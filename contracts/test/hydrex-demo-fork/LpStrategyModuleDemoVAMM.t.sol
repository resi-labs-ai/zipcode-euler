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

/// @notice A faithful Solidly-style vAMM pair that IS the LP token. `mint(to)` reads the token0/token1 the pair
///         RECEIVED since the last mint (balance delta — exactly the routerless "transfer then mint" shape the module
///         uses) and credits the REAL Solidly share math:
///           - empty pool (totalSupply == 0): `shares = sqrt(in0 * in1)` (geometric-mean seed; Solidly's
///             MINIMUM_LIQUIDITY burn is omitted as a harmless mock simplification);
///           - existing pool: `shares = min(in0 * totalSupply / reserve0, in1 * totalSupply / reserve1)` — the
///             minter earns shares ONLY for the lesser side; the excess of the larger side is DONATED to the pool
///             (reserves grow by the full received amount but mint no shares). A single-sided add therefore mints
///             `min(x, 0) = 0`.
///         Exposes `token0`/`token1` (read in setUp), a `seed(...)` helper to model the live HYDX/USDC pool, and a
///         `revertMode` for the `_exec`-bubble test. ERC20 surface backs the gauge approve/deposit path.
contract MockVammPair {
    string public constant name = "Mock vAMM LP";
    string public constant symbol = "mVAMM";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public token0;
    address public token1;
    uint256 public reserve0;
    uint256 public reserve1;
    uint8 public revertMode; // 0 = normal, 1 = custom-error revert, 2 = no-data revert

    error PairBoom();

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    /// @dev Seed an EXISTING-pool state so share-math tests model the live HYDX/USDC pool: reserves, totalSupply,
    ///      and the pair's own LP `balanceOf` (the seed liquidity is held by the pair itself — irrelevant to the
    ///      module's mint-to-Safe path, but keeps `balanceOf` summing to `totalSupply`).
    function seed(uint256 r0, uint256 r1, uint256 supply) external {
        reserve0 = r0;
        reserve1 = r1;
        totalSupply = supply;
        balanceOf[address(this)] = supply;
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

    /// @dev The faithful Solidly `mint`: shares against the freshly-received reserves (balance delta), to `to`.
    ///      Empty pool → geometric mean of both legs; existing pool → min of the two pro-rata legs (lesser side
    ///      wins, larger side is donated). Reserves always snap to the full post-transfer balances (the donate).
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
        if (totalSupply == 0) {
            shares = _sqrt(in0 * in1);
        } else {
            shares = _min(in0 * totalSupply / reserve0, in1 * totalSupply / reserve1);
        }
        reserve0 = bal0; // the donate: the excess of the larger side is absorbed into reserves, mints no shares
        reserve1 = bal1;
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Babylonian sqrt (the Solidly/UniswapV2 seed math).
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
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
        // Model the live HYDX/USDC pool: a 1:1 existing pool with supply == reserves so a proportional add mints 1:1.
        _seedPool(1000e18, 1000e18, 1000e18);
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);

        // A BOTH-sided PROPORTIONAL add (matching the 1:1 reserve ratio) mints the real `min`-based shares.
        // shares = min(100e18 * 1000e18 / 1000e18, 100e18 * 1000e18 / 1000e18) = min(100e18, 100e18) = 100e18.
        vm.prank(operator);
        uint256 sb = m.addLiquidity(100e18, 100e18, 1);
        assertEq(sb, 100e18, "proportional both-legs shares = min-based pro-rata");
        assertEq(m.lpBalance(), sb, "lpBalance == minted shares to the Safe");
        assertEq(token0.balanceOf(address(pair)), 1000e18 + 100e18, "token0 transferred to the pair (seed + add)");
        assertEq(token1.balanceOf(address(pair)), 1000e18 + 100e18, "token1 transferred to the pair (seed + add)");

        // A second proportional add (the reserves are now 1100:1100, supply 1100) mints pro-rata again.
        // shares = min(110e18 * 1100e18 / 1100e18, 110e18 * 1100e18 / 1100e18) = 110e18.
        vm.prank(operator);
        uint256 sb2 = m.addLiquidity(110e18, 110e18, 1);
        assertEq(sb2, 110e18, "second proportional both-legs shares = min-based pro-rata");
        assertEq(m.lpBalance(), sb + sb2, "cumulative LP in the Safe");

        // A SINGLE-sided add on a real pair mints min(x, 0) == 0 → floored out (covered by the dedicated revert test).
    }

    function test_addLiquidity_slippage_floor() public {
        safe.setLive(true);
        // Seed a 1:1 existing pool (supply == reserves); a proportional add of (100,100) mints min-based 100e18.
        _seedPool(1000e18, 1000e18, 1000e18);
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);

        // one above the achievable min-based shares must revert Slippage
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.Slippage.selector);
        m.addLiquidity(100e18, 100e18, 100e18 + 1);

        // at exactly the achievable floor it passes
        vm.prank(operator);
        uint256 s = m.addLiquidity(100e18, 100e18, 100e18);
        assertEq(s, 100e18);
    }

    /// @notice REGRESSION (HYDREX-ADV-02 issue 1): the bare deployed mastercopy is init-locked at construction
    ///         (via {MastercopyInitLock}), so calling `setUp` on it reverts `AlreadyInitialized` — a bare mastercopy
    ///         can never be hijacked/initialized. Clones (which never run the ctor) still `setUp` exactly once.
    function test_mastercopy_cannot_be_setUp() public {
        LpStrategyModuleDemoVAMM mastercopy = new LpStrategyModuleDemoVAMM(); // NOT a clone — runs the init-lock ctor
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mastercopy.setUp(abi.encode(owner, address(safe), operator, address(pair), address(gauge)));
    }

    /// @notice REGRESSION (HYDREX-ADV-02 issue 2): a mis-RATIOED both-sided add mints only the LESSER side's pro-rata
    ///         shares; the EXCESS of the larger side is DONATED — absorbed into reserves but minting no shares. The
    ///         Safe's LP == the lesser-side value, and the pair's reserves grow by the FULL deposited amounts.
    function test_addLiquidity_donatesExcessOfMisSizedSide() public {
        safe.setLive(true);
        _seedPool(1000e18, 1000e18, 1000e18); // 1:1 pool, supply == reserves
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);

        // Mis-ratioed add: token0 leg pro-rata = 200e18 * 1000/1000 = 200e18; token1 leg = 50e18 * 1000/1000 = 50e18.
        // shares = min(200e18, 50e18) = 50e18 (the lesser side); the extra 150e18 of token0 is DONATED.
        vm.prank(operator);
        uint256 shares = m.addLiquidity(200e18, 50e18, 1);
        assertEq(shares, 50e18, "shares == lesser-side pro-rata (the larger side mints nothing)");
        assertEq(m.lpBalance(), 50e18, "only the lesser-side shares land in the Safe");

        // The donate: reserves grew by the FULL deposited amounts (the 150e18 token0 excess is now pool-owned).
        (uint256 r0, uint256 r1,) = pair.getReserves();
        assertEq(r0, 1000e18 + 200e18, "reserve0 absorbed the full token0 deposit (incl. the donated excess)");
        assertEq(r1, 1000e18 + 50e18, "reserve1 absorbed the full token1 deposit");
    }

    /// @notice REGRESSION (HYDREX-ADV-02 issue 2): a SINGLE-sided add on a real (existing) pair mints
    ///         min(x, 0) == 0 shares, so the module's `minShares >= 1` floor reverts `Slippage`. The old mock's
    ///         sum-based math wrongly treated single-sided builds as legitimate.
    function test_addLiquidity_singleSided_mintsZero_revertsOnFloor() public {
        safe.setLive(true);
        _seedPool(1000e18, 1000e18, 1000e18); // existing pool
        token0.mint(address(safe), 1000e18);

        // token1 leg == 0 → min(200e18 * S / r0, 0 * S / r1) == 0 → fails the minShares floor.
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.Slippage.selector);
        m.addLiquidity(200e18, 0, 1);
    }

    // ----------------------------------------------------------------- exec discipline (live mock, per-index)

    /// @dev Exec discipline for the token1-leg-skipped shape: deposit0 only drives EXACTLY 2 execs (one transfer +
    ///      the mint). On a faithful Solidly pair a TRUE single-sided mint yields 0 shares and is floored out
    ///      (see `test_addLiquidity_singleSided_mintsZero_revertsOnFloor`); to exercise the 2-exec CALL pattern
    ///      itself we deposit only token0 but seed an EMPTY pool so the geometric-mean seed path mints against the
    ///      single received leg — the call sequence (the thing under test here) is identical to the live path.
    function test_exec_discipline_addLiquidity_single() public {
        // Empty pool (totalSupply == 0): mint = sqrt(in0 * in1). With token1 also funded into the pair as part of
        // the same balanced seed-add we keep both legs > 0 so the seed mint is non-zero and the floor passes; the
        // assertion under test is the CALL SHAPE, which for a one-operator-leg deposit is transfer + mint.
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        // We need a non-zero in1 for sqrt to be > 0, so pre-fund the pair's token1 balance directly (models prior
        // dust/seed already sitting in the pair) without touching totalSupply — keeps the pool "empty" for seed math.
        token1.mint(address(pair), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 0, 1); // 1 transfer (token0) + mint
        assertEq(safe.callCount(), 2, "single-leg (token0-only) vAMM add = 2 execs (transfer + mint)");
        _assertCall(0, address(token0), abi.encodeWithSelector(IERC20.transfer.selector, address(pair), uint256(100e18)));
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
        // Proportional both-sided seed-add so the Safe holds LP to stake (single-sided would mint 0 on a real pair).
        token0.mint(address(safe), 100e18);
        token1.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 100e18, 1); // empty pool: safe holds sqrt(100e18 * 100e18) = 100e18 LP
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
        // Proportional both-sided add (single-sided mints 0 on a real pair); empty pool → sqrt(100e18*100e18)=100e18.
        token0.mint(address(safe), 100e18);
        token1.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 100e18, 1);
        assertEq(m.lpBalance(), 100e18, "lpBalance reflects the Safe");
        vm.prank(operator);
        m.stake(40e18);
        assertEq(m.stakedBalance(), 40e18, "stakedBalance reflects the Safe");
        assertEq(m.lpBalance(), 60e18, "lpBalance dropped by the staked slice");
    }

    // ----------------------------------------------------------------- fuzz (tier-mover)

    /// @notice Fuzz the FAITHFUL Solidly share math against a seeded existing pool: shares == min(d0·S/r0, d1·S/r1)
    ///         (the lesser side wins; the larger side is donated), the minShares floor is exact (==shares passes,
    ///         +1 reverts), and the LP lands in the Safe.
    function testFuzz_addLiquidityShareMathAndFloor(uint128 d0, uint128 d1, uint64 supplySeed) public {
        safe.setLive(true);

        // A 1:1 existing pool whose supply is fuzzed; both reserves must be non-zero for the pro-rata math.
        uint256 r = 1_000_000e18;
        uint256 supply = bound(uint256(supplySeed), 1, 1_000_000e18);
        _seedPool(r, r, supply);

        // Bound deposits so each pro-rata leg fits a uint256 product comfortably and at least one mints non-zero.
        uint256 a0 = bound(uint256(d0), 1, 1_000_000e18);
        uint256 a1 = bound(uint256(d1), 1, 1_000_000e18);
        token0.mint(address(safe), a0);
        token1.mint(address(safe), a1);

        uint256 leg0 = a0 * supply / r;
        uint256 leg1 = a1 * supply / r;
        uint256 expected = leg0 < leg1 ? leg0 : leg1;
        vm.assume(expected > 0); // a dust deposit rounding to 0 shares is a degenerate input, not the property under test

        // one above the achievable min-based floor must revert Slippage
        vm.prank(operator);
        vm.expectRevert(LpStrategyModuleDemoVAMM.Slippage.selector);
        m.addLiquidity(a0, a1, expected + 1);

        // at exactly the achievable floor it passes and the shares match the min-based formula
        vm.prank(operator);
        uint256 shares = m.addLiquidity(a0, a1, expected);
        assertEq(shares, expected, "shares == min(d0 * S / r0, d1 * S / r1)");
        assertEq(m.lpBalance(), shares, "LP minted to the engine Safe");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Seed an existing-pool state CONSISTENTLY: set the pair's reserves/supply AND fund the pair's underlying
    ///      token0/token1 balances to match those reserves (so `mint`'s `in = balance - reserve` delta is correct;
    ///      otherwise the pair holds less underlying than its reserve and the balance-delta underflows).
    function _seedPool(uint256 r0, uint256 r1, uint256 supply) internal {
        token0.mint(address(pair), r0);
        token1.mint(address(pair), r1);
        pair.seed(r0, r1, supply);
    }

    function _assertCall(uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }
}
