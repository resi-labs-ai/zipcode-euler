# SUPPLY — AlgebraIchiFairLpOracle
[zipcode-euler/contracts/src/supply]

The trustless price for an LP share, used as borrow collateral. Base (chain 8453). Solidity 0.8.24.

* It prices one share of the ICHI liquidity-manager LP in USDC, fully on-chain, with no off-chain feed and no liveness dependency.
* It does this manipulation-resistantly by valuing the position at the pool's time-averaged price (delegated to the fair-reserves library), then taking the share's pro-rata slice of that value, rounded down against the borrower.
* It is the price source the lending market resolves the LP collateral through. It is the opt-in trustless alternative to the keeper-pushed LP oracle.

==================================================================================
What it does

- AlgebraIchiFairLpOracle.sol → fair LP-share price adapter
A read-only price adapter the lending market calls to value LP collateral. It asks the fair-reserves library for the position's two token amounts at the time-averaged price, values them in USDC at that same average price, and returns the share's pro-rata slice rounded down. It has no owner, no setters, and no stored state — re-pointing it is a redeploy. It fails closed on an unsupported pair, zero supply, or a pool with no time-average source.
[contracts/src/supply/AlgebraIchiFairLpOracle.sol]
[../wires/FairLpOracle.md]

Summaries:
[../wires/FairLpOracle.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (a hair from HARDENED) — a thin, stateless, ownerless pricing wrapper, fork-proven against the live HYDX/USDC vault (13 tests: 5 fork + 8 edge).

[contracts/src/supply/x-ray/AlgebraIchiFairLpOracle.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* The decisive property — fair value barely moves under a large in-block swap that moves the naive spot value more than 2% — is proven where it lives (the fair-reserves library) and re-proven end-to-end through this adapter's quote.
* It rounds down against the borrower (never over-values collateral), proven deterministically; it resolves identically through a real lending-market router.
* It fails closed: an unsupported pair, zero supply, or a pool with no time-average source revert rather than returning a manipulable or garbage price.
* Residuals (off-chain/upstream): the time-average's depth and window are a pool-config property; the underlying tick math is vendored, frozen Uniswap-V3 math; no external audit. None is this contract's own code.

==================================================================================
References:

- It delegates manipulation-resistance to the fair-reserves library — [contracts/src/supply/lib/IchiAlgebraFairReserves.sol] ([lib/IchiAlgebraFairReserves.md]).
- It is the trustless alternative to the keeper-pushed LP oracle — [contracts/src/supply/SzipFarmUtilityLpOracle.sol] ([SzipFarmUtilityLpOracle.md]).
- The lending market that resolves LP collateral through it is built by the venue adapter — [contracts/src/venue/EulerVenueAdapter.sol] ([../venue.md]).
