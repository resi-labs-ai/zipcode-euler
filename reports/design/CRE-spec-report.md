# CRE §8 spec pull (the off-chain robot) → producer-grade §8

**From:** spec-edit window (this session). **To:** the superintendent. **Item:** §8 — CRE workflows.
**Outcome:** `claude-zipcode.md §8` rewritten from a redesign-stale narrative into a **producer spec** where
**every on-chain report surface the built contracts consume has a defined off-chain producer**, and the
**CRE-00…CRE-05** build tickets are authorable. Spec-edit only — **`claude-zipcode.md` §8 + tickets/PROGRESS
+ tickets/PHASE2 touched; no `contracts/`, no cold-build.** **Date:** 2026-06-09.
**Verdict requested:** ratify §8.0…§8.11; note the two residual gates (DEC-01 for live CRE-01; 8-Bw reconcile
for CRE-04).

## What this was
A SPEC-EDIT window (like Phase 8-S / 8-SY): no `tickets/`, no `contracts/`, no critic fan-out. §8 predated the
Baal szipUSD + the `CreditWarehouse`, so it described producers for a report surface that has since changed
(the engine on-chain contracts are DONE, 401/401 green, on `snapshot/recycle-rework`). This window matched
every settled on-chain consumer to a producer and discharged the logged CRE-track obligations.

## The decisive structural finding (the thing §8 was missing)
CRE touches chain in **two trust modes**, and the old §8 only described one:
1. **The report path** — `f+1`-DON-signed reports through the immutable KeystoneForwarder → `ReceiverTemplate.onReport`.
2. **The operator path** — the **single immutable CRE operator** calling the engine modules' `onlyOperator`
   (`msg.sender == operator`) entrypoints directly (8-B5…8-B10). **Not** a DON-signed report; operator-TRUSTED
   (`RecycleModule.creditFreeValue` is unbounded) — which is exactly what makes the revolving reservoir borrow
   safe (kills the external-oracle-manipulation exploit). Verified in the built modules:
   `LpStrategyModule.sol:36/100`, `RecycleModule.sol:60/115`; design root `reports/design/baal-spec.md 8-B11`,
   `auto-sodomizer.md §8` inv. 1.
§8.0 / §8.7 now name both paths and route every workflow into one of them.

## What was authored (new + reworked subsections)
- **§8.0** — the report envelope + **per-`(receiver, reportType)` producer table** (the WOOF-05 discharge). Key
  ratification: `reportType` is **scoped per receiver** (each `WriteReport` names one `Receiver`), so
  `SzipNavOracle.NAV_LEG == 7` and `SzipReservoirLpOracle.LP_MARK == 7` are the **same numeral on two receivers
  and never collide**. `LP_MARK = 7` stands (`SzipReservoirLpOracle.sol:27`), distinct from `REVALUATION = 3`
  (`ZipcodeOracleRegistry.sol:24`) as the 8-B5 obligation required — no contract change.
- **§8.1** — added the **gas-bounded revaluation sharding rule** (the WOOF-02 discharge): shard to a
  `MAX_LIENS_PER_REPORT` constant; one `WriteReport` per shard (each independently atomic per
  `ZipcodeOracleRegistry.sol:93-111`); dedup across the full sweep (on-chain is last-write-wins) + equal-length
  enforced pre-encode.
- **§8.3** — redemption cron now funds the queue via the warehouse **REDEEM** op when pool USDC is short.
- **§8.5** (new) — **senior-warehouse ops** (SUPPLY/APPROVE/REDEEM/REPAY) through the Zodiac Roles adapter:
  the producer sizes the scalars, the owner-applied policy pins identities; `Roles.execTransactionWithRole`
  (`Roles.sol:153`). **Explicitly flagged: not yet final** — the 8-Bw `WarehouseAdminModule` is not built
  (dir empty), so CRE-04 must reconcile the opType bytes / envelope nesting / open EulerEarn-`redeem`-arg-order
  + APPROVE choices against `reports/8-Bw-report.md` when it lands.
- **§8.6** (new) — the **push-cache producers**: `NAV_LEG`(7)→`SzipNavOracle` (`legs ∈ {ALPHA_USD=0, HYDX_USD=1}`,
  with the on-chain deviation circuit-break and `fresh()` issuance guard the producer must respect) and
  `LP_MARK`(7)→`SzipReservoirLpOracle` (single-key, fail-closed; producer obligation is liveness only). Both
  from one reserve×price computation so the two feeds stay coherent.
- **§8.7** (new) — the **engine operator path** (8-B11): the per-epoch loop (claim/vote → strike → recycle →
  re-LP → rotate), each leg an `onlyOperator` scalar call; the operator-trusted boundary stated.
- **§8.8** (new) — the xALPHA-APR feed (trailing-realized; reuses the §8.6 shape).
- **§8.9** (new) — **DEC-01 surfaced** as the one external blocker on a *live* origination build (CRE-01 builds
  against mock Proof until Proof exposes a per-lien attestation API). Flagged, not resolved (capability decision).
- **§8.11** (new) — the CRE-00…CRE-05 build-ticket map; **CRE-04 (warehouse ops)** and **CRE-05 (engine
  operator)** added beyond PHASE2's CRE-00…03.
- **§8.10** — the former §8.5 proof layer, renumbered; six stale `§8.5`-means-proof-layer cross-refs retargeted
  to §8.10 (lines 146/259/438/1385 + the two §8.1/§8.9 refs).

## Honesty / method constraints honored
- **Matched the locked consumer ABIs, invented no mechanism.** Every payload in §8.0 is copied from the built
  decoder (`ZipcodeController` §4.4 types 1/2/4/5/6; `ZipcodeOracleRegistry.sol:93`; `SzipNavOracle.sol:201`;
  `SzipReservoirLpOracle.sol:72`; §4.5 warehouse op-set).
- **§17 not reopened** — event-driven Proof / immutable Forwarder via renounce / single immutable engine
  operator / the token model are referenced, not redesigned.
- **Did not over-spec the unsettled surface.** The warehouse envelope is specced from the settled §4.5 op-set
  but explicitly marked "reconcile against the 8-Bw build before CRE-04 finalizes," per the handoff.

## Obligations discharged
| Obligation | Where | Status |
|---|---|---|
| WOOF-05 report-ABI envelope per-type table | §8.0 | DISCHARGED-IN-SPEC (build = CRE-01) |
| WOOF-02 gas-bounded revaluation sharding | §8.1 | DISCHARGED-IN-SPEC (build = CRE-01) |
| LP_MARK reportType registration (8-B5) | §8.0/§8.6 | DISCHARGED (ratified per-receiver) |
| 8-B10 `creditFreeValue` net arithmetic owner (§8) | §8.7 | DISCHARGED-IN-SPEC (build = CRE-05) |

## Residual gates (not resolved here — by design)
- **DEC-01** (Proof per-lien attestation capability) gates a *live* CRE-01 origination build (§8.9).
- **8-Bw `WarehouseAdminModule`** must land before **CRE-04** finalizes its decode (§8.5).

## Conclude
§8 is at producer-spec level. PROGRESS: §8-spec row → DONE; the four CRE-track obligation rows discharged-in-spec.
PHASE2: cross-track obligation rows discharged; CRE stubs updated to the §8.0 surface (+ CRE-04, CRE-05); the
§8 producer gate is cleared. STOP.
