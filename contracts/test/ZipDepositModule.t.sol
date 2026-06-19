// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {ESynth} from "evk/Synths/ESynth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {ExitGate} from "../src/supply/szipUSD/ExitGate.sol";
import {SzipUSD} from "../src/supply/szipUSD/SzipUSD.sol";
import {ZipDepositModule} from "../src/supply/ZipDepositModule.sol";

// =========================================================================================== mocks
/// @dev Minimal configurable-decimals ERC20 (USDC stand-in, EE share base, mock szipUSD). No fee-on-transfer.
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

/// @dev EulerEarn par/non-par mock: itself the 6-dp share token; `deposit` pulls the FULL `assets` (real custody) then
///      mints `assets * num / den` shares to `receiver` (par by default; `9/10`/`11/10` prove share-count-agnosticism).
contract EEMock is MockERC20 {
    address public immutable asset; // USDC
    uint256 public immutable num;
    uint256 public immutable den;

    constructor(address asset_, uint256 num_, uint256 den_) MockERC20(6) {
        asset = asset_;
        num = num_;
        den = den_;
    }

    function deposit(uint256 assets, address receiver) external virtual returns (uint256 shares) {
        require(assets != 0, "EE:ZeroShares");
        MockERC20(asset).transferFrom(msg.sender, address(this), assets); // pull FULL assets (real custody)
        shares = assets * num / den;
        mint(receiver, shares);
    }
}

/// @dev An EE mock whose `deposit` re-enters the module — proves the `nonReentrant` guard covers the EE callout.
contract ReentrantEEMock is EEMock {
    ZipDepositModule public module;

    constructor(address asset_) EEMock(asset_, 1, 1) {}

    function setModule(address m) external {
        module = ZipDepositModule(m);
    }

    function deposit(uint256, address) external override returns (uint256) {
        module.deposit(1e6); // re-enter a guarded fn -> ReentrancyGuardReentrantCall
        return 0;
    }
}

/// @dev A stand-in Exit Gate implementing the `IZipExitGate` seam against the real zipUSD `ESynth` + a mock 18-dp
///      szipUSD and a mock `navPerShare`. Used for the adversarial guard tests the real Gate cannot exhibit
///      (under-pull, no-share, mid-call revert, reentrancy). `depositFor` pulls zipUSD module->this, mints mock
///      szipUSD to `receiver`, records `(amount, receiver)`.
contract MockGate {
    enum Mode {
        Normal, // pull full, mint shares
        UnderPull, // pull HALF -> module sees ResidualBalance
        NoShare, // pull FULL, return 0 -> module sees ZeroShares
        Revert, // revert before doing anything -> atomicity
        Reenter // re-enter the module -> ReentrancyGuardReentrantCall

    }

    address public immutable zipUSD;
    MockERC20 public immutable szip; // mock 18-dp share token
    uint256 public navPerShare = 1e18;
    Mode public mode = Mode.Normal;
    address public module;

    address public lastReceiver;
    uint256 public lastAmount;

    constructor(address zipUSD_) {
        zipUSD = zipUSD_;
        szip = new MockERC20(18);
    }

    function setNav(uint256 n) external {
        navPerShare = n;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setModule(address m) external {
        module = m;
    }

    function _quote(uint256 amount) internal view returns (uint256) {
        return amount * 1e18 / navPerShare; // round down (mirrors the real Gate at navEntry == navPerShare)
    }

    function previewDeposit(address, uint256 amount) external view returns (uint256 shares) {
        return _quote(amount);
    }

    function depositFor(address asset, uint256 amount, address receiver) external returns (uint256 shares) {
        if (mode == Mode.Revert) revert("gate:revert");
        if (mode == Mode.Reenter) {
            ZipDepositModule(module).deposit(1e6); // re-enter a guarded fn
        }
        uint256 pull = mode == Mode.UnderPull ? amount / 2 : amount;
        MockERC20(asset).transferFrom(msg.sender, address(this), pull);
        lastReceiver = receiver;
        lastAmount = amount;
        if (mode == Mode.NoShare) return 0;
        shares = _quote(amount);
        szip.mint(receiver, shares);
    }
}

// =========================================================================================== base harness
/// @dev Shared setup: a live EVC + the REAL zipUSD `ESynth` (the UUT's zipUSD, per WOOF-06), a 6-dp USDC mock, a par
///      EE mock, a `WAREHOUSE_SAFE` test address, and a `MockGate`. No fork needed — EVC/ESynth are plain contracts.
abstract contract ZipModuleBase is Test {
    EthereumVaultConnector internal evc;
    ESynth internal zip; // REAL ESynth = zipUSD (18-dp)
    MockERC20 internal usdc; // 6-dp
    EEMock internal ee; // par EE mock
    MockGate internal gate;
    ZipDepositModule internal module;

    address internal constant WAREHOUSE_SAFE = address(0xBEEF);
    address internal LP = makeAddr("lp");
    address internal USER = makeAddr("user");

    function _baseSetUp() internal {
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        ee = new EEMock(address(usdc), 1, 1);
        gate = new MockGate(address(zip));

        module = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        gate.setModule(address(module));
        zip.setCapacity(address(module), type(uint128).max); // owner == this
        module.setGate(address(gate));
    }

    function _mintUsdc(address to, uint256 amt) internal {
        usdc.mint(to, amt);
    }

    /// @dev Assert the module custodies nothing in any asset.
    function _assertModuleEmpty() internal view {
        assertEq(zip.balanceOf(address(module)), 0, "module holds zipUSD");
        assertEq(usdc.balanceOf(address(module)), 0, "module holds USDC");
        assertEq(ee.balanceOf(address(module)), 0, "module holds EE shares");
        assertEq(gate.szip().balanceOf(address(module)), 0, "module holds szipUSD");
    }
}

// =========================================================================================== mock-gate suite
/// @notice WOOF-06 — the zap mint+deposit router. REAL `ESynth` zipUSD over a live EVC; par/non-par EE mocks; a
///         `MockGate` standing in for the §4/§5 Exit Gate so the adversarial gate behaviours (under-pull, no-share,
///         mid-call revert, reentrancy) the real Gate cannot exhibit are exercised. The real-Gate seam is proven
///         separately on a Base fork (`ZipDepositModuleRealGateTest`).
contract ZipDepositModuleTest is ZipModuleBase {
    function setUp() public {
        _baseSetUp();
    }

    // -------------------------------------------------------------- decimals + scale
    function test_decimals_and_scale() public view {
        assertEq(module.scaleUp(), 1e12, "scaleUp = 10**(18-6)");
        assertEq(zip.decimals(), 18, "zipUSD 18-dp");
        assertEq(module.zipUSD(), address(zip));
        assertEq(module.usdc(), address(usdc));
        assertEq(module.eePool(), address(ee));
        assertEq(module.warehouseSafe(), WAREHOUSE_SAFE);
        assertEq(module.deployer(), address(this));
    }

    // -------------------------------------------------------------- deposit (warehouseSafe custody)
    function test_deposit_warehouse_custody() public {
        _mintUsdc(LP, 1_000_000e6);
        vm.startPrank(LP);
        usdc.approve(address(module), 1_000_000e6);
        vm.expectEmit(true, false, false, true, address(module));
        emit ZipDepositModule.Deposited(LP, 1_000_000e6, 1_000_000e18);
        uint256 ret = module.deposit(1_000_000e6);
        vm.stopPrank();

        assertEq(ret, 1_000_000e18, "return == zip minted");
        assertEq(usdc.balanceOf(LP), 0);
        assertEq(usdc.balanceOf(address(ee)), 1_000_000e6, "USDC parked in pool");
        assertEq(zip.balanceOf(LP), 1_000_000e18, "user holds zipUSD");
        assertEq(zip.totalSupply(), 1_000_000e18);
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), 1_000_000e6, "shares -> warehouseSafe");
        assertEq(ee.balanceOf(address(module)), 0);
        assertEq(usdc.allowance(address(module), address(ee)), 0, "approval consumed");
        _assertModuleEmpty();
        // conservation: USDC in pool * scaleUp == zipUSD supply AND warehouseSafe shares == pooled USDC (par)
        assertEq(usdc.balanceOf(address(ee)) * 1e12, zip.totalSupply());
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), usdc.balanceOf(address(ee)));
    }

    function test_deposit_works_unwired() public {
        // a fresh module with no gate wired still serves plain deposit
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        zip.setCapacity(address(m), type(uint128).max);
        assertEq(m.gate(), address(0));
        _mintUsdc(LP, 500_000e6);
        vm.startPrank(LP);
        usdc.approve(address(m), 500_000e6);
        uint256 ret = m.deposit(500_000e6);
        vm.stopPrank();
        assertEq(ret, 500_000e18);
        assertEq(zip.balanceOf(LP), 500_000e18);
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), 500_000e6);
    }

    // -------------------------------------------------------------- zap (on-behalf szipUSD mint)
    function test_zap_on_behalf_par_nav() public {
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        vm.expectEmit(true, false, false, true, address(module));
        emit ZipDepositModule.Zapped(USER, 200_000e6, 200_000e18, 200_000e18);
        uint256 shares = module.zap(200_000e6);
        vm.stopPrank();

        assertEq(shares, 200_000e18, "par NAV -> shares == zip value");
        assertEq(zip.balanceOf(USER), 0, "user never holds zipUSD");
        assertEq(gate.szip().balanceOf(USER), shares, "user holds szipUSD");
        assertEq(gate.szip().balanceOf(address(module)), 0);
        assertEq(zip.balanceOf(address(module)), 0);
        assertEq(zip.balanceOf(address(gate)), 200_000e18, "gate pulled the basket zipUSD");
        assertEq(zip.allowance(address(module), address(gate)), 0, "per-zap allowance reset to 0");
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), 200_000e6, "shares -> warehouseSafe");
        assertEq(ee.balanceOf(address(module)), 0);
        assertEq(ee.balanceOf(address(gate)), 0);
        assertEq(usdc.balanceOf(address(ee)), 200_000e6);
        // on-behalf correctness
        assertEq(gate.lastReceiver(), USER, "gate recorded the user as receiver");
        assertEq(gate.lastAmount(), 200_000e18, "gate recorded the full zipAmount");
        _assertModuleEmpty();
    }

    function test_zap_nav_proportional_nonpar() public {
        gate.setNav(1.2e18);
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        uint256 shares = module.zap(200_000e6);
        vm.stopPrank();

        uint256 navE = 1.2e18;
        assertEq(shares, uint256(200_000e18) * 1e18 / navE, "shares NAV-scaled, round down");
        assertEq(gate.szip().balanceOf(USER), shares);
        assertEq(zip.balanceOf(address(gate)), 200_000e18, "basket leg is par (value passed through)");
        _assertModuleEmpty();
    }

    // -------------------------------------------------------------- previews
    function test_previewDeposit_standalone_and_unwired() public {
        assertEq(module.previewDeposit(200_000e6), 200_000e18);
        // matches realized deposit
        _mintUsdc(LP, 200_000e6);
        vm.startPrank(LP);
        usdc.approve(address(module), 200_000e6);
        uint256 ret = module.deposit(200_000e6);
        vm.stopPrank();
        assertEq(module.previewDeposit(200_000e6), ret);
        _assertModuleEmpty();
        // works un-wired
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        assertEq(m.gate(), address(0));
        assertEq(m.previewDeposit(123e6), 123e18);
    }

    function test_previewZap_matches_zap() public {
        (uint256 pZip, uint256 pShares) = module.previewZap(200_000e6);
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        uint256 shares = module.zap(200_000e6);
        vm.stopPrank();
        assertEq(pZip, 200_000e18, "preview zip matches");
        assertEq(pShares, shares, "preview shares == realized (fixed NAV)");
        _assertModuleEmpty();
    }

    function test_previewZap_reverts_unwired() public {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        vm.expectRevert(ZipDepositModule.NotWired.selector);
        m.previewZap(1e6);
    }

    // -------------------------------------------------------------- adversarial gate behaviours (F1/F7)
    function test_zap_underpull_reverts_ResidualBalance() public {
        gate.setMode(MockGate.Mode.UnderPull);
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        vm.expectRevert(ZipDepositModule.ResidualBalance.selector);
        module.zap(200_000e6);
        vm.stopPrank();
    }

    /// @notice REGRESSION: a stray zipUSD donation must NOT brick the zap. The cleanliness
    ///         check is a DELTA (the Gate pulled exactly the minted amount), not an absolute zero balance —
    ///         else 1 wei of freely-transferable zipUSD sent to the module permanently DoS's the default UX.
    function test_zap_survives_zipusd_donation() public {
        // griefer parks 1 wei zipUSD on the module
        zip.setCapacity(address(this), type(uint128).max);
        zip.mint(address(module), 1);
        assertEq(zip.balanceOf(address(module)), 1, "donation parked");

        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        uint256 shares = module.zap(200_000e6); // would revert ResidualBalance under the old absolute check
        vm.stopPrank();

        assertGt(shares, 0, "zap succeeded despite the donation");
        assertEq(gate.szip().balanceOf(USER), shares, "user received szipUSD");
        assertEq(zip.balanceOf(address(module)), 1, "net module delta == 0; donation untouched, not bricked");
    }

    /// @notice The under-pull invariant still bites WITH a pre-existing donation (delta, not absolute): the
    ///         Gate pulling less than `zipAmount` leaves balance > `zipBefore` and reverts regardless.
    function testFuzz_zap_tolerates_donation(uint96 donation) public {
        zip.setCapacity(address(this), type(uint128).max);
        if (donation != 0) zip.mint(address(module), donation);
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        uint256 shares = module.zap(200_000e6);
        vm.stopPrank();
        assertGt(shares, 0, "zap succeeds for any pre-existing balance");
        assertEq(zip.balanceOf(address(module)), donation, "delta == 0; donation untouched");
    }

    function test_zap_noshare_reverts_ZeroShares() public {
        gate.setMode(MockGate.Mode.NoShare); // pulls FULL, returns 0
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        vm.expectRevert(ZipDepositModule.ZeroShares.selector);
        module.zap(200_000e6);
        vm.stopPrank();
    }

    function test_zap_gateRevert_atomic_rollback() public {
        // establish some prior state so we can prove the snapshot is restored
        _mintUsdc(LP, 50_000e6);
        vm.startPrank(LP);
        usdc.approve(address(module), 50_000e6);
        module.deposit(50_000e6);
        vm.stopPrank();

        // snapshot
        uint256 modZip = zip.balanceOf(address(module));
        uint256 modUsdc = usdc.balanceOf(address(module));
        uint256 userUsdc;
        uint256 whShares = ee.balanceOf(WAREHOUSE_SAFE);
        uint256 eeUsdc = usdc.balanceOf(address(ee));
        uint256 supply = zip.totalSupply();

        gate.setMode(MockGate.Mode.Revert);
        _mintUsdc(USER, 200_000e6);
        userUsdc = usdc.balanceOf(USER);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        vm.expectRevert(bytes("gate:revert"));
        module.zap(200_000e6);
        vm.stopPrank();

        // pristine post-state
        assertEq(zip.balanceOf(address(module)), modZip);
        assertEq(usdc.balanceOf(address(module)), modUsdc);
        assertEq(usdc.balanceOf(USER), userUsdc, "user USDC untouched");
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), whShares, "warehouseSafe shares unchanged");
        assertEq(usdc.balanceOf(address(ee)), eeUsdc, "pool USDC unchanged");
        assertEq(zip.totalSupply(), supply, "no zipUSD minted");
        assertEq(gate.szip().balanceOf(USER), 0, "no szipUSD minted");
    }

    function test_zap_reentrancy_guarded_via_gate() public {
        gate.setMode(MockGate.Mode.Reenter);
        _mintUsdc(USER, 200_000e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 200_000e6);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        module.zap(200_000e6);
        vm.stopPrank();
    }

    function test_deposit_reentrancy_guarded_via_ee() public {
        // a re-entrant EE mock variant: deposit() re-enters module.deposit -> guarded
        ReentrantEEMock rEE = new ReentrantEEMock(address(usdc));
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(rEE), WAREHOUSE_SAFE);
        rEE.setModule(address(m));
        zip.setCapacity(address(m), type(uint128).max);
        _mintUsdc(LP, 10e6);
        vm.startPrank(LP);
        usdc.approve(address(m), 10e6);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        m.deposit(10e6);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- share-price agnostic (both EE directions)
    function test_deposit_share_price_agnostic_under_par() public {
        _deployWithEE(new EEMock(address(usdc), 9, 10));
    }

    function test_deposit_share_price_agnostic_over_par() public {
        _deployWithEE(new EEMock(address(usdc), 11, 10));
    }

    function _deployWithEE(EEMock customEe) internal {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(customEe), WAREHOUSE_SAFE);
        zip.setCapacity(address(m), type(uint128).max);
        _mintUsdc(LP, 1_000_000e6);
        vm.startPrank(LP);
        usdc.approve(address(m), 1_000_000e6);
        uint256 ret = m.deposit(1_000_000e6);
        vm.stopPrank();
        assertEq(ret, 1_000_000e18, "zip minted is share-count-agnostic");
        assertEq(zip.balanceOf(LP), 1_000_000e18);
        uint256 expShares = 1_000_000e6 * customEe.num() / customEe.den();
        assertEq(customEe.balanceOf(WAREHOUSE_SAFE), expShares, "warehouseSafe shares scaled by EE ratio");
        assertEq(customEe.balanceOf(address(m)), 0);
    }

    // -------------------------------------------------------------- wiring guards
    function test_setGate_guards() public {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        // non-deployer
        vm.prank(LP);
        vm.expectRevert(ZipDepositModule.NotDeployer.selector);
        m.setGate(address(gate));
        // zero addr
        vm.expectRevert(ZipDepositModule.ZeroAddress.selector);
        m.setGate(address(0));
        // happy
        vm.expectEmit(true, false, false, false, address(m));
        emit ZipDepositModule.GateWired(address(gate));
        m.setGate(address(gate));
        assertEq(m.gate(), address(gate));
        assertEq(zip.allowance(address(m), address(gate)), 0, "setGate grants no standing allowance (D1)");
        // re-settable (build phase, §17): a second call re-points, still no standing allowance
        address gate2 = makeAddr("gate2");
        m.setGate(gate2);
        assertEq(m.gate(), gate2);
        assertEq(zip.allowance(address(m), gate2), 0, "re-point grants no standing allowance (D1)");
    }

    function test_zap_before_wiring_reverts_NotWired() public {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        zip.setCapacity(address(m), type(uint128).max);
        _mintUsdc(USER, 1e6);
        vm.startPrank(USER);
        usdc.approve(address(m), 1e6);
        vm.expectRevert(ZipDepositModule.NotWired.selector);
        m.zap(1e6);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- ctor guards
    function test_ctor_zero_address_reverts() public {
        vm.expectRevert(ZipDepositModule.ZeroAddress.selector);
        new ZipDepositModule(address(0), address(usdc), address(ee), WAREHOUSE_SAFE);
        vm.expectRevert(ZipDepositModule.ZeroAddress.selector);
        new ZipDepositModule(address(zip), address(0), address(ee), WAREHOUSE_SAFE);
        vm.expectRevert(ZipDepositModule.ZeroAddress.selector);
        new ZipDepositModule(address(zip), address(usdc), address(0), WAREHOUSE_SAFE);
        vm.expectRevert(ZipDepositModule.ZeroAddress.selector);
        new ZipDepositModule(address(zip), address(usdc), address(ee), address(0));
    }

    function test_ctor_reverts_when_usdc_finer_than_zip() public {
        MockERC20 fatUsdc = new MockERC20(24); // usdcDec > zipDec
        vm.expectRevert(ZipDepositModule.DecimalsTooFew.selector);
        new ZipDepositModule(address(zip), address(fatUsdc), address(ee), WAREHOUSE_SAFE);
    }

    // -------------------------------------------------------------- zero-amount guards
    function test_zero_amount_guards() public {
        vm.expectRevert(ZipDepositModule.ZeroAmount.selector);
        module.deposit(0);
        vm.expectRevert(ZipDepositModule.ZeroAmount.selector);
        module.zap(0);
    }

    // -------------------------------------------------------------- capacity (negative)
    function test_deposit_ungranted_capacity_reverts() public {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        // NO setCapacity
        _mintUsdc(LP, 1e6);
        vm.startPrank(LP);
        usdc.approve(address(m), 1e6);
        vm.expectRevert(ESynth.E_CapacityReached.selector);
        m.deposit(1e6);
        vm.stopPrank();
    }

    function test_deposit_bounded_capacity_reverts_and_rolls_back() public {
        ZipDepositModule m = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        zip.setCapacity(address(m), 500_000e18); // bounded below the mint
        _mintUsdc(LP, 1_000_000e6);
        uint256 supplyBefore = zip.totalSupply();
        vm.startPrank(LP);
        usdc.approve(address(m), 1_000_000e6);
        vm.expectRevert(ESynth.E_CapacityReached.selector);
        m.deposit(1_000_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(m)), 0, "module USDC rolled back");
        assertEq(usdc.balanceOf(LP), 1_000_000e6, "user USDC restored");
        assertEq(zip.totalSupply(), supplyBefore, "no zipUSD minted");
    }

    function test_deposit_overflow_boundary_reverts_capacity_not_panic() public {
        // usdcIn just above type(uint128).max / scaleUp -> zipMinted > uint128.max -> ESynth E_CapacityReached
        // (NOT a Panic; the contract does not pre-multiply into an overflow). Capacity granted = max.
        uint256 usdcIn = uint256(type(uint128).max) / module.scaleUp() + 1;
        _mintUsdc(LP, usdcIn);
        vm.startPrank(LP);
        usdc.approve(address(module), usdcIn);
        vm.expectRevert(ESynth.E_CapacityReached.selector);
        module.deposit(usdcIn);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- sequential / no residue
    function test_sequential_no_residue() public {
        _mintUsdc(LP, 2_000_000e6);
        _mintUsdc(USER, 400_000e6);
        vm.startPrank(LP);
        usdc.approve(address(module), 2_000_000e6);
        module.deposit(1_000_000e6);
        module.deposit(1_000_000e6);
        vm.stopPrank();
        vm.startPrank(USER);
        usdc.approve(address(module), 400_000e6);
        module.zap(200_000e6);
        module.zap(200_000e6);
        vm.stopPrank();
        _assertModuleEmpty();
        assertEq(zip.allowance(address(module), address(ee)), 0);
        assertEq(zip.allowance(address(module), address(gate)), 0);
    }

    // -------------------------------------------------------------- fuzz
    function testFuzz_deposit(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1, uint256(type(uint128).max) / module.scaleUp());
        _mintUsdc(LP, usdcIn);
        vm.startPrank(LP);
        usdc.approve(address(module), usdcIn);
        uint256 ret = module.deposit(usdcIn);
        vm.stopPrank();
        assertEq(ret, usdcIn * module.scaleUp());
        assertEq(zip.balanceOf(LP), usdcIn * 1e12);
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), usdcIn);
        _assertModuleEmpty();
    }

    function testFuzz_zap(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1, uint256(type(uint128).max) / module.scaleUp());
        _mintUsdc(USER, usdcIn);
        vm.startPrank(USER);
        usdc.approve(address(module), usdcIn);
        uint256 shares = module.zap(usdcIn);
        vm.stopPrank();
        assertEq(shares, usdcIn * 1e12, "par NAV: shares == zip value");
        assertEq(gate.szip().balanceOf(USER), shares);
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), usdcIn);
        _assertModuleEmpty();
    }
}

// =========================================================================================== real-gate fork suite
/// @notice WOOF-06 against the LIVE Exit Gate seam (not a mock): real Baal substrate (8-B1 `_summon`) + real
///         `SzipNavOracle` + real `ExitGate` + real `SzipUSD`, with the REAL zipUSD `ESynth` as both the module's
///         zipUSD and the Gate's basket leg. Proves the zap genuinely composes end-to-end: USDC -> zipUSD -> the
///         Gate values it NAV-proportionally and mints transferable szipUSD on-behalf to the user; `previewZap`
///         matches the realized zap; the module is stateless. This discharges the kickoff mandate to materialize
///         WOOF-06 against the real `gate.depositFor` seam.
contract ZipDepositModuleRealGateTest is ForkConfig, SummonSubstrate {
    uint256 internal constant SALT = uint256(keccak256("zipcode.woof06.realgate.salt"));
    uint32 internal constant W = 4 hours;
    uint256 internal constant MAX_AGE = 1 days;
    uint256 internal constant DEV_BPS = 2000;
    uint256 internal constant TVL_CAP = 100_000_000e18;
    address internal constant WAREHOUSE_SAFE = address(0xBEEF);

    address internal team = makeAddr("teamMultisig");
    address internal keeper = makeAddr("windowKeeper");
    address internal engine = makeAddr("juniorTrancheEngine");
    address internal forwarder = makeAddr("forwarder");
    address internal USER = makeAddr("user");

    Substrate internal sub;
    EthereumVaultConnector internal evc;
    ESynth internal zip; // REAL zipUSD
    MockERC20 internal usdc;
    MockXAlpha internal xa;
    MockERC20 internal hydx;
    MockOHydx internal ohydx;
    EEMock internal ee;
    SzipNavOracle internal oracle;
    ExitGate internal gate;
    SzipUSD internal szip;
    ZipDepositModule internal module;

    function setUp() public {
        _selectBaseFork();
        vm.warp(1_000_000);

        // real substrate
        vm.startPrank(team);
        sub = _summon(team, SALT);
        vm.stopPrank();

        // tokens: REAL zipUSD ESynth + mock basket/oracle legs
        evc = new EthereumVaultConnector();
        zip = new ESynth(address(evc), "Zipcode USD", "zipUSD");
        usdc = new MockERC20(6);
        xa = new MockXAlpha();
        hydx = new MockERC20(18);
        ohydx = new MockOHydx(30);
        ee = new EEMock(address(usdc), 1, 1);

        // real oracle over the real Safes, zipUSD = the real ESynth
        oracle = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdc),
            address(xa),
            address(hydx),
            address(ohydx),
            sub.juniorTrancheSafe,
            sub.juniorTrancheSidecar,
            W,
            MAX_AGE,
            DEV_BPS
        );

        // real Gate + szipUSD
        gate = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), TVL_CAP);
        szip = new SzipUSD(address(gate));
        gate.setShareToken(address(szip));
        gate.setWindowController(keeper);
        gate.setJuniorTrancheEngine(engine);
        oracle.setShareToken(address(szip));
        _grantManager(address(gate));
        _pushBoth(1e18, 5e17);

        // the module wired to the real Gate
        module = new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE);
        zip.setCapacity(address(module), type(uint128).max);
        module.setGate(address(gate));
    }

    // ---------------- helpers (mirroring ExitGate.t.sol) ----------------
    function _grantManager(address shaman) internal {
        bytes memory data = abi.encodeWithSelector(IBaal.setShamans.selector, _arr(shaman), _arrU(2));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(sub.juniorTrancheSafe).execTransaction(sub.baal, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _pushBoth(uint256 alphaUSD, uint256 hydxUSD) internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = oracle.LEG_ALPHA_USD();
        legs[1] = oracle.LEG_HYDX_USD();
        ps[0] = alphaUSD;
        ps[1] = hydxUSD;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _arrU(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    // ---------------- tests ----------------
    function test_real_zap_genesis_par() public {
        uint256 usdcIn = 200_000e6;
        usdc.mint(USER, usdcIn);

        (uint256 pZip, uint256 pShares) = module.previewZap(usdcIn);

        vm.startPrank(USER);
        usdc.approve(address(module), usdcIn);
        uint256 shares = module.zap(usdcIn);
        vm.stopPrank();

        // genesis NAV = $1 -> shares == zip value == 200_000e18
        assertEq(shares, 200_000e18, "genesis par shares");
        assertEq(pZip, 200_000e18, "preview zip");
        assertEq(pShares, shares, "previewZap shares == realized (same block, fresh oracle)");
        assertEq(szip.balanceOf(USER), shares, "user holds szipUSD");
        assertEq(zip.balanceOf(USER), 0, "user never holds zipUSD");
        assertEq(zip.balanceOf(sub.juniorTrancheSafe), 200_000e18, "zipUSD landed in the basket (main Safe)");
        assertEq(szip.totalSupply(), shares);
        // the real two-token invariant: szip supply == Loot held by the Gate
        assertEq(szip.totalSupply(), MockERC20Like(sub.loot).balanceOf(address(gate)), "two-token invariant");
        assertEq(IBaal(sub.baal).totalShares(), 0, "zero Shares");
        // module stateless
        assertEq(zip.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(zip.allowance(address(module), address(gate)), 0, "per-zap allowance reset");
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), 200_000e6, "EE shares -> warehouseSafe");
    }

    function test_real_zap_nav_proportional() public {
        // first zap establishes supply (12e18 shares, basket 12e18 zip, spot $1)
        uint256 first = 12e6;
        usdc.mint(USER, first);
        vm.startPrank(USER);
        usdc.approve(address(module), first);
        module.zap(first);
        vm.stopPrank();
        assertEq(szip.totalSupply(), 12e18);

        // bump the basket: mint 2.4e18 zipUSD straight into the main Safe -> gross 14.4e18 / supply 12e18 = spot $1.2
        zip.setCapacity(address(this), type(uint128).max);
        zip.mint(sub.juniorTrancheSafe, 24e17);

        // second zap of 12 USDC -> value 12e18 / navEntry($1.2) = 10e18 shares (round down)
        usdc.mint(USER, 12e6);
        vm.startPrank(USER);
        usdc.approve(address(module), 12e6);
        uint256 shares = module.zap(12e6);
        vm.stopPrank();
        assertEq(shares, 10e18, "navEntry $1.2 -> 10 shares");
        assertEq(szip.balanceOf(USER), 22e18, "12 + 10 shares");
        // module stateless after both zaps
        assertEq(zip.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(szip.balanceOf(address(module)), 0);
        assertEq(zip.allowance(address(module), address(gate)), 0);
    }

    function test_real_deposit_plain() public {
        uint256 usdcIn = 1_000_000e6;
        usdc.mint(USER, usdcIn);
        vm.startPrank(USER);
        usdc.approve(address(module), usdcIn);
        uint256 ret = module.deposit(usdcIn);
        vm.stopPrank();
        assertEq(ret, 1_000_000e18);
        assertEq(zip.balanceOf(USER), 1_000_000e18, "plain deposit: user holds zipUSD, no szipUSD");
        assertEq(szip.balanceOf(USER), 0);
        assertEq(ee.balanceOf(WAREHOUSE_SAFE), 1_000_000e6);
        // module stateless
        assertEq(zip.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
    }
}

/// @dev tiny reader for the Baal Loot ERC20 balance (avoids importing the full token interface).
interface MockERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @dev oHYDX stub exposing `discount()` (the oracle reads it). Mirrors ExitGate.t.sol.
contract MockOHydx is MockERC20 {
    uint256 public discount;

    constructor(uint256 d) MockERC20(18) {
        discount = d;
    }
}

/// @dev xALPHA stub exposing the LST `exchangeRate()` the oracle's two-layer mark reads. Mirrors ExitGate.t.sol.
contract MockXAlpha is MockERC20 {
    uint256 public exchangeRate = 1e18;

    constructor() MockERC20(18) {}
}
