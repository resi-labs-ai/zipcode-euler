# SEC-04 — `_xAlphaUSD()` fail-close on unseeded rate (H5)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` H5 (DECIDE→fail-close); `build/claude-zipcode.md`
§7 (NAV max-entry/min-exit asymmetry); audit `findings.md`, `interconnection-findings.md` · **Status:** DONE (2026-06-15)

> Scope authored 2026-06-15. The decision is settled (per kill-list + memory `exit-topology-intentional`):
> **fail closed on UNSEEDED only, keep the §7 asymmetry.** Do NOT gate exit/coverage on `fresh()`.

## Deliverable
Make `SzipNavOracle._xAlphaUSD()` revert `RateUnseeded()` when the xALPHA exchange rate has never been seeded
(`exchangeRate() == 0`), instead of silently returning 0 and underpricing xALPHA across every consumer.

## What it does / what's being fixed (plain language)
`_xAlphaUSD()` returns USD-per-xALPHA = `exchangeRate() × pushed alphaUSD`. `exchangeRate()` does NOT revert
when unseeded — it returns 0 — so `_xAlphaUSD()` silently returns **0**, valuing the entire xALPHA leg at
nothing. Three ungated consumers then read a too-low number: **navExit** (underpays junior exits), the freeze
module's **coverageValue** (under-counts the coverage floor → can mis-gate outflow), and **ExitGate's tvlCap**
check (under-reads gross → lets deposits exceed the real cap). The narrow correct fix is to fail closed when
the rate was never seeded — a genesis/uninitialized state, distinct from a stale-but-seeded mark.

## Binds to (verified file:line — 2026-06-15)
- **Fix site:** `contracts/src/supply/SzipNavOracle.sol:508-514` — `_xAlphaUSD()`. Rate source is
  `xAlphaRateOracle` if wired, else `xAlpha` (M1 stand-in); value =
  `IXAlphaRate(rateSrc).exchangeRate() * legCache[LEG_ALPHA_USD].price / 1e18`.
- **Consumers that inherit the fix (no edits needed — the fix is in the shared internal):**
  - `grossBasketValue()` `:343-352` (xALPHA leg `:346`) → `spotNavPerShare()`/`twapNavPerShare()` → **navExit** `:483-487`.
  - `_grossValueOf()` `:370-379` (xALPHA leg `:373`) → `committedValue`/`freeValue` → freeze module **coverageValue**.
  - `_legPriceOfToken()` `:524-528` (`:526`) → LP reserve valuation.
  - `ExitGate.sol:163` — `grossBasketValue() + value > tvlCap` (the `:161` `navEntry()` is fresh-gated; this cap leg is not).
- **Asymmetry to preserve (do NOT touch):** `navEntry()` `:471-480` reverts `StalePrice`/`StaleRate` on stale
  legs (issuance pauses); `navExit()` `:482-487` never reverts on staleness (prices off last-good); `fresh()` `:490-494`.

## Key requirements
1. In `_xAlphaUSD()`, capture the rate into a local, then guard:
   ```solidity
   uint256 rate = IXAlphaRate(rateSrc).exchangeRate();
   if (rate == 0) revert RateUnseeded();
   return rate * legCache[LEG_ALPHA_USD].price / 1e18;
   ```
2. Declare `error RateUnseeded();` on `SzipNavOracle`.
3. Update the `_xAlphaUSD()` docstring (`:509-511`) to state: fail-closed on **unseeded** rate (≠ stale);
   staleness is still NOT gated here (the §7 last-good-mark exit asymmetry is intact).

## Do NOT
- **Do NOT gate `navExit`/`coverageValue`/`grossBasketValue` on `fresh()`** — that breaks the deliberate §7
  max-entry/min-exit (last-good-mark) asymmetry. Failing closed on *unseeded* is the narrow, correct fix.
- Do NOT change `navEntry`/`navExit`/`fresh`/`_legStale` or the `StalePrice`/`StaleRate` paths.
- Do NOT extend the guard to a stale-but-nonzero rate — only `rate == 0` (never-seeded) reverts.
- Do NOT touch the alphaUSD leg-write zero-guard (a separate concern); the named hole is the rate. *(If, while
  implementing, `legCache[LEG_ALPHA_USD].price` can also be 0 on the same path — i.e. the alpha leg can be unseeded
  independently — confirm whether that silent-zero also needs covering and flag it as back-pressure rather than
  silently widening scope. The kill-list scopes this fix to the rate.)*
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC04_*` regression test** that fails before / passes after:
  - **Unseeded fail-close:** with the xALPHA exchange rate unseeded (`exchangeRate() == 0`) but the protocol
    holding xALPHA, assert `navExit()`, `grossBasketValue()`, the freeze `coverageValue()`, and the
    `ExitGate` deposit path (tvlCap leg) all revert `RateUnseeded()` (pre-fix they return a silently-underpriced
    value / succeed).
  - **Seeded prices:** seed `exchangeRate() > 0`; assert the same reads price the xALPHA leg correctly.
  - **Asymmetry preserved:** with the rate SEEDED but the pushed legs/rate **stale** (nonzero), assert
    `navExit()` still returns a value (does NOT revert) while `navEntry()` still reverts `StalePrice`/`StaleRate`
    — proving the fix did not collapse the §7 asymmetry.
- Quote the actual `forge test` output in this ticket's done note.

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-04" with the finding note.

---

## DONE — 2026-06-15

**Status: DONE.** Fail-close-on-unseeded landed in `SzipNavOracle.sol` exactly as scoped; the §7 asymmetry is intact.

### What changed (1 file, `contracts/src/supply/SzipNavOracle.sol`)
- Declared `error RateUnseeded();` (with the other oracle errors).
- `_xAlphaUSD()` (now `:517-525`) captures the rate into a local and fails closed:
  ```solidity
  address rateSrc = xAlphaRateOracle == address(0) ? xAlpha : xAlphaRateOracle;
  uint256 rate = IXAlphaRate(rateSrc).exchangeRate();
  if (rate == 0) revert RateUnseeded();
  return rate * legCache[LEG_ALPHA_USD].price / 1e18;
  ```
- Docstring updated: fail-closed on **unseeded** (≠ stale); staleness still NOT gated here (the §7 last-good-mark
  exit asymmetry intact).
- The guard is in the **shared internal**, so all four named consumers inherit it with no consumer edits:
  `navExit`/`spotNavPerShare`/`grossBasketValue` (`:349`), `_grossValueOf` → freeze `coverageValue`, `valueOf`/
  `_legPriceOfToken` (`:537`), and `ExitGate.depositFor` (reverts via `navEntry`/`grossBasketValue` at
  `ExitGate.sol:161/163`).

### Do-NOTs honored
- No `fresh()`/staleness gate added to exit/coverage/gross — only `rate == 0` reverts. `navEntry`/`navExit`/`fresh`/
  `_legStale`/`StalePrice`/`StaleRate` are byte-for-byte unchanged (asymmetry test proves it).
- Did not extend the guard to stale-but-nonzero. Did not touch the alphaUSD leg-write zero-guard. **Flagged check
  resolved (no back-pressure):** `legCache[LEG_ALPHA_USD].price` cannot be seeded to 0 — `_processReport` rejects
  `ZeroPrice` on every write — so only the rate's genesis zero slipped through; scope correctly stayed on the rate.

### Critics (ran before the test, both PASS)
- **spec-fidelity:** PASS — faithful to H5, no invented mechanism, §17 / §7 asymmetry honored, no `fresh()` gate.
- **reference-verifier:** PASS — `IXAlphaRate.exchangeRate()` real + returns 0 on unseeded (no revert) on both the
  wired `SzAlphaRateOracle` and the M1 stand-in; all four consumer routings confirmed; `RateUnseeded` uniquely
  declared. (Noted the ticket's `508-518` line cites were stale → actual `517-525`; corrected in the bindings above.)

### Gate (green)
- `cd contracts && forge build` → **Compiler run successful.**
- `forge test` → **774 passed / 0 failed / 3 skipped** (the 3 skips are the pre-existing `DeployZipcode.t.sol` skips;
  +5 over SEC-03's 769).
- The 5 new `test_SEC04_*` regressions:
  ```
  [PASS] test_SEC04_unseeded_rate_fails_closed()            (SzipNavOracle.t.sol)
  [PASS] test_SEC04_seeded_rate_prices_correctly()          (SzipNavOracle.t.sol)
  [PASS] test_SEC04_asymmetry_preserved_when_stale()        (SzipNavOracle.t.sol)
  [PASS] test_SEC04_unseeded_rate_reverts_coverageValue()   (DurationFreezeModule.t.sol::SzipNavOracleParityTest)
  [PASS] test_SEC04_unseeded_rate_reverts_deposit()         (ExitGate.t.sol)
  Ran 3 test suites: 5 tests passed, 0 failed, 0 skipped (5 total tests)
  ```
- **Fail-before/pass-after confirmed:** temporarily reverting `_xAlphaUSD()` to the un-guarded
  `return exchangeRate() * price / 1e18` reproduces all 3 unseeded-revert tests as
  `FAIL: next call did not revert as expected` (the silently-underpriced read returns instead of reverting). Guard
  restored, build re-verified clean.

### Coverage of the "Done when" surfaces
- **Unseeded fail-close** — `navExit()` + `grossBasketValue()` + `spotNavPerShare()` + `valueOf(xAlpha)` (oracle unit);
  freeze `coverageValue()` over the REAL oracle (`DurationFreezeModule.t.sol`); `ExitGate.depositFor` deposit path
  (`ExitGate.t.sol`) — all revert `RateUnseeded`.
- **Seeded prices** — `grossBasketValue() == 11779e17` and `valueOf(xAlpha,5e18) == 12e18` with `exchangeRate()>0`.
- **Asymmetry preserved** — rate seeded, legs stale: `navExit()` returns (no revert), `navEntry()` reverts `StalePrice`.

### Doc-sync (full checklist run)
ticket (this note) · `PROGRESS.md` (SEC-04 DONE, SEC-05 NEXT, "Just done" note) · `kill-list.md` H5 `[x]` + DONE ·
`audit-claude/` (findings #6 + SUMMARY H5 RESOLVED; interconnection C1 **partially** resolved — upward-stale half is
intended residual) · `wires/8-B4-SzipNavOracle.md` (leg-3 fail-close + navExit caveat) · report
`build/reports/SEC-04-report.md`. **No spec change** (interface-level fix, §7 intent unchanged). **No new obligation.**
