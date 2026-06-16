# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**SEC-06 — `closeLine` prunes the closed line from the EE supply queue (Group 3a / H2).** Ticket: `build/tickets/sec/SEC-06-closeline-queue-prune.md`.
- **Deliverable:** in `EulerVenueAdapter.closeLine`, remove the closed line's borrow EVAULT from the EulerEarn supply queue (`setSupplyQueue` minus the closed vault) so the 30-slot queue does not grow unboundedly and origination cannot permanently brick.
- **Source:** `build/kill-list.md` Group 3 / H2. Driver: `build/kill-list-driver.md`. (See the standing concurrent-line-ceiling design obligation below — SEC-06 reclaims *closed*-line slots only, not the ~29 concurrent ceiling.)
- **Done when:** `forge build` clean; `forge test` green + the named `SEC06_*` regression (open→close→reopen churn past the cap stays live); test output quoted in the ticket.

> **SEC track is the active build phase** (auditor-prep, 16 tickets authored — see the SEC track section below).
> Work them one at a time in the correctness-first order: SEC-01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 →
> 11 → 12 → 13 → 14 → 15 → SEC-DOC. After each lands, set the next `SEC-NN` as NEXT.
>
> **The Frontend ↔ anvil track is COMPLETE** (FE-00…FE-07, 2026-06-10/11). The **CRE track** (CRE-00…CRE-06) is
> DEFERRED behind the SEC remediation push; its head is CRE-00 (scope retained in the Backlog table below).

---

## SEC track — kill-list remediation (auditor-prep)

Source of truth: `build/kill-list.md` (16 FIX, 14 DOC). Driver: `build/kill-list-driver.md`. Tickets in
`build/tickets/sec/` (`SEC-NN`; Groups 1/2/3 each one ticket, standalone FIX items one each, all DOC items
→ one `SEC-DOC` sweep). One ticket at a time: focused change, regression test, verify, mark done, next.
Worked correctness-first per the driver's suggested order.

**All 16 SEC tickets are AUTHORED** (SEC-01…SEC-15 FIX + SEC-DOC). **SEC-01 + SEC-02 + SEC-03 + SEC-04 + SEC-05 are DONE (2026-06-15); SEC-06 is now NEXT.**
The harness drives builds one at a time; gate per SEC ticket is `forge build` + `forge test` green + the named
`SECnn_*` regression test (deploy-script tickets re-run `DeployLocal` against a fresh anvil fork). SEC-DOC is
doc/comment-only (no regression test).

| ID | Item(s) | What | Status |
|---|---|---|---|
| SEC-01 | Group 1 (H1/M1/L3) | Oracle monotonic-timestamp guard at 3 write sites + `error StaleReport()` decls | **DONE 2026-06-15** — `sec/SEC-01-oracle-monotonic-guard.md` |
| SEC-02 | Group 2 (M2/L14/L1) | Coverage sidecar-LP double-count — scope oracle `pathLockedLpEquity()` mainSafe-only | **DONE 2026-06-15** — `sec/SEC-02-coverage-sidecar-lp-double-count.md` |
| SEC-03 | H4 | CCIP admin handoff — `transferAdminRole`(964→ccipAdmin, Base→timelock) + accept runbook + pendingAdministrator assert | **DONE 2026-06-15** — `sec/SEC-03-ccip-admin-handoff.md` |
| SEC-04 | H5 | `_xAlphaUSD()` fail-close on unseeded rate (keep §7 asymmetry) | **DONE 2026-06-15** — `sec/SEC-04-xalphausd-fail-close.md` |
| SEC-05 | M4 | Seal `lpOracle` CRE identity in P9 + extend pre-gate (both conditional on `lpOracle != 0`) | **DONE 2026-06-15** — `sec/SEC-05-seal-lporacle-identity.md` |
| SEC-06 | Group 3a (H2) | `closeLine` prune of closed-line vault from EE supply queue | **NEXT** — `sec/SEC-06-closeline-queue-prune.md` |
| SEC-07 | L8 | `closeLine` line→base defund reallocate (reclaim stranded USDC) | **TICKETED** — `sec/SEC-07-closeline-defund-to-base.md` |
| SEC-08 | M6 | `openLine` runtime EE-timelock precheck + deploy-time perspective probe | **TICKETED** — `sec/SEC-08-openline-timelock-precheck-perspective-probe.md` |
| SEC-09 | M7 | `RecycleModule.divert` cumulative bound (lastSeenProvision tally) | **TICKETED** — `sec/SEC-09-recycle-divert-cumulative-bound.md` |
| SEC-10 | L2 | `setLpTwapWindow(>0)` Algebra plugin/init validation | **TICKETED** — `sec/SEC-10-setlptwapwindow-validation.md` |
| SEC-11 | L9 | `fund` sizing via `previewRedeem(config.balance)` (donation-immune; shared `_eeSupplyAssets` helper) | **TICKETED** — `sec/SEC-11-fund-previewredeem-sizing.md` |
| SEC-12 | L11 | `ZipRedemptionQueue.redeem()` recompute canonical shares before emit (event-only) | **TICKETED** — `sec/SEC-12-redeem-canonical-shares-event.md` |
| SEC-13 | L12 | `postBid` `validTo` anchored to `min(leg.ts)+maxAge` (+ new oracle `oldestRequiredLegTs` view) | **TICKETED** — `sec/SEC-13-postbid-validto-leg-anchor.md` |
| SEC-14 | L18 | Init-lock 9 mastercopies (empty `initializer` ctor lock — NOT `_disableInitializers`) + fix docstrings | **TICKETED** — `sec/SEC-14-mastercopy-init-lock.md` |
| SEC-15 | I6 | `setOperator` re-point `OwnerIsOperator` guard on 8 modules (mirror LpStrategyModule) | **TICKETED** — `sec/SEC-15-setoperator-owner-recheck.md` |
| SEC-DOC | M3 M8 L4 L6r L13 L15 L17 L16 I1-I5 prorata | Doc/runbook sweep (no behavioral code; 4 explicit rejects) | **TICKETED** — `sec/SEC-DOC-doc-runbook-sweep.md` |

> DISMISS (H3/L5/L10) + DEFER (drawgate/covguard/exitbook) left untouched per the kill-list — keep the
> existing `loot.paused()` test (H3) and add the deploy invariants the kill-list names where applicable.
> SEC-NN numbering above is provisional ordering, not final IDs; each ticket fixes its ID on authoring.

### Just done — SEC-05 (2026-06-15)
**Sealed the un-looped CRE-push `lpOracle`'s workflow identity + extended the deploy pre-gate** (kill-list M4; audit
ref-B / B3). `SzipReservoirLpOracle` is a `ReceiverTemplate` whose `onReport` workflow-identity check is **conditional**
(runs only when `expectedAuthor`/`expectedWorkflowId` are non-zero). P9's seal loop set those on six receivers but
**omitted the lpOracle**, and the fail-closed pre-gate only checked the controller as a "representative" — so the
lpOracle's identity stayed `bytes32(0)` (dormant) and any co-tenant workflow clearing the shared Keystone Forwarder
could push an arbitrary LP-share mark → mismark reservoir collateral → over-borrow (exceeds the documented
"compromised CRE" blast radius — no compromise needed).
- **Fix (2 files):** `ZipcodeDeployAsserts` gained `error ReceiverIdentityNotWired(address)` + a sibling
  `requireReceiverIdentityWired(address receiver)` `internal view` (reverts on `getExpectedWorkflowId() == 0`); the
  existing `requireIdentityWired(controller, registry)` + its `:534` call are untouched. `DeployZipcode.s.sol` P9 now
  `_sealIdentity(d.lpOracle)` (`:535`) and `requireReceiverIdentityWired(d.lpOracle)` (`:542`), **both guarded
  `!= address(0)`** (mirrors the `:544` `transferOwnership` conditional) so the fair-LP branch (ownerless
  `AlgebraIchiFairLpOracle`, `d.lpOracle == 0`) neither seals nor asserts and the deploy completes.
- **Gate green:** `forge build` clean; `forge test` **781 passed / 0 failed / 3 skipped** (+7 over SEC-04's 774; the 3
  skips are the pre-existing `DeployZipcode.t.sol` scaffold). 7 new `test_SEC05_*` in `test/ZipcodeDeployIdentityGate.t.sol`
  (no fork — the oracle ctor only reads `quote.decimals()`): identity-sealed; the **dormant-accepts-wrong-id vs
  sealed-rejects-`InvalidWorkflowId` behavioral pair on the REAL oracle**; sealed-accepts-correct-id (no false lockout);
  pre-gate negative/positive; fair-LP guard semantics. These 7 prove the FIX MECHANISM but do NOT run the deploy script.
- **End-to-end (the genuine deploy-script gate) — `DeployLocal` against a fresh Base-fork anvil** (`DeployLocal` is
  `DeployZipcode`; `_phaseP9` runs verbatim, CRE-push branch ⇒ `d.lpOracle` set): **before** = the live `:8545`
  pre-fix stack's lpOracle reads `getExpectedWorkflowId()==0x0` (the real dormant vuln); **after** = a fresh deploy with
  this fix seals it (`==0x..01`, author + `owner()==Timelock`); **fail-closed** = removing only the seal call makes
  `DeployLocal` revert `ReceiverIdentityNotWired` at the pre-gate before ownership transfer. (An earlier note claimed
  the unit behavioral test flips when the seal is removed — that was wrong; those tests never run the script. The
  script wiring is proven here instead.)
- **No spec change** (interface-level deploy fix; §9/§17 intent unchanged — the spec already prescribed sealing every
  receiver's identity; this fences the one the loop omitted). **No back-pressure / no new obligation** (uses the
  receiver's existing `setExpected*` surface + a new deploy-time lib fn). The standing **WOOF-10 deploy-bar obligation**
  (the skipped full-fork `DeployZipcode.t.sol`) is unchanged — SEC-05 adds a no-fork focused regression, does not
  un-skip it. Ticket (full output): `build/tickets/sec/SEC-05-seal-lporacle-identity.md`. Report:
  `build/reports/SEC-05-report.md`.

### Just done — SEC-04 (2026-06-15)
**`_xAlphaUSD()` fail-closed on an UNSEEDED xALPHA rate** (kill-list H5; audit finding #6 / interconnection C1). Pre-fix
`_xAlphaUSD()` returned `exchangeRate() × alphaUSD`, and `exchangeRate()` returns **0** (does not revert) when the
CRE-pushed cross-chain rate was never seeded — so the whole xALPHA leg was silently valued at **0**, underpricing three
ungated consumers (`navExit` underpays junior exits; freeze `coverageValue` under-counts the floor → can mis-gate
outflow; `ExitGate` tvlCap under-reads gross → lets deposits exceed the cap). The narrow fix fails closed on the
*genesis* zero only — distinct from a stale-but-seeded mark.
- **Fix (1 file, `SzipNavOracle.sol`):** declared `error RateUnseeded();`; `_xAlphaUSD()` (`:517-525`) now captures
  `uint256 rate = IXAlphaRate(rateSrc).exchangeRate();` then `if (rate == 0) revert RateUnseeded();` before the mark.
  The guard lives in the **shared internal**, so all four consumers (`navExit`, `grossBasketValue`, freeze
  `coverageValue` via `committedValue`/`freeValue`, `ExitGate` deposit) inherit it with no consumer edits. Docstring
  updated to state fail-closed-on-unseeded ≠ stale.
- **§7 asymmetry preserved (the Do-NOT):** staleness is still NOT gated on the exit/coverage path — only `rate == 0`
  reverts. `navEntry`/`navExit`/`fresh`/`_legStale`/`StalePrice`/`StaleRate` are byte-for-byte unchanged. The
  "gate every consumer on `fresh()`" alternative the audit floated was **deliberately rejected** (it breaks the
  ratified `exit-topology-intentional` last-good-mark asymmetry). The upward-stale-after-slash half of C1 is therefore
  accepted as residual (TWAP-lag + deviation-band remain its defense) — logged in the C1 finding.
- **Gate green:** `forge build` clean; `forge test` **774 passed / 0 failed / 3 skipped** (the 3 skips are the
  pre-existing `DeployZipcode.t.sol` skips; +5 over SEC-03's 769). 5 new `test_SEC04_*` regressions:
  `SzipNavOracle.t.sol` (3 — unseeded fail-close across navExit/grossBasketValue/spot/valueOf; seeded-correct;
  asymmetry-preserved-when-stale), `DurationFreezeModule.t.sol::SzipNavOracleParityTest` (1 — REAL freeze
  `coverageValue()` over the REAL oracle reverts unseeded), `ExitGate.t.sol` (1 — REAL deposit path reverts unseeded,
  re-seed succeeds). **Fail-before/pass-after confirmed** — removing the guard reproduces all 3 revert tests as
  "next call did not revert as expected."
- **No spec change** (interface-level fix; the §7 intent is unchanged — the spec already prescribed fail-closed-on-stale
  for issuance, and this fences a genesis hole the spec implicitly assumed away). **No back-pressure / no new
  obligation** (no contract surface owed). Per the ticket's flagged check: the alphaUSD leg `legCache[LEG_ALPHA_USD].price`
  cannot be seeded to 0 (`_processReport` rejects `ZeroPrice`), so only the rate's genesis zero slipped through — scope
  correctly stayed on the rate. Ticket (full output): `build/tickets/sec/SEC-04-xalphausd-fail-close.md`. Report:
  `build/reports/SEC-04-report.md`.

### Just done — SEC-03 (2026-06-15)
**CCIP `TokenAdminRegistry` registry-admin handoff closed** (kill-list H4, escalated DECIDE→FIX HIGH via audit
ref-B2 / finding #11). `DeploySzAlphaBridge` accepted the registry `administrator` role onto the ephemeral deploy
Script (to wire `setPool` in-broadcast) and never handed it on — `setCCIPAdmin` only mutates the token's
`getCCIPAdmin()` view, which the registry consumed once at registration and never re-reads. So post-deploy the
pool could never be re-pointed/delisted (RMN/CCIP upgrade, incident response), and the `:131`
`getCCIPAdmin()==ccipAdmin` assert gave false confidence on the wrong slot.
- **Fix (3 files):** extended `ICctRegistry.ITokenAdminRegistry` with `transferAdminRole` + `TokenConfig`/
  `getTokenConfig` (reference field names); `deploy964` now `transferAdminRole(token, ccipAdmin)` and `deployBase`
  `transferAdminRole(token, timelock)` after `setPool` (the durable authority each chain's `setCCIPAdmin` already
  intends — kept `setCCIPAdmin` for `getCCIPAdmin()` alignment per the Do-NOT). The `:131` assert is **replaced**
  by `getTokenConfig(token).pendingAdministrator == ccipAdmin` (analogue added to `deployBase`). The 2-step
  `acceptAdminRole` is documented as a mandatory post-deploy runbook step in both functions' NatDoc.
- **Per-chain target note:** the kill-list's "timelock both chains" was shorthand; the real durable target is
  964→`ccipAdmin`, Base→`timelock`. Both critics (spec-fidelity, reference-verifier) PASS on this reading.
- **Gate green:** `forge build` clean; new `SzAlphaAdminHandoffTest` (`test/bridge/SzAlphaBridge.t.sol`, 2
  `test_SEC03_*`) drives `deploy964`/`deployBase` against a mock CCT stack etched at the script's hard-coded
  addresses (new `MockTokenAdminRegistry`/`MockRegistryModuleOwnerCustom`/`MockTokenPoolFactory` in
  `BridgeMocks.sol`) — asserts the script is still `administrator` pre-accept AND `pendingAdministrator==<durable>`,
  then runs the runbook `acceptAdminRole` → durable is sole admin + the script's `setPool` reverts. **Fail-before/
  pass-after confirmed** (removing the two `transferAdminRole` calls → `registry admin handoff failed` on both).
  Full suite **769 passed / 0 failed / 3 skipped** (+2 over SEC-02's 767). **No spec change** (interface-level
  deploy fix; intent unchanged). **No back-pressure** (no contract surface owed — the fix is the deploy script
  using a real reference registry method). New standing runbook obligation logged below.
  Ticket (full output): `build/tickets/sec/SEC-03-ccip-admin-handoff.md`. Report: `build/reports/SEC-03-report.md`.

### Just done — SEC-02 (2026-06-15)
**Coverage sidecar-LP double-count closed** (kill-list Group 2: M2 + L14 + the real content of L1). One-line scope
in `SzipNavOracle.pathLockedLpEquity()` (`:388-392`): `_lpValue(_lpShares(mainSafe))` minus `_reservoirDebt(mainSafe)`
(was `mainSafe + sidecar` for both legs). The sidecar's LP + debt are already owned by `committedValue()`
(`_grossValueOf(sidecar)`), so `coverageValue() = committedValue + pathLockedLpEquity` now counts every Safe's LP
**exactly once**. Pre-fix, anyone could donate ICHI-LP shares into the sidecar to inflate `covered()` /
`lpBurnKeepsCovered()` and let `removeLiquidity`/`release`/`postBid` proceed below the coverage floor.
- **Surgical (Do-NOT honored):** only the oracle view changed (+ its docstring). `committedValue`, `freeValue`,
  `_grossValueOf`, `grossBasketValue`, all events, and the `ISzipNavBasket` interface are byte-for-byte unchanged — so
  `freeValue = gross − committedValue` and the §11-B Committed/Released accounting are untouched. LP stays IN the
  coverage numerator (single-count, not exclude — `build/lp-path-lock.md`). L1's "gross-cap DoS" disposition stayed
  overturned (not touched).
- **Gate green:** `forge build` clean; `forge test` **767 passed / 0 failed / 3 skipped** (the 3 skips are the
  pre-existing `DeployZipcode.t.sol` skips; +3 over SEC-01's 764). 3 new `test_SEC02_*` regressions in
  `SzipNavOracleParityTest` (`test/DurationFreezeModule.t.sol` — that suite already wires the REAL oracle, so the
  genuine double-count is exercised, not a settable mock): single-count (coverage rises by exactly one 15e18 mark on a
  sidecar donation, `pathLockedLpEquity` unchanged), partition (`gross − coverageValue == Pm` within ≤2 wei), and
  floor-breach (REAL `DurationFreezeModule` + REAL oracle + `MockEulerEarn`: single-counted 95e18 < 100e18 floor →
  `covered() == false`; pre-fix double-counted 110e18 lied `true`). **Fail-before/pass-after confirmed** — reverting
  the scope reproduces all 3 with the double-count signature (`110≠95`, `30≠15`, gap `15>2`).
- **No spec change, no back-pressure, no new obligation.** Internal oracle-view fix; no contract surface added or owed.
  Ticket (with full output): `build/tickets/sec/SEC-02-coverage-sidecar-lp-double-count.md`. Report:
  `build/reports/SEC-02-report.md`.

### Just done — SEC-01 (2026-06-15)
**Oracle monotonic-timestamp guard at the 3 sibling write sites** (kill-list Group 1: H1/M1/L3), mirroring the
existing `SzAlphaRateOracle.sol:86`. `error StaleReport()` declared + a strictly-newer `ts` guard added to:
`ZipcodeOracleRegistry._writePrice` (shared — covers BOTH `seedPrice` and the rt-3 batch loop), `SzipNavOracle.
_processReport` leg-write (before the `legCache` write, after the deviation block — so `DeviationExceeded` still
fires first on a same-ts price jump), and `SzipReservoirLpOracle._writePrice`. Timestamp-only; no value/deviation band
added (§17 / canonical pattern honored). Ticket: `build/tickets/sec/SEC-01-oracle-monotonic-guard.md`.
- **Gate green:** `forge build` clean; `forge test` **764 passed / 0 failed / 3 skipped** (the 3 skips are the
  pre-existing `DeployZipcode.t.sol` skips). 9 new `SEC01_*` regression tests across the 3 sites (a backdated/equal-ts
  replay reverts `StaleReport()` via every path; a strictly-newer write still succeeds). A **new test file**
  `test/SzipReservoirLpOracle.t.sol` was authored — none existed for that oracle.
- **Critics ran clean** (spec-fidelity **PASS** — faithful to kill-list Group 1, no invented mechanism, H1 correctly
  in the shared `_writePrice`, M1 `prior.ts != 0` first-write exemption correct; reference-verifier — all 3 bindings +
  field names resolve, `StaleReport` declared nowhere but the canonical sibling; junior-dev most-blocking item =
  the same-block seed re-anchor, resolved below). Implementation is zero-guess (the full suite is the proof).
- **Behavior change surfaced (intended fail-closed) — folded into the ticket + obligations below.** The controller
  re-anchors the lien mark via `seedPrice` at BOTH origination and draw, and `seedPrice` stamps `block.timestamp`, so
  two same-lien seeds in ONE block now revert. This is the H1 seed-clobber the kill-list wanted closed; 6 pre-existing
  tests that asserted same-ts/backdated-replay SUCCESS (3 oracle units + 3 integration, incl. one **false pass** in
  `test_Draw_ReAnchorBelowLTV_RollsBack` whose generic `expectRevert` was masking the LTV check) were updated with
  faithful forward-warps. No real regression.

### Just done — FE-07 (2026-06-11)
**Euler-native vault dashboard — the real reservoir EVK market + senior EE pool surfaced through euler-lite's OWN
lend/borrow/earn pages** (§4.7), committed to the layer repo (`resi-labs-ai`, commit `85f6908`). **Config + labels
only — no Zipcode composables, no contract writes, no euler-lite edits.** The back-pressure check **confirmed every
surface already exists (no obligation owed)** and that FE-00's labels already make the vaults *render*; the new work
was the one entity map FE-00 left empty.
- **The mechanism (verified, not re-architected):** euler-lite's server snapshot (`server/utils/vaults-cache.ts:
  refreshChainVaults`) sources the vault list from FE-00's `public/labels/8453/products.json` (`zipcode-reservoir.
  vaults[]` → evk) + `earn-vaults.json` (→ earn); **list inclusion = label membership** (`getVerifiedEVaults`/
  `isVerifiedVault` filter the `verified` flag, set true on snapshot membership at `useVaults.ts:200,615`), NOT governor
  matching. So the four fork vaults already rendered from FE-00 alone. The **verified BADGE**, though, runs
  `utils/vault/governor-verification.ts` (`isVaultGovernorVerified`/`isEarnVaultOwnerVerified`) which requires the
  product's declared **entity** to list the vault's on-chain `governorAdmin` + the EulerRouter `governor` — and FE-00's
  `zipcode` entity had **no `addresses` map**, so the reservoir market showed an *unverified* chip.
- **What shipped:** added an `addresses` map to the `zipcode` entity in `public/labels/8453/entities.json` declaring the
  three real, live on-chain governance authorities (read against the fork + cross-checked to `contract-map.md`):
  `0x77C2Cb…` (reservoir borrow-vault `governorAdmin` — the `ReservoirMarketDeployer` instance, see obligation below),
  `0x89ae08…` (Timelock — reservoir EulerRouter `governor()` + protocol root), `0xf39Fd6…` (team — base USDC market
  `governorAdmin` + EE pool `owner()`). Keys EIP-55 checksummed (`hasEntityAddress` is a case-sensitive
  `Object.keys(addresses).includes(getAddress(governor))`). Ticket: `build/tickets/frontend/FE-07-euler-native-vault-dashboard.md`.
- **Gate green + live-verified:** `npm run build` (`nuxt build`) ✨; built + served (`node .output/server/index.mjs`,
  env exported, `HOST=127.0.0.1 PORT=3000`) against the live anvil → `/` 200; `/api/labels/entities.json?chainId=8453`
  returns the `zipcode` entity with the three addresses; `/api/vaults?chainId=8453` returns **all four fork vaults**
  (reservoir borrow `0x1aFc`, escrow `0x8A5F`, base USDC `0x3A48` in `evkVaults`=3; EE pool `0x1a7A` in `earnVaults`=1).
  Critics ran clean (spec-fidelity **ALL PASS** — §4.7 faithful, §17 honored, no inbound obligation, declaring a live
  zipcode-controlled address is fact-not-fabrication; reference-verifier — all bindings resolve live, schema + case-
  sensitivity + EE undefined-branch auto-pass confirmed; frontend-binding — **back-pressure PASS**, all four render, no
  hidden filters, base-market `oracle()`=0x0 so the router-governor gate short-circuits). Cold-build is zero-guess (the
  ticket spells out the final `entities.json` verbatim).
- **EE pool note:** the EE pool is in `earn-vaults.json` but NOT in `products.json`, so `getDeclaredEntityKeys` returns
  `undefined` and `isEarnVaultOwnerVerified` returns `true` on earn-list membership alone (`governor-verification.ts:
  99-107`) — the owner declaration future-proofs it but was not strictly required for the earn page.
- **Finding B — fork-state limitation (no obligation, no config fix):** the reservoir **escrow collateral vault
  `0x8A5F…` is fork-deployed → absent from Base's `escrowedCollateralPerspective`** → euler-lite classifies it `evk`
  not `escrow` (confirmed live: it lands in the `evkVaults` bucket, not `escrowVaults`), and its `governorAdmin` is
  `0x0` (undeclarable). The borrow **pair still renders** (membership + `borrowLTV>0`) but the collateral leg shows an
  *unverified* chip in `VaultBorrowItem`. Mirrors FE-05's closed-line caveat — a fork-STATE limitation, not a contract
  gap. Also cosmetic: the LP collateral has no USD price on the fork (`priceService SOURCE_UNAVAILABLE` for `0x8A5F`),
  expected. Both resolve when the real Hydrex/Base escrow + LP-price plumbing exists post-MVP.

### Done earlier — FE-06 (2026-06-11)
**Solvency dashboard (§12 five metrics) via direct on-chain view reads**, committed to the layer repo (`resi-labs-ai`,
commit `f27302f`). The **back-pressure check confirmed every on-chain leg and flagged three off-fork data sources**:
- **What shipped:** `composables/useZipSolvency.ts` (the raw-bigint protocol-solvency aggregator, FE-03 `useZipPosition`
  shape — proxy-client reads, `navEntry` the only try/caught read, returns the 16-field `ZipSolvency` struct, derives
  `solvencyRatioBps = nav·1e12·10000/zipSupply` and `utilizationBps = borrows·10000/nav` with /0 guards, all-undefined
  when `!client.value`, never throws) + `components/zipcode/ZcSolvencyPanel.vue` (`{refreshKey}`-only self-contained
  panel: the five-metric `ZcStatCard` grid + the two real protocol-vault rows rendered into `ZcVaultAllocationTable`
  **internally**; `provision` as a NAV sub-line not a 6th card; the three deferred metrics flagged from component
  constants) + `pages/lender/portfolio.vue` (dropped the mock `protocol.aumUsdc` header card + mock single-row
  `vaultRows`/`ZcVaultAllocationTable` + now-dead imports; mounted `<ZcSolvencyPanel :refresh-key="positionRefreshKey">`;
  kept the mock hero + FE-03 `ZcPositionPanel` + transactions tab). Gate green: `npm run build` (`nuxt build`).
  Ticket: `build/tickets/frontend/FE-06-solvency-dashboard.md`.
- **Metric→view bindings (all real, live-verified on the fork):** NAV = reservoir `IEVault.totalAssets()` (= `cash`
  $2,000 + `totalBorrows` $6,000 = $8,000); senior AUM = `eePool.totalAssets()` ($9,000) read SEPARATELY as an
  allocation row (NOT summed into NAV — §12 ¶1 double-count rule; the EE pool supplies INTO the reservoir so its claim
  already resolves to reservoir cash+borrows); zipUSD supply = `zipUsd.totalSupply()` (2,000) → solvency ratio 40000
  bps = **4.00×**; utilization = `borrows/totalAssets` = **75%**, free liquidity = `cash` $2,000; szipUSD NAV/share =
  `navExit`/`navEntry` (≈$107.27, navEntry try/caught per the FE-03 seam) + `spot`/`twap`; `provision()` = $0 junior
  markdown sub-line; xALPHA insurance fund = `xAlpha.balanceOf(lienXAlphaEscrow.address)` = 0 (token balance, NOT
  `LienXAlphaEscrow.bondAmount` which is per-lien). Critics ran clean (spec-fidelity **ALL PASS** — §12 five metrics
  faithful, NAV non-double-count correct, provision routed to junior, §17 honored, no invention; reference-verifier —
  all 30+ bindings resolve, `navPerShare()` correctly absent, registry keys present; frontend-binding — **back-pressure
  PASS**, every real leg exists, the three deferred sources correctly have no fork view); cold-build returned **zero
  load-bearing guesses**.
- **Three back-pressure findings — DATA SOURCE DEFERRED off-fork, NOT a contract-surface gap (no obligation owed),
  rendered as an explicit flagged state (never a fabricated number):**
    1. **zipUSD peg** → no zipUSD secondary AMM on the fork (the real zipUSD pool is post-Hydrex; §6.2 peg = secondary-
       AMM price). Rendered **`$1.0000` · "par · no fork AMM"** (zipUSD mints 1:1 vs USDC, §4.5 — par is the honest MVP
       value). Resolves when the post-Hydrex zipUSD pool exists.
    2. **szipUSD trailing APR + Duration Bond premium APR** → no production on-chain source: the xALPHA-APR CRE feed is
       **CRE-03, not built** (the 8x-02 receiver exists, the Go producer remains), a trailing-realized yield needs NAV
       history the fresh fork lacks, and the Duration Bond premium needs a frozen position (no M1 default). Rendered
       **"—" · "pending CRE feed (CRE-03)"**; the **navExit/navEntry/spot/twap NAV/share reads beside it ARE real/live**.
       Resolves when CRE-03 ships.
    3. **off-chain insurance coverage** → CRE-published Proof-of-Insurance figure (§8.10), not built. Rendered **"—" ·
       "off-chain · CRE §8.10"**; the **xALPHA escrow fund beside it IS the real on-chain coverage leg**. Resolves when
       the §8.10 CRE feed ships. None of the three owes a new contract surface (all are off-chain/CRE/AMM legs deferred
       by design — mirrors FE-04's spoof-toggle finding).
- **Seams for later FE work:** (1) `useZipSolvency` is the **protocol-aggregate read template** (raw-bigint, no-args,
  proxy-client, never-throws) — the counterpart to FE-03's per-wallet `useZipPosition`; reuse it for any protocol-level
  read surface; (2) `rateToApyPct(ray)` returns `'0'` for the fork's `ZeroIRM` (rate 0) and TODO-stubs the non-zero
  branch to the euler-lite helper (`euler-lite/utils/vault/apy.ts`) — when a non-zero IRM is wired, fill that branch
  (do not hand-roll SPY→APY); (3) `<ZcSolvencyPanel>` is **route-agnostic** (no `definePageMeta`/auth inside) — it sits
  on the auth-gated lender portfolio now (FE-03/04/05 precedent), but a later move to a public/dedicated solvency route
  (or the landing `index.vue` grid) is a one-line remount. **Deliberate-choice (kept, not sanded by critics):** the
  panel mounts on `pages/lender/portfolio.vue` this window; public-route relocation is a deferred UX seam, out of scope.

### Just done — FE-05 (2026-06-11)
**Borrower line state + permissionless repay** (§4 / §4.4e / §9 / §15), committed to the layer repo (`resi-labs-ai`,
commit `b5fdc07`). The **back-pressure check shaped the ticket** (the contract wins, harness §1):
- **Draw is CRE-only — there is NO borrower-side draw write.** `EulerVenueAdapter.draw` is `onlyController`
  (`EulerVenueAdapter.sol:298`, only legal receiver = the immutable Erebor, `:302`); the controller's only write entry
  is `onReport` (Keystone-forwarder-gated) — no public originate/draw. So **`ZcDrawModal` is now read-only** (a line /
  draw-status view; "draws are originated by the protocol/CRE, §17").
- **Repay is the native EVK `repay`, permissionless — NOT a Zipcode method.** Spec §9 (line 838-839): *"Euler adapter:
  `EVault.repay` on the line's borrow account."* `openLine` installs the gating hook at `OP_BORROW | OP_LIQUIDATE` and
  **never hooks `OP_REPAY`** (`EulerVenueAdapter.sol:220`) → repay is ungated. Bind = `usdc.approve(lineRef, amount)` →
  `IEVault(lineRef).repay(amount, borrowAccount)` (direct vault approve, NOT Permit2 — mirrors the proven in-repo
  `ReservoirLoopModule.repay:251-259`). Any wallet repays (credits `borrowAccount`; no controller-enablement/operator
  bit) — the §4.4e permissionless property.
- **What shipped:** `composables/useZipLine.ts` (discover lines via the controller's `LienOriginated`/`LienStatusUpdated`/
  `LienReleased` `getContractEvents`, joined to the adapter's live `getLine`/`observeDebt`; raw-bigint `ZipLine[]`; the
  permissionless `repay({lineRef,borrowAccount,amount,full})` — approve via `sendZipTx`, the raw EVK repay via the new
  `sendRawZipTx`, `full`→`maxUint256` so EVK clamps the accrued debt) + **extended `composables/useZipTx.ts`** (added
  `sendRawZipTx({to,abi,functionName,args,value?})` for a **runtime-address** target, sharing the SAME 1.3× buffer via a
  private `sendBuffered` — the buffer is never re-implemented) + new `components/zipcode/ZcLinePanel.vue` (read-only line
  list: owed/equity-mark/draw-amount/status; Repay disabled when `owed==0||!open`) + rewritten `ZcDrawModal.vue`
  (read-only) + rewritten `ZcRepayModal.vue` (real approve→repay status track) + `pages/borrower/portfolio.vue` (mock
  `handleDraw`/`handleRepay` store mutations dropped; panel + modals wired; `lineRefreshKey` bump on repay `@success`) +
  `nuxt.config.ts`/`.env.example` (`zipDeployBlock`/`NUXT_PUBLIC_ZIP_DEPLOY_BLOCK`, default `47096000`, bounds the
  discovery `getLogs`). Gate green: `npm run build` (`nuxt build`) ✨. Ticket:
  `build/tickets/frontend/FE-05-borrower-line-repay.md`. Critics ran clean (spec-fidelity **ALL PASS** — §4/§4.4e/§9/§15
  faithful, §17 honored, no mechanism invented, no inbound obligation; reference-verifier — every ABI method/event +
  registry key + viem export + auto-import resolves, RPC proxy `ALLOWED_METHODS` includes `eth_getLogs`;
  frontend-binding — **back-pressure PASS**, every demanded surface exists); cold-build returned **zero load-bearing
  guesses**.
- **Seams for later FE work:** (1) **`useZipTx.sendRawZipTx`** is now the spine for any write to a **runtime/non-registry
  address** (per-line vaults, dynamically-discovered contracts) — reuse it, never re-implement the gas buffer; (2) the
  **`useZipLine` event-discovery pattern** (`getContractEvents` bounded by `zipDeployBlock`, joined to live struct
  reads) is the template for any "enumerate on-chain instances" FE read; (3) repay is **permissionless** and the
  connected wallet is **not** the borrower-of-record (disposable per-line `LineAccount`, §17) — no "my lines" filter.
- **Live-state caveat (logged, not a contract gap):** the only line on the post-smoke fork is **CLOSED** (`getLine(
  0x7c48…).open==false`, `observeDebt==0` — the smoke suite ran the full draw→repay→close loop, SP-14/SP-16). So the
  **read** path is fully live-verified now (the panel reads the real closed line; Repay correctly disabled) and the
  **repay binding** is fully verified (real `repay`/`debtOf` on the live `lineRef`, `asset()==USDC`, `borrowAccount`
  from `getLine`; encode + gas-estimate succeed), but a live repay **state change** needs drawn debt — re-run SP-14
  origination or have the reviewer draw a line, then the modal's approve→repay lands and `observeDebt` drops. This is a
  fork-STATE limitation, **not** a binding/back-pressure gap (no obligation owed).

### Done earlier — FE-04 (2026-06-11)
**szipUSD junior exit via the CoW book** (§6.4), committed to the layer repo (`resi-labs-ai`, commit `5f6d170`).
Back-pressure check **reshaped the ticket** — the original FE-04 row (above, now replaced) conflated the junior exit
with the senior queue; the spec §6.4 explicitly warns against exactly that. **The deploy target is Base mainnet; anvil
is only a local fork** — so FE-04 builds the exit as it works on **mainnet** (real CoW order) and spoofs only the
un-forkable solver leg (see `build-for-mainnet-spoof-on-anvil` working principle).
- **What shipped:** `composables/useCowExit.ts` (the szipUSD→USDC CoW sell-order spine: reads CoW wiring **live from
  the deployed `SzipBuyBurnModule`** — `settlement`/`vaultRelayer`/`usdc`/`szipUSD`/`domainSeparator`/`dBps`/
  `quoteMaxPrice` — never hard-coded; `approveRelayer` via the FE-02 `useZipTx` spine; `buildOrder`/`signOrder` mirror
  our own `SzipBuyBurnModule._orderUid` in the **bytes32 EIP-712 form** via `@wagmi/vue useSignTypedData`, flipping
  3 fields for the lender SELL (`kind = keccak256("sell")`); a **domain self-check** asserts the viem-computed
  separator == on-chain `0xd72ffa78…` before signing; `submitOrder`/`orderStatus` branch on **`isCowLive`**) +
  rewritten `components/zipcode/ZcWithdrawModal.vue` (the §6.4 status track **Order resting → Filled → szipUSD burned**,
  now-vs-waiting preview off `quoteMaxPrice` vs `navExit`, approve→sign→submit) + `pages/lender/portfolio.vue` (mock
  `handleWithdraw`/store-mutation dropped; `@success`→FE-03 panel refresh) + `nuxt.config.ts` (`runtimeConfig.public.
  cowLive`) + `.env.example` (`NUXT_PUBLIC_COW_LIVE`). Gate green: `npm run build` (`nuxt build`) ✨.
- **Reused euler-lite's CoW stack:** `~/entities/cowswap` (`fetchCowSwapOrderStatus`, `isCowSwapTerminalOrderStatus`,
  `getCowSwapOrderExplorerUrl`, poll constants) for the live status path; did NOT reuse
  `useCowSwapExecutionCore`/`executeCowSwapTransactionPlan` (those build Euler-**position** plans, not a plain ERC-20
  sell). Ticket: `build/tickets/frontend/FE-04-exit-cow-book.md`. Critics ran clean (spec-fidelity PASS — §6.2/§6.4
  faithful, §17 honored, senior queue correctly excluded; reference-verifier — all bindings resolve incl.
  `useSignTypedData`@`@wagmi/vue` + viem `domainSeparator`; frontend-binding — back-pressure PASS, every demanded
  surface present); cold-build returned **zero load-bearing guesses**.
- **Seams for later FE writes:** (1) `useCowExit` is the CoW-order template — read CoW wiring live off the contract
  that owns it, never hard-code GPv2 addresses; (2) `isCowLive` (env `NUXT_PUBLIC_COW_LIVE`, default false) is the
  **mainnet/spoof toggle** — the `approve` + EIP-712 sign are real on the fork, only the solver POST/poll spoofs; reuse
  this pattern for any future off-chain-solver leg; (3) the §6.4 exit is **off-chain CoW + the treasury 8-B14
  buy-and-burn**, NOT a contract exit write — the only on-chain user write is `szipUsd.approve(vaultRelayer)`.

### Done earlier — FE-03 (2026-06-10)
On-chain position / NAV view, committed to the layer repo (`resi-labs-ai`, commit `b66c8be`):
`composables/useZipPosition.ts` (read-only proxy-client reads of `szipUsd.balanceOf` + `zipUsd.balanceOf` +
`navExit`/`navEntry`; returns a raw-bigint `ZipPosition`; derives szipUSD $ value `= szipBal*navExit/1e18`, total $,
and the `1e36/navEntry` "szipUSD per $1 in" hint; **only `navEntry` is try/caught** — it reverts on stale legs,
`navExit` never reverts) + `components/zipcode/ZcPositionPanel.vue` (brand-card; szipUSD + zipUSD balances, szipUSD $
value via `navExit`, total position $, "Redeemable ≈ $X / szipUSD" + "≈ N szipUSD / $1 in"/"issuance paused"; not-
connected/loading/zero states; props `{user, refreshKey}`, watches `user`/`refreshKey`/`client`, no `defineExpose`) +
`pages/lender/portfolio.vue` (dropped the FE-02 adhoc `refreshOnChainBalances` block; mounts the panel, bumps
`positionRefreshKey` on deposit `@success`). Gate green: `npm run build` (`nuxt build`) ok. Ticket:
`build/tickets/frontend/FE-03-position-nav-view.md`. Critics ran clean (spec-fidelity: no drift, §7/§12 faithful, §17
honored, no inbound obligation; reference-verifier: all bindings resolve, live `navExit`≈`107.01e18`/`navEntry`≈
`107.27e18`, `navPerShare` confirmed absent; frontend-binding: back-pressure PASSES, all views present, correct §7
bracket-read choice); cold-build returned **zero load-bearing guesses**. **Seam for later FE reads:** value a *held*
szipUSD position at `navExit` (redemption, never reverts); `navEntry` (issuance) reverts on stale legs and MUST be
caught. The FE-03 read composable shape (raw-bigint aggregator + component-side `formatUnits`) is the read-view
template FE-06's solvency dashboard reuses.

### Done earlier — FE-02 (2026-06-10)
Supply/zap real-write path, committed to the layer repo (`resi-labs-ai`, commit `933c144`):
`composables/useZipTx.ts` (the shared **1.3× gas-buffer write spine** — `gas = max(ceil(est*1.3), est+150k)` —
that FE-04/FE-05 reuse; estimates off the proxy client, sends via `@wagmi/vue` `sendTransactionAsync`, awaits the
receipt) + `composables/useZipDeposit.ts` (supply reads via the proxy client + `approve`/`zap`/`deposit` via
`useZipTx`) + wired `components/zipcode/ZcDepositModal.vue` (mode toggle zap-default/hold, debounced
`previewZap`/`previewDeposit`, USDC balance+max, `gate()==0` un-wired guard, two-phase approve→action loading,
szipUSD-delta surfacing, toasts) + `pages/lender/portfolio.vue` (mock `handleDeposit` dropped; on `@success`
re-reads on-chain USDC + szipUSD). Gate green: `npm run build` (`nuxt build`) ok. Ticket:
`build/tickets/frontend/FE-02-supply-zap-deposit.md`. **EVC 1.3× gas-buffer obligation DISCHARGED.** Critics ran
clean (spec-fidelity: no drift/§17 honored; reference-verifier: all bindings resolve, `useToast` needs an explicit
import; frontend-binding: no back-pressure, all module surface present); cold-build returned **zero load-bearing
guesses**. **Seam for later FE writes:** every Zipcode write goes through `useZipTx` — import addresses/ABIs raw
from `ZIPCODE_CONTRACTS[key]`, never re-implement the gas buffer.

### Done earlier — FE-01 (2026-06-10)
Zipcode address book + typed ABI module, committed to the layer repo (`resi-labs-ai`, commit `6ec85b1`):
`lib/zipcode/{abi/*.ts (46 deduped ABIs), generated/registry.ts, contracts.ts}` + `scripts/gen-zipcode-abis.mjs`
(regenerates from `build/anvil/abi/index.json` after a redeploy) + `scripts/verify-zipcode-binding.ts`. Exports
`ZIPCODE_CONTRACTS` (every one of the 52 index.json contracts → `{address: Address, abi: as-const}`) +
`getZipcodeContract(key, client?)` + `ZipcodeContractKey`. Gate green: `npm run build` ok; `npx tsx
scripts/verify-zipcode-binding.ts` off the fork → `szipUsd.name()` = `"Zipcode Junior Vault Share"`,
`navOracle.navEntry()` = `107265000000000000000`. Ticket: `build/tickets/frontend/FE-01-zipcode-address-abi-module.md`.
**Seam for later FE tickets:** the FE-01 default client direct-reads `127.0.0.1:8545` (node/SSR only); browser
screens pass `useRpcClient().client`. Writes use `ZIPCODE_CONTRACTS[key]` raw + `encodeFunctionData`, not the
read getter.

---

## Backlog

### CRE (Go → wasip1) — spec §8
Numbering follows the spec's own CRE map (`claude-zipcode.md` §8.11) — the spec rules intent.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — *(was NEXT; deferred behind the FE↔anvil push the user prioritized 2026-06-10 — head of the CRE track when released)* |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family). **SEC-01 constraint: must not co-locate two same-lien `seedPrice` writes (origination+draw / draw+draw) in one block — the registry monotonic guard reverts the second. See open obligations.** | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call. *(2026-06-12: `settleEpoch` is now ON-DEMAND — the 30-day epoch gate was removed — so this can be event-driven off the queue's `RedemptionSettled` event rather than a fixed cron: settle → if backlog remains, sequence another REDEEM→REPAY. See `build/wires/9-ZipRedemptionQueue.md`.)* **Scope: `build/tickets/cre/CRE-02-redemption-settle.md`.** | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipReservoirLpOracle` — and the xALPHA-APR feed (the 8x-02 receiver is built; the Go producer remains) | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔sidecar rotation; regime/split/cap policy). *(2026-06-12 design inputs: (a) the DurationFreeze main↔sidecar rotation needs an LP **unstake→commit** sequence — the freeze can't move staked LP; see the `TODO(freeze-lp)` in `DurationFreezeModule.sol` + `build/wires/DurationFreezeModule.md`; (b) the 8-B14 CoW **buy-burn bid-automation loop** — size the resting bid to `clamp(freeReservoir − harvestReserve, 0, buybackCap)`, repost on drift/`RedemptionSettled`/fill, optionally as **staggered clones** for laddered depth; see `build/CoW-exit.md`.)* | §8.7 |
| CRE-06 | **CROSS-CUTTING — exit-vs-harvest capital allocation (NOT owned by a single ticket above).** One reservoir funds two competing claims: the CoW exit bid (CRE-02 REDEEM→REPAY→CoW) and the 8-B5 strike borrow (CRE-05 harvest working capital). A harvest borrow raises `U`, which shrinks redeemable liquidity AND raises the freeze floor — in real time. The CRE must arbitrate this split; it is currently unencoded discretion. Scope this policy explicitly when CRE-02/04/05 are written. See `build/CoW-exit.md` (structural coupling). | §8.5 / §8.7 |

### Frontend ↔ anvil (Vue/viem, in the `zipcode-finance-euler` LAYER over a read-only `euler-lite` base)
**Goal: make the team's skinned borrower/lender app interactive against the live local protocol — "fuck around
before mainnet."** The deploy-gating that blocked these is LIFTED: item-10 fork-executed the full stack on anvil, so
every "TODO post-deploy" slot is now fillable from `build/anvil/contract-map.md` (addresses) + `build/anvil/abi/`
(ABIs). The layer's `Zc*` screens are currently a **clickable mockup** fed by mock `lib/zipcode/store.ts` + simulated
Plaid — the work is to swap that data path for real reads/writes against the anvil contracts. Build one at a time,
foundation → leaf. Addresses below are the anvil board (`contract-map.md`); ABIs are `build/anvil/abi/<Name>.json`.

| Item | What | Binds to (anvil address + ABI) | Spec § |
|---|---|---|---|
| FE-00 | Boot the layer on anvil: populate the euler-lite base, `.env` repoint (`RPC_URL_8453`→`127.0.0.1:8545`, onchain vault source, local labels), wallet→8453 | euler-lite data layer (config-only) + `contract-map.md` | §5 — **DONE 2026-06-10** |
| FE-01 | Zipcode **address book + typed ABI module** in the layer (the shared dep every Zipcode composable imports; fills the INFLOW-06 "post-deploy slots" with real anvil addresses) | `abi/index.json` resolver + `contract-map.md` | §5 — **DONE 2026-06-10** |
| FE-02 | Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` (approve→`zap`/`deposit`, `previewZap`/`previewDeposit`); ship the shared **1.3× gas-buffer tx helper** (EVC headroom — see Open obligations) all writes reuse | `ZipDepositModule` `0x6ecc…` + `ESynth`(zipUSD) `0xC5bd…` + `SzipUSD` `0x33aD…` | §4.5 (= INFLOW-06, realized) — **NEXT** |
| FE-03 | Position / NAV view: szipUSD + zipUSD balances + **$ value via `navExit`** (held = redemption price; `navEntry` for the entry hint only, caught; NOT `navPerShare` — absent); the lender portfolio screen | `SzipNavOracle` `0x0C3E…` + `SzipUSD` `0x33aD…` + zipUSD `0xC5bd…` | §7 / §12 — **DONE 2026-06-10** |
| FE-04 | szipUSD junior exit via the **CoW book** (rest a sell order + the §6.4 status track); wire `ZcWithdrawModal` | `SzipBuyBurnModule` `0x1288…` (CoW wiring + treasury bid) + `SzipUSD` `0x33aD…` (`approve(vaultRelayer)`) + `SzipNavOracle` `0x0C3E…` | §6.2 / §6.4 — **DONE 2026-06-11** |
| FE-05 | Borrower flow: line state + permissionless repay; wire `ZcDrawModal` / `ZcRepayModal` (CRE drives origination per §17 — UI reads line state + repays) | `EulerVenueAdapter` `0x87dC…` + `ZipcodeController` `0x3602…` | §4 / §15 — **DONE 2026-06-11** |
| FE-06 | **Solvency dashboard** (§12 metrics — NAV, zipUSD supply + peg, szipUSD NAV/share + trailing APR, utilization / free liquidity, insurance coverage) via **direct on-chain view reads** (no subgraph for MVP); wire `ZcStatCard` grid / `ZcVaultAllocationTable` | `SzipNavOracle`, zipUSD, reservoir `IEVault` `0x1aFc…`, warehouse Safe `0xe028…` | §12 — **DONE 2026-06-11** |
| FE-07 | **Euler-native vault dashboard**: surface the real reservoir EVK market + senior EE pool through euler-lite's OWN lend/borrow/earn pages (largely FE-00 config + the local labels file — this is the "show euler data / particular vaults" surface) | reservoir `IEVault` `0x1aFc…` + EE pool `EulerEarn` `0x1a7A…` | §4.7 — **DONE 2026-06-11** |

INFLOW-06 (`build/tickets/frontend/INFLOW-06-deposit-module.md`) is the **FE-02 draft** — its "address config depends
on item 10 / reads a placeholder" notes are now discharged (use the anvil board); its `abis/`/composable files live in
the **layer**, not in euler-lite.

### Subgraph — deferred (FE track runs without it)
Still gated on item-10 freezing the §9 event ABIs; the MVP runs on **direct on-chain view
reads** (FE-06), not a subgraph. Author a subgraph spec later if/when aggregated history is needed; do not block the FE
track on it.

---

## Open obligations / seams

- **RUNBOOK (raised 2026-06-15, SEC-03) — durable admin MUST `acceptAdminRole` post-deploy to finalize the CCT
  registry-admin handoff (both chains).** `DeploySzAlphaBridge` hands the `TokenAdminRegistry` administrator to the
  durable authority via a 2-step `transferAdminRole` (964 → `ccipAdmin`, Base → `timelock`) but cannot accept on
  its behalf mid-broadcast. So after `deploy964`/`deployBase`, the durable authority MUST call
  `ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)` to become the registry `administrator`. Until it
  does, the ephemeral deploy Script remains a live registry admin — the one residual interruption window; accept
  promptly and verify `getTokenConfig(token).administrator == <durable>`. Documented in both deploy functions'
  NatDoc + `build/wires/8x-01-szALPHA-bridge.md` (Item-10 deploy facts step 4b). Not a contract change owed; an
  operational deploy-runbook step.

- **TODO (raised 2026-06-15, SEC-01) — CRE-01 must not co-locate two same-lien `seedPrice` writes in one block.**
  The oracle monotonic guard (SEC-01) lives in `ZipcodeOracleRegistry._writePrice` and rejects a write whose `ts` is
  not strictly newer than the cached mark. The controller re-anchors via `seedPrice` at origination (`:199`) AND draw
  (`:223`), and `seedPrice` stamps `block.timestamp` (no incoming CRE ts), so an origination+draw (or draw+draw) of the
  **same lien in one block** now reverts `StaleReport()` — intended fail-closed (the H1 seed-clobber). Benign in prod
  (origination/draw are separate Keystone reports in separate blocks), but **CRE-01 must ensure same-lien seeds are not
  co-located in one block** (defer the second one block, or — future hardening — give the seed path a real ts instead
  of `block.timestamp`). Not a contract change owed; an operational constraint on the CRE producer.

- **TODO (raised 2026-06-15) — concurrent-line ceiling: the per-line-EVK-vault model caps open lines at ~29 per
  EulerEarn pool. DESIGN obligation, surfaced while ticketing SEC-06 (H2).** EulerEarn's supply queue AND withdraw
  queue are each hard-capped at `MAX_QUEUE_LENGTH = 30` (`reference/euler-earn/src/libraries/ConstantsLib.sol:17`;
  withdraw-queue cap enforced at `EulerEarn.sol:785`). `openLine` enables one EVK borrow vault per line (one queue
  slot), so a single EE pool structurally supports **≤ ~29 concurrent open lines**. **SEC-06 does NOT raise this** —
  it only reclaims slots from *closed* lines (correct + necessary for churn, but the kill-list framed H2 as
  low-concurrency/lines-close-faster-than-open). If the product needs hundreds of **concurrent** lines (e.g. ~300),
  decide before scaling: **(a)** shard lines across multiple EE pools (~10+); **(b)** change topology to a shared
  borrow vault with internal per-line sub-accounting (one slot, many lines); **(c)** confirm whether the supply-queue
  *append* in `openLine` is even needed (`reallocate` only requires `config[id].cap != 0`, not supply-queue
  membership) — but (c) alone does NOT help because the **withdraw-queue** cap still bounds concurrent enabled
  markets. Not a kill-list FIX; a topology decision owed before high-line-count scaling. See SEC-06 ticket.

- **TODO (raised 2026-06-12) — `DurationFreezeModule` is INCOMPLETE; rethink its premise + accounting at rebuild.**
  Two independent problems, the first deeper than the second:
  1. **Threat model may be obviated.** The freeze keeps utilization-committed equity (sidecar floor = U × gross)
     unreachable by a ragequit/window exit draining the main Safe. But all legitimate Loot is custodied by the
     `ExitGate`, which only mints/burns and NEVER ragequits (depositors hold only szipUSD — no rq-to-extract-LP
     path), and exits are CoW-only (sell the share; `burnFor` pays nothing out — no basket extraction). So the
     liquidity drain the freeze defends against is already closed by the exit topology. Re-derive what it actually
     protects against before extending it.
  2. **Can't act on the dominant asset.** Most TVL is the zipUSD/xALPHA ICHI LP, STAKED in the Hydrex gauge to earn
     oHYDX. Staked LP is not a transferable ERC20 and `commit`/`release` move by plain transfer, so the freeze can
     only touch the (near-zero, oscillating) UNSTAKED LP — the floor is physically unreachable when staked-LP value
     > (1−U) × gross. Unstaking lives in `LpStrategyModule` (8-B6) on the main Safe; the freeze has no unstake path
     and the sidecar can't restake. NAV is fine (the oracle already counts the LP per-Safe incl. gauge stakes) —
     the gap is purely actuation/accounting.
  Interim code (2026-06-12): `ichiVault` added as a 6th whitelisted/movable asset in `DurationFreezeModule.sol`
  (leak-safe, with a loud `TODO(freeze-lp)`) — a placeholder that forces the decision, NOT a fix. Full context:
  `build/wires/DurationFreezeModule.md` (OPEN gotcha). Decide at rebuild: (a) CRE unstakes via 8-B6 then commits;
  (b) give the freeze an unstake leg; (c) let the sidecar stake; and/or (d) retire/redesign the module given (1).

- **TODO (raised 2026-06-12) — `ZipRedemptionQueue` pro-rata machinery is DORMANT under single-requester; simplify
  or keep as optionality.** The 30-day epoch *time gate* was removed 2026-06-12 (`EPOCH_DURATION`/`lastEpochTime`/
  `EpochNotElapsed` deleted; `settleEpoch` is now on-demand, controller-only; the `epoch` counter was renamed
  `settleCount`, event `EpochSettled` → `RedemptionSettled`). What remains: the `era` / `cumRemaining` / per-requester
  (`sharesAt`/`cumAt`/`eraAt`) carry-forward engine. It is **correct but degenerate** with a single requester (C4
  gates `requestRedeem` to the rq Safe): every fill ratio is trivially 100% to that one requester, so `sharesAt[rq]`
  always equals `totalPending` and the ratio math collapses. `era` only bumps on a full drain (its sole job is the
  zero-safe reset of `cumRemaining`, avoiding a div-by-zero); `settleCount` is cosmetic (read by nothing on-chain,
  only emitted). **At rebuild:** either collapse the whole apparatus to `totalPending` + a single `claimableAssets`
  accumulator (far less code), OR keep it as dormant optionality for reopening `requestRedeem` to many external
  redeemers later — that reopening is the only world where the pro-rata dimension becomes load-bearing again. See
  `build/wires/9-ZipRedemptionQueue.md` (gate-removal gotcha).

- **TODO (raised 2026-06-13) — `SzipNavOracle` is NOT yet wired to OUR zipUSD/xALPHA LP; the junior NAV does not
  price our pool. Promoted here from `build/anvil/zipusd-xalpha-pool.md` (was only tracked in that fork-setup doc).**
  A real single-sided-zipUSD ICHI YieldIQ vault over the zipUSD/xALPHA pool now **exists on the fork**
  (`0x4731d24b…`, 8-B6/DEC-03), but `SzipNavOracle.ichiVault` still points at the **WETH/USDC ICHI stand-in**
  (`0x07e72E46…`), so `grossBasketValue()`'s LP leg values the wrong pool. The LP code path itself (read ICHI +
  Hydrex gauge shares across both Safes, pro-rata `getTotalAmounts()`, value reserves via `_legPriceOfToken`) is
  built but **only ever exercised by the demo vAMM fork** (`SzipNavOracleDemoVAMM`, HYDX/USDC — showcase seam below),
  never against our real pool. **Remaining steps** (mirror `zipusd-xalpha-pool.md` lines 86-92): (a) create + stake a
  Hydrex gauge for the LP share (farms oHYDX); (b) deploy an escrow collateral EVK vault over `0x4731d24b…` + add it
  to the reservoir borrow market; (c) `setLpPosition(0x4731d24b…, <gauge>)` so the junior basket prices OUR LP;
  (d) confirm the `LP_MARK`(7)→`SzipReservoirLpOracle` feed flows (= CRE-03); (e) verify `_legPriceOfToken` reserve
  valuation (`zipUSD`→`1e18`, `xAlpha`→`_xAlphaUSD()`) is non-manipulable for the real pool — spot `getTotalAmounts()`
  reserves are JIT/flash-skewable, so confirm the NAV-per-share TWAP bracket defends the LP leg or harden the read.
  NB SP-04/SP-06 fork trap: while `ichiVault` points at the WETH/USDC vault, ANY of that LP in a Safe reverts
  `UnknownLpToken(WETH)` and bricks all NAV reads. Cross-refs: the DurationFreezeModule staked-LP gap (below) and the
  showcase note both hinge on this same LP leg.

- **FE-00 DONE (2026-06-10) — the layer boots + reads the fork.** Committed to the layer repo (`resi-labs-ai`,
  commit `1ace24b`): `.env.example` (anvil dev config), `public/labels/8453/{products,earn-vaults,entities}.json`
  (local euler-labels base), `nuxt.config.ts` EMFILE watch-guards. Gate green: `npm run build` ok; `GET /`→200;
  `/api/rpc/8453` `eth_chainId`→`0x2105`, `eth_blockNumber`→`47096192` (the fork block, not live Base);
  `/api/labels/products.json?chainId=8453`→3 reservoir vaults; `earn-vaults.json`→senior pool. Ticket:
  `build/tickets/frontend/FE-00-layer-anvil-foundation.md`. Carry-forward seams for later FE tickets:
    - **`node .output/server/index.mjs` does NOT auto-load `.env`** (only `nuxt dev`/`build` do). Export the env
      into BOTH the build and serve process env, and pin `HOST=127.0.0.1 PORT=3000` so the labels proxy's
      self-origin fetch (`http://127.0.0.1:3000/labels/...`) resolves. A backgrounded `set -a; . ./.env`
      compound can fail to propagate to the child — confirm the vars are in the node process.
    - **Interactive wallet-connect is config-gated on a real `NUXT_PUBLIC_APP_KIT_PROJECT_ID`** (Reown). Empty is
      non-fatal (only a `console.warn`), and the RPC binding the wallet uses is proven (chainId `0x2105`), but a
      headless gate can't click-connect — FE tickets needing a live signer must supply a project id.
    - **onchain vault source keeps a `vaultTypeAdapter:'subgraph'`** that 404s (no `SUBGRAPH_URI_8453`) and
      degrades to classifying verified addresses as `evk` — correct, but don't be surprised by the 404 in logs.
- **Frontend deploy-gating LIFTED → anvil-grounded (2026-06-10).** The whole FE track was written "gated on item-10 /
  post-mainnet"; item-10 fork-executed the full stack on a live anvil (Base fork @47096000, chainId 8453,
  `127.0.0.1:8545`). So the FE tickets now bind to **`build/anvil/contract-map.md`** (addresses) +
  **`build/anvil/abi/`** (ABIs, with `index.json` as the address→ABI resolver), not to a placeholder. **Build target =
  the `frontend/zipcode-finance-euler` LAYER** (the skinned app) **over a read-only `euler-lite` base** — the team's
  design keeps euler-lite pristine and overrides from the layer (`extends: ['./euler-lite']`), so new Zipcode
  `abis/`/composables/address-book go in the LAYER, NOT inside euler-lite (this supersedes INFLOW-06's
  "`reference/euler-lite/abis/…`" placement). euler-lite's data layer is config-only (env-driven, nothing hardwired to
  mainnet), so its native Euler reads work against the fork with just an RPC override.
- **Standing FE requirement — EVC gas buffer. DISCHARGED 2026-06-10 (FE-02).** Every EVC-touching tx
  (`ZipDepositModule.deposit`/`zap`, `RecycleModule.recycle`, warehouse SUPPLY/REDEEM, `EulerVenueAdapter.fund`/`draw`,
  the reservoir loop) must multiply `eth_estimateGas` by **~1.3× (or +150k)** before signing, baked into the shared
  tx-send helper, not per-call. **Shipped:** `frontend/zipcode-finance-euler/composables/useZipTx.ts` —
  `gas = max(ceil(est*1.3), est+150_000)`, applied once in `sendZipTx`; every later Zipcode write (FE-04/FE-05) MUST
  route through it (do not re-implement the buffer). No contract change removes this.
- **Showcase auto-compounder layer (`wires/SHOWCASE-VAMM.md`, SP-18).** BUILT + deployed: demo NAV-oracle + LP-module
  forks that price/stake a live vAMM HYDX/USDC pair, enabled on the existing engine Safe (the real zipUSD pool doesn't
  exist until post-Hydrex). FE: the auto-compounder dashboard reads the **demo** oracle (`SzipNavOracleDemoVAMM`); surface
  its LP figures as **showcase**, not production NAV. The prod oracle prices issuance/exit and is untouched.

- **item-10 deploy/wire FORK-EXECUTED 2026-06-10 (green, anvil Base-fork @ 47096000).** `script/DeployLocal.s.sol`
  (a `DeployZipcode` subclass) provisions the six `(T)` stand-ins (ZeroIRM, xALPHA MockERC20, MockEulerEarn ×2, + the
  live HYDX ICHI vault `0x07e7…`/gauge `0xAC39…` pair) and runs P0..P9 in one team-broadcast. All 8 seams hold; every
  receiver + engine-module proxy + the warehouse adapter is owned by the Timelock; the warehouse Roles/Safe by godOwner.
  **Four latent deploy-blocking bugs in the orchestrator were found + fixed** (the cost of "never executed"):
    1. `CreditWarehouseDeployer` left the adapter (a CRE ReceiverTemplate) owned by the throwaway deployer instance →
       P9's seal+transfer reverted. Fixed: new `receiverAdmin` param hands the adapter to the item-10 broadcaster.
    2. P9 re-`transferOwnership(tl)`'d engine modules already owned by `tl` (setUp `_transferOwnership(owner_=tl)`) →
       revert. Fixed: removed the redundant P9 module loop.
    3. P4 built `ZipRedemptionQueue` with `address(0)` zipUSD (the queue ctor zero-checks + reads `.decimals()`) →
       revert. Fixed: deploy the zipUSD synth at the top of P4 (EVC-only dep) before the queue.
    4. P7 built `LienXAlphaEscrow` with `address(0)` coordinator (ctor zero-checks it) → revert. Fixed: deploy the
       coordinator first (its ctor needs no escrow), then the escrow with the real coordinator.
  Also P5 needs an initial `LP_MARK` seeded before the reservoir `setLTV` (EVK calls `getQuote`); in prod that is a CRE
  push — the local harness seeds it via the owner→forwarder trick (`DeployLocal._seedLpMark`). `DeployZipcode.t.sol`
  3 skips remain.
- **REAL-EE deploy + smoke suite (2026-06-10, supersedes the mock-EE deploy above).** `DeployLocal` now creates a REAL
  EulerEarn pool off the live factory + the full curator runbook (`setFeeRecipient`, `submitCap`/`acceptCap` for the
  base USDC market + reservoir borrow vault — both pass the live "EVK Factory Perspective" — `setSupplyQueue`,
  `setCurator(adapter)`), a REAL no-borrow USDC EVault as the supply-queue head, and wires `ExitGate.windowController`
  (a P3 fix — was `address(0)`, blocking the buy-burn `burnFor` exit). This UNBLOCKS full origination + the
  utilization→freeze identity (`utilization()` now reads real `maxWithdraw`). Live real-contract anvil running @
  `127.0.0.1:8545`. Address board + 17 grounded smoke-path specs authored in `build/anvil/` (`contract-map.md`,
  `README.md`, `smoke-path-01..17.md`) — the next window executes them one at a time against the live node. The only
  remaining stand-ins are xALPHA (cross-chain, unbridged) + ZeroIRM (real 0%-rate); collateral mocked per §17.
- **FE-01 finding — `SzipNavOracle` has no `navPerShare()`** (logged 2026-06-10). The deployed oracle
  (`build/anvil/abi/SzipNavOracle.json`) exposes **`navEntry()`** (issuance price), **`navExit()`** (redemption
  price), **`spotNavPerShare()`**, **`twapNavPerShare()`** — all `view returns (uint256)`, 18-dp. There is NO
  `navPerShare()` (reverts). The spec §7 prose / INFLOW-06 use `navPerShare` as shorthand; the **contract wins**
  (harness §1). This is a **rename, not a missing surface — no contract change owed**: FE-03 (position/NAV) +
  any szipUSD-valuing screen must read `navEntry`/`navExit` (or the spot/twap views), not `navPerShare`. Live
  `navEntry()` ≈ `1.07e20`.
- **FE-04 finding — the szipUSD junior exit is NOT a contract write; the senior queue is treasury-only** (logged
  2026-06-11). The original FE-04 row demanded `ExitGate.requestExit`/`cancelExit` + a `ZipRedemptionQueue` cooldown
  panel — **all wrong** (the contract wins, harness §1; spec §6.4 confirms):
    - `ExitGate` has **no** `requestExit`/`cancelExit`/`processWindow` — they were **retired by design** (the forfeiting
      on-chain queue, `ExitGate.sol:26-28`). The junior exit is an **off-chain CoW sell order**; the only on-chain user
      write is `szipUsd.approve(vaultRelayer)`. `ExitGate.burnFor` is `onlyWindowController` (CRE keeper), not the UI.
    - `ZipRedemptionQueue` is the **SENIOR zipUSD→USDC treasury off-ramp** (`requestRedeem` is `onlyRedeemController` =
      the rq Safe driven by `OffRampModule`; `requester == owner == rqSafe`). A retail lender **cannot** enter it or
      claim from it. `ZipRedemptionQueue.sol:14-17` + `OffRampModule.sol:33-40`: *"NOT the junior Exit Gate… Never
      conflate."* The FE has **no senior-queue surface** and **no szipUSD cooldown** (the resting CoW order is the queue).
    - **No back-pressure obligation owed** — every surface the real (CoW) design needs EXISTS (`SzipBuyBurnModule` CoW
      wiring + `quoteMaxPrice`/`dBps`, `SzipUSD.approve`, `navExit`). The "missing" surfaces were never owed; they were
      retired. This was a **ticket error**, fixed in the FE-04 ticket; **no `claude-zipcode.md` change** (§6.4 already
      correct).
- **FE-05 finding — draw is CRE-only; repay is the native EVK `repay`, permissionless; the borrower ≠ the wallet**
  (logged 2026-06-11). The original FE-05 row implied a borrower-side draw/repay path — the contract wins (harness §1):
    - **No borrower draw write exists.** `EulerVenueAdapter.{openLine,setLineLimits,fund,draw,closeLine,liquidate}` are
      ALL `onlyController` (`EulerVenueAdapter.sol:83` modifier; `draw` `:298` also pins receiver = the immutable
      Erebor, `:302`); `liquidate` additionally `revert NotImplemented` (§4.4e). `ZipcodeController`'s only write entry
      is `onReport` (Keystone-forwarder + workflow-identity gated) — no public originate/draw. So `ZcDrawModal` is
      **read-only**; the draw is CRE-originated (§17).
    - **Repay is NOT a Zipcode method — it is the native EVK `IEVault(lineRef).repay(amount, borrowAccount)`**, ungated
      (`openLine` hooks only `OP_BORROW | OP_LIQUIDATE`, **never** `OP_REPAY`, `EulerVenueAdapter.sol:220`). Approve is
      a **direct** `usdc.approve(lineRef, amount)` to the line vault (NOT Permit2 — `ReservoirLoopModule.repay:251`).
      Any wallet may repay (credits `borrowAccount`, no controller-enablement/operator bit) — the §4.4e permissionless
      property. `full`→`type(uint256).max` (EVK clamps; a finite over-repay reverts `E_RepayTooMuch`).
    - **No back-pressure obligation owed** — every read (`getLine`/`observeDebt`/`getLien` + the `LienOriginated`/
      `LienStatusUpdated`/`LienReleased` events) and the EVK `repay`/`debtOf`/`asset` all exist. The implied borrower
      "draw" write was never owed; it is CRE-driven by design. **No `claude-zipcode.md` change** (§4/§9/§15 already
      correct). Ticket-precision note: `getLine` returns a **named-tuple struct** (viem → object, read by field name),
      not a positional tuple — the ticket wording was corrected.
    - **New FE seam:** `useZipTx.sendRawZipTx({to,abi,functionName,args})` writes to a **runtime/non-registry address**
      (per-line vaults) reusing the shared 1.3× buffer — the spine for any dynamically-discovered-contract write.
- **FE-07 Finding A — contract obligation owed to the contract track (NOT FE / NOT a frontend back-pressure)**
  (logged 2026-06-11). The reservoir **borrow vault's `governorAdmin` is never transferred to the Timelock** — it stays
  the throwaway `ReservoirMarketDeployer` instance (`0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa` on the current fork).
  `ReservoirMarketDeployer.deploy` (`contracts/script/ReservoirMarketDeployer.sol`) transfers only the **router**
  governance (`EulerRouter(router).transferGovernance(p.governor)`, `:88`); the borrow vault is created via
  `factory.createProxy` (deployer = governor at birth, `:77`) and never gets `setGovernorAdmin(p.governor)`. The comment
  at `:75` ("Governor RETAINED so the Timelock can tune LTV/caps") is **wrong for the borrow vault** — the Timelock
  cannot govern it; the deployer can. **Fix owed:** add `IEVault(borrowVault).setGovernorAdmin(p.governor)` in
  `ReservoirMarketDeployer.deploy` (alongside the router transfer) so the borrow vault is Timelock-governed (§17
  Timelock-settable-not-frozen). Once fixed, the live `governorAdmin` becomes `0x89ae…` (already in FE-07's
  `entities.json`) and the deployer entry can be dropped. **FE interim (shipped):** FE-07 declares the live deployer
  address so the reservoir market verifies in the UI today; `0x77C2Cb…` is nonce-derived, so re-read `governorAdmin()`
  and update `entities.json` after any redeploy that moves it.
- **CRE report ABI seam.** Every CRE report payload must `abi.decode` to the §4.4 layout the filed
  `ZipcodeController` / `ZipcodeOracleRegistry` expect (reportTypes 1/2/4/5/6 → controller, 3 → registry).
- **Subgraph blocked** until item-10 freezes the §9 event signatures.

---

## Deletion triggers (when forward artifacts die)

- **8-B11 + 8-B12 land** (CRE-05 strategy robot + monitoring) → `pending-docs/{monitoring,hydrex,auto-compounder}.md`
  die, folded into those builds.
- **Real Proof / SPV / insurance integration lands** (collateral un-mocked) → `pending-docs/spv-lien-proof.md` dies.
- **Built-contract narrative still in `claude-zipcode.md` §6/§7/§11** can be pruned to `wires/` pointers later
  (only §4 has been pruned so far; left in place for now to avoid disturbing the forward narrative around it).

---

## Done

The built, fork-tested on-chain contract stack (32 product contracts + 6 scripts + 30 interfaces) is
truth-sourced and indexed in **`build/wires/COVERAGE.md`** — not re-narrated here.
