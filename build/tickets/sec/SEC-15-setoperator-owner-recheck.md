# SEC-15 — `setOperator` re-checks `operator != owner` on 8 modules (I6)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` I6 (upgraded DOC→FIX); audit
`role-based-findings.md` (I6); `build/claude-zipcode.md` §17 (Timelock-settable wiring) · **Status:** DONE 2026-06-16

> Scope authored 2026-06-15. Mechanical one-line guard across 8 modules, mirroring the one module that already
> has it. The `OwnerIsOperator` error already exists in each (used by `setUp`).

## DONE-note (2026-06-16)
**The `operator != owner` re-check is now on all 9 szipUSD engine modules' `setOperator`** (audit R9; kill-list I6).
`setUp` enforces `owner != operator` at init, but the build-phase `setOperator` re-point on 8 of 9 modules rejected
only the zero address — a re-point could silently collapse the two roles. Added
`if (operator_ == owner) revert OwnerIsOperator();` after the existing `ZeroAddress` check in each of the 8
(`RecycleModule:195`, `ReservoirLoopModule:158`, `SzipBuyBurnModule:235`, `HarvestVoteModule:139`, `SellModule:157`,
`ExerciseModule:124`, `OffRampModule:119`, `DurationFreezeModule:179`), copied verbatim from the model
`LpStrategyModule.sol:141`. The inherited (zodiac-core `Ownable`) `owner` storage var resolves identically in all 8
(all `is MastercopyInitLock → Module → Ownable`); `OwnerIsOperator` was already declared in each. `setOperator` stays
`onlyOwner` and still emits `WiringSet("operator", ...)`. **No other surface touched** — non-conflicting with SEC-14
(ctor inheritance line vs `setOperator` body).

- **Cold-build folded the test fixture** (junior-dev critic's most-blocking item): each of the 8 suites already
  exposes a live module (owner ≠ operator) via its existing clone/`setUp` fixture — `RecycleModule`/`HarvestVote`/
  `Sell`/`Exercise`/`OffRamp`/`DurationFreeze`(SetupTest) use the contract-level `m` field; `SzipBuyBurn` uses its `module`
  field; `ReservoirLoop` builds one via `_deployModule(...)`. Each suite gained one
  `test_SEC15_setOperator_owner_recheck()` reusing that fixture: a non-owner/non-zero re-point succeeds + updates
  `operator`; `setOperator(owner)` reverts `OwnerIsOperator` (pranked as owner, so the auth layer doesn't mask it);
  `setOperator(address(0))` still reverts `ZeroAddress`.
- **Gate green:** `forge build` clean (lint notes only). `forge test`:
  ```
  Ran 52 test suites in 29.78s (84.12s CPU time): 829 tests passed, 0 failed, 3 skipped (832 total tests)
  ```
  +8 over SEC-14's 821 (the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold). **Fail-before/pass-after
  confirmed** — stripping the guard from all 8 src files (via `perl`, leaving only `LpStrategyModule`) makes all 8
  `test_SEC15_*` FAIL (`next call did not revert as expected`); restoring → 8/8 pass.
- **Stale line refs in this ticket's "Binds to" block corrected** (SEC-14 landed after authoring, shifting bodies):
  actual `setOperator` lines are Recycle:193, ReservoirLoop:156, SzipBuyBurn:233, HarvestVote:137, Sell:155,
  Exercise:122, OffRamp:117, DurationFreeze:177; model `LpStrategyModule.sol:141`.
- **No spec change** (interface-level input-validation; §17 "settable-not-frozen" honored — the pointer stays
  re-pointable to any non-owner/non-zero address, validation not a freeze). **No back-pressure / no new obligation.**

## Deliverable
Add the `operator_ == owner` re-check to the `setOperator` re-point path on the 8 engine modules that drop it,
preserving the init-time invariant that the owner (Timelock) is never also the operator.

## What it does / what's being fixed (plain language)
Each module is owned by the Timelock and driven by a separate `operator` (the CRE keeper). `setUp` enforces
`owner != operator` (defense against the privileged owner also holding the operator key). But the build-phase
`setOperator` re-point only rejects the zero address — it does NOT re-check `operator != owner`, so a re-point
can silently collapse the two roles into one, defeating the separation the init invariant established.
`LpStrategyModule` is the only module that re-checks; the other 8 should match.

## Binds to (verified file:line — 2026-06-15, all in `contracts/src/supply/szipUSD/`)
- **The model (already correct — do NOT change):** `LpStrategyModule.sol:139-144` —
  `setOperator` does `if (operator_ == address(0)) revert ZeroAddress(); if (operator_ == owner) revert OwnerIsOperator();`.
- **The 8 missing the re-check** (each: zero-check only, no `owner` check):
  `RecycleModule.sol:185-189`, `ReservoirLoopModule.sol:156-160`, `SzipBuyBurnModule.sol:232-236`,
  `HarvestVoteModule.sol:137-141`, `SellModule.sol:155-159`, `ExerciseModule.sol:122-126`,
  `OffRampModule.sol:117-121`, `DurationFreezeModule.sol:177-181`.
- **Invariant source (example):** `RecycleModule.sol:149` `if (owner_ == operator_) revert OwnerIsOperator();`
  (in `setUp`) — `OwnerIsOperator` already declared/available in each module.

## Key requirements
1. In each of the 8 `setOperator` functions, after the existing `if (operator_ == address(0)) revert ZeroAddress();`,
   add `if (operator_ == owner) revert OwnerIsOperator();` — copy the exact form (and `owner` reference) from
   `LpStrategyModule.sol:140` so it compiles identically across the siblings.
2. No other change to `setOperator` (still `onlyOwner`, still sets `operator` + emits `WiringSet("operator", ...)`).

## Do NOT
- Do NOT modify `LpStrategyModule.setOperator` — it already has the guard.
- Do NOT change `setUp`'s init-time check or the `onlyOwner` modifier.
- Do NOT introduce a new error — reuse the existing `OwnerIsOperator` in each module.
- Do NOT widen scope to other kill-list groups. (Coordinates with SEC-14, which also edits these 8 + LpStrategy —
  non-conflicting.)

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC15_*` regression test** that fails before / passes after:
  - For each of the 8 modules: with a live module (clone `setUp` with `owner != operator`), `setOperator(owner)`
    reverts `OwnerIsOperator` (pre-fix it succeeds, collapsing the roles).
  - `setOperator(<valid non-owner, non-zero>)` still succeeds and updates `operator`.
  - `setOperator(address(0))` still reverts `ZeroAddress`.
- Quote the actual `forge test` output in this ticket's done note.

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-15". **This completes the 15 FIX tickets; SEC-DOC (the
  doc/runbook sweep) is the final SEC item.**
