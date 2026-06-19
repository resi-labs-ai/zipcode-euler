# CTR-06 — SiloDeployer: stamp + wire + register a full venue silo

> Contract-track change (EXPANSION). The script that stands up a complete silo as one unit — a new EulerEarn pool,
> its resting + reservoir markets, a new `EulerVenueAdapter`, the warehouse (Safe + Roles + WarehouseAdminModule),
> the junior/loss/freeze stack, and the `SiloRegistry.addSilo` call. This is what makes "fill pool → deploy next →
> route there" real. Reuses the existing per-warehouse deployer verbatim.
> Spec: `claude-zipcode.md` §4.5/§4.7/§9.1 (deploy orchestration) / §17.

## Why (the seam)
`DeployZipcode`/`DeployLocal` stamp exactly ONE of everything. To add silo #2..N the protocol needs a parameterized
deploy that produces one more self-consistent silo and registers it. The pieces already exist and are per-instance;
this script orchestrates them in dependency order and hands ownership to the Timelock.

## Deliverable
A new `contracts/script/SiloDeployer.sol` (fork-driven, modeled on `DeployLocal.s.sol` + `CreditWarehouseDeployer`):
1. `EulerEarnFactory.createEulerEarn(timelockOwner, initialTimelock = 0, USDC, name, symbol, salt)` →
   the silo `eePool` (`reference/euler-earn/src/EulerEarnFactory.sol:90-113`). **`initialTimelock = 0`** or the
   first `openLine` reverts (`EulerVenueAdapter.sol:209`).
2. Build + onboard the silo's two non-line markets (the no-borrow resting USDC market + the reservoir borrow vault),
   `submitCap`→`acceptCap` each, mirroring `DeployLocal.s.sol:130-145`. Set the supply queue to the resting market.
3. Deploy a new `EulerVenueAdapter` bound to this `eePool`; `setCurator(adapter)` + (curator implies allocator)
   on the pool (`EulerEarn.sol:209`).
4. `CreditWarehouseDeployer.deploy(godOwner, receiverAdmin, eePool, usdc, forwarder, repaySink, saltNonce)` —
   stands up THIS silo's `{Safe, Roles, WarehouseAdminModule}` (reused verbatim,
   `contracts/script/CreditWarehouseDeployer.sol:66-98`). **`repaySink` = the SHARED `ZipRedemptionQueue`** (one
   senior exit queue funded by every silo's warehouse).
5. Stand up the silo's junior/loss/freeze stack: a junior Baal/szipUSD basket, a `LienXAlphaEscrow`, a
   `DefaultCoordinator`, a `DurationFreezeModule` clone (already a per-binding `ModuleProxyFactory` clone,
   `DurationFreezeModule.sol:41-44`) `setUp` to `{mainSafe, sidecar, operator, navOracle, eulerEarn = this eePool,
   warehouse = this Safe}`, and a `SzipNavOracle` for this junior.
6. `SiloRegistry.addSilo(siloId, Silo{...})` (CTR-02) — passes the admission topology assert.

## Spec §
`claude-zipcode.md` §9.1 (deploy/wiring orchestration), §4.5/§4.7, §17 (Timelock owns everything; wiring re-pointable).

## Binds to (verified)
- `EulerEarnFactory.createEulerEarn` (`reference/euler-earn/src/EulerEarnFactory.sol:90-113`).
- `CreditWarehouseDeployer.deploy(address,address,address,address,address,address,uint256)`
  (`contracts/script/CreditWarehouseDeployer.sol:66-74`); `ROLE_KEY = keccak256("ZIPCODE_WAREHOUSE_CRE")` (`:26`).
- EE admin: `submitCap`/`acceptCap`/`setSupplyQueue`/`setCurator` (`EulerEarn.sol:287,507,325,209`); the onboarding
  idiom in `DeployLocal.s.sol:130-166`.
- `DurationFreezeModule.setUp` 7-tuple (`DurationFreezeModule.sol:98-139`); `EulerVenueAdapter` ctor
  (`EulerVenueAdapter.sol:91-113`); `SiloRegistry.addSilo` (CTR-02).
- The reservoir market builder `ReservoirMarketDeployer.deploy` (`DeployLocal.s.sol:191-198`).

## Starting state
- One silo (silo #0) is the existing `DeployLocal` deployment. `SiloRegistry` (CTR-02) + controller routing
  (CTR-03) exist. `CreditWarehouseDeployer` is per-warehouse already.

## Do NOT
- Do NOT create the pool with a non-zero `initialTimelock` (bricks `openLine`).
- Do NOT point the silo's `repaySink` at a per-silo queue — every silo funds the ONE shared `ZipRedemptionQueue`
  (fungible senior; redemption can pull from any warehouse).
- Do NOT share one `EulerVenueAdapter` across pools — it stores a single `eePool`/`baseUsdcMarket`
  (`EulerVenueAdapter.sol:39,53`); one adapter per silo.
- Do NOT leave any owner as the deployer — hand Safe/Roles to `godOwner`, all module owners to the Timelock.
- Do NOT skip the §11 non-commingling assert: `repaySink != juniorSafe` and `warehouseSafe != juniorSafe`.

## Key requirements
1. **One unit, registered.** A single `deploy(...)` produces a fully self-consistent silo that passes
   `SiloRegistry.addSilo`'s topology assert (CTR-02 Key req 2) on the first try.
2. **Shared senior plumbing.** `repaySink` = shared `ZipRedemptionQueue`; the silo mints the SAME zipUSD (a deposit
   module pointed at the shared token via `setCapacity`).
3. **Curator/allocator wired** so `openLine`/`fund` work; pool `timelock == 0`.
4. **Ownership handoff** asserted (Safe/Roles → godOwner; modules → Timelock), mirroring `CreditWarehouseDeployer`'s
   post-asserts.
5. **FIX (folded from FE-07 Finding A) — the reservoir borrow vault must be Timelock-governed.** As built,
   `ReservoirMarketDeployer.deploy` transfers ONLY the router governance to `p.governor` (`:88`) and leaves the
   borrow vault's `governorAdmin` stranded on the throwaway deployer instance (no `setGovernorAdmin` call), despite
   its header/`:75` comment claiming "governor retained on both." Add
   `IEVault(borrowVault).setGovernorAdmin(p.governor)` in `ReservoirMarketDeployer.deploy` (alongside the router
   transfer at `:88`) so the Timelock can tune the reservoir LTV/caps/IRM (§17). A post-assert checks
   `IEVault(borrowVault).governorAdmin() == p.governor`. The existing fork market (silo #0) also needs this — fix +
   redeploy it, or note it as stranded. (This is a one-line correctness fix in a script every silo's deploy calls.)

## Done when (gate — `forge test`, fork)
- `forge build` green; a new `contracts/test/SiloDeployer.t.sol` fork test green: deploy silo #2; `addSilo` passes;
  open lines across silo #0 + silo #2 until the **29th concurrent line** lands in silo #2 (proving the cap is
  beaten); `SeniorNavAggregator.seniorBacking()` (CTR-05) reflects both warehouses. EulerEarn mocked where the
  0.8.26≠0.8.24 precedent requires; novel infra fork-real.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02, CTR-03, CTR-05 (and CTR-07 for slot-2 wiring once it lands).
- **Unblocks:** horizontal scaling (N pools) and the federation migration path (silo #0 = today's deployment).
