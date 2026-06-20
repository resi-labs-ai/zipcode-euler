# CTR-15 — "reservoir" → purpose-true rename (monorepo; naming-only)

> Build ticket. **Naming-only — zero behavior change.** Companion: `build/tickets/frontend/FE-09-reservoir-farmutility-rename.md`
> (the frontend layer repo). The two MUST land in the **same release** — this ticket changes contract getter
> selectors the frontend calls. Branch: `rename/reservoir-to-farmutility`.
>
> **SELF-EXCLUSION (2026-06-20):** this ticket + FE-09 are the rename's SPEC — their old→new tables are
> load-bearing documentation, so they are deliberately **excluded from the build/tickets/** history sweep**
> (a blanket sweep collapses every "X → Y" row into "Y → Y"). Old `reservoir*`/`baseUsdcMarket` names appear
> here AS the rename source and are correct; do not sweep them.

## Context — why
The codebase uses the word **"reservoir" for the strike-loop BORROW vault** (the vault USDC is borrowed from,
against the ICHI LP, to exercise oHYDX), while the **idle-USDC store is `baseUsdcMarket`**. Verified ground truth
(the wiring, not comments): the EE supply queue points at `baseUsdcMarket` (`script/DeployLocal.s.sol:113-119,153-155`);
`baseUsdcMarket` holds idle depositor USDC; `reservoirVault`/`borrowVault` is funded just-in-time and holds ≈0 at
rest. The names are inverted relative to purpose (a wire-doc comment `8-Bw:169` even calls the borrow vault the
"resting vault"). Fix: make names match purpose.

## How this ticket runs — discovery → confirm one-at-a-time → apply (MANDATORY)
**Do NOT sweep-and-replace.** Three phases:

**Phase A — Discovery (fan-out sub-agents).** One agent per area: contracts `src/venue`+`src/supply`; deploy
`script/`; CRE `cre/{keeper,sharefeeds,buyburn-bid,warehouse}`; docs+ABIs `docs/`+`build/anvil/abi`; tests + history
(`build/tickets/**`, `audit/`). **`docs/wires/` (via `COVERAGE.md`) is the guide** — each agent looks up what every
`reservoir*`/`baseUsdcMarket`/`freeReservoir` symbol IS and what it binds/validates against before proposing a
rename. Each returns rows for the table below.

**Phase B — Confirm with the reviewer ONE ITEM AT A TIME.** For each row, the builder states in plain language: what
the symbol is (grounded in wires), what we're renaming and why, the proposed name, and any selector/ABI/config-key
impact — then waits for the reviewer to confirm or adjust. Mark `status = confirmed: <final name>`. **No file is
edited before its row is confirmed.**

**Phase C — Apply** confirmed rows in the sequenced order; gate after each phase. `LEAVE` rows recorded as
deliberately untouched.

## Starting vocabulary (the Phase-A proposal; reviewer ratifies per row)
- **Idle store** `baseUsdcMarket` → **`usdcReservoir`** ("USDC Reservoir"); env `BASE_USDC_MARKET` → `USDC_RESERVOIR`.
- **Strike-loop borrow vault + ecosystem** `Reservoir*` → **`FarmUtility*`** ("Farm Utility Credit Vault"):
  `reservoirVault`→`farmUtilityVault`, `reservoirAllocator`→`farmUtilityAllocator`,
  `fundReservoir`/`defundReservoir`→`fundFarmUtility`/`defundFarmUtility`,
  `setReservoirVault`/`setReservoirAllocator`/`setReservoirLeg`→`setFarmUtility*`,
  `NotReservoirAllocator`/`onlyReservoirAllocator`/`ReservoirLegSet`/`ReservoirHookBlocksReallocate`/
  `SeamReservoirGovernor`→`FarmUtility*`, `_reservoirDebt`→`_farmUtilityDebt`, helpers
  `_wireReservoir`/`_reservoirParams`/`reservoirIrm`/`reservoirRouter`/`reservoirRateRay`/`reservoirLoop`.
  Contracts/files: `ReservoirLoopModule`→`FarmUtilityLoopModule`, `ReservoirMarketDeployer`→`FarmUtilityMarketDeployer`,
  `ReservoirBorrowGuard`→`FarmUtilityBorrowGuard`, `SzipReservoirLpOracle`→`SzipFarmUtilityLpOracle`,
  `IReservoirDebt`/`IReservoirEscrow`→`IFarmUtility*`.
  CRE: config key `"ReservoirLoopModule"`→`"FarmUtilityLoopModule"` + env `KEEPER_ADDR_*`; `strike_loop_job.go`
  field `reservoir`→`farmUtility`; `main.go` `Reservoir:`→`FarmUtility:`.
  Docs: `docs/wires/8-B5-ReservoirLoop.md`→`8-B5-FarmUtilityLoop.md` (+ `COVERAGE.md`/`README.md`); x-ray
  `ReservoirBorrowGuard.md`→`FarmUtilityBorrowGuard.md`.

## Classification rule (the sweep is NOT mechanical)
Every `reservoir` hit is one of three — classify before editing:
- **idle store** ("resting-USDC market", "base USDC market", `baseUsdcMarket`, "idle reservoir") → `usdcReservoir`.
- **strike/borrow side** (the `Reservoir*` symbol family) → `farmUtility*` / "Farm Utility Credit Vault".
- **`freeReservoir`** + idle-store prose → **LEAVE** (it is `EulerEarn.maxWithdraw(warehouse)` = the idle store;
  after the rename "reservoir" == idle store, so it is now correct). **Never `freeFarmUtility`.** Highest-risk
  silent error — no blind `s/reservoir/.../`.

## Scope (locked with reviewer)
- Monorepo only (contracts, CRE, deploy, ABIs, docs). Frontend = companion FE-09.
- Sweep **everything incl. history** (`build/tickets/**`, `audit/`) — **EXCEPT this ticket + FE-09** (self-exclusion above).
- `freeReservoir` STAYS.
- Comments kept verbatim modulo symbol names; the `ReservoirBorrowGuard.sol:12-13` "borrow vault IS resting USDC"
  accuracy discrepancy → flag as a SEPARATE ticket, do not rewrite here.

## Proposed changes (Phase A fills; Phase B confirms each row)
Each row below is one decision Phase B walks through with the reviewer. `impact` flags bricking surface. `[CONFIRM]`
marks a genuine judgment call (cross-component or a non-"reservoir" token), not a mechanical follow.

> **PHASE B RATIFIED 2026-06-20 (reviewer walked every row one-at-a-time).** ALL rows 1–32 + 31b confirmed
> **as proposed** (the names in each row's "proposed name" cell). Carve-outs upheld: row 23 LEAVE
> `escrowVault`/`borrowVault` identifiers; row 29 LEAVE `freeReservoir` (must NOT become `freeFarmUtility`).
> Phase-A discovery additions ratified: (a) **NEW** — `contracts/src/interfaces/supply/ISzipNavBasket.sol:20`
> comment "net of reservoir strike debt" → "net of farm utility strike debt" (STRIKE, comment-only; added to
> the prose scope — it was not in the original table). (b) `contracts/broadcast/**` + `contracts/cache/` carry
> old names but are NOT git-tracked and regenerate on next deploy/build → **LEAVE** (out of sweep). Reviewer
> also ratified sweeping **src/*.sol comment PROSE** (classified), EXCEPT the `ReservoirBorrowGuard.sol:12-13`
> accuracy claim (kept for its separate ticket). Headline vocab ratified: idle `baseUsdcMarket`→`usdcReservoir`;
> strike `Reservoir*`→`FarmUtility*`.
>
> **APPLIED 2026-06-20 — ALL ROWS DONE.** Phases 1–5 landed on branch `rename/reservoir-to-farmutility`
> (commit 1 `f8cf6ed` = pre-existing audit work, separated out; commit 2 = this rename). Gates green:
> `forge build` + `forge test` (1001 passed / 0 failed / 3 skipped — identical to baseline); CRE
> `go build`+`go vet`+`go test -count=1` + `GOOS=wasip1` builds across keeper/sharefeeds/zipreport/warehouse/
> buyburn-bid; `freeReservoir` preserved. ABI index diff = labels/paths only. Residual grep clean modulo the
> intentional `freeReservoir` + idle-store hits + this ticket/FE-09. **Separate ticket owed:** the
> `FarmUtilityBorrowGuard.sol:12-13` "borrow vault IS resting USDC" accuracy discrepancy (renamed in place; the
> factual claim left for that ticket). FE-09 (layer repo) must land same release.

| # | current identifier | file:line(s) | what it is / wires validation | class | proposed name | impact | status |
|---|---|---|---|---|---|---|---|
| 1 | `baseUsdcMarket` (var+getter+ctor) | EulerVenueAdapter.sol:61,168,179 | idle-USDC store at EE supply-queue head (`fund` withdraws idle cash) — 8-B5/WOOF-04 | IDLE | `usdcReservoir` | **getter selector** `baseUsdcMarket()`→`usdcReservoir()` | confirmed: usdcReservoir — DONE |
| 2 | `setBaseUsdcMarket()` | EulerVenueAdapter.sol:248 | Timelock setter for the idle store | IDLE | `setUsdcReservoir()` | **setter selector** | confirmed — DONE |
| 3 | env `BASE_USDC_MARKET` | Deploy{Zipcode,Mainnet}.s.sol, .env.example:40, DeployZipcode.t.sol | the idle-store address env key | IDLE | `USDC_RESERVOIR` | **env-key** (fail-loud) | confirmed — DONE |
| 4 | `baseUsdcMarket` usages | deploy scripts + ~60 test refs | follow-on refs to the idle store | IDLE | `usdcReservoir` | none (recompiled) | confirmed — DONE |
| 5 | `reservoirVault` (var+getter) | EulerVenueAdapter.sol:65 | strike-loop borrow vault (JIT-funded, ≈0 at rest) — 8-B5 | STRIKE | `farmUtilityVault` | **getter selector** | confirmed — DONE |
| 6 | `setReservoirVault()` | EulerVenueAdapter.sol:256 | Timelock setter | STRIKE | `setFarmUtilityVault()` | **setter selector** | confirmed — DONE |
| 7 | `reservoirAllocator` (var+getter) | EulerVenueAdapter.sol:72 | two-key allocator that funds/defunds the strike vault | STRIKE | `farmUtilityAllocator` | **getter selector** | confirmed — DONE |
| 8 | `setReservoirAllocator()` | EulerVenueAdapter.sol:271 | Timelock setter | STRIKE | `setFarmUtilityAllocator()` | **setter selector** | confirmed — DONE |
| 9 | `onlyReservoirAllocator` (modifier) | EulerVenueAdapter.sol:153 | gate on fund/defund | STRIKE | `onlyFarmUtilityAllocator` | internal | confirmed — DONE |
| 10 | `NotReservoirAllocator` (error) | EulerVenueAdapter.sol:129 | revert for non-allocator | STRIKE | `NotFarmUtilityAllocator` | **error selector** | confirmed — DONE |
| 11 | `ReservoirHookBlocksReallocate` (error) | EulerVenueAdapter.sol:132 | revert: vault hook blocks reallocate | STRIKE | `FarmUtilityHookBlocksReallocate` | **error selector** | confirmed — DONE |
| 12 | `fundReservoir()` | EulerVenueAdapter.sol:624 | move idle USDC → strike vault JIT | STRIKE | `fundFarmUtility()` | **selector** (ops/allocator caller) | confirmed — DONE |
| 13 | `defundReservoir()` | EulerVenueAdapter.sol:640 | inverse (strike → idle after repay) | STRIKE | `defundFarmUtility()` | **selector** | confirmed — DONE |
| 14 | `ReservoirLoopModule` (contract+file) | src/supply/szipUSD/ReservoirLoopModule.sol | 8-B5 strike-loop engine module | STRIKE | `FarmUtilityLoopModule` | **file rename** + imports | confirmed — DONE |
| 15 | `ReservoirBorrowGuard` (contract+file) | src/supply/szipUSD/ReservoirBorrowGuard.sol | EVK borrow-pin hook on the strike vault | STRIKE | `FarmUtilityBorrowGuard` | **file rename** + imports | confirmed — DONE |
| 16 | `SzipReservoirLpOracle` (contract+file+`name`) | src/supply/SzipReservoirLpOracle.sol:21,25 | CRE-fed LP_MARK collateral oracle (CRE-03 receiver) | STRIKE | `SzipFarmUtilityLpOracle` | **file rename**; CRE binds by ADDRESS not name (not bricking) | confirmed — DONE |
| 17 | `ReservoirMarketDeployer` (contract+file) | script/ReservoirMarketDeployer.sol | one-time strike-market deployer | STRIKE | `FarmUtilityMarketDeployer` | **file rename** + imports | confirmed — DONE |
| 18 | `setReservoirLeg()` | SzipNavOracle.sol:244 (callers DeployZipcode:522, JuniorTranche:315) | wires escrow+borrow vault leg into NAV | STRIKE | `setFarmUtilityLeg()` | **selector** [CONFIRM cross-component] | confirmed — DONE |
| 19 | `ReservoirLegSet` (event) | SzipNavOracle.sol:177 | emitted on leg wiring | STRIKE | `FarmUtilityLegSet` | **event topic** [CONFIRM] | confirmed — DONE |
| 20 | `_reservoirDebt()` | SzipNavOracle.sol:463 | reads strike debt for NAV | STRIKE | `_farmUtilityDebt()` | internal [CONFIRM] | confirmed — DONE |
| 21 | `IReservoirDebt` (interface) | SzipNavOracle.sol:30 | debtOf() on the strike vault | STRIKE | `IFarmUtilityDebt` | [CONFIRM] | confirmed — DONE |
| 22 | `IReservoirEscrow` (interface) | SzipNavOracle.sol:24 | balanceOf/convertToAssets on escrow vault | STRIKE | `IFarmUtilityEscrow` | [CONFIRM] | confirmed — DONE |
| 23 | `escrowVault`/`borrowVault` (storage) | SzipNavOracle.sol:113,117; ReservoirLoopModule.sol:45 | NAV/module refs to the escrow + strike vaults | STRIKE | **LEAVE the identifiers** | tokens do NOT contain "reservoir" — LEAVE; rename only their comments + #18-22 | confirmed: LEAVE — DONE |
| 24 | `SeamReservoirGovernor` (error) | SiloDeployer.s.sol:52,194 | revert: strike-vault governor != Timelock | STRIKE | `SeamFarmUtilityGovernor` | error (deploy-only) | confirmed — DONE |
| 25 | deploy helpers `reservoirLoop`/`reservoirIrm`/`_reservoirParams` | SiloDeployer.s.sol, JuniorTrancheDeployer.s.sol, DeployZipcode.s.sol | strike-loop deploy locals | STRIKE | `farmUtility*` | internal | confirmed — DONE |
| 26 | test labels/fn/contract names | test/* (makeAddr "reservoirAllocator", "reservoirEngineSafePlaceholder", `SzipReservoirLpOracleTest`, `test_reservoir_*`) | test-only identifiers | STRIKE | `farmUtility*` | test-only | confirmed — DONE |
| 27 | CRE keeper config-key+env+field | strike_loop_job.go:39,63,75,231,234; main.go:65,101,129,159; config.go; .env.example:46; keeper tests | `"ReservoirLoopModule"` key + `KEEPER_ADDR_ReservoirLoopModule` + struct field `reservoir`/`Reservoir` | STRIKE | `FarmUtilityLoopModule` / `KEEPER_ADDR_FarmUtilityLoopModule` / `farmUtility` | **config-key↔env coupling** (boot/`go test` trap) | confirmed — DONE |
| 28 | CRE comment refs `SzipReservoirLpOracle` | sharefeeds/workflow.go:13,63,260; zipreport/report.go (6); workflow_test.go:90 | comments only; `LpOracle` config field is an ADDRESS — keep | STRIKE | comment→`SzipFarmUtilityLpOracle` | comments only | confirmed — DONE |
| 29 | `freeReservoir` | buyburn-bid/workflow.go:133 (+tests); warehouse/funding.go:146 (+tests) | the idle-store read (`maxWithdraw`) — after rename "reservoir"==idle store, so already correct | LEAVE | **keep** | none — **must NOT become farmUtility** | confirmed: LEAVE — DONE |
| 30 | ABI artifacts | build/anvil/abi: ReservoirLoopModule.json, ReservoirBorrowGuard.json, SzipReservoirLpOracle.json; index.json entries (63-64,73-74) + 3 external labels (148,153,158,163); `baseUsdcMarket*` in EulerVenueAdapter.json | regenerate from `out/` to match renamed Solidity | both | rename files + `name`/`abi` strings (addresses unchanged) | ABI; index keyed by address (safe) | confirmed — DONE |
| 31 | wire + x-ray doc renames + links | `docs/wires/8-B5-ReservoirLoop.md`→`8-B5-FarmUtilityLoop.md` (+ COVERAGE.md/README.md links); x-ray FILE renames `ReservoirBorrowGuard.md`→`FarmUtilityBorrowGuard.md` **and `ReservoirLoopModule.md`→`FarmUtilityLoopModule.md`**; fix the x-ray index `portfolio-map.md` links | truth-source docs | both | rename files + fix links | doc | confirmed — DONE |
| 31b | x-ray audit-doc CONTENT sweep | `contracts/src/**/x-ray/*.md` (verified): ReservoirLoopModule.md, ReservoirBorrowGuard.md, portfolio-map.md, hydrex-demo-fork/x-ray/SzipNavOracleDemoVAMM.md, supply/lib/x-ray/{x-ray,invariants}.md, szipUSD/x-ray/{MastercopyInitLock,DurationFreezeModule}.md | per-contract audit docs — track the renamed identifiers | mixed | follow confirmed names (classification rule) | doc | confirmed — DONE |
| 32 | prose sweep | docs/** (~154/26 files), **contracts/test/** comments, build/** (incl. build/tickets/** + claude-zipcode.md + anvil contract-map/smoke-paths), audit/ (0); **+ src/interfaces/supply/ISzipNavBasket.sol** (Phase-A add) | classify per hit (idle vs strike vs freeReservoir-LEAVE) | mixed | follow confirmed names | mechanical, classification rule | confirmed — DONE (CTR-15/FE-09 self-excluded) |

## Phase C — Sequenced apply (compiles after each phase)
0. **Baseline green:** `forge build && forge test`; `go build ./... && go test ./...` in `cre/{keeper,sharefeeds,buyburn-bid,warehouse,zipreport}`.
1. **Solidity sources** (rename files + in-file symbols + ALL importers in one commit): the 4 file renames,
   contract/interface/error/event/modifier symbols, `_farmUtilityDebt`, the `EulerVenueAdapter` idle getter/setter.
   Files: `src/venue/EulerVenueAdapter.sol`, `src/supply/szipUSD/ReservoirLoopModule.sol`, `ReservoirBorrowGuard.sol`,
   `src/supply/SzipReservoirLpOracle.sol`, `src/supply/SzipNavOracle.sol`, `src/SiloRegistry.sol` (comment),
   `script/ReservoirMarketDeployer.sol`, + every importing test. **Gate:** `forge build`.
2. **Deploy scripts + env keys:** `DeployLocal/Mainnet/Zipcode.s.sol`, `SiloDeployer.s.sol`, `JuniorTrancheDeployer.s.sol`,
   `contracts/.env.example`, `SeamReservoirGovernor`. **Gate:** `forge build && forge test`.
3. **CRE keeper + sharefeeds:** `strike_loop_job.go`, `cmd/keeper/main.go`, `cre/keeper/.env.example`, keeper tests;
   sharefeeds comments only (`LpOracle` config is an address — keep the field). **Trap:** the Go string
   `"ReservoirLoopModule"` + env key are coupled — flip together (caught by `go test`/boot, not `go build`).
   **Gate:** `go build ./... && go test ./...` in keeper + sharefeeds + buyburn-bid + warehouse + zipreport.
4. **ABI artifacts:** rename the 3 ABI files; regenerate from `out/` per `build/anvil/abi/README.md`; update
   `index.json` `name`+`abi`; rename `baseUsdcMarket*`→`usdcReservoir*` in `EulerVenueAdapter.json`. **Gate:** `index.json`
   diff = only labels/paths.
5. **Docs + x-ray + test-comment + history sweep:** rename the `8-B5` wire doc (+ `COVERAGE.md`/`README.md`); rename
   the x-ray docs `ReservoirBorrowGuard.md` + `ReservoirLoopModule.md` (+ fix `portfolio-map.md` links); sweep
   `docs/**`, `contracts/src/**/x-ray/`, `contracts/test/**` (COMMENTS only), `build/**` (incl. `build/tickets/**`
   EXCEPT CTR-15/FE-09), `audit/` per the classification rule. **`docs/wires/COVERAGE.md`: also update the
   source-path cells** when files #14-17 rename.

## Bricking-risk table
| Risk | Affected | Mitigation |
|---|---|---|
| Getter/setter selector change `usdcReservoir()`/`farmUtilityVault()`/`setUsdcReservoir`/`fundFarmUtility` | deploy, tests, **frontend** | in-repo callers recompiled together; FE in FE-09, same release. No CRE reads these getters (verified). |
| CRE config-key + env rename | keeper boot (`config.MustAddr`) | flip Go string + `.env.example` + operator `.env` together; caught by `go test`/boot. |
| Deploy env `BASE_USDC_MARKET`→`USDC_RESERVOIR` | deploy/CI | fail-loud (empty read → revert); update RUNBOOK + CI secrets. |
| ABI file rename + `index.json` | FE ABI loader | index keyed by address (safe); update `abi` paths in lockstep; no consumer loads JSONs by literal path (verified). |
| `SzipReservoirLpOracle` rename vs CRE-03 LP_MARK receiver | sharefeeds | NOT bricking — receiver is the `LpOracle` **address**, not the contract name. |
| `freeReservoir` blind-replaced | CRE buyburn-bid/warehouse | **DO NOT rename** — different concept; classification carve-out. |

## Verification (after each phase + final)
1. `cd contracts && forge build && forge test`
2. `cd cre/keeper && go build ./... && go test ./...` (catches the config-key trap)
3. `cd cre/sharefeeds && go build ./... && go test ./...`; same for `buyburn-bid`, `warehouse`, `zipreport`
4. ABI regen per `build/anvil/abi/README.md`; `git diff build/anvil/abi/index.json` = only labels/paths
5. Residual grep (must be zero or an intentional `freeReservoir`/idle-store hit, or this ticket/FE-09):
   `grep -rniI "reservoir" contracts cre docs build audit --exclude-dir=reference --exclude-dir=out --exclude-dir=node_modules`
6. FE-09 filed + landing same release.

## Notes
- Next contracts ticket number is CTR-15 (CTR-14 latest). Do not touch the unrelated uncommitted working-tree
  changes (`SzipBuyBurnModule.t.sol`, x-ray files, `audit/`) — RESOLVED 2026-06-20: separated into commit 1
  (`f8cf6ed`) so the rename lands clean; `audit/` (embedded skills clone) left untracked.
