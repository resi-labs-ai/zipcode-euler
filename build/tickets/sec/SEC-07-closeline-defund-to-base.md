# SEC-07 — `closeLine` defunds the line's USDC back to base (L8)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / L8; audit `findings.md` (L8) ·
**Status:** PROPOSED

> Scope authored 2026-06-15. Group-3 sibling of SEC-06 (H2). Both edit `closeLine`; **neither subsumes the
> other** — SEC-06 prunes the supply *queue* (origination brick), this reclaims the stranded *USDC* (funding brick).

## Deliverable
Add a line→base `reallocate` to `closeLine` so the EulerEarn pool's USDC position supplied into the closed
line vault is returned to the base USDC market, instead of stranding.

## What it does / what's being fixed (plain language)
`fund` moves USDC from the base market into a line's borrow vault (the EE pool supplies into `lineRef`) so the
borrower can draw. `closeLine` redeems the borrower's **collateral** but leaves the EE pool's **supplied USDC**
sitting in the now-closed line vault. That USDC is stranded: it lowers the base market's balance permanently.
Because `fund` sizes the next allocation off `baseBalance` and computes `baseBalance - amount`, once enough USDC
is stranded across closed lines a later `fund` reverts on the unsigned underflow — funding bricks.

## Binds to (verified file:line — 2026-06-15)
- **The underflow site:** `contracts/src/venue/EulerVenueAdapter.sol:285-292` — `fund` reads
  `baseBalance = IEVault(baseUsdcMarket).convertToAssets(balanceOf(eulerEarn))` (`:285-286`) and sets
  `allocs[0] = {baseUsdcMarket, assets: baseBalance - amount}` (`:290`). When `amount > baseBalance` (USDC
  stranded in closed lines), `baseBalance - amount` underflows and reverts.
- **The missing defund:** `contracts/src/venue/EulerVenueAdapter.sol:343-360` — `closeLine` redeems escrow
  collateral (`:350-356`) and sets `L.open = false` (`:358`); it never reallocates the EE pool's `lineRef` USDC
  position back to base.
- **The reallocate pattern to mirror (inverted):** `fund` `:289-292` — two-item `MarketAllocation[]`,
  absolute-target, `eulerEarn.reallocate(allocs)`. `MarketAllocation{IOZERC4626 id; uint256 assets;}`.
- **EE enablement caveat (verified):** `reallocate` works on any market with a non-zero `config[].cap`
  (independent of supply-queue membership) — `openLine`'s `submitCap`/`acceptCap` (`:225-226`) left the line's
  cap at `type(uint136).max`, so the closed line is still reallocate-eligible. (This is why the defund must run
  before any future cap revocation, and is unaffected by SEC-06's supply-queue prune.)

## Key requirements
1. In `closeLine`, after the collateral redeem (`:350-356`), read
   `lineBalance = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(eulerEarn)))` and
   `baseBalance = IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(eulerEarn)))`,
   then `reallocate` two absolute targets: `{lineRef, assets: 0}` (redeem ALL the line's shares) and
   `{baseUsdcMarket, assets: baseBalance + lineBalance}` (base absorbs it). Zero-sum, mirrors `fund` inverted.
2. **Guard the no-op:** if `lineBalance == 0` (a line opened/closed without ever being funded), skip the
   reallocate — do not emit a pointless/zero-sum reallocate that could revert.
3. Keep the collateral redeem and `L.open = false` as-is; this is additive.

## Do NOT
- Do NOT fold this into the SEC-06 queue prune or vice-versa — distinct mechanisms (USDC reclaim vs queue
  membership). They share the function; sequence the defund (this) BEFORE the prune so the removed market is empty.
- Do NOT revoke the line's cap before the defund — `reallocate` needs the market EE-enabled (`cap != 0`).
- Do NOT change `fund`'s sizing logic — the strand is the cause; reclaiming it on close is the fix (not patching
  `fund` to tolerate a stranded base).
- Do NOT use `maxWithdraw` to size the defund — use the supplied-position read. **NOTE:** if SEC-11 (L9) has
  landed, size the base target via its `_eeSupplyAssets(market)` helper (`previewRedeem(config[id].balance)`),
  NOT `convertToAssets(balanceOf(EE))`, so the defund is donation-immune like `fund`. (The line leg uses
  `assets:0` regardless.)
- Do NOT widen scope to H2 (SEC-06) or L9 (SEC-11) or other groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC07_*` regression test** that fails before / passes after:
  - **No strand:** open a line, `fund` it, draw, repay, `closeLine`; assert the base market's
    `convertToAssets(balanceOf(EE))` is restored (the line's USDC returned, `lineRef` EE balance ≈ 0 post-close)
    — pre-fix the base balance stays depressed.
  - **No later-fund underflow:** after the open→fund→repay→close cycle, a subsequent `fund` of a NEW line for an
    `amount` near the full base balance succeeds (pre-fix it reverts on the `:290` underflow).
  - **Never-funded line:** open then immediately `closeLine` (lineBalance == 0) completes with no reallocate revert.
- Quote the actual `forge test` output in this ticket's done note. (Extend the adapter/smoke fixture; SP-14/L7/L8 paths exercise close.)

## Depends on
- None (independent of SEC-06, same function). On land: `PROGRESS.md` "Just done — SEC-07".
