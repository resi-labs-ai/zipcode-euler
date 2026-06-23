# SUPPLY-ADV-03 — `IchiAlgebraFairReserves` X-Ray refresh + the one untested guard (`BadTimepoints`)

> **STATUS: BUILT + SHIPPED to `main` (2026-06-22).** Added `test_fairReserves_revert_badTimepoints` +
> `MockBadTimepointsPlugin` (initialized plugin, wrong-length timepoint set) — the last untested fail-closed
> path. Suite 16 → **17 green**. Refreshed all four lib X-Ray files (`IchiAlgebraFairReserves.md`,
> `invariants.md`, `entry-points.md`, scope `x-ray.md`): three revert paths recorded
> (`NoPlugin`/`PluginNotReady`/`BadTimepoints`), the ADV-02 readiness gate added, all three now marked tested,
> the X-2 under-coverage resolution documented, and the verdict lifted **ADEQUATE → HARDENED**. No contract
> logic change (test + docs only).
>
> BUILD item (INFO/LOW). Source: dedicated pass on `contracts/src/supply/lib/IchiAlgebraFairReserves.sol`
> after the user pointed at `supply/lib/x-ray`. **No new vulnerability** — the lib was already reviewed as
> the core of the `algebraichifairlpooracle` cycle (SUPPLY-ADV-01 idle-donation WONTFIX; SUPPLY-ADV-02
> plugin-readiness gate SHIPPED, now at `:53`; math / rounding / in-block-invariance confirmed sound). This
> ticket closes the two real residuals: a stale X-Ray and the last untested fail-closed guard.

## The gap (source-verified)
The per-contract X-Ray `contracts/src/supply/lib/x-ray/IchiAlgebraFairReserves.md` is dated 06-20, **before
SUPPLY-ADV-02 landed**, and no longer matches the built lib + tests:
- The lib now has **THREE** revert paths, not two: `NoPlugin` (`:45`), **`PluginNotReady` (`:53`, added by
  ADV-02)**, `BadTimepoints` (`:92`). The X-Ray's §2 entry-points, §3 I-3, §4 guards table, §5, and
  structural fact 3 ("Two revert paths") all predate `PluginNotReady` and omit it.
- The X-Ray says `NoPlugin`/`BadTimepoints` are "not tested … no mock plugin." That is now **stale**:
  `contracts/test/supply/AlgebraIchiFairLpOracle.t.sol` added `MockPoolNoPlugin`/`MockVaultNoPlugin` →
  `NoPlugin` (`:173-175`), `MockPoolWithPlugin`/`MockUninitializedPlugin` → `PluginNotReady` on BOTH the ctor
  and the read path (`:185-186`, `:192-197`), plus an under-coverage fork-revert test (`:203-210`, the ADV-02
  empirical settlement).
- The verdict is capped at ADEQUATE explicitly because "`NoPlugin`/`BadTimepoints` fail-closed paths are
  untested." Two of the three are now tested; only `BadTimepoints` remains — so the cap should be re-evaluated.

`BadTimepoints` (`_meanTick:92`, `if (cum.length != 2) revert`) has **zero test references**
(`grep -rn BadTimepoints contracts/test` → none). It is defense-in-depth ("shape-only / dead in practice"
per the ADV-02 synthesis — `secondsAgos` is built locally as `new uint32[](2)`, so a conforming Algebra
plugin always returns length-2), but it is a declared guard with no coverage.

## Fix
1. **Add the `BadTimepoints` unit test.** New mock: an *initialized* plugin whose `getTimepoints` returns a
   non-length-2 set (e.g. length 1 or 3) — distinct from `MockUninitializedPlugin` (which trips
   `PluginNotReady` first and never reaches `_meanTick`). Drive it through the existing external
   `FairReservesHarness` wrapper (`AlgebraIchiFairLpOracle.t.sol:307-312`):
   `test_fairReserves_revert_badTimepoints` → `vm.expectRevert(IchiAlgebraFairReserves.BadTimepoints.selector)`.
   The vault only needs `pool()` reachable before `_meanTick` (position getters come after the revert), so
   reuse `MockVaultNoPlugin(mockPool)` + `MockPoolWithPlugin(badPlugin)`.
2. **Refresh the X-Ray** `contracts/src/supply/lib/x-ray/IchiAlgebraFairReserves.md` to match the built lib:
   - §2 entry-points + §3 I-3 + §4 guards table + structural fact 3: record the **three** revert paths
     (`NoPlugin`, `PluginNotReady`, `BadTimepoints`) and the `isInitialized()` readiness gate (ADV-02).
   - §4/§5: `NoPlugin` and `PluginNotReady` are now tested (cite the mock-plugin tests); only `BadTimepoints`
     was the gap — now closed by fix #1.
   - X-2 / §5 TWAP-trust: note the ADV-02 resolution — the read-time `isInitialized()` gate + the empirical
     fork settlement of under-coverage (`getTimepoints` reverts when `window` predates the oldest timepoint;
     cardinality is not on-chain-queryable, so no in-contract span assertion). Reference SUPPLY-ADV-02.
   - Re-evaluate the verdict: with all three fail-closed paths now tested and ADV-02 shipped, the lib meets
     **HARDENED** (the X-2 TWAP-source trust is an off-chain pool property, the only remaining residual, same
     class as every other oracle's external-feed trust).

## Gate
`forge build` clean + `forge test --match-path 'test/supply/AlgebraIchiFairLpOracle.t.sol'` green (currently
the suite the lib is connected to). The new `BadTimepoints` test passes; the existing fork + mock-plugin tests
stay green.

## Doc-sync (with the code)
- `contracts/src/supply/lib/x-ray/IchiAlgebraFairReserves.md` (the refresh above) — authoritative.
- `contracts/src/supply/lib/x-ray/invariants.md` + `entry-points.md` if they enumerate the revert paths /
  guards (grep-verify; add `PluginNotReady`).
- `build/tickets/PROGRESS.md` audit ledger.

## Acceptance criteria
- `BadTimepoints` has a passing unit test (initialized plugin, wrong-length timepoint set); the lib's three
  fail-closed paths are all covered.
- The X-Ray reflects the built lib: three revert paths incl. `PluginNotReady`, the readiness gate, the
  current test coverage, and the ADV-02 TWAP-under-coverage resolution; verdict re-evaluated (HARDENED).
- No contract logic change (the lib is sound as shipped); this is test + doc only.
