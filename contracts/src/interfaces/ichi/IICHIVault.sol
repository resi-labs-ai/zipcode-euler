// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for an ICHI (Automated Liquidity Manager) vault.
/// verified on-chain 2026-06-06 against a live HYDX ICHI vault
/// 0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad (allVaults(0) of factory
/// 0x2b52c416F723F16e883E53f3f16435B51300280a, ammName()=="HYDX").
/// Evidence: token0()/token1()/allowToken0()/allowToken1()/getTotalAmounts()/totalSupply()
/// returned real data via staticcall; deposit(uint256,uint256,address) selector 0x8dbdbe6d
/// present in bytecode; withdraw(uint256,address)->(uint256,uint256) confirmed by staticcall
/// reverting with the contract's own "IV.withdraw: shares" require message (selector resolves).
interface IICHIVault {
    // ERC4626-style core
    function deposit(uint256 deposit0, uint256 deposit1, address to) external returns (uint256 shares);

    function withdraw(uint256 shares, address to) external returns (uint256 amount0, uint256 amount1);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    // ICHI-specific
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);

    function allowToken0() external view returns (bool);

    function allowToken1() external view returns (bool);
}
