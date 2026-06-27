# CRE surface map — prompt set

> **Running it?** Read `_boot.md` (the cartographer persona + output schema) and `synthesis.md`
> (the conductor) first. This file is the map of the map.

The x-ray / adversarial-review harness covers only the on-chain Solidity layer. The **Chainlink
CRE** automation (wasip1 workflows + the native keeper service under `cre/`) is otherwise
unmapped. This prompt set fans seven cluster-scoped cartographer agents across the CRE terrain
and synthesizes a single **`adversarial-review/CRE-map.md`** that answers, by number:

1. Which CRE workflows do we have (built)?
2. Which are yet to build (unbuilt / blocked / policy-blocked)?
3. Where does each plug into the code (contract + reportType/opType/operator-fn + `file:line`)?
4. Are there workflows we ought to have but don't (gaps)?
5. What is the intention of each workflow?
6. Are there clusters of workflows?
7. What contracts are associated with each workflow?
8. What contracts have a *place* for a workflow but no workflow yet?

## The two CRE shapes (so the map classifies consistently)
- **(R) report path** — wasip1 workflow → Forwarder → `onReport` receiver (`ReceiverTemplate` /
  `CloneReportReceiver`), carrying a `reportType` (or `opType`).
- **(K) keeper path** — `cre/keeper/` Go service driving `onlyOperator`/`onlyController` functions
  as ordinary txs (one `Job` per unit). **Most engine modules are driven this way — they have no
  report socket**, which is the heart of Q8.

## Missions (each agent maps ONE cluster end-to-end)

| # | Cluster | Workflows | Key contracts |
|---|---|---|---|
| 1 | Underwriting & controller lifecycle | revaluation, controller, coordinator | ZipcodeController, ZipcodeOracleRegistry, DefaultCoordinator, SiloRegistry, EulerVenueAdapter |
| 2 | NAV / share-price feeds | sharefeeds, szalpha-rate (feed) | SzipNavOracle, SzipFarmUtilityLpOracle, SzAlphaRateOracle, AlgebraIchiFairLpOracle |
| 3 | Exit / buy-burn | buyburn-bid, keeper burn_job | SzipBuyBurnModule, ExitGate, SzipUSD, DurationFreezeModule |
| 4 | Warehouse / redemption | warehouse (CRE-04 + 02b/02c), keeper redemption_job | WarehouseAdminModule, CreditWarehouse, ZipRedemptionQueue, OffRampModule |
| 5 | Engine / harvest (Q8 hot zone) | keeper strike_loop_job, winddown_lp_job, identity_job | HarvestVote/FarmUtilityLoop/Exercise/Sell/Recycle/LpStrategy modules, DurationFreezeModule |
| 6 | Bridge / loss-recovery | szalpha-rate (bridge), UNBUILT xALPHA→TAO→USDC drain | SzAlpha, SzAlphaTokenPool, SzAlphaMirror, SzAlphaRateOracle, LienXAlphaEscrow |
| 7 | Shared infra, identity & monitoring | zipreport (CRE-00), scaffold, keeper spine | CREGatingHook, ReceiverTemplate base, CloneReportReceiver, all identity gates |

Each cluster lives in `<n>-<slug>/` with a `mission.md` (the scoped brief + read-set) and a
`context.files` (the inline file list for non-agentic panel legs).

## Run
Per `synthesis.md`: spawn the 7 cluster agents (`general-purpose`) in parallel — each reads
`_boot.md` + its `mission.md` + the named files and returns the A–E schema. The conductor then
**verifies each claim against source**, dedups cross-cluster crossings, and assembles
`adversarial-review/CRE-map.md` (8 numbered sections + a master workflow table + a Q8
seam-vs-workflow table). The map is the deliverable; this set produces it.
