// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for a Hydrex Solidly-style AMM pair (the pair contract IS its own LP token).
/// @dev    DEMO/showcase use only (ANVIL-01 oracle fork + ANVIL-02 LP-manager fork). Verified on-chain on a Base
///         fork @ 47096000 against the live vAMM HYDX/USDC pair 0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d
///         (name() == "VolatileV1 AMM - HYDX/USDC", stable() == false, decimals() == 18):
///           getReserves() -> (reserve0 18-dp HYDX, reserve1 6-dp USDC, blockTimestampLast) returned real data;
///           token0()==HYDX(0x00000e7e…), token1()==USDC(0x833589fC…); totalSupply()/balanceOf() are the LP token.
///         The low-level `mint(to)` is the routerless add: transfer both reserve tokens to the pair, then `mint`
///         credits LP to `to` proportional to the lesser-side reserve ratio (excess of one side is donated). Solidly
///         `mint`/`getReserves` signatures (UniV2 lineage); confirmed present in the pair bytecode.
interface IVammPair {
    /// @notice Mint LP to `to` against tokens already transferred in. Returns the LP shares minted.
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Current reserves: `_reserve0` (token0, native dp), `_reserve1` (token1, native dp), last-update ts.
    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}
