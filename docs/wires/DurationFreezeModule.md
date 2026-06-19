# DurationFreezeModule — Duration-Bond trigger B / structural juniorTrancheSidecar freeze (wiring map)

> Source of truth = the kept code at `contracts/src/supply/szipUSD/DurationFreezeModule.sol` +
> `contracts/src/interfaces/supply/{ISeniorPool,ISzipNavBasket}.sol`. Ticket
> `tickets/sodo/DurationFreezeModule.md` + report `reports/DurationFreezeModule-report.md` are intent —
> the code is final. (PROGRESS `DurationFreezeModule` row + row 320; spec §11-B / §6.4 / §8.2.)

## Role
The §11-B / §6.4 / §8.2 duration-squeeze freeze actuator: a zodiac-core `Module` (`is Module,
ReentrancyGuard`) and the **first engine module enabled on BOTH Safes** — the free-equity (ragequit-target)
**main** Safe and the non-ragequittable **juniorTrancheSidecar** Safe — because the freeze moves value across them. It is
the Duration-Bond **trigger B**, a pure LIQUIDITY squeeze: no realized loss, no xALPHA premium/slash, no
markdown, no Exit-Gate/DefaultCoordinator coupling.

Two operator-gated rotations, no recipient parameter (source/dest are the literal set-once Safes):
- **`commit(asset, amount)`** — MAIN→SIDECAR, **ungated by value**. Raising the freeze is always peg-safe, so
  an unbounded commit can freeze 100% (the intended squeeze). Over-commit is operator grief, not theft (the
  §12 metric-4 alarm watches it).
- **`release(asset, amount)`** — SIDECAR→MAIN, **autonomously floor-gated**: reverts unless the juniorTrancheSidecar still
  holds at least `requiredCommittedValue()`. This is the `DefaultCoordinator`
  "bounds-not-validates" pattern — the operator chooses which/how-much; the contract bounds the release value
  on-chain so even a compromised operator cannot open the run hatch while debt is outstanding.

**FLOOR (STRUCTURAL — no governed knob, §17):** the floor is pinned 1:1 to the senior LIABILITY in absolute
dollars, NOT a fraction of the junior basket: `requiredCommittedValue = min( illiquidSeniorValue, grossBasketValue )`
where `illiquidSeniorValue = (convertToAssets(balanceOf(warehouse)) − maxWithdraw(warehouse)) × 1e12` (the lent-out
senior USDC, 6-dp→18-dp). Because the liability does not move when `grossBasketValue` shrinks, the re-leveling
drain (sell the free side → lower the floor → release → loop) has **no denominator to game**. The floor is exactly
the lent-out senior dollars, live-marked — there is NO `coverageBps`/`dollarBuffer` knob (the earlier Phase-1 knobs
were removed 2026-06-16; the §17 "structural, not a governed knob" lock is now satisfied in code; the live oracle
mark already reacts to xALPHA price moves so a static over-collateralization buffer was redundant).
`utilization()`/`requiredFraction()` are RETAINED only as the §12 liquidity-run metric — they no longer gate
`release`.

**COVERAGE NUMERATOR = `committedValue() + pathLockedLpEquity()` (2026-06-13).** The
floor is checked against `coverageValue() = committedValue() + pathLockedLpEquity()`, NOT `committedValue()`
alone — the fenced ICHI LP (most of the basket) backs the floor IN PLACE, read from the oracle's
`pathLockedLpEquity()`, so it need not be physically hoarded in the juniorTrancheSidecar (this RESOLVES the former line-74
LP gotcha — see Gotchas). `release` reads `coverageValue()` post-move; `covered() = coverageValue() >=
requiredCommittedValue()` is the outflow predicate; `lpBurnKeepsCovered(lpShares)` is the dissolution-gate
helper. Both outflow gates are BUILT + armed at deploy: `SzipBuyBurnModule.postBid` reverts while
`!covered()`, and `LpStrategyModule.removeLiquidity` reverts `Undercovered` past the excess (each wires a
Timelock-settable `coverageGate` -> this module; kill-switch = `setCoverageGate(0)`). The draw-gate is SKIPPED
(junior over-collateralized). The module gates the Exit Gate **structurally** — by what value is
held out of the main Safe at exit time — with **no ExitGate change** (the Gate's windowed in-kind ragequit
reaches only the free main Safe). zipUSD never freezes (junior-only).

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `DurationFreezeModule` (`is Module, ReentrancyGuard`) | The actuator. `setUp` initializer (clone-safe set-once storage, NOT immutable); `commit`/`release` rotations; the floor + coverage math (`illiquidSeniorValue`, `requiredCommittedValue`, `committedValue`, `grossBasketValue`, `freeValue`, `pathLockedLpEquity`, `coverageValue`, `covered`, `lpBurnKeepsCovered`; `utilization`/`requiredFraction` retained as §12 metric); the 5-leg `onlyValued` whitelist (LP NOT movable — fenced in place); 11 onlyOwner (Timelock) setters (the 6 wired addrs + 5 legs — NO coverage knobs; the floor is structural). |
| `ISeniorPool` (`interfaces/supply/`) | Venue-neutral local interface for the §8.2 senior pool (CTR-10a — the generalization of the removed `IEulerEarnUtil`) — exactly the three views the donation-immune `U`/`illiquidSeniorValue` read needs: `maxWithdraw(owner)`, `convertToAssets(shares)`, `balanceOf(account)`. EulerEarn satisfies it directly (source `reference/euler-earn/src/EulerEarn.sol`, 0.8.26 — never compiled, fork-only). The `eulerEarn` storage slot name is retained (Euler is config one); only the read interface is generic. |
| `ISzipNavBasket` (`interfaces/supply/`) | Minimal local interface for the `SzipNavOracle` seam: `grossBasketValue()` / `committedValue()` / `freeValue()` / `pathLockedLpEquity()` / `lpShareValue(uint256)` (18-dp USD) for the floor + coverage, plus the five movable plain-leg getters `zipUSD()/usdc()/xAlpha()/hydx()/oHydx()` (read LIVE at `setUp` to form the whitelist). The GPL oracle is not imported. |

## Wiring — internal
- **`setUp(bytes initParams)`** (one-shot via zodiac-core `initializer`; ALL wired fields are plain set-once
  storage, NOT `immutable` — a `ModuleProxyFactory` clone shares the mastercopy runtime so `immutable` can't
  carry per-clone config). Decodes seven addresses `(owner_, juniorTrancheSafe_, juniorTrancheSidecar_, operator_,
  navOracle_, eulerEarn_, warehouse_)`. Guards: every address non-zero
  (`ZeroAddress`); `owner_ != operator_` (`OwnerIsOperator` — Timelock owner must not equal the hot operator
  key); `juniorTrancheSafe_ != juniorTrancheSidecar_` (`BadParams` — equal Safes make a rotation a self-transfer that trivially
  passes the floor). Sets
  `avatar = target = juniorTrancheSafe_` (the inherited single-avatar exec is **inert** — rotations use explicit
  `ISafe(src)` calls, not the avatar-bound path), writes the six wired addresses, then reads the five movable
  legs LIVE off `ISzipNavBasket(navOracle_)` (`zipUSD/usdc/xAlpha/hydx/oHydx`), and finally
  `_transferOwnership(owner_)` (Timelock). Reading the legs from the oracle makes the whitelist == exactly
  what the oracle prices — no drift, five fewer setUp args.
- **`commit(asset, amount)`** — `nonReentrant onlyValued(asset)`; `msg.sender == operator` (`NotOperator`);
  `amount != 0` (`ZeroAmount`). Snapshots `IERC20(asset).balanceOf(juniorTrancheSidecar)`, calls
  `ISafe(juniorTrancheSafe).execTransactionFromModule(asset, 0, transfer(juniorTrancheSidecar, amount), 0)` (Call, `value==0`),
  reverts `ExecFailed` if false, asserts the juniorTrancheSidecar delta `== amount` (`TransferShortfall` — the
  FoT/false-return defense), emits `Committed(asset, amount, committedValue())`. NO value floor/ceiling.
- **`release(asset, amount)`** — same gates; transfers `ISafe(juniorTrancheSidecar).execTransactionFromModule(asset, 0,
  transfer(juniorTrancheSafe, amount), 0)`, asserts the main delta `== amount`. THEN **THE FLOOR**, read AFTER the
  move (the revert atomically rolls the transfer back): `floor = requiredCommittedValue()`,
  `c = coverageValue()` (= `committedValue() + pathLockedLpEquity()` — the fenced LP backs the floor in place);
  `if (c < floor) revert FreezeFloorBreach(c, floor)`. Emits `Released(asset, amount, c, floor)`.
- **The donation-immune `U` read** — `utilization()` (18-dp, in `[0,1e18]`):
  `sa = convertToAssets(balanceOf(warehouse))`; if `sa == 0` → 0; `free = maxWithdraw(warehouse)`; if
  `free >= sa` → 0; else `u = (sa - free) * 1e18 / sa`. This is `U = 1 −
  maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` — the **illiquid fraction of the senior
  backing** read off the senior pool. It **NEVER** reads `balanceOf(eulerEarn)`: EulerEarn is a pure
  allocator (`totalAssets = Σ expectedSupplyAssets`, idle ≈ 0), so a `balanceOf` read is both broken
  (`U ≈ 1` permanently, bricks release) and donatable (anyone could lower `U` → lower the floor → open the
  run hatch). `requiredFraction()` simply returns `utilization()` — the whole formula, already clamped, no
  `min`/`max`, no escalation.
- **The 5-leg oracle whitelist** — `onlyValued(asset)` reverts `UnvaluedAsset` unless `asset ∈
  {zipUSD, usdc, xAlpha, hydx, oHydx}`. Load-bearing fix for the non-basket-asset leak (security #6): a
  `release` of an oracle-unvalued asset would drain the juniorTrancheSidecar **without** moving `committedValue()`, so the
  floor would pass while real value exits the freeze. Whitelisting to exactly the priced legs also closes the
  rebasing/FoT concern.
- **The `SzipNavOracle` views it relies on** — `committedValue() = _grossValueOf(juniorTrancheSidecar)`,
  `freeValue() = _grossValueOf(juniorTrancheSafe)`, and `pathLockedLpEquity()` (the fenced LP across all states net
  reservoir debt). `grossBasketValue`/`_grossValueOf` now COUNT the escrow-collateralized LP + SUBTRACT the
  reservoir strike debt (LP path-lock, 2026-06-13) — so they are no longer "unchanged", but the module still
  never moves the LP, so `grossBasketValue` stays rotation-invariant under a `commit`/`release` (which only
  move the 5 plain legs). The coverage numerator the floor checks is `coverageValue() = committedValue() +
  pathLockedLpEquity()`; `requiredCommittedValue()` is the debt-pinned floor (FLOOR note above) —
  `min( illiquidSeniorValue, grossBasketValue )`
  (a `gross == 0` basket floors to 0 — any release allowed). `lpBurnKeepsCovered(lpShares) =
  (coverageValue − lpShareValue(lpShares)) >= requiredCommittedValue` is the LP-dissolution gate's predicate.
- **Timelock-settable wiring (build phase, §17)** — eleven `onlyOwner` wiring setters, one per wired field
  (`setJuniorTrancheSafe`/`setJuniorTrancheSidecar`/`setOperator`/`setNavOracle`/`setEulerEarn`/`setWarehouseSafe` + the five legs
  `setZipUSD`/`setUsdc`/`setXAlpha`/`setHydx`/`setOHydx`), each zero-guarded and emitting
  `WiringSet(slot, value)`. There are NO coverage-param setters — the floor is structural
  (`min(illiquidSeniorValue, grossBasketValue)`); the `setCoverageBps`/`setDollarBuffer` knobs + the
  `CoverageParamSet` event were REMOVED 2026-06-16 (§17 "not a governed knob"). (The ICHI LP `setIchiVault` setter
  was also REMOVED — the LP is fenced in place, not a movable whitelist asset.) `setOperator` additionally re-checks `operator != owner` (`OwnerIsOperator`,
  SEC-15) so a re-point cannot collapse the Timelock owner and the CRE operator into one key. The CRE operator (hot
  key) cannot call them — only the Timelock owner. Inherited
  `setAvatar`/`setTarget` are onlyOwner and INERT for rotation (rotation uses the explicit set-once
  `ISafe(juniorTrancheSafe)`/`ISafe(juniorTrancheSidecar)` calls, not the avatar-bound exec); they are not hard-locked (that would
  require marking vendored zodiac-core setters `virtual`).

## Wiring — cross-component (who points at whom)
- **→ `SzipNavOracle`** (`navOracle`). The module reads `grossBasketValue()` (the rotation-invariant
  denominator), `committedValue()` (the juniorTrancheSidecar floor target), and the five movable-leg addresses (at
  `setUp`). The oracle already reads BOTH Safes' balances, so `committedValue()` = the juniorTrancheSidecar's holdings and
  the juniorTrancheSidecar xALPHA leg (grown by the 8-Bx `slashXAlphaToCohort` in-kind premium) accretes the frozen
  cohort's NAV pari-passu (the §4.6 / PROGRESS row 368 obligation).
- **→ EulerEarn senior pool + CreditWarehouse** (`eulerEarn`, `warehouseSafe`). `utilization()` reads
  `eulerEarn`'s ERC4626 views with `warehouseSafe` (the Safe holding the senior EulerEarn shares) as the
  `owner`/account arg — the donation-immune illiquid-fraction read off the controller-gated borrow side.
- **Rotates value main Safe ↔ juniorTrancheSidecar Safe.** `commit` calls `execTransactionFromModule` on `juniorTrancheSafe`
  (source) to push to `juniorTrancheSidecar`; `release` calls it on `juniorTrancheSidecar` (source) to push back to `juniorTrancheSafe`. The
  module holds no custody — the Safes hold the tokens — and both Safes must have this module enabled for the
  respective rotation to succeed.
- **Gates the Exit Gate structurally.** No call into `ExitGate`; the coupling is purely "the committed slice
  lives in the non-RQ juniorTrancheSidecar," so the Gate's window exit reaches only the free main equity. At steady-state
  high utilization (~80%) a windowed ragequit pays only the unfrozen slice (windowed RQ is wind-down-only;
  the impatient steady-state exit is CoW).
- **Sidecar must have `isOwner(team) == true` before funding** (8-B1 F6.2 discharge / PROGRESS row 320).
  `commit` is the only juniorTrancheSidecar-funding path and **fails closed**: `execTransactionFromModule` on the juniorTrancheSidecar
  reverts until the module is enabled on the team-owned juniorTrancheSidecar. Item-10 enables on the juniorTrancheSidecar only after
  `isOwner(team)` (8-B1's `_addOwnerToSidecar` lands it; the juniorTrancheSidecar ships Baal-only until then).

## Item-10 deploy facts
- **PROGRESS row 320 (F6.2) DISCHARGED.** Do NOT route value into the juniorTrancheSidecar until `isOwner(team) == true`
  on it. `commit` is the only juniorTrancheSidecar-funding path and fails closed (juniorTrancheSidecar `execTransactionFromModule`
  reverts) until the module is enabled on the team-owned juniorTrancheSidecar; the fork test proves the enable-on-both
  path. (The "item 9" in that row is baal-spec §8's internal numbering for THIS freeze/rotation module — NOT
  the PROGRESS-backlog item 9 `ZipRedemptionQueue`, which touches no juniorTrancheSidecar.)
- **Enable on BOTH Safes.** Enable the module on the main Safe; enable on the juniorTrancheSidecar **only after**
  `isOwner(team)` on the juniorTrancheSidecar (so the team has proven it can drive the juniorTrancheSidecar). Both enables are required
  before any `commit`/`release` round-trip.
- **CREATE2-clone + `setUp`.** The mastercopy is locked AUTOMATICALLY by its constructor (`MastercopyInitLock`,
  SEC-14) the instant it is deployed — NO separate deploy-time lock step, and `setUp` on the mastercopy reverts
  `AlreadyInitialized`; per-line/per-deploy instances are `ModuleProxyFactory` clones whose `setUp` writes the
  set-once storage. Pass
  `owner_ = Timelock`. Wire the warehouse/navOracle/eulerEarn reads via the `setUp` tuple; the five legs are
  derived LIVE from `navOracle` (not passed).
- **Oracle-consumer re-point reconcile.** This module holds a set-once `navOracle` (settable by the Timelock
  via `setNavOracle`). The branch `SzipNavOracle` setters are Timelock-re-pointable by design (oracles are
  replaceable — deploy multiple / hot-fix one; memory `oracle-replaceable-timelock-wiring`). On an oracle
  swap, item-10 either re-points `navOracle` via `setNavOracle` or re-clones the module — and must reconcile
  the DefaultCoordinator "set-once `defaultCoordinator`" thesis (logged in Open spec gaps before item-10).
- **Live-pool U donation-immunity verification (the CRITICAL's residual).** EulerEarn is mocked until
  item-10; confirm the production EVK strategy-cash donation surface is bounded (donating into a strategy
  vault's cash to raise `maxWithdraw` is the weaker, costly residual vector) — same deferral as 8-Bx /
  WOOF-04/05.
- Post-asserts: warehouse/navOracle/eulerEarn wired correctly; `owner() == Timelock`; module enabled on both
  Safes; the §12 metric-4 over-commit alarm wired as the operator-grief watch.

## Gotchas
- **CRITICAL build-surfaced + fixed: the v1 `idle = balanceOf(eulerEarn)` U-read was wrong.** It read
  `idle = IERC20(usdc).balanceOf(eulerEarn)`, `U = (totalAssets − idle)/totalAssets` — both **broken**
  (EulerEarn `totalAssets = Σ expectedSupplyAssets` excludes idle, which is ≈0 → `U ≈ 1e18` permanently →
  `release` bricked forever) and **donatable** (anyone transfers USDC to the pool → inflate idle → lower
  `U` → lower the floor → over-release that drains the juniorTrancheSidecar and opens the run hatch, defeating §11-B
  "not outsider-manipulable"). Fixed to the donation-immune `U = 1 −
  maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` read; spec **§8.2 / §11-B** corrected (the
  "U = borrowed/totalAssets … idle" framing was the spec's own root error).
- **Oracle setters are Timelock-re-pointable by design**, not set-once-renounce-frozen — confirmed intended
  2026-06-09 (oracles are replaceable). The DefaultCoordinator set-once thesis must be reconciled before
  item-10.
- The whole security shape is the SECURITY BOUNDARY: the operator supplies ONLY `(asset, amount)`; the module
  builds all calldata, source/dest are the literal set-once `juniorTrancheSafe`/`juniorTrancheSidecar` (no recipient param, no
  generic exec/delegatecall, `value == 0`). A compromised operator can grief (over-commit, delaying exits)
  but cannot steal and cannot under-freeze.
- The release floor is read AFTER the transfer; the `FreezeFloorBreach` revert atomically rolls the move back
  (balances + committedValue restored).
- `requiredFraction == utilization` is the final kept form. The report/§11-B escalation
  (`U_lock`/`U_max`/`maxLockFraction`) describes the as-first-built version — it was STRIPPED from the
  contract (NatSpec-only mention remains); do not treat it as live.
- **RESOLVED 2026-06-13 (LP path-lock) — the two problems raised 2026-06-12:**
  1. **Threat model clarified, not obviated.** The exit topology (ExitGate mints/burns only, CoW-only exits,
     `burnFor` pays nothing out) does close the *ragequit* drain. But the freeze floor was REPURPOSED: it is
     now the debt-pinned COVERAGE floor (`requiredCommittedValue = f(illiquidSeniorValue)`) that keeps the
     junior backing the senior LIABILITY — and the same `covered()` predicate gates the two real outflows
     (buy-burn `postBid`, LP `removeLiquidity`). So the freeze has a concrete, current job: keep coverage ≥
     the outstanding-debt floor, and freeze outflow when it dips (incl. price-drift).
  2. **The LP-unreachable / unsatisfiable-floor problem is GONE — by counting, not moving.** Resolution =
     NONE of the old candidate fixes (don't whitelist the LP, don't make `commit` unwind it, don't trust the
     CRE to keep zipUSD un-LP'd). Instead: the LP stays fenced in place (NOT movable) and is COUNTED toward
     the floor via the oracle's `pathLockedLpEquity()` (LP across loose+gauge+escrow states, net reservoir
     debt). The coverage numerator is `coverageValue() = committedValue() + pathLockedLpEquity()`, so the
     floor is satisfiable from the productive LP without hoarding it idle in the juniorTrancheSidecar. The LP's only
     dissolution path (`LpStrategyModule.removeLiquidity`) is coverage-gated to the excess, so it can't be
     liquefied below the floor. This supersedes the former "movable whitelist (LP excluded)" framing entirely.
