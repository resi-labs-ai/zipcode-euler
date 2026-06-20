# CTR-14 — multi-tranche redemption topology (N junior Safes vs the single-requester shared queue)

> Scoping / decision ticket (not yet built). Spec: `claude-zipcode.md` §4.7 (federation) / §6.1 (senior par
> redemption) / §11 (mutualized senior). Contracts (truth): `ZipRedemptionQueue.sol`, `OffRampModule.sol`,
> `SiloRegistry.sol`. Surfaced 2026-06-20 while reviewing CRE-02. Relates to CRE-02c (the funding-side solver).

## The gap (plain)
The senior off-ramp was built as **single-requester, single-Safe treasury plumbing**, but the federation
(`SiloRegistry`, CTR-02) admits **N silos** — and each product/silo plausibly has its **own junior tranche Safe**.
The two were never reconciled. Concretely, as-built:

1. **`OffRampModule` is pinned to ONE Safe.** It is a `ModuleProxyFactory` clone whose `avatar == target ==
   juniorTrancheSafe` is fixed in `setUp` (`OffRampModule.sol` — `avatar = target = juniorTrancheSafe_`). So a second
   junior Safe cannot share one OffRampModule — each junior Safe needs its **own** OffRampModule clone. There is no
   single shared off-ramp.
2. **The shared queue is single-requester and hard-reverts a second requester.** `ZipRedemptionQueue` sets
   `pendingRequester` on the first escrow and **reverts `MultipleRequesters`** if a *different* requester escrows
   while anything is still pending (`ZipRedemptionQueue.sol:181-185`). `redeemController` is **one** address
   (the rq Safe; `setRedeemController` is `onlyOwner`, single-valued). So two junior Safes **cannot concurrently**
   escrow into the one shared queue — the second reverts until the first fully drains.

So today: multiple products → multiple junior Safes → multiple OffRampModule clones → but **one shared,
single-requester queue** that only lets **one** of them have pending at a time. The federation's senior is
mutualized/fungible (one zipUSD, one queue, §11), yet the redemption *entry* is serialized to a single Safe.

## Why it matters
If each product runs its own szipUSD buy-burn, each junior Safe needs to convert its own zipUSD → USDC. Through
one single-requester queue they must **serialize** (Safe B waits until Safe A's pending drains to zero), which
throttles per-product redemption funding and couples unrelated products' buyback cadence. Not a fund-safety bug
(par is fixed, non-sweepable, the `MultipleRequesters` guard fails closed) — a **throughput / liveness +
fairness** limit, and a latent foot-gun (a second product's escrow silently reverting).

## The decision (resolve at scoping — the fork)
- **(a) Serialize through the one shared queue (accept the limit).** Document that junior Safes redeem one-at-a-time
  through the single queue; the CRE-02c solver + ops sequence them. Cheapest; fine if per-product redemption is
  low-frequency treasury plumbing (which it is in M1). No contract change.
- **(b) One queue per junior tranche.** Each silo/product deploys its own `ZipRedemptionQueue` + OffRampModule;
  `WarehouseAdminModule.redemptionBox` becomes per-silo. Restores concurrency; multiplies deploy surface +
  fragments the senior sink (re-examine the §11 "one shared queue / fungible senior" intent — this partially
  un-mutualizes the senior exit).
- **(c) Make the queue multi-requester.** Relax `ZipRedemptionQueue` to track per-requester pending + settle
  per-requester (restore the pro-rata/era engine that was collapsed out 2026-06-13, `9-ZipRedemptionQueue.md`
  "COLLAPSED"). Biggest contract change; re-opens the trust surface the single-requester collapse deliberately
  closed (par-at-1:1 is sound ONLY because treasury-internal). **Only if** real concurrent multi-tranche demand
  is wanted.
Recommendation to weigh: **(a) for M1** (serialize; it's treasury-internal, low-frequency — the single-requester
guard is a feature, not a bug, at this scale), revisit (b) when a second product's redemption cadence actually
contends. Pin which at scoping.

## Status — option (a) keeper-half PREPARED (2026-06-20, CRE-02-R1)
The keeper side of (a) is built ahead of federation: `RedemptionJob`'s escrow leg now reads
`queue.pendingRequester()` and fires only when the queue is free for its Safe (`pendingRequester == 0 || ==
rqSafe`) — so when a second junior Safe shares the one queue, each keeper waits its turn gracefully instead of
emitting a `MultipleRequesters`-reverting `requestRedeem`. No-op today (one Safe), no behavior change. settle/claim
stay ungated. **Remaining for (a):** the contract-side decision is still (a) vs (b) vs (c) — if (a) stands, all
that's left is the deploy runbook (one OffRampModule clone per junior Safe; serialize their escrow) + a
fork-level assert that a 2nd Safe's escrow during open pending reverts cleanly. No contract change needed for (a).

## Binds to (verified this session)
- `OffRampModule.sol` — clone, `avatar=target=juniorTrancheSafe` fixed in `setUp` (one per Safe).
- `ZipRedemptionQueue.sol` — single `pendingRequester` + `MultipleRequesters` revert (`:181-185`); single
  `redeemController` (`setRedeemController` `onlyOwner`).
- `SiloRegistry.sol` — `Silo {adapter, eePool, warehouseSafe, freeze, ...}` — **no per-silo queue/offramp/junior
  field today**; if the decision is (b), the registry likely gains a per-silo queue field (a `SiloRegistry`
  obligation).

## Done when (when resolved)
- The fork (a/b/c) is decided + recorded in `claude-zipcode.md` (§6.1/§11) + `PROGRESS.md`.
- If (a): a documented serialization runbook + a test/assert that a second junior Safe escrow during open pending
  reverts cleanly (the guard, surfaced not hidden).
- If (b)/(c): a follow-on build ticket (per-silo queue deploy, or the multi-requester queue rebuild) with its own
  fork-test gate.
