// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ZipcodeDeployAsserts} from "../src/ZipcodeDeployAsserts.sol";
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {ZipcodeController} from "../src/ZipcodeController.sol";
import {LienTokenFactory} from "../src/LienTokenFactory.sol";

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice A minimal 6-dp ERC20 so the registry ctor's `_getDecimals(quote_)` staticcall returns 6 (the registry
///         only reads `decimals()` at construction; the gate never touches the quote). Avoids a fork — the gate is
///         a pure view of state and the controller ctor only stores immutables.
contract MockUSDC {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice Thin external wrapper so `vm.expectRevert` can target the `internal` library call (an internal library
///         fn cannot be `vm.expectRevert`-pranked directly).
contract GateHarness {
    function gate(address c, address r) external view {
        ZipcodeDeployAsserts.requireIdentityWired(c, r);
    }
}

/// @title ZipcodeDeployIdentityGate test (WOOF-10a — the S11 renounce-before-identity pre-gate, §9)
/// @notice Proves `ZipcodeDeployAsserts.requireIdentityWired` against the REAL keepsake contracts
///         (`ZipcodeOracleRegistry` WOOF-02 + `ZipcodeController` WOOF-05), in three classes:
///         NEGATIVE (gate reverts when unwired), POSITIVE (gate passes → renounce → frozen), and NEGATIVE-CONTROL
///         (the dormant-identity vuln the gate prevents). No fork: the registry ctor only reads `quote.decimals()`
///         (satisfied by a 6-dp mock) and the controller ctor only stores immutables.
contract ZipcodeDeployIdentityGateTest is Test {
    GateHarness internal harness;

    MockUSDC internal usdc;
    LienTokenFactory internal lienFactory;
    ZipcodeOracleRegistry internal registry;
    ZipcodeController internal controller;

    // EOAs / stubs (any non-zero address satisfies the controller ctor zero-checks; origination is never exercised).
    address internal FORWARDER = makeAddr("forwarder");
    address internal VENUE_STUB = makeAddr("venueStub");
    address internal EREBOR = makeAddr("erebor");
    address internal WORKFLOW_OWNER = makeAddr("workflowOwner");

    uint256 internal constant VALIDITY = 365 days;
    bytes32 internal constant WID = bytes32(uint256(0xC0FFEE));
    bytes32 internal constant WRONG_WID = bytes32(uint256(0xBAD1D));

    function setUp() public {
        harness = new GateHarness();

        usdc = new MockUSDC();
        lienFactory = new LienTokenFactory();

        // CONTROLLER_OWNER = address(this): the test is the deployer/owner of both receivers, so it can set
        // identity / setController / renounce.
        registry = new ZipcodeOracleRegistry(FORWARDER, address(usdc), VALIDITY);
        controller = new ZipcodeController(
            FORWARDER, VENUE_STUB, address(lienFactory), address(registry), EREBOR
        );

        assertEq(controller.owner(), address(this), "test owns controller");
        assertEq(registry.owner(), address(this), "test owns registry");
    }

    // ============================================================
    // NEGATIVE — the tested gate (the obligations' REQUIRED negative)
    // ============================================================

    /// @dev F-3 case: identity unset (getExpectedWorkflowId == 0) but registry seeded. Gate BLOCKS renounce.
    function test_Negative_IdentityUnset_GateReverts() public {
        // registry.setController DONE (controller() != 0)...
        registry.setController(address(controller));
        // ...but controller identity NEVER set.
        assertEq(controller.getExpectedWorkflowId(), bytes32(0), "identity unset");
        assertTrue(registry.controller() != address(0), "registry seeded");

        vm.expectRevert(
            abi.encodeWithSelector(
                ZipcodeDeployAsserts.IdentityNotWired.selector, address(controller), address(registry)
            )
        );
        harness.gate(address(controller), address(registry));
    }

    /// @dev F7 case: controller identity set (id != 0) but registry.setController SKIPPED (controller() == 0).
    function test_Negative_ControllerUnset_GateReverts() public {
        controller.setExpectedWorkflowId(WID);
        assertTrue(controller.getExpectedWorkflowId() != bytes32(0), "identity set");
        assertEq(registry.controller(), address(0), "registry unseeded");

        vm.expectRevert(
            abi.encodeWithSelector(
                ZipcodeDeployAsserts.IdentityNotWired.selector, address(controller), address(registry)
            )
        );
        harness.gate(address(controller), address(registry));
    }

    /// @dev Sanity: both unset → reverts.
    function test_Negative_BothUnset_GateReverts() public {
        assertEq(controller.getExpectedWorkflowId(), bytes32(0), "identity unset");
        assertEq(registry.controller(), address(0), "registry unseeded");

        vm.expectRevert(
            abi.encodeWithSelector(
                ZipcodeDeployAsserts.IdentityNotWired.selector, address(controller), address(registry)
            )
        );
        harness.gate(address(controller), address(registry));
    }

    // ============================================================
    // POSITIVE — gate passes → renounce → frozen (audit S11 post-state)
    // ============================================================

    function test_Positive_GatePasses_ThenRenounce_ThenFrozen() public {
        // S10b: set identity. S6: seed the registry controller.
        controller.setExpectedAuthor(WORKFLOW_OWNER);
        controller.setExpectedWorkflowId(WID);
        registry.setController(address(controller));

        // The gate passes (no revert) when BOTH are wired.
        harness.gate(address(controller), address(registry));

        // S11: renounce succeeds.
        controller.renounceOwnership();
        assertEq(controller.owner(), address(0), "controller owner renounced");

        // Post-renounce every inherited owner-gated setter reverts OwnableUnauthorizedAccount.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        controller.setForwarderAddress(makeAddr("anything"));

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        controller.setExpectedAuthor(makeAddr("anything"));

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        controller.setExpectedWorkflowId(bytes32(uint256(0xDEAD)));

        // The registry's set-once is frozen too.
        registry.renounceOwnership();
        assertEq(registry.owner(), address(0), "registry owner renounced");
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.setController(makeAddr("anything"));
    }

    // ============================================================
    // NEGATIVE-CONTROL — demonstrate the vuln the gate prevents (dormant identity)
    // ============================================================

    function test_NegativeControl_DormantVsActiveIdentity_SelectorDifference() public {
        // Packed metadata with a WRONG workflowId (_decodeMetadata reads fixed offsets 32/64/74 → abi.encodePacked,
        // NOT abi.encode).
        bytes memory metadataWrongId = abi.encodePacked(WRONG_WID, bytes10(0), WORKFLOW_OWNER);

        // (a) Dormant: identity NEVER set, controller renounced from owner → permanently unwired. A wrong-id
        //     reportType-3 onReport gets PAST the (skipped) identity gate and reverts on DISPATCH:
        //     UnsupportedReportType(3). This IS the vuln the S11 gate prevents.
        assertEq(controller.getExpectedWorkflowId(), bytes32(0), "identity dormant");
        controller.renounceOwnership();

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(3))
        );
        controller.onReport(metadataWrongId, abi.encode(uint8(3), bytes("")));

        // (b) Gate-active: a SEPARATE controller (NOT renounced → identity still settable). After
        //     setExpectedWorkflowId(WID), the SAME wrong-id report reverts InvalidWorkflowId FIRST (identity gate
        //     fires before dispatch). The SELECTOR DIFFERENCE is the proof.
        ZipcodeController controller2 = new ZipcodeController(
            FORWARDER, VENUE_STUB, address(lienFactory), address(registry), EREBOR
        );
        controller2.setExpectedWorkflowId(WID);

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, WRONG_WID, WID)
        );
        controller2.onReport(metadataWrongId, abi.encode(uint8(3), bytes("")));
    }
}
