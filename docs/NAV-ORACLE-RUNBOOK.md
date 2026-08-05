# NAV oracle — operator runbook (emergency levers)

Written 2026-08-05. The part a human executes at 3am when a `SzipNavOracle` dependency regresses. The
mechanics and rationale live in the NatSpec and `docs/wires/8-B4-SzipNavOracle.md`; this file is the
step-by-step. Every lever here is a Timelock (`onlyOwner`) action.

Both scenarios below share one first move — **halt issuance without touching exits** — because the
recovery transiently changes NAV and a deposit in that window mints at the wrong price. Exits (the CoW
buy-burn) are deliberately never gated on this; do not try to pause them.

**Halt issuance:** `ExitGate.setTvlCap(1)` (any value at/below current gross). A deposit then reverts
`TvlCapExceeded` because `grossBasketValue() + value > cap`; `setTvlCap` does not read NAV, so it works
even while NAV reads are frozen. Restore the real cap once recovered. There is no separate pause switch
by design — the cap IS the issuance gate.

---

## Lever A — the farm-utility escrow/borrow vault view regressed

**Symptom.** `convertToAssets` or `debtOf` on the escrow or borrow vault reverts. That freezes
`_accumulate()` and therefore EVERY NAV read — `grossBasketValue`, `spot`/`twapNavPerShare`,
`navEntry`, `navExit`, `committedValue`, `freeValue`. NAV is fully frozen; deposits already revert.

**Steps.**
1. `ExitGate.setTvlCap(1)` — halt issuance (belt-and-braces; deposits already fail while NAV is frozen,
   but you are about to un-freeze it in an understated state).
2. `SzipNavOracle.setFarmUtilityLeg(0, 0)` — the atomic unset. Drops the escrow-collateralized LP AND
   its strike debt from the basket, so NAV reads resume. Note it now reads LOW by the loop equity (an
   entry-side arb if issuance were open — that's why step 1 comes first).
3. Re-wire `setFarmUtilityLeg(escrowVault, borrowVault)` as soon as the vault view is healthy again,
   then restore the real `tvlCap`. Both-or-neither: a mixed zero/non-zero pair reverts.

**Why there is no on-chain guard for this.** The obvious "refuse to unset while debt is outstanding"
check would have to call `debtOf` on the very vault that is reverting — it would revert too and lock you
out of the escape hatch. The safety has to live in this sequencing.

---

## Lever B — the LP TWAP plugin died or stopped writing

**Symptom.** `_lpValue → fairReserves` reverts, so NAV, exits, buy-burn, the freeze coverage reads, and
the EVK farm-utility collateral price all halt (including liquidation of that position). Two shapes: the
Algebra plugin is dead/uninitialized (`_assertLpTwapReady` fails), or it is alive but has stopped writing
recent timepoints (`LpTwapNoRecentTimepoint` — the fair-LP history gate).

**Do NOT reach for `setLpTwapWindow(0)`.** While an LP is wired it reverts `LpWiredCannotUseSpot` (the
0c-b fix — falling back to manipulable spot when the plugin is down would hand an attacker the mark for
most of NAV). And `setLpTwapWindow(non-zero)` re-asserts plugin readiness, so it cannot re-arm on a dead
plugin either. Neither is an escape anymore.

**Steps — pick one.**
1. `ExitGate.setTvlCap(1)` — halt issuance.
2a. `SzipNavOracle.setLpPosition(newVault, newGauge)` onto a pool whose plugin is live and recently
    writing. The setter re-asserts readiness against the new vault, so a healthy target passes and NAV
    resumes; **or**
2b. unwind the LP via `LpStrategyModule.removeLiquidity` (ungated since 0c-c) until `_lpShares == 0`, at
    which point `_lpValue` returns 0 and NAV resumes with the LP gone. Use this when there is no healthy
    pool to re-point to.
3. Restore the real `tvlCap` once NAV reads cleanly.

---

## After either recovery

Confirm before restoring the cap: `grossBasketValue()`, `navEntry()`, `navExit()`, and `fresh()` all
return without reverting, and `spotNavPerShare()` matches the expected post-recovery value (not the
transient understated one from a mid-recovery read).
