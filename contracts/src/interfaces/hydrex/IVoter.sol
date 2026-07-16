// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Hydrex (Solidly/ve(3,3)-fork) Voter.
/// Source contract: VoterV5Proxy @ Base 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b
/// (impl 0x03796788a91e521197e05865a55b2ee251148aa4).
/// verified on-chain 2026-06-06 against the impl's verified ABI + bytecode selectors:
///   createGauge(address,uint256) -> 0xdcd9e47a (FOUND); returns 3 addresses (gauge,internalBribe,externalBribe)
///   gauges(address)              -> 0xb9a09fd5 (FOUND); confirmed by staticcall returning the live gauge
///                                   for HYDX/USDC pool (0xAC396CabF5832A49483B78225D902C0999829993)
///   claimRewards(address[])      -> 0xf9f031df (FOUND)
///   vote(address[],uint256[])    -> 0x6f816a20 (FOUND); CORRECTED — the guessed
///                                   vote(uint256,address[],uint256[]) (0x7ac09bf7) is ABSENT.
///                                   This Voter votes with the caller's veNFT (no tokenId arg).
///   reset()                      -> 0xd826f88f (FOUND); account-keyed (no tokenId); the guessed
///                                   reset(uint256) (0x310bd74b) is ABSENT.
///   ve()                         -> 0x1f850716 (FOUND); the Voter's voting escrow (account-keyed accounting).
interface IVoter {
    function vote(address[] calldata poolVote, uint256[] calldata voteProportions) external;

    function reset() external;

    function ve() external view returns (address);

    function createGauge(address pool, uint256 gaugeType)
        external
        returns (address gauge, address internalBribe, address externalBribe);

    function gauges(address pool) external view returns (address gauge);

    function claimRewards(address[] calldata gauges) external;
}
