// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SzipUSD
/// @notice The transferable 18-dp user share of the szipUSD junior vault (the two-token model: this is the user
///         token; the soulbound, ragequit-bearing Baal `Loot` is held only by the Exit Gate). Fixed-supply per
///         mint, non-rebasing — NAV accrues in *price* (`SzipNavOracle`), never in balance. A plain, freely
///         transferable ERC-20 (it trades on the CoW secondary, §6.2): the ONLY non-standard surface is the
///         `onlyGate` mint/burn. Build phase (2026-06-09, §17): a Timelock admin can re-point `gate` (so the token
///         survives a Gate redeploy); re-freezing `gate` to immutable is DEFERRED to pre-prod. `claude-zipcode.md` §2/§6.4.
contract SzipUSD is ERC20, Ownable {
    /// @notice The Exit Gate — the sole minter/burner (it mints 1:1 against the Loot it holds, §6.4). Timelock-settable.
    address public gate;

    error NotGate();
    error ZeroAddress();

    event GateSet(address indexed gate);

    constructor(address gate_) ERC20("Zipcode Junior Vault Share", "szipUSD") Ownable(msg.sender) {
        if (gate_ == address(0)) revert ZeroAddress();
        gate = gate_;
        emit GateSet(gate_);
    }

    /// @notice Re-point the minter/burner Gate. `onlyOwner` (Timelock), build-phase flexibility.
    function setGate(address gate_) external onlyOwner {
        if (gate_ == address(0)) revert ZeroAddress();
        gate = gate_;
        emit GateSet(gate_);
    }

    /// @notice Mint `amount` szipUSD to `to`. Gate-only (paired with the Gate's `mintLoot`).
    function mint(address to, uint256 amount) external {
        if (msg.sender != gate) revert NotGate();
        _mint(to, amount);
    }

    /// @notice Burn `amount` szipUSD from `from`. Gate-only (paired with the Gate's `burnLoot`/`ragequit`).
    function burn(address from, uint256 amount) external {
        if (msg.sender != gate) revert NotGate();
        _burn(from, amount);
    }
}
