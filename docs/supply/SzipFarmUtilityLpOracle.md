# SUPPLY — SzipFarmUtilityLpOracle
[zipcode-euler/contracts/src/supply]

The keeper-pushed price for the LP collateral in the leverage loop. Base (chain 8453). Solidity 0.8.24.

* It prices one share of the LP in USDC from a single value pushed by an off-chain Chainlink keeper, cached on-chain.
* It is the twin of the trustless fair-LP oracle and serves the same role — pricing LP collateral for the lending market — but trades on-chain manipulation-resistance for a liveness dependency: if the pushed mark is stale or missing, a borrow fails closed.
* It is the deploy default; the trustless on-chain oracle is the opt-in alternative.

==================================================================================
What it does

- SzipFarmUtilityLpOracle.sol → CRE push-cache LP price adapter
Two faces in one contract: a report receiver that accepts the keeper's pushed per-share mark, and a price adapter the lending market reads. The write path is keeper-only and fail-closed (rejects a zero, oversized, future-dated, or non-newer mark). The read path returns the cached mark rounded down, and reverts if the cache is unset or older than the validity window — so a missing or stale mark blocks the borrow rather than opening an unsafe one.
[contracts/src/supply/SzipFarmUtilityLpOracle.sol]
[../wires/8-B5-FarmUtilityLoop.md]

Summaries:
[../wires/8-B5-FarmUtilityLoop.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — a pattern-proven push-cache oracle with correct fail-closed semantics across its full surface (19 tests).

[contracts/src/supply/x-ray/SzipFarmUtilityLpOracle.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* The defining property is the liveness contract: a stale or missing mark must fail the borrow closed (a too-old mark and an unset cache both revert, the window boundary pinned). This is the safety it trades manipulation-resistance for, and it is proven.
* The write path is keeper-only and rejects a malformed push (zero, oversized, future-dated), and a mark whose timestamp is not strictly newer is rejected — so a stale-but-higher mark can't over-credit collateral.
* The read returns the mark rounded down against the borrower. The price scaling bakes in an 18-dp LP key and re-derives only against the quote: re-pointing the quote token re-derives the scale (so a quote-decimals change is absorbed), while the LP key is locked to 18 decimals — the constructor and `setLpToken` both strict-read `lpToken.decimals()` and reject anything but a live 18-dp token (`InvalidLpDecimals`), because a non-18-dp key would NOT re-derive the scale and would silently mis-scale every quote (over-valuing collateral for a >18-dp key).
* Residual (off-chain): the keeper is trusted for the mark (bounded by fail-closed staleness); the report type is a placeholder to be ratified at the off-chain wiring step; build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It is the keeper-pushed twin of the trustless on-chain oracle — [contracts/src/supply/AlgebraIchiFairLpOracle.sol] ([AlgebraIchiFairLpOracle.md]).
- The leverage loop borrows against the collateral it prices — [contracts/src/supply/szipUSD/FarmUtilityLoopModule.sol] ([szipUSD/FarmUtilityLoopModule.md]).
- The lending market that resolves the collateral through it is built by the venue adapter — [contracts/src/venue/EulerVenueAdapter.sol] ([../venue.md]).
