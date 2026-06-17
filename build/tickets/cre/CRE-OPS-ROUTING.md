# CRE-OPS-ROUTING — the operator/controller write-path decision (the CRE engine-track fork)

> A DECISION record (not a build item). Resolves the "systemic operator-path seam" (PROGRESS Open obligations,
> raised CTR-01 2026-06-16): for every `onlyOperator`/`onlyController`/`onlyWindowController` module, choose the
> CRE write transport. This ruling shapes how the rest of the CRE track (CRE-02, CRE-05) is built and what tickets
> it spawns. Refines `claude-zipcode.md` §8.7 (the operator path). Honors §17 (Timelock-settable wiring) and the
> §8.7 operator-TRUSTED design — does NOT reopen them.

## The two transports (cre-sdk-go reality, verified)
- **(R) Report path** — a wasip1 CRE workflow → `runtime.GenerateReport` → `evmClient.WriteReport` → the immutable
  Keystone Forwarder → `IReceiver.onReport`. DON-signed, f+1 consensus. The ONLY write cre-sdk-go's wasip1
  sandbox has (verified: the evm client exposes reads + `WriteReport` only — no raw-tx primitive).
- **(K) Keeper** — an off-chain Go service (go-ethereum) holding the hot key(s), submitting ordinary txs to the
  module's `onlyOperator`/`onlyController` entrypoints. This IS the §8.7 "single immutable operator … keeper
  identity; the on-chain gate is the operator address, not the Forwarder identity." It is NOT compiled to wasip1.

§8.7 already sanctions (K); CTR-01 proved (R) is *possible* for a clone via the `CloneReportReceiver` socket. The
decision is **which transport each module gets** — and the answer is **(K) for the engine/redemption/exit
operator surface, (R) only where a value is worth DON attestation**.

## The principle (when (R), when (K)) — the threshold the routing applies
Use **(R)** for a write iff BOTH hold: (a) the write carries a **computed economic value** whose integrity an
f+1 DON attestation meaningfully improves, AND (b) **report-driving it opens NO new attack surface**. Use **(K)**
otherwise — i.e. when the write is a **trusted, sequenced, high-frequency control action**, OR when report-driving
it would **introduce a manipulation surface that operator-trust deliberately closes**. This is not "keeper =
fallback"; it is a positive rule, and it is exactly why 8-B14 is (R) (a clean bid value, no manipulation surface)
while `RecycleModule.creditFreeValue` is (K) (report-driving the free-value credit re-opens the
external-oracle-manipulation exploit that §4.5.1 / §8.7 operator-trust exists to kill — see the table + the
adversarial-review note). The single trusted operator is **§13's locked trust model**, not a SPOF this ruling
introduces.

## The ruling — per-module routing table (gates verified in `contracts/src/...`)
| Module / entrypoint | Gate (verified) | Form | Transport | Why |
|---|---|---|---|---|
| `SzipBuyBurnModule.postBid/cancelBid` (8-B14) | `onlyOperator` **+ CTR-01 report socket** | Zodiac clone | **(R) report — SHIPPED (CRE-05a)** | A periodic *computed economic value* (bid size @ `navExit×(1−d)`, clamped to free reservoir) — worth f+1 attestation; a clean data-push, not a trusted tight loop. The one justified socket. |
| `ReservoirLoopModule.borrow/repay/…` (8-B5) | `onlyOperator` | Zodiac clone | **(K) keeper** | Operator-TRUSTED tight strike loop; borrows the reservoir USDC; LP_MARK-gated (its oracle is the (R) path, CRE-03). DON-per-call latency/cost is wrong. |
| `LpStrategyModule.add/stake/unstake` (8-B6) | `onlyOperator` (scalar args, §10.1) | Zodiac clone | **(K) keeper** | Mid-harvest unstake→commit→restake; multi-call; slippage floors computed off-chain. |
| `HarvestVoteModule.claim/vote` (8-B7) | `onlyOperator` | Zodiac clone | **(K) keeper** | Per-epoch claim+vote; high-frequency; no value to attest. |
| `ExerciseModule.exercise` (8-B8) | `onlyOperator` | Zodiac clone | **(K) keeper** | Strike-loop leg, sequenced inside the harvest cycle. |
| `SellModule.sellHydx` (8-B9) | `onlyOperator` | Zodiac clone | **(K) keeper** | Range-order sells w/ retrace guard; multi-step. |
| `RecycleModule.creditFreeValue/recycle/divert` (8-B10) | `onlyOperator`, **`creditFreeValue` UNBOUNDED** | Zodiac clone | **(K) keeper** | **§8.7/§4.5.1 LOCKED: operator-trust here KILLS the external-oracle-manipulation exploit** (`claude-zipcode.md:474-476`). Report-driving the free-value credit (feeding it as an attested value) would RE-OPEN exactly that surface — so (R) is not merely unhelpful here, it is unsafe. (K) is the principled choice, not the lazy one; it preserves the §8.7 trust model the spec already chose. |
| `OffRampModule.requestRedeem/claim` | `onlyOperator` | Zodiac clone | **(K) keeper** | Sequenced with the warehouse REDEEM→REPAY (the (R) path) and `settleEpoch`. |
| `ZipRedemptionQueue.settleEpoch/claim` | `onlyController`/`onlyRedeemController` | **standalone `Ownable`** (NOT a clone) | **(K) keeper** | On-demand, cheap, sequenced after REDEEM→REPAY. (Socketing it would need a plain `ReceiverTemplate`, not `CloneReportReceiver` — and there's no attestation value; the keeper is simpler.) |
| `ExitGate.burnFor` | `onlyWindowController` | **standalone `Ownable`** (NOT a clone) | **(K) keeper** | Async after a CoW fill is detected off-chain; mechanical "szipUSD arrived → retire it", nothing to attest. Already a CRE keeper key. |
| `DurationFreezeModule.commit/release` | `onlyOperator` | Zodiac clone | **DORMANT (keeper-on-exception)** | Premise under review (PROGRESS obligation: may be obviated by the exit topology; can't move staked LP). Drive `commit` ONLY on a coverage shortfall — no routine driver. Re-decide at the freeze rebuild. |

## The correction this ruling makes (record it)
**CTR-01's socket is the EXCEPTION, not the template.** The systemic-seam obligation implied ~10 modules might
each get a `CloneReportReceiver`. The ruling: **only 8-B14 warranted (R)** (it pushes a computed economic value);
the engine harvest loop + the redemption/exit operator surface stay **(K)**, which is exactly the §8.7
"single immutable operator." So we do **NOT** bolt `CloneReportReceiver` onto 8-B5…B10 / OffRamp / DurationFreeze,
and do **NOT** add a `ReceiverTemplate` to the Queue / ExitGate. This **closes the systemic-seam obligation**.

## Consequence — the CRE track splits into two build shapes
- **(R) wasip1 workflows** (report path): **CRE-00** scaffold · **CRE-01** (controller/registry/DefaultCoordinator)
  · **CRE-03** (NAV/LP/APR oracle feeds) · **CRE-04** (warehouse SUPPLY/APPROVE/REPAY via the Roles adapter) ·
  **CRE-05a** (8-B14 bid — DONE).
- **(K) the CRE keeper service** (off-chain Go + go-ethereum, holds the operator/controller/windowController hot
  keys; NOT wasip1): the engine harvest loop, the redemption operator sequencing, `burnFor`, freeze-on-exception.
  A NEW component. Note the §8.7 invariant it must preserve: `operator != owner`, one immutable operator identity.

**Hybrid buy-burn cycle (a consequence to flag — and why it is SAFE):** CRE-05a posts the *bid* via (R) (the
workflow), but the *burn* (`burnFor`, windowController) is a (K) keeper step — the keeper detects the CoW fill
(szipUSD lands in the engine Safe) and calls `burnFor`. The split is **not** a solvency race: `SzipNavOracle`
already **excludes the engine Safe's pre-burn szipUSD from the supply denominator** (`_effectiveSupply() =
totalSupply − balanceOf(engineSafe)`, `SzipNavOracle.sol:608-611`), so a lagging/missed burn cannot dilute or
inflate NAV-per-share — the burn is **housekeeping** (keeps `totalSupply == Loot`, bounds Safe accumulation), not
a price-affecting step. The economic accretion happened at buy-time (USDC out, below-NAV). CRE-05a shipped the
bid; **the fill-detect→burn half is owed to the keeper** (KEEPER-01).

## Keeper trust, liveness & fail-safe (the (K) assumptions, stated not hand-waved)
- **Trust = §13's locked single trusted operator.** The keeper holds the operator/controller/windowController hot
  keys — this is the SAME trusted-operator the protocol is permissioned around end-to-end (§13), and the SAME
  identity §8.7 already names. (K) introduces **no new trust assumption** vs the as-designed system; it is that
  identity's off-chain embodiment. `operator != owner` stays asserted; the Timelock can re-point via `setOperator`
  (§17) if a key is compromised — that is the key-rotation/recovery path.
- **Failure mode = LIVENESS-ONLY, and FAIL-SAFE.** If the keeper is down: the harvest loop stalls (no new yield),
  the bid is not refreshed, redemptions queue — but **nothing moves incorrectly and no funds are lost**. The
  on-chain guards hold independently of the keeper: per-line LTV/caps, `borrowCap`, EVC account-status health, and
  the two `covered()` outflow gates (which **fail CLOSED** — block `postBid`/`removeLiquidity`/`release` when
  undercovered). User-facing paths that do NOT need the keeper still work: Gate deposits, and CoW exits against
  the external book / a still-resting protocol bid. So keeper downtime degrades yield/liveness, never safety.
- **SPOF acknowledged, bounded.** A single off-chain keeper is an operational SPOF for *liveness*; key custody +
  HA are an ops/runbook concern (not a contract change). This is the accepted §13 trade — recorded, not hidden.

## Adversarial review — counters considered (the ruling holds; here is why)
A decision-skeptic pass argued the OTHER side; each strongest counter was checked against the contracts/spec:
- **"creditFreeValue should be (R) — unbounded writes need MORE oversight."** REJECTED as a routing change:
  §4.5.1/§8.7 chose operator-trust specifically to KILL the oracle-manipulation exploit that an attested/report
  free-value credit would re-open (`:474-476`). (R) here is unsafe, not just unhelpful. (The skeptic was right that
  the *original rationale wording* was glib — now corrected to the §4.5.1 reason.)
- **"The bid/burn split is a solvency race."** REBUTTED by `SzipNavOracle._effectiveSupply` excluding the engine
  Safe (`:608-611`) — a lagging burn is housekeeping, not NAV dilution (see above).
- **"Keeper-driven senior redemption is a throttle vector."** MOOT: `ZipRedemptionQueue` is **single-requester,
  treasury-internal plumbing** (the rq Safe only, C4) — a real holder never redeems there; the keeper throttles
  only the protocol's own buyback-funding, not any user exit (`build/wires/9-ZipRedemptionQueue.md`).
- **"Keeper SPOF / no fail-safe stated."** ACCEPTED as a doc gap → the section above now states it (liveness-only,
  fail-safe via the on-chain gates, Timelock `setOperator` recovery).
- **"DurationFreeze trigger undefined."** True, and intentionally so: the lever is DORMANT (premise under review);
  the on-chain `covered()` gate is the fail-closed backstop, so the trigger is not safety-load-bearing. Defining the
  `commit`-on-shortfall trigger is owed to **KEEPER-01**, to be locked with the freeze rebuild.

## Spawned tickets (the plan — author each in its own window)
| Ticket | Scope | Transport | Depends on |
|---|---|---|---|
| **KEEPER-00** | The CRE keeper-service scaffold (Go + go-ethereum; key mgmt; the read→compute→submit spine + shared chain-read helpers; config; NOT wasip1). The foundation for every (K) item. | (K) | — |
| **KEEPER-01** (= rest of CRE-05) | The engine harvest-loop orchestrator (8-B5…B10 + main↔sidecar rotate; regime/split/cap policy) driving the `onlyOperator` entrypoints; **+ the buy-burn fill-detect→`burnFor`** step; **+ freeze-`commit`-on-coverage-shortfall** (the dormant lever, exception-only). | (K) | KEEPER-00 |
| **CRE-02** | Redemption-settle: warehouse REDEEM/REPAY via **(R)** (shares the CRE-04 warehouse-op package) **+** `OffRampModule.requestRedeem/claim` and `ZipRedemptionQueue.settleEpoch/claim` via **(K)** the keeper; event-driven off `RedemptionSettled`. (Existing scope `build/tickets/cre/CRE-02-redemption-settle.md` — confirm the (R)/(K) split per this ruling.) | (R)+(K) | KEEPER-00, CRE-04 |
| **CRE-00 / CRE-01 / CRE-03 / CRE-04** | Unchanged — all pure **(R)** workflows through the EXISTING report receivers; not blocked by this seam. | (R) | CRE-00 |

## Done when (this decision window)
- The ruling is recorded in `claude-zipcode.md` §8.7 (the authoritative intent) + `PROGRESS.md` (the systemic-seam
  obligation marked RESOLVED; the CRE backlog updated with the (R)/(K) split + the KEEPER-00/01 rows).
- No code (this is a decision). The spawned tickets are listed, not yet authored.
- A spec-fidelity pass confirms the ruling honors §8.7 (operator-TRUSTED, `operator != owner`) + §17 and reopens
  no locked decision.
