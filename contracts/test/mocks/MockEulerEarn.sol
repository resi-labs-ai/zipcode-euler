// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A minimal 0.8.24 ERC-4626-ish vault over real USDC (1:1 shares), mocking `EulerEarn` for 8-Bw.
/// @dev `deposit` pulls `assets` USDC via `transferFrom` (so the APPROVE→SUPPLY ordering is REAL — a SUPPLY
///      without a prior APPROVE fails the allowance pull) and mints 1:1 shares to `receiver`, reverting
///      `ZeroShares()` on `deposit(0)` (mirrors `EulerEarn.sol:565`, so the "scope passes, inner exec fails →
///      `ModuleTransactionFailed`" branch is testable). `redeem` burns `shares` from `owner` and transfers
///      `assets` USDC to `receiver`, with NO zero-check (`redeem(0)` is a no-op success, mirroring
///      `EulerEarn.sol:604`). `convertToAssets`/`balanceOf`/`asset` are ERC-4626 1:1.
contract MockEulerEarn {
    /// @notice mirrors `EulerEarn.sol:565` — a 0-share deposit reverts.
    error ZeroShares();

    address public immutable asset;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address usdc_) {
        asset = usdc_;
    }

    /// @notice Pull `assets` USDC from the caller, mint 1:1 shares to `receiver`. Reverts on 0-share mint.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets; // 1:1
        if (shares == 0) revert ZeroShares();
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    /// @notice Burn `shares` from `owner`, transfer `assets` (1:1) USDC to `receiver`. `redeem(0)` is a no-op.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares; // 1:1
        // No zero-check: redeem(0) is a no-op success (mirrors EulerEarn.sol:604). A non-zero amount over
        // the held balance reverts on the underflow (the "inner exec fails" branch for REDEEM>held).
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        if (assets > 0) {
            IERC20(asset).transfer(receiver, assets);
        }
    }

    /// @notice ERC-4626 1:1 mark — the §4.5 senior NAV the queue/oracle reads.
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}
