# SP-02 — NAV oracle genesis + read surface

**Intent.** Establish what a szipUSD share is worth before any deposit, and exercise the NAV oracle's full read
surface — the pricing primitive the whole junior side hinges on.

**Proves.** `GENESIS_NAV` at zero supply; `poke`/TWAP accumulation; the `navEntry=max(spot,twap)` /
`navExit=min(spot,twap)` asymmetry; the `freeValue()+committedValue()==grossBasketValue()` additivity (FREE = main
Safe, COMMITTED = sidecar); `valueOf`.

**Tier.** Pure on-chain (reads; `navEntry` needs fresh legs only once supply>0 — at genesis it short-circuits).

**Binds to.** `SzipNavOracle` `0x0C3E7731…`. Source: `contracts/src/supply/SzipNavOracle.sol`
(`spotNavPerShare` L334-340 `GENESIS_NAV`, `navEntry` L368-377, `navExit` L380-384, `grossBasketValue` L273-293,
`committedValue` L300-302, `freeValue` L305-307, `valueOf` L437-439, `poke` L255-257), wires `8-B4-SzipNavOracle.md`.

**Setup.** None (genesis state, zero szipUSD supply).

**Calls / reads.**
1. `SzipNavOracle.spotNavPerShare()` → expect `1e18` (GENESIS_NAV at zero effective supply).
2. `SzipNavOracle.navExit()` → `1e18` at genesis. `SzipNavOracle.navEntry()` → **reverts `StalePrice(LEG_ALPHA_USD)`** at genesis: the leg-staleness guards run unconditionally (before any supply check), so with no CRE-pushed legs issuance fail-closes. (It returns `1e18` only once the legs + xALPHA rate are pushed — see SP-06.)
3. `SzipNavOracle.poke()` (permissionless); call twice across `cast rpc evm_mine` / a warp; read `twapNavPerShare()`.
4. `SzipNavOracle.grossBasketValue()`, `committedValue()`, `freeValue()` → assert `free + committed == gross` (== 0 at genesis).
5. `SzipNavOracle.valueOf(zipUSD, 100e18)` → expect `100e18` (zipUSD valued $1). `valueOf(xAlphaMirror, …)` returns the xALPHA leg value.

**Assertions.** As inline above; the additivity identity is the key structural check.

**Notes.** After SP-06 funds the basket, re-run reads to see `gross/free` move and `navEntry` reflect the basket.
`navEntry` reverts `StalePrice` whenever the pushed legs (alphaUSD/HYDX) are stale — including at genesis (legs never pushed) and once they age out (SP-07). Genesis issuance therefore requires a CRE seed (legs + xALPHA rate) first.

**Result.** **PASS with a spec correction** (2026-06-10, reads + 2 poke txs on anvil). Basket genesis intact — SP-01 left zipUSD in alice/bob wallets, not in the Safes (the oracle counts only `mainSafe + sidecar`), and no szipUSD was minted.

Reads:
1. `spotNavPerShare()` = **1e18** (GENESIS_NAV, zero effective supply). ✓
2. `navExit()` = **1e18** ✓. **`navEntry()` REVERTED `StalePrice(0)`** (`0x9bbfef51`, leg 0 = `LEG_ALPHA_USD`) — *not* 1e18.
3. `poke()` → warp +600s (`evm_increaseTime`/`evm_mine`) → `poke()`; `twapNavPerShare()` = **1e18** before and after (spot is constant at genesis). ✓
4. `grossBasketValue()` = `committedValue()` = `freeValue()` = **0**; additivity `free + committed == gross` holds exactly. ✓
5. `valueOf(zipUSD, 100e18)` = **100e18** ✓. `valueOf(xAlpha, 100e18)` = **0** — correct: `_xAlphaUSD = exchangeRate × legCache[ALPHA_USD].price / 1e18`, and the alphaUSD leg is unpushed (price 0) at genesis. `fresh()` = **false**.

**Finding — the spec expectation is stale, the contract is right (no flaw).** SP-02 (line 20 + the line-11 note) claims `navEntry` "short-circuits" to 1e18 at genesis. It does not: `navEntry` (L368-373) runs the leg-staleness guards **unconditionally, before** any supply check, so with no CRE-pushed legs it fail-closes `StalePrice(LEG_ALPHA_USD)`. This is the correct fail-closed posture — it agrees with `fresh() == false`, and issuance must not quote a price off unpushed legs. Consequence to carry into SP-06: the first zap into the empty basket cannot price via `navEntry` until the alphaUSD + HYDX legs are CRE-pushed; genesis issuance therefore depends on a prior CRE push (or a spot-path) — verify which in SP-06. Spec lines 20/27 should read "navEntry reverts `StalePrice` at genesis until the legs are pushed."
