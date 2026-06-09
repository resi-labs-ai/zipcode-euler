# Structural-freeze lock + `DefaultCoordinator` shrink — spec-edit report

**From:** the superintendent (cross-cutting spec edit, authored with the user). **Date:** 2026-06-08.
**Kind:** spec-edit window (no ticket, no cold-build). **Touches:** `claude-zipcode.md` §2/§4.5/§4.6/§6.4/§9/§11/§15.

## TL;DR
- Resolved a latent inconsistency in the loss model. §6.4 already described the Duration-Bond freeze as
  **structural, utilization-sized, owned by the Exit Gate** — the junior equity committed to live credit lines sits
  in the non-ragequittable sidecar by virtue of being utilized, frozen-until-repaid. But §2/§4.5/§4.6/§9/§11/§15
  still carried the older framing: "`DefaultCoordinator` **engages** the freeze on default, sized
  `atRiskAmount/basketNAV`."
- **User ratified the structural reading.** The freeze is now uniformly structural and owned by the Exit Gate; a
  default does **not** engage it (utilization stays high → the committed slice stays in the sidecar).
- **`DefaultCoordinator` shrunk** to two jobs only: write the bounded recoverable **provision into `SzipNavOracle`**
  (the at-risk amount sizes the *markdown*, not the freeze) and run the **xALPHA recovery waterfall**. The freeze
  cohort storage / `lockedFraction` / objective release left it entirely.
- **`LienXAlphaEscrow` pulled forward** off M2 — it is a slashable reservoir (custody + slash), buildable now.

## Why (the design argument)
The freeze answers a **liquidity** question, not a loss question: capital lent into a live loan is illiquid, so the
junior backing it cannot be instantly redeemed either. That is true the moment a line draws — independent of whether
the loan ever defaults. So the correct sizing is **credit-warehouse utilization** (committed backing ÷ basketNAV),
recomputed as lines draw/repay, and the correct owner is the **Exit Gate** (the sole Loot custodian that already
accounts for free-vs-committed equity, §6.4). A default is not a freeze event — it is a **markdown** event.

The old "engage on default, sized `atRiskAmount`" framing implied the freeze only existed when a loan defaulted, which
(a) contradicted §6.4, (b) let junior backing for a *performing-but-live* loan be ragequit out (a real drain), and
(c) gave `DefaultCoordinator` custody/accounting responsibilities it does not need. The structural reading is safer
(no live-loan backing can be drained) and simpler (the coordinator never moves capital — it only writes NAV).

## What changed (faithful sweep, no §17 reopened)
| § | Edit |
|---|---|
| §2 (Duration-Bond row, l.153) | "at-risk slice sized `atRiskAmount/basketNAV`, driven by `DefaultCoordinator`" → "utilization-committed slice, owned by the Exit Gate; `DefaultCoordinator` only writes the NAV markdown + runs the xALPHA waterfall" |
| §4.5 (guardrail summary) | freeze sizing → utilization; ownership → Exit Gate |
| §4.6 (`DefaultCoordinator`) | rewrote the bullet to the **markdown-writer + recovery-waterfall** shape; freeze-engaging removed; "to detail for M2" no longer includes freeze cohort/`lockedFraction`/release |
| §4.6 (header) | M2-scope note gains a carve-out: `LienXAlphaEscrow` buildable now (custody M1, slash mock-tested now → M2 live) |
| §6.4 (item 4, l.1242) | `lockedFraction = atRiskAmount/basketNAV` → `committedFraction = committed backing / basketNAV` = utilization |
| §9 (default-path summary) | "`DefaultCoordinator` engages the freeze" → "the committed slice is already frozen (structural); the coordinator writes the provision + holds the bond" |
| §11 (two-parts prose, step-2 freeze, trigger-A) | freeze restated structural/utilization-sized, not engaged; at-risk amount sizes the markdown only |
| §15 (loss summary) | same: committed slice already frozen; coordinator writes the provision |

**No §17 decision reopened** — the freeze model was already locked (2026-06-05 duration-lock, 2026-06-07
provision-that-recovers). This edit removes a stale *residual framing*, it does not change a locked decision.

## Build impact
- **`LienXAlphaEscrow` → new backlog item 8-Bx, pulled forward** (M1-adjacent): custody half (`lockXAlpha`/
  `releaseXAlpha`) is M1; slash half (`slashXAlphaToCapital`/`slashXAlphaToCohort`, routing xALPHA into the sidecar)
  built + mock-tested now, live in M2. Authorable after the Exit Gate (the sidecar is its slash-target).
- **`DefaultCoordinator` stays M2**, now the smaller markdown-writer shape (its `SzipNavOracle.writeProvision` seam
  already exists — `SzipNavOracle` wires it as the set-once bounded provision writer).
- **The Exit Gate (NEXT)** owns the free-vs-committed / sidecar accounting and the structural freeze — this edit
  sharpens that scope but does not add to it (§6.4 already specified it).

## Status
Spec consistent across §2/§4.5/§4.6/§6.4/§9/§11/§15. PROGRESS backlog + session log updated. `forge build` still
clean (docs only). **NEXT (build) = the Exit Gate + szipUSD** (unchanged).
