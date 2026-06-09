# tickets/PHASE2.md — the post-M1 authoring extension

**Status: DORMANT.** This file is the backlog for the tracks that come AFTER the M1 on-chain spine
(the WOOF contracts + the item-8 Baal vault + deploy/wiring). `tickets/PROGRESS.md` remains the single
source of "what's NEXT"; the M1 spine is the only active work. PHASE2 activates at the **re-scoping
checkpoint** (bottom) once `WOOF-10` (deploy/wiring) is filed.

The numbers/stubs here are an **estimate to be re-derived at the checkpoint**, not a commitment.

> **Scope note (current as of 2026-06-07).** Everything that has since been absorbed into the M1 spine or
> resolved in the spec has been **removed** from this file. For the record, the following are no longer
> PHASE2 work and are tracked in `tickets/PROGRESS.md`:
> - the **item-8 szipUSD Baal vault** (substrate 8-Bw/8-B1/`SzipNavOracle`/Exit Gate + engine 8-B5…8-B14) —
>   the old `WOOF-08`/`INFLOW-08` and the separate `sdVAULT` track collapsed into it; the yield-engine spec
>   pull (`spec-clear-8SY`) is **DONE**;
> - the **xALPHA bridge** (`8x`) — pulled into M1, builds against a stand-in token (`tickets/bridge/8x-01-szalpha-wrapper-cct.md`);
> - `WOOF-09` (`ZipRedemptionQueue`) and `WOOF-10` (deploy/wiring) — M1 spine, tracked in PROGRESS;
> - the superseded `ISzipUSD` 3-arg-`stake`/F4 obligation (the seam is now the Exit Gate's `depositFor`).

---

## Why this exists

The WOOF/Baal (Solidity) track is authored to a high bar through the harness
(`audit/adversarial-spec/README.md`): draft → fan critics → triage → **build-to-zero-guess + keep** →
file → superintendent review, with composable integrity held by the cross-ticket **obligations table**
(`PROGRESS.md`) + the **LEDGER digest**. The remaining tracks can't inherit that rigor as-is:

1. **The zero-guess gate is Solidity-specific** (`forge build`/`forge test`). The non-Solidity tracks need
   a defined **cold-build equivalent** — `audit/adversarial-spec/track-gates.md`.
2. **Track maturity is uneven** — CRE is high-fidelity but Proof-gated; subnet is sketch-level; subgraph is
   locked-but-needs-formulas; treasury is decision-gated.
3. **Cross-track seams** owed by the done on-chain work to the not-yet-authored tracks (the obligations below).

**Locked operating decisions (2026-06-05, with the user):**
- **Decision-resolving items FIRST** for off-chain-blocked tracks (CRE/subnet/treasury).
- **Author nothing in these tracks until the re-scoping checkpoint** re-derives this backlog against the
  then-current spec.

---

## Track taxonomy (remaining tracks only)

| Track | Stack | Design lives in | Maturity | Gate |
|---|---|---|---|---|
| CRE workflows | Go→wasip1 | `claude-zipcode.md` §8 (+ `tickets/bridge/8x-02-xalpha-apr-cre.md`) | **Producer spec DONE 2026-06-09** (§8.0–§8.11) | **DEC-01 RESOLVED** (two-layer model); build on mock + swap real feeds — live real-collateral origination needs §6.2/§6.3 + vendors |
| Subnet | Bittensor (Py/Rust) | `claude-zipcode.md` §7, §8.5 | **Sketch** | Proof API + zk-verify choice (DEC-01) |
| Inflow (frontend) | Nuxt/Vue/viem | `§5/§6/§12/§15`; owned by **`superintendent-allaprima.md`** → `tickets/frontend/` (own ledger) | Sketch sweep runs now; renderer gated on item-10 | item-10 deploy (addresses/ABIs) for the renderer half |
| Subgraph | TS/AssemblyScript | §9 (events) + §12 (metrics) | Locked, needs formulas | final on-chain event ABIs |
| Treasury (economics) | — (decision doc) | **doc removed 2026-06-09 — re-author post-M1** | Strategy locked, ops-gated | GTV pairing (DEC-03) **RESOLVED → xALPHA/zipUSD** |
| M2 loss | Solidity | `reports/design/baal-spec.md §9` + §4.6 / §11 | Redesigned sketch (provision-that-recovers + foreclosure Proof oracles); `LienXAlphaEscrow` custody **pulled forward to M1-adjacent `8-Bx`** (PROGRESS) | Proof attestations (DEC-01) |

---

## Decision-resolving items — these gate everything below (some are user/legal, not cold-buildable)

- **`DEC-01` Proof-capability — RESOLVED 2026-06-09 (two-layer model).** A notarization attests instrument
  genuineness/identity/integrity, NOT the truth of contents → **facts** come from authoritative feeds (county
  recorder/title = existence + anti-fabrication, appraiser = value, carrier = insurance, Erebor = recovery) and
  **Proof** seals the SPV instrument as genuine + ours, all on the same CRE identical-consensus path (DON hashes
  the sealed artifact on-node + verifies cert). **NOT a blocker** — CRE/subnet/M2-loss build on mock + swap real
  feeds in. Residual (their own risks): insurance product (§6.2), legal (§6.3), pinning feed/SPV vendors.
  `spv-lien-proof.md` §6.1 + `reports/design/baal-spec.md §9.4`.
- **`DEC-02` canonical-vs-fork + CCT-registration** on chain 964. **RESOLVED 2026-06-09.** Fork decided (self-built
  `szALPHA` on our own validator); CCT registration on 964 confirmed **open/self-serve** — full TokenAdminRegistry +
  RegistryModuleOwnerCustom + TokenPoolFactory stack is deployed and GTV's own xSN* xAlpha tokens are already registered
  CCTs with a live Base lane (addresses in `tickets/bridge/8x-01-szalpha-wrapper-cct.md`). The bridge's real lane is now build-only.
- **`DEC-03` GTV pairing terms** — **RESOLVED 2026-06-09**: Hydrex confirmed the LP pair is **xALPHA / zipUSD**
  (the stable unit; USDC not mandated). Confirms the spec's existing `zipUSD/xALPHA` gauged pool (`claude-zipcode.md §4.5`,
  `pending-docs/hydrex.md`); the only stale artifact was the "xALPHA/szipUSD closed loop" memory phrasing. Treasury
  rationale (POL incentives) re-authors post-M1.
→ **~3 scoping items**

---

## Enumerated backlog (named stubs — re-derive at the checkpoint)

Each stub is a placeholder to be promoted to a real ticket via the harness + the per-track gate in
`track-gates.md`. A track is not authorable until its gate clears.

### CRE — off-chain robot (**§8 spec gate CLEARED + DEC-01 RESOLVED 2026-06-09**; live real-collateral origination needs §6.2/§6.3 + vendors)
The CRE §8 spec-pull window (2026-06-09) raised §8 to the producer level (`claude-zipcode.md §8.0…§8.11`; `reports/design/CRE-spec-report.md`; the `spec-clear-CRE.md` plan was consumed + deleted).
Stubs updated to the §8.0 surface + the two new tracks:
- `CRE-00` project/secrets scaffold (§8 intro / scaffolding note)
- `CRE-01` origination / draw / close / status → controller + revaluation (sharded) → registry + default/recovery → `DefaultCoordinator` (§8.1/§8.4) — **DEC-01 RESOLVED (two-layer model, §8.9)**; builds on mock Proof+feeds, swaps real endpoints in; live real-collateral origination needs §6.2/§6.3 + vendors
- `CRE-02` redemption-settle `cron` + warehouse REDEEM funding call (§8.3/§8.5)
- `CRE-03` szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle`, `LP_MARK`(7)→`SzipReservoirLpOracle` — + xALPHA-APR feed (§8.6/§8.8)
- `CRE-04` (new) senior-warehouse SUPPLY/APPROVE/REPAY via the Roles adapter (§8.5) — **must reconcile the 8-Bw `WarehouseAdminModule` decode before finalizing**
- `CRE-05` (new) engine strategy-admin **operator** orchestrator (§8.7 — the operator path, drives 8-B5…8-B10 `onlyOperator` + main↔sidecar rotation)
→ **~6** (the §8 producer gate is cleared + DEC-01 model resolved; CRE-01's *live real-collateral* origination waits on §6.2/§6.3 + feed vendors, CRE-04 on the 8-Bw build)

### Subnet — Bittensor (gated: DEC-01; sketch-level, no spec pull scheduled)
- `SUBNET-01` validator/miner container scaffold (§7)
- `SUBNET-02` Proof-family fetch + zk-verify (§8.5)
- `SUBNET-03` DON→CRE Shape-B integration (§7/§13)
→ **~3** (the least-mature track — needs a spec pull of its own before tickets)

### Inflow — frontend (the dedicated **alla-prima sketch sweep**, NOT this ledger)
The frontend is owned by `superintendent-allaprima.md` (a separate role): it paints the supply/zap/position/exit UI
over `reference/euler-lite`, files in **`tickets/frontend/`**, keeps its own **`tickets/frontend/PROGRESS-frontend.md`**,
and is **READ-ONLY on this file + `PROGRESS.md`**. The sketch half runs now (the user-facing contracts are built); the
renderer half is gated on item-10 deploy (addresses/ABIs). `INFLOW-06` was the model. The stubs below are that role's
candidate worklist — it derives/confirms them from the built contracts, they are not authored from here:
- `INFLOW-07` originator onboarding (§15)
- `INFLOW-09` redemption-queue view (§6.1)
- `INFLOW-12` solvency dashboard (§12)
→ **~3** (owned by `superintendent-allaprima.md` → `tickets/frontend/`)

### Subgraph (gated on final event ABIs)
- `GRAPH-01` event indexing (§9)
- `GRAPH-02` §12 dashboard-metric derivation (NAV / APR / utilization / insurance formulas)
→ **2**

### M2 loss machinery (deferred; gated: DEC-01 foreclosure Proof oracles)
- `M2-01` `LienXAlphaEscrow` — **PULLED FORWARD to M1-adjacent `8-Bx` (PROGRESS row, 2026-06-08).** The **custody half**
  (`lockXAlpha` at launch / `releaseXAlpha` on repay) is M1; the **slash half** (`slashXAlphaToCapital` /
  `slashXAlphaToCohort` → routes into the sidecar) is built + mock-tested with 8-Bx and goes live with the M2 default
  flow. So this stub is now **tracked as `8-Bx` in `PROGRESS.md`**, not authored from here — kept listed only for the
  M2 slash-flow integration.
- `M2-02` `DefaultCoordinator` (bounded conservative-provision writer → recovery true-up; sole NAV-markdown writer)
- `M2-03` systemic duration-squeeze freeze (Duration-Bond trigger B)
→ **~2 net new** (M2-01 custody is `8-Bx`; `reports/design/baal-spec.md §9` is the redesigned source — provision-that-recovers,
NOT withhold/markdown; the `.sol` stubs on disk under `contracts/src/loss/` are scaffold placeholders, not built)

### Designer
- euler-lite branded fork — setup task, not a cold-build ticket → **0–1**

**Estimated total: ~15 tickets** across the remaining tracks, plus the ~3 DEC items that resolve gates
rather than ship code. Treasury *economics* stays a decision (its `treasury.md` doc was removed 2026-06-09 — re-author post-M1).

---

## Cross-track obligations (live seams owed by done on-chain work to not-yet-authored tracks)

Authoritative status stays in `PROGRESS.md`; this is the cross-track view. (M1-spine deploy/wiring
obligations live in `PROGRESS.md`, not here.)

| Obligation | From | Discharged by | Status |
|---|---|---|---|
| Report ABI `abi.encode(uint8 reportType, bytes payload)` per §4.4 table (1/2/4/5/6→controller, 3→registry) | WOOF-05 | `CRE-01` | **DISCHARGED-IN-SPEC** (CRE §8.0 per-`(receiver,reportType)` table, 2026-06-09; build = CRE-01) |
| Revaluation report sharded by gas-bounded batch count, no malformed/dup entry (atomic batch) | WOOF-02 | `CRE-01` | **DISCHARGED-IN-SPEC** (CRE §8.1 sharding rule, 2026-06-09; build = CRE-01) |

No stub may reopen a locked §17 decision (event-driven Proof, fresh-per-line borrower model, yield-routing =
protocol's, the zipUSD/szipUSD/xALPHA token model, venue-agnosticism, immutable-Forwarder-via-renounce, and the
2026-06-07 Baal authority model: team-multisig Safe-signer admin + CRE-operator module, zero Shares). The
checkpoint re-verifies this against the then-current §17.

---

## The re-scoping checkpoint (the flexibility gate)

Run by the **superintendent**, **once**, when `WOOF-10` (deploy) is filed — **before any non-WOOF builder
window opens**:

1. **Re-read** the then-current `claude-zipcode.md` §17 + `tickets/LEDGER.md` + the cross-track obligations
   (above + `PROGRESS.md`).
2. **Consistency sweep over the whole backlog** — confirm each stub still matches the spec; no locked decision
   drifted under it. Drop/merge/split stubs the spec has moved past.
3. **Per blocked track:** promote its design doc to ticket-fidelity, **or** hold it behind its decision-resolving
   item (DEC-01/02/03). A track is not authorable until its gate clears.
4. **Re-confirm count + priority with the user**, then release the first non-WOOF window via `track-gates.md`.

Nothing past the M1 spine is authored against today's spec — it is re-derived against the spec as it stands
when the spine is done.
