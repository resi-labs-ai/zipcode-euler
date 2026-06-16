# SEC-14 report — init-lock the 9 module mastercopies (kill-list L18 / audit R10)

**Window:** 2026-06-16 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-15 (I6 `setOperator` re-check).

## What the window did
Made the 9 szipUSD Zodiac-module mastercopies genuinely init-locked at construction, and corrected the docstrings +
wire-doc runbooks that falsely claimed (or wrongly prescribed) the lock.

- **New src file `contracts/src/supply/szipUSD/MastercopyInitLock.sol`:**
  `abstract MastercopyInitLock is Module { constructor() { _lockMastercopy(); } function _lockMastercopy() private initializer {} }`.
  The empty `initializer`-guarded body flips the inherited (private) zodiac-core `Initializable._initialized` WITHOUT
  running `setUp` — so it sidesteps `setUp`'s non-zero / `owner!=operator` validation. (`_disableInitializers()` is
  OZ-only, absent in this base — would not compile; Do-NOT honored.)
- **9 modules rewired:** `is Module` → `is MastercopyInitLock` (DurationFreeze: `is MastercopyInitLock, ReentrancyGuard`);
  the `Module` import → `MastercopyInitLock` import in each (`Module` was inheritance-only — verified). Modules:
  Recycle, ReservoirLoop, SzipBuyBurn, HarvestVote, Sell, Exercise, OffRamp, LpStrategy, DurationFreeze.
- **Docstrings:** all 9 headers + setUp NatDocs corrected ("init-locked at deploy" → "init-locked in its constructor
  (see {MastercopyInitLock})"; the "Initialize a clone (or the mastercopy at deploy, then init-locked)" NatDoc → "...the
  mastercopy is locked in its constructor and CANNOT be setUp").
- **9 unit test suites reworked:** see "Holes → resolution" below.

## Decisions to sanity-check
1. **Shared abstract over per-module ctor.** Used the ticket's recommended `MastercopyInitLock is Module` (DRY, single
   place the docstring claim is realized) rather than 9 copy-pasted ctors. DurationFreeze (`is MastercopyInitLock,
   ReentrancyGuard`) linearizes cleanly — the critics flagged this as the one wrinkle and it compiled + tested fine.
2. **Empty-body lock, not the literal `TestModule` idiom.** `TestModule`'s ctor calls `setUp(initParams)`; ours can't
   (our `setUp` validates non-zero + `owner!=operator`, so `setUp(zeros)` reverts `ZeroAddress`). The empty
   `initializer`-guarded fn is the faithful equivalent — it locks via the SAME modifier without the validation path.
3. **Tests clone the impl instead of using the bare mastercopy.** Production-faithful (the deploy clones too). The
   `test_mastercopy_inert` tests now exercise an un-setUp clone (still inert, still valid); the bare-mastercopy lock is
   asserted by the new `test_SEC14_*` tests. Net coverage increased.
4. **Regression uses the suite's existing valid-param helper** (not empty bytes) so the fail-before path is the ticket's
   stated one (pre-fix `setUp(valid)` SUCCEEDS; post-fix reverts `AlreadyInitialized`).

## Holes → resolution
- **The ticket missed the test-architecture collision (the real blocker).** The 9 unit suites deploy a BARE mastercopy
  and `setUp` it directly (~85 sites: fixtures + negative `test_setUp_*`). The ctor lock makes every such `.setUp()`
  revert `AlreadyInitialized`, breaking the suites — and the `forge test` gate forces the fix. **Resolution:** added an
  "Existing-test rework (REQUIRED)" section to the ticket and reworked each suite via OZ `Clones.clone(address(new
  XModule()))` behind a file-scope `_clone<X>()` free function (file-scope → visible to multi-contract test files).
  The ONE DurationFreeze ModuleProxyFactory clone-SOURCE (`:1314`) was kept bare (cloning a clone via the factory is
  wrong). This was the junior-dev critic's "no per-module valid-param encodings" gap surfacing — discharged by reusing
  each suite's existing `_params`/`_initParams` helper.
- **No back-pressure / no new obligation** — the fix uses only existing surfaces (the inherited `initializer`, OZ
  `Clones` already in deps).

## Doc edits
- `build/tickets/sec/SEC-14-mastercopy-init-lock.md` — status DONE + Done-note + the added "Existing-test rework" section.
- `build/tickets/PROGRESS.md` — NEXT → SEC-15; status line + SEC-14/SEC-15 table rows; "Just done — SEC-14" note.
- `build/kill-list.md` — L18 `[ ]` → `[x]` + DONE note.
- `build/audit-claude/` — R10 RESOLVED in `role-based-findings.md`, `reference-diff-findings.md`, `SUMMARY.md`.
- `build/wires/` — 8 module wire-doc runbooks corrected (RecycleModule, SzipBuyBurnModule, ExerciseModule,
  HarvestVoteModule, LpStrategyModule, SellModule, DurationFreezeModule, OffRampModule). The old "deploy then call
  `setUp` once to lock the mastercopy" runbook step was itself WRONG. `8-B5-ReservoirLoop.md` carried no claim (n/c).
- **No `build/claude-zipcode.md` spec change** (interface-level QA fix; the spec carries no init-lock claim).

## Gate (quoted)
- `forge build`: clean (warnings only — pre-existing `asm-keccak256` lint NOTES on `SzipBuyBurnModule.sol`).
- `forge test`: `Ran 52 test suites: 821 tests passed, 0 failed, 3 skipped (824 total)` — +9 over SEC-13's 812; the 3
  skips are the pre-existing `DeployZipcode.t.sol` scaffold.
- **Fail-before/pass-after:** neutering `_lockMastercopy()` → `Ran 9 test suites: 0 passed, 9 failed` (all 9
  `test_SEC14_*` fail `next call did not revert as expected`); restored → `9 passed, 0 failed`.
- **Deploy gate:** fresh anvil Base fork @47096000 (port 8546) + `forge script DeployLocal.s.sol:DeployLocal --sig
  "runLocal()" --broadcast --slow` → `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

## Status + NEXT
SEC-14 DONE (2026-06-16). **NEXT: SEC-15** — add the `operator != owner` re-check to `setOperator` on the 8 modules
that drop it (mirror `LpStrategyModule.sol:140`). Note: SEC-15 edits the same 9 modules' `setOperator` body — a
different surface than SEC-14's inheritance line; non-conflicting.
