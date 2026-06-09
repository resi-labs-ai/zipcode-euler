// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

/// @notice Base-mainnet (8453) fork helper. Integration/fork tests inherit this.
/// Pins the fork to the `base` rpc endpoint (BASE_RPC_URL) — Base mainnet is BOTH
/// the deploy target AND the fork/integration-test target (decision 2026-06-06).
abstract contract ForkConfig is Test {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @dev PINNED fork block (2026-06-09). Pinning makes the fork deterministic: an unpinned
    /// `createSelectFork("base")` forks at *latest*, so fixed-amount deposits into live third-party
    /// vaults (e.g. the 8-B6 WETH/USDC ICHI stand-in) intermittently revert `DTL` as live state drifts.
    /// Re-pin to a newer block if a test needs a more recent on-chain deployment.
    uint256 internal constant BASE_FORK_BLOCK = 47096000;

    uint256 internal baseFork;

    function _selectBaseFork() internal {
        baseFork = vm.createSelectFork("base", BASE_FORK_BLOCK);
        assertEq(block.chainid, BASE_CHAIN_ID, "not on Base mainnet");
    }
}
