# SP-18 — vAMM auto-compounder showcase (demo oracle + demo LP module on the existing Safe)

**Intent.** Prove the mainnet-showcase forks work end-to-end on the existing engine Safe: the demo LP module builds +
stakes a live **vAMM HYDX/USDC** position, and the demo NAV oracle **prices** that LP (which the prod oracle can't),
with the prod oracle + Safe untouched. This is the artifact that demos the auto-compounder live (to unlock the
treasury for the real zipUSD/xALPHA vault).

**Proves.** `LpStrategyModuleDemoVAMM.addLiquidity` (vAMM `pair.mint`, no router) → `stake`/`unstake` (the standard
gauge, unchanged) ; `SzipNavOracleDemoVAMM.grossBasketValue` pricing the staked vAMM LP via `getReserves()` + the
HYDX (CRE leg) / USDC ($1, 6→18dp) legs ; the module enabled on the **existing** main Safe alongside the prod modules ;
**no contamination** of the prod oracle (the vAMM LP is a different token+gauge than it reads) ; operator gating.

**Tier.** Demo/showcase (run after `DeployShowcaseVAMM.s.sol`). Needs the demo oracle's HYDX leg pushed (reportType 7).

**Binds to.** `SzipNavOracleDemoVAMM` `0xF84eF3BA…`, `LpStrategyModuleDemoVAMM` `0xB76FfBa3…`, main Safe `0x0B9C95c7…`,
vAMM pair `0x605abD18…`, vAMM gauge `0x2dA5744C…`, HYDX `0x00000e7e…`, USDC, the prod `SzipNavOracle` `0x0C3E7731…` (the
contrast). Source: `contracts/src/hydrex-demo-fork/*`, `script/DeployShowcaseVAMM.s.sol`; tickets `build/wires/SHOWCASE-VAMM.md`.

**Setup.**
- Showcase deployed + registered (`DeployShowcaseVAMM.s.sol`): demo LP module `enableModule`'d on the main Safe; demo
  oracle wired (LP position → the vAMM pair+gauge, `xAlphaRateOracle` → `SzAlphaRateOracle`, CRE identity sealed).
- Push the HYDX/alphaUSD legs to the **demo** oracle (reportType 7, impersonated Forwarder) so `legCache[HYDX]` is set.
- Deal HYDX + USDC to the Safe at the live reserve ratio (≈169833e18 HYDX : 5985e6 USDC).

**Calls (run under `evm_snapshot`/`evm_revert` so the showcase LP isn't left in the Safe).**
1. `addLiquidity(hydx, usdc, minShares=1) as creOperator` → vAMM LP minted to the Safe.
2. `stake(lp) as creOperator` → into the vAMM gauge.
3. `grossBasketValue()` on the demo oracle (LP staked) vs with the same HYDX+USDC loose → assert ≈ equal.
4. `grossBasketValue()` on the **prod** oracle → unaffected (it reads a different vault+gauge).
5. `unstake(lp)`. (negative) `addLiquidity as alice` → `NotOperator`.

**Assertions.** Inline; the value-conservation identity (step 3) is the key check that the LP is priced correctly.

**Notes.** Harvest/exercise/sell are the same prod modules already PASS'd in SP-17 (exercise oHYDX→HYDX, sell HYDX→USDC
on the live Algebra pool). **oHYDX emission accrual is mainnet-only** — a frozen fork @ 47096000 runs no ve(3,3)
emission cycle, so a staked position earns 0; on live mainnet the gauge streams oHYDX and the loop compounds. The
gauge custodies oHYDX natively (not Merkl), so `claimReward`/`getReward` is the correct path; the emission-period
trigger itself is a custom-Hydrex-impl detail (their repo / onboarding).

**Result.** **PASS** (2026-06-10, real txs on anvil, under snapshot).

Build-discovered fix (folded into `DeployShowcaseVAMM.s.sol`): the demo oracle initially **reverted**
`grossBasketValue` because its `xAlphaRateOracle` was unwired → `_xAlphaUSD` fell back to the mock xALPHA mirror (no
`exchangeRate()`), and the sidecar holds 400e18 xALPHA (SP-11). Wired `setXAlphaRateOracle(SzAlphaRateOracle)` (the
deploy script + the live instance) → grossBasketValue works.

Calls & deltas (all ✓):
1. Pushed HYDX leg to the demo oracle → `legCache[HYDX].price` = **5e16**.
2. `addLiquidity(3396e18 HYDX, 119.68e6 USDC, 1)` → status 1, **636,831,083,443,467 vAMM LP** minted (real `pair.mint`).
3. `stake(LP)` → `stakedBalance` **636,831,083,443,467**, `lpBalance` → 0 (the standard vAMM gauge accepts it).
4. **Demo oracle prices the LP — value conserved:** gross with HYDX+USDC **loose** = `81689480000000000000000`; gross
   with the same value as the **staked LP** = `81689477675484489717909` → **delta = −0.0000023 USD** (donated-excess
   rounding). The LP block (`getReserves()` × held/supply, HYDX+USDC priced) values the position *exactly* as its
   underlyings. No revert. ✓
5. **Prod oracle unaffected:** `SzipNavOracle.grossBasketValue()` = **81,400e18**, no revert — the vAMM LP token
   (`0x605abD18`) + gauge (`0x2dA5744C`) are NOT what the prod oracle reads (its `ichiVault`/`gauge` are the WETH/USDC
   ICHI + its ALM gauge), so the showcase position is invisible to it. **No contamination** — contrary to the earlier
   worry, using a *different* pair than the prod oracle's means the showcase never needs isolation. ✓
6. `unstake(LP)` → `stakedBalance` 0, LP back. ✓ (negative) `addLiquidity as alice` → **`NotOperator` (0x7c214f04)**. ✓

No flaws. The showcase machinery works: the demo LP module builds+stakes a real live vAMM position through the
existing Safe, the demo oracle prices it exactly, and the prod oracle/Safe/modules are untouched. The only mainnet-only
piece is oHYDX accrual (the live emission stream), which makes the loop compound — the whole point of showing it on
mainnet.
