# Boot context — AlgebraIchiFairLpOracle (+ IchiAlgebraFairReserves) adversarial review

You are a smart-contract security reviewer auditing ONE unit as part of a blind panel (other models review
it independently; a reconciler scores findings against the X-Rays). Read this file and your mission
(`1.md` / `2.md` / `3.md`) before you begin.

## The unit under review (two tightly-coupled files — review them together)
- `contracts/src/supply/AlgebraIchiFairLpOracle.sol` (58 nSLOC) — a stateless, ownerless `BaseAdapter`
  (euler-price-oracle `IPriceOracle`) that an EVK `EulerRouter` resolves the **ICHI-vault LP collateral**
  through. Prices `(lpToken, quote=pool.token1)` as **pro-rata of fair TVL, rounded DOWN** against the
  borrower. Immutable params; no state/admin/setters/custody. `_getQuote`:
  `fairReserves → tvlInQuote = amount1 + _token0InQuote(meanTick, amount0) → FullMath.mulDiv(tvl, in, supply)`.
- `contracts/src/supply/lib/IchiAlgebraFairReserves.sol` (43 nSLOC) — the manipulation-resistance core: a
  pure `internal view` lib that reconstructs the vault's `(amount0, amount1)` at the pool's **TWAP tick**
  (value position liquidity `L` at the TWAP `sqrtP`) instead of the in-block-manipulable
  `IICHIVault.getTotalAmounts()` spot split. Idle vault balances added raw.

**Why it matters:** this is COLLATERAL pricing. A mis-price flows straight into the EVK borrow market →
over-valued collateral → bad debt. This is the highest-stakes target reviewed so far (not a demo).

## These are ORIGINAL contracts — the precedent is the *methodology + the upstream math*, not a code parent
Unlike the bridge/hydrex forks, there's no audited parent to diff. Your "supposed to be" baselines:
- **The canonical fair-LP-reserves technique** (Alpha-Homora-style): value the LP by reconstructing
  reserves at an *oracle/TWAP price*, never at spot reserves — because spot reserves are donation- and
  flash-loan-manipulable. The keystone claim is *the fair quote is invariant under an in-block swap.* Your
  job is to find any path where **spot still leaks in**.
- **UniV3 `OracleLibrary`** — `reference/euler-price-oracle/lib/v3-periphery/contracts/libraries/OracleLibrary.sol`
  (`getQuoteAtTick` / `consult`): `_token0InQuote` mirrors `getQuoteAtTick`; `_meanTick` mirrors `consult`
  (arithmetic-mean tick, round toward −∞). Diff the local code against these conventions.
- **The vendored UniV3 tick math** — `contracts/src/libraries/ConcentratedLiquidity.sol` (`TickMath`,
  `LiquidityAmounts`, `FullMath`). Faithfulness to upstream is **already confirmed** (the library review +
  a live Algebra-encoding fork check) — so do NOT re-audit the math primitives; attack how the oracle
  *uses* them (domain, rounding, branch selection, overflow at the boundary).
- **euler-price-oracle `BaseAdapter`** — `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` — the
  `IPriceOracle` face / `getQuote` contract the EVK router relies on.

## Tests
`contracts/test/supply/AlgebraIchiFairLpOracle.t.sol` — 13/13 (5 live-fork incl. the keystone
`test_fork_manipulation_invariance` (300k-USDC swap), + 8 edge: ctor guards, unsupported-pair, zero-supply,
rounds-down, the high-`sqrtP` branch). See what's proven (don't re-report) and what the fork *assumes* (a
healthy live pool with a real TWAP plugin — it does NOT model a low-cardinality / stale / multi-block-skewed
plugin).

## Ground rules
- Cite exact lines in the two files AND the upstream `OracleLibrary` / `ConcentratedLiquidity` line where
  relevant.
- The decisive surfaces: (1) does spot leak into the "fair" price anywhere; (2) a rounding/overflow/domain
  path that **over-values** collateral (the dangerous direction — DOWN is safe); (3) a non-reverting garbage
  price from a degenerate TWAP source (the X-2 residual). A finding that merely re-states the documented
  TWAP-trust residual without a concrete exploitation path is INFO.
- The vendored math is trusted/faithful — findings that require a transcription bug in `ConcentratedLiquidity`
  are out of scope (already diffed). Findings in how the *oracle* feeds/uses it are in scope.
- "Sound" is a valid result; if the manipulation-resistance holds and the math domain is respected, say so
  and show why.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/residual or methodology property you attack (I-1…I-8, X-1/X-2)>
- **Location:** <fn / line in the oracle or lib + the upstream OracleLibrary/ConcentratedLiquidity line>
- **Delta from precedent:** <how it differs from the fair-LP methodology / UniV3 OracleLibrary convention, or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it OVER- or under-values collateral.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness verdict.
