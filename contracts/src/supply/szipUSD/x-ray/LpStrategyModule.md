# X-Ray — `LpStrategyModule.sol` (single-contract, test-connected)

> LpStrategyModule | 166 nSLOC | `main`, working tree | Foundry | 23/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/LpStrategyModule.sol`, the 8-B6 LP-strategy leg —
the fleet module that owns the zipUSD/xALPHA ICHI LP lifecycle (build / gauge-stake / unstake / dissolve) and
carries the **coverage path-lock seam** back to `DurationFreezeModule`. Connected to `test/LpStrategyModule.t.sol`:
**33 unit + 5 base-fork = 38 tests, all passing** (0 fuzz, 0 invariant — deterministic multi-`exec` sequences).
**Every mutator is exercised** (all 7 setters + the 4 operator actions).

> The distinctive property here is the **path-lock**: `removeLiquidity` may only liquefy LP that is *excess* over the
> coverage floor — the on-chain enforcement of the same floor `DurationFreezeModule` gates `release`/exit by. That
> seam (`lpBurnKeepsCovered`) is the highest-value thing to verify, and it is tested across all three gate states.

## 1. What it is

The third engine Zodiac `Module`, CRE-operator-gated, enabled on the engine Safe (`avatar == target ==
juniorTrancheEngine`). It owns the LP's whole lifecycle:
- `addLiquidity(deposit0, deposit1, minShares)` — approve + `IICHIVault.deposit` (single-sided or balanced Mode-C) +
  reset approvals; the minted LP lands in the Safe.
- `removeLiquidity(shares, minAmount0, minAmount1)` — `IICHIVault.withdraw` back to legs; **coverage-gated** (the
  wind-down LP→legs hop).
- `stake(lpAmount)` / `unstake(lpAmount)` — gauge-stake to farm oHYDX / unstake for the 8-B5 harvest loop.

**The §10.1 security boundary:** the operator supplies ONLY scalar amounts. The module builds all calldata to
set-once targets, the deposit `to` + every balance read is `juniorTrancheEngine`, `value==0`, no
delegatecall/passthrough, no EVC/borrow leg. It writes **no storage** in any mutating path and holds no custody (the
Safe holds tokens, LP, and the staked position).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `addLiquidity(d0, d1, minShares)` | operator-only | approve→deposit→reset (3 or 5 execs); `ZeroAmount`/`ZeroMinShares`/`Slippage` guards; `to == juniorTrancheEngine` |
| `removeLiquidity(shares, min0, min1)` | operator-only | 1 exec `withdraw`; **coverage-gated** (`Undercovered`); `Slippage` floors |
| `stake(lpAmount)` | operator-only | approve→deposit→reset (3 execs) |
| `unstake(lpAmount)` | operator-only | 1 exec `gauge.withdraw` |
| `stakedBalance` / `lpBalance` | `view` | read `juniorTrancheEngine` off the gauge / vault |
| `setUp` + 7 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring (incl. `setCoverageGate`, where zero = gate OFF) |

No permissionless mutators. No custody, no recipient parameter except the pinned `juniorTrancheEngine`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| X-1 | **coverage path-lock** — `removeLiquidity` reverts `Undercovered` unless `coverageGate.lpBurnKeepsCovered(shares)`; gate==0 ⇒ ungated (M1 legacy) | Yes (reads `DurationFreezeModule`) | **`test_removeLiquidity_coverage_gate`** — all three states: gate `false` → `Undercovered`, gate `true` → dissolves, gate OFF (0) → ungated |
| I-1 | **deposit `to` + all balance reads hard-pinned to `juniorTrancheEngine`** | Yes | `test_exec_discipline_addLiquidity_single`/`_both_legs` (deposit `to == safe`), `test_views_read_juniorTrancheEngine`, **`test_fork_real_vault_single_sided_deposit`** (shares land in the Safe) |
| I-2 | **no standing approval** — approve→deposit→reset; atomic rollback on inner failure | Yes | `test_exec_discipline_*`, **`test_atomicity_addLiquidity_single_deposit_fail_rolls_back`**, `_both_legs_resets_both`, `_stake_deposit_fail_rolls_back`, fork (`allowance == 0` after) |
| I-3 | **slippage floors — non-zero MANDATORY on BOTH legs** — `minShares != 0` on add (`ZeroMinShares`), and not-both-zero on remove (`ZeroMinAmount`, SUPPLY-ADV-10). The remove floor is the *sole* sandwich guard: the ICHI `withdraw` self-protects with nothing (decomposes at the current tick), unlike `deposit` (vault hysteresis), so the CRE sizes it off the TWAP fair reserves (SUPPLY-ADV-09) | Yes | `test_addLiquidity_slippage_floor`, `test_zero_minShares_reverts`, `test_removeLiquidity_slippage_floor`, `test_removeLiquidity_zero_minAmount_reverts`, **`test_fork_slippage_floor_snapshot_guarded`** (probe-then-floor+1 → `Slippage`) |
| I-4 | **exec false-return hard-reverts with bubbled inner data** | Yes | `test_exec_bubbles_custom_error`, `_no_data_falls_back_to_ExecFailed`, `test_disallowed_side_bubbles_on_mock`, **`test_fork_disallowed_side_reverts`** (real vault `allowToken1==false`) |
| I-5 | **live-read `token0`/`token1` off the vault** — approval targets can't drift | Yes | `test_setUp_rejects_zero_token_leg`, **`test_fork_real_vault_single_sided_deposit`** (token0==WETH/token1==USDC live) |
| I-6 | **stake/unstake credit the Safe as msg.sender** (no EVC/borrow, no tokenId state) | Yes | `test_exec_discipline_stake_and_unstake`, **`test_fork_full_cycle_real_safe_mock_lp`** |
| X-2 | §10.1 residual: operator trusted for scalar amounts — bounded, not theft | **No** | recipient pin + no-passthrough + slippage floors cap it on-chain |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (engine/operator/ichiVault/gauge) + live-zero token leg | `test_setUp_rejects_zero_gauge`, `_zero_ichiVault_at_guard_not_staticcall`, `_zero_juniorTrancheEngine`, `_zero_token_leg` |
| `setUp` owner==operator / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_owner_equals_operator`, `test_setUp_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `NotOperator` on all 4 mutators | `test_entrypoints_only_operator`, `test_removeLiquidity_only_operator` |
| `ZeroAmount` / `ZeroMinShares` / `ZeroMinAmount` | `test_zero_amount_reverts`, `test_zero_minShares_reverts`, `test_removeLiquidity_zero_minAmount_reverts` |
| `Undercovered` coverage gate | `test_removeLiquidity_coverage_gate` |
| `Slippage` (add + remove) | `test_addLiquidity_slippage_floor`, `test_removeLiquidity_slippage_floor`, `test_fork_slippage_floor_snapshot_guarded` |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| `setCoverageGate` (on/off effect) | `test_removeLiquidity_coverage_gate` |
| 6 wiring setters (`setJuniorTrancheEngine`/`setOperator`/`setIchiVault`/`setGauge`/`setToken0`/`setToken1`) | `test_wiring_setters_onlyOwner_effect_and_zeroGuard` — onlyOwner + effect + zero-guard (all 6), **incl. the SEC-15 `setOperator` owner-recheck and the `setJuniorTrancheEngine` avatar/target sync** |

## 5. Attack surfaces

- **The coverage path-lock is the load-bearing seam — and it's tested across all states (X-1)** — `removeLiquidity`
  converts path-locked LP into exitable legs, so it must respect the same coverage floor as `release`/exit. The gate
  reads `DurationFreezeModule.lpBurnKeepsCovered(shares)`; `test_removeLiquidity_coverage_gate` proves a breaching
  burn reverts `Undercovered`, an excess burn clears, and the gate-OFF (zero) state is ungated legacy. This is the
  exact counterpart to the freeze module's `lpBurnKeepsCovered` (covered in `DurationFreezeModule.md`) — the two
  halves of the LP-in-place accounting line up.
- **Approval hygiene + atomic rollback (I-2)** — every approving path (`addLiquidity`, `stake`) resets the allowance
  to 0, and a failing inner exec rolls the whole sequence back (the approve never survives); proven on the live ICHI
  vault (`allowance == 0` after) and in the rollback tests. No standing approval to grief.
- **The slippage floor is the sole sandwich guard — and the WITHDRAW is the exposed side (I-3)** — verified
  against the real ICHI vault source (Base `0xfF8B…73f7`): `deposit` self-protects (spot-vs-TWAP hysteresis +
  conservative min/max share bracketing), so `addLiquidity`'s mandatory `minShares` (`ZeroMinShares`) is
  belt-and-suspenders there. `withdraw` self-protects with **nothing** — it decomposes liquidity at the current
  pool tick — so `removeLiquidity`'s `minAmount0/1` is the *only* protection on the dissolution hop. Two controls:
  (1) on-chain, not-both-zero is now mandatory (`ZeroMinAmount`, SUPPLY-ADV-10, `test_removeLiquidity_zero_
  minAmount_reverts`); (2) off-chain, the CRE sizes the floor off the TWAP fair reserves (`IchiAlgebraFairReserves`,
  the same value the coverage gate uses), NOT spot (SUPPLY-ADV-09 / KEEPER-02). `test_fork_slippage_floor_snapshot_
  guarded` probes the achievable shares on the real vault then proves floor+1 reverts.
- **The 6 wiring setters — now covered** — `test_wiring_setters_onlyOwner_effect_and_zeroGuard` exercises
  `setJuniorTrancheEngine`/`setOperator`/`setIchiVault`/`setGauge`/`setToken0`/`setToken1` for onlyOwner + effect +
  zero-guard, and additionally closes the two LpStrategy-specific gaps its siblings already covered: the **SEC-15
  `setOperator` owner-recheck** (re-pointing operator to owner reverts `OwnerIsOperator`) and the
  **`setJuniorTrancheEngine` avatar/target sync** (`:130-136`, asserted in lockstep). With `setCoverageGate` (the
  coverage-gate test), every wiring setter is now exercised.
- **No fuzz/invariant — correctly omitted** — deterministic exec sequences with no internal arithmetic beyond the
  slippage comparison; the live-fork ICHI/gauge tests are the higher-value check and they exist.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 33 | setUp/guards, SEC-14 clone-safety, all 7 wiring setters (onlyOwner/effect/zero-guard, incl. SEC-15 + avatar/target sync), exec-discipline (approve/reset shape) for add/stake/unstake/remove, atomicity rollbacks, the 3-state coverage gate, slippage floors (incl. the `ZeroMinAmount` remove-floor guard), vault-agnostic non-unit-price pass-through, view pinning, bubble matrix |
| Base-fork | 5 | live ICHI vault + gauge: real single-sided deposit (live token0/token1 read, no standing allowance), snapshot-guarded slippage, disallowed-side fail-close, gauge/Voter sig-verify, full build→stake→unstake→remove cycle (real Safe, mock LP for our not-yet-deployed vault) |
| Stateless fuzz / invariant | 0 | deterministic; fork is the higher-value check |

All **38 pass** (`forge test --match-path test/LpStrategyModule.t.sol`). The decisive seam (coverage path-lock) and
the approval/slippage discipline are tested unit + live-fork. Coverage % uninstrumentable (project-wide
stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — a clean fleet module whose distinctive, load-bearing property (the coverage path-lock tying
`removeLiquidity` to `DurationFreezeModule`'s floor) is tested across all three gate states, with solid approval
hygiene, atomic rollback, slippage floors, and live-ICHI fork coverage. **Every mutator is now exercised** (all 7
setters + the 4 operator actions; the 6-setter gap — including the previously-missing SEC-15 owner-recheck and the
avatar/target sync — was filled 2026-06-20). Capped at ADEQUATE by: no fuzz/invariant (correctly low-value), and the
build-phase mutable wiring pending the pre-prod re-freeze — neither a coverage gap.

**Structural facts:**
1. 165 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no custody, no EVC/borrow, no storage writes in mutating paths.
2. 4 operator-only actions; deposit `to` + all balance reads pinned to `juniorTrancheEngine`; `value==0`, Call-only, no passthrough; `_exec` bubbles inner reverts.
3. `removeLiquidity` is coverage-gated (`lpBurnKeepsCovered` → `Undercovered`) — the on-chain LP-dissolution path-lock; `token0`/`token1` live-read off the vault; approvals reset to 0 every path.
4. Tests: 33 unit + 5 base-fork (0 fuzz/invariant); the coverage gate (3 states), slippage (incl. the `ZeroMinAmount` remove-floor guard), atomicity, live ICHI deposit, and every wiring setter all proven.
5. No outstanding coverage gap on the contract surface; residuals are off-chain (the pre-prod wiring re-freeze).
