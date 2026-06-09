# 8-B6 — LP strategy module (build + maintain the gauge-staked ICHI LP)

> **NEXT / build-only.** The second harvest-loop engine module to be built (after 8-B5 reservoir-loop and 8-B14
> buy-and-burn). It owns the **LP's whole lifecycle**: build the zipUSD/xALPHA **single-sided ICHI LP**,
> **gauge-stake** it on Hydrex to farm oHYDX, and **unstake/re-stake** slices so 8-B5 can collateralize them per
> harvest. Internal engine plumbing → **build-only** (no INFLOW ticket; the frontend never wires to it, the CRE
> strategy robot 8-B11 drives every entrypoint). It is the **third engine Zodiac Module** — it reuses the
> `is Module` + `setUp(bytes)`-under-`initializer` + `onlyOperator` + `exec(...,Operation.Call)` + `_exec`-that-
> bubbles pattern established by `SzipBuyBurnModule` (8-B14) and `ReservoirLoopModule` (8-B5), with **no EVC leg**
> (it never borrows — it only drives the Safe to call the ICHI vault + the gauge).

**Deliverable**
Two files under the supply/engine tree:
- `contracts/src/supply/szipUSD/LpStrategyModule.sol` — `contract LpStrategyModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine
  Safe** (`avatar == target == engineSafe`). Three operator-only entrypoints — **`addLiquidity`** (build the LP),
  **`stake`** (gauge-stake), **`unstake`** (un-stake a slice for the 8-B5 loop) — each mutating the Safe **only** via
  the inherited `exec`/`execAndReturnData(to, value, data, Operation.Call)` to drive the **wired ICHI vault** and
  **wired gauge**. The operator supplies **only scalar amounts** (`deposit0`/`deposit1`/`minShares`/`lpAmount`); the
  module builds all calldata to the **set-once wired targets** (`ichiVault`, `gauge`, `token0`, `token1`), with the
  deposit `to` and every balance read hard-pinned to `engineSafe`. No generic call passthrough, no delegatecall,
  `value == 0` on every `exec` — the module's whole security boundary (§10.1).
- `contracts/test/LpStrategyModule.t.sol` — unit (recording-mock Safe — exec-shape / authority / atomicity /
  slippage) + fork (live Base: a **real ICHI vault** single-sided `deposit` against real ICHI bytecode + a fork
  **signature-verification** of the real gauge/Voter surface + the full add→stake→unstake→re-stake cycle against a
  real summoned substrate Safe with a faithful mock gauge).

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec: the **shared architecture** (every engine module is
  a `is Module` Zodiac module `enableModule`'d on the szipUSD Safe; one immutable CRE operator = `onlyOperator`;
  mutate the Safe only via inherited `exec(to,value,data,Operation.Call)`; the module holds **no custody**, the Safe
  holds the basket) and the **8-B6** block: external calls `ICHI vault deposit(uint256 deposit0, uint256 deposit1,
  address to) → shares` (single-sided ⇒ one deposit arg `0`); resolve the gauge `Voter.gauges(ourPool) → address`;
  **gauge-stake** `gauge.deposit(uint256)` / **unstake** `gauge.withdraw(uint256)` (Solidly-style — **staking is
  REQUIRED to earn oHYDX**; the bare LP earns only swap fees). CRE op seq (two directions): *build/stake* — pull
  zipUSD and/or xALPHA from the basket → `ICHI.deposit` → receive LP → `gauge.deposit`; *loop service* —
  `gauge.withdraw(slice)` (8-B5 step 1) then `gauge.deposit(slice)` (8-B5 step 7). State: ICHI vault, gauge,
  staked-LP balance (read from the gauge). Invariants: LP must be gauge-staked to earn oHYDX; the zipUSD leg is
  **backed** (minted only via 8-B10's free-value path, never unbacked); the **staked/collateral exclusivity** (a
  staked LP is custodied by the gauge → cannot simultaneously be EVK collateral → the loop must unstake first).
- `reports/baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one immutable CRE operator =
  `onlyOperator`, mutate the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via
  `ModuleProxyFactory`, init in `setUp` under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B6** (the
  LP/stake module description) + **§10.2** (the steady-state target — the basket converges toward mostly the
  gauge-staked zipUSD/xALPHA ICHI LP).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation. (8-B6 reopens nothing.)

**Model from (VERIFIED against `reference/`, the kept builds, and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol`. **Verified by the kept `SzipBuyBurnModule`
  (8-B14) and `ReservoirLoopModule` (8-B5), both build + fork-test green under 0.8.24:** `abstract contract Module is
  FactoryFriendly, Ownable`; `setUp(bytes) public virtual`; `initializer` is **zodiac-core's own**
  (`factory/Initializable.sol`, one-shot); `exec(to,value,data,Operation) internal` (`core/Module.sol:43`) and
  `execAndReturnData(to,value,data,Operation) internal returns (bool, bytes)` (`:59`) → forward to
  `IAvatar(target).execTransactionFromModule(...)` / `...ReturnData(...)`; `Operation { Call, DelegateCall }`
  (`core/Operation.sol`); `Ownable` is zodiac-core's own (`factory/Ownable.sol`: `address public owner`, `onlyOwner`
  reverts `OwnableUnauthorizedAccount`, `_transferOwnership` internal/no-guard — use in `setUp`; `setAvatar`/
  `setTarget` are `public onlyOwner` at `Module.sol:23/:31`). Remap
  `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/` (`remappings.txt:10`); zodiac-core imports **zero
  OpenZeppelin** → no OZ-4/5 collision.
- **Import the exact lines from the kept models (do NOT re-derive aliases):** copy the module header from
  `contracts/src/supply/szipUSD/ReservoirLoopModule.sol:4-5` (`Module`, `Operation`) and the
  `_exec`-that-bubbles helper **logic** from `ReservoirLoopModule.sol:146-154` (the Gnosis Safe **swallows** inner
  reverts and returns `(false, revertData)` — a bare `exec` would silently swallow a failed ICHI/gauge call and
  wrongly emit success, so route every mutation through a private `_exec` using `execAndReturnData` that **bubbles**
  the inner revert data, falling back to `ExecFailed` when there is none). **NOTE: the kept 8-B5 `_exec` is `private`
  and returns `void` — 8-B6 MUST adapt it to `private returns (bytes memory)` and add `return ret;` after the `if
  (!ok)` block, because `addLiquidity` decodes the ICHI `deposit` share-return from it (`abi.decode(ret, (uint256))`).
  Copy the bubbling body verbatim; change ONLY the signature + add the return.** The ICHI/Hydrex interfaces are **local** (vendored
  as minimal interfaces, not compiled from source — the `[EXT]` posture): import
  `{IICHIVault} from "../../interfaces/ichi/IICHIVault.sol"` + `{IGauge} from "../../interfaces/hydrex/IGauge.sol"`
  + `{IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"` (the `approve` selector only). (8-B6 needs **no
  EVC, no EVK, no oracle, no euler-earn** — it is the simplest engine module's calldata shape.)
- **CRITICAL clone fact (§18.6, proven on 8-B14/8-B5).** A `ModuleProxyFactory` clone shares the mastercopy's
  runtime bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp` config.
  **Every per-clone wired address of `LpStrategyModule` (`operator`, `engineSafe`, `ichiVault`, `gauge`, `token0`,
  `token1`) MUST be plain set-once storage written in `setUp` under `initializer`, NOT `immutable`.** Init-lock the
  mastercopy at deploy.
- **The ICHI add path — VERIFIED on live Base this window (2026-06-08).** The add call is the ICHI vault's **direct
  `deposit(uint256 deposit0, uint256 deposit1, address to) → shares`** (`IICHIVault.sol`, selector `0x8dbdbe6d`
  on-chain-verified). The vault share token **IS** the ICHI vault contract (the LP token == `ichiVault`).
  Single-sided ⇒ one of `deposit0`/`deposit1` is `0`, and the vault's `allowToken0()`/`allowToken1()` gate which
  side is permitted (a deposit on a disallowed side reverts in the vault — fail-closed). **Live probe:** ICHI vault
  `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad` (our factory `0x2b52c416…`, `ammName()=="HYDX"`) is a real
  **single-sided** vault — `token0()=WETH (0x4200…0006)`, `token1()=USDC (0x833589fC…)`, `allowToken0()=true`,
  `allowToken1()=false`, `deposit0Max()=4000e18` — so `deposit(wethAmt, 0, to)` is the exact single-sided shape. The
  fork test drives the module's `addLiquidity` against THIS live vault to prove direct `deposit` lands shares
  against **real ICHI bytecode** (the stand-in posture: our zipUSD/xALPHA vault has the same factory/codebase, it
  just isn't deployed until the POL pool/gauge whitelist lands). **The DepositGuard `0x9A0EBEc4…` is NOT used** —
  direct deposit is build-verified to work, the module is a contract that already holds the tokens, and the
  `forwardDepositToICHIVault(...)` guard is an EOA/UI convenience; the module deposits directly and gets slippage
  protection from the **`minShares` post-check** (operator-supplied bound, fail-closed) instead of the guard's
  `minimumProceeds`. **If the build's fork test shows the live vault's `deposit` is NOT directly callable
  (guard-only), fall back to `IICHIDepositGuard.forwardDepositToICHIVault(ichiVault, factory, token, amount,
  minShares, engineSafe)` for the single-sided path and record the resolution in the report** — keep-the-build: the
  code resolves the live-chain question, not the prose.
- **The gauge — VERIFIED on live Base this window.** Solidly-style: `gauge.deposit(uint256 amount)` (selector
  `0xb6b55f25`) / `gauge.withdraw(uint256 amount)` (`0x2e1a7d4d`) / `gauge.balanceOf(address)` (`0x70a08231`) /
  `gauge.rewardToken() → oHYDX` (the claim is 8-B7's job, not 8-B6's). Live gauge
  `0xAC396CabF5832A49483B78225D902C0999829993` (`Voter.gauges(HYDX/USDC pool) → this gauge`,
  `rewardToken()==oHYDX 0xA1136031…` confirmed on-chain). **8-B6 does NOT read the gauge's staking-token accessor**
  (`stakingToken()`/`TOKEN()`/`pool()` all REVERT on this gauge — the accessor varies by gauge type, §4.5.1) — the
  module knows the LP token from its `setUp` wiring (`ichiVault`), so the accessor variance is irrelevant to 8-B6.
  The fork **sig-verify** test confirms `deposit`/`withdraw`/`balanceOf`/`rewardToken` resolve on the live gauge;
  the behavioral stake/unstake tests run against a **faithful mock gauge** (our ALM_ICHI zipUSD/xALPHA gauge does
  not exist — the stand-in posture; staking an unrelated LP into the live HYDX/USDC gauge is not possible).
- **Gauge wiring is set-once, resolved upstream.** The module stores the `gauge` address from `setUp`; item-10
  deploy resolves it via `Voter.gauges(ourPool)` (hard gate: `Voter.gauges(ourPool) != 0` — our gauge must be
  whitelisted, an external Hydrex-governance dependency, `hydrex.md §9.4/§10`) and passes it. 8-B6 needs **no Voter
  import** (8-B7 owns voting).
- **Read `token0`/`token1` LIVE in `setUp`** off the wired vault (`IICHIVault(ichiVault).token0()/token1()`) — the
  same "read the live config off the dependency in `setUp`" pattern `SzipBuyBurnModule.setUp` uses for the
  VaultRelayer + domain separator (`SzipBuyBurnModule.sol:156-157`). This guarantees the approved tokens match the
  vault and removes two `setUp` args.
- **Error declarations (declare them; the ticket throws them):** `error NotOperator(); error ZeroAddress(); error
  OwnerIsOperator(); error ZeroAmount(); error ZeroMinShares(); error Slippage(); error ExecFailed();` (model the
  block on `ReservoirLoopModule.sol:59-69`). `ZeroMinShares` enforces a **non-zero slippage floor** — see the Do-NOT
  + KR3 (a `minShares == 0` would no-op the only sandwich protection on a direct ICHI deposit, security).
- **Addresses (`contracts/script/BaseAddresses.sol`, kept + verified):** `ICHI_VAULT_FACTORY 0x2b52c416…`,
  `ICHI_DEPOSIT_GUARD 0x9A0EBEc4…`, `HYDREX_VOTER 0xc69E3eF3…`, `OHYDX 0xA1136031…`, `HYDX_USDC_POOL 0x51f0B932…`,
  `USDC 0x833589fC…`. The live single-sided ICHI vault `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad` and the live
  gauge `0xAC396CabF5832A49483B78225D902C0999829993` are **test-only fork targets** (add them as test constants, NOT
  to `BaseAddresses` — they are not our production vault/gauge). WETH `0x4200000000000000000000000000000000000006`
  (the live test vault's `token0`).

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…05, `SzipNavOracle`, `ExitGate`+`SzipUSD`,
`ZipDepositModule`, 8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule` + `SzipReservoirLpOracle` +
`ReservoirBorrowGuard` + `ReservoirMarketDeployer`). zodiac-core `Module` proven by 8-B14/8-B5; the local ICHI/Hydrex
interfaces exist + are on-chain-verified (`contracts/src/interfaces/ichi/IICHIVault.sol`,
`contracts/src/interfaces/hydrex/IGauge.sol`, `IVoter.sol`). `contracts/src/supply/szipUSD/` exists. **No engine Safe
is summoned in unit tests** — use a **recording mock Safe** (the `RecordingSafe` in
`contracts/test/ReservoirLoopModule.t.sol` / `SzipBuyBurnModule.t.sol`: implements `execTransactionFromModule` +
`execTransactionFromModuleReturnData`, records each `(to, value, data, operation)`, `setLive`/`getCall`/`callCount`,
and `setFailOnCallIndex` for atomicity) for validation/authority/exec-shape, and a **real Base fork** with the **real
summoned substrate Safe** (`SummonSubstrate._summon`, model `ReservoirLoopModule.t.sol _summonAndEnable` /
`ExitGate.t.sol`) as the engine Safe for the live ICHI deposit + cycle.

**Two NEW test stand-ins to author (faithful, NOT named in the kept tree — write them in the test file).** Our
zipUSD/xALPHA ICHI vault + ALM gauge do not exist (the stand-in posture), so the behavioral cycle + exec-discipline
run against these (the real ICHI vault is used only for the headline single-sided-deposit + sig-verify fork tests):
- **`MockICHIVault` — an 18-dp ERC20 that IS the LP share token** (the vault == the LP token). It must: (a) implement
  `deposit(uint256 d0, uint256 d1, address to) returns (uint256 shares)` that **`transferFrom`s each non-zero side
  from `msg.sender`** (the Safe — using the allowance the module just set, so the approve/atomicity tests are real),
  asserts `to != address(0)`, **mints `shares` to `to` at a configurable `pricePerShare != 1e18`** (e.g. `shares =
  (d0 + d1) * 1e18 / pricePerShare`, settable in the ctor/a setter — so `shares != depositAmount` and the
  `minShares`/`lpBalance()` assertions exercise a non-unit share price), and reverts (custom error) when called with a
  **disallowed side** (configurable `allowToken0`/`allowToken1`, to model the `allowToken1=false` fail-closed); (b)
  expose `token0()`/`token1()`/`balanceOf(address)`/`allowToken0()`/`allowToken1()`/`approve`/`transfer`/
  `transferFrom`/`totalSupply`. Model the ERC20 plumbing on `MockLpToken` (`ReservoirLoopModule.t.sol:92`).
- **`MockGauge` — a faithful Solidly gauge over the LP token.** `deposit(uint256 amt)` **pulls the LP from
  `msg.sender` via `transferFrom`** (needs the module's approve) + credits `balanceOf[msg.sender] += amt`;
  `withdraw(uint256 amt)` debits `balanceOf[msg.sender]` + `transfer`s the LP back to `msg.sender`; expose
  `balanceOf(address)` + `rewardToken()`. So `stakedBalance()` (= `gauge.balanceOf(safe)`) and `lpBalance()` (=
  `ichiVault.balanceOf(safe)`) actually move as LP flows Safe↔gauge — the cycle assertions are real, not vacuous.

**Do NOT**
- **Do NOT expose ANY generic `exec`/`call`/`multicall`/arbitrary-target passthrough, and never let the operator
  supply `to`/`data`/`operation`/`receiver`/a vault/token/gauge address.** The operator passes **only scalar
  amounts** (`deposit0`/`deposit1`/`minShares`/`lpAmount`). The module's only `exec` targets are the **set-once
  wired** `ichiVault` / `gauge` / `token0` / `token1` with **module-built calldata**, and the deposit `to` + every
  balance read is the **literal set-once `engineSafe`**. This is the module's whole security boundary (§10.1; the
  8-B5/8-B14 boundary, no EVC leg).
- **Do NOT `delegatecall`** (§10.1: `Operation.Call` only, `value == 0` on every `exec`).
- **Do NOT send the LP, the deposited tokens, or the gauge receipt to any address other than `engineSafe`** (never
  the operator, never an arbitrary `to`). The deposit `to` is the literal `engineSafe`; `gauge.deposit`/`withdraw`
  credit/debit the Safe (msg.sender of the gauge call = the Safe, via `exec`).
- **Do NOT custody anything in the module.** The Safe holds the tokens, the LP, and the staked position; the module
  is stateless beyond its wired addresses (§10.1 — "the module holds no custody").
- **Do NOT make `addLiquidity` skip the `minShares` post-check, and do NOT accept `minShares == 0`.** A direct ICHI
  single-sided `deposit` is sandwich-exposed; the operator-supplied `minShares` floor (assert `shares >= minShares`,
  else `Slippage`) is the contract-side slippage guard that replaces the DepositGuard's `minimumProceeds`. A
  `minShares == 0` would silently no-op that protection (a lazy/compromised hot operator key → the deposit is fully
  sandwichable for one tick), so **reject `minShares == 0` with `ZeroMinShares()`** — there is no legitimate
  zero-floor deposit (the CRE robot always sizes `minShares` off the `SzipNavOracle` reserve×price math). Do NOT add
  an on-chain *absolute* share floor (the right value is unknowable on-chain without the oracle) — per-call non-zero
  is the correct granularity (security).
- **Do NOT add a module-level single-sided gate — keep the module VAULT-AGNOSTIC** (forward `(deposit0, deposit1)`
  unchanged to the wired vault; do NOT add an `xor`/`NotSingleSided` guard). **The design is single-sided zipUSD**
  (`claude-zipcode.md §4.5.1` "Vault = single-sided zipUSD YieldIQ, DECIDED 2026-06-08"), but single-sidedness is the
  **wired vault's** property: the ICHI YieldIQ vault's `allowToken0()`/`allowToken1()` rejects the disallowed side
  **fail-closed in the vault**, so a both-legs deposit reverts **there**, not in the module. The module stays agnostic
  so the **exact ICHI vault config can be finalized later (with ICHI) without re-authoring the module**. A balanced
  add is **not a supported flow** — the xALPHA leg is NEVER deposited; it accumulates in the Algebra position from
  pool trading + the emission flywheel (`auto-sodomizer.md §2/§10.3`). The module merely must not *itself* block the
  passthrough (that vault-agnostic property is what the both-legs tests pin).
- **Do NOT use `immutable` for any `setUp`-decoded value** (clone bytecode is shared).
- **Do NOT add a `removeLiquidity`/un-LP entrypoint, a gauge `getReward` claim, a vote, or a swap.** 8-B6's scope is
  exactly **build LP / stake / unstake-restake**. Claiming oHYDX + fees + voting is **8-B7**; un-LP / rebalance is
  **8-B13**; the borrow loop is **8-B5**. Keep the surface minimal (spec-faithful).
- **Do NOT edit anything under `reference/`** (pristine vendored tree). **Do NOT edit the kept WOOF/engine
  contracts** — 8-B6 is purely additive. **Do NOT add the test-only live vault/gauge addresses to
  `BaseAddresses.sol`** (they are not our production vault/gauge).

**Key requirements**

*A. `LpStrategyModule` (`is Module`).*
1. **`setUp(bytes initParams) public initializer`** decoding `(address owner, address engineSafe, address operator,
   address ichiVault, address gauge)`. **ORDER (load-bearing so the `ichiVault == 0` ZeroAddress test reverts at the
   guard, not the live read):** FIRST require **all five** decoded addresses (`owner`, `engineSafe`, `operator`,
   `ichiVault`, `gauge`) nonzero (`ZeroAddress`) and `owner != operator` (`OwnerIsOperator`); THEN set `avatar =
   engineSafe; target = engineSafe`; store `engineSafe/operator/ichiVault/gauge` (set-once, NOT immutable); THEN
   **read `token0 = IICHIVault(ichiVault).token0(); token1 = IICHIVault(ichiVault).token1()` LIVE**, store them, and
   assert both nonzero (`ZeroAddress`); finally `_transferOwnership(owner)`. The mastercopy is init-locked at deploy.
2. **`onlyOperator` gate (§10.1 invariant 1).** `addLiquidity`/`stake`/`unstake` gated to the single set-once
   `operator`; a non-operator reverts `NotOperator()`.
3. **`addLiquidity(uint256 deposit0, uint256 deposit1, uint256 minShares) external onlyOperator returns (uint256
   shares)` — the build/stake step (CRE op seq, *build* direction).** In order:
   - `if (deposit0 == 0 && deposit1 == 0) revert ZeroAmount();` (at least one side — the ONLY shape guard; the module
     is vault-agnostic and does NOT enforce single-sided, the wired single-sided vault rejects the disallowed side).
   - `if (minShares == 0) revert ZeroMinShares();` (the slippage floor must be a real bound — security; place this
     guard up front, before any `exec`).
   - For each non-zero side, **in the fixed order token0 then token1**, `_exec(tokenN,
     abi.encodeWithSelector(IERC20.approve.selector, ichiVault, depositN))` (approve the ICHI vault to pull `depositN`
     of `tokenN`). Skip the approve for a zero side. (`approve` is selector-built against the token address — the
     wired `token0`/`token1` are plain ERC20s; the `IICHIVault` interface intentionally declares no `approve`.)
   - `bytes memory ret = _exec(ichiVault, abi.encodeCall(IICHIVault.deposit, (deposit0, deposit1, engineSafe)));`
     then `shares = abi.decode(ret, (uint256));` (capture the minted-share return via `execAndReturnData` — `to ==
     engineSafe`).
   - **Reset each non-zero side's residual approval to `0`**, again **in the fixed order token0 then token1**
     (`_exec(tokenN, approve(ichiVault, 0))`) — leave no standing approval (the deposit consumes the exact amount,
     but reset defensively, the kept F13 pattern). So the balanced exec order is exactly `[0] approve(token0,d0) ·
     [1] approve(token1,d1) · [2] deposit · [3] approve(token0,0) · [4] approve(token1,0)` (5 execs); single-sided
     token0 = `[0] approve(token0,d0) · [1] deposit · [2] approve(token0,0)` (3 execs).
   - `if (shares < minShares) revert Slippage();` (the contract-side slippage floor — operator-supplied bound).
   - `emit LiquidityAdded(deposit0, deposit1, shares);` and `return shares;`
4. **`stake(uint256 lpAmount) external onlyOperator` — gauge-stake (CRE op seq *stake* / loop step 7 re-stake).** In
   order: `if (lpAmount == 0) revert ZeroAmount();`; `_exec(ichiVault, approve(gauge, lpAmount))`;
   `_exec(gauge, abi.encodeCall(IGauge.deposit, (lpAmount)))`; reset `_exec(ichiVault, approve(gauge, 0))`;
   `emit Staked(lpAmount);` (the ICHI vault share IS the LP token == `ichiVault`).
5. **`unstake(uint256 lpAmount) external onlyOperator` — un-stake a slice (loop step 1, before 8-B5
   `postCollateral`).** `if (lpAmount == 0) revert ZeroAmount();`; `_exec(gauge, abi.encodeCall(IGauge.withdraw,
   (lpAmount)))`; `emit Unstaked(lpAmount);` (the gauge returns the LP to the Safe = the gauge call's msg.sender).
6. **`_exec(address to, bytes memory data) private returns (bytes memory)`** — model
   `ReservoirLoopModule.sol:146-154` **exactly**: `(bool ok, bytes memory ret) = execAndReturnData(to, 0, data,
   Operation.Call); if (!ok) { if (ret.length == 0) revert ExecFailed(); assembly { revert(add(ret,0x20),
   mload(ret)) } } return ret;` (bubbles the inner ICHI/gauge revert so a failed deposit/stake never reports
   success).
7. **Views (8-B5/8-B11/8-B12 back-pressure).** `stakedBalance() view returns (uint256)` =
   `IGauge(gauge).balanceOf(engineSafe)` (the gauge-staked LP — 8-B5 reads it to size the unstake slice, 8-B12
   monitors it); `lpBalance() view returns (uint256)` = `IICHIVault(ichiVault).balanceOf(engineSafe)` (unstaked LP
   sitting in the Safe). Public getters for `engineSafe/operator/ichiVault/gauge/token0/token1`; the three events.
   No persistent loop state.

**Done when**
- `forge build` green (the third zodiac-core engine module; no OZ collision — the module uses zodiac Ownable, never
  mixes an OZ Ownable in the same contract; the ICHI/Hydrex interfaces are local minimal interfaces).
- `forge test --fork-url $BASE_RPC_URL --match-contract LpStrategyModuleTest` green, covering:
  - **the real-ICHI-vault single-sided deposit (the headline external-verification, fork):** wire a module to the
    **live ICHI vault `0x07e72…`** (`token0`=WETH read live, `allowToken0=true`) on a real summoned substrate Safe;
    `deal(WETH, engineSafe, amt)`; as operator `addLiquidity(amt, 0, minShares)` → the real `vault.deposit(amt, 0,
    safe)` lands shares, `vault.balanceOf(safe) > 0`, returned `shares >= minShares`, `lpBalance() == vault
    .balanceOf(safe)`, and the residual WETH allowance on the vault is `0`. Proves **direct `deposit` is callable +
    the calldata shape is correct against REAL ICHI bytecode on our factory**. *(If the live vault rejects a direct
    deposit → switch to the DepositGuard fallback per "Model from" + record it; the test must still prove a real
    on-chain single-sided add lands shares.)*
  - **slippage floor (fork, real vault — snapshot-guarded so it is deterministic):** `uint256 snap = vm.snapshot();`
    probe `probed = addLiquidity(amt, 0, 1)` (minShares=1 passes); `vm.revertTo(snap)` (so the probe's deposit does
    NOT grow the pool and shift the second run's share output); then `vm.expectRevert(Slippage.selector);
    addLiquidity(amt, 0, probed + 1)`. (Pin the fork — `ForkConfig` selects `base`; the real ICHI single-sided
    `deposit` is path-deterministic for a fixed pool state, so post-revert the re-run mints exactly `probed`.) Also
    assert **`addLiquidity(amt, 0, 0)` reverts `ZeroMinShares`** (the non-zero-floor guard, security).
  - **gauge surface sig-verify (fork — VIEW selectors only):** against the **live gauge `0xAC396…`**, assert the
    view selectors the test can soundly resolve read-only: `IGauge(gauge).rewardToken() == BaseAddresses.OHYDX` and
    `IGauge(gauge).balanceOf(address(this))` resolves (returns 0), plus `IVoter(HYDREX_VOTER).gauges(HYDX_USDC_POOL)
    == 0xAC396…` (the pool→gauge resolution). Do NOT staticcall the **state-mutating** `deposit`/`withdraw` to "prove
    the selector is present" (they cannot be staticcalled without side effects); their presence was bytecode-scanned
    when the `IGauge` interface was authored (its header documents `0xb6b55f25`/`0x2e1a7d4d`). This confirms `IGauge`
    is faithful to the live chain; the behavioral stake/unstake run on the `MockGauge` (our ALM gauge does not exist).
  - **the full cycle (fork, mock gauge):** a real summoned Safe + a mock ICHI vault + a mock gauge; as operator
    `addLiquidity(d0, d1, minShares)` → `lpBalance() == shares`; `stake(shares)` → `stakedBalance() == shares` and
    `lpBalance() == 0` (LP moved to the gauge); `unstake(slice)` → `stakedBalance() == shares - slice` and
    `lpBalance() == slice` (the 8-B5 unstake step); `stake(slice)` re-stakes → `stakedBalance() == shares` (loop
    step 7). Prove it cycles (run unstake→re-stake twice).
  - **vault-agnostic passthrough — single-sided + both-legs (unit, permissive mock vault, non-1:1 share price):**
    proves the module forwards `(d0, d1)` unchanged (single-sidedness is the *vault's* job, not the module's; our
    production single-sided vault rejects a both-legs deposit, see the disallowed-side fork test). With the
    `MockICHIVault` at a
    `pricePerShare != 1e18`, `addLiquidity(x, 0, m)` and `addLiquidity(0, y, m)` and `addLiquidity(x, y, m)` each mint
    shares (proving the module does NOT itself gate single-sided — the agnostic property; the production vault, not
    the module, is what rejects both-legs), and assert `lpBalance() == returnedShares` with `returnedShares !=
    depositAmount` (proves the share-return is captured, not assumed 1:1).
  - **disallowed-side live revert (fork, real vault — the `_exec` bubble on real bytecode):** wire the live WETH-only
    vault (`allowToken1()==false`); `deal(USDC, engineSafe, x)`; `addLiquidity(0, x, 1)` reverts (the bubbled vault
    revert, NOT a generic `ExecFailed`) — proves the `allowToken1=false` fail-close + the `_exec` bubble meet on real
    ICHI bytecode.
  - **views read `engineSafe`, not the module/`address(this)` (unit):** mint LP (mock vault) to a STRANGER →
    `stakedBalance() == 0` && `lpBalance() == 0`; then add+stake to the Safe → the views reflect the Safe's balances
    (catches a regression where a view reads `address(this)`).
  - **exec discipline (recording mock — THE security-boundary test, exhaustive).** The RecordingSafe MUST be
    `setLive(true)` with a **real `MockICHIVault`/`MockGauge` wired as the targets** — because `addLiquidity`
    `abi.decode`s the deposit's `uint256` return, a non-live mock (which returns `""`) would revert in the decode
    before any assertion (the new failure mode the kept void-`_exec` 8-B5 pattern does not cover). Per entrypoint,
    assert the **exact `callCount()`** AND pin the **per-index** `(to, value==0, op==Call, keccak(calldata))` via
    `_assertCall` (model `ReservoirLoopModule.t.sol:430`):
    - `addLiquidity(d0, 0, m)` single-sided = **3**: `[0]` `token0`,`approve(ichiVault,d0)` · `[1]` `ichiVault`,
      `deposit(d0,0,engineSafe)` · `[2]` `token0`,`approve(ichiVault,0)`.
    - `addLiquidity(d0, d1, m)` balanced = **5**: `[0]` `approve(token0,ichiVault,d0)` · `[1]`
      `approve(token1,ichiVault,d1)` · `[2]` `ichiVault`,`deposit(d0,d1,engineSafe)` · `[3]`
      `approve(token0,ichiVault,0)` · `[4]` `approve(token1,ichiVault,0)`.
    - `stake(lp)` = **3**: `[0]` `ichiVault`,`approve(gauge,lp)` · `[1]` `gauge`,`deposit(lp)` · `[2]` `ichiVault`,
      `approve(gauge,0)`.
    - `unstake(lp)` = **1**: `[0]` `gauge`,`withdraw(lp)`.
    Decode the `deposit` calldata's 3rd arg and assert `== engineSafe` (proves a `deposit(...,operator)` regression
    cannot hide behind the `to == ichiVault` outer shape).
  - **atomicity / rollback (recording mock `setFailOnCallIndex`, `setLive(true)`, real allowance-tracking targets).**
    The fail-index differs from 8-B5 (no interposed `enableCollateral`): for **single-sided** `addLiquidity` the
    deposit is index **1** (`[0]` approve, `[1]` deposit) → `setFailOnCallIndex(1)`, `deal(token0, safe, amt)`,
    expect revert, assert `IERC20(token0).allowance(safe, ichiVault) == 0` (the approve rolled back with the tx). For
    the **balanced** path force index **2** (the deposit, after `[0]/[1]` approves) and assert **both** `token0` AND
    `token1` allowances rolled back to 0 (covers the balanced reset path — security). For `stake`, `gauge.deposit` is
    index **1** (`[0]` approve, `[1]` deposit) → `setFailOnCallIndex(1)`, assert `IERC20(ichiVault).allowance(safe,
    gauge) == 0`. The approve targets MUST be real allowance-tracking tokens (the `MockICHIVault`/`MockLpToken`), not
    code-less addresses, so the allowance assertion is meaningful.
  - **authority / shape:** non-operator entrypoints revert `NotOperator`; the **operator (and any non-owner) cannot
    redirect the Safe** — `setAvatar`/`setTarget` revert `OwnableUnauthorizedAccount`; `setUp` callable once
    (`initializer`); `owner == operator` in `setUp` reverts `OwnerIsOperator`; at least one per-field `ZeroAddress`
    case (e.g. `gauge == 0`); the **mastercopy is inert** — assert ALL six wired fields are zero (`mc.operator()`,
    `mc.engineSafe()`, `mc.ichiVault()`, `mc.gauge()`, `mc.token0()`, `mc.token1()` all `== address(0)`) and every
    entrypoint reverts `NotOperator`, and a second `setUp` on a clone reverts (the zodiac `initializer` one-shot).
  - **zero-amount reverts:** `addLiquidity(0, 0, …)`, `stake(0)`, `unstake(0)` each revert `ZeroAmount`.
  - **`_exec` bubbles (unit):** a mock vault whose `deposit` reverts with a known custom error → `addLiquidity`
    bubbles that exact error (not a generic `ExecFailed`), and a no-data revert path falls back to `ExecFailed`.
  - **reentrancy / state disposition (state, don't hand-wave):** the module **writes NO storage in any mutating
    path** (no `currentUid`-style live state like 8-B14 — `stakedBalance`/`lpBalance` are pure live reads from the
    gauge + vault), targets are wired/trusted (the ICHI vault + gauge + the two wired tokens), and the deposit
    `to`/balance reads are the literal `engineSafe` — so classic reentrancy is low-risk; **the report MUST state the
    no-storage-in-the-mutating-path property explicitly** (it is the load-bearing reason). No user-supplied arrays →
    no gas-griefing surface. Approvals are **exact-amount** (never `type(uint256).max`) and reset to 0 in the same
    tx, bounding any trusted-target-upgrade approval-window risk.
  - **no regression:** the full suite green (prior count + these).
- Code committed under `contracts/src/supply/szipUSD/LpStrategyModule.sol` +
  `contracts/test/LpStrategyModule.t.sol`, kept. Mapped to `audit/2.md` (an L-step: the harvest cycle's
  add→stake→unstake→re-stake; N-steps: non-operator / zero-amount / slippage-floor revert) + an `audit/3-results.md`
  authority row — **audit-sweep obligation, below.**

**Depends on**
- **8-B1 substrate** (the engine Safe; unit-tested against a recording mock Safe, fork-tested against the real
  summoned Safe). · **zodiac-core `Module`** (8-B14/8-B5). · the local **`IICHIVault`/`IGauge`** interfaces (kept,
  on-chain-verified). · the **stand-in posture** (our zipUSD/xALPHA ICHI vault + ALM gauge do not exist until the
  POL pool + Hydrex gauge whitelist land — `hydrex.md §9.4/§10`; fork-test against a real ICHI vault + mock gauge).
- **Downstream:** 8-B5 (calls `unstake(slice)` before `postCollateral`, `stake(slice)` after `withdrawCollateral`);
  8-B7 (claims the gauge oHYDX the staked LP earns); 8-B13 (Mode-C compound: adds **single-sided zipUSD** via
  `addLiquidity(zip, 0, …)` + `stake` — the xALPHA leg accrues from pool flow, not a deposit); 8-B11 (the CRE op
  surface drives all three entrypoints); 8-B12 (monitors
  `stakedBalance`/`lpBalance`); item-10 deploy (CREATE2-clone via `ModuleProxyFactory`, `enableModule` on the engine
  Safe, `setUp` with the real `ichiVault` + the `Voter.gauges(ourPool)`-resolved `gauge`, `owner = TimelockController
  != operator`, init-lock the mastercopy; wire the CRE workflow as the module operator).

**Inbound cross-ticket obligations discharged by this ticket**
None owed by 8-B6 in `PROGRESS.md → Open cross-ticket obligations` (the rows are owed by items 3/5/6/10/CRE/
Exit-Gate/SzipNavOracle/8-B5/WOOF-00/WOOF-06 — confirm with the spec-fidelity critic). 8-B6 is a downstream consumer
and creates new obligations (below).

**New cross-ticket obligations this item creates** (log in `PROGRESS.md` at Conclude)
- **(owed by item-10 deploy)** resolve + wire the `gauge` via `Voter.gauges(ourPool)` with the **hard gate
  `Voter.gauges(ourPool) != 0`** — the gauge MUST be a Hydrex **`ALM_ICHI_UNIV3`-type** gauge created for our pool
  (`Voter.createGauge(ourPool, ALM_ICHI_UNIV3)`, an external Hydrex-governance whitelist dependency, `hydrex.md
  §9.4`); deploy/create the **single-sided zipUSD** POL ICHI YieldIQ vault (`createICHIVault(zipUSD, true, xALPHA,
  false)` — only zipUSD depositable; the xALPHA leg accrues from pool flow, NOT a deposit); CREATE2-clone the module,
  `enableModule` on the engine Safe, `setUp` it, init-lock the mastercopy, wire the CRE operator.
- **(owed by 8-B11 / CRE track)** the CRE strategy robot is the sole caller of `addLiquidity`/`stake`/`unstake`; it
  sizes `minShares` (the slippage floor) off the same reserve×price math `SzipNavOracle` uses, and sequences the
  unstake→re-stake around the 8-B5 borrow loop within the epoch (the staked/collateral-exclusivity, §4.5.1).
- **(owed by 8-B10)** the zipUSD leg of any `addLiquidity` must be **backed** zipUSD (minted only via 8-B10's
  free-value path / the §4.5 zap), never unbacked — the module does not mint; the CRE robot funds the Safe.

**Audit-sweep obligation (this item creates it)**
Author the harvest cycle's LP lifecycle into `audit/2.md` Phase L (an L-step: operator `addLiquidity` → `stake` →
[harvest off-harness] → `unstake` slice → [8-B5 loop] → `stake` re-stake, with `stakedBalance`/`lpBalance`
round-tripping; N-steps: non-operator / zero-amount / slippage-floor each revert) + the matching `audit/3-results.md`
authority row (operator-only entrypoints; `setAvatar`/`setTarget` locked to owner; deposit `to`/balance reads pinned
to the engine Safe; the module holds no custody). Author once the engine is integration-testable (alongside
8-B7…B13 + item-10 deploy), like the 8-B5 / Exit-Gate audit sweeps. Touch `audit/*` only as a consequence of this
build landing.
