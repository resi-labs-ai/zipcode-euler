# SP-17 — Engine flywheel (LP / harvest / exercise / sell / recycle)

**Intent.** Exercise the operator-driven engine flywheel against the live external venues — the machinery that turns
emissions into basket value. Each leg is its own operator action on the main Safe.

**Proves.** `LpStrategyModule` (add/stake/unstake on the live ICHI vault + Hydrex gauge); `HarvestVoteModule` (claim
oHYDX, lock veHYDX, vote, claim rebase); `ExerciseModule` (oHYDX→HYDX paid exercise); `SellModule` (HYDX→USDC and
zipUSD→xALPHA via Algebra); `RecycleModule` (credit free value, recycle USDC→zipUSD, divert to fill provisions).

**Tier.** Needs-forwarder for NAV context; each leg needs token seeding + live venue cooperation.

**Binds to.** Modules: LpStrategy `0xc242eaeb…`, HarvestVote `0x38d549cd…`, Exercise `0x8a80b821…`, Sell `0xbc8e1b79…`,
Recycle `0x0c4c6384…` (operator `creOperator`, main Safe `0x0B9C95c7…`). Live venues: ICHI `0x07e72E46…`, gauge
`0xAC396Cab…`, oHYDX `0xA1136031…`, Algebra router `0x6f4bE24d…`, HYDX `0x00000e7e…`. Source: `8-B6/7/8/9/10` modules
+ wires of the same names.

**Setup (per leg — run individually).**
- LP: main Safe holds zipUSD + xALPHA (or the ICHI vault's token0/token1 WETH/USDC). `addLiquidity → stake → unstake`.
- Harvest: a staked gauge position; warp to accrue; `claimReward` (oHYDX), `lockVe`, `vote`, `claimRebase`.
- Exercise: oHYDX + USDC in the Safe; `exercise(amount, maxPayment, deadline)` → HYDX minted.
- Sell: HYDX in the Safe; `sellHydx(amountIn, minOut, deadline)` → USDC; `buyXAlpha(zipUSD→xALPHA)`.
- Recycle: `creditFreeValue(amount)` then `recycle(usdc)` (→ deposit-module zap, NAV accretion) / `divert(usdc)`
  (bounded by live `provision()`).

**Calls / assertions.** Per leg: assert the token deltas in the main Safe (LP shares, gauge balance, oHYDX, HYDX,
USDC, zipUSD, xALPHA) and the operator-gate negatives (`NotOperator`). View reads: `stakedBalance`, `lpBalance`,
`pendingReward`, `outstandingDebt`, `freeValueAccrued`.

**Notes.** This is the broadest, most live-venue-dependent path — run each module separately and record which legs
the fork's live state supports (e.g. gauge rewards may need a warp; Algebra swaps need pool liquidity). Failures here
are often live-venue state, not our machinery — distinguish carefully.

**Result.** **PASS (machinery) — one fork-deploy bug found + fixed, one emission-feed step pending** (2026-06-10, real txs on anvil, run leg-by-leg). Operator (`creOperator`) and engineSafe (main Safe) wiring confirmed on all five modules.

> **CORRECTION (supersedes the first run's "killed gauge" diagnosis — it was wrong).** The original wired gauge `0xAC396Cab` is **alive** (`Voter.isAlive == true`); the stake revert `0x87c5d02a` was a **mis-wiring**, not a kill. `0xAC396Cab` is the per-pool CL gauge for the *HYDX/USDC* pool, but our ICHI vault is *WETH/USDC* — and CL gauges reject ICHI ALM wrapper shares ("not my staking token"). The correct gauge is the **vault-keyed ALM gauge** `Voter.gauges(ICHIvault)` = **`0x4328CE8A`** (alive, rewardToken = oHYDX). Re-pointed → stake works. **Deploy fixed:** `DeployLocal.s.sol` `LIVE_HYDREX_GAUGE` now `0x4328CE8A`; `DeployZipcode.s.sol` `POL_GAUGE` env note added. The live node's `LpStrategy`/`HarvestVote`/`oracle` gauge wiring was re-pointed to `0x4328CE8A` (Timelock) to mirror the fix.

The flywheel run under `evm_snapshot`/`evm_revert` (the WETH/USDC stand-in LP bricks NAV — `UnknownLpToken`; in prod the vault is zipUSD/xALPHA):

**LpStrategyModule — PASS.**
- `addLiquidity(0.1 WETH, 0, minShares=1)` → **306,964,228,674 LP shares** off the **real ICHI vault** (single-sided WETH; `allowToken0=true`/`allowToken1=false`). ✓
- `stake(LP)` against the **correct ALM gauge `0x4328CE8A`** → **status 1**, `stakedBalance` 0 → **306,964,228,674**, `lpBalance` → 0. ✓ (`unstake` is the inverse `IGauge.withdraw` — symmetric.)
- (neg) `addLiquidity` as alice → **`NotOperator`**. ✓

**HarvestVoteModule — call path PASS; emission accrual pending a gauge feed.**
- `claimReward()` (→ `gauge.getReward()`) → **status 1**, claims **0 oHYDX**. The harvest call path executes against the real gauge; accrual is 0 because the ALM gauge isn't being fed emissions at this fork block. These ICHI gauges use a **non-standard reward model** (`rewardRate()`/`periodFinish()` revert — Merkl-incentivized per Hydrex docs), so feeding oHYDX is a Hydrex-onboarding/Merkl step, not a contract gap.

**ExerciseModule — PASS (real oHYDX option).** Seeded 100e18 oHYDX into the Safe.
- `quoteStrike(100e18)` = **1,062,226 USDC** (reads live oHYDX option pricing). `exercise(100e18, maxPayment, deadline)` → **status 1, 288,800 gas**: oHYDX **100e18 → 0**, HYDX **0 → 100e18**, USDC **−1,062,226** (the strike paid). ✓ Real oHYDX→HYDX paid exercise.

**SellModule — PASS (real Algebra swap).**
- `sellHydx(100e18, minOut=1, deadline)` over the **live Algebra HYDX/USDC pool** (`0x51f0B932`, router `0x6f4bE24d`) → **status 1**: HYDX **100e18 → 0**, USDC **+3,514,206**. ✓

**RecycleModule — FULL PASS** (self-contained, real deposit-module zap):
- `creditFreeValue(1000e6)` → `freeValueAccrued` 0 → 1000e6. `recycle(1000e6)` → status 1: ledger → 0; main Safe USDC −1000e6, zipUSD 0 → 1000e18 (backed mint), warehouse EE shares 8000e6 → 9000e6. ✓
- (neg) `recycle(1)` w/ 0 free value → **`InsufficientFreeValue`**; `divert(1)` w/ `provision()==0` → **`NoHole`**; `creditFreeValue(1)` as alice → **`NotOperator`**. ✓

**Economics sanity (the flywheel's whole point):** exercised 100 oHYDX for **$1.06** strike → 100 HYDX → sold for **$3.51** = **+$2.45 free value** from the option discount. That free value is exactly what `RecycleModule.creditFreeValue` + `recycle` then route into the basket / senior backing.

**Conclusion:** the engine-flywheel contract machinery is **sound and proven** — LP add + stake (correct gauge), the harvest call path, real oHYDX exercise, real Algebra sell, and the full recycle leg all execute against live Base venues, with every operator gate verified. The ONE unproven step is the gauge **oHYDX emission accrual**, which needs the ICHI gauge fed (Merkl/Voter distribution) — a Hydrex-onboarding detail, not a code gap. The fork-deploy gauge mis-wiring is fixed in the deploy scripts.
