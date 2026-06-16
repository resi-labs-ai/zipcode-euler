# SEC-07 — `closeLine` defunds the line's USDC back to base (L8)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / L8; audit `findings.md` (L8) ·
**Status:** DONE 2026-06-15

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

## Critic triage (2026-06-15 — before build)
Three critics ran (junior-dev, spec-fidelity, reference-verifier). spec-fidelity **PASS** (faithful to L8/§4.7/§17,
minimal, no inbound obligation). reference-verifier **all bindings exist+usable** — confirmed `reallocate` is
ABSOLUTE-target + zero-sum (`EulerEarn.sol:441` `InconsistentReallocation`), `assets:0` redeems ALL shares
(`:399-402`), the per-market gate is `config[id].enabled` (`:390`, set by `acceptCap`, co-moves with the cap) NOT
supply-queue membership — so the defund is robust to ordering vs the SEC-06 prune; direct EVK `withdraw`/`deposit`
by the owning (EE) account auto-routes through EVC with a no-op status check (no controller on the EE account).
**junior-dev most-blocking = TICKET GAP (resolved here):** `MockEulerEarn.reallocate` only *records* targets, it does
not move funds — so the balance-level "no strand" / "no later-fund underflow" assertions below cannot fail-before/
pass-after against the recording-only mock. **Resolution (mirrors SEC-06's faithful `setSupplyQueue`):** make
`MockEulerEarn.reallocate` faithful — execute the absolute-target reallocation against the real EVK vaults
(two passes: withdrawals/redeem-all first → this pool's USDC cash, then deposits). This also makes `fund` actually
strand USDC, which is what the regression needs. Added requirements: assert `reallocCount` unchanged on the
never-funded path (proves the no-op guard *skipped*, not just "didn't revert"); update SEC-06's prune comment
(`closeLine:365`) — the defund (not the collateral redeem) is what now empties the line market before the prune.

## Done when
- `cd contracts && forge build` clean.
- **Make `MockEulerEarn.reallocate` faithful** (move USDC between the real EVK vaults; `assets:0` → redeem all shares).
- `forge test` green, **plus a new `SEC07_*` regression test** that fails before / passes after:
  - **No strand:** open a line, `fund` it, `closeLine` (debt 0); assert the base market's
    `convertToAssets(balanceOf(EE))` is restored (the line's USDC returned, `lineRef` EE balance == 0 post-close)
    — pre-fix the base balance stays depressed.
  - **No later-fund underflow:** after the open→fund→close cycle, a subsequent `fund` of a NEW line for an
    `amount` near the full base balance succeeds (pre-fix it reverts on the `:290` underflow).
  - **Never-funded line:** open then immediately `closeLine` (lineBalance == 0) completes with no reallocate revert
    **and `reallocCount` unchanged** (the no-op guard skipped the defund, not merely survived it).
- Quote the actual `forge test` output in this ticket's done note. (Extend `EulerVenueAdapter.t.sol`.)

## Depends on
- None (independent of SEC-06, same function). On land: `PROGRESS.md` "Just done — SEC-07".

---

## DONE note (2026-06-15)
**`closeLine` now defunds the line's USDC back to base before the SEC-06 queue prune** (`EulerVenueAdapter.sol:367-378`).
- **Fix (1 contract file):** after the collateral redeem and before the SEC-06 prune, read
  `lineBalance = convertToAssets(balanceOf(eulerEarn))` on `lineRef`; if non-zero, read the same on `baseUsdcMarket`
  and `eulerEarn.reallocate([{lineRef, assets: 0}, {baseUsdcMarket, assets: baseBalance + lineBalance}])` — the
  inverse of `fund`'s absolute-target reallocate (`assets: 0` redeems the EE's whole line position; base absorbs it;
  zero-sum). No-op guard on `lineBalance == 0` (never-funded line). SEC-06's prune comment updated (the defund, not
  the collateral redeem, is what now empties the removed market). `fund` sizing, the redeem, `L.open=false`, and the
  prune are otherwise untouched (additive).
- **Test (1 test file):** made `MockEulerEarn.reallocate` **faithful** (it now actually moves USDC between the real
  EVK vaults — pass 1 withdraws/redeems-all to the pool's cash, pass 2 deposits; `MockEulerEarn(usdc)` ctor) so the
  strand and the `:290` underflow are reproduced, not just asserted on recorded targets. 3 new `test_SEC07_*` in
  `test/EulerVenueAdapter.t.sol`: no-strand (base restored 1M, line emptied), no-later-fund-underflow (new line funds
  950k near full base), never-funded (guard skips defund, `reallocCount` unchanged).
- **Gate (quoted):**
  - `forge build` → clean (lints only).
  - `forge test` full suite → **`787 passed; 0 failed; 3 skipped (790 total)`** (+3 over SEC-06's 784; the 3 skips
    are the pre-existing `DeployZipcode.t.sol` scaffold). Adapter suite: `26 passed`.
  - **Fail-before/pass-after CONFIRMED** — with the `eulerEarn.reallocate(defund)` call disabled:
    `test_SEC07_CloseLine_DefundsUsdcToBase` FAILs `base ... 700000000000 !~= 1000000000000 (real delta: 300000000000)`;
    `test_SEC07_NoLaterFundUnderflow` FAILs `panic: arithmetic underflow or overflow (0x11)` (the exact `:290` bug);
    `test_SEC07_NeverFundedLine_NoDefund` still PASSes (guard test, not a fail-before). Restored → all 3 pass.
- **No spec change** (interface-level fix; §4.7 intent unchanged — defund is the adapter's allocator role, the symmetric
  un-do of `fund`'s supply, just as SEC-06 was the un-do of `openLine`'s queue append). **No back-pressure / no new
  obligation** (uses EE's existing `reallocate`). **L9/SEC-11 interaction:** SEC-11 has NOT landed (`_eeSupplyAssets`
  absent) so the ticket's primary `convertToAssets(balanceOf(EE))` sizing was used; when SEC-11 lands, the defund's
  base-leg read should adopt `previewRedeem(config[id].balance)` for donation-immunity (logged in audit B7 / finding #4).
