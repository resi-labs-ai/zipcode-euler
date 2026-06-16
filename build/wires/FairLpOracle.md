# FairLpOracle — trustless on-chain ICHI-on-Algebra LP valuation (wiring map)

> Full design + on-chain validation: **`build/fair-lp.md`** (the spec). This is the wires/ wiring map.
> Source of truth = the kept code; docs are intent.

## Role

A trustless, fully on-chain fair-value oracle for an ICHI-vault LP share on an Algebra pool. Realizes the
TWAP-ring / ring-spacing defense-in-depth (price `spot` itself manipulation-resistantly) and is the trustless
alternative to `SzipReservoirLpOracle`'s CRE-pushed mark. Serves **two** consumers:

- **EVK reservoir collateral** — a `BaseAdapter`/`IPriceOracle` drop-in the `EulerRouter` resolves the LP
  collateral through (`govSetConfig(lpToken, USDC, oracle)`). Proven against a live router on a Base fork.
- **NAV LP leg** — `SzipNavOracle._lpValue` reconstructs reserves via this math when `lpTwapWindow != 0`.

## Contracts (this doc)

| Contract | What it does |
|---|---|
| `src/libraries/ConcentratedLiquidity.sol` | Vendored, self-contained 0.8.24 Uniswap math: `FullMath.mulDiv`, `TickMath.getSqrtRatioAtTick`, `LiquidityAmounts.getAmounts*ForLiquidity`, `TickQuote.getQuoteAtTick`. Vendored (not remapped) so the build pulls no UniV3 pool interfaces and never reaches into `reference/`. Algebra uses identical X96 tick math. |
| `src/supply/lib/IchiAlgebraFairReserves.sol` | The keystone view: `fairReserves(vault, window) → (amt0, amt1, meanTick)`. Reconstructs each ICHI position's reserves at the pool's TWAP tick (from position `L` + bounds, both swap-immune) + idle balances. Fail-closed `NoPlugin` if the pool exposes no TWAP plugin. |
| `src/supply/AlgebraIchiFairLpOracle.sol` | `is BaseAdapter`. `_getQuote(lpShares, lpToken, quote=token1) → quote units`, rounded DOWN. Immutable params (cheap replaceable clone); `quote` pinned to the pool's token1. Fail-closed on no-plugin / TWAP revert / zero supply. |

## Wiring — cross-component

- **EulerRouter → oracle.** `govSetConfig(lpToken, USDC, AlgebraIchiFairLpOracle)`. In the deploy, gated by
  `Inputs.lpTwapWindow != 0` in `DeployZipcode._phaseP5` (the `ReservoirMarketDeployer` `lpOracle` param);
  else the CRE-push `SzipReservoirLpOracle` (the M1 default). The fair oracle is **ownerless** (immutable),
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
default, what local/anvil/fork-skeleton use); `>0` (e.g. `3600`) = trustless fair-LP for BOTH the reservoir
collateral and the NAV LP leg. Opt-in once the zipUSD/xALPHA LP is a live Algebra pool with a TWAP plugin.

## Verification

`test/AlgebraIchiFairLpOracle.t.sol` (Base fork, 5 tests): fair≈spot when calm; live TVL/holder
cross-check (debank-verifiable, m4ngos.base.eth); **manipulation invariance** (a 300k-USDC in-block swap
moves the spot split >2% while the fair quote is byte-identical); **resolves through a real `EulerRouter`**
as LP collateral; and **builds a real reservoir market** via the actual `ReservoirMarketDeployer` (the
`lpTwapWindow != 0` P5 path) — wiring + the W3 wire-check resolve with NO CRE seed, since the fair oracle
prices live.
