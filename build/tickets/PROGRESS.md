# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**CRE-00 — CRE track head (re-orient + scaffold).** The **SEC remediation track is COMPLETE** (SEC-01…SEC-15 FIX +
SEC-DOC, all DONE 2026-06-16). Per the kill-list "Next phase": **fresh anvil deploy → solidify `build/wires/` → CRE → FE.**
- **Immediate next step (per kill-list):** a fresh anvil Base-fork deploy (`contracts/script/DeployLocal.s.sol`) to
  confirm the full post-SEC stack stands up clean, then re-solidify any `build/wires/` truth-source the SEC sweep
  touched, **then** pick up the CRE track at its head **CRE-00** (scope retained in the Backlog table below).
- The reviewer releases the specific NEXT item; CRE-00 is the deferred head, but a deploy-sanity pass is the natural
  first move now that all 30 kill-list items (16 FIX + 14 DOC) are dispositioned.

> **The SEC track is COMPLETE** — all 16 SEC tickets (SEC-01…SEC-15 FIX + SEC-DOC) DONE. The kill-list is fully
> dispositioned: 16 FIX landed, 14 DOC swept, 3 DISMISS + 3 DEFER tracked. See the SEC track section below.
>
> **The Frontend ↔ anvil track is COMPLETE** (FE-00…FE-07, 2026-06-10/11). The **CRE track** (CRE-00…CRE-06) is the
> next workstream; its head is CRE-00 (scope retained in the Backlog table below).

---

## SEC track — kill-list remediation (auditor-prep) — COMPLETE

**All 16 SEC tickets DONE** (SEC-01…SEC-15 FIX + SEC-DOC doc-sweep; SEC-01…13 on 2026-06-15, SEC-14/15/DOC on
2026-06-16). The kill-list is fully dispositioned — **16 FIX + 14 DOC + 4 DISMISS + 4 DEFER** — and
`build/kill-list.md` is the per-item decision record (file:line + the fix, or why a proposed fix was rejected).
Every fix is in the committed, fork-tested code (`forge test` **829 passed / 0 failed / 3 skipped**) and
truth-sourced in `build/wires/` (index `build/wires/COVERAGE.md`).

The 16 per-ticket narratives + their `build/reports/SEC-*` files were pruned 2026-06-16 (superseded by
kill-list + wires + code; recoverable in git history). **5 tickets retained** in `build/tickets/sec/` for rationale
not fully captured elsewhere:
- **SEC-07** — `closeLine` line→base USDC defund (reclaim stranded liquidity).
- **SEC-08** — `openLine` runtime EE-timelock precheck + deploy perspective probe (incl. the "perspective is
  provenance-only" framing correction — the dominant brick the audit named doesn't exist under the live perspective).
- **SEC-13** — `postBid` `validTo` leg-anchor (caps fill-time mark age at `maxAge`, not `2·maxAge`).
- **SEC-14** — mastercopy init-lock via `MastercopyInitLock` (+ the ~85-site test-rework discovery folded in).
- **SEC-DOC** — the 14-item doc-sweep checklist + the 4 explicit code-change rejections (M8/L4/L6r/L15).

DISMISS (H3/L5/L10/M5) + DEFER (drawgate/covguard/exitbook/M9) are recorded in `build/kill-list.md`.

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
| FE-02 | Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` (approve→`zap`/`deposit`, `previewZap`/`previewDeposit`); ship the shared **1.3× gas-buffer tx helper** (EVC headroom — see Open obligations) all writes reuse | `ZipDepositModule` `0x6ecc…` + `ESynth`(zipUSD) `0xC5bd…` + `SzipUSD` `0x33aD…` | §4.5 (= INFLOW-06, realized) — **DONE 2026-06-11** |
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
