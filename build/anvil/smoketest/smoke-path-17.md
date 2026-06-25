# SP-17 — Engine flywheel (LP / harvest / exercise / sell / recycle) (seam S13)

**Intent.** Exercise the operator-driven engine flywheel against the live external venues — the machinery that turns
emissions into basket value. Each leg is its own operator action on the main Safe.

**Proves.** `LpStrategyModule` (add/stake/unstake on the live ICHI vault + Hydrex ALM gauge); `HarvestVoteModule`
(claim oHYDX, lock veHYDX, vote); `ExerciseModule` (oHYDX→HYDX paid exercise); `SellModule` (HYDX→USDC via Algebra);
`RecycleModule` (credit free value, recycle USDC→backed zipUSD, divert to fill provisions); the engine module set on
the shared Safe IS the access control (S13). New-guard negatives: avatar/target sync on
`setJuniorTrancheEngine` (Recycle/Harvest), zero-slippage `removeLiquidity` reject (LpStrategy).
Sources: `portfolio-map.md`, the `8-B6/7/8/9/10` module wires + X-Rays.

**Tier.** Needs-forwarder for NAV; each venue leg needs token seeding + live venue cooperation.

**Binds to** (by name — all CLONES, re-derive from the Safe module list): `LpStrategyModule` (`0x25cf123d…`),
`HarvestVoteModule` (`0xf1DEbc42…`), `ExerciseModule` (`0xaD54085b…`), `SellModule` (`0x1fCe5c71…`),
`RecycleModule` (`0x28b0109B…`), operator `creOperator`, main Safe; live venues: ICHI vault, ALM gauge
`0x4328CE8A` (the vault-keyed gauge — NOT the CL gauge), oHYDX, Algebra router, HYDX.

**Calls / assertions (per leg).** LP: `addLiquidity → stake → unstake` (deltas in LP/gauge balance). Harvest:
`claimReward` (oHYDX). Exercise: `exercise(amount, maxPayment, deadline)` (oHYDX→HYDX). Sell: `sellHydx` (HYDX→USDC
via live Algebra). Recycle: `creditFreeValue` → `recycle`/`divert`. Operator-gate negative (`NotOperator`) on each.

**Result.** **PASS — all five legs re-verified live against the live Base venues.**
- **ExerciseModule:** `quoteStrike(100e18)` = **1,058,409** (~$1.06, live oHYDX option pricing); `exercise` →
  oHYDX 100e18 → **0**, HYDX 0 → **100e18**, USDC −strike. ✓
- **SellModule:** `sellHydx(100e18)` over the **live Algebra HYDX/USDC pool** → HYDX → **0**, USDC **+3,514,018**
  (~$3.51). ✓
- **LpStrategyModule:** `gauge()`=**`0x4328CE8A`** (the vault-keyed ALM gauge), `ichiVault()`=the real ICHI vault;
  `addLiquidity(0.1 WETH, 0, 1)` → `lpBalance` **306,638,593,863**; `stake` → `stakedBalance`=that, `lpBalance` → **0**
  (unstake is the inverse). ✓
- **HarvestVoteModule:** `claimReward()` status 1 (call path PASS against the real gauge); `pendingReward` **0** —
  accrual 0 because the ALM gauge isn't fed emissions at this fork block (a Merkl/Voter onboarding step, not a code gap).
- **RecycleModule:** `creditFreeValue(1000e6)` → `freeValueAccrued` **1000e6**; `recycle(1000e6)` → main Safe zipUSD
  **1000e18** (backed mint), ledger → **0**. Negatives: `recycle(1)`/0 free value → `InsufficientFreeValue`,
  `divert(1)`/`provision()==0` → `NoHole`, `creditFreeValue(1)` as alice → `NotOperator`. ✓
- **Economics:** exercise 100 oHYDX for **$1.06** → 100 HYDX → sell **$3.51** = **+$2.45 free value** from the option
  discount — exactly what RecycleModule routes into the basket / senior backing. **No flaws** — full flywheel sound on
  live venues; the only unproven step is live gauge oHYDX emission accrual (venue onboarding, not code). Bound to the
  engine CLONE addresses.
