# SP-07 — szipUSD secondary transfer + NAV entry/exit asymmetry

**Intent.** Show szipUSD is a freely transferable secondary-market share, and that issuance pauses on stale prices
while exits keep pricing — the §7 asymmetry that protects stayers.

**Proves.** `szipUSD` plain ERC-20 transfer; `navEntry()=max(spot,twap)` reverts `StalePrice` when pushed legs are
stale (new issuance gated); `navExit()=min(spot,twap)` never stale-reverts (exits still priced off the last good mark).

**Tier.** Needs-forwarder (to seed then stale the legs).

**Binds to.** szipUSD `0x33aD3E23…`, `SzipNavOracle` `0x0C3E7731…`. Source: `SzipNavOracle.sol` (`navEntry` L368-377,
`navExit` L380-384, `fresh` L387-391), `8-B4-SzipNavOracle.md`.

**Setup.**
- Run SP-06 first so `alice` holds szipUSD and supply > 0.
- Push fresh legs, confirm `fresh()==true`.

**Calls.**
1. `szipUSD.transfer(charlie, 250e18) as alice` (secondary transfer).
2. `cast rpc evm_increaseTime <maxAge+1>` then `evm_mine` to stale the legs.
3. `SzipNavOracle.navEntry()` → expect revert `StalePrice`.
4. `SzipNavOracle.navExit()` → expect a value (no revert).
5. `ZipDepositModule.zap(…) as alice` while stale → reverts inside `depositFor`→`navEntry` (issuance paused).

**Assertions.**
- step 1: `szipUSD.balanceOf(charlie)==250e18`, `alice` reduced.
- step 3 reverts; step 4 returns a non-zero price; step 5 reverts (atomic — no shares minted, no USDC pulled).

**Notes.** Confirms a held share is transferable on a secondary market (the basis for the CoW buy-back in SP-13) and
that the oracle's directional staleness behaves as designed.

**Result.** **PASS** (2026-06-10, real txs on anvil). szipUSD is a freely transferable secondary share, and the oracle's directional staleness (issuance pauses, exit keeps pricing) holds exactly.

Pre-state: alice held 800e18 szipUSD (the SP-06 mint less the 200e18 sold/burned in SP-13); supply 800e18. Re-pushed fresh legs + rate → `fresh()==true`, `navEntry()` = 107.265e18.

1. `szipUSD.transfer(charlie, 250e18) as alice` → status 1; **alice 800e18 → 550e18, charlie 0 → 250e18** — plain ERC-20, no gate, no NAV interaction. ✓
2. `evm_increaseTime(maxAge+1 = 86,401)` (under `evm_snapshot`/`evm_revert`) → `fresh()` true → **false**.
3. `navEntry()` → reverts **`StalePrice(LEG_ALPHA_USD=0)` (0x9bbfef51)** — new issuance gated. ✓
4. `navExit()` → **107.265e18** (no revert) — exits keep pricing off the last good mark. ✓
5. `zap(1,000e6) as alice` while stale (alice pre-funded 1,000e6 USDC + approved) → tx **reverted (status 0)**; `navEntry` inside `depositFor` propagated `StalePrice`. **Atomic:** alice USDC stayed **1,000e6** (no pull) and alice szipUSD stayed **550e18** (no mint). ✓ Snapshot reverted → `fresh()` restored.

No flaws. A held share is transferable on the secondary market (the basis for the CoW buy-back in SP-13), and the oracle's `navEntry=max(spot,twap)` / `navExit=min(spot,twap)` directional staleness behaves as designed: staleness fail-closes minting while exits price off the last mark — the §7 asymmetry that protects stayers (no one can mint cheap into a stale basket; existing holders can always leave). charlie now holds 250e18 szipUSD.
