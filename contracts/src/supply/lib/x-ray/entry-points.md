# Entry Point Map

> supply/lib (Fair Reserves) | 2 entry points | 0 permissionless | 0 admin | library (internal view)

Scope: `IchiAlgebraFairReserves`. A pure `internal view` library — no permissionless surface, no state writes, no
custody, no admin. Both functions are `internal` and linked into the consuming oracles; they are reachable only
through a consumer call.

---

## Protocol Flow Paths

### Reserve reconstruction (consumer → library → external reads)

`AlgebraIchiFairLpOracle / SzipNavOracle → IchiAlgebraFairReserves.fairReserves(vault, window)` →
   ├─ `IICHIVault(vault).pool()` → `IAlgebraPool(pool).plugin()`  ◄── `revert NoPlugin` if 0
   ├─ `_meanTick(plugin, window)` → `IAlgebraOraclePlugin.getTimepoints([window, 0])`  ◄── `revert BadTimepoints` if !len 2
   │     → `sqrtP = TickMath.getSqrtRatioAtTick(meanTick)`
   ├─ base:  `getBasePosition()` → `LiquidityAmounts.getAmountsForLiquidity(sqrtP, lower, upper, L_base)`
   ├─ limit: `getLimitPosition()` → `LiquidityAmounts.getAmountsForLiquidity(sqrtP, lower, upper, L_limit)`
   └─ idle:  `+ IERC20(token0/token1).balanceOf(vault)`
        → returns `(amount0, amount1, meanTick)`

---

## Internal (library)

### `fairReserves(address vault, uint32 window)`

| Aspect | Detail |
|--------|--------|
| Visibility | `internal view` |
| Caller | the consuming oracle (`AlgebraIchiFairLpOracle`, `SzipNavOracle` LP leg) |
| Parameters | `vault` (ICHI vault), `window` (TWAP seconds, consumer-set — 3600 deployed) |
| Reads | vault `pool`/`plugin`/positions/bounds/token0/token1/balances; plugin `getTimepoints` |
| State modified | none (view) |
| Value flow | none — returns computed amounts only |
| Reverts | `NoPlugin` (pool exposes no TWAP plugin); `BadTimepoints` (bubbled from `_meanTick`) |

### `_meanTick(address plugin, uint32 window)`

| Aspect | Detail |
|--------|--------|
| Visibility | `internal view` |
| Caller | `fairReserves` only |
| Parameters | `plugin` (Algebra oracle plugin), `window` (seconds) |
| Reads | `getTimepoints([window, 0])` → two tick-cumulatives |
| Computation | `mean = (cum[1]-cum[0]) / window`, decremented on a negative remainder (round toward −∞; UniV3 `OracleLibrary.consult` convention) |
| State modified | none (view) |
| Reverts | `BadTimepoints` if the returned set isn't length-2 |

---

## Out-of-scope but load-bearing

| Dependency | Why it matters |
|------------|----------------|
| Algebra oracle plugin | The TWAP source (`getTimepoints`). Its observation cardinality / honesty bounds the manipulation guarantee. Absent → `NoPlugin` (fail closed). |
| ConcentratedLiquidity (`TickMath`, `LiquidityAmounts`) | The vendored UniV3 tick→reserve math; correctness is upstream Uniswap's (frozen copy, faithfulness diff confirmed 2026-06-20). |
| ICHI vault | Supplies position liquidity `L` + tick bounds + idle balances; `L` only changes on mint/burn (the swap-immune input). |
