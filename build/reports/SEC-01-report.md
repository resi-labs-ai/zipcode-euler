# SEC-01 report — Oracle monotonic-timestamp guard (3 write sites)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Source:** `build/kill-list.md` Group 1 (H1/M1/L3) ·
**Ticket:** `build/tickets/sec/SEC-01-oracle-monotonic-guard.md` · **Status:** DONE, gate green.

## What the window did
Brought the three sibling CRE-pushed price oracles up to the strictly-newer-timestamp guard already present at
`SzAlphaRateOracle.sol:86`. Each declares `error StaleReport()` and rejects a write whose `ts` is `<=` the cached
timestamp (first write has `timestamp == 0`, so it always passes). Timestamp-only — no value/deviation band added.

| Site | File | Guard |
|---|---|---|
| H1 | `src/ZipcodeOracleRegistry.sol` `_writePrice` (after `FutureTimestamp`, before the cache write) | `if (ts <= cache[lien].timestamp) revert StaleReport();` — **shared**, so it covers BOTH `seedPrice` and the rt-3 batch loop |
| M1 | `src/supply/SzipNavOracle.sol` `_processReport` (after the deviation block, before `legCache[leg] = …`) | `if (prior.ts != 0 && ts <= prior.ts) revert StaleReport();` — first per-leg write exempt; deviation band is price-only so a backdated same-price replay would otherwise slip through |
| L3 | `src/supply/SzipReservoirLpOracle.sol` `_writePrice` (after `FutureTimestamp`) | `if (ts <= cache.timestamp) revert StaleReport();` |

**M1 placement rationale:** put after the deviation `if`-block (not before) so a same-`ts` *price jump* still surfaces
`DeviationExceeded` (its existing test stays meaningful); only same/older `ts` writes that pass the band get caught by
`StaleReport`.

## Gate
- `forge build` → `Compiler run successful` (warnings only; pre-existing lints, no errors).
- `forge test` → **764 passed, 0 failed, 3 skipped** (the 3 skips are the pre-existing `DeployZipcode.t.sol` skips).
- 9 new `SEC01_*` regression tests across all three sites (registry seed path + rt-3 path + strictly-newer-succeeds;
  nav backdated same-price replay; lp first-write/backdated/equal/strictly-newer). New file
  `test/SzipReservoirLpOracle.t.sol` authored — none existed for that oracle.

## Decisions to sanity-check
1. **Same-block seed re-anchor now reverts (intended fail-closed).** The controller re-anchors the lien mark via
   `registry.seedPrice` at BOTH origination (`ZipcodeController.sol:199`) and draw (`:223`); `seedPrice` stamps
   `block.timestamp`, so two same-lien seeds in one block collide on equal `ts` and the second reverts `StaleReport()`.
   This is exactly the H1 seed-clobber the kill-list asked to close. In production origination/draw are separate
   Keystone reports in separate blocks, so it is benign — but it is a real **operational constraint on CRE-01** (logged
   in PROGRESS open obligations + the CRE-01 backlog row). If the reviewer wants origination+draw co-located in one
   block to remain legal, the seed path would need a real ts (not `block.timestamp`) — deliberately NOT done here
   (the ticket pins `<=` in the shared `_writePrice`).
2. **Duplicate-lien batch now fails closed.** A single rt-3 batch listing the same lien twice shares one `ts`, so the
   second write is a same-ts replay → the all-or-nothing batch reverts. Previously last-write-won. The test
   `test_DuplicateLiensLastWriteWins` was repurposed → `test_DuplicateLiensInBatchRevertStale`. A well-formed CRE report
   never lists a lien twice; fail-closed is the safer behavior. Flagging in case any producer relied on dedup-by-batch.

## Holes found → resolution
- **6 pre-existing tests asserted same-ts/backdated-replay SUCCESS** (the old vulnerable behavior). Resolution: faithful
  forward-warps (`vm.warp(block.timestamp + 1)`) — a separate CRE report lands in a later block with a strictly-newer
  `ts`. 3 oracle units (`ZipcodeOracleRegistry.t.sol`: `test_RevaluationOverwritesSeed`, `test_NoValueBand_BigDrop_
  Succeeds`, the renamed duplicate test; `SzipNavOracle.t.sol`: `test_deviation_within_bound_ok`, `test_batch_atomicity_
  one_bad_entry_reverts_all`, `test_lp_marked_through`) + 3 integration (`ZipcodeController.t.sol::test_Draw_
  ExactAccrual`, `EulerVenueAdapter.t.sol::test_TwoLine_DistinctPrefix_BothDraw_Isolation`, `ReservoirLoopModule.t.sol::
  test_oracle_non_divisible_floors_against_borrower`).
- **One false pass caught:** `ZipcodeController.t.sol::test_Draw_ReAnchorBelowLTV_RollsBack` used a generic
  `vm.expectRevert()` that was being satisfied by `StaleReport` instead of the intended LTV check. Warped + pinned to
  `EVKErrors.E_AccountLiquidity.selector` so it again exercises the re-anchor-below-LTV rollback. (Net test-quality
  improvement, not just a fixup.)
- **No back-pressure obligation** — every binding existed; the guard is a pure additive write-path check.

## Doc edits
- `build/tickets/sec/SEC-01-…md` — status DONE, added "Downstream test impact" + "Done note" (forge output).
- `build/tickets/PROGRESS.md` — SEC-01 → DONE, SEC-02 → NEXT, "Just done — SEC-01" note, new open obligation (CRE-01
  same-block seed constraint), CRE-01 backlog row annotated.

## Status + NEXT
SEC-01 DONE, committed with the gate green. **NEXT: SEC-02** — coverage sidecar-LP double-count (kill-list Group 2,
scope `pathLockedLpEquity()` to mainSafe-only in the coverage view). Ticket already authored at
`build/tickets/sec/SEC-02-coverage-sidecar-lp-double-count.md`.
