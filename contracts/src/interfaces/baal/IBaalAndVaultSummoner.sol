// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Baal higher-order summoner that produces a Baal DAO + main
/// Safe + a non-ragequittable juniorTrancheSidecar ("vault") Safe in one flow.
/// Source contract: BaalAndVaultSummoner @ Base 0x2eF2fC8a18A914818169eFa183db480d31a90c5D.
/// VERIFIED 2026-06-07 against reference/Baal/contracts/higherOrderFactories/BaalAndVaultSummoner.sol:
///   summonBaalAndVault(bytes,bytes[],uint256,bytes32,string) -> (daoAddress, vaultAddress)  (L62-76)
///     daoAddress = the Baal; vaultAddress = the juniorTrancheSidecar (summonVault -> deployAndSetupSafe(dao), L79-87).
///   vaultIdx() public counter (L22, incremented before store at L150) ; vaults(uint256) struct (L24-31).
interface IBaalAndVaultSummoner {
    function summonBaalAndVault(
        bytes calldata initializationParams,
        bytes[] calldata initializationActions,
        uint256 saltNonce,
        bytes32 referrer,
        string calldata name
    ) external returns (address daoAddress, address vaultAddress);

    function vaultIdx() external view returns (uint256);

    /// @dev The Vault registry struct (BaalAndVaultSummoner.sol:24-31): id, active, daoAddress, vaultAddress, name.
    function vaults(uint256 id)
        external
        view
        returns (uint256 vaultId, bool active, address daoAddress, address vaultAddress, string memory name);
}
