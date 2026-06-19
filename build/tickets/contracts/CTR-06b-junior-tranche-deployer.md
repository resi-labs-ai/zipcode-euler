# CTR-06b — JuniorTrancheDeployer: one callable that stands up a self-consistent junior tranche

> Contract-track EXPANSION (the missing reusable artifact). Split from CTR-06 (index + pinned decomposition:
> `CTR-06-silo-deployer.md`). The per-junior analogue of `CreditWarehouseDeployer` — it stands up ONE junior tranche
> (Baal substrate + NAV oracle + ExitGate/SzipUSD + deposit module + the 8 yield/freeze/buy-burn engine modules +
> loss side), hands every OZ-ownable contract to the Timelock, and hands the two Baal Safes to the persistent `team`
> admin multisig (§4.5 two-tier model). CTR-06c calls it once per silo.
> Spec: `claude-zipcode.md` §6/§7/§8 (junior tranche + engine) / §11 (loss) / §17.
>
> **REVISED 2026-06-19** after a 4-critic fan-out (junior-dev / spec-fidelity / reference-verifier / contract-binding)
> converged on the owner/signer model as the single most-blocking gap. The original draft said "the broadcaster MUST
> be `team`" while CTR-06c calls `new JuniorTrancheDeployer().deploy(...)` — mutually exclusive (a `new`'d contract's
> internal calls run with `msg.sender == the deployer instance`, never the broadcaster). Resolved below as the
> transient-owner pattern. All other findings (param struct, NAV-leg injection, helper provenance, Safe handoff target,
> minor wording) are folded in. Every ctor/setUp binding was re-verified against live source this window — all resolve.

## Why (the seam)
`DeployZipcode` stamps exactly ONE junior tranche inline across phases P3/P6/P7/P8/P9 (~30 deployments + ~15 seam
asserts, strict ordering). There is NO reusable junior deployer (unlike the warehouse). To add silo #2..N, CTR-06c
needs a single callable that reproduces that junior substrate parameterized — pointing at THIS silo's
`eePool`/`warehouseSafe` and the **shared** hub `zipUSD`. This ticket extracts that orchestration faithfully into one
contract.

## Prerequisite ratifications (RATIFIED 2026-06-19 by the reviewer)
- **D1 (POL sharing) RATIFIED:** the zipUSD/xALPHA `polIchiVault` + `polGauge` are **inputs** to this deployer
  (shared pool address across silos by default; each silo's `mainSafe` stakes its own LP position). NB the real pool
  is not live — M1 stand-in (PROGRESS "BLOCKED (external)").
- **D5 (senior off-ramp) RATIFIED:** this deployer **EXCLUDES `OffRampModule`** and the
  `ZipRedemptionQueue.setRedeemController` wiring. It builds the junior yield/freeze/buy-burn + loss stack only (8
  engine modules, not 9). The senior off-ramp is hub-level (CRE-02 + the D5 federation decision).

---

## The contract model (LOAD-BEARING — pin this before anything else)

`JuniorTrancheDeployer` is **`contract JuniorTrancheDeployer is SummonSubstrate`** in a new file
`contracts/script/JuniorTrancheDeployer.s.sol` (`.s.sol`, because `SummonSubstrate is Script` — `_summon` transitively
uses `vm.computeCreate2Address` via `computeMainSafe`, so the contract is cheatcode-dependent and is a forge
script/test-time orchestrator, NOT a plain on-chain factory). It is `new`'d and `.deploy()`'d exactly like
`CreditWarehouseDeployer` (`DeployZipcode.s.sol:266` `new CreditWarehouseDeployer().deploy(...)`), so CTR-06c's
`new JuniorTrancheDeployer().deploy(JuniorParams{...})` works.

**Self-summon transient-owner pattern (the resolution of the msg.sender collapse):**
- `_summon`/`_execAsTeam`/`_setShamansManager`/`_enableModuleOnSafe` all drive a Safe via the pre-validated `v==1`
  signature path, which requires `msg.sender == the Safe owner` (`SummonSubstrate.s.sol:159-167`,
  `DeployZipcode.s.sol:614-620`). Inside `new JuniorTrancheDeployer().deploy(...)`, `msg.sender` for those internal
  calls is **the deployer instance** — NOT the broadcaster, NOT `team`.
- Therefore `deploy()` calls `_summon(address(this), p.saltNonce)` — making the **deployer instance** the transient
  owner/signer of BOTH Safes (the `CreditWarehouseDeployer.sol:100-122,173-176` idiom: deploy-as-self, sign-as-self).
  Every subsequent Safe-drive then validates because `msg.sender == address(this) == owner`.
- **Final handoff (step 17 below):** before returning, `deploy()` hands BOTH Safes to the persistent real `team`
  (a `JuniorParams` input — the team admin multisig). This mirrors `CreditWarehouseDeployer._assignAndHandoff`'s
  `swapOwner` of the warehouse Safe to `godOwner` (`:160-167`), adapted to the Baal two-Safe substrate. **The Safes go
  to `team`, NOT the Timelock** — DeployZipcode P9 never transfers the Safes; they stay `team`-owned (the §4.5 two-tier
  admin/operator model: team = admin tier, the immutable CRE hot key = operator tier). Only OZ-ownable contracts go to
  the Timelock (§17).

**Helper provenance (reuse vs reimplement):**
- **Inherited from `SummonSubstrate`:** `_summon(address,uint256)` + `computeMainSafe` + the `Substrate` struct. Use as-is.
- **Reimplemented (parameterized) in this contract:** `_cloneModule`, `_enableModuleOnSafe`, `_setShamansManager`,
  `_execAsTeam`. These live on `DeployZipcode` (`:579/:588/:594/:617`), NOT on `SummonSubstrate`, and they read
  `DeployZipcode` storage (`i.team`, `i.saltNonce`). Copy their bodies but source `team = address(this)` and
  `saltNonce = p.saltNonce` from this deployer's own params. (Do NOT try to inherit them — they are orchestrator-local.)

---

## Deliverable
A new `contracts/script/JuniorTrancheDeployer.s.sol`. A single `deploy(JuniorParams memory p)` that, given the hub +
per-silo handles, produces a self-consistent junior tranche and returns its handles. **Build order is load-bearing**
(matches `DeployZipcode` P3/P6/P7/P8/P9):

### `JuniorParams` struct (define exactly this — every input the steps below dereference)
```
struct JuniorParams {
    // -- identity / authority --
    address timelock;        // owner_ of every module + OZ-ownable handoff target (§17)
    address team;            // the persistent admin multisig the two Safes are handed to (§4.5)
    address creOperator;     // module `operator` + the ExitGate windowController (M1 CRE hot key)
    uint256 saltNonce;       // DISTINCT per silo (CREATE2 — see Do NOT)
    address workflowAuthor;  // CRE identity seal (step 16)
    bytes32 workflowId;      // CRE identity seal (step 16)
    // -- shared hub handles (NOT deployed here) --
    address zipUSD;          // the shared senior $1 unit (Timelock-owned; setCapacity is the D2 runbook, not here)
    address rateOracle;      // the shared SzAlphaRateOracle (hub; an input, never owned/transferred by this deployer)
    // -- per-silo handles built upstream by CTR-06c --
    address eePool;          // this silo's EulerEarn pool (mock in the D3 test)
    address warehouseSafe;   // this silo's warehouse Safe (CreditWarehouseDeployer output)
    address escrowVault;     // this silo's reservoir escrow vault (ReservoirMarketDeployer, CTR-06a-fixed)
    address borrowVault;     // this silo's reservoir borrow vault
    // -- NAV leg tokens (INPUTS, not BaseAddresses constants — the D3 fork test injects mocks; see Done-when) --
    address usdc;
    address xAlphaMirror;
    address hydx;
    address oHydx;
    // -- POL (D1: shared pool address; per-silo staked position) --
    address polIchiVault;    // == escrowVault.asset() (seam #4)
    address polGauge;
    address capitalSink;     // loss-side capital sink (LienXAlphaEscrow ctor)
    // -- numeric knobs --
    uint32 W;                // NAV TWAP window
    uint256 maxAge;          // NAV
    uint256 maxDeviationBps; // NAV
    uint256 tvlCap;          // ExitGate
    uint16  dBps;            // buy-burn discount
    uint256 buybackCap;      // buy-burn
    uint256 borrowCap;       // reservoir loop
    uint256 recoveryFloor;   // DefaultCoordinator (must be < 1e18)
}
```
Venue infra that the modules only STORE (never call at `setUp`) stays a `BaseAddresses.*` constant inside the deployer,
matching `DeployZipcode`: `CRE_KEYSTONE_FORWARDER` (NAV/coord forwarder), `EVC`, `COW_SETTLEMENT`,
`ALGEBRA_SWAP_ROUTER`, `HYDX`-fed venue addrs `HYDREX_VOTER`/`HYDREX_REWARDS_DISTRIBUTOR`. (They are live on the Base
fork; the deployer test does not exercise their call paths, so they need no injection.)

### Build steps (each line-cited to `DeployZipcode.s.sol`)
1. **Baal two-Safe substrate** — `Substrate memory sub = _summon(address(this), p.saltNonce)` (self as transient owner;
   see the contract model above). `sub.mainSafe != sub.sidecar` is enforced by the summoner; the freeze `setUp` also
   reverts `BadParams` if they collide (`DurationFreezeModule.sol:115`). (`DeployZipcode._phaseP3:287-288` = `_summon`,
   but with `i.team`; here with `address(this)`.) `engineSafe := sub.mainSafe`.
2. **`SzipNavOracle`** ctor (11 args, `SzipNavOracle.sol:187-199` / `DeployZipcode.s.sol:300-312`):
   `(CRE_KEYSTONE_FORWARDER, p.zipUSD, p.usdc, p.xAlphaMirror, p.hydx, p.oHydx, sub.mainSafe, sub.sidecar, p.W,
   p.maxAge, p.maxDeviationBps)`. **NAV legs are `p.*` inputs, NOT `BaseAddresses.*`** — the freeze `setUp` reads
   `zipUSD/usdc/xAlpha/hydx/oHydx` LIVE off this oracle (`DurationFreezeModule.sol:130-135`), and the D3 fork test
   stands those up as mocks (`DurationFreezeModule.t.sol:1286-1295`).
3. **`ExitGate` + `SzipUSD`** (`:315-318`): `gate = new ExitGate(sub.baal, navOracle, p.zipUSD, p.xAlphaMirror,
   p.tvlCap)` (`ExitGate.sol:76`); `szip = new SzipUSD(gate)` (`SzipUSD.sol:23`); `gate.setShareToken(szip)` (`:94`);
   `navOracle.setShareToken(szip)`; `gate.setWindowController(p.creOperator)` (`:323`, `ExitGate.sol:101`).
4. **`ZipDepositModule`** (`:296-297`): `new ZipDepositModule(p.zipUSD, p.usdc, p.eePool, p.warehouseSafe)`
   (`ZipDepositModule.sol:84`); `depositModule.setGate(gate)` (`:326`, `ZipDepositModule.sol:103`). **NOTE (D2):**
   `zipUSD.setCapacity(depositModule, max)` is a Timelock step (zipUSD owned by the Timelock) — NOT done here; CTR-06c's
   runbook covers it. **Consequence:** the deposit module CANNOT mint zipUSD until that D2 grant lands; the tranche is
   topology-valid but inert on the mint path until then (expected). Do NOT attempt `setCapacity` inline.
5. **Shaman grant** (`:333`): `_setShamansManager(sub.baal, sub.mainSafe, gate)` — grant the Gate `manager(2)` via
   `self -> mainSafe.execTransaction -> Baal.setShamans([gate],[2])` (reimplemented helper, team=self). Asserts
   (`:336-337`): `IBaal(sub.baal).totalShares()==0`, `gate.shareToken()==szip`.
6. **`DurationFreezeModule` FIRST** (it is the `coverageGate` the buy-burn + LP-strategy wire to — must precede them):
   `durationFreeze = _cloneModule(address(new DurationFreezeModule()), abi.encode(p.timelock, sub.mainSafe,
   sub.sidecar, p.creOperator, navOracle, p.eePool, p.warehouseSafe), sub.mainSafe)` — a **7-tuple** whose FIRST arg is
   `owner_ = p.timelock` (`DurationFreezeModule.sol:98-107` decode order `(owner_, mainSafe_, sidecar_, operator_,
   navOracle_, eulerEarn_, warehouse_)`; encode precedent `DeployZipcode.s.sol:394-396`). Then
   `_enableModuleOnSafe(sub.sidecar, durationFreeze)` (`:399` — enabled on BOTH Safes; self is a direct owner of the
   sidecar via `_addOwnerToSidecar`, so the reimplemented `_execAsTeam(sidecar, sidecar, enableModule)` validates).
7. **`SzipBuyBurnModule`** (`:402-409`; setUp decode `SzipBuyBurnModule.sol:170-184`): `abi.encode(p.timelock,
   engineSafe, p.creOperator, navOracle, szip, p.usdc, COW_SETTLEMENT, p.dBps, p.buybackCap, durationFreeze)`. Then
   `navOracle.setEngineSafe(engineSafe)`; `gate.setEngineSafe(engineSafe)` (`ExitGate.sol:108`); seam asserts
   (`:411-418`): `buyBurn.coverageGate()==durationFreeze`, `buyBurn.engineSafe()==gate.engineSafe()==navOracle.engineSafe()`.
8. **`ReservoirLoopModule`** (`:421-425`; decode `ReservoirLoopModule.sol:84-98`): `abi.encode(p.timelock, engineSafe,
   p.creOperator, EVC, p.borrowVault, p.escrowVault, p.polIchiVault, p.usdc, p.borrowCap)`.
9. **`LpStrategyModule`** (`:428-432`; decode `LpStrategyModule.sol:85-93`): `abi.encode(p.timelock, engineSafe,
   p.creOperator, p.polIchiVault, p.polGauge, durationFreeze)`. Seams (`:434-439`):
   `lpStrategy.ichiVault()==p.polIchiVault==IEVault(p.escrowVault).asset()`; `lpStrategy.coverageGate()==durationFreeze`.
10. **`HarvestVoteModule`** (`:442-446`; decode `HarvestVoteModule.sol:77-85`): `abi.encode(p.timelock, engineSafe,
    p.creOperator, p.polGauge, HYDREX_VOTER, HYDREX_REWARDS_DISTRIBUTOR)`.
11. **`ExerciseModule`** (`:449-453`; decode `ExerciseModule.sol:73-75`): `abi.encode(p.timelock, engineSafe,
    p.creOperator, OHYDX)`.
12. **`SellModule`** (`:456-460`; decode `SellModule.sol:89-102`): `abi.encode(p.timelock, engineSafe, p.creOperator,
    ALGEBRA_SWAP_ROUTER, HYDX, p.usdc, p.zipUSD, p.xAlphaMirror, uint256(300_000e18))`.
13. **`RecycleModule`** (`:463-467`; decode `RecycleModule.sol:138-148`): `abi.encode(p.timelock, engineSafe,
    p.creOperator, depositModule, p.usdc, navOracle, p.eePool, p.warehouseSafe)`. One-bank seam (`:469-473`):
    `recycle.warehouse()==depositModule.warehouse()`, `recycle.eePool()==depositModule.eePool()`,
    `recycle.navOracle()==navOracle`.
14. **Loss side** (P7 order — coordinator FIRST to break the cycle): `coord = new DefaultCoordinator(
    CRE_KEYSTONE_FORWARDER, navOracle, p.xAlphaMirror, p.recoveryFloor)` (`:494-496`; `DefaultCoordinator.sol:128`);
    `escrow = new LienXAlphaEscrow(p.xAlphaMirror, coord, p.capitalSink, sub.sidecar)` (`:499`;
    `LienXAlphaEscrow.sol:106`); `coord.setEscrow(escrow)`; `navOracle.setDefaultCoordinator(coord)` (`:502-503`);
    assert `escrow.coordinator()==coord` (`:505`).
15. **NAV final wiring** (P8, `:511-519`): `navOracle.setLpPosition(p.polIchiVault, p.polGauge)`;
    `navOracle.setReservoirLeg(p.escrowVault, p.borrowVault)`; `navOracle.setXAlphaRateOracle(p.rateOracle)`
    (`SzipNavOracle.sol:292`; the shared hub rate oracle — an input); assert `navOracle.shareToken() != address(0)`.
    **M1 note:** do NOT call `setLpTwapWindow` (the `DeployZipcode:517` fair-LP branch). D1 fixes the LP leg on the M1
    CRE-push stand-in (`lpTwapWindow == 0`); the fair-LP TWAP branch is a later parameter swap, not built here.
16. **Identity seal + OZ-ownable handoff** for the receivers this tranche owns — mirror `DeployZipcode._phaseP9`
    (`:526-559`, the per-junior subset): `setExpectedAuthor(p.workflowAuthor)` + `setExpectedWorkflowId(p.workflowId)`
    (`DeployZipcode:604-606`) then `transferOwnership(p.timelock)` on **`navOracle`, `gate`, `szip`, `escrow`, `coord`**
    only. Identity-seal applies to the `ReceiverTemplate`s (`navOracle`, `coord`). The engine modules are ALREADY
    Timelock-owned from `setUp` (`owner_ == p.timelock`) — do NOT re-transfer (reverts, `:564-567`). `ZipDepositModule`
    has no ownable surface (`:560-562`; its `setGate` admin is the immutable deployer = this throwaway instance, so it
    is never re-homed — acceptable, `setGate` already ran in step 4). **Do NOT transfer `p.rateOracle`** (a shared hub
    input this deployer never owned — a literal `_phaseP9` mirror would wrongly transfer `d.rateOracle` and revert).
17. **Safe ownership handoff to `team`** (NEW — the transient-owner cleanup; mirrors `CreditWarehouseDeployer._assign
    AndHandoff:160-167`): hand BOTH Safes from `address(this)` to `p.team`. For each Safe, locate the `prevOwner`
    pointer for `address(this)` by traversing `getOwners()` (do NOT assume `SENTINEL_OWNERS` — the summoned Safe may
    carry the summoner/default owner alongside self), then drive (self is a direct owner of both)
    `swapOwner(prevOwner, address(this), p.team)` via the self-signed `execTransaction` path. Assert post-handoff:
    `ISafe(mainSafe).isOwner(p.team)`, `ISafe(sidecar).isOwner(p.team)`, `!ISafe(mainSafe).isOwner(address(this))`,
    `!ISafe(sidecar).isOwner(address(this))` (effect, not "didn't revert").

Return a `JuniorTranche` struct: `{baal: sub.baal, mainSafe: sub.mainSafe, sidecar: sub.sidecar, navOracle, gate, szip,
depositModule, durationFreeze, buyBurn, reservoirLoop, lpStrategy, harvestVote, exercise, sell, recycle, escrow, coord}`
for CTR-06c's `addSilo`. (CTR-06c supplies the warehouse-side `adapter`/`warehouseSafe`/`eePool`/`curator` + the
`juniorBasket = mainSafe` label; this struct supplies clauses 1–5's component side — see Key req 1.)

## Spec §
`claude-zipcode.md` §6/§7 (junior share + NAV), §8 (engine modules), §11 (loss side), §17 (Timelock owns all OZ-ownable
contracts, re-pointable), §4.5 (the two-tier admin/operator model — the Baal Safes are the `team` admin tier). The
decomposition is pinned in the CTR-06 index.

## Binds to (verified against live source this window)
- **Contract model:** `CreditWarehouseDeployer` transient-self-owner + sign-as-self + `swapOwner` handoff
  (`CreditWarehouseDeployer.sol:100-122,160-167,173-176`). `SummonSubstrate._summon(address,uint256)` is `internal`
  (`SummonSubstrate.s.sol:62`) and `SummonSubstrate is Script` (`:21`) → inherit it; the init-action adds the passed
  `teamMultisig` as the Safe owner (`:145-147`) and the sidecar add requires `msg.sender == that owner` (`:159-167`).
- **Helpers to reimplement (DeployZipcode-local, `i.*`-bound):** `_cloneModule:579`, `_enableModuleOnSafe:588`,
  `_setShamansManager:594`, `_execAsTeam:617`, `_sealIdentity:604`.
- **Every ctor/setUp tuple** is line-cited inline above and was confirmed exact (arg order + types) by the
  reference-verifier: NAV `:187-199`, freeze `:98-107`/`:130-135`/`:115`, the 7 engine setUps (`SzipBuyBurnModule:170-184`,
  `ReservoirLoopModule:84-98`, `LpStrategyModule:85-93`, `HarvestVoteModule:77-85`, `ExerciseModule:73-75`,
  `SellModule:89-102`, `RecycleModule:138-148`), `DefaultCoordinator:128`, `LienXAlphaEscrow:106`, `ExitGate:76/94/101/108`,
  `SzipUSD:23`, `ZipDepositModule:84/103/61`.
- `SiloRegistry` topology assert the result MUST satisfy (`SiloRegistry.sol:159-165`):
  `IFreeze(freeze).eulerEarn()==eePool`, `.warehouse()==warehouseSafe`, `.navOracle()==navOracle`,
  `IEscrow(escrow).coordinator()==defaultCoordinator`, `INavWriter(defaultCoordinator).navOracle()==navOracle`,
  `IAdapter(adapter).eulerEarn()==eePool`. Clauses 1–3 (freeze) + 4–5 (escrow/coord) are satisfied by THIS deployer's
  outputs; clause 6's `adapter` + the `eePool`/`warehouseSafe` sides are CTR-06c's inputs.
- The reservoir market handles (`escrowVault`, `borrowVault`) come from `ReservoirMarketDeployer.deploy` (CTR-06a-fixed)
  — INPUTS to this deployer, built by CTR-06c.

## Starting state
- CTR-06a (reservoir governor fix) DONE. The hub (`zipUSD`, `ZipRedemptionQueue`, `SzAlphaRateOracle`, Timelock,
  `SiloRegistry`, controller) exists from `DeployZipcode`. The reservoir market + EE pool for this silo are built by
  CTR-06c and passed in.

## Do NOT
- Do NOT deploy or re-point any HUB contract (`zipUSD`, `ZipRedemptionQueue`, controller, registry, `rateOracle`) —
  they are shared inputs, Timelock-owned. Do NOT call `zipUSD.setCapacity` (Timelock step, D2). Do NOT transfer
  `p.rateOracle` (a shared input never owned here).
- Do NOT build `OffRampModule` or call `queue.setRedeemController` (D5 — senior off-ramp is hub-level).
- Do NOT re-`transferOwnership` the engine modules (already Timelock-owned from `setUp`).
- Do NOT hand the two Baal Safes to the Timelock — they go to `p.team` (§4.5 admin tier). Do NOT leave them owned by
  the throwaway deployer instance (step 17 hands off + asserts).
- Do NOT hardcode the NAV leg tokens as `BaseAddresses.USDC/HYDX/OHYDX` — they are `p.*` inputs (the D3 test injects mocks).
- Do NOT reorder: `DurationFreezeModule` MUST precede buy-burn + LP-strategy (they wire to it as `coverageGate`);
  coordinator MUST precede escrow (the ctor cycle); the NAV oracle MUST precede the freeze setUp (it reads
  `zipUSD/usdc/xAlpha/hydx/oHydx` live off the oracle).
- Do NOT reuse silo #0's `saltNonce`. Within ONE silo deploy the same `saltNonce` is SAFE across all CREATE2
  deployments (each module clone has a distinct mastercopy+initializer; the Baal/Safe uses a different factory). The
  guaranteed CROSS-silo collision is the main Safe (its `createProxyWithNonce` initializer is empty/silo-invariant, so
  its address depends only on `saltNonce`). Take `saltNonce` as a distinct input per silo.

## Key requirements
1. **One callable, self-consistent.** `deploy(JuniorParams)` returns a junior tranche whose freeze/escrow/coordinator/
   navOracle satisfy `SiloRegistry.addSilo`'s topology clauses 1–5 on the first try (CTR-06c proves it by feeding the
   returned handles + the warehouse-side `adapter`/`eePool`/`warehouseSafe` to a real `SiloRegistry.addSilo`).
2. **Shared hub, per-silo junior.** `zipUSD`/`rateOracle`/`timelock`/`team` are inputs (shared/persistent);
   `szipUSD`/NAV/engine/loss are freshly deployed (per-silo). Loss is local to this junior's `szip`.
3. **All seam asserts from `DeployZipcode` reproduced** (coverage-gate ×2, engine-safe, shared-LP, one-bank,
   escrow-coordinator, NAV share-token, shaman/totalShares) — the deployer fails closed on any mis-wire.
4. **Ownership handoff asserted** — OZ-ownable (`navOracle`/`gate`/`szip`/`escrow`/`coord`) → Timelock; engine modules
   already Timelock-owned from setUp; **both Safes → `team`** (step 17 asserts owner-added + self-removed).
5. **§2 topology / non-commingling** (NOT §11 — index correction): assert the junior `mainSafe` AND `sidecar` are both
   distinct from the silo's `warehouseSafe`. This STRENGTHENS `DeployZipcode`'s `SeamWarehouseCommingled` (`:291`,
   which checks only `warehouse.safe != mainSafe`) by also covering the sidecar — a deliberate addition, not a verbatim match.

## Done when (gate — `forge test`, FORK; EE + NAV legs + LP mocked per D3)
- `forge build` green; a new `contracts/test/JuniorTrancheDeployer.t.sol` **fork test** (on `_selectBaseFork()` — the
  live `BaalAndVaultSummoner` + live EVK/EVC are reachable; reuse the `DurationFreezeModule.t.sol:1274-1314` +
  `ReservoirLoopModule.t.sol` fixture idioms): inject mock NAV legs (`zip/usdc/xalpha/hydx/ohydx` per
  `DurationFreezeModule.t.sol:1286-1295`), a `MockEulerEarn` (`eePool`), a `MockLpToken` (`polIchiVault`), and the
  reservoir `escrowVault`/`borrowVault` built via the real `ReservoirMarketDeployer` over the live EVK + mock LP. Run
  `deploy(...)` and assert: (a) every seam assert passes (deploy did not revert closed); (b) every OZ-ownable owner is
  the Timelock, each engine module owner is the Timelock (from setUp), and BOTH Safes are owned by `team` and NOT by the
  deployer instance; (c) the returned handles satisfy the `SiloRegistry` topology clauses 1–5 when fed (with a
  warehouse-side `adapter`/`eePool`/`warehouseSafe`) to a real `SiloRegistry.addSilo` from a pranked Timelock; (d) the
  non-commingling assert (Key req 5) holds.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-06a (reservoir governor fix); D1 + D5 ratified (2026-06-19).
- **Unblocks:** CTR-06c (the SiloDeployer orchestrator calls this once per silo).
