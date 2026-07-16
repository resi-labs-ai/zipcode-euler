// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Hydrex voting escrow (veHYDX, V2).
/// Source contract: proxy @ Base 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1
/// (impl 0x0fc68ce53be957a1aa779f553ad49f6068fff231).
/// verified on-chain 2026-06-06:
///   createLock(uint256,uint256,uint8) -> 0xc7512670 (FOUND in impl bytecode);
///     3rd arg is the IVotingEscrowV2_Data.LockType enum (modeled as uint8 to stay
///     self-contained). CORRECTED — the guessed create_lock(uint256,uint256) (0x65fc3873)
///     is ABSENT (this is the V2 escrow, not classic Solidly create_lock).
///   balanceOfNFT(uint256) -> 0xe7e242d4 (FOUND); confirmed by staticcall returning real voting power.
///   getVotes(address)     -> 0x9ab24eb0 (FOUND); the account-aggregate voting power summed across ALL the
///                            account's veNFTs (the floor metric — NOT balanceOfNFT(tokenId)).
///   balanceOf(address)    -> 0x70a08231 (FOUND); the count of veNFTs the account owns (ERC721 enumerable).
///   ownerOf(uint256)      -> 0x6352211e (FOUND); the owner of a veNFT.
///   tokenOfOwnerByIndex(address,uint256) -> 0x2f745c59 (FOUND); enumerate an account's veNFTs.
interface IVotingEscrow {
    /// @param lockType the LockType enum (0 = default); see Hydrex IVotingEscrowV2_Data.
    function createLock(uint256 value, uint256 lockDuration, uint8 lockType) external returns (uint256 tokenId);

    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    function getVotes(address account) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function ownerOf(uint256 tokenId) external view returns (address);

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}
