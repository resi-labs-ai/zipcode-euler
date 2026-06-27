CLUSTER 4 — Warehouse / redemption

Read `../_boot.md` first (persona + the A–E output schema). Map the senior-pool ⇄ warehouse custody
ops and the par-redemption settlement that they fund.

## Workflows you own
- `cre/warehouse/` (CRE-04) — senior warehouse ops → `WarehouseAdminModule` (opType 1 SUPPLY / 2
  APPROVE / 3 REDEEM / 4 REPAY) via Zodiac Roles. Plus the default-OFF cron legs folded into the same
  binary: **CRE-02b** (reserve-gated REDEEM→REPAY funding) and **CRE-02c** (cross-silo solver). Map
  all three and their on/off posture; note the "exactly one of funding/solver on" constraint.
- `cre/keeper/internal/job/redemption_job.go` (CRE-02 K-half) — settles the queue
  (`settleEpoch`) + claims through `OffRampModule`; reactive to whatever USDC the REPAY delivered.

## On-chain seams to classify (C section)
`WarehouseAdminModule` (Roles-op, opType 1/2/3/4 — the report receiver re-encoding pinned Safe
calls), `CreditWarehouse` (the Safe the module acts for), `ZipRedemptionQueue`
(`settleEpoch` — controller-socket, NOT a report receiver), `OffRampModule`
(`requestRedeem`/`claim` — operator-socket). Be explicit which are report-driven vs keeper-driven.

## Gap focus (D section)
`ZipRedemptionQueue` and `OffRampModule` are operator/controller sockets with **no report path** —
confirm they're driven only by the keeper Job (Q8). Note the CRE-02b/02c default-OFF status (built
but dormant — a Q1/Q2 nuance).

## Read-set
Workflows: `cre/warehouse/{README.md,workflow.go,main.go}`,
`cre/keeper/internal/job/redemption_job.go`, `cre/keeper/README.md`, `cre/zipreport/README.md`
(opType SUPPLY/APPROVE/REDEEM/REPAY payloads).
Contracts: `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`,
`contracts/src/supply/ZipRedemptionQueue.sol`, `contracts/src/supply/szipUSD/OffRampModule.sol`.
Wires: `docs/wires/8-Bw-CreditWarehouse.md`, `docs/wires/9-ZipRedemptionQueue.md`,
`docs/wires/OffRampModule.md`, `docs/roles.md` (the Roles scope pins).
Spec: `build/claude-zipcode.md §8.3` (redemption settlement), `§8.5` (senior-warehouse ops),
`§8.2` (funding/cash-reserve). Ticket: `build/tickets/cre/CRE-OPS-ROUTING.md`.
