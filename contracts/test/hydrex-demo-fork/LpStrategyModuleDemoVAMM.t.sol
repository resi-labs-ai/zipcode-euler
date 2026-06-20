// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LpStrategyModuleDemoVAMM} from "../../src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol";
import {IVammPair} from "../../src/interfaces/hydrex/IVammPair.sol";
import {IGauge} from "../../src/interfaces/hydrex/IGauge.sol";

/// @notice Dedicated unit + fuzz suite for the DEMO fork — ported from `test/LpStrategyModule.t.sol` (the audited
///         prod parent) with the ONLY differing seam swapped: the prod `MockICHIVault` (approve→deposit) becomes a
///         `MockVammPair` (direct transfer→`mint`). `stake`/`unstake`/setters/authority are identical to prod.
///         This converts the fork from "EXPOSED (no dedicated tests)" to a tested contract: the swapped vAMM
///         `addLiquidity` mint + its exec discipline + atomicity + `_exec` bubble are now covered.

function _cloneDemo() returns (LpStrategyModuleDemoVAMM) {
    return LpStrategyModuleDemoVAMM(Clones.clone(address(new LpStrategyModuleDemoVAMM())));
}

// =========================================================================== mocks

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A Solidly-style vAMM pair that IS the LP token. `mint(to)` reads the token0/token1 the pair RECEIVED
///         since the last mint (balance delta — exactly the routerless "transfer then mint" shape the module uses),
///         credits `shares = receivedSum * 1e18 / pricePerShare` to `to`. Exposes `token0`/`token1` (read in setUp)
///         and a `revertMode` for the `_exec`-bubble test. ERC20 surface backs the gauge approve/deposit path.
contract MockVammPair {
    string public constant name = "Mock vAMM LP";
    string public constant symbol = "mVAMM";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public token0;
    address public token1;
    uint256 public pricePerShare = 1e18;
    uint256 public reserve0;
    uint256 public reserve1;
    uint8 public revertMode; // 0 = normal, 1 = custom-error revert, 2 = no-data revert

    error PairBoom();

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setPricePerShare(uint256 p) external {
        pricePerShare = p;
    }

    function setRevertMode(uint8 m) external {
        revertMode = m;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function getReserves() external view returns (uint256, uint256, uint256) {
        return (reserve0, reserve1, 0);
    }

    /// @dev The Solidly `mint`: shares against the freshly-received reserves (balance delta), to `to`.
    function mint(address to) external returns (uint256 shares) {
        if (revertMode == 1) revert PairBoom();
        if (revertMode == 2) {
            assembly {
                revert(0, 0)
            }
        }
        uint256 bal0 = MockERC20(token0).balanceOf(address(this));
        uint256 bal1 = MockERC20(token1).balanceOf(address(this));
        uint256 in0 = bal0 - reserve0;
        uint256 in1 = bal1 - reserve1;
        shares = (in0 + in1) * 1e18 / pricePerShare;
        reserve0 = bal0;
        reserve1 = bal1;
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

contract MockGauge {
    address public immutable lp;
    address public immutable rewardToken;
    mapping(address => uint256) public balanceOf;

    constructor(address lp_, address rewardToken_) {
        lp = lp_;
        rewardToken = rewardToken_;
    }

    function deposit(uint256 amount) external {
        IERC20(lp).transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        IERC20(lp).transfer(msg.sender, amount);
    }
}

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

    function setLive(bool v) external {
        live = v;
    }

    function setFailOnCallIndex(uint256 i) external {
        failOnCallIndex = i;
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
            (ok, ret) = to.call{value: value}(data);
            return (ok, ret);
        }
        return (true, "");
    }

    receive() external payable {}
}

// =========================================================================== unit + fuzz

contract LpStrategyModuleDemoVAMMTest is Test {
    LpStrategyModuleDemoVAMM internal m;
    RecordingSafe internal safe;
    MockVammPair internal pair;
    MockGauge internal gauge;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    function setUp() public {
        token0 = new MockERC20();
        token1 = new MockERC20();
        pair = new MockVammPair(address(token0), address(token1));
        gauge = new MockGauge(address(pair), address(0xDEAD));
        safe = new RecordingSafe();
        m = _cloneDemo();
        m.setUp(abi.encode(owner, address(safe), operator, address(pair), address(gauge)));
    }

    // ----------------------------------------------------------------- setUp / authority

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.juniorTrancheEngine(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.ichiVault(), address(pair)); // the `ichiVault` slot holds the vAMM pair (name kept for ABI parity)
        assertEq(m.gauge(), address(gauge));
        assertEq(m.token0(), address(token0));
        assertEq(m.token1(), address(token1));
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(abi.encode(owner, address(safe), operator, address(pair), address(gauge)));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        LpStrategyModuleDemoVAMM x = _cloneDemo();
        vm.expectRevert(LpStrategyModuleDemoVAMM.OwnerIsOperator.selector);
        x.setUp(abi.encode(owner, address(safe), owner, address(pair), address(gauge)));
    }

    function test_setUp_rejects_zero_gauge() public {
        LpStrategyModuleDemoVAMM x = _cloneDemo();
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(pair), address(0)));
    }

    function test_setUp_rejects_zero_pair_at_guard_not_staticcall() public {
        LpStrategyModuleDemoVAMM x = _cloneDemo();
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(0), address(gauge)));
    }

    function test_setUp_rejects_zero_juniorTrancheEngine() public {
        LpStrategyModuleDemoVAMM x = _cloneDemo();
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(0), operator, address(pair), address(gauge)));
    }

    function test_setUp_rejects_zero_token_leg() public {
        MockVammPair badPair = new MockVammPair(address(0), address(token1));
        LpStrategyModuleDemoVAMM x = _cloneDemo();
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(badPair), address(gauge)));
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    function test_entrypoints_only_operator() public {
        vm.startPrank(rando);
        vm.expectRevert(LpStrategyModuleDemoVAMM.NotOperator.selector);
        m.addLiquidity(1e18, 0, 1);
        vm.expectRevert(LpStrategyModuleDemoVAMM.NotOperator.selector);
        m.stake(1e18);
        vm.expectRevert(LpStrategyModuleDemoVAMM.NotOperator.selector);
        m.unstake(1e18);
        vm.stopPrank();
    }

    function test_zero_amount_reverts() public {
        vm.startPrank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAmount.selector);
        m.addLiquidity(0, 0, 1);
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAmount.selector);
        m.stake(0);
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroAmount.selector);
        m.unstake(0);
        vm.stopPrank();
    }

    function test_zero_minShares_reverts() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.ZeroMinShares.selector);
        m.addLiquidity(50e18, 0, 0);
    }

    // ----------------------------------------------------------------- addLiquidity (the swapped vAMM seam)

    function test_addLiquidity_single_and_both_sided_share_math() public {
        safe.setLive(true);
        pair.setPricePerShare(2e18); // shares = received/2 -> non-1:1
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);

        vm.prank(operator);
        uint256 s0 = m.addLiquidity(100e18, 0, 1);
        assertEq(s0, 50e18, "single-sided token0 shares = d0/2");
        assertEq(m.lpBalance(), s0, "lpBalance == minted shares");

        vm.prank(operator);
        uint256 s1 = m.addLiquidity(0, 40e18, 1);
        assertEq(s1, 20e18, "single-sided token1 shares = d1/2");

        vm.prank(operator);
        uint256 sb = m.addLiquidity(100e18, 100e18, 1);
        assertEq(sb, 100e18, "both-legs shares = (d0+d1)/2");
        assertEq(m.lpBalance(), s0 + s1 + sb, "cumulative LP in the Safe");
        assertEq(token0.balanceOf(address(pair)), 200e18, "token0 transferred to the pair (100 + 100)");
        assertEq(token1.balanceOf(address(pair)), 140e18, "token1 transferred to the pair (40 + 100)");
    }

    function test_addLiquidity_slippage_floor() public {
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.Slippage.selector);
        m.addLiquidity(100e18, 0, 100e18 + 1);
        vm.prank(operator);
        uint256 s = m.addLiquidity(100e18, 0, 100e18);
        assertEq(s, 100e18);
    }

    // ----------------------------------------------------------------- exec discipline (live mock, per-index)

    function test_exec_discipline_addLiquidity_single() public {
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        vm.prank(operator);
        m.addLiquidity(50e18, 0, 1);
        assertEq(safe.callCount(), 2, "single-sided vAMM add = 2 execs (transfer + mint)");
        _assertCall(0, address(token0), abi.encodeWithSelector(IERC20.transfer.selector, address(pair), uint256(50e18)));
        _assertCall(1, address(pair), abi.encodeCall(IVammPair.mint, (address(safe))));
    }

    function test_exec_discipline_addLiquidity_both_legs() public {
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);
        vm.prank(operator);
        m.addLiquidity(30e18, 70e18, 1);
        assertEq(safe.callCount(), 3, "both-legs vAMM add = 3 execs (2 transfers + mint)");
        _assertCall(0, address(token0), abi.encodeWithSelector(IERC20.transfer.selector, address(pair), uint256(30e18)));
        _assertCall(1, address(token1), abi.encodeWithSelector(IERC20.transfer.selector, address(pair), uint256(70e18)));
        _assertCall(2, address(pair), abi.encodeCall(IVammPair.mint, (address(safe))));
    }

    function test_exec_discipline_stake_and_unstake() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 0, 1); // safe holds 100e18 LP (price 1e18)
        uint256 base = safe.callCount();

        vm.prank(operator);
        m.stake(60e18);
        assertEq(safe.callCount() - base, 3, "stake = 3 execs (approve / deposit / reset)");
        _assertCall(base + 0, address(pair), abi.encodeWithSelector(IERC20.approve.selector, address(gauge), uint256(60e18)));
        _assertCall(base + 1, address(gauge), abi.encodeCall(IGauge.deposit, (uint256(60e18))));
        _assertCall(base + 2, address(pair), abi.encodeWithSelector(IERC20.approve.selector, address(gauge), uint256(0)));

        uint256 base2 = safe.callCount();
        vm.prank(operator);
        m.unstake(20e18);
        assertEq(safe.callCount() - base2, 1, "unstake = 1 exec");
        _assertCall(base2 + 0, address(gauge), abi.encodeCall(IGauge.withdraw, (uint256(20e18))));
    }

    // ----------------------------------------------------------------- atomicity / _exec bubble

    function test_atomicity_addLiquidity_mint_fail_rolls_back_transfer() public {
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // the mint (index 1: [0] transfer, [1] mint)
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert();
        m.addLiquidity(50e18, 0, 1);
        assertEq(token0.balanceOf(address(safe)), 100e18, "transfer rolled back with the failed mint");
        assertEq(token0.balanceOf(address(pair)), 0, "no tokens stuck in the pair");
    }

    function test_exec_bubbles_custom_error() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        pair.setRevertMode(1); // PairBoom()
        vm.prank(operator);
        vm.expectRevert(MockVammPair.PairBoom.selector);
        m.addLiquidity(50e18, 0, 1);
    }

    function test_exec_bubbles_no_data_falls_back_to_ExecFailed() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        pair.setRevertMode(2); // revert(0,0) -> no data
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.ExecFailed.selector);
        m.addLiquidity(50e18, 0, 1);
    }

    // ----------------------------------------------------------------- views

    function test_views_read_juniorTrancheEngine() public {
        safe.setLive(true);
        assertEq(m.lpBalance(), 0, "no LP yet");
        assertEq(m.stakedBalance(), 0, "no stake yet");
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 0, 1);
        assertEq(m.lpBalance(), 100e18, "lpBalance reflects the Safe");
        vm.prank(operator);
        m.stake(40e18);
        assertEq(m.stakedBalance(), 40e18, "stakedBalance reflects the Safe");
        assertEq(m.lpBalance(), 60e18, "lpBalance dropped by the staked slice");
    }

    // ----------------------------------------------------------------- fuzz (tier-mover)

    /// @notice Fuzz the swapped vAMM share math across the deposit/price domain: shares == receivedSum·1e18/pps,
    ///         the minShares floor is exact (==shares passes, +1 reverts), and the LP lands in the Safe.
    function testFuzz_addLiquidityShareMathAndFloor(uint128 d0, uint128 d1, uint64 ppsSeed) public {
        safe.setLive(true);
        uint256 pps = bound(uint256(ppsSeed), 1, 4e18);
        pair.setPricePerShare(pps);
        vm.assume(uint256(d0) + uint256(d1) > 0);
        token0.mint(address(safe), d0);
        token1.mint(address(safe), d1);

        uint256 expected = (uint256(d0) + uint256(d1)) * 1e18 / pps;
        vm.assume(expected > 0); // a dust deposit rounding to 0 shares is a degenerate input, not the property under test

        // one above the achievable floor must revert Slippage
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.Slippage.selector);
        m.addLiquidity(d0, d1, expected + 1);

        // at exactly the achievable floor it passes and the shares match the formula
        vm.prank(operator);
        uint256 shares = m.addLiquidity(d0, d1, expected);
        assertEq(shares, expected, "shares == receivedSum * 1e18 / pricePerShare");
        assertEq(m.lpBalance(), shares, "LP minted to the engine Safe");
    }

    // ----------------------------------------------------------------- helpers

    function _assertCall(uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }
}
