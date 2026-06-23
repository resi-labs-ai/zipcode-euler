# Library Review — `contracts/src/libraries`

> ConcentratedLiquidity.sol | 189 lines, 4 libraries | vendored Uniswap-V3 math | solc 0.8.24 | `main` | 20/06/26

The libraries-scoped equivalent of an X-Ray. Pure math libraries have no state, entry points, access control, or invariants — the standard report does not apply. For *vendored* math the audit question is narrow and specific: **is this a faithful copy of upstream, and is the port to Solidity 0.8.x correct?** This maps that.

## What's here

One file, four `internal pure` math libraries — a minimal, self-contained vendoring of Uniswap-V3 concentrated-liquidity math, copied (per the header) from v3-core / v3-periphery (the same sources under `reference/euler-price-oracle/lib/v3-core|v3-periphery`), pinned to 0.8.24 so the prod build never reaches into `reference/` or pulls in UniV3 pool interfaces.

| Library | Functions | Upstream | Header claim |
|---------|-----------|----------|--------------|
| `FullMath` | `mulDiv`, `mulDivRoundingUp` | v3-core FullMath (MIT, Remco Bloemen) | **assembly-exact, byte-for-byte** |
| `TickMath` | `getSqrtRatioAtTick` + MIN/MAX consts | v3-core TickMath (GPL-2.0) | **assembly-exact, byte-for-byte** |
| `LiquidityAmounts` | `getAmount0/1ForLiquidity`, `getAmountsForLiquidity` | v3-periphery (GPL-2.0) | transcribed verbatim (not assembly-exact) |
| `TickQuote` | `getQuoteAtTick` | v3-periphery OracleLibrary (GPL-2.0) | transcribed verbatim |

## Consumed by (grep-verified, src)

- `supply/AlgebraIchiFairLpOracle.sol` — uses `FullMath`, `TickMath`, `ConcentratedLiquidity`
- `supply/lib/IchiAlgebraFairReserves.sol` — uses `TickMath`, `LiquidityAmounts`, `ConcentratedLiquidity`
- Test: `test/AlgebraIchiFairLpOracle.t.sol` (exercises the math **indirectly** via the oracle)

This file is the math foundation of the **fair-LP oracle** — the donation-/manipulation-resistant pricing of the ICHI/Algebra LP. Its correctness flows straight into NAV.

## The real audit points

- **Faithfulness — DIFFED 2026-06-20: CONFIRMED, no logic divergence.** Compared all four libraries against the cited upstream (`reference/euler-price-oracle/lib/v3-core|v3-periphery`): `FullMath.mulDiv` assembly ops match in order; `TickMath` all 20 magic constants + bounds + final rounding identical; `LiquidityAmounts` `getAmount0/1ForLiquidity` formulas and the 3-branch `getAmountsForLiquidity` identical; `TickQuote.getQuoteAtTick` identical to upstream `OracleLibrary` (both branches). Only deltas are value-preserving cosmetics (`FixedPoint96.Q96` → local `Q96 = 0x1000000000000000000000000` = 2^96, confirmed; `RESOLUTION = 96`) and unused functions omitted (`getTickAtSqrtRatio`, `getLiquidityForAmount*`). No transcription bug in the two transcribed libraries. *Caveat: this is a constant-table + normalized-logic diff, not a literal byte compare — but combined with upstream's audit/formal-verification pedigree that is the proof; a library fuzz would only re-prove Uniswap's work (see below).*

- **0.8.x port correctness.** Original UniV3 math predates 0.8's built-in overflow checks; every function here is wrapped in `unchecked` (intentional wraparound is load-bearing for `mulDiv`'s 512-bit trick and the tick ratio chain). This is the *correct* port — but it means standard overflow protection is off, so the bounds must hold by construction. Worth confirming no consumer feeds inputs outside the domain these assume (e.g. `tick` within ±MAX_TICK, liquidity/sqrt ranges in-range).

- **Partial vendoring of TickMath.** Only the forward `getSqrtRatioAtTick` is present — the inverse `getTickAtSqrtRatio` is **not** vendored. Fine *iff* no consumer needs price→tick; worth confirming the oracle only ever goes tick→price.

- **`getQuoteAtTick` uint128 cap.** `baseAmount` is `uint128` (per the header, callers valuing amounts > uint128 must split or use `FullMath` directly). Worth confirming the oracle respects this for large balances — an overflow here would be a silent mis-quote, not a revert (it's `unchecked`).

- **Cross-protocol tick-math assumption — CONFIRMED LIVE 2026-06-22.** The header asserts Algebra uses the identical X96 tick math as UniV3, so this code is correct for the Algebra HYDX/USDC pool. `test/libraries/AlgebraTickMathLive.t.sol` (Base-fork) confirms it against the live pool `0x51f0B9…`: the live `globalState` sqrtPrice falls in `[getSqrtRatioAtTick(tick), getSqrtRatioAtTick(tick+1))` using the vendored `TickMath` — the defining property of the encoding. Passes, so Algebra Integral's Q64.96 encoding matches UniV3 and the vendored math prices this pool correctly. Re-run if the wired pool changes.

- **No need to re-fuzz the library.** UniV3 `FullMath`/`TickMath` are among the most audited/formally-verified math in DeFi — fuzzing them re-proves Uniswap's work. The only copy-specific risk was a transcription typo, and the 2026-06-20 diff above ruled that out, so the upstream's assurance carries over. What *is* worth testing lives in the **consumer, not the library**: that `AlgebraIchiFairLpOracle` / `IchiAlgebraFairReserves` only ever feed in-domain inputs (ticks within ±MAX_TICK; `getQuoteAtTick` base amounts ≤ uint128, else split). That belongs in the oracle's test suite.

## Hygiene notes

- **Licenses are mixed but consistent:** `FullMath` is MIT, the rest GPL-2.0; file header is `GPL-2.0-or-later`, which dominates. Fine.
- **Vendored-not-remapped is deliberate** — keeps the prod build off `reference/` and out of UniV3 pool-interface pull-in. Same `[EXT]` house posture as the local interface mirrors. The cost is manual sync if upstream ever patches (UniV3 math is effectively frozen, so low risk).
- **Git:** squashed_import for this scope (1 source-touching commit), single author — no evolution history to mine.

## Takeaway

This is **vendored, frozen, well-pedigreed math** — not a design risk. There is **no tier/verdict** (a math lib can't be "tested" or "exploited" in the threat-model sense). The faithfulness check is **done** (the 2026-06-20 diff above: confirmed, no logic divergence), so the copy carries upstream's audit/formal-verification assurance — a library fuzz would only re-prove Uniswap's work. The one residual is **not in this file**: confirm the consumers (`AlgebraIchiFairLpOracle` / `IchiAlgebraFairReserves`) only feed in-domain inputs (ticks within ±MAX_TICK; `getQuoteAtTick` base amounts ≤ uint128) — that belongs in the oracle's test suite. Everything downstream (the fair-LP oracle, NAV) inherits the correctness of these four functions.
