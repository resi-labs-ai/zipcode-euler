# zipcode-euler — Run C: interconnection pass (money-flows traced end-to-end across contracts)

_6 parallel agents, each tracing one money-flow across every contract it touches — focus on the
hand-offs between contracts, not contracts in isolation. This pass found bugs that live only in the
seams, and escalated the xALPHA-rate issue to HIGH by tracing its full cross-chain propagation._

## HIGH

### C1 — xALPHA rate freshness gate is wired into issuance only, NOT into the coverage/exit/release path
- **flow:** bridge → rate → NAV → coverage. **contracts:** `SzAlphaRateOracle` → `SzipNavOracle._xAlphaUSD`/`grossBasketValue`/`navExit`/`committedValue`/`pathLockedLpEquity` → `DurationFreezeModule.coverageValue`/`covered`/`release` → `SzipBuyBurnModule`/`LpStrategyModule`.
- **location:** `SzipNavOracle.sol:508-514` (`_xAlphaUSD`, no freshness) vs `:476,492` (gate exists only in `navEntry`/`fresh`); `DurationFreezeModule.sol:319-321,344-360,405-423`.
- **class:** cross-chain rate-lag / freshness-gate-bypass · **severity: HIGH · confidence: high** (escalation of #6 / R2)
- **invariant_broken:** §4.8 "`release` cannot drop coverage below the senior liability floor"; §4.10 "consumers fail-closed on staleness via `fresh()`."
- **interaction:** the freeze floor `requiredCommittedValue()` is **rate-independent** (USDC from EulerEarn), but `coverageValue()` is **rate-dependent** (xALPHA sidecar balance + the zipUSD/xALPHA LP leg, both via `_xAlphaUSD`). The `StaleRate`/`fresh()` gate is absent from this path. So during the cross-chain push lag after a validator slash (the rate oracle is strictly-newer + no deviation band, so the stale-HIGH rate is served until the next push) — or whenever the rate is 0 (never-pushed) — `coverageValue` is over-stated, `covered()` returns true, and `release` opens the freeze hatch (rotates committed xALPHA/LP into the exit-reachable main Safe) and buy-burn/LP-dissolution proceed **below the true floor**. The TWAP-lag defense the spec relies on does not protect against an *upward-stale* rate feeding exit. This is the rate version of the coverage-floor break, with the full 964→Base→NAV→coverage path traced.
- **fix:** gate every `_xAlphaUSD` consumer (or `covered()`/`release()`) on `xAlphaRateOracle.fresh()`; treat `exchangeRate()==0` as fail-closed.

## MEDIUM

### C2 — `RecycleModule.divert` has no cumulative tally vs `provision()` → the same default markdown can be over-filled across calls
- **flow:** loss waterfall. **contracts:** `RecycleModule` ↔ `SzipNavOracle.provision` ↔ `DefaultCoordinator`.
- **location:** `RecycleModule.sol:285-310`; `SzipNavOracle.sol:304-309`; `DefaultCoordinator.sol:230-261`.
- **class:** cross-contract accounting double-count · **severity: MED · confidence: med**
- **invariant_broken:** §6 "`divert` bounded by `provision()` … can never over-fill it" — true per-call, **false across calls.**
- **interaction:** a default writes `provision = P`; `divert(P)` pushes P of junior free-value into the senior pool but does **not** reduce `provision` (by design) and stores no record. A later `divert(P)` reads the same unchanged `provision()=P` and passes again. Across N calls, up to N×P of junior equity drains into senior backing for a single P markdown. Operator-trusted (grief, not theft), but a genuine seam gap — neither contract debits the consumed portion. **fix:** cumulative `divertedAgainst[hole]` tally, or have `divert` reduce `provision`.

### C3 — `_resolve` heals the full junior provision with no realized-receipt bound (unlike `_recovery`)
- **flow:** loss waterfall. **contracts:** `DefaultCoordinator._resolve` ↔ `SzipNavOracle.writeProvision`.
- **location:** `DefaultCoordinator.sol:267-281` (vs `_recovery` `:249-261`).
- **class:** cross-contract accounting desync · **severity: MED · confidence: med**
- **interaction:** `_recovery` reduces provision by `min(provision, recoveryProceeds)` — bounded by realized receipts. `_resolve` instead zeroes the entire remaining provision **unconditionally**, then routes an *independent* CRE-supplied `capitalSlashAmount` (possibly 0). So a RESOLVE can mark junior NAV-per-share **up by the full provision** while no realized recovery enters the basket — and a minter/exiter transacting across the `writeProvision` captures the unsmoothed mark-up asymmetrically. The two heal paths diverge in a way §6 doesn't document as intentional.

### C4 — RT2 additional-draw re-seed overwrites a fresher revaluation, and the very next borrow reads exactly that seeded mark
- **flow:** venue credit lifecycle. **contracts:** `ZipcodeController._draw` → `ZipcodeOracleRegistry.seedPrice` → per-line `EulerRouter` → EVK account-status check.
- **location:** `ZipcodeController.sol:215-230`; `ZipcodeOracleRegistry.sol:106-110,127-133,147-161`; `EulerVenueAdapter.sol:298-334`.
- **class:** cross-contract mark-read ordering · **severity: MED · confidence: high (mechanism)** — the draw-path manifestation of the registry no-monotonic-guard (#1).
- **interaction:** CRE pushes an RT3 revaluation marking lien `L` DOWN. An RT2 additional-draw then calls `seedPrice(L, equityMark)`, which overwrites `cache[L]` unconditionally (no monotonic/deviation guard) at `block.timestamp`. The immediately-following `draw`'s `evc.batch(borrow)` end-of-call status check resolves the frozen router → registry `_getQuote`, reading exactly the just-seeded mark — **discarding the fresher down-revaluation and sizing the borrow against the controller-seeded value.** The registry has no on-chain backstop to catch the inconsistency.

## LOW / observations
- **C-L1 — reservoir borrow double-counts dollars against junior coverage.** A harvest `borrow` both lowers `pathLockedLpEquity` (via reservoir `debtOf`) AND raises the coverage floor (via the EulerEarn `maxWithdraw` drop, since the reservoir vault IS the warehouse pool) → the loop can self-brick `covered()` for the epoch. Conservative/fail-closed direction. `SzipNavOracle.sol:386-390`, `DurationFreezeModule.sol:328-360`.
- **C-L2 — `freeValue()` desyncs from `gross − coverageValue`.** The module presents two incompatible partitions of gross (freeValue subtracts sidecar LP once; coverageValue adds it twice), so at the senior-squeeze edge `covered()` can read true while `freeValue` still shows an exitable slice. `DurationFreezeModule.sol:304-321,344-351`.
- **C-L3 — szipUSD issuance is decoupled from EE share value; zipUSD is hard-marked $1.** `depositFor` prices szipUSD off the face $1 of freshly-minted zipUSD (`SzipNavOracle.sol:525`), not the realized EE-share value. Atomic/safe today (mint is capacity-gated), but if zipUSD ever de-pegs from its warehouse backing, junior shares over-issue. Documented "$1 utility dollar" trust seam — the one place deposit value-conservation rests on an off-NAV invariant. `ZipDepositModule.sol:139-146`.
- **C-L4 — USDC→eePool approval not reset after zap/deposit** (asymmetric with the carefully-reset zipUSD→gate approval); latent residual-value/approval surface if EE ever pulls < `usdcIn`. `ZipDepositModule.sol:120-121,142-143`.

## Verified sound across the seams (negative results)
- **Deposit/zap:** value-conserving and reentrancy-safe end-to-end — warehouse (EE shares) and basket (Safes) are cleanly partitioned (in-flight deposit never double-counted), NAV is read before the zipUSD lands, the two-token mint pair is atomic, and `depositFor` is `nonReentrant` with no attacker callback between NAV read and mint.
- **Senior redemption:** REDEEM→REPAY→`settleEpoch`→claim conserves value — par round-down, monotone `reservedAssets ≤ balanceOf`, single requester, USDC over-donation can't misattribute or drain.
- **`burnFor` NAV step** lands at CoW settlement (engineSafe exclusion), not at `burnFor`; a simultaneous deposit pays the post-fill `navEntry`, so the NAV/share step can't be captured across the boundary.
- **Bridge transport:** CCIP lock-release/burn-mint is transport-only — no NAV/escrow desync, and xALPHA is **not** double-counted across its basket/bond/CCT roles (escrow and Safe balances are disjoint; the oracle sums only main+sidecar).
- The reservoir borrow/repay/withdraw cycle is `grossBasketValue`-invariant (usdc leg vs `_reservoirDebt` cancel).
