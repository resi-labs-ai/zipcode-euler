// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ZipcodeDeployAsserts} from "../../src/ZipcodeDeployAsserts.sol";
import {ZipcodeOracleRegistry} from "../../src/ZipcodeOracleRegistry.sol";
import {ZipcodeController} from "../../src/ZipcodeController.sol";
import {LienTokenFactory} from "../../src/LienTokenFactory.sol";
import {SzipFarmUtilityLpOracle} from "../../src/supply/SzipFarmUtilityLpOracle.sol";

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

/// @notice A minimal 18-dp ERC20 stand-in for the ICHI LP share. The LP oracle ctor strict-reads `lpToken.decimals()`
///         (SUPPLY-ADV-13) and rejects anything but 18, so the key must be a live 18-dp contract, not a `makeAddr` EOA.
contract MockLp18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Thin external wrapper so `vm.expectRevert` can target the `internal` combined-fleet library call (an
///         internal library fn cannot be `vm.expectRevert`-pranked directly).
contract GateHarness {
    function gate(address[] calldata receivers, address registry) external view {
        ZipcodeDeployAsserts.requireIdentityWired(receivers, registry);
    }
}

/// @title ZipcodeDeployIdentityGate test (CTR-16 — the S11 seal-before-identity pre-gate, author+name posture, §9/§13)
/// @notice Proves `ZipcodeDeployAsserts.requireIdentityWired` against the REAL keepsake contracts
///         (`ZipcodeOracleRegistry` WOOF-02 + `ZipcodeController` WOOF-05), in three classes:
///         NEGATIVE (gate reverts when a receiver is unwired or the registry is unseeded), POSITIVE (gate passes →
///         renounce → frozen), and NEGATIVE-CONTROL (the dormant-identity vuln the gate prevents). CTR-16: the gate
///         now asserts EACH receiver's author + workflowName individually (the shared `workflowId` pin is dropped),
///         so a missing name on any one fails closed. No fork: the registry ctor only reads `quote.decimals()`
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
    string internal constant NAME_CONTROLLER = "zip-controller";
    string internal constant NAME_REVALUATION = "zip-revaluation";

    function setUp() public {
        harness = new GateHarness();

        usdc = new MockUSDC();
        lienFactory = new LienTokenFactory();

        // The test is the deployer/owner of both receivers, so it can set identity / setController / renounce.
        registry = new ZipcodeOracleRegistry(FORWARDER, address(usdc), VALIDITY);
        controller = new ZipcodeController(
            FORWARDER, VENUE_STUB, address(lienFactory), address(registry), EREBOR
        );

        assertEq(controller.owner(), address(this), "test owns controller");
        assertEq(registry.owner(), address(this), "test owns registry");
    }

    /// @dev The full sealed fleet for the combined gate (controller + registry, both `ReceiverTemplate`s). The
    ///      registry is asserted as a receiver AND separately for its set-once `controller()` seed.
    function _receivers() internal view returns (address[] memory r) {
        r = new address[](2);
        r[0] = address(controller);
        r[1] = address(registry);
    }

    /// @dev Seal one receiver with author + workflowName (the CTR-16 posture the deploy's `_sealIdentity` applies).
    function _seal(address receiver, string memory name) internal {
        ReceiverTemplate(receiver).setExpectedAuthor(WORKFLOW_OWNER);
        ReceiverTemplate(receiver).setExpectedWorkflowName(name);
    }

    // ============================================================
    // NEGATIVE — the tested gate
    // ============================================================

    /// @dev F-3 case: a receiver's identity unset (author+name both zero) while the registry is seeded. The gate
    ///      BLOCKS on the FIRST unwired receiver (the controller).
    function test_Negative_ReceiverUnsealed_GateReverts() public {
        // registry sealed + seeded...
        _seal(address(registry), NAME_REVALUATION);
        registry.setController(address(controller));
        // ...but the controller identity is NEVER set.
        assertEq(controller.getExpectedAuthor(), address(0), "controller author unset");
        assertEq(controller.getExpectedWorkflowName(), bytes10(0), "controller name unset");

        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector, address(controller))
        );
        harness.gate(_receivers(), address(registry));
    }

    /// @dev Author set but workflowName unset still fails closed (the name is load-bearing under the per-daemon
    ///      separation model — author alone cannot separate co-tenant daemons sharing the deploy wallet).
    function test_Negative_NameUnset_GateReverts() public {
        _seal(address(registry), NAME_REVALUATION);
        registry.setController(address(controller));
        controller.setExpectedAuthor(WORKFLOW_OWNER); // author only — NO name
        assertTrue(controller.getExpectedAuthor() != address(0), "author set");
        assertEq(controller.getExpectedWorkflowName(), bytes10(0), "name still unset");

        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector, address(controller))
        );
        harness.gate(_receivers(), address(registry));
    }

    /// @dev F7 case: every receiver sealed but `registry.setController` SKIPPED (`controller() == 0`).
    function test_Negative_RegistryControllerUnset_GateReverts() public {
        _seal(address(controller), NAME_CONTROLLER);
        _seal(address(registry), NAME_REVALUATION);
        assertEq(registry.controller(), address(0), "registry unseeded");

        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeDeployAsserts.RegistryControllerUnset.selector, address(registry))
        );
        harness.gate(_receivers(), address(registry));
    }

    /// @dev Defense-in-depth: an EMPTY fleet fails closed. The per-receiver loop would otherwise pass vacuously
    ///      (zero iterations), leaving only the registry leg — so a seeded registry + empty array would bless a
    ///      fleet the gate never actually checked. The gate refuses an empty `receivers` rather than trust the
    ///      caller to populate it. (Unreachable from the real call site, which sizes the array to the live fleet.)
    function test_Negative_EmptyReceivers_GateReverts() public {
        // Registry fully seeded, so the ONLY thing standing between an empty fleet and a pass is the new guard.
        _seal(address(registry), NAME_REVALUATION);
        registry.setController(address(controller));

        address[] memory empty = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeDeployAsserts.EmptyReceiverSet.selector));
        harness.gate(empty, address(registry));
    }

    // ============================================================
    // POSITIVE — gate passes → renounce → frozen (audit S11 post-state)
    // ============================================================

    function test_Positive_GatePasses_ThenRenounce_ThenFrozen() public {
        // Seal both receivers (author + per-receiver name) and seed the registry controller.
        _seal(address(controller), NAME_CONTROLLER);
        _seal(address(registry), NAME_REVALUATION);
        registry.setController(address(controller));

        // The gate passes (no revert) when every receiver is sealed AND the registry is seeded.
        harness.gate(_receivers(), address(registry));

        // S11: renounce succeeds.
        controller.renounceOwnership();
        assertEq(controller.owner(), address(0), "controller owner renounced");

        // Post-renounce every inherited owner-gated setter reverts OwnableUnauthorizedAccount.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        controller.setForwarderAddress(makeAddr("anything"));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        controller.setExpectedAuthor(makeAddr("anything"));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        controller.setExpectedWorkflowName("anything");

        // The registry's set-once is frozen too.
        registry.renounceOwnership();
        assertEq(registry.owner(), address(0), "registry owner renounced");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setController(makeAddr("anything"));
    }
}

/// @notice Thin external wrapper so `vm.expectRevert` can target the `internal` single-receiver library call.
contract LpGateHarness {
    function gate(address receiver) external view {
        ZipcodeDeployAsserts.requireReceiverIdentityWired(receiver);
    }
}

/// @title CTR-16 — per-receiver author+name seal + the K5 privilege-separation proof
/// @notice Proves the CTR-16 posture against the REAL `SzipFarmUtilityLpOracle` (a `ReceiverTemplate`), in four
///         classes:
///           1. IDENTITY SEALED — after the seal, `getExpectedAuthor()`/`getExpectedWorkflowName()` are non-zero.
///           2. BEHAVIORAL fail-closed — an unsealed lpOracle ACCEPTS a wrong-identity LP_MARK push (the dormant
///              vuln); a sealed one REJECTS a mismatched workflowName `InvalidWorkflowName`.
///           3. PRE-GATE bites — `requireReceiverIdentityWired` reverts when author OR name is unset, passes sealed.
///           4. K5 PRIVILEGE SEPARATION — two receivers, SAME author, DIFFERENT names: a report bearing daemon-A's
///              name is ACCEPTED by the receiver sealed to daemon-A and REJECTED (`InvalidWorkflowName`) by the
///              receiver sealed to daemon-B. This is the whole point of per-receiver names (a shared author cannot
///              separate the separate daemons).
///         No fork: the oracle ctor reads `quote.decimals()` (6-dp `MockUSDC`) and strict-reads `lpToken.decimals()`
///         (18-dp `MockLp18`, SUPPLY-ADV-13) before storing `lpToken`.
contract CTR16ReceiverIdentityTest is Test {
    LpGateHarness internal harness;
    MockUSDC internal usdc;
    SzipFarmUtilityLpOracle internal lpOracle;

    address internal FORWARDER = makeAddr("forwarder");
    address internal LP_TOKEN = address(new MockLp18()); // live 18-dp key — the oracle ctor strict-reads its decimals
    address internal WORKFLOW_OWNER = makeAddr("workflowOwner");

    uint256 internal constant VALIDITY = 365 days;
    uint8 internal constant LP_MARK = 7;
    string internal constant NAME_A = "zip-sharefeeds-a";
    string internal constant NAME_B = "zip-sharefeeds-b";

    function setUp() public {
        harness = new LpGateHarness();
        usdc = new MockUSDC();
        // The test is the deployer/owner ⇒ it can seal identity (mirrors the deploy's team broadcaster pre-transfer).
        lpOracle = new SzipFarmUtilityLpOracle(FORWARDER, address(usdc), VALIDITY, LP_TOKEN);
        assertEq(lpOracle.owner(), address(this), "test owns lpOracle");
    }

    /// @dev Replicates the deploy's `_sealIdentity(receiver, name)`: set author + workflowName.
    function _seal(SzipFarmUtilityLpOracle o, string memory name) internal {
        o.setExpectedAuthor(WORKFLOW_OWNER);
        o.setExpectedWorkflowName(name);
    }

    /// @dev `abi.encodePacked(workflowId, workflowName, workflowOwner)` — the Forwarder metadata layout
    ///      `ReceiverTemplate._decodeMetadata` reads at fixed offsets 32/64/74. `workflowId` is left zero (the pin
    ///      is dropped; `onReport` skips a zero expected id).
    function _metadata(bytes10 name, address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(0), name, owner);
    }

    /// @dev A well-formed `LP_MARK` report envelope (`abi.encode(uint8 reportType, abi.encode(mark, ts))`).
    function _lpMarkReport(uint256 mark, uint32 ts) internal pure returns (bytes memory) {
        return abi.encode(uint8(LP_MARK), abi.encode(mark, ts));
    }

    // ============================================================
    // 1. IDENTITY SEALED — the seal sets a non-zero author + name
    // ============================================================
    function test_IdentitySealed_AfterSeal() public {
        assertEq(lpOracle.getExpectedAuthor(), address(0), "pre-seal: author dormant");
        assertEq(lpOracle.getExpectedWorkflowName(), bytes10(0), "pre-seal: name dormant");
        _seal(lpOracle, NAME_A);
        assertEq(lpOracle.getExpectedAuthor(), WORKFLOW_OWNER, "author sealed");
        assertTrue(lpOracle.getExpectedWorkflowName() != bytes10(0), "name sealed");
    }

    // ============================================================
    // 2. BEHAVIORAL — dormant accepts wrong identity; sealed rejects a mismatched name
    // ============================================================

    /// @dev The vuln (dormant): NO identity ⇒ a wrong-identity LP_MARK from the (shared) Forwarder is ACCEPTED and
    ///      writes the cache. Any co-tenant workflow clearing the Forwarder can push the LP mark.
    function test_Behavioral_DormantAcceptsWrongIdentity() public {
        assertEq(lpOracle.getExpectedAuthor(), address(0), "identity dormant");

        vm.warp(VALIDITY + 100); // so a `ts` in range is non-zero and <= now
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        lpOracle.onReport(_metadata(bytes10("whatever"), makeAddr("strangerDaemon")), _lpMarkReport(15e6, ts));

        (uint208 price, uint48 cachedTs) = lpOracle.cache();
        assertEq(price, 15e6, "wrong-identity mark was accepted (the dormant vuln)");
        assertEq(cachedTs, ts, "cache timestamp written by an unauthorized workflow");
    }

    /// @dev The fix: once sealed, a report whose author matches but whose workflowName does NOT reverts
    ///      `InvalidWorkflowName` BEFORE dispatch.
    function test_Behavioral_SealedRejectsWrongName() public {
        _seal(lpOracle, NAME_A);
        bytes10 sealedName = lpOracle.getExpectedWorkflowName();
        bytes10 wrongName = bytes10(keccak256("some-other-daemon")); // != sealedName

        vm.warp(VALIDITY + 100);
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowName.selector, wrongName, sealedName)
        );
        lpOracle.onReport(_metadata(wrongName, WORKFLOW_OWNER), _lpMarkReport(15e6, ts));

        (, uint48 cachedTs) = lpOracle.cache();
        assertEq(cachedTs, 0, "no mark written - the mismatched-name push was rejected");
    }

    /// @dev The authorized workflow (matching author AND name) still pushes through the sealed gate.
    function test_Behavioral_SealedAcceptsCorrectIdentity() public {
        _seal(lpOracle, NAME_A);
        bytes10 sealedName = lpOracle.getExpectedWorkflowName();

        vm.warp(VALIDITY + 100);
        uint32 ts = uint32(block.timestamp);
        vm.prank(FORWARDER);
        lpOracle.onReport(_metadata(sealedName, WORKFLOW_OWNER), _lpMarkReport(15e6, ts));

        (uint208 price, uint48 cachedTs) = lpOracle.cache();
        assertEq(price, 15e6, "authorized mark accepted");
        assertEq(cachedTs, ts, "authorized push wrote the cache");
    }

    // ============================================================
    // 3. PRE-GATE — requireReceiverIdentityWired reverts unset (author OR name), passes sealed
    // ============================================================
    function test_PreGate_RevertsWhenAuthorUnset() public {
        // name set, author unset (the WorkflowNameRequiresAuthorValidation hazard the gate forecloses).
        lpOracle.setExpectedWorkflowName(NAME_A);
        assertEq(lpOracle.getExpectedAuthor(), address(0), "author unset");
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector, address(lpOracle))
        );
        harness.gate(address(lpOracle));
    }

    function test_PreGate_RevertsWhenNameUnset() public {
        lpOracle.setExpectedAuthor(WORKFLOW_OWNER); // author only
        assertEq(lpOracle.getExpectedWorkflowName(), bytes10(0), "name unset");
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector, address(lpOracle))
        );
        harness.gate(address(lpOracle));
    }

    function test_PreGate_PassesWhenSealed() public {
        _seal(lpOracle, NAME_A);
        harness.gate(address(lpOracle)); // no revert
    }

    // ============================================================
    // 4. K5 — PRIVILEGE SEPARATION (the load-bearing proof): same author, different names
    // ============================================================

    /// @dev Two receivers sealed to the SAME author but DIFFERENT names (daemon-A vs daemon-B). A report bearing
    ///      daemon-A's name is ACCEPTED by receiver-A (writes its cache) and REJECTED by receiver-B
    ///      (`InvalidWorkflowName`). The author is identical in both — only the per-receiver NAME separates them,
    ///      which is exactly what CTR-16 buys (a shared deploy wallet ⇒ shared author ⇒ author cannot separate).
    function test_K5_PrivilegeSeparation_NameSeparatesSameAuthorDaemons() public {
        SzipFarmUtilityLpOracle oracleA = lpOracle; // sealed to daemon-A below
        SzipFarmUtilityLpOracle oracleB =
            new SzipFarmUtilityLpOracle(FORWARDER, address(usdc), VALIDITY, LP_TOKEN);

        _seal(oracleA, NAME_A);
        _seal(oracleB, NAME_B);

        // identical author, distinct on-chain names.
        assertEq(oracleA.getExpectedAuthor(), oracleB.getExpectedAuthor(), "same author (shared deploy wallet)");
        bytes10 nameA = oracleA.getExpectedWorkflowName();
        bytes10 nameB = oracleB.getExpectedWorkflowName();
        assertTrue(nameA != nameB, "distinct per-receiver names");

        vm.warp(VALIDITY + 100);
        uint32 ts = uint32(block.timestamp);
        bytes memory metaA = _metadata(nameA, WORKFLOW_OWNER); // a report from daemon-A

        // (a) ACCEPTED by the receiver sealed to daemon-A.
        vm.prank(FORWARDER);
        oracleA.onReport(metaA, _lpMarkReport(15e6, ts));
        (uint208 priceA, uint48 tsA) = oracleA.cache();
        assertEq(priceA, 15e6, "daemon-A's report accepted by receiver-A");
        assertEq(tsA, ts, "receiver-A cache written");

        // (b) REJECTED by the receiver sealed to daemon-B — same author, wrong name.
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowName.selector, nameA, nameB));
        oracleB.onReport(metaA, _lpMarkReport(15e6, ts));
        (, uint48 tsB) = oracleB.cache();
        assertEq(tsB, 0, "receiver-B rejected daemon-A's report (no cache write)");
    }
}
