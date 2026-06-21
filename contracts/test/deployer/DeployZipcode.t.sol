// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "../ForkConfig.sol";
import {BaseAddresses} from "../../script/BaseAddresses.sol";
import {DeployZipcode} from "../../script/DeployZipcode.s.sol";

/// @title DeployZipcode.t.sol — item-10 deploy/wiring FORK-EXECUTION harness (SCAFFOLD)
/// @notice Runnable skeleton for the NEXT window. The deploy orchestrator
///         (`script/DeployZipcode.s.sol`) currently has a GREEN `forge build` (the authoring bar) but has
///         NEVER executed. This harness is where it earns the deploy bar: a Base-fork run of `deploy()` whose
///         Phase-S post-state holds, whose identity pre-gate reverts when unset, and through which an L4
///         origination succeeds. The three tests below are `vm.skip(true)` (skeleton — they compile + run as
///         SKIPPED) until the next window wires the stand-ins and removes the skips.
///
/// @dev WHAT THE NEXT WINDOW MUST DO to turn the skips green (see also `tickets/woof/WOOF-10-deploy-wiring.md`
///      "Done when" + PROGRESS NEXT):
///        1. STAND-INS (the `(T)` env inputs) — deploy/point real-or-mock contracts on the fork:
///           - EE_POOL: create the USDC EulerEarn pool off the LIVE `EULER_EARN_FACTORY` (curator timelock 0),
///             then run the EE admin config the script omits (the IEulerEarn-shim gap): `setIsAllocator(adapter)`,
///             `setCurator(adapter)`, `setFeeRecipient(warehouse.safe)`, `setFee(0.5e18)`, and point the supply
///             queue at the farm utility `borrowVault`. (Obligations 311/333 — fork-only.)
///           - USDC_RESERVOIR: a no-borrow USDC EVault at the supply-queue head (via `EVAULT_FACTORY`).
///           - XALPHA_MIRROR: an ERC20 stand-in (NavOracle reads `balanceOf`; SellModule swaps it).
///           - POL_ICHI_VAULT + POL_GAUGE: an ICHI-vault + Hydrex-gauge stand-in (the shared-LP seam keys off
///             the vault; the farm utility escrow `asset()` must equal it). OTC-whitelist-gated in prod.
///           - IRM: a real Base IRM (or a mock) for the farm utility borrow vault.
///        2. BROADCASTER: `deploy()` calls `vm.startBroadcast()` and the Safe pre-validated `v==1` path needs
///           `msg.sender == TEAM_MULTISIG`. In a TEST, either drive via `vm.prank(team)` + a non-broadcast deploy
///           variant, or fund + `vm.startBroadcast(teamPk)`. (May warrant a test-only `_deployWith(Inputs)`
///           entrypoint on the script so inputs are injected, not env-read — a small, low-risk refactor.)
///        3. ASSERTABILITY: the script's `Deployment d` handle is `internal`. Add a `getDeployment()` view (or
///           parse the deploy logs) so the post-state seams are readable from here.
///        4. `deal()` USDC to LP actors for the L4 origination trace (audit/2.md S12 + L4).
abstract contract DeployZipcodeForkBase is ForkConfig {
    DeployZipcode internal dep;

    address internal team;
    address internal godOwner;
    address internal creOperator;
    address internal workflowAuthor;
    address internal erebor;
    address internal adminSafe;

    function setUp() public virtual {
        _selectBaseFork();

        // Principals (EOAs we control in the test).
        team = makeAddr("team");
        godOwner = makeAddr("godOwner");
        creOperator = makeAddr("creOperator");
        workflowAuthor = makeAddr("workflowAuthor");
        erebor = makeAddr("erebor");
        adminSafe = makeAddr("adminSafe");

        _setDeployEnv();
        dep = new DeployZipcode();
    }

    /// @dev Set every env key `DeployZipcode._loadInputs()` reads. Address `(T)` stand-ins are placeholder
    ///      `makeAddr`s here — the next window REPLACES them with real/mock fork contracts (see the class NatSpec),
    ///      else `deploy()` reverts (e.g. `ExitGate` calls `IBaal`, the farm utility deployer calls the live EVK
    ///      factory, `SzipNavOracle` zero-checks its token args).
    function _setDeployEnv() internal {
        // principals
        vm.setEnv("TEAM_MULTISIG", vm.toString(team));
        vm.setEnv("GOD_OWNER", vm.toString(godOwner));
        vm.setEnv("CRE_OPERATOR", vm.toString(creOperator));
        vm.setEnv("WORKFLOW_AUTHOR", vm.toString(workflowAuthor));
        // CTR-16: per-receiver workflow NAMES (the dropped `WORKFLOW_ID` pin); each non-empty so the reworked
        // author+name identity pre-gate passes.
        vm.setEnv("WORKFLOW_NAME_CONTROLLER", "zip-controller");
        vm.setEnv("WORKFLOW_NAME_REVALUATION", "zip-revaluation");
        vm.setEnv("WORKFLOW_NAME_COORDINATOR", "zip-coordinator");
        vm.setEnv("WORKFLOW_NAME_SHAREFEEDS", "zip-sharefeeds");
        vm.setEnv("WORKFLOW_NAME_WAREHOUSE", "zip-warehouse");
        vm.setEnv("WORKFLOW_NAME_RATE", "zip-szalpha-rate");
        vm.setEnv("EREBOR", vm.toString(erebor));
        vm.setEnv("ADMIN_SAFE", vm.toString(adminSafe));
        vm.setEnv("SUMMON_SALT_NONCE", vm.toString(uint256(1)));

        // (T) stand-ins — REPLACE with real/mock fork contracts before un-skipping.
        vm.setEnv("IRM", vm.toString(makeAddr("STANDIN_irm")));
        vm.setEnv("XALPHA_MIRROR", vm.toString(makeAddr("STANDIN_xAlphaMirror")));
        vm.setEnv("POL_ICHI_VAULT", vm.toString(makeAddr("STANDIN_polIchiVault")));
        vm.setEnv("POL_GAUGE", vm.toString(makeAddr("STANDIN_polGauge")));
        vm.setEnv("EE_POOL", vm.toString(makeAddr("STANDIN_eePool")));
        vm.setEnv("USDC_RESERVOIR", vm.toString(makeAddr("STANDIN_usdcReservoir")));

        // numeric knobs (mirror .env.example)
        vm.setEnv("VALIDITY_WINDOW", vm.toString(uint256(31_536_000)));
        vm.setEnv("NAV_W", vm.toString(uint256(3600)));
        vm.setEnv("NAV_MAX_AGE", vm.toString(uint256(86_400)));
        vm.setEnv("NAV_MAX_DEVIATION_BPS", vm.toString(uint256(1000)));
        vm.setEnv("TVL_CAP", vm.toString(uint256(100_000_000e18)));
        vm.setEnv("RECOVERY_FLOOR", vm.toString(uint256(0.5e18)));
        vm.setEnv("BORROW_CAP", vm.toString(uint256(1_000_000e6)));
        vm.setEnv("BORROW_LTV", vm.toString(uint256(8000)));
        vm.setEnv("LIQ_LTV", vm.toString(uint256(9000)));
        vm.setEnv("BUYBURN_DBPS", vm.toString(uint256(100)));
        vm.setEnv("BUYBACK_CAP", vm.toString(uint256(1_000_000e18)));
        // SzAlphaRateOracle immutables — the 8x-02 doc+test fixtures (6h / 30d / 500%).
        vm.setEnv("RATE_MAX_STALENESS", vm.toString(uint256(6 hours)));
        vm.setEnv("RATE_WINDOW", vm.toString(uint256(30 days)));
        vm.setEnv("RATE_APR_CAP", vm.toString(uint256(50_000)));
    }
}

contract DeployZipcodeForkTest is DeployZipcodeForkBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Phase-S post-state: deploy on a fork, assert the 8 cross-cutting seams hold.
    /// TODO(next window): replace the stand-ins, drive as `team`, expose `getDeployment()`, then assert:
    ///   - controller.venue()==adapter; registry.controller()==controller
    ///   - IBaal(sub.baal).totalShares()==0; gate.shareToken()==szip
    ///   - RecycleModule one-bank trio; LpStrategy/escrow shared-LP; buyBurn/gate/navOracle juniorTrancheEngine trio
    ///   - escrow.coordinator()==coord; navOracle.shareToken()!=0; warehouse.safe != sub.juniorTrancheSafe
    ///   - every ReceiverTemplate owner()==timelock (post-seal); nothing renounced (owner()!=address(0))
    function test_phaseS_postState() public {
        vm.skip(true); // SCAFFOLD — un-skip once the stand-ins + broadcaster + getDeployment() are wired.
        // vm.prank(team); dep.deploy();
        // ... seam assertions here ...
    }

    /// @notice The identity pre-gate is a TESTED NEGATIVE: sealing with a per-receiver workflowName unset (or the
    ///   author unset) MUST revert (CTR-16 author+name posture). The focused unit proof lives in
    ///   `ZipcodeDeployIdentityGate.t.sol`; this fork-level negative is the integration echo.
    /// TODO(next window): run the deploy up to P9 with e.g. WORKFLOW_NAME_CONTROLLER="" and assert
    ///   `ZipcodeDeployAsserts.requireIdentityWired` reverts `ReceiverIdentityNotWired` (not just "didn't seal").
    function test_identityPregate_revertsWhenUnset() public {
        vm.skip(true); // SCAFFOLD
        // vm.setEnv("WORKFLOW_NAME_CONTROLLER", "");
        // vm.prank(team); vm.expectRevert(); dep.deploy();
    }

    /// @notice L4 origination end-to-end against the deployed system (audit/2.md S12 + L4): fund LP, push a CRE
    ///   origination report, assert the line opens + draws on a live EVK borrow.
    /// TODO(next window): this is the deploy bar. Needs the full fork deploy green first.
    function test_L4_origination() public {
        vm.skip(true); // SCAFFOLD
        // deal(BaseAddresses.USDC, lpA, 1_000_000e6); ... onReport(origination) ... assert debt/seed/draw ...
    }
}
