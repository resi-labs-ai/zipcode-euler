# X-Ray — `LienXAlphaEscrow.sol` (single-contract, test-connected)

> LienXAlphaEscrow | 96 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

Dedicated single-contract X-Ray for `contracts/src/loss/LienXAlphaEscrow.sol`, the custody half of the loss
subsystem (the bundled `loss/x-ray/x-ray.md` is the scope overview; this is the per-contract file). Connected to
`test/LienXAlphaEscrow.t.sol` (44 unit + 1 fuzz + 2 invariant + 5 reentrancy). The orchestrator half,
`DefaultCoordinator`, has its own file.

## 1. What it is

A standalone, **non-sweepable** custody contract holding the originator's xALPHA first-loss bond per lien. NOT a
Zodiac module, NOT a Baal shaman, NOT a `ReceiverTemplate` — a plain `Ownable` + `ReentrancyGuard` vault whose
four state-changers are all `onlyCoordinator`. `lockXAlpha` posts the bond at origination; `releaseXAlpha` returns
it on repayment; `slashXAlphaToCapital` routes to the treasury (realized capital hole) and `slashXAlphaToCohort`
routes the premium remainder to the engine Safe.

**Security thesis — destination integrity, not authorization correctness:** no state-changer takes a recipient
parameter; xALPHA can only ever flow to three destinations — the recorded `bondOriginator` (captured at lock), the
`adminSafe`, the `juniorTrancheSafe`. So a compromised `coordinator` can only **grief** (premature release / slash a
healthy bond), never redirect to an attacker. (Build-phase caveat: the sinks are Timelock-set, so the absolute
holds against everyone except the Timelock owner until the pre-prod immutable re-freeze.)

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `lockXAlpha(lienId, originator, amount)` | `onlyCoordinator` + `nonReentrant` | pulls the bond from the coordinator; no clobber (`BondExists`); CEI |
| `releaseXAlpha(lienId)` | `onlyCoordinator` + `nonReentrant` | returns the FULL bond to the recorded originator; CEI (both mappings zeroed first) |
| `slashXAlphaToCapital(lienId, amount)` | `onlyCoordinator` + `nonReentrant` | routes `amount ≤ bond` to `adminSafe`; lien stays open with the remainder |
| `slashXAlphaToCohort(lienId)` | `onlyCoordinator` + `nonReentrant` | routes the entire remaining bond (the premium) to `juniorTrancheSafe`; CEI |
| `setXAlpha` / `setCoordinator` / `setAdminSafe` / `setJuniorTrancheSafe` | `onlyOwner` (Timelock) | build-phase re-point (§17) |

No permissionless entry points; no recipient parameter anywhere.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-5 | escrow holds exactly `Σ bondAmount[lienId]`; all transfers use recorded amounts, never `balanceOf` (donation-immune) | Yes | **`invariant_escrowBalance_eq_sumBonds`**, **`testFuzz_lock_slash_preserves_balance`** |
| — | destination integrity: xALPHA flows only to originator / adminSafe / juniorTrancheSafe (no recipient param) | Yes | **`invariant_conservation_three_destinations`**, `test_no_sweep_surface_abiNegative` |
| — | bond state machine: lock-once (`BondExists`), release/cohort zero both mappings, slash bounded by bond; re-lock only after a clean exit | Yes | `test_lock_reLockBondedLien_reverts`, `test_reLock_after_release`, `_after_cohort_clears`, `test_bondOriginator_survives_partial_slash` |
| X-2 | destination integrity is absolute only once sinks are immutable; Timelock can re-point in the build phase | **No** (build phase) | `test_setWiring_onlyOwner_and_updates`, `_nonOwner_reverts`, `_zero_reverts` |
| — | CEI + `nonReentrant` on every path (xALPHA is hookless today; belt-and-suspenders) | Yes | `test_reentrancy_release_sameFn_blocked`, `_release_crossFn_blocked`, `_cohort_sameFn_blocked`, `_lock_reentry_blocked`, `_outer_completes_balance_moves_once` |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| G-13 ctor all four wiring slots ≠ 0 | `test_ctor_zero_xAlpha_reverts`, `_zero_coordinator_`, `_zero_adminSafe_`, `_zero_juniorTrancheSafe_` |
| G-14 setter zero-address (`ZeroWiring`) | `test_setWiring_zero_reverts` |
| G-15 lock: real originator, not self, amount ≠ 0, no clobber | `test_lock_zeroOriginator_reverts`, `_selfOriginator_reverts`, `_zeroAmount_reverts`, `_reLockBondedLien_reverts` |
| G-16 slashToCapital: amount ≠ 0, ≤ bond | `test_slashToCapital_zeroAmount_reverts`, `_overByOne_reverts_exceedsBond`, `_exactBoundary_passes`, `_unbonded_reverts_exceedsBond` |
| G-17 release / cohort need an existing bond | `test_release_unbonded_reverts_noBond`, `test_slashToCohort_reCall_reverts_noBond_noTransfer` |
| `onlyCoordinator` on all four | `test_lock_nonCoordinator_reverts`, `_release_nonCoordinator_`, `_slashToCapital_nonCoordinator_`, `_slashToCohort_nonCoordinator_` |
| CEI on failed pull (no orphan) | `test_lock_failedPull_leaves_no_orphan` |

## 5. Attack surfaces

- **Destination integrity is the whole defense** — no path takes a recipient. A compromised `coordinator`
  griefs (premature release / slash a healthy bond) but cannot steal. Tested: no-sweep ABI-negative + the
  conservation invariant. The residual is the build-phase mutable sinks (X-2).
- **Build-phase mutable wiring (X-2)** — `setAdminSafe`/`setJuniorTrancheSafe`/`setCoordinator`/`setXAlpha`
  re-pointable by the Timelock; the theft-immunity absolute lands at the deferred pre-prod immutable re-freeze
  (process, not on-chain). Tested for owner-gating + zero-reject.
- **Exact-amount allowance from the coordinator** — `lockXAlpha`'s `safeTransferFrom(coordinator, …)` pull is the
  only way funds enter. The coordinator grants the escrow only an exact-amount just-in-time allowance per lock and
  resets it to 0 (LOSS-ADV-01); there is **no standing allowance**. (The earlier MAX allowance was NOT made safe by
  the escrow's non-sweepability — an ERC-20 allowance authorizes the spender to move the owner's tokens to ANY
  destination, so a standing MAX to a re-pointable escrow was a drain primitive over the coordinator's reserve; the
  JIT approval closes it.) `test_lock_zeroAllowance_reverts` / `_insufficientBalance_reverts` pin the pull.
- **`_resolve` over-bond (driven by the coordinator)** — `slashXAlphaToCapital` reverts `ExceedsBond`, which
  atomically rolls back the coordinator's whole resolution. `test_slashToCapital_overByOne_reverts_exceedsBond`
  + the coordinator-side `test_resolve_exceedsBond_atomic_rollback`.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 44 | every guard, the full bond lifecycle, ordered resolution (capital-then-cohort), multi-lien independence, re-lock-after-exit |
| Stateless fuzz | 1 | `testFuzz_lock_slash_preserves_balance` — escrow balance tracks Σ bonds across lock/slash |
| Stateful invariant | 2 | escrow balance == Σ bonds; three-destination conservation |
| Reentrancy | 5 | same-fn / cross-fn / lock-reentry / outer-completes-once — the CEI + `nonReentrant` belt-and-suspenders |

Among the **best-tested contracts reviewed** — unit + fuzz + invariant + a dedicated reentrancy battery.
Coverage % uninstrumentable (project-wide stack-too-deep); existence + green run confirmed by scan.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — non-sweepable custody with destination integrity by construction (no
recipient parameter), CEI + `nonReentrant` everywhere, and the load-bearing properties (per-lien conservation /
donation-immunity, three-destination routing) under fuzz + Foundry invariants, plus a reentrancy battery. Capped
at ADEQUATE only by: no in-scope spec file and no emergency pause (mitigated by non-sweepability + the
grief-only blast radius). Tests axis is individually HARDENED.

**Structural facts:**
1. 96 nSLOC; plain `Ownable` + `ReentrancyGuard`; 4 `onlyCoordinator`+`nonReentrant` state-changers + 4 Timelock setters; 0 permissionless surface.
2. No recipient parameter on any path — xALPHA reaches only `bondOriginator` / `adminSafe` / `juniorTrancheSafe`.
3. Tests: 44 unit + 1 fuzz + 2 invariant + 5 reentrancy — conservation + three-destination routing invariant-asserted.
4. Non-sweepable; the coordinator grants only an exact-amount just-in-time allowance per lock (no standing allowance — LOSS-ADV-01), so a re-pointed escrow has no allowance to drain the coordinator's reserve.
5. Build-phase wiring is Timelock-re-pointable; destination integrity is absolute after the deferred pre-prod immutable re-freeze (process, not code) — the X-2 residual.
