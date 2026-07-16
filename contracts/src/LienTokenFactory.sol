// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {LienCollateralToken} from "./LienCollateralToken.sol";

/// @title LienTokenFactory
/// @notice Deploys LienCollateralToken instances via CREATE2 with salt = keccak256(abi.encode(lienId)), so the
///         controller/CRE can precompute a lien's address from lienId before the origination batch. The new token's
///         authority is the caller (msg.sender) — caller-binding is the authorization, no gate. Stores no mapping;
///         identity is the address, recoverable via computeAddress + the LienCreated event.
contract LienTokenFactory {
    /// @notice The canonical decimals pin every lien token shares; the registry validates a key's decimals() against
    ///         this before caching.
    uint8 public constant LIEN_DECIMALS = 18;

    /// @notice Records the lienId -> deployed address link on-chain for off-chain indexing. Both args indexed.
    event LienCreated(bytes32 indexed lienId, address indexed lien);

    /// @notice Deploy a LienCollateralToken for `lienId`, authorized to the caller. Reverts (Errors.FailedDeployment)
    ///         if the (lienId, caller) slot is already occupied — dedup / single-use lienId forever for that caller.
    /// @param lienId The lien identifier; salt = keccak256(abi.encode(lienId)).
    /// @return lien The deployed token address.
    function create(bytes32 lienId) external returns (address lien) {
        bytes32 salt = keccak256(abi.encode(lienId));
        bytes memory initCode =
            abi.encodePacked(type(LienCollateralToken).creationCode, abi.encode(msg.sender));
        lien = Create2.deploy(0, salt, initCode);
        emit LienCreated(lienId, lien);
    }

    /// @notice Precompute the address a `create(lienId)` from `controller` will (or did) deploy to. Two-arg: a pure
    ///         prediction has no msg.sender authority semantics — anyone must be able to predict any lien's address.
    /// @param lienId The lien identifier.
    /// @param controller The deploying caller whose authority binds into the init-code.
    /// @return The deterministic CREATE2 address (this factory as deployer).
    function computeAddress(bytes32 lienId, address controller) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(lienId));
        bytes memory initCode =
            abi.encodePacked(type(LienCollateralToken).creationCode, abi.encode(controller));
        return Create2.computeAddress(salt, keccak256(initCode));
    }
}
