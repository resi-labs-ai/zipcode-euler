# TWAP ring — poke-spam collapse of the NAV bracket

> **FIXED 2026-06-13.** `_accumulate` now decouples the integral from the ring: `cumNav` advances on every
> `poke()` with `dt>0`, but a new slot is consumed only once `obsSpacing` (an immutable, derived
> `ceil(1.25*W/(CARDINALITY-1))` in the ctor) has elapsed — otherwise the head slot refreshes in place. The
> `CARDINALITY-1` frozen checkpoints therefore always span `>= W` regardless of poke frequency; poke-spam can
> refresh the head but can no longer evict the window. Tests: `test_twap_window_survives_poke_spam` (200 spam
> pokes consume ≤3 slots, twap stays near history, `navExit < spot`) + `test_poke_within_spacing_refreshes_head_no_advance`.
> Full suite 749/0/3 green. With this, the `coverage-floor.md` Phase-2 capacity gate may safely lean on the
> `min(spot,twap)` bracket. No supply findings from the review remain open.

## Problem (verified)

`SzipNavOracle` defends issuance/exit against a one-block spot manipulation with a bracket:

```
navEntry() = max(spot, twap)   // SzipNavOracle.sol:368  — minting can only get more expensive
navExit()  = min(spot, twap)   // SzipNavOracle.sol:380  — exiting can only get cheaper
```

The whole defense is the *lag* of `twap` behind `spot` over the window `W` (deployed 4h). That lag lives
in a fixed 65-slot observation ring, and the ring can be collapsed:

```solidity
// SzipNavOracle.sol:260
function _accumulate() internal returns (bool) {
    uint32 nowTs = uint32(block.timestamp);
    uint32 dt = nowTs - lastUpdate;
    if (dt == 0) return false;                 // one write per block-timestamp max
    cumNav += spotNavPerShare() * uint256(dt);
    obsIndex = uint16((uint256(obsIndex) + 1) % CARDINALITY);  // ADVANCES a slot EVERY block
    observations[obsIndex] = Observation(nowTs, cumNav);
    lastUpdate = nowTs;
    return true;
}
```

`poke()` is permissionless (`:255`) and `_accumulate` advances `obsIndex` on **every** call with `dt>0`.
So `CARDINALITY=65` slots buy only 65 distinct block-timestamps of history. On Base (~2s blocks) an
attacker pokes ~65 blocks (~130s) and evicts every observation older than ~130s. The back-walk in
`twapNavPerShare` (`:352`) then finds no `o.ts <= now - W`, falls through to `return spot` (`:362`), and:

```
twap == spot   =>   navEntry == navExit == spot
```

The bracket degenerates to spot. The lag that was supposed to dilute a sub-window manipulation over 4h is
gone — the effective window shrinks to whatever the attacker leaves in the ring.

### Why it's exploitable, not cosmetic

`spotNavPerShare` is in-block manipulable through the **LP leg**. `grossBasketValue` marks the staked/held
ICHI position at `getTotalAmounts() * heldShares / totalSupply`, valuing each reserve at **oracle** leg
prices (`_legPriceOfToken`, `:421`), not pool price:

```solidity
(uint256 total0, uint256 total1) = IICHIVault(ichiVault).getTotalAmounts();   // SzipNavOracle.sol:285
uint256 amt0 = total0 * heldShares / supplyLp;
uint256 amt1 = total1 * heldShares / supplyLp;
value += _tokenValue(token0, amt0) + _tokenValue(token1, amt1);
```

`getTotalAmounts()` reflects the vault's *current* position composition. A large swap against the
zipUSD/xALPHA pool shifts `amt0/amt1`; valued at fixed oracle prices, the marked LP value moves with the
manipulated composition. Attack path: poke-spam to collapse the window → swap to inflate the LP mark →
poke once to bake the inflated spot into the now-short twap → `navExit = min(spot, twap)` tracks the
inflated mark → exit rich (or the symmetric depress-and-mint). This is exactly the brief's "spot vs EMA:
anything fund-moving reading an in-block-manipulable price?" landing on the keystone.

### It also degrades silently, with no attacker

Any keeper poking faster than `W / (CARDINALITY-1)` (4h/64 ≈ every 225s) shortens the effective window.
The 65-deep ring only spans `W` if pokes/pushes stay *sparser* than ~once per 3.75min. A diligent keeper
poking every block is indistinguishable from the attack — the defense quietly thins.

## Root cause

The ring conflates two jobs that should be decoupled:

1. the **integral** `cumNav` (must advance on every `dt>0` for an exact time-weighting), and
2. the **checkpoint ring** (only needs ~`CARDINALITY` points spaced to span `W`).

Today every integral step also consumes a ring slot. Fix: advance the integral always; consume a ring
slot only when enough wall-clock has elapsed since the last committed slot.

## Fix — Phase 1: min-spacing observation commits (self-contained, no new wiring)

Derive a minimum commit spacing from `W` so the `CARDINALITY-1` *frozen* checkpoints always span `W`,
regardless of poke frequency. Refresh the head slot in place between commits so the query still has a
fresh near-`now` point.

### Constant — derive spacing from W in the ctor (W-agnostic)

```solidity
/// @notice Min wall-clock between committed ring checkpoints. Sized so the CARDINALITY-1 frozen
///         checkpoints span >= W even if poke() is called every block: (CARDINALITY-1)*obsSpacing >= W.
uint32 public immutable obsSpacing;

// in the constructor, after W_ is set:
obsSpacing = uint32((uint256(W_) + (CARDINALITY - 2)) / (CARDINALITY - 1));  // ceil(W / (CARDINALITY-1))
```

For `W=14400` (4h), `CARDINALITY=65`: `obsSpacing = ceil(14400/64) = 225s`, fast-poke coverage
`64*225 = 14400 = W`. Bump `CARDINALITY` (e.g. to 97) if you want headroom over the exact bound — see
"Sizing" below.

### `_accumulate` — decouple integral from ring commit

```solidity
function _accumulate() internal returns (bool) {
    uint32 nowTs = uint32(block.timestamp);
    uint32 dt = nowTs - lastUpdate;
    if (dt == 0) return false;
    cumNav += spotNavPerShare() * uint256(dt);   // integral: advances on EVERY dt>0 (unchanged)
    lastUpdate = nowTs;
    // Ring: consume a NEW slot only once obsSpacing has elapsed since the newest committed checkpoint;
    // otherwise refresh the head slot in place. This bounds ring consumption so the CARDINALITY-1 frozen
    // checkpoints span >= W independent of poke() frequency — poke-spam can no longer collapse the window.
    if (nowTs - observations[obsIndex].ts >= obsSpacing) {
        obsIndex = uint16((uint256(obsIndex) + 1) % CARDINALITY);
    }
    observations[obsIndex] = Observation(nowTs, cumNav);
    return true;
}
```

`twapNavPerShare` is **unchanged** — it already walks back for the first `o.ts <= now - W` and divides
`(cumNow - foundCum)/(now - foundTs)`. With spacing enforced, the found checkpoint is at most `obsSpacing`
older than `now-W`, so the effective window is `[W, W+obsSpacing]` — ≤1.6% over `W` at the chosen spacing,
which is the standard checkpoint-TWAP slack and is the conservative direction for the lag.

### Why this closes it

- **Fast pokes** (every block): the head slot just refreshes in place; `obsIndex` advances only every
  `obsSpacing`. 64 frozen checkpoints × ≥225s ≥ `W`. The query always finds a checkpoint ≤ `now-W`. An
  attacker poking 65 blocks now evicts nothing — they only refresh one head slot.
- **Sparse pokes** (gaps > `obsSpacing`): every poke commits, each checkpoint spans its full gap, total
  coverage ≥ 64 gaps ≫ `W`. Strictly better than today.
- **Genesis / cold ring**: same fallback-to-spot as today until `W` of history exists (acceptable; the
  Gate is the first minter and the bracket is moot at zero supply).

The integral `cumNav` is unaffected, so the time-weighting stays exact; only *which* points are retained
as queryable checkpoints changes.

## Sizing the ring (the one number to settle)

`(CARDINALITY - 1) * obsSpacing >= W` must hold for coverage. Deriving `obsSpacing = ceil(W/(C-1))` makes
it hold by construction for any `W`, at the exact bound. For headroom (so the found checkpoint sits
comfortably past `now-W` rather than on the boundary), raise `CARDINALITY`:

| CARDINALITY | obsSpacing (W=4h) | fast-poke coverage | headroom over W |
|---|---|---|---|
| 65 (today)  | 225s | 14400s | 1.00× (exact) |
| 97          | 150s | 14400s | 1.00× (finer points, same span) |
| 129         | 113s | 14464s | ~1.00× (finer still) |

Note finer spacing alone does **not** add span at fixed `CARDINALITY` — span is `(C-1)*obsSpacing` and
`obsSpacing` is derived from `W`. To add *span* headroom, either raise `CARDINALITY` and keep `obsSpacing`
derived from a target > `W` (e.g. `1.5*W`), or set `obsSpacing = ceil(1.5*W/(C-1))` and accept a
`[W, W+1.5W/(C-1)]` window. Recommendation: keep `CARDINALITY=65`, derive `obsSpacing` from `1.25*W`
(`ceil(18000/64)=282s` → span 18048s ≈ 1.25× `W`), giving a query checkpoint always ~`W..1.25W` old.
Cheap, no extra storage, comfortably off the boundary.

## Fix — defense in depth (recommended, separable): make spot itself manipulation-resistant

The Phase-1 fix restores the lag, but a manipulation *sustained* across `W` still moves `twap`. The
deeper hardening is to remove the in-block manipulability of `spot`'s LP leg so there is nothing to
sustain:

- **Source the xALPHA leg from a manipulation-resistant primitive.** The recorded 8x-01 follow-up
  (`build/supply.md`) — source `LEG_ALPHA_USD` from `getMovingAlphaPrice` (18-dp EMA) × TAO/USD rather
  than an off-chain spot push — addresses the *price* leg.
- **Value the LP from fair reserves, not the instantaneous split.** `getTotalAmounts()` returns the
  current (manipulable) composition. Reconstruct the *fair* reserves from the pool's invariant + the
  oracle leg prices (the "fair LP value" / `k`-and-price reconstruction) so a swap that skews `amt0/amt1`
  does not move the mark. This is the leg coverage-floor.md Phase-2 build-note #2 already flags
  ("read off a TWAP/conservative reserve, not spot") — and which the bracket was silently relied on to
  cover. With the ring collapsible, that reliance was unsound; the fair-reserve read makes it sound
  independent of the ring.

Ship Phase-1 (ring spacing) first — it is small, local, and restores the documented invariant. The
fair-LP read is a larger change to `grossBasketValue` and can follow.

## Test deltas

- `SzipNavOracle.t.sol`:
  - `twap_window_survives_poke_spam`: poke `CARDINALITY+N` times across consecutive blocks (warp 1–2s
    each); assert `twapNavPerShare()` still divides over a span ≥ `W` (i.e. the found checkpoint is
    ≤ `now-W`), NOT a fallback-to-spot.
  - `twap_no_collapse_under_manipulated_spot`: collapse-attempt (poke-spam) + a simulated LP-composition
    shift; assert `navExit()` stays bracketed below the manipulated `spot` (the `min` still bites).
  - `obsSpacing_spans_W`: stateful/invariant — over an arbitrary poke schedule, the oldest frozen
    checkpoint is always ≤ `now-W` once `W` of history exists.
  - `accumulator_exactness_preserved`: `cumNav` after N pokes equals the analytic integral (the
    decoupling did not change the time-weighting).
- `forge inspect SzipNavOracle storage-layout` — confirm `obsSpacing` immutable adds no storage slot and
  the ring layout is unchanged (no upgrade-layout break).

## Status

**FIXED 2026-06-13** (Phase-1 min-spacing ring, `SzipNavOracle.sol`). Implemented: `obsSpacing` immutable
`= ceil(1.25*W/(CARDINALITY-1))`; `_accumulate` advances the integral every `dt>0` but consumes a ring slot
only once `obsSpacing` has elapsed (else refreshes the head in place); `twapNavPerShare` unchanged. Tests
`test_twap_window_survives_poke_spam` + `test_poke_within_spacing_refreshes_head_no_advance` added; existing
TWAP/ring tests + full suite (749/0/3) green. This unblocks the `coverage-floor.md` Phase-2 capacity gate,
which leans on the `min(spot,twap)` bracket.

The **defense-in-depth** item above (fair-LP reserve read so `spot` itself is not in-block manipulable) is
now **BUILT 2026-06-14** — see `build/fair-lp.md`. `SzipNavOracle._lpValue` reconstructs the LP reserves at
the pool's Algebra TWAP tick (via `IchiAlgebraFairReserves`) when the new Timelock-settable `lpTwapWindow`
is wired, instead of the in-block-manipulable spot `getTotalAmounts()`. Fork-proven manipulation-invariant
against the live HYDX/USDC vault (a 300k-USDC swap moved the spot split >2% while the fair quote was
byte-identical). Default `lpTwapWindow==0` keeps spot pricing for M1 / non-Algebra pools, so this is
opt-in per LP and changes nothing until set. The single-block ring fix and this sustained-move fix together
close both manipulation classes on the LP leg.
