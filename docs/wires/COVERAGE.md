# wires/ — coverage manifest (every file in `contracts/` → its doc)

Provable completeness check for the wiring map. Every Solidity file under `contracts/` is mapped to the
`wires/` doc that documents it. Inventory taken 2026-06-10, updated 2026-06-12 (8x-01 lock/release rework
added `SzAlphaLockReleasePool.sol`; deploy-track sweep added `DeployLocal.s.sol`/`DeployMainnet.s.sol`/
`test/DeployZipcode.t.sol`), updated 2026-06-14 (fair-LP oracle added `ConcentratedLiquidity.sol` +
`IchiAlgebraFairReserves.sol` + `AlgebraIchiFairLpOracle.sol` + `IAlgebraOraclePlugin.sol` +
`AlgebraIchiFairLpOracle.t.sol`), updated 2026-06-16 (CTR-01 added `CloneReportReceiver.sol` — the reusable
clone-safe CRE report socket), updated 2026-06-18 (CTR-02 added `SiloRegistry.sol` — the multi-pool/federation
silo catalog + admission gate, the first contract of the scaling/federation workstream), updated 2026-06-18 (CTR-05
added `SeniorNavAggregator.sol` — the donation-immune Σ senior par-backing view across silos, fourth contract of the
scaling/federation workstream), updated 2026-06-19 (CTR-06b added `script/JuniorTrancheDeployer.s.sol` — the reusable
per-junior tranche deployer, the per-silo analogue of `CreditWarehouseDeployer`, + its fork test), updated 2026-06-19
(CTR-06c added `script/SiloDeployer.s.sol` — the silo orchestrator that composes the four sub-deployers + the per-silo
venue front into one complete silo, the final child of the re-scoped CTR-06, + its fork test), updated 2026-06-19
(CTR-08 added the behavior note `CTR-08-structure-2-revolving.md` — structure-2 revolving lines as an operating mode
over the as-built stack, ZERO contract change; the 5 revolving tests + the CTR-04 withdraw-queue mock regression fix
land in the existing `test/ZipcodeController.t.sol`): **39 product
contracts + 11 scripts + 31 interface shims + 34 test/helper files**, plus a **demo/fork-only addendum** (section E): **2
showcase contracts + 1 demo interface + 1 demo deploy script**, kept SEPARATE from the audited core counts. Nobody
forgotten.

## A. Product contracts (`src/`, non-interface) — 39 files
| File | Doc |
|---|---|
| `src/SiloRegistry.sol` | `CTR-02-SiloRegistry.md` |
| `src/SeniorNavAggregator.sol` | `CTR-05-SeniorNavAggregator.md` |
| `src/libraries/ConcentratedLiquidity.sol` | `FairLpOracle.md` |
| `src/supply/lib/IchiAlgebraFairReserves.sol` | `FairLpOracle.md` |
| `src/supply/AlgebraIchiFairLpOracle.sol` | `FairLpOracle.md` |
| `src/CREGatingHook.sol` | `WOOF-03.md` |
| `src/LienCollateralToken.sol` | `WOOF-01.md` |
| `src/LienTokenFactory.sol` | `WOOF-01.md` |
| `src/ZipcodeController.sol` | `WOOF-05.md` |
| `src/ZipcodeDeployAsserts.sol` | `WOOF-10a.md` |
| `src/ZipcodeOracleRegistry.sol` | `WOOF-02.md` |
| `src/venue/EulerVenueAdapter.sol` | `WOOF-04.md` |
| `src/venue/IZipcodeVenue.sol` | `WOOF-04.md` |
| `src/venue/LineAccount.sol` | `WOOF-04.md` |
| `src/supply/ZipDepositModule.sol` | `WOOF-06.md` |
| `src/supply/ZipRedemptionQueue.sol` | `9-ZipRedemptionQueue.md` |
| `src/supply/SzipNavOracle.sol` | `8-B4-SzipNavOracle.md` |
| `src/supply/SzipReservoirLpOracle.sol` | `8-B5-ReservoirLoop.md` |
| `src/supply/CreditWarehouse/WarehouseAdminModule.sol` | `8-Bw-CreditWarehouse.md` |
| `src/supply/szipUSD/DurationFreezeModule.sol` | `DurationFreezeModule.md` |
| `src/supply/szipUSD/ExerciseModule.sol` | `8-B8-ExerciseModule.md` |
| `src/supply/szipUSD/ExitGate.sol` | `ExitGate-szipUSD.md` |
| `src/supply/szipUSD/HarvestVoteModule.sol` | `8-B7-HarvestVoteModule.md` |
| `src/supply/szipUSD/LpStrategyModule.sol` | `8-B6-LpStrategyModule.md` |
| `src/supply/szipUSD/OffRampModule.sol` | `OffRampModule.md` |
| `src/supply/szipUSD/RecycleModule.sol` | `8-B10-RecycleModule.md` |
| `src/supply/szipUSD/ReservoirBorrowGuard.sol` | `8-B5-ReservoirLoop.md` |
| `src/supply/szipUSD/ReservoirLoopModule.sol` | `8-B5-ReservoirLoop.md` |
| `src/supply/szipUSD/SellModule.sol` | `8-B9-SellModule.md` |
| `src/supply/szipUSD/SzipBuyBurnModule.sol` | `8-B14-SzipBuyBurnModule.md` |
| `src/supply/szipUSD/CloneReportReceiver.sol` | `8-B14-SzipBuyBurnModule.md` (CTR-01 — reusable clone-safe CRE report socket) |
| `src/supply/szipUSD/SzipUSD.sol` | `ExitGate-szipUSD.md` |
| `src/loss/DefaultCoordinator.sol` | `DefaultCoordinator.md` |
| `src/loss/LienXAlphaEscrow.sol` | `8-Bx-LienXAlphaEscrow.md` |
| `src/bridge/SzAlpha.sol` | `8x-01-szALPHA-bridge.md` |
| `src/bridge/SzAlphaMirror.sol` | `8x-01-szALPHA-bridge.md` |
| `src/bridge/SzAlphaTokenPool.sol` | `8x-01-szALPHA-bridge.md` |
| `src/bridge/SzAlphaLockReleasePool.sol` | `8x-01-szALPHA-bridge.md` |
| `src/bridge/SzAlphaRateOracle.sol` | `8x-02-SzAlphaRateOracle.md` |

## B. Deploy/helper scripts (`script/`) — 11 files
| File | Doc |
|---|---|
| `script/DeployZipcode.s.sol` | `DeployZipcode.md` |
| `script/JuniorTrancheDeployer.s.sol` | `CTR-06b-JuniorTrancheDeployer.md` |
| `script/SiloDeployer.s.sol` | `CTR-06c-SiloDeployer.md` |
| `script/SzipPerspectiveProbe.sol` | `WOOF-04.md` (SEC-08 deploy-time line-vault perspective probe) |
| `script/DeployLocal.s.sol` | `DeployZipcode.md` (anvil-fork wrapper of the orchestrator) |
| `script/DeployMainnet.s.sol` | `DeployZipcode.md` + `script/RUNBOOK-mainnet-deploy.md` (live-network wrapper) |
| `script/BaseAddresses.sol` | `WOOF-00.md` |
| `script/SummonSubstrate.s.sol` | `8-B1.md` |
| `script/CreditWarehouseDeployer.sol` | `8-Bw-CreditWarehouse.md` |
| `script/ReservoirMarketDeployer.sol` | `8-B5-ReservoirLoop.md` |
| `script/DeploySzAlphaBridge.s.sol` | `8x-01-szALPHA-bridge.md` |

## C. Interface shims (`src/interfaces/`) — 31 files, cataloged per folder
Each file is cataloged file-by-file inside its `interfaces-<folder>.md`.
| File | Doc |
|---|---|
| `src/interfaces/algebra/IAlgebraFactory.sol` | `interfaces-algebra.md` |
| `src/interfaces/algebra/IAlgebraOraclePlugin.sol` | `interfaces-algebra.md` |
| `src/interfaces/algebra/IAlgebraPool.sol` | `interfaces-algebra.md` |
| `src/interfaces/algebra/INonfungiblePositionManager.sol` | `interfaces-algebra.md` |
| `src/interfaces/algebra/ISwapRouter.sol` | `interfaces-algebra.md` |
| `src/interfaces/baal/IBaal.sol` | `interfaces-baal.md` |
| `src/interfaces/baal/IBaalAndVaultSummoner.sol` | `interfaces-baal.md` |
| `src/interfaces/baal/IBaalSummoner.sol` | `interfaces-baal.md` |
| `src/interfaces/baal/IBaalToken.sol` | `interfaces-baal.md` |
| `src/interfaces/bridge/ICctRegistry.sol` | `interfaces-bridge.md` |
| `src/interfaces/bridge/ISubtensorPrecompiles.sol` | `interfaces-bridge.md` |
| `src/interfaces/bridge/IXAlphaRate.sol` | `interfaces-bridge.md` |
| `src/interfaces/cow/IGPv2Settlement.sol` | `interfaces-cow.md` |
| `src/interfaces/euler/IEulerEarn.sol` | `interfaces-euler.md` |
| `src/interfaces/euler/IEulerEarnUtil.sol` | `interfaces-euler.md` |
| `src/interfaces/euler/IZipUSD.sol` | `interfaces-euler.md` |
| `src/interfaces/hydrex/IGauge.sol` | `interfaces-hydrex.md` |
| `src/interfaces/hydrex/IOptionToken.sol` | `interfaces-hydrex.md` |
| `src/interfaces/hydrex/IRewardsDistributor.sol` | `interfaces-hydrex.md` |
| `src/interfaces/hydrex/IVoter.sol` | `interfaces-hydrex.md` |
| `src/interfaces/hydrex/IVotingEscrow.sol` | `interfaces-hydrex.md` |
| `src/interfaces/ichi/IICHIDepositGuard.sol` | `interfaces-ichi.md` |
| `src/interfaces/ichi/IICHIVault.sol` | `interfaces-ichi.md` |
| `src/interfaces/ichi/IICHIVaultFactory.sol` | `interfaces-ichi.md` |
| `src/interfaces/loss/ILienXAlphaEscrow.sol` | `interfaces-loss.md` |
| `src/interfaces/loss/ISzipNavOracle.sol` | `interfaces-loss.md` |
| `src/interfaces/safe/ISafe.sol` | `interfaces-safe.md` |
| `src/interfaces/safe/ISafeProxyFactory.sol` | `interfaces-safe.md` |
| `src/interfaces/supply/ISzipNavBasket.sol` | `interfaces-supply.md` |
| `src/interfaces/zodiac/IModuleProxyFactory.sol` | `interfaces-zodiac.md` |
| `src/interfaces/zodiac/IRoles.sol` | `interfaces-zodiac.md` |

## D. Tests & helpers (`test/`) — 34 files (verification, covered by their component doc)
Tests are the verification artifact for a component, not a separate component — each is covered by the
component doc named below (the doc's "Wiring internal" + "Item-10 deploy facts" are what the test proves).
| Test/helper file | Component doc |
|---|---|
| `test/SiloRegistry.t.sol` | `CTR-02-SiloRegistry.md` |
| `test/JuniorTrancheDeployer.t.sol` | `CTR-06b-JuniorTrancheDeployer.md` |
| `test/SiloDeployer.t.sol` | `CTR-06c-SiloDeployer.md` |
| `test/SeniorNavAggregator.t.sol` | `CTR-05-SeniorNavAggregator.md` |
| `test/DeployZipcode.t.sol` | `DeployZipcode.md` |
| `test/ForkConfig.sol` | `WOOF-00.md` (the fork helper) |
| `test/mocks/MockEulerEarn.sol` | `WOOF-00.md` / `interfaces-euler.md` (EulerEarn is mocked, 0.8.26) |
| `test/bridge/BridgeMocks.sol` | `8x-01-szALPHA-bridge.md` |
| `test/bridge/SzAlphaBridge.t.sol` | `8x-01-szALPHA-bridge.md` |
| `test/bridge/SzAlphaRateOracle.t.sol` | `8x-02-SzAlphaRateOracle.md` |
| `test/CREGatingHook.t.sol` | `WOOF-03.md` |
| `test/LienToken.t.sol` | `WOOF-01.md` |
| `test/ZipcodeOracleRegistry.t.sol` | `WOOF-02.md` |
| `test/EulerVenueAdapter.t.sol` | `WOOF-04.md` |
| `test/ZipcodeController.t.sol` | `WOOF-05.md` (+ `CTR-08-structure-2-revolving.md` — the revolving-mode section + the CTR-04 mock regression fix) |
| `test/ZipcodeDeployIdentityGate.t.sol` | `WOOF-10a.md` |
| `test/ZipDepositModule.t.sol` | `WOOF-06.md` |
| `test/SummonSubstrate.t.sol` | `8-B1.md` |
| `test/SzipNavOracle.t.sol` | `8-B4-SzipNavOracle.md` |
| `test/AlgebraIchiFairLpOracle.t.sol` | `FairLpOracle.md` |
| `test/ExitGate.t.sol` | `ExitGate-szipUSD.md` |
| `test/WarehouseAdminModule.t.sol` | `8-Bw-CreditWarehouse.md` |
| `test/ZipRedemptionQueue.t.sol` | `9-ZipRedemptionQueue.md` |
| `test/OffRampModule.t.sol` | `OffRampModule.md` |
| `test/SzipBuyBurnModule.t.sol` | `8-B14-SzipBuyBurnModule.md` |
| `test/ReservoirLoopModule.t.sol` | `8-B5-ReservoirLoop.md` |
| `test/LpStrategyModule.t.sol` | `8-B6-LpStrategyModule.md` |
| `test/HarvestVoteModule.t.sol` | `8-B7-HarvestVoteModule.md` |
| `test/ExerciseModule.t.sol` | `8-B8-ExerciseModule.md` |
| `test/SellModule.t.sol` | `8-B9-SellModule.md` |
| `test/RecycleModule.t.sol` | `8-B10-RecycleModule.md` |
| `test/DurationFreezeModule.t.sol` | `DurationFreezeModule.md` |
| `test/LienXAlphaEscrow.t.sol` | `8-Bx-LienXAlphaEscrow.md` |
| `test/DefaultCoordinator.t.sol` | `DefaultCoordinator.md` |

## E. Demo / fork-only contracts (mainnet showcase) — NOT part of the audited core
The vAMM auto-compounder showcase (SP-18): surgical forks of the verified NAV oracle + LP module that price/stake an
EXISTING live vAMM HYDX/USDC venue, deployed alongside the prod system (do not ship as core). All → `SHOWCASE-VAMM.md`.
| File | Doc |
|---|---|
| `src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` | `SHOWCASE-VAMM.md` |
| `src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol` | `SHOWCASE-VAMM.md` |
| `src/interfaces/hydrex/IVammPair.sol` | `SHOWCASE-VAMM.md` |
| `script/DeployShowcaseVAMM.s.sol` | `SHOWCASE-VAMM.md` |

## Recheck command
To re-verify nothing was added since this manifest, diff the live tree against the rows above:
```
find contracts/src contracts/script -name '*.sol' | sort
```
Any file not in sections A–E above needs a doc (or a row here).
