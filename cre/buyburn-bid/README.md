# cre/buyburn-bid — CRE-05a buy-burn bid-automation loop (Go → wasip1)

A self-contained `cre-sdk-go` `WriteReport` workflow that maintains the **single resting buy-burn bid** on the
post-CTR-01 `SzipBuyBurnModule` via the §8.0 report path. It is the exit half of CRE-05 (§8.7) + the CoW-exit
workstream item #1, and the first buildable CRE workflow in this tree (also establishes the minimal CRE scaffold).

## What it does (the control loop — single resting bid)

Two triggers, one body (`evaluateAndReconcile`): a `cron` heartbeat and an `evm.LogTrigger` on
`ZipRedemptionQueue.RedemptionSettled` (more USDC freed → resize). Each tick:

1. **Reads** (view `CallContract`, decode the return): `currentBid()` → `(bytes uid, uint256 sellAmount)`;
   `quoteMaxPrice()`, `buybackCap()` on the module; `fresh()`, `maxAge()`, `oldestRequiredLegTs()` on
   `SzipNavOracle`; `covered()` on the coverage gate (skipped → `true` when the gate is the zero address);
   `maxWithdraw(warehouse)` on `EulerEarn` (the donation-immune §8.2 free-reservoir read).
2. **Size:** `targetSell = clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)` (6-dp USDC).
3. **Price:** `maxPrice = quoteMaxPrice()`; if `0` ⇒ skip. Else `targetBuy = ceilDiv(targetSell·1e18, maxPrice)`
   (ceil so the implied price ≤ `maxPrice` and the on-chain `BidAboveDiscount` bound passes).
4. **`validTo`** (defensive, fail-closed-by-skipping): `min(now+ttl, oldestRequiredLegTs+maxAge, now+86400)`. If
   `≤ now` (legs too stale) ⇒ skip posting.
5. **Reconcile** (single-resting-bid): `postable = targetSell>0 && fresh && covered && maxPrice>0 && validTo>now`.
   - No live bid + `postable` ⇒ `POST_BID`.
   - Live bid + `!postable` ⇒ `CANCEL_BID`.
   - Live bid + size drift ≥ `driftBps` ⇒ `CANCEL_BID` then `POST_BID` (sequential `Await`s — the module's
     `BidAlreadyLive` requires cancel-before-repost; they cannot be atomic).
   - Otherwise no-op.

The only write is `WriteReport` (the report path). No raw/keeper tx, no operator key, no second resting bid, no
off-chain NAV/APR.

## BUILD BOUNDARY

**PINNED EXACT — the §8.0 contract handshake (must byte-match `SzipBuyBurnModule._processReport`):**
- Envelope: `abi.encode(uint8 reportType, bytes payload)`.
- `POST_BID = 1`, `CANCEL_BID = 2` (receiver-scoped constants).
- POST_BID payload: `abi.encode(uint256 sellAmount, uint256 buyAmount, uint32 validTo)`.
- CANCEL_BID payload: empty `[]byte{}`.

The encode round-trip test (`TestPostBidEnvelopeRoundTrip` / `TestCancelBidEnvelopeRoundTrip`) asserts this layout
without a chain — it decodes back as `(uint8, bytes)` then `(uint256, uint256, uint32)`.

**CONFIG (`Config`, JSON):** the chain selector + the module / nav-oracle / coverage-gate / EulerEarn / warehouse /
redemption-queue addresses + `schedule` + `driftBps` + `ttlSeconds` + `harvestReserve` + `safetyBuffer`.

**CRE-06 folded in as config:** the exit-vs-harvest working-capital split is the `harvestReserve` + `safetyBuffer`
constants in the sizing step (M1 = constants; a dynamic, utilization-aware policy is a later parameter swap, not a
redesign). CRE-06 is therefore DISCHARGED-as-config by CRE-05a.

**DEFERRED:** the CoW `Trade` fill log-trigger (phase-2; for MVP a fill is detected as a `currentSellAmount` drop on
the next tick); the dynamic reserve policy.

**Deploy obligation (CTR-01):** the module must have `setForwarder` + `setExpectedWorkflowId(thisWorkflowId)` wired
for this workflow's reports to be accepted live.

## Layout / SDK notes

- `main.go` — `//go:build wasip1` entrypoint (`wasm.NewRunner` is wasip1-bound, so `main()` is tagged).
- `workflow.go` — the untagged control-loop logic (builds + tests on the host).
- `main_test.go` — encode round-trip + sizing units (`clamp`/`ceilDiv`/`validTo`/`sizeDriftBps`) + the simulated
  run (mocked reads via `evmmock.AddContractMock`, writes captured via the `writeReport` callback).
- `go.mod` pins to the in-tree `reference/cre-sdk-go` snapshot via `replace` (C7 permits this; the published
  releases predate `WriteCreReportRequest` (C1), `testutils.SetTimeProvider`, and the `EthereumMainnetBase1`
  selector this workflow + its tests use).

### Deviation from C6
go-ethereum v1.17.2's `abi.Pack` requires a **native `uint32`** for a `uint32` arg and rejects the
`new(big.Int).SetUint64(...)` form C6 pinned (against an older abi). The produced ABI bytes are identical; the
`(uint256,uint256,uint32)` layout — the load-bearing handshake — is unchanged. See `encodePostBidPayload`.

## Gate

```
cd cre/buyburn-bid
GOOS=wasip1 GOARCH=wasm go build ./...   # exits 0
go test ./...                            # green
```
