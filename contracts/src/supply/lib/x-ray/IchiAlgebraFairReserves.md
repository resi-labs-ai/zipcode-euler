# X-Ray — `IchiAlgebraFairReserves.sol` (single-library, test-connected)

> IchiAlgebraFairReserves | 43 nSLOC | `main` (working tree) | Foundry | 22/06/26 | **Verdict: HARDENED** *(only residual is the off-chain TWAP-source trust, X-2)*

> **Update:** the lib now has a read-time `isInitialized()` plugin-readiness
> gate (`PluginNotReady`, ADV-02) — a THIRD fail-closed revert beyond `NoPlugin`/`BadTimepoints`. All three are now
> unit-tested via mock plugins (`NoPlugin`, `PluginNotReady` ctor+read, `BadTimepoints` — ADV-03), and the TWAP
> window under-coverage residual (X-2) is settled empirically by a live-fork revert test. The earlier
> "fail-closed paths untested" cap is closed; verdict lifted ADEQUATE → HARDENED.

Dedicated single-contract X-Ray for `contracts/src/supply/lib/IchiAlgebraFairReserves.sol`, the sole file in the
`supply/lib` scope (the bundled `x-ray.md` is the scope overview; this is the per-contract, test-connected file).
Connected to `test/AlgebraIchiFairLpOracle.t.sol` — **5 base-fork integration tests against the LIVE HYDX/USDC ICHI
vault `0xfF8B…73f7`** plus **mock-plugin unit tests for the three fail-closed reverts** (`NoPlugin`,
`PluginNotReady`, `BadTimepoints`) and a fork under-coverage revert test (0 fuzz; the math primitives are
vendored/frozen — see §6).

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
| `fairReserves(vault, window)` | `internal view` | reconstructs `(amount0, amount1, meanTick)` at the `window`-sec TWAP tick; reverts `NoPlugin` (no plugin) or `PluginNotReady` (plugin not `isInitialized()` — read-time gate, ADV-02) |
| `_meanTick(plugin, window)` | `internal view` | arithmetic-mean tick over `[now-window, now]` via `getTimepoints`; reverts `BadTimepoints` if the set isn't length-2; rounds toward −∞ on a negative remainder (UniV3 `OracleLibrary.consult` convention) |

No permissionless surface, no state writes, no admin — a library linked into its consumers. `window` is supplied by
the consumer (1h / 3600s on the deployed oracle).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **manipulation invariance** — reserves are valued at the TWAP tick, never the spot tick; an in-block swap cannot move the reconstruction | Yes | **`test_fork_manipulation_invariance`** — 300k-USDC swap moves spot split >2% (`getTotalAmounts` shifts), fair quote moves <1% |
| I-2 | **faithfulness** — when the pool is calm (TWAP tick ≈ current tick), the reconstruction reproduces `getTotalAmounts()` | Yes | **`test_fork_fairReserves_match_getTotalAmounts_when_calm`** — `f0≈s0`, `f1≈s1` within ~1% |
| I-3 | **fail-closed on a bad TWAP source** — no plugin reverts `NoPlugin`; an uninitialized plugin reverts `PluginNotReady` (ADV-02 read-time gate); a malformed timepoint set reverts `BadTimepoints` | Yes | `:45`, `:53`, `:92`; **all three now tested** via mock plugins — `test_..._noPlugin`, `test_ctor_revert_uninitializedPlugin` + `test_fairReserves_revert_uninitializedPlugin`, `test_fairReserves_revert_badTimepoints` (ADV-03); under-coverage fails closed on the live plugin (`test_fork_underCoverageWindow_failsClosed`) |
| I-4 | **`_meanTick` rounds toward −∞** on a negative remainder (consult convention; avoids off-by-one upward bias at negative ticks) | Yes | code (`:85`); inherited from the UniV3 convention, exercised indirectly by I-1/I-2 (live tick is negative for HYDX/USDC) |
| I-5 | reserves = base recon + limit recon + idle balances; idle added as raw token amounts (composition not price-sensitive) | Yes | follows from `:54-70`; `test_fork_tvl_and_holder_value` confirms the summed dollar TVL + pro-rata identity is sane |
| X-1 | the tick→reserve math (`TickMath`, `LiquidityAmounts`) is correct | **No** (vendored) | `ConcentratedLiquidity` is frozen UniV3 math — audited/formally-verified upstream; faithfulness diff confirmed (`libraries/x-ray/library-review.md`) |
| X-2 | the Algebra plugin's TWAP is honest (sufficient observation cardinality, not stale, window not gameable over its length) | **No** (pool/off-chain) | the TWAP source is the Algebra pool's oracle plugin — integrity is a pool-config/economic property, not enforced here |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `NoPlugin` (pool has no TWAP plugin) | `test_..._noPlugin` (`MockPoolNoPlugin`/`MockVaultNoPlugin`) |
| `PluginNotReady` (plugin not `isInitialized()`; ADV-02 read-time gate) | `test_ctor_revert_uninitializedPlugin`, `test_fairReserves_revert_uninitializedPlugin` (`MockUninitializedPlugin`) |
| `BadTimepoints` (timepoint set not length-2) | `test_fairReserves_revert_badTimepoints` (`MockBadTimepointsPlugin`; ADV-03) |
| In-domain ticks (±MAX_TICK) | enforced upstream by `TickMath` (reverts out-of-range); `getAmountsForLiquidity` base ≤ uint128 is the consumer's contract (`library-review.md` §residual) |

## 5. Attack surfaces

- **The whole point — TWAP anchoring (I-1)** — the design replaces the in-block-manipulable `getTotalAmounts()` spot
  split with a TWAP-tick reconstruction. `test_fork_manipulation_invariance` is the decisive proof and it exists,
  against a *live* pool with a real 300k swap. This is the strongest possible evidence for a manipulation-resistance
  library.
- **Residual TWAP trust (X-2)** — manipulation invariance holds only as strongly as the Algebra plugin's TWAP. A
  pool with low observation cardinality, or a window short enough to be moved by a sustained (multi-block)
  cost-of-capital attack, weakens the guarantee. **Partly addressed (ADV-02):** the lib now fails closed on an
  uninitialized plugin (`PluginNotReady`, the read-time `isInitialized()` gate covering both consumers), and window
  UNDER-coverage fails closed on the deployed plugin (`getTimepoints` reverts when `window` predates the oldest
  stored timepoint — proven by `test_fork_underCoverageWindow_failsClosed`). Observation **cardinality is not
  on-chain-queryable**, so there is no in-contract span assertion (it would need plugin surface the verified
  interface lacks); the deployed pool's cardinality + the consumer's `window` (1h) being economically safe remains
  the off-chain residual. This is the same class as any oracle's external-feed trust.
- **Fail-closed paths now tested (I-3) — gap closed.** `NoPlugin`, `PluginNotReady` (ADV-02), and `BadTimepoints`
  (ADV-03) all have mock-plugin unit tests; the previously-flagged "one real test gap" is closed.
- **In-domain inputs (X-1 boundary)** — the tick→reserve math is vendored frozen UniV3 (`ConcentratedLiquidity`);
  the only copy-specific risk (a transcription typo) was ruled out by the faithfulness diff. The residual
  is feeding in-domain inputs (ticks within ±MAX_TICK, base ≤ uint128) — `TickMath` reverts out-of-range, so this
  fails closed rather than mis-prices.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Fork integration | 5 | all against the live HYDX/USDC ICHI vault: faithfulness-when-calm, manipulation invariance (the keystone), dollar/TVL + pro-rata holder cross-check, EVK-router collateral resolution, the deploy P5 fair-oracle market build |
| Mock-plugin fail-closed unit | 4 | `NoPlugin`, `PluginNotReady` (ctor + read path, ADV-02), `BadTimepoints` (ADV-03) — driven through the external `FairReservesCaller` wrapper so `expectRevert` sees the internal-lib revert |
| Fork under-coverage | 1 | `test_fork_underCoverageWindow_failsClosed` — a 10y window ≫ the plugin's history reverts (fail-closed), the empirical settlement of the X-2 under-coverage residual |
| Stateless fuzz | 0 | **correctly omitted** — the math is vendored UniV3 `TickMath`/`LiquidityAmounts`; fuzzing re-proves Uniswap's audited/formally-verified work (`libraries/x-ray/library-review.md`) |

The lib is connected to the `AlgebraIchiFairLpOracle.t.sol` suite (**17 pass** at the working tree:
`forge test --match-path test/supply/AlgebraIchiFairLpOracle.t.sol` → 17 passed, 0 failed). Several tests call
`IchiAlgebraFairReserves.fairReserves` directly (the calm-faithfulness check + the three fail-closed mock-plugin
tests via `FairReservesCaller`); the rest exercise it through `AlgebraIchiFairLpOracle`. Coverage %
uninstrumentable (project-wide stack-too-deep); existence + green run confirmed by scan.

## X-Ray Verdict

**HARDENED** — a small (43 nSLOC), stateless, single-purpose manipulation-resistance library whose **keystone
property (TWAP invariance) is directly proven by a live-fork manipulation test**, whose faithfulness-when-calm is
proven against the real vault, whose underlying tick math is vendored/frozen/audited UniV3, and whose **three
fail-closed reverts (`NoPlugin`/`PluginNotReady`/`BadTimepoints`) are all now unit-tested** (the earlier ADEQUATE
cap). The read-time `isInitialized()` gate (ADV-02) + the empirical under-coverage fork test settle the readiness
half of the X-2 residual. The only remaining residual is off-chain and out of scope: the Algebra plugin's TWAP
honesty (observation cardinality/window economics, not on-chain-queryable) — the same class as any oracle's
external-feed trust. No fuzz needed — the math is Uniswap's.

**Structural facts:**
1. 43 nSLOC; pure `internal view` library; no storage, no admin, no permissionless surface, no value path.
2. Reconstructs reserves at the TWAP tick (position `L` + bounds, both swap-immune) instead of the spot-tick `getTotalAmounts()`; idle balances added raw.
3. Three revert paths: `NoPlugin` (no TWAP source), `PluginNotReady` (plugin not initialized — ADV-02 read-time gate), `BadTimepoints` (malformed set) — all fail closed, all tested.
4. Tests: 5 live-fork integration (manipulation invariance + faithfulness + dollar sanity + EVK resolution + deploy path) + 4 mock-plugin fail-closed units + 1 fork under-coverage revert; 0 fuzz (vendored math).
5. The residual risk is off-chain: the Algebra plugin's TWAP integrity (cardinality/window), not this bytecode (X-2); the tick math correctness is upstream Uniswap (X-1).
