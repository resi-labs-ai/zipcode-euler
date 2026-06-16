# SEC-11 — `fund` sizes off `previewRedeem(config.balance)` (L9)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / L9; audit `findings.md` (L9);
`reference/euler-earn/src/EulerEarn.sol` (`reallocate`) · **Status:** DONE 2026-06-15

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

## Binds to (verified file:line — 2026-06-15; line refs corrected from the stale `:285-287`/`:289-292`)
- **Mis-sized reads:** `contracts/src/venue/EulerVenueAdapter.sol:295-297` — `fund` computes
  `baseBalance = IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(eulerEarn)))`
  and `lineBalance = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(eulerEarn)))`, then sets
  `allocs[0]={base, baseBalance - amount}` / `allocs[1]={line, lineBalance + amount}` (`:299-302`).
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

---

## DONE 2026-06-15

**Fix (1 contract file, `EulerVenueAdapter.sol`):** added the shared internal view
`_eeSupplyAssets(address market) returns (uint256) { return IEVault(market).previewRedeem(eulerEarn.config(IOZERC4626(market)).balance); }`.
`fund` now sizes both legs off it (`baseBalance = _eeSupplyAssets(baseUsdcMarket)`,
`lineBalance = _eeSupplyAssets(lineRef)`) instead of `convertToAssets(balanceOf(eulerEarn))`. **SEC-07
coordination DISCHARGED** (SEC-07 already landed): `closeLine`'s defund now sizes both legs off the same helper
(`lineBalance = _eeSupplyAssets(lineRef)` guard + `baseBalance = _eeSupplyAssets(baseUsdcMarket)`); the line leg
stays `assets:0` (a full redeem already sweeps any donation per `EulerEarn.sol:397-402`). The two-item
absolute-target `reallocate` structure is otherwise unchanged; `amount`/EVC/draw paths untouched; no donation
sweep/block added (Do-NOTs honored).

**Binding (verified by critics):** the imported `IEulerEarn` (`EulerVenueAdapter.sol:12`) exposes the **struct**
`config(IERC4626) returns (MarketConfig memory)` (`IEulerEarn.sol:211`, NOT the tuple form on
`IEulerEarnStaticTyping:188`), so `eulerEarn.config(...).balance` is directly accessible — no `MarketConfig`
import, no destructure. `IOZERC4626` is type-identical to euler-earn's `IERC4626` (same remap target — proven by
the existing `MarketAllocation({id: IOZERC4626(...)})`). `IEVault.previewRedeem(uint256)` resolves
(`evk/EVault/IEVault.sol:136`). `.balance` (uint112) widens to `previewRedeem`'s uint256 cleanly.

**Test-fixture rework (folded in from the junior-dev critic's most-blocking item — net-new mock infra, like
SEC-10):** the existing `MockEulerEarn` in `EulerVenueAdapter.t.sol` tracked no `config.balance` and exposed no
`config()`, so post-fix it would have reverted in EVERY fund/close test AND could not reproduce the grief.
Reworked it to be faithful to `EulerEarn.reallocate` (`EulerEarn.sol:383-442`):
- `mapping cfgBalance` (EE-tracked share balance) + `mapping cfgEnabled`; a `config()` getter returning the
  4-tuple `(cfgBalance, type(uint136).max, cfgEnabled, 0)` (ABI-identical to the real struct getter).
- `reallocate` rewritten single-pass to mirror the reference exactly: per market
  `supplyAssets = previewRedeem(cfgBalance)`; withdraw `supplyAssets - target` (or redeem-ALL on `target==0`, the
  `:397-402` donation-sweep branch); else supply `target - supplyAssets`; bump `cfgBalance` on every move; terminal
  `if (totalWithdrawn != totalSupplied) revert InconsistentReallocation()`. `acceptCap` now sets `cfgEnabled`.
- `seedConfig(market, shares)` test helper; seeding helpers `_fundBaseMarket`/`_supplyToLine` now record the
  actual minted shares as tracked config (so a legitimate supply IS tracked; a raw share transfer = donation is NOT).
- `ZipcodeController.t.sol`'s integration `MockEulerEarn` gained a `config()` getter returning live `balanceOf`
  (no donation path there → tracked == live → production sizing byte-identical to pre-fix; keeps its 13 tests green).

**Gate green:** `forge build` clean; `forge test` **803 passed / 0 failed / 3 skipped** (+3 over SEC-10's 800;
the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold). 3 new `test_SEC11_*` in `EulerVenueAdapter.t.sol`:
```
[PASS] test_SEC11_Fund_DonationImmune() (gas: 4753378)
[PASS] test_SEC11_Fund_NoDonation_StillMoves() (gas: 4430861)
[PASS] test_SEC11_PreFixSizing_Reverts_OnDonation() (gas: 4311897)
Suite result: ok. 3 passed; 0 failed; 0 skipped
...
Ran 52 test suites: 803 tests passed, 0 failed, 3 skipped (806 total tests)
```
**Fail-before/pass-after confirmed** — temporarily restoring `fund`'s `convertToAssets(balanceOf)` sizing makes
`test_SEC11_Fund_DonationImmune` FAIL (`ERC20: transfer amount exceeds balance` — the supply leg can't cover the
over-supply from the under-withdrawn cash) while `NoDonation_StillMoves` stays green; restored → all pass. Note:
the concrete pre-fix revert is the supply-leg cash shortfall (the EE pool holds no idle USDC), or
`InconsistentReallocation` proper if idle cash covers the deposit — both brick funding, so the regression uses a
bare `vm.expectRevert()`.

**No spec change** (interface-level sizing-precision fix; §4.7 intent unchanged — the spec already prescribes
`fund`/defund as the adapter's allocator role over `reallocate`; this fences a donation-grief gap). **No
back-pressure / no new obligation** (uses EE's existing `config`/`previewRedeem` surfaces). Report:
`build/reports/SEC-11-report.md`.
