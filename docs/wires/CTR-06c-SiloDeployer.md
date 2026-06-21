# SiloDeployer — the silo orchestrator (wiring map)

> Source of truth = the kept code at `contracts/script/SiloDeployer.s.sol` + its fork test
> `contracts/test/SiloDeployer.t.sol`. Ticket `build/tickets/contracts/CTR-06c-silo-deployer-orchestrator.md` is
> intent — the code is final. Third + final built child of the re-scoped CTR-06 (after CTR-06a + CTR-06b); the
> orchestrator that composes a complete venue silo and returns the handle the Timelock registers. Spec
> §4.5/§4.7/§9.1/§17. (PROGRESS "Credit-warehouse scaling + federation substrate" section.)

## Role
The capstone of the federation deploy chain: one `deploy(SiloParams)` stands up ONE complete, self-consistent venue
silo by composing the four verbatim sub-deployers + the per-silo venue front, and returns a `Silo` handle that maps
1:1 to `SiloRegistry.SiloConfig`. It makes "fill the active pool to 28 → deploy the next silo → route there → register"
real (the sequential-fill sharding decision). It builds NOTHING the hub owns — the hub (Timelock / controller /
oracleRegistry / zipUSD / rateOracle / shared `ZipRedemptionQueue` / erebor / forwarder / shared POL / EVC+EVK factory)
is a deploy INPUT. It is pure composition + the per-silo venue front; it invents no mechanism.

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `SiloDeployer` (`is Script`) | The callable. `deploy(SiloParams)` runs the load-bearing 0–9 build order, builds the per-silo venue front (EE pool + resting `usdcReservoir` + per-silo `CREGatingHook` + `EulerVenueAdapter`), composes the farm utility/warehouse/junior sub-deployers, runs the fail-closed post-asserts, and returns a `Silo` handle. `is Script` (not a plain factory) because it calls `JuniorTrancheDeployer.computeMainSafe`, a `vm`-using view. |
| `FarmUtilityMarketDeployer` (CTR-06a) | Builds this silo's farm utility escrow/borrow vaults (governor = Timelock). |
| `CreditWarehouseDeployer` (8-Bw) | Builds this silo's senior warehouse `{Safe, Roles, WarehouseAdminModule}`; `redemptionBox` = the SHARED queue. |
| `JuniorTrancheDeployer` (CTR-06b) | Builds this silo's junior tranche (Baal substrate + NAV + ExitGate/SzipUSD + deposit module + 8 engine modules + loss side). |
| `CREGatingHook` (per-silo) | A fresh hook per silo, `borrowDriver` → THIS silo's adapter, owner → Timelock. |
| `EulerVenueAdapter` (per-silo) | The 1:1-with-the-pool venue adapter (10-arg ctor); also the registry `curator`/`venueOf`. |
| `IFreeze`/`IEscrow`/`INavWriter`/`IAdapter` (local interfaces) | The getters the step-8 `addSilo` 6-clause pre-flight dereferences (mirror `SiloRegistry.sol`'s). |

## Wiring — internal (the build model, steps 0–9)
- **0. Precompute the junior juniorTrancheSafe (breaks the farm utility↔junior circular dependency — load-bearing).** The farm utility
  market needs `juniorTrancheEngine` = the junior `juniorTrancheSafe` (the `FarmUtilityBorrowGuard` pins `OP_BORROW` to it, IMMUTABLE), but
  `JuniorTrancheDeployer.deploy` is monolithic — it self-summons its Baal internally AND consumes the farm utility's
  `escrowVault`/`borrowVault` as inputs. Resolved WITHOUT a CTR-06b change: instantiate `jr = new JuniorTrancheDeployer()`
  once, precompute `juniorTrancheEngine = jr.computeMainSafe(p.saltNonce)`. `computeMainSafe` (`SummonSubstrate.s.sol:110-118`) is
  a pure function of `saltNonce` + the live Safe factory/singleton — caller-independent — so the precompute EQUALS the
  `juniorTrancheSafe` `jr.deploy(...)` later summons (CTR-06b's `MainSafeMismatch` assert `:91` guarantees it). The SAME `jr`
  instance is reused in step 7 so the salt + summon match.
- **1. EE pool** — `_createEePool(p)`, a `virtual internal` D3 seam. Base impl: the live-factory `.call`
  (`createEulerEarn(p.timelock, 0, p.usdc, p.eeName, p.eeSymbol, bytes32(p.saltNonce))`, `DeployLocal.s.sol:115-122`).
  `initialTimelock = 0` or the first `openLine` reverts `EulerEarnTimelockNonZero` (`EulerVenueAdapter.sol:80`). The
  test overrides it to return a `MockEulerEarn`.
- **2. Resting `usdcReservoir`** — SiloDeployer CREATES it (bare EVK proxy `createProxy(0,false,(usdc,0,0))` +
  `setHookConfig(0,0)`; `DeployLocal.s.sol:108-112`). NOT an input.
- **3. Farm utility market** — `new FarmUtilityMarketDeployer().deploy(Params{... juniorTrancheEngine, lpOracle, governor=timelock ...})`.
  `lpOracle` is a built-and-SEEDED INPUT (`setLTV`'s `getQuote` reverts without a resolvable LP mark, and the mark is a
  CRE/forwarder push the deployer cannot make).
- **4. EE admin config** (low-level `_eeCall`/`abi.encodeWithSignature` — the EE admin ABI is NOT compiled in): split —
  4a (after markets exist) `submitCap`+`acceptCap` for `usdcReservoir` + `borrowVault`, `setSupplyQueue([base])`; 4b
  (after the warehouse + adapter exist) `setFeeRecipient(warehouseSafe)` + `setCurator(adapter)`. **No
  `SzipPerspectiveProbe`** — it is a deploy-time advisory needing the live EE factory `creator()`, mock-incompatible;
  it stays a fork-runbook step, NOT part of `deploy`.
- **5. Per-silo venue front** — `new CREGatingHook(factory, evc, address(0))` → `new EulerVenueAdapter(controller, evc,
  eePool, factory, oracleRegistry, hook, lineIrm, usdc, erebor, usdcReservoir)` → `hook.setBorrowDriver(adapter)` →
  `hook.transferOwnership(timelock)`.
- **6. Warehouse** — `new CreditWarehouseDeployer().deploy(godOwner, address(this), eePool, usdc, forwarder,
  redemptionBox=SHARED queue, saltNonce)` (Safe/Roles → `godOwner`). **CTR-16:** the deployer takes TRANSIENT
  ownership of the WAM (the CRE warehouse admin adapter) to seal its identity (`setExpectedAuthor` +
  `setExpectedWorkflowName(WORKFLOW_NAME_WAREHOUSE)` — closing the folded-in hole where silos 2+ shipped the WAM
  forwarder-only), then `transferOwnership(timelock)` — uniform with silo-0's WAM (`DeployZipcode` P9).
- **7. Junior tranche** — `jr.deploy(JuniorParams{... eePool, warehouseSafe, escrowVault, borrowVault, shared
  zipUSD/rateOracle/POL, NAV-leg tokens ...})` (all 25 fields threaded from `SiloParams`).
- **8. Fail-closed post-asserts** — §2 non-commingling (`redemptionBox != juniorTrancheSafe`, `warehouseSafe != juniorTrancheSafe/juniorTrancheSidecar` —
  deployer-added; `addSilo` does NOT enforce these), farm utility borrow-vault `governorAdmin() == timelock` (CTR-06a),
  and the `addSilo` 6-clause pre-flight (so the Timelock `addSilo` can't revert `SiloMiswired`).
- **9. Return** the `Silo` handle (first 9 fields → `SiloConfig`; trailing `depositModule`/`warehouseRoles`/`hook` for
  the D2 runbook + observability).

## Wiring — cross-component (who points at whom)
- **→ shared hub (inputs, never built/re-pointed here):** `timelock`, `controller`, `oracleRegistry`, `zipUSD`,
  `rateOracle`, `redemptionBox` (the ONE shared `ZipRedemptionQueue` — every silo's warehouse funds it; D5/§6), `erebor`,
  `forwarder`, `polIchiVault`/`polGauge`, `EVC`/`EVAULT_FACTORY`.
- **← the Timelock D2 runbook** consumes the returned handle: (1) `zipUSD.setCapacity(silo.depositModule, max)`,
  (2) `siloRegistry.addSilo(siloId, SiloConfig{handle})`, (3) `siloRegistry.setCurrentSilo(siloId)`.
  `controller.setRegistry`/`siloRegistry.setController` are the ONE-TIME HUB bring-up (CTR-03/`DeployZipcode`, already
  done; NOT per-silo). This discharges the PROGRESS "DEPLOY OBLIGATION (CTR-03)" as the per-silo runbook.

## Item-10 / deploy facts
- **`CREGatingHook` is PER-SILO, not shared (corrects the CTR-06 index).** Its `borrowDriver` is a SINGLE settable
  address (`CREGatingHook.sol:35,94`) and the `fallback` gate authorizes exactly ONE adapter
  (`isAccountOperatorAuthorized(caller, borrowDriver)`, `:110-113`). N silos = N adapters = N hooks. So the deployer
  builds a fresh hook per silo, mirroring `DeployZipcode.s.sol:212`. The index's "deployed once at the hub, SHARED"
  list-item for the hook is superseded by this.
- **`lpOracle` is a built-and-seeded INPUT.** The runbook builds a `SzipFarmUtilityLpOracle` per silo + CRE pushes its
  first `LP_MARK` BEFORE `SiloDeployer.deploy` (the farm utility `setLTV`'s `getQuote` needs it). The deployer cannot push
  the mark (forwarder-gated).
- **`saltNonce` distinct per silo** (CREATE2 across the Safe factory + Baal summoner + EVK proxies + the EE salt — the
  guaranteed cross-silo collision is the junior main Safe, its initializer is silo-invariant; see CTR-06b's note).
- **D1/D5 ratified** (per CTR-06b): POL pool address shared (per-silo staked position); no per-silo `OffRampModule`
  (senior off-ramp hub-level).

## Gotchas
- **`is Script` → forge-only.** `deploy` calls `computeMainSafe` → `vm.computeCreate2Address`, so the orchestrator is a
  script/test-time deployer, not a plain on-chain factory (the `.s.sol` filename). Same posture as its sub-deployers.
- **The venue adapter's OZ-`Ownable` owner is left as the deployer instance** (like `DeployZipcode`, where the adapter
  is re-homed by a later seal pass, not the spine builder). The hook + junior OZ-ownables + Safes ARE handed off; the
  adapter owner is not (no assert depends on it; documented in the test).
- **Step-4 ordering.** `setFeeRecipient`/`setCurator` need the warehouse Safe + venue adapter (steps 5–6), so the EE
  config is split 4a (caps, pre-warehouse) / 4b (recipient+curator, post-warehouse). Cap onboarding does not depend on
  the curator.

## Test (the D3/D4 gate)
`contracts/test/SiloDeployer.t.sol` — a fork test on `_selectBaseFork()` (live `BaalAndVaultSummoner` + live EVK/EVC),
modeled on `JuniorTrancheDeployer.t.sol`. EE is mocked via a `_createEePool` override returning a small COMBINED
`MockEulerEarn` (settable-backing reads `balanceOf`/`convertToAssets`/`maxWithdraw` + `setBacking`, PLUS no-op/recording
admin stubs `setFeeRecipient`/`submitCap`/`acceptCap`/`setSupplyQueue`/`setCurator` — neither pre-existing mock had
both surfaces). 5 tests, all green: `test_deploy_silo_seams_hold`, `test_ownership_handoff` (hook/junior/Safes/warehouse
handoffs + farm utility governor = Timelock), `test_addSilo_first_try` (a REAL `addSilo` from a pranked Timelock passes on
the first try), `test_D4_two_silo_routing_rollover_and_aggregate` (registry-level: `venueOf` routing + pranked
`incrementLineCount` to `MAX_LINES_PER_SILO=28` → `SiloFull` → `setCurrentSilo` rollover lands on silo #2 +
`SeniorNavAggregator.seniorBacking()` sums both warehouses — NO real controller/opens, the CTR-03-already-proven path
is not re-driven), `test_D2_runbook` (`setCapacity`/`addSilo`/`setCurrentSilo` via `vm.prank(timelock)`).
