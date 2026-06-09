# 8-S3 — `audit/1` re-derivation to the Baal/withhold money model (report to the superintendent)

**From:** builder window (this session). **To:** the superintendent. **Item:** 8 — `szipUSD`, phase **8-S3**.
**Outcome:** `audit/1-results.md` **fully re-derived** from the dead pool-share / `J×p` / escrow-burn proof to
the new Baal Loot-on-a-Safe-basket + WITHHOLD-not-markdown + three-lever money model; **no spec change needed**
(the spec closes arithmetically). **Phase 8-S (the money-model spec foundation) is now COMPLETE.**
**Date:** 2026-06-06. **Verdict requested:** ratify the new invariant set + the worked-numbers proof; confirm
**NEXT = 8-B1** (the first Baal build ticket).

## TL;DR
- 8-S3 was a **spec EDIT, not a build ticket**: no adversarial harness, no cold-build, no ticket file, no
  `contracts/`. I edited `audit/1-results.md` directly to match the already-rewritten §2/§4.5/§4.6/§11/§12/§17.
- The OLD proof encoded the **deleted** model end-to-end: invariants `A=Z+ν+σ` / `P×p≥Z` / `ν=J×p` /
  `σ=P×p−Z`, loss realized by **moving `Burn=loss/p` venue-pool shares into escrow** (`_realizeMarkdown`),
  recovery by returning `recovery/p` shares, `finalizeLoss` burning the residual. **All of that machinery is
  gone** in the new model — no venue-pool shares in the junior, no `J×p`, no escrow, no markdown.
- The NEW proof is built on the **two independent ledgers** (§12): senior solvency `NAV_s/Z ≥ 1`, and a junior
  Baal basket exited by **in-kind ragequit** with a **display-only** NAV.
- **Five new invariants** (replace I1–I4) and **four scenarios** (replace the P-rows), all closing on concrete
  numbers. **Spec-changes-recommended = None.**

## What I replaced
The old `audit/1` was a tight invariants + worked-numbers proof on the convert-on-stake substrate (szipUSD held
EulerEarn pool shares; junior NAV `ν = J×p`; first loss = a tentative-burn of `loss/p` shares into a per-lien
escrow, healed by `recovery/p`). I kept the **kind** of artifact and the rigor, and re-derived the whole thing
on the new substrate.

## The new invariant set (replaces I1–I4)
- **I1 — Senior solvency.** `R = NAV_s / Z ≥ 1`, where `NAV_s = idle USDC + marked loan value` (§12) and `Z` =
  total zipUSD supply **including the Safe's holding** (zipUSD is fungible — this is the keystone that makes
  lever-1 burn restore the senior). The surplus `σ = NAV_s − Z` is the **protocol's** cushion, not the junior's.
- **I2 — Subordination.** A confirmed loss reduces the junior basket `B` first (to 0), then `σ`, then senior par.
- **I3 — Ragequit value-preservation.** A ragequit moves `(loot_h/Loot) × basket` in-kind; per-Loot claim
  `B/Loot`, `Z`, `NAV_s`, `R` all unchanged; no oracle in the exit path.
- **I4 — Freeze neutrality.** The FREEZE withholds `lockedFraction = atRiskAmount / B` of every position and
  **moves no value**; the senior stays covered because the loan is still marked (expected to repay) and the
  at-risk junior backing is pinned in place.
- **I5 — Loss-realization completeness.** Each lever for a confirmed shortfall `L` restores `R ≥ 1` and shrinks
  `B` by exactly `L`: lever 1 (burn `L` junior zipUSD) cuts `Z` with `NAV_s` flat; levers 2/3 (sell yield /
  xALPHA → USDC → repay) raise `NAV_s` with `Z` flat. Junior bears `L`, senior made whole, `σ` preserved.

## The scenarios (replace the old P-rows)
- **S0 — baseline lifecycle.** Senior deposit → junior **zap** → draw → interest accrues (the **protocol's** σ,
  per §5/§17) → **xALPHA subsidy + HYDX vamp** (the **junior's** pay, lifting `B/Loot` not `σ`) → a ragequit.
  Proves I1–I3 in calm operation and the **two-ledger independence** that is the redesign's core claim.
- **S1 — duration freeze + recovery.** The loan goes delinquent; the FREEZE withholds `atRiskAmount/B` (value-
  neutral, I4); the waterfall brings external USDC; the loan repays; the freeze releases; the junior is whole +
  the in-kind xALPHA Duration-Bond premium. No NAV "restore" step — the junior was only withheld.
- **S2 — confirmed permanent loss, the three levers (the heart).** From one common confirmed-loss row
  (`L=50,000`, transiently `R<1`), three **mutually exclusive** branches: lever 1 burns 50,000 junior zipUSD
  (`Z↓`); lever 2 sells 50,000 accrued yield → USDC → repay (`NAV_s↑`); lever 3 sells 50,000 xALPHA → USDC →
  repay (`NAV_s↑`). All three land `B=160,000`, `R≥1`, `σ=16,000` intact — proving I5 for each lever
  independently and I2 (junior bears `L`, surplus untouched).
- **S3 — insolvency boundary.** A catastrophic loss exceeding the whole basket: the junior is consumed in full
  (I2 holds), then I1 fails **exactly once** on the residual — the §12 documented boundary, the new-model analog
  of the old proof's single S2 insolvency row.

## Key property carried over (re-expressed, not changed)
The old proof's headline — **strict junior-first-loss with the surplus preserved as a senior cushion** —
survives the redesign, **mechanism-changed**: first loss is now (1) a **WITHHOLD** during the duration window
(value-neutral) and (2) a **basket realization** on a confirmed shortfall (the three levers). The junior still
bears `L` first and `σ` still survives; the entire `_realizeMarkdown` / `Burn=loss/p` / escrow / `finalizeLoss`
apparatus is simply gone (§11).

## Judgment calls (rule on these)
1. **Lever-1 burn is sized to the full `L` (strict junior-first-loss), not the minimum to reach `R=1`.** Burning
   only the par shortfall (`L − σ`) would let the protocol surplus co-absorb — exactly the non-strict-first-loss
   formula the old proof rejected. I burned the full `L`, leaving `σ` intact, to keep the junior the sole
   first-loss absorber (matching §11 "the junior bears the loss with its own assets"). The three levers are then
   economically equal for the junior (each costs it `L`); they differ only in whether solvency is restored by
   cutting `Z` (lever 1) or raising `NAV_s` (levers 2/3).
2. **The confirmed-loss row shows a transient `R<1` ("FAIL pending").** The `DefaultCoordinator` applies a lever
   atomically at the confirmed-shortfall step, so the under-collateralized instant is never a state the senior
   can transact against. I flagged it rather than hiding it, because it is the honest pre-resolution snapshot.
3. **Did NOT reopen the §17 Baal junior decisions** (locked: Loot/Safe-basket/ragequit/in-kind, NAV-display-
   only, withhold-not-markdown, three-lever realization). The proof derives *from* them.

## Out of scope (flagged, not touched)
`audit/2.md` and `audit/3-results.md` still carry the **deleted** szipUSD stake/unstake/cooldown acceptance
steps and the `ν=J×p` "I1 sanity" Foundry assertions (`A=Z+ν+σ`). My re-derivation implies the on-chain
solvency-sanity assertion becomes **I1 (`NAV_s/Z≥1`)** + the basket checks **I3/I5**, and the stake/unstake/
cooldown steps become the **Baal deposit-shaman / ragequit / lock-shaman** flows. Per the 8-S3 rules I noted
this in both `audit/1-results.md` and `PROGRESS.md` but did **not** rewrite those files — they re-align when the
8-B build tickets are authored.

## Standing note for the superintendent
The money model is now **complete and internally consistent across `claude-zipcode.md` §2/§4.5/§4.6/§11/§12/§17
AND `audit/1-results.md`** — the one place that previously contradicted the spec is fixed. **Phase 8-S is
done.** The only remaining residuals are the two cosmetic ones already logged on 8-S2 (the stale §4.5
`:566-607` convert-on-stake block + the §11 `:1181` "unstake→AMM dump" noun), both guardrail-covered and slated
to be deleted/replaced when 8-B1 is authored.

## Status & NEXT
8-S1 ✅, 8-S2 ✅, **8-S3 ✅ — phase 8-S COMPLETE**. **NEXT = 8-B1** (Baal + Safe + Loot + shaman/Zodiac
scaffold) — the first build ticket, authored through the full harness and fork-tested against live Base.
