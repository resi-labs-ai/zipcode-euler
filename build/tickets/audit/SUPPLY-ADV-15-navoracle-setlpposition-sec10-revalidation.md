# SUPPLY-ADV-15 — `setLpPosition` re-point bypasses the SEC-10 LP-TWAP readiness invariant

> **STATUS: BUILT + SHIPPED to `main`** (2026-06-24). Factored the readiness check into a shared
> `_assertLpTwapReady()` internal, called from `setLpTwapWindow` (arm) AND `setLpPosition` (re-point, when
> `lpTwapWindow != 0`) — chose the **re-validate-and-revert** variant over force-zero, to preserve operator intent
> (a re-point to another ready vault keeps the window) and fail loudly rather than silently disable fair-reserves.
> Regressions `test_SUPPLYADV15_setLpPosition_repoint_to_pluginless_reverts` + `_repoint_to_ready_vault_keeps_window`;
> NAV 66/66, full supply track 587/587, `forge build` clean.
>
> BUILD item (LOW, fail-closed). Source: adversarial-review on `SzipNavOracle`
> (`adversarial-review/reports/src/supply/szipnavoracle/`, mission 5). Single-model (Claude) run.
> The SEC-10 invariant is enforced at ONE of its two wiring half-pairs; the other half can re-introduce the
> exact state SEC-10 rejects.

## The gap (source-verified)
- SEC-10 (`SzipNavOracle.setLpTwapWindow:262-273`) establishes the invariant **a non-zero `lpTwapWindow`
  requires `ichiVault` wired + a present, `isInitialized()` plugin** — validated against the **then-current**
  `ichiVault`.
- `setLpPosition` (`:234-239`) is the other half of the LP wiring pair and re-points `ichiVault`/`gauge`. It
  zero-guards both args but contains **no `lpTwapWindow` re-check** (verified: lines 234-239 touch only
  `ichiVault`, `gauge`, and emit). So `setLpTwapWindow(3600)` against vault A (plugin ready) → `setLpPosition(
  vaultB, gaugeB)` where vaultB's pool has `plugin() == address(0)` (or uninitialized) leaves `lpTwapWindow ==
  3600` live over a pluginless pool.
- The SEC-10 tests (`test_SEC10_*`) only set the window *after* the LP is wired; none re-points the LP *after*
  a valid window is live — the ordering this finding exploits is unmodelled.

## Mechanism + impact
The next `grossBasketValue()`/`navEntry()`/`navExit()`/`committedValue()`/`pathLockedLpEquity()` routes
`_lpValue` (`:452-453`) through `IchiAlgebraFairReserves.fairReserves(vaultB, 3600)`, which reverts `NoPlugin`
(`IchiAlgebraFairReserves.sol:45`) or `PluginNotReady` (`:53`). **Every NAV-keystone read reverts** — issuance,
exit, AND the freeze-floor reads all brick. This is **fail-closed** (a DoS, never a mis-price / over-issue /
over-pay), recoverable by `setLpTwapWindow(0)` *while ownership is live*.

**Escalator (INFO, folded):** if the bad re-point is followed by `renounceOwnership()`, the recovery escape
(`setLpTwapWindow(0)`) is frozen and the brick is **permanent**. The `:260` NatSpec leans on read-time
recoverability via `setLpTwapWindow(0)` — which assumes a live owner. Gated by deploy discipline (item-10
verifies wiring before hand-off), so operational, but the M5-a fix removes the reachable bad state entirely.

## Honest severity (LOW)
Timelock-only, build-phase, fail-closed, recoverable pre-renounce. LOW (not INFO) because it breaks an invariant
SEC-10 was authored to hold *globally*, not a bare "Timelock can re-point" X-3 restatement. LOW (not higher)
because no drain / mis-price / decomposition break.

## Fix
In `setLpPosition` (`:234-239`), after setting `ichiVault`/`gauge`, if `lpTwapWindow != 0` re-run the SEC-10
readiness check against the new vault's pool/plugin and revert `LpTwapPluginNotReady` on failure — OR force
`lpTwapWindow = 0` on every re-point so the window must be deliberately re-armed against the new pool (preferred:
it cannot leave a stale window and is the safer default). Factor the readiness check out of `setLpTwapWindow`
into a shared `_assertLpTwapReady()` internal so both setters share one source of truth.

## Gate
`forge build` clean + `forge test --match-path 'test/supply/SzipNavOracle.t.sol'` green. Add regressions:
- `setLpTwapWindow(3600)` [ready vault] → `setLpPosition(pluginlessVault, gauge)` reverts `LpTwapPluginNotReady`
  (or, if the force-zero variant is chosen, asserts `lpTwapWindow() == 0` after the re-point).
- Confirm a re-point to another ready vault still succeeds and reads through fair-reserves.

## Doc-sync (after code)
`contracts/src/supply/x-ray/SzipNavOracle.md` — I-8 (SEC-10): note the invariant is now enforced on BOTH
`setLpTwapWindow` and `setLpPosition`, and the renounce-irrecoverable corollary is closed; Guards table
`setLpPosition` row updated. Grep-verify no other doc restates the SEC-10 single-call-site framing.

## Acceptance criteria
- `setLpPosition` cannot leave a non-zero `lpTwapWindow` over a pluginless/uninitialized-plugin pool;
  regression added; suite green.
- X-Ray I-8 updated to reflect the two-site enforcement and the closed renounce escalator.
