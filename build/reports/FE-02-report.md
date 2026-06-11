# FE-02 report — Supply/zap real-write path + shared gas-buffer helper

**Window:** 2026-06-10 · **Track:** Frontend ↔ anvil · **Spec §:** §4.5 (= INFLOW-06, realized) · **Status:** DONE

## What the window did
Swapped the **mock** lender supply path for **real writes** against the live anvil `ZipDepositModule`, and shipped
the shared write spine every later Zipcode write inherits.

Built (committed to the **layer repo** `resi-labs-ai`, commit `933c144`):
- `composables/useZipTx.ts` — the shared **1.3× gas-buffer write helper**. Pinned signature
  `sendZipTx({ key, functionName, args, value? }) → { hash, receipt }`. Estimates gas off the browser proxy client,
  applies `gas = max(ceil(est*1.3), est+150_000)` (exact bigint, round-up), sends via `@wagmi/vue`
  `sendTransactionAsync({ to, data, value, gas })`, awaits the receipt internally. **Discharges the standing EVC
  gas-buffer obligation.**
- `composables/useZipDeposit.ts` — supply reads (`previewDeposit`/`previewZap`/`gate`/`scaleUp`/USDC
  balance+allowance/szipUSD balance/`navEntry`) through `useRpcClient().client` (null-guarded), + `approve`/`zap`/
  `deposit` writes via `useZipTx`. `ensureAllowance` does the two-step approve gate.
- `components/zipcode/ZcDepositModal.vue` — mode toggle (Stake/zap default → szipUSD vs Hold zipUSD), debounced live
  preview, USDC balance + max, wallet-gate button, `gate()==0` un-wired guard (disables zap), two-phase
  approve→action loading labels, szipUSD balance-delta surfacing, toasts.
- `pages/lender/portfolio.vue` — dropped the localStorage `handleDeposit`; on the modal's `@success` re-reads on-chain
  USDC + szipUSD via the proxy client and surfaces them. Withdraw path left mock (FE-04).

**Gate:** `npm run build` (`nuxt build`) green. Cold-build (fresh subagent, ticket-only) returned **zero load-bearing
guesses**. No back-pressure — every UI surface exists on the deployed module.

## Decisions to sanity-check
- **Gas buffer = `max(ceil(est*1.3), est+150_000)`.** Reads the PROGRESS "~1.3× (or +150k)" as a per-tx floor of
  +150k headroom OR 30%, whichever is larger. Applied to the *outer* module call — `estimateGas` covers the internal
  EVC gas, so the buffer is for block-to-block state drift (NAV/allowance/storage warmth), not unmetered internal
  calls (frontend-binding critic confirmed the reasoning).
- **NAV view = `navEntry()`**, not `navPerShare()` (absent/reverts — FE-01 seam). FE-02 only uses it for the optional
  issuance-side hint; the full position $-value view is FE-03 (which should value a *held* position at `navExit` per
  §7, not `navEntry`).
- **Page boundary:** the modal owns the writes; the page re-reads on-chain balances on `@success`. The mock
  `store.ts` stays for the still-unwired borrower/other screens — only the lender supply path is un-mocked.
- **Exact-amount approve** (no unlimited toggle) for the MVP.
- **Max button** fills the input via `formatUnits(bal,6)` then re-parses through `parseUsdcInput` (2-dp truncation,
  matching the input step) → a max slightly under the true wei balance. Safe (never over-spends); a power user wanting
  the exact wei balance is not served — acceptable for the demo.

## Holes → resolution
- **`useToast` is not auto-imported** (it lives outside euler-lite's registered composable dirs) → resolved: explicit
  `import { useToast } from '~/components/ui/composables/useToast'`. The other composables (`useWagmi`/`useRpcClient`/
  `useDebounceFn`) auto-import. Logged in the ticket's Resolved-decisions block.
- **`useZipTx` had two candidate signatures in the draft** → resolved to one pinned shape (the `{key,...}` form, returns
  `{hash, receipt}`), since FE-04/FE-05 inherit it.
- **`nuxt build` does not type-check `.vue` files** (no `typescript.typeCheck` set) — the green build is a compile/bundle
  gate, not a type gate. Verified the new code is type-correct by direct read (toast `description` key is real, viem
  `readContract`/`estimateGas`/`waitForTransactionReceipt` signatures match). A future FE ticket could enable
  `vue-tsc` in CI; not blocking.

## Doc edits
- `build/tickets/PROGRESS.md`: FE-02 → done; **FE-03 set NEXT**; EVC gas-buffer obligation marked **DISCHARGED** with
  the `useZipTx` pointer + the "route all writes through it" seam.
- No `build/claude-zipcode.md` change — critics found **no spec gap** (the mechanism is fully defined in §4.5; all
  findings were ticket-clarity or binding-precision, fixed in the ticket).

## Status + NEXT
- **FE-02 DONE**, gate green, committed to the layer repo. EVC gas-buffer obligation discharged.
- **NEXT: FE-03** — Position / NAV view (szipUSD + zipUSD balances + $ value via `navEntry`/`navExit`, NOT
  `navPerShare`). Binds `SzipNavOracle` `0x0C3E…` + `szipUsd` + `zipUsd` via the FE-01 registry; reuses the FE-02 read
  patterns.
