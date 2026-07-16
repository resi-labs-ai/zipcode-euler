// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Hydrex RewardsDistributor (the per-veNFT anti-dilution rebase).
/// Source contract: RewardsDistributor @ Base 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42
/// (= Minter._rewards_distributor(), selector 0x4b1cd5da, read live 2026-06-08).
/// verified on-chain 2026-06-08 against the deployed bytecode selectors:
///   claim(uint256)        -> 0x379607f5 (FOUND); the singular per-veNFT rebase claim (returns the claimed amount).
///   claim_many(uint256[]) -> 0x1f1db043 (FOUND); the batch the module calls (returns bool — IGNORED by the module:
///                            the rebase credits each veNFT's own lock and cannot be redirected, so an imperfect
///                            operator-curated array is harmless).
///   claimable(uint256)    -> 0xd1d58b25 (FOUND); the per-veNFT claimable rebase view; claimable(#1) staticcalled non-zero.
/// The module calls only `claim_many` (mutate) + `claimable` (view); `claim` is included for interface completeness,
/// harmless + unused by the module.
interface IRewardsDistributor {
    function claim(uint256 tokenId) external returns (uint256);

    function claim_many(uint256[] calldata tokenIds) external returns (bool);

    function claimable(uint256 tokenId) external view returns (uint256);
}
