# SP-06 — Junior zap → share issuance (HEADLINE)

**Intent.** The core junior question: deposit, get szipUSD; how much is a share worth; how many shares per zipUSD;
where do the Loot and the receipt shares go.

**Proves.** `ZipDepositModule.zap`: USDC→zipUSD→EE pool, then `ExitGate.depositFor` values the zipUSD via the NAV
oracle and mints `shares = value·1e18/navEntry` (rounded DOWN); **Loot minted to the GATE (soulbound), szipUSD
receipt minted to the depositor**; zipUSD routed into the main Safe basket; the two-token invariant; the TVL cap.

**Tier.** Needs-forwarder (NAV legs fresh so `navEntry()` doesn't `StalePrice`).

**Binds to.** `ZipDepositModule` `0x6ecc7172…` (`zap` L129-149, `previewZap`), `ExitGate` `0xd9b8393f…`
(`depositFor` L151-176, `previewDeposit`), `SzipNavOracle` `0x0C3E7731…` (`navEntry`,`valueOf`), szipUSD
`0x33aD3E23…`, Loot `0xE7501dD9…`, Baal `0xdc4f3Bb2…`, main Safe `0x0B9C95c7…`. Source: `WOOF-06.md`, `ExitGate-szipUSD.md`.

**Setup.**
- Push fresh NAV legs (Forwarder). At genesis `navEntry()==1e18`.
- `deal` 1,000e6 USDC to `alice`; approve `ZipDepositModule`.
- Read `previewZap(1_000e6)` for the expected share estimate.

**Calls.**
1. `SzipNavOracle.poke()` (advance TWAP).
2. `ZipDepositModule.zap(1_000e6) as alice`.
3. (cap negative) deploy/lower `tvlCap` or deposit past it → `depositFor` reverts `TvlCapExceeded`.

**Assertions.**
- `szipUSD.balanceOf(alice) == valueOf(zipUSD,1000e18)·1e18/navEntry` rounded down (≈ 1,000e18 at genesis NAV 1e18).
- `Loot.balanceOf(ExitGate) == szipUSD.totalSupply()` — the two-token invariant (Loot→gate, szipUSD→depositor).
- `Baal.totalShares() == 0` (governance inert).
- `zipUSD.balanceOf(mainSafe)` rose by 1,000e18 (basket equity); deposit-module residual zipUSD == 0.
- after-zap `grossBasketValue()` reflects the basket; re-reading `navEntry` stays ≈1e18.

**Notes.** Answers "how much is a share worth" (= `navEntry`) and "shares minted to exit gate + receipt shares to
addresses" (Loot→gate soulbound, szipUSD→depositor). The exit/redeem side is SP-13 (CoW) / SP-10 (senior queue).

**Result.** **PASS** (2026-06-10, real txs on anvil — first CRE-forwarder path).

Preconditions (CRE pushes via impersonated Forwarder `0xF834…4482`):
- Pushed the **xALPHA rate** to `SzAlphaRateOracle` (reportType 8, `abi.encode(rate=1e18, ts)`) → `fresh()` true, `exchangeRate` 1e18. **Required** — `xAlphaRateOracle` is wired, so `navEntry` reverts `StaleRate` until a rate is pushed.
- Pushed the **NAV legs** to `SzipNavOracle` (reportType 7, legs `[0,1]` = [alphaUSD, HYDX], prices `[1e18, 5e16]`, ts) → `fresh()` true, **`navEntry()` = 1e18** (genesis), `navExit` 1e18.
- Metadata format: `abi.encodePacked(workflowId(32), workflowName(10), workflowOwner(20))` = **62 bytes** exactly; sealed id `0x…01`, author `0x90F7…`. (Initial pushes failed `InvalidAuthor` due to a hand-typed 11-byte name — my typo, not a contract bug; the documented 10-byte-name layout decodes correctly.)

Calls & deltas (zap 1,000e6 as alice):
1. `poke()`. 2. `zap(1000e6)` → status 1, 882,881 gas.
- `previewZap(1000e6)` = (1000e18 zip, **1000e18 shares**) and the realized mint matched exactly.
- `szipUSD.balanceOf(alice)` 0 → **1000e18** = value(1000e18)·1e18/navEntry(1e18), round-down. ✓
- **Two-token invariant:** `Loot.balanceOf(gate)` = **1000e18** == `szipUSD.totalSupply()` 1000e18. ✓
- `Baal.totalShares()` = **0** (governance inert). ✓
- `zipUSD.balanceOf(mainSafe)` 0 → **1000e18** (basket equity); **module residual zipUSD = 0** (the zap's F1/F7 clean-custody check). ✓
- `grossBasketValue` → **1000e18**; `navEntry` stays **1e18** (1000e18 gross / 1000e18 supply). ✓
3. (cap neg) Timelock `setTvlCap(1500e18)`, then `zap(1000e6)` → gross 1000e18 + value 1000e18 = 2000e18 > 1500e18 → **`TvlCapExceeded` (0xb0e52638)**. Cap restored to 1e26. ✓

**Resolves the SP-02 carry-forward:** genesis issuance is *not* free — `navEntry` requires both NAV legs AND (since the rate oracle is wired) the xALPHA rate CRE-pushed first; once pushed, `navEntry` = 1e18 at zero supply and the first zap prices cleanly.

**Finding (fork caveat + cross-path contamination risk):** the NAV oracle's wired `ichiVault` on this fork is the **POL WETH/USDC** vault `0x07e72E46…`, but the oracle's LP leg only prices zipUSD/xAlpha reserve tokens — so **any** of that POL LP sitting in the main/sidecar Safe makes `grossBasketValue` revert `UnknownLpToken(WETH)` and bricks the entire NAV (issuance AND exit reads). SP-04 left 200,000 of that LP + 10 USDC in the main Safe; I cleared both (storage writes) to restore a clean genesis basket before this path. In production the wired vault is the real zipUSD/xAlpha pool (reserves are priceable) so this can't happen — but on the fork it's a live trap, and it shows the two markets share the same LP token: the reservoir collateral LP and the NAV basket LP are the same `0x07e72E46…` here. Flagging so later paths (SP-15/17) clean LP out of the Safes before reading NAV.
