# X-Ray — `AlgebraIchiFairLpOracle.sol` (single-contract, fork-connected)

> AlgebraIchiFairLpOracle | 58 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

> **Update:** the coverage gaps below (ctor guards, unsupported-pair / zero-supply fail-closed reverts,
> rounding direction, and the high-`sqrtP` branch of `_token0InQuote`) are **CLOSED** — 8 new tests added to
> `AlgebraIchiFairLpOracle.t.sol` (13/13 green). Every entry point and every revert on the contract is now exercised.

Dedicated single-contract X-Ray for `contracts/src/supply/AlgebraIchiFairLpOracle.sol`, the **trustless, fully
on-chain** fair-value oracle for an ICHI-vault LP share on an Algebra pool. It is the `IPriceOracle`/`BaseAdapter`
face an EVK `EulerRouter` resolves the LP collateral through — the no-liveness-dependency drop-in for the CRE-pushed
`SzipFarmUtilityLpOracle`. Exercised by `AlgebraIchiFairLpOracle.t.sol` (5 base-fork tests vs the live HYDX/USDC
vault `0xfF8B…73f7`).

> This contract is a **thin pricing wrapper**: it owns the LP-share → TVL → pro-rata-quote arithmetic, and delegates
> the entire manipulation-resistance story to [`IchiAlgebraFairReserves`](../lib/x-ray/x-ray.md) (separately
> X-rayed — ADEQUATE, a hair from HARDENED). The keystone property — fair value is invariant under an in-block swap —
> is therefore proven in the lib's fork test and re-exercised here through this oracle's `getQuote`. What is *new* in
> this file is: (1) pro-rata-of-TVL pricing rounded DOWN against the borrower, (2) the `token0→quote` valuation at the
> TWAP tick, and (3) the fail-closed surface (unsupported pair / zero supply / no plugin).

## 1. What it is

A 58-nSLOC `BaseAdapter` (euler-price-oracle) that prices `(lpToken, quote)` where `quote == pool.token1` (the
stable leg, e.g. USDC). All params are **immutable** — a cheap, replaceable clone per the repo's oracle philosophy;
re-pointing the vault or TWAP window is a redeploy + a one-call router re-point (`govSetConfig`), not a setter.

`_getQuote(inAmount, base, quote)`:
1. `IchiAlgebraFairReserves.fairReserves(lpToken, twapWindow)` → `(amount0, amount1, meanTick)` at the **TWAP tick** (manipulation-resistant);
2. `tvlInQuote = amount1 + _token0InQuote(meanTick, amount0)` — value the volatile leg in token1 at that same TWAP tick;
3. `FullMath.mulDiv(tvlInQuote, inAmount, totalSupply)` — pro-rata of TVL, **rounded DOWN** (against the borrower).

No state, no admin, no setters, no custody. The only storage is four immutables set in the constructor.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `getQuote / getQuotes` (BaseAdapter) → `_getQuote` | public view | only `(lpToken, quote)` supported; else `PriceOracle_NotSupported`; `bid==ask==mid` |
| `fairTvl()` | external view | returns `(tvlInQuote, amount0, amount1, meanTick)` — monitoring / tests |
| `name()` | public const | `"AlgebraIchiFairLpOracle"` (satisfies `IPriceOracle.name()`) |
| `constructor(vault_, twapWindow_)` | deploy | zero-guards both; requires the pool exposes a plugin (`NoPlugin`); pins `quote=token1`, `token0`, `lpToken=vault` |

No CRE operator, no owner, no permissionless mutator. The contract is pure read.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **pro-rata identity** — `getQuote(shares) == TVL · shares / supply` | Yes | **`test_fork_tvl_and_holder_value`** (asserts holder value ≈ `tvl·bal/supply` to 1e-4; also the m4ngos holder dollar cross-check) |
| I-2 | **manipulation invariance** — fair quote barely moves (<1%) under a large in-block swap that moves the spot split >2% | Yes (via the lib) | **`test_fork_manipulation_invariance`** (300k-USDC swap on the live pool; the property the whole exercise exists to prove) |
| I-3 | **faithful when calm** — TWAP reconstruction ≈ `getTotalAmounts()` (within ~1%) | Yes | **`test_fork_fairReserves_match_getTotalAmounts_when_calm`** |
| I-4 | **resolves as EVK collateral** — a real `EulerRouter` configured with this oracle prices `(lpToken→USDC)` identically | Yes | **`test_fork_resolves_through_euler_router`** + **`test_fork_farmUtility_market_builds_with_fair_oracle`** (the deploy P5 `lpTwapWindow != 0` path, escrow→lpToken→oracle→USDC) |
| I-5 | **rounds DOWN against the borrower** — `mulDiv` truncates; never over-values collateral | Yes | **`test_getQuote_rounds_down_against_borrower`** — mocks `supply = tvl+1`, quotes `inAmount = tvl`; asserts the result is `tvl-1` (the floor of `tvl·tvl/(tvl+1)`), strictly below the un-truncated pro-rata, with a proven non-zero remainder |
| I-6 | **fail-closed** — unsupported `(base,quote)` and `supply==0` revert `PriceOracle_NotSupported`; no plugin reverts `NoPlugin` (ctor) | Yes | **`test_getQuote_revert_unsupportedBase` / `_unsupportedQuote` / `_zeroSupply`** (the two `NotSupported` paths) + **`test_ctor_revert_noPlugin`** (mock pool with `plugin()==0`) |
| I-7 | **ctor zero-guards** — zero vault → `ZeroAddress`; zero window → `ZeroWindow` | Yes | **`test_ctor_revert_zeroVault` / `test_ctor_revert_zeroWindow`** |
| I-8 | **`_token0InQuote` high-`sqrtP` (X128) branch is reachable + correct** — at `sqrtP > uint128.max` it switches to the 512-bit X128 form (avoids `sqrtP*sqrtP` overflow) and returns the same price | Yes | **`test_token0InQuote_highSqrtP_branch`** — harness drives tick 600k (asserts `sqrtP > uint128.max`), confirms no revert, equals the X128 reference, and is linear in `amount0`; low arm (tick 100k) cross-checked against the X192 reference |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `ZeroAddress` (vault) | ctor `:49` | `test_ctor_revert_zeroVault` |
| `ZeroWindow` | ctor `:50` | `test_ctor_revert_zeroWindow` |
| `NoPlugin` (pool has a TWAP plugin) | ctor `:52` (+ re-checked in the lib) | `test_ctor_revert_noPlugin` (mock pool, `plugin()==0`) |
| `PriceOracle_NotSupported` (wrong pair) | `_getQuote:73` | `test_getQuote_revert_unsupportedBase` / `_unsupportedQuote` |
| `PriceOracle_NotSupported` (zero supply) | `_getQuote:79` | `test_getQuote_revert_zeroSupply` (mocked `totalSupply()==0`) |

The functional/economic surface (I-1…I-4) is fork-proven; the fail-closed reverts (I-6/I-7), the rounding direction
(I-5), and the high-`sqrtP` branch (I-8) — formerly the coverage gap — **are now closed** (8 tests).
**Every guard and every entry point on the contract is now exercised.**

## 5. Attack surfaces

- **The decisive property is not in this file — and it's proven where it lives.** Manipulation resistance is
  `IchiAlgebraFairReserves`'s job (value position `L` at the TWAP tick, both swap-immune); this oracle just pro-rates
  the result. `test_fork_manipulation_invariance` lands a 300k-USDC swap and shows this oracle's `getQuote` moves <1%
  while `getTotalAmounts()` (the spot split a naive oracle would trust) moves >2%. The wrapper inherits the
  guarantee, and the fork test re-proves it end-to-end through `getQuote`.
- **`_token0InQuote` dual-branch — both arms now covered (I-8).** The conversion mirrors UniV3
  `OracleLibrary.getQuoteAtTick` but accepts a full `uint256` amount0 via `FullMath`'s 512-bit product (so a large
  vault never hits the `uint128` base-amount cap). The `sqrtP > type(uint128).max` branch (`:96-101`) only triggers
  at extreme prices; on HYDX/USDC the low branch is taken, so it carried no *fork* coverage — now driven directly via
  a harness at tick 600k (`test_token0InQuote_highSqrtP_branch`), asserting it is reachable, overflow-safe, and equal
  to the X128 reference; the low arm is cross-checked at tick 100k. Address-ordering (`token0 < quote`) is read at
  construction and selects the ratio direction — correct for the deployed single-sided-USDC vault.
- **Rounds DOWN against the borrower (I-5) — now proven deterministically.** `mulDiv` truncation under-values
  collateral, the safe direction for a borrow market; `test_getQuote_rounds_down_against_borrower` forces a guaranteed
  remainder (supply = tvl+1, inAmount = tvl) and asserts the floored result `tvl-1`, strictly below the un-truncated
  pro-rata.
- **Fail-closed reverts (I-6/I-7) — now covered.** Unsupported pair, zero supply, and (ctor) no plugin / zero
  vault / zero window all revert rather than returning a manipulable/garbage price — each now has a dedicated test
  (mock pool for `NoPlugin`, mocked `totalSupply()==0` for the zero-supply path). The former single in-file gap,
  shared with the lib, is closed on the oracle side.
- **Inherited residual trust** — the Algebra plugin's TWAP cardinality/window (the lib's X-2; off-chain pool config,
  1h window deployed) and the vendored UniV3 tick math (the lib's X-1; frozen `ConcentratedLiquidity`). Neither is
  this bytecode; both are load-bearing and documented in the lib's X-Ray.
- **No admin / no upgrade surface** — immutable params, ownerless clone (`DeployZipcode._phaseP5` leaves
  `d.lpOracle == address(0)` identity-wise). Zero blast radius of its own; a change is a redeploy + router re-point.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Fork integration | 5 | all vs the live HYDX/USDC vault `0xfF8B…73f7`, pinned to `ForkConfig.BASE_FORK_BLOCK` |
| — faithfulness when calm | 1 | `test_fork_fairReserves_match_getTotalAmounts_when_calm` |
| — dollar sanity + pro-rata + holder cross-check | 1 | `test_fork_tvl_and_holder_value` (debank-confirmed m4ngos holding) |
| — manipulation invariance (the keystone) | 1 | `test_fork_manipulation_invariance` |
| — EVK router resolution | 1 | `test_fork_resolves_through_euler_router` |
| — deploy P5 fair-oracle market build | 1 | `test_fork_farmUtility_market_builds_with_fair_oracle` (`lpTwapWindow != 0` branch, no CRE seed) |
| Edge / fail-closed | 8 | ctor `ZeroAddress`/`ZeroWindow`/`NoPlugin`; unsupported base/quote; zero supply; rounds-down; high-`sqrtP` branch (harness) |
| Fuzz / invariant | 0 | correctly omitted — pricing is pure arithmetic over vendored UniV3 math |

Coverage % uninstrumentable (project-wide `Stack too deep`); **13/13 green** (5 fork + 8 edge). The economic surface
is fork-proven against real on-chain state, and every guard / branch / entry point is now exercised — no outstanding
in-file coverage gap.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — a thin, stateless, ownerless pricing wrapper whose decisive property
(manipulation invariance) is fork-proven where it lives (`IchiAlgebraFairReserves`) and re-proven here end-to-end
through `getQuote`, whose pro-rata identity and EVK-router/deploy-P5 resolution are fork-proven against the live
HYDX/USDC vault, and whose math is pure UniV3-style tick valuation. **The prior coverage gaps are now closed**:
the fail-closed reverts (unsupported pair / zero supply / `NoPlugin` / ctor zero-guards), the
rounding-down direction, and the `_token0InQuote` high-`sqrtP` branch each have a dedicated test (13/13 green). Held
below HARDENED now only by off-chain/upstream residuals: the inherited TWAP-cardinality/window trust lives in pool
config (the lib's X-2), the tick math is vendored UniV3 (the lib's X-1), and there is no external audit.

**Structural facts:**
1. 58 nSLOC; `BaseAdapter` (euler-price-oracle); immutable params; no state, no admin, no setters, no custody.
2. Prices `(lpToken, quote=pool.token1)` as pro-rata of fair TVL, **rounded DOWN** against the borrower; `bid==ask==mid`.
3. Delegates manipulation-resistance to `IchiAlgebraFairReserves` (values `L` at the TWAP tick); `_token0InQuote` values the volatile leg at that same tick via a full-`uint256` `FullMath` conversion.
4. Fail-closed: unsupported pair / zero supply → `PriceOracle_NotSupported`; no plugin → `NoPlugin` (ctor) — the trustless alternative to the CRE-pushed `SzipFarmUtilityLpOracle`, with no liveness dependency.
5. Tests: 13/13 — 5 live-fork (faithfulness + dollar/pro-rata + manipulation invariance + EVK-router resolution + deploy-P5 build) + 8 edge (ctor guards, unsupported-pair, zero-supply, rounds-down, high-`sqrtP` branch). No outstanding in-file coverage gap; residuals are upstream (TWAP config, vendored math) + no external audit.
