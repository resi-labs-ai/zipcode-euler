# X-Ray — `SzipNavOracle.sol` (single-contract, test-connected)

> SzipNavOracle | 360 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED — the best-tested contract in the supply subsystem)*

> **Update 2026-06-20:** the two gaps below (I-15 setter auth/zero-guards, I-16 the `committedValue()+freeValue()`
> additive identity) are **CLOSED** — 3 new tests added to `SzipNavOracle.t.sol` (64/64 green). Every Timelock
> setter's `onlyOwner`/zero-guard is now exercised, and the per-Safe decomposition identity is pinned exactly (plain
> legs) and to ≤2 wei (split LP). The only residual now is the absence of a stateful fuzz invariant + no external audit.

Dedicated single-contract X-Ray for `contracts/src/supply/SzipNavOracle.sol`, the szipUSD junior-vault
**NAV-per-share oracle** — the issuance + exit pricing primitive (NAV is *not* display-only). It composes the junior
basket's value on-chain across the main + sidecar Safes (every leg read trustlessly, incl. the staked ICHI LP off the
Hydrex gauge), CRE-pushes only the off-chain leg prices it cannot read on Base (`alphaUSD`, HYDX/USD), and maintains
an on-chain cumulative-TWAP accumulator over a governed window `W`. Consumers read a **bracketed** share price:
`navEntry = max(spot, twap)` (issuance), `navExit = min(spot, twap)` (exit). Exercised by `SzipNavOracle.t.sol` — a
**63-test** suite covering essentially the whole surface, plus consumer suites (DurationFreezeModule, RecycleModule,
ExitGate, ZipDepositModule, DefaultCoordinator) that read it as the real oracle.

> This is the **economic keystone** of the junior vault and the most central contract in `supply/`: it is the supply
> denominator's price, the freeze module's coverage floor (`committedValue` + `pathLockedLpEquity`), the buy-burn
> bid's freshness anchor (`oldestRequiredLegTs`, SEC-13), the impairment-provision sink (M2), and the Exit Gate's
> issuance valuation seam (`valueOf`). The defensive core is the **bracket asymmetry** — a sub-window spot move can
> never be turned into a profitable mint (`max`) or a rich exit (`min`) — backed by a poke-spam-resistant TWAP ring
> (`obsSpacing`). It shares the `ReceiverTemplate` CRE-receiver DNA with `SzipFarmUtilityLpOracle` but is far larger:
> a full on-chain basket composition rather than a single pushed mark.

## 1. What it is

A 360-nSLOC `ReceiverTemplate` (CRE receiver; no `BaseAdapter` — this is a NAV primitive, not an EVK adapter). Eight
immutable identity/config slots + nine Timelock-re-pointable wiring slots. Surfaces:

- **Composition (view):** `grossBasketValue` sums seven legs (zipUSD@$1, USDC×1e12, xALPHA two-layer, HYDX, oHYDX intrinsic, ICHI LP in all states, − farm-utility strike debt), saturating at 0; `committedValue`/`freeValue` are the additive per-Safe decomposition; `pathLockedLpEquity` the main-Safe LP net of debt; `spotNavPerShare` / `twapNavPerShare` the share prices; `navEntry`/`navExit`/`fresh`/`oldestRequiredLegTs`/`valueOf`/`lpShareValue` the consumer reads.
- **Write (CRE only):** `onReport` (forwarder-gated) → `_processReport` (reportType `NAV_LEG=7`, all-or-nothing batch: length-match, future-ts, per-leg deviation band + zero-price + strictly-newer ts) → `legCache`; the accumulator is advanced FIRST so the old spot is booked before new prices apply.
- **Write (coordinator only):** `writeProvision` (sole writer = `DefaultCoordinator`; unbounded at the oracle by design — the bound lives in M2).
- **Permissionless:** `poke()` advances the TWAP integral + ring (idempotent within a block; one ring slot per `obsSpacing`).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `onReport` → `_processReport` | forwarder-only | batch leg push, reportType 7, all-or-nothing |
| `writeProvision(p)` | `defaultCoordinator`-only | `NotDefaultCoordinator` otherwise; unbounded (bound in M2); books spot first |
| `poke()` | permissionless | advances integral + ring; `dt==0` no-op |
| `grossBasketValue` / `committedValue` / `freeValue` / `pathLockedLpEquity` / `lpShareValue` / `valueOf` | public view | basket + per-leg valuation |
| `spotNavPerShare` / `twapNavPerShare` / `navEntry` / `navExit` / `fresh` / `oldestRequiredLegTs` | public view | share-price + freshness consumer surface |
| `setShareToken`/`setLpPosition`/`setFarmUtilityLeg`/`setLpTwapWindow`/`setJuniorTrancheEngine`/`setDefaultCoordinator`/`setXAlphaRateOracle` | `onlyOwner` (Timelock) | build-phase re-pointable wiring (§17) |
| `constructor(...11 args)` | deploy | zero-guards the 7 identity addrs + `W` + `maxAge`; derives `obsSpacing`, seeds obs[0] |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **bracket asymmetry** — `navEntry=max`, `navExit=min`; a one-block spot spike cannot cheapen a mint or enrich an exit | Yes | **`test_one_block_spike_does_not_enable_cheap_mint`**, **`test_twap_windowed_and_bracket`** |
| I-2 | **TWAP poke-spam immunity** — `obsSpacing` caps ring consumption to 1 slot/spacing; ≥W of history survives spam | Yes | **`test_twap_window_survives_poke_spam`** (200 spam pokes ⇒ ≤3 slots), `_poke_within_spacing_refreshes_head_no_advance`, `_twap_ring_wraparound`, `_poke_dt_zero_is_noop` |
| I-3 | **NAV composition is exact** — all seven legs hand-computed; USDC 6→18 scale pinned; xALPHA accrual flows through | Yes | **`test_nav_composition_handcomputed`**, `_nav_usdc_scale_pinned`, `_nav_xalpha_exchangeRate_accrual` |
| I-4 | **batch push is all-or-nothing + guarded** — reportType, length, future-ts, invalid-leg, zero-price, deviation band, strictly-newer ts (SEC-01); one bad entry reverts all | Yes | **`test_push_*`** (8), `_deviation_*` (3), **`test_SEC01_nav_backdated_replay_reverts`**, **`test_batch_atomicity_one_bad_entry_reverts_all`** |
| I-5 | **staleness asymmetry** — stale legs pause issuance (`navEntry`/`fresh` revert `StalePrice`) but never exit | Yes | **`test_staleness_pauses_issuance_not_exit`**, `_staleness_single_leg_hydx_stale` |
| I-6 | **xALPHA rate gate (SEC-04 + cross-chain)** — unseeded rate (`exchangeRate()==0`) fails ALL reads closed (`RateUnseeded`); a wired stale rate halts issuance, not exit | Yes | **`test_SEC04_unseeded_rate_fails_closed`** / `_seeded_rate_prices_correctly` / `_asymmetry_preserved_when_stale`; `test_xAlphaRateOracle_gates_issuance_not_exit` / `_unset_uses_fallback` |
| I-7 | **LP marked-through in all states** — loose + gauge-staked + escrow-collateralized, net of strike debt; `postCollateral`/`borrow` cycle is NAV-invariant; unknown LP token fails closed; supply-0 / unset guards | Yes | **`test_lp_marked_through`**, `_farmUtility_nav_invariant_across_post`, `_farmUtility_escrow_leg_and_debt`, `_lp_unknown_token_reverts`, `_lp_supplyLp_zero_guard`, `_lp_unset_contributes_zero`, `_farmUtility_debt_saturates_at_zero`, `_lpShareValue_pro_rata` |
| I-8 | **SEC-10 LP-TWAP window validation** — `setLpTwapWindow(>0)` requires `ichiVault` wired + an initialized plugin else `LpTwapPluginNotReady`; `(0)` is always a valid escape; the ready path reads through `fairReserves` | Yes | **`test_SEC10_no_plugin_reverts`** / `_uninitialized_plugin_reverts` / `_ready_pool_succeeds_and_reads_twap` / `_escape_zero_always_succeeds` |
| I-9 | **provision write** — sole writer `DefaultCoordinator`, immediate, unbounded (floors NAV at 0); reverts for all until wired | Yes | **`test_provision_auth_and_immediate`**, `_provision_unbounded_floors_at_zero` |
| I-10 | **SEC-13 anchor** — `oldestRequiredLegTs` = min of the two legs, folding the wired rate's `lastUpdate` only when seeded | Yes | **`test_SEC13_oldestRequiredLegTs_min_of_two_legs`** / `_folds_rate_ts_when_wired` |
| I-11 | **genesis + effective supply** — `GENESIS_NAV` at zero effective supply; engine pre-burn subtracted; underflow floors to genesis | Yes | **`test_genesis_*`** (2), `_nav_engine_pending_burn_subtracts` / `_underflow_floors_to_genesis` |
| I-12 | **valueOf seam** — zipUSD par, xALPHA two-layer, unsupported asset fails closed | Yes | **`test_valueOf_*`** (3) |
| I-13 | **forwarder identity + renounce-freeze** — workflow-id gate; renounce freezes setters; correct id still writes | Yes | **`test_forwarder_immutability_and_identity`** |
| I-14 | **ctor zero-guards + live-face signatures** | Yes | **`test_ctor_rejects_zero`**, `_deploy_immutables`, `_fork_external_signatures` (Base) |
| I-15 | **setter auth/zero on ALL wiring** — every setter is `onlyOwner` and zero-guards its non-optional args | Yes | **`test_setters_onlyOwner_and_zeroGuards`** — non-owner reverts on `setFarmUtilityLeg`/`setLpTwapWindow`/`setXAlphaRateOracle`/`setJuniorTrancheEngine`/`setDefaultCoordinator`; `ZeroAddress` on both `setFarmUtilityLeg` args + engine + DC; `setXAlphaRateOracle(0)` is a valid owner unset (+ `setShareToken` auth / `setLpPosition` zero, pre-existing) |
| I-16 | **additive decomposition** — `committedValue() + freeValue() == grossBasketValue()` exactly for the five plain legs (≤2 wei for a split LP); the double-count-free per-Safe split the freeze floor relies on | Yes | **`test_committed_plus_free_equals_gross_plainLegs`** (exact) + **`test_committed_plus_free_equals_gross_splitLp_within_2wei`** (worst-case constructed to land at exactly 2 wei, `sum <= gross`) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| push: `InvalidReportType` / `LengthMismatch` / `FutureTimestamp` / `InvalidLeg` / `ZeroPrice` / `DeviationExceeded` / `StaleReport` | `_processReport` | `test_push_*`, `_deviation_*`, `_SEC01_*`, `_batch_atomicity_*` |
| forwarder-only / workflow-id | `onReport` (parent) | `test_push_non_forwarder_reverts`, `_forwarder_immutability_and_identity` |
| `NotDefaultCoordinator` | `writeProvision:329` | `test_provision_auth_and_immediate` |
| `RateUnseeded` | `_xAlphaUSD:575` | `test_SEC04_unseeded_rate_fails_closed` |
| `StalePrice` / `StaleRate` | `navEntry`/`fresh` | `test_staleness_*`, `_xAlphaRateOracle_gates_*` |
| `UnknownLpToken` | `_legPriceOfToken:590` | `test_lp_unknown_token_reverts`, `_valueOf_unsupported_asset_reverts` |
| `LpTwapPluginNotReady` | `setLpTwapWindow:264-268` | `test_SEC10_*` |
| ctor `ZeroAddress` | `:200` | `test_ctor_rejects_zero` |
| `setShareToken` onlyOwner | `:227` | `test_setShareToken_setOnce_and_auth` |
| `setLpPosition` `ZeroAddress` | `:235` | `test_setLpPosition_setOnce` |
| `setFarmUtilityLeg` onlyOwner + ZeroAddress | `:244-245` | `test_setters_onlyOwner_and_zeroGuards` |
| `setLpTwapWindow` onlyOwner | `:262` | `test_setters_onlyOwner_and_zeroGuards` (gate isolated via the valid `0` arg) |
| `setXAlphaRateOracle` onlyOwner (0 = valid unset) | `:292` | `test_setters_onlyOwner_and_zeroGuards` |
| `setJuniorTrancheEngine` / `setDefaultCoordinator` onlyOwner + ZeroAddress | `:276,:283` | `test_setters_onlyOwner_and_zeroGuards` |

## 5. Attack surfaces

- **The defensive core is proven.** The whole oracle exists to make the share price unmanipulable within a window;
  the bracket asymmetry (I-1), the poke-spam-immune TWAP ring (I-2), the staleness asymmetry (I-5), and the
  unseeded/stale xALPHA-rate fail-closed (I-6) are all directly tested, several as named SEC/regression cases. This
  is the densest defensive coverage of any contract in `supply/`.
- **The batch-push write path is hardened and exercised (I-4).** All-or-nothing semantics, the deviation circuit-break,
  the SEC-01 strictly-newer monotonic guard (which the price-only deviation band cannot catch on a same-price
  replay), and per-guard reverts are all covered, including the partial-write-prevention test.
- **The LP / farm-utility mid-loop blind spot is closed and tested (I-7).** LP counted in loose + staked + escrow
  states net of strike debt, so a `postCollateral`/`borrow`/`repay`/`withdrawCollateral` cycle is NAV-invariant;
  unknown-token and supply-0 guards fail closed.
- **Setter-auth coverage holes (I-15) — CLOSED.** All seven Timelock setters now have their `onlyOwner` gate and
  (where applicable) `ZeroAddress` guard exercised: `test_setters_onlyOwner_and_zeroGuards` reverts a non-owner on
  `setFarmUtilityLeg`/`setLpTwapWindow`/`setXAlphaRateOracle`/`setJuniorTrancheEngine`/`setDefaultCoordinator` and
  pins the zero-guards on both `setFarmUtilityLeg` args + engine + DC, while confirming `setXAlphaRateOracle(0)` is a
  valid owner unset. The `setLpTwapWindow` test passes the valid `0` arg so the failure is unambiguously the
  `onlyOwner` gate, not the plugin validation (which I-8 covers separately).
- **The additive-decomposition identity (I-16) — CLOSED.** The contract's `committedValue() + freeValue() ==
  grossBasketValue()` claim — the double-count-free per-Safe split that `DurationFreezeModule`'s coverage floor
  (`committedValue` + `pathLockedLpEquity`) depends on — is now pinned directly: exact for the five plain legs, and
  for a split LP a constructed worst case (supply 7e18, $1/$1 legs, `L_safe=L_sidecar=4e18`) lands the double-floor
  delta at exactly 2 wei with `sum <= gross`. A regression that broke the decomposition would now be caught here.
- **Documented accepted trade-offs (not gaps).** zipUSD valued at flat $1 on the basket leg (a de-peg over-issues —
  LOW, §7, mitigated by capacity-gated minting); `navExit` may price off a stale-but-good mark by design (the §7
  asymmetry, keeper-`poke`-maintained); `writeProvision` unbounded at the oracle (bound in M2); xALPHA `exchangeRate`
  is an M1 stand-in (production Rubicon getter verified at bridge integration); no first-depositor guard (the Gate
  owns genesis). All are NatSpec-documented security-review acceptances.
- **Inherited residuals.** The `IchiAlgebraFairReserves` TWAP path (when `lpTwapWindow != 0`) carries the lib's X-2
  (pool TWAP cardinality, off-chain config) — see [lib/x-ray](../lib/x-ray/x-ray.md); the CRE/Forwarder push trust;
  and build-phase mutable wiring (frozen pre-prod).

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Deploy / wiring / genesis | 7 | immutables, ctor-zero, setter effects (re-point), genesis/zero-supply |
| Push path + deviation + SEC-01 atomicity | 14 | every write guard + all-or-nothing |
| NAV composition + LP + farm-utility | 13 | hand-computed legs, marked-through LP, path-lock, debt saturation |
| TWAP ring + bracket + spike | 6 | poke-spam immunity, wraparound, obsSpacing, one-block spike |
| Staleness / xALPHA-rate / SEC-04 | 6 | issuance-vs-exit asymmetry, unseeded fail-close |
| Provision / SEC-13 / valueOf / SEC-10 / forwarder / fork-sig | 17 | coordinator auth, anchor min, issuance seam, plugin validation, identity, live faces |
| Setter auth/zero (full) | 1 (added) | `test_setters_onlyOwner_and_zeroGuards` — all 7 setters' `onlyOwner` + zero-guards |
| `committedValue`+`freeValue` identity | 2 (added) | exact (plain legs) + ≤2-wei (split LP, worst case) |
| Fork / fuzz / invariant | 1 fork sig-check | no stateful fuzz (the TWAP ring + bracket are deterministic-tested; a `spotNavPerShare` conservation invariant would be the next hardening step) |

Coverage % uninstrumentable (project-wide `Stack too deep`); **64 tests green** (61 + 3 added 2026-06-20). This is
the most thoroughly tested contract in the supply subsystem — every economic guard, every SEC regression, the full
write path, the defensive TWAP/bracket core, all setter auth, and the per-Safe decomposition identity are directly
proven. The only residual is the absence of a stateful fuzz invariant.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — the economic keystone of the junior vault, and the best-tested contract in
`supply/`. The defensive core (bracket asymmetry, poke-spam-immune TWAP ring, staleness asymmetry, unseeded/stale
xALPHA fail-closed), the all-or-nothing guarded push path (incl. the SEC-01 monotonic guard the deviation band cannot
catch), the marked-through LP across all states with the mid-loop blind spot closed, the SEC-10 plugin validation,
the SEC-13 anchor, provision auth, and the forwarder identity/renounce are all directly proven. The two prior gaps
are now **CLOSED** (2026-06-20): all seven Timelock setters' `onlyOwner`/zero-guards are exercised (I-15), and the
`committedValue() + freeValue() == grossBasketValue()` additive identity is pinned exactly for plain legs and to ≤2
wei for a split LP (I-16). Held below HARDENED now only by the absence of a stateful fuzz invariant (a
`spotNavPerShare` conservation/monotonicity property would be the next step), the inherited TWAP-config residual (the
lib's X-2, pool-side), and no external audit.

**Structural facts:**
1. 360 nSLOC; `ReceiverTemplate` (CRE receiver, not an EVK adapter); 8 immutable identity slots + 9 Timelock-re-pointable wiring slots; the supply denominator's price + freeze coverage floor + buy-burn anchor + provision sink + Gate issuance seam.
2. Composes 7 basket legs on-chain (− farm-utility debt, saturating at 0); CRE pushes only `alphaUSD` + HYDX/USD as reportType-7 batches; maintains an on-chain cumulative-TWAP ring (`CARDINALITY=65`, `obsSpacing`-throttled).
3. Bracket reads: `navEntry=max(spot,twap)` / `navExit=min(spot,twap)` — the asymmetry that defeats sub-window spot manipulation in both directions.
4. Three write authorities: immutable Forwarder (leg marks), `DefaultCoordinator` (provision, unbounded here / bound in M2), permissionless `poke`.
5. Tests: 64 (the subsystem's densest) — every economic guard + SEC-01/04/10/13 + TWAP/bracket core + all setter auth (I-15) + the per-Safe decomposition identity (I-16). Only residual: no stateful fuzz.
