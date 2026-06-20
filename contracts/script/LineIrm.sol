// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IRMLinearKink} from "evk/InterestRateModels/IRMLinearKink.sol";

/// @title LineIrm (CTR-13) — the verified ~7.5%-APR flat IRM for the per-line credit-line borrow vaults.
/// @notice Single source of truth for the credit-line interest rate. A FLAT rate (`slope1 = slope2 = 0`,
///         `kink = type(uint32).max`) is the correct shape for a single-borrower isolated line: utilization is
///         ~binary per line, so the rate is `baseRate` at every utilization — no curve to traverse.
///
///         Units VERIFIED against EVK (not assumed — a units error silently mis-prices every line):
///         - `IIRM` returns the rate as SPY (second percent yield) scaled by 1e27 / RAY
///           (`reference/euler-vault-kit/src/InterestRateModels/IIRM.sol:16`).
///         - EVK accrues debt per second by `rpow(rate + 1e27, deltaT, 1e27)`
///           (`reference/euler-vault-kit/src/EVault/shared/Cache.sol:82`) — i.e. per-second COMPOUNDING.
///         - `SECONDS_PER_YEAR = 365.2425 * 86400 = 31_556_952` (Gregorian)
///           (`reference/euler-vault-kit/src/EVault/shared/Constants.sol:17`).
///
///         `BASE_RATE` is the per-second RAY rate for a NOMINAL 7.5% APR, written with the SAME idiom EVK uses for
///         its own rate constants (`reference/euler-vault-kit/src/Synths/IRMSynth.sol:18`) so the value is
///         compiler-derived — there is NO hardcoded magic number to mis-transcribe. Because EVK compounds
///         per-second, the effective APY is marginally above the nominal 7.5% (~7.788% = e^0.075 - 1): the
///         APR-vs-APY nuance. The farm utility borrow vault is left on `ZeroIRM` (internal POL, §4.5.1) — this IRM
///         is wired ONLY into the adapter `irm` slot, never the farm utility.
library LineIrm {
    /// @dev Matches EVK's `SECONDS_PER_YEAR` exactly (Gregorian calendar; the rational folds to integer 31_556_952).
    uint256 internal constant SECONDS_PER_YEAR = 365.2425 * 86400;

    /// @dev 7.5% nominal APR as a per-second 1e27-scaled (RAY) rate. `0.075 * 1e27` is the integer 7.5e25; the
    ///      constant division folds at compile time. Mirrors `IRMSynth.BASE_RATE = 1e27 * 0.005 / SECONDS_PER_YEAR`.
    uint256 internal constant BASE_RATE = 0.075 * 1e27 / SECONDS_PER_YEAR;

    /// @notice Deploy the flat ~7.5%-APR line IRM. Broadcast by the caller (call inside `vm.startBroadcast`).
    function deploy() internal returns (address) {
        return address(new IRMLinearKink(BASE_RATE, 0, 0, type(uint32).max));
    }
}
