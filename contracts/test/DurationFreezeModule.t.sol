// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {IModuleProxyFactory} from "../src/interfaces/zodiac/IModuleProxyFactory.sol";

import {DurationFreezeModule} from "../src/supply/szipUSD/DurationFreezeModule.sol";
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev SEC-14: mastercopies are init-locked in their ctor, so `setUp` on a bare impl reverts.
///      A fresh EIP-1167 clone (fresh proxy storage) behaves like the old bare instance for setUp.
function _cloneDurationFreezeModule() returns (DurationFreezeModule) {
    return DurationFreezeModule(Clones.clone(address(new DurationFreezeModule())));
}

// =========================================================================================== mocks

/// @dev Minimal configurable-decimals ERC20. ctor `(uint8 d)`, open `mint`. No fee-on-transfer, non-rebasing.
///      Mirrors `LienXAlphaEscrow.t.sol` / `DefaultCoordinator.t.sol`'s MockERC20.
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

/// @dev A MockERC20 that ALSO exposes `exchangeRate()` (the xAlpha LST leg the real oracle marks). Balance 0 in the
///      fork test, but `_xAlphaUSD()` is called unconditionally, so the leg token must answer this selector.
contract MockXAlphaToken is MockERC20 {
    uint256 public exchangeRate = 1e18;

    constructor(uint8 d) MockERC20(d) {}

    function setExchangeRate(uint256 v) external {
        exchangeRate = v;
    }
}

/// @dev A MockERC20 that ALSO exposes `discount()` (the oHYDX intrinsic-mark leg). Same rationale as MockXAlphaToken.
contract MockOHydxToken is MockERC20 {
    uint256 public discount;

    constructor(uint8 d, uint256 disc) MockERC20(d) {
        discount = disc;
    }
}

/// @dev A fee-on-transfer ERC20 (skims 1% on transfer) — drives the `TransferShortfall` defense: the dest delta
///      is less than `amount`, so the module reverts even though the Safe exec returned true.
contract MockFeeOnTransferERC20 {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        uint256 fee = a / 100; // 1% burned
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @dev Settable EulerEarn stand-in (the §8.2 senior pool). `convertToAssets`/`maxWithdraw`/`balanceOf` are all
///      drivable so ANY `U` is reachable. The donation test sends USDC to THIS address and asserts `U` unchanged.
contract MockEulerEarn {
    uint256 public sharesOf; // balanceOf(warehouse)
    uint256 public assetsPerShareBacking; // convertToAssets(shares) result
    uint256 public free; // maxWithdraw(warehouse) result

    function setBacking(uint256 shares, uint256 totalBacking, uint256 free_) external {
        sharesOf = shares;
        assetsPerShareBacking = totalBacking;
        free = free_;
    }

    function balanceOf(address) external view returns (uint256) {
        return sharesOf;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        // shares==0 -> 0; else the settable total backing (the test sets shares non-zero to mean "has a position").
        return shares == 0 ? 0 : assetsPerShareBacking;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return free;
    }
}

/// @dev A minimal `ISzipNavBasket` stand-in for the UNIT suite: settable `committedValue`/`grossBasketValue` +
///      the five leg getters (so `setUp` reads the whitelist). Exercises the floor math independent of basket
///      composition. The FORK suite uses the REAL `SzipNavOracle`.
contract MockNavBasket {
    uint256 public committedValue;
    uint256 public grossBasketValue;
    uint256 public pathLockedLpEquity; // default 0 -> coverageValue == committedValue (unchanged for legacy tests)

    address public zipUSD;
    address public usdc;
    address public xAlpha;
    address public hydx;
    address public oHydx;
    address public ichiVault; // defaults to address(0) (pre-LP) — keeps the unit suite's 5-leg whitelist

    constructor(address z, address u, address x, address h, address oh) {
        zipUSD = z;
        usdc = u;
        xAlpha = x;
        hydx = h;
        oHydx = oh;
    }

    function setIchiVault(address v) external {
        ichiVault = v;
    }

    function setValues(uint256 committed, uint256 gross) external {
        committedValue = committed;
        grossBasketValue = gross;
    }

    function setPathLockedLpEquity(uint256 v) external {
        pathLockedLpEquity = v;
    }

    /// @dev 1:1 for clean gate math in the unit suite (dissolving `shares` removes `shares` of coverage value).
    function lpShareValue(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function freeValue() external view returns (uint256) {
        return grossBasketValue - committedValue;
    }
}

/// @dev A recording/relaying Safe stand-in (the Zodiac avatar surface for the two Safes). When `live`, it performs
///      the inner transfer (so `committedValue`-style reads via the real basket would move); otherwise it records
///      only. Can be made to return `false` (Safe swallows inner reverts) to drive `ExecFailed`. Modeled on
///      `LpStrategyModule.t.sol`'s RecordingSafe.
contract RecordingSafe {
    bool public live = true;
    bool public forceFail; // return false from execTransactionFromModule (Safe-swallowed inner revert)

    function setLive(bool v) external {
        live = v;
    }

    function setForceFail(bool v) external {
        forceFail = v;
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8)
        external
        returns (bool)
    {
        if (forceFail) return false;
        if (live) {
            (bool ok,) = to.call{value: value}(data);
            return ok;
        }
        return true;
    }

    receive() external payable {}
}

// =========================================================================================== unit base harness

abstract contract FreezeBase is Test {
    DurationFreezeModule internal m;
    MockNavBasket internal basket;
    MockEulerEarn internal ee;
    RecordingSafe internal mainSafe;
    RecordingSafe internal sidecar;

    // the five legs (18-dp except usdc 6-dp)
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockERC20 internal xalpha;
    MockERC20 internal hydx;
    MockERC20 internal ohydx;
    MockERC20 internal unvalued; // a non-leg token

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal warehouse = makeAddr("warehouse");
    address internal rando = makeAddr("rando");

    function _legs() internal {
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockERC20(18);
        hydx = new MockERC20(18);
        ohydx = new MockERC20(18);
        unvalued = new MockERC20(18);
    }

    function _initParams(
        address owner_,
        address main_,
        address side_,
        address op_,
        address oracle_,
        address ee_,
        address wh_
    ) internal pure returns (bytes memory) {
        // coverageBps = 1e4 (100% of the liability), dollarBuffer = 0 — the default Phase-1 floor.
        return abi.encode(owner_, main_, side_, op_, oracle_, ee_, wh_, uint256(1e4), uint256(0));
    }

    function _deploy() internal {
        _legs();
        basket = new MockNavBasket(address(zip), address(usdc), address(xalpha), address(hydx), address(ohydx));
        ee = new MockEulerEarn();
        mainSafe = new RecordingSafe();
        sidecar = new RecordingSafe();
        m = _cloneDurationFreezeModule();
        m.setUp(
            _initParams(
                owner,
                address(mainSafe),
                address(sidecar),
                operator,
                address(basket),
                address(ee),
                warehouse
            )
        );
    }

    /// @dev Set the mock EulerEarn so utilization() == `u` (18-dp). backing=1e18 shares=1 => free=(1-u).
    function _setU(uint256 u) internal {
        // sa = 1e18, free = 1e18 - u*1e18/1e18 ; choose sa=1e18 -> free = 1e18 - u (since u*sa/1e18 illiquid)
        // u = (sa-free)*1e18/sa with sa=1e18 -> free = 1e18 - u
        ee.setBacking(1, 1e18, 1e18 - u);
    }

    /// @dev Set the mock EulerEarn so illiquidSeniorValue() == `debtUsd18` (18-dp USD). The module scales the
    ///      USDC-6dp senior numerator by 1e12, so set `sa = debtUsd18/1e12` (6-dp) and `free = 0`. `debtUsd18` MUST
    ///      be a clean multiple of 1e12 (use whole-dollar 18-dp values like 60e18).
    function _setDebt(uint256 debtUsd18) internal {
        ee.setBacking(1, debtUsd18 / 1e12, 0);
    }
}

// =========================================================================================== setUp / ctor suite

contract DurationFreezeModuleSetupTest is FreezeBase {
    function setUp() public {
        _deploy();
    }

    /// @dev SEC-14: the bare mastercopy is init-locked in its ctor; `setUp` on it reverts AlreadyInitialized.
    function test_SEC14_mastercopy_setUp_reverts() public {
        DurationFreezeModule mc = new DurationFreezeModule();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mc.setUp(
            _initParams(
                owner,
                address(mainSafe),
                address(sidecar),
                operator,
                address(basket),
                address(ee),
                warehouse
            )
        );
    }

    function test_setUp_wires_storage_and_whitelist() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.mainSafe(), address(mainSafe));
        assertEq(m.sidecar(), address(sidecar));
        assertEq(m.avatar(), address(mainSafe));
        assertEq(m.target(), address(mainSafe));
        assertEq(m.navOracle(), address(basket));
        assertEq(m.eulerEarn(), address(ee));
        assertEq(m.warehouse(), warehouse);
        // the five legs read LIVE off the oracle
        assertEq(m.zipUSD(), address(zip));
        assertEq(m.usdc(), address(usdc));
        assertEq(m.xAlpha(), address(xalpha));
        assertEq(m.hydx(), address(hydx));
        assertEq(m.oHydx(), address(ohydx));
        // coverage params default to 100% / no buffer
        assertEq(m.coverageBps(), 1e4);
        assertEq(m.dollarBuffer(), 0);
    }

    function test_setUp_rejects_zero_coverageBps() public {
        DurationFreezeModule x = _cloneDurationFreezeModule();
        bytes memory bad = abi.encode(
            owner, address(mainSafe), address(sidecar), operator, address(basket), address(ee), warehouse,
            uint256(0), uint256(0)
        );
        vm.expectRevert(DurationFreezeModule.BadParams.selector);
        x.setUp(bad);
    }

    function test_setCoverageBps_and_setDollarBuffer_onlyOwner() public {
        // owner can set; effect lands.
        vm.prank(owner);
        m.setCoverageBps(12000);
        assertEq(m.coverageBps(), 12000);
        vm.prank(owner);
        m.setDollarBuffer(5e18);
        assertEq(m.dollarBuffer(), 5e18);
        // zero coverageBps rejected.
        vm.prank(owner);
        vm.expectRevert(DurationFreezeModule.BadParams.selector);
        m.setCoverageBps(0);
        // non-owner rejected (OZ Ownable).
        vm.prank(rando);
        vm.expectRevert();
        m.setCoverageBps(1e4);
        vm.prank(rando);
        vm.expectRevert();
        m.setDollarBuffer(0);
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(
            _initParams(
                owner, address(mainSafe), address(sidecar), operator, address(basket), address(ee), warehouse
            )
        );
    }

    function test_mastercopy_init_locked() public {
        DurationFreezeModule mc = _cloneDurationFreezeModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.mainSafe(), address(0));
        assertEq(mc.zipUSD(), address(0));
        // entrypoints are inert (operator is 0; any caller != 0 -> NotOperator, but the whitelist gate fires first
        // for an unvalued asset — use a leg-less path: amount path is unreachable since whitelist is all-zero).
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.UnvaluedAsset.selector, address(zip)));
        mc.commit(address(zip), 1e18);
    }

    /// @dev Deploy a fresh (uninitialized) module, then `setUp` it under `vm.expectRevert(err)` — so the expect
    ///      attaches to the `setUp` call, NOT the CREATE.
    function _expectSetUpRevert(
        bytes4 err,
        address owner_,
        address main_,
        address side_,
        address op_,
        address oracle_,
        address ee_,
        address wh_
    ) internal {
        DurationFreezeModule x = _cloneDurationFreezeModule();
        vm.expectRevert(err);
        x.setUp(_initParams(owner_, main_, side_, op_, oracle_, ee_, wh_));
    }

    function test_setUp_rejects_zero_addresses() public {
        address M = address(mainSafe);
        address S = address(sidecar);
        address O = address(basket);
        address E = address(ee);
        bytes4 z = DurationFreezeModule.ZeroAddress.selector;
        _expectSetUpRevert(z, address(0), M, S, operator, O, E, warehouse); // owner
        _expectSetUpRevert(z, owner, address(0), S, operator, O, E, warehouse); // main
        _expectSetUpRevert(z, owner, M, address(0), operator, O, E, warehouse); // sidecar
        _expectSetUpRevert(z, owner, M, S, address(0), O, E, warehouse); // operator
        _expectSetUpRevert(z, owner, M, S, operator, address(0), E, warehouse); // navOracle
        _expectSetUpRevert(z, owner, M, S, operator, O, address(0), warehouse); // eulerEarn
        _expectSetUpRevert(z, owner, M, S, operator, O, E, address(0)); // warehouse
    }

    function test_setUp_rejects_owner_equals_operator() public {
        _expectSetUpRevert(
            DurationFreezeModule.OwnerIsOperator.selector, operator, address(mainSafe), address(sidecar), operator,
            address(basket), address(ee), warehouse
        );
    }

    function test_setUp_rejects_mainSafe_equals_sidecar() public {
        _expectSetUpRevert(
            DurationFreezeModule.BadParams.selector, owner, address(mainSafe), address(mainSafe), operator,
            address(basket), address(ee), warehouse
        );
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }
}

// =========================================================================================== view-math suite

contract DurationFreezeModuleMathTest is FreezeBase {
    function setUp() public {
        _deploy();
    }

    // -------------------------------------------------------------- utilization (donation-immune)
    function test_utilization_zero_when_no_position() public {
        ee.setBacking(0, 0, 0); // shares 0 -> sa 0 -> U 0
        assertEq(m.utilization(), 0);
    }

    function test_utilization_zero_when_free_ge_sa() public {
        ee.setBacking(1, 100e18, 100e18); // free == sa -> 0
        assertEq(m.utilization(), 0);
        ee.setBacking(1, 100e18, 200e18); // free > sa -> 0
        assertEq(m.utilization(), 0);
    }

    function test_utilization_mid() public {
        ee.setBacking(1, 100e18, 30e18); // U = (100-30)/100 = 0.7
        assertEq(m.utilization(), 0.7e18);
    }

    function test_utilization_free_eq_sa_exact_zero() public {
        ee.setBacking(1, 1, 1); // sa==free==1 -> 0
        assertEq(m.utilization(), 0);
    }

    function test_utilization_donation_immune() public {
        ee.setBacking(1, 100e18, 30e18); // U = 0.7
        uint256 before = m.utilization();
        // a USDC donation to the eulerEarn mock address must NOT move U (the CRITICAL fix).
        usdc.mint(address(ee), 1_000_000e6);
        assertEq(m.utilization(), before, "donation moved U");
        assertEq(m.utilization(), 0.7e18);
    }

    // -------------------------------------------------------------- requiredFraction (freeze% == utilization%)
    function test_requiredFraction_equals_utilization() public {
        // freeze% = utilization% exactly, across the range. utilization() is already clamped to [0, 1e18].
        _setU(0);
        assertEq(m.requiredFraction(), 0, "U==0 -> 0");
        assertEq(m.requiredFraction(), m.utilization());
        _setU(0.7e18);
        assertEq(m.requiredFraction(), 0.7e18, "U==0.7 -> 0.7");
        assertEq(m.requiredFraction(), m.utilization());
        _setU(1e18);
        assertEq(m.requiredFraction(), 1e18, "U==1.0 -> 1.0");
        assertEq(m.requiredFraction(), m.utilization());
    }

    // -------------------------------------------------------------- debt-pinned floor (Phase 1)
    function test_illiquidSeniorValue_scales_6dp_to_18dp() public {
        // sa = 70e6 USDC, free = 0 -> illiquid = 70e6 * 1e12 = 70e18 ($70).
        ee.setBacking(1, 70e6, 0);
        assertEq(m.illiquidSeniorValue(), 70e18, "(sa - free) * 1e12");
        // free >= sa -> 0; sa == 0 -> 0.
        ee.setBacking(1, 70e6, 70e6);
        assertEq(m.illiquidSeniorValue(), 0, "free >= sa -> 0");
        ee.setBacking(0, 70e6, 0);
        assertEq(m.illiquidSeniorValue(), 0, "no position -> 0");
    }

    function test_requiredCommittedValue_debt_pinned_at_100pct() public {
        _setDebt(70e18);
        basket.setValues(0, 100e18);
        assertEq(m.requiredCommittedValue(), 70e18, "floor = debt at 100% coverage (< gross)");
    }

    function test_requiredCommittedValue_capped_at_gross() public {
        _setDebt(120e18); // debt above gross
        basket.setValues(0, 100e18);
        assertEq(m.requiredCommittedValue(), 100e18, "floor capped at gross (cannot freeze more than exists)");
    }

    function test_requiredCommittedValue_coverageBps_overcollateralizes() public {
        _setDebt(70e18);
        basket.setValues(0, 1000e18); // gross high so the cap does not bind
        vm.prank(owner);
        m.setCoverageBps(12000); // 120%
        assertEq(m.requiredCommittedValue(), 84e18, "120% of 70");
    }

    function test_requiredCommittedValue_dollarBuffer_adds_floor() public {
        _setDebt(70e18);
        basket.setValues(0, 1000e18);
        vm.prank(owner);
        m.setDollarBuffer(10e18); // max(70, 70 + 10) = 80
        assertEq(m.requiredCommittedValue(), 80e18, "debt + buffer");
    }

    /// @dev The KEY anti-drain property: the floor is invariant to shrinking the junior basket (so long as gross
    ///      stays above it). Shrinking gross from 1000 to 100 leaves the floor at debt=70 — the re-leveling loop has
    ///      no denominator to game. Contrast the OLD `U × gross` floor, which would have fallen with gross.
    function test_requiredCommittedValue_invariant_to_basket_shrink() public {
        _setDebt(70e18);
        basket.setValues(0, 1000e18);
        assertEq(m.requiredCommittedValue(), 70e18, "floor = debt at gross 1000");
        basket.setValues(0, 100e18); // junior basket shrank 10x
        assertEq(m.requiredCommittedValue(), 70e18, "floor UNCHANGED - debt did not move");
    }

    function test_requiredCommittedValue_zero_gross_floor_zero() public {
        _setDebt(50e18);
        basket.setValues(0, 0);
        assertEq(m.requiredCommittedValue(), 0, "gross 0 -> floor 0 (capped), no div issue");
    }

    function test_covered_true_at_or_above_floor_false_below() public {
        _setDebt(70e18);
        basket.setValues(70e18, 100e18); // committed == floor
        assertTrue(m.covered(), "committed == floor -> covered");
        basket.setValues(69e18, 100e18); // committed < floor (price-drift breach, NO release)
        assertFalse(m.covered(), "committed < floor -> not covered");
    }

    function test_coverageValue_counts_pathLockedLp() public {
        _setDebt(70e18);
        basket.setValues(40e18, 100e18); // sidecar liquid = 40
        basket.setPathLockedLpEquity(50e18); // fenced LP = 50
        assertEq(m.coverageValue(), 90e18, "committed 40 + LP 50");
        assertTrue(m.covered(), "90 >= 70 -> covered by LP in place");
        basket.setPathLockedLpEquity(20e18); // LP mark drops -> coverage 60 < 70
        assertEq(m.coverageValue(), 60e18);
        assertFalse(m.covered(), "60 < 70 -> price-drift breach");
    }

    function test_lpBurnKeepsCovered_excess_bound() public {
        _setDebt(70e18); // floor 70
        basket.setValues(40e18, 100e18); // committed 40
        basket.setPathLockedLpEquity(50e18); // LP 50 -> coverage 90; excess over floor = 20
        // dissolving 15 (1:1 mock) -> 90 - 15 = 75 >= 70 -> allowed
        assertTrue(m.lpBurnKeepsCovered(15e18), "dissolve within the 20 excess");
        // dissolving 25 -> 90 - 25 = 65 < 70 -> NOT allowed (would eat into the floor-backing LP)
        assertFalse(m.lpBurnKeepsCovered(25e18), "dissolve beyond the excess");
    }

    function test_freeValue_is_gross_minus_committed() public {
        basket.setValues(40e18, 100e18);
        assertEq(m.freeValue(), 60e18);
        assertEq(m.committedValue(), 40e18);
        assertEq(m.grossBasketValue(), 100e18);
    }
}

// =========================================================================================== commit / release suite

contract DurationFreezeModuleRotationTest is FreezeBase {
    function setUp() public {
        _deploy();
    }

    // -------------------------------------------------------------- whitelist
    function test_commit_unvalued_asset_reverts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.UnvaluedAsset.selector, address(unvalued)));
        m.commit(address(unvalued), 1e18);
    }

    function test_release_unvalued_asset_reverts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.UnvaluedAsset.selector, address(unvalued)));
        m.release(address(unvalued), 1e18);
    }

    function test_each_leg_is_accepted_by_whitelist() public {
        // fund main with each leg; a commit of each succeeds (whitelist passes). The mock Safe relays the transfer.
        address[5] memory legs = [address(zip), address(usdc), address(xalpha), address(hydx), address(ohydx)];
        for (uint256 i = 0; i < 5; i++) {
            MockERC20(legs[i]).mint(address(mainSafe), 10e18);
            vm.prank(operator);
            m.commit(legs[i], 5e18);
            assertEq(MockERC20(legs[i]).balanceOf(address(sidecar)), 5e18, "leg committed to sidecar");
        }
    }

    // -------------------------------------------------------------- commit (happy + negatives)
    function test_commit_nonOperator_reverts() public {
        zip.mint(address(mainSafe), 10e18);
        vm.prank(rando);
        vm.expectRevert(DurationFreezeModule.NotOperator.selector);
        m.commit(address(zip), 1e18);
    }

    function test_commit_zeroAmount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.ZeroAmount.selector);
        m.commit(address(zip), 0);
    }

    function test_commit_happy_moves_and_emits() public {
        zip.mint(address(mainSafe), 100e18);
        // basket reflects: sidecar gets the value. The MockNavBasket doesn't auto-read balances, so we set it.
        basket.setValues(0, 100e18);

        vm.expectEmit(true, true, true, true, address(m));
        emit DurationFreezeModule.Committed(address(zip), 60e18, 0); // mock committedValue stays 0 (settable)
        vm.prank(operator);
        m.commit(address(zip), 60e18);

        assertEq(zip.balanceOf(address(mainSafe)), 40e18, "main -amount");
        assertEq(zip.balanceOf(address(sidecar)), 60e18, "sidecar +amount");
    }

    function test_commit_over_freeze_all_free_equity_succeeds() public {
        // no ceiling: committing 100% succeeds (grief-not-theft).
        zip.mint(address(mainSafe), 100e18);
        vm.prank(operator);
        m.commit(address(zip), 100e18);
        assertEq(zip.balanceOf(address(mainSafe)), 0);
        assertEq(zip.balanceOf(address(sidecar)), 100e18);
    }

    function test_commit_feeOnTransfer_reverts_shortfall() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20();
        // make it a valued leg by deploying a module whose oracle reports fot as a leg.
        MockNavBasket b2 =
            new MockNavBasket(address(fot), address(usdc), address(xalpha), address(hydx), address(ohydx));
        DurationFreezeModule x = _cloneDurationFreezeModule();
        x.setUp(
            _initParams(
                owner, address(mainSafe), address(sidecar), operator, address(b2), address(ee), warehouse
            )
        );
        fot.mint(address(mainSafe), 100e18);
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.TransferShortfall.selector);
        x.commit(address(fot), 50e18);
    }

    function test_commit_safe_returns_false_reverts_execFailed() public {
        zip.mint(address(mainSafe), 100e18);
        mainSafe.setForceFail(true); // Safe swallows inner revert, returns false
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.ExecFailed.selector);
        m.commit(address(zip), 10e18);
    }

    function test_commit_insufficient_balance_reverts_execFailed() public {
        // main has nothing; the live relay transfer underflows -> the Safe call returns false -> ExecFailed.
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.ExecFailed.selector);
        m.commit(address(zip), 10e18);
    }

    // -------------------------------------------------------------- release (the floor)
    function test_release_nonOperator_reverts() public {
        vm.prank(rando);
        vm.expectRevert(DurationFreezeModule.NotOperator.selector);
        m.release(address(zip), 1e18);
    }

    function test_release_zeroAmount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.ZeroAmount.selector);
        m.release(address(zip), 0);
    }

    function test_release_above_floor_succeeds_and_emits() public {
        // debt=60 -> floor 60 (100% coverage, < gross 100). sidecar holds 80 (real zip), release 10 -> 70 >= 60.
        _setDebt(60e18);
        zip.mint(address(sidecar), 80e18);
        // committedValue reflects what sidecar holds AFTER the move; with the MockNavBasket we set it to the
        // post-move value 70, gross 100 (the module reads these post-transfer).
        basket.setValues(70e18, 100e18);

        vm.expectEmit(true, true, true, true, address(m));
        emit DurationFreezeModule.Released(address(zip), 10e18, 70e18, 60e18);
        vm.prank(operator);
        m.release(address(zip), 10e18);

        assertEq(zip.balanceOf(address(mainSafe)), 10e18, "main got the release");
        assertEq(zip.balanceOf(address(sidecar)), 70e18, "sidecar drained by 10");
    }

    function test_release_floor_uses_coverage_incl_pathLockedLp() public {
        // floor 70. Post-move sidecar committed is only 30 — but the fenced LP adds 50 -> coverage 80 >= 70, so the
        // release CLEARS even though committedValue alone (30) is below the floor. The LP backs the floor in place.
        _setDebt(70e18);
        zip.mint(address(sidecar), 40e18);
        basket.setValues(30e18, 100e18); // post-move committed 30 (committed alone would breach)
        basket.setPathLockedLpEquity(50e18); // + LP 50 -> coverage 80
        vm.prank(operator);
        m.release(address(zip), 10e18); // 80 >= 70 -> succeeds
        assertEq(zip.balanceOf(address(mainSafe)), 10e18, "release cleared on coverage incl. LP");
    }

    function test_release_below_floor_reverts_and_rolls_back() public {
        // debt=100 == gross -> floor 100. Post-move committed would be 50 < 100.
        _setDebt(100e18);
        zip.mint(address(sidecar), 100e18);
        basket.setValues(50e18, 100e18); // post-move committed 50 < floor 100

        uint256 mainBefore = zip.balanceOf(address(mainSafe));
        uint256 sideBefore = zip.balanceOf(address(sidecar));
        uint256 committedBefore = m.committedValue();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 50e18, 100e18));
        m.release(address(zip), 60e18);

        // atomic rollback: balances AND committedValue() are the byte-for-byte pre-call values.
        assertEq(zip.balanceOf(address(mainSafe)), mainBefore, "main rolled back");
        assertEq(zip.balanceOf(address(sidecar)), sideBefore, "sidecar rolled back");
        assertEq(m.committedValue(), committedBefore, "committedValue rolled back");
    }

    function test_release_floor_zero_allows_full_drain() public {
        // U=0 -> requiredFraction 0 -> floor 0; the sidecar may be fully drained.
        _setU(0);
        zip.mint(address(sidecar), 100e18);
        basket.setValues(0, 0); // post-move sidecar empty
        vm.prank(operator);
        m.release(address(zip), 100e18);
        assertEq(zip.balanceOf(address(sidecar)), 0, "fully drained");
        assertEq(zip.balanceOf(address(mainSafe)), 100e18);
    }

    function test_release_required_full_sidecar_eq_gross_one_wei_release_reverts() public {
        // debt >= gross -> floor capped at gross: a 1-wei release drops committed below gross -> revert.
        _setDebt(100e18); // debt == gross 100 -> floor 100
        zip.mint(address(sidecar), 100e18);
        basket.setValues(100e18 - 1, 100e18); // after a 1-wei release, committed = gross-1 < gross
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 100e18 - 1, 100e18)
        );
        m.release(address(zip), 1);
    }

    function test_release_safe_returns_false_reverts_execFailed() public {
        zip.mint(address(sidecar), 100e18);
        sidecar.setForceFail(true);
        vm.prank(operator);
        vm.expectRevert(DurationFreezeModule.ExecFailed.selector);
        m.release(address(zip), 10e18);
    }

    // -------------------------------------------------------------- the autonomous-trigger flip (qa #9)
    function test_release_debt_rise_flips_legal_to_breach() public {
        // sidecar holds 70 (real); a fixed release of 10 -> post-move 60. gross 100.
        // At debt=60 floor=60 -> 60>=60 passes. Raise debt=70 -> floor=70 -> 60<70 reverts (operator call FIXED).
        zip.mint(address(sidecar), 70e18);
        basket.setValues(60e18, 100e18); // post-move committed 60 (fixed across the debt walk)

        _setDebt(60e18);
        // snapshot then release at debt=60 (passes), then revert state and re-run at debt=70 (breach).
        uint256 snap = vm.snapshot();
        vm.prank(operator);
        m.release(address(zip), 10e18); // passes at debt=60
        vm.revertTo(snap);

        _setDebt(70e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 60e18, 70e18));
        m.release(address(zip), 10e18);
    }

    // -------------------------------------------------------------- gross invariant under rotation (qa #4)
    /// @dev With the REAL oracle, gross is a pure balance sum; here we prove the module's commit/release of a plain
    ///      leg conserves the (mock-reported) gross by reading the real-oracle integration test below. The unit
    ///      MockNavBasket is settable, so the conservation linchpin is pinned in the integration suite.
    function test_commit_then_release_plain_leg_conserves_balances() public {
        // commit 30 then release 30; net main/sidecar balances unchanged (conservation of the moved leg).
        _setU(0); // floor 0 so the release is unconstrained
        zip.mint(address(mainSafe), 100e18);
        basket.setValues(0, 100e18);
        uint256 mainBefore = zip.balanceOf(address(mainSafe));
        vm.prank(operator);
        m.commit(address(zip), 30e18);
        assertEq(zip.balanceOf(address(sidecar)), 30e18);
        vm.prank(operator);
        m.release(address(zip), 30e18);
        assertEq(zip.balanceOf(address(mainSafe)), mainBefore, "leg conserved across commit+release");
        assertEq(zip.balanceOf(address(sidecar)), 0);
    }
}

// =========================================================================================== ABI-negatives

contract DurationFreezeModuleAbiNegativeTest is FreezeBase {
    function setUp() public {
        _deploy();
    }

    function test_no_forbidden_selectors() public {
        bytes4[] memory forbidden = new bytes4[](8);
        forbidden[0] = bytes4(keccak256("sweep(address,uint256)"));
        forbidden[1] = bytes4(keccak256("rescue(address,uint256)"));
        forbidden[2] = bytes4(keccak256("pause()"));
        forbidden[3] = bytes4(keccak256("exec(address,bytes)"));
        forbidden[4] = bytes4(keccak256("setExitGate(address)"));
        forbidden[5] = bytes4(keccak256("engageFreeze()"));
        forbidden[6] = bytes4(keccak256("writeProvision(uint256)"));
        forbidden[7] = bytes4(keccak256("slashXAlphaToCohort(bytes32)"));
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(m).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok, "forbidden selector resolved");
        }
    }

    function test_setTarget_nonOwner_reverts() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }
}

// =========================================================================================== oracle parity suite

/// @dev The additive `SzipNavOracle` extension: `grossBasketValue() == committedValue() + freeValue()` exactly with
///      no LP, and within ≤2 wei with a split LP. Plus the un-changed grossBasketValue (the 42-test pins re-run
///      green in the SzipNavOracle suite).
contract SzipNavOracleParityTest is Test {
    SzipNavOracle internal oracle;
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockXAlphaToken internal xalpha;
    MockERC20 internal hydx;
    MockOHydxToken internal ohydx;

    address internal forwarder = makeAddr("forwarder");
    address internal mainSafe = makeAddr("mainSafe");
    address internal sidecar = makeAddr("sidecar");

    function setUp() public {
        vm.warp(1_000_000);
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockXAlphaToken(18);
        hydx = new MockERC20(18);
        ohydx = new MockOHydxToken(18, 30);
        oracle = new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xalpha), address(hydx), address(ohydx), mainSafe,
            sidecar, 4 hours, 1 hours, 1000
        );
    }

    function testFuzz_parity_no_LP(uint96 zm, uint96 zs, uint96 um, uint96 us) public {
        // only the par legs (zip + usdc) -> no pushed-mark needed, no LP. Parity is EXACT.
        zip.mint(mainSafe, zm);
        zip.mint(sidecar, zs);
        usdc.mint(mainSafe, um);
        usdc.mint(sidecar, us);
        assertEq(oracle.grossBasketValue(), oracle.committedValue() + oracle.freeValue(), "exact parity, no LP");
    }

    function test_parity_exact_plain_legs() public {
        zip.mint(mainSafe, 100e18);
        zip.mint(sidecar, 50e18);
        usdc.mint(mainSafe, 30e6);
        usdc.mint(sidecar, 10e6);
        // gross = 150e18 + 40e6*1e12 = 150e18 + 40e18 = 190e18
        assertEq(oracle.grossBasketValue(), 190e18);
        assertEq(oracle.committedValue(), 50e18 + 10e18, "sidecar value");
        assertEq(oracle.freeValue(), 100e18 + 30e18, "main value");
        assertEq(oracle.grossBasketValue(), oracle.committedValue() + oracle.freeValue());
    }

    /// @dev The ≤2-wei LP-split vector: a non-dividing `totalSupply` so the per-Safe pro-rata floors twice (once
    ///      per Safe in committed+free) vs once (in gross). The slack is bounded by 2 wei (one per LP reserve token).
    function test_parity_split_LP_within_2_wei() public {
        ParityICHIVault iv = new ParityICHIVault();
        ParityGauge g = new ParityGauge();
        // LP token0 = zipUSD ($1), token1 = xAlpha (exchangeRate 1.0 × alpha mark). Push the alpha mark = $1.
        // non-dividing totalSupply (a prime) so total0*held/supply truncates.
        iv.set(address(zip), address(xalpha), 1_000_003, 7_777_777, 3_333_331);
        // split the LP across both Safes (held in the vault + the gauge), non-trivially.
        iv.setBalance(mainSafe, 111_111);
        iv.setBalance(sidecar, 222_223);
        g.setBalance(mainSafe, 55_557);
        g.setBalance(sidecar, 77_773);
        oracle.setLpPosition(address(iv), address(g));

        // push the alpha mark so xAlpha (the LP token1) prices at $1 (exchangeRate 1e18 default × alpha $1).
        _pushAlpha(1e18);

        uint256 gross = oracle.grossBasketValue();
        uint256 sum = oracle.committedValue() + oracle.freeValue();
        uint256 slack = gross > sum ? gross - sum : sum - gross;
        assertLe(slack, 2, "LP-split parity within 2 wei");
        assertGt(gross, 0, "LP actually contributed");
    }

    function _pushAlpha(uint256 alphaUSD) internal {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory prices = new uint256[](1);
        legs[0] = oracle.LEG_ALPHA_USD();
        prices[0] = alphaUSD;
        bytes memory payload = abi.encode(legs, prices, uint32(block.timestamp));
        bytes memory report = abi.encode(oracle.NAV_LEG(), payload);
        vm.prank(forwarder);
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------- SEC-02: coverage sidecar-LP double-count (Group 2)
    /// @dev Wire a clean dividing LP (zipUSD/xAlpha, both at $1): 1000 supply, reserves 200 zip + 100 xAlpha, so each
    ///      share marks at 0.3e18 ($1·200 + $1·100 over 1000). Used by the SEC02 vectors below.
    function _wireSec02Lp() internal returns (ParityICHIVault iv, ParityGauge g) {
        iv = new ParityICHIVault();
        g = new ParityGauge();
        iv.set(address(zip), address(xalpha), 1000e18, 200e18, 100e18);
        oracle.setLpPosition(address(iv), address(g));
        _pushAlpha(1e18); // xAlpha (LP token1) prices at $1 (default exchangeRate 1e18 × $1 mark)
    }

    /// @dev SEC-02 core: a sidecar LP donation must raise the coverage numerator (`committedValue +
    ///      pathLockedLpEquity`) by EXACTLY ONE LP mark — `committedValue` already owns the sidecar's LP, so
    ///      `pathLockedLpEquity` must be mainSafe-only (pre-fix it summed both Safes, double-counting the sidecar leg).
    function test_SEC02_sidecar_lp_single_counted() public {
        (ParityICHIVault iv,) = _wireSec02Lp();
        iv.setBalance(mainSafe, 100e18); // main LP 100/1000 -> 20 zip + 10 xAlpha = 30e18
        zip.mint(sidecar, 50e18); // sidecar plain leg

        uint256 covBefore = oracle.committedValue() + oracle.pathLockedLpEquity(); // 50 + 30 = 80e18
        uint256 pathBefore = oracle.pathLockedLpEquity(); // main-only LP = 30e18

        iv.setBalance(sidecar, 50e18); // DONATE 50e18 LP shares into the sidecar -> one mark = 15e18

        uint256 oneMark = oracle.lpShareValue(50e18);
        assertEq(oneMark, 15e18, "one sidecar LP mark (50/1000 -> 10 zip + 5 xAlpha)");
        uint256 covAfter = oracle.committedValue() + oracle.pathLockedLpEquity(); // 65 + 30 = 95e18
        assertEq(covAfter - covBefore, oneMark, "coverage rises by EXACTLY one LP mark, not two (single-count)");
        assertEq(oracle.pathLockedLpEquity(), pathBefore, "pathLockedLpEquity is mainSafe-only: untouched by sidecar LP");
    }

    /// @dev SEC-02 partition (L1 verify note): after the fix `grossBasketValue - coverageValue == Pm`, where Pm is the
    ///      mainSafe free liquid (plain) legs — i.e. every Safe's LP + debt is counted exactly once. Within ≤2 wei.
    function test_SEC02_partition_gross_minus_coverage_eq_pm() public {
        (ParityICHIVault iv,) = _wireSec02Lp();
        iv.setBalance(mainSafe, 100e18); // main LP 30e18
        iv.setBalance(sidecar, 50e18); // sidecar LP 15e18
        zip.mint(mainSafe, 40e18); // Pm: mainSafe free liquid legs
        zip.mint(sidecar, 50e18); // sidecar plain leg

        uint256 gross = oracle.grossBasketValue(); // 40 + 30 + 50 + 15 = 135e18
        uint256 coverage = oracle.committedValue() + oracle.pathLockedLpEquity(); // (50+15) + 30 = 95e18
        uint256 pm = 40e18;
        uint256 diff = gross - coverage;
        uint256 slack = diff > pm ? diff - pm : pm - diff;
        assertLe(slack, 2, "gross - coverageValue == Pm (mainSafe free liquid legs) within 2-wei pro-rata floor");
    }

    /// @dev SEC-02 floor-breach (M2): a state where the PRE-FIX double-counted coverage cleared the senior-liability
    ///      floor while the true single-counted value is below it. Exercises the REAL module's `covered()` /
    ///      `lpBurnKeepsCovered()` against the real oracle: post-fix the breach correctly surfaces (covered == false).
    function test_SEC02_floor_breach_covered_flips_false() public {
        (ParityICHIVault iv,) = _wireSec02Lp();
        iv.setBalance(mainSafe, 100e18); // main LP 30e18
        iv.setBalance(sidecar, 50e18); // sidecar LP 15e18 (the double-counted leg)
        zip.mint(mainSafe, 40e18); // Pm 40e18 (free liquid, NOT coverage)
        zip.mint(sidecar, 50e18); // sidecar plain 50e18

        MockEulerEarn ee = new MockEulerEarn();
        ee.setBacking(1, 100e6, 0); // illiquidSeniorValue == 100e18 (sa 100 USDC, free 0)
        DurationFreezeModule m = _cloneDurationFreezeModule();
        m.setUp(
            abi.encode(
                makeAddr("owner"), mainSafe, sidecar, makeAddr("operator"),
                address(oracle), address(ee), makeAddr("warehouse"), uint256(1e4), uint256(0)
            )
        );

        assertEq(m.requiredCommittedValue(), 100e18, "floor pinned to senior liability (< gross 135)");
        assertEq(m.coverageValue(), 95e18, "single-counted coverage = (sidecar 65) + (main LP 30)");
        assertFalse(m.covered(), "post-fix: 95 < 100 floor -> breach surfaces (NOT covered)");

        // pre-fix the sidecar LP (15e18) was double-counted -> coverage 110e18 >= 100 -> covered() would have lied.
        uint256 prefixCoverage = m.coverageValue() + oracle.lpShareValue(50e18);
        assertGe(prefixCoverage, m.requiredCommittedValue(), "pre-fix double-count WOULD have reported covered");

        // and the LP-dissolution gate tightens: from a breached state, burning fenced LP cannot keep coverage.
        assertFalse(m.lpBurnKeepsCovered(1e18), "burning fenced LP from a breach stays uncovered");
    }

    // ----------------------------------------------------------- SEC-04: unseeded xALPHA rate fail-close (H5)
    /// @dev An UNSEEDED xALPHA rate (`exchangeRate() == 0`) must FAIL CLOSED the freeze coverage read rather than
    ///      silently under-count the coverage floor (which could mis-gate outflow). `coverageValue()` -> the real
    ///      oracle `committedValue()` -> `_grossValueOf(sidecar)` -> `_xAlphaUSD()` reverts `RateUnseeded`. Pre-fix the
    ///      same path returned a silently-underpriced number, so this `expectRevert` would fail (fail-before/pass-after).
    function test_SEC04_unseeded_rate_reverts_coverageValue() public {
        MockEulerEarn ee = new MockEulerEarn();
        ee.setBacking(1, 100e6, 0);
        DurationFreezeModule m = _cloneDurationFreezeModule();
        m.setUp(
            abi.encode(
                makeAddr("owner"), mainSafe, sidecar, makeAddr("operator"),
                address(oracle), address(ee), makeAddr("warehouse"), uint256(1e4), uint256(0)
            )
        );

        xalpha.setExchangeRate(0); // unseeded rate
        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        m.coverageValue();

        // re-seed -> coverage reads cleanly again (fail-close was the only gate)
        xalpha.setExchangeRate(1e18);
        m.coverageValue(); // no revert
    }
}

/// @dev An ICHI-vault stand-in for the LP-split parity vector (settable per-Safe balances + pool globals).
contract ParityICHIVault {
    address public token0;
    address public token1;
    uint256 public totalSupply;
    uint256 internal t0;
    uint256 internal t1;
    mapping(address => uint256) public balanceOf;

    function set(address _t0, address _t1, uint256 _supply, uint256 _total0, uint256 _total1) external {
        token0 = _t0;
        token1 = _t1;
        totalSupply = _supply;
        t0 = _total0;
        t1 = _total1;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function getTotalAmounts() external view returns (uint256, uint256) {
        return (t0, t1);
    }
}

contract ParityGauge {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }
}

// =========================================================================================== stateful invariant

/// @dev FreezeHandler: drives `commit`/`release` over the five legs + an unvalued token, and `bumpUtilization` to
///      walk `U`, against the real module + a settable MockNavBasket whose committed/gross track real balances.
///      Mirrors `LienXAlphaEscrow.t.sol`'s EscrowHandler shape. The invariant is `committedValue() >=
///      requiredCommittedValue()` after any SUCCESSFUL release (the core safety property). `fail_on_revert = false`.
contract FreezeHandler is Test {
    DurationFreezeModule public m;
    MockNavBasket public basket;
    MockEulerEarn public ee;
    RecordingSafe public mainSafe;
    RecordingSafe public sidecar;
    address public operator;

    address[6] public tokens; // 5 legs + 1 unvalued
    uint256 public lastSuccessfulRelease; // ghost: counts successful releases (liveness sanity)
    bool public ghost_releaseViolatedFloor; // set true if ANY successful release left committed < floor AT that time

    constructor(
        DurationFreezeModule m_,
        MockNavBasket b_,
        MockEulerEarn ee_,
        RecordingSafe main_,
        RecordingSafe side_,
        address op_,
        address[6] memory toks
    ) {
        m = m_;
        basket = b_;
        ee = ee_;
        mainSafe = main_;
        sidecar = side_;
        operator = op_;
        tokens = toks;
    }

    function _tok(uint256 seed) internal view returns (MockERC20) {
        return MockERC20(tokens[seed % tokens.length]);
    }

    /// @dev Recompute the mock basket's committed/gross from the real balances of the FIVE legs across both Safes
    ///      (usdc scaled 6->18; the rest par-ish at 1:1 for the handler's purposes). Keeps the oracle view honest
    ///      relative to the moved balances so the floor check is meaningful.
    function _sync() internal {
        uint256 committed;
        uint256 gross;
        // the five legs (index 0..4); index 5 is the unvalued token, excluded from value by design.
        for (uint256 i = 0; i < 5; i++) {
            MockERC20 t = MockERC20(tokens[i]);
            uint256 scale = t.decimals() == 6 ? 1e12 : 1;
            committed += t.balanceOf(address(sidecar)) * scale;
            gross += (t.balanceOf(address(sidecar)) + t.balanceOf(address(mainSafe))) * scale;
        }
        basket.setValues(committed, gross);
    }

    function bumpUtilization(uint256 sa, uint256 free) external {
        sa = bound(sa, 0, 1e24);
        free = bound(free, 0, 1e24);
        ee.setBacking(sa == 0 ? 0 : 1, sa, free);
    }

    function commit(uint256 tokSeed, uint256 amount) external {
        MockERC20 t = _tok(tokSeed);
        amount = bound(amount, 1, 1e24);
        t.mint(address(mainSafe), amount); // ensure main can fund the move
        vm.prank(operator);
        try m.commit(address(t), amount) {} catch {}
        _sync();
    }

    function release(uint256 tokSeed, uint256 amount) external {
        MockERC20 t = _tok(tokSeed);
        uint256 held = t.balanceOf(address(sidecar));
        if (held == 0) {
            _sync();
            return;
        }
        amount = bound(amount, 1, held);
        // pre-sync so the floor reads the CURRENT committed/gross, then the module checks post-move via _sync inside?
        // The module reads the oracle AFTER its transfer; we must reflect the post-move balances. Since the mock
        // doesn't auto-read, we sync AFTER the transfer would land. Simplest faithful model: let the move happen,
        // then sync; but the floor is read mid-call. So we pre-commit the post-move values: simulate.
        _syncForReleaseSim(t, amount);
        vm.prank(operator);
        try m.release(address(t), amount) {
            lastSuccessfulRelease++;
            // The CORE safety property, checked AT the moment of a successful release (the floor is read live in
            // the same call): committed >= required. If this ever fails the freeze leaked.
            _sync();
            if (m.committedValue() < m.requiredCommittedValue()) ghost_releaseViolatedFloor = true;
        } catch {
            _sync();
        }
    }

    /// @dev Set the mock basket to the POST-move committed/gross so the module's mid-call floor read is faithful to
    ///      what the balances will be after the sidecar->main transfer of `amount` of `t`.
    function _syncForReleaseSim(MockERC20 t, uint256 amount) internal {
        uint256 committed;
        uint256 gross;
        for (uint256 i = 0; i < 5; i++) {
            MockERC20 tk = MockERC20(tokens[i]);
            uint256 scale = tk.decimals() == 6 ? 1e12 : 1;
            uint256 sideBal = tk.balanceOf(address(sidecar));
            uint256 mainBal = tk.balanceOf(address(mainSafe));
            if (address(tk) == address(t)) {
                // post-move: sidecar -amount, main +amount; gross (sum) unchanged
                sideBal = sideBal >= amount ? sideBal - amount : 0;
                mainBal += amount;
            }
            committed += sideBal * scale;
            gross += (sideBal + mainBal) * scale;
        }
        basket.setValues(committed, gross);
    }

    function tokenAt(uint256 i) external view returns (address) {
        return tokens[i];
    }
}

contract DurationFreezeModuleInvariantTest is Test {
    DurationFreezeModule internal m;
    MockNavBasket internal basket;
    MockEulerEarn internal ee;
    RecordingSafe internal mainSafe;
    RecordingSafe internal sidecar;
    FreezeHandler internal handler;

    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockERC20 internal xalpha;
    MockERC20 internal hydx;
    MockERC20 internal ohydx;
    MockERC20 internal unvalued;

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal warehouse = makeAddr("warehouse");

    function setUp() public {
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockERC20(18);
        hydx = new MockERC20(18);
        ohydx = new MockERC20(18);
        unvalued = new MockERC20(18);

        basket = new MockNavBasket(address(zip), address(usdc), address(xalpha), address(hydx), address(ohydx));
        ee = new MockEulerEarn();
        mainSafe = new RecordingSafe();
        sidecar = new RecordingSafe();

        m = _cloneDurationFreezeModule();
        m.setUp(
            abi.encode(
                owner, address(mainSafe), address(sidecar), operator, address(basket), address(ee), warehouse,
                uint256(1e4), uint256(0)
            )
        );

        address[6] memory toks =
            [address(zip), address(usdc), address(xalpha), address(hydx), address(ohydx), address(unvalued)];
        handler = new FreezeHandler(m, basket, ee, mainSafe, sidecar, operator, toks);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = FreezeHandler.commit.selector;
        sels[1] = FreezeHandler.release.selector;
        sels[2] = FreezeHandler.bumpUtilization.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @notice The core safety property: NO successful `release` ever left the sidecar below the live floor at the
    ///         moment of that release. (`commit` is ungated and `U` floats independently via `bumpUtilization`, so
    ///         a GLOBAL `committed >= floor` cannot hold — the floor is a RELEASE-direction bound, which the handler
    ///         records per successful release.) `fail_on_revert = false`; ≥128k calls (256 runs × 500 depth).
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_release_never_breached_floor() public view {
        assertFalse(handler.ghost_releaseViolatedFloor(), "a successful release left committed < floor");
    }
}

// =========================================================================================== Base-fork suite

/// @dev Base-fork: a REAL summoned substrate (the two Safes) + the REAL `SzipNavOracle` (committedValue parity) +
///      a clone of this module via `ModuleProxyFactory`, with `enableModule` on BOTH Safes via the proven Baal
///      `executeAsBaal -> safe.execTransactionFromModule(safe, enableModule(module))` idiom. EulerEarn stays a
///      mock (our pool deploys at item-10, WOOF-04/05 precedent). Proves a real cross-Safe rotation moves the real
///      `committedValue()` and a high-U release reverts `FreezeFloorBreach`.
contract DurationFreezeModuleForkTest is ForkConfig, SummonSubstrate {
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");
    address internal warehouse = makeAddr("warehouse");

    uint256 internal constant SALT = uint256(keccak256("zipcode.freeze.duration.salt.a"));

    MockEulerEarn internal ee;
    SzipNavOracle internal oracle;
    // five leg stand-ins; xAlpha + oHydx expose the marks the real oracle reads (exchangeRate / discount).
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockXAlphaToken internal xalpha;
    MockERC20 internal hydx;
    MockOHydxToken internal ohydx;

    function setUp() public {
        _selectBaseFork();
    }

    /// @dev Enable `module` on `safe` via the Baal idiom: team (a main-Safe owner) drives the main Safe ->
    ///      Baal.executeAsBaal(safe, 0, safe.execTransactionFromModule(safe, enableModule(module))). For the MAIN
    ///      Safe `safe == mainSafe`; for the SIDECAR `safe == sidecar` (Baal is an enabled module on both).
    function _enableViaBaal(address baal, address mainSafe, address safe, address module) internal {
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, module);
        // safe self-calls enableModule via its own execTransactionFromModule (Baal is the calling module).
        bytes memory selfEnable =
            abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, safe, uint256(0), enableMod, uint8(0));
        bytes memory execAsBaal =
            abi.encodeWithSelector(IBaalExecutor.executeAsBaal.selector, safe, uint256(0), selfEnable);
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(mainSafe).execTransaction(baal, 0, execAsBaal, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _setUpSubstrateAndModule()
        internal
        returns (DurationFreezeModule m, address mainSafe, address sidecar)
    {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        mainSafe = s.mainSafe;
        sidecar = s.sidecar;

        // deploy the real legs + oracle (over the real Safes) + a mock EulerEarn.
        vm.warp(block.timestamp + 1);
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockXAlphaToken(18);
        hydx = new MockERC20(18);
        ohydx = new MockOHydxToken(18, 30); // 30% exercise discount (the live oHYDX value)
        ee = new MockEulerEarn();
        oracle = new SzipNavOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER, address(zip), address(usdc), address(xalpha), address(hydx),
            address(ohydx), mainSafe, sidecar, 4 hours, 1 hours, 1000
        );

        // clone the module via the canonical Zodiac ModuleProxyFactory; init via setUp calldata.
        DurationFreezeModule mastercopy = new DurationFreezeModule();
        bytes memory init = abi.encodeWithSelector(
            DurationFreezeModule.setUp.selector,
            abi.encode(
                owner, mainSafe, sidecar, operator, address(oracle), address(ee), warehouse,
                uint256(1e4), uint256(0)
            )
        );
        address clone = IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY)
            .deployModule(address(mastercopy), init, SALT);
        m = DurationFreezeModule(clone);

        // enable the module on BOTH Safes via the Baal idiom.
        _enableViaBaal(s.baal, mainSafe, mainSafe, clone);
        _enableViaBaal(s.baal, mainSafe, sidecar, clone);
        assertTrue(ISafe(mainSafe).isModuleEnabled(clone), "module enabled on main");
        assertTrue(ISafe(sidecar).isModuleEnabled(clone), "module enabled on sidecar");
    }

    function test_fork_real_rotation_moves_real_committedValue() public {
        (DurationFreezeModule m, address mainSafe, address sidecar) = _setUpSubstrateAndModule();

        // seed the main Safe with zipUSD-leg stand-in; sidecar starts empty.
        zip.mint(mainSafe, 100e18);
        assertEq(oracle.committedValue(), 0, "sidecar empty");
        assertEq(oracle.grossBasketValue(), 100e18, "gross == main holdings");

        // low U so the floor allows a free rotation.
        ee.setBacking(1, 100e18, 100e18); // free==sa -> U 0

        vm.prank(operator);
        m.commit(address(zip), 60e18);
        assertEq(zip.balanceOf(sidecar), 60e18, "real cross-Safe transfer landed");
        assertEq(oracle.committedValue(), 60e18, "REAL committedValue moved");
        assertEq(oracle.grossBasketValue(), 100e18, "gross invariant under rotation");
        assertEq(oracle.grossBasketValue(), oracle.committedValue() + oracle.freeValue(), "parity exact (no LP)");

        // a release within the (zero) floor succeeds.
        vm.prank(operator);
        m.release(address(zip), 20e18);
        assertEq(oracle.committedValue(), 40e18, "released 20 back to main");
    }

    function test_fork_high_U_release_reverts_floorBreach() public {
        (DurationFreezeModule m, address mainSafe, address sidecar) = _setUpSubstrateAndModule();

        zip.mint(mainSafe, 100e18);
        ee.setBacking(1, 100e18, 100e18); // U 0
        vm.prank(operator);
        m.commit(address(zip), 100e18); // freeze everything
        assertEq(oracle.committedValue(), 100e18);

        // now set debt huge (free 0) -> illiquidSeniorValue >> gross -> floor CAPPED at gross == 100. Any release breaches.
        ee.setBacking(1, 100e18, 0); // free 0 -> debt = 100e18 * 1e12, capped at gross
        assertEq(m.requiredFraction(), 1e18); // utilization() retained as the §12 metric
        assertEq(m.requiredCommittedValue(), 100e18); // floor capped at gross

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 99e18, 100e18));
        m.release(address(zip), 1e18);

        // the breach rolled back: committedValue intact.
        assertEq(oracle.committedValue(), 100e18, "breach rolled back");
        assertEq(zip.balanceOf(sidecar), 100e18);
    }
}

/// @dev Minimal local interface for the Baal `executeAsBaal` call used by the fork enable idiom.
interface IBaalExecutor {
    function executeAsBaal(address to, uint256 value, bytes calldata data) external;
}
