# CRE-map synthesis — the conductor

You are the conductor. You run the seven cluster missions, verify their output, dedup the overlaps,
and assemble **`adversarial-review/CRE-map.md`** — the single deliverable. Mirror the discipline of
`../../CONDUCTOR.md`: subagent output is a *lead*, not truth, until you re-read the source yourself.

## Step 1 — run the seven cluster agents (parallel)
Spawn ONE `general-purpose` subagent per cluster, all in one message. Per-agent prompt template
(substitute `<n>-<slug>`):

> You are a CRE cartographer running ONE cluster-mapping mission. Read in full FIRST:
> `adversarial-review/prompts/cre/_boot.md` (persona + the A–E output schema) and
> `adversarial-review/prompts/cre/<n>-<slug>/mission.md`. Then actually OPEN every file the mission
> names — the workflow code, the contracts, the wire docs, the spec sections, the tickets — and map
> the terrain. Cite `path:line`. Your final message must BE the A–E report in the exact schema
> `_boot.md` specifies. Map, don't audit. "No workflow drives this seam" is a required finding, not
> an omission.

The clusters: `1-underwriting`, `2-navfeeds`, `3-exit-buyburn`, `4-warehouse-redemption`,
`5-engine-harvest`, `6-bridge-lossrecovery`, `7-infra-identity`.

## Step 2 — VERIFY before landing (non-negotiable)
For every workflow→contract write, every reportType/opType, every "seam with no workflow," and every
status claim: **re-open the cited `path:line` and confirm it yourself.** Never relay a cluster
agent's claim raw. A claim you cannot verify is marked `unverified` in the map, not dropped silently.
Watch especially for: a status claimed `built` that is actually parked/default-OFF; a "report
socket" that is really an operator socket (or vice-versa); an opType/reportType number off-by-one
vs the contract decode.

## Step 3 — dedup the crossings
Each cluster ends with `## Crossings`. Assign every workflow and every contract ONE canonical home:
- `SzAlphaRateOracle` / `szalpha-rate` → consuming-NAV side = cluster 2; transport/bridge side =
  cluster 6. In the map, one workflow row, noting both faces.
- `DefaultCoordinator` → report-socket + lifecycle = cluster 1; bond-destination/recovery = cluster 6.
- `OffRampModule` → exit side touches cluster 3; redemption side = cluster 4 (canonical).
- `DurationFreezeModule` → deep map = cluster 5; clusters 3/4 only read it.
- `zipreport` payload tuples (cluster 7) are the canonical cross-index for the Q3/Q7 columns.
Resolve any contradiction between two clusters by re-reading source; record the resolution.

## Step 4 — write `adversarial-review/CRE-map.md`
Catalog style (tables fine — this is an inventory, like the wires catalog). Structure EXACTLY:

- **Master workflow table** (top): `id · cluster · shape (R/K/lib) · status · target contract ·
  reportType/opType/fn · one-line intention`. One row per workflow (built + planned + blocked).
- **§1 — Workflows we have (built).** Per workflow: shape, intention, reads/writes, tests. (Q1/Q5)
- **§2 — Workflows yet to build.** Unbuilt / blocked (external dep) / policy-blocked / deferred, each
  with the blocker and what unblocks it. (Q2)
- **§3 — Where each plugs in.** Workflow → contract → reportType/opType/operator-fn → `file:line`.
  Group by the (R) report path vs the (K) operator path. (Q3/Q7)
- **§4 — Workflows we ought to have but don't.** The gaps: seams with no workflow, the loss-recovery
  drain, real-Proof integration, liquidation-trigger, plus spec-implied-but-absent. Rank by whether
  M1-load-bearing vs deferred. (Q4)
- **§5 — Intention of each workflow.** One tight paragraph each (the "why it exists"). (Q5)
- **§6 — Clusters.** The seven clusters, their data-flow, and how they hand off (the system-level
  picture). (Q6)
- **§7 — Contracts associated with each workflow.** The workflow↔contract matrix. (Q7)
- **§8 — Contracts with a seam but no workflow.** Every operator-socket / receiver with no built or
  ticketed driver — the engine modules are the anchor; state for each whether it's driven by a keeper
  Job (so NOT a gap) or genuinely unwired (a gap). (Q8)

End with a **Coverage check**: the master table reconciles 1:1 against `ls cre/` +
`ls cre/keeper/internal/job/*.go`; every contract in the §8 seam list is accounted for; note any
`unverified` rows.

## Guardrails
- The map records the **filed-contract truth** where it differs from `claude-zipcode.md §8` intent;
  mark which wins.
- Status vocabulary is fixed: `built · planned · blocked · policy-blocked · deferred`.
- Do not invent workflows the spec doesn't name; a genuine gap (Q4/Q8) is described as a gap, not a
  phantom row in §1.
