// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title Minimal local CCT admin-registry interfaces (8x-01 deploy/wire seam).
/// @notice Only the selectors `DeploySzAlphaBridge` touches, verified against
///         `reference/chainlink-ccip/chains/evm/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol`
///         and `.../interfaces/ITokenAdminRegistry.sol`. Selectors used: `registerAdminViaGetCCIPAdmin`,
///         `acceptAdminRole`, `setPool`, `getPool`, and (SEC-03/H4) `transferAdminRole` + `getTokenConfig`
///         (the 2-step registry-admin handoff: the deploy script accepts the admin role to wire `setPool`,
///         then `transferAdminRole`s it to the durable authority, which finalizes via `acceptAdminRole`).
/// @dev Self-registration via `getCCIPAdmin` is used (NOT `registerAdminViaOwner`): the canonical
///      `BurnMintERC20` (the Base mirror) is AccessControl-based and has no `owner()`, and `SzAlpha`'s
///      `owner()` is the TimelockController from genesis — so the CCIP admin is a *separate* role
///      (`ccipAdmin`, the registrar) returned by `getCCIPAdmin()`. See `reports/8x-01-report.md`.
interface IRegistryModuleOwnerCustom {
    /// @notice Registers the admin of `token` using its `getCCIPAdmin()` method.
    /// @dev `msg.sender` must equal `IGetCCIPAdmin(token).getCCIPAdmin()`.
    function registerAdminViaGetCCIPAdmin(address token) external;
}

interface ITokenAdminRegistry {
    /// @notice Accepts the pending administrator role for `localToken` (caller == pending admin).
    function acceptAdminRole(address localToken) external;

    /// @notice Links `localToken` to its `pool` (caller == token administrator).
    function setPool(address localToken, address pool) external;

    /// @notice Returns the pool currently configured for `token` (used by the deploy asserts).
    function getPool(address token) external view returns (address);

    /// @notice Per-token registry config (mirrors `TokenAdminRegistry.TokenConfig`, same field order).
    struct TokenConfig {
        address administrator; // current registry administrator of the token
        address pendingAdministrator; // address pending acceptance of the administrator role
        address tokenPool; // the configured token pool (address(0) = delisted)
    }

    /// @notice Transfers the administrator role for `localToken` to `newAdmin` (caller == current admin).
    /// @dev 2-step: `newAdmin` must call `acceptAdminRole(localToken)` to finalize. SEC-03/H4: the deploy
    ///      script hands the registry admin to the durable authority via this call (it cannot accept on the
    ///      durable admin's behalf mid-broadcast — see the runbook in `DeploySzAlphaBridge`).
    function transferAdminRole(address localToken, address newAdmin) external;

    /// @notice Returns the full registry config for `token` (used by the deploy asserts to verify the
    ///         pending-administrator handoff target without re-reading the wrong `getCCIPAdmin()` view).
    function getTokenConfig(address token) external view returns (TokenConfig memory);
}
