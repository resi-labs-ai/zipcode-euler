// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {BaseAdapter, Errors} from "euler-price-oracle/adapter/BaseAdapter.sol";
import {IICHIVault} from "../interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../interfaces/algebra/IAlgebraPool.sol";
import {IchiAlgebraFairReserves} from "./lib/IchiAlgebraFairReserves.sol";
import {TickMath, FullMath} from "../libraries/ConcentratedLiquidity.sol";

/// @title AlgebraIchiFairLpOracle
/// @notice A TRUSTLESS, fully on-chain fair-value price oracle for an ICHI-vault LP share on an Algebra pool — the
///         `IPriceOracle`/`BaseAdapter` face an EVK `EulerRouter` resolves the LP collateral through. It prices the
///         LP share in `quote` (= the pool's token1, the stable leg, e.g. USDC) by:
///           1. reconstructing the vault's reserves at the pool's TWAP tick (manipulation-resistant — see
///              `IchiAlgebraFairReserves`), NOT the in-block-manipulable current tick;
///           2. valuing the volatile leg (token0) in token1 at that same TWAP tick;
///           3. pro-rating the resulting TVL by the caller's LP-share fraction (rounded DOWN, against the borrower).
///
///         This is the trustless on-chain alternative to `SzipReservoirLpOracle`'s CRE-pushed mark: same EVK
///         `_getQuote(lpShares) -> USDC` face, but no off-chain push and no liveness dependency — the price is a
///         pure function of pool/vault state + the Algebra TWAP. Fail-closed: reverts (`NoPlugin` / a plugin TWAP
///         revert / zero supply) so a missing manipulation-resistant price FAILS THE BORROW rather than opening an
///         unsafe one.
///
/// @dev Params are immutable (a cheap, replaceable clone, per the repo's oracle philosophy): re-pointing the vault
///      or TWAP window is a redeploy + a one-call router re-point, not a setter. `quote` is pinned to the pool's
///      token1 at construction. Validated on-chain 2026-06-14 against HYDX/USDC vault 0xfF8B…73f7.
contract AlgebraIchiFairLpOracle is BaseAdapter {
    using IchiAlgebraFairReserves for address;

    /// @notice The oracle name (satisfies `IPriceOracle.name()`).
    string public constant name = "AlgebraIchiFairLpOracle";

    /// @notice The priced key: the ICHI LP share token (also the vault contract, 18-dp).
    address public immutable lpToken;
    /// @notice The unit of account = the pool's token1 (the stable leg, e.g. USDC).
    address public immutable quote;
    /// @notice The pool's token0 (the volatile leg, e.g. HYDX) — valued in `quote` at the TWAP tick.
    address public immutable token0;
    /// @notice The TWAP averaging window (seconds) for the Algebra price read.
    uint32 public immutable twapWindow;

    error ZeroAddress();
    error ZeroWindow();

    /// @param vault_      The ICHI vault (== the LP share token). Its pool must expose a TWAP plugin.
    /// @param twapWindow_ The TWAP window in seconds (e.g. 3600 for 1h).
    constructor(address vault_, uint32 twapWindow_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (twapWindow_ == 0) revert ZeroWindow();
        address pool = IICHIVault(vault_).pool();
        if (IAlgebraPool(pool).plugin() == address(0)) revert IchiAlgebraFairReserves.NoPlugin();
        lpToken = vault_;
        token0 = IICHIVault(vault_).token0();
        quote = IICHIVault(vault_).token1();
        twapWindow = twapWindow_;
    }

    /// @notice The vault's TVL expressed in `quote`, plus the fair reserves + TWAP tick used (monitoring / tests).
    function fairTvl() external view returns (uint256 tvlInQuote, uint256 amount0, uint256 amount1, int24 meanTick) {
        (amount0, amount1, meanTick) = IchiAlgebraFairReserves.fairReserves(lpToken, twapWindow);
        tvlInQuote = amount1 + _token0InQuote(meanTick, amount0);
    }

    /// @notice Convert `inAmount` LP shares to `quote` (token1) at the fair TWAP valuation, rounded DOWN.
    ///         Only `(lpToken, quote)` is supported; `bid == ask == mid`.
    function _getQuote(uint256 inAmount, address base, address quoteAsset)
        internal
        view
        override
        returns (uint256)
    {
        if (base != lpToken || quoteAsset != quote) revert Errors.PriceOracle_NotSupported(base, quoteAsset);

        (uint256 amount0, uint256 amount1, int24 meanTick) = IchiAlgebraFairReserves.fairReserves(lpToken, twapWindow);
        uint256 tvlInQuote = amount1 + _token0InQuote(meanTick, amount0);

        uint256 supply = IICHIVault(lpToken).totalSupply();
        if (supply == 0) revert Errors.PriceOracle_NotSupported(base, quoteAsset);

        // pro-rata of the fair TVL, rounded DOWN (against the borrower).
        return FullMath.mulDiv(tvlInQuote, inAmount, supply);
    }

    /// @dev Value `amount0` of token0 in token1 units at `tick`. Mirrors UniV3 `OracleLibrary.getQuoteAtTick` but
    ///      accepts a full `uint256` amount0 (via `FullMath.mulDiv`'s 512-bit product), so a large vault never hits
    ///      the `uint128` base-amount cap. token1 is `quote`, so this returns `quote` units.
    function _token0InQuote(int24 tick, uint256 amount0) internal view returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        bool zeroIsBase = token0 < quote; // address-ordering: price = (sqrtP)^2 = token1/token0 when token0 < token1
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP;
            return zeroIsBase
                ? FullMath.mulDiv(amount0, ratioX192, 1 << 192)
                : FullMath.mulDiv(amount0, 1 << 192, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
            return zeroIsBase
                ? FullMath.mulDiv(amount0, ratioX128, 1 << 128)
                : FullMath.mulDiv(amount0, 1 << 128, ratioX128);
        }
    }
}
