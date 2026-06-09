# WOOF-06 — authoring-window report to the superintendent

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** 7 — `ZipDepositModule` (the zap) (§4.5 → WOOF-06).
**Date:** 2026-06-08 (cold-build against the real Gate seam). **Branch:** `main`.

> This report REPLACES the 2026-06-07 re-author report (which described the spec re-author with the build deferred).
> The ticket was already authored + critiqued (2026-06-07, two-token / Exit-Gate seam). This window's job was the
> **keep-the-build materialization** against the now-landed real Gate.

## TL;DR
- **WOOF-06 is BUILT-VERIFIED + KEPT on disk against the REAL Exit Gate seam** (not a mock). Code:
  `contracts/src/supply/ZipDepositModule.sol` + `contracts/test/ZipDepositModule.t.sol`. `forge build` green +
  **29/29** WOOF-06 tests (26 mock-gate adversarial unit + 3 real-gate Base-fork), **205/205 total, no regression**.
  Run it yourself: `cd contracts && forge test --fork-url $BASE_RPC_URL` (the `.env` `BASE_RPC_URL` auto-loads).
- The module is exactly the re-authored ticket's stateless mint+route plumbing: `deposit` (raw zipUSD, secondary),
  `zap` (default — USDC → transient zipUSD → `gate.depositFor` → on-behalf transferable szipUSD), `previewDeposit`/
  `previewZap`, set-once `setGate`, 4 ctor immutables + derived `scaleUp`. F1/F7 hardening intact.
- **One real finding (the keep-the-build payoff): the live `ExitGate` lacked the `previewDeposit` quote view** — the
  obligation THIS ticket created on the Gate. I added it to the kept Gate and verified it. **It adds NO pricing math:
  it is a thin forwarder that delegates entirely to the already-built `SzipNavOracle` (8-B4)** — it reads the oracle's
  `navEntry()` (price per share) and `valueOf()` (USD value of the deposit) and divides, round-down. The price is the
  oracle's (which composes it from the real basket contents; at genesis/empty supply the oracle returns the $1.00
  par). `depositFor` itself matched the pinned interface exactly. No `claude-zipcode.md` spec edit was needed (the
  module is pure plumbing, the Gate view is a pure forwarder, and the pinned seam held).

## What the window did
1. Verified the real seam: the kept `ExitGate.depositFor(address asset, uint256 amount, address receiver) returns
   (uint256 shares)` matches the `IZipExitGate` the ticket pinned **exactly**. Built the module to it.
2. Materialized `ZipDepositModule.sol` from the ticket (zero spec-guess; the ticket was build-grade).
3. Wrote two test suites (see "Design decisions B"): a non-fork mock-gate suite for the full Done-when matrix incl.
   adversarial gate behaviours, and a Base-fork real-gate suite that re-proves the headline zap against the LIVE
   Gate + `SzipNavOracle` + Baal substrate + real zipUSD `ESynth`.
4. Closed the `previewDeposit` quote-view gap on the Gate (a pure forwarder to `SzipNavOracle`, no new pricing);
   added `forge test` coverage on both sides.

## Design decisions (superintendent sanity-check)
**A. `previewDeposit` quote view added to the live Gate (obligation discharge, not a spec change, and NOT new
pricing).** The ticket's `previewZap` calls `gate.previewDeposit(zipUSD, zipMinted)` and lists `previewDeposit` as a
cross-ticket obligation owed by the Gate. The Exit Gate (item 8) was built + kept WITHOUT it. The view I added owns
**no pricing of its own** — it forwards to the already-built `SzipNavOracle` (8-B4): it reads the oracle's
`valueOf(asset, amount)` (the deposit's USD value, composed by the oracle from the real basket contents) and
`navEntry()` (the bracketed price-per-share) and divides, round-down — i.e. it mirrors what `depositFor` does at
execution, minus the `poke`/`mint`/cap side-effects. It is view-only (it can't `poke`, so it reads the accumulator
as-is; documented as an estimate, per the §3 `max(spot,twap)` bracket). The oracle is the source of price and already
handles the empty-basket case (returns the $1.00 genesis par at zero supply), so the quote inherits that — nothing is
priced "without contents." This is additive — no behaviour change to any existing Gate function — and is the correct
seam completion. **Please confirm you're comfortable editing the already-DONE Gate to discharge this; I judged "keep
the seam honest" over "renegotiate the obligation down."**

**B. Real-gate fork suite + retained mock gate (the kickoff's "real seam, not a mock" mandate).** The 2026-06-07
ticket text says "cold-build MOCKS the Gate" (written before the Gate existed). The kickoff banner overrides:
"materialize it against the real `gate.depositFor` seam, not a mock." I did BOTH: `ZipDepositModuleRealGateTest`
proves the happy paths end-to-end against the live Gate; a `MockGate` is retained ONLY for the adversarial gate
behaviours the real, correct Gate cannot exhibit (under-pull → `ResidualBalance`, no-share → `ZeroShares`, mid-call
revert atomicity, gate-side + EE-side reentrancy). I folded this into the ticket's Done-when so intent + code agree.

**C. Real Gate routes pulled zipUSD to `mainSafe`, not the Gate.** `ExitGate.depositFor` does
`safeTransferFrom(module, mainSafe, amount)` (the zipUSD becomes basket equity immediately). The ticket's mock-gate
Done-when asserts `zip.balanceOf(gateMock)`; the real-gate test asserts `zip.balanceOf(mainSafe)`. The module's
own invariant — it must hold **zero** zipUSD afterwards (full pull, else `ResidualBalance`) — is identical either
way and is asserted in every test. Noted in the ticket.

## Holes the harness surfaced → resolution
**Build-discovered (during materialization):**
1. **`previewDeposit` quote view missing on the Gate** → added to `ExitGate.sol` as a thin forwarder to
   `SzipNavOracle` (8-B4) — no new pricing math (Design A). DISCHARGED.

**6-critic fanout (junior-developer · spec-fidelity · reference-verifier · qa-engineer · security-engineer ·
frontend-integration) — run on the materialized code + ticket + INFLOW-06.** Triage:
2. **[ticket/code] Misleading ctor error** (junior-dev + ref-verifier) — the `zipDec < usdcDec` guard reverted the
   reused `ZeroAmount()`. → added dedicated **`error DecimalsTooFew()`**; ticket error-list + the ctor test updated.
3. **[doc] `scaleUp` comment "(never `1e12`)"** contradicted the test asserting `scaleUp()==1e12` (ref-verifier). →
   reworded to "derived from the tokens' own `decimals()` (NOT a hard-coded literal); equals `1e12` for 18-dp/6-dp."
4. **[test] 4 tests missing the "module holds nothing" conservation assert** + **2 reentrancy tests using bare
   `expectRevert()`** (qa). → added `_assertModuleEmpty()`/inline module-empty checks to the 4; tightened both
   reentrancy tests to `ReentrancyGuard.ReentrancyGuardReentrantCall.selector`. Still 29/29, 205/205.
5. **spec-fidelity: clean — 100% faithful, no drift, §17 honored, all inbound obligations discharged.** No
   `claude-zipcode.md` edit warranted (the module adds no economic decision; pricing lives in Gate + oracle).

**Rejected as non-issues (recorded so they're not re-raised):**
6. **security "Critical/High: preview↔execution staleness/cap/wiring divergence"** — `previewDeposit` is a view-only
   UI ESTIMATE and its NatSpec already states it omits the cap/wiring (enforced by `depositFor` at execution); a view
   differing from execution is not value-extractable. Mint-to-`address(0)` "gap" is already blocked by OZ
   `_mint`’s `ERC20InvalidReceiver`. NOT actioned.
7. **security "stranded capital / residual allowance on mid-zap revert"** — false positive: the zap is one atomic
   `nonReentrant` tx; a revert rolls back the USDC pull, mint, EE deposit, AND the `forceApprove` together
   (`test_zap_gateRevert_atomic_rollback` proves the pristine snapshot). NOT actioned.
8. **frontend: `erc20AllowanceAbi` missing + `IZipDepositModule.sol` not authored** — INFLOW-06 scope (still PENDING
   cold-build); the *contract* surface MATCHES INFLOW-06's assumptions (events, `previewZap` tuple). Carried to the
   INFLOW-06 window, not a WOOF-06 contract gap.

*(Correction to my first draft of this report: I had proposed skipping the fanout — that was wrong; the harness loop
is the loop, especially for a user-facing item. The fanout was run and is the reason for fixes 2–4 above.)*

## Authoritative-doc edits (review)
- **`contracts/src/supply/szipUSD/ExitGate.sol`** — added the `previewDeposit` quote view (additive; a pure forwarder
  to `SzipNavOracle`, no new pricing). +2 tests in `contracts/test/ExitGate.t.sol`
  (`test_previewDeposit_matches_depositFor`, `test_previewDeposit_guards`).
- **`tickets/woof/WOOF-06-deposit-module.md`** — status → BUILT-VERIFIED; Done-when notes the two-suite shape +
  the mainSafe-vs-gate assertion; obligation #1 marked DISCHARGED.
- **`tickets/PROGRESS.md`** / **`tickets/LEDGER.md`** — item-7 row + banner + session log + the WOOF-06 digest
  updated to the as-built two-token shape.
- **No `claude-zipcode.md` edit.** (The contract adds no economic decision; NAV/pricing lives in the Gate + oracle.)

## Judgment calls (please rule)
- **JC1.** Editing the kept Exit Gate to add the `previewDeposit` quote view (a forwarder to `SzipNavOracle`, no new
  pricing — Design A). I believe correct; confirm.
- **JC2.** Retaining a `MockGate` for the adversarial guards rather than forcing every test through the real Gate
  (Design B). The real Gate can't under-pull / return-zero / re-enter, so those guards are only testable with a
  misbehaving stand-in. Confirm acceptable.
- **JC3.** ~~Skipping the critic fanout~~ — RETRACTED. The 6-critic fanout WAS run (Holes §2–8); it produced the
  ctor-error / doc / test-hardening fixes. No outstanding judgment call here.
- **JC4.** Code kept on disk, **NOT git-committed** (whole working tree is untracked — matching the Exit Gate /
  8-B1 precedent, "superintendent commit decision pending"). Confirm you want me to keep deferring commits to you.

## Status & next
- **Item 7 (WOOF-06): DONE / BUILT-VERIFIED.** Obligation: the Gate's `previewDeposit` DISCHARGED.
- **Still open:** INFLOW-06 (the frontend interface half) is still PENDING cold-build (a Vue/euler-lite item, not a
  contract — author when the frontend track is reached). Item-10 deploy/wiring obligations for the module remain
  OPEN (carried by the `audit/2` Baal sweep).
- **NEXT (per `reports/baal-spec.md §13` + the banner): 8-B14 — szipUSD buy-and-burn** (`burnFor`, the impatient-exit
  liquidity floor; the Gate's `burnFor` seam already exists), then the engine `8-B5…B13`.
