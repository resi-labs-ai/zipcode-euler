# SP-18 — vAMM auto-compounder showcase (demo oracle + demo LP module)

**Intent.** Show the auto-compounder running on a mainnet venue BEFORE the real zipUSD/xALPHA pool exists: a demo NAV
oracle prices a live vAMM HYDX/USDC LP (which the prod oracle can't — it only prices zipUSD/xALPHA reserves), and a
demo LP module is enabled on the SAME engine Safe alongside the prod modules.

**Proves.** `SzipNavOracleDemoVAMM` prices the live vAMM HYDX/USDC LP (HYDX via the pushed `LEG_HYDX_USD`, USDC $1,
6→18dp); `LpStrategyModuleDemoVAMM` (`addLiquidity` = `pair.mint`; stake/unstake on the vAMM gauge) enabled on the main
Safe via Zodiac; surgical forks of the verified NAV oracle + LP module with ONLY the LP-leg seam changed (HYDREX-ADV-01
restored the 3 audited guards the demo NAV fork had dropped; HYDREX-ADV-02 restored MastercopyInitLock). Sources:
`docs/SHOWCASE-VAMM.md` (a.k.a. `build/wires/SHOWCASE-VAMM.md`), `contracts/src/hydrex-demo-fork/x-ray/`.

**Tier.** Demo (outside the audited core). Deployed by `DeployShowcaseVAMM.s.sol` AFTER the main deploy.

**Binds to** (by name): `SzipNavOracleDemoVAMM` (`0xD74712fF…` this board — mastercopy/instance), `LpStrategyModuleDemoVAMM`
**clone** (`0x8f18E9Fd…`, enabled on the main Safe; mastercopy `0x17627cbb…`), vAMM HYDX/USDC pair (LP), vAMM gauge
(vault-keyed, rewards oHYDX), main Safe, operator `creOperator`.

**Setup.** Push the demo NAV leg (`LEG_HYDX_USD`); seed the Safe with the vAMM pair's tokens (HYDX/USDC).

**Calls / assertions.** Demo oracle: `spotNavPerShare()` prices the held vAMM LP slice at the pushed HYDX price + $1
USDC. Demo LP module: `addLiquidity` (= `pair.mint`) → LP shares; `stake`/`unstake` on the vAMM gauge; operator-gate
negative (`NotOperator`). Assert the LP/gauge balance deltas in the main Safe and that the demo oracle's NAV reflects
the LP.

**Notes.** Retire by `disableModule` + pulling the LP out. The demo proves the auto-compounder loop on a real live
venue with only the LP-leg swapped — it does NOT ship as core. The vAMM pair/gauge are existing live Base contracts.

**Result.** **PASS (wiring live 2026-06-24; mechanics carried from 2026-06-10).**
- `SzipNavOracleDemoVAMM` (`0xD74712fF…`) deployed + code present; demo `spotNavPerShare()` reads (genesis surface). ✓
- `LpStrategyModuleDemoVAMM` **clone `0x8f18E9Fd…` is `enableModule`'d on the main Safe** (`isModuleEnabled==true`),
  `operator()` = `creOperator` — running alongside the prod engine modules on the same Safe. ✓
- The `addLiquidity`=`pair.mint` / stake / unstake legs against the live vAMM pair + gauge were proven 2026-06-10; the
  demo fork's source is unchanged this cycle (HYDREX-ADV-01/02 guards restored). **No flaws** — addresses corrected to
  the current showcase deploy (the demo contracts move every redeploy with the team nonce; re-derive from the showcase
  broadcast). **Outside the audited core.**
