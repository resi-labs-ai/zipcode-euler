# SEC-10 — `setLpTwapWindow(>0)` Algebra plugin/init validation (L2)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L2 (LOW→MED); `build/twap-ring.md`,
`build/fair-lp.md`; audit `role-based-findings.md` (R-DoS / lpTwapWindow cascade) · **Status:** DONE 2026-06-15

## DONE note (2026-06-15)
**`setLpTwapWindow(>0)` now validates the Algebra plugin at set-time** (kill-list L2; audit R-DoS lpTwapWindow cascade).
- **Fix (1 file, `SzipNavOracle.sol`):** declared `error LpTwapPluginNotReady();`; added imports `IAlgebraPool`/
  `IAlgebraOraclePlugin`; `setLpTwapWindow` now, when `lpTwapWindow_ != 0`, requires `ichiVault != address(0)`, reads
  `pool = IICHIVault(ichiVault).pool()` → `plugin = IAlgebraPool(pool).plugin()`, and reverts `LpTwapPluginNotReady()`
  if `plugin == address(0) || !IAlgebraOraclePlugin(plugin).isInitialized()`. `setLpTwapWindow(0)` stays
  unconditionally valid (the recovery/escape path). NatDoc updated (validates presence+init only; `isInitialized()`
  necessary-not-sufficient; window>history residual fails closed at read-time, recoverable via `set(0)`). `_lpValue`/
  `fairReserves`/spot path untouched.
- **Gate green:** `forge build` clean (`Compiler run successful!`); `forge test`:
  `Ran 52 test suites in 29.73s (89.18s CPU time): 800 tests passed, 0 failed, 3 skipped (803 total tests)`
  (+5 over SEC-09's 795 — wait, SEC-09 was 796; SEC-10 adds 4 new tests → 800; the 3 skips are the pre-existing
  `DeployZipcode.t.sol` scaffold). 4 new `test_SEC10_*` in `SzipNavOracle.t.sol`:
  `no_plugin_reverts`, `uninitialized_plugin_reverts`, `ready_pool_succeeds_and_reads_twap`,
  `escape_zero_always_succeeds`. **Fail-before/pass-after confirmed** — commenting out the guard makes
  `test_SEC10_no_plugin_reverts` FAIL (`next call did not revert as expected`); a throwaway demo additionally showed
  `setLpTwapWindow(3600)` then succeeds and a subsequent `grossBasketValue()` reverts (NAV bricked). Restored → green.
- **Test fixture:** authored `MockAlgebraPool` (settable `plugin()`), `MockAlgebraPlugin` (settable `isInitialized()` +
  `getTimepoints` returning the real on-chain cumulatives `[-1380399043048, -1381518031724]`), extended `MockICHIVault`
  with `pool()` + `getBasePosition`/`getLimitPosition` (L=0 so reserves come from idle balances) + in-range tick bounds.
- **No spec change** (interface-level setter validation; §7 intent unchanged — the spec already prescribed the fair-LP
  opt-in, this fences a misconfig brick). **No back-pressure / no new obligation** (uses existing surfaces). Critics ran
  clean (spec-fidelity PASS all dimensions incl. §17 settable-not-frozen; reference-verifier all bindings usable;
  junior-dev's most-blocking item — net-new mock infra — folded into the Test-fixture section above).

> Scope authored 2026-06-15. Setter-validation fix. The full-cardinality / window-vs-history edge is NOT
> on-chain-queryable; that residual fails closed on first read and is recoverable via `setLpTwapWindow(0)` —
> accepted, not in scope. This ticket guards the gross mis-config (no plugin / uninitialized plugin).

## Deliverable
Validate, in `setLpTwapWindow`, that a non-zero window points at an Algebra pool with an **initialized TWAP
plugin** — so a mis-set window cannot brick every NAV read.

## What it does / what's being fixed (plain language)
`lpTwapWindow` selects how the junior LP leg is valued: `0` ⇒ spot `getTotalAmounts()`; non-zero ⇒ the
manipulation-resistant Algebra TWAP reconstruction. When non-zero, `_lpValue` calls `fairReserves`, which reads
the pool's TWAP plugin and reverts if there is none (`NoPlugin`) or queries `getTimepoints` (which reverts on an
uninitialized plugin). `setLpTwapWindow` has **zero validation**, so an owner who sets a non-zero window against
a plugin-less or under-seeded pool **instantly bricks every NAV read** (`navEntry`/`navExit`/`coverageValue` all
flow through `grossBasketValue → _lpValue → fairReserves`). Validating at set-time turns a silent protocol-wide
brick into a clean setter revert.

## Binds to (verified file:line — 2026-06-15)
- **The setter (no validation):** `contracts/src/supply/SzipNavOracle.sol:247-250` — `setLpTwapWindow` just
  assigns `lpTwapWindow` and emits.
- **The consumer that bricks:** `SzipNavOracle.sol:425-426` — `if (lpTwapWindow != 0) (total0,total1,) =
  IchiAlgebraFairReserves.fairReserves(ichiVault, lpTwapWindow);` (LP leg of `grossBasketValue`/`_grossValueOf`/
  `pathLockedLpEquity` via `_lpValue` `:417-429`).
- **The revert sources:** `contracts/src/supply/lib/IchiAlgebraFairReserves.sol:39-41` —
  `pool = IICHIVault(vault).pool(); plugin = IAlgebraPool(pool).plugin(); if (plugin == address(0)) revert NoPlugin();`
  and `:79` `IAlgebraOraclePlugin(plugin).getTimepoints(...)` (reverts on uninitialized/insufficient history).
- **Verified selectors:** `IAlgebraPool.plugin()` `contracts/src/interfaces/algebra/IAlgebraPool.sol:31`;
  `IAlgebraOraclePlugin.isInitialized()` `contracts/src/interfaces/algebra/IAlgebraOraclePlugin.sol:19`;
  `IICHIVault.pool()` (used at `IchiAlgebraFairReserves.sol:39`).

## Key requirements
1. In `setLpTwapWindow`, when `lpTwapWindow_ != 0`:
   - require `ichiVault != address(0)` (no pool to validate otherwise — and a TWAP window before the LP is wired
     is a mis-config);
   - read `pool = IICHIVault(ichiVault).pool()`, `plugin = IAlgebraPool(pool).plugin()`;
   - revert the **new error `LpTwapPluginNotReady()`** (canonical name — ONE error covers both failure modes;
     the two regression cases below distinguish by mock setup, not by selector) if `plugin == address(0)` OR
     `!IAlgebraOraclePlugin(plugin).isInitialized()`.
   Then assign + emit as today.
2. `lpTwapWindow_ == 0` stays unconditionally valid (the "use spot" default) — no validation.
3. Add the `IAlgebraPool` / `IAlgebraOraclePlugin` imports to `SzipNavOracle` if not already present, and declare
   the new error. (`IICHIVault` is already imported.)
4. Document in the setter NatDoc that this validates plugin presence + initialization only; `isInitialized()==true`
   is a *necessary-not-sufficient* precheck — a window longer than the plugin's accumulated history can still
   revert in `getTimepoints` on first read, fails closed there, and is recoverable via `setLpTwapWindow(0)`
   (cardinality is not on-chain-queryable). The `isInitialized()` setter check and the `getTimepoints` read-time
   revert are therefore *different* conditions; the setter guards only the gross "no/uninitialized plugin" brick.

## Do NOT
- Do NOT attempt to validate full observation cardinality / that the window is fully covered by history — not
  queryable on-chain; that edge fails closed on read and is recoverable (accepted residual, per kill-list).
- Do NOT change `_lpValue`/`fairReserves` or the spot path — the fix is purely setter input-validation.
- Do NOT block `setLpTwapWindow(0)` — it must always succeed (the recovery/escape path).
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC10_*` regression test** that fails before / passes after:
  - **No plugin:** with `ichiVault` pointing at a pool whose `plugin() == address(0)`, `setLpTwapWindow(3600)`
    reverts `LpTwapPluginNotReady` (pre-fix it succeeds and a subsequent `grossBasketValue()`/`navExit()` reverts
    — i.e. the NAV is bricked).
  - **Uninitialized plugin:** plugin present but `isInitialized() == false` → setter reverts.
  - **Ready pool:** plugin present + initialized → setter succeeds and `grossBasketValue()` reads through the TWAP path.
  - **Escape always open:** `setLpTwapWindow(0)` succeeds regardless of pool state (recovers a bricked NAV).
- Quote the actual `forge test` output in this ticket's done note.

### Test fixture — this is NET-NEW mock infrastructure, not a trivial extend
The existing `MockICHIVault` (`test/SzipNavOracle.t.sol:55-78`) implements only `token0/token1/totalSupply/balanceOf/getTotalAmounts` — it has **no `pool()`** and there is **no Algebra pool/plugin mock** in the suite. Author:
- **`MockAlgebraPool`** with a settable `plugin()` (returns `address(0)` for the no-plugin case, the mock plugin otherwise).
- **`MockAlgebraPlugin`** with a settable `isInitialized()` and a `getTimepoints(uint32[])` returning the **real on-chain cumulatives** cited in `contracts/src/interfaces/algebra/IAlgebraOraclePlugin.sol:6-8` — `getTimepoints([3600,0]) -> tickCumulatives [-1380399043048, -1381518031724]` (mean tick ≈ -310830, a valid `TickMath` tick) so the ready-pool case reads through `fairReserves` without reverting in `TickMath`. Also return a 2-elem `volatilityCumulatives` (any values; unused).
- **Extend `MockICHIVault`** with: `pool()` (settable, points at the `MockAlgebraPool`); and the position/tick getters `fairReserves` reads — `getBasePosition()`/`getLimitPosition()` (return `(uint128 liquidity, uint256 amount0, uint256 amount1)` per `IICHIVault.sol:39,42`; set base/limit **liquidity `L = 0`** so `LiquidityAmounts.getAmountsForLiquidity` yields `(0,0)` regardless of tick and the reserves come purely from idle `IERC20.balanceOf(vault)` token balances; the amount fields are unread), and `baseLower()/baseUpper()/limitLower()/limitUpper()` returning **valid in-range ticks** (e.g. `-887220 / 887220`, within `TickMath`'s `[-887272, 887272]`). The ready-pool reserves then equal the vault's idle token balances — keep the spot-vs-TWAP totals equal so the pro-rata mark is identical either path (lets the test assert `grossBasketValue()` is non-zero and unchanged across the window flip).
- Add `IAlgebraPool`/`IAlgebraOraclePlugin` imports to the test file too (it currently imports neither).

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-10" with the finding note.
