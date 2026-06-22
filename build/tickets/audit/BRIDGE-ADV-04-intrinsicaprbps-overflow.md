# BRIDGE-ADV-04 — `intrinsicAprBps()` overflow breaks its "never reverts" contract; the invariant that "proves" it is vacuous

> **STATUS: BUILT (2026-06-22)** on branch `audit/bridge-adv-04-aprbps-overflow`, awaiting review/merge.
> Shipped: two overflow-free saturation guards in `intrinsicAprBps` (`SzAlphaRateOracle.sol`) — growth that
> would overflow the multiply-up ⇒ `aprCap`, a rate that would overflow the `a.rate*dt` denominator ⇒ `0` —
> making the view genuinely total (chosen over `mulDiv`, which can't saturate the `type(uint256).max`-vs-tiny-anchor
> case). Tests: `testFuzz_aprBoundedAndNonNegative` + the invariant handler now fuzz the FULL uint256 rate
> domain (no longer vacuous), plus `test_apr_extremeRate_saturatesToCapNoRevert`. Rate-oracle suite **23/23
> green**, `forge build` clean. Doc-sync: X-Ray `SzAlphaRateOracle.md` (§4 + I-4), wire `8x-02`.

> BUILD item (LOW). Source: adversarial-review pilot on `contracts/src/bridge/SzAlphaRateOracle.sol`
> (`adversarial-review/reports/src/bridge/szalpharateoracle/synthesis.md`, missions 1+2 — both found it
> independently). Resolves an open residual the X-Ray itself flagged: §4 "APR annualization
> precision/overflow ... the multiply-up is the place an unbounded rate could overflow before the clamp ...
> worth a fuzz confirming no overflow/no revert across the full rate/dt domain."

## The defect (verified in code)

`intrinsicAprBps()` is documented as total — `:128-129`: "Advisory; **never reverts**" — and
`invariant_aprBoundedNeverReverts` (`contracts/test/bridge/SzAlphaRateOracle.t.sol:257`) asserts it. It
is not total.

- The push path imposes **no upper bound** on `rate`: `_processReport:84-86` rejects only `rate == 0`,
  future ts, and non-strictly-newer ts (the deliberate "no deviation band" design). So `latest.rate` may
  be any value up to `type(uint256).max`.
- `intrinsicAprBps:140` computes `(rNow - a.rate) * BPS * SECONDS_PER_YEAR / (a.rate * dt)` — the
  multiply-up happens **before** the clamp at `:141`. `BPS * SECONDS_PER_YEAR ≈ 2^39`, so the numerator
  overflows uint256 once `rNow - a.rate > ~2^218`. A push near `type(uint256).max` with a small anchor
  reverts the view (Solidity 0.8 checked-arithmetic panic) before `if (annual > aprCap)` can fire.

## The test gap (the more useful half)

`invariant_aprBoundedNeverReverts` passes **vacuously**: `testFuzz_aprBoundedAndNonNegative:191` does
`bound(rNow, 1, 1e24)` and the invariant handler `push:218` does `bound(rate, 0, 1e24)`. `1e24 ≈ 2^80` is
~138 bits below the 2^218 overflow threshold, so neither suite can ever land a rate large enough to trip
the revert. The property is asserted but never actually exercised at its failing region.

## Why it's LOW (don't over-rate)

`intrinsicAprBps()` has **no on-chain consumer** — grep over `contracts/src` returns only its own
definition + doc comments, and the contract's own docstring (`:128-129`) states "NAV does NOT use this —
it reads `exchangeRate()` directly." So the overflow is a self-contained advisory-view liveness defect:
no NAV move, no stuck issuance/exit, no fund path. Reachability also requires a rate (~1e65) that DON f+1
consensus would never produce. It earns a ticket anyway because (a) it falsifies a documented invariant,
(b) the test meant to prove that invariant doesn't reach the failing region, and (c) any future consumer
of the view would inherit a view that can brick — all for a one-line fix.

## Fix

1. Make the view total — replace the raw multiply at `:140` with OpenZeppelin `Math.mulDiv` for
   `(rNow - a.rate) * BPS * SECONDS_PER_YEAR / (a.rate * dt)` (full-precision 512-bit intermediate, no
   256-bit overflow), keeping the existing `if (annual > aprCap)` clamp. This keeps the view total
   **without rejecting any push** — preferred over adding an upper bound at `_processReport:84`, which
   would tension the deliberate "no deviation band" design.
   - (`mulDiv` reverts only on a zero denominator; `dt == 0` and the degenerate anchor are already guarded
     at `:132/:134-135`, and `a.rate != 0` holds because anchors only ever take `rate != 0` pushes — so
     the denominator is provably non-zero on the path that reaches `:140`.)
2. Make the invariant honest — widen the fuzzed rate domain in `testFuzz_aprBoundedAndNonNegative:191`
   and the handler `push:218` toward `type(uint256).max` (or add a dedicated case pushing an extreme
   rate), so `invariant_aprBoundedNeverReverts` actually exercises the overflow ceiling. After the
   `mulDiv` fix it should stay green across the full domain.

## Out-of-scope note (from mission 1, record only)
`SzipNavOracleDemoVAMM.sol:418-424` (`_xAlphaUSD`) reads `exchangeRate()` without the production
`RateUnseeded` zero-guard that `SzipNavOracle.sol:574-575` has. It is a DEMO/SHOWCASE fork, **not**
deployed by `DeploySzAlphaBridge.s.sol` (confirmed), so it is out of audited scope — but if that fork is
ever promoted toward mainnet pricing, mirror the production guard so it can't value the xALPHA leg at $0.
Not part of this ticket's required work; recorded so the divergence is tracked.

## Next step — documentation propagation (after the code + tests land)
Code-truth; update only once merged. Grep-verified targets (re-grep before each edit; `docs/` house style):
- `contracts/src/bridge/x-ray/SzAlphaRateOracle.md` — §3 invariant **I-4** (and §4 "APR annualization
  precision/overflow"): the overflow residual is now closed (`mulDiv` makes the view total) and the
  invariant is no longer vacuous (domain widened). Update the verdict's "held below HARDENED by no formal
  verification" line only if relevant.
- `contracts/src/bridge/x-ray/invariants.md` — if it carries the rate-oracle I-4 / never-reverts block,
  note the fix + the honest test domain.
- No `docs/` wire edits needed — `intrinsicAprBps` is advisory and not surfaced in the bridge wire docs
  (grep-confirm before concluding); `docs/wires/8x-02-SzAlphaRateOracle.md` only if it claims the view is
  total.

## Acceptance criteria
- `intrinsicAprBps()` cannot revert for any `rate ∈ [1, type(uint256).max]` (via `Math.mulDiv` or
  equivalent), clamp behavior unchanged.
- `testFuzz_aprBoundedAndNonNegative` + the invariant handler fuzz the rate across (near) the full uint256
  domain; `invariant_aprBoundedNeverReverts` green and now actually reaches the former overflow region.
- A regression test pushes `type(uint256).max` against a small anchor and asserts `intrinsicAprBps()`
  returns `aprCap` (not revert).
- X-Ray (`SzAlphaRateOracle.md`, `invariants.md`) updated per propagation step; I-4 no longer rests on a
  vacuous invariant.
