// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

/// @notice Mock of the Subtensor StakingV2 precompile (etched at 0x805 in tests).
/// @dev Stake is attributed to the CALLER's coldkey (keccak of msg.sender), mirroring the real precompile's
///      HashedAddressMapping; `addReward`/`slash` simulate validator emissions / slashing. The `break*`
///      toggles let the S4 effect-verification negatives be exercised (silent precompile failure).
contract MockSubtensorStaking {
    // stake[hotkey][coldkey][netuid]
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stake;
    bool public breakAddStake;
    bool public breakRemoveStake;

    function _coldkeyOf(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(a));
    }

    function setBreakAddStake(bool v) external {
        breakAddStake = v;
    }

    function setBreakRemoveStake(bool v) external {
        breakRemoveStake = v;
    }

    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        if (breakAddStake) return; // silent no-op: getStake will NOT rise -> wrapper must revert
        stake[hotkey][_coldkeyOf(msg.sender)][netuid] += amount;
    }

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        if (breakRemoveStake) return; // silent no-op: getStake/balance will NOT change
        bytes32 ck = _coldkeyOf(msg.sender);
        require(stake[hotkey][ck][netuid] >= amount, "insufficient stake");
        stake[hotkey][ck][netuid] -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "pay failed");
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stake[hotkey][coldkey][netuid];
    }

    /// @notice Simulate validator rewards (raises backing stake with no share mint).
    function addReward(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amt) external {
        stake[hotkey][coldkey][netuid] += amt;
    }

    /// @notice Simulate a slash (lowers backing stake).
    function slash(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amt) external {
        stake[hotkey][coldkey][netuid] -= amt;
    }

    receive() external payable {}
}

/// @notice Mock of the AddressMapping precompile (etched at 0x80C).
contract MockAddressMapping {
    bool public flipped;

    function setFlipped(bool v) external {
        flipped = v;
    }

    function addressMapping(address target) external view returns (bytes32) {
        // After `flipped`, return a DIFFERENT value to prove the wrapper cached its coldkey at init (S5).
        return flipped ? keccak256(abi.encode(target, "flipped")) : keccak256(abi.encode(target));
    }
}

/// @notice Mock CCIP Router exposing only getOnRamp/isOffRamp (the pool's ramp gating).
contract MockRouter {
    mapping(uint64 => address) public onRamp;
    mapping(uint64 => mapping(address => bool)) public offRamp;

    function setOnRamp(uint64 sel, address r) external {
        onRamp[sel] = r;
    }

    function setOffRamp(uint64 sel, address r, bool ok) external {
        offRamp[sel][r] = ok;
    }

    function getOnRamp(uint64 sel) external view returns (address) {
        return onRamp[sel];
    }

    function isOffRamp(uint64 sel, address r) external view returns (bool) {
        return offRamp[sel][r];
    }
}

/// @notice Mock RMN (ARMProxy) exposing isCursed (the pool's curse gate).
contract MockRMN {
    bool public cursed;

    function setCursed(bool v) external {
        cursed = v;
    }

    function isCursed() external view returns (bool) {
        return cursed;
    }

    function isCursed(bytes16) external view returns (bool) {
        return cursed;
    }
}

/// @notice A 6-dp BurnMint-ish token to prove the pool's 18-dp constructor guard.
contract Mock6DecimalToken is IBurnMintERC20 {
    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address, uint256) external {}
    function burn(uint256) external {}
    function burn(address, uint256) external {}
    function burnFrom(address, uint256) external {}

    // IERC20 surface (unused).
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}
