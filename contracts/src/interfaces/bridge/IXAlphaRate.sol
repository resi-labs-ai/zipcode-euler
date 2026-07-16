// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the xALPHA liquid-staking exchange-rate getter.
/// @dev `exchangeRate()` is alpha-per-xAlpha (18-dp; `1e18` == 1.0 ALPHA per 1.0 xALPHA), read ON-CHAIN
///      from stake accounting (`staked alpha / supply`) — no pool price, so subnet emissions accrue here
///      non-manipulably (`bridge/xalpha-bridge-impl.md §2`).
///
///      M1: xALPHA is a STAND-IN test token (an 18-dp mock ERC20 also exposing this getter). The
///      production swap-in is the bridged Rubicon LST wrapper (`LiquidStakedV3`); its production
///      rate-getter selector + supply-immutability are VERIFIED AT THE 8x/BRIDGE INTEGRATION (flag,
///      do not block). This interface pins only the face the NAV oracle depends on.
interface IXAlphaRate {
    function exchangeRate() external view returns (uint256);
}
