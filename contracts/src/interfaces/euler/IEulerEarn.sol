// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for an Euler `EulerEarn` ERC-4626 vault over USDC.
/// @dev The WOOF-00 `[EXT]` house posture: a LOCAL declaration (do NOT import the `euler-earn/` remap — it
///      pins solc 0.8.26 and carries an OZ-version ambiguity, the WOOF-04/05 + 8-B precedent). Mirrors
///      `ZipDepositModule.sol`'s local `IEulerEarn` but with the fuller surface the warehouse + its NAV
///      mark need. Signatures verified against `reference/euler-earn/src/EulerEarn.sol`:
///        deposit(uint256,address)            EulerEarn.sol:560 (reverts ZeroShares on 0-share mint :565)
///        redeem(uint256,address,address)     EulerEarn.sol:596 (owner is the 3rd arg; redeem(0) no-op :604)
///      `convertToAssets`/`balanceOf`/`asset` are the ERC-4626 read surface for the §4.5 senior NAV mark.
interface IEulerEarn {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function balanceOf(address account) external view returns (uint256);

    function asset() external view returns (address);
}
