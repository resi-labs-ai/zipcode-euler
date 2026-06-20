# CRE-02c — cross-silo redemption solver (which EE vault(s) to drain, and the split)

> BUILD ticket (both forks resolved). Spec: `claude-zipcode.md` §6.1 / §6.3 / §8.2 / §8.3 / §8.5; federation §4.7.
> Multi-warehouse generalization of CRE-02b (the single-pool funding leg). Folds into `cre/warehouse` as a THIRD
> default-OFF handler (`onSolverTick`) alongside CRE-04's `onWarehouseOp` (http) + CRE-02b's `onFundingTick` (cron).
> Depends on: CRE-02 (settle/claim — DONE), CRE-04 (`cre/warehouse` REDEEM/REPAY encode+write — DONE),
> CRE-02b (the single-pool sizing this generalizes — DONE), SiloRegistry (CTR-02 — DONE). Relates to CTR-14.

## Deliverable
A new cron handler `onSolverTick` in `cre/warehouse` (off-chain Go, wasip1) that, on each tick: reads the ONE
shared `ZipRedemptionQueue` shortfall, enumerates the live silos, sizes a per-pool REDEEM/REPAY split that
respects each pool's free-liquidity + per-silo coverage gate, and fires per-silo REDEEM→REPAY reports into the
one shared queue by writing to EACH silo's own `WarehouseAdminModule`. **Default-OFF** (`SolverEnabled=false`):
returns before any read. **No contract changes** — off-chain Go only → no backward `wires/` edit owed.

## Both open forks — RESOLVED at scoping (record)

### Fork A — the split policy: **pro-rata by gated free-liquidity** (M-N1)
Split the REDEEM shortfall across pools proportional to each pool's **`availP`** — the coverage-gated,
reserve-netted, per-tick-clamped redeemable amount (NOT the raw `maxWithdraw`). Rationale: pro-rata spreads
draw contention (no per-pool starvation), and weighting by `availP` (not raw free liquidity) means an
undercovered or reserve-starved pool has `availP == 0` ⇒ weight 0 ⇒ it is **skipped automatically** — the
"starved/undercovered pool is skipped" invariant falls out of the weight, not a special case. Utilization-
balancing is the documented dynamic upgrade (own-later); curator/priority ordering is federation policy
(own-later). This ticket builds pro-rata only.

### Fork B — the topology / who writes: **option (i), one binary, per-silo loop**
ONE `cre/warehouse` deployment, ONE workflow id, a single `onSolverTick` that loops the silos and writes a
report to EACH silo's own `WarehouseAdminModule` (WAM). This is feasible because the WAM gate
(`ReceiverTemplate.onReport`, `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol:83-92`)
admits a report iff `msg.sender == forwarder` AND `workflowId == expectedWorkflowId`:
- **Forwarder is already shared** — `SiloDeployer.s.sol` passes the one hub `p.forwarder` to every warehouse
  (`CreditWarehouseDeployer.deploy(... forwarder ...)` → `new WarehouseAdminModule(forwarder, ...)`).
- **`expectedWorkflowId` is a per-WAM deploy-config slot** (`setExpectedWorkflowId`, `ReceiverTemplate.sol:184`).
  **OPERATIONAL PRECONDITION (document, do NOT build around):** every silo's WAM `expectedWorkflowId` is set to
  the single `cre/warehouse` workflow id (the §17 build-phase-settable posture). Then the one binary's reports
  are accepted by ALL silos' WAMs. This is exactly the constraint that forced CRE-02b to fold into this binary
  (a separate binary = a different workflow id = rejected); option (i) is its multi-silo echo.
Option (ii) (an orchestrator POSTing to N separate warehouse binaries) is REJECTED — it multiplies binaries and
breaks the single-binary precedent.

## The silo↔WAM binding (the registry gap — a CONFIG SEAM, not back-pressure)
`SiloRegistry.Silo` carries `{adapter, warehouseSafe, eePool, juniorBasket, escrow, defaultCoordinator,
navOracle, freeze, curator, lineCount, active}` — it has **NO `warehouseAdminModule` field** (verified
`SiloRegistry.sol:82-95`). The WAM is CRE receiver plumbing the admission gate intentionally does not catalog
(the gate asserts the topology web: freeze/escrow/coordinator/adapter self-consistency, not CRE receivers). So:
- **The registry is the source of truth for the LIVE silo set + per-silo coverage gate:** `allSiloIds()` →
  `getSilo(id)` → skip `!active`; take `{warehouseSafe, eePool, freeze}` per active silo.
- **`cfg.Warehouses []string` is the writable WAM set** (the silo→WAM binding the registry lacks; §17 config,
  re-pointable — exactly how CRE-02b sources its single `cfg.Warehouse`).
- **Join by `warehouseSafe`:** for each WAM in `cfg.Warehouses`, read `warehouseSafe()`; pair it to the active
  registry silo whose `warehouseSafe` matches. A WAM with no matching active silo ⇒ skip + log. An active silo
  with no mapped WAM ⇒ skip + log (cannot write to a pool we have no receiver for). `warehouseSafe` is unique
  per silo (one Safe per silo — the topology invariant), so the join is 1:1.
- This is a **config seam, not a back-pressure obligation** (every input exists; the WAM is deliberately
  off-registry). A future hardening — adding `warehouseAdminModule` to the `Silo` struct so the binding is
  on-chain-authoritative — is logged as a low-priority OPEN note, NOT owed by this ticket.

## Binds to (CONFIRMED 2026-06-20)
- **`SiloRegistry` (CTR-02, DONE)** — `allSiloIds() → bytes32[]` (`:268`), `getSilo(bytes32) → Silo` tuple
  (`:263`; field order: adapter, warehouseSafe, eePool, juniorBasket, escrow, defaultCoordinator, navOracle,
  freeze, curator, `uint16 lineCount`, `bool active`). Address `cfg.SiloRegistry`.
- **`WarehouseAdminModule` (per silo, DONE)** — public getters `warehouseSafe()` (`:57`), `eePool()` (`:59`),
  `usdc()` (`:61`), `redemptionBox()` (`:63`); the §8.5 receiver CRE-04/02b already write to. REDEEM →
  `eePool.redeem(shares, safe, safe)` (`:181-182`), REPAY → `usdc.transfer(redemptionBox, amount)` with the
  `WrongRedemptionBox` self-check `dest != redemptionBox` (`:188`). Reports encode via the EXISTING
  `cre/zipreport.WhRedeemReport(shares)` / `WhRepayReport(dest, amount)` (`cre/zipreport/report.go:331/336`).
- **Per-silo coverage gate** — each silo's `freeze` (DurationFreezeModule) `covered() → bool`
  (`DurationFreezeModule.sol:330`). Read it per silo from the registry's `freeze` field (NO `cfg.CoverageGate` —
  multi-silo means per-silo gates, the improvement over CRE-02b's single gate).
- **Per-pool free-liquidity + sizing (the CRE-02b reads, per pool)** — `eePool.maxWithdraw(safe)` (donation-
  immune free USDC, 6-dp), `eePool.balanceOf(safe)`, `eePool.convertToAssets(shares)` (share→USDC sizing);
  `usdc.balanceOf(safe)` (already-held REDEEM proceeds for the REPAY leg).
- **Shared queue shortfall** — off the shared queue (`redemptionBox`, read off any WAM; assert all WAMs agree):
  `scaleUp()` (`:56`), `totalPending()` (`:74`), `reservedAssets()` (`:76`), `usdc.balanceOf(queue)`. All public
  state-var getters on `ZipRedemptionQueue.sol`.

## The tick (stateless / idempotent — the CRE-02b posture, generalized)
1. **`!cfg.SolverEnabled` ⇒ no-op** (K-DEFAULT-OFF): return BEFORE any `CallContract` — zero reads, zero writes.
2. `cfg.SiloRegistry` unset OR `len(cfg.Warehouses) == 0` ⇒ no-op.
3. **Resolve the shared queue + global shortfall.** Read `redemptionBox()` off `cfg.Warehouses[0]` as `queue`
   (re-pointable, §17). `scaleUp == 0` ⇒ no-op. Read `usdc` off `cfg.Warehouses[0]` (the shared USDC).
   `shortfall = max(0, totalPending/scaleUp − max(0, usdc.balanceOf(queue) − reservedAssets))` (6-dp USDC — P7
   units identical to CRE-02b: `scaleUp = 1e12`, `totalPending` 18-dp zipUSD ⇒ `/scaleUp` is 6-dp). `shortfall
   <= 0` ⇒ no-op (settle/claim is CRE-02's job).
4. **Build the candidate pool set.** Enumerate `allSiloIds()`; for each `getSilo(id)`: skip `!active`. Join to a
   WAM in `cfg.Warehouses` by `warehouseSafe` (read each WAM's `warehouseSafe()` once; build the map). For each
   joined pool read: `safeUsdc = usdc.balanceOf(safe)`; `covered = freeze.covered()` (zero freeze addr ⇒ true,
   the CRE-02b idiom — but the registry never stores a zero freeze, so this is defensive); `freeReservoir =
   eePool.maxWithdraw(safe)`. Assert each WAM's `redemptionBox() == queue` — skip + log any divergent WAM (the
   shared-queue invariant; never REPAY a pool's cash into the wrong sink).
5. **Per-pool `availP`** (the CRE-02b floor, per pool): `availP = covered ? clamp(freeReservoir −
   HarvestReserve − SafetyBuffer, 0, MaxRedeemPerTick) : 0` (`MaxRedeemPerTick == 0` ⇒ no upper clamp). These
   are PER-POOL knobs reused from CRE-02b's Config (applied to each pool identically — NOT split across pools).
6. **REPAY leg (un-gated; greedy, global-bounded).** Iterate pools in `allSiloIds()` order; `repayP =
   min(safeUsdc_P, remainingShortfall)`; `remainingShortfall -= repayP`. REPAY moves cash the Safe already holds
   (the only naked USDC in a Safe is prior REDEEM proceeds — `8-Bw` custody invariant), so it is safe even when
   undercovered, and greedy keeps `Σ repayP ≤ shortfall`.
7. **REDEEM split (pro-rata by `availP`, Fork A).** `totalAvail = Σ availP`. `redeemTarget = min(remainingShortfall,
   totalAvail)`. Per pool: `redeemAssetsP = floor(redeemTarget · availP / totalAvail)` (integer floor ⇒ Σ ≤
   redeemTarget, conservative; and `redeemAssetsP ≤ availP` because `availP/totalAvail ≤ 1` and `redeemTarget ≤
   totalAvail` — never over-redeems a pool into its freeze). `totalAvail == 0` ⇒ no REDEEM (every pool starved/
   undercovered). Convert to shares per pool via the ERC-4626 ratio (NO `convertToShares` dependency):
   `redeemSharesP = floor(redeemAssetsP · balanceOf(safe_P) / convertToAssets(balanceOf(safe_P)))`, guarded
   `navAssets_P > 0 && totalShares_P > 0` else 0.
8. **Fire per-silo REDEEM→REPAY** to EACH pool's OWN WAM (Fork B). Per pool, in order: if `repayP > 0`,
   `buildRepay(WarehouseOp{Op:"repay", Dest: queue.Hex(), Amount: repayP})` → `writeReportTo(WAM_P)`; if
   `redeemSharesP > 0`, `buildRedeem(WarehouseOp{Op:"redeem", Shares: redeemSharesP})` → `writeReportTo(WAM_P)`.
   REPAY-then-REDEEM per pool (deliver-then-refill; abort-safe — each sized off pre-tick reads). A write error is
   RETURNED (the §8.5 / CRE-02b posture; do not swallow).

## Key requirements (pins for the cold-build — zero load-bearing guesses)
- **K1 — THIRD handler, do not regress CRE-02b/CRE-04.** Add `onSolverTick(cfg, runtime, *cron.Payload)` as a
  THIRD `cre.Handler` in `initFn` (a second `cron.Trigger`, schedule `cfg.SolverSchedule`), leaving
  `onWarehouseOp` (http) and `onFundingTick` (cron) UNCHANGED. The existing 34 funding/op tests MUST stay green.
- **K2 — mutual exclusion guard.** Enabling both `onFundingTick` (single) and `onSolverTick` (multi) would
  double-count the SAME shared-queue shortfall. Add: `onFundingTick` returns no-op when `cfg.SolverEnabled` is
  true (the solver supersedes the single-pool leg). Document the operational rule: enable exactly one.
- **K3 — Config additions only (no removals):** `SolverEnabled bool`, `SolverSchedule string`,
  `SiloRegistry string`, `Warehouses []string`. REUSE the existing `HarvestReserve` / `SafetyBuffer` /
  `MaxRedeemPerTick` (per-pool semantics). NO `CoverageGate` for the solver (per-silo freeze from the registry).
- **K4 — reuse, do not re-implement:** the read helpers (`readAddr`/`readUint`/`readUintWithAddr`/
  `readUintWithArg`/`readBool`/`callF`/`selectorF`/`decodeUintF`) and the sizing helpers (`clampF`/`bigMin`/
  `mustBigF`) ALREADY EXIST in `funding.go` — reuse them. The encoders `buildRedeem`/`buildRepay` already exist
  in `workflow.go` — reuse them. Add a new `readSiloIds` (returns `[][32]byte` / `[]common.Address`-style via a
  `bytes32[]` decode) and `getSilo` decode helper (decodes the 11-field tuple; only `warehouseSafe`/`eePool`/
  `freeze`/`active` are used). Add `writeReportTo(cfg, runtime, receiver common.Address, envelope []byte)` —
  generalize the existing `writeReport` to take an explicit receiver; the old `writeReport` may delegate to it
  with `cfg.Warehouse`.
- **K5 — invariants the test must prove:**
  (a) a starved pool (`freeReservoir ≤ reserves` ⇒ `availP=0`) AND an undercovered pool (`covered=false` ⇒
      `availP=0`) each get ZERO redeem and are skipped;
  (b) the REDEEM split matches pro-rata: two healthy pools with `availP` 3:1 split the redeem 3:1 (modulo
      integer floor);
  (c) `Σ repaidP + Σ redeemAssetsP ≤ shortfall` (total funded never exceeds the shortfall);
  (d) `redeemAssetsP ≤ availP` for every pool (never over-redeems into a freeze);
  (e) `SolverEnabled=false` ⇒ ZERO reads, ZERO writes; empty `Warehouses` / no active silos / no shortfall ⇒
      no writes;
  (f) each REDEEM/REPAY is written to the CORRECT per-silo WAM (the join by `warehouseSafe` routes correctly).
- **K6 — encode handshake unchanged:** REDEEM is `(uint256 shares)` → `WarehouseAdminModule._processReport :172`;
  REPAY is `(address dest, uint256 amount)` → `:176` with `dest == redemptionBox` self-check. Reuse CRE-04's
  byte-exact encoders; do not re-derive the envelope.

## Done when (the gate)
- `cd cre/warehouse && go build ./... && go vet ./... && GOOS=wasip1 GOARCH=wasm go build ./... && go test
  -count=1 ./...` all green. The existing funding/op tests still pass (no regression).
- A table-driven `solver_test.go` proves K5 (a)–(f), decoding the captured `WriteReport` bytes per silo to op +
  sized scalars (NOT trusting `zipreport`), and asserting the per-WAM routing. A simulated `RunInNodeMode` path
  is NOT required for the cron solver (CRE-02b's `onFundingTick` test precedent — the cron reads are mocked via
  the evm stub; identical-consensus is exercised by the http path's existing tests).
- The split policy (Fork A: pro-rata by gated free-liquidity) + topology (Fork B: option (i), one binary) are
  recorded — here + in the PROGRESS note.

## Ships default-OFF (M1 posture)
Inert until `SolverEnabled` is set + each WAM's `expectedWorkflowId` is pinned to this binary. In M1 ops picks
the source pool by hand (the single-pool `onFundingTick`, or manual http ops). The solver automates the choice
once there are genuinely multiple live pools.

## Cold-build pins (P1–P7 — from the 4-critic fan-out; close every load-bearing guess)

- **P1 — `getSilo` decode by WORD OFFSET, NOT go-ethereum tuple reflection (THE load-bearing pin).** `getSilo`
  returns a `Silo memory` whose 11 fields are ALL static (9 × `address`, `uint16 lineCount`, `bool active`) ⇒
  the tuple is a fully-static, inline-encoded 11-word blob: `len(reply.Data) == 352` (11 × 32), NO leading
  offset word, field `i` at word `i`. The solver needs only 4 fields — extract by word index, no abi tuple type,
  no struct reflection (there is NO in-repo precedent for tuple-unpack — confirmed by reference-verifier; do not
  invent one):
  - `warehouseSafe = common.BytesToAddress(word[1][12:32])` (word 1)
  - `eePool        = common.BytesToAddress(word[2][12:32])` (word 2)
  - `freeze        = common.BytesToAddress(word[7][12:32])` (word 7)
  - `active        = word[10][31] != 0` (word 10; bool right-aligned)
  where `word[i] = data[i*32:(i+1)*32]`. Guard `len(data) >= 352` (skip+log a short/empty silo). Write a helper
  `decodeSilo(data []byte) (warehouseSafe, eePool, freeze common.Address, active bool, ok bool)`. The TEST must
  ENCODE its mock `getSilo` return via `abi.Arguments{{Type: <11-field tuple>}}.Pack(...)` (the canonical encoder
  — 9 addresses, a `uint16`, a `bool`) so the word-offset DECODE is proven against the canonical ABI layout. (If
  the cold-build prefers the abi-tuple approach it MAY use it, but the word-offset is the pinned, lower-risk path.)
- **P2 — `readSiloIds` returns `[][32]byte`** (NOT `[]common.Address`; the earlier "/[]common.Address" wording is
  void). Call `allSiloIds()` (no arg), unpack with `abi.NewType("bytes32[]","",nil)` → `[][32]byte`. Add a
  `getSilo`-arg packer: pack the `[32]byte` id via `abi.NewType("bytes32","",nil)`, append to `selectorF("getSilo(bytes32)")`,
  `callF`, then `decodeSilo` the reply.
- **P3 — assert shared USDC per WAM (parallel to the redemptionBox assert).** Read `usdc()` off each WAM; require
  `== usdc0` (the canonical from `cfg.Warehouses[0]`); skip + log any divergent WAM. Use `usdc0` for the queue
  balance read and each pool's own `safeUsdc` read (USDC is one token across silos on a single chain; the assert
  makes the invariant explicit rather than assumed — junior-dev Gap #11).
- **P4 — impl file `cre/warehouse/solver.go`; test `cre/warehouse/solver_test.go`.** Flat `package main`; the
  reused helpers live in `funding.go`/`workflow.go` (no import needed).
- **P5 — the test stub keys by (To, selector, arg), one `AddContractMock` per address.** Follow `funding_test.go`
  exactly: distinct addresses per pool for {WAM, eePool, safe, freeze}; `usdc.balanceOf(address)` dispatches on
  the trailing-20-byte arg to return queue-bal vs the right pool's safe-bal. Register a PER-WAM `writeCap` closure
  that appends `(WAM_addr, payload)` so K5(f) per-silo routing is asserted (each WAM's `AddContractMock` gets its
  own capture). Registry mock: `allSiloIds()` → the id list; `getSilo(bytes32)` dispatches on the id arg to the
  matching 352-byte tuple.
- **P6 — citation accuracy:** the `ReceiverTemplate.onReport` gate is `:83-85` (forwarder) + `:88-93` (workflowId)
  — not `:83-92`. `buildRedeem`/`buildRepay` live in `workflow.go` (they wrap the `cre/zipreport` encoders).
- **P7 — no regression:** `onWarehouseOp` (http) + `onFundingTick` (cron) bytes-for-bytes unchanged except K2's
  one-line `SolverEnabled` no-op guard at the top of `onFundingTick`. All existing tests stay green.

## OPEN notes (logged, not owed)
- **Registry has no `warehouseAdminModule` field** — the silo→WAM binding is config (`cfg.Warehouses`) joined by
  `warehouseSafe`. A future hardening could add the field to the `Silo` struct for on-chain authority (low
  priority; not back-pressure — the WAM is deliberately off-registry CRE plumbing).
- **Utilization-balancing + curator/priority split** — the dynamic upgrades over pro-rata (own-later).
- **CTR-14 (N junior Safes vs single-requester queue)** — the multi-Safe escrow sequencing is a separate
  contract-side question; this solver writes only REDEEM/REPAY (no escrow leg), so it is unaffected.
