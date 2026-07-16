# SZIPUSD ENGINE — DurationFreezeModule
[zipcode-euler/contracts/src/supply/szipUSD]

The solvency freeze: it keeps enough junior equity locked to back the senior debt. Base (chain 8453). Solidity 0.8.24.

* It moves junior value between two vaults — the main engine vault and a non-withdrawable sidecar vault — to fence committed equity so a normal window exit can't reach it.
* Filling the sidecar is unbounded by design (the intended liquidity squeeze). Draining it is gated: a release can never drop coverage below the required floor.
* The floor is the senior liability itself, read live: the smaller of the illiquid senior value and the whole junior basket value. It is pinned to absolute debt, not a fraction of the basket, so shrinking the basket cannot lower it.
* An off-chain keeper triggers it with only an asset and an amount; the module builds the move and holds no funds.

==================================================================================
What it does

- DurationFreezeModule.sol → the coverage-floor freeze actuator
Fills the sidecar (commit) and drains it (release). A release reverts unless coverage after the move still clears the floor, with an atomic rollback otherwise. Coverage counts the sidecar's committed value plus the engine's path-locked LP equity, with the LP counted in place and never double-counted. It runs on both vaults because the move crosses them, and only the five oracle-priced asset legs may move — the LP share itself is fenced in place, not transferred.
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[../../wires/DurationFreezeModule.md]

Summaries:
[../../wires/DurationFreezeModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (a hair from HARDENED) — the best-tested contract in the engine and the only one with the full test pyramid: 54 unit + 1 fuzz + 1 stateful invariant (128,000 calls, zero floor breaches) + 2 fork tests.

[contracts/src/supply/szipUSD/x-ray/DurationFreezeModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The floor cannot be under-frozen: it is read live after the move and an atomic rollback undoes any release that would breach it; pinned to absolute debt, so there is no fraction to game. Proven by the 128,000-call invariant.
* The locked LP backs the floor in place and is single-counted; its only dissolution path (the LP module's removeLiquidity) is gated against the same floor.
* Value moves only between the two wired vaults — no recipient parameter, no arbitrary call, no funds held. Backing reads are donation-immune (they read withdrawable value, never a raw token balance).
* Residuals (off-chain): the keeper is trusted for which asset and how much (it can grief by over-freezing, never steal or under-freeze); the floor's correctness depends on the NAV oracle's marks; the build-phase wiring (twelve setters) awaits the pre-production immutable re-freeze.

==================================================================================
References:

- Every floor input is read from the NAV oracle — [contracts/src/supply/SzipNavOracle.sol] ([../../wires/8-B4-SzipNavOracle.md]).
- The senior backing it measures lives in the EulerEarn pool — [contracts/src/interfaces/euler/IEulerEarn.sol] (see [../../interfaces/interfaces-euler.md]).
- The LP-dissolution path it gates is the LP strategy module — [contracts/src/supply/szipUSD/LpStrategyModule.sol] ([LpStrategyModule.md]).
