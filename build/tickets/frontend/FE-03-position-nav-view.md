# FE-03 — Position / NAV view: szipUSD + zipUSD balances + $ value via `navExit` (§7 / §12)

> Builds the lender portfolio's **on-chain position panel** on top of the FE-02 supply path. FE-02 already added a
> minimal on-chain USDC + szipUSD read to `pages/lender/portfolio.vue` (refreshed on a confirmed deposit `@success`).
> FE-03 replaces that ad-hoc read with a dedicated **`useZipPosition`** composable + a **`ZcPositionPanel`** component
> that shows the connected wallet's szipUSD + zipUSD balances and **values the szipUSD position in $ via the deployed
> `SzipNavOracle`**. The contract is truth (harness §1): the oracle has **no `navPerShare()`** (FE-01 seam) — bind
> `navExit()` (redemption price) for a *held* position's $ value, and `navEntry()` (issuance price) only for the
> "what $1 buys" hint. Where the spec prose says `navPerShare`, the contract wins.

## Deliverable
Swap the portfolio's ad-hoc on-chain read for a real position/NAV view. Ship three layer files:
1. `composables/useZipPosition.ts` — reads (proxy client, FE-02 patterns) the connected wallet's `szipUsd.balanceOf`
   + `zipUsd.balanceOf`, the oracle's `navExit()` (redemption NAV/share) and `navEntry()` (issuance NAV/share, may
   revert — see Key req 4), and derives the szipUSD position's **$ value** + the total position $ value + the
   "szipUSD per $1" entry hint. All `bigint`; all formatted by real decimals.
2. `components/zipcode/ZcPositionPanel.vue` — renders the panel: szipUSD balance + its $ value (via `navExit`),
   zipUSD balance (= $ 1:1), total position $ value, and the NAV/share lines ("≈ $X redeemable / szipUSD" +
   "≈ N szipUSD / $1 in"). Loading + not-connected + zero-position states handled.
3. `pages/lender/portfolio.vue` — drop the page-local `refreshOnChainBalances`/`onChainUsdc`/`onChainSzip` adhoc read
   block (FE-02 stopgap) and mount `<ZcPositionPanel>` instead, refreshed on the deposit modal's `@success`. The mock
   "Total Balance" hero (`state.balanceUsdc` from `store.ts`) stays as the demo headline; the new panel is the
   **real on-chain** position surface beside/below it. Wallet USDC stays shown (read in the panel).

## Spec §
`build/claude-zipcode.md` **§7** (the junior NAV-per-share is the issuance/exit pricing primitive: issuance at
`navEntry = max(spot, twap)`, exit at `navExit = min(spot, twap)`, "protecting resident holders both directions")
and **§12** (dashboard metric 3 — junior NAV/share + position display). FE-03 is the **per-wallet position** slice of
§12; the full five-metric **solvency dashboard** is FE-06. Honors §17: NAV is the on-chain pricing primitive, read
not computed; no AVM/heartbeat; szipUSD is the NAV-priced transferable share.

## Binds to (verified against the deployed ABIs + the FE-01 registry)
All via the **FE-01 module** (`lib/zipcode/contracts.ts` → `ZIPCODE_CONTRACTS[key] = { address, abi }`; keys confirmed
present in `lib/zipcode/generated/registry.ts`). Reads go through the **browser proxy client**
(`useRpcClient().client`, null-guarded) exactly like FE-02's `useZipDeposit` — the FE-01 default inline client is
node/SSR-only (CORS-fails in the browser).

- **`navOracle`** = `0x0C3E77314D97e8e001e0F626A559992479A3C79e` (`SzipNavOracle`). Back-pressure check PASSES against
  `build/anvil/abi/SzipNavOracle.json`:
  - `navExit() view → uint256` (18-dp NAV/share, **redemption** price `min(spot, twap)`). **Does NOT revert on
    staleness** (`SzipNavOracle.sol:380` — "prices off the last good mark"). Returns `GENESIS_NAV = 1e18` at zero
    effective supply (`spotNavPerShare`, `:336`). **This is the price for a held position's redeemable $ value (§7).**
  - `navEntry() view → uint256` (18-dp NAV/share, **issuance** price `max(spot, twap)`). **CAN REVERT** —
    `StalePrice(leg)` if a required pushed leg is stale, or `StaleRate()` if the xALPHA rate oracle is wired+stale
    (`:368-376`). Use ONLY for the "szipUSD per $1 in" hint, wrapped so a revert degrades gracefully (issuance
    paused), never for the held-position value. Live on the seeded fork ≈ `1.07e20` (i.e. ~$107.265/share).
  - **Do NOT bind `navPerShare()`** — absent, reverts. `spotNavPerShare()`/`twapNavPerShare()` also exist but are NOT
    the consumer surface here; bind `navExit`/`navEntry` (the §7 bracket reads).
- **`szipUsd`** = `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` (`SzipUSD`) — **18-dp** NAV-priced share. Read
  `balanceOf(user) view → uint256`.
- **`zipUsd`** = `0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF` (`ESynth`) — **18-dp** $1 utility dollar. Read
  `balanceOf(user) view → uint256`; its $ value is the token amount 1:1 (zipUSD = $1, §4.5/§7).

**Model from (verified files, same as FE-02):**
- read shape — `composables/useZipDeposit.ts:31-105` (`if (!client.value) return undefined` then
  `client.value.readContract({ ...ZIPCODE_CONTRACTS[key], functionName, args })`), itself modeled on
  `euler-lite/composables/useCustomTokenResolver.ts:30-44`.
- connected account / connect — `useWagmi()` → `address`, `isConnected`, `connect()` (auto-imported; see
  `euler-lite/composables/useWagmi.ts:100,127-132,202`).
- browser read client — `useRpcClient()` → `client` (auto-imported; `euler-lite/composables/useRpcClient/index.ts:6`,
  `client.value` null until chainId resolves).
- the consuming page — `pages/lender/portfolio.vue:185-226` (the FE-02 adhoc `refreshOnChainBalances` block to
  replace) + `:129-133` (the `<ZcDepositModal @success="…">` wiring to keep).
- display card shell — `components/zipcode/ZcStatCard.vue` (`brand-card` + `h-mono-eyebrow` + `tabular-nums`
  classes); model the panel's styling on it + the existing hero card markup in `portfolio.vue:27-90`.

## Starting state
- FE-02 done: `useZipTx` + `useZipDeposit` shipped; `portfolio.vue` has a page-local `refreshOnChainBalances()` that
  reads `usdc.balanceOf` + `szipUsd.balanceOf` on the modal's `@success` and shows them as raw "Wallet USDC / szipUSD"
  text (`portfolio.vue:185-212`). No $-value, no NAV read, no zipUSD balance, no dedicated component.
- FE-01 registry + typed ABIs present; FE-00 booted the layer on the fork (proxy `/api/rpc/8453` → chainId `0x2105`).
- `navExit()` live on the fork is readable (anvil up @ `127.0.0.1:8545`, block 47096192).
- No `useZipPosition` composable or `ZcPositionPanel` component exists yet.

## Do NOT
- Do **not** bind `navPerShare()` (absent — reverts). Held-position value = `navExit()`; entry hint = `navEntry()`.
- Do **not** value a held position at `navEntry` — that is the *issuance* (buy) price and can revert. §7: a holder's
  current redeemable value is the **exit** price `navExit` (`min(spot, twap)`).
- Do **not** let a `navEntry()` revert crash the panel — wrap it; on revert show "issuance paused" / hide the entry
  hint, but **still render** balances + the `navExit`-based value (navExit never reverts).
- Do **not** read on-chain state through the FE-01 **default** inline client from the browser (CORS). Use
  `useRpcClient().client`, null-guarded (skip the read, return `undefined`, never cast-and-crash).
- Do **not** float-scale. szipUSD/zipUSD/NAV are all **18-dp**; use viem `formatUnits`/`parseUnits` and **bigint**
  math for the $ value (`szipBal * navExit / 1e18`). USDC (if shown) is **6-dp**.
- Do **not** introduce a write path, a new tx, or touch `useZipTx`/`useZipDeposit` — FE-03 is **read-only**.
- Do **not** assume szipUSD ≈ zipUSD ≈ $1. One szipUSD ≈ $107 on the seeded fork (NAV/share); the panel's whole job
  is to show that conversion. Never display the szipUSD token count as if it were dollars.
- Do **not** stage the built Vue/composables in the monorepo — they commit to the **layer repo** (`resi-labs-ai`).
  Only this ticket file lands in `build/tickets/frontend/`.

## Key requirements
1. **`useZipPosition` — the read composable.** Mirror `useZipDeposit`'s structure (proxy client, null-guarded reads).
   Expose individual reads + one aggregator. **The composable returns raw `bigint`s; the COMPONENT does all
   `formatUnits` display formatting** (the composable never returns strings).
   - reads: `szipBalanceOf(user)`, `zipBalanceOf(user)`, `navExit()`, `navEntry()`. **Only `navEntry()` is wrapped**
     (`try { … } catch { return undefined }`) — it reverts on stale legs; the other three are NOT caught (a throw
     there is a real fault, let it surface).
   - a single `async loadPosition(user): Promise<ZipPosition>` that fetches all of the above once and returns a plain
     object `{ szipBal, zipBal, navExit, navEntry, szipUsdValueWad, zipUsdValueWad, totalUsdValueWad,
     sharesPerDollarWad }` (all typed `bigint | undefined`). The component calls this once per load and binds the
     derived fields. Derivations (bigint, 18-dp, round-down — define a `ZipPosition` interface for the return type):
     - `szipUsdValueWad = navExit === undefined ? undefined : (szipBal * navExit) / 10n ** 18n`  (held redeemable $)
     - `zipUsdValueWad   = zipBal`  (zipUSD = $1, already 18-dp USD)
     - `totalUsdValueWad = (szipUsdValueWad === undefined || zipUsdValueWad === undefined) ? undefined :
       szipUsdValueWad + zipUsdValueWad` (undefined if `navExit` was undefined, i.e. szip leg unpriced)
     - `sharesPerDollarWad = navEntry === undefined ? undefined : (10n ** 36n) / navEntry`  (szipUSD a fresh $1
       deposit would mint — the "N szipUSD / $1 in" hint; undefined when issuance is paused). `10n ** 36n / navEntry`
       == `(1e18 * 1e18) / navEntry`, the 18-dp inverse price.
   - If `!client.value` or `!user`, `loadPosition` returns an all-`undefined` `ZipPosition` (loading/not-ready), never
     throws.
2. **`ZcPositionPanel` — the display component.** A `brand-card` (model `ZcStatCard.vue` + the `portfolio.vue` hero).
   Add a small local `formatUsd(wad?: bigint): string` helper — `wad === undefined ? '—' : '$' +
   Number(formatUnits(wad, 18)).toFixed(2)` (display-only; do NOT reuse `store.ts`'s `formatUsdc`, which is 6-dp).
   NAV/share strings show ~4 dp (`Number(formatUnits(x, 18)).toFixed(4)`). Renders:
   - **szipUSD balance** (`formatUnits(szipBal, 18)`) and its **$ value** (`formatUsd(szipUsdValueWad)`), labelled so
     the user sees "X szipUSD ≈ $Y".
   - **zipUSD balance** (`formatUnits(zipBal, 18)`) shown as "= `formatUsd(zipUsdValueWad)`" (1:1).
   - **Total position value** (`formatUsd(totalUsdValueWad)`).
   - **NAV/share lines:** "Redeemable ≈ $`{toFixed4(navExit)}` / szipUSD" (always, from `navExit`) and, when
     `sharesPerDollarWad` is defined, "≈ `{toFixed4(sharesPerDollarWad)}` szipUSD / $1 in" (from `navEntry`); when
     `navEntry` reverted (`sharesPerDollarWad === undefined`), render "issuance paused" in place of the entry line.
   - **Props (pinned — pick ONE mechanism, no `defineExpose`):** `defineProps<{ user?: Address; refreshKey?: number }>()`.
     The component owns the load: a `const pos = ref<ZipPosition>()` + a loading flag, populated by an async
     `load()` that calls `loadPosition(props.user)`. Run `load()` on mount (`onMounted`) and re-run via
     `watch([() => props.user, () => props.refreshKey, client], load)` (watching the reactive `client` ref too, so the
     first load fires once the proxy client resolves from null). **No `defineExpose`/`refresh()`** — the page drives
     refresh purely by bumping `refreshKey`. **One-shot per trigger; no polling interval** (§17: no heartbeat).
3. **States.** Not-connected (`!props.user`, derived from `useWagmi().isConnected`/`address`) → "Connect wallet to
   view your position" + a `connect()` button (via `useWagmi()`, modeled on the FE-02 gate at
   `components/zipcode/ZcDepositModal.vue:106-110,178`); **clear any prior position data when `user` goes null** (the
   `watch` re-runs `load`, which returns all-`undefined` for a null user). Loading → "Loading position…". Zero position
   (balances `0n`, `navExit = GENESIS_NAV = 1e18`) → render `$0.00` cleanly (no divide-by-undefined). Client not ready
   (`!client.value`) → stay in loading; the `watch` on `client` re-fires `load` once it resolves.
4. **`navEntry` revert is non-fatal.** Because `navEntry()` reverts on stale legs (`StalePrice`/`StaleRate`), the
   composable MUST catch it and the panel MUST still render the balances + the `navExit` value. This is the load-
   bearing difference from FE-02 (which read `navEntry` optimistically).
5. **Decimals.** szipUSD, zipUSD, navExit, navEntry are **all 18-dp**. Use `formatUnits(x, 18)`; for the displayed $
   figures truncate/round to 2 dp in the template (a small `formatUsd(wad)` helper, or `Number(formatUnits(x,18))`
   `.toFixed(2)` — acceptable for *display only*, never for math). Keep all arithmetic in `bigint`.
6. **Page integration.** `portfolio.vue` drops the FE-02 stopgap (`refreshOnChainBalances`, `onChainUsdc`,
   `onChainSzip`, `onChainUsdcDisplay`, `onChainSzipDisplay`, the inline `readContract` block) and renders
   `<ZcPositionPanel :user="address" :refresh-key="positionRefreshKey" />`, bumping `positionRefreshKey` on the
   modal's `@success`. Keep the mock store hero + tabs + withdraw path untouched (FE-04 owns withdraw).

## Resolved decisions (close these — no builder guess)
- **Held position is valued at `navExit`, not `navEntry`** (§7: exit = `min(spot,twap)` is the redeemable price; FE-02
  report flagged this explicitly). `navEntry` is buy-side only.
- **`navEntry` may revert; `navExit` may not.** Verified in `SzipNavOracle.sol:368-384`. Catch `navEntry`; never
  catch `navExit` (a throw there is a real fault, let it surface).
- **Auto-imports.** `useWagmi`, `useRpcClient`, `useDebounceFn` auto-import in the layer; composables you author in
  `composables/` auto-import; components in `components/zipcode/` auto-register (used unprefixed as `<ZcPositionPanel>`
  per the existing `<ZcStatCard>`/`<ZcDepositModal>` usage). `useToast` is NOT auto-imported, but FE-03 needs no toast
  (read-only) — omit it.
- **NAV/share decimals.** `navExit`/`navEntry` are 18-dp NAV-per-share (USD). `formatUnits(navExit, 18)` ≈ `"107.26…"`.
  The "szipUSD per $1" inverse = `1e36 / navEntry` then `formatUnits(_, 18)` ≈ `"0.0093…"`. Both are display strings;
  the math stays bigint.
- **Multi-return reads.** None here — `navExit`/`navEntry`/`balanceOf` are all single `uint256` returns (unlike
  FE-02's `previewZap` tuple). No tuple indexing.
- **Zero / genesis.** At zero szipUSD supply `navExit` returns `GENESIS_NAV = 1e18` ($1); a user with `0n` szipUSD
  gets `szipUsdValueWad = 0n`. Render `$0.00`, not a blank/NaN.
- **No subgraph / no history.** FE-03 is a point-in-time on-chain read (§12 "direct on-chain view reads" for MVP). No
  trailing APR, no charts — those are FE-06.
- **Withdraw/exit untouched.** The szipUSD **exit** flow (CoW-sell / window-redeem, valued at `navExit×(1−d)`) is
  FE-04; FE-03 only *displays* the redeemable value. Cross-link when FE-04 is authored.
- **Refresh contract (pinned — closes the double-spec).** ONE mechanism: the page owns `const positionRefreshKey =
  ref(0)`, passes `:refresh-key="positionRefreshKey"` + `:user="address"` (the `useWagmi().address` already in scope
  at `portfolio.vue:188`), and does `@success="() => positionRefreshKey++"` on `<ZcDepositModal>`. The panel watches
  `refreshKey`/`user`/`client` and reloads. **No `defineExpose`, no `refresh()` method, no `@success` payload used.**
- **Composable returns bigints; component formats.** `loadPosition` returns the `ZipPosition` bigint object; ALL
  `formatUnits`/`toFixed`/`$` formatting lives in `ZcPositionPanel`. Define+export a `ZipPosition` interface from the
  composable for the component's `ref<ZipPosition>` type.
- **Only `navEntry` is caught.** `navExit` and the two `balanceOf` reads are NOT wrapped — a throw there is a real
  fault. `navEntry`'s catch → `undefined` → `sharesPerDollarWad` `undefined` → the panel shows "issuance paused".
- **Display precision.** `$` values → `formatUsd` (2 dp); NAV/share + szipUSD-per-$1 → `toFixed(4)`. Token balances →
  `formatUnits(_, 18)` (full precision is acceptable, or trim in the template). Math stays bigint throughout.

## Done when
- `npm run build` (`nuxt build`) is **green** in `frontend/zipcode-finance-euler/` (the gate — NOT `npm run dev`).
- `useZipPosition` + `ZcPositionPanel` exist; `portfolio.vue` renders the panel and drops the FE-02 adhoc read; the
  panel shows szipUSD + zipUSD balances, the szipUSD $ value (via `navExit`), total position $ value, and the NAV/share
  lines; a `navEntry` revert is non-fatal.
- A cold-build subagent building from this ticket alone returns **zero load-bearing guesses** (every import, address,
  ABI method, read path, and derivation resolves to a cited file/symbol).
- **Acceptance (anvil up, signer-supplied `NUXT_PUBLIC_APP_KIT_PROJECT_ID`):** connected, the panel reads the wallet's
  szipUSD/zipUSD balances and renders the `navExit`-based $ value + the NAV/share lines off the live oracle. (If no
  project id for click-connect, the gate is the green `nuxt build` + the cold-build zero-guess verdict; the live read
  is the signer-supplied extension.)
- Committed to the **layer repo** (`resi-labs-ai`). PROGRESS updated: FE-03 done, FE-04 set NEXT.

## Depends on
FE-00 (layer boots — DONE), FE-01 (address book + typed ABIs — DONE), FE-02 (read patterns + the `@success` refresh
hook — DONE). The szipUSD **exit** flow is FE-04 (values exits at `navExit×(1−d)`); cross-link the redeemable-value
display when FE-04 lands. No open obligations against FE-03 (PROGRESS).
