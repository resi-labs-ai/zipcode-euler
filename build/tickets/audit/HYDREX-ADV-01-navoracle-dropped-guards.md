# HYDREX-ADV-01 — SzipNavOracleDemoVAMM silently dropped 3 audited guards its prod parent has

> **STATUS: BUILT + SHIPPED to `main` (2026-06-22).** All three guards back-ported from the prod parent
> `SzipNavOracle.sol`: `obsSpacing` (immutable + ctor derivation + conditional ring-advance in `_accumulate`),
> `StaleReport` (strictly-newer in `_processReport`), `RateUnseeded` (zero-rate in `_xAlphaUSD`). Added 3
> regression tests (`test_obsSpacing_pokeSpam_cannot_collapse_window`, `test_staleReport_non_newer_push_reverts`,
> `test_rateUnseeded_zero_rate_reverts`). Hydrex suite **48/48 green** (27 NAV + 21 LP), `forge build` clean.
> The existing 24 NAV tests were non-breaking (monotonic ts / seeded rates). X-Ray `SzipNavOracleDemoVAMM.md`
> corrected (it had rated ADEQUATE without the guards). The fork is now a faithful port of the parent's
> TWAP/push guards — closing the would-be-HIGH-on-promotion residual.

> BUILD item (demo-scoped LOW–MED now; **HIGH on promotion**). Source: adversarial-review on
> `contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` (synthesis under
> `adversarial-review/reports/src/hydrex-demo-fork/szipnavoracledemovamm/`, missions 1+2+3 converged).
> The differential baseline is the **audited prod parent** `contracts/src/supply/SzipNavOracle.sol` —
> the fork is "identical except the LP-leg valuation," but the diff found it also dropped three guards.

## The gap (all source-verified: present in parent, absent in fork)

1. **`obsSpacing` poke-spam throttle — DROPPED (the dangerous one).** Parent declares `obsSpacing`
   immutable (`SzipNavOracle.sol:95`) and advances a new TWAP ring slot ONLY once it has elapsed
   (`:354` `if (nowTs - observations[obsIndex].ts >= obsSpacing)`), so the `CARDINALITY-1` frozen
   checkpoints always span `≥ W` — "immune to poke-spam" (`:94`). The fork has **no `obsSpacing`** and
   advances a fresh slot on EVERY `poke` with `dt>0` (`SzipNavOracleDemoVAMM.sol:275`, unconditional).
   **Effect:** permissionless `poke()` (`:265`) spammed ~64× collapses the 65-slot ring to seconds;
   `twapNavPerShare` then finds no obs `≤ now-W` and falls back to `spot` (`:375`) → the bracket
   degenerates to `navEntry=navExit=spot`. That **defeats the only defense** on the spot-`getReserves()`
   LP leg (mission-1 confirmed the bracket otherwise fences an in-block reserve push — but only while the
   TWAP window holds). Cross-mission amplifier: collapse the TWAP, then manipulate spot reserves → move
   `navEntry`/`navExit` → mint cheap / exit rich.
2. **`RateUnseeded` zero-rate guard — DROPPED.** Parent `_xAlphaUSD` reverts on an unseeded rate
   (`:575` `if (rate == 0) revert RateUnseeded();`). The fork (`_xAlphaUSD`, ~`:418-424`) has no check →
   an `exchangeRate()==0` (M1 stand-in or re-pointed-unseeded `SzAlphaRateOracle`) silently values the
   entire xALPHA leg at $0 → NAV understated (fail-open where the parent fails closed).
3. **`StaleReport` strictly-newer push guard — DROPPED.** Parent `_processReport` rejects a non-newer ts
   (`:320` `if (prior.ts != 0 && ts <= prior.ts) revert StaleReport();` — "a backdated replay would
   otherwise slip through and freeze issuance"). The fork's loop has no ts-monotonicity check → a
   backdated in-band push rewinds `legCache.ts` (freeze issuance / re-seat a stale mark). Trust-bounded
   (needs the Forwarder to deliver out-of-order), but it is a dropped audited control.

The fork dropped both the checks AND the error declarations (`StaleReport`/`RateUnseeded` absent from the
fork's error list). The X-Ray rates the contract **ADEQUATE** and did not catch any of the three — the
X-Ray over-claims and must be corrected too.

## Why demo-scoped now, HIGH on promotion
Today: small showcase HYDX/USDC pool, no real junior capital, only the demo ExitGate reads it → bounded.
BUT `docs/hydrex-demo-fork.md` explicitly plans to **promote this fork to a mainnet szALPHA/zipUSD
deployment** once the real pool exists. On a real-value deployment the obsSpacing+spot-LP combo is a
genuine NAV-manipulation (mint-cheap/exit-rich) → **HIGH**. Treat as **fix-before-promotion**.

## Fix
Back-port the three guards from the prod parent (the fork is supposed to be "identical except the LP leg"):
1. `obsSpacing` immutable + ctor derivation (`SzipNavOracle.sol:217`) + the conditional slot-advance in
   `_accumulate` (`:354-356`). One-for-one, no LP-seam interaction.
2. `RateUnseeded` error + `if (rate == 0) revert RateUnseeded();` in `_xAlphaUSD` (`:575`).
3. `StaleReport` error + `if (prior.ts != 0 && ts <= prior.ts) revert StaleReport();` in `_processReport`
   (`:320`).

## Gate
`forge build` clean + `forge test --match-path 'test/hydrex-demo-fork/*.t.sol'` green. Add regression tests
the ported parent has but the fork's suite lacks: a `poke`-spam test asserting the TWAP window survives
(parent's `obsSpacing` test), an unseeded-rate revert, and a backdated-push revert.

## Next step — documentation propagation (after code lands)
- `contracts/src/hydrex-demo-fork/x-ray/SzipNavOracleDemoVAMM.md` — correct the verdict: it currently
  rates ADEQUATE while three parent guards were absent; record that they're now restored + the new tests.
- `contracts/src/hydrex-demo-fork/x-ray/x-ray.md` (scope) + `docs/wires/SHOWCASE-VAMM.md` — note the
  fork is now a faithful port of the parent's TWAP/push guards.

## Acceptance criteria
- `obsSpacing`, `RateUnseeded`, `StaleReport` present in the fork, matching the parent; suite green with
  the three new regression tests.
- X-Ray (`SzipNavOracleDemoVAMM.md`) no longer over-claims; the dropped-guard residual is closed.
