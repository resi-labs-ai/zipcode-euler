// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Hydrex RewardsDistributor (the per-veNFT anti-dilution rebase).
/// Source contract: RewardsDistributor @ Base 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42
/// (= Minter._rewards_distributor(), selector 0x4b1cd5da, read live 2026-06-08).
/// verified on-chain 2026-06-08 against the deployed bytecode selectors:
///   claim(uint256)        -> 0x379607f5 (FOUND); the singular per-veNFT rebase claim (returns the claimed amount).
///   claim_many(uint256[]) -> 0x1f1db043 (FOUND); the batch the module calls (returns bool — IGNORED by the module:
///                            the rebase credits each veNFT's own lock and cannot be redirected, so an imperfect
///                            operator-curated array is harmless). The bool is VESTIGIAL always-true: probed live
///                            2026-07-28 via eth_call — returns true for a token with nothing claimable AND for a
///                            NONEXISTENT tokenId — so decoding it can never distinguish "claimed" from "no-op"
///                            (audit F11 won't-fix: the emitted RebaseClaimed means "claim ATTEMPTED for these ids";
///                            the truthful success signal is the claimable(tokenId) delta).
///                            SUNSET: the live Minter's schedule (RevisedPhasedEmissionSchedule 0x5aAa…2727,
///                            calculateRebaseAmount) hard-codes rebase = 0 from week 52 (starts 2026-09-10; probed
///                            week 45 on 2026-07-28, rate 26% − 0.5%/wk = 3.5% and decaying). After that date
///                            claim_many is a permanent no-op (still true) and claimRebase is vestigial — the
///                            keeper can drop it from rotation.
///   claimable(uint256)    -> 0xd1d58b25 (FOUND); the per-veNFT claimable rebase view; claimable(#1) staticcalled non-zero.
/// The module calls only `claim_many` (mutate) + `claimable` (view); `claim` is included for interface completeness,
/// harmless + unused by the module.
interface IRewardsDistributor {
    function claim(uint256 tokenId) external returns (uint256);

    function claim_many(uint256[] calldata tokenIds) external returns (bool);

    function claimable(uint256 tokenId) external view returns (uint256);
}
