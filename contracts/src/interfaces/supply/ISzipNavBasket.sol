// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the `SzipNavOracle` basket-value seam the DurationFreezeModule reads.
/// @dev Source: `contracts/src/supply/SzipNavOracle.sol`. The module reads the per-Safe sidecar value
///      (`committedValue()`) and the whole-basket value (`grossBasketValue()`) to compute the autonomous release
///      floor, and the five movable plain-leg addresses (read LIVE at `setUp` to form the whitelist == exactly
///      what the oracle prices). The GPL oracle is NOT imported for these views (the local-interface house posture).
interface ISzipNavBasket {
    /// @notice The gross junior-basket value (18-dp USD), summed across the main + sidecar Safes.
    function grossBasketValue() external view returns (uint256);

    /// @notice The sidecar-only (committed) basket value (18-dp USD).
    function committedValue() external view returns (uint256);

    /// @notice The main-only (free) basket value (18-dp USD).
    function freeValue() external view returns (uint256);

    // -- the five movable plain legs (the whitelist source) --
    function zipUSD() external view returns (address);
    function usdc() external view returns (address);
    function xAlpha() external view returns (address);
    function hydx() external view returns (address);
    function oHydx() external view returns (address);
}
