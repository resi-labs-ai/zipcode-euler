# SEC-14 — Init-lock the 9 module mastercopies + correct docstrings (L18)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L18 (info/QA);
`reference/zodiac-core/contracts/factory/Initializable.sol`, `.../test/TestModule.sol` · **Status:** PROPOSED

> Scope authored 2026-06-15. Non-exploitable (the mastercopies are never enabled as Safe modules) — QA /
> defense-in-depth + making a currently-FALSE docstring claim true. The audit's proposed `_disableInitializers()`
> does NOT exist in zodiac-core's `Initializable` (it's OZ-only) and won't compile.

## Deliverable
Lock initialization on each of the 9 zodiac-`Module` engine-module mastercopies at construction, and correct the
docstrings that already (falsely) claim "the mastercopy is init-locked at deploy."

## What it does / what's being fixed (plain language)
Each engine module is deployed once as a **mastercopy**, then EIP-1167-cloned per Safe; the clone's `setUp`
writes its wiring under the one-shot `initializer` modifier. The docstrings claim the mastercopy itself is
init-locked at deploy — but none of the 9 have a constructor that runs `initializer`, so the mastercopy's
`_initialized` stays false and anyone can call `setUp` on it. It is harmless today (a bare mastercopy is never
enabled on a Safe), but the claim is false; locking it makes the claim true and removes the footgun.

## Binds to (verified file:line — 2026-06-15)
- **The 9 mastercopies** (`contracts/src/supply/szipUSD/`, all `is Module` with `setUp(bytes) ... initializer`):
  `RecycleModule`, `ReservoirLoopModule`, `SzipBuyBurnModule`, `HarvestVoteModule`, `SellModule`,
  `ExerciseModule`, `OffRampModule`, `LpStrategyModule`, `DurationFreezeModule`. None has an init-locking ctor
  (verified — only RecycleModule mentions "constructor" in a comment).
- **False claim, example:** `RecycleModule.sol:69` ("The mastercopy is init-locked at deploy") and `:125`.
- **Deploy uses them as mastercopies, NOT live modules (so locking the ctor is safe):**
  `DeployZipcode.s.sol:391-477` — every module is `_cloneModule(address(new XModule()), params, safe)`;
  `_cloneModule` (`:570-576`) calls `ModuleProxyFactory.deployModule(mastercopy, abi.encode setUp(bytes), salt)`
  → clone gets `setUp`, the mastercopy never does.
- **The mechanism (reference, verified):** `Initializable.sol:4-13` — `bool private _initialized;` +
  `modifier initializer { if (_initialized) revert AlreadyInitialized(); _initialized = true; _; }`. `_initialized`
  is `private` (can't be flipped from a subclass except via the `initializer` modifier). `TestModule.sol:9-12`
  locks via `constructor { setUp(initParams); }`.
- **Why NOT the literal TestModule idiom here:** our `setUp` validates all addresses non-zero + `owner != operator`
  (`RecycleModule.sol:142-149`, and the siblings similarly), so a ctor calling `setUp(abi.encode(zeros))` would
  revert `ZeroAddress`. Use an empty `initializer`-guarded lock instead (below).

## Key requirements
1. **Lock each mastercopy via an empty `initializer`-guarded function called from the constructor** — a
   `_disableInitializers`-equivalent that does NOT run `setUp` (so it sidesteps `setUp`'s non-zero validation):
   ```solidity
   constructor() { _lockMastercopy(); }
   function _lockMastercopy() private initializer {}   // flips inherited _initialized; empty body
   ```
   **Recommended:** put this in ONE shared local abstract (e.g. `MastercopyInitLock is Module`) and have the 9
   modules inherit it instead of `Module` directly (DRY; single place the docstring claim is realized). A
   per-module 2-line ctor is an acceptable fallback.
2. Any later `setUp` on the mastercopy now reverts `AlreadyInitialized`; clones (fresh storage, no ctor run on
   the EIP-1167 proxy) still `setUp` normally — the deploy path is unchanged.
3. **Correct all 9 docstrings** to accurately describe the now-real ctor lock (remove/replace the wording that
   implied an automatic lock that wasn't happening).

## Do NOT
- Do NOT call `_disableInitializers()` — it does not exist in this `Initializable` base (OZ-only); it won't compile.
- Do NOT call `setUp` with dummy params in the ctor — our `setUp` reverts on zero/`owner==operator`; the empty
  `initializer`-guarded lock is the equivalent that compiles and runs.
- Do NOT edit the `reference/zodiac-core` package (`_initialized` is private there) — implement the lock at our
  module layer.
- Do NOT lock anything that the deploy `setUp`s directly — verified the deploy only `setUp`s clones, never the
  `new XModule()` mastercopies; do not extend the lock to non-Module contracts (`ExitGate`, `SzipUSD`,
  `ReservoirBorrowGuard`).
- Do NOT widen scope to other kill-list groups. (The showcase `LpStrategyModuleDemoVAMM` may take the same lock
  for consistency — optional, note it; not one of the 9 production modules.)

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC14_*` regression test** that fails before / passes after:
  - **Mastercopy locked:** for each of the 9, deploy `new XModule()` and assert `setUp(<valid params>)` reverts
    `AlreadyInitialized` (pre-fix it succeeds).
  - **Clone still initializes:** a clone deployed via `ModuleProxyFactory.deployModule` (the `_cloneModule` path)
    `setUp`s successfully and is functional — the lock does not touch clones.
- **Deploy intact:** a full `DeployLocal` against a fresh anvil fork still deploys + enables all 9 module clones
  (the clone `setUp` path is unaffected). Quote the actual `forge test` output in the done note.

## Depends on
- None. **Coordinate with SEC-15 (I6):** both edit the same 9 modules; SEC-15 adds the `setOperator`
  `OwnerIsOperator` re-check while SEC-14 adds the ctor lock — non-conflicting, but land them aware of each other.
  On land: `PROGRESS.md` "Just done — SEC-14".
