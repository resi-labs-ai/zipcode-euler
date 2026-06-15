// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IICHIVault} from "../../interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../../interfaces/algebra/IAlgebraPool.sol";
import {IAlgebraOraclePlugin} from "../../interfaces/algebra/IAlgebraOraclePlugin.sol";
import {TickMath, LiquidityAmounts} from "../../libraries/ConcentratedLiquidity.sol";

/// @title IchiAlgebraFairReserves
/// @notice Manipulation-resistant reserve reconstruction for an ICHI vault on an Algebra pool. The keystone the
///         fair-LP oracle (and the NAV oracle's LP leg) read instead of `IICHIVault.getTotalAmounts()`.
///
/// @dev WHY: `getTotalAmounts()` returns each ICHI position's token split computed at the pool's CURRENT tick, plus
///      idle balances. A swap moves the current tick, so the split is in-block manipulable — valuing it at fixed
///      prices moves with the manipulation (build/twap-ring.md). This library instead reconstructs each position's
///      reserves at the pool's TWAP tick using the position's liquidity `L` and its tick bounds — BOTH immune to
///      in-block swaps (`L` changes only on the vault's mint/burn; the TWAP tick is a time-average). Idle vault
///      balances are added as-is (they are token amounts, not price-sensitive in composition).
///
///      Validated on-chain 2026-06-14 against HYDX/USDC vault 0xfF8B…73f7 (pool 0x51f0…D3D2): the TWAP
///      reconstruction reproduces `getTotalAmounts()` while unmanipulated, and `base0 + limit0 + idle0` matched
///      `getTotalAmounts0()` to the wei.
library IchiAlgebraFairReserves {
    /// @notice The Algebra pool has no plugin / TWAP source — fail closed (no manipulation-resistant price).
    error NoPlugin();
    /// @notice The plugin returned an unusable timepoint set.
    error BadTimepoints();

    /// @notice Reconstruct the vault's `(amount0, amount1)` at the `window`-second TWAP tick (fair, manipulation-
    ///         resistant), and return that mean tick. Reverts `NoPlugin` if the pool exposes no TWAP plugin.
    /// @param vault  The ICHI vault.
    /// @param window The TWAP averaging window in seconds (e.g. 3600 for 1h).
    function fairReserves(address vault, uint32 window)
        internal
        view
        returns (uint256 amount0, uint256 amount1, int24 meanTick)
    {
        address pool = IICHIVault(vault).pool();
        address plugin = IAlgebraPool(pool).plugin();
        if (plugin == address(0)) revert NoPlugin();

        meanTick = _meanTick(plugin, window);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);

        // base position
        (uint128 lBase,,) = IICHIVault(vault).getBasePosition();
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).baseLower()),
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).baseUpper()),
            lBase
        );
        amount0 = a0;
        amount1 = a1;

        // limit position
        (uint128 lLimit,,) = IICHIVault(vault).getLimitPosition();
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).limitLower()),
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).limitUpper()),
            lLimit
        );
        amount0 += a0;
        amount1 += a1;

        // idle vault balances (held outside the AMM positions) — composition not price-sensitive
        amount0 += IERC20(IICHIVault(vault).token0()).balanceOf(vault);
        amount1 += IERC20(IICHIVault(vault).token1()).balanceOf(vault);
    }

    /// @notice The arithmetic-mean tick over `[now - window, now]` from the Algebra plugin, rounded toward negative
    ///         infinity on a negative remainder (the UniV3/`OracleLibrary.consult` convention).
    function _meanTick(address plugin, uint32 window) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window; // older
        secondsAgos[1] = 0; // now
        (int56[] memory cum,) = IAlgebraOraclePlugin(plugin).getTimepoints(secondsAgos);
        if (cum.length != 2) revert BadTimepoints();

        int56 delta = cum[1] - cum[0]; // tickCumulative(now) - tickCumulative(window ago)
        int56 w = int56(uint56(window));
        int56 mean = delta / w;
        if (delta < 0 && (delta % w != 0)) mean--;
        return int24(mean);
    }
}
