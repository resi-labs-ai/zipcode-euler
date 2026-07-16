# X-Ray — `RecycleModule.sol` (single-contract, test-connected)

> RecycleModule | 165 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/RecycleModule.sol`, the 8-B10 free-value ledger —
**the only engine module that carries real mutable state** (`freeValueAccrued` + the SEC-09 cumulative-divert
tally). Connected to `test/RecycleModule.t.sol`: **40 unit + 2 base-fork = 42 tests, all passing** (0 fuzz, 0
Foundry invariant — but the load-bearing cumulative bound has a dedicated 5-test SEC-09 suite). After
DurationFreezeModule, the best-tested fleet module. **Every mutator is exercised** (all 7 setters + the 3 operator
legs + `creditFreeValue`).

> Correction to the portfolio map: its `access` column lists "nonReentrant" for this module — that's wrong. The
> code uses **no** `ReentrancyGuard` (a clone never runs the guard's ctor); reentrancy safety is **effects-before-
> interaction** — the ledger decrement + tally bump land *before* the value-moving `_exec`s (`:69-72`, tested).

## 1. What it is

A CRE-operator-gated Zodiac `Module` enabled on the engine Safe (`avatar == target == juniorTrancheEngine`). It owns
the engine's one piece of real state — the single `freeValueAccrued` accumulator (CRE is the only writer, §8 inv. 3)
— and spends it through **two sinks**, both debiting the same ledger:
- `recycle(usdcAmount)` — **NAV accretion**: `ZipDepositModule.deposit` parks the USDC as senior backing + mints
  backed zipUSD 1:1 into the basket (no share issuance → NAV-per-share rises for all holders).
- `divert(usdcAmount)` — **Stream 2 (loss-side)**: supplies raw USDC into the senior pool crediting the warehouse
  Safe (`eePool.deposit(amount, warehouseSafe)`, no zipUSD minted), **bounded cumulatively by the live
  `provision()` hole** (SEC-09).

**The load-bearing free-value invariant, two-layer (§8 inv. 3):** (a) **policy ceiling** — spends debit
`freeValueAccrued` and revert if it would go negative; (b) **hard backing** — the actual USDC is pulled from the
Safe's *real* balance by the `_exec` legs, and `divert` asserts the Safe's USDC fell by exactly `usdcAmount`
(`BackingShortfall`) — so even an over-credited accumulator cannot conjure value. `creditFreeValue` is **unbounded
and operator-trusted** (layer (a) is policy, not cryptographic) — the §17 single-CRE-writer residual.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `creditFreeValue(amount)` | operator-only | unbounded ledger increment (the §17 trusted-writer residual) |
| `recycle(usdcAmount)` | operator-only | debit-first, then approve→`ZipDepositModule.deposit`→reset; backed-mint into basket |
| `divert(usdcAmount)` | operator-only | bounds-before-spend (`NoHole`/`ExceedsHole`) → CEI debit + tally → approve→`eePool.deposit(amount, warehouseSafe)`→reset; `BackingShortfall`/`NoSharesMinted` post-guards |
| `setUp` + 7 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring (`setJuniorTrancheEngine` syncs `avatar`/`target`) |
| `freeValueAccrued` / `lastSeenProvision` / `divertedSinceProvisionChange` | public state | the ledger + SEC-09 epoch tally |

No permissionless mutators, no custody. `recycle`/`divert` route value only to the basket / warehouse Safe; never an operator-supplied destination.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **free-value ledger conservation** — credited only by `creditFreeValue`, debited only by `recycle`+`divert` (via `_spendFreeValue`), reverts on overspend; shared single ledger | Yes | `test_credit_and_spend_arithmetic`, **`test_recycle_overspend_leaves_accrued_and_callcount_unchanged`**, `test_divert_then_recycle_share_one_ledger` |
| I-2 | **two-layer enforcement** — policy ceiling (debit-first) AND hard backing (Safe USDC must fall by exactly `usdcAmount`) | Yes | **`test_divert_backing_shortfall`** (`BackingShortfall`), `test_integrated_recycle_mints_backed_zip_and_debits` |
| I-3 | **SEC-09 cumulative divert bound** — total diverted ≤ live `provision()` per epoch; strict `>` (exact fill allowed); reset-on-remark; stale-value remark does NOT resurrect the tally | Yes | **`test_SEC09_cumulative_overfill_blocked`**, `_exact_cumulative_fill_and_one_wei_over`, `_reset_on_remark_allows_fresh_budget`, `_stale_value_remark_does_not_resurrect_tally`, `_divert_never_writes_provision` |
| I-4 | **divert bounds + liveness guards** — `NoHole` (provision 0), `ExceedsHole`, `NoSharesMinted`, overflow reverts before spend | Yes | `test_divert_no_hole_reverts`, `_exceeds_hole_boundary`, `_no_shares_minted`, **`test_divert_overflow_panics_before_spend`**, `_two_bounds_bind` |
| I-5 | **CEI / effects-before-interaction** (reentrancy safety without a guard) — decrement + tally bump land before the value-moving execs | Yes | **`test_integrated_decrement_before_exec`**, `test_divert_decrement_before_exec` |
| I-6 | **recycle backed-mint** — approve→deposit→reset; mints backed zipUSD into the Safe; no standing approval | Yes | `test_recycle_exec_shape_and_decode`, `test_integrated_recycle_mints_backed_zip_and_debits`, `test_recycle_malformed_return_reverts` |
| I-7 | **bubbling `_exec`** — a swallowed inner revert hard-reverts | Yes | `test_recycle_bubble_on_exec_fail`, `test_divert_bubble_on_exec_fail`, `test_exec_failed_empty_revert_data`, `test_divert_execfailed_empty_revert_data` |
| X-1 | §17 residual: `creditFreeValue` is unbounded, operator-trusted (layer (a) is policy) | **No** | bounded on-chain by the hard-backing layer (b) + the finite credited budget; off-chain by the single trusted CRE + 8-B11/8-B12 backstops |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (×8) / owner==operator / abi length / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_zero_in_each_of_eight`, `_rejects_owner_equals_operator`, `_abi_length_mismatch_reverts`, `_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `NotOperator` on all 3 legs + `creditFreeValue` | `test_action_legs_only_operator` |
| `ZeroAmount` (credit/recycle/divert) | `test_credit_zero_amount_reverts`, `test_recycle_zero_amount_reverts`, `test_divert_zero_amount_reverts` |
| `InsufficientFreeValue` | `test_recycle_overspend_leaves_accrued_and_callcount_unchanged` |
| Stream-2 setters (`setNavOracle`/`setEePool`/`setWarehouseSafe`) | `test_stream2_setters_repoint_only_owner` (onlyOwner + zero-guard + effect + event) |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| 3 wiring setters (`setJuniorTrancheEngine`/`setZipDepositModule`/`setUsdc`) | `test_wiring_setters_repoint_only_owner` — onlyOwner + zero-guard + effect + `WiringSet` event (all 3), incl. the `setJuniorTrancheEngine` avatar/target sync |

## 5. Attack surfaces

- **SEC-09 cumulative divert bound — the subtle property, tested thoroughly (I-3)** — `divert` can over-fill the
  capital hole only across provision re-marks, never within an epoch. The 5-test SEC-09 suite proves: per-call passes
  but cumulative over-fill reverts; exact fill (`sum*1e12 == hole`) is allowed and one-wei-over reverts;
  reset-on-remark frees a fresh budget; and the **stale-value remark (`H→H'→H`) does NOT resurrect the old tally**
  (the value-key bug the ticket forbids). This is the most careful invariant testing among the fleet drivers.
- **Two-layer free-value enforcement (I-1/I-2)** — the policy ceiling (debit-first) is operator-trusted, but the
  hard-backing guard (`BackingShortfall` — the Safe's USDC must fall by exactly `usdcAmount`) means even an
  over-credited accumulator cannot conjure value. Both layers tested. The §17 residual is real but bounded: an
  over-`creditFreeValue` can mis-route *real* free value, never *invent* it.
- **No `ReentrancyGuard` — CEI instead (I-5)** — uniquely among stateful modules, reentrancy safety is the
  effects-first decrement (clones can't run a guard ctor); `test_*_decrement_before_exec` proves the ledger + tally
  update before the value-moving execs, so a reentrant spend can't double-spend. Sound and tested — but worth noting
  it's a structural argument, not a guard, so any future code that moves an `_exec` before the decrement would break it.
- **3 wiring setters — now covered** — `test_wiring_setters_repoint_only_owner` exercises
  `setJuniorTrancheEngine`/`setZipDepositModule`/`setUsdc` for onlyOwner + zero-guard + effect + `WiringSet` event.
  With the stream-2 trio and `setOperator` (SEC-15), **every wiring setter is now exercised**. `setJuniorTrancheEngine`
  syncs `avatar`/`target` in lockstep (`:188-190`), matching the syncing siblings (Sell/Exercise/
  LpStrategy/FarmUtilityLoop) — the engine-Safe invariant `avatar == target == juniorTrancheEngine` must hold because
  `divert` reads `juniorTrancheEngine` as the executor account for its `BackingShortfall` balance-delta guard (`:325/:332`),
  so a non-syncing re-point would have left that guard measuring a non-executing Safe (fail-closed DoS on `divert`,
  owner-only, build-phase). The sync is asserted in `test_wiring_setters_repoint_only_owner`.
- **No Foundry stateful invariant on the ledger** — the conservation + SEC-09 properties are covered by deterministic
  boundary tests rather than fuzzed interleavings. Lower-priority than ExitGate's was: the consequence is smaller
  (mis-routing realized free value, not minting), and the tricky SEC-09 cases (exact/over/reset/stale-remark) are
  explicitly tested. A fuzzed credit/recycle/divert+remark handler would add some assurance but isn't a clear gap.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 40 | setUp/guards, SEC-14/15, all 7 wiring setters (stream-2 trio + the `juniorTrancheEngine`/`zipDepositModule`/`usdc` trio), ledger credit/spend arithmetic + overspend, recycle exec-shape/decode/malformed/bubble, the full divert guard matrix (no-hole/exceeds-hole/backing-shortfall/no-shares/overflow/two-bounds/decrement-before-exec), the **5-test SEC-09 cumulative-bound suite**, shared-ledger interaction |
| Base-fork | 2 | `test_fork_recycle_against_real_safe`, `test_fork_divert_against_real_safe` (real summoned Safe driving the actual deposit/eePool legs) |
| Stateless fuzz / Foundry invariant | 0 | the conservation + SEC-09 bounds are covered by deterministic boundary tests; a fuzzed handler is optional, not a clear gap |

All **42 pass** (`forge test --match-path test/RecycleModule.t.sol`). The decisive properties (ledger conservation,
two-layer enforcement, the SEC-09 cumulative bound, CEI ordering) are tested unit + fork. Coverage % uninstrumentable
(project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — the most stateful fleet module, and its state is well-defended: the free-value ledger conservation,
the two-layer (policy + hard-backing) free-value enforcement, the CEI reentrancy argument, and especially the SEC-09
cumulative-divert bound (with the exact-fill / reset / stale-remark edge cases) are all tested, unit + fork. **Every
mutator is now exercised** (all 7 setters + the 3 legs + `creditFreeValue`; the 3-setter gap was filled).
Capped at ADEQUATE by: the §17 `creditFreeValue` operator-trust residual (bounded by hard-backing, not eliminated),
no Foundry stateful invariant on the ledger (optional — boundary cases are covered deterministically), and the
build-phase mutable wiring pending the pre-prod re-freeze — none a coverage gap.

**Structural facts:**
1. 165 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); **no `ReentrancyGuard`** — CEI/effects-first instead; the only engine module with real mutable state.
2. One owned ledger (`freeValueAccrued`); two sinks (`recycle` NAV-accretion + `divert` Stream-2), both debit it; `divert` bounded cumulatively by the live `provision()` (SEC-09, reset-on-remark).
3. Two-layer free-value guarantee: policy ceiling (debit-first) + hard backing (`BackingShortfall` — exact USDC pull); `creditFreeValue` unbounded/operator-trusted (§17).
4. Tests: 40 unit + 2 base-fork (0 fuzz/invariant); every mutator exercised; the SEC-09 cumulative bound has a dedicated 5-test suite.
5. No outstanding coverage gap on the contract surface; residuals are off-chain (the §17 `creditFreeValue` trust, the pre-prod wiring re-freeze) + an optional ledger stateful invariant.
