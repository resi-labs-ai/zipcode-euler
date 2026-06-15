# LP path-lock — frozen-by-fence, valued-in-place

## STATUS — BUILT 2026-06-13 (166/166 tests green across the four suites)

- **Slice 1 (oracle):** `grossBasketValue`/`_grossValueOf` count the escrow-collateralized LP + subtract
  reservoir debt; new `pathLockedLpEquity()` + `lpShareValue()`; `escrowVault`/`borrowVault` wiring +
  `setReservoirLeg` (Timelock); deploy wires it in P8. Proven NAV-invariant across a `postCollateral`+`borrow`
  cycle. `ISzipNavBasket` exposes both new views.
- **Slice 2 (freeze coverage):** `DurationFreezeModule.coverageValue() = committedValue() +
  pathLockedLpEquity()`; `covered()` + the release floor use it; the ICHI LP is REMOVED from the movable
  whitelist (fenced in place — resolves the former line-74 gotcha). A release now clears on LP coverage that
  `committedValue` alone would breach.
- **Slice 3 (dissolution gate):** `DurationFreezeModule.lpBurnKeepsCovered(shares)`; `LpStrategyModule`
  gains a Timelock-settable `coverageGate` + `removeLiquidity` reverts `Undercovered` when it would dissolve
  floor-backing LP (excess-bound).
- **Slice 4 (exit gate):** `SzipBuyBurnModule.postBid` reverts `Undercovered` while `!covered()` (settable
  `coverageGate`).

**ARMED AT DEPLOY (2026-06-13, default-on).** The gates are wired LIVE at construction: `DurationFreezeModule`
is now cloned at the TOP of `DeployZipcode._phaseP6` (before the consumers), and its address is passed into
`LpStrategyModule.setUp` (5->6 args) and `SzipBuyBurnModule.setUp` (9->10 args) as their `coverageGate`,
asserted by two `SeamCoverageGate` checks. `DeployLocal` inherits this (gate live in the anvil smoke deploy
too). Both `setCoverageGate` setters remain — the **Timelock kill-switch**: `setCoverageGate(0)` disables in
one tx, and re-points if the freeze module is redeployed. The gate is transparent at zero senior debt
(`floor = min(debt, gross) = 0 -> covered() == true`), so genesis / no-lien states + the harvest loop (NOT
gated) are unaffected. **Verified:** `forge build` clean; **175/175** tests green incl. the buy-burn /
lp-strategy / freeze FORK suites on a real Base fork (RPC); and a full `DeployLocal` run on a fresh Base fork
at the pinned block **ran successfully** — both `SeamCoverageGate` asserts passed, confirming the gates are
wired LIVE at deploy (`lpStrategy.coverageGate() == buyBurn.coverageGate() == durationFreeze`). Note: the
deploy uses a fixed EulerEarn salt, so re-running on a *dirty* anvil collides in provisioning (`createEulerEarn
failed`) — run on a fresh fork. Skipped: items 2 (draw gate), 3 (FCFS->pro-rata / default-timeout), 4
(standalone CoverageGuard).

---


Companion to `build/coverage-floor.md`. The freeze floor (Phase 1) assumes the committed buffer is liquid
tokens in the sidecar. In steady state it is NOT: most junior value is the zipUSD/xALPHA ICHI LP, **staked
in the Hydrex gauge earning oHYDX**, on the engine Safe. You cannot freeze that by hoarding it idle in the
sidecar — that kills the flywheel and is the unsolved `DurationFreezeModule` line-74 gotcha. This spec
defines "frozen" for the LP as **path-locked + valued-in-place**, grounded against the contracts that move
it (read in full, not grepped — the earlier draft's "no dissolution path" claim was a grep miss and is
retracted below).

## Foundation — what we already have (read-checked)

**Everything productive runs on the engine Safe (`= mainSafe`, the Baal avatar).** The sidecar holds only
`DurationFreezeModule`. So the LP, the loop, the swaps, and the buy-burn all live on the *main* Safe; the
sidecar is just a frozen-liquid-leg box.

LP states, and who moves the LP between them (all operator-gated, all pinned to the engine Safe):

| state | mover | oracle sees it? |
|---|---|---|
| staked in the gauge | `LpStrategyModule.stake/unstake` (`IGauge.deposit/withdraw`) | YES — `gauge.balanceOf(safe)` (`SzipNavOracle.sol:319`) |
| unstaked LP share in the Safe | same | YES — `ichiVault.balanceOf(safe)` |
| posted as reservoir collateral | `ReservoirLoopModule.postCollateral/withdrawCollateral` (`escrowVault`, receiver pinned, debt==0 gate) | **NO** — `escrowVault.balanceOf(safe)` unread |
| (reservoir USDC debt vs it) | `ReservoirLoopModule.borrow/repay` (`borrowCap` F1, `ReservoirBorrowGuard` pins OP_BORROW to the Safe) | **NO** — `debtOf(safe, borrowVault)` unsubtracted |
| dissolved to zipUSD + xALPHA | `LpStrategyModule.removeLiquidity` (`IICHIVault.withdraw`, to=Safe, slippage-bounded) | YES (as plain legs) but no longer LP |

Two corrected foundational facts:

1. **The LP -> cash pipeline EXISTS BY DESIGN and is operator-callable, UN-coverage-gated.** It is the
   wind-down feeder: `unstake` -> `LpStrategyModule.removeLiquidity` (LP -> zipUSD + xALPHA;
   `LpStrategyModule.sol:231-241`) -> `SellModule.sellXAlpha` (xALPHA -> zipUSD; explicitly "the
   post-`removeLiquidity` unstrand hop", `SellModule.sol:236-256`) -> zipUSD -> senior par queue (OffRamp +
   `ZipRedemptionQueue`) -> USDC -> `SzipBuyBurnModule` bid + `ExitGate.burnFor`. Every step is operator-
   gated, slippage-bounded (`minOut`/`minShares`), and recipient-pinned to the engine Safe — but **the
   aggregate is not bounded by coverage.** `removeLiquidity`'s NatSpec says "wind-down only, NO live-ops
   caller" — that is a *convention, not an enforced gate*. (SellModule's "NO LP" dev-note means it never
   *custodies the LP share*; `sellXAlpha` very much handles the *decomposed legs* — the earlier draft
   misread this.)
2. **The bounds that exist are local, not aggregate.** `borrowCap` (F1) bounds the loop's USDC draw;
   `ReservoirBorrowGuard` pins the borrow to the engine Safe; `SellModule.sellHydx` has a `maxSellHydx`
   per-call size cap — but **`removeLiquidity` and `sellXAlpha` have NO size cap** (only price/slippage).
   So an operator can liquefy the whole LP in slices. Value does not *leave the Safe* by dissolving (it just
   changes form LP -> legs -> USDC); exfiltration is gated downstream at the exit (buy-burn `postBid`). But
   dissolution converts **path-locked** value into **exitable** value, so the fence must be enforced **at
   the dissolution**, not assumed from absence.

So the gaps are: (a) **honest valuation** of the LP mid-loop, and (b) a **coverage gate at the dissolution
chokepoint** so only the excess above the floor can be liquefied.

## The reframe — "frozen" is not "in the sidecar"

The Phase-1 model (frozen value = sidecar) is right for the **liquid legs** (they can reach an exit, so they
are physically held out). It is wrong for the LP: relocating staked LP into the sidecar kills its oHYDX
emissions (line-74). The LP is frozen by being **fenced** — its dissolution gated to the excess — not by
being relocated. Fact #1 says the fence is not free; the gate is the mechanism.

Coverage is therefore redefined as **value that cannot reach an exit without passing a coverage gate**,
regardless of which Safe holds it:

```
pathLockedLpEquity = value( ichiVault.balanceOf(s) + gauge.balanceOf(s)
                          + escrowVault.convertToAssets(escrowVault.balanceOf(s)) )   // LP in every state
                   − debtOf(s, borrowVault) × 1e12                                    // net of the strike debt
coverageValue      = committedValue()            // sidecar liquid legs, fully frozen (Phase 1)
                   + pathLockedLpEquity           // the fenced LP on the engine Safe, counted in place
covered()          = coverageValue >= requiredCommittedValue()        // the debt-pinned floor from Phase 1
```

The LP stays staked and productive and counts toward the floor because the gates below stop it reaching an
exit. When xALPHA drops, `pathLockedLpEquity` falls, the excess (`coverageValue − floor`) shrinks on its
own, and both gates tighten automatically. **No physical scoot into the sidecar.**

## The spec — valuation, one gated chokepoint, one invariant

### 1. Lifecycle-complete LP valuation (oracle)

`SzipNavOracle._grossValueOf` / `grossBasketValue` read `ichiVault.balanceOf + gauge.balanceOf` (the staked +
loose LP). Add, on the engine-Safe side:

- the **escrow-collateral leg**: `escrowVault.convertToAssets(escrowVault.balanceOf(safe))` -> LP amount ->
  priced via the existing `getTotalAmounts()` pro-rata + `_tokenValue(token0/token1)` path already in
  `grossBasketValue` (`SzipNavOracle.sol:279-292`);
- the **reservoir-debt subtraction**: `IBorrowing(borrowVault).debtOf(safe) × 1e12` (USDC 6dp -> 18dp).

New Timelock-settable wiring: `escrowVault`, `borrowVault` (re-pointable, §17; `== 0` -> contributes 0, the
same fail-safe as the `ichiVault == 0` guard). This closes the **bidirectional** mid-loop blind spot:
`postCollateral` currently makes NAV *under*-read (escrow LP unseen) while `borrow` makes it *over*-read (the
borrowed USDC is counted but its debt is not). Expose `pathLockedLpEquity()` so the freeze module's
`covered()` can add it to `committedValue()`. (`ReservoirLoopModule` already exposes `postedCollateral()` and
`outstandingDebt()` views — the oracle can read those or the vaults directly.)

### 2. Gate the EXISTING `removeLiquidity` — the single dissolution chokepoint

`removeLiquidity` is the one place path-locked LP becomes exitable liquid (everything downstream —
`sellXAlpha`, the senior queue, buy-burn — only moves already-liquid legs). Gate it; do NOT add a function.
It already is operator-gated, slippage-bounded, and `to`-pinned to the engine Safe — only the coverage bound
is missing:

```solidity
function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1) external onlyOperator ... {
    if (shares == 0) revert ZeroAmount();
    // PATH-LOCK: only the EXCESS above the coverage floor may be liquefied.
    if (coverageValue() - valueOf(shares) < requiredCommittedValue()) revert Undercovered();
    ... existing IICHIVault.withdraw + slippage check
}
```

`valueOf(shares)` reuses the oracle's `getTotalAmounts()` pro-rata mark. This makes the NatSpec's "wind-down
only" claim *true*: with debt outstanding the floor is tight and the excess is ~0, so `removeLiquidity`
reverts `Undercovered`; only as debt amortizes (the floor drops) does material LP become dissolvable — the
lock releases itself.

The downstream exit chokepoint (`SzipBuyBurnModule.postBid`) takes the same `covered()` gate (the deferred
Phase-1 item) so the *liquid* side cannot be drained below the floor either. Two chokepoints, one predicate.

### 3. Path-lock invariant (enforce, don't assume)

- **Egress / dissolution allow-list:** the ONLY movers of the LP share or its escrow position are
  `LpStrategyModule` (stake/unstake/addLiquidity/the now-gated removeLiquidity) and `ReservoirLoopModule`
  (post/withdraw collateral); `SellModule.sellXAlpha` only ever sees legs *already* released past the
  `removeLiquidity` gate. Documented hard invariant: **no new module with an LP-egress or LP-dissolution
  path is enabled on the engine Safe without re-deriving the coverage proof** — same class as the
  `{DurationFreeze}`-only sidecar rule (build/coverage-floor.md), watched the same way (§12).
- **Transient-only:** the LP exists in a Safe's *direct* balance only within an atomic loop tx. A *standing*
  `ichiVault.balanceOf(engineSafe)` outside a loop tx is the anomaly -> §12 metric-alarm.

## Per-contract change list

- `SzipNavOracle.sol` — add `escrowVault` + `borrowVault` wiring (+ setters); extend `_grossValueOf` /
  `grossBasketValue` with the escrow leg + debt subtraction; add `pathLockedLpEquity()`. Keep `== 0 -> 0`.
- `ISzipNavBasket` — expose `pathLockedLpEquity()` so the freeze module reads it.
- `DurationFreezeModule.sol` — `covered()` / the release floor numerator = `committedValue() +
  pathLockedLpEquity` (not `committedValue()` alone); remove the ICHI LP share from the movable whitelist
  (it is fenced in place, never rotated to the sidecar) — supersedes `setIchiVault` and resolves line-74 by
  NOT physically committing staked LP.
- `LpStrategyModule.sol` — **gate the EXISTING `removeLiquidity`** with the excess bound (one `if` + a
  `valueOf(shares)` mark + the coverage read). No new function.
- `SzipBuyBurnModule.sol` — `postBid` reverts while `!covered()` (the exit chokepoint; deferred Phase-1).
- Cross-module read: `LpStrategyModule`, `DurationFreezeModule`, `SzipBuyBurnModule` (and Phase-2's
  controller draw gate) all need the coverage number -> a shared **`CoverageGuard`** view (one definition of
  `coverageValue`/`requiredCommittedValue`, four callers, no drift) is the recommendation over direct reads.

## Test deltas

- Oracle: `grossBasketValue` is invariant across `postCollateral` (LP -> escrow, debt 0) and nets correctly
  after `borrow` (escrow leg added, debt subtracted); `pathLockedLpEquity()` matches a known LP+escrow−debt.
- `LpStrategyModule.removeLiquidity`: reverts `Undercovered` when it would dissolve floor-backing LP
  (excess ~0); succeeds for the excess (slack floor / wind-down); existing slippage + `to`-pin unchanged.
  (Existing tests that dissolve at a tight floor must first set zero debt / a slack floor.)
- `SzipBuyBurnModule.postBid`: reverts while `!covered()`; succeeds once re-covered.
- Path-lock: no module other than the allow-list can move/dissolve the LP; transient-only alarm fires on a
  standing idle LP balance.

## Open decisions

- **`CoverageGuard` (B) vs direct cross-reads (A)** — with four consumers now, B is recommended.
- **Sidecar holds no LP** (recommended): the LP is fenced in place on the engine Safe; the sidecar holds
  only the liquid remainder. Retires the line-74 "unstake-then-commit / sidecar stakes" options entirely.
