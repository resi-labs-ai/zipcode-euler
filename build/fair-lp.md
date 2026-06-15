# Fair-LP oracle — trustless on-chain ICHI-on-Algebra LP valuation

## STATUS — BUILT 2026-06-14 (fork-proven against the live HYDX/USDC vault)

A trustless, fully on-chain fair-value oracle for an ICHI-vault LP share on an Algebra pool. Realizes the
`twap-ring.md` defense-in-depth (price `spot` itself so a sustained move can't drag NAV) and is the
trustless alternative to `SzipReservoirLpOracle`'s CRE-pushed mark.

## Problem

`getTotalAmounts()` returns each ICHI position's token split computed at the pool's **current tick**, plus
idle balances. The current tick is in-block manipulable (a swap moves it), so valuing the split at fixed
prices moves with the manipulation. `SzipNavOracle._lpValue` read exactly this; `twap-ring.md`'s ring fix
only restored the single-block bracket — a sustained move still dragged the mark.

## Method (manipulation-resistant)

Reconstruct each position's reserves at the pool's **TWAP tick** from the position's liquidity `L` + tick
bounds — both immune to in-block swaps (`L` changes only on the vault's mint/burn; the TWAP tick is a
time-average). Value at oracle prices, add idle balances, pro-rate by LP-share fraction.

```
meanTick = Algebra plugin getTimepoints([window,0]) → arithmetic-mean tick (round toward −∞)
(amt0,amt1)_i = LiquidityAmounts.getAmountsForLiquidity(sqrt(meanTick), sqrt(lower_i), sqrt(upper_i), L_i)
fair0 = Σ amt0_i + token0.balanceOf(vault);  fair1 = Σ amt1_i + token1.balanceOf(vault)
TVL_quote = fair1 + value(fair0 in token1 @ meanTick);  perShare = TVL_quote × shares / totalSupply
```

`getTotalAmounts0 = base0 + limit0 + idle0` was confirmed on-chain to the wei; the TWAP reconstruction
reproduces it when the pool is calm.

## Files

- `contracts/src/libraries/ConcentratedLiquidity.sol` — vendored, self-contained 0.8.24 copies of Uniswap
  `FullMath.mulDiv`, `TickMath.getSqrtRatioAtTick`, `LiquidityAmounts.getAmounts*ForLiquidity`, `getQuoteAtTick`
  (vendored, not remapped — no `reference/` reach at build time, no UniV3 pool-interface imports). Algebra
  uses identical X96 tick math.
- `contracts/src/supply/lib/IchiAlgebraFairReserves.sol` — the keystone: `fairReserves(vault, window) →
  (amt0, amt1, meanTick)`. Reads `getBasePosition`/`getLimitPosition` (liquidity), `baseLower/Upper`,
  `limitLower/Upper`, idle balances, and the Algebra plugin TWAP. Fail-closed: `NoPlugin` if the pool has no
  TWAP plugin.
- `contracts/src/supply/AlgebraIchiFairLpOracle.sol` — `BaseAdapter`/`IPriceOracle`. `_getQuote(lpShares,
  lpToken, quote=token1) → quote units`, rounded DOWN. Immutable params (cheap replaceable clone). The
  drop-in trustless collateral oracle for the EVK router.
- `contracts/src/interfaces/algebra/IAlgebraOraclePlugin.sol` — `getTimepoints` (TWAP). `IAlgebraPool` gains
  `plugin()`; `IICHIVault` gains `pool()`/`getBasePosition`/`getLimitPosition`/`base|limit Lower|Upper`.
- `contracts/src/supply/SzipNavOracle.sol` — `_lpValue` sources reserves from `fairReserves` when the new
  Timelock-settable `lpTwapWindow` is non-zero, else spot `getTotalAmounts()` (the M1 / non-Algebra default,
  unchanged). Leg pricing (`_tokenValue`) and pro-rata are identical either way.

## Verification (fork-proven)

`contracts/test/AlgebraIchiFairLpOracle.t.sol` — Base fork (pinned `ForkConfig.BASE_FORK_BLOCK`), **3/3 green**:

1. `fairReserves ≈ getTotalAmounts` when calm (within 1%).
2. **TVL $432,028, USDC 69.07%, m4ngos.base.eth holding $3,389.99** (pro-rata of TVL). At latest block these
   read ~$398.5k / 69.7% / ~$3,507 — cross-checkable on debank (m4ngos.base.eth). Live HYDX TWAP ≈ $0.0317.
3. **Manipulation invariance** — a 300k-USDC in-block swap moved the spot reserve split >2%, yet the oracle's
   fair quote was **byte-identical before and after** (`149353105.110753` USDC/share). This is the property
   the whole exercise proves.

Full suite: **755 passed / 0 failed / 3 skipped** (no regression; `lpTwapWindow==0` default preserves every
existing path).

## Integration — BUILT (both consumers), flag-gated

Single deploy knob `LP_TWAP_WINDOW` (`Inputs.lpTwapWindow`); `0` = M1 default (CRE-push lpOracle + spot NAV
LP leg, what local/anvil use), `>0` = trustless fair-LP for BOTH consumers. Opt-in once the zipUSD/xALPHA LP
is a live Algebra pool with a TWAP plugin.

- **NAV LP leg** — `DeployZipcode._phaseP8` calls `navOracle.setLpTwapWindow(lpTwapWindow)`; `_lpValue`
  reconstructs at the TWAP tick. Done.
- **Reservoir collateral oracle** — `_phaseP5` deploys `AlgebraIchiFairLpOracle` as the
  `ReservoirMarketDeployer` `lpOracle` when the flag is set, else the CRE-push `SzipReservoirLpOracle`
  (kept as the M1/fallback; co-exist, not deleted). The fair oracle is ownerless so `_phaseP9` skips its
  `transferOwnership`. Proven: `test_fork_reservoir_market_builds_with_fair_oracle` runs the real deployer
  with the fair oracle — the market wires + W3-resolves with no CRE seed.
