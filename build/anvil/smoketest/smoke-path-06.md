# SP-06 — Junior zap → share issuance (HEADLINE; seam S8)

**Intent.** The core junior question: deposit USDC, get szipUSD. How much is a share worth, how many shares per
zipUSD, and where do the Loot and the receipt shares go.

**Proves.** `ZipDepositModule.zap` (USDC→zipUSD→EE pool) then `ExitGate.depositFor` values zipUSD via NAV and mints
`shares = value·1e18/navEntry` (round DOWN); **Loot minted to the GATE (soulbound), szipUSD to the depositor**; zipUSD
routed into the main Safe basket. ExitGate **I-1** two-token conservation (`szipUSD.totalSupply()==Loot.balanceOf(gate)`),
**I-4** round-down issuance; the TVL cap (negative); SUPPLY-ADV-06/07 conservation-setter locks + FoT received-delta
guard. Sources: `docs/supply/szipUSD/ExitGate.md`, `contracts/src/supply/szipUSD/x-ray/ExitGate.md`, wires `WOOF-06.md`/`ExitGate-szipUSD.md`.

**Tier.** Needs-forwarder (NAV legs + xALPHA rate seeded so `navEntry()` doesn't fail-close).

**Binds to** (by name): `ZipDepositModule`, `ExitGate`, `SzipNavOracle`, szipUSD, Loot, Baal, main Safe, USDC. alice.

**Setup.** `seed_marks`; `deal` 1,000e6 USDC to alice; approve `ZipDepositModule`; read `previewZap(1_000e6)`.

**Calls (happy).** 1. `ZipDepositModule.zap(1_000e6)` as alice.

**Calls (fuzzy / negative).** 2. (cap) Timelock `ExitGate.setTvlCap(1_500e18)`, then `zap(1_000e6)` again
(gross 1,000e18 + value 1,000e18 = 2,000e18 > cap) → `TvlCapExceeded`. 3. (setter lock) a conservation setter
post-issuance → reverts (SUPPLY-ADV-06/07).

**Assertions** (On-chain=Yes): `szipUSD.balanceOf(alice) == valueOf(zipUSD,1000e18)·1e18/navEntry` round-down (≈1,000e18
at genesis NAV); **I-1** `Loot.balanceOf(gate) == szipUSD.totalSupply()`; `Baal.totalShares()==0`;
`zipUSD.balanceOf(mainSafe)` +1,000e18; module residual zipUSD == 0; `navEntry` stays ≈1e18.

**Notes.** Answers "what's a share worth" (= `navEntry`) and "where do shares go" (Loot→gate soulbound, szipUSD→depositor).
Exit/redeem is SP-13 (CoW) / SP-10 (senior queue). **Fork trap (carried from 2026-06-10):** the NAV oracle's wired
`ichiVault` is the POL WETH/USDC vault; any of that LP left in a counted Safe makes `grossBasketValue` revert
`UnknownLpToken` and bricks NAV — clean LP out of the Safes before NAV reads (the `evm_revert` baseline handles this).

**Result.** **PASS** (2026-06-24, live fork; `_harness.sh` seed; clean baseline gross=0, navEntry=1e18).
- `previewZap(1_000e6)` = (**1,000e18** zip, **1,000e18** shares); realized mint matched exactly.
- `zap(1_000e6)` status 1 (gas 1,072,019): `szipUSD.balanceOf(alice)` 0 → **1,000e18** = `totalSupply`. ✓
- **I-1 two-token invariant:** `Loot.balanceOf(gate)` = **1,000e18** == `szipUSD.totalSupply()`. ✓
- `zipUSD.balanceOf(mainSafe)` 0 → **1,000e18** (basket equity); **module residual zipUSD = 0** (clean custody). ✓
- `navEntry` stays **1e18** (1,000e18 gross / 1,000e18 supply). ✓
- Cap + setter-lock negatives: documented (cap path proven 2026-06-10 via Timelock `setTvlCap`); re-run requires a
  Timelock op (2-day warp). **No flaws.**
