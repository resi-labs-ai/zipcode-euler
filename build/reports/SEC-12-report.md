# SEC-12 report — `ZipRedemptionQueue.redeem()` emits canonical shares (L11)

**Date:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-13

## What this window did
Fixed an event-correctness bug: `ZipRedemptionQueue.redeem(shares,...)` pays `assets = shares / scaleUp` USDC at
par (floor division) but emitted the **raw** caller-supplied `shares` in its `Withdraw` event. On a sub-unit-excess
input (e.g. `redeem(scaleUp + scaleUp/2)` → `assets == 1`) the event reported `shares == 1.5·scaleUp` while only
`scaleUp`-worth was actually redeemed — overstating the figure and disagreeing with the paid `assets`. The sibling
`withdraw` already emits the canonical `assets * scaleUp`; `redeem` now matches.

**Fix (1 file, `contracts/src/supply/ZipRedemptionQueue.sol`):** inserted `shares = assets * scaleUp;` in `redeem`
after the `:240-242` guards and before the `:248` `emit Withdraw(...)`, mirroring `withdraw`'s `:221`. Event-field-only
— `assets`, the transfers, `claimableAssets`/`reservedAssets` effects, and the return value are byte-for-byte
unchanged. No `% scaleUp` revert guard added (Do-NOT honored). USDC out was always correct; this is a pure
feed/accounting-drift fix with no solvency impact.

## Decisions to sanity-check
- **Recompute, not guard.** The kill-list L11 `Fix:` line explicitly prefers recomputing `shares = assets * scaleUp`
  over adding a `shares % scaleUp != 0` revert guard, because the guard would reject currently-accepted inputs. The
  spec-fidelity critic verified this verbatim. The accepted-input surface is therefore unchanged.
- **Floor semantics preserved.** `redeem(shares < scaleUp)` still reverts via the `assets == 0` guard (`:241`); a
  sub-unit *excess* still redeems the floored whole units. The recompute only corrects the emitted figure.
- **Overflow non-issue.** `scaleUp = 1e12` (`uint256`, 18/6 dp); `assets = shares / scaleUp ≤ shares`, so
  `assets * scaleUp ≤ shares` — the product cannot exceed the original input magnitude, and Solidity 0.8 reverts
  (not wraps) on overflow regardless. Confirmed by the reference-verifier critic.

## Holes → resolution
- **Test-fixture funding** (junior-dev critic's closest-to-blocking item): how to fund `claimableAssets` as the
  single requester. **Resolved** — the existing `_fullFillAlice` helper drives `_giveZip → requestRedeem →
  _deliverUsdc → _settle`, leaving `claimableAssets[alice]` set, exactly the settle path the ticket named. No fixture
  gap; no net-new mock infra needed.
- **No other holes.** All three critics ran clean with zero line drift between the ticket and the contract.

## Doc edits (doc-sync-checklist)
1. **Ticket** `build/tickets/sec/SEC-12-redeem-canonical-shares-event.md` — status → DONE, Done-note with quoted
   gate output added.
2. **PROGRESS.md** — SEC-12 row → DONE, SEC-13 set NEXT (NEXT block + SEC-track status note + table), "Just done —
   SEC-12" note added.
3. **kill-list.md** — L11 `[ ]` → `[x]` + `DONE 2026-06-15 (SEC-12)`.
4. **audit-claude/reference-diff-findings.md** — B9 marked `✅ RESOLVED 2026-06-15 (SEC-12)` (single reference; no
   summary-table duplicate).
5. **wires/9-ZipRedemptionQueue.md** — the `withdraw`/`redeem` behavior paragraph + the Events list now document
   both claim paths emitting the canonical `assets * scaleUp` (the changed-contract truth-source, per COVERAGE.md).
6. **No spec change** — interface-level event-correctness fix; `claude-zipcode.md` §12 senior-exit intent unchanged
   (`redeem` is a par claim path; only the emitted figure was wrong).
7. **No back-pressure / no new obligation** — uses existing surfaces; no contract surface owed.

## Gate
- `forge build` clean.
- `forge test`: **806 passed / 0 failed / 3 skipped** (+3 over SEC-11's 803; the 3 skips are the pre-existing
  `DeployZipcode.t.sol` scaffold).
- 3 new `test_SEC12_*` in `test/ZipRedemptionQueue.t.sol` (sub-unit-excess canonical emit; clean-multiple unchanged;
  return value unchanged).
- **Fail-before/pass-after confirmed** — removing the one-line recompute makes the sub-unit-excess test FAIL
  (`log != expected log`); restored → `[PASS] (gas: 302552)`, full suite green.

## Status + NEXT
SEC-12 DONE. **NEXT: SEC-13** — `postBid` `validTo` anchored to `min(required leg.ts) + maxAge` (+ a new additive
`SzipNavOracle.oldestRequiredLegTs()` view), spanning two of our own contracts. Ticket already authored:
`build/tickets/sec/SEC-13-postbid-validto-leg-anchor.md`.
