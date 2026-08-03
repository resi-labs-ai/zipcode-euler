// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "../ForkConfig.sol";
import {BaseAddresses} from "../../script/BaseAddresses.sol";
import {DeployZipcode} from "../../script/DeployZipcode.s.sol";
import {DeployMainnet} from "../../script/DeployMainnet.s.sol";
import {SzipNavOracle} from "../../src/supply/SzipNavOracle.sol";
import {RecycleModule} from "../../src/supply/szipUSD/RecycleModule.sol";
import {SzipBuyBurnModule} from "../../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {LpStrategyModule} from "../../src/supply/szipUSD/LpStrategyModule.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IBaal} from "../../src/interfaces/baal/IBaal.sol";
import {ZipcodeDeployAsserts} from "../../src/ZipcodeDeployAsserts.sol";

import {
    MockERC20,
    MockLpOracle,
    MockXAlphaToken,
    MockEulerEarn,
    MockLpToken,
    MockGauge,
    ZeroIRM
} from "./JuniorTrancheDeployer.t.sol";

/// @title DeployZipcodeFork.t.sol — the deploy bar for `script/DeployZipcode.s.sol`
/// @notice `DeployZipcode` had only ever had a green `forge build`, which its own scaffold called "the authoring
///         bar". Every seam assert inside it, including the two added 2026-08-03
///         (`SeamRecycleCoordinator`, `SeamEngineNotSafe`), was unexecuted code. This suite runs the whole phase
///         sequence P0→P9 on a Base fork and asserts the post-state.
///
/// @dev  Two things had made it untestable, both about the wrapper rather than the work, and both are now fixed on
///       the script: it read inputs from the environment, and it wrapped the phases in `vm.startBroadcast()`, under
///       which `msg.sender` is the broadcaster rather than the caller — while the Safe pre-validated `v == 1` path
///       needs `msg.sender == TEAM_MULTISIG`, which a test supplies with `vm.prank`. `deployWith(Inputs)` injects
///       and does not broadcast; `deploy()` keeps its exact production behaviour; both share `_runPhases()`, so the
///       ORDER proven here cannot drift from the order production runs.
///
/// @dev  STAND-INS, and what that costs. The mock set is reused verbatim from `JuniorTrancheDeployer.t.sol`, which
///       already drives the same substrate green against the live EVK factory. The farm-utility market, the EVK
///       vaults, the router, the Safes and Baal are all REAL on the fork. What is mocked is the token leaves and
///       the LP oracle. The LP oracle in particular cannot be real here: `AlgebraIchiFairLpOracle` needs a live
///       Algebra pool with a warmed-up plugin, and the pair is zipUSD/xALPHA whose zipUSD this script is in the
///       middle of deploying. So this proves the WIRING and the SEAMS, not the Algebra math, which has its own
///       suite.
/// @dev The two Algebra faces the fair-LP TWAP readiness gate touches. `DeployZipcode` calls
///      `setLpTwapWindow`, which asserts the pool's plugin exists and is initialized — a real deploy-sequencing
///      precondition (the ICHI pool must be live and warmed up first). `JuniorTrancheDeployer` skips that call
///      and keeps the LP leg on spot, which is why its mock set stops short of these.
contract MockAlgebraPlugin {
    function isInitialized() external pure returns (bool) {
        return true;
    }
}

contract MockAlgebraPool {
    address public plugin;

    constructor(address plugin_) {
        plugin = plugin_;
    }
}

abstract contract DeployZipcodeForkHarness is ForkConfig {
    DeployZipcode internal dep;

    address internal team = makeAddr("teamMultisig");
    address internal godOwner = makeAddr("godOwner");
    address internal creOperator = makeAddr("creOperator");
    address internal workflowAuthor = makeAddr("workflowAuthor");
    address internal erebor = makeAddr("erebor");
    address internal adminSafe = makeAddr("adminSafe");
    address internal curatorSafe = makeAddr("curatorSafe");

    MockXAlphaToken internal xAlpha;
    MockEulerEarn internal eePool;
    MockLpToken internal lp;
    MockGauge internal gauge;
    ZeroIRM internal irm;
    MockLpOracle internal lpOracle;
    MockERC20 internal usdcStandIn;

    function _standIns() internal {
        xAlpha = new MockXAlphaToken(18);
        eePool = new MockEulerEarn();
        lp = new MockLpToken();
        gauge = new MockGauge(BaseAddresses.OHYDX);
        irm = new ZeroIRM();
        usdcStandIn = new MockERC20(6);
        // The ICHI legs `LpStrategyModule.setUp` reads live off the vault. token1 must be the LP oracle's quote.
        lp.setTokens(address(xAlpha), BaseAddresses.USDC);
        lp.setPool(address(new MockAlgebraPool(address(new MockAlgebraPlugin()))));
        lpOracle = new MockLpOracle(address(lp), BaseAddresses.USDC, 1e6); // $1.00/share so setLTV's getQuote resolves
    }

    function _inputs() internal view returns (DeployZipcode.Inputs memory) {
        return DeployZipcode.Inputs({
            team: team,
            godOwner: godOwner,
            saltNonce: 1,
            creOperator: creOperator,
            erebor: erebor,
            irm: address(irm),
            lineIrm: address(irm),
            xAlphaMirror: address(xAlpha),
            polIchiVault: address(lp),
            polGauge: address(gauge),
            adminSafe: adminSafe,
            curatorSafe: curatorSafe,
            workflowAuthor: workflowAuthor,
            workflowNameController: "zip-controller",
            workflowNameRevaluation: "zip-revaluation",
            workflowNameCoordinator: "zip-coordinator",
            workflowNameSharefeeds: "zip-sharefeeds",
            workflowNameWarehouse: "zip-warehouse",
            workflowNameRate: "zip-szalpha-rate",
            eePool: address(eePool),
            usdcReservoir: address(usdcStandIn),
            validityWindow: 31_536_000,
            lpTwapWindow: 3600,
            lpOracleOverride: address(lpOracle),
            W: 3600,
            maxAge: 86_400,
            tvlCap: 100_000_000e18,
            recoveryFloor: 0.5e18,
            borrowCap: 1_000_000e6,
            borrowLTV: 8000,
            liqLTV: 9000,
            dBps: 100,
            buybackCap: 1_000_000e18,
            rateMaxStaleness: 6 hours,
            rateWindow: 30 days,
            rateAprCap: 50_000,
            rateTwapWindow: 24 hours
        });
    }
}

contract DeployZipcodeForkTest is DeployZipcodeForkHarness {
    DeployZipcode.Deployment internal D;

    function setUp() public {
        _selectBaseFork();
        _standIns();
        dep = new DeployZipcode();

        // THE SIGNER PROBLEM, and why `team` is the script here. The Safe pre-validated `v == 1` path requires
        // `msg.sender` to be an owner. Under `forge script --broadcast` that holds trivially, because broadcast
        // decomposes the phases into separate transactions each sent FROM the broadcaster EOA, so the Safe sees
        // the team multisig. Inside a test the whole thing is one call stack, so the Safe sees the script
        // contract and rejects the signature with GS025 — a `vm.prank` cannot help, since it only rewrites the
        // sender of the test's own call, not of the nested ones the script makes.
        // The fix is the deploy-as-self / sign-as-self idiom `JuniorTrancheDeployer` already uses in production:
        // the deployer summons the Safes as their own transient owner. Passing the script as `team` makes it the
        // signer for every `execTransaction` in the run. What that does NOT cover is the final owner handoff to a
        // real multisig, which stays a production-only step.
        DeployZipcode.Inputs memory inputs = _inputs();
        inputs.team = address(dep);
        dep.deployWith(inputs);
        D = dep.getDeployment();
    }

    /// @notice The bar: the whole phase sequence executes. If `setUp` did not revert, it did.
    function test_deploy_executes_end_to_end() public view {
        assertTrue(address(D.timelock) != address(0), "timelock deployed");
        assertTrue(address(D.navOracle) != address(0), "nav oracle deployed");
        assertTrue(D.recycle != address(0), "engine modules cloned");
    }

    /// @notice The two seam asserts added 2026-08-03. Both were unexecuted until now: the script would have
    ///         compiled and deployed with either one violated.
    function test_seams_added_2026_08_03_hold() public view {
        assertEq(
            D.navOracle.juniorTrancheEngine(),
            D.navOracle.juniorTrancheSafe(),
            "SeamEngineNotSafe: engine and safe are one address"
        );
        assertEq(D.coord.recycleModule(), D.recycle, "SeamRecycleCoordinator: the coordinator names the module");
    }

    /// @notice The engine trio: buy-burn, gate and NAV oracle must all name the same engine Safe, and the
    ///         buy-burn module's Zodiac exec pointers must match it or every post/cancel reverts at CoW's owner check.
    function test_engine_trio_and_avatar() public view {
        address engine = D.navOracle.juniorTrancheEngine();
        assertEq(SzipBuyBurnModule(D.buyBurn).juniorTrancheEngine(), engine, "buyBurn engine");
        assertEq(D.gate.juniorTrancheEngine(), engine, "gate engine");
        assertEq(SzipBuyBurnModule(D.buyBurn).avatar(), engine, "buyBurn avatar");
        assertEq(SzipBuyBurnModule(D.buyBurn).target(), engine, "buyBurn target");
    }

    /// @notice One-bank seam: the recycle module and the deposit module must point at the same senior pool and
    ///         warehouse, or free value and deposits land in different banks.
    function test_one_bank_seam() public view {
        assertEq(RecycleModule(D.recycle).eePool(), address(eePool), "recycle bank");
        assertEq(RecycleModule(D.recycle).eePool(), D.depositModule.eePool(), "same bank as deposits");
        assertEq(
            RecycleModule(D.recycle).warehouseSafe(), D.depositModule.warehouseSafe(), "same warehouse as deposits"
        );
        assertEq(RecycleModule(D.recycle).navOracle(), address(D.navOracle), "same oracle");
    }

    /// @notice Shared-LP seam: the LP strategy's vault and the farm-utility escrow's asset are the same token, or
    ///         collateral posted on one side is invisible to the other.
    function test_shared_lp_seam() public view {
        assertEq(LpStrategyModule(D.lpStrategy).ichiVault(), address(lp), "lp strategy vault");
        assertEq(IEVault(D.escrowVault).asset(), address(lp), "escrow asset is the same LP");
    }

    /// @notice Non-commingling: the junior Safes and the warehouse Safe must be distinct addresses (Key req 5).
    function test_warehouse_not_commingled() public view {
        assertTrue(D.warehouse.warehouseSafe != D.sub.juniorTrancheSafe, "warehouse != junior safe");
        assertTrue(D.warehouse.warehouseSafe != D.sub.juniorTrancheSidecar, "warehouse != sidecar");
        assertTrue(D.sub.juniorTrancheSafe != D.sub.juniorTrancheSidecar, "safe != sidecar");
    }

    /// @notice Baal shares stay zero forever (the ratified two-token junior: soulbound Loot, no Shares), and the
    ///         gate holds the share token.
    function test_baal_shares_zero_and_gate_wired() public view {
        assertEq(IBaal(D.sub.baal).totalShares(), 0, "Baal shares are zero by design");
        assertEq(D.gate.shareToken(), address(D.szip), "gate share token");
        assertTrue(D.navOracle.shareToken() != address(0), "nav share token wired");
    }

    /// @notice Build-phase posture: everything is Timelock-owned and NOTHING is renounced, so every slot stays
    ///         re-pointable until the pre-production lock-down.
    function test_ownership_handed_to_timelock_and_nothing_renounced() public view {
        assertEq(D.navOracle.owner(), address(D.timelock), "nav oracle owner");
        assertEq(D.coord.owner(), address(D.timelock), "coordinator owner");
        assertTrue(D.navOracle.owner() != address(0), "not renounced");
        assertTrue(D.coord.owner() != address(0), "not renounced");
    }

    /// @notice The rate oracle deploys with the twapWindow argument added 2026-08-03, and serves the smoothed
    ///         value rather than the raw one. This is the contract going to Base first.
    function test_rate_oracle_deployed_with_twap_window() public view {
        assertEq(D.rateOracle.twapWindow(), 24 hours, "twapWindow wired from inputs");
        assertEq(D.rateOracle.exchangeRate(), 0, "unseeded reads zero; fresh() is the consumer gate");
    }
}

/// @notice The identity pre-gate as a TESTED NEGATIVE. `requireIdentityWired` is the fail-closed S11 gate: every
///         receiver must carry BOTH an author and a per-receiver workflowName before the deploy is allowed to
///         finish. A gate that has only ever been observed passing is not evidence of anything, so this drives the
///         same deploy with one workflowName blanked and requires the revert.
contract DeployZipcodeIdentityGateForkTest is DeployZipcodeForkHarness {
    function setUp() public {
        _selectBaseFork();
        _standIns();
        dep = new DeployZipcode();
    }

    function test_identity_pregate_reverts_when_a_workflow_name_is_unset() public {
        DeployZipcode.Inputs memory inputs = _inputs();
        inputs.team = address(dep);
        inputs.workflowNameController = ""; // the one field the gate is meant to catch

        // Decode the selector rather than using a bare `expectRevert`, which passes on ANY revert and would let a
        // deploy broken for an unrelated reason masquerade as the gate working. The error carries the offending
        // receiver, a CREATE address not worth pinning, so match the selector prefix only.
        (bool ok, bytes memory ret) = address(dep).call(abi.encodeCall(DeployZipcode.deployWith, (inputs)));
        assertFalse(ok, "an unsealed receiver must fail the deploy closed");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        assertEq(
            sel,
            ZipcodeDeployAsserts.ReceiverIdentityNotWired.selector,
            "the S11 identity pre-gate is what reverted, not something incidental"
        );
    }

    /// @dev The positive control for the negative above: the SAME inputs with the name restored complete. Without
    ///      this, the revert test would pass just as happily against a deploy broken for some unrelated reason.
    function test_identity_pregate_passes_when_every_name_is_set() public {
        DeployZipcode.Inputs memory inputs = _inputs();
        inputs.team = address(dep);
        dep.deployWith(inputs);
        assertTrue(address(dep.getDeployment().navOracle) != address(0), "the control deploy completes");
    }
}

/// @notice THE PRODUCTION PATH. `DeployMainnet` — not `DeployZipcode` — is what actually runs against Base: it
///         provisions the EVK reservoir and creates a REAL EulerEarn pool off the live factory, runs the same
///         phases, then executes the curator config (fee recipient, caps, supply queue, curator handoff to the
///         adapter). None of that had ever executed either.
///
/// @dev  Why this matters more than the `DeployZipcode` suite above: `EulerVenueAdapter.fund` moves cash by
///       calling `reallocate` on the EE pool, against the pool's own tracked position. A hand-written EE mock
///       proves the controller's orchestration and nothing about that, and the EE admin ABI is deliberately not
///       compiled in this repo. Creating the pool for real on a fork is the only way to exercise it.
///
/// @dev  Still stood in for: the ICHI vault and gauge, because the pair is zipUSD/xALPHA and this script deploys
///       the zipUSD; and the LP oracle, for the same reason. Everything else here is live Base infrastructure.
contract DeployMainnetForkTest is DeployZipcodeForkHarness {
    DeployMainnet internal main;
    DeployZipcode.Deployment internal D;
    address internal eeAddr; // the REAL EulerEarn pool this run created

    function setUp() public {
        _selectBaseFork();
        _standIns();
        main = new DeployMainnet();

        DeployZipcode.Inputs memory inputs = _inputs();
        inputs.team = address(main); // deploy-as-self / sign-as-self, see the DeployZipcode suite above
        // Zeroed so `_provisionStandins` builds the REAL ones off the live factories.
        inputs.eePool = address(0);
        inputs.usdcReservoir = address(0);
        inputs.irm = address(0);
        inputs.xAlphaMirror = address(0);

        main.runMainnetWith(inputs);
        D = main.getDeployment();
        eeAddr = RecycleModule(D.recycle).eePool(); // the pool the run created, read back off a wired module
    }

    function test_mainnet_path_executes_with_a_real_euler_earn_pool() public view {
        assertTrue(address(D.navOracle) != address(0), "phases ran");
        assertTrue(D.escrowVault != address(0), "farm utility market built off the live EVK factory");
    }

    /// @notice The curator config is the step `DeployZipcode` leaves as a TODO and `DeployMainnet` owns. If the
    ///         adapter is not the curator, `openLine` cannot onboard per-line vaults and `fund` cannot reallocate,
    ///         so origination fails on the first real line rather than at deploy.
    function test_euler_earn_curator_is_the_adapter() public view {
        // Read the pool directly. The EE admin ABI is not compiled here by design, so this is a raw staticcall
        // against the same signature `_configureEulerEarn` writes with.
        (bool ok, bytes memory ret) = eeAddr.staticcall(abi.encodeWithSignature("curator()"));
        assertTrue(ok, "curator() readable on the real pool");
        assertEq(abi.decode(ret, (address)), address(D.adapter), "adapter is the EE curator");

        (bool okQ, bytes memory retQ) = eeAddr.staticcall(abi.encodeWithSignature("supplyQueueLength()"));
        assertTrue(okQ, "supplyQueueLength() readable");
        assertEq(abi.decode(retQ, (uint256)), 1, "supply queue points at the resting reservoir only");
    }

    /// @notice The seams added 2026-08-03 hold on the production path too, not just the injected-pool one.
    function test_seams_hold_on_the_production_path() public view {
        assertEq(D.navOracle.juniorTrancheEngine(), D.navOracle.juniorTrancheSafe(), "engine == safe");
        assertEq(D.coord.recycleModule(), D.recycle, "coordinator names the recycle module");
    }
}
