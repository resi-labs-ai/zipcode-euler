# ZIPCODE ORACLE REGISTRY
[zipcode-euler/contracts/src]

The price source for every credit line's collateral. Base (chain 8453). Solidity 0.8.24.

* Each credit line is represented by its own lien token; this registry caches a USD mark for each one — the line's appraised value minus its senior debt.
* Two things write the cache: the controller seeds a line's price at origination, and an off-chain Chainlink keeper revalues lines later. One read serves the lending market, and it fails closed if the mark is missing or stale.
* It is the lending market's price feed for the lien collateral. A line whose mark goes stale cannot be borrowed against until it is refreshed.

==================================================================================
What it does

- ZipcodeOracleRegistry.sol → multi-line collateral price cache
Holds one cached mark per lien token. The controller seeds a single mark at origination; the keeper revalues in all-or-nothing batches (one bad entry reverts the whole batch). Every write is fail-closed: a zero, oversized, future-dated, or non-newer mark is rejected, and every priced key must be a strict 18-decimal token (a non-18-decimal lien is unreachable by design, because there is one shared scale). The read rounds down against the borrower and reverts if the mark is unset or older than the validity window.
[contracts/src/ZipcodeOracleRegistry.sol]
[wires/WOOF-02.md]

Summaries:
[wires/WOOF-02.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — the multi-line collateral price cache, exhaustively tested (41 tests).

[contracts/src/x-ray/ZipcodeOracleRegistry.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* One shared scaling factor makes the strict 18-decimal key guard load-bearing: a non-18-decimal lien would be silently mis-scaled, so any such key is rejected on both write paths (a 6-decimal token and a code-less address both fail).
* Revaluation is all-or-nothing: a single bad key reverts the whole batch (no partial revaluation), with blast radius bounded off-chain by sharding. There is no on-chain value band by design — integrity is upstream (the proof, the keeper consensus, and the Timelock-pinned sender), so even a large mark drop is accepted as a real revaluation; the read fails closed on staleness instead.
* A mark whose timestamp is not strictly newer than the cached one is rejected, blocking replays and out-of-order writes that a price-only check can't catch.
* Residual (off-chain): the wiring slots are owner-re-pointable until the pre-production immutable re-freeze; the keeper and proof producer are trusted; no external audit.

==================================================================================
References:

- The controller seeds a line's price at origination and re-anchors it on draw — [contracts/src/ZipcodeController.sol] ([ZipcodeController.md]).
- It prices lien tokens, whose strict 18-decimal pin it validates against the factory's constant — [contracts/src/LienCollateralToken.sol] ([LienCollateralToken.md]), [contracts/src/LienTokenFactory.sol] ([LienTokenFactory.md]).
- The lending market resolves the lien collateral's price through it — [contracts/src/venue/EulerVenueAdapter.sol] ([venue.md]).
- It is the multi-line sibling of the single-key push oracle — [contracts/src/supply/SzipFarmUtilityLpOracle.sol] ([supply/SzipFarmUtilityLpOracle.md]).
