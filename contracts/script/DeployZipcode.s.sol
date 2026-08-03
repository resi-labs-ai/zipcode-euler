// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {BaseAddresses} from "./BaseAddresses.sol";
import {SummonSubstrate} from "./SummonSubstrate.s.sol";
import {CreditWarehouseDeployer} from "./CreditWarehouseDeployer.sol";
import {FarmUtilityMarketDeployer} from "./FarmUtilityMarketDeployer.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {ESynth} from "evk/Synths/ESynth.sol";

// --- venue spine ---
import {ZipcodeOracleRegistry} from "../src/ZipcodeOracleRegistry.sol";
import {LienTokenFactory} from "../src/LienTokenFactory.sol";
import {CREGatingHook} from "../src/CREGatingHook.sol";
import {EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol";
import {ZipcodeController} from "../src/ZipcodeController.sol";
import {ZipcodeDeployAsserts} from "../src/ZipcodeDeployAsserts.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";
import {SeniorNavAggregator} from "../src/SeniorNavAggregator.sol";

// --- supply substrate ---
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {ExitGate} from "../src/supply/szipUSD/ExitGate.sol";
import {SzipUSD} from "../src/supply/szipUSD/SzipUSD.sol";
import {ZipDepositModule} from "../src/supply/ZipDepositModule.sol";
import {ZipRedemptionQueue} from "../src/supply/ZipRedemptionQueue.sol";
import {AlgebraIchiFairLpOracle} from "../src/supply/AlgebraIchiFairLpOracle.sol";

// --- engine modules (Zodiac mastercopies; cloned via ModuleProxyFactory) ---
import {SzipBuyBurnModule} from "../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {FarmUtilityLoopModule} from "../src/supply/szipUSD/FarmUtilityLoopModule.sol";
import {LpStrategyModule} from "../src/supply/szipUSD/LpStrategyModule.sol";
import {HarvestVoteModule} from "../src/supply/szipUSD/HarvestVoteModule.sol";
import {ExerciseModule} from "../src/supply/szipUSD/ExerciseModule.sol";
import {SellModule} from "../src/supply/szipUSD/SellModule.sol";
import {RecycleModule} from "../src/supply/szipUSD/RecycleModule.sol";
import {OffRampModule} from "../src/supply/szipUSD/OffRampModule.sol";
import {DurationFreezeModule} from "../src/supply/szipUSD/DurationFreezeModule.sol";

// --- loss side ---
import {LienXAlphaEscrow} from "../src/loss/LienXAlphaEscrow.sol";
import {DefaultCoordinator} from "../src/loss/DefaultCoordinator.sol";

// --- bridge rate oracle (Base side of 8x-02) ---
import {SzAlphaRateOracle} from "../src/bridge/SzAlphaRateOracle.sol";

// --- live-infra seams ---
import {IModuleProxyFactory} from "../src/interfaces/zodiac/IModuleProxyFactory.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

/// @title DeployZipcode (WOOF-10 — item-10 deploy + wiring orchestrator)
/// @notice Deploys + wires the entire Base-side Zipcode protocol in dependency order (phases P0–P9), asserts the
///         eight load-bearing cross-cutting seams (wires/README.md), seals every `ReceiverTemplate` CRE identity,
///         gates with `ZipcodeDeployAsserts.requireIdentityWired`, and `transferOwnership(timelock)` on every owned
///         contract. Build-phase posture per [[oracle-replaceable-timelock-wiring]] / §17: NEVER renounce; all
///         wiring stays Timelock-re-pointable. The forge-build-green is the bar this window; a fork execution run
///         (Phase S post-state) is the follow-on.
///
/// @dev `is SummonSubstrate` (which `is Script`) — we INHERIT `_summon`/`computeMainSafe` and reuse its Safe
///      pre-validated-signature execTransaction pattern for `_enableModuleOnSafe` / `_setShamansManager`. The
///      broadcaster MUST be `TEAM_MULTISIG` (the Safe `v==1` pre-validated path needs `msg.sender == owner`).
///
///      EE-pool ABI avoidance: `EULER_EARN_FACTORY.createEulerEarn(...)` and the EE admin config (setIsAllocator /
///      setCurator / setFeeRecipient / setFee, capping the resting `usdcReservoir` + the farm utility borrow vault as
///      EE markets, and pointing the EE supply queue at the resting `usdcReservoir` ONLY — the borrow vault is
///      capped/reallocate-reachable but kept OUT of the supply queue so deposits never auto-route into it) are
///      FORK-ONLY curator ops whose admin ABI is intentionally NOT in the local `IEulerEarn` shim (we do not compile
///      EulerEarn source). They are taken as PRE-STEP env inputs here: `EE_POOL` (the created USDC EulerEarn pool)
///      and `USDC_RESERVOIR` (the no-borrow USDC EVault at the EE supply-queue head) are env addresses. The EE
///      allocator/curator/fee config is a documented fork-only TODO at its phase (not compiled).
contract DeployZipcode is SummonSubstrate {
    // ----------------------------------------------------------------- asserts (clear custom errors)
    error SeamVenue();
    error SeamRegistryController();
    error SeamSharesNonZero();
    error SeamGateShareToken();
    error SeamWarehouseCommingled();
    error SeamOneBank();
    error SeamSharedLp();
    error SeamEngineSafe();
    /// @notice `juniorTrancheEngine != juniorTrancheSafe` on the NAV oracle. They are one address with two role
    ///         names; a divergence makes NAV count the safe while excluding the engine from supply.
    error SeamEngineNotSafe();
    /// @notice The buy-burn module's Zodiac exec pointers diverge from its engine (`avatar`/`target` != `juniorTrancheEngine`).
    error SeamEngineAvatar();
    error SeamEscrowCoordinator();
    /// @notice The RecycleModule↔DefaultCoordinator settlement seam is not wired both ways, so `divert` would fail
    ///         closed and the markdown could not be retired with the cash that pays it.
    error SeamRecycleCoordinator();
    error SeamNavShareTokenUnset();
    error LpTwapWindowZero();
    error SeamCoverageGate();
    error SeamSiloRegistry();
    error SeamSiloRouting();

    /// @notice The canonical single-silo id this deploy registers; the origination CRE report routes to it (CTR-03,
    ///         the `siloId` 8th field of the RT=1 payload). Without a registered silo, `_origination` fails closed.
    bytes32 internal constant LOCAL_SILO_ID = keccak256("ZIPCODE_SILO_0");

    // ----------------------------------------------------------------- inputs (env / stand-ins)
    struct Inputs {
        address team; // TEAM_MULTISIG — the broadcaster (k-of-n Safe in prod)
        address godOwner; // GOD_OWNER — transient pre-multisig (warehouse handoff target)
        uint256 saltNonce; // SUMMON_SALT_NONCE (also reused for the sub-deployers)
        address creOperator; // CRE_OPERATOR — the engine-module operator (owner != operator)
        address erebor; // EREBOR — the draw off-ramp
        address irm; // IRM — interest-rate model for the FARM UTILITY borrow vault (ZeroIRM: internal POL, §4.5.1)
        address lineIrm; // LINE_IRM — interest-rate model for the per-line credit-line borrow vaults (CTR-13, ~7.5% APR)
        address xAlphaMirror; // XALPHA_MIRROR — 8x-01 Base xALPHA leg (M1 stand-in token ok)
        address polIchiVault; // POL_ICHI_VAULT — the zipUSD/xALPHA ICHI vault (OTC-gated; stand-in)
        address polGauge; // POL_GAUGE — the Hydrex gauge the LP stakes in
        address adminSafe; // ADMIN_SAFE — the protocol treasury Safe (loss-side xALPHA recovery custody, §11)
        address curatorSafe; // CURATOR_SAFE — the per-line EVK feeReceiver: curator pay for running the vaults (CTR-13)
        address workflowAuthor; // WORKFLOW_AUTHOR — the CRE workflow owner (shared deploy wallet; all receivers)
        // CTR-16: per-receiver workflow NAMES (the shared `workflowId` pin is DROPPED — author+name survive workflow
        // redeploys, and per-receiver names are what separate the SEPARATE daemons a shared author cannot). Each is
        // the registered name string of the daemon that writes to the matching receiver (see the §13 map).
        string workflowNameController; // WORKFLOW_NAME_CONTROLLER — ZipcodeController (controller daemon, rt1/2/4/5/6)
        string workflowNameRevaluation; // WORKFLOW_NAME_REVALUATION — ZipcodeOracleRegistry (revaluation daemon, rt3)
        string workflowNameCoordinator; // WORKFLOW_NAME_COORDINATOR — DefaultCoordinator (coordinator daemon, rt8)
        string workflowNameSharefeeds; // WORKFLOW_NAME_SHAREFEEDS — SzipNavOracle (rt7)
        string workflowNameWarehouse; // WORKFLOW_NAME_WAREHOUSE — WarehouseAdminModule (warehouse daemon, CRE-04/02b/02c)
        string workflowNameRate; // WORKFLOW_NAME_RATE — SzAlphaRateOracle (szalpha-rate daemon, 8x-02)
        // EE-factory ABI avoidance (pre-step env inputs; see contract NatSpec):
        address eePool; // EE_POOL — the created USDC EulerEarn pool
        address usdcReservoir; // USDC_RESERVOIR — the no-borrow USDC EVault at the EE supply-queue head
        // numeric knobs
        uint256 validityWindow; // registry read-staleness window
        uint32 lpTwapWindow; // LP_TWAP_WINDOW (required non-zero, default 3600) — the trustless fair-LP TWAP window
        // FORK-HARNESS ONLY. Zero in production, and the script builds the real `AlgebraIchiFairLpOracle` from
        // `polIchiVault` as it always has. A fork test cannot: that oracle's constructor requires a live Algebra
        // pool with an initialized, warmed-up plugin, and the farm-utility deployer then does a birth-time
        // `getQuote` against it — neither is reachable for a zipUSD/xALPHA pair whose zipUSD this script is in the
        // middle of deploying. Injecting a fixed-mark stand-in is the only way to execute the phases at all, and
        // it mirrors `JuniorTrancheDeployer`, which already takes its LP oracle as a parameter.
        address lpOracleOverride;
            // (AlgebraIchiFairLpOracle) for the farm utility collateral AND the NAV LP leg. The CRE-push twin
            // (SzipFarmUtilityLpOracle) was DELETED: on a visible plugin swap the TWAP halts closed and the farm
            // loop pauses ~1 window (the ratified halt-over-degrade posture) — no trusted spot-mark fallback.
        uint32 W; // NAV TWAP window
        uint256 maxAge; // NAV pushed-leg staleness
        uint256 tvlCap; // ExitGate TVL cap
        uint256 recoveryFloor; // DefaultCoordinator recovery floor (< 1e18)
        uint256 borrowCap; // FarmUtilityLoopModule borrow cap
        uint16 borrowLTV; // farm utility market borrow LTV (1e4)
        uint16 liqLTV; // farm utility market liquidation LTV (1e4)
        uint16 dBps; // buy-burn discount bps
        uint256 buybackCap; // buy-burn per-cycle cap
        // bridge rate oracle
        uint256 rateMaxStaleness; // SzAlphaRateOracle max staleness
        uint32 rateWindow; // SzAlphaRateOracle window
        uint256 rateAprCap; // SzAlphaRateOracle APR cap
        uint32 rateTwapWindow; // SzAlphaRateOracle exchangeRate() smoothing window (24h at the hourly push cadence)
    }

    /// @notice The full deployment handle (one storage struct — avoids stack-too-deep across the phase helpers).
    struct Deployment {
        // roots
        TimelockController timelock;
        // P1 venue spine
        ZipcodeOracleRegistry registry;
        LienTokenFactory lienFactory;
        CREGatingHook hook;
        EulerVenueAdapter adapter;
        ZipcodeController controller;
        // P2 bridge rate oracle
        SzAlphaRateOracle rateOracle;
        // P3 supply substrate
        Substrate sub;
        ESynth zipUSD;
        ZipDepositModule depositModule;
        SzipNavOracle navOracle;
        ExitGate gate;
        SzipUSD szip;
        ZipRedemptionQueue queue;
        // P4 warehouse
        CreditWarehouseDeployer.Warehouse warehouse;
        // P5 farm utility market + LP oracle
        AlgebraIchiFairLpOracle lpOracle;
        address escrowVault;
        address borrowVault;
        address router;
        // P6 engine modules (proxies)
        address buyBurn;
        address farmUtilityLoop;
        address lpStrategy;
        address harvestVote;
        address exercise;
        address sell;
        address recycle;
        address offRamp;
        address durationFreeze;
        // P8 federation catalog (CTR-02/03)
        SiloRegistry siloRegistry;
        SeniorNavAggregator seniorNav; // CTR-05 senior-solvency aggregator (Σ donation-immune senior par over silos)
        // P7 loss side
        LienXAlphaEscrow escrow;
        DefaultCoordinator coord;
    }

    Inputs internal i;
    Deployment internal d;

    // ================================================================= entrypoint
    /// @dev Named `deploy()` (not `run()`) — `run()` is the inherited non-virtual SummonSubstrate entrypoint.
    function deploy() external {
        _loadInputs();

        vm.startBroadcast(); // broadcaster MUST be TEAM_MULTISIG (Safe pre-validated v==1 path)
        _runPhases();
        vm.stopBroadcast();
    }

    /// @notice The same deploy with inputs INJECTED and NO broadcast — the fork-harness entrypoint.
    /// @dev  Exists because the two things that made `deploy()` untestable are both about the wrapper, not the
    ///       work: it reads its inputs from the environment, and it wraps everything in `vm.startBroadcast()`,
    ///       under which `msg.sender` is the broadcaster rather than the caller. The Safe pre-validated `v == 1`
    ///       path needs `msg.sender == TEAM_MULTISIG`, which a test satisfies with `vm.prank(team)` — and a prank
    ///       does not survive `startBroadcast`. Splitting the phase body out lets the harness inject stand-ins and
    ///       drive as the team Safe owner, while `deploy()` keeps its exact production behaviour.
    /// @dev  The phase ORDER is shared, so this cannot drift from what production runs. If it could, the harness
    ///       would be proving a sequence nothing deploys.
    function deployWith(Inputs memory inputs) external {
        i = inputs;
        _injected = true;
        _runPhases();
    }

    /// @dev Set only by `deployWith`. See `_actor()`.
    bool internal _injected;

    /// @notice Who is acting as the transaction sender for this run.
    /// @dev  Under `deploy()` every state-changing call is broadcast as its OWN transaction from the broadcaster
    ///       EOA, so the script's `msg.sender` and the sender the callee observes are the same address. Inside
    ///       `deployWith` the whole run is one call stack, so the callee observes the SCRIPT while `msg.sender` is
    ///       the test. Anything that records an owner in one phase and is then called back in a later phase — the
    ///       warehouse adapter is handed to `receiverAdmin` in P4 and sealed in P9 — needs those two to agree, or
    ///       the seal reverts `OwnableUnauthorizedAccount` against an address that is correct in production.
    ///       This collapses the difference to one function rather than scattering test branches through the phases.
    function _actor() internal view returns (address) {
        return _injected ? address(this) : msg.sender;
    }

    /// @notice Read the deployed handles. `Deployment` is internal state; the harness needs it to assert the
    ///         post-state seams, and there is no event carrying the full set.
    function getDeployment() external view returns (Deployment memory) {
        return d;
    }

    /// @dev The phase sequence, shared by `deploy()` and `deployWith`. Order is load-bearing and commented at
    ///      each call site rather than here.
    function _runPhases() internal {
        _phaseP0();
        _phaseP1();
        _phaseP2();
        _phaseP4(); // warehouse BEFORE the P3 deposit module (immutable warehouse ctor arg)
        _phaseP3();
        _phaseP5();
        _phaseP6();
        _phaseP7();
        _phaseP8();
        _phaseP9();
    }

    // ================================================================= P0 — roots
    function _phaseP0() internal {
        // 1. Timelock: 2-day delay, deployer = sole proposer/executor + retained admin for the build phase.
        address[] memory deployerArr = new address[](1);
        deployerArr[0] = _actor();
        address[] memory openExec = new address[](1);
        openExec[0] = address(0); // open executor role (anyone can execute a queued op)
        d.timelock = new TimelockController(2 days, deployerArr, openExec, _actor());

        // 2. eePool: created off the LIVE EulerEarnFactory in a pre-step (fork-only; ABI not compiled). Taken as
        //    env input `EE_POOL`. On a non-fork build this call site is intentionally absent — the script compiles
        //    against the address. Same for `usdcReservoir` (the no-borrow USDC EVault).
    }

    // ================================================================= P1 — venue spine
    function _phaseP1() internal {
        // 3-4
        d.registry = new ZipcodeOracleRegistry(BaseAddresses.CRE_KEYSTONE_FORWARDER, BaseAddresses.USDC, i.validityWindow);
        d.lienFactory = new LienTokenFactory();

        // 5. hook with borrowDriver placeholder (set after the adapter).
        d.hook = new CREGatingHook(BaseAddresses.EVAULT_FACTORY, BaseAddresses.EVC, address(0));

        // 6. adapter with controller placeholder (ctor does NOT zero-check controller_).
        d.adapter = new EulerVenueAdapter(
            address(0), // controller placeholder
            BaseAddresses.EVC,
            i.eePool,
            BaseAddresses.EVAULT_FACTORY,
            address(d.registry),
            address(d.hook),
            i.lineIrm, // CTR-13: the adapter `irm` slot drives the per-line vaults (real ~7.5% APR), NOT the farm utility
            BaseAddresses.USDC,
            i.erebor,
            i.usdcReservoir
        );

        // 7. controller (venue_ must be non-zero ✓).
        d.controller = new ZipcodeController(
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            address(d.adapter),
            address(d.lienFactory),
            address(d.registry),
            i.erebor
        );

        // 8. close the ctor cycles via the Timelock-settable setters.
        d.adapter.setController(address(d.controller));
        d.hook.setBorrowDriver(address(d.adapter));
        d.registry.setController(address(d.controller));

        // 8b. CTR-13: wire the per-line curator fee receiver (the EVK `feeReceiver` every `openLine` installs).
        // `address(0)` is the legal "no curator fee" sentinel (governor forfeits ⇒ 100% to Euler).
        d.adapter.setCuratorSafe(i.curatorSafe);

        // 9. assert the venue spine seams.
        if (d.controller.venue() != address(d.adapter)) revert SeamVenue();
        if (d.registry.controller() != address(d.controller)) revert SeamRegistryController();
    }

    // ================================================================= P2 — bridge rate oracle (Base side of 8x-02)
    function _phaseP2() internal {
        // 10.
        d.rateOracle = new SzAlphaRateOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER, i.rateMaxStaleness, i.rateWindow, i.rateAprCap, i.rateTwapWindow
        );
    }

    // ================================================================= P4 — warehouse (before the P3 deposit module)
    function _phaseP4() internal {
        // zipUSD synth — deployed HERE (ahead of P3) so the redemption queue ctor can bind the REAL token: the queue
        // ctor zero-checks `zipUSD` AND reads `zipUSD.decimals()`, so it cannot accept the `address(0)`-then-setTokens
        // placeholder. The synth depends only on the EVC (no warehouse/summon dependency), so building it here is safe;
        // P3's later steps (deposit module, NAV oracle, Gate) reuse `d.zipUSD`.
        d.zipUSD = new ESynth(BaseAddresses.EVC, "Zipcode USD", "zipUSD");

        // 21. redemptionBox = the redemption queue — deployed here (before the warehouse) so the warehouse can pin
        //     redemptionBox == queue (the §6 redemptionBox chain). The queue's remaining wiring (controllers) lands in P3.
        d.queue = new ZipRedemptionQueue(address(d.zipUSD), BaseAddresses.USDC, _redemptionController());

        d.warehouse = new CreditWarehouseDeployer().deploy(
            i.godOwner,
            _actor(), // receiverAdmin — the adapter (a CRE ReceiverTemplate) is handed to the item-10 broadcaster
            i.eePool,
            BaseAddresses.USDC,
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            address(d.queue), // redemptionBox == queue (seam #6)
            i.saltNonce
        );

        // assert the warehouse is real + non-commingling (its Safe must NOT be the summon main Safe). The main Safe
        // is summoned in P3 — but the warehouse Safe is a fresh CREATE2 Safe and is asserted again post-P3 in P3.
        if (d.warehouse.warehouseSafe == address(0)) revert SeamWarehouseCommingled();

        // 22. EE config (S8, fork-only — admin ABI not compiled): on the live EE pool —
        //       eePool.setIsAllocator(adapter, true); eePool.setCurator(adapter); eePool.setFeeRecipient(w.warehouseSafe);
        //       eePool.setFee(0.5e18). Done as a pre/post fork step via the live EulerEarn admin surface.
    }

    // ================================================================= P3 — supply substrate
    function _phaseP3() internal {
        // 11. summon the two-Safe Baal substrate (inherited; broadcaster == team).
        d.sub = _summon(i.team, i.saltNonce);

        // warehouse non-commingling now that the main Safe exists.
        if (d.warehouse.warehouseSafe == d.sub.juniorTrancheSafe) revert SeamWarehouseCommingled();

        // 12. zipUSD synth — already deployed at the top of P4 (the queue ctor needs the real token); `d.zipUSD` is set.

        // 13. deposit module (warehouse is an immutable ctor arg — warehouse Safe from P4).
        d.depositModule =
            new ZipDepositModule(address(d.zipUSD), BaseAddresses.USDC, i.eePool, d.warehouse.warehouseSafe);

        // 14. NAV oracle.
        d.navOracle = new SzipNavOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            address(d.zipUSD),
            BaseAddresses.USDC,
            i.xAlphaMirror,
            BaseAddresses.HYDX,
            BaseAddresses.OHYDX,
            d.sub.juniorTrancheSafe,
            d.sub.juniorTrancheSidecar,
            i.W,
            i.maxAge
        );

        // 15-16. ExitGate + SzipUSD (Gate is SzipUSD's owner-deployer); wire the share token both ways.
        d.gate = new ExitGate(d.sub.baal, address(d.navOracle), address(d.zipUSD), i.xAlphaMirror, i.tvlCap);
        d.szip = new SzipUSD(address(d.gate));
        d.gate.setShareToken(address(d.szip));
        d.navOracle.setShareToken(address(d.szip));

        // 16b. wire the buy-and-burn window controller (the CRE keeper that drives `ExitGate.burnFor`, the post-CoW
        //      buy-and-burn exit). Done HERE while the gate is still team-owned — P9 transfers the gate to the Timelock.
        //      M1 = the engine/CRE operator hot key. Without this, `burnFor` is wired to `address(0)` and the exit reverts.
        d.gate.setWindowController(i.creOperator);

        // 17. deposit module gate + zipUSD mint capacity for the module.
        d.depositModule.setGate(address(d.gate));
        d.zipUSD.setCapacity(address(d.depositModule), type(uint128).max);

        // 18. the redemption queue already binds the real zipUSD (deployed at the top of P4); no token re-point needed.
        //     Its settle controller is the ctor `controller_`; its redeem controller is wired in P6 (setRedeemController).

        // 19. grant the Gate manager(2): team -> juniorTrancheSafe.execTransaction -> Baal.setShamans([gate],[2]).
        _setShamansManager(d.sub.baal, d.sub.juniorTrancheSafe, address(d.gate));

        // 20. assert.
        if (IBaal(d.sub.baal).totalShares() != 0) revert SeamSharesNonZero();
        if (d.gate.shareToken() != address(d.szip)) revert SeamGateShareToken();
    }

    // ================================================================= P5 — farm utility market + LP oracle
    function _phaseP5() internal {
        // 23. LP oracle — the trustless fair-LP (Algebra TWAP) oracle, always. It reads the price live on-chain, so
        //     it needs NO seed before the step-24 `setLTV` getQuote (it resolves immediately on a live Algebra pool
        //     whose plugin has ≥ `lpTwapWindow` of history — a deploy-sequencing precondition, see the x-ray).
        address lpOracleAddr;
        if (i.lpOracleOverride == address(0)) {
            d.lpOracle = new AlgebraIchiFairLpOracle(i.polIchiVault, i.lpTwapWindow);
            lpOracleAddr = address(d.lpOracle);
        } else {
            lpOracleAddr = i.lpOracleOverride; // fork harness (see the Inputs field)
        }

        // 24. farm utility market (governor = the Timelock; juniorTrancheEngine = the main basket Safe).
        (d.escrowVault, d.borrowVault, d.router) = new FarmUtilityMarketDeployer().deploy(
            FarmUtilityMarketDeployer.Params({
                factory: GenericFactory(BaseAddresses.EVAULT_FACTORY),
                evc: BaseAddresses.EVC,
                governor: address(d.timelock),
                lpToken: i.polIchiVault,
                usdc: BaseAddresses.USDC,
                lpOracle: lpOracleAddr,
                irm: i.irm,
                juniorTrancheEngine: d.sub.juniorTrancheSafe,
                borrowLTV: i.borrowLTV,
                liqLTV: i.liqLTV
            })
        );

        // 25. shared-LP invariant: POL_ICHI_VAULT == escrow.asset() (seam #4).
        if (i.polIchiVault != IEVault(d.escrowVault).asset()) revert SeamSharedLp();
        // EE supply-queue -> borrowVault is a fork-only curator op (admin ABI not compiled).
    }

    // ================================================================= P6 — engine modules (clone -> setUp -> enable)
    function _phaseP6() internal {
        address tl = address(d.timelock);
        address op = i.creOperator;
        address juniorTrancheEngine = d.sub.juniorTrancheSafe; // the basket Safe (buy-burn denominator-excluded address)

        // -- DurationFreezeModule FIRST (enabled on BOTH the main Safe AND the juniorTrancheSidecar) — it is the coverage gate the
        //    buy-burn + LP-strategy modules wire to at construction, so it must exist before them.
        //    The floor is debt-pinned + STRUCTURAL (no governed knob, §17): `requiredCommittedValue =
        //    min(illiquidSeniorValue, grossBasketValue)` — freeze 100% of the lent-out senior dollars, live-marked,
        //    un-drainable by shrinking gross — docs/wires/DurationFreezeModule.md.
        //    All deps exist by P6 (navOracle/warehouse/Safes/eePool); Timelock re-settable post-deploy.
        d.durationFreeze = _cloneModule(
            address(new DurationFreezeModule()),
            abi.encode(
                tl, d.sub.juniorTrancheSafe, d.sub.juniorTrancheSidecar, op, address(d.navOracle), i.eePool, d.warehouse.warehouseSafe
            ),
            d.sub.juniorTrancheSafe
        );
        _enableModuleOnSafe(d.sub.juniorTrancheSidecar, d.durationFreeze);

        // -- SzipBuyBurnModule (juniorTrancheEngine) — coverageGate = durationFreeze: postBid blocked while !covered() --
        d.buyBurn = _cloneModule(
            address(new SzipBuyBurnModule()),
            abi.encode(
                tl, juniorTrancheEngine, op, address(d.navOracle), address(d.szip), BaseAddresses.USDC,
                BaseAddresses.COW_SETTLEMENT, i.dBps, i.buybackCap, d.durationFreeze
            ),
            juniorTrancheEngine
        );
        // path-lock arming seam: the buy-burn exit gate is wired LIVE to the freeze module (Timelock re-pointable).
        if (SzipBuyBurnModule(d.buyBurn).coverageGate() != d.durationFreeze) revert SeamCoverageGate();
        // juniorTrancheEngine denominator-exclusion seam (#3): navOracle + gate must equal the buy-burn juniorTrancheEngine.
        d.navOracle.setJuniorTrancheEngine(juniorTrancheEngine);
        d.gate.setJuniorTrancheEngine(juniorTrancheEngine);
        if (
            SzipBuyBurnModule(d.buyBurn).juniorTrancheEngine() != d.gate.juniorTrancheEngine()
                || d.gate.juniorTrancheEngine() != d.navOracle.juniorTrancheEngine()
        ) revert SeamEngineSafe();
        // The engine and the basket Safe are ONE address with two role names (docs/safe-identities.md). NAV counts
        // the safe and excludes the engine from supply, so a divergence zeroes NAV with every token intact.
        if (d.navOracle.juniorTrancheEngine() != d.navOracle.juniorTrancheSafe()) revert SeamEngineNotSafe();
        if (
            SzipBuyBurnModule(d.buyBurn).avatar() != juniorTrancheEngine
                || SzipBuyBurnModule(d.buyBurn).target() != juniorTrancheEngine
        ) revert SeamEngineAvatar();

        // -- FarmUtilityLoopModule (juniorTrancheEngine) --
        d.farmUtilityLoop = _cloneModule(
            address(new FarmUtilityLoopModule()),
            abi.encode(tl, juniorTrancheEngine, op, BaseAddresses.EVC, d.borrowVault, d.escrowVault, i.polIchiVault, BaseAddresses.USDC, i.borrowCap),
            juniorTrancheEngine
        );

        // -- LpStrategyModule (juniorTrancheEngine) — coverageGate = durationFreeze: removeLiquidity bounded to the excess --
        d.lpStrategy = _cloneModule(
            address(new LpStrategyModule()),
            abi.encode(tl, juniorTrancheEngine, op, i.polIchiVault, i.polGauge, d.durationFreeze),
            juniorTrancheEngine
        );
        // shared-LP seam (#4): LpStrategyModule.ichiVault == POL_ICHI_VAULT == escrow.asset().
        if (
            LpStrategyModule(d.lpStrategy).ichiVault() != i.polIchiVault
                || i.polIchiVault != IEVault(d.escrowVault).asset()
        ) revert SeamSharedLp();
        // path-lock arming seam: the LP-dissolution gate is wired LIVE to the freeze module (Timelock re-pointable).
        if (LpStrategyModule(d.lpStrategy).coverageGate() != d.durationFreeze) revert SeamCoverageGate();

        // -- HarvestVoteModule (juniorTrancheEngine) --
        d.harvestVote = _cloneModule(
            address(new HarvestVoteModule()),
            abi.encode(tl, juniorTrancheEngine, op, i.polGauge, BaseAddresses.HYDREX_VOTER, BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR),
            juniorTrancheEngine
        );

        // -- ExerciseModule (juniorTrancheEngine) --
        d.exercise = _cloneModule(
            address(new ExerciseModule()),
            abi.encode(tl, juniorTrancheEngine, op, BaseAddresses.OHYDX),
            juniorTrancheEngine
        );

        // -- SellModule (juniorTrancheEngine) --
        d.sell = _cloneModule(
            address(new SellModule()),
            abi.encode(tl, juniorTrancheEngine, op, BaseAddresses.ALGEBRA_SWAP_ROUTER, BaseAddresses.HYDX, BaseAddresses.USDC, address(d.zipUSD), i.xAlphaMirror, BaseAddresses.OHYDX, uint256(300_000e18)),
            juniorTrancheEngine
        );

        // -- RecycleModule (juniorTrancheEngine) --
        d.recycle = _cloneModule(
            address(new RecycleModule()),
            abi.encode(tl, juniorTrancheEngine, op, address(d.depositModule), BaseAddresses.USDC, address(d.navOracle), i.eePool, d.warehouse.warehouseSafe),
            juniorTrancheEngine
        );
        // one-bank seam (#5): RecycleModule.warehouse/eePool/navOracle == the deposit module's bank + the NAV oracle.
        if (
            RecycleModule(d.recycle).warehouseSafe() != d.depositModule.warehouseSafe()
                || RecycleModule(d.recycle).eePool() != d.depositModule.eePool()
                || RecycleModule(d.recycle).navOracle() != address(d.navOracle)
        ) revert SeamOneBank();

        // -- OffRampModule (juniorTrancheSafe = the basket Safe) --
        d.offRamp = _cloneModule(
            address(new OffRampModule()),
            abi.encode(tl, juniorTrancheEngine, op, address(d.zipUSD), address(d.queue)),
            juniorTrancheEngine
        );
        d.queue.setRedeemController(d.sub.juniorTrancheSafe);

        // NOTE (path-lock arming): the coverage gates are now wired LIVE at construction —
        // `DurationFreezeModule` is cloned at the TOP of this phase and passed into the buy-burn + LP-strategy
        // `setUp` as their `coverageGate`, asserted by the two `SeamCoverageGate` checks above. Both remain
        // Timelock-re-pointable via `setCoverageGate` (the kill-switch: `setCoverageGate(0)` disables in one tx).
    }

    // ================================================================= P7 — loss side (circular escrow <-> coordinator)
    function _phaseP7() internal {
        // 26. coordinator FIRST — its ctor does not take the escrow (it is set via `setEscrow` below), so it breaks
        //     the escrow<->coordinator cycle. The escrow ctor, by contrast, zero-checks `coordinator_` and so cannot
        //     accept a placeholder.
        d.coord = new DefaultCoordinator(
            BaseAddresses.CRE_KEYSTONE_FORWARDER, address(d.navOracle), i.xAlphaMirror, i.recoveryFloor
        );

        // 27. escrow with the REAL coordinator (ctor-pinned; no placeholder re-point needed).
        // CTR-11: the cohort-premium destination is the engine/main basket Safe (the junior tranche Safe), so the
        // yield flywheel subsumes the premium; was the juniorTrancheSidecar (inert). juniorTrancheSafe is already asserted != warehouseSafe.
        d.escrow = new LienXAlphaEscrow(i.xAlphaMirror, address(d.coord), i.adminSafe, d.sub.juniorTrancheSafe);

        // 28. close the cycle. setEscrow grants NO standing allowance; _lock approves the exact bond
        //     amount just-in-time around its pull, so a re-pointed escrow has nothing to drain.
        d.coord.setEscrow(address(d.escrow));
        d.navOracle.setDefaultCoordinator(address(d.coord));

        // The junior-cash settlement seam. Only ONE side needs wiring: `divert` reads the coordinator live off the
        // oracle, so the coordinator just has to name the module it will accept that settle from.
        d.coord.setRecycleModule(d.recycle);

        if (d.escrow.coordinator() != address(d.coord)) revert SeamEscrowCoordinator();
        if (d.coord.recycleModule() != d.recycle) revert SeamRecycleCoordinator();
    }

    // ================================================================= P8 — NAV oracle final wiring + rate seam
    function _phaseP8() internal {
        // 29.
        d.navOracle.setLpPosition(i.polIchiVault, i.polGauge);
        // farm utility escrow + borrow vaults (P5) -> NAV closes the mid-loop blind spot (counts escrow-collateralized
        // LP + subtracts strike debt). Both exist by P5 (step 24).
        d.navOracle.setFarmUtilityLeg(d.escrowVault, d.borrowVault);
        // Fair-LP NAV LP leg: the NAV LP leg reconstructs reserves at the Algebra TWAP tick instead of spot
        // getTotalAmounts. Same (required non-zero) window the farm utility collateral oracle uses.
        d.navOracle.setLpTwapWindow(i.lpTwapWindow);
        d.navOracle.setXAlphaRateOracle(address(d.rateOracle));
        if (d.navOracle.shareToken() == address(0)) revert SeamNavShareTokenUnset();

        // CTR-02/CTR-03: deploy the silo catalog and register THIS deploy as `LOCAL_SILO_ID`, then wire it as the
        //   controller's routing registry. WITHOUT this the controller's `_origination` fails closed (`RegistryUnset`)
        //   and NO line can open — origination resolves the venue + bumps the line count through the registry. The
        //   ctor seeds the slot-accounting `controller`; `addSilo` runs the 6-clause self-consistency topology assert
        //   (freeze/escrow/coordinator/adapter all point at THIS silo's eePool/safe/oracle). The deployer is still the
        //   owner here; P9 hands the registry to the Timelock with the rest.
        d.siloRegistry = new SiloRegistry(address(d.controller));
        d.controller.setRegistry(address(d.siloRegistry));
        d.siloRegistry.addSilo(
            LOCAL_SILO_ID,
            SiloRegistry.SiloConfig({
                adapter: address(d.adapter),
                warehouseSafe: d.warehouse.warehouseSafe,
                eePool: i.eePool,
                juniorBasket: d.sub.juniorTrancheSafe,
                escrow: address(d.escrow),
                defaultCoordinator: address(d.coord),
                navOracle: address(d.navOracle),
                freeze: d.durationFreeze,
                curator: address(d.adapter)
            })
        );
        if (d.controller.registry() != address(d.siloRegistry)) revert SeamSiloRegistry();
        if (d.siloRegistry.venueOf(LOCAL_SILO_ID) != address(d.adapter)) revert SeamSiloRouting();

        // CTR-05: the senior-solvency telemetry aggregator — Σ donation-immune senior par-backing over every
        //   registered silo (here just LOCAL_SILO_ID). Reads the live SiloRegistry + zipUSD; holds no funds, prices
        //   nothing (zipUSD still mints by value / redeems at par). Deployed LAST in the main sequence so no earlier
        //   CREATE address moves; owner (team broadcaster) → Timelock at P9. `seniorBacking()` is live immediately.
        d.seniorNav = new SeniorNavAggregator(address(d.siloRegistry), address(d.zipUSD));
        if (address(d.seniorNav.registry()) != address(d.siloRegistry)) revert SeamSiloRegistry();
    }

    // ================================================================= P9 — seal (identity -> pre-gate -> transfer)
    function _phaseP9() internal {
        // 30. set the CRE identity on every ReceiverTemplate — author + PER-RECEIVER workflowName (CTR-16). The
        //     shared `workflowId` pin is DROPPED (left bytes32(0) ⇒ `onReport` skips it); the per-receiver names are
        //     what separate the separate daemons that share this one deploy wallet (the §13 map).
        _sealIdentity(address(d.controller), i.workflowNameController);
        _sealIdentity(address(d.registry), i.workflowNameRevaluation);
        _sealIdentity(d.warehouse.adapter, i.workflowNameWarehouse);
        _sealIdentity(address(d.coord), i.workflowNameCoordinator);
        _sealIdentity(address(d.navOracle), i.workflowNameSharefeeds);
        _sealIdentity(address(d.rateOracle), i.workflowNameRate);
        // The fair-LP oracle is NOT a `ReceiverTemplate` (ownerless view adapter, no CRE writer) — no identity seal.

        // 31. the fail-closed pre-gate — assert EACH sealed receiver individually (author + workflowName both set,
        //     CTR-16) plus the registry's set-once controller seed. A missing/empty per-receiver name (e.g. an unset
        //     env var) now fails closed; the old representative-id inference would have missed it.
        address[] memory receivers = new address[](6);
        receivers[0] = address(d.controller);
        receivers[1] = address(d.registry);
        receivers[2] = d.warehouse.adapter;
        receivers[3] = address(d.coord);
        receivers[4] = address(d.navOracle);
        receivers[5] = address(d.rateOracle);
        ZipcodeDeployAsserts.requireIdentityWired(receivers, address(d.registry));

        // 32. transferOwnership(timelock) on every owned contract — NOT renounce (build-phase §17).
        address tl = address(d.timelock);
        d.registry.transferOwnership(tl);
        d.controller.transferOwnership(tl);
        d.hook.transferOwnership(tl); // manual-owner hook (not OZ Ownable)
        d.adapter.transferOwnership(tl);
        d.navOracle.transferOwnership(tl);
        // The fair-LP lpOracle is ownerless (immutable params) — nothing to transfer.
        d.rateOracle.transferOwnership(tl);
        d.gate.transferOwnership(tl);
        d.szip.transferOwnership(tl);
        d.queue.transferOwnership(tl);
        d.escrow.transferOwnership(tl);
        d.coord.transferOwnership(tl);
        d.siloRegistry.transferOwnership(tl); // CTR-02 catalog → Timelock (slot-accounting `controller` stays the controller)
        d.seniorNav.transferOwnership(tl); // CTR-05 senior-solvency aggregator → Timelock
        // The zipUSD ESynth. ADDED 2026-08-02 — it was MISSING from this block while thirteen siblings were in it.
        // `ESynth.setCapacity(minter, cap)` is `onlyOwner`, and `mint()` is open to any address holding capacity, so
        // whoever owns the synth can authorize itself and mint UNBOUNDED senior dollars against the USDC backing.
        // Left unset, that power stays with this script's broadcaster forever — the single most dangerous key in the
        // system, retained by the party the handoff exists to remove. Capacity for the deposit module is granted
        // earlier in P4 (step 12) while the broadcaster still owns it, so this transfer is ordering-safe.
        d.zipUSD.transferOwnership(tl);
        // ZipDepositModule has NO ownable surface — its sole admin (the set-once `setGate`) is the IMMUTABLE
        // `deployer` (this script). No transfer path; a known build-phase limitation (re-deploy to re-home, or the
        // Timelock simply never needs it since setGate is re-settable only by the immutable deployer). Not transferred.

        // Engine modules are ALREADY owned by `tl`: each was cloned in P6 with `owner_ == tl` and the zodiac
        // `Module.setUp` runs `_transferOwnership(owner_)`, so the module owner is the Timelock from birth. A P9
        // `transferOwnership(tl)` here would be both redundant AND revert (the team broadcaster is not the owner).
        // No module transfer is needed — they enter the post-deploy state owned by the Timelock directly.

        // The warehouse adapter is a `ReceiverTemplate` (OZ-Ownable). `CreditWarehouseDeployer` hands its ownership to
        // the item-10 broadcaster (`receiverAdmin == _actor()`, P4) — distinct from the Safe/Roles which go to
        // GOD_OWNER — so this script seals its CRE identity (above) and re-homes it to the Timelock uniformly with
        // every other receiver, in this same team-broadcast.
        IOwnableLike(d.warehouse.adapter).transferOwnership(tl);
    }

    // ================================================================= helpers

    /// @notice Clone a Zodiac module mastercopy + `setUp` atomically (front-run-safe), then `enableModule` on `safe`.
    function _cloneModule(address mastercopy, bytes memory setUpData, address safe) internal returns (address proxy) {
        bytes memory initializer = abi.encodeWithSignature("setUp(bytes)", setUpData);
        proxy = IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY).deployModule(
            mastercopy, initializer, i.saltNonce
        );
        _enableModuleOnSafe(safe, proxy);
    }

    /// @notice Drive `safe` (team is an owner) via the pre-validated v==1 signature path to `enableModule(module)`.
    function _enableModuleOnSafe(address safe, address module) internal {
        bytes memory data = abi.encodeWithSelector(ISafe.enableModule.selector, module);
        _execAsTeam(safe, safe, data);
    }

    /// @notice team -> juniorTrancheSafe.execTransaction -> Baal.setShamans([gate],[2]) (grant the Gate manager).
    function _setShamansManager(address baal, address juniorTrancheSafe, address gate) internal {
        address[] memory shamans = new address[](1);
        shamans[0] = gate;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        bytes memory setShamans = abi.encodeWithSelector(IBaal.setShamans.selector, shamans, perms);
        _execAsTeam(juniorTrancheSafe, baal, setShamans);
    }

    /// @notice Set the CRE identity (author + per-receiver workflow NAME) on a `ReceiverTemplate` (selectors
    ///         inherited from it). The shared `workflowId` pin is dropped (left bytes32(0)); `setExpectedWorkflowName`
    ///         hashes the registered name string to bytes10 on-chain (matching the DON metadata's same hashing), so
    ///         we pass the string directly. `onReport` requires author whenever name is set, so author goes first.
    function _sealIdentity(address receiver, string memory name) internal {
        IReceiverIdentitySet(receiver).setExpectedAuthor(i.workflowAuthor);
        IReceiverIdentitySet(receiver).setExpectedWorkflowName(name);
    }

    /// @notice OZ `Ownable.transferOwnership` on an engine module proxy (the zodiac `Module` base is OZ-Ownable).
    function _transferModuleOwner(address module, address newOwner) internal {
        IOwnableLike(module).transferOwnership(newOwner);
    }

    /// @notice Generic Safe owner-driven call: team (an owner of `safe`) drives `safe.execTransaction(to, 0, data)`
    ///         with the 1-of-n pre-validated signature (`v==1`, msg.sender == owner == team). Same pattern as
    ///         SummonSubstrate `_addOwnerToJuniorTrancheSidecar`.
    function _execAsTeam(address safe, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(i.team))), bytes32(0), uint8(1));
        ISafe(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    /// @dev The redemption queue's CRE settle controller is a DISTINCT identity from the origination controller; in
    ///      M1 it is wired to the engine OffRamp/RQ Safe (`setRedeemController(juniorTrancheSafe)` in P6). The ctor `controller_`
    ///      is the par-settle CRE identity; reuse the CRE operator as the M1 stand-in (re-pointable via setController).
    function _redemptionController() internal view returns (address) {
        return i.creOperator;
    }

    // ----------------------------------------------------------------- env load
    function _loadInputs() internal {
        i.team = vm.envAddress("TEAM_MULTISIG");
        i.godOwner = vm.envAddress("GOD_OWNER");
        i.saltNonce = vm.envUint("SUMMON_SALT_NONCE");
        i.creOperator = vm.envAddress("CRE_OPERATOR");
        i.erebor = vm.envAddress("EREBOR");
        i.curatorSafe = vm.envOr("CURATOR_SAFE", address(0)); // CTR-13: 0 ⇒ no curator fee (forfeit to Euler)
        i.irm = vm.envAddress("IRM");
        // CTR-13: the per-line rate. Defaults to the farm utility IRM if unset (back-compat), but a real deploy SHOULD
        // set LINE_IRM to the ~7.5%-APR `LineIrm` instance so lines accrue while the farm utility stays at zero.
        i.lineIrm = vm.envOr("LINE_IRM", i.irm);
        i.xAlphaMirror = vm.envAddress("XALPHA_MIRROR");
        i.polIchiVault = vm.envAddress("POL_ICHI_VAULT");
        // POL_GAUGE MUST be the ICHI-vault-keyed ALM gauge (`Voter.gauges(POL_ICHI_VAULT)`), NOT the per-pool CL gauge
        // (`Voter.gauges(pool)`). The CL gauge rejects ICHI ALM wrapper shares (reverts 0x87c5d02a — wrong staking
        // token). See DeployLocal.s.sol's LIVE_HYDREX_GAUGE note (verified on the fork).
        i.polGauge = vm.envAddress("POL_GAUGE");
        i.adminSafe = vm.envAddress("ADMIN_SAFE");
        i.workflowAuthor = vm.envAddress("WORKFLOW_AUTHOR");
        // CTR-16: per-receiver registered daemon NAMES (the `WORKFLOW_ID` env read is dropped). Required env — the
        // operator supplies the names of the deployed daemons at deploy time (they do not exist in source; the
        // `project.yaml`s are templates). The setters stay owner-callable post-deploy (§17 re-pointable).
        i.workflowNameController = vm.envString("WORKFLOW_NAME_CONTROLLER");
        i.workflowNameRevaluation = vm.envString("WORKFLOW_NAME_REVALUATION");
        i.workflowNameCoordinator = vm.envString("WORKFLOW_NAME_COORDINATOR");
        i.workflowNameSharefeeds = vm.envString("WORKFLOW_NAME_SHAREFEEDS");
        i.workflowNameWarehouse = vm.envString("WORKFLOW_NAME_WAREHOUSE");
        i.workflowNameRate = vm.envString("WORKFLOW_NAME_RATE");
        i.eePool = vm.envAddress("EE_POOL");
        i.usdcReservoir = vm.envAddress("USDC_RESERVOIR");

        i.validityWindow = vm.envUint("VALIDITY_WINDOW");
        // The fair-LP TWAP window (default 1h). Zero is REJECTED: zero meant "CRE-push lpOracle + spot NAV LP leg",
        // and both of those paths were deleted — spot composition is the manipulable surface the TWAP prices out.
        i.lpTwapWindow = uint32(vm.envOr("LP_TWAP_WINDOW", uint256(3600)));
        if (i.lpTwapWindow == 0) revert LpTwapWindowZero();
        i.W = uint32(vm.envUint("NAV_W"));
        i.maxAge = vm.envUint("NAV_MAX_AGE");
        i.tvlCap = vm.envUint("TVL_CAP");
        i.recoveryFloor = vm.envUint("RECOVERY_FLOOR");
        i.borrowCap = vm.envUint("BORROW_CAP");
        i.borrowLTV = uint16(vm.envUint("BORROW_LTV"));
        i.liqLTV = uint16(vm.envUint("LIQ_LTV"));
        i.dBps = uint16(vm.envUint("BUYBURN_DBPS"));
        i.buybackCap = vm.envUint("BUYBACK_CAP");

        i.rateMaxStaleness = vm.envUint("RATE_MAX_STALENESS");
        i.rateWindow = uint32(vm.envUint("RATE_WINDOW"));
        i.rateAprCap = vm.envUint("RATE_APR_CAP");
        i.rateTwapWindow = uint32(vm.envOr("RATE_TWAP_WINDOW", uint256(24 hours)));
    }
}

/// @notice The `ReceiverTemplate` identity-seal surface (inherited; onlyOwner). CTR-16: name-posture — the
///         `setExpectedWorkflowId` selector is no longer used by the deploy (the pin is dropped).
interface IReceiverIdentitySet {
    function setExpectedAuthor(address author) external;
    function setExpectedWorkflowName(string calldata name) external;
}

/// @notice A minimal `transferOwnership` face (OZ Ownable + the manual-owner hook share the selector).
interface IOwnableLike {
    function transferOwnership(address newOwner) external;
}
