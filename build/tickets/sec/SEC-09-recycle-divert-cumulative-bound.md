# SEC-09 — `RecycleModule.divert` cumulative hole bound (M7)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` M7 (FIX, fix-mechanism CORRECTED); audit
`findings.md` (M7); `build/claude-zipcode.md` §8.4/§11 (provision/recovery) · **Status:** DONE 2026-06-15

## DONE-note (2026-06-15)
**Implemented exactly per the ticket** (`RecycleModule.sol`): added `uint256 public lastSeenProvision;` +
`uint256 public divertedSinceProvisionChange;` (18-dp USD); `divert` now does reset-on-change
(`if (hole != lastSeenProvision) { lastSeenProvision = hole; divertedSinceProvisionChange = 0; }`), computes
`scaled = usdcAmount * 1e12`, and the old per-call `:290` check is REPLACED by the cumulative
`if (divertedSinceProvisionChange + scaled > hole) revert ExceedsHole();` (strict `>`); tally bumped
`divertedSinceProvisionChange += scaled;` immediately after `_spendFreeValue` and before the first value-moving
`_exec`. `_spendFreeValue` untouched; divert still never writes `provision`. Docstring rewritten (per-epoch
guarantee, sentinel-0 note); stale `SzipNavOracle.sol:102` interface-comment ref fixed to `:135`.

**Gate green:** `forge build` clean; `forge test` **796 passed / 0 failed / 3 skipped** (+5 over SEC-08's 791;
the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold). 5 new `test_SEC09_*` in `RecycleModuleDivertTest`:
`cumulative_overfill_blocked`, `exact_cumulative_fill_and_one_wei_over`, `reset_on_remark_allows_fresh_budget`,
`stale_value_remark_does_not_resurrect_tally`, `divert_never_writes_provision`. The 13 existing divert tests stayed
green (the cumulative check is strictly tighter than the old per-call check). **Fail-before/pass-after confirmed:**
reverting `divert` to the old per-call check (no tally) makes `test_SEC09_cumulative_overfill_blocked` FAIL
(`tally tracks the first divert: 0 != 60000000000000000000000` — the second over-fill divert is not blocked);
restoring the fix → passes. **Zero load-bearing guesses** (the cold-builder verified every symbol against source).

**No spec change** (interface-level fix; §8.4/§11 intent unchanged — the spec already prescribed `divert` bounded
by the live hole; this fences the across-calls hole the per-call check left open). **No back-pressure / no new
obligation** (uses the existing `provision()` read + `ExceedsHole`; no contract surface owed).

> Scope authored 2026-06-15. The fix MECHANISM matters: do NOT key a tally by the provision value
> (`divertedAgainst[hole]`) — provision is a single re-markable scalar, so a value key is buggy (a
> `$100 → $80 → $100` re-mark would resurrect the stale tally). Use `lastSeenProvision` +
> `divertedSinceProvisionChange`, reset on any change.

## Deliverable
Bound `divert` **cumulatively** against the live hole across calls (not just per-call), via a running tally
that resets whenever the provision is re-marked — so total diverted USDC can never exceed the hole.

## What it does / what's being fixed (plain language)
`divert` supplies free-value USDC into the senior pool to fill the junior **hole** (`provision()`, the §11
markdown). Each call checks `usdcAmount * 1e12 <= hole`, but `divert` never writes `provision` (the CRE reduces
the hole later via `DefaultCoordinator.Recovery`). So between provision re-marks, several diverts that each pass
the per-call check **cumulatively over-fill** the hole (e.g. hole = $100; divert $60, then $60 again → $120 into
a $100 hole). The docstring's "a divert can never over-fill it" is true per-call but false across calls.

## Binds to (verified file:line — 2026-06-15)
- **`divert`:** `contracts/src/supply/szipUSD/RecycleModule.sol:285-310`. Per-call bound at `:290`
  (`if (usdcAmount * 1e12 > hole) revert ExceedsHole();`); hole read fresh at `:287`
  (`ISzipNavProvision(navOracle).provision()`); `hole == 0` → `NoHole` at `:288`; `_spendFreeValue` at `:292`;
  `:282-283` documents that divert never writes provision. `ExceedsHole` already declared at `:107` (reuse it).
- **`provision`:** `uint256 public provision;` at **`SzipNavOracle.sol:135`** (NOT `:102` — both the old ticket
  cite and the local-interface comment at `RecycleModule.sol:19` carry a stale `:102`; fix the comment line ref
  while editing the file). Sole writer = `writeProvision(uint256)` at `SzipNavOracle.sol:307-312`
  (`onlyDefaultCoordinator`), an **absolute re-mark to an arbitrary value** — called by
  `DefaultCoordinator.sol:240/258/275` writing the recomputed `totalProvision`. This confirms the test can set
  provision to any value and re-mark it mid-test (incl. `H → H'' → H`).
- **False claim to correct:** docstring `:270-283` ("a divert can never over-fill it", `:272`).
- **Units (verified):** `provision()` is 18-dp USD; `usdcAmount` is USDC 6-dp; `* 1e12` scales to 18-dp (`:275`).
  Keep the tally in 18-dp USD to match `hole`.

## Key requirements
1. **Add state:** `uint256 public lastSeenProvision;` and `uint256 public divertedSinceProvisionChange;`
   (both 18-dp USD).
2. **Reset-on-change + cumulative bound in `divert`,** after reading `hole` (`:287`) and the `hole == 0` check:
   ```solidity
   if (hole != lastSeenProvision) {            // provision was re-marked → fresh budget
       lastSeenProvision = hole;
       divertedSinceProvisionChange = 0;
   }
   uint256 scaled = usdcAmount * 1e12;          // USDC 6-dp -> USD 18-dp
   if (divertedSinceProvisionChange + scaled > hole) revert ExceedsHole();  // strict > → exact fill allowed
   ```
   Reuse the existing `ExceedsHole` error. Keep the original per-call intent subsumed by the cumulative check
   (the cumulative check is strictly tighter; a separate per-call check is redundant — replace `:290`).
3. **Increment the tally in the effects phase** (CEI): `divertedSinceProvisionChange += scaled;` in `divert`
   **immediately after the `_spendFreeValue(usdcAmount)` call at `:292`** and BEFORE the first value-moving
   `_exec` at `:298`, so a reentrant call sees it. **Do NOT** put the increment inside `_spendFreeValue` —
   that is the shared debit path `recycle` also calls (it must not touch the divert tally), and the Do-NOT
   forbids changing its CEI ordering. The tally increment rolls back atomically if a later post-deposit guard
   (`BackingShortfall`/`NoSharesMinted`) reverts — intended.
4. **Do NOT have `divert` write `provision`** — preserve the design where the CRE reduces the hole later
   (`:282-283`). Reset is triggered by *observing* a changed `provision()`, never by mutating it.
5. **Update the docstring** (`:270-283`) — the over-fill guard now holds cumulatively; document
   `lastSeenProvision` / `divertedSinceProvisionChange` + reset-on-change. State the guarantee is
   **per-provision-epoch** (between re-marks): cross-re-mark over-supply of the senior pool is possible but
   benign — extra USDC backing only strengthens the peg, and the spend is hard-capped by `freeValueAccrued`
   (a finite CRE-credited budget) + the trusted single CRE writer (§17). `lastSeenProvision == 0` is a safe
   "never observed" sentinel because `hole == 0` reverts `NoHole` (`:288`), so the reset block can never set
   it to 0.

## Do NOT
- Do NOT key the tally by the provision value (`mapping(uint256 hole => uint256 diverted)`) — re-mark churn
  resurrects stale tallies. Use `lastSeenProvision` (last observed) + a single running counter.
- Do NOT make `divert` write/decrement `provision` — the CRE owns the hole reduction.
- Do NOT change the USDC→USD scaling (`* 1e12`), the `BackingShortfall`/`NoSharesMinted` post-guards, or the
  `_spendFreeValue` CEI ordering — only add the cumulative bound + tally.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC09_*` regression test** that fails before / passes after:
  - **Cumulative over-fill blocked:** with `provision() == H`, two diverts that each individually pass
    (`amount*1e12 <= H`) but together exceed `H` — assert the second reverts `ExceedsHole` (pre-fix both pass,
    total diverted > H).
  - **Exact cumulative fill allowed; one wei over reverts.**
  - **Reset on re-mark:** after filling toward `H`, re-mark `provision()` to a new value `H'`; assert the tally
    resets so a fresh divert up to `H'` is allowed (not permanently stuck), AND the stale-value case
    (`H → H'' → H`) does NOT resurrect the old tally.
  - **Divert never writes provision:** assert `provision()` is unchanged across a successful `divert`.
- **Existing divert suite stays green:** the cumulative check is strictly tighter than the old per-call check,
  so the existing `RecycleModuleDivertTest` cases (`test_divert_exceeds_hole_boundary`,
  `test_divert_two_bounds_bind`, the CEI/overflow/shortfall cases) still pass — confirm by running the FULL
  `forge test`, not just the new cases.
- **Test-fixture facts:** the suite is `RecycleModuleDivertTest` (`contracts/test/RecycleModule.t.sol:668`);
  `provision()` is driven by the settable `MockNavProvision` (`:170-176`, `setProvision(uint256)`), wired as
  `navOracle` and already re-marked mid-test. **Ledger caveat:** divert is also bounded by `freeValueAccrued`
  (the rig's `SEED = 1_000_000e6`, `:681`) — pick test holes `H` with `H < SEED * 1e12` so the cumulative
  `ExceedsHole` binds before `InsufficientFreeValue`.
- Quote the actual `forge test` output in this ticket's done note. (Extend the RecycleModule test fixture.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-09" with the finding note.
