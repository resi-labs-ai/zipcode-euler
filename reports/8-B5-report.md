# 8-B5 report — reservoir strike-loop module (to the superintendent)

**Status: DONE / BUILT-VERIFIED + KEPT. NEXT = 8-B6 (LP / gauge-stake module).**

## TL;DR
Authored `tickets/sodo/8-B5-reservoir-loop.md` (the **2nd engine Zodiac Module**) through the full harness and
cold-built it green on a live Base fork — **kept, not discarded**. 8-B5 is the on-chain seam of the
self-collateralizing harvest loop: a CRE-`onlyOperator` `is Module` that drives the szipUSD Safe's **own EVC
account** through unstake→post→borrow→repay→withdraw to finance the oHYDX strike, plus the CRE-fed LP collateral
oracle, a borrow-gating hook, and the reservoir-market deployer.

- **`forge test --match-contract ReservoirLoopModuleTest` → 33/33 Base-fork; full suite 271/271, no regression.**
  Independently re-run by me (not just the cold-build subagent).
- 4 contracts + 1 test kept: `contracts/src/supply/szipUSD/ReservoirLoopModule.sol` (238) +
  `contracts/src/supply/SzipReservoirLpOracle.sol` (108) + `contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol`
  (62) + `contracts/script/ReservoirMarketDeployer.sol` (102) + `contracts/test/ReservoirLoopModule.t.sol` (888).
- No `reference/` edits, no kept-contract edits, `BaseAddresses.sol` untouched. **NOT git-committed** (whole tree is
  untracked — commit is your call).

## What the window did
1. Confirmed NEXT = the engine chain starting at **8-B5** (per the PROGRESS banner + `reports/design/baal-spec.md §13` build order).
2. **Asked you one question** (the lone §4.5.1-flagged build decision): the LP collateral oracle shape. After a
   back-and-forth clarifying that this is the **Oracle Router** (`EulerRouter`) price feed (not the swap/orderflow
   router), you locked **option 1 — the CRE-fed push-cache** (CRE computes the per-LP-share reserve×price mark and
   pushes it; the on-chain adapter is the thin stale-checked cache). Recorded as component-local (ticket/LEDGER/report),
   not a §17 change.
3. Drafted the ticket → **5-critic fanout** (junior-developer, spec-fidelity, reference-verifier, qa-engineer,
   security-engineer; build-only → no frontend critic) → triaged → cold-build (subagent, zero-guess gate) →
   re-verified green myself.

## Design decisions to sanity-check (your call)
1. **The Safe borrows on its OWN EVC account (not a `LineAccount`).** Per §4.5.1 "the Safe is itself an EVC account
   owner." The module `exec`s through the Safe, so the Safe is the EVC `msg.sender` and account owner —
   `enableCollateral(engineSafe,·)`/`enableController(engineSafe,·)`/`EVC.call(·, engineSafe, ·, ·)` all authorize.
   Distinct from the senior lien side (WOOF-04's per-line `LineAccount` + adapter-as-operator). Fork-proven.
2. **`ReservoirBorrowGuard` upgraded from optional→required (security F8a).** The reservoir USDC borrow vault IS the
   warehouse's *shared* resting USDC (depositors' idle cash). Without a gate, any ICHI-LP holder could post the
   escrow on their own account and lever depositor funds. The guard pins `OP_BORROW` to the engine Safe. I judged
   this crosses the depositor-funds threshold and made it a required, tested contract (a third-party direct borrow
   reverts at the guard; the Safe's borrow passes). `CREGatingHook` itself doesn't fit (it needs an operator on the
   account — we forbid that), so the guard gates account-identity instead. **Sanity-check:** is gating to the Safe at
   the vault level the right boundary, or do you want it left to item-10/8-Bw with a documented residual? I chose to
   build it now.
3. **`borrowCap` = aggregate outstanding bound (security F1).** `debtOf(safe) + amount > borrowCap → revert`, not a
   per-call gate — so a compromised operator can't loop-borrow past the cap. `borrowCap==0` = kill-switch.
4. **Governor RETAINED at the Timelock** (§4.5.1 inversion of WOOF-04's freeze) — the reservoir is a standing tunable
   facility (LTV/caps/oracle re-pointable under the 2-day veto). The deployer is router governor at birth, then
   `transferGovernance(timelock)`.
5. **Test stand-ins / values** (CRE/8-B6 deps not yet built): 18-dp `MockLpToken` for the LP (the real ICHI share is
   8-B6), `ZeroIRM`, a directly-seeded USDC borrow vault (the EE→resting-vault wiring is 8-Bw/item-10). Deploy values:
   `validityWindow=1 days`, `borrowCap=1_000_000e6`, `borrowLTV/liqLTV=0.7e4/0.8e4`, mark `1e6` ($1/share). All
   governed/deploy params — flagged as such.

## Holes surfaced → resolution
**Spec (2 §4.5.1 clarifications FIXED in `claude-zipcode.md`, no §17 reopened):**
- The 8-B5 borrow vault installs an `OP_BORROW` guard pinning the borrow to the engine Safe + `borrowCap` is
  aggregate (added to the §4.5.1 "What it is" block).
- The collateral-oracle build-flag RESOLVED to the CRE-fed push-cache via a dedicated `LP_MARK` reportType (≠ the
  registry's `REVALUATION=3`), fail-closed on staleness (rewrote the §4.5.1 "Collateral oracle" paragraph).

**Spec gap DEFERRED (the one SPEC-GAP the spec-fidelity critic surfaced):**
- **`LP_MARK` must be registered in the §8 CRE report ABI** (`spec-clear-CRE.md`, still TODO). 8-B5 pinned the
  placeholder `7` in the built oracle and logged a CRE-track obligation. The CRE window ratifies. *This is the only
  item I could not close in-spec; it is genuinely CRE-§8 territory.*

**Build-exposed corrections (cold-build, folded back into the ticket — the kept-build doctrine working as intended):**
- **C1 (critical):** the Gnosis Safe **swallows inner reverts** (`execTransactionFromModule` returns `false`, doesn't
  bubble). A bare `exec` silently swallowed a failed EVC borrow/oracle-read → the module would wrongly emit success.
  Fixed: a private `_exec` using `execAndReturnData` that **bubbles the inner revert bytes** (so every fail-closed
  "Done when" revert actually surfaces). Without this the safety tests would pass for the wrong reason — worth your
  attention as a pattern for 8-B6…B13 (every engine module that drives the Safe through the EVC needs it).
- **C2:** EVK `repay` does NOT cap a literal `amount>owed` (reverts `E_RepayTooMuch`; only `type(uint).max`=all). My
  ticket wrongly said "EVK caps." Repay the exact strike.
- **C3:** a NEW borrow gates on `borrowLTV`, not `liqLTV`. Over-LTV magnitudes re-pinned.
- **C4:** `setLTV` validates the collateral price at config time → a live LP mark must exist pre-deploy; "governor
  retained" is `transferGovernance(timelock)`, not a skipped transfer.

## Authoritative-doc edits
- `claude-zipcode.md §4.5.1` — 2 clarifications above (the `OP_BORROW` borrow-pin + aggregate `borrowCap`; the LP
  oracle resolution + `LP_MARK` reportType). No §17 decision reopened.
- `tickets/PROGRESS.md` — 8-B5 row → BUILT-VERIFIED; banner NEXT → 8-B6; session log; 4 new obligations (8-Bw EE
  wiring, CRE `LP_MARK`, item-10/8-B11 CRE wiring, item-10 audit-sweep); spec-gap log entry.
- `tickets/LEDGER.md` — full 8-B5 digest.
- `audit/2.md` / `audit/3-results.md` — **NOT touched.** The audit-sweep is logged as an OPEN obligation pinned to
  the item-10/engine-integration pass (consistent with the Exit-Gate + 8-B14 deferrals — the loop L-step needs the
  full engine + deploy to be integration-testable; writing it against a half-wired system would be fiction).

## Judgment calls
- **Made the borrow guard required + built it** rather than deferring (design decision #2) — depositor-fund exposure.
- **Did not re-fan the critics** after folding in the guard (new surface). The addition is a verbatim `CREGatingHook`
  model covered by a new targeted test (third-party borrow reverts), and the cold-build's zero-guess gate +
  exhaustive exec-discipline test are themselves adversarial. Per the harness "cold-build-only suffices for a change
  covered by a new targeted test." Flagging it here for your review.
- **Pinned `LP_MARK=7`** as a placeholder rather than blocking on the CRE §8 window — the value is CRE-ratified later;
  the oracle's behavior is fully tested regardless.

## NEXT
**8-B6 — LP / gauge-stake module** (`reports/design/baal-spec.md §13` / `§10.8`): builds + gauge-stakes the zipUSD/xALPHA ICHI LP and
unstakes/re-stakes slices for this loop. It produces the real LP token 8-B5 stands-in for, and consumes the
unstake/re-stake seam (loop steps 1 + 7). Then 8-B7…8-B13.
