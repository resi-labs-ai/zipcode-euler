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

> **The szipUSD CoW-exit workstream is COMPLETE (2026-06-16): CTR-01 (report socket) + CRE-05a (bid-loop) +
> CRE-06 (folded-as-config) + FE-08 (exit-book page) landed; the `build/CoW.md` + `build/CoW-exit.md` drivers are
> deleted.** Durable record = the built code + `build/wires/` + this file.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — **DONE 2026-06-19** (`cre/zipreport` lib + `cre/scaffold` template; note below) |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family). **SEC-01 constraint: must not co-locate two same-lien `seedPrice` writes (origination+draw / draw+draw) in one block — the registry monotonic guard reverts the second. See open obligations.** **DONE 2026-06-19/20** — split into CRE-01a (revaluation→registry), CRE-01b (origination/draw/close/status→controller), CRE-01c (loss-action→coordinator); committed. | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call. *(2026-06-12: `settleEpoch` is now ON-DEMAND — the 30-day epoch gate was removed — so this can be event-driven off the queue's `RedemptionSettled` event rather than a fixed cron: settle → if backlog remains, sequence another REDEEM→REPAY. See `build/wires/9-ZipRedemptionQueue.md`.)* **DONE 2026-06-20** — (K) settle/claim half = `RedemptionJob` (`cre/keeper`); the (R) REDEEM→REPAY funding = CRE-02b/02c, built default-OFF in `cre/warehouse`. | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipFarmUtilityLpOracle` (one coherent producer). **DONE 2026-06-20** (`cre/sharefeeds/`, note below). The "xALPHA-APR feed" the row used to bundle is NOT here: the APR is on-chain-derived (§8.8), and the raw RATE push is the separate `cre/szalpha-rate` (8x-02, R-1-blocked) — NOT owed by CRE-03. | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter. **DONE 2026-06-20** (`cre/warehouse`). | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔juniorTrancheSidecar rotation; regime/split/cap policy). **SPLIT — exit half = CRE-05a (DONE); harvest remainder = KEEPER-01b (POLICY-BLOCKED). CRE-05 is NOT complete; there is no CRE-05b/05c — the remainder lives under the KEEPER prefix.** The freeze coverage is live NAV-oracle accounting (`covered()` gating `postBid`/`removeLiquidity`/`release`), the LP counted IN PLACE via `pathLockedLpEquity()` — NOT a physical main↔sidecar rotation. The exit half SHIPPED as CRE-05a (`cre/buyburn-bid/`). | §8.7 |
| CRE-06 | **DISCHARGED-as-config by CRE-05a (2026-06-16).** The exit-vs-harvest split is now the `harvestReserve` + `safetyBuffer` Config params in the buy-burn bid sizing (`clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)`) — M1 constants; a dynamic utilization-aware policy is a later parameter swap, not a redesign. No standalone workflow. (Cross-cutting coupling now recorded in the CRE-05a ticket + `build/wires/DurationFreezeModule.md`.) | §8.5 / §8.7 |
| CRE-05a | **DONE 2026-06-16 — buy-burn bid-loop** (the exit half of CRE-05; `cre/buyburn-bid/`). The single-resting-bid automation via the CTR-01 report path. Gate green (wasip1 build + 14 tests). The REST of CRE-05 (the harvest engine legs 8-B5…8-B10) remains — tracked as KEEPER-01b (harvest orchestrator, POLICY-BLOCKED); there is no CRE-05b/05c. | §8.7 |

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

**Blocked — can't build yet, waiting on outside things:**
- **The xALPHA price feed.** The bot that reports the xALPHA price can't be built until two things exist: a proven way to read the staking rate from Bittensor, and the real xALPHA token going live. Only a stub exists today.
- **The real szALPHA/zipUSD pool.** Hydrex hasn't launched it yet, so the junior share price can't value the real LP. It runs on a WETH/USDC placeholder until the real pool exists.
- **The subgraph.** The history indexer can't be built until the contract event formats are locked down at deploy.

**Deploy day — manual steps:**
- After deploying, five wiring steps have to be done by hand (the deploy script doesn't do them). They're written out as a checklist in `contracts/script/RUNBOOK-mainnet-deploy.md` §7.

**Rules the off-chain CRE bot must follow (these are how the bot operates, not contract changes):**
- Don't send two price updates for the same loan in the same block — the contract rejects the second one.
- When opening a loan, set the borrow limit high enough to also cover the origination fee, since the fee gets added to the loan's debt (limit must be ≥ loan + fee).
- Pack every message in the exact format the receiving contract reads, or the contract rejects it.

**Frontend notes — for when the app gets wired to the contracts:**
- The share-price function is `navEntry`/`navExit`; there is no `navPerShare` (calling it reverts).
- To exit the junior position, the user places a sell order on the CoW exchange — there is no "redeem" button or contract call.
- Users can't open loans from the app (only the CRE bot does); anyone can repay using a standard Euler repay.

**Milestone 2 / before production:**
- Default and loss handling (seizing the bond, recovering, writing off bad debt) is built but only switched on in Milestone 2, not at launch.
- Create the real treasury wallet and the off-chain process that turns seized collateral into USDC to cover losses (Milestone 2).
- Before going live, make all the currently-changeable wiring permanent — one final lock-down pass across the repo.

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
