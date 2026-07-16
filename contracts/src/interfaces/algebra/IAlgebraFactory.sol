// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @dev STATUS: STAGED — not yet wired. Build-time pool-address verification for the prod ICHI/Algebra LP path;
///      referenced by no src contract today. Intentional forward scaffolding, not dead code.
///      See docs/interfaces/interfaces-algebra.md.
/// @notice Minimal local interface for the Algebra Integral factory.
/// Live factory @ Base 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E (from HYDX/USDC pool.factory()).
/// verified on-chain 2026-06-06 (VERIFIED-CORRECT): poolByPair(HYDX,USDC) returned the exact
/// pool 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2. Algebra pools are fee-by-pair (no fee tier arg).
interface IAlgebraFactory {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}
