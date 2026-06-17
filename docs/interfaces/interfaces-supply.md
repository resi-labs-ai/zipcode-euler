# INTERFACES — SUPPLY
[zipcode-euler/contracts/src/interfaces/supply]

One internal interface onto our own NAV oracle. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Interface → What it is

Note: this is internal — it points at one of our own contracts (`SzipNavOracle`), not an outside protocol. We use a small interface so the freeze module doesn't have to compile against the whole oracle.

- ISzipNavBasket.sol → the basket-value views of our NAV oracle
A read-only view of `SzipNavOracle`: the basket's total value, the committed (frozen) portion, the free portion, and the five token addresses the oracle prices. The DurationFreezeModule reads these to enforce the freeze floor — it requires the committed value to stay above its utilization-based minimum.
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[wires/DurationFreezeModule.md]

Summaries:
[../wires/interfaces-supply.md]

==================================================================================
References:

- SzipNavOracle — [contracts/src/supply/SzipNavOracle.sol] is the implementer; this interface is just the basket-value slice the freeze module reads.
