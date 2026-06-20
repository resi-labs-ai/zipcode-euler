# Portfolio Map — `contracts/src/supply/szipUSD`

> szipUSD junior-vault engine | 14 contracts, 3,302 lines (~1,754 nSLOC) | `main` | 20/06/26

> ⚠️ **This is a portfolio triage map + drill index, not a per-contract X-Ray.** At 14 contracts / 3.3k lines, the standard X-Ray pipeline (classify every entry point, trace every invariant to a line) is ~9 module-passes of work. This report maps the subsystem — roles, surfaces, tests, churn, external trust — and **ranks which contracts to drill into with a real single-contract X-Ray.** Per-contract invariant catalogs live in the linked drill files (✅ rows / the drill list below), not here. **Drilled: 14/14 — COMPLETE.** SzipBuyBurnModule, DurationFreezeModule, ExitGate, ExerciseModule, CloneReportReceiver, HarvestVoteModule, LpStrategyModule, MastercopyInitLock, OffRampModule, RecycleModule, FarmUtilityBorrowGuard, FarmUtilityLoopModule, SellModule, SzipUSD. Every contract has a per-contract X-Ray (linked ✅ rows); every on-chain setter/mutator gap found during the sweep has been closed (incl. `SzipUSD.setGate`/ctor-zero).

---

## What this subsystem is

The szipUSD junior-vault **auto-compounder engine**: a fleet of CRE-operator-gated Zodiac **Modules** enabled on the engine/main Safe(s), orchestrating an options-yield flywheel (Hydrex oHYDX → exercise/sell/recycle), plus the user-facing token, the custody/issuance/exit gate, and a duration-squeeze solvency freeze. Same architectural DNA as the loss subsystem and the hydrex demo: **operator supplies scalars, the module builds fixed-shape calldata, the Safe executes, build-phase wiring is Timelock-re-pointable.**

## The 14 contracts

| Contract | nSLOC | ext/pub | access | tests (u/f/i) | git mods | role |
|----------|------:|:-------:|--------|:-------------:|:--------:|------|
| [**SzipBuyBurnModule**](SzipBuyBurnModule.md) ✅ | 244 | 22 | owner + operator | 52/0/0 | **12** | §7 haircut buy-and-burn BID; CoW presign + USDC approve |
| [**DurationFreezeModule**](DurationFreezeModule.md) ✅ | 199 | 25 | owner + nonReentrant×4 | 54/**1**/**1** | **11** | duration-squeeze freeze actuator; coverage-floor gate; on BOTH safes |
| [FarmUtilityLoopModule](FarmUtilityLoopModule.md) ✅ | 170 | 15 | owner + operator | 43/0/0 | 5 | 8-B5 strike-financing leverage loop (EVK/Farm utility) |
| [SellModule](SellModule.md) ✅ | 167 | 9 | owner + operator | 38/0/0 | 7 | 8-B9 market-sell swap seam (Algebra router) |
| [RecycleModule](RecycleModule.md) ✅ | 165 | 14 | owner + operator (CEI, no guard) | 42/0/0 | 7 | 8-B10 free-value ledger + spends |
| [LpStrategyModule](LpStrategyModule.md) ✅ | 165 | 13 | owner + operator | 37/0/0 | 6 | 8-B6 LP build + coverage-gate seam (ICHI) |
| [HarvestVoteModule](HarvestVoteModule.md) ✅ | 142 | 16 | owner + operator | 29/0/0 | 6 | 8-B7 harvest/vote leg (Hydrex gauge/voter/ve) |
| [ExitGate](ExitGate.md) ✅ | 133 | 9 | owner + nonReentrant×2 | 17/0/**1** | 5 | custody + issuance + exit; sole szipUSD mint/burn; Baal shaman |
| [ExerciseModule](ExerciseModule.md) ✅ | 95 | 6 | owner + operator | 30/0/0 | 5 | 8-B8 paid-exercise leg (Hydrex oHYDX) |
| [OffRampModule](OffRampModule.md) ✅ | 94 | 10 | owner + operator | 19/0/0 | 4 | zipUSD→USDC par off-ramp driver |
| [CloneReportReceiver](CloneReportReceiver.md) ✅ | 57 | 5 | owner | via consumer (8) | 1 | EIP-1167-safe CRE report-receiver base |
| [FarmUtilityBorrowGuard](FarmUtilityBorrowGuard.md) ✅ | 53 | 5 | owner | via consumer (3) | 3 | EVK GenericFactory proxy-check view |
| [SzipUSD](SzipUSD.md) ✅ | 27 | 3 | owner (gate-gated mint/burn) | via consumers | 2 | the transferable 18-dp user share token |
| [MastercopyInitLock](MastercopyInitLock.md) ✅ | 8 | 0 | — | via consumers (18) | 2 | clone mastercopy init-lock mixin |

*nSLOC totals ~1,754; the table's `access` column counts modifier *occurrences* (incl. docstrings), not distinct functions — directional, not exact.*

*✅ = a dedicated single-contract X-Ray exists (linked). Test counts for drilled contracts are current as of 2026-06-20 and include this session's gap-fills: ExitGate +1 stateful invariant + 2 path tests (15→18), ExerciseModule +3 setter tests (27→30), HarvestVoteModule +1 batch setter test (28→29), LpStrategyModule +1 batch setter test incl. SEC-15 + avatar/target sync (36→37), RecycleModule +1 batch setter test for the remaining 3 setters (41→42), FarmUtilityLoopModule +1 batch setter test for the 6 wiring setters (42→43), FarmUtilityBorrowGuard +1 admin test (2→3 guard tests), SellModule +1 batch setter test for the 6 wiring setters (37→38), SzipBuyBurnModule +1 batch setter test for the 6 wiring setters (51→52), SzipUSD +1 setGate/ctor-zero test (via ExitGate.t.sol), CloneReportReceiver's author-branch test (CTR-01 block, covered via `SzipBuyBurnModule.t.sol`). Undrilled rows are the original triage counts.*

## Clusters

- **Engine module fleet (operator-gated Zodiac Modules):** SzipBuyBurnModule, FarmUtilityLoopModule, SellModule, RecycleModule, LpStrategyModule, HarvestVoteModule, ExerciseModule, OffRampModule — the yield flywheel. All share the "operator scalars → module-built calldata → Safe exec" shape; none hold custody.
- **Solvency gate:** DurationFreezeModule — fences value across main↔sidecar Safes; gates outflow against a coverage floor (`committedValue() + pathLockedLpEquity()`), and is the coverage-gate the LP-dissolution path reads.
- **Custody + token:** ExitGate (sole minter/burner; Baal Loot↔szipUSD) + SzipUSD (the 47-line ERC-20).
- **Infrastructure:** CloneReportReceiver (CRE receiver base), MastercopyInitLock (clone init-lock), FarmUtilityBorrowGuard (EVK proxy view).

## Cross-cutting observations

- **Test posture is solid-but-shallow** (improving). Every functional contract has a real unit suite (19–54 tests). **DurationFreezeModule and ExitGate now both carry a stateful invariant** (the latter added 2026-06-20). RecycleModule (drilled) covers its ledger-conservation + SEC-09 cumulative-divert bound with deterministic boundary tests rather than a fuzzed invariant (optional, not a clear gap). The remaining stateful-fuzz consideration is on the other value-moving modules (BuyBurn, Loop), to be assessed when drilled. Of the three infra contracts with no *dedicated* test file (CloneReportReceiver, MastercopyInitLock, FarmUtilityBorrowGuard), two are heavily consumer-covered: `CloneReportReceiver`'s socket via `SzipBuyBurnModule.t.sol`'s CTR-01 block (8 tests, incl. the workflow-author branch), and `MastercopyInitLock` via 18 SEC-14 tests across all 9 engine modules (coverage-complete — see [MastercopyInitLock.md](MastercopyInitLock.md)). `FarmUtilityBorrowGuard` (drilled) has its security gate proven on the real EVK market plus its admin surface covered, via the loop suite (3 tests) — see [FarmUtilityBorrowGuard.md](FarmUtilityBorrowGuard.md).
- **ExitGate — was under-tested for its centrality; now addressed.** It is the *sole* szipUSD minter/burner and custody core; its documented two-token invariant `szipUSD.totalSupply() == loot.balanceOf(gate)` (plus zero-shares) is now under a **fuzzed stateful invariant** (`invariant_twoToken_conservation_and_zeroShares`, ~6,400 calls, 0 violations) rather than deterministic sequences alone, and the `xALPHA`-deposit + `burnFor`-underfunded paths are now covered. See [ExitGate.md](ExitGate.md).
- **Shared external trust surface** (audit each integration once, used many times): Baal (ExitGate `mintLoot`/`burnLoot`, no `ragequit` wired), CoW `GPv2Settlement` (BuyBurn presign + relayer approve), Hydrex gauge/voter/ve/option (Harvest/Exercise/Loop), ICHI (LpStrategy), EulerEarn (Freeze/warehouse), Farm utility/EVK (Loop/BorrowGuard). See `interfaces/x-ray/dependency-surface.md`.
- **Build-phase mutable wiring everywhere** — the recurring repo pattern: every module's wiring is `onlyOwner` (Timelock) re-pointable, to be re-frozen to immutable pre-prod (off-chain process). Same residual flagged in loss/ and CreditWarehouse/.
- **Single developer, high churn on the two hottest files** (BuyBurn 12, Freeze 11) — these two have absorbed the most rework and carry the most value-movement / solvency logic.

## What this map does NOT cover (be honest)

- Per-contract entry-point + invariant catalogs now exist for the **drilled** contracts (DurationFreezeModule, ExitGate, ExerciseModule, CloneReportReceiver — linked above). The undrilled rows still have only the triage-level modifier counts.
- No tracing of the flywheel's end-to-end value conservation across the 8 modules — that cross-module property is the real prize and needs a dedicated pass.

## Drill list (do these as real single-contract X-Rays, in order)

1. ✅ **SzipBuyBurnModule** — DONE → [SzipBuyBurnModule.md](SzipBuyBurnModule.md). The protocol's only exit valve; its exit-safety surface (exact discount bound, cap/killswitch, coverage path-lock, freshness + the SEC-13 leg-anchored fence) densely tested, the GPv2 uid KAT-pinned, presign fork-verified; setter gap since closed (every mutator exercised).
2. ✅ **DurationFreezeModule** — DONE → [DurationFreezeModule.md](DurationFreezeModule.md). Confirmed the floor cannot be under-frozen (128k-call stateful invariant, 0 breaches) and the LP-in-place accounting is single-counted (SEC-02). Best-tested contract in the subsystem.
3. ✅ **ExitGate** — DONE → [ExitGate.md](ExitGate.md). Added the requested `szipUSD.totalSupply() == loot.balanceOf(gate)` + zero-shares **stateful invariant** (~6,400 calls, 0 violations) and the `xALPHA`/`burnFor`-underfunded path tests; confirmed **no `ragequit` reachable** (only `mintLoot`/`burnLoot`).
4. ✅ **FarmUtilityLoopModule** — DONE → [FarmUtilityLoopModule.md](FarmUtilityLoopModule.md). The leverage loop's three borrow bounds (F1 cap/killswitch + EVK health + the guard's account-identity pin) + the full revolve all proven on the real EVK/EVC market; setter gap since closed (every wiring setter exercised).

Also drilled out of band: ✅ **ExerciseModule** → [ExerciseModule.md](ExerciseModule.md) (every mutator now tested, 30 tests), ✅ **CloneReportReceiver** → [CloneReportReceiver.md](CloneReportReceiver.md) (the CRE base; socket covered via the consumer's CTR-01 block), ✅ **HarvestVoteModule** → [HarvestVoteModule.md](HarvestVoteModule.md) (8-B7 harvest/vote; recipient pin + account-keyed statelessness proven on live Hydrex; setter gap since closed), and ✅ **LpStrategyModule** → [LpStrategyModule.md](LpStrategyModule.md) (8-B6 LP lifecycle; the coverage path-lock seam to DurationFreezeModule tested across all 3 gate states; setter gap since closed, incl. the SEC-15 owner-recheck + avatar/target sync), ✅ **MastercopyInitLock** → [MastercopyInitLock.md](MastercopyInitLock.md) (the 4-line SEC-14 init-lock mixin; coverage-complete — lock + clone-once proven by 18 consumer tests across all 9 engine modules), ✅ **OffRampModule** → [OffRampModule.md](OffRampModule.md) (zipUSD→USDC par off-ramp driver; destination integrity + par NAV-neutrality proven on a full real-queue fork cycle; no setter gap), ✅ **RecycleModule** → [RecycleModule.md](RecycleModule.md) (8-B10 free-value ledger — the only stateful engine module; the SEC-09 cumulative divert bound + two-layer free-value enforcement well-tested; setter gap since closed), ✅ **FarmUtilityBorrowGuard** → [FarmUtilityBorrowGuard.md](FarmUtilityBorrowGuard.md) (EVK OP_BORROW hook; the account-identity borrow gate proven on the real EVK market; admin surface — incl. the borrow-allowlist `setJuniorTrancheEngine` + raw-msg.sender onlyOwner — since covered), and ✅ **SellModule** → [SellModule.md](SellModule.md) (8-B9 swap leg; recipient/pair pin + the `maxSellHydx` size cap + slippage/deadline abort proven on the real Algebra router; setter gap since closed).

14 of 14 drilled — the sweep is complete, and **every on-chain coverage gap found has been closed** (no outstanding setter/mutator gap across the subsystem). The fleet modules all confirmed the pattern (destination-pinned, bubbling exec, operator-sizes-only); the infra contracts (CloneReportReceiver, MastercopyInitLock, FarmUtilityBorrowGuard, SzipUSD) are consumer-covered with their security-relevant surfaces tested. Per-contract verdicts: 2 "a hair from HARDENED" (DurationFreezeModule, SzipBuyBurnModule — ExitGate after its invariant too), the rest ADEQUATE; all capped below HARDENED only by off-chain/process residuals + no external audit.
