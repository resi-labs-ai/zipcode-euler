// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {ESynth} from "evk/Synths/ESynth.sol";

import {RecycleModule, IZipDepositModule, IEulerEarn} from "../src/supply/szipUSD/RecycleModule.sol";
import {ZipDepositModule} from "../src/supply/ZipDepositModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe (Zodiac avatar surface) — copied from `SellModule.t.sol`. Records every
///         `(to, value, data, operation)`, can perform the call live, can force an exec index to fail, and returns a
///         settable `_returnData` from the NON-live path (the `deposit`'s zipMinted decode).
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

/// @dev Configurable-decimals ERC20 with a real `transfer` (the ZipDepositModule pull needs it).
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
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

/// @dev A par EulerEarn mock (itself the share token): `deposit` pulls the full assets, mints par shares to receiver.
contract EEMock is MockERC20 {
    address public immutable asset;

    constructor(address asset_) MockERC20(6) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        MockERC20(asset).transferFrom(msg.sender, address(this), assets);
        shares = assets;
        // par mint
        // (use the inherited storage via a self-call-free direct write through `mint`)
        MockERC20(address(this)).mint(receiver, shares);
        return shares;
    }
}

/// @dev Proves DECREMENT-BEFORE-EXEC: its `deposit` reads back the module's `freeValueAccrued` mid-call, so the test
///      can assert the spend was ALREADY applied at exec #2 time (a re-entrant spend could not double-spend).
contract ReadbackZipDepositModule {
    RecycleModule public module;
    uint256 public observed;
    bool public did;

    function setModule(RecycleModule m) external {
        module = m;
    }

    function deposit(uint256) external returns (uint256) {
        observed = module.freeValueAccrued();
        did = true;
        return 777;
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

/// @dev A settable `SzipNavOracle.provision()` stand-in (the Stream-2 hole size).
contract MockNavProvision {
    uint256 public provision;

    function setProvision(uint256 p) external {
        provision = p;
    }
}

/// @dev A STINGY EulerEarn pool: pulls the full USDC (so hard-backing passes) but mints NO shares to the receiver →
///      proves `divert`'s `NoSharesMinted` liveness guard fires when a pool no-ops the share credit.
contract StingyEEMock is MockERC20 {
    address public immutable asset;

    constructor(address asset_) MockERC20(6) {
        asset = asset_;
    }

    function deposit(uint256 assets, address /*receiver*/ ) external returns (uint256) {
        MockERC20(asset).transferFrom(msg.sender, address(this), assets);
        return 0; // no shares minted to the receiver
    }
}

/// @dev A FREE-MINT EulerEarn pool: mints shares to the receiver WITHOUT pulling any USDC → proves `divert`'s
///      `BackingShortfall` hard-backing guard fires (the share-rose alone is a liveness check, not value-moved).
contract FreeMintEEMock is MockERC20 {
    address public immutable asset;

    constructor(address asset_) MockERC20(6) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        MockERC20(address(this)).mint(receiver, shares); // shares minted, but NO USDC pulled from the Safe
        return shares;
    }
}

/// @dev A par EulerEarn pool that, INSIDE `deposit`, reads back the module's `freeValueAccrued` (the CEI probe — proves
///      the `_spendFreeValue` decrement landed BEFORE the value-moving deposit exec), then performs a real par deposit.
contract ReadbackEEMock is MockERC20 {
    address public immutable asset;
    RecycleModule public module;
    uint256 public observed;
    bool public did;

    constructor(address asset_) MockERC20(6) {
        asset = asset_;
    }

    function setModule(RecycleModule m) external {
        module = m;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        observed = module.freeValueAccrued(); // mid-call read
        did = true;
        MockERC20(asset).transferFrom(msg.sender, address(this), assets); // real pull (hard-backing passes)
        shares = assets;
        MockERC20(address(this)).mint(receiver, shares); // real share credit (liveness passes)
        return shares;
    }
}

// =========================================================================== unit tests (no fork)

contract RecycleModuleUnitTest is Test {
    RecycleModule internal m;
    RecordingSafe internal safe;
    MockERC20 internal usdc;
    address internal zdm = makeAddr("zipDepositModule");

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    // Dummy nonzero wiring for the three Stream-2 slots in recycle-only tests (these tests never exercise `divert`,
    // so plausible-but-unused addresses are fine; the divert suite below wires real mocks).
    address internal constant NAVO = address(0xA01);
    address internal constant EEP = address(0xA02);
    address internal constant WH = address(0xA03);

    event FreeValueCredited(uint256 amount, uint256 newAccrued);
    event FreeValueSpent(uint256 amount, uint256 newAccrued);
    event Recycled(uint256 usdcAmount, uint256 zipMinted);
    event WiringSet(bytes32 indexed slot, address value);

    function setUp() public {
        usdc = new MockERC20(6);
        safe = new RecordingSafe();
        m = new RecycleModule();
        m.setUp(_params(owner, address(safe), operator, zdm, address(usdc)));
    }

    /// @dev 5-arg facade over the 8-arg setUp: appends the three Stream-2 dummies (recycle-only tests don't use them).
    function _params(address o, address s, address op, address z, address u) internal pure returns (bytes memory) {
        return abi.encode(o, s, op, z, u, NAVO, EEP, WH);
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
        assertEq(m.engineSafe(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.zipDepositModule(), zdm);
        assertEq(m.usdc(), address(usdc));
        assertEq(m.navOracle(), NAVO);
        assertEq(m.eePool(), EEP);
        assertEq(m.warehouse(), WH);
        assertEq(m.freeValueAccrued(), 0);
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(_params(owner, address(safe), operator, zdm, address(usdc)));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        RecycleModule x = new RecycleModule();
        vm.expectRevert(RecycleModule.OwnerIsOperator.selector);
        x.setUp(_params(owner, address(safe), owner, zdm, address(usdc)));
    }

    function test_setUp_rejects_zero_in_each_of_eight() public {
        // positions 1-5 (existing) via the facade...
        _expectZero(_params(address(0), address(safe), operator, zdm, address(usdc)));
        _expectZero(_params(owner, address(0), operator, zdm, address(usdc)));
        _expectZero(_params(owner, address(safe), address(0), zdm, address(usdc)));
        _expectZero(_params(owner, address(safe), operator, address(0), address(usdc)));
        _expectZero(_params(owner, address(safe), operator, zdm, address(0)));
        // ...positions 6-8 (the Stream-2 slots) encoded explicitly so a zero can be injected.
        _expectZero(abi.encode(owner, address(safe), operator, zdm, address(usdc), address(0), EEP, WH));
        _expectZero(abi.encode(owner, address(safe), operator, zdm, address(usdc), NAVO, address(0), WH));
        _expectZero(abi.encode(owner, address(safe), operator, zdm, address(usdc), NAVO, EEP, address(0)));
    }

    function _expectZero(bytes memory params) internal {
        RecycleModule x = new RecycleModule();
        vm.expectRevert(RecycleModule.ZeroAddress.selector);
        x.setUp(params);
    }

    function test_setUp_abi_length_mismatch_reverts() public {
        RecycleModule x = new RecycleModule();
        // only 7 addresses encoded (warehouse missing) -> abi.decode reverts (the decode needs 8)
        vm.expectRevert();
        x.setUp(abi.encode(owner, address(safe), operator, zdm, address(usdc), NAVO, EEP));
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
        RecycleModule mc = new RecycleModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.engineSafe(), address(0));
        assertEq(mc.zipDepositModule(), address(0));
        assertEq(mc.usdc(), address(0));
        assertEq(mc.navOracle(), address(0));
        assertEq(mc.eePool(), address(0));
        assertEq(mc.warehouse(), address(0));
        vm.prank(operator);
        vm.expectRevert(RecycleModule.NotOperator.selector);
        mc.creditFreeValue(1e6);
    }

    // ----------------------------------------------------------------- the three Stream-2 wiring setters

    function test_stream2_setters_repoint_only_owner() public {
        // non-owner reverts
        vm.startPrank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setNavOracle(address(0xB01));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setEePool(address(0xB02));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setWarehouse(address(0xB03));
        vm.stopPrank();

        // zero reverts ZeroAddress
        vm.startPrank(owner);
        vm.expectRevert(RecycleModule.ZeroAddress.selector);
        m.setNavOracle(address(0));
        vm.expectRevert(RecycleModule.ZeroAddress.selector);
        m.setEePool(address(0));
        vm.expectRevert(RecycleModule.ZeroAddress.selector);
        m.setWarehouse(address(0));

        // owner re-points, each emits WiringSet with the correct slot label
        vm.expectEmit(true, false, false, true, address(m));
        emit WiringSet("navOracle", address(0xB01));
        m.setNavOracle(address(0xB01));
        vm.expectEmit(true, false, false, true, address(m));
        emit WiringSet("eePool", address(0xB02));
        m.setEePool(address(0xB02));
        vm.expectEmit(true, false, false, true, address(m));
        emit WiringSet("warehouse", address(0xB03));
        m.setWarehouse(address(0xB03));
        vm.stopPrank();

        assertEq(m.navOracle(), address(0xB01));
        assertEq(m.eePool(), address(0xB02));
        assertEq(m.warehouse(), address(0xB03));
    }

    // ----------------------------------------------------------------- authority on the action legs

    function test_action_legs_only_operator() public {
        vm.startPrank(rando);
        vm.expectRevert(RecycleModule.NotOperator.selector);
        m.creditFreeValue(1e6);
        vm.expectRevert(RecycleModule.NotOperator.selector);
        m.recycle(1e6);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- accumulator arithmetic + gate

    function test_credit_and_spend_arithmetic() public {
        // credit 100 -> 100
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit FreeValueCredited(100e6, 100e6);
        m.creditFreeValue(100e6);
        assertEq(m.freeValueAccrued(), 100e6);

        // multi-credit running total + event
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit FreeValueCredited(50e6, 150e6);
        m.creditFreeValue(50e6);
        assertEq(m.freeValueAccrued(), 150e6);

        // spend (via recycle) arithmetic: debit 60 -> 90, emits FreeValueSpent then Recycled
        safe.setReturnData(abi.encode(uint256(0)));
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit FreeValueSpent(60e6, 90e6);
        m.recycle(60e6);
        assertEq(m.freeValueAccrued(), 90e6);

        // boundary: spend == accrued -> 0
        vm.prank(operator);
        m.recycle(90e6);
        assertEq(m.freeValueAccrued(), 0);
    }

    function test_credit_zero_amount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ZeroAmount.selector);
        m.creditFreeValue(0);
    }

    function test_recycle_zero_amount_reverts() public {
        vm.prank(operator);
        m.creditFreeValue(10e6);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ZeroAmount.selector);
        m.recycle(0);
    }

    function test_recycle_overspend_leaves_accrued_and_callcount_unchanged() public {
        vm.prank(operator);
        m.creditFreeValue(10e6);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.InsufficientFreeValue.selector);
        m.recycle(11e6);
        assertEq(safe.callCount(), 0, "no exec before the gate");
        assertEq(m.freeValueAccrued(), 10e6, "accrued unchanged");
    }

    // ----------------------------------------------------------------- recycle exec-shape (non-live RecordingSafe)

    function test_recycle_exec_shape_and_decode() public {
        vm.prank(operator);
        m.creditFreeValue(100e6);
        safe.setReturnData(abi.encode(uint256(42e18))); // the deposit's zipMinted (every non-live call returns this)

        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit Recycled(40e6, 42e18);
        uint256 zipMinted = m.recycle(40e6);

        assertEq(zipMinted, 42e18, "decoded zipMinted");
        assertEq(m.freeValueAccrued(), 60e6, "debited");
        assertEq(safe.callCount(), 3, "exactly three recorded calls");
        _assertCall(0, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, zdm, uint256(40e6)));
        _assertCall(1, zdm, abi.encodeCall(IZipDepositModule.deposit, (40e6)));
        _assertCall(2, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, zdm, uint256(0)));
    }

    function test_recycle_malformed_return_reverts() public {
        vm.prank(operator);
        m.creditFreeValue(100e6);
        safe.setReturnData(hex"00112233"); // < 32 bytes -> abi.decode reverts
        vm.prank(operator);
        vm.expectRevert();
        m.recycle(40e6);
    }

    // ----------------------------------------------------------------- atomicity (live RecordingSafe)

    function test_recycle_bubble_on_exec_fail() public {
        vm.prank(operator);
        m.creditFreeValue(100e6);
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // the deposit exec reverts "forced-fail"
        vm.prank(operator);
        vm.expectRevert(bytes("forced-fail"));
        m.recycle(40e6);
        // the atomic revert rolled back the decrement
        assertEq(m.freeValueAccrued(), 100e6, "accrued unchanged after a reverted recycle");
    }

    function test_exec_failed_empty_revert_data() public {
        // a live Safe whose target returns (false, "") -> ExecFailed. Wire `usdc` to a contract that reverts empty,
        // so recycle's first approve -> Safe catches (false, "") -> _exec reverts ExecFailed (not a bubble).
        RevertEmpty re = new RevertEmpty();
        RecycleModule x = new RecycleModule();
        RecordingSafe s2 = new RecordingSafe();
        x.setUp(_params(owner, address(s2), operator, address(re), address(re)));
        s2.setLive(true);
        vm.prank(operator);
        x.creditFreeValue(100e6);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ExecFailed.selector);
        x.recycle(40e6);
    }
}

// =========================================================================== integrated (no fork; real ZipDepositModule)

contract RecycleModuleIntegratedTest is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip;
    MockERC20 internal usdc;
    EEMock internal ee;
    ZipDepositModule internal zdmReal;
    RecycleModule internal m;
    RecordingSafe internal safe;

    address internal constant WAREHOUSE = address(0xBEEF);
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal constant NAVO = address(0xA01); // recycle-only: nav/eePool/warehouse unused on the recycle path

    function setUp() public {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        ee = new EEMock(address(usdc));
        zdmReal = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE);
        zip.setCapacity(address(zdmReal), type(uint128).max);

        safe = new RecordingSafe();
        safe.setLive(true); // drive the REAL ZipDepositModule
        m = new RecycleModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(zdmReal), address(usdc), NAVO, address(ee), WAREHOUSE));
    }

    function test_integrated_recycle_mints_backed_zip_and_debits() public {
        assertEq(zdmReal.scaleUp(), 1e12, "scaleUp 18/6");
        usdc.mint(address(safe), 1_000e6);
        vm.prank(operator);
        m.creditFreeValue(1_000e6);

        vm.prank(operator);
        uint256 zipMinted = m.recycle(1_000e6);

        assertEq(zipMinted, 1_000e6 * 1e12, "zipMinted == amount * scaleUp");
        assertEq(zip.balanceOf(address(safe)), 1_000e6 * 1e12, "backed zipUSD minted to the Safe");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left the Safe");
        assertEq(usdc.balanceOf(address(ee)), 1_000e6, "USDC parked as senior backing");
        assertEq(ee.balanceOf(WAREHOUSE), 1_000e6, "EE shares -> warehouse");
        assertEq(m.freeValueAccrued(), 0, "free value debited exactly");
        assertEq(usdc.allowance(address(safe), address(zdmReal)), 0, "approval reset");
    }

    function test_integrated_decrement_before_exec() public {
        ReadbackZipDepositModule rb = new ReadbackZipDepositModule();
        RecycleModule x = new RecycleModule();
        RecordingSafe s = new RecordingSafe();
        s.setLive(true);
        x.setUp(abi.encode(owner, address(s), operator, address(rb), address(usdc), NAVO, address(ee), WAREHOUSE));
        rb.setModule(x);

        vm.prank(operator);
        x.creditFreeValue(100e6);
        vm.prank(operator);
        x.recycle(40e6); // exec #2 = rb.deposit reads back freeValueAccrued mid-call

        assertTrue(rb.did(), "readback ran");
        assertEq(rb.observed(), 60e6, "the spend was applied BEFORE the deposit exec (effects-before-interaction)");
    }
}

// =========================================================================== fork (live Base; real summoned Safe)

contract RecycleModuleForkTest is ForkConfig, SummonSubstrate {
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");
    address internal constant WAREHOUSE = address(0xBEEF);

    uint256 internal constant SALT = uint256(keccak256("zipcode.recycle.8b10.salt.a"));

    EthereumVaultConnector internal evc;
    ESynth internal zip;
    MockERC20 internal usdc;
    EEMock internal ee;
    MockNavProvision internal nav;
    ZipDepositModule internal zdmReal;

    function setUp() public {
        _selectBaseFork();
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        ee = new EEMock(address(usdc));
        nav = new MockNavProvision();
        zdmReal = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE);
        zip.setCapacity(address(zdmReal), type(uint128).max);
    }

    function _summonAndEnable(RecycleModule m) internal returns (address mainSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        mainSafe = s.mainSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(mainSafe).execTransaction(mainSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _deploy() internal returns (RecycleModule m, address engineSafe) {
        m = new RecycleModule();
        engineSafe = _summonAndEnable(m);
        m.setUp(abi.encode(owner, engineSafe, operator, address(zdmReal), address(usdc), address(nav), address(ee), WAREHOUSE));
    }

    function test_fork_recycle_against_real_safe() public {
        (RecycleModule m, address engineSafe) = _deploy();
        usdc.mint(engineSafe, 1_000e6);
        vm.prank(operator);
        m.creditFreeValue(1_000e6);

        vm.prank(operator);
        uint256 zipMinted = m.recycle(1_000e6);

        assertEq(zipMinted, 1_000e6 * 1e12, "zipMinted exact");
        assertEq(zip.balanceOf(engineSafe), 1_000e6 * 1e12, "backed zipUSD minted to the REAL Safe");
        assertEq(usdc.balanceOf(engineSafe), 0, "USDC left the Safe");
        assertEq(m.freeValueAccrued(), 0, "debited");
        assertEq(usdc.allowance(engineSafe, address(zdmReal)), 0, "approval reset");
    }

    // Stream 2 (`divert`) over a REAL summoned Gnosis Safe — proves the Zodiac exec path for the new leg.
    function test_fork_divert_against_real_safe() public {
        (RecycleModule m, address engineSafe) = _deploy();
        usdc.mint(engineSafe, 1_000e6);
        vm.prank(operator);
        m.creditFreeValue(1_000e6);
        nav.setProvision(2_000e6 * 1e12); // hole large enough for the full divert

        vm.prank(operator);
        uint256 sent = m.divert(1_000e6);

        assertEq(sent, 1_000e6, "sent == usdcAmount");
        assertEq(usdc.balanceOf(engineSafe), 0, "USDC left the REAL Safe into EE");
        assertEq(usdc.balanceOf(address(ee)), 1_000e6, "USDC parked in EE (raw, no zipUSD mint)");
        assertEq(ee.balanceOf(WAREHOUSE), 1_000e6, "EE shares credited to the warehouse");
        assertEq(zip.balanceOf(engineSafe), 0, "NO zipUSD minted (the whole point of Stream 2)");
        assertEq(m.freeValueAccrued(), 0, "ledger debited exactly");
        assertEq(usdc.allowance(engineSafe, address(ee)), 0, "approval reset");
    }
}

// =========================================================================== divert (Stream 2 — no fork; LIVE Safe)

contract RecycleModuleDivertTest is Test {
    RecycleModule internal m;
    RecordingSafe internal safe;
    MockERC20 internal usdc;
    EEMock internal ee;
    MockNavProvision internal nav;

    address internal constant ZDM = address(0xD00); // unused by divert; nonzero for setUp
    address internal constant WAREHOUSE = address(0xBEEF);
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    uint256 internal constant SEED = 1_000_000e6;
    uint256 internal constant BIG_HOLE = 2_000_000e6 * 1e12;

    event FreeValueSpent(uint256 amount, uint256 newAccrued);
    event Filled(uint256 usdcAmount, address indexed warehouse, uint256 provisionAfter);

    function setUp() public {
        usdc = new MockERC20(6);
        ee = new EEMock(address(usdc));
        nav = new MockNavProvision();
        (m, safe) = _rigWith(address(ee));
    }

    /// @dev A fresh LIVE-Safe rig wired to a given EE pool, funded + ledger-seeded + a large hole set.
    function _rigWith(address pool) internal returns (RecycleModule mod, RecordingSafe s) {
        s = new RecordingSafe();
        s.setLive(true);
        mod = new RecycleModule();
        mod.setUp(abi.encode(owner, address(s), operator, ZDM, address(usdc), address(nav), pool, WAREHOUSE));
        usdc.mint(address(s), SEED);
        vm.prank(operator);
        mod.creditFreeValue(SEED);
        nav.setProvision(BIG_HOLE);
    }

    function _assertCall(RecordingSafe s, uint256 i, address to, bytes memory data) internal view {
        (address rto, uint256 rval, bytes memory rdata, uint8 rop) = s.getCall(i);
        assertEq(rto, to, "call to");
        assertEq(rval, 0, "value == 0");
        assertEq(rop, 0, "operation == Call");
        assertEq(rdata, data, "call data");
    }

    // ----------------------------------------------------------------- value flow + exec-shape (LIVE Safe + real EEMock)

    function test_divert_value_flow_and_exec_shape() public {
        uint256 amt = 400_000e6;

        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(m));
        emit FreeValueSpent(amt, SEED - amt);
        vm.expectEmit(true, false, false, true, address(m));
        emit Filled(amt, WAREHOUSE, BIG_HOLE);
        uint256 sent = m.divert(amt);

        assertEq(sent, amt, "sent == usdcAmount");
        // exec-shape: exactly three recorded calls, each value 0 / Call.
        assertEq(safe.callCount(), 3, "three execs");
        _assertCall(safe, 0, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, address(ee), amt));
        _assertCall(safe, 1, address(ee), abi.encodeCall(IEulerEarn.deposit, (amt, WAREHOUSE)));
        _assertCall(safe, 2, address(usdc), abi.encodeWithSelector(IERC20.approve.selector, address(ee), uint256(0)));
        // value flow: USDC left the Safe into EE crediting the warehouse, NO zipUSD, ledger debited, allowance reset.
        assertEq(usdc.balanceOf(address(safe)), SEED - amt, "Safe USDC fell by amt");
        assertEq(usdc.balanceOf(address(ee)), amt, "USDC parked in EE (raw)");
        assertEq(ee.balanceOf(WAREHOUSE), amt, "EE shares credited to the warehouse");
        assertEq(m.freeValueAccrued(), SEED - amt, "ledger debited by amt");
        assertEq(usdc.allowance(address(safe), address(ee)), 0, "approval reset");
    }

    // ----------------------------------------------------------------- bounds (all revert BEFORE any spend/exec)

    function test_divert_zero_amount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ZeroAmount.selector);
        m.divert(0);
        assertEq(safe.callCount(), 0);
        assertEq(m.freeValueAccrued(), SEED, "ledger untouched");
    }

    function test_divert_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(RecycleModule.NotOperator.selector);
        m.divert(1e6);
    }

    function test_divert_no_hole_reverts() public {
        nav.setProvision(0);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.NoHole.selector);
        m.divert(1e6);
        assertEq(safe.callCount(), 0, "no exec before the gate");
        assertEq(m.freeValueAccrued(), SEED, "ledger untouched");
    }

    function test_divert_exceeds_hole_boundary() public {
        uint256 amt = 100_000e6;
        // exact fill (hole == amt * 1e12) -> ALLOWED
        nav.setProvision(amt * 1e12);
        vm.prank(operator);
        m.divert(amt);
        assertEq(ee.balanceOf(WAREHOUSE), amt, "exact fill allowed");

        // hole == amt*1e12 - 1 -> ExceedsHole (revert before spend/exec)
        RecycleModule m2;
        RecordingSafe s2;
        (m2, s2) = _rigWith(address(ee));
        nav.setProvision(amt * 1e12 - 1);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ExceedsHole.selector);
        m2.divert(amt);
        assertEq(s2.callCount(), 0, "no exec on over-hole");
        assertEq(m2.freeValueAccrued(), SEED, "ledger untouched on over-hole");

        // hole == amt*1e12 + 1 -> ALLOWED
        nav.setProvision(amt * 1e12 + 1);
        vm.prank(operator);
        m2.divert(amt);
        assertEq(m2.freeValueAccrued(), SEED - amt, "plus-one fill allowed");
    }

    function test_divert_overflow_panics_before_spend() public {
        // a pathological usdcAmount whose *1e12 overflows uint256 -> Solidity 0.8 Panic(0x11), before _spendFreeValue.
        uint256 huge = type(uint256).max / 1e12 + 1;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        m.divert(huge);
        assertEq(safe.callCount(), 0);
        assertEq(m.freeValueAccrued(), SEED, "ledger untouched");
    }

    // ----------------------------------------------------------------- the two bounds bind independently (min semantics)

    function test_divert_two_bounds_bind() public {
        // Case A: the HOLE binds first. freeValueAccrued huge, hole small -> ExceedsHole.
        nav.setProvision(50_000e6 * 1e12);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ExceedsHole.selector);
        m.divert(60_000e6);
        assertEq(safe.callCount(), 0);

        // Case B: the LEDGER binds first. hole huge, freeValueAccrued small -> InsufficientFreeValue.
        nav.setProvision(BIG_HOLE);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.InsufficientFreeValue.selector);
        m.divert(SEED + 1);
        assertEq(safe.callCount(), 0);
        assertEq(m.freeValueAccrued(), SEED, "ledger untouched on over-ledger");
    }

    // ----------------------------------------------------------------- value guards (hard backing + liveness)

    function test_divert_backing_shortfall() public {
        // a pool that mints shares but does NOT pull USDC -> BackingShortfall (the hard-backing / value guard).
        FreeMintEEMock fm = new FreeMintEEMock(address(usdc));
        (RecycleModule mod,) = _rigWith(address(fm));
        vm.prank(operator);
        vm.expectRevert(RecycleModule.BackingShortfall.selector);
        mod.divert(100_000e6);
        assertEq(mod.freeValueAccrued(), SEED, "ledger rolled back atomically (the guard reverts the whole divert)");
    }

    function test_divert_no_shares_minted() public {
        // a pool that pulls USDC but mints NO shares -> NoSharesMinted (the liveness / FoT guard).
        StingyEEMock st = new StingyEEMock(address(usdc));
        (RecycleModule mod,) = _rigWith(address(st));
        vm.prank(operator);
        vm.expectRevert(RecycleModule.NoSharesMinted.selector);
        mod.divert(100_000e6);
        assertEq(mod.freeValueAccrued(), SEED, "ledger rolled back atomically (the guard reverts the whole divert)");
    }

    // ----------------------------------------------------------------- atomicity (bubble / ExecFailed)

    function test_divert_bubble_on_exec_fail() public {
        safe.setFailOnCallIndex(1); // the deposit exec reverts "forced-fail"
        vm.prank(operator);
        vm.expectRevert(bytes("forced-fail"));
        m.divert(100_000e6);
        assertEq(m.freeValueAccrued(), SEED, "ledger unchanged after a reverted divert");
    }

    function test_divert_execfailed_empty_revert_data() public {
        // wire usdc to a contract that reverts empty -> the first approve _exec -> Safe catches (false,"") -> ExecFailed.
        RevertEmpty re = new RevertEmpty();
        RecordingSafe s = new RecordingSafe();
        s.setLive(true);
        RecycleModule x = new RecycleModule();
        // usdc slot points at the empty-reverting target; eePool/nav real so the bound passes to reach the approve exec.
        x.setUp(abi.encode(owner, address(s), operator, ZDM, address(re), address(nav), address(ee), WAREHOUSE));
        vm.prank(operator);
        x.creditFreeValue(100_000e6);
        nav.setProvision(BIG_HOLE);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.ExecFailed.selector);
        x.divert(100_000e6);
    }

    // ----------------------------------------------------------------- CEI: decrement lands BEFORE the deposit exec

    function test_divert_decrement_before_exec() public {
        ReadbackEEMock rb = new ReadbackEEMock(address(usdc));
        (RecycleModule mod, RecordingSafe s) = _rigWith(address(rb));
        rb.setModule(mod);

        uint256 amt = 300_000e6;
        vm.prank(operator);
        mod.divert(amt);

        assertTrue(rb.did(), "readback ran");
        assertEq(rb.observed(), SEED - amt, "the spend was applied BEFORE the deposit exec (effects-before-interaction)");
        assertEq(s.callCount(), 3, "full exec set ran");
    }

    // ----------------------------------------------------------------- divert + recycle co-exist on one ledger

    function test_divert_then_recycle_share_one_ledger() public {
        // divert spends part into the bank; recycle spends more into the basket; the ledger ends at the remainder.
        uint256 diverted = 250_000e6;
        vm.prank(operator);
        m.divert(diverted);
        assertEq(m.freeValueAccrued(), SEED - diverted, "ledger after divert");
        assertEq(ee.balanceOf(WAREHOUSE), diverted, "divert filled the bank");

        // recycle drives ZipDepositModule.deposit — the RecordingSafe is live, so wire `usdc`/ZDM execs return true via
        // the live path; here we only need it to succeed against a stub deposit return.
        uint256 recycled = 100_000e6;
        safe.setReturnData(abi.encode(uint256(recycled * 1e12))); // recycle's deposit zipMinted (non-live decode path)
        // recycle's execs (approve ZDM / deposit / approve 0) execute live against ZDM=0xD00 (an EOA: call to an EOA
        // with calldata succeeds and returns empty) — so make the deposit return decodable by switching the safe to a
        // recording (non-live) returndata path for this leg only.
        safe.setLive(false);
        vm.prank(operator);
        uint256 zipMinted = m.recycle(recycled);
        assertEq(zipMinted, recycled * 1e12, "recycle minted (stubbed)");
        assertEq(m.freeValueAccrued(), SEED - diverted - recycled, "one ledger: seed - diverted - recycled");
    }
}
