# CTR-06b — JuniorTrancheDeployer: one callable that stands up a self-consistent junior tranche

> Contract-track EXPANSION (the missing reusable artifact). Split from CTR-06 (index + pinned decomposition:
> `CTR-06-silo-deployer.md`). The per-junior analogue of `CreditWarehouseDeployer` — it stands up ONE junior tranche
> (Baal substrate + NAV oracle + ExitGate/SzipUSD + deposit module + the 8 yield/freeze/buy-burn engine modules +
> loss side) and hands every owner to the Timelock. CTR-06c calls it once per silo.
> Spec: `claude-zipcode.md` §6/§7/§8 (junior tranche + engine) / §11 (loss) / §17.

## Why (the seam)
`DeployZipcode` stamps exactly ONE junior tranche inline across phases P3/P6/P7 (~30 deployments + ~15 seam asserts,
strict ordering). There is NO reusable junior deployer (unlike the warehouse). To add silo #2..N, CTR-06c needs a
single callable that reproduces that junior substrate parameterized — pointing at THIS silo's `eePool`/`warehouseSafe`
and the **shared** hub `zipUSD`. This ticket extracts that orchestration faithfully into one contract.

## Prerequisite ratifications (from the index — confirm before cold-build)
- **D1 (POL sharing) RATIFIED as:** the zipUSD/xALPHA `polIchiVault` + `polGauge` are **inputs** to this deployer
  (shared pool address across silos by default; each silo's `mainSafe` stakes its own LP position). NB the real pool
  is not live — M1 stand-in (PROGRESS "BLOCKED (external)").
- **D5 (senior off-ramp) RATIFIED as:** this deployer **EXCLUDES `OffRampModule`** and the
  `ZipRedemptionQueue.setRedeemController` wiring. It builds the junior yield/freeze/buy-burn + loss stack only (8
  engine modules, not 9). The senior off-ramp is hub-level (CRE-02 + the D5 federation decision).

## Deliverable
A new `contracts/script/JuniorTrancheDeployer.sol` (modeled VERBATIM on `DeployZipcode` P3/P5(reservoir-consume)/P6/P7
ordering). A single `deploy(JuniorParams)` that, given the hub + per-silo handles, produces a self-consistent junior
tranche and returns its handles. **Build order is load-bearing** (matches `DeployZipcode`):

1. **Baal two-Safe substrate** — `SummonSubstrate._summon(team, saltNonce)` → `{baal, mainSafe, sidecar}`. The
   broadcaster MUST be `team` (the Safe pre-validated `v==1` path). `mainSafe != sidecar` required (the freeze setUp
   reverts `BadParams` otherwise — `DurationFreezeModule.sol:114-115`). (`DeployZipcode._phaseP3:287` = `_summon`.)
2. **`SzipNavOracle`** ctor (11 args, `SzipNavOracle.sol` ctor / `DeployZipcode.s.sol:300-312`):
   `(CRE_KEYSTONE_FORWARDER, zipUSD, USDC, xAlphaMirror, HYDX, OHYDX, mainSafe, sidecar, W, maxAge, maxDeviationBps)`.
3. **`ExitGate` + `SzipUSD`** (`:315-318`): `gate = new ExitGate(baal, navOracle, zipUSD, xAlphaMirror, tvlCap)`;
   `szip = new SzipUSD(gate)`; `gate.setShareToken(szip)`; `navOracle.setShareToken(szip)`;
   `gate.setWindowController(creOperator)` (`:323`, M1 = the CRE operator hot key).
4. **`ZipDepositModule`** (`:296-297`): `new ZipDepositModule(zipUSD, USDC, eePool, warehouseSafe)`;
   `depositModule.setGate(gate)` (`:326`). **NOTE (D2):** `zipUSD.setCapacity(depositModule, max)` is a Timelock
   step (zipUSD owned by the Timelock) — NOT done here; CTR-06c's runbook covers it. Do NOT attempt it inline.
5. **Shaman grant** (`:333`): `_setShamansManager(baal, mainSafe, gate)` — grant the Gate `manager(2)` via
   `team -> mainSafe.execTransaction -> Baal.setShamans([gate],[2])`. Asserts (`:336-337`): `totalShares()==0`,
   `gate.shareToken()==szip`.
6. **`DurationFreezeModule` FIRST** (it is the `coverageGate` the buy-burn + LP-strategy wire to — must precede them):
   `_cloneModule(new DurationFreezeModule(), abi.encode(timelock, mainSafe, sidecar, creOperator, navOracle, eePool,
   warehouseSafe), mainSafe)` — a **7-tuple** whose FIRST arg is `owner_ = timelock` (`DurationFreezeModule.sol:98-107`
   decode order `(owner_, mainSafe_, sidecar_, operator_, navOracle_, eulerEarn_, warehouse_)`; encode precedent
   `DeployZipcode.s.sol:394-396`). Then `_enableModuleOnSafe(sidecar, durationFreeze)` (`:399` — enabled on BOTH Safes).
7. **`SzipBuyBurnModule`** (`:402-409`): `abi.encode(timelock, engineSafe=mainSafe, creOperator, navOracle, szip, USDC,
   COW_SETTLEMENT, dBps, buybackCap, durationFreeze)`. Then `navOracle.setEngineSafe(mainSafe)`;
   `gate.setEngineSafe(mainSafe)`; seam asserts (`:411-418`): `buyBurn.coverageGate()==durationFreeze`,
   `buyBurn.engineSafe()==gate.engineSafe()==navOracle.engineSafe()`.
8. **`ReservoirLoopModule`** (`:421-425`): `abi.encode(timelock, mainSafe, creOperator, EVC, borrowVault, escrowVault,
   polIchiVault, USDC, borrowCap)`. (`borrowVault`/`escrowVault` are INPUTS — the reservoir market is built by CTR-06c
   via the CTR-06a-fixed `ReservoirMarketDeployer`, then passed in.)
9. **`LpStrategyModule`** (`:428-432`): `abi.encode(timelock, mainSafe, creOperator, polIchiVault, polGauge,
   durationFreeze)`. Seams (`:434-439`): `lpStrategy.ichiVault()==polIchiVault==escrowVault.asset()`;
   `lpStrategy.coverageGate()==durationFreeze`.
10. **`HarvestVoteModule`** (`:442-446`): `abi.encode(timelock, mainSafe, creOperator, polGauge, HYDREX_VOTER,
    HYDREX_REWARDS_DISTRIBUTOR)`.
11. **`ExerciseModule`** (`:449-453`): `abi.encode(timelock, mainSafe, creOperator, OHYDX)`.
12. **`SellModule`** (`:456-460`): `abi.encode(timelock, mainSafe, creOperator, ALGEBRA_SWAP_ROUTER, HYDX, USDC,
    zipUSD, xAlphaMirror, uint256(300_000e18))`.
13. **`RecycleModule`** (`:463-467`): `abi.encode(timelock, mainSafe, creOperator, depositModule, USDC, navOracle,
    eePool, warehouseSafe)`. One-bank seam (`:469-473`): `recycle.warehouse()==depositModule.warehouse()`,
    `recycle.eePool()==depositModule.eePool()`, `recycle.navOracle()==navOracle`.
14. **Loss side** (P7 order — coordinator FIRST to break the cycle): `coord = new DefaultCoordinator(
    CRE_KEYSTONE_FORWARDER, navOracle, xAlphaMirror, recoveryFloor)` (`:494-496`); `escrow = new LienXAlphaEscrow(
    xAlphaMirror, coord, capitalSink, sidecar)` (`:499`); `coord.setEscrow(escrow)`;
    `navOracle.setDefaultCoordinator(coord)` (`:502-503`); assert `escrow.coordinator()==coord` (`:505`).
15. **NAV final wiring** (P8, `:511-519`): `navOracle.setLpPosition(polIchiVault, polGauge)`;
    `navOracle.setReservoirLeg(escrowVault, borrowVault)`; `navOracle.setXAlphaRateOracle(rateOracle)` (the shared hub
    rate oracle — an input); assert `navOracle.shareToken() != address(0)`.
16. **Identity seal + ownership handoff** for the receivers this tranche owns (NAV oracle, coordinator) — mirror
    `DeployZipcode._phaseP9`: `setExpectedAuthor`/`setExpectedWorkflowId` then `transferOwnership(timelock)` on
    `navOracle`, `gate`, `szip`, `escrow`, `coord`. The engine modules are ALREADY Timelock-owned from `setUp`
    (`owner_ == timelock`) — do NOT re-transfer (reverts). `ZipDepositModule` has no ownable surface (`:560-562`).

Return a `JuniorTranche` struct: `{baal, mainSafe, sidecar, navOracle, gate, szip, depositModule, durationFreeze,
buyBurn, reservoirLoop, lpStrategy, harvestVote, exercise, sell, recycle, escrow, coord}` for CTR-06c's `addSilo`.

## Spec §
`claude-zipcode.md` §6/§7 (junior share + NAV), §8 (engine modules), §11 (loss side), §17 (Timelock owns all,
re-pointable). The decomposition is pinned in the CTR-06 index.

## Binds to (verified)
- `SummonSubstrate._summon(address,uint256)` → `Substrate{baal, mainSafe, sidecar}` (inherited; the broadcaster must
  be the team Safe owner). `_setShamansManager`/`_enableModuleOnSafe`/`_cloneModule`/`_execAsTeam` — the
  `DeployZipcode`/`SummonSubstrate` helper idioms (reuse, do not reinvent).
- Every ctor/setUp tuple above is line-cited to `DeployZipcode.s.sol` (P3 `:286-338`, P6 `:381-487`, P7 `:490-506`,
  P8 `:509-520`, P9 `:522-574`). `DurationFreezeModule.setUp` 7-tuple: `DurationFreezeModule.sol:98-139`.
- `SiloRegistry` topology assert the result MUST satisfy: `freeze.{eulerEarn,warehouse,navOracle}`,
  `escrow.coordinator`, `defaultCoordinator.navOracle`, `adapter.eulerEarn` (`SiloRegistry.sol:159-165`).
- The reservoir market handles (`escrowVault`, `borrowVault`, `router`) come from `ReservoirMarketDeployer.deploy`
  (CTR-06a-fixed) — INPUTS to this deployer, built by CTR-06c.

## Starting state
- CTR-06a (reservoir governor fix) DONE. The hub (`zipUSD`, `ZipRedemptionQueue`, `SzAlphaRateOracle`, Timelock,
  `SiloRegistry`, controller) exists from `DeployZipcode`. The reservoir market for this silo is built by CTR-06c and
  passed in.

## Do NOT
- Do NOT deploy or re-point any HUB contract (`zipUSD`, `ZipRedemptionQueue`, controller, registry, rate oracle) —
  they are shared inputs, Timelock-owned. Do NOT call `zipUSD.setCapacity` (Timelock step, D2).
- Do NOT build `OffRampModule` or call `queue.setRedeemController` (D5 — senior off-ramp is hub-level).
- Do NOT re-`transferOwnership` the engine modules (already Timelock-owned from `setUp`).
- Do NOT reorder: `DurationFreezeModule` MUST precede buy-burn + LP-strategy (they wire to it as `coverageGate`);
  coordinator MUST precede escrow (the ctor cycle); the NAV oracle MUST precede the freeze setUp (it reads
  `zipUSD/usdc/xAlpha/hydx/oHydx` live off the oracle).
- Do NOT reuse silo #0's `saltNonce` — CREATE2 collision on the Safe/Roles/module proxies. Take `saltNonce` as a
  distinct input per silo.

## Key requirements
1. **One callable, self-consistent.** `deploy(JuniorParams)` returns a junior tranche whose freeze/escrow/coordinator/
   navOracle satisfy `SiloRegistry.addSilo`'s 6-clause topology assert on the first try (CTR-06c proves it).
2. **Shared hub, per-silo junior.** `zipUSD`/`rateOracle`/`timelock` are inputs (shared); `szipUSD`/NAV/engine/loss are
   freshly deployed (per-silo). Loss is local to this junior's `szip`.
3. **All 15 seam asserts from `DeployZipcode` reproduced** (coverage-gate ×2, engine-safe, shared-LP, one-bank,
   escrow-coordinator, NAV share-token, shaman/totalShares) — the deployer fails closed on any mis-wire.
4. **Ownership handoff asserted** (NAV/gate/szip/escrow/coord → Timelock; modules already Timelock-owned).
5. **§2 topology / non-commingling** (NOT §11 — index correction): assert the junior `mainSafe`/`sidecar` are distinct
   from the silo's `warehouseSafe` (the per-silo analogue of `DeployZipcode`'s `SeamWarehouseCommingled`, `:291`).

## Done when (gate — `forge test`, fork; EE mocked per D3)
- `forge build` green; a new `contracts/test/JuniorTrancheDeployer.t.sol` fork test: run `deploy(...)` against a
  mocked EE (D3 — inject the `eePool`/`warehouseSafe`/reservoir handles) and assert (a) every seam assert passes, (b)
  every owner is the Timelock (or module-owned-from-setUp), (c) the returned handles satisfy the `addSilo` 6-clause
  topology assert when fed to a real `SiloRegistry`. Reuse `DurationFreezeModule.t.sol`/`ReservoirLoopModule.t.sol`
  fork fixtures for the live EVK/Algebra legs.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-06a (reservoir governor fix); D1 + D5 ratified (index).
- **Unblocks:** CTR-06c (the SiloDeployer orchestrator calls this once per silo).
