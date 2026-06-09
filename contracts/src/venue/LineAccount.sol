// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

/// @title LineAccount
/// @notice A minimal per-line EVC owner contract (§4.4 borrower-of-record), CREATE2-deployed by the venue adapter
///         inside `openLine` (salt = `lienId`). Its deterministic address establishes a fresh EVC owner-prefix; in
///         its constructor it registers that prefix and grants the borrow-driver (the adapter) the EVC operator bit
///         over its own **code-free** borrow account (sub-account 1 of its prefix). After construction it is inert —
///         the cluster is abandoned at close (the on-chain "graveyard," §4.4/§17). Constructor-only: no state, no
///         admin, no teardown.
contract LineAccount {
    /// @param evc_ The Ethereum Vault Connector.
    /// @param operator_ The EVC operator to authorize over the borrow account. The adapter passes
    ///        `operator_ = address(this)` (the adapter itself — the `EVC.call` `msg.sender` on the borrow path).
    constructor(address evc_, address operator_) {
        // Sub-account 1 of this contract's own prefix: shares the 19-byte prefix, and is code-free (a plain
        // account address, not this contract's coded address) so the EVC's non-owner-must-be-code-free guard
        // (EthereumVaultConnector.sol:787) does NOT trip on the operator path.
        address borrowAccount = address(uint160(address(this)) ^ 1);

        // Owner-self path: authenticateCaller(borrowAccount, allowOperator:true) finds the shared prefix, registers
        // this contract as the prefix owner, then sets the operator bit for `operator_` over sub-account 1.
        IEVC(evc_).setAccountOperator(borrowAccount, operator_, true);
    }
}
