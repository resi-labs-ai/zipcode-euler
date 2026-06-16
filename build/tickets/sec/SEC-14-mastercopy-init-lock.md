# SEC-14 — Init-lock the 9 module mastercopies + correct docstrings (L18)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L18 (info/QA);
`reference/zodiac-core/contracts/factory/Initializable.sol`, `.../test/TestModule.sol` · **Status:** DONE 2026-06-16

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

## Existing-test rework (REQUIRED — discovered at cold-build 2026-06-16; the original ticket missed it)
Locking the ctor is **incompatible with how the 9 module unit suites currently exercise the modules**: each
`test/<X>Module.t.sol` deploys a **bare** mastercopy and `setUp`s it directly (`m = new XModule(); m.setUp(...)`
in the fixture, and `new XModule(); x.setUp(badParams)` in the negative `test_setUp_*` cases — ~85 sites total).
Post-lock every such `.setUp()` reverts `AlreadyInitialized` BEFORE its `abi.decode`/`ZeroAddress`/`OwnerIsOperator`
validation, so the fixtures and the specific-selector negative tests break. The `forge test` gate forces the rework.

**Rework (production-faithful — the deploy path clones too):** in each of the 9 suites, make the setUp'd instance a
**clone of the impl** instead of the bare impl. A `Clones.clone(address(new XModule()))` minimal proxy has fresh
storage (`_initialized == 0`), so `setUp` works exactly as the old bare instance did.
- Add `import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";` (resolves via the OZ remap).
- Add a **file-scope free function** `function _clone<X>() returns (<X>) { return <X>(Clones.clone(address(new <X>()))); }`
  (file-scope so it's visible to ALL test contracts in the file — several files have >1 test contract). Define it
  AFTER doing the `new XModule()` → `_clone<X>()` replace_all so the free function's own literal `new` survives.
- Replace `new XModule()` → `_clone<X>()` across the file (`replace_all`). This also routes the `test_mastercopy_inert`
  / `test_mastercopy_init_locked` sites through a clone — still valid (an un-setUp clone is inert with zero storage).
- **`DurationFreezeModule.t.sol` ONLY:** restore the fork **mastercopy-clone-source** site (`DurationFreezeModule
  mastercopy = new DurationFreezeModule();`, ~:1307 — passed to `IModuleProxyFactory.deployModule`) back to the bare
  `new DurationFreezeModule()` (cloning a clone via the factory is fragile/wrong). It is the only such site; the rest clone.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC14_*` regression test** that fails before / passes after:
  - **Mastercopy locked:** for each of the 9, deploy a **bare** `new XModule()` and assert `setUp(<valid params>)`
    reverts `AlreadyInitialized` (pre-fix it succeeds). Use each suite's existing `_params`/`_initParams` valid-param
    helper for the encoding (discharges the junior-dev "no per-module encodings" gap); selector via
    `vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"))` (no import of the zodiac base needed).
  - **Clone still initializes:** the reworked fixtures (now clone-based) + the existing `test_setUp_wires_storage`
    already prove a clone `setUp`s and is functional. The `ModuleProxyFactory.deployModule` clone path specifically is
    proven by `DurationFreezeModule.t.sol`'s fork test + the `DeployLocal` gate below (which clones all 9 via the factory).
- **Deploy intact:** a full `DeployLocal` against a fresh anvil fork still deploys + enables all 9 module clones
  (the clone `setUp` path is unaffected). Quote the actual `forge test` output in the done note.

## Depends on
- None. **Coordinate with SEC-15 (I6):** both edit the same 9 modules; SEC-15 adds the `setOperator`
  `OwnerIsOperator` re-check while SEC-14 adds the ctor lock — non-conflicting, but land them aware of each other.
  On land: `PROGRESS.md` "Just done — SEC-14".

## DONE 2026-06-16
- **Lock (1 new src file + 9 modules):** new `src/supply/szipUSD/MastercopyInitLock.sol` — `abstract MastercopyInitLock
  is Module { constructor() { _lockMastercopy(); } function _lockMastercopy() private initializer {} }`. The empty
  `initializer`-guarded body flips the inherited (private) zodiac-core `Initializable._initialized` WITHOUT running
  `setUp`, so it sidesteps `setUp`'s non-zero / `owner!=operator` validation (the literal `TestModule` idiom of
  `setUp(abi.encode(zeros))` would revert `ZeroAddress`). All 9 modules changed `is Module` → `is MastercopyInitLock`
  (DurationFreeze: `is MastercopyInitLock, ReentrancyGuard`; the `Module` import → `MastercopyInitLock` import — `Module`
  was inheritance-only in every file). `_disableInitializers()` NOT used (absent in this base; Do-NOT honored).
- **Docstrings:** all 9 `is Module` headers + setUp NatDocs corrected — "init-locked at deploy" → "init-locked in its
  constructor (see {MastercopyInitLock})"; "Initialize a clone (or the mastercopy at deploy, then init-locked)" →
  "Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp)".
- **Test rework (the scope the original ticket missed — see section above):** the 9 unit suites deployed bare
  mastercopies and `setUp` them directly (~85 sites). Reworked via OZ `Clones.clone(address(new XModule()))` behind a
  file-scope `_clone<X>()` free function; the DurationFreeze fork ModuleProxyFactory clone-SOURCE (`:1314`) restored to
  bare. Each suite gained `test_SEC14_mastercopy_setUp_reverts()` (bare impl + the suite's existing valid-param helper →
  `AlreadyInitialized`).
- **Gate green:** `forge build` clean (warnings only — pre-existing `asm-keccak256` lint notes). `forge test`:
  `Ran 52 test suites: 821 tests passed, 0 failed, 3 skipped` (+9 SEC14 over SEC-13's 812; the 3 skips are the
  pre-existing `DeployZipcode.t.sol` scaffold). **Fail-before/pass-after confirmed** — neutering `_lockMastercopy()`
  makes all 9 `test_SEC14_*` FAIL (`next call did not revert as expected`, bare-mastercopy `setUp` succeeds); restored →
  9/9 pass. **Deploy intact:** fresh anvil Base fork @47096000 (port 8546) + `DeployLocal runLocal --broadcast --slow`
  → `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` (all 9 module clones `setUp` + enable through the unchanged deploy path).
- **No spec change** (interface-level QA fix; spec carries no init-lock claim). **No back-pressure / no new obligation.**
  Doc-sync: kill-list L18 `[x]`; audit R10 RESOLVED (role-based + reference-diff + SUMMARY); 8 module wire-doc runbooks
  corrected (the old "deploy then `setUp` once to lock" step was itself WRONG — the deploy never touched the mastercopy).
  *(Standalone report pruned 2026-06-16; this ticket is the retained record.)*
