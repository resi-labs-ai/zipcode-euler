# CRE-04 — the senior-warehouse op producer (opType 1/2/3/4 → `WarehouseAdminModule`)

> **Track:** (R) — a wasip1 CRE report-path workflow (CRE-OPS-ROUTING: CRE-04 is pure (R) through the EXISTING
> `WarehouseAdminModule` receiver — "Senior-warehouse **SUPPLY/APPROVE/REPAY** ops via the Roles adapter (§8.5)",
> routing table line 68 / spawned-tickets table line 121). It builds the **senior-warehouse op producer**: the
> §8.5 Roles-gated op family (SUPPLY / APPROVE / REDEEM / REPAY) → the `WarehouseAdminModule` (8-Bw). The
> CRE-01 family (01a/01b/01c) and CRE-00 (`cre/zipreport`) are DONE; this slice imports the shared encoder and
> clones the proven `cre/coordinator/` http-producer shape.

---

## Deliverable
A committed Go module at **`cre/warehouse/`** (monorepo `cre/` — harness §3) that compiles to `wasip1` and
implements the **§8.5 senior-warehouse op producer**: an off-chain warehouse-op event arrives via `http.Trigger`,
the workflow reaches **identical consensus** on the event record, normalizes + **dispatches on the op
discriminant**, validates the per-op required fields, encodes the matching payload via the shared
**`cre/zipreport`** library, and emits **one `WriteReport`** to the `WarehouseAdminModule` as the §8.5 envelope
`abi.encode(uint8 opType, bytes payload)`. The four ops it produces:

| op (payload discriminant) | opType byte | encoder | payload tuple | the pinned Safe call the adapter re-encodes |
|---|---|---|---|---|
| `supply` | 1 `SUPPLY` | `zipreport.WhSupplyReport` | `(uint256 amount)` | `eePool.deposit(amount, receiver==SAFE)` |
| `approve` | 2 `APPROVE` | `zipreport.WhApproveReport` | `(uint256 amount)` | `usdc.approve(spender==eePool, amount)` |
| `redeem` | 3 `REDEEM` | `zipreport.WhRedeemReport` | `(uint256 shares)` | `eePool.redeem(shares, receiver==SAFE, owner==SAFE)` |
| `repay` | 4 `REPAY` | `zipreport.WhRepayReport` | `(address dest, uint256 amount)` | `usdc.transfer(to==dest, amount)` (adapter pins `dest==redemptionBox`) |

The adapter holds NO custody and enforces NO scope of its own beyond the `dest==redemptionBox` self-check — the
**security boundary is the Zodiac Roles scope** (params pinned, Call-only). The producer sizes the scalars; the
on-chain policy pins the identities. Encoding is delegated to `cre/zipreport` (CRE-00) — this slice does **NOT**
re-implement the §8.5 envelope or any payload encode.

## Spec §
- **§8.5 "Senior-warehouse ops (SUPPLY / REDEEM / REPAY — the Roles-gated path)"** — the producer this slice
  implements verbatim. The `CreditWarehouse` is a plain Gnosis Safe custodying the protocol's `EulerEarn`
  shares; CRE drives it **only** through the audited Zodiac Roles Modifier v2. The CRE seam is a thin
  `is ReceiverTemplate` receiver (Forwarder-gated, Timelock-owned) `assignRoles`'d as the role member; on a
  report it decodes `abi.encode(uint8 opType, bytes payload)`, **re-encodes the corresponding pinned Safe call**,
  and invokes `Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`. The four opType rows
  (1/2/3/4) + their payload tuples are pinned in §8.5 (lines 690-695, the table reproduced under "Binds to A")
  and **reconciled with the build** (§8.5 lines 702-707): EulerEarn `redeem(shares, receiver, owner)` (owner
  3rd); redeemed USDC → Safe-then-REPAY (not direct-to-sink); APPROVE **exact-amount** with `spender` pinned;
  the warehouse adapter uses a **distinct Forwarder identity / workflowId** from the controller/registry/oracle
  receivers.
- **§8.5 sizing (lines 697-701) — the producer sizes scalars; the policy pins identities.** The workflow
  computes `amount`/`shares` (e.g. the redemption shortfall, the recovery draw) off the live NAV
  (`eePool.convertToAssets(eePool.balanceOf(SAFE))`, read via `evmClient.CallContract`) — **but for the BUILD
  that sizing arrives pre-computed on the `http.Trigger` payload (the §8.5/§8.9 MOCK-FEED seam, K3), exactly as
  CRE-01c's loss magnitudes arrive on its trigger.** The on-chain NAV read is the documented production
  replacement of the mock `observe`; the `RunInNodeMode` + consensus + dispatch + encode + write machinery is
  unchanged. The producer **cannot widen the call set** (that needs the Safe owner: GOD-EOA → multisig). The
  `to` of REPAY is the one field the producer carries (the scope pins it `EqualTo(redemptionBox)`); every other
  identity is adapter-injected AND scope-pinned (belt-and-suspenders).
- **§8.0** — the shared envelope `abi.encode(uint8 reportType, bytes payload)`; for the warehouse the first
  field is named `opType` (same `(uint8, bytes)` wire shape). Build-map row line 523 (SUPPLY/APPROVE/REDEEM/
  REPAY → `CreditWarehouse` CRE-receiver, CRE-04). Encoder BUILT as `cre/zipreport` (CRE-00).
- **§8.9 — NO on-chain boolean Proof gate on the warehouse op family.** Like CRE-01a (revaluation) and CRE-01c
  (the loss family), the `WarehouseAdminModule` exposes **no on-chain boolean gate surface** — its decode is a
  pure `(opType, payload)` → one pinned Roles-forwarded call; there is no boolean to set fail-closed on. The
  attestation **IS** the identical consensus over the (mocked-via-trigger) op facts; the §13 trust boundary (the
  distinct Forwarder + Timelock-pinned workflow identity, `WarehouseAdminModule.sol:76,91`) + the **Roles scope**
  (the real param-pinning security boundary) are the entry guards. So there is **no `Gates` struct and no "emit
  only if gates pass" branch** here.
- **§17** — every wiring slot (receiver address, chain selector) comes from Config (re-pointable), not hardcoded.

## Binds to (verified by inspection — do NOT cite blind)

### A. The filed report consumer — `WarehouseAdminModule` (8-Bw, the decode sites)
`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`. The op constants
(`WarehouseAdminModule.sol:25-31`): `SUPPLY = 1, APPROVE = 2, REDEEM = 3, REPAY = 4`. The shared envelope is
decoded in `_processReport` (`:157-191`): `abi.decode(report, (uint8 opType, bytes payload))` (`:158`) →
dispatches on `opType`, reverting `UnsupportedOpType(opType)` (`:184`) on any other byte. Each op decodes a
payload tuple and builds exactly one scoped call forwarded via
`roles.execTransactionWithRole(to, 0, data, OP_CALL=0, roleKey, true)` (`:189`):

- **`SUPPLY` (1) → (`:163-166`)**, `amount = abi.decode(payload, (uint256))` (`:164`); `to = eePool`,
  `data = deposit.selector(amount, warehouseSafe)`. **The injected `warehouseSafe` is the deposit receiver**
  (Roles scope pins `receiver == avatar`). On-chain: `deposit(0)` reverts (EE `ZeroShares` → Roles
  `ModuleTransactionFailed`; verified `WarehouseAdminModule.t.sol:450`) — so `amount` must be **> 0**.
- **`APPROVE` (2) → (`:167-170`)**, `amount = abi.decode(payload, (uint256))` (`:168`); `to = usdc`,
  `data = approve.selector(eePool, amount)`. The exact-amount allowance `deposit` pulls against (precedes
  SUPPLY; Roles scope pins `spender == EqualTo(eePool)`). Producer pushes the exact next-deposit amount → **> 0**
  (the producer drives exact-amount approves, never an infinite or reset-to-zero approve; §8.5 "exact-amount").
- **`REDEEM` (3) → (`:171-174`)**, `shares = abi.decode(payload, (uint256))` (`:172`); `to = eePool`,
  `data = redeem.selector(shares, warehouseSafe, warehouseSafe)` (receiver==owner==SAFE). On-chain: `redeem(0)`
  is a no-op success (mirrors `EulerEarn.sol:604`; `WarehouseAdminModule.t.sol:489`) — but a 0-share redeem is a
  wasted DON write the producer never intends, so `shares` must be **> 0**.
- **`REPAY` (4) → (`:175-185`)**, `(dest, amount) = abi.decode(payload, (address, uint256))` (`:176`);
  **the adapter SELF-ENFORCES `dest == redemptionBox` and reverts `WrongRedemptionBox(dest)` (`:180`)** —
  belt-and-suspenders with the Roles `EqualTo(redemptionBox)` scope — then `to = usdc`,
  `data = transfer.selector(redemptionBox, amount)`. So the producer carries `dest` (§8.5: the one carried
  field); it must be a **non-zero address** and, to land on-chain, must equal the wired `redemptionBox` (the
  producer surfaces, the contract backstops — it does NOT read the on-chain `redemptionBox` to pre-check).
  `amount` must be **> 0** (a 0-value transfer is a meaningless wasted write).

The adapter never decodes `value`/`operation`/`shouldRevert` from a payload (`value` always 0, op always Call,
shouldRevert always true — `:20`); the receiver/spender/redeem-owner are **adapter-injected from wiring**
(`:24-31` docstring), so the producer carries ONLY the four payload tuples above.

### B. The encoders — already pinned to these exact tuples (`cre/zipreport/report.go`)
All reuse the §8.0 `Envelope` with `opType` as the first arg (same `(uint8, bytes)` shape — `report.go:159-163,
316-338`); each is round-trip-tested against the filed-contract decode in `cre/zipreport/report_test.go`
(`TestWh{Supply,Approve,Redeem,Repay}RoundTrip`). **Import them; do not re-encode.**
- **`WhSupplyReport(amount *big.Int) ([]byte, error)`** — `report.go:321` (opType 1, `(uint256 amount)`).
- **`WhApproveReport(amount *big.Int) ([]byte, error)`** — `report.go:326` (opType 2, `(uint256 amount)`).
- **`WhRedeemReport(shares *big.Int) ([]byte, error)`** — `report.go:331` (opType 3, `(uint256 shares)`).
- **`WhRepayReport(dest common.Address, amount *big.Int) ([]byte, error)`** — `report.go:336` (opType 4,
  `(address dest, uint256 amount)`).
- Constants: `zipreport.WhSupply(1)/WhApprove(2)/WhRedeem(3)/WhRepay(4)` — `report.go:118-123`.

### C. cre-sdk-go bindings (verified — identical surface to CRE-01c, `cre/coordinator/`)
Same as CRE-01c — no new SDK surface. `http.Trigger` (`reference/cre-sdk-go/capabilities/networking/http`,
aliased `httpcap`); `cre.RunInNodeMode[C,T]` with `C` a FREE generic = `[]byte` (pass `payload.Input`);
`cre.ConsensusIdenticalAggregation[WarehouseOp]()` (the carrier is **string fields only** → trivially
`isIdenticalType`, `reference/cre-sdk-go/cre/consensus_aggregators.go:198-225`); the write path
`runtime.GenerateReport` → `evm.Client{ChainSelector}.WriteReport(runtime, &evm.WriteCreReportRequest{Receiver,
Report, GasConfig})`. **Test harness:** `testutils.NewRuntime`, `evmmock.NewClientCapability`,
`evmmock.AddContractMock` capturing the report bytes — model `cre/coordinator/workflow_test.go`.

### D. The module skeleton to clone — `cre/coordinator/` (CRE-01c, the closest sibling)
Clone `cre/coordinator/`'s file shape exactly (it is already the **http + zipreport** dependency set this slice
needs — no cron, no sharding, one report per event, op-discriminant dispatch — the best seed): `main.go`
(`//go:build wasip1`, `wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)`), `main_host.go` (`//go:build
!wasip1`, no-op `main()`), `workflow.go` (untagged logic + handler), `go.mod`, `project.yaml`, `.env.example`,
`secrets.yaml.example`, `README.md`, `workflow_test.go`.
**go.mod:** seed from `cre/coordinator/go.mod`, rename `module cre-coordinator` → `module cre-warehouse`, keep
its replace set verbatim (base `cre-sdk-go` + `evm` + `networking/http` + `cre-zipreport`; the relative paths
`../../reference/...` and `../zipreport` are correct — same depth), then `go mod tidy`. **Also rename the
internal `coordinator`→`warehouse` strings** in `project.yaml` (workflow/project name), `.env.example` (var
labels), and `README.md` (no behavioral effect — consistency only). The test's chain-selector constant
`evm.EthereumMainnetBase1` (`cre/coordinator/workflow_test.go:34`) comes for free with the clone — reuse it.
**Reuse `parseBytes32`** is NOT needed here (the warehouse carries no bytes32); **reuse `parseAddress`** (REPAY
dest) and **`parsePositiveBig`** (all four magnitudes) verbatim from `cre/coordinator/workflow.go` (`:284-303`,
`:307-316`). `parseNonNegBig` is NOT needed (no warehouse magnitude tolerates 0) — drop it.

## Module layout (author exactly this)
```
cre/warehouse/
  go.mod                  # module cre-warehouse ; go 1.25.3 ; coordinator's replaces (SDK pins + cre-zipreport)
  .gitignore              # /.env, secrets.yaml, *.wasm, /cre-warehouse
  .env.example            # CRE_* / config vars documented
  secrets.yaml.example    # illustrative (no live secret needed — see K6)
  project.yaml            # cre-cli project file (clone coordinator)
  README.md               # what it is, the trigger, the 4-op discriminant, the §8.5 sizing/mock seam, the gate
  main.go                 # //go:build wasip1 — wasm runner entrypoint (clone coordinator)
  main_host.go            # //go:build !wasip1 — no-op main (clone coordinator)
  workflow.go             # initFn + onWarehouseOp handler + observe + dispatch/validate/encode + writeReport
  workflow_test.go        # host sim test (per-op decode asserts + bad-input errors + no-op)
```

## Key requirements

### K1 — trigger + Config
- **One trigger: `http.Trigger`** (§8.5 ops are driven on demand by the off-chain redemption/recovery
  sequencer, `trigger→node-mode→consensus→GenerateReport→WriteReport`; **no cron heartbeat**). The off-chain
  pipeline POSTs one warehouse-op event; `http.Payload.Input` is the JSON body.
- `Config` (JSON, `cre.ParseJSON[Config]`): `ChainSelector uint64`, **`Warehouse string`** (the
  `WarehouseAdminModule` receiver address — NOTE the field is `Warehouse`), `WriteGasLimit uint64`
  (default `600_000` if 0), `AuthorizedKeys []string` (optional, for `http.Config`). **No hardcoded address**
  (§17). No `MaxLiensPerReport` (one report per event, no sharding).

### K2 — the consensus carrier (string fields only — pinned, not guessed)
The node-mode observation returns ONE struct carrying every op's fields (the union; per-op validation in the
handler decides which are required). Pin the carrier to **string fields only** — do **NOT** put
`common.Address`, `[32]byte`, or `*big.Int` in the carrier (parse those on the DON side AFTER consensus, exactly
as CRE-01c parses post-consensus). **No `Gates` struct** (no Proof gate on the warehouse op family — Spec §8.9).
```go
type WarehouseOp struct {
    Op     string `json:"op"`     // "supply"|"approve"|"redeem"|"repay"
    Amount string `json:"amount"` // base-10; supply/approve/repay (USDC, 6-dp)
    Shares string `json:"shares"` // base-10; redeem ONLY (EulerEarn shares, 18-dp)
    Dest   string `json:"dest"`   // 0x… 40-hex; repay ONLY (the pinned REPAY sink — must be redemptionBox on-chain)
}
```
- Consensus = **`cre.ConsensusIdenticalAggregation[WarehouseOp]()`** (the op facts are notarized → identical,
  not median). All fields are `string` → trivially `isIdenticalType`
  (`reference/cre-sdk-go/cre/consensus_aggregators.go:198-225`). The full-handler sim (Done-when 2) proves the
  carrier `values.Wrap`s through `RunInNodeMode` — if it does not, the carrier-shape decision folds back here.

### K3 — the handler + observe (node mode) = the §8.5/§8.9 MOCK-FEED SEAM
- **The single handler `onWarehouseOp(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload) (struct{},
  error)`** (the return type is `(struct{}, error)`, exactly as `cre/coordinator/workflow.go:92`) runs in DON
  mode, holds `payload.Input`. Registered in `initFn`:
  `cre.Handler(httpcap.Trigger(&httpcap.Config{}), onWarehouseOp)`.
- **Payload → node mode (the load-bearing plumbing CRE-01a/01c pinned — do NOT improvise):** `RunInNodeMode[C,T]`'s
  `C` is a **FREE generic**, NOT the workflow `*Config`. Pass the raw bytes as `C = []byte`:
  ```go
  ev, err := cre.RunInNodeMode(payload.Input, runtime, observe,
      cre.ConsensusIdenticalAggregation[WarehouseOp]()).Await()
  ```
  with `observe(in []byte, _ cre.NodeRuntime) (WarehouseOp, error)` = `json.Unmarshal(in, &ev)` → return `ev`.
- **THIS IS THE MOCK SEAM (§8.5/§8.9):** for the build, every node `json.Unmarshal`s the identical
  trigger-supplied op event (deterministic → identical consensus holds). A prominent comment block on `observe`
  marks it: *"§8.5/§8.9 MOCK FEED — replace this `json.Unmarshal` with the §8.5 on-chain NAV sizing: per-node
  `evmClient.CallContract` reading `eePool.convertToAssets(eePool.balanceOf(warehouseSafe))` + the redemption
  shortfall / recovery draw, deriving `amount`/`shares` per node; the `RunInNodeMode` + consensus + dispatch +
  encode + write machinery is unchanged."*
- **`observe` MUST NOT call `runtime.GetSecret`** (NodeRuntime has no SecretsProvider; §8.1/§8.5 forbid secrets
  in a consensus observation). Any future DON-only secret read stays in the handler.

### K4 — dispatch → validate → encode → write (the core)
After consensus, the handler **`strings.ToLower(strings.TrimSpace(ev.Op))`** and dispatches on the result (so
`"Supply"`/`" supply "` all match; an unknown or empty op ⇒ error, no write). **There is NO Proof gate** — every
well-formed op emits exactly one report. Per-op **required** field rules (a required field that is missing/
empty/unparseable ⇒ error, no write — a malformed event is a producer-side bug to surface):

- **`supply`** (opType 1): **required** — `Amount` (`*big.Int`, base-10, **> 0** — `deposit(0)` reverts
  on-chain). Encode `zipreport.WhSupplyReport(amount)`.
- **`approve`** (opType 2): **required** — `Amount` (`*big.Int`, base-10, **> 0** — exact-amount allowance).
  Encode `zipreport.WhApproveReport(amount)`.
- **`redeem`** (opType 3): **required** — `Shares` (`*big.Int`, base-10, **> 0**). Encode
  `zipreport.WhRedeemReport(shares)`.
- **`repay`** (opType 4): **required** — `Dest` (address, **non-zero** — the adapter reverts
  `WrongRedemptionBox` if it is not the wired `redemptionBox`; the producer carries it per §8.5, does NOT read
  on-chain to pre-check), `Amount` (`*big.Int`, base-10, **> 0**). Encode
  `zipreport.WhRepayReport(dest, amount)`.
- **One `WriteReport`** per well-formed event → the `WarehouseAdminModule` (`cfg.Warehouse`). A write error is
  **returned** from the handler (the §8.5 model surfaces it; do not swallow).
- **No-op fail-safe:** `strings.TrimSpace(Warehouse) == ""` ⇒ no write, log, return nil. An unknown/empty `Op`
  or a missing/unparseable required field ⇒ **error** (return it).
- **Anticipated on-chain reverts the producer does NOT pre-check (surface, do not retry-loop):** `supply` can
  revert on EE `ZeroShares`/cap or an unwired Roles instance; `approve`/`redeem`/`repay` can revert in the Roles
  checker (`ParameterNotAllowed`/`ModuleTransactionFailed`) if a wiring drift makes the re-encoded call fall
  outside the scope; `repay` reverts `WrongRedemptionBox` if `dest != redemptionBox`; `redeem`/`repay` revert on
  insufficient shares/USDC in the Safe. These are on-chain backstops; the producer sends a well-formed report,
  it does NOT replicate the warehouse balance/scope state. The write error propagates (above).

### K5 — hex parsing (address) + base-10 magnitudes
- **`parseAddress(s string) (common.Address, error)`** — reuse CRE-01c's helper verbatim
  (`cre/coordinator/workflow.go:284-303`): requires `0x`/`0X` + **exactly 40 hex chars**, rejects non-hex,
  rejects the zero address, then `common.HexToAddress(s)` (which silently zero-pads/truncates bad input, so
  validate FIRST). Caller: `repay` `Dest`.
- **`parsePositiveBig(s string) (*big.Int, error)`** (base-10, **> 0**) — reuse CRE-01c's helper verbatim
  (`cre/coordinator/workflow.go:307-316`). Callers: `supply`/`approve` Amount, `redeem` Shares, `repay` Amount.
- **Do NOT clone `parseBytes32` or `parseNonNegBig`** — no warehouse field is a bytes32 and no magnitude
  tolerates 0. (Drop them from the clone; keep `go vet` clean — no unused funcs.)

### K6 — secrets/scaffolding
- No live secret is required (the mock op event arrives on the trigger payload). `secrets.yaml.example` is
  illustrative. A future real-feed swap (the §8.5 on-chain NAV sizing reads no secret; a future authenticated
  off-chain shortfall feed would) reads any DON-only key in the **handler**, never `observe`.

### K7 — docs
- `README.md`: what it is (the §8.5 senior-warehouse op producer), the http trigger + the per-op JSON event
  shape (one documented example per op), the **4-op discriminant** table, the **§8.5 sizing + §8.5/§8.9
  mock-feed seam + swap-in note** (on-chain NAV sizing is the production replacement of `observe`), the
  **distinct-Forwarder-identity** deploy note (the warehouse adapter's workflowId differs from the controller/
  registry/oracle receivers), and the gate commands. Cross-link §8.5/§8.9/§8.0 + `cre/zipreport`.

## Do NOT
- Do **NOT** re-implement the §8.5 envelope or any payload encode — import `cre/zipreport`
  (`WhSupplyReport`/`WhApproveReport`/`WhRedeemReport`/`WhRepayReport`).
- Do **NOT** add a `cron.Trigger` heartbeat (§8.5: on-demand, event-driven).
- Do **NOT** add a boolean Proof `Gates` struct or a "emit only if gates pass" branch (no on-chain gate surface
  on the warehouse op family; the identical consensus IS the attestation — §8.9/CRE-01a/01c posture).
- Do **NOT** read the on-chain `redemptionBox`/`warehouseSafe`/`eePool` to pre-check or to source `dest`/the
  injected identities — the adapter injects them from wiring and self-enforces `dest==redemptionBox`; the
  producer carries `dest` per §8.5 and surfaces the on-chain revert (do not duplicate on-chain state off-chain).
- Do **NOT** put `common.Address` / `[32]byte` / `*big.Int` in the consensus carrier (K2); parse post-consensus.
- Do **NOT** call `GetSecret` inside `observe` (node mode).
- Do **NOT** accept a 0 magnitude for any op (all four magnitudes are `> 0` — unlike CRE-01c's recovery/resolve/
  writeoff which tolerate 0; no warehouse op tolerates 0).
- Do **NOT** hardcode any address (§17 — Config-driven, re-pointable).

## Done when (the per-track CRE gate — wasip1 variant)
1. **`cd cre/warehouse && go build ./... && go vet ./...`** exits 0 (host), **and**
   `GOOS=wasip1 GOARCH=wasm go build ./...` exits 0 (the wasip1 target — the real gate).
2. **`cd cre/warehouse && go test ./...`** green, **non-vacuous**, covering:
   - **Encode handshake (per op):** the captured report decodes to `(uint8 opType, bytes payload)` with the
     expected opType byte, then `payload` to the EXACT `WarehouseAdminModule` decode tuple for that op —
     asserted by decoding the bytes (NOT by trusting `zipreport`). All four: supply → `(uint256)` opType 1;
     approve → `(uint256)` opType 2; redeem → `(uint256)` opType 3; repay → `(address,uint256)` opType 4. Assert
     the decoded scalars equal the input (amount/shares/dest), and the opType against BOTH the constant
     (`zipreport.WhSupply` …) and the literal (1/2/3/4).
   - **Validation errors ⇒ no write:** unknown op; empty op; on supply/approve/redeem — zero/non-base-10/missing
     magnitude; on repay — zero/malformed/missing `dest`, zero/non-base-10/missing `amount`.
   - **Op normalization:** `"  SuPPLy  "` dispatches to supply.
   - **No-op:** unset `Warehouse` ⇒ 0 writes.
   - **Full handler path (the sim):** call `onWarehouseOp(cfg, runtime, &httpcap.Payload{Input: <JSON event
     bytes>})` directly (model `cre/coordinator/workflow_test.go`). The path exercises `RunInNodeMode(payload.Input,
     …)` + `ConsensusIdenticalAggregation[WarehouseOp]` + dispatch + `zipreport.Wh*Report` + `GenerateReport` +
     `WriteReport`, under `testutils` + `evmmock`, asserting the captured envelope. **This proves the
     `WarehouseOp` carrier `values.Wrap`s through identical consensus** — a `RunInNodeMode` failure here = the K2
     carrier-shape decision was wrong → fold back.
   - **`parseAddress` unit test** (good + the bad set: empty, no-0x, short, 39/41 hex, non-hex, zero address).
3. The Go module is **committed to `cre/warehouse/`** (monorepo `cre/`), code only — no `build/`/`docs/`/
   `contracts/` staged in the code commit; the host build artifact (`/cre-warehouse`) + `*.wasm` gitignored.
4. **Cold-build verdict is "yes," not "yes-with-guesses."** If the builder must guess the carrier Wrap-ability,
   the payload→node-mode plumbing, the per-op required-field set, or any SDK signature, the gap folds back.

## Depends on
- **CRE-00** (`cre/zipreport` encoder — the `Wh*Report` builders + round-trip tests) — DONE. **CRE-01c**
  (`cre/coordinator/`, the http+zipreport sibling to clone, with `parseAddress`/`parsePositiveBig`) — DONE.
- The filed `WarehouseAdminModule` (8-Bw, built, ABI fixed) — the decode sites + the `WrongRedemptionBox`
  self-check + the on-chain `deposit(0)`/`redeem(0)` behaviors.
- `reference/cre-sdk-go` present (harness §7). No anvil needed for the unit gate (the sim is mock-backed).

## Discharges / spawns
- Discharges no inbound *Done-when-testable* obligation row (none owed *by* CRE-04).
- **Unblocks CRE-02** (redemption-settle, R+K hybrid): CRE-02 reuses THIS warehouse-op package for the (R)
  REDEEM→REPAY funding calls, then sequences `OffRampModule.requestRedeem/claim` + `ZipRedemptionQueue.
  settleEpoch/claim` via the (K) keeper (CRE-OPS-ROUTING line 120). Set the next `NEXT` to the reviewer's pick
  (CRE-02 now unblocked / CRE-03 feeds).

## Reconciliation notes (precision the ticket pins beyond the literal §8.5 prose)
- §8.5 enumerates the four ops + their payload tuples + the pinned Safe calls + the producer/policy split, and
  names the `trigger→consensus→GenerateReport→WriteReport` shape, but does not pin the carrier type, the per-op
  required-field set, or the op-string discriminant spelling. This ticket pins: **one op-discriminated http
  event** (the §8.5 four ops share one producer, distinct from CRE-01's controller/registry/coordinator paths),
  **carrier = `WarehouseOp{string-only}`** (the verified-Wrap-able shape, proven by the sim), **lowercase op
  keys** (`supply|approve|redeem|repay`), and the **all-magnitudes-`> 0`** rule derived from the contract +
  EE behaviors (`deposit(0)` reverts; `redeem(0)` is a wasted no-op; a 0 approve/transfer is meaningless). Each
  is a derivation from §8.5 + the verified SDK + the filed contract, not an invention.
- **REPAY `dest` is carried in the event, not sourced from Config**, per §8.5 ("the `to` of REPAY is the one
  field the producer carries"). The producer validates it is a non-zero address and surfaces the on-chain
  `WrongRedemptionBox` / Roles `EqualTo(redemptionBox)` revert if it drifts — the same "producer surfaces, the
  contract backstops" posture CRE-01c took for the coordinator status machine. Sourcing `dest` from a Config
  slot was considered and rejected: it would duplicate on-chain state off-chain (drift risk on a Timelock
  re-point of `setRedemptionBox`) and contradicts the §8.5 "carried field" reading.
- **No Proof gate is the faithful reading**, not an omission: the `WarehouseAdminModule` exposes no on-chain
  boolean gate surface (its decode is `(opType, payload)` → one pinned Roles-forwarded call); the real security
  boundary is the Zodiac Roles scope (param-pinning, Call-only) + the distinct Forwarder/workflow identity, not a
  CRE-emitted boolean — exactly as CRE-01a/01c emitted with no boolean gate.
