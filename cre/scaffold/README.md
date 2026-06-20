# cre-scaffold — the clone-me CRE `(R)` workflow template

A working `wasip1` workflow module that demonstrates the SDK patterns the Zipcode report-path (R)
workflows (CRE-01/03/04) need, so you can clone it and replace the worked example with your own logic.

> **The LpMark example is a PLACEHOLDER.** This scaffold implements NONE of the CRE-01/03/04 business logic
> (no underwriting, no NAV/LP math, no revaluation sharding, no Proof gating). The observed `mark` is a
> hard-coded constant, not a data feed. The seams to replace are marked `TEMPLATE:` in `workflow.go`.

## What it demonstrates

1. **wasip1 runner** — `wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)` (`main.go`, wasip1-tagged). A
   host stub `main()` (`main_host.go`, `!wasip1`) keeps the host `go build ./...` green.
2. **DON-only `GetSecret`** (§8.10) — the secret is read on the **DON `runtime`** in the handler, NEVER
   inside the node-mode observation function, because raw secret material must never enter a consensus
   observation. The read is **fail-safe and illustrative**: on error or empty value the handler logs and
   PROCEEDS. Uses the `cre.SecretRequest` alias so no new `chainlink-protos` import is added.
3. **`RunInNodeMode` + identical consensus** — `cre.RunInNodeMode(cfg, runtime, observe,
   cre.ConsensusIdenticalAggregation[uint64]())`. The carrier is a single `uint64` scalar (a known
   `values.Wrap`-able type). The timestamp is NOT consensused — it is stamped DON-side.
4. **The §8.0 write path** — `runtime.Now()` stamp → `zipreport.LpMarkReport(...)` encode →
   `GenerateReport` → `WriteReport` to `cfg.Receiver`. Imports the shared `cre-zipreport` library.

## §8.0 report table

See [`../zipreport/README.md`](../zipreport/README.md) for the full per-`(receiver, reportType)` decode
table. This scaffold pushes `LpMark` (reportType `7`, inner `(uint256 mark, uint32 ts)`).

## Config

```json
{
  "schedule": "0 */5 * * * *",
  "chainSelector": 1234567890,
  "receiver": "0x...",
  "secretId": "DEMO_SECRET"
}
```

## Clone me

1. Copy this directory to `cre/<your-workflow>/`; set `module cre-<your-workflow>` in `go.mod`.
2. Keep the `replace` blocks (the in-tree SDK snapshot + `cre-zipreport => ../zipreport`).
3. In `workflow.go`, replace the `TEMPLATE:`-marked seams:
   - `observe` — your real per-node observation (a chain read, etc.).
   - the `zipreport.LpMarkReport(...)` call — your ticket's `zipreport.Xxx` builder.
   - the `Config` fields — your workflow's addresses / parameters.
4. Copy `secrets.yaml.example` → `secrets.yaml` (gitignored) and `.env.example` → `.env`; fill them in.

## Project files

- `project.yaml` — CRE CLI targets (illustrative; fill in your RPC URLs + owner address).
- `secrets.yaml.example` — the secrets manifest template (the `id` must match `cfg.SecretId`).
- `.env.example` — env vars (private key / 1Password ref + target profile).
- `.gitignore` — ignores the built binary, `*.wasm`, `.env`, `secrets.yaml`.

These template files are illustrative scaffolding and are NOT gate-checked.

## Test

```sh
go build ./... && go vet ./... && go test ./...
GOOS=wasip1 GOARCH=wasm go build ./...
```

`main_test.go` runs the full handler path (DON secret read → `RunInNodeMode` + consensus → `runtime.Now()`
stamp → `zipreport` encode → `GenerateReport` → `WriteReport`) under `testutils` + `evmmock`, and asserts
the captured report decodes to the LpMark envelope.
