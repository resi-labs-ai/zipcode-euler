// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LockReleaseTokenPool} from "chainlink-ccip/pools/LockReleaseTokenPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SzAlphaLockReleasePool — the 964-side CCT pool for szALPHA (lock-on-source / release-on-dest).
/// @notice The proven topology for a supply-denominated LST (Project Rubicon runs LockReleaseTokenPool on
///         964 for all 18 live xAlpha bridges, see `reference/rubicon/`): bridged-out szALPHA is LOCKED
///         here (custodied in the wired `ERC20LockBox`), never burned, so `SzAlpha.totalSupply()` keeps
///         counting it and `exchangeRate() = stake/supply` stays truthful while supply circulates on
///         Base. Burn-on-source would inflate the rate against unchanged stake and let 964 redeemers
///         drain the backing of Base holders.
/// @dev A thin subclass of the audited `LockReleaseTokenPool` adding the deploy-time invariants the
///      security review requires:
///        - S8: `localTokenDecimals == 18` (cross-chain conservation depends on equal decimals); and
///        - S9: the wired `rmnProxy` equals the chain's canonical ARMProxy (immutable in `TokenPool`;
///              redeploy — never mutate — on an RMN rotation).
///      `advancedPoolHooks` is pinned to `address(0)` (no hooks). Custody lives in the `ERC20LockBox`
///      (this pool is an authorized caller), so an RMN-rotation pool redeploy migrates NO funds — only
///      the lockbox's authorized-caller list changes. The rate-limiter is configured per-lane
///      POST-deploy via `applyChainUpdates` under the timelock (S7); OffRamp validation uses the
///      standard `router.isOffRamp` path. The Base side uses `SzAlphaTokenPool` (burn/mint) unchanged.
contract SzAlphaLockReleasePool is LockReleaseTokenPool {
    error LocalDecimalsNot18(uint8 provided);
    error RmnNotCanonical(address provided, address canonical);

    constructor(
        IERC20 token,
        uint8 localTokenDecimals,
        address rmnProxy,
        address router,
        address lockBox,
        address canonicalRmn
    ) LockReleaseTokenPool(token, localTokenDecimals, address(0), rmnProxy, router, lockBox) {
        if (localTokenDecimals != 18) revert LocalDecimalsNot18(localTokenDecimals);
        if (rmnProxy != canonicalRmn) revert RmnNotCanonical(rmnProxy, canonicalRmn);
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "SzAlphaLockReleasePool 1.0.0";
    }
}
