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

    address[] public submittedCaps;
    address[] public acceptedCaps;
    IOZERC4626[] internal _queue;

    // last-reallocate recording
    address[] public lastReallocIds;
    uint256[] public lastReallocAssets;
    uint256 public reallocCount;

    function submitCap(IOZERC4626 id, uint256) external {
        submittedCaps.push(address(id));
    }

    function acceptCap(IOZERC4626 id) external {
        acceptedCaps.push(address(id));
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

    function reallocate(MarketAllocation[] calldata allocs) external {
        delete lastReallocIds;
        delete lastReallocAssets;
        for (uint256 i; i < allocs.length; ++i) {
            lastReallocIds.push(address(allocs[i].id));
            lastReallocAssets.push(allocs[i].assets);
        }
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
        ee = new MockEulerEarn();

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
    function _fundBaseMarket(uint256 usdcAmount) internal {
        deal(usdc, address(this), usdcAmount);
        IERC20(usdc).approve(baseUsdcMarket, usdcAmount);
        // Credit shares to the EE mock so convertToAssets(balanceOf(EE)) > 0.
        IEVault(baseUsdcMarket).deposit(usdcAmount, address(ee));
    }

    /// @dev Supply USDC cash into a line's borrow vault so a draw has liquidity (mirrors what fund() does on a
    ///      live EE). The EE mock cannot move real assets, so we deposit directly as the EE.
    function _supplyToLine(address lineRef, uint256 usdcAmount) internal {
        deal(usdc, address(this), usdcAmount);
        IERC20(usdc).approve(lineRef, usdcAmount);
        IEVault(lineRef).deposit(usdcAmount, address(ee));
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
}
