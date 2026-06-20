# CRE-01c — the loss-action producer (reportType 8 → `DefaultCoordinator`)

> **Track:** (R) — a wasip1 CRE report-path workflow (CRE-OPS-ROUTING: CRE-01 is pure (R) through existing
> receivers). **This is the THIRD and LAST of three CRE-01 slices** (the split was forced by a 4-critic fan-out
> on CRE-01 — same pattern as CTR-06/CTR-10). CRE-01a (revaluation → registry, rt3) and CRE-01b (origination/
> draw/close/status → controller, rt1/2/4/5,6) are DONE. This slice builds the **loss-side / default-recovery
> producer**: the §8.4 reportType-8 action family (LOCK / RELEASE / DEFAULT / RECOVERY / RESOLVE / WRITEOFF) →
> the `DefaultCoordinator`. It completes the CRE-01 controller/loss family; there is no further CRE-01 slice.

---

## Deliverable
A committed Go module at **`cre/coordinator/`** (monorepo `cre/` — harness §3) that compiles to `wasip1` and
implements the **§8.4 default / recovery producer**: an off-chain loss event arrives via `http.Trigger`, the
workflow reaches **identical consensus** on the event record, normalizes + **dispatches on the action
discriminant**, validates the per-action required fields, encodes the matching payload via the shared
**`cre/zipreport`** library, and emits **one `WriteReport`** to the `DefaultCoordinator` as the §8.0 envelope
`abi.encode(uint8 reportType, bytes payload)` — where the payload is itself the §8.4 inner
`abi.encode(uint8 action, bytes actionData)`. The six actions it produces (all reportType 8):

| action (payload discriminant) | action byte | encoder | actionData tuple | M1-live? |
|---|---|---|---|---|
| `lock` | 0 `Lock` | `zipreport.CoordLock` | `(bytes32 lienId, address originator, uint256 amount)` | **yes** (post launch bond) |
| `release` | 1 `Release` | `zipreport.CoordRelease` | `(bytes32 lienId)` | **yes** (clean repay) |
| `default` | 2 `Default_` | `zipreport.CoordDefault` | `(bytes32 lienId, uint256 atRisk)` | M2 demo |
| `recovery` | 3 `Recovery` | `zipreport.CoordRecovery` | `(bytes32 lienId, uint256 recoveryProceeds)` | M2 demo |
| `resolve` | 4 `Resolve` | `zipreport.CoordResolve` | `(bytes32 lienId, uint256 capitalSlashAmount)` | M2 demo |
| `writeoff` | 5 `WriteOff` | `zipreport.CoordWriteOff` | `(bytes32 lienId, uint256 capitalSlashAmount)` | M2 demo |

**The M1-live vs M2 distinction is OPERATIONAL, not a code gate** — the off-chain encode handshake is identical
machinery for all six actions; the producer builds + tests all six. Which actions the off-chain pipeline
actually fires when (LOCK/RELEASE in M1; the economic family with the M2 demo) is documented in the README, not
branched in code. (Discharges the framing of the open obligation **"LOSS — the default/slash flow is M2, not
M1-live"** — this producer IS that `rt8` driver; the contract half is built + mock-tested, the live firing of
the economic actions is M2 ops.)

Encoding is delegated to `cre/zipreport` (CRE-00) — this slice does **NOT** re-implement the §8.0 envelope or
the §8.4 inner action envelope.

## Spec §
- **§8.4 "Default / recovery"** — the producer this slice implements verbatim. Delinquency status and recovery
  amounts are **off-chain truths** arriving as DON-signed **reportType 8** to the `DefaultCoordinator`,
  action-discriminated `payload = abi.encode(uint8 action, bytes actionData)`, decoded per action. The six
  action rows + their `actionData` tuples + the units are pinned in §8.4 (lines 645-662) and reproduced under
  "Binds to A". **Units (§8.4 line 660):** `atRisk`/`recoveryProceeds` are **18-dp USD**; `amount`/
  `capitalSlashAmount` are **xALPHA (18-dp)**. The **capital-vs-premium split + timing + default-state policy**
  are computed **off-chain** (the §13 trust boundary); the producer carries the magnitudes, the escrow enforces
  only `amount ≤ bond`.
- **§8.4 line 651 — TWO receivers for one real-world default.** The bare reportType-**5** default-*status*
  report goes to the **`ZipcodeController`** (§4.4d, status marker + legal-action event) — **that is CRE-01b's
  rt5, already BUILT.** The reportType-**8** DEFAULT economic action (the markdown `atRisk` → provision +
  `SzipNavOracle`) goes to the **`DefaultCoordinator`** — **that is THIS slice.** The split is on the *receiver*,
  not on "default vs not". This producer does **NOT** emit any controller status marker (that is not its
  receiver).
- **§8.0** — the shared envelope `abi.encode(uint8 reportType, bytes payload)` + the reportType-8 row
  (line 524). Encoder BUILT as `cre/zipreport` (CRE-00).
- **§8.9 (DEC-01, RESOLVED) — NO on-chain boolean Proof gate on the loss family.** §8.9 (line 847) lists
  "§8.4 recovery" among reports carrying a credit fact that **needs its facts attested in a CRE-consumable
  (per-lien, signed, deterministic, identical-consensus) form**. For the loss family that attestation **IS the
  identical consensus over the (mocked-via-trigger) loss facts** — exactly the posture CRE-01a (revaluation)
  built: there is **no boolean `Gates` struct and no "emit only if gates pass" fail-closed branch** here (unlike
  CRE-01b's origination/draw pre-mint gate). The `DefaultCoordinator` exposes **no on-chain gate surface** — its
  six decode tuples carry no booleans; the §13 trust boundary (the Forwarder + Timelock-pinned workflow
  identity, `DefaultCoordinator.sol:22-43`) is the entry guard. The §8.9 real-feed swap (per-node fetch +
  on-node hash/cert-chain verify of the recovery/foreclosure artifacts) replaces the mock `json.Unmarshal` in
  `observe` later — same mock seam as CRE-01a/01b.
- **§17** — every wiring slot (receiver address, chain selector) comes from Config (re-pointable), not hardcoded.

## Binds to (verified by inspection — do NOT cite blind)

### A. The filed report consumer — `DefaultCoordinator` (the decode sites)
`contracts/src/loss/DefaultCoordinator.sol`. `REPORT_TYPE = 8` (`:49`). The shared envelope is decoded in
`_processReport` (`:181-201`): `abi.decode(report, (uint8 reportType, bytes payload))` → rejects
`reportType != 8` (`InvalidReportType`, `:183`) → `abi.decode(payload, (uint8 action, bytes data))` (`:185`) →
dispatches on `action`, reverting `InvalidAction` (`:199`) on an unknown byte. The action enum
(`DefaultCoordinator.sol:52-60`): `Lock=0, Release=1, Default_=2, Recovery=3, Resolve=4, WriteOff=5`.

- **`Lock` (0) → `_lock` (`:206-215`)**, `data = abi.decode(data,(bytes32 lienId, address originator,
  uint256 amount))` (`:207`). Requires `lienLoss[lienId].status == None` (else `BadStatus`, `:208`); sets
  `Bonded`; calls `escrow.lockXAlpha(lienId, originator, amount)`. **The escrow guards
  (`LienXAlphaEscrow.sol:156-160`):** reverts `ZeroOriginator` on `originator==0`, `SelfOriginator` on
  `originator==escrow`, `ZeroAmount` on `amount==0`, `BondExists` on a duplicate `lienId`.
- **`Release` (1) → `_release` (`:219-228`)**, `data = abi.decode(data,(bytes32 lienId))` (`:220`). Requires
  `Bonded` (`:221`); flips to `None`; `escrow.releaseXAlpha(lienId)` returns the full bond to the recorded
  originator.
- **`Default_` (2) → `_default` (`:234-247`)**, `data = (bytes32 lienId, uint256 atRisk)` (`:235`). Requires
  `Bonded` (`:236`); **reverts `ZeroAtRisk` on `atRisk==0` (`:237`)**; sets `provision = atRisk×(1−recoveryFloor)/1e18`
  (rounds DOWN), status `Defaulted`, `totalProvision += p`, `navOracle.writeProvision(totalProvision)`.
- **`Recovery` (3) → `_recovery` (`:253-265`)**, `data = (bytes32 lienId, uint256 recoveryProceeds)` (`:254`).
  Requires `Defaulted` (`:255`); reduces provision by `min(provision, proceeds)`, floored at 0; status STAYS
  `Defaulted`; pushes `totalProvision`. **`recoveryProceeds==0` does NOT revert** (a no-op heal: reduction 0,
  redundant oracle write).
- **`Resolve` (4) → `_resolve` (`:276-290`)**, `data = (bytes32 lienId, uint256 capitalSlashAmount)` (`:277`).
  Requires `Defaulted` (`:278`); heals provision to 0; then `if (capitalSlashAmount != 0)
  escrow.slashXAlphaToCapital(lienId, capitalSlashAmount)` (the escrow reverts `ExceedsBond` if
  `capitalSlashAmount > bond`, `LienXAlphaEscrow.sol:194`) then `if (escrow.bondAmount(lienId) != 0)
  escrow.slashXAlphaToCohort(lienId)`. **`capitalSlashAmount==0` is LEGAL** (skip the capital slash; route all to
  cohort).
- **`WriteOff` (5) → `_writeOff` (`:297-307`)**, `data = (bytes32 lienId, uint256 capitalSlashAmount)` (`:298`).
  Requires `Defaulted` (`:299`); leaves the provision IN PLACE (the residual IS the realized loss — NO
  `writeProvision` call); routes the bond exactly as `Resolve`. **`capitalSlashAmount==0` is LEGAL** (same).

### B. The encoders — already pinned to these exact tuples (`cre/zipreport/report.go`)
All produce reportType **8** with the inner `(uint8 action, bytes data)` via the unexported `coordEnvelope`
(`report.go:258-260`); each is round-trip-tested against the filed-contract decode in
`cre/zipreport/report_test.go` (`TestCoord{Lock,Release,Default,Recovery,Resolve,WriteOff}RoundTrip`,
`:301-410`). **Import them; do not re-encode.**
- **`CoordLock(lienId [32]byte, originator common.Address, amount *big.Int) ([]byte, error)`** — `report.go:263`.
- **`CoordRelease(lienId [32]byte) ([]byte, error)`** — `report.go:272`.
- **`CoordDefault(lienId [32]byte, atRisk *big.Int) ([]byte, error)`** — `report.go:281`.
- **`CoordRecovery(lienId [32]byte, recoveryProceeds *big.Int) ([]byte, error)`** — `report.go:290`.
- **`CoordResolve(lienId [32]byte, capitalSlashAmount *big.Int) ([]byte, error)`** — `report.go:299`.
- **`CoordWriteOff(lienId [32]byte, capitalSlashAmount *big.Int) ([]byte, error)`** — `report.go:308`.
- Constants: `zipreport.CoordinatorReportType (8)`; `ActionLock(0)/ActionRelease(1)/ActionDefault(2)/
  ActionRecovery(3)/ActionResolve(4)/ActionWriteOff(5)` — `report.go:102-109`.

### C. cre-sdk-go bindings (verified — identical surface to CRE-01b, `cre/controller/`)
Same as CRE-01b — no new SDK surface. `http.Trigger` (`reference/cre-sdk-go/capabilities/networking/http`,
aliased `httpcap`); `cre.RunInNodeMode[C,T]` with `C` a FREE generic = `[]byte` (pass `payload.Input`);
`cre.ConsensusIdenticalAggregation[Application]()` (the carrier here is **string fields only** → trivially
`isIdenticalType`, `reference/cre-sdk-go/cre/consensus_aggregators.go:198-225`); the write path
`runtime.GenerateReport` → `evm.Client{ChainSelector}.WriteReport(runtime, &evm.WriteCreReportRequest{Receiver,
Report, GasConfig})`. **Test harness:** `testutils.NewRuntime`, `evmmock.NewClientCapability`,
`evmmock.AddContractMock` capturing the report bytes — model `cre/controller/workflow_test.go`.

### D. The module skeleton to clone — `cre/controller/` (CRE-01b, the closest sibling)
Clone `cre/controller/`'s file shape exactly (it is already the **http + zipreport** dependency set this slice
needs, with no cron and no sharding — the best seed): `main.go` (`//go:build wasip1`,
`wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)`), `main_host.go` (`//go:build !wasip1`, no-op `main()`),
`workflow.go` (untagged logic + handler), `go.mod`, `project.yaml`, `.env.example`, `secrets.yaml.example`,
`README.md`, `workflow_test.go`.
**go.mod:** seed from `cre/controller/go.mod` (NOT the scaffold's), rename `module cre-controller` →
`module cre-coordinator`, keep its replace set verbatim (base `cre-sdk-go` + `evm` + `networking/http` +
`cre-zipreport`; the relative paths `../../reference/...` and `../zipreport` are correct — same depth), then
`go mod tidy`. **Also rename the internal `controller`→`coordinator` strings** in `project.yaml` (workflow/
project name), `.env.example` (var labels), and `README.md` (no behavioral effect — consistency only). The
test's chain-selector constant `evm.EthereumMainnetBase1` (`cre/controller/workflow_test.go:33`) comes for free
with the clone — reuse it.

## Module layout (author exactly this)
```
cre/coordinator/
  go.mod                  # module cre-coordinator ; go 1.25.3 ; controller's replaces (SDK pins + cre-zipreport)
  .gitignore              # /.env, secrets.yaml
  .env.example            # CRE_* / config vars documented
  secrets.yaml.example    # illustrative (no live secret needed — see K6)
  project.yaml            # cre-cli project file (clone controller)
  README.md               # what it is, the trigger, the 6-action discriminant, the M1-live/M2 split, the mock seam, the gate
  main.go                 # //go:build wasip1 — wasm runner entrypoint (clone controller)
  main_host.go            # //go:build !wasip1 — no-op main (clone controller)
  workflow.go             # initFn + onLossEvent handler + observe + dispatch/validate/encode + writeReport
  workflow_test.go        # host sim test (per-action decode asserts + bad-input errors + no-op)
```

## Key requirements

### K1 — trigger + Config
- **One trigger: `http.Trigger`** (§8.4 — default/recovery are off-chain-event-driven, `trigger→node-mode→
  consensus→GenerateReport→WriteReport`, §8.4 line 665; **no cron heartbeat**). The off-chain loss pipeline POSTs
  one loss event; `http.Payload.Input` is the JSON body.
- `Config` (JSON, `cre.ParseJSON[Config]`): `ChainSelector uint64`, **`Coordinator string`** (the
  `DefaultCoordinator` receiver address — NOTE the field is `Coordinator`, not `Controller`),
  `WriteGasLimit uint64` (default `600_000` if 0), `AuthorizedKeys []string` (optional, for `http.Config`).
  **No hardcoded address** (§17). No `MaxLiensPerReport` (one report per event, no sharding).

### K2 — the consensus carrier (string fields only — pinned, not guessed)
The node-mode observation returns ONE struct carrying every action's fields (the union; per-action validation
in the handler decides which are required). Pin the carrier to **string fields only** — do **NOT** put
`common.Address`, `[32]byte`, or `*big.Int` in the carrier (parse those on the DON side AFTER consensus, exactly
as CRE-01b parses post-consensus). **No `Gates` struct** (no Proof gate on the loss family — see Spec §8.9).
```go
type LossEvent struct {
    Action             string `json:"action"`             // "lock"|"release"|"default"|"recovery"|"resolve"|"writeoff"
    LienID             string `json:"lienId"`             // 0x… 32-byte hex (every action)
    Originator         string `json:"originator"`         // 0x… 20-byte hex (lock ONLY — the release recipient, §13)
    Amount             string `json:"amount"`             // base-10, xALPHA 18-dp (lock ONLY)
    AtRisk             string `json:"atRisk"`             // base-10, 18-dp USD (default ONLY)
    RecoveryProceeds   string `json:"recoveryProceeds"`   // base-10, 18-dp USD (recovery ONLY)
    CapitalSlashAmount string `json:"capitalSlashAmount"` // base-10, xALPHA 18-dp (resolve, writeoff)
}
```
- Consensus = **`cre.ConsensusIdenticalAggregation[LossEvent]()`** (the loss facts are notarized → identical,
  not median; §8.4/§8.9). All fields are `string` → trivially `isIdenticalType`
  (`reference/cre-sdk-go/cre/consensus_aggregators.go:198-225`). The full-handler sim (Done-when 2) proves the
  carrier `values.Wrap`s through `RunInNodeMode` — if it does not, the carrier-shape decision folds back here.

### K3 — the handler + observe (node mode) = the §8.4/§8.9 MOCK-FEED SEAM
- **The single handler `onLossEvent(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload)`** runs in DON
  mode, holds `payload.Input`. Registered in `initFn`:
  `cre.Handler(httpcap.Trigger(&httpcap.Config{}), onLossEvent)`.
- **Payload → node mode (the load-bearing plumbing CRE-01a/01b pinned — do NOT improvise):** `RunInNodeMode[C,T]`'s
  `C` is a **FREE generic**, NOT the workflow `*Config`. Pass the raw bytes as `C = []byte`:
  ```go
  ev, err := cre.RunInNodeMode(payload.Input, runtime, observe,
      cre.ConsensusIdenticalAggregation[LossEvent]()).Await()
  ```
  with `observe(in []byte, _ cre.NodeRuntime) (LossEvent, error)` = `json.Unmarshal(in, &ev)` → return `ev`.
- **THIS IS THE MOCK SEAM (§8.4/§8.9):** for the build, every node `json.Unmarshal`s the identical
  trigger-supplied loss event (deterministic → identical consensus holds). A prominent comment block on
  `observe` marks it: *"§8.4/§8.9 MOCK FEED — replace this `json.Unmarshal` of the trigger event with per-node
  `httpcap.Client.SendRequest` to the real recovery/foreclosure/insurance feeds + on-node hash/cert-chain verify,
  deriving the loss magnitudes (atRisk / recoveryProceeds / capitalSlashAmount) + the capital-vs-premium split
  per node; the `RunInNodeMode` + consensus + dispatch + encode + write machinery is unchanged."*
- **`observe` MUST NOT call `runtime.GetSecret`** (NodeRuntime has no SecretsProvider; §8.1/§8.4 forbid secrets
  + PII in a consensus observation). Any future DON-only secret read stays in the handler.

### K4 — dispatch → validate → encode → write (the core)
After consensus, the handler **`strings.ToLower(strings.TrimSpace(ev.Action))`** and dispatches on the result
(so `"Lock"`/`" lock "` all match; an unknown or empty action ⇒ error, no write). **There is NO Proof gate** —
every well-formed action emits exactly one report. Per-action **required vs optional** field rules (a required
field that is missing/empty/unparseable ⇒ error, no write — a malformed event is a producer-side bug to
surface; "may be 0" fields parse a present value but accept 0):

- **`lock`** (action 0): **required** — `LienID` (bytes32, non-zero), `Originator` (address, **non-zero** — the
  escrow reverts `ZeroOriginator`; it is the RELEASE recipient, §13), `Amount` (`*big.Int`, base-10, **> 0** —
  the escrow reverts `ZeroAmount`). Encode `zipreport.CoordLock(lienId, originator, amount)`.
- **`release`** (action 1): **required** — `LienID` (bytes32, non-zero). All other carrier fields ignored.
  Encode `zipreport.CoordRelease(lienId)`.
- **`default`** (action 2): **required** — `LienID` (bytes32, non-zero), `AtRisk` (`*big.Int`, base-10, **> 0** —
  the contract reverts `ZeroAtRisk`). Encode `zipreport.CoordDefault(lienId, atRisk)`.
- **`recovery`** (action 3): **required** — `LienID` (bytes32, non-zero), `RecoveryProceeds` (`*big.Int`,
  base-10, present, **may be 0** — the contract tolerates a 0 heal). Encode
  `zipreport.CoordRecovery(lienId, recoveryProceeds)`.
- **`resolve`** (action 4): **required** — `LienID` (bytes32, non-zero), `CapitalSlashAmount` (`*big.Int`,
  base-10, present, **may be 0** — 0 means skip the capital slash, route all to cohort). Encode
  `zipreport.CoordResolve(lienId, capitalSlashAmount)`.
- **`writeoff`** (action 5): **required** — `LienID` (bytes32, non-zero), `CapitalSlashAmount` (`*big.Int`,
  base-10, present, **may be 0**). Encode `zipreport.CoordWriteOff(lienId, capitalSlashAmount)`.
- **One `WriteReport`** per well-formed event → the `DefaultCoordinator` (`cfg.Coordinator`). A write error is
  **returned** from the handler (the §8.4 model surfaces it; do not swallow).
- **No-op fail-safe:** `strings.TrimSpace(Coordinator) == ""` ⇒ no write, log, return nil. An unknown/empty
  `Action` or a missing/unparseable required field ⇒ **error** (return it).
- **Anticipated on-chain reverts the producer does NOT pre-check (surface, do not retry-loop):** `lock` can
  revert `BadStatus` (lien not `None`), `SelfOriginator` (originator == escrow), `BondExists` (duplicate bond),
  or hit an unwired escrow; `release`/`default`/`recovery`/`resolve`/`writeoff` revert `BadStatus` on the wrong
  status-machine state (`release` needs `Bonded`; `default` needs `Bonded`; `recovery`/`resolve`/`writeoff` need
  `Defaulted`); `resolve`/`writeoff` revert `ExceedsBond` if `capitalSlashAmount > bond`. These are on-chain
  backstops; the producer sends a well-formed report, it does NOT replicate the coordinator's status machine.
  The write error propagates (above).

### K5 — hex parsing (bytes32 AND address)
- **`parseBytes32(s string, allowZero bool) ([32]byte, error)`** — reuse CRE-01b's helper verbatim
  (`cre/controller/workflow.go:266-286`): requires `0x`/`0X` + **exactly 64 hex chars**, rejects non-hex, then
  `common.HexToHash(s)` → `[32]byte`; if `!allowZero` rejects the zero value. `lienId` → `parseBytes32(s, false)`
  (every action, non-zero).
- **`parseAddress(s string) (common.Address, error)`** — NEW (the controller slice keys only by bytes32; this
  slice's `lock` carries an originator **address**). Mirror the validate-hex-first discipline: require `0x`/`0X`
  + **exactly 40 hex chars**, reject non-hex, reject the zero address, then `common.HexToAddress(s)`. Clone the
  shape from `cre/revaluation/workflow.go`'s address `parseLien` (40-hex validation) — `common.HexToAddress`
  silently zero-pads/truncates bad input, so validate FIRST. Caller: `lock` originator.
- **`parsePositiveBig(s string) (*big.Int, error)`** (base-10, **> 0**) and **`parseNonNegBig(s string)
  (*big.Int, error)`** (base-10, **≥ 0**) — reuse CRE-01b's helpers verbatim (`cre/controller/workflow.go:288-312`).
  `lock` Amount + `default` AtRisk → `parsePositiveBig`; `recovery` RecoveryProceeds + `resolve`/`writeoff`
  CapitalSlashAmount → `parseNonNegBig`.

### K6 — secrets/scaffolding
- No live secret is required (the mock feed arrives on the trigger payload). `secrets.yaml.example` is
  illustrative. A future real-feed swap reads any DON-only key in the **handler**, never `observe`.

### K7 — docs
- `README.md`: what it is (the §8.4 loss-action producer), the http trigger + the per-action JSON event shape
  (one documented example per action), the **6-action discriminant** table, the **M1-live (LOCK/RELEASE) vs M2
  (DEFAULT/RECOVERY/RESOLVE/WRITEOFF) operational split**, the **§8.4/§8.9 mock-feed seam + swap-in note**, the
  **two-receivers-for-one-default** note (the controller rt5 status marker is CRE-01b; this is the coordinator
  rt8 economic action), and the gate commands. Cross-link §8.4/§8.9/§8.0 + `cre/zipreport`.

## Do NOT
- Do **NOT** re-implement the §8.0 envelope, the §8.4 inner action envelope, or any payload encode — import
  `cre/zipreport` (`CoordLock`/`CoordRelease`/`CoordDefault`/`CoordRecovery`/`CoordResolve`/`CoordWriteOff`).
- Do **NOT** add a `cron.Trigger` heartbeat (§8.4: event-driven, no cron).
- Do **NOT** add a boolean Proof `Gates` struct or a "emit only if gates pass" branch (no on-chain gate surface
  on the loss family; the identical consensus IS the attestation — §8.9/CRE-01a posture).
- Do **NOT** emit any `ZipcodeController` status marker (rt5/rt6) here — that is CRE-01b. This producer's only
  receiver is the `DefaultCoordinator` (rt8).
- Do **NOT** put `common.Address` / `[32]byte` / `*big.Int` in the consensus carrier (K2); parse post-consensus.
- Do **NOT** call `GetSecret` inside `observe` (node mode).
- Do **NOT** pre-check the coordinator's status machine or the escrow bond size (surface the on-chain revert).
- Do **NOT** hardcode any address (§17 — Config-driven, re-pointable).

## Done when (the per-track CRE gate — wasip1 variant)
1. **`cd cre/coordinator && go build ./... && go vet ./...`** exits 0 (host), **and**
   `GOOS=wasip1 GOARCH=wasm go build ./...` exits 0 (the wasip1 target — the real gate).
2. **`cd cre/coordinator && go test ./...`** green, **non-vacuous**, covering:
   - **Encode handshake (per action):** the captured report decodes to `(uint8 reportType, bytes payload)` with
     `reportType == 8`, then the payload to `(uint8 action, bytes data)` with the expected action byte, then
     `data` to the EXACT `DefaultCoordinator` decode tuple for that action — asserted by decoding the bytes
     (NOT by trusting `zipreport`). All six: lock → `(bytes32,address,uint256)` action 0; release → `(bytes32)`
     action 1; default → `(bytes32,uint256)` action 2; recovery → `(bytes32,uint256)` action 3; resolve →
     `(bytes32,uint256)` action 4; writeoff → `(bytes32,uint256)` action 5. Assert the decoded scalars equal the
     input (lienId, originator, the magnitudes), and the reportType/action against BOTH the constant and the
     literal.
   - **Validation errors ⇒ no write:** unknown action; empty action; malformed/short `lienId` hex; zero
     `lienId`; on `lock` — zero/malformed `originator`, zero/non-base-10 `amount`; on `default` — zero/non-base-10
     `atRisk`. (A 0 `recoveryProceeds`/`capitalSlashAmount` on recovery/resolve/writeoff is **ACCEPTED** → 1 write.)
   - **No-op:** unset `Coordinator` ⇒ 0 writes.
   - **Full handler path (the sim):** call `onLossEvent(cfg, runtime, &httpcap.Payload{Input: <JSON event
     bytes>})` directly (model `cre/controller/workflow_test.go`). The path exercises `RunInNodeMode(payload.Input,
     …)` + `ConsensusIdenticalAggregation[LossEvent]` + dispatch + `zipreport.Coord*` + `GenerateReport` +
     `WriteReport`, under `testutils` + `evmmock`, asserting the captured envelope. **This proves the `LossEvent`
     carrier `values.Wrap`s through identical consensus** — a `RunInNodeMode` failure here = the K2 carrier-shape
     decision was wrong → fold back.
3. The Go module is **committed to `cre/coordinator/`** (monorepo `cre/`), code only — no `build/`/`docs/`/
   `contracts/` staged in the code commit.
4. **Cold-build verdict is "yes," not "yes-with-guesses."** If the builder must guess the carrier Wrap-ability,
   the payload→node-mode plumbing, the per-action required-field set, or any SDK signature, the gap folds back.

## Depends on
- **CRE-00** (`cre/zipreport` encoder — the `Coord*` builders + round-trip tests) — DONE. **CRE-01b**
  (`cre/controller/`, the http+zipreport sibling to clone, with `parseBytes32`/`parsePositiveBig`/`parseNonNegBig`)
  — DONE.
- The filed `DefaultCoordinator` + `LienXAlphaEscrow` (built, ABI fixed) — the decode sites + escrow guards.
- `reference/cre-sdk-go` present (harness §7). No anvil needed for the unit gate (the sim is mock-backed).

## Discharges / spawns
- Discharges no inbound *Done-when-testable* obligation row (none owed *by* CRE-01c). Addresses the framing of
  the open obligation **"LOSS — the default/slash flow is M2, not M1-live"** — this producer IS the `rt8`
  default/recovery driver it names; the M2-live firing of the economic actions is operational, the producer is
  built.
- **Completes the CRE-01 family** (01a registry / 01b controller / 01c coordinator). No CRE-01 remainder. Set the
  next `NEXT` to the reviewer's pick among the remaining CRE backlog (CRE-03 feeds / CRE-04 warehouse ops; CRE-02
  blocked on CRE-04).

## Reconciliation notes (precision the ticket pins beyond the literal §8.4 prose)
- §8.4 enumerates the six actions + their `actionData` tuples + units, and names the trigger→consensus→
  GenerateReport→WriteReport shape, but does not pin the carrier type, the per-action required-field set, or the
  action-string discriminant spelling. This ticket pins: **one action-discriminated http event** (the §8.4 six
  actions share one producer, distinct from CRE-01a's registry path and CRE-01b's controller path), **carrier =
  `LossEvent{string-only}`** (the verified-Wrap-able shape, proven by the sim), **lowercase action keys**
  (`lock|release|default|recovery|resolve|writeoff`), and the required-vs-optional field rules derived from the
  contract's revert guards (`ZeroAtRisk`, escrow `ZeroOriginator`/`ZeroAmount`; `capitalSlashAmount`/
  `recoveryProceeds` may be 0 since the contract tolerates them). Each is a derivation from §8.4 + the verified
  SDK + the filed contract, not an invention.
- **No Proof gate is the faithful reading**, not an omission: §8.9 lists "§8.4 recovery" as a fact needing
  attestation, but for the loss family that attestation is the identical consensus over the (mocked-via-trigger)
  facts — there is no on-chain boolean gate surface on the `DefaultCoordinator` (its six tuples carry no
  booleans), exactly as CRE-01a (revaluation, also a line-847 "credit fact") emitted with no boolean gate. The
  §13 Forwarder/identity boundary is the entry guard.
