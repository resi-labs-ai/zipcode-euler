# build/anvil — smoke-path test suite for the live deployment

Push **real smoke through the real machinery**: fire the actual functions at the actual deployed contracts on the
running anvil node (`http://127.0.0.1:8545`, Base fork @ 47096000), across many surfaces, to **prove real things work
or expose real flaws before mainnet**.

- **`contract-map.md`** — the live address board (every spec binds to it).
- **`smoke-path-NN.md`** — one grounded path each. Run one at a time.
- **`recipes/`** — manual fork build-recipes that stand up the **real** zipUSD/xALPHA ICHI pool + vault (a substrate the SP suite deliberately lacks — it uses the showcase VAMM stand-in). See `recipes/zipusd-xalpha-pool.md`.

## Running anvil (where it lives)
- **Endpoint:** `http://127.0.0.1:8545` · chainId `8453` (Base mainnet fork) · fork block `47096000`.
- **Process:** a **detached** anvil (parented to init/launchd, not any shell) — it **persists across terminal/editor
  windows**; closing this session does NOT kill it.
- **Launch command:**
  `anvil --fork-url <BASE_MAINNET_RPC> --fork-block-number 47096000 --host 127.0.0.1 --port 8545`
- **Is it alive?** `cast block-number -r http://127.0.0.1:8545` (and `cast chain-id` → `8453`).
- **Restart if dead (deterministic — addresses re-match `contract-map.md`):**
  1. relaunch anvil (command above);
  2. `cd contracts && forge script script/DeployLocal.s.sol:DeployLocal --sig "runLocal()" --rpc-url http://127.0.0.1:8545 --broadcast --slow --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`;
  3. (showcase layer) `forge script script/DeployShowcaseVAMM.s.sol:DeployShowcaseVAMM --rpc-url http://127.0.0.1:8545 --broadcast --slow --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`.

Two layers live on the node:
- **The protocol** (SP-01…17) — the full Zipcode system on Gnosis Safe + Moloch v3 (Baal) + Zodiac: issuance, the
  credit-origination spine (real EulerEarn + EVK), senior par-epoch redemption, the utilization↔freeze identity, the
  CoW buy-and-burn, the loss/bond cycle, the bridge rate. All PASS against real Base bytecode.
- **The showcase** (SP-18) — a live **HYDX/USDC auto-compounder** demo on top, deployed by `DeployShowcaseVAMM.s.sol`
  (run after the main deploy). Forks of the verified NAV oracle + LP module with ONLY the LP-leg seam changed, enabled
  on the **same** engine Safe via Zodiac `enableModule` (alongside the prod modules) — so the auto-compounder can be
  shown running on mainnet BEFORE the real zipUSD/xALPHA pool exists. Addresses: `contract-map.md` → "Showcase / demo".
  Tickets: `build/wires/SHOWCASE-VAMM.md`.

## How the next window runs a path
Each spec is executed as **real transactions against the running node**: a small forge script broadcast to the anvil
RPC (`forge script … --rpc-url http://127.0.0.1:8545 --broadcast --unlocked`) for multi-step sequences, plus `cast`
for impersonating the CRE Forwarder, dealing tokens, warping time, and reading state back. After running, record the
observed deltas + PASS/FLAW in the spec's "Result" section.

Helpers:
- **Push a CRE report**: `cast rpc anvil_impersonateAccount 0xF8344CFd5c43616a4366C34E3EEE75af79a74482`, then
  `cast send <receiver> "onReport(bytes,bytes)" <metadata> <abi.encode(uint8 reportType, payload)> --from 0xF834…4482 --unlocked`.
  Metadata must carry the sealed author `0x90F7…`/workflowId `0x…01` where the receiver enforces identity.
- **Deal USDC**: `cast rpc anvil_setStorageAt` on the USDC balance slot, or a forge-script `deal`.
- **Timelock op**: proposer/executor = `team`; `warp` past the 2-day delay on anvil.

## The four simulation boundaries (unavoidable on an isolated fork — not mocks of our machinery)
CRE push (impersonate Forwarder) · xALPHA (stand-in ERC20) · CoW fill (simulate the solver) · Proof-of-Value collateral
(mocked per §17). Everything else is real Base bytecode.

## Catalog

> **The runnable suite lives in `smoketest/`** (`smoketest/smoke-path-NN.md`), rebuilt 2026-06-24 from the
> docs/X-Ray/seam model (`smoke-path-x-ray-update.md`). Each spec binds to `contract-map.md` **by name**, proves a
> named seam + the contract's `On-chain=Yes` invariants, and carries a happy path **and** a fuzzy/negative leg.
> SPs are isolated by `evm_snapshot`/`evm_revert` to a clean post-deploy baseline. See `smoketest/README.md`.

| # | Path | Seam | Tier | Headline question it answers |
|---|---|---|---|---|
| 01 | zipUSD utility-dollar lifecycle | →S12 | pure on-chain | does zipUSD mint/transfer/park; who can mint/burn |
| 02 | NAV oracle genesis + read surface | S8-in | pure on-chain | what's a share worth at genesis; FREE+COMMITTED additivity |
| 03 | DurationFreeze commit (rq→non-rq move) | S9 | pure on-chain | can a zodiac module move value to the non-rq Safe |
| 04 | Farm utility borrow/repay (real EVK) + borrow guard | — | pure on-chain | lines of credit + utilization; borrow pinned to the engine Safe |
| 05 | Buy-burn bid post/cancel | S10 | needs-forwarder | the CoW limit order set + price bound; no re-point under a live bid |
| 06 | Junior zap → share issuance | S8 | needs-forwarder | shares per zipUSD; Loot→gate, szipUSD→depositor; setter locks |
| 07 | szipUSD secondary transfer + NAV asymmetry | S3 | needs-forwarder | sell shares; entry pauses on stale, exit doesn't |
| 08 | Revaluation batch → registry | lien | needs-forwarder | CRE reprices liens; staleness window; strict-18dp/StaleReport |
| 09 | Warehouse senior ops (SUPPLY/APPROVE/REDEEM/REPAY) | S11 | needs-forwarder | the senior EE custody ops via Roles scope |
| 10 | Senior par-epoch redemption | — | needs-forwarder | request→settle→claim at par; quiescent setTokens guard |
| 11 | Loss bond lifecycle | S5/S6 | needs-forwarder | default provisioning drops NAV; bond slash; JIT escrow approval |
| 12 | xALPHA rate push | S2/S3 | needs-forwarder | rate freshness feeds the NAV xALPHA leg; saturation guard |
| 13 | Buy-burn full exit | S10 | needs-forwarder | sell shares for USDC + exit; NAV ticks up; poke-before-navExit |
| 14 | Full venue origination (CTR-03 siloId) | spine | needs-forwarder | the venue spine end-to-end (real EE); siloId routing |
| 15 | Utilization ↔ freeze identity | S9 | needs-forwarder | does %utilization == %committed in the non-rq Safe |
| 16 | Draw + close line (CTR-03 siloId) | spine | needs-forwarder | re-anchor seed; repay→close burns the lien |
| 17 | Engine flywheel | S13 | needs-forwarder | LP/harvest/exercise/sell/recycle against live venues |
| 18 | vAMM auto-compounder showcase | demo | demo | the demo oracle prices a live vAMM HYDX/USDC LP the prod oracle can't |
| 19 | Donation seam (NAV moves with no deposit) | **S7** | needs-forwarder | a direct transfer into a counted Safe moves NAV; the Gate denominator absorbs it |
| 20 | Engine flywheel end-to-end value conservation | **S13** | needs-forwarder | is basket value conserved across deposit→LP→harvest→exercise→sell→recycle |
| 21 | Senior NAV donation-immunity | **S12** | needs-forwarder | Σ senior par reads `convertToAssets(balanceOf(safe))`, never `balanceOf(pool)` |

Run order suggestion: 01→04 (no CRE) to warm up, then 06/08 (issuance + pricing), then 14/16 (origination),
09/10/21 (senior), 03/15 (freeze), 05/13 (CoW exit), 11/12 (loss/bridge), 17/20 (flywheel), 19 (donation seam),
then 18 (the showcase layer — after `DeployShowcaseVAMM.s.sol`). Each SP `evm_revert`s to the clean baseline first.
