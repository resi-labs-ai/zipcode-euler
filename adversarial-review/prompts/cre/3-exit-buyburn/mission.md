CLUSTER 3 — Exit / buy-burn

Read `../_boot.md` first (persona + the A–E output schema). Map the szipUSD junior-exit valve: the
(R) bid loop that posts CoW buy-bids and the (K) burn that retires filled inventory.

## Workflows you own
- `cre/buyburn-bid/` (CRE-05a) — single-resting-bid loop → `SzipBuyBurnModule` (reportType 1
  POST_BID / 2 CANCEL_BID). Note the M1 posture (built-but-parked / manually driven) and the CRE-06
  working-capital split folded in as config.
- `cre/keeper/internal/job/burn_job.go` (KEEPER-01a) — after CoW fill detected, calls
  `ExitGate.burnFor` (windowController-gated). Note why no NAV gate is needed (NavOracle excludes
  pre-burn szipUSD from effective supply).

## On-chain seams to classify (C section)
`SzipBuyBurnModule` (report-socket via `CloneReportReceiver`, rt 1/2 — the CTR-01 "two-door"
exception socket), `ExitGate` (operator/windowController `burnFor` — operator-socket, not a
receiver), `SzipUSD` (the token being retired), `DurationFreezeModule` (coverage-read consulted by
the bid sizing — note it, cluster 5 owns its deep map).

## Gap focus (D section)
Is the bid loop's automation actually live or parked-for-manual? Record honestly (Q1 vs Q2 boundary).
Note any exit path that has no automation yet.

## Read-set
Workflows: `cre/buyburn-bid/{README.md,workflow.go,main.go}`,
`cre/keeper/internal/job/burn_job.go`, `cre/keeper/README.md` (spine), `cre/zipreport/README.md`
(POST_BID/CANCEL_BID payloads).
Contracts: `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol`,
`contracts/src/supply/szipUSD/ExitGate.sol`, `contracts/src/supply/szipUSD/SzipUSD.sol`,
`contracts/src/supply/szipUSD/CloneReportReceiver.sol`,
`contracts/src/supply/szipUSD/DurationFreezeModule.sol` (coverage-read only).
Wires: `docs/wires/8-B14-SzipBuyBurnModule.md`, `docs/wires/ExitGate-szipUSD.md`,
`docs/wires/DurationFreezeModule.md`.
Spec: `build/claude-zipcode.md §8.7` (engine operator path — buy-burn half), `§6` (the CoW exit).
