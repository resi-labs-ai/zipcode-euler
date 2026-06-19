# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**Reviewer to release.** KEEPER-00 (spine) + KEEPER-01a (burn job) are DONE (below). **KEEPER-01 was split into
three** (its sub-systems differ in size + maturity): **01a** fill-detect→`burnFor` (DONE), **01b** the engine
harvest orchestrator, **01c** freeze-`commit`-on-shortfall (deferred — binds to the INCOMPLETE
`DurationFreezeModule`). Candidate NEXT items (reviewer picks):
- **KEEPER-01b — the engine harvest orchestrator** (8-B5…8-B10 `onlyOperator` legs + regime/split/cap policy, as
  `Job`s on the spine). The large remaining (K) item. **POLICY-BLOCKED** — its execution floors / regime+state /
  vote / sizing knobs are undecided (contracts push them off-chain; §17 defers the economic ones). Agenda written
  2026-06-17: `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md` (+ §8.7 pointer). *Ratify A1–A4 + C4 there → the
  strike-loop core slice unblocks (claim→borrow→exercise→sell→recycle→restake, M1-constant slippage, no regime/vote/
  rotation).* Rotation → KEEPER-01c (freeze rebuild).
- **CRE-00 — the wasip1 workflow scaffold** + the shared §8.0 report-encoding package; then the **(R)** workflows
  **CRE-01 / CRE-03 / CRE-04** (all through EXISTING report receivers — not blocked by anything). Independent of (K).
- **CRE-02 (R)+(K) hybrid** — redemption-settle; needs KEEPER-00 (done) + CRE-04. Confirm the (R)/(K) split per
  `CRE-OPS-ROUTING.md`.
- **CTR-06c / CTR-07** (NEW contracts workstream — credit-warehouse scaling + federation). **CTR-02 `SiloRegistry` +
  CTR-03 controller siloId routing + CTR-04 `closeLine` withdraw-queue reclaim + CTR-05 `SeniorNavAggregator` +
  CTR-06a reservoir borrow-vault governor handoff + CTR-06b `JuniorTrancheDeployer` are DONE** (2026-06-18/19, below). CTR-02/03's concurrent slot accounting is fully SOUND (CTR-04 physically frees the
  binding withdraw-queue slot on close; a pool churns 28 *concurrent* lines). **CTR-06 was RE-SCOPED 2026-06-18** — a
  4-critic fan-out found the single-ticket `SiloDeployer` can't cold-build to zero guesses (the junior stack is ~30
  deployments collapsed into 5 nouns with no reusable junior deployer; the hub/silo boundary + shared-queue reach were
  undefined; the "29 real concurrent line" fork gate is infeasible — EE can't compile, no fork test ever stood up a
  real EE pool). Split into **CTR-06a** (`ReservoirMarketDeployer` borrow-vault `setGovernorAdmin` fix — discharges
  FE-07 Finding A; tiny, independent, the only near-term cold-buildable piece — DONE), **CTR-06b** (`JuniorTrancheDeployer` —
  the missing reusable artifact; D1+D5 ratified — DONE 2026-06-19), **CTR-06c** (`SiloDeployer` orchestrator + feasible mock-EE
  test; deps 06a+06b both DONE — now unblocked). Index + pinned hub/silo decomposition + open decisions D1–D5:
  `build/tickets/contracts/CTR-06-silo-deployer.md`. **CTR-06a + CTR-06b both landed 2026-06-19** (notes below; D1+D5
  ratified by the reviewer). **CTR-06c landed 2026-06-19** (note below) — the re-scoped CTR-06 is now COMPLETE
  (06a+06b+06c). **CTR-07 landed 2026-06-19** (note below) — the slot-2 reservoir fund/defund is now revolving;
  finding 3 RESOLVED. So the next of that workstream = **CTR-08** (structure-2 revolving line; dep 02/03, composes
  07/09 — now unblocked, 07 done) or **CTR-09** (0.1%-per-revolution fee; dep 03, composes 08) — reviewer picks. See
  "Credit-warehouse scaling + federation" below.

---

## Credit-warehouse scaling + federation substrate (contract track — NEXT = CTR-02)

> **Contracts are being EXPANDED here** — this workstream supersedes harness.md's "the contract stack is done,
> only CRE/FE remain" framing for these items. They are contract-track tickets (forge-test gate), like CTR-01.
> Tickets: `build/tickets/contracts/CTR-02..CTR-10`. Design blueprint authored 2026-06-18.

**The problem.** Today is "configuration one": one controller → one `EulerVenueAdapter` → one EulerEarn pool → one
warehouse → one junior → one zipUSD. A pool caps at `MAX_QUEUE_LENGTH = 30` markets
(`reference/euler-earn/src/libraries/ConstantsLib.sol:17`, binding on the withdraw queue `EulerEarn.sol:785`); with
2 permanent non-line markets (resting USDC + reservoir) → **28 concurrent lines/pool**. Goal: scale past one pool
AND make the same mechanism a federation substrate under one mutualized senior zipUSD, carrying BOTH repurchase
lines (structure 1, the safe HELOC-warehouse standard) and insurance-underwritten revolving lines (structure 2).

**Locked decisions (2026-06-18 — do not reopen):**
- A silo = one full stack `{venue adapter + warehouse + EE pool + junior tranche}`; replicate the silo, keep
  zipUSD/mint/redeem at the hub. Loss is local to a silo's junior; senior is mutualized (only post-junior residual
  reaches zipUSD).
- **Split slot 2:** no-borrow resting market + separate reservoir vault, funded JIT via a new allocator
  fund/defund path (re-absorbed on repay). 28 lines/pool; allocator key ≠ reservoir operator key.
- **Accommodate BOTH** line structures; repo is the safe default, revolving is for when an insurance policy exists.
- **Sequential-fill sharding:** fill the active pool to 28 → deploy next EE vault → route there → register.
- Open decisions carried into tickets: **A** single controller + registry (chosen) over per-silo (CTR-03);
  **B** fix `closeLine` to reclaim the binding slot (chosen) (CTR-04); **C** ship CTR-02..09 first, CTR-10 later.

**Verified findings (obligations — discharge in the tickets):**
1. **RESOLVED 2026-06-18 (CTR-04, below).** `closeLine` reclaimed only the SUPPLY queue; the **binding
   withdraw-queue slot was never freed** (`EulerVenueAdapter.sol:415-423`) → a pool bricked after ~28 *lifetime*
   opens. CTR-04 added the inline withdraw-queue reclaim (`submitCap(0)` + `updateWithdrawQueue`); a pool now churns
   28 *concurrent* lines. Removal of the (defunded) empty market is timelock-independent, so no `submitMarketRemoval`/
   reap step was needed — the `EulerEarn.sol:362` two-step path is dead code for an empty market.
2. The **0.1%-per-revolution fee is unimplemented** on-chain (grep `contracts/src`: only EE yield fee, buy-burn
   discount, oracle bands). **→ CTR-09.**
3. **RESOLVED 2026-06-19 (CTR-07, below).** Slot-2 revolving was half-wired: the reservoir borrow/repay cycled, but
   no `reallocate` funded it from resting or re-absorbed after repay. CTR-07 added `fundReservoir`/`defundReservoir`
   (`onlyReservoirAllocator`) — the per-line `fund`/`closeLine` reallocate pattern generalized to the reservoir.
4. Reservoir borrow is pinned to `engineSafe` (`ReservoirBorrowGuard.sol:91-92`) + capped (`borrowCap`, Timelock)
   — not externally exploitable; residual is internal contention vs senior redemption liquidity (informs CTR-07).
5. Structure-1's per-lien oracle is an n→∞ keyed cache; structure-2 keys the line to a borrower → one persistent
   key (`ZipcodeOracleRegistry` hosts both meanings unchanged). **→ CTR-08.**

**Cross-ticket obligations:** CTR-03 depends on CTR-02; CTR-05 on CTR-02; CTR-06 on CTR-02/03/05 (+CTR-07 wiring);
CTR-08/09 compose with CTR-03/07; CTR-10 on CTR-02..09. **Deploy-wiring:** every silo's
`WarehouseAdminModule.repaySink` → the ONE shared `ZipRedemptionQueue` (fungible senior; redemption drains any
warehouse). **§11 non-commingling assert** at silo deploy (`repaySink != juniorSafe`, `warehouseSafe != juniorSafe`).

**Ledger (build order):**
- **CTR-02** `SiloRegistry` — silo set + admission gate + slot accounting. **DONE 2026-06-18** (below). *(leaf)*
- **CTR-03** `ZipcodeController` siloId routing over the registry. **DONE 2026-06-18** (below). *(dep CTR-02)*
- **CTR-04** `closeLine` withdraw-queue reclaim (finding 1). **DONE 2026-06-18** (below). *(independent; paired with
  CTR-03's decrement — the binding withdraw-queue slot is now physically freed on close, so the registry counter and
  the actual queue length stay consistent; concurrent slot-accounting is now SOUND)*
- **CTR-05** `SeniorNavAggregator` (donation-immune Σ). **DONE 2026-06-18** (below). *(dep CTR-02)*
- **CTR-06** `SiloDeployer` — **RE-SCOPED 2026-06-18 into a 3-way split** (could not cold-build to zero guesses as one
  ticket; see the re-scope note in NEXT + the index `CTR-06-silo-deployer.md` with the pinned hub/silo decomposition +
  open decisions D1–D5). Children:
  - **CTR-06a** `ReservoirMarketDeployer` borrow-vault `setGovernorAdmin` fix (discharges FE-07 Finding A).
    **DONE 2026-06-19** (note below). *(was independent)*
  - **CTR-06b** `JuniorTrancheDeployer` (the missing reusable per-junior artifact, analogue of
    `CreditWarehouseDeployer`; excludes `OffRampModule` per D5). **DONE 2026-06-19** (note below; D1+D5 ratified). *(was dep CTR-06a)*
  - **CTR-06c** `SiloDeployer` orchestrator + feasible mock-EE two-silo routing test (D3/D4). **DONE 2026-06-19** (note
    below). *(dep CTR-06a + CTR-06b, both DONE)* — the re-scoped CTR-06 is now COMPLETE (06a+06b+06c all landed).
- **CTR-07** slot-2 reservoir fund/defund (finding 3; the split-slot decision). **DONE 2026-06-19** (note below).
  *(independent)*
- **CTR-08** structure-2 revolving credit-approval line (finding 5). *(dep 02/03; composes 07/09)*
- **CTR-09** 0.1%-per-revolution fee (finding 2). *(dep 03; composes 08)*
- **CTR-10** federation generalization — `ISeniorPool` + a non-Euler adapter. *(LATER / P5; dep 02..09)*

**Spec sync (forward, NOT a precondition):** each ticket is the complete, self-sufficient build instruction (it
cold-builds from the ticket alone). `build/claude-zipcode.md` is the intent reference; it gets a Conclude-step
doc-sync to *reflect* the federation / structure-2 / fee design once built (like the `wires/` sync) — nothing is
owed to the spec before CTR-02 can run.

> **CTR-07 — Slot-2 reservoir fund/defund: the revolving junior yield facility — DONE 2026-06-19.** Discharges
> **finding 3**. Modified `contracts/src/venue/EulerVenueAdapter.sol` + `contracts/test/ReservoirLoopModule.t.sol`
> (no new files → no `COVERAGE.md` row change, no regression on untouched contracts). Added two adapter-LOCAL methods
> `fundReservoir(uint256)` / `defundReservoir(uint256)` (`onlyReservoirAllocator`) — the per-line `fund`/`closeLine`
> reallocate pattern generalized to move idle USDC resting↔reservoir JIT, so the reservoir holds ≈0 at rest (split-slot
> decision). Each is a two-item absolute-target zero-sum `eulerEarn.reallocate` between `baseUsdcMarket` and a new
> `reservoirVault` slot, sized off `_eeSupplyAssets` (donation-immune, NOT `balanceOf`). Plus two Timelock-settable
> wiring slots `reservoirVault`+`reservoirAllocator` (`setX`+`WiringSet`), a `NotReservoirAllocator` error, and the
> `onlyReservoirAllocator` modifier. NOT on `IZipcodeVenue` (venue interface stays line-only). **Harness loop ran:** 4
> critics (junior-dev/spec-fidelity/reference-verifier/contract-binding). The contract-binding critic CONFIRMED **ZERO
> back-pressure** — the mechanism binds entirely to surfaces that exist today: (a) the reservoir vault is already an
> enabled NON-supply-queue EE market (`DeployLocal.s.sol:140-141` acceptCap's it; supply queue = `[baseUsdcMarket]`
> only), so it is reallocate-eligible; (b) its hook is **OP_BORROW-only**, so EE's reallocate deposit/withdraw legs
> into it are un-hooked and don't trip `ReservoirBorrowGuard` (the critical check — fundReservoir does NOT brick); (c)
> withdraw-while-lent-out reverts `E_InsufficientCash` (JIT discipline is EVK-enforced, not assumed); (d)
> `previewRedeem` is flat under a zero-rate borrow so the round-trip sizing nets post-repay. spec-fidelity confirmed
> invention-free + §17-faithful (the "split slot 2" topology is a PROGRESS session decision, not spec text — its
> spec-doc-sync is forward-deferred per the §-sync note, NOT a precondition). All other critic findings were **ticket
> gaps** (test-fixture under-specification), ALL fixed in the ticket BEFORE cold-build: the EE side does not exist in
> the reservoir suite, so the ticket now pins the full port/merge (copy the faithful `MockEulerEarn` — which moves
> REAL USDC between real EVK vaults — from `EulerVenueAdapter.t.sol`; add the `IOZERC4626`/`{IEulerEarn,
> MarketAllocation}`/adapter imports; build the base resting market + `_fundBaseMarket`; enable the reservoir at ZERO
> balance via `submitCap`+`acceptCap`; wire a real adapter with placeholder line-side ctor args; read tracked balances
> via the mock's public `expectedSupplyAssets`; name `E_InsufficientCash` + `NotReservoirAllocator` revert selectors;
> pin the donation = mint-shares-then-raw-transfer). **Two-key separation** is a documented DEPLOY invariant
> (`reservoirAllocator` ≠ `ReservoirLoopModule.operator`) — the adapter holds no loop-module handle, so the on-chain
> proof is the operator key reverting `NotReservoirAllocator` (no fabricated cross-contract coupling). Test home =
> `ReservoirLoopModule.t.sol` (it already stands up the live reservoir borrow leg), reusing
> `test_full_loop_revolves_twice`'s fixture. Gate green (verified by my own re-run, not just the cold-build's): `forge
> build` exit 0 + `forge test --match-path test/ReservoirLoopModule.t.sol` = **40 passed / 0 failed** (35 pre-existing
> all still green + 5 new: roundtrip-restores-resting, defund-reverts-when-lent-out, operator-cannot-fund,
> donation-noop-on-sizing, reservoir-zero-at-rest). Cold-build returned ZERO load-bearing guesses (only test-fixture
> sizing choices — X=$100/strike=$50 matching the existing fork fixture's scale — and a faithful tuple-read idiom).
> Ticket: `build/tickets/contracts/CTR-07-slot2-reservoir-fund-defund.md`. **Doc-sync:** modified contract → backward
> wire `docs/wires/WOOF-04.md` (new "reservoir fund-defund" method entry + the OP_BORROW-only load-bearing invariant +
> the adapter↔reservoir-loop two-key cross-component row + the allocator-role note now covers reallocate-for-reservoir
> + the CTR-07 gotchas test note). No `claude-zipcode.md` edit (the federation/split-slot-2 §-sync is forward-deferred,
> per the federation-section §-sync note; CTR-07 invents no mechanism — it generalizes the existing reallocate one).
> **Unblocks CTR-08** (structure-2 revolving lines reuse this reallocate-funded-revolving pattern).
> **Follow-up (reviewer-requested, same day):** the OP_BORROW-only hook invariant is now **fail-fast ENFORCED** —
> `setReservoirVault` reverts `ReservoirHookBlocksReallocate` if the wired vault hooks any reallocate leg
> (`hookedOps & (OP_DEPOSIT|OP_MINT|OP_WITHDRAW|OP_REDEEM) != 0`), so a mis-hooked vault can't be wired in (a fresh
> negative test `test_ctr07_setReservoirVault_rejects_reallocate_blocking_hook` simulates the governor widening the
> mask). Gate re-run: **41 passed / 0 failed**. The only residual (a Timelock re-hooking an already-wired vault) stays
> a documented §17 governed invariant — outside the adapter's reach. WOOF-04 + the ticket Do-NOT updated to match.

> **CTR-06c — `SiloDeployer` (the silo orchestrator) — DONE 2026-06-19.** Third + FINAL built child of the re-scoped
> CTR-06; the re-scoped CTR-06 is now COMPLETE (06a+06b+06c). Added `contracts/script/SiloDeployer.s.sol` +
> `contracts/test/SiloDeployer.t.sol` (NEW files only — no existing contract changed, so no regression possible).
> `deploy(SiloParams)` composes the four sub-deployers + the per-silo venue front into ONE complete silo and returns
> the `Silo` handle the Timelock registers via `addSilo`: (0) precompute the junior `mainSafe`; (1) EE pool via a
> `virtual _createEePool` (live-factory `.call`; mock in the test); (2) resting `baseUsdcMarket` (bare EVK proxy);
> (3) `ReservoirMarketDeployer` (CTR-06a); (4) EE admin config via low-level `_eeCall`; (5) per-silo `CREGatingHook` +
> `EulerVenueAdapter`; (6) `CreditWarehouseDeployer` (repaySink = the SHARED queue); (7) `JuniorTrancheDeployer`
> (CTR-06b); (8) fail-closed post-asserts; (9) return. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/
> reference-verifier/contract-binding) CONVERGED on ~9 load-bearing gaps in the first draft, ALL in-tree fixable (ZERO
> back-pressure), fixed in the ticket BEFORE cold-build: (1) the **reservoir↔junior circular dependency** — the reservoir
> `engineSafe` must be the junior `mainSafe`, but `JuniorTrancheDeployer.deploy` self-summons its Baal internally AND
> consumes the reservoir vaults as inputs; resolved by precomputing `jr.computeMainSafe(p.saltNonce)` (verified
> saltNonce-only, caller-independent — `SummonSubstrate.s.sol:110-118`; CTR-06b's `MainSafeMismatch` guarantees the
> precompute == the eventual summon), NOT the draft's infeasible "two-phase junior build"; (2) **`CREGatingHook` is
> PER-SILO, not shared** — its `borrowDriver` is a single settable address gating one adapter (`:35,94,110-113`), so the
> CTR-06 index's "shared hub infra" classification was wrong and is corrected (the deployer builds a fresh hook per
> silo); (3) the **combined test mock** — NEITHER existing `MockEulerEarn` had both the EE-admin surface AND the
> donation-immune NAV reads (`convertToAssets`/`balanceOf`/`maxWithdraw`) the aggregator needs, so the test defines a
> small combined mock (de-scoping D4 to no-opens makes the rich queue mock unnecessary); (4) the full **`SiloParams`
> struct** specified; (5) `lpOracle` is a built-and-SEEDED INPUT (the LP_MARK is a CRE/forwarder push the deployer
> can't make, and `setLTV`'s `getQuote` needs it); (6) `baseUsdcMarket` is CREATED by the deployer; (7) the
> `SzipPerspectiveProbe` is EXCLUDED (mock-incompatible; fork-runbook advisory only); (8) `_createEePool` arity pinned;
> (9) **D4 de-scoped** — the controller routing/rollover is already exhaustively proven by `ZipcodeController.t.sol`
> (CTR-03), so CTR-06c proves it at the REGISTRY level (pranked `incrementLineCount` to the `MAX_LINES_PER_SILO=28` cap
> → `SiloFull` → `setCurrentSilo` rollover) + `SeniorNavAggregator.seniorBacking()` summing both warehouses, with NO
> real controller/opens (the stale "29th origination" off-by-one fixed — cap is 28). Gate green (verified by my own
> re-run, not just the cold-build's): `forge build` exit 0 + `forge test --match-path test/SiloDeployer.t.sol` = **5
> passed / 0 failed** — `test_deploy_silo_seams_hold`, `test_ownership_handoff` (hook→TL, junior OZ-ownables/8 modules→TL,
> reservoir borrow-vault governor→TL, warehouse Safe/Roles→godOwner + admin adapter→receiverAdmin, both Baal Safes→team
> & NOT the deployer), `test_addSilo_first_try` (a REAL `SiloRegistry.addSilo` from a pranked Timelock passes on the
> first try — non-vacuous, reverts `SiloMiswired` on any clause failure), `test_D4_two_silo_routing_rollover_and_aggregate`,
> `test_D2_runbook` (`setCapacity`/`addSilo`/`setCurrentSilo` via `vm.prank(timelock)`). Cold-build returned ZERO
> load-bearing mechanism guesses (only test-fixture value choices + ticket-sanctioned options). Ticket:
> `build/tickets/contracts/CTR-06c-silo-deployer-orchestrator.md`. **Doc-sync:** NEW script + test → new wire
> `docs/wires/CTR-06c-SiloDeployer.md` + `COVERAGE.md` rows (scripts 10→11, tests 33→34); CTR-06 index marked 06c DONE
> + the per-silo-hook correction. No existing contract changed → no backward wire edit owed. No `claude-zipcode.md`
> edit (the federation §-sync is forward, not a precondition; the deployer invents no mechanism — it composes the
> existing ones). **Discharges the PROGRESS "DEPLOY OBLIGATION (CTR-03)"** as the per-silo D2 runbook (the hub half —
> `setRegistry`/`setController` + silo #0 — is already done by CTR-03/`DeployZipcode`). **Unblocks horizontal scaling
> (N pools) + the federation migration path.**

> **CTR-06b — `JuniorTrancheDeployer` (the reusable per-junior tranche deployer) — DONE 2026-06-19.** Second built
> child of the re-scoped CTR-06; the missing per-silo analogue of `CreditWarehouseDeployer`. Added
> `contracts/script/JuniorTrancheDeployer.s.sol` + `contracts/test/JuniorTrancheDeployer.t.sol` (NEW files only — no
> existing contract changed, so no regression possible). `deploy(JuniorParams)` is a faithful EXTRACTION of
> `DeployZipcode`'s inline junior stack (phases P3/P6/P7/P8/P9, ~30 deployments + 15 seam asserts) into one callable,
> parameterized to point at THIS silo's `eePool`/`warehouseSafe`/reservoir handles + the SHARED hub `zipUSD`/
> `rateOracle`. Stands up: Baal two-Safe substrate + `SzipNavOracle` + `ExitGate`/`SzipUSD` + `ZipDepositModule` + the
> **8** yield/freeze/buy-burn engine modules + the loss side (`LienXAlphaEscrow`+`DefaultCoordinator`); reproduces every
> seam assert; hands OZ-ownable → Timelock, engine modules already Timelock-owned from setUp, BOTH Baal Safes → the
> persistent `team` (§4.5 two-tier model). **Reviewer ratified D1 + D5 (2026-06-19):** D1 = `polIchiVault`/`polGauge`
> are shared deploy INPUTS (one pool, per-silo staked position); D5 = EXCLUDES `OffRampModule` + `queue.setRedeem
> Controller` (8 modules not 9; senior off-ramp is hub-level). **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/
> reference-verifier/contract-binding) CONVERGED on the **owner/signer model** as the single most-blocking gap — the
> original draft said "the broadcaster MUST be `team`" while CTR-06c calls `new JuniorTrancheDeployer().deploy(...)`
> (mutually exclusive: a `new`'d contract's internal Safe-drives run with `msg.sender == the deployer instance`, never
> the broadcaster, so `_summon(team,…)` reverts on the sidecar owner-add). **Ticket fixed BEFORE cold-build** to the
> transient-owner pattern (self-summon `_summon(address(this),…)` à la `CreditWarehouseDeployer`; reimplement the 4
> `i.*`-bound helpers parameterized; step-17 `swapOwner` both Safes to the real `team`; Safes → `team` NOT Timelock —
> the preamble's "every owner to the Timelock" was wrong for the Safes). Plus: the full `JuniorParams` struct defined,
> the **NAV leg tokens made injectable params** (the freeze `setUp` reads `zipUSD/usdc/xAlpha/hydx/oHydx` live off the
> oracle; the fork fixture feeds mocks — verified directly against `DurationFreezeModule.t.sol:1286-1295`),
> `workflowAuthor`/`workflowId` added for the identity seal, `rateOracle` excluded from the handoff, `is SummonSubstrate`
> (→ `is Script`, `.s.sol`), and the `setLpTwapWindow`/CREATE2/non-commingling minor flags. Gate green (verified by my
> own re-run, not just the cold-build's): `forge build` exit 0 + `forge test --match-path test/JuniorTrancheDeployer.t.sol`
> = **4 passed / 0 failed** — `test_deploy_seams_hold`, `test_ownership_handoff` (OZ→Timelock, 8 modules→Timelock, both
> Safes→team & NOT the deployer, rate-oracle wired-not-owned), `test_addSilo_topology_clauses_1_to_5` (a REAL
> `SiloRegistry.addSilo` from a pranked Timelock — reverts `SiloMiswired` on any clause failure; non-vacuous), and
> `test_non_commingling`; the reservoir leg is built via the REAL `ReservoirMarketDeployer` over the live EVK + a mock
> LP. Cold-build returned ZERO load-bearing guesses. Ticket: `build/tickets/contracts/CTR-06b-junior-tranche-deployer.md`.
> **Doc-sync:** NEW script → new wire `docs/wires/CTR-06b-JuniorTrancheDeployer.md` + `COVERAGE.md` rows (scripts 9→10,
> tests 32→33). No existing contract changed → no backward wire edit owed. No `claude-zipcode.md` edit (the federation
> §-sync is forward, not a precondition; the deployer invents no mechanism — it extracts `DeployZipcode`'s existing one).
> **Unblocks CTR-06c** (the `SiloDeployer` orchestrator calls this once per silo).

> **CTR-06a — `ReservoirMarketDeployer` hands the borrow-vault governor to the Timelock — DONE 2026-06-19.** First
> child of the re-scoped CTR-06; discharges **FE-07 Finding A**. One-line source fix + one post-assert (no new files).
> `ReservoirMarketDeployer.deploy` (`contracts/script/ReservoirMarketDeployer.sol`) handed ONLY the **router**
> governance to `p.governor` (`:88`); the USDC **borrow vault** is created via `factory.createProxy(address(0), …)`
> (`:77`) so its `governorAdmin` defaulted to the throwaway deployer INSTANCE and was never re-pointed — directly
> contradicting the contract header (`:13-14`) + `:75` ("Governor RETAINED … the Timelock can tune LTV/caps") and §17.
> Added `IEVault(borrowVault).setGovernorAdmin(p.governor)` as step 6, alongside the router transfer — AFTER all
> governor-gated config (`setInterestRateModel`/`setHookConfig`/`setLTV`), so the deployer can still configure first.
> Escrow renounce (`:61`, intentional holding box) + router transfer untouched. **Binding verified, not cited blind:**
> `IEVault.setGovernorAdmin(address)` @ `reference/euler-vault-kit/src/EVault/IEVault.sol:481`, `governorAdmin()` @
> `:370` — both real. Test home = the existing fork section `test_deployer_governor_RETAINED`
> (`test/ReservoirLoopModule.t.sol`), next to the router-retained + escrow-renounced asserts: added
> `assertEq(IEVault(bv).governorAdmin(), owner, "borrow vault governor RETAINED")`. **Proven load-bearing** — reverting
> the source line fails the assert (`governorAdmin()` = the deployer instance `0x5991…` ≠ owner `0xf744…`), confirming
> it tests the EFFECT not "didn't revert". Gate green: `forge build` exit 0 + `forge test` on the two deployer-touching
> suites = `ReservoirLoopModule.t.sol` **35 passed / 0 failed** + `AlgebraIchiFairLpOracle.t.sol` **5 passed / 0
> failed**; no pre-existing test regressed (escrow `governorAdmin()==address(0)` still holds). Cold-build returned ZERO
> load-bearing guesses (the ticket was already 4-critic-vetted in the CTR-06 split; binding + seam re-verified against
> live source this window). Ticket: `build/tickets/contracts/CTR-06a-reservoir-governoradmin-fix.md`. **Doc-sync:**
> modified script contract → backward wire `docs/wires/8-B5-ReservoirLoop.md` step-5 sequence rewritten to enumerate
> the borrow-vault `setGovernorAdmin` handoff (the prose claim at `:25`/`:150` was already "retained on both" — the
> SEQUENCE list was the stale part). No new contract/test file → no `COVERAGE.md` row change. No `claude-zipcode.md`
> edit (§17 already correct — the fix makes the code MATCH §17). **Live-fork caveat:** fixes future deploys only; the
> already-deployed anvil borrow vault keeps its stranded governor until a redeploy (FE-07 `entities.json` re-read note
> stands).

> **CTR-05 — `SeniorNavAggregator` (donation-immune Σ senior par-backing across silos) — DONE 2026-06-18.** Fourth
> contract of the scaling/federation workstream; the cross-silo solvency telemetry + circuit-breaker input. Added
> `contracts/src/SeniorNavAggregator.sol` + `contracts/test/SeniorNavAggregator.t.sol` (no existing contract changed).
> A pure OZ `Ownable` (Timelock) view that loops `SiloRegistry.allSiloIds()` and sums each silo's §8.2 donation-immune
> senior read (`convertToAssets(balanceOf(warehouseSafe)) * 1e12`, NEVER `balanceOf(eePool)`), replicating the
> `DurationFreezeModule:295-302` guards VERBATIM. Surface: `seniorBacking()` (Σ ALL silos), `activeSeniorBacking()`
> (active-only), `illiquidSeniorValue()` (Σ lent-out), `collateralization(supply)` (zero-supply→`type(uint256).max`),
> `systemCollateralization()` (wired zipUSD `totalSupply`), per-silo getters (unknown→0), Timelock `setRegistry`/
> `setZipUsd`+`WiringSet`. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/contract-
> binding) converged on THREE load-bearing fixes applied to the ticket BEFORE cold-build: (1) **the draft excluded
> inactive silos from the live backing sum — WRONG for the §12 solvency numerator.** `retireSilo` only stops new
> routing ("existing lines close normally"), so a retired silo still backs the zipUSD its open lines minted; zipUSD is
> fungible at the hub, so excluding it understates backing and could falsely trip a breaker during wind-down. Fixed:
> `seniorBacking()`/`illiquidSeniorValue()` sum ALL silos (drained ones self-zero via `balanceOf→0`); `active` filters
> ONLY the separate `activeSeniorBacking()`. (Ticket gap, not a spec change — §12 already says system-wide.) (2)
> **§12-NAV mislabel:** the Σ is senior **par** backing (idle + loan principal at par), NOT full §12 NAV (which marks
> impaired loans to recovery, net of the junior provision); they coincide only pre-impairment, impairment lands in the
> junior `SzipNavOracle` per §11. Reframed to "senior par-backing coverage" throughout — the correct senior-solvency
> signal. (3) **registry-read framing self-contradictory** (an inline iface naming `SiloRegistry.Silo` still needs the
> import) → `import {SiloRegistry}` outright; no struct-read precedent exists in CTR-03. Plus precision nail-downs:
> `WiringSet` slot labels `"registry"`/`"zipUsd"`, ctor accepts zero for both (deploy-order) with fail-closed
> `RegistryUnset`/`ZipUsdUnset` guards, per-silo getters return 0 on unknown/empty, zipUSD 18-dp VERIFIED
> (`DeployZipcode.s.sol:260` `new ESynth(...)`, no decimals override). **The test mock was the precision work:** the
> shared `test/mocks/MockEulerEarn.sol` has no `maxWithdraw` and can't model `free<sa` — used the settable-backing
> mock per `DurationFreezeModule.t.sol:107-130` (per-account `balanceOf`, settable `convertToAssets`/`maxWithdraw`, a
> `donateShares` path that does NOT move warehouse backing, mirroring the donation test at `:455-461`); `SiloRegistry`
> is the REAL contract with self-consistent topology stubs. Gate green: `forge build` exit 0 + `forge test
> --match-path test/SeniorNavAggregator.t.sol` = **18 passed / 0 failed** (N=1 identity, two-silo Σ, donation no-op,
> retired-still-counted-but-dropped-from-active, drained→0, illiquid verbatim-formula incl. `free>=sa`/`sa==0`→0,
> collateralization math + zero-supply→max, systemCollateralization wired vs `ZipUsdUnset`, per-silo getters +
> unknown→0, `RegistryUnset` on all aggregate reads, ctor-zero-both, setter owner-gating + zero-reject + `WiringSet`).
> Cold-build returned ZERO load-bearing guesses. Ticket: `build/tickets/contracts/CTR-05-senior-nav-aggregator.md`.
> **Doc-sync:** NEW contract → new wire `docs/wires/CTR-05-SeniorNavAggregator.md` + `COVERAGE.md` rows (38→39 product,
> +1 test → 32); CTR-02 wire's CTR-05 cross-ref marked BUILT. No `claude-zipcode.md` edit owed (§12 NAV semantics
> intact — CTR-05 is a senior-par-coverage telemetry view consistent with §11/§12, recorded in the wire).

> **CTR-04 — `closeLine` reclaims the binding withdraw-queue slot — DONE 2026-06-18.** Third contract of the
> scaling/federation workstream; discharges **finding 1**. Modified `contracts/src/venue/EulerVenueAdapter.sol`
> (`closeLine`) + `contracts/test/EulerVenueAdapter.t.sol` (no new files). `closeLine` previously pruned only the
> SUPPLY queue (SEC-06) and left the line's EE cap at `type(uint136).max`, so the **binding WITHDRAW-queue slot was
> never freed** — the hard `MAX_QUEUE_LENGTH=30` cap fires on the withdraw queue inside `_setCap` when `acceptCap`
> first enables a market (`EulerEarn.sol:783-785`), so a pool bricked after ~28 *lifetime* opens. Added, AFTER the
> existing defund + supply-prune, a single **inline** withdraw-queue reclaim: `submitCap(IOZERC4626(lineRef), 0)`
> (cap DECREASE applies immediately, no timelock, `:298-299`; removal guard `:362` requires `cap==0`) → build
> `keepIndexes` = every withdraw-queue index whose market `!= lineRef` (by address, two-pass, via
> `withdrawQueueLength()`/`withdrawQueue(i)`) → `updateWithdrawQueue(keepIndexes)`. **Harness loop ran:** 4 critics
> (junior-dev/spec-fidelity/reference-verifier/contract-binding) CONVERGED on ONE load-bearing design fix applied to
> the ticket BEFORE cold-build: the draft's two-path design (`submitMarketRemoval` + a deferred `reapLine` keeper
> step + an `eulerEarn.timelock()` branch for non-zero-timelock pools) is **dead code** — removal of an EMPTY market
> never engages the EE timelock, because `updateWithdrawQueue`'s `removableAt`/timelock guard (`:366-370`) sits
> inside `if (expectedSupplyAssets(id) != 0)` (`:365`) and `closeLine` mandatorily defunds the line to zero first
> (`previewRedeem(0)==0`, `expectedSupplyAssets == _eeSupplyAssets`). So removal is inline + timelock-independent for
> ANY pool (even if the external EE owner raised the timelock mid-life), and `submitMarketRemoval` is never needed.
> Cut the two-path → single inline path. Also resolved the ticket's open hedges: `withdrawQueueLength()` confirmed to
> exist (`:482`); `IOZERC4626` is the adapter's OZ-`IERC4626` alias (`:13`); `submitCap(0)` is always a valid
> `max→0` (the EE config cap is invariably max from openLine — `setLineLimits` touches only the EVK vault's own caps);
> CTR-04 adds NO registry call (`decrementLineCount` lives in the CONTROLLER, CTR-03 — CTR-04 makes the *physical*
> slot reclaim match the existing counter decrement). **The real test work was extending `MockEulerEarn`** (it
> modeled only the supply queue + hardcoded `cap=max`): added per-market cap tracking, a `_withdrawQueue` pushed on
> first market-enable enforcing the `:785` cap, `withdrawQueue`/`withdrawQueueLength` getters, and a faithful
> `updateWithdrawQueue` with the `:362-371` removal guards. Gate green: `forge build` exit 0 + `forge test
> --match-path test/EulerVenueAdapter.t.sol` = **39 passed / 0 failed** (33 pre-existing incl. SEC-06/07/08/11 all
> still green + 6 new CTR-04: reclaims-slot, removed-market-cap-zero-and-empty, leaves-other-slots,
> brick-without-close (31st open reverts `MaxQueueLengthExceeded`), no-brick-across-churn-past-cap, concurrent-reuse
> (fill→close→fresh-open-succeeds)). Cold-build returned ZERO load-bearing guesses. Ticket:
> `build/tickets/contracts/CTR-04-closeline-withdrawqueue-reclaim.md`. **Doc-sync:** modified contract → backward wire
> `docs/wires/WOOF-04.md` updated (`closeLine` now reclaims BOTH queues; the allocator-role note gains
> `updateWithdrawQueue`; the `MockEulerEarn` note records the withdraw-queue extension). No new contract → no
> `COVERAGE.md` row change. No `claude-zipcode.md` edit (§4.7/§4.5 already correct).

> **CTR-03 — `ZipcodeController` siloId routing over the registry — DONE 2026-06-18.** Second contract of the
> scaling/federation workstream; makes the controller multi-pool. Modified `contracts/src/ZipcodeController.sol` +
> `contracts/test/ZipcodeController.t.sol` (no new files). The report paths now resolve `venue` per origination
> from `SiloRegistry.venueOf(siloId)` (CTR-02) instead of the single `venue` pointer: added a `registry` wiring
> slot (NOT in ctor — `setRegistry`, `WiringSet`, §17), an inline `ISiloRegistry` 3-method interface, errors
> `RegistryUnset`/`SiloUnrouted`, a private `_venueFor(siloId)` fail-closed resolver, `LienRecord.siloId`
> (appended), a trailing `siloId` on `LienOriginated` + the RT_ORIGINATION payload, and the
> `incrementLineCount`/`decrementLineCount` slot hooks (each the FINAL statement of origination/close → a
> `SiloFull` revert rolls the whole atomic origination back; F-10 preserved — trusted no-callback registry).
> Draw/close **re-resolve from the stored `r.siloId`** (never `currentSilo`), so a re-pointed/retired silo can't
> strand an open line. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/contract-
> binding) converged on ONE load-bearing design fix applied to the ticket BEFORE cold-build: the draft's
> dual-mode `venue` fallback (route via `venue` when `registry==0`) is a silent line-bricking hazard (a line
> opened pre-registry becomes un-closeable post-registry) → **registry made MANDATORY** for report paths
> (`RegistryUnset` fail-closed; no fallback), with `venue`/`setVenue`/ctor RETAINED only for deploy-cycle compat.
> Plus precision fixes: `siloId` appended LAST (matches the lienId-first §8.0 convention) not first; explicit
> inline `ISiloRegistry`; `registry.setController(controller)` made a Key requirement + deploy obligation; N=1
> identity defined concretely (the full pre-existing suite routed through a registered `SILO_0 → adapter`); the
> CTR-04 lifetime-vs-concurrent caveat carried into the NatSpec + wire. One agent misread filtered (a critic cited
> the test's `registry.setController` at `:236` as a SiloRegistry wire — verified it's the `ZipcodeOracleRegistry`;
> there was no SiloRegistry in the test). Gate green: `forge build` exit 0 + `forge test --match-path
> test/ZipcodeController.t.sol` = **34 passed / 0 failed** (26 pre-existing routed through the registry = the N=1
> identity proof, + 8 new: routes-to-named-venue, draw/close re-resolve, closes-after-retire, count
> increment/decrement, SiloFull-rolls-back-no-orphan, unknown-silo→SiloUnrouted, registry-0→RegistryUnset, and a
> real-`SiloRegistry` integration test with self-consistent topology stubs). Cold-build returned ZERO load-bearing
> guesses. Ticket: `build/tickets/contracts/CTR-03-controller-silo-routing.md`. **Doc-sync:** modified contract →
> backward wire `docs/wires/WOOF-05.md` updated (registry slot, `_venueFor`, the origination step-0/step-9 hooks,
> draw/close re-resolve, gotchas, cross-component pin, CTR-04 caveat); forward spec `claude-zipcode.md` §8.0
> RT_ORIGINATION row gains trailing `siloId` + a routing note. No new contract → no `COVERAGE.md` row change.
> **Deploy obligation logged** under Open obligations (setRegistry/setController wiring + assert).

> **CTR-02 — `SiloRegistry` (multi-pool/federation silo catalog + admission gate) — DONE 2026-06-18.** First
> contract of the scaling/federation workstream. Added `contracts/src/SiloRegistry.sol` + `contracts/test/
> SiloRegistry.t.sol`. A plain OZ `Ownable` (v5, Timelock owner — NOT a Zodiac module/EVK hook) catalog of silos
> `{adapter, warehouseSafe, eePool, juniorBasket, escrow, defaultCoordinator, navOracle, freeze, curator,
> lineCount, active}` keyed by a caller-chosen `bytes32 siloId`: `addSilo` (onlyOwner admission + a load-bearing
> **6-clause topology assert** that the silo points only at its OWN components — `freeze.{eulerEarn==eePool,
> warehouse==warehouseSafe, navOracle==navOracle}`, `escrow.coordinator()==defaultCoordinator`,
> `defaultCoordinator.navOracle()==navOracle`, `adapter.eulerEarn()==eePool`), `retireSilo`/`setActive`/
> `setCurrentSilo` (governed lifecycle; retire keeps the record), `incrementLineCount`/`decrementLineCount`
> (`onlyController`, cap `MAX_LINES_PER_SILO = 28 = 30−2`), views (`venueOf`→adapter, `getSilo`, `allSiloIds`,
> `siloCount`), Timelock-settable `controller` (`setController`+`WiringSet`). **Harness loop ran:** 4 critics
> (junior-dev/spec-fidelity/reference-verifier/contract-binding) converged on TWO load-bearing findings, both fixed
> in the ticket BEFORE cold-build: (1) the draft `Silo` struct lacked `defaultCoordinator` + `freeze` fields the
> topology assert dereferences → added both, dropped the redundant `WarehouseAdminModule` assert; (2) `lineCount`
> is concurrent but the EE cap is LIFETIME until CTR-04 (closeLine doesn't free the withdraw-queue slot) →
> documented as a cross-ticket capacity dependency (CTR-02 builds standalone but concurrency is sound only once
> CTR-03+CTR-04 land). Plus: caller can't seed `lineCount`/`active` (admission takes a `SiloConfig` addresses-only
> view); `bytes32(0)` reserved as the `currentSilo` sentinel; `venueOf` returns the adapter. Gate green: `forge
> build` exit 0 + `forge test --match-path test/SiloRegistry.t.sol` = **28 passed / 0 failed** (happy-path, zero-id,
> dup, per-field zero-address, ≥2 broken topology clauses, increment-to-cap→SiloFull, decrement + zero-guard,
> onlyController/onlyOwner gating, retire-stops-routing-keeps-record). Cold-build returned only non-load-bearing
> defensive choices (constructor accepts zero `controller_` per deploy-later order, `UnknownSilo` guard,
> `adapter!=0` existence sentinel). Ticket: `build/tickets/contracts/CTR-02-silo-registry.md`. **Doc-sync:** NEW
> contract → new wire `docs/wires/CTR-02-SiloRegistry.md` + `docs/wires/COVERAGE.md` rows (37→38 product, +test).
> No existing contract changed → no backward wire edit owed. No `claude-zipcode.md` edit (federation § is forward
> doc-sync, not a precondition). NOTE on git: a mid-session commit `0350d5a` (author rootdraws) checkpointed the
> pre-existing dirty tree (the CTR-02..12 *draft* tickets + earlier doc edits) — it does NOT contain this window's
> work; CTR-02's built code + rewritten ticket + this sync are the new commit.

> **KEEPER-01a — buy-burn fill-detect → `burnFor` job — DONE 2026-06-17.** The first live (K) write job + the burn
> half of the hybrid buy-burn cycle (`CRE-OPS-ROUTING.md`): a CoW fill lands szipUSD in the engine Safe; `BurnJob`
> retires it via `ExitGate.burnFor(amount)` (`onlyWindowController` = the keeper key). Added to `cre/keeper/`:
> `internal/job/burn_job.go` (`BurnJob`: reads `shareToken()`/`engineSafe()`/`balanceOf` off the Gate each tick
> §17-re-pointable, burns the **full** engine-Safe balance — `Loot(gate) ≥ that` always, the soulbound-Loot
> invariant — above a config `MinBurnAmount` floor; no-op on zero/below-floor/unwired) · `internal/chain/encode.go`
> (`PackUintCall` for one-uint256 write calldata) · `MinBurnAmount` config (env-only `*big.Int`; explicit 0 valid) ·
> `main.go` registers it after the IdentityJob. **No coverage/freshness gate by design** — `SzipNavOracle.
> _effectiveSupply()` excludes the engine Safe's pre-burn szipUSD (`:608-613`, denominator at `:474`), so a lagging
> burn can't move NAV (housekeeping). **No double-burn** because the spine's `Submit` is synchronous on a
> single-threaded Runner (recorded as load-bearing in a code comment). Gate green: `go vet`/`go build` exit 0
> (native) + `go test ./...` green (stub-Reader unit suite with the EXACT `0x6f5d0f0b ++ uint256` calldata
> assertion + no-op/floor/unwired/error branches; simulated-backend end-to-end via `ExitGateBurnProbe`) + all
> KEEPER-00 tests still pass, clean under `-race`. Zero load-bearing guesses. Ticket:
> `build/tickets/cre/KEEPER-01a-burn-job.md`. No contract changed → no `wires/` sync owed.

> **KEEPER-00 — the CRE keeper-service scaffold — DONE 2026-06-16.** The foundation for the entire **(K)** surface
> (the §8.7 operator path's off-chain embodiment; NOT wasip1, imports no `cre-sdk-go`). Built `cre/keeper/` (Go +
> go-ethereum v1.17.2): config (env+JSON, defaults-before-validate, re-pointable address book §17) · keymgr
> (operator hot key, env-hex primary / geth-keystore secondary; key NEVER logged/in-errors/in-Config) · the
> `chain` client (a minimal `Backend`/`Reader` iface both `*ethclient.Client` AND `simulated.Client` satisfy; view
> read-helpers `CallUint/Bool/Address`; a **nonce-safe** EIP-1559 `Submit` — local mutex-guarded nonce, advances
> ONLY after a successful send, `EstimateGas` doubles as a dry-run that aborts without advancing) · the
> read→compute→submit **`Job` spine** (`Evaluate→chain.Plan`, a `Runner` that ResyncNonce→submits each plan
> **ordered + abort-on-first-error**, fail-safe between jobs, graceful SIGINT/SIGTERM — liveness-only failure per
> `CRE-OPS-ROUTING.md`) · one reference read-only **IdentityJob** asserting the §8.7 invariant `operator()==key &&
> owner()!=key` (the copy-template KEEPER-01 clones; startup fail-fast + heartbeat). Gate green:
> `go vet ./... && go build ./...` exit 0 (native, NOT wasip1) + `go test ./...` green across chain/config/job/keymgr
> (submit-spine incl. nonce-gap regression; default-before-validate; abort-on-first-error; IdentityJob incl. the
> `operator!=owner` branch via a stub Reader), also clean under `-race`. Zero load-bearing guesses. Ticket:
> `build/tickets/cre/KEEPER-00-keeper-scaffold.md`. No contract changed → no `wires/` sync owed (off-chain code;
> truth = ticket + code + commit). **Forward notes recorded for KEEPER-01** in the ticket: fill-detect is a
> balance-poll (no on-chain fill event); harvest legs are discrete txs (no multicall) → ordered `chain.Plan`; the
> `abi.Pack` native-int quirk bites scalar args.

> **M1 DECISION (2026-06-16): the 8-B14 buy-order bid is HUMAN/MANUAL at launch.** A person posts/cancels it via
> the operator-key door, reading the FE-08 exit-book dashboard; the CRE-05a robot is **built-but-parked** until
> there's real exit data to tune the bid's `d`/size rules (flip-on = wire Forwarder + workflow-id, then run). No
> rework — CTR-01's two-door design already supports manual. The yield engine (8-B5…8-B10) stays robot-run.
> See `build/tickets/cre/CRE-OPS-ROUTING.md` (M1 operating note).

> **FE-08 — szipUSD NAV exit-book page — DONE 2026-06-16.** Built in the LAYER (`frontend/zipcode-finance-euler`,
> commit `a592135` on `resi-labs-ai`): `pages/lender/szip-exit-book.vue` + `composables/{useNavExitBook,
> useCowOrderbook}.ts` + `components/zipcode/{ZcNavExitBookChart,ZcLiquidityGauge}.vue`. The two-sided depth chart
> (x = % of NAV, y = cumulative USDC): NAV line @100% + the protocol buy-burn bid block @ `navExit×(1−d)` sized to
> the live `currentBid().sellAmount` (the CRE-05a loop) + the external CoW book fanned below; a liquidity gauge
> (free reservoir = `eePool.maxWithdraw(warehouseSafe)`, `U` the donation-immune §8.2 way); a "Sell to floor" CTA
> that opens the unmodified FE-04 `ZcWithdrawModal` (no new exit logic). Reads all exist (no back-pressure); the
> registry already had `eePool`/`warehouseSafe`. Gate green: `npm run build` (nuxt) clean + `node
> .output/server/index.mjs` → `/lender/szip-exit-book` returns 200 (external book empty on the fork, renders fine).
> Ticket: `build/tickets/frontend/FE-08-nav-exit-book.md`.

> **CRE-05a — buy-burn bid-loop wasip1 workflow — DONE 2026-06-16.** The exit half of CRE-05 (§8.7), unblocked by
> CTR-01. Built `cre/buyburn-bid/` (the first buildable CRE workflow — also the minimal CRE scaffold): a
> `cre-sdk-go` workflow that maintains the single resting buy-burn bid via the report path. Reads
> `currentBid`/`quoteMaxPrice`/`buybackCap`/`fresh`/`maxAge`/`oldestRequiredLegTs`/`covered` + the donation-immune
> §8.2 free-reservoir read (`EulerEarn.maxWithdraw(warehouse)`); sizes `clamp(freeReservoir − harvestReserve −
> safetyBuffer, 0, buybackCap)` @ `quoteMaxPrice` (= `navExit×(1−d)`); reconciles one bid (post / cancel+repost on
> size-drift ≥ driftBps / cancel) via `WriteReport(POST_BID|CANCEL_BID)` to the socketed module; cron + a
> `RedemptionSettled` LogTrigger. Gate green: `GOOS=wasip1 GOARCH=wasm go build` exit 0 + `go test` 14 pass
> (encode round-trip byte-matching `_processReport`, 7 simulated-run scenarios, sizing units). Ticket:
> `build/tickets/cre/CRE-05a-buyburn-bid-loop.md`.

> **CTR-01 — Clone-compatible CRE report socket on SzipBuyBurnModule — DONE 2026-06-16.** Resolved the
> operator-path-has-no-CRE-write seam for 8-B14: added the reusable `CloneReportReceiver` base
> (`contracts/src/supply/szipUSD/CloneReportReceiver.sol`) + expanded `SzipBuyBurnModule` to be ALSO
> report-drivable (two doors — operator key + DON report — one guard set, fail-closed on an unset forwarder).
> Gate green: `forge test --match-path test/SzipBuyBurnModule.t.sol` = 50 passed / 0 failed (44 pre-existing +
> 6 new report-path cases). Ticket: `build/tickets/contracts/CTR-01-clone-report-receiver-buyburn.md`. Truth:
> `build/wires/8-B14-SzipBuyBurnModule.md` + `COVERAGE.md`; spec exception recorded in `claude-zipcode.md`
> §8.7 + §8.0 table.

> **The SEC track is COMPLETE** — all 16 internal-audit remediation items (15 FIX + the DOC sweep) landed; the
> deliberate non-fixes are recorded under Open obligations below. See the SEC track section below.
>
> **The Frontend ↔ anvil track is COMPLETE** (FE-00…FE-07, 2026-06-10/11). The **CRE track** (CRE-00…CRE-06) is the
> next workstream; its head is CRE-00 (scope retained in the Backlog table below).

---

## SEC track — internal-audit remediation (auditor-prep) — COMPLETE

**All SEC remediation DONE** (15 FIX + the DOC sweep; 2026-06-15/16). Every fix is in the committed, fork-tested
code (`forge test` green) and truth-sourced in `build/wires/` (index `build/wires/COVERAGE.md`) — **that, plus the
git commit history, is now the durable record.** The internal-audit scratch (the `audit-claude/` findings, the
consolidated `kill-list.md`, the per-item SEC tickets + reports) has been pruned — it was Claude-run self-audit
bookkeeping, not an external-auditor deliverable, and its actionable conclusions all landed in code + wires. The
conceptual findings that weren't obvious from code live in the wires (e.g. the "perspective is provenance-only"
finding in `wires/WOOF-04.md`). The deliberate **non-fixes** that remain forward-relevant are recorded under Open
obligations (the `setBaal` managerLock caveat; the abandoned draw-time coverage gate); the pure "verified-not-real"
dismissals (the old H3/L5/L10/M5) needed no code and are recoverable from git if a professional auditor re-raises them.

---

## Backlog

### CRE — two build shapes (routing decided 2026-06-16, `build/tickets/cre/CRE-OPS-ROUTING.md`)
**(R) wasip1 workflows** (report path → existing receivers): CRE-00/01/03/04 + CRE-05a (done).
**(K) the CRE keeper service** (off-chain Go + go-ethereum, hot keys, NOT wasip1): KEEPER-00/01 + the CRE-02 operator half.
Numbering otherwise follows the spec's own CRE map (`claude-zipcode.md` §8.11) — the spec rules intent.

| Item | What | Shape |
|---|---|---|
| KEEPER-00 | **DONE 2026-06-16** — CRE keeper-service scaffold (`cre/keeper/`; Go + go-ethereum; key mgmt; nonce-safe read→compute→submit spine + chain-read helpers + the `Job`/`Runner` seam + the IdentityJob template; config). Foundation for every (K) item. NOT wasip1. | (K) |
| KEEPER-01a | **DONE 2026-06-17** — buy-burn fill-detect→`burnFor` (windowController). The first live (K) write `Job` on the spine (`cre/keeper/internal/job/burn_job.go`). | (K) |
| KEEPER-01b | Engine harvest-loop orchestrator (8-B5…8-B10 `onlyOperator` legs; regime/split/cap policy), as `Job`s on the `cre/keeper/` spine. = the bulk of the rest of CRE-05. **POLICY-BLOCKED** — undecided execution floors / regime+state / vote / sizing; agenda = `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md`. Strike-loop core slice unblocks once A1–A4 + C4 ratified. | (K) |
| KEEPER-01c | Freeze-`commit`-on-coverage-shortfall (the DORMANT lever, exception-only). **DEFERRED** — binds to the INCOMPLETE `DurationFreezeModule` (premise under review, Open obligations); lock with the freeze rebuild, not against an unsettled module. | (K) |

> **The szipUSD CoW-exit workstream is COMPLETE (2026-06-16): CTR-01 (report socket) + CRE-05a (bid-loop) +
> CRE-06 (folded-as-config) + FE-08 (exit-book page) landed; the `build/CoW.md` + `build/CoW-exit.md` drivers are
> deleted.** Durable record = the built code + `build/wires/` + this file.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — *(was NEXT; deferred behind the FE↔anvil push the user prioritized 2026-06-10 — head of the CRE track when released)* |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family). **SEC-01 constraint: must not co-locate two same-lien `seedPrice` writes (origination+draw / draw+draw) in one block — the registry monotonic guard reverts the second. See open obligations.** | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call. *(2026-06-12: `settleEpoch` is now ON-DEMAND — the 30-day epoch gate was removed — so this can be event-driven off the queue's `RedemptionSettled` event rather than a fixed cron: settle → if backlog remains, sequence another REDEEM→REPAY. See `build/wires/9-ZipRedemptionQueue.md`.)* **Scope: `build/tickets/cre/CRE-02-redemption-settle.md`.** | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipReservoirLpOracle` — and the xALPHA-APR feed (the 8x-02 receiver is built; the Go producer remains) | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔sidecar rotation; regime/split/cap policy). **SPLIT — exit half = CRE-05a (DONE); harvest + rotation remainder = KEEPER-01b (POLICY-BLOCKED) + KEEPER-01c (DEFERRED). CRE-05 is NOT complete; there is no CRE-05b/05c — the remainder lives under the KEEPER prefix.** *(2026-06-12 design inputs: (a) the DurationFreeze main↔sidecar rotation needs an LP **unstake→commit** sequence — the freeze can't move staked LP; see the `TODO(freeze-lp)` in `DurationFreezeModule.sol` + `build/wires/DurationFreezeModule.md`; (b) the 8-B14 CoW **buy-burn bid-automation loop** — size the resting bid to `clamp(freeReservoir − harvestReserve, 0, buybackCap)`, repost on drift/`RedemptionSettled`/fill, optionally as **staggered clones** for laddered depth — the exit half SHIPPED as CRE-05a, `cre/buyburn-bid/`.)* **CLARIFICATION (2026-06-16): the freeze's physical lever (`commit`/`release`) is DORMANT by design.** `commit` is `onlyOperator` + discretionary (no auto-machinery), and the sidecar is empty in normal operation because the dominant asset (the staked ICHI LP) can't be moved into it — it is counted toward the floor IN PLACE via the oracle's `pathLockedLpEquity()` (`coverageValue = committedValue + pathLockedLpEquity`). So CRE-05 should drive `commit` ONLY on a coverage shortfall (a price-drift breach where in-place LP + sidecar < `requiredCommittedValue`), to top up with the movable plain legs (USDC/zipUSD preferred — stable backing). The live machinery is the **accounting + outflow gates** (`covered()` on `postBid`/`removeLiquidity`/`release`), not the physical rotation. | §8.7 |
| CRE-06 | **DISCHARGED-as-config by CRE-05a (2026-06-16).** The exit-vs-harvest split is now the `harvestReserve` + `safetyBuffer` Config params in the buy-burn bid sizing (`clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)`) — M1 constants; a dynamic utilization-aware policy is a later parameter swap, not a redesign. No standalone workflow. (Cross-cutting coupling now recorded in the CRE-05a ticket + `build/wires/DurationFreezeModule.md`.) | §8.5 / §8.7 |
| CRE-05a | **DONE 2026-06-16 — buy-burn bid-loop** (the exit half of CRE-05; `cre/buyburn-bid/`). The single-resting-bid automation via the CTR-01 report path. Gate green (wasip1 build + 14 tests). The REST of CRE-05 (the harvest engine legs 8-B5…8-B10 + main↔sidecar rotation) remains — tracked as KEEPER-01b (harvest orchestrator, POLICY-BLOCKED) + KEEPER-01c (freeze commit, DEFERRED); there is no CRE-05b/05c. | §8.7 |

### Frontend ↔ anvil (Vue/viem, in the `zipcode-finance-euler` LAYER over a read-only `euler-lite` base)
**Goal: make the team's skinned borrower/lender app interactive against the live local protocol — "fuck around
before mainnet."** The deploy-gating that blocked these is LIFTED: item-10 fork-executed the full stack on anvil, so
every "TODO post-deploy" slot is now fillable from `build/anvil/contract-map.md` (addresses) + `build/anvil/abi/`
(ABIs). The layer's `Zc*` screens are currently a **clickable mockup** fed by mock `lib/zipcode/store.ts` + simulated
Plaid — the work is to swap that data path for real reads/writes against the anvil contracts. Build one at a time,
foundation → leaf. Addresses below are the anvil board (`contract-map.md`); ABIs are `build/anvil/abi/<Name>.json`.

| Item | What | Binds to (anvil address + ABI) | Spec § |
|---|---|---|---|
| FE-00 | Boot the layer on anvil: populate the euler-lite base, `.env` repoint (`RPC_URL_8453`→`127.0.0.1:8545`, onchain vault source, local labels), wallet→8453 | euler-lite data layer (config-only) + `contract-map.md` | §5 — **DONE 2026-06-10** |
| FE-01 | Zipcode **address book + typed ABI module** in the layer (the shared dep every Zipcode composable imports; fills the INFLOW-06 "post-deploy slots" with real anvil addresses) | `abi/index.json` resolver + `contract-map.md` | §5 — **DONE 2026-06-10** |
| FE-02 | Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` (approve→`zap`/`deposit`, `previewZap`/`previewDeposit`); ship the shared **1.3× gas-buffer tx helper** (EVC headroom — see Open obligations) all writes reuse | `ZipDepositModule` `0x6ecc…` + `ESynth`(zipUSD) `0xC5bd…` + `SzipUSD` `0x33aD…` | §4.5 (= INFLOW-06, realized) — **DONE 2026-06-11** |
| FE-03 | Position / NAV view: szipUSD + zipUSD balances + **$ value via `navExit`** (held = redemption price; `navEntry` for the entry hint only, caught; NOT `navPerShare` — absent); the lender portfolio screen | `SzipNavOracle` `0x0C3E…` + `SzipUSD` `0x33aD…` + zipUSD `0xC5bd…` | §7 / §12 — **DONE 2026-06-10** |
| FE-04 | szipUSD junior exit via the **CoW book** (rest a sell order + the §6.4 status track); wire `ZcWithdrawModal` | `SzipBuyBurnModule` `0x1288…` (CoW wiring + treasury bid) + `SzipUSD` `0x33aD…` (`approve(vaultRelayer)`) + `SzipNavOracle` `0x0C3E…` | §6.2 / §6.4 — **DONE 2026-06-11** |
| FE-05 | Borrower flow: line state + permissionless repay; wire `ZcDrawModal` / `ZcRepayModal` (CRE drives origination per §17 — UI reads line state + repays) | `EulerVenueAdapter` `0x87dC…` + `ZipcodeController` `0x3602…` | §4 / §15 — **DONE 2026-06-11** |
| FE-06 | **Solvency dashboard** (§12 metrics — NAV, zipUSD supply + peg, szipUSD NAV/share + trailing APR, utilization / free liquidity, insurance coverage) via **direct on-chain view reads** (no subgraph for MVP); wire `ZcStatCard` grid / `ZcVaultAllocationTable` | `SzipNavOracle`, zipUSD, reservoir `IEVault` `0x1aFc…`, warehouse Safe `0xe028…` | §12 — **DONE 2026-06-11** |
| FE-07 | **Euler-native vault dashboard**: surface the real reservoir EVK market + senior EE pool through euler-lite's OWN lend/borrow/earn pages (largely FE-00 config + the local labels file — this is the "show euler data / particular vaults" surface) | reservoir `IEVault` `0x1aFc…` + EE pool `EulerEarn` `0x1a7A…` | §4.7 — **DONE 2026-06-11** |

INFLOW-06 (`build/tickets/frontend/INFLOW-06-deposit-module.md`) is the **FE-02 draft** — its "address config depends
on item 10 / reads a placeholder" notes are now discharged (use the anvil board); its `abis/`/composable files live in
the **layer**, not in euler-lite.

### Subgraph — deferred (FE track runs without it)
Still gated on item-10 freezing the §9 event ABIs; the MVP runs on **direct on-chain view
reads** (FE-06), not a subgraph. Author a subgraph spec later if/when aggregated history is needed; do not block the FE
track on it.

---

## Open obligations / seams

- **SYSTEMIC SEAM (raised 2026-06-16, CTR-01) — RESOLVED 2026-06-16 by `build/tickets/cre/CRE-OPS-ROUTING.md`.**
  The per-module write-path decision is made: **(R) report path only for 8-B14**; **(K) the single trusted
  operator/keeper for the engine harvest loop (8-B5…8-B10), the redemption operator sequencing (`OffRampModule` +
  `ZipRedemptionQueue`), and `ExitGate.burnFor`**; **`DurationFreezeModule` stays DORMANT** (on-chain `covered()`
  is the fail-closed backstop). `RecycleModule.creditFreeValue` is (K) on principle — report-driving it re-opens
  the §4.5.1 oracle-manipulation exploit. **CTR-01's socket is the exception, not the template** — no further
  sockets owed. Spawns **KEEPER-00** (keeper-service scaffold) + **KEEPER-01** (= rest of CRE-05 + burnFor +
  freeze-on-exception); CRE-02 is confirmed (R)+(K) hybrid. Recorded in `claude-zipcode.md` §8.7. The original
  seam description (kept for context):
  > `cre-sdk-go`'s evm client has reads + exactly ONE write — `WriteReport` (DON-signed
  → Keystone Forwarder → `IReceiver.onReport`); there is **no raw-tx / keeper primitive**. So a wasip1 CRE workflow
  can only drive contracts that are **report receivers**. Today that is: `WarehouseAdminModule`, `SzipNavOracle`,
  `SzipReservoirLpOracle`, `DefaultCoordinator`, `ZipcodeController`, `ZipcodeOracleRegistry`, `SzAlphaRateOracle`
  — and now **`SzipBuyBurnModule`** (CTR-01). The following are gated `msg.sender == operator`/`controller` and
  thus **cannot be driven by CRE as built**: `ReservoirLoopModule` (8-B5), `LpStrategyModule` (8-B6),
  `HarvestVoteModule` (8-B7), `ExerciseModule` (8-B8), `SellModule` (8-B9), `RecycleModule` (8-B10),
  `DurationFreezeModule`, `OffRampModule`, `ZipRedemptionQueue` (`settleEpoch`/`claim`), `ExitGate.burnFor`. **This
  blocks CRE-02 (`settleEpoch`/`requestRedeem`/`claim`) and the rest of CRE-05 (the engine loop).** Per-module
  decision owed: **(a)** adopt the reusable `CloneReportReceiver` base (CTR-01) to add a report socket (clone-safe,
  fail-closed; what 8-B14 did), OR **(b)** drive it from an **off-chain keeper** holding the operator/controller
  hot key (standard go-ethereum tx submission, outside the CRE sandbox). The §8.7 spec exception + the rationale
  are recorded in `claude-zipcode.md` §8.7. Not a code fix owed yet — a track-shaping decision before CRE-02/05.

- **DEP SEAM (raised 2026-06-16, CRE-05a) — the CRE workflows bind to the IN-TREE `reference/cre-sdk-go`
  snapshot, not a published release.** `cre/buyburn-bid/go.mod` uses `replace` → `reference/cre-sdk-go` because
  the published releases (`cre-sdk-go@v0.10.0` / capability `@…beta.0`) LACK APIs the build relies on:
  `evm.WriteCreReportRequest` (the public write type — published has only the inner `WriteReportRequest`),
  `testutils.SetTimeProvider`, and some `evm` chain-selector consts. Until the published SDK catches up (or the
  snapshot is vendored/pinned for the real CRE deploy), every `cre/*` workflow should `replace` to the in-tree
  snapshot. Also: go-ethereum v1.17.2's `abi.Pack` wants a NATIVE `uint32` (not `*big.Int`) for a `uint32` arg —
  produced bytes identical; noted in `cre/buyburn-bid/workflow.go`. Not a code fix owed; a build/deploy note.

- **DEPLOY OBLIGATION (raised 2026-06-16, CTR-01) — `DeployZipcode` must wire the buy-burn report socket
  post-clone.** After cloning `SzipBuyBurnModule`, the deploy must call `setForwarder(keystoneForwarder)` +
  `setExpectedWorkflowId(WORKFLOW_ID)` (and optionally `setExpectedAuthor`) on it, else the report socket stays
  inert (fail-closed — `onReport` reverts `InvalidForwarder`). The operator path works without this; only the CRE
  report door needs it. Mirror the `setExpectedWorkflowId(...) != 0` assert pattern §9 already mandates for the
  other `ReceiverTemplate` subclasses before the Timelock hand-off. Not a contract change; a deploy-runbook step.

- **RUNBOOK (raised 2026-06-15, SEC-03) — durable admin MUST `acceptAdminRole` post-deploy to finalize the CCT
  registry-admin handoff (both chains).** `DeploySzAlphaBridge` hands the `TokenAdminRegistry` administrator to the
  durable authority via a 2-step `transferAdminRole` (964 → `ccipAdmin`, Base → `timelock`) but cannot accept on
  its behalf mid-broadcast. So after `deploy964`/`deployBase`, the durable authority MUST call
  `ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)` to become the registry `administrator`. Until it
  does, the ephemeral deploy Script remains a live registry admin — the one residual interruption window; accept
  promptly and verify `getTokenConfig(token).administrator == <durable>`. Documented in both deploy functions'
  NatDoc + `build/wires/8x-01-szALPHA-bridge.md` (Item-10 deploy facts step 4b). Not a contract change owed; an
  operational deploy-runbook step.

- **TODO (raised 2026-06-15, SEC-01) — CRE-01 must not co-locate two same-lien `seedPrice` writes in one block.**
  The oracle monotonic guard (SEC-01) lives in `ZipcodeOracleRegistry._writePrice` and rejects a write whose `ts` is
  not strictly newer than the cached mark. The controller re-anchors via `seedPrice` at origination (`:199`) AND draw
  (`:223`), and `seedPrice` stamps `block.timestamp` (no incoming CRE ts), so an origination+draw (or draw+draw) of the
  **same lien in one block** now reverts `StaleReport()` — intended fail-closed (the H1 seed-clobber). Benign in prod
  (origination/draw are separate Keystone reports in separate blocks), but **CRE-01 must ensure same-lien seeds are not
  co-located in one block** (defer the second one block, or — future hardening — give the seed path a real ts instead
  of `block.timestamp`). Not a contract change owed; an operational constraint on the CRE producer.

- **RESOLVED INTO A WORKSTREAM (2026-06-18) — concurrent-line ceiling.** This TODO (raised 2026-06-15 ticketing
  SEC-06) is now the **Credit-warehouse scaling + federation** workstream above (CTR-02..CTR-10). Decision: shard
  across multiple EE pools (option a) — it keeps per-line EVK isolation and makes senior NAV a Σ of audited EE
  share values; the shared-vault topology (option b) was rejected (it sacrifices isolation). Note the original
  "~29 concurrent" was imprecise on two counts: (i) two non-line markets per pool → **28**, not 29; (ii) `closeLine`
  reclaimed only the SUPPLY queue, so closed lines did NOT free the binding withdraw-queue slot → ~28 *lifetime*, not
  concurrent — **fixed by CTR-04 (DONE 2026-06-18); a pool now churns 28 *concurrent* lines.** See the workstream
  ledger for the full decomposition.

- **RESOLVED (2026-06-13/16) — `DurationFreezeModule` rework.** The 2026-06-12 "incomplete" concerns (premise
  obviated; can't act on staked LP; `ichiVault` placeholder) are SUPERSEDED in the built code: it is now a
  debt-pinned coverage floor (`requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`), the staked
  LP is counted IN PLACE via `pathLockedLpEquity()`, and `covered()` gates the real outflows
  (`SzipBuyBurnModule.postBid`, `LpStrategyModule.removeLiquidity`); the `ichiVault` placeholder + coverage knobs
  were removed. Dormant `commit`-on-shortfall lever = KEEPER-01c. Truth: `build/wires/DurationFreezeModule.md`.

- **BLOCKED (external, not build work) — the real szALPHA/zipUSD Hydrex LP pool is NOT yet active, so
  `SzipNavOracle` can't be wired to it.** The junior NAV's LP leg can only price our pool once Hydrex stands up the
  szALPHA/zipUSD vAMM pool + the Ichi strategy (upstream of us; needs szALPHA bridged + live — see `docs/bridge.md`
  / `hydrex-demo-fork`). Until that pool exists, `SzipNavOracle.ichiVault` stays on the **WETH/USDC stand-in**
  (`0x07e72E46…`) and the LP code path is exercised only by the demo vAMM fork (`SzipNavOracleDemoVAMM`). The wiring
  surfaces already exist (`setLpPosition`/`setReservoirLeg`, Timelock-settable), so when the pool is live it is a
  deploy/fork-wiring step (create+stake gauge → escrow vault → `setLpPosition` → CRE-03 `LP_MARK` feed), NOT a
  contract change. One verification owed at that point: confirm the LP-leg read (`_legPriceOfToken` spot
  `getTotalAmounts()`) is not flash-skewable for the real pool — if the TWAP bracket doesn't defend, that becomes a
  hardening ticket. NB fork trap: while `ichiVault` points at WETH/USDC, that LP in a Safe reverts
  `UnknownLpToken(WETH)` and bricks NAV reads.

- **FE-01 finding — `SzipNavOracle` has no `navPerShare()`** (logged 2026-06-10). The deployed oracle
  (`build/anvil/abi/SzipNavOracle.json`) exposes **`navEntry()`** (issuance price), **`navExit()`** (redemption
  price), **`spotNavPerShare()`**, **`twapNavPerShare()`** — all `view returns (uint256)`, 18-dp. There is NO
  `navPerShare()` (reverts). The spec §7 prose / INFLOW-06 use `navPerShare` as shorthand; the **contract wins**
  (harness §1). This is a **rename, not a missing surface — no contract change owed**: FE-03 (position/NAV) +
  any szipUSD-valuing screen must read `navEntry`/`navExit` (or the spot/twap views), not `navPerShare`. Live
  `navEntry()` ≈ `1.07e20`.
- **FE-04 finding — the szipUSD junior exit is NOT a contract write; the senior queue is treasury-only** (logged
  2026-06-11). The original FE-04 row demanded `ExitGate.requestExit`/`cancelExit` + a `ZipRedemptionQueue` cooldown
  panel — **all wrong** (the contract wins, harness §1; spec §6.4 confirms):
    - `ExitGate` has **no** `requestExit`/`cancelExit`/`processWindow` — they were **retired by design** (the forfeiting
      on-chain queue, `ExitGate.sol:26-28`). The junior exit is an **off-chain CoW sell order**; the only on-chain user
      write is `szipUsd.approve(vaultRelayer)`. `ExitGate.burnFor` is `onlyWindowController` (CRE keeper), not the UI.
    - `ZipRedemptionQueue` is the **SENIOR zipUSD→USDC treasury off-ramp** (`requestRedeem` is `onlyRedeemController` =
      the rq Safe driven by `OffRampModule`; `requester == owner == rqSafe`). A retail lender **cannot** enter it or
      claim from it. `ZipRedemptionQueue.sol:14-17` + `OffRampModule.sol:33-40`: *"NOT the junior Exit Gate… Never
      conflate."* The FE has **no senior-queue surface** and **no szipUSD cooldown** (the resting CoW order is the queue).
    - **No back-pressure obligation owed** — every surface the real (CoW) design needs EXISTS (`SzipBuyBurnModule` CoW
      wiring + `quoteMaxPrice`/`dBps`, `SzipUSD.approve`, `navExit`). The "missing" surfaces were never owed; they were
      retired. This was a **ticket error**, fixed in the FE-04 ticket; **no `claude-zipcode.md` change** (§6.4 already
      correct).
- **FE-05 finding — draw is CRE-only; repay is the native EVK `repay`, permissionless; the borrower ≠ the wallet**
  (logged 2026-06-11). The original FE-05 row implied a borrower-side draw/repay path — the contract wins (harness §1):
    - **No borrower draw write exists.** `EulerVenueAdapter.{openLine,setLineLimits,fund,draw,closeLine,liquidate}` are
      ALL `onlyController` (`EulerVenueAdapter.sol:83` modifier; `draw` `:298` also pins receiver = the immutable
      Erebor, `:302`); `liquidate` additionally `revert NotImplemented` (§4.4e). `ZipcodeController`'s only write entry
      is `onReport` (Keystone-forwarder + workflow-identity gated) — no public originate/draw. So `ZcDrawModal` is
      **read-only**; the draw is CRE-originated (§17).
    - **Repay is NOT a Zipcode method — it is the native EVK `IEVault(lineRef).repay(amount, borrowAccount)`**, ungated
      (`openLine` hooks only `OP_BORROW | OP_LIQUIDATE`, **never** `OP_REPAY`, `EulerVenueAdapter.sol:220`). Approve is
      a **direct** `usdc.approve(lineRef, amount)` to the line vault (NOT Permit2 — `ReservoirLoopModule.repay:251`).
      Any wallet may repay (credits `borrowAccount`, no controller-enablement/operator bit) — the §4.4e permissionless
      property. `full`→`type(uint256).max` (EVK clamps; a finite over-repay reverts `E_RepayTooMuch`).
    - **No back-pressure obligation owed** — every read (`getLine`/`observeDebt`/`getLien` + the `LienOriginated`/
      `LienStatusUpdated`/`LienReleased` events) and the EVK `repay`/`debtOf`/`asset` all exist. The implied borrower
      "draw" write was never owed; it is CRE-driven by design. **No `claude-zipcode.md` change** (§4/§9/§15 already
      correct). Ticket-precision note: `getLine` returns a **named-tuple struct** (viem → object, read by field name),
      not a positional tuple — the ticket wording was corrected.
    - **New FE seam:** `useZipTx.sendRawZipTx({to,abi,functionName,args})` writes to a **runtime/non-registry address**
      (per-line vaults) reusing the shared 1.3× buffer — the spine for any dynamically-discovered-contract write.
- **FE-07 Finding A — DISCHARGED 2026-06-19 by CTR-06a.** `ReservoirMarketDeployer.deploy` now hands the borrow-vault
  governor to the Timelock (`IEVault(borrowVault).setGovernorAdmin(p.governor)`, step 6, alongside the router transfer);
  `test_deployer_governor_RETAINED` asserts `governorAdmin() == governor` (proven load-bearing: the assert fails without
  the fix, where the governor is the throwaway deployer instance). **Live-fork caveat retained:** this fixes all FUTURE
  deploys; the ALREADY-DEPLOYED anvil borrow vault keeps its stranded governor until a redeploy — FE-07's `entities.json`
  must still re-read `governorAdmin()` after any redeploy (that row already says so). Original finding kept below for
  context:
  - The reservoir **borrow vault's `governorAdmin` is never transferred to the Timelock** — it stays
  the throwaway `ReservoirMarketDeployer` instance (`0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa` on the current fork).
  `ReservoirMarketDeployer.deploy` (`contracts/script/ReservoirMarketDeployer.sol`) transfers only the **router**
  governance (`EulerRouter(router).transferGovernance(p.governor)`, `:88`); the borrow vault is created via
  `factory.createProxy` (deployer = governor at birth, `:77`) and never gets `setGovernorAdmin(p.governor)`. The comment
  at `:75` ("Governor RETAINED so the Timelock can tune LTV/caps") is **wrong for the borrow vault** — the Timelock
  cannot govern it; the deployer can. **Fix owed:** add `IEVault(borrowVault).setGovernorAdmin(p.governor)` in
  `ReservoirMarketDeployer.deploy` (alongside the router transfer) so the borrow vault is Timelock-governed (§17
  Timelock-settable-not-frozen). Once fixed, the live `governorAdmin` becomes `0x89ae…` (already in FE-07's
  `entities.json`) and the deployer entry can be dropped. **FE interim (shipped):** FE-07 declares the live deployer
  address so the reservoir market verifies in the UI today; `0x77C2Cb…` is nonce-derived, so re-read `governorAdmin()`
  and update `entities.json` after any redeploy that moves it. **TICKETED 2026-06-18 as CTR-06a**
  (`build/tickets/contracts/CTR-06a-reservoir-governoradmin-fix.md`) — add `IEVault(borrowVault).setGovernorAdmin(p.governor)`
  + a post-assert; mark this obligation DISCHARGED when CTR-06a lands.
- **DEPLOY OBLIGATION (raised 2026-06-18, CTR-03) — wire the controller↔SiloRegistry pair before the first
  origination.** The `ZipcodeController` now resolves venue + slot-accounting through `SiloRegistry`. The deploy
  MUST: (a) `controller.setRegistry(siloRegistry)`; (b) `siloRegistry.setController(controller)` (its
  `incrementLineCount`/`decrementLineCount` are `onlyController`); (c) register silo #0 (`addSilo`) whose `adapter`
  equals the controller's ctor `venue` seed; (d) assert `siloRegistry.controller() == address(controller)`
  post-deploy. Until (a)+(b), every origination reverts `RegistryUnset`/`NotController` (and every close at the
  decrement). Symmetric to the existing `oracleRegistry.setController` step (WOOF-05 item-10 S6). Folds into the
  CTR-06 `SiloDeployer` runbook. Not a contract change owed; a deploy-wiring step. **DISCHARGED-as-runbook 2026-06-19
  by CTR-06c** — the D2 hub-grant runbook (`docs/wires/CTR-06c-SiloDeployer.md` + the `SiloDeployer` NatSpec) documents
  + prank-tests the per-silo `addSilo`/`setCurrentSilo` + the `zipUSD.setCapacity` grant; the one-time hub half
  (`controller.setRegistry`/`siloRegistry.setController` + silo #0 registration) is CTR-03/`DeployZipcode`, already
  done. Remains an operational deploy step (no contract change), now fully specified.
- **CRE report ABI seam.** Every CRE report payload must `abi.decode` to the §4.4 layout the filed
  `ZipcodeController` / `ZipcodeOracleRegistry` expect (reportTypes 1/2/4/5/6 → controller, 3 → registry).
- **Subgraph blocked** until item-10 freezes the §9 event signatures.
- **RUNBOOK — `ExitGate.setBaal` managerLock parity (a trusted-admin footgun).** `ExitGate.setBaal` (`:114`,
  `onlyOwner`/Timelock) can re-point to a different Baal; if that Baal has `managerLock == true`, the Gate's
  `manager(2)` grant can no longer be re-set → deposits/`burnFor` brick (fail-closed). Only reachable via a Timelock
  re-point to a hostile/locked Baal (build-phase wiring is deliberately settable, §17; the Timelock owner is trusted,
  §13) — same class as the `WarehouseAdminModule` `setSafe`/`setAvatar` parity footgun. No code fix owed; **before any
  `setBaal`, assert the target Baal's `managerLock() == false`.**
- **DEFER — on-chain draw-time coverage gate (ABANDONED 2026-06-16).** A portfolio-level "total debt ≤ junior-backed
  capacity" gate at borrow time was considered and **dropped**: a draw can only borrow USDC physically present in the
  EulerEarn pool (senior deposits), so pool liquidity already hard-bounds total draws; plus per-line LTV/cap + the two
  `covered()` outflow gates. No credible path where draws outrun coverage. Don't re-propose. If ever revisited: a
  `zipUSDValue()` TWAP-bracketed view + an `illiquidSeniorValue() + draw <= zipUSDValue()` check in the draw path.
- **LOSS — the default/slash flow is M2, not M1-live (from `src/loss/` headers, recorded 2026-06-17).**
  `LienXAlphaEscrow`'s custody half (`lockXAlpha`/`releaseXAlpha`) is M1-live; the slash half
  (`slashXAlphaToCapital`/`slashXAlphaToCohort`) + the `DefaultCoordinator` driver are built + mock-tested but go
  live in M2. The driver is **CRE-01's `rt8` default/recovery action family** (already in the CRE backlog above —
  not a new workflow) plus the off-chain capital-sink liquidation account (xALPHA→USDC on Bittensor). No contract
  code owed — it's CRE-01 sequencing + that operational account.
- **LOSS — cohort-premium should route to the MAIN Safe + a CRE flow, not the sidecar in-kind (design decided 2026-06-18).**
  As-built, `LienXAlphaEscrow.slashXAlphaToCohort` parks the premium xALPHA in the **sidecar** Safe and the natspec
  treats it as in-kind ("never market-sold; NAV does the cohort pro-rata for free"). But the flywheel modules
  (`SellModule`/`LpStrategyModule`/Gate) all operate on the **engine Safe (== `mainSafe`, DeployZipcode:384)**, so they
  can't reach sidecar xALPHA — the premium just sits there. **Decision:** route the cohort slash to the **main Baal
  Safe** so the existing yield-flywheel modules can subsume it (xALPHA → zipUSD → LP backing), lifting shares the
  same way emissions do; and add a **slash-triggered CRE flow that REUSES the existing Zodiac flywheel modules —
  NO new modules** (`SellModule` already does the `zipUSD↔xALPHA` POL swap on the engine Safe; the slash flow IS
  the yield/harvest sequence, just triggered on a slash or subsumed by the normal harvest cadence). Fold into the
  harvest orchestrator KEEPER-01b / the CRE-01 loss leg. **The CONTRACT half (retarget the destination + natspec) is
  ticketed as CTR-11** (`build/tickets/contracts/CTR-11-cohort-slash-to-main-safe.md`) — safe to land independently
  (rerouted xALPHA is swept by the normal harvest vs stranded in the sidecar today). The slash-triggered CRE flow
  stays M2. Implications handled in CTR-11: (a) the destination + natspec change; (b) the premium then lands in FREE
  value, not the committed sidecar bucket — confirmed intended for the freeze-floor accounting (a stayer bonus
  should be liquid/sellable; gross NAV unchanged, xALPHA stays a movable leg).
- **LOSS — designate the real treasury Safe for the capital-hole recovery (recorded 2026-06-18).** The
  destination is renamed `capitalSink` → `treasurySafe` by **CTR-12** (contract rename) — naming it the protocol
  treasury Safe. `slashXAlphaToCapital` routes the slashed bond there; today it's only a deploy-config placeholder.
  The remaining OPERATIONAL half (M2): create + wire the real treasury Safe and stand up its off-chain process
  (receive slashed xALPHA → bridge to Bittensor → liquidate alpha → TAO → USDC → return USDC to cover the realized
  hole, §11). Ops deliverable, not contract code (the rename is CTR-12; the Safe + bridge process is M2 ops).
- **PRE-PROD — re-freeze ALL build-phase wiring to immutable (§17, repo-wide; recorded 2026-06-17).** This is a
  deliberately-deferred, **protocol-wide** end-of-build step, not a loss-side task: every contract carries
  Timelock-settable wiring (each cross-component pointer is re-pointable — `harness.md` locked decision #6), and
  the immutability lock-down is deferred to pre-prod. The loss side is just one instance — `LienXAlphaEscrow`'s
  four slots (`xAlpha`/`coordinator`/`capitalSink`/`sidecar`) + `DefaultCoordinator.setEscrow` (onlyOwner, NOT
  set-once) — alongside `WarehouseAdminModule`, `EulerVenueAdapter`, `ZipcodeController`, `CREGatingHook`, the
  oracles, `DurationFreezeModule`, etc. Until the lock-down, the trusted Timelock owner can re-point any of them
  (grief/redirect, never drain — §13). When ticketed, it is ONE repo-wide "freeze wiring to immutable" pass.

---

## Deletion triggers (when forward artifacts die)

- **8-B11 + 8-B12 land** (CRE-05 strategy robot + monitoring) → `pending-docs/{monitoring,hydrex,auto-compounder}.md`
  die, folded into those builds.
- **Real Proof / SPV / insurance integration lands** (collateral un-mocked) → `pending-docs/spv-lien-proof.md` dies.
- **Built-contract narrative still in `claude-zipcode.md` §6/§7/§11** can be pruned to `wires/` pointers later
  (only §4 has been pruned so far; left in place for now to avoid disturbing the forward narrative around it).

---

## Done

The built, fork-tested on-chain contract stack (32 product contracts + 6 scripts + 30 interfaces) is
truth-sourced and indexed in **`build/wires/COVERAGE.md`** — not re-narrated here.
