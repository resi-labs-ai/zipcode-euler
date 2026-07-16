// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

import {ZipcodeController} from "../src/ZipcodeController.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";
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
import {Errors as PriceErrors} from "euler-price-oracle/lib/Errors.sol";

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

    // CTR-04: per-market cap (the withdraw-queue removal guard reads it; openLine submits type(uint136).max, and
    // closeLine's submitCap(0) clears it before the prune).
    mapping(address => uint136) public cfgCap;
    // CTR-04: the BINDING withdraw queue — pushed once on a market's first acceptCap, pruned by closeLine's
    // updateWithdrawQueue. Independent of the supply queue (`_queue`).
    IOZERC4626[] internal _withdrawQueue;

    /// @dev CTR-04: withdraw-queue removal guards (faithful to EulerEarn.updateWithdrawQueue :362,:366).
    error InvalidMarketRemovalNonZeroCap(address id);
    error InvalidMarketRemovalNonZeroSupply(address id);

    constructor(address usdc_) {
        usdc = usdc_;
    }

    /// @dev SEC-08: openLine reads `eulerEarn.timelock()` as a precheck; 0 == immediate cap config (happy path).
    function timelock() external pure returns (uint256) {
        return 0;
    }

    /// @dev CTR-04: record the per-market cap. A decrease (incl. ->0, closeLine's revoke) is IMMEDIATE; the
    ///      withdraw-queue removal guard requires this to be 0 before a market drops.
    function submitCap(IOZERC4626 id, uint256 cap) external {
        cfgCap[address(id)] = uint136(cap);
    }

    /// @dev CTR-04: on a market's FIRST enable push it onto the WITHDRAW queue (a contains-guard prevents a
    ///      re-accept from double-pushing) — faithful to _setCap's first-enable push.
    function acceptCap(IOZERC4626 id) external {
        for (uint256 i; i < _withdrawQueue.length; ++i) {
            if (address(_withdrawQueue[i]) == address(id)) return; // already enabled -> no re-push
        }
        _withdrawQueue.push(id);
    }

    /// @dev SEC-11 (L9): `fund`/`closeLine` now size off the EE-tracked `previewRedeem(config.balance)`. This
    ///      controller-integration mock has NO donation path (no raw share transfers into the pool), so the tracked
    ///      balance is exactly the live share balance — return `balanceOf(this)` so the production sizing is
    ///      byte-identical to the prior `convertToAssets(balanceOf)`. The donation DIVERGENCE that SEC-11 fixes is
    ///      exercised against the faithful mock in `EulerVenueAdapter.t.sol`, not here. ABI-identical to the real
    ///      `IEulerEarn.config(IERC4626)` struct getter (4-tuple encodes the same as `MarketConfig memory`).
    function config(IOZERC4626 id) external view returns (uint112 balance, uint136 cap, bool enabled, uint64 removableAt) {
        return (uint112(IOZERC4626(address(id)).balanceOf(address(this))), type(uint136).max, true, 0);
    }

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

    // ----- CTR-04: withdraw-queue surface (the BINDING queue closeLine reclaims) -----

    function withdrawQueueLength() external view returns (uint256) {
        return _withdrawQueue.length;
    }

    function withdrawQueue(uint256 i) external view returns (IOZERC4626) {
        return _withdrawQueue[i];
    }

    /// @dev test helper: is `market` present in the current withdraw queue?
    function withdrawQueueContains(address market) external view returns (bool) {
        for (uint256 i; i < _withdrawQueue.length; ++i) {
            if (address(_withdrawQueue[i]) == market) return true;
        }
        return false;
    }

    /// @dev CTR-04: KEEP-index semantics (faithful to EulerVenueAdapter.t.sol's mock / EulerEarn.updateWithdrawQueue
    ///      :340-380). The caller passes the indexes to RETAIN; every current index NOT listed is removed. A removed
    ///      market must have cfgCap == 0 (else InvalidMarketRemovalNonZeroCap) and be empty
    ///      (previewRedeem(balanceOf(this)) == 0, else InvalidMarketRemovalNonZeroSupply). cfgCap is cleared on
    ///      removal; the queue is rebuilt from the kept indexes.
    function updateWithdrawQueue(uint256[] calldata indexes) external {
        uint256 currLength = _withdrawQueue.length;
        bool[] memory seen = new bool[](currLength);
        IOZERC4626[] memory newQueue = new IOZERC4626[](indexes.length);

        for (uint256 i; i < indexes.length; ++i) {
            uint256 prevIndex = indexes[i]; // out-of-bounds reverts natively, like the reference
            newQueue[i] = _withdrawQueue[prevIndex];
            seen[prevIndex] = true;
        }

        for (uint256 i; i < currLength; ++i) {
            if (!seen[i]) {
                address id = address(_withdrawQueue[i]);
                if (cfgCap[id] != 0) revert InvalidMarketRemovalNonZeroCap(id);
                // This mock has no donation path, so live balanceOf == EE-tracked balance (the defund above
                // emptied the line). previewRedeem(balanceOf) == 0 confirms the market is empty.
                if (IEVault(id).previewRedeem(IEVault(id).balanceOf(address(this))) != 0) {
                    revert InvalidMarketRemovalNonZeroSupply(id);
                }
                cfgCap[id] = 0;
            }
        }

        delete _withdrawQueue;
        for (uint256 i; i < newQueue.length; ++i) {
            _withdrawQueue.push(newQueue[i]);
        }
    }

    /// @dev MOCK-RECORDED allocation args; the actual move into the LINE vault is the LIVE leg that gives the borrow
    ///      vault cash. ITERATE EVERY allocation (CTR-04): a `target == 0` leg REDEEMS all of that market's shares
    ///      (closeLine's defund empties the line so the removal guard passes); a `target > current` leg deposits the
    ///      delta (the original fund leg); otherwise no-op (0 < target < current — e.g. fund's untouched base leg).
    function reallocate(MarketAllocation[] calldata allocs) external {
        delete lastReallocIds;
        delete lastReallocAssets;
        for (uint256 i; i < allocs.length; ++i) {
            lastReallocIds.push(address(allocs[i].id));
            lastReallocAssets.push(allocs[i].assets);
        }
        reallocCount++;

        for (uint256 i; i < allocs.length; ++i) {
            address id = address(allocs[i].id);
            uint256 target = allocs[i].assets;
            if (target == 0) {
                // closeLine defund: empty the line so the withdraw-queue removal guard's previewRedeem == 0.
                IOZERC4626(id).redeem(IOZERC4626(id).balanceOf(address(this)), address(this), address(this));
            } else {
                uint256 current = IOZERC4626(id).convertToAssets(IOZERC4626(id).balanceOf(address(this)));
                if (target > current) {
                    uint256 delta = target - current;
                    IERC20(usdc).approve(id, delta);
                    IOZERC4626(id).deposit(delta, address(this));
                }
                // else (0 < target < current): no-op (do NOT add a withdraw leg — would perturb fund's base leg).
            }
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

/// @notice A no-op recording IZipcodeVenue that records the lien it was opened with and returns a deterministic
///         lineRef/oracleKey — for isolating which venue instance the controller routed to.
contract RecordingVenue is IZipcodeVenue {
    address public immutable lineRef;
    address public immutable oracleKey;
    uint256 public openCount;
    uint256 public closeCount;
    bytes32 public lastLienId;

    constructor(address lineRef_, address oracleKey_) {
        lineRef = lineRef_;
        oracleKey = oracleKey_;
    }

    function openLine(bytes32 lienId, address, uint256) external returns (address, address) {
        openCount++;
        lastLienId = lienId;
        return (lineRef, oracleKey);
    }

    function setLineLimits(address, uint16, uint16, uint256) external {}
    function fund(address, uint256) external {}
    function draw(address, uint256, address) external {}
    function observeDebt(address) external pure returns (uint256) {
        return 0;
    }

    function closeLine(address) external {
        closeCount++;
    }

    function liquidate(address) external {}
}

/// @notice A 3-method SiloRegistry stand-in for isolating the controller's routing branches (the real registry's
///         admission/topology is exhaustively covered by SiloRegistry.t.sol). Mirrors the controller's inline
///         ISiloRegistry: venueOf + increment/decrement. Tracks a per-siloId concurrent-line counter.
contract MockSiloRegistry {
    mapping(bytes32 => address) public venues;
    mapping(bytes32 => uint256) public lineCount;

    function setVenue(bytes32 siloId, address venue) external {
        venues[siloId] = venue;
    }

    function venueOf(bytes32 siloId) external view returns (address) {
        return venues[siloId];
    }

    function incrementLineCount(bytes32 siloId) external {
        lineCount[siloId] += 1;
    }

    function decrementLineCount(bytes32 siloId) external {
        lineCount[siloId] -= 1;
    }
}

/// @notice Minimal self-consistent topology stub for the REAL SiloRegistry's 6-clause admission assert. The adapter
///         is the real EulerVenueAdapter (adapter.eulerEarn() == ee), so eePool == address(ee). The freeze stub
///         returns {eulerEarn=ee, warehouseSafe=warehouseSafe, navOracle=navOracle}.
contract StubFreeze {
    address public eulerEarn;
    address public warehouseSafe;
    address public navOracle;

    constructor(address ee_, address warehouseSafe_, address navOracle_) {
        eulerEarn = ee_;
        warehouseSafe = warehouseSafe_;
        navOracle = navOracle_;
    }
}

/// @notice Escrow stub: escrow.coordinator() == defaultCoordinator.
contract StubEscrow {
    address public coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }
}

/// @notice Coordinator stub: coordinator.navOracle() == navOracle.
contract StubCoordinator {
    address public navOracle;

    constructor(address navOracle_) {
        navOracle = navOracle_;
    }
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
    SiloRegistry internal siloReg;
    address internal usdcReservoir;

    // EOAs
    address internal FORWARDER = makeAddr("forwarder");
    address internal CONTROLLER_OWNER; // = this test contract (the deployer of the controller)
    address internal EREBOR = makeAddr("erebor");

    bytes32 internal constant LIEN_ID = bytes32(uint256(0xA11CE));
    bytes32 internal constant LIEN_ID_2 = bytes32(uint256(0xB0B));
    bytes32 internal constant PROOF_REF = bytes32(uint256(0xDEAD));
    bytes32 internal constant SILO_0 = bytes32(uint256(0x5170));

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
        uint256 drawAmount,
        bytes32 siloId
    );
    event LienReleased(bytes32 indexed lienId);
    event LienDrawn(bytes32 indexed lienId, uint256 equityMark, uint256 drawAmount);
    event LienStatusUpdated(bytes32 indexed lienId, uint8 status);
    event WiringSet(bytes32 indexed slot, address value);

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
        usdcReservoir = factory.createProxy(address(0), false, abi.encodePacked(usdc, address(0), address(0)));
        IEVault(usdcReservoir).setHookConfig(address(0), 0);
        IEVault(usdcReservoir).setGovernorAdmin(address(0));

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
            usdcReservoir
        );
        assertEq(address(adapter), predictedAdapter, "adapter address prediction must hold");
        assertEq(controller.venue(), address(adapter), "controller.venue == adapter");

        // Wire the registry's set-once seed authority to the controller.
        registry.setController(address(controller));

        // ---- CTR-03: deploy + wire the REAL SiloRegistry, registering SILO_0 -> adapter ----
        // Self-consistent topology stubs so addSilo's 6-clause assert passes. The adapter is the REAL
        // EulerVenueAdapter (adapter.eulerEarn() == ee), so eePool == address(ee).
        address warehouseSafe = makeAddr("warehouseSafe");
        address navOracle = makeAddr("navOracle");
        address juniorBasket = makeAddr("juniorBasket");
        address curator = makeAddr("curator");
        StubCoordinator coord = new StubCoordinator(navOracle);
        StubEscrow escrow = new StubEscrow(address(coord));
        StubFreeze freeze = new StubFreeze(address(ee), warehouseSafe, navOracle);

        siloReg = new SiloRegistry(address(this)); // ctor controller_ placeholder; re-pointed below
        siloReg.addSilo(
            SILO_0,
            SiloRegistry.SiloConfig({
                adapter: address(adapter),
                warehouseSafe: warehouseSafe,
                eePool: address(ee),
                juniorBasket: juniorBasket,
                escrow: address(escrow),
                defaultCoordinator: address(coord),
                navOracle: navOracle,
                freeze: address(freeze),
                curator: curator
            })
        );
        controller.setRegistry(address(siloReg));
        siloReg.setController(address(controller));

        // Seed the EE supply queue with the base market.
        IOZERC4626[] memory q = new IOZERC4626[](1);
        q[0] = IOZERC4626(usdcReservoir);
        ee.setSupplyQueue(q);

        // Pre-seed the base USDC market with an EE position so fund()'s `baseBalance - amount` withdraw leg has
        // balance (a §9/item-10 deploy concern; mirrors WOOF-04's _fundBaseMarket). The EE-as-lender deposits.
        vm.startPrank(address(ee));
        IERC20(usdc).approve(usdcReservoir, 50_000_000e6);
        IEVault(usdcReservoir).deposit(50_000_000e6, address(ee));
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
        // CTR-03: route the default fleet of pre-existing tests through SILO_0 (the N=1 identity silo).
        return _origReportSilo(lienId, equityMark, borrowLTV, liqLTV, drawAmount, cap, SILO_0);
    }

    /// @dev CTR-03: the RT_ORIGINATION payload gains a TRAILING `bytes32 siloId`.
    function _origReportSilo(
        bytes32 lienId,
        uint256 equityMark,
        uint16 borrowLTV,
        uint16 liqLTV,
        uint256 drawAmount,
        uint256 cap,
        bytes32 siloId
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(1), abi.encode(lienId, PROOF_REF, equityMark, borrowLTV, liqLTV, drawAmount, cap, siloId)
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
        emit LienOriginated(LIEN_ID, predictedLien, address(0), PROOF_REF, EQUITY_MARK, DRAW_AMOUNT, SILO_0);

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
    // (I-11) build-phase wiring setters + ctor zero-guards
    // ============================================================
    // The 5 Timelock-settable slots (venue/lienFactory/oracleRegistry/erebor/registry). All pure store-and-emit
    // (no external call), so re-pointing to a fresh address is safe. Owner == this test contract.

    function test_I11_WiringSetters_RejectNonOwner() public {
        address bad = makeAddr("notOwner");
        vm.startPrank(bad);
        bytes memory expErr = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad);
        vm.expectRevert(expErr);
        controller.setVenue(bad);
        vm.expectRevert(expErr);
        controller.setLienFactory(bad);
        vm.expectRevert(expErr);
        controller.setOracleRegistry(bad);
        vm.expectRevert(expErr);
        controller.setErebor(bad);
        vm.expectRevert(expErr);
        controller.setRegistry(bad);
        vm.stopPrank();
    }

    function test_I11_WiringSetters_RejectZeroAddress() public {
        vm.expectRevert(ZipcodeController.ZeroAddress.selector);
        controller.setVenue(address(0));
        vm.expectRevert(ZipcodeController.ZeroAddress.selector);
        controller.setLienFactory(address(0));
        vm.expectRevert(ZipcodeController.ZeroAddress.selector);
        controller.setOracleRegistry(address(0));
        vm.expectRevert(ZipcodeController.ZeroAddress.selector);
        controller.setErebor(address(0));
        vm.expectRevert(ZipcodeController.ZeroAddress.selector);
        controller.setRegistry(address(0));
    }

    function test_I11_WiringSetters_RepointAndEmit() public {
        address x = makeAddr("rewire");

        vm.expectEmit(true, false, false, true, address(controller));
        emit WiringSet("venue", x);
        controller.setVenue(x);
        assertEq(controller.venue(), x, "venue re-pointed");

        vm.expectEmit(true, false, false, true, address(controller));
        emit WiringSet("lienFactory", x);
        controller.setLienFactory(x);
        assertEq(controller.lienFactory(), x, "lienFactory re-pointed");

        vm.expectEmit(true, false, false, true, address(controller));
        emit WiringSet("oracleRegistry", x);
        controller.setOracleRegistry(x);
        assertEq(controller.oracleRegistry(), x, "oracleRegistry re-pointed");

        vm.expectEmit(true, false, false, true, address(controller));
        emit WiringSet("erebor", x);
        controller.setErebor(x);
        assertEq(controller.erebor(), x, "erebor re-pointed");

        vm.expectEmit(true, false, false, true, address(controller));
        emit WiringSet("registry", x);
        controller.setRegistry(x);
        assertEq(controller.registry(), x, "registry re-pointed");
    }

    /// @notice The 4 ctor `require` zero-guards (venue/lienFactory/oracleRegistry/erebor). A valid Forwarder is passed
    ///         (the parent `ReceiverTemplate` zero-forwarder guard fires first otherwise); each non-forwarder arg is
    ///         zeroed in turn.
    function test_I11_Ctor_ZeroGuards() public {
        address v = makeAddr("v");
        address lf = makeAddr("lf");
        address or = makeAddr("or");
        address er = makeAddr("er");

        vm.expectRevert(bytes("ZipcodeController: zero venue"));
        new ZipcodeController(FORWARDER, address(0), lf, or, er);
        vm.expectRevert(bytes("ZipcodeController: zero lienFactory"));
        new ZipcodeController(FORWARDER, v, address(0), or, er);
        vm.expectRevert(bytes("ZipcodeController: zero oracleRegistry"));
        new ZipcodeController(FORWARDER, v, lf, address(0), er);
        vm.expectRevert(bytes("ZipcodeController: zero erebor"));
        new ZipcodeController(FORWARDER, v, lf, or, address(0));
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

        // c2 needs a routable registry too (the real registry's topology can't admit ReentrantVenue). A 3-method
        // MockSiloRegistry pointing SILO_0 -> rv is fine (increment/decrement just bump a counter).
        MockSiloRegistry mockReg = new MockSiloRegistry();
        mockReg.setVenue(SILO_0, address(rv));
        c2.setRegistry(address(mockReg));

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

    // ============================================================
    // (10) CTR-03 — siloId routing over the registry
    // ============================================================

    bytes32 internal constant SILO_A = bytes32(uint256(0xA));
    bytes32 internal constant SILO_B = bytes32(uint256(0xB));
    bytes32 internal constant SILO_UNKNOWN = bytes32(uint256(0xDEAD0));

    /// @dev Stand up a fresh controller routed through a MockSiloRegistry, with seedPrice mocked so origination
    ///      through a no-op RecordingVenue completes deterministically (isolating routing from venue mechanics).
    function _freshRoutedController() internal returns (ZipcodeController c, MockSiloRegistry mr) {
        c = new ZipcodeController(FORWARDER, address(adapter), address(lienFactory), address(registry), EREBOR);
        mr = new MockSiloRegistry();
        c.setRegistry(address(mr));
        // seedPrice is the only real-registry call in the no-op-venue path; mock it (the lien create is real,
        // caller-bound to `c`).
        vm.mockCall(address(registry), abi.encodeWithSelector(IZipcodeOracleRegistrySeed.seedPrice.selector), bytes(""));
    }

    // (a) origination routes to the venue named by siloId
    function test_CTR03_Origination_RoutesToNamedVenue() public {
        (ZipcodeController c, MockSiloRegistry mr) = _freshRoutedController();
        RecordingVenue vA = new RecordingVenue(address(0xA11), address(0xA12));
        RecordingVenue vB = new RecordingVenue(address(0xB11), address(0xB12));
        mr.setVenue(SILO_A, address(vA));
        mr.setVenue(SILO_B, address(vB));

        vm.prank(FORWARDER);
        c.onReport("", _origReportSilo(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP, SILO_A));

        assertEq(vA.openCount(), 1, "SILO_A venue opened");
        assertEq(vB.openCount(), 0, "SILO_B venue NOT touched");
        ZipcodeController.LienRecord memory r = c.getLien(LIEN_ID);
        assertEq(r.siloId, SILO_A, "record stores routed siloId");
        assertEq(r.lineRef, address(0xA11), "lineRef from SILO_A venue");

        // A second lien routed to SILO_B hits the OTHER venue.
        vm.prank(FORWARDER);
        c.onReport("", _origReportSilo(LIEN_ID_2, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP, SILO_B));
        assertEq(vB.openCount(), 1, "SILO_B venue opened for second lien");
        assertEq(c.getLien(LIEN_ID_2).siloId, SILO_B, "second record stores SILO_B");
    }

    // (b) draw/close re-resolve from r.siloId — even after the silo's currentSilo/active state changes.
    function test_CTR03_DrawClose_ReResolveFromStoredSiloId() public {
        (ZipcodeController c, MockSiloRegistry mr) = _freshRoutedController();
        RecordingVenue vA = new RecordingVenue(address(0xA11), address(0xA12));
        mr.setVenue(SILO_A, address(vA));

        vm.prank(FORWARDER);
        c.onReport("", _origReportSilo(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP, SILO_A));

        // Draw re-resolves SILO_A -> vA (no separate venue pointer on the report).
        vm.prank(FORWARDER);
        c.onReport("", _drawReport(LIEN_ID, EQUITY_MARK, 1e6));

        // Close re-resolves SILO_A -> vA and burns; the controller still holds the 1e18 (no-op openLine never pulled it).
        vm.prank(FORWARDER);
        c.onReport("", _closeReport(LIEN_ID));
        assertEq(vA.closeCount(), 1, "close routed to the stored silo's venue");
        assertFalse(c.getLien(LIEN_ID).open, "record closed");
    }

    /// @dev The integration-level proof that a line still closes after its silo's `currentSilo`/`active` state
    ///      changes (uses the REAL SiloRegistry from setUp; SILO_0 -> the real adapter).
    function test_CTR03_OpenLine_ClosesAfterSiloRetired() public {
        _originate(LIEN_ID); // routes through SILO_0 (real registry, real adapter)
        assertEq(siloReg.getSilo(SILO_0).lineCount, 1, "line counted");

        // Retire SILO_0 (clears currentSilo, sets active=false). venueOf still returns the adapter (Key req 1).
        siloReg.retireSilo(SILO_0);
        assertEq(siloReg.currentSilo(), bytes32(0), "currentSilo cleared on retire");
        assertEq(siloReg.venueOf(SILO_0), address(adapter), "venueOf survives retire");

        // The open line still closes — re-resolved from r.siloId, not currentSilo.
        _repayAndClose(LIEN_ID);
        assertFalse(controller.getLien(LIEN_ID).open, "open line closed after silo retire");
        assertEq(siloReg.getSilo(SILO_0).lineCount, 0, "count decremented on close");
    }

    // (c) line count increments on origination + decrements on close (via the registry's count/getSilo).
    function test_CTR03_LineCount_IncrementsAndDecrements() public {
        assertEq(siloReg.getSilo(SILO_0).lineCount, 0, "count starts 0");
        _originate(LIEN_ID);
        assertEq(siloReg.getSilo(SILO_0).lineCount, 1, "incremented on origination");
        _originate(LIEN_ID_2);
        assertEq(siloReg.getSilo(SILO_0).lineCount, 2, "incremented on second origination");
        _repayAndClose(LIEN_ID);
        assertEq(siloReg.getSilo(SILO_0).lineCount, 1, "decremented on close");
        _repayAndClose(LIEN_ID_2);
        assertEq(siloReg.getSilo(SILO_0).lineCount, 0, "decremented back to 0");
    }

    // (d) SiloFull rolls an origination fully back (no orphan).
    function test_CTR03_SiloFull_RollsBackOrigination() public {
        // Force the real registry's SILO_0 to the cap so the FINAL incrementLineCount reverts SiloFull. We pump the
        // count to MAX-1 via real originations would be 28 opens (expensive); instead drive the count to the cap by
        // pranking the controller directly against the registry (the registry's onlyController gate).
        uint16 max = siloReg.MAX_LINES_PER_SILO();
        vm.startPrank(address(controller));
        for (uint256 i = 0; i < max; ++i) {
            siloReg.incrementLineCount(SILO_0);
        }
        vm.stopPrank();
        assertEq(siloReg.getSilo(SILO_0).lineCount, max, "registry at cap");

        // An origination now reverts SiloFull at the final increment — and rolls the WHOLE batch back (no orphan).
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.SiloFull.selector, SILO_0));
        controller.onReport("", _origReport(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP));
        _assertNoOrphan(LIEN_ID);
    }

    // (e) venueOf(unknownSilo) == 0 reverts SiloUnrouted.
    function test_CTR03_UnknownSilo_RevertsSiloUnrouted() public {
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(ZipcodeController.SiloUnrouted.selector, SILO_UNKNOWN));
        controller.onReport("", _origReportSilo(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP, SILO_UNKNOWN));
    }

    // (f) registry == 0 reverts RegistryUnset.
    function test_CTR03_RegistryUnset_Reverts() public {
        // A fresh controller with NO registry wired (registry starts address(0)).
        ZipcodeController c =
            new ZipcodeController(FORWARDER, address(adapter), address(lienFactory), address(registry), EREBOR);
        assertEq(c.registry(), address(0), "registry starts unset");
        vm.prank(FORWARDER);
        vm.expectRevert(ZipcodeController.RegistryUnset.selector);
        c.onReport("", _origReportSilo(LIEN_ID, EQUITY_MARK, BORROW_LTV, LIQ_LTV, DRAW_AMOUNT, CAP, SILO_0));
    }

    // Integration: full originate + close through the REAL SiloRegistry (setUp registered SILO_0 -> real adapter).
    function test_CTR03_RealRegistry_OriginateAndClose() public {
        // venueOf resolves to the real adapter; origination + increment + close + decrement all bind.
        assertEq(siloReg.venueOf(SILO_0), address(adapter), "real registry resolves SILO_0 to the adapter");
        _originate(LIEN_ID);
        ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID);
        assertEq(r.siloId, SILO_0, "record stores SILO_0");
        assertTrue(r.open, "open");
        assertEq(siloReg.getSilo(SILO_0).lineCount, 1, "real registry incremented");

        _repayAndClose(LIEN_ID);
        assertFalse(controller.getLien(LIEN_ID).open, "closed through real registry");
        assertEq(siloReg.getSilo(SILO_0).lineCount, 0, "real registry decremented");
    }

    // ============================================================
    // (6) Structure-2: revolving credit-approval line
    // ============================================================
    // A revolving line is an OPERATING MODE over the as-built stack, not new code: the line is opened ONCE, then
    // borrow -> permissionless repay -> redraw cycles on the SAME open line / oracle key / EE slot. The CRE simply
    // never files RT_CLOSE until disqualification. Per-revolution the only on-chain gate is LTV x the mark VALUE the
    // CRE supplies in the draw report (a too-low mark trips E_AccountLiquidity); a STALE mark does NOT block a draw,
    // because _draw re-seeds a fresh mark before borrowing. Repay is un-hooked and never quotes. See
    // docs/wires/CTR-08-structure-2-revolving.md.

    /// @dev RT_DRAW on an already-open line (a redraw). Mirrors the existing draw tests: advance the block first so
    ///      the re-anchor seed clears the registry's strictly-newer-ts guard (SEC-01).
    function _redraw(bytes32 lienId, uint256 equityMark, uint256 drawAmount) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(FORWARDER);
        controller.onReport("", _drawReport(lienId, equityMark, drawAmount));
    }

    // (1) Core revolving proof: borrow -> repay -> redraw on ONE open line / key / slot, no new market minted.
    function test_Revolving_BorrowRepayRedraw_SameSlot() public {
        _originate(LIEN_ID_2);

        ZipcodeController.LienRecord memory r0 = controller.getLien(LIEN_ID_2);
        address lineRef = r0.lineRef;
        address oracleKey = r0.lien;
        address borrowAccount = _borrowAccountOf(LIEN_ID_2);
        uint256 supplyLen0 = ee.supplyQueueLength();
        uint256 withdrawLen0 = ee.withdrawQueueLength();

        // Two full borrow -> permissionless repay -> redraw cycles. Do NOT close (that would make it one-shot).
        for (uint256 cycle; cycle < 2; ++cycle) {
            _repay(LIEN_ID_2); // permissionless, zeroes the debt
            assertEq(adapter.observeDebt(lineRef), 0, "debt zeroed before redraw");

            _redraw(LIEN_ID_2, EQUITY_MARK, DRAW_AMOUNT);

            ZipcodeController.LienRecord memory r = controller.getLien(LIEN_ID_2);
            assertTrue(r.open, "line still open across the revolution");
            assertEq(r.lineRef, lineRef, "same lineRef (one slot)");
            assertEq(r.lien, oracleKey, "same oracle key (persistent token)");
            assertEq(_borrowAccountOf(LIEN_ID_2), borrowAccount, "same borrow account");
            assertEq(ee.supplyQueueLength(), supplyLen0, "supply queue unchanged (no new market)");
            assertEq(ee.withdrawQueueLength(), withdrawLen0, "withdraw queue unchanged (no new slot)");
            assertEq(IEVault(lineRef).debtOf(borrowAccount), DRAW_AMOUNT, "debt == the redraw amount");
            assertEq(controller.getLien(LIEN_ID_2).lien, oracleKey, "getLien.lien unchanged");
        }
    }

    // (2) Bounded-key contrast: ONE persistent oracle key across N revolutions vs a NEW key per repo open.
    function test_Revolving_PersistentOracleKey() public {
        _originate(LIEN_ID_2);
        address key = controller.getLien(LIEN_ID_2).lien;

        // Across N revolutions the key is CONSTANT and the registry holds ONE entry for it (latest seeded mark).
        for (uint256 i; i < 3; ++i) {
            _repay(LIEN_ID_2);
            _redraw(LIEN_ID_2, EQUITY_MARK, DRAW_AMOUNT);
            assertEq(controller.getLien(LIEN_ID_2).lien, key, "revolving key is constant across revolutions");
            assertEq(registry.getQuote(1e18, key, usdc), EQUITY_MARK, "registry resolves the one key to the mark");
        }

        // Contrast: a repo open mints a DISTINCT token = a distinct oracle key (n->inf for repo, 1 for revolving).
        _originate(LIEN_ID);
        address repoKey = controller.getLien(LIEN_ID).lien;
        assertTrue(repoKey != key, "repo open mints a distinct key (Key-req #4)");
    }

    // (3) Per-revolution on-chain gate is LTV x mark (the corrected mechanism), in the post-repay context.
    function test_Revolving_LtvBackstopOnRedraw() public {
        _originate(LIEN_ID_2);
        address LIEN_i = controller.getLien(LIEN_ID_2).lien;
        address lineRef = controller.getLien(LIEN_ID_2).lineRef;
        address borrowAccount = _borrowAccountOf(LIEN_ID_2);

        _repay(LIEN_ID_2); // zero the debt; do NOT close
        assertEq(IEVault(lineRef).debtOf(borrowAccount), 0, "debt zeroed");

        uint256 priorQuote = registry.getQuote(1e18, LIEN_i, usdc);

        // A redraw whose mark is too low for the requested amount: 0.8 * 100k = $80k < the $100k draw.
        uint256 lowMark = 100_000e6;
        vm.warp(block.timestamp + 1);
        vm.prank(FORWARDER);
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        controller.onReport("", _drawReport(LIEN_ID_2, lowMark, DRAW_AMOUNT));

        // Rolled back: line stays open, prior mark + (zero) debt unchanged.
        assertTrue(controller.getLien(LIEN_ID_2).open, "line still open after rolled-back redraw");
        assertEq(registry.getQuote(1e18, LIEN_i, usdc), priorQuote, "prior mark intact (re-anchor rolled back)");
        assertEq(IEVault(lineRef).debtOf(borrowAccount), 0, "debt unchanged (still zero)");
    }

    // (4) The lapse correction: repay + a re-seeding redraw BOTH survive a mark that has gone stale for readers.
    function test_Revolving_RepayAndRedrawSurviveMarkLapse() public {
        _originate(LIEN_ID_2);
        address LIEN_i = controller.getLien(LIEN_ID_2).lien;
        address lineRef = controller.getLien(LIEN_ID_2).lineRef;
        address borrowAccount = _borrowAccountOf(LIEN_ID_2);

        // Warp past the 365-day validity window so the mark is stale for EXTERNAL readers.
        // NOTE: this forge-std's `expectRevert(bytes4)` does a FULL-returndata compare, not selector-only, so the
        // ticket's bare-selector form does not match a 2-arg error here. The two args are DETERMINISTIC (not
        // fragile): staleness == 365 days + 1 (the exact warp delta from the originate-time seed), window == the
        // registry's 365-day validityWindow. Assert them precisely via encodeWithSelector.
        vm.warp(block.timestamp + 365 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, 365 days + 1, registry.validityWindow())
        );
        registry.getQuote(1e18, LIEN_i, usdc);

        // (a) Permissionless repay STILL zeroes the debt (repay is un-hooked, never quotes).
        _repay(LIEN_ID_2);
        assertEq(IEVault(lineRef).debtOf(borrowAccount), 0, "repay survives the lapse (un-hooked, no quote)");

        // (b) An RT_DRAW AFTER the lapse STILL succeeds — _draw re-seeds a fresh mark, then borrows. Lapse does NOT
        //     block a draw (the corrected mechanism).
        _redraw(LIEN_ID_2, EQUITY_MARK, DRAW_AMOUNT);

        // The mark is refreshed (getQuote resolves again) and the debt rose by the redraw amount.
        assertEq(registry.getQuote(1e18, LIEN_i, usdc), EQUITY_MARK, "mark refreshed by the re-seeding draw");
        assertEq(IEVault(lineRef).debtOf(borrowAccount), DRAW_AMOUNT, "debt rose by the redraw amount");
        assertTrue(controller.getLien(LIEN_ID_2).open, "line open across the lapse");
    }

    // (5) Coexistence: a repo line (closes + burns, frees its CTR-04 slot) and a revolving line (persists), one pool.
    function test_Coexistence_RepoAndRevolving_OnePool() public {
        // Open BOTH into SILO_0 (one EE pool).
        _originate(LIEN_ID); // repo line
        _originate(LIEN_ID_2); // revolving line

        ZipcodeController.LienRecord memory repo = controller.getLien(LIEN_ID);
        ZipcodeController.LienRecord memory rev = controller.getLien(LIEN_ID_2);
        address repoRef = repo.lineRef;
        address revRef = rev.lineRef;

        // Both concurrent, each holding one withdraw-queue slot (the base market is seeded directly, never a slot).
        assertTrue(ee.withdrawQueueContains(repoRef), "repo line holds a slot while concurrent");
        assertTrue(ee.withdrawQueueContains(revRef), "revolving line holds a slot while concurrent");
        uint256 wqLenConcurrent = ee.withdrawQueueLength();

        // Revolving: draw -> repay -> redraw, persists open.
        _repay(LIEN_ID_2);
        _redraw(LIEN_ID_2, EQUITY_MARK, DRAW_AMOUNT);
        assertTrue(controller.getLien(LIEN_ID_2).open, "revolving line stays open");

        // Repo: draw -> repay -> RT_CLOSE -> token burned, record closed, AND its slot freed (CTR-04).
        _repayAndClose(LIEN_ID);
        assertFalse(controller.getLien(LIEN_ID).open, "repo line closed");
        assertEq(IERC20(repo.lien).totalSupply(), 0, "repo lien burned");
        assertEq(ee.withdrawQueueLength(), wqLenConcurrent - 1, "repo slot freed (CTR-04 reclaim)");
        assertFalse(ee.withdrawQueueContains(repoRef), "repo lineRef no longer in withdraw queue");
        assertTrue(ee.withdrawQueueContains(revRef), "revolving lineRef still present");

        // The revolving line can still redraw after the repo line closed.
        _repay(LIEN_ID_2);
        _redraw(LIEN_ID_2, EQUITY_MARK, DRAW_AMOUNT);
        assertTrue(controller.getLien(LIEN_ID_2).open, "revolving line still revolves after repo close");
        assertEq(
            IEVault(revRef).debtOf(_borrowAccountOf(LIEN_ID_2)), DRAW_AMOUNT, "revolving debt == redraw amount"
        );
    }
}
