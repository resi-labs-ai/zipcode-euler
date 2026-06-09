# GRAPH-02 — zipcode-euler subgraph: dashboard-metric derivation (5 metrics) (README §348 / §12 / monitoring.md)

> **Frontend-track / build-only.** Sits on top of GRAPH-01's entities (`GRAPH-01-event-indexing.md`). The five
> dashboard metrics the protocol owes — **NAV history · zipUSD peg · szipUSD APR · utilization · insurance-
> coverage** (§12 + `pending-docs/monitoring.md` + README §348). For each: the exact formula, the input
> entities / view-reads, the **subgraph-vs-direct-read tag**, the time-series/snapshot model, and the resolved
> open question. Build GRAPH-01 entities first; these formulas read them.
>
> **The governing split (README §348):** the **subgraph owns history + aggregation**; the **frontend reads cheap
> point-in-time values directly** (`navEntry()`, `debtOf`, `totalSupply`, share price, pool tick). Rule of thumb:
> **needs more than one block to compute → subgraph; a single `eth_call` answers it → direct read.** Every metric
> below is tagged one or the other — none ambiguous.
>
> **The hard rule (do not break it): index the oracle's OUTPUTS, never recompute NAV.** `SzipNavOracle` composes
> NAV on-chain (hybrid compose + windowed TWAP + bracket + provision). The subgraph stores `Poked`/
> `LegPriceUpdated`/`ProvisionWritten` (GRAPH-01 `NavSnapshot`/`LegPrice`/`Provision`) — it never multiplies legs
> into a NAV. A second, divergent NAV is the worst failure class. Live NAV-per-share is a `navEntry()`/`navExit()`
> direct read.

**Deliverable**
The metric layer realized as: (a) the GraphQL **queries** the Vue dashboard issues against the GRAPH-01 entities
(documented here as the binding surface — the UI wires to them), (b) the small set of **direct view-reads** the
frontend pairs with them, (c) any **time-bucket snapshot entities** GRAPH-01 must add for chart density (§7). No
new contract code. The frontend pass (memory `[[frontend-after-contracts]]`) consumes this as its data contract.

**Spec §**
- `README.md` §348 — the subgraph-history / direct-read split.
- `claude-zipcode.md` §12 — the on-chain NAV solvency model (why NAV is indexed-from-outputs).
- `pending-docs/monitoring.md` §B/§C — the dashboard metric inventory (NAV-per-share, origination throughput,
  trailing-realized APR, over-collateralization) + the "real lending yield is the protocol's; depositor return is
  NAV-per-share accretion" rule (§monitoring:6-9).
- `pending-docs/spv-lien-proof.md` §3/§4 — insurance is an **off-chain carrier fact** gated at origination via
  Proof of Insurance (the §insurance-coverage resolution).
- The view reads: `SzipNavOracle.{navEntry,navExit}()` (`:348/:357`), `DurationFreezeModule.{utilization,
  committedValue,requiredFraction}()` (`:170/:194/:183`), the EE-pool `convertToAssets`/`maxWithdraw` (warehouse).

---

## 1. Metric inventory + tag at a glance

| Metric | Where it computes | Primary source |
|---|---|---|
| **NAV history** | **SUBGRAPH** (history) + frontend direct read (live tick) | GRAPH-01 `NavSnapshot`/`LegPrice`/`Provision`/`LpMark` (oracle outputs) ; live = `navEntry()`/`navExit()` |
| **zipUSD peg** | **SUBGRAPH** (history chart) + frontend direct read (live tick) | secondary pool `Swap`/state → `PegSnapshot` (NEW §3 / §6) ; live = pool reserves read |
| **szipUSD APR** | **SUBGRAPH** (needs the trailing window) | two `NavSnapshot`s spanning the window (trailing-realized slope) |
| **utilization** | **SUBGRAPH** (over-time series) + frontend direct read (live gauge) | junior: `FreezeAction.committedValueAfter` ÷ basket NAV ; senior: `Line.drawnTotal`/warehouse ; live = `utilization()`/`committedValue()` |
| **insurance-coverage** | **OFF-CHAIN / NOT-SUBGRAPH** (origination-gate-implied + CRE feed) | every originated `Lien` ⇒ Proof-of-Insurance gate passed (§5) ; live status = CRE feed, not on-chain |

---

## 2. NAV history  — SUBGRAPH (history) + frontend direct read (live)

**Formula.** NAV-per-share = basket NAV ÷ szipUSD supply, composed on-chain by `SzipNavOracle` (hybrid spot/TWAP
bracket, minus provision). **The subgraph does NOT compute this.** It stores the oracle's emitted building blocks
and the live number is read directly.

**Subgraph (history):**
- Source entities (GRAPH-01 §3, all from oracle outputs): `NavSnapshot` (per `Poked` — carries `cumNav`, `oracleTs`,
  and the carried-forward `legAlphaUsd`/`legHydxUsd`/`lpMark`/`provision`), `LegPrice` (per-leg mark series),
  `Provision` (impairment series), `LpMark` (LP-leg series).
- The **NAV-per-share chart** is the `NavSnapshot` series ordered by `blockTimestamp`. The **provision (impairment)
  chart** is the `Provision` series. The **leg-mark charts** are `LegPrice` filtered by `leg` (0=ALPHA_USD,
  1=HYDX_USD) + `LpMark`.
- Query the dashboard issues:
  ```graphql
  { navSnapshots(orderBy: blockTimestamp, orderDirection: desc, first: 500) {
      cumNav oracleTs provision legAlphaUsd legHydxUsd lpMark blockTimestamp } }
  ```

**Frontend direct read (live tick — single `eth_call`):**
- `SzipNavOracle.navEntry()` (issuance price `max(spot,twap)`, reverts on stale leg — `SzipNavOracle.sol:348`).
- `SzipNavOracle.navExit()` (exit price `min(spot,twap)`, no stale revert — `:357`).
- The live number is **never** taken from the subgraph (the subgraph lags head + cannot price between pokes).

**Why this is the §2 hard rule, made concrete:** the GRAPH-01 `handlePoked` carries forward emitted leg/provision
values into a snapshot row — it does **not** multiply legs into a NAV. If a chart needs a displayable NAV-per-share
*between* the discrete oracle outputs, the frontend reads `navExit()` live; the subgraph only ever shows what the
oracle emitted. No divergent second NAV.

> **Open-Q (which NAV anchors the APR slope) — see §4.** NAV history itself has no open question: it is the verbatim
> oracle-output series.

---

## 3. zipUSD peg  — SUBGRAPH (history chart) + frontend direct read (live tick)

**Definition (README §348 / §6):** the **secondary-AMM price of zipUSD vs USDC** — NOT computed on-chain per
request, NOT a protocol oracle. zipUSD is over-collateralized 1:1 at the warehouse (`monitoring.md` §C
over-collateralization), but the *traded* peg is the Hydrex/secondary-pool price.

**Open-Q (peg in M1 scope?) — RESOLVED:**
- The **history chart belongs to the subgraph** (a price series needs many blocks); the **live tick is a direct
  pool read**. So peg IS in subgraph scope **for the chart**, direct-read for the live number.
- **BUT the peg pool is NOT a zipcode-euler contract** — it is the external Hydrex (Algebra Integral) zipUSD/USDC
  (or zipUSD/xALPHA per memory `[[rubicon-fork-and-closed-loop]]` DEC-03) pool. Its `Swap`/`globalState` events are
  **not in the GRAPH-01 §2 inventory** (that inventory is zipcode contracts only). To index the peg history the
  manifest must add the **external pool as a fixed datasource** (Algebra pool ABI: `Swap(...)` + the pool's
  `globalState`). **This is a GRAPH-01 manifest addition, deferred to item-10** because the pool address is created
  at deploy/liquidity-bootstrap time (memory: `zipUSD/xALPHA pool on Hydrex`, DEC-03), exactly like the protocol
  addresses.

**Subgraph (history) — the deferred-to-item-10 add (§6 obligation):**
- New datasource `HydrexZipUsdPool` (Algebra pool, ABI from the Hydrex/Algebra Integral pool — `reference/` has the
  Hydrex fork). Handler `handleSwap` → `PegSnapshot @entity(immutable: true) { id, sqrtPriceX96 / price, liquidity,
  zeroToOne, amount0, amount1, blockTimestamp, tx }`, deriving the zipUSD/USDC price from the pool `globalState`
  price (or the swap's amount ratio). Time-ordered series = the peg chart.
- **Decision: this is a SECOND, separate dynamic-or-fixed datasource the GRAPH-01 manifest gains at item-10.** It is
  NOT a zipcode event; do not invent a zipcode `Peg` event (no contract emits one — that would be back-pressure for
  a number the protocol deliberately does not compute on-chain). Flagged in §6.

**Frontend direct read (live tick):** read the pool's `globalState()` (Algebra) / reserves and compute the spot
price client-side — a single `eth_call`, exact at head.

---

## 4. szipUSD APR  — SUBGRAPH (needs the trailing window)  · TRAILING-REALIZED, never projected

**Formula (the §12 / `monitoring.md` rule — depositor return is NAV-per-share accretion, §monitoring:6-9):**
```
apr = (navEnd / navStart − 1) × (YEAR_SECONDS / windowSeconds)
```
trailing-**realized**: the realized slope of the szipUSD NAV-per-share series over a trailing window. The
depositor's M1 return is **NAV accretion from the single-sink recycle** (memory `[[supply-side-redesign-locked]]`),
so APR is the realized slope — **never a projected/forward number, never blended with the xALPHA intrinsic APR.**

**Source (subgraph — it owns the history):** two `NavSnapshot`s spanning the window. **Open-Q (which NAV anchors
the slope) — RESOLVED:** anchor on the **TWAP accumulator** the oracle already emits, NOT spot, NOT entry/exit:
- The GRAPH-01 `NavSnapshot.cumNav` is `Poked.cumNav` — the oracle's **own windowed-TWAP accumulator**
  (`SzipNavOracle.sol:129`, the `cumNav`/`ts` checkpoint). The TWAP-NAV-per-share over `[t0,t1]` is
  `(cumNav_1 − cumNav_0) / (oracleTs_1 − oracleTs_0)` — i.e. **the oracle's own TWAP between the two checkpoints**,
  read straight off the accumulator deltas. This is the highest-fidelity slope source: it is the oracle's realized
  time-weighted NAV, not a subgraph re-derivation, and it smooths the spot jitter the bracket would introduce.
- **Decision:** `navStart`/`navEnd` for the APR = the **accumulator-implied TWAP NAV-per-share** at the window
  endpoints (`Δcum/Δt`), NOT `navEntry`/`navExit` (those are point-in-time bracket reads for issuance/exit, not a
  realized-history anchor). This keeps APR strictly a function of indexed oracle outputs.

**Open-Q (window length) — RESOLVED:** expose **multiple trailing windows** off the same series — **7d and 30d**
(the dashboard standard; `monitoring.md` §Product lists "trailing-realized APR" without a fixed window, so the
subgraph serves both and the UI picks). The window is computed at query time from the `NavSnapshot` series; no
fixed-window entity is required for M1, but §7's daily bucket makes the 7d/30d lookups O(1).

**Distinctness (do NOT conflate):** this szipUSD-vault realized APR is **NOT** the **xALPHA-LST intrinsic APR**
(the CRE `XAlphaAprOracle`, ticket 8x-02 — the bridged-LST staking yield). They are different numbers from
different sources; the dashboard shows them in separate fields and the subgraph derives only the vault one.

**Tag: SUBGRAPH.** (Requires the trailing window of snapshots — more than one block; never a single `eth_call`.)

**Query:**
```graphql
# endpoints for a 7d window (windowSeconds = 604800); UI computes the slope client-side or via a derived field
{ start: navSnapshots(where:{blockTimestamp_lte:$tMinus7d}, orderBy:blockTimestamp, orderDirection:desc, first:1){ cumNav oracleTs }
  end:   navSnapshots(orderBy:blockTimestamp, orderDirection:desc, first:1){ cumNav oracleTs } }
```

---

## 5. utilization  — SUBGRAPH (over-time series) + frontend direct read (live gauge)

There are **two utilization figures** (both real, both wanted):

**5a. Junior structural-freeze utilization (§6.4 — what sizes the sidecar freeze):**
```
u_junior = committedValue / basketNAV            # the φ_A liquidity-path identity
```
- **Subgraph (over-time):** the `FreezeAction.committedValueAfter` series (GRAPH-01 §3, from `DurationFreezeModule`
  `Committed`/`Released`) is the numerator-over-time; pair with the `NavSnapshot`-implied basket NAV for the ratio
  history.
- **Frontend direct read (live gauge):** `DurationFreezeModule.utilization()` (`:170` — `(sa−free)/sa` over the EE
  pool) and `committedValue()` (`:194`) and `requiredFraction()` (`:183`) — a single `eth_call` each, exact at head.
  The module's own `utilization()` is the authoritative live gauge; the subgraph's `FreezeAction` series is the
  history behind it.

**5b. Senior origination throughput (`monitoring.md` §C — the *real* M1 constraint):**
```
throughput = USDC deployed-in-loans / USDC total (deployed + idle)
```
- **Subgraph (over-time):** `Σ Line.drawnTotal` (GRAPH-01, from `LineDrawn`) minus repaid (the `LineBorrow` template
  `REPAY` series) = deployed; the redemption/`EpochSettled` + `LineFunded` flows give the funding side. The
  deployed-over-time series is the subgraph's.
- **Frontend direct read (live):** the **warehouse** idle/deployed — `EE_POOL.convertToAssets(EE_POOL.balanceOf(
  warehouse))` (total senior assets) vs `EE_POOL.maxWithdraw(warehouse)` (free) — the same reads
  `DurationFreezeModule.utilization()` uses (`:172/:174`); a single multicall at head.

**Tag: SUBGRAPH (series) + DIRECT READ (live gauge).** History over time → subgraph; the live needle → direct read.

**Query (junior history):**
```graphql
{ freezeActions(orderBy: timestamp, orderDirection: desc, first: 200) { committedValueAfter floor kind timestamp } }
```

---

## 6. insurance-coverage  — OFF-CHAIN / NOT-SUBGRAPH (origination-gate-implied + CRE feed)

**THE flag — RESOLVED (decision (b)+(c), explicitly NOT a faked on-chain number):**

Per `pending-docs/spv-lien-proof.md` §3, insurance is an **off-chain carrier fact**: the carrier confirms a policy
(Proof of Insurance) and it is a **CRE gate at origination** — "no line is issued unless Proof of Lien **AND** Proof
of Insurance pass" (`spv-lien-proof.md:39`). There is **no on-chain event carrying coverage status**, and there
should not be a faked one.

**Resolution:**
- **(b) origination-gate-implied (the subgraph's honest contribution):** every `Lien` that exists in the subgraph
  **passed the Proof-of-Insurance gate at origination by construction** (the gate is upstream of `LienOriginated`).
  So "coverage existed at origination" is a **derived boolean = `Lien` exists** — the subgraph can surface
  `coveredAtOrigination: true` for every indexed lien **without inventing a number**. This is the only insurance
  fact the chain implies.
- **(c) live coverage status = off-chain CRE feed, NOT subgraph:** whether a policy is *currently* in force, its
  terms, claim timing (`spv-lien-proof.md:68` — "a duration leg") are **off-chain carrier facts surfaced by the CRE
  feed directly to the frontend**, not by an on-chain event and not by the subgraph.

**Tag: OFF-CHAIN / NOT-SUBGRAPH.** The dashboard's "insurance coverage" panel = (subgraph) the count/list of liens
that passed the origination gate + (CRE feed, direct) the live carrier status. **The subgraph does NOT emit, store,
or compute a coverage number that no contract carries.**

**Back-pressure decision — NONE filed, deliberately.** A "CRE-pushed coverage attestation event" (option (a)) is
**rejected for M1**: the spv-lien-proof model keeps insurance as an off-chain product (`spv-lien-proof.md:9/:105`,
the insurance product "may not exist" yet). Adding an on-chain coverage event now would be building a surface for a
business leg that is not finalized. If/when a coverage attestation lands on-chain (M2+), GRAPH-01 gains a handler;
until then this is correctly off-chain. (No contract obligation filed — the absence is intentional, not a gap.)

---

## 7. The snapshot / time-series model  (open-Q: cadence — RESOLVED)

**Open-Q (snapshot cadence — event-driven vs time-bucketed) — RESOLVED: BOTH, layered.**
- **Event-driven (the base truth):** `NavSnapshot` is written **on each `Poked`** (one row per oracle output) —
  GRAPH-01 §5.9. This is the exact, lossless series; APR/NAV correctness derives from it. Never down-sample the
  base.
- **Time-bucketed (chart density + O(1) window lookups):** add a **daily** rollup entity GRAPH-01 writes by deriving
  the bucket id from `block.timestamp / 86400`:
  ```graphql
  type NavDayData @entity {            # one row per UTC day
    id: Bytes!                         # day index (timestamp / 86400)
    dayStartTimestamp: BigInt!
    navTwapStart: BigInt!              # cumNav/oracleTs at first Poked of the day
    navTwapEnd: BigInt!                # at last Poked of the day
    provisionEnd: BigInt!
    pokeCount: Int!
  }
  ```
  The `NavDayData` makes the §4 7d/30d APR lookups O(1) (read day t and day t−7/t−30) and bounds chart payloads. It
  is a **derived rollup of the event-driven base**, not a separate NAV computation. **Reorg note:** Base finality is
  fast; mutable `NavDayData` (non-`immutable`) self-heals on reorg because the handler reloads-and-overwrites the
  day row from the (reorg-corrected) `Poked` stream.

> **Decision:** event-driven base (`NavSnapshot`, immutable) + daily rollup (`NavDayData`, mutable). The same daily
> pattern can wrap `PegSnapshot` (§3) and the utilization series (§5) if the UI needs bounded chart payloads — add
> per-need, not preemptively.

---

## 8. Resolved / escalated open questions (GRAPH-02 scope)

| # | Open question | Resolution |
|---|---|---|
| 1 | **APR window** length + which NAV anchors the slope | **7d + 30d** trailing; anchored on the oracle's **TWAP accumulator** (`NavSnapshot.cumNav`/`oracleTs` deltas), NOT spot/entry/exit. SUBGRAPH. Distinct from the xALPHA intrinsic APR (8x-02). §4 |
| 2 | **zipUSD peg** in M1 scope? | History = SUBGRAPH (but via a NEW external Hydrex/Algebra pool datasource, deferred to item-10 — the pool address is a deploy output, like the protocol addrs); live tick = direct pool read. §3 / §6-of-GRAPH-01-style obligation |
| 3 | **insurance-coverage** source | **OFF-CHAIN / NOT-SUBGRAPH.** Origination-gate-implied (`Lien` exists ⇒ PoI passed) for the count; live status from the CRE feed directly. No on-chain coverage number faked; no back-pressure event filed (intentional). §6 |
| 4 | **snapshot cadence** | **BOTH:** event-driven `NavSnapshot` (base, immutable, per `Poked`) + daily `NavDayData` rollup (mutable, chart density + O(1) APR windows). §7 |
| 5 | back-pressure (any metric needing a field no event carries) | NAV/APR/utilization all trace to indexed oracle/freeze/venue outputs — no gap. Peg needs the **external pool datasource** (a manifest add, not a zipcode contract change). insurance is deliberately off-chain. The ONE contract back-pressure is GRAPH-01 §9 B-1 (`Withdraw` `requestId`), unrelated to these five metrics. §8 |

---

## 9. Every metric input traces to a GRAPH-01 entity field or a named view read (the fidelity check)

| Metric | Subgraph input (GRAPH-01 entity.field) | Direct view read |
|---|---|---|
| NAV history | `NavSnapshot.{cumNav,oracleTs,provision,legAlphaUsd,legHydxUsd,lpMark}`, `LegPrice`, `Provision`, `LpMark` | `SzipNavOracle.navEntry()/navExit()` |
| zipUSD peg | `PegSnapshot.*` (NEW external-pool datasource, item-10) | Hydrex/Algebra pool `globalState()` |
| szipUSD APR | two `NavSnapshot.{cumNav,oracleTs}` over the window (+ `NavDayData` for O(1)) | — (never a single read) |
| utilization (junior) | `FreezeAction.committedValueAfter` ÷ `NavSnapshot` basket | `DurationFreezeModule.utilization()/committedValue()/requiredFraction()` |
| utilization (senior) | `Line.drawnTotal`, `LineBorrow(REPAY)`, `RedemptionEpoch`, `LineFunded` | `EE_POOL.convertToAssets/maxWithdraw(warehouse)` |
| insurance-coverage | `Lien` existence ⇒ `coveredAtOrigination` (origination-gate-implied) | CRE feed (off-chain, not a contract read) |

> Fidelity bar (both prep kits' §6 checklists): NAV/provision indexed from oracle outputs, never recomputed (§2);
> APR trailing-realized off the NAV series, never projected, never blended with the xALPHA intrinsic APR (§4);
> every metric tagged subgraph-or-direct-read (§1) — none ambiguous; insurance-coverage source decided = off-chain
> (§6); every input traces to a GRAPH-01 field or named view read (this table). ✓
