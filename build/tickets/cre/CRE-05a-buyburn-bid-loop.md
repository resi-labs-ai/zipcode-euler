# CRE-05a — Buy-burn bid-automation loop (Go → wasip1)

> CRE-track workflow. The exit half of spec CRE-05 (§8.7) + the driver's CoW-exit workstream item #1
> (`build/CoW.md` / `build/CoW-exit.md`). UNBLOCKED by CTR-01 (2026-06-16): `SzipBuyBurnModule` now carries a CRE
> report socket, so this is a real `cre-sdk-go` `WriteReport` workflow (not a keeper / not blocked on the
> operator-path seam). Spec: `claude-zipcode.md` §8.0 (envelope) / §8.7 (operator path + the CTR-01 exception) /
> §8.6 (read-cadence patterns).

## Deliverable
A self-contained Go module `cre/buyburn-bid/` (the FIRST buildable CRE workflow — also establishes the minimal
CRE scaffold: `go.mod` wiring `reference/cre-sdk-go` + its `capabilities/{blockchain/evm,scheduler/cron}`
sub-modules + go-ethereum):
- `cre/buyburn-bid/go.mod` — module + the cre-sdk-go deps (model the version pins on
  `reference/cre-templates/starter-templates/*/workflow-go/go.mod`; `replace` to `../../reference/cre-sdk-go`
  + its capability sub-module dirs is acceptable to build offline-of-registry if proxy fetch is undesired).
- `cre/buyburn-bid/main.go` — the wasip1 workflow (model the WriteReport + envelope-encode shape on
  `cre/szalpha-rate/main.go`, which is the proven §8.0-envelope template).
- `cre/buyburn-bid/main_test.go` — the table-driven encode round-trip + the simulated run (below).
- `cre/buyburn-bid/README.md` — the BUILD BOUNDARY note (like szalpha-rate's): what is pinned exact (the
  POST_BID/CANCEL_BID handshake), what is config, what is deferred.

## What the workflow does (the control loop — single resting bid)
1. **Triggers:** (a) `cron.Trigger(&cron.Config{Schedule})` heartbeat; (b)
   `evm.LogTrigger(chainSelector, &evm.FilterLogTriggerRequest{...})` on `ZipRedemptionQueue.RedemptionSettled`
   (more USDC freed → resize). Each handler runs the same evaluate-and-reconcile body. (A CoW `Trade` fill log
   trigger is a phase-2 refinement; for MVP a fill is detected as a `currentSellAmount` drop on the next tick.)
2. **Reads (all `evmClient.CallContract`, view; ABI-encode the selector + args, decode the return):**
   - `SzipBuyBurnModule.currentBid()` → `(bytes uid, uint256 sellAmount)` — the live bid (empty uid ⇒ none).
   - `SzipBuyBurnModule.quoteMaxPrice()` → `uint256` (6-dp USDC ceiling per 1e18 share; already folds
     `navExit × (1−dBps)`).
   - `SzipBuyBurnModule.buybackCap()` → `uint256`; `dBps()` → `uint16` (sanity / kill-switch read).
   - `SzipNavOracle.fresh()` → `bool`; `maxAge()` → `uint256`; `oldestRequiredLegTs()` → `uint48` (for the
     defensive `validTo`, below).
   - coverage gate `covered()` → `bool` (the `DurationFreezeModule`; address from config — skip the read /
     treat as `true` only if the configured gate is the zero address).
   - free farm utility + utilization off `EulerEarn`: `maxWithdraw(warehouse)` → `uint256` (6-dp USDC freeable
     NOW = the free farm utility) and `convertToAssets(balanceOf(warehouse))` → `uint256` (the warehouse senior
     position) for `U = 1 − maxWithdraw/convertToAssets`. **`freeReservoir = maxWithdraw(warehouse)`.** (Read the
     same donation-immune way §8.2 mandates — NOT `IERC20.balanceOf(eulerEarn)`.)
3. **Size (the CRE-06 split folded in here — see Decision):**
   `targetSell = clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)` (6-dp USDC), where
   `harvestReserve` + `safetyBuffer` are **Config constants** (the exit-vs-harvest working-capital reserve).
4. **Price:** `maxPrice = quoteMaxPrice()`; if `maxPrice == 0` ⇒ skip (no fresh mark). Else
   `targetBuy = ceilDiv(targetSell × 1e18, maxPrice)` (18-dp shares) — ceil so the implied price `≤ maxPrice`
   and the on-chain `BidAboveDiscount` bound passes. `ceilDiv(a,b) = (a + b − 1) / b`.
5. **`validTo` (defensive, fail-closed-by-skipping — avoid an on-chain revert):**
   `fence = oldestRequiredLegTs + maxAge`; `validTo = min(now + ttlSeconds, fence, now + 86400 /*MAX_BID_TTL*/)`.
   If `validTo <= now` (legs too stale to rest a bid) ⇒ skip posting.
6. **Reconcile (single-resting-bid):**
   - Let `postable = targetSell > 0 && fresh() && covered() && validTo > now`.
   - **No live bid** (`uid` empty): if `postable` ⇒ `WriteReport(POST_BID)`. Else no-op.
   - **Live bid:** compute `sizeDriftBps = |targetSell − currentSellAmount| × 10_000 / max(currentSellAmount,1)`.
     If `!postable` (kill / stale / undercovered / target 0) ⇒ `WriteReport(CANCEL_BID)`.
     Else if `sizeDriftBps >= driftBps` (Config) ⇒ `WriteReport(CANCEL_BID)` THEN `WriteReport(POST_BID)`
     (sequential `Await`s — the module's `BidAlreadyLive` requires cancel-before-repost; they cannot be atomic).
     Else no-op (bid still good).
7. **Writes (the report path — NOT the operator key):** `runtime.GenerateReport(&cre.ReportRequest{
   EncodedPayload: encodeEnvelope(POST_BID, encodePostBidPayload(sell, buy, validTo)), EncoderName:"evm",
   SigningAlgo:"ecdsa", HashingAlgo:"keccak256"})` → `evmClient.WriteReport(runtime, &evm.WriteReportRequest{
   Receiver: buyBurnModule.Bytes(), Report: report, GasConfig:{GasLimit}})`. CANCEL_BID = same with an EMPTY
   payload. The deployed module must have `setForwarder` + `setExpectedWorkflowId(thisWorkflowId)` (the CTR-01
   deploy obligation) so this workflow's reports are accepted.

## The §8.0 handshake (pinned EXACT — must byte-match the built `_processReport`)
- Envelope: `abi.encode(uint8 reportType, bytes payload)` — reuse szalpha-rate's `encodeEnvelope`.
- `POST_BID = 1`, `CANCEL_BID = 2` (the module's receiver-scoped constants — `SzipBuyBurnModule.sol`).
- POST_BID payload: `abi.encode(uint256 sellAmount, uint256 buyAmount, uint32 validTo)` →
  `SzipBuyBurnModule._processReport` does `abi.decode(payload,(uint256,uint256,uint32))` → `_postBid`.
- CANCEL_BID payload: empty `[]byte{}` (the contract ignores it).

## Binds to (verified)
- `SzipBuyBurnModule` (8-B14, post-CTR-01): `onReport` (Forwarder-gated), `_processReport` decode,
  `currentBid`/`quoteMaxPrice`/`buybackCap`/`dBps` views, `RedemptionSettled` is on `ZipRedemptionQueue`.
  Truth: `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` + `build/wires/8-B14-SzipBuyBurnModule.md`.
- `SzipNavOracle`: `fresh`/`maxAge`/`oldestRequiredLegTs`/`navExit` — `contracts/src/supply/SzipNavOracle.sol`.
- `EulerEarn`: `maxWithdraw`/`convertToAssets`/`balanceOf` (external; the §8.2 utilization read).
- `cre-sdk-go`: `capabilities/scheduler/cron.Trigger`, `capabilities/blockchain/evm.{Client.CallContract,
  LogTrigger,Client.WriteReport}`, `cre.{Workflow,Handler,Runtime,ReportRequest}`, `cre/wasm.NewRunner`.
  Paths under `reference/cre-sdk-go/`. Model: `cre/szalpha-rate/main.go`.
- Addresses for any fork test: `build/anvil/contract-map.md` + `build/anvil/abi/`.

## Do NOT
- Do NOT submit a raw/keeper tx — the only write is `WriteReport` (report path). Do NOT use the operator key.
- Do NOT ladder the bid / post a 2nd resting bid (single-resting-bid invariant — driver §4). One bid, repost on drift.
- Do NOT post when `!fresh()`, `!covered()`, `targetSell == 0`, or `validTo <= now` (the contract would revert;
  skip instead — liveness, fail-closed).
- Do NOT exceed `buybackCap` (the `clamp` upper bound handles it). Do NOT change any contract.
- Do NOT compute NAV/APR off-chain or push any precomputed value — read `quoteMaxPrice` (chain-derived).

## Decision recorded here (triage) — CRE-06 folds into this sizing
The driver left open whether the exit-vs-harvest capital split (CRE-06) is a standalone workflow or folds into
the bid sizing. **DECISION: fold it in** as the `harvestReserve` + `safetyBuffer` Config params in step 3 (M1 =
constants; a dynamic, utilization-aware policy is a later parameter swap, not a redesign). CRE-06 is therefore
DISCHARGED-as-config by CRE-05a, not a separate ticket. Record in PROGRESS at conclude.

## Implementation pins (cold-builder guesses NONE)
1. **go.mod/version pins:** copy the cre-sdk-go + capability module versions from a working
   `reference/cre-templates/starter-templates/*/workflow-go/go.mod`; ensure `capabilities/blockchain/evm` +
   `capabilities/scheduler/cron` are required. Confirm `GOOS=wasip1 GOARCH=wasm go build ./...` exits 0.
2. **Reads:** build calldata with go-ethereum `abi` (4-byte selector of e.g. `currentBid()` + packed args, none
   here) and `CallContract(runtime, &evm.CallContractRequest{Call:&evm.CallMsg{To: addr.Bytes(), Data: data}})`
   `.Await()` → decode the reply `.Data`. Model the exact call/decode on the evm package + a template; the
   selectors are the view names above. (`currentBid` returns `(bytes,uint256)` — decode both.)
3. **Encode:** `encodeEnvelope` + a new `encodePostBidPayload(sell,buy *big.Int, validTo uint32)` using
   `abi.Arguments{{u256},{u256},{u32}}.Pack(...)` (cre-binding verified this round-trips the Solidity decode,
   incl. the `uint32`). `validTo` packs as `new(big.Int).SetUint64(uint64(validTo))` into a `uint32` arg.
4. **Triggers:** two `cre.Handler(...)` entries in the `cre.Workflow` (cron + LogTrigger), both calling one
   shared `evaluateAndReconcile(cfg, runtime)` so heartbeat and event paths are identical.
5. **Tests (the gate):** use `cre/testutils.NewRuntime(t, ...)` + `capabilities/blockchain/evm/mock`
   (`NewClientCapability` + `AddContractMock(clientMock, addr, func(data) ([]byte,error))` to script each
   view's return) + the test report-capture (`cre/testutils/test_writer.go` / `TestRuntime.GetLogs`). Verify the
   exact mock + capture API in those files before writing (do not guess the helper names).

## Pin CORRECTIONS from the critic pass (these override anything above — verified in-tree)
- **C1 — the write type is `evm.WriteCreReportRequest`, NOT `evm.WriteReportRequest`.** `Client.WriteReport(runtime,
  input *evm.WriteCreReportRequest)` (`capabilities/blockchain/evm/client_sdk_gen.go:293`); construct
  `&evm.WriteCreReportRequest{Receiver: buyBurnAddr.Bytes(), Report: report, GasConfig: &evm.GasConfig{GasLimit:
  writeGasLimit}}` where `report` is the `*cre.Report` returned by `runtime.GenerateReport(req).Await()`.
  **`cre/szalpha-rate/main.go` uses `WriteReportRequest` — that is a LATENT BUG in a never-compiled stub; do NOT
  copy it verbatim.** Copy szalpha-rate's `encodeEnvelope` + the `ReportRequest{EncodedPayload, EncoderName:"evm",
  SigningAlgo:"ecdsa", HashingAlgo:"keccak256"}` shape only.
- **C2 — `AddContractMock` exact signature** (`capabilities/blockchain/evm/mock/utils.go:14`):
  `AddContractMock(address common.Address, clientMock *ClientCapability, callContract map[string]func(payload
  []byte) ([]byte, error), writeReport func(payload []byte, config *evm.GasConfig) (*evm.WriteReportReply,
  error))`. The `callContract` map is keyed by the **4-byte selector** (`string(methodID)`); each value receives
  the calldata-minus-selector and returns the ABI-packed view result. **WriteReport is captured/asserted via the
  `writeReport` callback** (record the `payload` it is handed) — NOT `TestRuntime.GetLogs()` (that is for `log()`).
- **C3 — reads:** `CallContract(runtime, &evm.CallContractRequest{Call: &evm.CallMsg{To: addr.Bytes(), Data:
  selectorPlusArgs}}).Await()` → decode `reply.Data`. `From` may be left nil for views. Decode a `(bytes,uint256)`
  return (`currentBid`) with `abi.Arguments{{Type: bytesT},{Type: u256}}.Unpack(reply.Data)`.
- **C4 — two triggers, two callbacks, one body:** `cre.Workflow[Config]{ cre.Handler(cron.Trigger(&cron.Config{
  Schedule: cfg.Schedule}), onCron), cre.Handler(evm.LogTrigger(cfg.ChainSelector, filter), onLog) }`. The
  callbacks differ in payload type (`*cron.Payload` vs `*evm.Log`); both immediately call a shared
  `evaluateAndReconcile(cfg Config, runtime cre.Runtime)`.
- **C5 — `RedemptionSettled` topic0:** read the REAL event signature from
  `contracts/src/supply/ZipRedemptionQueue.sol` and compute `topic0 = keccak256(canonicalSig)`; populate the
  `evm.FilterLogTriggerRequest` `Addresses = [queueAddr.Bytes()]` + `Topics[0] = [topic0]` (verify the exact
  field names/shape in `client.pb.go` — do not guess). (The CRE-02 ticket's 6-arg prose is stale; the contract wins.)
- **C6 — `validTo` uint32 pack:** `abi.Arguments{{u256},{u256},{u32}}.Pack(sell, buy, new(big.Int).SetUint64(uint64(validTo)))`.
- **C7 — go.mod:** model versions on a working `reference/cre-templates/starter-templates/*/workflow-go/go.mod`;
  registry fetch via the default proxy WORKS here (verified — a template builds `wasip1` clean). `replace`
  directives to the local `reference/cre-sdk-go` are OPTIONAL (use only if pinning to the in-tree SDK is desired).

## Done when (the gate — CRE track, per harness)
- `cd cre/buyburn-bid && GOOS=wasip1 GOARCH=wasm go build ./...` exits 0 (wasip1 target).
- `go test ./...` green, including:
  - **Encode round-trip (load-bearing handshake):** `encodeEnvelope(POST_BID, encodePostBidPayload(s,b,v))`
    decodes back via go-ethereum abi as `(uint8, bytes)` then `(uint256,uint256,uint32)` == `(POST_BID, s,b,v)`;
    CANCEL_BID round-trips as `(uint8 2, empty bytes)`. This is the exact layout the built `_processReport`
    decodes (asserts the contract handshake without a chain).
  - **Simulated run:** with mocked reads, the workflow (a) emits ONE POST_BID `WriteReport` to the buy-burn
    module address with the expected report bytes when there is no live bid and `freeReservoir` funds a bid;
    (b) emits CANCEL_BID then POST_BID when a live bid's size drift ≥ `driftBps`; (c) emits CANCEL_BID alone
    when `!covered()` / `!fresh()` / `targetSell==0`; (d) emits NOTHING when a live bid is still within drift.
  - **Sizing unit tests:** `clamp` + `ceilDiv` + the defensive `validTo` (incl. the stale-legs skip).
- Zero load-bearing guesses; the Go module committed to `cre/buyburn-bid/`.

## Depends on / unblocks
- **Depends on:** CTR-01 (the report socket — DONE). The CTR-01 deploy obligation (`setForwarder` +
  `setExpectedWorkflowId` on the module) must be wired for the workflow's reports to be accepted live.
- **Unblocks / informs:** the FE NAV exit-book page reads this loop's `currentBid` (driver item #3); the rest of
  CRE-05 (the harvest engine legs) once those modules get the socket or a keeper (the systemic seam in PROGRESS).
