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
An LST Wrapper on Bittensor, which connects to an existing validator, and mints szALPHA shares; the share price (exchangeRate) rises as staking rewards accrue. It is the only contract with a stake surface, and the only upgradeable one (UUPS). Two authorities, set from genesis: owner() is a TimelockController (gates the UUPS upgrade and pause), and ccipAdmin is a separate registrar-only role (no mint, upgrade, or fund power). deposit() is pausable; redeem() is never pausable by design — share value is anchored to redeemability.

- SzAlphaLockReleasePool.sol → 964
The CCIP bridge endpoint on Bittensor. When szALPHA bridges to Base it's locked here (not burned), so total supply stays intact and the exchange rate stays accurate.

- ERC20LockBox (vendored canonical) → 964
The custody vault behind SzAlphaLockReleasePool. Locked szALPHA is held here, not in the pool itself — the pool is only an authorized caller. An RMN/CCIP pool rotation re-points the authorized caller; funds never migrate.

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
Security X-Ray (audit fidelity)

Every contract in this folder has a dedicated, test-connected X-Ray under contracts/src/bridge/x-ray/. All five are rated ADEQUATE; the bridge test suite runs 55/55 + 22/22 green (SzAlphaBridge.t.sol + SzAlphaRateOracle.t.sol). The X-Rays are the authoritative security artifact; the wires summaries below are the code-truth wiring maps.

[contracts/src/bridge/x-ray/x-ray.md] — scope-level overview + verdict
[contracts/src/bridge/x-ray/SzAlpha.md]
[contracts/src/bridge/x-ray/SzAlphaRateOracle.md]
[contracts/src/bridge/x-ray/SzAlphaLockReleasePool.md]
[contracts/src/bridge/x-ray/SzAlphaTokenPool.md]
[contracts/src/bridge/x-ray/SzAlphaMirror.md]

The load-bearing properties an auditor should check (full catalog + test connection live in the X-Rays):

* I-1 — exchangeRate() is always backing-over-supply with a 1/1 virtual offset: (stake18 + 1) · 1e18 / (totalSupply + 1). It moves only on real stake change or mint/burn, never on a manipulable pool price.
* I-2 — shares are minted/burned ONLY against the measured precompile stake delta, never against msg.value or an estimate.
* X-1 (top residual, on-chain=No) — the contract guards only the SIGN of the precompile stake/balance change; the MAGNITUDE minted or paid is whatever the Subtensor runtime reports. The precompile is trusted runtime; the blast radius is characterized by a lying-mock test (over-report → proportional over-issuance).
* E-1 (deploy-topology, on-chain=No) — cross-chain rate truth requires the 964 side to be LOCK/RELEASE (not burn) and both lanes to share 18 decimals. Burn-on-964 would shrink local supply against unchanged stake and inflate the rate. The decimals leg is enforced on-chain (guard G-18); the lock-vs-burn placement is a deploy choice (seam S2 in the system map).
* Rate oracle — no deviation band by design (a validator slash legitimately lowers the rate). The only defenses are DON f+1 consensus (off-chain), strict timestamp monotonicity, and the consumer's fresh() gate; every NAV consumer must gate on fresh().

==================================================================================
How the bridge connects to the rest of the protocol

The bridge produces one fact the rest of the protocol prices off: the xALPHA exchange rate. It is native only on 964 and reaches Base-side consumers through the CRE push.

  SzAlpha.exchangeRate() (964)
    → CRE workflow push
    → SzAlphaRateOracle (Base, an IXAlphaRate drop-in)
    → SzipNavOracle xALPHA NAV leg
    → NAV → ExitGate issuance (S8) / SzipBuyBurnModule bid (S10) / DurationFreezeModule floor (S9)

The SzAlphaMirror is the xALPHA BALANCE leg: the bridged token actually held by the zipUSD/szALPHA basket LP (8-B5/8-B6) and by the first-loss escrow 8-Bx LienXAlphaEscrow.xAlpha. Rate and balance are distinct sources by construction — the mirror has no exchangeRate(), the rate oracle has no balanceOf().

SzipNavOracle gates ISSUANCE on the oracle's fresh() (navEntry reverts StaleRate, seam S3); EXIT is intentionally unaffected and prices off the last good rate (the issuance/exit asymmetry).

The full cross-contract seam catalog (S1 precompile-magnitude, S2 conservation-topology, S3 freshness, S4 CRE Forwarder, S8–S10 NAV consumers) lives in:
[wires/SYSTEM-SEAM-MAP.md]

Consumers (their own wiring maps):
[wires/8-B4-SzipNavOracle.md]
[wires/8-Bx-LienXAlphaEscrow.md]
[wires/ExitGate-szipUSD.md]

Post-deploy obligations (the 2-step CCIP registry-admin handoffs, SEC-03/H4):
[contracts/script/RUNBOOK-mainnet-deploy.md]

==================================================================================
References: 

[reference/MANIFEST.md]
[reference/rubicon/README.md]

The bridge copies a proven, audited design — Project Rubicon (General TAO Ventures + Chainlink, live since Nov 2025, Hashlock-audited "Secure" Oct 2025). We verified its real contracts on-chain and modeled ours on them.

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
