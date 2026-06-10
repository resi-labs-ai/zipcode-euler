// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {BurnMintTokenPool} from "chainlink-ccip/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

/// @title SzAlphaTokenPool — the CCT BurnMintTokenPool for szALPHA (both chains).
/// @notice A thin subclass of the audited `BurnMintTokenPool` (burn-on-source / mint-on-dest) that adds
///         two deploy-time invariants the security review requires:
///           - S8: `localTokenDecimals == 18` (cross-chain conservation depends on equal decimals); and
///           - S9: the wired `rmnProxy` equals the chain's canonical ARMProxy (immutable in `TokenPool`;
///                 redeploy — never mutate — on an RMN rotation).
/// @dev `advancedPoolHooks` is pinned to `address(0)` (no hooks). The rate-limiter is configured per-lane
///      POST-deploy via `applyChainUpdates` under the timelock (S7); OffRamp validation uses the standard
///      `router.isOffRamp` path (offRamps rotate on legit CCIP upgrades — never hardcoded).
contract SzAlphaTokenPool is BurnMintTokenPool {
    error LocalDecimalsNot18(uint8 provided);
    error RmnNotCanonical(address provided, address canonical);

    constructor(IBurnMintERC20 token, uint8 localTokenDecimals, address rmnProxy, address router, address canonicalRmn)
        BurnMintTokenPool(token, localTokenDecimals, address(0), rmnProxy, router)
    {
        if (localTokenDecimals != 18) revert LocalDecimalsNot18(localTokenDecimals);
        if (rmnProxy != canonicalRmn) revert RmnNotCanonical(rmnProxy, canonicalRmn);
    }

    function typeAndVersion() external pure override returns (string memory) {
        return "SzAlphaTokenPool 1.0.0";
    }
}
