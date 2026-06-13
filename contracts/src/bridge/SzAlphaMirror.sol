// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

/// @title SzAlphaMirror — the Base (8453) bridged mirror of szALPHA.
/// @notice A PLAIN canonical `BurnMintERC20` (18-dp): mint/burn gated to the Base CCT pool (via
///         `grantMintAndBurnRoles`), with ZERO staking / redeem / precompile / `IXAlphaRate` surface.
///         Base has no Subtensor precompiles, so the native stake/unstake leg exists ONLY on 964
///         (`SzAlpha`). A separate contract (not an init flag) keeps dead precompile code off Base and
///         shrinks the Base audit surface.
/// @dev This is a bridged mirror with NO native backing on Base — its supply is conserved 1:1 against the
///      szALPHA LOCKED in the 964 `SzAlphaLockReleasePool`'s lockbox (the lane is lock/release on 964,
///      burn/mint here; locked 964 supply keeps counting in `SzAlpha.totalSupply()`, so the rate stays
///      truthful — see SzAlphaLockReleasePool). All value accrual (validator rewards) happens on 964 and
///      is reflected via `SzAlpha.exchangeRate()`; the mirror is a pure transport token.
/// @dev `maxSupply = 0` (unlimited — the cross-chain supply is bounded by the 964 lock/release custody,
///      not here); `preMint = 0` (no genesis supply on Base). `DEFAULT_ADMIN_ROLE` + `ccipAdmin` are the
///      deployer at construction; the deploy script hands both to the timelock/multisig and revokes the
///      deployer.
contract SzAlphaMirror is BurnMintERC20 {
    constructor(string memory name_, string memory symbol_) BurnMintERC20(name_, symbol_, 18, 0, 0) {}
}
