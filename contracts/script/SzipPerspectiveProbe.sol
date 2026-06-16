// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEulerEarnFactory} from "euler-earn/interfaces/IEulerEarnFactory.sol";

/// @title SzipPerspectiveProbe
/// @notice SEC-08 (kill-list M6) deploy-time guardrail: build a throwaway vault with the SAME shape `openLine` mints
///         for a credit line, then assert the EulerEarn factory's CONFIGURED perspective accepts it
///         (`isStrategyAllowed`). `openLine` onboards each line vault via a same-tx `submitCap`+`acceptCap`, both of
///         which require `IEulerEarnFactory(creator).isStrategyAllowed(id) = perspective.isVerified(id) || isVault[id]`
///         (`EulerEarnFactory.sol:76-77`). A line vault is an EVK-`GenericFactory` proxy (not EE-factory-created), so
///         `isVault` is false — it MUST pass the perspective.
///
///         NOTE on the live gate: the EE factory's currently-configured perspective is `EVKFactoryPerspective`, whose
///         `isVerified(v) = vaultFactory.isProxy(v)` — PROVENANCE-ONLY (it does NOT inspect IRM / hook / governor /
///         oracle). So today this probe is a provenance pass and the custom line-vault config is invisible to the gate.
///         Its real value is guarding a FUTURE perspective swap: `setPerspective` is EE-factory-OWNER-settable (the
///         owner is external), and a config-inspecting successor (e.g. `EulerUngovernedPerspective`, which requires
///         `governorAdmin==0` + `hookTarget==0`) would REJECT the governed+hooked line vault and brick origination.
///         Built identically to `openLine`, this probe makes that regression fail LOUDLY at deploy instead of as an
///         opaque mid-origination revert. It probes the EXTERNAL EE factory's gate — NOT a protocol-owned perspective
///         (§17 "perspectives dropped entirely" governs the protocol's own design, not external EE infra).
///
///         A standalone CONTRACT (NOT a library) so the vault-building runs in THIS instance's context — `address(this)`
///         is the probe contract (the per-line market governor at birth), exactly as `ReservoirMarketDeployer` is for
///         the reservoir market. A library would inline into the ephemeral deploy script, and `forge script --broadcast`
///         rejects a script's `address(this)` being baked into deployed state ("Script contracts are ephemeral...").
contract SzipPerspectiveProbe {
    // EVK op bitmask constants — MUST match EulerVenueAdapter (`EulerVenueAdapter.sol:27-28`).
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_LIQUIDATE = 1 << 11;

    /// @notice The EE factory's configured perspective rejects a vault built like `openLine`'s line vault — origination
    ///         is structurally bricked (back-pressure / design obligation), not just a missing assert.
    error LineVaultPerspectiveRejected(address probe, address factory);

    /// @notice Build a throwaway vault with the SAME shape `openLine` mints (steps 1/2/3/6), then assert the EE
    ///         factory's perspective accepts it. Reverts `LineVaultPerspectiveRejected` if not.
    /// @dev Runs in the CALLER's context (library `internal`), so the caller is the per-line market governor at birth
    ///      — exactly as the adapter is in `openLine`. The probe omits `openLine` step-0 (LineAccount), step-4 (EE
    ///      onboarding — the thing being guarded), step-5 (collateral deposit), and step-7 (`_assertWired`, which would
    ///      resolve `getQuote` on an unseeded throwaway lien); none affect the perspective, which inspects the borrow
    ///      vault, not those legs.
    /// @param factory The EVK `GenericFactory` (the adapter's `eVaultFactory`).
    /// @param eulerEarn The EE pool; its `creator()` is the factory whose perspective gates `isStrategyAllowed`.
    /// @param evc The Ethereum Vault Connector (the per-line router's EVC).
    /// @param usdc USDC (borrow asset + unit-of-account — prices 1:1, no feed).
    /// @param oracleRegistry The shared `ZipcodeOracleRegistry` the per-line router prices the lien through.
    /// @param irm The interest rate model `openLine` installs on every borrow vault.
    /// @param gatingHook The `CREGatingHook` `openLine` installs at `OP_BORROW | OP_LIQUIDATE`.
    /// @param probeLien A throwaway 18-dp token standing in for the runtime `lienToken` (the perspective never resolves
    ///        the oracle, so the choice does not affect the result — the lien only shapes the escrow + router config).
    function assertLineVaultAllowed(
        GenericFactory factory,
        address eulerEarn,
        address evc,
        address usdc,
        address oracleRegistry,
        address irm,
        address gatingHook,
        address probeLien
    ) external returns (address probe) {
        address fac = _creatorOf(eulerEarn);
        probe = buildLineVaultShape(factory, evc, usdc, oracleRegistry, irm, gatingHook, probeLien);
        if (!IEulerEarnFactory(fac).isStrategyAllowed(probe)) revert LineVaultPerspectiveRejected(probe, fac);
    }

    /// @notice Build the per-line vault SHAPE. MUST MIRROR `EulerVenueAdapter.openLine` steps 1/2/3/6
    ///         (`EulerVenueAdapter.sol:205-243`). If `openLine`'s vault construction changes, update this in lockstep
    ///         (SEC-08 / kill-list M6) — the probe is only meaningful while it matches what `openLine` actually builds.
    function buildLineVaultShape(
        GenericFactory factory,
        address evc,
        address usdc,
        address oracleRegistry,
        address irm,
        address gatingHook,
        address probeLien
    ) internal returns (address evault) {
        // step 1: escrow collateral vault (bare holding box: no oracle, no unit-of-account, no governance).
        address collat = factory.createProxy(address(0), false, abi.encodePacked(probeLien, address(0), address(0)));
        IEVault(collat).setHookConfig(address(0), 0);
        IEVault(collat).setGovernorAdmin(address(0));

        // step 2: dedicated per-line router; wire COLLAT -> lien -> registry (the caller is governor at birth).
        EulerRouter router = new EulerRouter(evc, address(this));
        router.govSetResolvedVault(collat, true);
        router.govSetConfig(probeLien, usdc, oracleRegistry);

        // step 3: isolated USDC borrow vault (oracle = this router; unit-of-account = USDC). Custom IRM + the gating
        //         hook at OP_BORROW | OP_LIQUIDATE; governor RETAINED (only the router is frozen, step 6) — the exact
        //         shape the EE perspective must accept.
        evault = factory.createProxy(address(0), false, abi.encodePacked(usdc, address(router), usdc));
        IEVault(evault).setInterestRateModel(irm);
        IEVault(evault).setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE);

        // step 6: freeze the router — the wiring is now immutable (matches `openLine:243`).
        router.transferGovernance(address(0));
    }

    /// @dev Reach the EE pool's factory via `creator()` (low-level — DeployLocal keeps the EE admin ABI uncompiled).
    function _creatorOf(address eulerEarn) private view returns (address) {
        (bool ok, bytes memory ret) = eulerEarn.staticcall(abi.encodeWithSignature("creator()"));
        require(ok && ret.length >= 32, "SEC08: creator() failed");
        return abi.decode(ret, (address));
    }
}
