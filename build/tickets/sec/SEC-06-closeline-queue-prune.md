# SEC-06 — `closeLine` prunes the closed line from the EE supply queue (Group 3a / H2)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / H2; audit `findings.md` (H2);
`reference/euler-earn/src/EulerEarn.sol` (`setSupplyQueue`), `.../libraries/ConstantsLib.sol` · **Status:** DONE 2026-06-15

> Scope authored 2026-06-15. Group 3 (Euler venue) splits into THREE distinct `closeLine`/`fund` fixes: H2
> (this ticket — supply-queue prune), L8 (SEC-07 — line→base USDC defund), L9 (SEC-11 — `fund` sizing). H2 and
> L8 both live in `closeLine` but neither subsumes the other (queue-prune vs USDC-reclaim). This ticket is H2 only.

## Deliverable
Remove the closed line's borrow EVAULT from the EulerEarn supply queue inside `closeLine`, so the queue does
not grow unboundedly and origination cannot permanently brick.

## What it does / what's being fixed (plain language)
Every `openLine` onboards a fresh per-line borrow vault and **appends** it to the EE pool's supply queue so
`fund` can route USDC into it. `closeLine` redeems the collateral and marks the line closed but **never removes
that vault from the queue**. The supply queue is hard-capped at `MAX_QUEUE_LENGTH = 30`; once ~29 lines have
been originated the next `openLine`'s `setSupplyQueue` reverts `MaxQueueLengthExceeded` and **origination is
permanently bricked** — even though most of those lines are long since closed.

## Binds to (verified file:line — 2026-06-15)
- **The unbounded append:** `contracts/src/venue/EulerVenueAdapter.sol:227-233` — `openLine` reads
  `supplyQueueLength()`, copies the queue into a `qlen+1` array, appends the new `evault`, and calls
  `eulerEarn.setSupplyQueue(newQueue)`.
- **The missing prune:** `contracts/src/venue/EulerVenueAdapter.sol:343-360` — `closeLine` redeems the escrow
  collateral (`:350-356`) and sets `L.open = false` (`:358`); no supply-queue edit.
- **Reference truth:** `reference/euler-earn/src/EulerEarn.sol:325-337` — `setSupplyQueue(IERC4626[])` is
  `onlyAllocatorRole` (the adapter already holds it — it calls this in `openLine`), reverts
  `MaxQueueLengthExceeded` when `length > MAX_QUEUE_LENGTH`, and requires `config[market].cap != 0` for **every
  entry of the new queue**. It does NOT require the removed market to be empty or timelocked (that constraint is
  on `updateWithdrawQueue` / cap revocation, not the supply queue). `MAX_QUEUE_LENGTH = 30` —
  `reference/euler-earn/src/libraries/ConstantsLib.sol:17`.

## Key requirements
1. In `closeLine`, after the line is confirmed closeable (`:345-346`), rebuild the supply queue **excluding
   `lineRef`** and call `eulerEarn.setSupplyQueue(newQueue)` — mirror the `openLine` copy loop (`:227-233`) but
   into a `qlen - 1` array, skipping the entry whose address `== lineRef`.
2. Every remaining entry still has `cap != 0` (base market + other open lines), so the EE `cap != 0` check
   passes — no cap change / timelock / `updateWithdrawQueue` needed.
3. Keep the existing collateral redeem (`:350-356`) and `L.open = false` (`:358`) exactly as-is; this is an
   additive prune.

## Do NOT
- Do NOT revoke the closed market's cap or touch the **withdraw** queue — pruning the **supply** queue is
  sufficient and avoids the timelocked cap-revocation path. (The closed vault retains a zero balance after the
  redeem; if any balance remains, that is L8/SEC-07's defund, not this ticket.)
- Do NOT change `openLine`'s append.
- Do NOT assume `lineRef` is the last queue entry — search for it (other opens/closes interleave); skip by
  address match.
- Do NOT widen scope to L8 (USDC defund) or L9 (`fund` sizing) — separate SEC tickets; see the ordering note below.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC06_*` regression test** that fails before / passes after:
  - **Prune happens:** open a line, assert it is in `eulerEarn.supplyQueue`; `closeLine` it; assert the vault is
    **absent** and `supplyQueueLength()` dropped by exactly 1 (pre-fix it stays).
  - **No brick across churn:** an open→close loop run **more than `MAX_QUEUE_LENGTH` (30) total originations**,
    closing each line before the next, keeps `supplyQueueLength()` bounded and every `openLine` succeeds
    (pre-fix the ~29th open reverts `MaxQueueLengthExceeded`).
  - **Other open lines untouched:** with two lines open, closing one leaves the other in the queue and `fund`able.
- Quote the actual `forge test` output in this ticket's done note. (An adapter/smoke test fixture exists — extend it.)

## Depends on
- None. **Ordering note for SEC-07 (L8):** when both land, `closeLine` should defund the line leg back to base
  (SEC-07) and prune the supply queue (this ticket) in the same call; do the prune AFTER the redeem/defund so the
  removed market is empty. Independent correctness, shared function. On land: `PROGRESS.md` "Just done — SEC-06".

---

## DONE 2026-06-15

**Fix (1 file, `contracts/src/venue/EulerVenueAdapter.sol`):** after the existing collateral redeem (`:350-356`)
and before `L.open = false`, `closeLine` now rebuilds the EE supply queue into a `qlen - 1` array, skipping the
entry whose address `== lineRef` (by **address match** — does not assume last position), and calls
`eulerEarn.setSupplyQueue(newQueue)` (the symmetric un-do of `openLine`'s `:227-233` append). The redeem and
`L.open = false`/`LineClosed` are untouched (additive prune). No cap-revoke / withdraw-queue / timelock path —
every surviving entry keeps `cap != 0`, so EE's per-entry check passes; the just-redeemed line carries no balance.

**Critics ran clean.** spec-fidelity **PASS** (faithful to H2, no invented mechanism, Do-NOTs correct, the
redeem-before-prune ordering is an SEC-07 convenience not an H2 correctness precondition since `setSupplyQueue`
never inspects the removed market's balance — `EulerEarn.sol:328-332`). reference-verifier: bindings exist+usable
(`IEulerEarn.{supplyQueueLength,supplyQueue,setSupplyQueue}` at `IEulerEarn.sol:58/55/156`; `MAX_QUEUE_LENGTH==30`
at `ConstantsLib.sol:17`; `setSupplyQueue` checks `cap!=0` on the NEW queue only, no removal/timelock) — **and
flagged the one actionable gap:** `MockEulerEarn.setSupplyQueue` enforced nothing, so the churn regression could
not fail pre-fix. Resolved by making the mock faithful (revert `MaxQueueLengthExceeded` at `length > 30`, mirroring
`EulerEarn.sol:328`) + a `queueContains(address)` view helper.

**Regression (3 new `test_SEC06_*` in `test/EulerVenueAdapter.t.sol`, section (N)):**
- `test_SEC06_CloseLine_PrunesSupplyQueue` — open → queue `[base, line]` (len 2); close → queue `[base]` (len 1),
  line absent.
- `test_SEC06_CloseLine_LeavesOtherOpenLineFundable` — two lines open `[base, A, B]`; close A → `[base, B]`, B
  retained, B still `fund`able (reallocate succeeds).
- `test_SEC06_NoBrickAcrossChurnPastQueueCap` — 33 open→close cycles (>30, single `LIEN_A` recycled via the close
  redeem); queue stays bounded at `[base, line]`/`[base]` every cycle and every `openLine` succeeds.

**Fail-before / pass-after confirmed** — with the prune reverted (faithful mock + tests kept) all 3 fail
(`queue dropped to [base]: 2 != 1`, `queue = [base, B]: 3 != 2`, `queue back to [base]: 2 != 1`); restored → all pass.

**Gate green:** `forge build` clean; `forge test`:
```
Ran 52 test suites in 30.05s (93.86s CPU time): 784 tests passed, 0 failed, 3 skipped (787 total tests)
```
(+3 over SEC-05's 781 — the 3 new SEC06 tests; the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold.)

**No spec change** (interface-level fix; §4.7 intent unchanged — the spec already prescribes queue management as the
adapter's allocator role; this fences the missing un-do of the `openLine` append). **No back-pressure / no new
obligation** (uses EE's existing `setSupplyQueue` surface, which the adapter already drives in `openLine`). The
standing **concurrent-line-ceiling** design obligation is unchanged — SEC-06 reclaims *closed*-line slots only, not
the ~29 *concurrent* ceiling.
