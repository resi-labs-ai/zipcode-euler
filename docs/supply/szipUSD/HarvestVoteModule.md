# SZIPUSD ENGINE — HarvestVoteModule
[zipcode-euler/contracts/src/supply/szipUSD]

The harvest and governance leg of the auto-compounder. Base (chain 8453). Solidity 0.8.24.

* It claims the gauge's HYDX option rewards into the vault, permanently locks a slice into vote power, votes the gauges, and claims anti-dilution rebases.
* It moves no value out: rewards come in to the vault, the vote lock stays owned by the vault, and votes are cast as the vault.
* An off-chain keeper triggers each action with only amounts or lists; the module builds the calls and holds no funds and grants no token approvals.

==================================================================================
What it does

- HarvestVoteModule.sol → claim, permalock, vote, rebase
Five keeper-only actions over the Hydrex emissions venue: claim the gauge rewards to the vault; permanently lock a slice into a fresh vote-power position minted to the vault; vote and reset the gauge weights; and claim per-position rebases. The vote-lock recipient is hard-pinned to the vault, and votes accrue to the vault simply because it is the caller of record — there is no transferable position handle for a keeper to redirect.
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[../../wires/8-B7-HarvestVoteModule.md]

Summaries:
[../../wires/8-B7-HarvestVoteModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — the most external-integration-heavy module, exercised against the real Hydrex contracts: 24 unit + 5 fork tests.

[contracts/src/supply/szipUSD/x-ray/HarvestVoteModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The vote-lock recipient is hard-pinned to the vault and the venue is account-keyed (no per-position handle), so the rewards and vote power can only ever accrue to the vault. Proven on a live fork.
* Each action is a single fixed call with no value attached and no token approvals anywhere; a failed inner call hard-reverts rather than silently reporting success.
* Residual (off-chain): permanently locking is one-way, so a clumsy keeper can grief by over-locking liquid rewards into illiquid vote power — bounded to the vault, never theft. Build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It drives the Hydrex gauge, voter, voting-escrow, and rewards-distributor — [contracts/src/interfaces/hydrex/IGauge.sol], [contracts/src/interfaces/hydrex/IVoter.sol], [contracts/src/interfaces/hydrex/IVotingEscrow.sol], [contracts/src/interfaces/hydrex/IRewardsDistributor.sol] (see [../../interfaces/interfaces-hydrex.md]).
- The claimed reward options are exercised by the exercise module — [contracts/src/supply/szipUSD/ExerciseModule.sol] ([ExerciseModule.md]).
