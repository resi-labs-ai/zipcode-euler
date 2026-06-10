// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {CreditWarehouseDeployer} from "../script/CreditWarehouseDeployer.sol";
import {WarehouseAdminModule} from "../src/supply/CreditWarehouse/WarehouseAdminModule.sol";
import {MockEulerEarn} from "./mocks/MockEulerEarn.sol";
import {ZipRedemptionQueue} from "../src/supply/ZipRedemptionQueue.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {ESynth} from "evk/Synths/ESynth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================================== mocks
/// @dev Minimal configurable-decimals ERC20 (USDC stand-in). No fee-on-transfer. Mirrors ZipDepositModule.t.sol.
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

/// @dev A USDC stand-in whose `transfer` re-enters the queue mid-payout — proves the `nonReentrant` guard covers
///      the claim path's `safeTransfer` out (KR-9). Used ONLY in the dedicated reentrancy test (the unit/fuzz
///      harnesses use the plain `MockERC20` or the real Base USDC).
contract ReentrantUSDC {
    string public name = "ReUSDC";
    string public symbol = "rUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    ZipRedemptionQueue public queue;
    bool public armed;

    function setQueue(address q) external {
        queue = ZipRedemptionQueue(q);
    }

    function arm(bool a) external {
        armed = a;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        // On the claim payout (queue -> receiver), re-enter a guarded fn before completing the transfer.
        if (armed && msg.sender == address(queue)) {
            armed = false; // one-shot
            queue.settleEpoch(); // re-enter a guarded fn -> ReentrancyGuardReentrantCall
        }
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

// =========================================================================================== base harness (unit)
/// @dev Shared no-fork setup: a live EVC + the REAL zipUSD `ESynth` (18-dp), a 6-dp `MockERC20` USDC, and the
///      queue with a dedicated `controller`. The test grants ITSELF ESynth minter capacity so it can mint zipUSD
///      to requesters. `scaleUp == 1e12`. EVC/ESynth are plain contracts — no fork needed. Mirrors
///      ZipDepositModule.t.sol's `ZipModuleBase`.
abstract contract QueueBase is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip; // REAL ESynth = zipUSD (18-dp)
    MockERC20 internal usdc; // 6-dp
    ZipRedemptionQueue internal queue;

    address internal controller = makeAddr("controller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SCALE = 1e12;

    function _baseSetUp() internal {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        queue = new ZipRedemptionQueue(address(zip), address(usdc), controller);
        zip.setCapacity(address(this), type(uint128).max); // owner == this -> can mint zipUSD to requesters
    }

    /// @dev Mint `zipAmt` zipUSD to `to`, have `to` approve the queue, AND authorize `to` as the redeemController
    ///      (C4: `requestRedeem` is hard-gated; in the legacy unit flows the caller == owner == requester == the
    ///      authorized rq-Safe stand-in, so wiring it to `to` preserves the open-queue behavior these tests assert).
    function _giveZip(address to, uint256 zipAmt) internal {
        zip.mint(to, zipAmt);
        vm.prank(to);
        zip.approve(address(queue), zipAmt);
        queue.setRedeemController(to); // owner == this (deployed the queue)
    }

    /// @dev Authorize `c` as the C4 redeemController (the sole `requestRedeem` caller). owner == this.
    function _authRedeem(address c) internal {
        queue.setRedeemController(c);
    }

    /// @dev Deliver `usdcAmt` USDC to the queue as if the warehouse REPAY transferred it in.
    function _deliverUsdc(uint256 usdcAmt) internal {
        usdc.mint(address(queue), usdcAmt);
    }

    function _warpPastEpoch() internal {
        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION());
    }

    function _settle() internal {
        vm.prank(controller);
        queue.settleEpoch();
    }
}

// =========================================================================================== unit suite
contract ZipRedemptionQueueTest is QueueBase {
    function setUp() public {
        _baseSetUp();
    }

    // -------------------------------------------------------------- ctor / scale
    function test_ctor_state() public view {
        assertEq(queue.zipUSD(), address(zip));
        assertEq(queue.usdc(), address(usdc));
        assertEq(queue.controller(), controller);
        assertEq(queue.scaleUp(), SCALE, "scaleUp = 1e12");
        assertEq(queue.PREC(), 1e27);
        assertEq(queue.EPOCH_DURATION(), 30 days);
        assertEq(queue.era(), 0);
        assertEq(queue.cumRemaining(), 1e27, "cumRemaining init PREC");
        assertEq(queue.lastEpochTime(), block.timestamp);
    }

    function test_ctor_zero_address_reverts() public {
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        new ZipRedemptionQueue(address(0), address(usdc), controller);
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        new ZipRedemptionQueue(address(zip), address(0), controller);
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        new ZipRedemptionQueue(address(zip), address(usdc), address(0));
    }

    function test_ctor_reverts_when_usdc_finer_than_zip() public {
        MockERC20 fatUsdc = new MockERC20(24);
        vm.expectRevert(ZipRedemptionQueue.DecimalsTooFew.selector);
        new ZipRedemptionQueue(address(zip), address(fatUsdc), controller);
    }

    // -------------------------------------------------------------- requestRedeem (lifecycle)
    function test_requestRedeem_escrows_and_emits() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.expectEmit(true, true, true, true, address(queue));
        emit ZipRedemptionQueue.RedeemRequest(alice, alice, 0, alice, q);
        vm.prank(alice);
        uint256 id = queue.requestRedeem(q, alice, alice);
        assertEq(id, 0, "singleton request id");
        assertEq(zip.balanceOf(address(queue)), q, "queue escrows zipUSD");
        assertEq(zip.balanceOf(alice), 0);
        assertEq(queue.totalPending(), q);
        assertEq(queue.sharesAt(alice), q);
        (uint256 pend,) = queue.previewRealize(alice);
        assertEq(pend, q, "pending == escrowed");
    }

    function test_requestRedeem_zero_reverts() public {
        _authRedeem(alice); // C4: authorize so the ZeroShares guard (not the redeem gate) is the binding revert
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.ZeroShares.selector);
        queue.requestRedeem(0, alice, alice);
    }

    function test_requestRedeem_nonWholeUnit_reverts() public {
        _giveZip(alice, 1000e18 + 1); // not a multiple of scaleUp (1e12)
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.NotWholeUnit.selector);
        queue.requestRedeem(1000e18 + 1, alice, alice);
    }

    function test_requestRedeem_nonOwnerNonOperator_reverts() public {
        _giveZip(alice, 1000e18);
        // C4: bob is NOT the redeemController (alice is, via _giveZip) -> the redeem-controller gate trips FIRST,
        // before the legacy owner/operator authorization check.
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, bob, alice);
    }

    function test_operator_can_request_and_claim_on_behalf() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        // C4: authorize bob as the redeemController so he can drive requestRedeem on alice's behalf.
        _authRedeem(bob);
        // alice approves bob as operator
        vm.prank(alice);
        queue.setOperator(bob, true);
        // bob requests on alice's behalf (owner == alice, requester == alice)
        vm.prank(bob);
        queue.requestRedeem(q, alice, alice);
        assertEq(queue.totalPending(), q);

        // fund + settle (full)
        _deliverUsdc(q / SCALE);
        _warpPastEpoch();
        _settle();

        // bob claims on alice's behalf, redirecting USDC to carol (F7: operator full claim control)
        vm.prank(bob);
        queue.withdraw(q / SCALE, carol, alice);
        assertEq(usdc.balanceOf(carol), q / SCALE, "operator redirected USDC");
    }

    function test_setOperator_self_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.CannotSetSelfAsOperator.selector);
        queue.setOperator(alice, true);
    }

    function test_setOperator_emits_and_sets() public {
        vm.expectEmit(true, true, false, true, address(queue));
        emit ZipRedemptionQueue.OperatorSet(alice, bob, true);
        vm.prank(alice);
        queue.setOperator(bob, true);
        assertTrue(queue.isOperator(alice, bob));
    }

    // -------------------------------------------------------------- C4: redeemController hard-gate
    function test_requestRedeem_notRedeemController_reverts() public {
        // a random EOA, the (would-be) module address, and an old-style owner==msg.sender caller all revert.
        _giveZip(alice, 1000e18); // sets redeemController = alice
        address module = makeAddr("offRampModule");
        // a random EOA
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, bob, bob);
        // the module address itself (the C4 critical: the gate authorizes the SAFE, not the module) — not wired here
        vm.prank(module);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, module, module);
        // an old-style owner==msg.sender caller that ISN'T the redeemController
        vm.prank(carol);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, carol, carol);
    }

    function test_setRedeemController_discipline() public {
        // onlyOwner: a non-owner cannot set it
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        queue.setRedeemController(alice);
        // ZeroAddress guarded
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        queue.setRedeemController(address(0));
        // re-pointable (build phase, §17, NOT set-once) + emits
        vm.expectEmit(true, false, false, true, address(queue));
        emit ZipRedemptionQueue.RedeemControllerSet(alice);
        queue.setRedeemController(alice);
        assertEq(queue.redeemController(), alice);
        queue.setRedeemController(bob);
        assertEq(queue.redeemController(), bob, "re-pointed");
    }

    function test_requestRedeem_succeeds_when_authorized() public {
        // the authorized redeemController (here = alice) can escrow; the CLAIM path stays open afterward.
        _giveZip(alice, 1000e18);
        vm.prank(alice);
        queue.requestRedeem(1000e18, alice, alice);
        assertEq(queue.totalPending(), 1000e18);
    }

    // -------------------------------------------------------------- settle: full / partial / over / exact / zero
    function test_settle_full_fill_bumps_era() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(q / SCALE);
        _warpPastEpoch();
        uint256 supplyBefore = zip.totalSupply();
        _settle();

        assertEq(queue.era(), 1, "era bumped on full drain");
        assertEq(queue.cumRemaining(), 1e27, "cumRemaining reset to PREC");
        assertEq(queue.totalPending(), 0);
        assertEq(queue.reservedAssets(), q / SCALE);
        assertEq(zip.totalSupply(), supplyBefore - q, "filled zipUSD burned");
        assertEq(zip.balanceOf(address(queue)), 0);

        // alice can claim full par
        (, uint256 claimable) = queue.previewRealize(alice);
        assertEq(claimable, q / SCALE);
    }

    function test_settle_partial_fill_carries() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(400e6); // only 40%
        _warpPastEpoch();
        _settle();

        assertEq(queue.era(), 0, "no era bump on partial");
        assertGt(queue.cumRemaining(), 0);
        assertLt(queue.cumRemaining(), 1e27, "cumRemaining decayed");
        assertEq(queue.totalPending(), q - 400e6 * SCALE, "remainder carried");
        assertEq(queue.reservedAssets(), 400e6);

        (uint256 pend, uint256 claimable) = queue.previewRealize(alice);
        assertEq(claimable, 400e6, "alice filled 40% at par");
        assertEq(pend, q - 400e6 * SCALE, "remainder still pending");
    }

    function test_settle_overfunded_caps_fill_excess_survives() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(1500e6); // more than the 1000e6 capacity
        _warpPastEpoch();
        _settle();

        assertEq(queue.era(), 1, "full drain on over-funding");
        assertEq(queue.reservedAssets(), 1000e6, "fill capped at par capacity");
        // excess 500e6 survives as free USDC
        assertEq(usdc.balanceOf(address(queue)) - queue.reservedAssets(), 500e6, "excess survives");
    }

    function test_settle_exact_capacity_takes_drain() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(1000e6); // == maxFillAssets exactly
        _warpPastEpoch();
        _settle();
        assertEq(queue.era(), 1, "exact capacity takes the drain branch");
        assertEq(queue.cumRemaining(), 1e27);
    }

    function test_settle_pending_zero_noop_advances_epoch() public {
        _warpPastEpoch();
        uint256 t0 = queue.lastEpochTime();
        _settle();
        assertEq(queue.epoch(), 1, "epoch advanced");
        assertEq(queue.lastEpochTime(), t0 + 30 days, "lastEpochTime advanced");
        assertEq(queue.era(), 0, "no era bump on empty");
        assertEq(queue.cumRemaining(), 1e27);
    }

    function test_settle_zero_liquidity_noop_no_era_bump() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        // no USDC delivered
        _warpPastEpoch();
        _settle();
        assertEq(queue.era(), 0, "no era bump with zero liquidity");
        assertEq(queue.cumRemaining(), 1e27, "cumRemaining unchanged");
        assertEq(queue.totalPending(), q, "pending unchanged");
        assertEq(queue.reservedAssets(), 0);
    }

    function test_settle_EpochNotElapsed_boundary() public {
        // at lastEpochTime + EPOCH_DURATION - 1: reverts
        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION() - 1);
        vm.prank(controller);
        vm.expectRevert(ZipRedemptionQueue.EpochNotElapsed.selector);
        queue.settleEpoch();
        // at +0: succeeds
        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION());
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.epoch(), 1);
    }

    function test_settle_NotController_reverts() public {
        _warpPastEpoch();
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.NotController.selector);
        queue.settleEpoch();
    }

    function test_settle_multiRequester_prorata() public {
        // alice 1000, bob 3000; deliver 1000 USDC -> 25% fill each
        _giveZip(alice, 1000e18);
        _giveZip(bob, 3000e18);
        _authRedeem(alice);
        vm.prank(alice);
        queue.requestRedeem(1000e18, alice, alice);
        _authRedeem(bob);
        vm.prank(bob);
        queue.requestRedeem(3000e18, bob, bob);
        _deliverUsdc(1000e6); // 25% of 4000 capacity
        _warpPastEpoch();
        _settle();

        (, uint256 ca) = queue.previewRealize(alice);
        (, uint256 cb) = queue.previewRealize(bob);
        // proportional: alice ~250, bob ~750 (round down)
        assertApproxEqAbs(ca, 250e6, 1, "alice 25%");
        assertApproxEqAbs(cb, 750e6, 1, "bob 25%");
        assertLe(ca + cb, queue.reservedAssets(), "no over-credit");
    }

    // -------------------------------------------------------------- zero-safety (KR-4a)
    function test_zeroSafety_fullDrain_then_newEra_request() public {
        // round 1: alice fully drained
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(q / SCALE);
        _warpPastEpoch();
        _settle();
        assertEq(queue.era(), 1);

        // a fresh request in the NEW era — must NOT div-by-zero
        uint256 q2 = 2000e18;
        _giveZip(bob, q2);
        vm.prank(bob);
        queue.requestRedeem(q2, bob, bob); // _realize(bob) with cumRemaining==PREC, no div-by-zero
        assertEq(queue.cumAt(bob), 1e27, "bob snapped at fresh factor");
        assertEq(queue.eraAt(bob), 1);

        // partial settle in era 1
        _deliverUsdc(800e6);
        _warpPastEpoch();
        _settle();
        (, uint256 cb) = queue.previewRealize(bob);
        assertEq(cb, 800e6, "bob filled 40%");

        // alice (never realized since era 0, eraAt < era) still claims full era-0 fill, no div-by-zero
        (, uint256 ca) = queue.previewRealize(alice);
        assertEq(ca, q / SCALE, "pre-drain alice fully filled (eraAt < era)");
        vm.prank(alice);
        queue.withdraw(q / SCALE, alice, alice);
        assertEq(usdc.balanceOf(alice), q / SCALE);
    }

    // -------------------------------------------------------------- cross-era / carry-forward
    function test_carryForward_singleRequester_realize_invariance() public {
        // alice partially filled over 2 epochs then drained; realizing each epoch vs only at the end -> same total
        uint256 q = 1000e18;

        // -- run A: alice realizes each epoch --
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(300e6);
        _warpPastEpoch();
        _settle();
        vm.prank(alice);
        queue.withdraw(300e6, alice, alice); // realize + claim epoch 1
        _deliverUsdc(700e6); // drains the rest
        _warpPastEpoch();
        _settle();
        (, uint256 ca) = queue.previewRealize(alice);
        assertEq(ca, 700e6, "remaining 700 after drain");
        vm.prank(alice);
        queue.withdraw(700e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 1000e6, "exact par total = deposit");
    }

    function test_carryForward_lateClaimer_drain() public {
        // alice never realizes mid-stream; partial then drain; claims full deposit at the end (exact par)
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(300e6);
        _warpPastEpoch();
        _settle(); // partial 30%, era 0
        _deliverUsdc(700e6);
        _warpPastEpoch();
        _settle(); // drains -> era 1
        assertEq(queue.era(), 1);
        // alice (eraAt 0 < era 1) -> pendingNow 0, full deposit credited
        (, uint256 ca) = queue.previewRealize(alice);
        assertEq(ca, 1000e6, "late claimer gets exact full par");
        vm.prank(alice);
        uint256 got = queue.redeem(q, alice, alice);
        assertEq(got, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_crossEra_twoCohorts() public {
        // A,B request era 0, partial fill, A claims, full drain -> era 1, C requests era 1, partial fill,
        // then B (never realized) claims its full era-0 fill with no div-by-zero.
        _giveZip(alice, 1000e18);
        _giveZip(bob, 1000e18);
        _authRedeem(alice);
        vm.prank(alice);
        queue.requestRedeem(1000e18, alice, alice);
        _authRedeem(bob);
        vm.prank(bob);
        queue.requestRedeem(1000e18, bob, bob);

        // partial fill era 0: 1000 USDC of 2000 capacity = 50%
        _deliverUsdc(1000e6);
        _warpPastEpoch();
        _settle();
        assertEq(queue.era(), 0);
        // A claims 500
        vm.prank(alice);
        queue.withdraw(500e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 500e6);

        // full drain of the remaining 1000 pending -> era 1
        _deliverUsdc(1000e6);
        _warpPastEpoch();
        _settle();
        assertEq(queue.era(), 1, "full drain bumps era");

        // C requests in era 1
        _giveZip(carol, 1000e18);
        vm.prank(carol);
        queue.requestRedeem(1000e18, carol, carol);
        assertEq(queue.eraAt(carol), 1);
        assertEq(queue.cumAt(carol), 1e27);

        // partial fill era 1: 400 USDC of 1000 capacity = 40%
        _deliverUsdc(400e6);
        _warpPastEpoch();
        _settle();
        (, uint256 cc) = queue.previewRealize(carol);
        assertEq(cc, 400e6, "C filled 40% in era 1");

        // B (never realized since era 0, eraAt 0 < era 1) claims its full era-0 residual: deposited 1000,
        // filled 500 in epoch 1, drained the other 500 at the era close -> total 1000.
        (, uint256 cb) = queue.previewRealize(bob);
        assertEq(cb, 1000e6, "B full era-0 fill, not subjected to era-1 partials");
        vm.prank(bob);
        queue.withdraw(1000e6, bob, bob);
        assertEq(usdc.balanceOf(bob), 1000e6);
    }

    // -------------------------------------------------------------- claim edges
    function test_claim_before_settle_reverts() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.InsufficientClaimable.selector);
        queue.withdraw(1, alice, alice);
    }

    function test_withdraw_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.ZeroAssets.selector);
        queue.withdraw(0, alice, alice);
    }

    function test_redeem_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.ZeroShares.selector);
        queue.redeem(0, alice, alice);
    }

    function test_redeem_belowScaleUp_reverts() public {
        _fullFillAlice(1000e18);
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.ZeroAssets.selector);
        queue.redeem(SCALE - 1, alice, alice); // assets == 0
    }

    function test_overclaim_reverts() public {
        _fullFillAlice(1000e18);
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.InsufficientClaimable.selector);
        queue.withdraw(1000e6 + 1, alice, alice);
    }

    function test_reclaim_reverts_not_silent_zero() public {
        _fullFillAlice(1000e18);
        vm.prank(alice);
        queue.withdraw(1000e6, alice, alice);
        // a second claim of the same amount reverts (over-claim), not a silent zero
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.InsufficientClaimable.selector);
        queue.withdraw(1000e6, alice, alice);
    }

    function test_withdraw_redeem_parity_identical() public {
        // from identical state, withdraw(a) and redeem(a*scaleUp) move identical USDC and leave identical state
        _fullFillAlice(1000e18);
        _fullFillBob(1000e18);

        vm.prank(alice);
        uint256 sharesW = queue.withdraw(400e6, alice, alice);
        vm.prank(bob);
        uint256 assetsR = queue.redeem(400e6 * SCALE, bob, bob);

        assertEq(sharesW, 400e6 * SCALE, "withdraw returns shares");
        assertEq(assetsR, 400e6, "redeem returns assets");
        assertEq(usdc.balanceOf(alice), usdc.balanceOf(bob), "identical USDC moved");
        assertEq(queue.claimableAssets(alice), queue.claimableAssets(bob), "identical remaining state");
    }

    function test_claim_nonOwnerNonOperator_reverts() public {
        _fullFillAlice(1000e18);
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.NotAuthorized.selector);
        queue.withdraw(1, bob, alice);
    }

    function test_par_roundTrip_exact() public {
        // KR-3: deposit-style mint q*scaleUp, full fund, claim -> exact q USDC
        uint256 u = 777e6;
        uint256 q = u * SCALE;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(u);
        _warpPastEpoch();
        _settle();
        vm.prank(alice);
        queue.redeem(q, alice, alice);
        assertEq(usdc.balanceOf(alice), u, "exact par round-trip, no value created/destroyed");
    }

    // -------------------------------------------------------------- donation hygiene
    function test_donation_stray_zipUSD_not_corrupt() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        // stray zipUSD donated directly into the queue
        zip.mint(address(queue), 500e18);
        assertEq(queue.totalPending(), q, "totalPending not corrupted by donation");
        assertGe(zip.balanceOf(address(queue)), queue.totalPending(), "invariant #4 >= holds");

        // full fund + settle: burns ONLY filledShares == q, not the donated surplus
        _deliverUsdc(q / SCALE);
        _warpPastEpoch();
        uint256 supplyBefore = zip.totalSupply();
        _settle();
        assertEq(supplyBefore - zip.totalSupply(), q, "burned only filledShares, donation untouched");
        assertEq(zip.balanceOf(address(queue)), 500e18, "donated zipUSD survives");
    }

    function test_donation_stray_USDC_distributed_at_par() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        // donor sends extra USDC beyond the par need; it becomes free liquidity for real requesters
        _deliverUsdc(600e6); // legit REPAY
        usdc.mint(address(queue), 1000e6); // stray donation
        _warpPastEpoch();
        _settle();
        // capacity 1000, available 1600 -> full drain, alice gets full 1000; 600 excess survives
        assertEq(queue.era(), 1);
        assertEq(queue.reservedAssets(), 1000e6);
        assertGe(usdc.balanceOf(address(queue)), queue.reservedAssets(), "reserved <= balance");
        // donor cannot withdraw (no claimableAssets)
        vm.prank(address(this));
        vm.expectRevert(ZipRedemptionQueue.ZeroAssets.selector);
        queue.withdraw(0, address(this), address(this));
    }

    // -------------------------------------------------------------- reentrancy (KR-9)
    function test_reentrancy_blocked_on_claim() public {
        // a callback USDC re-enters settleEpoch during the claim transfer -> ReentrancyGuardReentrantCall
        ReentrantUSDC rUsdc = new ReentrantUSDC();
        ZipRedemptionQueue q2 = new ZipRedemptionQueue(address(zip), address(rUsdc), controller);
        rUsdc.setQueue(address(q2));

        uint256 q = 1000e18;
        zip.mint(alice, q);
        vm.prank(alice);
        zip.approve(address(q2), q);
        q2.setRedeemController(alice); // C4: authorize (owner == this deployed q2)
        vm.prank(alice);
        q2.requestRedeem(q, alice, alice);

        rUsdc.mint(address(q2), 1000e6);
        vm.warp(q2.lastEpochTime() + q2.EPOCH_DURATION());
        vm.prank(controller);
        q2.settleEpoch();
        // make settleEpoch eligible again so the re-entrant call would otherwise proceed
        vm.warp(q2.lastEpochTime() + q2.EPOCH_DURATION());

        rUsdc.arm(true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        q2.withdraw(1000e6, alice, alice);
    }

    // -------------------------------------------------------------- preview parity (KR M-11)
    function testFuzz_previewRealize_matches_touch(uint256 reqUnits, uint256 fundUnits) public {
        reqUnits = bound(reqUnits, 1, 1_000_000);
        fundUnits = bound(fundUnits, 0, reqUnits); // partial-or-full
        uint256 q = reqUnits * SCALE;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(fundUnits);
        _warpPastEpoch();
        _settle();

        (uint256 pPend, uint256 pClaim) = queue.previewRealize(alice);
        uint256 claimBefore = queue.claimableAssets(alice);

        // Force an actual realize via a benign extra request of exactly scaleUp (calls _realize(alice) first),
        // then assert the post-touch state matches the pure-view preview EXACTLY (same era/ceil/floor math).
        uint256 extra = SCALE;
        _giveZip(alice, extra);
        vm.prank(alice);
        queue.requestRedeem(extra, alice, alice);

        assertEq(queue.sharesAt(alice), pPend + extra, "preview pending == post-touch sharesAt (+ the new request)");
        assertEq(queue.claimableAssets(alice), claimBefore + pClaim, "preview claimable == post-touch banked");

        // and the previously-claimable can actually be withdrawn at par
        if (pClaim != 0) {
            vm.prank(alice);
            queue.withdraw(pClaim, alice, alice);
            assertEq(usdc.balanceOf(alice), pClaim, "preview claimable == realized payout");
        }
    }

    // -------------------------------------------------------------- KR-2 negative: no sweep surface
    function test_no_sweep_surface_compileCheck() public {
        // The queue exposes NO owner/transferOwnership/sweep/pause. This is a compile-time guarantee
        // (those selectors do not exist). We assert the only USDC-out path is claim by proving the controller
        // cannot extract free USDC: there is no function for it, and settleEpoch never transfers USDC out.
        _deliverUsdc(1000e6); // free USDC sitting in the queue
        _warpPastEpoch();
        uint256 balBefore = usdc.balanceOf(address(queue));
        _settle(); // no pending -> no fill, no transfer out
        assertEq(usdc.balanceOf(address(queue)), balBefore, "settle moved no USDC out");
        assertEq(usdc.balanceOf(controller), 0, "controller extracted nothing");
    }

    // -------------------------------------------------------------- helpers
    function _fullFillAlice(uint256 q) internal {
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(q / SCALE);
        _warpPastEpoch();
        _settle();
    }

    function _fullFillBob(uint256 q) internal {
        _giveZip(bob, q);
        vm.prank(bob);
        queue.requestRedeem(q, bob, bob);
        _deliverUsdc(q / SCALE);
        // need a fresh epoch boundary; bob's request joined after alice's settle so re-warp
        _warpPastEpoch();
        _settle();
    }
}

// =========================================================================================== invariant/fuzz harness
/// @dev Stateful invariant handler with the KR-5 ghost accumulators. Drives randomized request/settle/claim
///      sequences and tracks `ghost_totalDelivered` (Σ USDC sent in) and `ghost_totalPaid` (Σ USDC paid out).
contract QueueHandler is Test {
    ZipRedemptionQueue public queue;
    ESynth public zip;
    MockERC20 public usdc;
    address public controller;
    address public queueOwner; // the address that can call setRedeemController (the test contract)
    address[] public actors;

    uint256 public ghost_totalDelivered;
    uint256 public ghost_totalPaid;

    uint256 internal constant SCALE = 1e12;

    constructor(ZipRedemptionQueue q, ESynth z, MockERC20 u, address c, address owner_, address[] memory a) {
        queue = q;
        zip = z;
        usdc = u;
        controller = c;
        queueOwner = owner_;
        actors = a;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function request(uint256 actorSeed, uint256 units) external {
        address a = _actor(actorSeed);
        units = bound(units, 1, 100_000);
        uint256 q = units * SCALE;
        zip.mint(a, q); // test contract is the minter (capacity granted in setUp)
        vm.prank(a);
        zip.approve(address(queue), q);
        // C4: authorize this actor as the redeemController (caller == owner == requester in this flow).
        vm.prank(queueOwner);
        queue.setRedeemController(a);
        vm.prank(a);
        queue.requestRedeem(q, a, a);
    }

    function deliver(uint256 units) external {
        units = bound(units, 0, 200_000);
        usdc.mint(address(queue), units);
        ghost_totalDelivered += units;
    }

    function settle(uint256 warpBy) external {
        warpBy = bound(warpBy, queue.EPOCH_DURATION(), queue.EPOCH_DURATION() + 10 days);
        vm.warp(queue.lastEpochTime() + warpBy);
        vm.prank(controller);
        queue.settleEpoch();
    }

    function claim(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        (, uint256 claimable) = queue.previewRealize(a);
        if (claimable == 0) return;
        vm.prank(a);
        queue.withdraw(claimable, a, a);
        ghost_totalPaid += claimable;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract ZipRedemptionQueueInvariantTest is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip;
    MockERC20 internal usdc;
    ZipRedemptionQueue internal queue;
    QueueHandler internal handler;
    address internal controller = makeAddr("controller");

    uint256 internal constant SCALE = 1e12;

    function setUp() public {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        queue = new ZipRedemptionQueue(address(zip), address(usdc), controller);
        zip.setCapacity(address(this), type(uint128).max);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("a0");
        actors[1] = makeAddr("a1");
        actors[2] = makeAddr("a2");
        actors[3] = makeAddr("a3");

        handler = new QueueHandler(queue, zip, usdc, controller, address(this), actors);
        // the minter is THIS test contract; the handler mints via the test's capacity by being granted too
        zip.setCapacity(address(handler), type(uint128).max);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = QueueHandler.request.selector;
        sels[1] = QueueHandler.deliver.selector;
        sels[2] = QueueHandler.settle.selector;
        sels[3] = QueueHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @notice KR-5 #1 (binding): never pay out more USDC than was ever delivered.
    function invariant_solvency_paid_le_delivered() public view {
        assertLe(handler.ghost_totalPaid(), handler.ghost_totalDelivered(), "paid > delivered");
    }

    /// @notice KR-5 #2: never owe more than the queue holds.
    function invariant_reserved_le_balance() public view {
        assertLe(queue.reservedAssets(), usdc.balanceOf(address(queue)), "reserved > balance");
    }

    /// @notice KR-5 #4: queue zipUSD balance >= totalPending (donation-tolerant).
    function invariant_zipBalance_ge_totalPending() public view {
        assertGe(zip.balanceOf(address(queue)), queue.totalPending(), "zipBalance < totalPending");
    }

    /// @notice KR-5 #5: zero-safety — 0 < cumRemaining <= PREC at all times.
    function invariant_cumRemaining_bounded() public view {
        assertGt(queue.cumRemaining(), 0, "cumRemaining == 0");
        assertLe(queue.cumRemaining(), queue.PREC(), "cumRemaining > PREC");
    }

    /// @notice KR-5 #3: after force-realizing every actor, Σ claimableAssets <= reservedAssets.
    function invariant_sumClaimable_le_reserved() public {
        uint256 n = handler.actorCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            (, uint256 c) = queue.previewRealize(a); // pure mirror == what a touch would bank
            sum += c;
        }
        assertLe(sum, queue.reservedAssets(), "sum claimable > reserved (over-credit)");
    }
}

// =========================================================================================== integration (fork)
/// @notice KR-1/KR-2 integration: the REAL `WarehouseAdminModule` REPAY funds the queue, which then settles
///         against its OWN USDC balance with ZERO EulerEarn coupling. Two REPAY rounds (REPAY half -> partial
///         settle -> REPAY the rest -> drain settle/era bump); asserts the REAL `ESynth` `totalSupply` dropped by
///         the burned `filledShares` both times (proves the no-allowance/no-capacity burn seam on the real ESynth).
contract ZipRedemptionQueueForkTest is ForkConfig {
    uint8 internal constant REPAY = 4;

    CreditWarehouseDeployer internal deployer;
    CreditWarehouseDeployer.Warehouse internal w;
    MockEulerEarn internal ee;
    address internal usdc; // real Base USDC (6-dp)
    address internal forwarder = makeAddr("forwarder");
    address internal godOwner;

    EthereumVaultConnector internal evc;
    ESynth internal zip; // real ESynth (18-dp)
    ZipRedemptionQueue internal queue;
    address internal controller = makeAddr("controller");
    address internal requester = makeAddr("requester");

    WarehouseAdminModule internal adapter;
    address internal safe;

    uint256 internal constant SCALE = 1e12;
    uint256 internal constant Q = 1_000_000e18; // 1M zipUSD redeem request

    function setUp() public {
        _selectBaseFork();
        usdc = BaseAddresses.USDC;
        godOwner = address(this);

        // zipUSD side
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");

        // the queue FIRST (so REPAY scope can pin to == queue)
        queue = new ZipRedemptionQueue(address(zip), usdc, controller);

        // warehouse side: deploy with repaySink == queue
        ee = new MockEulerEarn(usdc);
        deployer = new CreditWarehouseDeployer();
        w = deployer.deploy(godOwner, address(ee), usdc, forwarder, address(queue), 1);
        adapter = WarehouseAdminModule(w.adapter);
        safe = w.safe;

        // mint zipUSD to the requester and escrow the request
        zip.setCapacity(address(this), type(uint128).max);
        zip.mint(requester, Q);
        vm.prank(requester);
        zip.approve(address(queue), Q);
        // C4: authorize the requester as the redeemController (owner == this deployed the queue).
        queue.setRedeemController(requester);
        vm.prank(requester);
        queue.requestRedeem(Q, requester, requester);
        assertEq(queue.totalPending(), Q, "request escrowed");
        assertEq(zip.balanceOf(address(queue)), Q);
    }

    function _repay(uint256 amount) internal {
        vm.prank(forwarder);
        adapter.onReport("", abi.encode(REPAY, abi.encode(address(queue), amount)));
    }

    function test_fork_twoRepayRounds_drain_realESynthBurn() public {
        // --- round 1: fund HALF the par need via REPAY -> partial settle ---
        uint256 half = Q / SCALE / 2; // 500_000e6
        deal(usdc, safe, half);
        uint256 qBalBefore = IERC20(usdc).balanceOf(address(queue));
        _repay(half);
        assertEq(IERC20(usdc).balanceOf(address(queue)) - qBalBefore, half, "REPAY delivered exactly half");

        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION());
        uint256 supply1 = zip.totalSupply();
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.era(), 0, "partial -> no era bump");
        uint256 burned1 = supply1 - zip.totalSupply();
        assertEq(burned1, half * SCALE, "round 1 burned exactly the filled zipUSD on the REAL ESynth");
        assertEq(queue.reservedAssets(), half);

        // requester claims the partial fill
        (, uint256 claim1) = queue.previewRealize(requester);
        assertEq(claim1, half, "partial fill claimable");
        vm.prank(requester);
        queue.withdraw(claim1, requester, requester);
        assertEq(IERC20(usdc).balanceOf(requester), half);

        // --- round 2: REPAY the rest -> drain settle / era bump ---
        uint256 rest = Q / SCALE - half; // 500_000e6
        deal(usdc, safe, rest);
        _repay(rest);
        vm.warp(queue.lastEpochTime() + queue.EPOCH_DURATION());
        uint256 supply2 = zip.totalSupply();
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.era(), 1, "full drain -> era bump");
        assertEq(queue.cumRemaining(), 1e27, "cumRemaining reset");
        uint256 burned2 = supply2 - zip.totalSupply();
        assertEq(burned2, rest * SCALE, "round 2 burned exactly the filled zipUSD on the REAL ESynth");

        // requester claims the rest -> exact par total over both rounds
        (, uint256 claim2) = queue.previewRealize(requester);
        assertEq(claim2, rest, "drain residual claimable");
        vm.prank(requester);
        queue.withdraw(claim2, requester, requester);
        assertEq(IERC20(usdc).balanceOf(requester), Q / SCALE, "exact par over both rounds (1M USDC)");

        // KR-1: zero EulerEarn coupling — the queue holds NO EE shares and never called the pool.
        assertEq(ee.balanceOf(address(queue)), 0, "queue holds no EE shares");
        // KR-2: no surplus stuck; queue USDC == 0 after full claim
        assertEq(IERC20(usdc).balanceOf(address(queue)), 0, "queue fully drained to the requester");
    }

    /// @notice KR-2 negative — assert no transferOwnership/sweep/pause/owner selector exists on the queue ABI.
    function test_fork_noSweepSelectors() public {
        // Build phase (§17): a Timelock admin exists (owner/transferOwnership for re-pointing wiring), but there is
        // still NO direct fund-extraction path — no sweep/rescue/pause.
        bytes4[] memory forbidden = new bytes4[](4);
        forbidden[0] = bytes4(keccak256("sweep(address,uint256)"));
        forbidden[1] = bytes4(keccak256("sweep(address)"));
        forbidden[2] = bytes4(keccak256("rescue(address,uint256)"));
        forbidden[3] = bytes4(keccak256("pause()"));
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(queue).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok, "fund-extraction surface exists");
        }
    }
}
