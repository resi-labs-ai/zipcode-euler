# X-Ray — `SellModule.sol` (single-contract, test-connected)

> SellModule | 167 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/SellModule.sol`, the 8-B9 market-sell leg — pure
Algebra `SwapRouter` swap mechanism (no EVC, no oracle, no LP, no veNFT, no repay). Connected to
`test/SellModule.t.sol`: **34 unit + 4 base-fork = 38 tests, all passing** (0 fuzz, 0 invariant — deterministic
3-exec swaps). **Every mutator is exercised** (all 7 setters + the 3 swap legs).

> Distinctive control: a **per-call HYDX size cap** (`maxSellHydx`). `minOut` bounds *price* (slippage), not *size* —
> without the cap a compromised operator could dump the whole HYDX basket in one tx (`minOut=1`) and crater HYDX,
> which the protocol is long via veHYDX + the LP. The cap is the size backstop, and it's tested.

## 1. What it is

The sixth engine Zodiac `Module`, CRE-operator-gated, enabled on the engine Safe (`avatar == target ==
juniorTrancheEngine`). It owns the swap leg of the auto-compounder via three operator-only entrypoints, all sharing
one `_swap` (approve → `exactInputSingle` → reset):
- `sellHydx(amountIn, minOut, deadline)` — HYDX → USDC (the strike-loop repay feeder); **size-capped by `maxSellHydx`**.
- `buyXAlpha(...)` — zipUSD → xALPHA on our POL (the recycle buy leg).
- `sellXAlpha(...)` — xALPHA → zipUSD (the wind-down/unstrand hop; xALPHA has no direct USDC pool).

**The §10.1 boundary:** operator supplies only scalars (`amountIn`, `minOut`, `deadline`). The module builds all
calldata; `tokenIn`/`tokenOut` are hard-pinned per entrypoint, `deployer` pinned to `address(0)` (base-factory
pools), `recipient` pinned to the literal `juniorTrancheEngine` (output can only land in the basket), `limitSqrtPrice`
pinned to 0; `value==0`, no passthrough/delegatecall. `minOut` is the slippage guard (router reverts, bubbled); the
approve resets to 0 (no standing approval).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `sellHydx(amountIn, minOut, deadline)` | operator-only | HYDX→USDC; `amountIn > maxSellHydx` → `ExceedsMaxSell` (the size cap) |
| `buyXAlpha(...)` / `sellXAlpha(...)` | operator-only | zipUSD↔xALPHA on our POL; **not** size-capped (POL asset, bounded upstream) |
| `setMaxSellHydx(newMax)` | `onlyOwner` (Timelock) | resize the HYDX cap to track pool depth; `ZeroAmount` guard; not operator-settable |
| `setUp` + 7 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring (`setJuniorTrancheEngine` syncs avatar/target) |

No permissionless mutators. No custody, no recipient parameter except the pinned `juniorTrancheEngine`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **recipient + pair hard-pinned** — output mints only to `juniorTrancheEngine`; `tokenIn`/`tokenOut` per entrypoint; `deployer=0`, `limitSqrtPrice=0` | Yes | `test_sellHydx_exec_shape_fully_pinned`, `_buyXAlpha_`, `_sellXAlpha_` (decode the `ExactInputSingleParams`: recipient==Safe, pins), **`test_fork_real_sellHydx`** (USDC lands in the Safe) |
| I-2 | **`maxSellHydx` size cap** — `sellHydx` reverts `ExceedsMaxSell` above the cap; the buy/`sellXAlpha` legs are NOT capped | Yes | **`test_sellHydx_reverts_above_cap`**, `_at_cap_is_allowed`, `test_buyXAlpha_not_capped_by_maxSellHydx`, `test_sellXAlpha_not_capped_by_maxSellHydx` |
| I-3 | **`minOut` slippage guard** — the router reverts if `amountOut < minOut`; bubbled through `_exec` | Yes | **`test_fork_minOut_too_high_reverts_state_unchanged`** (real Algebra router), `_guards_zero_amountIn_and_zero_minOut` (×3 legs) |
| I-4 | **no standing approval** — approve→swap→reset; atomic rollback on failure | Yes | `test_state_moving_happy_path_resets_allowance`, **`test_state_moving_rollback_no_dangling_approval`**, fork (allowance 0 after) |
| I-5 | **exec false-return hard-reverts with bubbled inner data** | Yes | `test_exec_bubbles_custom_error`, `_no_data_ExecFailed`, `test_sellHydx_reverts_on_short/empty_return_data` |
| I-6 | **deadline enforced** — a past deadline reverts (router) | Yes | **`test_fork_past_deadline_reverts`** |
| X-1 | §10.1 residual: operator sizes `(amountIn, minOut, deadline)` — bounded, not theft | **No** | recipient/pair pin + the size cap + `minOut` cap it on-chain; throughput is 8-B11/8-B12 off-chain policy |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (×8) / owner==operator / zero `maxSellHydx` / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_zero_in_each_of_eight`, `_zero_swapRouter_is_ZeroAddress`, `_rejects_owner_equals_operator`, `_rejects_zero_maxSellHydx`, `_initializer_once`, `test_SEC14_mastercopy_setUp_reverts` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| SEC-15 caveat — `owner != operator` is enforced on `setUp` (`:110`) + `setOperator` (`:157`) but NOT on the inherited non-virtual `Ownable.transferOwnership` (`reference/zodiac-core/contracts/factory/Ownable.sol:19`) | (accepted residual — see note below) |
| `NotOperator` on all 3 swap legs | `test_sellHydx_only_operator`, `test_buyXAlpha_only_operator`, `test_sellXAlpha_only_operator` |
| `ZeroAmount` (amountIn / minOut, ×3 legs) | `test_*_guards_zero_amountIn_and_zero_minOut` |
| `ExceedsMaxSell` + `setMaxSellHydx` (owner-only, zero-guard, resize) | `test_sellHydx_reverts_above_cap`, `test_setMaxSellHydx_owner_resizes`/`_only_owner`/`_rejects_zero` |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| 6 wiring setters (`setJuniorTrancheEngine`/`setSwapRouter`/`setHydx`/`setUsdc`/`setZipUSD`/`setXAlpha`) | `test_wiring_setters_onlyOwner_effect_and_zeroGuard` — onlyOwner + effect + zero-guard (all 6), incl. the `setJuniorTrancheEngine` avatar/target sync |

## 5. Attack surfaces

- **The size cap is the distinctive control (I-2) — and it's tested** — `minOut` only bounds price, so the on-chain
  `maxSellHydx` ceiling is what stops a compromised operator from dumping the whole HYDX basket (which the protocol
  is long). Above-cap reverts, at-cap allowed, and the buy/`sellXAlpha` legs are correctly *not* capped (different
  token / our own POL). The cap is owner(Timelock)-resizable to track pool depth, also tested.
- **Recipient + pair pin (I-1) — proven on the live router** — the operator can't redirect the swap output or swap an
  arbitrary pair; `test_fork_real_sellHydx` confirms USDC lands in the Safe against the real Algebra router, and the
  exec-shape tests decode the `ExactInputSingleParams` to pin recipient/deployer/limitSqrtPrice.
- **Slippage + deadline abort (I-3/I-6)** — a too-high `minOut` or a past deadline reverts on the real router with
  state unchanged, so a bad-price or stale swap aborts rather than dumping.
- **The 6 wiring setters — now covered** — `test_wiring_setters_onlyOwner_effect_and_zeroGuard` exercises
  `setJuniorTrancheEngine`/`setSwapRouter`/`setHydx`/`setUsdc`/`setZipUSD`/`setXAlpha` for onlyOwner + effect +
  zero-guard, including the `setJuniorTrancheEngine` avatar/target sync (`:146-152`). With `setOperator` (SEC-15) and
  `setMaxSellHydx`, **every mutator on the contract is now exercised**.
- **No fuzz/invariant — correctly omitted** — three deterministic 3-exec swaps; the live-Algebra fork tests are the
  higher-value check and they exist.
- **SEC-15 covers `setOperator`, not `transferOwnership` (accepted residual)** — the "owner ≠ operator" invariant is
  re-checked on `setUp` (`:110`) and `setOperator` (`:157`), but the inherited `Ownable.transferOwnership`
  (`reference/zodiac-core/contracts/factory/Ownable.sol:19`) is **non-virtual** and carries no symmetric recheck, so a
  Timelock `transferOwnership(currentOperator)` could collapse the two roles. The only on-chain fix is to mark the
  vendored zodiac-core function `virtual` and override it — which the ratified posture at `SellModule.sol:203-206`
  deliberately declines for the parallel `setAvatar`/`setTarget` setters ("reference deps stay pristine"). Same
  accepted-residual class: `onlyOwner` (Timelock), unreachable by the CRE operator, no drain/redirect/escalation by any
  non-owner — a governance footgun, not an exploit path. Surfaced by the 2026-06-23 adversarial review (mission 4).

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 34 | setUp/guards, SEC-14/15, all 7 wiring setters (onlyOwner/effect/zero-guard + avatar/target sync), the fully-pinned exec-shape proof for all 3 legs, the size-cap matrix (above/at/uncapped legs), `setMaxSellHydx`, the bubble/atomicity matrix, zero-amount/minOut edges |
| Base-fork | 4 | real Algebra router: sig-verify, real `sellHydx` (USDC to the Safe, allowance reset), minOut-too-high abort, past-deadline revert |
| Stateless fuzz / invariant | 0 | deterministic swaps; fork is the higher-value check |

All **38 pass** (`forge test --match-path test/SellModule.t.sol`). The decisive properties (recipient/pair pin, size
cap, slippage/deadline abort, approval hygiene) are tested unit + live-fork. Coverage % uninstrumentable (project-wide
stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — a clean swap-leg fleet module whose load-bearing controls are well-covered: the recipient/pair pin
(proven on the real Algebra router), the `maxSellHydx` size cap (the defense against dumping the HYDX basket), the
`minOut`/deadline slippage abort, approval hygiene, and bubbled reverts. **Every mutator is now exercised** (all 7
setters + the 3 swap legs; the 6-setter gap, incl. the avatar/target sync, was filled 2026-06-20). Capped at
ADEQUATE by: no fuzz/invariant (correctly low-value for deterministic swaps), the §10.1 operator-sizing residual
(bounded by the size cap + `minOut` + the pins), and the build-phase mutable wiring pending the pre-prod re-freeze —
neither a coverage gap.

**Structural facts:**
1. 167 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no EVC/oracle/LP/veNFT — pure swap; no custody.
2. 3 operator-only swap legs sharing one `_swap` (approve→`exactInputSingle`→reset); recipient pinned to `juniorTrancheEngine`, `deployer=0`, `limitSqrtPrice=0`, `value==0`, no passthrough.
3. `sellHydx` size-capped by the owner-set `maxSellHydx` (size backstop; `minOut` is price-only); buy/`sellXAlpha` uncapped by design.
4. Tests: 34 unit + 4 base-fork (0 fuzz/invariant); every mutator exercised; recipient pin, size cap, slippage/deadline abort, approval hygiene proven — the swap paths against the real Algebra router.
5. No outstanding coverage gap on the contract surface; residuals are off-chain (the §10.1 operator-sizing trust, bounded by cap+minOut+pins; the pre-prod wiring re-freeze).
