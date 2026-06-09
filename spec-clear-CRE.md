# spec-clear-CRE.md — §8 CRE workflow spec (the off-chain robot)

**What this is.** A SPEC-EDIT window (like Phase 8-S): no `tickets/`, no `contracts/`, no cold-build. You edit
`claude-zipcode.md` §8 (+ `bridge/xALPHA-apr.md` if touched). **Run it in a FRESH context.** Output = §8 raised
to the level where the **CRE-00…CRE-03 build tickets** (the Go workflows) are authorable, with every on-chain
report surface the contracts consume matched by a defined off-chain producer. Conclude with a report
(`reports/design/CRE-spec-report.md`) + a `tickets/PROGRESS.md` update, then STOP.

## Why
CRE is the off-chain Go program (Chainlink Runtime Environment, `cre-sdk-go` → wasip1) that drives the protocol:
gather the Proof-of-Value appraisals + subnet/DON consensus, then PUSH reports on-chain through the **immutable
KeystoneForwarder → the receivers**. The contracts are built + tested against MOCK reports; §8 (the producer
side) is "authored when reached" and is now **stale to the redesign** — it predates the Baal szipUSD + the
`CreditWarehouse`. This window authors §8 so the CRE build track can begin and every report surface has a producer.

## Read first
- `claude-zipcode.md` §8 (current CRE spec) + §4.1/§4.3/§4.4 (the on-chain report CONSUMERS: registry seed +
  `_processReport`; the controller `onReport` per-type dispatch; the hook gate) + §7 (subnet/Proof feed) + §17
  (event-driven Proof; immutable-Forwarder-via-renounce — **do NOT reopen**).
- The NEW report surfaces the redesign added: the **`CreditWarehouse` `WarehouseAdminModule`** opType reports
  (SUPPLY / REDEEM / REPAY → it calls `Roles.execTransactionWithRole`) — `reports/research/zodiac-warehouse-research.md`
  + §4.5 `CreditWarehouse`; and the **Baal szipUSD manager + lock/freeze shaman** reports (deposit / lock /
  freeze / NAV / harvest) — `reports/design/szipUSD-baal-redesign-report.md` + §4.5 + (for the engine ops)
  `spec-clear-8SY.md`'s 8-B11.
- The OPEN **CRE-track obligations** in `tickets/PROGRESS.md` (report ABI envelope per-type table; gas-bounded
  revaluation sharding) — this window must DISCHARGE them in §8.
- `tickets/PHASE2.md` (the CRE stubs CRE-00…03 + the cross-track obligation rows) — reconcile, don't duplicate.
- Reference: `reference/cre-sdk-go`, `reference/cre-templates`, `reference/cre-bootcamp-2026`, the
  KeystoneForwarder / `ReceiverTemplate` pattern (`reference/x402-cre-price-alerts`). Memory
  `deploy-target-base-mainnet` (CRE chain selector `ethereum-mainnet-base-1`, Base mainnet 8453).

## Deliverable — author §8 to cover every report surface + its producer
- **The report envelope + per-type table.** The on-chain convention is `abi.encode(uint8 reportType, bytes
  payload)`. Enumerate EVERY reportType the contracts consume and the workflow that produces each: the §4.4
  controller types (1 origination / 2 draw / 4 close / 5,6 status; 3 → registry-direct revaluation) PLUS the new
  warehouse opTypes (SUPPLY/REDEEM/REPAY) and the szipUSD shaman ops. (Discharges the WOOF-05 ABI + WOOF-02
  sharding obligations.)
- **The workflows** (each a CRE-NN ticket basis): origination/underwriting (§8.1, Proof-gated); draw; close;
  redemption-settle `cron` (§8.3); revaluation (gas-bounded sharded batches, atomic-safe, no malformed/dup
  entry); default/recovery → `DefaultCoordinator` (M2-aware, sketch OK); the **warehouse ops** (CRE drives
  SUPPLY/REDEEM/REPAY through the Roles-gated adapter); the **szipUSD strategy-admin** ops (the 8-B11 robot —
  on-chain surface from `spec-clear-8SY.md`); the **xALPHA-APR feed** (§7 / `bridge/xALPHA-apr.md`).
- **Gating rules:** emit a report only after the Proof gates + delinquency checks pass; the immutable-Forwarder
  identity model; the gas-bounded sharding rule.

## Method / constraints
- **Honor §17** (event-driven Proof, no heartbeat, immutable Forwarder). §8 is the PRODUCER spec; the consumer
  ABIs are already locked in §4.1/§4.4 — **match them exactly, do not redesign them**. Invent no on-chain mechanism.
- **DEC-01 (Proof capability) is the external gate** — surface it (can Proof attest lien/value/ownership/insurance
  per-lien in a CRE-consumable form?); spec assuming it, flag where it blocks a live build.
- Reconcile with PHASE2's CRE stubs (CRE-00 scaffold / CRE-01 origination / CRE-02 redemption-cron / CRE-03
  xALPHA-APR) — update them to the new surfaces, don't duplicate.

## Conclude
Write `reports/design/CRE-spec-report.md`. Update `tickets/PROGRESS.md`: §8 spec DONE; discharge the CRE-track
obligation rows; CRE-00…CRE-03 now authorable. STOP.
