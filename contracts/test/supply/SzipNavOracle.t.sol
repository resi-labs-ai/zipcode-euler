// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipNavOracle} from "../../src/supply/SzipNavOracle.sol";
import {IchiAlgebraFairReserves} from "../../src/supply/lib/IchiAlgebraFairReserves.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IICHIVault} from "../../src/interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../../src/interfaces/algebra/IAlgebraPool.sol";
import {IAlgebraOraclePlugin} from "../../src/interfaces/algebra/IAlgebraOraclePlugin.sol";
import {IGauge} from "../../src/interfaces/hydrex/IGauge.sol";
import {IOptionToken} from "../../src/interfaces/hydrex/IOptionToken.sol";

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
    address public pool; // SEC-10: the Algebra pool the vault provides liquidity to (settable)

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

    function setPool(address _pool) external {
        pool = _pool;
    }

    function getTotalAmounts() external view returns (uint256, uint256) {
        return (t0, t1);
    }

    // SEC-10 fair-reserves introspection. Liquidity L = 0 for both positions so
    // LiquidityAmounts.getAmountsForLiquidity yields (0,0) regardless of tick — the
    // reconstructed reserves then come purely from the vault's idle IERC20 token balances.
    function getBasePosition() external pure returns (uint128, uint256, uint256) {
        return (0, 0, 0);
    }

    function getLimitPosition() external pure returns (uint128, uint256, uint256) {
        return (0, 0, 0);
    }

    // Valid in-range ticks within TickMath's [-887272, 887272].
    function baseLower() external pure returns (int24) {
        return -887220;
    }

    function baseUpper() external pure returns (int24) {
        return 887220;
    }

    function limitLower() external pure returns (int24) {
        return -887220;
    }

    function limitUpper() external pure returns (int24) {
        return 887220;
    }
}

/// @dev SEC-10: minimal Algebra pool with a settable `plugin()` — `address(0)` for the no-plugin case,
///      the mock plugin otherwise.
contract MockAlgebraPool {
    address public plugin;

    function setPlugin(address _plugin) external {
        plugin = _plugin;
    }
}

/// @dev SEC-10: minimal Algebra oracle plugin. `isInitialized()` settable; `getTimepoints` returns the real
///      on-chain cumulatives cited in IAlgebraOraclePlugin.sol:6-8 — getTimepoints([3600,0]) ->
///      tickCumulatives [-1380399043048, -1381518031724] (mean tick ≈ -310830, a valid TickMath tick) so the
///      ready-pool case reads through `fairReserves` without reverting in TickMath.
contract MockAlgebraPlugin {
    bool public isInitialized;
    uint32 public oldestTs; // slot-0 timestamp — drives the history-depth gate (default 0 ⇒ history since genesis)

    function setInitialized(bool v) external {
        isInitialized = v;
    }

    function setOldestTs(uint32 v) external {
        oldestTs = v;
    }

    // Pre-wrap ring shape: head = 1, slot head+1 uninitialized ⇒ the gate reads slot 0 as the oldest.
    function timepointIndex() external pure returns (uint16) {
        return 1;
    }

    function timepoints(uint256 index)
        external
        view
        returns (bool initialized, uint32 blockTimestamp, int56, uint88, int24, int24, uint16)
    {
        if (index == 0) return (true, oldestTs, 0, 0, 0, 0, 0);
        return (false, 0, 0, 0, 0, 0, 0);
    }

    function getTimepoints(uint32[] calldata)
        external
        pure
        returns (int56[] memory tickCumulatives, uint88[] memory volatilityCumulatives)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = -1380399043048; // window-ago (3600)
        tickCumulatives[1] = -1381518031724; // now (0)
        volatilityCumulatives = new uint88[](2); // unused by fairReserves
    }
}

contract MockGauge {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }
}

/// @dev The farm utility LP escrow collateral vault — a bare 1:1 box (`convertToAssets(s) == s`).
contract MockEscrowVault {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @dev The farm utility USDC borrow vault — only `debtOf` is read (USDC 6-dp). `setReverting(true)` simulates an
///      integration regression (the view reverting) for the recovery-lever test.
contract MockBorrowVault {
    mapping(address => uint256) internal debt;
    bool public reverting;

    function setDebt(address a, uint256 v) external {
        debt[a] = v;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function debtOf(address a) external view returns (uint256) {
        require(!reverting, "borrow vault view regressed");
        return debt[a];
    }
}

/// @dev A `ZipRedemptionQueue` receivables stand-in (SEC/M-2): trivial storage getters for pending zipUSD (18-dp) and
///      claimable USDC (6-dp), plus a `settle` that atomically moves pending→claimable at par (mirrors settleEpoch's
///      burn-and-bank) so the NAV-continuity test can drive the real request→settle→claim lifecycle.
contract MockRedemptionQueue {
    mapping(address => uint256) public pending; // 18-dp zipUSD escrowed
    mapping(address => uint256) public claimable; // 6-dp USDC filled, unclaimed

    function setPending(address r, uint256 v) external {
        pending[r] = v;
    }

    function setClaimable(address r, uint256 v) external {
        claimable[r] = v;
    }

    /// @dev Fill `assets` USDC (6-dp) of `r`'s pending at par: burn `assets * 1e12` pending zipUSD, bank `assets` USDC.
    function settle(address r, uint256 assets) external {
        pending[r] -= assets * 1e12;
        claimable[r] += assets;
    }

    function pendingRedeemRequest(uint256, address r) external view returns (uint256) {
        return pending[r];
    }

    function maxWithdraw(address r) external view returns (uint256) {
        return claimable[r];
    }
}

// --------------------------------------------------------------------------- tests
contract SzipNavOracleTest is Test {
    SzipNavOracle oracle;

    address forwarder = makeAddr("forwarder");
    address juniorTrancheSafe = makeAddr("juniorTrancheSafe");
    address juniorTrancheSidecar = makeAddr("juniorTrancheSidecar");
    address dc = makeAddr("defaultCoordinator");
    /// @dev ONE address with two role names — the oracle now enforces `engine == safe`.
    address juniorTrancheEngine = juniorTrancheSafe;

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
    event RedemptionQueueSet(address indexed redemptionQueue);

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
            juniorTrancheSafe,
            juniorTrancheSidecar,
            W,
            MAX_AGE
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
        assertEq(oracle.juniorTrancheSafe(), juniorTrancheSafe);
        assertEq(oracle.juniorTrancheSidecar(), juniorTrancheSidecar);
        assertEq(oracle.W(), W);
        assertEq(oracle.maxAge(), MAX_AGE);
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
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, W, MAX_AGE
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, 0, MAX_AGE
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, W, 0
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
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, W, MAX_AGE
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
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, W, MAX_AGE
        );
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        fresh.setLpPosition(address(0), address(g));
    }

    function test_setJuniorTrancheEngine_and_setDefaultCoordinator_setOnce() public {
        oracle.setJuniorTrancheEngine(juniorTrancheEngine);
        assertEq(oracle.juniorTrancheEngine(), juniorTrancheEngine);
        // NOT re-settable to anything else: engine and safe are one address with two role names, and the numerator
        // counts the safe while the denominator excludes the engine, so a divergence would zero NAV.
        address es2 = makeAddr("es2");
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.EngineMustEqualSafe.selector, es2, juniorTrancheSafe));
        oracle.setJuniorTrancheEngine(es2);
        assertEq(oracle.juniorTrancheEngine(), juniorTrancheSafe, "unchanged by the rejected re-point");
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
        zip.setBalance(juniorTrancheSafe, 500e18); // basket has value but no shares
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

    // ----------------------------------------------------------------- SEC-13 (L12): oldestRequiredLegTs view
    /// @notice The new additive view returns the MIN of the two required pushed-leg timestamps — the anchor the §7
    ///         buy-burn fence uses (SEC-13 / kill-list L12). Push the legs at different times and assert the older.
    function test_SEC13_oldestRequiredLegTs_min_of_two_legs() public {
        uint48 t0 = uint48(block.timestamp);
        _push(1, 5e17); // HYDX at t0 (older)
        vm.warp(t0 + 3 hours);
        _push(0, 1e18); // ALPHA at t0+3h (newer)
        assertEq(oracle.oldestRequiredLegTs(), t0, "anchor = older (HYDX) leg ts");
    }

    /// @notice When the xALPHA rate oracle is wired, its `lastUpdate()` is folded into the min when older than both
    ///         legs; a never-seeded rate (`lastUpdate()==0`) is excluded so the anchor is not clamped to 0.
    function test_SEC13_oldestRequiredLegTs_folds_rate_ts_when_wired() public {
        MockRateOracle rateOracle = new MockRateOracle();
        rateOracle.setRate(1e18);
        rateOracle.setFresh(true);
        oracle.setXAlphaRateOracle(address(rateOracle));

        uint48 t0 = uint48(block.timestamp);
        _pushBoth(1e18, 5e17); // both legs at t0
        // rate unseeded (lastUpdate==0) ⇒ excluded; anchor stays at the legs' t0
        assertEq(oracle.oldestRequiredLegTs(), t0, "unseeded rate excluded from min");
        // rate stamped OLDER than the legs ⇒ becomes the anchor
        rateOracle.setLastUpdate(t0 - 1 hours);
        assertEq(oracle.oldestRequiredLegTs(), t0 - 1 hours, "older rate ts folds into min");
        // rate stamped NEWER than the legs ⇒ legs remain the anchor
        rateOracle.setLastUpdate(t0 + 1 hours);
        assertEq(oracle.oldestRequiredLegTs(), t0, "newer rate ts does not raise the anchor");
    }

    /// @notice The rate leg's fence honors the rate oracle's OWN `maxStaleness` when tighter than `maxAge`: the
    ///         folded timestamp is shifted back by `maxAge − maxStaleness`, so the module's `anchor + maxAge`
    ///         ceiling lands at `lastUpdate + maxStaleness`. A bid can never outlive the rate that priced it.
    function test_oldestRequiredLegTs_rate_window_tighter_than_maxAge() public {
        MockRateOracle rateOracle = new MockRateOracle();
        rateOracle.setRate(1e18);
        rateOracle.setFresh(true);
        oracle.setXAlphaRateOracle(address(rateOracle));

        uint48 t0 = uint48(block.timestamp);
        _pushBoth(1e18, 5e17); // both legs at t0
        uint256 ms = MAX_AGE / 4; // the rate's own bound, tighter than maxAge
        rateOracle.setMaxStaleness(ms);
        rateOracle.setLastUpdate(t0); // rate as fresh as the legs
        // shifted rate ts = t0 - (maxAge - ms) becomes the min ⇒ fence = t0 + ms, not t0 + maxAge
        assertEq(uint256(oracle.oldestRequiredLegTs()) + MAX_AGE, uint256(t0) + ms, "fence = lastUpdate + maxStaleness");
        // ms >= maxAge ⇒ no shift, plain fold
        rateOracle.setMaxStaleness(MAX_AGE * 2);
        assertEq(oracle.oldestRequiredLegTs(), t0, "wider rate bound leaves the maxAge fence");
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

    // ----------------------------------------------------------------- no deviation band (removed 2026-07-31)
    /// @notice The band capped each push at +/-N% vs the last cached price. On a SPOT feed that rejects the truth:
    ///         an 11% real move could not be published, and the CRE producer's answer was `bandClamp` — push the
    ///         band EDGE, a knowingly-wrong number, silently. Magnitude is now guarded at the source (a CRE-side
    ///         TWAP of the subnet-46 pool reserves), so an implausible jump never arises rather than being clamped.
    ///         See `deriveAlphaUSD` in `cre/sharefeeds/workflow.go`.
    function test_no_band_large_honest_move_lands_at_true_value() public {
        _push(0, 1e18);
        vm.warp(block.timestamp + 1); // SEC-01: strictly-newer ts still required
        _push(0, 121e16); // +21% — would have reverted DeviationExceeded
        (uint256 p,) = oracle.legCache(0);
        assertEq(p, 121e16, "recorded at the TRUE price, not clamped to a band edge");
    }

    /// @notice A crash is symmetric: a -50% move is a real market event and must be publishable.
    function test_no_band_large_downward_move_lands() public {
        _push(0, 1e18);
        vm.warp(block.timestamp + 1);
        _push(0, 5e17); // -50%
        (uint256 p,) = oracle.legCache(0);
        assertEq(p, 5e17);
    }

    /// @notice The guards that REMAIN on the push path are unaffected by the band's removal.
    function test_no_band_other_push_guards_intact() public {
        _push(0, 1e18);
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 0; // zero price still rejected
        vm.warp(block.timestamp + 1); // advance the clock, not the report ts (a future ts trips FutureTimestamp first)
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.ZeroPrice.selector);
        oracle.onReport("", report);
    }

    // SEC-01 (M1): the deviation band is PRICE-ONLY, so replaying the last price with a backdated/equal `ts` slips
    // through it and would freeze issuance + buy-burn. The monotonic guard catches it. Same price (diff == 0) proves
    // the deviation band alone does not — only the strictly-newer `ts` check rejects the replay.
    function test_SEC01_nav_backdated_replay_reverts() public {
        _push(0, 1e18); // first write at the current block.timestamp
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0;
        ps[0] = 1e18; // identical price → deviation band passes
        uint32 backdated = uint32(block.timestamp - 1); // older than the cached leg ts (and not-future)
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, backdated));
        vm.prank(forwarder);
        vm.expectRevert(SzipNavOracle.StaleReport.selector);
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------------- atomicity
    function test_batch_atomicity_one_bad_entry_reverts_all() public {
        _push(0, 1e18); // prior for leg 0
        _push(1, 5e17); // prior for leg 1
        vm.warp(block.timestamp + 1); // SEC-01: the batch needs a strictly-newer ts so leg0 clears the monotonic guard and leg1's ZeroPrice is reached
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
        zip.setBalance(juniorTrancheSafe, 100e18);
        zip.setBalance(juniorTrancheSidecar, 50e18); // _bal(zip) = 150e18
        usdc.setBalance(juniorTrancheSafe, 1000e6); // -> 1000e18
        xa.setBalance(juniorTrancheSafe, 10e18);
        xa.setExchangeRate(12e17); // 1.2
        hydx.setBalance(juniorTrancheSafe, 5e18); // marked $0 in NAV by design (sale inventory)
        ohydx.setBalance(juniorTrancheSafe, 4e18); // marked $0 in NAV by design
        _pushBoth(2e18, 5e17); // alphaUSD=2, hydxUSD=0.5
    }

    function test_nav_composition_handcomputed() public {
        _wireFullBasket();
        // gross = 150 (zip) + 1000 (usdc) + 24 (xa:10*1.2*2) + 0 (hydx/ohydx: marked $0) = 1174e18
        assertEq(oracle.grossBasketValue(), 1174e18);
        // spot = 1174e18 / 1000 = 1.174e18
        assertEq(oracle.spotNavPerShare(), 1174e15);
    }

    function test_nav_hydx_and_ohydx_marked_zero_and_discount_never_read() public {
        _wireFullBasket();
        uint256 base = oracle.grossBasketValue();
        hydx.setBalance(juniorTrancheSafe, 1_000_000e18); // sale inventory: any size, still $0 in NAV
        ohydx.setBalance(juniorTrancheSafe, 1_000_000e18); // any size: still $0 in NAV
        assertEq(oracle.grossBasketValue(), base);
        ohydx.setDiscount(150); // even a broken discount() can't touch NAV — it is never read
        assertEq(oracle.grossBasketValue(), base);
        assertEq(oracle.spotNavPerShare(), base * 1e18 / 1000e18);
    }

    function test_nav_xalpha_exchangeRate_accrual() public {
        _wireFullBasket();
        uint256 before = oracle.spotNavPerShare();
        xa.setExchangeRate(13e17); // LST APR accrues -> xa leg up by 10e18*0.1*2 = 2e18 gross
        assertEq(oracle.grossBasketValue(), 1174e18 + 2e18);
        assertGt(oracle.spotNavPerShare(), before);
    }

    function test_nav_engine_pending_burn_subtracts() public {
        _wireFullBasket();
        uint256 noBurn = oracle.spotNavPerShare(); // supply 1000
        oracle.setJuniorTrancheEngine(juniorTrancheEngine);
        szip.setBalance(juniorTrancheEngine, 100e18); // effective supply 900
        uint256 gross = oracle.grossBasketValue();
        assertEq(oracle.spotNavPerShare(), gross * 1e18 / 900e18);
        assertGt(oracle.spotNavPerShare(), noBurn);
    }

    function test_nav_engine_pending_burn_underflow_floors_to_genesis() public {
        _wireFullBasket();
        oracle.setJuniorTrancheEngine(juniorTrancheEngine);
        szip.setBalance(juniorTrancheEngine, 2000e18); // > totalSupply 1000 -> effective 0
        assertEq(oracle.spotNavPerShare(), 1e18); // genesis, no underflow
    }

    function test_nav_usdc_scale_pinned() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1e18);
        usdc.setBalance(juniorTrancheSafe, 1e6); // exactly 1 USDC -> $1
        _pushBoth(1e18, 1e18);
        assertEq(oracle.grossBasketValue(), 1e18);
    }

    // ----------------------------------------------------------------- SEC/M-2: off-ramp redemption-queue receivables
    function _wireQueue() internal returns (MockRedemptionQueue q) {
        q = new MockRedemptionQueue();
        oracle.setRedemptionQueue(address(q));
    }

    /// @dev Setter: onlyOwner, re-pointable, zero-allowed (unset), emits.
    function test_setRedemptionQueue_onlyOwner_and_zeroAllowed() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        oracle.setRedemptionQueue(address(0xBEEF));

        vm.expectEmit(true, false, false, false);
        emit RedemptionQueueSet(address(0xBEEF));
        oracle.setRedemptionQueue(address(0xBEEF));
        assertEq(oracle.redemptionQueue(), address(0xBEEF));

        oracle.setRedemptionQueue(address(0)); // unset is valid
        assertEq(oracle.redemptionQueue(), address(0));
    }

    /// @dev Unwired (v0) and wired-but-empty both contribute exactly 0 — no spurious NAV movement.
    function test_queue_unwired_and_empty_contribute_zero() public {
        _wireFullBasket();
        uint256 base = oracle.grossBasketValue();
        MockRedemptionQueue q = _wireQueue(); // wired, all zero
        assertEq(oracle.grossBasketValue(), base, "empty queue adds nothing");
        q.setPending(juniorTrancheSafe, 0);
        q.setClaimable(juniorTrancheSafe, 0);
        assertEq(oracle.grossBasketValue(), base, "explicit zeros add nothing");
    }

    /// @dev Pending zipUSD is counted at $1 (18-dp); claimable USDC at $1 (6-dp ×1e12).
    function test_queue_pending_and_claimable_counted() public {
        _wireFullBasket();
        uint256 base = oracle.grossBasketValue();
        MockRedemptionQueue q = _wireQueue();

        q.setPending(juniorTrancheSafe, 40e18); // 40 zipUSD escrowed
        assertEq(oracle.grossBasketValue(), base + 40e18, "pending zipUSD counted at par");

        q.setClaimable(juniorTrancheSafe, 25e6); // 25 USDC filled, unclaimed
        assertEq(oracle.grossBasketValue(), base + 40e18 + 25e18, "claimable USDC scaled 6->18");
    }

    /// @dev Only `juniorTrancheSafe` (the rq Safe) is attributed — receivables booked to any other address are ignored,
    ///      so a mis-wired requester can never inflate NAV.
    function test_queue_only_juniorTrancheSafe_attributed() public {
        _wireFullBasket();
        uint256 base = oracle.grossBasketValue();
        MockRedemptionQueue q = _wireQueue();
        q.setPending(juniorTrancheSidecar, 1_000e18);
        q.setClaimable(makeAddr("stranger"), 1_000e6);
        assertEq(oracle.grossBasketValue(), base, "non-rq-Safe receivables not counted");
    }

    /// @dev Additivity preserved: the receivables are FREE (main-Safe) equity, so `committedValue + freeValue ==
    ///      grossBasketValue` still holds exactly, and `committedValue` (sidecar) is unaffected.
    function test_queue_additivity_committed_plus_free() public {
        _wireFullBasket();
        MockRedemptionQueue q = _wireQueue();
        q.setPending(juniorTrancheSafe, 40e18);
        q.setClaimable(juniorTrancheSafe, 25e6);

        uint256 committedBefore = oracle.committedValue();
        assertEq(oracle.committedValue() + oracle.freeValue(), oracle.grossBasketValue(), "additivity holds");
        // sidecar (committed) is untouched by the off-ramp receivables
        assertEq(oracle.committedValue(), committedBefore, "committedValue unaffected");
    }

    /// @dev THE core property (the fix's whole point): NAV is continuous across the full request→settle→claim
    ///      off-ramp lifecycle, so a deposit made mid-flight mints at the true navEntry, not a depressed one.
    function test_queue_nav_continuous_across_offramp_lifecycle() public {
        _wireFullBasket(); // juniorTrancheSafe holds 100 zipUSD + 1000 USDC (6-dp)
        MockRedemptionQueue q = _wireQueue();
        uint256 G = oracle.grossBasketValue();

        // (1) requestRedeem: 40 zipUSD leaves the Safe into the queue as pending.
        zip.setBalance(juniorTrancheSafe, 60e18);
        q.setPending(juniorTrancheSafe, 40e18);
        assertEq(oracle.grossBasketValue(), G, "continuous across requestRedeem");

        // (2) settleEpoch: burn the pending zipUSD, bank 40 USDC (6-dp) claimable at par.
        q.settle(juniorTrancheSafe, 40e6);
        assertEq(oracle.grossBasketValue(), G, "continuous across settleEpoch");

        // (3) claim: USDC lands back on the Safe; queue drains to empty.
        q.setClaimable(juniorTrancheSafe, 0);
        usdc.setBalance(juniorTrancheSafe, 1040e6);
        assertEq(oracle.grossBasketValue(), G, "continuous across claim");
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
        iv.setBalance(juniorTrancheSafe, 100e18); // unstaked
        g.setBalance(juniorTrancheSafe, 400e18); // staked -> heldShares 500/1000 = half
        // amt0 = 200*0.5=100 zipUSD -> 100e18 ; amt1 = 100*0.5=50 xAlpha -> 50*2.4=120e18 ; LP = 220e18
        assertEq(oracle.grossBasketValue(), 220e18);
        // IL marked-through: raise alphaUSD -> LP value moves
        uint256 lpBefore = oracle.grossBasketValue();
        vm.warp(block.timestamp + 1); // SEC-01: the re-mark needs a strictly-newer ts (monotonic guard)
        _pushBoth(22e17, 5e17); // alphaUSD 2.0 -> 2.2 (within 20%)
        assertGt(oracle.grossBasketValue(), lpBefore);
    }

    function test_lp_unset_contributes_zero() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 100e18);
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
        g.setBalance(juniorTrancheSafe, 1); // heldShares != 0 but supplyLp 0
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
        g.setBalance(juniorTrancheSafe, 500e18);
        _pushBoth(1e18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.UnknownLpToken.selector, address(rogue)));
        oracle.grossBasketValue();
    }

    // ----------------------------------------------------------------- farm utility escrow leg + debt (path-lock)
    function _wireFarmUtility() internal returns (MockEscrowVault e, MockBorrowVault b) {
        e = new MockEscrowVault();
        b = new MockBorrowVault();
        oracle.setFarmUtilityLeg(address(e), address(b));
    }

    function test_farmUtility_escrow_leg_and_debt() public {
        _wireLp(); // 1000 LP supply, reserves 200 zip + 100 xAlpha, xAlphaUSD 2.4
        (MockEscrowVault e, MockBorrowVault b) = _wireFarmUtility();
        // 500 LP posted as escrow collateral (1:1) -> heldShares 500/1000 = half -> 100 zip + 50 xAlpha*2.4 = 220e18
        e.setBalance(juniorTrancheSafe, 500e18);
        b.setDebt(juniorTrancheSafe, 30e6); // 30 USDC strike debt -> 30e18
        assertEq(oracle.pathLockedLpEquity(), 220e18 - 30e18, "LP(all states) - debt");
        assertEq(oracle.grossBasketValue(), 220e18 - 30e18, "escrow LP counted, debt subtracted");
    }

    function test_farmUtility_nav_invariant_across_post() public {
        (, MockGauge g) = _wireLp();
        (MockEscrowVault e, MockBorrowVault b) = _wireFarmUtility();

        // BEFORE the loop: 500 LP staked in the gauge. gross = 220e18 (the test_lp_marked_through basket).
        g.setBalance(juniorTrancheSafe, 500e18);
        assertEq(oracle.grossBasketValue(), 220e18, "pre-loop: staked LP");

        // SIMULATE postCollateral + borrow: unstake (gauge->0), escrow the 500 LP, +30 USDC borrowed into the Safe,
        // +30 USDC debt. NAV must be INVARIANT (the blind spot closed).
        g.setBalance(juniorTrancheSafe, 0);
        e.setBalance(juniorTrancheSafe, 500e18);
        usdc.setBalance(juniorTrancheSafe, 30e6); // borrowed strike sits in the Safe
        b.setDebt(juniorTrancheSafe, 30e6);
        assertEq(oracle.grossBasketValue(), 220e18, "mid-loop: NAV invariant (escrow + USDC - debt)");
        // sanity: the un-fixed oracle would have read 0(escrow unseen) + 30(usdc) = 30e18 here, not 220.
    }

    function test_farmUtility_debt_saturates_at_zero() public {
        _wireLp();
        (MockEscrowVault e, MockBorrowVault b) = _wireFarmUtility();
        e.setBalance(juniorTrancheSafe, 100e18); // 100/1000 -> 20 zip + 10 xAlpha*2.4 = 44e18 LP
        b.setDebt(juniorTrancheSafe, 1_000_000e6); // debt far exceeds the basket
        assertEq(oracle.grossBasketValue(), 0, "debt > basket saturates to 0, no underflow");
        assertEq(oracle.pathLockedLpEquity(), 0, "lp equity saturates to 0");
    }

    function test_farmUtility_unset_contributes_zero() public {
        _wireLp();
        MockGauge(oracle.gauge()).setBalance(juniorTrancheSafe, 500e18);
        // escrowVault/borrowVault unset -> pathLockedLpEquity is just the LP, no debt; gross unchanged.
        assertEq(oracle.grossBasketValue(), 220e18);
        assertEq(oracle.pathLockedLpEquity(), 220e18);
    }

    /// @notice The (0,0) atomic unset is the RECOVERY LEVER for a regressed farm-utility view: a reverting
    ///         `debtOf`/`convertToAssets` freezes `_accumulate()` (poke, leg pushes, provision writes) fail-closed;
    ///         unsetting the leg restores liveness with the loop legs (escrow LP + debt) out of the basket.
    function test_farmUtility_unset_recovers_from_reverting_view() public {
        _wireLp(); // wires shareToken + 1000e18 supply
        (MockEscrowVault e, MockBorrowVault b) = _wireFarmUtility();
        e.setBalance(juniorTrancheSafe, 500e18); // mid-loop: 500 LP escrowed
        b.setDebt(juniorTrancheSafe, 30e6);
        assertEq(oracle.grossBasketValue(), 220e18 - 30e18, "pre-regression baseline");
        b.setReverting(true); // integration regression: debtOf() now reverts
        vm.warp(block.timestamp + 1);
        vm.expectRevert(); // fail-closed: the accumulator walk hits the broken view
        oracle.poke();
        oracle.setFarmUtilityLeg(address(0), address(0)); // the emergency lever
        vm.warp(block.timestamp + 1); // fresh dt so poke() genuinely walks the basket and books
        oracle.poke(); // liveness restored
        // eyes-open cost: BOTH loop legs leave the basket (escrow LP no longer counted, debt no longer
        // subtracted) -> gross understates by the loop equity until re-wired.
        assertEq(oracle.grossBasketValue(), 0, "loop legs out of the basket while unset");
    }

    /// @notice NAV-input setters checkpoint BEST-EFFORT before mutating: the elapsed gap is booked at the OLD
    ///         configuration's spot, so a re-point can't retroactively re-weight TWAP history at the new spot.
    ///         (The failure branch — a reverting basket walk skips the checkpoint instead of bricking the setter —
    ///         is exercised by test_farmUtility_unset_recovers_from_reverting_view.)
    function test_setters_checkpoint_before_repoint() public {
        _wireFullBasket(); // rateSrc = xa (1.2), spot = 1.174e18
        uint256 oldSpot = oracle.spotNavPerShare();
        uint256 cumBefore = oracle.cumNav();
        vm.warp(block.timestamp + 100); // stale accumulator gap
        MockXAlpha newRateSrc = new MockXAlpha();
        newRateSrc.setExchangeRate(24e17); // re-point DOUBLES the xALPHA leg's rate
        oracle.setXAlphaRateOracle(address(newRateSrc));
        // the 100s gap must be booked at the OLD spot (pre-re-point), not retroactively at the new one
        assertEq(oracle.lastUpdate(), uint32(block.timestamp), "checkpointed at setter time");
        assertEq(oracle.cumNav(), cumBefore + oldSpot * 100, "gap booked at OLD spot");
        assertGt(oracle.spotNavPerShare(), oldSpot, "new config live after the checkpoint");
    }

    function test_lpShareValue_pro_rata() public {
        _wireLp(); // 1000 supply, reserves 200 zip + 100 xAlpha, xAlphaUSD 2.4
        // 500/1000 -> 100 zip ($100) + 50 xAlpha*2.4 ($120) = 220e18
        assertEq(oracle.lpShareValue(500e18), 220e18);
        assertEq(oracle.lpShareValue(0), 0);
    }

    // ----------------------------------------------------------------- TWAP + bracket
    function test_twap_fallback_to_spot_before_W() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 1000e18); // spot = 1e18
        _pushBoth(1e18, 1e18);
        assertEq(oracle.twapNavPerShare(), oracle.spotNavPerShare());
    }

    function test_twap_windowed_and_bracket() public {
        uint256 T = block.timestamp;
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 1000e18); // spot = 1e18
        _pushBoth(1e18, 1e18); // legs fresh, dt=0 (no accumulate)

        vm.warp(T + 2 hours);
        oracle.poke(); // books spot 1e18 over 2h

        zip.setBalance(juniorTrancheSafe, 3000e18); // spot = 3e18
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
        zip.setBalance(juniorTrancheSafe, 1000e18);
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
        zip.setBalance(juniorTrancheSafe, 1000e18); // stable spot 1e18
        for (uint256 i = 0; i < 70; i++) {
            vm.warp(block.timestamp + 1 hours);
            oracle.poke();
        }
        // 70 successful accumulates from obsIndex 0 -> 70 % 65 = 5
        assertEq(oracle.obsIndex(), 5);
        // twap still computes (no revert) and is ~spot
        assertEq(oracle.twapNavPerShare(), 1e18);
    }

    /// @notice A poke BELOW obsSpacing advances the integral + refreshes the head in place, but does NOT consume
    ///         a new ring slot (the decoupling that bounds ring consumption — build/twap-ring.md).
    function test_poke_within_spacing_refreshes_head_no_advance() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 1000e18);
        vm.warp(block.timestamp + oracle.obsSpacing()); // first poke crosses obsSpacing -> one advance
        oracle.poke();
        uint16 idx = oracle.obsIndex();
        uint256 cum = oracle.cumNav();
        vm.warp(block.timestamp + 2); // dt>0 but < obsSpacing
        oracle.poke();
        assertEq(oracle.obsIndex(), idx, "no slot advance within obsSpacing");
        assertGt(oracle.cumNav(), cum, "integral still advances (time-weighting exact)");
    }

    /// @notice REGRESSION (twap-ring.md): permissionless poke()-spam must NOT collapse the TWAP window to spot.
    ///         Pre-fix, one slot per block meant ~CARDINALITY spam-pokes evicted all history older than a couple
    ///         minutes, dropping twap to spot and degenerating max/min(spot,twap) to spot (re-enabling a one-block
    ///         LP-mark manipulation). With obsSpacing the spam only refreshes the head; the frozen >= W of history
    ///         survives, so the bracket keeps biting.
    function test_twap_window_survives_poke_spam() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 1000e18); // spot = 1e18
        _pushBoth(1e18, 1e18);

        // Build >= W of history at spot 1e18 (one checkpoint per obsSpacing).
        uint32 spacing = oracle.obsSpacing();
        for (uint256 i = 0; i < 80; i++) {
            vm.warp(block.timestamp + spacing);
            oracle.poke();
        }
        assertApproxEqAbs(oracle.twapNavPerShare(), 1e18, 1e9, "twap anchored at history");
        uint16 idxBefore = oracle.obsIndex();

        // ATTACK: jump spot, then poke-spam in consecutive ~2s blocks (the eviction attempt).
        zip.setBalance(juniorTrancheSafe, 3000e18); // spot = 3e18 (manipulated)
        assertEq(oracle.spotNavPerShare(), 3e18);
        for (uint256 i = 0; i < 200; i++) {
            vm.warp(block.timestamp + 2);
            oracle.poke();
        }

        // 200 spam pokes over ~400s consume only ~1-2 slots (400s / obsSpacing), NOT 200 — the window is intact.
        uint256 advanced = (uint256(oracle.obsIndex()) + oracle.CARDINALITY() - idxBefore) % oracle.CARDINALITY();
        assertLe(advanced, 3, "spam consumed <= 3 slots, not one-per-block");
        // Decisive: twap did NOT collapse to the manipulated spot; the bracket still defends exit.
        assertLt(oracle.twapNavPerShare(), 12e17, "twap stays near history, not the 3e18 spike");
        assertLt(oracle.navExit(), oracle.spotNavPerShare(), "min(spot,twap) below spot -> no exit-rich");
    }

    // ----------------------------------------------------------------- staleness asymmetry
    function test_staleness_pauses_issuance_not_exit() public {
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        zip.setBalance(juniorTrancheSafe, 1000e18);
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
        zip.setBalance(juniorTrancheSafe, 1000e18);
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
        zip.setBalance(juniorTrancheSafe, 1000e18); // spot 1e18
        _pushBoth(1e18, 1e18);
        vm.warp(T + 5 hours);
        oracle.poke(); // establish a twap ~1e18 over the window

        // one-block UP spike (donation)
        zip.setBalance(juniorTrancheSafe, 2000e18); // spot jumps to 2e18 in this block, twap still ~1e18
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

    // ----------------------------------------------------------------- SEC-04: unseeded xALPHA rate fail-close (H5)
    /// @notice With the xALPHA exchange rate UNSEEDED (`exchangeRate() == 0`) but the protocol holding xALPHA, every
    ///         consumer that marks the xALPHA leg through `_xAlphaUSD()` must FAIL CLOSED (`RateUnseeded`) rather than
    ///         silently value the leg at 0. Pre-fix `_xAlphaUSD()` returned 0, so navExit underpaid exits and
    ///         grossBasketValue/valueOf under-read the basket — the H5 silent-zero. Fail-before/pass-after: pre-fix
    ///         these reads RETURN (a silently-underpriced value), so the `expectRevert`s here would fail.
    function test_SEC04_unseeded_rate_fails_closed() public {
        _wireFullBasket(); // seeds exchangeRate 1.2e18 + holds 10 xALPHA + pushes the alphaUSD leg
        xa.setExchangeRate(0); // genesis/unseeded rate (the CRE cross-chain rate before its first push)

        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        oracle.navExit(); // exit consumer
        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        oracle.grossBasketValue(); // freeze coverage + ExitGate tvlCap leg
        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        oracle.spotNavPerShare(); // navEntry/navExit share this
        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        oracle.valueOf(address(xa), 5e18); // the ExitGate issuance valuation seam
    }

    /// @notice With the rate SEEDED (>0) the same reads price the xALPHA leg correctly — the par baseline (identical
    ///         to `test_nav_composition_handcomputed` + `test_valueOf_xAlpha_two_layer_mark`).
    function test_SEC04_seeded_rate_prices_correctly() public {
        _wireFullBasket(); // exchangeRate 1.2e18, alphaUSD 2e18, 10 xALPHA -> xa leg = 10*1.2*2 = 24e18
        assertEq(oracle.grossBasketValue(), 1174e18);
        assertEq(oracle.valueOf(address(xa), 5e18), 12e18); // 5 * (1.2*2)
        oracle.navExit(); // no revert
    }

    /// @notice The fix gates ONLY on unseeded, NEVER on staleness — a SEEDED-but-stale rate/legs must keep the §7
    ///         max-entry/min-exit asymmetry: navExit prices off the last good mark (no revert) while navEntry pauses
    ///         issuance. Proves the fix did not collapse the asymmetry.
    function test_SEC04_asymmetry_preserved_when_stale() public {
        _wireFullBasket(); // rate seeded 1.2e18, legs fresh
        vm.warp(block.timestamp + MAX_AGE + 1); // legs go stale; the rate stays nonzero (seeded)
        oracle.navExit(); // exit still prices off the last good mark (NO revert)
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, uint8(0)));
        oracle.navEntry(); // issuance still pauses on stale legs
    }

    // ----------------------------------------------------------------- SEC-10: setLpTwapWindow(>0) plugin/init validation (L2)
    /// @dev Wire an LP whose pool/plugin readiness is configurable. Mirrors `_wireLp`: pool = zipUSD/xALPHA, 1000 LP
    ///      shares, but TWAP reserves come from the vault's IDLE token balances (L=0), so set the vault's token
    ///      balances to the same 200 zip / 100 xAlpha — the pro-rata mark is then identical to the spot path. The
    ///      held shares (500/1000 = half) give a non-zero `grossBasketValue()` so the TWAP-path read is asserted live.
    function _wireLpForTwap()
        internal
        returns (MockICHIVault iv, MockGauge g, MockAlgebraPool pool, MockAlgebraPlugin plugin)
    {
        iv = new MockICHIVault();
        g = new MockGauge();
        pool = new MockAlgebraPool();
        plugin = new MockAlgebraPlugin();
        // spot reserves 200 zip + 100 xAlpha; idle balances match so the TWAP reconstruction == spot reserves.
        iv.set(address(zip), address(xa), 1000e18, 200e18, 100e18);
        iv.setPool(address(pool));
        zip.setBalance(address(iv), 200e18); // idle token0 the fair-reserves reconstruction reads
        xa.setBalance(address(iv), 100e18); // idle token1
        oracle.setLpPosition(address(iv), address(g));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        xa.setExchangeRate(12e17);
        _pushBoth(2e18, 5e17); // xAlphaUSD = 1.2*2 = 2.4
        g.setBalance(juniorTrancheSafe, 500e18); // held 500/1000 = half
    }

    /// @notice No plugin: `ichiVault` points at a pool whose `plugin() == address(0)` → `setLpTwapWindow(3600)`
    ///         reverts `LpTwapPluginNotReady`. Pre-fix the setter succeeds and a subsequent `grossBasketValue()`
    ///         reverts (NAV bricked) — the fail-before evidence.
    function test_SEC10_no_plugin_reverts() public {
        (,, MockAlgebraPool pool,) = _wireLpForTwap();
        pool.setPlugin(address(0)); // pool exposes no TWAP plugin
        vm.expectRevert(SzipNavOracle.LpTwapPluginNotReady.selector);
        oracle.setLpTwapWindow(3600);
    }

    /// @notice Uninitialized plugin: plugin present but `isInitialized() == false` → setter reverts.
    function test_SEC10_uninitialized_plugin_reverts() public {
        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(false); // under-seeded plugin
        vm.expectRevert(SzipNavOracle.LpTwapPluginNotReady.selector);
        oracle.setLpTwapWindow(3600);
    }

    /// @notice Ready pool: plugin present + initialized → setter succeeds and `grossBasketValue()` reads through the
    ///         TWAP path (`_lpValue`→`fairReserves`) without reverting, returning the same non-zero mark as spot.
    function test_SEC10_ready_pool_succeeds_and_reads_twap() public {
        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(true);

        // spot-path baseline: 500/1000 -> 100 zip ($100) + 50 xAlpha*2.4 ($120) = 220e18.
        uint256 spotGross = oracle.grossBasketValue();
        assertEq(spotGross, 220e18, "spot-path baseline");

        oracle.setLpTwapWindow(3600); // succeeds
        assertEq(oracle.lpTwapWindow(), 3600);

        // now the LP leg reads through fairReserves (TWAP path); idle reserves == spot, so mark is unchanged + non-zero.
        uint256 twapGross = oracle.grossBasketValue();
        assertGt(twapGross, 0, "TWAP-path read is non-zero (did not brick)");
        assertEq(twapGross, spotGross, "TWAP reconstruction == spot reserves (idle balances match)");
    }

    /// @notice Escape always open: `setLpTwapWindow(0)` succeeds regardless of pool state (recovers a bricked NAV).
    function test_SEC10_escape_zero_always_succeeds() public {
        (,, MockAlgebraPool pool,) = _wireLpForTwap();
        pool.setPlugin(address(0)); // worst case: no plugin
        oracle.setLpTwapWindow(0); // must NOT revert
        assertEq(oracle.lpTwapWindow(), 0);

        // also succeeds before the LP is even wired (ichiVault could be 0 on a fresh oracle).
        SzipNavOracle freshOracle = new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx),
            address(ohydx), juniorTrancheSafe, juniorTrancheSidecar, W, MAX_AGE
        );
        freshOracle.setLpTwapWindow(0); // unconditionally valid
        assertEq(freshOracle.lpTwapWindow(), 0);
    }

    // ----------------------------------------------------------------- F8: LP-TWAP history halt gate + status probe
    /// @notice a plugin whose history is shorter than the armed window HALTS every LP-containing NAV read
    ///         with the typed `LpTwapHistoryTooShort(plugin, readyAt)` (not an opaque plugin revert), and the same
    ///         read passes UNAIDED once `block.timestamp` reaches `readyAt` — the self-healing, no-unpause shape.
    function test_F8_historyGate_halts_navReads_then_selfHeals() public {
        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(true);
        oracle.setLpTwapWindow(3600);

        // simulate a plugin swap: history restarts 30min ago ⇒ 1h window under-covered.
        uint32 oldest = uint32(block.timestamp) - 1800;
        plugin.setOldestTs(oldest);
        uint256 readyAt = uint256(oldest) + 3600;
        vm.expectRevert(
            abi.encodeWithSelector(IchiAlgebraFairReserves.LpTwapHistoryTooShort.selector, address(plugin), readyAt)
        );
        oracle.grossBasketValue();

        // ...and self-heals: at readyAt the identical read succeeds with no setter/unpause touched.
        vm.warp(readyAt);
        assertGt(oracle.grossBasketValue(), 0, "read resumes unaided at readyAt");
    }

    /// @notice `lpTwapStatus()` — the non-reverting probe CRE polls: ready when the TWAP is not in play
    ///         (window 0), (false, plugin, readyAt) while halted, ready again once history covers.
    function test_F8_lpTwapStatus_probe() public {
        // TWAP not in play: fresh wiring, window 0.
        (bool ready, address p, uint256 readyAt) = oracle.lpTwapStatus();
        assertTrue(ready, "window 0 => TWAP not in play => ready");
        assertEq(p, address(0));
        assertEq(readyAt, 0);

        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(true);
        oracle.setLpTwapWindow(3600);

        uint32 oldest = uint32(block.timestamp) - 600; // 10min of history ⇒ halted
        plugin.setOldestTs(oldest);
        (ready, p, readyAt) = oracle.lpTwapStatus();
        assertFalse(ready, "under-covered => not ready");
        assertEq(p, address(plugin), "status names the plugin");
        assertEq(readyAt, uint256(oldest) + 3600, "readyAt = oldest + window");

        vm.warp(readyAt);
        (ready,, ) = oracle.lpTwapStatus();
        assertTrue(ready, "covered again at readyAt");
    }

    /// @notice with a non-zero LP-TWAP window already live, re-pointing `setLpPosition` to a vault
    ///         whose pool exposes NO plugin must revert `LpTwapPluginNotReady` — NOT silently leave the live window
    ///         over a pluginless pool (which bricks every LP-containing NAV read, irrecoverable post-renounce).
    function test_SUPPLYADV15_setLpPosition_repoint_to_pluginless_reverts() public {
        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(true);
        oracle.setLpTwapWindow(3600); // window armed against a ready vault
        assertEq(oracle.lpTwapWindow(), 3600);

        // re-point to a vault whose pool has no plugin → the readiness invariant must be re-asserted on re-point.
        MockICHIVault ivBad = new MockICHIVault();
        MockGauge gBad = new MockGauge();
        MockAlgebraPool poolBad = new MockAlgebraPool();
        ivBad.set(address(zip), address(xa), 1000e18, 200e18, 100e18);
        ivBad.setPool(address(poolBad));
        poolBad.setPlugin(address(0));
        vm.expectRevert(SzipNavOracle.LpTwapPluginNotReady.selector);
        oracle.setLpPosition(address(ivBad), address(gBad));
    }

    /// @notice re-pointing to a DIFFERENT but equally-ready vault under a live window succeeds and
    ///         preserves the window (the re-validation passes; intent is kept, not silently zeroed).
    function test_SUPPLYADV15_setLpPosition_repoint_to_ready_vault_keeps_window() public {
        (,, MockAlgebraPool pool, MockAlgebraPlugin plugin) = _wireLpForTwap();
        pool.setPlugin(address(plugin));
        plugin.setInitialized(true);
        oracle.setLpTwapWindow(3600);

        MockICHIVault iv2 = new MockICHIVault();
        MockGauge g2 = new MockGauge();
        MockAlgebraPool pool2 = new MockAlgebraPool();
        MockAlgebraPlugin plugin2 = new MockAlgebraPlugin();
        iv2.set(address(zip), address(xa), 1000e18, 200e18, 100e18);
        iv2.setPool(address(pool2));
        pool2.setPlugin(address(plugin2));
        plugin2.setInitialized(true);
        oracle.setLpPosition(address(iv2), address(g2));
        assertEq(oracle.ichiVault(), address(iv2), "re-pointed to the ready vault");
        assertEq(oracle.lpTwapWindow(), 3600, "window preserved across a ready re-point");
    }

    // ----------------------------------------------------------------- I-15: setter auth + zero-guards (full sweep)
    /// @notice Every Timelock wiring setter is `onlyOwner` and zero-guards its non-optional args. The effect/re-point
    ///         of these is covered elsewhere; this closes the auth + zero-guard gap on the five setters whose gate was
    ///         previously only exercised for effect (`setFarmUtilityLeg`, `setLpTwapWindow`, `setXAlphaRateOracle`,
    ///         `setJuniorTrancheEngine`, `setDefaultCoordinator`).
    function test_setters_onlyOwner_and_zeroGuards() public {
        address rando = makeAddr("rando");
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");

        // --- onlyOwner gate (a non-owner cannot touch any setter) ---
        vm.startPrank(rando);
        vm.expectRevert();
        oracle.setFarmUtilityLeg(a1, a2);
        vm.expectRevert();
        oracle.setLpTwapWindow(0); // 0 is a VALID value, so this isolates the onlyOwner gate from the validation
        vm.expectRevert();
        oracle.setXAlphaRateOracle(a1);
        vm.expectRevert();
        oracle.setJuniorTrancheEngine(a1);
        vm.expectRevert();
        oracle.setDefaultCoordinator(a1);
        vm.stopPrank();

        // --- zero-guards (owner = this) ---
        // setFarmUtilityLeg: MIXED zero/non-zero is rejected (a half-wired leg counts escrow LP without its
        // debt, or vice versa); (0,0) is the valid ATOMIC UNSET — the recovery lever for a regressed
        // escrow/borrow-vault view that would otherwise freeze _accumulate() unrecoverably.
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        oracle.setFarmUtilityLeg(address(0), a2); // zero escrow only
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        oracle.setFarmUtilityLeg(a1, address(0)); // zero borrow only
        oracle.setFarmUtilityLeg(a1, a2);
        oracle.setFarmUtilityLeg(address(0), address(0)); // atomic unset — must NOT revert
        assertEq(oracle.escrowVault(), address(0));
        assertEq(oracle.borrowVault(), address(0));
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        oracle.setJuniorTrancheEngine(address(0));
        vm.expectRevert(SzipNavOracle.ZeroAddress.selector);
        oracle.setDefaultCoordinator(address(0));
        // setXAlphaRateOracle(0) is a VALID "unset / use fallback" value — must NOT revert for the owner.
        oracle.setXAlphaRateOracle(address(0));
        assertEq(oracle.xAlphaRateOracle(), address(0));
    }

    // ----------------------------------------------------------------- I-16: committedValue + freeValue == gross
    /// @notice For the five plain legs the per-Safe decomposition is EXACT: `committedValue() + freeValue()` equals
    ///         `grossBasketValue()` to the wei (no LP ⇒ no double-floor). This is the additive identity the freeze
    ///         module's coverage floor (`committedValue` + `pathLockedLpEquity`) relies on for double-count-freedom.
    function test_committed_plus_free_equals_gross_plainLegs() public {
        _wireFullBasket(); // zip on both Safes; usdc/xa/hydx/ohydx on the main Safe; no LP, no debt
        uint256 gross = oracle.grossBasketValue();
        assertEq(oracle.committedValue() + oracle.freeValue(), gross, "plain legs: decomposition is EXACT");
        // sanity: the split is non-trivial (the sidecar owns the 50e18 zip leg).
        assertEq(oracle.committedValue(), 50e18, "sidecar = its zip leg");
        assertEq(oracle.freeValue(), gross - 50e18, "main = the rest");
    }

    /// @notice For a SPLIT LP the per-Safe pro-rata floors twice vs once, so `committedValue+freeValue` lands
    ///         below `grossBasketValue`. Constructed to force the worst case AT AN xALPHA MARK OF EXACTLY $1.00:
    ///         supply 7e18, reserves 1e18/1e18, both legs priced exactly $1, and L_safe=L_sidecar=4e18 — each per-Safe
    ///         leg floors away 4/7 of a wei (×2 legs), and the two halves sum to exactly 2 wei below the combined floor.
    ///         NOTE — the 2 wei in this test's NAME is NOT the general bound; it is this construction's $1-pinned
    ///         value. The outer `_tokenValue` division (`amt * price / 1e18`) is lossless only at `price == 1e18`, so
    ///         off $1 the doubled inner floor is amplified: the general tolerance is `floor(px/1e18) + 4` wei for
    ///         `px = exchangeRate * alphaUSD / 1e18` (3 wei at $0.50, 4 at $1.20, 7 at $3.70, 101 at $100). The
    ///         price-aware bound is the one fuzzed in `SzipNavOracleInvariant.t.sol::invariant_decompositionAdditivity`;
    ///         this case stays deliberately pinned at $1 so the 2-wei figure is exact and deterministic.
    ///         The `sum <= gross` direction asserted below is likewise construction-specific — see that invariant's
    ///         docstring for the per-Safe-debt saturation case where it does not hold.
    function test_committed_plus_free_equals_gross_splitLp_within_2wei() public {
        MockICHIVault iv = new MockICHIVault();
        MockGauge g = new MockGauge();
        iv.set(address(zip), address(xa), 7e18, 1e18, 1e18); // supply 7e18, total0=total1=1e18
        oracle.setLpPosition(address(iv), address(g));
        oracle.setShareToken(address(szip));
        szip.setTotalSupply(1000e18);
        xa.setExchangeRate(1e18); // xAlpha price = exchangeRate × alphaUSD = 1 × 1 = $1
        _pushBoth(1e18, 1e18); // both LP legs (zip, xAlpha) at exactly $1 ⇒ a 1-wei amt floor == 1-wei USD

        g.setBalance(juniorTrancheSafe, 4e18); // free LP
        g.setBalance(juniorTrancheSidecar, 4e18); // committed LP (combined 8e18 of 7e18 supply)

        uint256 gross = oracle.grossBasketValue();
        uint256 sum = oracle.committedValue() + oracle.freeValue();
        assertLe(sum, gross, "per-Safe floors never over-count");
        assertApproxEqAbs(sum, gross, 2, "split-LP decomposition within <=2 wei");
        assertEq(gross - sum, 2, "the constructed worst case is exactly 2 wei (1 per LP reserve leg)");
    }
}

/// @notice Minimal stand-in for `SzAlphaRateOracle` — exposes `exchangeRate()` + `fresh()` for the gate test,
///         `lastUpdate()` for the SEC-13 `oldestRequiredLegTs()` rate-leg fold, and `maxStaleness()` for the
///         rate-window fence shift (defaults to unbounded so shift-free tests keep their plain-fold expectations).
contract MockRateOracle {
    uint256 public r;
    bool public f;
    uint48 public lu;
    uint256 public maxStaleness = type(uint256).max;

    function setRate(uint256 x) external {
        r = x;
    }

    function setMaxStaleness(uint256 x) external {
        maxStaleness = x;
    }

    function setFresh(bool x) external {
        f = x;
    }

    function setLastUpdate(uint48 x) external {
        lu = x;
    }

    function exchangeRate() external view returns (uint256) {
        return r;
    }

    function fresh() external view returns (bool) {
        return f;
    }

    function lastUpdate() external view returns (uint48) {
        return lu;
    }
}
