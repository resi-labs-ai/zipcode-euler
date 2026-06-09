// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the ICHI Vault Factory (the deployer/registry).
/// verified on-chain 2026-06-06.
/// Address constant: BaseAddresses.ICHI_VAULT_FACTORY = 0x2b52c416F723F16e883E53f3f16435B51300280a.
/// IMPORTANT: BaseAddresses.ICHI_ADMIN_SAFE (0x7d11De61c219b70428Bb3199F0DD88bA9E76bfEE) is NOT this
/// contract — that address is a Gnosis Safe v1.3.0 (getOwners() returns 7 owners, VERSION()=="1.3.0"),
/// the ICHI admin multisig. The REAL ICHI factory on Base is 0x2b52c416F723F16e883E53f3f16435B51300280a,
/// read directly from the verified DepositGuard's ICHIVaultFactory() getter on-chain.
/// Selectors confirmed against that factory's deployed bytecode + verified source:
///   createICHIVault(address,bool,address,bool) -> 0x5f715016 (FOUND)
///   getICHIVault(bytes32)                      -> 0x50309615 (FOUND, callable view)
/// The previously guessed getVault(address,address,bool,bool) / createVault(...,uint24)
/// selectors are ABSENT from the factory bytecode (wrong) and have been replaced.
interface IICHIVaultFactory {
    /// @dev vault lookup is by a bytes32 key (genKey(deployer,token0,token1,allowToken0,allowToken1)),
    ///      NOT by raw token pair. Returns address(0) if no vault for that key.
    function getICHIVault(bytes32 key) external view returns (address ichiVault);

    function createICHIVault(address tokenA, bool allowTokenA, address tokenB, bool allowTokenB)
        external
        returns (address ichiVault);

    function allVaults(uint256 index) external view returns (address ichiVault);
}
