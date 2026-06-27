CLUSTER 7 — Shared infra, identity & monitoring (cross-cutting)

Read `../_boot.md` first (persona + the A–E output schema). Map the shared machinery every other
cluster depends on: the report encoder, the workflow template, the keeper spine, and the Forwarder
identity model that gates every (R) receiver. This cluster's job is to make the OTHER six coherent.

## Workflows / libs you own
- `cre/zipreport/` (CRE-00) — the §8.0 envelope + every per-receiver payload encoder. List which
  `(receiver, reportType/opType)` tuples it covers — this is the canonical Q3/Q7 cross-index.
- `cre/scaffold/` — the clone-me (R) workflow template (not deployed).
- `cre/keeper/` spine (KEEPER-00) — the Job/Runner/Submit machinery (the (K) substrate; individual
  Jobs are mapped by clusters 3/4/5). Map the spine + the `identity_job` liveness model.

## On-chain seams to classify (C section) — the identity model
- `ReceiverTemplate` (base) — the Forwarder gate + workflow-identity pin fronting every `onReport`.
- `CloneReportReceiver` — the clone variant (CTR-01 two-door) used by the buy-burn module.
- `CREGatingHook` — NOT a receiver; the Euler vault hook gating per-line borrow/liquidate on EVC
  operator authorization. Classify it precisely (it's a borrow-gate, not a report path).
- The per-receiver `workflowName`/author pin (CTR-16) and the daemon-name map
  (CONTROLLER/REVALUATION/SHAREFEEDS/WAREHOUSE/COORDINATOR/RATE). Build the receiver→daemon table.

## Gap focus (D section)
- **Monitoring** (`build/pending-docs/monitoring.md`) — confirm it is read-only surveillance with
  NO CRE write workflow owed (so it isn't mistaken for a missing producer in Q4).
- Any receiver whose identity pin is dormant/unset (a deploy-time obligation, not a workflow gap) —
  note as build-phase, not Q8.

## Read-set
Workflows/libs: `cre/zipreport/README.md`, `cre/scaffold/{README.md,workflow.go,main.go}`,
`cre/keeper/README.md`, `cre/keeper/internal/job/job.go`,
`cre/keeper/internal/job/identity_job.go`.
Contracts: `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` (the base),
`contracts/src/supply/szipUSD/CloneReportReceiver.sol`, `contracts/src/CREGatingHook.sol`.
Spec: `build/claude-zipcode.md §8.0` (report envelope), `§8.11` (build-ticket map), `§17`
(build-phase mutable wiring / identity sealing). Doc: `build/pending-docs/monitoring.md`.
