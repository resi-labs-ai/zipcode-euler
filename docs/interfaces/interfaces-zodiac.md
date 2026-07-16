# INTERFACES — ZODIAC
[zipcode-euler/contracts/src/interfaces/zodiac]

Small interfaces for the Zodiac contracts used at deploy time. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Gnosis Safe is the container for the vaults.
Zodiac Modules are the mechanical operators for the vault's strategies.

Chainlink CRE is the driver for these modules, providing price feeds and operations logic / triggers.

Note: these are interfaces to already-deployed Zodiac contracts — we hand-write only the functions we call. They are separate from the `zodiac-core` `Module` base that our engine modules inherit and compile against.

- IModuleProxyFactory.sol → Zodiac ModuleProxyFactory `0x000000000000aDdB49795b0f9bA5BC298cDda236`
The clone factory. Every engine module (and the warehouse's Roles instance) is a cheap CREATE2 clone of a mastercopy, minted through this factory at deploy time.
[contracts/script/CreditWarehouseDeployer.sol]
[contracts/script/DeployZipcode.s.sol]
[contracts/script/DeployShowcaseVAMM.s.sol]
[../wires/DeployZipcode.md]

- IRoles.sol → Zodiac Roles Modifier v2 (mastercopy `0x9646fDAD06d3e24444381f44362a3B0eB343D337`; each instance is a clone, no fixed address)
The permission layer for the Credit Warehouse. At deploy the script scopes exactly which calls the warehouse may make — deposit/redeem to the senior pool, approve/repay USDC, and nothing else. At runtime WarehouseAdminModule forwards the four warehouse operations through it. The Roles scope is the security boundary.
[contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol]
[contracts/script/CreditWarehouseDeployer.sol]
[../wires/8-Bw-CreditWarehouse.md]

Summaries:
[../wires/interfaces-zodiac.md]

==================================================================================
References:

These declare only the calls we make; signatures are verified against the vendored Zodiac source.

- Zodiac core — [reference/zodiac-core] (the ModuleProxyFactory).
- Zodiac Roles Modifier v2 — [reference/zodiac-modifier-roles] (the Roles permission layer).
