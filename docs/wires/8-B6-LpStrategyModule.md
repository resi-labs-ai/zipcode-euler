# 8-B6 — LpStrategyModule (wiring map)

> **X-Ray (security verdict):** rated **ADEQUATE** — owns the zipUSD/xALPHA ICHI LP lifecycle; the load-bearing
> coverage path-lock (dissolve gated against the freeze floor) is tested across all three gate states (32 unit +
> 5 fork on the live ICHI vault/gauge). Report:
> `contracts/src/supply/szipUSD/x-ray/LpStrategyModule.md` (scope: `portfolio-map.md`). ELI20:
> `docs/supply/szipUSD/LpStrategyModule.md`. This doc is the code-truth wiring map.

> Source of truth = the kept code `contracts/src/supply/szipUSD/LpStrategyModule.sol`. Ticket
> `tickets/sodo/8-B6-lp-strategy.md` + report `reports/8-B6-report.md` are intent only — the code is final.
> Test: `contracts/test/LpStrategyModule.t.sol`.

## Role
The **third engine Zodiac Module** (after the 8-B14 buy-and-burn and the 8-B5 farm utility loop) and the **simplest**
of the engine set: **no EVC leg, no oracle, no hook, no custody, no storage written in any mutating path**. It owns
the LP's whole lifecycle on the szipUSD engine Safe: build the single-sided zipUSD/xALPHA ICHI LP (`addLiquidity` →
`IICHIVault.deposit`), gauge-stake it to farm oHYDX (`stake` → `IGauge.deposit`), unstake slices back to the
Safe for the 8-B5 harvest loop (`unstake` → `IGauge.withdraw`), and decompose LP back to its zipUSD/xALPHA legs
(`removeLiquidity` → `IICHIVault.withdraw`). The module is **CRE-operator-gated**: the operator supplies only
scalar amounts; the module builds all calldata to set-once wired targets and the deposit/withdraw `to` / every
balance read is the literal `juniorTrancheEngine`.

**`removeLiquidity` is the LP→legs dissolution hop, now COVERAGE-GATED (LP path-lock).** It is the
global-wind-down feeder (`unstake` → `removeLiquidity` → `SellModule.sellXAlpha` → zipUSD → senior par queue →
buy-burn bid). It is the ONLY path that turns the fenced LP into exitable legs, so it is bounded to the coverage
EXCESS: `removeLiquidity` reverts `Undercovered` unless `coverageGate.lpBurnKeepsCovered(shares)` (i.e.
`coverageValue − lpShareValue(shares) >= requiredCommittedValue`). With debt outstanding the floor is tight and
the excess is ~0, so it reverts (making the "wind-down only" NatSpec TRUE); as debt amortizes the floor drops and
LP becomes dissolvable. `coverageGate == 0` is the M1 pre-wiring / kill-switch state (ungated, legacy).

The module is **vault-agnostic** — it forwards `(deposit0, deposit1)` unchanged. Single-sidedness is **not a module
gate**; it is the *wired vault's* `allowToken0()`/`allowToken1()` property, which rejects the disallowed leg
fail-closed inside the vault. The only shape guard is `ZeroAmount` (≥1 non-zero side) + the `minShares` floor. The
ICHI **DepositGuard is NOT used** — direct `IICHIVault.deposit` lands shares (build-verified on live Base against the
real vault `0x07e72…` on factory `0x2b52c416…`); slippage protection is the operator-supplied `minShares` post-check,
not the guard's `minimumProceeds`. The LP token **IS** the ICHI vault contract (an 18-dp ERC20); the gauge custodies
the staked LP.

## Contracts involved (what each does)
| Contract / Interface | What it does |
|---|---|
| `LpStrategyModule` (`is Module`, zodiac-core) | The seam. `setUp` initializer (6 args, +`coverageGate`) + 7 `onlyOwner` build-phase wiring setters (incl. `setCoverageGate`) + 4 `onlyOperator` entrypoints (`addLiquidity`/`removeLiquidity` (coverage-gated)/`stake`/`unstake`) + 2 views (`stakedBalance`/`lpBalance`). Private `_exec` drives the Safe via inherited `execAndReturnData` (Call, value 0) and bubbles inner reverts. |
| `ICoverageGate` (declared inline in the .sol) | The coverage seam `removeLiquidity` reads (the `DurationFreezeModule`): `lpBurnKeepsCovered(uint256 lpShares) → bool`. Zero ⇒ gate OFF. |
| `IICHIVault` (`src/interfaces/ichi/IICHIVault.sol`) | The managed LP vault for zipUSD/xALPHA. `deposit(deposit0, deposit1, to) → shares`; `withdraw(shares, to) → (amount0, amount1)`; `token0()`/`token1()`/`balanceOf()` read live. The vault contract **is** the LP share token. `allowToken0/1()` is where single-sidedness lives (fail-closed). |
| `IGauge` (`src/interfaces/hydrex/IGauge.sol`) | The Hydrex gauge over our pool. `deposit(amount)`/`withdraw(amount)` stake/unstake the LP; `balanceOf(safe)` is the staked balance. Staking is REQUIRED to earn oHYDX (bare LP earns only swap fees). Must be `ALM_ICHI_UNIV3` type. |
| `IERC20` (OZ 4.x) | `approve` selector encoded for the exact-amount approve / reset on both legs (token0/token1 → ichiVault; ichiVault → gauge). |
| `Module` / `Operation` (zodiac-core) | Base: `avatar`/`target` (set to `juniorTrancheEngine`), `onlyOwner`, `execAndReturnData`, `initializer`. |

## Wiring — internal (ctor / setUp / entrypoints)
**No constructor logic of its own** — the mastercopy is init-locked in its constructor (see `MastercopyInitLock`,
SEC-14). All per-clone config is
**plain set-once storage written in `setUp` under `initializer`, NOT `immutable`** (a `ModuleProxyFactory` clone
shares the mastercopy runtime bytecode, so `immutable` would be identical for every clone and cannot carry per-clone
config — the proven 8-B14/8-B5 clone fact).

**`setUp(bytes initParams)`** decodes **six** params `(owner, juniorTrancheEngine, operator, ichiVault, gauge,
coverageGate)`. Order is load-bearing:
1. Validate the **first five** addresses nonzero (`ZeroAddress`) FIRST — so an `ichiVault == 0` reverts cleanly,
   not via a staticcall on a code-less address; then `owner != operator` (`OwnerIsOperator`). `coverageGate` MAY
   be `address(0)` (gate OFF) — no zero-check (mirrors `setCoverageGate`).
2. Set `avatar = target = juniorTrancheEngine` (the module is enabled ON the engine Safe and only ever mutates it).
3. Persist `juniorTrancheEngine`/`operator`/`ichiVault`/`gauge`; read `token0`/`token1` LIVE; set `coverageGate`.
4. `_transferOwnership(owner_)`.

**Seven storage slots** (all `public`): `juniorTrancheEngine`, `operator`, `ichiVault`, `gauge`, `token0`, `token1`,
`coverageGate` (the `DurationFreezeModule`; ARMED at deploy, Timelock-re-pointable / kill-switch via `setCoverageGate(0)`).

**Four `onlyOperator` entrypoints** (scalar-only; the gate is `msg.sender != operator → NotOperator`):
- **`addLiquidity(deposit0, deposit1, minShares) → shares`** — guards `!(deposit0==0 && deposit1==0)` (`ZeroAmount`)
  and `minShares != 0` (`ZeroMinShares` — a zero floor would no-op the only sandwich protection on a direct ICHI
  deposit). Then, per non-zero leg: `_exec(tokenN, approve(ichiVault, depositN))`; `_exec(ichiVault,
  IICHIVault.deposit(deposit0, deposit1, juniorTrancheEngine))` and `abi.decode` the returned `shares`; reset each approved leg
  to 0; finally `shares < minShares → Slippage`. Deposit `to` is the literal `juniorTrancheEngine` — the minted LP lands in the
  Safe. No standing approvals (exact-amount, reset defensively).
- **`removeLiquidity(shares, minAmount0, minAmount1) → (amount0, amount1)`** — `ZeroAmount` guard (shares); then
  the **ZERO-FLOOR GUARD**: `if minAmount0 == 0 && minAmount1 == 0 → ZeroMinAmount` (the ICHI
  `withdraw` self-protects with nothing, so this floor is the SOLE sandwich guard; at least one leg must be
  floored). Then the **COVERAGE GATE**: `if coverageGate != 0 && !ICoverageGate(coverageGate).lpBurnKeepsCovered(shares) →
  Undercovered` (only the coverage EXCESS may be liquefied). Then exactly 1 `exec`: `IICHIVault.withdraw(shares,
  juniorTrancheEngine)`, `abi.decode` the two leg amounts, then `amount0 < minAmount0 || amount1 < minAmount1 → Slippage`.
  **No approval needed** — the LP shares are already in the Safe (unstaked first via `unstake`), and the vault
  burns from / pays to the Safe because the Safe is the `exec` msg.sender. Decomposes LP → zipUSD/xALPHA into the Safe.
- **`stake(lpAmount)`** — `ZeroAmount` guard, then exactly 3 `exec`s: `approve(gauge, lpAmount)` on `ichiVault` (the LP
  token) / `IGauge.deposit(lpAmount)` / `approve(gauge, 0)` reset.
- **`unstake(lpAmount)`** — `ZeroAmount` guard, then exactly 1 `exec`: `IGauge.withdraw(lpAmount)`. The gauge returns
  the LP to the Safe (= the gauge call's `msg.sender`).

**Views** (pinned to `juniorTrancheEngine`): `stakedBalance()` = `IGauge(gauge).balanceOf(juniorTrancheEngine)`; `lpBalance()` =
`IICHIVault(ichiVault).balanceOf(juniorTrancheEngine)`. These feed the 8-B5/8-B11/8-B12 back-pressure sizing.

**`_exec(to, data)` discipline:** inherited `execAndReturnData(to, 0, data, Operation.Call)` — Call-only, `value == 0`,
no delegatecall, no generic passthrough. On `ok == false` it **bubbles the inner revert data** (`revert(add(ret,
0x20), mload(ret))`) so the original ICHI/gauge error surfaces, or `ExecFailed` if there is none. (The Gnosis Safe's
`execTransactionFromModuleReturnData` catches inner reverts and returns `(false, revertData)` rather than bubbling, so
an unchecked `exec` would silently swallow a failed deposit/stake — hence the hard re-revert.)

**No DepositGuard slot.** The module deposits directly into `IICHIVault.deposit`; the guard `0x9A0EBEc4…` is neither
wired nor referenced.

## Wiring — cross-component (who points at whom)
- **`ichiVault` = the SHARED LP address (PROGRESS row 338).** The production POL ICHI vault (the LP share token) MUST
  be the **single** address wired into ALL of: this module's `ichiVault` (`setUp`), the 8-B5 farm utility escrow vault's
  collateral `asset()` (`FarmUtilityMarketDeployer.lpToken`), the `SzipFarmUtilityLpOracle` `LP_MARK` key, and the
  `SzipNavOracle` basket-LP leg. 8-B6 `unstake`s that LP to the Safe (harvest-loop step 1) and 8-B5 `postCollateral`
  deposits it into the escrow — if the two are wired to *different* LP addresses the loop silently fractures (the
  unstaked LP can't be posted). The item-10 deploy MUST assert
  `LpStrategyModule.ichiVault() == farm utility-escrow asset() == lpOracle key`.
- **`gauge` resolved via `Voter.gauges(ourPool)`** (Hydrex Voter `0xc69E…`) with a **hard `!= 0` gate** — our
  zipUSD/xALPHA gauge must be Hydrex-whitelisted (`Voter.createGauge(ourPool, ALM_ICHI_UNIV3)`), an **external
  governance dependency** (`hydrex.md §9.4`). The gauge's staking token is the ICHI vault share; staking is what earns
  oHYDX (8-B7 claims it).
- **`operator` = the single CRE operator** — the sole caller of all three entrypoints. The CRE robot sizes `minShares`
  off the `SzipNavOracle` reserve×price math (no on-chain absolute floor is knowable without the oracle; per-call
  non-zero is the right granularity) and sequences `unstake → re-stake` around the 8-B5 strike loop (8-B11 driver).
- **Staked/collateral exclusivity (8-B5 seam).** A staked LP is custodied by the gauge and therefore cannot
  *simultaneously* be EVK collateral — collateralizing requires unstaking, and the unstaked slice stops earning oHYDX
  until re-staked. This is exactly why 8-B5 is a tight unstake→borrow→repay→re-stake loop, not a hold; 8-B6 supplies
  the `unstake` (loop step 1) and `stake` (loop step 7) ends.
- **`coverageGate` = the `DurationFreezeModule`** — wired at `setUp` (ARMED at deploy), the seam `removeLiquidity`
  reads to bound dissolution to the coverage excess. Timelock-settable via `setCoverageGate` (`address(0)` allowed
  = OFF kill-switch).
- **`owner` = the TimelockController** (governance) — holds the 7 `onlyOwner` build-phase wiring setters
  (`setJuniorTrancheEngine`/`setOperator`/`setIchiVault`/`setGauge`/`setToken0`/`setToken1`/`setCoverageGate`, each
  `WiringSet`-emitting; the first six `ZeroAddress`-guarded, `setCoverageGate` allows 0) plus the inherited
  `setAvatar`/`setTarget`. `owner != operator` is enforced at `setUp` and at `setOperator`. The hot CRE
  `operator` can never re-point wiring; a redirect is a deliberate timelocked act.

## Item-10 deploy facts (PROGRESS rows 337/338/339)
- **Create the POL vault** as a **single-sided zipUSD YieldIQ ICHI vault** via the ICHI factory `0x2b52c416…`
  (`createICHIVault`): only zipUSD deposited; the xALPHA leg is acquired via the underlying Algebra pool's flow +
  the emissions flywheel (exact vault config pending an ICHI conversation — single-sided zipUSD is the decided shape).
- **Resolve + wire the gauge** via `Voter.gauges(ourPool)` with the **hard gate `Voter.gauges(ourPool) != 0`** (the
  ALM_ICHI gauge must be Hydrex-whitelisted — external governance dep).
- **CREATE2-clone** the module via `ModuleProxyFactory`, `enableModule` it on the engine Safe, and `setUp` it with
  `(owner=Timelock, juniorTrancheEngine, operator, ichiVault, gauge, coverageGate=durationFreeze)`. The mastercopy is locked
  AUTOMATICALLY by its constructor (`MastercopyInitLock`, SEC-14) the instant it is deployed — NO separate
  deploy-time lock step, and `setUp` on the mastercopy reverts `AlreadyInitialized`. Deploy clones
  `DurationFreezeModule` at the TOP of P6 (before this module) so the gate is wired
  LIVE; a `SeamCoverageGate` assert confirms `coverageGate() == durationFreeze`.
- **`owner = TimelockController != operator`** (the hot CRE key).
- **Assert** `LpStrategyModule.ichiVault() == farm utility-escrow vault asset() == lpOracle key` (the shared-LP-address
  invariant, row 338).
- No `audit/*` follow-on for 8-B6 itself — the LP-lifecycle audit-sweep is folded into the deferred
  engine-integration pass.

## Gotchas
- **The gauge MUST be `ALM_ICHI_UNIV3` type.** A wrong-type gauge (or an unwhitelisted pool, `Voter.gauges(ourPool)
  == 0`) breaks staking; until the Hydrex OTC whitelist lands, fork tests use a stand-in (`hydrex.md §9.4`). The
  production zipUSD/xALPHA vault + ALM gauge do not exist until the whitelist clears — the behavioral cycle tests use
  mocks (the blessed §4.5.1 stand-in posture); the real-vault fork test uses the live WETH/USDC single-sided vault as
  a *mechanism* stand-in (direct deposit lands shares).
- **Backed-zipUSD-only invariant.** The CRE funds the engine Safe with backed zipUSD (minted only via 8-B10's
  free-value path); **the module never mints** and holds no custody — it only forwards the Safe's own balances. The
  deposited zipUSD must be backed, never unbacked.
- **0.8.24 pin.** `require(cond, CustomError())` is 0.8.26+; guards here use `if (!cond) revert CustomError()`.
- **Fork non-determinism (test-infra).** `ForkConfig` uses an unpinned `createSelectFork("base")` (latest block); the
  two real-vault fork tests deposit a FIXED amount into a live third-party ICHI vault, which can intermittently revert
  `DTL` at certain blocks. Pin a block before relying on those two tests (logged in PROGRESS as latent fragility);
  the module logic is unaffected.
- **A zero slippage floor is rejected on BOTH legs** — `minShares == 0` on add (`ZeroMinShares`) and both
  `minAmount0/1 == 0` on remove (`ZeroMinAmount`). Verified against the real ICHI source: the
  *deposit* self-protects (spot-vs-TWAP hysteresis), so its floor is belt-and-suspenders; the *withdraw* self-
  protects with nothing (decomposes at the current tick), so its floor is the SOLE sandwich guard — which is why
  the remove guard is at-least-one-non-zero and the CRE sizes it off the TWAP fair reserves, not spot
  (KEEPER-02).
