# INTERFACES — ALGEBRA
[zipcode-euler/contracts/src/interfaces/algebra]

Minimal interface shims for the Algebra Integral AMM that Hydrex runs on Base (chain 8453). Solidity 0.8.24.

==================================================================================
Interface → Live Base contract

- ISwapRouter.sol → Algebra SwapRouter `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`
Used by SellModule for its market swaps: HYDX→USDC, and zipUSD↔xALPHA (POL).
[contracts/src/supply/szipUSD/SellModule.sol]
[wires/8-B9-SellModule.md]

- IAlgebraPool.sol → HYDX/USDC pool `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`
Used by the fair-LP oracle to price the LP, and by the NAV oracle.
[contracts/src/supply/AlgebraIchiFairLpOracle.sol]
[contracts/src/supply/lib/IchiAlgebraFairReserves.sol]
[contracts/src/supply/SzipNavOracle.sol]
[wires/FairLpOracle.md]
[wires/8-B4-SzipNavOracle.md]

- IAlgebraOraclePlugin.sol → pool plugin `0xe33a242990780Ab872Ae986AD68206478Fc85Ae1`
TWAP oracle plugin used by the fair-LP oracle and the NAV oracle.
[contracts/src/supply/lib/IchiAlgebraFairReserves.sol]
[contracts/src/supply/SzipNavOracle.sol]
[wires/FairLpOracle.md]
[wires/8-B4-SzipNavOracle.md]

- INonfungiblePositionManager.sol → Algebra NFPM `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86`
STAGED (not yet wired): reserved for a future Algebra range-sell ladder strategy — referenced by no src/script/test today. Intentional forward scaffolding, not dead code.

- IAlgebraFactory.sol → Algebra factory `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E`
STAGED (not yet wired): build-time pool-address verification for the prod ICHI/Algebra LP path — referenced by no src contract today. Intentional forward scaffolding, not dead code.

Summaries:
[../wires/interfaces-algebra.md]

==================================================================================
References:

Hydrex runs Algebra AMM so the call shapes are pinned to match its live contracts exactly.
[contracts/script/BaseAddresses.sol]

All interfaces were sourced from Base contracts.
