CLUSTER 1 — Underwriting & controller lifecycle

Read `../_boot.md` first (persona + the A–E output schema). Map the credit-fact arc: how an
origination/draw/close/default decision becomes an on-chain report, and the contracts that receive it.

## Workflows you own
- `cre/revaluation/` (CRE-01a) — gas-bounded lien price-sweep → `ZipcodeOracleRegistry` (reportType 3).
- `cre/controller/` (CRE-01b) — origination/draw/close/status lifecycle → `ZipcodeController`
  (reportType 1/2/4/5/6); enforces the §8.9 Proof gate.
- `cre/coordinator/` (CRE-01c) — loss-action family → `DefaultCoordinator` (reportType 8). (The
  bond-routing/escrow internals belong to cluster 6 — note the crossing, don't deep-map them here.)

## On-chain seams to classify (C section)
`ZipcodeController` (report-socket, rt 1/2/4/5/6), `ZipcodeOracleRegistry` (report-socket, rt 3 +
its price-oracle read role), `DefaultCoordinator` (report-socket, rt 8 action family). Also note how
`SiloRegistry` (silo→venue routing, CTR-03), `EulerVenueAdapter` / `LineAccount`, and
`LienTokenFactory` / `LienCollateralToken` participate in the origination batch (they are NOT report
receivers — record them as the contracts the controller drives).

## Gap focus (D section)
- The **real Proof integration** (§8.9/§8.10) — the underwriting gates are mocked; flag what's owed.
- The **liquidation trigger**: the controller accepts a DEFAULT/LIQUIDATION status report, but is any
  workflow named to *emit* "delinquency detected"? Report whether this is owed or intentionally
  operator-driven. Cite the spec.

## Read-set
Workflows: `cre/revaluation/{README.md,workflow.go,main.go}`, `cre/controller/{README.md,workflow.go,main.go}`,
`cre/coordinator/{README.md,workflow.go,main.go}`, and the shared encoder `cre/zipreport/README.md`
(for the rt1/2/3/4/5/6/8 payload tuples).
Contracts: `contracts/src/ZipcodeController.sol`, `contracts/src/ZipcodeOracleRegistry.sol`,
`contracts/src/loss/DefaultCoordinator.sol`, `contracts/src/SiloRegistry.sol`,
`contracts/src/venue/EulerVenueAdapter.sol`, `contracts/src/venue/LineAccount.sol`,
`contracts/src/LienTokenFactory.sol`, `contracts/src/LienCollateralToken.sol`.
Wires: `docs/wires/WOOF-05.md` (controller), `docs/wires/WOOF-02.md` (revaluation),
`docs/wires/DefaultCoordinator.md`, `docs/roles.md`.
Spec: `build/claude-zipcode.md §8.1` (underwriting/origination/revaluation), `§8.4` (default/recovery),
`§8.9` (Proof gate), `§8.10` (off-chain underwriting & proof layer).
