// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {BaseAdapter, Errors, IPriceOracle} from "euler-price-oracle/adapter/BaseAdapter.sol";
import {ScaleUtils, Scale} from "euler-price-oracle/lib/ScaleUtils.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title ZipcodeOracleRegistry
/// @notice A single multi-asset push-cache price adapter that prices every lien token at its Proof of Value mark
///         (Proof-notarized appraised value − senior debt, in the unit of account). It is the EVK read-adapter
///         (`BaseAdapter`/`IPriceOracle` face) and the CRE receiver (`ReceiverTemplate`) in one contract. Two write
///         paths feed one venue-neutral cache: a controller-gated origination seed (`seedPrice`, single lien, atomic
///         with the controller's batch) and a Forwarder-gated revaluation (`_processReport`, reportType 3, batch). One
///         stale-checked view (`_getQuote`) serves it. The mark is event-driven (no heartbeat): a long, line-term
///         validity window, fail-closed guards, and no on-chain plausibility band (integrity is upstream: Proof + DON
///         consensus + immutable Forwarder).
contract ZipcodeOracleRegistry is ReceiverTemplate, BaseAdapter {
    /// @notice The pinned lien-token decimals (= `LienTokenFactory.LIEN_DECIMALS`). Every priced key is guarded to it.
    uint8 public constant LIEN_DECIMALS = 18;
    /// @notice The oracle name (satisfies `IPriceOracle.name()`).
    string public constant name = "ZipcodeOracleRegistry";
    /// @notice The `reportType` (§4.4 report ABI) the registry accepts.
    uint8 public constant REVALUATION = 3;

    /// @notice The unit of account (USDC).
    address public immutable quote;
    /// @notice The long, line-term read-staleness window (no upper-bound cap; the mark is event-driven).
    uint256 public immutable validityWindow;
    /// @notice The immutable scale: baseDecimals=18, quoteDecimals=feedDecimals=quote's decimals.
    Scale internal immutable scale;

    /// @notice A cached Proof-of-Value mark for a lien. `timestamp == 0` ⇒ unset.
    struct Cache {
        uint208 price;
        uint48 timestamp;
    }

    /// @notice The push-cache, keyed on the lien token address. The registry never stores a `lienId`.
    mapping(address => Cache) public cache;
    /// @notice The set-once origination-seed authority (`ZipcodeController`).
    address public controller;

    /// @notice The caller of `seedPrice` is not the controller.
    error NotController();
    /// @notice The controller has already been set (set-once).
    error ControllerAlreadySet();
    /// @notice The report's `reportType` is not `REVALUATION` (3).
    error InvalidReportType(uint8 reportType);
    /// @notice The revaluation `liens`/`prices` arrays have different lengths.
    error LengthMismatch();
    /// @notice The lien's `decimals()` is not `LIEN_DECIMALS`, missing, or the call failed (strict guard).
    error InvalidLienDecimals(address lien);
    /// @notice A revaluation `ts` is dated after `block.timestamp` (timestamp-sanity, not a value band).
    error FutureTimestamp();

    /// @notice The set-once controller was wired.
    event ControllerSet(address indexed controller);
    /// @notice A lien's mark was seeded by the controller at origination.
    event RegistryPriceSeed(address indexed lien, uint256 price);
    /// @notice A lien's mark was revalued by the Forwarder.
    event RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`); frozen by deploy-time renounce.
    /// @param quote_ The unit of account (USDC).
    /// @param validityWindow_ The long, line-term read-staleness window.
    constructor(address forwarder, address quote_, uint256 validityWindow_) ReceiverTemplate(forwarder) {
        quote = quote_;
        validityWindow = validityWindow_;
        uint8 quoteDecimals = _getDecimals(quote_);
        scale = ScaleUtils.calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals);
    }

    /// @notice Wire the set-once origination-seed authority. `onlyOwner`, frozen by the deploy-time renounce.
    /// @param c The controller address.
    function setController(address c) external onlyOwner {
        if (controller != address(0)) revert ControllerAlreadySet();
        controller = c;
        emit ControllerSet(c);
    }

    /// @notice Origination seed (§4.4a): the controller writes a single lien's mark inside its atomic batch.
    /// @param lien The lien token (oracle key).
    /// @param price The equity mark, in the quote asset's native units.
    function seedPrice(address lien, uint256 price) external {
        if (msg.sender != controller) revert NotController();
        _writePrice(lien, price, uint48(block.timestamp));
        emit RegistryPriceSeed(lien, price);
    }

    /// @notice Revaluation (§4.4 reportType 3): the Forwarder pushes a batch of new marks. All-or-nothing.
    /// @param report The shared §4.4 envelope `abi.encode(uint8 reportType, bytes payload)`.
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (reportType != REVALUATION) revert InvalidReportType(reportType);
        (address[] memory liens, uint256[] memory prices, uint32 ts) =
            abi.decode(payload, (address[], uint256[], uint32));
        if (liens.length != prices.length) revert LengthMismatch();
        for (uint256 i = 0; i < liens.length; i++) {
            _writePrice(liens[i], prices[i], uint48(ts));
            emit RegistryPriceUpdated(liens[i], prices[i], uint48(ts));
        }
    }

    /// @notice Shared write guards (fail-closed): price != 0, price <= uint208.max, ts <= now, decimals() == 18.
    function _writePrice(address lien, uint256 price, uint48 ts) internal {
        if (price == 0) revert Errors.PriceOracle_InvalidAnswer();
        if (price > type(uint208).max) revert Errors.PriceOracle_Overflow();
        if (ts > block.timestamp) revert FutureTimestamp();
        if (_strictDecimals(lien) != LIEN_DECIMALS) revert InvalidLienDecimals(lien);
        cache[lien] = Cache({price: uint208(price), timestamp: ts});
    }

    /// @notice Strict decimals read: reverts on a failed/short `decimals()` staticcall (NOT silent-18 like
    ///         `_getDecimals`). An off-by-decimal key (or a code-less EOA) must be rejected, not silently accepted.
    function _strictDecimals(address lien) internal view returns (uint8) {
        (bool ok, bytes memory d) = lien.staticcall(abi.encodeCall(IERC20.decimals, ()));
        if (!ok || d.length != 32) revert InvalidLienDecimals(lien);
        return abi.decode(d, (uint8));
    }

    /// @notice The single stale-checked read. Only `(LIEN_i, quote)` is supported; `bid==ask==mid`.
    /// @param inAmount The amount of `base` to convert.
    /// @param base The lien token being priced.
    /// @param quoteAsset The unit of account; must equal `quote`.
    function _getQuote(uint256 inAmount, address base, address quoteAsset)
        internal
        view
        override
        returns (uint256)
    {
        if (quoteAsset != quote) revert Errors.PriceOracle_NotSupported(base, quoteAsset);
        Cache memory c = cache[base];
        if (c.timestamp == 0) revert Errors.PriceOracle_NotSupported(base, quoteAsset);
        if (block.timestamp > c.timestamp) {
            uint256 s = block.timestamp - c.timestamp;
            if (s > validityWindow) revert Errors.PriceOracle_TooStale(s, validityWindow);
        }
        return ScaleUtils.calcOutAmount(inAmount, c.price, scale, false);
    }
}
