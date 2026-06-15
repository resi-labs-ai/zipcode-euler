// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";

/// @notice A minimal mock whose `decimals()` returns a configurable value (the LP oracle reads it on the USDC quote).
contract DecimalsMock {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @notice SEC-01 (L3): the reservoir LP-mark oracle's `_writePrice` must reject any mark whose `ts` is not strictly
///         newer than the cached one (replay / out-of-order). A stale-but-still-fresh higher mark would otherwise
///         over-credit reservoir collateral. Mirrors the guard at `SzAlphaRateOracle:86`. No pre-existing test file
///         existed for this oracle; authored from scratch for the SEC-01 regression.
contract SzipReservoirLpOracleTest is Test {
    SzipReservoirLpOracle internal lpo;

    address internal constant FORWARDER = address(0xF0F0);
    address internal constant LP = address(0x11D9); // the priced ICHI LP share key (any non-zero addr for the write path)
    address internal usdc; // mock quote, decimals == 6
    uint256 internal constant VALIDITY = 365 days;

    function setUp() public {
        usdc = address(new DecimalsMock(6));
        vm.warp(1_000_000); // non-zero base time so backdating is valid
        lpo = new SzipReservoirLpOracle(FORWARDER, usdc, VALIDITY, LP);
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
        vm.expectRevert(SzipReservoirLpOracle.StaleReport.selector);
        vm.prank(FORWARDER);
        lpo.onReport("", _markReport(2_000e6, t - 1)); // older ts, higher mark
    }

    // An equal-ts replay → StaleReport.
    function test_SEC01_lp_equalTs_reverts() public {
        uint32 t = uint32(block.timestamp);
        _push(1_000e6, t);
        vm.expectRevert(SzipReservoirLpOracle.StaleReport.selector);
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
}
