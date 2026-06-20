# X-Ray — `IchiAlgebraFairReserves.sol` (single-library, test-connected)

> IchiAlgebraFairReserves | 43 nSLOC | 95ed3dd (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

Dedicated single-contract X-Ray for `contracts/src/supply/lib/IchiAlgebraFairReserves.sol`, the sole file in the
`supply/lib` scope (the bundled `x-ray.md` is the scope overview; this is the per-contract, test-connected file).
Connected to `test/AlgebraIchiFairLpOracle.t.sol` — **5 base-fork integration tests against the LIVE HYDX/USDC ICHI
vault `0xfF8B…73f7`** (0 isolated unit, 0 fuzz; the math primitives are vendored/frozen — see §6).

> The keystone test (`test_fork_manipulation_invariance`) IS the reason this library exists: it proves a 300k-USDC
> in-block swap that moves `getTotalAmounts()` >2% leaves the fair quote unmoved (<1%).

## 1. What it is

A pure `internal view` library — **no storage, no state, no admin, no value path**. It reconstructs an ICHI vault's
`(amount0, amount1)` reserves **at the pool's TWAP tick** instead of trusting `IICHIVault.getTotalAmounts()`, which
computes each position's split at the pool's *current* tick and is therefore in-block manipulable. It is the
keystone the fair-LP oracle (`AlgebraIchiFairLpOracle`) and the NAV oracle's LP leg (`SzipNavOracle`) read.

**The mechanism:** for each of the vault's two positions (base + limit), take the position liquidity `L`
(`getBasePosition`/`getLimitPosition`) and its tick bounds, and compute reserves via
`LiquidityAmounts.getAmountsForLiquidity` evaluated at the TWAP `sqrtP`. Both inputs are immune to in-block swaps —
`L` changes only on the vault's mint/burn, the TWAP tick is a time-average. Idle vault balances (`balanceOf(vault)`
for token0/token1) are added as-is (token amounts, not price-sensitive in composition).

## 2. Entry points

| Function | Visibility | Notes |
|---|---|---|
| `fairReserves(vault, window)` | `internal view` | reconstructs `(amount0, amount1, meanTick)` at the `window`-sec TWAP tick; reverts `NoPlugin` if the pool exposes no TWAP plugin |
| `_meanTick(plugin, window)` | `internal view` | arithmetic-mean tick over `[now-window, now]` via `getTimepoints`; reverts `BadTimepoints` if the set isn't length-2; rounds toward −∞ on a negative remainder (UniV3 `OracleLibrary.consult` convention) |

No permissionless surface, no state writes, no admin — a library linked into its consumers. `window` is supplied by
the consumer (1h / 3600s on the deployed oracle).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **manipulation invariance** — reserves are valued at the TWAP tick, never the spot tick; an in-block swap cannot move the reconstruction | Yes | **`test_fork_manipulation_invariance`** — 300k-USDC swap moves spot split >2% (`getTotalAmounts` shifts), fair quote moves <1% |
| I-2 | **faithfulness** — when the pool is calm (TWAP tick ≈ current tick), the reconstruction reproduces `getTotalAmounts()` | Yes | **`test_fork_fairReserves_match_getTotalAmounts_when_calm`** — `f0≈s0`, `f1≈s1` within ~1% |
| I-3 | **fail-closed on no TWAP source** — a pool with no plugin reverts `NoPlugin`; a malformed timepoint set reverts `BadTimepoints` | Yes | code (`:41`, `:80`); **not directly tested** (the live vault always has a plugin) — see §5 |
| I-4 | **`_meanTick` rounds toward −∞** on a negative remainder (consult convention; avoids off-by-one upward bias at negative ticks) | Yes | code (`:85`); inherited from the UniV3 convention, exercised indirectly by I-1/I-2 (live tick is negative for HYDX/USDC) |
| I-5 | reserves = base recon + limit recon + idle balances; idle added as raw token amounts (composition not price-sensitive) | Yes | follows from `:54-70`; `test_fork_tvl_and_holder_value` confirms the summed dollar TVL + pro-rata identity is sane |
| X-1 | the tick→reserve math (`TickMath`, `LiquidityAmounts`) is correct | **No** (vendored) | `ConcentratedLiquidity` is frozen UniV3 math — audited/formally-verified upstream; faithfulness diff confirmed 2026-06-20 (`libraries/x-ray/library-review.md`) |
| X-2 | the Algebra plugin's TWAP is honest (sufficient observation cardinality, not stale, window not gameable over its length) | **No** (pool/off-chain) | the TWAP source is the Algebra pool's oracle plugin — integrity is a pool-config/economic property, not enforced here |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `NoPlugin` (pool has no TWAP plugin) | not tested — live vault always has one (gap, §5) |
| `BadTimepoints` (timepoint set not length-2) | not tested — would need a mock plugin (gap, §5) |
| In-domain ticks (±MAX_TICK) | enforced upstream by `TickMath` (reverts out-of-range); `getAmountsForLiquidity` base ≤ uint128 is the consumer's contract (`library-review.md` §residual) |

## 5. Attack surfaces

- **The whole point — TWAP anchoring (I-1)** — the design replaces the in-block-manipulable `getTotalAmounts()` spot
  split with a TWAP-tick reconstruction. `test_fork_manipulation_invariance` is the decisive proof and it exists,
  against a *live* pool with a real 300k swap. This is the strongest possible evidence for a manipulation-resistance
  library.
- **Residual TWAP trust (X-2)** — manipulation invariance holds only as strongly as the Algebra plugin's TWAP. A
  pool with low observation cardinality, or a window short enough to be moved by a sustained (multi-block)
  cost-of-capital attack, weakens the guarantee. The library does **not** check observation cardinality or staleness
  — it trusts `getTimepoints` to return a meaningful average. Worth confirming the deployed pool's cardinality and
  the consumer's `window` are economically safe; consider a cardinality/staleness assertion as defense-in-depth.
- **Fail-closed paths untested (I-3)** — `NoPlugin` and `BadTimepoints` are correct on inspection but have no test
  (the live vault always exposes a plugin). A mock-plugin unit test (no plugin → `NoPlugin`; wrong-length set →
  `BadTimepoints`) would close the one real test gap.
- **In-domain inputs (X-1 boundary)** — the tick→reserve math is vendored frozen UniV3 (`ConcentratedLiquidity`);
  the only copy-specific risk (a transcription typo) was ruled out by the 2026-06-20 faithfulness diff. The residual
  is feeding in-domain inputs (ticks within ±MAX_TICK, base ≤ uint128) — `TickMath` reverts out-of-range, so this
  fails closed rather than mis-prices.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Fork integration | 5 | all against the live HYDX/USDC ICHI vault: faithfulness-when-calm, manipulation invariance (the keystone), dollar/TVL + pro-rata holder cross-check, EVK-router collateral resolution, the deploy P5 fair-oracle market build |
| Isolated unit | 0 | the fail-closed reverts (`NoPlugin`/`BadTimepoints`) would need a mock plugin — not present |
| Stateless fuzz | 0 | **correctly omitted** — the math is vendored UniV3 `TickMath`/`LiquidityAmounts`; fuzzing re-proves Uniswap's audited/formally-verified work (`libraries/x-ray/library-review.md`) |

All **5 pass** (`forge test --match-path test/AlgebraIchiFairLpOracle.t.sol` → 5 passed, 0 failed). Two tests call
`IchiAlgebraFairReserves.fairReserves` directly (`_match_getTotalAmounts_when_calm`, and the manipulation test via
the oracle's `getQuote`); the other three exercise it through `AlgebraIchiFairLpOracle`. Coverage %
uninstrumentable (project-wide stack-too-deep); existence + green run confirmed by scan.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — a small (43 nSLOC), stateless, single-purpose manipulation-resistance
library whose **keystone property (TWAP invariance) is directly proven by a live-fork manipulation test**, whose
faithfulness-when-calm is proven against the real vault, and whose underlying tick math is vendored/frozen/audited
UniV3. Capped at ADEQUATE (not HARDENED) only by: the `NoPlugin`/`BadTimepoints` fail-closed paths are untested (no
mock-plugin unit), no on-chain TWAP cardinality/staleness guard (the residual trust X-2 lives in pool config), and
single-vault fork coverage. No fuzz needed — the math is Uniswap's.

**Structural facts:**
1. 43 nSLOC; pure `internal view` library; no storage, no admin, no permissionless surface, no value path.
2. Reconstructs reserves at the TWAP tick (position `L` + bounds, both swap-immune) instead of the spot-tick `getTotalAmounts()`; idle balances added raw.
3. Two revert paths: `NoPlugin` (no TWAP source → fail closed), `BadTimepoints` (malformed set).
4. Tests: 5 live-fork integration (manipulation invariance + faithfulness + dollar sanity + EVK resolution + deploy path); 0 unit, 0 fuzz (vendored math).
5. The residual risk is off-chain: the Algebra plugin's TWAP integrity (cardinality/window), not this bytecode (X-2); the tick math correctness is upstream Uniswap (X-1).
