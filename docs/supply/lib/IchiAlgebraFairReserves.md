# SUPPLY/LIB — IchiAlgebraFairReserves
[zipcode-euler/contracts/src/supply/lib]

The manipulation-resistant way to value an ICHI liquidity-manager vault. Base (chain 8453). Solidity 0.8.24.

* The question it answers: how much of each token is really inside an ICHI vault's liquidity position right now?
* The naive answer — the vault's own reserve readout — values the position at the pool's CURRENT price. A single large swap can move that price within one block, so an attacker could make the position look worth more or less for the length of one transaction.
* This library values the position at the pool's TIME-AVERAGED price (a TWAP) over a window the caller chooses — one hour on the deployed oracle. The two inputs it uses, the position's liquidity (which only changes when the vault rebalances) and the time-averaged price, cannot be moved by an in-block swap. So the number it returns cannot be manipulated in one block.
* It only reads. It holds no funds, no stored state, and no admin. It is a helper compiled into the contracts that use it, not deployed on its own.

==================================================================================
One file, one job.

- IchiAlgebraFairReserves.sol → fair reserve reconstruction
For each of the vault's two liquidity positions it takes the position's liquidity and price bounds and recomputes the underlying token amounts at the time-averaged price, then adds the vault's idle (un-deployed) balances. It returns the two fair token amounts and the average price level. It fails closed: if the pool exposes no time-average price source, or the data comes back malformed, it reverts rather than falling back to the manipulable current price.
[contracts/src/supply/lib/IchiAlgebraFairReserves.sol]
[../../wires/FairLpOracle.md]

Summaries:
[../../wires/FairLpOracle.md]

==================================================================================
Security X-Ray (audit fidelity)

The supply/lib scope has a dedicated, test-connected X-Ray under contracts/src/supply/lib/x-ray/. It is rated ADEQUATE (a hair from HARDENED).

[contracts/src/supply/lib/x-ray/x-ray.md] — scope-level overview + verdict
[contracts/src/supply/lib/x-ray/IchiAlgebraFairReserves.md] — the per-contract review

The load-bearing points an auditor should check (full catalog + test connection live in the X-Ray):

* Manipulation invariance is the whole point, and it is proven on a live pool. The keystone fork test lands a 300k-USDC swap on the real HYDX/USDC vault: the naive current-price readout shifts more than 2%, while this library's fair number moves less than 1%.
* Faithfulness when calm. When the pool is quiet (the time-averaged price is near the current price), the reconstruction reproduces the vault's own readout, also proven against the live vault.
* The time-average's integrity is a pool-config property, not enforced here (top residual, off-chain). The guarantee is only as strong as the pool's price-history depth and the chosen window. The library does not check that the pool keeps enough price history; a pool with too little history, or too short a window, weakens it. Confirm the deployed pool's settings are economically safe.
* The tick math is borrowed, frozen Uniswap-V3 math (off-chain assurance). Its correctness is upstream Uniswap's, and the faithful-copy check is done — see the ConcentratedLiquidity library review.
* The one in-file test gap: the two fail-closed reverts (no price source / malformed data) are not directly tested, because the live vault always has a price source. A small mock test would close it.

==================================================================================
References:

This library is built on borrowed math and live market infrastructure, and it feeds the protocol's two LP-value reads.

- It uses the vendored Uniswap-V3 tick math — [contracts/src/libraries/ConcentratedLiquidity.sol] ([../../libraries/concentrated-liquidity.md]).
- It reads an ICHI vault's positions and an Algebra pool's time-average price source through minimal local interfaces — [contracts/src/interfaces/ichi/IICHIVault.sol], [contracts/src/interfaces/algebra/IAlgebraPool.sol] (see [../../interfaces/interfaces-ichi.md], [../../interfaces/interfaces-algebra.md]).
- It is read by the trustless fair-LP collateral oracle — [contracts/src/supply/AlgebraIchiFairLpOracle.sol] ([../../wires/FairLpOracle.md]).
- It is read by the NAV oracle's LP leg, so a wrong number would mis-mark senior NAV as well as the farm-utility LP collateral — [contracts/src/supply/SzipNavOracle.sol] ([../../wires/8-B4-SzipNavOracle.md]).
