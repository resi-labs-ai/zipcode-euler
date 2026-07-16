// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title IGPv2Settlement
/// @notice Minimal CoW Protocol `GPv2Settlement` surface the §7 buy-and-burn bid module touches (8-B14). The live
///         Base 8453 deployment is `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (same address all chains).
/// @dev Verified live on Base 8453 (2026-06-08, `cast`):
///      - `domainSeparator()` => `0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b`.
///      - `vaultRelayer()`   => `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` (the spender USDC is `approve`d to).
///      - `setPreSignature(bytes,bool)` selector `0xec6cb13f` (stores a presignature keyed by the `owner` packed
///        into `orderUid`; that `owner` MUST == `msg.sender`).
///      - `preSignature(bytes)` selector `0xd08d33d1` (0 = unsigned, nonzero = signed).
interface IGPv2Settlement {
    /// @notice The EIP-712 domain separator for CoW orders on this chain.
    function domainSeparator() external view returns (bytes32);

    /// @notice The GPv2VaultRelayer — the address sell tokens are pulled from (the `approve` spender).
    function vaultRelayer() external view returns (address);

    /// @notice Set (or clear) an on-chain presignature for the order identified by `orderUid`. The `owner` packed
    ///         into `orderUid` MUST equal `msg.sender`.
    function setPreSignature(bytes calldata orderUid, bool signed) external;

    /// @notice Read back a presignature (0 = unsigned, nonzero = signed).
    function preSignature(bytes calldata orderUid) external view returns (uint256);
}
