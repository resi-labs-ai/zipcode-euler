# SEC-13 — `postBid` `validTo` anchored to oldest required leg (L12)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L12; `build/CoW-exit.md`, `build/twap-ring.md`;
audit `findings.md` (L12) · **Status:** PROPOSED

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
