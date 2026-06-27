CLUSTER 6 — Bridge / loss-recovery

Read `../_boot.md` first (persona + the A–E output schema). Map the cross-chain xALPHA rail and the
loss-recovery drain — the cluster richest in **unbuilt/blocked** workflows (Q2/Q4).

## Workflows you own
- `cre/szalpha-rate/` (8x-02) — the bridge-side transport of `SzAlpha.exchangeRate()` from Subtensor
  964 → `SzAlphaRateOracle` on Base (reportType 8 RATE). DEFERRED (R-1: can CRE read the 964
  precompile? + needs mainnet xALPHA). Map the producer shape and the blocker precisely. (Cluster 2
  maps the *consuming* NAV side — note the crossing.)
- The **UNBUILT loss-recovery drain** — on default the seized xALPHA bond lands in `adminSafe`;
  turning it to USDC needs bridge xALPHA → Bittensor → unstake → swap TAO/USDC, callable off
  `DefaultCoordinator` recovery. There is NO code/ticket for this drain yet — map it as the headline
  Q4 gap, cite where the spec/PROGRESS says it's owed and what blocks it (8x-01 bridge live).

## On-chain seams to classify (C section)
`SzAlpha` (the bridged token + `exchangeRate()` source), `SzAlphaTokenPool` (CCIP burn/mint pool),
`SzAlphaMirror`, `SzAlphaRateOracle` (report-socket, rt 8 RATE), `LienXAlphaEscrow` (bond custody —
where the seized xALPHA sits), `DefaultCoordinator` recovery actions (RESOLVE/WRITEOFF route the
bond — note the crossing to cluster 1, focus here on the xALPHA destination side).

## Gap focus (D section)
- The loss-recovery drain (the big one) — no workflow exists.
- The xALPHA rate push — deferred; what unblocks.
- Any bridge-side automation (CCIP message relays) that is operator/manual today.

## Read-set
Workflows: `cre/szalpha-rate/{README.md,main.go}`.
Contracts: `contracts/src/bridge/SzAlpha.sol`, `contracts/src/bridge/SzAlphaTokenPool.sol`,
`contracts/src/bridge/SzAlphaMirror.sol`, `contracts/src/bridge/SzAlphaRateOracle.sol`,
`contracts/src/loss/LienXAlphaEscrow.sol`, `contracts/src/loss/DefaultCoordinator.sol`.
Wires: `docs/wires/8x-01-szALPHA-bridge.md`, `docs/wires/8x-02-SzAlphaRateOracle.md`,
`docs/wires/8-Bx-LienXAlphaEscrow.md`.
Spec: `build/claude-zipcode.md §8.4` (default/recovery), `§8.8` (xALPHA rate), `§11` (loss-recovery /
unwind narrative). Also scan `build/tickets/PROGRESS.md` "Open obligations" for the loss-recovery seam.
