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

**Result.** **PASS** (live fork — full draw→repay→close end-to-end).
- **DRAW (reportType 2)** live: debt 50,000e6 → **70,000e6**; `USDC.balanceOf(erebor)` 50,000e6 → **70,000e6** (+20k);
  registry mark **re-anchored 100,000e6 → 120,000e6**; LTV held (70k ≤ 120k·0.8 = 96k). ✓
- **(neg) CLOSE with debt** → reverted `DebtOutstanding` (the close only succeeded *after* the repay below). ✓
- **Repay to zero**: permissionless `borrowVault.repay(max, borrowAccount)` (borrowAccount resolved via
  `getLine(lineRef)` — `lineRef` is an **address**, the per-line borrow vault) → status 1, debt → 0. ✓
- **CLOSE (reportType 4)** live: `getLien.open` → **false**, lien `totalSupply` 1e18 → **0** (burned),
  `getLine(lineRef).open` → **false**. ✓
- **(neg) re-originate the same lienId** → `LienExists` (the controller's `r.lien` dup-guard persists post-close —
  single-use). ✓ **No flaws** — full venue loop (originate → draw → repay → close → burn) verified live on real EE+EVK.
