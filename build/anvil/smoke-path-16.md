# SP-16 — Draw + close line

**Intent.** Complete the line lifecycle begun in SP-14: issue a second draw that re-anchors the equity seed, then
repay to zero and close the line, burning the lien token.

**Proves.** `ZipcodeController` reportType-2 `_draw` (re-anchor seed + fund + draw on an open line); reportType-4
`_close` (requires `observeDebt == 0`, closes the line, burns the 1e18 lien).

**Tier.** Needs-forwarder (+ identity). Depends on SP-14.

**Binds to.** `ZipcodeController` `0x36025de2…`, `EulerVenueAdapter` `0x87dC8666…`, the per-line vaults from SP-14,
Erebor `0x15d34AAf…`, USDC. Source: `ZipcodeController.sol` (`_draw` payload `(bytes32 lienId, bytes32 proofRef,
uint256 equityMark, uint256 drawAmount)` L216-217; `_close` payload `(bytes32 lienId)` L234), `EulerVenueAdapter.sol`
(`closeLine` L343-360, `observeDebt`), wires `WOOF-05.md`, `WOOF-04.md`.

**Setup.**
- SP-14 done (an open line with a drawn balance).
- To close: repay the line's USDC debt to zero — `deal` USDC to the line's borrow account and repay via the EVC, so
  `adapter.observeDebt(lineRef) == 0`.

**Calls.**
1. DRAW: impersonate Forwarder → `onReport(meta, abi.encode(2, abi.encode(lienId, proofRef2, newEquityMark, drawAmount2)))`.
2. Repay the line to zero (EVC repay path).
3. CLOSE: `onReport(meta, abi.encode(4, abi.encode(lienId)))`.

**Assertions.**
- after 1: registry cache for the lien == `newEquityMark` (re-anchored), ts updated; `USDC.balanceOf(erebor)` rose by `drawAmount2`.
- after 3: `adapter.getLine(lineRef).open == false`; lien `balanceOf(controller) == 0` and `totalSupply() == 0` (burned);
  post-close `observeDebt(lineRef) == 0` still readable.
- (negative) attempting CLOSE with debt outstanding → revert `DebtOutstanding` (the controller's `_close` guard fires first, ahead of the adapter's `LineNotRepaid` — defense-in-depth, outer guard wins).

**Notes.** Closes the venue loop opened in SP-14. The lien token is single-use (factory rejects re-create for the same
(lienId, controller)).

**Result.** **PASS** (2026-06-10, real txs on anvil). Completes the SP-14 line lifecycle: a re-anchoring second draw, then repay-to-zero and close with the lien burned.

Operated on the SP-14 line: lienId `0x689c43ea…`, lineRef `0x7C489cC9…`, lien `0xC8c8D3C8…`, collat `0xA0A6a900…`, borrowAccount `0xb11844B5…48fAf`. Starting debt 50,000e6, mark 100,000e6.

1. **DRAW (reportType 2)** — payload `(lienId, proofRef2, newEquityMark=120,000e6, drawAmount2=20,000e6)`, 491,490 gas. Deltas: debt 50k → **70,000e6**; erebor USDC 50k → **70,000e6** (+20k); registry mark **re-anchored 100k → 120,000e6**, cache ts refreshed (1780985208 → 1780985411). LTV held: 70k ≤ 120k·0.8 = 96k. ✓
2. (neg) **CLOSE with debt outstanding** → reverts **`DebtOutstanding` (0x568d5a84)** — the *controller's* `_close` guard fires first (ahead of the adapter's `LineNotRepaid` `0x2e48b075`). *(Spec said `LineNotRepaid`; the controller-level `DebtOutstanding` is what callers actually see.)*
3. **Repay to zero** — permissionless: supplier acct[9] funded `lineRef.repay(uint256.max, borrowAccount)` (repay credits anyone's debt, pulls from msg.sender) → `observeDebt` 70k → **0**. ✓
4. **CLOSE (reportType 4)** — 189,349 gas. closeLine redeemed the 1e18 escrow shares (held by borrowAccount) to the controller via operator-routed `EVC.call(redeem)`, then `burn(1e18)`. Assertions (all ✓): `getLine.open` = **false**; lien `totalSupply` 1e18 → **0** and `balanceOf(controller)` = **0** (burned); `observeDebt` post-close = **0** (still readable — record kept, only `open` flipped); `controller.getLien` = `(lien, lineRef, false)`.
- (neg) **re-originate the same lienId** → reverts **`LienExists` (0x28f9652f, arg == lienId)** — the controller dup-guard catches it (the record's `r.lien` stays set forever, F-12) before the factory's `FailedDeployment`. Single-use confirmed even after close. ✓

No flaws — the full venue loop (originate → draw → repay → close → burn) is verified end-to-end on real EE + EVK across SP-14/SP-16. Only note is the SP-text error name (`LineNotRepaid` → actually `DebtOutstanding` at the controller).
