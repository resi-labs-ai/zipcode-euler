// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipNavOracleDemoVAMM} from "../../src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";

/// @notice Dedicated unit + fuzz suite for the DEMO NAV-oracle fork — ported from `test/SzipNavOracle.t.sol`
///         (the audited prod parent) with the ONLY differing seam swapped: the prod ICHI LP leg
///         (`getTotalAmounts()` + farm utility escrow) becomes the demo's **Solidly vAMM pair** leg
///         (`getReserves()` pro-rata, HYDX/USDC priced via `_legPriceOfToken`). Mocks are `setBalance`-style
///         (no real transfers), mirroring the prod suite. Converts the fork from EXPOSED (no dedicated tests).

// --------------------------------------------------------------------------- mocks (ported)
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
}

contract MockGauge {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }
}

/// @dev The DEMO seam: a Solidly vAMM pair priced via `getReserves()` (NOT ICHI `getTotalAmounts`). The pair IS
///      the LP token (`balanceOf`/`totalSupply`); `token0`/`token1` are the priced reserve assets (HYDX/USDC).
contract MockVammPair {
    address public token0;
    address public token1;
    uint256 public totalSupply;
    uint256 internal r0;
    uint256 internal r1;
    mapping(address => uint256) public balanceOf;

    function set(address t0, address t1, uint256 supply, uint256 reserve0, uint256 reserve1) external {
        token0 = t0;
        token1 = t1;
        totalSupply = supply;
        r0 = reserve0;
        r1 = reserve1;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function getReserves() external view returns (uint256, uint256, uint256) {
        return (r0, r1, 0);
    }
}

/// @dev The wired Base xALPHA rate oracle face (`exchangeRate()` + `fresh()`).
contract MockRateOracle {
    uint256 public exchangeRate = 1e18;
    bool public fresh = true;

    function setExchangeRate(uint256 v) external {
        exchangeRate = v;
    }

    function setFresh(bool v) external {
        fresh = v;
    }

    function lastUpdate() external pure returns (uint48) {
        return 1;
    }
}

// --------------------------------------------------------------------------- tests
contract SzipNavOracleDemoVAMMTest is Test {
    SzipNavOracleDemoVAMM oracle;

    address forwarder = makeAddr("forwarder");
    address safe = makeAddr("juniorTrancheSafe");
    address sidecar = makeAddr("juniorTrancheSidecar");
    address dc = makeAddr("defaultCoordinator");
    address engine = makeAddr("juniorTrancheEngine");
    address rando = makeAddr("rando");

    MockToken zip;
    MockToken usdc;
    MockXAlpha xa;
    MockToken hydx;
    MockOHydx ohydx;
    MockToken szip;

    uint32 constant W = 4 hours;
    uint256 constant MAX_AGE = 12 hours;
    uint256 constant DEV_BPS = 2000; // 20%

    function setUp() public {
        vm.warp(1_000_000);
        zip = new MockToken(18);
        usdc = new MockToken(6);
        xa = new MockXAlpha();
        hydx = new MockToken(18);
        ohydx = new MockOHydx(30);
        szip = new MockToken(18);
        oracle = new SzipNavOracleDemoVAMM(
            forwarder, address(zip), address(usdc), address(xa), address(hydx), address(ohydx), safe, sidecar, W, MAX_AGE, DEV_BPS
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

    function _wireSupply(uint256 supply) internal {
        vm.prank(address(this));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(supply);
    }

    // ----------------------------------------------------------------- deploy + ctor
    function test_deploy_immutables() public view {
        assertEq(oracle.getForwarderAddress(), forwarder);
        assertEq(oracle.zipUSD(), address(zip));
        assertEq(oracle.usdc(), address(usdc));
        assertEq(oracle.xAlpha(), address(xa));
        assertEq(oracle.hydx(), address(hydx));
        assertEq(oracle.oHydx(), address(ohydx));
        assertEq(oracle.juniorTrancheSafe(), safe);
        assertEq(oracle.juniorTrancheSidecar(), sidecar);
        assertEq(oracle.GENESIS_NAV(), 1e18);
        assertEq(oracle.NAV_LEG(), 7);
        assertEq(oracle.owner(), address(this));
    }

    function test_ctor_rejects_zero_address() public {
        vm.expectRevert(SzipNavOracleDemoVAMM.ZeroAddress.selector);
        new SzipNavOracleDemoVAMM(
            forwarder, address(0), address(usdc), address(xa), address(hydx), address(ohydx), safe, sidecar, W, MAX_AGE, DEV_BPS
        );
        vm.expectRevert(SzipNavOracleDemoVAMM.ZeroAddress.selector);
        new SzipNavOracleDemoVAMM(
            forwarder, address(zip), address(usdc), address(xa), address(hydx), address(ohydx), safe, sidecar, 0, MAX_AGE, DEV_BPS
        );
    }

    // ----------------------------------------------------------------- setters (Timelock, re-pointable §17)
    function test_setters_onlyOwner_and_zero_checks() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        oracle.setShareToken(address(szip));

        vm.startPrank(address(this));
        oracle.setShareToken(address(szip));
        assertEq(oracle.shareToken(), address(szip));
        vm.expectRevert(SzipNavOracleDemoVAMM.ZeroAddress.selector);
        oracle.setShareToken(address(0));

        oracle.setDefaultCoordinator(dc);
        assertEq(oracle.defaultCoordinator(), dc);

        // setXAlphaRateOracle accepts zero (the "use fallback" sentinel)
        oracle.setXAlphaRateOracle(address(0));
        assertEq(oracle.xAlphaRateOracle(), address(0));
        vm.stopPrank();
    }

    function test_setLpPosition_repointable() public {
        MockVammPair p1 = new MockVammPair();
        MockGauge g = new MockGauge();
        oracle.setLpPosition(address(p1), address(g));
        assertEq(oracle.ichiVault(), address(p1));
        // re-pointable (NOT set-once, §17 build phase)
        MockVammPair p2 = new MockVammPair();
        oracle.setLpPosition(address(p2), address(g));
        assertEq(oracle.ichiVault(), address(p2));
        vm.expectRevert(SzipNavOracleDemoVAMM.ZeroAddress.selector);
        oracle.setLpPosition(address(0), address(g));
    }

    // ----------------------------------------------------------------- the CRE leg push
    function test_push_lands_prices() public {
        _pushBoth(1.2e18, 0.5e18);
        // grossBasketValue reads legCache prices; a tiny hydx balance proves the HYDX leg landed.
        hydx.setBalance(safe, 2e18);
        assertEq(oracle.grossBasketValue(), 2e18 * 0.5e18 / 1e18, "hydx leg priced");
    }

    function test_push_non_forwarder_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 1;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, rando, forwarder));
        oracle.onReport("", report);
    }

    function test_push_wrong_reportType_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 1;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(3), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracleDemoVAMM.InvalidReportType.selector, uint8(3)));
        oracle.onReport("", report);
    }

    function test_push_zeroPrice_reverts() public {
        uint8 hydxLeg = oracle.LEG_HYDX_USD(); // read BEFORE expectRevert (it gates the NEXT call)
        vm.expectRevert(SzipNavOracleDemoVAMM.ZeroPrice.selector);
        _push(hydxLeg, 0);
    }

    function test_push_invalidLeg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracleDemoVAMM.InvalidLeg.selector, uint8(5)));
        _push(5, 1e18);
    }

    function test_push_futureTimestamp_reverts() public {
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 1;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp + 1)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracleDemoVAMM.FutureTimestamp.selector);
        oracle.onReport("", report);
    }

    function test_push_deviation_band_rejects() public {
        uint8 hydxLeg = oracle.LEG_HYDX_USD(); // read BEFORE expectRevert
        _push(hydxLeg, 1e18);
        vm.warp(block.timestamp + 1);
        // +21% > 20% band
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracleDemoVAMM.DeviationExceeded.selector, hydxLeg, uint256(1e18), uint256(1.21e18)));
        _push(hydxLeg, 1.21e18);
        // +20% exactly lands
        _push(hydxLeg, 1.2e18);
    }

    function test_push_lengthMismatch_reverts() public {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        legs[1] = 1;
        ps[0] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracleDemoVAMM.LengthMismatch.selector);
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------------- freshness
    function test_fresh_requires_both_legs_within_maxAge() public {
        assertFalse(oracle.fresh(), "unset legs are stale");
        _pushBoth(1e18, 1e18);
        assertTrue(oracle.fresh(), "both legs fresh");
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertFalse(oracle.fresh(), "aged past maxAge");
    }

    // ----------------------------------------------------------------- NAV: plain legs
    function test_grossBasketValue_plain_legs() public {
        _pushBoth(1e18, 1e18); // alphaUSD=1, hydxUSD=1
        zip.setBalance(safe, 100e18); // $100
        usdc.setBalance(sidecar, 50e6); // $50 (6->18dp)
        xa.setBalance(safe, 10e18); // 10 xALPHA @ (rate 1 * alphaUSD 1) = $10
        // gross = 100 + 50 + 10 = 160
        assertEq(oracle.grossBasketValue(), 160e18, "plain-leg gross");
    }

    function test_spotNavPerShare_genesis_and_priced() public {
        // genesis: zero effective supply -> GENESIS_NAV
        assertEq(oracle.spotNavPerShare(), 1e18, "genesis nav");
        _pushBoth(1e18, 1e18);
        zip.setBalance(safe, 200e18); // $200 basket
        _wireSupply(100e18); // 100 shares
        assertEq(oracle.spotNavPerShare(), 2e18, "nav = $200 / 100 shares = $2");
    }

    // ----------------------------------------------------------------- THE SEAM: vAMM LP valuation
    function test_vamm_lp_leg_valuation() public {
        _push(oracle.LEG_HYDX_USD(), 1e18); // $1 / HYDX
        MockVammPair pair = new MockVammPair();
        MockGauge g = new MockGauge();
        // pair tokens = HYDX/USDC; supply 1000; reserves 10 HYDX + 20 USDC(6dp)
        pair.set(address(hydx), address(usdc), 1000, 10e18, 20e6);
        oracle.setLpPosition(address(pair), address(g));
        // the Safe holds 50 LP in the pair + 50 staked in the gauge = 100/1000 = 10% of reserves
        pair.setBalance(safe, 50);
        g.setBalance(safe, 50);
        // amt0 = 10e18 * 100/1000 = 1e18 HYDX -> $1 ; amt1 = 20e6 * 100/1000 = 2e6 USDC -> $2
        assertEq(oracle.grossBasketValue(), 3e18, "LP leg = 1 HYDX@$1 + 2 USDC@$1 = $3");
    }

    function test_vamm_lp_zero_when_unwired_or_empty() public {
        _push(oracle.LEG_HYDX_USD(), 1e18);
        assertEq(oracle.grossBasketValue(), 0, "no LP wired, no balances -> 0");
        MockVammPair pair = new MockVammPair();
        MockGauge g = new MockGauge();
        pair.set(address(hydx), address(usdc), 1000, 10e18, 20e6);
        oracle.setLpPosition(address(pair), address(g));
        // no held shares -> LP contributes 0
        assertEq(oracle.grossBasketValue(), 0, "wired but no held LP -> 0");
    }

    // ----------------------------------------------------------------- bracket (navEntry/navExit)
    function test_navEntry_max_navExit_min() public {
        _pushBoth(1e18, 1e18);
        zip.setBalance(safe, 100e18);
        _wireSupply(100e18); // spot = $1
        oracle.poke();
        vm.warp(block.timestamp + W + 1);
        // raise the basket so spot rises above the trailing twap
        zip.setBalance(safe, 200e18);
        _pushBoth(1e18, 1e18); // refresh legs (not stale) at the new time
        uint256 spot = oracle.spotNavPerShare();
        uint256 twap = oracle.twapNavPerShare();
        assertGe(spot, twap, "spot rose above twap");
        assertEq(oracle.navEntry(), spot > twap ? spot : twap, "navEntry = max(spot,twap)");
        assertEq(oracle.navExit(), spot < twap ? spot : twap, "navExit = min(spot,twap)");
    }

    function test_navEntry_reverts_on_stale_leg() public {
        _pushBoth(1e18, 1e18);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracleDemoVAMM.StalePrice.selector, oracle.LEG_ALPHA_USD()));
        oracle.navEntry();
    }

    function test_navEntry_reverts_on_stale_rate_oracle() public {
        _pushBoth(1e18, 1e18);
        MockRateOracle ro = new MockRateOracle();
        ro.setFresh(false);
        oracle.setXAlphaRateOracle(address(ro));
        vm.expectRevert(SzipNavOracleDemoVAMM.StaleRate.selector);
        oracle.navEntry();
    }

    // ----------------------------------------------------------------- provision (DC-only)
    function test_writeProvision_only_defaultCoordinator() public {
        oracle.setDefaultCoordinator(dc);
        vm.prank(rando);
        vm.expectRevert(SzipNavOracleDemoVAMM.NotDefaultCoordinator.selector);
        oracle.writeProvision(1e18);
    }

    function test_writeProvision_subtracts_from_gross() public {
        oracle.setDefaultCoordinator(dc);
        _pushBoth(1e18, 1e18);
        zip.setBalance(safe, 200e18);
        _wireSupply(100e18);
        assertEq(oracle.spotNavPerShare(), 2e18, "pre-provision nav");
        vm.prank(dc);
        oracle.writeProvision(50e18); // $50 impairment
        assertEq(oracle.spotNavPerShare(), 1.5e18, "nav drops by provision/supply = $0.5");
    }

    // ----------------------------------------------------------------- valueOf
    function test_valueOf_whitelisted_assets() public {
        _push(oracle.LEG_HYDX_USD(), 1e18);
        assertEq(oracle.valueOf(address(zip), 5e18), 5e18, "zipUSD $1");
        assertEq(oracle.valueOf(address(usdc), 5e6), 5e18, "usdc 6->18dp $1");
        assertEq(oracle.valueOf(address(hydx), 3e18), 3e18, "hydx @ pushed $1");
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracleDemoVAMM.UnknownLpToken.selector, rando));
        oracle.valueOf(rando, 1e18);
    }

    // ----------------------------------------------------------------- fuzz (tier-mover)
    /// @notice Fuzz the spot-NAV formula over basket value, supply, and provision: at non-zero supply
    ///         `spotNavPerShare == (gross - provision) * 1e18 / supply`, floored at 0; genesis at zero supply.
    function testFuzz_spotNavFormula(uint128 zipBal, uint128 supplySeed, uint128 prov) public {
        _pushBoth(1e18, 1e18);
        uint256 supply = bound(uint256(supplySeed), 1, 1e30);
        zip.setBalance(safe, zipBal);
        _wireSupply(supply);
        oracle.setDefaultCoordinator(dc);
        vm.prank(dc);
        oracle.writeProvision(prov);

        uint256 gross = uint256(zipBal); // only the zip leg funded
        uint256 net = gross > prov ? gross - prov : 0;
        assertEq(oracle.spotNavPerShare(), net * 1e18 / supply, "spot = (gross-provision)*1e18/supply");
    }

    // ----------------------------------------------------------------- HYDREX-ADV-01: restored parent guards
    /// @notice obsSpacing throttle (back-ported): permissionless poke() spam must NOT evict the TWAP ring —
    ///         obsIndex advances at most once per obsSpacing, not once per poke (else the bracket collapses to spot).
    function test_obsSpacing_pokeSpam_cannot_collapse_window() public {
        assertEq(oracle.obsIndex(), 0);
        uint32 sp = oracle.obsSpacing();
        assertGt(sp, 1, "obsSpacing must be derived (>1)");
        // 100 rapid pokes, each +2s — total 200s, far under obsSpacing → no slot advance (head refreshes in place).
        for (uint256 i = 0; i < 100; i++) {
            vm.warp(block.timestamp + 2);
            oracle.poke();
        }
        assertEq(oracle.obsIndex(), 0, "poke-spam evicted the ring (obsSpacing throttle missing)");
        // once obsSpacing has elapsed since the head, a single poke DOES advance one slot.
        vm.warp(block.timestamp + sp);
        oracle.poke();
        assertEq(oracle.obsIndex(), 1, "slot did not advance after obsSpacing elapsed");
    }

    /// @notice StaleReport (back-ported): a leg push not strictly-newer than the cached one (replay/out-of-order)
    ///         must revert — the deviation band is price-only, so a backdated in-band replay would otherwise land.
    function test_staleReport_non_newer_push_reverts() public {
        _push(oracle.LEG_ALPHA_USD(), 1e18); // prior.ts = block.timestamp
        // a second push with a NON-newer ts (== prior) and an in-band price must revert StaleReport.
        uint8[] memory legs = new uint8[](1);
        legs[0] = oracle.LEG_ALPHA_USD();
        uint256[] memory ps = new uint256[](1);
        ps[0] = 1.05e18; // within the 20% band → passes deviation, must hit StaleReport
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracleDemoVAMM.StaleReport.selector);
        oracle.onReport("", report);
    }

    /// @notice RateUnseeded (back-ported): an unseeded xALPHA rate source (exchangeRate()==0) must fail closed,
    ///         not silently value the xALPHA leg at $0.
    function test_rateUnseeded_zero_rate_reverts() public {
        _pushBoth(1e18, 1e18); // seed the leg marks so the xALPHA leg is priced off a real alphaUSD
        xa.setBalance(safe, 1e18); // fund the xALPHA basket leg so grossBasketValue prices it
        xa.setExchangeRate(0); // unseeded rate source (M1 stand-in: xAlphaRateOracle == 0 ⇒ reads xa directly)
        vm.expectRevert(SzipNavOracleDemoVAMM.RateUnseeded.selector);
        oracle.grossBasketValue();
    }
}
