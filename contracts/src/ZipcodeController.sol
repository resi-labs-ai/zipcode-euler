// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IZipcodeVenue} from "./venue/IZipcodeVenue.sol";

/// @notice The lien-token factory faces the controller needs (WOOF-01). Declared inline to avoid the
///         OZ-vs-forge-std `IERC20` import choice; the factory is a plain contract, not re-implemented here.
interface ILienTokenFactory {
    function create(bytes32 lienId) external returns (address);
    function computeAddress(bytes32 lienId, address controller) external view returns (address);
}

/// @notice The two faces the controller needs on a lien token (WOOF-01): `approve` (so the venue can pull the
///         escrow deposit) and the controller-only `burn` (close path). One local interface sidesteps importing
///         OZ `IERC20`.
interface ILienToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

/// @notice The single write face the controller touches on the registry (WOOF-02): the controller-gated seed.
interface IZipcodeOracleRegistry {
    function seedPrice(address lien, uint256 price) external;
}

/// @title ZipcodeController (§4.4)
/// @notice The portable core's orchestrator: the CRE receiver (inbound gated on an immutable Forwarder), the
///         report decode + per-`reportType` decision logic, and the lien-token mint/burn authority. It is the
///         on-chain borrower of record — but it touches NO EVC: every on-chain venue effect (open a line, set
///         LTV/caps, fund, draw, observe debt, close) is driven through the venue-neutral `IZipcodeVenue` seam
///         (§4.7). The mechanical EVC borrow-on-behalf is the adapter's job as the line's per-line EVC operator
///         (granted by the line's `LineAccount` inside `openLine`); the controller never calls EVC.
contract ZipcodeController is ReceiverTemplate {
    // ----- the full lien (a 1/1 primitive: 1e18 minted at construction, WOOF-01) -----
    uint256 internal constant FULL_LIEN = 1e18;

    // ----- report-type discriminants (§4.4 report ABI) -----
    uint8 internal constant RT_ORIGINATION = 1;
    uint8 internal constant RT_DRAW = 2;
    // 3 = Revaluation -> NOT handled here (delivered direct to the registry, §4.1); rejected.
    uint8 internal constant RT_CLOSE = 4;
    uint8 internal constant RT_DEFAULT = 5;
    uint8 internal constant RT_LIQUIDATION = 6;

    // ----- cross-component wiring (5-arg ctor; NO EVC) -----
    // NOTE (2026-06-09, §17): the wiring below is Timelock-settable, NOT immutable — build-phase flexibility so a
    // redeployed venue/factory/registry/off-ramp is a one-call re-point, not a redeploy cascade. The Timelock is the
    // owner (via ReceiverTemplate's Ownable). Lock down pre-production.
    /// @notice The venue adapter — every on-chain venue effect goes through this `IZipcodeVenue` seam. Timelock-settable.
    address public venue;
    /// @notice The lien-token factory (the controller is the canonical `create`/`burn` caller, §4.2). Timelock-settable.
    address public lienFactory;
    /// @notice The shared Proof-of-Value registry (the controller is the set-once `seedPrice` caller, §4.2/§4.4). Timelock-settable.
    address public oracleRegistry;
    /// @notice The ONLY legal draw receiver — the Erebor off-ramp (the venue backstops `receiver == erebor`, F2). Timelock-settable.
    address public erebor;

    /// @notice Per-lien state. `lien` = LIEN_i (collateral token / oracle key); `lineRef` = the opaque venue line
    ///         handle returned by `openLine`. The controller stores no borrowAccount/subId — the per-line borrow
    ///         account is the adapter's internal artifact behind the seam.
    struct LienRecord {
        address lien;
        address lineRef;
        bool open;
    }

    /// @notice lienId => LienRecord. Public for cheap reads; the struct getter `getLien` returns the struct.
    mapping(bytes32 => LienRecord) public liens;

    // ----- errors (identity/sender/owner reverts reuse ReceiverTemplate/Ownable; no EVC errors) -----
    error ZeroAddress();
    error LienExists(bytes32 lienId);
    error UnknownLien(bytes32 lienId);
    error PrecomputeMismatch();
    error DebtOutstanding();
    error UnsupportedReportType(uint8 reportType);

    // ----- events -----
    event LienOriginated(
        bytes32 indexed lienId,
        address indexed lien,
        address lineRef,
        bytes32 proofRef,
        uint256 equityMark,
        uint256 drawAmount
    );
    event LienDrawn(bytes32 indexed lienId, uint256 equityMark, uint256 drawAmount);
    event LienReleased(bytes32 indexed lienId);
    event LienStatusUpdated(bytes32 indexed lienId, uint8 status);
    event WiringSet(bytes32 indexed slot, address value);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`); frozen by deploy renounce.
    /// @param venue_ The `IZipcodeVenue` adapter (every venue effect).
    /// @param lienFactory_ The `LienTokenFactory`.
    /// @param oracleRegistry_ The `ZipcodeOracleRegistry`.
    /// @param erebor_ The Erebor off-ramp (the only legal draw receiver).
    constructor(
        address forwarder,
        address venue_,
        address lienFactory_,
        address oracleRegistry_,
        address erebor_
    ) ReceiverTemplate(forwarder) {
        require(venue_ != address(0), "ZipcodeController: zero venue");
        require(lienFactory_ != address(0), "ZipcodeController: zero lienFactory");
        require(oracleRegistry_ != address(0), "ZipcodeController: zero oracleRegistry");
        require(erebor_ != address(0), "ZipcodeController: zero erebor");
        venue = venue_;
        lienFactory = lienFactory_;
        oracleRegistry = oracleRegistry_;
        erebor = erebor_;
    }

    // --- Timelock-settable wiring (build phase, §17) ---

    /// @notice Re-point `venue` (build phase, §17). onlyOwner (Timelock).
    function setVenue(address venue_) external onlyOwner {
        if (venue_ == address(0)) revert ZeroAddress();
        venue = venue_;
        emit WiringSet("venue", venue_);
    }

    /// @notice Re-point `lienFactory` (build phase, §17). onlyOwner (Timelock).
    function setLienFactory(address lienFactory_) external onlyOwner {
        if (lienFactory_ == address(0)) revert ZeroAddress();
        lienFactory = lienFactory_;
        emit WiringSet("lienFactory", lienFactory_);
    }

    /// @notice Re-point `oracleRegistry` (build phase, §17). onlyOwner (Timelock).
    function setOracleRegistry(address oracleRegistry_) external onlyOwner {
        if (oracleRegistry_ == address(0)) revert ZeroAddress();
        oracleRegistry = oracleRegistry_;
        emit WiringSet("oracleRegistry", oracleRegistry_);
    }

    /// @notice Re-point `erebor` (build phase, §17). onlyOwner (Timelock).
    function setErebor(address erebor_) external onlyOwner {
        if (erebor_ == address(0)) revert ZeroAddress();
        erebor = erebor_;
        emit WiringSet("erebor", erebor_);
    }

    /// @notice Struct getter (the public mapping auto-getter returns a tuple, not a struct).
    function getLien(bytes32 lienId) external view returns (LienRecord memory) {
        return liens[lienId];
    }

    /// @inheritdoc ReceiverTemplate
    /// @dev Decode the shared envelope `(uint8 reportType, bytes payload)` then dispatch. Fails closed on any
    ///      unknown type (incl. reportType 3, which is delivered direct to the registry, §4.1).
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));

        if (reportType == RT_ORIGINATION) {
            _origination(payload);
        } else if (reportType == RT_DRAW) {
            _draw(payload);
        } else if (reportType == RT_CLOSE) {
            _close(payload);
        } else if (reportType == RT_DEFAULT || reportType == RT_LIQUIDATION) {
            // M1: status-marker only — no markdown / escrow / venue.liquidate (§4.4d/e; DefaultCoordinator is M2).
            (bytes32 lienId, uint8 status) = abi.decode(payload, (bytes32, uint8));
            emit LienStatusUpdated(lienId, status);
        } else {
            revert UnsupportedReportType(reportType);
        }
    }

    /// @dev Origination branch (a) — the atomic batch: create -> openLine -> seed -> setLineLimits -> fund -> draw.
    ///      Any revert rolls back the whole branch (incl. the CREATE2 deploys) — no orphan lien/market.
    function _origination(bytes memory payload) internal {
        (
            bytes32 lienId,
            bytes32 proofRef,
            uint256 equityMark,
            uint16 borrowLTV,
            uint16 liqLTV,
            uint256 drawAmount,
            uint256 cap
        ) = abi.decode(payload, (bytes32, bytes32, uint256, uint16, uint16, uint256, uint256));

        // 1: clean dup guard (the factory also reverts FailedDeployment on a re-used slot).
        if (liens[lienId].lien != address(0)) revert LienExists(lienId);

        // 2: precompute + create + defensive assert (both addresses derive from (lienId, this) -> equal).
        address predicted = ILienTokenFactory(lienFactory).computeAddress(lienId, address(this));
        address lien = ILienTokenFactory(lienFactory).create(lienId);
        if (lien != predicted) revert PrecomputeMismatch();

        // 3: custody approve — exactly 1e18 (no standing allowance left, F-7).
        ILienToken(lien).approve(venue, FULL_LIEN);

        // 4: open the line with the FULL lien (the venue backstops != 1e18); oracleKey == lien by construction.
        (address lineRef, address oracleKey) = IZipcodeVenue(venue).openLine(lienId, lien, FULL_LIEN);

        // 5: seed the Proof-of-Value mark on the openLine-returned oracleKey, after openLine + before draw.
        IZipcodeOracleRegistry(oracleRegistry).seedPrice(oracleKey, equityMark);

        // 6: set limits (1e4-scale LTVs; raw cap).
        IZipcodeVenue(venue).setLineLimits(lineRef, borrowLTV, liqLTV, cap);

        // 7: fund + draw. The draw's on-chain LTV/cap bound (the EVK account-status check) is the only gate — the
        //    controller does NOT pre-check it. The borrow is authorized because the adapter is the line's operator.
        IZipcodeVenue(venue).fund(lineRef, drawAmount);
        IZipcodeVenue(venue).draw(lineRef, drawAmount, erebor);

        // 8: store + event (the liens write is LAST — last-write reentrancy safety, F-10).
        liens[lienId] = LienRecord({lien: lien, lineRef: lineRef, open: true});
        emit LienOriginated(lienId, lien, lineRef, proofRef, equityMark, drawAmount);
    }

    /// @dev Draw branch (a') — additional draw on an open line: re-anchor seed -> fund -> draw.
    function _draw(bytes memory payload) internal {
        (bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount) =
            abi.decode(payload, (bytes32, bytes32, uint256, uint256));

        LienRecord storage r = liens[lienId];
        if (!r.open) revert UnknownLien(lienId);

        // Re-anchor a fresh Proof-of-Value mark (also refreshes the cache timestamp, §4.4a'/§4.1).
        IZipcodeOracleRegistry(oracleRegistry).seedPrice(r.lien, equityMark);

        IZipcodeVenue(venue).fund(r.lineRef, drawAmount);
        IZipcodeVenue(venue).draw(r.lineRef, drawAmount, erebor);

        emit LienDrawn(lienId, equityMark, drawAmount);
        proofRef; // proofRef is carried for off-chain indexing; not stored on-chain.
    }

    /// @dev Close branch (c) — release on zero debt: observeDebt==0 -> closeLine -> burn(1e18) -> LienReleased.
    function _close(bytes memory payload) internal {
        bytes32 lienId = abi.decode(payload, (bytes32));

        LienRecord storage r = liens[lienId];
        if (!r.open) revert UnknownLien(lienId);

        if (IZipcodeVenue(venue).observeDebt(r.lineRef) != 0) revert DebtOutstanding();

        // closeLine reclaims the 1e18 lien back to the controller (operator-routed EVC.call redeem) — so the
        // reclaim happens BEFORE burn (else burn reverts ERC20InsufficientBalance, WOOF-01 obligation 1).
        IZipcodeVenue(venue).closeLine(r.lineRef);
        ILienToken(r.lien).burn(FULL_LIEN);

        // Keep r.lien set (single-use lienId forever, F-12); only flip open.
        r.open = false;
        emit LienReleased(lienId);
    }
}
