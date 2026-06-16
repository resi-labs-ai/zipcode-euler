# SEC-DOC — Doc / runbook sweep (14 DOC dispositions)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` §B (DOC) + Design notes; the cited
`build/claude-zipcode.md` §§ and contract files below · **Status:** ✅ DONE 2026-06-16

> Scope authored 2026-06-15. The FINAL SEC item, after SEC-01…SEC-15. **Documentation / NatDoc / runbook only —
> NO behavioral code.** Several items explicitly REJECT a proposed code change (the rejection IS the finding).
> Where a contract comment is added, `forge build` must stay clean; there is no regression test (doc-only) —
> the gate is a per-item checklist + green build/tests.

## Deliverable
Land all 14 DOC dispositions as doc/comment/runbook edits in one sweep, recording for each whether the action is
a doc edit, a one-line code comment, or an explicit rejection of a proposed change.

## Per-item actions (verify each cited site at edit time)

| ID | Disposition | Action | Site |
|---|---|---|---|
| **M3** | DECIDE→DOC | Document that buy-burn fill is **intentionally NOT fill-time gated** (buy-burn USDC is engine-Safe value excluded from `coverageValue()`; APP_DATA pinned to 0 forbids CoW hooks). **REJECT the CoW hook.** The "optionally shrink deployed `NAV_MAX_AGE`" is a deploy-tuning decision — note it, do NOT change the param here. | `SzipBuyBurnModule` NatDoc + `build/claude-zipcode.md` §6/§7 |
| **M8** | FIX→DOC | Reconcile the header docstring (provisions write up by realized receipts OR fully on terminal resolve, the ratified §8.4 clean-resolution). **REJECT the `capitalSlashAmount <= recoveryProceeds` assert** — unit-incoherent (xALPHA bond units vs USD) and `_resolve` has no such param. | `src/loss/DefaultCoordinator.sol` header (~`:27-28`) |
| **L4** | FIX→DOC | Producer runbook: `MAX_LIENS_PER_REPORT` sharding to mitigate the all-or-nothing batch. **REJECT per-key try/catch** — it weakens the intentional WOOF-02 fail-closed batch (swallows poison keys). | CRE producer runbook note (`build/` + the registry batch NatDoc) |
| **L6r** | FIX→DOC | CEI verified correct; an over-bond `capitalSlashAmount` reverts atomically + is re-submittable. **REJECT the proposed assert (no-op).** Optional clarity comment only. | `src/loss/DefaultCoordinator.sol` `_resolve` |
| **L13** | DOC | Re-document: a reservoir borrow is a **double-squeeze** (numerator down via `pathLockedLpEquity` debt AND floor up via warehouse `maxWithdraw` drop) — fail-closed/self-DoS, recovers on repay. Optional liveness-footgun note. | `DurationFreezeModule` / `SzipNavOracle` coverage NatDoc |
| **L15** | FIX→DOC | One-line comment that the registry adapter is **intentionally forward-only** (reverse-pair quote already fails closed; EVK never quotes reverse). **REJECT "add inverse support"** (dead code). | `src/ZipcodeOracleRegistry.sol:153` (`_getQuote` `NotSupported`) |
| **L17** | FIX→DOC | Comment that the USDC→eePool allowance always settles to 0 (exact-amount `forceApprove`, EE pulls full, `eePool` immutable) so the asymmetry vs the zipUSD→gate reset is justified. The symmetric `forceApprove(0)` reset is OPTIONAL (not owed) — if added it is a 1-line behavioral change; **default = comment only** to keep this sweep non-behavioral. | the approve sites (NatDoc) |
| **L16** | DOC | Comment that the global 18-dp `scale` / `_strictDecimals == 18` guard is **load-bearing** — must not be relaxed without per-key scale (non-18dp is currently unreachable by design). | the `scale` / `_strictDecimals` guard site (confirm: `SzipNavOracle` / `ZipcodeOracleRegistry`) |
| **I1** | design re-affirm | Re-affirm: **no on-chain junior redeem-for-assets**; exit is the NAV-tracking CoW secondary. | `build/claude-zipcode.md` exit § |
| **I2** | design (tighten) | Tighten the note: szipUSD **shares** are NAV-priced (`max(spot,twap)`); the flat $1 is ONLY on the zipUSD **deposit input**. Real latent risk: a zipUSD **de-peg** over-issues szipUSD + dilutes stayers (LOW; mitigated by atomic capacity-gated minting). Optional hardening (price the zipUSD leg off realized backing) = note, not owed. | `build/claude-zipcode.md` §7 + the deposit-input $1 site in `SzipNavOracle` (confirm exact line) |
| **I3** | design | Document that par-burn 1:1 is treasury-internal (single requester escrows its own zipUSD); the `MultipleRequesters` guard is the sole defense — **`redeemController` must never be an untrusted party**. | `build/claude-zipcode.md` §12 + `ZipRedemptionQueue` NatDoc |
| **I4** | info | Correct the false "no owner / immutable" claim: `SzAlphaRateOracle` inherits `Ownable`; Forwarder + workflow identity are Timelock-mutable; only the economic knobs are immutable. | `build/claude-zipcode.md:146` + §2/§6 |
| **I5** | info | Runbook: paired `setSafe`/`setAvatar` with a parity check (the injected `safe` and Roles `avatar` are independent slots; a one-sided re-point bricks SUPPLY/REDEEM — fails closed). Correct the docstrings. | `src/supply/CreditWarehouse/WarehouseAdminModule.sol:24,:28` + runbook |
| **prorata** | DEFER→DOC | Re-document: the "loan-marked-bad signal absent" premise is WRONG — `writeProvision` exists and flows to the **junior** NAV (`ExitGate` ragequit self-prices on impairment). The **senior** par queue is intentionally impairment-blind (single trusted requester). **No queue change.** | `build/claude-zipcode.md` §11/§12 + `ZipRedemptionQueue` NatDoc |

## Do NOT (the rejected code changes — these rejections are the finding)
- **M8:** do NOT add the `capitalSlashAmount <= recoveryProceeds` assert (unit-incoherent, no such param).
- **L4:** do NOT add per-key try/catch (weakens the fail-closed batch).
- **L6r:** do NOT add the over-bond assert (no-op; the tx already reverts atomically).
- **L15:** do NOT add reverse/inverse pair support (dead code; reverse already fails closed).
- Do NOT make any behavioral change in this sweep — M3's `NAV_MAX_AGE` shrink and L17's symmetric `approve(0)`
  reset are OPTIONAL/deferred decisions, NOT part of SEC-DOC (note them; don't implement).
- Do NOT touch the DISMISS items (H3/L5/L10) or DEFER items here — they are tracked, not swept.

## Done when
- `cd contracts && forge build` clean (any added contract comments compile) and `forge test` still green
  (no new test — doc/comment-only).
- A per-item checklist in this ticket's done note confirms each of the 14 landed as the table specifies, with the
  4 rejections (M8/L4/L6r/L15) explicitly recorded as "rejected, not implemented — reason."
- Any `build/claude-zipcode.md` edits (I1/I2/I3/I4/M3/prorata) saved; cite the section/line touched.

## Depends on
- Authored after SEC-01…SEC-15 (it documents the as-built state, including the just-landed fixes). On land:
  `PROGRESS.md` "Just done — SEC-DOC" + mark the SEC track complete → next phase (fresh anvil deploy → solidify
  `build/wires/` → CRE → FE), per the kill-list "Next phase".

---

## DONE-note (2026-06-16)

**All 14 DOC dispositions landed as doc/NatDoc/comment edits — ZERO behavioral code.** Gate: `cd contracts && forge build`
clean (lint notes only) + `forge test` **829 passed / 0 failed / 3 skipped** — IDENTICAL to the SEC-15 baseline (829/0/3),
confirming no behavior changed. No new regression test (doc-only). The 4 rejected code changes are recorded as rejections
(the rejection IS the finding).

### Per-item checklist (each verified at edit time against the live contract/spec)

| ID | Kind | Landed where | Rejection recorded? |
|---|---|---|---|
| **M3** | NatDoc + spec | `SzipBuyBurnModule.sol` APP_DATA NatDoc; `claude-zipcode.md` §6.4 step 3; `8-B14` wire `ICoverageGate` row | ✅ CoW fill-time hook **REJECTED** (`APP_DATA==0` forbids hooks); `NAV_MAX_AGE` shrink noted as deploy-tuning, not changed |
| **M8** | NatDoc | `DefaultCoordinator.sol` header `(a)` clause (`:26-31`) reconciled (RECOVERY = up by receipts; RESOLVE = full to 0; WRITEOFF leaves residual) | ✅ `capitalSlashAmount <= recoveryProceeds` assert **REJECTED** — unit-incoherent, no such param |
| **L4** | NatDoc + runbook | `ZipcodeOracleRegistry._processReport` NatDoc; runbook already in `claude-zipcode.md` §8.1 "Revaluation sharding" — augmented with the rejection | ✅ per-key try/catch **REJECTED** — weakens WOOF-02 fail-closed batch |
| **L6r** | NatDoc | `DefaultCoordinator._resolve` NatDoc (over-bond reverts atomically + re-submittable) | ✅ over-bond assert **REJECTED** — no-op (tx already reverts) |
| **L13** | NatDoc | `DurationFreezeModule.covered()` `@dev` — re-documented as a fail-closed DOUBLE-squeeze (numerator down + floor up), recovers on repay | n/a (rationale correction) |
| **L15** | NatDoc | `ZipcodeOracleRegistry._getQuote` `@dev` — intentionally forward-only | ✅ inverse/reverse support **REJECTED** — dead code |
| **L16** | NatDoc | `ZipcodeOracleRegistry.LIEN_DECIMALS` `@dev` — 18-dp scale guard is LOAD-BEARING; don't relax without per-key scale | n/a |
| **L17** | comment | `ZipDepositModule.deposit`/`zap` — USDC→eePool settles to 0 (no reset needed); asymmetry vs zipUSD→gate justified | n/a (symmetric reset noted optional/behavioral, deferred) |
| **I1** | spec | `claude-zipcode.md` §6.4 — explicit re-affirmation: no on-chain junior redeem-for-assets; exit is NAV-tracking CoW | n/a (re-affirm) |
| **I2** | spec + comment | `claude-zipcode.md` §7; `SzipNavOracle.grossBasketValue` comment — shares NAV-priced, flat $1 only on zipUSD deposit-input leg; de-peg over-issue risk noted LOW | n/a (hardening noted not-owed) |
| **I3** | NatDoc + spec | `ZipRedemptionQueue.redeemController` `@dev`; `claude-zipcode.md` §12; `9-ZipRedemptionQueue` wire — par-burn treasury-internal, `MultipleRequesters` sole defense, `redeemController` must never be untrusted | n/a |
| **I4** | spec + wire | `claude-zipcode.md:146` + §8.8; `8-Bw-CreditWarehouse` wire — `is ReceiverTemplate is Ownable`, Forwarder + identity Timelock-mutable, only economic knobs immutable. (`8x-02` wire already correct.) | n/a |
| **I5** | NatDoc + wire | `WarehouseAdminModule.setSafe`/`safe` docstrings; `8-Bw-CreditWarehouse` wire — `safe` (injected) vs Roles `avatar` parity; pair `setSafe`+`setAvatar` or SUPPLY/REDEEM brick (fail-closed) | n/a |
| **prorata** | NatDoc + spec | `ZipRedemptionQueue` header; `claude-zipcode.md` §12; `9-ZipRedemptionQueue` wire — "no bad-loan signal" premise WRONG (`writeProvision` → junior NAV self-prices); senior par queue intentionally impairment-blind | ✅ queue change **REJECTED** (no pro-rata in senior queue) |

### Doc-sync done
- **kill-list §B:** banner + all 14 items tagged `[x] … DONE (SEC-DOC)`.
- **audit-claude:** `SUMMARY.md` (M3/M8 rows ✅ + LOW-line L4/L6r/L13/L15/L16/L17 tagged + setOperator ✅(SEC-15) + INFORMATIONAL I1/I2/I3/I4); `findings.md` #5 (M3); `interconnection-findings.md` C3 (M8) + C-L4 (L17); `role-based-findings.md` R11 (I4); `reference-diff-findings.md` (I5).
- **wires:** `8-Bw-CreditWarehouse` (I4+I5), `9-ZipRedemptionQueue` (I3+prorata), `8-B14-SzipBuyBurnModule` (M3). `8x-02-SzAlphaRateOracle` confirmed already-correct for I4.
- **spec:** `claude-zipcode.md` §3:146, §6.4, §7, §8.1, §8.8, §12 edited.
- **Report:** `build/reports/SEC-DOC-report.md`.

### Interpretation notes folded back (for cold rebuild)
- **L4 runbook** lives in `claude-zipcode.md` §8.1 (already present), NOT a new `build/cre-producer-runbook.md`; the registry NatDoc points there.
- **I4 "§2/§6"** in the ticket/kill-list was an imprecise pointer — the actual false claim is at §3:146 (and recurs as "immutable Forwarder" shorthand elsewhere, governed by the §17 revision at `:1342`). Corrected at §3:146 + §8.8.
- **I1** is a re-affirm: §6.4 already asserted it; added an explicit tagged sentence.
