// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";

/// @title SzAlphaRateOracle
/// @notice The **Base** xALPHA exchange-rate oracle: the on-Base home for the one fact that lives only on Bittensor.
///         xALPHA's `exchangeRate()` (`staked alpha / supply`) is native to **Subtensor EVM (964)** — the bridged
///         Base mirror (`SzAlphaMirror`) is a plain `BurnMintERC20` with no stake surface — so a CRE workflow
///         **pulls** the rate from 964 (RPC/precompile read) and **pushes** it here on the §8 push-cache pattern.
///         This contract is then the Base-side `IXAlphaRate`: a drop-in `exchangeRate()` for `SzipNavOracle`'s
///         xALPHA NAV leg and any Euler price-oracle adapter. `claude-zipcode.md` §8.6/§8.8.
/// @dev The principle: **CRE transports the PRIMITIVE (the rate), the chain DERIVES the rest.** Only the raw rate
///      crosses the chain boundary — never a pre-computed APR/NAV. The intrinsic APR is a pure on-chain derivation
///      over the pushed rate's history (`intrinsicAprBps`), exposed here as a convenience view; NAV consumes
///      `exchangeRate()` directly. Push guards are minimal and truthful — non-zero, not-future, strictly newer
///      (no replay/out-of-order). There is deliberately **no deviation band**: the rate is ground truth from 964
///      (a validator slash legitimately lowers it), so a band would either brick a real move or need a bypass.
///      Consumers enforce **staleness** via `fresh()`/`lastUpdate()` (a rate feeding NAV can move funds, so the
///      reader must fail-closed on a stale push — this oracle exposes freshness, it does not silently serve old).
/// @dev SMOOTHING (2026-08-02) — `exchangeRate()` serves `min(spot, twap)` over `twapWindow`, NOT the raw push.
///      This is NOT the deviation band the paragraph above rejects. A band is symmetric and REJECTS; this is
///      one-directional and ATTENUATES. Downward moves land in full on the first push, because `min` takes the lower
///      number — so a slash still arrives instantly, which is the exact case that killed the band idea. Only upward
///      moves are delayed, and an upward move cannot be legitimate-and-sudden: the rate is `stake / supply`, stake
///      grows only by emission at sub-bps per tempo, and deposits and redeems move stake and supply together.
///      THE FAILURE BEING PRICED IS A WRONG VALUE FROM OUR OWN SIDE, not an attacker's. Note what it is NOT: the
///      push job does no scaling whatsoever — `cre/szalpha-rate` reads `exchangeRate()`, unpacks the uint256 and
///      pushes it unchanged — and the 9-dp→18-dp conversion is `_stake18() = getStake × 1e9` in `SzAlpha` on 964,
///      which the mainnet drill measured exactly against the published subnet price. So there is no decimals slip
///      in this path today. What remains is that a cross-chain value read over RPC lands here and is multiplied
///      straight into a payout gate with no bound of any kind: a bug in the source accounting, a read against the
///      wrong contract or chain, or a future refactor of either side all arrive the same way.
///      THE WINDOW DOES NOT BOUND THAT NUMBER — it makes it take a window to arrive, which is only worth anything
///      if something watches during it. `cre/szalpha-watch` alarm 5 is that watcher: it compares this contract's
///      `rawExchangeRate()` against `SzAlpha.exchangeRate()` on 964, which must be EQUAL precisely because the job
///      transports the number unchanged. That is an equality check rather than a threshold, and the distinction is
///      the point — a real slash is large and legitimate, so no "is this move too big" alarm can separate one from
///      a scaling error, while equality can. Alarm 5 must read `rawExchangeRate()`, never `exchangeRate()`: the
///      smoothed view is built to withhold exactly the signal a monitor needs.
///      This works here and provably did NOT work in `SzipNavOracle` for one structural reason: that contract has a
///      permissionless `poke()`, so whoever benefits can advance the accumulator themselves. This one has exactly
///      one state-mutating path, `_processReport`, and it is forwarder-gated.
contract SzAlphaRateOracle is ReceiverTemplate, IXAlphaRate {
    // --------------------------------------------------------------------- constants
    /// @notice The reportType this oracle services (the xALPHA rate push). `(receiver, reportType)`-scoped (§8.0):
    ///         `8` here never collides with `DefaultCoordinator`'s `8` — each push names one receiver.
    uint8 public constant RATE = 8;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant BPS = 10_000;

    // --------------------------------------------------------------------- governed knobs (immutable, deploy-time)
    /// @notice The consumer-facing freshness bound (seconds): `fresh()` is false once the latest push ages past it.
    uint256 public immutable maxStaleness;
    /// @notice The trailing window (seconds) the derived APR looks back over.
    uint32 public immutable window;
    /// @notice The derived-APR display sanity clamp (bps; the APR view is `uint32`).
    uint256 public immutable aprCap;
    /// @notice The smoothing window (seconds) `exchangeRate()` averages the pushed rate over. Sized against the push
    ///         cadence: at the hourly `defaultSchedule`, 24h is 24 samples, so one push is 1/24 of the average.
    uint32 public immutable twapWindow;

    /// @notice Observation ring capacity. 32 slots covers a 24h window at hourly pushes with headroom; a faster
    ///         cadence just means the ring holds less than `twapWindow` and the average runs over what it holds.
    uint16 public constant CARDINALITY = 32;

    // --------------------------------------------------------------------- state
    struct Sample {
        uint256 rate; // exchangeRate() (alpha per xALPHA, 18-dp)
        uint48 ts; // the DON push time the workflow stamped (`runtime.Now()` — NEVER the 964 block time; 0 ⇒ unset)
    }

    /// @notice The latest pushed rate — the headline `exchangeRate()` (updates every push).
    Sample public latest;
    /// @notice The trailing checkpoint the APR derives against (rolls every `window`).
    Sample public prevAnchor;
    /// @notice The maturing checkpoint, retired to `prevAnchor` once `window` old.
    Sample public curAnchor;

    /// @notice A point on the rate-seconds accumulator, written once per accepted push.
    struct Observation {
        uint48 ts; // the DON push time this point was written at (0 ⇒ slot never written)
        uint256 cum; // Σ rate × elapsed, from genesis to `ts`
    }

    /// @notice The rate-seconds accumulator at `latest.ts`. Advanced ONLY by `_processReport`.
    uint256 public cumRate;
    /// @notice Ring of accumulator points; `obsIndex` is the newest.
    Observation[CARDINALITY] public observations;
    /// @notice Index of the newest written observation.
    uint16 public obsIndex;
    /// @notice The DON push time of the FIRST accepted push. Before this there is nothing to average.
    uint48 public genesisTs;

    // --------------------------------------------------------------------- errors / events
    error InvalidReportType(uint8 reportType);
    error ZeroRate();
    error FutureTimestamp();
    error StaleReport(); // a push not strictly newer than the cached one (replay / out-of-order)
    error ZeroWindow();
    error ZeroTwapWindow();
    error InvalidAprCap();
    error ZeroMaxStaleness();

    event RatePushed(uint256 rate, uint48 ts, bool rolled);

    /// @param forwarder The Chainlink Forwarder (the CRE write path; reverts on zero in `ReceiverTemplate`).
    /// @param maxStaleness_ The consumer freshness bound (seconds, `!= 0`).
    /// @param window_ The derived-APR trailing window (seconds, `!= 0`).
    /// @param aprCap_ The derived-APR display clamp (bps, `!= 0` and `<= type(uint32).max`).
    /// @param twapWindow_ The `exchangeRate()` smoothing window (seconds, `!= 0`).
    constructor(address forwarder, uint256 maxStaleness_, uint32 window_, uint256 aprCap_, uint32 twapWindow_)
        ReceiverTemplate(forwarder)
    {
        if (maxStaleness_ == 0) revert ZeroMaxStaleness();
        if (window_ == 0) revert ZeroWindow();
        if (aprCap_ == 0 || aprCap_ > type(uint32).max) revert InvalidAprCap();
        if (twapWindow_ == 0) revert ZeroTwapWindow();
        maxStaleness = maxStaleness_;
        window = window_;
        aprCap = aprCap_;
        twapWindow = twapWindow_;
    }

    // --------------------------------------------------------------------- the push (CRE → Base)
    /// @notice The CRE workflow pushes the 964 rate. Envelope `abi.encode(uint8 reportType, bytes payload)`; payload
    ///         `abi.encode(uint256 rate, uint48 ts)` — the raw rate + the DON PUSH time (`cre/szalpha-rate` stamps
    ///         `runtime.Now()`, the sharefeeds pattern — never the 964 block time, whose skew vs Base would make the
    ///         not-future/staleness gates below judge the wrong clock). Under DON stamping the `FutureTimestamp`
    ///         guard is a pure producer-bug tripwire (e.g. a ms-vs-s stamp fails LOUDLY on the first push instead of
    ///         poisoning the strictly-newer cursor forever — this contract has no admin reset, so an accepted
    ///         far-future `ts` would both wedge every later push AND read permanently fresh). Forwarder-gated.
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (reportType != RATE) revert InvalidReportType(reportType);
        (uint256 rate, uint48 ts) = abi.decode(payload, (uint256, uint48));
        if (rate == 0) revert ZeroRate();
        if (ts > block.timestamp) revert FutureTimestamp();
        if (ts <= latest.ts) revert StaleReport(); // strictly newer: no replay / out-of-order
        // No deviation band: publish the rate the chain reports. A band can't tell a real emission spike from a bad
        // read (identical in one number), so it would reject genuine moves; DON f+1 consensus catches a misread and
        // the staleness gate catches a frozen feed. The value guards are only non-zero / not-future / strictly-newer.

        // Maintain the trailing checkpoints for the derived APR.
        bool rolled;
        if (curAnchor.ts == 0) {
            curAnchor = Sample(rate, ts); // seed
        } else if (ts - curAnchor.ts >= window) {
            prevAnchor = curAnchor; // retire the matured checkpoint to the trailing slot
            curAnchor = Sample(rate, ts);
            rolled = true;
        }

        // Advance the rate-seconds accumulator BEFORE overwriting `latest`, so the elapsed interval is booked at the
        // rate that was actually live across it. This is the ordering `SzipNavOracle._processReport` uses for its leg
        // pushes, and it is why a bad push cannot retroactively reprice the interval that preceded it.
        if (latest.ts == 0) {
            genesisTs = ts; // the seed push: nothing precedes it, so nothing to accumulate
        } else {
            // UNCHECKED, deliberately. The push must never revert on MAGNITUDE — "no deviation band" is the ratified
            // design (a slash legitimately moves the rate), and an overflow revert here would be a magnitude band by
            // the back door, bricking the feed on exactly the reading a breaker needs to see. This is the standard
            // accumulator contract: it may wrap, and `twapRate` only ever reads DIFFERENCES of two points, which stay
            // correct across a wrap. A rate absurd enough to overflow the difference makes the average meaningless,
            // but such a value is a producer bug that `rawExchangeRate()` and Phase C alarm 3 surface immediately.
            unchecked {
                cumRate += latest.rate * uint256(ts - latest.ts);
            }
        }
        obsIndex = (obsIndex + 1) % CARDINALITY;
        observations[obsIndex] = Observation({ts: ts, cum: cumRate});

        latest = Sample(rate, ts);
        emit RatePushed(rate, ts, rolled);
    }

    // --------------------------------------------------------------------- IXAlphaRate (the deliverable)
    /// @notice The Base-side xALPHA exchange rate (alpha per xALPHA, 18-dp) — the last value CRE pushed from 964.
    ///         Consumers (NAV / Euler adapter) read this and MUST gate on `fresh()` (a rate that moves NAV must
    ///         fail-closed on a stale push). Returns 0 if never pushed OR while only the seed push exists — it
    ///         does NOT revert; both consumers route 0 into their `RateUnseeded` fail-closed path.
    /// @dev  WARM-UP GATE. The seed push is the one value `twapRate()` cannot smooth (nothing precedes it), and
    ///       the failure the smoothing prices — a wrong value from our own producer side — arrives identically on
    ///       push 1. Serving the raw seed would hand NAV that value unattenuated for one cadence period, and the
    ///       deploy wires this oracle into `SzipNavOracle` before any push exists. So until one CLOSED interval
    ///       exists (`latest.ts != genesisTs`) consumers get 0, i.e. stay closed; `rawExchangeRate()` still serves
    ///       the seed so the alarm-5 equality watch sees a bad first push the moment it lands.
    function exchangeRate() external view returns (uint256) {
        uint256 spot = latest.rate;
        if (spot == 0) return 0; // never pushed — `fresh()` is the consumer's gate, unchanged
        if (latest.ts == genesisTs) return 0; // seed only: no closed interval to smooth against — fail closed
        uint256 t = twapRate();
        return t < spot ? t : spot;
    }

    /// @notice The raw last-pushed rate, UNSMOOTHED. For monitoring only — Phase C alarm 3 watches this, because a
    ///         mis-scaled push must be visible the moment it lands, not a day later once it has soaked into the
    ///         average. NAV must NOT read this; it reads `exchangeRate()`.
    function rawExchangeRate() external view returns (uint256) {
        return latest.rate;
    }

    /// @notice The time-weighted average pushed rate over the trailing `twapWindow`, 18-dp.
    /// @dev  NO SPOT FALLBACK. `SzipNavOracle.twapNavPerShare` returns raw spot when it has no history, which makes
    ///       its guard vanish exactly when there is nothing to smooth against. This uses whatever history exists
    ///       instead: after three pushes it averages three, after ten it averages ten, and the smoothing strengthens
    ///       on its own. The only unsmoothed moment is the seed push, where there is genuinely nothing to average —
    ///       which is why `exchangeRate()` serves 0 (consumers fail closed) until the seed's interval is closed.
    /// @dev  CLOSED INTERVALS ONLY. The average runs to `latest.ts`, NOT to `block.timestamp`. Booking the trailing
    ///       segment `[latest.ts, now]` at the newest rate is the right-endpoint mistake that makes
    ///       `SzipNavOracle._accumulate` reprice a whole idle gap at whatever spot is current — measured here, a
    ///       x1,000,000 push with one hour of trailing segment against a 24h window leaked ~40,000x into the average
    ///       and defeated the smoothing outright. Excluding it means a fresh push carries NO weight until the next
    ///       push closes its interval, so one hourly push really is 1/24 of a 24h window.
    /// @dev  A feed that stops pushing therefore freezes the average rather than drifting toward its last value.
    ///       That is correct here: staleness is `fresh()`'s job, and consumers must already fail closed on it.
    function twapRate() public view returns (uint256) {
        uint48 lastTs = latest.ts;
        if (lastTs == 0) return 0;

        uint256 nowTs = uint256(lastTs);
        uint256 cumNow = cumRate;

        // Target the window edge, but never reach back past genesis — before it there is no history, not a zero rate.
        uint256 target = nowTs > twapWindow ? nowTs - twapWindow : 0;
        if (target < genesisTs) target = genesisTs;

        // Walk back for the newest observation at or before `target`; the ring is small and hourly-written.
        uint256 idx = obsIndex;
        for (uint256 i = 0; i < CARDINALITY; i++) {
            Observation memory o = observations[idx];
            if (o.ts != 0 && uint256(o.ts) <= target) {
                uint256 dt = nowTs - uint256(o.ts);
                if (dt == 0) break; // same-second read against the edge point: fall through to the genesis span
                unchecked {
                    return (cumNow - o.cum) / dt; // difference across the wrapping accumulator
                }
            }
            idx = idx == 0 ? uint256(CARDINALITY) - 1 : idx - 1;
        }

        // The ring holds nothing that old and it is FULL: every slot was written inside the window, i.e. the push
        // cadence outran CARDINALITY. Average from the oldest surviving observation, so the window degrades to the
        // ring's actual span instead of silently stretching to the oracle's whole lifetime. The next slot to be
        // overwritten is the oldest; `ts == 0` there means the ring never filled, which is the young-feed case below.
        Observation memory oldest = observations[(uint256(obsIndex) + 1) % CARDINALITY];
        if (oldest.ts != 0) {
            uint256 ringSpan = nowTs - uint256(oldest.ts); // > 0: 32 strictly-increasing ts, so oldest < latest
            unchecked {
                return (cumNow - oldest.cum) / ringSpan; // difference across the wrapping accumulator
            }
        }

        // Young feed: the ring still holds everything since the seed push — average over the partial window.
        uint256 span = nowTs - uint256(genesisTs);
        if (span == 0) return latest.rate; // the seed push itself, read in the same second
        return cumNow / span;
    }

    /// @notice The DON push time of the latest pushed rate (0 ⇒ never pushed).
    function lastUpdate() external view returns (uint48) {
        return latest.ts;
    }

    /// @notice True iff a rate has been pushed AND it is within `maxStaleness`. The consumer's fail-closed gate.
    function fresh() public view returns (bool) {
        return latest.ts != 0 && block.timestamp - latest.ts <= maxStaleness;
    }

    // --------------------------------------------------------------------- derived APR (convenience view)
    /// @notice The intrinsic LST APR (bps), DERIVED on-chain from the pushed rate's history:
    ///         `(rate_now/rate_prev − 1) × year/Δ`. Floored at 0 (a slash/decline is 0, not negative — `uint32`),
    ///         clamped to `aprCap`. `0` until a trailing checkpoint exists. Advisory; never reverts. NAV does NOT
    ///         use this — it reads `exchangeRate()` directly. (Resolves 8x-02 without any pushed APR.)
    function intrinsicAprBps() external view returns (uint32) {
        Sample memory a = prevAnchor.ts != 0 ? prevAnchor : curAnchor;
        if (a.ts == 0 || latest.ts == 0) return 0;
        uint256 rNow = latest.rate;
        uint256 dt = latest.ts > a.ts ? latest.ts - a.ts : 0;
        if (rNow <= a.rate || dt == 0) return 0; // slash/decline/flat ⇒ 0
        // Annualize in ONE expression — do NOT compute growthBps then annualize. Real Bittensor per-tempo growth is
        // sub-bps (~0.0016% per 72-min tempo for an ~11% alpha-APR validator); a two-step `(rNow-rPrev)*BPS/rPrev`
        // truncates that to 0 and the feed silently reads 0% for any short window. Multiplying up before the divide
        // keeps the precision (verified against live netuid-64 validators: 11.4 / 19.7 / 20.7%).
        // saturate rather than overflow — keep this view TOTAL for ANY pushed rate (the push
        // path has no upper bound by design, "no deviation band"). A growth large enough to overflow the
        // multiply-up annualizes far beyond aprCap (⇒ return aprCap); a rate large enough to overflow the
        // `a.rate * dt` denominator makes the true APR ~0 (⇒ return 0). Both checks are overflow-free
        // divisions (BPS*SECONDS_PER_YEAR is a compile-time constant; dt ≥ 1 here).
        if (rNow - a.rate > type(uint256).max / (BPS * SECONDS_PER_YEAR)) return uint32(aprCap); // aprCap ≤ uint32.max (ctor)
        if (a.rate > type(uint256).max / dt) return 0;
        uint256 annual = (rNow - a.rate) * BPS * SECONDS_PER_YEAR / (a.rate * dt);
        if (annual > aprCap) annual = aprCap;
        return uint32(annual);
    }
}
