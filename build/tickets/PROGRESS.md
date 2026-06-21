# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**NEXT = reviewer picks** among the deferred candidates below — CTR-16 is DONE + COMMITTED (`4378f93`); CTR-15
follow-up (b) is DONE (notes immediately under). One item moves at a time; the reviewer selects the next forward edge.

Deferred candidates: **SEAM-1** (CRE-03 material-move http trigger, own-later); the **FE track**; **CTR-14** (N
junior Safes vs the single-requester queue — CRE-02c is unaffected, it writes only REDEEM/REPAY, no escrow leg).
The CRE redemption (R)/(K) stack is COMPLETE — CRE-02 (K) + 02b + 02c + 04. (CTR-15 follow-up (b) DONE — note below.)

- **CTR-15 follow-up (b) DONE (2026-06-20) — `FarmUtilityBorrowGuard` "borrow vault IS resting USDC" accuracy fix
  (docs/comments only, ZERO behavior change).** The deferred CTR-15 follow-up: the rename left an inverted factual
  claim. **Truth (code wins):** the resting USDC lives in the no-borrow `usdcReservoir`; the farm utility borrow
  vault holds **≈0 at rest** and is JIT-funded from the reservoir via `EulerVenueAdapter.fundFarmUtility` /
  re-absorbed via `defundFarmUtility` (the adapter comment `:615-617` calls the "combined" always-funded topology
  **rejected** — CTR-07). So "the borrow vault IS the warehouse's resting USDC / USDC Resting Vault" is the
  old/rejected design. Verified directly against `EulerVenueAdapter.sol` (no critic fan-out — own-docs accuracy,
  per [[do-not-delegate-judgment-on-own-docs]]). **Reviewer scoped this as a full SWEEP** of the inverted
  vault-IDENTITY claim (the *economic* substance — "borrows un-utilized depositor USDC, over-collateralized,
  repaid each loop" — was already correct and left intact). Fixed: `FarmUtilityBorrowGuard.sol` (the ticketed
  `:12-13` + the `juniorTrancheEngine` field `@notice`); `docs/wires/8-B5-FarmUtilityLoop.md` (Role para + the
  `borrowVault` cross-component bullet); `docs/wires/8-Bw-CreditWarehouse.md` (the row-333 supply-queue bullet);
  `docs/wires/WOOF-04.md` (the stale `farm-utility-borrow-vault-as-resting-vault` obligation → superseded-by-CTR-07);
  `build/pending-docs/auto-compounder.md` (6 spots — the borrow source named the "USDC Resting Vault"). **Double-check
  correction (caught on review):** the as-built EE config (`DeployLocal._configureEulerEarn:155-162`) caps BOTH
  `usdcReservoir` and the farm utility borrow vault as markets but sets the **supply queue to `[usdcReservoir]`
  ONLY** — the borrow vault is reallocate-reachable but deliberately OUT of the supply queue (so deposits never
  auto-route into a borrowable vault). My first pass wrongly wrote "both markets sit in the supply queue" in
  `8-Bw`/`WOOF-04`; corrected. An exhaustive repo-wide re-sweep (pass 1 only searched `src/`+`docs/wires/`+`build/`,
  missing `script/` + x-ray docs + `docs/wires/README.md`/`DeployZipcode.md`) then caught FIVE more stale spots:
  `DeployZipcode.s.sol:70` + `docs/wires/DeployZipcode.md:73` + `docs/wires/README.md:188` ("supply queue at the
  farm utility borrow vault" → resting `usdcReservoir`); `FarmUtilityMarketDeployer.sol:19`+`:76` and
  `FarmUtilityLoopModule.sol:18`+`:44` (committed source calling the borrow vault "the warehouse resting USDC
  vault" / borrowing "from the warehouse resting vault"); `x-ray/FarmUtilityBorrowGuard.md:11` (the x-ray doc's
  "is the warehouse's shared resting USDC"). All comment/doc-only.
  **Pass 3 (final, own sweep):** tightened one borderline x-ray header (`FarmUtilityLoopModule.md:6` "borrow against
  the warehouse's resting USDC" → "borrow OF … JIT-funded into the farm utility vault, collateralized by the LP").
  **VERIFIED (not asserted) clean:** `claude-zipcode.md` never carried the identity claim (its "resting" hits are
  all the CoW-book junior-exit order); the `freeReservoir = maxWithdraw` CRE reads (`cre/buyburn-bid`,
  `cre/warehouse/solver.go`) are the intentional row-29 carve-out (the idle store, correctly named);
  `CTR-02-SiloRegistry.md:83` (`30 − resting market − farm utility vault = 28`) corroborates the model (both are
  enabled withdraw-queue markets; only `usdcReservoir` is in the SUPPLY queue). Final repo-wide sweep CLEAN.
  **Gate:** `forge build` green (comment-only ⇒ no bytecode change; the CTR-16 run's `forge test` 1041/0/3 stands).
  **Doc-sync:** the owning wire doc (8-B5) + the propagated siblings are the fix itself; `claude-zipcode.md`
  unaffected (it never carried the identity claim). Not committed yet (this note's commit pending). NEXT: reviewer
  picks (SEAM-1 / FE track / CTR-14).

- **CTR-16 DONE (2026-06-20) — CRE receiver permissioning: author + per-receiver workflowName, shared workflowId
  pin dropped** (`build/tickets/contracts/CTR-16-receiver-name-permissioning.md`). Deploy-track only (NO
  receiver-contract code change — `ReceiverTemplate` already exposed `setExpectedWorkflowName`). The whole
  `ReceiverTemplate` fleet (controller, registry, coordinator, navOracle, lpOracle, rateOracle, **+ the per-silo
  WAM**) is now sealed with `setExpectedAuthor` + `setExpectedWorkflowName(<daemon name>)` and the `workflowId` pin is
  left `bytes32(0)`: author+name survive workflow redeploys (no fleet re-seal footgun) and the **per-receiver names**
  separate the SEPARATE daemons that share the one deploy wallet (the shared author cannot). **Folded-in hole closed:**
  `SiloDeployer` now takes transient WAM ownership, seals the per-silo WAM (author + `WORKFLOW_NAME_WAREHOUSE`), and
  `transferOwnership(timelock)` — uniform with silo-0's WAM (reviewer-directed; the dead `receiverAdmin` param was
  dropped); silos 2+ no longer ship the WAM forwarder-only. **Pre-gate reworked (K7):**
  `ZipcodeDeployAsserts.requireIdentityWired(address[] receivers, address registry)` asserts EACH sealed receiver
  (author≠0 AND name≠0) individually + the registry controller seed — the representative-id inference is gone, so a
  missing/empty per-receiver name now fails closed. **OUT (verified critic misreads):** `EulerVenueAdapter` is NOT a
  receiver (no `onReport`); `SzipBuyBurnModule`/`CloneReportReceiver` have NO `setExpectedWorkflowName` surface
  (permissioned at `setUp`) — unifying them onto author+name is a CONTRACT change = a separate ticket. **Gate green
  (my own run):** `forge build` + `forge test` = 1039 passed / 0 failed / 3 skipped (the 3 = pre-existing
  `DeployZipcode.t.sol` fork scaffolds, untouched). Files: `ZipcodeDeployAsserts.sol` + `DeployZipcode`/
  `JuniorTrancheDeployer`/`SiloDeployer`/`DeployLocal`/`DeployMainnet`/`DeployShowcaseVAMM` scripts + the
  `ZipcodeDeployIdentityGate`/`SiloDeployer`/`JuniorTrancheDeployer`/`DeployZipcode` tests. **NEW K5
  privilege-separation test:** two receivers, same author, different names — daemon-A's report accepted by receiver-A,
  rejected `InvalidWorkflowName` by receiver-B. **Doc-sync:** `docs/wires/DeployZipcode.md`, `claude-zipcode.md`
  §9 recipe + §13 inbound note, `contracts/.env.example`, `RUNBOOK-mainnet-deploy.md`. **RESOLVES the
  [[wam-permissioning-workflowid-vs-author]] memory note.** **COMMITTED `4378f93`** (gate re-run before commit:
  `forge build` + `forge test` = 1041 passed / 0 failed / 3 skipped — the +2 vs the 1039 above are the new
  `SiloRegistry` I-12/I-13 tests). ⚠️ **FLAG (unchanged, not mine):** the working tree still carries 4 untracked
  x-ray `.md`s from the prior x-ray sweep (`LienCollateralToken`/`LienTokenFactory`/`SeniorNavAggregator`/
  `SiloRegistry`, all citing commit `46fd0c1`) — left untracked, NOT part of CTR-16.

- **CRE-02c note (2026-06-20) — the cross-silo redemption solver (`onSolverTick` → per-silo `WarehouseAdminModule`,
  default-OFF), folded into `cre/warehouse`.** The multi-warehouse generalization of CRE-02b. **Off-chain Go only —
  NO contract changed** (no backward `wires/` edit owed). Committed at `cre/warehouse/` (4 files: `solver.go` +
  `solver_test.go` new, `funding.go` + `workflow.go` touched). **Both open forks RESOLVED at scoping:**
  **Fork A (split policy) → pro-rata by GATED free-liquidity** (M-N1): the REDEEM shortfall splits across pools
  proportional to each pool's `availP` (coverage-gated, reserve-netted, per-tick-clamped redeemable — NOT raw
  `maxWithdraw`), so a starved/undercovered pool has `availP=0` ⇒ weight 0 ⇒ **skipped automatically** (the invariant
  falls out of the weight). Utilization-balancing + curator-priority are own-later upgrades. **Fork B (topology) →
  option (i), one binary, per-silo loop:** a THIRD default-OFF `cron` handler in the SAME binary writes REDEEM/REPAY
  to EACH silo's own WAM — feasible because `ReceiverTemplate.onReport` gates on `msg.sender==forwarder` (shared by
  deploy) + `workflowId==expectedWorkflowId` (a per-WAM deploy-config slot), so ONE workflow id is accepted by all
  WAMs once each WAM's `expectedWorkflowId` is pinned to it (the OPERATIONAL precondition — the multi-silo echo of
  the same single-id pin that forced CRE-02b's fold-in). **The silo→WAM binding is a CONFIG SEAM, not back-pressure:**
  `SiloRegistry.Silo` has NO `warehouseAdminModule` field (the WAM is off-registry CRE plumbing), so the registry
  gives the live-silo set + per-silo `freeze` and `cfg.Warehouses[]` gives the writable WAM set, joined 1:1 by the
  unique `warehouseSafe` (a future on-chain-authoritative field is logged as a low-priority OPEN, not owed). **Each
  tick (stateless/idempotent):** read the ONE shared-queue shortfall (CRE-02b math); enumerate `allSiloIds()`/`getSilo`,
  skip `!active`; per pool `availP = covered(its freeze) ? clamp(maxWithdraw(safe) − HarvestReserve − SafetyBuffer,
  0, MaxRedeemPerTick) : 0`; **REPAY** greedily drains each Safe's already-held USDC (global-bounded ⇒ Σ ≤ shortfall);
  **REDEEM** splits the remainder pro-rata by `availP`, sized to shares via the same 4626 ratio (`redeemSharesP =
  floor(redeemAssetsP·balanceOf(safe)/convertToAssets(balanceOf(safe)))`, conservative). **K2 mutual exclusion:**
  enable exactly ONE of `fundingEnabled`/`solverEnabled` (both target the same shortfall — `onFundingTick` no-ops when
  the solver is on; one-line guard). **Harness loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier
  / cre-binding). **spec-fidelity = FAITHFUL** (no invention; REPAY-un-gated/REDEEM-gated is the spec-correct split;
  pro-rata-by-`availP` consistent with §6.3 contention + §8.2 reserve math; §17 honored; the (R)-routing + fold-in
  consistent with CRE-02b; the "config seam not back-pressure" framing is honest — every input exists). **cre-binding
  = byte-exact, NO mismatches** (REDEEM `(uint256 shares)` / REPAY `(address dest, uint256 amount)` match
  `WarehouseAdminModule._processReport` `:172/:176`; `redeemSharesP` resolves to 18-dp EE shares, floors doubly
  conservative ⇒ never over-redeems; `scaleUp=1e12` correct + read live; the N-receiver/one-workflow-id gate
  admissible; REPAY `dest==queue` guaranteed by the per-WAM `redemptionBox()==queue` filter). **reference-verifier =
  all 8 bindings resolve** (`SiloRegistry.allSiloIds/getSilo` + the 11-field struct ORDER verified; WAM getters;
  `DurationFreezeModule.covered()`; queue getters; `zipreport.WhRedeem/WhRepayReport`; the reused Go helpers; the
  3-handler `cre.Workflow` slice; the `bytes32[]`+tuple decode buildable under go-ethereum v1.17.2 — NET-NEW, no
  in-repo precedent). **Ticket tightened pre-cold-build** with pins P1–P7 (the load-bearing P1: decode `getSilo` by
  WORD OFFSET — the 11-field all-static tuple is an inline 352-byte blob, field i at word i, safe=1/eePool=2/freeze=7/
  active=10 — NO go-ethereum tuple reflection, no precedent to mimic; P2 `readSiloIds → [][32]byte`; P3 assert per-WAM
  `usdc()==usdc0` + `redemptionBox()==queue`; P4 file names; P5 the per-WAM-writeCap test idiom; P6 citation fixes;
  P7 no-regression). **Gate green (my own `-count=1` re-run, not just the cold-build's):** `cd cre/warehouse &&
  go build ./... && go vet ./... && GOOS=wasip1 GOARCH=wasm go build ./... && go test -count=1 ./...` — all pass (41
  RUN; the 7 new `Solver*` tests + the unchanged `Funding*`/`Sim*`/`ParseAddress` op tests). **Non-vacuous:** the
  test ENCODES its `getSilo` mock via the canonical 11-field abi tuple Pack (proving the word-offset decode against
  the real layout), decodes the CAPTURED report bytes per silo (op asserted vs BOTH constant + literal, NOT trusting
  zipreport), and proves K5(a)–(f): starved + undercovered pools skipped; exact 3:1 pro-rata (`shares1==3·shares2`);
  Σfunded ≤ shortfall; `redeemAssetsP ≤ availP`; default-OFF/empty/no-shortfall/no-active ⇒ zero writes; per-WAM
  routing correct. **Cold-build returned ZERO load-bearing guesses** (verified by my own gate re-run + full read of
  solver.go/solver_test.go; its 2 "judgment calls" — using the registry's `eePool` given the `addSilo` topology
  assert pins it == the WAM's, and test-fixture magnitudes derived from the pinned `availP` formula — are forced, not
  invented). Committed — code only; no `build/`/`docs/`/`contracts/` staged in the code commit; HEAD verified (no
  rogue commit). Ticket: `build/tickets/cre/CRE-02c-redemption-solver.md`. **Doc-sync:** no contract changed → no
  backward `wires/` edit; forward `claude-zipcode.md` §8.5 gains a "(BUILT — CRE-02c)" note + the §8.11 CRE-02 row
  marks 02c BUILT. ⚠️ **FLAG for reviewer (not mine, not committed):** the working tree carries pre-existing
  uncommitted changes UNRELATED to CRE-02c — deleted `build/superintendent*.md`/`build/supply.md`, a modified
  `contracts/test/AlgebraIchiFairLpOracle.t.sol`, and untracked `audit/` + `contracts/src/supply/x-ray/`. Left
  untouched + unstaged (the long-standing parallel audit-prep noted in earlier windows). Decide whether to commit or
  discard. **NEXT: reviewer picks** (candidates above).

- **CTR-15 note (2026-06-20) — the "reservoir" → purpose-true rename (monorepo, naming-only, ZERO behavior change).**
  An interjected naming task (NOT a build-NEXT advance — NEXT stays CRE-02c). Headline: the idle-USDC store
  `baseUsdcMarket` → **`usdcReservoir`** ("USDC Reservoir"); the strike-loop BORROW vault + its ecosystem
  `Reservoir*` → **`FarmUtility*`** ("Farm Utility Credit Vault"). The names were inverted vs purpose (the idle
  store is the real "reservoir"; the borrow vault is JIT-funded, ≈0 at rest). **`freeReservoir` LEFT verbatim**
  (it reads `EulerEarn.maxWithdraw(warehouse)` = the idle store, so post-rename it is already correct — the
  highest-risk silent-error carve-out); `escrowVault`/`borrowVault` identifiers LEFT (no "reservoir" token).
  **Process:** the reviewer ratified all 32 rows + 31b of `CTR-15-reservoir-farmutility-rename.md` one-at-a-time,
  then approved sweeping src `.sol` comment PROSE (classified) too. Applied across 5 phases on branch
  `rename/reservoir-to-farmutility` (commit 1 `f8cf6ed` = pre-existing audit work separated out so the rename lands
  clean; commit 2 = this rename): (1) Solidity files+symbols+importers, (2) deploy scripts+env `BASE_USDC_MARKET`→
  `USDC_RESERVOIR`, (3) CRE keeper config-key `"ReservoirLoopModule"`→`"FarmUtilityLoopModule"`+env+`reservoir`
  field, sharefeeds/zipreport comment refs `SzipReservoirLpOracle`→`SzipFarmUtilityLpOracle`, (4) ABI files+regen
  +index labels/paths, (5) docs/x-ray/test-comment/history sweep by classification rule. File renames:
  `ReservoirLoopModule`→`FarmUtilityLoopModule`, `ReservoirBorrowGuard`→`FarmUtilityBorrowGuard`,
  `SzipReservoirLpOracle`→`SzipFarmUtilityLpOracle`, `ReservoirMarketDeployer`→`FarmUtilityMarketDeployer` (+ their
  `.t.sol`/`.md`/`.json`), `docs/wires/8-B5-ReservoirLoop.md`→`8-B5-FarmUtilityLoop.md`. **Gates green (my own
  re-runs):** `forge build` + `forge test` (**1001 passed / 0 failed / 3 skipped — IDENTICAL to baseline**, proving
  zero behavior change); CRE `go build`+`go vet`+`go test -count=1`+`GOOS=wasip1 go build` across keeper/sharefeeds/
  zipreport/warehouse/buyburn-bid; `index.json` diff = names/paths/labels only. **Self-exclusions (the spec is its
  own source):** `CTR-15`+`FE-09` tickets keep their old→new tables (a blanket sweep collapses "X → Y"→"Y → Y");
  the **FE tickets `FE-00/01/05/06/07/08` were restored** (the frontend rename is **FE-09's domain in the layer
  repo** — `frontend/zipcode-finance-euler/`, its own `.git`, NOT this monorepo); CRE-02b/02c "reservoir" = the
  idle EE-backing read (LEAVE). **Two follow-ups owed:** (a) **FE-09 must land in the SAME RELEASE** — CTR-15 changed
  contract getter selectors (`baseUsdcMarket()`→`usdcReservoir()`, the borrow-vault getter→`farmUtilityVault()`) the
  frontend calls; (b) a **SEPARATE ticket for the `FarmUtilityBorrowGuard.sol:12-13` accuracy discrepancy** ("borrow
  vault IS resting USDC" — renamed in place, the factual claim deliberately NOT rewritten here). `audit/` (embedded
  skills clone) left untracked. **NEXT unchanged: CRE-02c.**

- **FE-09 note (2026-06-20) — the frontend half of the rename, APPLIED in the layer repo.** Companion to CTR-15;
  lands the FE `reservoir*`→`farmUtility*` rename so the layer binds the renamed contracts (same release). **Code
  committed to the LAYER repo `resi-labs-ai/zipcode-finance-euler`, branch `merge-flow-and-function`** (`a7f5653`) —
  NOT this monorepo (the layer has its own `.git`; monorepo gitignores it). Mechanics: re-ran the layer's
  `scripts/gen-zipcode-abis.mjs` off the **freshly-regenerated monorepo catalog** (`build/anvil/abi/index.json`,
  refreshed to the canonical DeployLocal addresses in `8d0930f`) after updating its `KEY_TABLE` (6 name→key renames)
  → `registry.ts` + `lib/zipcode/abi/*.ts` regenerated with new keys (`farmUtilityVault`/`farmUtilityEscrowVault`/
  `farmUtilityLpOracle`/`farmUtilityLoopModule`/`farmUtilityRouter`/`usdcReservoir`), new addresses, renamed ABI
  files; swept composables/components/store/pages/labels; product slug `zipcode-reservoir`→`zipcode-farm-utility`.
  **Gate: `npm run build` (nuxt) GREEN**; binding proven (`szipUsd.name()` resolves the new address; the verifier's
  only error is `navEntry()` `StalePrice` — a fresh-deploy no-feeds state condition, not a binding fault).
  `freeReservoir` (the idle `eePool.maxWithdraw` read in `ZcLiquidityGauge.vue`) LEFT verbatim (row-29 carve-out).
  **Caveat (reviewer-directed):** the layer branch carried pre-existing flow/function WIP interleaved with the
  rename in shared files; committed together in `a7f5653` (couldn't split by file). **Monorepo side (this commit):**
  the 6 sibling FE tickets (FE-00/01/05/06/07/08) swept `reservoir*`→`farmUtility*` — the work deferred when CTR-15
  restored them — and FE-09 marked APPLIED. **Redeploy done this session:** anvil re-forked clean + full DeployLocal
  (113/113 txs) so the catalog + chain + FE all agree on the new names. **NEXT unchanged: CRE-02c.**

- **CRE-02b note (2026-06-20) — the reserve-gated redemption-funding leg, folded into `cre/warehouse` (default-OFF).**
  The (R) funding twin of CRE-02's reactive (K) `RedemptionJob`: it sizes + fires the warehouse REDEEM→REPAY so the
  redemption→buyback cycle runs without a human POSTing events. **Off-chain Go only — NO contract changed** (no
  backward `wires/` edit owed). Committed at `cre/warehouse/` (`74b6c5c`, 4 files: `funding.go` + `funding_test.go`
  new, `workflow.go` + `go.mod` touched). **The open fork is RESOLVED → (b) fold-in, and FORCED:** a 4-critic
  fan-out + my own source read confirmed `WarehouseAdminModule` (a `ReceiverTemplate`) pins exactly ONE
  `expectedWorkflowId` (`out/ReceiverTemplate.sol/ReceiverTemplate.json` — `getExpectedWorkflowId`/
  `setExpectedWorkflowId`), so a SEPARATE CRE-02b workflow could never `WriteReport` to the warehouse (wrong
  workflow id → rejected). Only the pinned `cre/warehouse` binary can write, so the sizing must live in it — exactly
  the hook CRE-04's `observe` docstring anticipated. Built as a SECOND default-OFF `cron` handler (`onFundingTick`)
  added to `initFn` alongside the UNCHANGED http `onWarehouseOp` (two handlers, one binary, one pinned id — the
  `cre/buyburn-bid` two-handler precedent, `workflow.go:75-79`). **Each tick (reactive/stateless, §17 live reads):**
  resolve `warehouseSafe`/`eePool`/`usdc`/`queue` off the warehouse adapter (re-pointable; `queue == redemptionBox`,
  deploy seam #6); `shortfall = max(0, totalPending/scaleUp − (usdc.balanceOf(queue) − reservedAssets))`; **REPAY**
  `min(safeUsdc, shortfall)` to the queue **un-gated** (moves already-held cash, not farm utility backing — safe under
  a coverage breach); **REDEEM** tops the Safe up to `min(shortfall − repay, floor)` where `floor = covered() ?
  clamp(maxWithdraw(SAFE) − harvestReserve − safetyBuffer, 0, maxRedeemPerTick) : 0`, sizing
  `redeemShares = redeemAssets·balanceOf(SAFE)/convertToAssets(balanceOf(SAFE))` (conservative integer floor — never
  over-redeems); REPAY-then-REDEEM order; two sequential `writeReport`s reusing CRE-04's encode/write path (no
  re-implemented handshake). **Resolves the "verify the exact U getter" item:** there is NO bespoke utilization
  getter — `U` is captured by `maxWithdraw` through the reserve math (§8.2 `U = 1 − maxWithdraw/convertToAssets(balanceOf)`
  read via the coverage surface), and a separate knob would fight the freeze over the same cash (the load-bearing
  caution honored). **Harness loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier / cre-binding).
  **spec-fidelity = FAITHFUL** (confirmed the §8.2 `U` definition makes the no-bespoke-getter reading literal; the
  REPAY-ungated/REDEEM-gated split is the spec-correct treatment of which leg touches the reservoir; (b) is forced;
  funding correctly on the (R) side per CRE-OPS-ROUTING). **cre-binding = byte-exact + dimensionally sound, NO
  mismatches** (REDEEM `(uint256 shares)` / REPAY `(address dest, uint256 amount)` still match `_processReport`
  `:171-182`; `scaleUp=1e12`, `totalPending` 18-dp zipUSD ⇒ `pending/scaleUp` 6-dp USDC; the share ratio's units
  cancel through the ERC-4626 rate, floor = conservative; two-report routing clean). **reference-verifier = all
  bindings resolve** (adapter getters, queue getters, `maxWithdraw`/`convertToAssets`/`balanceOf` live-bound per the
  buyburn-bid precedent, `covered()` zero⇒true idiom; 3 non-blocking flags — add the `scheduler/cron` require+replace
  to go.mod, `readAddr` is new not a clone, the builders take the string-field `WarehouseOp` — all folded into the
  ticket's P1–P9 pins before cold-build). **Ticket tightened pre-cold-build** with P1–P9 (the two-handler/one-id
  proof, the cron go.mod add, default-OFF returns-before-any-read, cloned-helpers-not-keeper-pkg, the new `readAddr`,
  the units pins, the P8 mock-selector list, the P9 envelope decode). **Gate green (my own `-count=1` re-run, not
  just the cold-build's):** `cd cre/warehouse && go build ./... && go vet ./... && GOOS=wasip1 GOARCH=wasm go build
  ./... && go test -count=1 ./...` — all pass (34 test cases; the 8 new funding-sizing cases each decode the captured
  report bytes to op + sized scalars across the six "Done when" cases + scaleUp==0 + starved-reservoir; CRE-04's
  http-path tests unchanged + still green). **Cold-build returned ZERO load-bearing guesses** (verified by my own
  gate re-run + code read; it caught + fixed a tautological assert in its own test draft via `go vet`). Committed —
  code only; HEAD verified as the single 4-file commit, nothing under `build/`/`docs/`/`contracts/` staged; wasip1
  binary + `*.wasm` already gitignored. **Doc-sync:** no contract changed → no backward `wires/` edit; forward
  `claude-zipcode.md` §8.5/§8.6 boundary gains a "(BUILT — CRE-02b funding leg, default-OFF)" note. **NEXT:**
  reviewer picks — remaining CRE work is **CRE-02c** (cross-silo redemption solver, the multi-warehouse
  generalization, ticketed) + **SEAM-1** (CRE-03's material-move http trigger, additive own-later).
  ⚠️ **FLAG for reviewer (not mine, not committed):** the working tree carries session-fresh uncommitted changes
  UNRELATED to CRE-02b (off-chain Go) — a 24-line add to `contracts/test/SzipBuyBurnModule.t.sol` (a CTR-01
  `expectedAuthor`-mismatch test) + new x-ray `.md` files (`WarehouseAdminModule.md`, `CloneReportReceiver.md`,
  `DurationFreezeModule.md`, `lib/x-ray/`) + the `audit/` dir. These look like parallel audit-prep test-gap-fills /
  doc generation; I left them untouched + unstaged. Decide whether to commit or discard.

**Reviewer to release.** KEEPER-00 (spine) + KEEPER-01a (burn job) + **KEEPER-01b core slice (strike-loop harvest
Job) — DONE 2026-06-19** (note below) are landed. **KEEPER-01 was split into three** (its sub-systems differ in
size + maturity): **01a** fill-detect→`burnFor` (DONE), **01b** the engine harvest orchestrator (core slice DONE;
own-later slices remain — see note), **01c** freeze-`commit`-on-shortfall (deferred — binds to the INCOMPLETE
`DurationFreezeModule`). Candidate NEXT items (reviewer picks):
- ~~**KEEPER-01b own-later slices**~~ **— CLOSED 2026-06-19 (reviewer: out of MVP scope).** The entire own-later
  remainder (B1 regime classifier + EMA, B2 keeper STATE store, C1 vote weights, C2 lock-vs-sell split, C3
  `claimRebase` set, C5 per-epoch volume cap + epoch definition + the relocated TWAP cadence steer) is the
  ve-allocation / regime / epoch-cadence machinery — a process **not built out in the MVP**. None of it is a
  build item. The shipped strike-loop core (claim→borrow→exercise→sell→credit/recycle→restake, side-aware, with
  the level-based B3 taper/halt) is the whole of KEEPER-01b for M1. Rotation (D1) remains separately deferred to
  KEEPER-01c (the freeze rebuild). See `KEEPER-01b-OPEN-POLICY.md` for the closed-out record. ~~Plus one **follow-up on the
  built core slice:** generalize the restake leg to the token1-side case~~ **KEEPER-01b-R1 DONE 2026-06-19**
  (note below) — the restake is now side-aware; the token0-only known-limitation is RESOLVED. Rotation →
  KEEPER-01c (freeze rebuild).
- ~~**CRE-00 — the wasip1 workflow scaffold** + the shared §8.0 report-encoding package~~ **DONE 2026-06-19**
  (note below). The **(R)** workflows **CRE-01 / CRE-03 / CRE-04** are now UNBLOCKED and each imports the new
  `cre/zipreport` shared encoder (all through EXISTING report receivers — not blocked by anything). Independent
  of (K).
- **CRE-01 was SPLIT into three (R) slices 2026-06-19** (a 4-critic fan-out confirmed it can't cold-build to zero
  guesses as one ticket — same pattern as CTR-06/CTR-10; three distinct workflows, triggers, receivers):
  **CRE-01a** revaluation sharded → registry (rt3) — **DONE 2026-06-19** (note below); **CRE-01b** origination/
  draw/close/status → controller (rt1/2/4/5,6; `http.Trigger` + the §8.9 mock Proof-gate + `equityMark` +
  CTR-03 `siloId`) — **DONE 2026-06-19** (note below); **CRE-01c** default/recovery → DefaultCoordinator
  (rt8 action family; LOCK/RELEASE M1-live, DEFAULT/RECOVERY/RESOLVE/WRITEOFF go live with the M2 demo, §8.4) —
  **DONE 2026-06-20** (note below). **The CRE-01 family is now COMPLETE** (01a registry / 01b controller / 01c
  coordinator); there is no further CRE-01 slice. **CRE-04 (warehouse ops) — DONE 2026-06-20** (note below);
  this **UNBLOCKS CRE-02** (it reuses the `cre/warehouse` op package for the (R) REDEEM→REPAY funding). Remaining
  (R) backlog: ~~**CRE-03 (feeds)**~~ **DONE 2026-06-20** (note below) + **CRE-02 (R+K hybrid, now unblocked)**.
  **With CRE-03 done, there is NO standalone (R) producer left** — the remaining CRE work is the CRE-02b/02c
  orchestration glue (already ticketed obligations) + the deferred SEAM-1 (CRE-03's material-move http trigger).
  ~~**Strong NEXT candidate: CRE-01**~~ (split) (origination/draw/close/status → controller; revaluation → registry,
  gas-bounded sharded; rt8 default/recovery → DefaultCoordinator) — the largest (R) producer, now that the
  encode handshake is a tested library.
- ~~**CRE-02 (R)+(K) hybrid** — redemption-settle~~ **(K) operator half DONE 2026-06-20** (note below). The
  reactive `RedemptionJob` (`cre/keeper/internal/job/redemption_job.go`) drives `ZipRedemptionQueue.settleEpoch`
  + `OffRampModule.claim`/`requestRedeem` via (K). The (R) REDEEM→REPAY funding is the EXISTING `cre/warehouse`
  (CRE-04); **the cross-transport orchestration that fires it (sized off the §8.2 reserve) is the owed seam
  CRE-02b** (see Open obligations). ~~So the only remaining (R) backlog item is **CRE-03 (NAV/LP/xALPHA-APR feeds)**.~~
  **CRE-03 DONE 2026-06-20** (note below) — no standalone (R) producer remains.
- **CTR-06c / CTR-07** (NEW contracts workstream — credit-warehouse scaling + federation). **CTR-02 `SiloRegistry` +
  CTR-03 controller siloId routing + CTR-04 `closeLine` withdraw-queue reclaim + CTR-05 `SeniorNavAggregator` +
  CTR-06a farm utility borrow-vault governor handoff + CTR-06b `JuniorTrancheDeployer` are DONE** (2026-06-18/19, below). CTR-02/03's concurrent slot accounting is fully SOUND (CTR-04 physically frees the
  binding withdraw-queue slot on close; a pool churns 28 *concurrent* lines). **CTR-06 was RE-SCOPED 2026-06-18** — a
  4-critic fan-out found the single-ticket `SiloDeployer` can't cold-build to zero guesses (the junior stack is ~30
  deployments collapsed into 5 nouns with no reusable junior deployer; the hub/silo boundary + shared-queue reach were
  undefined; the "29 real concurrent line" fork gate is infeasible — EE can't compile, no fork test ever stood up a
  real EE pool). Split into **CTR-06a** (`FarmUtilityMarketDeployer` borrow-vault `setGovernorAdmin` fix — discharges
  FE-07 Finding A; tiny, independent, the only near-term cold-buildable piece — DONE), **CTR-06b** (`JuniorTrancheDeployer` —
  the missing reusable artifact; D1+D5 ratified — DONE 2026-06-19), **CTR-06c** (`SiloDeployer` orchestrator + feasible mock-EE
  test; deps 06a+06b both DONE — now unblocked). Index + pinned hub/silo decomposition + open decisions D1–D5:
  `build/tickets/contracts/CTR-06-silo-deployer.md`. **CTR-06a + CTR-06b both landed 2026-06-19** (notes below; D1+D5
  ratified by the reviewer). **CTR-06c landed 2026-06-19** (note below) — the re-scoped CTR-06 is now COMPLETE
  (06a+06b+06c). **CTR-07 landed 2026-06-19** (note below) — the slot-2 farm utility fund/defund is now revolving;
  finding 3 RESOLVED. **CTR-08 landed 2026-06-19** (note below) — structure-2 revolving lines proved as an operating
  MODE over the as-built stack with ZERO contract change (test + doc only). **CTR-09 landed 2026-06-19** (note below)
  — the 0.1%-per-revolution draw fee; finding 2 RESOLVED. **CTR-10 was RE-SCOPED 2026-06-19 into a 3-way split**
  (a 4-critic fan-out found it can't cold-build as one ticket — same pattern as CTR-06): **CTR-10a** (`ISeniorPool`
  extract + no-op re-type) **landed 2026-06-19** — the structural §4.7 senior-read generalization; **CTR-10b** (the
  federation HOST SEAM — venue-agnostic `addSilo` admission + the `seniorPool()` getter + plug-in recipe + proof
  test) **landed 2026-06-19** (notes below) — RESOLVES obligation #3, so a future non-Euler venue adapter plugs in
  with NO registry change; **CTR-10c** (the actual reference non-Euler adapter + wrapper + fork test) is
  **BACK-PRESSURE / DEFERRED (P5)** — still blocked on a concrete venue choice + a real bindable non-Euler senior
  surface (none deployed on the Base fork) + donation-immunity needing a real deployed venue (obligations #1/#2/#4
  preserved in the CTR-10c deferred-spec note below + `docs/venue.md`). So the scaling/federation contract
  workstream has NO near-term cold-buildable item left (CTR-10c waits on a 2nd venue actually being wanted; the
  host is now READY for it). (**CTR-12 DONE 2026-06-19**; **CTR-13 DONE 2026-06-19**; **CTR-11 DONE 2026-06-19** —
  cohort slash-to-main-safe, note below. All contract-track tickets (CTR-01..13) are now landed except the deferred
  CTR-10c second-venue integration.)

- **CRE-02 note (2026-06-20) — the (K) operator-half redemption-settle Job (`RedemptionJob` → `ZipRedemptionQueue`
  + `OffRampModule`).** The (K) half of the (R)+(K) hybrid, per `CRE-OPS-ROUTING.md` (the (R) REDEEM/REPAY is the
  SEPARATE `cre/warehouse`/CRE-04 — a transport the keeper cannot emit). A committed keeper `Job` at
  **`cre/keeper/internal/job/redemption_job.go`** (off-chain Go on the KEEPER-00 spine — **NO contract changed**,
  so **NO backward `wires/` edit owed**). Modeled on `BurnJob`: a PURE-read `Evaluate` returns an ordered
  `chain.Plan`; the Runner alone submits. **Reactive + idempotent + stateless** — each tick re-reads live
  off-ramp/queue state (§17, never cached) and emits an ordered Plan: **settleEpoch** (when free REPAY-delivered
  USDC + pending exist — the Go gate `min(freeUsdc, pending/scaleUp) > 0` mirrors `ZipRedemptionQueue.sol:203-206`
  exactly, so a 0-fill is skipped, no wasted tx), **claim** (drain banked `claimableAssets[rqSafe]` to the rq Safe
  via `OffRampModule.claim`), and an OPTIONAL **requestRedeem** escrow leg gated by a config `RedeemTargetPending`
  (**default 0 = escrow disabled**, the `BurnJob` `minBurn` idiom). **Reactive legs first, escrow last** so an
  escrow revert under the spine's abort-on-first-error never strands the always-safe legs. Never calls the
  warehouse, never calls `queue.withdraw`/`requestRedeem` DIRECTLY (only via the off-ramp, which `exec`s through
  the rq Safe = `redeemController`). The single keeper signer must be BOTH `queue.controller` AND `offramp.operator`
  — two new `IdentityCheck` rows (`operator()`/`controller()`) assert it at startup (§8.7 `owner != operator`).
  **Harness loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier / keeper-binding).
  **keeper-binding = NO MISMATCHES** (settle math mirrors the contract exactly incl. the unchecked-sub edge;
  `claim(claimable)` reads `maxWithdraw(rqSafe)==claimableAssets[rqSafe]` so it can't over-claim/revert;
  `escrow = floorToUnit(min(gap,idleZip), scaleUp) >= scaleUp` satisfies every off-ramp `ZeroAmount`/`NotWholeUnit`
  + queue whole-unit/single-requester guard; ordering + the synchronous-spine no-double-act argument hold).
  **spec-fidelity = FAITHFUL** (no invention; honors §17 + the (R)/(K) routing ruling; **CRE-06 reserve correctly
  on the (R) REDEEM-sizing side — this (K) Job is reserve-independent**, reads only the queue's own
  `reservedAssets`; the stale 30-day-cron / "against the anvil fork" framing dropped — keeper-track gate is
  `go build`/`go test` + simulated backend, not anvil). **reference-verifier = ALL bindings resolve** (every
  OffRampModule/ZipRedemptionQueue signature + chain helper + the `RedemptionProbe` bytecode = valid solc-0.8.24
  with every needed selector). **Ticket tightened pre-cold-build** from the junior-dev fan-out (the load-bearing
  fixes: the stub MUST key the two `balanceOf` reads by `call.To` since they hit different token addrs; reuse the
  EXISTING `encodeUint` — a local redeclaration is a compile error; the sim `record(i)` is a 2-field tuple not
  StrikeLoop's 4-field; `floorToUnit` pinned as an unexported helper; `NewRedemptionJob` signature pinned; the
  botched `claimable = CallUint…` line cleaned). **Gate green (my own `-count=1` re-run, not just the cold-build's):**
  `cd cre/keeper && go build ./... && go vet ./... && go test -count=1 ./...` — all pass. **Non-vacuous:** the unit
  test decodes real `Action` calldata to selectors+scalars across 6 groups (all-three-ordered / settle-only /
  claim-only / 4 escrow-gating subcases / 4 no-op+fail-safe subcases / escrow-floored); the sim test deploys
  `RedemptionProbe` on the simulated backend and runs the FULL Runner, asserting the 3 ordered recorded calls
  (`settleEpoch` / `claim(5)` / `requestRedeem(7e12)`). **Cold-build returned ZERO load-bearing guesses** (verified
  by my own gate re-run + code read; its 2 adjustments — a stub rename to dodge a `baseReader` collision +
  `setRqSafe` calldata idiom — are forced compile fixes, not mechanism guesses). Committed to `cre/keeper`
  (`0f2e32c`) — code only (6 files incl. `RedemptionProbe.sol`); no `build/`/`docs/`/`contracts/` staged; HEAD
  verified (no rogue commit). Ticket: `build/tickets/cre/CRE-02-redemption-settle.md`. **Doc-sync:** no contract
  changed → no backward `wires/` edit; forward `claude-zipcode.md` §8.3 gains a "(BUILT — CRE-02 (K) half)" note +
  the §8.11 map's CRE-02 row marks the (K) half BUILT / flags the owed CRE-02b. **NEXT:** reviewer picks — the
  remaining (R) backlog is **CRE-03** (NAV/LP/xALPHA-APR feeds); plus the owed **CRE-02b** orchestration glue.
  ⚠️ **FLAG for reviewer (not mine, not committed):** the working tree carries a 123-line uncommitted change to
  `contracts/test/WarehouseAdminModule.t.sol` (a `_onReportRevertsWithSelector` helper + new onReport
  selector-revert tests + an `attacker` state-var refactor). It is **unrelated to CRE-02**, predates my window
  (last committed touch was `81df630`, before the CRE-04 commits), and I left it untouched + unstaged — decide
  whether it's leftover CRE-04 test-hardening to commit or to discard.

- **CRE-03 note (2026-06-20) — the szipUSD share-price feeds producer (`NAV_LEG`+`LP_MARK`, both rt7 → one
  coherent wasip1 producer).** A pure (R) producer through the two EXISTING `ReceiverTemplate` push-caches
  (`SzipNavOracle` + `SzipFarmUtilityLpOracle`) — no new contract, off-chain Go only → **NO backward `wires/` edit
  owed**. Committed at **`cre/sharefeeds/`** (engine-epoch `cron` → node-mode identical consensus on the two
  off-chain marks {`alphaUSD`, `HYDX/USD`} (§8.9 mock observe, the `cre/revaluation` idiom) → DON-mode `eth_call`
  reads of every on-chain quantity {ICHI `getTotalAmounts`/`totalSupply`/`token0`/`token1`, `exchangeRate()`, the
  prior `legCache(uint8)` for the band} (the `cre/buyburn-bid` read idiom) → **ONE coherent computation** → up to
  two `WriteReport`s, encoded via `cre/zipreport` `NavLegReport`/`LpMarkReport`). **Coherence (§8.6, load-bearing):
  the SAME band-clamped `alphaUSD` prices BOTH the NAV alpha leg AND the LP mark's xALPHA reserve valuation** — the
  two feeds converge together (the LP feed inherits NAV's band rate-limit though its own receiver has no band).
  **Scope narrowed vs the §8.11 row** (a FINDING, not a silent re-scope): the row's "xALPHA-APR feed" is NOT here
  — APR is on-chain-derived (§8.8) and the raw RATE push is the separate `cre/szalpha-rate` (8x-02, R-1-blocked).
  **Harness loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier / cre-binding). **cre-binding =
  byte-exact handshake on both rt7 payloads + the LP `mark`-units question RESOLVED definitively** (`mark` is
  quote-native USDC 6-dp = `perShare_18dp / 1e12`, proven from `ScaleUtils.calcScale(18,6,6)`→feedScale=1e24/
  priceScale=1e6 and the contract's own `1_000e6` test; band edge-clamp lands, strict `>`, no off-by-one).
  **spec-fidelity = FAITHFUL** (no invention; FINDING-1 [HYDX pushed unconditionally — the as-built `SzipNavOracle`
  has no on-chain HYDX read and REQUIRES leg 1 fresh] is a correct contract-wins reading; FINDING-2 [APR scope]
  correct). **reference-verifier = ALL bindings resolve** (the real read idiom is `cre/buyburn-bid:288-367`, NOT
  the comment-only `cre/szalpha-rate` stub; `CallContract` `BlockNumber` optional=latest; `WriteCreReportRequest`
  is the live form). **Ticket tightened pre-cold-build** from the junior-dev fan-out (added `XAlpha`/`ZipUSD`
  Config for the side-aware `token0`/`token1` mapping; pinned the exact band-clamp formula + the `LegMarks`
  carrier struct; cited buyburn-bid for the reads). **Gate green (my own `-count=1` re-run, not just the
  cold-build's):** `cd cre/sharefeeds && go build ./... && go vet ./... && go test -count=1 ./... && GOOS=wasip1
  GOARCH=wasm go build ./...` — all pass. **Non-vacuous:** 13 tests incl. `TestSimEncodeHandshake` (decodes the
  envelope, asserts rt==7 literal, legs==[0,1], prices match, and the LP mark == the hand-computed `38e6` =
  $38/share 6-dp via BOTH the function and a literal), band-clamp (3 cases), LP math (both token orderings +
  zero-supply), and the simulated handler with mocked `eth_call` replies + a writeCap asserting the 2 ordered
  reports. **Cold-build returned ZERO load-bearing guesses** (verified by my own gate re-run + full code read; its
  5 listed adjustments — the `MockMarks` config seam, a `defaultMaxDeviationBps` fallback, the legCache-skip when
  no NAV oracle, the `uint48`→`uint64` ts local type, a defensive nil/zero-prior guard — are glue/defensive
  defaults, NONE touching the handshake bytes or the load-bearing formulas). **Provenance note:** `cre/sharefeeds/`
  source pre-existed this window (a ~10:00 prior build attempt, before the critic-tightened ticket); the cold-build
  verified it line-by-line against the tightened ticket + ran gates rather than discarding correct work, and I
  independently re-ran all 4 gates + read `workflow.go`/the encode test myself. Added a per-module `.gitignore`
  (mirrors `cre/revaluation`) so the 16 MB build binary + `*.wasm` + secrets are never staged. Code only; no
  `build/`/`docs/`/`contracts/` staged beyond the doc-sync below; HEAD verified post-commit (no rogue commit).
  Ticket: `build/tickets/cre/CRE-03-share-price-feeds.md`. **Doc-sync:** no contract changed → no backward `wires/`
  edit; forward `claude-zipcode.md` §8.6 gains a "(BUILT — CRE-03)" note (with FINDING-1 + the deferred-trigger
  SEAM-1) + the §8.11 CRE-03 row marked DONE / scope-corrected. **NEXT:** reviewer picks — no standalone (R)
  producer remains; the open CRE work is CRE-02b/02c (orchestration glue, ticketed obligations) + SEAM-1 (the
  deferred material-move http trigger, Open obligations).

- **CRE-04 note (2026-06-20) — the senior-warehouse op producer (opType 1/2/3/4 → `WarehouseAdminModule`/8-Bw).**
  A pure (R) producer through the EXISTING `WarehouseAdminModule` receiver (CRE-OPS-ROUTING: CRE-04 is pure (R);
  no new contract, off-chain Go only → **NO backward `wires/` edit owed**). A committed wasip1 workflow at
  **`cre/warehouse/`** (monorepo `cre/`). One `http.Trigger` carries an off-chain warehouse-op event; the workflow
  reaches **identical consensus** on a string-only `WarehouseOp` carrier (4 fields: op/amount/shares/dest),
  normalizes + **dispatches on the lowercase op discriminant** (`supply`→1 / `approve`→2 / `redeem`→3 /
  `repay`→4), validates the per-op required fields, and emits **one `WriteReport`** to the warehouse adapter via
  the shared `cre/zipreport` encoders (`WhSupplyReport`/`WhApproveReport`/`WhRedeemReport`/`WhRepayReport`; no
  re-implemented handshake). **All four magnitudes require `> 0`** (unlike CRE-01c's recovery/resolve/writeoff
  which tolerate 0): `deposit(0)` reverts EE `ZeroShares`, `redeem(0)` is a wasted no-op, a 0 approve/transfer is
  meaningless. **REPAY `dest` is carried in the event** (§8.5: the one producer-carried field), validated non-zero;
  the on-chain `WrongRedemptionBox` self-check + the Roles `EqualTo(redemptionBox)` scope are the backstops (the
  producer does NOT read on-chain to pre-check — "surface, don't pre-check", the CRE-01c posture). **NO Proof gate**
  — the `WarehouseAdminModule` exposes no on-chain boolean gate surface (its decode is `(opType, payload)` → one
  pinned Roles-forwarded call); the real security boundary is the Zodiac Roles scope (param-pinning, Call-only) +
  the distinct Forwarder/workflow identity, so the identical consensus over the mocked-via-trigger op facts IS the
  §8.9 attestation (the CRE-01a/01c posture). The §8.5 on-chain NAV sizing
  (`eePool.convertToAssets(balanceOf(SAFE))`) is the documented production replacement of the mock `observe` (the
  magnitudes arrive pre-sized on the trigger). Fail-safe no-op on unset Warehouse; unknown/empty-op +
  missing/unparseable-required-field errors propagate. **Includes REDEEM** (op 3) even though CRE-OPS-ROUTING's
  shorthand names CRE-04 "SUPPLY/APPROVE/REPAY" — the package must carry REDEEM so **CRE-02 reuses it** for the (R)
  REDEEM→REPAY funding (CRE-OPS-ROUTING line 120); spec-fidelity confirmed excluding it would break that reuse
  contract. **Harness loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier / cre-binding).
  **cre-binding = BYTE-EXACT** (all four ops: envelope `(uint8 opType, bytes)` ↔ `WarehouseAdminModule._processReport`
  `:158`; per-op payload tuples ↔ the contract decode sites — SUPPLY/APPROVE/REDEEM `(uint256)` `:164/:168/:172`,
  REPAY `(address,uint256)` order `:176`; opType bytes ↔ contract consts `:25-31` ↔ `zipreport.Wh*` consts
  `:118-123`; the `> 0` rules + `WrongRedemptionBox`/`UnsupportedOpType` reverts verified against
  `WarehouseAdminModule.t.sol` incl. `deposit(0)` revert + `redeem(0)` no-op-success). **spec-fidelity = FAITHFUL**
  (the four ops/tuples/producer-sizes-policy-pins split verbatim §8.5 lines 690-707; the all-four-ops incl. REDEEM
  reading is the CORRECT one per CRE-OPS-ROUTING 120; the no-Proof-gate + mock-sizing posture consistent with
  CRE-01a/01c; §17 honored — nothing hardcoded, REPAY dest carried not Config-sourced to avoid re-point drift).
  **reference-verifier = ALL ~20 cited file:line refs resolve exactly** (no stale refs; the four `Wh*RoundTrip`
  tests exist at `report_test.go:420/431/442/453`; `parseAddress`/`parsePositiveBig` clone sources exact;
  `parseBytes32`/`parseNonNegBig` correctly dropped). **Ticket tightened pre-cold-build** from the one borderline
  junior-dev nit: the handler return type `(struct{}, error)` pinned inline in K3. **Gate green (my own re-run,
  `-count=1`, not just the cold-build's):** `cd cre/warehouse && go build ./... && go vet ./...` (host) +
  `GOOS=wasip1 GOARCH=wasm go build ./...` exit 0 + `go test -count=1 ./...` = PASS, **non-vacuous** (4 per-op
  handshake tests each independently `abi.Unpack` the captured bytes to the exact contract tuple — NOT trusting
  `zipreport` — asserting opType against BOTH the constant and the literal + decoded scalars==input incl. REPAY
  dest+amount; the full `RunInNodeMode` + `ConsensusIdenticalAggregation[WarehouseOp]` path runs, **proving the
  string-only carrier Wraps**; op normalization; 18 validation-error⇒0-write subcases; unset-Warehouse no-op;
  `parseAddress` unit test). **Cold-build returned ZERO load-bearing guesses** (verified by my own gate re-run +
  code/test read). Committed to `cre/warehouse` — code only (11 files); host build artifact (`/cre-warehouse`) +
  `*.wasm` gitignored; no `build/`/`docs/`/`contracts/` staged in the code commit; HEAD verified (no rogue commit).
  Ticket: `build/tickets/cre/CRE-04-warehouse-ops.md`. **Doc-sync:** no contract changed → no backward `wires/`
  edit; forward spec §8.5 gains a "(BUILT — CRE-04)" producer note + §8.11's CRE-04 row marks BUILT + the
  "Open before CRE-04 finalizes" reconcile line marked DONE. **NEXT:** reviewer picks among the remaining (R)
  backlog — CRE-03 (NAV/LP/xALPHA-APR feeds) or CRE-02 (redemption-settle, now unblocked).

- **CRE-01c note (2026-06-20) — the loss-action producer (reportType 8 → `DefaultCoordinator`).** The THIRD and
  LAST of the three CRE-01 (R) slices — **the CRE-01 family is now COMPLETE.** A committed wasip1 workflow at
  **`cre/coordinator/`** (monorepo `cre/`, off-chain Go only — **NO contract changed**, so no backward `wires/`
  edit owed). One `http.Trigger` carries an off-chain loss event; the workflow reaches **identical consensus** on
  a string-only `LossEvent` carrier (7 fields), normalizes + **dispatches on the lowercase action discriminant**
  (`lock`→0 / `release`→1 / `default`→2 / `recovery`→3 / `resolve`→4 / `writeoff`→5), validates the per-action
  required fields, and emits **one `WriteReport`** to the coordinator via the shared `cre/zipreport` encoders
  (`CoordLock/Release/Default/Recovery/Resolve/WriteOff`; no re-implemented handshake). **NO Proof gate** — unlike
  CRE-01b's origination/draw, the loss family has no on-chain boolean gate surface (the coordinator's six decode
  tuples carry no booleans; the §13 Forwarder/identity boundary is the entry guard), so the identical consensus
  over the mocked-via-trigger facts IS the §8.9 attestation — the exact posture CRE-01a (revaluation) built.
  Fail-safe no-op on unset Coordinator; unknown/empty-action + missing-required-field errors propagate.
  **All six actions built+tested; the M1-live (LOCK/RELEASE) vs M2 (economic family) split is OPERATIONAL, not a
  code gate** (the encode handshake is identical machinery for all six). **Harness loop ran:** 4 critics
  (junior-dev / spec-fidelity / reference-verifier / cre-binding). **cre-binding = byte-exact** (the three-level
  wire — envelope `(uint8,bytes)` → inner `(uint8 action,bytes)` → per-action tuple — matches `DefaultCoordinator`
  `_lock/_release/_default/_recovery/_resolve/_writeOff` at `:207/:220/:235/:254/:277/:298` exactly; action bytes
  ↔ enum ordinals `:52-60` ↔ `zipreport.Action*` constants all consistent; `parsePositiveBig`(>0) for lock-amount/
  atRisk vs `parseNonNegBig`(≥0) for recovery-proceeds/capitalSlash matches every contract+escrow revert guard —
  `ZeroAtRisk` `:237`, escrow `ZeroOriginator`/`ZeroAmount`, the `capitalSlashAmount==0`/`recoveryProceeds==0`
  LEGAL paths). **spec-fidelity = FAITHFUL** (six actions/tuples/units verbatim §8.4 lines 645-662; the "no Proof
  gate" reading verified against the BUILT CRE-01a precedent — `cre/revaluation/workflow.go` has no `Gates`
  struct; rt8-only scoping with the rt5 controller status-marker correctly EXCLUDED as CRE-01b's, §8.4 line 651's
  two-receivers-for-one-default; §17 honored). **reference-verifier = ALL resolve** (all six `Coord*` encoders +
  the cloned `parseBytes32`/`parsePositiveBig`/`parseNonNegBig` helpers + the `parseLien` address-parse model +
  the SDK surface). **Ticket tightened pre-cold-build** from the fan-out: two stale helper line-ranges fixed
  (`parseBytes32` 266-286, `parse*Big` 288-312) + a clone-rename note (`controller`→`coordinator` in project.yaml/
  .env/README) + the test chain-selector note. **Gate green (my own re-run, `-count=1`, not just the cold-build's):**
  `cd cre/coordinator && go build ./... && go vet ./...` (host) + `GOOS=wasip1 GOARCH=wasm go build ./...` exit 0
  + `go test -count=1 ./...` = PASS, **non-vacuous** (6 per-action handshake tests each independently `abi.Unpack`
  the captured bytes down all three nesting levels to the exact contract tuple — NOT trusting `zipreport` —
  asserting reportType==8/action-byte against BOTH the constant and the literal + the decoded scalars==input; the
  full `RunInNodeMode` + `ConsensusIdenticalAggregation[LossEvent]` path runs, **proving the string-only carrier
  Wraps**; 19 validation-error⇒0-write cases; 3 zero-magnitude-accepted⇒1-write cases; unset-Coordinator no-op;
  `parseBytes32`/`parseAddress` unit tests). **Cold-build returned ZERO load-bearing guesses** (verified by my own
  gate re-run + git inspection). Committed to `cre/coordinator` (`17661fb`) — code only (11 files); host build
  artifact + `*.wasm` gitignored; no `build/`/`docs/`/`contracts/` staged in the code commit; HEAD verified (no
  rogue commit). Ticket: `build/tickets/cre/CRE-01c-coordinator-producer.md`. **Doc-sync:** no contract changed →
  no backward `wires/` edit; forward spec §8.4 gains a "(BUILT — CRE-01c)" producer note + §8.11's CRE-01 row
  marks 01c BUILT / the family COMPLETE. **Addresses the open obligation "LOSS — the default/slash flow is M2"** —
  this producer IS that rt8 driver; the live firing of the economic actions is M2 ops, the producer is built.
  **NEXT:** reviewer picks among the remaining CRE backlog — CRE-03 (NAV/LP/xALPHA-APR feeds) or CRE-04
  (warehouse SUPPLY/APPROVE/REPAY); CRE-02 stays blocked on CRE-04.

- **CRE-01b note (2026-06-19) — the controller lifecycle producer (reportType 1/2/4/5,6 → `ZipcodeController`).**
  The SECOND of the three CRE-01 (R) slices — the headline/largest. A committed wasip1 workflow at
  **`cre/controller/`** (monorepo `cre/`, off-chain Go only — **NO contract changed**, so no backward `wires/`
  edit owed). One `http.Trigger` carries an off-chain lifecycle event; the workflow reaches **identical
  consensus** on an `Application` carrier (string + bool + uintN scalars + a nested `Gates` struct of six bools),
  normalizes + **dispatches on the action discriminant** (`origination`→rt1 / `draw`→rt2 / `close`→rt4 /
  `default`→rt5 / `liquidation`→rt6), validates the per-action required fields, **enforces the §8.9 Proof gate
  fail-closed** (origination/draw emit ONLY if all six gates pass — else a no-op, NO report), and emits **one
  `WriteReport`** to the controller via the shared `cre/zipreport` encoders (`Origination`/`Draw`/`Close`/
  `Status`; no re-implemented handshake). `siloId` rides **origination only** (CTR-03; draw/close re-resolve the
  venue from the stored `r.siloId` on-chain — the producer does NOT re-send it). Fail-safe no-op on unset
  Controller; required-field/unknown-action errors propagate. **Harness loop ran:** 4 critics (junior-dev /
  spec-fidelity / reference-verifier / cre-binding). **cre-binding = byte-exact** (all four report types' field
  order/type/reportType-routing match `ZipcodeController._processReport` at `:203/:222/:266/:287` exactly).
  **spec-fidelity = FAITHFUL** (the §8.9 "emit only if gates pass" implemented verbatim; rt5/rt6 status-markers
  to the *controller* correctly scoped IN, the DefaultCoordinator rt8 economic action family correctly DEFERRED
  to CRE-01c — split is on the receiver, not on "default vs not"; honors §17/§8.0 534-538). **reference-verifier
  = ALL 17 bindings resolve** — incl. the load-bearing carrier proof: `isIdenticalType` **recurses into structs**
  (`consensus_aggregators.go:207-214`), so the nested `Gates` struct-of-bool + the `uintN` scalars are
  identical-type and Wrap-able. **One cre-binding misread corrected by my own source read:** it claimed
  `seedPrice` accepts any uint256 — FALSE; `seedPrice`→`_writePrice` reverts `PriceOracle_InvalidAnswer` on
  `price==0` (`ZipcodeOracleRegistry.sol:115,142`), so the ticket's `equityMark > 0` rule was already correct
  (kept). **Ticket tightened pre-cold-build** from the fan-out: pinned per-action required-vs-optional field
  rules + action normalization (`ToLower`+`TrimSpace`); the `parseBytes32(s, allowZero bool)` signature; an
  anticipated-on-chain-reverts note (`SiloUnrouted`/`SiloFull`/`LienExists`/`UnknownLien`/`DebtOutstanding` — the
  producer surfaces, does not pre-check); and the two-distinct-single-gate-flip gate test. **Gate green (my own
  re-run, `-count=1`, not just the cold-build's):** `cd cre/controller && go build ./... && go vet ./...` (host)
  + `GOOS=wasip1 GOARCH=wasm go build ./...` exit 0 + `go test -count=1 ./...` = PASS (13 funcs + sub-cases),
  **non-vacuous** (each handshake test drives the FULL handler through `evmmock`, captures the real `WriteReport`
  bytes, then **independently `abi.Unpack`s** the envelope to `(uint8,bytes)` + the payload to the exact contract
  tuple per action — NOT trusting `zipreport` — asserting reportType against BOTH the constant and the literal;
  the full `RunInNodeMode` + `ConsensusIdenticalAggregation[Application]` path runs, **proving the carrier
  Wraps**; gate-pass⇒1 write, two distinct single-gate flips⇒0 writes; the validation-error table⇒0 writes;
  zero-proofRef accepted; unset-Controller no-op). **Cold-build returned ZERO load-bearing mechanism guesses**
  (its 3 reported items are literal/structural resolutions — the `Hash→[32]byte` copy, empty-string=missing,
  no Status range-check — all ticket-faithful); verified by my own code read. Committed to `cre/controller` —
  code only; host build artifact + `*.wasm` gitignored; no `build/`/`docs/`/`contracts/` staged in the code
  commit; HEAD verified (no rogue commit). Ticket: `build/tickets/cre/CRE-01b-controller-producer.md`.
  **Doc-sync:** no contract changed → no backward `wires/` edit; forward spec §8.0 gains a "(BUILT — CRE-01b)"
  producer note + §8.11's CRE-01 row marks 01b BUILT. **NEXT remainder:** CRE-01c (DefaultCoordinator rt8 action
  family) — the last CRE-01 slice.

- **CRE-01a note (2026-06-19) — the WOOF-02 gas-bounded revaluation producer (reportType 3 → `ZipcodeOracleRegistry`).**
  The FIRST of the three CRE-01 (R) slices (the split was forced by a 4-critic fan-out — see the NEXT bullet).
  A committed wasip1 workflow at **`cre/revaluation/`** (monorepo `cre/`, off-chain Go only — **NO contract
  changed**, so no backward `wires/` edit owed). An off-chain Proof-of-Value re-appraisal batch arrives via
  `http.Trigger`; the workflow reaches **identical consensus** on the `(lien, mark)` set, validates + **dedups
  the full sweep (fail-closed — errors on a dup)** + enforces equal-length, **shards** into gas-bounded batches
  (`MAX_LIENS_PER_REPORT` default 50, TUNABLE; logs the shard count), and emits **one `WriteReport` per shard**
  encoded via the shared `cre/zipreport.Revaluation` (no re-implemented handshake). Stamps one DON
  `uint32(runtime.Now().Unix())` ts across a sweep. Fail-safe no-ops on empty marks / unset registry. **Harness
  loop ran:** 4 critics (junior-dev / spec-fidelity / reference-verifier / cre-binding). **cre-binding = byte-exact**
  (envelope `(uint8 3, bytes)` → `(address[],uint256[],uint32)` matches `ZipcodeOracleRegistry._processReport`
  exactly; every `_writePrice` revert path — price==0, future ts, StaleReport strictly-newer, decimals==18,
  LengthMismatch — anticipated; uint32→uint48 ts widening lossless). **spec-fidelity = FAITHFUL** (the §8.1
  sharding runbook implemented verbatim; trigger=`http.Trigger`/no-cron and dedup-across-sweep are LITERAL §8.1
  text, not invention; carrier type is a transparent SDK derivation; the 01a/b/c split honors §8.11 intent).
  **reference-verifier = ALL bindings resolve** (every cited contract/zipreport/SDK line verified; the `Marks`
  struct-of-`[]string` carrier confirmed `isIdenticalType` + `values.Wrap`-able). **The one load-bearing find
  (junior-dev + reference-verifier):** the draft's K3 said the http payload reaches node-mode `observe` "via
  cfg/closure, mirroring the scaffold" — **WRONG** (the scaffold's `observe` ignores its config; `*Config` is
  static, parsed once at init). **FIXED in the ticket BEFORE cold-build:** `RunInNodeMode[C,T]`'s `C` is a FREE
  generic — the handler passes `payload.Input` in as `C = []byte` (`observe(in []byte, _ cre.NodeRuntime)`); a
  Config field for the batch is explicitly forbidden. Also pinned pre-build: the JSON wire shape
  (`{"liens":[],"prices":[]}`), the go.mod cron→http replace swap, and explicit hex validation before
  `common.HexToAddress` (which does NOT error on bad input). **Two spec gaps fixed first** (§8.1 now states the
  dup-action = error/fail-closed + the uint32-ts 2106 wire-ceiling note; §8.11's stale single-`CRE-01` build-map
  row now reflects the 01a/01b/01c split). **Gate green (my own re-run, `-count=1`, not just the cold-build's):**
  `cd cre/revaluation && go build ./... && go vet ./...` (host) + `GOOS=wasip1 GOARCH=wasm go build ./...` exit 0
  + `go test ./...` = 10 tests PASS, **non-vacuous** (the full handler sim decodes the captured bytes to the exact
  on-chain tuple and proves the `Marks` carrier `values.Wrap`s through `RunInNodeMode`; sharding asserts
  ceil(N/k) writes / ordered subsets / identical ts / union==input; dedup/length/zero-price/malformed-address →
  error+0 writes; no-op cases). **Cold-build returned ZERO load-bearing guesses;** verified by my own code read
  (not just its report). Committed to `cre/revaluation` — code only; build artifact gitignored; no
  `build/`/`docs/`/`contracts/` staged in the code commit; HEAD verified (no rogue commit). Ticket:
  `build/tickets/cre/CRE-01a-revaluation-sharded.md`. **Doc-sync:** no contract changed → no backward `wires/`
  edit; forward spec §8.1 + §8.11 edited (above). **NEXT remainder:** CRE-01b (controller underwriting — the
  headline) + CRE-01c (DefaultCoordinator action family).

- **KEEPER-01b own-later set CLOSED (2026-06-19, reviewer-driven) — out of MVP scope.** The B1 regime classifier
  + EMA, B2 keeper STATE store, and C1/C2/C3/C5 economic knobs (vote weights / lock-vs-sell split / `claimRebase`
  set / per-epoch volume cap) — the ve-allocation / regime / epoch-cadence machinery — are **not built out in the
  MVP** and are no longer build items. The shipped strike-loop core (with the level-based B3 taper/halt) is the
  whole of KEEPER-01b for M1. Rotation (D1) stays separately deferred to KEEPER-01c. Record:
  `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md` (rows struck through with a closeout note).

- **CRE-00 note (2026-06-19) — the (R)-track scaffold + the shared §8.0 `cre/zipreport` encoder package.** Head
  of the CRE report-path track; unblocks CRE-01/03/04. Two artifacts, both committed to the monorepo `cre/`
  (off-chain Go only — **NO contract changed**, so no backward `wires/` edit owed). **(1) `cre/zipreport/`** — a
  standalone, **SDK-free** module (`module cre-zipreport`; depends only on `go-ethereum/accounts/abi`+`common`,
  so it builds host AND `wasip1`) that is the single source of the §8.0 envelope `abi.encode(uint8 reportType,
  bytes payload)` + **all 18 per-`(receiver, reportType)` payload builders**, each pinned by a non-vacuous
  round-trip test to the EXACT filed-contract `abi.decode` tuple (controller origination/draw/close/status,
  registry revaluation, Nav legs, LP mark, DefaultCoordinator's 6-action inner-inner family, SzAlphaRate, the 4
  warehouse ops). Constants are grouped one `const` block per receiver so the cross-receiver numeral collisions
  (`NavLeg==7`/`LpMark==7`; `CoordinatorReportType==8`/`RateReportType==8`; warehouse `opType` 1-4) are explicit.
  CRE-01/03/04 import it instead of re-implementing the handshake (today `buyburn-bid`+`szalpha-rate` each
  duplicate it). **(2) `cre/scaffold/`** — the clone-me `wasip1` workflow template (`module cre-scaffold`;
  `replace cre-zipreport => ../zipreport`) demonstrating the SDK patterns the existing workflows do NOT: DON-only
  `GetSecret` (fail-safe/illustrative, §8.10 — never in node mode), `RunInNodeMode` + `ConsensusIdentical
  Aggregation[uint64]` over a deterministic observation, `runtime.Now()` ts-stamp, `zipreport.LpMarkReport` →
  `GenerateReport` → `WriteReport`, plus the `cre-templates` project files. **Harness loop ran:** 4 critics
  (junior-dev/spec-fidelity/reference-verifier/cre-binding). **cre-binding = ALL MATCH** (every reportType/field/
  type/envelope verified field-by-field against the filed `src/` decoders — zero mismatch). **reference-verifier**
  confirmed every SDK binding resolves (`cre.ParseJSON`, `wasm.NewRunner`, `GenerateReport`/`WriteCreReportRequest`,
  `RunInNodeMode`/`ConsensusIdenticalAggregation`, `cre.SecretRequest` alias, `cron.Trigger`/`cre.Handler`,
  `testutils`/`evmmock`, the go-ethereum native-type abi mapping incl. the uint32-native gotcha). **spec-fidelity =
  FAITHFUL** — no fidelity bug; flagged two spots where the ticket is MORE precise than the literal §8.0 table
  (it numbers the warehouse ops `1-4` from the filed constants, and omits the POST_BID/CANCEL_BID rows that
  CRE-OPS-ROUTING reassigned to the SHIPPED CRE-05a) — both fixed as reconciliation notes in the ticket before
  cold-build. **junior-dev** surfaced the load-bearing ambiguities (the `RunInNodeMode` carrier type, `GetSecret`
  namespace/seeding, go.mod/go.sum seeding, project-file fidelity) — ALL pinned in the ticket before cold-build
  (carrier = single `uint64` + ts from `runtime.Now()`; secret read fail-safe so the sim needs no seeded secret;
  seed go.mod/go.sum from `buyburn-bid` then `go mod tidy`; project files illustrative/not gate-checked). **Gate
  green (my own re-run, not just the cold-build's):** `cre/zipreport` → `go build && go vet && go test` (22 tests
  PASS) + `GOOS=wasip1 GOARCH=wasm go build` exit 0; `cre/scaffold` → host build/vet/test (3 sim tests PASS) +
  wasip1 build exit 0. **Cold-build returned ZERO load-bearing mechanism guesses;** its 3 reported items were
  verified structural resolutions: (a) builders that would collide with a same-named constant got a `…Report`
  suffix (`NavLegReport`/`LpMarkReport`/`Wh*Report`) — wire bytes/reportType unaffected; (b) a `//go:build
  !wasip1` no-op `main()` (`main_host.go`) so the literal `go build ./...` host gate links (the wasip1-tagged
  `main.go` leaves no host `main` — the same command exits 1 on `buyburn-bid`); (c) the seeded-secret test keys
  the empty namespace, verified against `testutils/runtime.go`. Committed to the monorepo `cre/` — code only; no
  `build/`/`docs/`/`contracts/` staged in the code commit. **Doc-sync:** no contract changed → no backward
  `wires/` edit; forward spec `claude-zipcode.md` §8.0 gains a "(BUILT — `cre/zipreport`, CRE-00)" note + the
  §8.11 CRE-00 row marked BUILT. Ticket: `build/tickets/cre/CRE-00-cre-scaffold.md`.

- **KEEPER-01b core slice note (2026-06-19) — the strike-loop harvest Job (the bulk of the remaining CRE-05).**
  The (K) keeper-track Job that drives the auto-compounder engine's `onlyOperator` legs (8-B5…8-B10) as ONE
  ordered `chain.Plan` on the `cre/keeper/` spine. Built per `build/tickets/cre/KEEPER-01b-strike-loop-job.md`.
  Leg order (load-bearing): `claimReward → borrow → exercise → sell → repay → creditFreeValue → [recycle →
  addLiquidity → stake]` (the bracketed deployment legs skip together when the recycle split is 0). Stateless
  single-Plan sizing — every scalar pre-computed from current reads + live quotes, NO cross-tick state (B2
  deferred); later legs use the deterministic effect of earlier ones (claim adds `pendingReward` oHYDX; exercise
  mints `amount` HYDX 1:1; recycle mints `usdc·1e12` zipUSD). Conservative floors throughout: `maxPayment =
  quoteStrike·1.02`, `minOut = liveQuote·0.98`, `minShares = ICHIformula·0.98`, `creditFreeValue` gets the
  guaranteed floor `minOut − maxPayment` (realized surplus ≥ it). No-op (empty Plan, fail-safe) on: unwired Safe,
  zero oHYDX, `P < haltPrice`, zero exercise room, `maxPayment > maxBorrowPerCycle`, or the profit gate `minOut ≤
  maxPayment`. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/keeper-binding).
  spec-fidelity = FAITHFUL (repay is a necessary cycle-close for the free-value-only invariant, not an invention;
  all A1–A4/B3/C4 constants match; own-later items B1/B2/C1–C3/C5/D1 correctly excluded). The fan-out's one
  load-bearing find was the `addLiquidity` `minShares` binding: the real ICHI `deposit()` share formula is NOT in
  the repo (only an interface stub) and the protocol deliberately treats `getTotalAmounts()` as manipulable
  (`IchiAlgebraFairReserves` uses TWAP). **RESOLVED** by reading the canonical `ICHIVault.deposit` source: the
  keeper replicates it EXACTLY (`shares = deposit·min(spot,twap)·totalSupply / (pool·max(spot,twap) + pool1)`),
  spot from the LP pool `globalState()`, TWAP-mean tick via the oracle plugin `getTimepoints` (the repo's
  `IchiAlgebraFairReserves._meanTick` logic), `getSqrtRatioAtTick` ported from `ConcentratedLiquidity.sol` and
  unit-tested against UniV3 vectors — a true conservative floor, zero guess. The HYDX price (A1) uses the pool
  `globalState()` sqrtPrice directly (`out = in·sqrtP²/2¹⁹²`, 6dp) — **no Algebra QuoterV2 address needed**, so the
  PROGRESS "build-time verify the QuoterV2 address" item is MOOT. **Built:** `cre/keeper/internal/quote/`
  (`Quoter` seam + `ProdQuoter` + ported TickMath), `internal/job/strike_loop_job.go`, additions to
  `internal/chain/{encode,read}.go` (multi-uint packer + `globalState`/two-uint decoders) + `internal/config`
  (StrikeLoop knobs, `MustMaxBorrowPerCycle`) + `cmd/keeper/main.go` (register after BurnJob; 6-module startup
  identity check). **Gate green (my own re-run, not just the cold-build's):** `cd cre/keeper && go build ./... &&
  go vet ./... && go test ./...` = all pass (44 tests; chain/config/job/keymgr/quote). Tests are non-vacuous: the
  table-driven `strike_loop_job_test.go` (12 funcs) decodes every leg's calldata and asserts the scalar args +
  ordered labels (9-leg happy path, 6-leg recycle-skipped, each no-op gate, maxSell cap, amber taper, profit
  gate, P==amber boundary, minShares==0); `quote_test.go` asserts the price/share math (TickMath vectors,
  decimals-correct `HydxToUsdc`, `ZipToShares` worse/better selection); a combined recorder probe
  (`StrikeLoopProbe.sol`, forge/solc 0.8.24, bytecode const) runs the full Job through the `Runner` and asserts
  the ordered `(selector,args)` of all 9 legs over a real EVM. Cold-build returned ZERO load-bearing guesses.
  Committed to `cre/keeper` (16f15cc) — code only; no `build/`/`docs/`/`contracts/` staged. **KNOWN LIMITATION
  (logged as the follow-up in NEXT):** the restake leg hardcodes the recycled zipUSD as the vault's **token0**
  (`addLiquidity(deposit0=zip, 0, minShares)`); if zipUSD deploys as token1 the `addLiquidity` leg fail-safe
  reverts (recycle + all extraction legs still land, freeValueAccrued spent, zipUSD sits backed in the Safe) —
  liveness-only, never unsafe. ~~Generalize to the token1-side branch in the own-later restake follow-up.~~
  **RESOLVED 2026-06-19 by KEEPER-01b-R1 (note below).**
  **Doc-sync:** NO contract changed this window → no backward `wires/` edit owed; `claude-zipcode.md` §8.7 gains a
  one-line "(core slice BUILT — KEEPER-01b)" note; the ratified policy record + §8.7 block (the reviewer's
  2026-06-19 ratification) land in the same docs commit.

- **KEEPER-01b-R1 note (2026-06-19) — the restake leg is now side-aware (resolves the core-slice KNOWN
  LIMITATION above).** The core slice hardcoded the recycled zipUSD as the LP vault's **token0**
  (`addLiquidity(expectedZip, 0, minShares)`, and `ZipToShares` priced the token0 side). ICHI vault token
  slotting is by ADDRESS SORT, fixed at pool creation — so if zipUSD's deployed address sorts ABOVE xALPHA's,
  zipUSD is **token1** and the leg fail-safe reverted (recycle landed, restake skipped). Now the deposit side
  follows the live slotting. **Off-chain Go only — NO contract changed** (no backward `wires/` edit owed).
  Three changes, all in `cre/keeper`: (1) `internal/quote/quote.go` — `Quoter.ZipToShares` returns the side
  flag (`(shares, zipIsToken0, err)`); the production `ProdQuoter` resolves the recycled zipUSD each tick off
  `recycle.zipDepositModule()` → `zdm.zipUSD()` (both confirmed public getters: `RecycleModule.sol:80`,
  `ZipDepositModule.sol:50` `address public immutable zipUSD`) and sets `zipIsToken0 = (zipUSD == vault.token0())`,
  erroring loudly if zipUSD matches NEITHER vault token (a bad re-point); `ichiSingleSidedShares` now selects
  the numerator by side — `depositZip·min(price,twap)/1e18` for token0, **raw `depositZip`** for token1 (already
  in token1 terms — the unconditional token0-pricing was the bug). The denominator + the `price`/`twap`
  direction (ALWAYS token0→token1) are side-independent and unchanged. (2) `internal/job/strike_loop_job.go` —
  the Job builds `addLiquidity(expectedZip, 0, minShares)` when `zipIsToken0`, else `(0, expectedZip, minShares)`;
  KNOWN-LIMITATION comment block deleted. (3) tests updated to the new signature + new token1-side/neither-match
  coverage. **Side-resolution lives behind the `Quoter` seam, so the sim probe needed ZERO change** (the sim
  injects a `fakeQuoter` carrying a configurable `zipIsToken0`); the `StrikeLoopProbe` bytecode is byte-identical.
  **NOTHING else changed** — leg order, no-op gates, taper/halt, profit gate, and every scalar (exerciseAmount…
  expectedZip/minShares/stakeAmount) are untouched (restake-side routing ONLY). §17 honored: the side is
  re-read each tick, never cached. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/
  keeper-binding). spec-fidelity = FAITHFUL (single-sided `addLiquidity` on either side is the EXISTING §8.7
  mechanism — no invention; the per-tick side re-read is §17-correct; no scalar/leg-order change). reference-
  verifier = all 6 bindings resolve against live source (`zipDepositModule()`, `zipUSD()`, `token0()/token1()`,
  `addLiquidity` symmetric single-sided, `chain.CallAddress`, and the recycle→zdm→zipUSD trace). keeper-binding =
  the token1 numerator (raw, un-priced) is the correct algebraic consequence of the canonical ICHI formula; the
  price/twap direction must NOT flip (confirmed). junior-dev surfaced the load-bearing TICKET gaps — ALL fixed
  BEFORE cold-build: the "assert `numerator == depositZip`" acceptance (numerator is an unexported local →
  rephrased to a shares-level assertion); the concrete `ProdQuoter` signature; the stale `quote.go` doc comment
  + `depositSide0`→`depositZip` rename; and "update ALL existing `quote_test.go` callers + the scripted reader's
  two new getters." **Gate green (my own re-run, `-count=1`, not just the cold-build's):** `cd cre/keeper &&
  go build ./... && go vet ./... && go test ./...` — all pass (quote + job suites). Tests are non-vacuous: the
  Job token1 case decodes the `addLiquidity` calldata and asserts `(0, expectedZip, minShares)`; the quote tests
  recompute the share math independently and PROVE the token1 (raw) result differs from the token0 (priced)
  result when `price≠twap`, plus the neither-match error. Cold-build returned ZERO load-bearing guesses; no
  rogue commit (verified HEAD). Committed to `cre/keeper` — code only; no `build/`/`docs/`/`contracts/` staged in
  the code commit. **Doc-sync:** NO contract changed → no backward `wires/` edit; forward `claude-zipcode.md` §8.7
  the own-later "restake token1-side" item is now a "(BUILT — KEEPER-01b-R1)" side-aware note. Ticket:
  `build/tickets/cre/KEEPER-01b-R1-restake-token1-side.md`.

- **CTR-08 note (2026-06-19) — structure-2 revolving, zero contract change.** Resolved Key-req #5: NO new contract is
  needed. A revolving line is the same stack (`ZipcodeController` + `EulerVenueAdapter` + `ZipcodeOracleRegistry` +
  `CREGatingHook` + `LienCollateralToken`) driven in a different MODE — open ONCE, then borrow -> permissionless
  repay -> redraw on the SAME open line / oracle key / EE slot; the CRE just never files `RT_CLOSE` until
  disqualification. Corrected disqualification mechanism: the per-revolution on-chain gate is **LTV x the mark VALUE**
  in the draw report (a too-low mark reverts `E_AccountLiquidity`), NOT mark lapse — `_draw` re-seeds a fresh mark
  before borrowing, so a stale mark cannot block a draw, and un-hooked repay never quotes. Binary disqualification is
  OFF-CHAIN (CRE declines to file `RT_DRAW`); the optional on-chain per-account hook flag is unbuilt/optional for M1.
  Shipped: 5 revolving tests in `test/ZipcodeController.t.sol` + a forced precondition fix (extended that file's
  `MockEulerEarn` with the CTR-04 withdraw-queue surface `closeLine` calls — the 6 close-path tests were RED on main
  after CTR-04 updated only the faithful mock). Suite now 39/39 green. Doc: `docs/wires/CTR-08-structure-2-revolving.md`.
  **Regression confirmed ISOLATED:** of the 3 suites exercising the `closeLine` withdraw-queue path, the other two
  were already green (`EulerVenueAdapter.t.sol` 39/39 — CTR-04 updated its faithful mock; `FarmUtilityLoopModule.t.sol`
  41/41 — CTR-07 ported that mock); only `ZipcodeController.t.sol` (its own simpler `MockEulerEarn`) was the casualty.
  **Process lesson:** a per-match-path Conclude gate that verifies only the OWN suite can leave another suite's
  homegrown mock stale + RED uncaught (CTR-04 verified `EulerVenueAdapter.t.sol`, not the controller suite). When a
  `src/` contract gains a new external-call surface, grep ALL suites with a homegrown mock of the called contract and
  re-run them, not just the touched suite.

- **CTR-09 note (2026-06-19) — the 0.1%-per-revolution protocol draw fee.** Resolves **finding 2**. Modified
  `contracts/src/venue/EulerVenueAdapter.sol` + `contracts/test/EulerVenueAdapter.t.sol` (no new files → no
  `COVERAGE.md` row change). The fee is levied in the **adapter's borrow path** (NOT the controller — it holds no
  USDC; drawn USDC crosses to the off-chain Erebor rail the moment it's borrowed, so the borrow point is the ONLY
  on-chain-enforceable levy site). `draw` now appends a **fourth EVC borrow leg** `IBorrowing.borrow(fee,
  feeRecipient)` on the SAME `borrowAccount` as the principal, where `fee = amount * feeBps / 10_000` (round-DOWN),
  ONLY when `feeRecipient != address(0) && fee != 0`. **Financed-fee model:** line debt = `amount + fee`, the
  borrower repays both; the principal leg keeps the hardcoded `erebor` receiver (F2 intact), only the fee leg's
  receiver differs. New slots `feeRecipient` (default `address(0)` = OFF) + `feeBps` (inline `= 50` = 0.50%, NOT a ctor arg —
  a ctor arg would break `MisWiringAdapter`'s super-call) + `MAX_FEE_BPS = 500`; Timelock setters `setFeeRecipient`
  (accepts `address(0)`, the disable sentinel, so it omits the `ZeroAddress` guard) / `setFeeBps` (reverts
  `FeeTooHigh` above the cap); new error `FeeTooHigh`, new events `FeeSet(uint16)` (bps can't reuse `WiringSet`, whose
  2nd param is `address`) + `FeeLevied(lineRef, fee)` (emitted ONLY when the leg fires). **Harness loop ran:** 4
  critics (junior-dev/spec-fidelity/reference-verifier/contract-binding). **spec-fidelity = FAITHFUL** (the fee is a
  PROGRESS-workstream EXPANSION, not spec-invention; draw-only is correct — close is a full repay→burn, no borrow leg
  to levy on; the spec has zero symmetric-fee language; §17 + F2 honored). **contract-binding = ZERO back-pressure**
  (the `CREGatingHook` is op-agnostic/stateless/account-keyed → the fee leg passes the hook exactly as the principal;
  F2 pins the FUNCTION ARG, not the per-leg receiver, so the fee leg's distinct `feeRecipient` trips nothing; the
  LTV-ceiling-revert-once-fee-added is intended financed-fee semantics = a CRE draw-sizing constraint, not a gap).
  **reference-verifier** confirmed all bindings resolve (`IBorrowing.borrow(uint256,address) returns (uint256)` @
  `IEVault.sol:234`; `IEVC.BatchItem`+`batch` @ `IEthereumVaultConnector.sol:12-23,355`; two borrows on one account in
  one batch are valid — the deferred status check set-dedups to ONE end-of-batch check on `amount+fee`,
  `EthereumVaultConnector.sol:696-702,916-920`; and that `feeBps`-as-uint **cannot** reuse `WiringSet(bytes32,address)`
  → forced the `FeeSet` event). **junior-dev** found the load-bearing TICKET gaps — ALL fixed in the ticket BEFORE
  cold-build: (1) the most-blocking — whether `feeRecipient`/`feeBps` are wired in `setUp` (would flip the existing
  `debtOf == drawAmount` assertions to `+ fee` and break the green suite) or local-only → **pinned default-OFF +
  local-per-test wiring**; (2) names/events/error pinned (not invented); (3) the `fee == 0` dust case → guard on
  `fee != 0` (never a `borrow(0,..)` leg); (4) `feeBps` seeding via inline initializer (ctor-arg blast radius on
  `MisWiringAdapter`); (5) close-fee conditional resolved to draw-only; (6) stale line numbers refreshed in "Binds to".
  Gate green (verified by my own re-run, not just the cold-build's): `forge build` exit 0 + `forge test --match-path
  test/EulerVenueAdapter.t.sol` = **46 passed / 0 failed** (40 pre-existing all still green — proves default-OFF — + 6
  new: fee-on (debt==amount+fee, recipient credited, erebor gets exactly amount, `FeeLevied` emitted), per-revolution
  (second draw levies again), no-op (feeBps==0/recipient unset → 3-item batch), dust (fee rounds to 0 → no leg),
  setter gating/cap/sentinel/events, F2-intact-with-fee-on). **Cross-suite re-run (CTR-08 process lesson — every suite
  that drives the adapter `draw`):** `ZipcodeController.t.sol` **39/39** (the CTR-08 revolving draws, default-OFF →
  byte-identical) + `FarmUtilityLoopModule.t.sol` **41/41** — no regression. Cold-build returned ZERO load-bearing
  guesses. Ticket: `build/tickets/contracts/CTR-09-per-revolution-fee.md`. **Doc-sync:** modified contract → backward
  wire `docs/wires/WOOF-04.md` (`draw` entry now enumerates the optional 4th fee leg + the financed-fee/F2/hook/
  default-OFF semantics + the fee setters/events). Forward spec `claude-zipcode.md` §5 gains a "Per-revolution draw
  fee (BUILT — CTR-09)" note (distinct from the EulerEarn perf-fee). No `COVERAGE.md` row change (no new file).
  **Unblocks protocol revenue → treasury `feeRecipient`** (the deploy must `setFeeRecipient(adminSafe)` to turn it
  on — default OFF ships safe).
  **Fee calibration (dartboard 2026-06-19, reviewer-driven):** default `feeBps` set to **50 bps (0.50%)** — NOT the
  original 0.1%. Anchored to market comps researched this session: bank warehouse lines SOFR+2.25–3.25% (~6–7%),
  one-time origination 0.5–1.0% (Maple 0.5–1%), consumer HELOC ~7.5–8.5% (Bankrate June 2026), securitized HELOC pool
  WAC ~10.9% (Angel Oak). Since each revolution is a fresh origination (warehouse → secondary take-out → redraw) the
  origination-scale fee is charged per draw; ~6mo secondary-market seasoning bounds velocity to ≤4 turns/yr
  (≤quarterly), so 50 bps ≈ ≤2%/yr of drawn volume. Re-address with observed velocity. **The time-based APR is
  separate** — built later as CTR-13: the per-line vaults now run a real flat ~7.5% `IRMLinearKink` (the farm utility
  stays `ZeroIRM`). See the CTR-13 DONE note below. Tests made default-robust
  (read `adapter.feeBps()`; dust amount = `10_000/feeBps - 1`) + a `feeBps == 50` default assertion; gate re-run green
  (adapter 46/46, controller 39/39, farm utility 41/41).

- **CTR-12 note (2026-06-19) — rename `capitalSink` → `adminSafe` (loss-side recovery destination).** Pure rename,
  ZERO behavior change. The slashed-bond capital-hole destination is now explicitly named the protocol **treasury
  Safe** (the recovery custody bridging xALPHA → TAO → USDC, §11), closing the PROGRESS-433 "designate the real safe"
  item at the NAMING level (Safe creation + bridge process stays M2 ops). **The draft's enumerated surface was STALE**
  — CTR-06b/06c (built earlier this session) had added `capitalSink` to `script/SiloDeployer.s.sol` +
  `script/JuniorTrancheDeployer.s.sol` (Params field + ctor pass) and `test/{SiloDeployer,JuniorTrancheDeployer,
  DefaultCoordinator}.t.sol`; I re-grepped the LIVE tree (not the draft) and swept them all in to satisfy Key-req #2
  (zero `capitalSink` left). Renamed 3 case variants: `capitalSink`→`adminSafe` (slot/var/field/getter), `setCapitalSink`
  →`setAdminSafe`, `CAPITAL_SINK`→`ADMIN_SAFE` (env), `WiringSet` label `"capitalSink"`→`"adminSafe"`, test
  `test_ctor_zero_capitalSink_reverts`→`..._adminSafe_reverts`; natspec/comments name it "the protocol treasury
  Safe". `slashXAlphaToCapital`/`SlashedToCapital`/RecycleModule "capital hole" prose UNTOUCHED (Do-NOT honored).
  **Gate green — FULL suite** (not just touched paths: the public getter `capitalSink()→adminSafe()` is an ABI
  change, so per the CTR-08 process lesson I re-ran everything): `forge build` exit 0 + `forge test` = **920 passed /
  0 failed / 3 skipped (56 suites)** — byte-identical to the CTR-10b baseline, proving behavior-neutrality. `grep -rni
  capitalsink|capital_sink` over `src`/`script`/`test`/`docs` = NONE. **Doc-sync:** backward wires
  `docs/wires/8-Bx-LienXAlphaEscrow.md` (slot/setter/WiringSet-label/4-arg-ctor/destination prose), `DefaultCoordinator.md`,
  `DeployZipcode.md` (`ADMIN_SAFE` env), `8-B10-RecycleModule.md`; `docs/loss.md` was already on "treasury Safe".
  No `COVERAGE.md` change (no new file). No `claude-zipcode.md` edit (§11/§17 unchanged — the slot was never spec-named).
  Ticket: `build/tickets/contracts/CTR-12-rename-capitalsink-treasurysafe.md`. **Process note:** a draft ticket's
  "Binds to (verified)" grep set goes STALE when sibling tickets land between authoring and build — always re-grep the
  live tree at build time, never trust the enumerated set.
  **DEPLOY OBLIGATION (CTR-12):** set `ADMIN_SAFE` to a **real Gnosis Safe** at deploy. The `LienXAlphaEscrow`
  ctor only reverts on `address(0)` (doesn't enforce Safe-ness), but the live deploy must wire a real Safe — it is
  the custody that holds slashed xALPHA and runs the off-chain xALPHA→TAO→USDC bridge. Today it's a placeholder
  (`ANVIL_5` locally / the `ADMIN_SAFE` env var on mainnet). The slot is dormant in M1 (only `slashXAlphaToCapital`
  touches it; the slash path isn't active until the `DefaultCoordinator` drives it).

---

## Credit-warehouse scaling + federation substrate (contract track — NEXT = CTR-02)

> **Contracts are being EXPANDED here** — this workstream supersedes harness.md's "the contract stack is done,
> only CRE/FE remain" framing for these items. They are contract-track tickets (forge-test gate), like CTR-01.
> Tickets: `build/tickets/contracts/CTR-02..CTR-10`. Design blueprint authored 2026-06-18.

**The problem.** Today is "configuration one": one controller → one `EulerVenueAdapter` → one EulerEarn pool → one
warehouse → one junior → one zipUSD. A pool caps at `MAX_QUEUE_LENGTH = 30` markets
(`reference/euler-earn/src/libraries/ConstantsLib.sol:17`, binding on the withdraw queue `EulerEarn.sol:785`); with
2 permanent non-line markets (resting USDC + farm utility) → **28 concurrent lines/pool**. Goal: scale past one pool
AND make the same mechanism a federation substrate under one mutualized senior zipUSD, carrying BOTH repurchase
lines (structure 1, the safe HELOC-warehouse standard) and insurance-underwritten revolving lines (structure 2).

**Locked decisions (2026-06-18 — do not reopen):**
- A silo = one full stack `{venue adapter + warehouse + EE pool + junior tranche}`; replicate the silo, keep
  zipUSD/mint/redeem at the hub. Loss is local to a silo's junior; senior is mutualized (only post-junior residual
  reaches zipUSD).
- **Split slot 2:** no-borrow resting market + separate farm utility vault, funded JIT via a new allocator
  fund/defund path (re-absorbed on repay). 28 lines/pool; allocator key ≠ farm utility operator key.
- **Accommodate BOTH** line structures; repo is the safe default, revolving is for when an insurance policy exists.
- **Sequential-fill sharding:** fill the active pool to 28 → deploy next EE vault → route there → register.
- Open decisions carried into tickets: **A** single controller + registry (chosen) over per-silo (CTR-03);
  **B** fix `closeLine` to reclaim the binding slot (chosen) (CTR-04); **C** ship CTR-02..09 first, CTR-10 later.

**Verified findings (obligations — discharge in the tickets):**
1. **RESOLVED 2026-06-18 (CTR-04, below).** `closeLine` reclaimed only the SUPPLY queue; the **binding
   withdraw-queue slot was never freed** (`EulerVenueAdapter.sol:415-423`) → a pool bricked after ~28 *lifetime*
   opens. CTR-04 added the inline withdraw-queue reclaim (`submitCap(0)` + `updateWithdrawQueue`); a pool now churns
   28 *concurrent* lines. Removal of the (defunded) empty market is timelock-independent, so no `submitMarketRemoval`/
   reap step was needed — the `EulerEarn.sol:362` two-step path is dead code for an empty market.
2. **RESOLVED 2026-06-19 (CTR-09, below).** The 0.1%-per-revolution fee was unimplemented on-chain (only EE yield
   fee, buy-burn discount, oracle bands). CTR-09 added it as a fourth EVC borrow leg in `EulerVenueAdapter.draw`
   (`borrow(fee, feeRecipient)`, `fee = amount*feeBps/10_000`, default 50 bps = 0.50%, Timelock-settable, capped 5%) —
   the only on-chain-enforceable levy point (controller holds no USDC; drawn USDC crosses to Erebor immediately).
   Financed-fee (debt = `amount + fee`), default OFF until `feeRecipient` wired. Re-fires per draw → per-revolution.
3. **RESOLVED 2026-06-19 (CTR-07, below).** Slot-2 revolving was half-wired: the farm utility borrow/repay cycled, but
   no `reallocate` funded it from resting or re-absorbed after repay. CTR-07 added `fundFarmUtility`/`defundFarmUtility`
   (`onlyFarmUtilityAllocator`) — the per-line `fund`/`closeLine` reallocate pattern generalized to the farm utility.
4. Farm utility borrow is pinned to `juniorTrancheEngine` (`FarmUtilityBorrowGuard.sol:91-92`) + capped (`borrowCap`, Timelock)
   — not externally exploitable; residual is internal contention vs senior redemption liquidity (informs CTR-07).
5. Structure-1's per-lien oracle is an n→∞ keyed cache; structure-2 keys the line to a borrower → one persistent
   key (`ZipcodeOracleRegistry` hosts both meanings unchanged). **→ CTR-08.**

**Cross-ticket obligations:** CTR-03 depends on CTR-02; CTR-05 on CTR-02; CTR-06 on CTR-02/03/05 (+CTR-07 wiring);
CTR-08/09 compose with CTR-03/07; CTR-10 on CTR-02..09. **Deploy-wiring:** every silo's
`WarehouseAdminModule.redemptionBox` → the ONE shared `ZipRedemptionQueue` (fungible senior; redemption drains any
warehouse). **§11 non-commingling assert** at silo deploy (`redemptionBox != juniorSafe`, `warehouseSafe != juniorSafe`).

**Ledger (build order):**
- **CTR-02** `SiloRegistry` — silo set + admission gate + slot accounting. **DONE 2026-06-18** (below). *(leaf)*
- **CTR-03** `ZipcodeController` siloId routing over the registry. **DONE 2026-06-18** (below). *(dep CTR-02)*
- **CTR-04** `closeLine` withdraw-queue reclaim (finding 1). **DONE 2026-06-18** (below). *(independent; paired with
  CTR-03's decrement — the binding withdraw-queue slot is now physically freed on close, so the registry counter and
  the actual queue length stay consistent; concurrent slot-accounting is now SOUND)*
- **CTR-05** `SeniorNavAggregator` (donation-immune Σ). **DONE 2026-06-18** (below). *(dep CTR-02)*
- **CTR-06** `SiloDeployer` — **RE-SCOPED 2026-06-18 into a 3-way split** (could not cold-build to zero guesses as one
  ticket; see the re-scope note in NEXT + the index `CTR-06-silo-deployer.md` with the pinned hub/silo decomposition +
  open decisions D1–D5). Children:
  - **CTR-06a** `FarmUtilityMarketDeployer` borrow-vault `setGovernorAdmin` fix (discharges FE-07 Finding A).
    **DONE 2026-06-19** (note below). *(was independent)*
  - **CTR-06b** `JuniorTrancheDeployer` (the missing reusable per-junior artifact, analogue of
    `CreditWarehouseDeployer`; excludes `OffRampModule` per D5). **DONE 2026-06-19** (note below; D1+D5 ratified). *(was dep CTR-06a)*
  - **CTR-06c** `SiloDeployer` orchestrator + feasible mock-EE two-silo routing test (D3/D4). **DONE 2026-06-19** (note
    below). *(dep CTR-06a + CTR-06b, both DONE)* — the re-scoped CTR-06 is now COMPLETE (06a+06b+06c all landed).
- **CTR-07** slot-2 farm utility fund/defund (finding 3; the split-slot decision). **DONE 2026-06-19** (note below).
  *(independent)*
- **CTR-08** structure-2 revolving credit-approval line (finding 5). *(dep 02/03; composes 07/09)*
- **CTR-09** 0.1%-per-revolution fee (finding 2). **DONE 2026-06-19** (note below). *(dep 03; composes 08)*
- **CTR-10** federation generalization — **RE-SCOPED 2026-06-19 into a 3-way split** (4-critic fan-out: can't
  cold-build as one ticket). Children:
  - **CTR-10a** `ISeniorPool` extract + no-op re-type of the senior read (`SeniorNavAggregator` +
    `DurationFreezeModule`). **DONE 2026-06-19** (note below). *(dep CTR-05)* — the structural §4.7 generalization.
  - **CTR-10b** the federation HOST SEAM — venue-agnostic `addSilo` admission (`ISeniorVenue.seniorPool()` getter
    + `eePool` re-cast as the generic `ISeniorPool` surface + plug-in recipe + proof test). **DONE 2026-06-19**
    (note below). *(dep CTR-10a)* — RESOLVES obligation #3 (reuse `eePool`, no new field). A future venue adapter
    now plugs in with NO registry change.
  - **CTR-10c** the reference non-Euler adapter + `ISeniorPool` wrapper + fork test. **BACK-PRESSURE / DEFERRED
    (P5)** — build only when a second venue is actually wanted. Design recorded in `docs/venue.md` (the federation
    section). Full deferred spec preserved here (the `CTR-10-federation-iseniorpool.md` ticket was DELETED 2026-06-19
    after CTR-10a/b landed; git retains the original text):
    - **Blocker #1 — no bindable non-Euler senior surface on the Base fork (block 47096000).** `BaseAddresses.sol`
      has zero Aave/Morpho/MetaMorpho/Centrifuge addresses. Reference clones are un-deployed (`moneymarket-contracts`
      USD3 is 4626 source but no Base deployment), async (`centrifuge`/`erc7540-reference` — request/claim, not a
      synchronous `maxWithdraw`), or non-4626 id-keyed (`moneymarket` Morpho.sol). Binding a real adapter means
      first deploying a reference vault into the fork OR guessing an address — both fail the zero-guess gate.
    - **Blocker #2 — the venue is unchosen.** Aave v4 (not live) vs MetaMorpho (4626) vs an orderbook (neither) are
      mutually-exclusive integrations; picking one is itself a load-bearing decision deferred to P5.
    - **Blocker #4 — donation-immunity is a property of the real venue, not the interface.** A mock hardcodes
      immunity and proves nothing about the real venue's `convertToAssets`/`maxWithdraw` skewability; the per-venue
      fork test genuinely needs a chosen, deployed venue. (Obligation #3 — the senior-surface plumbing — was RESOLVED
      by CTR-10b: reuse `eePool` as the generic `ISeniorPool` read, no new struct field.)
    - **Done-when (gate):** `forge build` green; a fork test stands up a non-Euler silo, registers it via
      `SiloRegistry.addSilo`, opens a line through it, shows `SeniorNavAggregator` aggregating it donation-immune,
      and proves a default in it marks ONLY its own junior. Cold-build with ZERO load-bearing guesses.
    - **Carry-over:** the §11 non-commingling deploy assert (`redemptionBox != juniorSafe`, `warehouseSafe != juniorSafe`)
      must be NAMED in the admission gate's done-when so a non-4626-wrapper silo cannot silently drop it.
    *(dep CTR-10b; LATER / P5)*

**Spec sync (forward, NOT a precondition):** each ticket is the complete, self-sufficient build instruction (it
cold-builds from the ticket alone). `build/claude-zipcode.md` is the intent reference; it gets a Conclude-step
doc-sync to *reflect* the federation / structure-2 / fee design once built (like the `wires/` sync) — nothing is
owed to the spec before CTR-02 can run.

> **CTR-10a — `ISeniorPool` extract: the venue-neutral senior-read generalization — DONE 2026-06-19.** The
> buildable, zero-guess half of the re-scoped CTR-10 (the §4.7 structural generalization). A pure interface
> extract + no-op re-type. Added `contracts/src/interfaces/supply/ISeniorPool.sol` (the three donation-immune
> views `{maxWithdraw, convertToAssets, balanceOf}` — the exact selector set of the deleted `IEulerEarnUtil`,
> now named for the federation seam so ANY venue's senior surface can satisfy it); re-typed the only two `src`
> readers `SeniorNavAggregator._seniorValue`/`_illiquidValue` and `DurationFreezeModule.utilization`/
> `illiquidSeniorValue` from `IEulerEarnUtil(...)` → `ISeniorPool(...)`; DELETED the orphaned
> `src/interfaces/euler/IEulerEarnUtil.sol`. **The `DurationFreezeModule.eulerEarn` storage slot name is RETAINED**
> (renaming ripples into `SiloRegistry`'s `IFreeze(freeze).eulerEarn()` topology assert — that is CTR-10b scope);
> only the read interface is generic. **Harness loop ran on the parent CTR-10:** the same 4-critic fan-out
> (junior-dev/spec-fidelity/reference-verifier/contract-binding) that produced the re-scope verified this half is a
> genuine no-op — `ISeniorPool` is the exact selector-subset of `IEulerEarnUtil`, so the cast change emits
> byte-identical calldata for the Euler silo (contract-binding critic = SOUND; reference-verifier confirmed both
> readers + the deleted file's 3 views). spec-fidelity = FAITHFUL (no invention; the federation §-sync stays
> forward-deferred; §17 honored). Gate green (verified by my own full-suite re-run, not just a targeted match):
> `forge build` exit 0 + `forge test` = **919 passed / 0 failed / 3 skipped (56 suites)** — the no-op proof; the
> `SeniorNavAggregator.t.sol` (18/18) and DurationFreeze suites pass unchanged. Cold-build returned ZERO
> load-bearing guesses (a verified-equivalent re-type). Ticket: `build/tickets/contracts/CTR-10a-iseniorpool-extract.md`.
> **Doc-sync:** the catalog row moved euler→supply (`COVERAGE.md`, count stays 31); `interfaces-euler.md`
> (`IEulerEarnUtil.sol` marked REMOVED + folder now 2 files), `interfaces-supply.md` (new `ISeniorPool` section),
> `CTR-05-SeniorNavAggregator.md` + `DurationFreezeModule.md` (read now via `ISeniorPool`). No `claude-zipcode.md`
> edit (invisible at the spec level — no mechanism change). **Unblocks CTR-10b** (a non-Euler venue's senior
> surface now reads/wraps to `ISeniorPool`).

> **CTR-10b — Federation host seam: venue-agnostic admission (the plug-in point) — DONE 2026-06-19.** The
> host-side half of CTR-10 — makes `SiloRegistry` admission + the senior-read path venue-agnostic so a FUTURE
> non-Euler venue adapter plugs in with NO host change. RESOLVES CTR-10 obligation #3 (the senior-surface
> plumbing decision). Modified `contracts/src/venue/EulerVenueAdapter.sol` (+`seniorPool()` view returning
> `address(eulerEarn)`), `contracts/src/SiloRegistry.sol` (renamed local `IAdapter`→`ISeniorVenue { seniorPool() }`;
> the `addSilo` adapter clause now asserts `ISeniorVenue(adapter).seniorPool() == eePool` instead of the
> Euler-specific `eulerEarn()`; `eePool` re-documented as the generic `ISeniorPool` senior-read surface; added a
> "VENUE-AGNOSTIC ADMISSION" plug-in recipe to the NatSpec), and 4 test mock-adapter stubs (`eulerEarn`→`seniorPool`
> in `SiloRegistry.t.sol`/`SeniorNavAggregator.t.sol`/`SiloDeployer.t.sol`/`JuniorTrancheDeployer.t.sol` — the
> `MockFreeze` stubs keep `eulerEarn()`, the freeze clause is unchanged). **The obligation-#3 decision: REUSE
> `eePool` as the read surface — NOT a new `seniorRead` field** (the critics' "Option B" would have rippled into
> the CTR-02 struct, the `addSilo` writer, the `ZeroAddress` check, and every `SiloConfig` caller; reusing `eePool`
> is zero struct change / zero caller churn — a non-4626 venue sets `eePool` = its wrapper, the freeze clause
> already compares to `eePool`, the aggregator already reads it via `ISeniorPool` from CTR-10a). The `seniorPool()`
> getter lives on the concrete adapter, NOT on `IZipcodeVenue` (the seam stays senior-surface-free, §4.7). **Built
> directly with full-suite verification** (I already had the 4-critic grounding from the CTR-10 fan-out; every
> binding was confirmed against live source this window — the only genuinely venue-specific piece, the actual
> `IZipcodeVenue` adapter for a real venue, is correctly deferred to CTR-10c). New proof test
> `test_ctr10b_nonEuler_venue_plugs_in` (`SeniorNavAggregator.t.sol`): a venue stand-in with `seniorPool()` and NO
> `eulerEarn()` admits + aggregates donation-immune (the admission SUCCEEDING is the venue-neutrality proof; a
> staticcall confirms the adapter has no `eulerEarn()`). Gate green (my own full-suite re-run): `forge build` exit 0
> + `forge test` = **920 passed / 0 failed / 3 skipped (56 suites)** (the +1 vs CTR-10a is the new test); the 6
> silo/aggregator/deployer suites = 140/140. **Doc-sync:** modified contracts → backward wires `docs/wires/WOOF-04.md`
> (new `seniorPool()` view entry) + `docs/wires/CTR-02-SiloRegistry.md` (the `ISeniorVenue` local interface row,
> clause-6 rewrite, the `eePool`-as-senior-surface note + the plug-in recipe). No `COVERAGE.md` row change (no new
> file). No `claude-zipcode.md` edit (the host seam removes an Euler hardcode — invents no mechanism; the federation
> §-sync stays forward-deferred for CTR-10c). Ticket: `build/tickets/contracts/CTR-10b-federation-host-seam.md`.
> **Unblocks CTR-10c** (a real non-Euler adapter now plugs in with no host change; still gated on a chosen/deployed
> second venue).

> **CTR-07 — Slot-2 farm utility fund/defund: the revolving junior yield facility — DONE 2026-06-19.** Discharges
> **finding 3**. Modified `contracts/src/venue/EulerVenueAdapter.sol` + `contracts/test/FarmUtilityLoopModule.t.sol`
> (no new files → no `COVERAGE.md` row change, no regression on untouched contracts). Added two adapter-LOCAL methods
> `fundFarmUtility(uint256)` / `defundFarmUtility(uint256)` (`onlyFarmUtilityAllocator`) — the per-line `fund`/`closeLine`
> reallocate pattern generalized to move idle USDC resting↔farm utility JIT, so the farm utility holds ≈0 at rest (split-slot
> decision). Each is a two-item absolute-target zero-sum `eulerEarn.reallocate` between `usdcReservoir` and a new
> `farmUtilityVault` slot, sized off `_eeSupplyAssets` (donation-immune, NOT `balanceOf`). Plus two Timelock-settable
> wiring slots `farmUtilityVault`+`farmUtilityAllocator` (`setX`+`WiringSet`), a `NotFarmUtilityAllocator` error, and the
> `onlyFarmUtilityAllocator` modifier. NOT on `IZipcodeVenue` (venue interface stays line-only). **Harness loop ran:** 4
> critics (junior-dev/spec-fidelity/reference-verifier/contract-binding). The contract-binding critic CONFIRMED **ZERO
> back-pressure** — the mechanism binds entirely to surfaces that exist today: (a) the farm utility vault is already an
> enabled NON-supply-queue EE market (`DeployLocal.s.sol:140-141` acceptCap's it; supply queue = `[usdcReservoir]`
> only), so it is reallocate-eligible; (b) its hook is **OP_BORROW-only**, so EE's reallocate deposit/withdraw legs
> into it are un-hooked and don't trip `FarmUtilityBorrowGuard` (the critical check — fundFarmUtility does NOT brick); (c)
> withdraw-while-lent-out reverts `E_InsufficientCash` (JIT discipline is EVK-enforced, not assumed); (d)
> `previewRedeem` is flat under a zero-rate borrow so the round-trip sizing nets post-repay. spec-fidelity confirmed
> invention-free + §17-faithful (the "split slot 2" topology is a PROGRESS session decision, not spec text — its
> spec-doc-sync is forward-deferred per the §-sync note, NOT a precondition). All other critic findings were **ticket
> gaps** (test-fixture under-specification), ALL fixed in the ticket BEFORE cold-build: the EE side does not exist in
> the farm utility suite, so the ticket now pins the full port/merge (copy the faithful `MockEulerEarn` — which moves
> REAL USDC between real EVK vaults — from `EulerVenueAdapter.t.sol`; add the `IOZERC4626`/`{IEulerEarn,
> MarketAllocation}`/adapter imports; build the base resting market + `_fundBaseMarket`; enable the farm utility at ZERO
> balance via `submitCap`+`acceptCap`; wire a real adapter with placeholder line-side ctor args; read tracked balances
> via the mock's public `expectedSupplyAssets`; name `E_InsufficientCash` + `NotFarmUtilityAllocator` revert selectors;
> pin the donation = mint-shares-then-raw-transfer). **Two-key separation** is a documented DEPLOY invariant
> (`farmUtilityAllocator` ≠ `FarmUtilityLoopModule.operator`) — the adapter holds no loop-module handle, so the on-chain
> proof is the operator key reverting `NotFarmUtilityAllocator` (no fabricated cross-contract coupling). Test home =
> `FarmUtilityLoopModule.t.sol` (it already stands up the live farm utility borrow leg), reusing
> `test_full_loop_revolves_twice`'s fixture. Gate green (verified by my own re-run, not just the cold-build's): `forge
> build` exit 0 + `forge test --match-path test/FarmUtilityLoopModule.t.sol` = **40 passed / 0 failed** (35 pre-existing
> all still green + 5 new: roundtrip-restores-resting, defund-reverts-when-lent-out, operator-cannot-fund,
> donation-noop-on-sizing, farm utility-zero-at-rest). Cold-build returned ZERO load-bearing guesses (only test-fixture
> sizing choices — X=$100/strike=$50 matching the existing fork fixture's scale — and a faithful tuple-read idiom).
> Ticket: `build/tickets/contracts/CTR-07-slot2-farm utility-fund-defund.md`. **Doc-sync:** modified contract → backward
> wire `docs/wires/WOOF-04.md` (new "farm utility fund-defund" method entry + the OP_BORROW-only load-bearing invariant +
> the adapter↔farm utility-loop two-key cross-component row + the allocator-role note now covers reallocate-for-farm utility
> + the CTR-07 gotchas test note). No `claude-zipcode.md` edit (the federation/split-slot-2 §-sync is forward-deferred,
> per the federation-section §-sync note; CTR-07 invents no mechanism — it generalizes the existing reallocate one).
> **Unblocks CTR-08** (structure-2 revolving lines reuse this reallocate-funded-revolving pattern).
> **Follow-up (reviewer-requested, same day):** the OP_BORROW-only hook invariant is now **fail-fast ENFORCED** —
> `setFarmUtilityVault` reverts `FarmUtilityHookBlocksReallocate` if the wired vault hooks any reallocate leg
> (`hookedOps & (OP_DEPOSIT|OP_MINT|OP_WITHDRAW|OP_REDEEM) != 0`), so a mis-hooked vault can't be wired in (a fresh
> negative test `test_ctr07_setFarmUtilityVault_rejects_reallocate_blocking_hook` simulates the governor widening the
> mask). Gate re-run: **41 passed / 0 failed**. The only residual (a Timelock re-hooking an already-wired vault) stays
> a documented §17 governed invariant — outside the adapter's reach. WOOF-04 + the ticket Do-NOT updated to match.

> **CTR-06c — `SiloDeployer` (the silo orchestrator) — DONE 2026-06-19.** Third + FINAL built child of the re-scoped
> CTR-06; the re-scoped CTR-06 is now COMPLETE (06a+06b+06c). Added `contracts/script/SiloDeployer.s.sol` +
> `contracts/test/SiloDeployer.t.sol` (NEW files only — no existing contract changed, so no regression possible).
> `deploy(SiloParams)` composes the four sub-deployers + the per-silo venue front into ONE complete silo and returns
> the `Silo` handle the Timelock registers via `addSilo`: (0) precompute the junior `juniorTrancheSafe`; (1) EE pool via a
> `virtual _createEePool` (live-factory `.call`; mock in the test); (2) resting `usdcReservoir` (bare EVK proxy);
> (3) `FarmUtilityMarketDeployer` (CTR-06a); (4) EE admin config via low-level `_eeCall`; (5) per-silo `CREGatingHook` +
> `EulerVenueAdapter`; (6) `CreditWarehouseDeployer` (redemptionBox = the SHARED queue); (7) `JuniorTrancheDeployer`
> (CTR-06b); (8) fail-closed post-asserts; (9) return. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/
> reference-verifier/contract-binding) CONVERGED on ~9 load-bearing gaps in the first draft, ALL in-tree fixable (ZERO
> back-pressure), fixed in the ticket BEFORE cold-build: (1) the **farm utility↔junior circular dependency** — the farm utility
> `juniorTrancheEngine` must be the junior `juniorTrancheSafe`, but `JuniorTrancheDeployer.deploy` self-summons its Baal internally AND
> consumes the farm utility vaults as inputs; resolved by precomputing `jr.computeMainSafe(p.saltNonce)` (verified
> saltNonce-only, caller-independent — `SummonSubstrate.s.sol:110-118`; CTR-06b's `MainSafeMismatch` guarantees the
> precompute == the eventual summon), NOT the draft's infeasible "two-phase junior build"; (2) **`CREGatingHook` is
> PER-SILO, not shared** — its `borrowDriver` is a single settable address gating one adapter (`:35,94,110-113`), so the
> CTR-06 index's "shared hub infra" classification was wrong and is corrected (the deployer builds a fresh hook per
> silo); (3) the **combined test mock** — NEITHER existing `MockEulerEarn` had both the EE-admin surface AND the
> donation-immune NAV reads (`convertToAssets`/`balanceOf`/`maxWithdraw`) the aggregator needs, so the test defines a
> small combined mock (de-scoping D4 to no-opens makes the rich queue mock unnecessary); (4) the full **`SiloParams`
> struct** specified; (5) `lpOracle` is a built-and-SEEDED INPUT (the LP_MARK is a CRE/forwarder push the deployer
> can't make, and `setLTV`'s `getQuote` needs it); (6) `usdcReservoir` is CREATED by the deployer; (7) the
> `SzipPerspectiveProbe` is EXCLUDED (mock-incompatible; fork-runbook advisory only); (8) `_createEePool` arity pinned;
> (9) **D4 de-scoped** — the controller routing/rollover is already exhaustively proven by `ZipcodeController.t.sol`
> (CTR-03), so CTR-06c proves it at the REGISTRY level (pranked `incrementLineCount` to the `MAX_LINES_PER_SILO=28` cap
> → `SiloFull` → `setCurrentSilo` rollover) + `SeniorNavAggregator.seniorBacking()` summing both warehouses, with NO
> real controller/opens (the stale "29th origination" off-by-one fixed — cap is 28). Gate green (verified by my own
> re-run, not just the cold-build's): `forge build` exit 0 + `forge test --match-path test/SiloDeployer.t.sol` = **5
> passed / 0 failed** — `test_deploy_silo_seams_hold`, `test_ownership_handoff` (hook→TL, junior OZ-ownables/8 modules→TL,
> farm utility borrow-vault governor→TL, warehouse Safe/Roles→godOwner + admin adapter→receiverAdmin, both Baal Safes→team
> & NOT the deployer), `test_addSilo_first_try` (a REAL `SiloRegistry.addSilo` from a pranked Timelock passes on the
> first try — non-vacuous, reverts `SiloMiswired` on any clause failure), `test_D4_two_silo_routing_rollover_and_aggregate`,
> `test_D2_runbook` (`setCapacity`/`addSilo`/`setCurrentSilo` via `vm.prank(timelock)`). Cold-build returned ZERO
> load-bearing mechanism guesses (only test-fixture value choices + ticket-sanctioned options). Ticket:
> `build/tickets/contracts/CTR-06c-silo-deployer-orchestrator.md`. **Doc-sync:** NEW script + test → new wire
> `docs/wires/CTR-06c-SiloDeployer.md` + `COVERAGE.md` rows (scripts 10→11, tests 33→34); CTR-06 index marked 06c DONE
> + the per-silo-hook correction. No existing contract changed → no backward wire edit owed. No `claude-zipcode.md`
> edit (the federation §-sync is forward, not a precondition; the deployer invents no mechanism — it composes the
> existing ones). **Discharges the PROGRESS "DEPLOY OBLIGATION (CTR-03)"** as the per-silo D2 runbook (the hub half —
> `setRegistry`/`setController` + silo #0 — is already done by CTR-03/`DeployZipcode`). **Unblocks horizontal scaling
> (N pools) + the federation migration path.**

> **CTR-06b — `JuniorTrancheDeployer` (the reusable per-junior tranche deployer) — DONE 2026-06-19.** Second built
> child of the re-scoped CTR-06; the missing per-silo analogue of `CreditWarehouseDeployer`. Added
> `contracts/script/JuniorTrancheDeployer.s.sol` + `contracts/test/JuniorTrancheDeployer.t.sol` (NEW files only — no
> existing contract changed, so no regression possible). `deploy(JuniorParams)` is a faithful EXTRACTION of
> `DeployZipcode`'s inline junior stack (phases P3/P6/P7/P8/P9, ~30 deployments + 15 seam asserts) into one callable,
> parameterized to point at THIS silo's `eePool`/`warehouseSafe`/farm utility handles + the SHARED hub `zipUSD`/
> `rateOracle`. Stands up: Baal two-Safe substrate + `SzipNavOracle` + `ExitGate`/`SzipUSD` + `ZipDepositModule` + the
> **8** yield/freeze/buy-burn engine modules + the loss side (`LienXAlphaEscrow`+`DefaultCoordinator`); reproduces every
> seam assert; hands OZ-ownable → Timelock, engine modules already Timelock-owned from setUp, BOTH Baal Safes → the
> persistent `team` (§4.5 two-tier model). **Reviewer ratified D1 + D5 (2026-06-19):** D1 = `polIchiVault`/`polGauge`
> are shared deploy INPUTS (one pool, per-silo staked position); D5 = EXCLUDES `OffRampModule` + `queue.setRedeem
> Controller` (8 modules not 9; senior off-ramp is hub-level). **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/
> reference-verifier/contract-binding) CONVERGED on the **owner/signer model** as the single most-blocking gap — the
> original draft said "the broadcaster MUST be `team`" while CTR-06c calls `new JuniorTrancheDeployer().deploy(...)`
> (mutually exclusive: a `new`'d contract's internal Safe-drives run with `msg.sender == the deployer instance`, never
> the broadcaster, so `_summon(team,…)` reverts on the juniorTrancheSidecar owner-add). **Ticket fixed BEFORE cold-build** to the
> transient-owner pattern (self-summon `_summon(address(this),…)` à la `CreditWarehouseDeployer`; reimplement the 4
> `i.*`-bound helpers parameterized; step-17 `swapOwner` both Safes to the real `team`; Safes → `team` NOT Timelock —
> the preamble's "every owner to the Timelock" was wrong for the Safes). Plus: the full `JuniorParams` struct defined,
> the **NAV leg tokens made injectable params** (the freeze `setUp` reads `zipUSD/usdc/xAlpha/hydx/oHydx` live off the
> oracle; the fork fixture feeds mocks — verified directly against `DurationFreezeModule.t.sol:1286-1295`),
> `workflowAuthor`/`workflowId` added for the identity seal, `rateOracle` excluded from the handoff, `is SummonSubstrate`
> (→ `is Script`, `.s.sol`), and the `setLpTwapWindow`/CREATE2/non-commingling minor flags. Gate green (verified by my
> own re-run, not just the cold-build's): `forge build` exit 0 + `forge test --match-path test/JuniorTrancheDeployer.t.sol`
> = **4 passed / 0 failed** — `test_deploy_seams_hold`, `test_ownership_handoff` (OZ→Timelock, 8 modules→Timelock, both
> Safes→team & NOT the deployer, rate-oracle wired-not-owned), `test_addSilo_topology_clauses_1_to_5` (a REAL
> `SiloRegistry.addSilo` from a pranked Timelock — reverts `SiloMiswired` on any clause failure; non-vacuous), and
> `test_non_commingling`; the farm utility leg is built via the REAL `FarmUtilityMarketDeployer` over the live EVK + a mock
> LP. Cold-build returned ZERO load-bearing guesses. Ticket: `build/tickets/contracts/CTR-06b-junior-tranche-deployer.md`.
> **Doc-sync:** NEW script → new wire `docs/wires/CTR-06b-JuniorTrancheDeployer.md` + `COVERAGE.md` rows (scripts 9→10,
> tests 32→33). No existing contract changed → no backward wire edit owed. No `claude-zipcode.md` edit (the federation
> §-sync is forward, not a precondition; the deployer invents no mechanism — it extracts `DeployZipcode`'s existing one).
> **Unblocks CTR-06c** (the `SiloDeployer` orchestrator calls this once per silo).

> **CTR-06a — `FarmUtilityMarketDeployer` hands the borrow-vault governor to the Timelock — DONE 2026-06-19.** First
> child of the re-scoped CTR-06; discharges **FE-07 Finding A**. One-line source fix + one post-assert (no new files).
> `FarmUtilityMarketDeployer.deploy` (`contracts/script/FarmUtilityMarketDeployer.sol`) handed ONLY the **router**
> governance to `p.governor` (`:88`); the USDC **borrow vault** is created via `factory.createProxy(address(0), …)`
> (`:77`) so its `governorAdmin` defaulted to the throwaway deployer INSTANCE and was never re-pointed — directly
> contradicting the contract header (`:13-14`) + `:75` ("Governor RETAINED … the Timelock can tune LTV/caps") and §17.
> Added `IEVault(borrowVault).setGovernorAdmin(p.governor)` as step 6, alongside the router transfer — AFTER all
> governor-gated config (`setInterestRateModel`/`setHookConfig`/`setLTV`), so the deployer can still configure first.
> Escrow renounce (`:61`, intentional holding box) + router transfer untouched. **Binding verified, not cited blind:**
> `IEVault.setGovernorAdmin(address)` @ `reference/euler-vault-kit/src/EVault/IEVault.sol:481`, `governorAdmin()` @
> `:370` — both real. Test home = the existing fork section `test_deployer_governor_RETAINED`
> (`test/FarmUtilityLoopModule.t.sol`), next to the router-retained + escrow-renounced asserts: added
> `assertEq(IEVault(bv).governorAdmin(), owner, "borrow vault governor RETAINED")`. **Proven load-bearing** — reverting
> the source line fails the assert (`governorAdmin()` = the deployer instance `0x5991…` ≠ owner `0xf744…`), confirming
> it tests the EFFECT not "didn't revert". Gate green: `forge build` exit 0 + `forge test` on the two deployer-touching
> suites = `FarmUtilityLoopModule.t.sol` **35 passed / 0 failed** + `AlgebraIchiFairLpOracle.t.sol` **5 passed / 0
> failed**; no pre-existing test regressed (escrow `governorAdmin()==address(0)` still holds). Cold-build returned ZERO
> load-bearing guesses (the ticket was already 4-critic-vetted in the CTR-06 split; binding + seam re-verified against
> live source this window). Ticket: `build/tickets/contracts/CTR-06a-farm utility-governoradmin-fix.md`. **Doc-sync:**
> modified script contract → backward wire `docs/wires/8-B5-FarmUtilityLoop.md` step-5 sequence rewritten to enumerate
> the borrow-vault `setGovernorAdmin` handoff (the prose claim at `:25`/`:150` was already "retained on both" — the
> SEQUENCE list was the stale part). No new contract/test file → no `COVERAGE.md` row change. No `claude-zipcode.md`
> edit (§17 already correct — the fix makes the code MATCH §17). **Live-fork caveat:** fixes future deploys only; the
> already-deployed anvil borrow vault keeps its stranded governor until a redeploy (FE-07 `entities.json` re-read note
> stands).

> **CTR-05 — `SeniorNavAggregator` (donation-immune Σ senior par-backing across silos) — DONE 2026-06-18.** Fourth
> contract of the scaling/federation workstream; the cross-silo solvency telemetry + circuit-breaker input. Added
> `contracts/src/SeniorNavAggregator.sol` + `contracts/test/SeniorNavAggregator.t.sol` (no existing contract changed).
> A pure OZ `Ownable` (Timelock) view that loops `SiloRegistry.allSiloIds()` and sums each silo's §8.2 donation-immune
> senior read (`convertToAssets(balanceOf(warehouseSafe)) * 1e12`, NEVER `balanceOf(eePool)`), replicating the
> `DurationFreezeModule:295-302` guards VERBATIM. Surface: `seniorBacking()` (Σ ALL silos), `activeSeniorBacking()`
> (active-only), `illiquidSeniorValue()` (Σ lent-out), `collateralization(supply)` (zero-supply→`type(uint256).max`),
> `systemCollateralization()` (wired zipUSD `totalSupply`), per-silo getters (unknown→0), Timelock `setRegistry`/
> `setZipUsd`+`WiringSet`. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/contract-
> binding) converged on THREE load-bearing fixes applied to the ticket BEFORE cold-build: (1) **the draft excluded
> inactive silos from the live backing sum — WRONG for the §12 solvency numerator.** `retireSilo` only stops new
> routing ("existing lines close normally"), so a retired silo still backs the zipUSD its open lines minted; zipUSD is
> fungible at the hub, so excluding it understates backing and could falsely trip a breaker during wind-down. Fixed:
> `seniorBacking()`/`illiquidSeniorValue()` sum ALL silos (drained ones self-zero via `balanceOf→0`); `active` filters
> ONLY the separate `activeSeniorBacking()`. (Ticket gap, not a spec change — §12 already says system-wide.) (2)
> **§12-NAV mislabel:** the Σ is senior **par** backing (idle + loan principal at par), NOT full §12 NAV (which marks
> impaired loans to recovery, net of the junior provision); they coincide only pre-impairment, impairment lands in the
> junior `SzipNavOracle` per §11. Reframed to "senior par-backing coverage" throughout — the correct senior-solvency
> signal. (3) **registry-read framing self-contradictory** (an inline iface naming `SiloRegistry.Silo` still needs the
> import) → `import {SiloRegistry}` outright; no struct-read precedent exists in CTR-03. Plus precision nail-downs:
> `WiringSet` slot labels `"registry"`/`"zipUsd"`, ctor accepts zero for both (deploy-order) with fail-closed
> `RegistryUnset`/`ZipUsdUnset` guards, per-silo getters return 0 on unknown/empty, zipUSD 18-dp VERIFIED
> (`DeployZipcode.s.sol:260` `new ESynth(...)`, no decimals override). **The test mock was the precision work:** the
> shared `test/mocks/MockEulerEarn.sol` has no `maxWithdraw` and can't model `free<sa` — used the settable-backing
> mock per `DurationFreezeModule.t.sol:107-130` (per-account `balanceOf`, settable `convertToAssets`/`maxWithdraw`, a
> `donateShares` path that does NOT move warehouse backing, mirroring the donation test at `:455-461`); `SiloRegistry`
> is the REAL contract with self-consistent topology stubs. Gate green: `forge build` exit 0 + `forge test
> --match-path test/SeniorNavAggregator.t.sol` = **18 passed / 0 failed** (N=1 identity, two-silo Σ, donation no-op,
> retired-still-counted-but-dropped-from-active, drained→0, illiquid verbatim-formula incl. `free>=sa`/`sa==0`→0,
> collateralization math + zero-supply→max, systemCollateralization wired vs `ZipUsdUnset`, per-silo getters +
> unknown→0, `RegistryUnset` on all aggregate reads, ctor-zero-both, setter owner-gating + zero-reject + `WiringSet`).
> Cold-build returned ZERO load-bearing guesses. Ticket: `build/tickets/contracts/CTR-05-senior-nav-aggregator.md`.
> **Doc-sync:** NEW contract → new wire `docs/wires/CTR-05-SeniorNavAggregator.md` + `COVERAGE.md` rows (38→39 product,
> +1 test → 32); CTR-02 wire's CTR-05 cross-ref marked BUILT. No `claude-zipcode.md` edit owed (§12 NAV semantics
> intact — CTR-05 is a senior-par-coverage telemetry view consistent with §11/§12, recorded in the wire).

> **CTR-04 — `closeLine` reclaims the binding withdraw-queue slot — DONE 2026-06-18.** Third contract of the
> scaling/federation workstream; discharges **finding 1**. Modified `contracts/src/venue/EulerVenueAdapter.sol`
> (`closeLine`) + `contracts/test/EulerVenueAdapter.t.sol` (no new files). `closeLine` previously pruned only the
> SUPPLY queue (SEC-06) and left the line's EE cap at `type(uint136).max`, so the **binding WITHDRAW-queue slot was
> never freed** — the hard `MAX_QUEUE_LENGTH=30` cap fires on the withdraw queue inside `_setCap` when `acceptCap`
> first enables a market (`EulerEarn.sol:783-785`), so a pool bricked after ~28 *lifetime* opens. Added, AFTER the
> existing defund + supply-prune, a single **inline** withdraw-queue reclaim: `submitCap(IOZERC4626(lineRef), 0)`
> (cap DECREASE applies immediately, no timelock, `:298-299`; removal guard `:362` requires `cap==0`) → build
> `keepIndexes` = every withdraw-queue index whose market `!= lineRef` (by address, two-pass, via
> `withdrawQueueLength()`/`withdrawQueue(i)`) → `updateWithdrawQueue(keepIndexes)`. **Harness loop ran:** 4 critics
> (junior-dev/spec-fidelity/reference-verifier/contract-binding) CONVERGED on ONE load-bearing design fix applied to
> the ticket BEFORE cold-build: the draft's two-path design (`submitMarketRemoval` + a deferred `reapLine` keeper
> step + an `eulerEarn.timelock()` branch for non-zero-timelock pools) is **dead code** — removal of an EMPTY market
> never engages the EE timelock, because `updateWithdrawQueue`'s `removableAt`/timelock guard (`:366-370`) sits
> inside `if (expectedSupplyAssets(id) != 0)` (`:365`) and `closeLine` mandatorily defunds the line to zero first
> (`previewRedeem(0)==0`, `expectedSupplyAssets == _eeSupplyAssets`). So removal is inline + timelock-independent for
> ANY pool (even if the external EE owner raised the timelock mid-life), and `submitMarketRemoval` is never needed.
> Cut the two-path → single inline path. Also resolved the ticket's open hedges: `withdrawQueueLength()` confirmed to
> exist (`:482`); `IOZERC4626` is the adapter's OZ-`IERC4626` alias (`:13`); `submitCap(0)` is always a valid
> `max→0` (the EE config cap is invariably max from openLine — `setLineLimits` touches only the EVK vault's own caps);
> CTR-04 adds NO registry call (`decrementLineCount` lives in the CONTROLLER, CTR-03 — CTR-04 makes the *physical*
> slot reclaim match the existing counter decrement). **The real test work was extending `MockEulerEarn`** (it
> modeled only the supply queue + hardcoded `cap=max`): added per-market cap tracking, a `_withdrawQueue` pushed on
> first market-enable enforcing the `:785` cap, `withdrawQueue`/`withdrawQueueLength` getters, and a faithful
> `updateWithdrawQueue` with the `:362-371` removal guards. Gate green: `forge build` exit 0 + `forge test
> --match-path test/EulerVenueAdapter.t.sol` = **39 passed / 0 failed** (33 pre-existing incl. SEC-06/07/08/11 all
> still green + 6 new CTR-04: reclaims-slot, removed-market-cap-zero-and-empty, leaves-other-slots,
> brick-without-close (31st open reverts `MaxQueueLengthExceeded`), no-brick-across-churn-past-cap, concurrent-reuse
> (fill→close→fresh-open-succeeds)). Cold-build returned ZERO load-bearing guesses. Ticket:
> `build/tickets/contracts/CTR-04-closeline-withdrawqueue-reclaim.md`. **Doc-sync:** modified contract → backward wire
> `docs/wires/WOOF-04.md` updated (`closeLine` now reclaims BOTH queues; the allocator-role note gains
> `updateWithdrawQueue`; the `MockEulerEarn` note records the withdraw-queue extension). No new contract → no
> `COVERAGE.md` row change. No `claude-zipcode.md` edit (§4.7/§4.5 already correct).

> **CTR-03 — `ZipcodeController` siloId routing over the registry — DONE 2026-06-18.** Second contract of the
> scaling/federation workstream; makes the controller multi-pool. Modified `contracts/src/ZipcodeController.sol` +
> `contracts/test/ZipcodeController.t.sol` (no new files). The report paths now resolve `venue` per origination
> from `SiloRegistry.venueOf(siloId)` (CTR-02) instead of the single `venue` pointer: added a `registry` wiring
> slot (NOT in ctor — `setRegistry`, `WiringSet`, §17), an inline `ISiloRegistry` 3-method interface, errors
> `RegistryUnset`/`SiloUnrouted`, a private `_venueFor(siloId)` fail-closed resolver, `LienRecord.siloId`
> (appended), a trailing `siloId` on `LienOriginated` + the RT_ORIGINATION payload, and the
> `incrementLineCount`/`decrementLineCount` slot hooks (each the FINAL statement of origination/close → a
> `SiloFull` revert rolls the whole atomic origination back; F-10 preserved — trusted no-callback registry).
> Draw/close **re-resolve from the stored `r.siloId`** (never `currentSilo`), so a re-pointed/retired silo can't
> strand an open line. **Harness loop ran:** 4 critics (junior-dev/spec-fidelity/reference-verifier/contract-
> binding) converged on ONE load-bearing design fix applied to the ticket BEFORE cold-build: the draft's
> dual-mode `venue` fallback (route via `venue` when `registry==0`) is a silent line-bricking hazard (a line
> opened pre-registry becomes un-closeable post-registry) → **registry made MANDATORY** for report paths
> (`RegistryUnset` fail-closed; no fallback), with `venue`/`setVenue`/ctor RETAINED only for deploy-cycle compat.
> Plus precision fixes: `siloId` appended LAST (matches the lienId-first §8.0 convention) not first; explicit
> inline `ISiloRegistry`; `registry.setController(controller)` made a Key requirement + deploy obligation; N=1
> identity defined concretely (the full pre-existing suite routed through a registered `SILO_0 → adapter`); the
> CTR-04 lifetime-vs-concurrent caveat carried into the NatSpec + wire. One agent misread filtered (a critic cited
> the test's `registry.setController` at `:236` as a SiloRegistry wire — verified it's the `ZipcodeOracleRegistry`;
> there was no SiloRegistry in the test). Gate green: `forge build` exit 0 + `forge test --match-path
> test/ZipcodeController.t.sol` = **34 passed / 0 failed** (26 pre-existing routed through the registry = the N=1
> identity proof, + 8 new: routes-to-named-venue, draw/close re-resolve, closes-after-retire, count
> increment/decrement, SiloFull-rolls-back-no-orphan, unknown-silo→SiloUnrouted, registry-0→RegistryUnset, and a
> real-`SiloRegistry` integration test with self-consistent topology stubs). Cold-build returned ZERO load-bearing
> guesses. Ticket: `build/tickets/contracts/CTR-03-controller-silo-routing.md`. **Doc-sync:** modified contract →
> backward wire `docs/wires/WOOF-05.md` updated (registry slot, `_venueFor`, the origination step-0/step-9 hooks,
> draw/close re-resolve, gotchas, cross-component pin, CTR-04 caveat); forward spec `claude-zipcode.md` §8.0
> RT_ORIGINATION row gains trailing `siloId` + a routing note. No new contract → no `COVERAGE.md` row change.
> **Deploy obligation logged** under Open obligations (setRegistry/setController wiring + assert).

> **CTR-02 — `SiloRegistry` (multi-pool/federation silo catalog + admission gate) — DONE 2026-06-18.** First
> contract of the scaling/federation workstream. Added `contracts/src/SiloRegistry.sol` + `contracts/test/
> SiloRegistry.t.sol`. A plain OZ `Ownable` (v5, Timelock owner — NOT a Zodiac module/EVK hook) catalog of silos
> `{adapter, warehouseSafe, eePool, juniorBasket, escrow, defaultCoordinator, navOracle, freeze, curator,
> lineCount, active}` keyed by a caller-chosen `bytes32 siloId`: `addSilo` (onlyOwner admission + a load-bearing
> **6-clause topology assert** that the silo points only at its OWN components — `freeze.{eulerEarn==eePool,
> warehouse==warehouseSafe, navOracle==navOracle}`, `escrow.coordinator()==defaultCoordinator`,
> `defaultCoordinator.navOracle()==navOracle`, `adapter.eulerEarn()==eePool`), `retireSilo`/`setActive`/
> `setCurrentSilo` (governed lifecycle; retire keeps the record), `incrementLineCount`/`decrementLineCount`
> (`onlyController`, cap `MAX_LINES_PER_SILO = 28 = 30−2`), views (`venueOf`→adapter, `getSilo`, `allSiloIds`,
> `siloCount`), Timelock-settable `controller` (`setController`+`WiringSet`). **Harness loop ran:** 4 critics
> (junior-dev/spec-fidelity/reference-verifier/contract-binding) converged on TWO load-bearing findings, both fixed
> in the ticket BEFORE cold-build: (1) the draft `Silo` struct lacked `defaultCoordinator` + `freeze` fields the
> topology assert dereferences → added both, dropped the redundant `WarehouseAdminModule` assert; (2) `lineCount`
> is concurrent but the EE cap is LIFETIME until CTR-04 (closeLine doesn't free the withdraw-queue slot) →
> documented as a cross-ticket capacity dependency (CTR-02 builds standalone but concurrency is sound only once
> CTR-03+CTR-04 land). Plus: caller can't seed `lineCount`/`active` (admission takes a `SiloConfig` addresses-only
> view); `bytes32(0)` reserved as the `currentSilo` sentinel; `venueOf` returns the adapter. Gate green: `forge
> build` exit 0 + `forge test --match-path test/SiloRegistry.t.sol` = **28 passed / 0 failed** (happy-path, zero-id,
> dup, per-field zero-address, ≥2 broken topology clauses, increment-to-cap→SiloFull, decrement + zero-guard,
> onlyController/onlyOwner gating, retire-stops-routing-keeps-record). Cold-build returned only non-load-bearing
> defensive choices (constructor accepts zero `controller_` per deploy-later order, `UnknownSilo` guard,
> `adapter!=0` existence sentinel). Ticket: `build/tickets/contracts/CTR-02-silo-registry.md`. **Doc-sync:** NEW
> contract → new wire `docs/wires/CTR-02-SiloRegistry.md` + `docs/wires/COVERAGE.md` rows (37→38 product, +test).
> No existing contract changed → no backward wire edit owed. No `claude-zipcode.md` edit (federation § is forward
> doc-sync, not a precondition). NOTE on git: a mid-session commit `0350d5a` (author rootdraws) checkpointed the
> pre-existing dirty tree (the CTR-02..12 *draft* tickets + earlier doc edits) — it does NOT contain this window's
> work; CTR-02's built code + rewritten ticket + this sync are the new commit.

> **KEEPER-01a — buy-burn fill-detect → `burnFor` job — DONE 2026-06-17.** The first live (K) write job + the burn
> half of the hybrid buy-burn cycle (`CRE-OPS-ROUTING.md`): a CoW fill lands szipUSD in the engine Safe; `BurnJob`
> retires it via `ExitGate.burnFor(amount)` (`onlyWindowController` = the keeper key). Added to `cre/keeper/`:
> `internal/job/burn_job.go` (`BurnJob`: reads `shareToken()`/`juniorTrancheEngine()`/`balanceOf` off the Gate each tick
> §17-re-pointable, burns the **full** engine-Safe balance — `Loot(gate) ≥ that` always, the soulbound-Loot
> invariant — above a config `MinBurnAmount` floor; no-op on zero/below-floor/unwired) · `internal/chain/encode.go`
> (`PackUintCall` for one-uint256 write calldata) · `MinBurnAmount` config (env-only `*big.Int`; explicit 0 valid) ·
> `main.go` registers it after the IdentityJob. **No coverage/freshness gate by design** — `SzipNavOracle.
> _effectiveSupply()` excludes the engine Safe's pre-burn szipUSD (`:608-613`, denominator at `:474`), so a lagging
> burn can't move NAV (housekeeping). **No double-burn** because the spine's `Submit` is synchronous on a
> single-threaded Runner (recorded as load-bearing in a code comment). Gate green: `go vet`/`go build` exit 0
> (native) + `go test ./...` green (stub-Reader unit suite with the EXACT `0x6f5d0f0b ++ uint256` calldata
> assertion + no-op/floor/unwired/error branches; simulated-backend end-to-end via `ExitGateBurnProbe`) + all
> KEEPER-00 tests still pass, clean under `-race`. Zero load-bearing guesses. Ticket:
> `build/tickets/cre/KEEPER-01a-burn-job.md`. No contract changed → no `wires/` sync owed.

> **KEEPER-00 — the CRE keeper-service scaffold — DONE 2026-06-16.** The foundation for the entire **(K)** surface
> (the §8.7 operator path's off-chain embodiment; NOT wasip1, imports no `cre-sdk-go`). Built `cre/keeper/` (Go +
> go-ethereum v1.17.2): config (env+JSON, defaults-before-validate, re-pointable address book §17) · keymgr
> (operator hot key, env-hex primary / geth-keystore secondary; key NEVER logged/in-errors/in-Config) · the
> `chain` client (a minimal `Backend`/`Reader` iface both `*ethclient.Client` AND `simulated.Client` satisfy; view
> read-helpers `CallUint/Bool/Address`; a **nonce-safe** EIP-1559 `Submit` — local mutex-guarded nonce, advances
> ONLY after a successful send, `EstimateGas` doubles as a dry-run that aborts without advancing) · the
> read→compute→submit **`Job` spine** (`Evaluate→chain.Plan`, a `Runner` that ResyncNonce→submits each plan
> **ordered + abort-on-first-error**, fail-safe between jobs, graceful SIGINT/SIGTERM — liveness-only failure per
> `CRE-OPS-ROUTING.md`) · one reference read-only **IdentityJob** asserting the §8.7 invariant `operator()==key &&
> owner()!=key` (the copy-template KEEPER-01 clones; startup fail-fast + heartbeat). Gate green:
> `go vet ./... && go build ./...` exit 0 (native, NOT wasip1) + `go test ./...` green across chain/config/job/keymgr
> (submit-spine incl. nonce-gap regression; default-before-validate; abort-on-first-error; IdentityJob incl. the
> `operator!=owner` branch via a stub Reader), also clean under `-race`. Zero load-bearing guesses. Ticket:
> `build/tickets/cre/KEEPER-00-keeper-scaffold.md`. No contract changed → no `wires/` sync owed (off-chain code;
> truth = ticket + code + commit). **Forward notes recorded for KEEPER-01** in the ticket: fill-detect is a
> balance-poll (no on-chain fill event); harvest legs are discrete txs (no multicall) → ordered `chain.Plan`; the
> `abi.Pack` native-int quirk bites scalar args.

> **M1 DECISION (2026-06-16): the 8-B14 buy-order bid is HUMAN/MANUAL at launch.** A person posts/cancels it via
> the operator-key door, reading the FE-08 exit-book dashboard; the CRE-05a robot is **built-but-parked** until
> there's real exit data to tune the bid's `d`/size rules (flip-on = wire Forwarder + workflow-id, then run). No
> rework — CTR-01's two-door design already supports manual. The yield engine (8-B5…8-B10) stays robot-run.
> See `build/tickets/cre/CRE-OPS-ROUTING.md` (M1 operating note).

> **FE-08 — szipUSD NAV exit-book page — DONE 2026-06-16.** Built in the LAYER (`frontend/zipcode-finance-euler`,
> commit `a592135` on `resi-labs-ai`): `pages/lender/szip-exit-book.vue` + `composables/{useNavExitBook,
> useCowOrderbook}.ts` + `components/zipcode/{ZcNavExitBookChart,ZcLiquidityGauge}.vue`. The two-sided depth chart
> (x = % of NAV, y = cumulative USDC): NAV line @100% + the protocol buy-burn bid block @ `navExit×(1−d)` sized to
> the live `currentBid().sellAmount` (the CRE-05a loop) + the external CoW book fanned below; a liquidity gauge
> (free farm utility = `eePool.maxWithdraw(warehouseSafe)`, `U` the donation-immune §8.2 way); a "Sell to floor" CTA
> that opens the unmodified FE-04 `ZcWithdrawModal` (no new exit logic). Reads all exist (no back-pressure); the
> registry already had `eePool`/`warehouseSafe`. Gate green: `npm run build` (nuxt) clean + `node
> .output/server/index.mjs` → `/lender/szip-exit-book` returns 200 (external book empty on the fork, renders fine).
> Ticket: `build/tickets/frontend/FE-08-nav-exit-book.md`.

> **CRE-05a — buy-burn bid-loop wasip1 workflow — DONE 2026-06-16.** The exit half of CRE-05 (§8.7), unblocked by
> CTR-01. Built `cre/buyburn-bid/` (the first buildable CRE workflow — also the minimal CRE scaffold): a
> `cre-sdk-go` workflow that maintains the single resting buy-burn bid via the report path. Reads
> `currentBid`/`quoteMaxPrice`/`buybackCap`/`fresh`/`maxAge`/`oldestRequiredLegTs`/`covered` + the donation-immune
> §8.2 free-farm utility read (`EulerEarn.maxWithdraw(warehouse)`); sizes `clamp(freeReservoir − harvestReserve −
> safetyBuffer, 0, buybackCap)` @ `quoteMaxPrice` (= `navExit×(1−d)`); reconciles one bid (post / cancel+repost on
> size-drift ≥ driftBps / cancel) via `WriteReport(POST_BID|CANCEL_BID)` to the socketed module; cron + a
> `RedemptionSettled` LogTrigger. Gate green: `GOOS=wasip1 GOARCH=wasm go build` exit 0 + `go test` 14 pass
> (encode round-trip byte-matching `_processReport`, 7 simulated-run scenarios, sizing units). Ticket:
> `build/tickets/cre/CRE-05a-buyburn-bid-loop.md`.

> **CTR-01 — Clone-compatible CRE report socket on SzipBuyBurnModule — DONE 2026-06-16.** Resolved the
> operator-path-has-no-CRE-write seam for 8-B14: added the reusable `CloneReportReceiver` base
> (`contracts/src/supply/szipUSD/CloneReportReceiver.sol`) + expanded `SzipBuyBurnModule` to be ALSO
> report-drivable (two doors — operator key + DON report — one guard set, fail-closed on an unset forwarder).
> Gate green: `forge test --match-path test/SzipBuyBurnModule.t.sol` = 50 passed / 0 failed (44 pre-existing +
> 6 new report-path cases). Ticket: `build/tickets/contracts/CTR-01-clone-report-receiver-buyburn.md`. Truth:
> `build/wires/8-B14-SzipBuyBurnModule.md` + `COVERAGE.md`; spec exception recorded in `claude-zipcode.md`
> §8.7 + §8.0 table.

> **The SEC track is COMPLETE** — all 16 internal-audit remediation items (15 FIX + the DOC sweep) landed; the
> deliberate non-fixes are recorded under Open obligations below. See the SEC track section below.
>
> **The Frontend ↔ anvil track is COMPLETE** (FE-00…FE-07, 2026-06-10/11). The **CRE track** (CRE-00…CRE-06) is the
> next workstream; its head is CRE-00 (scope retained in the Backlog table below).

---

## SEC track — internal-audit remediation (auditor-prep) — COMPLETE

**All SEC remediation DONE** (15 FIX + the DOC sweep; 2026-06-15/16). Every fix is in the committed, fork-tested
code (`forge test` green) and truth-sourced in `build/wires/` (index `build/wires/COVERAGE.md`) — **that, plus the
git commit history, is now the durable record.** The internal-audit scratch (the `audit-claude/` findings, the
consolidated `kill-list.md`, the per-item SEC tickets + reports) has been pruned — it was Claude-run self-audit
bookkeeping, not an external-auditor deliverable, and its actionable conclusions all landed in code + wires. The
conceptual findings that weren't obvious from code live in the wires (e.g. the "perspective is provenance-only"
finding in `wires/WOOF-04.md`). The deliberate **non-fixes** that remain forward-relevant are recorded under Open
obligations (the `setBaal` managerLock caveat; the abandoned draw-time coverage gate); the pure "verified-not-real"
dismissals (the old H3/L5/L10/M5) needed no code and are recoverable from git if a professional auditor re-raises them.

---

## Backlog

### CRE — two build shapes (routing decided 2026-06-16, `build/tickets/cre/CRE-OPS-ROUTING.md`)
**(R) wasip1 workflows** (report path → existing receivers): CRE-00/01/03/04 + CRE-05a (done).
**(K) the CRE keeper service** (off-chain Go + go-ethereum, hot keys, NOT wasip1): KEEPER-00/01 + the CRE-02 operator half.
Numbering otherwise follows the spec's own CRE map (`claude-zipcode.md` §8.11) — the spec rules intent.

| Item | What | Shape |
|---|---|---|
| KEEPER-00 | **DONE 2026-06-16** — CRE keeper-service scaffold (`cre/keeper/`; Go + go-ethereum; key mgmt; nonce-safe read→compute→submit spine + chain-read helpers + the `Job`/`Runner` seam + the IdentityJob template; config). Foundation for every (K) item. NOT wasip1. | (K) |
| KEEPER-01a | **DONE 2026-06-17** — buy-burn fill-detect→`burnFor` (windowController). The first live (K) write `Job` on the spine (`cre/keeper/internal/job/burn_job.go`). | (K) |
| KEEPER-01b | Engine harvest-loop orchestrator (8-B5…8-B10 `onlyOperator` legs; regime/split/cap policy), as `Job`s on the `cre/keeper/` spine. = the bulk of the rest of CRE-05. **POLICY-BLOCKED** — undecided execution floors / regime+state / vote / sizing; agenda = `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md`. Strike-loop core slice unblocks once A1–A4 + C4 ratified. | (K) |
| KEEPER-01c | Freeze-`commit`-on-coverage-shortfall (the DORMANT lever, exception-only). **DEFERRED** — binds to the INCOMPLETE `DurationFreezeModule` (premise under review, Open obligations); lock with the freeze rebuild, not against an unsettled module. | (K) |

> **The szipUSD CoW-exit workstream is COMPLETE (2026-06-16): CTR-01 (report socket) + CRE-05a (bid-loop) +
> CRE-06 (folded-as-config) + FE-08 (exit-book page) landed; the `build/CoW.md` + `build/CoW-exit.md` drivers are
> deleted.** Durable record = the built code + `build/wires/` + this file.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — **DONE 2026-06-19** (`cre/zipreport` lib + `cre/scaffold` template; note below) |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family). **SEC-01 constraint: must not co-locate two same-lien `seedPrice` writes (origination+draw / draw+draw) in one block — the registry monotonic guard reverts the second. See open obligations.** | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call. *(2026-06-12: `settleEpoch` is now ON-DEMAND — the 30-day epoch gate was removed — so this can be event-driven off the queue's `RedemptionSettled` event rather than a fixed cron: settle → if backlog remains, sequence another REDEEM→REPAY. See `build/wires/9-ZipRedemptionQueue.md`.)* **Scope: `build/tickets/cre/CRE-02-redemption-settle.md`.** | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipFarmUtilityLpOracle` (one coherent producer). **DONE 2026-06-20** (`cre/sharefeeds/`, note below). The "xALPHA-APR feed" the row used to bundle is NOT here: the APR is on-chain-derived (§8.8), and the raw RATE push is the separate `cre/szalpha-rate` (8x-02, R-1-blocked) — NOT owed by CRE-03. | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔juniorTrancheSidecar rotation; regime/split/cap policy). **SPLIT — exit half = CRE-05a (DONE); harvest + rotation remainder = KEEPER-01b (POLICY-BLOCKED) + KEEPER-01c (DEFERRED). CRE-05 is NOT complete; there is no CRE-05b/05c — the remainder lives under the KEEPER prefix.** *(2026-06-12 design inputs: (a) the DurationFreeze main↔juniorTrancheSidecar rotation needs an LP **unstake→commit** sequence — the freeze can't move staked LP; see the `TODO(freeze-lp)` in `DurationFreezeModule.sol` + `build/wires/DurationFreezeModule.md`; (b) the 8-B14 CoW **buy-burn bid-automation loop** — size the resting bid to `clamp(freeReservoir − harvestReserve, 0, buybackCap)`, repost on drift/`RedemptionSettled`/fill, optionally as **staggered clones** for laddered depth — the exit half SHIPPED as CRE-05a, `cre/buyburn-bid/`.)* **CLARIFICATION (2026-06-16): the freeze's physical lever (`commit`/`release`) is DORMANT by design.** `commit` is `onlyOperator` + discretionary (no auto-machinery), and the juniorTrancheSidecar is empty in normal operation because the dominant asset (the staked ICHI LP) can't be moved into it — it is counted toward the floor IN PLACE via the oracle's `pathLockedLpEquity()` (`coverageValue = committedValue + pathLockedLpEquity`). So CRE-05 should drive `commit` ONLY on a coverage shortfall (a price-drift breach where in-place LP + juniorTrancheSidecar < `requiredCommittedValue`), to top up with the movable plain legs (USDC/zipUSD preferred — stable backing). The live machinery is the **accounting + outflow gates** (`covered()` on `postBid`/`removeLiquidity`/`release`), not the physical rotation. | §8.7 |
| CRE-06 | **DISCHARGED-as-config by CRE-05a (2026-06-16).** The exit-vs-harvest split is now the `harvestReserve` + `safetyBuffer` Config params in the buy-burn bid sizing (`clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)`) — M1 constants; a dynamic utilization-aware policy is a later parameter swap, not a redesign. No standalone workflow. (Cross-cutting coupling now recorded in the CRE-05a ticket + `build/wires/DurationFreezeModule.md`.) | §8.5 / §8.7 |
| CRE-05a | **DONE 2026-06-16 — buy-burn bid-loop** (the exit half of CRE-05; `cre/buyburn-bid/`). The single-resting-bid automation via the CTR-01 report path. Gate green (wasip1 build + 14 tests). The REST of CRE-05 (the harvest engine legs 8-B5…8-B10 + main↔juniorTrancheSidecar rotation) remains — tracked as KEEPER-01b (harvest orchestrator, POLICY-BLOCKED) + KEEPER-01c (freeze commit, DEFERRED); there is no CRE-05b/05c. | §8.7 |

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
| FE-02 | Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` (approve→`zap`/`deposit`, `previewZap`/`previewDeposit`); ship the shared **1.3× gas-buffer tx helper** (EVC headroom — see Open obligations) all writes reuse | `ZipDepositModule` `0x6ecc…` + `ESynth`(zipUSD) `0xC5bd…` + `SzipUSD` `0x33aD…` | §4.5 (= INFLOW-06, realized) — **DONE 2026-06-11** |
| FE-03 | Position / NAV view: szipUSD + zipUSD balances + **$ value via `navExit`** (held = redemption price; `navEntry` for the entry hint only, caught; NOT `navPerShare` — absent); the lender portfolio screen | `SzipNavOracle` `0x0C3E…` + `SzipUSD` `0x33aD…` + zipUSD `0xC5bd…` | §7 / §12 — **DONE 2026-06-10** |
| FE-04 | szipUSD junior exit via the **CoW book** (rest a sell order + the §6.4 status track); wire `ZcWithdrawModal` | `SzipBuyBurnModule` `0x1288…` (CoW wiring + treasury bid) + `SzipUSD` `0x33aD…` (`approve(vaultRelayer)`) + `SzipNavOracle` `0x0C3E…` | §6.2 / §6.4 — **DONE 2026-06-11** |
| FE-05 | Borrower flow: line state + permissionless repay; wire `ZcDrawModal` / `ZcRepayModal` (CRE drives origination per §17 — UI reads line state + repays) | `EulerVenueAdapter` `0x87dC…` + `ZipcodeController` `0x3602…` | §4 / §15 — **DONE 2026-06-11** |
| FE-06 | **Solvency dashboard** (§12 metrics — NAV, zipUSD supply + peg, szipUSD NAV/share + trailing APR, utilization / free liquidity, insurance coverage) via **direct on-chain view reads** (no subgraph for MVP); wire `ZcStatCard` grid / `ZcVaultAllocationTable` | `SzipNavOracle`, zipUSD, farm utility `IEVault` `0x1aFc…`, warehouse Safe `0xe028…` | §12 — **DONE 2026-06-11** |
| FE-07 | **Euler-native vault dashboard**: surface the real farm utility EVK market + senior EE pool through euler-lite's OWN lend/borrow/earn pages (largely FE-00 config + the local labels file — this is the "show euler data / particular vaults" surface) | farm utility `IEVault` `0x1aFc…` + EE pool `EulerEarn` `0x1a7A…` | §4.7 — **DONE 2026-06-11** |

INFLOW-06 (`build/tickets/frontend/INFLOW-06-deposit-module.md`) is the **FE-02 draft** — its "address config depends
on item 10 / reads a placeholder" notes are now discharged (use the anvil board); its `abis/`/composable files live in
the **layer**, not in euler-lite.

### Subgraph — deferred (FE track runs without it)
Still gated on item-10 freezing the §9 event ABIs; the MVP runs on **direct on-chain view
reads** (FE-06), not a subgraph. Author a subgraph spec later if/when aggregated history is needed; do not block the FE
track on it.

---

## Open obligations / seams

- **SEAM-1 — CRE-03's material-move http trigger (DEFERRED, additive own-later).** §8.6 cadence is "push on the
  engine epoch **AND** on a material leg move." `cre/sharefeeds/` (CRE-03, DONE) ships the engine-epoch `cron`
  handler only; the material-move `http.Trigger` second handler is an additive own-later — **liveness-safe to
  defer** (the band clamp already converges large moves across epochs and the LP feed is liveness-only
  fail-closed), but the "AND material move" clause is carried here so it isn't lost. When built it reuses the
  same node-mode observe → DON-mode reads → coherent compose → two-WriteReport path; only the trigger differs.

- **SEAM-2 — the xALPHA RATE producer (`cre/szalpha-rate`, 8x-02) is BLOCKED + UNTRACKED-until-now.** CRE-03 was
  narrowed to NAV_LEG + LP_MARK (the APR is on-chain-derived, §8.8; the raw RATE push, reportType 8 →
  `SzAlphaRateOracle`, is a SEPARATE producer). That producer exists only as a **pre-CRE-00 stub** at
  `cre/szalpha-rate/main.go` (stale local encoders + `WriteReportRequest` form; an unimplemented `readExchangeRate`).
  It is **blocked on R-1**: proving a CRE wasip1 workflow can read the Subtensor-964 `0x805` StakingV2 precompile
  via `exchangeRate()` (the "8x exception" says a typed call may never reach it). It is ALSO downstream of 8x-01's
  lane being live (until then it points at the 18-dp xALPHA stand-in). **Owed work when unblocked:** rewrite it to
  the CRE-00 idiom — import `cre/zipreport.Rate` (the encoder already exists, rt8 `(uint256 rate, uint48 ts)`),
  the `cre/buyburn-bid` read idiom, the `WriteCreReportRequest` write — i.e. the same modernization CRE-03 did for
  the NAV/LP feeds. **Not cold-buildable now** (R-1 is a real external unknown). Logged here so the de-scope from
  CRE-03 doesn't lose it; it is NOT a near-term build item.

- **CRE-02b — redemption funding automation — BUILT (default-OFF) 2026-06-20** (`74b6c5c`; ticket
  `build/tickets/cre/CRE-02b-redemption-funding.md`). CRE-02's (K) `RedemptionJob` is REACTIVE (settles/claims
  what's there, never funds). Funding = the (R) warehouse **REDEEM→REPAY** (`cre/warehouse`, CRE-04) — a transport
  the keeper can't emit. CRE-02b sizes + fires it: a reserve-gated floor that actively refills (the funding twin of
  CRE-05a's bid), derived **through the existing reserve gate** (`covered()`/`harvestReserve`/`safetyBuffer`).
  **Open fork RESOLVED → (b) fold into `cre/warehouse`, and it is FORCED:** `WarehouseAdminModule` (a
  `ReceiverTemplate`) pins ONE `expectedWorkflowId`, so only the pinned workflow can `WriteReport` to it — a
  separate orchestrator can never get write authority; the sizing must live in the same binary (CRE-04's own
  `observe` docstring anticipated this hook). **Built** as a second default-OFF `cron` handler (`onFundingTick`)
  alongside CRE-04's unchanged http path — see the window note below. **Ships default-OFF** (`fundingEnabled=false`
  ⇒ zero reports); manual ops POSTs are the M1 path. Idempotent/self-healing. The cross-silo chooser is the still-
  owed **CRE-02c** (below).
- **CRE-02c — cross-silo redemption solver — BUILT (default-OFF) 2026-06-20** (committed; ticket
  `build/tickets/cre/CRE-02c-redemption-solver.md`; window note near the top of this file).
  The mutualized senior has ONE shared queue but N warehouses (one EE pool per silo). Funding a redemption must
  CHOOSE which pool(s) to REDEEM from + the split, respecting each pool's free liquidity + coverage gate (never
  over-redeem into a freeze). That chooser = the solver (CRE-02b's multi-warehouse generalization), a third
  default-OFF `cron` handler in `cre/warehouse`. **Open fork RESOLVED at scoping → pro-rata by GATED free-liquidity**
  (`availP`): a starved/undercovered pool gets weight 0 ⇒ skipped automatically. Utilization-balancing +
  curator-priority are own-later upgrades. Ships default-OFF; ops picks the pool by hand in M1.
- **CTR-14 — multi-tranche redemption topology (TICKETED 2026-06-20, `build/tickets/contracts/CTR-14-multi-tranche-redemption-topology.md`).**
  The off-ramp is built single-requester/single-Safe (`OffRampModule` clone pinned to one `juniorTrancheSafe`;
  `ZipRedemptionQueue` reverts `MultipleRequesters` for a 2nd concurrent requester; single `redeemController`), but
  the federation admits N silos with (plausibly) N junior Safes. So multiple products can't concurrently use the
  one shared queue — they serialize. Throughput/liveness limit, NOT fund-safety. Open fork: (a) serialize through
  one queue [M1 rec], (b) one queue per tranche, (c) multi-requester queue rebuild. Decision owed before a 2nd
  product's redemption cadence contends. **Option (a) keeper-half PREPARED 2026-06-20 (CRE-02-R1, `499f811`):**
  `RedemptionJob`'s escrow leg now waits its turn via `queue.pendingRequester()` (no-op today, graceful when a 2nd
  Safe arrives). Remaining for (a) = the contract-side fork decision + the per-Safe-clone deploy runbook + a revert
  assert; no contract change.
- **DEPLOY OBLIGATION (raised 2026-06-20, CRE-02) — `KEEPER_ADDR_ZipRedemptionQueue == OffRampModule.queue()`.**
  The keeper's startup `IdentityCheck` validates the queue `controller()` on the **configured** queue address,
  while `RedemptionJob` resolves the LIVE queue off `offramp.queue()` each tick (§17 re-pointable). Deploy must
  wire + assert these two are the same address (and that the keeper signer is BOTH `OffRampModule.operator` AND
  `ZipRedemptionQueue.controller`). Mark DISCHARGED at item-10 deploy wiring.

- **SYSTEMIC SEAM (raised 2026-06-16, CTR-01) — RESOLVED 2026-06-16 by `build/tickets/cre/CRE-OPS-ROUTING.md`.**
  The per-module write-path decision is made: **(R) report path only for 8-B14**; **(K) the single trusted
  operator/keeper for the engine harvest loop (8-B5…8-B10), the redemption operator sequencing (`OffRampModule` +
  `ZipRedemptionQueue`), and `ExitGate.burnFor`**; **`DurationFreezeModule` stays DORMANT** (on-chain `covered()`
  is the fail-closed backstop). `RecycleModule.creditFreeValue` is (K) on principle — report-driving it re-opens
  the §4.5.1 oracle-manipulation exploit. **CTR-01's socket is the exception, not the template** — no further
  sockets owed. Spawns **KEEPER-00** (keeper-service scaffold) + **KEEPER-01** (= rest of CRE-05 + burnFor +
  freeze-on-exception); CRE-02 is confirmed (R)+(K) hybrid. Recorded in `claude-zipcode.md` §8.7. The original
  seam description (kept for context):
  > `cre-sdk-go`'s evm client has reads + exactly ONE write — `WriteReport` (DON-signed
  → Keystone Forwarder → `IReceiver.onReport`); there is **no raw-tx / keeper primitive**. So a wasip1 CRE workflow
  can only drive contracts that are **report receivers**. Today that is: `WarehouseAdminModule`, `SzipNavOracle`,
  `SzipFarmUtilityLpOracle`, `DefaultCoordinator`, `ZipcodeController`, `ZipcodeOracleRegistry`, `SzAlphaRateOracle`
  — and now **`SzipBuyBurnModule`** (CTR-01). The following are gated `msg.sender == operator`/`controller` and
  thus **cannot be driven by CRE as built**: `FarmUtilityLoopModule` (8-B5), `LpStrategyModule` (8-B6),
  `HarvestVoteModule` (8-B7), `ExerciseModule` (8-B8), `SellModule` (8-B9), `RecycleModule` (8-B10),
  `DurationFreezeModule`, `OffRampModule`, `ZipRedemptionQueue` (`settleEpoch`/`claim`), `ExitGate.burnFor`. **This
  blocks CRE-02 (`settleEpoch`/`requestRedeem`/`claim`) and the rest of CRE-05 (the engine loop).** Per-module
  decision owed: **(a)** adopt the reusable `CloneReportReceiver` base (CTR-01) to add a report socket (clone-safe,
  fail-closed; what 8-B14 did), OR **(b)** drive it from an **off-chain keeper** holding the operator/controller
  hot key (standard go-ethereum tx submission, outside the CRE sandbox). The §8.7 spec exception + the rationale
  are recorded in `claude-zipcode.md` §8.7. Not a code fix owed yet — a track-shaping decision before CRE-02/05.

- **DEP SEAM (raised 2026-06-16, CRE-05a) — the CRE workflows bind to the IN-TREE `reference/cre-sdk-go`
  snapshot, not a published release.** `cre/buyburn-bid/go.mod` uses `replace` → `reference/cre-sdk-go` because
  the published releases (`cre-sdk-go@v0.10.0` / capability `@…beta.0`) LACK APIs the build relies on:
  `evm.WriteCreReportRequest` (the public write type — published has only the inner `WriteReportRequest`),
  `testutils.SetTimeProvider`, and some `evm` chain-selector consts. Until the published SDK catches up (or the
  snapshot is vendored/pinned for the real CRE deploy), every `cre/*` workflow should `replace` to the in-tree
  snapshot. Also: go-ethereum v1.17.2's `abi.Pack` wants a NATIVE `uint32` (not `*big.Int`) for a `uint32` arg —
  produced bytes identical; noted in `cre/buyburn-bid/workflow.go`. Not a code fix owed; a build/deploy note.

- **DEPLOY OBLIGATION (raised 2026-06-16, CTR-01) — `DeployZipcode` must wire the buy-burn report socket
  post-clone.** After cloning `SzipBuyBurnModule`, the deploy must call `setForwarder(keystoneForwarder)` +
  `setExpectedWorkflowId(WORKFLOW_ID)` (and optionally `setExpectedAuthor`) on it, else the report socket stays
  inert (fail-closed — `onReport` reverts `InvalidForwarder`). The operator path works without this; only the CRE
  report door needs it. Mirror the `setExpectedWorkflowId(...) != 0` assert pattern §9 already mandates for the
  other `ReceiverTemplate` subclasses before the Timelock hand-off. Not a contract change; a deploy-runbook step.

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

- **TODO (raised 2026-06-19, CTR-09) — CRE-01 must size `cap` and `drawAmount` for `amount + fee`, not `amount`.**
  CTR-09's draw fee is **financed** (`EulerVenueAdapter.draw` borrows `amount` to `erebor` AND `fee = amount *
  feeBps / 10_000` to `feeRecipient` on the same `borrowAccount`), so the line's debt becomes `amount + fee` (a
  $50,000 draw at the default 50 bps → **$50,250** of debt; the originator still receives the full $50,000 at
  `erebor`). Both per-draw gates must clear `amount + fee`: (a) the **per-line borrow cap** — the RT_ORIGINATION
  `cap` field (§8.1) flows to `setLineLimits` → `setCaps(0, cap)`; a `cap == amount` exactly reverts the fee leg
  on the borrow cap; (b) the **LTV × mark** collateral headroom (end-of-batch `E_AccountLiquidity`). So the
  origination/draw producer must set `cap ≥ amount + fee` and size the draw so `amount + fee` fits the LTV. The
  contract deliberately does NOT auto-inflate the cap — the producer owns sizing. Only bites when the fee is ON
  (`feeRecipient != 0`, default OFF). Not a contract change owed; a CRE-01 producer constraint. Truth:
  `docs/wires/WOOF-04.md` (`draw` entry).

- **CTR-13 DONE 2026-06-19 — the line APR is now a real flat ~7.5% IRM (was `ZeroIRM`); `f` left dormant; curator
  fee added.** The per-line borrow vaults run a flat `IRMLinearKink` (`script/LineIrm.sol`,
  `baseRate = 0.075·1e27 / SECONDS_PER_YEAR` per-second RAY, units VERIFIED against EVK `Cache` accrual; per-second
  compounding ⇒ effective APY ~7.788%), wired into the adapter `irm` slot (`setIrm`; every `openLine` installs it at
  `EulerVenueAdapter.sol:323`). The **farm utility** borrow vault stays on `ZeroIRM` (internal POL, §4.5.1) — the adapter
  `irm` slot and the farm utility IRM are independent. NO new `src/` contract for the rate (reuses EVK `IRMLinearKink` +
  the existing `setIrm`/`setInterestRateModel`). Fresh-deploy only (no live lines to roll off).
  **EE perf-fee `f` left DORMANT at 0** (recipient pre-wired to the warehouse Safe): the warehouse Safe is the SOLE
  senior EE-share custodian, so net line interest already accrues to it via share appreciation — a non-zero `f` would
  mint fee-shares to the pool's own owner (a no-op until external senior LPs ever deposit, post-M1). This reverses the
  ticket's "set `f`" step after the economics review.
  **Curator fee added (claw-back from Euler).** New Timelock-settable `EulerVenueAdapter.curatorSafe` slot
  (`setCuratorSafe`, `WiringSet`); every `openLine` sets it as the line vault's EVK `feeReceiver`, so the GOVERNOR
  share of the line vault's default 10% `interestFee` (Euler capped at 50% ⇒ ~5% of gross line interest) routes to the
  curator instead of forfeiting 100% to Euler. `address(0)` = off (forfeit). Wired in
  `DeployZipcode`/`DeployLocal`/`DeployMainnet` (P1 step 8b; `CURATOR_SAFE` env / `ANVIL_6` local) AND `SiloDeployer`
  (per-silo `SiloParams.curatorSafe`, for when the federation path goes live). Arrives as per-line-vault fee-shares
  (claim via the vault's `convertFees()` → redeem to USDC).
  Fork-tested: `EulerVenueAdapter.t.sol` `test_CTR13_*` (rate proof; a real line accrues ~7.5% while a `ZeroIRM` line
  accrues 0 over a year; curator-fee split ≥ Euler's). Doc-sync: `claude-zipcode.md` §5 + `docs/wires/WOOF-04.md`.
  Truth: `docs/wires/WOOF-04.md` (`draw` entry, APR note). **Uncommitted (working tree).**

- **RESOLVED INTO A WORKSTREAM (2026-06-18) — concurrent-line ceiling.** This TODO (raised 2026-06-15 ticketing
  SEC-06) is now the **Credit-warehouse scaling + federation** workstream above (CTR-02..CTR-10). Decision: shard
  across multiple EE pools (option a) — it keeps per-line EVK isolation and makes senior NAV a Σ of audited EE
  share values; the shared-vault topology (option b) was rejected (it sacrifices isolation). Note the original
  "~29 concurrent" was imprecise on two counts: (i) two non-line markets per pool → **28**, not 29; (ii) `closeLine`
  reclaimed only the SUPPLY queue, so closed lines did NOT free the binding withdraw-queue slot → ~28 *lifetime*, not
  concurrent — **fixed by CTR-04 (DONE 2026-06-18); a pool now churns 28 *concurrent* lines.** See the workstream
  ledger for the full decomposition.

- **RESOLVED (2026-06-13/16) — `DurationFreezeModule` rework.** The 2026-06-12 "incomplete" concerns (premise
  obviated; can't act on staked LP; `ichiVault` placeholder) are SUPERSEDED in the built code: it is now a
  debt-pinned coverage floor (`requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`), the staked
  LP is counted IN PLACE via `pathLockedLpEquity()`, and `covered()` gates the real outflows
  (`SzipBuyBurnModule.postBid`, `LpStrategyModule.removeLiquidity`); the `ichiVault` placeholder + coverage knobs
  were removed. Dormant `commit`-on-shortfall lever = KEEPER-01c. Truth: `build/wires/DurationFreezeModule.md`.

- **BLOCKED (external, not build work) — the real szALPHA/zipUSD Hydrex LP pool is NOT yet active, so
  `SzipNavOracle` can't be wired to it.** The junior NAV's LP leg can only price our pool once Hydrex stands up the
  szALPHA/zipUSD vAMM pool + the Ichi strategy (upstream of us; needs szALPHA bridged + live — see `docs/bridge.md`
  / `hydrex-demo-fork`). Until that pool exists, `SzipNavOracle.ichiVault` stays on the **WETH/USDC stand-in**
  (`0x07e72E46…`) and the LP code path is exercised only by the demo vAMM fork (`SzipNavOracleDemoVAMM`). The wiring
  surfaces already exist (`setLpPosition`/`setFarmUtilityLeg`, Timelock-settable), so when the pool is live it is a
  deploy/fork-wiring step (create+stake gauge → escrow vault → `setLpPosition` → CRE-03 `LP_MARK` feed), NOT a
  contract change. One verification owed at that point: confirm the LP-leg read (`_legPriceOfToken` spot
  `getTotalAmounts()`) is not flash-skewable for the real pool — if the TWAP bracket doesn't defend, that becomes a
  hardening ticket. NB fork trap: while `ichiVault` points at WETH/USDC, that LP in a Safe reverts
  `UnknownLpToken(WETH)` and bricks NAV reads.

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
      the rq Safe driven by `OffRampModule`; `requester == owner == juniorTrancheSafe`). A retail lender **cannot** enter it or
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
      a **direct** `usdc.approve(lineRef, amount)` to the line vault (NOT Permit2 — `FarmUtilityLoopModule.repay:251`).
      Any wallet may repay (credits `borrowAccount`, no controller-enablement/operator bit) — the §4.4e permissionless
      property. `full`→`type(uint256).max` (EVK clamps; a finite over-repay reverts `E_RepayTooMuch`).
    - **No back-pressure obligation owed** — every read (`getLine`/`observeDebt`/`getLien` + the `LienOriginated`/
      `LienStatusUpdated`/`LienReleased` events) and the EVK `repay`/`debtOf`/`asset` all exist. The implied borrower
      "draw" write was never owed; it is CRE-driven by design. **No `claude-zipcode.md` change** (§4/§9/§15 already
      correct). Ticket-precision note: `getLine` returns a **named-tuple struct** (viem → object, read by field name),
      not a positional tuple — the ticket wording was corrected.
    - **New FE seam:** `useZipTx.sendRawZipTx({to,abi,functionName,args})` writes to a **runtime/non-registry address**
      (per-line vaults) reusing the shared 1.3× buffer — the spine for any dynamically-discovered-contract write.
- **FE-07 Finding A — DISCHARGED 2026-06-19 by CTR-06a.** `FarmUtilityMarketDeployer.deploy` now hands the borrow-vault
  governor to the Timelock (`IEVault(borrowVault).setGovernorAdmin(p.governor)`, step 6, alongside the router transfer);
  `test_deployer_governor_RETAINED` asserts `governorAdmin() == governor` (proven load-bearing: the assert fails without
  the fix, where the governor is the throwaway deployer instance). **Live-fork caveat retained:** this fixes all FUTURE
  deploys; the ALREADY-DEPLOYED anvil borrow vault keeps its stranded governor until a redeploy — FE-07's `entities.json`
  must still re-read `governorAdmin()` after any redeploy (that row already says so). Original finding kept below for
  context:
  - The farm utility **borrow vault's `governorAdmin` is never transferred to the Timelock** — it stays
  the throwaway `FarmUtilityMarketDeployer` instance (`0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa` on the current fork).
  `FarmUtilityMarketDeployer.deploy` (`contracts/script/FarmUtilityMarketDeployer.sol`) transfers only the **router**
  governance (`EulerRouter(router).transferGovernance(p.governor)`, `:88`); the borrow vault is created via
  `factory.createProxy` (deployer = governor at birth, `:77`) and never gets `setGovernorAdmin(p.governor)`. The comment
  at `:75` ("Governor RETAINED so the Timelock can tune LTV/caps") is **wrong for the borrow vault** — the Timelock
  cannot govern it; the deployer can. **Fix owed:** add `IEVault(borrowVault).setGovernorAdmin(p.governor)` in
  `FarmUtilityMarketDeployer.deploy` (alongside the router transfer) so the borrow vault is Timelock-governed (§17
  Timelock-settable-not-frozen). Once fixed, the live `governorAdmin` becomes `0x89ae…` (already in FE-07's
  `entities.json`) and the deployer entry can be dropped. **FE interim (shipped):** FE-07 declares the live deployer
  address so the farm utility market verifies in the UI today; `0x77C2Cb…` is nonce-derived, so re-read `governorAdmin()`
  and update `entities.json` after any redeploy that moves it. **TICKETED 2026-06-18 as CTR-06a**
  (`build/tickets/contracts/CTR-06a-farm utility-governoradmin-fix.md`) — add `IEVault(borrowVault).setGovernorAdmin(p.governor)`
  + a post-assert; mark this obligation DISCHARGED when CTR-06a lands.
- **DEPLOY OBLIGATION (raised 2026-06-18, CTR-03) — wire the controller↔SiloRegistry pair before the first
  origination.** The `ZipcodeController` now resolves venue + slot-accounting through `SiloRegistry`. The deploy
  MUST: (a) `controller.setRegistry(siloRegistry)`; (b) `siloRegistry.setController(controller)` (its
  `incrementLineCount`/`decrementLineCount` are `onlyController`); (c) register silo #0 (`addSilo`) whose `adapter`
  equals the controller's ctor `venue` seed; (d) assert `siloRegistry.controller() == address(controller)`
  post-deploy. Until (a)+(b), every origination reverts `RegistryUnset`/`NotController` (and every close at the
  decrement). Symmetric to the existing `oracleRegistry.setController` step (WOOF-05 item-10 S6). Folds into the
  CTR-06 `SiloDeployer` runbook. Not a contract change owed; a deploy-wiring step. **DISCHARGED-as-runbook 2026-06-19
  by CTR-06c** — the D2 hub-grant runbook (`docs/wires/CTR-06c-SiloDeployer.md` + the `SiloDeployer` NatSpec) documents
  + prank-tests the per-silo `addSilo`/`setCurrentSilo` + the `zipUSD.setCapacity` grant; the one-time hub half
  (`controller.setRegistry`/`siloRegistry.setController` + silo #0 registration) is CTR-03/`DeployZipcode`, already
  done. Remains an operational deploy step (no contract change), now fully specified.
- **CRE report ABI seam.** Every CRE report payload must `abi.decode` to the §4.4 layout the filed
  `ZipcodeController` / `ZipcodeOracleRegistry` expect (reportTypes 1/2/4/5/6 → controller, 3 → registry).
- **Subgraph blocked** until item-10 freezes the §9 event signatures.
- **RUNBOOK — `ExitGate.setBaal` managerLock parity (a trusted-admin footgun).** `ExitGate.setBaal` (`:114`,
  `onlyOwner`/Timelock) can re-point to a different Baal; if that Baal has `managerLock == true`, the Gate's
  `manager(2)` grant can no longer be re-set → deposits/`burnFor` brick (fail-closed). Only reachable via a Timelock
  re-point to a hostile/locked Baal (build-phase wiring is deliberately settable, §17; the Timelock owner is trusted,
  §13) — same class as the `WarehouseAdminModule` `setSafe`/`setAvatar` parity footgun. No code fix owed; **before any
  `setBaal`, assert the target Baal's `managerLock() == false`.**
- **DEFER — on-chain draw-time coverage gate (ABANDONED 2026-06-16).** A portfolio-level "total debt ≤ junior-backed
  capacity" gate at borrow time was considered and **dropped**: a draw can only borrow USDC physically present in the
  EulerEarn pool (senior deposits), so pool liquidity already hard-bounds total draws; plus per-line LTV/cap + the two
  `covered()` outflow gates. No credible path where draws outrun coverage. Don't re-propose. If ever revisited: a
  `zipUSDValue()` TWAP-bracketed view + an `illiquidSeniorValue() + draw <= zipUSDValue()` check in the draw path.
- **LOSS — the default/slash flow is M2, not M1-live (from `src/loss/` headers, recorded 2026-06-17).**
  `LienXAlphaEscrow`'s custody half (`lockXAlpha`/`releaseXAlpha`) is M1-live; the slash half
  (`slashXAlphaToCapital`/`slashXAlphaToCohort`) + the `DefaultCoordinator` driver are built + mock-tested but go
  live in M2. The driver is **CRE-01's `rt8` default/recovery action family — now BUILT as CRE-01c
  (`cre/coordinator/`, 2026-06-20; note above).** The off-chain producer is complete; what remains for M2 is
  OPERATIONAL — firing the economic actions (DEFAULT/RECOVERY/RESOLVE/WRITEOFF) on a real default + the off-chain
  capital-sink liquidation account (xALPHA→USDC on Bittensor). No contract code owed; no CRE code owed — it's M2
  sequencing + that operational account.
- **LOSS — cohort-premium routes to the MAIN Safe (CTR-11 DONE 2026-06-19; the CRE flow stays M2).** `LienXAlphaEscrow`
  now sends `slashXAlphaToCohort` to a `juniorTrancheSafe` slot wired to the engine/main basket Safe (was the
  inert `juniorTrancheSidecar`). The slot replaces the old `juniorTrancheSidecar` slot (distinct name — `juniorTrancheSidecar` is a freeze concept), with
  `setJuniorTrancheSafe` (onlyOwner/Timelock/`WiringSet`/zero-guard); `slashXAlphaToCapital → adminSafe` is
  unchanged; the three-destination integrity thesis holds (`{bondOriginator, adminSafe, juniorTrancheSafe}`).
  Deploy wires it = `sub.juniorTrancheSafe` in `DeployZipcode` + `JuniorTrancheDeployer` (juniorTrancheSafe already asserted distinct
  from the warehouse Safe). Tests + docs synced (`LienXAlphaEscrow.t.sol`/`DefaultCoordinator.t.sol`; `docs/loss.md`,
  `wires/8-Bx-LienXAlphaEscrow.md`). 243 tests green. The slash-triggered CRE flow that processes it stays M2
  (KEEPER-01b/CRE-01). **Original design note (2026-06-18) retained below for the rationale.**
  As-built, `LienXAlphaEscrow.slashXAlphaToCohort` parks the premium xALPHA in the **juniorTrancheSidecar** Safe and the natspec
  treats it as in-kind ("never market-sold; NAV does the cohort pro-rata for free"). But the flywheel modules
  (`SellModule`/`LpStrategyModule`/Gate) all operate on the **engine Safe (== `juniorTrancheSafe`, DeployZipcode:384)**, so they
  can't reach juniorTrancheSidecar xALPHA — the premium just sits there. **Decision:** route the cohort slash to the **main Baal
  Safe** so the existing yield-flywheel modules can subsume it (xALPHA → zipUSD → LP backing), lifting shares the
  same way emissions do; and add a **slash-triggered CRE flow that REUSES the existing Zodiac flywheel modules —
  NO new modules** (`SellModule` already does the `zipUSD↔xALPHA` POL swap on the engine Safe; the slash flow IS
  the yield/harvest sequence, just triggered on a slash or subsumed by the normal harvest cadence). Fold into the
  harvest orchestrator KEEPER-01b / the CRE-01 loss leg. **The CONTRACT half (retarget the destination + natspec) is
  ticketed as CTR-11** (`build/tickets/contracts/CTR-11-cohort-slash-to-main-safe.md`) — safe to land independently
  (rerouted xALPHA is swept by the normal harvest vs stranded in the juniorTrancheSidecar today). The slash-triggered CRE flow
  stays M2. Implications handled in CTR-11: (a) the destination + natspec change; (b) the premium then lands in FREE
  value, not the committed juniorTrancheSidecar bucket — confirmed intended for the freeze-floor accounting (a stayer bonus
  should be liquid/sellable; gross NAV unchanged, xALPHA stays a movable leg).
- **LOSS — designate the real treasury Safe for the capital-hole recovery (recorded 2026-06-18).** The
  destination is renamed `capitalSink` → `adminSafe` by **CTR-12** (contract rename) — naming it the protocol
  treasury Safe. `slashXAlphaToCapital` routes the slashed bond there; today it's only a deploy-config placeholder.
  The remaining OPERATIONAL half (M2): create + wire the real treasury Safe and stand up its off-chain process
  (receive slashed xALPHA → bridge to Bittensor → liquidate alpha → TAO → USDC → return USDC to cover the realized
  hole, §11). Ops deliverable, not contract code (the rename is CTR-12; the Safe + bridge process is M2 ops).
- **PRE-PROD — re-freeze ALL build-phase wiring to immutable (§17, repo-wide; recorded 2026-06-17).** This is a
  deliberately-deferred, **protocol-wide** end-of-build step, not a loss-side task: every contract carries
  Timelock-settable wiring (each cross-component pointer is re-pointable — `harness.md` locked decision #6), and
  the immutability lock-down is deferred to pre-prod. The loss side is just one instance — `LienXAlphaEscrow`'s
  four slots (`xAlpha`/`coordinator`/`capitalSink`/`juniorTrancheSidecar`) + `DefaultCoordinator.setEscrow` (onlyOwner, NOT
  set-once) — alongside `WarehouseAdminModule`, `EulerVenueAdapter`, `ZipcodeController`, `CREGatingHook`, the
  oracles, `DurationFreezeModule`, etc. Until the lock-down, the trusted Timelock owner can re-point any of them
  (grief/redirect, never drain — §13). When ticketed, it is ONE repo-wide "freeze wiring to immutable" pass.

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
