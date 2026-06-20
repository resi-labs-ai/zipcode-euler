# FE-09 — "reservoir" → purpose-true rename (frontend layer; naming-only)

> Build ticket. **Naming-only — zero behavior change.** Companion to `build/tickets/contracts/CTR-15-reservoir-farmutility-rename.md`.
> The two MUST land in the **same release** — CTR-15 changes contract getter selectors this frontend calls.
>
> **SELF-EXCLUSION:** this ticket + CTR-15 are the rename SPEC — their old→new tables are excluded from the
> history sweep (a blanket sweep collapses "X → Y" into "Y → Y"). Old names below are the rename SOURCE.
> **STATUS 2026-06-20:** CTR-15 (monorepo) **APPLIED** on `rename/reservoir-to-farmutility`. **FE-09 APPLIED**
> on layer branch `merge-flow-and-function` (`resi-labs-ai/zipcode-finance-euler`): regenerated `registry.ts` +
> `lib/zipcode/abi/*.ts` via `gen-zipcode-abis.mjs` off the refreshed catalog (new keys `farmUtilityVault`/
> `farmUtilityEscrowVault`/`farmUtilityLpOracle`/`farmUtilityLoopModule`/`farmUtilityRouter`/`usdcReservoir`; old
> ABI `.ts` cleared); swept composables/components/store/pages/labels off the new keys; fixed the product slug
> `zipcode-reservoir`→`zipcode-farm-utility`. **Gate: `npm run build` GREEN** (nuxt build). `freeReservoir` (the
> idle `eePool.maxWithdraw` read in `ZcLiquidityGauge.vue`) LEFT verbatim — the row-29 carve-out. Binding proven
> live: `getZipcodeContract('szipUsd').read.name()` resolves the new address (`navEntry()` reverts `StalePrice`
> only because the fresh deploy has no CRE feeds — a state condition, not a binding fault). The 6 sibling FE
> tickets (FE-00/01/05/06/07/08) were swept `reservoir*`→`farmUtility*` in the monorepo (the work deferred in
> CTR-15). MUST deploy same-release as CTR-15.

## Context — why
The frontend is built against the OLD `reservoir*` vocabulary (~98 hits) and calls contract getters whose
**selectors CTR-15 renames** (`baseUsdcMarket()`→`usdcReservoir()`; the borrow-vault getter → `farmUtilityVault()`).
If CTR-15 merges without this, the FE reads break. Ground truth + rationale: see CTR-15 Context.

## Repo / commit target (read `build/harness.md` §3)
The layer `frontend/zipcode-finance-euler/` has its **own `.git`** (remote `resi-labs-ai`); the monorepo gitignores
it. The **ticket file** lives in the monorepo (here); the **built Vue/TS changes** commit to the **layer repo**.
Never stage layer code in the monorepo. Author Zipcode files in the LAYER, never inside the read-only `euler-lite`
submodule.

## How this ticket runs — discovery → confirm one-at-a-time → apply (MANDATORY)
**Phase A — Discovery (fan-out).** Sub-agent(s) grep `frontend/zipcode-finance-euler/` for all `reservoir*` /
`baseUsdcMarket` hits, and for each determine what it binds to (which contract getter / registry key) using the
CTR-15 confirmed names as the target. Fill the table below.
**Phase B — Confirm with the reviewer ONE ITEM AT A TIME** (what it is, the proposed name, the impact) before any
edit. Mark `status = confirmed: <final name>`.
**Phase C — Apply** confirmed rows + build gate.

## Classification (same rule as CTR-15)
The FE's `reservoir*` references are the **borrow/strike side** (the dashboard for the borrow vault) → map to
**`farmUtility*`**, NOT `usdcReservoir`. Verify each (an idle-store / `baseUsdcMarket` reference, if any, →
`usdcReservoir`).
- Registry keys: `reservoirBorrowVault`→`farmUtilityVault`, `reservoirEscrowVault`→`farmUtilityEscrowVault`,
  `reservoirLpOracle`→`farmUtilityLpOracle`.
- Composable methods/fields: `reservoirCash`/`reservoirBorrows`/`reservoirRateRay`/`reservoirRouter`→`farmUtility*`.
- The ABI registry must point at the CTR-15-regenerated artifacts; bind by address (unchanged); fix getter call
  names to the new selectors.

## Proposed changes (Phase A fills; Phase B confirms each row)
Discovery: 6 registry keys + their usages; ~13 hits total. The registry-key renames are pure JS string lookups
(safe). The bricking surface is the 4 getter call sites that call the renamed CTR-15 selectors.

| # | current key/method | file:line(s) | what it binds to | proposed name | bricking (getter-call)? | status |
|---|---|---|---|---|---|---|
| 1 | `reservoirBorrowVault` | `lib/zipcode/generated/registry.ts:172-175`; `composables/useZipLine.ts:30`; `useZipSolvency.ts:90,98,106,114,289` | the strike-loop borrow vault (IEVault) | `farmUtilityVault` | **YES** — useZipSolvency:90/98/106/114 call `.cash()/.totalBorrows()/.totalAssets()/.interestRate()` (must stay in sync with CTR-15 #5) | pending |
| 2 | `reservoirEscrowVault` | `lib/zipcode/generated/registry.ts:176-179` | strike LP escrow collateral vault | `farmUtilityEscrowVault` | no (registry def) | pending |
| 3 | `reservoirLpOracle` | `lib/zipcode/generated/registry.ts:100-103` | `SzipFarmUtilityLpOracle` (CRE-03 LP_MARK) | `farmUtilityLpOracle` | no (registry def) | pending |
| 4 | `reservoirRouter` | `lib/zipcode/generated/registry.ts:180-183` | strike-collateral EulerRouter | `farmUtilityRouter` | no | pending |
| 5 | `reservoirLoopModule` | `lib/zipcode/generated/registry.ts:108-111`; `composables/useZipActivity.ts:52` | `FarmUtilityLoopModule` (Borrowed/Repaid events) | `farmUtilityLoopModule` | no (address/abi only) | pending |
| 6 | `baseUsdcMarket` | `lib/zipcode/generated/registry.ts:168-171` | the idle-USDC store (IEVault) | `usdcReservoir` | no FE getter call found; safe (CTR-15 #1 renames the contract selector) | pending |
| 7 | ABI files + labels | `lib/zipcode/abi/{EulerVenueAdapter,FarmUtilityLoopModule,SzipFarmUtilityLpOracle}.ts`; `public/labels/8453/{products,earn-vaults}.json` | the regenerated CTR-15 ABIs + UI labels | follow #1-6 | n/a | pending |

**Addresses are unchanged** (renames are key/label only). The registry-key renames are safe; the only runtime
break would be if CTR-15's contract selectors changed without this landing — hence same-release.

## Bricking risks
- Getter-selector calls (`baseUsdcMarket()`/borrow-vault getter) MUST update to `usdcReservoir()`/`farmUtilityVault()`
  or reads revert → why same-release with CTR-15 is mandatory.
- Pure naming-only; no UX/behavior change.

## Gate / verification
`cd frontend/zipcode-finance-euler && <install per vercel.json>` then **`npm run build`** (nuxt build) green — NOT
`npm run dev` (EMFILE on macOS, harness §7). Plus `vue-tsc` typecheck if wired. Residual grep:
`grep -rniI "reservoir" frontend/zipcode-finance-euler --exclude-dir=node_modules --exclude-dir=euler-lite` → zero
or intentional.

## Done when
FE registry keys + composable methods renamed to `farmUtility*` (any idle-store ref → `usdcReservoir`); ABI registry
points at the regenerated artifacts; `npm run build` green; committed to the layer repo; coordinated to deploy with
CTR-15.
