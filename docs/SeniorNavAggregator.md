# SENIOR NAV AGGREGATOR
[zipcode-euler/contracts/src]

The one number for senior solvency: total senior backing across every silo. Base (chain 8453). Solidity 0.8.24.

* It sums each silo's senior par-backing into a single figure, then compares it to the zipUSD in circulation. It is solvency telemetry — the input to a circuit breaker and to dashboards — not a pricing oracle. zipUSD still mints by value and redeems at par regardless of this number.
* It reads each silo's backing donation-immunely: it values the warehouse-owned position, never a raw pool balance, so nobody can inflate or deflate the figure by sending tokens to a pool.
* It is venue-agnostic: it reads each silo's senior pool through a venue-neutral interface, so a non-Euler venue counts the same way.

==================================================================================
What it does

- SeniorNavAggregator.sol → donation-immune senior-backing sum
A pure read over the silo registry. Per silo it computes the senior value and the illiquid (lent-out) portion from the warehouse-owned position, and sums them across all silos, across active silos only, and as the lent-out total. It also computes the collateralization ratio against a given supply — returning the maximum when supply is zero, so a breaker reading "below threshold" cannot false-trip when no zipUSD is outstanding. It holds no funds and transfers nothing.
[contracts/src/SeniorNavAggregator.sol]
[wires/CTR-05-SeniorNavAggregator.md]

Summaries:
[wires/CTR-05-SeniorNavAggregator.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — pure-view solvency telemetry, fully tested (20 unit tests).

[contracts/src/x-ray/SeniorNavAggregator.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Donation immunity is the entire security claim: it reads the warehouse-owned senior position through value/withdrawable views, never a raw pool balance, so a stray donation cannot move the figure. The math is lifted verbatim from the freeze module, so the two never disagree.
* It is telemetry, not pricing: the zero-supply-returns-maximum choice is the load-bearing safety detail (with no zipUSD outstanding the system is not insolvent, so a breaker must not trip).
* Retired silos still count toward backing (their open lines still minted zipUSD); only the active view filters them out. A drained silo contributes zero with no special case.
* Residual (off-chain): the registry and zipUSD wiring slots are owner-re-pointable until the pre-production immutable re-freeze; no external audit. It holds no funds and prices nothing.

==================================================================================
References:

- It reads the silo catalog — [contracts/src/SiloRegistry.sol] ([SiloRegistry.md]) — and each silo's senior pool through the venue-neutral interface — [contracts/src/interfaces/supply/ISeniorPool.sol] (see [interfaces/interfaces-supply.md]).
- Its donation-immune per-silo math matches the freeze module's coverage math — [contracts/src/supply/szipUSD/DurationFreezeModule.sol] ([supply/szipUSD/DurationFreezeModule.md]).
- It measures backing against the zipUSD supply, the senior dollar minted via the deposit module — [contracts/src/supply/ZipDepositModule.sol] ([supply/ZipDepositModule.md]).
