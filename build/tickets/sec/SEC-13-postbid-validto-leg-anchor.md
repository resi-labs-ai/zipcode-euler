# SEC-13 — `postBid` `validTo` anchored to oldest required leg (L12)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L12; `build/CoW-exit.md`, `build/twap-ring.md`;
audit `findings.md` (L12) · **Status:** DONE 2026-06-15

> Scope authored 2026-06-15. Spans TWO of our contracts (same track, not external back-pressure): a small
> additive view on `SzipNavOracle` + the `postBid` fence in `SzipBuyBurnModule`.

## Deliverable
Bound a resting buy-burn bid's `validTo` to `min(required leg.ts) + maxAge` (the oldest NAV leg's age, not
post-time), so a bid can never fill against a NAV mark older than `maxAge`.

## What it does / what's being fixed (plain language)
`postBid` rests a single CoW buy order priced off `navExit`. To stop it filling against a NAV that has since
gone stale, it caps `validTo` to `block.timestamp + maxAge` (the NAV freshness window). But the legs feeding
`navExit` may already be up to `maxAge` old at post-time (`fresh()` only requires age ≤ `maxAge`). So the
worst-case age of the mark at fill is `maxAge` (already elapsed) + `maxAge` (resting) = **2·maxAge** — double the
intended freshness. Anchoring the ceiling to the **oldest required leg's timestamp** instead of post-time caps
the fill-time mark age at exactly `maxAge`.

## Binds to (verified file:line — 2026-06-15)
- **The post-time-anchored fence:** `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol:304` —
  `if (order.validTo > block.timestamp + INavOracle(navOracle).maxAge()) revert ValidToBeyondNavFreshness();`
  (plus the absolute TTL `:299` and the `fresh()` check `:305`).
- **Module's oracle interface (to extend):** `SzipBuyBurnModule.sol:11-14` — `INavOracle` exposes only
  `navExit()`/`fresh()`/`maxAge()`.
- **Oracle internals (no view today):** `contracts/src/supply/SzipNavOracle.sol` — required legs are
  `LEG_ALPHA_USD` (`:61`) and `LEG_HYDX_USD` (`:63`); `fresh()` checks both via `_legStale` (`:490-501`); leg
  timestamps live in the internal `legCache[leg].ts` (`:498`). `maxAge` is `immutable` (`:82`).
- The xALPHA **rate-oracle** freshness is also part of `fresh()` when wired (`SzipNavOracle.sol:492`) — see the
  rate-leg note in Key requirements.

## Key requirements
1. **New oracle view.** Add `SzipNavOracle.oldestRequiredLegTs() returns (uint48)` returning
   `min(legCache[LEG_ALPHA_USD].ts, legCache[LEG_HYDX_USD].ts)` — the oldest timestamp among the legs `navExit`
   is built from. **Rate-leg refinement:** when `xAlphaRateOracle != address(0)`, also fold the rate oracle's
   last-update timestamp into the min so the anchor reflects the full `fresh()` set; if the rate oracle exposes no
   ts getter, flag it (back-pressure) rather than silently omitting it.
2. **Extend `INavOracle`** in `SzipBuyBurnModule` with `oldestRequiredLegTs()`.
3. **Anchor the fence.** Replace the `:304` post-time anchor with:
   ```solidity
   uint256 anchor = INavOracle(navOracle).oldestRequiredLegTs();
   if (order.validTo > anchor + INavOracle(navOracle).maxAge()) revert ValidToBeyondNavFreshness();
   ```
   Keep the absolute TTL ceiling (`:299`) and the `fresh()` check (`:305`).
4. **Guard the edge (no underflow).** Use addition (`anchor + maxAge`), never subtraction, so the
   `oldest-leg-age == maxAge` / `maxAge == 0` cases can't underflow. When `anchor + maxAge <= block.timestamp`
   (legs at the freshness edge → no forward-resting window), the bid correctly cannot be posted — ensure that
   path reverts cleanly (the existing `validTo > block.timestamp` `:299` + this fence already reject it;
   confirm a legible revert, not a panic). (`maxAge == 0` is unreachable — immutable, ctor-rejected, L5 — but
   the addition form is safe regardless.)

## Do NOT
- Do NOT keep the post-time anchor — the new anchor is strictly tighter and supersedes `:304`.
- Do NOT relax `fresh()` (`:305`) or the absolute `MAX_BID_TTL` (`:299`) — they are independent ceilings.
- Do NOT compute a remaining-TTL via subtraction (underflow risk) — bound with `anchor + maxAge`.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC13_*` regression test** that fails before / passes after:
  - **2·maxAge closed:** push the required legs at `t0`; warp by `a` with `0 < a < maxAge` (still `fresh()`);
    `postBid` with `validTo = block.timestamp + maxAge` → pre-fix passes, post-fix reverts
    `ValidToBeyondNavFreshness` (the max postable `validTo` is now `t0 + maxAge`, i.e. only `maxAge - a` ahead).
  - **Fill-age bound:** the maximum-allowed resting bid implies a fill-time leg age of `maxAge`, not `2·maxAge`.
  - **Edge fail-closed:** with legs aged exactly `maxAge` (`anchor + maxAge == block.timestamp`), no bid is
    postable and the call reverts cleanly (no underflow/panic).
  - **Fresh legs still postable:** with `a` small, a near-term `validTo` posts successfully.
  - **View:** `oldestRequiredLegTs()` returns the min of the two leg timestamps (and the rate ts when wired).
- Quote the actual `forge test` output in this ticket's done note. (Extend the buy-burn + NAV-oracle fixtures.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-13" with the finding note (+ any rate-ts back-pressure if surfaced).

---

## DONE — 2026-06-15

**`postBid`'s `validTo` fence is now LEG-ANCHORED** (kill-list L12; audit finding #12). Two of our own contracts changed
(same track, not external back-pressure): an additive view on `SzipNavOracle` + the fence in `SzipBuyBurnModule`.

- **Fix (2 src files):**
  - `SzipNavOracle.sol` — declared `oldestRequiredLegTs() external view returns (uint48)` returning
    `min(legCache[LEG_ALPHA_USD].ts, legCache[LEG_HYDX_USD].ts)`, and **folding the wired xALPHA rate oracle's
    `lastUpdate()` into the min** when `xAlphaRateOracle != 0` AND `lastUpdate() != 0` (the `!= 0` guard routes an
    unseeded-but-wired rate to the cleaner `fresh()`/`StaleNav` gate instead of clamping the anchor to 0). Extended the
    inline `IXAlphaRateFresh` interface with `lastUpdate()` (the real `SzAlphaRateOracle.lastUpdate()` already exposes
    it at `:116` — **no back-pressure**).
  - `SzipBuyBurnModule.sol` — extended the inline `INavOracle` with `oldestRequiredLegTs()`; replaced the `:304`
    post-time fence with `uint256 anchor = INavOracle(navOracle).oldestRequiredLegTs(); if (order.validTo > anchor +
    INavOracle(navOracle).maxAge()) revert ValidToBeyondNavFreshness();`. Pure addition (no underflow). The absolute
    `MAX_BID_TTL` (`:299`) and the `fresh()` check (`:305`) are untouched (independent ceilings, Do-NOTs honored).

- **Decision sanity-check (rate-leg window, flagged by the spec-fidelity critic):** the rate oracle's native freshness
  is its own `maxStaleness` (6h), tighter than `maxAge` (1 day). Folding the rate ts with `+ maxAge` bounds the rate's
  fill-time age to `maxAge`, NOT its tighter native window. Kept (faithful to the ticket's "reflect the full `fresh()`
  set" + the authored deliverable) because: (a) including the rate only ever LOWERS the anchor, so the per-pushed-leg
  `maxAge` guarantee is never weakened; (b) it is strictly better than excluding the rate (which would expose it to
  `maxStaleness + restingWindow`); (c) the tighter `maxStaleness` is still enforced at post-time by `:305 fresh()`.
  Documented as accepted residual in the view's NatDoc + both wire docs.

- **Intended behavior change (fail-closed, folded back into the test suite):** for an **age-stale pushed leg**, the
  leg-anchored fence now reverts `ValidToBeyondNavFreshness` BEFORE the `:305 fresh()`/`StaleNav` gate (the fence is
  strictly tighter — `anchor + maxAge < now < validTo`). Two pre-existing tests that asserted `StaleNav` for the
  stale-by-age / never-pushed cases were updated to expect `ValidToBeyondNavFreshness` (the bid is rejected fail-closed
  either way; only the selector changed). `StaleNav` remains reachable via the **rate-stale** path (fresh pushed legs,
  stale wired rate) — the leg-only anchor does not pre-empt it.

- **Gate green:** `cd contracts && forge build` clean; `forge test` **812 passed / 0 failed / 3 skipped** (+6 over
  SEC-12's 806 = the 6 new SEC13 tests; the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold). New tests:
  - `test/SzipNavOracle.t.sol` (2): `test_SEC13_oldestRequiredLegTs_min_of_two_legs` (push legs at different times →
    returns the older), `test_SEC13_oldestRequiredLegTs_folds_rate_ts_when_wired` (unseeded rate excluded; older rate
    folds in; newer rate does not raise the anchor).
  - `test/SzipBuyBurnModule.t.sol` (4, real oracle w/ `maxAge = 1 hours < MAX_BID_TTL`):
    `test_SEC13_two_maxAge_window_closed` (legs@t0, warp 30m, the OLD post-time ceiling now reverts; the new ceiling
    `t0+maxAge` posts), `test_SEC13_fill_age_capped_at_maxAge` (exact ceiling posts, `+1` reverts),
    `test_SEC13_edge_legs_at_freshness_limit_fail_closed` (legs aged exactly `maxAge`, `anchor+maxAge == now`, any
    `validTo > now` reverts cleanly — no panic), `test_SEC13_fresh_legs_near_term_validTo_posts` (small age, near-term
    validTo posts).
  - **Fail-before/pass-after confirmed:** restoring the post-time anchor (`block.timestamp + maxAge`) makes all 3
    fence regressions FAIL (`next call did not revert as expected`); restored → all 6 pass.

  ```
  Ran 52 test suites in 29.90s (88.38s CPU time): 812 tests passed, 0 failed, 3 skipped (815 total tests)
  ```

- **Fixtures:** `MockNavOracle` (buy-burn suite) gained `oldestRequiredLegTs()` (settable; default returns
  `block.timestamp` so existing fence tests behave identically) + `setOldestTs`; `MockRateOracle` (NAV suite) gained
  `lastUpdate()`/`setLastUpdate`; new `_realOracleMaxAge(maxAge)` + `_moduleFor(oracle)` helpers (the existing
  `_newRealOracle` hard-codes `maxAge == 1 day == MAX_BID_TTL`, which can't exercise the leg anchor binding before
  `BadValidTo`).

- **No spec change** (interface-level fence-tightening; §7 buy-and-burn intent unchanged — `navExit`/`fresh()` semantics
  and the §7 exit asymmetry are untouched). **No back-pressure / no new obligation** (the rate oracle already exposes
  `lastUpdate()`). Doc-sync: kill-list L12 `[x]`; audit finding #12 RESOLVED (summary table + `fix:` line, noting the
  addition-not-subtraction form); wire docs `8-B4-SzipNavOracle.md` + `8-B14-SzipBuyBurnModule.md` updated (consumer
  surface, guard list, fence gotcha). Report: `build/reports/SEC-13-report.md`.
