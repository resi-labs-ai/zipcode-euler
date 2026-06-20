# CRE-00 — the (R)-track scaffold + the shared §8.0 report-encoding package

> Head of the CRE `(R)` (report-path) track. Two artifacts, both committed to the monorepo `cre/`:
> **(1) `cre/zipreport/`** — the single, SDK-free Go library that encodes the §8.0 report envelope + every
> per-`(receiver, reportType)` payload, each pinned to the EXACT filed-contract decode tuple. CRE-01/03/04
> import it instead of re-implementing the handshake. **(2) `cre/scaffold/`** — the clone-me `wasip1`
> workflow template that demonstrates the SDK patterns the existing workflows do NOT (DON-only `GetSecret`,
> `RunInNodeMode` + identical-consensus, the `cre-templates` project files), imports `zipreport`, and runs a
> full trigger → node-mode → consensus → `GenerateReport` → `WriteReport` path under a sim test.

## Deliverable
- `cre/zipreport/` — a standalone Go module (`module cre-zipreport`) with `report.go` (envelope + reportType
  constants + per-type full-report builders), `report_test.go` (table-driven round-trip against every filed
  decode tuple), `go.mod`, `go.sum`, `README.md`.
- `cre/scaffold/` — a standalone `wasip1` workflow module (`module cre-scaffold`) with `main.go` (wasip1
  runner), `workflow.go` (untagged logic), `main_test.go` (sim test), `go.mod`, `go.sum`, the `cre-templates`
  project files (`project.yaml`, `secrets.yaml.example`, `.env.example`, `.gitignore`), `README.md`.

## Spec §
`claude-zipcode.md` §8.0 (report envelope + the per-type producer table) · §8.11 (the CRE build-ticket map; the
CRE-00 row) · §8 path-1 (the report path) · §8.10 (DON-only secret discipline — raw PII never enters a
consensus observation). The `CRE-OPS-ROUTING.md` ruling: CRE-00 is pure `(R)`, blocks nothing, unblocks
CRE-01/03/04.

## Binds to (verified against the FILED contracts — these are the source of truth, not spec prose)
Envelope (every report receiver): `abi.encode(uint8 reportType, bytes payload)`
(`ZipcodeController.sol:193`, `ZipcodeOracleRegistry.sol:129`, `SzipNavOracle.sol:301`,
`SzipFarmUtilityLpOracle.sol:107`, `DefaultCoordinator.sol:182`, `SzAlphaRateOracle.sol:81`,
`WarehouseAdminModule.sol:158` — there the first field is named `opType`, same shape).

The complete per-`(receiver, reportType)` decode table — each `zipreport` builder MUST encode to exactly this:

| reportType | Receiver (constant @ line) | inner payload tuple (the `abi.decode` site) |
|---|---|---|
| `1` Origination | `ZipcodeController.RT_ORIGINATION` (`:47`) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount, uint256 cap, bytes32 siloId)` (`:222`) |
| `2` Draw | `ZipcodeController.RT_DRAW` (`:48`) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)` (`:266`) |
| `4` Close | `ZipcodeController.RT_CLOSE` (`:50`) | `(bytes32 lienId)` (`:287`) |
| `5` Default / `6` Liquidation | `ZipcodeController.RT_DEFAULT`/`RT_LIQUIDATION` (`:51`/`:52`) | `(bytes32 lienId, uint8 status)` (`:203`) |
| `3` Revaluation | `ZipcodeOracleRegistry.REVALUATION` (`:29`) | `(address[] liens, uint256[] prices, uint32 ts)` (`:132`) |
| `7` NavLeg | `SzipNavOracle.NAV_LEG` (`:72`) | `(uint8[] legs, uint256[] prices, uint32 ts)` (`:304`); `legs ∈ {0 LEG_ALPHA_USD, 1 LEG_HYDX_USD}` (`:66/:68`) |
| `7` LpMark | `SzipFarmUtilityLpOracle.LP_MARK` (`:28`) | `(uint256 mark, uint32 ts)` (`:109`) |
| `8` Coordinator | `DefaultCoordinator.REPORT_TYPE` (`:49`) | `(uint8 action, bytes data)` (`:185`); action enum `Lock=0,Release=1,Default_=2,Recovery=3,Resolve=4,WriteOff=5` (`:52-58`) |
| `8` RATE | `SzAlphaRateOracle.RATE` (`:26`) | `(uint256 rate, uint48 ts)` (`:83`) |
| `1/2/3/4` Warehouse op | `WarehouseAdminModule.SUPPLY/APPROVE/REDEEM/REPAY` (`:25-31`) | per-op (below); first envelope field is `opType` |

DefaultCoordinator action `data` tuples (the inner-inner decode):
- `Lock(0)` → `(bytes32 lienId, address originator, uint256 amount)` (`:207`)
- `Release(1)` → `(bytes32 lienId)` (`:220`)
- `Default_(2)` → `(bytes32 lienId, uint256 atRisk)` (`:235`)
- `Recovery(3)` → `(bytes32 lienId, uint256 recoveryProceeds)` (`:254`)
- `Resolve(4)` → `(bytes32 lienId, uint256 capitalSlashAmount)` (`:277`)
- `WriteOff(5)` → `(bytes32 lienId, uint256 capitalSlashAmount)` (`:296`)

WarehouseAdminModule op payloads (envelope `(uint8 opType, bytes payload)`):
- `SUPPLY(1)` → `(uint256 amount)` (`:164`)
- `APPROVE(2)` → `(uint256 amount)` (`:168`)
- `REDEEM(3)` → `(uint256 shares)` (`:172`)
- `REPAY(4)` → `(address dest, uint256 amount)` (`:176`)

**Reconciliation notes (where this table is deliberately MORE precise than the literal §8.0 table):**
- §8.0's warehouse row is unnumbered (`| SUPPLY/APPROVE/REDEEM/REPAY | … |`); this ticket numbers it
  `1/2/3/4` straight from the filed `WarehouseAdminModule.SUPPLY..REPAY` constants (`:25-31`) — the contract
  is truth (harness §1). The first envelope field is named `opType`, but the wire shape is the same
  `(uint8, bytes)` so `zipreport.Envelope` is reused (the warehouse builders pass `opType` as the first arg).
- §8.0 also lists `1 POST_BID` / `2 CANCEL_BID` → `SzipBuyBurnModule` (`:526-527`). Those are **owned by
  CRE-05a (SHIPPED, `cre/buyburn-bid/`)** per `CRE-OPS-ROUTING.md` — they are NOT re-exported by `zipreport`
  (this table covers the (R) report-receivers CRE-01/03/04 drive; the 8-B14 socket is the deliberate §8.7
  exception and stays in its own workflow). So the table is complete *for CRE-00's scope*, not for all of §8.0.

**SDK + tooling bindings (verified, in-tree):**
- Module SDK pins (copy from `cre/buyburn-bid/go.mod` VERBATIM — the published releases predate
  `evm.WriteCreReportRequest` / `testutils.SetTimeProvider`): `go 1.25.3`,
  `github.com/ethereum/go-ethereum v1.17.2`, `cre-sdk-go v1.0.1-0.20251111122439-00032d582c18`,
  `capabilities/blockchain/evm v1.0.0-beta.0`, `capabilities/scheduler/cron v0.9.0`, and the three SDK
  `replace` directives pointing at `../../reference/cre-sdk-go[/...]`. **DEP SEAM** (PROGRESS): every `cre/*`
  module `replace`s the in-tree SDK snapshot; CRE-00 follows the same.
- `cre/zipreport` has **NO cre-sdk dependency** — only `github.com/ethereum/go-ethereum v1.17.2`
  (`accounts/abi` + `common`). It builds for host AND `wasip1`.
- `cre/scaffold` `require`s + `replace`s `cre-zipreport => ../zipreport` (the same relative-replace idiom
  the SDK pins use).
- wasm runner: `wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)` (`cre/buyburn-bid/main.go`).
- Report write path: `runtime.GenerateReport(&cre.ReportRequest{EncodedPayload: <envelope bytes>, EncoderName:
  "evm", SigningAlgo: "ecdsa", HashingAlgo: "keccak256"})` then `client.WriteReport(runtime,
  &evm.WriteCreReportRequest{Receiver, Report, GasConfig})` (`cre/buyburn-bid/workflow.go:268-284`).
- Node-mode + consensus: `cre.RunInNodeMode[C,T](cfg, runtime, fn, cre.ConsensusIdenticalAggregation[T]())`
  (`reference/cre-sdk-go/cre/runtime.go:166`, `consensus_aggregators.go:33`).
- DON-only secret: `runtime.GetSecret(&sdk.SecretRequest{Id: ...}).Await()` where `sdk` =
  `github.com/smartcontractkit/chainlink-protos/cre/go/sdk` (pattern: `standard_tests/secrets/main_wasip1.go`;
  the inverse invariant — fails in node mode — `standard_tests/secrets_fail_in_node_mode/`).
- Sim test bindings: `cre/testutils` + `capabilities/blockchain/evm/mock` (`cre/buyburn-bid/main_test.go`).
- go-ethereum `abi.Pack` native-type mapping (VERIFIED via `cre/buyburn-bid/workflow.go:248`): `uint8` →
  native `uint8`; `uint16` → native `uint16`; `uint32` → native `uint32`; `uint48`/`uint256` → `*big.Int`;
  `bytes32` → `[32]byte`; `address` → `common.Address`; `address[]` → `[]common.Address`; `uint256[]` →
  `[]*big.Int`; `uint8[]` → `[]uint8`; `bytes` → `[]byte`. (A `*big.Int` for `uint32` is REJECTED by v1.17.2 —
  pass native; the produced ABI bytes are identical.)

## Starting state
- `cre/` holds `buyburn-bid/` (DONE, the (R) layout exemplar), `keeper/` (DONE, (K) track), `szalpha-rate/`
  (a sketch — `main.go` + README only, no `go.mod`; do NOT model the module wiring on it).
- No shared encoding library exists — `buyburn-bid` and `szalpha-rate` each re-implement `encodeEnvelope` + a
  payload encoder inline. CRE-00 creates the shared one so CRE-01/03/04 don't.
- The `cre-templates` layout reference: `reference/cre-templates/starter-templates/tokenized-asset-servicing/`
  (`project.yaml`, `secrets.yaml`, `.env.example`).

## Do NOT
- Do NOT add any cre-sdk dependency to `cre/zipreport` — it stays pure-`abi` (host + wasip1 buildable, trivially
  testable). The SDK lives only in `cre/scaffold`.
- Do NOT implement any CRE-01/03/04 business logic in the scaffold (no real underwriting, no real NAV/LP math,
  no revaluation sharding, no Proof gating). The scaffold's worked example is a SKELETON; its report content is
  an illustrative `LpMark` push, loudly marked as a template placeholder.
- Do NOT invent reportType numbers, field orders, or types — every one is fixed by the table above (the filed
  contract). A builder whose round-trip does not decode to the exact tuple FAILS the gate.
- Do NOT call `GetSecret` inside the node-mode observation function (it is DON-runtime only; raw PII must never
  enter a consensus observation, §8.10). Demonstrate it on the DON `runtime` in the handler.
- Do NOT stage anything outside `cre/` (no `build/`, `docs/`, `contracts/` in the code commit).
- Do NOT add a `go.work` (the existing modules don't use one; the `replace` idiom is the convention).

## Key requirements
1. **`cre/zipreport/report.go`** exports:
   - `func Envelope(reportType uint8, payload []byte) ([]byte, error)` — `abi.encode(uint8, bytes)`.
   - Receiver-grouped reportType + action/op constants matching the table, in **one `const` block per
     receiver** (so the cross-receiver numeral collisions are explicit and a reader cannot conflate them:
     `NavLeg==7` and `LpMark==7` live in different blocks; `CoordinatorReportType==8` and `RateReportType==8`
     likewise; the warehouse `WhSupply==1`/`WhApprove==2`/`WhRedeem==3`/`WhRepay==4` reuse 1-4 but are
     `opType`s on their own receiver). Name them so the receiver is visible: e.g. `ControllerOrigination`,
     `RegistryRevaluation`, `NavLeg`, `LpMark`, `CoordinatorReportType` + the `Action*` set,
     `WhSupply`/`WhApprove`/`WhRedeem`/`WhRepay`, `RateReportType`, `LegAlphaUsd=0`/`LegHydxUsd=1`.
   - One **full-report builder per type** returning the complete envelope-wrapped bytes ready for
     `GenerateReport(EncodedPayload:)`. Each takes the typed Go args (per the native-mapping above) and returns
     `([]byte, error)`. Minimum set (cover the whole table): `Origination`, `Draw`, `Close`, `Status(reportType
     uint8, lienId [32]byte, status uint8)` (assert `reportType ∈ {5,6}`), `Revaluation`, `NavLeg`, `LpMark`,
     `CoordLock`, `CoordRelease`, `CoordDefault`, `CoordRecovery`, `CoordResolve`, `CoordWriteOff`, `WhSupply`,
     `WhApprove`, `WhRedeem`, `WhRepay`, `Rate`.
   - Validation where the contract enforces it and a bad encode would silently mis-bind: `Revaluation` and
     `NavLeg` MUST error if `len(liens) != len(prices)` / `len(legs) != len(prices)` (the contracts revert
     `LengthMismatch` — fail early off-chain). `NavLeg` legs are not range-checked here (the contract's
     `InvalidLeg` guard owns that) but the constants `LegAlphaUsd=0`/`LegHydxUsd=1` are exported.
2. **`cre/zipreport/report_test.go`** is table-driven and NON-VACUOUS: for every builder, (a) decode the bytes
   as `(uint8, bytes)` and assert the reportType; (b) decode the inner payload as the EXACT filed tuple and
   assert every field equals the input; for `CoordLock`/etc. also decode the inner-inner `(action, data)` then
   the action tuple. Include length-mismatch error cases for `Revaluation`/`NavLeg`. A header comment cites each
   contract decode line (the table above) so the binding is auditable.
3. **`cre/scaffold/`** is a working `wasip1` workflow template:
   - `main.go` (`//go:build wasip1`): `wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)`.
   - `workflow.go` (untagged): a `Config` with at least `Schedule string`, `ChainSelector uint64`,
     `Receiver string`, `SecretId string`. `initFn` registers ONE `cron.Trigger`. The handler:
     (i) reads a secret on the DON runtime via `GetSecret(&cre.SecretRequest{Id: cfg.SecretId})` — use the
     `cre.SecretRequest` alias (`= sdk.SecretRequest`, `runtime.go:14`) so no NEW direct import of
     `chainlink-protos` is added; comment it DON-only (§8.10). This read is **fail-safe and illustrative**: on
     error or empty value, log and PROCEED (the secret is a demo of the call, NOT a precondition for the
     write) — so the sim test does not depend on a seeded secret/namespace.
     (ii) gathers the observation in `RunInNodeMode(cfg, runtime, observeFn, cre.ConsensusIdenticalAggregation
     [uint64]())` where `observeFn func(*Config, cre.NodeRuntime) (uint64, error)` returns a deterministic
     `mark` (a constant is fine — this is a template, not a data feed). **Carrier = a single `uint64`** (a
     known `values.Wrap`-able scalar — avoids the multi-field-struct Wrap question the critics raised); do NOT
     consensus the timestamp.
     (iii) on the DON side stamps `ts := uint32(runtime.Now().Unix())` (the `runtime.Now()` idiom from
     `buyburn-bid/workflow.go:152`) and encodes via `zipreport.LpMark(new(big.Int).SetUint64(mark), ts)`
     (illustrative — comment: "TEMPLATE: replace with your ticket's zipreport.Xxx call");
     (iv) `GenerateReport` → `WriteReport` to `cfg.Receiver` (the §8.0 write path, `buyburn-bid/workflow.go:268`).
     A no-op / fail-safe skip is fine if `mark == 0` or `cfg.Receiver` is unset.
   - `main_test.go`: a sim test (model `cre/buyburn-bid/main_test.go:221-246`) using
     `testutils.NewRuntime(t, testutils.Secrets{...})` (seed the secret keyed to match `cfg.SecretId` with an
     EMPTY namespace, per `testutils/runtime.go` `Namespace→ID→value` keying — but since the secret read is
     fail-safe, the happy path is optional) + `evmmock.NewClientCapability(chainSelector, t)` +
     `evmmock.AddContractMock(receiver, mock, callMap, writeFunc)` to capture the `WriteReport`, and asserts the
     captured report decodes to the LpMark envelope (reportType `7`, inner `(uint256 mark, uint32 ts)`). If a
     full host-mode sim of the cron-triggered handler proves awkward under the mock harness (the exemplar calls
     its loop fn directly rather than firing the trigger), the test MAY (a) call the handler fn directly with
     the mocked runtime, and/or (b) assert the encode handshake directly by decoding `zipreport.LpMark` bytes —
     but `RunInNodeMode`+consensus MUST execute in at least one host test path, and the wasip1 build of
     `main.go` MUST be green.
   - `project.yaml` + `secrets.yaml.example` + `.env.example` + `.gitignore` modeled on
     `reference/cre-templates/starter-templates/tokenized-asset-servicing/` (+ `cre/buyburn-bid/.gitignore`).
   - `README.md`: the §8.0 table, the "clone me" instructions, the DON-only-secret note, and the explicit
     statement that the LpMark example is a placeholder.
4. `cre/zipreport/README.md` documents the table + the binding lines + a usage snippet.

## Build / dependency notes (resolve the cold-build's offline + module questions up front)
- **Seed each `go.mod`/`go.sum` from `cre/buyburn-bid/`, then `go mod tidy`.** Copy buyburn-bid's `go.mod`
  require/replace block VERBATIM for `cre/scaffold` (identical SDK + cron + evm pins + the three `../../reference`
  replaces), then add `require cre-zipreport v0.0.0` + `replace cre-zipreport => ../zipreport`. `go.sum` is
  TOOL-GENERATED (`go mod tidy`/`go mod download`) — not hand-written; if the build host is offline, copy
  buyburn-bid's `go.sum` lines for the shared deps (incl. the transitively-required
  `chainlink-protos/cre/go` hashes — it is pulled by the SDK's own go.mod, NOT replaced in-tree; this is the
  documented DEP SEAM, already true for every `cre/*` module). The build environment that produced
  buyburn-bid/keeper HAS network; `go mod tidy` is expected to succeed.
- **`cre/zipreport/go.mod`** declares `module cre-zipreport`, `go 1.25.3`, and requires ONLY
  `github.com/ethereum/go-ethereum v1.17.2` (no SDK, no replace). Its `go.sum` covers go-ethereum + its
  transitive deps via `go mod tidy`.
- **Using `cre.SecretRequest` (the alias) avoids adding a new direct import** of `chainlink-protos` to the
  scaffold — `sdk.SecretRequest` (as in `standard_tests/secrets/main_wasip1.go`) is equivalent and also
  acceptable; pick the alias to keep the import set minimal.
- **The `cre-templates` project files (`project.yaml`/`secrets.yaml.example`/`.env.example`) are illustrative
  scaffolding, NOT gate-checked** — the four `go` gates below never invoke the CRE CLI. Model them loosely on
  `tokenized-asset-servicing/` (which ships `secrets.yaml`, not `.example`; rename + add a sample entry), and
  DROP the template's workflow-specific fields (`.cre/`, contracts/lambda dirs) the scaffold has no analogue
  for. Getting these byte-perfect is not required; demonstrating the layout is.

## Done when (the gate — verified by my OWN re-run, not just the cold-build's)
- `cd cre/zipreport && go build ./... && go vet ./... && go test ./...` → all pass (the round-trip handshake
  proven for every type).
- `cd cre/zipreport && GOOS=wasip1 GOARCH=wasm go build ./...` → exit 0 (the library compiles to the workflow
  target).
- `cd cre/scaffold && go build ./... && go vet ./... && go test ./...` → all pass (host sim/handshake test).
- `cd cre/scaffold && GOOS=wasip1 GOARCH=wasm go build ./...` → exit 0 (the workflow `main.go` compiles to
  wasip1).
- A fresh cold-build reproduces all four from the ticket alone with **zero load-bearing guesses** (test-fixture
  values + the ticket-sanctioned LpMark placeholder choice are not guesses).

## Depends on
Nothing (the head of the (R) track). Unblocks CRE-01, CRE-03, CRE-04 (each imports `cre/zipreport`).

## Inbound obligations to discharge
None owed *by* CRE-00 in PROGRESS "Open obligations" (the CRE-01 seeding-collision / fee-sizing TODOs and the
DEP SEAM are owed by/about CRE-01, not CRE-00). The DEP-SEAM `replace`-the-in-tree-SDK convention is FOLLOWED
here (key req: SDK pins + replaces copied from buyburn-bid).
