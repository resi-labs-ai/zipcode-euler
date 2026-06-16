// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

import {ZipcodeController} from "../src/ZipcodeController.sol";
import {EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol";
import {IZipcodeVenue} from "../src/venue/IZipcodeVenue.sol";
import {CREGatingHook} from "../src/CREGatingHook.sol";
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {LienTokenFactory} from "../src/LienTokenFactory.sol";
import {LienCollateralToken} from "../src/LienCollateralToken.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerEarn, MarketAllocation} from "euler-earn/interfaces/IEulerEarn.sol";
import {IERC4626 as IOZERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

/// @notice The seedPrice face, for vm.mockCall selector use in the reentrancy isolation test.
interface IZipcodeOracleRegistrySeed {
    function seedPrice(address lien, uint256 price) external;
}

/// @notice A zero-rate IRM so the close-path repay(debt) is exact (no interest accrual).
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A recording IEulerEarn mock that ACTUALLY supplies cash. On `reallocate([base, line])` it deposits the
///         line's incremental `amount` into the borrow vault (`USDC.approve; deposit(amount, mock)`) so the live
///         borrow has real cash — exactly what a real EulerEarn does as the market's lender. Pre-minted USDC in
///         setup. Records the two-item allocation args for the F-harness label.
contract MockEulerEarn {
    address public immutable usdc;
    IOZERC4626[] internal _queue;
    address[] public lastReallocIds;
    uint256[] public lastReallocAssets;
    uint256 public reallocCount;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    /// @dev SEC-08: openLine reads `eulerEarn.timelock()` as a precheck; 0 == immediate cap config (happy path).
    function timelock() external pure returns (uint256) {
        return 0;
    }

    function submitCap(IOZERC4626, uint256) external {}
    function acceptCap(IOZERC4626) external {}

    function setSupplyQueue(IOZERC4626[] calldata q) external {
        delete _queue;
        for (uint256 i; i < q.length; ++i) {
            _queue.push(q[i]);
        }
    }

    function supplyQueueLength() external view returns (uint256) {
        return _queue.length;
    }

    function supplyQueue(uint256 i) external view returns (IOZERC4626) {
        return _queue[i];
    }

    /// @dev MOCK-RECORDED allocation args; the actual deposit into the LINE vault (item 1) is the LIVE leg that
    ///      gives the borrow vault cash. We compute the incremental supply = target - current and deposit it.
    function reallocate(MarketAllocation[] calldata allocs) external {
        delete lastReallocIds;
        delete lastReallocAssets;
        for (uint256 i; i < allocs.length; ++i) {
            lastReallocIds.push(address(allocs[i].id));
            lastReallocAssets.push(allocs[i].assets);
        }
        reallocCount++;

        // item[1] is the line vault with the new ABSOLUTE target. Deposit the delta so cash() rises (LIVE).
        address lineVault = address(allocs[1].id);
        uint256 target = allocs[1].assets;
        uint256 current = IOZERC4626(lineVault).convertToAssets(IOZERC4626(lineVault).balanceOf(address(this)));
        if (target > current) {
            uint256 delta = target - current;
            IERC20(usdc).approve(lineVault, delta);
            IOZERC4626(lineVault).deposit(delta, address(this));
        }
    }
}

/// @notice A malicious venue that tries to re-enter the controller's onReport during openLine (F-10 proof).
contract ReentrantVenue is IZipcodeVenue {
    ZipcodeController public controller;
    bool public reentered;

    function setController(address c) external {
        controller = ZipcodeController(c);
    }

    function openLine(bytes32, address, uint256) external returns (address, address) {
        // Try to re-enter onReport — the controller's Forwarder gate must reject (callee != Forwarder).
        try controller.onReport("", abi.encode(uint8(1), bytes(""))) {
            reentered = true;
        } catch {
            reentered = false;
        }
        return (address(0xBEEF), address(0xBEEF));
    }

    function setLineLimits(address, uint16, uint16, uint256) external {}
    function fund(address, uint256) external {}
    function draw(address, uint256, address) external {}
    function observeDebt(address) external pure returns (uint256) {
        return 0;
    }
    function closeLine(address) external {}
    function liquidate(address) external {}
}

contract ZipcodeControllerTest is ForkConfig {
    // -- live Base deployments --
    IEVC internal evc;
    GenericFactory internal factory;
    address internal usdc;

    // -- fresh deploys --
    ZipcodeOracleRegistry internal registry;
    LienTokenFactory internal lienFactory;
    CREGatingHook internal hook;
    ZeroIRM internal irm;
    MockEulerEarn internal ee;
    EulerVenueAdapter internal adapter;
    ZipcodeController internal controller;
    address internal baseUsdcMarket;

    // EOAs
    address internal FORWARDER = makeAddr("forwarder");
    address internal CONTROLLER_OWNER; // = this test contract (the deployer of the controller)
    address internal EREBOR = makeAddr("erebor");

    bytes32 internal constant LIEN_ID = bytes32(uint256(0xA11CE));
    bytes32 internal constant LIEN_ID_2 = bytes32(uint256(0xB0B));
    bytes32 internal constant PROOF_REF = bytes32(uint256(0xDEAD));

    uint256 internal constant EQUITY_MARK = 200_000e6; // $200k
    uint16 internal constant BORROW_LTV = 0.8e4;
    uint16 internal constant LIQ_LTV = 0.85e4;
    uint256 internal constant DRAW_AMOUNT = 100_000e6; // well under 0.8 * $200k = $160k
    uint256 internal constant CAP = 1_000_000e6;

    // ----- registry/factory events (for expectEmit, declared locally) -----
    event LienCreated(bytes32 indexed lienId, address indexed lien);
    event RegistryPriceSeed(address indexed lien, uint256 price);
    event LienOriginated(
        bytes32 indexed lienId,
        address indexed lien,
        address lineRef,
        bytes32 proofRef,
        uint256 equityMark,
        uint256 drawAmount
    );
    event LienReleased(bytes32 indexed lienId);
    event LienDrawn(bytes32 indexed lienId, uint256 equityMark, uint256 drawAmount);
    event LienStatusUpdated(bytes32 indexed lienId, uint8 status);

    function setUp() public {
        _selectBaseFork();

        evc = IEVC(BaseAddresses.EVC);
        factory = GenericFactory(BaseAddresses.EVAULT_FACTORY);
        usdc = BaseAddresses.USDC;
        CONTROLLER_OWNER = address(this);

        registry = new ZipcodeOracleRegistry(FORWARDER, usdc, 365 days);
        lienFactory = new LienTokenFactory();

        irm = new ZeroIRM();
        ee = new MockEulerEarn(usdc);
        deal(usdc, address(ee), 100_000_000e6); // pre-mint the EE so it can supply real cash on reallocate

        // A live base USDC market (no-borrow holding vault).
        baseUsdcMarket = factory.createProxy(address(0), false, abi.encodePacked(usdc, address(0), address(0)));
        IEVault(baseUsdcMarket).setHookConfig(address(0), 0);
        IEVault(baseUsdcMarket).setGovernorAdmin(address(0));

        // Break the controller<->venue<->hook ctor cycle. Deploy order from this test contract:
        //   nonce n   : (CONTROLLER_OWNER deploys) hook
        //   nonce n+1 : controller   (needs venue = predicted adapter)
        //   nonce n+2 : adapter      (needs controller + hook)
        // So predict the adapter address at nonce n+2 and wire hook.borrowDriver + controller.venue to it.
        uint256 n = vm.getNonce(address(this));
        address predictedAdapter = vm.computeCreateAddress(address(this), n + 2);

        hook = new CREGatingHook(address(factory), address(evc), predictedAdapter); // nonce n
        controller = new ZipcodeController( // nonce n+1
            FORWARDER, predictedAdapter, address(lienFactory), address(registry), EREBOR
        );
        adapter = new EulerVenueAdapter( // nonce n+2
            address(controller),
            address(evc),
            address(ee),
            address(factory),
            address(registry),
            address(hook),
            address(irm),
            usdc,
            EREBOR,
            baseUsdcMarket
        );
        assertEq(address(adapter), predictedAdapter, "adapter address prediction must hold");
        assertEq(controller.venue(), address(adapter), "controller.venue == adapter");

        // Wire the registry's set-once seed authority to the controller.
        registry.setController(address(controller));

        // Seed the EE supply queue with the base market.
        IOZERC4626[] memory q = new IOZERC4626[](1);
        q[0] = IOZERC4626(baseUsdcMarket);
        ee.setSupplyQueue(q);

        // Pre-seed the base USDC market with an EE position so fund()'s `baseBalance - amount` withdraw leg has
        // balance (a §9/item-10 deploy concern; mirrors WOOF-04's _fundBaseMarket). The EE-as-lender deposits.
        vm.startPrank(address(ee));
        IERC20(usdc).approve(baseUsdcMarket, 50_000_000e6);
        IEVault(baseUsdcMarket).deposit(50_000_000e6, address(ee));
        vm.stopPrank();
    }

    // ---------- helpers ----------

    function _origReport(
        bytes32 lienId,
        uint256 equityMark,
        uint16 borrowLTV,
        uint16 liqLTV,
        uint256 drawAmount,
        uint256 cap
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(1), abi.encode(lienId, PROOF_REF, equityMark, borrowLTV, liqLTV, drawAmount, cap)
        );
    }

    function _drawReport(bytes32 lienId, uint256 equityMark, uint256 drawAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(2), abi.encode(lienId, PROOF_REF, equityMark, drawAmount));
    }

    function _closeReport(bytes32 lienId) internal pure returns (bytes memory) {
        return abi.encode(uint8(4), abi.encode(lienId));
    }

    function _originate(bytes32 lienId) internal {
        vm.prank(FORWARDER);
        controller.onReport("", _origReport(lienId, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));
    }

    function _borrowAccountOf(bytes32 lienId) internal view returns (address) {
        ZipcodeController.LienRecord memory r = controller.getLien(lienId);
        return adapter.getLine(r.lineRef).borrowAccount;
    }

    // ============================================================
    // (1) Live borrow with NO controller operator-wiring (the re-author proof)
    // ============================================================

    function test_LiveBorrow_NoControllerOperatorWiring() public {
        _originate(LIEN_ID);

        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        EulerVenueAdapter.Line memory L = adapter.getLine(r.lineRef);

        // Live debt was produced — the borrow succeeded with no controller EVC step.
        assertEq(IEVault(r.lineRef).debtOf(L.borrowAccount), DRAW_AMOUNT, "live debt produced");

        // The adapter (not the controller) is the line's EVC operator.
        assertTrue(
            evc.isAccountOperatorAuthorized(L.borrowAccount, address(adapter)),
            "adapter is the granted operator"
        );
        assertFalse(
            evc.isAccountOperatorAuthorized(L.borrowAccount, address(controller)),
            "controller is NOT an operator"
        );
    }

    // ============================================================
    // (2) Origination (audit L4) — the full transcript
    // ============================================================

    function test_Origination_L4_FullTranscript() public {
        // Predict the lien so we can assert events with the right emitter/topics.
        address predictedLien = lienFactory.computeAddress(LIEN_ID, address(controller));

        vm.prank(FORWARDER);
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));

        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        address LIEN_i = r.lien;
        EulerVenueAdapter.Line memory L = adapter.getLine(r.lineRef);

        assertEq(LIEN_i, predictedLien, "lien == computeAddress(lienId, controller)");
        assertEq(IERC20(LIEN_i).totalSupply(), 1e18, "totalSupply 1e18");
        assertEq(LienCollateralToken(LIEN_i).decimals(), 18, "decimals 18");
        assertEq(IERC20(LIEN_i).balanceOf(L.collateralVault), 1e18, "escrow holds exactly the full lien");

        assertEq(registry.getQuote(1e18, LIEN_i, usdc), EQUITY_MARK, "seed landed; getQuote == equityMark");

        assertEq(IEVault(r.lineRef).LTVBorrow(L.collateralVault), BORROW_LTV, "borrowLTV (1e4)");
        assertEq(IEVault(r.lineRef).LTVLiquidation(L.collateralVault), LIQ_LTV, "liqLTV (1e4)");

        assertEq(IEVault(r.lineRef).debtOf(L.borrowAccount), DRAW_AMOUNT, "debtOf == drawAmount");
        assertEq(IERC20(usdc).balanceOf(EREBOR), DRAW_AMOUNT, "erebor received drawAmount");

        assertEq(IERC20(LIEN_i).allowance(address(controller), address(adapter)), 0, "no standing allowance (F-7)");

        assertTrue(r.open, "record open");
    }

    function test_Origination_EmitsExpectedEvents() public {
        address predictedLien = lienFactory.computeAddress(LIEN_ID, address(controller));

        // LienCreated (factory) and RegistryPriceSeed (registry) and LienOriginated (controller) all fire.
        vm.expectEmit(true, true, false, false, address(lienFactory));
        emit LienCreated(LIEN_ID, predictedLien);
        vm.expectEmit(true, false, false, true, address(registry));
        emit RegistryPriceSeed(predictedLien, EQUITY_MARK);
        // lineRef unknown ahead of time -> check topics (lienId, lien) + don't match all data.
        vm.expectEmit(true, true, false, false, address(controller));
        emit LienOriginated(LIEN_ID, predictedLien, address(0), PROOF_REF, EQUITY_MARK, DRAW_AMOUNT);

        vm.prank(FORWARDER);
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));
    }

    // ============================================================
    // (3) Batch-atomicity — two revert points + no-orphan post-state
    // ============================================================

    function _assertNoOrphan(bytes32 lienId) internal {
        address predictedLien = lienFactory.computeAddress(lienId, address(controller));
        assertEq(predictedLien.code.length, 0, "no orphan lien token deployed");
        ZipcodeController.LienRecord memory r = controller.getLien(lienId);
        assertEq(r.lien, address(0), "no controller record");
        assertFalse(r.open, "record not open");
        // No orphan seed.
        vm.expectRevert();
        registry.getQuote(1e18, predictedLien, usdc);
    }

    function test_Atomicity_LateRevert_OverLTV() public {
        // drawAmount above borrowLTV * equityMark = 0.8 * $200k = $160k. The mock pre-funds cash so the failure is
        // the LTV account-status check, NOT E_InsufficientCash.
        uint256 overDraw = 170_000e6;
        vm.prank(FORWARDER);
        // Asserting the EXACT selector E_AccountLiquidity (NOT E_InsufficientCash) is the precondition guarantee
        // the ticket asks for: it proves the mock pre-funded the vault and the failure is the LTV account-status
        // check, not a cash shortfall (else N6/atomicity would pass for the wrong reason).
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, overDraw, CAP));
        _assertNoOrphan(LIEN_ID);
    }

    function test_Atomicity_MidBatchRevert_ZeroMark_RollsBackDeploys() public {
        // equityMark = 0 reverts at seedPrice (PriceOracle_InvalidAnswer), AFTER the lien token AND the LineAccount
        // CREATE2 deploys — proving both roll back (no orphan).
        vm.prank(FORWARDER);
        vm.expectRevert();
        controller.onReport("", _origReport(LIEN_ID, 0, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));
        _assertNoOrphan(LIEN_ID);

        // And the LineAccount CREATE2 slot is free: a real origination with the same lienId now succeeds.
        _originate(LIEN_ID);
        assertTrue(controller.getLien(LIEN_ID).open, "re-origination after rollback succeeds");
    }

    function test_Atomicity_CapOnlyBound() public {
        // drawAmount within LTV*mark ($160k headroom) but above a tiny cap -> E_BorrowCapExceeded (mark-independent).
        uint256 tinyCap = 50_000e6;
        uint256 draw = 100_000e6; // under LTV bound, over cap
        vm.prank(FORWARDER);
        vm.expectRevert(EVKErrors.E_BorrowCapExceeded.selector); // the real AmountCap ceiling, mark-independent
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, draw, tinyCap));
        _assertNoOrphan(LIEN_ID);
    }

    // ============================================================
    // (4) Draw branch (a') — exact accrual, re-anchor rollback, UnknownLien
    // ============================================================

    function test_Draw_ExactAccrual() public {
        _originate(LIEN_ID);
        address borrowAccount = _borrowAccountOf(LIEN_ID);
        uint256 d0 = IEVault(controller.getLien(LIEN_ID).lineRef).debtOf(borrowAccount);
        uint256 er0 = IERC20(usdc).balanceOf(EREBOR);

        uint256 draw2 = 30_000e6;
        // SEC-01: the draw re-anchors the mark via seedPrice; a separate CRE report lands in a later block (strictly-newer ts).
        vm.warp(block.timestamp + 1);
        vm.prank(FORWARDER);
        controller.onReport("", _drawReport(LIEN_ID, EQUITY_MARK, draw2));

        address lineRef = controller.getLien(LIEN_ID).lineRef;
        assertEq(IEVault(lineRef).debtOf(borrowAccount), d0 + draw2, "debt accrued exactly (zero-rate IRM)");
        assertEq(IERC20(usdc).balanceOf(EREBOR), er0 + draw2, "erebor received the additional draw");
    }

    function test_Draw_ReAnchorBelowLTV_RollsBack() public {
        _originate(LIEN_ID);
        address borrowAccount = _borrowAccountOf(LIEN_ID);
        address LIEN_i = controller.getLien(LIEN_ID).lien;
        address lineRef = controller.getLien(LIEN_ID).lineRef;

        uint256 priorQuote = registry.getQuote(1e18, LIEN_i, usdc);
        uint256 priorDebt = IEVault(lineRef).debtOf(borrowAccount);

        // Lower the mark so the existing + new debt blows the LTV. The re-anchor seed must roll back with the draw.
        uint256 lowMark = 110_000e6; // 0.8 * 110k = 88k < existing 100k debt
        // SEC-01: advance to a later block so the re-anchor seed clears the monotonic guard and the revert is the LTV check (not StaleReport).
        vm.warp(block.timestamp + 1);
        vm.prank(FORWARDER);
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        controller.onReport("", _drawReport(LIEN_ID, lowMark, 1e6));

        assertEq(registry.getQuote(1e18, LIEN_i, usdc), priorQuote, "re-anchor rolled back (prior mark intact)");
        assertEq(IEVault(lineRef).debtOf(borrowAccount), priorDebt, "debt unchanged");
    }

    function test_Draw_UnknownLien_Reverts() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnknownLien.selector, LIEN_ID));
        controller.onReport("", _drawReport(LIEN_ID, EQUITY_MARK, 1e6));
    }

    function test_Draw_OnClosedLine_Reverts() public {
        _originate(LIEN_ID);
        _repayAndClose(LIEN_ID);
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnknownLien.selector, LIEN_ID));
        controller.onReport("", _drawReport(LIEN_ID, EQUITY_MARK, 1e6));
    }

    // ============================================================
    // (5) Close branch (audit L7/L8)
    // ============================================================

    /// @dev Permissionless repay by a non-Forwarder EOA to zero the debt, then close.
    function _repay(bytes32 lienId) internal {
        ZipcodeController.LienRecord memory r = controller.getLien(lienId);
        address borrowAccount = adapter.getLine(r.lineRef).borrowAccount;
        uint256 debt = IEVault(r.lineRef).debtOf(borrowAccount);
        address repayer = makeAddr("permissionlessRepayer");
        deal(usdc, repayer, debt);
        vm.startPrank(repayer);
        IERC20(usdc).approve(r.lineRef, debt);
        IBorrowing(r.lineRef).repay(debt, borrowAccount);
        vm.stopPrank();
    }

    function _repayAndClose(bytes32 lienId) internal {
        _repay(lienId);
        vm.prank(FORWARDER);
        controller.onReport("", _closeReport(lienId));
    }

    function test_Close_L7L8_RepayThenRelease() public {
        _originate(LIEN_ID);
        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        address LIEN_i = r.lien;
        address collat = adapter.getLine(r.lineRef).collateralVault;

        // permissionless repay (non-Forwarder) zeroes the debt.
        _repay(LIEN_ID);
        assertEq(adapter.observeDebt(r.lineRef), 0, "debt zeroed permissionlessly");

        vm.expectEmit(true, false, false, false, address(controller));
        emit LienReleased(LIEN_ID);

        vm.prank(FORWARDER);
        controller.onReport("", _closeReport(LIEN_ID));

        assertEq(IERC20(LIEN_i).totalSupply(), 0, "lien burned");
        assertEq(IERC20(LIEN_i).balanceOf(collat), 0, "escrow drained");
        assertFalse(controller.getLien(LIEN_ID).open, "record closed");
    }

    function test_Close_RepayCannotAddDebt() public {
        // Security F-8: a permissionless caller can repay but cannot ADD debt (borrow is hook-gated to the adapter).
        _originate(LIEN_ID);
        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        address borrowAccount = adapter.getLine(r.lineRef).borrowAccount;
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        IBorrowing(r.lineRef).borrow(1e6, attacker);
        // (borrowAccount is unchanged.)
        assertEq(IEVault(r.lineRef).debtOf(borrowAccount), DRAW_AMOUNT, "debt unchanged by attacker borrow attempt");
    }

    function test_Close_DebtOutstanding_StateUnchanged() public {
        _originate(LIEN_ID);
        address LIEN_i = controller.getLien(LIEN_ID).lien;
        vm.prank(FORWARDER);
        vm.expectRevert(ZipcodeController.DebtOutstanding.selector);
        controller.onReport("", _closeReport(LIEN_ID));
        assertEq(IERC20(LIEN_i).totalSupply(), 1e18, "no burn");
        assertTrue(controller.getLien(LIEN_ID).open, "still open");
    }

    function test_Close_DoubleClose_Reverts() public {
        _originate(LIEN_ID);
        _repayAndClose(LIEN_ID);
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnknownLien.selector, LIEN_ID));
        controller.onReport("", _closeReport(LIEN_ID));
    }

    function test_Close_NeverOpened_Reverts() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnknownLien.selector, LIEN_ID));
        controller.onReport("", _closeReport(LIEN_ID));
    }

    function test_Close_BurnAfterReclaim_Sequencing() public {
        // With closeLine mocked to no-op (lien NOT reclaimed), burn(1e18) reverts ERC20InsufficientBalance:
        // pins the reclaim-before-burn dependency.
        _originate(LIEN_ID);
        _repay(LIEN_ID);
        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        // observeDebt must still read 0 so we reach closeLine -> burn.
        vm.mockCall(address(adapter), abi.encodeWithSelector(IZipcodeVenue.observeDebt.selector, r.lineRef), abi.encode(uint256(0)));
        vm.mockCall(address(adapter), abi.encodeWithSelector(IZipcodeVenue.closeLine.selector, r.lineRef), bytes(""));
        vm.prank(FORWARDER);
        vm.expectRevert(); // ERC20InsufficientBalance — controller holds 0 lien (still in escrow)
        controller.onReport("", _closeReport(LIEN_ID));
    }

    // ============================================================
    // (6) Dispatch + dup
    // ============================================================

    function test_Dispatch_ReportType3_Rejected() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(3)));
        controller.onReport("", abi.encode(uint8(3), bytes("")));
    }

    function test_Dispatch_ReportType0_Rejected() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(0)));
        controller.onReport("", abi.encode(uint8(0), bytes("")));
    }

    function test_Dispatch_ReportType7And255_Rejected() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(7)));
        controller.onReport("", abi.encode(uint8(7), bytes("")));
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(255)));
        controller.onReport("", abi.encode(uint8(255), bytes("")));
    }

    function test_Dispatch_TruncatedPayload_Reverts() public {
        // type-1 with an empty payload -> the inner abi.decode bounds-check reverts (fails closed, no zero-filled
        // origination).
        vm.prank(FORWARDER);
        vm.expectRevert();
        controller.onReport("", abi.encode(uint8(1), bytes("")));
    }

    function test_Dispatch_DuplicateOrigination_NoDoubleMint() public {
        _originate(LIEN_ID);
        address LIEN_i = controller.getLien(LIEN_ID).lien;
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.LienExists.selector, LIEN_ID));
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));
        assertEq(IERC20(LIEN_i).totalSupply(), 1e18, "no double-mint");
        assertTrue(controller.getLien(LIEN_ID).open, "first record intact");
    }

    // ============================================================
    // (7) Default/Liquidation markers (5/6 emit only LienStatusUpdated, no state change)
    // ============================================================

    function test_Markers_DefaultAndLiquidation_StatusOnly() public {
        _originate(LIEN_ID);
        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        address borrowAccount = adapter.getLine(r.lineRef).borrowAccount;
        uint256 debtBefore = IEVault(r.lineRef).debtOf(borrowAccount);

        // Any liquidate call would revert (it should not be reached).
        vm.mockCallRevert(address(adapter), abi.encodeWithSelector(IZipcodeVenue.liquidate.selector), "NOPE");

        vm.expectEmit(true, false, false, true, address(controller));
        emit LienStatusUpdated(LIEN_ID, 2);
        vm.prank(FORWARDER);
        controller.onReport("", abi.encode(uint8(5), abi.encode(LIEN_ID, uint8(2))));

        vm.expectEmit(true, false, false, true, address(controller));
        emit LienStatusUpdated(LIEN_ID, 3);
        vm.prank(FORWARDER);
        controller.onReport("", abi.encode(uint8(6), abi.encode(LIEN_ID, uint8(3))));

        assertTrue(controller.getLien(LIEN_ID).open, "open unchanged");
        assertEq(IEVault(r.lineRef).debtOf(borrowAccount), debtBefore, "debt unchanged");
    }

    // ============================================================
    // (8) Authority + dormant-gate
    // ============================================================

    function test_Authority_NonForwarder_Reverts() public {
        address bad = makeAddr("bad");
        vm.prank(bad);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, bad, FORWARDER));
        controller.onReport("", abi.encode(uint8(0), bytes("")));
    }

    function test_DormantGate_Demonstration() public {
        // Build packed metadata with a WRONG workflowId (abi.encodePacked: id@32, name@64, owner@74).
        bytes32 wrongId = bytes32(uint256(0xBAD1D));
        bytes10 wfName = bytes10(0);
        address wfOwner = address(0);
        bytes memory metadata = abi.encodePacked(wrongId, wfName, wfOwner);

        // (a) expectations UNSET -> the wrong-id report is ACCEPTED (dormant gate). Use type 3 so it reaches the
        //     dispatcher and reverts UnsupportedReportType(3) — i.e., it got PAST the identity gate.
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.UnsupportedReportType.selector, uint8(3)));
        controller.onReport(metadata, abi.encode(uint8(3), bytes("")));

        // (b) set the expected workflowId -> the same wrong-id report now reverts InvalidWorkflowId.
        bytes32 wid = bytes32(uint256(0xC0FFEE));
        controller.setExpectedWorkflowId(wid);
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidWorkflowId.selector, wrongId, wid));
        controller.onReport(metadata, abi.encode(uint8(3), bytes("")));
    }

    function test_PostRenounce_SettersRevert() public {
        controller.setExpectedWorkflowId(bytes32(uint256(0xC0FFEE)));
        controller.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        controller.setForwarderAddress(makeAddr("anything"));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        controller.setExpectedAuthor(makeAddr("anything"));
    }

    // ============================================================
    // (9) Reentrancy is structurally impossible (F-10)
    // ============================================================

    function test_Reentrancy_Impossible() public {
        // Stand up a fresh controller pointed at a malicious venue whose openLine re-enters onReport.
        ReentrantVenue rv = new ReentrantVenue();
        ZipcodeController c2 =
            new ZipcodeController(FORWARDER, address(rv), address(lienFactory), address(registry), EREBOR);
        rv.setController(address(c2));

        // c2 is not the registry's controller; mock seedPrice so the outer batch completes deterministically and we
        // isolate the reentrancy behavior (the lien token create is real and caller-bound to c2).
        vm.mockCall(address(registry), abi.encodeWithSelector(IZipcodeOracleRegistrySeed.seedPrice.selector), bytes(""));

        // Origination on c2 reaches rv.openLine, which tries to re-enter c2.onReport from rv (NOT the Forwarder).
        // The reentrant call must revert InvalidSender(rv, FORWARDER) -> the try/catch in rv records reentered=false.
        bytes32 lid = bytes32(uint256(0xFEED));
        vm.prank(FORWARDER);
        c2.onReport("", _origReport(lid, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));

        assertFalse(rv.reentered(), "reentrant onReport was rejected (Forwarder gate)");
    }
}
