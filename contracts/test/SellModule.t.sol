// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

import {SellModule} from "../src/supply/szipUSD/SellModule.sol";
import {ISwapRouter} from "../src/interfaces/algebra/ISwapRouter.sol";
import {IAlgebraPool} from "../src/interfaces/algebra/IAlgebraPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe (Zodiac avatar surface) — copied verbatim from `ExerciseModule.t.sol`.
///         Records every `(to, value, data, operation)`, optionally performs the call live, can force a specific exec
///         index to fail, and returns a settable `_returnData` from the NON-live path (the `amountOut` decode).
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
    bytes private _returnData; // returned from the NON-live recording path (the swap amountOut decode)

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

/// @notice A minimal mintable ERC20 stand-in (the wired `tokenIn`) — supports approve/transferFrom/allowance/balanceOf
///         the module + the MockSwapRouter pull need.
contract MockERC20 {
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

/// @notice The Algebra `SwapRouter` stand-in (the `_exec` target): an `exactInputSingle(params)` that RECORDS the full
///         `ExactInputSingleParams` struct it received (so the test can assert every field via struct-decode, not a
///         keccak match), pulls `amountIn` `tokenIn` from msg.sender on the live path, and returns a settable
///         `amountOut`. A settable short-return + revert flag exercise the malformed-return + atomicity paths.
contract MockSwapRouter {
    ISwapRouter.ExactInputSingleParams public last;
    bool public didRecord;
    uint256 public amountOutReturn;
    bool public shortReturn; // return < 32 bytes
    bool public revertOnSwap;

    error SwapBoom();

    function setAmountOut(uint256 v) external {
        amountOutReturn = v;
    }

    function setShortReturn(bool v) external {
        shortReturn = v;
    }

    function setRevertOnSwap(bool v) external {
        revertOnSwap = v;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256)
    {
        last = params;
        didRecord = true;
        if (revertOnSwap) revert SwapBoom();
        // pull amountIn tokenIn from the caller (the Safe) — proves the approval path on the live recording Safe.
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        if (shortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 4) // < 32 bytes
            }
        }
        return amountOutReturn;
    }
}

// =========================================================================== unit tests (no fork)

contract SellModuleUnitTest is Test {
    SellModule internal m;
    RecordingSafe internal safe;
    MockSwapRouter internal router;
    MockERC20 internal hydx;
    MockERC20 internal usdc;
    MockERC20 internal zipUSD;
    MockERC20 internal xAlpha;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    /// @dev The governed per-call HYDX size ceiling (the deploy default — 300k HYDX ≈ ~3% slippage ≈ ~$10k).
    uint256 internal constant MAX_SELL = 300_000e18;

    function setUp() public {
        router = new MockSwapRouter();
        hydx = new MockERC20();
        usdc = new MockERC20();
        zipUSD = new MockERC20();
        xAlpha = new MockERC20();
        safe = new RecordingSafe();
        m = new SellModule();
        m.setUp(_params(owner, address(safe), operator));
    }

    function _params(address owner_, address safe_, address operator_) internal view returns (bytes memory) {
        return abi.encode(
            owner_,
            safe_,
            operator_,
            address(router),
            address(hydx),
            address(usdc),
            address(zipUSD),
            address(xAlpha),
            MAX_SELL
        );
    }

    // ----------------------------------------------------------------- setUp / authority / locks

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.engineSafe(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.swapRouter(), address(router));
        assertEq(m.hydx(), address(hydx));
        assertEq(m.usdc(), address(usdc));
        assertEq(m.zipUSD(), address(zipUSD));
        assertEq(m.xAlpha(), address(xAlpha));
        assertEq(m.maxSellHydx(), MAX_SELL);
    }

    /// @dev (qa iii) every one of the 7 wired getters returns its wired address after setUp.
    function test_getters() public view {
        assertEq(m.engineSafe(), address(safe), "engineSafe getter");
        assertEq(m.operator(), operator, "operator getter");
        assertEq(m.swapRouter(), address(router), "swapRouter getter");
        assertEq(m.hydx(), address(hydx), "hydx getter");
        assertEq(m.usdc(), address(usdc), "usdc getter");
        assertEq(m.zipUSD(), address(zipUSD), "zipUSD getter");
        assertEq(m.xAlpha(), address(xAlpha), "xAlpha getter");
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(_params(owner, address(safe), operator));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        SellModule x = new SellModule();
        vm.expectRevert(SellModule.OwnerIsOperator.selector);
        x.setUp(_params(owner, address(safe), owner));
    }

    /// @dev (qa iv) enumerate the 8 zero-address setUp reverts (one per address). For the swapRouter==0 case assert the
    ///      selector is SellModule.ZeroAddress specifically (the order-guard fires before any use).
    function test_setUp_rejects_zero_in_each_of_eight() public {
        _expectZero(abi.encode(address(0), address(safe), operator, address(router), address(hydx), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL)); // owner
        _expectZero(abi.encode(owner, address(0), operator, address(router), address(hydx), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL)); // engineSafe
        _expectZero(abi.encode(owner, address(safe), address(0), address(router), address(hydx), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL)); // operator
        _expectZero(abi.encode(owner, address(safe), operator, address(0), address(hydx), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL)); // swapRouter
        _expectZero(abi.encode(owner, address(safe), operator, address(router), address(0), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL)); // hydx
        _expectZero(abi.encode(owner, address(safe), operator, address(router), address(hydx), address(0), address(zipUSD), address(xAlpha), MAX_SELL)); // usdc
        _expectZero(abi.encode(owner, address(safe), operator, address(router), address(hydx), address(usdc), address(0), address(xAlpha), MAX_SELL)); // zipUSD
        _expectZero(abi.encode(owner, address(safe), operator, address(router), address(hydx), address(usdc), address(zipUSD), address(0), MAX_SELL)); // xAlpha
    }

    function _expectZero(bytes memory params) internal {
        SellModule x = new SellModule();
        vm.expectRevert(SellModule.ZeroAddress.selector);
        x.setUp(params);
    }

    /// @dev (qa iv) the swapRouter==0 case asserts the order-guard fires (ZeroAddress) specifically.
    function test_setUp_zero_swapRouter_is_ZeroAddress() public {
        SellModule x = new SellModule();
        vm.expectRevert(SellModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(0), address(hydx), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL));
    }

    /// @dev (cap) setUp rejects a zero `maxSellHydx` (a zero cap would brick `sellHydx`).
    function test_setUp_rejects_zero_maxSellHydx() public {
        SellModule x = new SellModule();
        vm.expectRevert(SellModule.ZeroAmount.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(router), address(hydx), address(usdc), address(zipUSD), address(xAlpha), uint256(0)));
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
        SellModule mc = new SellModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.engineSafe(), address(0));
        assertEq(mc.swapRouter(), address(0));
        assertEq(mc.hydx(), address(0));
        assertEq(mc.usdc(), address(0));
        assertEq(mc.zipUSD(), address(0));
        assertEq(mc.xAlpha(), address(0));
        vm.prank(operator);
        vm.expectRevert(SellModule.NotOperator.selector);
        mc.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- authority (both entrypoints)

    function test_sellHydx_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(SellModule.NotOperator.selector);
        m.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    function test_buyXAlpha_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(SellModule.NotOperator.selector);
        m.buyXAlpha(1e18, 1, block.timestamp + 1 hours);
    }

    function test_sellXAlpha_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(SellModule.NotOperator.selector);
        m.sellXAlpha(1e18, 1, block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- guards (both entrypoints)

    function test_sellHydx_guards_zero_amountIn_and_zero_minOut() public {
        vm.startPrank(operator);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.sellHydx(0, 1, block.timestamp + 1 hours);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.sellHydx(1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_buyXAlpha_guards_zero_amountIn_and_zero_minOut() public {
        vm.startPrank(operator);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.buyXAlpha(0, 1, block.timestamp + 1 hours);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.buyXAlpha(1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_sellXAlpha_guards_zero_amountIn_and_zero_minOut() public {
        vm.startPrank(operator);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.sellXAlpha(0, 1, block.timestamp + 1 hours);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.sellXAlpha(1e18, 0, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- the per-call HYDX size cap (defense-in-depth)

    /// @dev (cap) `sellHydx` reverts `ExceedsMaxSell` when `amountIn > maxSellHydx` — the whole-basket-dump backstop.
    function test_sellHydx_reverts_above_cap() public {
        vm.prank(operator);
        vm.expectRevert(SellModule.ExceedsMaxSell.selector);
        m.sellHydx(MAX_SELL + 1, 1, block.timestamp + 1 hours);
    }

    /// @dev (cap) `amountIn == maxSellHydx` (the exact boundary) is allowed — proves the guard is `>` not `>=`.
    function test_sellHydx_at_cap_is_allowed() public {
        safe.setReturnData(abi.encode(uint256(1)));
        vm.prank(operator);
        m.sellHydx(MAX_SELL, 1, block.timestamp + 1 hours); // does not revert at the cap guard
    }

    /// @dev (cap) the cap applies ONLY to `sellHydx` (HYDX) — `buyXAlpha` (zipUSD, a different token, bounded upstream
    ///      by 8-B10's free-value gate) is NOT capped here: a buy above MAX_SELL passes the cap layer.
    function test_buyXAlpha_not_capped_by_maxSellHydx() public {
        safe.setReturnData(abi.encode(uint256(1)));
        vm.prank(operator);
        m.buyXAlpha(MAX_SELL + 1, 1, block.timestamp + 1 hours); // no ExceedsMaxSell
    }

    /// @dev (cap) `sellXAlpha` (xALPHA, our own POL asset — no oHYDX-style profitability ceiling) is deliberately NOT
    ///      size-capped: an amount above MAX_SELL passes the cap layer (only `sellHydx` carries the HYDX backstop).
    function test_sellXAlpha_not_capped_by_maxSellHydx() public {
        safe.setReturnData(abi.encode(uint256(1)));
        vm.prank(operator);
        m.sellXAlpha(MAX_SELL + 1, 1, block.timestamp + 1 hours); // no ExceedsMaxSell
    }

    /// @dev (cap) the owner (Timelock) can re-size the cap; emits `MaxSellHydxSet`; a sell at the new larger cap passes.
    function test_setMaxSellHydx_owner_resizes() public {
        uint256 newMax = MAX_SELL * 2;
        vm.expectEmit(false, false, false, true, address(m));
        emit SellModule.MaxSellHydxSet(newMax);
        vm.prank(owner);
        m.setMaxSellHydx(newMax);
        assertEq(m.maxSellHydx(), newMax);

        safe.setReturnData(abi.encode(uint256(1)));
        vm.prank(operator);
        m.sellHydx(MAX_SELL + 1, 1, block.timestamp + 1 hours); // now under the raised cap
    }

    /// @dev (cap) the hot CRE operator (and any non-owner) CANNOT re-size the cap — only the Timelock owner.
    function test_setMaxSellHydx_only_owner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setMaxSellHydx(MAX_SELL * 2);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setMaxSellHydx(MAX_SELL * 2);
    }

    /// @dev (cap) the setter rejects a zero cap (would brick `sellHydx`).
    function test_setMaxSellHydx_rejects_zero() public {
        vm.prank(owner);
        vm.expectRevert(SellModule.ZeroAmount.selector);
        m.setMaxSellHydx(0);
    }

    // ----------------------------------------------------------------- exec discipline (fully pinned) — sellHydx

    function test_sellHydx_exec_shape_fully_pinned() public {
        _assertExecShape(true);
    }

    function test_buyXAlpha_exec_shape_fully_pinned() public {
        _assertExecShape(false);
    }

    /// @dev exec-shape for `sellXAlpha` (xALPHA → zipUSD) — fully pinned, mirrors `_assertExecShape` for the reverse pair.
    function test_sellXAlpha_exec_shape_fully_pinned() public {
        address tokenIn = address(xAlpha);
        address tokenOut = address(zipUSD);
        uint256 amountIn = 5e18;
        uint256 minOut = 12_000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 expectedOut = 10_556;
        safe.setReturnData(abi.encode(expectedOut));

        vm.expectEmit(true, true, true, true, address(m));
        emit SellModule.Sold(tokenIn, tokenOut, amountIn, expectedOut);
        vm.prank(operator);
        uint256 ret = m.sellXAlpha(amountIn, minOut, deadline);
        assertEq(ret, expectedOut, "return value == amountOut");

        assertEq(safe.callCount(), 3, "swap = 3 execs");
        _assertCall(0, tokenIn, abi.encodeWithSelector(IERC20.approve.selector, address(router), amountIn));
        _assertCall(
            1,
            address(router),
            abi.encodeCall(
                ISwapRouter.exactInputSingle,
                (
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        deployer: address(0),
                        recipient: address(safe),
                        deadline: deadline,
                        amountIn: amountIn,
                        amountOutMinimum: minOut,
                        limitSqrtPrice: 0
                    })
                )
            )
        );
        _assertCall(2, tokenIn, abi.encodeWithSelector(IERC20.approve.selector, address(router), uint256(0)));
    }

    /// @dev exec-shape, fully pinned for BOTH entrypoints (sell == true → HYDX/USDC, else zipUSD/xAlpha).
    function _assertExecShape(bool sell) internal {
        address tokenIn = sell ? address(hydx) : address(zipUSD);
        address tokenOut = sell ? address(usdc) : address(xAlpha);
        uint256 amountIn = 5e18;
        uint256 minOut = 12_000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 expectedOut = 10_556;
        safe.setReturnData(abi.encode(expectedOut));

        vm.expectEmit(true, true, true, true, address(m));
        emit SellModule.Sold(tokenIn, tokenOut, amountIn, expectedOut);
        vm.prank(operator);
        uint256 ret = sell ? m.sellHydx(amountIn, minOut, deadline) : m.buyXAlpha(amountIn, minOut, deadline);
        assertEq(ret, expectedOut, "return value == amountOut");

        assertEq(safe.callCount(), 3, "swap = 3 execs");
        // (1) approve(router, amountIn)
        _assertCall(0, tokenIn, abi.encodeWithSelector(IERC20.approve.selector, address(router), amountIn));
        // (2) exactInputSingle(params)
        _assertCall(
            1,
            address(router),
            abi.encodeCall(
                ISwapRouter.exactInputSingle,
                (
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        deployer: address(0),
                        recipient: address(safe),
                        deadline: deadline,
                        amountIn: amountIn,
                        amountOutMinimum: minOut,
                        limitSqrtPrice: 0
                    })
                )
            )
        );
        // (3) approve(router, 0) — the reset
        _assertCall(2, tokenIn, abi.encodeWithSelector(IERC20.approve.selector, address(router), uint256(0)));

        // decode the full ExactInputSingleParams from getCall(1) — every one of the 8 fields pinned.
        (,, bytes memory data,) = safe.getCall(1);
        ISwapRouter.ExactInputSingleParams memory p =
            abi.decode(_slice(data, 4), (ISwapRouter.ExactInputSingleParams));
        assertEq(p.tokenIn, tokenIn, "tokenIn field");
        assertEq(p.tokenOut, tokenOut, "tokenOut field");
        assertEq(p.deployer, address(0), "deployer == 0 (base-factory pool)");
        assertEq(p.recipient, address(safe), "recipient == engineSafe");
        assertEq(p.deadline, deadline, "deadline field");
        assertEq(p.amountIn, amountIn, "amountIn field");
        assertEq(p.amountOutMinimum, minOut, "amountOutMinimum == minOut");
        assertEq(p.limitSqrtPrice, 0, "limitSqrtPrice == 0");

        // decode the reset-approve args (spender == router, amount == 0).
        (,, bytes memory resetData,) = safe.getCall(2);
        (address spender, uint256 resetAmt) = abi.decode(_slice(resetData, 4), (address, uint256));
        assertEq(spender, address(router), "reset spender == router");
        assertEq(resetAmt, 0, "reset amount == 0");
    }

    function test_sellHydx_reverts_on_short_return_data() public {
        safe.setReturnData(hex"00112233"); // < 32 bytes
        vm.prank(operator);
        vm.expectRevert();
        m.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    function test_sellHydx_reverts_on_empty_return_data() public {
        safe.setReturnData(hex"");
        vm.prank(operator);
        vm.expectRevert();
        m.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- atomicity (production bubble path)

    function test_exec_bubbles_custom_error() public {
        // live Safe + a MockSwapRouter whose exactInputSingle reverts SwapBoom -> the bubble surfaces it.
        (SellModule x, RecordingSafe lsafe, MockERC20 ltoken, MockSwapRouter lrouter) = _liveRig();
        ltoken.mint(address(lsafe), 1e18);
        lrouter.setRevertOnSwap(true);
        vm.prank(operator);
        vm.expectRevert(MockSwapRouter.SwapBoom.selector);
        x.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    function test_exec_bubbles_no_data_ExecFailed() public {
        // a tokenIn whose approve reverts EMPTY through a live Safe -> ExecFailed fallback (exec #1).
        RecordingSafe lsafe = new RecordingSafe();
        lsafe.setLive(true);
        RevertEmptyToken badIn = new RevertEmptyToken();
        MockSwapRouter lrouter = new MockSwapRouter();
        SellModule x = new SellModule();
        x.setUp(abi.encode(
            owner, address(lsafe), operator, address(lrouter), address(badIn), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL
        ));
        vm.prank(operator);
        vm.expectRevert(SellModule.ExecFailed.selector);
        x.sellHydx(1e18, 1, block.timestamp + 1 hours);
    }

    /// @dev (e2) state-moving rollback: the swap (exec #2) reverts -> the whole tx reverts atomically, so exec #1's
    ///      approve is rolled back and NO dangling allowance survives.
    function test_state_moving_rollback_no_dangling_approval() public {
        (SellModule x, RecordingSafe lsafe, MockERC20 ltoken, MockSwapRouter lrouter) = _liveRig();
        ltoken.mint(address(lsafe), 1e18);
        lrouter.setRevertOnSwap(true);
        vm.prank(operator);
        vm.expectRevert(MockSwapRouter.SwapBoom.selector);
        x.sellHydx(1e18, 1, block.timestamp + 1 hours);
        assertEq(ltoken.allowance(address(lsafe), address(lrouter)), 0, "no dangling approval after rollback");
    }

    /// @dev (e3) state-moving happy path: the reset actually clears the residual allowance on a state-moving path (not
    ///      just the calldata shape), and the tokenIn actually moves.
    function test_state_moving_happy_path_resets_allowance() public {
        (SellModule x, RecordingSafe lsafe, MockERC20 ltoken, MockSwapRouter lrouter) = _liveRig();
        uint256 amountIn = 1e18;
        uint256 expectedOut = 10_556;
        ltoken.mint(address(lsafe), amountIn);
        lrouter.setAmountOut(expectedOut);

        uint256 balBefore = ltoken.balanceOf(address(lsafe));
        vm.prank(operator);
        uint256 ret = x.sellHydx(amountIn, 1, block.timestamp + 1 hours);

        assertEq(ret, expectedOut, "return == amountOut");
        assertEq(ltoken.allowance(address(lsafe), address(lrouter)), 0, "residual allowance reset to 0");
        assertEq(balBefore - ltoken.balanceOf(address(lsafe)), amountIn, "exactly amountIn tokenIn pulled");
        assertEq(lrouter.didRecord(), true, "router received the swap");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev A live rig where the wired `hydx` (tokenIn for sellHydx) is a controllable MockERC20.
    function _liveRig() internal returns (SellModule x, RecordingSafe lsafe, MockERC20 ltoken, MockSwapRouter lrouter) {
        ltoken = new MockERC20();
        lrouter = new MockSwapRouter();
        lsafe = new RecordingSafe();
        lsafe.setLive(true);
        x = new SellModule();
        x.setUp(abi.encode(
            owner, address(lsafe), operator, address(lrouter), address(ltoken), address(usdc), address(zipUSD), address(xAlpha), MAX_SELL
        ));
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
}

// =========================================================================== fork tests (live Base)

/// @notice Fork tests against live Base: a real `SwapRouter.exactInputSingle` HYDX→USDC against a real summoned
///         substrate Safe seeded with HYDX, proving the HYDX pull / USDC-to-Safe / amountOut return / minOut
///         enforcement / allowance reset, plus a signature-verification of the router/pool surface and the minOut-too-
///         high + past-deadline revert bubbles. `buyXAlpha` is unit-only (no live zipUSD/xALPHA POL pool yet).
contract SellModuleForkTest is ForkConfig, SummonSubstrate {
    address internal constant HYDX_WHALE = 0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF; // a known HYDX/oHYDX holder

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");

    // mocks for the zipUSD/xAlpha wiring (no live POL pool yet) — only their addresses matter for setUp + sellHydx.
    address internal zipUSD = makeAddr("zipUSD");
    address internal xAlpha = makeAddr("xAlpha");

    uint256 internal constant SALT = uint256(keccak256("zipcode.sell.8b9.salt.a"));

    function setUp() public {
        _selectBaseFork();
    }

    function _summonAndEnable(SellModule m) internal returns (address mainSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        mainSafe = s.mainSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(mainSafe).execTransaction(mainSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _deploy() internal returns (SellModule m, address engineSafe) {
        m = new SellModule();
        engineSafe = _summonAndEnable(m);
        m.setUp(abi.encode(
            owner,
            engineSafe,
            operator,
            BaseAddresses.ALGEBRA_SWAP_ROUTER,
            BaseAddresses.HYDX,
            BaseAddresses.USDC,
            zipUSD,
            xAlpha,
            uint256(300_000e18)
        ));
    }

    function _fundHYDX(address engineSafe, uint256 amount) internal {
        try this.tryDeal(BaseAddresses.HYDX, engineSafe, amount) {
            if (IERC20(BaseAddresses.HYDX).balanceOf(engineSafe) >= amount) return;
        } catch {}
        vm.prank(HYDX_WHALE);
        IERC20(BaseAddresses.HYDX).transfer(engineSafe, amount);
    }

    function tryDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    /// @dev Read a sanity quote: spot-implied USDC for `amountInHydx` off `pool.globalState()`. price = sqrtPriceX96
    ///      analogue; Algebra packs sqrtPrice (Q64.96) in `globalState().price`. token0==HYDX (18dp), token1==USDC
    ///      (6dp). spotPrice (token1/token0) = (price/2^96)^2. USDC out ≈ amountInHydx * spot (with decimal scaling).
    function _spotQuoteUsdc(uint256 amountInHydx) internal view returns (uint256) {
        (uint160 sqrtP,,,,,) = IAlgebraPool(BaseAddresses.HYDX_USDC_POOL).globalState();
        // priceX192 = sqrtP^2 (token1 per token0, scaled by 2^192). usdc(6dp) = hydx(18dp) * priceX192 / 2^192.
        uint256 priceX192 = uint256(sqrtP) * uint256(sqrtP);
        return (amountInHydx * priceX192) >> 192;
    }

    // ----------------------------------------------------------------- sig-verify

    function test_fork_sig_verify() public {
        (SellModule m,) = _deploy();
        // the module stored the live router.
        assertEq(m.swapRouter(), BaseAddresses.ALGEBRA_SWAP_ROUTER, "swapRouter wired to live router");
        assertEq(m.hydx(), BaseAddresses.HYDX, "hydx wired");
        assertEq(m.usdc(), BaseAddresses.USDC, "usdc wired");

        // the pool surface resolves: globalState decodes, token0==HYDX, token1==USDC.
        IAlgebraPool pool = IAlgebraPool(BaseAddresses.HYDX_USDC_POOL);
        (uint160 price,,,,, bool unlocked) = pool.globalState();
        assertGt(price, 0, "globalState price resolves");
        assertTrue(unlocked, "pool unlocked");
        assertEq(pool.token0(), BaseAddresses.HYDX, "token0 == HYDX");
        assertEq(pool.token1(), BaseAddresses.USDC, "token1 == USDC");
    }

    // ----------------------------------------------------------------- real sell (the model)

    function test_fork_real_sellHydx() public {
        (SellModule m, address engineSafe) = _deploy();

        // small amountIn well within pool depth: 100 HYDX.
        uint256 amountIn = 100e18;
        _fundHYDX(engineSafe, amountIn);

        // quote + exec in the SAME block, no warp/roll between (avoid a stale-quote flake).
        uint256 expectedOut = _spotQuoteUsdc(amountIn);
        assertGt(expectedOut, 0, "sanity quote > 0");
        uint256 minOut = expectedOut * 80 / 100; // generous integer-math cushion — the test proves mechanism not price.

        uint256 hBefore = IERC20(BaseAddresses.HYDX).balanceOf(engineSafe);
        uint256 uBefore = IERC20(BaseAddresses.USDC).balanceOf(engineSafe);

        vm.recordLogs();
        vm.prank(operator);
        uint256 amountOut = m.sellHydx(amountIn, minOut, block.timestamp + 1 hours);

        assertGt(amountOut, 0, "amountOut > 0");
        assertGe(amountOut, minOut, "amountOut >= minOut");
        assertEq(hBefore - IERC20(BaseAddresses.HYDX).balanceOf(engineSafe), amountIn, "exactly amountIn HYDX pulled");
        assertEq(
            IERC20(BaseAddresses.USDC).balanceOf(engineSafe) - uBefore, amountOut, "exactly amountOut USDC to the Safe"
        );
        assertEq(
            IERC20(BaseAddresses.HYDX).allowance(engineSafe, BaseAddresses.ALGEBRA_SWAP_ROUTER),
            0,
            "approval reset to 0 (no standing approval)"
        );

        // the Sold event fired with the returned amountOut.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(m) && logs[i].topics[0] == SellModule.Sold.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseAddresses.HYDX, "event tokenIn == HYDX");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), BaseAddresses.USDC, "event tokenOut == USDC");
                (uint256 ain, uint256 aout) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(ain, amountIn, "event amountIn");
                assertEq(aout, amountOut, "event amountOut");
                assertGt(aout, 0, "event amountOut nonzero");
                found = true;
            }
        }
        assertTrue(found, "Sold emitted");
    }

    // ----------------------------------------------------------------- minOut-too-high / deadline reverts

    function test_fork_minOut_too_high_reverts_state_unchanged() public {
        (SellModule m, address engineSafe) = _deploy();
        uint256 amountIn = 100e18;
        _fundHYDX(engineSafe, amountIn);

        IERC20 hydx = IERC20(BaseAddresses.HYDX);
        IERC20 usdc = IERC20(BaseAddresses.USDC);
        uint256 hBefore = hydx.balanceOf(engineSafe);
        uint256 uBefore = usdc.balanceOf(engineSafe);

        // an impossible slippage floor -> the router slippage guard reverts, bubbled through _exec.
        vm.prank(operator);
        vm.expectRevert();
        m.sellHydx(amountIn, type(uint256).max, block.timestamp + 1 hours);

        // the atomic revert rolled back exec #1's approve -> no dangling approval, no partial swap.
        assertEq(hydx.allowance(engineSafe, BaseAddresses.ALGEBRA_SWAP_ROUTER), 0, "no dangling approval");
        assertEq(hydx.balanceOf(engineSafe), hBefore, "HYDX balance unchanged");
        assertEq(usdc.balanceOf(engineSafe), uBefore, "USDC balance unchanged");
    }

    function test_fork_past_deadline_reverts() public {
        (SellModule m, address engineSafe) = _deploy();
        uint256 amountIn = 100e18;
        _fundHYDX(engineSafe, amountIn);
        uint256 minOut = _spotQuoteUsdc(amountIn) * 80 / 100;

        vm.warp(block.timestamp + 100);
        vm.prank(operator);
        vm.expectRevert();
        m.sellHydx(amountIn, minOut, block.timestamp - 1);
    }
}
