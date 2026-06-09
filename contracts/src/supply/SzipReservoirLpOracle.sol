// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {BaseAdapter, Errors, IPriceOracle} from "euler-price-oracle/adapter/BaseAdapter.sol";
import {ScaleUtils, Scale} from "euler-price-oracle/lib/ScaleUtils.sol";

/// @title SzipReservoirLpOracle
/// @notice The CRE-fed push-cache LP-collateral price oracle for the 8-B5 reservoir loop (§4.5.1). A single-key
///         adapter (the ICHI LP share, quote = USDC) modeled directly on `ZipcodeOracleRegistry`: it is the EVK
///         read-adapter (`BaseAdapter`/`IPriceOracle` face) the reservoir's `EulerRouter` resolves the LP collateral
///         through, AND the CRE receiver (`ReceiverTemplate`) the Forwarder pushes the per-LP-share USD mark to. The
///         mark is computed off-chain by CRE as `(reserve_xALPHA × priceXAlpha + reserve_zipUSD × priceZipUSD) /
///         ICHI_LP_totalSupply` (the same reserve-value LP math `SzipNavOracle` runs for the basket's staked-LP leg)
///         and pushed via `_processReport` (reportType `LP_MARK`); a stale/missing mark FAILS THE BORROW CLOSED
///         (`_getQuote` reverts → the EVC account-status check reverts). Differences from the registry: a single fixed
///         key (`lpToken`, not a per-key map), the dedicated `LP_MARK` reportType, and NO controller-seed path (the
///         only writer is the Forwarder push). The inherited OZ-5 Ownable is renounced at deploy — re-pointing is the
///         router governor's job (the retained §17 Timelock), not an oracle-local owner.
contract SzipReservoirLpOracle is ReceiverTemplate, BaseAdapter {
    /// @notice The ICHI LP share decimals (18-dp). The base must be exactly this key.
    uint8 public constant LP_DECIMALS = 18;
    /// @notice The oracle name (satisfies `IPriceOracle.name()`).
    string public constant name = "SzipReservoirLpOracle";
    /// @notice The dedicated engine-oracle `reportType` (§8 placeholder, distinct from the registry's `REVALUATION=3`;
    ///         CRE-§8 ratifies it later — see the 8-B5 cross-ticket obligation).
    uint8 public constant LP_MARK = 7;

    /// @notice The unit of account (USDC).
    address public immutable quote;
    /// @notice The single priced key: the ICHI LP share token (18-dp).
    address public immutable lpToken;
    /// @notice The generous engine-cadence read-staleness window (CRE re-pushes each epoch). A stale mark fails the
    ///         borrow closed (the safe direction), never opens an unsafe one.
    uint256 public immutable validityWindow;
    /// @notice The immutable scale: baseDecimals=18 (LP), quoteDecimals=feedDecimals=quote's decimals.
    Scale internal immutable scale;

    /// @notice The cached per-LP-share mark (quote-native units). `timestamp == 0` ⇒ unset.
    struct Cache {
        uint208 price;
        uint48 timestamp;
    }

    /// @notice The single push-cache for `lpToken`.
    Cache public cache;

    /// @notice The report's `reportType` is not `LP_MARK`.
    error InvalidReportType(uint8 reportType);
    /// @notice A pushed `ts` is dated after `block.timestamp` (timestamp-sanity, not a value band).
    error FutureTimestamp();

    /// @notice The LP mark was updated by the Forwarder.
    event LpMarkUpdated(uint256 mark, uint32 timestamp);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`); the only writer.
    /// @param quote_ The unit of account (USDC).
    /// @param validityWindow_ The generous engine-cadence read-staleness window.
    /// @param lpToken_ The single ICHI LP share key (18-dp).
    constructor(address forwarder, address quote_, uint256 validityWindow_, address lpToken_)
        ReceiverTemplate(forwarder)
    {
        quote = quote_;
        lpToken = lpToken_;
        validityWindow = validityWindow_;
        uint8 quoteDecimals = _getDecimals(quote_);
        scale = ScaleUtils.calcScale(LP_DECIMALS, quoteDecimals, quoteDecimals);
    }

    /// @notice CRE push (reportType `LP_MARK`): the Forwarder writes the fresh per-LP-share mark. Only writer.
    /// @param report The shared §4.4 envelope `abi.encode(uint8 reportType, abi.encode(uint256 mark, uint32 ts))`.
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (reportType != LP_MARK) revert InvalidReportType(reportType);
        (uint256 mark, uint32 ts) = abi.decode(payload, (uint256, uint32));
        _writePrice(mark, uint48(ts));
        emit LpMarkUpdated(mark, ts);
    }

    /// @notice Shared fail-closed write guards: mark != 0, mark <= uint208.max, ts <= now.
    function _writePrice(uint256 mark, uint48 ts) internal {
        if (mark == 0) revert Errors.PriceOracle_InvalidAnswer();
        if (mark > type(uint208).max) revert Errors.PriceOracle_Overflow();
        if (ts > block.timestamp) revert FutureTimestamp();
        cache = Cache({price: uint208(mark), timestamp: ts});
    }

    /// @notice The single stale-checked read. Only `(lpToken, quote)` is supported; `bid==ask==mid`.
    /// @param inAmount The amount of `base` (LP shares) to convert.
    /// @param base The LP token being priced (must equal `lpToken`).
    /// @param quoteAsset The unit of account; must equal `quote`.
    function _getQuote(uint256 inAmount, address base, address quoteAsset)
        internal
        view
        override
        returns (uint256)
    {
        if (quoteAsset != quote || base != lpToken) revert Errors.PriceOracle_NotSupported(base, quoteAsset);
        Cache memory c = cache;
        if (c.timestamp == 0) revert Errors.PriceOracle_NotSupported(base, quoteAsset);
        if (block.timestamp > c.timestamp) {
            uint256 s = block.timestamp - c.timestamp;
            if (s > validityWindow) revert Errors.PriceOracle_TooStale(s, validityWindow);
        }
        // rounds DOWN — against the borrower.
        return ScaleUtils.calcOutAmount(inAmount, c.price, scale, false);
    }
}
