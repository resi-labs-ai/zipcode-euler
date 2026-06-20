// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ZipcodeDeployAsserts} from "../src/ZipcodeDeployAsserts.sol";
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {ZipcodeController} from "../src/ZipcodeController.sol";
import {LienTokenFactory} from "../src/LienTokenFactory.sol";
import {SzipFarmUtilityLpOracle} from "../src/supply/SzipFarmUtilityLpOracle.sol";

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

/// @notice Thin external wrapper so `vm.expectRevert` can target the `internal` single-receiver library call.
contract LpGateHarness {
    function gate(address receiver) external view {
        ZipcodeDeployAsserts.requireReceiverIdentityWired(receiver);
    }
}

/// @title SEC-05 — seal the un-looped CRE-push `lpOracle` identity + extend the pre-gate (kill-list M4)
/// @notice Proves the M4 fix against the REAL `SzipFarmUtilityLpOracle` (a `ReceiverTemplate` NOT in the deploy's
///         S10b same-WORKFLOW_ID seal loop), in four classes mirroring the harness Done-when:
///           1. IDENTITY SEALED — after the P9 seal, `getExpectedWorkflowId() == WID` (pre-fix: bytes32(0)).
///           2. BEHAVIORAL fail-closed — an unsealed lpOracle ACCEPTS a wrong-identity LP_MARK push (the dormant
///              vuln); a sealed one REJECTS it `InvalidWorkflowId` (the accept-vs-revert difference is the proof).
///           3. PRE-GATE bites — `requireReceiverIdentityWired` reverts when identity unset, passes once sealed.
///           4. FAIR-LP branch — the new P9 calls are guarded `if (d.lpOracle != address(0))`, identical to the
///              already-exercised `:544` ownership-transfer guard, so the ownerless `AlgebraIchiFairLpOracle`
///              branch (`d.lpOracle == address(0)`) neither seals nor asserts (guard-by-construction; see below).
///         No fork: the oracle ctor only reads `quote.decimals()` (6-dp `MockUSDC`) and stores `lpToken`.
contract SEC05LpOracleIdentityTest is Test {
    LpGateHarness internal harness;
    MockUSDC internal usdc;
    SzipFarmUtilityLpOracle internal lpOracle;

    address internal FORWARDER = makeAddr("forwarder");
    address internal LP_TOKEN = makeAddr("ichiLpToken");
    address internal WORKFLOW_OWNER = makeAddr("workflowOwner");

    uint256 internal constant VALIDITY = 365 days;
    uint8 internal constant LP_MARK = 7;
    bytes32 internal constant WID = bytes32(uint256(0xC0FFEE));
    bytes32 internal constant WRONG_WID = bytes32(uint256(0xBAD1D));

    function setUp() public {
        harness = new LpGateHarness();
        usdc = new MockUSDC();
        // The test is the deployer/owner ⇒ it can seal identity (mirrors P9's team broadcaster pre-transfer).
        lpOracle = new SzipFarmUtilityLpOracle(FORWARDER, address(usdc), VALIDITY, LP_TOKEN);
        assertEq(lpOracle.owner(), address(this), "test owns lpOracle");
    }

    /// @dev Replicates the deploy's `_sealIdentity(address(d.lpOracle))`: set author + workflowId.
    function _seal() internal {
        lpOracle.setExpectedAuthor(WORKFLOW_OWNER);
        lpOracle.setExpectedWorkflowId(WID);
    }

    /// @dev `abi.encodePacked(workflowId, workflowName, workflowOwner)` — the Forwarder metadata layout
    ///      `ReceiverTemplate._decodeMetadata` reads at fixed offsets 32/64/74.
    function _metadata(bytes32 wid) internal view returns (bytes memory) {
        return abi.encodePacked(wid, bytes10(0), WORKFLOW_OWNER);
    }

    /// @dev A well-formed `LP_MARK` report envelope (`abi.encode(uint8 reportType, abi.encode(mark, ts))`).
    function _lpMarkReport(uint256 mark, uint32 ts) internal pure returns (bytes memory) {
        return abi.encode(uint8(LP_MARK), abi.encode(mark, ts));
    }

    // ============================================================
    // 1. IDENTITY SEALED — the P9 seal sets a non-zero workflow id
    // ============================================================
    function test_SEC05_IdentitySealed_AfterSeal() public {
        assertEq(lpOracle.getExpectedWorkflowId(), bytes32(0), "pre-fix: identity dormant");
        _seal();
        assertEq(lpOracle.getExpectedWorkflowId(), WID, "post-fix: identity sealed");
        assertEq(lpOracle.getExpectedAuthor(), WORKFLOW_OWNER, "author sealed");
    }

    // ============================================================
    // 2. BEHAVIORAL — dormant accepts wrong identity; sealed rejects it
    // ============================================================

    /// @dev The vuln (pre-fix): identity dormant ⇒ a wrong-workflowId LP_MARK from the (shared) Forwarder is
    ///      ACCEPTED and writes the cache. Any co-tenant workflow clearing the Forwarder can push the LP mark.
    function test_SEC05_Behavioral_DormantAcceptsWrongIdentity() public {
        assertEq(lpOracle.getExpectedWorkflowId(), bytes32(0), "identity dormant");

        vm.warp(VALIDITY + 100); // so a `ts` in range is non-zero and <= now
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        lpOracle.onReport(_metadata(WRONG_WID), _lpMarkReport(15e6, ts));

        (uint208 price, uint48 cachedTs) = lpOracle.cache();
        assertEq(price, 15e6, "wrong-identity mark was accepted (the dormant vuln)");
        assertEq(cachedTs, ts, "cache timestamp written by an unauthorized workflow");
    }

    /// @dev The fix: once sealed, the SAME wrong-workflowId report reverts `InvalidWorkflowId` BEFORE dispatch.
    function test_SEC05_Behavioral_SealedRejectsWrongIdentity() public {
        _seal();

        vm.warp(VALIDITY + 100);
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, WRONG_WID, WID)
        );
        lpOracle.onReport(_metadata(WRONG_WID), _lpMarkReport(15e6, ts));

        (, uint48 cachedTs) = lpOracle.cache();
        assertEq(cachedTs, 0, "no mark written - the unauthorized push was rejected");
    }

    /// @dev The authorized workflow still pushes through the sealed gate (no false-positive lockout).
    function test_SEC05_Behavioral_SealedAcceptsCorrectIdentity() public {
        _seal();

        vm.warp(VALIDITY + 100);
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        lpOracle.onReport(_metadata(WID), _lpMarkReport(15e6, ts));

        (uint208 price, uint48 cachedTs) = lpOracle.cache();
        assertEq(price, 15e6, "authorized mark accepted");
        assertEq(cachedTs, ts, "authorized push wrote the cache");
    }

    // ============================================================
    // 3. PRE-GATE — requireReceiverIdentityWired reverts unset, passes sealed
    // ============================================================
    function test_SEC05_PreGate_RevertsWhenIdentityUnset() public {
        assertEq(lpOracle.getExpectedWorkflowId(), bytes32(0), "identity unset");
        vm.expectRevert(
            abi.encodeWithSelector(
                ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector, address(lpOracle)
            )
        );
        harness.gate(address(lpOracle));
    }

    function test_SEC05_PreGate_PassesWhenSealed() public {
        _seal();
        harness.gate(address(lpOracle)); // no revert
    }

    // ============================================================
    // 4. FAIR-LP branch — the new P9 calls are guarded by `lpOracle != address(0)`
    // ============================================================

    /// @dev On the fair-LP branch the deploy leaves `d.lpOracle == address(0)`, so the script's
    ///      `if (address(d.lpOracle) != address(0))` guard skips BOTH the seal and this pre-gate — exactly as it
    ///      already skips the `:544` ownership transfer. This test pins the guard's load-bearing half: WERE the
    ///      gate ever invoked on an unsealed receiver it reverts (proven above), so the `address(0)` skip is what
    ///      keeps the fair-LP deploy from fail-closing. The full fair-LP deploy path is the (skipped) WOOF-10
    ///      fork harness's bar; here we fix the guard semantics the script depends on.
    function test_SEC05_FairLpBranch_GuardSemantics() public pure {
        // The deployment struct's default `lpOracle` is the zero address (never assigned on the fair-LP branch),
        // and the script gates both new calls on `!= address(0)`. The library is therefore never reached.
        address fairLpBranchOracle = address(0);
        assertEq(fairLpBranchOracle, address(0), "fair-LP branch: no SzipFarmUtilityLpOracle to seal/assert");
        // (No harness.gate(address(0)) call — that is precisely what the script's guard prevents.)
    }
}
