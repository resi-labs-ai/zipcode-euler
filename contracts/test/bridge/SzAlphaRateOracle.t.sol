// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzAlphaRateOracle} from "../../src/bridge/SzAlphaRateOracle.sol";
import {IXAlphaRate} from "../../src/interfaces/bridge/IXAlphaRate.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";

contract SzAlphaRateOracleTest is Test {
    SzAlphaRateOracle internal oracle;

    address internal forwarder = makeAddr("forwarder");

    uint256 internal constant MAX_STALENESS = 6 hours;
    uint32 internal constant WINDOW = 30 days;
    uint256 internal constant APR_CAP = 50_000; // 500% bps
    uint32 internal constant TWAP_WINDOW = 24 hours; // exchangeRate() smoothing window
    uint256 internal constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        oracle = new SzAlphaRateOracle(forwarder, MAX_STALENESS, WINDOW, APR_CAP, TWAP_WINDOW);
    }

    function _pushTo(SzAlphaRateOracle o, uint256 rate, uint48 ts) internal {
        bytes memory report = abi.encode(uint8(8), abi.encode(rate, ts));
        vm.prank(forwarder);
        o.onReport("", report);
    }

    function _push(uint256 rate, uint48 ts) internal {
        _pushTo(oracle, rate, ts);
    }

    // --------------------------------------------------------------------- ctor guards
    function test_ctor_reverts_zeroForwarder() public {
        vm.expectRevert(ReceiverTemplate.InvalidForwarderAddress.selector);
        new SzAlphaRateOracle(address(0), MAX_STALENESS, WINDOW, APR_CAP, TWAP_WINDOW);
    }

    function test_ctor_reverts_zeroMaxStaleness() public {
        vm.expectRevert(SzAlphaRateOracle.ZeroMaxStaleness.selector);
        new SzAlphaRateOracle(forwarder, 0, WINDOW, APR_CAP, TWAP_WINDOW);
    }

    function test_ctor_reverts_zeroWindow() public {
        vm.expectRevert(SzAlphaRateOracle.ZeroWindow.selector);
        new SzAlphaRateOracle(forwarder, MAX_STALENESS, 0, APR_CAP, TWAP_WINDOW);
    }

    function test_ctor_reverts_capZeroOrOverUint32() public {
        vm.expectRevert(SzAlphaRateOracle.InvalidAprCap.selector);
        new SzAlphaRateOracle(forwarder, MAX_STALENESS, WINDOW, 0, TWAP_WINDOW);
        vm.expectRevert(SzAlphaRateOracle.InvalidAprCap.selector);
        new SzAlphaRateOracle(forwarder, MAX_STALENESS, WINDOW, uint256(type(uint32).max) + 1, TWAP_WINDOW);
    }

    function test_deploy_state() public view {
        assertEq(oracle.getForwarderAddress(), forwarder);
        assertEq(oracle.RATE(), 8);
        assertEq(oracle.exchangeRate(), 0);
        assertFalse(oracle.fresh());
    }

    // --------------------------------------------------------------------- push path
    function test_push_lands_and_serves_rate() public {
        _push(1.05e18, uint48(T0));
        assertEq(oracle.exchangeRate(), 1.05e18);
        assertEq(oracle.lastUpdate(), uint48(T0));
        assertTrue(oracle.fresh());
    }

    function test_exchangeRate_is_IXAlphaRate_dropin() public {
        _push(1.05e18, uint48(T0));
        assertEq(IXAlphaRate(address(oracle)).exchangeRate(), 1.05e18);
    }

    /// @notice No deviation band: the chain's value is published as-is. A big legit jump (e.g. a real emission hike
    ///         doubling the rate in one push) LANDS — a band would have wrongly rejected it as "garbage".
    /// @dev The push still PUBLISHES any magnitude — no band, unchanged. What changed 2026-08-02 is that the
    ///      consumer-facing `exchangeRate()` smooths UPWARD moves over `twapWindow`, so a mis-scaled push needs the
    ///      whole window to land. The raw value is published instantly and is what Phase C alarm 3 watches.
    function test_large_legit_jump_is_published_raw_but_smoothed_to_consumers() public {
        _push(1e18, uint48(T0));
        vm.warp(T0 + 1);
        _push(2e18, uint48(T0 + 1)); // +100% in one push — real or not, publish it

        assertEq(oracle.rawExchangeRate(), 2e18, "the raw push lands in full, immediately");
        assertEq(oracle.exchangeRate(), 1e18, "consumers still see the old average: min(spot, twap) picks the twap");
    }

    /// @dev The upward move is delayed, not rejected. It arrives as successive pushes CLOSE their intervals, which
    ///      is what makes one hourly push worth 1/24 of a 24h window. Warping alone does not move it, deliberately.
    function test_upward_move_arrives_as_pushes_close_intervals() public {
        _push(1e18, uint48(T0));
        uint256 t = T0;
        for (uint256 i = 0; i < 24; i++) {
            t += 1 hours;
            vm.warp(t);
            _push(2e18, uint48(t));
        }
        // 24 pushes in, the seed hour at 1e18 is still the oldest slice inside the window: (1 + 2*23)/24.
        assertEq(oracle.exchangeRate(), uint256(47e18) / 24, "one honest hour still in the window");

        t += 1 hours;
        vm.warp(t);
        _push(2e18, uint48(t));
        assertEq(oracle.exchangeRate(), 2e18, "once it rolls out, the new rate has fully landed");
    }

    /// @dev A single push carries NO weight until the next one closes its interval — the trailing segment is
    ///      excluded on purpose, because booking it at the newest rate leaks a large jump straight through.
    function test_fresh_push_carries_no_weight_until_its_interval_closes() public {
        _push(1e18, uint48(T0));
        vm.warp(T0 + 1 hours);
        _push(1_000_000e18, uint48(T0 + 1 hours));

        assertEq(oracle.twapRate(), 1e18, "the inflated push has zero weight while its interval is still open");
        vm.warp(T0 + 6 hours);
        assertEq(oracle.twapRate(), 1e18, "and merely waiting does not give it weight");
    }

    /// @dev A SLASH must not be delayed. `min(spot, twap)` takes the lower number, so a downward move is immediate —
    ///      this is the whole reason the smoothing is one-directional rather than a symmetric band.
    function test_downward_move_lands_instantly() public {
        _push(1e18, uint48(T0));
        vm.warp(T0 + 1 hours);
        _push(0.5e18, uint48(T0 + 1 hours));

        assertEq(oracle.exchangeRate(), 0.5e18, "the slash reaches consumers on the first push");
        assertGt(oracle.twapRate(), 0.5e18, "...even though the trailing average is still high");
    }

    /// @dev NO SPOT FALLBACK before the window fills. `SzipNavOracle.twapNavPerShare` degrades to raw spot when it
    ///      lacks history, which is the fails-open shape. Here a partial window smooths over whatever exists.
    function test_partial_window_smooths_rather_than_falling_back_to_spot() public {
        _push(1e18, uint48(T0));
        vm.warp(T0 + 1 hours);
        _push(10e18, uint48(T0 + 1 hours)); // 3 hours into a 24h window: nowhere near full

        assertLt(oracle.exchangeRate(), 10e18, "the partial window still bites - it did NOT fall back to spot");
        assertEq(oracle.exchangeRate(), 1e18, "and it is the honest trailing value, not the inflated one");
    }

    /// @dev The seed push is the one genuinely unsmoothed moment: nothing precedes it to average against.
    function test_seed_push_is_unsmoothed_and_that_is_the_only_one() public {
        _push(1e18, uint48(T0));
        assertEq(oracle.exchangeRate(), 1e18, "the seed value serves itself");
        assertEq(oracle.genesisTs(), uint48(T0), "genesis recorded");
    }

    function test_push_non_forwarder_reverts() public {
        bytes memory report = abi.encode(uint8(8), abi.encode(uint256(1e18), uint48(T0)));
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, makeAddr("rando"), forwarder));
        oracle.onReport("", report);
    }

    function test_push_wrong_reportType_reverts() public {
        bytes memory report = abi.encode(uint8(3), abi.encode(uint256(1e18), uint48(T0)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(SzAlphaRateOracle.InvalidReportType.selector, uint8(3)));
        oracle.onReport("", report);
    }

    function test_push_zeroRate_reverts() public {
        bytes memory report = abi.encode(uint8(8), abi.encode(uint256(0), uint48(T0)));
        vm.prank(forwarder);
        vm.expectRevert(SzAlphaRateOracle.ZeroRate.selector);
        oracle.onReport("", report);
    }

    function test_push_futureTimestamp_reverts() public {
        bytes memory report = abi.encode(uint8(8), abi.encode(uint256(1e18), uint48(T0 + 1)));
        vm.prank(forwarder);
        vm.expectRevert(SzAlphaRateOracle.FutureTimestamp.selector);
        oracle.onReport("", report);
    }

    function test_push_stale_or_replayed_reverts() public {
        _push(1e18, uint48(T0));
        bytes memory report = abi.encode(uint8(8), abi.encode(uint256(1.1e18), uint48(T0)));
        vm.prank(forwarder);
        vm.expectRevert(SzAlphaRateOracle.StaleReport.selector);
        oracle.onReport("", report);
    }

    function test_fresh_flips_false_past_maxStaleness() public {
        _push(1e18, uint48(T0));
        assertTrue(oracle.fresh());
        vm.warp(T0 + MAX_STALENESS + 1);
        assertFalse(oracle.fresh());
        assertEq(oracle.exchangeRate(), 1e18); // still served; consumer gates on fresh()
    }

    // --------------------------------------------------------------------- derived APR
    function _warmAndRoll(SzAlphaRateOracle o) internal {
        _pushTo(o, 1e18, uint48(T0));
        vm.warp(T0 + WINDOW);
        _pushTo(o, 1e18, uint48(T0 + WINDOW)); // rolls prev=(1e18,T0)
    }

    function test_derives_apr_from_rate_growth() public {
        _warmAndRoll(oracle);
        vm.warp(T0 + WINDOW + 1);
        _push(1.01e18, uint48(T0 + WINDOW + 1)); // +1% over ~30d
        assertEq(oracle.intrinsicAprBps(), 1216);
    }

    function test_apr_slash_is_zero_not_negative() public {
        _warmAndRoll(oracle);
        vm.warp(T0 + WINDOW + 1);
        _push(0.9e18, uint48(T0 + WINDOW + 1)); // downward lands
        assertEq(oracle.intrinsicAprBps(), 0);
        assertEq(oracle.exchangeRate(), 0.9e18);
        assertTrue(oracle.fresh());
    }

    function test_apr_cap_clamps() public {
        _warmAndRoll(oracle);
        vm.warp(T0 + WINDOW + 1);
        _push(2e18, uint48(T0 + WINDOW + 1)); // +100% over ~window ⇒ annual >> cap
        assertEq(oracle.intrinsicAprBps(), uint32(APR_CAP));
    }

    function test_apr_zero_before_warm() public {
        _push(1e18, uint48(T0));
        assertEq(oracle.intrinsicAprBps(), 0);
    }

    /// @notice Real Bittensor data (live netuid-64 validator uid 252): stake 1,351,726 alpha, +21.066 alpha/tempo.
    ///         Over a SHORT (one-tempo, 72-min) window the per-tempo growth is sub-bps; the two-step integer math
    ///         truncated it to 0 (feed read 0% for a live validator); the single-expression annualization recovers
    ///         the true ~11.4% (1137 bps). Verified against the on-chain read in the 8x-02 report.
    function test_derives_real_validator_short_window() public {
        uint32 tempo = 4320;
        SzAlphaRateOracle o = new SzAlphaRateOracle(forwarder, 2 hours, tempo, 1_000_000, TWAP_WINDOW);
        uint256 rPrev = 1_351_726e9;
        uint256 rNow = rPrev + 21_066_000_000;

        _pushTo(o, rPrev, uint48(T0));
        vm.warp(T0 + tempo);
        _pushTo(o, rNow, uint48(T0 + tempo));

        uint32 apr = o.intrinsicAprBps();
        assertGt(apr, 0);
        assertApproxEqAbs(apr, 1137, 5);
    }

    // --------------------------------------------------------------------- GAP: fuzz + invariant (tier-mover)

    /// @notice Fuzz the anchor-roll + APR annualization across the rate/Δ domain: a push Δ ≥ WINDOW always rolls,
    ///         so the APR derives `rNow` vs the rolled `prevAnchor` over Δ. Must never revert, must clamp to the
    ///         cap, and must floor at 0 on a decline/flat (a slash is 0, not negative — `uint32`).
    function testFuzz_aprBoundedAndNonNegative(uint256 rPrev, uint256 rNow, uint32 dtSeed) public {
        // fuzz the FULL uint256 rate domain (the push path has no upper bound) so this
        // actually reaches the former overflow ceiling (~2^218) instead of staying ~138 bits below it.
        rPrev = bound(rPrev, 1, type(uint256).max);
        rNow = bound(rNow, 1, type(uint256).max);
        uint256 dt = bound(uint256(dtSeed), WINDOW, 365 days); // ≥ WINDOW so push 2 rolls the anchor
        _push(rPrev, uint48(T0));
        vm.warp(T0 + dt);
        _push(rNow, uint48(T0 + dt)); // rolls: prev=(rPrev,T0); latest=(rNow,T0+dt)
        uint32 apr = oracle.intrinsicAprBps(); // must not revert / overflow
        assertLe(uint256(apr), APR_CAP, "apr exceeds cap");
        if (rNow <= rPrev) assertEq(apr, 0, "decline/flat must annualize to 0");
    }

    /// @notice an absurd pushed rate (the push path has NO upper bound — "no deviation band")
    ///         must SATURATE the advisory APR to `aprCap`, NOT revert. Pre-fix the multiply-up at the
    ///         former `:140` overflowed (uint256 panic) for `rNow - rPrev > ~2^218`; the saturation guards
    ///         make the view total. This is the regression the (now-widened) fuzz/invariant also covers.
    function test_apr_extremeRate_saturatesToCapNoRevert() public {
        _push(1, uint48(T0)); // tiny anchor
        vm.warp(T0 + WINDOW + 1);
        _push(type(uint256).max, uint48(T0 + WINDOW + 1)); // rolls; latest.rate = max, anchor.rate = 1
        assertEq(oracle.intrinsicAprBps(), uint32(APR_CAP), "extreme growth must clamp to cap, not revert");
    }
}

/// @dev Bounded action driver for the rate-oracle invariant suite. Pushes arbitrary (rate, ts) through the
///      Forwarder (many get rejected: zero / future / not-strictly-newer) and advances time. On every ACCEPTED
///      push it asserts the ts strictly increased — the I-1 monotonicity as a stateful property.
contract RateOracleHandler is Test {
    SzAlphaRateOracle public oracle;
    address internal forwarder;
    uint48 public ghostLastTs; // ts of the last accepted push (0 = none)
    uint256 public accepted;

    constructor(SzAlphaRateOracle o, address fwd) {
        oracle = o;
        forwarder = fwd;
    }

    function push(uint256 rate, uint256 tsSeed) external {
        uint48 ts = uint48(bound(tsSeed, 1, block.timestamp));
        rate = bound(rate, 0, type(uint256).max); // full domain (0 still exercises ZeroRate; huge rates exercise the APR saturation)
        bytes memory report = abi.encode(uint8(8), abi.encode(rate, ts));
        vm.prank(forwarder);
        try oracle.onReport("", report) {
            // accepted ⇒ the contract required ts > prior latest.ts (== prior ghostLastTs) and rate != 0
            assertGt(ts, ghostLastTs, "accepted a non-increasing ts (I-1 broken)");
            ghostLastTs = ts;
            accepted++;
        } catch {}
    }

    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1, 10 days));
    }
}

/// @notice Invariant suite for SzAlphaRateOracle (the tier-mover): (a) `latest.ts` always equals the
///         strictly-increasing last-accepted ts (I-1 monotonicity); (b) `intrinsicAprBps()` never reverts and
///         stays ≤ cap in ANY reachable state — including every anchor-roll state the handler drives.
contract SzAlphaRateOracleInvariantTest is Test {
    SzAlphaRateOracle internal oracle;
    RateOracleHandler internal handler;
    address internal forwarder = makeAddr("invFwd");

    uint256 internal constant MAX_STALENESS = 6 hours;
    uint32 internal constant WINDOW = 30 days;
    uint256 internal constant APR_CAP = 50_000;
    uint32 internal constant TWAP_WINDOW = 24 hours;

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new SzAlphaRateOracle(forwarder, MAX_STALENESS, WINDOW, APR_CAP, TWAP_WINDOW);
        handler = new RateOracleHandler(oracle, forwarder);
        targetContract(address(handler));
    }

    function invariant_latestTsTracksMonotonicAccepted() public view {
        assertEq(uint256(oracle.lastUpdate()), uint256(handler.ghostLastTs()), "latest.ts != last accepted ts");
    }

    function invariant_aprBoundedNeverReverts() public view {
        uint256 apr = oracle.intrinsicAprBps(); // reverts here would fail the invariant
        assertLe(apr, APR_CAP, "apr exceeds cap");
    }
}
