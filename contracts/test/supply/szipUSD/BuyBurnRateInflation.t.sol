// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SzipNavOracle} from "../../../src/supply/SzipNavOracle.sol";
import {SzAlphaRateOracle} from "../../../src/bridge/SzAlphaRateOracle.sol";
import {SzipBuyBurnModule} from "../../../src/supply/szipUSD/SzipBuyBurnModule.sol";

// REAL fixtures reused from the two existing suites. NOTE: `MockNavOracle` is deliberately NOT used —
// this harness wires the REAL `SzipNavOracle` + the REAL `SzAlphaRateOracle` behind the buy-burn module.
import {MockToken, MockXAlpha} from "../SzipNavOracle.t.sol";
import {RecordingSafe, MockSettlement, MockCoverageGate} from "./SzipBuyBurnModule.t.sol";

/// @title BuyBurnRateInflation — adversarial verification of `docs/AGGREGATE-CRE-COMPROMISE.md` §3 (A1)
/// @notice THE CLAIM UNDER TEST: an attacker holding the CRE keys can push an **unbanded** xALPHA
///         `exchangeRate` into `SzAlphaRateOracle`, which multiplies straight through
///         `SzipNavOracle._xAlphaUSD()` into `spotNavPerShare()`, inflating `navExit = min(spot, twap)`,
///         and thereby making `SzipBuyBurnModule.postBid` authorize dramatically more USDC out of the
///         engine Safe for the SAME quantity of szipUSD shares.
///
///         Everything here is a LEGAL push: `SzAlphaRateOracle._processReport` enforces only
///         non-zero / not-future / strictly-newer (it is band-free BY DESIGN, `SzAlphaRateOracle.sol:92-94`),
///         and the `alphaUSD` NAV leg is pushed once inside its deviation band and then never touched again.
///         The rate push alone carries the whole attack.
///
///         Fixture params are the PRODUCTION defaults from `script/DeployMainnet.s.sol:91-106`:
///         `W = 3600`, `NAV_MAX_AGE = 86_400`, `BUYBURN_DBPS = 100`,
///         `RATE_MAX_STALENESS = 6h`, `RATE_WINDOW = 30d`.
contract BuyBurnRateInflationTest is Test {
    // ------------------------------------------------------------------ production params
    uint32 internal constant W = 3600; // NAV_W
    uint256 internal constant MAX_AGE = 86_400; // NAV_MAX_AGE
    uint16 internal constant D_BPS = 100; // BUYBURN_DBPS (1% haircut)
    uint256 internal constant RATE_MAX_STALENESS = 6 hours;
    uint32 internal constant RATE_WINDOW = 30 days;
    uint256 internal constant RATE_APR_CAP = 50_000;
    uint32 internal constant RATE_TWAP_WINDOW = 24 hours; // the ratified exchangeRate() smoothing window
    /// @dev The deployed default (`BUYBACK_CAP = 1_000_000e18`) is in USDC 6-dp units ⇒ 1e18 whole USDC.
    ///      It is effectively unbounded; kept verbatim so the harness does not soften a real bound.
    uint256 internal constant BUYBACK_CAP = 1_000_000e18;

    /// @dev The rate multiplier the compromised CRE pushes: 1e18 -> 1e24.
    uint256 internal constant K = 1_000_000;

    // ------------------------------------------------------------------ actors
    address internal navForwarder = makeAddr("navForwarder");
    address internal rateForwarder = makeAddr("rateForwarder");
    address internal juniorTrancheSafe = makeAddr("juniorTrancheSafe");
    address internal juniorTrancheSidecar = makeAddr("juniorTrancheSidecar");
    address internal timelock = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal keeper = makeAddr("honestKeeper");

    // ------------------------------------------------------------------ substrate
    MockToken internal zip;
    MockToken internal usdcTok;
    MockXAlpha internal xa;
    MockToken internal hydx;
    MockToken internal ohydx;
    MockToken internal szip;

    SzipNavOracle internal nav;
    SzAlphaRateOracle internal rate;
    SzipBuyBurnModule internal module;
    RecordingSafe internal engine; // the engine Safe (avatar == target == receiver)
    MockSettlement internal settlement;
    MockCoverageGate internal coverage;

    // basket sizing: $1,000,000 USDC + 1,000,000 xALPHA @ $1 ⇒ xALPHA is 50% of gross
    uint256 internal constant BASKET_USDC6 = 1_000_000e6;
    uint256 internal constant BASKET_XALPHA = 1_000_000e18;
    uint256 internal constant SHARE_SUPPLY = 2_000_000e18; // ⇒ navPerShare == $1.00 exactly
    uint256 internal constant ENGINE_USDC6 = 1_000_000e6; // the drainable engine-Safe float

    function setUp() public {
        vm.warp(1_000_000);

        zip = new MockToken(18);
        usdcTok = new MockToken(6);
        xa = new MockXAlpha();
        hydx = new MockToken(18);
        ohydx = new MockToken(18);
        szip = new MockToken(18);

        // The engine Safe IS the counted basket Safe — one address, two role names (docs/safe-identities.md), now
        // enforced by `setJuniorTrancheEngine`. So it is constructed FIRST and passed as `juniorTrancheSafe`, and
        // the drainable float is the basket's own USDC leg rather than a second uncounted pile.
        engine = new RecordingSafe();

        nav = new SzipNavOracle(
            navForwarder,
            address(zip),
            address(usdcTok),
            address(xa),
            address(hydx),
            address(ohydx),
            address(engine),
            juniorTrancheSidecar,
            W,
            MAX_AGE
        );
        rate = new SzAlphaRateOracle(rateForwarder, RATE_MAX_STALENESS, RATE_WINDOW, RATE_APR_CAP, RATE_TWAP_WINDOW);

        settlement = new MockSettlement(keccak256("domain"), makeAddr("vaultRelayer"));
        coverage = new MockCoverageGate();
        coverage.set(true); // covered — the outflow gate is OPEN (it is not a defense against this)

        nav.setShareToken(address(szip));
        nav.setJuniorTrancheEngine(address(engine));
        nav.setXAlphaRateOracle(address(rate)); // the CRE-pushed cross-chain rate is the live source

        // fund the junior basket: xALPHA is a MATERIAL fraction (asserted in every test via _assertMaterial)
        usdcTok.setBalance(address(engine), BASKET_USDC6); // == ENGINE_USDC6: the counted leg IS the drainable float
        xa.setBalance(address(engine), BASKET_XALPHA);
        szip.setTotalSupply(SHARE_SUPPLY);

        // seed the two pushed NAV legs (in-band, single push) + the xALPHA rate at 1.0
        _pushLegs(1e18, 1e18);
        _pushRate(1e18);

        // the REAL buy-burn module, wired to the REAL NAV oracle
        module = SzipBuyBurnModule(Clones.clone(address(new SzipBuyBurnModule())));
        module.setUp(
            abi.encode(
                timelock,
                address(engine),
                operator,
                address(nav),
                address(szip),
                address(usdcTok),
                address(settlement),
                D_BPS,
                BUYBACK_CAP,
                address(coverage)
            )
        );

        // build >= W of honest TWAP history (a keeper poking every 72s ≈ obsSpacing)
        for (uint256 i = 0; i < 130; i++) {
            vm.warp(block.timestamp + 72);
            vm.prank(keeper);
            nav.poke();
        }
    }

    // ================================================================= helpers
    function _pushLegs(uint256 alphaUSD, uint256 hydxUSD) internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = nav.LEG_ALPHA_USD();
        legs[1] = nav.LEG_HYDX_USD();
        ps[0] = alphaUSD;
        ps[1] = hydxUSD;
        vm.prank(navForwarder);
        nav.onReport("", abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp))));
    }

    /// @dev The FULL legal rate-push path: reportType 8, non-zero, not-future, strictly-newer. No band exists.
    function _pushRate(uint256 r) internal {
        vm.prank(rateForwarder);
        rate.onReport("", abi.encode(uint8(8), abi.encode(r, uint48(block.timestamp))));
    }

    function _order(uint256 sell, uint256 buy, uint32 validTo)
        internal
        pure
        returns (SzipBuyBurnModule.GPv2OrderInput memory o)
    {
        o.sellAmount = sell;
        o.buyAmount = buy;
        o.validTo = validTo;
    }

    /// @dev PRECONDITION: xALPHA must be a material fraction of the basket, else inflating the rate
    ///      moves NAV negligibly and the whole measurement is meaningless.
    function _assertMaterialXAlpha() internal view returns (uint256 pct) {
        uint256 gross = nav.grossBasketValue();
        uint256 xValue = BASKET_XALPHA * (rate.exchangeRate() * 1e18 / 1e18) / 1e18; // alphaUSD == 1e18
        pct = xValue * 100 / gross;
        assertGe(pct, 40, "PRECONDITION: xALPHA must be >= 40% of grossBasketValue");
    }

    /// @dev The exact boundary of the `postBid` price gate for a FIXED `buyAmount`:
    ///      `sellAmount * 1e12 * 10_000 * 1e18 <= buyAmount * navExit18 * (10_000 - dBps)`.
    ///      Proves the boundary by EXECUTION: `max + 1` must revert `BidAboveDiscount`, `max` must be accepted,
    ///      and the accepted bid must have driven a real USDC `approve(vaultRelayer, max)` through the Safe.
    function _maxAcceptedSell(uint256 buyAmount) internal returns (uint256 maxSell) {
        uint256 navExit18 = nav.navExit();
        maxSell = buyAmount * navExit18 * (10_000 - uint256(D_BPS)) / (1e12 * 10_000 * 1e18);
        uint32 vt = uint32(block.timestamp + 1 hours);

        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        module.postBid(_order(maxSell + 1, buyAmount, vt));

        uint256 idx = engine.callCount();
        vm.prank(operator);
        module.postBid(_order(maxSell, buyAmount, vt));

        assertEq(module.currentSellAmount(), maxSell, "recorded sellAmount");
        // the USDC approve the module actually drove through the engine Safe == the authorized drain
        (address to,, bytes memory data,) = engine.getCall(idx);
        assertEq(to, address(usdcTok), "first exec is the USDC approve");
        (address spender, uint256 amount) = _decodeApprove(data);
        assertEq(spender, module.vaultRelayer(), "approve spender is the CoW VaultRelayer");
        assertEq(amount, maxSell, "the VaultRelayer allowance IS the authorized USDC outflow");

        vm.prank(operator);
        module.cancelBid();
    }

    function _decodeApprove(bytes memory d) internal pure returns (address spender, uint256 amount) {
        assembly {
            spender := mload(add(d, 36))
            amount := mload(add(d, 68))
        }
    }

    /// @dev The closed form of `spotNavPerShare()` for this fixture at a given xALPHA `exchangeRate`
    ///      (`alphaUSD` leg is pinned at $1, no LP / debt / receivables / provision).
    function _expectedSpotAtRate(uint256 r) internal pure returns (uint256) {
        uint256 xAlphaUSD = r; // rate * alphaUSD(1e18) / 1e18
        uint256 gross = BASKET_XALPHA * xAlphaUSD / 1e18 + BASKET_USDC6 * 1e12;
        return gross * 1e18 / SHARE_SUPPLY;
    }

    /// @dev The szipUSD the attacker must sell into the bid to extract `usdc6` USDC at the current mark —
    ///      the inverse of the `postBid` price gate.
    function _sharesToExtract(uint256 usdc6, uint256 navExit18) internal pure returns (uint256) {
        uint256 num = usdc6 * 1e12 * 10_000 * 1e18;
        uint256 den = navExit18 * (10_000 - uint256(D_BPS));
        return num / den + 1; // round up so the gate is satisfied
    }

    // ================================================================= the rate TWAP, proven by what it stops
    /// @notice THE REGRESSION GUARD. Before the one-directional TWAP landed (2026-08-02), a single legal x1,000,000
    ///         rate push took `navExit` from $1.00 to $1,662.13 and made the buy-burn gate authorize $1,645 of Safe
    ///         USDC for one share — a $1M Safe for 607 shares. The push still LANDS in full; it just no longer
    ///         reaches the consumer, because `SzAlphaRateOracle.exchangeRate()` serves `min(spot, twap)`.
    function test_A1_rate_inflation_no_longer_reaches_the_payout_gate() public {
        uint256 pct = _assertMaterialXAlpha();
        console2.log("xALPHA share of grossBasketValue (%):", pct);

        uint256 buyAmount = 1e18; // ONE szipUSD share — fixed across both measurements
        uint256 navBefore = nav.navExit();
        uint256 sellBefore = _maxAcceptedSell(buyAmount);
        assertEq(navBefore, 1e18, "baseline NAV/share is exactly $1.00");

        vm.warp(block.timestamp + 12);
        _pushRate(1e18 * K); // 1e18 -> 1e24, still legal, still accepted

        // The push is NOT rejected — there is no band, and there must not be one.
        assertEq(rate.rawExchangeRate(), 1e24, "the raw push landed in full");
        assertTrue(rate.fresh(), "and it is fresh");
        // ...but the consumer reads the smoothed value, so NAV never sees it.
        assertEq(rate.exchangeRate(), 1e18, "min(spot, twap) holds the consumer at the trailing average");

        uint256 navAfter = nav.navExit();
        uint256 sellAfter = _maxAcceptedSell(buyAmount);
        console2.log("navExit AFTER (18dp):       ", navAfter);
        console2.log("max sellAmount AFTER (6dp): ", sellAfter);

        // was: navExit 1.00 -> 1662.13, sellAmount 0.99 -> 1645.51, both 1662x.
        assertEq(navAfter, navBefore, "navExit is bit-identical across the inflation attempt");
        assertEq(sellAfter, sellBefore, "and the USDC the module will authorize is unchanged");

        // was: draining the whole Safe fell from 1,010,101 shares to 607.7.
        uint256 sharesToDrain = _sharesToExtract(ENGINE_USDC6, navAfter);
        assertGt(sharesToDrain, 1_000_000e18, "draining the Safe still costs its full honest value in szipUSD");
    }

    /// @notice The upward move is DELAYED, not rejected. Hold the inflated rate for a full smoothing window and it
    ///         arrives — which is correct, and is why the window is sized against operator reaction time rather than
    ///         treated as a bound. Phase C alarm 3 watches `rawExchangeRate()` and fires on the first push.
    function test_A1_sustained_inflation_still_arrives_after_the_window() public {
        _assertMaterialXAlpha();

        // Waiting alone does nothing: the average only moves as pushes CLOSE their intervals. It takes a full
        // window of the producer repeatedly publishing the bad value, which is the whole point of the delay.
        vm.warp(block.timestamp + 12);
        _pushRate(1e18 * K);
        vm.warp(block.timestamp + RATE_TWAP_WINDOW);
        assertEq(rate.exchangeRate(), 1e18, "one bad push plus a day of silence still reaches nobody");

        for (uint256 i = 0; i < 25; i++) {
            vm.warp(block.timestamp + 1 hours);
            _pushRate(1e18 * K + i + 1); // strictly-newer value each time; magnitude unchanged
        }
        assertGt(rate.exchangeRate(), 1e23, "a full window of sustained bad pushes and it has landed");
        assertGt(nav.spotNavPerShare(), 1000e18, "so NAV does move eventually - the window buys time, not immunity");
    }

    /// @notice `postBid` calls `poke()` before reading `navExit`. It was never a defense against rate inflation and
    ///         still is not; the difference is that there is no longer an inflated mark for it to book.
    function test_A1_poke_does_not_defend() public {
        _assertMaterialXAlpha();
        vm.warp(block.timestamp + 12);
        _pushRate(1e18 * K);

        uint256 navNoPoke = nav.navExit();
        vm.prank(keeper);
        nav.poke();

        assertEq(nav.navExit(), navNoPoke, "poke() changed NOTHING - it is not a defense");
        // was: assertGt(navAfterPoke, 1000e18, "and the mark it books is the inflated one")
        assertEq(nav.navExit(), 1e18, "and the mark it books is the HONEST one");
    }

    /// @notice A2 from the rate side. Silence for `W` still collapses the NAV bracket — `twapNavPerShare` degrades to
    ///         spot and `navEntry == navExit` — and that remains open as a liveness item. What the rate TWAP removes
    ///         is the thing that made the collapse profitable: there is no inflated spot to be exposed by it.
    function test_A2_silence_collapses_bracket_but_there_is_no_inflation_to_expose() public {
        _assertMaterialXAlpha();
        vm.warp(block.timestamp + W + 1); // one dormant hour; nobody pokes
        _pushRate(1e18 * K);

        assertTrue(nav.fresh(), "legs are still fresh - nothing fails closed");
        uint256 spot = nav.spotNavPerShare();
        uint256 navExit18 = nav.navExit();

        assertEq(navExit18, spot, "the bracket DID collapse: navExit == navEntry == spot (still open, as liveness)");
        // was: assertEq(spot, _expectedSpotAtRate(1e24)) - the full 500,000x reached the gate.
        assertEq(spot, 1e18, "but spot is honest, because the rate leg never inflated");
        assertEq(_maxAcceptedSell(1e18), 990_000, "so one share still authorizes only the honest $0.99");
    }

    /// @notice The `g == 0` bracket property used to be the ONLY thing that defended, and only in the same block.
    ///         With the rate smoothed at the source that special case stops mattering: any gap is now safe.
    function test_rate_leg_is_safe_at_any_accumulator_gap() public {
        _assertMaterialXAlpha();
        vm.warp(block.timestamp + 12);
        vm.prank(keeper);
        nav.poke();
        _pushRate(1e18 * K); // inflate in the same block, after the poke

        assertEq(nav.spotNavPerShare(), 1e18, "spot is NOT inflated - the consumer never saw the push");
        assertEq(nav.navExit(), 1e18, "navExit honest at g == 0");
        assertEq(_maxAcceptedSell(1e18), 990_000, "the module authorizes the honest $0.99");

        // was: one second of gap re-opened the leak.
        vm.warp(block.timestamp + 1);
        assertEq(nav.navExit(), 1e18, "and one second of gap no longer re-opens anything");
    }
}
