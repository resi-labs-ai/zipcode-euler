# Invariant Map

> supply/lib (Fair Reserves) | 2 guards | 5 inferred (single-contract) | 2 not enforced on-chain (cross-contract)

> The defining feature: the keystone invariant (**I-1, manipulation invariance**) is **On-chain=Yes and directly
> fork-tested**. The two residual-trust invariants are **On-chain=No** — the tick math is Uniswap's (X-1), the TWAP
> integrity is the pool's (X-2).

---

## 1. Enforced Guards (Reference)

#### G-1
`if (plugin == address(0)) revert NoPlugin()` · `IchiAlgebraFairReserves.sol:41` · the pool must expose a TWAP plugin; a pool with no manipulation-resistant price source fails **closed** rather than falling back to a manipulable spot value.

#### G-2
`if (cum.length != 2) revert BadTimepoints()` · `IchiAlgebraFairReserves.sol:80` · the plugin must return exactly the two requested tick-cumulatives; a malformed timepoint set fails closed.

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`ManipulationInvariance` · On-chain: **Yes**

> The reconstruction values each position's reserves at the **TWAP tick**, never the pool's current tick. An in-block swap moves the current tick (and thus `getTotalAmounts()`) but moves neither the position liquidity `L` (changes only on vault mint/burn) nor the time-averaged TWAP tick — so it cannot move the reconstruction.

**Derivation** — `meanTick = _meanTick(plugin, window)` then `sqrtP = getSqrtRatioAtTick(meanTick)` (`:43-44`); every `getAmountsForLiquidity` evaluates at this `sqrtP` (`:48-64`). No spot/current-tick read enters the amount math.

**If violated** — LP value would track the spot split and be in-block manipulable (the exact flaw of `getTotalAmounts()`). Proven held: **`test_fork_manipulation_invariance`** (300k-USDC swap → spot split >2%, fair quote <1%).

#### I-2

`Faithfulness` · On-chain: **Yes**

> When the pool is calm (TWAP tick ≈ current tick), the reconstruction reproduces `getTotalAmounts()`. The fair value is not a different number — it is the same composition valued at a manipulation-resistant price.

**Derivation** — at TWAP≈current, `getAmountsForLiquidity` at the TWAP `sqrtP` equals the live split; idle balances are added identically (`:69-70`).

**If violated** — the oracle would diverge from reality even absent manipulation. Proven held: **`test_fork_fairReserves_match_getTotalAmounts_when_calm`** (within ~1%), and the wei-level NatSpec validation (`:21-23`).

#### I-3

`FailClosed` · On-chain: **Yes**

> No TWAP source ⇒ revert (`NoPlugin`); malformed timepoints ⇒ revert (`BadTimepoints`). The library never returns a spot/fallback value when the manipulation-resistant price is unavailable.

**Derivation** — `:41`, `:80`.

**If violated** — a missing/broken plugin could silently degrade to a manipulable value. **Untested** (the live vault always has a plugin) — the one concrete test gap.

#### I-4

`RoundingConvention` · On-chain: **Yes**

> `_meanTick` rounds toward −∞ on a negative remainder (`if (delta < 0 && delta % w != 0) mean--`), matching the UniV3 `OracleLibrary.consult` convention — avoids an upward off-by-one bias at negative ticks.

**Derivation** — `:82-86`.

**If violated** — a one-tick upward bias at negative ticks (the live HYDX/USDC tick is negative). Exercised indirectly by I-1/I-2 (both run at the live negative tick).

#### I-5

`ReserveComposition` · On-chain: **Yes**

> Total reserves = base-position recon + limit-position recon + idle vault balances; idle balances are added as raw token amounts (their composition is not price-sensitive).

**Derivation** — `:54-70` (`amount0/amount1` accumulate base, then limit, then `balanceOf(vault)`).

**If violated** — under- or double-counting of positions/idle. `test_fork_tvl_and_holder_value` confirms the summed dollar TVL is sane and the pro-rata holder identity holds.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No** (vendored math)

> The tick→reserve math (`TickMath.getSqrtRatioAtTick`, `LiquidityAmounts.getAmountsForLiquidity`) is correct for in-domain inputs (ticks within ±MAX_TICK, base amounts ≤ uint128).

**Caller side** — `fairReserves:44-64`.

**Callee side** — `ConcentratedLiquidity` (vendored UniV3) — **out of scope**; audited/formally-verified upstream; faithfulness diff confirmed 2026-06-20 (`libraries/x-ray/library-review.md`).

**If violated** — mis-priced reserves. Mitigated: `TickMath` reverts out-of-domain ticks (fail-closed); feeding in-domain inputs is the consumer's contract.

#### X-2

On-chain: **No** (pool / off-chain config)

> The Algebra plugin's TWAP is honest and robust: sufficient observation cardinality and a window long enough that moving the average over its full length is economically infeasible.

**Caller side** — `_meanTick:79` (`getTimepoints`).

**Callee side** — the Algebra pool's oracle plugin — **out of scope** (pool config + economics).

**If violated** — a low-cardinality or short-window TWAP could be moved by a sustained multi-block attack, weakening I-1. The library does **not** assert cardinality/staleness; the deployed pool's cardinality and the consumer's `window` (1h) must be economically safe.

---

## 4. Economic Invariants

*None in scope.* This is a stateless reconstruction library; the economic invariants (LP collateral valuation, senior NAV marking, liquidation thresholds) live in the consuming oracles and the EVK reservoir market, not here.
