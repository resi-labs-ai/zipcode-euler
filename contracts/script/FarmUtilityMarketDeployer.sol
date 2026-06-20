// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

import {FarmUtilityBorrowGuard} from "../src/supply/szipUSD/FarmUtilityBorrowGuard.sol";

/// @title FarmUtilityMarketDeployer
/// @notice One-time wiring of the 8-B5 farm utility EVK market (§4.5.1), modeled on WOOF-04 `openLine` steps 1–3 with two
///         deliberate differences: (1) the GOVERNOR IS RETAINED on both the router and the borrow vault (the §17
///         standing-tunable facility — LTV/caps/oracle stay tunable by the Timelock; NOT frozen to `address(0)` like
///         WOOF-04's per-line routers), and (2) the deployer CREATES the borrow vault (oracle = the router), resolving
///         the router/borrow-vault ordering cycle (the router is built BEFORE the borrow vault). It stands up:
///         - the LP escrow collateral vault (bare 1:1 holding box),
///         - a dedicated `EulerRouter` wired `escrow → lpToken → SzipFarmUtilityLpOracle`,
///         - the `FarmUtilityBorrowGuard` (pins `OP_BORROW` to the engine Safe — security F8a),
///         - the USDC borrow vault (oracle = that router; the warehouse resting USDC vault), with the guard installed
///           at `OP_BORROW` and `setLTV(escrow, …)` accepting the escrow as collateral.
///         Returns `(escrowVault, borrowVault, router)` for the module's `setUp` + the item-10 deploy.
contract FarmUtilityMarketDeployer {
    /// @notice The EVK `OP_BORROW` op bit (`1 << 6`; EVK op bitmask).
    uint32 internal constant OP_BORROW = 1 << 6;

    /// @notice The birth-time wire-check failed: the router does not resolve `escrow → lpToken → lpOracle`.
    error WireMismatch();

    /// @notice The one-time wiring inputs (a struct to keep the call site below the stack-depth limit).
    /// @param factory The EVK GenericFactory (caller becomes vault governor via initialize).
    /// @param evc The Ethereum Vault Connector.
    /// @param governor The retained governor (the §17 TimelockController) for the router + borrow vault.
    /// @param lpToken The ICHI LP share collateral token (18-dp).
    /// @param usdc USDC (borrow asset + unit-of-account — prices 1:1, no feed).
    /// @param lpOracle The `SzipFarmUtilityLpOracle` the router resolves the LP collateral through.
    /// @param irm The interest rate model installed on the borrow vault.
    /// @param juniorTrancheEngine The szipUSD engine Safe (the guard's sole legal borrower).
    /// @param borrowLTV The borrow LTV (1e4 scale) accepting the escrow as collateral.
    /// @param liqLTV The liquidation LTV (1e4 scale).
    struct Params {
        GenericFactory factory;
        address evc;
        address governor;
        address lpToken;
        address usdc;
        address lpOracle;
        address irm;
        address juniorTrancheEngine;
        uint16 borrowLTV;
        uint16 liqLTV;
    }

    /// @notice Stand up the farm utility market. Governor RETAINED on the router + borrow vault.
    function deploy(Params calldata p)
        external
        returns (address escrowVault, address borrowVault, address router)
    {
        // step 1: escrow collateral vault (bare holding box: no oracle, no unit-of-account, no governance).
        escrowVault = p.factory.createProxy(address(0), false, abi.encodePacked(p.lpToken, address(0), address(0)));
        IEVault(escrowVault).setHookConfig(address(0), 0);
        IEVault(escrowVault).setGovernorAdmin(address(0));

        // step 2: dedicated router; wire ESCROW -> lpToken -> lpOracle. The deployer is the governor AT BIRTH (so it
        //          can configure), then HANDS GOVERNANCE TO THE TIMELOCK — RETAINED, NOT renounced to address(0)
        //          (the §4.5.1 difference from WOOF-04's `transferGovernance(address(0))`).
        {
            EulerRouter r = new EulerRouter(p.evc, address(this));
            r.govSetResolvedVault(escrowVault, true); // unwrap escrow shares -> lpToken, 1:1
            r.govSetConfig(p.lpToken, p.usdc, p.lpOracle); // price (lpToken, USDC) via the LP oracle
            router = address(r);
        }

        // step 3+4: the borrow guard (pins OP_BORROW to the engine Safe — the shared resting USDC must not be levered)
        //           then the farm utility USDC borrow vault (oracle = the router; unit-of-account = USDC -> prices 1:1).
        //           Governor RETAINED so the Timelock can tune LTV/caps. In production the EE supply queue allocates
        //           idle depositor USDC into this vault (so it IS the warehouse resting USDC vault).
        borrowVault = p.factory.createProxy(address(0), false, abi.encodePacked(p.usdc, router, p.usdc));
        IEVault(borrowVault).setInterestRateModel(p.irm);
        IEVault(borrowVault).setHookConfig(
            address(new FarmUtilityBorrowGuard(address(p.factory), p.juniorTrancheEngine)), OP_BORROW
        ); // never hook OP_REPAY
        IEVault(borrowVault).setLTV(escrowVault, p.borrowLTV, p.liqLTV, 0); // 1e4 scale; ramp 0

        // step 5: birth-time wire-check (W3): prove ESCROW -> lpToken -> lpOracle resolves.
        _assertWired(router, escrowVault, p.lpToken, p.usdc, p.lpOracle);

        // step 6: hand governance to the Timelock — RETAINED (LTV/caps/oracle/IRM stay tunable), NOT renounced. Both
        //          the router AND the borrow vault: the borrow vault was created with `createProxy(address(0), …)`
        //          (`:77`), so its governor defaults to THIS throwaway deployer instance — it MUST be re-pointed to the
        //          Timelock (§17 standing-tunable facility), else LTV/caps/IRM strand. Done AFTER all governor-gated
        //          config above (setInterestRateModel/setHookConfig/setLTV). The escrow stays renounced by design
        //          (`:61`, a no-governance holding box).
        IEVault(borrowVault).setGovernorAdmin(p.governor);
        EulerRouter(router).transferGovernance(p.governor);
    }

    /// @notice Defensive wire-check (W3): proves the router resolves `escrow -> lpToken -> lpOracle`. Not a
    ///         caller-reachable branch — `deploy` builds the wiring itself; covered by a deliberately-mis-wiring
    ///         harness subclass override.
    function _assertWired(address router, address escrowVault, address lpToken, address usdc, address lpOracle)
        internal
        view
        virtual
    {
        (, address rBase,, address rOracle) = EulerRouter(router).resolveOracle(1e18, escrowVault, usdc);
        if (rBase != lpToken || rOracle != lpOracle) revert WireMismatch();
    }
}
