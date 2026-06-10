# WOOF-10 — Item-10 deploy + wiring orchestrator (`script/DeployZipcode.s.sol`)

**Deliverable.** A single Foundry orchestrator `contracts/script/DeployZipcode.s.sol` that deploys + wires the
entire Base-side protocol in dependency order, asserts the load-bearing seams, sets CRE identity on every
`ReceiverTemplate`, gates with `ZipcodeDeployAsserts.requireIdentityWired`, and `transferOwnership(timelock)`
on every contract (NOT renounce — build-phase §17 / [[oracle-replaceable-timelock-wiring]]). Forge **build**
green is the bar this window; a full fork **execution** run (Phase S post-state) is the follow-on.

**Spec source = `wires/`** (the per-component wiring map, code-as-truth) — esp. `wires/README.md` (the 8
cross-cutting seams + deploy dependency order) + each component's "Item-10 deploy facts". Every ctor
signature, `setUp` decode order, and sub-deployer entrypoint below is verified against the kept code.

**Model from (compose these existing deployers — do NOT reimplement):**
- `script/SummonSubstrate.s.sol` — INHERIT it; call `_summon(team, saltNonce) → Substrate{baal,mainSafe,sidecar,loot,shares}` and `computeMainSafe`. The broadcaster IS `TEAM_MULTISIG` (MVP — the pre-validated `v==1` Safe signature path needs `msg.sender == owner`).
- `script/CreditWarehouseDeployer.sol` — `new`, then `.deploy(godOwner, eePool, usdc, forwarder, repaySink, saltNonce) → Warehouse{safe,roles,adapter,roleKey}`.
- `script/ReservoirMarketDeployer.sol` — `new`, then `.deploy(Params{factory,evc,governor,lpToken,usdc,lpOracle,irm,engineSafe,borrowLTV,liqLTV}) → (escrowVault,borrowVault,router)`.
- The 8x bridge (`DeploySzAlphaBridge.s.sol`) is a SEPARATE chain (964) deploy — OUT OF SCOPE. The `SzAlphaMirror` address (Base xALPHA leg) + the `SzAlphaRateOracle` are INPUTS (env); deploy `SzAlphaRateOracle` here on Base (it is a Base `ReceiverTemplate`).

## Inputs (env / stand-ins)
`TEAM_MULTISIG` (k-of-n Safe in prod; the broadcaster), `GOD_OWNER` (transient pre-multisig), `SUMMON_SALT_NONCE`,
`EREBOR` (draw off-ramp), `IRM` (interest-rate model), `XALPHA_MIRROR` (8x-01 Base mirror; M1 stand-in token ok),
`POL_ICHI_VAULT` + `POL_GAUGE` (OTC-whitelist-gated — stand-in until live), `CRE_FORWARDER` =
`BaseAddresses.CRE_KEYSTONE_FORWARDER`, `WORKFLOW_AUTHOR` + the per-receiver `WORKFLOW_ID`s. Externals come from
`BaseAddresses` (EVC, EVAULT_FACTORY, EULER_EARN_FACTORY, USDC, HYDX, OHYDX, HYDREX_VOTER/REWARDS_DISTRIBUTOR,
ALGEBRA_SWAP_ROUTER, COW_SETTLEMENT, ZODIAC_MODULE_PROXY_FACTORY, …).

## Deploy order (phases) — each step asserts its post-state
**Circular ctor deps are resolved by the Timelock-settable setters** (deploy with a placeholder/`address(0)` or
the already-deployed peer, then `setX`). This is why the build-phase wiring is settable (wires/ seam #1).

### P0 — roots
1. `timelock = new TimelockController(2 days, [deployer], [address(0)], deployer)` (admin renounced post-wire is M2; keep deployer admin for build phase).
2. `eePool = IEulerEarnFactory(EULER_EARN_FACTORY).createEulerEarn(USDC, …)` (live factory on fork; curator timelock 0 for M1 — see EE config). On a non-fork build this call is unreachable; guard `run()` so `build` does not require it (the script need only COMPILE — the call site uses the `IEulerEarn`/factory interface).

### P1 — venue spine (ctors verified)
3. `registry = new ZipcodeOracleRegistry(CRE_FORWARDER, USDC, validityWindow)`.
4. `lienFactory = new LienTokenFactory()`.
5. `hook = new CREGatingHook(EVAULT_FACTORY, EVC, address(0))` (borrowDriver placeholder → `setBorrowDriver` after the adapter).
6. `adapter = new EulerVenueAdapter(address(0), EVC, eePool, EVAULT_FACTORY, registry, hook, IRM, USDC, EREBOR, baseUsdcMarket)` (controller placeholder; ctor does NOT zero-check `controller_`). `baseUsdcMarket` = a no-borrow USDC EVault (create via `EVAULT_FACTORY.createProxy` or pass an input).
7. `controller = new ZipcodeController(CRE_FORWARDER, address(adapter), lienFactory, registry, EREBOR)` (venue_ must be non-zero ✓).
8. `adapter.setController(controller)`; `hook.setBorrowDriver(adapter)`; `registry.setController(controller)`.
9. **Assert** `controller.venue()==adapter`, `registry.controller()==controller`, `hook` immutables (it is `IHookTarget` `0x87439e04`).

### P2 — bridge rate oracle (Base side of 8x-02)
10. `rateOracle = new SzAlphaRateOracle(CRE_FORWARDER, maxStaleness, window, aprCap)`.

### P3 — supply substrate
11. `Substrate sub = _summon(TEAM_MULTISIG, SUMMON_SALT_NONCE)` (inherited). `mainSafe`=basket, `sidecar`=freeze.
12. `zipUSD = new ESynth(EVC, "Zipcode USD", "zipUSD")` (evk `ESynth`, 3-arg).
13. `depositModule = new ZipDepositModule(zipUSD, USDC, eePool, warehouseSafe)` — but `warehouseSafe` is from P4; deploy P4 first OR pass placeholder + `setGate`/no-warehouse-setter. NOTE: `ZipDepositModule` warehouse is an immutable ctor arg (4-arg) → deploy the warehouse (P4) BEFORE the deposit module. Reorder: P4 warehouse → P3 deposit module.
14. `navOracle = new SzipNavOracle(CRE_FORWARDER, zipUSD, USDC, XALPHA_MIRROR, HYDX, OHYDX, mainSafe, sidecar, W, maxAge, maxDeviationBps)`.
15. `gate = new ExitGate(sub.baal, navOracle, zipUSD, XALPHA_MIRROR, tvlCap)` (derives loot/mainSafe from IBaal).
16. `szip = new SzipUSD(gate)`; `gate.setShareToken(szip)`; `navOracle.setShareToken(szip)`.
17. `depositModule.setGate(gate)`; `ESynth(zipUSD).setCapacity(depositModule, type(uint128).max)`.
18. `queue = new ZipRedemptionQueue(zipUSD, USDC, redemptionController)` (controller = a DISTINCT CRE settle identity).
19. Grant the Gate `manager(2)`: team→`mainSafe.execTransaction`→`Baal.setShamans([gate],[2])` (helper).
20. **Assert** `IBaal(sub.baal).totalShares()==0`; `gate.shareToken()==szip`; `szip.owner()` will → timelock at seal.

### P4 — warehouse (before P3 deposit module)
21. `Warehouse w = new CreditWarehouseDeployer().deploy(GOD_OWNER, eePool, USDC, CRE_FORWARDER, address(queue), saltNonce)`. `warehouseSafe = w.safe`. **Assert** `w` non-zero, `repaySink == queue`, `w.safe != sub.mainSafe` (non-commingling).
22. EE config (S8): `eePool.setIsAllocator(w.adapter? no — VENUE)`; correct: `eePool.setIsAllocator(adapter, true)`; `eePool.setCurator(adapter)`; `eePool.setFeeRecipient(<protocol-side, e.g. w.safe>)`; `eePool.setFee(0.5e18)`. **Assert** allocator/curator.

### P5 — reservoir market + LP oracle
23. `lpOracle = new SzipReservoirLpOracle(CRE_FORWARDER, USDC, validityWindow, POL_ICHI_VAULT)`.
24. `(escrowV, borrowV, router) = new ReservoirMarketDeployer().deploy(Params{EVAULT_FACTORY, EVC, timelock, POL_ICHI_VAULT, USDC, lpOracle, IRM, mainSafe, borrowLTV, liqLTV})`.
25. **Assert** the shared-LP invariant: `POL_ICHI_VAULT == IEVault(escrowV).asset()` (wires/ seam #4); item-10 also points the EE supply queue at `borrowV` (curator op, may be a comment/TODO if EE config is fork-only).

### P6 — engine modules (clone → setUp → enableModule), `owner = timelock != operator = CRE`
For each: deploy a mastercopy, `IModuleProxyFactory(ZODIAC_MODULE_PROXY_FACTORY).deployModule(mastercopy, setUpData, salt)`, then `_enableModuleOnSafe(targetSafe, proxy)` (team→`safe.execTransaction`→`enableModule`). Use a helper. `setUp` ABI-encode orders (VERIFIED against code):
- **SzipBuyBurnModule** (engineSafe = a dedicated buy-burn Safe = `mainSafe` denominator-excluded; here use `mainSafe`): `(owner=timelock, engineSafe, operator=CRE, navOracle, szip, USDC, COW_SETTLEMENT, uint16 dBps, uint256 buybackCap)`. Then `navOracle.setEngineSafe(engineSafe)` + `gate.setEngineSafe(engineSafe)` (seam #3 — assert all three equal).
- **ReservoirLoopModule** (engineSafe=mainSafe): `(owner, engineSafe, operator, EVC, borrowV, escrowV, POL_ICHI_VAULT, USDC, uint256 borrowCap)`.
- **LpStrategyModule** (mainSafe): `(owner, engineSafe, operator, POL_ICHI_VAULT, POL_GAUGE)`. **Assert** `ichiVault()==POL_ICHI_VAULT==escrowV.asset()` (seam #4).
- **HarvestVoteModule** (mainSafe): `(owner, engineSafe, operator, POL_GAUGE, HYDREX_VOTER, HYDREX_REWARDS_DISTRIBUTOR)`.
- **ExerciseModule** (mainSafe): `(owner, engineSafe, operator, OHYDX)`.
- **SellModule** (mainSafe): `(owner, engineSafe, operator, ALGEBRA_SWAP_ROUTER, HYDX, USDC, zipUSD, XALPHA_MIRROR, uint256 maxSellHydx=300_000e18)`.
- **RecycleModule** (mainSafe): `(owner, engineSafe, operator, depositModule, USDC, navOracle, eePool, warehouseSafe)`. **Assert the one-bank invariant** (seam #5): `RecycleModule.warehouse()==depositModule.warehouse()` AND `eePool()==depositModule.eePool()` AND `navOracle()==address(navOracle)` (the same oracle DefaultCoordinator writes).
- **DurationFreezeModule** (BOTH Safes): `(owner, mainSafe, sidecar, operator, navOracle, eePool /*eulerEarn*/, warehouseSafe)`. enableModule on mainSafe AND on sidecar (sidecar requires `isOwner(team)` — already true from `_summon`).
- **OffRampModule** (rqSafe = mainSafe, the basket): `(owner, rqSafe=mainSafe, operator, zipUSD, queue)`. Then `queue.setRedeemController(mainSafe)`.

### P7 — loss side (circular escrow↔coordinator via setters)
26. `escrow = new LienXAlphaEscrow(XALPHA_MIRROR, address(0) /*coordinator placeholder*/, CAPITAL_SINK, sidecar)`.
27. `coord = new DefaultCoordinator(CRE_FORWARDER, navOracle, XALPHA_MIRROR, recoveryFloor)`.
28. `escrow.setCoordinator(coord)`; `coord.setEscrow(escrow)` (also `forceApprove(escrow,max)` inside per the ctor NatSpec); `navOracle.setDefaultCoordinator(coord)`. **Assert** `escrow.coordinator()==coord` AND `coord` wired to escrow/oracle.

### P8 — NAV oracle final wiring + rate seam
29. `navOracle.setLpPosition(POL_ICHI_VAULT, POL_GAUGE)`; `navOracle.setXAlphaRateOracle(rateOracle)`. (setShareToken/setEngineSafe/setDefaultCoordinator done earlier.) **Assert** `navOracle.shareToken()!=0` before any ownership transfer.

### P9 — seal (S10b → pre-gate → transfer)
30. On EACH `ReceiverTemplate` (`controller`, `registry`, `warehouse adapter`, `coord`, `navOracle`, `rateOracle`): `setExpectedAuthor(WORKFLOW_AUTHOR)` + `setExpectedWorkflowId(<id>)`.
31. `ZipcodeDeployAsserts.requireIdentityWired(controller, registry)` (and the analogous gate on the others — assert each `getExpectedWorkflowId()!=0`). MUST be a tested negative in the fork test (renounce/transfer with identity unset reverts).
32. `transferOwnership(timelock)` on every owned contract (registry, controller, hook, adapter, navOracle, lpOracle, rateOracle, depositModule [its owner/deployer], szip, queue, escrow, coord, every engine module, warehouse adapter + the Roles owner [already `GOD_OWNER` — re-point to timelock or leave per CreditWarehouseDeployer]). NOT renounce.

## Do NOT
- Do NOT renounce ownership anywhere (build-phase §17 — transfer to the Timelock; immutability/re-freeze is a pre-prod step).
- Do NOT compile EulerEarn source (mock/interface only; the live factory is forked).
- Do NOT hardcode addresses that `BaseAddresses` already pins; read from it.
- Do NOT mint Shares anywhere; do NOT grant the Gate `mintShares` (only `setShamans([gate],[2])` = manager).
- Do NOT deploy the 964 bridge here (separate chain/script).

## Done when
- `forge build` GREEN (the orchestrator + all imports compile under the 0.8.24 profile). This is the window bar.
- The script is structured in the P0–P9 phases above with inline asserts + the `ZipcodeDeployAsserts` pre-gate + `transferOwnership(timelock)` everywhere.
- (Follow-on, not this window) a `test/DeployZipcode.t.sol` fork run: Phase S post-state asserts hold; the identity pre-gate tested-negative reverts; an L4 origination succeeds end-to-end. + the deferred `audit/2`/`audit/3` engine/junior/loss L-row sweeps.

## Build-discovered corrections (folded back from the cold-build, 2026-06-10 — `forge build` GREEN)
The kept `script/DeployZipcode.s.sol` (625 lines, `contract DeployZipcode is SummonSubstrate`, phases
`_phaseP0..P9`, entrypoint `deploy()`) compiles green. Deltas vs the spec above, now authoritative:
1. **`ZipDepositModule` has NO Ownable surface** — its admin is the *immutable* `deployer` + a `deployer`-gated
   re-settable `setGate`; there is no `transferOwnership`. P9 drops it (re-home only by redeploy).
2. **`ZipRedemptionQueue` is deployed in P4** (the warehouse needs `repaySink == queue`) but its zipUSD ctor arg
   doesn't exist yet (P3) → deploy the queue with `zipUSD = address(0)` then `queue.setTokens(zipUSD, usdc)`
   once zipUSD lands in P3. Ctor stays 3-arg `(zipUSD, usdc, controller)`.
3. **Entrypoint is `deploy()` not `run()`** — `SummonSubstrate.run()` is non-virtual (name collision). The
   fork-test harness calls `DeployZipcode.deploy()`.
4. **EE-pool admin config is fork-only (NOT in the compiled script)** — the local `IEulerEarn` shim exposes only
   `deposit/redeem/convertToAssets/balanceOf/asset`, so `createEulerEarn`/`setIsAllocator`/`setCurator`/
   `setFeeRecipient`/`setFee` + pointing the EE supply queue at the reservoir borrow vault would not compile
   (would require the 0.8.26 EulerEarn source, forbidden). `EE_POOL` + `BASE_USDC_MARKET` are **env address
   inputs** (a pre-step creates the pool via the live factory); the allocator/curator/fee + supply-queue wiring
   are **documented TODOs the fork-test/deploy runbook performs against the live pool**. (Open obligation —
   rows 311/333: still owed, now scoped to the fork-execution step.)
5. All else matched code exactly: 13 standalone ctors, 9 module `setUp` tuples, `ReceiverTemplate`
   `setExpectedAuthor`/`setExpectedWorkflowId`/`transferOwnership` (OZ-Ownable v5), `CREGatingHook` manual-owner
   `transferOwnership`, `IModuleProxyFactory.deployModule(masterCopy, abi.encodeWithSignature("setUp(bytes)",
   data), salt)`, the Safe `v==1` pre-validated exec pattern, `TimelockController(uint256,address[],address[],address)`.

## Depends on
Every WOOF/sodo/loss/bridge component (all BUILT-VERIFIED) + `wires/` (the spec) + `BaseAddresses`/`ForkConfig`.
