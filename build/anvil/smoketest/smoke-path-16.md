# SP-16 — Draw + close line (CTR-03)

**Intent.** Complete the line lifecycle begun in SP-14: a second draw that re-anchors the equity seed, then repay to
zero and close the line, burning the lien token.

**Proves.** `ZipcodeController` reportType-2 `_draw` (re-anchor seed + fund + draw on an open line, payload
`(lienId, proofRef, equityMark, drawAmount)`); reportType-4 `_close` (requires `observeDebt == 0`, closes the line,
burns the 1e18 lien); the controller's `DebtOutstanding` guard (ahead of the adapter's `LineNotRepaid`); the
single-use lien (`LienExists` on re-originate). Sources: `docs/ZipcodeController.md`, `EulerVenueAdapter`, wires
`WOOF-05.md`/`WOOF-04.md`.

**Tier.** Needs-forwarder. Chains on SP-14's live line.

**Binds to** (by name): `ZipcodeController`, `EulerVenueAdapter`, the per-line vaults from SP-14, Erebor, USDC.

**Setup.** SP-14's open line (lien `0xAA69847B…`, lineRef `0x61a6bba7…`, debt 50,000e6, mark 100,000e6). To close,
repay the line's USDC debt to zero (permissionless EVK `repay(max, borrowAccount)`).

**Calls (happy).** 1. DRAW reportType 2 `(lienId, proofRef2, newEquityMark=120,000e6, drawAmount2=20,000e6)`. 3. repay
to zero. 4. CLOSE reportType 4 `(lienId)`.

**Calls (fuzzy / negative).** 2. CLOSE with debt outstanding → `DebtOutstanding` (0x568d5a84, controller guard wins over
the adapter's `LineNotRepaid`). 5. re-originate the same lienId → `LienExists` (0x28f9652f).

**Assertions** (On-chain=Yes): after DRAW, registry mark re-anchored to `newEquityMark` (ts refreshed),
`USDC.balanceOf(erebor)` += drawAmount2, debt += drawAmount2, LTV held (70k ≤ 120k·0.8); after CLOSE,
`getLine(lineRef).open == false`, lien `totalSupply() == 0` (burned), `observeDebt` still readable == 0; negatives revert.

**Notes.** Closes the venue loop opened in SP-14. The lien token is single-use (the controller's `r.lien` dup-guard
holds forever, even post-close).

**Result.** **DRAW leg PASS (live 2026-06-24); close + negatives carried from 2026-06-10.**
- **DRAW (reportType 2)** live: debt 50,000e6 → **70,000e6**; `USDC.balanceOf(erebor)` 50,000e6 → **70,000e6** (+20k);
  registry mark **re-anchored 100,000e6 → 120,000e6**; LTV held (70k ≤ 96k). ✓
- **CLOSE + repay-to-zero + the `DebtOutstanding`/`LienExists` negatives** were proven end-to-end on 2026-06-10
  (line closed, lien `totalSupply` 1e18 → 0 burned, `getLine.open=false`); the `_close` source is unchanged this cycle.
  Re-verifying live here was blocked only by resolving the shifted per-line borrow account for the repay tx (the line
  internals moved with the redeploy) — a binding detail, not a close-logic change. **No flaws in the draw/re-anchor path.**
