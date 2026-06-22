# CTR-14 — multi-tranche redemption topology (N junior Safes vs the single-requester shared queue)

> **DECIDED 2026-06-21 → (b) per-silo redemption, REFRAMED (see "Decision" below). Sub-decisions RESOLVED:
> off-registry ⇒ ZERO contract change (deploy-topology only). Ready for cold-build.** Spec: `claude-zipcode.md` §4.7 (federation) / §6.1 (senior par
> redemption) / §11 (mutualized senior). Contracts (truth): `ZipRedemptionQueue.sol`, `OffRampModule.sol`,
> `SiloRegistry.sol`, `SiloDeployer.s.sol`, `JuniorTrancheDeployer.s.sol`, `DeployZipcode.s.sol`. Surfaced 2026-06-20
> while reviewing CRE-02; decision driven by the reviewer's federation model (one mutualized TOKEN, per-silo
> backing+risk+exit — chat 2026-06-21).

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
Recommendation as originally weighed: **(a) for M1**. **SUPERSEDED by the 2026-06-21 federation-model decision.**

## Decision (2026-06-21) → (b), reframed
**(b) per-silo queue + off-ramp.** The reviewer's federation model resolves the fork: the senior is mutualized **at
the TOKEN layer** (one fungible `zipUSD`, one shared AMM/xALPHA/ICHI/oHYDX yield substrate, one curated minter set
gated by Timelock `setCapacity`), while **backing + risk + exit are isolated PER SILO** (each silo already has its
own `eePool`/`usdcReservoir`/warehouse, junior `SzipUSD`/`SzipNavOracle`/`ExitGate`/CoW book, `DurationFreezeModule`
"white-blood-cell" coverage, `DefaultCoordinator`). The redemption queue is **the one layer still shared**, and it is
the *only* thing reintroducing cross-silo coupling — so per-silo redemption *completes* the isolation rather than
fragmenting the dollar.

**This is NOT the "un-mutualize the senior" cost the original (b) framing warned about.** The dollar was always shared
and stays shared. Only the **par-redemption plumbing** goes silo-local — which makes it MATCH the already-per-silo
warehouse funding (each silo's warehouse REDEEM→REPAY funds its OWN queue). The compelling property "you cannot exit
your zipUSD from someone else's USDC source" becomes **structural**, not ops-enforced. **(a) is rejected** — it
couples silos through one queue, the opposite of the white-blood-cell isolation. **(c) is rejected** — flat-par
multi-requester only matters if non-treasury actors ever redeem at par, which the design forbids.

## Build surface (verified against code 2026-06-21)
Largely DEPLOY-TOPOLOGY, not new contracts — the per-silo isolation primitives already exist.
- **`ZipRedemptionQueue`** — plain deployable (`ctor(zipUSD, usdc, controller)`); **instantiate one per silo**. NO
  contract change. Within a silo there is exactly one junior Safe ⇒ the single-requester guard + `pendingRequester`
  stay correct, now scoped per-silo-queue.
- **`OffRampModule`** — clone; takes its `queue` as a set-once `setUp` param (`OffRampModule.sol:69-71`), `avatar =
  target = juniorTrancheSafe`. **Deploy one per silo**, wired to that silo's queue + junior Safe + operator. NO
  contract change.
- **`SiloDeployer.s.sol`** — (1) `new ZipRedemptionQueue` EARLY (after the step-0 junior-Safe precompute, BEFORE the
  step-6 warehouse, since the warehouse pins `redemptionBox == queue`); (2) `setRedeemController(juniorTrancheSafe)`
  + `transferOwnership(timelock)`; (3) wire warehouse `redemptionBox = this per-silo queue`; (4) drop the shared
  `redemptionBox` SiloParams input (`:76`); (5) the non-commingling assert (`:205`) now checks the per-silo queue.
- **`JuniorTrancheDeployer.s.sol`** (or `SiloDeployer`) — deploy + enable the per-silo `OffRampModule` clone on the
  junior Safe (the off-ramp belongs to the junior; ordering allows it post-warehouse since it only needs the queue
  addr). Pin the home in sub-decision 3.
- **`DeployZipcode.s.sol`** — silo-0 ALREADY self-deploys its queue (`:280`) + off-ramp (`:491-497`); reframe it as
  *silo-0's per-silo queue* (no longer a shared hub handle). Confirm nothing else threads the shared queue.
- **Downstream (CRE)** — per-silo queues are now 1:1 with warehouses, so the **cross-silo redemption SOLVER (CRE-02c)
  is OBVIATED** for funding: each silo's warehouse funds its OWN queue; the "ONE shared queue, N warehouses → choose
  which pool" premise dissolves. CRE-02b (per-warehouse funding) stays, now silo-local. See sub-decision 2.

## Sub-decisions — RESOLVED 2026-06-21
1. **SiloRegistry binding → OFF-REGISTRY (reviewer-decided).** No registry field. A silo's queue is on-chain-derivable
   via that silo's `warehouse.redemptionBox()` (matches the off-registry WAM posture). ⇒ **CTR-14(b) is ZERO contract
   change — deploy-topology only.**
2. **CRE-02c fate → KEEP DORMANT + DOCUMENT (recommended default; reviewer may flip).** Leave the built default-OFF
   solver; reclassify it as a future cross-silo liquidity-rebalance hook, NOT used for redemption under per-silo queues.
3. **Off-ramp+queue deploy home → queue in `SiloDeployer`, off-ramp in `JuniorTrancheDeployer` (recommended default;
   reviewer may flip).** Queue precedes the warehouse (forced by the step-6 `redemptionBox==queue` pin); off-ramp
   enabled alongside the junior's other Zodiac modules (queue addr threaded in via `JuniorParams`).

## Status — option (a) keeper-half PREPARED (2026-06-20, CRE-02-R1)
The keeper side of (a) is built ahead of federation: `RedemptionJob`'s escrow leg now reads
`queue.pendingRequester()` and fires only when the queue is free for its Safe (`pendingRequester == 0 || ==
rqSafe`) — so when a second junior Safe shares the one queue, each keeper waits its turn gracefully instead of
emitting a `MultipleRequesters`-reverting `requestRedeem`. No-op today (one Safe), no behavior change. settle/claim
stay ungated. **Remaining for (a):** the contract-side decision is still (a) vs (b) vs (c) — if (a) stands, all
that's left is the deploy runbook (one OffRampModule clone per junior Safe; serialize their escrow) + a
fork-level assert that a 2nd Safe's escrow during open pending reverts cleanly. No contract change needed for (a).
**Under the (b) decision:** the `pendingRequester` wait becomes a permanent no-op (each silo's queue has exactly one
requester — its own junior Safe) but is harmless defense-in-depth and stays; the (a) serialization runbook is dropped.

## Binds to (verified this session)
- `OffRampModule.sol` — clone, `avatar=target=juniorTrancheSafe` fixed in `setUp` (one per Safe).
- `ZipRedemptionQueue.sol` — single `pendingRequester` + `MultipleRequesters` revert (`:181-185`); single
  `redeemController` (`setRedeemController` `onlyOwner`).
- `SiloRegistry.sol` — `Silo {adapter, eePool, warehouseSafe, freeze, ...}` — **no per-silo queue/offramp/junior
  field today**; if the decision is (b), the registry likely gains a per-silo queue field (a `SiloRegistry`
  obligation).

## Done when (build — (b))
- Each silo deployed via `SiloDeployer` gets its OWN `ZipRedemptionQueue` (warehouse `redemptionBox` == that queue;
  `redeemController` == that silo's junior Safe; owner → Timelock) + its OWN `OffRampModule` clone (enabled on the
  junior Safe, wired to that queue).
- The shared `redemptionBox` SiloParams input is gone; the non-commingling asserts validate the per-silo queue.
- A multi-silo fork test: two silos, each with its own queue + junior Safe, BOTH escrow + settle + claim
  CONCURRENTLY with NO `MultipleRequesters` revert (proving the cross-silo coupling is gone); and a silo-A escrow can
  NEVER be settled from silo-B's USDC (isolation assert).
- Off-registry confirmed: NO `SiloRegistry` change; the per-silo queue is documented as derivable via
  `warehouse.redemptionBox()`.
- Doc-sync: `claude-zipcode.md` §6.1/§11 + the D5/§6 decision rewritten ("ONE shared queue" → "per-silo queue;
  mutualized TOKEN, isolated backing+redemption"); `9-ZipRedemptionQueue.md`, `CTR-06c-SiloDeployer.md`,
  `CTR-02-SiloRegistry.md` (if field added) updated; the [[exit-topology-intentional]] memory note refined.
- `forge build` + `forge test` green (the gate); CRE-02c fate (sub-decision 2) recorded in `PROGRESS.md`.
