# Portfolio Map — `contracts/src/supply/szipUSD`

> szipUSD junior-vault engine | 14 contracts, 3,302 lines (~1,754 nSLOC) | `main` | 20/06/26

> ⚠️ **This is a portfolio triage map, not a per-contract X-Ray.** At 14 contracts / 3.3k lines, the standard X-Ray pipeline (classify every entry point, trace every invariant to a line) is ~9 module-passes of work. This report maps the subsystem — roles, surfaces, tests, churn, external trust — and **ranks which contracts to drill into with a real single-contract X-Ray.** It does NOT contain per-contract invariant catalogs. Treat the "drill list" at the bottom as the actual next step.

---

## What this subsystem is

The szipUSD junior-vault **auto-compounder engine**: a fleet of CRE-operator-gated Zodiac **Modules** enabled on the engine/main Safe(s), orchestrating an options-yield flywheel (Hydrex oHYDX → exercise/sell/recycle), plus the user-facing token, the custody/issuance/exit gate, and a duration-squeeze solvency freeze. Same architectural DNA as the loss subsystem and the hydrex demo: **operator supplies scalars, the module builds fixed-shape calldata, the Safe executes, build-phase wiring is Timelock-re-pointable.**

## The 14 contracts

| Contract | nSLOC | ext/pub | access | tests (u/f/i) | git mods | role |
|----------|------:|:-------:|--------|:-------------:|:--------:|------|
| **SzipBuyBurnModule** | 244 | 22 | owner + operator | 50/0/0 | **12** | §7 haircut buy-and-burn BID; CoW presign + USDC approve |
| **DurationFreezeModule** | 199 | 25 | owner + nonReentrant×4 | 54/**1**/**1** | **11** | duration-squeeze freeze actuator; coverage-floor gate; on BOTH safes |
| ReservoirLoopModule | 170 | 15 | owner + operator | 41/0/0 | 5 | 8-B5 strike-financing leverage loop (EVK/Reservoir) |
| SellModule | 167 | 9 | owner + operator | 37/0/0 | 7 | 8-B9 market-sell swap seam (Algebra router) |
| RecycleModule | 165 | 14 | owner + operator + nonReentrant | 41/0/0 | 7 | 8-B10 free-value ledger + spends |
| LpStrategyModule | 165 | 13 | owner + operator | 36/0/0 | 6 | 8-B6 LP build + coverage-gate seam (ICHI) |
| HarvestVoteModule | 142 | 16 | owner + operator | 28/0/0 | 6 | 8-B7 harvest/vote leg (Hydrex gauge/voter/ve) |
| ExitGate | 133 | 9 | owner + nonReentrant×2 | **15**/0/0 | 5 | custody + issuance + exit; sole szipUSD mint/burn; Baal shaman |
| ExerciseModule | 95 | 6 | owner + operator | 27/0/0 | 5 | 8-B8 paid-exercise leg (Hydrex oHYDX) |
| OffRampModule | 94 | 10 | owner + operator | 19/0/0 | 4 | zipUSD→USDC par off-ramp driver |
| CloneReportReceiver | 57 | 5 | owner | **none** | 1 | EIP-1167-safe CRE report-receiver base |
| ReservoirBorrowGuard | 53 | 5 | owner | **none** | 3 | EVK GenericFactory proxy-check view |
| SzipUSD | 27 | 3 | owner (gate-gated mint/burn) | **none** | 2 | the transferable 18-dp user share token |
| MastercopyInitLock | 8 | 0 | — | **none** | 2 | clone mastercopy init-lock mixin |

*nSLOC totals ~1,754; the table's `access` column counts modifier *occurrences* (incl. docstrings), not distinct functions — directional, not exact.*

## Clusters

- **Engine module fleet (operator-gated Zodiac Modules):** SzipBuyBurnModule, ReservoirLoopModule, SellModule, RecycleModule, LpStrategyModule, HarvestVoteModule, ExerciseModule, OffRampModule — the yield flywheel. All share the "operator scalars → module-built calldata → Safe exec" shape; none hold custody.
- **Solvency gate:** DurationFreezeModule — fences value across main↔sidecar Safes; gates outflow against a coverage floor (`committedValue() + pathLockedLpEquity()`), and is the coverage-gate the LP-dissolution path reads.
- **Custody + token:** ExitGate (sole minter/burner; Baal Loot↔szipUSD) + SzipUSD (the 47-line ERC-20).
- **Infrastructure:** CloneReportReceiver (CRE receiver base), MastercopyInitLock (clone init-lock), ReservoirBorrowGuard (EVK proxy view).

## Cross-cutting observations

- **Test posture is solid-but-shallow.** Every functional contract has a real unit suite (15–54 tests), but **only DurationFreezeModule has fuzz + invariant** tests. For a math/accounting-heavy flywheel, the absence of stateful fuzz on the value-moving modules (BuyBurn, Recycle, Loop) is the main test gap. Three infra contracts have no dedicated tests (CloneReportReceiver, MastercopyInitLock, ReservoirBorrowGuard) — small, but `CloneReportReceiver` is the CRE entry base for clones and deserves coverage.
- **ExitGate is under-tested relative to its centrality.** It is the *sole* szipUSD minter/burner and the custody core, yet has the **fewest unit tests (15)** of any functional contract. Its documented two-token invariant — `szipUSD.totalSupply() == loot.balanceOf(gate)` — is the kind of property that wants an invariant test and currently has none.
- **Shared external trust surface** (audit each integration once, used many times): Baal (ExitGate `mintLoot`/`burnLoot`, no `ragequit` wired), CoW `GPv2Settlement` (BuyBurn presign + relayer approve), Hydrex gauge/voter/ve/option (Harvest/Exercise/Loop), ICHI (LpStrategy), EulerEarn (Freeze/warehouse), Reservoir/EVK (Loop/BorrowGuard). See `interfaces/x-ray/dependency-surface.md`.
- **Build-phase mutable wiring everywhere** — the recurring repo pattern: every module's wiring is `onlyOwner` (Timelock) re-pointable, to be re-frozen to immutable pre-prod (off-chain process). Same residual flagged in loss/ and CreditWarehouse/.
- **Single developer, high churn on the two hottest files** (BuyBurn 12, Freeze 11) — these two have absorbed the most rework and carry the most value-movement / solvency logic.

## What this map does NOT cover (be honest)

- No per-contract entry-point classification (permissionless vs role-gated) beyond the modifier counts above.
- No per-contract invariant catalog. The only invariants noted are the two I read directly (ExitGate two-token; Freeze coverage floor).
- No tracing of the flywheel's end-to-end value conservation across the 8 modules — that cross-module property is the real prize and needs a dedicated pass.

## Drill list (do these as real single-contract X-Rays, in order)

1. **SzipBuyBurnModule** — #1 churn (12), largest module (244 nSLOC), and the **value-out path**: it `approve`s the CoW vault relayer and presigns orders (`setPreSignature`). Highest-leverage single-contract X-Ray in this folder. Hook: `vaultRelayer`/`domainSeparator` read in `setUp:208`, order fields are the only operator input (`GPv2OrderInput:133`).
2. **DurationFreezeModule** — #2 churn (11), the **solvency floor** that gates all junior outflow (`coverageValue() = committedValue() + pathLockedLpEquity()`; `release` coverage-gated). Already has fuzz+invariant — drill to confirm the floor cannot be under-frozen and the LP-in-place accounting is exact.
3. **ExitGate** — the custody/mint/burn core with the **two-token conservation invariant** and the **fewest tests**. Drill + add an invariant test for `szipUSD.totalSupply() == loot.balanceOf(gate)`. Baal shaman power (`mintLoot`/`burnLoot`); confirm no `ragequit` path is reachable.
4. **ReservoirLoopModule** — leverage loop (EVK borrow); leverage + external lending market = the remaining high-consequence module.

Everything below the top 4 (Sell/Recycle/Harvest/Exercise/OffRamp) is the same well-understood module shape and can be batch-reviewed against the fleet pattern once a representative (BuyBurn) is fully X-Rayed.
