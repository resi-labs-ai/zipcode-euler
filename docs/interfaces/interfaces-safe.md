# INTERFACES — SAFE
[zipcode-euler/contracts/src/interfaces/safe]

Small interfaces for the Gnosis Safe contracts the modules and deploy scripts drive. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Gnosis Safe is the core container for the Junior Tranche, as well as the Credit Warehouse.

Note: Gnosis Safe is on an older Solidity/OZ version than our build, so we don't compile it — we hand-write small interfaces with only the functions we call, matched to the verified on-chain ABI.

- ISafe.sol → a Gnosis Safe (SafeL2 1.4.1 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`)
The Safe itself. Modules and deploy scripts drive Safes through it: enable a module, execute a transaction, manage owners. The DurationFreezeModule drives both the main and juniorTrancheSidecar Safes to rotate shares; the deploy scripts set Safes up and hand off ownership.
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[contracts/script/SummonSubstrate.s.sol]
[contracts/script/CreditWarehouseDeployer.sol]
[contracts/script/DeployZipcode.s.sol]
[contracts/script/DeployShowcaseVAMM.s.sol]
[wires/8-B1.md]

- ISafeProxyFactory.sol → Gnosis Safe proxy factory
Deploys new Safes, and lets us compute a Safe's address before it exists. The warehouse deployer uses the generic factory to deploy the warehouse Safe; the summon script reads the Baal-owned factory to precompute the main Safe's address (Baal deploys that one).
Two different 1.3.0 factories — don't conflate them:

```
generic 1.3.0   0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2   warehouse Safe
Baal's own      0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC   main-Safe address precompute
```

[contracts/script/CreditWarehouseDeployer.sol]
[contracts/script/SummonSubstrate.s.sol]
[wires/8-Bw-CreditWarehouse.md]
[wires/8-B1.md]

Summaries:
[../wires/interfaces-safe.md]

==================================================================================
References:

These declare only the calls we make, matched to the Basescan-verified ABI (never compiled — Safe can't share a build with Euler's newer OZ).

- Module calls go through the Safe as Call-only with zero value — no delegatecall, no ETH.
