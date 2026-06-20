# X-Ray — `DurationFreezeModule.sol` (single-contract, test-connected)

> DurationFreezeModule | 199 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/DurationFreezeModule.sol`, the **#2 drill** from
`portfolio-map.md` — the duration-squeeze solvency floor that gates all junior outflow. Connected to
`test/DurationFreezeModule.t.sol`: **54 unit + 1 fuzz (parity) + 1 stateful invariant + 2 base-fork** = **56 tests,
all passing** (the invariant ran 128k calls, 0 floor violations). The **only contract in the szipUSD subsystem with
the full test pyramid.**

> Drill goal (from the portfolio map): *confirm the floor cannot be under-frozen and the LP-in-place accounting is
> exact.* **Both are directly proven** — the stateful invariant proves no `release` ever breached the live floor; the
> SEC-02 vectors prove the LP is single-counted; the debt-pinned/basket-shrink-invariant tests prove un-drainability.

## 1. What it is

The seventh engine Zodiac `Module`, and the **first enabled on BOTH Safes** (main + `juniorTrancheSidecar`) because
the freeze moves value across them. It fills the non-ragequittable sidecar (`commit`, MAIN→SIDECAR) and drains it
(`release`, SIDECAR→MAIN), keeping utilization-committed junior equity structurally unreachable by an Exit-Gate
window exit. It is the Duration-Bond trigger B — a **liquidity** squeeze (no realized loss, no xALPHA slash, no
markdown).

**The §13 residual-trust posture (load-bearing):** the module **rotates and bounds**; it does *not* decide the
liquidity regime. The CRE `operator` is trusted for *which* whitelisted asset, *how much*, timing, and whether to
`commit`. The on-chain guarantees are narrow and exact: (a) value moves only between the two wired Safes — **no
recipient parameter, no generic exec/delegatecall, `value==0`, no custody**; (b) `release` cannot drop coverage
below `requiredCommittedValue()` = `min(illiquidSeniorValue, grossBasketValue)` — the senior **liability**, read
live + donation-immune; (c) the floor is pinned to **absolute debt**, not a junior-basket fraction, so shrinking the
basket cannot lower it (no governed knob). A compromised operator can **grief** (over-commit free equity, delaying
exits) but **cannot steal** and **cannot under-freeze**.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `commit(asset, amount)` | operator + `nonReentrant` + `onlyValued` | MAIN→SIDECAR; no value floor (an unbounded commit can freeze 100% — the intended squeeze); FoT/false-return defended |
| `release(asset, amount)` | operator + `nonReentrant` + `onlyValued` | SIDECAR→MAIN; **the autonomous floor** — reverts `FreezeFloorBreach` unless post-move coverage ≥ `requiredCommittedValue()` (atomic rollback) |
| `setUp(initParams)` | `initializer` (clone) | wires 7 addrs, reads the 5 movable legs LIVE off the oracle, sets `avatar=target=juniorTrancheSafe`, transfers ownership to Timelock |
| 12 × `setX(...)` | `onlyOwner` (Timelock) | build-phase wiring re-points (2 Safes, operator, oracle, eulerEarn, warehouse, 5 leg tokens) |
| views | public | `utilization`, `requiredFraction`, `committedValue`, `grossBasketValue`, `freeValue`, `pathLockedLpEquity`, `coverageValue`, `illiquidSeniorValue`, `requiredCommittedValue`, `covered`, `lpBurnKeepsCovered` |

No permissionless mutators. The operator supplies only `(asset, amount)`; the module builds all calldata.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **the floor holds** — no successful `release` ever leaves coverage below the live floor | Yes | **`invariant_release_never_breached_floor`** (256×500 = 128k calls, 0 violations), `test_release_below_floor_reverts_and_rolls_back`, `test_release_debt_rise_flips_legal_to_breach`, **`test_fork_high_U_release_reverts_floorBreach`** |
| I-2 | **floor is debt-pinned, un-drainable** — `requiredCommittedValue = min(illiquidSeniorValue, gross)`; invariant to basket shrink (no fractional denominator to game) | Yes | `test_requiredCommittedValue_debt_pinned_at_100pct`, `_capped_at_gross`, **`test_requiredCommittedValue_invariant_to_basket_shrink`**, `_zero_gross_floor_zero` |
| I-3 | **value moves only between the two Safes** — no recipient param, no forbidden selector, no custody, `value==0` | Yes | `test_no_forbidden_selectors`, `test_commit_happy_moves_and_emits`, `test_commit_then_release_plain_leg_conserves_balances`, **`test_fork_real_rotation_moves_real_committedValue`** |
| I-4 | **coverage = committedValue + pathLockedLpEquity**, LP counted in-place and **single-counted** (not double) | Yes | `test_coverageValue_counts_pathLockedLp`, **`test_SEC02_juniorTrancheSidecar_lp_single_counted`** (rises by exactly one mark), `test_SEC02_partition_gross_minus_coverage_eq_pm`, `test_SEC02_floor_breach_covered_flips_false` |
| I-5 | **donation-immune** U/debt — read via `maxWithdraw`/`convertToAssets`, never `balanceOf(eulerEarn)` | Yes | **`test_utilization_donation_immune`**, `test_utilization_*` (zero/mid/exact-boundary), `test_illiquidSeniorValue_scales_6dp_to_18dp` |
| I-6 | **only the 5 oracle-valued legs are movable**; the ICHI LP share is NOT whitelisted (fenced in place) | Yes | `test_commit_unvalued_asset_reverts`, `test_release_unvalued_asset_reverts`, `test_each_leg_is_accepted_by_whitelist` |
| I-7 | **FoT / false-return transfer defense** — dest balance delta MUST equal `amount` | Yes | `test_commit_feeOnTransfer_reverts_shortfall`, `test_commit_safe_returns_false_reverts_execFailed`, `test_release_safe_returns_false_reverts_execFailed` |
| I-8 | **gross is invariant under rotation** (oracle sums both Safes) — the floor is a pure "did the sidecar keep enough" check; `gross == committed + free` | Yes | **`testFuzz_parity_no_LP`** (fuzz, exact), `test_parity_exact_plain_legs`, `test_parity_split_LP_within_2_wei` (≤2-wei pro-rata floor), fork rotation |
| I-9 | **unseeded xALPHA rate fails closed** — `coverageValue` reverts `RateUnseeded` rather than under-counting the floor | Yes | **`test_SEC04_unseeded_rate_reverts_coverageValue`** (fail-before/pass-after) |
| X-1 | §13 residual: CRE operator trusted for asset/amount/timing — **grief-bounded, not theft, not under-freeze** | **No** | the bound is the on-chain floor + no-recipient-param; `test_commit_over_freeze_all_free_equity_succeeds` shows over-freeze is *permitted* (accepted grief, §12 alarm) |
| X-2 | the floor's correctness depends on the **oracle**'s `committedValue`/`pathLockedLpEquity`/`grossBasketValue` being honest | **No** | `SzipNavOracle` is the valuation authority (out of this scope); SEC-02/SEC-04 exercise the REAL oracle to pin the seam |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr / owner==operator / safes-distinct | `test_setUp_rejects_zero_addresses`, `_rejects_owner_equals_operator`, `_rejects_juniorTrancheSafe_equals_juniorTrancheSidecar` |
| `initializer` once + mastercopy init-locked (SEC-14) | `test_setUp_initializer_once`, `test_mastercopy_init_locked`, `test_SEC14_mastercopy_setUp_reverts` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `NotOperator` on commit/release | `test_commit_nonOperator_reverts`, `test_release_nonOperator_reverts` |
| `ZeroAmount` on commit/release | `test_commit_zeroAmount_reverts`, `test_release_zeroAmount_reverts` |
| `UnvaluedAsset` whitelist | `test_commit_unvalued_asset_reverts`, `test_release_unvalued_asset_reverts` |
| `ExecFailed` on Safe false-return / insufficient bal | `test_commit_safe_returns_false_reverts_execFailed`, `test_commit_insufficient_balance_reverts_execFailed` |
| `FreezeFloorBreach` + atomic rollback | `test_release_below_floor_reverts_and_rolls_back`, `_required_full_juniorTrancheSidecar_eq_gross_one_wei_release_reverts` |
| operator cannot redirect Safe (`setAvatar`/`setTarget` onlyOwner) | `test_operator_cannot_redirect_safe`, `test_setTarget_nonOwner_reverts` |
| floor-zero allows full drain | `test_release_floor_zero_allows_full_drain` |

## 5. Attack surfaces

- **The floor cannot be under-frozen (I-1/I-2) — the drill's #1 question, answered** — the floor is read live AFTER
  the move and the revert atomically rolls the transfer back; it is pinned to *absolute* senior debt
  (`min(illiquidSeniorValue, gross)`), not a basket fraction, so shrinking the junior basket leaves no denominator to
  game. The **128k-call stateful invariant** (`U` floated independently via `bumpUtilization`, `commit` ungated,
  `release` recorded per success) found **zero** breaches. This is the strongest evidence in the subsystem.
- **LP-in-place accounting is exact (I-4) — the drill's #2 question, answered** — the SEC-02 vectors run the REAL
  oracle: a sidecar LP donation raises coverage by *exactly one* mark (`pathLockedLpEquity` is main-only, so the
  sidecar LP isn't double-counted), and `test_SEC02_floor_breach_covered_flips_false` proves the pre-fix
  double-count *would* have falsely reported `covered()`.
- **The double-squeeze (documented, fail-closed by design)** — `covered():323-329` documents that a reservoir borrow
  against the fenced LP pushes **both** sides the wrong way at once: the numerator drops (`pathLockedLpEquity`
  subtracts strike debt) **and** the floor rises (the borrow draws senior cash → `maxWithdraw` falls →
  `illiquidSeniorValue` rises). The two do **not** cancel. This is **self-DoS**: the borrower can only freeze its own
  outflow, and it recovers fully on repay. A liveness footgun, never a solvency hole — well-reasoned and explicitly
  documented (the docstring corrects an earlier "debt nets out" rationale that was wrong).
- **Single-operator assumption is off-chain (X-1)** — the floor read is sound only under the single-operator
  invariant (no concurrent sibling-module rotation mid-`release`). Not on-chain enforced; relies on the
  one-trusted-operator model shared across the engine fleet.
- **Large mutable-wiring surface (X-3 pattern)** — **12** `onlyOwner` setters, including the 5 leg tokens. Re-pointing
  a leg (`setUsdc`, etc.) could desync the whitelist from what the oracle prices (the `setUp` reads them live to
  avoid exactly this drift; the setters reintroduce the drift risk if used carelessly). All zero-guarded; the
  destination guarantees hold after the deferred pre-prod immutable re-freeze. Untested: the 12 setters' effects (the
  shared `onlyOwner` gate is proven on `setAvatar`/`setTarget` + `setOperator`).
- **Oracle is the valuation authority (X-2)** — every floor input (`committedValue`, `pathLockedLpEquity`, `gross`)
  is read from `SzipNavOracle`. A wrong oracle mark mis-gates outflow. Out of this scope, but the SEC tests pin the
  seam against the real oracle.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 54 | setUp/guards, the full views suite, commit/release happy+revert matrix, whitelist, FoT defense, balance conservation, SEC-02 (LP single-count, the marquee fix), SEC-04 (unseeded-rate fail-close), SEC-14/15 |
| Stateless fuzz | 1 | `testFuzz_parity_no_LP` — `gross == committed + free` exact across 4 fuzzed balances |
| Stateful invariant | 1 | **`invariant_release_never_breached_floor`** — 128k calls, `U` floated, 0 floor violations |
| Base-fork | 2 | real summoned Safes + real `SzipNavOracle` + a `ModuleProxyFactory` clone enabled on both Safes via the Baal idiom: real cross-Safe rotation moves real `committedValue`; high-U release reverts `FreezeFloorBreach` |

All **56 pass** (`forge test --match-path test/DurationFreezeModule.t.sol`). The **decisive safety property (the
floor) is under a stateful Foundry invariant** *and* a base-fork test — the gold standard. Coverage %
uninstrumentable (project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — the best-tested contract in the szipUSD subsystem: roles + Timelock +
`nonReentrant` + CEI, no recipient parameter, no custody, and its load-bearing properties (the debt-pinned floor's
un-breachability, the in-place single-counted LP accounting, gross-parity-under-rotation, donation-immunity,
fail-closed unseeded-rate) are proven by **unit + fuzz + a 128k-call stateful invariant + base-fork** — and the two
historical security fixes (SEC-02 double-count, SEC-04 fail-close) carry regression tests. Capped at ADEQUATE (not
HARDENED) only by: the §13 residual operator trust (grief is permitted by design), the **12-setter** build-phase
mutable wiring + deferred immutable re-freeze (the 12 setters' effects untested), the off-chain single-operator
assumption, and the cross-contract dependence on `SzipNavOracle`'s marks (X-2).

**Structural facts:**
1. 199 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); `nonReentrant` on both mutators; no custody.
2. Operator supplies only `(asset, amount)`; the module builds all calldata; source/dest are the literal set-once Safes; `value==0`; no recipient param, no delegatecall.
3. The floor = `min(illiquidSeniorValue, grossBasketValue)`, debt-pinned (not a basket fraction), read live + donation-immune; `release` enforces coverage ≥ floor post-move with atomic rollback.
4. Coverage = `committedValue + pathLockedLpEquity` — the fenced LP backs the floor IN PLACE (single-counted); its only dissolution path (`LpStrategyModule.removeLiquidity`) is coverage-gated via `lpBurnKeepsCovered`.
5. Tests: 54 unit + 1 fuzz + **1 stateful invariant (128k calls, 0 breaches)** + 2 base-fork; the floor and LP-accounting drill questions are both directly answered.
