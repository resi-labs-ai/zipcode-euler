# SEC-01 — Oracle monotonic-timestamp guard (3 write sites)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 1 (H1/M1/L3);
audit `build/audit-claude/interconnection-findings.md` (C4 draw path),
`build/audit-claude/reference-diff-findings.md` · **Status:** DONE (2026-06-15)

> Scope authored 2026-06-15. One pattern, three sibling write paths. The fourth sibling,
> `SzAlphaRateOracle.sol:86`, already has the guard (`if (ts <= latest.ts) revert StaleReport();`)
> — this ticket brings the other three up to match. Smallest, highest-leverage kill-list item.

## Deliverable
Add the strictly-newer timestamp guard to the three oracle write paths that omit it, each with
the required `error StaleReport()` declaration so the one-liner compiles.

## What it does / what's being fixed (plain language)
These contracts are CRE-pushed price feeds: each pushed price carries a timestamp ("price as of
time T"); the contract stores the latest mark and the rest of the protocol reads it to value
loans, gate liquidations, and price deposits/exits. Three of them accept a new write without
checking the incoming timestamp is newer than the stored one — so an old or replayed price can
overwrite a fresher mark.

## Binds to (verified file:line — 2026-06-15)
- **H1 (HIGH)** · `contracts/src/ZipcodeOracleRegistry.sol:127-133` — shared `_writePrice`.
  Out-of-order/replayed rt-3 overwrites a fresher mark → shields a bad loan from liquidation.
  The guard goes in the **shared** `_writePrice` so it ALSO covers the controller `seedPrice`
  clobber (`:106-108`, the interconnection-C4 draw-path seed) — NOT in the rt-3 loop (`:121`)
  or `seedPrice` individually.
- **M1 (MED, DoS)** · `contracts/src/supply/SzipNavOracle.sol` `_processReport` leg-write —
  immediately before the `legCache[leg] = LegCache(p, uint48(ts));` write (~`:296-297`). The
  deviation band is **price-only**, so replaying the last price with a backdated `ts` slips
  through and freezes issuance + buy-burn. A `prior.ts != 0` branch already exists (deviation
  band) — add the ts check beside it.
- **L3 (LOW)** · `contracts/src/supply/SzipReservoirLpOracle.sol:112-118` — shared `_writePrice`.
  Same gap; not pure grief — a stale-but-still-fresh *higher* mark over-credits reservoir collateral.

## Key requirements
1. **H1:** `if (ts <= cache[lien].timestamp) revert StaleReport();` in `_writePrice`. Use `<=`
   (strictly-newer; first write has `timestamp == 0`, so any non-zero `ts` passes).
2. **M1:** `if (prior.ts != 0 && ts <= prior.ts) revert StaleReport();` before the leg write.
3. **L3:** `if (ts <= cache.timestamp) revert StaleReport();` in `_writePrice`.
4. **Declare `error StaleReport();`** at each of the three contracts (registry, nav, lp) — the
   guard line alone will NOT compile. `SzAlphaRateOracle` already declares + uses it; leave it untouched.

## Do NOT
- Do NOT add a deviation band or any value guard — timestamp-only, mirroring `SzAlphaRateOracle:86`.
- Do NOT put the H1 guard in `seedPrice` or the rt-3 loop — it must sit in the **shared**
  `_writePrice` so the seed clobber is covered too.
- Do NOT use `<` (must reject equal-`ts` replays), and do NOT change the existing
  `SzAlphaRateOracle:86` guard.
- Do NOT widen scope to any other kill-list group.

## Done when
- `cd contracts && forge build` is clean (with the three `error StaleReport()` declarations).
- `forge test` is green, **plus a new `SEC01_*` regression test** that fails before the fix and
  passes after:
  - registry: a stale/equal-`ts` write reverts `StaleReport()` via BOTH `seedPrice` and the rt-3
    batch path; a strictly-newer write still succeeds;
  - nav: a backdated same-price replay reverts `StaleReport()` (proving it slips the deviation band);
  - lp: a backdated mark reverts `StaleReport()`.
- Quote the actual `forge test` output in this ticket's done note.

## Depends on
- None — first SEC ticket. On land: add the finding note to `PROGRESS.md` "Just done — SEC-01".

---

## Downstream test impact (discovered at build — folds back into the ticket)
The guard changes the accepted-input set, so any **pre-existing** test that pushed a non-increasing/equal/backdated
mark and asserted SUCCESS must be updated (it now correctly reverts `StaleReport()`). Six tests, all fixed by a
faithful forward-warp (a separate CRE report lands in a later block with a strictly-newer `ts`) — none reflect a real
regression:
- **Oracle units (3):** `ZipcodeOracleRegistry.t.sol::test_RevaluationOverwritesSeed` (was a *backdated* overwrite →
  now a strictly-newer overwrite; the backdated-revert case moved to `test_SEC01_reval_backdated_reverts`),
  `…::test_NoValueBand_BigDrop_Succeeds` (warp before the reval), `…::test_DuplicateLiensLastWriteWins` →
  **renamed** `test_DuplicateLiensInBatchRevertStale` (a duplicate lien in ONE batch shares the batch `ts`, so the
  second write is a same-ts replay → the all-or-nothing batch now reverts `StaleReport()` — a malformed duplicate
  report fails closed instead of silently last-write-winning).
- **NAV units (3):** `SzipNavOracle.t.sol::test_deviation_within_bound_ok`,
  `…::test_batch_atomicity_one_bad_entry_reverts_all` (warp so leg0 clears the guard and leg1's `ZeroPrice` is the
  surfaced revert), `…::test_lp_marked_through`.
- **Integration (3, beyond the units):** `ZipcodeController.t.sol::test_Draw_ExactAccrual` +
  `…::test_Draw_ReAnchorBelowLTV_RollsBack` (the latter was a **false pass** — its generic `vm.expectRevert()` was
  satisfied by `StaleReport` instead of the LTV check; now warped + pinned to `EVKErrors.E_AccountLiquidity`),
  `EulerVenueAdapter.t.sol::test_TwoLine_DistinctPrefix_BothDraw_Isolation` (re-mark B in a later block),
  `ReservoirLoopModule.t.sol::test_oracle_non_divisible_floors_against_borrower` (warp between the two `_pushMark`s).

**Operational consequence (intended fail-closed; logged for the CRE track).** `ZipcodeController` re-anchors the
lien mark via `registry.seedPrice` at BOTH origination (`:199`) and draw (`:223`); `seedPrice` stamps
`block.timestamp` (no incoming CRE ts). With the guard in the shared `_writePrice`, **two seeds of the same lien in
one block now revert** (origination+draw or draw+draw co-located in a single block). This is exactly the H1
seed-clobber the kill-list wanted closed; in production origination/draw are separate Keystone reports in separate
blocks, so it is benign — but **CRE-01 must not co-locate two same-lien seeds in one block** (defer the second one
block, or carry a real ts). Noted in `PROGRESS.md` open obligations + the CRE-01 backlog row.

## Done note — gate output (2026-06-15)
- `cd contracts && forge build` → `Compiler run successful` (warnings only; pre-existing lints, no errors).
- New `SzipReservoirLpOracle.t.sol` authored (no prior test file existed for this oracle).
- `forge test` full suite: **764 passed, 0 failed, 3 skipped** (the 3 skips are the pre-existing `DeployZipcode.t.sol`
  skips). SEC01 regression (`forge test --match-test SEC01`):
  ```
  [PASS] test_SEC01_seedPrice_equalTs_reverts()       (registry, seedPrice path)
  [PASS] test_SEC01_reval_backdated_reverts()         (registry, rt-3 path)
  [PASS] test_SEC01_reval_equalTs_reverts()           (registry, rt-3 path)
  [PASS] test_SEC01_strictlyNewer_succeeds()          (registry, strictly-newer still writes)
  [PASS] test_SEC01_nav_backdated_replay_reverts()    (nav, same-price replay slips the deviation band → caught)
  [PASS] test_SEC01_lp_firstWrite_succeeds()          (lp, first write timestamp==0 passes)
  [PASS] test_SEC01_lp_backdated_mark_reverts()       (lp, stale higher mark rejected)
  [PASS] test_SEC01_lp_equalTs_reverts()              (lp)
  [PASS] test_SEC01_lp_strictlyNewer_succeeds()       (lp)
  Suite result: ok. (3 oracle suites green; integration suites green)
  ```
