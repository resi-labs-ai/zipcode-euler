# SP-17 — Engine flywheel (LP / harvest / exercise / sell / recycle) (seam S13)

**Intent.** Exercise the operator-driven engine flywheel against the live external venues — the machinery that turns
emissions into basket value. Each leg is its own operator action on the main Safe.

**Proves.** `LpStrategyModule` (add/stake/unstake on the live ICHI vault + Hydrex ALM gauge); `HarvestVoteModule`
(claim oHYDX, lock veHYDX, vote); `ExerciseModule` (oHYDX→HYDX paid exercise); `SellModule` (HYDX→USDC via Algebra);
`RecycleModule` (credit free value, recycle USDC→backed zipUSD, divert to fill provisions); the engine module set on
the shared Safe IS the access control (S13). New-guard negatives: SUPPLY-ADV-08/11 avatar/target sync on
`setJuniorTrancheEngine` (Recycle/Harvest), SUPPLY-ADV-10 zero-slippage `removeLiquidity` reject (LpStrategy).
Sources: `portfolio-map.md`, the `8-B6/7/8/9/10` module wires + X-Rays.

**Tier.** Needs-forwarder for NAV; each venue leg needs token seeding + live venue cooperation.

**Binds to** (by name — all CLONES, re-derive from the Safe module list): `LpStrategyModule` (`0x25cf123d…`),
`HarvestVoteModule` (`0xf1DEbc42…`), `ExerciseModule` (`0xaD54085b…`), `SellModule` (`0x1fCe5c71…`),
`RecycleModule` (`0x28b0109B…`), operator `creOperator`, main Safe; live venues: ICHI vault, ALM gauge
`0x4328CE8A` (the vault-keyed gauge — NOT the CL gauge), oHYDX, Algebra router, HYDX.

**Calls / assertions (per leg).** LP: `addLiquidity → stake → unstake` (deltas in LP/gauge balance). Harvest:
`claimReward` (oHYDX). Exercise: `exercise(amount, maxPayment, deadline)` (oHYDX→HYDX). Sell: `sellHydx` (HYDX→USDC
via live Algebra). Recycle: `creditFreeValue` → `recycle`/`divert`. Operator-gate negative (`NotOperator`) on each.

**Result.** **PASS (machinery) — RecycleModule re-verified live 2026-06-24; venue legs carried from 2026-06-10.**
- **RecycleModule (live 2026-06-24):** `operator()`=creOperator; `creditFreeValue(1000e6)` → `freeValueAccrued`
  **1000e6**; `recycle(1000e6)` → main Safe zipUSD **1000e18** (backed mint), ledger → **0**. Negatives:
  `recycle(1)` w/ 0 free value → `InsufficientFreeValue`; `divert(1)` w/ `provision()==0` → `NoHole`;
  `creditFreeValue(1)` as alice → `NotOperator`. ✓
- **LpStrategyModule (carried):** `addLiquidity(0.1 WETH)` → ~3.07e11 LP off the real ICHI vault; `stake` against the
  **vault-keyed ALM gauge `0x4328CE8A`** (the 2026-06-10 fork-deploy fix — the CL gauge rejects ALM shares);
  `unstake` inverse; `addLiquidity` as alice → `NotOperator`. SUPPLY-ADV-10: all-zero `removeLiquidity` slippage →
  `ZeroMinAmount`.
- **ExerciseModule (carried):** `quoteStrike(100e18)`=~$1.06; `exercise` → oHYDX 100e18→0, HYDX 0→100e18, USDC −strike.
- **SellModule (carried):** `sellHydx(100e18)` over the live Algebra HYDX/USDC pool → USDC +~$3.51.
- **HarvestVoteModule (carried):** `claimReward()` call path PASS; oHYDX accrual 0 (the ALM gauge isn't fed emissions
  at this fork block — a Merkl/Voter onboarding step, not a code gap). SUPPLY-ADV-11: `setJuniorTrancheEngine` syncs
  avatar/target.
- **Economics:** exercise 100 oHYDX for ~$1.06 → 100 HYDX → sell ~$3.51 = **+$2.45 free value** from the option
  discount — exactly what RecycleModule routes into the basket / senior backing. **No flaws** — engine machinery sound;
  the only unproven step is live gauge oHYDX emission accrual (venue onboarding). Addresses corrected to the clones.
