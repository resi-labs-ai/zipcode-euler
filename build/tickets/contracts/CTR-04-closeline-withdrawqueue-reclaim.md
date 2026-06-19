# CTR-04 — closeLine reclaims the binding withdraw-queue slot

> Contract-track change (EXPANSION / correctness). Fixes a verified gap: `EulerVenueAdapter.closeLine` prunes only
> the SUPPLY queue and leaves the line's EE cap at max, so the **binding WITHDRAW-queue slot is never reclaimed** — a
> pool bricks after ~28 *lifetime* opens, not ~28 *concurrent*. This makes a closed repo line free its withdraw-queue
> slot so one pool churns 28 *concurrent* lines. (Revolving structure-2 lines reuse a slot natively; this is for
> structure-1 / repo lines.)
> Spec: `claude-zipcode.md` §4.7 (venue adapter / Euler = config one; load-bearing) + §4.5 (warehouse supply, secondary).
> **Open decision B (locked: fix it).** Discharges PROGRESS **finding 1**.

## Why (the verified seam)
`EulerVenueAdapter.closeLine` (`contracts/src/venue/EulerVenueAdapter.sol:367-427`) rebuilds the SUPPLY queue
skipping the closed vault (SEC-06, `:415-423`) and explicitly leaves the cap at `type(uint136).max` ("never revoked",
`:392-393`). But the hard `> MAX_QUEUE_LENGTH (30)` cap fires on the WITHDRAW queue inside `_setCap` when a market is
first enabled (`reference/euler-earn/src/EulerEarn.sol:785`, reached from `acceptCap`→`_setCap` at `:507,772,783`).
`closeLine` never removes the line's market from the withdraw queue, so the slot stays consumed forever and the ~29th
*lifetime* `openLine`'s `acceptCap` reverts `MaxQueueLengthExceeded` — even though most lines are long closed.

The supply-queue prune does NOT help: the supply and withdraw queues are independent arrays (`EulerEarn.sol:92,95`),
each capped at 30 (`setSupplyQueue:328`, `_setCap:785`). SEC-06 fixed the supply side; the binding side is the
withdraw queue.

## Deliverable

### (A) Contract — extend `closeLine` (`EulerVenueAdapter.sol:367-427`), AFTER the existing defund + supply-prune
A single **inline** sequence (NO `reapLine`, NO `submitMarketRemoval`, NO timelock branch — see "Why inline only"):
1. `eulerEarn.submitCap(IOZERC4626(lineRef), 0);` — zero the line's EE cap. A cap DECREASE applies **immediately**
   via `_setCap` with no timelock (`EulerEarn.sol:298-299`); the removal guard `:362` requires `cap == 0`.
2. Build `keepIndexes` = every current withdraw-queue index whose market `!= lineRef`, in order (the withdraw-queue
   analog of the supply-prune rebuild at `:415-423`). Read the queue via `eulerEarn.withdrawQueueLength()` +
   `eulerEarn.withdrawQueue(i)`.
3. `eulerEarn.updateWithdrawQueue(keepIndexes);` — `updateWithdrawQueue(uint256[] indexes)` takes the indexes to
   KEEP; any current index NOT listed is removed (`EulerEarn.sol:340-380`). The removed `lineRef` passes the removal
   guards (`:362-371`): `cap == 0` (step 1), `pendingCap.validAt == 0` (none), and `expectedSupplyAssets == 0` (the
   prior defund `:398-405` emptied it) → the `removableAt`/timelock sub-block (`:365-371`) is **skipped entirely** and
   `delete config[lineRef]` runs. Keep the base USDC market (and any reservoir/resting market) — only `lineRef` drops.

### Why inline only (the design finding — verified, do not re-add the two-path)
`submitMarketRemoval` + a deferred `reapLine` keeper step + a `eulerEarn.timelock()` branch are **dead code** here.
Removal of an *empty* market never engages the EE timelock: `updateWithdrawQueue`'s `removableAt`/timelock guard
(`:366-370`) sits inside `if (expectedSupplyAssets(id) != 0)` (`:365`). `closeLine` **mandatorily defunds the line to
zero** before the prune (the `assets:0` full-redeem leg `:398-405` drives `config[lineRef].balance → 0`, so
`expectedSupplyAssets(lineRef) = previewRedeem(0) = 0`, `EulerEarn.sol:492`). So the guard block is unreachable for
*any* timelock value — including the narrow case where the external EE owner RAISED the timelock after lines were
opened. `submitMarketRemoval` is only needed to remove a market that still holds supply; we never do. Cutting the
two-path removes an external method, a branch, and a test fixture for a path that cannot trigger.

### (B) Test — extend `MockEulerEarn` in `contracts/test/EulerVenueAdapter.t.sol`
The mock today models only the SUPPLY queue (`_queue` + the `:124-132` `MaxQueueLengthExceeded` cap) and hardcodes
`config().cap = type(uint136).max, removableAt = 0` (`:101-103`). To make the binding withdraw-queue brick + its fix
provable, extend the mock **faithfully to the real EE** (it already mirrors `reallocate`/`setSupplyQueue`):
1. **Per-market cap tracking.** Add `mapping(address => uint136) cfgCap`. `submitCap(id, cap)` records `cfgCap[id] =
   cap` (decrease/zero is immediate, matching `_setCap`'s decrease branch). `config()` returns `cfgCap[id]` (not the
   hardcoded max). openLine submits `type(uint136).max`, so a line's cap is max until closeLine's `submitCap(0)`.
2. **Withdraw queue.** Add `IOZERC4626[] _withdrawQueue`. On a market's first enable (a shared internal helper called
   by BOTH `acceptCap` and the base/reservoir `seedConfig` enable paths, guarded against double-push), push it and
   enforce `if (_withdrawQueue.length > MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded();` — mirroring
   `_setCap:783-785`. This is the BINDING cap; the existing supply-queue cap stays.
3. **Getters** `withdrawQueue(uint256)` + `withdrawQueueLength()`.
4. **`updateWithdrawQueue(uint256[] indexes)`** faithful to `EulerEarn.sol:340-380`: keep-indexes semantics; for each
   removed index assert `cfgCap[id] == 0` (else revert, mirror `InvalidMarketRemovalNonZeroCap`) and, if
   `expectedSupplyAssets(id) != 0`, require `removableAt` elapsed (mock has `removableAt==0`/no pending, so empty
   markets remove freely); then clear the market's config (`cfgEnabled=false`, `cfgCap=0`, `cfgBalance=0`); rebuild
   `_withdrawQueue`.

## Spec §
`claude-zipcode.md` §4.7 (load-bearing — the venue adapter / Euler = config one boundary), §4.5 (secondary). SEC-06
reclaimed the non-binding SUPPLY queue; CTR-04 completes the reclaim on the BINDING WITHDRAW queue.

## Binds to (verified — every signature confirmed against the cited line)
- `EulerEarn.submitCap(IERC4626,uint256)` (`reference/euler-earn/src/EulerEarn.sol:287`; decrease is immediate `:298-299`),
  `updateWithdrawQueue(uint256[])` (`:340`, keep-indexes), removal guards (`:362-371`), `withdrawQueueLength()` (`:482`,
  **confirmed exists** — the supply analog of `supplyQueueLength()`), `withdrawQueue(uint256)` (public array `:95`),
  `expectedSupplyAssets(IERC4626)` (`:492` = `previewRedeem(config.balance)`, identical to the adapter's
  `_eeSupplyAssets` `:295-296`), `_setCap` withdraw-push + cap (`:783-785`). All declared on the `IEulerEarn` interface
  the adapter imports (`euler-earn/interfaces/IEulerEarn.sol`: `withdrawQueue:63`, `withdrawQueueLength:66`,
  `submitCap`, `updateWithdrawQueue`, `expectedSupplyAssets:74`).
- **Cast type:** use `IOZERC4626` — the adapter's alias `import {IERC4626 as IOZERC4626}` (`EulerVenueAdapter.sol:13`),
  the SAME OZ `IERC4626` the `IEulerEarn` interface params use. openLine already casts EE ids with `IOZERC4626(...)`
  (`:235,242`). Do NOT use `IEVKERC4626` (the EVK alias) for EE calls.
- The as-built `closeLine` (`:367-427`) + its supply-queue rebuild idiom (`:415-423`) to mirror for the withdraw side.
- Roles: the adapter is the EE **curator** (`DeployLocal.s.sol:147`); `submitCap` is `onlyCuratorRole` (`:287,146-151`)
  and `updateWithdrawQueue` is `onlyAllocatorRole` (`:340,154-160`) which **admits the curator** (`:156`). No new role
  grant owed. (openLine already calls `submitCap`/`setSupplyQueue` successfully, confirming both roles resolve.)

## Starting state
- `closeLine` defunds (`:398-405`) + prunes supply queue (`:415-423`) + flips `open=false`; the EE config cap is still
  `type(uint136).max` (openLine `:235`; `setLineLimits` `:282` touches only the EVK vault's OWN caps, NOT the EE
  config cap — so `submitCap(0)` is always a valid `max→0` decrease, never `AlreadySet`); the line's market is still in
  the withdraw queue.
- `MockEulerEarn` models only the supply queue; the withdraw-queue lifecycle does not exist yet.

## Do NOT
- Do NOT add `reapLine`, `submitMarketRemoval`, or an `eulerEarn.timelock()` branch — proven dead code (above).
- Do NOT remove the existing defund (`:398-405`) — removal needs the market empty.
- Do NOT assume the line is the last withdraw-queue entry — match by ADDRESS (interleaved opens/closes move it),
  like the supply-queue rebuild.
- Do NOT break the existing supply-queue prune, the `open=false` record-keep, or any existing SEC-06/SEC-07/SEC-11 test.
- Do NOT add a registry call here — `decrementLineCount` lives in the CONTROLLER (CTR-03), not the adapter. CTR-04
  makes the *physical* withdraw-queue slot reclaim match the controller's already-existing counter decrement.

## Key requirements
1. **Binding slot freed.** After close, `withdrawQueueLength()` drops by one and a fresh `openLine` succeeds where it
   would previously have reverted `MaxQueueLengthExceeded` — proven by churning past the cap (recycling the single
   1e18 lien, like the existing `test_SEC06_NoBrickAcrossChurnPastQueueCap`).
2. **Inline, timelock-independent.** One sequence, same transaction, no keeper follow-up. The removed market is empty
   (defunded), so removal never waits on the EE timelock.
3. **Empty-before-remove.** The defund precedes removal; the removed market carries no EE balance.
4. **Counter/queue consistency.** After CTR-04 the controller's `decrementLineCount` (CTR-03) corresponds to a truly
   freed withdraw-queue slot — the registry count and the actual queue length stay consistent. (No code added here;
   this is the property CTR-04 restores.)

## Done when (gate — `forge test`)
- `forge build` green.
- `contracts/test/EulerVenueAdapter.t.sol` updated + green, with NEW cases:
  - `MockEulerEarn` extended (per-market cap, withdraw queue + `:785` cap, getters, `updateWithdrawQueue` guards).
  - **Brick-without-fix is real:** a test (or an asserted pre-fix expectation) showing the withdraw queue would hit 30
    and `MaxQueueLengthExceeded` on the ~29th lifetime open absent the reclaim. (May be expressed by temporarily not
    pruning, or by an inline comment + the churn test below standing as the regression.)
  - **Concurrent reuse:** open to the cap, close one, open another succeeds; `withdrawQueueLength()` decremented.
  - **Churn past the cap:** recycle the single lien through > MAX_QUEUE_LENGTH open/close cycles without bricking.
  - **Removal guards respected:** the removed market had `cap==0` (submitCap 0) and zero EE balance (defunded).
  - All existing EulerVenueAdapter tests still pass.
- Cold-build with ZERO load-bearing guesses.

## Conclude doc-sync (backward + forward truth-sources)
- **`docs/wires/WOOF-04.md`** (EulerVenueAdapter — via `COVERAGE.md`): update the `closeLine` behavior/guard list to
  include the withdraw-queue reclaim (submitCap 0 + updateWithdrawQueue), and note both queues are now pruned on close.
- **`build/tickets/PROGRESS.md`**: mark CTR-04 DONE; set next `NEXT` (CTR-05 or CTR-07 per reviewer); mark **finding 1
  RESOLVED**; update the CTR-03 DONE-note caveat and the "RESOLVED INTO A WORKSTREAM" note (lines ~374-376) — "~28
  *lifetime*, not concurrent, until CTR-04" becomes "28 *concurrent* (CTR-04 landed)".
- No `claude-zipcode.md` change required (§4.7/§4.5 already correct; federation narrative is forward doc-sync).

## Depends on / unblocks
- **Depends on:** nothing hard (independent of CTR-02/03; pairs with CTR-03's decrement).
- **Unblocks:** true 28-*concurrent*-line reuse per pool (repo lines), reducing how fast sharding (CTR-06) must roll over.
