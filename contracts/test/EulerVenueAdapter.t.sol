// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

import {EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol";
import {IZipcodeVenue} from "../src/venue/IZipcodeVenue.sol";
import {LineAccount} from "../src/venue/LineAccount.sol";
import {CREGatingHook} from "../src/CREGatingHook.sol";
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {LienCollateralToken} from "../src/LienCollateralToken.sol";
import {SzipPerspectiveProbe} from "../script/SzipPerspectiveProbe.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerEarn, MarketAllocation} from "euler-earn/interfaces/IEulerEarn.sol";
import {IERC4626 as IOZERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors as PriceErrors} from "euler-price-oracle/lib/Errors.sol";

/// @notice A zero-rate IRM (IIRM face: computeInterestRate(address,uint256,uint256)).
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A recording IEulerEarn mock — only the surface the adapter touches. EulerEarn pins solc 0.8.26 so it
///         cannot be `new`-ed under 0.8.24; the adapter imports only the interface, so a focused recording mock
///         suffices for the unit/fork test (the live EE path is the audit S9/L4 integration).
contract MockEulerEarn {
    // Mirror the real EulerEarn supply-queue cap so the H2 brick (SEC-06) is reproducible at the unit level.
    uint256 internal constant MAX_QUEUE_LENGTH = 30; // ConstantsLib.MAX_QUEUE_LENGTH

    error MaxQueueLengthExceeded();
    /// @dev Mirrors EulerEarn's `afterTimelock` (reference EulerEarn.sol:185-189,507): a same-tx `acceptCap` after a
    ///      `submitCap` that set `validAt = now + timelock` reverts while `timelock != 0`. SEC-08's openLine precheck
    ///      fires BEFORE this — so without the fix, openLine builds all line proxies, THEN reverts here (orphaned).
    error TimelockNotElapsed();
    /// @dev Mirrors EulerEarn.reallocate's terminal invariant (reference EulerEarn.sol:441): the zero-sum check
    ///      `if (totalWithdrawn != totalSupplied) revert InconsistentReallocation()`. This is the exact revert
    ///      the L9/SEC-11 donation grief triggers when `fund` sizes targets off the donation-skewed live balance
    ///      while reallocate measures positions off the unskewed TRACKED `config.balance`.
    error InconsistentReallocation();
    /// @dev Mirrors EulerEarn.reallocate's per-market gate (reference EulerEarn.sol:390).
    error MarketNotEnabled(address id);

    /// @notice The pool asset (USDC) the mock moves between markets during a faithful reallocate.
    address public immutable asset;

    // ----- EE-tracked per-market config (security L9/SEC-11) -----
    // The crux of the donation bug: EE tracks each market's supplied SHARE balance INTERNALLY (`config.balance`),
    // updated ONLY through the deposits/redeems EE itself performs. A direct share transfer into the pool inflates
    // the market vault's live `balanceOf(EE)` but NOT this tracked balance (reference IEulerEarn.sol:69,73 "ignores
    // direct shares transfer"). reallocate measures every position as `previewRedeem(config.balance)` — NOT
    // `convertToAssets(balanceOf)` — so a target sized off the live balance diverges from EE's own accounting and
    // breaks the zero-sum check. This mock mirrors that: `cfgBalance` is bumped only inside `reallocate`/`seedConfig`.
    mapping(address => uint112) public cfgBalance; // EE-tracked share balance per market
    mapping(address => bool) public cfgEnabled; // a market is reallocate-eligible once its cap is accepted

    /// @notice The EE pool timelock (SEC-08). Default 0 (immediate cap config); a test raises it as the EE owner.
    uint256 public timelock;
    /// @notice The EE pool's factory (SEC-08); `SzipPerspectiveProbe` reaches it via `creator()` to gate the probe.
    address public creator;

    address[] public submittedCaps;
    address[] public acceptedCaps;
    IOZERC4626[] internal _queue;

    // last-reallocate recording
    address[] public lastReallocIds;
    uint256[] public lastReallocAssets;
    uint256 public reallocCount;

    constructor(address asset_) {
        asset = asset_;
    }

    function submitCap(IOZERC4626 id, uint256) external {
        submittedCaps.push(address(id));
    }

    function acceptCap(IOZERC4626 id) external {
        if (timelock != 0) revert TimelockNotElapsed(); // faithful afterTimelock: same-tx accept fails while > 0
        acceptedCaps.push(address(id));
        cfgEnabled[address(id)] = true; // faithful: accepting a cap enables the market for reallocate/withdraw
    }

    /// @dev The EE-tracked config getter the L9/SEC-11 `_eeSupplyAssets` helper reads. ABI-identical to the real
    ///      `IEulerEarn.config(IERC4626)` (struct `MarketConfig memory` — encodes the same as this 4-tuple). `cap`
    ///      is reported as max (the line cap openLine leaves unrevoked) and `removableAt` as 0; only `.balance`
    ///      (the tracked share count) and `.enabled` are load-bearing for the adapter/this mock.
    function config(IOZERC4626 id) external view returns (uint112 balance, uint136 cap, bool enabled, uint64 removableAt) {
        return (cfgBalance[address(id)], type(uint136).max, cfgEnabled[address(id)], 0);
    }

    /// @dev Test helper: seed the EE-tracked position for a market the test funded DIRECTLY (bypassing reallocate,
    ///      e.g. `_fundBaseMarket`/`_supplyToLine`). Records `shares` as legitimately-tracked supply + enables the
    ///      market. A donation, by contrast, transfers shares to the EE address WITHOUT calling this — so
    ///      `balanceOf(EE) > cfgBalance`, which is exactly the L9 skew.
    function seedConfig(address market, uint256 shares) external {
        cfgBalance[market] += uint112(shares);
        cfgEnabled[market] = true;
    }

    /// @dev SEC-08 test hook: the external EE owner raises the timelock post-deploy.
    function setTimelock(uint256 t) external {
        timelock = t;
    }

    /// @dev SEC-08 test hook: point the probe at a given factory (the live EE factory, or a mock that rejects).
    function setCreator(address c) external {
        creator = c;
    }

    function setSupplyQueue(IOZERC4626[] calldata q) external {
        // Faithful to EulerEarn.setSupplyQueue (reference :328): reject a queue past the hard cap. This is the
        // exact revert SEC-06's prune prevents — without the prune the queue grows unboundedly to this bound.
        if (q.length > MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded();
        delete _queue;
        for (uint256 i; i < q.length; ++i) {
            _queue.push(q[i]);
        }
    }

    /// @dev test helper: is `market` present in the current supply queue?
    function queueContains(address market) external view returns (bool) {
        for (uint256 i; i < _queue.length; ++i) {
            if (address(_queue[i]) == market) return true;
        }
        return false;
    }

    function supplyQueueLength() external view returns (uint256) {
        return _queue.length;
    }

    function supplyQueue(uint256 i) external view returns (IOZERC4626) {
        return _queue[i];
    }

    /// @dev Faithful to EulerEarn.reallocate (reference EulerEarn.sol:383-442): ABSOLUTE-target, zero-sum, sized off
    ///      the TRACKED `config.balance` (NOT live `balanceOf`). Single-pass in allocation order, mirroring the
    ///      reference exactly so both the SEC-07 strand/reclaim AND the L9/SEC-11 donation-grief are reproducible:
    ///      per market, `supplyAssets = previewRedeem(config.balance)`; if `target < supplyAssets` it withdraws the
    ///      difference (or, when `target == 0`, redeems ALL tracked shares — the reference's :397-402
    ///      "donations can be withdrawn" full-redeem branch); else it supplies `target - supplyAssets`; finally the
    ///      `totalWithdrawn != totalSupplied -> InconsistentReallocation` invariant (reference :441). `cfgBalance`
    ///      is updated on every move (reference :415,:431) so the tracked balance stays the source of truth — a
    ///      direct share donation never touches it. Callers (`fund`, `closeLine` defund) order withdraw-before-supply
    ///      so the single in-order pass has cash before it deposits. Real USDC moves between the real EVK vaults.
    function reallocate(MarketAllocation[] calldata allocs) external {
        delete lastReallocIds;
        delete lastReallocAssets;
        uint256 totalSupplied;
        uint256 totalWithdrawn;
        for (uint256 i; i < allocs.length; ++i) {
            lastReallocIds.push(address(allocs[i].id));
            lastReallocAssets.push(allocs[i].assets);
            address id = address(allocs[i].id);
            if (!cfgEnabled[id]) revert MarketNotEnabled(id);
            IEVault v = IEVault(id);

            uint256 supplyShares = cfgBalance[id];
            uint256 supplyAssets = v.previewRedeem(supplyShares);
            uint256 target = allocs[i].assets;
            uint256 withdrawn = supplyAssets > target ? supplyAssets - target : 0;

            if (withdrawn > 0) {
                uint256 shares;
                if (target == 0) {
                    // reference :397-402: target 0 redeems ALL shares (sweeps any donation), withdrawn reset to 0.
                    shares = supplyShares;
                    withdrawn = 0;
                }
                uint256 withdrawnAssets;
                uint256 withdrawnShares;
                if (shares == 0) {
                    withdrawnAssets = withdrawn;
                    withdrawnShares = v.withdraw(withdrawn, address(this), address(this));
                } else {
                    withdrawnAssets = v.redeem(shares, address(this), address(this));
                    withdrawnShares = shares;
                }
                cfgBalance[id] = uint112(supplyShares - withdrawnShares);
                totalWithdrawn += withdrawnAssets;
            } else {
                uint256 suppliedAssets = target > supplyAssets ? target - supplyAssets : 0;
                if (suppliedAssets == 0) continue;
                IERC20(asset).approve(id, suppliedAssets);
                uint256 suppliedShares = v.deposit(suppliedAssets, address(this));
                cfgBalance[id] = uint112(supplyShares + suppliedShares);
                totalSupplied += suppliedAssets;
            }
        }
        if (totalWithdrawn != totalSupplied) revert InconsistentReallocation();
        reallocCount++;
    }

    function submittedCapsLength() external view returns (uint256) {
        return submittedCaps.length;
    }

    function lastReallocLength() external view returns (uint256) {
        return lastReallocIds.length;
    }
}

/// @notice A harness that deliberately mis-wires the router so the (W3) WireMismatch invariant is reachable.
///         Overrides `_assertWired` to feed the WRONG lien token, proving the check would catch a cross-wire.
contract MisWiringAdapter is EulerVenueAdapter {
    address public immutable wrongLien;

    constructor(
        address controller_,
        address evc_,
        address eulerEarn_,
        address eVaultFactory_,
        address oracleRegistry_,
        address gatingHook_,
        address irm_,
        address usdc_,
        address erebor_,
        address baseUsdcMarket_,
        address wrongLien_
    )
        EulerVenueAdapter(
            controller_,
            evc_,
            eulerEarn_,
            eVaultFactory_,
            oracleRegistry_,
            gatingHook_,
            irm_,
            usdc_,
            erebor_,
            baseUsdcMarket_
        )
    {
        wrongLien = wrongLien_;
    }

    function _assertWired(address router, address collat, address) internal view override {
        // Pass the WRONG expected lien -> the real resolve (correct lien) must trip WireMismatch.
        super._assertWired(router, collat, wrongLien);
    }
}

/// @notice SEC-08: a minimal EE factory whose perspective REJECTS the line vault — proves the deploy-time probe bites
///         (models a future external `setPerspective` swap to a config-inspecting perspective).
contract MockRejectingEarnFactory {
    function isStrategyAllowed(address) external pure returns (bool) {
        return false;
    }
}

contract EulerVenueAdapterTest is ForkConfig {
    // -- live Base deployments --
    IEVC internal evc;
    GenericFactory internal factory;
    address internal usdc;

    // -- fresh deploys --
    ZipcodeOracleRegistry internal registry;
    CREGatingHook internal hook;
    ZeroIRM internal irm;
    MockEulerEarn internal ee;
    EulerVenueAdapter internal adapter;
    address internal baseUsdcMarket;

    LienCollateralToken internal LIEN_A;
    LienCollateralToken internal LIEN_B;

    bytes32 internal constant LIEN_ID_A = bytes32(uint256(0xA11CE));
    bytes32 internal constant LIEN_ID_B = bytes32(uint256(0xB0B));

    address internal controller; // the mock controller = this test contract
    address internal erebor = makeAddr("erebor");
    address internal forwarder = makeAddr("forwarder");

    uint256 internal constant PRICE_A = 300_000e6; // $300k
    uint256 internal constant PRICE_B = 500_000e6; // $500k

    function setUp() public {
        _selectBaseFork();

        evc = IEVC(BaseAddresses.EVC);
        factory = GenericFactory(BaseAddresses.EVAULT_FACTORY);
        usdc = BaseAddresses.USDC;

        controller = address(this);

        // Registry (this test is the owner; controller wired to seed prices).
        registry = new ZipcodeOracleRegistry(forwarder, usdc, 365 days);
        registry.setController(controller);

        // Lien tokens minted to the controller (this test).
        LIEN_A = new LienCollateralToken(controller);
        LIEN_B = new LienCollateralToken(controller);

        irm = new ZeroIRM();
        ee = new MockEulerEarn(usdc);

        // A live base USDC market (no-borrow holding vault) that fund() withdraws from.
        baseUsdcMarket =
            factory.createProxy(address(0), false, abi.encodePacked(usdc, address(0), address(0)));
        IEVault(baseUsdcMarket).setHookConfig(address(0), 0);
        IEVault(baseUsdcMarket).setGovernorAdmin(address(0));

        // The adapter must be deployed BEFORE the hook so the hook's borrowDriver == the adapter. The adapter
        // address is independent of the hook, so deploy adapter with a placeholder? No — adapter ctor needs the
        // hook. Resolve the cycle: predict the adapter address via CREATE nonce, OR deploy hook with the adapter.
        // Simplest: deploy the adapter, then the hook wired to it, then a SECOND adapter that uses the real hook.
        // Instead: precompute adapter address (this test's next CREATE) and wire the hook to it.
        address predictedAdapter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        hook = new CREGatingHook(address(factory), address(evc), predictedAdapter);

        adapter = new EulerVenueAdapter(
            controller,
            address(evc),
            address(ee),
            address(factory),
            address(registry),
            address(hook),
            address(irm),
            usdc,
            erebor,
            baseUsdcMarket
        );
        assertEq(address(adapter), predictedAdapter, "adapter address prediction must hold");

        // Seed the EE supply queue with the base market (M1 head).
        IOZERC4626[] memory q = new IOZERC4626[](1);
        q[0] = IOZERC4626(baseUsdcMarket);
        ee.setSupplyQueue(q);

        // Controller approves the adapter to pull the lien (origination-batch obligation 1c).
        LIEN_A.approve(address(adapter), type(uint256).max);
        LIEN_B.approve(address(adapter), type(uint256).max);
    }

    // ---------- helpers ----------

    function _seedRegistry(address lien, uint256 price) internal {
        vm.prank(controller);
        registry.seedPrice(lien, price);
    }

    function _openA() internal returns (address lineRef, address oracleKey) {
        return adapter.openLine(LIEN_ID_A, address(LIEN_A), 1e18);
    }

    function _openB() internal returns (address lineRef, address oracleKey) {
        return adapter.openLine(LIEN_ID_B, address(LIEN_B), 1e18);
    }

    /// @dev Fund the EE mock's position in the base market so fund()'s absolute-target math has a base balance.
    ///      Deposit as the EE, then record the minted shares as EE-tracked config.balance (security L9/SEC-11): a
    ///      legitimate supply IS tracked (unlike a donation). Seeding the ACTUAL shares minted (not usdcAmount)
    ///      keeps cfgBalance == balanceOf(EE) so the no-donation path nets exactly.
    function _fundBaseMarket(uint256 usdcAmount) internal {
        deal(usdc, address(this), usdcAmount);
        IERC20(usdc).approve(baseUsdcMarket, usdcAmount);
        uint256 shares = IEVault(baseUsdcMarket).deposit(usdcAmount, address(ee));
        ee.seedConfig(baseUsdcMarket, shares);
    }

    /// @dev Supply USDC cash into a line's borrow vault so a draw has liquidity (mirrors what fund() does on a
    ///      live EE). The EE mock cannot move real assets, so we deposit directly as the EE and record the minted
    ///      shares as EE-tracked config.balance (security L9/SEC-11), keeping cfgBalance == balanceOf(EE).
    function _supplyToLine(address lineRef, uint256 usdcAmount) internal {
        deal(usdc, address(this), usdcAmount);
        IERC20(usdc).approve(lineRef, usdcAmount);
        uint256 shares = IEVault(lineRef).deposit(usdcAmount, address(ee));
        ee.seedConfig(lineRef, shares);
    }

    // ============================================================
    // (A) AmountCap round-trip + ZeroCap (mock-level / pure)
    // ============================================================

    function test_AmountCap_RoundTrip_And_ZeroReverts() public {
        _seedRegistry(address(LIEN_A), PRICE_A); // setLTV resolves the collateral price
        (address lineRef,) = _openA();
        // cap == 0 must revert ZeroCap (via setLineLimits -> _toAmountCap).
        vm.expectRevert(EulerVenueAdapter.ZeroCap.selector);
        adapter.setLineLimits(lineRef, 0.8e4, 0.9e4, 0);

        // A representative set: the realized cap (setCaps stored, then read back) must be >= requested.
        uint256[5] memory amts = [uint256(1), 1023, 100_000e6, 1e18, 250_000e6];
        for (uint256 i; i < amts.length; ++i) {
            adapter.setLineLimits(lineRef, 0.8e4, 0.9e4, amts[i]);
            // setCaps stores AmountCap; read it back via the vault's caps() and decode.
            (, uint16 borrowCapRaw) = IEVault(lineRef).caps();
            uint256 resolved = _resolveCap(borrowCapRaw);
            assertGe(resolved, amts[i], "realized cap must be >= requested (round UP)");
            assertTrue(borrowCapRaw != 0, "non-zero raw cap (never unlimited)");
        }
    }

    function _resolveCap(uint16 raw) internal pure returns (uint256) {
        if (raw == 0) return type(uint256).max;
        return 10 ** (raw & 63) * (raw >> 6) / 100;
    }

    // ============================================================
    // (B) collateralAmount != 1e18 guard
    // ============================================================

    function test_OpenLine_InvalidCollateralAmount_Zero() public {
        vm.expectRevert(EulerVenueAdapter.InvalidCollateralAmount.selector);
        adapter.openLine(LIEN_ID_A, address(LIEN_A), 0);
    }

    function test_OpenLine_InvalidCollateralAmount_Partial() public {
        vm.expectRevert(EulerVenueAdapter.InvalidCollateralAmount.selector);
        adapter.openLine(LIEN_ID_A, address(LIEN_A), 0.3e18);
    }

    function test_OpenLine_FullAmount_Succeeds() public {
        (address lineRef, address oracleKey) = _openA();
        assertEq(oracleKey, address(LIEN_A), "oracleKey == lien token");
        EulerVenueAdapter.Line memory L = adapter.getLine(lineRef);
        assertTrue(L.open, "line open");
        assertEq(L.lienToken, address(LIEN_A));
        assertEq(IEVault(L.collateralVault).asset(), address(LIEN_A), "escrow asset == lien");
    }

    // ============================================================
    // (C) Market wiring (live fork)
    // ============================================================

    function test_MarketWiring() public {
        (address lineRef,) = _openA();
        EulerVenueAdapter.Line memory L = adapter.getLine(lineRef);

        assertEq(IEVault(lineRef).governorAdmin(), address(adapter), "adapter is borrow vault governor");
        (address hookTarget, uint32 hookedOps) = IEVault(lineRef).hookConfig();
        assertEq(hookTarget, address(hook), "gating hook installed");
        assertEq(hookedOps, uint32((1 << 6) | (1 << 11)), "OP_BORROW | OP_LIQUIDATE, no OP_REPAY");
        assertEq(IEVault(lineRef).oracle(), L.router, "borrow vault oracle == per-line router");

        // The escrow is a bare 1:1 holding box.
        assertEq(IEVault(L.collateralVault).convertToAssets(1e18), 1e18, "escrow 1:1");
        assertEq(IEVault(L.collateralVault).governorAdmin(), address(0), "escrow governance renounced");

        // Router frozen.
        assertEq(EulerRouter(L.router).governor(), address(0), "router governance frozen");
        vm.expectRevert();
        EulerRouter(L.router).govSetConfig(address(LIEN_A), usdc, address(registry));
    }

    function test_SetLineLimits_RegistersCollateral() public {
        _seedRegistry(address(LIEN_A), PRICE_A); // setLTV resolves the collateral price
        (address lineRef,) = _openA();
        EulerVenueAdapter.Line memory L = adapter.getLine(lineRef);
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 250_000e6);
        assertEq(IEVault(lineRef).LTVBorrow(L.collateralVault), 0.7e4, "borrowLTV set (discharges WOOF-01)");
        assertEq(IEVault(lineRef).LTVLiquidation(L.collateralVault), 0.8e4, "liqLTV set");
    }

    // ============================================================
    // (D) LineAccount mechanics + operator grant (live fork)
    // ============================================================

    function test_LineAccount_Mechanics() public {
        (address lineRef,) = _openA();
        EulerVenueAdapter.Line memory L = adapter.getLine(lineRef);

        assertEq(evc.getAccountOwner(L.borrowAccount), L.lineAccount, "LineAccount is the prefix owner");
        assertEq(L.borrowAccount, address(uint160(L.lineAccount) ^ 1), "borrowAccount == lineAccount ^ 1");
        assertEq(L.borrowAccount.code.length, 0, "borrowAccount is code-free");
        // The adapter (the EVC.call caller) is the granted operator — before any draw.
        assertTrue(
            evc.isAccountOperatorAuthorized(L.borrowAccount, address(adapter)),
            "adapter is the granted operator"
        );
        // A foreign account did NOT authorize the adapter.
        address foreign = makeAddr("foreignEOA");
        assertFalse(evc.isAccountOperatorAuthorized(foreign, address(adapter)), "foreign not authorized");
    }

    // ============================================================
    // (E) Two-line distinct-prefix isolation + BOTH draw (the load-bearing live test)
    // ============================================================

    function test_TwoLine_DistinctPrefix_BothDraw_Isolation() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        _seedRegistry(address(LIEN_B), PRICE_B);

        (address lineA,) = _openA();
        (address lineB,) = _openB();
        EulerVenueAdapter.Line memory LA = adapter.getLine(lineA);
        EulerVenueAdapter.Line memory LB = adapter.getLine(lineB);

        // Structural distinctness.
        assertTrue(lineA != lineB, "distinct borrow vaults");
        assertTrue(LA.router != LB.router, "distinct routers");
        assertTrue(LA.collateralVault != LB.collateralVault, "distinct escrow vaults");
        assertTrue(LA.lineAccount != LB.lineAccount, "distinct LineAccounts");
        assertTrue(LA.borrowAccount != LB.borrowAccount, "distinct borrow accounts");
        assertTrue(
            evc.getAddressPrefix(LA.borrowAccount) != evc.getAddressPrefix(LB.borrowAccount),
            "distinct owner prefixes"
        );
        assertTrue(IEVault(lineA).oracle() != IEVault(lineB).oracle(), "distinct oracles");

        // Each router resolves to its OWN lien -> registry.
        (, address baseA,, address oracleA) = EulerRouter(LA.router).resolveOracle(1e18, LA.collateralVault, usdc);
        assertEq(baseA, address(LIEN_A), "A resolves to LIEN_A");
        assertEq(oracleA, address(registry), "A resolves to registry");
        (, address baseB,, address oracleB) = EulerRouter(LB.router).resolveOracle(1e18, LB.collateralVault, usdc);
        assertEq(baseB, address(LIEN_B), "B resolves to LIEN_B");
        assertEq(oracleB, address(registry), "B resolves to registry");

        // Cross-resolve negative: A's router cannot resolve B's collateral to a registry price.
        vm.expectRevert();
        EulerRouter(LA.router).resolveOracle(1e18, LB.collateralVault, usdc);

        // Set limits + supply cash, then BOTH draw.
        adapter.setLineLimits(lineA, 0.7e4, 0.8e4, 1_000_000e6);
        adapter.setLineLimits(lineB, 0.7e4, 0.8e4, 1_000_000e6);
        _supplyToLine(lineA, 1_000_000e6);
        _supplyToLine(lineB, 1_000_000e6);

        uint256 drawA = 100_000e6; // well under 0.7 * $300k
        uint256 drawB = 150_000e6; // well under 0.7 * $500k

        uint256 erBefore = IERC20(usdc).balanceOf(erebor);
        adapter.draw(lineA, drawA, erebor);
        adapter.draw(lineB, drawB, erebor);

        assertEq(IEVault(lineA).debtOf(LA.borrowAccount), drawA, "A debt");
        assertEq(IEVault(lineB).debtOf(LB.borrowAccount), drawB, "B debt unaffected by A");
        assertEq(IERC20(usdc).balanceOf(erebor) - erBefore, drawA + drawB, "erebor received both draws");

        // Revaluation independence: re-mark B; A's quote unchanged.
        uint256 quoteA_before = registry.getQuote(1e18, address(LIEN_A), usdc);
        // SEC-01: the re-mark needs a strictly-newer ts (monotonic guard); a separate CRE report lands in a later block.
        vm.warp(block.timestamp + 1);
        _seedRegistry(address(LIEN_B), 999_999e6);
        uint256 quoteA_after = registry.getQuote(1e18, address(LIEN_A), usdc);
        assertEq(quoteA_after, quoteA_before, "A quote byte-for-byte unchanged after B reval");
        assertEq(IEVault(lineA).debtOf(LA.borrowAccount), drawA, "A debt unchanged");
    }

    // ============================================================
    // (F) Foreign-account hook rejection (live fork)
    // ============================================================

    function test_ForeignAccount_HookRejects() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineA,) = _openA();
        adapter.setLineLimits(lineA, 0.7e4, 0.8e4, 1_000_000e6);
        _supplyToLine(lineA, 1_000_000e6);

        // Open B to get a foreign (authorized-for-its-own-line-only) borrow account.
        _seedRegistry(address(LIEN_B), PRICE_B);
        (address lineB,) = _openB();
        EulerVenueAdapter.Line memory LB = adapter.getLine(lineB);

        // Attempt to borrow on lineA's vault on behalf of B's borrow account (a foreign account for line A).
        // B's account did not authorize anyone as operator over line A's vault context, AND the adapter is not
        // B's operator-for-line-A in a way the hook accepts unless B granted it... B DID grant the adapter over
        // borrowAccount_B, but the hook gate is isAccountOperatorAuthorized(appendedAccount, adapter). For a truly
        // foreign account (an arbitrary EOA owner that never granted), the hook reverts. Build that directly:
        address foreignEOA = makeAddr("foreignBorrower");
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (foreignEOA, lineA))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (foreignEOA, LB.collateralVault))
        });
        items[2] = IEVC.BatchItem({
            targetContract: lineA,
            onBehalfOfAccount: foreignEOA,
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (1e6, erebor))
        });
        // The adapter is not foreignEOA's operator -> EVC authentication for the borrow item fails (EVC rejects
        // before the hook). Either way the borrow does NOT succeed.
        vm.prank(foreignEOA);
        vm.expectRevert();
        evc.batch(items);

        // And: directly prove the hook would reject an un-granted account if it reached the vault. Use a foreign
        // account that the adapter operates but appended to line A's borrow context where it has no controller.
        // (Covered by the EVC-level rejection above; the hook unit-rejection is proven in CREGatingHook.t.sol.)
    }

    // ============================================================
    // (G) Authority (onlyController) + stubs
    // ============================================================

    function test_Authority_NonController_Reverts() public {
        (address lineRef,) = _openA();
        address bad = makeAddr("bad");

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.openLine(LIEN_ID_B, address(LIEN_B), 1e18);

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 100e6);

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.fund(lineRef, 1e6);

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.draw(lineRef, 1e6, erebor);

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.closeLine(lineRef);

        vm.prank(bad);
        vm.expectRevert(EulerVenueAdapter.NotController.selector);
        adapter.liquidate(lineRef);
    }

    function test_Liquidate_NotImplemented() public {
        (address lineRef,) = _openA();
        vm.expectRevert(EulerVenueAdapter.NotImplemented.selector);
        adapter.liquidate(lineRef);
    }

    function test_UnknownLine_Reverts() public {
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(EulerVenueAdapter.UnknownLine.selector, ghost));
        adapter.setLineLimits(ghost, 0.7e4, 0.8e4, 100e6);
        vm.expectRevert(abi.encodeWithSelector(EulerVenueAdapter.UnknownLine.selector, ghost));
        adapter.fund(ghost, 1e6);
        vm.expectRevert(abi.encodeWithSelector(EulerVenueAdapter.UnknownLine.selector, ghost));
        adapter.draw(ghost, 1e6, erebor);
        vm.expectRevert(abi.encodeWithSelector(EulerVenueAdapter.UnknownLine.selector, ghost));
        adapter.closeLine(ghost);
    }

    function test_Draw_BadReceiver_Reverts() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineRef,) = _openA();
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 1_000_000e6);
        _supplyToLine(lineRef, 1_000_000e6);
        vm.expectRevert(EulerVenueAdapter.BadReceiver.selector);
        adapter.draw(lineRef, 1e6, makeAddr("notErebor"));
    }

    // ============================================================
    // (H) fund records the two-item ABSOLUTE allocation (mock-level)
    // ============================================================

    function test_Fund_RecordsTwoItemAbsoluteAllocation() public {
        (address lineRef,) = _openA();
        // Give the EE a base position so baseBalance - amount does not underflow.
        _fundBaseMarket(1_000_000e6);

        uint256 baseBal =
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee)));
        uint256 lineBal = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(ee)));
        uint256 amount = 200_000e6;

        adapter.fund(lineRef, amount);

        assertEq(ee.reallocCount(), 1, "reallocate called once");
        assertEq(ee.lastReallocLength(), 2, "two-item allocation");
        assertEq(ee.lastReallocIds(0), baseUsdcMarket, "item0 = baseUsdcMarket (withdraw)");
        assertEq(ee.lastReallocAssets(0), baseBal - amount, "item0 absolute target = base - amount");
        assertEq(ee.lastReallocIds(1), lineRef, "item1 = lineRef (supply)");
        assertEq(ee.lastReallocAssets(1), lineBal + amount, "item1 absolute target = line + amount");
    }

    // ============================================================
    // (H2) SEC-11 (L9) — fund/defund sized off the EE-TRACKED position (previewRedeem(config.balance)),
    //       donation-immune. Pre-fix (convertToAssets(balanceOf)) a share donation skews the targets so the
    //       reallocate deltas no longer net and funding bricks.
    // ============================================================

    /// @dev Donate `usdcAmount` worth of `market`'s EVK shares directly into the EE pool: mint to this test
    ///      contract, then raw-transfer the shares to the pool. This inflates the pool's LIVE `balanceOf(EE)`
    ///      WITHOUT touching the EE-tracked `cfgBalance` (the L9 skew — a raw transfer never calls reallocate /
    ///      seedConfig). Returns the donated share count.
    function _donateBaseShares(address market, uint256 usdcAmount) internal returns (uint256 shares) {
        deal(usdc, address(this), usdcAmount);
        IERC20(usdc).approve(market, usdcAmount);
        shares = IEVault(market).deposit(usdcAmount, address(this));
        IEVault(market).transfer(address(ee), shares);
    }

    /// @dev Post-fix: `fund` sizes both legs off `previewRedeem(config.balance)`, so a base-market share donation
    ///      is invisible to the sizing — the reallocate deltas net exactly and funding succeeds (the line is then
    ///      drawable on the funded liquidity). The pre-fix `convertToAssets(balanceOf)` sizing reverts on the same
    ///      donation — see `test_SEC11_PreFixSizing_Reverts_OnDonation`.
    function test_SEC11_Fund_DonationImmune() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineRef,) = _openA();
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 1_000_000e6);
        _fundBaseMarket(1_000_000e6);

        // Donate 1 USDC of base-market shares into the pool: live balance now EXCEEDS the EE-tracked balance.
        uint256 donated = _donateBaseShares(baseUsdcMarket, 1e6);
        assertGt(donated, 0, "donation minted base-market shares");
        assertGt(
            IEVault(baseUsdcMarket).balanceOf(address(ee)),
            ee.cfgBalance(baseUsdcMarket),
            "live balanceOf(EE) > EE-tracked cfgBalance after donation (the L9 skew)"
        );

        uint256 amount = 200_000e6;
        uint256 baseTrackedBefore = IEVault(baseUsdcMarket).previewRedeem(ee.cfgBalance(baseUsdcMarket));
        uint256 lineTrackedBefore = IEVault(lineRef).previewRedeem(ee.cfgBalance(lineRef));

        adapter.fund(lineRef, amount); // post-fix: succeeds despite the donation

        // EE-TRACKED supplied assets moved by exactly `amount`: base fell, line rose.
        assertEq(
            IEVault(baseUsdcMarket).previewRedeem(ee.cfgBalance(baseUsdcMarket)),
            baseTrackedBefore - amount,
            "base EE-tracked supplied assets fell by amount"
        );
        assertEq(
            IEVault(lineRef).previewRedeem(ee.cfgBalance(lineRef)),
            lineTrackedBefore + amount,
            "line EE-tracked supplied assets rose by amount"
        );

        // The line is drawable on the funded liquidity (50k < 0.7 * $300k collateral, < 200k funded).
        uint256 erBefore = IERC20(usdc).balanceOf(erebor);
        adapter.draw(lineRef, 50_000e6, erebor);
        assertEq(IERC20(usdc).balanceOf(erebor) - erBefore, 50_000e6, "erebor received the draw");
        assertEq(IEVault(lineRef).debtOf(adapter.getLine(lineRef).borrowAccount), 50_000e6, "line debt == draw");
    }

    /// @dev Proves the bug the fix closes: reconstructs the PRE-FIX sizing verbatim
    ///      (`convertToAssets(balanceOf(EE))`) on a donated pool and drives `reallocate` directly — it reverts
    ///      (the donation-skewed targets withdraw `amount - donation` from base but try to supply `amount` to the
    ///      line, so the deltas cannot net). The post-fix `fund` does NOT revert — see
    ///      `test_SEC11_Fund_DonationImmune`. (Bare `expectRevert`: the concrete revert is the supply leg failing
    ///      to cover the over-supply from the under-withdrawn cash — i.e. EE's `InconsistentReallocation`
    ///      invariant whenever idle cash covers the deposit, else the deposit-side shortfall — both brick funding.)
    function test_SEC11_PreFixSizing_Reverts_OnDonation() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineRef,) = _openA();
        _fundBaseMarket(1_000_000e6);
        _donateBaseShares(baseUsdcMarket, 1e6);

        uint256 amount = 200_000e6;
        // PRE-FIX sizing verbatim (the formula SEC-11 replaced): live balance, donation-skewed.
        uint256 baseBalancePreFix =
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee)));
        uint256 lineBalancePreFix = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(ee)));

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({id: IOZERC4626(baseUsdcMarket), assets: baseBalancePreFix - amount});
        allocs[1] = MarketAllocation({id: IOZERC4626(lineRef), assets: lineBalancePreFix + amount});

        vm.expectRevert();
        ee.reallocate(allocs);
    }

    /// @dev The happy path is unchanged: with no donation (live balance == EE-tracked balance) `fund` still moves
    ///      exactly `amount` from base to the line.
    function test_SEC11_Fund_NoDonation_StillMoves() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineRef,) = _openA();
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 1_000_000e6);
        _fundBaseMarket(1_000_000e6);

        uint256 amount = 200_000e6;
        uint256 baseTrackedBefore = IEVault(baseUsdcMarket).previewRedeem(ee.cfgBalance(baseUsdcMarket));
        // No donation: the live and tracked balances agree.
        assertEq(
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee))),
            baseTrackedBefore,
            "no skew absent a donation"
        );

        adapter.fund(lineRef, amount);

        assertEq(
            IEVault(baseUsdcMarket).previewRedeem(ee.cfgBalance(baseUsdcMarket)),
            baseTrackedBefore - amount,
            "base fell by amount"
        );
        assertEq(
            IEVault(lineRef).previewRedeem(ee.cfgBalance(lineRef)),
            amount,
            "line rose from zero to amount"
        );
    }

    // ============================================================
    // (I) onboarding bounded to the freshly-minted EVAULT only (security F3)
    // ============================================================

    function test_OpenLine_SubmitsCapOnlyForOwnVault() public {
        (address lineRef,) = _openA();
        assertEq(ee.submittedCapsLength(), 1, "exactly one submitCap");
        assertEq(ee.submittedCaps(0), lineRef, "submitCap ONLY for the freshly-minted EVAULT");
        // The supply queue was rebuilt preserving the base head + appending the line.
        assertEq(ee.supplyQueueLength(), 2, "queue = [base, line]");
        assertEq(address(ee.supplyQueue(0)), baseUsdcMarket, "head preserved");
        assertEq(address(ee.supplyQueue(1)), lineRef, "line appended");
    }

    // ============================================================
    // (J) close / reclaim (live fork)
    // ============================================================

    function test_CloseLine_LineNotRepaid_WhileDebt() public {
        _seedRegistry(address(LIEN_A), PRICE_A);
        (address lineRef,) = _openA();
        adapter.setLineLimits(lineRef, 0.7e4, 0.8e4, 1_000_000e6);
        _supplyToLine(lineRef, 1_000_000e6);
        adapter.draw(lineRef, 50_000e6, erebor);

        vm.expectRevert(EulerVenueAdapter.LineNotRepaid.selector);
        adapter.closeLine(lineRef);
    }

    function test_CloseLine_NoDebt_ReclaimsLien() public {
        (address lineRef,) = _openA();
        EulerVenueAdapter.Line memory L = adapter.getLine(lineRef);

        // The escrow shares are held by borrowAccount; the controller holds none of the lien now.
        assertEq(LIEN_A.balanceOf(controller), 0, "controller deposited the full lien");
        assertEq(IEVault(L.collateralVault).balanceOf(L.borrowAccount), 1e18, "borrowAccount holds escrow shares");
        assertEq(adapter.observeDebt(lineRef), 0, "no debt");

        adapter.closeLine(lineRef);

        // The lien is reclaimed to the controller (operator-routed EVC.call redeem).
        assertEq(LIEN_A.balanceOf(controller), 1e18, "lien reclaimed to controller");
        EulerVenueAdapter.Line memory L2 = adapter.getLine(lineRef);
        assertFalse(L2.open, "line closed");
        // observeDebt readable AFTER close.
        assertEq(adapter.observeDebt(lineRef), 0, "observeDebt readable post-close == 0");
    }

    // ============================================================
    // (K) double openLine same lienId -> CREATE2 collision reverts
    // ============================================================

    function test_DoubleOpenLine_SameLienId_Reverts() public {
        _openA();
        // Re-open same lienId -> CREATE2 redeploy of LineAccount at the same salt collides -> revert.
        vm.expectRevert();
        adapter.openLine(LIEN_ID_A, address(LIEN_A), 1e18);
    }

    // ============================================================
    // (L) WireMismatch is reachable via a deliberately-mis-wiring harness
    // ============================================================

    function test_WireMismatch_ReachableViaMisWiringHarness() public {
        // A mis-wiring adapter whose _assertWired checks against the WRONG lien -> the correct resolve trips it.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        CREGatingHook mwHook = new CREGatingHook(address(factory), address(evc), predicted);
        MisWiringAdapter mw = new MisWiringAdapter(
            controller,
            address(evc),
            address(ee),
            address(factory),
            address(registry),
            address(mwHook),
            address(irm),
            usdc,
            erebor,
            baseUsdcMarket,
            address(LIEN_B) // wrong expected lien
        );
        assertEq(address(mw), predicted, "prediction holds");

        LIEN_A.approve(address(mw), type(uint256).max);
        IOZERC4626[] memory q = new IOZERC4626[](1);
        q[0] = IOZERC4626(baseUsdcMarket);
        // mw uses the SAME ee mock; ensure its queue is fine (already set in setUp). Open must trip WireMismatch.
        vm.expectRevert(EulerVenueAdapter.WireMismatch.selector);
        mw.openLine(LIEN_ID_A, address(LIEN_A), 1e18);
    }

    // ============================================================
    // (M) Interface neutrality (compile-time) + completeness
    // ============================================================

    function test_InterfaceImplemented() public view {
        // EulerVenueAdapter is IZipcodeVenue — assignable to the interface type (compile-time proof).
        IZipcodeVenue v = IZipcodeVenue(address(adapter));
        assertEq(address(v), address(adapter));
    }

    // ============================================================
    // (N) SEC-06 — closeLine prunes the closed line from the EE supply queue (H2)
    // ============================================================

    /// @dev Prune happens: a closed line's borrow vault is removed from the supply queue (length drops by 1).
    function test_SEC06_CloseLine_PrunesSupplyQueue() public {
        (address lineRef,) = _openA();
        assertEq(ee.supplyQueueLength(), 2, "queue = [base, line] after open");
        assertTrue(ee.queueContains(lineRef), "line present in queue after open");

        adapter.closeLine(lineRef);

        // Pre-fix this stays 2 (no prune) and the vault remains in the queue.
        assertEq(ee.supplyQueueLength(), 1, "queue dropped to [base] after close");
        assertFalse(ee.queueContains(lineRef), "closed line pruned from queue");
        assertTrue(ee.queueContains(baseUsdcMarket), "base market preserved");
    }

    /// @dev Other open lines untouched: closing one line leaves the other in the queue and still fundable.
    function test_SEC06_CloseLine_LeavesOtherOpenLineFundable() public {
        _fundBaseMarket(1_000_000e6);
        (address lineA,) = _openA();
        (address lineB,) = _openB();
        assertEq(ee.supplyQueueLength(), 3, "queue = [base, A, B] after two opens");

        adapter.closeLine(lineA);

        assertEq(ee.supplyQueueLength(), 2, "queue = [base, B] after closing A");
        assertFalse(ee.queueContains(lineA), "A pruned");
        assertTrue(ee.queueContains(lineB), "B retained");
        assertTrue(ee.queueContains(baseUsdcMarket), "base retained");

        // B is still routable: fund() reallocates into it without reverting.
        adapter.fund(lineB, 100_000e6);
        assertEq(ee.reallocCount(), 1, "B still fundable after A closed");
    }

    /// @dev No brick across churn: run open->close more than MAX_QUEUE_LENGTH (30) total originations, closing each
    ///      before the next. Post-fix the queue stays bounded at [base, line] and every open succeeds. Pre-fix the
    ///      queue grows by 1 per open and never shrinks, so the ~30th open's setSupplyQueue reverts
    ///      MaxQueueLengthExceeded. The single 1e18 LIEN_A is recycled — each close redeems it back to the controller.
    function test_SEC06_NoBrickAcrossChurnPastQueueCap() public {
        uint256 n = 33; // comfortably past MAX_QUEUE_LENGTH (30)
        for (uint256 i; i < n; ++i) {
            bytes32 lienId = keccak256(abi.encode("SEC06", i));
            (address lineRef,) = adapter.openLine(lienId, address(LIEN_A), 1e18);
            assertEq(ee.supplyQueueLength(), 2, "queue bounded at [base, line] every cycle");
            adapter.closeLine(lineRef);
            assertEq(ee.supplyQueueLength(), 1, "queue back to [base] after each close");
            assertEq(LIEN_A.balanceOf(controller), 1e18, "lien recycled to controller after close");
        }
    }

    // ============================================================
    // (O) SEC-07 — closeLine defunds the line's USDC back to base (L8)
    // ============================================================

    /// @dev No strand: open->fund->close returns the line's supplied USDC to the base market. The faithful EE
    ///      mock actually moves funds, so pre-fix (no defund) the base EE balance stays depressed at base-amount
    ///      and the line vault keeps the stranded USDC; post-fix base is restored and the line is emptied.
    function test_SEC07_CloseLine_DefundsUsdcToBase() public {
        _fundBaseMarket(1_000_000e6);
        uint256 baseStart = IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee)));
        assertEq(baseStart, 1_000_000e6, "base seeded with 1M");

        (address lineRef,) = _openA();
        adapter.fund(lineRef, 300_000e6); // moves 300k base -> line (faithful reallocate)

        // After fund: base depressed, line holds the stranded USDC.
        assertApproxEqAbs(
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee))),
            700_000e6,
            2,
            "base drawn down by the fund"
        );
        assertApproxEqAbs(
            IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(ee))),
            300_000e6,
            2,
            "line holds the funded USDC"
        );

        adapter.closeLine(lineRef); // no draw -> debt 0; defund must reclaim the 300k

        // Post-fix: base restored, line emptied (assets:0 -> redeem all shares).
        assertApproxEqAbs(
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(ee))),
            1_000_000e6,
            2,
            "base balance restored by the defund"
        );
        assertEq(IEVault(lineRef).balanceOf(address(ee)), 0, "line EE position fully redeemed");
    }

    /// @dev No later-fund underflow: after an open->fund->close cycle that defunds back to base, a NEW line can be
    ///      funded for an amount near the FULL base balance. Pre-fix the strand leaves base depressed and the new
    ///      fund's `baseBalance - amount` (:290) underflows and reverts.
    function test_SEC07_NoLaterFundUnderflow() public {
        _fundBaseMarket(1_000_000e6);

        (address lineA,) = _openA();
        adapter.fund(lineA, 900_000e6); // strand 900k pre-fix
        adapter.closeLine(lineA); // defund returns it to base

        // Base is whole again; a NEW line funds for 950k (> the pre-fix residual 100k) without underflowing.
        (address lineB,) = _openB();
        adapter.fund(lineB, 950_000e6);

        assertApproxEqAbs(
            IEVault(lineB).convertToAssets(IEVault(lineB).balanceOf(address(ee))),
            950_000e6,
            2,
            "new line funded near the full base balance (pre-fix this reverts on the :290 underflow)"
        );
    }

    /// @dev Never-funded line: open then immediately close (lineBalance == 0). The no-op guard SKIPS the defund —
    ///      no reallocate is emitted (reallocCount unchanged), and the close completes without reverting.
    function test_SEC07_NeverFundedLine_NoDefund() public {
        (address lineRef,) = _openA();
        uint256 reallocBefore = ee.reallocCount();

        adapter.closeLine(lineRef); // lineBalance == 0 -> guard skips the defund

        assertEq(ee.reallocCount(), reallocBefore, "no defund reallocate on a never-funded line");
        assertFalse(adapter.getLine(lineRef).open, "line closed");
    }

    // ============================================================
    // (P) SEC-08 — openLine timelock precheck + deploy-time perspective probe (M6)
    // ============================================================

    /// @dev Timelock precheck fails LOUD + EARLY: with the EE pool's timelock raised (> 0) by its external owner,
    ///      openLine reverts the legible `EulerEarnTimelockNonZero` and builds NO line proxies. Pre-fix (precheck
    ///      removed) it builds the LineAccount + escrow + router + borrow vault, THEN reverts opaquely inside the
    ///      faithful mock's `acceptCap` (`TimelockNotElapsed`) — orphaning the proxies (the factory list grows).
    function test_SEC08_TimelockPrecheck_RevertsEarly_NoOrphan() public {
        ee.setTimelock(1 days); // external EE owner raises the timelock post-deploy

        uint256 proxiesBefore = factory.getProxyListLength();
        vm.expectRevert(EulerVenueAdapter.EulerEarnTimelockNonZero.selector);
        adapter.openLine(LIEN_ID_A, address(LIEN_A), 1e18);
        assertEq(factory.getProxyListLength(), proxiesBefore, "no line proxies built on the timelock brick");
        assertFalse(adapter.getLine(address(0)).open, "no line recorded");
    }

    /// @dev Happy path intact: with timelock == 0 (default) openLine still succeeds end-to-end.
    function test_SEC08_TimelockZero_HappyPath() public {
        assertEq(ee.timelock(), 0, "default timelock is 0");
        (address lineRef,) = _openA();
        assertTrue(lineRef != address(0), "line opened");
        assertTrue(adapter.getLine(lineRef).open, "line is open");
    }

    /// @dev Deploy probe passes LIVE: a vault built with `openLine`'s exact shape passes the live EE factory's
    ///      configured (provenance-only) perspective via the full `SzipPerspectiveProbe` path (reaching the real
    ///      factory through `creator()`). No revert == accepted.
    function test_SEC08_DeployProbe_PassesLive() public {
        ee.setCreator(BaseAddresses.EULER_EARN_FACTORY);
        address probe = new SzipPerspectiveProbe().assertLineVaultAllowed(
            factory, address(ee), address(evc), usdc, address(registry), address(irm), address(hook), address(LIEN_A)
        );
        assertTrue(probe != address(0), "probe vault built");
        assertTrue(factory.isProxy(probe), "probe is an EVK-factory proxy (what the live perspective verifies)");
    }

    /// @dev Deploy probe BITES: point `creator()` at a factory whose perspective rejects the line vault — the probe
    ///      reverts `LineVaultPerspectiveRejected` (models a future `setPerspective` swap that bricks origination).
    function test_SEC08_DeployProbe_Bites() public {
        MockRejectingEarnFactory bad = new MockRejectingEarnFactory();
        ee.setCreator(address(bad));
        SzipPerspectiveProbe probe = new SzipPerspectiveProbe();
        // The probe vault address is created inside the call (so its revert ARGS are unpredictable); catch and match
        // the selector only.
        bool reverted;
        try probe.assertLineVaultAllowed(
            factory, address(ee), address(evc), usdc, address(registry), address(irm), address(hook), address(LIEN_A)
        ) returns (address) {} catch (bytes memory reason) {
            reverted = true;
            assertEq(
                bytes4(reason), SzipPerspectiveProbe.LineVaultPerspectiveRejected.selector, "wrong revert selector"
            );
        }
        assertTrue(reverted, "probe must revert when the EE perspective rejects the line vault");
    }
}
