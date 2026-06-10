# interfaces-algebra — Algebra Integral / Hydrex shims (catalog)

> Source of truth = the kept code under `contracts/src/interfaces/algebra/`. This doc reads the four
> shims as the final form, pins each to its live Base deployment, and records the declared surface +
> the Algebra-not-UniV3 gotchas. Address book = `contracts/script/BaseAddresses.sol`.

## Role
Minimal **interface + fork** shims (per WOOF-00 Strategy A: interfaced, never compiled from source) for
the **Algebra Integral** AMM that **Hydrex** (Lynex/Algebra fork) runs on Base 8453. Each shim declares
only the methods/structs we call against the live deployment. The single live consumer today is
`SellModule` (8-B9 market-sell) → `ISwapRouter`; the other three are present for the LP/pool path
(NFPM mint/positions, pool `globalState`/`swap`, factory `poolByPair` lookup).

Hard distinction baked into every shim: **Algebra Integral, NOT Uniswap V3** — params carry a
`deployer` field (custom-pool plugin deployer) and `limitSqrtPrice` (not `sqrtPriceLimitX96`), and
**no `fee` field** (Algebra is fee-by-pair, set in the pool's `globalState`, not a per-call tier).
For the **base-factory** HYDX/USDC pool, `deployer == address(0)`.

## Live external pins (BaseAddresses.sol, on-chain-verified 2026-06-06)
| Constant | Address | Shimmed by |
|---|---|---|
| `ALGEBRA_SWAP_ROUTER` | `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e` | `ISwapRouter` |
| `ALGEBRA_NFPM` | `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86` | `INonfungiblePositionManager` |
| `HYDX_USDC_POOL` | `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2` | `IAlgebraPool` |
| Algebra factory | `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E` | `IAlgebraFactory` |

Factory has **no named constant** — it is `router.factory()` == `HYDX_USDC_POOL.factory()`, recorded
in `BaseAddresses.sol` comments only.

---

## `ISwapRouter.sol` — Algebra Integral `SwapRouter`
- **Shims:** deployed Algebra `SwapRouter` @ `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`.
- **Surface:**
  - `struct ExactInputSingleParams { address tokenIn; address tokenOut; address deployer; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 limitSqrtPrice; }`
  - `function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256 amountOut);`
- **Consumed by:** `contracts/src/supply/szipUSD/SellModule.sol` (the only live consumer; imports
  `ISwapRouter`, builds `ExactInputSingleParams`, calls `exactInputSingle` via the approve → swap →
  reset-approve 3-`exec` dance).
- **Gotchas:** `exactInputSingle` selector = **0x1679c792** (8-field Algebra Integral struct). The
  alternates are ABSENT in bytecode: `0xbc651188` (Algebra-classic, no deployer), `0x04e45aaf` (UniV3
  with `fee`). Callback is `algebraSwapCallback(int256,int256,bytes)` = `0x2c8958f6`. **No `fee` field;
  `deployer` + `limitSqrtPrice` instead.** Base-factory HYDX/USDC pool ⇒ pass `deployer == address(0)`.
  Field ORDER is the canonical Algebra Integral periphery ordering, pinned by a green real-swap fork
  test — wrong order misroutes output / reverts.

## `INonfungiblePositionManager.sol` — Algebra Integral NFPM
- **Shims:** NFPM @ `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86`.
- **Surface:**
  - `struct MintParams { address token0; address token1; address deployer; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }`
  - `struct IncreaseLiquidityParams { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }`
  - `struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }`
  - `struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }`
  - `function mint(MintParams) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);`
  - `function increaseLiquidity(IncreaseLiquidityParams) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);`
  - `function decreaseLiquidity(DecreaseLiquidityParams) external payable returns (uint256 amount0, uint256 amount1);`
  - `function collect(CollectParams) external payable returns (uint256 amount0, uint256 amount1);`
  - `function burn(uint256 tokenId) external payable;`
  - `function positions(uint256 tokenId) external view returns (uint88 nonce, address operator, address token0, address token1, address deployer, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1);`
- **Consumed by:** none in `contracts/src` / `contracts/script` yet (present for the LP path).
- **Gotchas:** `mint(MintParams)` selector = **0xfe3f3be7** (the 3-leading-address struct including
  `deployer`); the guessed UniV3 10-field struct `0x9cc1a283` is ABSENT — Algebra **omits `fee`, ADDS
  `address deployer`** (3rd field). `positions` = `0x99fbab88`, return tuple is **12 fields** (includes
  `deployer`), confirmed against live tokenId 1013. `increaseLiquidity 0x219f5d17`,
  `decreaseLiquidity 0x0c49ccbe`, `collect 0xfc6f7865`, `burn 0x42966c68` — unchanged vs UniV3.

## `IAlgebraPool.sol` — Algebra Integral pool
- **Shims:** HYDX/USDC pool @ `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`.
- **Surface:**
  - `function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data) external returns (int256 amount0, int256 amount1);`
  - `function globalState() external view returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked);`
  - `function token0() external view returns (address);`
  - `function token1() external view returns (address);`
- **Consumed by:** none in `contracts/src` / `contracts/script` yet.
- **Gotchas:** `swap(address,bool,int256,uint160,bytes)` = `0x128acb08`; **`globalState()`** =
  `0xe76c01e4` is the UniV3 `slot0` analogue — Algebra packs `(price, tick, lastFee, pluginConfig,
  communityFee, unlocked)`, so **fee lives here (`lastFee`), not on a per-call tier**. For pool 0x51f0…,
  `token0() == HYDX`, `token1() == USDC`.

## `IAlgebraFactory.sol` — Algebra Integral factory
- **Shims:** factory @ `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E` (`= pool.factory() = router.factory()`).
- **Surface:** `function poolByPair(address tokenA, address tokenB) external view returns (address pool);`
- **Consumed by:** none in `contracts/src` / `contracts/script` yet.
- **Gotchas:** **fee-by-pair, no fee-tier arg** — `poolByPair(HYDX, USDC)` returns the single canonical
  pool `0x51f0…D3D2` (verified). Base-factory pools (this one) ⇒ `deployer == address(0)` everywhere
  the periphery structs above take a `deployer`.
