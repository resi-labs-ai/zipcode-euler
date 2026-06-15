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
}
