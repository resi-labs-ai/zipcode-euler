// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice The single read face the deploy-time gate needs on the controller (the representative
///         `ReceiverTemplate`): the workflow-identity getter. Declared inline to avoid pulling
///         `ReceiverTemplate`/`BaseAdapter` into the library's compile unit.
interface IReceiverIdentity {
    function getExpectedWorkflowId() external view returns (bytes32);
}

/// @notice The single read face the deploy-time gate needs on the registry: the set-once controller getter
///         (the only contract with a `controller` getter, WOOF-02).
interface IOracleRegistryController {
    function controller() external view returns (address);
}

/// @title ZipcodeDeployAsserts (§9 / audit S11)
/// @notice The one load-bearing deploy-time assertion the item-10 deploy script calls IMMEDIATELY before the
///         irreversible `controller.renounceOwnership()` / `registry.renounceOwnership()`. It is the only defense
///         against the dormant-identity vuln (§4.4 / audit/3-results.md F1): `ReceiverTemplate.onReport`'s
///         workflow-identity check is CONDITIONAL (runs only when an expected value is non-zero) and `onReport` /
///         `setForwarderAddress` are non-virtual, so a deploy that renounces BEFORE wiring identity freezes the
///         receiver in a Forwarder-sender-only state any co-tenant workflow can drive. Symmetrically, renouncing
///         before `registry.setController` leaves `controller == address(0)` so the registry is unseedable forever.
///         A `library` `internal` view is the minimal shape: it compiles INTO the deploy script (no extra deployed
///         bytecode), spans the two contracts, and is purely a deploy-time concern.
library ZipcodeDeployAsserts {
    /// @notice Either the controller's workflow identity is unset (F-3 dormancy) OR the registry's controller is
    ///         unseeded (F7 brick) — a `renounceOwnership()` here is fail-closed BLOCKED.
    error IdentityNotWired(address controller, address registry);

    /// @notice The combined fail-closed S11 pre-gate. Reverts `IdentityNotWired` if EITHER the controller's
    ///         `getExpectedWorkflowId()` is `bytes32(0)` (identity unset) OR the registry's `controller()` is
    ///         `address(0)` (registry unseedable). Passes only when BOTH are wired.
    /// @param controller The representative `ReceiverTemplate` receiver (§9/S10b sets the same WORKFLOW_ID on every
    ///        subclass, so a non-zero controller id ⇒ the registry id was wired in the same loop).
    /// @param registry The `ZipcodeOracleRegistry` (the only contract with a set-once `controller` getter).
    function requireIdentityWired(address controller, address registry) internal view {
        if (
            IReceiverIdentity(controller).getExpectedWorkflowId() == bytes32(0)
                || IOracleRegistryController(registry).controller() == address(0)
        ) revert IdentityNotWired(controller, registry);
    }
}
