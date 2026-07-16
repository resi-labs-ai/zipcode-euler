// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Baal Loot/Shares ERC20 clones.
/// Source: reference/Baal/contracts/LootERC20.sol / SharesERC20.sol (ERC20Upgradeable, Ownable; no
/// decimals() override -> 18). Paused at summon by BaalSummoner.deployTokens (BaalSummoner.sol:303-304);
/// owned by the Baal (transferOwnership at :305-306). Only the surface 8-B1 reads is declared.
interface IBaalToken {
    function paused() external view returns (bool);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function owner() external view returns (address);

    function totalSupply() external view returns (uint256);
}
