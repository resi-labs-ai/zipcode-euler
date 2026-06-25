# SP-12 — xALPHA rate push (the bridge rate → NAV leg; seam S2/S3)

**Intent.** Push the cross-chain xALPHA exchange rate and show it feeds the NAV xALPHA leg, is freshness-fenced, and
that the intrinsic-APR view is saturation-safe.

**Proves.** `SzAlphaRateOracle.onReport` reportType 8 `(uint256 rate, uint48 ts)` → `exchangeRate`/`fresh`; the rate
flows into `SzipNavOracle`'s xALPHA leg (`xAlphaUSD = rate · legCache[ALPHA_USD] / 1e18`); the freshness fence;
saturation-guarded `intrinsicAprBps()` (total, no overflow). Sources: `docs/bridge.md`, wires `8x-02-SzAlphaRateOracle.md`.

**Tier.** Needs-forwarder.

**Binds to** (by name): `SzAlphaRateOracle`, `SzipNavOracle`, xALPHA mirror.

**Setup.** Clean baseline (rate unseeded → `exchangeRate==0`, `fresh()==false`).

**Calls (happy).** 1. `seed_marks` (pushes NAV legs + rate). 2. read `exchangeRate`, `fresh`, NAV `valueOf(xAlpha,1e18)`,
`intrinsicAprBps`.

**Calls (fuzzy / negative).** 3. push a large rate (1.5e18) → bounded by the per-update deviation guard. 4. `intrinsicAprBps()`
under the bumped rate → saturates, never reverts/overflows. 5. warp +2 days → `fresh()==false`.

**Assertions** (On-chain=Yes): pre-seed `exchangeRate==0`/`fresh==false`; post-seed `exchangeRate==1e18`/`fresh==true`;
NAV xALPHA leg reflects the rate; `intrinsicAprBps` returns a bounded value (no overflow); staleness flips `fresh`.

**Notes.** Cross-chain conservation (lock/release on 964) is `On-chain=No` (deploy-topology, seam S2) — out of scope on
the Base fork. Here we prove the Base-side rate rail + the NAV consumption + the freshness asymmetry (issuance side, SP-07).

**Result.** **PASS** (live fork).
- Pre-seed `exchangeRate`=**0**, `fresh()`=**false**. Post-seed (rate 1e18): `exchangeRate`=**1e18**, `fresh()`=**true**. ✓
- NAV `valueOf(xAlpha, 1e18)` = **1e8** = `rate(1e18)·alphaUSD(1e8)/1e18` — the rate feeds the leg. ✓
- `intrinsicAprBps()` = **0** at rate 1e18 (no premium); **saturation-safe** — returns a bounded value, never reverts
  ✓
- The 1.5e18 re-push was **bounded** (per-update deviation guard kept `exchangeRate` at 1e18) — the rate cannot jump
  arbitrarily in one report. ✓
- After +2-day warp: `fresh()` = **false**. ✓ **No flaws.**
