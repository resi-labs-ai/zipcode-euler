// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title Minimal local Subtensor precompile interfaces (8x-01).
/// @notice Authored locally (NOT imported from `reference/subtensor/precompiles/src/solidity/`)
///         for two reasons:
///           1. the reference `stakingV2.sol` does not compile under strict solc (a trailing comma
///              in `allowance(...)`), and
///           2. only the load-bearing entrypoints are pinned here (the ticket's "minimal local
///              interfaces" rule, WOOF-00 EXTENDED).
/// @dev Precompile addresses verified against `reference/subtensor/precompiles/src/` (Rust source)
///      AND against Project Rubicon's verified production `LiquidStakedV3` (`reference/rubicon/`):
///       StakingV2 = 0x...0805 (INDEX 2053), Alpha = 0x...0808 (INDEX 2056), AddressMapping = 0x...080C.
///      IMPORTANT: on Subtensor's Frontier EVM a *typed* call to these precompiles "never reaches the
///      runtime precompile" (see `reference/evm-bittensor/solidity/stakeV2.sol`). The wrapper therefore
///      invokes the state-changing entrypoints via low-level `call` with `abi.encodeWithSelector` and
///      reads the views via `staticcall`. These interfaces exist only to source the 4-byte selectors
///      and to decode return data — they are never used as a call target directly.
///
/// @dev UNIT CONVENTIONS (verified against the live 964 runtime + Rubicon's audited wrapper, 2026-06-12):
///       - The EVM native currency is TAO at 18-dp (wei). Substrate-side balances are 9-dp (rao);
///         1 TAO = 1e9 rao = 1e18 wei.
///       - Subnet alpha is 9-dp on-chain everywhere the precompiles speak it.
///       - `addStake` swaps TAO -> alpha through the subnet AMM at a VARIABLE price (never assume 1:1);
///         the alpha received is only observable as a `getStake` delta. `removeStake` swaps back.
interface IStakingV2 {
    /// @notice Stake TAO with `hotkey` on `netuid`, swapping TAO -> alpha at the subnet AMM price.
    /// @dev Call with NO attached value: the precompile debits `amount` (rao) directly from the
    ///      caller's substrate-mapped native balance. The alpha credited to the caller's coldkey is
    ///      the AMM output, NOT `amount` — measure it as a `getStake` delta.
    /// @param hotkey The validator hotkey (32-byte SS58 pubkey).
    /// @param amount TAO to stake, in rao (9-dp; `msg.value`-style wei must be divided by 1e9).
    /// @param netuid The subnet id.
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @notice Unstake alpha from `hotkey` on `netuid`, swapping alpha -> TAO at the subnet AMM price.
    /// @dev The TAO output is credited to the caller's native balance; measure it as a balance delta.
    /// @param hotkey The validator hotkey (32-byte SS58 pubkey).
    /// @param amount Alpha to unstake, in 9-dp alpha units.
    /// @param netuid The subnet id.
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;

    /// @notice The current stake attributed to (`hotkey`, `coldkey`) on `netuid`.
    /// @return The staked alpha in 9-dp units.
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);

    // NOTE (donation vector, 8x-01): StakingV2 also exposes `transferStake` / `moveStake`, which let a
    // third party attribute staked alpha to an ARBITRARY destination coldkey — including a wrapper's.
    // They are not load-bearing here (so not pinned), but their existence means "no third party can
    // raise the wrapper's backing stake" is FALSE; the wrapper's donation handling documents this.
}

/// @title Minimal Alpha precompile interface (0x...0808, INDEX 2056).
/// @notice The subnet AMM's read-only quoting surface: spot/EMA price and exact swap simulation.
///         Source: `reference/subtensor/precompiles/src/alpha.rs`; usage precedent: Rubicon
///         `LiquidStakedV3` estimators. Verified live on 964 mainnet 2026-06-12 (SN64:
///         `getAlphaPrice` = 0.0672e18; `simSwapTaoForAlpha(1 TAO)` = 14.870 alpha 9-dp).
/// @dev DECIMALS ARE INCONSISTENT ACROSS THIS PRECOMPILE — pinned per function below:
///       - the two `simSwap*` functions take and return 9-dp amounts (raw u64 math, no scaling);
///       - the two price getters return 18-dp (rao price scaled to EVM balance, x1e9).
///      `netuid` is uint16 HERE (uint256 in StakingV2) — selectors differ accordingly.
interface IAlpha {
    /// @notice Spot alpha price. 18-dp TAO per 1.0 alpha (`1e18` == 1 TAO).
    /// @dev SPOT — in-block manipulable via a large swap; fine for advisory quotes, NOT for NAV.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @notice EMA alpha price. 18-dp TAO per 1.0 alpha. Manipulation-resistant (the NAV-grade read).
    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @notice Simulate swapping `tao` (rao, 9-dp) for alpha. Fee-inclusive, size-aware AMM output.
    /// @return Alpha out, 9-dp.
    function simSwapTaoForAlpha(uint16 netuid, uint64 tao) external view returns (uint256);

    /// @notice Simulate swapping `alpha` (9-dp) for TAO. Fee-inclusive, size-aware AMM output.
    /// @return TAO out, in rao (9-dp).
    function simSwapAlphaForTao(uint16 netuid, uint64 alpha) external view returns (uint256);
}

interface IAddressMapping {
    /// @notice Converts an EVM H160 address to its Substrate AccountId32 (H256) coldkey.
    function addressMapping(address targetAddress) external view returns (bytes32);
}
