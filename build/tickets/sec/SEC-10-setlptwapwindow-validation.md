# SEC-10 — `setLpTwapWindow(>0)` Algebra plugin/init validation (L2)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L2 (LOW→MED); `build/twap-ring.md`,
`build/fair-lp.md`; audit `findings.md` (L2) · **Status:** PROPOSED

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
- **The consumer that bricks:** `SzipNavOracle.sol:420-421` — `if (lpTwapWindow != 0) (total0,total1,) =
  IchiAlgebraFairReserves.fairReserves(ichiVault, lpTwapWindow);` (LP leg of `grossBasketValue`/`_grossValueOf`/
  `pathLockedLpEquity` via `_lpValue` `:412-428`).
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
   - revert (new error, e.g. `LpTwapPluginNotReady()`) if `plugin == address(0)` OR
     `!IAlgebraOraclePlugin(plugin).isInitialized()`.
   Then assign + emit as today.
2. `lpTwapWindow_ == 0` stays unconditionally valid (the "use spot" default) — no validation.
3. Add the `IAlgebraPool` / `IAlgebraOraclePlugin` imports to `SzipNavOracle` if not already present, and declare
   the new error. (`IICHIVault` is already imported.)
4. Document in the setter NatDoc that this validates plugin presence + initialization only; a window longer than
   the plugin's accumulated history still fails closed on first read and is recoverable via `setLpTwapWindow(0)`
   (cardinality is not on-chain-queryable).

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
- Quote the actual `forge test` output in this ticket's done note. (Extend the NAV-oracle fair-LP test fixture / mock Algebra pool+plugin.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-10" with the finding note.
