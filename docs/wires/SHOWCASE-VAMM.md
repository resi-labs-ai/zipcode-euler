# SHOWCASE-VAMM — vAMM auto-compounder demo (wiring map)

> Source of truth = the kept code `contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol`,
> `contracts/src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol`, `contracts/src/interfaces/hydrex/IVammPair.sol`, and the deploy
> script `contracts/script/DeployShowcaseVAMM.s.sol`. This doc IS the truth (the build tickets that authored these
> forks were retired once built — lean-no-dead-artifacts). Tested: `build/anvil/smoke-path-18.md` (PASS, on anvil).

## Role
A **mainnet SHOWCASE layer — outside the audited core.** It demonstrates the auto-compounder running live against an
**existing** Hydrex venue (the **vAMM HYDX/USDC** pair + its gauge) **before** the real zipUSD/xALPHA ICHI pool + gauge
exist (those are created post-Hydrex onboarding, once the treasury funds them). Two surgical forks of verified
contracts, changed at exactly **one seam each**:
- **`SzipNavOracleDemoVAMM`** (forks `SzipNavOracle`, doc `8-B4`) — the prod oracle reverts `UnknownLpToken` on any LP
  whose reserves aren't zipUSD/xALPHA. This fork prices a **Solidly vAMM pair** instead: the LP-leg reads
  `IVammPair.getReserves()` and `_legPriceOfToken` is extended to value **HYDX** (via the already-pushed `LEG_HYDX_USD`
  CRE leg) + **USDC** ($1, 6→18dp). Everything else (CRE legs, TWAP, provision, navEntry/navExit/fresh/valueOf) is
  byte-identical.
- **`LpStrategyModuleDemoVAMM`** (forks `LpStrategyModule`, doc `8-B6`) — `addLiquidity` mints vAMM LP (transfer both
  legs to the pair → `IVammPair.mint`, routerless) instead of `IICHIVault.deposit`. `stake`/`unstake` are **unchanged**
  (the gauge interface `IGauge.deposit/withdraw(uint256)` is identical; the pair IS the LP token).

**No new Safe, no new system.** The demo module is `enableModule`'d on the **existing** engine (main) Safe alongside
the prod modules; the demo oracle reads the same Safe(s). Retire by `disableModule` + pulling the showcase LP out. The
prod oracle + modules stay wired and untouched.

## Contracts involved (what each does)
| Contract / Interface | What it does |
|---|---|
| `SzipNavOracleDemoVAMM` (`is ReceiverTemplate`) | Demo NAV oracle. Identical to `SzipNavOracle` except the LP-leg valuation (`getReserves` + HYDX/USDC pricing in `_legPriceOfToken`/`_tokenValue`). `ichiVault` slot holds the **vAMM pair** (name kept so `setLpPosition` + deploy wiring match prod). |
| `LpStrategyModuleDemoVAMM` (`is Module`, zodiac-core) | Demo LP manager. Identical to `LpStrategyModule` except `addLiquidity` (vAMM `pair.mint`). `ichiVault` slot holds the vAMM pair. |
| `IVammPair` (`src/interfaces/hydrex/IVammPair.sol`) | Minimal Solidly pair interface (the pair IS its own LP token): `mint(to)→liquidity`, `getReserves()→(r0,r1,ts)`, `token0()/token1()/totalSupply()/balanceOf()`. Verified against the live vAMM HYDX/USDC pair. |
| `DeployShowcaseVAMM` (`script/`) | Post-deploy step (run AFTER `DeployLocal`/`DeployZipcode`, as the **team**): deploy + wire the demo oracle, deploy + clone + **enable** the demo LP module on the existing Safe. |

## Wiring — internal (the diffs from prod; everything else per 8-B4 / 8-B6)
**`SzipNavOracleDemoVAMM`** — same ctor as `SzipNavOracle` `(forwarder, zipUSD, usdc, xAlpha, hydx, oHydx, juniorTrancheSafe,
juniorTrancheSidecar, W, maxAge, maxDeviationBps)`. The LP block in `grossBasketValue()` / `_grossValueOf(safe)` reads
`IVammPair(ichiVault).getReserves()` (not `IICHIVault.getTotalAmounts()`), then the same pro-rata
`amt = reserve * heldShares / supplyLp` and `_tokenValue(token, amt)`. `_legPriceOfToken` adds:
`token == hydx → legCache[LEG_HYDX_USD].price` (18-dp $/HYDX), `token == usdc → 1e30` (folds the 6→18dp scaling into
the price so `amt*price/1e18` = 18-dp USD); zipUSD/xAlpha kept (additive). Owner = deployer (team) via
`ReceiverTemplate`'s `Ownable(msg.sender)`.

**`LpStrategyModuleDemoVAMM`** — same `setUp(owner, juniorTrancheEngine, operator, ichiVault, gauge)`; `token0`/`token1` read
LIVE off the pair (`IVammPair`). `addLiquidity`: per non-zero leg `_exec(tokenN, IERC20.transfer(pair, depositN))`
then `_exec(pair, IVammPair.mint(juniorTrancheEngine))`, decode `shares`, `shares < minShares → Slippage`. **No approval**
(direct `transfer`, not `transferFrom`). `stake`/`unstake`/views unchanged (`IGauge` + `IVammPair.balanceOf`).

## Wiring — cross-component (who points at whom)
- **Both demo contracts point at the SAME live vAMM venue:** pair `0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d`
  (token0 = HYDX `0x00000e7e…`, token1 = USDC), gauge `0x2dA5744C7205ae9CacBB1AB8a72A2fA3896d39F8` (alive,
  rewardToken oHYDX). The oracle's `setLpPosition(pair, gauge)` and the module's `setUp(…, pair, gauge)` use the same.
- **Demo oracle ← the prod CRE leg feed.** Same forwarder + sealed identity (`setExpectedAuthor 0x90F7…` /
  `setExpectedWorkflowName "zip-sharefeeds"`, CTR-16 — the `workflowId` pin is dropped), so the existing reportType-7 HYDX leg push feeds `legCache[LEG_HYDX_USD]` (used to
  price the LP's HYDX reserve). It also reads the szipUSD `shareToken` + `juniorTrancheEngine` (= the prod ones).
- **Demo oracle ← `SzAlphaRateOracle` (REQUIRED — build-discovered).** `setXAlphaRateOracle(0x7251A305…)` MUST be wired
  or `grossBasketValue` reverts on the juniorTrancheSidecar's xALPHA leg (the fallback reads the mock mirror, which has no
  `exchangeRate()`). Folded into the deploy script.
- **Demo LP module → enabled on the existing engine Safe** via `enableModule` (the team-owner `execTransaction` path,
  identical to how the prod modules are enabled). operator = `creOperator`, owner = team (so the team can re-point /
  retire the showcase without a timelock dance).
- **No overlap with the prod oracle.** The vAMM LP token + gauge are DIFFERENT addresses than the prod oracle's wired
  `ichiVault` (WETH/USDC ICHI) + gauge — so the showcase position is **invisible to the prod oracle** (`grossBasketValue`
  unaffected, no `UnknownLpToken`). No isolation needed because the pair differs from prod's. (Contrast: putting the
  prod oracle's *own* WETH/USDC ICHI LP in the Safe WOULD brick it — that's the SP-06 trap; the vAMM pair avoids it.)

## Deploy facts (`DeployShowcaseVAMM.s.sol`, run after the main deploy, as the team)
- `new SzipNavOracleDemoVAMM(...)` (same ctor/params as the live prod oracle: `W=3600`, `maxAge=86400`,
  `maxDeviationBps=1000`); then `setShareToken` / `setJuniorTrancheEngine` / `setLpPosition(pair, gauge)` /
  `setXAlphaRateOracle(SzAlphaRateOracle)` / `setExpectedAuthor` / `setExpectedWorkflowName` (CTR-16).
- `_cloneModule(new LpStrategyModuleDemoVAMM(), setUp(team, juniorTrancheSafe, op, pair, gauge), juniorTrancheSafe)` via the Zodiac
  `ModuleProxyFactory` (distinct salt), then `enableModule` on the main Safe via the team's 1-of-n pre-validated
  `execTransaction` (copied verbatim from `DeployZipcode._cloneModule`/`_enableModuleOnSafe`/`_execAsTeam`).
- **Live anvil addresses (deployed 2026-06-10):** `SzipNavOracleDemoVAMM` `0xF84eF3BA83BB62C88502241B878983D79708e371`,
  `LpStrategyModuleDemoVAMM` `0xB76FfBa3d1973f61b0E2e3b09536B15283e18dFC`. (Demo addresses are NOT deterministic across
  redeploys — read them from the run log / `build/anvil/contract-map.md` "Showcase / demo".)
- **Mainnet path:** the same script with a mainnet RPC + the team key (the vAMM pair/gauge are real Base addresses).

## Gotchas
- **`setXAlphaRateOracle` is mandatory** (see cross-component) — without it the demo oracle reverts on the xALPHA leg.
- **oHYDX emission accrual is MAINNET-ONLY.** A static fork @ 47096000 runs no ve(3,3) weekly emission cycle, so the
  gauge streams nothing and a staked position earns 0 over any warp (verified on the ICHI and vAMM gauges). On live
  mainnet the gauge emits continuously and the loop compounds. The gauge custodies oHYDX **natively** (NOT Merkl —
  `getReward()`/`earned()` present, gauge holds oHYDX inventory), so `HarvestVoteModule.claimReward()` is the correct
  path; the emission-period **trigger** is a custom-Hydrex-impl detail (`notifyRewardAmount`/`Voter.distribute` revert
  from standard signatures — needs their repo / onboarding). Exercise (oHYDX→HYDX) + sell (HYDX→USDC via Algebra) are
  the prod modules, already PASS in SP-17 once oHYDX is in hand.
- **Showcase LP, not core funds.** The team intentionally seeds a small HYDX/USDC LP for the show and pulls it out
  after (`disableModule`). It is NOT part of the protocol's basket/NAV (different token/gauge than the prod oracle).
- **`ichiVault` slot name** is kept on both forks (holds the vAMM pair) purely to keep `setLpPosition` / `setUp` /
  setters / deploy wiring byte-identical to prod — do not read it as "an ICHI vault."
- **Retire cleanly at real-vault launch:** `disableModule` the demo LP module, clear the showcase LP, drop the demo
  oracle — the prod oracle/modules were never touched.
