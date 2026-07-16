// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../src/libraries/ConcentratedLiquidity.sol";

/// @dev Minimal read of Algebra Integral's `globalState` (sqrtPrice + tick).
interface IAlgebraGlobalState {
    function globalState() external view returns (uint160 price, int24 tick, uint16, uint8, uint16, bool);
}

/// @notice Resolves the one runnable residual in `src/libraries/x-ray/library-review.md`: the cross-protocol
///         assumption that Algebra Integral uses the IDENTICAL Q64.96 X96 sqrt-price/tick encoding as UniV3
///         `TickMath` (so the vendored math is correct for the Algebra HYDX/USDC pool that feeds NAV). Confirms
///         it against the LIVE pool: the live `globalState` sqrtPrice must sit in
///         `[getSqrtRatioAtTick(tick), getSqrtRatioAtTick(tick+1))` — the defining property of the encoding.
///         Run: `forge test --match-path 'test/libraries/*' --fork-url base`.
contract AlgebraTickMathLiveTest is Test {
    address internal constant POOL = 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2; // Algebra HYDX/USDC (token0=HYDX)

    function test_algebra_sqrtPrice_matches_vendored_TickMath() public {
        vm.createSelectFork(vm.rpcUrl("base"));
        (uint160 price, int24 tick,,,,) = IAlgebraGlobalState(POOL).globalState();
        assertGt(price, 0, "pool unreadable / sqrtPrice 0");

        uint160 lo = TickMath.getSqrtRatioAtTick(tick);
        uint160 hi = TickMath.getSqrtRatioAtTick(tick + 1);
        // The defining invariant: the current tick is the floor of the live sqrtPrice in UniV3 X96 encoding.
        assertGe(price, lo, "live sqrtPrice < TickMath(tick) -- Algebra encoding diverges from UniV3");
        assertLt(price, hi, "live sqrtPrice >= TickMath(tick+1) -- Algebra encoding diverges from UniV3");
    }
}
