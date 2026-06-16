# zipcode-euler — Claude adversarial audit findings

_Reasoning-driven pass, 6 parallel subsystem auditors, invariant-falsification methodology
(see `adversarial-spec.md`). All paths under `contracts/src/`. Findings are verified against the
code as written; acknowledged trust assumptions (malicious Timelock, compromised CRE within its
documented blast radius) are excluded from findings and listed separately as posture notes._

## Summary

| # | Severity | Conf | Subsystem | Finding |
|---|---|---|---|---|
| 1 | **HIGH** | high | core | Registry has no monotonic-timestamp guard → out-of-order / replayed revaluation overwrites a fresher mark — ✅ **RESOLVED (SEC-01, 2026-06-15)** |
| 2 | **HIGH** | high | venue | Unbounded supply-queue growth in `openLine` bricks all origination after ~29 lines |
| 3 | MED | high | core | Backdated revaluation arbitrarily rewinds/extends a mark's staleness window — ✅ **RESOLVED (SEC-01, 2026-06-15)** |
| 4 | MED | high | venue | No defund path — USDC stranded in closed line vaults drains base liquidity, DoS's `fund`/`draw` — ✅ **RESOLVED (SEC-07, 2026-06-15)** |
| 5 | MED | high | szipUSD | Resting CoW buy-burn bid keeps filling after coverage drops below floor (gate is post-time only) |
| 6 | MED | high | bridge/NAV | `navExit`/`grossBasketValue` price the xALPHA leg off a **zero** rate when the rate oracle is never seeded — ✅ **RESOLVED (SEC-04, 2026-06-15)** |
| 7 | MED | med | szipUSD | `coverageValue()` double-counts sidecar ICHI-LP, inflating coverage + corrupting the LP-dissolution gate |
| 8 | MED | high | szipUSD | Coverage gate defaults OFF (`coverageGate==0`) leaves buy-burn outflow + LP dissolution unfenced |
| 9 | LOW | high | szipUSD | `requiredCommittedValue` gross-cap can make `covered()` permanently false → bricks release/postBid/removeLiquidity |
| 10 | LOW | high | venue | `openLine` atomicity silently depends on un-asserted EulerEarn preconditions (zero timelock + perspective allow-list) |
| 11 | LOW | high | bridge | CCT TokenAdminRegistry admin left as the transient deploy contract, never handed to Timelock → pool re-point bricked — ✅ RESOLVED 2026-06-15 (SEC-03, escalated to H4) |
| 12 | LOW | med | szipUSD | NAV-freshness `validTo` fence permits a fill against an effectively-stale mark at the edge of the bid window |

**Cross-cutting theme:** the protocol enforces freshness/monotonicity on *some* oracle read surfaces
(`SzAlphaRateOracle` strictly-newer; `navEntry()`/`fresh()` fail-closed) but **omits the same guard on
parallel surfaces** — the registry revaluation path (#1, #3) and `_xAlphaUSD`/`grossBasketValue`/
`navExit` (#6). Three independent auditors converged on this. It is the single most systemic weakness:
read-side freshness is inconsistent, and the unguarded surfaces feed credit (registry → LTV) and
coverage/freeze decisions.

---

## HIGH

### 1. Registry accepts out-of-order / replayed revaluations (no monotonic-timestamp guard)
- **contract/fn:** `ZipcodeOracleRegistry` / `_processReport`, `_writePrice`
- **location:** `src/ZipcodeOracleRegistry.sol:114-133`
- **class:** oracle · **invariant_broken:** §4.10 explicitly contrasts this contract as having "no
  monotonic-timestamp guard — unlike RateOracle." `SzAlphaRateOracle.sol:86` enforces
  `if (ts <= latest.ts) revert StaleReport()`; the registry omits it and unconditionally clobbers
  `cache[lien]` with any `ts <= block.timestamp`.
- **actor:** CRE/DON — **exceeds documented blast radius.** Does NOT require a *compromised* Forwarder:
  the protocol's own design treats out-of-order/replayed DON delivery as an expected, non-malicious
  event (it guards it in the sibling oracle), and a previously-valid signed RT-3 report can be replayed.
- **attack:**
  1. Lien `L` has fresh mark `{price: $200k, ts: T0}`; borrower drew near the LTV bound against it.
  2. DON pushes a corrective markdown `{price: $50k, ts: T1>T0}` — position is now under-collateralized.
  3. The older still-validly-signed `{$200k, T0}` report is replayed (or the two are simply mined
     out of order). No `ts <= cache.timestamp` check → the fresher $50k mark is destroyed, $200k resurrected.
  4. **Impact A (resurrect favorable price):** the per-line `EulerRouter` reads $200k, the EVK
     account-status check passes, and the borrower keeps/extends an undercollateralized loan shielded
     from liquidation → direct credit loss to the warehouse/senior.
  5. **Impact B (grief/DoS):** a backdated push with `ts = now − validityWindow − 1` makes `_getQuote`
     revert `PriceOracle_TooStale`, bricking borrows/draws against `L` until the next push.
- **fix:** add `if (ts <= cache[lien].timestamp) revert` on the revaluation path (match `SzAlphaRateOracle`).
- **RESOLVED 2026-06-15 (SEC-01).** Guard added in the **shared** `_writePrice` (covers both the rt-3 batch and the
  `seedPrice` clobber); `error StaleReport()` declared. Kill-list H1. The NAV (M1) + LP (L3) siblings fixed in the
  same ticket. Regression: `test_SEC01_reval_backdated_reverts` / `_equalTs_reverts` / `_seedPrice_equalTs_reverts`.

### 2. Unbounded supply-queue growth in `openLine` bricks all future origination — **RESOLVED 2026-06-15 (SEC-06)**
- **contract/fn:** `EulerVenueAdapter` / `openLine`
- **location:** `src/venue/EulerVenueAdapter.sol:225-233`
- **class:** dos · **invariant_broken:** origination atomicity / core protocol liveness (the adapter is
  the sole origination path).
- **actor:** the legitimate CRE/controller flow over the protocol's lifetime — a self-inflicted dead-end
  reached by normal operation (a cheap-origination griefer accelerates it).
- **attack:**
  1. `openLine` step 4 reads the EulerEarn supply queue, allocates `qlen+1`, copies all entries, appends
     the new `evault`, and calls `setSupplyQueue`. Starts at length 1 (`[baseUsdcMarket]`).
  2. Each `openLine` grows the queue by one and **never removes**; `closeLine` (`:343-360`) never prunes,
     so closed lines stay in the queue forever — length is monotonic in *cumulative* line count.
  3. EulerEarn's `setSupplyQueue` reverts `MaxQueueLengthExceeded` at length > 30. The length-31 queue
     is built on the 30th `openLine` (1 base + 29 prior + this one).
  4. From then on every `openLine` reverts *after* the CREATE2 LineAccount, both EVK proxies, the router,
     and the cap submit/accept have run — origination is permanently dead, unrecoverable via the venue.
- **fix:** prune closed-line vaults from the supply queue in `closeLine`, or cap concurrent (not
  cumulative) lines and reuse queue slots. **RESOLVED 2026-06-15 (SEC-06):** `closeLine` now rebuilds the
  supply queue into a `qlen-1` array excluding the closed `lineRef` (by address match — not assuming last
  position) and calls `setSupplyQueue` (`EulerVenueAdapter.sol:357-373`). Queue length is now bounded by
  *concurrent* open lines, not cumulative; a >30-origination open→close churn test stays live.

---

## MEDIUM

### 3. Backdated revaluation rewinds/extends a mark's staleness window
- **contract/fn:** `ZipcodeOracleRegistry` / `_writePrice`, `_getQuote` — `src/ZipcodeOracleRegistry.sol:127-161`
- **class:** oracle. Staleness is measured as `block.timestamp − c.timestamp`, trusting `c.timestamp` as
  the true observation time; RT-3 lets the DON choose any `ts <= now` unrelated to the prior cache.
- **actor:** CRE/DON or replay. Re-pushing the *same* price value with `ts = now` resets `s = 0`,
  treating a stale appraisal as fresh for another full window with no deviation band to detect the
  unchanged value — defeating the fail-closed staleness guarantee. Symmetric to #1 Impact B.
- **fix:** same monotone guard as #1.
- **RESOLVED 2026-06-15 (SEC-01).** A *backdated* `ts` can no longer be written (reverts `StaleReport()`), so the
  rewind/extend vector is closed by the #1 guard. (Re-pushing the *same* price at `ts = now` is still admissible by
  design — that is a strictly-newer write; the deviation-band-can't-see-unchanged-value posture is unchanged.)

### 4. No defund path — USDC stranded in closed line vaults drains base liquidity ✅ RESOLVED 2026-06-15 (SEC-07)
- **contract/fn:** `EulerVenueAdapter` / `fund`, `closeLine` — `src/venue/EulerVenueAdapter.sol:278-295, 343-360`
- **class:** economic/dos. `fund` hardcodes the withdraw leg to `baseUsdcMarket` and only ever moves
  base→line; there is no line→base reallocation. `closeLine` reclaims only the lien token, leaving
  supplied USDC in the closed line vault. As cumulative funded-then-closed volume grows, `baseBalance`
  shrinks until `baseBalance − amount` underflows and blocks funding/draws — capital trapped, not stolen.
- **actor:** legitimate controller flow over time. *(Rests on EulerEarn keeping the closed-line supply
  shares — verified nothing removes them, but flagged as resting on EE accounting.)*
- **fix:** add a line→base defund/reallocation path invoked on `closeLine`. **RESOLVED 2026-06-15 (SEC-07):**
  `closeLine` now runs a zero-sum INVERSE of `fund`'s reallocate — `{lineRef, assets:0}` (redeem the EE's full
  line position) + `{baseUsdcMarket, assets: base+line}` (base absorbs it) — sequenced BEFORE the SEC-06
  queue-prune, guarded `lineBalance != 0` (never-funded lines skip). `EulerVenueAdapter.sol:367-378`. Regression
  (`test_SEC07_*` in `EulerVenueAdapter.t.sol`) made `MockEulerEarn.reallocate` faithful (actually moves USDC) so
  the strand + the `:290` underflow are reproduced fail-before/pass-after. The L9/SEC-11 donation-immune sizing
  (B7 below, `previewRedeem(config[id].balance)`) remains open and will flow into this defund's base-leg read.

### 5. Resting CoW buy-burn bid keeps filling after coverage drops below floor
- **contract/fn:** `SzipBuyBurnModule` / `postBid` — `src/supply/szipUSD/SzipBuyBurnModule.sol:289-337` (gate 297-298)
- **class:** economic · **invariant_broken:** §4.9/§6 "Outflow blocked while `coverageGate.covered()==false`."
  Only bid *posting* is gated; bid *filling* is not.
- **actor:** CoW solvers + adverse price drift (no privileged actor). Defeats the *autonomous* coverage
  floor the design relies on instead of operator vigilance.
- **attack:** operator posts a bid while `covered()` (checked once); within the bid TTL (≤ maxAge, up to
  1 day) price drift drops coverage below floor; solvers settle the presigned order directly against
  GPv2Settlement — the module is not in the settlement path, so `covered()` is never re-checked — and
  USDC leaves the engine Safe while undercovered. Only remedy is the operator manually calling
  `cancelBid`, contradicting the documented autonomous gate.
- **fix:** a CoW pre/post-interaction hook that re-checks `covered()` at fill, or short bid TTLs.

### 6. `navExit`/`grossBasketValue` price the xALPHA leg off a *zero* rate when the rate oracle is never seeded — ✅ RESOLVED 2026-06-15 (SEC-04)
- **contract/fn:** `SzAlphaRateOracle.exchangeRate` (root) → `SzipNavOracle._xAlphaUSD`, `grossBasketValue`, `navExit`
- **location:** `src/bridge/SzAlphaRateOracle.sol:111-113`; `src/supply/SzipNavOracle.sol:508-514, 483-487, 345`
- **class:** oracle · **invariant_broken:** §4.10 "navExit prices off the *last good mark*, defense =
  TWAP lag." The 0-return is a degenerate zero, not a stale-but-good mark; `_xAlphaUSD`/`grossBasketValue`/
  `navExit` read `exchangeRate()` with **no freshness check** (freshness is only enforced in
  `navEntry()`/`fresh()`).
- **actor:** wiring/liveness state — rate oracle wired but never pushed (no precompile dishonesty needed).
  Issuance and buy-burn fail-closed via `fresh()`, but `DurationFreezeModule` coverage/freeze-floor and
  `ExitGate` tvlCap consume the understated basket → coverage decisions on a wrong (low) value.
- **fix:** gate `_xAlphaUSD`/`grossBasketValue` on rate freshness, or treat `exchangeRate()==0` as fail-closed.
- **RESOLVED 2026-06-15 (SEC-04 / kill-list H5).** Adopted the **fail-closed-on-unseeded** half: `error RateUnseeded()`
  declared on `SzipNavOracle`; `_xAlphaUSD()` (`:517-525`) captures `uint256 rate = IXAlphaRate(rateSrc).exchangeRate()`
  then `if (rate == 0) revert RateUnseeded();`. The degenerate zero can no longer be served — all four consumers
  (`navExit`, `grossBasketValue`, freeze `coverageValue`, `ExitGate` deposit) inherit the revert via the shared
  internal. **The "gate every consumer on `fresh()`" alternative was deliberately NOT taken** — gating exit/coverage on
  staleness would break the §7 max-entry/min-exit (last-good-mark) asymmetry that the spec relies on (`exit-topology-intentional`
  is ratified). Failing closed on *unseeded* (`rate==0`, genesis) — distinct from *stale-but-nonzero* — is the narrow,
  correct fix. Regression: 5 `test_SEC04_*` (oracle unit + real freeze + real ExitGate), fail-before/pass-after confirmed.
  See `reports/SEC-04-report.md`.

  > **Residual (intended, not a gap):** a stale-HIGH rate after a validator slash (the upward-stale exit-pricing concern
  > raised in `interconnection-findings.md` C1) is NOT closed by this fix and is NOT meant to be — closing it requires
  > gating exit on `fresh()`, which the §7 asymmetry forbids. The TWAP-lag + deviation-band remain the defense for a
  > *moving* rate; the unseeded *genesis* zero is the only piece SEC-04 fences.

### 7. `coverageValue()` double-counts sidecar ICHI-LP
- **contract/fn:** `DurationFreezeModule` (math from `SzipNavOracle`) / `coverageValue`, `covered`, `lpBurnKeepsCovered`
- **location:** `src/supply/szipUSD/DurationFreezeModule.sol:319-321, 358-360, 367-372`; `SzipNavOracle.sol:359-361, 386-390`
- **class:** arithmetic. `committedValue() = _grossValueOf(sidecar)` already includes the sidecar's LP,
  and `pathLockedLpEquity()` *also* sums LP across both safes → sidecar LP is counted twice in
  `coverageValue() = committedValue() + pathLockedLpEquity()`. `covered()` then passes with phantom
  coverage, and `lpBurnKeepsCovered` subtracts only 1× the LP value while dissolution drops coverage 2×,
  permitting a `removeLiquidity` that breaches the floor.
- **actor:** requires LP in the sidecar (the DurationFreezeModule whitelist excludes LP from `commit`, so
  not operator-reachable via this module alone — hence medium confidence), but a latent correctness bug
  exactly in the LP-in-sidecar config the path-lock design intends to support.
- **fix:** subtract sidecar LP from one of the two addends (count LP once).

### 8. Coverage gate defaults OFF when `coverageGate==0`
- **contract/fn:** `SzipBuyBurnModule.postBid` (`:297-298`), `LpStrategyModule.removeLiquidity` (`:268-269`)
- **class:** access-control. Both gates short-circuit on `gate != address(0) && …`, so a zero/un-wired
  coverage gate makes the entire floor inert. Documented as M1 posture, but it converts the floor from
  "autonomous" to "absent" silently. **fix:** deploy-time assert both `coverageGate` slots are non-zero
  before go-live; emit a `SecurityWarning` on `setCoverageGate(0)` (mirror the §4.2 Forwarder==0 treatment).

---

## LOW

### 9. `requiredCommittedValue` gross-cap can make `covered()` permanently false
- `DurationFreezeModule` / `requiredCommittedValue`, `covered` — `src/supply/szipUSD/DurationFreezeModule.sol:344-360`
- dos. The floor caps at `grossBasketValue()` (both safes), but `coverageValue()` excludes the **main**
  safe's plain legs. At high utilization the floor saturates to gross > coverageValue while the main safe
  holds value → `covered()` is structurally false, bricking every coverage-gated outflow (`postBid`,
  `removeLiquidity`) and `release` exactly when exits/dissolution are most needed. No attacker; liveness.

### 10. `openLine` atomicity depends on un-asserted EulerEarn preconditions
- `EulerVenueAdapter` / `openLine` — `src/venue/EulerVenueAdapter.sol:225-226`
- cross-contract. The same-tx `submitCap`→`acceptCap` only succeeds if the fresh vault is already
  perspective-verified (`isStrategyAllowed`) **and** the EE timelock is 0; otherwise every `openLine`
  reverts. Fail-closed (no fund loss), but the headline atomic-origination guarantee rests on two
  off-contract EE settings with no birth-time assert analogous to `_assertWired`. **fix:** defensive
  precondition check / deploy-time assert.

### 11. CCT TokenAdminRegistry admin left as the transient deploy contract — ✅ RESOLVED 2026-06-15 (SEC-03)
- **RESOLVED 2026-06-15 (SEC-03 / kill-list H4, escalated to HIGH via ref-B2):** explicit `transferAdminRole(<durable>)` added to `deploy964`+`deployBase` (964→`ccipAdmin`, Base→`timelock`) + the 2-step `acceptAdminRole` runbook; `ICctRegistry` extended with `transferAdminRole`/`getTokenConfig`; the assert now checks `pendingAdministrator`. See ref-B2 + `reports/SEC-03-report.md`.
- `SzAlpha`/`DeploySzAlphaBridge` — `script/DeploySzAlphaBridge.s.sol:120-131`; `src/bridge/SzAlpha.sol:301-310`
- access-control. The registry-level token administrator (which can call `setPool`/`transferAdminRole`)
  is set to the deploy-script contract and never handed to the Timelock; `setCCIPAdmin` only changes a
  cosmetic return value. *Good news:* a compromised `ccipAdmin` therefore can't seize `setPool`. *Bad
  news:* legitimate pool re-pointing for an RMN/CCIP upgrade is bricked, and §2 mis-states where this
  authority lives. **fix:** explicit `transferAdminRole(timelock)` step; correct the doc.

### 12. NAV-freshness `validTo` fence permits an edge-stale fill
- `SzipBuyBurnModule` / `postBid` — `src/supply/szipUSD/SzipBuyBurnModule.sol:299-308`
- oracle. The fence bounds `validTo ≤ now + maxAge` relative to *post time*, not to the legs' push
  timestamps, so a bid posted when a leg is nearly `maxAge` old can fill ~`maxAge` later against a mark
  the oracle itself would reject as stale. Small impact (deviation band bounds per-push movement).
  **fix:** derive the `validTo` ceiling from `maxAge − age_of_oldest_required_leg`.

---

## Verified sound (attacked, held) — auditable negative results

- **Loss side** (`DefaultCoordinator`, `LienXAlphaEscrow`): all four claimed invariants hold against a
  CRE-only attacker — no NAV inflation via the provision path; the `totalProvision == Σ == oracle.provision()`
  identity holds across every path; recovery cannot double-count or underflow; the status machine admits
  no illegal transition or post-resolution heal; slash never exceeds bond; CEI/nonReentrant throughout.
- **NAV bracket / TWAP / queue:** `max/min(spot,twap)` mint/exit bracket holds; TWAP poke-spam immunity
  verified numerically (`obsSpacing=282s`, frozen checkpoints span ≥ W); `ZipRedemptionQueue` par round-down
  (KR-5), single-requester guard, and CEI hold; `ZipDepositModule.zap` residual/approval handling is clean.
- **szipUSD core invariants:** the two-token invariant, the `postBid` integer never-above-NAV ceiling,
  `RecycleModule` free-value two-layer guard, round-down first-depositor issuance, the reservoir borrow
  cap, and `ReservoirBorrowGuard` `isProxy` anti-spoof all hold.
- **Bridge:** `exchangeRate()` non-manipulable without precompile dishonesty (donation is value-destroying,
  down-manipulation needs the wrapper's own coldkey, first-depositor inflation reverts `ZeroSharesOut`);
  measured-delta mint/redeem (S4) holds; the lockbox custody and CCT mint-conservation survive a
  `ccipAdmin` compromise.
- **Core:** report-type partition holds; draw-to-non-erebor is double-blocked; `liquidate` reverts;
  CREATE2 lien factory is collision/front-run-safe; `liens` written last (reentrancy-safe); single-use
  lienId; conditional workflow-identity gate defended by `ZipcodeDeployAsserts.requireIdentityWired`.
- **Venue:** per-line router frozen at birth; `collateralAmount==1e18` exact; LineAccount operator grant
  not front-runnable; isolation holds.

## Posture notes (acknowledged trust — NOT findings)
A malicious **Timelock** can re-point oracles/gate/coordinator/sinks/operator (build-phase, §7) and a
compromised **CRE/Forwarder** can grief marks within its partition (§4.1) — both documented. These were
modelled and excluded from findings per the bug-vs-posture rule. The build-phase non-immutable wiring is
the dominant residual risk and is already acknowledged in §17/§7; recommend the deferred pre-prod
immutability lockdown as the structural mitigation.
