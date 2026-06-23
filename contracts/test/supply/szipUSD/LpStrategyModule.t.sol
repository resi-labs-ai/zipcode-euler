// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "../../ForkConfig.sol";
import {BaseAddresses} from "../../../script/BaseAddresses.sol";
import {SummonSubstrate} from "../../../script/SummonSubstrate.s.sol";
import {ISafe} from "../../../src/interfaces/safe/ISafe.sol";

import {LpStrategyModule} from "../../../src/supply/szipUSD/LpStrategyModule.sol";
import {IICHIVault} from "../../../src/interfaces/ichi/IICHIVault.sol";
import {IGauge} from "../../../src/interfaces/hydrex/IGauge.sol";
import {IVoter} from "../../../src/interfaces/hydrex/IVoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev SEC-14: mastercopies are init-locked in their ctor, so `setUp` on a bare impl reverts.
///      A fresh EIP-1167 clone (fresh proxy storage) behaves like the old bare instance for setUp.
function _cloneLpStrategyModule() returns (LpStrategyModule) {
    return LpStrategyModule(Clones.clone(address(new LpStrategyModule())));
}

// =========================================================================== mocks

/// @notice A minimal 18-dp ERC20 (model `MockLpToken` in `FarmUtilityLoopModule.t.sol`). Real allowance tracking so the
///         approve/atomicity assertions are meaningful.
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

/// @notice A faithful 18-dp ICHI vault stand-in that IS the LP share token (the vault == the LP token). `deposit`
///         pulls each non-zero side from `msg.sender` via `transferFrom`, mints `shares` to `to` at a configurable
///         `pricePerShare != 1e18`, and reverts on a disallowed side. Supports a revertMode for the `_exec`-bubble
///         test.
contract MockICHIVault {
    string public constant name = "Mock ICHI LP";
    string public constant symbol = "mICHI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public token0;
    address public token1;
    bool public allowToken0 = true;
    bool public allowToken1 = true;
    uint256 public pricePerShare = 1e18; // shares = (d0+d1) * 1e18 / pricePerShare
    uint8 public revertMode; // 0 = normal, 1 = custom-error revert, 2 = no-data revert

    error VaultBoom();
    error DisallowedSide();

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setPricePerShare(uint256 p) external {
        pricePerShare = p;
    }

    function setAllow(bool a0, bool a1) external {
        allowToken0 = a0;
        allowToken1 = a1;
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

    function deposit(uint256 deposit0, uint256 deposit1, address to) external returns (uint256 shares) {
        if (revertMode == 1) revert VaultBoom();
        if (revertMode == 2) {
            assembly {
                revert(0, 0)
            }
        }
        require(to != address(0), "IV.to=0");
        if (deposit0 != 0) {
            if (!allowToken0) revert DisallowedSide();
            IERC20(token0).transferFrom(msg.sender, address(this), deposit0);
        }
        if (deposit1 != 0) {
            if (!allowToken1) revert DisallowedSide();
            IERC20(token1).transferFrom(msg.sender, address(this), deposit1);
        }
        shares = (deposit0 + deposit1) * 1e18 / pricePerShare;
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    /// @notice Burn `shares` from `msg.sender` and return the proportional token0/token1 the vault holds, to `to`.
    ///         Faithful enough for the module's `removeLiquidity` seam (the real ICHI `withdraw` decomposes the LP).
    function withdraw(uint256 shares, address to) external returns (uint256 amount0, uint256 amount1) {
        if (revertMode == 1) revert VaultBoom();
        if (revertMode == 2) {
            assembly {
                revert(0, 0)
            }
        }
        require(to != address(0), "IV.to=0");
        uint256 ts = totalSupply;
        amount0 = IERC20(token0).balanceOf(address(this)) * shares / ts;
        amount1 = IERC20(token1).balanceOf(address(this)) * shares / ts;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        if (amount0 != 0) IERC20(token0).transfer(to, amount0);
        if (amount1 != 0) IERC20(token1).transfer(to, amount1);
    }
}

/// @notice A faithful Solidly-style gauge over the LP token: `deposit` pulls the LP from `msg.sender` via
///         `transferFrom`, `withdraw` returns it; `balanceOf` is the staked amount.
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

/// @notice A recording mock Safe (Zodiac avatar surface). Records every `(to, value, data, operation)`, optionally
///         performs the call live, and can force a specific exec index to fail. Modeled verbatim on
///         `FarmUtilityLoopModule.t.sol` / `SzipBuyBurnModule.t.sol`.
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

// =========================================================================== unit tests (no fork)

/// @dev A settable coverage gate (`ICoverageGate`) for the removeLiquidity excess-bound test.
contract MockCoverageGate {
    bool public ret;

    function set(bool v) external {
        ret = v;
    }

    function lpBurnKeepsCovered(uint256) external view returns (bool) {
        return ret;
    }
}

contract LpStrategyModuleUnitTest is Test {
    LpStrategyModule internal m;
    RecordingSafe internal safe;
    MockICHIVault internal vault;
    MockGauge internal gauge;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    function setUp() public {
        token0 = new MockERC20();
        token1 = new MockERC20();
        vault = new MockICHIVault(address(token0), address(token1));
        gauge = new MockGauge(address(vault), address(0xDEAD));
        safe = new RecordingSafe();
        m = _cloneLpStrategyModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(vault), address(gauge), address(0)));
    }

    /// @dev SEC-14: the bare mastercopy is init-locked in its ctor; `setUp` on it reverts AlreadyInitialized.
    function test_SEC14_mastercopy_setUp_reverts() public {
        LpStrategyModule mc = new LpStrategyModule();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mc.setUp(abi.encode(owner, address(safe), operator, address(vault), address(gauge), address(0)));
    }

    // ----------------------------------------------------------------- setUp / authority / locks

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.juniorTrancheEngine(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.ichiVault(), address(vault));
        assertEq(m.gauge(), address(gauge));
        assertEq(m.token0(), address(token0));
        assertEq(m.token1(), address(token1));
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(abi.encode(owner, address(safe), operator, address(vault), address(gauge), address(0)));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        LpStrategyModule x = _cloneLpStrategyModule();
        vm.expectRevert(LpStrategyModule.OwnerIsOperator.selector);
        x.setUp(abi.encode(owner, address(safe), owner, address(vault), address(gauge), address(0)));
    }

    function test_setUp_rejects_zero_gauge() public {
        LpStrategyModule x = _cloneLpStrategyModule();
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(vault), address(0), address(0)));
    }

    function test_setUp_rejects_zero_ichiVault_at_guard_not_staticcall() public {
        // ichiVault == 0 must revert ZeroAddress (the guard runs BEFORE the live token0() read).
        LpStrategyModule x = _cloneLpStrategyModule();
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(0), address(gauge), address(0)));
    }

    function test_setUp_rejects_zero_juniorTrancheEngine() public {
        LpStrategyModule x = _cloneLpStrategyModule();
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(0), operator, address(vault), address(gauge), address(0)));
    }

    function test_setUp_rejects_zero_token_leg() public {
        // a vault returning token0() == 0 must revert ZeroAddress on the live read.
        MockICHIVault badVault = new MockICHIVault(address(0), address(token1));
        LpStrategyModule x = _cloneLpStrategyModule();
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(badVault), address(gauge), address(0)));
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    /// @dev The six build-phase wiring setters (besides `setCoverageGate`, covered by the coverage-gate test): each is
    ///      `onlyOwner`, non-zero-guarded, and takes effect. Also pins the two LpStrategy-specific behaviors its
    ///      siblings test but this suite was missing: `setOperator`'s SEC-15 owner-recheck, and
    ///      `setJuniorTrancheEngine` keeping `avatar`/`target` in lockstep.
    function test_wiring_setters_onlyOwner_effect_and_zeroGuard() public {
        address x = makeAddr("rewire");

        // non-owner rejected on every setter
        vm.startPrank(rando);
        bytes memory unauth = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando);
        vm.expectRevert(unauth);
        m.setJuniorTrancheEngine(x);
        vm.expectRevert(unauth);
        m.setOperator(x);
        vm.expectRevert(unauth);
        m.setIchiVault(x);
        vm.expectRevert(unauth);
        m.setGauge(x);
        vm.expectRevert(unauth);
        m.setToken0(x);
        vm.expectRevert(unauth);
        m.setToken1(x);
        vm.stopPrank();

        // owner re-point takes effect
        vm.startPrank(owner);
        m.setOperator(x);
        assertEq(m.operator(), x, "operator re-pointed");
        m.setIchiVault(x);
        assertEq(m.ichiVault(), x, "ichiVault re-pointed");
        m.setGauge(x);
        assertEq(m.gauge(), x, "gauge re-pointed");
        m.setToken0(x);
        assertEq(m.token0(), x, "token0 re-pointed");
        m.setToken1(x);
        assertEq(m.token1(), x, "token1 re-pointed");

        // setJuniorTrancheEngine keeps avatar/target in lockstep
        address newEngine = makeAddr("newEngine");
        m.setJuniorTrancheEngine(newEngine);
        assertEq(m.juniorTrancheEngine(), newEngine, "juniorTrancheEngine re-pointed");
        assertEq(m.avatar(), newEngine, "avatar synced to juniorTrancheEngine");
        assertEq(m.target(), newEngine, "target synced to juniorTrancheEngine");

        // SEC-15: setOperator must preserve owner != operator (re-pointing operator to owner reverts)
        vm.expectRevert(LpStrategyModule.OwnerIsOperator.selector);
        m.setOperator(owner);

        // zero rejected on every setter
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setJuniorTrancheEngine(address(0));
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setOperator(address(0));
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setIchiVault(address(0));
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setGauge(address(0));
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setToken0(address(0));
        vm.expectRevert(LpStrategyModule.ZeroAddress.selector);
        m.setToken1(address(0));
        vm.stopPrank();
    }

    function test_mastercopy_inert() public {
        LpStrategyModule mc = _cloneLpStrategyModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.juniorTrancheEngine(), address(0));
        assertEq(mc.ichiVault(), address(0));
        assertEq(mc.gauge(), address(0));
        assertEq(mc.token0(), address(0));
        assertEq(mc.token1(), address(0));
        vm.startPrank(operator);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        mc.addLiquidity(1e18, 0, 1);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        mc.stake(1e18);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        mc.unstake(1e18);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        mc.removeLiquidity(1e18, 0, 0);
        vm.stopPrank();
    }

    function test_entrypoints_only_operator() public {
        vm.startPrank(rando);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        m.addLiquidity(1e18, 0, 1);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        m.stake(1e18);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        m.unstake(1e18);
        vm.stopPrank();
    }

    function test_zero_amount_reverts() public {
        vm.startPrank(operator);
        vm.expectRevert(LpStrategyModule.ZeroAmount.selector);
        m.addLiquidity(0, 0, 1);
        vm.expectRevert(LpStrategyModule.ZeroAmount.selector);
        m.stake(0);
        vm.expectRevert(LpStrategyModule.ZeroAmount.selector);
        m.unstake(0);
        vm.stopPrank();
    }

    function test_zero_minShares_reverts() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.ZeroMinShares.selector);
        m.addLiquidity(50e18, 0, 0);
    }

    // ----------------------------------------------------------------- add: vault-agnostic passthrough, non-1:1 price

    /// @dev The module is intentionally VAULT-AGNOSTIC: it forwards (deposit0, deposit1) unchanged. Single-sidedness
    ///      is the WIRED VAULT's property (its allowToken0/1), NOT a module gate — our production single-sided zipUSD
    ///      YieldIQ vault rejects a both-legs deposit (see test_fork_disallowed_side_reverts /
    ///      test_disallowed_side_bubbles_on_mock). A both-legs add is NOT a supported product flow; this test only
    ///      pins that the MODULE itself never blocks the passthrough (so the ICHI vault config can be finalized later
    ///      without re-authoring the module).
    function test_addLiquidity_vault_agnostic_passthrough_non_unit_price() public {
        safe.setLive(true);
        vault.setPricePerShare(2e18); // shares = (d0+d1)/2 -> non-1:1
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);

        // single-sided token0 (the production shape)
        vm.prank(operator);
        uint256 s0 = m.addLiquidity(100e18, 0, 1);
        assertEq(s0, 50e18, "single-sided shares = d0/2");
        assertTrue(s0 != 100e18, "non-1:1 share price exercised");
        assertEq(m.lpBalance(), s0, "lpBalance == returned shares");

        // single-sided token1
        vm.prank(operator);
        uint256 s1 = m.addLiquidity(0, 40e18, 1);
        assertEq(s1, 20e18, "single-sided token1 shares = d1/2");

        // both legs (permissive mock allows both) -> the module forwards them unchanged (vault-agnostic property).
        vm.prank(operator);
        uint256 sb = m.addLiquidity(100e18, 100e18, 1);
        assertEq(sb, 100e18, "both-legs passthrough shares = (d0+d1)/2");
        assertEq(m.lpBalance(), s0 + s1 + sb, "cumulative LP in the Safe");
        assertEq(token0.balanceOf(address(vault)), 200e18, "token0 pulled (100 + 100)");
        assertEq(token1.balanceOf(address(vault)), 140e18, "token1 pulled (40 + 100)");
    }

    function test_addLiquidity_slippage_floor() public {
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        // pricePerShare 1e18 -> shares == d0 == 100e18; minShares 100e18+1 must revert Slippage.
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.Slippage.selector);
        m.addLiquidity(100e18, 0, 100e18 + 1);
        // at exactly the achievable floor it passes.
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
        assertEq(safe.callCount(), 3, "single-sided add = 3 execs");
        _assertCall(0, address(token0), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(50e18)));
        _assertCall(1, address(vault), abi.encodeCall(IICHIVault.deposit, (50e18, 0, address(safe))));
        _assertCall(2, address(token0), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(0)));
        // the deposit `to` arg is the engine Safe (regression guard).
        (, , bytes memory data, ) = safe.getCall(1);
        ( , , address to) = abi.decode(_slice(data, 4), (uint256, uint256, address));
        assertEq(to, address(safe), "deposit to == juniorTrancheEngine");
    }

    /// @dev The both-legs exec shape (vault-agnostic passthrough — 5 execs). NOT a supported product flow; pins the
    ///      module's calldata discipline when forwarding both legs.
    function test_exec_discipline_addLiquidity_both_legs() public {
        safe.setLive(true);
        token0.mint(address(safe), 1000e18);
        token1.mint(address(safe), 1000e18);
        vm.prank(operator);
        m.addLiquidity(30e18, 70e18, 1);
        assertEq(safe.callCount(), 5, "both-legs add = 5 execs");
        _assertCall(0, address(token0), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(30e18)));
        _assertCall(1, address(token1), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(70e18)));
        _assertCall(2, address(vault), abi.encodeCall(IICHIVault.deposit, (30e18, 70e18, address(safe))));
        _assertCall(3, address(token0), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(0)));
        _assertCall(4, address(token1), abi.encodeWithSelector(IERC20.approve.selector, address(vault), uint256(0)));
    }

    function test_exec_discipline_stake_and_unstake() public {
        safe.setLive(true);
        // give the Safe LP to stake (mint vault shares directly).
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 0, 1); // safe now holds 100e18 LP (price 1e18)
        uint256 base = safe.callCount();

        vm.prank(operator);
        m.stake(60e18);
        assertEq(safe.callCount() - base, 3, "stake = 3 execs");
        _assertCall(base + 0, address(vault), abi.encodeWithSelector(IERC20.approve.selector, address(gauge), uint256(60e18)));
        _assertCall(base + 1, address(gauge), abi.encodeCall(IGauge.deposit, (uint256(60e18))));
        _assertCall(base + 2, address(vault), abi.encodeWithSelector(IERC20.approve.selector, address(gauge), uint256(0)));

        uint256 base2 = safe.callCount();
        vm.prank(operator);
        m.unstake(20e18);
        assertEq(safe.callCount() - base2, 1, "unstake = 1 exec");
        _assertCall(base2 + 0, address(gauge), abi.encodeCall(IGauge.withdraw, (uint256(20e18))));
    }

    // ----------------------------------------------------------------- removeLiquidity (the wind-down LP->legs hop)

    function test_removeLiquidity_returns_legs_to_safe_and_emits() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        token1.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 shares = m.addLiquidity(100e18, 100e18, 1); // both legs into the vault (permissive mock)
        uint256 baseT0 = token0.balanceOf(address(safe));
        uint256 baseT1 = token1.balanceOf(address(safe));

        vm.expectEmit(false, false, false, true, address(m));
        emit LpStrategyModule.LiquidityRemoved(shares, 100e18, 100e18);
        vm.prank(operator);
        (uint256 a0, uint256 a1) = m.removeLiquidity(shares, 1, 1);

        assertEq(a0, 100e18, "all token0 returned");
        assertEq(a1, 100e18, "all token1 returned");
        assertEq(token0.balanceOf(address(safe)) - baseT0, 100e18, "token0 landed in the Safe");
        assertEq(token1.balanceOf(address(safe)) - baseT1, 100e18, "token1 landed in the Safe");
        assertEq(m.lpBalance(), 0, "LP burned");
    }

    function test_removeLiquidity_zero_reverts() public {
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.ZeroAmount.selector);
        m.removeLiquidity(0, 0, 0);
    }

    function test_removeLiquidity_zero_minAmount_reverts() public {
        // both floors zero -> ZeroMinAmount (the sole sandwich guard on the router-less ICHI withdraw)
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.ZeroMinAmount.selector);
        m.removeLiquidity(1e18, 0, 0);

        // a single non-zero floor passes the guard and reaches the dissolve path
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 shares = m.addLiquidity(100e18, 0, 1);
        vm.prank(operator);
        (uint256 a0,) = m.removeLiquidity(shares, 1, 0);
        assertEq(a0, 100e18, "single non-zero floor passes the guard");
    }

    function test_removeLiquidity_coverage_gate() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 shares = m.addLiquidity(100e18, 0, 1);

        MockCoverageGate gate = new MockCoverageGate();
        vm.prank(owner);
        m.setCoverageGate(address(gate));

        // gate says dissolution would breach coverage -> revert Undercovered
        gate.set(false);
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.Undercovered.selector);
        m.removeLiquidity(shares, 1, 0);

        // gate says still covered (excess) -> dissolution clears
        gate.set(true);
        vm.prank(operator);
        (uint256 a0,) = m.removeLiquidity(shares, 1, 0);
        assertEq(a0, 100e18, "dissolved once within the excess");

        // gate OFF (address 0) -> ungated legacy behavior
        vm.prank(owner);
        m.setCoverageGate(address(0));
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 s2 = m.addLiquidity(100e18, 0, 1);
        vm.prank(operator);
        m.removeLiquidity(s2, 1, 0); // no gate -> ok
        assertEq(m.lpBalance(), 0, "ungated dissolution ok");
    }

    function test_removeLiquidity_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(LpStrategyModule.NotOperator.selector);
        m.removeLiquidity(1e18, 0, 0);
    }

    function test_removeLiquidity_slippage_floor() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 shares = m.addLiquidity(100e18, 0, 1); // single-sided; vault holds 100 token0
        // withdraw returns 100e18 token0, 0 token1 -> minAmount0 one above the floor reverts Slippage.
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.Slippage.selector);
        m.removeLiquidity(shares, 100e18 + 1, 0);
        // at the achievable floor it passes.
        vm.prank(operator);
        (uint256 a0,) = m.removeLiquidity(shares, 100e18, 0);
        assertEq(a0, 100e18);
    }

    function test_exec_discipline_removeLiquidity() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        uint256 shares = m.addLiquidity(100e18, 0, 1);
        uint256 base = safe.callCount();
        vm.prank(operator);
        m.removeLiquidity(shares, 1, 0);
        assertEq(safe.callCount() - base, 1, "removeLiquidity = 1 exec");
        _assertCall(base + 0, address(vault), abi.encodeCall(IICHIVault.withdraw, (shares, address(safe))));
    }

    // ----------------------------------------------------------------- views read juniorTrancheEngine (not address(this))

    function test_views_read_juniorTrancheEngine() public {
        safe.setLive(true);
        // stranger LP doesn't show up.
        MockICHIVault(address(vault));
        // mint LP to a stranger -> views stay 0.
        vm.prank(address(this));
        // directly credit the stranger by depositing on its behalf is awkward; instead mint via a deposit to stranger.
        // Simpler: stranger has no LP, gauge balance 0.
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

    // ----------------------------------------------------------------- atomicity / rollback (fail-index)

    function test_atomicity_addLiquidity_single_deposit_fail_rolls_back() public {
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // the deposit (index 1: [0] approve, [1] deposit)
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert();
        m.addLiquidity(50e18, 0, 1);
        assertEq(token0.allowance(address(safe), address(vault)), 0, "approve rolled back");
    }

    /// @dev Both-legs (vault-agnostic passthrough) atomicity: a forced deposit revert rolls back BOTH approvals.
    function test_atomicity_addLiquidity_both_legs_resets_both() public {
        safe.setLive(true);
        safe.setFailOnCallIndex(2); // the deposit (index 2: [0] approve0, [1] approve1, [2] deposit)
        token0.mint(address(safe), 100e18);
        token1.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert();
        m.addLiquidity(30e18, 70e18, 1);
        assertEq(token0.allowance(address(safe), address(vault)), 0, "token0 approve rolled back");
        assertEq(token1.allowance(address(safe), address(vault)), 0, "token1 approve rolled back");
    }

    function test_atomicity_stake_deposit_fail_rolls_back() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vm.prank(operator);
        m.addLiquidity(100e18, 0, 1);
        safe.setFailOnCallIndex(safe.callCount() + 1); // the gauge.deposit (index 1 within stake: [0] approve, [1] deposit)
        vm.prank(operator);
        vm.expectRevert();
        m.stake(40e18);
        assertEq(IERC20(address(vault)).allowance(address(safe), address(gauge)), 0, "LP approve rolled back");
    }

    // ----------------------------------------------------------------- _exec bubbles

    function test_exec_bubbles_custom_error() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vault.setRevertMode(1); // VaultBoom()
        vm.prank(operator);
        vm.expectRevert(MockICHIVault.VaultBoom.selector);
        m.addLiquidity(50e18, 0, 1);
    }

    function test_exec_bubbles_no_data_falls_back_to_ExecFailed() public {
        safe.setLive(true);
        token0.mint(address(safe), 100e18);
        vault.setRevertMode(2); // revert(0,0) -> no data
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.ExecFailed.selector);
        m.addLiquidity(50e18, 0, 1);
    }

    function test_disallowed_side_bubbles_on_mock() public {
        // mirror the fork disallowed-side: a token1-disallowed vault reverts DisallowedSide (bubbled, not ExecFailed).
        safe.setLive(true);
        vault.setAllow(true, false);
        token1.mint(address(safe), 100e18);
        vm.prank(operator);
        vm.expectRevert(MockICHIVault.DisallowedSide.selector);
        m.addLiquidity(0, 50e18, 1);
    }

    // ----------------------------------------------------------------- helpers

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

// =========================================================================== fork tests (live Base)

/// @notice Fork tests against live Base: a real ICHI vault single-sided deposit (real ICHI bytecode), the gauge/Voter
///         signature verification, and the full add→stake→unstake→re-stake cycle against a real summoned substrate
///         Safe (mock gauge — our ALM zipUSD/xALPHA gauge does not exist yet, the §4.5.1 stand-in posture).
contract LpStrategyModuleForkTest is ForkConfig, SummonSubstrate {
    // -- live Base test-only fork targets (NOT our production vault/gauge; not added to BaseAddresses) --
    address internal constant LIVE_ICHI_VAULT = 0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad; // single-sided WETH/USDC
    address internal constant LIVE_GAUGE = 0xAC396CabF5832A49483B78225D902C0999829993; // HYDX/USDC gauge
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // the live vault's token0

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");

    uint256 internal constant SALT = uint256(keccak256("zipcode.lp.8b6.salt.a"));

    function setUp() public {
        _selectBaseFork();
    }

    /// @dev Summon a real substrate + enable the module on its main Safe (team-owner drives the enable). Model
    ///      `FarmUtilityLoopModule.t.sol _summonAndEnable`.
    function _summonAndEnable(LpStrategyModule m) internal returns (address juniorTrancheSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        juniorTrancheSafe = s.juniorTrancheSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(juniorTrancheSafe).execTransaction(juniorTrancheSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    // ----------------------------------------------------------------- real ICHI vault single-sided deposit

    function test_fork_real_vault_single_sided_deposit() public {
        LpStrategyModule m = _cloneLpStrategyModule();
        address juniorTrancheEngine = _summonAndEnable(m);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, LIVE_ICHI_VAULT, LIVE_GAUGE, address(0)));

        // the module read token0/token1 live off the real vault.
        assertEq(m.token0(), WETH, "token0 == WETH (live read)");
        assertEq(m.token1(), BaseAddresses.USDC, "token1 == USDC (live read)");

        uint256 amt = 1e18; // 1 WETH, well within deposit0Max (4000 WETH)
        deal(WETH, juniorTrancheEngine, amt);

        vm.prank(operator);
        uint256 shares = m.addLiquidity(amt, 0, 1);
        assertGt(shares, 0, "real ICHI deposit minted LP shares");
        assertEq(IICHIVault(LIVE_ICHI_VAULT).balanceOf(juniorTrancheEngine), shares, "shares landed in the Safe");
        assertEq(m.lpBalance(), shares, "lpBalance() reads the real vault");
        assertEq(IERC20(WETH).allowance(juniorTrancheEngine, LIVE_ICHI_VAULT), 0, "no standing WETH allowance");
    }

    function test_fork_slippage_floor_snapshot_guarded() public {
        LpStrategyModule m = _cloneLpStrategyModule();
        address juniorTrancheEngine = _summonAndEnable(m);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, LIVE_ICHI_VAULT, LIVE_GAUGE, address(0)));

        uint256 amt = 1e18;
        deal(WETH, juniorTrancheEngine, amt);

        // probe the achievable shares, then revert so the probe's deposit doesn't grow the pool.
        // NOTE: `snapshot()`/`revertTo()` are deprecated aliases in this forge-std pin (the repo's other fork tests
        // use them too); the renamed `snapshotState`/`revertToState` are not yet in this version.
        uint256 snap = vm.snapshot();
        vm.prank(operator);
        uint256 probed = m.addLiquidity(amt, 0, 1);
        vm.revertTo(snap);

        // re-run with minShares one above the achievable floor -> Slippage.
        deal(WETH, juniorTrancheEngine, amt);
        vm.prank(operator);
        vm.expectRevert(LpStrategyModule.Slippage.selector);
        m.addLiquidity(amt, 0, probed + 1);
    }

    function test_fork_disallowed_side_reverts() public {
        // the live vault is single-sided WETH-only (allowToken1 == false); a token1(USDC) deposit fails closed
        // (bubbled vault revert, not a generic ExecFailed).
        assertFalse(IICHIVault(LIVE_ICHI_VAULT).allowToken1(), "live vault is token0-only");

        LpStrategyModule m = _cloneLpStrategyModule();
        address juniorTrancheEngine = _summonAndEnable(m);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, LIVE_ICHI_VAULT, LIVE_GAUGE, address(0)));

        deal(BaseAddresses.USDC, juniorTrancheEngine, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(); // bubbled from the real ICHI vault
        m.addLiquidity(0, 1_000e6, 1);
    }

    // ----------------------------------------------------------------- gauge / Voter sig-verify (view selectors)

    function test_fork_gauge_and_voter_sig_verify() public view {
        // VIEW selectors the test can soundly resolve read-only.
        assertEq(IGauge(LIVE_GAUGE).rewardToken(), BaseAddresses.OHYDX, "gauge.rewardToken() == oHYDX");
        assertEq(IGauge(LIVE_GAUGE).balanceOf(address(this)), 0, "gauge.balanceOf resolves");
        assertEq(
            IVoter(BaseAddresses.HYDREX_VOTER).gauges(BaseAddresses.HYDX_USDC_POOL),
            LIVE_GAUGE,
            "Voter.gauges(pool) resolves to the gauge"
        );
    }

    // ----------------------------------------------------------------- full cycle (real Safe + mock vault + mock gauge)

    function test_fork_full_cycle_real_safe_mock_lp() public {
        // our zipUSD/xALPHA ICHI vault + ALM gauge do not exist -> mock them; the Safe is the REAL summoned substrate.
        MockERC20 z = new MockERC20();
        MockERC20 x = new MockERC20();
        MockICHIVault vault = new MockICHIVault(address(z), address(x));
        MockGauge gauge = new MockGauge(address(vault), address(0xBEEF));

        LpStrategyModule m = _cloneLpStrategyModule();
        address juniorTrancheEngine = _summonAndEnable(m);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(vault), address(gauge), address(0)));

        // fund the Safe with zipUSD (the single-sided deposit leg).
        z.mint(juniorTrancheEngine, 1000e18);

        // build LP (single-sided zipUSD — the production shape; the xALPHA leg accrues from pool flow, not a deposit).
        vm.prank(operator);
        uint256 shares = m.addLiquidity(700e18, 0, 1);
        assertEq(m.lpBalance(), shares, "LP minted to the Safe");
        assertEq(m.stakedBalance(), 0, "nothing staked yet");

        // stake all.
        vm.prank(operator);
        m.stake(shares);
        assertEq(m.stakedBalance(), shares, "all LP staked");
        assertEq(m.lpBalance(), 0, "LP moved to the gauge");

        // unstake / re-stake a slice twice (the 8-B5 loop steps 1 + 7).
        uint256 slice = shares / 4;
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(operator);
            m.unstake(slice);
            assertEq(m.stakedBalance(), shares - slice, "slice unstaked");
            assertEq(m.lpBalance(), slice, "slice back in the Safe");

            vm.prank(operator);
            m.stake(slice);
            assertEq(m.stakedBalance(), shares, "slice re-staked");
            assertEq(m.lpBalance(), 0, "LP back in the gauge");
        }
    }
}
