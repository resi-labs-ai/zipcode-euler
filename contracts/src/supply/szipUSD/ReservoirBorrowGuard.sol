// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

/// @notice Minimal local view of the EVK GenericFactory — only the proxy check is needed.
interface IGenericFactory {
    function isProxy(address proxy) external view returns (bool);
}

/// @title ReservoirBorrowGuard
/// @notice EVK hook target (§4.3) installed on the reservoir USDC borrow vault at `OP_BORROW` (security F8a). The
///         reservoir borrow vault IS the warehouse's shared resting USDC (idle depositor cash); without this guard any
///         ICHI-LP holder could post the escrow collateral on their OWN EVC account and lever that shared USDC. The
///         guard pins `OP_BORROW` to the engine Safe: a borrow is allowed ONLY when the EVK-appended on-behalf account
///         `== juniorTrancheEngine` (else revert `NotEngineSafe`). The engine Safe borrows on its own account (no operator,
///         §4.5.1) so the gate is account-identity, NOT operator-authorization — distinct from `CREGatingHook`
///         (which gates `isAccountOperatorAuthorized`, the per-line `LineAccount` model). Op-agnostic; installed only
///         on `OP_BORROW`, so it only ever guards borrows.
/// @dev Replicates `BaseHookTarget` (reference/evk-periphery) logic inline (evk-periphery is not remapped): the
///      `isProxy`-guarded `isHookTarget()` and the `isProxy`-guarded `_msgSender()` calldata extraction. Modeled
///      verbatim on `src/CREGatingHook.sol` with the gate body swapped.
contract ReservoirBorrowGuard is IHookTarget {
    /// @notice The EVK vault factory; used to validate the caller is a factory proxy (vault).
    IGenericFactory public eVaultFactory;
    /// @notice The engine Safe — the ONLY account permitted to borrow the reservoir's resting USDC.
    address public juniorTrancheEngine;
    /// @notice The Timelock admin (build phase, §17). NOT OZ `Ownable` — the inherited `Context._msgSender()` would
    ///         collide with this hook's EVK trailing-data `_msgSender()` decoder; `onlyOwner` checks `msg.sender`
    ///         DIRECTLY (the admin is never an EVK on-behalf call).
    address public owner;

    /// @notice Thrown when the appended on-behalf account is not the engine Safe.
    error NotEngineSafe();
    /// @notice Thrown when a wiring re-point is given the zero address.
    error ZeroAddress();
    /// @notice Thrown when a non-owner calls an admin function.
    error NotOwner();

    /// @notice A Timelock-settable wiring field was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice Ownership transferred (build phase admin).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev Admin gate — checks the RAW `msg.sender`, never the hook `_msgSender()` decoder.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param eVaultFactory_ The EVK GenericFactory that deployed the reservoir vaults.
    /// @param juniorTrancheEngine_ The szipUSD engine Safe (the sole legal borrower).
    constructor(address eVaultFactory_, address juniorTrancheEngine_) {
        eVaultFactory = IGenericFactory(eVaultFactory_);
        juniorTrancheEngine = juniorTrancheEngine_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Transfer the build-phase admin (to the Timelock). `onlyOwner`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Timelock-settable wiring (build phase, §17) ---
    /// @notice Re-point `eVaultFactory` (build phase, §17). onlyOwner (Timelock).
    function setEVaultFactory(address eVaultFactory_) external onlyOwner {
        if (eVaultFactory_ == address(0)) revert ZeroAddress();
        eVaultFactory = IGenericFactory(eVaultFactory_);
        emit WiringSet("eVaultFactory", eVaultFactory_);
    }

    /// @notice Re-point `juniorTrancheEngine` (build phase, §17). onlyOwner (Timelock).
    function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
        if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
        juniorTrancheEngine = juniorTrancheEngine_;
        emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
    }

    /// @inheritdoc IHookTarget
    /// @dev Returns the magic value only when called by a recognized factory proxy (a vault).
    function isHookTarget() external view override returns (bytes4) {
        if (eVaultFactory.isProxy(msg.sender)) return this.isHookTarget.selector;
        else return 0;
    }

    /// @notice The only gate: the appended on-behalf account must be the engine Safe. Op-agnostic; reverts with no
    ///         return data. Non-payable — the EVK invokes the hook with no value.
    fallback() external {
        if (_msgSender() != juniorTrancheEngine) revert NotEngineSafe();
    }

    /// @notice Extracts the on-behalf account appended by the EVK (`abi.encodePacked(msg.data, caller)`), but trusts
    ///         the appended 20 bytes ONLY when `msg.sender` is a factory proxy — otherwise a non-vault caller could
    ///         spoof an authorized account. Replicates `BaseHookTarget._msgSender()` verbatim.
    function _msgSender() internal view returns (address msgSender) {
        if (!eVaultFactory.isProxy(msg.sender)) return msg.sender;

        assembly {
            msgSender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
