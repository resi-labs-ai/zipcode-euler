# JuniorTrancheDeployer — the reusable per-junior tranche deployer (wiring map)

> Source of truth = the kept code at `contracts/script/JuniorTrancheDeployer.s.sol` + its fork test
> `contracts/test/JuniorTrancheDeployer.t.sol`. Ticket `build/tickets/contracts/CTR-06b-junior-tranche-deployer.md`
> is intent — the code is final. Second built child of the re-scoped CTR-06 (after CTR-06a); the per-silo analogue of
> `CreditWarehouseDeployer`. Spec §6/§7 (junior share + NAV) / §8 (engine) / §11 (loss) / §17 / §4.5 (two-tier admin).
> (PROGRESS "Credit-warehouse scaling + federation substrate" section.)

## Role
The single missing reusable artifact in the federation deploy chain. `DeployZipcode` stamps exactly ONE junior tranche
inline across phases P3/P6/P7/P8/P9 (~30 deployments + ~15 seam asserts, strict ordering); there was no callable to
reproduce it for silo #2..N (unlike the senior warehouse, which has `CreditWarehouseDeployer`). This is that callable:
`deploy(JuniorParams)` stands up ONE self-consistent junior tranche — Baal two-Safe substrate + `SzipNavOracle` +
`ExitGate`/`SzipUSD` + `ZipDepositModule` + the **8** yield/freeze/buy-burn engine modules + the loss side
(`LienXAlphaEscrow` + `DefaultCoordinator`) — wired to THIS silo's `eePool`/`warehouseSafe`/reservoir handles and the
SHARED hub `zipUSD`/`rateOracle`, and returns the handles `SiloRegistry.addSilo` needs. CTR-06c calls it once per silo.

It is a faithful EXTRACTION, not a new mechanism: every ctor/setUp tuple is the one `DeployZipcode` already uses
(re-verified against live source). The two design decisions it embodies are the ratified federation calls D1 + D5.

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `JuniorTrancheDeployer` (`is SummonSubstrate`, so `is Script`) | The callable. `deploy(JuniorParams)` runs the 17-step junior build in load-bearing order, reproduces every `DeployZipcode` seam assert, seals the two `ReceiverTemplate`s' CRE identity, hands the OZ-ownable contracts to the Timelock and BOTH Baal Safes to the persistent `team`, and returns a `JuniorTranche` handle struct. |
| `SummonSubstrate` (inherited) | Supplies `_summon(address,uint256)` + `computeMainSafe` + the `Substrate` struct. The deployer self-summons (`_summon(address(this), saltNonce)`). |
| `IReceiverIdentitySet` (local interface) | The `setExpectedAuthor`/`setExpectedWorkflowId` seal surface on the `ReceiverTemplate`s (`SzipNavOracle`, `DefaultCoordinator`). |

## Wiring — internal (the deploy model)
- **Why self-summon (load-bearing).** CTR-06c calls `new JuniorTrancheDeployer().deploy(...)`, so every internal
  Safe-drive runs with `msg.sender == the deployer instance` — NOT a broadcaster, NOT `team`. The Safe pre-validated
  `v==1` signature path (`SummonSubstrate.s.sol:159-167`) requires `msg.sender == the Safe owner`. So `deploy` calls
  `_summon(address(this), p.saltNonce)`, making the deployer instance the TRANSIENT owner/signer of both Safes — the
  `CreditWarehouseDeployer` deploy-as-self/sign-as-self idiom (`CreditWarehouseDeployer.sol:100-122,173-176`). The
  `DeployZipcode`-local helpers (`_cloneModule:579`, `_enableModuleOnSafe:588`, `_setShamansManager:594`,
  `_execAsTeam:617`) read `i.team`/`i.saltNonce`, so they are reimplemented here parameterized off `address(this)` +
  `p.saltNonce` (the reimplemented `_execAsSelf` signs as the deployer instance), not inherited.
- **The 17 steps** (each mirrors a `DeployZipcode` line, cited in the ticket): 1 summon → 2 `SzipNavOracle` (11-arg) →
  3 `ExitGate`+`SzipUSD`+shareToken-both-ways+windowController → 4 `ZipDepositModule`+`setGate` → 5 shaman grant
  (Gate→manager(2)) + `totalShares()==0` assert → 6 `DurationFreezeModule` FIRST (the `coverageGate`) enabled on BOTH
  Safes → 7 `SzipBuyBurnModule` + engine-safe seam → 8 `ReservoirLoopModule` → 9 `LpStrategyModule` + shared-LP seam →
  10 `HarvestVoteModule` → 11 `ExerciseModule` → 12 `SellModule` → 13 `RecycleModule` + one-bank seam → 14 loss side
  (coordinator FIRST to break the ctor cycle, then escrow, `setEscrow`, `setDefaultCoordinator`) → 15 NAV final wiring
  (`setLpPosition`/`setReservoirLeg`/`setXAlphaRateOracle`) → 16 identity seal + OZ-ownable handoff → 17 Safe handoff.
- **Seam asserts reproduced (fails closed on any mis-wire):** coverage-gate ×2 (buy-burn + LP-strategy →
  `durationFreeze`), engine-safe (NAV == Gate == buy-burn), shared-LP (`lpStrategy.ichiVault() == polIchiVault ==
  escrowVault.asset()`), one-bank (recycle's warehouse/eePool/navOracle == the deposit module's bank + the NAV oracle),
  escrow-coordinator, NAV share-token-set, shaman/`totalShares==0`.
- **Ownership split (the §4.5 two-tier model).** OZ-ownable contracts (`navOracle`, `gate`, `szip`, `escrow`, `coord`)
  → the **Timelock** (`transferOwnership`); the 8 engine modules are ALREADY Timelock-owned from `setUp`
  (`owner_ == p.timelock`) and are NOT re-transferred (would revert); the two Baal Safes → the persistent **`team`**
  admin multisig (step 17, `swapOwner` from the transient deployer-self, `prevOwner` located by traversing
  `getOwners()`), asserted by `SafeHandoffFailed` (`isOwner(team)` true on both AND `isOwner(self)` false on both).
  `ZipDepositModule` has no ownable surface; the shared `rateOracle` is an input the deployer never owns (NOT transferred).
- **Non-commingling (Key req 5).** Asserts `sub.juniorTrancheSafe != warehouseSafe && sub.juniorTrancheSidecar != warehouseSafe` — STRENGTHENS
  `DeployZipcode`'s `SeamWarehouseCommingled` (`:291`, which checks only the main Safe) by also covering the juniorTrancheSidecar.

## Wiring — cross-component (who points at whom)
- **← `SiloDeployer`** (CTR-06c, not yet built) is the sole intended caller: it builds the EE pool + reservoir market
  (via the CTR-06a-fixed `ReservoirMarketDeployer`) + warehouse (via `CreditWarehouseDeployer`), then calls
  `new JuniorTrancheDeployer().deploy(JuniorParams{...})` and feeds the returned handles + the warehouse-side
  `adapter`/`warehouseSafe`/`eePool`/`curator` to `SiloRegistry.addSilo`.
- **→ shared hub (inputs, never deployed/re-pointed here):** `zipUSD`, `rateOracle`, `timelock`, `team`. Per D2,
  `zipUSD.setCapacity(depositModule, max)` is a post-deploy Timelock grant (CTR-06c runbook), NOT inline — the deposit
  module is topology-valid but cannot mint until that grant lands.
- **→ per-silo upstream handles (inputs):** `eePool`, `warehouseSafe`, `escrowVault`, `borrowVault`, `polIchiVault`,
  `polGauge` — all built by CTR-06c and passed in.
- **Returned `JuniorTranche` → `SiloRegistry` topology** (`SiloRegistry.sol:159-165`): this deployer's outputs satisfy
  clauses 1–5 (freeze.{eulerEarn,warehouse,navOracle}, escrow.coordinator, coord.navOracle); clause 6's `adapter` is
  CTR-06c's warehouse-side input.

## Item-10 / deploy facts
- **D1 (POL sharing) RATIFIED:** `polIchiVault` + `polGauge` are deploy `JuniorParams` INPUTS — one shared pool address
  across silos by default; each silo's `juniorTrancheSafe` stakes its own LP position. (Real pool not live — M1 stand-in on the
  WETH/USDC vault, PROGRESS "BLOCKED (external)".) No `setLpTwapWindow` (the fair-LP TWAP branch) — M1 uses the
  CRE-push LP mark.
- **D5 (senior off-ramp) RATIFIED:** EXCLUDES `OffRampModule` + `ZipRedemptionQueue.setRedeemController`. The junior
  tranche carries the 8 yield/freeze/buy-burn engine modules, NOT 9; the senior off-ramp stays hub-level (one shared
  OffRamp/rq Safe — N silos cannot each be the queue's sole `redeemController`). CRE-02 + the federation decision own it.
- **`saltNonce` MUST be distinct per silo.** Within ONE silo deploy the same nonce is safe across all CREATE2
  deployments (each module clone has a distinct mastercopy+initializer; the Baal/Safe uses a different factory). The
  guaranteed CROSS-silo collision is the main Safe (its `createProxyWithNonce` initializer is empty/silo-invariant).

## Gotchas
- **NAV leg tokens are `JuniorParams` inputs, not `BaseAddresses.*` constants (load-bearing for testability).** The
  freeze `setUp` reads `zipUSD/usdc/xAlpha/hydx/oHydx` LIVE off the NAV oracle (`DurationFreezeModule.sol:130-135`),
  and the NAV oracle marks `xAlpha.exchangeRate()`/`oHydx.discount()` unconditionally. So `usdc`/`xAlphaMirror`/`hydx`/
  `oHydx` (plus the shared `zipUSD`) are passed in: production passes `BaseAddresses.*`; the D3 fork test injects mocks
  (`DurationFreezeModule.t.sol:1286-1295` is the precedent). Venue infra the modules only STORE and never call at
  `setUp` (`EVC`, `COW_SETTLEMENT`, `ALGEBRA_SWAP_ROUTER`, `HYDREX_VOTER`/`HYDREX_REWARDS_DISTRIBUTOR`, the
  `CRE_KEYSTONE_FORWARDER`) stays a `BaseAddresses.*` constant inside the deployer.
- **`is Script` → forge-only.** Inheriting `SummonSubstrate` (which `is Script`) makes the deployer cheatcode-dependent
  (`_summon` → `computeMainSafe` → `vm.computeCreate2Address`); it is a forge script/test-time orchestrator, not a plain
  on-chain factory. Hence the `.s.sol` filename. CTR-06c (also a script) `new`s it under the same posture.
- **The deposit module is pinned to the throwaway deployer instance.** `ZipDepositModule`'s `setGate` admin is its
  immutable `deployer` (this transient instance) — `setGate` runs inline in step 4, and the module is never re-homed.
  Same known build-phase limitation as `DeployZipcode:560-562`; acceptable (the gate is wired before the instance dies).

## Test (the D3 gate)
`contracts/test/JuniorTrancheDeployer.t.sol` — a fork test on `_selectBaseFork()` (live `BaalAndVaultSummoner` + live
EVK/EVC). Injects mock NAV legs (`zip/usdc/xalpha/hydx/ohydx`) + `MockEulerEarn` (eePool) + `MockLpToken` (polIchiVault,
with `token0/token1` for `LpStrategyModule.setUp`) + `MockGauge` (`rewardToken` for `HarvestVoteModule.setUp`); builds
the reservoir escrow/borrow vaults via the REAL `ReservoirMarketDeployer` over the live EVK + a CRE-marked
`SzipReservoirLpOracle`. 4 tests, all green: `test_deploy_seams_hold` (every inline seam passes), `test_ownership_handoff`
(OZ→Timelock, 8 modules→Timelock, both Safes→team & NOT the deployer, rate oracle wired-not-owned), 
`test_addSilo_topology_clauses_1_to_5` (a REAL `SiloRegistry.addSilo` from a pranked Timelock — reverts `SiloMiswired`
if any clause fails), `test_non_commingling`.
