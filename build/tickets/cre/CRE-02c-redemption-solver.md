# CRE-02c — cross-silo redemption solver (which EE vault(s) to drain)

> Scoping ticket (not yet built). Spec: `claude-zipcode.md` §6.1 / §6.3 / §8.2 / §8.3 / §8.5; federation §4.7.
> Sibling of CRE-02b (the single-source funding glue) — this is its **multi-warehouse generalization**.
> Depends on: CRE-02 (settle/claim — DONE), CRE-04 (`cre/warehouse` REDEEM/REPAY — DONE), SiloRegistry (CTR-02 —
> DONE). Relates to CTR-14 (the multi-tranche topology question — separate ticket).

## The problem (plain)
The senior zipUSD is **mutualized** across all silos, and there is **one shared `ZipRedemptionQueue`**
(`WarehouseAdminModule.redemptionBox` → the single queue; the registry's `Silo` struct has **no per-silo queue
field** — confirmed `SiloRegistry.sol` `struct Silo {adapter, eePool, warehouseSafe, freeze, ...}`). But there are
**N warehouses** — one `warehouseSafe` + EulerEarn pool per silo (`SiloRegistry` admits each silo as
`{adapter, eePool, warehouseSafe, ...}`). To fund a redemption, USDC is freed via REDEEM→REPAY **from a
warehouse** — but *which* one? With N pools feeding one queue, something has to **choose the source(s) and the
split**. That chooser is a **redemption solver**. CRE-02 (the keeper) and CRE-02b (single-source funding) both
assume the source is already decided; this ticket is that decision.

## What the solver must do
Given a redemption shortfall (`queue.totalPending()/scaleUp − queue free USDC`), pick which silo EE pool(s) to
REDEEM from and how much from each, then fire the per-pool REDEEM→REPAY via `cre/warehouse` (each silo's
`WarehouseAdminModule` has its own forwarder/scope; REPAY `dest` = the one shared queue). Constraints it must
respect **per pool**:
- **Free liquidity** — only redeem what a pool can free without bricking draws (§6.3 redemption-vs-draw
  contention is per-pool; `EE.maxWithdraw(warehouseSafe)` is the donation-immune free read).
- **Reserve / coverage** — leave each silo's working-capital + harvest reserve + coverage floor intact
  (`covered()` / `harvestReserve` / `safetyBuffer`); never over-redeem a pool into its freeze.
- **NAV sizing** — `EE.convertToAssets(EE.balanceOf(warehouseSafe))` to size shares→USDC per pool.

## The solver policy (the open design question)
How to split a shortfall across N pools — pick + record at scoping:
- **Most-free-first** — drain the pool with the most idle USDC first (simplest; concentrates draw on one pool).
- **Pro-rata by free liquidity** — split proportional to each pool's free reservoir (spreads contention).
- **Utilization-balancing** — redeem so post-redeem utilization `U` is equalized across pools (keeps no single
  pool near its freeze; richest, most complex).
- **Curator/priority-ordered** — a registry-driven order (federation policy).
Recommendation to weigh: pro-rata by free liquidity for M-N1 (spreads contention, no per-pool starvation), with
utilization-balancing as the dynamic upgrade — but this is the decision the ticket exists to make.

## Binds to (verify exact getters at scoping)
- `SiloRegistry` silo enumeration — the per-silo `{eePool, warehouseSafe}` set (`SiloRegistry.sol` `allSiloIds()`
  + the `Silo` getter; the doc note at `:262` describes iterating `{eePool, warehouseSafe}`). **Verify the exact
  enumeration getters.**
- Per silo: `EE.maxWithdraw(warehouseSafe)`, `EE.convertToAssets(EE.balanceOf(warehouseSafe))`, the
  `covered()`/reserve surface.
- `cre/warehouse` HTTP trigger per silo (each silo's `WarehouseAdminModule` is a distinct receiver/forwarder;
  REPAY `dest` pinned `EqualTo(redemptionBox)` = the shared queue).
- The shared queue shortfall reads (CRE-02's reads).

## Ships default-OFF (M1 posture)
Like CRE-02b: inert until configured/tested. In M1 ops picks the source pool by hand (one warehouse). The solver
automates the choice once there are genuinely multiple live pools + data to tune the split. **No back-pressure
expected** — every input exists; this is off-chain routing, not a missing contract surface. (If silo enumeration
turns out not to expose what the solver needs, THAT is a back-pressure obligation against `SiloRegistry`.)

## Done when (when built)
- The solver enumerates live silos, sizes a per-pool REDEEM split that respects each pool's free-liquidity +
  coverage gate (never over-redeems into a freeze), fires per-pool REDEEM→REPAY into the shared queue, and a test
  proves: a starved/undercovered pool is skipped; the split matches the chosen policy; total REPAID ≤ shortfall;
  default-OFF emits nothing.
- The split policy is resolved + recorded.
