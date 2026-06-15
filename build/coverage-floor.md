# Coverage Floor — debt-denominated freeze (kills the re-leveling drain)

## Problem (verified)

`DurationFreezeModule.requiredCommittedValue()` floors `release` at a **junior-proportional**
amount:

```
requiredCommittedValue = requiredFraction() * grossBasketValue() / 1e18   // src/supply/szipUSD/DurationFreezeModule.sol:294
requiredFraction()     = utilization()                                    // :273
utilization()          = (sa - free) * 1e18 / sa,  sa=convertToAssets(balanceOf(warehouse)), free=maxWithdraw(warehouse)  // :260
```

`grossBasketValue()` is read live (`SzipNavOracle.sol:273`) and is **invariant under a rotation but
not under an exit**. So an operator who can shrink the basket (buy-and-burn the free side, bounded by
`buybackCap`/senior liquidity) lowers the floor proportionally and releases frozen value, then loops:

```
gross 1,000,000 -> 100,000   =>   floor 100,000 -> 10,000   =>   release 90,000   =>   repeat
```

The floor is denominated in the **junior basket** but defends a **senior liability**. They diverge
exactly when the junior shrinks. The proportionality is the bug.

## Fix — Phase 1: absolute, debt-denominated release floor (self-contained)

Replace the proportional floor with an **absolute** one pinned to the lent-out senior dollars (the
real liability the junior backs). Reuse the inputs `utilization()` already reads — no enumeration, no
new wiring.

### DurationFreezeModule changes

New governed params (Timelock-settable, `WiringSet` pattern, build phase §17):

| param | type | meaning |
|---|---|---|
| `coverageBps` | `uint256` | required coverage of the liability, 1e4 = 100% (>=1e4 over-collateralizes) |
| `dollarBuffer` | `uint256` | 18-dp USD absolute minimum first-loss added on top of the liability |

New view — the absolute liability (18-dp USD; senior asset is USDC 6-dp, scale `* 1e12`):

```solidity
/// @notice Lent-out (illiquid) senior dollars = the absolute liability the junior backs.
///         Numerator of utilization(); donation-immune (reads the warehouse position, never
///         balanceOf(eulerEarn)). 18-dp USD.
function illiquidSeniorValue() public view returns (uint256) {
    IEulerEarnUtil e = IEulerEarnUtil(eulerEarn);
    uint256 sa = e.convertToAssets(e.balanceOf(warehouse)); // USDC 6-dp
    uint256 free = e.maxWithdraw(warehouse);                // USDC 6-dp
    if (free >= sa) return 0;
    return (sa - free) * 1e12;                              // -> 18-dp USD
}
```

Redefine the floor (the `max(%, $)` form — the larger, most conservative; capped at gross because you
cannot freeze more than exists):

```solidity
function requiredCommittedValue() public view returns (uint256) {
    uint256 debt  = illiquidSeniorValue();
    uint256 pct   = debt * coverageBps / 1e4;   // % coverage
    uint256 abs   = debt + dollarBuffer;         // $ coverage
    uint256 floor = pct > abs ? pct : abs;
    uint256 gross = grossBasketValue();          // via navOracle
    return floor < gross ? floor : gross;
}
```

`utilization()`/`requiredFraction()` are **kept** as the §12 liquidity-run metric (the alarm surface),
but no longer gate `release`. `release`'s post-move check (`DurationFreezeModule.sol:323-334`) is
unchanged in shape — it still reads `committedValue()` vs `requiredCommittedValue()`; only the floor's
definition changed.

### Why this kills the drain

`debt` is read off the senior pool and does not move when the junior basket shrinks. Shrinking
`grossBasketValue` can only lower the floor once `floor > gross` (i.e. the junior is already
under-collateralized, at which point release is the wrong action anyway). The release loop has no
denominator left to game. No reliance on `buybackCap` or markdown timing.

### The floor is a VALUE floor — outflow must be gated on BOTH sides

`committedValue()` is a live USD mark of the sidecar (`SzipNavOracle.sol:300`). The floor is therefore
a **value** floor, not a quantity floor — and the sidecar's value moves with mark prices, not only with
commit/release. This gives the three target rules:

1. **non-rq value drops (e.g. sidecar holds xALPHA that falls)** -> it must absorb more (`commit`) until
   `committedValue() >= requiredCommittedValue()` again.
2. **non-rq value rises above the floor** -> `release` is allowed down to the mark.
3. **at minimum, 100k debt -> always 100k of value frozen** (`coverageBps = 1e4`, `dollarBuffer = 0`).

But rule 1 is NOT automatic under a release-only gate. A **price drop** pushes `committedValue()` below
the floor with no `release` call, and `commit` is operator-discretionary — nothing claws it back. That
reopens "under-freeze by neglect," the exact grief vector the absolute floor was meant to close.

Fix: the coverage condition gates **every outflow**, not just `release`. Define one predicate

```solidity
function covered() public view returns (bool) {
    return committedValue() >= requiredCommittedValue();
}
```

and require `covered()` (read AFTER the move, atomic-rollback on breach) on:

- `release` (sidecar -> main) — already does this; unchanged.
- **free-side exit** (buy-and-burn bid post / redemption) — block while `!covered()`.
- **draw** (`ZipcodeController`, Phase 2) — block while `!covered()` or while the new debt would breach.

Then a price drop doesn't auto-commit, but it **freezes all outflow** until the sidecar is topped back
up — which forces the absorb. Rules 1-3 become mechanical, not operator-cooperative.

Wiring note: the buy-and-burn gate lives in `SzipBuyBurnModule.postBid` (the §7 bid is the free-side
outflow), reading the freeze module's `covered()`. That is a new supply-side wire (buy-burn -> freeze
module); fold it into the same Phase-1 deploy step that wires the two new params.

### Buffer composition — back debt with stable value

Rule 1 only fires because the frozen buffer holds **volatile** xALPHA. Two mitigations, pick per book:

- **Freeze stable legs.** Commit USDC/zipUSD to the sidecar to back debt; keep xALPHA on the free side.
  The buffer doesn't drift, rule 1 rarely triggers, and the `covered()` gate stays slack in normal ops.
- **Over-collateralize.** `coverageBps > 1e4` (e.g. `12000` = 120%) sizes the buffer to absorb expected
  xALPHA vol before it breaches the debt mark.

Operationally this is CRE commit policy (which legs land in the sidecar), not a contract constraint —
the whitelist still allows all five legs + LP. Document it as the §12 keeper playbook, and consider a
metric-alarm when the sidecar's volatile fraction exceeds a threshold.

### Interaction with the markdown (`provision`)

`provision` (`SzipNavOracle.sol:102`, sole writer `DefaultCoordinator`, M2) is the **loss-recognition**
lever and stays orthogonal. Note the floor reads **gross** (not net-of-provision): a recognized loss
lowers NAV-per-share (exiters eat it) but must NOT mechanically relax the freeze — the liability is
still outstanding until the cash returns. Cap-at-gross handles the insolvent edge (`floor > gross`):
the sidecar simply holds everything it has.

## Fix — Phase 2: draw-time coverage gate — capacity = zipUSD-in-NAV

Enforce the hard cap **continuously** instead of only at origination: a draw may not push total debt
above what the junior can actually back. The capacity number is **not total NAV** — it is the
**zipUSD content of the basket only**.

```
borrowCapacity = zipUSDValue()                     // standalone zipUSD + the zipUSD leg of the LP, @ $1
require illiquidSeniorValue() + drawAmount <= borrowCapacity     // else revert Undercovered
```

### Why zipUSD only, not NAV

The basket is mostly the zipUSD/xALPHA ICHI LP, so a large slice of NAV is **xALPHA** — the volatile,
reflexive reward token that drops exactly in the stress it would need to cover. **xALPHA is yield, not
coverage.** Only the stable leg counts. If ~30% of the basket is xALPHA, ~70% is zipUSD, so **max
utilization tops out around 70%** — by construction, not by a tuned cap.

### Why this can't be gamed (the conservation argument)

zipUSD is minted exactly one way: `USDC -> EulerEarn senior -> mint`. Trading the zipUSD/xALPHA pool
**moves** zipUSD between standalone and LP; it never **creates** it. So:

- Selling xALPHA into the pool for zipUSD is `net new zipUSD = 0` -> **capacity unchanged.** Share value
  may rise (more xALPHA in the basket), borrow room does not. Yield, not coverage — again.
- Dumping xALPHA into the POL pool swaps the *vault's* zipUSD for the dumper's xALPHA, so measured
  `zipUSDValue()` *drops* -> capacity *drops* (defensive, correct). It's an emissions-dilution /
  coverage-quality nuisance bounded by pool slippage, never a capacity inflation. The meter only moves
  the safe way.

### Two build notes

- **No forced deleveraging.** A capacity drop blocks *new* draws only. Existing debt is term debt with
  borrowers — it cannot be clawed back mid-term. Falling xALPHA tightens the front door; it does not
  unwind anything already out.
- **Read `zipUSDValue()` off a TWAP/conservative reserve, not spot.** The LP's zipUSD leg comes from
  `IICHIVault.getTotalAmounts()` — a spot read a one-block sandwich could flash up to approve a draw,
  then revert. Bracket it the way `SzipNavOracle.navPerShare` already brackets (`min(spot, twap)` for
  the capacity read).

### Where the math lives (the one decision to settle before building Phase 2)

The controller is demand-side; the NAV oracle + senior reads are supply-side.

- **A. Controller reads the primitives directly** — add `navOracle` + `eePool`/`warehouse` as
  Timelock-settable wiring on the controller. Simple, duplicates the coverage math.
- **B. A shared `CoverageGuard` view** — one source of `illiquidSeniorValue` / `zipUSDValue` / coverage
  math, read by BOTH the freeze module (release floor) and the controller (draw gate). No drift.

`zipUSDValue()` is a NEW oracle view (standalone zipUSD + LP zipUSD leg, TWAP-bracketed) needed only by
Phase 2; the Phase-1 floor caps at `grossBasketValue()` and does not depend on it. Recommendation: ship
Phase 1 first; pick B for Phase 2 if more consumers appear (multi-venue, dashboards), A if it stays just
these two.

## Status

**Phase 1 SHIPPED (2026-06-13) — `DurationFreezeModule`, 49/49 green:**

- `illiquidSeniorValue()`, `coverageBps`/`dollarBuffer` (Timelock-settable, default `1e4`/`0`),
  `requiredCommittedValue()` redefined to the debt-pinned `min(max(pct, debt+buffer), gross)`, `covered()`.
- `release` floor now reads the debt-pinned value; `utilization()`/`requiredFraction()` retained as the §12
  metric only. Deploy wires `1e4`/`0`; the stateful invariant (`release_never_breached_floor`) holds over
  128k calls. New unit test `requiredCommittedValue_invariant_to_basket_shrink` pins the anti-drain property.

**ALSO SHIPPED (2026-06-13) — the LP path-lock + both outflow gates, `build/lp-path-lock.md`:**

- LP lifecycle valuation (escrow-collateral leg + reservoir-debt subtraction in the NAV oracle); `covered()`
  numerator is now `committedValue() + pathLockedLpEquity()` (the fenced LP backs the floor in place).
- `covered()` gate on free-side outflow — `SzipBuyBurnModule.postBid` reverts while `!covered()` — BUILT.
- LP-dissolution gate — `LpStrategyModule.removeLiquidity` reverts `Undercovered` past the coverage excess
  (`DurationFreezeModule.lpBurnKeepsCovered`) — BUILT. Both gates armed at deploy (Timelock kill-switch kept).

**Deferred (NOT built) — user-triaged 2026-06-13:**

- Phase 2 draw gate in `ZipcodeController` + the `zipUSDValue()` oracle view (capacity = zipUSD-in-NAV).
  **SKIPPED** — the junior is over-collateralized (xALPHA+zipUSD net > USDC lent); don't over-restrict origination.
- FCFS -> pro-rata exit flip on impairment — **DEFERRED**: no "loan is bad" signal until a default-timeout
  ("marked bad after X") mechanism exists; depends on the M2 `DefaultCoordinator`.
- Shared `CoverageGuard` refactor — **SKIPPED**: no duplication today (the freeze module is the single
  coverage source via the `ICoverageGate` seam).

## Out of scope / documented

- True per-line debt aggregation (sum `observeDebt` over an enumerable line set, includes accrued
  interest) is the precise-but-heavier alternative to the senior-illiquidity proxy. Only needed if
  `sa - free` ever diverges from outstanding principal (other senior cash sinks). Not the case in the
  current single-warehouse topology; revisit if the senior pool gains non-draw outflows.
