# LIBRARIES — CONCENTRATED LIQUIDITY
[zipcode-euler/contracts/src/libraries]

Vendored Uniswap-V3 concentrated-liquidity math, used by the fair-LP oracle to value the ICHI LP. Solidity 0.8.24.

==================================================================================
Math for Hydrex Pools, used by the fair-LP oracle to value the ICHI LP.

Note: this math is copied verbatim from Uniswap v3-core/v3-periphery rather than imported, so the build pulls in no UniV3 pool interfaces. Algebra uses the same tick math as Uniswap V3, so it's correct for the Algebra HYDX/USDC pool. `ConcentratedLiquidity.sol` holds four small libraries:

- FullMath — multiply two numbers and divide by a third without overflowing in between (512-bit `mulDiv`). The building block the others rely on.
- TickMath — turn a pool tick into its square-root price.
- LiquidityAmounts — turn a position's liquidity + tick range into the two underlying token amounts.
- TickQuote — price one token in terms of the other at a given tick.

Used by:
[contracts/src/supply/AlgebraIchiFairLpOracle.sol]
[contracts/src/supply/lib/IchiAlgebraFairReserves.sol]
[../wires/FairLpOracle.md]

==================================================================================
Security X-Ray (audit fidelity)

Pure math libraries have no state, entry points, access control, or invariants, so there is NO tier/verdict — a math lib can't be "tested" or "exploited" in the threat-model sense. For vendored math the audit question is narrow: is this a faithful copy of upstream, and is the 0.8.x port correct? The library review answers that.

[contracts/src/libraries/x-ray/library-review.md] — the faithfulness + port review

* Faithfulness: DIFFED 2026-06-20, CONFIRMED — no logic divergence. All four libraries were compared against the cited upstream (reference/euler-price-oracle/lib/v3-core|v3-periphery): FullMath assembly ops, all 20 TickMath magic constants + bounds, the LiquidityAmounts formulas, and TickQuote.getQuoteAtTick all match. Only deltas are value-preserving cosmetics (local Q96 constant) and omitted unused functions. So the copy carries upstream's audit/formal-verification pedigree.
* No need to re-fuzz the library — UniV3 FullMath/TickMath are among the most audited/formally-verified math in DeFi; fuzzing re-proves Uniswap's work. The only copy-specific risk was a transcription typo, ruled out by the diff.
* 0.8.x port: every function is wrapped in unchecked (intentional wraparound is load-bearing for mulDiv's 512-bit trick and the tick-ratio chain). This is the correct port, but standard overflow protection is OFF — the bounds must hold by construction.
* Partial vendoring: only the forward getSqrtRatioAtTick is present (the inverse getTickAtSqrtRatio is not) — fine iff the oracle only ever goes tick→price.
* The one residual is NOT in this file: confirm the consumers (AlgebraIchiFairLpOracle / IchiAlgebraFairReserves) only feed in-domain inputs — ticks within ±MAX_TICK, getQuoteAtTick base amounts ≤ uint128 (an over-cap quote is a silent mis-quote, not a revert, because it's unchecked). That belongs in the oracle's test suite, not here. Everything downstream (the fair-LP oracle, NAV) inherits the correctness of these four functions.

==================================================================================
References:

- Uniswap v3-core / v3-periphery — the source of this math (`FullMath`, `TickMath`, `LiquidityAmounts`, `OracleLibrary.getQuoteAtTick`). The same sources are vendored under `reference/euler-price-oracle/lib/v3-core` and `…/v3-periphery`. `mulDiv` and `getSqrtRatioAtTick` are byte-for-byte; the rest are transcribed verbatim and pinned to 0.8.24.
