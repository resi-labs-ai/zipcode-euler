# INTERFACES — SUPPLY
[zipcode-euler/contracts/src/interfaces/supply]

One internal interface onto our own NAV oracle. Base (chain 8453). Solidity 0.8.24.

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

Summaries:
[../wires/interfaces-supply.md]

==================================================================================
References:

- SzipNavOracle — [contracts/src/supply/SzipNavOracle.sol] is the implementer; this interface is just the basket-value slice the freeze module reads.
