# WOOF-06 — ZipDepositModule (the zap) (wiring map)

> **X-Ray (security verdict):** rated **HARDENED** — a stateless, custody-free supply-side router whose
> decisive properties are hygiene (net-zero custody, donation-proof cleanliness, exact-amount approvals, atomic
> rollback), exhaustively proven (29 mock-gate incl. fuzz + 3 real-gate fork). Report:
> `contracts/src/supply/x-ray/ZipDepositModule.md`. ELI20: `docs/supply/ZipDepositModule.md`. This doc is the
> code-truth wiring map.

> Source of truth = the kept code `contracts/src/supply/ZipDepositModule.sol`. Ticket
> `tickets/woof/WOOF-06-deposit-module.md` + report `reports/WOOF-06-report.md` are intent. The seam flipped
> 2026-06-07 to the two-token Gate model; this doc reads the **final code** (the `gate.depositFor` →
> transferable szipUSD seam), not the retired EE-pool-share `stake` seam.

## Role
The supply-side **entry zap** — the only door by which a supplier turns USDC into a protocol position. It is a
**stateless mint+route plumbing layer with NO custody and NO economic decision**: it holds no per-user state,
custodies no assets, and prices nothing (all NAV/pricing lives in the Exit Gate + `SzipNavOracle`). It has no
owner/admin/pause/upgrade surface — the lone privileged action is the deployer-gated, build-phase-resettable
`setGate`. Two entrypoints:

- **`zap(usdcIn)` — THE default UX.** Pull USDC → mint zipUSD **transiently to the module** → hand it to the
  Exit Gate via `depositFor`, which mints **NAV-proportional transferable szipUSD** to the caller. The supplier
  lands directly in the headline junior position and never holds zipUSD or Loot. The USDC is parked into the
  senior backing (the `EulerEarn` pool, shares to the `CreditWarehouse` Safe); the module ends each call
  holding nothing.
- **`deposit(usdcIn)` — the secondary path.** Pull USDC → mint zipUSD **1:1-by-value to the depositor** → park
  the USDC in the venue pool with the warehouse Safe as the share `receiver`. The user walks away with the $1
  utility synth; no szipUSD, no Gate involvement.

In both paths the USDC sinks into `EE_POOL` with the **`CreditWarehouse` Safe** as the EE-share `receiver` — the
"protocol's holding" of senior backing. **The module never holds EE shares, USDC, or zipUSD across a call.**

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `ZipDepositModule` (`is ReentrancyGuard`) | The zap. 4 immutables + derived `scaleUp` + the set-once `gate`. `deposit`/`zap` entrypoints, `previewDeposit`/`previewZap` views, deployer-gated `setGate`. Stateless, no custody. |
| zipUSD (`ESynth`, interfaced as `IESynth`) | The $1 synth (18-dp). The module is a **capacity-granted minter** (`mint(account,amount)`; `mint(·,0)` is a silent no-op, covered by the `ZeroAmount` guard). Local interface only — `reference/euler-vault-kit/src/Synths/ESynth.sol`. |
| `EE_POOL` (`EulerEarn` over USDC, interfaced as `IEulerEarn`) | The USDC sink / senior backing. `deposit(assets, receiver)` pulls USDC from the module, mints shares to `receiver` (= the warehouse). Local interface — `reference/euler-earn/src/EulerEarn.sol:560`. |
| `CreditWarehouse` Safe (`warehouseSafe`) | The EE-share custodian (8-Bw). Passed as the `deposit` `receiver`; holds all EE shares backing un-staked zipUSD. The module never receives shares. |
| Exit Gate (`ExitGate`, interfaced as `IZipExitGate`) | The NAV-proportional issuance core. `depositFor(asset,amount,receiver)→shares` pulls the asset into the junior basket, values it via `SzipNavOracle`, mints soulbound Loot to itself + transferable szipUSD to `receiver`. `previewDeposit(asset,amount)` is the read-only quote. `contracts/src/supply/szipUSD/ExitGate.sol`. |
| USDC | The deposit asset (6-dp). Pulled via `SafeERC20.safeTransferFrom`; approved to `EE_POOL` via `forceApprove`. |

## Wiring — internal

**Constructor** `constructor(address zipUSD_, address usdc_, address eePool_, address warehouse_)`:
- Reverts `ZeroAddress()` if any arg is zero.
- Reads `zipDec = IERC20Metadata(zipUSD_).decimals()` and `usdcDec = IERC20Metadata(usdc_).decimals()`;
  reverts **`DecimalsTooFew()`** if `zipDec < usdcDec` (value-1:1 needs zipUSD the finer unit).
- Sets immutables `zipUSD`, `usdc`, `eePool`, `warehouseSafe`; `deployer = msg.sender`.
- Derives `scaleUp = 10 ** (zipDec - usdcDec)` — **not a hard-coded literal**; for 18-dp zipUSD over 6-dp USDC
  it equals `1e12`.

(Note: an older PROGRESS row describes a 3-arg `ZipDepositModule(ZIPUSD, USDC, EE_POOL)` — the **kept code is
4-arg with the warehouse as the 4th immutable**. Code wins.)

**Gate seam wiring — `setGate(address gate_)`** (the one privileged action):
- `if (msg.sender != deployer) revert NotDeployer();` — deployer-gated.
- `if (gate_ == address(0)) revert ZeroAddress();`
- Stores `gate = gate_`; emits `GateWired(gate_)`. **Grants NO standing allowance** (D1 — the zap approves the
  Gate exact-amount per call; the test asserts `zip.allowance(module, gate) == 0` after wiring).
- **Re-settable** (build phase, §17 — survives a Gate redeploy). Re-freezing to set-once is deferred to
  pre-prod. `gate == address(0)` ⇒ un-wired (`zap`/`previewZap` revert `NotWired`).

**`deposit(uint256 usdcIn)`** (`nonReentrant`) — how zipUSD is minted + USDC parked:
1. `if (usdcIn == 0) revert ZeroAmount();`
2. `IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);`
3. `zipMinted = usdcIn * scaleUp;` then `IESynth(zipUSD).mint(msg.sender, zipMinted);` — **capacity-gated**
   mint **to the depositor**.
4. `IERC20(usdc).forceApprove(eePool, usdcIn);`
5. `IEulerEarn(eePool).deposit(usdcIn, warehouse);` — shares to the warehouse Safe; the module never holds them.
6. `emit Deposited(msg.sender, usdcIn, zipMinted);`

**`zap(uint256 usdcIn)`** (`nonReentrant`) — the `gate.depositFor` seam + zero-residual enforcement:
1. `if (usdcIn == 0) revert ZeroAmount();` and `if (gate == address(0)) revert NotWired();`
2. `IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);`
3. `uint256 zipAmount = usdcIn * scaleUp;` then `IESynth(zipUSD).mint(address(this), zipAmount);` —
   **transient mint to the module** (handed to the Gate below; never escapes to the user as zipUSD).
4. `IERC20(usdc).forceApprove(eePool, usdcIn); IEulerEarn(eePool).deposit(usdcIn, warehouse);` — USDC →
   venue pool, warehouse custodies the shares (same senior-backing park as `deposit`).
5. `IERC20(zipUSD).forceApprove(gate, zipAmount);` — **exact-amount per-zap allowance** (D1).
6. `shares = IZipExitGate(gate).depositFor(zipUSD, zipAmount, msg.sender);` — the Gate pulls the zipUSD by
   `transferFrom` (in the real Gate, routed straight to `juniorTrancheSafe`/the basket), values it via `SzipNavOracle`,
   mints Loot to itself + **transferable szipUSD to the caller**, returns `shares`.
7. **Zero-residual / "holds nothing" enforcement (F1/F7) — never trust the Gate to leave the module clean:**
   - `if (shares == 0) revert ZeroShares();` — fail closed on a no-op/paused Gate.
   - `if (IESynth(zipUSD).balanceOf(address(this)) != 0) revert ResidualBalance();` — the Gate must have pulled
     the **full** `zipAmount`.
   - `IERC20(zipUSD).forceApprove(gate, 0);` — defensively reset the per-zap allowance.
8. `emit Zapped(msg.sender, usdcIn, zipAmount, shares);`

**Previews (read-only — frontend back-pressure):**
- `previewDeposit(usdcIn) → zipMinted` = `usdcIn * scaleUp`. Independent of the Gate (works un-wired).
- `previewZap(usdcIn) → (zipMinted, shares)`: reverts `NotWired` if un-wired; else `zipMinted = usdcIn *
  scaleUp` and `shares = IZipExitGate(gate).previewDeposit(zipUSD, zipMinted)`. **`shares` is an ESTIMATE** —
  NAV moves between preview and tx (the §3 `max(spot,twap)` entry bracket); label it "≈" in the UI.

**Custody invariant.** The module is conservation-clean every call: USDC fully forwarded to `EE_POOL`, zipUSD
either minted to the user (`deposit`) or transiently minted and fully pulled by the Gate (`zap`), EE shares to
the warehouse, szipUSD to the user. A `zap` is one atomic `nonReentrant` tx — a Gate revert rolls back the USDC
pull, both mints, the EE deposit, AND the `forceApprove` together.

## Wiring — cross-component (who points at whom)
- **module → zipUSD (`ESynth`).** The module is a **capacity-granted minter**: item-10 grants
  `ESynth.setCapacity(module, …)`. `mint` reverts (or silently no-ops at 0) without capacity. The 3-arg
  `ESynth` ctor `(EVC, "Zipcode USD", "zipUSD")` fixes zipUSD at **18-dp** (no decimals arg — the source of the
  `scaleUp = 1e12`).
- **module → `EE_POOL` / `CreditWarehouse` Safe.** Both `deposit` and `zap` call `EE_POOL.deposit(usdcIn,
  warehouse)` — USDC sinks to the venue pool, **shares to the warehouse Safe** (8-Bw, §4.5). The module is the
  zap half of the warehouse's senior-NAV wiring (`EE_POOL.convertToAssets(EE_POOL.balanceOf(SAFE))`); the
  redemption queue (§6.1) draws via the warehouse REDEEM, the recovery waterfall (§11/§4.6) via REPAY — the
  module only feeds the deposit side.
- **module → Exit Gate (`depositFor`).** The zap's junior leg. The module pins the Gate via the set-once
  `gate` and calls `gate.depositFor(zipUSD, zipAmount, user)` — the Gate absorbs the retired 8-B2 mint-shaman
  role. The Gate's `previewDeposit(asset,amount) view` was the obligation **this ticket created on the Gate**;
  it was added to the kept `ExitGate` (a pure forwarder to `SzipNavOracle` — `valueOf` ÷ `navEntry`, round-down;
  no new pricing) and is what `previewZap` reads. `reports/WOOF-06-report.md` §A.
- **TVL-cap composition (PROGRESS row 332, item-10 obligation, OPEN).** The Gate carries a **hard immutable
  `tvlCap`** backstop: `depositFor` reverts `TvlCapExceeded` if `navOracle.grossBasketValue() + value >
  tvlCap` (`ExitGate.sol:163`). 8-B12 describes a **dynamic measured `maxDeposit`** as the WOOF-06 deposit
  gate. Item-10 must wire the measured cap **on top of** the Gate backstop and assert they compose (measured ≤
  hard; a deposit blocked by either reverts).
- **Reciprocal one-bank assert with `RecycleModule` (PROGRESS rows 357/375, item-10 obligation, OPEN).** The
  `RecycleModule` (8-B10 recycle path + S1 `divert` path) routes USDC into the **same** senior backing. Item-10
  must deploy-assert `RecycleModule.warehouse == ZipDepositModule.warehouseSafe()` AND `RecycleModule.eePool ==
  ZipDepositModule.eePool()` — **one bank** — else diverted/recycled USDC supplies the wrong pool and never
  fills the warehouse hole (revert the deploy on mismatch). `RecycleModule.recycle` itself mints backed zipUSD
  **only through `ZipDepositModule.deposit`** (USDC parked as senior backing before the mint ⇒ backed 1:1 by
  construction), never `ESynth.mint` directly.

## Item-10 deploy facts (S7, OPEN)
- **ctor:** `new ZipDepositModule(ZIPUSD, USDC, EE_POOL, CREDIT_WAREHOUSE_SAFE)` — 4 args in that order.
  zipUSD = the `ESynth` from the 3-arg ctor `(EVC, "Zipcode USD", "zipUSD")` (18-dp); USDC 6-dp; EE_POOL the
  `EulerEarn` over USDC; the 4th = the deployed `CreditWarehouse` Safe.
- **Capacity grant:** `ESynth.setCapacity(module, …)` — bounded in prod (tests use `type(uint128).max`). The
  module mints zipUSD; without this `mint` no-ops/reverts. Renounce `ESynth` ownership only **after** the
  capacity grants + the wiring (S7 order).
- **Gate seam wiring:** deploy the Exit Gate (item 8), then `module.setGate(GATE)` (deployer-gated,
  build-phase-resettable). Assert `module.gate() == GATE` and `zip.allowance(module, GATE) == 0` (no standing
  allowance, D1).
- **Composition asserts:** wire the measured `maxDeposit` (8-B12) and assert it composes **≤** the Gate's hard
  `tvlCap` (row 332); deploy-assert the **one-bank** equality with `RecycleModule` (warehouse + eePool, rows
  357/375).
- **Build-phase wiring posture:** the cross-component setters are Timelock-settable / build-phase-resettable,
  NOT immutable/set-once (memory `oracle-replaceable-timelock-wiring`); re-freezing is deferred to pre-prod. The
  module's `deployer` (the `setGate` gate) carries no other power; ownership re-pointing is via the Timelock on
  the cross-component contracts, not on the module (the module has no owner).
- **Pre-capacity sanity:** verify `warehouseSafe` (8-Bw Safe) and the Gate exist before granting capacity (a
  re-authored carryover of the original WOOF-06 deploy obligation).

## Gotchas
- **Permit2 fallback.** The module pulls USDC via `SafeERC20.safeTransferFrom` (standard ERC20 allowance) — the
  caller approves the module first; there is **no** Permit2/permit path in the kept code (Permit2 was RESOLVED
  to the plain-ERC20 fallback during authoring). The frontend must issue a standard `approve` before `deposit`/
  `zap`.
- **`scaleUp = 1e12` is derived, not literal.** It is `10 ** (zipDec - usdcDec)` read from the tokens' own
  `decimals()` in the ctor (18 − 6 = 12). All cross-asset value-1:1 (`usdcIn * scaleUp` zipUSD) and any
  zipUSD↔USDC/share conversions carry the same `1e12`. The `DecimalsTooFew()` ctor guard enforces
  `zipDec >= usdcDec`.
- **`mint(·,0)` is a silent ESynth no-op** — harmless here because the `ZeroAmount()` guard rejects `usdcIn ==
  0` before any mint.
- **The zap fails closed.** `ZeroShares` (Gate returned 0 / paused), `ResidualBalance` (Gate under-pulled —
  module still holds zipUSD), `NotWired` (Gate un-wired) all revert the whole atomic tx. The real Gate routes
  the pulled zipUSD to `juniorTrancheSafe` (basket equity immediately), so the module's post-state is zero zipUSD either
  way — the `ResidualBalance` check is the invariant, not where the zipUSD lands.
- **`0.8.24` pin.** Guards use `if (!cond) revert CustomError()` (not the `0.8.26+` `require(cond, Err())`
  form).
