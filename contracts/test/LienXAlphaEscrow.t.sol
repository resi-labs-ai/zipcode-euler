// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LienXAlphaEscrow} from "../src/loss/LienXAlphaEscrow.sol";

// =========================================================================================== mocks
/// @dev Minimal configurable-decimals ERC20 (xALPHA stand-in). No fee-on-transfer, non-rebasing — matches the
///      production bridged LST's hookless/feeless assumption. Mirrors `ZipRedemptionQueue.t.sol:18`'s MockERC20.
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

/// @dev A xALPHA stand-in whose `transfer`/`transferFrom` re-enters the escrow mid-move — proves the
///      `nonReentrant` guard covers every safeTransfer/safeTransferFrom out. The test sets the escrow's
///      `coordinator == address(this reentrant token)` so the re-entrant call passes `onlyCoordinator` and
///      actually exercises the guard/CEI. Mirrors the `ReentrantUSDC` template at `ZipRedemptionQueue.t.sol:58`.
contract ReentrantToken {
    string public name = "ReXALPHA";
    string public symbol = "rXALPHA";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    LienXAlphaEscrow public escrow;
    uint8 public mode; // 0 = off, 1 = same-fn during release, 2 = cross-fn (release->cohort),
        // 3 = same-fn during cohort, 4 = lock reentry
    bytes32 public probeLien;

    function setEscrow(address e) external {
        escrow = LienXAlphaEscrow(e);
    }

    function arm(uint8 m, bytes32 lienId) external {
        mode = m;
        probeLien = lienId;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _reenter() internal {
        uint8 m = mode;
        mode = 0; // one-shot
        if (m == 1) {
            escrow.releaseXAlpha(probeLien); // same-fn reentry
        } else if (m == 2) {
            escrow.slashXAlphaToCohort(probeLien); // cross-fn reentry
        } else if (m == 3) {
            escrow.slashXAlphaToCohort(probeLien); // same-fn reentry (during a cohort transfer)
        } else if (m == 4) {
            escrow.lockXAlpha(probeLien, address(0xBEEF), 1); // lock reentry
        }
    }

    function transfer(address to, uint256 a) external returns (bool) {
        // On any payout out of the escrow, re-enter a guarded fn before completing the transfer.
        if (mode != 0 && msg.sender == address(escrow)) {
            _reenter();
        }
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        // Fire on the lock pull-in (the escrow is the recipient of the safeTransferFrom).
        if (mode != 0 && to == address(escrow)) {
            _reenter();
        }
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

// =========================================================================================== base harness (unit)
abstract contract EscrowBase is Test {
    MockERC20 internal xalpha; // 18-dp
    LienXAlphaEscrow internal escrow;

    address internal coordinator = makeAddr("coordinator");
    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSafe = makeAddr("juniorTrancheSafe");
    address internal originator = makeAddr("originator");
    address internal originator2 = makeAddr("originator2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant LIEN_A = bytes32(uint256(0xA));
    bytes32 internal constant LIEN_B = bytes32(uint256(0xB));

    function _baseSetUp() internal {
        xalpha = new MockERC20(18);
        escrow = new LienXAlphaEscrow(address(xalpha), coordinator, adminSafe, juniorTrancheSafe);
    }

    /// @dev Fund the coordinator with `amt` xALPHA and have it approve the escrow (the item-10 wiring obligation).
    function _fundCoordinator(uint256 amt) internal {
        xalpha.mint(coordinator, amt);
        vm.prank(coordinator);
        xalpha.approve(address(escrow), amt);
    }

    function _lock(bytes32 lienId, address orig, uint256 amt) internal {
        _fundCoordinator(amt);
        vm.prank(coordinator);
        escrow.lockXAlpha(lienId, orig, amt);
    }
}

// =========================================================================================== unit suite
contract LienXAlphaEscrowTest is EscrowBase {
    function setUp() public {
        _baseSetUp();
    }

    // -------------------------------------------------------------- ctor
    function test_ctor_stores_immutables() public view {
        assertEq(address(escrow.xAlpha()), address(xalpha));
        assertEq(escrow.coordinator(), coordinator);
        assertEq(escrow.adminSafe(), adminSafe);
        assertEq(escrow.juniorTrancheSafe(), juniorTrancheSafe);
    }

    function test_ctor_zero_xAlpha_reverts() public {
        vm.expectRevert(LienXAlphaEscrow.ZeroAddress.selector);
        new LienXAlphaEscrow(address(0), coordinator, adminSafe, juniorTrancheSafe);
    }

    function test_ctor_zero_coordinator_reverts() public {
        vm.expectRevert(LienXAlphaEscrow.ZeroAddress.selector);
        new LienXAlphaEscrow(address(xalpha), address(0), adminSafe, juniorTrancheSafe);
    }

    function test_ctor_zero_adminSafe_reverts() public {
        vm.expectRevert(LienXAlphaEscrow.ZeroAddress.selector);
        new LienXAlphaEscrow(address(xalpha), coordinator, address(0), juniorTrancheSafe);
    }

    function test_ctor_zero_juniorTrancheSafe_reverts() public {
        vm.expectRevert(LienXAlphaEscrow.ZeroAddress.selector);
        new LienXAlphaEscrow(address(xalpha), coordinator, adminSafe, address(0));
    }

    // -------------------------------------------------------------- lock (happy)
    function test_lock_happy_pulls_records_emits() public {
        uint256 amt = 100e18;
        _fundCoordinator(amt);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit LienXAlphaEscrow.Locked(LIEN_A, originator, amt);
        vm.prank(coordinator);
        escrow.lockXAlpha(LIEN_A, originator, amt);

        assertEq(xalpha.balanceOf(address(escrow)), amt, "escrow +amount");
        assertEq(xalpha.balanceOf(coordinator), 0, "coordinator -amount");
        assertEq(escrow.bondAmount(LIEN_A), amt, "bondAmount recorded");
        assertEq(escrow.bondOriginator(LIEN_A), originator, "bondOriginator recorded");
    }

    // -------------------------------------------------------------- lock (negatives)
    function test_lock_nonCoordinator_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(LienXAlphaEscrow.NotCoordinator.selector);
        escrow.lockXAlpha(LIEN_A, originator, 1e18);
    }

    function test_lock_zeroAmount_reverts() public {
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.ZeroAmount.selector);
        escrow.lockXAlpha(LIEN_A, originator, 0);
    }

    function test_lock_zeroOriginator_reverts() public {
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.ZeroOriginator.selector);
        escrow.lockXAlpha(LIEN_A, address(0), 1e18);
    }

    function test_lock_selfOriginator_reverts() public {
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.SelfOriginator.selector);
        escrow.lockXAlpha(LIEN_A, address(escrow), 1e18);
    }

    function test_lock_reLockBondedLien_reverts() public {
        _lock(LIEN_A, originator, 100e18);
        _fundCoordinator(50e18);
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.BondExists.selector);
        escrow.lockXAlpha(LIEN_A, originator, 50e18);
    }

    function test_lock_zeroAllowance_reverts() public {
        xalpha.mint(coordinator, 100e18); // minted but NOT approved
        vm.prank(coordinator);
        vm.expectRevert(); // SafeERC20 allowance underflow / failed op
        escrow.lockXAlpha(LIEN_A, originator, 100e18);
    }

    function test_lock_insufficientBalance_reverts() public {
        // approve but don't fund enough
        vm.prank(coordinator);
        xalpha.approve(address(escrow), 100e18);
        vm.prank(coordinator);
        vm.expectRevert(); // balance underflow
        escrow.lockXAlpha(LIEN_A, originator, 100e18);
    }

    function test_lock_failedPull_leaves_no_orphan() public {
        // a reverting pull (no allowance) must roll back the mapping writes
        xalpha.mint(coordinator, 100e18);
        vm.prank(coordinator);
        vm.expectRevert();
        escrow.lockXAlpha(LIEN_A, originator, 100e18);
        assertEq(escrow.bondAmount(LIEN_A), 0, "no orphaned bond entry");
        assertEq(escrow.bondOriginator(LIEN_A), address(0), "no orphaned originator entry");
    }

    // -------------------------------------------------------------- release (happy + negatives)
    function test_release_happy_returns_full_zeros_emits() public {
        uint256 amt = 100e18;
        _lock(LIEN_A, originator, amt);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit LienXAlphaEscrow.Released(LIEN_A, originator, amt);
        vm.prank(coordinator);
        escrow.releaseXAlpha(LIEN_A);

        assertEq(xalpha.balanceOf(originator), amt, "full bond returned to originator");
        assertEq(xalpha.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(escrow.bondAmount(LIEN_A), 0);
        assertEq(escrow.bondOriginator(LIEN_A), address(0));
    }

    function test_release_reRelease_reverts_noBond() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.releaseXAlpha(LIEN_A);
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.NoBond.selector);
        escrow.releaseXAlpha(LIEN_A);
    }

    function test_release_nonCoordinator_reverts() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(stranger);
        vm.expectRevert(LienXAlphaEscrow.NotCoordinator.selector);
        escrow.releaseXAlpha(LIEN_A);
    }

    function test_release_unbonded_reverts_noBond() public {
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.NoBond.selector);
        escrow.releaseXAlpha(LIEN_A);
    }

    // -------------------------------------------------------------- slashToCapital (happy + partial)
    function test_slashToCapital_happy_full_routes_to_sink() public {
        uint256 amt = 100e18;
        _lock(LIEN_A, originator, amt);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit LienXAlphaEscrow.SlashedToCapital(LIEN_A, amt);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, amt);

        assertEq(xalpha.balanceOf(adminSafe), amt, "routed to adminSafe");
        assertEq(escrow.bondAmount(LIEN_A), 0, "bond zeroed at exact boundary");
        assertEq(escrow.bondOriginator(LIEN_A), originator, "originator untouched");
    }

    function test_slashToCapital_partial_leaves_remainder() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, 40e18);

        assertEq(xalpha.balanceOf(adminSafe), 40e18, "40 routed");
        assertEq(escrow.bondAmount(LIEN_A), 60e18, "60 remainder stays");
        assertEq(escrow.bondOriginator(LIEN_A), originator, "originator intact");
        assertEq(xalpha.balanceOf(address(escrow)), 60e18, "escrow holds remainder");
    }

    // -------------------------------------------------------------- slashToCapital (boundary + negatives)
    function test_slashToCapital_exactBoundary_passes() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, 100e18); // amount == bond
        assertEq(escrow.bondAmount(LIEN_A), 0);
    }

    function test_slashToCapital_overByOne_reverts_exceedsBond() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.ExceedsBond.selector);
        escrow.slashXAlphaToCapital(LIEN_A, 100e18 + 1);
    }

    function test_slashToCapital_nonCoordinator_reverts() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(stranger);
        vm.expectRevert(LienXAlphaEscrow.NotCoordinator.selector);
        escrow.slashXAlphaToCapital(LIEN_A, 10e18);
    }

    function test_slashToCapital_zeroAmount_reverts() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.ZeroAmount.selector);
        escrow.slashXAlphaToCapital(LIEN_A, 0);
    }

    function test_slashToCapital_unbonded_reverts_exceedsBond() public {
        // amount > 0 over a 0 bond => ExceedsBond
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.ExceedsBond.selector);
        escrow.slashXAlphaToCapital(LIEN_A, 1);
    }

    // -------------------------------------------------------------- slashToCohort (pure premium + remainder)
    function test_slashToCohort_purePremium_routes_whole_bond() public {
        uint256 B = 100e18;
        _lock(LIEN_A, originator, B);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit LienXAlphaEscrow.SlashedToCohort(LIEN_A, B);
        vm.prank(coordinator);
        escrow.slashXAlphaToCohort(LIEN_A);

        assertEq(xalpha.balanceOf(juniorTrancheSafe), B, "whole bond to juniorTrancheSafe");
        assertEq(escrow.bondAmount(LIEN_A), 0);
        assertEq(escrow.bondOriginator(LIEN_A), address(0));
    }

    function test_slashToCohort_remainder_routes_residual() public {
        uint256 B = 100e18;
        uint256 part = 30e18;
        _lock(LIEN_A, originator, B);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, part);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit LienXAlphaEscrow.SlashedToCohort(LIEN_A, B - part);
        vm.prank(coordinator);
        escrow.slashXAlphaToCohort(LIEN_A);

        assertEq(xalpha.balanceOf(juniorTrancheSafe), B - part, "remainder to juniorTrancheSafe");
        assertEq(escrow.bondAmount(LIEN_A), 0);
        assertEq(escrow.bondOriginator(LIEN_A), address(0));
    }

    function test_slashToCohort_reCall_reverts_noBond_noTransfer() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.slashXAlphaToCohort(LIEN_A);

        uint256 juniorTrancheSafeBefore = xalpha.balanceOf(juniorTrancheSafe);
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.NoBond.selector);
        escrow.slashXAlphaToCohort(LIEN_A);
        assertEq(xalpha.balanceOf(juniorTrancheSafe), juniorTrancheSafeBefore, "no transfer on the reverting cohort call");
    }

    function test_slashToCohort_nonCoordinator_reverts() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(stranger);
        vm.expectRevert(LienXAlphaEscrow.NotCoordinator.selector);
        escrow.slashXAlphaToCohort(LIEN_A);
    }

    // -------------------------------------------------------------- the ordered two-job resolution (§4.6)
    function test_orderedResolution_capitalThenCohort() public {
        uint256 B = 100e18;
        uint256 part = 70e18;
        _lock(LIEN_A, originator, B);

        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, part);
        vm.prank(coordinator);
        escrow.slashXAlphaToCohort(LIEN_A);

        assertEq(xalpha.balanceOf(adminSafe), part, "part to adminSafe");
        assertEq(xalpha.balanceOf(juniorTrancheSafe), B - part, "remainder to juniorTrancheSafe");
        assertEq(xalpha.balanceOf(address(escrow)), 0, "escrow net 0");
        assertEq(escrow.bondAmount(LIEN_A), 0, "bond cleared");
        assertEq(escrow.bondOriginator(LIEN_A), address(0));
    }

    function test_orderedResolution_fullCapital_then_cohort_reverts() public {
        uint256 B = 100e18;
        _lock(LIEN_A, originator, B);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, B); // full-bond capital slash
        vm.prank(coordinator);
        vm.expectRevert(LienXAlphaEscrow.NoBond.selector);
        escrow.slashXAlphaToCohort(LIEN_A); // coordinator skips cohort when capital took everything
    }

    // -------------------------------------------------------------- multi-lien independence
    function test_multiLien_independence() public {
        _lock(LIEN_A, originator, 100e18);
        _lock(LIEN_B, originator2, 200e18);

        // release A pays A's originator and does NOT touch B
        vm.prank(coordinator);
        escrow.releaseXAlpha(LIEN_A);
        assertEq(xalpha.balanceOf(originator), 100e18);
        assertEq(escrow.bondAmount(LIEN_B), 200e18, "B untouched by A release");
        assertEq(escrow.bondOriginator(LIEN_B), originator2);

        // slashToCapital(B) does NOT touch A
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_B, 50e18);
        assertEq(xalpha.balanceOf(adminSafe), 50e18);
        assertEq(escrow.bondAmount(LIEN_A), 0, "A already released");
        assertEq(escrow.bondAmount(LIEN_B), 150e18);
        // aggregate invariant: escrow balance == Σ bondAmount over live liens
        assertEq(xalpha.balanceOf(address(escrow)), 150e18);
    }

    // -------------------------------------------------------------- re-lock reusability
    function test_reLock_after_release() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.releaseXAlpha(LIEN_A);
        // fresh lock with different originator/amount succeeds
        _fundCoordinator(50e18);
        vm.prank(coordinator);
        escrow.lockXAlpha(LIEN_A, originator2, 50e18);
        assertEq(escrow.bondAmount(LIEN_A), 50e18);
        assertEq(escrow.bondOriginator(LIEN_A), originator2);
    }

    function test_reLock_after_cohort_clears() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.slashXAlphaToCohort(LIEN_A);
        _fundCoordinator(50e18);
        vm.prank(coordinator);
        escrow.lockXAlpha(LIEN_A, originator2, 50e18);
        assertEq(escrow.bondAmount(LIEN_A), 50e18);
        assertEq(escrow.bondOriginator(LIEN_A), originator2);
    }

    // -------------------------------------------------------------- bondOriginator survives a partial slash
    function test_bondOriginator_survives_partial_slash() public {
        _lock(LIEN_A, originator, 100e18);
        vm.prank(coordinator);
        escrow.slashXAlphaToCapital(LIEN_A, 30e18);
        vm.prank(coordinator);
        escrow.releaseXAlpha(LIEN_A);
        assertEq(xalpha.balanceOf(originator), 70e18, "remainder returned to ORIGINAL originator");
    }

    // -------------------------------------------------------------- non-sweepable ABI-negative
    function test_no_sweep_surface_abiNegative() public {
        // Build phase (§17): a Timelock admin CAN re-point wiring (owner/transferOwnership/setCoordinator exist),
        // but there is still NO direct fund-extraction path — no sweep/rescue. Destination-integrity hardening
        // (re-freeze the wiring to immutable) is DEFERRED to pre-production.
        bytes4[] memory forbidden = new bytes4[](3);
        forbidden[0] = bytes4(keccak256("sweep(address,uint256)"));
        forbidden[1] = bytes4(keccak256("sweep(address)"));
        forbidden[2] = bytes4(keccak256("rescue(address,uint256)"));
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(escrow).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok, "fund-extraction surface exists");
        }
        // the build-phase admin surface DOES exist now
        assertEq(escrow.owner(), address(this), "Timelock admin owns the escrow");
    }

    // -------------------------------------------------------------- build-phase Timelock re-point
    function test_setWiring_onlyOwner_and_updates() public {
        address newSink = makeAddr("newSink");
        escrow.setAdminSafe(newSink);
        assertEq(escrow.adminSafe(), newSink);

        address newSidecar = makeAddr("newSidecar");
        escrow.setJuniorTrancheSafe(newSidecar);
        assertEq(escrow.juniorTrancheSafe(), newSidecar);

        address newCoord = makeAddr("newCoord");
        escrow.setCoordinator(newCoord);
        assertEq(escrow.coordinator(), newCoord);
    }

    function test_setWiring_nonOwner_reverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrow.setJuniorTrancheSafe(makeAddr("x"));
    }

    function test_setWiring_zero_reverts() public {
        vm.expectRevert(LienXAlphaEscrow.ZeroWiring.selector);
        escrow.setAdminSafe(address(0));
    }

    // -------------------------------------------------------------- fuzz: balance invariant preserved
    function testFuzz_lock_slash_preserves_balance(uint256 bond, uint256 part) public {
        bond = bound(bond, 1, 1e30);
        part = bound(part, 0, bond);
        _lock(LIEN_A, originator, bond);
        assertEq(xalpha.balanceOf(address(escrow)), bond, "escrow holds full bond");

        if (part != 0) {
            vm.prank(coordinator);
            escrow.slashXAlphaToCapital(LIEN_A, part);
        }
        assertEq(escrow.bondAmount(LIEN_A), bond - part, "remainder tracked");
        assertEq(xalpha.balanceOf(address(escrow)), bond - part, "escrow == bondAmount");
        assertEq(xalpha.balanceOf(adminSafe), part, "adminSafe got the slash");

        if (bond - part != 0) {
            vm.prank(coordinator);
            escrow.slashXAlphaToCohort(LIEN_A);
            assertEq(xalpha.balanceOf(juniorTrancheSafe), bond - part, "juniorTrancheSafe got the remainder");
        }
        assertEq(xalpha.balanceOf(address(escrow)), 0, "escrow fully drained");
        // total conservation: every minted token landed on one of the three destination classes
        assertEq(
            xalpha.balanceOf(adminSafe) + xalpha.balanceOf(juniorTrancheSafe) + xalpha.balanceOf(originator),
            bond,
            "conservation across the three destinations"
        );
    }
}

// =========================================================================================== reentrancy probe
contract LienXAlphaEscrowReentrancyTest is Test {
    ReentrantToken internal rtoken;
    LienXAlphaEscrow internal escrow;

    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSafe = makeAddr("juniorTrancheSafe");
    address internal originator = makeAddr("originator");

    bytes32 internal constant LIEN = bytes32(uint256(0xA11CE));

    function setUp() public {
        rtoken = new ReentrantToken();
        // coordinator == the reentrant token, so its callback passes onlyCoordinator and exercises the guard/CEI.
        escrow = new LienXAlphaEscrow(address(rtoken), address(rtoken), adminSafe, juniorTrancheSafe);
        rtoken.setEscrow(address(escrow));
    }

    /// @dev Lock a bond with the reentrant token as coordinator. The token funds itself + approves the escrow.
    function _lock(uint256 amt) internal {
        rtoken.mint(address(rtoken), amt);
        vm.prank(address(rtoken));
        rtoken.approve(address(escrow), amt);
        vm.prank(address(rtoken));
        escrow.lockXAlpha(LIEN, originator, amt);
    }

    function test_reentrancy_release_sameFn_blocked() public {
        _lock(100e18);
        rtoken.arm(1, LIEN); // re-enter releaseXAlpha during the payout transfer
        vm.prank(address(rtoken));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.releaseXAlpha(LIEN);
        // outer reverted entirely -> bond intact, no balance moved
        assertEq(escrow.bondAmount(LIEN), 100e18, "bond intact after guarded revert");
        assertEq(rtoken.balanceOf(originator), 0, "no payout");
    }

    function test_reentrancy_release_crossFn_blocked() public {
        _lock(100e18);
        rtoken.arm(2, LIEN); // release -> reenter slashXAlphaToCohort
        vm.prank(address(rtoken));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.releaseXAlpha(LIEN);
        assertEq(escrow.bondAmount(LIEN), 100e18, "bond intact");
        assertEq(rtoken.balanceOf(juniorTrancheSafe), 0, "no cross-fn leak");
    }

    function test_reentrancy_cohort_sameFn_blocked() public {
        _lock(100e18);
        rtoken.arm(3, LIEN); // re-enter slashXAlphaToCohort during its own transfer
        vm.prank(address(rtoken));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.slashXAlphaToCohort(LIEN);
        assertEq(escrow.bondAmount(LIEN), 100e18, "bond intact");
        assertEq(rtoken.balanceOf(juniorTrancheSafe), 0, "no payout");
    }

    function test_reentrancy_lock_reentry_blocked() public {
        // arm a lock-reentry on a SECOND lien while the first lock's pull callback fires
        rtoken.mint(address(rtoken), 100e18);
        vm.prank(address(rtoken));
        rtoken.approve(address(escrow), 100e18);
        rtoken.arm(4, bytes32(uint256(0xBEEF))); // re-enter lockXAlpha during the pull
        vm.prank(address(rtoken));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.lockXAlpha(LIEN, originator, 100e18);
        // outer reverted -> no orphan
        assertEq(escrow.bondAmount(LIEN), 0, "no orphan after guarded revert");
    }

    function test_reentrancy_outer_completes_balance_moves_once() public {
        // with the probe disarmed, the same release path completes exactly once (sanity baseline).
        _lock(100e18);
        rtoken.arm(0, LIEN); // disarmed
        vm.prank(address(rtoken));
        escrow.releaseXAlpha(LIEN);
        assertEq(rtoken.balanceOf(originator), 100e18, "balance moved exactly once");
        assertEq(escrow.bondAmount(LIEN), 0, "bond cleared once");
    }
}

// =========================================================================================== invariant/fuzz handler
/// @dev Stateful handler exposing all four state-changers over a small fixed lienId set + a ghost array of
///      touched lienIds. The escrow's coordinator is THIS handler. Uses balance-conservation accounting (the
///      mock emits no Transfer event we match on).
contract EscrowHandler is Test {
    MockERC20 public xalpha;
    LienXAlphaEscrow public escrow;
    address public adminSafe;
    address public juniorTrancheSafe;

    bytes32[] public lienIds; // the fixed candidate set
    mapping(bytes32 => bool) public touched;
    bytes32[] public touchedLiens; // ghost array
    mapping(bytes32 => address) public originatorOf; // who a live lien returns to

    address[] public allOriginators; // every DISTINCT originator ever used (for conservation accounting)
    mapping(address => bool) public seenOriginator;

    uint256 public ghost_minted; // total xALPHA ever minted into the system

    constructor(MockERC20 x, address cs, address sc) {
        xalpha = x;
        adminSafe = cs;
        juniorTrancheSafe = sc;
        for (uint256 i = 0; i < 5; i++) {
            lienIds.push(bytes32(uint256(i + 1)));
        }
    }

    /// @dev One-time wiring to break the escrow<->handler deploy cycle: deploy handler, deploy escrow with the
    ///      handler as the immutable coordinator, then point the handler at that escrow here.
    function setEscrow(address e) external {
        require(address(escrow) == address(0), "escrow already set");
        escrow = LienXAlphaEscrow(e);
    }

    function _lien(uint256 seed) internal view returns (bytes32) {
        return lienIds[seed % lienIds.length];
    }

    function _origFor(uint256 seed) internal pure returns (address) {
        // a deterministic non-zero, non-this originator per seed
        return address(uint160(uint256(keccak256(abi.encode("orig", seed))) | 1));
    }

    function _markTouched(bytes32 lienId) internal {
        if (!touched[lienId]) {
            touched[lienId] = true;
            touchedLiens.push(lienId);
        }
    }

    function lock(uint256 lienSeed, uint256 origSeed, uint256 amount) external {
        bytes32 lienId = _lien(lienSeed);
        if (escrow.bondAmount(lienId) != 0) return; // no clobber
        amount = bound(amount, 1, 1e24);
        address orig = _origFor(origSeed);
        // fund + approve the coordinator (this handler)
        xalpha.mint(address(this), amount);
        ghost_minted += amount;
        xalpha.approve(address(escrow), amount);
        escrow.lockXAlpha(lienId, orig, amount);
        originatorOf[lienId] = orig;
        if (!seenOriginator[orig]) {
            seenOriginator[orig] = true;
            allOriginators.push(orig);
        }
        _markTouched(lienId);
    }

    function release(uint256 lienSeed) external {
        bytes32 lienId = _lien(lienSeed);
        if (escrow.bondAmount(lienId) == 0) return;
        escrow.releaseXAlpha(lienId);
        originatorOf[lienId] = address(0);
    }

    function slashCapital(uint256 lienSeed, uint256 amount) external {
        bytes32 lienId = _lien(lienSeed);
        uint256 bond = escrow.bondAmount(lienId);
        if (bond == 0) return;
        amount = bound(amount, 1, bond);
        escrow.slashXAlphaToCapital(lienId, amount);
    }

    function slashCohort(uint256 lienSeed) external {
        bytes32 lienId = _lien(lienSeed);
        if (escrow.bondAmount(lienId) == 0) return;
        escrow.slashXAlphaToCohort(lienId);
        originatorOf[lienId] = address(0);
    }

    function lienCount() external view returns (uint256) {
        return lienIds.length;
    }

    function lienAt(uint256 i) external view returns (bytes32) {
        return lienIds[i];
    }

    function touchedCount() external view returns (uint256) {
        return touchedLiens.length;
    }

    function touchedAt(uint256 i) external view returns (bytes32) {
        return touchedLiens[i];
    }

    function originatorAt(bytes32 lienId) external view returns (address) {
        return originatorOf[lienId];
    }

    function originatorsCount() external view returns (uint256) {
        return allOriginators.length;
    }

    function originatorsAt(uint256 i) external view returns (address) {
        return allOriginators[i];
    }
}

contract LienXAlphaEscrowInvariantTest is Test {
    MockERC20 internal xalpha;
    LienXAlphaEscrow internal escrow;
    EscrowHandler internal handler;

    address internal adminSafe = makeAddr("adminSafe");
    address internal juniorTrancheSafe = makeAddr("juniorTrancheSafe");

    function setUp() public {
        xalpha = new MockERC20(18);
        // Break the escrow<->handler deploy cycle: handler first, then escrow with the handler as the immutable
        // coordinator, then point the handler at the escrow. The handler drives all four state-changers.
        handler = new EscrowHandler(xalpha, adminSafe, juniorTrancheSafe);
        escrow = new LienXAlphaEscrow(address(xalpha), address(handler), adminSafe, juniorTrancheSafe);
        handler.setEscrow(address(escrow));

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = EscrowHandler.lock.selector;
        sels[1] = EscrowHandler.release.selector;
        sels[2] = EscrowHandler.slashCapital.selector;
        sels[3] = EscrowHandler.slashCohort.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @notice (i) escrow xALPHA balance == Σ bondAmount over touched liens.
    function invariant_escrowBalance_eq_sumBonds() public view {
        uint256 n = handler.touchedCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            sum += escrow.bondAmount(handler.touchedAt(i));
        }
        assertEq(xalpha.balanceOf(address(escrow)), sum, "escrow balance != Sigma bondAmount");
    }

    /// @notice (ii) conservation (the security thesis): every minted xALPHA lands ONLY on one of the three
    ///         destination classes — {escrow, adminSafe, juniorTrancheSafe, the recorded originators} — and NO other
    ///         address (the handler/coordinator, an attacker) ever accrues xALPHA from an outbound transfer.
    ///         Exact: balanceOf(escrow) + balanceOf(adminSafe) + balanceOf(juniorTrancheSafe) + Σ distinct originators ==
    ///         ghost_minted, AND the coordinator/handler holds 0 (its mint is fully forwarded at lock).
    function invariant_conservation_three_destinations() public view {
        uint256 acc = xalpha.balanceOf(address(escrow)) + xalpha.balanceOf(adminSafe) + xalpha.balanceOf(juniorTrancheSafe);
        // Σ over every DISTINCT originator ever used (originators are unique per seed and never collide with the
        // three sinks — deterministic keccak | 1). This captures both live and already-released-and-paid bonds.
        uint256 m = handler.originatorsCount();
        for (uint256 i = 0; i < m; i++) {
            acc += xalpha.balanceOf(handler.originatorsAt(i));
        }
        // the coordinator/handler must NEVER hold xALPHA — every minted token is forwarded into the escrow at lock.
        assertEq(xalpha.balanceOf(address(handler)), 0, "coordinator must never accrue xALPHA");
        // exact conservation: no value created or destroyed; every token is on one of the three destination classes.
        assertEq(acc, handler.ghost_minted(), "xALPHA not conserved across the three destinations");
    }
}
