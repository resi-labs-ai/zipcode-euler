# SUPPLY-ADV-02 — fair-LP oracle lacks the `isInitialized()` plugin gate its own sibling enforces

> BUILD item (MEDIUM, with caveats). Source: adversarial-review on `AlgebraIchiFairLpOracle` +
> `IchiAlgebraFairReserves` (`adversarial-review/reports/src/supply/algebraichifairlpooracle/`, mission 3).
> **Live EVK collateral pricing.** The explicit fail-closed surface is sound; this is the one fail-OPEN mode.

## The gap (source-verified, incl. the sibling diff)
- The oracle ctor (`AlgebraIchiFairLpOracle.sol:52`) checks only `IAlgebraPool(pool).plugin() != address(0)`.
- The TWAP integrity guard `IchiAlgebraFairReserves._meanTick:80` is **shape-only**: `if (cum.length != 2)
  revert BadTimepoints();`. Since `secondsAgos` is built locally as `new uint32[](2)`, a conforming plugin
  always returns length-2 — the check tells you nothing about whether the two timepoints actually span
  `window`. No `isInitialized()`, no cardinality, no staleness assertion. (`isInitialized()` is in the
  interface, `IAlgebraOraclePlugin.sol:19`, but unused here.)
- **The sibling guards the identical plugin.** `SzipNavOracle.setLpTwapWindow:267`:
  `if (plugin == address(0) || !IAlgebraOraclePlugin(plugin).isInitialized()) revert LpTwapPluginNotReady();`
  — and documents `isInitialized()` as a "necessary-not-sufficient precheck" with the cardinality residual
  failing closed at read-time. **This oracle is strictly weaker than its own sibling against the same plugin.**

## Mechanism + impact
`_meanTick` computes `(cum[1]-cum[0])/window`. A degenerate Algebra plugin — freshly-seeded, low-cardinality,
or stale — can return a well-formed length-2 set whose `cum[0]` is extrapolated from a near-current
(manipulable) or frozen tick, so the "1h mean" collapses toward spot/stale. That price is then fed, **without
reverting (fail-OPEN)**, to the EVK borrow market as LP collateral value → over-value → bad debt. The keystone
fork test only proves invariance on a HEALTHY high-cardinality live plugin (the case the X-Ray says the fork
assumes); it cannot model a degenerate plugin.

## Honest severity (MEDIUM, two caveats)
- Production window is narrow: the live HYDX/USDC plugin is warm/high-cardinality, and re-pointing the oracle
  at a thinner pool is a governed redeploy + router `govSetConfig`.
- Whether `getTimepoints` **extrapolates (fail-open)** vs **reverts (fail-closed)** on under-coverage depends
  on the deployed Algebra Integral plugin version, which is NOT pinned in-repo — that uncertainty is itself
  the risk. The sibling assumes fail-closed-at-read-time; this is unverified for the live plugin version.
What IS definitive: the asymmetry with the sibling, and that the fix is cheap.

## Fix
1. Add the sibling's gate to the oracle ctor: `if (!IAlgebraOraclePlugin(plugin).isInitialized()) revert
   NoPlugin();` (or a dedicated error) — fails a fresh/uninitialized plugin closed at deploy, matching
   `SzipNavOracle:267`.
2. Add a read-time window-coverage assertion in `_meanTick`: confirm the effective observed span ≥ `window`
   (e.g. via the plugin's oldest-observation age, or two reads at `[window,0]`/`[window+ε,0]` that must
   differ), else revert `BadTimepoints`. Length-2 alone is not an integrity guard.
3. (Optional) pin/verify the deployed Algebra Integral plugin version's `getTimepoints` under-coverage
   behavior, to settle the fail-open-vs-closed uncertainty.

## Gate
`forge build` clean + `forge test --match-path 'test/supply/AlgebraIchiFairLpOracle.t.sol'` green. Add the
mock-plugin tests the lib X-Ray flagged missing: `NoPlugin`/uninitialized → ctor reverts; a length-2-but-
zero-span / stale timepoint set → `BadTimepoints` (after the coverage check is added).

## Doc-sync (after code)
`contracts/src/supply/x-ray/AlgebraIchiFairLpOracle.md` + `contracts/src/supply/lib/x-ray/IchiAlgebraFairReserves.md`
(the X-2 residual + the I-6 guard — now content-checked, not shape-only; the sibling asymmetry closed).

## Acceptance criteria
- Oracle ctor reverts on an uninitialized plugin (matches the sibling); `_meanTick` rejects an under-coverage
  window; mock-plugin regression tests added; suite green.
- X-Rays updated: the fail-open mode is closed and the sibling asymmetry resolved.
