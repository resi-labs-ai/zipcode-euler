# FE-00 — Layer ↔ anvil foundation: boot the skinned app against the live local node

**Track:** Frontend ↔ anvil · **Spec §:** §5 (UX shell) · **Status:** NEXT
**Built code lands in:** the LAYER repo `frontend/zipcode-finance-euler/` (own `.git`, remote `resi-labs-ai`)
— never staged in the monorepo. The *ticket file* (this doc) lands in `build/tickets/frontend/`.

---

## Deliverable

The `frontend/zipcode-finance-euler` layer (`extends: ['./euler-lite']`) boots and **reads the live anvil
Base-fork** (chainId 8453, `http://127.0.0.1:8545`) through euler-lite's OWN data layer — no Zipcode-contract
UI. Concretely, three things, all committed to the layer repo:

1. **`.env.example`** (committed) at the layer root: the documented anvil dev config. The running `.env` is
   `cp .env.example .env` (gitignored per the layer's HARD RULE #2 — commit the template, not the secrets/host
   file). The example must carry every var the boot needs (below).
2. **A local euler-labels base** under `public/labels/8453/` — `products.json` (lists the deployed farm utility
   borrow + escrow + base-USDC EVK vaults → they resolve **verified**), `earn-vaults.json` (lists the senior
   **EulerEarn** pool → it appears on the earn page), `entities.json` (a `zipcode` entity for branding). Served
   statically at the layer origin and pointed at by `NUXT_PUBLIC_CONFIG_LABELS_BASE_URL`.
3. The wiring that makes euler-lite's native earn/borrow/lend pages render **on-chain reads off the fork** (not
   live Base, not subgraph, not V3).

No `Zc*` Zipcode screens are touched this window. This is the foundation FE-01..07 build on.

---

## Binds to (verified by inspection — euler-lite data layer is 100% env-driven, nothing hardwired to mainnet)

| Surface | Mechanism (file:line) | What we set |
|---|---|---|
| Chain enablement | `utils/chain-env.ts:43-56` — chains derived **purely** from `RPC_URL_<id>` presence; `getKnownChainIds` filters to @reown/appkit-known. **No subgraph required.** | `RPC_URL_8453=http://127.0.0.1:8545` |
| Browser RPC | `composables/useEulerSdk.ts:215-226` builds transport `/api/rpc/{chainId}`; `server/api/rpc/[chainId].ts:71` → `server/utils/rpc.ts` reads `process.env['RPC_URL_'+chainId]` | same `RPC_URL_8453` (server-side) |
| Vault source = onchain | `server/utils/sdk-server.ts:57-63` + `composables/useEulerSdk.ts:143-150` — `onchain` ⇒ `accountServiceAdapter/eVaultServiceAdapter/eulerEarnServiceAdapter='onchain'`, rewards `'direct'`; **no subgraph, no V3** | `SERVER_VAULT_CACHE_SOURCE=onchain`, `NUXT_PUBLIC_BROWSER_VAULT_SOURCE=onchain` |
| Euler core addresses | `server/api/euler-chains.get.ts:9,21-23` — empty env ⇒ default GitHub `EulerChains.json` (real Base 8453 EVC/EVK/EE factories). Fork preserves real Base core ⇒ default is correct. | leave `NUXT_PUBLIC_CONFIG_EULER_CHAINS_URL` empty |
| Labels | `server/api/labels/[file].get.ts:124-133` fetches `{LABELS_BASE_URL}/{chainId}/{file}`; SDK `eulerLabelsService.js` `normalizeProducts` (verified = union of every `product.vaults[]`), `normalizeEarnVaults` (earn list) | `NUXT_PUBLIC_CONFIG_LABELS_BASE_URL=<layer-origin>/labels` |
| Geo gate | `server/middleware/geo-gate.ts:33-52` — unset country ⇒ 451 unless `DOPPLER_ENVIRONMENT=dev`; `DEV_GEO_COUNTRY=<2-letter>` bypasses | `DEV_GEO_COUNTRY=GB` + `DOPPLER_ENVIRONMENT=dev` |
| Wallet connect | `plugins/00.wagmi.ts:14-19,70` — needs `NUXT_PUBLIC_APP_KIT_PROJECT_ID` (Reown); empty ⇒ AppKit inits degraded | document the var; a real projectId is the operator's to supply |

**Anvil address board** (`build/anvil/contract-map.md`, real-contract deploy 2026-06-10):
- farm utility borrow vault (EVK) `0x1aFc8c641BE6E8a0849f00f3c90a27D44710D267`
- farm utility escrow vault (EVK) `0x8A5FA36779693584E0e52246f05C5b0bF55Df1b1`
- base USDC market (EVK, supply-queue head) `0x3A48aaaa90CF3938290f12F6A1E58C1aeb54699D`
- senior **EulerEarn** pool (USDC) `0x1a7A8A5a6A2B34895201CFBC997C4eC419ba8A3d`

**Labels schemas** (from SDK `eulerLabelsService.js`, all fetches `.catch`→empty so missing files degrade cleanly):
- `products.json`: object keyed by slug; entry `{ name, description, entity, url, vaults: string[] }` — every
  address in `vaults[]` becomes verified (`normalizeProducts`, line 88-117).
- `earn-vaults.json`: array of `string | { address, description?, ... }` (`normalizeEarnVaults`, line 151-198).
- `entities.json`: object keyed by slug; entry `{ name, url, addresses?: {} }`; any `logo` must match
  `/^[a-zA-Z0-9_-]+\.(svg|png|jpg|jpeg|webp|gif)$/` (proxy `validateNode`, line 99) — so omit `logo`.

---

## Starting state (already in place — do NOT redo)

- euler-lite submodule populated (`git submodule status` → `63b9e779`, v2.0.0-16), `node_modules` symlinked up.
- `nuxt.config.ts` already: `extends: ['./euler-lite']`, alias/`components`/`css`/sass-loadPaths re-pointing,
  **EMFILE watch-guards** (`vite.server.watch` + `nitro.watchOptions` + `ignore`), brand title suppression.
- `.nuxt`/`.output` exist from a prior `nuxt build`. Anvil is up (block ≥ 47096000).
- There is **no `.env`** in the layer or in euler-lite yet — that is part (1) of this ticket.

---

## Do NOT

- **Do NOT edit anything inside `euler-lite/`.** It is a read-only base; compensate from the layer only.
- Do NOT commit a real `.env` (gitignored, HARD RULE #2). Commit `.env.example`; the runner copies it.
- Do NOT set a subgraph URI for 8453 — onchain source needs none, and the live goldsky 8453 subgraph would
  serve **real-Base** data that contradicts the fork. Leave `NUXT_PUBLIC_SUBGRAPH_URI_8453` unset.
- Do NOT set `NUXT_PUBLIC_CONFIG_EULER_CHAINS_URL` — the GitHub default has the correct real-Base addresses.
- Do NOT add any Zipcode-contract ABI / composable / address-book this window (that is FE-01).
- Do NOT invent vault metadata fields beyond the verified SDK schema above.

---

## Key requirements

1. **`.env.example`** at the layer root carries: `RPC_URL_8453=http://127.0.0.1:8545`,
   `NUXT_PUBLIC_BROWSER_VAULT_SOURCE=onchain`, `SERVER_VAULT_CACHE_SOURCE=onchain`,
   `NUXT_PUBLIC_CONFIG_LABELS_BASE_URL=http://127.0.0.1:3000/labels`, `DEV_GEO_COUNTRY=GB`,
   `DOPPLER_ENVIRONMENT=dev`, and a documented (blank-OK) `NUXT_PUBLIC_APP_KIT_PROJECT_ID=` with a comment that
   wallet connect needs a real Reown id. Each line commented with its role.
2. **`public/labels/8453/products.json`** lists the 3 EVK vaults under one `zipcode-*` product → verified.
3. **`public/labels/8453/earn-vaults.json`** lists the senior EulerEarn pool address.
4. **`public/labels/8453/entities.json`** defines the `zipcode` entity referenced by the product (no `logo`).
5. The labels JSON passes the proxy's `validateNode` (`server/api/labels/[file].get.ts:82-122`): any `url`
   field **must be an absolute `https://` URL** (a relative/empty-scheme `url` THROWS → the whole file collapses
   to the empty fallback → every listed vault silently shows unverified), no string > 16KiB, no `logo` key
   (omit it — the path-traversal regex would reject most values).

## Build / serve gate — literal commands (triaged in from critics)

`node .output/server/index.mjs` (standalone Nitro) does **NOT** auto-load `.env` — only `nuxt dev`/`nuxt build`
do. So the same env must be exported into **both** the build shell and the serve shell, and the serve must pin
`HOST=127.0.0.1 PORT=3000` so the labels proxy's self-origin fetch (`http://127.0.0.1:3000/labels/...`) resolves.
`RPC_URL_8453` MUST be present at serve time or `plugins/00.wagmi.ts:26` throws "No enabled chains" → `/` 500.

```sh
cd frontend/zipcode-finance-euler
cp .env.example .env
set -a; . ./.env; set +a            # export every var for the build shell
npm run build                        # nuxt build — bakes NUXT_PUBLIC_* + copies public/labels into .output
set -a; . ./.env; set +a; HOST=127.0.0.1 PORT=3000 node .output/server/index.mjs &   # serve with same env
# gate probes:
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/                         # → 200
curl -s -X POST http://127.0.0.1:3000/api/rpc/8453 \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'                # → {"result":"0x2105"}
curl -s 'http://127.0.0.1:3000/api/labels/products.json?chainId=8453'                 # → the 3 farm utility vaults
curl -s 'http://127.0.0.1:3000/api/labels/earn-vaults.json?chainId=8453'              # → the senior pool
```

The `/api/labels/*` proxy **requires** the `?chainId=8453` query (400 without it). The labels files must exist
in `public/labels/` BEFORE `npm run build` (public/ is copied into `.output/public/` at build time).

## Done when (gate = build + serve, NOT `nuxt dev` — dev EMFILE-floods on macOS per the watch-guard rationale)

1. `npm run build` (`nuxt build`) is **green** with the anvil env exported.
2. `node .output/server/index.mjs` serves; `GET /` → **200**.
3. `GET /api/rpc/8453` proxies to anvil: a JSON-RPC `eth_chainId` POST through it returns `0x2105` (8453),
   proving the browser read path reaches the fork (not live Base).
4. `GET /api/labels/products.json?chainId=8453` returns the 3 farm utility vaults;
   `GET /api/labels/earn-vaults.json?chainId=8453` returns the senior pool — proving the local labels resolve.
5. The committed artifacts (`.env.example`, `public/labels/8453/*.json`) are committed to the **layer repo**.

(Interactive wallet-connect on 8453 is config-gated on a real `NUXT_PUBLIC_APP_KIT_PROJECT_ID`, which a headless
gate can't click; requirement 3 proves the chain/RPC binding the wallet will use. Documented as a seam.)

## Depends on / Obligations

- Inbound obligations: **none** (PROGRESS.md "Open obligations" — FE-00 establishes the running app + env).
- Anvil must be up (`cast block-number --rpc-url http://127.0.0.1:8545`); redeploy from
  `contracts/script/DeployLocal.s.sol` if down.
