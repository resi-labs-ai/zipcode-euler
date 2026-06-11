# FE-06 report — Solvency dashboard (§12) via direct on-chain view reads

**Window:** 2026-06-11 · **Track:** Frontend ↔ anvil · **Status:** DONE · **NEXT:** FE-07 (euler-native vault dashboard)

## What this window did
Built the protocol-level §12 solvency surface as **pure direct on-chain view reads** (no subgraph, MVP). Three layer
files, committed to the layer repo (`resi-labs-ai`, commit `f27302f`):
- `composables/useZipSolvency.ts` — raw-bigint protocol-solvency aggregator (FE-03 `useZipPosition` shape: proxy-client
  reads, `navEntry` the only try/caught read, 16-field `ZipSolvency` struct, derives `solvencyRatioBps` +
  `utilizationBps` with /0 guards, all-undefined when no client, never throws).
- `components/zipcode/ZcSolvencyPanel.vue` — `{refreshKey}`-only self-contained panel: five-metric `ZcStatCard` grid +
  two real protocol-vault rows rendered into `ZcVaultAllocationTable` internally; `provision` as a NAV sub-line; the
  three deferred metrics flagged from component constants.
- `pages/lender/portfolio.vue` — dropped the mock `protocol.aumUsdc` header card + mock `vaultRows`/table + dead
  imports; mounted `<ZcSolvencyPanel>`; kept the mock hero + FE-03 panel + transactions tab.

Gate: `npm run build` (`nuxt build`) green. Ticket: `build/tickets/frontend/FE-06-solvency-dashboard.md`.

## Metric → view bindings (all live-verified on the fork)
| §12 metric | Binding | Live value |
|---|---|---|
| Total protocol NAV | `reservoirBorrowVault.totalAssets()` = `cash` + `totalBorrows` | $8,000 ($2k cash + $6k borrows) |
| Senior AUM (allocation row, **not** in NAV) | `eePool.totalAssets()` | $9,000 |
| zipUSD minted + solvency ratio | `zipUsd.totalSupply()`; NAV/zipUSD | 2,000 zipUSD → **4.00×** (40000 bps) |
| Utilization / free liquidity | `borrows/totalAssets`; `cash` | **75%** / $2,000 |
| szipUSD NAV/share | `navExit`/`navEntry` (caught) + `spot`/`twap` | ≈$107.27 |
| loss provision (NAV sub-line) | `navOracle.provision()` | $0 |
| xALPHA insurance fund | `xAlpha.balanceOf(lienXAlphaEscrow.address)` | 0 |

## Decisions to sanity-check
1. **NAV = reservoir `totalAssets`, EE pool read separately as an allocation row (not summed).** Rationale: §12 ¶1's
   double-count rule — the EE pool supplies INTO the reservoir, so its claim already resolves to the reservoir's
   cash+borrows; summing would double-count. spec-fidelity critic confirmed faithful. Worth a glance if the intended
   headline NAV was meant to be the senior AUM ($9,000) instead of the reservoir total ($8,000) — I chose the literal
   §12 wording ("idle USDC + outstanding loan value" = reservoir cash + borrows).
2. **`provision()` is a NAV sub-line, NOT subtracted from senior NAV** (it is the junior markdown, borne via `navExit`,
   §11/§12). Currently $0 (no M1 default).
3. **Mounted on the auth-gated `pages/lender/portfolio.vue`** (FE-03/04/05 precedent). The frontend-binding critic
   flagged that protocol-solvency metrics are arguably public — I kept the precedent and left the panel route-agnostic
   so a later move to a public/dedicated route is a one-line remount. Deferred UX seam, not done this window.

## Holes → resolution (three back-pressure findings)
All three are **data-source-deferred off-fork, NOT contract-surface gaps** (no obligation owed) — rendered as an
explicit flagged state, never a fabricated number:
1. **zipUSD peg** → no zipUSD secondary AMM on the fork (post-Hydrex). Rendered `$1.0000` · "par · no fork AMM"
   (zipUSD mints 1:1 vs USDC). Resolves with the post-Hydrex pool.
2. **szipUSD trailing APR + Duration Bond premium APR** → xALPHA-APR CRE feed is **CRE-03, not built**; no NAV history
   on a fresh fork; no frozen position. Rendered "—" · "pending CRE feed (CRE-03)"; the real NAV/share reads show
   beside it. Resolves with CRE-03.
3. **off-chain insurance coverage** → CRE-published Proof-of-Insurance (§8.10), not built. Rendered "—" · "off-chain ·
   CRE §8.10"; the real xALPHA escrow fund shows beside it. Resolves with the §8.10 CRE feed.

## Doc edits
- `build/tickets/frontend/FE-06-solvency-dashboard.md` — filed (authored + hardened through the critic loop).
- `build/tickets/PROGRESS.md` — FE-06 → DONE; FE-07 → NEXT; the three back-pressure seams logged.
- **No `build/claude-zipcode.md` change** — spec-fidelity ALL PASS; §12 already correct (its "off-chain indexer"
  prose is the eventual production path; the MVP direct-read deviation is already recorded in PROGRESS "Subgraph —
  deferred", an intentional scoping, not a spec edit).

## Critic loop
- **spec-fidelity:** ALL PASS — five metrics faithful, NAV non-double-count correct, provision routed to junior, §17
  honored, no invention.
- **reference-verifier:** all 30+ bindings resolve; `navPerShare()` correctly absent; all registry keys present;
  found `euler-lite/utils/vault/apy.ts` as the rate→APY helper for the (unexercised, fork rate=0) non-zero branch.
- **frontend-binding:** back-pressure PASS — every real leg exists; the three deferred sources confirmed to have no
  fork view; UX placement flagged as a non-blocker.
- **junior-developer:** found real ticket-clarity gaps (no formal `ZipSolvency` interface, error-prone ratio math,
  vague flagged-state render, panel/page `vaultRows` ownership, provision placement, allocation-row apy, explicit
  `xAlpha.balanceOf(escrowAddr)`) — all triaged as **ticket gaps** and fixed in-ticket (no spec edit, no contract
  obligation). The junior's arithmetic objection to the ratio formula was itself a miscalculation; the formula is
  correct (40000 bps) and now carries a worked unit comment.
- **cold-build:** ZERO load-bearing guesses; `npm run build` green; live `cast` checks match the ticket values.

## Status + NEXT
FE-06 done + committed (gate green). **NEXT = FE-07** (euler-native vault dashboard — surface the real reservoir EVK
market + senior EE pool through euler-lite's own lend/borrow/earn pages; largely FE-00 config + local labels). FE-07
is the last FE↔anvil item; after it the CRE track (CRE-00…) is the remaining work. **STOP for review.**
