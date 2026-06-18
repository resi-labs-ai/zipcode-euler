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
References:

- Uniswap v3-core / v3-periphery — the source of this math (`FullMath`, `TickMath`, `LiquidityAmounts`, `OracleLibrary.getQuoteAtTick`). The same sources are vendored under `reference/euler-price-oracle/lib/v3-core` and `…/v3-periphery`. `mulDiv` and `getSqrtRatioAtTick` are byte-for-byte; the rest are transcribed verbatim and pinned to 0.8.24.
