// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IICHIVault} from "../../interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../../interfaces/algebra/IAlgebraPool.sol";
import {IAlgebraOraclePlugin} from "../../interfaces/algebra/IAlgebraOraclePlugin.sol";
import {TickMath, LiquidityAmounts} from "../../libraries/ConcentratedLiquidity.sol";

/// @title IchiAlgebraFairReserves
/// @notice Manipulation-resistant reserve reconstruction for an ICHI vault on an Algebra pool. The keystone the
///         fair-LP oracle (and the NAV oracle's LP leg) read instead of `IICHIVault.getTotalAmounts()`.
///
/// @dev WHY: `getTotalAmounts()` returns each ICHI position's token split computed at the pool's CURRENT tick, plus
///      idle balances. A swap moves the current tick, so the split is in-block manipulable — valuing it at fixed
///      prices moves with the manipulation. This library instead reconstructs each position's
///      reserves at the pool's TWAP tick using the position's liquidity `L` and its tick bounds — BOTH immune to
///      in-block swaps (`L` changes only on the vault's mint/burn; the TWAP tick is a time-average). Idle vault
///      balances are added as-is (they are token amounts, not price-sensitive in composition).
///
///      Validated on-chain against HYDX/USDC vault 0xfF8B…73f7 (pool 0x51f0…D3D2): the TWAP
///      reconstruction reproduces `getTotalAmounts()` while unmanipulated, and `base0 + limit0 + idle0` matched
///      `getTotalAmounts0()` to the wei.
library IchiAlgebraFairReserves {
    /// @notice The Algebra pool has no plugin / TWAP source — fail closed (no manipulation-resistant price).
    error NoPlugin();
    /// @notice The plugin exists but is not initialized — a fresh plugin reverts/returns garbage on a TWAP read,
    ///         so fail closed rather than price off an uninitialized timepoint array (matches the sibling
    ///         `SzipNavOracle.setLpTwapWindow` gate on the identical plugin).
    error PluginNotReady();
    /// @notice The plugin returned an unusable timepoint set.
    error BadTimepoints();
    /// @notice The plugin is live but its recorded history is shorter than the requested TWAP window — a
    ///         replaced/reset plugin (Hydrex controls the pool's plugin pointer) restarts with EMPTY history and
    ///         re-accumulates it passively. Carries WHICH plugin and WHEN the window is covered, so halted callers
    ///         surface "plugin X was replaced; TWAP resumes at readyAt" instead of an opaque plugin revert.
    ///         Self-healing by construction: no pause state, no unpause act — the same read passes once
    ///         `block.timestamp >= readyAt`. Halt-over-degrade is deliberate: shortening the average (or falling
    ///         to spot) right after a publicly-visible plugin swap is exactly the manipulation window the 1h TWAP
    ///         exists to price out — an attacker must otherwise hold a displaced price against arbitrage for a
    ///         large fraction of the window, bleeding capital to the (vault-owned) counter-side.
    error LpTwapHistoryTooShort(address plugin, uint256 readyAt);

    /// @notice Reconstruct the vault's `(amount0, amount1)` at the `window`-second TWAP tick (fair, manipulation-
    ///         resistant), and return that mean tick. Reverts `NoPlugin` if the pool exposes no TWAP plugin.
    /// @param vault  The ICHI vault.
    /// @param window The TWAP averaging window in seconds (e.g. 3600 for 1h).
    function fairReserves(address vault, uint32 window)
        internal
        view
        returns (uint256 amount0, uint256 amount1, int24 meanTick)
    {
        address pool = IICHIVault(vault).pool();
        address plugin = IAlgebraPool(pool).plugin();
        if (plugin == address(0)) revert NoPlugin();
        // Read-time readiness gate: a non-zero but UNINITIALIZED plugin would return a
        // well-formed length-2 set encoding a near-spot/frozen "TWAP". Fail closed here so BOTH consumers
        // (this oracle + SzipNavOracle's LP leg) are covered at read-time, not only at deploy/set-time.
        if (!IAlgebraOraclePlugin(plugin).isInitialized()) revert PluginNotReady();

        // History-depth gate: the populated span IS on-chain-queryable via the ring buffer's oldest slot
        // (`timepointIndex()`/`timepoints(i)`, pinned live by fork test + InterfaceSelectorDrift), so under-coverage
        // fails closed HERE with a typed, self-describing error rather than deep inside `getTimepoints`. The
        // `getTimepoints` revert on a predating request remains as defense-in-depth behind this gate.
        {
            // scoped: keeps the reserve-reconstruction frame below the stack limit
            uint256 readyAt = uint256(_oldestTimestamp(plugin)) + window;
            if (block.timestamp < readyAt) revert LpTwapHistoryTooShort(plugin, readyAt);
        }

        meanTick = _meanTick(plugin, window);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);

        // base position
        (uint128 lBase,,) = IICHIVault(vault).getBasePosition();
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).baseLower()),
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).baseUpper()),
            lBase
        );
        amount0 = a0;
        amount1 = a1;

        // limit position
        (uint128 lLimit,,) = IICHIVault(vault).getLimitPosition();
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).limitLower()),
            TickMath.getSqrtRatioAtTick(IICHIVault(vault).limitUpper()),
            lLimit
        );
        amount0 += a0;
        amount1 += a1;

        // idle vault balances (held outside the AMM positions) — composition not price-sensitive
        amount0 += IERC20(IICHIVault(vault).token0()).balanceOf(vault);
        amount1 += IERC20(IICHIVault(vault).token1()).balanceOf(vault);
    }

    /// @notice Non-reverting status probe of the history-depth gate — the "is the TWAP halted, and until when"
    ///         surface CRE (`cre/buyburn-bid`) and front-ends poll instead of decoding reverts. `ready == false`
    ///         means `fairReserves`-based reads currently revert: `LpTwapHistoryTooShort(plugin, readyAt)` when a
    ///         replaced plugin is still re-accumulating (resumes unaided at `readyAt`), or `NoPlugin`/
    ///         `PluginNotReady` when `readyAt == 0` (no ETA — the pool has no initialized plugin at all).
    function historyStatus(address vault, uint32 window)
        internal
        view
        returns (bool ready, address plugin, uint256 readyAt)
    {
        address pool = IICHIVault(vault).pool();
        plugin = IAlgebraPool(pool).plugin();
        if (plugin == address(0) || !IAlgebraOraclePlugin(plugin).isInitialized()) return (false, plugin, 0);
        readyAt = uint256(_oldestTimestamp(plugin)) + window;
        ready = block.timestamp >= readyAt;
    }

    /// @dev The timestamp of the plugin's OLDEST stored timepoint. The 65536-slot ring buffer is written in order:
    ///      before wrap the oldest is slot 0; after wrap it is the slot just ahead of the write head
    ///      (`timepointIndex + 1`, uint16-wrapping) — that slot's `initialized` flag IS the wrapped test.
    function _oldestTimestamp(address plugin) private view returns (uint32 ts) {
        uint16 head = IAlgebraOraclePlugin(plugin).timepointIndex();
        uint16 next;
        unchecked {
            next = head + 1; // ring arithmetic: 65535 + 1 wraps to 0 on purpose
        }
        (bool wrapped, uint32 nextTs,,,,,) = IAlgebraOraclePlugin(plugin).timepoints(next);
        if (wrapped) return nextTs;
        (, ts,,,,,) = IAlgebraOraclePlugin(plugin).timepoints(0);
    }

    /// @notice The arithmetic-mean tick over `[now - window, now]` from the Algebra plugin, rounded toward negative
    ///         infinity on a negative remainder (the UniV3/`OracleLibrary.consult` convention).
    function _meanTick(address plugin, uint32 window) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window; // older
        secondsAgos[1] = 0; // now
        (int56[] memory cum,) = IAlgebraOraclePlugin(plugin).getTimepoints(secondsAgos);
        if (cum.length != 2) revert BadTimepoints();

        int56 delta = cum[1] - cum[0]; // tickCumulative(now) - tickCumulative(window ago)
        int56 w = int56(uint56(window));
        int56 mean = delta / w;
        if (delta < 0 && (delta % w != 0)) mean--;
        return int24(mean);
    }
}
