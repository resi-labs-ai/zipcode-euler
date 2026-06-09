// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Algebra Integral NonfungiblePositionManager.
/// Source contract: NFPM @ Base 0xC63E9672f8e93234C73cE954a1d1292e4103Ab86.
/// verified on-chain 2026-06-06:
///   mint(MintParams) -> 0xfe3f3be7 (FOUND in bytecode for the 3-leading-address struct).
///     CORRECTED: Algebra omits UniV3 `fee` but ADDS an `address deployer` field (custom-pool
///     plugin deployer); the guessed 10-field struct (selector 0x9cc1a283) is ABSENT.
///   positions(uint256) -> 0x99fbab88 (FOUND); return tuple CORRECTED to include `deployer`
///     (12 fields). Confirmed by staticcall on live tokenId 1013 decoding cleanly
///     (token0/token1/ticks/liquidity all sensible).
///   increaseLiquidity 0x219f5d17, decreaseLiquidity 0x0c49ccbe, collect 0xfc6f7865,
///   burn 0x42966c68 — all FOUND unchanged (VERIFIED-CORRECT).
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        address deployer;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint88 nonce,
            address operator,
            address token0,
            address token1,
            address deployer,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
