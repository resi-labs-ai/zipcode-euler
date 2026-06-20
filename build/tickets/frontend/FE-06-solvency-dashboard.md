# FE-06 — Solvency dashboard (§12 protocol metrics) via direct on-chain view reads

> Builds the **protocol-level §12 solvency surface** on top of the FE-03 read-view template. Where FE-03 was the
> *per-wallet* slice of §12 (metric 3, one holder's position), FE-06 is the **protocol aggregate**: total NAV, zipUSD
> supply + peg, szipUSD NAV/share + APR, utilization / free liquidity, insurance coverage. **Pure reads — no writes,
> no `useZipTx`.** The contract is truth (harness §1): the back-pressure check below confirms each metric maps to a
> real `view` on a deployed contract, and **logs three §12 metrics whose data source is deferred off-fork** (CRE feed /
> post-Hydrex AMM) — these render an explicit "pending" / "par" state, never a fabricated number.

## Deliverable
Swap the lender portfolio's mock protocol figures for real direct-read §12 metrics. Ship three layer files:
1. `composables/useZipSolvency.ts` — the **raw-bigint protocol-solvency aggregator** (FE-03 `useZipPosition` shape:
   proxy-client reads, returns the `ZipSolvency` struct below of `bigint | undefined`, **all**
   `formatUnits`/`%`/`$` formatting lives in the component). Reads the five §12 metric sources (Binds-to below). Pure
   reads, no args (protocol-level, not per-wallet). Exposes one aggregator `loadSolvency(): Promise<ZipSolvency>`.
2. `components/zipcode/ZcSolvencyPanel.vue` — **owns the whole §12 surface**: calls `useZipSolvency.loadSolvency()`
   (re-run on mount + when `refreshKey` / `client` changes, mirroring `ZcPositionPanel`), renders the **`ZcStatCard`
   grid** (the five §12 metrics), derives the two real protocol-vault rows **internally**, and renders
   `<ZcVaultAllocationTable :rows="…">` itself. Props `{ refreshKey }` only. Loading / unavailable / pending-source
   states handled per metric. The page does NOT compute or pass `vaultRows` — the panel is self-contained.
3. `pages/lender/portfolio.vue` — drop the header `ZcStatCard` (the mock `protocol.aumUsdc` treasury card) and the
   mock single-row `vaultRows` computed (`store.ts`/`data.ts` `VAULT_NAME`/`VAULT_APY`) + its `<ZcVaultAllocationTable>`
   usage; mount `<ZcSolvencyPanel :refresh-key="positionRefreshKey">` in their place (reuse the existing
   `positionRefreshKey`, already bumped on deposit/withdraw `@success`). The mock "Total Balance" hero + the FE-03
   `<ZcPositionPanel>` + transactions tab stay (demo headline + per-wallet position, unchanged, like FE-03 kept the
   mock hero).

### `ZipSolvency` struct (the exact composable return — assemble it verbatim)
All fields `bigint | undefined` (undefined = client not ready, the read reverted, or — for the three deferred-source
metrics — no MVP-fork source). The composable returns an all-`undefined` value when `!client.value` and **never
throws** (only `navEntry` is try/caught; everything else is a real fault if it throws):
```ts
interface ZipSolvency {
  // metric 1 — NAV (all 6-dp USDC)
  farmUtilityCash: bigint | undefined        // farmUtilityVault.cash()        — idle reserve
  farmUtilityBorrows: bigint | undefined     // farmUtilityVault.totalBorrows() — par loan value
  protocolNavUsdc: bigint | undefined      // farmUtilityVault.totalAssets()  — cash + borrows (THE NAV)
  seniorAumUsdc: bigint | undefined        // eePool.totalAssets()                — senior allocation row
  // metric 2 — zipUSD (18-dp) + derived ratio
  zipSupply: bigint | undefined            // zipUsd.totalSupply()
  solvencyRatioBps: bigint | undefined     // DERIVED (see math note) — NAV ÷ zipUSD, in bps
  // metric 3 — szipUSD NAV/share (18-dp)
  navExit: bigint | undefined              // navOracle.navExit()    — never reverts
  navEntry: bigint | undefined             // navOracle.navEntry()   — try/caught (StalePrice/StaleRate)
  spotNav: bigint | undefined              // navOracle.spotNavPerShare()  (supplementary)
  twapNav: bigint | undefined              // navOracle.twapNavPerShare()  (supplementary)
  szipSupply: bigint | undefined           // szipUsd.totalSupply()
  lossProvision: bigint | undefined        // navOracle.provision()  — 18-dp junior markdown (NAV sub-line)
  // metric 4 — utilization (6-dp USDC + derived bps)
  utilizationBps: bigint | undefined       // DERIVED — borrows·10000/totalAssets (guard /0)
  freeLiquidityUsdc: bigint | undefined    // = farmUtilityCash (the protocol-level free reserve)
  // metric 5 — insurance (18-dp xALPHA)
  xAlphaEscrowBal: bigint | undefined      // xAlpha.balanceOf(<lienXAlphaEscrow address>)
  farmUtilityRateRay: bigint | undefined     // farmUtilityVault.interestRate() — per-second ray (1e27); 0 on fork
}
```
The three **deferred-source** §12 fields have NO struct entry (no MVP-fork source): **zipUSD peg** (no AMM),
**szipUSD/Duration-Bond APR** (no CRE feed), **off-chain insurance** (no CRE feed). The component renders their
flagged state from constants, not from a read (see "Flagged-state rendering" below).

### Derived-value math (compute in the composable; `bigint` only)
- `solvencyRatioBps = protocolNavUsdc === undefined || !zipSupply ? undefined : (protocolNavUsdc * 10n**12n * 10000n) / zipSupply`
  — the `10n**12n` scales the 6-dp USDC NAV up to the 18-dp zipUSD denomination **before** the bps multiply, so units
  cancel to pure bps. Worked: `(8_000_000_000 · 1e12 · 10000) / 2_000e18 = 8e25 / 2e21 = 40000` bps = 4.00×. Guard
  `zipSupply == 0` (→ undefined, "no supply").
- `utilizationBps = !protocolNavUsdc ? undefined : (farmUtilityBorrows * 10000n) / protocolNavUsdc` — both operands are
  6-dp USDC (same denomination → no scaling). Worked: `6000·10000/8000 = 7500` bps = 75%. Guard `protocolNavUsdc==0`.

### Flagged-state rendering (the three deferred metrics — be concrete, do NOT fabricate a number)
Render each as a `ZcStatCard` whose `value` is the honest placeholder and whose `unit` (the card's existing muted
suffix slot) carries the source tag — these tag strings are **component constants, not reads**:
- **zipUSD peg** → `value="$1.0000"`, `unit="par · no fork AMM"` (zipUSD mints 1:1 vs USDC, §4.5 — par is honest).
- **szipUSD APR** → `value="—"`, `unit="pending CRE feed (CRE-03)"`.
- **off-chain insurance** → `value="—"`, `unit="off-chain · CRE §8.10"`.
The **real on-chain leg beside each** (NAV/share for the APR card, the xALPHA escrow fund for the insurance card) IS
shown with its live value.

### `provision` placement
`lossProvision` is **not** a sixth headline card and is **not** subtracted from NAV — render it as a small sub-line
under the NAV card (e.g. "loss provision: $0.00", 18-dp via `formatUnits(v,18)`), the junior-markdown indicator.

### `ZcVaultAllocationTable` rows (derived inside the panel; exactly two, fixed order)
1. **Senior Warehouse** — `name:'Senior Warehouse'`, `balanceUsdc: seniorAumUsdc` (6-dp string),
   `apy: rateToApyPct(farmUtilityRateRay)`, `status:'Active'`.
2. **Farm utility Credit Market** — `name:'Farm utility Credit Market'`, `balanceUsdc: protocolNavUsdc` (6-dp string),
   `apy: rateToApyPct(farmUtilityRateRay)`, `status:'Active'`.
Both rows show the **same `apy`** = the farm utility per-second-ray rate annualized — which on the MVP fork is **`'0'`**
(ZeroIRM stand-in, `interestRate()==0` → `apy='0'` → the table renders `0% APY`). That both rows show 0% is correct
for the fork (a single 0% IRM); the senior/borrow split only diverges once a non-zero IRM is wired. `rateToApyPct`:
for `ray==0n` return `'0'` (no math); for a non-zero ray, annualize via the **euler-lite rate helper**
(`euler-lite/utils/vault/apy.ts` — the codebase rate→APY path; do NOT hand-roll SPY→APY compounding). The fork rate
is 0, so the 0-branch is the only path exercised this window; the non-zero branch may stub to a TODO calling the helper.

## Spec §
`build/claude-zipcode.md` **§12** (NAV / dashboard / solvency — the five-metric dashboard). FE-06 realizes the full
five-metric protocol surface; FE-03 was metric 3's per-wallet slice. Honors the project subgraph-deferral: §12 prose
names "an off-chain indexer (the subgraph workstream) … not computed per-request on-chain" as the *eventual* delivery,
but **PROGRESS locks the MVP on direct on-chain view reads** ("Subgraph — deferred (FE track runs without it)") — for
the MVP these aggregates are read per-request directly off the fork. This is an **intentional, already-recorded MVP
scoping** (PROGRESS "Subgraph — deferred"), **not** a spec edit: §12 keeps describing the production indexer path.
Honors §17: NAV (`SzipNavOracle`) is the read on-chain pricing primitive; no AVM/heartbeat poll; szipUSD is the
NAV-priced share.

## Binds to (verified against the deployed ABIs + the FE-01 registry, live-read on the fork)
All via the **FE-01 module** (`lib/zipcode/contracts.ts` → `ZIPCODE_CONTRACTS[key] = { address, abi }`; every key below
confirmed present in `lib/zipcode/generated/registry.ts`). Reads go through the **browser proxy client**
(`useRpcClient().client`, null-guarded) exactly like FE-02/FE-03 — the FE-01 default inline client is node/SSR-only
(CORS-fails in the browser). Live fork values (anvil up @ `127.0.0.1:8545`, block ~47096195) shown per read.

### Metric 1 — Total protocol NAV (cash + marked loan value), §12 ¶1
- **`farmUtilityVault`** = `0x1aFc8c641BE6E8a0849f00f3c90a27D44710D267` (EVK `IEVault`, `external/IEVault.json`).
  The farm utility credit market **is** the warehouse lending vault; §12's "idle USDC (cash/reserve) + outstanding loan
  value [par]" maps **exactly** to its `cash()` + `totalBorrows()`:
  - `cash() view → uint256` (6-dp USDC, idle reserve). Live `2000000000` = $2,000.
  - `totalBorrows() view → uint256` (6-dp USDC, outstanding loan value at **par**). Live `6000000000` = $6,000.
  - `totalAssets() view → uint256` = `cash + totalBorrows` (6-dp). Live `8000000000` = $8,000. **This single read is
    the headline Total Protocol NAV** (cash + marked loan value); show `cash` + `totalBorrows` as its two components.
  - **Do NOT add the senior EE pool `totalAssets` to this** — the EE pool *supplies into* the farm utility vault, so its
    claim already resolves to the farm utility's `cash + borrows`; summing them double-counts (§12 ¶1 explicitly forbids
    double-counting "the lent-out USDC and the lien collateral … are two sides of one loan"). The EE pool is read
    separately as the **senior AUM** allocation row (below), not folded into NAV.
  - The §11/§12 **recovery markdown** on an *impaired* loan lives in the **junior** `SzipNavOracle.provision()` (borne
    by szipUSD via the lower `navExit`), **not** subtracted from the senior farm utility NAV. Read `provision()` and show
    it as a separate "loss provision" line; live `0` (no default on the M1 fork → par == recovery).
- **`eePool`** = `0x1a7A8A5a6A2B34895201CFBC997C4eC419ba8A3d` (`EulerEarn`, `external/EulerEarn.json`).
  `totalAssets() view → uint256` (6-dp USDC, senior warehouse AUM). Live `9000000000` = $9,000. → the senior
  allocation row in `ZcVaultAllocationTable`.

### Metric 2 — zipUSD minted + peg, §12 ¶2
- **`zipUsd`** = `0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF` (`ESynth`). `totalSupply() view → uint256` (18-dp
  utility-dollar supply). Live `2000000000000000000000` = 2,000 zipUSD.
- **Solvency ratio = NAV ÷ zipUSD minted** (§12 ¶2, "the senior peg ≥ 1"). Compute decimal-normalized in the
  composable: `ratioBps = (navUsdc6 * 1e12 * 10000) / zipSupply18`. Live `8000e6 / 2000e18` ⇒ `40000` bps = 4.00×.
- **zipUSD peg vs USDC — BACK-PRESSURE (data source deferred, NOT a contract gap).** §12 ¶2 + the §12 footer define
  the peg as "the secondary-AMM price (§6.2)". **There is no zipUSD secondary AMM on the fork** — the real
  zipUSD/xALPHA pool does not exist until post-Hydrex (PROGRESS "Showcase auto-compounder" seam: "the real zipUSD pool
  doesn't exist until post-Hydrex"). So the peg has **no on-chain source on the MVP fork**. Render it as **par
  `$1.0000`** with an explicit "no secondary market on fork (post-Hydrex)" tag. zipUSD mints 1:1 vs USDC at deposit
  (§4.5), so par is the honest MVP value. No new contract surface is owed (the AMM is off-fork by design).

### Metric 3 — szipUSD NAV/share + APR, §12 ¶3
- **`navOracle`** = `0x0C3E77314D97e8e001e0F626A559992479A3C79e` (`SzipNavOracle`). The §7 bracket reads (FE-03 seam:
  **NO `navPerShare()`** — absent, reverts):
  - `navExit() view → uint256` (18-dp redemption NAV/share, `min(spot, twap)`; **never reverts**). Live `≈1.0727e20`.
  - `navEntry() view → uint256` (18-dp issuance NAV/share, `max(spot, twap)`; **CAN REVERT** `StalePrice`/`StaleRate`
    — wrap in try/catch like FE-03; live `≈1.0727e20`).
  - `spotNavPerShare()` / `twapNavPerShare() view → uint256` (18-dp) — optional supplementary display; both real.
  - `provision() view → uint256` (18-dp loss provision; live `0`) — the metric-1 "loss provision" line.
- **`szipUsd`** = `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` (`SzipUSD`). `totalSupply() view → uint256` (18-dp).
  Live `795000000000000000000` = 795 szipUSD.
- **szipUSD trailing APR + Duration Bond premium APR — BACK-PRESSURE (data source deferred, NOT a contract gap).**
  §12 ¶3's headline APR = "the HYDX-vamp trailing-realized yield + the xALPHA subsidy" and the "Duration Bond premium
  APR on frozen positions". **No production on-chain source exists for the MVP fork:** the xALPHA-APR CRE feed is
  **CRE-03, not yet built** (PROGRESS backlog: "the 8x-02 receiver is built; the Go producer remains"); a
  trailing-realized yield would need NAV history the fresh fork does not have (genesis NAV, single mark); the Duration
  Bond premium needs a frozen position (no engineered default on M1). Render the APR fields as **"— (pending CRE yield
  feed, CRE-03)"**; the **navExit/navEntry/spot/twap NAV/share reads above ARE the real, live szipUSD pricing** shown
  beside it. No new contract surface owed (the APR is a CRE-published figure by design, §8.6/§8.8).

### Metric 4 — Utilization / free liquidity, §12 ¶4
- **`farmUtilityVault`** (same as metric 1): `utilizationBps = totalBorrows * 10000 / totalAssets` (guard
  `totalAssets == 0`). Live `6000/8000` ⇒ `7500` bps = 75%. **Free liquidity** = `cash()` (6-dp); live $2,000.
  (`maxWithdraw(address)` exists but is per-account; `cash()` is the protocol-level free reserve — bind `cash`.)

### Metric 5 — Insurance coverage, §12 ¶5
- **`lienXAlphaEscrow`** = `0xfba6a2f082ca39552725cb9190754c2f4c525468` + **`xAlpha`** =
  `0xF6CAAF72A788916915ce1bF111E245e0bEABCd18`. The on-chain **xALPHA backstop fund** = `xAlpha.balanceOf(escrow)`
  (the escrow custodies the per-lien bonds; there is no aggregate view, so read the token balance). Live `0` (no bond
  posted on the fresh fork). 18-dp. **Bind the `xAlpha` token's `balanceOf` with the escrow ADDRESS as the arg:**
  `readContract({ ...ZIPCODE_CONTRACTS.xAlpha, functionName:'balanceOf', args:[ZIPCODE_CONTRACTS.lienXAlphaEscrow.address] })`
  — NOT a method on `LienXAlphaEscrow` itself. (`LienXAlphaEscrow.bondAmount` is per-`bytes32`-lien, not a total — do
  NOT bind it for an aggregate.)
- **Off-chain insurance coverage — BACK-PRESSURE (data source deferred, NOT a contract gap).** §12 ¶5's "off-chain
  insurance (Proof of Insurance, §8.10)" is a **CRE-published** figure (§12 footer: "off-chain insurance coverage is a
  CRE-published figure (§8.10)") — **not built** (no CRE Proof-of-Insurance feed on the fork). Render it as
  **"— (off-chain, attested via CRE §8.10)"**; the **xALPHA escrow fund above IS the real on-chain coverage leg**. No
  new contract surface owed.

### ZcVaultAllocationTable — real protocol rows
Feed `ZcVaultAllocationTable` real protocol-capital rows (replacing the mock single `VAULT_NAME` row), each
`{ name, balanceUsdc (6-dp string), apy, status }`:
- **Senior Warehouse (EulerEarn)** — `balanceUsdc` = `eePool.totalAssets()`; `apy` from the farm utility
  `interestRate()` (see note); `status: 'Active'`.
- **Farm utility Credit Market (EVK)** — `balanceUsdc` = `farmUtilityVault.totalAssets()`; same `apy`;
  `status: 'Active'`.
- **APY note:** `farmUtilityVault.interestRate() view → uint256` is the EVK **per-second ray (1e27) borrow rate**;
  live `0` (the MVP uses the `ZeroIRM` 0%-rate stand-in, PROGRESS). Render **`0%`** honestly (do not fabricate a yield;
  the real rate arrives when a non-zero IRM is wired). If a non-zero rate is ever read, annualize per the euler-lite
  rate helper (see Model-from) rather than re-deriving the SPY→APY math by hand.

**Model from (verified files):**
- read shape — `composables/useZipPosition.ts:44-110` (FE-03: `if (!client.value) return undefined` then
  `client.value.readContract({ ...ZIPCODE_CONTRACTS[key], functionName, args? })`; the `navEntry` try/catch at `:84`;
  the raw-bigint aggregator `loadPosition` at `:96`). **Mirror this exactly** — `useZipSolvency.loadSolvency()`.
- the consuming page — `pages/lender/portfolio.vue` (the header `<ZcStatCard … :value="formatUsdcCompact(protocol.
  aumUsdc)">` at `:19-24` and the mock `vaultRows` computed at `:191-193` + `<ZcVaultAllocationTable :rows="vaultRows">`
  at `:110` to replace; the `positionRefreshKey` bump pattern at `:126`/`:176` to reuse for `<ZcSolvencyPanel>`).
- display shells — `components/zipcode/ZcStatCard.vue` (`{ label, value, unit? }` — pre-formatted string `value`) and
  `components/zipcode/ZcVaultAllocationTable.vue` (`rows: { name, balanceUsdc, apy, status }[]`, renders
  `formatUsdc(row.balanceUsdc)` + `{{ row.apy }}% APY`).
- browser read client — `useRpcClient()` → `client` (auto-imported; `euler-lite/composables/useRpcClient/index.ts`).
- formatting — `lib/zipcode/store.ts` `formatUsdc`/`formatUsdcCompact` (6-dp USDC strings) + viem `formatUnits` for
  the 18-dp NAV/share + the bps→% / ratio derivations (all component-side).

## Starting state
- FE-01..FE-05 done. FE-03's `useZipPosition` + `ZcPositionPanel` are the read template; `ZcStatCard` +
  `ZcVaultAllocationTable` exist but are fed **mock** data (`store.ts` protocol seed + `data.ts` `VAULT_NAME`/
  `VAULT_APY`). No `useZipSolvency` composable or `ZcSolvencyPanel` component exists.
- FE-01 registry includes every key bound here: `farmUtilityVault`, `eePool`, `zipUsd`, `szipUsd`, `navOracle`,
  `lienXAlphaEscrow`, `xAlpha` (confirmed in `lib/zipcode/generated/registry.ts`).
- Anvil up @ `127.0.0.1:8545` (block ~47096195); all five metric sources live-read OK (values above).

## Do NOT
- Do **not** write anything / import `useZipTx` — FE-06 is **pure reads** (no `approve`, no tx, no gas buffer).
- Do **not** fabricate a value for a deferred-source metric. The three back-pressure metrics (**zipUSD peg**,
  **szipUSD/Duration-Bond APR**, **off-chain insurance**) render an explicit "par"/"pending"/"off-chain" state — never
  a made-up number. The on-chain legs beside them (NAV/share, xALPHA escrow fund) ARE real and shown.
- Do **not** add `eePool.totalAssets` to the farm utility NAV (double-count, §12 ¶1). NAV = farm utility
  `totalAssets` (= cash + borrows); the EE pool is a separate allocation row.
- Do **not** bind `navPerShare()` (absent — FE-03 seam) or `LienXAlphaEscrow.bondAmount` for an aggregate (per-lien).
- Do **not** subtract `provision()` from the senior NAV — it is the junior markdown (reflected in `navExit`), shown as
  its own line.
- Do **not** value with floats — all money math is `bigint`; format only at the display edge (CLAUDE.md hard rule 5).

## Key requirements
1. `useZipSolvency.ts` returns a `ZipSolvency` struct of `bigint | undefined` (+ the derived `solvencyRatioBps`,
   `utilizationBps`) and an all-`undefined` empty value when `!client.value`; **never throws** (wrap only `navEntry`).
2. Every on-chain read resolves against the **deployed ABI via the FE-01 registry**, through the **browser proxy
   client** (`useRpcClient().client`), null-guarded — never the FE-01 inline node client (CORS).
3. The **five §12 metrics** render: NAV (+ cash/borrows/provision components), zipUSD supply + solvency ratio + peg
   (par-flagged), szipUSD NAV/share (navExit/navEntry-caught) + APR (pending-flagged), utilization + free liquidity,
   insurance (xALPHA escrow fund + off-chain-flagged). `ZcVaultAllocationTable` shows the two real protocol vault rows.
4. The three **back-pressure** metrics show an explicit deferred-source state, and each is logged as a **seam** in
   `PROGRESS.md` (data source deferred to CRE/post-Hydrex — **no contract obligation owed**, mirroring FE-04's
   spoof-toggle finding).
5. **Gate:** `npm run build` (`nuxt build`) green in the layer; committed to the **layer repo** (`resi-labs-ai`).

## Done when
- `npm run build` green in `frontend/zipcode-finance-euler/`; the dashboard reads the **real §12 metrics off the live
  fork** (the NAV/zipUSD/szipUSD-NAV/utilization/xALPHA-escrow legs are live values, not mock); the three deferred-
  source metrics render their flagged state; reuses the FE-03 read pattern; committed to the layer repo.

## Depends on
FE-01 (registry/ABIs), FE-03 (`useZipPosition` read template + the `navExit`/`navEntry` seam). No inbound obligation
in PROGRESS is owed by FE-06 (the NEXT row lists none).

## Deliberate-choice note (do not let a critic sand this off)
The §12 solvency surface mounts on the **auth-gated `pages/lender/portfolio.vue`** — matching the FE-03/04/05
precedent (every Zc* surface so far lives there) and the fact that `ZcStatCard` + `ZcVaultAllocationTable` already
live on that page. The protocol-solvency metrics are arguably **public** (a trust signal for any observer), so a
later refactor may lift `<ZcSolvencyPanel>` onto a public/dedicated route (or the landing `index.vue`, which already
renders a `ZcStatCard` grid). That relocation is **out of scope for this window** — deferred as a UX seam, not done
here. Keep the panel route-agnostic (no `definePageMeta`, no auth logic inside it) so the future move is a one-line
remount.
