CLUSTER 5 — Engine / harvest (the Q8 hot zone)

Read `../_boot.md` first (persona + the A–E output schema). This is the auto-compounder engine and
the wind-down lever. **Critical for Q8:** the 8-B5…8-B10 engine modules expose `onlyOperator`
sockets and are driven by the keeper service via direct tx orchestration — they have **no report
receivers**. Map that precisely; do not mistake an operator socket for a missing workflow if a
keeper Job drives it, and do flag any socket no Job drives.

## Workflows you own
- `cre/keeper/internal/job/strike_loop_job.go` (KEEPER-01b core) — the ordered harvest plan
  (claim→borrow→exercise→sell→repay→credit→[recycle→addLiq→stake]) across six modules. Note the
  policy-blocked layers (regime EMA B1, keeper state B2, vote weights C1, lock-vs-sell C2,
  claimRebase C3, per-epoch cap C5) — these are Q2 (policy-blocked), the core is Q1 (built/ready).
- `cre/keeper/internal/job/winddown_lp_job.go` (KEEPER-02) — coverage-excess-bounded
  unstake→removeLiquidity on `LpStrategyModule`; default-OFF, needs a private RPC config.
- `cre/keeper/internal/job/identity_job.go` — read-only operator/owner liveness probe (template).

## On-chain seams to classify (C section)
For EACH of `HarvestVoteModule`, `FarmUtilityLoopModule`, `ExerciseModule`, `SellModule`,
`RecycleModule`, `LpStrategyModule`: list the `onlyOperator` entry fns (operator-socket) and which
keeper Job (if any) drives them. `DurationFreezeModule` is a coverage-read (gates dissolution/exit,
no write path). Record which sockets are covered by `strike_loop_job` vs `winddown_lp_job` vs none.

## Gap focus (D section)
- Confirm there is **no report receiver** anywhere in this cluster (Q8 anchor) — operator path only.
- The real **Hydrex pool** is unbuilt (harvest runs on a WETH/USDC placeholder) — flag the blocker
  and which Job goes live with the real pool.
- Note the policy-blocked KEEPER-01b layers as owed-but-deferred (Q2/Q4).

## Read-set
Workflows: `cre/keeper/internal/job/strike_loop_job.go`,
`cre/keeper/internal/job/winddown_lp_job.go`, `cre/keeper/internal/job/identity_job.go`,
`cre/keeper/internal/job/job.go` (the Job interface), `cre/keeper/README.md`.
Contracts (all under `contracts/src/supply/szipUSD/`): `HarvestVoteModule.sol`,
`FarmUtilityLoopModule.sol`, `ExerciseModule.sol`, `SellModule.sol`, `RecycleModule.sol`,
`LpStrategyModule.sol`, `DurationFreezeModule.sol`.
Wires: `docs/wires/8-B5-FarmUtilityLoop.md`, `docs/wires/8-B6-LpStrategyModule.md`,
`docs/wires/8-B7-HarvestVoteModule.md`, `docs/wires/8-B8-ExerciseModule.md`,
`docs/wires/8-B9-SellModule.md`, `docs/wires/8-B10-RecycleModule.md`,
`docs/wires/DurationFreezeModule.md`.
Spec/tickets: `build/claude-zipcode.md §8.7` (engine operator path — NOT a report),
`build/tickets/cre/KEEPER-01b-OPEN-POLICY.md`, `build/tickets/cre/KEEPER-02-winddown-lp-dissolution.md`,
`build/pending-docs/auto-compounder.md`, `build/pending-docs/hydrex.md`.
