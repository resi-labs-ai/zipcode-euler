# SZIPUSD ENGINE — LpStrategyModule
[zipcode-euler/contracts/src/supply/szipUSD]

The liquidity-position leg: it owns the vault's zipUSD/xALPHA LP. Base (chain 8453). Solidity 0.8.24.

* It builds the LP in an ICHI managed-liquidity vault, stakes it in the gauge to farm rewards, unstakes it for the harvest loop, and dissolves it back into the two tokens.
* Dissolving is the one gated action: the LP backs the solvency floor in place, so it can only convert LP that is excess over that floor.
* An off-chain keeper triggers it with amounts; the built LP and all reads are pinned to the vault, and the module holds no funds.

==================================================================================
What it does

- LpStrategyModule.sol → build, stake, unstake, dissolve the LP
Four keeper-only actions. Build approves and deposits the two tokens into the ICHI vault (single-sided or balanced) and resets approvals; stake and unstake move the LP in and out of the gauge; dissolve withdraws the LP back to the two tokens and is blocked unless the freeze module confirms the burn keeps the vault covered. The deposit target and every balance read are pinned to the vault, and the token legs are read live off the ICHI vault so approval targets can't drift.
[contracts/src/supply/szipUSD/LpStrategyModule.sol]
[../../wires/8-B6-LpStrategyModule.md]

Summaries:
[../../wires/8-B6-LpStrategyModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — tested unit plus live-fork against the real ICHI vault and gauge: 32 unit + 5 fork tests.

[contracts/src/supply/szipUSD/x-ray/LpStrategyModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The load-bearing seam is the coverage path-lock: dissolving LP is gated against the same solvency floor the freeze module enforces, tested across all three gate states (blocked when it would breach, allowed for excess, ungated in the legacy off state).
* Approvals reset to zero on every path and a failed inner call rolls the whole sequence back, so no standing approval survives; the minimum-shares floor is the only sandwich protection on a direct deposit and is enforced.
* Residual (off-chain): the keeper sizes the amounts, bounded by the pins and the slippage floor; build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It builds the LP in an ICHI managed-liquidity vault — [contracts/src/interfaces/ichi/IICHIVault.sol] (see [../../interfaces/interfaces-ichi.md]).
- It stakes in the Hydrex gauge — [contracts/src/interfaces/hydrex/IGauge.sol] (see [../../interfaces/interfaces-hydrex.md]).
- Its dissolve is gated by the freeze module's coverage floor — [contracts/src/supply/szipUSD/DurationFreezeModule.sol] ([DurationFreezeModule.md]).
