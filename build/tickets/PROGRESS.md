# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**SIZE-01 SHIPPED 2026-06-22 (`build/tickets/contracts/trim-eulervenueadapter.md`).** `EulerVenueAdapter` trimmed
under EIP-170 via Option A: the three identical "withdraw `amount` from A, supply to B" reallocate builders
(`fund`/`fundFarmUtility`/`defundFarmUtility`) folded into one internal `_eeMove(from, to, amount)` helper —
behavior- and ABI-identical, read order preserved. **24614 (−38) → 24054 (+522 margin).** `forge test` green
(1047 passed / 0 failed / 3 skipped); `DeployLocal --broadcast` completes clean (run log
`broadcast/DeployLocal.s.sol/8453/runLocal-latest.json`). The already-applied SiloRegistry routing fix landed on
this broadcast. `build/anvil/contract-map.md` regenerated — the three placeholders filled (`SiloRegistry`
`0x86C2…FeDf2`, `LineIrm` `0xF6CA…BCd18`, `FarmUtilityBorrowGuard` `0x3b7c…1fAa3`); every other address kept its
2026-06-10 value (bytecode edits don't move CREATE addresses, and the only inserted contract sorts last in the
nonce order). `abi/index.json` gained the three entries (52 → 55). Doc-synced `docs/wires/WOOF-04.md`.

**NEXT → reviewer picks.** One item moves at a time: finish it, set the next `NEXT`, STOP.

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
| KEEPER-01b | Engine harvest-loop orchestrator (8-B5…8-B10 `onlyOperator` legs; regime/split/cap policy), as `Job`s on the `cre/keeper/` spine. = the bulk of the rest of CRE-05. **POLICY-BLOCKED** — undecided execution floors / regime+state / vote / sizing; agenda = `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md`. Strike-loop core slice unblocks once A1–A4 + C4 ratified. **Lands with the real szALPHA/zipUSD pool — same component.** | (K) |

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

### Subgraph — follows the FE track (part of the same workstream)
Still gated on item-10 freezing the §9 event ABIs; the MVP runs on **direct on-chain view
reads** (FE-06), not a subgraph. Author a subgraph spec later if/when aggregated history is needed; do not block the FE
track on it.

---

## Open obligations / seams

**Blocked — can't build yet, waiting on outside things:**
- **The xALPHA price feed.** The bot that reports the xALPHA price can't be built until two things exist: a proven way to read the staking rate from Bittensor, and the real xALPHA token going live. Only a stub exists today.
- **The real szALPHA/zipUSD pool, and the harvest bot that rides with it.** Hydrex hasn't launched the pool yet, so the junior share price can't value the real LP (it runs on a WETH/USDC placeholder until then). The harvest bot (KEEPER-01b) is part of this same component — it goes live alongside the real pool.
- **The subgraph** is part of the frontend workstream — built after the app, and only if aggregated history is wanted (the app runs fine on direct contract reads without it). It also needs the event formats locked at deploy.
- **The loss-recovery workflow.** When a borrower defaults, the seized bond (xALPHA) lands in `adminSafe`. Turning it into USDC is a CRE workflow that bridges the xALPHA to Bittensor, unstakes it, and swaps to TAO/USDC — so it can't be built until the bridge (8x-01) is live. Until then the xALPHA just accumulates safely in `adminSafe`. (The on-chain seize/slash contracts are already built; only this off-chain drain remains.)

**Hardening — after the contracts have proven their functionality:**
- Lock all the currently-changeable contract wiring to immutable — one repo-wide pass. It's deliberately left re-pointable during the build/demonstration phase (§17); freezing it is the next hardening level once functionality is demonstrated, not a launch gate.

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

---

## Audit track (adversarial-review)

A separate workstream from the CRE/frontend `NEXT` above. The multi-model adversarial-review harness lives
at `adversarial-review/` (run via `adversarial-review/CONDUCTOR.md`); per-contract findings + tickets land in
`build/tickets/audit/`. **Bridge group reviewed (5/5 contracts), all ADEQUATE, no CRITICAL/HIGH/MEDIUM.**

Ledger:
Bridge audit COMPLETE (5/5 reviewed; 3 LOW fixes shipped to `main`, 1 WONTFIX, 2 sound). No CRITICAL/HIGH/MEDIUM.
- **BRIDGE-ADV-01** — non-pausable `redeem` under precompile compromise → WONTFIX (accepted runtime trust).
- **BRIDGE-ADV-02** — genesis seed atomicity + mandatory slippage floor (subsumes ADV-03) → **SHIPPED to `main`**
  (`deploy964` seeds in-broadcast + `SlippageFloorRequired` floors). X-Ray/wire/runbook synced.
- **BRIDGE-ADV-04** — `intrinsicAprBps()` overflow + vacuous invariant → **SHIPPED to `main`** (saturation guards;
  fuzz/invariant now full-uint256-domain). X-Ray/wire synced.
- **BRIDGE-ADV-05** — burn/mint pool ownership → timelock in `deployBase` → **SHIPPED to `main`** (2-step; verified
  behaviorally in the fork test). X-Ray/wire/runbook synced.
- Consolidated bridge suite **81/81 green** (`forge build` clean) with all three integrated.
- `szalphalockreleasepool` + `szalphamirror` reviewed **sound** (no tickets).

Hydrex demo-fork group reviewed (2/2; differential vs the prod parents). The forks were NOT clean ports —
they silently dropped audited guards the parents have (the X-Rays over-claimed ADEQUATE). Demo-scoped, but
**fix-before-promotion** (docs plan a mainnet version).
- **HYDREX-ADV-01** — `SzipNavOracleDemoVAMM` dropped 3 parent guards (`obsSpacing` poke-spam throttle,
  `StaleReport`, `RateUnseeded`) → **SHIPPED to `main`** (all back-ported + 3 regression tests; hydrex suite
  48/48 green; X-Ray corrected).
- **HYDREX-ADV-02** — `LpStrategyModuleDemoVAMM` dropped `MastercopyInitLock` (false invariant) + `MockVammPair`
  didn't model real Solidly `mint` → **SHIPPED to `main`** (inherits `MastercopyInitLock`; mock now `min`+donate
  faithful + donate-excess/single-sided/mastercopy-lock regression tests). Hydrex suite 51/51 green; X-Ray corrected.
- Hydrex group COMPLETE: both forks reviewed + both tickets shipped. No drain found; the regressions were
  dropped audited guards (NAV) + a false init-lock claim & an unfaithful test mock (LP) — all fix-before-promotion.

Supply group — `AlgebraIchiFairLpOracle` + `IchiAlgebraFairReserves` reviewed (single-model panel, Opus ×3;
Codex/Fugu cross-check still owed on the fail-open question — now settled by fork test, see ADV-02). Keystone
(in-block-swap invariance) confirmed sound; two edge findings.
- **SUPPLY-ADV-01** — fair reserves count raw idle vault balances (in-block donation seam) → **WONTFIX**. Idle
  balances are real assets and belong in NAV; the seam is inert (no szipUSD collateral-borrow, farm-utility
  borrow gated to the engine Safe as sole borrower, CoW-only exit at counterparty price, no redeem-at-mark, POL
  self-held), and dropping idle would under-mark honest value continuously AND not even close the seam (deposited
  cash converts to LP next rebalance). No code change; rationale in the ticket + `FairLpOracle.md`.
- **SUPPLY-ADV-02** — fair-LP oracle lacked the `isInitialized()` plugin gate its sibling enforces → **SHIPPED to
  `main`**. Added `PluginNotReady` readiness gate on the oracle ctor (matching `SzipNavOracle.setLpTwapWindow:267`)
  AND the shared `IchiAlgebraFairReserves.fairReserves` read path (covers both consumers). The read-time
  under-coverage residual is settled empirically: a fork test proves the DEPLOYED plugin reverts (fail-CLOSED) on
  a window longer than its history — no in-contract span assertion (cardinality is not on-chain-queryable, so a
  span check would require plugin surface the verified interface lacks). Fair-LP suite 16/16 green; SzipNavOracle
  suites green (shared lib). X-Ray/wire (`FairLpOracle.md`) synced.

Loss group — `DefaultCoordinator` + `LienXAlphaEscrow` reviewed (single-model panel, Opus; Codex/Fugu not
credentialed). Both load-bearing surfaces SOUND (conservation seam, default bound, status machine, two-call
resolve, destination integrity, reentrancy battery all re-verified). One promotable finding; escrow produced
no tickets. X-1 grief ceiling + X-2 build-phase wiring = ratified accepted-residuals.
- **LOSS-ADV-01** — `setEscrow` granted a standing MAX xALPHA allowance, making an escrow re-point a *drain*
  of the launch reserve (an ERC-20 allowance lets the spender pick the destination — the escrow's
  non-sweepability is irrelevant); the X-Ray/NatSpec's "safe because non-sweepable" rationale was an unsound
  non-sequitur → **SHIPPED to `main`**. Fix: removed the standing allowance; `_lock` now grants the escrow an
  exact-amount just-in-time allowance (`forceApprove(amount)` → pull → `forceApprove(0)`, the house WOOF-06
  pattern), so a re-pointed escrow has nothing to drain and re-pointing is grief/redirect like every other
  slot. `setEscrow` stays uniformly re-pointable (NO lone bolt-down — set-once rejected for X-2 consistency);
  deleted the dangling `error AlreadyWired()` (vestige of the dropped set-once). Loss suite 118/118 green
  (+1 JIT regression test); X-Rays + `docs/wires/` (DefaultCoordinator, 8-Bx, interfaces-loss, DeployZipcode,
  README) + deploy-script comments synced.

CreditWarehouse group — `WarehouseAdminModule` reviewed (single-model panel, Opus; Codex/Fugu not
credentialed). SOUND / HARDENED holds: the hardcode-dangerous/inject-addressable encoder discipline is
complete (no dangerous attribute reaches the forwarded call), and every wiring desync fails-closed —
verified against the live deployer scope tree (`EqualToAvatar` dynamic receiver pin; deploy-baked `EqualTo`
eePool/redemptionBox pins). No code vulnerability. One promotable result (documentation accuracy). X-1 scope
trust + X-3 build-phase wiring = ratified accepted-residuals.
- **CWH-ADV-01** — the X-Ray/`invariants.md` overstated I-4 avatar parity as a maintained on-chain invariant
  ("a one-sided re-point can no longer be saved" / "On-chain: Yes"). It is **entry-point-local at
  `setWarehouseSafe`** only — `setRoles` (no parity re-check) and an external `Roles.setAvatar` re-desync the
  pair, both **fail-closed** at the live `EqualToAvatar` scope pin (no leak; the pin can only resolve to the
  actual current avatar) → **SHIPPED to `main` (DOC-ONLY)**. Corrected `WarehouseAdminModule.md` +
  `invariants.md` (I-4/X-2 enforcement scope; X-3 "needs a paired off-chain re-scope" qualifier) +
  `docs/roles.md` (the re-point runbook). Optional `setRoles` parity re-check DECLINED (breaks build-phase
  re-pointing, can't cover external `setAvatar`, no gain over the fail-closed scope). Contract untouched; the
  28 fork-integration tests unaffected (green at baseline). HARDENED verdict retained.
