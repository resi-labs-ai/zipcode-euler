# Kill-list — consolidated, re-reviewed remediation list

> Single source of truth for everything owed before auditor submission. Consolidates the
> 4-pass internal audit (`build/audit-claude/`), the 7 spec-edit docs in `build/`, and the
> open items in `build/tickets/PROGRESS.md`.
>
> **Two passes done.** Pass 1: each item evaluated against `contracts/`. Pass 2: 39
> independent adversarial agents re-verified every disposition against `contracts/`,
> `reference/` (upstream), and the audit/spec docs. Pass 2 **overturned 2** dispositions,
> **revised ~14** (fix-mechanism or severity corrections; several FIX→DOC), and **confirmed
> the rest** with completeness caveats. Verdicts below are the post-pass-2 state.
>
> Disposition: **FIX** (confirmed real, code change) · **DOC** (wording/runbook only) ·
> **DISMISS** (verified not-real) · **DEFER** (ratified, track only).

## Source docs (provenance — every item traces here)
- **Audit (origin of findings):** `build/audit-claude/` → `SUMMARY.md`, `findings.md`,
  `interconnection-findings.md`, `reference-diff-findings.md`, `role-based-findings.md`.
- **Spec/design (what's by-design vs gap):** `build/claude-zipcode.md` (master spec; §7 NAV
  asymmetry, §8.4 resolve, §13 trust boundary), `build/coverage-floor.md`, `build/lp-path-lock.md`,
  `build/CoW-exit.md`, `build/outflow-gate.md`, `build/fair-lp.md`, `build/twap-ring.md`, `build/zap-residual.md`.
- **Code under fix:** `contracts/src/**`, `contracts/script/**`. **Upstream truth:** `reference/**`
  (euler-earn, euler-vault-kit, euler-price-oracle, Baal, zodiac-core, zodiac-modifier-roles,
  erc7540-reference, maple-withdrawal-manager, chainlink-ccip, subtensor).
- **Work tracker:** `build/tickets/PROGRESS.md` (forward edge) + `build/tickets/{track}/{ID}-{slug}.md`.
- **Driver for a fresh agent:** `build/kill-list-driver.md` (paste-as-prompt handoff).

## What pass 2 changed (read this first)
- **H4 escalated DECIDE → FIX (HIGH).** It is NOT an interruption-window risk — CCIP admin
  loss is **guaranteed on every deploy, both chains**. `setCCIPAdmin` only moves a cosmetic
  view; the registry `administrator` is left as the throwaway deploy Script. The "atomic
  deploy + runbook" option I floated is **not viable** (the timelock can't `acceptAdminRole`
  inside the script broadcast). Needs real `transferAdminRole(timelock)+acceptAdminRole`.
- **L1 overturned FIX → non-issue.** The "gross-cap bricks exits" DoS doesn't exist
  (operator drives `Pm→0` via `commit()`, no ceiling). The co-located *real* defect is the
  M2 double-count. L1 folds into Group 2; the "verify after M2" note was misdirected.
- **FIX → DOC downgrades:** M8, L4, L15, L17, L6r (and M3 from DECIDE → DOC). Each proposed
  code change was unnecessary or actively wrong (details inline).
- **DOC → FIX upgrade:** I6 (one-line code fix, error symbol already exists).
- **Fix-mechanism corrections (still FIX):** M7 (tally keying), L18 (`_disableInitializers`
  doesn't exist in this base), M6 (proposed fix incomplete), H5 (fail-close, don't gate),
  M5 (assert already exists — only the warning is owed).
- **New caveat surfaced:** every oracle monotonic guard needs `error StaleReport()` *declared*
  or it won't compile; H1's guard must sit in shared `_writePrice` to also cover `seedPrice`.

---

## A. FIX — confirmed real, code change

### Group 1 — Oracle monotonic-timestamp guard (3 write sites, one pattern)
`SzAlphaRateOracle.sol:86` already has the strictly-newer guard (`ts <= latest.ts → StaleReport`);
three siblings omit it. **Each site must also DECLARE `error StaleReport()` — the one-liner alone won't compile.**
- [x] **H1** (HIGH) · `ZipcodeOracleRegistry._writePrice` (`:127-133`). Out-of-order/replayed RT-3
  overwrites a fresher mark → shields a bad loan from liquidation. **Fix:** `if (ts <= cache[lien].timestamp) revert StaleReport();`
  in **shared `_writePrice`** (so it also covers the `seedPrice` clobber driving interconnection-C4 draw path). Use `<=`.
  **DONE 2026-06-15 (SEC-01).**
- [x] **M1** (MED, DoS) · `SzipNavOracle._processReport` leg-write (`:286-297`). Deviation band is
  price-only; replaying last price with a backdated `ts` freezes issuance+buy-burn. **Fix:** `if (prior.ts != 0 && ts <= prior.ts) revert StaleReport();` before `:297`.
  **DONE 2026-06-15 (SEC-01).**
- [x] **L3** (LOW) · `SzipReservoirLpOracle._writePrice` (`:113-118`). Same gap. Note: not pure
  grief — a stale-but-still-fresh *higher* mark over-credits reservoir collateral. **Fix:** same guard + error decl.
  **DONE 2026-06-15 (SEC-01).**

### Group 2 — Coverage sidecar-LP double-count (one fix; absorbs L14 and the real part of L1)
- [ ] **M2** (MED, permissionless via LP-share donation to sidecar) · `coverageValue()` counts
  sidecar ICHI-LP twice: `committedValue()`=`_grossValueOf(sidecar)` already includes
  `_lpValue(_lpShares(sidecar))` (`SzipNavOracle.sol:376`) **and** `pathLockedLpEquity()` sums LP across
  both safes (`:386-390`). Inflates `covered()`/`lpBurnKeepsCovered()` → `removeLiquidity`/`release`/`postBid`
  below the true floor. **Fix:** scope `pathLockedLpEquity()` to **mainSafe-only** (`_lpShares(mainSafe)`,
  `_reservoirDebt(mainSafe)`) — single-counts LP *and* debt. **Land it in `coverageValue`/the oracle view, NOT
  in `committedValue` (that would corrupt `freeValue` and the Committed/Released events).**
- [ ] **L14** — same root; resolved by the M2 fix (the cross-view `freeValue` vs `gross−coverageValue` desync).
- [ ] **L1** — *overturned as a standalone bug* (gross-cap is correct, operator-recoverable). Its real
  content is the M2 double-count. No separate work; verify the partition `gross − coverageValue = Pm` after M2.

### Group 3 — Euler venue (`EulerVenueAdapter.sol`)
- [x] **H2** (HIGH) · `openLine` appends to the EE supply queue every origination; `closeLine` never
  prunes (`:222-233,:343-360`). `MAX_QUEUE_LENGTH=30` (confirmed `reference/euler-earn/.../ConstantsLib.sol:17`)
  → origination permanently bricks after ~29 lines. **Fix:** prune the closed-line vault in `closeLine`
  (`setSupplyQueue` only requires `cap!=0` on *remaining* entries — no timelock/removal path needed).
  **DONE 2026-06-15 (SEC-06).**
- [x] **L8** (MED) · `fund` only withdraws from base; closed-line USDC strands, `baseBalance` underflows
  on a later `fund` (`:285-292`). **Fix:** add a line→base defund `reallocate` in `closeLine` (`assets:0` on
  the line leg redeems all shares; base leg absorbs it; market must still be EE-enabled). *Distinct from H2 —
  queue-prune vs USDC-reclaim; both in `closeLine`, neither subsumes the other.* **DONE 2026-06-15 (SEC-07).**
- [x] **L9** (LOW grief) · `fund` sizes off `convertToAssets(balanceOf(EE))`; a 1-share donation reverts
  `reallocate` (`:295-297`). **Fix:** use `config[id].balance` run through **`previewRedeem`** (not
  `convertToAssets`) to byte-match EE's internal rounding. **DONE 2026-06-15 (SEC-11).** Shared
  `_eeSupplyAssets(market) = previewRedeem(config(market).balance)` helper sizes both `fund` legs + the SEC-07
  defund base leg (line leg stays `assets:0`); donation-immune by construction. Test `MockEulerEarn` made faithful
  to EE's `config.balance`/`previewRedeem`/`InconsistentReallocation` accounting to reproduce the grief fail-before/pass-after.
- [x] **M6** (MED liveness) — *FIX, but the proposed fix was incomplete (REVISE).* A deploy-time
  `timelock()==0` assert is a one-time snapshot: the external EE owner can raise the timelock later, and the
  **dominant** brick is perspective-verification of the custom line vault (custom IRM + gating hook + retained
  governor), which the assert doesn't touch. **Fix:** (1) runtime precheck in `openLine` reading
  `eulerEarn.timelock()` with a legible revert; (2) deploy-time assert the EE factory perspective verifies a
  probe vault built identically to `openLine`'s. **DONE 2026-06-15 (SEC-08).** (1) `openLine` aborts with
  `EulerEarnTimelockNonZero` before any line state is built (`EulerVenueAdapter.sol:201`). (2) new
  `SzipPerspectiveProbe` contract builds a line-vault-shaped probe and asserts `isStrategyAllowed`, wired into
  `DeployLocal._configureEulerEarn`. **Finding (validated, framing corrected):** the live EE-factory perspective
  is `EVKFactoryPerspective` — **provenance-only** (`isVerified = isProxy`), so it never inspects IRM/hook/governor;
  the "dominant brick" does NOT exist under the *current* perspective. The probe's real value is guarding a
  **future** external `setPerspective` swap (e.g. to a config-inspecting/ungoverned-only perspective that would
  reject the governed+hooked line vault and brick origination). See `reports/SEC-08-report.md`.

### Standalone FIX
- [x] **H4** (HIGH) — *overturned from DECIDE.* Registry `administrator` is left as the deploy Script on
  both chains (`DeploySzAlphaBridge.s.sol:121,162`); `setCCIPAdmin` (`:126`) only mutates `getCCIPAdmin()`, which
  the registry never re-reads. Pool can never be re-pointed/delisted. The `:131` assert checks only
  `getCCIPAdmin` → false confidence. **Fix:** add `transferAdminRole(localToken,newAdmin)` to `ICctRegistry`,
  call `transferAdminRole(token, timelock)` in `deploy964`+`deployBase`, document the timelock `acceptAdminRole`
  runbook step (2-step, unavoidable), and assert `pendingAdministrator==timelock`. **DONE 2026-06-15 (SEC-03).**
  Per-chain durable target (the kill-list's "timelock both chains" was shorthand): **964 → `ccipAdmin`**, **Base →
  `timelock`** — the same durable authority each chain's existing `setCCIPAdmin` already intends (`setCCIPAdmin`
  kept, aligns `getCCIPAdmin()` for future re-registration). Extended `ICctRegistry.ITokenAdminRegistry` with
  `transferAdminRole` + `TokenConfig`/`getTokenConfig`; replaced the `:131` false-confidence `getCCIPAdmin` assert
  with `getTokenConfig(token).pendingAdministrator == <durable>` (added analogue to `deployBase`); runbook
  `acceptAdminRole` documented in both functions' NatDoc + the report (the one residual interruption window).
  Regression: `test/bridge/SzAlphaBridge.t.sol::SzAlphaAdminHandoffTest` (2 `test_SEC03_*`, mock CCT infra etched
  at the hard-coded addresses) — fail-before/pass-after confirmed. **Standing runbook obligation logged in PROGRESS.**
- [x] **H5** (HIGH-ish) — *DECIDE resolved → fail-close only, keep the asymmetry.* `_xAlphaUSD()`
  (`SzipNavOracle.sol:517-525`) returns 0 when the rate is unseeded (`exchangeRate()==0` never reverts), silently
  underpricing xALPHA in three ungated consumers: `navExit`, `coverageValue`, and `ExitGate` tvlCap. **Fix:**
  fail-closed in `_xAlphaUSD()` — `if (rate == 0) revert RateUnseeded();`. **Decision: do NOT gate exit/coverage
  on `fresh()`** — that breaks the deliberate §7 max-entry/min-exit (last-good-mark) asymmetry; failing closed on
  *unseeded* (≠ stale) is the correct, narrow fix. **DONE 2026-06-15 (SEC-04).** `error RateUnseeded()` declared
  + the `rate == 0` guard in the shared `_xAlphaUSD()`; all four named consumers inherit it (navExit /
  grossBasketValue / freeze coverageValue / ExitGate deposit). Regression: 5 `test_SEC04_*` across
  `SzipNavOracle.t.sol` (unseeded fail-close + seeded-correct + asymmetry-preserved), `DurationFreezeModule.t.sol`
  (real freeze coverageValue), `ExitGate.t.sol` (real deposit path) — fail-before/pass-after confirmed.
- [x] **M4** (MED) · `SzipReservoirLpOracle` deployed with zero author/workflowId so its CRE identity check is
  skipped; the P9 seal loop omits it (`DeployZipcode.s.sol:526-531`). Default mainnet path (`LP_TWAP_WINDOW=0`)
  is the vulnerable one. **Fix:** `if (address(d.lpOracle) != address(0)) _sealIdentity(address(d.lpOracle));`
  + extend `requireIdentityWired` — **both conditional** on `d.lpOracle != 0` (the fair-LP branch leaves it unset).
  **DONE 2026-06-15 (SEC-05).** P9 now seals `d.lpOracle` (`:535`) and a new `ZipcodeDeployAsserts.
  requireReceiverIdentityWired(address)` per-receiver gate (`error ReceiverIdentityNotWired`) asserts it (`:542`),
  both guarded `!= address(0)`. 7 new `test_SEC05_*` in `ZipcodeDeployIdentityGate.t.sol` (identity sealed,
  dormant-accepts-vs-sealed-rejects behavioral pair on the REAL oracle, pre-gate negative/positive, fair-LP guard)
  prove the fix mechanism; the SCRIPT WIRING is proven end-to-end via `DeployLocal` on a fresh Base-fork anvil —
  before: live pre-fix lpOracle `getExpectedWorkflowId()==0x0`; after: sealed `==0x..01` + owner=Timelock;
  fail-closed: seal removed → deploy reverts `ReceiverIdentityNotWired` at the pre-gate.
- [x] **L2** (LOW→MED) · `setLpTwapWindow(>0)` against a plugin-less/under-seeded Algebra pool bricks *every*
  NAV read; setter has zero validation (`SzipNavOracle.sol:247-250`). **Fix:** in the setter, for non-zero window
  assert `IAlgebraPool(pool).plugin() != 0` and `IAlgebraOraclePlugin(plugin).isInitialized()`. (Full cardinality
  isn't queryable on-chain; the residual window>history edge fails closed on first read, recoverable via `set(0)`.)
  **DONE 2026-06-15 (SEC-10).** Added `error LpTwapPluginNotReady()` + a non-zero-window precheck (require `ichiVault`
  wired, `pool.plugin() != 0`, `plugin.isInitialized()`); `set(0)` stays unconditionally valid.
- [x] **M7** (LOW-MED grief) · `RecycleModule.divert` (`:285-310`) bounds per-call but not cumulatively; the
  docstring's "can never over-fill" is false across calls. **Fix:** NOT `divertedAgainst[hole]` (provision is a
  single re-markable scalar — keying by value is buggy). Use `lastSeenProvision` + `divertedSinceProvisionChange`,
  reset on any provision change; assert `diverted + amount*1e12 <= hole`. (Do not have `divert` write provision.)
  **DONE 2026-06-15 (SEC-09).**
- [ ] **I6** (LOW) — *upgraded DOC → FIX.* 8 of 9 szipUSD modules drop the init-time `operator != owner`
  invariant on `setOperator` re-point; `LpStrategyModule.sol:141` is the only one that re-checks. The
  `OwnerIsOperator` error already exists in each. **Fix:** add `if (operator_ == owner) revert OwnerIsOperator();`
  to each sibling's `setOperator` (RecycleModule, ReservoirLoop, SzipBuyBurn, HarvestVote, Sell, Exercise, OffRamp,
  + DurationFreeze for consistency).
- [x] **L11** (info) · `ZipRedemptionQueue.redeem()` emits raw caller `shares` on sub-unit input (`:248`).
  **Fix:** recompute `shares = assets * scaleUp` before emit (mirror `withdraw()` `:221`). *Prefer this over adding
  a `% scaleUp` revert guard — the guard changes currently-accepted inputs.* Redeem is effectively dead in the
  single-requester topology anyway. **DONE 2026-06-15 (SEC-12).**
- [ ] **L12** (LOW) · `postBid` `validTo` ceiling is anchored to post-time, so worst-case fill age is `2·maxAge`
  (`SzipBuyBurnModule.sol:304`). **Fix:** cap `validTo <= min(required leg.ts) + maxAge`; guard the `maxAge==0`/oldest-leg-age==maxAge
  underflow edge.
- [ ] **L18** (info/QA) · 9 module mastercopies aren't init-locked despite the docstring claim. *The proposed
  `_disableInitializers()` does NOT exist in zodiac-core's `Initializable` (OZ-only) — won't compile.* **Fix:**
  use the zodiac-core `TestModule` idiom (constructor calls `setUp` under the `initializer` modifier) or add a
  `_disableInitializers`-equivalent to the base; **and** correct all 9 docstrings. Non-exploitable (never enabled).

---

## B. DOC / runbook — no code change (or code change rejected)

- **M3** (LOW) — *DECIDE → DOC.* The fill-after-coverage-drop can't breach the floor: buy-burn USDC is
  engine-Safe value excluded from `coverageValue()`. APP_DATA is pinned to `0` so CoW hooks are deliberately
  forbidden. **Action:** document that filling is intentionally not fill-time gated; optionally shrink deployed
  `NAV_MAX_AGE` (currently 1 day) to shrink the undercovered-fill window. Reject the CoW hook.
- **M8** (LOW) — *FIX → DOC.* `_resolve` full-provision heal is the ratified §8.4 "clean resolution" design;
  totalProvision invariant holds. The proposed `capitalSlashAmount <= recoveryProceeds` assert is **unit-incoherent**
  (xALPHA bond units vs USD) and `_resolve` has no such param — **reject it.** **Action:** reconcile the
  `DefaultCoordinator.sol:27-28` header (provisions write up by realized receipts *or* fully on terminal resolve).
- **L4** (info) — *FIX → DOC.* All-or-nothing batch is the intentional WOOF-02 fail-closed design; 1-year
  validity window + producer sharding mitigate. Per-key try/catch would **weaken** it (swallows poison keys). 
  **Action:** producer runbook (MAX_LIENS_PER_REPORT sharding), no code.
- **L6r** (info) — *FIX → DOC/cosmetic.* CEI verified correct; an over-bond `capitalSlashAmount` reverts the
  whole tx atomically (no strand) and is re-submittable. The proposed assert is a no-op. Optional clarity only.
- **L13** (info) — *bucket holds, rationale was wrong.* Not "debt subtracted consistently" — a reservoir borrow
  is a **double-squeeze**: numerator down (`pathLockedLpEquity` debt) AND floor up (warehouse `maxWithdraw` drop).
  Fail-closed/self-DoS, recovers on repay. **Action:** re-document; optional liveness footgun note.
- **L15** (info) — *FIX → DOC.* Reverse-pair quote already fails closed (`ZipcodeOracleRegistry.sol:153`); EVK
  never quotes reverse. "Add inverse support" = dead code. **Action:** one-line comment that the adapter is
  intentionally forward-only.
- **L17** (info) — *FIX → DOC/optional.* USDC→eePool allowance always settles to 0 (exact-amount `forceApprove`,
  EE pulls full amount, `eePool` immutable). The zipUSD→gate reset IS needed (gate is re-settable) so the asymmetry
  is justified. **Action:** optional comment, or add the reset for symmetry. Not a bug.
- **I4** (info) · `SzAlphaRateOracle` "no owner / immutable" is false (inherits Ownable; Forwarder + workflow
  identity are Timelock-mutable; economic knobs *are* immutable). **Action:** correct `claude-zipcode.md:146` and §2/§6.
- **I5** (info) · `WarehouseAdminModule.safe` (injected) vs Roles `avatar` (checked) are independent slots; a
  one-sided re-point silently bricks SUPPLY/REDEEM (incl. senior par-redemption → liveness). Fails closed.
  **Action:** runbook — paired `setSafe`/`setAvatar` with a parity check; correct docstrings `:24,:28`.
- **L16** (info) · Global `scale` assumes 18-dp base; `_strictDecimals==18` makes non-18dp unreachable.
  **Action:** comment that the guard is load-bearing and must not be relaxed without per-key scale.
- **DEFER-prorata** — *DEFER → DOC.* The "loan-marked-bad signal absent" premise is wrong: `writeProvision`
  exists and flows to the **junior** NAV (`ExitGate` ragequit self-prices on impairment continuously). The
  **senior** par queue is intentionally impairment-blind (single trusted requester). No queue change.

### Design notes (by design — re-affirm, don't fix)
- **I1** · No on-chain junior redeem-for-assets; exit is the NAV-tracking CoW secondary. Ratified.
- **I2** · *Caveat: my earlier wording was imprecise.* szipUSD **shares** are NAV-priced (`max(spot,twap)`);
  the flat $1 mark is only on the zipUSD **deposit input** (`SzipNavOracle.sol:525`). Real latent risk: a zipUSD
  **de-peg** over-issues szipUSD and dilutes stayers (LOW; mitigated by atomic capacity-gated minting). Worth a
  tighter doc note; optional hardening = price the zipUSD leg off realized backing.
- **I3** · Par-burn 1:1 is treasury-internal (single requester escrows its own zipUSD); the Maple/Centrifuge
  impaired-rate comparison applies to open multi-requester queues, not this. `MultipleRequesters` guard is the
  sole defense — document that `redeemController` must never be an untrusted party.

---

## C. DISMISS — verified not-real

- **H3** (not a vuln) · Confirmed — but the decisive reason is **custody, not pause**: depositors never hold raw
  Loot (`ExitGate.sol:172` mints Loot only to the Gate). Pause (`SummonSubstrate.s.sol:134`, test-asserted) is
  secondary. **Reject the audit's `lockAdmin()` fix** — `adminLock` only blocks new admin-role grants, it does NOT
  pin the pause flag. Keep the existing `loot.paused()` test.
- **L5** (not real) · `maxAge==0` is unreachable — immutable, ctor rejects 0, no setter (`SzipNavOracle.sol:82,194,204`).
- **L10** (not real) · Single-requester topology enforced by the `MultipleRequesters` guard
  (`ZipRedemptionQueue.sol:168-172`); the dropped ERC7540 guard isn't even universally present upstream.

---

## D. DEFER — genuinely absent, ratified (track only)

- **drawgate** (coverage-floor Phase 2) — *confirmed absent and sound to defer.* Junior is structurally
  over-collateralized; zipUSD creation is one-way and the meter only moves the safe way; venue LTV/cap + the two
  `covered()` outflow gates suffice. No credible path where draws outrun coverage. Ticket (if revisited): add
  `zipUSDValue()` TWAP-bracketed view + `illiquidSeniorValue()+draw <= zipUSDValue()` gate in `_draw`.
- **CoverageGuard refactor** — *confirmed: no such contract, none needed.* Single coverage source
  (`DurationFreezeModule`) via the `ICoverageGate` seam, two consumers, deploy-asserted. Cosmetic at best.
- **CoW exit-book page (FE) + CRE bid-automation loop** — *confirmed unbuilt; no contract change needed.* FE
  withdraw spine (`useCowExit.ts`, `ZcWithdrawModal.vue`) shipped; depth-chart page + the `clamp(free−harvest,0,cap)`
  CRE loop are net-new off-chain/UI (tracked as CRE-05). Contract surface (`postBid`/`cancelBid`) is complete.

---

## Tally (post-pass-2)

| Disposition | Count | Items |
|---|---|---|
| FIX | 16 | H1 H2 H4 H5 M1 M2 M4 M6 M7 L2 L3 L8 L9 L11 L12 L18 I6 |
| DOC | 14 | M3 M8 L4 L6r L13 L15 L17 L16 I1 I2 I3 I4 I5 prorata |
| DISMISS | 3 | H3 L5 L10 |
| DEFER | 3 | drawgate · covguard · exitbook |
| dissolved | 1 | L1 (folds into M2/Group 2) |

> HIGHs: **H1, H2, H4 are real FIX** (H4 escalated). **H5** is a real fail-close FIX. **H3** dismissed.
> No HIGH left unresolved or in limbo. The earlier "3 open design decisions" collapsed: H5 → fail-close,
> M3 → DOC, H4 → FIX. Nothing now requires a user design call to proceed to ticketing.

## Next phase
Mint tickets from A into `build/tickets/sec/` (`SEC-NN`; Groups 1/2/3 each one ticket, standalone items one
each), and DOC items into a single `SEC-DOC` sweep. Then: fresh anvil deploy → solidify `build/wires/` → CRE → FE.
