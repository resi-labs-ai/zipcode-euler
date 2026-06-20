# KEEPER-01b — the strike-loop harvest Job (core slice)

> One item. The (K) keeper-track Job that drives the auto-compounder engine's `onlyOperator` legs
> (8-B5…8-B10) as ONE ordered `chain.Plan` on the `cre/keeper/` spine. Core slice only: claim → borrow →
> exercise → sell → repay → credit/recycle → restake. **NO** regime classifier/EMA, **NO** keeper STATE
> store, **NO** vote/allocation, **NO** main↔sidecar rotation (those are own-later slices / KEEPER-01c).
> Policy ratified 2026-06-19 (`KEEPER-01b-OPEN-POLICY.md`, lifted into `claude-zipcode.md` §8.7).

## Deliverable
A new `StrikeLoopJob` implementing `job.Job` in `cre/keeper/internal/job/strike_loop_job.go`, registered in
`cmd/keeper/main.go`, plus a price/share quote seam `internal/quote/` (or `internal/chain` helpers) for the
off-chain Algebra/ICHI reads. Native go-ethereum service (NOT wasip1 — the keeper submits ordinary txs;
`cmd/keeper/main.go:1-3`). Gate: `go build ./...` + `go vet ./...` green; a table-driven unit test of
`Evaluate` (scripted reader/quoter) asserting plan ordering + scalar sizing + every no-op gate; a unit test
of the price/share math; and a sim test driving a combined recorder probe through the `Runner` to prove
ordered multi-leg submission + arg fidelity. Committed to `cre/keeper`.

## Spec §
`claude-zipcode.md` §8.7 (the operator path; the per-leg loop steps 1–4 + the ratified core-slice policy
block) and §4.5.1 (the auto-compounder / free-value-only invariant). Policy record:
`build/tickets/cre/KEEPER-01b-OPEN-POLICY.md` (A1–A4, B3, C4 ratified).

## Binds to (verified against live source — re-confirm at build)
All six engine modules under `contracts/src/supply/szipUSD/`. The keeper supplies **only scalar amounts**
(never addresses/calldata) — blast radius bounded (§8.7; `LpStrategyModule.sol:19`). Each module stores the
engine Safe as a public `juniorTrancheEngine` (getter `juniorTrancheEngine()`); token addresses are read off
the module getters (§17 re-pointable, same pattern as `BurnJob` reading `shareToken()`/`engineSafe()` off the
gate — `burn_job.go:46-66`). **Do not hard-code token addresses in Go.**

Operator legs (all `onlyOperator`, `msg.sender == operator` = the keeper key):
- **claim** — `HarvestVoteModule.claimReward()` → claims oHYDX to the Safe (`HarvestVoteModule.sol:198-200`).
  Gate view: `pendingReward() returns(uint256)` = `IGauge.earned(oHYDX, safe)`, claimable oHYDX, 18dp
  (`:239-241`). Getter `oHYDX()` for the oHYDX token address (`setOHYDX` ⇒ public field).
- **borrow** — `FarmUtilityLoopModule.borrow(uint256 usdcAmount)` → borrows USDC to the Safe via EVC
  (`:228-242`). Reverts `CapExceeded` past `borrowCap` (`:231`) and on EVC account-status if the LP_MARK is
  stale (fail-closed). Views `outstandingDebt() returns(uint256)` (`:289-290`), `postedCollateral()`
  (`:294-295`). **Collateral is assumed already posted** (persistent; `postedCollateral() > 0`); the core
  slice does NOT post/withdraw collateral per cycle. `usdc()` getter for the USDC address.
- **repay** — `FarmUtilityLoopModule.repay(uint256 usdcAmount)` (`:249`). Closes the cycle's borrow.
- **exercise** — `ExerciseModule.exercise(uint256 amount, uint256 maxPayment, uint256 deadline) returns
  (uint256 paymentAmount)` → burns `amount` oHYDX from the Safe, pulls ≤`maxPayment` USDC from the Safe,
  **mints `amount` HYDX 1:1 to the Safe** (`:178-198`, verified: `IOptionToken.exercise(amount, maxPayment,
  juniorTrancheEngine, deadline)`). Gate view `quoteStrike(uint256 amount) returns(uint256)` = the USDC
  strike (`max(getDiscountedPrice, getMinPaymentAmount)`, 6dp) (`:203-206`). `oHYDX()` getter.
- **sell** — `SellModule.sellHydx(uint256 amountIn, uint256 minOut, uint256 deadline) returns
  (uint256 amountOut)` → sells HYDX→USDC to the Safe via the Algebra `swapRouter` (`:214-221`); reverts
  `ExceedsMaxSell` if `amountIn > maxSellHydx` (`:219`). Views: public `maxSellHydx()` (`:62`), `hydx()`,
  `usdc()` getters. Router pinned (`deployer=address(0)`, `recipient=safe`, `limitSqrtPrice=0`).
- **credit + recycle** — `RecycleModule.creditFreeValue(uint256 amount)` (operator-trusted unbounded
  accumulator, `freeValueAccrued += amount`, `:241-245`); `recycle(uint256 usdcAmount) returns
  (uint256 zipMinted)` → `_spendFreeValue` then `ZipDepositModule.deposit(usdcAmount)` pulls USDC from the
  Safe, mints `usdcAmount * scaleUp` backed zipUSD to the Safe (`:263-272`). `usdc()` getter.
  **`divert` is NOT in scope** (loss-side, gated on `provision()` hole — own-later).
- **restake** — `LpStrategyModule.addLiquidity(uint256 deposit0, uint256 deposit1, uint256 minShares)
  returns (uint256 shares)` (single-sided allowed: reverts only if BOTH are 0, `:220`; reverts `Slippage` if
  `shares < minShares`, `:243`) then `stake(uint256 lpAmount)` → gauge-stakes (`:278-284`). token0 = zipUSD,
  token1 = xALPHA (read live `ichiVault().token0()/token1()`, `:113-117`); the recycled zipUSD is the
  single-sided deposit0. Views `lpBalance()`, `stakedBalance()`, `ichiVault()` getter.

Off-chain price/share seam (NOT a contract write — read-only `eth_call`s the keeper makes to size floors):
- **HYDX→USDC price** for `sellHydx` `minOut` and the taper/halt level check: per §8.7/A1, an Algebra
  QuoterV2 `quoteExactInputSingle` on the HYDX/USDC pool, floored at `quote × (1 − cushion)`. **BUILD-TIME
  VERIFY (binding #1):** the exact Algebra QuoterV2 address on Base is NOT pinned in the repo (hydrex.md §2.5
  lists only SwapRouter `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e` + NFPM). The HYDX/USDC pool
  `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2` is confirmed (token0=HYDX, token1=USDC) and exposes
  `globalState()` (`contracts/src/interfaces/algebra/IAlgebraPool.sol:20-23`, returns
  `(uint160 price/*sqrtPriceX96*/, int24 tick, uint16, uint8, uint16, bool)`). **Resolve the QuoterV2
  address; if unresolvable, bind to the pool `globalState()` sqrtPrice** (deterministic: `amountOutUsdcRaw =
  amountInHydxRaw × sqrtPriceX96² / 2¹⁹²`, the decimals are baked into the raw price token1/token0). Either
  way the address(es) come from keeper config, not on-chain. HYDX=`0x00000e7efa313F4E11Bfff432471eD9423AC6B30`,
  USDC=`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
- **zipUSD→ICHI-shares** for `addLiquidity` `minShares` (RESOLVED — the exact canonical ICHIVault `deposit()`
  share math, confirmed against the canonical ICHIVault source 2026-06-19; the same formula across all ICHI
  vaults). The keeper replicates it EXACTLY, then applies the 200bps cushion → a true lower bound (honest
  deposits pass, sandwiched/thin mints revert). For a single-sided deposit on the zipUSD side, `deposit1`
  (xALPHA side) = 0, and with `totalSupply > 0`:
  ```
  spotTick  = the LP pool globalState() current tick
  meanTick  = the LP pool TWAP-mean tick over twapPeriod (read via the oracle plugin getTimepoints — the
              EXACT logic already in contracts/src/supply/lib/IchiAlgebraFairReserves.sol:_meanTick)
  price = getQuoteAtTick(spotTick, 1e18, token0, token1)   // token1 out for 1e18 token0, at spot
  twap  = getQuoteAtTick(meanTick, 1e18, token0, token1)   // same, at the TWAP-mean tick
  (pool0, pool1) = ICHIVault.getTotalAmounts()
  depositPricedIn1 = depositZip * min(price, twap) / 1e18         // ICHI values the deposit at the WORSE price
  expectedShares   = depositPricedIn1 * totalSupply()
                     / (pool0 * max(price, twap) / 1e18 + pool1)  // and the pool at the BETTER price
  minShares = expectedShares - expectedShares*cushionBps/10000
  ```
  Token ordering is generic: the keeper reads `token0()`/`token1()` off the vault and routes the single-sided
  deposit to whichever side is zipUSD (the recycled token from `ZipDepositModule`); `getQuoteAtTick` direction
  follows the token address order (the standard UniV3 `OracleLibrary.getQuoteAtTick`: `ratioX192 =
  sqrtRatioAtTick²`; if `baseToken < quoteToken` → `mulDiv(ratioX192, baseAmount, 2¹⁹²)`, else
  `mulDiv(2¹⁹², baseAmount, ratioX192)`). **`spotTick`** is read from the Algebra pool `globalState()` (the
  2nd return field — or derive from the 1st field `sqrtPriceX96`); **`getSqrtRatioAtTick`** (TickMath) is
  ported to Go from the canonical UniV3 reference and unit-tested against known tick→sqrtRatio vectors.
  ICHI's own `deposit()` carries a `hysteresis` guard (reverts/escalates if `|spot−twap| > 1%`) — on-chain
  anti-sandwich; the keeper's `minShares` is the secondary floor. Source confirmed:
  canonical `ICHIVault.deposit` (`deposit0PricedInToken1 = deposit0·min(price,twap)/PRECISION`;
  `shares = (deposit1 + depositPricedIn1)·totalSupply/(pool0·max(price,twap)/PRECISION + pool1)`;
  `PRECISION = 1e18`; `_fetchSpot/_fetchTwap = getQuoteAtTick(tick, PRECISION, tokenIn, tokenOut)`).

Reference patterns: `cre/keeper/internal/job/burn_job.go` (the Job shape, re-pointable address reads,
fail-safe semantics), `runner_sim_test.go`/`burn_job_sim_test.go` (the sim-probe gate), `chain/read.go`
(view-read helpers), `chain/encode.go` (`PackUintCall`), `cre/buyburn-bid/workflow.go` (multi-arg ABI
packing idiom). For the price/share math: `contracts/src/interfaces/algebra/IAlgebraPool.sol` (`globalState()`),
`contracts/src/interfaces/algebra/IAlgebraOraclePlugin.sol` (`getTimepoints`),
`contracts/src/supply/lib/IchiAlgebraFairReserves.sol` (`_meanTick` — the exact mean-tick read to port),
`contracts/src/libraries/ConcentratedLiquidity.sol` (`TickMath.getSqrtRatioAtTick` — the Solidity reference
the Go port must match), and the confirmed canonical `ICHIVault.deposit` share formula (in "Binds to").

## Starting state
- `cre/keeper/` builds (KEEPER-00 spine + KEEPER-01a BurnJob shipped). `Job`/`Runner`/`Chain`/`Config`/
  `keymgr` exist. `chain` has `CallUint`, `CallUintWithAddr`, `CallBool`, `CallAddress`, `PackUintCall`,
  `Action`/`Plan`. The Runner submits a Plan **ordered + abort-on-first-error** (`job.go:82-99`).
- No multi-arg write packer yet (`PackUintCall` is single-uint256 only) — add a multi-arg packer for
  `exercise(uint256,uint256,uint256)` / `sellHydx(uint256,uint256,uint256)` /
  `addLiquidity(uint256,uint256,uint256)` (mirror `buyburn-bid/workflow.go` `abi.Arguments.Pack`).
- No no-arg→multi-return tuple decoder yet (needed for `globalState()` and `getTotalAmounts()`) — add one.
- The engine modules are built + fork-tested; their ABIs are fixed (truth source).

## Do NOT
- Do NOT introduce cross-tick keeper STATE (no EMA, no fill-history, no phase memory). The Job must be a
  pure stateless poll: every tick rebuilds the whole Plan from current reads + live quotes (B2 is an
  own-later infra decision). If a leg's realized output isn't knowable at `Evaluate` time, size it
  CONSERVATIVELY from the quote/floor (never optimistically).
- Do NOT classify regime / gate on UP-FLAT-DOWN / call `vote`/`lockVe`/`claimRebase`/`resetVote` (B1/C1–C3,
  §17-deferred). Run on a `pendingReward`/oHYDX-balance threshold, not a regime.
- Do NOT drive `commit`/`release` (main↔sidecar rotation — KEEPER-01c, the freeze rebuild).
- Do NOT call `divert` (loss-side), `postCollateral`/`withdrawCollateral` (collateral assumed persistent),
  `unstake`/`removeLiquidity` (wind-down/collateral lifecycle — not the per-cycle harvest).
- Do NOT recycle/restake depositor USDC. Only borrow-funded, HYDX-extracted USDC may be credited/recycled
  (the free-value-only invariant, §4.5.1). Borrow the FULL strike payment — never net against the Safe's
  resident USDC (which may be depositor money).
- Do NOT hard-code addresses in Go — modules from `cfg.MustAddr`, tokens read off module getters, the pool
  + QuoterV2 from config.
- Do NOT submit from `Evaluate` (it is pure read+decide; the Runner submits — `job.go` C1/K4).
- Do NOT widen the operator surface (scalars only).

## Key requirements
1. **Stateless single-Plan sizing.** `Evaluate(ctx, r)` reads current state + live quotes and returns ONE
   ordered `chain.Plan`; the Runner submits it (no `Evaluate`-time submission). Pre-compute every leg's
   scalar from current reads (later legs use the deterministic effect of earlier legs):
   - `totalOHydx = oHYDX.balanceOf(safe) + pendingReward()` (claim adds `pendingReward` oHYDX).
   - **Taper/halt (B3, level check on the live HYDX price `P = quoter.HydxPriceUsdc()`, USDC-per-1-HYDX, 6dp):**
     comparisons are STRICT `<` (boundary `P == threshold` → the higher tier). `if P < haltPrice (cfg, 15000 =
     $0.015): no-op` (accrue oHYDX, do not borrow into a dead market). `else if P < amberPrice (cfg, 18000 =
     $0.018): tapered = totalOHydx · amberFractionBps/10000` (cfg, default 5000 = 50%). `else: tapered =
     totalOHydx` (full). (The smooth "$0.033 taper" is the EMA-gated own-later refinement; the no-EMA core
     uses this explicit 2-threshold step, faithful to "a level check on the live price, no EMA/state store.")
   - `exerciseAmount = min(tapered, max(0, maxSellHydx() − hydx.balanceOf(safe)))` — taper applied to
     `totalOHydx` FIRST, then capped so `sellAmount ≤ maxSellHydx`; if 0 → no-op.
   - `strike = quoteStrike(exerciseAmount)`; `maxPayment = strike + strike·cushionBps/10000` (cushionBps=200).
   - `borrowAmount = maxPayment`, but if `maxPayment > maxBorrowPerCycle (cfg, C4)` → no-op (can't fund the
     cycle responsibly). (The on-chain `borrowCap` is the fail-safe backstop.)
   - `sellAmount = hydx.balanceOf(safe) + exerciseAmount`.
   - `quotedOut = quoter.HydxToUsdc(sellAmount)`; `minOut = quotedOut − quotedOut·cushionBps/10000`.
   - **Profit gate:** `if minOut ≤ maxPayment → no-op` (unprofitable at the conservative floor — never borrow
     to lose).
   - `conservativeNet = minOut − maxPayment` (the guaranteed-floor surplus, USDC 6dp).
   - `recycleAmount = conservativeNet · recycleFractionBps/10000 (cfg, C4 split)`; the remainder stays in the
     Safe as the working-capital reserve. If `recycleAmount == 0` → skip the recycle+restake legs (still do
     claim/borrow/exercise/sell/repay/creditFreeValue).
   - `creditAmount = conservativeNet` (credit the full guaranteed surplus; recycle spends a fraction of it).
   - `expectedZip = recycleAmount · scaleUp` (6dp→18dp; **verify scaleUp = exactly 1e12, no deposit fee**).
   - `expectedShares = quoter.ZipToShares(expectedZip)`; `minShares = expectedShares − expectedShares·
     cushionBps/10000`. If `minShares == 0` → skip restake (addLiquidity reverts on zero).
   - `stakeAmount = minShares` (conservative: addLiquidity guarantees `shares ≥ minShares`, so staking
     `minShares` always has the LP; any realized surplus stays unstaked and is picked up next cycle).
2. **Ordered Plan (the exact leg order is load-bearing):**
   `claimReward` → `borrow(borrowAmount)` → `exercise(exerciseAmount, maxPayment, deadline)` →
   `sellHydx(sellAmount, minOut, deadline)` → `repay(borrowAmount)` → `creditFreeValue(creditAmount)` →
   [`recycle(recycleAmount)` → `addLiquidity(expectedZip, 0, minShares)` → `stake(stakeAmount)`].
   The bracketed three are skipped together when `recycleAmount == 0`. **`deadline` (pinned):** the same value
   for both the `exercise` and `sell` legs (they mine within one tick) = `clock.Now().Unix() + deadlineBuffer`
   where `clock` is an injectable field on the Job (`func() time.Time`, defaults to `time.Now`; tests inject a
   fixed clock so the plan is deterministic). Do NOT use on-chain `block.timestamp` (the `Evaluate` seam is
   `chain.Reader` = read-only `CallContract`; widening it is unnecessary — a generous wall-clock buffer covers
   the seconds-to-mine, and the modules enforce the deadline on-chain). `deadlineBuffer` default 300s.
3. **No-op gates return an empty Plan (nil error), never an error** (liveness-only, fail-safe; the Runner
   logs+continues): zero `totalOHydx`; `P < haltPrice`; `exerciseAmount == 0`; `maxPayment >
   maxBorrowPerCycle`; `minOut ≤ maxPayment`. Read errors (RPC) propagate (the Runner logs+continues).
4. **Re-pointable reads every tick** (§17): re-read module getters + token addresses each `Evaluate`; do not
   cache across ticks (a Timelock re-point must take effect — `burn_job.go:40-43`).
5. **The price/share seam is injectable** so tests need no live Algebra/ICHI contracts. Define a `Quoter`
   interface, each method returning the RAW quote (the Job applies the cushion floor itself):
   - `HydxToUsdc(ctx, amountIn) (*big.Int, error)` — USDC (6dp) out for `amountIn` HYDX (18dp), from the
     HYDX/USDC pool `globalState()` sqrtPrice: `outUsdcRaw = amountInRaw·sqrtP²/2¹⁹²` (token0=HYDX/token1=USDC
     → yields 6dp directly, no extra factor). Used for `sellHydx` `minOut`.
   - `HydxPriceUsdc(ctx) (*big.Int, error)` — USDC (6dp) per ONE HYDX (= `HydxToUsdc(1e18)`), the taper/halt
     level check.
   - `ZipToShares(ctx, vault, depositZip) (*big.Int, error)` — the expected ICHI shares per the EXACT formula
     in "Binds to" above (reads the vault's `token0/token1/getTotalAmounts/totalSupply` + the LP pool spot
     tick (globalState) + TWAP-mean tick (oracle plugin getTimepoints, the `_meanTick` logic) + the ported
     `getSqrtRatioAtTick`/`getQuoteAtTick`). Used for `addLiquidity` `minShares`.
   The production impl binds to the pools + ICHI vault views via `chain.Reader`; tests inject a scripted fake.
   The ported TickMath (`getSqrtRatioAtTick`) gets its OWN unit test against known tick→sqrtRatio vectors.
6. **Config additions** (env-driven, validated; mirror `config.go` defaults→json→env→Validate). Scalar knobs
   with pinned M1 defaults (TUNABLE — C4 reviewer-flagged for later adjustment): `cushionBps`=200,
   `amberFractionBps`=5000, `haltPriceUsdc`=15000, `amberPriceUsdc`=18000, `deadlineBuffer`=300s,
   `twapPeriod`=3600s (the ICHI TWAP window for `ZipToShares`); `recycleFractionBps`=10000 (recycle all of the
   floor; the reserve is the realized−floor surplus left in the Safe). `maxBorrowPerCycle` is **required env**
   (no safe default — it bounds per-cycle exposure). Addresses (re-pointable, `KEEPER_ADDR_*`): the 6 modules
   `{HarvestVoteModule,FarmUtilityLoopModule,ExerciseModule,SellModule,RecycleModule,LpStrategyModule}`, the
   `HydxUsdcPool` (for `HydxToUsdc`), and the LP `IchiVault`'s pool is read off the vault (`pool()`), so only
   the vault address is needed — and the keeper reads it off `LpStrategyModule.ichiVault()` (no separate
   config). Validate: each referenced address non-zero (via `MustAddr`); the price thresholds satisfy
   `0 < haltPriceUsdc < amberPriceUsdc`; `cushionBps`/`amberFractionBps`/`recycleFractionBps ≤ 10000`. The
   injectable `clock` is a Job field, not config. Document each in `.env.example` + `README.md`.
7. **Registered in `cmd/keeper/main.go`** after the BurnJob (the harvest loop is the new primary job). Extend
   the startup identity check (`job.IdentityCheck`) to assert the keeper key == `operator()` on each of the
   six modules this Job drives state-changingly: `HarvestVoteModule`, `FarmUtilityLoopModule`, `ExerciseModule`,
   `SellModule`, `RecycleModule`, `LpStrategyModule` (all expose `operator()`); a wrong key fails fast at
   startup (refuse to run, §8.7).

## Done when (the gate — verified by re-run, not just the cold-build's claim)
- `go build ./...` exit 0; `go vet ./...` clean.
- A table-driven `strike_loop_job_test.go` over a scripted `chain.Reader` + fake `Quoter` asserts, per case:
  the returned `Plan` has the expected ordered `Action.Label`s and each `Action.Data` decodes to the
  correctly-sized scalar args (decode the calldata, assert the `uint256`s). Cases MUST cover: full happy path
  (all 9 legs); recycle-skipped (`recycleAmount==0` → 6 legs); each no-op gate → empty Plan; the
  `sellAmount ≤ maxSellHydx` cap; the amber-taper scaling; the profit gate.
- A `quote_test.go` asserts the price math: a scripted `globalState()` sqrtPrice → the expected `HydxToUsdc`
  (decimals correct, no 1e12 error) and `HydxPriceUsdc`; a scripted `getTotalAmounts()`/`totalSupply()` →
  the expected `ZipToShares`.
- A sim test (`strike_loop_job_sim_test.go`) deploys a single combined recorder probe (a `StrikeLoopProbe.sol`
  authored + compiled with `forge`/`solc` 0.8.24, creation bytecode pasted as a const à la
  `burn_job_sim_test.go:15`) that (a) returns scripted view values for the gate reads and (b) records the
  ordered `(selector, args)` of every state-changing call; the test seeds the views, runs the Job through the
  `Runner`, and asserts the recorded call sequence + decoded args match the expected ordered Plan. (If a
  faithful combined probe proves infeasible in-window, the unit test of `Evaluate` is the REQUIRED gate and
  the sim test may assert the Runner submits the multi-leg plan against a minimal recorder — but state the
  limitation explicitly; do not silently drop coverage.)
- Both former build-time-verify bindings are now RESOLVED in this ticket (no back-pressure): (#1) the HYDX
  price uses the pool `globalState()` sqrtPrice — the QuoterV2 address is not needed; (#2) the ICHI `minShares`
  uses the exact canonical `ICHIVault.deposit` formula pinned in "Binds to". The cold-build must confirm both
  against live source and **introduce ZERO load-bearing guesses** — if any sub-binding (e.g. the Algebra
  oracle-plugin `getTimepoints` signature, or `getSqrtRatioAtTick` reference) cannot be confirmed, fold it back
  into the ticket; do not guess.
- The Go module committed to `cre/keeper` with the gate green.

## Depends on
KEEPER-00 (spine, DONE) + KEEPER-01a (BurnJob pattern, DONE). The engine modules (8-B5…8-B10) are built +
fork-tested. No inbound cross-ticket obligation owed by KEEPER-01b. Independent of the (R) CRE workflows.
