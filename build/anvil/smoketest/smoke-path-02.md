# SP-02 — NAV oracle genesis + read surface (the S8 pricing input)

**Intent.** Establish what a szipUSD share is worth before any deposit, and exercise the NAV oracle's read surface —
the pricing primitive the whole junior side hinges on (feeds S8 issuance, S9 freeze floor, S10 buy-burn bid).

**Proves.** `GENESIS_NAV` at zero supply; `poke`/TWAP accumulation; SzipNavOracle **I-1** bracket asymmetry
(`navEntry=max(spot,twap)`, `navExit=min(spot,twap)`); `freeValue()+committedValue()==grossBasketValue()` additivity;
`valueOf`; and the two **fail-closed** genesis guards. Sources: `docs/supply/SzipNavOracle.md`,
`contracts/src/supply/x-ray/SzipNavOracle.md`, wires `8-B4-SzipNavOracle.md`.

**Tier.** Pure on-chain (reads + 2 permissionless `poke`s).

**Binds to** (by name): `SzipNavOracle`, zipUSD, xALPHA mirror (stand-in).

**Setup.** None (genesis: zero szipUSD supply, empty basket, legs/rate unpushed).

**Calls / reads (happy).**
1. `spotNavPerShare()` → `1e18` (GENESIS_NAV at zero effective supply).
2. `navExit()` → `1e18`. `twapNavPerShare()` after `poke`/warp/`poke` → `1e18` (spot constant at genesis).
3. `valueOf(zipUSD, 100e18)` → `100e18` (zipUSD valued $1); `fresh()` → `false`.

**Calls / reads (fuzzy / negative — fail-closed guards).**
4. `navEntry()` → **reverts `StalePrice(LEG_ALPHA_USD)`** (leg-staleness guards run unconditionally, before any supply
   check — issuance must never quote off unpushed legs).
5. `grossBasketValue()` / `committedValue()` / `freeValue()` / `valueOf(xAlpha,·)` → **revert `RateUnseeded()`**
   (`0x006806f9`) until the xALPHA rate is seeded.

**Assertions** (On-chain=Yes): genesis spot/exit/twap == `1e18`; `valueOf(zipUSD)` linear at $1; `navEntry` fail-closes
`StalePrice`; basket reads fail-close `RateUnseeded`. The additivity identity `free+committed==gross` is verified in
the **funded + seeded** state (SP-06), since at genesis the basket reads fail-closed.

**Notes.** **Drift vs the 2026-06-10 run (correct, no flaw):** `grossBasketValue` etc. then returned `0`; they now
**fail-close `RateUnseeded()`** (the BRIDGE-ADV-02 structural genesis-seed guard) — the basket cannot be priced until
the rate oracle is seeded. This agrees with `fresh()==false`. Issuance therefore depends on a prior CRE seed
(legs + rate); see SP-06/SP-12.

**Result.** **PASS** (2026-06-24, reads + 2 `poke` txs on the live fork; clean baseline).
- `spotNavPerShare()` = `navExit()` = `twapNavPerShare()` = **1e18** (GENESIS_NAV; twap flat across a +600s warp). ✓
- `valueOf(zipUSD,100e18)` = **100e18**; `fresh()` = **false**. ✓
- `navEntry()` **reverted** (leg-staleness fail-closed). ✓
- `grossBasketValue()`/`committedValue()`/`freeValue()`/`valueOf(xAlpha,·)` **reverted `RateUnseeded()` (0x006806f9)** —
  the new genesis-seed guard. ✓ Additivity deferred to the seeded/funded state (SP-06). **No flaws** (stricter than the
  2026-06-10 behavior — fail-closed where it previously returned 0).
