# SEC-10 report — `setLpTwapWindow(>0)` Algebra plugin/init validation (L2)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep, kill-list remediation) · **Status:** DONE, gate green.

## What the window did
Closed kill-list **L2** (LOW→MED) / audit R-DoS finding "lpTwapWindow misconfig cascade-bricks NAV." Added set-time
validation to `SzipNavOracle.setLpTwapWindow` so a non-zero TWAP window can only be set against an Algebra pool that
actually exposes an **initialized** TWAP plugin. Before the fix, the setter had zero validation: a Timelock setting
`lpTwapWindow > 0` against a plugin-less or uninitialized-plugin pool would make **every** NAV read revert
(`navEntry`/`navExit`/`grossBasketValue`/`coverageValue`/`poke`/`writeProvision` all route through
`grossBasketValue → _lpValue → IchiAlgebraFairReserves.fairReserves`, which reverts `NoPlugin` / in `getTimepoints`).

### The change (1 contract file)
`contracts/src/supply/SzipNavOracle.sol`:
- `import {IAlgebraPool}` + `import {IAlgebraOraclePlugin}` (mirroring the existing `IICHIVault` import).
- `error LpTwapPluginNotReady();` declared in the error block.
- `setLpTwapWindow(uint32 lpTwapWindow_)`: when `lpTwapWindow_ != 0`, require `ichiVault != address(0)`, read
  `pool = IICHIVault(ichiVault).pool()` → `plugin = IAlgebraPool(pool).plugin()`, revert `LpTwapPluginNotReady()` if
  `plugin == address(0) || !IAlgebraOraclePlugin(plugin).isInitialized()`. `lpTwapWindow_ == 0` stays unconditionally
  valid. NatDoc updated.
- `_lpValue`/`fairReserves`/spot path untouched (Do-NOT honored).

### Tests (`contracts/test/SzipNavOracle.t.sol`)
New mocks: `MockAlgebraPool` (settable `plugin()`), `MockAlgebraPlugin` (settable `isInitialized()` + `getTimepoints`
returning the real on-chain cumulatives `[-1380399043048, -1381518031724]`), `MockICHIVault` extended with `pool()` +
`getBasePosition`/`getLimitPosition` (L=0, reserves from idle balances) + in-range tick bounds. Four `test_SEC10_*`:
`no_plugin_reverts`, `uninitialized_plugin_reverts`, `ready_pool_succeeds_and_reads_twap`, `escape_zero_always_succeeds`.

## Gate
- `forge build` → `Compiler run successful!`
- `forge test` → **800 passed / 0 failed / 3 skipped** (+4 over SEC-09's 796; 3 skips = pre-existing
  `DeployZipcode.t.sol` scaffold).
- **Fail-before/pass-after:** guard commented out → `test_SEC10_no_plugin_reverts` fails (`next call did not revert as
  expected`); a throwaway demo confirmed the brick half (setter succeeds, then `grossBasketValue()` reverts). Restored → green.

## Decisions to sanity-check
1. **Single error for two failure modes.** `plugin == 0` and `!isInitialized()` both revert `LpTwapPluginNotReady()`;
   the two regression cases distinguish by mock setup, not selector. Deliberate (kept; critics agreed).
2. **`ichiVault != address(0)` precheck** is an additive requirement beyond L2's literal text — necessary (can't read
   `pool()` off a zero vault) and benign (a non-zero window before the LP is wired is itself a misconfig). spec-fidelity
   confirmed it's a benign tightening, not §17 drift (still Timelock-settable, not frozen).
3. **`isInitialized()` is necessary-not-sufficient.** It does NOT guarantee `getTimepoints([window,0])` succeeds for an
   arbitrary window — see holes below.

## Holes → resolution
- **Window > accumulated-history residual (accepted, not in scope).** Observation cardinality is NOT on-chain-queryable,
  so a window longer than the plugin's history still reverts in `getTimepoints` on first read. This fails closed at
  read-time and is recoverable via `setLpTwapWindow(0)`. Matches kill-list L2's own parenthetical carve-out — documented
  in the setter NatDoc + the `8-B4` wire doc. No further work owed.

## Doc edits (full doc-sync per `build/doc-sync-checklist.md`)
1. Ticket `build/tickets/sec/SEC-10-setlptwapwindow-validation.md` → DONE + done-note; consumer line-ref corrected
   (`:420-421` → `:425-426`); error name pinned canonical; Test-fixture section expanded to spell out the net-new mock
   infra (junior-dev's most-blocking item); position-getter signature corrected to the real
   `(uint128 liquidity, uint256, uint256)`.
2. `build/tickets/PROGRESS.md` → SEC-10 DONE, SEC-11 set NEXT, "Just done — SEC-10" note, SEC-track status line bumped.
3. `build/kill-list.md` → L2 `[ ]`→`[x]` + `DONE 2026-06-15 (SEC-10)`.
4. `build/audit-claude/role-based-findings.md` → R-DoS lpTwapWindow finding marked `✅ RESOLVED 2026-06-15 (SEC-10)`
   with a fix line; `build/audit-claude/SUMMARY.md` → `✅(SEC-10)` tag on the inline entry.
5. `build/wires/8-B4-SzipNavOracle.md` → the `setLpTwapWindow` setter row + the fair-LP narrative updated to describe
   the set-time validation + the read-time residual.
6. **No `claude-zipcode.md` spec change** — interface-level setter validation; §7 intent (fair-LP TWAP opt-in) unchanged.

## Status + NEXT
SEC-10 DONE. **NEXT = SEC-11** (kill-list L9) — `fund` sizing via `previewRedeem(config[id].balance)` (donation-immune;
shared `_eeSupplyAssets` helper; SEC-07's defund base-leg read should adopt it). Ticket:
`build/tickets/sec/SEC-11-fund-previewredeem-sizing.md`.
