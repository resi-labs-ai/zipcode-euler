# CTR-06 — SiloDeployer (SPLIT INDEX): stamp + wire + register a full venue silo

> Contract-track EXPANSION. **RE-SCOPED 2026-06-18.** The original single-ticket CTR-06 ("one `SiloDeployer.sol`
> that stands up a complete silo + a fork test that opens the 29th concurrent line") **cannot cold-build to zero
> load-bearing guesses** — a 4-critic fan-out (junior-dev / spec-fidelity / reference-verifier / contract-binding)
> converged on three blocking gaps. This file is now the **split index**: it pins the hub/silo decomposition every
> child ticket shares, records the open decisions to ratify, and points at the three buildable children.
> Spec: `claude-zipcode.md` §4.5/§4.7/§9.1 / §17.

## Why the original ticket was re-scoped (the convergent findings)

1. **The junior stack is ~30 deployments collapsed into 5 nouns.** The old step 5 ("a junior Baal/szipUSD basket, a
   `LienXAlphaEscrow`, a `DefaultCoordinator`, a `DurationFreezeModule` clone, and a `SzipNavOracle`") omits the **8
   other engine modules** (`SzipBuyBurnModule`, `ReservoirLoopModule`, `LpStrategyModule`, `HarvestVoteModule`,
   `ExerciseModule`, `SellModule`, `RecycleModule`, `OffRampModule`), the **reservoir market** (escrow/borrow/router/LP
   oracle), the **deposit module**, the full **ExitGate/SzipUSD/NavOracle wiring sequence**, and the **Baal `_summon`
   + shaman grant** — all of which `DeployZipcode` P3/P5/P6/P7 require for a topology-valid junior. Unlike the
   warehouse (`CreditWarehouseDeployer`, reusable verbatim), **there is no one-call junior deployer to reuse — it must
   be written first** (→ CTR-06b). And `DurationFreezeModule.setUp` reads `zipUSD/usdc/xAlpha/hydx/oHydx` *live* off a
   real `SzipNavOracle`, so the freeze can't be `setUp` against a placeholder oracle.
2. **The per-silo vs hub-shared boundary was undefined and the script couldn't reach the hub.** The shared
   `ZipRedemptionQueue` / shared `zipUSD` were not `deploy()` inputs, and `zipUSD.setCapacity` (granting a new deposit
   module mint authority) is Timelock-owned post-deploy — so the deployer cannot wire the new silo to the shared hub
   inline. Pinned below + carried as a post-deploy Timelock runbook step (D2).
3. **The "29th concurrent line" fork gate was self-contradictory + infeasible.** Step 1 called the **live**
   `EulerEarnFactory.createEulerEarn` (real EE, solc 0.8.26, low-level `.call`) while the gate said "EE mocked." EE
   **cannot** be compiled into this 0.8.24 repo, and **no test has ever stood up a real EE pool on a fork**
   (`DeployZipcode.t.sol` is entirely `vm.skip(true)`, never executed). 28+ real originations × 2 pools, with the
   rollover mechanic + arithmetic unstated. Re-scoped to a feasible gate in CTR-06c (D3/D4).

Plus minor errors fixed in the children: the "non-commingling assert" was mis-cited to §11 (it is the PROGRESS
deploy-obligation / the §2 "point only at its OWN components" topology rule — `addSilo` does NOT enforce it); the
freeze `setUp` 7-tuple dropped its leading `owner_` (the Timelock); `juniorBasket`/`curator` `addSilo` values were
unspecified; no salt-nonce scheme for silo #2.

---

## The hub/silo decomposition (PINNED 2026-06-18 — every child ticket binds to this)

**Deployed ONCE at the hub (by `DeployZipcode`), SHARED by all silos — NEVER re-deployed per silo:**
- `TimelockController` — owns everything (every silo-internal owner is handed to it).
- `zipUSD` (`ESynth`) — the senior $1 unit dollar. **ALL silos mint the SAME token** (a per-silo deposit module is
  granted `setCapacity` by the Timelock — D2).
- `ZipcodeController` + `ZipcodeOracleRegistry` — the controller routes `openLine` by `siloId` (CTR-03); the registry
  hosts every lien's oracle mark. One controller, one oracle registry, all silos.
- `LienTokenFactory`, `CREGatingHook` — shared venue infra.
- `SiloRegistry` (CTR-02), `SeniorNavAggregator` (CTR-05).
- `ZipRedemptionQueue` — the **ONE** senior zipUSD→USDC exit. Every silo's warehouse `repaySink` points HERE
  (fungible senior; redemption drains any warehouse). Never per-silo.
- `SzAlphaRateOracle` — the bridge rate feed (8x-02 Base side).

**Replicated PER SILO (by `SiloDeployer`, CTR-06c):**
- The EulerEarn pool (`createEulerEarn`) + its base USDC resting market + its reservoir market (escrow/borrow vaults +
  router + LP oracle).
- One `EulerVenueAdapter` (1:1 with the pool — it stores a single `eePool`/`baseUsdcMarket`; never shared).
- The warehouse `{Safe, Roles, WarehouseAdminModule}` via `CreditWarehouseDeployer.deploy(...)` (reused verbatim;
  `repaySink` = the **shared** `ZipRedemptionQueue`).
- A Baal two-Safe substrate `{mainSafe, sidecar}` via `SummonSubstrate._summon`.
- A `ZipDepositModule` (points at THIS silo's `eePool` + `warehouseSafe`; mints the **shared** `zipUSD`).
- A junior `SzipNavOracle`.
- An `ExitGate` + a `SzipUSD` — **the szipUSD junior share token is PER-SILO** (loss is local to a silo's junior; the
  senior residual is what reaches the shared zipUSD).
- The 9 engine modules (`DurationFreezeModule` FIRST — the buy-burn + LP-strategy wire to it as `coverageGate` —
  then `SzipBuyBurnModule`, `ReservoirLoopModule`, `LpStrategyModule`, `HarvestVoteModule`, `ExerciseModule`,
  `SellModule`, `RecycleModule`, `OffRampModule`).
- The loss side: `LienXAlphaEscrow` + `DefaultCoordinator` (circular `setEscrow`/`setDefaultCoordinator` wiring).

`addSilo`'s 9 non-zero fields map: `adapter`=the venue adapter, `warehouseSafe`=the warehouse Safe, `eePool`=the EE
pool, `juniorBasket`=the junior Baal `mainSafe` (routing/label only — NOT topology-asserted), `escrow`/
`defaultCoordinator`/`navOracle`/`freeze`=the per-silo loss+freeze components, `curator`=the venue adapter (matches
`DeployLocal._configureEulerEarn`'s `setCurator(adapter)`; routing/label only). The 6-clause topology assert
(`SiloRegistry.sol:159-165`) forces: `freeze.{eulerEarn==eePool, warehouse==warehouseSafe, navOracle==navOracle}`,
`escrow.coordinator==defaultCoordinator`, `defaultCoordinator.navOracle==navOracle`, `adapter.eulerEarn==eePool`.

---

## Open decisions to RATIFY before 06b/06c cold-build

- **D1 (POL sharing).** Is the protocol-owned-liquidity zipUSD/xALPHA ICHI vault + Hydrex gauge **shared** across
  silos (one pool) or **per-silo**? Recommend SHARED pool address (there is one zipUSD), with each silo's `mainSafe`
  holding its OWN staked LP position and its own reservoir escrow vault whose `asset() == the shared polIchiVault`.
  NB the real pool is not live yet (M1 stand-in on the WETH/USDC vault — see PROGRESS "BLOCKED (external)"), so this
  is a per-silo wiring decision, not a new contract.
- **D2 (post-deploy Timelock grants — a runbook, NOT script code).** `SiloDeployer` CANNOT inline: (a)
  `zipUSD.setCapacity(newDepositModule, max)` or (b) any hub re-point — `zipUSD`/`queue`/`registry` are Timelock-owned.
  These are post-deploy Timelock governance steps, mirroring the CTR-03 `setRegistry`/`setController` obligation. The
  deployer hands silo-internal ownership to the Timelock and returns the silo handles; the hub grants + the
  `SiloRegistry.addSilo` + `setCurrentSilo` rollover follow as a Timelock runbook (06c documents it).
- **D3 (test strategy).** EE can't compile (0.8.26 ≠ 0.8.24) and no fork test has ever stood up a real EE pool
  (`DeployZipcode.t.sol` is all `vm.skip(true)`). 06c's gate MUST inject a mock EE via an **overridable
  pool-creation seam** — make the `createEulerEarn` step `virtual` (mirroring `DeployZipcode._phaseP5`'s `virtual`
  pattern) so the test exercises the full junior/warehouse/reservoir/`addSilo` orchestration against the rich
  `MockEulerEarn` (`EulerVenueAdapter.t.sol`'s in-file mock with the 30-slot withdraw queue). The live-factory `.call`
  path is fork-runbook-only (like `DeployLocal`), NOT a unit gate.
- **D4 (concurrency proof).** De-scope "29 REAL concurrent lines." Prove instead: two registered silos route
  originations by `siloId`; the registry `MAX_LINES_PER_SILO=28` cap forces `SiloFull` then a `setCurrentSilo`
  rollover lands the 29th in silo #2; `SeniorNavAggregator.seniorBacking()` sums both warehouses. Drive the per-silo
  count toward the cap by **pranking the controller** (the `ZipcodeController.t.sol:938` precedent — "via real
  originations would be 28 opens (expensive); instead drive the count by pranking") plus a few real opens per silo.
  Do NOT open 28 real lines per silo.
- **D5 (the senior off-ramp under federation — UNRESOLVED, needs ratification).** `OffRampModule` (setUp
  `(tl, engineSafe, op, zipUSD, queue)`) drives the **senior** `ZipRedemptionQueue` (zipUSD→USDC), and
  `ZipRedemptionQueue.setRedeemController` sets a **single** redeem controller (the rq Safe). A mutualized one-queue
  topology therefore **cannot naively replicate the OffRamp per silo** — N silos can't each be the queue's sole redeem
  controller. The senior off-ramp is hub-level, not junior-local. **Decision owed:** (a) ONE shared OffRamp/rq Safe at
  the hub that pulls REDEEM funding from any warehouse (likely; senior is fungible), or (b) the queue accepts multiple
  redeem controllers (a `ZipRedemptionQueue` contract change → back-pressure). This is CRE-02 territory (redemption
  sequencing) + a federation decision. **Until ratified, CTR-06b's junior tranche EXCLUDES `OffRampModule` and the
  `queue.setRedeemController` wiring** — the per-silo deployer builds the junior yield/freeze/buy-burn + loss stack
  only; the senior off-ramp stays hub-side. (CTR-06c notes the seam; it does not wire a per-silo OffRamp.)

---

## The split (build order)

- **CTR-06a — `ReservoirMarketDeployer` borrow-vault `setGovernorAdmin` fix** (discharges FE-07 Finding A). Tiny,
  independent, clean `forge test` gate. The only near-term cold-buildable piece; a true 06c prerequisite (every
  silo's reservoir market is built by this script). Ticket: `CTR-06a-reservoir-governoradmin-fix.md`. **NEXT-able now.**
- **CTR-06b — `JuniorTrancheDeployer`** — the MISSING reusable artifact: a callable that stands up one self-consistent
  junior tranche (Baal substrate + NAV oracle + ExitGate/SzipUSD + deposit module + the **8** yield/freeze/buy-burn
  engine modules + loss side), analogous to `CreditWarehouseDeployer`. Excludes `OffRampModule` (senior off-ramp →
  D5). Large but bounded. **Depends on D1 + D5 ratified.** Ticket: `CTR-06b-junior-tranche-deployer.md`.
- **CTR-06c — `SiloDeployer` orchestrator + feasible test** — composes EE-pool creation (D3 virtual seam) +
  `CreditWarehouseDeployer` + `ReservoirMarketDeployer` (06a-fixed) + `JuniorTrancheDeployer` (06b) + `addSilo`, hands
  ownership to the Timelock, and documents the D2 hub-grant runbook. Gate = the D3/D4 mock-EE two-silo routing test.
  **Depends on CTR-06a + CTR-06b.** Ticket: `CTR-06c-silo-deployer-orchestrator.md`.

## Depends on / unblocks
- **Depends on:** CTR-02, CTR-03, CTR-05 (all DONE). CTR-06b adds D1; CTR-06c adds CTR-06a+CTR-06b.
- **Unblocks:** horizontal scaling (N pools) + the federation migration path (silo #0 = today's `DeployLocal`).
