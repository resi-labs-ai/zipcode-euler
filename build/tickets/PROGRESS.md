# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**FE-00 — Layer ↔ anvil foundation: boot the skinned app against the live local node.**
- **Deliverable:** the `frontend/zipcode-finance-euler` layer (the team's skinned borrower/lender app —
  `extends: ['./euler-lite']`) running locally against the live anvil node (`http://127.0.0.1:8545`, Base fork,
  chainId 8453), with a wallet able to connect and euler-lite's own data layer reading the fork (not live Base).
  No Zipcode-contract UI yet — just: the app boots, connects, reads. Concretely: (a) populate the layer's empty
  `./euler-lite` base (init the submodule, or point it at the working `frontend/euler-lite` checkout) so
  `npm install && npm run dev` boots; (b) a committed local `.env` repointing the data layer at anvil —
  `RPC_URL_8453=http://127.0.0.1:8545`, `NUXT_PUBLIC_BROWSER_VAULT_SOURCE=onchain` + `SERVER_VAULT_CACHE_SOURCE=onchain`
  (no subgraph for MVP), and a local labels base URL; (c) a local euler-labels `8453/products.json` listing the
  deployed reservoir borrow/escrow vaults + senior EE pool so they resolve as verified.
- **Binds to:** euler-lite's data layer — verified **100% env-driven, nothing hardwired to mainnet** (`RPC_URL_<id>`,
  `NUXT_PUBLIC_BROWSER_VAULT_SOURCE`, `NUXT_PUBLIC_CONFIG_LABELS_BASE_URL`, `NUXT_PUBLIC_CONFIG_EULER_CHAINS_URL`) — plus
  the live address board `build/anvil/contract-map.md`. The fork preserves the REAL Base Euler core (EVC `0x5301…`,
  EVK factory `0x7F32…`, EE factory `0x75F4…`), so canonical `EulerChains.json` resolves 8453 with only the RPC override.
- **Spec §:** §5 (UX shell) — the foundational wiring beneath FE-01..07.
- **Done when:** `npm run dev` boots the layer; a wallet connects on chainId 8453 against the anvil RPC; euler-lite's
  own earn/borrow pages render real on-chain vault reads off the fork (no calls to live Base); the local labels file
  makes the reservoir + senior pool appear. Zero Zipcode-contract UI required at this step.
- **Obligations:** none inbound. Establishes the running app + env + address-board access that FE-01 and every later FE
  ticket build on. **Build target is the LAYER over a read-only euler-lite base — never edits to euler-lite** (see seams).

---

## Backlog

### CRE (Go → wasip1) — spec §8
Numbering follows the spec's own CRE map (`claude-zipcode.md` §8.11) — the spec rules intent.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — *(was NEXT; deferred behind the FE↔anvil push the user prioritized 2026-06-10 — head of the CRE track when released)* |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family) | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipReservoirLpOracle` — and the xALPHA-APR feed (the 8x-02 receiver is built; the Go producer remains) | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔sidecar rotation; regime/split/cap policy) | §8.7 |

### Frontend ↔ anvil (Vue/viem, in the `zipcode-finance-euler` LAYER over a read-only `euler-lite` base)
**Goal: make the team's skinned borrower/lender app interactive against the live local protocol — "fuck around
before mainnet."** The deploy-gating that blocked these is LIFTED: item-10 fork-executed the full stack on anvil, so
every "TODO post-deploy" slot is now fillable from `build/anvil/contract-map.md` (addresses) + `build/anvil/abi/`
(ABIs). The layer's `Zc*` screens are currently a **clickable mockup** fed by mock `lib/zipcode/store.ts` + simulated
Plaid — the work is to swap that data path for real reads/writes against the anvil contracts. Build one at a time,
foundation → leaf. Addresses below are the anvil board (`contract-map.md`); ABIs are `build/anvil/abi/<Name>.json`.

| Item | What | Binds to (anvil address + ABI) | Spec § |
|---|---|---|---|
| FE-00 | Boot the layer on anvil: populate the euler-lite base, `.env` repoint (`RPC_URL_8453`→`127.0.0.1:8545`, onchain vault source, local labels), wallet→8453 | euler-lite data layer (config-only) + `contract-map.md` | §5 — **NEXT** |
| FE-01 | Zipcode **address book + typed ABI module** in the layer (the shared dep every Zipcode composable imports; fills the INFLOW-06 "post-deploy slots" with real anvil addresses) | `abi/index.json` resolver + `contract-map.md` | §5 |
| FE-02 | Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` (approve→`zap`/`deposit`, `previewZap`/`previewDeposit`); ship the shared **1.3× gas-buffer tx helper** (EVC headroom — see Open obligations) all writes reuse | `ZipDepositModule` `0x6ecc…` + `ESynth`(zipUSD) `0xC5bd…` + `SzipUSD` `0x33aD…` | §4.5 (= INFLOW-06, realized) |
| FE-03 | Position / NAV view: szipUSD + zipUSD balances + **$ value via `navPerShare`**; the lender portfolio screen | `SzipNavOracle` `0x0C3E…` + `SzipUSD` `0x33aD…` + zipUSD `0xC5bd…` | §7 / §12 |
| FE-04 | Exit flow: `requestExit`/`cancelExit` + redemption-queue status + the **net-new cooldown panel**; wire `ZcWithdrawModal` | `ExitGate` `0xd9b8…` + `ZipRedemptionQueue` `0x46c8…` | §6 / §12 |
| FE-05 | Borrower flow: line state + permissionless repay; wire `ZcDrawModal` / `ZcRepayModal` (CRE drives origination per §17 — UI reads line state + repays) | `EulerVenueAdapter` `0x87dC…` + `ZipcodeController` `0x3602…` | §4 / §15 |
| FE-06 | **Solvency dashboard** (§12 metrics — NAV, zipUSD supply + peg, szipUSD NAV/share + trailing APR, utilization / free liquidity, insurance coverage) via **direct on-chain view reads** (no subgraph for MVP); wire `ZcStatCard` grid / `ZcVaultAllocationTable` | `SzipNavOracle`, zipUSD, reservoir `IEVault` `0x1aFc…`, warehouse Safe `0xe028…` | §12 |
| FE-07 | **Euler-native vault dashboard**: surface the real reservoir EVK market + senior EE pool through euler-lite's OWN lend/borrow/earn pages (largely FE-00 config + the local labels file — this is the "show euler data / particular vaults" surface) | reservoir `IEVault` `0x1aFc…` + EE pool `EulerEarn` `0x1a7A…` | §4.7 |

INFLOW-06 (`build/tickets/frontend/INFLOW-06-deposit-module.md`) is the **FE-02 draft** — its "address config depends
on item 10 / reads a placeholder" notes are now discharged (use the anvil board); its `abis/`/composable files live in
the **layer**, not in euler-lite.

### Subgraph — deferred (FE track runs without it)
Still gated on item-10 freezing the §9 event ABIs; the MVP runs on **direct on-chain view
reads** (FE-06), not a subgraph. Author a subgraph spec later if/when aggregated history is needed; do not block the FE
track on it.

---

## Open obligations / seams

- **Frontend deploy-gating LIFTED → anvil-grounded (2026-06-10).** The whole FE track was written "gated on item-10 /
  post-mainnet"; item-10 fork-executed the full stack on a live anvil (Base fork @47096000, chainId 8453,
  `127.0.0.1:8545`). So the FE tickets now bind to **`build/anvil/contract-map.md`** (addresses) +
  **`build/anvil/abi/`** (ABIs, with `index.json` as the address→ABI resolver), not to a placeholder. **Build target =
  the `frontend/zipcode-finance-euler` LAYER** (the skinned app) **over a read-only `euler-lite` base** — the team's
  design keeps euler-lite pristine and overrides from the layer (`extends: ['./euler-lite']`), so new Zipcode
  `abis/`/composables/address-book go in the LAYER, NOT inside euler-lite (this supersedes INFLOW-06's
  "`reference/euler-lite/abis/…`" placement). euler-lite's data layer is config-only (env-driven, nothing hardwired to
  mainnet), so its native Euler reads work against the fork with just an RPC override.
- **Standing FE requirement — EVC gas buffer.** Every EVC-touching tx
  (`ZipDepositModule.deposit`/`zap`, `RecycleModule.recycle`, warehouse SUPPLY/REDEEM, `EulerVenueAdapter.fund`/`draw`,
  the reservoir loop) must multiply `eth_estimateGas` by **~1.3× (or +150k)** before signing, baked into the shared
  tx-send helper (FE-02), not per-call. No contract change removes this.
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
