// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the §8.2 EulerEarn senior pool — ONLY the three views the
///         DurationFreezeModule needs to read the donation-immune utilization `U`.
/// @dev Source: `reference/euler-earn/src/EulerEarn.sol` (solc 0.8.26 — never imported/compiled, the `[EXT]`
///      house posture). `maxWithdraw(address)` accounts for live strategy liquidity (`_maxWithdraw` →
///      `_simulateWithdrawStrategy`); `convertToAssets`/`balanceOf` are inherited from OZ `ERC4626`/`ERC20`.
///      `U = 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` reads the controller-gated borrow
///      side (`totalAssets() = Σ expectedSupplyAssets(strategy)`), so a stray-USDC donation to the pool address
///      moves neither term — the §11-B "not outsider-manipulable" guarantee. NEVER read `balanceOf(eulerEarn)`.
interface IEulerEarnUtil {
    /// @notice The assets `owner`'s shares can withdraw RIGHT NOW (free liquidity), bounded by strategy liquidity.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice The total backing assets `shares` represent (donation-immune: `Σ expectedSupplyAssets`).
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice The EulerEarn share balance of `account` (the warehouse Safe holding the senior position).
    function balanceOf(address account) external view returns (uint256);
}
