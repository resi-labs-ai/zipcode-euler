# CRE-01b — the controller lifecycle producer (reportType 1/2/4/5,6 → `ZipcodeController`)

> **Track:** (R) — a wasip1 CRE report-path workflow (CRE-OPS-ROUTING: CRE-01 is pure (R) through existing
> receivers). **This is the SECOND of three CRE-01 slices** (the split was forced by a 4-critic fan-out on
> CRE-01 — same pattern as CTR-06/CTR-10). CRE-01a (revaluation → registry, rt3) is DONE. This slice builds the
> **underwriting / controller lifecycle producer** — origination, draw, close, and default/liquidation status —
> the headline, largest slice. CRE-01c (default/recovery → `DefaultCoordinator`, rt8 action family) is the
> remaining slice, logged at the bottom.

---

## Deliverable
A committed Go module at **`cre/controller/`** (monorepo `cre/` — harness §3) that compiles to `wasip1` and
implements the **§8.1 underwriting / controller lifecycle producer**: an off-chain application / lifecycle
event arrives via `http.Trigger`, the workflow reaches **identical consensus** on the event record (the typed
fields + the §8.9/§8.10 Proof boolean gates), **enforces the Proof gate** (fail-closed — a credit-fact report
is emitted ONLY if every gate passes), encodes the matching payload via the shared **`cre/zipreport`** library,
and emits **one `WriteReport`** to the `ZipcodeController` as the §8.0 envelope `abi.encode(uint8 reportType,
bytes payload)`. The four report types it produces:

| action (payload discriminant) | reportType | encoder | Proof-gate? | carries siloId? |
|---|---|---|---|---|
| `origination` | 1 `RT_ORIGINATION` | `zipreport.Origination` | **yes** (§8.9 — before mint) | **yes** (CTR-03) |
| `draw` | 2 `RT_DRAW` | `zipreport.Draw` | **yes** (re-appraisal mark) | no (re-resolved on-chain) |
| `close` | 4 `RT_CLOSE` | `zipreport.Close` | no (release on zero debt) | no |
| `default` / `liquidation` | 5 `RT_DEFAULT` / 6 `RT_LIQUIDATION` | `zipreport.Status` | no (a status marker) | no |

Encoding is delegated to `cre/zipreport` (CRE-00) — this slice does **NOT** re-implement the §8.0 handshake.

## Spec §
- **§8.1** "Underwriting / origination / revaluation" — the producer this slice implements: **trigger =
  `http.Trigger(*Config)`** ("originator submits an application") for origination; **event-driven** on draw /
  close / status events. **No cron heartbeat.** Inputs are fetched per-node, identical-consensus-aggregated
  (the value is a notarized *fact*, not a model estimate). Output = ABI-encode the payload →
  `runtime.GenerateReport` → `evmClient.WriteReport({Receiver: ZipcodeController})`.
- **§8.0** — the report envelope + the rt1/rt2/rt4/rt5,6 rows (the exact decode tuples; reproduced under "Binds
  to A"). Encoder BUILT as `cre/zipreport` (CRE-00). Note the §8.0 **siloId routing** paragraph (lines 534-538):
  RT_ORIGINATION carries a **trailing `bytes32 siloId`**; RT_DRAW/RT_CLOSE do **not** (those branches re-resolve
  the venue from the stored `r.siloId`, so the producer does NOT re-send it).
- **§8.9 (DEC-01, RESOLVED)** — the two-layer Proof gate. **CRE-01 builds against mock Proof + mock feeds**; the
  Proof gates + the equity mark arrive in the trigger payload this window (the documented mock seam), and the
  real per-node fetch + on-node hash/cert-chain verify swap in later (the §8.10 source map). The §8.9 rule the
  producer enforces: every report carrying a **credit fact** (origination 1, draw 2) needs its facts attested →
  **the workflow emits a report only if the gates pass** (§8.1).
- **§8.10** — the off-chain underwriting/proof layer: each off-chain truth becomes a **boolean gate** (lien
  perfected, insured, identity-ok, credit band, income ≥ threshold, clean title) or a **value reached by
  identical consensus** (the equity mark, the LTV bounds). raw PII never enters consensus.
- **§17** — every wiring slot (receiver address, chain selector) comes from Config (re-pointable), not hardcoded.

## Binds to (verified by inspection — do NOT cite blind)

### A. The filed report consumer — `ZipcodeController` (the decode sites)
The shared envelope is decoded at **`contracts/src/ZipcodeController.sol:193`**
(`abi.decode(report, (uint8, bytes))`) then dispatched in `_processReport` (`:191-211`); fails closed on any
unknown type (`UnsupportedReportType`, `:209`). reportType 3 is explicitly rejected here (delivered direct to
the registry — that is CRE-01a's path).

- **rt1 `RT_ORIGINATION` (`:47`) → `_origination` (`:213-262`)**, payload decoded at `:215-224`:
  `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount,
  uint256 cap, bytes32 siloId)`. On-chain effect (atomic): resolve `venue = SiloRegistry.venueOf(siloId)`
  (fail-closed `SiloUnrouted` if 0, `:226` via `_venueFor`) → create lien → `openLine` → `seedPrice(oracleKey,
  equityMark)` → `setLineLimits(lineRef, borrowLTV, liqLTV, cap)` → `fund` → `draw(…, erebor)` → store +
  `LienOriginated` event → `incrementLineCount(siloId)` (fail-closed `SiloFull`). **The LTVs are 1e4-scale**
  (`setLineLimits` comment `:248`); `cap` is raw; `equityMark` is the 18-dp Proof-of-Value mark.
- **rt2 `RT_DRAW` (`:48`) → `_draw` (`:265-283`)**, payload decoded at `:266-267`:
  `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)`. Requires the lien `open`
  (`UnknownLien`, `:270`); re-resolves the venue from the **stored** `r.siloId` (NOT from the payload);
  re-anchors a fresh mark (`seedPrice(r.lien, equityMark)`); funds + draws; `LienDrawn` event. `proofRef` is
  carried for off-chain indexing, **not stored** (`:282`).
- **rt4 `RT_CLOSE` (`:50`) → `_close` (`:286-…`)**, payload decoded at `:287`: `(bytes32 lienId)`. Requires
  `open`; requires `observeDebt(lineRef) == 0` (`DebtOutstanding`); closeLine → burn → `LienReleased`. **No
  credit fact → no Proof gate** (the on-chain zero-debt check is the gate).
- **rt5/rt6 `RT_DEFAULT` (`:51`) / `RT_LIQUIDATION` (`:52`)** → the inline branch (`:202-206`):
  `abi.decode(payload, (bytes32 lienId, uint8 status))` → `emit LienStatusUpdated(lienId, status)`. **M1:
  status-marker only** (no markdown / escrow / `venue.liquidate` — that is the DefaultCoordinator's M2 job,
  CRE-01c). A bare status push, off-chain truth (§8.4) — **no Proof gate** in this slice.

### B. The encoders — already pinned to these exact tuples (`cre/zipreport/report.go`)
- **`Origination(lienId, proofRef [32]byte, equityMark *big.Int, borrowLTV, liqLTV uint16, drawAmount, cap *big.Int, siloId [32]byte) ([]byte, error)`** — `report.go:181-185`, wraps reportType 1.
- **`Draw(lienId, proofRef [32]byte, equityMark, drawAmount *big.Int) ([]byte, error)`** — `report.go:189-193`, reportType 2.
- **`Close(lienId [32]byte) ([]byte, error)`** — `report.go:196-198`, reportType 4.
- **`Status(reportType uint8, lienId [32]byte, status uint8) ([]byte, error)`** — `report.go:202-208`, reportType
  **must be 5 or 6** (it returns an error otherwise — use the constants `zipreport.ControllerDefault` /
  `zipreport.ControllerLiquidation`).
- Constants: `zipreport.ControllerOrigination(1) / ControllerDraw(2) / ControllerClose(4) /
  ControllerDefault(5) / ControllerLiquidation(6)` — `report.go:75-81`.
- Each builder is round-trip-tested against the filed-contract decode in `cre/zipreport/report_test.go`.
  **Import it; do not re-encode.**

### C. cre-sdk-go bindings (verified — identical surface to CRE-01a, `cre/revaluation/`)
- **`http.Trigger`** — `reference/cre-sdk-go/capabilities/networking/http`,
  `Trigger(*http.Config) cre.Trigger[*Payload, *Payload]` (`trigger_sdk_gen.go:16-23`). Handler signature
  `onApplication(cfg *Config, runtime cre.Runtime, payload *http.Payload)`. **`http.Payload.Input []byte`**
  carries the JSON event body. Import the capability package aliased
  `httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"` (avoid the stdlib `net/http`
  clash). Empty `&httpcap.Config{}` is valid for the build.
- **`cre.RunInNodeMode[C,T]`** (`cre/runtime.go:166-225`) — `C` is a **FREE generic**; pass the raw trigger
  bytes as `C = []byte` into `observe(in []byte, _ cre.NodeRuntime) (Application, error)` (see K3 — the
  load-bearing plumbing CRE-01a pinned: do NOT carry the per-call body on the workflow `*Config`).
- **`cre.ConsensusIdenticalAggregation[Application]()`** (`cre/consensus_aggregators.go:31-40`) — `isIdenticalType`
  (`:198-225`) accepts **string, bool, all int/uint widths, slices/arrays (recursively), structs (all exported
  fields identical-type)**, and `*big.Int` (special-cased). The carrier here is a struct of **string + bool +
  uintN scalar** fields only (K2).
- **`runtime.Now() time.Time`** (`cre/runtime.go:27-28`) — only needed if a report carried a ts (none of
  rt1/2/4/5,6 do; the controller payloads have NO ts field). Test determinism via
  `testutils.(*TestRuntime).SetTimeProvider` if used.
- **The write path** — copy **`cre/revaluation/workflow.go:228-249`** (`writeReport`) verbatim:
  `runtime.GenerateReport(&cre.ReportRequest{EncodedPayload, EncoderName:"evm", SigningAlgo:"ecdsa",
  HashingAlgo:"keccak256"})` → `(&evm.Client{ChainSelector: cfg.ChainSelector}).WriteReport(runtime,
  &evm.WriteCreReportRequest{Receiver: common.HexToAddress(cfg.Controller).Bytes(), Report, GasConfig})`.
- **Test harness** — `testutils.NewRuntime`, `evmmock.NewClientCapability(chainSelector, t)`,
  `evmmock.AddContractMock(receiver, mock, …)` capturing the report bytes. Model the sim on
  **`cre/revaluation/workflow_test.go`** (its `onReappraisal` full-handler sim) — construct a
  `*httpcap.Payload{Input: <JSON bytes>}` and call the handler directly.

### D. The module skeleton to clone — `cre/revaluation/` (CRE-01a, the closest sibling)
Clone `cre/revaluation/`'s file shape exactly (it is already on the **http + zipreport** dependency set this
slice needs — a better seed than the cron-based scaffold): `main.go` (`//go:build wasip1`,
`wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)`), `main_host.go` (`//go:build !wasip1`, no-op `main()`),
`workflow.go` (untagged logic + handler), `go.mod`, `project.yaml`, `.env.example`, `secrets.yaml.example`,
`README.md`, `workflow_test.go`.
**go.mod:** seed from `cre/revaluation/go.mod` (NOT the scaffold's), rename `module cre-revaluation` →
`module cre-controller`, keep its replace set verbatim (base `cre-sdk-go` + `evm` + `networking/http` +
`cre-zipreport`; the relative paths `../../reference/...` and `../zipreport` are correct — same depth), then
`go mod tidy`.

## Module layout (author exactly this)
```
cre/controller/
  go.mod                  # module cre-controller ; go 1.25.3 ; revaluation's replaces (SDK pins + cre-zipreport)
  .gitignore              # /.env, secrets.yaml
  .env.example            # CRE_* / config vars documented
  secrets.yaml.example    # illustrative (no live secret needed — see K6)
  project.yaml            # cre-cli project file (clone revaluation)
  README.md               # what it is, the trigger, the action discriminant, the Proof-gate, the mock seam, the gate
  main.go                 # //go:build wasip1 — wasm runner entrypoint (clone revaluation)
  main_host.go            # //go:build !wasip1 — no-op main (clone revaluation)
  workflow.go             # initFn + onApplication handler + observe + dispatch/validate/encode + writeReport
  workflow_test.go        # host sim test (per-action decode asserts + gate-fail no-op + bad-input errors)
```

## Key requirements

### K1 — trigger + Config
- **One trigger: `http.Trigger`** (§8.1 — origination/lifecycle are http/event-driven; **no cron heartbeat**).
  The off-chain pipeline POSTs one event; `http.Payload.Input` is the JSON body.
- `Config` (JSON, `cre.ParseJSON[Config]`): `ChainSelector uint64`, `Controller string` (the `ZipcodeController`
  receiver address), `WriteGasLimit uint64` (default `600_000` if 0), `AuthorizedKeys []string` (optional, for
  `http.Config`). **No hardcoded address** (§17). (No `MaxLiensPerReport` — this slice emits one report per
  event, no sharding.)

### K2 — the consensus carrier (string + bool + uintN scalars only — pinned, not guessed)
The node-mode observation returns ONE struct carrying every action's fields (the union; per-action validation
in the handler decides which are required). Pin the carrier to **string, bool, and uintN scalar fields only** —
do **NOT** put `common.Address`, `[32]byte`, or `*big.Int` in the carrier (parse those on the DON side AFTER
consensus, exactly as CRE-01a parses `Marks` post-consensus):
```go
type Application struct {
    Action     string `json:"action"`     // "origination"|"draw"|"close"|"default"|"liquidation"
    LienID     string `json:"lienId"`     // 0x… 32-byte hex (every action)
    ProofRef   string `json:"proofRef"`   // 0x… 32-byte hex (origination, draw)
    SiloID     string `json:"siloId"`     // 0x… 32-byte hex (origination ONLY — CTR-03)
    EquityMark string `json:"equityMark"` // base-10 string, 18-dp mark (origination, draw)
    DrawAmount string `json:"drawAmount"` // base-10 string (origination, draw)
    Cap        string `json:"cap"`        // base-10 string (origination)
    BorrowLTV  uint16 `json:"borrowLtv"`  // 1e4-scale (origination)
    LiqLTV     uint16 `json:"liqLtv"`     // 1e4-scale (origination)
    Status     uint8  `json:"status"`     // (default, liquidation)
    Gates      Gates  `json:"gates"`      // §8.9/§8.10 Proof booleans (origination, draw)
}
type Gates struct {
    LienPerfected bool `json:"lienPerfected"` // §8.10 — boolean gate before mint
    Insured       bool `json:"insured"`       // §8.10 — boolean gate before mint
    IdentityOk    bool `json:"identityOk"`     // §8.10 — Plaid KYC/sanctions
    CreditOk      bool `json:"creditOk"`       // §8.10 — VantageScore band
    IncomeOk      bool `json:"incomeOk"`        // §8.10 — income ≥ threshold
    TitleClean    bool `json:"titleClean"`     // §8.10 — Pippin title
}
```
- Consensus = **`cre.ConsensusIdenticalAggregation[Application]()`** (the facts are notarized → identical, not
  median; §8.1/§8.10). `uint16`/`uint8` and a nested struct-of-`bool` are all `isIdenticalType` — verified
  against the source: `isIdenticalType` recurses into structs and accepts a struct iff every exported field is
  itself identical-type (`reference/cre-sdk-go/cre/consensus_aggregators.go:207-214`), and accepts string/bool/
  all int+uint widths (`:198-225`). So `Gates` (six `bool` fields) and the `uintN` scalars are accepted.
- **The full-handler sim (Done-when 2) is the Wrap-ability proof** — if `Application` (with its bool/uintN/nested
  fields) fails to `values.Wrap` through `RunInNodeMode`, the sim fails and the carrier-shape decision folds back
  into this ticket. This is the same net CRE-01a used; it is a tested decision, not a guess.

### K3 — the handler + observe (node mode) = the §8.9 MOCK-FEED SEAM
- **The single handler `onApplication(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload)`** runs in DON
  mode, holds `payload.Input`. Registered in `initFn`:
  `cre.Handler(httpcap.Trigger(&httpcap.Config{}), onApplication)`.
- **Payload → node mode (the load-bearing plumbing CRE-01a pinned — do NOT improvise):** `RunInNodeMode[C,T]`'s
  `C` is a **FREE generic**, NOT the workflow `*Config`. Pass the raw bytes as `C = []byte`:
  ```go
  app, err := cre.RunInNodeMode(payload.Input, runtime, observe,
      cre.ConsensusIdenticalAggregation[Application]()).Await()
  ```
  with `observe(in []byte, _ cre.NodeRuntime) (Application, error)` = `json.Unmarshal(in, &app)` → return `app`.
  **WRONG:** carrying the body on the workflow `*Config` (it is parsed once at init, has no per-invocation body).
- **THIS IS THE MOCK SEAM (§8.9/§8.10):** for the build, every node `json.Unmarshal`s the identical
  trigger-supplied event (deterministic → identical consensus holds), **including the `Gates` booleans** — i.e.
  the off-chain Proof/feed verdicts arrive pre-computed in the payload this window. A prominent comment block on
  `observe` marks it: *"§8.9/§8.10 MOCK FEED — replace this `json.Unmarshal` of the trigger event with per-node
  `httpcap.Client.SendRequest` to the real Proof / Plaid / Credit-Karma / Pippin / DART / Block-Analitica feeds +
  on-node zk/hash/cert-chain verify, deriving `Gates` + `EquityMark` per node; the `RunInNodeMode` + consensus +
  gate + encode + write machinery is unchanged."*
- **`observe` MUST NOT call `runtime.GetSecret`** (NodeRuntime has no SecretsProvider; §8.1 forbids secrets in a
  consensus observation). Any future DON-only secret read stays in the handler.

### K4 — dispatch → validate → Proof-gate → encode → write (the core)
After consensus, the handler **`strings.ToLower(strings.TrimSpace(app.Action))`** and dispatches on the result
(so `"Origination"`/`" origination "` all match; an unknown or empty action ⇒ error, no write). Per-action
**required vs optional** field rules (a required field that is missing/empty/unparseable ⇒ error, no write — a
malformed event is a producer-side bug to surface; "may be zero" fields parse a present value but accept 0):

- **`origination`** (rt1): **required** — `LienID` (bytes32, non-zero), `SiloID` (bytes32, non-zero — the
  current fill-target silo; CTR-03), `EquityMark` (`*big.Int`, base-10, **> 0** — the controller's
  `seedPrice`→`_writePrice` `price==0` guard reverts `PriceOracle_InvalidAnswer`, `ZipcodeOracleRegistry.sol:115,142`),
  `DrawAmount` + `Cap` (`*big.Int`, base-10, present but **may be 0**), `BorrowLTV`/`LiqLTV` (uint16 from the
  carrier, 1e4-scale — no producer-side range check beyond uint16; Block Analitica owns the bounds, §8.10).
  **Optional** — `ProofRef` (bytes32, **may be zero** — off-chain commitment, not load-bearing on-chain). **Proof
  gate (§8.9): ALL `Gates` fields true → emit; any false → NO report (fail-closed no-op, log "origination gate
  failed", return nil).** Encode `zipreport.Origination(lienId, proofRef, equityMark, borrowLTV, liqLTV,
  drawAmount, cap, siloId)`.
- **`draw`** (rt2): **required** — `LienID` (bytes32, non-zero), `EquityMark` (> 0), `DrawAmount` (`*big.Int`,
  may be 0). **Optional** — `ProofRef` (may be zero). **NO `SiloID`** (the controller re-resolves the venue from
  the stored `r.siloId`; §8.0 lines 534-538 — do NOT send it). **Proof gate (§8.9): same all-must-pass → else
  no-op.** Encode `zipreport.Draw(lienId, proofRef, equityMark, drawAmount)`.
- **`close`** (rt4): **required** — `LienID` (bytes32, non-zero). All other carrier fields are ignored. **No
  Proof gate** (the on-chain `observeDebt==0` is the gate). Encode `zipreport.Close(lienId)`.
- **`default` / `liquidation`** (rt5 / rt6): **required** — `LienID` (bytes32, non-zero), `Status` (uint8 from
  the carrier — any uint8 is valid; the M1 contract emits it verbatim, `LienStatusUpdated`). **No Proof gate** (a
  status marker, off-chain truth §8.4). Encode
  `zipreport.Status(zipreport.ControllerDefault /* or ControllerLiquidation */, lienId, status)`.
- **One `WriteReport`** per gated-pass event → the `ZipcodeController` (`cfg.Controller`). A write error is
  **returned** from the handler (the §8.1 model surfaces it; do not swallow).
- **No-op fail-safe:** `strings.TrimSpace(Controller) == ""` ⇒ no write, log, return nil. A failed Proof gate ⇒
  no write (above). An unknown/empty `Action` or a missing required field ⇒ **error** (return it).
- **Anticipated on-chain reverts the producer does NOT pre-check (surface, do not retry-loop):** origination can
  revert `SiloUnrouted` (silo not registered), `SiloFull` (silo at the 28-line cap — the CRE-01 composer's job is
  to pick a non-full fill target; on `SiloFull` the silo has rolled over, pick the next), `LienExists` (duplicate
  `lienId` — never re-originate the same lien); draw/close can revert `UnknownLien` (lien not open); close can
  revert `DebtOutstanding` (non-zero debt). These are on-chain backstops; the producer's job is to send a
  well-formed report, not to replicate the controller's state machine. The write error propagates (above).

### K5 — hex parsing (bytes32, NOT address — distinct from CRE-01a)
The controller keys by **`bytes32 lienId`** (the CREATE2 salt), not a token address. `common.HexToHash` /
`HexToAddress` silently zero-pad/truncate bad input, so **validate the hex string FIRST**. Pin **one helper with
an explicit allow-zero flag** (so the zero-value policy is a per-caller decision, not two near-duplicate funcs):
```go
func parseBytes32(s string, allowZero bool) ([32]byte, error)
```
It requires a `0x`/`0X` prefix + **exactly 64 hex chars**, rejects non-hex, then `common.HexToHash(s)` and takes
`[32]byte`; if `!allowZero` it rejects the zero value. Callers: `lienId`/`siloId` → `parseBytes32(s, false)`
(must be non-zero); `proofRef` → `parseBytes32(s, true)` (an off-chain commitment, may be zero). Reuse the
validate-hex-first discipline from `cre/revaluation/workflow.go:204-223` (`parseLien`), adapted from 40→64 hex
chars and address→`[32]byte`.

### K6 — secrets/scaffolding
- No live secret is required (the mock feed + gates arrive on the trigger payload). `secrets.yaml.example` is
  illustrative. A future real-feed swap reads any DON-only key in the **handler**, never `observe`.

### K7 — docs
- `README.md`: what it is (the §8.1 controller lifecycle producer), the http trigger + the per-action JSON event
  shape (one documented example per action), the **action discriminant** table, the **§8.9 Proof-gate
  (all-must-pass, fail-closed) + the §8.10 mock-feed seam + the swap-in note**, the **siloId-on-origination-only**
  rule (CTR-03), and the gate commands. Cross-link §8.1/§8.9/§8.10/§8.0 + `cre/zipreport`.

## Do NOT
- Do **NOT** re-implement the §8.0 envelope or any payload encode — import `cre/zipreport`.
- Do **NOT** add a `cron.Trigger` heartbeat (§8.1: event-driven Proof, no cron).
- Do **NOT** send `siloId` on draw/close (the controller re-resolves from the stored `r.siloId`; §8.0 534-538).
- Do **NOT** emit an origination/draw report when any Proof gate is false (§8.9 — fail-closed, no report).
- Do **NOT** implement the DefaultCoordinator rt8 action family (LOCK/RELEASE/DEFAULT/…) here — that is CRE-01c.
  The rt5/rt6 *status markers* (a `(lienId, status)` push to the controller) ARE in scope; the coordinator's
  economic actions are NOT.
- Do **NOT** put `common.Address` / `[32]byte` / `*big.Int` in the consensus carrier (K2); parse post-consensus.
- Do **NOT** call `GetSecret` inside `observe` (node mode).
- Do **NOT** hardcode any address (§17 — Config-driven, re-pointable).

## Done when (the per-track CRE gate — wasip1 variant)
1. **`cd cre/controller && go build ./... && go vet ./...`** exits 0 (host), **and**
   `GOOS=wasip1 GOARCH=wasm go build ./...` exits 0 (the wasip1 target — the real gate).
2. **`cd cre/controller && go test ./...`** green, **non-vacuous**, covering:
   - **Encode handshake (per action):** the captured report decodes to `(uint8 reportType, bytes payload)` and
     the payload to the EXACT `ZipcodeController` decode tuple for that action — asserted by decoding the bytes
     (NOT by trusting `zipreport`). At least: origination → `(bytes32,bytes32,uint256,uint16,uint16,uint256,
     uint256,bytes32)` with reportType 1; draw → `(bytes32,bytes32,uint256,uint256)` rt2; close → `(bytes32)`
     rt4; default → `(bytes32,uint8)` rt5; liquidation → rt6.
   - **Proof gate:** origination/draw with all gates true ⇒ 1 write; with ANY gate false ⇒ **0 writes** (no-op);
     proved by **two separate cases each flipping a different single gate to false** (e.g. one with
     `lienPerfected=false`, one with `insured=false`) — so the all-must-pass logic is exercised on more than one
     field, not a single hardcoded gate.
   - **siloId routing:** the origination payload's trailing `bytes32` decodes to the input `siloId`; the draw
     payload has **no** siloId field (its tuple is 4 elements).
   - **Validation errors ⇒ no write:** unknown action; empty action; malformed/short `lienId` hex; non-base-10
     or **zero** `equityMark` on origination/draw; zero `lienId`. (A zero `proofRef` on origination is ACCEPTED.)
   - **No-op:** unset `Controller` ⇒ 0 writes.
   - **Full handler path (the sim):** call `onApplication(cfg, runtime, &httpcap.Payload{Input: <JSON event
     bytes>})` directly (model `cre/revaluation/workflow_test.go`). The path exercises `RunInNodeMode(payload.Input,
     …)` + `ConsensusIdenticalAggregation[Application]` + dispatch + gate + `zipreport.*` + `GenerateReport` +
     `WriteReport`, under `testutils` + `evmmock`, asserting the captured envelope. **This proves the
     `Application` carrier (bool/uintN/nested struct) actually `values.Wrap`s through identical consensus** — a
     `RunInNodeMode` failure here = the K2 carrier-shape decision was wrong → fold back.
3. The Go module is **committed to `cre/controller/`** (monorepo `cre/`), code only — no `build/`/`docs/`/
   `contracts/` staged in the code commit.
4. **Cold-build verdict is "yes," not "yes-with-guesses."** If the builder must guess the carrier Wrap-ability,
   the payload→node-mode plumbing, the per-action required-field set, or any SDK signature, the gap folds back.

## Depends on
- **CRE-00** (`cre/zipreport` encoder + scaffold) — DONE. **CRE-01a** (`cre/revaluation/`, the http+zipreport
  sibling to clone) — DONE.
- The filed `ZipcodeController` (built, ABI fixed) — the decode site.
- `reference/cre-sdk-go` present (harness §7). No anvil needed for the unit gate (the sim is mock-backed).

## Discharges / spawns
- Discharges no inbound obligation row (none owed *by* CRE-01b).
- **Logs the CRE-01 remainder** (set the next `NEXT`): **CRE-01c — default/recovery producer**, reportType 8
  action family → `DefaultCoordinator` (LOCK/RELEASE M1-live; DEFAULT/RECOVERY/RESOLVE/WRITEOFF go live with the
  M2 demo, §8.4). Encoders: `zipreport.CoordLock/Release/Default/Recovery/Resolve/WriteOff`.

## Reconciliation notes (precision the ticket pins beyond the literal §8.1 prose)
- §8.1 names the trigger (`http.Trigger`) and the consensus model (identical) but does not enumerate the
  per-action payload discriminant, the carrier type, or the gate-fail policy. This ticket pins: **one
  action-discriminated http event** (the §8.0 four controller report types share one producer — distinct from
  CRE-01a's registry path), **carrier = `Application{string+bool+uintN}`** (the verified-Wrap-able shape,
  proven by the sim), **gate-fail = no report / fail-closed** (the literal §8.1 "emits a report only if they
  pass"). Each is a derivation from §8.1/§8.9/§8.10 + the verified SDK + the filed contract, not an invention.
- The §8.9 mock seam (Proof gates + equity mark arriving in the payload) is the spec-sanctioned build posture
  ("CRE-01 builds against mock Proof + mock feeds"), not a shortcut: the node-mode + identical-consensus + gate +
  encode + write structure is the real, permanent machinery; only the per-node fetch source is mocked-via-trigger.
- The rt5/rt6 **status markers** are in this slice (a `(lienId, status)` push to the *controller*, §8.0 row 520);
  the DefaultCoordinator's reportType-8 economic action family (§8.4) is CRE-01c. They are different receivers
  and different report shapes — the split is on the receiver, not on "default vs not."
