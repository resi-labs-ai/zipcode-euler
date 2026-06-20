# CRE-02b — redemption funding automation (the reserve-gated self-sizing REDEEM→REPAY leg)

> **Build ticket** (supersedes the scoping draft). Spec: `claude-zipcode.md` §6.1 / §8.2 / §8.3 / §8.5 / §11.
> Depends on: CRE-02 (the reactive (K) `RedemptionJob` — DONE), CRE-04 (`cre/warehouse`, the REDEEM/REPAY (R)
> producer — DONE), CRE-05a (`cre/buyburn-bid`, the resting-bid sizing twin — DONE, the read/size/write idiom).
> **Ships default-OFF / unactivated** (a `fundingEnabled` flag defaulting false; manual ops POSTs remain the M1
> path). The cycle is idempotent/self-healing, so a manual or partial firing is always safe.

## The fork is RESOLVED — option (b), fold into `cre/warehouse`. And it is FORCED, not merely preferred.
`WarehouseAdminModule` extends `ReceiverTemplate`, which pins **exactly one** `expectedWorkflowId`
(`out/ReceiverTemplate.sol/ReceiverTemplate.json` — `getExpectedWorkflowId()`/`setExpectedWorkflowId(bytes32)`,
a single slot). A report whose author/workflow-id is not the pinned one is rejected (`onReport` fail-closed). So a
*separate* CRE-02b workflow **cannot** `WriteReport` to the warehouse — only the workflow whose id is pinned can,
and that is `cre/warehouse` (CRE-04). Therefore the sizing must live **inside `cre/warehouse`** (option b), as
CRE-04's own `observe` docstring already anticipated ("the §8.5 on-chain NAV sizing is the documented production
replacement of the mock `observe`"). Option (a)'s separate orchestrator would add an HTTP-ingress hop **and** a
second deployable that still has no write authority — strictly worse. This matches CRE-05a (`cre/buyburn-bid`),
which reads reservoir/coverage/price on-chain, sizes, and writes — all in one workflow.

## Deliverable
Add to `cre/warehouse/` a **new, default-OFF, cron-driven funding handler** (`onFundingTick`) **alongside** the
existing `http.Trigger` event handler (`onWarehouseOp`, CRE-04 — UNCHANGED, the manual-ops path). The new handler
reads the reserve-gated availability + the redemption shortfall on-chain (DON mode, the `buyburn-bid` read idiom),
sizes a REDEEM (EE shares) and/or a REPAY (USDC → queue), and emits the matching report(s) via the EXISTING
`cre/warehouse` build/write path (`buildRedeem`/`buildRepay` → `writeReport`, which already encode through
`cre/zipreport`). No new report transport, no new encoder, no contract change.

## Spec §
- **§8.5** — the senior-warehouse ops (SUPPLY/APPROVE/**REDEEM**/**REPAY**); the on-chain NAV-sizing hook.
- **§8.2** — the donation-immune free-reservoir read (`maxWithdraw(warehouseSafe)`, NOT `IERC20.balanceOf`).
- **§8.3 / §6.1** — the senior par-redemption flow the funding feeds (CRE-02's `RedemptionJob` settles/claims it).
- **§11 / §6.3** — the duration/coverage squeeze: utilization is also the freeze variable; size THROUGH the
  reserve/coverage gate, never around it.

## Binds to (all VERIFIED this window — no back-pressure)
Every **address slot for warehouse/EE/USDC/queue** is read **off the warehouse adapter** (re-pointable, §17) —
NOT a fresh Config address, NOT hardcoded. **EXCEPTION:** the `coverageGate` is Config-sourced — the warehouse
adapter has no `covered()`/gate getter, so the gate address rides Config (the `buyburn-bid` idiom: zero ⇒ treat
covered). The new Config beyond CRE-04's is the funding policy (enable/schedule/reserve split/cap) **plus**
`coverageGate`.

- `cre/warehouse` build/write path (REUSE, do not re-implement): `buildRedeem(WarehouseOp)` →
  `zipreport.WhRedeemReport(shares)`; `buildRepay(WarehouseOp)` → `zipreport.WhRepayReport(dest, amount)`;
  `writeReport(cfg, runtime, envelope)`. (`cre/warehouse/workflow.go:180,192,252`.)
- **Warehouse adapter getters** (`WarehouseAdminModule.sol:49-55`, all `address public`): `warehouseSafe()`,
  `eePool()`, `usdc()`, `redemptionBox()`. **`redemptionBox == queue`** — pinned at deploy
  (`script/DeployZipcode.s.sol:278` "redemptionBox == queue (seam #6)"), so `redemptionBox()` is BOTH the REPAY
  `dest` AND the queue to read the shortfall from. One address, no extra slot.
- **Free reservoir (§8.2, donation-immune):** `eePool.maxWithdraw(warehouseSafe)` — the exact read
  `buyburn-bid`/FE-08 use (`cre/buyburn-bid/workflow.go:133`). EulerEarn is an ERC-4626 vault; `maxWithdraw(address)`
  exists on the deployed contract (the minimal `IEulerEarn.sol` stub omits it, but `buyburn-bid` already binds it
  live — confirmed precedent).
- **NAV share-sizing — use `convertToAssets` + `balanceOf` ONLY** (both in `IEulerEarn.sol:17,19`; no dependency on
  `convertToShares`, which the stub omits): `totalShares = eePool.balanceOf(warehouseSafe)`;
  `navAssets = eePool.convertToAssets(totalShares)`; `redeemShares = redeemAssets * totalShares / navAssets`
  (integer floor → redeems marginally LESS than the target USDC; conservative, never over-redeems). Guard
  `navAssets > 0 && totalShares > 0`, else skip REDEEM.
- **Shortfall (CRE-02's reads):** `queue.totalPending()`, `queue.scaleUp()`, `queue.reservedAssets()`,
  `usdc.balanceOf(queue)` — all proven live in `cre/keeper/internal/job/redemption_job.go:80-110`.
- **Coverage gate:** `covered()` on the `CoverageGate` (DurationFreezeModule / ICoverageGate); a **zero/unset gate
  address ⇒ treat `covered() = true`** (the `buyburn-bid` idiom, `workflow.go:122-128`). `!covered ⇒ floor = 0`.
- **Reserve split (CRE-06 constants, Config):** `harvestReserve`, `safetyBuffer` (6-dp USDC, base-10 strings) —
  same names/shape as `buyburn-bid` Config. Plus a funding `buybackCap`-analog ceiling `maxRedeemPerTick` (6-dp,
  optional; 0 = uncapped by this knob, still capped by `avail` + shortfall).
- **SDK reads:** clone the `buyburn-bid` DON-mode read helpers (`readUint`/`readBool`/`readUintWithAddr`/
  `readAddr` + `call`/`selector`/`decodeUint`) into a `cre/warehouse` reads file — `cre/warehouse` currently has
  NO on-chain reads (pure encoder). `evm.Client.CallContract`, `WriteCreReportRequest`, `cron.Trigger` all resolve
  in the in-tree `reference/cre-sdk-go` (the DEP SEAM `replace` already in `cre/warehouse/go.mod`).

## The sizing policy (one tick of `onFundingTick`)
Utilization `U` is **not read via a bespoke getter** — it is captured by `maxWithdraw(warehouseSafe)` through the
reserve math: high `U` (more lent out / less free) ⇒ small `maxWithdraw` ⇒ small floor; `!covered` ⇒ floor 0.
**This is the resolution of the "verify the exact `U` getter" open item — there is no separate `U` getter, and
introducing one would fight the freeze over the same cash (the load-bearing caution).** State it as a FINDING.

Per tick (all reads re-read live, §17; stateless/idempotent like `RedemptionJob`):
1. `fundingEnabled == false` (default) ⇒ **no-op, no writes** (read nothing or read-and-skip; the gate is the test).
2. Resolve `warehouseSafe`/`eePool`/`usdc`/`queue(=redemptionBox)` off the warehouse adapter. Any zero ⇒ no-op.
3. `scaleUp == 0` ⇒ no-op (malformed/unwired queue; mirrors `RedemptionJob`).
4. `shortfall = max(0, totalPending/scaleUp − (usdc.balanceOf(queue) − reservedAssets))`. `shortfall == 0` ⇒ no
   funding (settle/claim is CRE-02's job; nothing to fund). *(Use the same `freeUsdc = bal − reserved` floored-at-0
   as `RedemptionJob:125-128`.)*
5. **REPAY leg** (drain already-delivered Safe USDC toward the queue): `safeUsdc = usdc.balanceOf(warehouseSafe)`;
   `repayAmt = min(safeUsdc, shortfall)`. If `repayAmt > 0` ⇒ emit REPAY `{dest: queue, amount: repayAmt}`.
   **REPAY is NOT gated on coverage** — it moves cash the warehouse already holds to settle pending obligations; it
   does not touch EE shares / the reservoir, so it is safe even when undercovered.
6. **REDEEM leg** (top up the Safe for the shortfall the Safe can't yet cover), **gated on the reserve/coverage
   floor**: `avail = clamp(maxWithdraw(warehouseSafe) − harvestReserve − safetyBuffer, 0, maxRedeemPerTick)`
   (the buyburn-bid `clamp`; `maxRedeemPerTick==0` ⇒ no upper clamp). `floor = covered ? avail : 0`.
   `redeemAssets = min(shortfall − repayAmt, floor)`. If `redeemAssets > 0` and `navAssets>0 && totalShares>0` ⇒
   `redeemShares = redeemAssets * totalShares / navAssets`; if `redeemShares > 0` emit REDEEM `{shares}`.
7. **Order: REPAY then REDEEM** — deliver what we have now, then refill for next tick (they target different cash;
   each is sized off pre-tick reads, so order is for clarity/abort-safety, not correctness). Two ops ⇒ up to two
   sequential `writeReport` Awaits in the one handler (the `buyburn-bid` cancel-then-post idiom,
   `workflow.go:170-176`). A write error is returned (surface it; §8.5 posture).

Across ticks this converges: REDEEM tops the Safe up to (shortfall, floor); next tick REPAY drains it to the queue;
CRE-02's `RedemptionJob` then `settleEpoch`s + `claim`s. Starved reservoir / undercovered ⇒ `floor=0` ⇒ REDEEM
shrinks to nothing (never over-redeems); REPAY of existing cash still proceeds.

## Do NOT
- Do **not** read a bespoke utilization getter or invent a separate floor knob (the load-bearing caution — it would
  drain the cash the harvest loop + freeze floor need). Derive the floor through `maxWithdraw` + `harvestReserve`/
  `safetyBuffer` + `covered()` ONLY.
- Do **not** use `IERC20.balanceOf(eePool)` for the reservoir (donation-spoofable) — use `maxWithdraw(warehouseSafe)`.
- Do **not** re-implement the §8.5 envelope or any payload encode — call the existing `buildRedeem`/`buildRepay`/
  `writeReport`. Do **not** touch `onWarehouseOp` / `observe` / the http path (CRE-04 stays intact).
- Do **not** depend on `convertToShares` (stub omits it) — derive shares from `convertToAssets`+`balanceOf`.
- Do **not** sweep the Safe's FULL USDC to the queue — bound REPAY by `shortfall` (avoid moving non-redemption cash).
- Do **not** make the funding handler pre-check Safe balance / Roles scope / on-chain reverts beyond the sizing
  guards — anticipated reverts (EE cap, Roles `ParameterNotAllowed`, `WrongRedemptionBox`) are on-chain backstops;
  surface a write error (the CRE-04 posture).
- Do **not** add cross-tick state (no EMA, no stored target) — stateless reactive sizing only (M1).

## Key requirements
- K1. New `onFundingTick(cfg, runtime, *cron.Payload)` registered in `initFn` alongside the existing http handler;
  both belong to the same pinned workflow id so both write under the warehouse's pinned author.
- K2. Config gains: `fundingEnabled bool` (default false), `fundingSchedule string` (cron), `coverageGate string`,
  `harvestReserve string`, `safetyBuffer string`, `maxRedeemPerTick string`. Existing CRE-04 fields unchanged.
  (No new ADDRESS slots for safe/eePool/usdc/queue — read them off the warehouse adapter.)
- K3. `fundingEnabled == false` ⇒ the funding handler emits ZERO reports (default-OFF ship posture).
- K4. The floor is reserve/coverage-gated: `!covered` OR starved reservoir (`avail ≤ 0`) ⇒ REDEEM sized to 0.
- K5. REPAY bounded by `min(safeUsdc, shortfall)`; REDEEM `redeemAssets = min(shortfall − repayAmt, floor)`,
  `redeemShares` floored conservative; both skipped when 0 (no wasted writes).
- K6. The sized REDEEM `shares` round-trips through the EXISTING `WhRedeemReport` handshake to the contract's
  `(uint256 shares)`; the REPAY through `WhRepayReport` to `(address dest, uint256 amount)`. (Reuse — already
  byte-pinned by CRE-04's tests; the funding test asserts the SIZING, not the encode.)

## Done when
- `cd cre/warehouse && go build ./... && go vet ./... && go test -count=1 ./...` green, plus
  `GOOS=wasip1 GOARCH=wasm go build ./...` exit 0.
- A **non-vacuous** sizing test proves, against a simulated backend with mocked `eth_call` replies:
  (1) `fundingEnabled=false` ⇒ zero reports; (2) `!covered` (or starved reservoir) ⇒ floor 0 ⇒ no REDEEM (REPAY of
  existing Safe USDC may still fire); (3) shortfall fully covered by Safe USDC ⇒ REPAY only, no REDEEM;
  (4) shortfall > Safe USDC, covered, reservoir ample ⇒ REPAY(safeUsdc) + REDEEM with `redeemShares` matching the
  `convertToAssets`-ratio sizing for `min(shortfall−repay, floor)`; (5) `maxRedeemPerTick` clamps the redeem;
  (6) `shortfall==0` ⇒ no-op. Decode the captured report bytes to assert op + sized scalars (not just count).
- The CRE-04 http path tests still pass unchanged (the funding handler is additive).
- Doc-sync: no contract changed ⇒ no backward `wires/` edit; forward `claude-zipcode.md` §8.5 gains a
  "(BUILT — CRE-02b funding leg, default-OFF)" note; `PROGRESS.md` CRE-02b obligation marked BUILT/default-OFF and
  the open fork recorded RESOLVED→(b). The DEPLOY OBLIGATION (`redemptionBox==queue`, keeper signer identity) and
  CRE-02c (cross-silo solver) remain open/owed.

## Critic-tightened build pins (close before cold-build — zero load-bearing guesses)
The 4-critic fan-out (junior-dev / spec-fidelity / reference-verifier / cre-binding) returned spec-fidelity =
FAITHFUL and cre-binding = byte-exact / dimensionally sound (NO mismatches). These pins close the junior-dev +
reference-verifier ticket gaps so the cold-build guesses nothing:

- **P1 — two handlers = ONE workflow id (the option-(b) premise, DEMONSTRATED).** A `cre.Workflow[*Config]{}`
  registers multiple `cre.Handler`s in one binary; the workflow id is per deployed binary, not per handler.
  Precedent: `cre/buyburn-bid/workflow.go:75-79` returns a Workflow with TWO handlers (`cron.Trigger`+`evm.LogTrigger`).
  So `initFn` returns:
  `cre.Workflow[*Config]{ cre.Handler(httpcap.Trigger(&httpcap.Config{}), onWarehouseOp), cre.Handler(cron.Trigger(&cron.Config{Schedule: cfg.FundingSchedule}), onFundingTick) }`.
  Both handlers write under the warehouse's single pinned `expectedWorkflowId`. (If, against expectation, the
  http+cron pairing fails to compile/simulate, that is back-pressure — log it; do NOT split into a second binary,
  which the `ReceiverTemplate` single-id pin forbids.)
- **P2 — add the cron module to `cre/warehouse/go.mod`** (currently http-only; CRE-04's comment says "no cron
  heartbeat" — UPDATE it). Mirror `buyburn-bid/go.mod:9,29`: add `require .../capabilities/scheduler/cron v0.9.0`
  + `replace github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron => ../../reference/cre-sdk-go/capabilities/scheduler/cron`.
  Then `go mod tidy`.
- **P3 — `fundingEnabled == false` ⇒ `onFundingTick` returns immediately BEFORE any `CallContract`** (zero reads,
  zero writes; the disabled-case test then needs zero eth_call mocks). This is the default ship posture.
- **P4 — queue/EE reads use the CLONED `buyburn-bid` DON-mode helpers, NOT the keeper's `chain` pkg.** The
  `redemption_job.go:80-110` references are for the read *semantics/units only* (a different module, `cre-keeper`,
  that won't compile here). Clone `readUint`/`readBool`/`readUintWithAddr`/`call`/`selector`/`decodeUint` from
  `buyburn-bid/workflow.go` into a new `cre/warehouse` reads file. `totalPending()`/`scaleUp()`/`reservedAssets()`
  → `readUint`; `balanceOf(address)`/`maxWithdraw(address)` → `readUintWithAddr`; `covered()` → `readBool`.
- **P5 — `readAddr` is NEW, not a clone** (buyburn-bid reads no addresses). Write it: `call(...)` the no-arg
  getter, then `abi.Arguments{{Type: addressT}}.Unpack(data)` → `common.Address`. Use it for the four adapter
  getters `warehouseSafe()`/`eePool()`/`usdc()`/`redemptionBox()`.
- **P6 — reuse `buildRedeem`/`buildRepay` by constructing a string-field `WarehouseOp`**, NOT by passing
  `*big.Int`. They consume the carrier (`workflow.go:67-72,180,192`): set `WarehouseOp{Op:"redeem", Shares: redeemShares.String()}`
  and `WarehouseOp{Op:"repay", Dest: queue.Hex(), Amount: repayAmt.String()}`, then call the existing builder.
  (Or call `zipreport.WhRedeemReport`/`WhRepayReport` directly — either is fine; the carrier route reuses CRE-04's
  validation.)
- **P7 — units, PINNED (cre-binding-confirmed, state as load-bearing assumptions):** `scaleUp = 1e12`
  (= 10^(18−6)); `totalPending` is 18-dp zipUSD, so `totalPending/scaleUp` is **6-dp USDC** — directly comparable
  to `usdc.balanceOf`/`reservedAssets` (matches `ZipRedemptionQueue.sol:203-204` + `redemption_job.go:133-138`).
  EE's asset is USDC, so `convertToAssets` returns **6-dp USDC**; in `redeemShares = redeemAssets·totalShares/navAssets`
  the (18-dp shares)/(6-dp USDC) ratio × 6-dp USDC → 18-dp shares with no hardcoded `1e12` — units cancel through
  the ERC-4626 rate. Integer floor ⇒ conservative (redeems ≤ target). Guard `navAssets>0 && totalShares>0`.
- **P8 — test mock selector list (mirror buyburn-bid's `AddContractMock`/`eth_call` map).** The funding-sizing
  test registers replies for, keyed by `(to, selector)`: on the warehouse adapter — `warehouseSafe()`/`eePool()`/
  `usdc()`/`redemptionBox()`; on eePool — `maxWithdraw(warehouseSafe)`, `convertToAssets(totalShares)`,
  `balanceOf(warehouseSafe)`; on usdc — `balanceOf(queue)`, `balanceOf(warehouseSafe)`; on queue —
  `totalPending()`/`scaleUp()`/`reservedAssets()`; on coverageGate — `covered()`. (`convertToShares` is NOT
  mocked — unused.)
- **P9 — test decode path.** The captured report is `runtime.GenerateReport(EncoderName:"evm")` over the §8.0
  envelope `abi.encode(uint8 opType, bytes payload)`. To assert the sized scalars: unpack the envelope to
  `(uint8, bytes)`, then the payload — REDEEM → `(uint256 shares)`, REPAY → `(address dest, uint256 amount)`.
  Model the decode on CRE-04's `TestSimRedeemHandshake`/`TestSimRepayHandshake` (`cre/warehouse/workflow_test.go:173,193`),
  which already `abi.Unpack` a captured warehouse report to those exact tuples.

## Depends on
CRE-02 (DONE), CRE-04 (DONE), CRE-05a (DONE — read/size/write idiom). No contract dependency; no anvil (gate is
`go build`/`go test` + simulated backend).
