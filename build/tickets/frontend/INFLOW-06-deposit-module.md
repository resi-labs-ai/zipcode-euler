# INFLOW-06 — `ZipDepositModule` frontend interface (the supply/zap UX) (§4.5)

> **RE-AUTHORED 2026-06-07 to the two-token / Exit-Gate model** (matches the re-authored WOOF-06). **szipUSD is now a
> transferable ERC20 share** (18-dp) that the **Exit Gate** mints to the user — **NOT raw Baal Loot** (the soulbound
> Loot stays inside the Gate; the user never holds it). The zap's stake leg is
> **`Gate.depositFor(zipUSD, zipAmount, user)`** → **NAV-proportional** szipUSD (priced via `SzipNavOracle`); the
> contract returns / events emit **`shares`** (szipUSD), not `loot`. The euler-lite modeling below is unchanged +
> still verified; only the share semantics + the preview tuple + the wired-target name are aligned to WOOF-06's
> current ABI. **Build dependency:** the Gate's `depositFor`/`previewDeposit` is item 8's obligation (mocked + pinned
> by WOOF-06).

**Deliverable**
The Inflow (Vue) wiring for the supply side: a **Supply** view whose **default action is the `zap`** (USDC →
szipUSD, the headline junior **share**), with **plain `deposit`** (USDC → raw zipUSD, the $1 utility token) as the
secondary mode. Modeled on the euler-lite earn/supply flow. Plus the ABI fragment + address config + composable the
view needs. This is the **interface half** of PROGRESS item 7; it **back-pressures** the build ticket
(`tickets/woof/WOOF-06-deposit-module.md`) — it demands the events + preview views the frontend cannot work without.

(Inflow is rebuilding in Vue and converging on **euler-lite** — `reference/euler-lite` is a Nuxt 3 / Vue 3 app on
**viem + wagmi-vue + @tanstack/vue-query**, verified. This ticket names the **real** euler-lite files to model.)

**Spec §**
`reports/baal-spec.md` §4 (`ZipDepositModule` — `deposit`/`zap`, value-1:1 18-dp zipUSD, the on-behalf **szipUSD** deposit via
the Gate's `depositFor`, NAV-proportional) + §5 (the Exit Gate) + §3 (`SzipNavOracle` — the NAV/share the position is
valued at) + §6 (the two exits the position links to). The contract surface it wires is **WOOF-06**'s public ABI
(re-authored).

**Back-pressure on the build ticket (WOOF-06) — required contract surface (CONFIRM present):**
1. **Events:**
   - `Deposited(address indexed user, uint256 usdcIn, uint256 zipMinted)` — present. ✓
   - `Zapped(address indexed user, uint256 usdcIn, uint256 zipMinted, uint256 shares)` — present (the 4th field is
     the **szipUSD shares** minted to the user, NAV-proportional). ✓ **(was `loot` — now `shares`.)**
2. **Preview views** (euler-lite always shows expected output in the supply form — `VaultFormInfoBlock.vue`):
   - `previewDeposit(uint256 usdcIn) view returns (uint256 zipMinted)` — present. ✓
   - `previewZap(uint256 usdcIn) view returns (uint256 zipMinted, uint256 shares)` — present. ✓ This forces the Gate
     (item 8) to expose **`previewDeposit(address asset, uint256 amount) view returns (uint256 shares)`** — without
     it the zap UI cannot quote the user's szipUSD. The `shares` figure is an **estimate** (NAV moves between quote
     and tx; the §3 `max(spot,twap)` entry bracket) — **label "≈".**
3. **Decimals contract:** the UI MUST treat **USDC as 6-dp**, **zipUSD as 18-dp**, and **szipUSD as 18-dp** (a normal
   transferable ERC20 share the Gate mints). `zipMinted = usdcIn * scaleUp` (`scaleUp() == 1e12` on-chain source of
   truth). The UI reads token `decimals()` and formats accordingly — **never** assume zipUSD ≈ USDC raw, and **never
   assume szipUSD ≈ zipUSD** (1 szipUSD ≠ 1 zipUSD — it is a NAV-priced share; the szipUSD amount is
   `zipMinted / navPerShare`, surfaced by `previewZap`).
4. **NAV/share (NET-NEW display input):** szipUSD is a **share whose value drifts with NAV**. To show the user the
   **$ value** of their szipUSD position (and the live "≈ X szipUSD per $1"), the UI reads **`navPerShare` from
   `SzipNavOracle`** (item 8 / §3) — a `view` returning the bracketed share price (18-dp). Until the oracle/Gate are
   wired, fall back to the `previewZap` quote only (no standalone position-value line). **Back-pressure:** item 8
   must expose a public `navPerShare()`-style view (pin it as the szipUSD-position obligation, owed by the Gate/oracle
   — the supply form needs it to value the headline position).
5. **No SDK coverage:** `ZipDepositModule` is net-new (not in `@eulerxyz/euler-v2-sdk`), so the UI calls the module
   **directly** — a hand-rolled `useZipDeposit` composable using `encodeFunctionData` + `@wagmi/vue`
   `sendTransactionAsync` (NOT viem `writeContract`, which the codebase does not use). Model the *form/UX/tx-tracking*
   patterns from euler-lite.

**Model from (verified against `reference/euler-lite` + `reference/euler-interfaces`)**
- **Stack:** Nuxt 3 (3.21) / Vue 3 (3.5), **viem 2.48** + **wagmi 3.6** + **@wagmi/vue 0.5** + **@tanstack/vue-query**,
  Tailwind, `@reown/appkit`. (`reference/euler-lite/package.json`.)
- **Supply form page to model:** `reference/euler-lite/pages/earn/[vault]/index.vue` — amount input
  (`v-model="amount"`), `submit()` (`:122`), the review-modal handoff (`:151-162`), the decimals discipline
  (`valueToNano(amount, asset.decimals)`, `:94/:102/:135`). **Model the layout + amount/approve/submit/review
  structure** — but NOT the data path; swap the SDK `planDeposit`/`executePlan` for the direct module writes below.
  **The existing `VaultFormInfoBlock.vue` is only a styled card shell** (shows Supply APY, NOT expected output), so
  the zipUSD/szipUSD **expected-output element is NET-NEW** (driven by `previewDeposit`/`previewZap`); reuse
  `VaultFormInfoBlock` only as the card chrome.
- **Tx submit + tracking — the codebase's REAL write primitive:** euler-lite does **not** use viem `writeContract`.
  Its write path is **`@wagmi/vue` `useSendTransaction()` → `sendTransactionAsync({ to, data })`** where
  `data = encodeFunctionData({ abi, functionName, args })` (`composables/useEulerTx.ts:411, 1023-1041`;
  `OperationReviewModal.vue:232`). Model `useZipDeposit` on that. Toasts: `components/ui/composables/useToast.ts`.
  Modal: `components/ui/composables/useModal.ts`. **Review modal — do NOT reuse `OperationReviewModal` as-is:** it is
  SDK-plan-coupled (needs an SDK `plan`, disables Confirm unless `reviewPlan.length`, `:308`; `type` union has no
  `zap`, `:25`). **Fork a small plan-free review variant** (props: amount, mode, previewed zipUSD/szipUSD, `onConfirm`)
  modeled on its layout, or confirm inline. `useModal`/`useToast` ARE reusable.
- **ABI storage pattern:** `reference/euler-lite/abis/*.ts` — small viem `as const` fragment exports. Add
  `reference/euler-lite/abis/zipDepositModule.ts` exporting `deposit(usdcIn)`/`zap(usdcIn)`/`previewDeposit`/
  `previewZap`/`scaleUp`/**`gate`**/`warehouse` + the `Deposited` and `Zapped` (4th field **`shares`**) events.
  **`erc20.ts` has no `allowance` fragment** — add an `erc20AllowanceAbi` fragment (the two-step approve gate needs
  `allowance(owner,spender)`).
- **Address config pattern:** add a small per-chain config for `zipDepositModule` (+ `zipUSD`, `szipUSD`, `usdc`,
  `eePool`, **`navOracle`**) alongside `reference/euler-lite/composables/useEulerAddresses.ts` (a new
  `useZipcodeAddresses.ts` chain→addresses map seeded from config; mirror euler-interfaces' `addresses/{chainId}/*.json`).
- **euler-interfaces slot:** add `reference/euler-interfaces/interfaces/IZipDepositModule.sol` + the compiled
  `ZipDepositModule.json` alongside `IEulerEarn.sol`/`EulerEarn.json`.

**Key requirements (the UI behavior)**
- **A Supply view** with: an **amount** input (USDC, 6-dp), a wallet **USDC balance** read + "max", and a **mode
  toggle** — **"Stake (zap)"** [default, lands in szipUSD] vs **"Hold zipUSD"** [plain deposit]. Default = the **zap**.
- **Two-step tx (approve → action):** read `USDC.allowance(user, module)` via a **direct `readContract`** (NOT the
  SDK `fetchSingleBalance`); if `< amount`, first `encodeFunctionData` + `sendTransactionAsync` a
  `USDC.approve(module, amount)` (or unlimited — surface the choice), then `module.zap(amount)` **or**
  `module.deposit(amount)` per mode. Track each tx with `useToast` + the forked review modal; refresh balances on
  confirm via direct `readContract`.
- **Expected-output preview (the NET-NEW element):** on amount change, call **`previewZap(amount)`** (zap mode →
  "You receive ≈ `shares` szipUSD" + "mints `zipMinted` zipUSD into the vault") or **`previewDeposit(amount)`** (hold
  mode → "You receive ≈ `zipMinted` zipUSD"), via direct `readContract`. Format with the tokens' real `decimals()`
  (USDC 6, zipUSD 18, szipUSD 18) — **never** assume zipUSD≈USDC or szipUSD≈zipUSD. Debounce like the page's
  `updateEstimates` (`pages/earn/[vault]/index.vue:224-227`). (`previewZap`'s `shares` is an estimate — label "≈".)
- **Position value (NET-NEW, optional until oracle wired):** when `navOracle` is available, show the user's szipUSD
  **$ value** = `szipUSD.balanceOf(user) * navPerShare()` (both 18-dp) and a "≈ N szipUSD / $1" hint. Gate this behind
  an oracle-available check; until then show only the `previewZap` quote.
- **Un-wired guard:** if `module.gate() == address(0)` (Gate not yet wired — pre-item-8 deploy), **disable the zap
  mode** and show "staking not yet available; hold zipUSD" — `previewZap`/`zap` revert `NotWired` and must not be
  offered. (Plain `deposit` stays available.)
- **Result surfacing:** on success show the realized position — for a zap, the **szipUSD balance delta** (a normal
  ERC20 balance) + a link to the junior position view (the szipUSD **window-redeem / CoW-sell** exits — §6 — are
  item 8's Baal interface backlog; cross-link when authored). For a deposit, the zipUSD balance.
- **A `useZipDeposit.ts` composable** wrapping: **direct `readContract`** (the app's `getPublicClient(...).readContract`
  pattern, `composables/useSpyMode.ts:53`, `utils/multicall.ts`) for the previews + `gate`/`scaleUp` + USDC
  balance/allowance + szipUSD balance + (optional) `navPerShare`; and **`encodeFunctionData` + `@wagmi/vue`
  `useSendTransaction().sendTransactionAsync`** for `approve`/`deposit`/`zap`. Do **not** route through the Euler SDK
  and do **not** use viem `writeContract`.
- **The ABI fragment + address config + euler-interfaces interface/JSON** files named above.

**Done when**
- The Supply view renders, reads USDC balance/allowance (direct `readContract`), previews the expected zipUSD /
  szipUSD-shares via `previewDeposit`/`previewZap`, and submits the approve→`zap`/`deposit` sequence via
  `encodeFunctionData` + `@wagmi/vue` `useSendTransaction().sendTransactionAsync` (NOT viem `writeContract`), with
  toasts + the forked plan-free review modal + post-tx balance refresh — modeling the named euler-lite files.
- The `zap` default vs `deposit` toggle works; the un-wired (`gate == 0`) guard disables zap.
- Decimals handled by reading token `decimals()` (USDC 6 / zipUSD 18 / **szipUSD 18, NAV-priced**) — no hard-coded
  scale; `zipMinted = usdcIn * scaleUp()`; the szipUSD amount comes from `previewZap` (NOT assumed equal to zipUSD).
- The `abis/zipDepositModule.ts` fragment (with the `shares` Zapped field + `gate` getter), the `useZipcodeAddresses`
  config (incl. `navOracle`), the `useZipDeposit` composable, and the `euler-interfaces` `IZipDepositModule.sol` +
  `ZipDepositModule.json` exist and are wired.
- **Back-pressure satisfied:** confirmed WOOF-06 exposes `Deposited`/`Zapped(…shares)` + `previewDeposit`/`previewZap`
  + `scaleUp`/`gate`; and the Gate/oracle obligation for `previewDeposit(asset,amount)→shares` + `navPerShare()` is
  pinned. If any were missing, that is a build-ticket gap to file first.

**Depends on**
WOOF-06 (the contract surface — re-authored). The szipUSD junior position / **window-redeem + CoW-sell** view is part
of item 8's Baal interface backlog — cross-link when authored. The Gate's `depositFor`/`previewDeposit` + the
`SzipNavOracle` `navPerShare` are item-8 obligations (mocked + pinned by WOOF-06). The address config depends on
item 10 (deploy) for real addresses (+ the `CreditWarehouse` Safe + the Gate + the oracle); until then it reads a
placeholder/local config.
