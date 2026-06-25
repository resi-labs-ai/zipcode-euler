// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DefaultCoordinator} from "../../src/loss/DefaultCoordinator.sol";
import {LienXAlphaEscrow} from "../../src/loss/LienXAlphaEscrow.sol";
import {SzipNavOracle} from "../../src/supply/SzipNavOracle.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// =========================================================================================== mocks
/// @dev Minimal configurable-decimals ERC20 (xALPHA stand-in). No fee-on-transfer, non-rebasing. Mirrors
///      `LienXAlphaEscrow.t.sol`'s MockERC20 — ctor `(uint8 d)`, open `mint`.
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amt) public {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Ungated NAV-oracle stand-in for the UNIT suite: `writeProvision` is open + `provision()` is public, so the
///      unit tests can both let the coordinator write and read the value back. The coordinator's `ISzipNavOracle`
///      interface has only `writeProvision`; assertions read `oracle.provision()` off this concrete type. Mirrors
///      `SzipNavOracle.ProvisionWritten` so `expectEmit` can target it.
contract MockNavOracle {
    uint256 public provision;

    event ProvisionWritten(uint256 provision);

    function writeProvision(uint256 p) external {
        provision = p;
        emit ProvisionWritten(p);
    }
}

// =========================================================================================== unit base harness
abstract contract CoordBase is Test {
    MockERC20 internal xalpha; // 18-dp
    MockNavOracle internal oracle;
    DefaultCoordinator internal coordinator;
    LienXAlphaEscrow internal escrow;

    address internal forwarder = makeAddr("forwarder");
    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSidecar = makeAddr("juniorTrancheSidecar");
    address internal originator = makeAddr("originator");
    address internal originator2 = makeAddr("originator2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant FLOOR = 0.8e18; // 80% floor => provision = atRisk * 20%

    bytes32 internal constant LIEN_A = bytes32(uint256(0xA));
    bytes32 internal constant LIEN_B = bytes32(uint256(0xB));

    function _deploy(uint256 floor) internal {
        xalpha = new MockERC20(18);
        oracle = new MockNavOracle();
        coordinator = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), floor);
        // escrow's coordinator = the coordinator (circular break: coordinator deployed first with escrow unset)
        escrow = new LienXAlphaEscrow(address(xalpha), address(coordinator), adminSafe, juniorTrancheSidecar);
        coordinator.setEscrow(address(escrow));
    }

    function _baseSetUp() internal {
        _deploy(FLOOR);
    }

    /// @dev Fund the coordinator just-in-time with `amt` xALPHA (the item-10 funding discipline).
    function _fund(uint256 amt) internal {
        xalpha.mint(address(coordinator), amt);
    }

    // ---- report builders ----
    function _report(uint8 action, bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(uint8(8), abi.encode(action, data));
    }

    function _drive(bytes memory report) internal {
        vm.prank(forwarder);
        coordinator.onReport("", report);
    }

    function _lock(bytes32 lienId, address orig, uint256 amount) internal {
        _drive(_report(0, abi.encode(lienId, orig, amount)));
    }

    function _releaseReport(bytes32 lienId) internal {
        _drive(_report(1, abi.encode(lienId)));
    }

    function _defaultReport(bytes32 lienId, uint256 atRisk) internal {
        _drive(_report(2, abi.encode(lienId, atRisk)));
    }

    function _recoveryReport(bytes32 lienId, uint256 proceeds) internal {
        _drive(_report(3, abi.encode(lienId, proceeds)));
    }

    function _resolveReport(bytes32 lienId, uint256 capitalSlash) internal {
        _drive(_report(4, abi.encode(lienId, capitalSlash)));
    }

    function _writeOffReport(bytes32 lienId, uint256 capitalSlash) internal {
        _drive(_report(5, abi.encode(lienId, capitalSlash)));
    }

    function _status(bytes32 lienId) internal view returns (DefaultCoordinator.LienStatus s) {
        (s,) = coordinator.lienLoss(lienId);
    }

    function _provision(bytes32 lienId) internal view returns (uint256 p) {
        (, p) = coordinator.lienLoss(lienId);
    }
}

// =========================================================================================== unit suite
contract DefaultCoordinatorTest is CoordBase {
    // event mirrors
    event EscrowSet(address indexed escrow);
    event RecoveryFloorSet(uint256 oldFloor, uint256 newFloor);
    event BondLocked(bytes32 indexed lienId, address indexed originator, uint256 amount);
    event BondReleased(bytes32 indexed lienId);
    event Defaulted(bytes32 indexed lienId, uint256 atRisk, uint256 provision);
    event Recovered(bytes32 indexed lienId, uint256 recoveryProceeds, uint256 remainingProvision);
    event Resolved(bytes32 indexed lienId, uint256 capitalSlashAmount);
    event WrittenOff(bytes32 indexed lienId, uint256 capitalSlashAmount);
    event ProvisionWritten(uint256 provision);
    event Locked(bytes32 indexed lienId, address indexed originator, uint256 amount);
    event SlashedToCohort(bytes32 indexed lienId, uint256 amount);

    function setUp() public {
        _baseSetUp();
    }

    // ---------------------------------------------------------------- ctor
    function test_ctor_stores_immutables() public view {
        assertEq(address(coordinator.navOracle()), address(oracle));
        assertEq(address(coordinator.xAlpha()), address(xalpha));
        assertEq(coordinator.recoveryFloor(), FLOOR);
        assertEq(coordinator.getForwarderAddress(), forwarder);
        assertEq(uint256(coordinator.REPORT_TYPE()), 8);
    }

    function test_ctor_zero_navOracle_reverts() public {
        vm.expectRevert(DefaultCoordinator.ZeroAddress.selector);
        new DefaultCoordinator(forwarder, address(0), address(xalpha), FLOOR);
    }

    function test_ctor_zero_xAlpha_reverts() public {
        vm.expectRevert(DefaultCoordinator.ZeroAddress.selector);
        new DefaultCoordinator(forwarder, address(oracle), address(0), FLOOR);
    }

    function test_ctor_recoveryFloor_eq_1e18_reverts() public {
        vm.expectRevert(DefaultCoordinator.InvalidRecoveryFloor.selector);
        new DefaultCoordinator(forwarder, address(oracle), address(xalpha), 1e18);
    }

    function test_ctor_recoveryFloor_above_1e18_reverts() public {
        vm.expectRevert(DefaultCoordinator.InvalidRecoveryFloor.selector);
        new DefaultCoordinator(forwarder, address(oracle), address(xalpha), 2e18);
    }

    function test_ctor_zero_forwarder_reverts_base() public {
        vm.expectRevert(ReceiverTemplate.InvalidForwarderAddress.selector);
        new DefaultCoordinator(address(0), address(oracle), address(xalpha), FLOOR);
    }

    function test_ctor_accepts_floor_zero_and_max() public {
        DefaultCoordinator c0 = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), 0);
        assertEq(c0.recoveryFloor(), 0);
        DefaultCoordinator cMax = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), 1e18 - 1);
        assertEq(cMax.recoveryFloor(), 1e18 - 1);
    }

    // ---------------------------------------------------------------- setEscrow
    function test_setEscrow_emits_and_grants_no_standing_allowance() public {
        // fresh coordinator (un-wired) to assert the EscrowSet emit + that NO standing allowance is granted
        // (_lock approves the exact bond amount JIT; setEscrow itself leaves allowance at 0).
        DefaultCoordinator c = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        LienXAlphaEscrow e = new LienXAlphaEscrow(address(xalpha), address(c), adminSafe, juniorTrancheSidecar);
        vm.expectEmit(true, true, true, true, address(c));
        emit EscrowSet(address(e));
        c.setEscrow(address(e));
        assertEq(address(c.escrow()), address(e));
        assertEq(xalpha.allowance(address(c), address(e)), 0, "no standing allowance to escrow");
    }

    function test_setEscrow_repoint_works_no_standing_allowance() public {
        // build phase (§17): setEscrow re-points (no set-once lock), and grants NO standing allowance to the new
        // escrow — so a re-pointed escrow has nothing to drain.
        LienXAlphaEscrow e2 = new LienXAlphaEscrow(address(xalpha), address(coordinator), adminSafe, juniorTrancheSidecar);
        coordinator.setEscrow(address(e2));
        assertEq(address(coordinator.escrow()), address(e2));
        assertEq(xalpha.allowance(address(coordinator), address(e2)), 0, "no standing allowance on re-point");
    }

    function test_lock_jit_allowance_leaves_no_standing_allowance() public {
        // regression: a lock succeeds via the exact-amount JIT approval, and leaves zero standing
        // allowance both before and after — there is no MAX allowance for a re-pointed escrow to exploit.
        uint256 amt = 100e18;
        _fund(amt);
        assertEq(xalpha.allowance(address(coordinator), address(escrow)), 0, "zero allowance before lock");
        _lock(LIEN_A, originator, amt);
        assertEq(_status(LIEN_A) == DefaultCoordinator.LienStatus.Bonded, true, "bond landed");
        assertEq(escrow.bondAmount(LIEN_A), amt, "escrow holds the bond");
        assertEq(xalpha.allowance(address(coordinator), address(escrow)), 0, "zero standing allowance after lock");
    }

    function test_setNavOracle_repoint_and_onlyOwner() public {
        MockNavOracle o2 = new MockNavOracle();
        coordinator.setNavOracle(address(o2));
        assertEq(address(coordinator.navOracle()), address(o2));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        coordinator.setNavOracle(address(o2));
        vm.expectRevert(DefaultCoordinator.ZeroAddress.selector);
        coordinator.setNavOracle(address(0));
    }

    function test_setXAlpha_repoint_no_standing_allowance() public {
        MockERC20 x2 = new MockERC20(18);
        coordinator.setXAlpha(address(x2));
        assertEq(address(coordinator.xAlpha()), address(x2));
        // no standing re-approval of the new token: _lock grants the exact amount JIT instead.
        assertEq(x2.allowance(address(coordinator), address(escrow)), 0, "no standing allowance after token re-point");
    }

    function test_setEscrow_zero_reverts() public {
        DefaultCoordinator c = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        vm.expectRevert(DefaultCoordinator.ZeroAddress.selector);
        c.setEscrow(address(0));
    }

    function test_setEscrow_nonOwner_reverts() public {
        DefaultCoordinator c = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        LienXAlphaEscrow e = new LienXAlphaEscrow(address(xalpha), address(c), adminSafe, juniorTrancheSidecar);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        c.setEscrow(address(e));
    }

    function test_setEscrow_repoint_by_timelock() public {
        // build phase (§17): the Timelock admin can re-point the escrow (no set-once lock)
        address timelock = makeAddr("timelock");
        DefaultCoordinator c = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        LienXAlphaEscrow e = new LienXAlphaEscrow(address(xalpha), address(c), adminSafe, juniorTrancheSidecar);
        c.setEscrow(address(e));
        c.transferOwnership(timelock);
        LienXAlphaEscrow e2 = new LienXAlphaEscrow(address(xalpha), address(c), adminSafe, juniorTrancheSidecar);
        vm.prank(timelock);
        c.setEscrow(address(e2));
        assertEq(address(c.escrow()), address(e2));
    }

    // ---------------------------------------------------------------- setRecoveryFloor (governed by the Timelock)
    function test_setRecoveryFloor_updates_and_emits() public {
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit RecoveryFloorSet(FLOOR, 0.5e18);
        coordinator.setRecoveryFloor(0.5e18);
        assertEq(coordinator.recoveryFloor(), 0.5e18);
    }

    function test_setRecoveryFloor_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        coordinator.setRecoveryFloor(0.5e18);
    }

    function test_setRecoveryFloor_eq_1e18_reverts() public {
        vm.expectRevert(DefaultCoordinator.InvalidRecoveryFloor.selector);
        coordinator.setRecoveryFloor(1e18);
    }

    function test_setRecoveryFloor_by_timelock_after_transfer() public {
        address timelock = makeAddr("timelock");
        coordinator.transferOwnership(timelock);
        vm.prank(timelock);
        coordinator.setRecoveryFloor(0.3e18);
        assertEq(coordinator.recoveryFloor(), 0.3e18);
    }

    function test_setRecoveryFloor_applies_to_next_default_only() public {
        // recognize a default at FLOOR=0.8 => provision = atRisk*20% = 20e18
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 100e18);
        assertEq(_provision(LIEN_A), 20e18);
        // lower the floor; the existing provision is NOT retroactively re-marked
        coordinator.setRecoveryFloor(0.5e18);
        assertEq(_provision(LIEN_A), 20e18, "existing provision unchanged");
        assertEq(coordinator.totalProvision(), 20e18);
        // a NEW default uses the updated floor => provision = atRisk*50% = 50e18
        _fund(100e18);
        _lock(LIEN_B, originator2, 100e18);
        _defaultReport(LIEN_B, 100e18);
        assertEq(_provision(LIEN_B), 50e18, "new default uses the updated floor");
    }

    // ---------------------------------------------------------------- onReport authority
    function test_onReport_nonForwarder_reverts() public {
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 1e18));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, stranger, forwarder));
        coordinator.onReport("", report);
    }

    function test_onReport_workflowId_mismatch_reverts() public {
        bytes32 WID = keccak256("workflow");
        coordinator.setExpectedWorkflowId(WID);
        bytes memory meta = abi.encodePacked(keccak256("wrong"), bytes10(0), address(0));
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 1e18));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, keccak256("wrong"), WID));
        coordinator.onReport(meta, report);
    }

    function test_onReport_emptyMeta_passes_when_identity_unset() public {
        // identity unset => empty metadata is fine; a happy LOCK goes through
        _fund(10e18);
        _lock(LIEN_A, originator, 10e18);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Bonded));
    }

    function test_onReport_workflowId_match_passes() public {
        bytes32 WID = keccak256("workflow");
        coordinator.setExpectedWorkflowId(WID);
        bytes memory goodMeta = abi.encodePacked(WID, bytes10(0), address(0));
        _fund(10e18);
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 10e18));
        vm.prank(forwarder);
        coordinator.onReport(goodMeta, report);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Bonded));
    }

    // ---------------------------------------------------------------- dispatch negatives
    function test_dispatch_wrongReportType_reverts() public {
        bytes memory report = abi.encode(uint8(7), abi.encode(uint8(0), abi.encode(LIEN_A, originator, 1e18)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(DefaultCoordinator.InvalidReportType.selector, uint8(7)));
        coordinator.onReport("", report);
    }

    function test_dispatch_invalidAction_reverts() public {
        bytes memory report = _report(6, abi.encode(LIEN_A));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(DefaultCoordinator.InvalidAction.selector, uint8(6)));
        coordinator.onReport("", report);
    }

    // ---------------------------------------------------------------- LOCK
    function test_lock_happy_drives_escrow_and_emits() public {
        uint256 amt = 100e18;
        _fund(amt);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Locked(LIEN_A, originator, amt);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit BondLocked(LIEN_A, originator, amt);
        _lock(LIEN_A, originator, amt);

        assertEq(xalpha.balanceOf(address(escrow)), amt, "escrow +amount");
        assertEq(xalpha.balanceOf(address(coordinator)), 0, "coordinator -amount");
        assertEq(escrow.bondAmount(LIEN_A), amt);
        assertEq(escrow.bondOriginator(LIEN_A), originator);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Bonded));
    }

    function test_lock_reLock_bonded_reverts_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _fund(50e18);
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 50e18));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_lock_on_defaulted_reverts_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 10e18);
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 50e18));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_lock_unfunded_rolls_back_no_orphan_then_funded_succeeds() public {
        // coordinator un-funded => escrow pull reverts => whole report reverts, no orphan
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 100e18));
        vm.prank(forwarder);
        vm.expectRevert(); // SafeERC20 balance underflow in the pull
        coordinator.onReport("", report);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.None), "no orphan status");
        assertEq(escrow.bondAmount(LIEN_A), 0, "no orphan bond");

        // a subsequent funded LOCK of the same lien succeeds (no sticky orphan)
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Bonded));
        assertEq(escrow.bondAmount(LIEN_A), 100e18);
    }

    // ---------------------------------------------------------------- RELEASE
    function test_release_happy_returns_full_and_emits() public {
        uint256 amt = 100e18;
        _fund(amt);
        _lock(LIEN_A, originator, amt);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit BondReleased(LIEN_A);
        _releaseReport(LIEN_A);

        assertEq(xalpha.balanceOf(originator), amt, "full bond to originator");
        assertEq(escrow.bondAmount(LIEN_A), 0);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.None));
        assertEq(coordinator.totalProvision(), 0);
    }

    function test_release_neverBonded_reverts_badStatus() public {
        bytes memory report = _report(1, abi.encode(LIEN_A));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_release_defaulted_reverts_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 10e18);
        bytes memory report = _report(1, abi.encode(LIEN_A));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    // ---------------------------------------------------------------- DEFAULT (the bound)
    function test_default_happy_bound_and_coemit() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);

        uint256 atRisk = 1000e18;
        uint256 expectedP = atRisk * (1e18 - FLOOR) / 1e18; // 200e18

        vm.expectEmit(true, true, true, true, address(oracle));
        emit ProvisionWritten(expectedP);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit Defaulted(LIEN_A, atRisk, expectedP);
        _defaultReport(LIEN_A, atRisk);

        assertEq(_provision(LIEN_A), expectedP);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Defaulted));
        assertEq(coordinator.totalProvision(), expectedP);
        assertEq(oracle.provision(), expectedP);
    }

    function test_default_highFloor_boundary() public {
        _deploy(0.9e18); // re-deploy with 90% floor
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        uint256 atRisk = 1000e18;
        _defaultReport(LIEN_A, atRisk);
        assertEq(_provision(LIEN_A), atRisk / 10, "provision == atRisk/10");
        assertEq(oracle.provision(), atRisk / 10);
    }

    function test_default_floorZero_full_atRisk() public {
        _deploy(0);
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        uint256 atRisk = 1000e18;
        _defaultReport(LIEN_A, atRisk);
        assertEq(_provision(LIEN_A), atRisk, "floor 0 => provision == atRisk");
    }

    function test_default_truncation_pin() public {
        _deploy(0.5e18); // 50%
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 3); // 3 * 0.5e18 / 1e18 = 1.5 -> truncates DOWN to 1
        assertEq(_provision(LIEN_A), 1, "rounds DOWN (under-provision)");
        assertEq(oracle.provision(), 1);
    }

    function test_default_zeroResult_does_not_revert() public {
        _deploy(1e18 - 1); // floor = 1e18 - 1
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1e17); // 1e17 * 1 / 1e18 = 0
        assertEq(_provision(LIEN_A), 0, "zero-result provision");
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Defaulted), "status still Defaulted");
        assertEq(coordinator.totalProvision(), 0);
        assertEq(oracle.provision(), 0);
    }

    function test_default_nonBonded_reverts_badStatus() public {
        bytes memory report = _report(2, abi.encode(LIEN_A, uint256(10e18)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_default_twice_reverts_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 10e18);
        bytes memory report = _report(2, abi.encode(LIEN_A, uint256(10e18)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector); // replay -> BadStatus (status guard is the defense)
        coordinator.onReport("", report);
    }

    function test_default_zeroAtRisk_reverts() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        bytes memory report = _report(2, abi.encode(LIEN_A, uint256(0)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.ZeroAtRisk.selector);
        coordinator.onReport("", report);
    }

    // ---------------------------------------------------------------- RECOVERY (up by realized receipts)
    function test_recovery_partial_heal_status_stays() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18
        uint256 p0 = _provision(LIEN_A);

        uint256 proceeds = 50e18;
        vm.expectEmit(true, true, true, true, address(oracle));
        emit ProvisionWritten(p0 - proceeds);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit Recovered(LIEN_A, proceeds, p0 - proceeds);
        _recoveryReport(LIEN_A, proceeds);

        assertEq(_provision(LIEN_A), p0 - proceeds);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Defaulted), "status stays Defaulted");
        assertEq(coordinator.totalProvision(), p0 - proceeds);
        assertEq(oracle.provision(), p0 - proceeds);
    }

    function test_recovery_exact_to_zero() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18
        uint256 p0 = _provision(LIEN_A);
        _recoveryReport(LIEN_A, p0); // proceeds == provision
        assertEq(_provision(LIEN_A), 0);
        assertEq(coordinator.totalProvision(), 0);
        assertEq(oracle.provision(), 0);
    }

    function test_recovery_overshoot_floors_at_zero() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18
        _recoveryReport(LIEN_A, 1_000_000e18); // proceeds >> provision
        assertEq(_provision(LIEN_A), 0, "floors at 0, never negative");
        assertEq(coordinator.totalProvision(), 0);
        assertEq(oracle.provision(), 0);
    }

    function test_recovery_second_on_zero_is_noop_still_emits() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18);
        uint256 p0 = _provision(LIEN_A);
        _recoveryReport(LIEN_A, p0); // to zero
        // second recovery on a 0 provision: no underflow, still emits, still 0
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit Recovered(LIEN_A, 5e18, 0);
        _recoveryReport(LIEN_A, 5e18);
        assertEq(_provision(LIEN_A), 0);
        assertEq(coordinator.totalProvision(), 0);
    }

    function test_recovery_multiple_accumulate_down() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18
        _recoveryReport(LIEN_A, 50e18);
        _recoveryReport(LIEN_A, 50e18);
        _recoveryReport(LIEN_A, 50e18);
        assertEq(_provision(LIEN_A), 50e18);
        _recoveryReport(LIEN_A, 50e18);
        assertEq(_provision(LIEN_A), 0);
        assertEq(coordinator.totalProvision(), 0);
    }

    function test_recovery_nonDefaulted_reverts_badStatus() public {
        bytes memory report = _report(3, abi.encode(LIEN_A, uint256(1e18)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    // ---------------------------------------------------------------- RESOLVE (heal + ordered slash)
    function test_resolve_partial_heals_and_routes() public {
        uint256 B = 100e18;
        uint256 part = 70e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18

        vm.expectEmit(true, true, true, true, address(oracle));
        emit ProvisionWritten(0);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit SlashedToCohort(LIEN_A, B - part);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit Resolved(LIEN_A, part);
        _resolveReport(LIEN_A, part);

        assertEq(_provision(LIEN_A), 0);
        assertEq(coordinator.totalProvision(), 0);
        assertEq(oracle.provision(), 0);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Resolved));
        assertEq(xalpha.balanceOf(adminSafe), part, "part to adminSafe");
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), B - part, "remainder to juniorTrancheSidecar");
        assertEq(xalpha.balanceOf(address(escrow)), 0, "escrow net 0");
    }

    function test_resolve_purePremium_whole_to_cohort() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        _resolveReport(LIEN_A, 0); // pure premium

        assertEq(xalpha.balanceOf(adminSafe), 0);
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), B, "whole bond to juniorTrancheSidecar");
        assertEq(escrow.bondAmount(LIEN_A), 0);
    }

    function test_resolve_fullBondCapital_skips_cohort() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        _resolveReport(LIEN_A, B); // full-bond capital slash -> bond 0 -> cohort skipped (no NoBond revert)

        assertEq(xalpha.balanceOf(adminSafe), B, "all to adminSafe");
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), 0, "cohort skipped");
        assertEq(escrow.bondAmount(LIEN_A), 0);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Resolved));
    }

    function test_resolve_nonDefaulted_reverts_badStatus() public {
        bytes memory report = _report(4, abi.encode(LIEN_A, uint256(0)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_resolve_after_resolve_reverts_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18);
        _resolveReport(LIEN_A, 30e18);
        bytes memory report = _report(4, abi.encode(LIEN_A, uint256(0)));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);
    }

    function test_resolve_exceedsBond_atomic_rollback() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        uint256 pBefore = _provision(LIEN_A);
        uint256 totBefore = coordinator.totalProvision();
        uint256 oracleBefore = oracle.provision();

        // capitalSlash > B => escrow reverts ExceedsBond => whole report (incl. the provision write) rolls back
        bytes memory report = _report(4, abi.encode(LIEN_A, B + 1));
        vm.prank(forwarder);
        vm.expectRevert(LienXAlphaEscrow.ExceedsBond.selector);
        coordinator.onReport("", report);

        assertEq(_provision(LIEN_A), pBefore, "provision unchanged after rollback");
        assertEq(coordinator.totalProvision(), totBefore, "totalProvision unchanged");
        assertEq(oracle.provision(), oracleBefore, "oracle provision unchanged");
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Defaulted), "status unchanged");
    }

    // ---------------------------------------------------------------- WRITEOFF (settle permanently + slash)
    function test_writeoff_partial_keeps_provision_no_coemit() public {
        uint256 B = 100e18;
        uint256 part = 70e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18); // p = 200e18
        uint256 p0 = _provision(LIEN_A);

        // record oracle emit count: WRITEOFF must NOT co-emit ProvisionWritten
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(escrow));
        emit SlashedToCohort(LIEN_A, B - part);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit WrittenOff(LIEN_A, part);
        _writeOffReport(LIEN_A, part);

        // assert NO ProvisionWritten from the oracle in the captured logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 pw = keccak256("ProvisionWritten(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle)) {
                assertTrue(logs[i].topics[0] != pw, "WRITEOFF must not write provision");
            }
        }

        assertEq(_provision(LIEN_A), p0, "provision unchanged (residual is the realized loss)");
        assertEq(coordinator.totalProvision(), p0, "totalProvision still carries the residual");
        assertEq(oracle.provision(), p0, "oracle provision unchanged");
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.WrittenOff));
        assertEq(xalpha.balanceOf(adminSafe), part);
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), B - part);
    }

    function test_writeoff_fullBond_skips_cohort() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        _writeOffReport(LIEN_A, B);
        assertEq(xalpha.balanceOf(adminSafe), B);
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), 0, "cohort skipped");
        assertEq(escrow.bondAmount(LIEN_A), 0);
    }

    function test_writeoff_purePremium_whole_to_cohort() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        _writeOffReport(LIEN_A, 0);
        assertEq(xalpha.balanceOf(juniorTrancheSidecar), B);
        assertEq(xalpha.balanceOf(adminSafe), 0);
    }

    function test_writeoff_exceedsBond_atomic_rollback() public {
        uint256 B = 100e18;
        _fund(B);
        _lock(LIEN_A, originator, B);
        _defaultReport(LIEN_A, 1000e18);
        uint256 pBefore = _provision(LIEN_A);
        uint256 totBefore = coordinator.totalProvision();
        uint256 oracleBefore = oracle.provision();

        bytes memory report = _report(5, abi.encode(LIEN_A, B + 1));
        vm.prank(forwarder);
        vm.expectRevert(LienXAlphaEscrow.ExceedsBond.selector);
        coordinator.onReport("", report);

        assertEq(_provision(LIEN_A), pBefore);
        assertEq(coordinator.totalProvision(), totBefore);
        assertEq(oracle.provision(), oracleBefore);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Defaulted));
    }

    function test_writeoff_then_action_terminal_badStatus() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18);
        _writeOffReport(LIEN_A, 30e18);
        // RECOVERY / RESOLVE / WRITEOFF / RELEASE on a written-off lien all revert
        bytes memory rec = _report(3, abi.encode(LIEN_A, uint256(1e18)));
        bytes memory res = _report(4, abi.encode(LIEN_A, uint256(0)));
        bytes memory wo = _report(5, abi.encode(LIEN_A, uint256(0)));
        bytes memory rel = _report(1, abi.encode(LIEN_A));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", rec);
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", res);
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", wo);
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", rel);
    }

    // ---------------------------------------------------------------- full illegal-transition matrix
    /// @dev From each of the 5 statuses attempt all 6 actions; assert exactly the legal ones pass and the rest
    ///      revert BadStatus. Each cell builds a FRESH coordinator at the target source status.
    function test_full_illegal_transition_matrix() public {
        // legal: None->Lock; Bonded->{Release,Default}; Defaulted->{Recovery,Resolve,WriteOff}
        for (uint8 src = 0; src < 5; src++) {
            for (uint8 act = 0; act < 6; act++) {
                bool legal = (src == 0 && act == 0) // None -> Lock
                    || (src == 1 && (act == 1 || act == 2)) // Bonded -> Release/Default
                    || (src == 2 && (act == 3 || act == 4 || act == 5)); // Defaulted -> Recovery/Resolve/WriteOff
                _matrixCell(src, act, legal);
            }
        }
    }

    function _matrixCell(uint8 src, uint8 act, bool legal) internal {
        _deploy(FLOOR); // fresh wiring per cell
        bytes32 lien = LIEN_A;

        // drive the lien to the target source status
        if (src == 1) {
            // Bonded
            _fund(100e18);
            _lock(lien, originator, 100e18);
        } else if (src == 2) {
            // Defaulted
            _fund(100e18);
            _lock(lien, originator, 100e18);
            _defaultReport(lien, 1000e18);
        } else if (src == 3) {
            // Resolved
            _fund(100e18);
            _lock(lien, originator, 100e18);
            _defaultReport(lien, 1000e18);
            _resolveReport(lien, 0);
        } else if (src == 4) {
            // WrittenOff
            _fund(100e18);
            _lock(lien, originator, 100e18);
            _defaultReport(lien, 1000e18);
            _writeOffReport(lien, 0);
        }
        // src == 0 (None): leave the lien untouched

        // build the action report with valid sub-data
        bytes memory data;
        if (act == 0) {
            data = abi.encode(lien, originator, uint256(100e18));
        } else if (act == 1) {
            data = abi.encode(lien);
        } else if (act == 2) {
            data = abi.encode(lien, uint256(1000e18));
        } else if (act == 3) {
            data = abi.encode(lien, uint256(1e18));
        } else {
            data = abi.encode(lien, uint256(0));
        }
        bytes memory report = _report(act, data);

        if (legal) {
            if (act == 0) _fund(100e18); // LOCK needs funding
            vm.prank(forwarder);
            coordinator.onReport("", report);
        } else {
            vm.prank(forwarder);
            vm.expectRevert(DefaultCoordinator.BadStatus.selector);
            coordinator.onReport("", report);
        }
    }

    function test_lock_on_resolved_and_writtenoff_reverts_badStatus() public {
        // explicit: terminal-status LOCK guard (escrow's bondAmount==0 would otherwise allow a re-lock)
        // Resolved
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _defaultReport(LIEN_A, 1000e18);
        _resolveReport(LIEN_A, 100e18); // full slash -> escrow bond 0, status Resolved
        assertEq(escrow.bondAmount(LIEN_A), 0);
        _fund(100e18);
        bytes memory report = _report(0, abi.encode(LIEN_A, originator, 100e18));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report);

        // WrittenOff
        _fund(100e18);
        _lock(LIEN_B, originator, 100e18);
        _defaultReport(LIEN_B, 1000e18);
        _writeOffReport(LIEN_B, 100e18); // full slash -> escrow bond 0, status WrittenOff
        assertEq(escrow.bondAmount(LIEN_B), 0);
        _fund(100e18);
        bytes memory report2 = _report(0, abi.encode(LIEN_B, originator, 100e18));
        vm.prank(forwarder);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        coordinator.onReport("", report2);
    }

    // ---------------------------------------------------------------- multi-lien independence + full unwind
    function test_multiLien_independence_and_full_unwind() public {
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        _fund(200e18);
        _lock(LIEN_B, originator2, 200e18);

        _defaultReport(LIEN_A, 1000e18); // pA = 200e18
        _defaultReport(LIEN_B, 500e18); // pB = 100e18
        uint256 pA = _provision(LIEN_A);
        uint256 pB = _provision(LIEN_B);
        assertEq(coordinator.totalProvision(), pA + pB);
        assertEq(oracle.provision(), pA + pB);

        _resolveReport(LIEN_A, 0); // heals only A
        assertEq(coordinator.totalProvision(), pB, "only A healed");
        assertEq(_provision(LIEN_B), pB, "B untouched");
        assertEq(oracle.provision(), pB);

        _resolveReport(LIEN_B, 0); // heals B
        assertEq(coordinator.totalProvision(), 0, "fully unwound to 0, no dust");
        assertEq(oracle.provision(), 0);
    }

    // ---------------------------------------------------------------- no-sweep / immutable / no-freeze ABI-negative
    function test_no_sweep_freeze_immutable_abiNegative() public {
        bytes4[] memory forbidden = new bytes4[](9);
        forbidden[0] = bytes4(keccak256("sweep(address,uint256)"));
        forbidden[1] = bytes4(keccak256("rescue(address,uint256)"));
        forbidden[2] = bytes4(keccak256("setRecoveryFloor(uint256)"));
        forbidden[3] = bytes4(keccak256("setNavOracle(address)"));
        forbidden[4] = bytes4(keccak256("setCoordinator(address)"));
        forbidden[5] = bytes4(keccak256("freeze()"));
        forbidden[6] = bytes4(keccak256("lockedFraction()"));
        forbidden[7] = bytes4(keccak256("engageFreeze()"));
        forbidden[8] = bytes4(keccak256("setExitGate(address)"));
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(coordinator).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok, "forbidden selector resolved");
        }
    }

    function test_timelock_is_admin_after_transfer() public {
        // Ownership transfers to the Timelock (NOT renounced) — the same admin pattern as the engine modules.
        address timelock = makeAddr("timelock");
        DefaultCoordinator c = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        c.transferOwnership(timelock);
        assertEq(c.owner(), timelock);
        // the old deployer can no longer call owner-only setters
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        c.setExpectedWorkflowId(keccak256("x"));
        // the Timelock can
        vm.prank(timelock);
        c.setExpectedWorkflowId(keccak256("x"));
        assertEq(c.getExpectedWorkflowId(), keccak256("x"));
    }

    function test_lock_works_under_timelock_owner() public {
        // onReport is Forwarder-gated, not owner-gated — LOCK works regardless of who owns the contract
        coordinator.transferOwnership(makeAddr("timelock"));
        _fund(100e18);
        _lock(LIEN_A, originator, 100e18);
        assertEq(uint256(_status(LIEN_A)), uint256(DefaultCoordinator.LienStatus.Bonded));
    }

    // ---------------------------------------------------------------- provision-bound fuzz
    function testFuzz_provision_bound(uint256 atRisk, uint256 proceeds, uint256 floor) public {
        floor = bound(floor, 0, 1e18 - 1);
        atRisk = bound(atRisk, 1, 1e30);
        proceeds = bound(proceeds, 0, 2e30);
        _deploy(floor);
        _fund(1e18);
        _lock(LIEN_A, originator, 1e18);
        _defaultReport(LIEN_A, atRisk);
        // the true economic cap: provision <= atRisk (NOT the formula re-applied)
        assertLe(_provision(LIEN_A), atRisk, "provision <= atRisk");
        assertEq(coordinator.totalProvision(), _provision(LIEN_A));
        assertEq(oracle.provision(), coordinator.totalProvision());

        _recoveryReport(LIEN_A, proceeds);
        assertLe(_provision(LIEN_A), atRisk, "provision <= atRisk after recovery");
        assertEq(coordinator.totalProvision(), _provision(LIEN_A));
        assertEq(oracle.provision(), coordinator.totalProvision());
    }
}

// =========================================================================================== integration suite
/// @dev Real `SzipNavOracle` + real `LienXAlphaEscrow` — proves the live `writeProvision` + slash wiring.
contract DefaultCoordinatorIntegrationTest is Test {
    MockERC20 internal xalpha;
    SzipNavOracle internal oracle;
    DefaultCoordinator internal coordinator;
    LienXAlphaEscrow internal escrow;

    address internal forwarder = makeAddr("forwarder");
    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSidecar = makeAddr("juniorTrancheSidecar");
    address internal originator = makeAddr("originator");
    address internal stranger = makeAddr("stranger");

    // token slots for the 11-arg oracle ctor
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockERC20 internal hydx;
    MockERC20 internal ohydx;

    bytes32 internal constant LIEN = bytes32(uint256(0xA11CE));
    uint256 internal constant FLOOR = 0.8e18;

    function setUp() public {
        vm.warp(1_000_000);
        xalpha = new MockERC20(18);
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        hydx = new MockERC20(18);
        ohydx = new MockERC20(18);
        address juniorTrancheSafe = makeAddr("juniorTrancheSafe");
        address oracleSidecar = makeAddr("oracleSidecar");

        // oracle deployed BEFORE the coordinator (navOracle immutable, no circularity)
        oracle = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdc),
            address(xalpha),
            address(hydx),
            address(ohydx),
            juniorTrancheSafe,
            oracleSidecar,
            4 hours, // W
            1 hours, // maxAge
            1000 // maxDeviationBps
        );
        coordinator = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        // escrow coordinator = this coordinator
        escrow = new LienXAlphaEscrow(address(xalpha), address(coordinator), adminSafe, juniorTrancheSidecar);
        // wire both seams
        oracle.setDefaultCoordinator(address(coordinator));
        coordinator.setEscrow(address(escrow));
    }

    function _report(uint8 action, bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(uint8(8), abi.encode(action, data));
    }

    function _drive(bytes memory report) internal {
        vm.prank(forwarder);
        coordinator.onReport("", report);
    }

    function test_integration_full_lifecycle_tracks_real_collaborators() public {
        uint256 B = 100e18;
        xalpha.mint(address(coordinator), B);

        // LOCK
        _drive(_report(0, abi.encode(LIEN, originator, B)));
        assertEq(escrow.bondAmount(LIEN), B);
        assertEq(escrow.bondOriginator(LIEN), originator);
        assertEq(oracle.provision(), coordinator.totalProvision());
        assertEq(oracle.provision(), 0);

        // DEFAULT
        uint256 atRisk = 1000e18;
        _drive(_report(2, abi.encode(LIEN, atRisk)));
        uint256 expectedP = atRisk * (1e18 - FLOOR) / 1e18;
        assertEq(coordinator.totalProvision(), expectedP);
        assertEq(oracle.provision(), expectedP, "real oracle tracks coordinator");

        // RECOVERY
        _drive(_report(3, abi.encode(LIEN, uint256(50e18))));
        assertEq(coordinator.totalProvision(), expectedP - 50e18);
        assertEq(oracle.provision(), expectedP - 50e18);

        // RESOLVE (part to capital, remainder to cohort)
        uint256 part = 60e18;
        _drive(_report(4, abi.encode(LIEN, part)));
        assertEq(coordinator.totalProvision(), 0);
        assertEq(oracle.provision(), 0, "healed to 0 on the real oracle");
        assertEq(xalpha.balanceOf(escrow.adminSafe()), part, "adminSafe got the slash");
        assertEq(xalpha.balanceOf(escrow.juniorTrancheSafe()), B - part, "junior tranche Safe got the remainder");
        assertEq(escrow.bondAmount(LIEN), 0);
    }

    function test_integration_oracle_gate_exclusive() public {
        // direct writeProvision from a non-coordinator EOA reverts NotDefaultCoordinator
        vm.prank(stranger);
        vm.expectRevert(SzipNavOracle.NotDefaultCoordinator.selector);
        oracle.writeProvision(123);
    }

    function test_integration_escrow_gate_exclusive() public {
        // direct lockXAlpha from a non-coordinator reverts NotCoordinator
        vm.prank(stranger);
        vm.expectRevert(LienXAlphaEscrow.NotCoordinator.selector);
        escrow.lockXAlpha(LIEN, originator, 1e18);
    }
}

// =========================================================================================== invariant handler
/// @dev Stateful handler driving all six actions over a small fixed lienId set against the MockNavOracle + real
///      escrow, with an INDEPENDENT ghost cap (Σ recognized atRisk*(1e18-floor)/1e18). Mirrors the escrow's
///      `EscrowHandler` deploy-cycle break trick (handler is the escrow's immutable coordinator-side via the
///      coordinator). Here the coordinator itself is the escrow's coordinator; the handler drives the coordinator's
///      Forwarder-gated entry.
contract CoordHandler is Test {
    MockERC20 public xalpha;
    MockNavOracle public oracle;
    DefaultCoordinator public coordinator;
    LienXAlphaEscrow public escrow;
    address public forwarder;
    uint256 public floor;

    bytes32[] public lienIds;
    mapping(bytes32 => bool) public touched;
    bytes32[] public touchedLiens;

    uint256 public ghost_cap; // Σ recognized atRisk*(1e18-floor)/1e18 (independent of the contract)

    constructor(
        MockERC20 x,
        MockNavOracle o,
        DefaultCoordinator c,
        LienXAlphaEscrow e,
        address fwd,
        uint256 floor_
    ) {
        xalpha = x;
        oracle = o;
        coordinator = c;
        escrow = e;
        forwarder = fwd;
        floor = floor_;
        for (uint256 i = 0; i < 5; i++) {
            lienIds.push(bytes32(uint256(i + 1)));
        }
    }

    function _lien(uint256 seed) internal view returns (bytes32) {
        return lienIds[seed % lienIds.length];
    }

    function _origFor(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("orig", seed))) | 1));
    }

    function _mark(bytes32 lienId) internal {
        if (!touched[lienId]) {
            touched[lienId] = true;
            touchedLiens.push(lienId);
        }
    }

    function _drive(uint8 action, bytes memory data) internal {
        bytes memory report = abi.encode(uint8(8), abi.encode(action, data));
        vm.prank(forwarder);
        coordinator.onReport("", report);
    }

    function _status(bytes32 lienId) internal view returns (DefaultCoordinator.LienStatus s) {
        (s,) = coordinator.lienLoss(lienId);
    }

    function lock(uint256 lienSeed, uint256 origSeed, uint256 amount) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.None) return;
        amount = bound(amount, 1, 1e24);
        xalpha.mint(address(coordinator), amount); // just-in-time funding
        _drive(0, abi.encode(lienId, _origFor(origSeed), amount));
        _mark(lienId);
    }

    function release(uint256 lienSeed) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.Bonded) return;
        _drive(1, abi.encode(lienId));
    }

    function default_(uint256 lienSeed, uint256 atRisk) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.Bonded) return;
        atRisk = bound(atRisk, 1, 1e30);
        _drive(2, abi.encode(lienId, atRisk));
        ghost_cap += atRisk * (1e18 - floor) / 1e18; // independent recompute, accumulated OUTSIDE the contract
        _mark(lienId);
    }

    function recovery(uint256 lienSeed, uint256 proceeds) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.Defaulted) return;
        proceeds = bound(proceeds, 0, 2e30);
        _drive(3, abi.encode(lienId, proceeds));
    }

    function resolve(uint256 lienSeed, uint256 capitalSlash) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.Defaulted) return;
        uint256 bond = escrow.bondAmount(lienId);
        capitalSlash = bound(capitalSlash, 0, bond);
        _drive(4, abi.encode(lienId, capitalSlash));
    }

    function writeoff(uint256 lienSeed, uint256 capitalSlash) external {
        bytes32 lienId = _lien(lienSeed);
        if (_status(lienId) != DefaultCoordinator.LienStatus.Defaulted) return;
        uint256 bond = escrow.bondAmount(lienId);
        capitalSlash = bound(capitalSlash, 0, bond);
        _drive(5, abi.encode(lienId, capitalSlash));
    }

    function touchedCount() external view returns (uint256) {
        return touchedLiens.length;
    }

    function touchedAt(uint256 i) external view returns (bytes32) {
        return touchedLiens[i];
    }
}

contract DefaultCoordinatorInvariantTest is Test {
    MockERC20 internal xalpha;
    MockNavOracle internal oracle;
    DefaultCoordinator internal coordinator;
    LienXAlphaEscrow internal escrow;
    CoordHandler internal handler;

    address internal forwarder = makeAddr("forwarder");
    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSidecar = makeAddr("juniorTrancheSidecar");

    uint256 internal constant FLOOR = 0.8e18;

    function setUp() public {
        xalpha = new MockERC20(18);
        oracle = new MockNavOracle();
        coordinator = new DefaultCoordinator(forwarder, address(oracle), address(xalpha), FLOOR);
        escrow = new LienXAlphaEscrow(address(xalpha), address(coordinator), adminSafe, juniorTrancheSidecar);
        coordinator.setEscrow(address(escrow));

        handler = new CoordHandler(xalpha, oracle, coordinator, escrow, forwarder, FLOOR);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](6);
        sels[0] = CoordHandler.lock.selector;
        sels[1] = CoordHandler.release.selector;
        sels[2] = CoordHandler.default_.selector;
        sels[3] = CoordHandler.recovery.selector;
        sels[4] = CoordHandler.resolve.selector;
        sels[5] = CoordHandler.writeoff.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @notice (i) totalProvision == Σ lienLoss[lienId].provision over touched liens.
    function invariant_totalProvision_eq_sum() public view {
        uint256 n = handler.touchedCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            (, uint256 p) = coordinator.lienLoss(handler.touchedAt(i));
            sum += p;
        }
        assertEq(coordinator.totalProvision(), sum, "totalProvision != Sigma provision");
    }

    /// @notice (ii) oracle.provision() == totalProvision (sole writer).
    function invariant_oracle_eq_totalProvision() public view {
        assertEq(oracle.provision(), coordinator.totalProvision(), "oracle != totalProvision");
    }

    /// @notice (iii) totalProvision <= the INDEPENDENT ghost cap (the security thesis).
    function invariant_totalProvision_le_ghostCap() public view {
        assertLe(coordinator.totalProvision(), handler.ghost_cap(), "totalProvision > ghost_cap");
    }
}
