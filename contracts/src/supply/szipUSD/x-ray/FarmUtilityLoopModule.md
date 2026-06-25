# X-Ray — `FarmUtilityLoopModule.sol` (single-contract, test-connected)

> FarmUtilityLoopModule | 170 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/FarmUtilityLoopModule.sol`, the **#4 drill** — the
8-B5 strike-financing **leverage loop** (EVK borrow of the warehouse's resting USDC — JIT-funded into the farm
utility vault from `usdcReservoir`, collateralized by the LP). The highest-consequence
fleet module after the value-out path: it borrows shared depositor cash. Connected to
`test/FarmUtilityLoopModule.t.sol` — a 42-test suite that **also** covers adjacent contracts (the `SzipFarmUtilityLpOracle`,
the already-drilled `FarmUtilityBorrowGuard`, and a farm utility-funding surface, CTR-07). The loop module's own coverage:
**~16 unit/fork tests, almost all against the REAL EVK/EVC market.** By integration depth, the second-best-tested
module after DurationFreezeModule.

> The risk to size: this is the only module that *borrows*. Three independent controls bound it — (1) the on-chain
> **F1 aggregate cap / killswitch** (`borrowCap`, owner-only), (2) the **EVK account-status health check** (over-LTV
> or stale-mark borrows revert), and (3) the **`FarmUtilityBorrowGuard`** pinning `OP_BORROW` to the Safe. All three
> are tested on the live market.

## 1. What it is

The second engine Zodiac `Module`, CRE-operator-gated, enabled on the engine Safe (`avatar == target ==
juniorTrancheEngine`). It drives the **Safe's own EVC account** (borrower-of-record = the Safe, not a fresh
`LineAccount`) through four loop steps: `postCollateral` (approve+enableCollateral+deposit the LP slice) → `borrow`
(strike USDC, F1-capped) → `repay` (approve+repay+reset) → `withdrawCollateral` (release LP to re-stake). The LP
self-collateralizes its own oHYDX strike.

**The §10.1 boundary:** operator supplies only scalar amounts. The module builds all calldata; every borrow/repay/
withdraw `receiver`/`owner` and every EVC `onBehalfOfAccount` is the literal `juniorTrancheEngine`; `value==0`, no
passthrough/delegatecall. Borrow/repay/withdraw run via `IEVC.call(target, juniorTrancheEngine, 0, …)` — the Safe is
the EVC msg.sender owning sub-account 0, so the on-behalf is authorized with **no operator bit**.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `postCollateral(lpAmount)` | operator-only | 3 execs: approve→`enableCollateral`(idempotent)→`escrow.deposit` |
| `borrow(usdcAmount)` | operator-only | **F1 cap check** then `enableController`(idempotent)→`EVC.call(borrow)`; EVK health-gated |
| `repay(usdcAmount)` | operator-only | 3 execs: approve→`EVC.call(repay)`→reset (no standing approval) |
| `withdrawCollateral(lpAmount)` | operator-only | `DebtOutstanding` guard then `EVC.call(withdraw)` |
| `setBorrowCap(cap)` | `onlyOwner` (Timelock) | the F1 aggregate cap / killswitch (cap==0 ⇒ all borrows revert); **not** operator-settable |
| `setUp` + 7 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring (`setJuniorTrancheEngine` syncs avatar/target) |
| `outstandingDebt` / `postedCollateral` | `view` | read live from the vault/escrow |

No permissionless mutators. No custody.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **the loop revolves cleanly** — post/borrow/repay/withdraw round-trips; no duplicate EVC enables; views read the vault live; no standing approval | Yes | **`test_full_loop_revolves_twice`** (×2 rounds: 1 collateral / 1 controller, debt clears, allowance 0, LP returns) |
| I-2 | **F1 aggregate cap + killswitch** — `debtOf + amount > borrowCap` reverts `CapExceeded`; `borrowCap==0` reverts every borrow; owner-only | Yes | **`test_aggregate_cap_boundary_and_killswitch`** (exact-cap OK, +1 reverts, cap=0 killswitch), `test_setBorrowCap_only_owner` |
| I-3 | **EVK health gate** — over-LTV (borrow-LTV, not liq-LTV) and no-collateral borrows revert `E_AccountLiquidity` | Yes | **`test_over_LTV_reverts_AccountLiquidity`** (69<70 OK, +5 reverts), `test_no_collateral_borrow_reverts_AccountLiquidity` |
| I-4 | **fail-closed on a bad mark** — stale / never-pushed LP oracle marks revert the borrow (bubbled router error) | Yes | **`test_stale_and_never_pushed_mark_fail_borrow_closed`** (`PriceOracle_TooStale` + `_NotSupported`) |
| I-5 | **borrow pinned to the Safe (the guard seam)** — a third party can't borrow against the same escrow on its own account | Yes | **`test_third_party_borrow_blocked_by_guard`** (real EVC, `NotEngineSafe`); see [FarmUtilityBorrowGuard.md](FarmUtilityBorrowGuard.md) |
| I-6 | **repay exactness + withdraw-with-debt block** — over-repay reverts `E_RepayTooMuch`; withdraw with outstanding debt reverts `DebtOutstanding` | Yes | **`test_exact_repay_clears_debt_and_resets_allowance_overrepay_reverts`**, `test_withdraw_with_debt_reverts` |
| I-7 | **exec discipline + atomicity** — fixed exec shapes; a failed inner exec bubbles and rolls back (no dangling approval / partial state) | Yes | `test_exec_discipline_full`, **`test_atomicity_postCollateral_deposit_revert_rolls_back`**, `test_atomicity_repay_call_revert_rolls_back` |
| X-1 | §10.1 residual: operator sizes `(lpAmount, usdcAmount)` — bounded, not theft | **No** | bounded on-chain by F1 cap + EVK health + guard + receiver/owner pin; off-chain by the trusted CRE |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr / owner==operator / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_zero_address_evc`/`_juniorTrancheEngine`, `_rejects_owner_equals_operator`, `_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `NotOperator` on all 4 loop steps | `test_entrypoints_only_operator` |
| `ZeroAmount` (all 4 steps) | `test_zero_amount_reverts` |
| `CapExceeded` (F1) + `setBorrowCap` owner-only | `test_aggregate_cap_boundary_and_killswitch`, `test_setBorrowCap_only_owner` |
| `DebtOutstanding` (withdraw with debt) | `test_withdraw_with_debt_reverts` |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| 6 wiring setters (`setJuniorTrancheEngine`/`setEvc`/`setBorrowVault`/`setEscrowVault`/`setLpToken`/`setUsdc`) | `test_wiring_setters_onlyOwner_effect_and_zeroGuard` — onlyOwner + effect + zero-guard (all 6), incl. the `setJuniorTrancheEngine` avatar/target sync |

## 5. Attack surfaces

- **It borrows shared depositor USDC — and the three bounds are all tested on the live market** — the F1 aggregate
  cap + killswitch (I-2), the EVK over-LTV/no-collateral health checks (I-3), and the `FarmUtilityBorrowGuard`
  account-identity pin (I-5) each independently cap the borrow, and `test_full_loop_revolves_twice` proves the happy
  path round-trips against the real EVK/EVC with no duplicate enables and no standing approval. This is the most
  important property in the module and it is the best-covered.
- **Fail-closed on a bad oracle mark (I-4)** — a stale or never-pushed LP mark reverts the borrow (bubbled router
  `TooStale`/`NotSupported`), so the leverage can't open against a price the oracle won't stand behind. Tested both
  ways. (The oracle itself, `SzipFarmUtilityLpOracle`, has its own cluster in this suite — out of this module's scope.)
- **Repay exactness (I-6)** — EVK's `repay` reverts `E_RepayTooMuch` for a literal over-repay (only `type(uint).max`
  means "all"); the module repays the exact strike and resets the approval. Both the over-repay revert and the
  allowance reset are tested.
- **The 6 wiring setters — now covered** — `test_wiring_setters_onlyOwner_effect_and_zeroGuard` exercises
  `setJuniorTrancheEngine`/`setEvc`/`setBorrowVault`/`setEscrowVault`/`setLpToken`/`setUsdc` for onlyOwner + effect +
  zero-guard, including the `setJuniorTrancheEngine` avatar/target sync (`:147-153`, the borrower-of-record
  invariant). With `setBorrowCap` and `setOperator` (SEC-15), **every wiring setter is now exercised** — extra
  warranted here since several re-point what is borrowed against (`borrowVault`/`escrowVault`/`lpToken`).
- **No fuzz/invariant — acceptable** — the loop is a deterministic 4-step sequence whose hard properties (health,
  cap, debt) are enforced by the EVK and the cap check, both exercised on the real market. A stateful invariant over
  random post/borrow/repay/withdraw interleavings could add some assurance (e.g. "debt never exceeds cap", "withdraw
  never leaves the account unhealthy") but the EVK enforces those itself; lower priority than ExitGate's was.

## 6. Test analysis

| Category | Count (this module) | Notes |
|---|---|---|
| Unit | setUp/guards/SEC-14/15, exec-discipline, atomicity (×2), F1 cap/killswitch, zero-amount, entrypoint auth | mock-Safe for shape/atomicity |
| Base-fork (real EVK/EVC) | full-loop-revolves-twice, over-LTV, no-collateral, stale/never-pushed, withdraw-with-debt, exact-repay/over-repay, third-party-guard | the load-bearing borrow controls, all on the real market |
| Stateless fuzz / Foundry invariant | 0 | the hard properties are EVK-enforced + cap-checked; a stateful invariant is optional |

The full file is **43 tests, all passing** (`forge test --match-path test/FarmUtilityLoopModule.t.sol`) — incl. the
adjacent `SzipFarmUtilityLpOracle` cluster, the `FarmUtilityBorrowGuard` tests, and the CTR-07 farm utility-funding tests
(out of this module's scope). Coverage % uninstrumentable (project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — the highest-consequence fleet module (it borrows shared depositor USDC), and its load-bearing
controls are the best-covered after DurationFreezeModule: the F1 aggregate cap + killswitch, the EVK over-LTV /
no-collateral / stale-mark fail-closed checks, the guard's account-identity pin, repay exactness, and the full
4-step revolve are all proven **on the real EVK/EVC market**, with exec-discipline + atomicity on the mock side.
**Every wiring setter is now exercised** (the 6-setter gap, incl. the avatar/target sync, was filled).
Capped at ADEQUATE by: no fuzz/invariant (acceptable — the hard bounds are EVK-enforced and tested), the §10.1
operator-sizing residual (bounded by cap + health + guard), and the build-phase mutable wiring pending the pre-prod
re-freeze — none a coverage gap.

**Structural facts:**
1. 170 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no custody; borrower-of-record = the Safe's own EVC account (no operator bit).
2. 4 operator-only loop steps; receiver/owner/on-behalf all pinned to `juniorTrancheEngine`; `value==0`, no passthrough; `_exec` bubbles inner EVK/router reverts.
3. Three independent borrow bounds: F1 `borrowCap` (owner-only kill-switch) + EVK account-status health (over-LTV/stale-mark revert) + the `FarmUtilityBorrowGuard` account-identity pin — all tested on the real market.
4. Tests: ~17 loop-module tests (mostly base-fork) within a 43-test shared suite; every wiring setter exercised; 0 fuzz/invariant.
5. No outstanding coverage gap on the contract surface; residuals are off-chain (the §10.1 operator-sizing trust, bounded by cap+health+guard; the pre-prod wiring re-freeze).
