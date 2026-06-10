// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {CreditWarehouseDeployer} from "../script/CreditWarehouseDeployer.sol";
import {WarehouseAdminModule} from "../src/supply/CreditWarehouse/WarehouseAdminModule.sol";
import {MockEulerEarn} from "./mocks/MockEulerEarn.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {ESynth} from "evk/Synths/ESynth.sol";

import {OffRampModule, IZipRedemptionQueue} from "../src/supply/szipUSD/OffRampModule.sol";
import {ZipRedemptionQueue} from "../src/supply/ZipRedemptionQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe (Zodiac avatar surface) — copied from `RecycleModule.t.sol`. Records every
///         `(to, value, data, operation)`, can perform the call live, and can force an exec index to fail.
contract RecordingSafe {
    struct Recorded {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    Recorded[] public calls;
    bool public live;
    uint256 public failOnCallIndex = type(uint256).max;
    bytes private _returnData;

    function setLive(bool v) external {
        live = v;
    }

    function setFailOnCallIndex(uint256 i) external {
        failOnCallIndex = i;
    }

    function setReturnData(bytes calldata d) external {
        _returnData = d;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (address to, uint256 value, bytes memory data, uint8 operation) {
        Recorded storage r = calls[i];
        return (r.to, r.value, r.data, r.operation);
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        (bool ok,) = _record(to, value, data, operation);
        return ok;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool, bytes memory)
    {
        return _record(to, value, data, operation);
    }

    function _record(address to, uint256 value, bytes calldata data, uint8 operation)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (calls.length == failOnCallIndex) revert("forced-fail");
        calls.push(Recorded({to: to, value: value, data: data, operation: operation}));
        if (live) {
            (ok, ret) = to.call{value: value}(data); // model the real Safe: return (false, revertData), do NOT bubble
            return (ok, ret);
        }
        return (true, _returnData);
    }

    receive() external payable {}
}

/// @dev A minimal queue stand-in exposing a settable `scaleUp` — proves the module reads `scaleUp()` LIVE (not a
///      hard-coded 1e12). Its `requestRedeem`/`withdraw` are no-ops (the RecordingSafe records the calldata).
contract MockQueue {
    uint256 public scaleUp;

    constructor(uint256 s) {
        scaleUp = s;
    }

    function setScaleUp(uint256 s) external {
        scaleUp = s;
    }

    function requestRedeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev A target whose every call reverts with empty data (for the ExecFailed path).
contract RevertEmpty {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

// =========================================================================== unit tests (no fork)

contract OffRampModuleUnitTest is Test {
    OffRampModule internal m;
    RecordingSafe internal safe;
    MockQueue internal queue;
    address internal zipUSD = makeAddr("zipUSD");

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    event Redeemed(uint256 zipAmount, address requester);
    event Claimed(uint256 assets, address receiver);

    uint256 internal constant SCALE = 1e12;

    function setUp() public {
        safe = new RecordingSafe();
        queue = new MockQueue(SCALE);
        m = new OffRampModule();
        m.setUp(_params(owner, address(safe), operator, zipUSD, address(queue)));
    }

    function _params(address o, address s, address op, address z, address q) internal pure returns (bytes memory) {
        return abi.encode(o, s, op, z, q);
    }

    function _assertCall(uint256 i, address to, bytes memory data) internal view {
        (address rto, uint256 rval, bytes memory rdata, uint8 rop) = safe.getCall(i);
        assertEq(rto, to, "call to");
        assertEq(rval, 0, "value == 0");
        assertEq(rop, 0, "operation == Call");
        assertEq(rdata, data, "call data");
    }

    // ----------------------------------------------------------------- setUp / wiring / authority / locks

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.rqSafe(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.zipUSD(), zipUSD);
        assertEq(m.queue(), address(queue));
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(_params(owner, address(safe), operator, zipUSD, address(queue)));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        OffRampModule x = new OffRampModule();
        vm.expectRevert(OffRampModule.OwnerIsOperator.selector);
        x.setUp(_params(owner, address(safe), owner, zipUSD, address(queue)));
    }

    function test_setUp_rejects_zero_in_each_of_five() public {
        _expectZero(_params(address(0), address(safe), operator, zipUSD, address(queue)));
        _expectZero(_params(owner, address(0), operator, zipUSD, address(queue)));
        _expectZero(_params(owner, address(safe), address(0), zipUSD, address(queue)));
        _expectZero(_params(owner, address(safe), operator, address(0), address(queue)));
        _expectZero(_params(owner, address(safe), operator, zipUSD, address(0)));
    }

    function _expectZero(bytes memory params) internal {
        OffRampModule x = new OffRampModule();
        vm.expectRevert(OffRampModule.ZeroAddress.selector);
        x.setUp(params);
    }

    function test_setUp_abi_length_mismatch_reverts() public {
        OffRampModule x = new OffRampModule();
        vm.expectRevert();
        x.setUp(abi.encode(owner, address(safe), operator, zipUSD)); // only 4 -> decode reverts
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        OffRampModule mc = new OffRampModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.rqSafe(), address(0));
        assertEq(mc.zipUSD(), address(0));
        assertEq(mc.queue(), address(0));
        vm.prank(operator);
        vm.expectRevert(OffRampModule.NotOperator.selector);
        mc.requestRedeem(1e18);
    }

    // ----------------------------------------------------------------- authority on the action legs

    function test_action_legs_only_operator() public {
        vm.startPrank(rando);
        vm.expectRevert(OffRampModule.NotOperator.selector);
        m.requestRedeem(1e18);
        vm.expectRevert(OffRampModule.NotOperator.selector);
        m.claim(1e6);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- Timelock wiring setters

    function test_wiring_setters_onlyOwner_and_zero_guard() public {
        // non-owner cannot set
        vm.prank(operator);
        vm.expectRevert();
        m.setOperator(rando);
        // zero rejected (owner caller)
        vm.prank(owner);
        vm.expectRevert(OffRampModule.ZeroAddress.selector);
        m.setQueue(address(0));
        // owner re-points (build-phase, §17) — rqSafe keeps avatar/target in lock-step
        address newSafe = makeAddr("newSafe");
        vm.prank(owner);
        m.setRqSafe(newSafe);
        assertEq(m.rqSafe(), newSafe);
        assertEq(m.avatar(), newSafe);
        assertEq(m.target(), newSafe);
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        m.setOperator(newOp);
        assertEq(m.operator(), newOp);
    }

    // ----------------------------------------------------------------- requestRedeem exec-shape

    function test_requestRedeem_exec_shape() public {
        uint256 amt = 40e18;
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit Redeemed(amt, address(safe));
        m.requestRedeem(amt);

        assertEq(safe.callCount(), 3, "exactly three recorded calls");
        _assertCall(0, zipUSD, abi.encodeWithSelector(IERC20.approve.selector, address(queue), amt));
        _assertCall(
            1,
            address(queue),
            abi.encodeCall(IZipRedemptionQueue.requestRedeem, (amt, address(safe), address(safe)))
        );
        _assertCall(2, zipUSD, abi.encodeWithSelector(IERC20.approve.selector, address(queue), uint256(0)));
    }

    function test_requestRedeem_zero_amount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(OffRampModule.ZeroAmount.selector);
        m.requestRedeem(0);
    }

    /// @dev Proves the LIVE `scaleUp()` read: set the queue's scaleUp to a non-1e12 value; an amount that IS a whole
    ///      multiple of 1e12 but NOT of the live scaleUp reverts `NotWholeUnit`.
    function test_requestRedeem_reads_scaleUp_live() public {
        queue.setScaleUp(1e15); // a non-18/6 queue (e.g. 18-dp vs 3-dp asset)
        // 40e18 is a whole multiple of 1e12 but NOT of 1e15? 40e18 / 1e15 = 40000 -> IS whole. Use a value that is
        // a multiple of 1e12 but not 1e15: 1e12 itself.
        uint256 amt = 1e12; // % 1e12 == 0 but % 1e15 != 0
        vm.prank(operator);
        vm.expectRevert(OffRampModule.NotWholeUnit.selector);
        m.requestRedeem(amt);
        // a whole multiple of the live scaleUp succeeds
        vm.prank(operator);
        m.requestRedeem(2e15);
        assertEq(safe.callCount(), 3);
    }

    // ----------------------------------------------------------------- claim exec-shape

    function test_claim_exec_shape() public {
        uint256 assets = 1_000e6;
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit Claimed(assets, address(safe));
        m.claim(assets);

        assertEq(safe.callCount(), 1, "exactly one recorded call");
        _assertCall(0, address(queue), abi.encodeCall(IZipRedemptionQueue.withdraw, (assets, address(safe), address(safe))));
    }

    function test_claim_zero_amount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(OffRampModule.ZeroAmount.selector);
        m.claim(0);
    }

    // ----------------------------------------------------------------- bubbling _exec (live RecordingSafe)

    function test_requestRedeem_bubbles_on_inner_fail() public {
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // the requestRedeem exec reverts "forced-fail"
        vm.prank(operator);
        vm.expectRevert(bytes("forced-fail"));
        m.requestRedeem(40e18);
    }

    function test_exec_failed_empty_revert_data() public {
        // a live Safe whose target returns (false, "") -> ExecFailed. Wire zipUSD + queue to a RevertEmpty so the
        // first approve catches (false, "") -> _exec reverts ExecFailed (not a bubble).
        RevertEmpty re = new RevertEmpty();
        // RevertEmpty has no scaleUp(); call the no-whole-unit-check path by wiring a real MockQueue for scaleUp but
        // RevertEmpty for the zipUSD approve target. queue.scaleUp == SCALE so amt passes the whole-unit check.
        OffRampModule x = new OffRampModule();
        RecordingSafe s2 = new RecordingSafe();
        x.setUp(_params(owner, address(s2), operator, address(re), address(queue)));
        s2.setLive(true);
        vm.prank(operator);
        vm.expectRevert(OffRampModule.ExecFailed.selector);
        x.requestRedeem(40e18);
    }
}

// =========================================================================== fork (live Base; real queue + warehouse)

/// @notice Full-cycle Base-fork test: a real summoned rq Safe with the OffRampModule enabled, driving the REAL
///         `ZipRedemptionQueue` (C4-gated to the rq Safe) + the REAL `WarehouseAdminModule` REPAY to fund the epoch.
///         Proves: `requestRedeem` through the real `exec` escrows with `RedeemRequest.sender == rqSafe` (C4 proof);
///         the main-Safe zipUSD drops by exactly `zipAmount` immediately; the CRE-equiv settle + `claim` lands USDC
///         at par; NAV-neutrality across the FULL cycle (basket zipUSD value lost == USDC value gained).
contract OffRampModuleForkTest is ForkConfig, SummonSubstrate {
    uint8 internal constant REPAY = 4;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");
    address internal controller = makeAddr("queueController");
    address internal forwarder = makeAddr("forwarder");
    address internal godOwner;

    uint256 internal constant SALT = uint256(keccak256("zipcode.offramp.c1.salt.a"));
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant Q = 1_000_000e18; // 1M zipUSD

    EthereumVaultConnector internal evc;
    ESynth internal zip;
    address internal usdc; // real Base USDC
    ZipRedemptionQueue internal queue;
    MockEulerEarn internal ee;
    CreditWarehouseDeployer internal deployer;
    CreditWarehouseDeployer.Warehouse internal w;
    WarehouseAdminModule internal adapter;
    address internal warehouseSafe;

    OffRampModule internal offRamp;
    address internal rqSafe;

    function setUp() public {
        _selectBaseFork();
        godOwner = address(this);
        usdc = BaseAddresses.USDC;

        // zipUSD side
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");

        // the queue FIRST (so the warehouse REPAY scope pins to == queue)
        queue = new ZipRedemptionQueue(address(zip), usdc, controller);

        // warehouse side: deploy with repaySink == queue
        ee = new MockEulerEarn(usdc);
        deployer = new CreditWarehouseDeployer();
        w = deployer.deploy(godOwner, address(ee), usdc, forwarder, address(queue), 1);
        adapter = WarehouseAdminModule(w.adapter);
        warehouseSafe = w.safe;

        // summon the real substrate -> rq Safe = Baal.avatar()
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        rqSafe = s.mainSafe;

        // deploy + enable the OffRampModule on the rq Safe
        offRamp = new OffRampModule();
        _enableModule(rqSafe, address(offRamp));
        offRamp.setUp(abi.encode(owner, rqSafe, operator, address(zip), address(queue)));

        // C4: authorize the rq Safe as the queue's redeemController (the module exec's THROUGH the Safe)
        queue.setRedeemController(rqSafe);

        // seed the basket: mint zipUSD into the rq Safe (the idle basket leg the off-ramp redeems)
        zip.setCapacity(address(this), type(uint128).max);
        zip.mint(rqSafe, Q);
    }

    function _enableModule(address safe, address module) internal {
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, module);
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(safe).execTransaction(safe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _repay(uint256 amount) internal {
        vm.prank(forwarder);
        adapter.onReport("", abi.encode(REPAY, abi.encode(address(queue), amount)));
    }

    function test_fork_full_cycle_par_nav_neutral() public {
        uint256 zipBefore = zip.balanceOf(rqSafe);
        uint256 usdcBefore = IERC20(usdc).balanceOf(rqSafe);

        // --- leg 1: requestRedeem through the real exec ---
        vm.recordLogs();
        vm.prank(operator);
        offRamp.requestRedeem(Q);

        // C4 proof: the RedeemRequest.sender (msg.sender at the queue) is the rq SAFE, not the module.
        // RedeemRequest(controller indexed, owner indexed, requestId indexed, sender, shares)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundReq;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(queue)
                    && logs[i].topics[0] == keccak256("RedeemRequest(address,address,uint256,address,uint256)")
            ) {
                (address sender, uint256 shares) = abi.decode(logs[i].data, (address, uint256));
                assertEq(sender, rqSafe, "RedeemRequest.sender == rqSafe (real exec-driven msg.sender)");
                assertEq(shares, Q);
                // controller (topic1) == owner (topic2) == rqSafe
                assertEq(address(uint160(uint256(logs[i].topics[1]))), rqSafe, "requester == rqSafe");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), rqSafe, "owner == rqSafe");
                foundReq = true;
            }
        }
        assertTrue(foundReq, "RedeemRequest emitted by the queue");

        // main-Safe zipUSD dropped by exactly zipAmount immediately (escrowed into the queue)
        assertEq(zipBefore - zip.balanceOf(rqSafe), Q, "rq Safe zipUSD down by exactly zipAmount");
        assertEq(queue.totalPending(), Q, "escrowed in the queue");
        // the module reset its approval (the 3rd leg)
        assertEq(zip.allowance(rqSafe, address(queue)), 0, "approval reset to 0");

        // --- leg 2: CRE funds the epoch (warehouse REPAY) then settles ---
        uint256 par = Q / SCALE; // 1M USDC
        deal(usdc, warehouseSafe, par);
        _repay(par);
        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION());
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.era(), 1, "full drain");

        // --- leg 3: claim the USDC back into the rq Safe (the basket) ---
        vm.prank(operator);
        offRamp.claim(par);
        assertEq(IERC20(usdc).balanceOf(rqSafe) - usdcBefore, par, "USDC landed in the rq Safe at par");

        // NAV-neutrality across the FULL cycle: the basket lost Q (18-dp $1) zipUSD and gained par*1e12 (18-dp $1)
        // USDC value -> exactly neutral.
        assertEq(zipBefore - zip.balanceOf(rqSafe), par * SCALE, "zipUSD value out == USDC value in (par neutral)");
        assertEq(zip.balanceOf(rqSafe), zipBefore - Q, "rq Safe holds only the un-redeemed zipUSD");
    }
}
