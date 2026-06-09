// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Baal summoner factory.
/// Source contract: BaalSummoner @ Base 0x97Aaa5be8B38795245f1c38A883B44cccdfB3E11.
/// verified 2026-06-06 against vendored reference/Baal/contracts/BaalSummoner.sol:
///   summonBaal(bytes,bytes[],uint256)                 -> exists (lines 128-140)
///   summonBaalFromReferrer(bytes,bytes[],uint256,bytes32) -> exists (lines 143-159)
/// RESOLVED: summonBaalAndSafe does NOT exist on the Baal summoner — grep over the entire
/// reference/Baal/ tree returns zero hits. The higher-order BaalAndVaultSummoner exposes
/// `summonBaalAndVault` (a DIFFERENT contract/selector), not `summonBaalAndSafe`. The phantom
/// `summonBaalAndSafe` flagged in WOOF-00 has been REMOVED from this interface.
interface IBaalSummoner {
    function summonBaal(
        bytes calldata initializationParams,
        bytes[] calldata initializationActions,
        uint256 _saltNonce
    ) external returns (address);

    function summonBaalFromReferrer(
        bytes calldata initializationParams,
        bytes[] calldata initializationActions,
        uint256 _saltNonce,
        bytes32 referrer
    ) external payable returns (address);

    /// @dev public state var (BaalSummoner.sol:20) — the Gnosis Safe singleton the summoner clones.
    /// Read live for the main-Safe CREATE2 compute. (The proxy factory itself is `internal` on the
    /// summoner — use BaseAddresses.SAFE_PROXY_FACTORY_1_3_0, validated by the compute==avatar assert.)
    function gnosisSingleton() external view returns (address);
}
