# FE-02 — Supply/zap: wire `ZcDepositModal` → real `useZipDeposit` + shared 1.3× gas-buffer tx helper (§4.5)

> **Realizes INFLOW-06 against the live anvil board.** INFLOW-06 (`build/tickets/frontend/INFLOW-06-deposit-module.md`)
> is the design draft (form/UX/tx-tracking patterns, back-pressure list). This ticket binds that draft to the
> **deployed** `ZipDepositModule` ABI + the FE-01 address book, in the `zipcode-finance-euler` LAYER. Where INFLOW-06
> and the deployed contract disagree, the **contract wins** (harness §1): the deployed module exposes
> `previewZap`/`previewDeposit`/`zap`/`deposit`/`scaleUp`/`gate` exactly as INFLOW-06 demanded (back-pressure
> discharged — see Binding), and the NAV view is `navEntry`/`navExit`, NOT `navPerShare` (FE-01 seam).

## Deliverable
Swap the **mock** deposit path of the lender supply UX for **real writes** against the anvil contracts. The
`ZcDepositModal` (`components/zipcode/ZcDepositModal.vue`) gains a **mode toggle** — **"Stake (zap)"** [default →
szipUSD] vs **"Hold zipUSD"** [plain deposit] — an **expected-output preview** (`previewZap`/`previewDeposit`), a
two-step **approve → zap/deposit** flow, and a USDC balance read. All reads go through the FE-01 registry + the
browser proxy client; all writes go through a **net-new shared `useZipTx` gas-buffer tx helper** that every later
Zipcode write (FE-04/FE-05) reuses.

Ship three layer files:
1. `composables/useZipTx.ts` — the shared **1.3× gas-buffer** write helper (the EVC headroom obligation).
2. `composables/useZipDeposit.ts` — reads (preview/gate/scaleUp/USDC balance+allowance/szipUSD balance) + writes
   (approve/zap/deposit) for the supply UX, built on `useZipTx`.
3. the wired `ZcDepositModal.vue` (mode toggle + preview + approve→action), and the `pages/lender/portfolio.vue`
   handler swapped from the mock store mutation to a real on-confirm balance refresh.

## Spec §
`build/claude-zipcode.md` §4.5 (supply-side: `ZipDepositModule` — `deposit` mints zipUSD 1:1 value via
`scaleUp = 1e12`; `zap` = deposit→stake in one tx, lands the user in **NAV-proportional szipUSD** minted by the Exit
Gate; USDC goes to work in the warehouse, the module holds no shares). = INFLOW-06 (§4.5), realized against anvil.

## Binds to (verified against the deployed ABIs + the FE-01 registry)
All via the **FE-01 module** (`lib/zipcode/contracts.ts` → `ZIPCODE_CONTRACTS[key] = { address, abi }`). Confirmed
present in `build/anvil/abi/` + `lib/zipcode/generated/registry.ts`:

- **`depositModule`** = `0x6ecc717266e6FE8d7Ad7608219c30b736eEB728a` (`ZipDepositModule`). Real ABI surface (CONFIRMED
  against `build/anvil/abi/ZipDepositModule.json` — back-pressure check PASSES):
  - `deposit(uint256 usdcIn) → (uint256 zipMinted)` (nonpayable)
  - `zap(uint256 usdcIn) → (uint256 shares)` (nonpayable)
  - `previewDeposit(uint256 usdcIn) view → (uint256 zipMinted)`
  - `previewZap(uint256 usdcIn) view → (uint256 zipMinted, uint256 shares)`
  - `scaleUp() view → (uint256)` (== `1e12` on-chain)
  - `gate() view → (address)` — the un-wired guard (zap reverts `NotWired` if `gate() == address(0)`)
  - events `Deposited(address indexed user, uint256 usdcIn, uint256 zipMinted)` and
    `Zapped(address indexed user, uint256 usdcIn, uint256 zipMinted, uint256 shares)` — the 4th `Zapped` field is the
    **szipUSD shares** minted to the user, NAV-proportional.
- **`usdc`** = `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (`abi: ERC20` in the registry; CONFIRMED the ERC20 fragment
  carries `allowance(owner,spender)`, `approve(spender,amount)`, `balanceOf(account)`, `decimals()`). USDC is **6-dp**.
- **`zipUsd`** = `0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF` (`ESynth`) — **18-dp** utility dollar.
- **`szipUsd`** = `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` (`SzipUSD`) — **18-dp** NAV-priced share; read
  `balanceOf(user)` for the post-zap delta.
- **`navOracle`** = `0x0C3E77314D97e8e001e0F626A559992479A3C79e` (`SzipNavOracle`). **NO `navPerShare()`** (FE-01 seam).
  The position-value line (optional, see Key requirements) reads **`navEntry() view → uint256`** (issuance price,
  18-dp; ≈ `1.07e20` live). Do NOT bind `navPerShare` — it reverts.

**Read vs write paths (FE-01 seam — load-bearing):**
- **Reads** (previews, `gate`, `scaleUp`, balances, allowance, `navEntry`) MUST use the **browser proxy client**:
  `const { client } = useRpcClient()` → pass `client.value` into a viem `readContract`/`getContract` call. The FE-01
  `getZipcodeContract(key)` **default inline client is node/SSR-only** (direct `127.0.0.1:8545` → CORS-fails in the
  browser). Either call `getZipcodeContract(key, client.value as PublicClient)` or read directly with
  `client.value.readContract({ ...ZIPCODE_CONTRACTS[key], functionName, args })`.
- **Writes** (`approve`, `zap`, `deposit`) use the raw registry entry + the app's real write primitive:
  `@wagmi/vue` `useSendTransaction().sendTransactionAsync({ to, data })` where
  `data = encodeFunctionData({ abi: ZIPCODE_CONTRACTS[key].abi, functionName, args })`. **NOT** viem `writeContract`
  (the codebase does not use it — see `euler-lite/composables/useEulerTx.ts:1023-1041`).

**Model from (verified euler-lite files):**
- write primitive — `euler-lite/composables/useEulerTx.ts:411` (`const { sendTransactionAsync } = useSendTransaction()`)
  + `:1025-1039` (`send({ to, data, value })` → `sendTransactionAsync({ to, data, value: value ?? 0n })`).
- connected account — `euler-lite/composables/useWagmi.ts:100,127-132,202` (`useWagmi()` → `address`, `isConnected`,
  `connect()`). Gate the action behind `isConnected`; offer `connect()` when not.
- browser read client — `euler-lite/composables/useRpcClient/index.ts` (`useRpcClient().client` → same-origin
  `/api/rpc/8453` proxy `PublicClient`).
- toasts — `euler-lite/components/ui/composables/useToast.ts` (`useToast()` → `success`/`error`/`info`).
- the existing modal `components/zipcode/ZcDepositModal.vue` (steps `input`/`confirm`/`loading`/`success`) and its
  consumer `pages/lender/portfolio.vue:116-120,187-204` (the mock `handleDeposit` to replace).

## Starting state
- `ZcDepositModal.vue` is a **mock**: `handleSubmit` does `setTimeout(…1600)` then emits `deposit` with a USDC string;
  `pages/lender/portfolio.vue:handleDeposit` mutates the `lib/zipcode/store.ts` localStorage state. No chain calls.
- FE-01 shipped `lib/zipcode/contracts.ts` + the typed registry (the single import). FE-00 booted the layer on the
  fork (RPC proxy `/api/rpc/8453` returns chainId `0x2105`).
- No `useZipTx`/`useZipDeposit` composables exist yet.

## Do NOT
- Do **not** use viem `writeContract` or route through the Euler SDK (`planDeposit`/`executePlan`). Direct module
  writes only — `ZipDepositModule` is net-new, not in `@eulerxyz/euler-v2-sdk`.
- Do **not** read on-chain state through the FE-01 **default** inline client from a browser screen (CORS). Pass
  `useRpcClient().client`.
- Do **not** bind `navPerShare()` (absent — reverts). Use `navEntry()`.
- Do **not** assume zipUSD ≈ USDC raw or szipUSD ≈ zipUSD. Format each token by its real `decimals()` (USDC 6, zipUSD
  18, szipUSD 18); the szipUSD amount is `previewZap`'s `shares`, NOT `zipMinted`.
- Do **not** bake the gas buffer per-call. It lives **once** in `useZipTx` so every Zipcode write inherits it.
- Do **not** stage the built Vue/composables in the monorepo — they commit to the **layer repo** (`resi-labs-ai`).
  Only this ticket file lands in `build/tickets/frontend/`.

## Key requirements
1. **`useZipTx` — the shared gas-buffer write helper (discharges the EVC obligation).** Expose **exactly one**
   signature (do not offer a `{to,data}` variant — FE-04/FE-05 inherit this spine, so pin it):
   `sendZipTx({ key, functionName, args, value? }): Promise<` `{ hash, receipt }` `>` where `key: ZipcodeContractKey`,
   `args` matches the registry ABI's function. It:
   - builds `data = encodeFunctionData({ abi: ZIPCODE_CONTRACTS[key].abi, functionName, args })` and `to =
     ZIPCODE_CONTRACTS[key].address`,
   - **estimates gas** via the proxy client (`const { client } = useRpcClient()`; throw if `client.value` is null) →
     `client.value.estimateGas({ account, to, data, value })` with `account = useWagmi().address` (throw "Wallet not
     connected" if absent — `account` is required because the call is balance/allowance-dependent),
   - applies the buffer with this **exact bigint formula** (round-up, no float):
     `const buffered = (est * 13n + 9n) / 10n; const gas = buffered > est + 150_000n ? buffered : est + 150_000n`
     (i.e. `gas = max(ceil(est*1.3), est+150_000)`),
   - sends via `useSendTransaction().sendTransactionAsync({ to, data, value: value ?? 0n, gas })`,
   - **awaits the receipt inside the helper** (`await client.value.waitForTransactionReceipt({ hash })`) and returns
     `{ hash, receipt }`. (If estimate reverts/throws, propagate the error — never send unbuffered.)
   This helper is the standing **EVC 1.3× gas buffer** obligation (PROGRESS "Open obligations") — discharge it here.
2. **`useZipDeposit` — supply reads + writes.** Wraps:
   - **reads** (proxy client): `previewDeposit(usdcIn)`, `previewZap(usdcIn)`, `gate()`, `scaleUp()`,
     `usdc.balanceOf(user)`, `usdc.allowance(user, depositModule)`, `szipUsd.balanceOf(user)`, and (optional)
     `navOracle.navEntry()`. All keyed off the FE-01 registry.
   - **writes** (via `useZipTx`): `approve` = `usdc.approve(depositModuleAddr, amount)`; `zap(usdcIn)`;
     `deposit(usdcIn)`.
   - **two-step gate:** read `allowance`; if `< amount`, send `approve` first (offer exact-amount; unlimited optional),
     await receipt, then send the action. Refresh balances/allowance after each confirmed tx.
3. **Mode toggle.** `ZcDepositModal` gets **"Stake (zap)"** (default) vs **"Hold zipUSD"**. Default action = `zap`.
4. **Expected-output preview (NET-NEW).** On amount change (debounced), zap mode → `previewZap` → "You receive ≈
   `shares` szipUSD" + "mints `zipMinted` zipUSD into the vault"; hold mode → `previewDeposit` → "You receive ≈
   `zipMinted` zipUSD". Label szipUSD with **≈** (NAV drifts between quote and tx). Format with real decimals.
5. **Un-wired guard.** If `gate() == address(0)`, **disable the zap mode** ("staking not yet available; hold zipUSD")
   and keep `deposit` available — `previewZap`/`zap` revert `NotWired`. (On the current anvil board the gate IS wired;
   the guard is defensive + correct for a pre-wire redeploy.)
6. **USDC balance + max.** Read `usdc.balanceOf(user)`, show it, wire a "max" that fills the input. Block submit if
   amount > balance (the module reverts `InsufficientBalance` otherwise).
7. **Result surfacing.** On success: zap → show the **szipUSD balance delta** (re-read `szipUsd.balanceOf`); deposit →
   the zipUSD figure (`zipMinted`). Toast each tx (`useToast`). Keep the modal's `loading`/`success` steps but drive
   them off the real tx lifecycle (pending on send, success on receipt, error toast on revert).
8. **Wallet gate.** If not `useWagmi().isConnected`, the modal's primary button is "Connect wallet" → `connect()`.

## Resolved decisions (close these — no builder guess)
- **Auto-import exceptions.** `useWagmi`, `useRpcClient`, `useEulerTx`, and `useDebounceFn` (`@vueuse/nuxt`) ARE
  auto-imported in the layer (`extends: ['./euler-lite']`). **`useToast` is NOT** — add the explicit import
  `import { useToast } from '~/components/ui/composables/useToast'` (every euler-lite consumer does, e.g.
  `composables/useSwapPageLogic.ts:15`). Composables you author in the layer's own `composables/` are auto-imported.
- **Read shape.** Model proxy-client reads on `euler-lite/composables/useCustomTokenResolver.ts:30-44`:
  `const { client } = useRpcClient()` then `client.value!.readContract({ ...ZIPCODE_CONTRACTS[key], functionName,
  args })`. **Guard `client.value` for null** (it is null until chainId resolves — `useRpcClient/index.ts:6`); skip the
  read (return undefined) rather than cast-and-crash. A multi-return view (`previewZap`) comes back as a **tuple array**
  `[zipMinted, shares]` — index `[1]` for the szipUSD `shares` (the warned-about value).
- **Decimals/formatting.** Use viem `formatUnits(value, decimals)` / `parseUnits` for the 18-dp tokens (zipUSD/szipUSD);
  keep the store's `parseUsdcInput`/`formatUsdc` for the 6-dp USDC input/display. Do not invent a new 18-dp store
  helper. Read each token's `decimals()` once (or trust the known 6/18/18) — never hard-scale.
- **Debounce.** Wrap the preview read in `useDebounceFn(fn, 300)` (VueUse, auto-imported), modeled on
  `euler-lite/composables/position/useCollateralForm.ts:418`.
- **szipUSD delta.** Snapshot `szipUsd.balanceOf(user)` **before** sending the zap; after the receipt re-read and show
  `after - before` (formatted 18-dp). For a plain deposit, surface `zipMinted` from the `Deposited`/`previewDeposit`.
- **Approve scope.** MVP = **exact-amount approve** (`approve(depositModule, amount)`). No unlimited-approve toggle this
  ticket (keep the surface simple; revisit if UX demands).
- **Modal step semantics.** Keep `input`/`loading`/`success`; the `input` step now carries the **mode toggle + live
  preview + USDC balance/max + wallet-gate button**. Drop the mock `confirm` copy ("USDC Warehouse Vault…"); a brief
  confirm step is optional. The `loading` step must distinguish the **two on-chain phases** — label "Approving USDC…"
  during the approve tx, "Staking…"/"Depositing…" during the action tx (drive off `useZipDeposit`'s phase state).
- **Modal ↔ page boundary.** The **modal owns the writes** (via `useZipDeposit`). After a confirmed tx it emits a
  `success` event (no amount payload needed); `pages/lender/portfolio.vue` drops the localStorage-mutating
  `handleDeposit` and instead, on `@success`, re-reads the on-chain balances it displays (USDC + szipUSD via the proxy
  client) — the page's hero numbers come from chain, not the mock store. (The mock `store.ts` stays for the as-yet-
  unwired borrower/other screens; this ticket only un-mocks the lender supply path.)
- **`navPerShare` adjacent trap.** The oracle also exposes `spotNavPerShare()`/`twapNavPerShare()` — do NOT reach for
  those either; the position-value read (optional, FE-03 owns the full view) is `navEntry()`.

## Done when
- `npm run build` (`nuxt build`) is **green** in `frontend/zipcode-finance-euler/` (the gate — NOT `npm run dev`).
- `useZipTx` + `useZipDeposit` exist; the modal mode-toggle + preview + approve→zap/deposit flow is wired; the
  `portfolio.vue` mock `handleDeposit` is replaced by a real on-confirm refresh.
- A cold-build subagent building from this ticket alone returns **zero load-bearing guesses** (every import, address,
  ABI method, and read/write path resolves to a cited file/symbol).
- **Acceptance (anvil up, signer-supplied `NUXT_PUBLIC_APP_KIT_PROJECT_ID`):** the modal reads the connected USDC
  balance, previews `previewZap`/`previewDeposit`, and performs a real `approve → zap` (or `deposit`) on the fork; the
  gas-buffer helper applies the 1.3× headroom. (If no project id is available for click-connect, the gate is the green
  `nuxt build` + the cold-build zero-guess verdict; the live approve→zap is the signer-supplied extension.)
- Committed to the **layer repo** (`resi-labs-ai`). The **EVC 1.3× gas-buffer obligation is DISCHARGED** (shared
  `useZipTx`) — mark it in PROGRESS.

## Depends on
FE-00 (layer boots on fork — DONE), FE-01 (address book + typed ABIs — DONE). The szipUSD position/NAV **view** is
FE-03; the szipUSD **exits** (CoW-sell / window-redeem) are FE-04 — cross-link the result surface when authored.
