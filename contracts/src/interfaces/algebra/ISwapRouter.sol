// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title ISwapRouter (Algebra Integral)
/// @notice The minimal Algebra Integral `SwapRouter` surface the 8-B9 SellModule calls — only `exactInputSingle`.
/// @dev [EXT] Source: deployed Algebra `SwapRouter` @ Base 8453 0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e.
///      On-chain-verified this window: `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))`
///      = selector 0x1679c792 (FOUND as a PUSH4 in the deployed bytecode); `algebraSwapCallback(int256,int256,bytes)`
///      = 0x2c8958f6 (FOUND) → Algebra Integral (NOT Uniswap V3): the params carry NO `fee` field, a `deployer`
///      field, and `limitSqrtPrice` (not `sqrtPriceLimitX96`). The two non-Algebra candidates are ABSENT
///      (0xbc651188 Algebra-classic-no-deployer, 0x04e45aaf UniV3-with-fee). The struct field ORDER is the canonical
///      Algebra Integral periphery ordering — pinned by the green real-swap fork test (a wrong order sends the output
///      to the wrong recipient / reverts).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address deployer; // Algebra Integral custom-pool deployer; address(0) for base-factory pools
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
