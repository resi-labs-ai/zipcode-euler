# BRIDGE
[zipcode-euler/contracts/src/bridge]

* szALPHA is an LST on Bittensor (964) — it represents Alpha tokens staked in a Bittensor validator. Its bridged mirror circulates on Base, and that's what Zipcode uses in the LP.
* szALPHA has an innate APR, sourced from the Validator.
* Zipcode uses szALPHA tokens in a zipUSD/szALPHA LP pool on Base.
* szALPHA is a part of the zipUSD liquidity mining program, which incentivizes USDC supply to the credit warehouse.

Bittensor EVM (chain 964) ↔ Base (chain 8453), Chainlink CCT lane. Solidity 0.8.24.

* Deployer needs a Validator Key.
* Deploy Bridge to Base and register with Chainlink CCIP.
* Connect Chainlink CRE to push the validator's exchange rate to the Bridge Oracle (APR and NAV are derived on-chain from it).
* Bridge szALPHA to Base.

==================================================================================
Contract → Chain

- SzAlpha.sol → 964
An LST Wrapper on Bittensor, which connects to an existing validator, and mints szALPHA shares; the share price (exchangeRate) rises as staking rewards accrue.

- SzAlphaLockReleasePool.sol → 964
The CCIP bridge endpoint on Bittensor. When szALPHA bridges to Base it's locked here (not burned), so total supply stays intact and the exchange rate stays accurate.

- SzAlphaMirror.sol → Base 8453
The bridged version of szALPHA that circulates on Base.

- SzAlphaTokenPool.sol → Base 8453
The CCIP bridge endpoint on Base. Mints mirror tokens when szALPHA arrives, burns them when it leaves — keeping supply across both chains balanced.

Oracle:
SzAlphaRateOracle.sol → Base 8453
An on-chain price feed for szALPHA. A Chainlink CRE job reads the rate from Bittensor and pushes it to Base.

Deployment: 
[DeploySzAlphaBridge.s.sol]

Summaries:
[wires/8x-01-szALPHA-bridge.md]
[wires/8x-02-SzAlphaRateOracle.md]

Interfaces:
[interfaces/interfaces-bridge.md]

==================================================================================
References: 

[reference/MANIFEST.md]
[reference/rubicon/README.md]

The bridge copies a proven, audited design — Project Rubicon (General TAO Ventures + Chainlink, live since Nov 2025, Hashlock-audited "Secure" Oct 2025). We verified its real contracts on-chain on 2026-06-12 and modeled ours on them.

- Rubicon — [rubicon/LiquidStakedV3.flattened.sol]
SzAlpha was designed to follow Rubicon's live staking contract on Bittensor.

- Subtensor — subtensor @ 1104f2a
Bittensor's source code confirmed the staking commands & number formats.

- EVM Bittensor — evm-bittensor @ 0b8eb3e [opentensor/evm-bittensor]
Examples of how to call Bittensor's built-in staking functions from a contract.

- Chainlink CCIP — chainlink-ccip @ 349cdba [smartcontractkit/chainlink-ccip]
  The official Chainlink bridge building blocks (lock pool, burn/mint pool, lockbox) our pools extend.

- CCIP Starter Kit — ccip-starter-kit-foundry @ da26a78 [smartcontractkit/ccip-starter-kit-foundry]
  The step-by-step recipe for deploying and registering a bridge; what DeploySzAlphaBridge follows.

- Chain Selectors — chain-selectors @ c0421bd [smartcontractkit/chain-selectors]
  The official ID numbers for the Base and Bittensor chains.

- x402 CRE Price Alerts — x402-cre-price-alerts @ d582019 [smartcontractkit/x402-cre-price-alerts]
  The base contract our price oracle inherits to safely receive Chainlink pushes.

- CRE Toolkit — cre-sdk-go, cre-templates, documentation
  [smartcontractkit (see MANIFEST)]
  The toolkit and docs for writing the Chainlink job that reads the rate from Bittensor.

What we did differently from Rubicon: we added our own Chainlink price feed on Base (Rubicon relies on market pricing instead), we charge no fees (our rate is the raw stake-to-supply ratio), and we use a slightly newer version of the Chainlink bridge contracts.
