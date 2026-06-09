# 8-Bx — `LienXAlphaEscrow` — builder window report (to the superintendent)

**Status: DONE — BUILT-VERIFIED + KEPT. 44/44 contract tests, 512/512 total (468 baseline + 44), no regression
(`forge test`, independently re-run). Code on disk, NOT git-committed (your call, per item-9 precedent).**

## TL;DR
Authored + cold-built `LienXAlphaEscrow` (§4.6/§11/§2) — the per-lien xALPHA first-loss bond vault, the loss-side
sibling of item 9. A standalone, fully-immutable, non-sweepable custody contract: lock the bond at launch, return it
on repayment, and on default route it in two ordered jobs (sell-to-cover the capital hole → `capitalSink`; in-kind
premium remainder → `sidecar`). The custody half (`lock`/`release`) is M1-live; the slash half is built + mock-tested
now and goes live with the M2 `DefaultCoordinator`. Full harness run (5 critics). **One spec gap fixed first** (§4.6
stale cohort-distributor language). **Zero load-bearing guesses** at cold-build.

## What the window did
- Verified the three `reference/moneymarket-contracts` "Model from" sources by inspection: `InsuranceFund.bring:33`
  (the immutable-caller + gated-`safeTransfer` custody model — replicated clean-room over OZ), `MarkdownController
  .slashJaneProportional:146` (a proportional-slash concept template — **rejected**, our split is coordinator-passed),
  `jane/RewardsDistributor:131/:141` (a Merkle pull-claim distributor — **not built**).
- Drafted `tickets/loss/8-Bx-lien-xalpha-escrow.md` (build-only; no INFLOW — internal plumbing).
- 5-critic fanout (junior / spec-fidelity / ref-verifier / qa / security — foundational loss-side custody warranted
  the full panel). Spec-fidelity verdict **FAITHFUL**; ref-verifier confirmed all 5 sources resolve; security found
  **no CRITICAL/HIGH** (the theft-immunity thesis verified).
- Triaged: **1 spec gap → fixed `claude-zipcode.md §4.6` FIRST**; the rest folded into the ticket.
- Cold-built (fresh subagent, ticket-only, zero-guess gate) → independently re-ran green.

## Design decisions to sanity-check (your eyes)
1. **Single immutable `coordinator` gates all four entrypoints** (lock+release+both slashes), rather than split
   launch-poster vs slash-driver roles. Security critic's verdict: acceptable for M1 — a compromised coordinator
   **cannot steal** (no recipient param; funds only reach {originator, capitalSink, sidecar}), only **grief**
   (premature release / slash-healthy), which is the coordinator's §13 trust boundary. The M1-live surface is only
   lock/release; slash goes live with the M2 CRE-Forwarder-gated `DefaultCoordinator`. **No split role for M1.** OK?
2. **The cohort premium = a single `safeTransfer` to the sidecar Safe** (NAV does the pro-rata), NOT a per-holder
   snapshot/Merkle distributor. This is the §4.6 spec fix (see below) — the simplest mechanism faithful to §11/§6.4's
   socialized-sidecar model. This is the one substantive design call; it hinges on `SzipNavOracle` valuing the
   sidecar's xALPHA leg (recorded as an obligation).
3. **`lienId` keyed as `bytes32`** (not `uint256`) to match the canonical controller/factory/venue/CRE-report type —
   security critic catch; verified against `ZipcodeController`/`IZipcodeVenue`/`LienTokenFactory` + §8.0.
4. **Mandatory `nonReentrant` + CEI both** (not CEI-only). The contract is token-agnostic (item-10 swaps the
   production xALPHA in), so the guard is belt-and-suspenders against a future hooked token — mirrors
   `ZipRedemptionQueue is ReentrancyGuard`. Adds no admin surface.
5. **Non-sweepable, no recovery path** — a never-resolved bond is permanently stuck. Security critic argued both ways
   and landed on **keep non-sweepable** (a sweep is a 4th privileged path over the first-loss bond); the mitigation is
   the **terminal-call operational invariant** (the coordinator must always release-or-slash every locked lien; don't
   lock against a decommissionable coordinator). Recorded as an item-10/M2 obligation. OK to keep non-sweepable?

## Holes surfaced → resolution
- **SPEC GAP (fixed first) — `claude-zipcode.md §4.6` cohort distributor.** The line "the in-kind pro-rata cohort
  distributor (snapshot → per-holder xALPHA share) is net-new (`RewardsDistributor`-style)" was **stale M2-sketch
  language that contradicted §11/§6.4** ("no per-position index, no SBT"; `HaircutLockAccountant`/`RecoveryClaimSBT`
  not built). Spec-fidelity confirmed the contradiction is real. **Replaced** with: the coordinator computes the
  split off-chain + the escrow routes; the premium is delivered by routing the remaining bond into the sidecar Safe,
  the socialized pro-rata automatic via NAV — no snapshot/index/SBT. (Faithful reconciliation of §4.6 with the locked
  §11/§6.4 model, not a mechanism change.)
- **Reentrancy probe was self-contradictory as drafted** (junior #8): all entrypoints are `onlyCoordinator`, so a
  plain-token callback reverts `NotCoordinator` before reaching the CEI defense → the probe would pass for the wrong
  reason. **Fixed** by setting `coordinator == the reentrant token` in the probe so it actually exercises the guard
  (`ReentrancyGuardReentrantCall`).
- **QA test-matrix gaps** folded: pure-premium path (lock→slashToCohort with no capital slash), exact-equality
  boundary (`amount==bond` passes, `==bond+1` → `ExceedsBond`), multi-lien independence, re-lock reusability,
  failed-pull-leaves-no-orphan, coordinator-approval/balance negatives, `expectEmit` mandates, no-sweep ABI-negative,
  and the fund-flow invariant reframed to mechanically-checkable balance-conservation (a stateful `invariant_`
  handler — 128k calls, 0 reverts).
- **Self-lock footgun** (security #6): added `require(originator != address(this))` (`SelfOriginator`).

## Authoritative-doc edits
- `claude-zipcode.md` **§4.6** — the cohort-distributor paragraph (the only spec edit; reconciliation, see above).
- `tickets/PROGRESS.md` — 8-Bx row → DONE; NEXT banner; **3 new cross-ticket obligations** (item-10 wiring +
  feeless/approval asserts + terminal-call; `DefaultCoordinator` slash split-policy; `SzipNavOracle` sidecar-xALPHA
  valuation); session-log line.
- `tickets/LEDGER.md` — `LienXAlphaEscrow` digest (BUILT-VERIFIED) + split out the `DefaultCoordinator` digest.
- No `audit/2.md` / `audit/3-results.md` edit: the §4.6 fix changed no mechanism the acceptance harness references
  (the slash/recovery trace is M2 and not yet authored into the harness — it folds into the item-10/M2 sweep).

## Judgment calls
- **No re-fan after the revisions.** The folded changes (`bytes32` key, mandatory `nonReentrant`, `SelfOriginator`,
  the probe fix, the QA additions) were **all directly critic-recommended** — convergent hardening of already-intended
  surface, not new invention — and the cold-build (fresh subagent, zero-guess) is the proof. Consistent with how the
  8-B5/8-B9 windows folded critic + build-exposed fixes without re-fanning (README §3a).
- **No fork test, nothing to chain-verify.** This contract has no external interface signatures and no hardcoded
  addresses — it is pure custody over a generic ERC-20. The production bridged xALPHA (8x-01 `SzAlphaMirror`) is not
  yet live on Base, so a fork test has nothing real to hit; mocks fully exercise the logic. (The keep-the-build
  chain-verification mandate is satisfied vacuously — there is no live interface/address in this contract.)
- **Left uncommitted** for your review + commit, matching the item-9 precedent (the prior window left code on disk
  and you committed it after review — `f188b84`).

## NEXT (you pick the order)
- `8x-01` szALPHA bridge — cold-build (ticket ready, build-ready, the only external-source compile).
- `8x-02` xALPHA-APR CRE — after 8x-01 (depends on `IXAlphaRate`).
- item 10 — deploy/wiring (best once the on-chain spine + bridge are built; it discharges the long obligation list).
- `DefaultCoordinator` — the 8-Bx slash driver + NAV-provision writer (pulled into M1 scope 2026-06-09); it makes the
  8-Bx slash half live and is the natural loss-side follow-on.

---

## POST-REVIEW AMENDMENT (2026-06-09, superintendent + user)
Superintendent review accepted the build. Then, **user-directed**, the escrow joined the repo-wide build-phase
**Timelock-settable wiring** decision (§17, memory [[oracle-replaceable-timelock-wiring]]):
- `LienXAlphaEscrow` now carries a **Timelock owner**; `xAlpha`/`coordinator`/`capitalSink`/`sidecar` are
  Timelock-re-pointable (no longer immutable). No fund-extraction path was added (no sweep/rescue) — `40/40` escrow
  tests green incl. the reframed no-sweep ABI-negative.
- The "fully-immutable / non-sweepable / destination-integrity theft-immunity" thesis above holds for the
  PRE-PRODUCTION shape; in the build phase a hostile Timelock could re-point a destination, so the theft-immunity is
  **restored at the pre-prod lock-down** (re-freeze the four slots to immutable). Logged in §17 + PROGRESS.
