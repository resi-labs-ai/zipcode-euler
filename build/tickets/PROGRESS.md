# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**NEXT = reviewer picks.** One item moves at a time: finish it, set the next `NEXT`, STOP.

Forward candidates:
- **FE track** — the anvil-grounded frontend (Vue/viem in the `zipcode-finance-euler` layer). Lands last, once the rest is ready.

Shipped work is recorded in the commit history + `build/wires/` (this file does not re-narrate it). What remains lives in **Backlog** + **Open obligations** below.

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

- **DEPLOY OBLIGATION (raised 2026-06-20, CRE-02) — `KEEPER_ADDR_ZipRedemptionQueue == OffRampModule.queue()`.**
  The keeper's startup `IdentityCheck` validates the queue `controller()` on the **configured** queue address,
  while `RedemptionJob` resolves the LIVE queue off `offramp.queue()` each tick (§17 re-pointable). Deploy must
  wire + assert these two are the same address (and that the keeper signer is BOTH `OffRampModule.operator` AND
  `ZipRedemptionQueue.controller`). Mark DISCHARGED at item-10 deploy wiring.

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
- **LOSS — the default/slash flow is M2, not M1-live (from `src/loss/` headers, recorded 2026-06-17).**
  `LienXAlphaEscrow`'s custody half (`lockXAlpha`/`releaseXAlpha`) is M1-live; the slash half
  (`slashXAlphaToCapital`/`slashXAlphaToCohort`) + the `DefaultCoordinator` driver are built + mock-tested but go
  live in M2. The driver is **CRE-01's `rt8` default/recovery action family — now BUILT as CRE-01c
  (`cre/coordinator/`, 2026-06-20; note above).** The off-chain producer is complete; what remains for M2 is
  OPERATIONAL — firing the economic actions (DEFAULT/RECOVERY/RESOLVE/WRITEOFF) on a real default + the off-chain
  capital-sink liquidation account (xALPHA→USDC on Bittensor). No contract code owed; no CRE code owed — it's M2
  sequencing + that operational account.
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
