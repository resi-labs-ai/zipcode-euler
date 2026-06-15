# SEC-04 — `_xAlphaUSD()` fail-close on unseeded rate (H5)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` H5 (DECIDE→fail-close); `build/claude-zipcode.md`
§7 (NAV max-entry/min-exit asymmetry); audit `findings.md`, `interconnection-findings.md` · **Status:** PROPOSED

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
