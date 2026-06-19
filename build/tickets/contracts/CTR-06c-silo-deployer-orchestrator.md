# CTR-06c — SiloDeployer: compose the silo + register it + the hub-grant runbook

> Contract-track EXPANSION. Split from CTR-06 (index + pinned decomposition: `CTR-06-silo-deployer.md`). The
> orchestrator that composes the EE pool + reservoir market + warehouse + junior tranche into ONE silo, registers it
> via `SiloRegistry.addSilo`, and documents the post-deploy Timelock hub-grant runbook (D2). The feasible replacement
> for the original CTR-06's infeasible "29 real concurrent line" gate (D3/D4).
> Spec: `claude-zipcode.md` §4.5/§4.7/§9.1 / §17.

## Why (the seam)
With `CreditWarehouseDeployer` (verbatim), `ReservoirMarketDeployer` (CTR-06a-fixed), and `JuniorTrancheDeployer`
(CTR-06b) in hand, the only missing piece is the orchestrator that runs them in dependency order, wires the new silo
to the shared hub, and registers it — making "fill pool → deploy next → route there" real.

## Prerequisite ratifications (from the index)
- **D2 (post-deploy Timelock grants are a RUNBOOK, not script code)** — confirmed: the deployer returns silo handles;
  the Timelock then grants `zipUSD.setCapacity` + calls `addSilo` + `setCurrentSilo`. This ticket documents that
  runbook and tests it via `vm.prank(timelock)`.
- **D3 (mock-EE test seam)** — confirmed: the `createEulerEarn` step is `virtual`; the test injects a mock EE.
- **D4 (concurrency proof)** — confirmed: prove two-silo routing + cap rollover via pranked counts + a few real opens,
  NOT 28 real opens.
- **D5 (no per-silo OffRamp)** — confirmed: the silo carries no senior off-ramp.

## Deliverable
A new `contracts/script/SiloDeployer.sol`. `deploy(SiloParams)` runs, in order:
1. **EE pool** (D3 — a `virtual _createEePool(...)` step so the test injects a mock): on a fork, the live-factory
   `.call` idiom from `DeployLocal.s.sol:115-122` (`createEulerEarn(timelockOwner, initialTimelock=0, USDC, name,
   symbol, salt)`); the override returns the pool address. **`initialTimelock = 0`** or the first `openLine` reverts
   `EulerEarnTimelockNonZero` (`EulerVenueAdapter.sol:209`).
2. **Two non-line markets + EE admin config** — the resting USDC market + (after the reservoir market in step 4) the
   reservoir borrow vault, each `submitCap`→`acceptCap`; `setSupplyQueue([restingMarket])`; `setCurator(adapter)`.
   ALL via the low-level `_eeCall`/`abi.encodeWithSignature` idiom (`DeployLocal._configureEulerEarn:130-166`,
   `_eeCall:170-177`) — the EE admin ABI is NOT compiled in; do NOT write typed `IEulerEarn` admin calls.
3. **`EulerVenueAdapter`** bound to this `eePool` (10-arg ctor, `EulerVenueAdapter.sol:91-113` /
   `DeployZipcode.s.sol:215-226`): `(controller, EVC, eePool, EVAULT_FACTORY, oracleRegistry, hook, irm, USDC, erebor,
   baseUsdcMarket)`. `controller`/`oracleRegistry`/`hook` are the SHARED hub handles (inputs). Then `setCurator(adapter)`
   on the pool (curator implies allocator) so `openLine`/`fund` work.
4. **Reservoir market** — `new ReservoirMarketDeployer().deploy(Params{...})` (CTR-06a-fixed; governor = Timelock,
   engineSafe = the junior `mainSafe` from step 5). NB ordering: the junior `mainSafe` (the engineSafe) is needed
   here, so summon/junior step 5 partly precedes — or pass a two-phase build (summon Baal first, then reservoir, then
   the rest of the junior). Mirror `DeployZipcode` (P5 reservoir uses `d.sub.mainSafe` from P3).
5. **Warehouse** — `new CreditWarehouseDeployer().deploy(godOwner, receiverAdmin, eePool, USDC, forwarder,
   repaySink=SHARED ZipRedemptionQueue, saltNonce)` (verbatim; `CreditWarehouseDeployer.sol:66-74`).
6. **Junior tranche** — `new JuniorTrancheDeployer().deploy(JuniorParams{...})` (CTR-06b) with the reservoir handles +
   shared `zipUSD`/`rateOracle`/Timelock + this silo's `eePool`/`warehouseSafe`.
7. **Post-asserts**: §2 topology / non-commingling (NOT §11): `repaySink != juniorMainSafe`,
   `warehouseSafe != juniorMainSafe`, `warehouseSafe != juniorSidecar`; the reservoir borrow vault
   `governorAdmin() == timelock` (CTR-06a); the adapter/freeze/escrow/coord satisfy the `addSilo` 6-clause assert
   pre-flight (so the Timelock `addSilo` can't revert `SiloMiswired`).
8. **Return** a `Silo` handle struct mapping 1:1 to `SiloRegistry.SiloConfig`: `adapter`, `warehouseSafe`, `eePool`,
   `juniorBasket = junior.mainSafe`, `escrow`, `defaultCoordinator = junior.coord`, `navOracle = junior.navOracle`,
   `freeze = junior.durationFreeze`, `curator = adapter`.

## The D2 hub-grant runbook (documented in NatSpec + tested via prank; NOT deployer script code)
After `deploy(...)`, the Timelock MUST (mirrors the CTR-03 `setRegistry`/`setController` obligation):
1. `zipUSD.setCapacity(silo.depositModule, type(uint128).max)` — grant the new deposit module mint authority on the
   shared zipUSD (zipUSD owned by the Timelock).
2. `siloRegistry.addSilo(siloId, SiloConfig{from the returned handle})` — admission (passes the topology assert).
3. `siloRegistry.setCurrentSilo(siloId)` — roll the active fill target to the new silo when the prior one hits the cap.
(`siloRegistry.setController(controller)` is already wired hub-side from CTR-03; no per-silo change.)

## Spec §
`claude-zipcode.md` §9.1 (deploy orchestration), §4.5/§4.7, §17. The hub/silo boundary is pinned in the CTR-06 index.

## Binds to (verified)
- `EulerEarnFactory.createEulerEarn(address,uint256,address,string,string,bytes32)` —
  `reference/euler-earn/src/EulerEarnFactory.sol:90-113` (live-factory `.call`, D3 virtual).
- EE admin via low-level call: `submitCap`:287 / `acceptCap`:507 / `setSupplyQueue`:325 / `setCurator`:209
  (`reference/euler-earn/src/EulerEarn.sol`); idiom `DeployLocal.s.sol:130-177`.
- `EulerVenueAdapter` ctor `:91-113`; `CreditWarehouseDeployer.deploy` `:66-74`; `ReservoirMarketDeployer.deploy`
  (CTR-06a-fixed); `JuniorTrancheDeployer.deploy` (CTR-06b); `SiloRegistry.addSilo`/`SiloConfig`/`setCurrentSilo`
  (`SiloRegistry.sol:146,80-90,210`); `SeniorNavAggregator.seniorBacking()` (`SeniorNavAggregator.sol:74`).
- Mock EE for the gate: the in-file `MockEulerEarn` in `EulerVenueAdapter.t.sol:39-315` (models caps + the 30-slot
  withdraw queue + `reallocate`); the registry-cap pranking precedent `ZipcodeController.t.sol:938-955`.

## Starting state
- CTR-06a + CTR-06b DONE. The hub exists from `DeployZipcode`/`DeployLocal` (silo #0 = today's anvil deployment).

## Do NOT
- Do NOT point `repaySink` at a per-silo queue — every silo funds the ONE shared `ZipRedemptionQueue` (D5/§6).
- Do NOT share an `EulerVenueAdapter` across pools (single `eePool`/`baseUsdcMarket`, `EulerVenueAdapter.sol:39,53`).
- Do NOT create the EE pool with non-zero `initialTimelock` (bricks `openLine`).
- Do NOT inline the D2 Timelock grants (`zipUSD.setCapacity`, `addSilo`, `setCurrentSilo`) into the deployer — they
  are Timelock-owned post-deploy steps; the deployer can't call them.
- Do NOT attempt 28 real originations per silo in the test (D4 — prank the count).
- Do NOT leave any owner as the deployer (Safe/Roles → godOwner; all modules/oracles → Timelock).

## Key requirements
1. **One `deploy(...)` → one self-consistent silo** whose returned handle passes `SiloRegistry.addSilo` on the first
   try (proven in the test by a real `addSilo` from a pranked Timelock).
2. **Shared senior plumbing** (`repaySink` = shared queue; the silo mints the shared zipUSD via the D2 grant) + the
   D2 runbook documented and prank-tested.
3. **Mock-EE test seam** (D3): `_createEePool` virtual; the gate runs against `MockEulerEarn`.
4. **Two-silo routing + rollover proof** (D4): register silo #0 (mock) + silo #2; route originations by `siloId`
   through the controller (CTR-03); fill silo #0's count to `MAX_LINES_PER_SILO` (pranked), assert `SiloFull`,
   `setCurrentSilo(siloId#2)`, land the 29th origination in silo #2; assert `SeniorNavAggregator.seniorBacking()`
   reflects both warehouses.
5. **All step-7 post-asserts** (non-commingling, reservoir governor = Timelock, addSilo pre-flight) fail closed.

## Done when (gate — `forge test`, fork; EE mocked per D3)
- `forge build` green; a new `contracts/test/SiloDeployer.t.sol`: deploy silo #2 against a mock EE; a pranked-Timelock
  `addSilo` passes; the D4 two-silo routing + cap-rollover scenario is green; `SeniorNavAggregator.seniorBacking()`
  sums both warehouses; the D2 runbook (setCapacity/addSilo/setCurrentSilo) is exercised via `vm.prank(timelock)`.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-06a, CTR-06b (and so D1/D2/D3/D4/D5 ratified).
- **Unblocks:** horizontal scaling (N pools); the federation migration path (silo #0 = today's deployment). Folds in
  the CTR-03 deploy-wiring obligation (PROGRESS) as the D2 runbook.
