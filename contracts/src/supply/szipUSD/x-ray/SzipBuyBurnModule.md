# X-Ray — `SzipBuyBurnModule.sol` (single-contract, test-connected)

> SzipBuyBurnModule | 244 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol`, the **#1 drill** — the §7
"haircut buy-and-burn" BID side (8-B14): the protocol's **only exit valve** and the hinge of any global wind-down.
The largest fleet module (244 nSLOC, #1 churn at 12) and the value-out path. Connected to
`test/SzipBuyBurnModule.t.sol`: **52 functions, all passing** (~41 module + 8 CTR-01 receiver + 1 fork; the CTR-01
block covers the inherited `CloneReportReceiver`, drilled separately). After DurationFreezeModule, the richest-tested
contract in the subsystem; 0 fuzz/invariant but a deep deterministic + SEC-regression + KAT + fork suite. **Every
mutator is exercised** (all 7 setters + governed params + post/cancel).

> Why it's the flagship: it makes the protocol the discounted **buyer of last resort** for szipUSD via a single
> resting CoW `BUY` order, signed on-chain by PRESIGN. A global RQ exit is just this same bid, sized larger and
> re-armed — there is no other exit primitive. So its validations (price bound, caps, coverage gate, NAV-freshness
> fence) are the protocol's exit-safety surface.

## 1. What it is

A CRE-operator-gated Zodiac `Module` (also a `CloneReportReceiver`) enabled on the engine Safe. On the operator's
tick it posts a **single resting CoW `BUY szipUSD` limit order** (`sellToken=USDC`, `receiver=juniorTrancheEngine`,
partiallyFillable), priced **at or below `navExit × (1 − d)`** off `SzipNavOracle`, `sellAmount ≤ buybackCap`, signed
via `GPv2Settlement.setPreSignature`. Everything bought lands in the Safe; the BURN is `ExitGate.burnFor` (out of
scope). Two doors reach the same `_postBid`/`_cancelBid` internals: the operator path and the CRE report path
(`POST_BID`/`CANCEL_BID`, forwarder-gated via the inherited receiver).

**The §4 hardening:** only 3 order fields are operator-supplied (`sellAmount`, `buyAmount`, `validTo`); every other
GPv2 field is a module-fixed constant (`KIND_BUY`, `APP_DATA=0` (no hooks), `feeAmount=0`, pinned balances), and the
module hashes *exactly* the struct it validates into the uid. No unvalidated field enters the signed order.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `postBid(order)` / CRE `POST_BID` | operator / forwarder | the full §7.2 validation → atomic approve + `setPreSignature` |
| `cancelBid()` / CRE `CANCEL_BID` | operator **or** owner / forwarder | idempotent retract (presign false + allowance 0) |
| `setDiscountBps` / `setBuybackCap` | `onlyOwner` (Timelock) | governed: discount ∈ (0,10000); `buybackCap==0` = kill-switch |
| `setCoverageGate` | `onlyOwner` | the path-lock outflow gate (zero = OFF) |
| `setOperator` + 6 wiring `setX` | `onlyOwner` | build-phase wiring |
| `_orderUid` / `currentBid` / `quoteMaxPrice` | view | on-chain GPv2 uid build; monitoring |

No custody. The only state is the single live bid (`currentUid`/`currentSellAmount`) + wiring/governed params.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **single resting bid** — a second `postBid` while one is live reverts `BidAlreadyLive`; cancel/partial-fill re-arms | Yes | **`test_single_resting_bid`**, `test_partial_fill_then_repost` |
| I-2 | **exact discount price bound** — paid ≤ `buyAmount × navExit × (1−d)`, integer-exact (never rounds up into an above-NAV fill); priced off `navExit` not twap | Yes | **`test_price_bound_boundary_divisible`**/`_non_divisible`, `test_bid_at_or_above_nav_reverts`, `test_deep_discount_passes`, `test_prices_off_navExit_not_twap` |
| I-3 | **NAV-freshness leg-anchored fence (SEC-13)** — `validTo ≤ oldestRequiredLegTs + maxAge`, so a fill lands against a mark at most `maxAge` old (not `2·maxAge`); fails closed at the edges | Yes | **`test_SEC13_two_maxAge_window_closed`**, `_fill_age_capped_at_maxAge`, `_edge_legs_at_freshness_limit_fail_closed`, `_fresh_legs_near_term_validTo_posts`, `test_freshness_fence_binds_before_BadValidTo`, `validTo_at_maxAge_boundary`/`_one_past` |
| I-4 | **caps + kill-switch** — `sellAmount > buybackCap` reverts; `buybackCap==0` reverts every post; `buyAmount > MAX_BUY_AMOUNT` reverts | Yes | `test_cap_exceeded_reverts`, **`test_killswitch_zero_cap_always_reverts`**, `test_buyAmount_too_large_reverts` |
| I-5 | **coverage path-lock outflow gate** — `postBid` blocked while `!covered()`; gate-off (0) = ungated | Yes | **`test_postBid_coverage_gate`** (gate false → `Undercovered`, true → posts, off → ungated) |
| I-6 | **freshness gate** — stale / never-pushed NAV reverts (`StaleNav`) | Yes | `test_freshness_gate_stale_reverts`, `test_freshness_never_pushed_reverts` |
| I-7 | **canonical GPv2 uid** — the on-chain order hash matches the CoW encoding exactly | Yes | **`test_orderUid_known_answer_vector`** (56-byte uid == an out-of-band `cast` KAT; owner==engine, validTo tail), `test_typehash_constant` |
| I-8 | **atomic post / idempotent cancel** — approve + presign are one tx (a presign revert rolls back the approve); cancel no-ops when no live bid | Yes | **`test_atomicity_second_exec_revert_rolls_back`**, `test_exec_discipline_postBid_calls`/`_cancelBid_calls` |
| I-9 | **two doors, one guard set** — the CRE `POST_BID` path enforces the identical `_postBid` validations as the operator path | Yes | `test_CTR01_report_postBid_equals_operator_postBid` (byte-identical uid/sellAmount), the CTR-01 block (see [CloneReportReceiver.md](CloneReportReceiver.md)) |
| X-1 | §10.1 residual: operator sizes the 3 order fields — bounded, not theft | **No** | recipient pinned to the Safe + the price/cap/coverage/freshness gates cap it; a compromised Timelock could redirect avatar/target (accepted, same Timelock governs all) |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr / owner==operator / bad discount / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_zero_address`/`_owner_equals_operator`/`_bad_discount`, `_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `postBid` operator-only / `cancelBid` operator-or-owner | `test_postBid_only_operator`, `test_cancelBid_only_operator_or_owner` |
| governed params owner-only + discount bounds | `test_governed_params_only_owner`, `test_setDiscountBps_bounds` |
| `ZeroAmount` / `BadValidTo` / `BidAlreadyLive` / `CapExceeded` / `Undercovered` / `StaleNav` / `BidAboveDiscount` / `BuyAmountTooLarge` / `ValidToBeyondNavFreshness` | the I-1…I-6 tests above |
| `setCoverageGate` (on/off) | `test_postBid_coverage_gate` |
| 6 wiring setters (`setJuniorTrancheEngine`/`setNavOracle`/`setSzipUSD`/`setUsdc`/`setSettlement`/`setVaultRelayer`) | `test_wiring_setters_onlyOwner_effect_and_zeroGuard` — onlyOwner + effect + zero-guard (all 6) |

## 5. Attack surfaces

- **The exit-safety surface is densely tested (I-2/I-3/I-4/I-5/I-6)** — because this bid is the only exit, its
  validations *are* the safety model, and each is covered: the exact integer discount bound (divisible + non-divisible
  boundaries, at/above-NAV reject), the cap + kill-switch, the coverage path-lock, the freshness gate, and the
  standout **SEC-13 leg-anchored NAV-freshness fence** — a 4-test cluster proving a resting bid can't fill against a
  mark older than `maxAge` (closing the worst-case `2·maxAge` window) and that the edge cases fail closed without
  underflow. This is the most careful single-property testing in the subsystem after the freeze floor.
- **On-chain order hashing is KAT-pinned (I-7)** — `_orderUid` builds the canonical GPv2 order from fixed constants
  + the 3 validated fields; `test_orderUid_known_answer_vector` asserts the 56-byte uid equals an out-of-band
  `cast`-computed vector, so the signed order provably matches CoW's encoding (a transcription error in `TYPE_HASH`/
  field order would fail this). `APP_DATA == 0` deliberately forbids any CoW hook (the documented rejection of a
  fill-time coverage re-check).
- **Two doors, one guard set (I-9)** — the CRE `POST_BID` report path routes to the *same* `_postBid`, so the
  forwarder-driven bid enforces the identical validations; `test_CTR01_report_postBid_equals_operator_postBid` proves
  byte-identical output. The receiver half (forwarder gate, workflow id/author, fail-closed clone) is the CTR-01
  block — see [CloneReportReceiver.md](CloneReportReceiver.md).
- **Undercovered-fill window is bounded, not gated at fill (documented)** — `postBid` is coverage-gated, but a *fill*
  after coverage drifts isn't (CoW hooks forbidden by `APP_DATA==0`). The code documents why this is safe: the USDC
  the bid spends is free-side value `coverageValue()` already excludes, and the window is bounded by NAV `maxAge`.
  Worth understanding as an accepted design point, not a gap.
- **The 6 wiring setters — now covered** — `test_wiring_setters_onlyOwner_effect_and_zeroGuard` exercises
  `setJuniorTrancheEngine`/`setNavOracle`/`setSzipUSD`/`setUsdc`/`setSettlement`/`setVaultRelayer` for onlyOwner +
  effect + zero-guard (the assertions call out the pricing/signing/spend re-points). With `setOperator` (SEC-15) and
  the governed params, **every mutator on the value-out module is now exercised**. (`setJuniorTrancheEngine` does NOT
  sync avatar/target here, so there was no sync to assert.)
- **No fuzz/invariant** — the price-bound arithmetic is a candidate for stateless fuzz (sellAmount/buyAmount/navExit/
  dBps), but the boundary tests (divisible + non-divisible + at/above-NAV) pin the exact integer comparison
  explicitly; lower priority than the property-rich deterministic suite already provides.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Module unit | ~41 | setUp/guards/SEC-14/15, all 7 wiring setters, single-bid, price-bound boundaries, caps/killswitch, coverage gate, the SEC-13 freshness-fence cluster (4), freshness gate, exec-discipline + atomicity, the uid KAT + typehash |
| Receiver (CTR-01) | 8 | the inherited `CloneReportReceiver` socket (fail-closed clone, forwarder, workflow id/author, report↔operator equivalence, supportsInterface) — see its own X-Ray |
| Base-fork | 1 | `test_fork_postBid_stores_presignature_and_allowance` (real `GPv2Settlement` — presign stored + VaultRelayer allowance set) |
| Stateless fuzz / invariant | 0 | price-bound is a fuzz candidate, but the integer boundaries are pinned deterministically |

All **52 pass** (`forge test --match-path test/SzipBuyBurnModule.t.sol`). The exit-safety validations, the uid
encoding, atomicity, and the two-doors equivalence are all tested; the presign path is fork-verified against real
CoW. Coverage % uninstrumentable (project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — the protocol's only exit valve, and its exit-safety surface is the
best-covered after the freeze floor: the exact discount price bound, the cap + kill-switch, the coverage path-lock,
the freshness gate, and especially the SEC-13 leg-anchored NAV-freshness fence are all densely tested; the canonical
GPv2 uid is KAT-pinned; post is atomic and the two doors share one guard set; the presign path is fork-verified
against real CoW. **Every mutator is now exercised** (the 6-setter gap was filled 2026-06-20). Capped below HARDENED
by: no fuzz on the price-bound arithmetic (boundaries are pinned deterministically instead), and the §10.1 /
Timelock-redirect residuals (accepted, governance-bounded) — neither a coverage gap.

**Structural facts:**
1. 244 nSLOC; clone (`MastercopyInitLock` + `initializer`) + `CloneReportReceiver`; the only exit valve; no custody.
2. Single resting CoW `BUY szipUSD` bid; only 3 operator order fields, every other GPv2 field a fixed constant (`APP_DATA=0` forbids hooks); on-chain uid build hashes exactly the validated struct.
3. Exit-safety gates: exact discount bound (off `navExit`), `buybackCap` (+ kill-switch), coverage path-lock (`covered()`), freshness + the SEC-13 leg-anchored fence (fill-age ≤ maxAge); atomic post / idempotent cancel; two doors (operator + CRE) one guard set.
4. Tests: ~41 module + 8 CTR-01 receiver + 1 base-fork (0 fuzz/invariant); every mutator exercised; SEC-13 cluster + uid KAT are the standouts.
5. No outstanding coverage gap on the contract surface; residuals are off-chain/accepted (no price-bound fuzz; §10.1 + Timelock-redirect, governance-bounded).
