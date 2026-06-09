// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LienCollateralToken
/// @notice A 1/1 fixed-supply collateral token: exactly 1e18 (one whole token at 18 decimals) minted once to the
///         controller at construction. One instance per lien; the lien's identity is this token's address. The
///         controller is the sole authority and may burn from its own balance at close. No mint path, no admin.
contract LienCollateralToken is ERC20 {
    /// @notice The sole authority over this token (mint-once-at-construction; burn). Set at deploy, immutable.
    address public immutable controller;

    /// @notice Thrown when a non-controller calls a controller-only function.
    error NotController();

    /// @param controller_ The token's authority; receives the entire 1e18 supply. Must be non-zero.
    constructor(address controller_) ERC20("Zipcode Lien Collateral", "zLIEN") {
        require(controller_ != address(0), "LienCollateralToken: zero controller");
        controller = controller_;
        _mint(controller_, 1e18);
    }

    /// @notice Pinned to 18 (constant narrowing override: legal to override a `view` base with `pure`). Pins the
    ///         scale per spec so a base bump can't silently shift it and the oracle never infers a wrong decimal.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Burn from the controller's own balance (close path). Controller-only.
    /// @param amount The amount to burn from the controller's balance.
    function burn(uint256 amount) external {
        if (msg.sender != controller) revert NotController();
        _burn(controller, amount);
    }
}
