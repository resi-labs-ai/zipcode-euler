// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {BaseAddresses} from "./BaseAddresses.sol";
import {SummonSubstrate} from "./SummonSubstrate.s.sol";

import {IEVault} from "evk/EVault/IEVault.sol";

// --- supply substrate ---
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {ExitGate} from "../src/supply/szipUSD/ExitGate.sol";
import {SzipUSD} from "../src/supply/szipUSD/SzipUSD.sol";
import {ZipDepositModule} from "../src/supply/ZipDepositModule.sol";

// --- engine modules (Zodiac mastercopies; cloned via ModuleProxyFactory) ---
import {SzipBuyBurnModule} from "../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {ReservoirLoopModule} from "../src/supply/szipUSD/ReservoirLoopModule.sol";
import {LpStrategyModule} from "../src/supply/szipUSD/LpStrategyModule.sol";
import {HarvestVoteModule} from "../src/supply/szipUSD/HarvestVoteModule.sol";
import {ExerciseModule} from "../src/supply/szipUSD/ExerciseModule.sol";
import {SellModule} from "../src/supply/szipUSD/SellModule.sol";
import {RecycleModule} from "../src/supply/szipUSD/RecycleModule.sol";
import {DurationFreezeModule} from "../src/supply/szipUSD/DurationFreezeModule.sol";

// --- loss side ---
import {LienXAlphaEscrow} from "../src/loss/LienXAlphaEscrow.sol";
import {DefaultCoordinator} from "../src/loss/DefaultCoordinator.sol";

// --- live-infra seams ---
import {IModuleProxyFactory} from "../src/interfaces/zodiac/IModuleProxyFactory.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

/// @title JuniorTrancheDeployer (CTR-06b)
/// @notice The per-junior analogue of `CreditWarehouseDeployer`: ONE callable (`deploy`) that stands up a single,
///         self-consistent junior tranche — the Baal two-Safe substrate + NAV oracle + ExitGate/SzipUSD + deposit
///         module + the 8 yield/freeze/buy-burn engine modules + the loss side — and hands every OZ-ownable contract
///         to the Timelock and BOTH Baal Safes to the persistent `team` admin multisig (§4.5 two-tier model). It is
///         the faithful EXTRACTION of `DeployZipcode`'s inline junior stack (phases P3/P6/P7/P8/P9), parameterized to
///         point at THIS silo's `eePool`/`warehouseSafe`/reservoir handles and the SHARED hub `zipUSD`/`rateOracle`.
///         CTR-06c calls it once per silo.
///
/// @dev `is SummonSubstrate` (which `is Script`) — we INHERIT `_summon`/`computeMainSafe` + the `Substrate` struct
///      and reuse the Safe pre-validated-signature `execTransaction` pattern for `_enableModuleOnSafe` /
///      `_setShamansManager`. Because CTR-06c calls `new JuniorTrancheDeployer().deploy(...)`, every internal
///      Safe-drive runs with `msg.sender == this deployer instance` — NOT the broadcaster, NOT `team`. So `deploy`
///      SELF-summons (`_summon(address(this), saltNonce)`), making the deployer instance the TRANSIENT owner/signer
///      of both Safes (the `CreditWarehouseDeployer` deploy-as-self/sign-as-self idiom). Step 17 then hands both
///      Safes to the persistent `team` (`swapOwner` from self) before returning. The reimplemented
///      `_cloneModule`/`_enableModuleOnSafe`/`_setShamansManager`/`_execAsTeam`/`_sealIdentity` helpers source
///      `team = address(this)` and `saltNonce = p.saltNonce` from this deployer's own call params (the
///      `DeployZipcode`-local helpers read `i.team`/`i.saltNonce`, so they are reimplemented, not inherited).
contract JuniorTrancheDeployer is SummonSubstrate {
    // ----------------------------------------------------------------- seam asserts (reproduced from DeployZipcode)
    error SeamSharesNonZero();
    error SeamGateShareToken();
    error SeamCoverageGate();
    error SeamEngineSafe();
    error SeamSharedLp();
    error SeamOneBank();
    error SeamEscrowCoordinator();
    error SeamNavShareTokenUnset();
    /// @notice §2 topology / non-commingling (Key req 5): the junior `juniorTrancheSafe`/`juniorTrancheSidecar` collide with the warehouse.
    error SeamWarehouseCommingled();
    /// @notice The transient-owner -> `team` Safe handoff did not land (effect, not "didn't revert").
    error SafeHandoffFailed();

    // ----------------------------------------------------------------- venue infra modules only STORE (never call)
    // These are live on the Base fork; the deployer test does not exercise their call paths, so no injection.
    address internal constant CRE_KEYSTONE_FORWARDER = BaseAddresses.CRE_KEYSTONE_FORWARDER;
    address internal constant EVC = BaseAddresses.EVC;
    address internal constant COW_SETTLEMENT = BaseAddresses.COW_SETTLEMENT;
    address internal constant ALGEBRA_SWAP_ROUTER = BaseAddresses.ALGEBRA_SWAP_ROUTER;
    address internal constant HYDREX_VOTER = BaseAddresses.HYDREX_VOTER;
    address internal constant HYDREX_REWARDS_DISTRIBUTOR = BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR;

    /// @notice The Safe owner-list sentinel (`SENTINEL_OWNERS`) — the head of the linked owner list.
    address internal constant SENTINEL_OWNERS = address(0x1);

    // ----------------------------------------------------------------- inputs
    struct JuniorParams {
        // -- identity / authority --
        address timelock; // owner_ of every module + OZ-ownable handoff target (§17)
        address team; // the persistent admin multisig the two Safes are handed to (§4.5)
        address creOperator; // module `operator` + the ExitGate windowController (M1 CRE hot key)
        uint256 saltNonce; // DISTINCT per silo (CREATE2)
        address workflowAuthor; // CRE identity seal (step 16)
        bytes32 workflowId; // CRE identity seal (step 16)
        // -- shared hub handles (NOT deployed here) --
        address zipUSD; // the shared senior $1 unit (Timelock-owned; setCapacity is the D2 runbook, not here)
        address rateOracle; // the shared SzAlphaRateOracle (hub; an input, never owned/transferred by this deployer)
        // -- per-silo handles built upstream by CTR-06c --
        address eePool; // this silo's EulerEarn pool (mock in the D3 test)
        address warehouseSafe; // this silo's warehouse Safe (CreditWarehouseDeployer output)
        address escrowVault; // this silo's reservoir escrow vault (ReservoirMarketDeployer, CTR-06a-fixed)
        address borrowVault; // this silo's reservoir borrow vault
        // -- NAV leg tokens (INPUTS, not BaseAddresses constants — the D3 fork test injects mocks) --
        address usdc;
        address xAlphaMirror;
        address hydx;
        address oHydx;
        // -- POL (D1: shared pool address; per-silo staked position) --
        address polIchiVault; // == escrowVault.asset() (seam #4)
        address polGauge;
        address adminSafe; // the protocol treasury Safe — loss-side xALPHA recovery custody (LienXAlphaEscrow ctor, §11)
        // -- numeric knobs --
        uint32 W; // NAV TWAP window
        uint256 maxAge; // NAV
        uint256 maxDeviationBps; // NAV
        uint256 tvlCap; // ExitGate
        uint16 dBps; // buy-burn discount
        uint256 buybackCap; // buy-burn
        uint256 borrowCap; // reservoir loop
        uint256 recoveryFloor; // DefaultCoordinator (must be < 1e18)
    }

    /// @notice The deployed junior tranche handle (one source of truth for CTR-06c's `addSilo`).
    struct JuniorTranche {
        address baal;
        address juniorTrancheSafe;
        address juniorTrancheSidecar;
        SzipNavOracle navOracle;
        ExitGate gate;
        SzipUSD szip;
        ZipDepositModule depositModule;
        address durationFreeze;
        address buyBurn;
        address reservoirLoop;
        address lpStrategy;
        address harvestVote;
        address exercise;
        address sell;
        address recycle;
        LienXAlphaEscrow escrow;
        DefaultCoordinator coord;
    }

    /// @dev Per-call salt; set at the top of `deploy` so the reimplemented `_cloneModule` can read it like
    ///      `DeployZipcode`'s `i.saltNonce` without threading it through every helper signature.
    uint256 internal _saltNonce;

    // ================================================================= entrypoint
    /// @notice Stand up one self-consistent junior tranche. Build order is load-bearing (mirrors DeployZipcode
    ///         P3/P6/P7/P8/P9). Returns the handles for CTR-06c's `SiloRegistry.addSilo`.
    function deploy(JuniorParams memory p) external returns (JuniorTranche memory t) {
        _saltNonce = p.saltNonce;

        // -- 1. Baal two-Safe substrate (self as transient owner/signer of BOTH Safes).
        Substrate memory sub = _summon(address(this), p.saltNonce);
        address juniorTrancheEngine = sub.juniorTrancheSafe;

        // §2 non-commingling (Key req 5): main AND juniorTrancheSidecar both distinct from the silo's warehouse Safe (strengthens
        // DeployZipcode's `SeamWarehouseCommingled`, which checks only the main Safe).
        if (sub.juniorTrancheSafe == p.warehouseSafe || sub.juniorTrancheSidecar == p.warehouseSafe) revert SeamWarehouseCommingled();

        // -- 2. SzipNavOracle (NAV legs are p.* inputs, not BaseAddresses.* — the freeze setUp reads them live).
        t.navOracle = new SzipNavOracle(
            CRE_KEYSTONE_FORWARDER,
            p.zipUSD,
            p.usdc,
            p.xAlphaMirror,
            p.hydx,
            p.oHydx,
            sub.juniorTrancheSafe,
            sub.juniorTrancheSidecar,
            p.W,
            p.maxAge,
            p.maxDeviationBps
        );

        // -- 3. ExitGate + SzipUSD (Gate is SzipUSD's owner-deployer); wire the share token both ways + window ctrl.
        t.gate = new ExitGate(sub.baal, address(t.navOracle), p.zipUSD, p.xAlphaMirror, p.tvlCap);
        t.szip = new SzipUSD(address(t.gate));
        t.gate.setShareToken(address(t.szip));
        t.navOracle.setShareToken(address(t.szip));
        t.gate.setWindowController(p.creOperator);

        // -- 4. ZipDepositModule (warehouse Safe is an immutable ctor arg). setGate runs here (deployer==this is its
        //       set-once admin). NB: zipUSD.setCapacity(depositModule, max) is a Timelock step (D2) — NOT done here.
        t.depositModule = new ZipDepositModule(p.zipUSD, p.usdc, p.eePool, p.warehouseSafe);
        t.depositModule.setGate(address(t.gate));

        // -- 5. Shaman grant: self -> juniorTrancheSafe.execTransaction -> Baal.setShamans([gate],[2]).
        _setShamansManager(sub.baal, sub.juniorTrancheSafe, address(t.gate));
        if (IBaal(sub.baal).totalShares() != 0) revert SeamSharesNonZero();
        if (t.gate.shareToken() != address(t.szip)) revert SeamGateShareToken();

        // -- 6. DurationFreezeModule FIRST (the coverageGate the buy-burn + LP-strategy wire to). owner_ = timelock.
        t.durationFreeze = _cloneModule(
            address(new DurationFreezeModule()),
            abi.encode(
                p.timelock, sub.juniorTrancheSafe, sub.juniorTrancheSidecar, p.creOperator, address(t.navOracle), p.eePool, p.warehouseSafe
            ),
            sub.juniorTrancheSafe
        );
        _enableModuleOnSafe(sub.juniorTrancheSidecar, t.durationFreeze); // enabled on BOTH Safes

        // -- 7. SzipBuyBurnModule (juniorTrancheEngine). coverageGate = durationFreeze.
        t.buyBurn = _cloneModule(
            address(new SzipBuyBurnModule()),
            abi.encode(
                p.timelock,
                juniorTrancheEngine,
                p.creOperator,
                address(t.navOracle),
                address(t.szip),
                p.usdc,
                COW_SETTLEMENT,
                p.dBps,
                p.buybackCap,
                t.durationFreeze
            ),
            juniorTrancheEngine
        );
        if (SzipBuyBurnModule(t.buyBurn).coverageGate() != t.durationFreeze) revert SeamCoverageGate();
        t.navOracle.setJuniorTrancheEngine(juniorTrancheEngine);
        t.gate.setJuniorTrancheEngine(juniorTrancheEngine);
        if (
            SzipBuyBurnModule(t.buyBurn).juniorTrancheEngine() != t.gate.juniorTrancheEngine()
                || t.gate.juniorTrancheEngine() != t.navOracle.juniorTrancheEngine()
        ) revert SeamEngineSafe();

        // -- 8. ReservoirLoopModule (juniorTrancheEngine).
        t.reservoirLoop = _cloneModule(
            address(new ReservoirLoopModule()),
            abi.encode(
                p.timelock,
                juniorTrancheEngine,
                p.creOperator,
                EVC,
                p.borrowVault,
                p.escrowVault,
                p.polIchiVault,
                p.usdc,
                p.borrowCap
            ),
            juniorTrancheEngine
        );

        // -- 9. LpStrategyModule (juniorTrancheEngine). coverageGate = durationFreeze. Shared-LP seam.
        t.lpStrategy = _cloneModule(
            address(new LpStrategyModule()),
            abi.encode(p.timelock, juniorTrancheEngine, p.creOperator, p.polIchiVault, p.polGauge, t.durationFreeze),
            juniorTrancheEngine
        );
        if (
            LpStrategyModule(t.lpStrategy).ichiVault() != p.polIchiVault
                || p.polIchiVault != IEVault(p.escrowVault).asset()
        ) revert SeamSharedLp();
        if (LpStrategyModule(t.lpStrategy).coverageGate() != t.durationFreeze) revert SeamCoverageGate();

        // -- 10. HarvestVoteModule (juniorTrancheEngine).
        t.harvestVote = _cloneModule(
            address(new HarvestVoteModule()),
            abi.encode(p.timelock, juniorTrancheEngine, p.creOperator, p.polGauge, HYDREX_VOTER, HYDREX_REWARDS_DISTRIBUTOR),
            juniorTrancheEngine
        );

        // -- 11. ExerciseModule (juniorTrancheEngine).
        t.exercise = _cloneModule(
            address(new ExerciseModule()),
            abi.encode(p.timelock, juniorTrancheEngine, p.creOperator, p.oHydx),
            juniorTrancheEngine
        );

        // -- 12. SellModule (juniorTrancheEngine).
        t.sell = _cloneModule(
            address(new SellModule()),
            abi.encode(
                p.timelock,
                juniorTrancheEngine,
                p.creOperator,
                ALGEBRA_SWAP_ROUTER,
                p.hydx,
                p.usdc,
                p.zipUSD,
                p.xAlphaMirror,
                uint256(300_000e18)
            ),
            juniorTrancheEngine
        );

        // -- 13. RecycleModule (juniorTrancheEngine). One-bank seam.
        t.recycle = _cloneModule(
            address(new RecycleModule()),
            abi.encode(
                p.timelock,
                juniorTrancheEngine,
                p.creOperator,
                address(t.depositModule),
                p.usdc,
                address(t.navOracle),
                p.eePool,
                p.warehouseSafe
            ),
            juniorTrancheEngine
        );
        if (
            RecycleModule(t.recycle).warehouseSafe() != t.depositModule.warehouseSafe()
                || RecycleModule(t.recycle).eePool() != t.depositModule.eePool()
                || RecycleModule(t.recycle).navOracle() != address(t.navOracle)
        ) revert SeamOneBank();

        // -- 14. Loss side (coordinator FIRST to break the ctor cycle).
        t.coord = new DefaultCoordinator(CRE_KEYSTONE_FORWARDER, address(t.navOracle), p.xAlphaMirror, p.recoveryFloor);
        // CTR-11: cohort premium → the engine/main basket Safe (junior tranche Safe) so the flywheel subsumes it
        // (was the juniorTrancheSidecar, inert). juniorTrancheSafe is already asserted distinct from the warehouse Safe above.
        t.escrow = new LienXAlphaEscrow(p.xAlphaMirror, address(t.coord), p.adminSafe, sub.juniorTrancheSafe);
        t.coord.setEscrow(address(t.escrow));
        t.navOracle.setDefaultCoordinator(address(t.coord));
        if (t.escrow.coordinator() != address(t.coord)) revert SeamEscrowCoordinator();

        // -- 15. NAV final wiring (M1: do NOT setLpTwapWindow — the LP leg uses the CRE-push stand-in).
        t.navOracle.setLpPosition(p.polIchiVault, p.polGauge);
        t.navOracle.setReservoirLeg(p.escrowVault, p.borrowVault);
        t.navOracle.setXAlphaRateOracle(p.rateOracle);
        if (t.navOracle.shareToken() == address(0)) revert SeamNavShareTokenUnset();

        // -- 16. Identity seal + OZ-ownable handoff (navOracle/gate/szip/escrow/coord -> Timelock). The
        //        ReceiverTemplates (navOracle, coord) also get the CRE identity seal. The engine modules are ALREADY
        //        Timelock-owned from setUp (owner_ == p.timelock) — do NOT re-transfer. ZipDepositModule has no
        //        ownable surface. Do NOT transfer p.rateOracle (a shared hub input this deployer never owned).
        _sealIdentity(address(t.navOracle), p.workflowAuthor, p.workflowId);
        _sealIdentity(address(t.coord), p.workflowAuthor, p.workflowId);
        t.navOracle.transferOwnership(p.timelock);
        t.gate.transferOwnership(p.timelock);
        t.szip.transferOwnership(p.timelock);
        t.escrow.transferOwnership(p.timelock);
        t.coord.transferOwnership(p.timelock);

        // -- 17. Safe ownership handoff to `team` (the transient-owner cleanup) — both Safes, self -> team.
        _handoffSafe(sub.juniorTrancheSafe, p.team);
        _handoffSafe(sub.juniorTrancheSidecar, p.team);
        if (
            !ISafe(sub.juniorTrancheSafe).isOwner(p.team) || !ISafe(sub.juniorTrancheSidecar).isOwner(p.team)
                || ISafe(sub.juniorTrancheSafe).isOwner(address(this)) || ISafe(sub.juniorTrancheSidecar).isOwner(address(this))
        ) revert SafeHandoffFailed();

        t.baal = sub.baal;
        t.juniorTrancheSafe = sub.juniorTrancheSafe;
        t.juniorTrancheSidecar = sub.juniorTrancheSidecar;
    }

    // ================================================================= helpers (reimplemented; self-bound)

    /// @notice Clone a Zodiac module mastercopy + `setUp` atomically, then `enableModule` on `safe`.
    function _cloneModule(address mastercopy, bytes memory setUpData, address safe) internal returns (address proxy) {
        bytes memory initializer = abi.encodeWithSignature("setUp(bytes)", setUpData);
        proxy = IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY).deployModule(
            mastercopy, initializer, _saltNonce
        );
        _enableModuleOnSafe(safe, proxy);
    }

    /// @notice Drive `safe` (this deployer is an owner) via the pre-validated v==1 signature path to
    ///         `enableModule(module)`.
    function _enableModuleOnSafe(address safe, address module) internal {
        bytes memory data = abi.encodeWithSelector(ISafe.enableModule.selector, module);
        _execAsSelf(safe, safe, data);
    }

    /// @notice self -> juniorTrancheSafe.execTransaction -> Baal.setShamans([gate],[2]) (grant the Gate manager).
    function _setShamansManager(address baal, address juniorTrancheSafe, address gate) internal {
        address[] memory shamans = new address[](1);
        shamans[0] = gate;
        uint256[] memory perms = new uint256[](1);
        perms[0] = 2; // manager
        bytes memory setShamans = abi.encodeWithSelector(IBaal.setShamans.selector, shamans, perms);
        _execAsSelf(juniorTrancheSafe, baal, setShamans);
    }

    /// @notice Set the CRE identity (author + workflow id) on a `ReceiverTemplate` (selectors inherited from it).
    function _sealIdentity(address receiver, address workflowAuthor, bytes32 workflowId) internal {
        IReceiverIdentitySet(receiver).setExpectedAuthor(workflowAuthor);
        IReceiverIdentitySet(receiver).setExpectedWorkflowId(workflowId);
    }

    /// @notice Hand `safe` from this transient deployer owner to `team` via `swapOwner`. The `prevOwner` pointer for
    ///         `address(this)` is located by traversing `getOwners()` (do NOT assume SENTINEL_OWNERS — the summoned
    ///         Safe may carry the summoner/default owner alongside self).
    function _handoffSafe(address safe, address team) internal {
        address prevOwner = _prevOwner(safe, address(this));
        bytes memory data =
            abi.encodeWithSelector(ISafe.swapOwner.selector, prevOwner, address(this), team);
        _execAsSelf(safe, safe, data);
    }

    /// @notice Find the linked-list predecessor of `owner` in the Safe owner list (SENTINEL if `owner` is the head).
    function _prevOwner(address safe, address owner) internal view returns (address prev) {
        address[] memory owners = ISafe(safe).getOwners();
        prev = SENTINEL_OWNERS;
        for (uint256 idx = 0; idx < owners.length; idx++) {
            if (owners[idx] == owner) return prev;
            prev = owners[idx];
        }
        // owner not found — fall through (swapOwner will fail closed on a bad prevOwner; step-17 effect assert catches).
        return SENTINEL_OWNERS;
    }

    /// @notice Generic owner-driven Safe call: this deployer (an owner of `safe`) drives `safe.execTransaction(to, 0,
    ///         data)` with the 1-of-n pre-validated signature (`v==1`, msg.sender == owner == this). Same pattern as
    ///         CreditWarehouseDeployer `_execTransactionAsSelf` / SummonSubstrate `_addOwnerToJuniorTrancheSidecar`.
    function _execAsSelf(address safe, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(address(this)))), bytes32(0), uint8(1));
        ISafe(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }
}

/// @notice The `ReceiverTemplate` identity-seal surface (inherited; onlyOwner).
interface IReceiverIdentitySet {
    function setExpectedAuthor(address author) external;
    function setExpectedWorkflowId(bytes32 id) external;
}
