# FE-08 — szipUSD NAV exit-book page (two-sided depth chart + liquidity gauge + one-click exit)

> FE-track, built in the LAYER `frontend/zipcode-finance-euler/` (its own git → `resi-labs-ai`; the monorepo
> gitignores it). This ticket file lives in the monorepo; the Vue/composable/page code commits to the LAYER.
> The net-new exit-book page on top of the shipped FE-04 withdraw spine. Driver: `build/CoW.md` item #3 +
> `build/CoW-exit.md` ("The exchange view" + "Making it buildable"). Spec intent: `claude-zipcode.md` §6.4
> (junior exit) / §7 (`SzipNavOracle`) / §12 (dashboard). **This is the LAST piece before `CoW.md` + `CoW-exit.md`
> are retired.**

## Deliverable (in the layer)
1. `composables/useNavExitBook.ts` — the read model: the protocol side via on-chain reads (`navExit`,
   `currentBid`, `quoteMaxPrice`, `buybackCap`, `dBps`) + the external side via the CoW Orderbook API, aggregated
   into two-sided depth-chart series (x = **% of NAV**, y = **cumulative USDC**).
2. `composables/useCowOrderbook.ts` — net-new: `GET https://api.cow.fi/base/api/v1/orders` filtered to the
   szipUSD/USDC pair, normalized to `{price%OfNav, sizeUsdc, side}[]`. (CSP already allows `api.cow.fi`.)
3. `components/zipcode/ZcNavExitBookChart.vue` — the chart.js depth chart: a **NAV line at 100%** (annotation),
   the **protocol bid block** at `navExit×(1−d)` sized to `currentBid.sellAmount` (the live CRE-05a bid), and
   **external CoW orders fanned below** the floor (the "stinkbids"). Axis = % of NAV, never absolute $.
4. `components/zipcode/ZcLiquidityGauge.vue` — the liquidity gauge: **free farm utility** + **utilization** (the
   reads that *explain* the protocol block's depth; tightens visibly as `U` rises). Fail-soft if a read is
   unavailable (degrade to what's readable; do not throw).
5. `pages/lender/szip-exit-book.vue` — the page: the chart + the gauge + a "Sell to floor" exit CTA that
   **reuses the shipped `ZcWithdrawModal` / `useCowExit`** (no new exit logic).
6. Registry additions IF NEEDED for the gauge (the FE-01 pattern): add `eulerEarn`, the warehouse Safe, and/or
   `durationFreeze` to `lib/zipcode/generated/registry.ts` + an ABI under `lib/zipcode/abi/` so the gauge can read
   `EulerEarn.maxWithdraw(warehouse)` / `convertToAssets(balanceOf(warehouse))` (free farm utility + `U`), the
   donation-immune §8.2 way. If extending the registry balloons scope, ship the gauge as free-farm utility-only or
   defer it and SHIP the depth chart + protocol bid + external book first (log what was deferred).

## Spec §
- `claude-zipcode.md` §6.4 — the junior exit is the CoW book (rest a SELL → treasury just-in-time buy-burn or
  external fill); the only on-chain user write is `szipUsd.approve(vaultRelayer)` (FE-04 already does this). NO
  senior-queue surface, NO szipUSD cooldown (FE-04 finding — the resting CoW order IS the queue).
- §7 — `SzipNavOracle` is the pricing primitive; the page reads `navExit` (the redemption mark, never reverts),
  NOT `navPerShare` (absent — FE-01 finding).
- §12 — dashboard metrics (NAV, utilization / free liquidity).
- `CoW-exit.md` "The exchange view": Ask = enter at the Gate `navEntry`; Bid = the CoW buy-burn + external
  bidders at `navExit×(1−d)`. The page renders the **Bid/exit** side (the Ask/entry stays the existing Gate flow).

## Binds to (verified by the layer map)
- `lib/zipcode/contracts.ts` → `ZIPCODE_CONTRACTS` + `getZipcodeContract`; reads via `useRpcClient().client`
  (the browser proxy at `/api/rpc/8453`), null-guarded — the FE-03 `useZipPosition` read pattern.
- ABIs present: `lib/zipcode/abi/SzipBuyBurnModule.ts` (`currentBid`/`quoteMaxPrice`/`buybackCap`/`dBps`),
  `SzipNavOracle.ts` (`navExit`/`navEntry`/`spotNavPerShare`/`twapNavPerShare`). Anvil addresses:
  `SzipBuyBurnModule 0x12881a80…`, `SzipNavOracle 0x0C3E77…` (`build/anvil/contract-map.md`).
- `composables/useCowExit.ts` + `components/zipcode/ZcWithdrawModal.vue` (FE-04) — the exit action to REUSE
  (`buildOrder`/`signOrder`/`submitOrder`/`orderStatus`; submit = POST `api.cow.fi/base/api/v1/orders`).
- `composables/useZipTx.ts` — the 1.3× gas buffer (only relevant if the exit re-approves; the CTA reuses FE-04).
- chart.js 4.5.1 + vue-chartjs 5.3.3 + chartjs-plugin-annotation 3.1.0 (already in the stack). viem 2.48.8.
- Build/boot: `npm run build` (= `nuxt build`); `DEV_GEO_COUNTRY=GB` + `RPC_URL_8453=http://127.0.0.1:8545`;
  anvil up (block 47096111, confirmed).

## Starting state
- FE-00…FE-07 shipped (the withdraw spine `ZcWithdrawModal`/`useCowExit` is live). Anvil up. The page is net-new.

## Do NOT
- Do NOT author any file inside `euler-lite/` (read-only submodule) — Zipcode files live in the layer only.
- Do NOT price the axis in absolute $ — szipUSD is NAV-priced; the axis is **% of NAV** (`navExit` = 100%).
- Do NOT render the book as a price-time/FIFO CLOB — it is a **UI aggregation over open CoW orders** (batch
  auction); label/treat it as such.
- Do NOT show a protocol ASK on CoW (the protocol is **bid-only** — buys to burn; entry is Gate-only). The page's
  protocol element is the single buy-burn BID block; do NOT ladder it (single-resting-bid; laddering needs a
  contract change — driver §4, deferred).
- Do NOT build new exit-submission logic — reuse `useCowExit`/`ZcWithdrawModal`. Do NOT read `navPerShare`
  (absent). Do NOT add arbitrary-limit order UI (phase 2 per CoW-exit.md) — MVP exit = "sell to floor".
- Do NOT gate the gate on `npm run dev` (EMFILE-floods on macOS) — the gate is `npm run build`.

## Key requirements
1. **Read-only depth chart FIRST (the MVP core).** NAV line @ 100% + the protocol bid block @ `navExit×(1−d)`
   sized to `currentBid.sellAmount` + the external CoW book fanned below. Must render correctly when the external
   book is EMPTY (expected on the fork — the real `api.cow.fi/base` does not know the fork's szipUSD address), and
   when `currentBid` is empty (no live protocol bid → show just the NAV line + an empty/"no resting bid" state).
2. **% of NAV axis.** x maps a CoW order's USDC-per-share price to `price / navExit × 100`. The protocol block sits
   at `(1 − dBps/10_000) × 100`. y = cumulative USDC depth.
3. **Liquidity gauge** explains the protocol depth (free farm utility + `U`), fail-soft.
4. **One-click exit** reuses the FE-04 spine (open `ZcWithdrawModal` prefilled to "sell to floor" = the
   `quoteMaxPrice` limit). No new signing/submit code.
5. **Reads are null-guarded** (the `useRpcClient().client` may be absent) and never throw on the page; `navEntry`
   stays wrapped (can revert) — but the page only needs `navExit` (never reverts).
6. **Registered route** under `pages/lender/` (file-based routing), `Zc*`-prefixed components under
   `components/zipcode/`, composables in `composables/` — matching the layer conventions.

## Implementation pins (cold-builder guesses NONE)
1. **Reads:** `const { client } = useRpcClient(); if (!client.value) return undefined;
   client.value.readContract({ ...ZIPCODE_CONTRACTS.buyBurnModule, functionName: 'currentBid' })` →
   returns `[uid: Hex, sellAmount: bigint]`. Same for `quoteMaxPrice`/`buybackCap`/`dBps` and
   `navOracle.navExit`. Mirror `composables/useZipPosition.ts` exactly.
2. **% of NAV math (all bigint, scale to number only for the chart):** `navExit` is 18-dp USD per 1e18 share;
   `quoteMaxPrice` is 6-dp USDC per 1e18 share; the protocol floor % = `(10_000 − dBps) / 100` (i.e. dBps=200 →
   98%). For an external CoW order at `price6` (USDC-6dp per share equivalent), `%OfNav = price6 × 1e12 / navExit
   × 100` (reconcile 6-dp→18-dp). Pin the 1e12 reconciliation so the chart axis matches the on-chain basis.
3. **CoW Orderbook fetch:** `GET https://api.cow.fi/base/api/v1/orders?owner=…` is owner-scoped; for a token-pair
   book use the documented orders endpoint and FILTER client-side to `sellToken|buyToken ∈ {szipUSD, USDC}`
   (verify the exact query the layer's existing `~/entities/cowswap` helper uses before hand-rolling; reuse it if
   it exposes a list call). On any non-200 / empty, return `[]` (graceful — the fork has no real CoW orders).
4. **Chart:** chart.js via `vue-chartjs` `<Bar>`/`<Scatter>` + `chartjs-plugin-annotation` for the NAV line;
   register the controllers/plugin once (the euler-lite pattern). Cumulative-USDC step series.
5. **Exit CTA:** import + mount `ZcWithdrawModal` (or its trigger) — do not reimplement. Prefill the "sell to
   floor" limit from `quoteMaxPrice`.
6. **Gauge reads:** if `eulerEarn`/warehouse are not yet in the registry, add them (addresses from
   `build/anvil/contract-map.md`; minimal ABI fragments `maxWithdraw(address)`, `convertToAssets(uint256)`,
   `balanceOf(address)` for an ERC4626). `freeReservoir = maxWithdraw(warehouse)`; `U = 1 − maxWithdraw /
   convertToAssets(balanceOf(warehouse))`. NEVER `IERC20.balanceOf(eulerEarn)` (§8.2 — donatable).

## Pin CORRECTIONS from the critic pass (override anything above — verified in the layer)
- **PC1 — the gauge needs NO registry additions** (deliverable #6 is moot). The registry already has `eePool`
  (`0x1a7A…`), `warehouseSafe` (`0xe028…`), and `durationFreezeModule`; `lib/zipcode/abi/EulerEarn.ts` already
  exposes `maxWithdraw(address)`, `convertToAssets(uint256)`, `balanceOf(address)`. Gauge reads:
  `freeReservoir = eePool.maxWithdraw(warehouseSafe)`; `U = 1 − maxWithdraw / convertToAssets(balanceOf(warehouseSafe))`,
  all off `ZIPCODE_CONTRACTS.eePool` + the `warehouseSafe` address. No new files in `lib/zipcode/`.
- **PC2 — `currentBid()` decodes to a POSITIONAL tuple `[uid: Hex, sellAmount: bigint]`** (viem returns an array,
  not a named struct): `const [uid, sellAmount] = await client.value.readContract({...ZIPCODE_CONTRACTS.buyBurnModule,
  functionName:'currentBid'})`. **"No live bid" = `sellAmount === 0n`** (equivalently `uid === '0x'`).
- **PC3 — the exit CTA just OPENS `ZcWithdrawModal`; it has NO prefill prop.** Its props are `:is-open` +
  optional `:user`, and it emits `@close`/`@success`; it resets `rawAmount`/`rawLimit` on open and already
  surfaces the floor (`quoteMaxPrice`/`dBps`) + now-vs-waiting itself. So the page holds a local `isOpen` ref and
  `<ZcWithdrawModal :is-open=… :user=… @close=…/>` + a "Sell to floor" button that sets `isOpen=true`. Do NOT
  modify FE-04's modal contract; a true limit-prefill (an optional `initialLimit?` prop) is a nice-to-have only —
  skip it for the MVP.
- **PC4 — `useCowOrderbook` is genuinely net-new.** `~/entities/cowswap` only re-exports
  `fetchCowSwapOrderStatus` (status polling) — there is NO list-orders helper. Hand-roll
  `fetch('https://api.cow.fi/base/api/v1/orders?owner=…')` (the same raw-`fetch` style `useCowExit.submitOrder`
  uses), filter client-side to `sellToken|buyToken ∈ {szipUSD, USDC}`, return `[]` on non-200/empty (the fork has
  no real CoW orders — render the NAV line + protocol block alone; do NOT treat empty as an error or spin on it).
- **PC5 — chart.js is registered PER-COMPONENT in `<script setup>`** (it's an `euler-lite` dep, importable from
  the layer). Model the registration + `<Line>`/`<Bar>` usage on
  `euler-lite/components/entities/vault/overview/VaultOverviewBlockIRM.vue` (imports the controllers/scales +
  `chartjs-plugin-annotation`, calls `ChartJS.register(...)` once in the component). Reads mirror
  `composables/useZipPosition.ts` (`useRpcClient().client`, null-guarded).

## Done when (the gate — FE track, per harness)
- `cd frontend/zipcode-finance-euler && npm run build` (= `nuxt build`) is GREEN (NOT `npm run dev`).
- The page route resolves; with anvil up + `DEV_GEO_COUNTRY=GB`, `node .output/server/index.mjs` → the
  `/lender/szip-exit-book` route returns 200 and the chart renders the NAV line + protocol bid block from live
  reads (external book empty on the fork is acceptable and must not error).
- The exit CTA opens the existing `ZcWithdrawModal` (FE-04 flow), unchanged.
- Code committed to the LAYER repo (`frontend/zipcode-finance-euler`, remote `resi-labs-ai`) — NEVER staged in
  the monorepo. Zero load-bearing guesses.

## Depends on / unblocks
- **Depends on:** FE-04 (the withdraw spine — shipped); CRE-05a (the loop that maintains `currentBid` the chart
  reads — shipped). Anvil up.
- **Unblocks:** the retirement of `build/CoW.md` + `build/CoW-exit.md` (both deleted once this lands — the durable
  record becomes the built code + wires + PROGRESS).
