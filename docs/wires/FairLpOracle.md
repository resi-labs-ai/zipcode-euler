# FairLpOracle — trustless on-chain ICHI-on-Algebra LP valuation (wiring map)

> **X-Ray (three scopes feed this doc):**
> - `AlgebraIchiFairLpOracle.sol` (the pricing wrapper, this doc's headline contract) — **ADEQUATE** (a hair
>   from HARDENED); pro-rata-of-TVL rounded down against the borrower, fork-proven through `getQuote` on the live
>   HYDX/USDC vault. Report: `contracts/src/supply/x-ray/AlgebraIchiFairLpOracle.md`; ELI20:
>   `docs/supply/AlgebraIchiFairLpOracle.md`.
> - `IchiAlgebraFairReserves.sol` (the TWAP-tick reserve reconstruction) — **ADEQUATE** (a hair from HARDENED);
>   keystone proven by a live-fork manipulation test (300k-USDC swap moves spot >2%, fair quote <1%). Reports:
>   `contracts/src/supply/lib/x-ray/` (`x-ray.md` + `IchiAlgebraFairReserves.md`); ELI20:
>   `docs/supply/lib/IchiAlgebraFairReserves.md`. The X-2 residual (Algebra TWAP cardinality/window) is now
>   gated: **SUPPLY-ADV-02** added a `PluginNotReady` readiness gate (`isInitialized()`) on both the ctor and the
>   read path, matching the sibling `SzipNavOracle.setLpTwapWindow:267`; and the deployed plugin's
>   **under-coverage behavior is proven fail-CLOSED** by fork test (a 10y window reverts in `getTimepoints` rather
>   than extrapolating a fake mean). The fail-closed reverts (`NoPlugin`/`PluginNotReady`/`BadTimepoints`) are now
>   regression-tested.
> - `ConcentratedLiquidity.sol` (the math foundation) — vendored UniV3 math, faithfulness DIFFED & CONFIRMED, no
>   tier/verdict by nature; review at `contracts/src/libraries/x-ray/library-review.md`, ELI20
>   `docs/libraries/concentrated-liquidity.md`. The residual it flags lands HERE, in the oracle's suite: confirm
>   only in-domain inputs reach the lib (ticks within ±MAX_TICK; `getQuoteAtTick` base ≤ uint128).

> Source of truth = the kept code (`src/supply/AlgebraIchiFairLpOracle.sol`, `src/supply/lib/IchiAlgebraFairReserves.sol`,
> `src/libraries/ConcentratedLiquidity.sol`); the manipulation-invariance proof is the fork test
> `test/AlgebraIchiFairLpOracle.t.sol`. This is the wires/ wiring map; docs are intent.

## Role

A trustless, fully on-chain fair-value oracle for an ICHI-vault LP share on an Algebra pool. Realizes the
TWAP-ring / ring-spacing defense-in-depth (price `spot` itself manipulation-resistantly) and is the trustless
alternative to `SzipFarmUtilityLpOracle`'s CRE-pushed mark. Serves **two** consumers:

- **EVK farm utility collateral** — a `BaseAdapter`/`IPriceOracle` drop-in the `EulerRouter` resolves the LP
  collateral through (`govSetConfig(lpToken, USDC, oracle)`). Proven against a live router on a Base fork.
- **NAV LP leg** — `SzipNavOracle._lpValue` reconstructs reserves via this math when `lpTwapWindow != 0`.

## Contracts (this doc)

| Contract | What it does |
|---|---|
| `src/libraries/ConcentratedLiquidity.sol` | Vendored, self-contained 0.8.24 Uniswap math: `FullMath.mulDiv`, `TickMath.getSqrtRatioAtTick`, `LiquidityAmounts.getAmounts*ForLiquidity`, `TickQuote.getQuoteAtTick`. Vendored (not remapped) so the build pulls no UniV3 pool interfaces and never reaches into `reference/`. Algebra uses identical X96 tick math. |
| `src/supply/lib/IchiAlgebraFairReserves.sol` | The keystone view: `fairReserves(vault, window) → (amt0, amt1, meanTick)`. Reconstructs each ICHI position's reserves at the pool's TWAP tick (from position `L` + bounds, both swap-immune) + idle balances (idle inclusion is deliberate — real assets; the donation seam is inert, see SUPPLY-ADV-01 WONTFIX). Fail-closed: `NoPlugin` if the pool exposes no TWAP plugin, `PluginNotReady` if the plugin is not `isInitialized()` (SUPPLY-ADV-02, read-path gate covering both consumers). |
| `src/supply/AlgebraIchiFairLpOracle.sol` | `is BaseAdapter`. `_getQuote(lpShares, lpToken, quote=token1) → quote units`, rounded DOWN. Immutable params (cheap replaceable clone); `quote` pinned to the pool's token1. Fail-closed on no-plugin / **uninitialized plugin (`PluginNotReady`, ctor gate matching `SzipNavOracle:267`)** / TWAP revert / zero supply. |

## Wiring — cross-component

- **EulerRouter → oracle.** `govSetConfig(lpToken, USDC, AlgebraIchiFairLpOracle)`. In the deploy, gated by
  `Inputs.lpTwapWindow != 0` in `DeployZipcode._phaseP5` (the `FarmUtilityMarketDeployer` `lpOracle` param);
  else the CRE-push `SzipFarmUtilityLpOracle` (the M1 default). The fair oracle is **ownerless** (immutable),
  so `_phaseP9` skips `transferOwnership` for it. It resolves immediately on a live Algebra pool (no CRE
  seed needed before `setLTV`).
- **SzipNavOracle → oracle math.** `_lpValue` calls `IchiAlgebraFairReserves.fairReserves(ichiVault,
  lpTwapWindow)` when the Timelock-settable `lpTwapWindow != 0` (set via `setLpTwapWindow`; wired in
  `_phaseP8` from the same input), else spot `getTotalAmounts()`. See `8-B4-SzipNavOracle.md`.
- **IICHIVault / IAlgebraPool / IAlgebraOraclePlugin** — the reads: vault `pool()`/`getBasePosition`/
  `getLimitPosition`/`base|limit Lower|Upper`; pool `plugin()`; plugin `getTimepoints` (cataloged in
  `interfaces-ichi.md` / `interfaces-algebra.md`).

## Deploy knob

`LP_TWAP_WINDOW` (`Inputs.lpTwapWindow`, `.env.example`): `0` = CRE-push lpOracle + spot NAV LP (M1
default, what local/anvil/fork-skeleton use); `>0` (e.g. `3600`) = trustless fair-LP for BOTH the farm utility
collateral and the NAV LP leg. Opt-in once the zipUSD/xALPHA LP is a live Algebra pool with a TWAP plugin.

## Verification

`test/AlgebraIchiFairLpOracle.t.sol` (Base fork, 16 tests): fair≈spot when calm; live TVL/holder
cross-check (debank-verifiable, m4ngos.base.eth); **manipulation invariance** (a 300k-USDC in-block swap
moves the spot split >2% while the fair quote is byte-identical); **resolves through a real `EulerRouter`**
as LP collateral; **builds a real farm utility market** via the actual `FarmUtilityMarketDeployer` (the
`lpTwapWindow != 0` P5 path) — wiring + the W3 wire-check resolve with NO CRE seed, since the fair oracle
prices live; ctor fail-closed guards (`ZeroAddress`/`ZeroWindow`/`NoPlugin`); rounds-DOWN + high-`sqrtP`
branch; and the **SUPPLY-ADV-02 readiness suite**: uninitialized plugin reverts `PluginNotReady` at ctor AND
on the read path, and an under-coverage (10y) window reverts in the live plugin's `getTimepoints` (fail-CLOSED,
settling the fail-open-vs-closed residual for the deployed plugin version).
