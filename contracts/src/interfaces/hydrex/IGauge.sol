// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for a Hydrex gauge (created on demand by IVoter).
/// Live example: BeaconProxy gauge @ Base 0xAC396CabF5832A49483B78225D902C0999829993
/// (impl 0x22D23D13aa0065ff3233cc7628f59b49dc80480d). rewardToken()==oHYDX.
/// verified on-chain 2026-06-06 against the impl bytecode selectors:
///   deposit(uint256)        -> 0xb6b55f25 (FOUND)
///   withdraw(uint256)       -> 0x2e1a7d4d (FOUND)
///   getReward()             -> 0x3d18b912 (FOUND)
///   balanceOf(address)      -> 0x70a08231 (FOUND)
///   earned(address,address) -> 0x211dc32d (FOUND); takes (rewardToken, account).
/// CORRECTED: the guessed single-arg earned(address) (0x008cc262) is ABSENT from the impl
/// bytecode — this gauge exposes the two-arg (token, account) form. Pass rewardToken()==oHYDX.
interface IGauge {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function rewardToken() external view returns (address);

    function earned(address token, address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}
