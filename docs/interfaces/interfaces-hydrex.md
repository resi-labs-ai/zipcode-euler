# INTERFACES — HYDREX
[zipcode-euler/contracts/src/interfaces/hydrex]

Small interfaces for Hydrex, the ve(3,3) emissions venue the harvest loop farms. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Hydrex provides the szALPHA/zipUSD liquidity pool, as well as oHYDX emissions which fuel the auto-compounder.

The junior tranche is the likely holder of all LP tokens in the pool, within an Ichi single-sided LP.

Note: Hydrex is an outside protocol on Base — we don't compile its code, we hand-write interfaces with only the functions we call.

- IGauge.sol → a Hydrex gauge (created on demand for our pool, no fixed address)
Where the LP is staked to earn rewards. The strategy stakes and unstakes the LP here; the harvest module claims the oHYDX rewards; the NAV oracle reads the staked balance.
[contracts/src/supply/szipUSD/LpStrategyModule.sol]
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[contracts/src/supply/SzipNavOracle.sol]
[contracts/src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol] (demo)
[contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol] (demo)
[wires/8-B7-HarvestVoteModule.md]

- IOptionToken.sol → oHYDX, the reward token `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78`
A discounted call option on HYDX — what the gauge actually pays out. The exercise module turns oHYDX into HYDX (paying the strike); the NAV oracle marks oHYDX at its intrinsic value (HYDX price minus the discount).
[contracts/src/supply/szipUSD/ExerciseModule.sol]
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[contracts/src/supply/SzipNavOracle.sol]
[contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol] (demo)
[wires/8-B8-ExerciseModule.md]

- IVoter.sol → Hydrex VoterV5 `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b`
The ve(3,3) gauge voter. The harvest module votes with the Safe's veHYDX to steer emissions toward our pool, and resolves or creates our gauge through it.
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[wires/8-B7-HarvestVoteModule.md]

- IVotingEscrow.sol → veHYDX `0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1`
The lock that holds HYDX as veHYDX and grants voting power. The harvest module creates locks and reads the Safe's total voting power.
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[wires/8-B7-HarvestVoteModule.md]

- IRewardsDistributor.sol → Hydrex RewardsDistributor `0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42`
The anti-dilution rebase paid to each veHYDX lock. The harvest module claims it for the Safe's locks.
[contracts/src/supply/szipUSD/HarvestVoteModule.sol]
[wires/8-B7-HarvestVoteModule.md]

- IVammPair.sol → a Solidly vAMM pair (demo only)
A plain Solidly pair (the pair is its own LP token). Used only by the Hydrex demo fork to build and price a live vAMM LP before the real ICHI pool exists. Production uses the ICHI vault instead.
[contracts/src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol]
[contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol]
[wires/SHOWCASE-VAMM.md]

Summaries:
[../wires/interfaces-hydrex.md]

==================================================================================
References:

These declare only the calls we make, with selectors verified against the live Base deployments.

- Hydrex — a Lynex/Algebra-style ve(3,3) AMM on Base. Token: HYDX `0x00000e7efa313F4E11Bfff432471eD9423AC6B30`.
- The gauge has no fixed address: it's created on demand for our pool and wired in once. That depends on Hydrex whitelisting our pool — an outside (OTC/governance) step.
