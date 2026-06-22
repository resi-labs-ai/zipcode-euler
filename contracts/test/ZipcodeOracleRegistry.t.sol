// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {LienCollateralToken} from "../src/LienCollateralToken.sol";
import {Errors} from "euler-price-oracle/lib/Errors.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

/// @notice A minimal ERC20-ish mock whose `decimals()` returns a configurable value (used for the USDC=6 quote and for
///         a hostile 6-dp lien key). It only implements `decimals()`; that is all the registry reads.
contract DecimalsMock {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

contract ZipcodeOracleRegistryTest is Test {
    ZipcodeOracleRegistry internal reg;

    address internal constant FORWARDER = address(0xF0F0);
    address internal constant CTRL = address(0xC0C0);
    address internal usdc; // mock quote, decimals == 6
    uint256 internal constant VALIDITY = 365 days;

    LienCollateralToken internal LIEN;
    LienCollateralToken internal LIEN_A;
    LienCollateralToken internal LIEN_B;

    // Mirror of the registry's events for vm.expectEmit.
    event ControllerSet(address indexed controller);
    event RegistryPriceSeed(address indexed lien, uint256 price);
    event RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp);
    event WiringSet(bytes32 indexed slot, address value);
    event ValidityWindowSet(uint256 window);

    function setUp() public {
        usdc = address(new DecimalsMock(6));
        // Deploy at a non-trivial timestamp so warps/sub-now math are exercised.
        vm.warp(1_000_000);
        reg = new ZipcodeOracleRegistry(FORWARDER, usdc, VALIDITY);
        // Real lien tokens (pinned decimals()==18). Controller arg is just the mint recipient; irrelevant here.
        LIEN = new LienCollateralToken(address(this));
        LIEN_A = new LienCollateralToken(address(this));
        LIEN_B = new LienCollateralToken(address(this));
    }

    // --- helpers ---------------------------------------------------------

    function _wireController() internal {
        reg.setController(CTRL);
    }

    function _seed(address lien, uint256 price) internal {
        vm.prank(CTRL);
        reg.seedPrice(lien, price);
    }

    function _revalReport(address[] memory liens, uint256[] memory prices, uint32 ts)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(3), abi.encode(liens, prices, ts));
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _one(uint256 p) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = p;
    }

    // --- Deploy + name ---------------------------------------------------

    function test_DeployAndName() public view {
        assertEq(reg.name(), "ZipcodeOracleRegistry");
        assertEq(reg.quote(), usdc);
        assertEq(reg.validityWindow(), VALIDITY);
        assertGt(reg.validityWindow(), 0);
        assertEq(reg.LIEN_DECIMALS(), 18);
        assertEq(reg.getForwarderAddress(), FORWARDER);
        assertEq(reg.owner(), address(this));
    }

    // --- Scale / value identity (load-bearing, audit L4) -----------------

    function test_ScaleValueIdentity() public {
        _wireController();
        _seed(address(LIEN), 300_000e6);
        assertEq(reg.getQuote(1e18, address(LIEN), usdc), 300_000e6); // EXACT ==
        (uint256 bid, uint256 ask) = reg.getQuotes(1e18, address(LIEN), usdc);
        assertEq(bid, 300_000e6);
        assertEq(ask, 300_000e6);
        assertEq(reg.getQuote(0.5e18, address(LIEN), usdc), 150_000e6);
        assertEq(reg.getQuote(0, address(LIEN), usdc), 0);
    }

    // --- Scale truncation + jumbo ----------------------------------------

    function test_ScaleTruncationFloor() public {
        _wireController();
        uint256 price = 333_333e6 + 1;
        _seed(address(LIEN), price);
        // priceScale = 1e6, feedScale = 1e24 ⇒ out = fullMulDiv(in, 1e6*price, 1e24)
        uint256 expected = FixedPointMathLib.fullMulDiv(3e17, 1e6 * price, 1e24);
        assertEq(reg.getQuote(3e17, address(LIEN), usdc), expected);
    }

    function test_JumboNoOverflow() public {
        _wireController();
        _seed(address(LIEN_A), 50_000_000e6);
        assertEq(reg.getQuote(1e18, address(LIEN_A), usdc), 50_000_000e6);
    }

    // --- Seed authority + event ------------------------------------------

    function test_SeedAuthorityAndEvent() public {
        _wireController();
        vm.expectRevert(ZipcodeOracleRegistry.NotController.selector);
        vm.prank(address(0xBAD));
        reg.seedPrice(address(LIEN), 300_000e6);

        vm.expectEmit(true, false, false, true);
        emit RegistryPriceSeed(address(LIEN), 300_000e6);
        vm.prank(CTRL);
        reg.seedPrice(address(LIEN), 300_000e6);

        (, uint48 ts) = reg.cache(address(LIEN));
        assertEq(ts, uint48(block.timestamp));
    }

    // --- Re-seed / overwrite ---------------------------------------------

    function test_ReseedOverwrite() public {
        _wireController();
        uint256 t1 = block.timestamp;
        _seed(address(LIEN), 100_000e6);
        vm.warp(t1 + 100);
        _seed(address(LIEN), 200_000e6);
        (uint208 price, uint48 ts) = reg.cache(address(LIEN));
        assertEq(price, 200_000e6);
        assertEq(ts, uint48(t1 + 100));
    }

    // --- controller re-point (Timelock-settable, §17) --------------------

    function test_SetControllerRepoint() public {
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD))
        );
        vm.prank(address(0xBAD));
        reg.setController(CTRL);

        // zero-address rejected.
        vm.expectRevert(ZipcodeOracleRegistry.ZeroAddress.selector);
        reg.setController(address(0));

        vm.expectEmit(true, false, false, false);
        emit ControllerSet(CTRL);
        reg.setController(CTRL);
        assertEq(reg.controller(), CTRL);

        // §17: a second call RE-POINTS (no set-once freeze) to the new owner-supplied value.
        vm.expectEmit(true, false, false, false);
        emit ControllerSet(address(0xDEAD));
        reg.setController(address(0xDEAD));
        assertEq(reg.controller(), address(0xDEAD));
    }

    // --- Revaluation (Forwarder path), garbage metadata ------------------

    function test_RevaluationForwarderPath() public {
        address[] memory liens = new address[](2);
        liens[0] = address(LIEN_A);
        liens[1] = address(LIEN_B);
        uint256[] memory prices = new uint256[](2);
        prices[0] = 111_000e6;
        prices[1] = 222_000e6;
        uint32 ts = uint32(block.timestamp);
        bytes memory report = _revalReport(liens, prices, ts);

        // Non-empty GARBAGE metadata: identity branch skipped because expectations are all zero.
        bytes memory garbage = hex"deadbeefdeadbeefdeadbeef";

        vm.expectEmit(true, false, false, true);
        emit RegistryPriceUpdated(address(LIEN_A), 111_000e6, uint48(ts));
        vm.expectEmit(true, false, false, true);
        emit RegistryPriceUpdated(address(LIEN_B), 222_000e6, uint48(ts));
        vm.prank(FORWARDER);
        reg.onReport(garbage, report);

        assertEq(reg.getQuote(1e18, address(LIEN_A), usdc), 111_000e6);
        assertEq(reg.getQuote(1e18, address(LIEN_B), usdc), 222_000e6);
        (, uint48 cachedTs) = reg.cache(address(LIEN_A));
        assertEq(cachedTs, uint48(ts));
    }

    // --- Revaluation overwriting a seeded entry --------------------------

    function test_RevaluationOverwritesSeed() public {
        _wireController();
        _seed(address(LIEN), 300_000e6);
        // SEC-01: a reval overwrites the seed only with a strictly-newer ts (a backdated overwrite is rejected — see test_SEC01_*).
        uint32 newer = uint32(block.timestamp + 50);
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(250_000e6)), newer);
        vm.warp(block.timestamp + 50);
        vm.prank(FORWARDER);
        reg.onReport("", report);
        (uint208 price, uint48 ts) = reg.cache(address(LIEN));
        assertEq(price, 250_000e6);
        assertEq(ts, uint48(newer));
    }

    // --- Forwarder gate + reportType + length ----------------------------

    function test_ForwarderGate() public {
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(1e6)), uint32(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, address(0xBAD), FORWARDER)
        );
        vm.prank(address(0xBAD));
        reg.onReport("", report);
    }

    function test_InvalidReportTypes() public {
        uint8[4] memory bad = [uint8(0), uint8(1), uint8(2), uint8(255)];
        for (uint256 i = 0; i < bad.length; i++) {
            bytes memory payload = abi.encode(_one(address(LIEN)), _one(uint256(1e6)), uint32(block.timestamp));
            bytes memory report = abi.encode(bad[i], payload);
            vm.expectRevert(
                abi.encodeWithSelector(ZipcodeOracleRegistry.InvalidReportType.selector, bad[i])
            );
            vm.prank(FORWARDER);
            reg.onReport("", report);
        }
    }

    function test_LengthMismatch() public {
        // 2 vs 1
        address[] memory liens2 = new address[](2);
        liens2[0] = address(LIEN_A);
        liens2[1] = address(LIEN_B);
        bytes memory r1 = _revalReport(liens2, _one(uint256(1e6)), uint32(block.timestamp));
        vm.expectRevert(ZipcodeOracleRegistry.LengthMismatch.selector);
        vm.prank(FORWARDER);
        reg.onReport("", r1);

        // 1 vs 2
        uint256[] memory prices2 = new uint256[](2);
        prices2[0] = 1e6;
        prices2[1] = 2e6;
        bytes memory r2 = _revalReport(_one(address(LIEN_A)), prices2, uint32(block.timestamp));
        vm.expectRevert(ZipcodeOracleRegistry.LengthMismatch.selector);
        vm.prank(FORWARDER);
        reg.onReport("", r2);
    }

    function test_EmptyBatchNoRevert() public {
        address[] memory liens0 = new address[](0);
        uint256[] memory prices0 = new uint256[](0);
        bytes memory report = _revalReport(liens0, prices0, uint32(block.timestamp));
        // Should not revert and emit zero updates (vm.recordLogs to count).
        vm.recordLogs();
        vm.prank(FORWARDER);
        reg.onReport("", report);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 updates = 0;
        bytes32 sig = keccak256("RegistryPriceUpdated(address,uint256,uint48)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) updates++;
        }
        assertEq(updates, 0);
    }

    // --- Duplicate liens last-write-wins ---------------------------------

    // SEC-01: a duplicate lien inside one batch shares the batch's single `ts`, so the SECOND write of that lien
    // has `ts == cache.timestamp` (just written) and is rejected as a replay. The all-or-nothing batch reverts —
    // a malformed duplicate report now fails closed instead of silently last-write-winning.
    function test_DuplicateLiensInBatchRevertStale() public {
        address[] memory liens = new address[](2);
        liens[0] = address(LIEN_A);
        liens[1] = address(LIEN_A);
        uint256[] memory prices = new uint256[](2);
        prices[0] = 100_000e6;
        prices[1] = 200_000e6;
        bytes memory report = _revalReport(liens, prices, uint32(block.timestamp));

        vm.expectRevert(ZipcodeOracleRegistry.StaleReport.selector);
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    // --- Write guards: BOTH paths ----------------------------------------

    function test_WriteGuard_ZeroPrice_Seed() public {
        _wireController();
        vm.expectRevert(Errors.PriceOracle_InvalidAnswer.selector);
        vm.prank(CTRL);
        reg.seedPrice(address(LIEN), 0);
    }

    function test_WriteGuard_ZeroPrice_Reval() public {
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(0)), uint32(block.timestamp));
        vm.expectRevert(Errors.PriceOracle_InvalidAnswer.selector);
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    function test_WriteGuard_Uint208Boundary_Succeeds_Seed() public {
        _wireController();
        uint256 max208 = uint256(type(uint208).max);
        _seed(address(LIEN), max208);
        (uint208 price,) = reg.cache(address(LIEN));
        assertEq(price, type(uint208).max);
    }

    function test_WriteGuard_Uint208Boundary_Succeeds_Reval() public {
        uint256 max208 = uint256(type(uint208).max);
        bytes memory report = _revalReport(_one(address(LIEN)), _one(max208), uint32(block.timestamp));
        vm.prank(FORWARDER);
        reg.onReport("", report);
        (uint208 price,) = reg.cache(address(LIEN));
        assertEq(price, type(uint208).max);
    }

    function test_WriteGuard_Overflow_Seed() public {
        _wireController();
        uint256 over = uint256(type(uint208).max) + 1;
        vm.expectRevert(Errors.PriceOracle_Overflow.selector);
        vm.prank(CTRL);
        reg.seedPrice(address(LIEN), over);
    }

    function test_WriteGuard_Overflow_Reval() public {
        uint256 over = uint256(type(uint208).max) + 1;
        bytes memory report = _revalReport(_one(address(LIEN)), _one(over), uint32(block.timestamp));
        vm.expectRevert(Errors.PriceOracle_Overflow.selector);
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    function test_WriteGuard_FutureTimestamp_Reval() public {
        // seed path cannot reach FutureTimestamp (uses block.timestamp); only revaluation can.
        uint32 future = uint32(block.timestamp + 1);
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(1e6)), future);
        vm.expectRevert(ZipcodeOracleRegistry.FutureTimestamp.selector);
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    // --- Strict-decimals guard is REAL (the key defensive proof) ---------

    function test_StrictDecimals_6dp_Rejected_Seed() public {
        _wireController();
        address sixDp = address(new DecimalsMock(6));
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeOracleRegistry.InvalidLienDecimals.selector, sixDp)
        );
        vm.prank(CTRL);
        reg.seedPrice(sixDp, 1e6);
    }

    function test_StrictDecimals_6dp_Rejected_Reval() public {
        address sixDp = address(new DecimalsMock(6));
        bytes memory report = _revalReport(_one(sixDp), _one(uint256(1e6)), uint32(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeOracleRegistry.InvalidLienDecimals.selector, sixDp)
        );
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    function test_StrictDecimals_EOA_Rejected_Seed() public {
        _wireController();
        address eoa = address(0xE0A); // no code → staticcall ok=true, len=0 → strict guard rejects
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeOracleRegistry.InvalidLienDecimals.selector, eoa)
        );
        vm.prank(CTRL);
        reg.seedPrice(eoa, 1e6);
    }

    function test_StrictDecimals_EOA_Rejected_Reval() public {
        address eoa = address(0xE0A);
        bytes memory report = _revalReport(_one(eoa), _one(uint256(1e6)), uint32(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(ZipcodeOracleRegistry.InvalidLienDecimals.selector, eoa)
        );
        vm.prank(FORWARDER);
        reg.onReport("", report);
    }

    // --- No value band (positive proof) ----------------------------------

    function test_NoValueBand_BigDrop_Succeeds() public {
        _wireController();
        _seed(address(LIEN), 300_000e6);
        // >99% drop in one report (no value band) — at a strictly-newer ts (SEC-01 monotonic guard).
        vm.warp(block.timestamp + 1);
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(1e6)), uint32(block.timestamp));
        vm.prank(FORWARDER);
        reg.onReport("", report);
        (uint208 price,) = reg.cache(address(LIEN));
        assertEq(price, 1e6);
    }

    // --- Read guards -----------------------------------------------------

    function test_ReadGuard_UncachedNotSupported() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, address(LIEN), usdc)
        );
        reg.getQuote(1e18, address(LIEN), usdc);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, address(LIEN), usdc)
        );
        reg.getQuotes(1e18, address(LIEN), usdc);
    }

    function test_ReadGuard_WrongQuoteNotSupported() public {
        _wireController();
        _seed(address(LIEN), 300_000e6);
        address otherQuote = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, address(LIEN), otherQuote)
        );
        reg.getQuote(1e18, address(LIEN), otherQuote);
    }

    function test_ReadGuard_TooStale_ExactArgs() public {
        _wireController();
        uint256 seedTs = block.timestamp;
        _seed(address(LIEN), 300_000e6);
        vm.warp(seedTs + VALIDITY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY)
        );
        reg.getQuote(1e18, address(LIEN), usdc);
    }

    function test_ReadGuard_BoundaryStillFresh() public {
        _wireController();
        uint256 seedTs = block.timestamp;
        _seed(address(LIEN), 300_000e6);
        vm.warp(seedTs + VALIDITY); // exactly at window → still valid
        assertEq(reg.getQuote(1e18, address(LIEN), usdc), 300_000e6);
    }

    // --- Forwarder immutability + identity (S10b -> S11) ------------------

    function _packedMetadata(bytes32 wid, bytes10 wname, address wowner) internal pure returns (bytes memory) {
        return abi.encodePacked(wid, wname, wowner);
    }

    function test_IdentityGate_WrongWorkflowId_BeforeRenounce() public {
        bytes32 WID = keccak256("the-real-workflow");
        bytes32 wrongId = keccak256("wrong-workflow");
        reg.setExpectedAuthor(address(this));
        reg.setExpectedWorkflowId(WID);

        bytes memory metadata = _packedMetadata(wrongId, bytes10("name"), address(this));
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(1e6)), uint32(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, wrongId, WID)
        );
        vm.prank(FORWARDER);
        reg.onReport(metadata, report);
    }

    function test_Renounce_FreezesSettersButIdentityStaysLive() public {
        bytes32 WID = keccak256("the-real-workflow");
        bytes32 wrongId = keccak256("wrong-workflow");
        reg.setExpectedAuthor(address(this));
        reg.setExpectedWorkflowId(WID);

        reg.renounceOwnership();
        assertEq(reg.owner(), address(0));

        // All onlyOwner setters now revert OwnableUnauthorizedAccount.
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this))
        );
        reg.setForwarderAddress(address(0x1234));

        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this))
        );
        reg.setExpectedAuthor(address(0x1234));

        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this))
        );
        reg.setController(address(0x1234));

        // The identity gate is still live: a wrong-id onReport still reverts InvalidWorkflowId.
        bytes memory metadata = _packedMetadata(wrongId, bytes10("name"), address(this));
        bytes memory report = _revalReport(_one(address(LIEN)), _one(uint256(1e6)), uint32(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, wrongId, WID)
        );
        vm.prank(FORWARDER);
        reg.onReport(metadata, report);
    }

    function test_RenouncedWithoutController_SeedForeverReverts() public {
        // No setController. Renounce. seedPrice is permanently unreachable (controller == address(0)).
        reg.renounceOwnership();
        assertEq(reg.controller(), address(0));
        vm.expectRevert(ZipcodeOracleRegistry.NotController.selector);
        vm.prank(address(this));
        reg.seedPrice(address(LIEN), 300_000e6);
    }

    // --- Forwarder immutability: constructor-set forwarder is identity ---

    function test_ForwarderImmutableAfterRenounce() public {
        reg.renounceOwnership();
        assertEq(reg.getForwarderAddress(), FORWARDER); // unchanged, and now unchangeable
    }

    // --- SEC-01: oracle monotonic-timestamp guard (H1) -------------------
    // The shared `_writePrice` rejects any write whose `ts` is not strictly newer than the cached mark, covering
    // BOTH write paths (the controller `seedPrice` clobber and the Forwarder rt-3 batch). First write (timestamp==0)
    // always passes. Mirrors `SzAlphaRateOracle:86`.

    // seedPrice path: a same-block re-seed (equal `block.timestamp`) is a replay → StaleReport.
    function test_SEC01_seedPrice_equalTs_reverts() public {
        _wireController();
        _seed(address(LIEN), 100_000e6); // first write, cache.timestamp = block.timestamp
        vm.expectRevert(ZipcodeOracleRegistry.StaleReport.selector);
        vm.prank(CTRL);
        reg.seedPrice(address(LIEN), 200_000e6); // same block → ts == cache.timestamp
    }

    // rt-3 batch path: a backdated revaluation over a fresher mark → StaleReport (shields-a-bad-loan replay).
    function test_SEC01_reval_backdated_reverts() public {
        uint32 t = uint32(block.timestamp);
        bytes memory fresh = _revalReport(_one(address(LIEN)), _one(uint256(300_000e6)), t);
        vm.prank(FORWARDER);
        reg.onReport("", fresh);

        bytes memory stale = _revalReport(_one(address(LIEN)), _one(uint256(250_000e6)), t - 50);
        vm.expectRevert(ZipcodeOracleRegistry.StaleReport.selector);
        vm.prank(FORWARDER);
        reg.onReport("", stale);
    }

    // rt-3 batch path: an equal-ts replay → StaleReport.
    function test_SEC01_reval_equalTs_reverts() public {
        uint32 t = uint32(block.timestamp);
        bytes memory r1 = _revalReport(_one(address(LIEN)), _one(uint256(300_000e6)), t);
        vm.prank(FORWARDER);
        reg.onReport("", r1);

        bytes memory r2 = _revalReport(_one(address(LIEN)), _one(uint256(310_000e6)), t);
        vm.expectRevert(ZipcodeOracleRegistry.StaleReport.selector);
        vm.prank(FORWARDER);
        reg.onReport("", r2);
    }

    // A strictly-newer write still succeeds (the guard only rejects equal/older).
    function test_SEC01_strictlyNewer_succeeds() public {
        uint32 t = uint32(block.timestamp);
        bytes memory r1 = _revalReport(_one(address(LIEN)), _one(uint256(300_000e6)), t);
        vm.prank(FORWARDER);
        reg.onReport("", r1);

        vm.warp(block.timestamp + 1);
        bytes memory r2 = _revalReport(_one(address(LIEN)), _one(uint256(310_000e6)), t + 1);
        vm.prank(FORWARDER);
        reg.onReport("", r2);

        (uint208 price, uint48 ts) = reg.cache(address(LIEN));
        assertEq(price, 310_000e6);
        assertEq(ts, uint48(t + 1));
    }

    // --- I-11: setQuote + setValidityWindow (onlyOwner + zero + effect) ---

    /// @notice `setQuote` is `onlyOwner`, zero-guarded, re-derives the global `scale`, and re-points the supported
    ///         quote: the new pair prices (scale valid) and the old quote reverts `NotSupported`. (The scale is
    ///         numerically decimals-invariant by construction — feedDecimals==quoteDecimals collapses it to /1e18 —
    ///         so the re-derive is proven by "the new quote prices correctly without bricking", not a value delta.)
    function test_I11_setQuote_guards_and_effect() public {
        // onlyOwner
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        reg.setQuote(usdc);
        // zero-guard
        vm.expectRevert(ZipcodeOracleRegistry.ZeroAddress.selector);
        reg.setQuote(address(0));

        // effect: re-point to a fresh quote + emit WiringSet("quote", ..)
        address newQuote = address(new DecimalsMock(6));
        vm.expectEmit(true, false, false, true, address(reg));
        emit WiringSet("quote", newQuote);
        reg.setQuote(newQuote);
        assertEq(reg.quote(), newQuote, "quote re-pointed");

        // the new pair prices via the re-derived scale; the OLD quote is no longer supported.
        _wireController();
        _seed(address(LIEN), 300_000e6);
        assertEq(reg.getQuote(1e18, address(LIEN), newQuote), 300_000e6, "prices via the new quote (scale valid)");
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, address(LIEN), usdc));
        reg.getQuote(1e18, address(LIEN), usdc);
    }

    /// @notice `setValidityWindow` is `onlyOwner` and tightening it makes a previously-fresh mark read as stale.
    function test_I11_setValidityWindow_guards_and_effect() public {
        // onlyOwner
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        reg.setValidityWindow(10);

        _wireController();
        uint256 t0 = block.timestamp;
        _seed(address(LIEN), 300_000e6); // mark written at t0

        vm.expectEmit(false, false, false, true, address(reg));
        emit ValidityWindowSet(10);
        reg.setValidityWindow(10);
        assertEq(reg.validityWindow(), 10, "window tightened");

        vm.warp(t0 + 11); // 11s > 10s window
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, uint256(11), uint256(10)));
        reg.getQuote(1e18, address(LIEN), usdc);
    }
}
