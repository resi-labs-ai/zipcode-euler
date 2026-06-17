# HYDREX DEMO FORK
[zipcode-euler/contracts/src/hydrex-demo-fork]

* This demo is meant to test out the auto-compounder on an Anvil fork of Base, using an existing Hydrex vAMM HYDX/USDC pool.
* An existing pool means that we can test the oHYDX redemption path inside of the auto-compounder.
* The mainnet version can be deployed after the vAMM szALPHA/zipUSD pool is live, with the Ichi strategy enabled.

Base (chain 8453). Solidity 0.8.24.

* Deploy and Test on Anvil.
* Hook up Zodiac `enableModule` to the existing engine Safe.
* Speak with Hydrex about setting up the szALPHA/zipUSD vAMM pool, and Ichi strategy.

==================================================================================
Contract → Chain

These are meant to price, and deposit, and farm the HYDX/USDC vAMM pool on the Anvil fork of Base.

- SzipNavOracleDemoVAMM.sol → Base 8453
A fork of SzipNavOracle (8-B4). Identical except the LP-leg valuation: it prices a live Solidly vAMM pair via `getReserves()` (+ HYDX/USDC pricing) instead of an ICHI vault.

- LpStrategyModuleDemoVAMM.sol → Base 8453
A fork of LpStrategyModule (8-B6). Identical except `addLiquidity`: it builds vAMM LP by transferring both legs to the pair → `IVammPair.mint` (routerless, no approval) instead of an ICHI deposit. `stake`/`unstake` unchanged.

Interface:
IVammPair.sol → Base 8453
The minimal Solidly pair interface (the pair IS its own LP token). Verified against the live vAMM HYDX/USDC pair.

Deployment:
DeployShowcaseVAMM.s.sol — run AFTER the main deploy (DeployLocal/DeployZipcode), as the team.

Summaries:
[wires/SHOWCASE-VAMM.md]

==================================================================================
References:

The two forks are built on the prod contracts they mirror + the existing Hydrex venue.

[[src/supply/SzipNavOracle.sol]
[wires/8-B4-SzipNavOracle.md]
The prod NAV oracle this forks. Everything but the LP-leg valuation is byte-identical.

[[src/supply/szipUSD/LpStrategyModule.sol]
[wires/8-B6-LpStrategyModule.md]
The prod LP-strategy module this forks. Everything but the LP-mint seam is byte-identical.
