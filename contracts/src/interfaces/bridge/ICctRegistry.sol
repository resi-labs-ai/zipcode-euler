// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title Minimal local CCT admin-registry interfaces (8x-01 deploy/wire seam).
/// @notice Only the selectors `DeploySzAlphaBridge` touches, verified against
///         `reference/chainlink-ccip/chains/evm/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol`
///         and `.../interfaces/ITokenAdminRegistry.sol`.
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
}
