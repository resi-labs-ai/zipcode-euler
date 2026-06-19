# INTERFACES — SUPPLY
[zipcode-euler/contracts/src/interfaces/supply]

Two interfaces: one onto our own NAV oracle, and the venue-neutral senior-pool read. Base (chain 8453). Solidity 0.8.24.

==================================================================================
The Junior Tranche has an oracle, which evaluates the NAV of its underlying basket of tokens. 

This NAV evaluation helps with risk management, as well as pricing entries, and estimating the value of exits.

Note: this is internal — it points at one of our own contracts (`SzipNavOracle`), not an outside protocol. We use a small interface so the freeze module doesn't have to compile against the whole oracle.

- ISzipNavBasket.sol → the basket-value views of our NAV oracle
A read-only view of `SzipNavOracle`. The DurationFreezeModule reads it to enforce the freeze floor — keeping the sidecar's covered value above its utilization-based minimum. It exposes:
  - the basket's total value, the committed (frozen) portion, and the free portion;
  - the path-locked LP equity and a per-share LP value — the freeze floor's coverage is committed value plus path-locked LP equity, and the LP-release check reads the per-share value;
  - the six movable asset addresses the oracle prices (zipUSD, USDC, xALPHA, HYDX, oHYDX, and the ICHI LP token).
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[wires/DurationFreezeModule.md]

- ISeniorPool.sol → the venue-neutral senior-pool read (CTR-10a)
A small read-only view of a silo's senior pool — its three donation-immune views (share balance, share-to-assets, and free liquidity right now). It is the generalization of the old EulerEarnUtil view: named for any venue, not just Euler, so a non-Euler senior surface can satisfy the same read. EulerEarn satisfies it directly. The SeniorNavAggregator and the DurationFreezeModule read each silo's senior backing through it, donation-immune (an outsider can't skew it by donating to the pool).
[contracts/src/SeniorNavAggregator.sol]
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[wires/interfaces-supply.md]

Summaries:
[../wires/interfaces-supply.md]

==================================================================================
References:

- SzipNavOracle — [contracts/src/supply/SzipNavOracle.sol] is the implementer; this interface is just the basket-value slice the freeze module reads.
