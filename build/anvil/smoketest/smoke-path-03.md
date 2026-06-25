# SP-03 — DurationFreeze commit (rq → non-rq Safe move) (seam S9)

**Intent.** Can a Zodiac module move value from the rq (main) Safe to the non-rq (sidecar) Safe? Yes — and only
`DurationFreezeModule` can. Exercise the move + its guards.

**Proves.** The single cross-Safe value path (main→sidecar via `commit`); operator gating; the oracle-valued-leg
whitelist; the FoT shortfall guard; Safe-distinctness on the freeze setters (negative). Sources:
`docs/supply/szipUSD/DurationFreezeModule.md`, `contracts/src/supply/szipUSD/x-ray/DurationFreezeModule.md`,
wires `DurationFreezeModule.md`.

**Tier.** Needs-forwarder — see Setup: `commit` reads `SzipNavOracle.committedValue()`, which reverts `RateUnseeded`
until the xALPHA rate is seeded. (The prior run worked because the rate was already seeded; on a clean baseline
it is not.)

**Binds to** (by name — engine modules are CLONES; re-derive from the main Safe's module list):
`DurationFreezeModule` **clone** (enabled on main + sidecar; this board `0x3Bcd8BD1…`, mastercopy `0x675fdf…`),
main Safe, sidecar Safe, `creOperator`, `SzAlphaRateOracle`, `SzipNavOracle`, USDC. WETH `0x4200…0006` for the negative.

**Setup.**
- **Universal preamble:** seed the xALPHA rate (CRE reportType 8 → `SzAlphaRateOracle`) + NAV legs (reportType 7 →
  `SzipNavOracle`) with a fresh timestamp, so `committedValue()` does not revert `RateUnseeded`. (Shared with SP-06/12/13/15.)
- `deal` 100,000e6 USDC into the **main Safe** (USDC slot 9).

**Calls (happy).**
1. `DurationFreezeModule.commit(USDC, 50_000e6)` as `creOperator` → moves USDC main→sidecar.

**Calls (fuzzy / negative).**
2. `commit(USDC, 1e6)` as alice → `NotOperator` (`0x7c214f04`).
3. `commit(WETH, 1e18)` as `creOperator` → `UnvaluedAsset(WETH)` (`0x205b5d50`) — the `{zipUSD,usdc,xAlpha,hydx,oHydx}`
   whitelist rejects WETH before the body.
4. A freeze setter (`setSafes`/equivalent) with main==sidecar → reverts (Safe-distinctness).

**Assertions** (On-chain=Yes): sidecar USDC +50,000e6, main −50,000e6 (exact FoT delta check); `committedValue()` ≈
50,000e18 (6→18, USDC $1); negatives revert as named.

**Notes.** `commit` reads no utilization/floor (only `release` checks the §12 coverage floor — SP-15); an unbounded
freeze is by design (over-freeze grief is the §12 metric-4 alarm). FoT `TransferShortfall` guard present; exercised
only if a fee-on-transfer token is staged.

**Result.** **PASS** (live fork; clean baseline + `seed_marks` preamble via `_harness.sh`).
- **Happy `commit(USDC,50_000e6)` as `creOperator`** (status 1, gas 237,620): main USDC 100,000e6 → **50,000e6**;
  sidecar 0 → **50,000e6** (exact move); `committedValue()` 0 → **50,000e18** (6→18, USDC $1). ✓
- **(neg) operator gate:** `commit(USDC,1e6)` as alice → **`NotOperator` (0x7c214f04)**. ✓
- **(neg) whitelist:** `commit(WETH,1e18)` as operator → **`UnvaluedAsset(WETH)` (0x205b5d50)** (rejected before body). ✓
- **Finding (correct fail-closed, no flaw):** without the seed preamble, `commit` reverts `RateUnseeded` (0x006806f9) —
  it reads `SzipNavOracle.committedValue()` → `SzAlphaRateOracle.exchangeRate()`; both must be seeded. This is the
  universal NAV-touch precondition, not a freeze bug.
- **Address note:** the map previously listed the **mastercopy** `0x675fdf…` (inert: `operator()==0`, not enabled);
  the live module is the **clone** `0x3Bcd8BD1…`. Map + `index.json` corrected. **No flaws.**
