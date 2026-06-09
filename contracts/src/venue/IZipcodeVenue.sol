// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title IZipcodeVenue
/// @notice The venue-neutral seam (§4.7) the `ZipcodeController` (§4.4) drives every on-chain venue effect
///         through. Only `bytes32`/`address`/`uint*`/opaque `lineRef` cross this boundary — NO Euler types
///         (`IEVault`/`MarketAllocation`/`BatchItem`/EVC/router/`LineAccount`). One config (Euler) is built today;
///         the interface keeps the controller venue-agnostic (§4.7 #10).
interface IZipcodeVenue {
    /// @notice Emitted when a credit line's full isolated-market cluster is minted + wired.
    /// @param lienId The lien identity (the `LineAccount` CREATE2 salt).
    /// @param lineRef The opaque line handle (the borrow vault) used by every later method.
    /// @param oracleKey The address the controller seeds the price on (= the lien token).
    /// @param collateralVault The per-line escrow collateral vault (holds the lien).
    /// @param router The per-line frozen price router.
    /// @param borrowAccount The fresh per-line EVC borrow account (borrower-of-record).
    event LineOpened(
        bytes32 indexed lienId,
        address indexed lineRef,
        address oracleKey,
        address collateralVault,
        address router,
        address borrowAccount
    );

    /// @notice Emitted when a line's LTV + borrow cap are (re)set.
    event LineLimitsSet(address indexed lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap);

    /// @notice Emitted when liquidity is reallocated into a line's borrow vault.
    event LineFunded(address indexed lineRef, uint256 amount);

    /// @notice Emitted when a line draws against its collateral to the off-ramp.
    event LineDrawn(address indexed lineRef, uint256 amount, address receiver);

    /// @notice Emitted when a line is closed (collateral reclaimed; cluster abandoned).
    event LineClosed(address indexed lineRef);

    /// @notice Mint + wire a fresh isolated-market cluster for a credit line, atomically.
    /// @param lienId The lien identity (the per-line `LineAccount` CREATE2 salt).
    /// @param lienToken The lien collateral token (the escrow vault's asset + the oracle key).
    /// @param collateralAmount The lien amount custodied (must be the full `1e18`).
    /// @return lineRef The opaque line handle (the borrow vault).
    /// @return oracleKey The address the controller seeds the price on (= `lienToken`).
    function openLine(bytes32 lienId, address lienToken, uint256 collateralAmount)
        external
        returns (address lineRef, address oracleKey);

    /// @notice Set the line's borrow/liquidation LTV and its absolute borrow cap.
    function setLineLimits(address lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap) external;

    /// @notice Reallocate `amount` of base liquidity into the line's borrow vault.
    function fund(address lineRef, uint256 amount) external;

    /// @notice Draw `amount` against the line's collateral to `receiver` (pinned to the off-ramp).
    function draw(address lineRef, uint256 amount, address receiver) external;

    /// @notice The line's current outstanding debt (readable after close).
    function observeDebt(address lineRef) external view returns (uint256);

    /// @notice Close a fully-repaid line, reclaiming the collateral to the controller.
    function closeLine(address lineRef) external;

    /// @notice Defensive stub — no on-chain economic liquidation (§4.4e). Always reverts.
    function liquidate(address lineRef) external;
}
