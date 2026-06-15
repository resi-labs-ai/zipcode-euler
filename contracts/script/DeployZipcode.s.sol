// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {BaseAddresses} from "./BaseAddresses.sol";
import {SummonSubstrate} from "./SummonSubstrate.s.sol";
import {CreditWarehouseDeployer} from "./CreditWarehouseDeployer.sol";
import {ReservoirMarketDeployer} from "./ReservoirMarketDeployer.sol";

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

// --- supply substrate ---
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {ExitGate} from "../src/supply/szipUSD/ExitGate.sol";
import {SzipUSD} from "../src/supply/szipUSD/SzipUSD.sol";
import {ZipDepositModule} from "../src/supply/ZipDepositModule.sol";
import {ZipRedemptionQueue} from "../src/supply/ZipRedemptionQueue.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";
import {AlgebraIchiFairLpOracle} from "../src/supply/AlgebraIchiFairLpOracle.sol";

// --- engine modules (Zodiac mastercopies; cloned via ModuleProxyFactory) ---
import {SzipBuyBurnModule} from "../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {ReservoirLoopModule} from "../src/supply/szipUSD/ReservoirLoopModule.sol";
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
///      setCurator / setFeeRecipient / setFee, and pointing the EE supply queue at the reservoir borrow vault) are
///      FORK-ONLY curator ops whose admin ABI is intentionally NOT in the local `IEulerEarn` shim (we do not compile
///      EulerEarn source). They are taken as PRE-STEP env inputs here: `EE_POOL` (the created USDC EulerEarn pool)
///      and `BASE_USDC_MARKET` (the no-borrow USDC EVault at the EE supply-queue head) are env addresses. The EE
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
    error SeamEscrowCoordinator();
    error SeamNavShareTokenUnset();
    error SeamCoverageGate();

    // ----------------------------------------------------------------- inputs (env / stand-ins)
    struct Inputs {
        address team; // TEAM_MULTISIG — the broadcaster (k-of-n Safe in prod)
        address godOwner; // GOD_OWNER — transient pre-multisig (warehouse handoff target)
        uint256 saltNonce; // SUMMON_SALT_NONCE (also reused for the sub-deployers)
        address creOperator; // CRE_OPERATOR — the engine-module operator (owner != operator)
        address erebor; // EREBOR — the draw off-ramp
        address irm; // IRM — interest-rate model
        address xAlphaMirror; // XALPHA_MIRROR — 8x-01 Base xALPHA leg (M1 stand-in token ok)
        address polIchiVault; // POL_ICHI_VAULT — the zipUSD/xALPHA ICHI vault (OTC-gated; stand-in)
        address polGauge; // POL_GAUGE — the Hydrex gauge the LP stakes in
        address capitalSink; // CAPITAL_SINK — the loss-side xALPHA capital sink
        address workflowAuthor; // WORKFLOW_AUTHOR — the CRE workflow owner (all receivers)
        bytes32 workflowId; // WORKFLOW_ID — the CRE workflow id (all receivers; one author/id family)
        // EE-factory ABI avoidance (pre-step env inputs; see contract NatSpec):
        address eePool; // EE_POOL — the created USDC EulerEarn pool
        address baseUsdcMarket; // BASE_USDC_MARKET — the no-borrow USDC EVault at the EE supply-queue head
        // numeric knobs
        uint256 validityWindow; // registry + lpOracle read-staleness window
        uint32 lpTwapWindow; // 0 = CRE-push lpOracle + spot NAV LP leg (M1 default); >0 = trustless fair-LP
            // (AlgebraIchiFairLpOracle) for the reservoir collateral AND the NAV LP leg. Opt-in once the
            // zipUSD/xALPHA LP is a live Algebra pool with a TWAP plugin. build/fair-lp.md.
        uint32 W; // NAV TWAP window
        uint256 maxAge; // NAV pushed-leg staleness
        uint256 maxDeviationBps; // NAV per-push deviation circuit-break
        uint256 tvlCap; // ExitGate TVL cap
        uint256 recoveryFloor; // DefaultCoordinator recovery floor (< 1e18)
        uint256 borrowCap; // ReservoirLoopModule borrow cap
        uint16 borrowLTV; // reservoir market borrow LTV (1e4)
        uint16 liqLTV; // reservoir market liquidation LTV (1e4)
        uint16 dBps; // buy-burn discount bps
        uint256 buybackCap; // buy-burn per-cycle cap
        // bridge rate oracle
        uint256 rateMaxStaleness; // SzAlphaRateOracle max staleness
        uint32 rateWindow; // SzAlphaRateOracle window
        uint256 rateAprCap; // SzAlphaRateOracle APR cap
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
        // P5 reservoir market + LP oracle
        SzipReservoirLpOracle lpOracle;
        address escrowVault;
        address borrowVault;
        address router;
        // P6 engine modules (proxies)
        address buyBurn;
        address reservoirLoop;
        address lpStrategy;
        address harvestVote;
        address exercise;
        address sell;
        address recycle;
        address offRamp;
        address durationFreeze;
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
        vm.stopBroadcast();
    }

    // ================================================================= P0 — roots
    function _phaseP0() internal {
        // 1. Timelock: 2-day delay, deployer = sole proposer/executor + retained admin for the build phase.
        address[] memory deployerArr = new address[](1);
        deployerArr[0] = msg.sender;
        address[] memory openExec = new address[](1);
        openExec[0] = address(0); // open executor role (anyone can execute a queued op)
        d.timelock = new TimelockController(2 days, deployerArr, openExec, msg.sender);

        // 2. eePool: created off the LIVE EulerEarnFactory in a pre-step (fork-only; ABI not compiled). Taken as
        //    env input `EE_POOL`. On a non-fork build this call site is intentionally absent — the script compiles
        //    against the address. Same for `baseUsdcMarket` (the no-borrow USDC EVault).
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
            i.irm,
            BaseAddresses.USDC,
            i.erebor,
            i.baseUsdcMarket
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

        // 9. assert the venue spine seams.
        if (d.controller.venue() != address(d.adapter)) revert SeamVenue();
        if (d.registry.controller() != address(d.controller)) revert SeamRegistryController();
    }

    // ================================================================= P2 — bridge rate oracle (Base side of 8x-02)
    function _phaseP2() internal {
        // 10.
        d.rateOracle =
            new SzAlphaRateOracle(BaseAddresses.CRE_KEYSTONE_FORWARDER, i.rateMaxStaleness, i.rateWindow, i.rateAprCap);
    }

    // ================================================================= P4 — warehouse (before the P3 deposit module)
    function _phaseP4() internal {
        // zipUSD synth — deployed HERE (ahead of P3) so the redemption queue ctor can bind the REAL token: the queue
        // ctor zero-checks `zipUSD` AND reads `zipUSD.decimals()`, so it cannot accept the `address(0)`-then-setTokens
        // placeholder. The synth depends only on the EVC (no warehouse/summon dependency), so building it here is safe;
        // P3's later steps (deposit module, NAV oracle, Gate) reuse `d.zipUSD`.
        d.zipUSD = new ESynth(BaseAddresses.EVC, "Zipcode USD", "zipUSD");

        // 21. repaySink = the redemption queue — deployed here (before the warehouse) so the warehouse can pin
        //     repaySink == queue (the §6 repaySink chain). The queue's remaining wiring (controllers) lands in P3.
        d.queue = new ZipRedemptionQueue(address(d.zipUSD), BaseAddresses.USDC, _redemptionController());

        d.warehouse = new CreditWarehouseDeployer().deploy(
            i.godOwner,
            msg.sender, // receiverAdmin — the adapter (a CRE ReceiverTemplate) is handed to the item-10 broadcaster
            i.eePool,
            BaseAddresses.USDC,
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            address(d.queue), // repaySink == queue (seam #6)
            i.saltNonce
        );

        // assert the warehouse is real + non-commingling (its Safe must NOT be the summon main Safe). The main Safe
        // is summoned in P3 — but the warehouse Safe is a fresh CREATE2 Safe and is asserted again post-P3 in P3.
        if (d.warehouse.safe == address(0)) revert SeamWarehouseCommingled();

        // 22. EE config (S8, fork-only — admin ABI not compiled): on the live EE pool —
        //       eePool.setIsAllocator(adapter, true); eePool.setCurator(adapter); eePool.setFeeRecipient(w.safe);
        //       eePool.setFee(0.5e18). Done as a pre/post fork step via the live EulerEarn admin surface.
    }

    // ================================================================= P3 — supply substrate
    function _phaseP3() internal {
        // 11. summon the two-Safe Baal substrate (inherited; broadcaster == team).
        d.sub = _summon(i.team, i.saltNonce);

        // warehouse non-commingling now that the main Safe exists.
        if (d.warehouse.safe == d.sub.mainSafe) revert SeamWarehouseCommingled();

        // 12. zipUSD synth — already deployed at the top of P4 (the queue ctor needs the real token); `d.zipUSD` is set.

        // 13. deposit module (warehouse is an immutable ctor arg — warehouse Safe from P4).
        d.depositModule =
            new ZipDepositModule(address(d.zipUSD), BaseAddresses.USDC, i.eePool, d.warehouse.safe);

        // 14. NAV oracle.
        d.navOracle = new SzipNavOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            address(d.zipUSD),
            BaseAddresses.USDC,
            i.xAlphaMirror,
            BaseAddresses.HYDX,
            BaseAddresses.OHYDX,
            d.sub.mainSafe,
            d.sub.sidecar,
            i.W,
            i.maxAge,
            i.maxDeviationBps
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

        // 19. grant the Gate manager(2): team -> mainSafe.execTransaction -> Baal.setShamans([gate],[2]).
        _setShamansManager(d.sub.baal, d.sub.mainSafe, address(d.gate));

        // 20. assert.
        if (IBaal(d.sub.baal).totalShares() != 0) revert SeamSharesNonZero();
        if (d.gate.shareToken() != address(d.szip)) revert SeamGateShareToken();
    }

    // ================================================================= P5 — reservoir market + LP oracle
    /// @dev `virtual` so a local/fork harness can interleave an initial `LP_MARK` push between the oracle creation and
    ///      the market build: EVK `setLTV` (step 24) calls `getQuote` on the `SzipReservoirLpOracle`, which reverts
    ///      `PriceOracle_NotSupported` until a fresh mark exists. In production the CRE `LP_MARK` push seeds it here.
    function _phaseP5() internal virtual {
        // 23. LP oracle. Trustless fair-LP (Algebra TWAP, build/fair-lp.md) when `lpTwapWindow` is set — it reads
        //     the price live on-chain, so it needs NO CRE seed before the step-24 `setLTV` getQuote (it resolves
        //     immediately on a live Algebra pool). Else the CRE-pushed mark (`SzipReservoirLpOracle`), which this
        //     phase is `virtual` to let a local/fork harness seed before `setLTV`.
        address lpOracleAddr;
        if (i.lpTwapWindow != 0) {
            lpOracleAddr = address(new AlgebraIchiFairLpOracle(i.polIchiVault, i.lpTwapWindow));
        } else {
            d.lpOracle = new SzipReservoirLpOracle(
                BaseAddresses.CRE_KEYSTONE_FORWARDER, BaseAddresses.USDC, i.validityWindow, i.polIchiVault
            );
            lpOracleAddr = address(d.lpOracle);
        }

        // 24. reservoir market (governor = the Timelock; engineSafe = the main basket Safe).
        (d.escrowVault, d.borrowVault, d.router) = new ReservoirMarketDeployer().deploy(
            ReservoirMarketDeployer.Params({
                factory: GenericFactory(BaseAddresses.EVAULT_FACTORY),
                evc: BaseAddresses.EVC,
                governor: address(d.timelock),
                lpToken: i.polIchiVault,
                usdc: BaseAddresses.USDC,
                lpOracle: lpOracleAddr,
                irm: i.irm,
                engineSafe: d.sub.mainSafe,
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
        address engineSafe = d.sub.mainSafe; // the basket Safe (buy-burn denominator-excluded address)

        // -- DurationFreezeModule FIRST (enabled on BOTH the main Safe AND the sidecar) — it is the coverage gate the
        //    buy-burn + LP-strategy modules wire to at construction, so it must exist before them.
        //    coverageBps = 1e4 (freeze 100% of the senior liability), dollarBuffer = 0. The floor is debt-pinned (NOT
        //    a junior-basket fraction) so it cannot be drained by shrinking gross — build/coverage-floor.md Phase 1.
        //    All deps exist by P6 (navOracle/warehouse/Safes/eePool); Timelock re-settable post-deploy.
        d.durationFreeze = _cloneModule(
            address(new DurationFreezeModule()),
            abi.encode(
                tl, d.sub.mainSafe, d.sub.sidecar, op, address(d.navOracle), i.eePool, d.warehouse.safe,
                uint256(1e4), uint256(0)
            ),
            d.sub.mainSafe
        );
        _enableModuleOnSafe(d.sub.sidecar, d.durationFreeze);

        // -- SzipBuyBurnModule (engineSafe) — coverageGate = durationFreeze: postBid blocked while !covered() --
        d.buyBurn = _cloneModule(
            address(new SzipBuyBurnModule()),
            abi.encode(
                tl, engineSafe, op, address(d.navOracle), address(d.szip), BaseAddresses.USDC,
                BaseAddresses.COW_SETTLEMENT, i.dBps, i.buybackCap, d.durationFreeze
            ),
            engineSafe
        );
        // path-lock arming seam: the buy-burn exit gate is wired LIVE to the freeze module (Timelock re-pointable).
        if (SzipBuyBurnModule(d.buyBurn).coverageGate() != d.durationFreeze) revert SeamCoverageGate();
        // engineSafe denominator-exclusion seam (#3): navOracle + gate must equal the buy-burn engineSafe.
        d.navOracle.setEngineSafe(engineSafe);
        d.gate.setEngineSafe(engineSafe);
        if (
            SzipBuyBurnModule(d.buyBurn).engineSafe() != d.gate.engineSafe()
                || d.gate.engineSafe() != d.navOracle.engineSafe()
        ) revert SeamEngineSafe();

        // -- ReservoirLoopModule (engineSafe) --
        d.reservoirLoop = _cloneModule(
            address(new ReservoirLoopModule()),
            abi.encode(tl, engineSafe, op, BaseAddresses.EVC, d.borrowVault, d.escrowVault, i.polIchiVault, BaseAddresses.USDC, i.borrowCap),
            engineSafe
        );

        // -- LpStrategyModule (engineSafe) — coverageGate = durationFreeze: removeLiquidity bounded to the excess --
        d.lpStrategy = _cloneModule(
            address(new LpStrategyModule()),
            abi.encode(tl, engineSafe, op, i.polIchiVault, i.polGauge, d.durationFreeze),
            engineSafe
        );
        // shared-LP seam (#4): LpStrategyModule.ichiVault == POL_ICHI_VAULT == escrow.asset().
        if (
            LpStrategyModule(d.lpStrategy).ichiVault() != i.polIchiVault
                || i.polIchiVault != IEVault(d.escrowVault).asset()
        ) revert SeamSharedLp();
        // path-lock arming seam: the LP-dissolution gate is wired LIVE to the freeze module (Timelock re-pointable).
        if (LpStrategyModule(d.lpStrategy).coverageGate() != d.durationFreeze) revert SeamCoverageGate();

        // -- HarvestVoteModule (engineSafe) --
        d.harvestVote = _cloneModule(
            address(new HarvestVoteModule()),
            abi.encode(tl, engineSafe, op, i.polGauge, BaseAddresses.HYDREX_VOTER, BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR),
            engineSafe
        );

        // -- ExerciseModule (engineSafe) --
        d.exercise = _cloneModule(
            address(new ExerciseModule()),
            abi.encode(tl, engineSafe, op, BaseAddresses.OHYDX),
            engineSafe
        );

        // -- SellModule (engineSafe) --
        d.sell = _cloneModule(
            address(new SellModule()),
            abi.encode(tl, engineSafe, op, BaseAddresses.ALGEBRA_SWAP_ROUTER, BaseAddresses.HYDX, BaseAddresses.USDC, address(d.zipUSD), i.xAlphaMirror, uint256(300_000e18)),
            engineSafe
        );

        // -- RecycleModule (engineSafe) --
        d.recycle = _cloneModule(
            address(new RecycleModule()),
            abi.encode(tl, engineSafe, op, address(d.depositModule), BaseAddresses.USDC, address(d.navOracle), i.eePool, d.warehouse.safe),
            engineSafe
        );
        // one-bank seam (#5): RecycleModule.warehouse/eePool/navOracle == the deposit module's bank + the NAV oracle.
        if (
            RecycleModule(d.recycle).warehouse() != d.depositModule.warehouse()
                || RecycleModule(d.recycle).eePool() != d.depositModule.eePool()
                || RecycleModule(d.recycle).navOracle() != address(d.navOracle)
        ) revert SeamOneBank();

        // -- OffRampModule (rqSafe = the basket Safe) --
        d.offRamp = _cloneModule(
            address(new OffRampModule()),
            abi.encode(tl, engineSafe, op, address(d.zipUSD), address(d.queue)),
            engineSafe
        );
        d.queue.setRedeemController(d.sub.mainSafe);

        // NOTE (path-lock arming, build/lp-path-lock.md): the coverage gates are now wired LIVE at construction —
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
        d.escrow = new LienXAlphaEscrow(i.xAlphaMirror, address(d.coord), i.capitalSink, d.sub.sidecar);

        // 28. close the cycle (coord.setEscrow forceApproves escrow internally per the ctor NatSpec).
        d.coord.setEscrow(address(d.escrow));
        d.navOracle.setDefaultCoordinator(address(d.coord));

        if (d.escrow.coordinator() != address(d.coord)) revert SeamEscrowCoordinator();
    }

    // ================================================================= P8 — NAV oracle final wiring + rate seam
    function _phaseP8() internal {
        // 29.
        d.navOracle.setLpPosition(i.polIchiVault, i.polGauge);
        // reservoir escrow + borrow vaults (P5) -> NAV closes the mid-loop blind spot (counts escrow-collateralized
        // LP + subtracts strike debt; build/lp-path-lock.md). Both exist by P5 (step 24).
        d.navOracle.setReservoirLeg(d.escrowVault, d.borrowVault);
        // Fair-LP NAV LP leg (build/twap-ring.md + build/fair-lp.md): when set, the NAV LP leg reconstructs reserves
        // at the Algebra TWAP tick instead of spot getTotalAmounts. Same window the reservoir collateral oracle uses.
        if (i.lpTwapWindow != 0) d.navOracle.setLpTwapWindow(i.lpTwapWindow);
        d.navOracle.setXAlphaRateOracle(address(d.rateOracle));
        if (d.navOracle.shareToken() == address(0)) revert SeamNavShareTokenUnset();
    }

    // ================================================================= P9 — seal (identity -> pre-gate -> transfer)
    function _phaseP9() internal {
        // 30. set the CRE identity on every ReceiverTemplate (controller, registry, warehouse adapter, coord,
        //     navOracle, rateOracle). setExpectedAuthor / setExpectedWorkflowId (inherited from ReceiverTemplate).
        _sealIdentity(address(d.controller));
        _sealIdentity(address(d.registry));
        _sealIdentity(d.warehouse.adapter);
        _sealIdentity(address(d.coord));
        _sealIdentity(address(d.navOracle));
        _sealIdentity(address(d.rateOracle));

        // 31. the fail-closed pre-gate (identity unset OR registry controller unset => revert).
        ZipcodeDeployAsserts.requireIdentityWired(address(d.controller), address(d.registry));

        // 32. transferOwnership(timelock) on every owned contract — NOT renounce (build-phase §17).
        address tl = address(d.timelock);
        d.registry.transferOwnership(tl);
        d.controller.transferOwnership(tl);
        d.hook.transferOwnership(tl); // manual-owner hook (not OZ Ownable)
        d.adapter.transferOwnership(tl);
        d.navOracle.transferOwnership(tl);
        // The CRE-push lpOracle is OZ-Ownable; the fair-LP oracle is ownerless (immutable params) ⇒ unset here.
        if (address(d.lpOracle) != address(0)) d.lpOracle.transferOwnership(tl);
        d.rateOracle.transferOwnership(tl);
        d.gate.transferOwnership(tl);
        d.szip.transferOwnership(tl);
        d.queue.transferOwnership(tl);
        d.escrow.transferOwnership(tl);
        d.coord.transferOwnership(tl);
        // ZipDepositModule has NO ownable surface — its sole admin (the set-once `setGate`) is the IMMUTABLE
        // `deployer` (this script). No transfer path; a known build-phase limitation (re-deploy to re-home, or the
        // Timelock simply never needs it since setGate is re-settable only by the immutable deployer). Not transferred.

        // Engine modules are ALREADY owned by `tl`: each was cloned in P6 with `owner_ == tl` and the zodiac
        // `Module.setUp` runs `_transferOwnership(owner_)`, so the module owner is the Timelock from birth. A P9
        // `transferOwnership(tl)` here would be both redundant AND revert (the team broadcaster is not the owner).
        // No module transfer is needed — they enter the post-deploy state owned by the Timelock directly.

        // The warehouse adapter is a `ReceiverTemplate` (OZ-Ownable). `CreditWarehouseDeployer` hands its ownership to
        // the item-10 broadcaster (`receiverAdmin == msg.sender`, P4) — distinct from the Safe/Roles which go to
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

    /// @notice team -> mainSafe.execTransaction -> Baal.setShamans([gate],[2]) (grant the Gate manager).
    function _setShamansManager(address baal, address mainSafe, address gate) internal {
        address[] memory shamans = new address[](1);
        shamans[0] = gate;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        bytes memory setShamans = abi.encodeWithSelector(IBaal.setShamans.selector, shamans, perms);
        _execAsTeam(mainSafe, baal, setShamans);
    }

    /// @notice Set the CRE identity (author + workflow id) on a `ReceiverTemplate` (selectors inherited from it).
    function _sealIdentity(address receiver) internal {
        IReceiverIdentitySet(receiver).setExpectedAuthor(i.workflowAuthor);
        IReceiverIdentitySet(receiver).setExpectedWorkflowId(i.workflowId);
    }

    /// @notice OZ `Ownable.transferOwnership` on an engine module proxy (the zodiac `Module` base is OZ-Ownable).
    function _transferModuleOwner(address module, address newOwner) internal {
        IOwnableLike(module).transferOwnership(newOwner);
    }

    /// @notice Generic Safe owner-driven call: team (an owner of `safe`) drives `safe.execTransaction(to, 0, data)`
    ///         with the 1-of-n pre-validated signature (`v==1`, msg.sender == owner == team). Same pattern as
    ///         SummonSubstrate `_addOwnerToSidecar`.
    function _execAsTeam(address safe, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(i.team))), bytes32(0), uint8(1));
        ISafe(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    /// @dev The redemption queue's CRE settle controller is a DISTINCT identity from the origination controller; in
    ///      M1 it is wired to the engine OffRamp/RQ Safe (`setRedeemController(mainSafe)` in P6). The ctor `controller_`
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
        i.irm = vm.envAddress("IRM");
        i.xAlphaMirror = vm.envAddress("XALPHA_MIRROR");
        i.polIchiVault = vm.envAddress("POL_ICHI_VAULT");
        // POL_GAUGE MUST be the ICHI-vault-keyed ALM gauge (`Voter.gauges(POL_ICHI_VAULT)`), NOT the per-pool CL gauge
        // (`Voter.gauges(pool)`). The CL gauge rejects ICHI ALM wrapper shares (reverts 0x87c5d02a — wrong staking
        // token). See DeployLocal.s.sol's LIVE_HYDREX_GAUGE note (verified on the fork).
        i.polGauge = vm.envAddress("POL_GAUGE");
        i.capitalSink = vm.envAddress("CAPITAL_SINK");
        i.workflowAuthor = vm.envAddress("WORKFLOW_AUTHOR");
        i.workflowId = vm.envBytes32("WORKFLOW_ID");
        i.eePool = vm.envAddress("EE_POOL");
        i.baseUsdcMarket = vm.envAddress("BASE_USDC_MARKET");

        i.validityWindow = vm.envUint("VALIDITY_WINDOW");
        i.W = uint32(vm.envUint("NAV_W"));
        i.maxAge = vm.envUint("NAV_MAX_AGE");
        i.maxDeviationBps = vm.envUint("NAV_MAX_DEVIATION_BPS");
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
    }
}

/// @notice The `ReceiverTemplate` identity-seal surface (inherited; onlyOwner).
interface IReceiverIdentitySet {
    function setExpectedAuthor(address author) external;
    function setExpectedWorkflowId(bytes32 id) external;
}

/// @notice A minimal `transferOwnership` face (OZ Ownable + the manual-owner hook share the selector).
interface IOwnableLike {
    function transferOwnership(address newOwner) external;
}
