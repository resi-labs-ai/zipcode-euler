# SEC-15 — `setOperator` re-checks `operator != owner` on 8 modules (I6)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` I6 (upgraded DOC→FIX); audit
`role-based-findings.md` (I6); `build/claude-zipcode.md` §17 (Timelock-settable wiring) · **Status:** PROPOSED

> Scope authored 2026-06-15. Mechanical one-line guard across 8 modules, mirroring the one module that already
> has it. The `OwnerIsOperator` error already exists in each (used by `setUp`).

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
