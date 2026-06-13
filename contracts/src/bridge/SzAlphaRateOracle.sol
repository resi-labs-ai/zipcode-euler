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

    // --------------------------------------------------------------------- state
    struct Sample {
        uint256 rate; // exchangeRate() (alpha per xALPHA, 18-dp)
        uint48 ts; // the 964 read time the workflow stamped (0 ⇒ unset)
    }

    /// @notice The latest pushed rate — the headline `exchangeRate()` (updates every push).
    Sample public latest;
    /// @notice The trailing checkpoint the APR derives against (rolls every `window`).
    Sample public prevAnchor;
    /// @notice The maturing checkpoint, retired to `prevAnchor` once `window` old.
    Sample public curAnchor;

    // --------------------------------------------------------------------- errors / events
    error InvalidReportType(uint8 reportType);
    error ZeroRate();
    error FutureTimestamp();
    error StaleReport(); // a push not strictly newer than the cached one (replay / out-of-order)
    error ZeroWindow();
    error InvalidAprCap();
    error ZeroMaxStaleness();

    event RatePushed(uint256 rate, uint48 ts, bool rolled);

    /// @param forwarder The Chainlink Forwarder (the CRE write path; reverts on zero in `ReceiverTemplate`).
    /// @param maxStaleness_ The consumer freshness bound (seconds, `!= 0`).
    /// @param window_ The derived-APR trailing window (seconds, `!= 0`).
    /// @param aprCap_ The derived-APR display clamp (bps, `!= 0` and `<= type(uint32).max`).
    constructor(address forwarder, uint256 maxStaleness_, uint32 window_, uint256 aprCap_)
        ReceiverTemplate(forwarder)
    {
        if (maxStaleness_ == 0) revert ZeroMaxStaleness();
        if (window_ == 0) revert ZeroWindow();
        if (aprCap_ == 0 || aprCap_ > type(uint32).max) revert InvalidAprCap();
        maxStaleness = maxStaleness_;
        window = window_;
        aprCap = aprCap_;
    }

    // --------------------------------------------------------------------- the push (CRE → Base)
    /// @notice The CRE workflow pushes the 964 rate. Envelope `abi.encode(uint8 reportType, bytes payload)`; payload
    ///         `abi.encode(uint256 rate, uint48 ts)` — the raw rate + the 964 read time. Forwarder-gated.
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

        latest = Sample(rate, ts);
        emit RatePushed(rate, ts, rolled);
    }

    // --------------------------------------------------------------------- IXAlphaRate (the deliverable)
    /// @notice The Base-side xALPHA exchange rate (alpha per xALPHA, 18-dp) — the last value CRE pushed from 964.
    ///         Consumers (NAV / Euler adapter) read this and MUST gate on `fresh()` (a rate that moves NAV must
    ///         fail-closed on a stale push). Returns 0 if never pushed — it does NOT revert, which is exactly
    ///         why the `fresh()` gate is mandatory (`latest.ts == 0` ⇒ not fresh; an ungated consumer would
    ///         read a 0 rate).
    function exchangeRate() external view returns (uint256) {
        return latest.rate;
    }

    /// @notice The 964 read time of the latest pushed rate (0 ⇒ never pushed).
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
        uint256 annual = (rNow - a.rate) * BPS * SECONDS_PER_YEAR / (a.rate * dt);
        if (annual > aprCap) annual = aprCap;
        return uint32(annual);
    }
}
