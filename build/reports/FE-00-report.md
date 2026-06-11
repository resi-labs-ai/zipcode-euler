# FE-00 report — Layer ↔ anvil foundation

**Window:** 2026-06-10 · **Track:** Frontend ↔ anvil · **Spec §:** §5 · **Status:** DONE → NEXT is FE-01

## What this window did

Booted the `frontend/zipcode-finance-euler` layer (`extends: ['./euler-lite']`) against the live local anvil
Base-fork (chainId 8453, `http://127.0.0.1:8545`) through euler-lite's OWN env-driven data layer — no
Zipcode-contract UI. Three artifacts, committed to the **layer repo** (`resi-labs-ai`, commit `1ace24b`):

1. **`.env.example`** — the documented anvil dev config: `RPC_URL_8453`→anvil, `*_VAULT_SOURCE=onchain`,
   `NUXT_PUBLIC_CONFIG_LABELS_BASE_URL`→local labels, geo-gate bypass, a blank-but-documented Reown project id.
2. **`public/labels/8453/{products,earn-vaults,entities}.json`** — a local euler-labels base so the deployed
   reservoir borrow/escrow/base-USDC EVK vaults resolve **verified** and the senior EulerEarn pool appears on
   earn — without the live goldsky 8453 subgraph (which would serve real-Base data contradicting the fork).
3. **`nuxt.config.ts`** EMFILE watch-guards (vite + nitro `followSymlinks:false`) — foundation that was
   uncommitted; folded in here since the boot depends on it.

The ticket (`build/tickets/frontend/FE-00-layer-anvil-foundation.md`) was drafted, run through three critic
subagents (junior-dev, frontend-binding ×2 lenses), triaged, then built to a green gate.

## Gate — verified green (build + serve, env exported)

- `npm run build` (`nuxt build`) — green.
- `GET /` → **200** (page routes aren't geo-gated; only `/api/*` is).
- `POST /api/rpc/8453` `eth_chainId` → **`0x2105`** (8453); `eth_blockNumber` → **47096192** = the anvil fork
  block (live Base would be hundreds of millions) — proves the browser read path reaches the fork, not live Base.
- `GET /api/labels/products.json?chainId=8453` → the 3 reservoir vaults; `…/earn-vaults.json?chainId=8453` →
  the senior pool — proves the local labels resolve and those markets will render verified.

## Decisions to sanity-check

- **Committed `.env.example`, not a real `.env`.** The layer gitignores `.env` (HARD RULE #2). The runner does
  `cp .env.example .env`. The ticket's "committed local .env" was interpreted as the committed *template*. If the
  reviewer wanted an actually-committed running env, that conflicts with the gitignore — flag if so.
- **Left `NUXT_PUBLIC_CONFIG_EULER_CHAINS_URL` empty** (defaults to GitHub `EulerChains.json` with real Base
  core addresses — correct because the fork preserves real Base EVC/EVK/EE factories). The serve gate therefore
  needs outbound network to GitHub for chain resolution; air-gapped serve would empty it.
- **Pulled the uncommitted `nuxt.config.ts` watch-guards into this commit.** They are FE-00 boot foundation but
  predate the window; if they belong to a different changeset, split them out.

## Holes → resolution

- **Backgrounded env didn't propagate (caught + fixed in-window).** First serve attempt backgrounded a
  `set -a; . ./.env; set +a; … node … &` compound and the child got NONE of the vars (fell back to GitHub labels
  + no RPC → gate 3/4 failed). Re-ran with the env passed **inline** on the `node` command → all gates passed.
  Recorded as a carry-forward seam in PROGRESS.md so later FE tickets confirm the vars are in the node process.
- **Interactive wallet-connect not provable headlessly** — needs a real Reown `NUXT_PUBLIC_APP_KIT_PROJECT_ID`.
  Empty is non-fatal (only a `console.warn`; the throw path is empty `enabledChainIds`, which `RPC_URL_8453`
  satisfies). The chain/RPC the wallet will use is proven via gate 3. Logged as a seam.

## Doc edits

- `build/tickets/frontend/FE-00-layer-anvil-foundation.md` — filed (with a triaged-in literal gate-command block
  + the `url`-must-be-absolute-https `validateNode` constraint).
- `build/tickets/PROGRESS.md` — FE-00 marked DONE, **FE-01 set NEXT**, three carry-forward seams logged.
- No `build/claude-zipcode.md` spec change needed — all critic findings were ticket-clarity gaps, not spec gaps;
  no back-pressure (euler-lite's env-driven data layer exposes every surface FE-00 needed).

## Status + NEXT

FE-00 **done**, layer code committed to `resi-labs-ai@1ace24b`, gate green. **NEXT = FE-01** (Zipcode address
book + typed ABI module in the layer, binding `build/anvil/abi/index.json` + `contract-map.md`). STOP for review.
