# SEC-DOC — report (2026-06-16)

**The final SEC item.** All 14 DOC dispositions from `build/kill-list.md` §B landed as documentation / NatDoc /
comment / spec edits in one sweep, with **zero behavioral code**. The SEC track is now COMPLETE — the kill-list is
fully dispositioned (16 FIX landed SEC-01…SEC-15, 14 DOC swept here, 3 DISMISS + 3 DEFER tracked).

## What the window did

Documented the as-built behavior the audit flagged, recorded the four rejected code changes as rejections (the
rejection IS the finding), and corrected stale/false claims in the spec and wires. Every cited site was verified
against the live contract/spec before editing (the doc-only equivalent of the cold-build "zero guesses" gate).

### Edits by item

- **M3** (buy-burn fill not coverage-gated): `SzipBuyBurnModule` APP_DATA NatDoc + `claude-zipcode.md` §6.4 + the
  `8-B14` wire. **CoW fill-time hook REJECTED** (`APP_DATA==0` forbids hooks); `NAV_MAX_AGE` shrink noted as a
  deploy-tuning knob, not changed.
- **M8** (`_resolve` full heal): `DefaultCoordinator` header `(a)` clause reconciled — RECOVERY heals up by realized
  receipts, RESOLVE heals fully to 0 on terminal clean resolution (§8.4), WRITEOFF leaves the residual. **Assert
  REJECTED** (unit-incoherent; `_resolve` has no `recoveryProceeds` param).
- **L4** (all-or-nothing batch): `ZipcodeOracleRegistry._processReport` NatDoc + augmented the existing producer
  runbook in `claude-zipcode.md` §8.1. **Per-key try/catch REJECTED** (weakens the WOOF-02 fail-closed batch).
- **L6r** (over-bond resolve): `DefaultCoordinator._resolve` NatDoc — over-bond reverts the whole tx atomically and is
  re-submittable. **Assert REJECTED** (no-op).
- **L13** (coverage double-squeeze): `DurationFreezeModule.covered()` `@dev` — a reservoir borrow pushes BOTH sides
  the wrong way (numerator down via `pathLockedLpEquity` debt, floor up via `maxWithdraw` drop); fail-closed/self-DoS,
  recovers on repay.
- **L15** (forward-only adapter): `ZipcodeOracleRegistry._getQuote` `@dev`. **Inverse support REJECTED** (dead code).
- **L16** (18-dp scale): `ZipcodeOracleRegistry.LIEN_DECIMALS` `@dev` — the global 18-dp scale guard is load-bearing;
  don't relax without per-key scale.
- **L17** (USDC→eePool approve): `ZipDepositModule.deposit`/`zap` comments — the allowance settles to 0 (exact-amount,
  EE pulls full, `eePool` Timelock-only), so the asymmetry vs the zipUSD→gate reset is justified. Symmetric reset
  noted optional/behavioral, deferred.
- **I1** (no on-chain junior redeem): `claude-zipcode.md` §6.4 explicit re-affirm.
- **I2** (NAV-priced shares): `claude-zipcode.md` §7 + `SzipNavOracle.grossBasketValue` comment — shares are
  NAV-priced; flat $1 is only the zipUSD deposit-input leg; a zipUSD de-peg over-issue risk noted LOW.
- **I3** (trusted requester): `ZipRedemptionQueue.redeemController` `@dev` + `claude-zipcode.md` §12 + the
  `9-ZipRedemptionQueue` wire — `MultipleRequesters` is the sole defense; `redeemController` must never be untrusted.
- **I4** (owner/immutable false): `claude-zipcode.md` §3:146 + §8.8 + the `8-Bw-CreditWarehouse` wire —
  `ReceiverTemplate is Ownable`; Forwarder + identity are Timelock-mutable; only economic knobs are immutable.
- **I5** (safe/avatar parity): `WarehouseAdminModule.setSafe`/`safe` docstrings + the `8-Bw` wire — pair `setSafe`
  with the Roles `setAvatar` or SUPPLY/REDEEM brick (fail-closed).
- **prorata** (impairment-blind senior queue): `ZipRedemptionQueue` header + `claude-zipcode.md` §12 + the
  `9-ZipRedemptionQueue` wire — `writeProvision` DOES exist and flows to the JUNIOR NAV (so the junior CoW exit
  self-prices); the SENIOR par queue is intentionally impairment-blind. **No queue change.**

## Gate

`cd contracts && forge build` clean (lint notes only). `forge test` **829 passed / 0 failed / 3 skipped** —
**identical to the SEC-15 baseline (829/0/3)**, which is the proof this sweep changed no behavior. No regression test
added (doc/comment-only, per the ticket). The 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold.

## Decisions to sanity-check

1. **I4 "§2/§6" pointer was imprecise.** The ticket/kill-list named `claude-zipcode.md:146` + "§2/§6"; §2/§6 do not
   actually describe `SzAlphaRateOracle`'s ownership. The genuine false claim is at **§3:146** ("we drop the setter;
   immutable Forwarder"), corrected there + at the oracle's own **§8.8**. The recurring "immutable Forwarder"
   shorthand elsewhere in §7/§8 is already governed by the §17 revision at `:1342` ("wiring Timelock-settable, NOT
   immutable; immutability deferred to pre-prod") — left as-is rather than rewriting every occurrence. **Sanity-check:**
   is leaving the §7 "immutable Forwarder" phrasing (qualified by §17) acceptable, or should those occurrences be
   reworded too?
2. **L4 runbook location.** The producer runbook the registry NatDoc references already lives in `claude-zipcode.md`
   §8.1 ("Revaluation sharding"); I augmented it with the rejection rather than creating a new
   `build/cre-producer-runbook.md`. The registry NatDoc points to §8.1.
3. **L17 / M3 optional behavioral changes were NOT made** (per the ticket's Do-NOT): L17's symmetric `forceApprove(0)`
   reset and M3's `NAV_MAX_AGE` shrink are deferred deploy/optional decisions, only noted.
4. **`8x-02-SzAlphaRateOracle` wire doc was already correct for I4** (states Ownable, owner→Timelock, knobs immutable) —
   confirmed, left unedited. Only the `8-Bw-CreditWarehouse` wire carried the contradicting "immutable Forwarder gate"
   phrase, which was fixed.

## Holes → resolution

- *Which wire docs need syncing for a doc-only sweep?* — Resolved: only wires carrying a claim the kill-list declares
  WRONG/stale needed correction (`8-Bw` "immutable Forwarder gate", I4). Additive clarifications were added to the
  directly-owning wires for the substantive dispositions (M3→8-B14, I3/prorata→9-ZipRedemptionQueue, I5→8-Bw). The
  remaining items' wire behavior lists were already accurate (no behavior changed), so no further wire edits owed.

## Doc edits (full doc-sync list)

- **Ticket:** `build/tickets/sec/SEC-DOC-doc-runbook-sweep.md` — status DONE + 14-row per-item checklist.
- **PROGRESS.md:** SEC-DOC row DONE; "Just done — SEC-DOC (SEC track COMPLETE)" note; NEXT → CRE track (head CRE-00,
  preceded by a fresh-anvil deploy-sanity pass per the kill-list "Next phase").
- **kill-list.md §B:** DONE banner + all 14 items tagged `[x] … DONE (SEC-DOC)`.
- **audit-claude:** `SUMMARY.md` (M3/M8 rows ✅; LOW-line L4/L6r/L13/L15/L16/L17 tagged; setOperator ✅(SEC-15);
  INFORMATIONAL I1/I2/I3/I4); `findings.md` #5 (M3); `interconnection-findings.md` C3 (M8) + C-L4 (L17);
  `role-based-findings.md` R11 (I4); `reference-diff-findings.md` (I5).
- **wires:** `8-Bw-CreditWarehouse` (I4+I5), `9-ZipRedemptionQueue` (I3+prorata), `8-B14-SzipBuyBurnModule` (M3).
- **spec (`claude-zipcode.md`):** §3:146, §6.4, §7, §8.1, §8.8, §12.
- **No spec mechanism change** — all edits are interface/intent clarifications; the spec rules intent, the contract
  rules interface, and neither's *mechanism* moved. **No back-pressure / no new obligation.**

## Status + NEXT

**SEC-DOC DONE. The SEC track is COMPLETE (all 16 SEC tickets).** Per the kill-list "Next phase":
**fresh anvil deploy → solidify `build/wires/` → CRE → FE.** Recommended next move: a fresh anvil Base-fork
`DeployLocal` sanity pass to confirm the full post-SEC stack stands up, then the CRE track at its head **CRE-00**.
Reviewer releases the specific NEXT. **STOP.**
