# Hydrex demo-fork group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first. This file is the map.

Mirrors `contracts/src/hydrex-demo-fork/`. Two contracts, **3 missions each**.

| Contract | nSLOC | Missions | Surfaces |
|---|---:|---:|---|
| `lpstrategymoduledemovamm/` | 129 | 3 | vAMM-mint seam (diff vs ICHI parent) · operator-grief/blast-radius · clone-lifecycle/wiring |
| `szipnavoracledemovamm/` | 294 | 3 | spot-`getReserves()` LP valuation + TWAP bracket · NAV-accounting/donation/provision · CRE-push/freshness/rate-seam |

## The differential is unusual here — diff against the contract's OWN prod parent
Unlike the bridge group (diffed vs an external audited repo, Rubicon), these are **forks of audited prod
contracts with ONE seam swapped each** (ICHI → Solidly vAMM). The "supposed to be" baseline is therefore
the prod parent itself:
- `lpstrategymoduledemovamm` ← `contracts/src/supply/szipUSD/LpStrategyModule.sol` (swap: LP-mint seam)
- `szipnavoracledemovamm` ← `contracts/src/supply/SzipNavOracle.sol` (swap: LP-leg valuation)

A finding is either (1) the seam swap **dropped a guard the audited parent had**, or (2) it **introduced
behavior the parent never handled** — Solidly `mint` donate-excess (LP module) / spot-`getReserves()`
in-block manipulability (oracle). The swapped-seam interface is `contracts/src/interfaces/hydrex/IVammPair.sol`.

## Scope caveat (carry into every synthesis)
Both self-declare **DEMO/SHOWCASE, outside the audited core**. They ARE deployed on mainnet
(`DeployShowcaseVAMM.s.sol`) against a live HYDX/USDC vAMM, so real (small) value flows — but findings are
**demo-scoped**, and several NAV-hub residuals (raw-balance donation seam, in-block spot-LP, unbounded
provision) are **inherited from the prod design, not introduced by the fork**. Every finding must label
itself *fork-introduced* vs *prod-inherited* — the panel's job on inherited ones is to confirm the
bracket/gate actually fences them, not to re-report them.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅
(`contracts/src/hydrex-demo-fork/x-ray/`). Each mission's `context.files` inlines the contract + its prod
parent + `IVammPair` + the ported test suite for non-agentic (Fugu) panelists.
