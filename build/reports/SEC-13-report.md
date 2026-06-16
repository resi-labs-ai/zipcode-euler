# SEC-13 report — `postBid` `validTo` leg-anchored (kill-list L12 / audit finding #12)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-14 (init-lock 9 mastercopies, L18)

## What the window did
Tightened the NAV-freshness fence in `SzipBuyBurnModule.postBid` so a resting CoW buy-burn bid can never fill against a
NAV mark older than `maxAge` (pre-fix worst case `2·maxAge`). Spans two of our own contracts (same track, not external
back-pressure):

1. **`contracts/src/supply/SzipNavOracle.sol`** — added the additive view
   `oldestRequiredLegTs() external view returns (uint48)` = `min(legCache[LEG_ALPHA_USD].ts, legCache[LEG_HYDX_USD].ts)`,
   folding the wired xALPHA rate oracle's `lastUpdate()` into the min when `xAlphaRateOracle != 0 && lastUpdate() != 0`.
   Extended the inline `IXAlphaRateFresh` interface with `lastUpdate()`.
2. **`contracts/src/supply/szipUSD/SzipBuyBurnModule.sol`** — extended the inline `INavOracle` with
   `oldestRequiredLegTs()`; replaced the `:304` post-time fence
   (`validTo > block.timestamp + maxAge()`) with
   `uint256 anchor = oldestRequiredLegTs(); if (order.validTo > anchor + maxAge()) revert ValidToBeyondNavFreshness();`.
   Pure addition (underflow-safe). `MAX_BID_TTL` (`:299`) and `fresh()` (`:305`) untouched.

## Decisions to sanity-check
- **Rate-leg `+ maxAge` window (the one judgement call).** The spec-fidelity critic flagged that the rate oracle's own
  freshness is `maxStaleness` (6h), tighter than NAV `maxAge` (1 day); bounding the rate ts with `+ maxAge` gives it a
  looser bound than its native window. **Kept** the rate in the min (faithful to the authored deliverable + "reflect the
  full `fresh()` set") because: (a) folding any term into a `min` only LOWERS the anchor → the per-pushed-leg `maxAge`
  guarantee is never weakened; (b) it is strictly better than excluding the rate (which would expose it to
  `maxStaleness + restingWindow`); (c) the tight `maxStaleness` is still enforced at post-time by `:305 fresh()`.
  Documented as accepted residual. **If a reviewer prefers exactness**, the alternative is a second ceiling
  `rateTs + rate.maxStaleness()` (needs a `maxStaleness()` getter on the rate oracle + a two-window fence) — more code,
  marginal benefit, beyond L12's literal `min(required leg.ts)` scope.
- **Behavior change is intended and fail-closed.** For an age-stale pushed leg, the leg-anchored fence now reverts
  `ValidToBeyondNavFreshness` BEFORE the `fresh()`/`StaleNav` gate (the fence is strictly tighter). The bid is rejected
  either way. `StaleNav` remains reachable via the rate-stale path (fresh legs, stale wired cross-chain rate). Two
  pre-existing tests asserting `StaleNav` were updated to the new selector with explanatory comments.

## Holes → resolution
- **Rate-ts back-pressure?** → NONE. The reference-verifier confirmed `SzAlphaRateOracle.lastUpdate() returns (uint48)`
  already exists (`:116`); extending the inline `IXAlphaRateFresh` resolves it. No contract surface owed.
- **Unset/unseeded leg edge** → `oldestRequiredLegTs()` returns 0 for an unpushed required leg, and the rate is folded
  only when its `lastUpdate() != 0`. Anchor 0 ⇒ the fence fails the bid closed (`anchor + maxAge < now < validTo`). The
  never-pushed test was repointed to expect `ValidToBeyondNavFreshness` accordingly.
- **Existing fixtures don't model leg timestamps** (junior-dev critic's most-blocking item) → `MockNavOracle` gained
  `oldestRequiredLegTs()` defaulting to `block.timestamp` (so existing fence tests behave identically) + `setOldestTs`;
  `MockRateOracle` gained `lastUpdate()`/`setLastUpdate`; new `_realOracleMaxAge(maxAge)` + `_moduleFor(oracle)` helpers
  (the existing `_newRealOracle` hard-codes `maxAge == 1 day == MAX_BID_TTL`, which can't bind the anchor before
  `BadValidTo`).

## Gate
`cd contracts && forge build` clean; `forge test` **812 passed / 0 failed / 3 skipped** (+6 over SEC-12's 806; the 3
skips are the pre-existing `DeployZipcode.t.sol` scaffold).

```
Ran 52 test suites in 29.90s (88.38s CPU time): 812 tests passed, 0 failed, 3 skipped (815 total tests)
```

New tests (6): `test/SzipNavOracle.t.sol` — `test_SEC13_oldestRequiredLegTs_min_of_two_legs`,
`test_SEC13_oldestRequiredLegTs_folds_rate_ts_when_wired`; `test/SzipBuyBurnModule.t.sol` —
`test_SEC13_two_maxAge_window_closed`, `test_SEC13_fill_age_capped_at_maxAge`,
`test_SEC13_edge_legs_at_freshness_limit_fail_closed`, `test_SEC13_fresh_legs_near_term_validTo_posts`.
**Fail-before/pass-after confirmed** — restoring the post-time anchor makes the 3 fence regressions FAIL.

## Doc edits
- Ticket `build/tickets/sec/SEC-13-postbid-validto-leg-anchor.md` → DONE + done-note.
- `build/tickets/PROGRESS.md` → SEC-13 DONE, SEC-14 NEXT, "Just done — SEC-13" note (no obligation/seam created; no
  deletion trigger fires).
- `build/kill-list.md` L12 `[ ]` → `[x]` + DONE note.
- `build/audit-claude/findings.md` finding #12 RESOLVED (summary table ✅ + `fix:` line, noting addition-not-subtraction);
  `build/audit-claude/SUMMARY.md` kill-list line ✅(SEC-13).
- Wire docs `build/wires/8-B4-SzipNavOracle.md` (consumer surface + `IXAlphaRateFresh` `lastUpdate()`) and
  `build/wires/8-B14-SzipBuyBurnModule.md` (`INavOracle` surface, guard list #5/#6, fence gotcha) updated.
- **No `claude-zipcode.md` spec change** — interface-level fence-tightening; §7 intent (buyer-conservative `navExit`,
  `fresh()` issuance gate, exit asymmetry) is unchanged.

## Status + NEXT
SEC-13 DONE. **NEXT = SEC-14** (init-lock the 9 Zodiac-module mastercopies via the zodiac-core `TestModule` ctor idiom,
kill-list L18; ticket `build/tickets/sec/SEC-14-mastercopy-init-lock.md`).
