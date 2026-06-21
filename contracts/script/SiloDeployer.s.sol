// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BaseAddresses} from "./BaseAddresses.sol";

import {FarmUtilityMarketDeployer} from "./FarmUtilityMarketDeployer.sol";
import {CreditWarehouseDeployer} from "./CreditWarehouseDeployer.sol";
import {JuniorTrancheDeployer} from "./JuniorTrancheDeployer.s.sol";

import {CREGatingHook} from "../src/CREGatingHook.sol";
import {EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @title SiloDeployer (CTR-06c)
/// @notice The orchestrator that composes ONE self-consistent silo out of the four verbatim sub-deployers
///         (`FarmUtilityMarketDeployer` CTR-06a, `CreditWarehouseDeployer` 8-Bw, `JuniorTrancheDeployer` CTR-06b) plus
///         the per-silo venue front (EulerEarn pool + resting `usdcReservoir` + per-silo `CREGatingHook` +
///         `EulerVenueAdapter`), and returns a `Silo` handle that maps 1:1 to `SiloRegistry.SiloConfig`. The hub
///         (`timelock`/`controller`/`oracleRegistry`/`zipUSD`/`rateOracle`/`redemptionBox`/`erebor`/`forwarder` + the shared
///         POL + EVC/EVK factory) is a deploy INPUT, never built here; only the per-silo venue + farm utility + warehouse +
///         junior are built. `claude-zipcode.md` §4.5/§4.7/§9.1/§17.
///
/// @dev `is Script` — `deploy` calls `JuniorTrancheDeployer.computeMainSafe` (a `vm`-using view), so this runs in a
///      forge `script`/`test` context like the other `.s.sol` deployers. The sub-deployer param structs are built in
///      `internal` helpers so `deploy` stays under the 16-local stack limit.
///
/// @dev THE D2 HUB-GRANT RUNBOOK (NOT script code — Timelock-owned post-deploy). Before `deploy(...)` (one-time, per
///      silo): build a `SzipFarmUtilityLpOracle` for the silo + push its first `LP_MARK` (a CRE/forwarder push the
///      deployer cannot make — `FarmUtilityMarketDeployer`'s `setLTV` `getQuote` reverts without a resolvable mark) →
///      pass as `p.lpOracle`. After `deploy(...)`, the Timelock MUST:
///        1. `zipUSD.setCapacity(silo.depositModule, type(uint128).max)` — grant the new deposit module mint authority
///           on the shared zipUSD (Timelock-owned).
///        2. `siloRegistry.addSilo(siloId, SiloConfig{from the returned handle})` — admission (passes the topology
///           assert; cannot revert `SiloMiswired` because step 8 pre-flights every clause).
///        3. `siloRegistry.setCurrentSilo(siloId)` — roll the active fill target when the prior silo hits the cap.
///      `controller.setRegistry(registry)` + `siloRegistry.setController(controller)` are the ONE-TIME HUB bring-up
///      (already wired by CTR-03 / `DeployZipcode`; NOT per-silo). Silo #0 = today's anvil deployment.
contract SiloDeployer is Script {
    /// @notice The EVK GenericFactory (Base 8453) used for the resting base USDC market.
    address internal constant EVAULT_FACTORY = BaseAddresses.EVAULT_FACTORY;
    /// @notice The Ethereum Vault Connector (Base 8453).
    address internal constant EVC = BaseAddresses.EVC;

    // ----------------------------------------------------------------- deployer-added post-asserts (fail-closed)
    /// @notice §2 non-commingling: the shared redemptionBox/queue, the warehouse Safe, and the junior Safes collide.
    error SeamCommingled();
    /// @notice The farm utility borrow vault's governor is not the Timelock (CTR-06a §17 standing-tunable facility).
    error SeamFarmUtilityGovernor();
    /// @notice An `addSilo` 6-clause pre-flight clause failed — the handle would revert `SiloMiswired` at admission.
    error SeamSiloMiswired();

    // ----------------------------------------------------------------- inputs
    struct SiloParams {
        // identity / authority (hub)
        address timelock;
        address team;
        address creOperator;
        address godOwner;
        address receiverAdmin;
        address workflowAuthor;
        // CTR-16: per-receiver workflow NAMES (the shared `workflowId` pin is dropped). The warehouse name seals
        // THIS silo's WAM (folded-in hole: silos 2+ shipped it forwarder-only); the sharefeeds + coordinator names
        // thread through to `JuniorTrancheDeployer` for the per-silo navOracle + coordinator seals.
        string workflowNameWarehouse;
        string workflowNameSharefeeds;
        string workflowNameCoordinator;
        uint256 saltNonce; // DISTINCT per silo (CREATE2 across Safe factory + Baal summoner + EVK proxies + EE salt)
        // shared hub handles (NOT built here)
        address controller;
        address oracleRegistry;
        address zipUSD;
        address rateOracle;
        address redemptionBox; // == the ONE shared ZipRedemptionQueue (D5/§6)
        address erebor;
        address forwarder;
        // shared POL (D1) + the pre-seeded farm utility LP oracle
        address polIchiVault;
        address polGauge;
        address lpOracle; // built-and-SEEDED INPUT (initial LP_MARK already pushed)
        // tokens (injectable so the D3 test feeds mocks; prod passes BaseAddresses)
        address usdc;
        address xAlphaMirror;
        address hydx;
        address oHydx;
        // IRMs
        address farmUtilityIrm;
        address lineIrm;
        // EE pool naming
        string eeName;
        string eeSymbol;
        // numeric knobs (pass-through to the sub-deployers)
        address adminSafe;
        address curatorSafe; // per-line EVK feeReceiver — curator pay (CTR-13). NB: distinct from the EE `curator` role.
        uint16 borrowLTV;
        uint16 liqLTV;
        uint32 W;
        uint256 maxAge;
        uint256 maxDeviationBps;
        uint256 tvlCap;
        uint16 dBps;
        uint256 buybackCap;
        uint256 borrowCap;
        uint256 recoveryFloor;
    }

    /// @notice The deployed silo handle. The first nine fields map 1:1 to `SiloRegistry.SiloConfig`; the trailing three
    ///         are exposed for the D2 runbook (`depositModule` = the `setCapacity` target) + observability.
    struct Silo {
        address adapter; // venue adapter (SiloConfig.adapter)
        address warehouseSafe; // SiloConfig.warehouseSafe
        address eePool; // SiloConfig.eePool
        address juniorBasket; // junior.juniorTrancheSafe (SiloConfig.juniorBasket)
        address escrow; // junior.escrow (SiloConfig.escrow)
        address defaultCoordinator; // junior.coord (SiloConfig.defaultCoordinator)
        address navOracle; // junior.navOracle (SiloConfig.navOracle)
        address freeze; // junior.durationFreeze (SiloConfig.freeze)
        address curator; // venue adapter (SiloConfig.curator — routing/label only, NOT topology-asserted)
        // -- runbook / observability (NOT part of SiloConfig) --
        address depositModule; // the D2 zipUSD.setCapacity target
        address warehouseRoles; // the warehouse Roles modifier (observability)
        address warehouseAdmin; // the per-silo WarehouseAdminModule (a CRE ReceiverTemplate — CTR-16 sealed; observability)
        address hook; // the per-silo CREGatingHook (observability)
    }

    // ================================================================= entrypoint
    /// @notice Compose one self-consistent silo. Build order is load-bearing (steps 0–9). Returns the handle the
    ///         Timelock registers via the D2 runbook. The per-step structs are built in `internal` helpers and the
    ///         venue front / cap onboarding / post-asserts are factored out so `deploy` stays under the 16-local
    ///         stack-depth limit.
    function deploy(SiloParams memory p) external returns (Silo memory s) {
        // -- 0. Precompute the junior juniorTrancheSafe (breaks the farm utility<->junior cycle). The farm utility's `juniorTrancheEngine`
        //       MUST be the junior juniorTrancheSafe (the FarmUtilityBorrowGuard pins OP_BORROW to it, IMMUTABLE). `computeMainSafe`
        //       is a pure function of saltNonce + the live Safe factory/singleton, so the precompute here EQUALS the
        //       juniorTrancheSafe `jr.deploy(...)` later summons (its `MainSafeMismatch` assert guarantees it). REUSE `jr` in
        //       step 7 so the salt + summon match.
        JuniorTrancheDeployer jr = new JuniorTrancheDeployer();

        // -- 1. EE pool (D3 seam — `_createEePool` is virtual; the test overrides it to return a MockEulerEarn).
        s.eePool = _createEePool(p);

        // -- 2. Resting usdcReservoir — a bare EVK proxy (asset=USDC, no oracle/uoa => supply-only). NOT an input.
        address usdcReservoir = GenericFactory(EVAULT_FACTORY).createProxy(
            address(0), false, abi.encodePacked(p.usdc, address(0), address(0))
        );
        IEVault(usdcReservoir).setHookConfig(address(0), 0);

        // -- 3. Farm utility market (CTR-06a-fixed). juniorTrancheEngine = the precomputed junior juniorTrancheSafe (step 0).
        (address escrowVault, address borrowVault,) =
            new FarmUtilityMarketDeployer().deploy(_farmUtilityParams(p, jr.computeMainSafe(p.saltNonce)));

        // -- 4a. EE cap onboarding (markets exist; does NOT depend on the curator).
        _onboardCaps(s.eePool, usdcReservoir, borrowVault);

        // -- 5. Per-silo CREGatingHook + EulerVenueAdapter (borrowDriver -> this silo's adapter; hook owner -> TL).
        (s.adapter, s.hook) = _deployVenueFront(p, s.eePool, usdcReservoir);

        // -- 6. Warehouse (verbatim CreditWarehouseDeployer). redemptionBox MUST be the shared queue (D5/§6).
        //       CTR-16: take TRANSIENT ownership of the WAM (a CRE ReceiverTemplate) by passing `address(this)` as
        //       `receiverAdmin`, so we can seal its identity here (the folded-in hole: silos 2+ shipped the WAM
        //       forwarder-only — DeployZipcode only sealed silo-0's). Then hand it to the real `p.receiverAdmin`.
        CreditWarehouseDeployer.Warehouse memory warehouse = new CreditWarehouseDeployer().deploy(
            p.godOwner, address(this), s.eePool, p.usdc, p.forwarder, p.redemptionBox, p.saltNonce
        );
        s.warehouseSafe = warehouse.warehouseSafe;
        s.warehouseRoles = warehouse.roles;
        s.warehouseAdmin = warehouse.adapter;
        // seal the per-silo WAM (author + the warehouse daemon's name) while this deployer owns it, then re-home it
        // to the interim receiverAdmin (preserving the as-built WAM→receiverAdmin posture).
        _sealIdentity(warehouse.adapter, p.workflowAuthor, p.workflowNameWarehouse);
        IOwnableLike(warehouse.adapter).transferOwnership(p.receiverAdmin);

        // -- 4b. EE admin config needing the warehouse Safe + venue adapter (built in steps 5–6).
        _eeCall(s.eePool, abi.encodeWithSignature("setFeeRecipient(address)", s.warehouseSafe));
        _eeCall(s.eePool, abi.encodeWithSignature("setCurator(address)", s.adapter));

        // -- 7. Junior tranche (the step-0 `jr` instance so the salt + summon match; CTR-06b). juniorTrancheEngine of the
        //       farm utility (step 3) == the juniorTrancheSafe this summons.
        JuniorTrancheDeployer.JuniorTranche memory junior =
            jr.deploy(_juniorParams(p, s.eePool, s.warehouseSafe, escrowVault, borrowVault));
        s.juniorBasket = junior.juniorTrancheSafe;
        s.escrow = address(junior.escrow);
        s.defaultCoordinator = address(junior.coord);
        s.navOracle = address(junior.navOracle);
        s.freeze = junior.durationFreeze;
        s.curator = s.adapter; // routing/label only — addSilo does NOT assert curator
        s.depositModule = address(junior.depositModule);

        // -- 8. Post-asserts (fail-closed).
        _postAsserts(p, s, junior, borrowVault);
    }

    /// @dev Step-8 fail-closed post-asserts: §2 non-commingling (deployer-added — addSilo does NOT enforce these), the
    ///      farm utility borrow-vault governor = Timelock (CTR-06a), and the `addSilo` 6-clause pre-flight (so the Timelock
    ///      `addSilo` can't revert `SiloMiswired`).
    function _postAsserts(
        SiloParams memory p,
        Silo memory s,
        JuniorTrancheDeployer.JuniorTranche memory junior,
        address borrowVault
    ) internal view {
        if (p.redemptionBox == junior.juniorTrancheSafe || s.warehouseSafe == junior.juniorTrancheSafe || s.warehouseSafe == junior.juniorTrancheSidecar) {
            revert SeamCommingled();
        }
        if (IEVault(borrowVault).governorAdmin() != p.timelock) revert SeamFarmUtilityGovernor();
        if (
            IFreeze(s.freeze).eulerEarn() != s.eePool || IFreeze(s.freeze).warehouseSafe() != s.warehouseSafe
                || IFreeze(s.freeze).navOracle() != s.navOracle
                || IEscrow(s.escrow).coordinator() != s.defaultCoordinator
                || INavWriter(s.defaultCoordinator).navOracle() != s.navOracle
                || IAdapter(s.adapter).eulerEarn() != s.eePool
        ) revert SeamSiloMiswired();
    }

    /// @dev Step-4a EE cap onboarding via the low-level `_eeCall` idiom (the EE admin ABI is NOT compiled in):
    ///      `submitCap`+`acceptCap` for both non-line markets, then point the supply queue at the resting market.
    ///      (setFeeRecipient/setCurator are step 4b — they need the warehouse Safe + venue adapter.)
    function _onboardCaps(address eePool, address usdcReservoir, address borrowVault) internal {
        uint256 capMax = type(uint136).max;
        _eeCall(eePool, abi.encodeWithSignature("submitCap(address,uint256)", usdcReservoir, capMax));
        _eeCall(eePool, abi.encodeWithSignature("acceptCap(address)", usdcReservoir));
        _eeCall(eePool, abi.encodeWithSignature("submitCap(address,uint256)", borrowVault, capMax));
        _eeCall(eePool, abi.encodeWithSignature("acceptCap(address)", borrowVault));
        address[] memory q = new address[](1);
        q[0] = usdcReservoir;
        _eeCall(eePool, abi.encodeWithSignature("setSupplyQueue(address[])", q));
    }

    /// @dev Step-5 per-silo venue front: a fresh `CREGatingHook` + `EulerVenueAdapter`, the hook's `borrowDriver` set to
    ///      THIS silo's adapter (N silos = N adapters = N hooks), and the hook owner (= this deployer) handed to the
    ///      Timelock.
    function _deployVenueFront(SiloParams memory p, address eePool, address usdcReservoir)
        internal
        returns (address adapter, address hook)
    {
        CREGatingHook h = new CREGatingHook(EVAULT_FACTORY, EVC, address(0));
        EulerVenueAdapter a = new EulerVenueAdapter(
            p.controller,
            EVC,
            eePool,
            EVAULT_FACTORY,
            p.oracleRegistry,
            address(h),
            p.lineIrm,
            p.usdc,
            p.erebor,
            usdcReservoir
        );
        a.setCuratorSafe(p.curatorSafe); // CTR-13: per-line EVK feeReceiver (deployer is adapter owner at birth)
        h.setBorrowDriver(address(a));
        h.transferOwnership(p.timelock);
        return (address(a), address(h));
    }

    // ================================================================= the D3 mock seam

    /// @notice Create the silo's EulerEarn pool. Base (fork/runbook) implementation: the live-factory `.call` idiom
    ///         (`DeployLocal.s.sol:115-122`). `initialTimelock = 0` (else the first `openLine` reverts
    ///         `EulerEarnTimelockNonZero`). The D3 test OVERRIDES this to return a `new MockEulerEarn()`.
    function _createEePool(SiloParams memory p) internal virtual returns (address eePool) {
        (bool ok, bytes memory ret) = BaseAddresses.EULER_EARN_FACTORY.call(
            abi.encodeWithSignature(
                "createEulerEarn(address,uint256,address,string,string,bytes32)",
                p.timelock, // initialOwner
                uint256(0), // initialTimelock — MUST be 0
                p.usdc,
                p.eeName,
                p.eeSymbol,
                bytes32(p.saltNonce)
            )
        );
        require(ok, "createEulerEarn failed");
        eePool = abi.decode(ret, (address));
    }

    // ================================================================= sub-deployer param helpers (stack relief)

    function _farmUtilityParams(SiloParams memory p, address juniorTrancheEngine)
        internal
        pure
        returns (FarmUtilityMarketDeployer.Params memory)
    {
        return FarmUtilityMarketDeployer.Params({
            factory: GenericFactory(EVAULT_FACTORY),
            evc: EVC,
            governor: p.timelock,
            lpToken: p.polIchiVault,
            usdc: p.usdc,
            lpOracle: p.lpOracle,
            irm: p.farmUtilityIrm,
            juniorTrancheEngine: juniorTrancheEngine,
            borrowLTV: p.borrowLTV,
            liqLTV: p.liqLTV
        });
    }

    function _juniorParams(
        SiloParams memory p,
        address eePool,
        address warehouseSafe,
        address escrowVault,
        address borrowVault
    ) internal pure returns (JuniorTrancheDeployer.JuniorParams memory) {
        return JuniorTrancheDeployer.JuniorParams({
            timelock: p.timelock,
            team: p.team,
            creOperator: p.creOperator,
            saltNonce: p.saltNonce,
            workflowAuthor: p.workflowAuthor,
            workflowNameSharefeeds: p.workflowNameSharefeeds,
            workflowNameCoordinator: p.workflowNameCoordinator,
            zipUSD: p.zipUSD,
            rateOracle: p.rateOracle,
            eePool: eePool,
            warehouseSafe: warehouseSafe,
            escrowVault: escrowVault,
            borrowVault: borrowVault,
            usdc: p.usdc,
            xAlphaMirror: p.xAlphaMirror,
            hydx: p.hydx,
            oHydx: p.oHydx,
            polIchiVault: p.polIchiVault,
            polGauge: p.polGauge,
            adminSafe: p.adminSafe,
            W: p.W,
            maxAge: p.maxAge,
            maxDeviationBps: p.maxDeviationBps,
            tvlCap: p.tvlCap,
            dBps: p.dBps,
            buybackCap: p.buybackCap,
            borrowCap: p.borrowCap,
            recoveryFloor: p.recoveryFloor
        });
    }

    // ================================================================= low-level EE admin call

    /// @dev Low-level EE admin call (the EulerEarn admin ABI is deliberately not compiled into the repo), bubbling the
    ///      inner revert reason on failure (`DeployLocal._eeCall:170-177`).
    function _eeCall(address ee, bytes memory data) internal {
        (bool ok, bytes memory ret) = ee.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev CTR-16 WAM seal: set the CRE identity (author + per-receiver workflow NAME) on a `ReceiverTemplate`.
    ///      The shared `workflowId` pin is dropped (left bytes32(0)); author goes first because `onReport` requires
    ///      the author whenever the name is set. Callable only while this deployer transiently owns the receiver.
    function _sealIdentity(address receiver, address workflowAuthor, string memory name) internal {
        IReceiverIdentitySet(receiver).setExpectedAuthor(workflowAuthor);
        IReceiverIdentitySet(receiver).setExpectedWorkflowName(name);
    }
}

// =========================================================================================== topology getters
// Minimal local interfaces for the addSilo 6-clause pre-flight (mirrors SiloRegistry.sol's IFreeze/IEscrow/
// INavWriter/IAdapter — the exact getters the admission assert dereferences).

/// @notice `DurationFreezeModule.{eulerEarn(), warehouse(), navOracle()}`.
interface IFreeze {
    function eulerEarn() external view returns (address);
    function warehouseSafe() external view returns (address);
    function navOracle() external view returns (address);
}

/// @notice `LienXAlphaEscrow.coordinator()`.
interface IEscrow {
    function coordinator() external view returns (address);
}

/// @notice `DefaultCoordinator.navOracle()`.
interface INavWriter {
    function navOracle() external view returns (address);
}

/// @notice `EulerVenueAdapter.eulerEarn()`.
interface IAdapter {
    function eulerEarn() external view returns (address);
}

/// @notice The `ReceiverTemplate` identity-seal surface (inherited; onlyOwner). CTR-16: name-posture.
interface IReceiverIdentitySet {
    function setExpectedAuthor(address author) external;
    function setExpectedWorkflowName(string calldata name) external;
}

/// @notice OZ `Ownable.transferOwnership` — used to re-home the sealed WAM to the interim receiverAdmin.
interface IOwnableLike {
    function transferOwnership(address newOwner) external;
}
