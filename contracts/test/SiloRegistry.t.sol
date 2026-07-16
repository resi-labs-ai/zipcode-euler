// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";

// =========================================================================================== mocks
// Thin stubs exposing the four topology getters with configurable addresses, so the topology assert can be driven
// deterministically — both a self-consistent silo and deliberately mis-wired ones.

/// @dev Stub for `DurationFreezeModule.{eulerEarn(), warehouseSafe(), navOracle()}`.
contract MockFreeze {
    address public eulerEarn;
    address public warehouseSafe;
    address public navOracle;

    constructor(address eePool_, address warehouseSafe_, address navOracle_) {
        eulerEarn = eePool_;
        warehouseSafe = warehouseSafe_;
        navOracle = navOracle_;
    }
}

/// @dev Stub for `LienXAlphaEscrow.coordinator()`.
contract MockEscrow {
    address public coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }
}

/// @dev Stub for `DefaultCoordinator.navOracle()`.
contract MockCoordinator {
    address public navOracle;

    constructor(address navOracle_) {
        navOracle = navOracle_;
    }
}

/// @dev Stub for the venue adapter's venue-neutral `ISeniorVenue.seniorPool()` (CTR-10b).
contract MockAdapter {
    address public seniorPool;

    constructor(address eePool_) {
        seniorPool = eePool_;
    }
}

contract SiloRegistryTest is Test {
    SiloRegistry internal reg;

    address internal owner = address(this); // deployer == owner (Ownable(msg.sender))
    address internal controller = makeAddr("controller");
    address internal stranger = makeAddr("stranger");

    // shared plain leaf addresses for a self-consistent silo
    address internal eePool = makeAddr("eePool");
    address internal warehouseSafe = makeAddr("warehouseSafe");
    address internal navOracle = makeAddr("navOracle");
    address internal juniorBasket = makeAddr("juniorBasket");
    address internal curator = makeAddr("curator");

    // mirror of the contract event (for vm.expectEmit)
    event SiloActiveSet(bytes32 indexed siloId, bool active);

    function setUp() public {
        reg = new SiloRegistry(controller);
    }

    // ----- helpers -----

    /// @dev Build a fully self-consistent SiloConfig (all six topology clauses satisfied).
    function _wiredConfig() internal returns (SiloRegistry.SiloConfig memory cfg) {
        // defaultCoordinator must point at navOracle; escrow must point at defaultCoordinator; freeze must point at
        // {eePool, warehouseSafe, navOracle}; adapter must point at eePool.
        address coordinator_ = address(new MockCoordinator(navOracle));
        address escrow_ = address(new MockEscrow(coordinator_));
        address freeze_ = address(new MockFreeze(eePool, warehouseSafe, navOracle));
        address adapter_ = address(new MockAdapter(eePool));

        cfg = SiloRegistry.SiloConfig({
            adapter: adapter_,
            warehouseSafe: warehouseSafe,
            eePool: eePool,
            juniorBasket: juniorBasket,
            escrow: escrow_,
            defaultCoordinator: coordinator_,
            navOracle: navOracle,
            freeze: freeze_,
            curator: curator
        });
    }

    function _addWired(bytes32 id) internal returns (SiloRegistry.SiloConfig memory cfg) {
        cfg = _wiredConfig();
        reg.addSilo(id, cfg);
    }

    // ============================================================== addSilo happy path
    function test_addSilo_happyPath() public {
        bytes32 id = keccak256("silo-A");
        SiloRegistry.SiloConfig memory cfg = _addWired(id);

        SiloRegistry.Silo memory s = reg.getSilo(id);
        assertEq(s.adapter, cfg.adapter, "adapter");
        assertEq(s.warehouseSafe, cfg.warehouseSafe, "warehouseSafe");
        assertEq(s.eePool, cfg.eePool, "eePool");
        assertEq(s.juniorBasket, cfg.juniorBasket, "juniorBasket");
        assertEq(s.escrow, cfg.escrow, "escrow");
        assertEq(s.defaultCoordinator, cfg.defaultCoordinator, "defaultCoordinator");
        assertEq(s.navOracle, cfg.navOracle, "navOracle");
        assertEq(s.freeze, cfg.freeze, "freeze");
        assertEq(s.curator, cfg.curator, "curator");
        assertEq(s.lineCount, 0, "lineCount starts 0");
        assertTrue(s.active, "active starts true");

        // currentSilo set on first admit
        assertEq(reg.currentSilo(), id, "currentSilo set on first");
        assertEq(reg.venueOf(id), cfg.adapter, "venueOf == adapter");
        assertEq(reg.siloCount(), 1, "siloCount");
        assertEq(reg.allSiloIds().length, 1, "allSiloIds len");
        assertEq(reg.allSiloIds()[0], id, "allSiloIds[0]");
    }

    /// @dev currentSilo is set only on the FIRST admit; a second admit does not move it.
    function test_addSilo_currentSilo_onlyFirst() public {
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        _addWired(a);
        _addWired(b);
        assertEq(reg.currentSilo(), a, "currentSilo stays first");
        assertEq(reg.siloCount(), 2, "two silos");
    }

    // ============================================================== zero siloId
    function test_addSilo_zeroId_reverts() public {
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        vm.expectRevert(SiloRegistry.ZeroSiloId.selector);
        reg.addSilo(bytes32(0), cfg);
    }

    // ============================================================== duplicate id
    function test_addSilo_duplicate_reverts() public {
        bytes32 id = keccak256("dup");
        _addWired(id);
        SiloRegistry.SiloConfig memory cfg2 = _wiredConfig();
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.DuplicateSilo.selector, id));
        reg.addSilo(id, cfg2);
    }

    // ============================================================== any zero address in cfg
    function test_addSilo_zeroAddress_eachField_reverts() public {
        bytes32 id = keccak256("zaddr");

        // For each of the 9 fields, zero it and confirm a ZeroAddress revert.
        for (uint256 i = 0; i < 9; i++) {
            SiloRegistry.SiloConfig memory cfg = _wiredConfig();
            if (i == 0) cfg.adapter = address(0);
            else if (i == 1) cfg.warehouseSafe = address(0);
            else if (i == 2) cfg.eePool = address(0);
            else if (i == 3) cfg.juniorBasket = address(0);
            else if (i == 4) cfg.escrow = address(0);
            else if (i == 5) cfg.defaultCoordinator = address(0);
            else if (i == 6) cfg.navOracle = address(0);
            else if (i == 7) cfg.freeze = address(0);
            else if (i == 8) cfg.curator = address(0);

            vm.expectRevert(SiloRegistry.ZeroAddress.selector);
            reg.addSilo(id, cfg);
        }
    }

    // ============================================================== topology assert (>=2 distinct broken clauses)

    /// @dev Clause 1: freeze.eulerEarn() != eePool.
    function test_addSilo_miswired_freezeEePool_reverts() public {
        bytes32 id = keccak256("mw1");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        // freeze points at a sibling pool, not cfg.eePool
        cfg.freeze = address(new MockFreeze(makeAddr("siblingPool"), warehouseSafe, navOracle));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    /// @dev Clause 4: escrow.coordinator() != defaultCoordinator.
    function test_addSilo_miswired_escrowCoordinator_reverts() public {
        bytes32 id = keccak256("mw2");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        // escrow points at a sibling coordinator
        cfg.escrow = address(new MockEscrow(makeAddr("siblingCoordinator")));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    /// @dev Clause 2: freeze.warehouseSafe() != warehouseSafe.
    function test_addSilo_miswired_freezeWarehouse_reverts() public {
        bytes32 id = keccak256("mw3");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        cfg.freeze = address(new MockFreeze(eePool, makeAddr("siblingSafe"), navOracle));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    /// @dev Clause 3: freeze.navOracle() != navOracle.
    function test_addSilo_miswired_freezeNavOracle_reverts() public {
        bytes32 id = keccak256("mw4");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        cfg.freeze = address(new MockFreeze(eePool, warehouseSafe, makeAddr("siblingOracle")));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    /// @dev Clause 5: defaultCoordinator.navOracle() != navOracle.
    function test_addSilo_miswired_coordinatorNavOracle_reverts() public {
        bytes32 id = keccak256("mw5");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        address badCoord = address(new MockCoordinator(makeAddr("siblingOracle")));
        // keep escrow consistent with the new coordinator so clause 4 still passes — isolate clause 5
        cfg.defaultCoordinator = badCoord;
        cfg.escrow = address(new MockEscrow(badCoord));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    /// @dev Clause 6: adapter.seniorPool() != eePool.
    function test_addSilo_miswired_adapterEePool_reverts() public {
        bytes32 id = keccak256("mw6");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        cfg.adapter = address(new MockAdapter(makeAddr("siblingPool")));
        vm.expectRevert(SiloRegistry.SiloMiswired.selector);
        reg.addSilo(id, cfg);
    }

    // ============================================================== slot accounting

    function test_incrementToCap_thenSiloFull() public {
        bytes32 id = keccak256("cap");
        _addWired(id);

        uint16 cap = reg.MAX_LINES_PER_SILO();
        for (uint16 i = 0; i < cap; i++) {
            vm.prank(controller);
            reg.incrementLineCount(id);
        }
        assertEq(reg.getSilo(id).lineCount, cap, "at cap");

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.SiloFull.selector, id));
        reg.incrementLineCount(id);
    }

    function test_decrement_freesRegistrySlot() public {
        bytes32 id = keccak256("dec");
        _addWired(id);

        vm.prank(controller);
        reg.incrementLineCount(id);
        assertEq(reg.getSilo(id).lineCount, 1, "count 1");

        vm.prank(controller);
        reg.decrementLineCount(id);
        assertEq(reg.getSilo(id).lineCount, 0, "count back to 0");
    }

    function test_decrement_zeroCount_reverts() public {
        bytes32 id = keccak256("dec0");
        _addWired(id);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.NoLinesToDecrement.selector, id));
        reg.decrementLineCount(id);
    }

    // ============================================================== onlyController gating
    function test_incrementLineCount_onlyController() public {
        bytes32 id = keccak256("inc-auth");
        _addWired(id);
        vm.prank(stranger);
        vm.expectRevert(SiloRegistry.NotController.selector);
        reg.incrementLineCount(id);
    }

    function test_decrementLineCount_onlyController() public {
        bytes32 id = keccak256("dec-auth");
        _addWired(id);
        vm.prank(controller);
        reg.incrementLineCount(id);
        vm.prank(stranger);
        vm.expectRevert(SiloRegistry.NotController.selector);
        reg.decrementLineCount(id);
    }

    // ============================================================== onlyOwner gating
    function test_addSilo_onlyOwner() public {
        bytes32 id = keccak256("owner-add");
        SiloRegistry.SiloConfig memory cfg = _wiredConfig();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addSilo(id, cfg);
    }

    function test_retireSilo_onlyOwner() public {
        bytes32 id = keccak256("owner-retire");
        _addWired(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.retireSilo(id);
    }

    function test_setActive_onlyOwner() public {
        bytes32 id = keccak256("owner-active");
        _addWired(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.setActive(id, false);
    }

    function test_setCurrentSilo_onlyOwner() public {
        bytes32 id = keccak256("owner-current");
        _addWired(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.setCurrentSilo(id);
    }

    function test_setController_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.setController(makeAddr("newController"));
    }

    // ============================================================== retireSilo
    function test_retireSilo_stopsRouting_keepsRecord() public {
        bytes32 id = keccak256("retire");
        SiloRegistry.SiloConfig memory cfg = _addWired(id);
        assertEq(reg.currentSilo(), id, "current set before retire");

        reg.retireSilo(id);

        SiloRegistry.Silo memory s = reg.getSilo(id);
        assertFalse(s.active, "active false after retire");
        // record stays fully readable
        assertEq(s.adapter, cfg.adapter, "record readable: adapter");
        assertEq(s.eePool, cfg.eePool, "record readable: eePool");
        // currentSilo cleared since it was the current
        assertEq(reg.currentSilo(), bytes32(0), "currentSilo cleared");
        // never deleted from enumeration
        assertEq(reg.siloCount(), 1, "still enumerated");
    }

    /// @dev Retiring a non-current silo leaves currentSilo untouched.
    function test_retireSilo_nonCurrent_keepsCurrent() public {
        bytes32 a = keccak256("ra");
        bytes32 b = keccak256("rb");
        _addWired(a); // becomes current
        _addWired(b);
        reg.retireSilo(b);
        assertEq(reg.currentSilo(), a, "current unchanged");
        assertFalse(reg.getSilo(b).active, "b inactive");
    }

    // ============================================================== setCurrentSilo guards
    function test_setCurrentSilo_unknown_reverts() public {
        bytes32 ghost = keccak256("ghost");
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.UnknownSilo.selector, ghost));
        reg.setCurrentSilo(ghost);
    }

    function test_setCurrentSilo_inactive_reverts() public {
        bytes32 id = keccak256("sci");
        _addWired(id);
        reg.setActive(id, false);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.SiloInactive.selector, id));
        reg.setCurrentSilo(id);
    }

    function test_setCurrentSilo_rollover() public {
        bytes32 a = keccak256("rolla");
        bytes32 b = keccak256("rollb");
        _addWired(a);
        _addWired(b);
        assertEq(reg.currentSilo(), a, "starts a");
        reg.setCurrentSilo(b);
        assertEq(reg.currentSilo(), b, "rolled to b");
    }

    // ============================================================== setController happy path
    function test_setController_repoints() public {
        address newController = makeAddr("newController");
        reg.setController(newController);
        assertEq(reg.controller(), newController, "controller re-pointed");
    }

    function test_setController_zero_reverts() public {
        vm.expectRevert(SiloRegistry.ZeroAddress.selector);
        reg.setController(address(0));
    }

    // ============================================================== I-12: UnknownSilo on every by-id function
    /// @dev The `UnknownSilo` guard is carried by five by-id functions; only `setCurrentSilo`'s was tested. Cover the
    ///      other four: retire/setActive (owner path) and increment/decrement (controller path — onlyController
    ///      passes, then UnknownSilo fires on the unknown id).
    function test_unknownSilo_reverts_on_all_byId_functions() public {
        bytes32 unknown = keccak256("does-not-exist");

        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.UnknownSilo.selector, unknown));
        reg.retireSilo(unknown);

        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.UnknownSilo.selector, unknown));
        reg.setActive(unknown, true);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.UnknownSilo.selector, unknown));
        reg.incrementLineCount(unknown);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.UnknownSilo.selector, unknown));
        reg.decrementLineCount(unknown);
    }

    // ============================================================== I-13: setActive flips the flag (both ways) + emits
    function test_setActive_effect_flipsBothWays_andEmits() public {
        bytes32 id = keccak256("active-effect");
        _addWired(id);
        assertTrue(reg.getSilo(id).active, "starts active");

        vm.expectEmit(true, false, false, true, address(reg));
        emit SiloActiveSet(id, false);
        reg.setActive(id, false);
        assertFalse(reg.getSilo(id).active, "flipped to inactive");

        vm.expectEmit(true, false, false, true, address(reg));
        emit SiloActiveSet(id, true);
        reg.setActive(id, true);
        assertTrue(reg.getSilo(id).active, "flipped back to active");
    }
}
