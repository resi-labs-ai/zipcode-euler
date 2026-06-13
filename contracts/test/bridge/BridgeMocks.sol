// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

/// @notice Mock of the Subtensor StakingV2 precompile (etched at 0x805 in tests) — UNIT-FAITHFUL.
/// @dev Mirrors the live runtime semantics verified against Rubicon's LiquidStakedV3 (8x-01):
///       - `addStake(hotkey, amountRao, netuid)`: amount is TAO in rao (9-dp); the TAO is swapped to
///         alpha at `priceRaoPerAlpha` (TAO-rao per 1.0 alpha; 1e9 = par) — set off-par to exercise
///         the wrapper's measured-delta + slippage paths. The real runtime debits the caller's
///         substrate-mapped native balance; an EVM mock cannot pull native from its caller, so it only
///         ASSERTS sufficiency and skips the debit. Safe because the wrapper never reads its own
///         balance on the deposit path, and redeem measures a balance DELTA (leftover deposit TAO
///         cannot skew a delta).
///       - `removeStake(hotkey, alphaRao, netuid)`: amount is alpha 9-dp; pays the caller TAO (wei) at
///         the same price.
///       - `getStake` returns alpha 9-dp. Stake is attributed to the CALLER's coldkey (keccak of
///         msg.sender), mirroring HashedAddressMapping.
///      `addReward` raises stake with no caller action — it simulates BOTH validator emissions AND a
///      third-party `transferStake` donation (identical observable effect on the wrapper). The
///      `break*` toggles exercise the S4 effect-verification negatives (silent precompile failure).
contract MockSubtensorStaking {
    uint256 internal constant RAO = 1e9;

    // stake[hotkey][coldkey][netuid] — alpha, 9-dp
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stake;
    /// @notice TAO-rao per 1.0 alpha (1e9 = par; 2e9 = 1 alpha costs 2 TAO).
    uint256 public priceRaoPerAlpha = 1e9;
    bool public breakAddStake;
    bool public breakRemoveStake;

    function _coldkeyOf(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(a));
    }

    function setPrice(uint256 raoPerAlpha) external {
        priceRaoPerAlpha = raoPerAlpha;
    }

    function setBreakAddStake(bool v) external {
        breakAddStake = v;
    }

    function setBreakRemoveStake(bool v) external {
        breakRemoveStake = v;
    }

    /// @dev `amountRao` = TAO in rao (9-dp). Swaps TAO -> alpha at the configured price.
    function addStake(bytes32 hotkey, uint256 amountRao, uint256 netuid) external payable {
        if (breakAddStake) return; // silent no-op: getStake will NOT rise -> wrapper must revert
        // The real runtime debits the caller's substrate balance; assert sufficiency only (see header).
        require(msg.sender.balance >= amountRao * RAO, "insufficient TAO");
        stake[hotkey][_coldkeyOf(msg.sender)][netuid] += amountRao * RAO / priceRaoPerAlpha;
    }

    /// @dev `alphaRao` = alpha 9-dp. Swaps alpha -> TAO at the configured price, pays the caller wei.
    function removeStake(bytes32 hotkey, uint256 alphaRao, uint256 netuid) external payable {
        if (breakRemoveStake) return; // silent no-op: getStake/balance will NOT change
        bytes32 ck = _coldkeyOf(msg.sender);
        require(stake[hotkey][ck][netuid] >= alphaRao, "insufficient stake");
        stake[hotkey][ck][netuid] -= alphaRao;
        uint256 taoOutWei = (alphaRao * priceRaoPerAlpha / RAO) * RAO; // rao -> wei
        (bool ok,) = payable(msg.sender).call{value: taoOutWei}("");
        require(ok, "pay failed");
    }

    /// @return The staked alpha in 9-dp units.
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stake[hotkey][coldkey][netuid];
    }

    /// @notice Raise backing stake with no share mint (9-dp alpha): validator rewards — or, identically
    ///         observable, a third-party `transferStake` DONATION to the wrapper's coldkey.
    function addReward(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        stake[hotkey][coldkey][netuid] += alphaRao;
    }

    /// @notice Simulate a slash (lowers backing stake; 9-dp alpha).
    function slash(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        stake[hotkey][coldkey][netuid] -= alphaRao;
    }

    receive() external payable {}
}

/// @notice Mock of the Alpha precompile (etched at 0x808) — the AMM quoting surface (IAlpha, 8x-01).
/// @dev Decimals mirror the real precompile: sims are 9-dp in/out; price getters are 18-dp. Quotes use
///      the same `priceRaoPerAlpha` convention as `MockSubtensorStaking` — etched bytecode does NOT
///      share storage, so tests must `setPrice` on BOTH mocks to keep previews and execution coherent.
contract MockAlphaPrecompile {
    uint256 internal constant RAO = 1e9;

    /// @notice TAO-rao per 1.0 alpha (1e9 = par) — keep in sync with the staking mock's price.
    uint256 public priceRaoPerAlpha = 1e9;

    function setPrice(uint256 raoPerAlpha) external {
        priceRaoPerAlpha = raoPerAlpha;
    }

    /// @return 18-dp TAO per 1.0 alpha (rao price scaled x1e9, as the runtime does).
    function getAlphaPrice(uint16) external view returns (uint256) {
        return priceRaoPerAlpha * RAO;
    }

    /// @return 18-dp TAO per 1.0 alpha (the mock's EMA equals spot).
    function getMovingAlphaPrice(uint16) external view returns (uint256) {
        return priceRaoPerAlpha * RAO;
    }

    /// @param taoRao TAO in, 9-dp. @return alpha out, 9-dp.
    function simSwapTaoForAlpha(uint16, uint64 taoRao) external view returns (uint256) {
        return uint256(taoRao) * RAO / priceRaoPerAlpha;
    }

    /// @param alphaRao alpha in, 9-dp. @return TAO out, 9-dp (rao).
    function simSwapAlphaForTao(uint16, uint64 alphaRao) external view returns (uint256) {
        return uint256(alphaRao) * priceRaoPerAlpha / RAO;
    }
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

/// @notice A 6-dp BurnMint-ish token to prove the pools' 18-dp constructor guards (works as plain
///         IERC20 for the lock/release pool too).
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
