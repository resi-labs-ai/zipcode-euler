// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

/// @notice Minimal local view of the EVK GenericFactory — only the proxy check is needed.
interface IGenericFactory {
    function isProxy(address proxy) external view returns (bool);
}

/// @notice Minimal local view of the EVC — only the operator-authorization predicate is needed.
/// @dev Pins the exact selector of `isAccountOperatorAuthorized(address,address)`.
interface IEVC {
    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool);
}

/// @title CREGatingHook
/// @notice EVK hook target (§4.3) gating `borrow`/`liquidate` on the lien markets to the line's
/// borrow-driver. The hook authorizes the appended EVC on-behalf account (the fresh per-line borrow
/// account, §4.4) **only** when it has granted the `borrowDriver` (the venue adapter = the `EVC.call`
/// caller = EVC operator) the operator bit. `repay` is never installed in `hookedOps`, so it stays
/// permissionless; the hook itself is op-agnostic.
/// @dev Replicates `BaseHookTarget` (reference/evk-periphery) logic inline because evk-periphery is not
/// in the remap set — the `isProxy`-guarded `isHookTarget()` and the `isProxy`-guarded `_msgSender()`
/// calldata extraction. The gate is operator-authorization, NOT an owner / haveCommonOwner check: the
/// per-line borrow account has its own owner-prefix and shares no prefix with the borrowDriver.
contract CREGatingHook is IHookTarget {
    /// @notice The EVK vault factory; used to validate the caller is a factory proxy (vault).
    IGenericFactory public immutable eVaultFactory;
    /// @notice The Ethereum Vault Connector; queried for operator authorization.
    IEVC public immutable evc;
    /// @notice The EVC operator that drives the borrow (the venue adapter / `EVC.call` caller).
    /// @dev NOT the controller — the address EVC authenticates as the operator of each per-line account.
    address public immutable borrowDriver;

    /// @notice Thrown when the appended on-behalf account has not authorized `borrowDriver` as its
    /// EVC operator. Named so it does NOT imply the controller specifically.
    error NotAuthorizedOperator();

    /// @param eVaultFactory_ The EVK GenericFactory that deployed the lien vaults.
    /// @param evc_ The Ethereum Vault Connector.
    /// @param borrowDriver_ The venue adapter address (EVC operator / `EVC.call` caller).
    constructor(address eVaultFactory_, address evc_, address borrowDriver_) {
        eVaultFactory = IGenericFactory(eVaultFactory_);
        evc = IEVC(evc_);
        borrowDriver = borrowDriver_;
    }

    /// @inheritdoc IHookTarget
    /// @dev Returns the magic value only when called by a recognized factory proxy (a vault).
    function isHookTarget() external view override returns (bytes4) {
        if (eVaultFactory.isProxy(msg.sender)) return this.isHookTarget.selector;
        else return 0;
    }

    /// @notice The only gate: the appended on-behalf account (the per-line borrow account) must have
    /// authorized `borrowDriver` as its EVC operator. Op-agnostic; reverts with no return data.
    /// @dev Non-payable — the EVK invokes the hook with no value.
    fallback() external {
        address caller = _msgSender();
        if (!evc.isAccountOperatorAuthorized(caller, borrowDriver)) revert NotAuthorizedOperator();
    }

    /// @notice Extracts the on-behalf account appended by the EVK (`abi.encodePacked(msg.data, caller)`),
    /// but trusts the appended 20 bytes ONLY when `msg.sender` is a factory proxy — otherwise a non-vault
    /// caller could spoof an authorized account. Replicates `BaseHookTarget._msgSender()` verbatim.
    function _msgSender() internal view returns (address msgSender) {
        if (!eVaultFactory.isProxy(msg.sender)) return msg.sender;

        assembly {
            msgSender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
