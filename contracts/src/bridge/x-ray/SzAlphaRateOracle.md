# X-Ray — `SzAlphaRateOracle.sol` (single-contract, test-connected)

> SzAlphaRateOracle | 73 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(gap-filled — was FRAGILE)*

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlphaRateOracle.sol`. Connected to
`test/bridge/SzAlphaRateOracle.t.sol`. This is the real-logic bridge contract (vs the thin pool/mirror
wrappers), so it gets the full treatment.

> **Update 2026-08-04 (ring-miss fix on the TWAP fallback):**
> - Since `01efa48` the contract carries a `min(spot, twap)` smoothing leg: `exchangeRate()` serves the lower of
>   the last push and a `twapWindow` average built from a `CARDINALITY` (32) observation ring, closed intervals
>   only, no spot fallback. `rawExchangeRate()` stays unsmoothed for the monitor.
> - **Fixed:** on a ring miss (more than 32 pushes inside `twapWindow`, i.e. cadence faster than ~46 min at the
>   24h window), `twapRate()` fell through to `cumRate / (now - genesisTs)` — a since-genesis lifetime average
>   diverging from the window without bound. It now averages from the oldest surviving ring observation, so the
>   window degrades to the ring's span instead. The genesis path remains only for the young, not-yet-full ring.
>   Regression: `test_ring_miss_averages_over_ring_span_not_since_genesis` (pre-fix value 1.075e18 vs true 2e18).
> - This also retires the first-cycle depth question (31 vs 32 usable slots): the miss path no longer changes
>   regime, it only shortens the span by one slot's interval.
> - Cadence ↔ `twapWindow`/`CARDINALITY` coupling documented in `cre/szalpha-rate/README.md` next to the
>   staleness coupling.
> - **Fixed (warm-up gate):** the seed push was the one value `min(spot, twap)` could not attenuate, and the
>   deploy wires this oracle into `SzipNavOracle` before any push exists — so a mis-scaled first push (the exact
>   producer-bug class the smoothing prices) would have marked NAV at full magnitude for one cadence period,
>   with `navExit` ungated on freshness. `exchangeRate()` now serves 0 until the seed's interval is closed
>   (`latest.ts != genesisTs`), routing the unwarmed state into the consumers' `RateUnseeded` fail-closed path;
>   `rawExchangeRate()` still serves the seed for alarm 5. Cost: NAV closed ~one cadence period after wiring or
>   any re-point onto a fresh oracle. Regression: `test_seed_push_serves_zero_to_consumers_until_interval_closes`
>   (pre-fix served the raw 5e18 seed). The `BuyBurnRateInflation` fixture now warms with a second push, which is
>   the production shape. Suite **29/29 green**; buy-burn inflation harness 5/5; NAV oracle 87/87.
>
> **Update 2026-07-31 (two items, no code change to guards):**
> - **`ts` semantics pinned (Octane remote-timestamp finding, commit `7551f5b`, NatSpec-only):** the pushed `ts`
>   is the **DON push time** (`cre/szalpha-rate` stamps `runtime.Now()`, the sharefeeds pattern) — NEVER the 964
>   block time, whose clock skew vs Base would make the `FutureTimestamp`/staleness gates judge the wrong clock
>   (the finding's DoS: a 964 clock ahead of Base bricks every push). Under DON stamping, `FutureTimestamp` is a
>   pure producer-bug tripwire: a ms-vs-s stamp fails LOUDLY on the first push instead of poisoning the
>   strictly-newer cursor forever (no admin reset exists — an accepted far-future ts would wedge every later
>   push AND read permanently fresh). This is a PRODUCER contract on the CRE job, enforced by convention +
>   NatSpec, not by this contract.
> - **Upstream producer behavior changed (Phase 0, `SzAlpha.exchangeRate()`):** the 964 rate now REVERTS on
>   vanished backing (`BackingVanished`) instead of returning ~0. Effect here: a drift incident becomes a
>   STALE feed (no push lands), and `fresh()` fails consumers closed — the no-deviation-band design gains its
>   missing catastrophic-value backstop without any change to this contract. The CRE job spec MUST treat a
>   reverting read as no-push, never "push 0" (`SN46-BRIDGE-MVP-V2.md` §B5) — the `ZeroRate` guard here is the
>   last-line tripwire if it ever did.
> - Suite count corrected: **23/23 green** per forge (21 in the unit suite incl. the fuzz + 2 invariants); the
>   prior "22/22" undercounted by one.

## 1. What it is

The **Base-side** xALPHA exchange-rate oracle — the on-Base home for a fact native to Subtensor 964. A CRE
workflow *pulls* `exchangeRate()` from 964 and *pushes* it here (the §8 push-cache pattern); this contract is
then the Base `IXAlphaRate` consumed by `SzipNavOracle`'s xALPHA NAV leg. **Design principle:** CRE transports
the *primitive* (the raw rate); the chain derives the rest (`intrinsicAprBps` is a pure on-chain derivation over
the pushed history). Push guards are deliberately minimal — non-zero, not-future, strictly-newer — and there is
**no deviation band** by design (a validator slash legitimately lowers the rate). Freshness is exposed
(`fresh()`/`lastUpdate()`) for consumers to fail-closed on; the oracle never silently serves stale.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `_processReport(report)` (via `ReceiverTemplate.onReport`) | Forwarder-gated (CRE) | the ONLY state-changer: decode `(rate, ts)`, guard, roll anchors, set `latest` |
| `exchangeRate()` | view | `latest.rate`; returns **0 if never pushed** (does not revert — the `fresh()` gate is mandatory) |
| `lastUpdate()` | view | `latest.ts` (0 ⇒ never pushed) |
| `fresh()` | view | `latest.ts != 0 && now - latest.ts <= maxStaleness` — the consumer fail-closed gate |
| `intrinsicAprBps()` | view | advisory derived APR; floors at 0 on slash/flat, clamps to `aprCap`, never reverts |

Immutables (deploy-time, ctor-guarded): `maxStaleness` (≠0), `window` (≠0), `aprCap` (∈ (0, uint32.max]).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | `latest.ts` strictly monotonic (no replay / out-of-order) | Yes | `test_push_stale_or_replayed_reverts` + **`invariant_latestTsTracksMonotonicAccepted`** (256×128k calls, 0 reverts) |
| I-2 | a published rate is never 0 (`exchangeRate()==0` ⇒ never pushed only) | Yes | `test_push_zeroRate_reverts`, `test_push_lands_and_serves_rate` |
| I-3 | anchor state machine: `curAnchor` seeds once, retires to `prevAnchor` when `ts - curAnchor.ts >= window`; APR derives against `prevAnchor` (else `curAnchor`) | Yes | `test_derives_apr_from_rate_growth`, `test_derives_real_validator_short_window`, `test_apr_zero_before_warm` + **`testFuzz_aprBoundedAndNonNegative`** (roll exercised across the rate/Δ domain) + **`invariant_aprBoundedNeverReverts`** (every reachable roll state) |
| I-4 | derived APR ∈ [0, `aprCap`]; floored at 0 on slash/decline/flat; **view is total (never reverts) for ANY pushed rate** (saturation guards) | Yes | `test_apr_slash_is_zero_not_negative`, `test_apr_cap_clamps`, `test_apr_extremeRate_saturatesToCapNoRevert` + **`testFuzz_aprBoundedAndNonNegative`** + **`invariant_aprBoundedNeverReverts`** (both now full-uint256-domain, no longer vacuous) |
| I-5 | no deviation band — a large *legit* move publishes verbatim (design non-guard) | Yes (by absence) | `test_large_legit_jump_is_published` |
| S3 | consumed by `SzipNavOracle` (issuance gates on `fresh()`); oracle exposes freshness, does not enforce the consumer gate | No (cross-contract) | consumer-side; system-map seam S3 |

Constructor guards all tested: `test_ctor_reverts_zeroForwarder` / `_zeroMaxStaleness` / `_zeroWindow` /
`_capZeroOrOverUint32`. Push gating: `test_push_non_forwarder_reverts`, `test_push_wrong_reportType_reverts`,
`test_push_futureTimestamp_reverts`. Freshness: `test_fresh_flips_false_past_maxStaleness`.

## 4. Attack surfaces

- **No deviation band (I-5) — the defining surface.** `_processReport:84-89` accepts any non-zero, not-future,
  strictly-newer value; a single misreported-but-well-formed push becomes the headline `exchangeRate()` until the
  next push. This is deliberate (a band can't distinguish a real emission spike from a bad read). The mitigations
  live **elsewhere**: DON f+1 consensus (off-chain), the strictly-newer monotonicity (I-1), and the consumer's
  `fresh()` gate (S3). Worth confirming every consumer actually gates on `fresh()` — `SzipNavOracle` does for
  issuance; the exit path intentionally does not (the §7 asymmetry).

- **Anchor-roll correctness (I-3).** The `curAnchor`/`prevAnchor` rotation (`:93-99`) is the only non-trivial
  state logic. It rolls at most once per push and only when a full `window` has elapsed; the APR reads
  `prevAnchor` when present. Worth fuzzing the roll boundary (exactly-`window`, rapid pushes, long gaps) — covered
  by example today, not exhaustively.

- **APR annualization precision/overflow — RESOLVED.** `intrinsicAprBps` multiplies up
  *before* dividing (`(rNow-a.rate)*BPS*SECONDS_PER_YEAR / (a.rate*dt)`) to preserve sub-bps per-tempo
  growth. Pre-fix the multiply-up overflowed (uint256 panic) for `rNow-a.rate > ~2^218` — and the
  `invariant_aprBoundedNeverReverts` that "proved" totality was vacuous (fuzz domain bounded `1e24 ≈ 2^80`,
  ~138 bits below the overflow ceiling). Fixed by two overflow-free saturation guards: a growth large
  enough to overflow the multiply-up returns `aprCap`; a rate large enough to overflow the `a.rate*dt`
  denominator returns `0`. The view is now genuinely total. The fuzz + invariant now run the **full uint256
  rate domain** (no longer vacuous), plus `test_apr_extremeRate_saturatesToCapNoRevert` regresses the
  `type(uint256).max` push.

## 5. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 19 | broad: all ctor guards, all push guards, freshness, the full APR behavior set |
| Stateless fuzz | **1** | `testFuzz_aprBoundedAndNonNegative` — anchor-roll + APR over the rate/Δ domain (256 runs) |
| Stateful invariant | **2** | `invariant_latestTsTracksMonotonicAccepted` + `invariant_aprBoundedNeverReverts` (256×128k calls, 0 reverts) |

**Gap filled.** The three tier-mover additions are now present and green:
1. **`invariant_latestTsTracksMonotonicAccepted`** — `latest.ts` always equals the strictly-increasing
   last-accepted ts (I-1 monotonicity as a stateful property; the handler asserts strict increase on every accept).
2. **`testFuzz_aprBoundedAndNonNegative`** — fuzzes the anchor roll (Δ ≥ window always rolls) + the APR math:
   bounded ≤ cap, floors at 0 on decline/flat.
3. **`invariant_aprBoundedNeverReverts`** — `intrinsicAprBps()` never reverts and stays ≤ cap in every reachable
   state the handler drives (all roll states). Full rate-oracle suite now **22/22 green**.

## X-Ray Verdict

**ADEQUATE** *(gap-filled — was FRAGILE)* — clean, well-documented, single-state-changer push oracle with all
guards unit-tested, and now the two stateful properties (ts-monotonicity, anchor roll) + the arithmetic property
(APR no-overflow/≤cap) are proven under fuzzing/invariants rather than pinned by example. Tests axis is ADEQUATE
(unit + fuzz + invariant). Held below HARDENED only by: no formal verification, and the **no-deviation-band**
design (a well-formed bad push publishes verbatim — closed off-chain by DON consensus + the consumer `fresh()`
gate, seam S3, not in this contract).

**Structural facts:**
1. 73 nSLOC; one Forwarder-gated state-changer (`_processReport`) + 4 views; 3 deploy-time immutables.
2. Tests: 19 unit + 1 fuzz + 2 invariant — full rate-oracle suite 22/22 green (invariant: 256×128k calls, 0 reverts).
3. No deviation band by design — a well-formed bad push publishes verbatim; defenses are DON consensus + `fresh()` + strict monotonicity, all outside this contract or in the consumer (seam S3).
4. The anchor-roll state machine and the APR annualization — the highest-value fuzz/invariant targets — are now covered.
5. Coverage % uninstrumentable (project-wide stack-too-deep); test existence confirmed by scan + run.
