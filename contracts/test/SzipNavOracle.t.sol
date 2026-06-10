// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IICHIVault} from "../src/interfaces/ichi/IICHIVault.sol";
import {IGauge} from "../src/interfaces/hydrex/IGauge.sol";
import {IOptionToken} from "../src/interfaces/hydrex/IOptionToken.sol";

// --------------------------------------------------------------------------- mocks
contract MockToken {
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 d) {
        decimals = d;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function setTotalSupply(uint256 v) external {
        totalSupply = v;
    }
}

contract MockXAlpha is MockToken {
    uint256 public exchangeRate;

    constructor() MockToken(18) {
        exchangeRate = 1e18;
    }

    function setExchangeRate(uint256 v) external {
        exchangeRate = v;
    }
}

contract MockOHydx is MockToken {
    uint256 public discount;

    constructor(uint256 d) MockToken(18) {
        discount = d;
    }

    function setDiscount(uint256 v) external {
        discount = v;
    }
}

contract MockICHIVault {
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

contract MockGauge {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }
}

// --------------------------------------------------------------------------- tests
contract SzipNavOracleTest is Test {
    SzipNavOracle oracle;

    address forwarder = makeAddr("forwarder");
    address mainSafe = makeAddr("mainSafe");
    address sidecar = makeAddr("sidecar");
    address dc = makeAddr("defaultCoordinator");
    address engineSafe = makeAddr("engineSafe");

    MockToken zip;
    MockToken usdc;
    MockXAlpha xa;
    MockToken hydx;
    MockOHydx ohydx;
    MockToken szip; // the share token

    uint32 constant W = 4 hours;
    uint256 constant MAX_AGE = 12 hours;
    uint256 constant DEV_BPS = 2000; // 20%

    // mirror of the contract events
    event ShareTokenSet(address indexed szipUSD);
    event LegPriceUpdated(uint8 indexed leg, uint256 price, uint48 ts);
    event ProvisionWritten(uint256 provision);
    event Poked(uint32 ts, uint256 cumNav);

    function setUp() public {
        vm.warp(1_000_000); // a non-zero base time
        zip = new MockToken(18);
        usdc = new MockToken(6);
        xa = new MockXAlpha();
        hydx = new MockToken(18);
        ohydx = new MockOHydx(30);
        szip = new MockToken(18);
        oracle = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdc),
            address(xa),
            address(hydx),
            address(ohydx),
            mainSafe,
            sidecar,
            W,
            MAX_AGE,
            DEV_BPS
        );
    }

    // ----------------------------------------------------------------- helpers
    function _push(uint8 leg, uint256 price) internal {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = leg;
        ps[0] = price;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);
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

    // ----------------------------------------------------------------- deploy + wiring
    function test_deploy_immutables() public view {
        assertEq(oracle.getForwarderAddress(), forwarder);
        assertEq(oracle.zipUSD(), address(zip));
        assertEq(oracle.usdc(), address(usdc));
        assertEq(oracle.xAlpha(), address(xa));
        assertEq(oracle.hydx(), address(hydx));
        assertEq(oracle.oHydx(), address(ohydx));
        assertEq(oracle.mainSafe(), mainSafe);
        assertEq(oracle.sidecar(), sidecar);
        assertEq(oracle.W(), W);
        assertEq(oracle.maxAge(), MAX_AGE);
        assertEq(oracle.maxDeviationBps(), DEV_BPS);
        assertEq(oracle.GENESIS_NAV(), 1e18);
        assertEq(oracle.NAV_LEG(), 7);
        assertEq(oracle.NUM_LEGS(), 2);
        assertEq(oracle.CARDINALITY(), 65);
        assertEq(oracle.owner(), address(this));
    }

    function test_ctor_rejects_zero() public {
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        new SzipNavOracle(
            forwarder, address(0), address(usdc), address(xa), address(hydx),
            address(ohydx), mainSafe, sidecar, W, MAX_AGE, DEV_BPS
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), mainSafe, sidecar, 0, MAX_AGE, DEV_BPS
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), mainSafe, sidecar, W, 0, DEV_BPS
        );
    }

    function test_setShareToken_setOnce_and_auth() public {
        vm.expectEmit(true, false, false, false);
        emit ShareTokenSet(address(szip));
        oracle.setShareToken(address(szip));
        assertEq(oracle.shareToken(), address(szip));
        // re-settable (build phase, §17): a second call re-points
        address szip2 = makeAddr("szip2");
        oracle.setShareToken(szip2);
        assertEq(oracle.shareToken(), szip2);
        // non-owner
        SzipNavOracle fresh = new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), mainSafe, sidecar, W, MAX_AGE, DEV_BPS
        );
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        fresh.setShareToken(address(szip));
    }

    function test_setLpPosition_setOnce() public {
        MockICHIVault iv = new MockICHIVault();
        MockGauge g = new MockGauge();
        oracle.setLpPosition(address(iv), address(g));
        assertEq(oracle.ichiVault(), address(iv));
        assertEq(oracle.gauge(), address(g));
        // re-settable (build phase, §17): a second call re-points
        MockICHIVault iv2 = new MockICHIVault();
        oracle.setLpPosition(address(iv2), address(g));
        assertEq(oracle.ichiVault(), address(iv2));
        SzipNavOracle fresh = new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), mainSafe, sidecar, W, MAX_AGE, DEV_BPS
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        fresh.setLpPosition(address(0), address(g));
    }

    function test_setEngineSafe_and_setDefaultCoordinator_setOnce() public {
        oracle.setEngineSafe(engineSafe);
        assertEq(oracle.engineSafe(), engineSafe);
        // re-settable (build phase, §17)
        address es2 = makeAddr("es2");
        oracle.setEngineSafe(es2);
        assertEq(oracle.engineSafe(), es2);
        oracle.setDefaultCoordinator(dc);
        assertEq(oracle.defaultCoordinator(), dc);
        address dc2 = makeAddr("dc2");
        oracle.setDefaultCoordinator(dc2);
        assertEq(oracle.defaultCoordinator(), dc2);
    }

    // ----------------------------------------------------------------- genesis
    function test_genesis_price_before_wiring() public {
        assertEq(oracle.spotNavPerShare(), 1e18);
        assertEq(oracle.navExit(), 1e18); // genesis, twap falls back to spot
        // navEntry reverts: no leg pushed yet
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, uint8(0)));
        oracle.navEntry();
    }

    function test_genesis_price_zero_supply_after_wiring() public {
        oracle.setShareToken(address(szip)); // totalSupply still 0
        zip.setBalance(mainSafe, 500e18); // basket has value but no shares
        assertEq(oracle.spotNavPerShare(), 1e18);
    }

    // ----------------------------------------------------------------- xALPHA rate-oracle staleness gate (8x-02)
    /// @notice When the Base rate oracle is wired, a STALE cross-chain rate halts ISSUANCE (`navEntry`/`fresh`) but
    ///         NOT exit (`navExit` prices off the last rate — the §7 asymmetry). Unwired = unchanged (the 42 pins).
    function test_xAlphaRateOracle_gates_issuance_not_exit() public {
        MockRateOracle rateOracle = new MockRateOracle();
        rateOracle.setRate(1e18);
        rateOracle.setFresh(true);
        oracle.setXAlphaRateOracle(address(rateOracle));
        _pushBoth(1e18, 1e18); // legs fresh

        // fresh rate: issuance works, fresh() true, exit works
        oracle.navEntry();
        assertTrue(oracle.fresh());
        oracle.navExit();

        // stale rate: issuance halts, exit still prices off the last rate
        rateOracle.setFresh(false);
        assertFalse(oracle.fresh());
        vm.expectRevert(SzipNavOracle.StaleRate.selector);
        oracle.navEntry();
        oracle.navExit(); // no revert — exit is unaffected by rate staleness
    }

    function test_xAlphaRateOracle_unset_uses_fallback() public {
        // not wired ⇒ reads IXAlphaRate(xAlpha) directly; navEntry behaves exactly as before (no StaleRate path).
        assertEq(oracle.xAlphaRateOracle(), address(0));
        _pushBoth(1e18, 1e18);
        oracle.navEntry(); // succeeds via the fallback rate read — unchanged
        assertTrue(oracle.fresh());
    }

    // ----------------------------------------------------------------- push path (reportType 7)
    function test_push_updates_cache_and_emits() public {
        vm.expectEmit(true, false, false, true);
        emit LegPriceUpdated(0, 2e18, uint48(block.timestamp));
        vm.expectEmit(true, false, false, true);
        emit LegPriceUpdated(1, 5e17, uint48(block.timestamp));
        _pushBoth(2e18, 5e17);
        (uint256 pa, uint48 ta) = oracle.legCache(0);
        (uint256 ph,) = oracle.legCache(1);
        assertEq(pa, 2e18);
        assertEq(ph, 5e17);
        assertEq(ta, uint48(block.timestamp));
    }

    function test_push_non_forwarder_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        oracle.onReport("", report);
    }

    function test_push_wrong_reportType_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(3), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.InvalidReportType.selector, uint8(3)));
        oracle.onReport("", report);
    }

    function test_push_length_mismatch_reverts() public {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        legs[1] = 1;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.LengthMismatch.selector);
        oracle.onReport("", report);
    }

    function test_push_empty_batch_ok() public {
        uint8[] memory legs = new uint8[](0);
        uint256[] memory ps = new uint256[](0);
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report); // no revert
    }

    function test_push_invalid_leg_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 2; // >= NUM_LEGS
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.InvalidLeg.selector, uint8(2)));
        oracle.onReport("", report);
    }

    function test_push_zero_price_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 0;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.ZeroPrice.selector);
        oracle.onReport("", report);
    }

    function test_push_future_ts_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp + 1)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.FutureTimestamp.selector);
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------------- deviation circuit-break
    function test_deviation_first_push_not_checked() public {
        _push(0, 100e18); // any value ok first time
        (uint256 p,) = oracle.legCache(0);
        assertEq(p, 100e18);
    }

    function test_deviation_within_bound_ok() public {
        _push(0, 1e18);
        _push(0, 119e16); // +19% <= 20%
        (uint256 p,) = oracle.legCache(0);
        assertEq(p, 119e16);
    }

    function test_deviation_exceeded_reverts() public {
        _push(0, 1e18);
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 121e16; // +21% > 20%
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.DeviationExceeded.selector, uint8(0), uint256(1e18), uint256(121e16)));
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------------- atomicity
    function test_batch_atomicity_one_bad_entry_reverts_all() public {
        _push(0, 1e18); // prior for leg 0
        _push(1, 5e17); // prior for leg 1
        // batch: leg0 -> 1.05e18 (ok), leg1 -> 0 (ZeroPrice)
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = 0;
        legs[1] = 1;
        ps[0] = 105e16;
        ps[1] = 0;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.ZeroPrice.selector);
        oracle.onReport("", report);
        // leg 0 must be UNCHANGED (no partial write)
        (uint256 p0,) = oracle.legCache(0);
        assertEq(p0, 1e18);
    }

    // ----------------------------------------------------------------- NAV composition
    function _wireFullBasket() internal {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 100e18);
        zip.setBalance(sidecar, 50e18); // _bal(zip) = 150e18
        usdc.setBalance(mainSafe, 1000e6); // -> 1000e18
        xa.setBalance(mainSafe, 10e18);
        xa.setExchangeRate(12e17); // 1.2
        hydx.setBalance(mainSafe, 5e18);
        ohydx.setBalance(mainSafe, 4e18); // discount 30
        _pushBoth(2e18, 5e17); // alphaUSD=2, hydxUSD=0.5
    }

    function test_nav_composition_handcomputed() public {
        _wireFullBasket();
        // gross = 150 (zip) + 1000 (usdc) + 24 (xa:10*1.2*2) + 2.5 (hydx:5*0.5) + 1.4 (ohydx:4*0.5*0.7) = 1177.9e18
        assertEq(oracle.grossBasketValue(), 11779e17);
        // spot = 1177.9e18 / 1000 = 1.1779e18
        assertEq(oracle.spotNavPerShare(), 11779e14);
    }

    function test_nav_xalpha_exchangeRate_accrual() public {
        _wireFullBasket();
        uint256 before = oracle.spotNavPerShare();
        xa.setExchangeRate(13e17); // LST APR accrues -> xa leg up by 10e18*0.1*2 = 2e18 gross
        assertEq(oracle.grossBasketValue(), 11779e17 + 2e18);
        assertGt(oracle.spotNavPerShare(), before);
    }

    function test_nav_engine_pending_burn_subtracts() public {
        _wireFullBasket();
        uint256 noBurn = oracle.spotNavPerShare(); // supply 1000
        oracle.setEngineSafe(engineSafe);
        szip.setBalance(engineSafe, 100e18); // effective supply 900
        uint256 gross = oracle.grossBasketValue();
        assertEq(oracle.spotNavPerShare(), gross * 1e18 / 900e18);
        assertGt(oracle.spotNavPerShare(), noBurn);
    }

    function test_nav_engine_pending_burn_underflow_floors_to_genesis() public {
        _wireFullBasket();
        oracle.setEngineSafe(engineSafe);
        szip.setBalance(engineSafe, 2000e18); // > totalSupply 1000 -> effective 0
        assertEq(oracle.spotNavPerShare(), 1e18); // genesis, no underflow
    }

    function test_nav_usdc_scale_pinned() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1e18);
        usdc.setBalance(mainSafe, 1e6); // exactly 1 USDC -> $1
        _pushBoth(1e18, 1e18);
        assertEq(oracle.grossBasketValue(), 1e18);
    }

    // ----------------------------------------------------------------- ICHI LP marked-through
    function _wireLp() internal returns (MockICHIVault iv, MockGauge g) {
        iv = new MockICHIVault();
        g = new MockGauge();
        // pool = zipUSD/xALPHA, 1000 LP shares, reserves 200 zipUSD + 100 xALPHA
        iv.set(address(zip), address(xa), 1000e18, 200e18, 100e18);
        oracle.setLpPosition(address(iv), address(g));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        xa.setExchangeRate(12e17);
        _pushBoth(2e18, 5e17); // xAlphaUSD = 1.2*2 = 2.4
    }

    function test_lp_marked_through() public {
        (MockICHIVault iv, MockGauge g) = _wireLp();
        iv.setBalance(mainSafe, 100e18); // unstaked
        g.setBalance(mainSafe, 400e18); // staked -> heldShares 500/1000 = half
        // amt0 = 200*0.5=100 zipUSD -> 100e18 ; amt1 = 100*0.5=50 xAlpha -> 50*2.4=120e18 ; LP = 220e18
        assertEq(oracle.grossBasketValue(), 220e18);
        // IL marked-through: raise alphaUSD -> LP value moves
        uint256 lpBefore = oracle.grossBasketValue();
        _pushBoth(22e17, 5e17); // alphaUSD 2.0 -> 2.2 (within 20%)
        assertGt(oracle.grossBasketValue(), lpBefore);
    }

    function test_lp_unset_contributes_zero() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 100e18);
        _pushBoth(1e18, 1e18);
        assertEq(oracle.grossBasketValue(), 100e18); // no LP leg
    }

    function test_lp_supplyLp_zero_guard() public {
        MockICHIVault iv = new MockICHIVault();
        MockGauge g = new MockGauge();
        iv.set(address(zip), address(xa), 0, 200e18, 100e18); // totalSupply 0
        oracle.setLpPosition(address(iv), address(g));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        g.setBalance(mainSafe, 1); // heldShares != 0 but supplyLp 0
        _pushBoth(1e18, 1e18);
        assertEq(oracle.grossBasketValue(), 0); // no div-by-zero, LP leg 0
    }

    function test_lp_unknown_token_reverts() public {
        MockICHIVault iv = new MockICHIVault();
        MockGauge g = new MockGauge();
        MockToken rogue = new MockToken(18);
        iv.set(address(zip), address(rogue), 1000e18, 200e18, 100e18); // token1 not a known leg
        oracle.setLpPosition(address(iv), address(g));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        g.setBalance(mainSafe, 500e18);
        _pushBoth(1e18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.UnknownLpToken.selector, address(rogue)));
        oracle.grossBasketValue();
    }

    // ----------------------------------------------------------------- TWAP + bracket
    function test_twap_fallback_to_spot_before_W() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18); // spot = 1e18
        _pushBoth(1e18, 1e18);
        assertEq(oracle.twapNavPerShare(), oracle.spotNavPerShare());
    }

    function test_twap_windowed_and_bracket() public {
        uint256 T = block.timestamp;
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18); // spot = 1e18
        _pushBoth(1e18, 1e18); // legs fresh, dt=0 (no accumulate)

        vm.warp(T + 2 hours);
        oracle.poke(); // books spot 1e18 over 2h

        zip.setBalance(mainSafe, 3000e18); // spot = 3e18
        vm.warp(T + 4 hours);
        oracle.poke(); // books spot 3e18 over 2h

        vm.warp(T + 5 hours);
        // cumNow = (1*7200 + 3*7200)e18 + 3e18*3600 = 28800e18 + 10800e18 = 39600e18
        // foundObs at T (ts<=T+1h); twap = 39600e18 / 18000 = 2.2e18
        assertEq(oracle.twapNavPerShare(), 22e17);
        assertEq(oracle.spotNavPerShare(), 3e18);
        assertEq(oracle.navEntry(), 3e18); // max(3, 2.2)
        assertEq(oracle.navExit(), 22e17); // min(3, 2.2)
    }

    function test_poke_dt_zero_is_noop() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18);
        vm.warp(block.timestamp + 1 hours);
        oracle.poke();
        uint256 cumBefore = oracle.cumNav();
        uint16 idxBefore = oracle.obsIndex();
        oracle.poke(); // same block -> no-op (no event, no state change)
        assertEq(oracle.cumNav(), cumBefore);
        assertEq(oracle.obsIndex(), idxBefore);
    }

    function test_twap_ring_wraparound() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18); // stable spot 1e18
        for (uint256 i = 0; i < 70; i++) {
            vm.warp(block.timestamp + 1 hours);
            oracle.poke();
        }
        // 70 successful accumulates from obsIndex 0 -> 70 % 65 = 5
        assertEq(oracle.obsIndex(), 5);
        // twap still computes (no revert) and is ~spot
        assertEq(oracle.twapNavPerShare(), 1e18);
    }

    // ----------------------------------------------------------------- staleness asymmetry
    function test_staleness_pauses_issuance_not_exit() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18);
        _pushBoth(1e18, 1e18);
        assertTrue(oracle.fresh());
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertFalse(oracle.fresh());
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, uint8(0)));
        oracle.navEntry();
        // navExit still works off the last mark
        assertEq(oracle.navExit(), oracle.spotNavPerShare() < oracle.twapNavPerShare() ? oracle.spotNavPerShare() : oracle.twapNavPerShare());
    }

    function test_staleness_single_leg_hydx_stale() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18);
        // push hydx first, then alpha later, then age past hydx but not alpha
        _push(1, 1e18); // hydx at T
        vm.warp(block.timestamp + 6 hours);
        _push(0, 1e18); // alpha at T+6h
        vm.warp(block.timestamp + MAX_AGE - 5 hours); // hydx age ~13h (stale), alpha age ~7h (fresh)
        assertFalse(oracle.fresh());
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, uint8(1)));
        oracle.navEntry();
    }

    // ----------------------------------------------------------------- provision
    function test_provision_auth_and_immediate() public {
        _wireFullBasket();
        // before wiring dc: reverts for everyone
        vm.prank(dc);
        vm.expectRevert(SzipNavOracle.NotDefaultCoordinator.selector);
        oracle.writeProvision(1e18);

        oracle.setDefaultCoordinator(dc);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(SzipNavOracle.NotDefaultCoordinator.selector);
        oracle.writeProvision(1e18);

        uint256 spotBefore = oracle.spotNavPerShare();
        uint256 gross = oracle.grossBasketValue();
        vm.prank(dc);
        vm.expectEmit(false, false, false, true);
        emit ProvisionWritten(90e18);
        oracle.writeProvision(90e18); // 90 USD provision over 1000 shares -> -0.09
        assertEq(oracle.spotNavPerShare(), (gross - 90e18) * 1e18 / 1000e18);
        assertLt(oracle.spotNavPerShare(), spotBefore);

        // recovery: lower provision -> rises
        vm.prank(dc);
        oracle.writeProvision(10e18);
        assertEq(oracle.spotNavPerShare(), (gross - 10e18) * 1e18 / 1000e18);
    }

    function test_provision_unbounded_floors_at_zero() public {
        _wireFullBasket();
        oracle.setDefaultCoordinator(dc);
        vm.prank(dc);
        oracle.writeProvision(type(uint256).max); // unbounded at the oracle
        assertEq(oracle.spotNavPerShare(), 0);
        assertEq(oracle.navExit(), 0);
    }

    // ----------------------------------------------------------------- one-block spike resistance
    function test_one_block_spike_does_not_enable_cheap_mint() public {
        uint256 T = block.timestamp;
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(mainSafe, 1000e18); // spot 1e18
        _pushBoth(1e18, 1e18);
        vm.warp(T + 5 hours);
        oracle.poke(); // establish a twap ~1e18 over the window

        // one-block UP spike (donation)
        zip.setBalance(mainSafe, 2000e18); // spot jumps to 2e18 in this block, twap still ~1e18
        assertEq(oracle.navEntry(), oracle.spotNavPerShare()); // max picks the SPIKE -> minting MORE expensive
        assertGt(oracle.navEntry(), 1e18);
        assertEq(oracle.navExit(), oracle.twapNavPerShare()); // min ignores the up-spike -> ~1e18, no exit-rich
        assertLt(oracle.navExit(), oracle.spotNavPerShare());
    }

    // ----------------------------------------------------------------- fork sig-verification (live Base faces)
    function test_fork_external_signatures() public view {
        if (block.chainid != 8453) return; // self-skip when not on a Base fork
        address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address ICHI = 0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad; // live HYDX ICHI vault
        address GAUGE = 0xAC396CabF5832A49483B78225D902C0999829993; // live Hydrex gauge
        address OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78; // live oHYDX

        assertEq(IERC20(USDC).decimals(), 6);
        // ICHI faces the NAV math depends on
        IICHIVault(ICHI).token0();
        IICHIVault(ICHI).token1();
        (uint256 a, uint256 b) = IICHIVault(ICHI).getTotalAmounts();
        a;
        b;
        assertGt(IICHIVault(ICHI).totalSupply(), 0);
        IICHIVault(ICHI).balanceOf(address(this));
        // gauge balanceOf
        IGauge(GAUGE).balanceOf(address(this));
        // oHYDX discount() == 30 (the intrinsic-mark input)
        assertEq(IOptionToken(OHYDX).discount(), 30);
    }

    // ----------------------------------------------------------------- forwarder immutability via renounce
    function test_forwarder_immutability_and_identity() public {
        bytes32 WID = keccak256("workflow");
        oracle.setExpectedWorkflowId(WID);
        // wrong id -> revert
        bytes memory meta = abi.encodePacked(keccak256("wrong"), bytes10(0), address(0));
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, keccak256("wrong"), WID));
        oracle.onReport(meta, report);

        // renounce -> setters frozen
        oracle.renounceOwnership();
        assertEq(oracle.owner(), address(0));
        vm.expectRevert();
        oracle.setShareToken(address(szip));
        vm.expectRevert();
        oracle.setForwarderAddress(address(1));

        // correct id still works
        bytes memory goodMeta = abi.encodePacked(WID, bytes10(0), address(0));
        vm.prank(forwarder);
        oracle.onReport(goodMeta, report);
        (uint256 p,) = oracle.legCache(0);
        assertEq(p, 1e18);
    }

    // ----------------------------------------------------------------- valueOf (the Exit Gate issuance seam)
    function test_valueOf_zipUSD_is_par() public view {
        // zipUSD is the constant $1 leg (18-dp) — value == amount, no leg push needed.
        assertEq(oracle.valueOf(address(zip), 12e18), 12e18);
        assertEq(oracle.valueOf(address(zip), 0), 0);
        assertEq(oracle.valueOf(address(zip), 1), 1);
    }

    function test_valueOf_xAlpha_two_layer_mark() public {
        // exchangeRate (default 1e18) × alphaUSD (pushed 2e18) = $2 per xALPHA; 5 xALPHA -> $10.
        _pushBoth(2e18, 5e17);
        assertEq(oracle.valueOf(address(xa), 5e18), 10e18);
        // LST APR accrual (exchangeRate up) raises the mark proportionally.
        xa.setExchangeRate(11e17); // 1.1
        assertEq(oracle.valueOf(address(xa), 5e18), 11e18); // 5 * (1.1*2) = 11
        // floor division: 1 wei xALPHA at $2.2 -> 1 * 2.2e18 / 1e18 = 2 (floored, no rounding up)
        assertEq(oracle.valueOf(address(xa), 1), 2);
    }

    function test_valueOf_unsupported_asset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.UnknownLpToken.selector, address(usdc)));
        oracle.valueOf(address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.UnknownLpToken.selector, address(hydx)));
        oracle.valueOf(address(hydx), 1e18);
    }
}

/// @notice Minimal stand-in for `SzAlphaRateOracle` — exposes `exchangeRate()` + `fresh()` for the gate test.
contract MockRateOracle {
    uint256 public r;
    bool public f;

    function setRate(uint256 x) external {
        r = x;
    }

    function setFresh(bool x) external {
        f = x;
    }

    function exchangeRate() external view returns (uint256) {
        return r;
    }

    function fresh() external view returns (bool) {
        return f;
    }
}
