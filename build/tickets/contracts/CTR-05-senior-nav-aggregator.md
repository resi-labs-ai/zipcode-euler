# CTR-05 — SeniorNavAggregator: donation-immune Σ senior backing across silos

> Contract-track change (EXPANSION). A read-only view that sums each silo's senior backing into one number, so
> zipUSD's solvency (Σ backing vs supply) is observable across N pools. This is solvency telemetry + the input to
> any circuit-breaker — NOT a pricing oracle (zipUSD still mints by value and redeems at par).
> Spec: `claude-zipcode.md` §7 (NAV) / §11 (solvency) / §12 (dashboard metrics) / §8.2 (donation-immune senior read).

## Why (the seam)
With N silos each holding senior EulerEarn shares in its own warehouse Safe, the protocol needs one aggregate
"how much USDC actually backs all outstanding zipUSD." Each silo already exposes a donation-immune per-silo read;
nothing sums them. The aggregator loops `SiloRegistry.siloIds` and adds the per-silo senior values.

## Deliverable
A new `contracts/src/SeniorNavAggregator.sol` (view):
- holds a `registry` (CTR-02) pointer (Timelock-settable, `WiringSet`).
- `seniorBacking() returns (uint256)` — `Σ over active silos: IEulerEarnUtil(s.eePool).convertToAssets(
  IEulerEarnUtil(s.eePool).balanceOf(s.warehouseSafe))`, scaled USDC-6dp → 18dp at the boundary.
- `illiquidSeniorValue() returns (uint256)` — `Σ (convertToAssets(balanceOf(warehouse)) − maxWithdraw(warehouse))`
  per silo (the lent-out senior dollars), reusing the exact formula in `DurationFreezeModule.illiquidSeniorValue`.
- `collateralization(uint256 zipUsdSupply) returns (uint256)` — `seniorBacking() * 1e18 / zipUsdSupply` (the
  breaker input); or take zipUSD as a wired address and read `totalSupply()` directly.
- per-silo getters for dashboards.

## Spec §
`claude-zipcode.md` §8.2 (the donation-immune senior read — `U = 1 − maxWithdraw(warehouse)/convertToAssets(
balanceOf(warehouse))`, NEVER `balanceOf(eePool)`), §7/§11/§12.

## Binds to (verified)
- The donation-immune read to replicate, per silo: `DurationFreezeModule.utilization`/`illiquidSeniorValue`
  (`contracts/src/supply/szipUSD/DurationFreezeModule.sol:243-302`) — `convertToAssets(balanceOf(warehouse))`,
  `maxWithdraw(warehouse)`, the `*1e12` 6→18dp scale (`:301`).
- `IEulerEarnUtil` (`contracts/src/interfaces/euler/IEulerEarnUtil.sol`) — `balanceOf`/`convertToAssets`/`maxWithdraw`.
- `SiloRegistry.allSiloIds`/`getSilo` (CTR-02) — `{eePool, warehouseSafe, active}`.

## Starting state
- No aggregator exists; `DurationFreezeModule` does the per-silo donation-immune read for ONE pool. `SiloRegistry`
  exists (CTR-02).

## Do NOT
- Do NOT ever read `balanceOf(eePool)` — EulerEarn is a pure allocator (idle ≈ 0) and that read is both broken and
  donatable (the §8.2 CRITICAL). Always `convertToAssets(balanceOf(warehouseSafe))`.
- Do NOT sum junior NAV here — loss is local to each silo's junior; this view is senior backing only.
- Do NOT let zipUSD price off this — it is telemetry/breaker input; zipUSD mints by value and redeems at par.
- Do NOT include retired/inactive silos in the live backing sum (but expose them in per-silo getters).

## Key requirements
1. **Donation-immunity is the whole point** — a test donates shares/USDC to an `eePool` and asserts
   `seniorBacking()` does not move.
2. **N=1 identity** — with one silo, `seniorBacking()` equals the single warehouse's
   `convertToAssets(balanceOf(safe))`.
3. **Σ correctness** — two silos sum; an inactive silo is excluded from the live total.
4. **6→18dp scaling matches** `DurationFreezeModule` exactly (`:301`).

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/SeniorNavAggregator.t.sol` green: N=1 identity; two-silo Σ; donation
  no-op; inactive-silo exclusion; scaling matches the freeze module. (EulerEarn is mocked per the WOOF-04/05
  precedent; novel infra fork-real.)
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02.
- **Unblocks:** a federation solvency dashboard (FE), the mint kill-switch / circuit-breaker, and CTR-10's
  `ISeniorPool` generalization (which swaps the per-silo read behind an interface).
