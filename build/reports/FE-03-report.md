# FE-03 report — Position / NAV view (szipUSD + zipUSD balances + $ value via `navExit`)

**Window:** 2026-06-10 · **Track:** Frontend ↔ anvil · **Spec §:** §7 (NAV pricing primitive) / §12 (position
display) · **Status:** DONE

## What the window did
Built the lender portfolio's **real on-chain position panel** on top of the FE-02 supply path, replacing FE-02's
ad-hoc balance read with a dedicated read composable + component. The panel values the held szipUSD position in $ via
the deployed `SzipNavOracle`.

Built (committed to the **layer repo** `resi-labs-ai`, commit `b66c8be`):
- `composables/useZipPosition.ts` — read-only, proxy-client (`useRpcClient().client`, null-guarded). Reads
  `szipUsd.balanceOf` + `zipUsd.balanceOf` + `navExit()` + `navEntry()`; one `loadPosition(user?)` aggregator returns
  a raw-bigint `ZipPosition` (exported interface). Derivations: `szipUsdValueWad = szipBal*navExit/1e18` (held
  redeemable $), `zipUsdValueWad = zipBal` (zipUSD = $1), `totalUsdValueWad`, `sharesPerDollarWad = 1e36/navEntry`
  (the "szipUSD per $1 in" hint). **Only `navEntry` is `try/catch`'d** — it reverts on stale legs; `navExit` and the
  `balanceOf` reads are not caught.
- `components/zipcode/ZcPositionPanel.vue` — `brand-card` (modeled on `ZcStatCard` + the portfolio hero). Shows
  szipUSD + zipUSD balances, the szipUSD $ value (via `navExit`), total position $, and the NAV/share lines
  ("Redeemable ≈ $X / szipUSD" always; "≈ N szipUSD / $1 in" or "issuance paused" when `navEntry` reverted).
  Not-connected (with `connect()`), loading, and zero-position states. Props `{ user?, refreshKey? }`; loads on mount
  + watches `user`/`refreshKey`/`client` (the last so the first load fires once the proxy client resolves from null).
  No `defineExpose`. Component owns all `formatUnits`/`toFixed`/`$` formatting (math stays bigint in the composable).
- `pages/lender/portfolio.vue` — dropped the FE-02 ad-hoc `refreshOnChainBalances`/`onChainUsdc`/`onChainSzip` block
  (and its now-unused imports); mounts `<ZcPositionPanel :user="address" :refresh-key="positionRefreshKey" />` below
  the hero; `@success="() => positionRefreshKey++"` on the deposit modal. Mock store hero, tabs, and withdraw path
  untouched (withdraw = FE-04).

**Gate:** `npm run build` (`nuxt build`) green, exit 0. Cold-build (fresh subagent, ticket-only) returned **zero
load-bearing guesses** — every import/address/ABI method/read-path/derivation resolved to a cited file/symbol. No
back-pressure — every UI view exists on the deployed oracle.

## Decisions to sanity-check
- **Held position valued at `navExit` (redemption), not `navEntry` (issuance).** §7: exit = `min(spot,twap)` is the
  redeemable price; issuance = `max(spot,twap)`. Confirmed by spec-fidelity + frontend-binding critics. (FE-02's
  report flagged this as the FE-03 correction; honored.)
- **`navEntry` revert is non-fatal; `navExit` never reverts — and the *reason* is the §7 bracket, not redeemability.**
  Verified in `SzipNavOracle.sol:368-384`. `navEntry` (issuance, `max(spot,twap)`) reverts `StalePrice`/`StaleRate`
  because minting at a stale price would hand out mispriced shares. `navExit` (redemption, `min(spot,twap)`) does NOT
  revert: it is the **conservative accounting/bid price** that must keep producing a number for NAV and the buyback
  bid even when a pushed feed lapses — its safety is the `min` bracket (a stale/spiked leg cannot inflate it), NOT a
  freshness gate. (This is NOT "a holder can always redeem" — positions can be frozen and exits run through the CoW
  book / par epoch queue, not instant redemption.) Only `navEntry` is caught — a throw on `navExit`/`balanceOf` is a
  real fault and is allowed to surface. This is the load-bearing difference from FE-02,
  which read `navEntry` optimistically.
- **One szipUSD ≈ $107 on the seeded fork** (`navExit`≈`107.01e18`, `navEntry`≈`107.27e18`, both 18-dp NAV/share).
  The panel's job is to show that conversion; the szipUSD token count is never displayed as dollars.
- **Refresh contract pinned to ONE mechanism** (closed a draft double-spec): page bumps `positionRefreshKey`; panel
  watches it. No `defineExpose`/`refresh()`, no `@success` payload.
- **`navPerShare()` is absent** on the deployed oracle (FE-01 seam) — bound the §7 bracket reads (`navExit`/`navEntry`),
  not `navPerShare` or `spot/twapNavPerShare`. The contract wins over spec prose (harness §1).

## Holes → resolution
- **Refresh mechanism double-specified in the draft** (junior-dev most-blocking finding: `refresh()` via `defineExpose`
  OR `:refreshKey`) → resolved in the ticket to ONE mechanism (`refreshKey` bump only), pinned in Key req 2 +
  Resolved-decisions. No builder guess.
- **Composable-returns-strings vs bigints ambiguity** → resolved: composable returns raw bigints, component formats.
  `ZipPosition` interface exported for the component's `ref` type.
- **Display precision unspecified** → resolved: `$` via a local `formatUsd` (2 dp; do NOT reuse `store.ts`'s 6-dp
  `formatUsdc`), NAV/share via `toFixed(4)`. Display-only; math bigint.
- **`nuxt build` does not type-check `.vue`** (carried from FE-02; no `typescript.typeCheck`) — the green build is a
  compile/bundle gate. New code verified type-correct by direct read (viem `readContract`/`formatUnits` sigs, the
  exported `ZipPosition` import, `useWagmi`/`useRpcClient` shapes). Not blocking; a future ticket could enable
  `vue-tsc`.

## Doc edits
- `build/tickets/PROGRESS.md`: FE-03 → done (NEXT block + backlog row + "Just done" entry with the seam); **FE-04 set
  NEXT** with its back-pressure note (verify whether the szipUSD exit is `ExitGate.requestExit`/`cancelExit` vs the
  `SzipBuyBurnModule.burnFor` CoW path before binding).
- No `build/claude-zipcode.md` change — critics found **no spec gap**. §7/§12 fully define the NAV pricing primitive
  and the position display; all findings were ticket-clarity or binding-precision, fixed in the ticket. The existing
  FE-01 `navPerShare`-absent seam in PROGRESS already records the contract-vs-prose rename (no new obligation owed).

## Status + NEXT
- **FE-03 DONE**, gate green (`nuxt build` exit 0), committed to the layer repo (`b66c8be`). No open obligations.
- **NEXT: FE-04** — szipUSD exit flow (`ExitGate` + `ZipRedemptionQueue`, cooldown panel, wire `ZcWithdrawModal`),
  reusing the `useZipTx` write spine + the FE-03 `navExit` redeemable-value display. Binds `ExitGate` `0xd9b8…` +
  `ZipRedemptionQueue` `0x46c8…` via the FE-01 registry; back-pressure check first (exit may be CoW/`burnFor`-driven).
