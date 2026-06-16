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
///         consensus + the Timelock-pinned Forwarder).
contract ZipcodeOracleRegistry is ReceiverTemplate, BaseAdapter {
    /// @notice The pinned lien-token decimals (= `LienTokenFactory.LIEN_DECIMALS`). Every priced key is guarded to it.
    /// @dev LOAD-BEARING — do not relax: the global `scale` is derived once with `baseDecimals = 18`
    ///      (`calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals)`), and `_writePrice` rejects any key whose
    ///      `decimals() != 18` (`_strictDecimals`). Together these make a non-18-dp lien UNREACHABLE by design: there
    ///      is one shared scale, not a per-key scale. Relaxing the 18-dp guard without first introducing per-key
    ///      scaling would silently mis-scale every non-18-dp mark — never loosen it in isolation.
    uint8 public constant LIEN_DECIMALS = 18;
    /// @notice The oracle name (satisfies `IPriceOracle.name()`).
    string public constant name = "ZipcodeOracleRegistry";
    /// @notice The `reportType` (§4.4 report ABI) the registry accepts.
    uint8 public constant REVALUATION = 3;

    // NOTE (2026-06-09, §17): wiring below is Timelock-settable, NOT immutable — build-phase flexibility. Lock pre-prod.
    /// @notice The unit of account (USDC). Timelock-settable.
    address public quote;
    /// @notice The long, line-term read-staleness window (no upper-bound cap; the mark is event-driven). Timelock-settable.
    uint256 public validityWindow;
    /// @notice The scale: baseDecimals=18, quoteDecimals=feedDecimals=quote's decimals. Re-derived on `setQuote`.
    Scale internal scale;

    /// @notice A cached Proof-of-Value mark for a lien. `timestamp == 0` ⇒ unset.
    struct Cache {
        uint208 price;
        uint48 timestamp;
    }

    /// @notice The push-cache, keyed on the lien token address. The registry never stores a `lienId`.
    mapping(address => Cache) public cache;
    /// @notice The origination-seed authority (`ZipcodeController`). Timelock-settable (build phase, §17).
    address public controller;

    /// @notice The caller of `seedPrice` is not the controller.
    error NotController();
    /// @notice A zero address in a Timelock re-point.
    error ZeroAddress();
    /// @notice The report's `reportType` is not `REVALUATION` (3).
    error InvalidReportType(uint8 reportType);
    /// @notice The revaluation `liens`/`prices` arrays have different lengths.
    error LengthMismatch();
    /// @notice The lien's `decimals()` is not `LIEN_DECIMALS`, missing, or the call failed (strict guard).
    error InvalidLienDecimals(address lien);
    /// @notice A revaluation `ts` is dated after `block.timestamp` (timestamp-sanity, not a value band).
    error FutureTimestamp();
    /// @notice A write whose `ts` is not strictly newer than the cached mark (replay / out-of-order). Mirrors `SzAlphaRateOracle`.
    error StaleReport();

    /// @notice The controller was wired (Timelock-settable, build phase).
    event ControllerSet(address indexed controller);
    /// @notice A lien's mark was seeded by the controller at origination.
    event RegistryPriceSeed(address indexed lien, uint256 price);
    /// @notice A lien's mark was revalued by the Forwarder.
    event RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp);
    /// @notice A Timelock re-point of an address wiring slot (build phase).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice A Timelock re-set of the read-staleness window.
    event ValidityWindowSet(uint256 window);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`); Timelock-re-pointable (§17), not renounce-frozen.
    /// @param quote_ The unit of account (USDC).
    /// @param validityWindow_ The long, line-term read-staleness window.
    constructor(address forwarder, address quote_, uint256 validityWindow_) ReceiverTemplate(forwarder) {
        quote = quote_;
        validityWindow = validityWindow_;
        uint8 quoteDecimals = _getDecimals(quote_);
        scale = ScaleUtils.calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals);
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Wire the origination-seed authority. Timelock-settable (build phase, §17): re-pointable, `onlyOwner`.
    /// @param c The controller address.
    function setController(address c) external onlyOwner {
        if (c == address(0)) revert ZeroAddress();
        controller = c;
        emit ControllerSet(c);
    }

    /// @notice Re-point the unit of account (re-derives `scale`). `onlyOwner` (Timelock).
    function setQuote(address quote_) external onlyOwner {
        if (quote_ == address(0)) revert ZeroAddress();
        quote = quote_;
        uint8 quoteDecimals = _getDecimals(quote_);
        scale = ScaleUtils.calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals);
        emit WiringSet("quote", quote_);
    }

    /// @notice Re-set the read-staleness window. `onlyOwner` (Timelock).
    function setValidityWindow(uint256 validityWindow_) external onlyOwner {
        validityWindow = validityWindow_;
        emit ValidityWindowSet(validityWindow_);
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
    /// @dev the all-or-nothing batch is the INTENTIONAL WOOF-02 fail-closed design — a single bad mark
    ///      (zero/overflow price, future/stale ts, off-decimal key) reverts the whole report so no partial, possibly
    ///      inconsistent revaluation lands. A per-key try/catch would WEAKEN this (it would swallow a poison key and
    ///      let the rest through) — deliberately NOT added. The producer mitigates the blast radius by SHARDING:
    ///      it caps each report at `MAX_LIENS_PER_REPORT` keys and the long line-term validity window tolerates a
    ///      failed shard's keys staying on their prior mark until the next push (see the CRE producer runbook in
    ///      `build/claude-zipcode.md` §8.1, "Revaluation sharding (the WOOF-02 discharge)").
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
        if (ts <= cache[lien].timestamp) revert StaleReport(); // strictly-newer (first write: timestamp==0 passes); covers seedPrice clobber + out-of-order rt-3
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
    /// @dev the adapter is INTENTIONALLY forward-only. A reverse-pair quote (`base == quote`,
    ///      `quoteAsset == LIEN_i`) already fails closed at the `quoteAsset != quote` guard below, and the EVK
    ///      collateral path never quotes the reverse direction for a lien. Adding inverse support would be dead
    ///      code (an un-exercised, un-needed surface) — deliberately NOT added.
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
