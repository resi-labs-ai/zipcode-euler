# SEC-06 report — `closeLine` prunes the closed line from the EE supply queue (Group 3a / H2)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-07 (L8 — `closeLine`
line→base USDC defund)

## What the window did
Closed kill-list **H2** (audit finding #2 / ref-B / interconnection-C, 4× independently derived). `openLine` appends
every freshly-minted per-line borrow EVAULT to the EulerEarn supply queue (`EulerVenueAdapter.sol:227-233`) so `fund`
can route USDC into it, but `closeLine` never removed it. The queue therefore grew **monotonically in cumulative line
count** toward the hard `MAX_QUEUE_LENGTH = 30` cap (`reference/euler-earn/.../ConstantsLib.sol:17`); once ~29 lifetime
lines existed, the next `openLine`'s `setSupplyQueue` reverted `MaxQueueLengthExceeded` — and did so *after* the CREATE2
LineAccount, both EVK proxies, the router, and the cap submit/accept had already run, so **origination bricked
permanently and unrecoverably** even with most lines long since closed.

**Fix (1 contract file, `EulerVenueAdapter.sol:357-373`):** after the existing collateral redeem (`:350-356`) and
before `L.open = false`, `closeLine` rebuilds the supply queue into a `qlen - 1` array, skipping the entry whose
address `== lineRef` (**by address match — not last-position**, because interleaved opens/closes move it), and calls
`eulerEarn.setSupplyQueue(newQueue)`. This is the symmetric un-do of the `openLine` append. The redeem and
`L.open = false`/`LineClosed emit` are untouched (purely additive). Queue length is now bounded by **concurrent**, not
cumulative, open lines.

## Decisions to sanity-check
1. **Address-match prune, `qlen-1` array.** I do not assume `lineRef` is the last queue entry (it isn't, once
   opens/closes interleave) — I scan and skip by address. If `lineRef` were somehow absent from the queue, the
   `qlen-1` array would overflow on the final write and revert; that can't happen because `openLine` appends it exactly
   once and nothing else removes it (invariant holds). Worth a reviewer eye.
2. **No cap-revoke / withdraw-queue / timelock.** Pruning the **supply** queue alone is sufficient: `setSupplyQueue`
   only requires `cap != 0` on every entry of the *new* queue (`EulerEarn.sol:330-332`) and never inspects the removed
   market's balance, so no removal-timelock path is needed. The spec-fidelity critic confirmed the redeem-before-prune
   ordering is an **SEC-07 convenience, not an H2 correctness precondition**.
3. **Faithful mock change (test infra).** `MockEulerEarn.setSupplyQueue` previously enforced nothing, so the churn
   regression could not fail pre-fix. I made it faithful (revert `MaxQueueLengthExceeded` at `length > 30`, mirroring
   `EulerEarn.sol:328`) + added a `queueContains(address)` view helper. This is a test-only change; the live EE path is
   the audit S9/L4 integration.

## Holes → resolution
- **Critic-flagged (reference-verifier #4):** the mock enforced no queue cap → churn test would pass with or without
  the fix. **Resolved** by making the mock faithful (above); fail-before now genuinely fails.
- **Churn test demonstrates the bound, not the raw revert.** The `test_SEC06_NoBrickAcrossChurnPastQueueCap` asserts a
  bounded queue + all-opens-succeed (the exact done-when requirement); pre-fix it fails on the in-loop bounded-length
  assert (which trips one cycle before the `MaxQueueLengthExceeded` brick the faithful mock would otherwise raise at the
  30th open). The revert mechanism itself is proven real by the faithful mock + the reference verification.

## Doc edits (full doc-sync run)
- **Ticket** `build/tickets/sec/SEC-06-closeline-queue-prune.md` → Status DONE + DONE-note with quoted `forge test`.
- **PROGRESS.md** → SEC-06 row DONE, SEC-07 set NEXT (new NEXT block), "Just done — SEC-06" note, header tally updated.
- **kill-list.md** → H2 `[ ]`→`[x]` + `DONE 2026-06-15 (SEC-06)`.
- **audit-claude** → finding #2 RESOLVED (header + `fix:` line in `findings.md`); `SUMMARY.md` H2 row `✅` + RESOLVED;
  `role-based-findings.md` cross-confirmation #2 RESOLVED.
- **wires/WOOF-04.md** (owner of `EulerVenueAdapter.sol` per `COVERAGE.md`) → `closeLine` behavior entry now documents
  the prune; allocator-role note updated.
- **No `claude-zipcode.md` spec change** — interface-level fix; §4.7 intent unchanged (queue management is already the
  adapter's allocator role). **No back-pressure / no new obligation.** The standing concurrent-line-ceiling obligation
  is unchanged (already cross-references SEC-06).

## Gate
```
forge build — clean
Ran 52 test suites in 30.05s (93.86s CPU time): 784 tests passed, 0 failed, 3 skipped (787 total tests)
```
3 new `test_SEC06_*` (+3 over SEC-05's 781). 3 skips = pre-existing `DeployZipcode.t.sol` scaffold. Fail-before/
pass-after confirmed.

## Status + NEXT
SEC-06 DONE. **NEXT: SEC-07** (L8 — add a line→base USDC defund `reallocate` to `closeLine`, sequenced BEFORE this
prune so the removed market is empty; Group-3 sibling, same fn, distinct fix).
