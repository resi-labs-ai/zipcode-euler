// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice The read face the deploy-time gate needs on every sealed `ReceiverTemplate`: the author + workflow-name
///         identity getters. Declared inline to avoid pulling `ReceiverTemplate`/`BaseAdapter` into the library's
///         compile unit. CTR-16: the gate now keys on author + workflowName (the per-receiver separate-daemon
///         posture), NOT the dropped shared `workflowId` pin.
interface IReceiverIdentity {
    function getExpectedAuthor() external view returns (address);
    function getExpectedWorkflowName() external view returns (bytes10);
}

/// @notice The single read face the deploy-time gate needs on the registry: the set-once controller getter
///         (the only contract with a `controller` getter, WOOF-02).
interface IOracleRegistryController {
    function controller() external view returns (address);
}

/// @title ZipcodeDeployAsserts (§9 / audit S11)
/// @notice The one load-bearing deploy-time assertion the item-10 deploy script calls IMMEDIATELY before the
///         irreversible ownership hand-off / renounce. It is the only defense against the dormant-identity vuln
///         (§4.4 / audit/3-results.md F1): `ReceiverTemplate.onReport`'s identity check is CONDITIONAL (each
///         expected slot is enforced only when set) and `onReport` / `setForwarderAddress` are non-virtual, so a
///         deploy that seals BEFORE wiring identity freezes the receiver in a Forwarder-sender-only state any
///         co-tenant workflow can drive. Symmetrically, sealing before `registry.setController` leaves
///         `controller == address(0)` so the registry is unseedable forever.
///
///         CTR-16: the gate asserts EACH sealed receiver individually (author + workflowName both set), dropping
///         the old "same WORKFLOW_ID on every subclass ⇒ one representative id ⇒ all wired" inference. Under the
///         separate-daemon model each receiver carries its OWN workflowName, so a missing/empty name on any one
///         (e.g. an unset `vm.envString`) must fail closed — a representative-only check would miss it.
///         A `library` `internal` view is the minimal shape: it compiles INTO the deploy script (no extra deployed
///         bytecode) and is purely a deploy-time concern.
library ZipcodeDeployAsserts {
    /// @notice A sealed `ReceiverTemplate` whose identity is incomplete: author unset OR workflowName unset. Either
    ///         leaves a co-tenant Forwarder workflow able to drive the receiver (F-3 dormancy / M4).
    error ReceiverIdentityNotWired(address receiver);

    /// @notice The registry's set-once controller is unseeded (`controller() == address(0)`) — the registry is
    ///         unseedable once ownership is handed off (F7 brick).
    error RegistryControllerUnset(address registry);

    /// @notice Fail-closed per-receiver identity gate for a single `ReceiverTemplate`. Reverts
    ///         `ReceiverIdentityNotWired` unless BOTH `getExpectedAuthor()` is non-zero AND
    ///         `getExpectedWorkflowName()` is non-zero (the CTR-16 author+name posture; `onReport` enforces the name
    ///         only when the author is also set, so both are load-bearing).
    /// @param receiver A sealed CRE `ReceiverTemplate` (controller / registry / warehouse adapter / coordinator /
    ///        navOracle / rateOracle / the un-looped CRE-push lpOracle).
    function requireReceiverIdentityWired(address receiver) internal view {
        if (
            IReceiverIdentity(receiver).getExpectedAuthor() == address(0)
                || IReceiverIdentity(receiver).getExpectedWorkflowName() == bytes10(0)
        ) revert ReceiverIdentityNotWired(receiver);
    }

    /// @notice The combined fail-closed S11 pre-gate. Asserts EACH receiver in `receivers` is fully sealed
    ///         (author + workflowName) AND the registry's set-once controller is seeded. Reverts on the FIRST
    ///         unwired receiver (`ReceiverIdentityNotWired`) or on the unseeded registry (`RegistryControllerUnset`).
    ///         Passes only when every receiver is sealed and the registry is seeded.
    /// @param receivers Every sealed `ReceiverTemplate` in the fleet (asserted individually — CTR-16 drops the
    ///        representative-id inference). The registry is itself a receiver and SHOULD appear here too.
    /// @param registry The `ZipcodeOracleRegistry` (the only contract with a set-once `controller` getter).
    function requireIdentityWired(address[] memory receivers, address registry) internal view {
        for (uint256 k = 0; k < receivers.length; k++) {
            requireReceiverIdentityWired(receivers[k]);
        }
        if (IOracleRegistryController(registry).controller() == address(0)) {
            revert RegistryControllerUnset(registry);
        }
    }
}
