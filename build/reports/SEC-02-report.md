# SEC-02 report — Coverage sidecar-LP double-count (kill-list Group 2: M2 / L14 / L1)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE
**Ticket:** `build/tickets/sec/SEC-02-coverage-sidecar-lp-double-count.md`

## What the window did
Scoped `SzipNavOracle.pathLockedLpEquity()` (`contracts/src/supply/SzipNavOracle.sol:388-392`) to **mainSafe-only**:
```solidity
function pathLockedLpEquity() public view returns (uint256) {
    uint256 lpValue = _lpValue(_lpShares(mainSafe));   // was _lpShares(mainSafe) + _lpShares(sidecar)
    uint256 debt = _reservoirDebt(mainSafe);            // was _reservoirDebt(mainSafe) + _reservoirDebt(sidecar)
    return lpValue > debt ? lpValue - debt : 0;
}
```
The freeze module's coverage numerator is `coverageValue() = committedValue() + pathLockedLpEquity()`.
`committedValue()` = `_grossValueOf(sidecar)` already values the sidecar's LP + subtracts its reservoir debt, so the
old both-Safes `pathLockedLpEquity` counted the **sidecar LP a second time**. Now each Safe's LP + debt is counted
exactly once: sidecar legs are owned by `committedValue`, mainSafe legs by `pathLockedLpEquity`. All path-locked LP
across both Safes is still covered (single-count, not exclude). Docstring updated to state the mainSafe-only scope.

Added 3 regression tests to `SzipNavOracleParityTest` in `test/DurationFreezeModule.t.sol` (chosen because that suite
already wires the **real** `SzipNavOracle` — the double-count is a real-computation bug, not reproducible against the
settable `MockNavBasket`):
- `test_SEC02_sidecar_lp_single_counted` — donating 50e18 sidecar LP shares raises the coverage numerator by exactly
  one mark (`lpShareValue(50e18) = 15e18`); `pathLockedLpEquity` stays at the mainSafe 30e18.
- `test_SEC02_partition_gross_minus_coverage_eq_pm` — `grossBasketValue − coverageValue == Pm` (mainSafe free liquid
  legs) within the ≤2-wei pro-rata tolerance.
- `test_SEC02_floor_breach_covered_flips_false` — real `DurationFreezeModule` + real oracle + `MockEulerEarn` (debt
  floor 100e18): single-counted coverage 95e18 < floor → `covered() == false` and `lpBurnKeepsCovered(1e18) == false`.

## Gate (green)
```
forge build  -> clean (No files changed, compilation skipped)
forge test   -> 767 passed; 0 failed; 3 skipped (770 total)   [3 skips = pre-existing DeployZipcode.t.sol]
forge test --match-test SEC02 ->
  [PASS] test_SEC02_floor_breach_covered_flips_false()      (gas: 3887384)
  [PASS] test_SEC02_partition_gross_minus_coverage_eq_pm()  (gas: 728730)
  [PASS] test_SEC02_sidecar_lp_single_counted()             (gas: 720352)
```
**Fail-before / pass-after verified:** reverting the one-line scope reproduces all 3 failures with the exact
double-count signature — `110 != 95` (coverage), `30 != 15` (one extra sidecar mark), partition gap `15 > 2`.

## Decisions to sanity-check
1. **Test home = `SzipNavOracleParityTest` (in `DurationFreezeModule.t.sol`), not `SzipNavOracle.t.sol`.** That suite
   was purpose-built for the oracle's additive cross-view parity and is the only place that already stands up the real
   oracle next to a reachable real `DurationFreezeModule`. The `covered()` flip (the ticket's named consequence) needs
   both, so co-locating all 3 SEC02 vectors there keeps the fixture single. Reasonable, but if a reviewer expects the
   oracle's own suite to carry an oracle regression, the single-count + partition vectors could be mirrored there.
2. **`covered()` flip exercised against the real module, not asserted on a hand-computed floor.** I deploy a real
   `DurationFreezeModule` (view-only — not enabled on a Safe, since `covered()`/`requiredCommittedValue()` are pure
   reads of the oracle + EE) rather than inlining the `>= floor` comparison. Stronger integration signal; the cost is a
   module deploy in the test.

## Holes → resolution
- None load-bearing. The fix is internal to one oracle view; no module signature, event, or interface changed, so no
  downstream binding moved. The full 767-test suite (incl. the existing freeze/oracle/parity/invariant suites) is the
  proof that `committedValue`/`freeValue`/`grossBasketValue` and the §11-B accounting are untouched.

## Doc edits
- `SzipNavOracle.sol:383-392` docstring rewritten ("across BOTH Safes" → mainSafe-only, with the SEC-02 rationale).
- Ticket done note + `PROGRESS.md` ("Just done — SEC-02", table → DONE, NEXT → SEC-03) updated.
- No `build/claude-zipcode.md` change (spec under-defined nothing here; this was a contract-vs-contract double-count).

## Status + NEXT
SEC-02 DONE. **NEXT = SEC-03 (H4 — CCIP admin handoff):** `transferAdminRole`(964→ccipAdmin, Base→timelock) + accept
runbook + `pendingAdministrator` assert. Ticket: `build/tickets/sec/SEC-03-ccip-admin-handoff.md`. Continue the
correctness-first SEC order (03 → 04 → … → 15 → SEC-DOC).
