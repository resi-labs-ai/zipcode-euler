# SEC-15 report — `setOperator` re-checks `operator != owner` on 8 modules (I6 / audit R9)

**Window:** 2026-06-16 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-DOC (the final SEC item)

## What this window did
Closed audit R9 (kill-list I6, upgraded DOC→FIX): the build-phase `setOperator` re-point on 8 of the 9 szipUSD engine
modules rejected only the zero address, so a Timelock re-point could silently collapse the owner (Timelock) and the
operator (CRE hot key) into one address — defeating the `owner != operator` separation that `setUp` establishes at
init. `LpStrategyModule` was the only module that already re-checked.

**Fix (8 src files, one line each):** after the existing `if (operator_ == address(0)) revert ZeroAddress();`, added
`if (operator_ == owner) revert OwnerIsOperator();`, copied verbatim from the model `LpStrategyModule.sol:141`:
`RecycleModule:195`, `ReservoirLoopModule:158`, `SzipBuyBurnModule:235`, `HarvestVoteModule:139`, `SellModule:157`,
`ExerciseModule:124`, `OffRampModule:119`, `DurationFreezeModule:179`. `setOperator` stays `onlyOwner` and still emits
`WiringSet("operator", ...)`. No other surface touched.

**Tests (8 files):** each suite gained `test_SEC15_setOperator_owner_recheck()` reusing its existing live-module
fixture (contract-level `m` field; `module` for SzipBuyBurn; `_deployModule(...)` for ReservoirLoop). Asserts: a
non-owner/non-zero re-point succeeds + updates `operator`; `setOperator(owner)` reverts `OwnerIsOperator` (pranked as
owner); `setOperator(address(0))` still reverts `ZeroAddress`.

## Gate
- `forge build` — clean (warnings/lint notes only: pre-existing `asm-keccak256`).
- `forge test` — **829 passed / 0 failed / 3 skipped** (+8 over SEC-14's 821; the 3 skips are the pre-existing
  `DeployZipcode.t.sol` scaffold).
- **Fail-before/pass-after** — stripping the guard from all 8 src files (via `perl`, leaving only `LpStrategyModule`)
  makes all 8 `test_SEC15_*` FAIL (`next call did not revert as expected`); restoring the guard → 8/8 pass.

## Critic loop (3 cheap critics, parallel)
- **reference-verifier:** all 8 exists+usable — `owner` resolves identically (`is MastercopyInitLock → Module →
  zodiac-core Ownable`'s `address public owner`), `OwnerIsOperator` declared in each, guard copy-pasteable verbatim.
- **spec-fidelity:** PASS — input validation, not a §17 freeze (pointer stays re-pointable to any non-owner/non-zero
  address); invents nothing; mirrors the init-time invariant; no inbound obligation owed by SEC-15.
- **junior-developer:** production fix unambiguous; all gaps were in the test deliverable (fixture pattern, distinct
  per-module `setUp` ABI, prank-as-owner footgun) — folded into the ticket and the implementation before cold-build.

## Decisions to sanity-check
- **`DurationFreezeModule` is the 8th module.** The audit (R9) counted 7 siblings; the kill-list (I6) added
  `DurationFreezeModule` "for consistency." We patched all 8 so all 9 modules now re-check. (Noted in R9/I6.)
- **No event assertion in the regression** — the test checks storage (`m.operator() == newOp`) on the success leg, not
  the `WiringSet` emit, since the fix doesn't touch the event. Existing per-suite wiring tests already cover the emit.

## Holes → resolution
- Ticket "Binds to" line numbers were stale (authored pre-SEC-14, which shifted module bodies down via the ctor
  inheritance line). → Verified each `setOperator` by grep before editing; corrected the refs in the ticket's DONE-note.
- `git checkout --` during the fail-before proof reverted the (uncommitted) production fix along with the test-only
  strip. → Re-applied the guard to all 8 via a `perl` insert keyed on the unique `setOperator` zero-check pattern;
  re-verified 9/9 guard count and re-ran the full suite green.

## Doc edits (doc-sync-checklist)
1. Ticket `sec/SEC-15-setoperator-owner-recheck.md` → DONE + Done-note (quoted gate output, fixture notes, corrected refs).
2. `PROGRESS.md` → SEC-15 row DONE; NEXT = SEC-DOC; status line; "Just done — SEC-15" note.
3. `kill-list.md` I6 → `[x]` + `DONE 2026-06-16 (SEC-15)`.
4. `audit-claude/role-based-findings.md` R9 → RESOLVED (SUMMARY.md has no R9 entry — nothing to sync there).
5. Wire docs (8) — setter sections note the `setOperator` re-check: `8-B10-RecycleModule`, `8-B5-ReservoirLoop`,
   `8-B14-SzipBuyBurnModule`, `8-B7-HarvestVoteModule`, `8-B9-SellModule`, `8-B8-ExerciseModule`, `OffRampModule`,
   `DurationFreezeModule`.
6. **No spec change** — interface-level input-validation; §17 "settable-not-frozen" intent unchanged.
7. **No deletion trigger fired** — a code QA fix, no forward artifact retired.

## Status + NEXT
SEC-15 DONE. **All 15 SEC FIX tickets (SEC-01…SEC-15) are now complete.** NEXT = **SEC-DOC** — the 14 DOC-disposition
doc/runbook sweep (no behavioral code; 4 explicit rejections), the final SEC item.
