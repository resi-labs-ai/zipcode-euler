# CTR-04 — closeLine reclaims the binding withdraw-queue slot

> Contract-track change (EXPANSION / correctness). Fixes a verified gap: `EulerVenueAdapter.closeLine` prunes only
> the SUPPLY queue and leaves the line's cap at max, so the **binding withdraw-queue slot is never reclaimed** — a
> pool bricks after ~28 *lifetime* opens, not ~28 *concurrent*. This ticket makes a closed repo line free its slot
> so one pool churns 28 concurrent lines. (Revolving structure-2 lines reuse a slot natively, so this matters for
> structure 1 / repo lines.)
> Spec: `claude-zipcode.md` §4.5/§4.7. **Open decision B (locked: fix it).**

## Why (the verified seam)
`EulerVenueAdapter.closeLine` (`contracts/src/venue/EulerVenueAdapter.sol:407-423`) rebuilds the SUPPLY queue
skipping the closed vault and explicitly leaves the cap at `type(uint136).max` ("never revoked", comment
`:411-414`). But the hard cap fires on the WITHDRAW queue: enabling a market pushes it there and checks `> 30`
(`reference/euler-earn/src/EulerEarn.sol:785`). Removing a market from the withdraw queue requires `config[id].cap
== 0` (`EulerEarn.sol:362`) + `submitMarketRemoval` + the EE timelock + `updateWithdrawQueue`
(`EulerEarn.sol:310,340`). `closeLine` does none of these, so the slot stays consumed forever.

## Deliverable
Extend `EulerVenueAdapter.closeLine` (`:367-427`) — AFTER the existing defund + supply-queue prune — to fully
retire the closed line's market from the withdraw queue:
1. `eulerEarn.submitCap(IOZERC4626(lineRef), 0)` — zero the cap (immediate for a decrease, `EulerEarn.sol:298-299`).
2. `eulerEarn.submitMarketRemoval(IOZERC4626(lineRef))` — set `removableAt = now + timelock` (`:310-317`).
3. The actual `updateWithdrawQueue` removal happens after the EE timelock elapses — so split the lifecycle: either
   (a) a follow-up `reapLine(lineRef)` adapter method the keeper calls once `removableAt` has passed, OR (b)
   document that closeLine starts removal and reap is a separate keeper step. (Pin: with `initialTimelock = 0`
   pools, removal is same-block, so closeLine MAY call `updateWithdrawQueue` inline; for non-zero timelock pools it
   MUST be the two-step reap. Build BOTH paths, gated on `eulerEarn.timelock()`.)
4. `updateWithdrawQueue(indexes)` rebuilds the withdraw queue skipping `lineRef` (the inverse of the supply-queue
   rebuild at `:415-423`); the removed market must have `cap == 0`, no `pendingCap`, and zero `expectedSupplyAssets`
   (the prior defund at `:399-405` already emptied it).

## Spec §
`claude-zipcode.md` §4.5/§4.7. SEC-06 (the supply-queue prune) reclaimed the non-binding queue; this completes the
reclaim on the binding queue.

## Binds to (verified)
- `EulerEarn.submitCap(IERC4626,uint256)` (`reference/euler-earn/src/EulerEarn.sol:287`), `submitMarketRemoval`
  (`:310`), `updateWithdrawQueue(uint256[])` (`:340`), the removal guards (`:362-371`), `timelock()` (`:74`).
- The as-built `closeLine` (`contracts/src/venue/EulerVenueAdapter.sol:367-427`) + its supply-queue rebuild idiom
  (`:415-423`) to mirror.
- `EulerVenueAdapter.eulerEarn.timelock() == 0` is already asserted in `openLine` (`:209`).

## Starting state
- `closeLine` defunds + prunes supply queue + flips `open=false`; cap left at max; market still in withdraw queue.
- Local deploy uses `initialTimelock = 0` (`DeployLocal.s.sol`), so same-block removal is possible there.

## Do NOT
- Do NOT remove the existing defund (`:399-405`) — the market must be empty before removal (`expectedSupplyAssets
  != 0` blocks removal unless `removableAt` is set + elapsed, `:365-371`).
- Do NOT assume the line is the last withdraw-queue entry — match by address (interleaved opens/closes move it),
  like the supply-queue rebuild.
- Do NOT break the existing supply-queue prune or the `open=false` record-keep.
- Do NOT silently rely on `timelock==0` — handle the non-zero case (two-step reap) or the fix is incomplete on
  production pools.

## Key requirements
1. **Binding slot freed.** After close (+ reap, if timelocked), `withdrawQueue.length` drops by one and a fresh
   `openLine` succeeds where it would previously have reverted `MaxQueueLengthExceeded`.
2. **Timelock-aware.** Zero-timelock pools reclaim inline; non-zero pools use the keeper reap step; document which.
3. **Empty-before-remove.** The defund precedes removal; assert the removed market carries no EE balance.
4. **Registry sync.** Pair with `SiloRegistry.decrementLineCount` (CTR-03 calls it on close) so the slot count and
   the actual queue length stay consistent.

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/EulerVenueAdapter.t.sol` updated + green: open to the cap, close one, open
  another succeeds (concurrent reuse proven); withdraw-queue length decremented; removal guards respected;
  zero-timelock inline path AND a non-zero-timelock two-step reap path both covered.
- Cold-build with ZERO load-bearing guesses.

## Implementation pins (resolved from code — the cold-builder guesses NONE of these)
1. **Order, inline (zero-timelock pools, e.g. `DeployLocal`).** AFTER the existing defund (`:399-405`) + supply
   prune (`:415-423`): `eulerEarn.submitCap(IOZERC4626(lineRef), 0)` — a cap DECREASE applies immediately via
   `_setCap`, no timelock (`EulerEarn.sol:298-299`); then `eulerEarn.submitMarketRemoval(IOZERC4626(lineRef))` —
   sets `config[lineRef].removableAt = block.timestamp + timelock` (`:310-317`); then
   `eulerEarn.updateWithdrawQueue(keepIndexes)`.
2. **`keepIndexes` construction.** `updateWithdrawQueue(uint256[] indexes)` takes the indexes to KEEP, in the new
   order; any current index NOT listed is removed (`EulerEarn.sol:340-380`). Build `keepIndexes` = every current
   withdraw-queue index whose market `!= lineRef`, in order (the inverse of the supply-prune rebuild at `:418-422`).
   Read the queue via the public array getter `eulerEarn.withdrawQueue(i)` (confirm the exact length getter; the
   supply side uses `supplyQueueLength()`/`supplyQueue(i)` — verify the withdraw analog or track length locally).
   **Keep the resting + reservoir markets in the list** — only `lineRef` is dropped.
3. **Removal guards are satisfied** (`EulerEarn.sol:362-371`): `config[lineRef].cap == 0` (step-1 submitCap 0);
   `pendingCap[lineRef].validAt == 0` (none); `expectedSupplyAssets(lineRef) == 0` (the defund at `:399-405`
   emptied it). So removal passes without waiting in the zero-timelock case.
4. **Timelock>0 → two-step reap.** When `eulerEarn.timelock() != 0`, `closeLine` does only steps 1-2 (submitCap 0 +
   submitMarketRemoval); add a new `reapLine(address lineRef) external onlyController` that calls
   `updateWithdrawQueue(keepIndexes)` once `block.timestamp >= config[lineRef].removableAt`. Branch on
   `eulerEarn.timelock()` to pick inline vs deferred. (`openLine` already asserts `timelock()==0` at origination,
   `:209`, so M1 pools are inline; the reap path is for production pools with a non-zero timelock.)
5. **Registry sync.** Pair with `SiloRegistry.decrementLineCount` (CTR-03 calls it on `_close`) so the slot count
   matches the actual withdraw-queue length.

## Depends on / unblocks
- **Depends on:** nothing hard (independent of CTR-02/03, but pairs with CTR-03's decrement).
- **Unblocks:** true 28-*concurrent*-line reuse per pool (repo lines), reducing how fast sharding must roll over.
