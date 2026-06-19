# CTR-06c — SiloDeployer: compose the silo + register it + the hub-grant runbook

> Contract-track EXPANSION. Split from CTR-06 (index + pinned decomposition: `CTR-06-silo-deployer.md`). The
> orchestrator that composes the EE pool + per-silo hook/adapter + reservoir market + warehouse + junior tranche into
> ONE silo, returns a handle that registers via `SiloRegistry.addSilo`, and documents the post-deploy Timelock
> hub-grant runbook (D2). The feasible replacement for the original CTR-06's infeasible "29 real concurrent line" gate
> (D3/D4). Spec: `claude-zipcode.md` §4.5/§4.7/§9.1 / §17.
>
> **REWRITTEN 2026-06-19 after a 4-critic fan-out** (junior-dev / spec-fidelity / reference-verifier / contract-
> binding). The critics converged on ~9 load-bearing gaps in the first draft — all in-tree fixable (ZERO
> back-pressure). The fixes are folded in below: the full `SiloParams` struct, the verified build order that breaks
> the reservoir↔junior circular dependency via `computeMainSafe`, the per-silo `CREGatingHook` (the index mis-classed
> it as shared), `baseUsdcMarket`/`lpOracle` ownership, the perspective-probe exclusion, the combined test mock, and a
> de-scoped D4. See "Resolved findings" at the bottom.

## Why (the seam)
With `CreditWarehouseDeployer` (verbatim), `ReservoirMarketDeployer` (CTR-06a-fixed), and `JuniorTrancheDeployer`
(CTR-06b) in hand, the only missing piece is the orchestrator that runs them in dependency order, builds the per-silo
venue front (hook + adapter + EE pool + base market), wires the new silo to the shared hub, and returns a handle the
Timelock registers — making "fill pool → deploy next → route there" real.

## Prerequisite ratifications (from the index)
- **D1 (POL shared pool)** — confirmed: `polIchiVault`/`polGauge`/`rateOracle` are shared deploy INPUTS; each silo
  holds its OWN staked position + its OWN reservoir escrow vault whose `asset() == polIchiVault`.
- **D2 (post-deploy Timelock grants are a RUNBOOK, not script code)** — confirmed: the deployer returns silo handles;
  the Timelock then grants `zipUSD.setCapacity` + calls `addSilo` + `setCurrentSilo`. This ticket documents that
  runbook and tests it via `vm.prank(timelock)`.
- **D3 (mock-EE test seam)** — confirmed: the `_createEePool` step is `virtual`; the test injects a mock EE.
- **D4 (concurrency proof)** — confirmed and DE-SCOPED (see below): prove two-silo routing + cap rollover via the
  registry + pranked counts + the aggregator sum — NOT by re-driving the real controller, and NOT 28 real opens.
- **D5 (no per-silo OffRamp)** — confirmed: the silo carries no senior off-ramp (CTR-06b excludes `OffRampModule`).

## The hub vs per-silo boundary (binds to the CTR-06 index; ONE correction)
**Shared hub INPUTS (deployed once by `DeployZipcode`; passed to `deploy`, never built here):** `timelock`,
`controller` (CTR-03), `oracleRegistry` (`ZipcodeOracleRegistry`), `zipUSD` (`ESynth`), `rateOracle`
(`SzAlphaRateOracle`), `repaySink` (the ONE shared `ZipRedemptionQueue`), `erebor` (the immutable line receiver),
`forwarder` (CRE Keystone), the shared POL `polIchiVault`/`polGauge`, and `EVC`/`EVAULT_FACTORY` (`BaseAddresses`).

**Built PER SILO by `SiloDeployer`:** the EE pool + its resting `baseUsdcMarket` + the reservoir market
(escrow/borrow/router) + the per-silo **`CREGatingHook`** + the `EulerVenueAdapter` + the warehouse + the junior
tranche.

> **INDEX CORRECTION (this ticket):** the CTR-06 index lists `CREGatingHook` under "deployed ONCE at the hub, SHARED."
> That is **wrong** — `CREGatingHook.borrowDriver` is a SINGLE settable address (`CREGatingHook.sol:35,94`) and the
> gate authorizes exactly ONE adapter (`fallback` checks `isAccountOperatorAuthorized(caller, borrowDriver)`, `:110-
> 113`). N silos = N adapters = N hooks. So the hook is PER-SILO, built here, `borrowDriver`→this silo's adapter,
> mirroring `DeployZipcode.s.sol:212` (`new CREGatingHook(factory, evc, address(0))` → `setBorrowDriver(adapter)`).

## Deliverable
A new `contracts/script/SiloDeployer.s.sol` (`is Script` — it calls `computeMainSafe`, a `vm`-using view, so it runs
in a forge `script`/`test` context like the other `.s.sol` deployers). `deploy(SiloParams memory p)` runs, IN ORDER.
Build the sub-deployer param structs inside `internal` helpers so `deploy` stays under the 16-local stack limit
(`ReservoirMarketDeployer` itself uses a struct for this reason).

**0. Precompute the junior `mainSafe` (breaks the reservoir↔junior cycle).** `JuniorTrancheDeployer.deploy` is
   monolithic: it self-summons its Baal internally AND consumes the reservoir's `escrowVault`/`borrowVault` as inputs.
   The reservoir's `engineSafe` must be that junior `mainSafe` (the `ReservoirBorrowGuard` pins `OP_BORROW` to it,
   IMMUTABLE). Resolve by precomputing: instantiate `JuniorTrancheDeployer jr = new JuniorTrancheDeployer()` once, then
   `address engineSafe = jr.computeMainSafe(p.saltNonce)`. `computeMainSafe` (`SummonSubstrate.s.sol:110-118`) is a
   pure function of `saltNonce` + the live Safe factory/singleton — caller-independent — so the value precomputed here
   EQUALS the `mainSafe` `jr.deploy(...)` later summons (its `MainSafeMismatch` assert `:91` guarantees it). REUSE the
   same `jr` instance for step 7 (so the salt + summon match).

1. **EE pool** (D3 seam). `address eePool = _createEePool(p)` — a `virtual internal` step. Base (fork/runbook)
   implementation: the live-factory `.call` idiom from `DeployLocal.s.sol:115-122`
   (`createEulerEarn(p.timelock /*initialOwner*/, uint256(0) /*initialTimelock*/, p.usdc, p.eeName, p.eeSymbol,
   bytes32(p.saltNonce))`), `abi.decode(ret,(address))`. **`initialTimelock = 0`** or the first `openLine` reverts
   `EulerEarnTimelockNonZero` (the error is declared `EulerVenueAdapter.sol:80`). The D3 test OVERRIDES `_createEePool`
   to return a `new MockEulerEarn()` (see test mock below). Signature: `_createEePool(SiloParams memory) internal
   virtual returns (address)`.
2. **Resting `baseUsdcMarket`** — SiloDeployer CREATES it (it is NOT an input; mirrors `DeployLocal.s.sol:108-112`): a
   bare EVK proxy `EVAULT_FACTORY.createProxy(address(0), false, abi.encodePacked(p.usdc, address(0), address(0)))`
   then `setHookConfig(address(0), 0)`.
3. **Reservoir market** — `new ReservoirMarketDeployer().deploy(ReservoirMarketDeployer.Params{...})` (CTR-06a-fixed).
   ALL 10 fields: `factory = GenericFactory(EVAULT_FACTORY)`, `evc = EVC`, `governor = p.timelock`,
   `lpToken = p.polIchiVault`, `usdc = p.usdc`, `lpOracle = p.lpOracle`, `irm = p.reservoirIrm`,
   `engineSafe = engineSafe` (step 0), `borrowLTV = p.borrowLTV`, `liqLTV = p.liqLTV`. Returns
   `(escrowVault, borrowVault, router)`. **`p.lpOracle` is a built-and-SEEDED INPUT** (a `SzipReservoirLpOracle` with
   an initial `LP_MARK` already pushed) — `deploy` calls `setLTV` whose `getQuote` reverts without a resolvable mark,
   and the mark is a CRE/forwarder push the deployer cannot make. The caller (runbook = CRE first push; test = FORWARDER
   prank, the `JuniorTrancheDeployer.t.sol:245-249` pattern) builds + seeds it before `SiloDeployer.deploy`.
4. **EE admin config** — onboard the two non-line markets + grant the adapter curator/allocator, ALL via the low-level
   `_eeCall`/`abi.encodeWithSignature` idiom (`DeployLocal._configureEulerEarn:130-177`; the EE admin ABI is NOT
   compiled in — do NOT write typed `IEulerEarn` admin calls): `setFeeRecipient(p_warehouseSafe)` (from step 6) —
   defer if warehouse is built later, see ordering note; `submitCap(baseUsdcMarket, type(uint136).max)`+
   `acceptCap(baseUsdcMarket)`; `submitCap(borrowVault, type(uint136).max)`+`acceptCap(borrowVault)`;
   `setSupplyQueue([baseUsdcMarket])`; `setCurator(adapter)` (from step 5). **Do NOT run the `SzipPerspectiveProbe`**
   (`DeployLocal._configureEulerEarn:156-165` runs it, but it calls `IEulerEarnFactory(eePool.creator()).
   isStrategyAllowed(...)` which has no meaning against a mock EE and is a deploy-time advisory, not a silo-correctness
   invariant) — it stays a FORK-RUNBOOK assertion, not part of `deploy`.
5. **Per-silo `CREGatingHook` + `EulerVenueAdapter`.** `new CREGatingHook(EVAULT_FACTORY, EVC, address(0))`; then the
   adapter (10-arg ctor, `EulerVenueAdapter.sol:91-113`, order verified vs `DeployZipcode.s.sol:215-226`):
   `(p.controller, EVC, eePool, EVAULT_FACTORY, p.oracleRegistry, hook, p.lineIrm, p.usdc, p.erebor, baseUsdcMarket)`;
   then `hook.setBorrowDriver(address(adapter))`. Curator is granted in step 4 (`setCurator(adapter)`).
6. **Warehouse** — `new CreditWarehouseDeployer().deploy(p.godOwner, p.receiverAdmin, eePool, p.usdc, p.forwarder,
   p.repaySink /*== shared ZipRedemptionQueue*/, p.saltNonce)` (verbatim; `CreditWarehouseDeployer.sol:66-74`).
   Returns `Warehouse{safe, roles, adapter /*the WAREHOUSE admin adapter, distinct from the venue adapter*/, roleKey}`.
   `repaySink` MUST be the shared queue (D5/§6). `receiverAdmin` = the deploy broadcaster (the warehouse admin module is
   a CRE receiver sealed/re-homed by the item-10/runbook pass — NOT `godOwner`, per `CreditWarehouseDeployer.sol:61-65`).
7. **Junior tranche** — `jr.deploy(JuniorTrancheDeployer.JuniorParams{...})` (the step-0 `jr` instance; CTR-06b). ALL
   25 fields, mapped: identity `timelock=p.timelock, team=p.team, creOperator=p.creOperator, saltNonce=p.saltNonce,
   workflowAuthor=p.workflowAuthor, workflowId=p.workflowId`; hub `zipUSD=p.zipUSD, rateOracle=p.rateOracle`; upstream
   `eePool=eePool, warehouseSafe=warehouse.safe, escrowVault=escrowVault, borrowVault=borrowVault`; NAV legs
   `usdc=p.usdc, xAlphaMirror=p.xAlphaMirror, hydx=p.hydx, oHydx=p.oHydx`; POL `polIchiVault=p.polIchiVault,
   polGauge=p.polGauge, capitalSink=p.capitalSink`; knobs `W=p.W, maxAge=p.maxAge, maxDeviationBps=p.maxDeviationBps,
   tvlCap=p.tvlCap, dBps=p.dBps, buybackCap=p.buybackCap, borrowCap=p.borrowCap, recoveryFloor=p.recoveryFloor`.
8. **Post-asserts** (deployer-added, fail-closed — see step-9 note on which are `addSilo` clauses vs belt-and-suspenders):
   - §2 non-commingling (deployer-added; `addSilo` does NOT enforce these): `p.repaySink != junior.mainSafe`,
     `warehouse.safe != junior.mainSafe`, `warehouse.safe != junior.sidecar`.
   - reservoir borrow-vault governor = Timelock (CTR-06a): `IEVault(borrowVault).governorAdmin() == p.timelock`.
   - `addSilo` 6-clause pre-flight (these ARE the `SiloRegistry.sol:159-165` clauses, so the Timelock `addSilo` can't
     revert `SiloMiswired`): `freeze.{eulerEarn==eePool, warehouse==warehouse.safe, navOracle==navOracle}`,
     `escrow.coordinator==coord`, `coord.navOracle==navOracle`, `venueAdapter.eulerEarn==eePool`.
9. **Return** a `Silo` handle struct mapping 1:1 to `SiloRegistry.SiloConfig`: `adapter = venue adapter`,
   `warehouseSafe = warehouse.safe`, `eePool`, `juniorBasket = junior.mainSafe`, `escrow = junior.escrow`,
   `defaultCoordinator = junior.coord`, `navOracle = junior.navOracle`, `freeze = junior.durationFreeze`,
   `curator = venue adapter` (`addSilo` does NOT assert `curator`/`juniorBasket` — routing/label only). Also expose
   `depositModule = junior.depositModule` on the return (the D2 `setCapacity` target) and `warehouseRoles`/`hook` for
   the runbook/observability.

**Ordering note on step 4.** `setFeeRecipient`/`setCurator` need the warehouse Safe + venue adapter, which are built in
steps 5–6. So split step 4: do the two `submitCap`/`acceptCap` + `setSupplyQueue` after step 2/3 (markets exist), and
do `setFeeRecipient(warehouse.safe)` + `setCurator(adapter)` after steps 5–6. The cap-onboarding does not depend on the
curator. Keep all six EE calls as `_eeCall`.

## The `SiloParams` input struct (define exactly — a flat struct; sub-structs built in helpers)
```
struct SiloParams {
    // identity / authority (hub)
    address timelock; address team; address creOperator; address godOwner; address receiverAdmin;
    address workflowAuthor; bytes32 workflowId; uint256 saltNonce; // saltNonce DISTINCT per silo (CREATE2 across Safe
                                                                   // factory + Baal summoner + EVK proxies + EE salt)
    // shared hub handles (NOT built here)
    address controller; address oracleRegistry; address zipUSD; address rateOracle; address repaySink; // == queue
    address erebor; address forwarder;
    // shared POL (D1) + the pre-seeded reservoir LP oracle
    address polIchiVault; address polGauge; address lpOracle;
    // tokens (injectable so the D3 test feeds mocks; prod passes BaseAddresses)
    address usdc; address xAlphaMirror; address hydx; address oHydx;
    // IRMs
    address reservoirIrm; address lineIrm;
    // EE pool naming
    string eeName; string eeSymbol;
    // numeric knobs (pass-through to the sub-deployers)
    address capitalSink; uint16 borrowLTV; uint16 liqLTV;
    uint32 W; uint256 maxAge; uint256 maxDeviationBps; uint256 tvlCap; uint16 dBps; uint256 buybackCap;
    uint256 borrowCap; uint256 recoveryFloor;
}
```

## The D2 hub-grant runbook (documented in NatSpec + tested via prank; NOT deployer script code)
Before `deploy(...)` (one-time, per silo): build a `SzipReservoirLpOracle` for the silo + push its first `LP_MARK`
(CRE) → pass as `p.lpOracle`. After `deploy(...)`, the Timelock MUST (mirrors the CTR-03 obligation):
1. `zipUSD.setCapacity(silo.depositModule, type(uint128).max)` — grant the new deposit module mint authority on the
   shared zipUSD (Timelock-owned).
2. `siloRegistry.addSilo(siloId, SiloConfig{from the returned handle})` — admission (passes the topology assert).
3. `siloRegistry.setCurrentSilo(siloId)` — roll the active fill target when the prior silo hits the cap.
`controller.setRegistry(registry)` + `siloRegistry.setController(controller)` are the ONE-TIME HUB bring-up (already
wired by CTR-03 / `DeployZipcode`; NOT per-silo). Silo #0 = today's anvil deployment. (Discharges the PROGRESS
"DEPLOY OBLIGATION (CTR-03)" row as the per-silo runbook; the hub half is already done.)

## Spec §
`claude-zipcode.md` §9.1 (deploy orchestration), §4.5/§4.7, §17. The hub/silo boundary is pinned in the CTR-06 index
(with this ticket's per-silo-hook correction).

## Binds to (verified this window)
- `EulerEarnFactory.createEulerEarn(address,uint256,address,string,string,bytes32)` —
  `reference/euler-earn/src/EulerEarnFactory.sol:90-113`; idiom `DeployLocal.s.sol:115-122` (live-factory `.call`, D3 virtual).
- EE admin via low-level call: `setFeeRecipient`:258 / `submitCap`:287 / `setSupplyQueue`:325 / `acceptCap`:507 /
  `setCurator`:209 (`reference/euler-earn/src/EulerEarn.sol`); idiom `DeployLocal.s.sol:130-177`.
- `EulerVenueAdapter` 10-arg ctor `:91-113` (order verified vs `DeployZipcode.s.sol:215-226`); `EulerEarnTimelockNonZero`
  declared `:80`. `CREGatingHook` ctor + `setBorrowDriver` `CREGatingHook.sol:63,94`; `DeployZipcode.s.sol:212` precedent.
- `CreditWarehouseDeployer.deploy(godOwner,receiverAdmin,eePool,usdc,forwarder,repaySink,saltNonce)` `:66-74`.
- `ReservoirMarketDeployer.deploy(Params)` — 10-field `Params` `:40-54` (`lpToken`/`lpOracle`/`engineSafe`/`governor` real).
- `JuniorTrancheDeployer.deploy(JuniorParams)` — 25-field `JuniorParams` `:81-115`; `computeMainSafe(uint256) public`
  `SummonSubstrate.s.sol:110-118` (saltNonce-only).
- `SiloRegistry.addSilo`/`SiloConfig`/`setCurrentSilo` `:146,80-90,210`; `SeniorNavAggregator.seniorBacking()` `:74`.

## The D3/D4 test (`contracts/test/SiloDeployer.t.sol`, fork — EE mocked)
Model the fixture on `JuniorTrancheDeployer.t.sol` (a `ForkConfig` fork; live Baal summoner + EVK/EVC; mock NAV legs;
real `ReservoirMarketDeployer` over the live EVK + a `SzipReservoirLpOracle` built + mark-seeded via FORWARDER prank).

**The combined `MockEulerEarn` (NEW in this test file).** NO existing mock serves both surfaces (verified: the
`EulerVenueAdapter.t.sol` mock has the admin/queue surface but NO `convertToAssets`/`balanceOf`/`maxWithdraw`/
`setCurator`; the `JuniorTrancheDeployer.t.sol` mock has the value reads but no admin surface). Because D4 is de-scoped
to NO real opens, the combined mock is SMALL — write it as: the `JuniorTrancheDeployer.t.sol` settable-backing mock
(`balanceOf(address)→sharesOf`, `convertToAssets(uint256)→assetsPerShareBacking`, `maxWithdraw(address)→free`,
`setBacking(shares,backing,free)`) PLUS no-op/recording admin stubs by ABI signature: `setFeeRecipient(address)`,
`submitCap(address,uint256)`, `acceptCap(address)`, `setSupplyQueue(address[])`, `setCurator(address)`. (deploy() never
reads `config()`/`reallocate()` here — there are no opens — so the rich queue mock is unnecessary.)

Tests:
1. **`test_deploy_silo_seams_hold`** — `SiloDeployer.deploy(_params())` against a `_createEePool` override returning a
   `new MockEulerEarn()`; assert all step-8 post-asserts hold (a closed seam reverts), and the venue adapter's
   `eulerEarn() == address(mockEE)`, hook `borrowDriver() == adapter`.
2. **`test_ownership_handoff`** — every junior OZ-ownable + engine module owner = Timelock (delegated to CTR-06b's
   coverage — re-assert the headline ones), the per-silo hook owner = Timelock (`SiloDeployer` transfers it), the
   reservoir borrow-vault `governorAdmin() == timelock`, warehouse Safe/Roles → `godOwner`, warehouse admin adapter →
   `receiverAdmin`, both Baal Safes → `team` & NOT the deployer.
3. **`test_addSilo_first_try`** — a real `SiloRegistry` (re-homed to a pranked Timelock); `addSilo(siloId, handle)`
   passes on the FIRST try (proves the handle is self-consistent; reverts `SiloMiswired` if any clause fails).
4. **`test_D4_two_silo_routing_rollover_and_aggregate`** (the de-scoped D4 — registry-level, NO real controller):
   register silo #0 (a SiloDeployer-built or a self-consistent topology stub) + silo #2 (SiloDeployer-built) in one
   real `SiloRegistry` (Timelock-owned). Assert `venueOf(silo0)`/`venueOf(silo2)` return each silo's OWN adapter. Drive
   silo #0 to `MAX_LINES_PER_SILO` (= **28**) by `vm.prank(controller)` `incrementLineCount` (the
   `ZipcodeController.t.sol:938-955` precedent); the next increment reverts `SiloFull`; `setCurrentSilo(silo2)`; an
   increment now lands on silo #2 (`lineCount == 1`). Then set each silo's mock-EE backing via `setBacking(...)` and
   assert `SeniorNavAggregator.seniorBacking()` == the Σ of both warehouses' donation-immune values (wire the
   aggregator's `registry` to this registry).
5. **`test_D2_runbook`** — exercise `zipUSD.setCapacity(silo.depositModule,…)` + `addSilo` + `setCurrentSilo` via
   `vm.prank(timelock)` against a mock/real zipUSD (a settable-capacity stub for the `setCapacity` leg is fine).

## Starting state
- CTR-06a + CTR-06b DONE. The hub exists from `DeployZipcode`/`DeployLocal` (silo #0 = today's anvil deployment).

## Do NOT
- Do NOT point `repaySink` at a per-silo queue — every silo funds the ONE shared `ZipRedemptionQueue` (D5/§6).
- Do NOT share an `EulerVenueAdapter` OR a `CREGatingHook` across pools (single `eePool`/`baseUsdcMarket`,
  `EulerVenueAdapter.sol:39,53`; single `borrowDriver`, `CREGatingHook.sol:35`).
- Do NOT create the EE pool with non-zero `initialTimelock` (bricks `openLine`).
- Do NOT run the `SzipPerspectiveProbe` inside `deploy` (mock-incompatible; fork-runbook advisory only).
- Do NOT inline the D2 Timelock grants (`zipUSD.setCapacity`, `addSilo`, `setCurrentSilo`) — Timelock-owned post-deploy.
- Do NOT attempt real originations / 28 real opens in the test (D4 — prank the count).
- Do NOT leave any owner as the deployer (Safe/Roles → godOwner; warehouse adapter → receiverAdmin; hook + all
  modules/oracles → Timelock; both Baal Safes → team).
- Do NOT use the `EulerVenueAdapter.t.sol` rich mock for the gate (it lacks the aggregator reads + `setCurator`).

## Key requirements
1. **One `deploy(...)` → one self-consistent silo** whose returned handle passes `SiloRegistry.addSilo` on the first
   try (proven by a real `addSilo` from a pranked Timelock).
2. **The reservoir↔junior cycle is broken via `computeMainSafe`** (step 0) — the precomputed `engineSafe` equals the
   junior's eventual `mainSafe` (CTR-06b's `MainSafeMismatch` assert guarantees it).
3. **Per-silo hook**: `new CREGatingHook` with `borrowDriver` → this silo's adapter, owner → Timelock.
4. **Shared senior plumbing**: `repaySink` = the shared queue; the silo mints the shared zipUSD via the D2 grant; the
   D2 runbook documented + prank-tested.
5. **Mock-EE test seam** (D3): `_createEePool` virtual; the gate runs against the combined `MockEulerEarn`.
6. **Two-silo routing + rollover + aggregate proof** (D4, de-scoped): registry-level routing/rollover (pranked counts,
   cap = 28) + `SeniorNavAggregator.seniorBacking()` sums both warehouses. NO real controller, NO real opens.
7. **All step-8 post-asserts** (non-commingling, reservoir governor = Timelock, addSilo 6-clause pre-flight) fail closed.

## Done when (gate — `forge test`, fork; EE mocked per D3)
- `forge build` green; `contracts/test/SiloDeployer.t.sol`: the five tests above pass; `forge test --match-path
  test/SiloDeployer.t.sol` green; no pre-existing suite regresses.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-06a, CTR-06b (and so D1/D2/D3/D4/D5 ratified).
- **Unblocks:** horizontal scaling (N pools); the federation migration path (silo #0 = today's deployment). Folds in
  the CTR-03 deploy-wiring obligation (PROGRESS) as the D2 runbook.

## Resolved findings (the 4-critic fan-out, 2026-06-19 — all in-tree, ZERO back-pressure)
1. **Combined mock EE** — neither existing mock has both the EE-admin surface AND the donation-immune NAV reads. FIXED:
   the test defines a small combined mock (settable-backing + admin no-op stubs); de-scoping D4 (no opens) means the
   rich queue/reallocate mock is not needed.
2. **`SiloParams` undefined** — FIXED: the full struct is specified above.
3. **Reservoir↔junior circular dependency** — FIXED: `computeMainSafe(saltNonce)` (saltNonce-only, verified) precomputes
   the junior `mainSafe` as the reservoir `engineSafe`; the first draft's "two-phase junior build" was infeasible
   against CTR-06b's monolithic `deploy` and is replaced.
4. **`lpOracle` + `LP_MARK` seed** — FIXED: `p.lpOracle` is a built-and-seeded INPUT (the mark is a CRE/forwarder push
   the deployer cannot make; `setLTV`'s `getQuote` needs it). Runbook + test build/seed it first.
5. **`baseUsdcMarket`** — FIXED: SiloDeployer creates the bare EVK proxy (step 2).
6. **`SzipPerspectiveProbe`** — FIXED: excluded from `deploy` (fork-runbook advisory only; mock-incompatible).
7. **`_createEePool` arity** — FIXED: `(SiloParams memory) internal virtual returns (address)` pinned.
8. **Per-silo `CREGatingHook`** — FIXED: the index's "shared hub infra" classification corrected; built per-silo.
9. **D4 de-scope + off-by-one** — FIXED: D4 is registry-level (no real controller/opens); cap is **28**
   (`SiloRegistry.sol:61`), not the stale "29".
- Also (spec-fidelity, minor): step-8 wording now distinguishes the deployer-added non-commingling `!=` checks from the
  `addSilo` 6-clause assert (the index notes `addSilo` does NOT enforce non-commingling); the CTR-03 obligation's hub
  half is disclaimed as already-done.
