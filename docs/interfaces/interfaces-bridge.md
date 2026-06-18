# INTERFACES — BRIDGE
[zipcode-euler/contracts/src/interfaces/bridge]

Minimal interface shims for the szALPHA bridge (Bittensor 964 ↔ Base 8453). Solidity 0.8.24.

==================================================================================
Two external shims (Chainlink's cross-chain registry; Bittensor's staking precompiles) plus one internal rate interface.

Note: we don't import these contracts' real code — for each one we hand-write a small interface listing only the functions we call, and we verified (with `cast`) that those signatures match the live contracts.

- ICctRegistry.sol → Chainlink CCT admin registry (a pair of contracts, on each chain)
Chainlink's registry for cross-chain tokens — it records which pool handles each bridged token and who administers it. The deploy script registers the szALPHA token and pool here, then transfers the admin role to the protocol's permanent admin. Nothing touches it after deploy.

```
Base 8453
  TokenAdminRegistry         0x6f6C373d09C07425BaAE72317863d7F6bb731e37
  RegistryModuleOwnerCustom  0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f
Bittensor 964
  TokenAdminRegistry         0xe72d25aDd538E8ef9CeF85622eA8912a6CB98Be6
  RegistryModuleOwnerCustom  0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3
```

[contracts/script/DeploySzAlphaBridge.s.sol]
[wires/8x-01-szALPHA-bridge.md]

- ISubtensorPrecompiles.sol → Bittensor 964 system precompiles
Bittensor's built-in staking contracts on 964. SzAlpha stakes and prices through three of them:

```
StakingV2        0x0000000000000000000000000000000000000805   stake, unstake, read the stake
Alpha            0x0000000000000000000000000000000000000808   subnet AMM price + swap quotes
AddressMapping   0x000000000000000000000000000000000000080C   look up the wrapper's coldkey
```

SzAlpha calls them low-level by selector, never as a normal typed call — a typed call to a Bittensor precompile never reaches the runtime.
[contracts/src/bridge/SzAlpha.sol]
[contracts/script/DeploySzAlphaBridge.s.sol]
[wires/8x-01-szALPHA-bridge.md]

- IXAlphaRate.sol → the xALPHA exchange-rate interface (internal)
A single `exchangeRate()` getter: how much alpha one xALPHA is worth (18-dp). The rate comes straight from the staking accounts — staked alpha divided by supply. On 964, SzAlpha computes it natively; on Base, SzAlphaRateOracle serves the rate CRE pushed over. The NAV oracle reads it to value the xALPHA leg of the basket.
[contracts/src/bridge/SzAlpha.sol]
[contracts/src/bridge/SzAlphaRateOracle.sol]
[contracts/src/supply/SzipNavOracle.sol]
[contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol]
[wires/8x-02-SzAlphaRateOracle.md]

Summaries:
[../wires/interfaces-bridge.md]

Contracts:
[../bridge.md]

==================================================================================
References:

The two external shims declare only the calls we make against live contracts; selectors are hand-verified, and units are pinned per function.

- Chainlink CCIP — [reference/chainlink-ccip] (the cross-chain token registry these shim).
- Subtensor / Bittensor — [reference/subtensor] + [reference/evm-bittensor] (the 964 staking precompiles).
- [contracts/script/DeploySzAlphaBridge.s.sol] — holds the on-chain-verified CCT address book for both chains.
