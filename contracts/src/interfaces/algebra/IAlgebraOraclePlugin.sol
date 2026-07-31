// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Algebra Integral volatility/oracle plugin (the TWAP source).
/// Verified on-chain 2026-06-14 against plugin 0xe33a242990780Ab872Ae986AD68206478Fc85Ae1
/// (the plugin of HYDX/USDC pool 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2):
///   getTimepoints([3600,0]) -> tickCumulatives [-1380399043048, -1381518031724] (mean tick over 1h ≈ -310830);
///   isInitialized() -> true.
interface IAlgebraOraclePlugin {
    /// @notice Cumulative tick at each `secondsAgo` offset (newest = `secondsAgos[i] == 0`). The arithmetic-mean
    ///         tick over `[t0, t1]` is `(tickCumulatives[t1] - tickCumulatives[t0]) / (t0 - t1)` (round toward
    ///         negative infinity on a negative numerator with nonzero remainder — the UniV3/OracleLibrary convention).
    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint88[] memory volatilityCumulatives);

    /// @notice True once the plugin's timepoint array has been initialized (a fresh plugin reverts TWAP reads).
    function isInitialized() external view returns (bool);

    /// @notice The write head of the plugin's 65536-slot timepoint ring buffer (the index of the NEWEST stored
    ///         timepoint). Verified on-chain 2026-07-28 against the same plugin 0xe33a24…85Ae1: timepointIndex()
    ///         -> 14799 with timepoints(14800).initialized == false (ring not yet wrapped ⇒ oldest is slot 0).
    function timepointIndex() external view returns (uint16);

    /// @notice The ring-buffer slot at `index`. Only `initialized` and `blockTimestamp` are consumed here (the
    ///         history-depth gate); the remaining fields are returned to match the deployed struct layout.
    ///         Verified on-chain 2026-07-28 against plugin 0xe33a24…85Ae1: timepoints(0) ->
    ///         (true, 1776960545, 0, 0, -306490, -306490, 0).
    function timepoints(uint256 index)
        external
        view
        returns (
            bool initialized,
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint88 volatilityCumulative,
            int24 tick,
            int24 averageTick,
            uint16 windowStartIndex
        );
}
