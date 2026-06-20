# CRE-03 — the szipUSD share-price feeds producer (NAV_LEG + LP_MARK, reportType 7)

> **Track:** (R) — a wasip1 CRE report-path workflow (CRE-OPS-ROUTING: CRE-03 is pure (R) through existing
> receivers; no new contract, off-chain Go only → **NO backward `wires/` edit owed**). It imports the shared
> `cre/zipreport` library (CRE-00) for the two encoders; it does NOT re-implement the handshake.
>
> **Scope narrowed vs the §8.11 CRE-03 row.** The row reads "NAV_LEG + LP_MARK + the xALPHA-APR feed." Per the
> inversion (harness §1) the as-built contracts rule the interface, and they say the **APR is DERIVED on-chain**
> (`SzAlphaRateOracle.intrinsicAprBps()`, §8.8) — **never pushed**. The only pushed xALPHA primitive is the raw
> `RATE` (reportType 8), whose producer is the SEPARATE, pre-existing `cre/szalpha-rate/` (the 8x-02 bridge
> workflow), which is **blocked on R-1** (proving CRE can read the Subtensor-964 `0x805` precompile) and lives on
> the bridge track. So **CRE-03 here = the two coupled Base-side push-cache feeds only** (NAV_LEG + LP_MARK),
> which §8.6 mandates be produced **from one computation** for coherence. The RATE/APR leg is explicitly out of
> scope (see "Do NOT" + the PROGRESS flag). This is a FINDING logged at Conclude, not a silent re-scope.

---

## Deliverable
A committed Go module at **`cre/sharefeeds/`** (monorepo `cre/` — harness §3) that compiles to `wasip1` and
implements the **szipUSD share-price push-cache producer** (§8.6): on the engine epoch it reaches **identical
consensus** on the two off-chain leg marks it cannot read on Base (`alphaUSD`, `HYDX/USD`), reads every on-chain
quantity it CAN read (the ICHI LP reserves + total supply, the xALPHA `exchangeRate()`) via DON-mode `eth_call`,
composes **one coherent computation**, and emits **two `WriteReport`s**:

1. **NAV_LEG → `SzipNavOracle`** — `abi.encode(uint8 reportType=7, abi.encode(uint8[] legs, uint256[] prices,
   uint32 ts))`, `legs = [LEG_ALPHA_USD=0, LEG_HYDX_USD=1]`, `prices = [alphaUSD_18dp, hydxUsd_18dp]` (both
   `1e18 = $1`). Encoded via `zipreport.NavLegReport`.
2. **LP_MARK → `SzipReservoirLpOracle`** — `abi.encode(uint8 reportType=7, abi.encode(uint256 mark, uint32 ts))`,
   `mark` = the per-LP-share value in **quote-native USDC 6-dp** (`$1000/share == 1_000e6`). Encoded via
   `zipreport.LpMarkReport`.

**Coherence requirement (§8.6, load-bearing):** the `alphaUSD` used to price the xALPHA NAV leg and the
`alphaUSD` used inside the LP-mark reserve valuation MUST be the SAME (post-band-clamp) value, computed once per
tick. The two feeds converge together; they never diverge mid-move.

## Spec §
- **§8.6** "szipUSD share-price feeds (NAV legs + LP mark — the push-cache producers)" — the producer runbook
  this slice implements verbatim. Pin points: the two receivers + payloads; `legs ∈ {0,1}`; the LP mark formula
  `(reserve_xALPHA × priceXAlpha + reserve_zipUSD × priceZipUSD) / ICHI_LP_totalSupply`; "produce them from one
  computation"; the NAV per-push **deviation circuit-break** (`maxDeviationBps`) → "push intermediate marks, or
  the band rejects it"; the LP feed is liveness-only (fail-closed on stale, never opens an unsafe borrow);
  cadence = engine epoch + material leg move.
- **§7** — the leg definitions the producer must honor: `alphaUSD` = the subnet **TAO/alpha AMM TWAP × TAO/USD**
  (the two-layer mark, input 2); the on-chain xALPHA `exchangeRate()` (LST stake-accounting, non-manipulable) is
  read trustlessly and multiplied IN BY THE CONTRACT — the producer pushes only `alphaUSD` (per-1.0-ALPHA), NOT
  per-xALPHA. HYDX = pool TWAP; oHYDX intrinsic is derived on-chain (`HYDX × (1−discount)`). The ICHI LP marks at
  true reserve value (IL marked-through).
- **§8.9 (DEC-01)** — CRE-03 builds against **mock feeds** for the two off-chain marks; the real `alphaUSD`
  (TAO/alpha TWAP + TAO/USD) and HYDX/USD endpoints swap in later (the §8.10 source map). The mark **source** is
  a documented mock seam this window (mirroring `cre/revaluation/observe`), NOT a live integration. The on-chain
  reads (reserves/supply/rate) are REAL DON-mode `eth_call`s — only the off-chain leg inputs are mocked.
- **§8.10** — the per-node fetch + identical-consensus model. The marks are derived market values, never PII.
- **§17** — every wiring slot (both receiver addresses, the ICHI vault, the gauge is NOT needed here, the rate
  source, chain selector, cadence, band, gas) comes from Config (re-pointable), never hardcoded.

## Binds to (verified by inspection — do NOT cite blind)

### A. Receiver 1 — `SzipNavOracle` (the NAV_LEG decode site)
- **`contracts/src/supply/SzipNavOracle.sol:300-324`** `_processReport`: `abi.decode(report, (uint8, bytes))`;
  requires `reportType == NAV_LEG (7)` (`:72,302`); then `abi.decode(payload, (uint8[] legs, uint256[] prices,
  uint32 ts))` (`:303-304`). Producer-relevant guards (all-or-nothing for the batch):
  - `legs.length != prices.length` → `LengthMismatch` (`:305`). **Producer enforces equal length before encoding.**
  - `ts > block.timestamp` → `FutureTimestamp` (`:306`). Use `ts = uint32(runtime.Now().Unix())` (DON time ≈
    chain time, always ≤ now).
  - per leg: `leg >= NUM_LEGS(2)` → `InvalidLeg` (`:311`); `price == 0` → `ZeroPrice` (`:313`). **Producer drops
    a zero/garbage mark before encoding (no-op the tick) rather than emit a reverting report.**
  - **Deviation band (`:314-319`):** if the leg was seen before (`prior.ts != 0`), `diff × 10_000 / priorP >
    maxDeviationBps` (strict `>`, integer floor-div; `diff = |p − priorP|`) → `DeviationExceeded`. **The producer
    MUST clamp each leg to within the band of the on-chain prior cached mark** (read `legCache(leg)` via
    `eth_call`, §B). **EXACT clamp (cre-binding-confirmed lands at the edge):** `step = priorP × maxDeviationBps /
    10_000` (integer floor-div); `clamped = true ∈ [priorP − step, priorP + step]` → push `true`; else push
    `priorP + step` (true above) or `priorP − step` (true below). At the edge `diff × 10_000 / priorP ==
    maxDeviationBps`, which is NOT `> maxDeviationBps`, so it passes — the contract's floor-div only makes the
    guard MORE permissive, so an edge-clamped push can never trip it (no off-by-one against the producer). A
    clamped push always lands; convergence takes multiple epochs on a large move (§8.6 "push intermediate marks").
    First push (`prior.ts == 0`) has no band → push the true value. **The clamped alphaUSD (leg 0) is the SAME
    value fed into the LP mark (coherence) — so the LP feed deliberately inherits NAV's band rate-limit even
    though the LP receiver has no band of its own; the two converge together.**
  - **Strictly-newer (`:320`):** `prior.ts != 0 && ts <= prior.ts` → `StaleReport`. `runtime.Now()` is monotonic
    across ticks; holds in normal operation. Known fail-closed edge: two pushes in the same wall-clock second —
    the second reverts, leg stays on the prior mark until next epoch. Do NOT special-case.
- **Leg semantics the producer must respect:** `LEG_ALPHA_USD=0` (`:66`) = `alphaUSD` (USD per 1.0 ALPHA);
  `LEG_HYDX_USD=1` (`:68`) = HYDX/USD. The contract computes `_xAlphaUSD() = exchangeRate × legCache[0].price /
  1e18` (`:569-577`) and `_oHydxUSD() = legCache[1].price × (100 − discount)/100` (`:580-582`) — so the producer
  pushes the **two market legs only**; xALPHA-USD and oHYDX-USD are derived on-chain.
- **Both legs are REQUIRED for issuance** (`navEntry`/`fresh` revert `StalePrice` if either leg ages past
  `maxAge`, `:503-526`). The contract has **NO on-chain HYDX price source** — it reads only `legCache[1]`. So the
  producer pushes **leg 1 (HYDX) UNCONDITIONALLY every epoch**, NOT "only if the pool is thin." (§7/§8.6 say
  "HYDX if thin"; the as-built contract has no thin-pool fallback read → contract wins → always push. See
  FINDING-1.)

### B. Receiver 2 — `SzipReservoirLpOracle` (the LP_MARK decode site)
- **`contracts/src/supply/SzipReservoirLpOracle.sol:106-121`** `_processReport`: `abi.decode(report, (uint8,
  bytes))`; requires `reportType == LP_MARK (7)` (`:28,108`); then `abi.decode(payload, (uint256 mark, uint32
  ts))` (`:109`); `_writePrice` guards: `mark == 0` → `PriceOracle_InvalidAnswer` (`:116`); `mark >
  type(uint208).max` → `PriceOracle_Overflow` (`:117`); `ts > now` → `FutureTimestamp` (`:118`); `ts <=
  cache.timestamp` → `StaleReport` (`:119`, strictly-newer; first write `timestamp==0` passes).
- **`mark` UNITS — load-bearing, confirmed by the contract's own test** (`contracts/test/SzipReservoirLpOracle.t.sol:34-48`:
  pushes `_push(1_000e6, ts)`, asserts the cached `price == 1_000e6`). The scale is `calcScale(LP_DECIMALS=18,
  quoteDecimals=6, feedDecimals=6)` (`:78`), quote = USDC. So **`mark` = (USD per 1.0 LP share) × 1e6** —
  quote-native 6-dp. **The producer computes per-share USD at 18-dp then divides by 1e12** to land 6-dp:
  - `priceXAlpha_18dp = exchangeRate × alphaUSD_18dp / 1e18` (mirror `SzipNavOracle._xAlphaUSD`, the SAME
    clamped alphaUSD); `priceZipUSD_18dp = 1e18` ($1).
  - reserves come from the ICHI vault (§C). Map `token0`/`token1` → which side is xALPHA vs zipUSD (side-aware,
    like the keeper restake) so the formula picks the right reserve for each price.
  - `perShare_18dp = (reserveXAlpha_18dp × priceXAlpha_18dp + reserveZipUSD_18dp × priceZipUSD_18dp) /
    totalSupply_18dp` — numerator is 36-dp, `/totalSupply` (18-dp) ⇒ 18-dp USD/share.
  - `mark_6dp = perShare_18dp / 1e12`. If `mark_6dp == 0` (empty/unseeded vault) → **no-op the LP push** (the
    contract would revert `PriceOracle_InvalidAnswer`); NAV_LEG may still push.
- **No deviation band on this receiver** (only `!=0`, `<=uint208.max`, `ts<=now`, strictly-newer). Liveness-only:
  a stale mark fails the reservoir borrow CLOSED (`_getQuote` reverts → EVC account-status reverts, `:127-142`),
  never opens an unsafe borrow. So the producer's sole obligation is to re-push within `validityWindow`.

### C. On-chain reads (DON-mode `eth_call`, Base) — the quantities the producer reads, never pushes
- **ICHI vault** (`contracts/src/interfaces/ichi/IICHIVault.sol`): `getTotalAmounts() → (uint256 total0, uint256
  total1)`, `totalSupply() → uint256`, `token0() → address`, `token1() → address`. Reserves + supply are 18-dp.
  Use **spot `getTotalAmounts()`** (matches `SzipNavOracle._lpValue` when `lpTwapWindow == 0`, the M1 default,
  `:452-456`) for M1 coherence; the fair-reserve TWAP path is a later swap, not owed here.
- **xALPHA exchange rate** (`contracts/src/interfaces/bridge/IXAlphaRate.sol`): `exchangeRate() → uint256`
  (18-dp). The producer reads `exchangeRate()` off the **single Config `RateSource` address** — it does NOT
  branch. Whoever runs the workflow points `RateSource` at the wired `SzAlphaRateOracle` (prod) OR the xALPHA
  stand-in (M1); both implement `IXAlphaRate.exchangeRate()` (the contract's own two-source branch at
  `SzipNavOracle.sol:573` is contract-internal and irrelevant to the producer). Fail-closed: if
  `exchangeRate() == 0` (unseeded) → **no-op the tick** (the NAV contract reverts `RateUnseeded` on read; pushing
  legs that can't be priced is pointless) — match the contract's fail-closed posture.
- **Token side mapping:** the producer holds the `XAlpha` + `ZipUSD` token addresses in Config (§17) and matches
  them against the vault's `token0()`/`token1()` to pick which reserve is the xALPHA side vs the zipUSD side
  (the contract does the same against its own immutable `xAlpha`/`zipUSD` storage, `SzipNavOracle.sol:587-591`).
  If neither token matches `XAlpha`/`ZipUSD` → no-op the LP push (wrong/spoofed vault, fail-closed).
- **Prior NAV leg cache** (for the band clamp): `SzipNavOracle.legCache(uint8) → (uint256 price, uint48 ts)`
  (public mapping getter, `:135`). `ts == 0` ⇒ unset ⇒ no band applies (first push lands at the true value).
- All reads are `evm.Client{ChainSelector}.CallContract(runtime, &evm.CallContractRequest{Call: &evm.CallMsg{To:
  addr.Bytes(), Data: selectorCalldata}}).Await()` → `*CallContractReply{ Data []byte }`, then `abi`-decode the
  return. **`BlockNumber` is OPTIONAL — leave it nil (= latest mined block); no finality field required**
  (`client_sdk_gen.go:22`; `CallContractRequest{Call, BlockNumber *pb.BigInt}` doc `client.pb.go:280-290`;
  `CallMsg{From,To,Data}` `:589-596`; `CallContractReply.GetData()` `:376`). The reads are sequential within one
  tick (near-atomic on a quiet block); M1 does NOT pin a shared block across the reads (the feeds are
  liveness-tolerant — a 1-block skew between two reads is immaterial vs the engine-epoch cadence). 
- **THE read/selector/decode idiom to COPY is the live `cre/buyburn-bid/workflow.go` (NOT the szalpha-rate
  stub, which is comment-only pseudocode):** `selector(sig string) []byte = crypto.Keccak256([]byte(sig))[:4]`
  (`:288-290`); a no-arg read `readUint`/`call` doing `CallContract` then decoding `reply.Data` (`:313-319`,
  `:359-366`); arg-packing `append(selector(sig), abi.Arguments{...}.Pack(args...)...)` (`:323-329`); return
  decode `abi.Arguments{...}.Unpack(reply.Data)` (`:336-342`). Reuse this shape for `legCache(uint8)` (one
  `uint8` arg → `(uint256, uint48)` return), `getTotalAmounts()`/`token0()`/`token1()`/`totalSupply()`/
  `exchangeRate()` (no-arg reads).

### D. cre-sdk-go bindings (verified against `reference/cre-sdk-go/`) + the shared encoder
- **Trigger:** `cron.Trigger(*cron.Config{Schedule})` (engine-epoch cadence), modeled on `cre/szalpha-rate`
  + `cre/scaffold`. Handler `onEpoch(cfg *Config, runtime cre.Runtime, _ *cron.Payload)`. (A material-move
  `http.Trigger` second handler is an additive own-later, NOT this slice — see "Do NOT".)
- **`cre.RunInNodeMode[C,T](in, runtime, fn, agg).Await()`** (`cre/runtime.go:166`) + **`cre.ConsensusIdenticalAggregation[T]()`**
  (`cre/consensus_aggregators.go:33`) for the two off-chain marks. **Pin the carrier struct EXACTLY** (the
  `cre/revaluation` `Marks` idiom, but two scalars not a sweep): `type LegMarks struct { AlphaUSD string
  \`json:"alphaUSD"\`; HydxUsd string \`json:"hydxUsd"\` }` — base-10 decimal strings of the 18-dp marks,
  JSON-native + `isIdenticalType`-safe; parse to `*big.Int` (`new(big.Int).SetString(s,10)`, reject `ok==false`
  / sign≤0) AFTER consensus on the DON side. The node-mode observe MUST NOT call `runtime.GetSecret`
  (NodeRuntime has no SecretsProvider). §8.9 MOCK: observe `json.Unmarshal`s a config/trigger-supplied `LegMarks`
  deterministically (real httpcap `alphaUSD`/HYDX fetch deferred), exactly as `cre/revaluation/observe`.
- **`runtime.GenerateReport(&cre.ReportRequest{EncodedPayload, EncoderName:"evm", SigningAlgo:"ecdsa",
  HashingAlgo:"keccak256"}).Await()`** then **`evm.Client{ChainSelector}.WriteReport(runtime,
  &evm.WriteCreReportRequest{Receiver, Report, GasConfig:&evm.GasConfig{GasLimit}}).Await()`** — the proven idiom
  from `cre/revaluation/workflow.go:228-249` (note: `WriteCreReportRequest`, `client_sdk_gen.go:255,293`; the
  szalpha-rate stub's `WriteReportRequest` is STALE — use the revaluation form).
- **Encoders (import, do NOT re-encode):** `cre/zipreport/report.go` —
  `NavLegReport(legs []uint8, prices []*big.Int, ts uint32) ([]byte, error)` (`:229`, asserts equal length,
  wraps reportType 7) and `LpMarkReport(mark *big.Int, ts uint32) ([]byte, error)` (`:241`, wraps reportType 7).
  Both round-trip-tested in `cre/zipreport/report_test.go`. go.mod replaces `cre-zipreport => ../zipreport` +
  the SDK relative-replaces, exactly as `cre/revaluation/go.mod`.

## Starting state
- `cre/zipreport` (CRE-00) is BUILT + tested; both encoders exist. `cre/revaluation` (CRE-01a) is the canonical
  producer to model (http trigger → node-mode consensus → §8.9 mock observe → DON ts → encode → WriteReport).
- `cre/szalpha-rate` exists but is a PRE-CRE-00 stub (local encoders, stale `WriteReportRequest`, R-1-blocked
  964 read) — DO NOT model its encode/write idiom; model `cre/revaluation`. It is a SEPARATE track (out of scope).
- Both receivers are filed + fork-tested (`SzipNavOracle.t.sol`, `SzipReservoirLpOracle.t.sol`). No contract change.

## Do NOT
- Do NOT push the RATE (reportType 8) / xALPHA exchange rate or any APR — that is `cre/szalpha-rate` (8x-02,
  R-1-blocked) and the APR is derived on-chain (§8.8). CRE-03 here is NAV_LEG + LP_MARK only.
- Do NOT push xALPHA-USD or oHYDX-USD — the contract derives both on-chain from the two market legs. Push only
  `alphaUSD` (per-ALPHA) and `HYDX/USD`.
- Do NOT push per-xALPHA prices — `alphaUSD` is per-1.0-ALPHA; the contract multiplies in `exchangeRate()`.
- Do NOT re-implement the report encoders — import `cre/zipreport`.
- Do NOT emit a report that will revert: drop zero/garbage marks, clamp NAV legs to the band, skip the LP push on
  a zero mark, skip a tick on an unseeded rate. A no-op tick is the safe outcome (liveness-only feeds).
- Do NOT add the material-move `http.Trigger` handler, the fair-reserve TWAP path, or a live HTTP feed fetch this
  slice — all additive own-later; keep the §8.9 mock observe.
- Do NOT hardcode any address/selector/cadence — Config-driven (§17).

## Key requirements
1. **Two coupled reports from one computation** (§8.6 coherence): one node-mode consensus on `{alphaUSD, hydxUsd}`,
   one set of DON-mode reads (reserves, supply, rate, prior leg cache), one `alphaUSD` (post-clamp) feeding BOTH
   the NAV alpha leg AND the LP mark's xALPHA reserve valuation.
2. **NAV_LEG** push: `legs=[0,1]`, `prices=[alphaUSD_18dp, hydxUsd_18dp]`, both clamped to `maxDeviationBps` of
   the on-chain prior `legCache`, `ts=uint32(runtime.Now().Unix())`, via `zipreport.NavLegReport` → WriteReport to
   the nav oracle. HYDX pushed unconditionally (FINDING-1).
3. **LP_MARK** push: `mark_6dp = perShare_18dp / 1e12` (side-aware token0/token1 mapping), via
   `zipreport.LpMarkReport` → WriteReport to the LP oracle. No-op the LP push if `mark_6dp == 0`.
4. **Fail-safe no-ops:** unset Config receiver → skip that push; `exchangeRate()==0` → skip the tick; a zero/garbage
   off-chain mark → skip; an empty vault (supply 0 / mark 0) → skip the LP push.
5. **Pure, table-testable core** factored out of the SDK glue: the band clamp, the LP-mark math (incl. side-aware
   token mapping + the 18→6 dp downscale), and the leg assembly are pure functions unit-tested without the runtime.
6. **Config (§17):** `ChainSelector`, `NavOracle`, `LpOracle`, `IchiVault`, `RateSource` (the SzAlphaRateOracle or
   xALPHA stand-in — single address, no branch), `XAlpha` + `ZipUSD` (the two LP-side token addresses, for the
   side-aware `token0`/`token1` mapping), `MaxDeviationBps`, `Schedule`, `WriteGasLimit`. No hardcoded address.
7. `go.mod` replaces `cre-zipreport` + the SDK snapshots via the relative-replace idiom (`cre/revaluation/go.mod`).

## Done when
- **Gate (per-track, harness §4 CRE):** `cd cre/sharefeeds && go build ./... && go vet ./... && go test -count=1 ./...`
  all green; the package compiles to the `wasip1` target (`GOOS=wasip1 GOARCH=wasm go build ./...`).
- **Non-vacuous encode test:** a table test ENCODES the produced NAV_LEG payload and asserts it `abi.decode`s to
  exactly `(uint8[]{0,1}, uint256[]{alphaUSD,hydxUsd}, uint32 ts)`; ENCODES the LP_MARK payload and asserts it
  `abi.decode`s to `(uint256 mark, uint32 ts)` with `mark` in 6-dp — i.e. round-trips the EXACT tuples the two
  filed `_processReport`s decode (envelope `(uint8 7, bytes)` for each).
- **Band clamp test:** a leg move beyond `maxDeviationBps` produces a pushed price at the band edge (lands, not
  reverts); a within-band move passes through; an unset prior (`ts==0`) passes the true value.
- **LP-mark math test:** a hand-computed reserve/price/supply tuple (both token0=xALPHA and token0=zipUSD
  orderings) yields the expected 6-dp mark; a zero-supply vault yields a no-op (mark 0).
- **Simulated run:** a trigger → node-mode identical-consensus → DON-mode (mocked `eth_call` replies for
  reserves/supply/rate/legCache) → two WriteReports, asserting the two recorded reports decode to the expected
  payloads. (Model the `cre/revaluation` workflow_test + the evm mock client `reference/.../evm/mock`.)
- **ZERO load-bearing guesses** from the cold-build. The Go module committed to `cre/sharefeeds` (code only;
  no `build/`/`docs/`/`contracts/` staged).

## Depends on
- CRE-00 (`cre/zipreport` encoders + the scaffold idiom) — DONE.
- The two receivers — filed + fork-tested. No new contract surface needed (NOT back-pressured).

## Findings to log at Conclude
- **FINDING-1 (spec vs contract, contract wins):** §7/§8.6 say "HYDX pushed only if the pool is thin." The
  as-built `SzipNavOracle` has NO on-chain HYDX read — `_oHydxUSD`/`grossBasketValue` read only `legCache[1]`,
  and `navEntry`/`fresh` REQUIRE leg 1 fresh. So the producer pushes HYDX unconditionally. Note in §8.6 (a
  "(BUILT — CRE-03)" clarification) that the thin-pool conditionality is deferred spec intent pending an on-chain
  HYDX TWAP read the contract does not have.
- **FINDING-2 (scope):** the §8.11 CRE-03 row's "xALPHA-APR feed (Go producer remains)" is the `cre/szalpha-rate`
  RATE pull (bridge 8x-02, R-1-blocked), NOT part of this slice; the APR is on-chain-derived. Mark the row so the
  next reviewer doesn't expect an APR producer here.
- **SEAM-1 (deferred, log in PROGRESS):** §8.6 cadence is "engine epoch AND a material leg move." This slice ships
  the engine-epoch `cron` handler only; the material-move `http.Trigger` second handler is an additive own-later.
  It is liveness-safe to defer (the band-clamp already converges large moves over epochs; the LP feed is
  liveness-only fail-closed), but the "AND material move" clause must be carried as an open seam so it isn't lost.
