# SEC-02 — Coverage sidecar-LP double-count (Group 2: M2 / L14 / L1)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 2 (M2, absorbs L14 + the
real part of L1); `build/coverage-floor.md`, `build/lp-path-lock.md`; audit `findings.md` (M2),
`interconnection-findings.md` · **Status:** DONE (2026-06-15)

> Scope authored 2026-06-15. One fix resolves M2, L14 (same root — the cross-view `freeValue` vs
> `gross − coverageValue` desync), and the real content of L1 (L1's "gross-cap bricks exits" DoS was
> overturned as a non-bug; its only real defect is this double-count).

## Deliverable
Scope the oracle's `pathLockedLpEquity()` to **mainSafe-only** so the coverage numerator counts each
Safe's LP (and reservoir debt) exactly once.

## What it does / what's being fixed (plain language)
The freeze module's coverage floor is checked against `coverageValue() = committedValue() +
pathLockedLpEquity()`. `committedValue()` already values the sidecar Safe's holdings **including its
LP**; `pathLockedLpEquity()` then sums LP across **both** Safes — so the sidecar's LP is counted twice.
That inflates `covered()` / `lpBurnKeepsCovered()`, letting `removeLiquidity` / `release` / `postBid`
proceed when the basket is actually **below** the coverage floor. Permissionless to trigger: anyone can
donate ICHI-LP shares into the sidecar Safe to pump the inflated number.

## Binds to (verified file:line — 2026-06-15)
- **Fix site:** `contracts/src/supply/SzipNavOracle.sol:386-390` — `pathLockedLpEquity()`. Today:
  `_lpValue(_lpShares(mainSafe) + _lpShares(sidecar))` minus `_reservoirDebt(mainSafe) +
  _reservoirDebt(sidecar)`. Scope both to **mainSafe-only**: `_lpValue(_lpShares(mainSafe))` minus
  `_reservoirDebt(mainSafe)`.
- **Why mainSafe-only is correct:** `committedValue()` = `_grossValueOf(sidecar)` (`:359-360`) already
  adds `_lpValue(_lpShares(sidecar))` (`:376`) and subtracts `_reservoirDebt(sidecar)` (`:377-378`). So
  the **sidecar** LP + debt are owned by `committedValue`; the **mainSafe** LP + debt are owned by
  `pathLockedLpEquity`. Summed in `coverageValue()`, each leg is counted exactly once and ALL
  path-locked LP across both Safes is still covered.
- **Consumers (unchanged, read-through):** `DurationFreezeModule.sol` — `pathLockedLpEquity()` `:312-314`
  (delegates to the oracle), `coverageValue()` `:319-320`, `covered()` `:358-360`,
  `lpBurnKeepsCovered()` `:367-372`. The fix is purely in the oracle's computation; no module signature
  changes. The only other reference is the interface `ISzipNavBasket.sol:22` (no change).

## Key requirements
1. Edit **only** `SzipNavOracle.pathLockedLpEquity()` (`:386-390`) → mainSafe-only for both the LP-share
   sum and the reservoir-debt subtraction. Keep the saturating `lpValue > debt ? lpValue - debt : 0`.
2. **Land it in the oracle view (read by `coverageValue`), NOT in `committedValue`.** Touching
   `committedValue` / `_grossValueOf` would corrupt `freeValue()` (`= gross − committedValue`,
   `DurationFreezeModule.sol:303-306`) and the §11-B Committed/Released event accounting.
3. Update the `pathLockedLpEquity()` docstring (`:381-385`) to state it is **mainSafe-only** (sidecar LP
   is owned by `committedValue`) — the current "across BOTH Safes" wording becomes wrong.

## Do NOT
- Do NOT change `committedValue`, `freeValue`, `_grossValueOf`, `grossBasketValue`, or any event.
- Do NOT remove the LP from the coverage numerator — it must still back the floor (`build/lp-path-lock.md`);
  the fix is single-count, not exclude.
- Do NOT touch L1 as a standalone "gross-cap DoS" — that disposition was overturned (operator drives
  `Pm→0` via `commit()`, no ceiling). L1's only real content is this double-count.
- Do NOT widen scope to any other kill-list group.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC02_*` regression test** that fails before / passes after:
  - **Double-count regression:** donate `N` ICHI-LP shares into the **sidecar** Safe; assert
    `coverageValue()` rises by **exactly one** LP mark (`lpShareValue(N)`), not two. (Pre-fix it rises by
    ~2× — via both `committedValue` and `pathLockedLpEquity`.)
  - **Floor-breach regression:** construct a state where the inflated (pre-fix) `coverageValue()` reports
    `covered() == true` while the single-counted value is **below** `requiredCommittedValue()`; assert
    `covered()` is `false` after the fix (and the analogous `lpBurnKeepsCovered()` tightens).
  - **Partition invariant (L1 verify note):** assert `grossBasketValue() == coverageValue() +
    (mainSafe free liquid legs)` within the ≤2-wei per-Safe pro-rata-floor tolerance documented at
    `SzipNavOracle.sol:354-358` — i.e. `gross − coverageValue == Pm` holds after M2.
- Quote the actual `forge test` output in this ticket's done note.

## Depends on
- None. (Independent of SEC-01.) On land: `PROGRESS.md` "Just done — SEC-02" with the finding note.

---

## Done note (2026-06-15)
**Fix applied — `SzipNavOracle.pathLockedLpEquity()` (`:388-392`) scoped to mainSafe-only:**
`_lpValue(_lpShares(mainSafe))` minus `_reservoirDebt(mainSafe)` (was `mainSafe + sidecar` for both). The
sidecar's LP + debt are already owned by `committedValue()` (`_grossValueOf(sidecar)`, `:372-381`), so
`coverageValue() = committedValue + pathLockedLpEquity` now counts every Safe's LP exactly once. Docstring
updated to state the mainSafe-only scope + the SEC-02 rationale. **Nothing else touched** — `committedValue`,
`freeValue`, `_grossValueOf`, `grossBasketValue`, and all events are byte-for-byte unchanged (Key req 2 / Do-NOT).

**Regression (3 new `test_SEC02_*` in `SzipNavOracleParityTest`, `test/DurationFreezeModule.t.sol`)** — that
suite already wires the REAL `SzipNavOracle`, so the genuine double-count is exercised (not a settable mock):
- `test_SEC02_sidecar_lp_single_counted` — donate 50e18 sidecar LP shares; coverage numerator rises by
  **exactly one** mark (`lpShareValue(50e18) = 15e18`, 80→95), and `pathLockedLpEquity` is unchanged at 30e18
  (mainSafe-only). Pre-fix it rose by 30e18 (two marks).
- `test_SEC02_partition_gross_minus_coverage_eq_pm` — `grossBasketValue − coverageValue == Pm` (mainSafe free
  liquid legs, 40e18) within the ≤2-wei pro-rata tolerance. Pre-fix the gap was off by one sidecar mark (15e18).
- `test_SEC02_floor_breach_covered_flips_false` — REAL `DurationFreezeModule` + REAL oracle + `MockEulerEarn`
  (debt floor 100e18): single-counted coverage 95e18 < floor → `covered() == false` (breach surfaces) and
  `lpBurnKeepsCovered(1e18) == false`. Pre-fix the double-counted 110e18 cleared the floor and `covered()` lied.

**Fail-before / pass-after confirmed:** reverting the one-line scope reproduces all 3 failures with the exact
double-count signature (`110 != 95`, `30 != 15`, `gap 15 > 2`); restoring passes.

**Gate green:**
```
forge build  -> No files changed, compilation skipped (clean)
forge test   -> 767 passed; 0 failed; 3 skipped (770 total)
             (the 3 skips are the pre-existing DeployZipcode.t.sol skips; +3 new SEC02 over SEC-01's 764)
forge test --match-test SEC02 ->
  [PASS] test_SEC02_floor_breach_covered_flips_false()      (gas: 3887384)
  [PASS] test_SEC02_partition_gross_minus_coverage_eq_pm()  (gas: 728730)
  [PASS] test_SEC02_sidecar_lp_single_counted()             (gas: 720352)
```

**No back-pressure, no spec change, no new obligation.** The fix is internal to the oracle view; no module
signature, event, or interface (`ISzipNavBasket`) changed. SEC-03 (H4 — CCIP admin handoff) is now NEXT.
