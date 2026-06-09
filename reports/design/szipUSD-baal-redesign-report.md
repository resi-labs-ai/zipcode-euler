# szipUSD redesign — Baal/Zodiac NAV vault + withhold money model (report to the superintendent)

**From:** builder window (this session). **To:** the superintendent. **Item:** 8 — `szipUSD`.
**Outcome:** item 8 **REOPENED + redesigned**; the prior WOOF-07/INFLOW-08 were **deleted as the wrong vault**;
the money model was rewritten across `claude-zipcode.md`; item 8 decomposed into an ordered ticket backlog.
**Date:** 2026-06-06. **Verdict requested:** ratify the substrate decision + the withhold/three-lever money
model; confirm the decomposition + the 8-S spec-edit sequence; release 8-S3 (`audit/1` re-derivation).

## TL;DR
- The 2026-06-05 `WOOF-07` (+ `INFLOW-08` + its report) built szipUSD as **the wrong vault** — an ERC-4626
  *convert-on-stake* vault over **EulerEarn loan-book pool shares**. The user caught it. **All three were
  deleted.**
- szipUSD is the **auto-sodomizer junior NAV vault** (`pending-docs/auto-sodomizer.md` + `hydrex.md`): pools
  **zipUSD**, accrues **xALPHA**, holds + **gauge-farms** a zipUSD/xALPHA **ICHI LP** on Hydrex (oHYDX →
  exercise → HYDX → USDC → recycle), tracks **NAV**, bears **residual first-loss**, CRE-operated, ~30-day lock.
- **Substrate decided = Baal (Moloch v3) + Zodiac** (user-reversed an interim 7540 lean). Share = **Loot**;
  treasury = a **Gnosis Safe** basket; exit = **ragequit** (in-kind); NAV = multi-oracle **display-only**; **LOCK
  + FREEZE** gates; first-loss = **WITHHOLD, not markdown**.
- The **money model was rewritten** (§2/§4.5/§4.6/§6.4/§11/§12/§17/§3 primitive rows) to the withhold model,
  with the **permanent-loss realization** pinned (three levers).
- Item 8 **decomposed** into an ordered backlog: **3 spec edits (8-S1/2/3)** then **12 build tickets (8-B1…12)**.
  8-S1 (§17) + 8-S2 (§12 + sweep) are **DONE**; **8-S3 (`audit/1` re-derivation) is NEXT** (see `s3.md`).

## Root cause (why the wrong vault got built)
The 2026-06-05 supply-side redesign changed the *framing* (xALPHA subsidy, protocol-privatized yield) but
**left the convert-on-stake / EulerEarn-pool-share substrate in §4.5/§11/§17 + `audit/1`** intact, deferring the
reconciliation *"to when item 8 is authored."* The item-8 builder (me) **dropped that deferral** and implemented
the stale substrate. Lesson logged to memory: **do the reconciliation; never build on an un-reconciled deferral.**

## The substrate decision (ratify)
Two comparison agents (in the plan) scored **7540 33/50 vs Baal+Zodiac 29/50** — but 7540's win rested entirely
on **single-asset zipUSD exit + 4626 composability**, which the user explicitly does **not** need. Stripping
those, **Baal wins** the load-bearing rows: native multi-asset Safe custody, **oracle-free ragequit
loss-socialization**, and **programmable shaman/Zodiac control** for the CRE robot. Build posture: Baal is
0.8.7 → **summon a live DAO + Safe on a Base fork and drive it** (same posture as the Hydrex stack). Baal +
Zodiac are cloned into `reference/`.

## The money model (ratify — this is the core)
- **Two NAVs.** Senior solvency `NAV/zipUSD ≥ 1` (cash + marked loans) is **unchanged**. The **junior basket
  NAV** (zipUSD + xALPHA + ICHI LP in the Safe) is **multi-oracle, display-only** — not in the ragequit exit
  path. Ragequit = `(holder Loot / total Loot) × basket`, value-preserving.
- **First-loss = WITHHOLD, not markdown (the keystone).** The at-risk asset is the **lent-out USDC**, not the
  junior's zipUSD — clawing zipUSD recovers nothing. During a duration hole the **FREEZE withholds** a pro-rata
  at-risk slice from ragequit (`atRiskAmount / basketNAV`); the withheld backing **stays in place and keeps
  earning** while **time + the recovery waterfall** (secondary → insurance → xALPHA bond → HYDX-vamped USDC)
  bring **external** USDC to repay the loan. On recovery the freeze releases, junior whole + xALPHA premium.
- **Permanent-loss realization (resolved 2026-06-06; the piece `audit/1` needed).** At a **confirmed permanent**
  shortfall, realize the loss on the **junior's own basket**, three levers until the hole is filled: **(1)
  sequester + burn the frozen junior zipUSD** (cuts supply → restores senior backing); **(2) sell the junior's
  accrued yield → USDC → repay**; **(3) sell the junior's xALPHA → USDC → repay**. Each **fills the hole + lifts
  the freeze**; the basket shrinks → ragequit slices shrink. The junior's zipUSD is touched **only** here, never
  during the duration window.
- **Yield = the junior's pay.** The auto-sodomizer vamps net-new USDC out of the HYDX/USDC pool → the basket
  compounds → that compensates the junior for duration risk ("frozen but earning") and is waterfall leg (e).
  **Bounded** (TVL-capped, front-loaded, ~6-month degrading per `hydrex.md`).

## The decomposition (confirm the sequence)
Item 8 is now an ordered backlog in `tickets/PROGRESS.md` (build one at a time, each on the last):
- **Phase 8-S — spec EDITS (NOT tickets; foundation):** `8-S1 §17` ✅ DONE · `8-S2 §12 + residual sweep` ✅ DONE
  · **`8-S3 audit/1 re-derivation` — NEXT** (see `s3.md`).
- **Phase 8-B — build TICKETS (Baal+Zodiac, fork-tested, `tickets/sodo/`):** `8-B1 Baal+Safe+Loot scaffold` →
  `8-B2 deposit/mint shaman + TVL cap` → `8-B3 lock/freeze shaman` → `8-B4 NAV+APR oracle` → `8-B5 reservoir +
  borrow` → `8-B6 LP module` → `8-B7 harvest/vote` → `8-B8 exercise/strike` → `8-B9 range-sell` → `8-B10
  recycle/payout` → `8-B11 CRE robot` → `8-B12 dashboard`. (The §4.5 strategy-module inventory is the source.)

## Authoritative-doc edits this session
- **`claude-zipcode.md`:** §4.5 (SUPERSEDED guardrail at the top of the szipUSD bullet + the auto-sodomizer
  engine bullet replaced with the **8-module Zodiac strategy inventory**); §11 (keystone → withhold; Default-flow
  steps; both triggers; resolved-block points 3+5; the **permanent-loss three-lever block**); §4.6 (both
  loss-side contracts → `LienXAlphaEscrow` = xALPHA bond only, `DefaultCoordinator` drives the freeze + the
  three-lever resolution); §17 (4 locked junior decisions flipped to Baal); §12 (two NAVs; withhold defense;
  metrics); §6.4 (ragequit + lock + freeze); §2 (token-table cell + "Junior accounting unit" para); §3
  (reused-primitive rows → Baal `ragequit` + lock/freeze shamans).
- **`tickets/PROGRESS.md`:** item-8 row REOPENED; the full 8-S/8-B decomposition; session-log entry; obligation
  notes. **`tickets/LEDGER.md`:** WOOF-07 digest marked DELETED. **Plan file** + this report.
- **Deleted:** `tickets/woof/WOOF-07-szipusd-vault.md`, `tickets/inflow/INFLOW-08-szipusd-position.md`,
  `reports/WOOF-07-report.md`. **`contracts/`** = skeleton (no build this session).

## Judgment calls (rule on these)
1. **Baal+Zodiac over 7540** — user-decided after a fair eval; the agents favored 7540 only on criteria the user
   doesn't need. Accepted.
2. **Held the money-model rewrite as ordered spec edits (8-S1/2/3), not one blob** — and did NOT do `audit/1`
   (8-S3) at the tail of a long session (it's a full proof-harness re-derivation). Recommend it gets its own
   window via `s3.md`.
3. **`audit/2.md`/`3-results.md` NOT yet swept** for the Baal model — they still carry the old szipUSD
   stake/unstake/cooldown acceptance steps (L1/L3/L6/L12/N3/N4, S7/S8). These are M1-supply acceptance; they
   re-align when the 8-B tickets are authored (flagged, not lost).
4. **Residuals (guardrail-covered, cosmetic):** the stale convert-on-stake block at §4.5 `:566-607` (delete when
   8-B1 is authored) + one "unstake→AMM dump" noun at §11 `:1181`.

## Standing concern for the superintendent
The **money model is now complete and internally consistent** in §11/§12/§17/§4.5/§4.6 — but `audit/1-results.md`
**still encodes the old `J×p`/`Burn=loss/p`/escrow proof** end to end. Until **8-S3** lands, `audit/1` is the
one place that contradicts the current spec. It is the gating spec-edit before any 8-B build ticket. `s3.md` is
the focused prompt for it.

## Status & NEXT
8-S1 ✅, 8-S2 ✅. **NEXT = 8-S3 (`audit/1` re-derivation)** — fresh focused window, prompt in `s3.md`. Then the
8-B build tickets, one at a time through the harness (fork-tested against live Base).
