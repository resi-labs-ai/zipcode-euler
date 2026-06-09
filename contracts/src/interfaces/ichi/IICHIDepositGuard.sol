// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the ICHI Deposit Guard (deposit/withdraw forwarder).
/// Source contract: ICHIDepositGuard @ Base 0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8
/// verified on-chain 2026-06-06: forwardDepositToICHIVault selector 0x5d123e3f present in
/// deployed bytecode AND matches Basescan-verified source; forwardWithdrawFromICHIVault arg
/// order + return type CORRECTED to the verified source (was guessed wrong).
/// NOTE: the guard's hardcoded factory is ICHIVaultFactory()=0x2b52c416F723F16e883E53f3f16435B51300280a
/// (read on-chain) = BaseAddresses.ICHI_VAULT_FACTORY, NOT ICHI_ADMIN_SAFE (0x7d11…) which is a Gnosis Safe.
interface IICHIDepositGuard {
    function forwardDepositToICHIVault(
        address vault,
        address vaultDeployer,
        address token,
        uint256 amount,
        uint256 minimumProceeds,
        address to
    ) external returns (uint256 vaultTokens);

    function forwardWithdrawFromICHIVault(
        address vault,
        address vaultDeployer,
        uint256 shares,
        address to,
        uint256 minAmount0,
        uint256 minAmount1
    ) external returns (uint256 amount0, uint256 amount1);
}
