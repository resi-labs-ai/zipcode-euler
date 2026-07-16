// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title ISeniorPool
/// @notice The venue-neutral senior-surface read (§8.2, §4.7) — the minimal three views every silo's senior
///         pool MUST expose so the donation-immune senior par-backing read works for ANY venue type, not only
///         EulerEarn. This generalizes the former `IEulerEarnUtil` (which was Euler-named for the same three
///         selectors); EulerEarn satisfies it directly (4626 `convertToAssets`/`maxWithdraw` + ERC20 `balanceOf`),
///         and a non-4626 venue is admitted behind a thin wrapper that satisfies the same contract (CTR-10b).
///
/// @dev The DONATION-IMMUNITY contract every implementation must satisfy (the §11-B "not outsider-manipulable"
///      guarantee): the senior value of a holder is read as `convertToAssets(balanceOf(warehouse))`, and the
///      free/liquid portion as `maxWithdraw(warehouse)`. Both terms MUST be backed by the pool's real accounting
///      (for EulerEarn, `Σ expectedSupplyAssets(strategy)`), so a stray-asset DONATION to the pool address moves
///      neither term. Implementations whose `convertToAssets`/`maxWithdraw` can be skewed by an outside transfer
///      break this invariant and MUST NOT be admitted. Consumers NEVER read `balanceOf(pool)` itself (it is
///      donatable AND ≈0 for a pure-allocator pool).
interface ISeniorPool {
    /// @notice The assets `owner`'s shares can withdraw RIGHT NOW (free liquidity), bounded by available pool
    ///         liquidity. For EulerEarn this accounts for live strategy liquidity.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice The total backing assets `shares` represent (donation-immune: real pool accounting, NOT pool balance).
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice The senior share balance of `account` (the warehouse Safe holding the senior position).
    function balanceOf(address account) external view returns (uint256);
}
