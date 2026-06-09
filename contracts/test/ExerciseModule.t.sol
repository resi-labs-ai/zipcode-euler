// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

import {ExerciseModule} from "../src/supply/szipUSD/ExerciseModule.sol";
import {IOptionToken} from "../src/interfaces/hydrex/IOptionToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe (Zodiac avatar surface) — copied from `HarvestVoteModule.t.sol` / `ReservoirLoopModule.t.sol`.
///         Records every `(to, value, data, operation)`, optionally performs the call live, can force a specific exec
///         index to fail, and returns a settable `_returnData` from the NON-live path (the `paymentAmount` decode).
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
    bytes private _returnData; // returned from the NON-live recording path (the exercise paymentAmount decode)

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
            // Model the real Safe: catch the inner revert and RETURN (false, revertData), do NOT bubble.
            (ok, ret) = to.call{value: value}(data);
            return (ok, ret);
        }
        return (true, _returnData);
    }

    receive() external payable {}
}

/// @notice A minimal mintable ERC20 stand-in for USDC (the strike payment token) — supports the approve/transferFrom/
///         allowance/balanceOf the module + the MockOHYDX exercise pull need.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; // reverts on underflow (insufficient approval)
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice An oHYDX stand-in: settable `paymentToken()` (incl. address(0) to prove the setUp fail-closed),
///         `getDiscountedPrice`/`getMinPaymentAmount` (settable, to prove `quoteStrike` = max of the two), and an
///         `exercise(...)` that RECORDS its args, optionally reverts, and (on the live path) pulls `paymentReturn`
///         USDC from msg.sender + returns it.
contract MockOHYDX {
    address public paymentToken;
    uint256 public discounted;
    uint256 public floor;
    uint256 public paymentReturn;
    bool public revertOnExercise;

    // recorded exercise args
    uint256 public lastAmount;
    uint256 public lastMaxPayment;
    address public lastRecipient;
    uint256 public lastDeadline;

    error ExerciseBoom();

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setPaymentToken(address t) external {
        paymentToken = t;
    }

    function setDiscounted(uint256 v) external {
        discounted = v;
    }

    function setFloor(uint256 v) external {
        floor = v;
    }

    function setPaymentReturn(uint256 v) external {
        paymentReturn = v;
    }

    function setRevertOnExercise(bool v) external {
        revertOnExercise = v;
    }

    function getDiscountedPrice(uint256) external view returns (uint256) {
        return discounted;
    }

    function getMinPaymentAmount() external view returns (uint256) {
        return floor;
    }

    function exercise(uint256 amount, uint256 maxPayment, address recipient, uint256 deadline)
        external
        returns (uint256)
    {
        lastAmount = amount;
        lastMaxPayment = maxPayment;
        lastRecipient = recipient;
        lastDeadline = deadline;
        if (revertOnExercise) revert ExerciseBoom();
        // pull the strike from the caller (the Safe) — proves the approval path on the live recording Safe.
        IERC20(paymentToken).transferFrom(msg.sender, address(this), paymentReturn);
        return paymentReturn;
    }
}

// =========================================================================== unit tests (no fork)

contract ExerciseModuleUnitTest is Test {
    ExerciseModule internal m;
    RecordingSafe internal safe;
    MockOHYDX internal oToken;
    MockUSDC internal usdc;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    function setUp() public {
        usdc = new MockUSDC();
        oToken = new MockOHYDX(address(usdc));
        safe = new RecordingSafe();
        m = new ExerciseModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(oToken)));
    }

    // ----------------------------------------------------------------- setUp / authority / locks

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.engineSafe(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.oHYDX(), address(oToken));
        assertEq(m.paymentToken(), address(usdc)); // live-read off oHYDX.paymentToken()
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(abi.encode(owner, address(safe), operator, address(oToken)));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        ExerciseModule x = new ExerciseModule();
        vm.expectRevert(ExerciseModule.OwnerIsOperator.selector);
        x.setUp(abi.encode(owner, address(safe), owner, address(oToken)));
    }

    function test_setUp_rejects_zero_in_each_of_four() public {
        _expectZero(abi.encode(address(0), address(safe), operator, address(oToken))); // owner
        _expectZero(abi.encode(owner, address(0), operator, address(oToken))); // engineSafe
        _expectZero(abi.encode(owner, address(safe), address(0), address(oToken))); // operator
        _expectZero(abi.encode(owner, address(safe), operator, address(0))); // oHYDX
    }

    function _expectZero(bytes memory params) internal {
        ExerciseModule x = new ExerciseModule();
        vm.expectRevert(ExerciseModule.ZeroAddress.selector);
        x.setUp(params);
    }

    /// @dev The zero-oHYDX case asserts the order-guard fires (ZeroAddress) BEFORE a staticcall-to-zero paymentToken().
    function test_setUp_zero_oHYDX_is_ZeroAddress_not_staticcall() public {
        ExerciseModule x = new ExerciseModule();
        vm.expectRevert(ExerciseModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(0)));
    }

    function test_setUp_rejects_zero_paymentToken_live() public {
        MockOHYDX bad = new MockOHYDX(address(0)); // paymentToken() == 0
        ExerciseModule x = new ExerciseModule();
        vm.expectRevert(ExerciseModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(bad)));
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        ExerciseModule mc = new ExerciseModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.engineSafe(), address(0));
        assertEq(mc.oHYDX(), address(0));
        assertEq(mc.paymentToken(), address(0));
        vm.prank(operator);
        vm.expectRevert(ExerciseModule.NotOperator.selector);
        mc.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    function test_exercise_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(ExerciseModule.NotOperator.selector);
        m.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- guards

    function test_guards_zero_amount_and_zero_maxPayment() public {
        vm.startPrank(operator);
        vm.expectRevert(ExerciseModule.ZeroAmount.selector);
        m.exercise(0, 1e6, block.timestamp + 1 hours);
        vm.expectRevert(ExerciseModule.ZeroAmount.selector);
        m.exercise(1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- exec discipline (fully pinned)

    function test_exec_shape_fully_pinned() public {
        uint256 amount = 5e18;
        uint256 maxPayment = 12_000; // 0.012 USDC
        uint256 deadline = block.timestamp + 1 hours;
        uint256 payment = 10_556;
        safe.setReturnData(abi.encode(payment));

        vm.expectEmit(true, true, true, true, address(m));
        emit ExerciseModule.Exercised(amount, payment);
        vm.prank(operator);
        uint256 ret = m.exercise(amount, maxPayment, deadline);
        assertEq(ret, payment, "return value == paymentAmount");

        assertEq(safe.callCount(), 3, "exercise = 3 execs");
        // (1) approve(oHYDX, maxPayment)
        _assertCall(0, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, address(oToken), maxPayment));
        // (2) exercise(amount, maxPayment, engineSafe, deadline)
        _assertCall(
            1, address(oToken), abi.encodeCall(IOptionToken.exercise, (amount, maxPayment, address(safe), deadline))
        );
        // (3) approve(oHYDX, 0) — the reset
        _assertCall(2, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, address(oToken), uint256(0)));

        // decode ALL FOUR exercise args from getCall(1) — the recipient-pin + deadline/maxPayment pass-through firewall.
        (,, bytes memory data,) = safe.getCall(1);
        (uint256 a, uint256 mp, address recipient, uint256 dl) =
            abi.decode(_slice(data, 4), (uint256, uint256, address, uint256));
        assertEq(a, amount, "amount arg");
        assertEq(mp, maxPayment, "maxPayment arg");
        assertEq(recipient, address(safe), "exercise recipient == engineSafe");
        assertEq(dl, deadline, "deadline arg");

        // decode the reset-approve args (spender == oHYDX, amount == 0).
        (,, bytes memory resetData,) = safe.getCall(2);
        (address spender, uint256 resetAmt) = abi.decode(_slice(resetData, 4), (address, uint256));
        assertEq(spender, address(oToken), "reset spender == oHYDX");
        assertEq(resetAmt, 0, "reset amount == 0");
    }

    function test_exercise_reverts_on_short_return_data() public {
        safe.setReturnData(hex"00112233"); // < 32 bytes
        vm.prank(operator);
        vm.expectRevert();
        m.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    function test_exercise_reverts_on_empty_return_data() public {
        safe.setReturnData(hex"");
        vm.prank(operator);
        vm.expectRevert();
        m.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    /// @dev KR5 honesty guard: a misreporting oHYDX returning paymentAmount > maxPayment reverts PaymentExceedsMax
    ///      (isolated on the NON-live path so no transferFrom-underflow fires first).
    function test_exercise_reverts_paymentExceedsMax() public {
        uint256 maxPayment = 1e6;
        safe.setReturnData(abi.encode(maxPayment + 1));
        vm.prank(operator);
        vm.expectRevert(ExerciseModule.PaymentExceedsMax.selector);
        m.exercise(1e18, maxPayment, block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- atomicity (production bubble path)

    function test_exec_bubbles_custom_error() public {
        // live Safe + a MockOHYDX whose exercise reverts ExerciseBoom -> the bubble surfaces it.
        (ExerciseModule x, RecordingSafe lsafe, MockUSDC lusdc, MockOHYDX lo) = _liveRig();
        lusdc.mint(address(lsafe), 1e6);
        lo.setRevertOnExercise(true);
        vm.prank(operator);
        vm.expectRevert(MockOHYDX.ExerciseBoom.selector);
        x.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    function test_exec_bubbles_no_data_ExecFailed() public {
        // a target that reverts with empty data through a live Safe -> ExecFailed fallback. Point oHYDX at an
        // empty-reverting target. setUp needs paymentToken() to resolve, so use a MockOHYDX then swap behaviour via a
        // RevertEmpty wrapper as the oHYDX exercise target is not separable; instead, force the FIRST exec (approve) to
        // hit a token whose approve reverts empty.
        RecordingSafe lsafe = new RecordingSafe();
        lsafe.setLive(true);
        RevertEmptyToken bad = new RevertEmptyToken();
        MockOHYDX lo = new MockOHYDX(address(bad));
        ExerciseModule x = new ExerciseModule();
        x.setUp(abi.encode(owner, address(lsafe), operator, address(lo)));
        vm.prank(operator);
        vm.expectRevert(ExerciseModule.ExecFailed.selector);
        x.exercise(1e18, 1e6, block.timestamp + 1 hours);
    }

    /// @dev (e2) state-moving rollback: the exercise (exec #2) reverts -> the whole tx reverts atomically, so exec #1's
    ///      approve is rolled back and NO dangling allowance survives.
    function test_state_moving_rollback_no_dangling_approval() public {
        (ExerciseModule x, RecordingSafe lsafe, MockUSDC lusdc, MockOHYDX lo) = _liveRig();
        lusdc.mint(address(lsafe), 1e6);
        lo.setRevertOnExercise(true);
        vm.prank(operator);
        vm.expectRevert(MockOHYDX.ExerciseBoom.selector);
        x.exercise(1e18, 1e6, block.timestamp + 1 hours);
        assertEq(lusdc.allowance(address(lsafe), address(lo)), 0, "no dangling approval after rollback");
    }

    /// @dev (e3) state-moving happy path: the reset actually clears the residual `maxPayment - paymentAmount` on a
    ///      state-moving path (not just the calldata shape), and the strike USDC actually moves.
    function test_state_moving_happy_path_resets_allowance() public {
        (ExerciseModule x, RecordingSafe lsafe, MockUSDC lusdc, MockOHYDX lo) = _liveRig();
        uint256 maxPayment = 12_000;
        uint256 payment = 10_556;
        lusdc.mint(address(lsafe), 1e6);
        lo.setPaymentReturn(payment);

        uint256 balBefore = lusdc.balanceOf(address(lsafe));
        vm.prank(operator);
        uint256 ret = x.exercise(5e18, maxPayment, block.timestamp + 1 hours);

        assertEq(ret, payment, "return == paymentReturn");
        assertEq(lusdc.allowance(address(lsafe), address(lo)), 0, "residual allowance reset to 0");
        assertEq(balBefore - lusdc.balanceOf(address(lsafe)), payment, "exactly paymentAmount USDC pulled");
        assertEq(lo.lastRecipient(), address(lsafe), "recipient pinned to engineSafe on the live path");
    }

    // ----------------------------------------------------------------- view (quoteStrike = max)

    function test_quoteStrike_max_each_side_wins() public {
        oToken.setDiscounted(10_556);
        oToken.setFloor(10_000);
        assertEq(m.quoteStrike(1e18), 10_556, "discounted dominates");

        oToken.setDiscounted(5_000);
        oToken.setFloor(10_000);
        assertEq(m.quoteStrike(1e15), 10_000, "floor dominates");
    }

    function test_quoteStrike_floor_at_zero() public {
        oToken.setDiscounted(0);
        oToken.setFloor(10_000);
        assertEq(m.quoteStrike(0), 10_000, "floor dominates at amount==0");
    }

    function test_quoteStrike_tie() public {
        oToken.setDiscounted(10_000);
        oToken.setFloor(10_000);
        assertEq(m.quoteStrike(1e18), 10_000, "tie returns the common value");
    }

    // ----------------------------------------------------------------- helpers

    function _liveRig() internal returns (ExerciseModule x, RecordingSafe lsafe, MockUSDC lusdc, MockOHYDX lo) {
        lusdc = new MockUSDC();
        lo = new MockOHYDX(address(lusdc));
        lsafe = new RecordingSafe();
        lsafe.setLive(true);
        x = new ExerciseModule();
        x.setUp(abi.encode(owner, address(lsafe), operator, address(lo)));
    }

    function _assertCall(uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }
}

/// @notice A token whose `approve` reverts with EMPTY data (to exercise the `_exec` ExecFailed fallback).
contract RevertEmptyToken {
    function approve(address, uint256) external pure returns (bool) {
        assembly {
            revert(0, 0)
        }
    }

    // paymentToken() resolution at setUp: this IS the payment token, so the module reads ITS address as oHYDX's
    // paymentToken via MockOHYDX(address(this)). No paymentToken() needed here (MockOHYDX holds it).
}

// =========================================================================== fork tests (live Base)

/// @notice Fork tests against live Base: a real `oHYDX.exercise` against a real summoned substrate Safe seeded with
///         oHYDX + USDC, proving the burn / USDC-pull / HYDX-mint / paymentAmount return / allowance reset, plus a
///         signature-verification of the oHYDX surface and the maxPayment/deadline revert bubbles.
contract ExerciseModuleForkTest is ForkConfig, SummonSubstrate {
    address internal constant OHYDX_WHALE = 0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF; // holds 2334e18 oHYDX

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");

    uint256 internal constant SALT = uint256(keccak256("zipcode.exercise.8b8.salt.a"));

    function setUp() public {
        _selectBaseFork();
    }

    function _summonAndEnable(ExerciseModule m) internal returns (address mainSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        mainSafe = s.mainSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(mainSafe).execTransaction(mainSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _deploy() internal returns (ExerciseModule m, address engineSafe) {
        m = new ExerciseModule();
        engineSafe = _summonAndEnable(m);
        m.setUp(abi.encode(owner, engineSafe, operator, BaseAddresses.OHYDX));
    }

    function _fundOHYDX(address engineSafe, uint256 amount) internal {
        try this.tryDeal(BaseAddresses.OHYDX, engineSafe, amount) {
            if (IERC20(BaseAddresses.OHYDX).balanceOf(engineSafe) >= amount) return;
        } catch {}
        vm.prank(OHYDX_WHALE);
        IERC20(BaseAddresses.OHYDX).transfer(engineSafe, amount);
    }

    function tryDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    // ----------------------------------------------------------------- sig-verify

    function test_fork_sig_verify() public {
        (ExerciseModule m,) = _deploy();
        assertEq(m.oHYDX(), BaseAddresses.OHYDX, "oHYDX wired");
        assertEq(m.paymentToken(), BaseAddresses.USDC, "paymentToken live-read == USDC");

        // the strike surface resolves on the live oHYDX.
        IOptionToken o = IOptionToken(BaseAddresses.OHYDX);
        assertEq(o.paymentToken(), BaseAddresses.USDC, "oHYDX.paymentToken() == USDC");
        assertEq(o.discount(), 30, "discount() == 30");
        assertGt(o.getDiscountedPrice(1e18), 0, "getDiscountedPrice resolves");
        assertEq(o.getMinPaymentAmount(), 10_000, "getMinPaymentAmount() == $0.01");

        // the module view mirrors the contract's max(discounted, floor).
        uint256 q = m.quoteStrike(1e18);
        uint256 disc = o.getDiscountedPrice(1e18);
        uint256 floor = o.getMinPaymentAmount();
        assertEq(q, disc > floor ? disc : floor, "quoteStrike == max(discounted, floor)");
    }

    // ----------------------------------------------------------------- real exercise (the model)

    function test_fork_real_exercise() public {
        (ExerciseModule m, address engineSafe) = _deploy();

        uint256 amount = 10e18;
        _fundOHYDX(engineSafe, amount);
        uint256 quoteBefore = m.quoteStrike(amount); // read in the SAME block as the exercise below (no warp between)
        uint256 maxPayment = quoteBefore * 2; // generous cushion (8-B11 sizes it tight in prod)
        deal(BaseAddresses.USDC, engineSafe, maxPayment * 2); // ample USDC for the strike

        uint256 oBefore = IERC20(BaseAddresses.OHYDX).balanceOf(engineSafe);
        uint256 uBefore = IERC20(BaseAddresses.USDC).balanceOf(engineSafe);
        uint256 hBefore = IERC20(BaseAddresses.HYDX).balanceOf(engineSafe);

        vm.recordLogs();
        vm.prank(operator);
        uint256 paymentAmount = m.exercise(amount, maxPayment, block.timestamp + 1 hours);

        assertGt(paymentAmount, 0, "paymentAmount > 0");
        assertLe(paymentAmount, maxPayment, "paymentAmount <= maxPayment");
        // EVIDENCE for the self-quote question: does the view == the actual same-block charge?
        assertEq(paymentAmount, quoteBefore, "exercise charges exactly quoteStrike read in the same block");
        assertEq(oBefore - IERC20(BaseAddresses.OHYDX).balanceOf(engineSafe), amount, "exactly `amount` oHYDX burned");
        assertEq(uBefore - IERC20(BaseAddresses.USDC).balanceOf(engineSafe), paymentAmount, "exactly paymentAmount USDC paid");
        assertGt(IERC20(BaseAddresses.HYDX).balanceOf(engineSafe), hBefore, "HYDX minted to the Safe");
        assertEq(IERC20(BaseAddresses.USDC).allowance(engineSafe, BaseAddresses.OHYDX), 0, "approval reset to 0 (no standing approval)");

        // the Exercised event fired with the returned paymentAmount.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(m) && logs[i].topics[0] == ExerciseModule.Exercised.selector) {
                (uint256 amt, uint256 pay) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amt, amount, "event amount");
                assertEq(pay, paymentAmount, "event paymentAmount");
                found = true;
            }
        }
        assertTrue(found, "Exercised emitted");
    }

    // ----------------------------------------------------------------- maxPayment-too-low / deadline reverts

    function test_fork_maxPayment_too_low_reverts_state_unchanged() public {
        (ExerciseModule m, address engineSafe) = _deploy();
        uint256 amount = 10e18;
        _fundOHYDX(engineSafe, amount);
        deal(BaseAddresses.USDC, engineSafe, 1e6);

        IERC20 oToken = IERC20(BaseAddresses.OHYDX);
        IERC20 hydx = IERC20(BaseAddresses.HYDX);
        uint256 oBefore = oToken.balanceOf(engineSafe);
        uint256 hBefore = hydx.balanceOf(engineSafe);

        // maxPayment = 1 (far below the real strike) -> the oHYDX slippage guard reverts, bubbled through _exec.
        vm.prank(operator);
        vm.expectRevert();
        m.exercise(amount, 1, block.timestamp + 1 hours);

        // the atomic revert rolled back exec #1's approve -> no dangling approval, no partial burn/mint.
        assertEq(IERC20(BaseAddresses.USDC).allowance(engineSafe, BaseAddresses.OHYDX), 0, "no dangling approval");
        assertEq(oToken.balanceOf(engineSafe), oBefore, "no oHYDX burned");
        assertEq(hydx.balanceOf(engineSafe), hBefore, "no HYDX minted");
    }

    function test_fork_past_deadline_reverts() public {
        (ExerciseModule m, address engineSafe) = _deploy();
        uint256 amount = 10e18;
        _fundOHYDX(engineSafe, amount);
        uint256 maxPayment = m.quoteStrike(amount) * 2;
        deal(BaseAddresses.USDC, engineSafe, maxPayment * 2);

        vm.warp(block.timestamp + 100);
        vm.prank(operator);
        vm.expectRevert();
        m.exercise(amount, maxPayment, block.timestamp - 1);
    }
}
