// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title Minimal local Subtensor precompile interfaces (8x-01).
/// @notice Authored locally (NOT imported from `reference/subtensor/precompiles/src/solidity/`)
///         for two reasons:
///           1. the reference `stakingV2.sol` does not compile under strict solc (a trailing comma
///              in `allowance(...)`), and
///           2. only `addStake` / `removeStake` / `getStake` / `addressMapping` are load-bearing here
///              (the ticket's "minimal local interfaces" rule, WOOF-00 EXTENDED).
/// @dev Precompile addresses verified against `reference/subtensor/precompiles/src/solidity/`:
///       StakingV2 = 0x...0805, AddressMapping = 0x...080C.
///      IMPORTANT: on Subtensor's Frontier EVM a *typed* call to these precompiles "never reaches the
///      runtime precompile" (see `reference/evm-bittensor/solidity/stakeV2.sol`). The wrapper therefore
///      invokes the state-changing entrypoints via low-level `call` with `abi.encodeWithSelector` and
///      reads `getStake` / `addressMapping` via `staticcall`. These interfaces exist only to source the
///      4-byte selectors and to decode return data — they are never used as a call target directly.
interface IStakingV2 {
    /// @param hotkey The validator hotkey (32-byte SS58 pubkey).
    /// @param amount The amount to stake (rao).
    /// @param netuid The subnet id.
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @param hotkey The validator hotkey (32-byte SS58 pubkey).
    /// @param amount The amount to unstake (alpha).
    /// @param netuid The subnet id.
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @notice The current stake (alpha) attributed to (`hotkey`, `coldkey`) on `netuid`.
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);
}

interface IAddressMapping {
    /// @notice Converts an EVM H160 address to its Substrate AccountId32 (H256) coldkey.
    function addressMapping(address targetAddress) external view returns (bytes32);
}
