# X-Ray — `ExerciseModule.sol` (single-contract, test-connected)

> ExerciseModule | 95 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/ExerciseModule.sol`, the 8-B8 paid-exercise leg —
a representative of the szipUSD **engine module fleet** (operator scalars → module-built calldata → Safe exec).
Connected to `test/ExerciseModule.t.sol`: **26 unit + 4 base-fork = 30 tests, all passing** (0 fuzz, 0 invariant —
a deterministic 3-exec sequence with no arithmetic). **Every mutator is exercised** (all 4 setters + the operator
action).

> This is the first *fleet-module* drill. It validates the shared shape — pinned recipient, fixed exec sequence,
> slippage delegated to the external option, no standing approval — that Sell/Recycle/Harvest/OffRamp reuse.

## 1. What it is

The fifth engine Zodiac `Module`, CRE-operator-gated, enabled on the engine Safe (`avatar == target ==
juniorTrancheEngine`). It owns the **paid** exercise of the harvest sell-slice: the CRE robot finances the ~30% USDC
strike via the 8-B5 borrow (USDC already in the Safe), then calls `exercise(amount, maxPayment, deadline)`. The
module runs **exactly three `exec`s**: (1) `paymentToken.approve(oHYDX, maxPayment)`, (2) `oHYDX.exercise(amount,
maxPayment, juniorTrancheEngine, deadline)` (burns the Safe's oHYDX, pulls the strike USDC, mints liquid HYDX to the
Safe), (3) `paymentToken.approve(oHYDX, 0)` (reset). 8-B9 then market-sells the HYDX to repay the borrow. **No
oracle, no EVC, no LP, no veNFT** — pure exercise mechanism.

**The §10.1 security boundary (the module's whole shape):** the operator supplies ONLY scalars (`amount`,
`maxPayment`, `deadline`). The module builds all calldata to the set-once wired targets; the exercise `recipient` is
**hard-pinned to the literal `juniorTrancheEngine`** — HYDX can only ever mint to the basket, never the operator or
a third party. No generic call/exec passthrough, no delegatecall, `value==0`. `maxPayment` is the **slippage guard**:
the immutable, Base-verified oHYDX computes the strike from its *own* TWAP and pulls exactly that, reverting if it
would exceed `maxPayment` — so a TWAP spike between the CRE's quote and execution safely *aborts* instead of
overpaying.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `exercise(amount, maxPayment, deadline)` | operator-only | 3 execs (approve→exercise→reset); recipient pinned; `PaymentExceedsMax` honesty re-assert on return |
| `quoteStrike(amount)` | `view` | `max(getDiscountedPrice, getMinPaymentAmount)` — 8-B5 sizes the borrow / 8-B11 the cushion off this |
| `setUp(initParams)` | `initializer` (clone) | decodes 4 addrs, reads `paymentToken` LIVE off `oHYDX.paymentToken()`, sets `avatar=target=juniorTrancheEngine` |
| `setJuniorTrancheEngine` | `onlyOwner` | re-points + syncs `avatar`/`target` |
| `setOperator` | `onlyOwner` | owner-recheck (SEC-15) |
| `setOHYDX` | `onlyOwner` | re-reads `paymentToken` LIVE off the new option (fail-closed) |
| `setPaymentToken` | `onlyOwner` | direct override (normally LIVE-derived) |

No permissionless mutators. Single operator-gated action.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **recipient hard-pinned** — HYDX mints only to `juniorTrancheEngine`, never operator/3rd party | Yes | **`test_exec_shape_fully_pinned`** (decodes exercise arg 3 == Safe), `test_state_moving_happy_path_resets_allowance` (`lastRecipient == juniorTrancheEngine`), **`test_fork_real_exercise`** (HYDX minted to the Safe) |
| I-2 | **fixed 3-exec shape** — approve(maxPayment) → exercise → approve(0); `value==0`, `Operation.Call`, no passthrough/delegatecall | Yes | `test_exec_shape_fully_pinned` (`callCount==3`, each call's target+calldata asserted) |
| I-3 | **`maxPayment` slippage guard** — oHYDX pulls ≤ maxPayment and reverts otherwise; module re-asserts on the decoded return (`PaymentExceedsMax`) | Yes | **`test_fork_maxPayment_too_low_reverts_state_unchanged`** (real oHYDX slippage revert, bubbled), `test_exercise_reverts_paymentExceedsMax` (honesty guard on a misreporting return) |
| I-4 | **no standing approval** — reset-to-0 clears the residual; an atomic revert rolls the approve back | Yes | `test_state_moving_happy_path_resets_allowance` (allowance 0 after), **`test_state_moving_rollback_no_dangling_approval`**, `test_fork_*` (allowance == 0) |
| I-5 | **exec false-return hard-reverts with bubbled inner data** (the Safe swallows reverts → an unchecked exec would silently report success) | Yes | `test_exec_bubbles_custom_error` (surfaces `ExerciseBoom`), `test_exec_bubbles_no_data_ExecFailed`, `test_exercise_reverts_on_short/empty_return_data` |
| I-6 | **`paymentToken` is LIVE-read off the option** — the approve target can't drift from the option's actual payment token | Yes | `test_setUp_rejects_zero_paymentToken_live`, **`test_fork_sig_verify`** (`paymentToken()` live-read == USDC) |
| I-7 | `quoteStrike == max(discounted, floor)`, and equals the same-block charge | Yes | `test_quoteStrike_max_each_side_wins`/`_floor_at_zero`/`_tie`, **`test_fork_real_exercise`** (`paymentAmount == quoteStrike` read same block) |
| X-1 | §10.1 residual: operator trusted for `(amount, maxPayment, deadline)` — bounded, not theft | **No** | the bound is on-chain (recipient pin + `value==0` + no passthrough); operator honesty (cushion sizing) is the off-chain 8-B11 concern |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (×4) / owner==operator / live-zero paymentToken | `test_setUp_rejects_zero_in_each_of_four`, `_rejects_owner_equals_operator`, `_rejects_zero_paymentToken_live`, `_zero_oHYDX_is_ZeroAddress_not_staticcall` |
| `initializer` once + mastercopy lock (SEC-14) | `test_setUp_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `setOHYDX` re-derives `paymentToken` LIVE (+ fail-closed on zero) | `test_setOHYDX_repoints_and_rederives_paymentToken` |
| `setJuniorTrancheEngine` syncs `avatar`/`target` | `test_setJuniorTrancheEngine_syncs_avatar_and_target` |
| `setPaymentToken` direct override (onlyOwner + zero-guard) | `test_setPaymentToken_override_onlyOwner_and_zeroGuard` |
| `NotOperator` | `test_exercise_only_operator` |
| `ZeroAmount` (amount or maxPayment) | `test_guards_zero_amount_and_zero_maxPayment` |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| `ExecFailed` (empty-data revert) | `test_exec_bubbles_no_data_ExecFailed` |

## 5. Attack surfaces

- **The recipient pin is the whole point (I-1) — and it's proven on a live fork** — the operator cannot redirect the
  minted HYDX; the exercise `recipient` is the literal `juniorTrancheEngine`. `test_exec_shape_fully_pinned` decodes
  the actual exercise calldata to confirm arg 3 is the Safe, and `test_fork_real_exercise` confirms HYDX lands in the
  Safe against the real oHYDX. No recipient parameter exists for the operator to set.
- **Slippage is delegated to the external option (I-3)** — the module does not compute the strike; oHYDX does, from
  its own TWAP, and enforces `paymentAmount ≤ maxPayment`. This is a deliberate trust in the immutable, Base-verified
  oHYDX. The on-chain belt-and-suspenders is the `PaymentExceedsMax` re-assert on the decoded return + the USDC
  approval capped at `maxPayment` (so even a misreporting return can't pull more). The residual is **off-chain**: if
  8-B11 sizes the `maxPayment` cushion too loose, a TWAP spike could be paid *within* the cushion — a griefing-cost
  ceiling, not a leak.
- **Bubbled reverts prevent silent success (I-5)** — the Gnosis Safe returns `(false, revertData)` on an inner
  revert rather than bubbling; `_exec` hard-reverts and re-throws the inner data, so a failed exercise can never be
  recorded as a successful step. Tested with a custom error, empty data, and short/empty return decodes.
- **Build-phase mutable wiring — now fully covered** — 4 `onlyOwner` setters. The two side-effects flagged in the
  first draft are now tested: `test_setOHYDX_repoints_and_rederives_paymentToken` (re-points the option, re-derives
  `paymentToken` LIVE off the new option, fail-closed on a zero payment token) and
  `test_setJuniorTrancheEngine_syncs_avatar_and_target` (re-point keeps `juniorTrancheEngine`/`avatar`/`target` in
  lockstep). The `onlyOwner` gate is also re-asserted on both. The remaining residual is the deferred pre-prod
  immutable re-freeze (process, not code).
- **No fuzz/invariant — correctly omitted** — `exercise` is a deterministic 3-call sequence and `quoteStrike` is a
  `max` of two external reads; there is no internal arithmetic for a fuzzer to probe. The fork test against the real
  oHYDX is the higher-value check, and it exists.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 26 | setUp/guards, the SEC-14/15 clone-safety pair, all three wiring setters (`setOHYDX` paymentToken re-derive, `setJuniorTrancheEngine` avatar/target sync, `setPaymentToken` override), the fully-pinned exec-shape proof, the bubble/atomicity matrix (custom error, empty/short data, rollback), the `quoteStrike = max` cases, live-rig state-moving happy + rollback |
| Base-fork | 4 | real oHYDX on Base: sig-verify (live `paymentToken`/`discount`/`getMinPaymentAmount`), real exercise (burn/pull/mint + `paymentAmount == quoteStrike` same block), maxPayment-too-low rollback, past-deadline revert |
| Stateless fuzz / invariant | 0 | deterministic; no arithmetic — fork test is the higher-value check |

All **30 pass** (`forge test --match-path test/ExerciseModule.t.sol`). The decisive properties (recipient pin,
fixed exec shape, slippage abort, no standing approval, bubbled reverts) are all tested, **including on a live fork
against the real deployed oHYDX**. Coverage % uninstrumentable (project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — a clean, tightly-scoped fleet module: operator supplies only scalars, the module builds all calldata
to set-once targets, the mint recipient is hard-pinned to the basket, the strike is slippage-bounded by the external
option with an on-chain `PaymentExceedsMax` backstop, and no standing approval survives. Its load-bearing properties
are tested unit + live-fork, and the same-block `paymentAmount == quoteStrike` check answers the "does the view match
the charge" question directly. **Every mutator on the contract is now exercised** (all 4 setters + the operator
action; the side-effects flagged in the first draft were filled 2026-06-20). The remaining distance to HARDENED is
**not a coverage gap** — it is (a) the deliberate, justified absence of fuzz/invariant (a deterministic 3-call
sequence with no arithmetic gives a fuzzer nothing to probe) and (b) two off-chain residuals no test in this file
can reach: the `maxPayment`-cushion sizing (§10.1 / 8-B11) and the pre-prod immutable re-freeze (process, not code).

**Structural facts:**
1. 95 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no oracle/EVC/LP/veNFT — pure exercise.
2. Operator supplies `(amount, maxPayment, deadline)`; module builds all calldata; recipient = literal `juniorTrancheEngine`; `value==0`, no delegatecall/passthrough.
3. Exactly 3 execs: approve(maxPayment) → exercise → approve(0); slippage enforced by oHYDX's own TWAP + a `PaymentExceedsMax` re-assert + the maxPayment-capped approval.
4. `_exec` bubbles inner revert data so a Safe-swallowed failure can never report success.
5. Tests: 26 unit + 4 base-fork (0 fuzz/invariant); every mutator exercised — recipient pin, exec shape, slippage abort, approval hygiene, and all 4 setters proven — the slippage/mint paths against the real oHYDX.
