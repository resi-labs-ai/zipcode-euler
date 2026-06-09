// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title ILienXAlphaEscrow — the bond seam the `DefaultCoordinator` drives
/// @notice The four `onlyCoordinator` state-changers + the two bond views the coordinator reads to route a slash.
///         Interface-not-import (the escrow is in-repo but a thin interface keeps the coupling loose, the project
///         pattern). The concrete impl is `LienXAlphaEscrow.sol`; signatures verified against it BUILT-VERIFIED
///         2026-06-09 (`:111/:128/:147/:165/:60/:62`).
interface ILienXAlphaEscrow {
    function lockXAlpha(bytes32 lienId, address originator, uint256 amount) external;
    function releaseXAlpha(bytes32 lienId) external;
    function slashXAlphaToCapital(bytes32 lienId, uint256 amount) external;
    function slashXAlphaToCohort(bytes32 lienId) external;

    function bondAmount(bytes32 lienId) external view returns (uint256);
    function bondOriginator(bytes32 lienId) external view returns (address);
}
