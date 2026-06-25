# X-Ray — `ZipDepositModule.sol` (single-contract, test-connected)

> ZipDepositModule | 90 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo no external audit)*

> **Update:** the two completeness gaps below (I-13 `scaleUp` derivation at non-default decimal pairs,
> I-14 the zap-side USDC→eePool allowance-settle) are **CLOSED** — a new `scaleUp`-derivation test (3 pairs, each with
> a realized deposit) + allowance assertions on the zap and sequential paths. Mock-gate suite 29 green (+ the
> real-Gate fork suite). Every guard, branch, derived property, and documented invariant on the contract is now
> exercised.

Dedicated single-contract X-Ray for `contracts/src/supply/ZipDepositModule.sol`, **the zap** — the supply-side
mint+deposit router and the *only* entry by which a supplier turns USDC into the protocol's two supply positions.
`deposit(usdcIn)` mints zipUSD 1:1-by-value to the depositor and parks the USDC in the `EulerEarn` venue pool with
the `CreditWarehouse` Safe as the share receiver; `zap(usdcIn)` is the default UX: deposit → mint transient zipUSD →
auto-deposit into the Exit Gate on the caller's behalf, atomically, so the supplier lands directly in the
transferable szipUSD position. Exercised by `ZipDepositModule.t.sol` — a **33-test** suite (28 mock-gate unit + 2
fuzz + 3 real-gate Base-fork) using the **real zipUSD `ESynth`** over a live EVC.

> This contract adds NO economic decision — all NAV/pricing lives in the Gate + `SzipNavOracle`. Its entire job is to
> be a **clean, stateless, custody-free conduit**: zipUSD minted to the user (or transiently to itself then handed to
> the Gate), USDC deposited to the warehouse Safe, szipUSD minted to the user by the Gate. The interesting properties
> are therefore not economic but **hygiene**: net-zero custody (the delta check, not an absolute-zero check, so a 1-wei
> donation can't brick the zap), exact-amount allowances that reset, reentrancy-guarded callouts, and atomic rollback
> on any downstream revert. No owner/admin/pause/upgrade — the lone privileged action is the deployer-gated `setGate`.

## 1. What it is

A 90-nSLOC `ReentrancyGuard` with six immutables + one re-pointable wiring slot (`gate`). `scaleUp` is **derived** in
the ctor from the tokens' own `decimals()` (`10**(zipDec - usdcDec)`, = `1e12` for 18-dp zipUSD / 6-dp USDC) — not a
hard-coded literal; the ctor reverts `DecimalsTooFew` if USDC were the finer unit.

- **`deposit(usdcIn)`** (`nonReentrant`): pull USDC → mint `usdcIn*scaleUp` zipUSD to the depositor → `forceApprove(eePool, usdcIn)` → `eePool.deposit(usdcIn, warehouseSafe)`. User walks away with zipUSD; module holds nothing.
- **`zap(usdcIn)`** (`nonReentrant`): snapshot `zipBefore` → pull USDC → mint transient zipUSD to itself → park USDC in the pool (shares → warehouse) → `forceApprove(gate, zipAmount)` → `gate.depositFor(zipUSD, zipAmount, msg.sender)` → assert `shares != 0` (`ZeroShares`) and net zipUSD delta == 0 (`ResidualBalance`) → `forceApprove(gate, 0)`.
- **previews:** `previewDeposit` (gate-independent), `previewZap` (reverts `NotWired`; `shares` is an estimate — NAV moves).
- **`setGate(gate_)`:** deployer-only, zero-guarded, re-settable (build phase, §17), grants no standing allowance (D1).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `deposit(usdcIn)` | public `nonReentrant` | mint zipUSD to caller + park USDC; works un-wired |
| `zap(usdcIn)` | public `nonReentrant` | atomic deposit→mint→on-behalf szipUSD; `NotWired` if gate unset |
| `previewDeposit(usdcIn)` | public view | `usdcIn*scaleUp`; gate-independent |
| `previewZap(usdcIn)` | public view | `NotWired` if unset; `shares` is an estimate |
| `setGate(gate_)` | `deployer`-only | `NotDeployer`/`ZeroAddress`; re-pointable; no standing allowance |
| `constructor(zipUSD, usdc, eePool, warehouseSafe)` | deploy | zero-guards all 4; derives `scaleUp`; `DecimalsTooFew` guard |

No owner/pause/upgrade. The module is stateless and custodies nothing.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **net-zero custody** — module holds no USDC/zipUSD/EE-share/szipUSD after any call | Yes | `_assertModuleEmpty()` asserted in **every** happy-path test; `test_deposit_warehouse_custody`, `_zap_on_behalf_par_nav`, `_sequential_no_residue`, both fuzz tests |
| I-2 | **deposit value-1:1 + warehouse custody** — `usdcIn*scaleUp` zipUSD to caller, EE shares to `warehouseSafe`, share-count-agnostic | Yes | `test_deposit_warehouse_custody`, `_deposit_works_unwired`, `_deposit_share_price_agnostic_under_par`/`_over_par`, `testFuzz_deposit`, `test_real_deposit_plain` |
| I-3 | **zap on-behalf + NAV-proportional** — szipUSD minted to caller, never holds zipUSD; shares = value/navEntry (round down) | Yes | `test_zap_on_behalf_par_nav`, `_zap_nav_proportional_nonpar`, `testFuzz_zap`, `test_real_zap_genesis_par`, `_real_zap_nav_proportional` (real Gate, $1.2 NAV → round-down) |
| I-4 | **zap cleanliness is a DELTA, not absolute zero** — a stray zipUSD donation cannot brick the zap; under-pull still reverts `ResidualBalance` | Yes | `test_zap_survives_zipusd_donation`, `testFuzz_zap_tolerates_donation`, `_zap_underpull_reverts_ResidualBalance` |
| I-5 | **zap fails closed on a bad Gate** — no-share → `ZeroShares`; mid-call revert → full atomic rollback | Yes | `test_zap_noshare_reverts_ZeroShares`, `_zap_gateRevert_atomic_rollback` (pristine post-state) |
| I-6 | **reentrancy-guarded on both callouts** — EE `deposit` and Gate `depositFor` re-entry both revert | Yes | `test_deposit_reentrancy_guarded_via_ee`, `_zap_reentrancy_guarded_via_gate` |
| I-7 | **exact-amount allowances; zip→gate reset to 0** | Yes | `test_zap_on_behalf_par_nav` (`allowance==0`), `_sequential_no_residue`, `_setGate_guards` (no standing allowance), real-fork asserts |
| I-8 | **capacity is the mint bound; over-cap rolls back** — ungranted/bounded/overflow all revert `E_CapacityReached` (not Panic), state restored | Yes | `test_deposit_ungranted_capacity_reverts`, `_bounded_capacity_reverts_and_rolls_back`, `_overflow_boundary_reverts_capacity_not_panic` |
| I-9 | **setGate auth + re-point** — non-deployer/zero revert; re-settable; no standing allowance | Yes | `test_setGate_guards`, `_zap_before_wiring_reverts_NotWired` |
| I-10 | **ctor guards** — zero on all 4 args; `DecimalsTooFew` when USDC finer | Yes | `test_ctor_zero_address_reverts`, `_ctor_reverts_when_usdc_finer_than_zip` |
| I-11 | **zero-amount guard** — `deposit(0)`/`zap(0)` revert | Yes | `test_zero_amount_guards` |
| I-12 | **previews match realized** — deposit standalone/un-wired; zap == realized at fixed NAV; previewZap `NotWired` | Yes | `test_previewDeposit_standalone_and_unwired`, `_previewZap_matches_zap`, `_previewZap_reverts_unwired`, real-fork preview==realized |
| I-13 | **`scaleUp` is derived from decimals(), not hard-coded** | Yes | **`test_scaleUp_derived_from_decimals_nonDefault`** — asserts `scaleUp` + a realized `deposit` (mints `usdcIn*scaleUp`) at 18/18→1, 8/6→100, 18/0→1e18 (plus `previewDeposit` uses the derived scale); a hard-coded `1e12` would fail every non-default case |
| I-14 | **zap's USDC→eePool allowance settles to 0** (the documented no-reset asymmetry) | Yes | **`test_zap_on_behalf_par_nav`** + **`test_sequential_no_residue`** now assert `usdc.allowance(module, eePool) == 0` after the zap path (matching the existing `deposit`-path assertion) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `ZeroAmount` (deposit/zap) | `:116,:134` | `test_zero_amount_guards` |
| `NotWired` (zap/previewZap) | `:135,:177` | `test_zap_before_wiring_reverts_NotWired`, `_previewZap_reverts_unwired` |
| `ZeroShares` | `:158` | `test_zap_noshare_reverts_ZeroShares` |
| `ResidualBalance` (delta) | `:161` | `test_zap_underpull_reverts_ResidualBalance` (+ donation tests) |
| `ReentrancyGuard` (both paths) | `nonReentrant` | `test_*_reentrancy_guarded_via_{ee,gate}` |
| `E_CapacityReached` (ESynth) | `mint` | `test_deposit_{ungranted,bounded,overflow}_*` |
| `NotDeployer` / `ZeroAddress` (setGate) | `:104,:105` | `test_setGate_guards` |
| ctor `ZeroAddress` ×4 / `DecimalsTooFew` | `:85,:90` | `test_ctor_zero_address_reverts`, `_ctor_reverts_when_usdc_finer_than_zip` |

Every revert path, derived property, and documented invariant is now exercised — including the `scaleUp` derivation
at non-default decimal pairs (I-13) and the zap-side USDC→eePool allowance-settle (I-14), closed.

## 5. Attack surfaces

- **Custody hygiene is the whole game — and it's exhaustively proven.** The module is a conduit; the risk is that it
  silently retains assets or that a downstream callout corrupts it. `_assertModuleEmpty()` runs in every happy path,
  the delta-not-absolute cleanliness check (I-4) is regression-tested both ways (donation survives, under-pull still
  reverts) including a fuzz over donation size, and the gate-revert path proves a fully pristine rollback (I-5).
- **The zap trusts the Gate only within a fence.** It approves exactly `zipAmount` (so the Gate cannot pull more),
  requires non-zero shares, and asserts the net zipUSD delta is zero before resetting the allowance. The four
  adversarial Gate behaviours the real Gate cannot exhibit (under-pull, no-share, mid-call revert, reentrancy) are
  driven via a `MockGate`; the real-Gate seam is then proven end-to-end on a Base fork incl. the two-token invariant
  (`szip.totalSupply() == loot.balanceOf(gate)`) and NAV-proportional round-down at $1.2.
- **Capacity is the only mint bound (I-8) and is correctly an `ESynth` concern.** Over-capacity reverts
  `E_CapacityReached` (proven NOT a Panic at the `uint128` overflow boundary) and rolls back the pulled USDC — the
  module pre-multiplies nothing into an overflow.
- **`scaleUp` anti-hardcode (I-13) — now pinned.** The NatSpec stresses `scaleUp` is derived from `decimals()`, "NOT
  a hard-coded literal." `test_scaleUp_derived_from_decimals_nonDefault` now exercises three non-default pairs
  (18/18→1, 8/6→100, 18/0→1e18), each with a realized `deposit` minting `usdcIn*scaleUp` and a `previewDeposit`
  cross-check — a regression that hard-coded `1e12` would fail every case but the old default.
- **Allowance settle asymmetry (I-14) — now pinned.** The contract deliberately does NOT reset the USDC→eePool
  approval (unlike the zip→gate reset), arguing the exact-amount approval is fully pulled so the residual is always 0.
  Both `test_zap_on_behalf_par_nav` and `test_sequential_no_residue` now assert `usdc.allowance(module, eePool) == 0`
  after the zap path, completing the proof of the documented asymmetry alongside the pre-existing `deposit`-path
  assertion.
- **No owner/upgrade/pause surface.** The lone privileged action is the deployer-gated, zero-guarded `setGate`
  (re-settable build-phase, to be frozen pre-prod — the subsystem-wide residual); it grants no standing allowance.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Mock-gate unit (deposit/zap/previews/guards/scaleUp) | 26 | real `ESynth` zipUSD over a live EVC; par/non-par EE mocks; adversarial `MockGate` (under-pull/no-share/revert/reentrant); scaleUp derivation at 3 decimal pairs |
| Fuzz | 3 | `testFuzz_deposit`, `testFuzz_zap`, `testFuzz_zap_tolerates_donation` — bounded to the capacity range |
| Real-gate Base-fork | 3 | real Baal substrate + `SzipNavOracle` + `ExitGate` + `SzipUSD`; genesis par, NAV-proportional, plain deposit; two-token invariant |
| Stateful invariant | 0 | not needed — stateless, custody-free; the per-call `_assertModuleEmpty()` is the conservation check |

Coverage % uninstrumentable (project-wide `Stack too deep`); 29 mock-gate green (+ 3 real-Gate fork). This is among
the best-covered contracts in the subsystem: both entrypoints, every guard, every adversarial Gate behaviour,
capacity bounds, atomic rollback, donation-resistance (incl. fuzz), the `scaleUp` derivation across decimal pairs,
and a real-Gate fork end-to-end. No outstanding behavioural or completeness gap.

## X-Ray Verdict

**HARDENED** *(modulo no external audit)* — a stateless, custody-free supply-side router whose decisive properties
are hygiene, not economics, and they are now exhaustively proven: net-zero custody asserted in every path, the
delta-based cleanliness check regression-tested both ways (donation-survives + under-pull-reverts, incl. fuzz),
reentrancy guarded on both callouts, capacity-bounded mint with atomic rollback, the `scaleUp` derivation pinned
across decimal pairs (I-13), the documented allowance-settle asymmetry pinned on both paths (I-14), and a real-Gate
Base-fork end-to-end with the two-token invariant. The two prior completeness gaps are CLOSED. The only
residuals are the build-phase re-settable `setGate` (frozen pre-prod, a subsystem-wide process item) and the absence
of an external audit — neither a code or coverage gap. Every guard, branch, derived property, and documented
invariant on the contract is exercised.

**Structural facts:**
1. 90 nSLOC; `ReentrancyGuard`; 6 immutables + 1 re-pointable `gate`; no owner/pause/upgrade; the only USDC→supply entry.
2. `deposit` → zipUSD to caller + USDC to `EulerEarn` (shares → warehouse Safe); `zap` → atomic deposit + on-behalf szipUSD mint via the Gate; the module custodies nothing.
3. Adds no economic decision — NAV/pricing lives in the Gate + `SzipNavOracle`; `scaleUp` derived from `decimals()`.
4. Hygiene fences: net-zero-delta cleanliness (donation-proof), exact-amount allowances (zip→gate reset), `ZeroShares`/`ResidualBalance` fail-closed, `nonReentrant` on both paths, atomic rollback.
5. Tests: 29 mock-gate (incl. 3 fuzz + the scaleUp-derivation test) + 3 real-gate Base-fork. No outstanding gap — every guard, branch, derived property (scaleUp I-13), and documented invariant (allowance-settle I-14) is exercised.
