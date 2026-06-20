# CRE-01a — the revaluation sharded producer (reportType 3 → `ZipcodeOracleRegistry`)

> **Track:** (R) — a wasip1 CRE report-path workflow (CRE-OPS-ROUTING: CRE-01 is pure (R) through existing
> receivers). **This is the FIRST of three CRE-01 slices** (CRE-01 in §8.11 bundles three distinct workflows;
> they cannot cold-build to zero guesses as one ticket — same split pattern as CTR-06/CTR-10). This slice builds
> the **revaluation sweep → registry** workflow only. The other two are logged as the CRE-01 remainder at the
> bottom: **CRE-01b** (underwriting/controller: origination/draw/close/status) and **CRE-01c**
> (default/recovery → DefaultCoordinator).

---

## Deliverable
A committed Go module at **`cre/revaluation/`** (monorepo `cre/` — harness §3) that compiles to `wasip1` and
implements the **WOOF-02 gas-bounded revaluation producer** (§8.1): an off-chain re-appraisal batch arrives,
the workflow reaches **identical consensus** on the `(lien, mark)` set, **shards** it into gas-bounded batches,
**dedups** across the full sweep, enforces equal-length, and emits **one `WriteReport` per shard** to the
`ZipcodeOracleRegistry` as the §8.0 envelope `abi.encode(uint8 reportType=3, bytes payload)` where
`payload = abi.encode(address[] liens, uint256[] prices, uint32 ts)`. Encoding is delegated to the **shared
`cre/zipreport` library** (`zipreport.Revaluation`, CRE-00) — this slice does NOT re-implement the handshake.

## Spec §
- **§8.1** "Revaluation sharding (the WOOF-02 discharge)" — the producer runbook this slice implements verbatim:
  (i) shard a multi-lien re-mark into gas-bounded batches sized to a fixed `MAX_LIENS_PER_REPORT`; (ii) one
  `WriteReport` per shard (each batch independently atomic); (iii) dedup across the full sweep + enforce
  equal-length `liens`/`prices` **before** encoding. **No cron heartbeat — the mark is event-driven Proof.**
- **§8.0** — the report envelope + the reportType-3 row (`address[] liens, uint256[] prices, uint32 ts` →
  `ZipcodeOracleRegistry`). Encoder BUILT as `cre/zipreport` (CRE-00).
- **§8.9 (DEC-01, RESOLVED)** — CRE-01 builds against **mock Proof + mock feeds**; the real Proof-of-Value
  re-appraisal endpoints swap in later (the §8.10 source map). So the mark **source** is a documented mock seam
  this window, NOT a live integration.
- **§8.10** — the per-node fetch + identical-consensus model (facts, not estimates). raw PII never enters
  consensus (the marks are derived values, not PII).
- **§17** — every wiring slot (receiver address, chain selector) comes from Config (re-pointable), not hardcoded.

## Binds to (verified by inspection — do NOT cite blind)

### A. The filed report consumer — `ZipcodeOracleRegistry` (the decode site)
- **`contracts/src/ZipcodeOracleRegistry.sol:128-138`** `_processReport(bytes calldata report)`:
  `abi.decode(report, (uint8, bytes))`, requires `reportType == REVALUATION (3)` (`:29,130`), then
  `abi.decode(payload, (address[] liens, uint256[] prices, uint32 ts))` (`:131-132`), requires
  `liens.length == prices.length` (`LengthMismatch`, `:133`), loops `_writePrice` (`:134-137`).
- **`_writePrice` guards (`:141-148`) — the producer-relevant fail-closed rules:**
  - `price == 0` → revert (`PriceOracle_InvalidAnswer`, `:142`). **Producer MUST drop/refuse any zero price
    before encoding.**
  - `price > type(uint208).max` → revert (`:143`). (18-dp marks are far below this; note it, no special handling.)
  - `ts > block.timestamp` → `FutureTimestamp` (`:144`). **Producer uses `ts = uint32(runtime.Now().Unix())`** —
    always ≤ now on-chain (DON time ≈ chain time); never stamp a future ts.
  - `ts <= cache[lien].timestamp` → `StaleReport` (`:145`). **Strictly-newer per lien.** `runtime.Now()` is
    monotonic across distinct sweeps, so this holds in normal operation. **Known fail-closed edge:** a lien
    seeded/revalued in the *same wall-clock second* would make a second push that second revert its shard — the
    long validity window tolerates it (the lien stays on its prior mark until the next push, §8.1). Do NOT
    special-case it (no per-lien `cache.timestamp` read-back) — that is out of the §8.1 runbook.
  - `_strictDecimals(lien) != 18` → `InvalidLienDecimals` (`:146,152-156`). **The key is the lien TOKEN ADDRESS**
    (the registry is keyed by token address, never `lienId` — `:45-46`). The 18-dp guard is the on-chain
    backstop; the producer sends token addresses, the contract enforces decimals.
- **All-or-nothing batch is intentional (`:119-126` natspec)** — a poison entry reverts its own shard only;
  sharding bounds the blast radius. The producer does NOT try to make a partial batch land.
- **The encoder is already pinned to this exact tuple:** `cre/zipreport/report.go:215-220`
  `Revaluation(liens []common.Address, prices []*big.Int, ts uint32)` — errors on length mismatch, wraps
  `reportType 3`. Round-trip-tested against this decode in `cre/zipreport/report_test.go`. **Import it; do not
  re-encode.**

### B. cre-sdk-go bindings (verified against `reference/cre-sdk-go/`)
- **`http.Trigger`** — `capabilities/networking/http`, `Trigger(*http.Config) cre.Trigger[*Payload, *Payload]`
  (`trigger_sdk_gen.go:16-23`). Handler `onReappraisal(cfg *Config, runtime cre.Runtime, payload *http.Payload)`.
  **`http.Payload.Input []byte`** (`trigger.pb.go:116-168`) carries the JSON batch body. `http.Config` has
  `AuthorizedKeys []*AuthorizedKey` — leave empty/Config-driven for the build.
- **`cre.RunInNodeMode[C,T](cfg, runtime, fn func(C, cre.NodeRuntime)(T,error), ca ConsensusAggregation[T]) Promise[T]`**
  (`cre/runtime.go:166-225`). `.Await()` → `(T, error)`.
- **`cre.ConsensusIdenticalAggregation[T]()`** (`cre/consensus_aggregators.go:31-40`). **`T` may be a STRUCT of
  identical-type fields and SLICES** — `isIdenticalType` (`:198-225`) accepts string/bool/all int+uint widths/
  float, **slices/arrays (recursively)**, structs (all exported fields identical-type), maps (string-keyed),
  and `*big.Int` (special-cased). **Carrier pinned to `[]string` fields ONLY** (unambiguously Wrap-able +
  JSON-native), NOT `[]common.Address`/`[]*big.Int` in the carrier — convert on the DON side. See K2.
- **`runtime.Now() time.Time`** (`cre/runtime.go:27-28`); test determinism via
  `testutils.(*TestRuntime).SetTimeProvider(func() time.Time)` (`cre/testutils/runtime.go:88-91`).
- **The write path** — `runtime.GenerateReport(&cre.ReportRequest{EncodedPayload, EncoderName:"evm",
  SigningAlgo:"ecdsa", HashingAlgo:"keccak256"})` → `(&evm.Client{ChainSelector}).WriteReport(runtime,
  &evm.WriteCreReportRequest{Receiver, Report, GasConfig:&evm.GasConfig{GasLimit}})`. **Copy
  `cre/scaffold/workflow.go:108-125` verbatim** (the `writeReport` helper) — it is the proven idiom.
- **Test harness** — `testutils.NewRuntime`, `evmmock.NewClientCapability(chainSelector,t)`,
  `evmmock.AddContractMock(receiver, mock, views, writeCap)` capturing the report bytes. **Copy
  `cre/scaffold/main_test.go:52-78` verbatim** as `runHandler`.

### C. The module skeleton to clone — `cre/scaffold/` (CRE-00)
Clone the scaffold's file shape exactly: `main.go` (`//go:build wasip1`, `wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)`),
`main_host.go` (`//go:build !wasip1`, no-op `main()`), `workflow.go` (untagged — the logic + handlers, host-testable),
`go.mod`, `project.yaml`, `.env.example`, `secrets.yaml.example`, `README.md`.
**go.mod replace set (correct it for this slice — do NOT copy the scaffold's blindly):** seed from `cre/scaffold`,
then (a) the relative paths `../../reference/...` and `../zipreport` are correct as-is (`cre/revaluation/` is the
same depth as `cre/scaffold/`); (b) **this slice uses `http`, not `cron`** — ADD a require + `replace
github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http =>
../../reference/cre-sdk-go/capabilities/networking/http`, and you MAY drop the `scheduler/cron` require+replace
(it is unused here). Keep the `evm` + base `cre-sdk-go` + `cre-zipreport` replaces. Then `go mod tidy`. (The
scaffold ships 3 SDK replaces — base/evm/cron — plus `cre-zipreport`; swap cron→http.)

## Module layout (author exactly this)
```
cre/revaluation/
  go.mod                  # module cre-revaluation ; go 1.25.3 ; the scaffold's replaces (SDK pins + cre-zipreport)
  .gitignore              # /.env, secrets.yaml
  .env.example            # CRE_* / config vars documented
  secrets.yaml.example    # illustrative (no live secret needed — see K5)
  project.yaml            # cre-cli project file (clone scaffold)
  README.md               # what it is, the trigger, the gate, the mock-feed seam
  main.go                 # //go:build wasip1 — wasm runner entrypoint (clone scaffold)
  main_host.go            # //go:build !wasip1 — no-op main (clone scaffold)
  workflow.go             # initFn + onReappraisal handler + observe + shard + writeReport (the logic)
  workflow_test.go        # host sim test (table-driven sharding + per-shard decode asserts)
```

## Key requirements

### K1 — trigger + Config
- **One trigger: `http.Trigger`** (§8.1 — origination/revaluation are http/event-driven, **no cron heartbeat**).
  The off-chain Proof-of-Value re-appraisal pipeline POSTs the batch; `http.Payload.Input` is the JSON body.
- `Config` (JSON, `cre.ParseJSON[Config]`): `ChainSelector uint64`, `Registry string` (the
  `ZipcodeOracleRegistry` receiver address), `MaxLiensPerReport int` (the shard cap; **default + validate** — if
  `<= 0`, fall back to the pinned default `50`), `WriteGasLimit uint64` (default `600_000` if 0),
  `AuthorizedKeys []string` (optional, for `http.Config`). All addresses via Config (§17); **no hardcoded
  address.** `MAX_LIENS_PER_REPORT` default = **50** — a TUNABLE constant "calibrated on the target chain"
  (§8.1); the on-chain `_processReport` loop is O(n) with a per-entry `decimals()` staticcall + SSTORE, so 50
  keeps a shard's processing well under the report `GasLimit`. Document it as tunable; **log the shard count**.

### K2 — the consensus carrier (the load-bearing type decision — pinned, not guessed)
- The node-mode observation returns a struct of **parallel `[]string` slices ONLY**:
  ```go
  type Marks struct {
      Liens  []string `json:"liens"`  // hex lien-token addresses (the registry key)
      Prices []string `json:"prices"` // base-10 decimal strings of the 18-dp equity marks
  }
  ```
  (the JSON tags are the off-chain feed contract — see K3 for the wire shape.)
  `[]string` is unambiguously `isIdenticalType` + `values.Wrap`-able + JSON-native. Do **NOT** put
  `[]common.Address` or `[]*big.Int` in the carrier (they pass `isIdenticalType` by reflection but are an
  avoidable Wrap risk) — **parse to `common.HexToAddress` / `new(big.Int).SetString(s,10)` on the DON side,
  AFTER consensus.**
- Consensus = **`cre.ConsensusIdenticalAggregation[Marks]()`** (the marks are notarized facts → identical, not
  median; §8.1/§8.10).

### K3 — the handler + observe (node mode) = the §8.9 MOCK-FEED SEAM
- **The single handler `onReappraisal(cfg *Config, runtime cre.Runtime, payload *http.Payload)`** runs in DON
  mode and holds `payload.Input` (`[]byte`, the JSON batch body). Registered in `initFn`:
  `cre.Handler(httpcap.Trigger(&httpcap.Config{}), onReappraisal)` (import the capability package aliased
  `httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"` to avoid the stdlib `net/http`
  name clash; an empty `&httpcap.Config{}` — no `AuthorizedKeys` — is valid for the build).
- **Payload → node mode (the load-bearing plumbing — pinned, do NOT improvise):** `RunInNodeMode[C,T]`'s first
  type-param `C` is a **FREE generic**, NOT the workflow `*Config`. The handler passes the raw trigger bytes in
  as `C = []byte`:
  ```go
  marks, err := cre.RunInNodeMode(payload.Input, runtime, observe,
      cre.ConsensusIdenticalAggregation[Marks]()).Await()
  ```
  with `observe(in []byte, _ cre.NodeRuntime) (Marks, error)` that `json.Unmarshal(in, &m)` → returns `m`.
  - **WRONG (do not do this):** carrying the batch on the workflow `*Config`. `*Config` is parsed once from the
    static JSON config at init (`cre.ParseJSON[Config]`) and has no per-invocation trigger body — adding a
    `[]byte` field to `Config` for the batch is an error. The scaffold's `observe(_ *Config, …)` IGNORES its
    config and returns a constant; it is **not** a precedent for per-call data. The verified mechanism is the
    free `C` type-arg above (`reference/cre-sdk-go/cre/runtime.go:166-193` — `config C` is captured and passed
    verbatim into `fn`; `C` is unconstrained).
- **THIS IS THE MOCK SEAM (§8.9):** for the build, every node `json.Unmarshal`s the identical trigger-supplied
  re-appraisal batch (deterministic → identical consensus holds). A prominent comment block on `observe` marks
  it: *"§8.9 MOCK FEED — replace this `json.Unmarshal` of the trigger batch with a per-node
  `httpcap.Client.SendRequest` to the real Proof-of-Value feed + on-node hash/cert-chain verify (§8.10) when the
  endpoints integrate; the `RunInNodeMode` + consensus + shard + write machinery is unchanged."*
- **`Marks` JSON wire shape (pin it — the README documents it as the feed contract):**
  ```json
  { "liens": ["0x…", "0x…"], "prices": ["1500000000000000000000", "…"] }
  ```
  i.e. `type Marks struct { Liens []string \`json:"liens"\`; Prices []string \`json:"prices"\` }`. Lowercase
  `liens`/`prices` JSON tags are part of the contract the off-chain pipeline must match.
- **Note:** `observe` MUST NOT call `runtime.GetSecret` (NodeRuntime has no SecretsProvider; §8.1 forbids
  secrets in a consensus observation). Any DON-only secret read (none needed this slice) stays in the handler.

### K4 — validate → dedup → shard → encode → write (the WOOF-02 core)
Pure, table-testable helper `func shardRevaluation(m Marks, maxPer int) ([]Shard, error)` where
`Shard{Liens []common.Address; Prices []*big.Int}`:
1. **Length-equal** `len(Liens) == len(Prices)` (error early — do NOT rely on the on-chain `LengthMismatch`).
2. **Parse** each lien + price. **Lien:** `common.HexToAddress` does NOT error on bad input (it silently
   zero-pads/truncates) — so **validate the hex string FIRST** (require `0x` prefix + 40 hex chars; reject the
   zero address) before converting, else a malformed feed entry becomes `address(0)` and corrupts a mark. **Price:**
   `new(big.Int).SetString(s,10)` — **reject the `ok==false` (malformed) case AND zero** (the on-chain `price==0`
   guard is the backstop, but §8.1 says enforce before encoding).
3. **Dedup across the full sweep** — a lien appearing twice is an error (on-chain it is silent last-write-wins, a
   correctness footgun §8.1 mandates the producer prevent). Keep first; error on any dup (fail-closed) — or, if a
   "last-wins-with-warning" policy is preferred, pick ONE and pin it in the ticket. **Pinned: error on dup**
   (fail-closed, matches the all-or-nothing ethos; an off-chain pipeline emitting a dup is a bug to surface).
4. **Shard** into batches of ≤ `maxPer`, preserving order. `log` the shard count + total liens.
5. Each shard → `zipreport.Revaluation(shard.Liens, shard.Prices, ts)` (ts = the single DON-stamped
   `uint32(runtime.Now().Unix())`, shared across all shards of one sweep) → `writeReport`.
- **One `WriteReport` per shard**, each independently atomic on-chain. A shard's write error is returned
  (fail-safe: the handler logs; the §8.1 model tolerates a failed shard — its liens stay on the prior mark).
- **No-op fail-safe:** empty `Marks` (no liens) ⇒ no write, log and return nil. Unset `Registry` ⇒ no-op.

### K5 — secrets/scaffolding
- No live secret is required for this slice (the mock feed arrives via the trigger payload). `secrets.yaml.example`
  is illustrative. If a future real-feed swap needs a DON-only key, it is read in the **handler** (not `observe`).

### K6 — docs
- `README.md`: what it is (the WOOF-02 revaluation producer), the http trigger + JSON batch shape, the
  `MAX_LIENS_PER_REPORT` tunable, **the §8.9 mock-feed seam + the §8.10 swap-in note**, the gate commands, the
  StaleReport same-second fail-closed edge. Cross-link §8.1 + `cre/zipreport`.

## Do NOT
- Do **NOT** re-implement the §8.0 envelope or the reportType-3 payload encode — import `cre/zipreport`.
- Do **NOT** add a `cron.Trigger` heartbeat (§8.1: the mark is event-driven Proof; a cron sweep is explicitly
  out of the model).
- Do **NOT** implement CRE-01b (origination/draw/close/status → controller) or CRE-01c
  (default/recovery → DefaultCoordinator) here — those are the logged remainder.
- Do **NOT** put `[]common.Address` / `[]*big.Int` in the consensus carrier (K2); convert post-consensus.
- Do **NOT** call `GetSecret` inside `observe` (node mode); do **NOT** stamp a future `ts`.
- Do **NOT** add a per-key try/catch expectation or attempt partial-batch landing — the all-or-nothing shard is
  the intended WOOF-02 design; the producer mitigates via sharding only.
- Do **NOT** hardcode any address (§17 — Config-driven, re-pointable).

## Done when (the per-track CRE gate — wasip1 variant)
1. **`cd cre/revaluation && go build ./... && go vet ./...`** exits 0 (host), **and**
   `GOOS=wasip1 GOARCH=wasm go build ./...` exits 0 (the wasip1 target — the real gate).
2. **`cd cre/revaluation && go test ./...`** green, **non-vacuous**, covering:
   - **Encode handshake:** the captured report decodes to `(uint8 reportType=3, bytes payload)` and the payload
     to `(address[] liens, uint256[] prices, uint32 ts)` matching the input set — asserted by decoding the
     bytes (NOT by trusting `zipreport`). At least one assert proves the bytes `abi.decode` to the exact
     `ZipcodeOracleRegistry._processReport` tuple.
   - **Sharding:** N liens with `MaxLiensPerReport=k` ⇒ `ceil(N/k)` writes; each shard's decoded `liens`/`prices`
     are the right ordered subset; `ts` identical across shards; the union of shards == the input (no drop/dup).
   - **Dedup:** a duplicate lien ⇒ error, **no** write (fail-closed).
   - **Length mismatch / zero price / malformed address ⇒ error, no write.**
   - **No-op:** empty marks ⇒ 0 writes; unset `Registry` ⇒ 0 writes.
   - **Full handler path** (the sim): call `onReappraisal(cfg, runtime, &httpcap.Payload{Input: <JSON batch
     bytes>})` directly (as `main_test.go` calls `onCron(cfg, runtime, nil)` directly — but here the constructed
     `*httpcap.Payload` carries the batch, since this handler reads `payload.Input`). The path exercises
     `RunInNodeMode(payload.Input, …)` + `ConsensusIdenticalAggregation[Marks]` + `runtime.Now()` stamp +
     `zipreport.Revaluation` + `GenerateReport` + `WriteReport`, under `testutils` + `evmmock`, asserting the
     captured envelope(s). This proves the `Marks` carrier actually `values.Wrap`s through identical consensus
     (a `RunInNodeMode` failure here = the carrier-type guess was wrong → fold back) AND that the
     payload-into-node-mode plumbing (K3) compiles and runs.
3. The Go module is **committed to `cre/revaluation/`** (monorepo `cre/`), code only — no `build/`/`docs/`/
   `contracts/` staged in the code commit.
4. **Cold-build verdict is "yes," not "yes-with-guesses."** If the builder must guess the carrier Wrap-ability,
   the trigger payload plumbing into node mode, or any SDK signature, the gap folds back into this ticket.

## Depends on
- **CRE-00** (`cre/zipreport` encoder + `cre/scaffold` template) — DONE.
- The filed `ZipcodeOracleRegistry` (built, ABI fixed) — the decode site.
- `reference/cre-sdk-go` present (harness §7). No anvil needed for the unit gate (the sim is mock-backed).

## Discharges / spawns
- Discharges no inbound obligation row (none owed *by* CRE-01a).
- **Logs the CRE-01 remainder** (set the next `NEXT` from these):
  - **CRE-01b — underwriting/controller producer:** origination (rt1, `http.Trigger`) + draw (rt2) + close (rt4)
    + status (rt5/6) → `ZipcodeController`. Carries the Proof-gate booleans (§8.9/§8.10, mock) + `equityMark` +
    `siloId` (CTR-03 routing). The headline, largest slice. Encoders: `zipreport.Origination/Draw/Close/Status`.
  - **CRE-01c — default/recovery producer:** reportType 8 action family → `DefaultCoordinator`
    (LOCK/RELEASE M1-live; DEFAULT/RECOVERY/RESOLVE/WRITEOFF go live with the M2 demo, §8.4). Encoders:
    `zipreport.CoordLock/Release/Default/Recovery/Resolve/WriteOff`.

## Reconciliation notes (precision the ticket pins beyond the literal §8.1 prose)
- §8.1 lists the producer rule as shard/one-write-per-shard/dedup+length-check; it does not name the consensus
  carrier type, the trigger choice, or the dup policy. This ticket pins: **trigger = `http.Trigger`** (the only
  §8.1-consistent event-driven, non-cron option that carries a batch), **carrier = `Marks{[]string,[]string}`**
  (the verified-Wrap-able shape), **dup policy = error/fail-closed**. Each is a derivation from §8.1 + the
  verified SDK surface, not an invention — flagged here for the spec-fidelity critic.
- The §8.9 mock-feed seam is the explicit, spec-sanctioned build posture ("CRE-01 builds against mock Proof +
  mock feeds") — not a shortcut. The node-mode + identical-consensus + shard + write machinery is the real,
  permanent structure; only the per-node fetch source is mocked-via-trigger this window.
