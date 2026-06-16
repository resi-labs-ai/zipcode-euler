// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Ownable} from "@gnosis-guild/zodiac-core/factory/Ownable.sol";
import {IReceiver} from "x402-cre-price-alerts/interfaces/IReceiver.sol";
import {IERC165} from "x402-cre-price-alerts/interfaces/IERC165.sol";

/// @title CloneReportReceiver
/// @notice A clone-compatible (EIP-1167-safe) re-implementation of the Chainlink CRE Keystone report-receiver
///         surface, to be mixed into a zodiac `Module` so a DON-signed `Report` delivered through the immutable
///         Keystone Forwarder can drive the module ALONGSIDE its operator hot-key (§8.0 report envelope / §8.7
///         operator path / §17 Timelock-settable wiring).
///
/// @dev WHY NOT inherit `ReceiverTemplate`
///      (`reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`):
///      (a) it extends **OpenZeppelin** `Ownable`, which would clash with the module's zodiac `Ownable`
///          (two `owner`s); and
///      (b) it sets its forwarder in its **constructor** — which an EIP-1167 clone NEVER runs, so a cloned
///          `ReceiverTemplate` has a ZERO forwarder, and its gate ("zero ⇒ open") leaves `onReport` callable
///          by ANYONE. This base INVERTS that: zero forwarder ⇒ FAIL CLOSED (inert socket).
///
/// @dev INHERITANCE / MRO: this is `is Ownable` where `Ownable` is **zodiac-core's**
///      `reference/zodiac-core/contracts/factory/Ownable.sol` — the SAME base the module's `Module` already
///      derives from. C3 linearization merges it to ONE `owner`/`onlyOwner` (no second Ownable). This base has
///      NO constructor (clone-safe) and reuses the module's existing `owner`/`onlyOwner` for its setters.
///
/// @dev REUSABLE: this carries NO buy-burn-specific logic — only the report socket + workflow identity + the
///      `_processReport` hook — so the other szipUSD operator/controller modules can adopt it later unchanged.
abstract contract CloneReportReceiver is Ownable, IReceiver {
    // --------------------------------------------------------------------- set-once / Timelock-settable wiring (§17)
    /// @notice The Keystone Forwarder allowed to call `onReport`. ZERO ⇒ the socket is INERT (fail-closed). A fresh
    ///         clone starts all-zero; the Timelock wires this post-clone. Zero is the intended inert default — NO
    ///         zero-guard on the setter.
    address public forwarder;
    /// @notice Optional workflow-id identity check. When non-zero, `onReport` decodes the metadata and rejects a
    ///         mismatched workflow id. Zero ⇒ this check is disabled.
    bytes32 public expectedWorkflowId;
    /// @notice Optional workflow-author (workflow owner) identity check. When non-zero, `onReport` decodes the
    ///         metadata and rejects a mismatched author. Zero ⇒ this check is disabled.
    address public expectedAuthor;

    // --------------------------------------------------------------------- errors
    error UnsupportedReportType(uint8 reportType);
    error InvalidForwarder(address sender, address expected);
    error InvalidWorkflowId(bytes32 received, bytes32 expected);
    error InvalidAuthor(address received, address expected);

    // --------------------------------------------------------------------- events
    /// @notice Reuses the module's existing `WiringSet(bytes32 indexed slot, address value)` convention for the
    ///         address-valued wiring slots (`"forwarder"` / `"expectedAuthor"`).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice The workflow-id wiring slot (a bytes32 value — does not fit the `WiringSet` address shape).
    event ExpectedWorkflowIdSet(bytes32 previousId, bytes32 newId);

    // --------------------------------------------------------------------- the report socket (IReceiver)
    /// @inheritdoc IReceiver
    /// @dev Fail-closed forwarder gate (the clone inversion — NOT ReceiverTemplate's "zero ⇒ open"): reverts when
    ///      the forwarder is unset OR the caller is not it. Then, only if a workflow identity is configured, decode
    ///      + check it. Then dispatch to `_processReport`.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // Fail CLOSED on an unset forwarder (a fresh clone is all-zero ⇒ inert until the Timelock wires it).
        if (forwarder == address(0) || msg.sender != forwarder) revert InvalidForwarder(msg.sender, forwarder);

        // Workflow identity, only when configured (mirrors ReceiverTemplate's checks; when both unset, the
        // forwarder gate alone applies).
        if (expectedWorkflowId != bytes32(0) || expectedAuthor != address(0)) {
            (bytes32 workflowId,, address workflowOwner) = _decodeMetadata(metadata);
            if (expectedWorkflowId != bytes32(0) && workflowId != expectedWorkflowId) {
                revert InvalidWorkflowId(workflowId, expectedWorkflowId);
            }
            if (expectedAuthor != address(0) && workflowOwner != expectedAuthor) {
                revert InvalidAuthor(workflowOwner, expectedAuthor);
            }
        }

        _processReport(report);
    }

    /// @notice Process the decoded report. Implemented by the concrete receiver (e.g. the buy-burn module routes the
    ///         §8.0 envelope to its `_postBid`/`_cancelBid` internals).
    /// @param report The report calldata containing the receiver's encoded data.
    function _processReport(bytes calldata report) internal virtual;

    // --------------------------------------------------------------------- Timelock-settable wiring setters (§17)
    /// @notice Wire/re-point the Keystone Forwarder. `onlyOwner` (Timelock). NO zero-guard — zero is the intended
    ///         inert ("socket off") state, fail-closed by `onReport`.
    function setForwarder(address forwarder_) external onlyOwner {
        forwarder = forwarder_;
        emit WiringSet("forwarder", forwarder_);
    }

    /// @notice Set/clear the expected workflow author (workflow owner). `onlyOwner` (Timelock). Zero ⇒ check off.
    function setExpectedAuthor(address expectedAuthor_) external onlyOwner {
        expectedAuthor = expectedAuthor_;
        emit WiringSet("expectedAuthor", expectedAuthor_);
    }

    /// @notice Set/clear the expected workflow id. `onlyOwner` (Timelock). Zero ⇒ check off.
    function setExpectedWorkflowId(bytes32 expectedWorkflowId_) external onlyOwner {
        bytes32 previousId = expectedWorkflowId;
        expectedWorkflowId = expectedWorkflowId_;
        emit ExpectedWorkflowIdSet(previousId, expectedWorkflowId_);
    }

    // --------------------------------------------------------------------- metadata decode (replicated, clone-safe)
    /// @notice Extract the workflow identity fields from the `onReport` metadata.
    /// @dev Replicated VERBATIM from `ReceiverTemplate._decodeMetadata`
    ///      (`reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`) — the canonical metadata
    ///      layout `abi.encodePacked(workflowId bytes32, workflowName bytes10, workflowOwner address)`:
    ///      - First 32 bytes: the dynamic-bytes length word.
    ///      - Offset 32, size 32: workflowId (bytes32)
    ///      - Offset 64, size 10: workflowName (bytes10)
    ///      - Offset 74, size 20: workflowOwner (address)
    ///      The `onReport(bytes calldata metadata,...)` arg is passed to this `bytes memory` param via an implicit
    ///      copy; the offsets do NOT change.
    function _decodeMetadata(bytes memory metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        assembly {
            workflowId := mload(add(metadata, 32))
            workflowName := mload(add(metadata, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }
        return (workflowId, workflowName, workflowOwner);
    }

    // --------------------------------------------------------------------- ERC165
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
