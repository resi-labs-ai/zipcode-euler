// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipFarmUtilityLpOracle} from "../../src/supply/SzipFarmUtilityLpOracle.sol";
import {Errors} from "euler-price-oracle/adapter/BaseAdapter.sol";

/// @notice A minimal mock whose `decimals()` returns a configurable value (the LP oracle reads it on the USDC quote).
contract DecimalsMock {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @notice SEC-01 (L3): the farm utility LP-mark oracle's `_writePrice` must reject any mark whose `ts` is not strictly
///         newer than the cached one (replay / out-of-order). A stale-but-still-fresh higher mark would otherwise
///         over-credit farm utility collateral. Mirrors the guard at `SzAlphaRateOracle:86`. No pre-existing test file
///         existed for this oracle; authored from scratch for the SEC-01 regression.
contract SzipFarmUtilityLpOracleTest is Test {
    SzipFarmUtilityLpOracle internal lpo;

    address internal constant FORWARDER = address(0xF0F0);
    address internal constant LP = address(0x11D9); // the priced ICHI LP share key (any non-zero addr for the write path)
    address internal usdc; // mock quote, decimals == 6
    uint256 internal constant VALIDITY = 365 days;

    function setUp() public {
        usdc = address(new DecimalsMock(6));
        vm.warp(1_000_000); // non-zero base time so backdating is valid
        lpo = new SzipFarmUtilityLpOracle(FORWARDER, usdc, VALIDITY, LP);
    }

    function _markReport(uint256 mark, uint32 ts) internal pure returns (bytes memory) {
        return abi.encode(uint8(7), abi.encode(mark, ts)); // LP_MARK == 7
    }

    function _push(uint256 mark, uint32 ts) internal {
        vm.prank(FORWARDER);
        lpo.onReport("", _markReport(mark, ts));
    }

    // First write (timestamp == 0) always passes.
    function test_SEC01_lp_firstWrite_succeeds() public {
        _push(1_000e6, uint32(block.timestamp));
        (uint208 price, uint48 ts) = lpo.cache();
        assertEq(price, 1_000e6);
        assertEq(ts, uint48(block.timestamp));
    }

    // A backdated mark over a fresher one → StaleReport (no over-crediting via a stale higher mark).
    function test_SEC01_lp_backdated_mark_reverts() public {
        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        vm.expectRevert(SzipFarmUtilityLpOracle.StaleReport.selector);
        vm.prank(FORWARDER);
        lpo.onReport("", _markReport(2_000e6, t - 1)); // older ts, higher mark
    }

    // An equal-ts replay → StaleReport.
    function test_SEC01_lp_equalTs_reverts() public {
        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        vm.expectRevert(SzipFarmUtilityLpOracle.StaleReport.selector);
        vm.prank(FORWARDER);
        lpo.onReport("", _markReport(1_000e6, t));
    }

    // A strictly-newer mark still succeeds.
    function test_SEC01_lp_strictlyNewer_succeeds() public {
        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        vm.warp(block.timestamp + 1);
        _push(1_100e6, t + 1);
        (uint208 price, uint48 ts) = lpo.cache();
        assertEq(price, 1_100e6);
        assertEq(ts, uint48(t + 1));
    }

    // --- shared helpers for the gap-closing tests ---
    function _typedReport(uint8 rtype, uint256 mark, uint32 ts) internal pure returns (bytes memory) {
        return abi.encode(rtype, abi.encode(mark, ts));
    }

    // ----------------------------------------------------------------- I-2: forwarder-only writes
    /// @notice Only the configured Chainlink Forwarder may call `onReport`; any other caller reverts `InvalidSender`.
    function test_onReport_nonForwarder_reverts() public {
        address attacker = address(0xBAD);
        vm.expectRevert(abi.encodeWithSignature("InvalidSender(address,address)", attacker, FORWARDER));
        vm.prank(attacker);
        lpo.onReport("", _markReport(1_000e6, uint32(block.timestamp)));
    }

    // ----------------------------------------------------------------- I-3: reportType pinned to LP_MARK (7)
    /// @notice A report whose `reportType` is not `LP_MARK` reverts `InvalidReportType` (the registry's `REVALUATION=3`
    ///         must not be accepted on this single-key engine oracle).
    function test_processReport_wrongType_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SzipFarmUtilityLpOracle.InvalidReportType.selector, uint8(3)));
        vm.prank(FORWARDER);
        lpo.onReport("", _typedReport(3, 1_000e6, uint32(block.timestamp)));
    }

    // ----------------------------------------------------------------- I-4: write value guards (fail-closed)
    /// @notice A zero mark is meaningless collateral pricing → `PriceOracle_InvalidAnswer`.
    function test_writePrice_zeroMark_reverts() public {
        vm.expectRevert(Errors.PriceOracle_InvalidAnswer.selector);
        _push(0, uint32(block.timestamp));
    }

    /// @notice A mark above `uint208.max` cannot fit the cache slot → `PriceOracle_Overflow`.
    function test_writePrice_overflowMark_reverts() public {
        vm.expectRevert(Errors.PriceOracle_Overflow.selector);
        _push(uint256(type(uint208).max) + 1, uint32(block.timestamp));
    }

    /// @notice A future-dated mark (timestamp sanity, not a value band) → `FutureTimestamp`.
    function test_writePrice_futureTs_reverts() public {
        vm.expectRevert(SzipFarmUtilityLpOracle.FutureTimestamp.selector);
        _push(1_000e6, uint32(block.timestamp + 1));
    }

    // ----------------------------------------------------------------- I-5: read fail-closed (the defining contract)
    /// @notice Only the configured `(lpToken, quote)` pair is priced; any other base/quote reverts `NotSupported`.
    function test_getQuote_unsupportedPair_reverts() public {
        _push(1_000e6, uint32(block.timestamp)); // a valid cache, so the revert is the pair check, not staleness
        // wrong base (base != lpToken)
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, usdc, usdc));
        lpo.getQuote(1e18, usdc, usdc);
        // wrong quote (quote != stored quote)
        address wrongQuote = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, LP, wrongQuote));
        lpo.getQuote(1e18, LP, wrongQuote);
    }

    /// @notice An unset cache (`timestamp == 0`, no mark ever pushed) fails the borrow CLOSED via `NotSupported`.
    function test_getQuote_unsetCache_reverts() public {
        // `lpo` has had no push in this test ⇒ cache.timestamp == 0.
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, LP, usdc));
        lpo.getQuote(1e18, LP, usdc);
    }

    /// @notice A mark older than `validityWindow` fails the borrow CLOSED via `TooStale` — the liveness contract this
    ///         push-oracle exists to provide (vs the trustless `AlgebraIchiFairLpOracle`).
    function test_getQuote_stale_reverts() public {
        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        // exactly at the window boundary still reads (s == window is NOT > window)
        vm.warp(uint256(t) + VALIDITY);
        assertEq(lpo.getQuote(1e18, LP, usdc), 1_000e6, "fresh at the boundary");
        // one second past the window → TooStale(s, window)
        vm.warp(uint256(t) + VALIDITY + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY));
        lpo.getQuote(1e18, LP, usdc);
    }

    // ----------------------------------------------------------------- I-6: quote value + rounds DOWN
    /// @notice `getQuote(1e18, lpToken, USDC) == mark` (1 LP share is worth exactly its per-share mark); the conversion
    ///         reduces to `floor(inAmount·mark / 1e18)` and truncates against the borrower.
    function test_getQuote_value_and_roundsDown() public {
        _push(1_234e6, uint32(block.timestamp));
        assertEq(lpo.getQuote(1e18, LP, usdc), 1_234e6, "1 LP share == its mark");
        assertEq(lpo.getQuote(2e18, LP, usdc), 2 * 1_234e6, "linear in share count");

        // a guaranteed-remainder case: floor((1e18+1)*7 / 1e18) == 7, dropping the 7/1e18 fractional part.
        SzipFarmUtilityLpOracle fresh = new SzipFarmUtilityLpOracle(FORWARDER, usdc, VALIDITY, LP);
        vm.prank(FORWARDER);
        fresh.onReport("", _markReport(7, uint32(block.timestamp)));
        uint256 inAmt = 1e18 + 1;
        uint256 q = fresh.getQuote(inAmt, LP, usdc);
        assertEq(q, (inAmt * 7) / 1e18, "matches the floored conversion");
        assertEq(q, 7, "rounds DOWN to 7");
        assertGt((inAmt * 7) % 1e18, 0, "a real down-rounding (non-zero remainder truncated)");
    }

    // ----------------------------------------------------------------- I-7: Timelock setters (onlyOwner + zero + effect)
    /// @notice `setQuote` is `onlyOwner`, zero-guarded, re-derives `scale`, and re-points the priced quote: the new
    ///         pair prices and the old one reverts. (Owner is this test contract — it deployed `lpo`.)
    function test_setQuote_guards_and_effect() public {
        address newQuote = address(new DecimalsMock(18)); // different decimals ⇒ scale re-derived
        // onlyOwner
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        vm.prank(address(0xBAD));
        lpo.setQuote(newQuote);
        // zero-guard
        vm.expectRevert(SzipFarmUtilityLpOracle.ZeroAddress.selector);
        lpo.setQuote(address(0));
        // effect
        lpo.setQuote(newQuote);
        assertEq(lpo.quote(), newQuote, "quote re-pointed");
        _push(1_000e6, uint32(block.timestamp));
        assertEq(lpo.getQuote(1e18, LP, newQuote), 1_000e6, "prices via the new quote (scale re-derived, valid)");
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, LP, usdc));
        lpo.getQuote(1e18, LP, usdc); // old quote no longer supported
    }

    /// @notice `setLpToken` is `onlyOwner`, zero-guarded, and re-points the priced base key.
    function test_setLpToken_guards_and_effect() public {
        address newLp = address(0xABCD);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        vm.prank(address(0xBAD));
        lpo.setLpToken(newLp);
        vm.expectRevert(SzipFarmUtilityLpOracle.ZeroAddress.selector);
        lpo.setLpToken(address(0));
        lpo.setLpToken(newLp);
        assertEq(lpo.lpToken(), newLp, "lpToken re-pointed");
        _push(500e6, uint32(block.timestamp));
        assertEq(lpo.getQuote(1e18, newLp, usdc), 500e6, "prices the new LP key");
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, LP, usdc));
        lpo.getQuote(1e18, LP, usdc); // old key no longer supported
    }

    /// @notice `setValidityWindow` is `onlyOwner` and tightening it can make a previously-fresh mark read as stale.
    function test_setValidityWindow_guards_and_effect() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        vm.prank(address(0xBAD));
        lpo.setValidityWindow(10);

        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        lpo.setValidityWindow(10); // tighten window to 10s
        assertEq(lpo.validityWindow(), 10, "window updated");
        vm.warp(uint256(t) + 11); // 11s > 10s window
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, uint256(11), uint256(10)));
        lpo.getQuote(1e18, LP, usdc);
    }

    // ----------------------------------------------------------------- I-8: constructor zero-guards
    function test_ctor_zeroQuote_reverts() public {
        vm.expectRevert(SzipFarmUtilityLpOracle.ZeroAddress.selector);
        new SzipFarmUtilityLpOracle(FORWARDER, address(0), VALIDITY, LP);
    }

    function test_ctor_zeroLpToken_reverts() public {
        vm.expectRevert(SzipFarmUtilityLpOracle.ZeroAddress.selector);
        new SzipFarmUtilityLpOracle(FORWARDER, usdc, VALIDITY, address(0));
    }

    function test_ctor_zeroForwarder_reverts() public {
        // the parent `ReceiverTemplate` ctor runs first and rejects a zero forwarder.
        vm.expectRevert(abi.encodeWithSignature("InvalidForwarderAddress()"));
        new SzipFarmUtilityLpOracle(address(0), usdc, VALIDITY, LP);
    }
}
