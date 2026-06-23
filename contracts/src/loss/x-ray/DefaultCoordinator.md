# X-Ray — `DefaultCoordinator.sol` (single-contract, test-connected)

> DefaultCoordinator | 158 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

Dedicated single-contract X-Ray for `contracts/src/loss/DefaultCoordinator.sol`, the orchestrator half of the
loss subsystem (the `bridge/x-ray/x-ray.md`-style bundled `loss/x-ray/x-ray.md` is the scope overview; this is the
per-contract file). Connected to `test/DefaultCoordinator.t.sol` (66 unit + 1 fuzz + 3 invariant). The custody
half, `LienXAlphaEscrow`, gets its own file.

## 1. What it is

The single loss-side orchestrator: a CRE-gated `ReceiverTemplate` that is the immutable `LienXAlphaEscrow.coordinator`
(owns the xALPHA bond lifecycle) AND the `SzipNavOracle.defaultCoordinator` (the sole `writeProvision` caller).
Every action flows through `_processReport` (reportType 8, action-discriminated) behind the Timelock-pinned
Forwarder. Ownership transfers to the Timelock at deploy (governs `recoveryFloor` + build-phase wiring; **no theft,
no NAV-inflation, no sweep, no pause**). It custodies the launch xALPHA reserve; the escrow holds **no standing
allowance** — `_lock` grants the exact bond `amount` just-in-time around its pull and resets to 0 (LOSS-ADV-01),
so a re-pointed escrow has nothing to drain.

**The §13 trust posture (load-bearing):** this contract *bounds and routes*; it does **not** validate that a default
is real. The CRE is trusted for magnitude/timing/split/originator; the on-chain guarantees are the narrow arithmetic
bounds + the lien status machine. A compromised CRE can grief (down-mark NAV, slash a healthy bond, reclaim a fresh
bond via a hostile originator) but cannot steal to an arbitrary address or inflate NAV.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `_processReport` (via `onReport`) | Forwarder-gated (CRE) | reportType-8 dispatcher → `_lock`/`_release`/`_default`/`_recovery`/`_resolve`/`_writeOff` |
| `setEscrow(escrow_)` | `onlyOwner` (Timelock) | wires escrow; NO standing allowance (JIT in `_lock`, LOSS-ADV-01); re-pointable (§17) |
| `setNavOracle(navOracle_)` | `onlyOwner` | re-point the provision sink |
| `setXAlpha(xAlpha_)` | `onlyOwner` | re-point bond asset (+ re-approve escrow) |
| `setRecoveryFloor(newFloor)` | `onlyOwner` | bound `<1e18`; future defaults only |

No permissionless entry points. Internal handlers (`_lock`…`_writeOff`) are reachable only via the Forwarder dispatch.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | `totalProvision == Σ lienLoss[lienId].provision` (incl. WrittenOff residual) | Yes | **`invariant_totalProvision_eq_sum`**, **`invariant_totalProvision_le_ghostCap`** |
| S5 | `navOracle.provision() == totalProvision` (sole writer; pushed after every change) | Yes | **`invariant_oracle_eq_totalProvision`** |
| I-2 | default provision = `atRisk·(1−recoveryFloor)/1e18`, rounded down; floor ∈ [0,1e18) | Yes | **`testFuzz_provision_bound`**, `test_default_happy_bound_and_coemit`, `_highFloor_boundary`, `_floorZero_full_atRisk`, `_truncation_pin` |
| I-3 | recovery never heals below 0: `reduction = min(provision, proceeds)` | Yes | `test_recovery_overshoot_floors_at_zero`, `_exact_to_zero`, `_multiple_accumulate_down` |
| I-4 | status machine `None→Bonded→{None|Defaulted}`, `Defaulted→{Resolved|WrittenOff}`, no reverse/re-entry | Yes | **`test_full_illegal_transition_matrix`**, `test_lock_on_resolved_and_writtenoff_reverts_badStatus`, + per-action `_badStatus` tests |
| X-1 | CRE-supplied magnitude/timing/originator trusted (grief-bounded, not theft) | **No** | §13 boundary; on-chain code caps damage — `test_resolve_exceedsBond_atomic_rollback`, `test_no_sweep_freeze_immutable_abiNegative` |
| E-1 | provision only falls by `atRisk·(1−floor)`, heals by realized receipts/to 0, floored at 0, never above un-impaired basket; WriteOff keeps residual | Yes | follows from I-1+I-2+I-3+I-4; `test_writeoff_partial_keeps_provision_no_coemit` |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| G-1 ctor navOracle/xAlpha ≠ 0 | `test_ctor_zero_navOracle_reverts`, `_zero_xAlpha_reverts` |
| G-2 ctor recoveryFloor < 1e18 | `test_ctor_recoveryFloor_eq_1e18_reverts`, `_above_1e18_reverts`, `_accepts_floor_zero_and_max` |
| G-3/4/5 setter zero-address | `test_setEscrow_zero_reverts`, `_setNavOracle_repoint_and_onlyOwner`, `_setXAlpha_repoint_reapproves_escrow` |
| G-6 setRecoveryFloor < 1e18 | `test_setRecoveryFloor_eq_1e18_reverts` |
| G-7 reportType == 8 | `test_dispatch_wrongReportType_reverts` |
| G-8 valid action enum | `test_dispatch_invalidAction_reverts` |
| G-9 lock from None | `test_lock_reLock_bonded_reverts_badStatus`, `_on_defaulted_reverts_badStatus` |
| G-10 release/default need Bonded | `test_release_neverBonded_reverts_badStatus`, `test_default_nonBonded_reverts_badStatus` |
| G-11 atRisk ≠ 0 | `test_default_zeroAtRisk_reverts` |
| G-12 recovery/resolve/writeoff need Defaulted | `test_recovery_nonDefaulted_…`, `test_resolve_nonDefaulted_…`, `test_writeoff_then_action_terminal_badStatus` |
| Forwarder + workflow-id gate | `test_onReport_nonForwarder_reverts`, `_workflowId_mismatch_reverts`, `_match_passes` |
| Exact-amount JIT allowance; no standing allowance (LOSS-ADV-01) | `test_setEscrow_emits_and_grants_no_standing_allowance`, `test_setEscrow_repoint_works_no_standing_allowance`, `test_setXAlpha_repoint_no_standing_allowance`, `test_lock_jit_allowance_leaves_no_standing_allowance` |

## 5. Attack surfaces

- **CRE residual-trust ceiling (X-1)** — `_processReport:181` + handlers trust CRE magnitude/timing/originator. The
  grief paths are tested to stay grief (atomic rollback on over-bond `test_resolve_exceedsBond_atomic_rollback`; no
  sweep `test_no_sweep_freeze_immutable_abiNegative`; status machine forbids escalation). Remains On-chain=No by
  design — DON consensus + the bounds are the control.
- **Unsmoothed provision → exit** — `_default:244` calls `writeProvision(totalProvision)` immediately; a default
  instantly down-marks NAV (concurrent exiters exit-poor). Documented/accepted; the interaction lives in the exit
  path (out of scope). `test_setRecoveryFloor_applies_to_next_default_only` pins the non-retroactive floor.
- **Build-phase mutable wiring** — `setEscrow`/`setNavOracle`/`setXAlpha` re-pointable by the Timelock; tested
  (`test_setEscrow_repoint_*`, `test_setNavOracle_repoint_*`). The destination-integrity absolute holds after the
  deferred pre-prod immutable re-freeze (process step, not on-chain). **LOSS-ADV-01 (closed):** `setEscrow`
  formerly granted a standing MAX xALPHA allowance, which made re-pointing the escrow a *drain* of the launch
  reserve (an ERC-20 allowance lets the spender pick the destination — the escrow's non-sweepability is
  irrelevant). Now `_lock` grants only the exact bond `amount` JIT and resets to 0, so re-pointing the escrow is
  grief/redirect like every other slot — no standing allowance to drain.
- **`_writeOff` leaves residual provision in place** — intentional (the realized loss). `test_writeoff_partial_keeps_provision_no_coemit` confirms it does NOT call `writeProvision`. Worth confirming NAV consumers expect a permanent floor for written-off liens.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 66 | every guard, the full status machine (incl. the illegal-transition matrix), all six actions, multi-lien independence, the integration-with-real-collaborators paths |
| Stateless fuzz | 1 | `testFuzz_provision_bound` — the default bound across (atRisk, proceeds, floor) |
| Stateful invariant | 3 | conservation (`==Σ`), oracle-equality (sole writer), `≤ ghostCap` |

The **best-tested contract reviewed** — unit + fuzz + invariant, with the conservation invariant *and* the
cross-contract `oracle.provision() == totalProvision` seam both fuzz-asserted. Coverage % uninstrumentable
(project-wide stack-too-deep); existence + green run confirmed by scan.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — roles + Timelock + CEI throughout, no permissionless surface, and the
load-bearing properties (provision conservation, the default bound, the lien status machine, the sole-writer ↔
oracle seam) are all under fuzz + Foundry invariants. Capped at ADEQUATE only by: no in-scope spec file and no
emergency pause; the Tests axis is individually HARDENED.

**Structural facts:**
1. 158 nSLOC; non-upgradeable `ReceiverTemplate`; 0 permissionless entry points (Forwarder/CRE + 4 Timelock setters).
2. Sole `writeProvision` caller into `SzipNavOracle`; immutable `coordinator` of `LienXAlphaEscrow`; holds the launch xALPHA reserve and grants the escrow only an exact-amount just-in-time allowance per lock (no standing allowance — LOSS-ADV-01).
3. Tests: 66 unit + 1 fuzz + 3 invariant — the conservation + oracle-equality seams are invariant-asserted.
4. §13: bounds-and-routes only; a compromised CRE is bounded to grief, never theft/NAV-inflation (status machine + arithmetic bounds + no recipient parameter).
5. Build-phase wiring is Timelock-re-pointable; the destination-integrity absolute lands at the deferred pre-prod immutable re-freeze (process, not code).
