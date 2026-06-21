// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "../ForkConfig.sol";
import {BaseAddresses} from "../../script/BaseAddresses.sol";
import {CreditWarehouseDeployer} from "../../script/CreditWarehouseDeployer.sol";
import {WarehouseAdminModule} from "../../src/supply/CreditWarehouse/WarehouseAdminModule.sol";
import {MockEulerEarn} from "../mocks/MockEulerEarn.sol";
import {ZipRedemptionQueue} from "../../src/supply/ZipRedemptionQueue.sol";
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
///      the claim path's `safeTransfer` out (KR-9).
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
///      to the requester. `scaleUp == 1e12`. Single-requester topology: `requestRedeem` is gated to one
///      `redeemController`; the unit flows wire it to the acting requester (caller == owner == requester).
abstract contract QueueBase is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip; // REAL ESynth = zipUSD (18-dp)
    MockERC20 internal usdc; // 6-dp
    ZipRedemptionQueue internal queue;

    address internal controller = makeAddr("controller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SCALE = 1e12;

    function _baseSetUp() internal {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        queue = new ZipRedemptionQueue(address(zip), address(usdc), controller);
        zip.setCapacity(address(this), type(uint128).max); // owner == this -> can mint zipUSD to the requester
    }

    /// @dev Mint `zipAmt` zipUSD to `to`, approve the queue, AND authorize `to` as the sole redeemController.
    function _giveZip(address to, uint256 zipAmt) internal {
        zip.mint(to, zipAmt);
        vm.prank(to);
        zip.approve(address(queue), zipAmt);
        queue.setRedeemController(to); // owner == this (deployed the queue)
    }

    /// @dev Authorize `c` as the redeemController (the sole `requestRedeem` caller). owner == this.
    function _authRedeem(address c) internal {
        queue.setRedeemController(c);
    }

    /// @dev Deliver `usdcAmt` USDC to the queue as if the warehouse REPAY transferred it in.
    function _deliverUsdc(uint256 usdcAmt) internal {
        usdc.mint(address(queue), usdcAmt);
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
        assertEq(queue.totalPending(), 0);
        assertEq(queue.reservedAssets(), 0);
        assertEq(queue.pendingRequester(), address(0));
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
        vm.expectEmit(true, true, false, true, address(queue));
        emit ZipRedemptionQueue.RedeemRequest(alice, alice, alice, q);
        vm.prank(alice);
        uint256 id = queue.requestRedeem(q, alice, alice);
        assertEq(id, 0, "singleton request id");
        assertEq(zip.balanceOf(address(queue)), q, "queue escrows zipUSD");
        assertEq(zip.balanceOf(alice), 0);
        assertEq(queue.totalPending(), q);
        assertEq(queue.pendingShares(alice), q);
        assertEq(queue.pendingRequester(), alice, "pendingRequester set");
        assertEq(queue.pendingRedeemRequest(0, alice), q, "pending == escrowed");
    }

    function test_requestRedeem_zero_reverts() public {
        _authRedeem(alice); // authorize so ZeroShares (not the redeem gate) is the binding revert
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

    function test_requestRedeem_ownerNotSender_reverts() public {
        // alice is the authorized redeemController, but tries to escrow bob's zipUSD (owner != msg.sender).
        _giveZip(alice, 1000e18);
        zip.mint(bob, 1000e18);
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.NotAuthorized.selector);
        queue.requestRedeem(1000e18, alice, bob);
    }

    // -------------------------------------------------------------- redeemController hard-gate
    function test_requestRedeem_notRedeemController_reverts() public {
        _giveZip(alice, 1000e18); // sets redeemController = alice
        address module = makeAddr("offRampModule");
        // a random EOA
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, bob, bob);
        // the module address itself (the gate authorizes the SAFE, not the module)
        vm.prank(module);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1000e18, module, module);
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

    // -------------------------------------------------------------- setTokens (auth + zero + DecimalsTooFew + scaleUp re-derive)
    /// @notice `setTokens` is `onlyOwner`, zero-guards both args, rejects USDC finer than zipUSD (`DecimalsTooFew`),
    ///         and RE-DERIVES `scaleUp` from the new tokens' `decimals()` — the par-scale source for every fill. Proven
    ///         live: after re-pointing to an 8-dp/6-dp pair, `scaleUp == 100` and the whole-unit guard uses it.
    function test_setTokens_guards_and_scaleUp_rederive() public {
        // onlyOwner
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        queue.setTokens(address(zip), address(usdc));
        // zero-guards (both args)
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        queue.setTokens(address(0), address(usdc));
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        queue.setTokens(address(zip), address(0));
        // DecimalsTooFew: USDC finer than zipUSD
        MockERC20 fatUsdc = new MockERC20(24);
        vm.expectRevert(ZipRedemptionQueue.DecimalsTooFew.selector);
        queue.setTokens(address(zip), address(fatUsdc));

        // effect: re-point to an 8-dp zip / 6-dp usdc pair -> scaleUp re-derived to 10**2, emits TokensSet
        MockERC20 zip8 = new MockERC20(8);
        MockERC20 usdc6 = new MockERC20(6);
        vm.expectEmit(true, true, false, false, address(queue));
        emit ZipRedemptionQueue.TokensSet(address(zip8), address(usdc6));
        queue.setTokens(address(zip8), address(usdc6));
        assertEq(queue.zipUSD(), address(zip8), "zipUSD re-pointed");
        assertEq(queue.usdc(), address(usdc6), "usdc re-pointed");
        assertEq(queue.scaleUp(), 100, "scaleUp re-derived to 10**(8-6), NOT the stale 1e12");

        // the re-derived scale is LIVE: the whole-unit guard now floors at 100, not 1e12.
        queue.setRedeemController(alice);
        zip8.mint(alice, 1000);
        vm.prank(alice);
        zip8.approve(address(queue), 1000);
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.NotWholeUnit.selector);
        queue.requestRedeem(150, alice, alice); // 150 % 100 != 0
        vm.prank(alice);
        queue.requestRedeem(200, alice, alice); // exact multiple of the new scaleUp
        assertEq(queue.totalPending(), 200, "escrowed at the re-derived scale");
        assertEq(zip8.balanceOf(address(queue)), 200);
    }

    // -------------------------------------------------------------- setController (auth + zero + effect)
    /// @notice `setController` is `onlyOwner`, zero-guarded, and re-points the sole `settleEpoch` caller: after the
    ///         re-point the NEW controller settles and the OLD one reverts `NotController`.
    function test_setController_guards_and_effect() public {
        // onlyOwner
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        queue.setController(alice);
        // zero-guard
        vm.expectRevert(ZipRedemptionQueue.ZeroAddress.selector);
        queue.setController(address(0));
        // effect + emit
        address newController = makeAddr("newController");
        vm.expectEmit(true, false, false, false, address(queue));
        emit ZipRedemptionQueue.ControllerSet(newController);
        queue.setController(newController);
        assertEq(queue.controller(), newController, "controller re-pointed");
        // the OLD controller can no longer settle
        vm.prank(controller);
        vm.expectRevert(ZipRedemptionQueue.NotController.selector);
        queue.settleEpoch();
        // the NEW controller can (no pending -> clean no-op, no revert)
        vm.prank(newController);
        queue.settleEpoch();
    }

    function test_requestRedeem_succeeds_when_authorized() public {
        _giveZip(alice, 1000e18);
        vm.prank(alice);
        queue.requestRedeem(1000e18, alice, alice);
        assertEq(queue.totalPending(), 1000e18);
    }

    // -------------------------------------------------------------- single-requester invariant
    function test_requestRedeem_secondRequester_reverts() public {
        // alice opens pending; switching the redeemController to bob and requesting reverts MultipleRequesters
        // (the single-requester topology — one open requester until the pending drains).
        _giveZip(alice, 1000e18);
        vm.prank(alice);
        queue.requestRedeem(1000e18, alice, alice);

        _giveZip(bob, 3000e18);
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.MultipleRequesters.selector);
        queue.requestRedeem(3000e18, bob, bob);
    }

    function test_requestRedeem_newRequester_ok_afterDrain() public {
        // after alice fully drains, pendingRequester clears and a new requester may open.
        _fullFillAlice(1000e18);
        assertEq(queue.pendingRequester(), address(0), "cleared on full drain");
        _giveZip(bob, 2000e18);
        vm.prank(bob);
        queue.requestRedeem(2000e18, bob, bob);
        assertEq(queue.pendingRequester(), bob, "new requester after drain");
    }

    // -------------------------------------------------------------- settle: full / partial / over / exact / zero
    function test_settle_full_fill() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(q / SCALE);
        uint256 supplyBefore = zip.totalSupply();
        _settle();

        assertEq(queue.totalPending(), 0, "fully filled");
        assertEq(queue.pendingRequester(), address(0), "requester cleared");
        assertEq(queue.reservedAssets(), q / SCALE);
        assertEq(zip.totalSupply(), supplyBefore - q, "filled zipUSD burned");
        assertEq(zip.balanceOf(address(queue)), 0);
        assertEq(queue.claimableAssets(alice), q / SCALE, "full par claimable");
    }

    function test_settle_partial_fill_carries() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(400e6); // only 40%
        _settle();

        assertEq(queue.totalPending(), q - 400e6 * SCALE, "remainder carried");
        assertEq(queue.pendingRequester(), alice, "requester still open");
        assertEq(queue.reservedAssets(), 400e6);
        assertEq(queue.claimableAssets(alice), 400e6, "alice filled 40% at par");
        assertEq(queue.pendingShares(alice), q - 400e6 * SCALE, "remainder still pending");
    }

    function test_settle_overfunded_caps_fill_excess_survives() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(1500e6); // more than the 1000e6 capacity
        _settle();

        assertEq(queue.totalPending(), 0, "fully drained");
        assertEq(queue.reservedAssets(), 1000e6, "fill capped at par capacity");
        // excess 500e6 survives as free USDC
        assertEq(usdc.balanceOf(address(queue)) - queue.reservedAssets(), 500e6, "excess survives");
    }

    function test_settle_exact_capacity_drains() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(1000e6); // == maxFillAssets exactly
        _settle();
        assertEq(queue.totalPending(), 0, "exact capacity drains");
        assertEq(queue.reservedAssets(), 1000e6);
    }

    function test_settle_pending_zero_noop() public {
        // no pending, no USDC: settle is a clean no-op (no revert).
        _settle();
        assertEq(queue.totalPending(), 0);
        assertEq(queue.reservedAssets(), 0);
    }

    function test_settle_zero_liquidity_noop() public {
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        // no USDC delivered
        _settle();
        assertEq(queue.totalPending(), q, "pending unchanged");
        assertEq(queue.reservedAssets(), 0);
        assertEq(queue.claimableAssets(alice), 0);
    }

    function test_settle_onDemand_noTimeGate() public {
        // The controller can settle immediately and again back-to-back; non-controller reverts NotController.
        vm.expectRevert(ZipRedemptionQueue.NotController.selector);
        queue.settleEpoch();

        vm.prank(controller);
        queue.settleEpoch();
        vm.prank(controller);
        queue.settleEpoch(); // second settle in the same block — no time gate
    }

    function test_settle_NotController_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.NotController.selector);
        queue.settleEpoch();
    }

    // -------------------------------------------------------------- carry-forward (single requester, multi-epoch)
    function test_carryForward_partial_then_drain_exact_par() public {
        // alice partially filled over 2 epochs then drained; total claimed == exact par deposit.
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);

        _deliverUsdc(300e6);
        _settle();
        vm.prank(alice);
        queue.withdraw(300e6, alice, alice); // claim epoch 1

        _deliverUsdc(700e6); // drains the rest
        _settle();
        assertEq(queue.totalPending(), 0, "drained");
        assertEq(queue.claimableAssets(alice), 700e6, "remaining 700 after drain");
        vm.prank(alice);
        queue.withdraw(700e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 1000e6, "exact par total = deposit");
    }

    function test_carryForward_lateClaimer_drain() public {
        // alice never claims mid-stream; partial then drain; claims full deposit at the end (exact par).
        uint256 q = 1000e18;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(300e6);
        _settle(); // partial 30%
        _deliverUsdc(700e6);
        _settle(); // drains
        assertEq(queue.totalPending(), 0);
        assertEq(queue.claimableAssets(alice), 1000e6, "late claimer gets exact full par");
        vm.prank(alice);
        uint256 got = queue.redeem(q, alice, alice);
        assertEq(got, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
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
        vm.prank(alice);
        vm.expectRevert(ZipRedemptionQueue.InsufficientClaimable.selector);
        queue.withdraw(1000e6, alice, alice);
    }

    function test_withdraw_redeem_parity_identical() public {
        // withdraw(a) and redeem(a*scaleUp) move identical USDC and leave identical state. Run sequentially so the
        // single-requester invariant holds (alice fully drains before bob opens).
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

    function test_claim_nonRequester_reverts() public {
        _fullFillAlice(1000e18);
        vm.prank(bob);
        vm.expectRevert(ZipRedemptionQueue.NotAuthorized.selector);
        queue.withdraw(1, bob, alice);
    }

    function test_par_roundTrip_exact() public {
        // KR-3: mint q*scaleUp, full fund, claim -> exact q USDC.
        uint256 u = 777e6;
        uint256 q = u * SCALE;
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(u);
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
        zip.mint(address(queue), 500e18); // stray zipUSD donated directly
        assertEq(queue.totalPending(), q, "totalPending not corrupted by donation");
        assertGe(zip.balanceOf(address(queue)), queue.totalPending(), "invariant #4 >= holds");

        _deliverUsdc(q / SCALE);
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
        _deliverUsdc(600e6); // legit REPAY
        usdc.mint(address(queue), 1000e6); // stray donation
        _settle();
        // capacity 1000, available 1600 -> full drain, alice gets full 1000; 600 excess survives
        assertEq(queue.totalPending(), 0);
        assertEq(queue.reservedAssets(), 1000e6);
        assertGe(usdc.balanceOf(address(queue)), queue.reservedAssets(), "reserved <= balance");
        // a non-requester cannot withdraw (no claimableAssets)
        vm.prank(address(this));
        vm.expectRevert(ZipRedemptionQueue.ZeroAssets.selector);
        queue.withdraw(0, address(this), address(this));
    }

    // -------------------------------------------------------------- reentrancy (KR-9)
    function test_reentrancy_blocked_on_claim() public {
        ReentrantUSDC rUsdc = new ReentrantUSDC();
        ZipRedemptionQueue q2 = new ZipRedemptionQueue(address(zip), address(rUsdc), controller);
        rUsdc.setQueue(address(q2));

        uint256 q = 1000e18;
        zip.mint(alice, q);
        vm.prank(alice);
        zip.approve(address(q2), q);
        q2.setRedeemController(alice);
        vm.prank(alice);
        q2.requestRedeem(q, alice, alice);

        rUsdc.mint(address(q2), 1000e6);
        vm.prank(controller);
        q2.settleEpoch();

        rUsdc.arm(true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        q2.withdraw(1000e6, alice, alice);
    }

    // -------------------------------------------------------------- KR-2: no sweep surface
    function test_no_sweep_surface() public {
        // The only USDC-out path is a claim: prove the controller cannot extract free USDC — settleEpoch never
        // transfers USDC out, and there is no sweep/rescue/pause function.
        _deliverUsdc(1000e6); // free USDC sitting in the queue
        uint256 balBefore = usdc.balanceOf(address(queue));
        _settle(); // no pending -> no fill, no transfer out
        assertEq(usdc.balanceOf(address(queue)), balBefore, "settle moved no USDC out");
        assertEq(usdc.balanceOf(controller), 0, "controller extracted nothing");
    }

    // -------------------------------------------------------------- SEC-12: redeem emits canonical shares
    function test_SEC12_redeem_subUnitExcess_emits_canonical_shares() public {
        // Fund alice with exactly 1 unit (1 USDC) of par-claimable. A sub-unit-excess redeem (1.5 * scaleUp) pays
        // assets == 1 but must emit the canonical shares == assets*scaleUp (== scaleUp), NOT the raw 1.5*scaleUp.
        _fullFillAlice(SCALE); // 1 zipUSD escrowed/filled -> claimableAssets[alice] == 1 USDC
        assertEq(queue.claimableAssets(alice), 1, "alice has 1 USDC claimable");

        uint256 rawInput = SCALE + SCALE / 2; // sub-unit excess
        vm.expectEmit(true, true, true, true, address(queue));
        emit ZipRedemptionQueue.Withdraw(alice, alice, alice, 1, SCALE); // assets==1, shares==scaleUp (canonical)
        vm.prank(alice);
        uint256 assets = queue.redeem(rawInput, alice, alice);
        assertEq(assets, 1, "floored par payout");
        assertEq(usdc.balanceOf(alice), 1, "exactly 1 USDC paid");
    }

    function test_SEC12_redeem_cleanMultiple_emits_unchanged() public {
        // Clean multiple: redeem(k*scaleUp) emits shares == k*scaleUp (recompute is a no-op for exact inputs).
        uint256 k = 400e6;
        _fullFillAlice(1000e18);
        vm.expectEmit(true, true, true, true, address(queue));
        emit ZipRedemptionQueue.Withdraw(alice, alice, alice, k, k * SCALE);
        vm.prank(alice);
        queue.redeem(k * SCALE, alice, alice);
    }

    function test_SEC12_redeem_returnValue_unchanged() public {
        // Return value stays `assets` (shares / scaleUp), unchanged by the event recompute.
        _fullFillAlice(1000e18);
        vm.prank(alice);
        uint256 assets = queue.redeem(400e6 * SCALE, alice, alice);
        assertEq(assets, 400e6, "redeem still returns assets unchanged");
    }

    // -------------------------------------------------------------- helpers
    function _fullFillAlice(uint256 q) internal {
        _giveZip(alice, q);
        vm.prank(alice);
        queue.requestRedeem(q, alice, alice);
        _deliverUsdc(q / SCALE);
        _settle();
    }

    function _fullFillBob(uint256 q) internal {
        _giveZip(bob, q);
        vm.prank(bob);
        queue.requestRedeem(q, bob, bob);
        _deliverUsdc(q / SCALE);
        _settle();
    }
}

// =========================================================================================== invariant/fuzz harness
/// @dev Stateful invariant handler with the KR-5 ghost accumulators. Drives randomized request/settle/claim
///      sequences against the SINGLE requester (single-requester topology) and tracks `ghost_totalDelivered`
///      (Σ USDC sent in) and `ghost_totalPaid` (Σ USDC paid out).
contract QueueHandler is Test {
    ZipRedemptionQueue public queue;
    ESynth public zip;
    MockERC20 public usdc;
    address public controller;
    address public requester; // the single redeemController/requester

    uint256 public ghost_totalDelivered;
    uint256 public ghost_totalPaid;

    uint256 internal constant SCALE = 1e12;

    constructor(ZipRedemptionQueue q, ESynth z, MockERC20 u, address c, address requester_) {
        queue = q;
        zip = z;
        usdc = u;
        controller = c;
        requester = requester_;
    }

    function request(uint256 units) external {
        units = bound(units, 1, 100_000);
        uint256 q = units * SCALE;
        zip.mint(requester, q);
        vm.prank(requester);
        zip.approve(address(queue), q);
        vm.prank(requester);
        queue.requestRedeem(q, requester, requester);
    }

    function deliver(uint256 units) external {
        units = bound(units, 0, 200_000);
        usdc.mint(address(queue), units);
        ghost_totalDelivered += units;
    }

    function settle(uint256) external {
        vm.prank(controller);
        queue.settleEpoch();
    }

    function claim() external {
        uint256 claimable = queue.claimableAssets(requester);
        if (claimable == 0) return;
        vm.prank(requester);
        queue.withdraw(claimable, requester, requester);
        ghost_totalPaid += claimable;
    }
}

contract ZipRedemptionQueueInvariantTest is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip;
    MockERC20 internal usdc;
    ZipRedemptionQueue internal queue;
    QueueHandler internal handler;
    address internal controller = makeAddr("controller");
    address internal requester = makeAddr("requester");

    function setUp() public {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        queue = new ZipRedemptionQueue(address(zip), address(usdc), controller);
        zip.setCapacity(address(this), type(uint128).max);
        queue.setRedeemController(requester);

        handler = new QueueHandler(queue, zip, usdc, controller, requester);
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

    /// @notice KR-5 #3: the requester's claimable never exceeds the reserved book.
    function invariant_claimable_le_reserved() public view {
        assertLe(queue.claimableAssets(requester), queue.reservedAssets(), "claimable > reserved (over-credit)");
    }
}

// =========================================================================================== integration (fork)
/// @notice KR-1/KR-2 integration: the REAL `WarehouseAdminModule` REPAY funds the queue, which then settles
///         against its OWN USDC balance with ZERO EulerEarn coupling. Two REPAY rounds (REPAY half -> partial
///         settle -> REPAY the rest -> drain settle); asserts the REAL `ESynth` `totalSupply` dropped by the
///         burned `filledShares` both times (proves the no-allowance/no-capacity burn seam on the real ESynth).
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

        // warehouse side: deploy with redemptionBox == queue
        ee = new MockEulerEarn(usdc);
        deployer = new CreditWarehouseDeployer();
        w = deployer.deploy(godOwner, godOwner, address(ee), usdc, forwarder, address(queue), 1);
        adapter = WarehouseAdminModule(w.adapter);
        safe = w.warehouseSafe;

        // mint zipUSD to the requester and escrow the request
        zip.setCapacity(address(this), type(uint128).max);
        zip.mint(requester, Q);
        vm.prank(requester);
        zip.approve(address(queue), Q);
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

        uint256 supply1 = zip.totalSupply();
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.totalPending(), Q - half * SCALE, "partial -> remainder pending");
        uint256 burned1 = supply1 - zip.totalSupply();
        assertEq(burned1, half * SCALE, "round 1 burned exactly the filled zipUSD on the REAL ESynth");
        assertEq(queue.reservedAssets(), half);

        // requester claims the partial fill
        assertEq(queue.claimableAssets(requester), half, "partial fill claimable");
        vm.prank(requester);
        queue.withdraw(half, requester, requester);
        assertEq(IERC20(usdc).balanceOf(requester), half);

        // --- round 2: REPAY the rest -> drain settle ---
        uint256 rest = Q / SCALE - half; // 500_000e6
        deal(usdc, safe, rest);
        _repay(rest);
        uint256 supply2 = zip.totalSupply();
        vm.prank(controller);
        queue.settleEpoch();
        assertEq(queue.totalPending(), 0, "full drain");
        assertEq(queue.pendingRequester(), address(0), "requester cleared on drain");
        uint256 burned2 = supply2 - zip.totalSupply();
        assertEq(burned2, rest * SCALE, "round 2 burned exactly the filled zipUSD on the REAL ESynth");

        // requester claims the rest -> exact par total over both rounds
        assertEq(queue.claimableAssets(requester), rest, "drain residual claimable");
        vm.prank(requester);
        queue.withdraw(rest, requester, requester);
        assertEq(IERC20(usdc).balanceOf(requester), Q / SCALE, "exact par over both rounds (1M USDC)");

        // KR-1: zero EulerEarn coupling — the queue holds NO EE shares and never called the pool.
        assertEq(ee.balanceOf(address(queue)), 0, "queue holds no EE shares");
        // KR-2: no surplus stuck; queue USDC == 0 after full claim
        assertEq(IERC20(usdc).balanceOf(address(queue)), 0, "queue fully drained to the requester");
    }

    /// @notice KR-2 negative — assert no sweep/rescue/pause selector exists on the queue ABI.
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
