// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for an Algebra Integral pool.
/// Source: HYDX/USDC pool @ Base 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2.
/// verified on-chain 2026-06-06 (VERIFIED-CORRECT, no change):
///   swap(address,bool,int256,uint160,bytes) -> 0x128acb08 (FOUND)
///   globalState() -> 0xe76c01e4 (FOUND); staticcall decoded cleanly to
///   (price=1.587e22, tick=-308481, lastFee=500, pluginConfig=215, communityFee=1000, unlocked=true).
interface IAlgebraPool {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @dev Algebra packs the pool state into `globalState` (the UniV3 `slot0` analogue).
    function globalState()
        external
        view
        returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked);

    /// @dev Standard pair getters. Verified on-chain this window for pool 0x51f0…: token0() == HYDX, token1() == USDC.
    function token0() external view returns (address);
    function token1() external view returns (address);
}
