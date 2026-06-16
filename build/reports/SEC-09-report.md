# SEC-09 report — `RecycleModule.divert` cumulative hole bound (M7)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-10
(`setLpTwapWindow(>0)` Algebra plugin/init validation, L2).

## What the window did
Closed kill-list **M7** / audit **interconnection-C2**: `RecycleModule.divert` bounded the diverted USDC only
**per-call** against the live junior hole (`provision()`), but `divert` never writes `provision` (the CRE reduces
it later via `DefaultCoordinator.Recovery`). So between provision re-marks, several diverts that each passed the
per-call check **cumulatively over-filled** the hole — up to N×P of junior free-value drained into senior backing
for a single P markdown. Operator-trusted (grief, not theft), but a real seam gap.

**Fix (1 contract, `contracts/src/supply/szipUSD/RecycleModule.sol`):**
- Added `uint256 public lastSeenProvision;` + `uint256 public divertedSinceProvisionChange;` (both 18-dp USD).
- `divert`: after the `hole == 0`/`NoHole` check and before the spend — reset-on-change
  (`if (hole != lastSeenProvision) { lastSeenProvision = hole; divertedSinceProvisionChange = 0; }`), compute
  `scaled = usdcAmount * 1e12`, and **replace** the per-call `:290` check with the cumulative
  `if (divertedSinceProvisionChange + scaled > hole) revert ExceedsHole();` (strict `>`, exact cumulative fill
  allowed). Tally bumped `divertedSinceProvisionChange += scaled;` right after `_spendFreeValue`, before the first
  value-moving `_exec` (effects-phase / CEI). `_spendFreeValue` untouched; divert still never writes `provision`.
- Docstring rewritten (per-epoch guarantee + sentinel-0 note); fixed stale `SzipNavOracle.sol:102`→`:135` ref.

**Tests (`contracts/test/RecycleModule.t.sol`, `RecycleModuleDivertTest`):** 5 new `test_SEC09_*` —
cumulative-over-fill-blocked, exact-fill-and-one-wei-over, reset-on-re-mark-allows-fresh-budget,
stale-value-re-mark-does-not-resurrect-tally, divert-never-writes-provision.

## Gate
- `forge build` clean.
- `forge test` **796 passed / 0 failed / 3 skipped** (+5 over SEC-08's 791; the 3 skips are the pre-existing
  `DeployZipcode.t.sol` scaffold). The 13 existing divert tests stayed green — the cumulative check is strictly
  tighter than the old per-call check, so it never loosens a previously-passing case.
- **Fail-before/pass-after:** reverting `divert` to the old per-call check (no tally) makes
  `test_SEC09_cumulative_overfill_blocked` FAIL (`tally tracks the first divert: 0 != 60000000000000000000000`);
  restoring the fix → passes.
- Cold-build returned **zero load-bearing guesses**.

## Decisions to sanity-check
1. **Mechanism = last-seen + single counter, NOT value-keyed.** The audit's `fix:` line floated
   `divertedAgainst[hole]`; the kill-list explicitly corrected this (a `$100→$80→$100` re-mark resurrects a stale
   value-key tally). The implemented `lastSeenProvision` + one running counter is churn-safe. Confirmed correct by
   the spec-fidelity critic walking the stale-churn scenario.
2. **Reset on ANY observed change (shrink OR grow), to 0.** A partial Recovery (hole shrinks, stays nonzero) gives
   a fresh budget against the new smaller hole; a new markdown (hole grows) also resets. The spec-fidelity critic
   confirmed resetting-to-0 on any change is the right call (a shrink-only reset would wrongly strand budget after
   a markdown grows) and that the resulting **cross-re-mark over-supply is possible but benign** — extra USDC
   backing only strengthens the peg, and every spend is hard-capped by the finite CRE-credited `freeValueAccrued`
   plus the trusted single CRE writer (§17). This is documented in the `divert` docstring + the `8-B10` wire doc as
   a **per-provision-epoch** guarantee, so an auditor doesn't read "can never over-fill" as a global invariant.
3. **`lastSeenProvision == 0` as "never observed" sentinel** is safe because `hole == 0` reverts `NoHole` before
   the reset block — `lastSeenProvision` can never legitimately be set to 0. No separate `bool seeded` flag needed.

## Holes → resolution
- **Junior-dev blocker (increment placement, "alongside `_spendFreeValue`").** Resolved in the ticket: the bump
  goes in `divert` immediately after the `_spendFreeValue(usdcAmount)` call and before the first `_exec`, NOT
  inside the shared `_spendFreeValue` (which `recycle` also calls). Implemented that way.
- **SEED ledger-bound interaction.** `divert` is also bounded by `freeValueAccrued` (rig `SEED = 1_000_000e6`);
  a test using a hole `H ≥ SEED*1e12` would trip `InsufficientFreeValue` before `ExceedsHole`. Folded into the
  ticket; the new tests use `H = 100_000e6 * 1e12 < SEED*1e12`.
- **Existing divert suite.** Verified (and run) green — the cumulative check is strictly tighter, so the existing
  per-call boundary / two-bounds / CEI / overflow / shortfall tests all still pass.

## Doc edits (doc-sync-checklist)
1. Ticket `sec/SEC-09-*.md` → DONE + Done-note with quoted `forge test` output; folded in the three critic findings
   (placement, SEED caveat, existing-suite safety) + the corrected `:135` cite.
2. `PROGRESS.md` → SEC-09 DONE, SEC-10 set NEXT (both the NEXT block and the SEC-track table), "Just done — SEC-09" note.
3. `kill-list.md` → M7 `[ ]`→`[x]` + `DONE 2026-06-15 (SEC-09)`.
4. `audit-claude/` → interconnection-C2 + SUMMARY.md M7 marked RESOLVED with the fix line.
5. `wires/8-B10-RecycleModule.md` → the `divert` bounds list rewritten to the cumulative tally (reset-on-change,
   effects-phase bump, per-epoch guarantee), renumbered; stale `:102`→`:135` ref fixed.
6. **No `claude-zipcode.md` spec change** — interface-level fix; §8.4/§11 intent (divert bounded by the live hole)
   unchanged; this fences the across-calls gap the spec implicitly assumed away.

## Status
**DONE.** Gate green, doc-sync complete, code committed. **NEXT: SEC-10.** No new obligation/seam, no back-pressure.
