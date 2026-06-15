# SEC-11 — `fund` sizes off `previewRedeem(config.balance)` (L9)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / L9; audit `findings.md` (L9);
`reference/euler-earn/src/EulerEarn.sol` (`reallocate`) · **Status:** PROPOSED

> Scope authored 2026-06-15. Group-3 sibling of SEC-06/SEC-07. This is a sizing-precision fix in `fund` so a
> donation-induced rounding/divergence can no longer revert `reallocate`. Cross-cuts SEC-07's defund (same
> sizing primitive) — see Depends.

## Deliverable
Size `fund`'s absolute reallocate targets from EE's **internally-tracked** supplied position
(`previewRedeem(config[id].balance)`), byte-matching what `reallocate` computes — instead of the live
`convertToAssets(balanceOf(eulerEarn))`, which a share donation can skew.

## What it does / what's being fixed (plain language)
`fund` tells the EE pool to move `amount` USDC from the base market into a line market by giving `reallocate`
**absolute** target balances. It computes those targets from `convertToAssets(balanceOf(eulerEarn))` — the EE
pool's *live* EVK-share balance. But `reallocate` internally measures each market's current assets as
`previewRedeem(config[id].balance)` — the EE pool's *tracked* share balance, which deliberately ignores direct
share transfers. Anyone can donate even **1 EVK share** to the EE pool, making `balanceOf` exceed
`config.balance`; `fund`'s targets then disagree with EE's own accounting, the withdraw/supply deltas no longer
net, and `reallocate` reverts `InconsistentReallocation` — funding bricks (grief).

## Binds to (verified file:line — 2026-06-15)
- **Mis-sized reads:** `contracts/src/venue/EulerVenueAdapter.sol:285-287` — `fund` computes
  `baseBalance = IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(eulerEarn)))`
  and `lineBalance = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(eulerEarn)))`, then sets
  `allocs[0]={base, baseBalance - amount}` / `allocs[1]={line, lineBalance + amount}` (`:289-292`).
- **What EE actually uses (reference, verified):** `reference/euler-earn/src/EulerEarn.sol:392-393` —
  `uint256 supplyShares = config[id].balance; uint256 supplyAssets = id.previewRedeem(supplyShares);` per
  allocation; `:441` `if (totalWithdrawn != totalSupplied) revert InconsistentReallocation();`. The interface
  comment (`IEulerEarn.sol:69,73`) confirms the tracked balance "ignores direct shares transfer".
- **Selectors:** `IEulerEarn.config(IERC4626)` — tuple form `IEulerEarn.sol:188`
  (`(uint112 balance, uint136 cap, bool enabled, uint64 removableAt)`) / struct form `:211`
  (`config(id).balance`); `IEVault.previewRedeem(uint256)`.

## Key requirements
1. Replace the two `convertToAssets(balanceOf(eulerEarn))` reads in `fund` with
   `IEVault(market).previewRedeem(eulerEarn.config(IOZERC4626(market)).balance)` (read EE's tracked share
   balance, run it through the SAME `previewRedeem` rounding EE uses). Destructure the tuple getter or use the
   struct getter per the imported interface shape.
2. Extract a small internal helper, e.g.
   `function _eeSupplyAssets(address market) internal view returns (uint256)`, returning
   `IEVault(market).previewRedeem(eulerEarn.config(IOZERC4626(market)).balance)`, and call it for both base and
   line. (Reused by SEC-07's defund — see Depends.)
3. Keep the two-item absolute-target `reallocate` structure (`:289-292`) unchanged otherwise.

## Do NOT
- Do NOT keep `convertToAssets(balanceOf(...))` for sizing — `balanceOf` includes donated shares EE's accounting
  ignores; that mismatch is the bug.
- Do NOT try to "sweep" or block donations — match EE's accounting instead (donation-immune by construction).
- Do NOT change `amount` semantics or the EVC/draw paths.
- Do NOT widen scope to H2 (SEC-06) / L8 (SEC-07) beyond sharing the `_eeSupplyAssets` helper.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC11_*` regression test** that fails before / passes after:
  - **Donation-immune fund:** open a line; transfer (donate) ≥1 EVK share of the base market directly to the EE
    pool; call `fund(line, amount)` → pre-fix it reverts `InconsistentReallocation`, post-fix it succeeds.
  - **Correct movement:** assert post-`fund` the line market's EE-tracked supplied assets rose by `amount` and
    the base's fell by `amount` (EE accounting), and the line is drawable.
  - **No-donation path unchanged:** a plain `fund` with no donation still succeeds and moves `amount`.
- Quote the actual `forge test` output in this ticket's done note. (Extend the adapter/smoke fund fixture.)

## Depends on
- None to build. **Coordinate with SEC-07 (L8):** SEC-07's `closeLine` defund currently sizes via
  `convertToAssets(balanceOf)` too — when both land, point its base/line sizing at this ticket's
  `_eeSupplyAssets` helper so the defund is equally donation-immune (the line leg uses `assets:0`, but the base
  target should use `_eeSupplyAssets`). On land: `PROGRESS.md` "Just done — SEC-11".
