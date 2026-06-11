# FE-05 — Borrower flow: read the per-line credit state + the permissionless repay; `ZcDrawModal` read-only, `ZcRepayModal` real (§4 / §15)

> Replaces the mock borrower path (`ZcDrawModal`/`ZcRepayModal` → `store.ts` mutations) with **real reads of the
> on-chain line state + the permissionless repay as the contracts actually implement it.** **Back-pressure check done —
> it shaped this ticket (per §17 + the deployed ABIs, the contract wins, harness §1):**
> - **Draw is CRE-only — there is NO borrower-side draw write.** `EulerVenueAdapter.draw(lineRef,amount,receiver)` is
>   `onlyController` (`EulerVenueAdapter.sol:298`, modifier `:83`), and the only legal receiver is the immutable Erebor
>   off-ramp (`:302`, `revert BadReceiver`). The controller's only write entry is `onReport(bytes,bytes)` (the Keystone
>   Forwarder + workflow-identity gate, `ZipcodeController.sol`); it exposes **no** public originate/draw method. So
>   `ZcDrawModal` becomes a **read-only line / draw-status view** — the draw is originated by the protocol (CRE), per
>   §17. (Confirmed: no surface lets a borrower/EOA draw.)
> - **Repay is the native EVK `repay`, permissionless — NOT a Zipcode-contract method.** Spec §9 (line 838-839):
>   *"permissionless repay against the line's borrow position (no hook, no report needed; Euler adapter: `EVault.repay`
>   on the line's borrow account)."* `openLine` installs the gating hook at `OP_BORROW | OP_LIQUIDATE` and **never hooks
>   `OP_REPAY`** (`EulerVenueAdapter.sol:220`), so repay is ungated. Bind to `IEVault(lineRef).repay(amount,
>   borrowAccount)` against the per-line **borrow vault** (`lineRef`), preceded by `usdc.approve(lineRef, amount)` —
>   exactly the proven in-repo EVK repay (`ReservoirLoopModule.repay`, `:248-263`: `approve(borrowVault, amt)` →
>   `repay(amt, account)`). The repayer is **any wallet** (it credits `receiver = borrowAccount`; no controller
>   enablement, no operator bit required) — that is the §4.4e permissionless property.
> - **No back-pressure obligation owed.** Every surface this UI needs EXISTS: reads `getLine`/`observeDebt`
>   (adapter) + `getLien`/`LienOriginated`/`LienStatusUpdated` (controller); the repay write is the EVK `repay` the
>   per-line vault already exposes (same EVK proxy as `reservoirBorrowVault`, whose ABI we reuse). Nothing is missing;
>   the "draw" the original FE-05 row implied as a borrower write was never owed — it is CRE-driven by design.
>
> **Live-state caveat (logged as a hole, not a contract gap):** the only line on the current post-smoke fork is
> **CLOSED** (`getLine(0x7c48…).open == false`, `observeDebt == 0`) — the smoke suite ran the full draw→repay→close loop
> (SP-14/SP-16). So the **read** path is fully live-verifiable now (it reads the real closed line), and the **repay**
> binding is fully verified (real `repay`/`debtOf` on the live `lineRef`, `asset() == USDC`, `borrowAccount` from
> `getLine`), but a live repay *state change* needs a line with drawn debt — see "Done when / Acceptance".

## Deliverable
Ship to the **layer repo** (`resi-labs-ai`, `frontend/zipcode-finance-euler/`), never the monorepo:
1. `composables/useZipLine.ts` — the borrower line **read** view + the permissionless **repay** spine. Discovers the
   line(s) from on-chain events, reads each line's live state, and exposes `repay(...)` (approve via `useZipTx` → EVK
   `repay` via the new raw `useZipTx` helper). Raw `bigint`s out; the component formats (FE-03 shape).
2. `composables/useZipTx.ts` (**extend, do not duplicate the buffer**) — add `sendRawZipTx({ to, abi, functionName,
   args, value? })` for a **runtime-address** target (the per-line `lineRef` is not a registry key) that reuses the
   SAME 1.3× gas-buffer spine as `sendZipTx`. Refactor the estimate+buffer+send+wait core into one private helper both
   call. (Standing obligation: never re-implement the buffer.)
3. `components/zipcode/ZcLinePanel.vue` — read-only on-chain credit-line surface (symmetric to FE-03's
   `ZcPositionPanel`): lists the line(s) with **owed = `observeDebt`**, the **equity mark + draw amount** (from
   `LienOriginated`), open/closed + status, and per-line **Draw** (read-only view) / **Repay** (real) actions emitted to
   the page. Pure read; props `{ user, refreshKey }`; emits `@draw(line)` / `@repay(line)`.
4. `components/zipcode/ZcDrawModal.vue` (**rewrite to read-only**) — drop the mock draw write + "transferred to your
   bank" copy. Show the selected line's live state (owed, equity mark, draw amount, status) and a clear "Draws are
   originated by the protocol (CRE) — §17; this view is read-only" note. **No write, no `@draw` emit that mutates
   state.**
5. `components/zipcode/ZcRepayModal.vue` (**rewrite to the real repay**) — input USDC (with "repay full"), the real
   approve→repay status track (**Approve USDC → Repay → Debt reduced**), input capped at the live `observeDebt`. Drives
   `useZipLine.repay`. Emits `@success` so the panel refreshes.
6. `pages/borrower/portfolio.vue` — drop the mock `handleDraw`/`handleRepay` `store.ts` mutations; mount
   `<ZcLinePanel :user="address" :refresh-key="lineRefreshKey">`; own the two modals (page passes the real selected line
   in; bumps `lineRefreshKey` on repay `@success`), exactly like the FE-03/04 page pattern. Keep the mock offer/RON
   ceremony + the `Send` action as the **off-chain originator placeholder** (§15 off-chain; out of FE-05 scope) — only
   the **line state + draw/repay data path** swaps to real.
7. `nuxt.config.ts` + `.env.example` — add `runtimeConfig.public.zipDeployBlock` (env `NUXT_PUBLIC_ZIP_DEPLOY_BLOCK`,
   string, default `'47096000'`) so the line-discovery `getLogs` is **block-bounded** (cheap; survives a redeploy).

## Spec §
`build/claude-zipcode.md` **§4** (the line lifecycle: `venue.openLine`/`setLineLimits`/`fund`/`draw` are
controller-gated; **§4.4e** no on-chain economic liquidation, resolution is off-chain → **permissionless repay**) and
**§9** (the explicit "Repay path: … Euler adapter: `EVault.repay` on the line's borrow account; no hook, no report
needed" + "Closing is separate: controller observes `venue.observeDebt == 0` → close report burns the lien →
`LienReleased`") and **§15** (the M1 base loop borrower UX: "… `venue.draw` on the line's fresh borrower account …→
permissionless repay → controller closes (burn)"). Honors **§17**: CRE drives origination/draw (the UI does NOT
originate or draw); no AVM/heartbeat (no perpetual polling — bounded reads); collateral mocked. The borrower-of-record
is a disposable per-line `LineAccount`, **not** the connected wallet — the UI reads line state and exposes a
permissionless repay any wallet can land.

## Binds to (verified against the deployed ABIs, the FE-01 registry, the live fork, and the contract source)
All Zipcode contracts via the **FE-01 module** (`ZIPCODE_CONTRACTS[key] = { address, abi }`; keys confirmed in
`lib/zipcode/generated/registry.ts`). Reads go through the **browser proxy client** (`useRpcClient().client`,
null-guarded) exactly like FE-02/03/04. Writes go through **`useZipTx`** (never re-implement the 1.3× buffer).

**Reads (all real `view`s — confirmed live on the fork):**
- **`venueAdapter`** = `0x87dC8666F0c31Fb4B205240003DD733E327E14F3` (`EulerVenueAdapter`):
  - `getLine(lineRef) → struct Line{ collateralVault, lienToken, router, lineAccount, borrowAccount, open }` — the
    struct getter (ABI: `EulerVenueAdapter.json`, a **named-tuple** output). viem `readContract` returns it as an
    **object** with those component names — read `struct.borrowAccount` (the `receiver` arg for repay) + `struct.open`
    (the line's live open flag) **by name**, not by positional index.
  - `observeDebt(lineRef) → uint256` — the line's current USDC debt (= `IEVault(lineRef).debtOf(borrowAccount)`, 6-dp);
    readable AFTER close (returns 0). **This is "Amount Owed".**
  - Event `LineOpened(bytes32 lienId, address lineRef, address oracleKey, address collateralVault, address router,
    address borrowAccount)` — `lienId` + `lineRef` are indexed (topics); the rest are in `data`. Discovery source for
    the structural addresses.
- **`controller`** = `0x36025de2F0753789058eAE99003BbE2131b63810` (`ZipcodeController`):
  - `getLien(lienId) → (lien, lineRef, open)` — `LienRecord` (`ZipcodeController.sol:62-66`). `open` = lien-level
    open flag.
  - Event `LienOriginated(bytes32 indexed lienId, address indexed lien, address lineRef, bytes32 proofRef, uint256
    equityMark, uint256 drawAmount)` — **the economics**: `equityMark` (the Proof-of-Value collateral mark, 6-dp USDC)
    + `drawAmount` (the initial draw, 6-dp). Discovery + display source. (Verified live: one event, `equityMark =
    100_000e6`, `drawAmount = 50_000e6`, `lineRef = 0x7c489cc9…`.)
  - Event `LienStatusUpdated(bytes32 indexed lienId, uint8 status)` — M1 status marker (latest event per lienId);
    `LienReleased(bytes32 indexed lienId)` — emitted at close. (Both optional for the panel; default "active" when no
    status event, "released" if `LienReleased` seen / `!open`.)
- **per-line `lineRef`** (the borrow vault — a runtime address, NOT a registry key; **same EVK proxy** as
  `reservoirBorrowVault`, so reuse its ABI): `IEVault` — `asset() → address` (= USDC, verified), `debtOf(account) →
  uint256`. **ABI = `ZIPCODE_CONTRACTS.reservoirBorrowVault.abi`** (the EVK `IEVault.json`; it carries `repay`/`debtOf`/
  `asset`). Bind it to the runtime `lineRef` address.
- **`usdc`** = `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (registry key `usdc`, `ERC20.json`, **6-dp**):
  `balanceOf(user) → uint256`, `allowance(user, lineRef) → uint256`, `decimals()` (= 6).

**Writes (both via `useZipTx`; the 1.3× buffer is reused, never re-implemented):**
- `usdc.approve(lineRef, amount)` → `sendZipTx({ key: 'usdc', functionName: 'approve', args: [lineRef, amount] })`
  (the spender is just an arg; `to` = USDC, which IS a registry key). The approve **spender is the line vault itself**
  (`lineRef`) — direct, NOT Permit2 (mirrors `ReservoirLoopModule.repay:251` `approve(borrowVault, amt)`).
- `IEVault(lineRef).repay(amount, borrowAccount)` → the new **`sendRawZipTx({ to: lineRef, abi: EVAULT_ABI,
  functionName: 'repay', args: [amount, borrowAccount] })`** (raw because `lineRef` is a runtime address, not a registry
  key). `EVAULT_ABI = ZIPCODE_CONTRACTS.reservoirBorrowVault.abi`. EVK `repay(uint256,address)` (`IEVault.sol:240`):
  pulls `amount` USDC from the connected wallet (the EVC-authenticated caller; the vault is `callThroughEVC`) and
  reduces `borrowAccount`'s debt. **`amount = type(uint256).max` repays exactly the full accrued debt** (EVK clamps; a
  finite over-repay reverts `E_RepayTooMuch`, per SP-04) — use max for "repay full".

**Model from (verified layer files):**
- write spine — `composables/useZipTx.ts` (`sendZipTx({ key, functionName, args })` + the new `sendRawZipTx`).
- read shape — `composables/useZipPosition.ts` (proxy-client `readContract`, null-guarded, raw `bigint`s; the component
  formats with `formatUnits`) — the **read-view template** FE-03 set for exactly this.
- the panel shell — `components/zipcode/ZcPositionPanel.vue` (brand-card, `:user`/`:refreshKey` props, watches
  `user`/`refreshKey`/`client`, not-connected/loading/zero states, no `defineExpose`).
- the modal shell + step machine + write UX — the existing `ZcRepayModal.vue`/`ZcDrawModal.vue` (`ZcModal`, `step` ref,
  `surface-sharp`/`field-sharp`/`btn-pill-*`, `formatUsdc`) + FE-02 `ZcDepositModal.vue` (approve→action two-phase
  loading, `gate()` guard, toasts via `import { useToast } from '~/components/ui/composables/useToast'`).
- the consuming page — `pages/borrower/portfolio.vue` (the `<ZcDrawModal>`/`<ZcRepayModal>` wiring + `handleDraw`/
  `handleRepay` mocks to replace) and the FE-03 `pages/lender/portfolio.vue` (panel + `:refresh-key` + `@success`
  bump pattern to mirror).
- auto-imports — `useWagmi()` → `{ address, isConnected, connect }`; `useRpcClient()` → `{ client }`;
  `useRuntimeConfig()`; `formatUnits`/`parseUnits`/`maxUint256` from `viem`.

## Starting state
- FE-00..04 done: registry + typed ABIs (`reservoirBorrowVault` → `IEVault` ABI; `usdc` → `ERC20`; `venueAdapter`,
  `controller` present); `useZipTx` (the 1.3× gas-buffer write spine, `sendZipTx({ key, … })`); `useZipPosition` +
  `ZcPositionPanel` (the FE-03 read-view template); `useCowExit` + the rewritten `ZcWithdrawModal` (FE-04). The
  lender portfolio mounts a real position panel; the **borrower portfolio is still all mock** (`ZcDrawModal`/
  `ZcRepayModal` mutate `store.ts`; balances come from `defaultBorrowerState()` + localStorage).
- Anvil up @ `127.0.0.1:8545` (Base fork, chainId 8453, block 47096192). One line exists and is **closed**:
  `lineRef = 0x7c489cc95f242c5abed07712c3f21ca3126adcd7`, `borrowAccount = 0xb11844…fAf`, `getLine(...).open == false`,
  `observeDebt == 0`, `asset() == USDC`. `LienOriginated`: `equityMark = 100_000e6`, `drawAmount = 50_000e6`.
- No `useZipLine` composable, no `ZcLinePanel`, no `sendRawZipTx` exist yet. `ZcDrawModal`/`ZcRepayModal` are the mock
  ports (input → confirm → fake `setTimeout` → success; `@draw`/`@repay` emit a string the page applies to `store.ts`).

## Do NOT
- Do **not** bind a borrower-side **draw/originate** write — there is **none** (draw is `onlyController`, the controller
  has no public originate method; §17 CRE-driven). `ZcDrawModal` is **read-only**.
- Do **not** call any `EulerVenueAdapter` mutator from the UI (`openLine`/`setLineLimits`/`fund`/`draw`/`closeLine`/
  `liquidate`) — **all are `onlyController`** and will revert `NotController` for an EOA. `liquidate` additionally
  `revert NotImplemented` (§4.4e). Reads only on the adapter.
- Do **not** route the repay through the adapter or the controller — repay is the **native EVK `repay` on `lineRef`**,
  called directly (no `ZipcodeController`/`EulerVenueAdapter` repay method exists).
- Do **not** assume the connected wallet is the borrower-of-record — it is NOT (the borrower is a disposable per-line
  `LineAccount`, §17). Do not filter lines "by my address". Repay is **permissionless**: any wallet repays any line's
  debt by approving USDC + `repay(amount, borrowAccount)`.
- Do **not** re-implement the 1.3× gas buffer — `approve` uses `sendZipTx`; `repay` uses the new `sendRawZipTx`, which
  reuses the SAME buffer core.
- Do **not** approve/repay against Permit2 — the EVK pull is a **direct** `approve(lineRef, amount)` on USDC (proven by
  `ReservoirLoopModule.repay:251`).
- Do **not** perpetually poll on-chain state (§17 no-heartbeat) — reads fire on mount + `refreshKey` bump + post-write,
  not on an interval.
- Do **not** float-scale. USDC/`observeDebt`/`equityMark`/`drawAmount` are **6-dp**; `bigint` math; `formatUnits(x, 6)`
  for display, `parseUnits(s, 6)` for input.
- Do **not** stage built Vue/composables in the monorepo — commit to the **layer repo**; only this ticket file lands in
  the monorepo (`build/tickets/frontend/`).

## Key requirements
1. **`useZipTx` — add `sendRawZipTx`, share the buffer.** Refactor the estimate→buffer→send→wait body of `sendZipTx`
   into a private `async function sendBuffered({ to, data, value })` (the existing `gas = max(ceil(est*1.3), est+150k)`
   math, unchanged). `sendZipTx` builds `data` from `ZIPCODE_CONTRACTS[key]` then calls `sendBuffered`. New export
   `sendRawZipTx({ to, abi, functionName, args, value? }): Promise<SendZipTxResult>` builds `data =
   encodeFunctionData({ abi, functionName, args })` against an **arbitrary `to`/`abi`** then calls the SAME
   `sendBuffered`. Both return `{ hash, receipt }`. (The buffer lives in exactly one place.)
2. **`useZipLine` — discovery + reads (proxy-client, null-guarded, raw `bigint`s).** Expose:
   - `loadLines(): Promise<ZipLine[]>` — discover via `controller` `LienOriginated` logs (the economics: `lienId`,
     `lien`, `lineRef`, `equityMark`, `drawAmount`) over `[fromBlock = zipDeployBlock, 'latest']`
     (`getContractEvents`/`getLogs`); for each, read `venueAdapter.getLine(lineRef)` (→ `borrowAccount`,
     `collateralVault`, `lienToken`, `open`) + `venueAdapter.observeDebt(lineRef)` (→ `owed`) + the lien-level
     `open`/status (latest `LienStatusUpdated` or `LienReleased` ⇒ released). Returns `[]` when `!client`. Each
     `ZipLine = { lienId: Hex, lineRef: Address, borrowAccount: Address, collateralVault: Address, lienToken: Address,
     open: boolean, owed: bigint, equityMark: bigint, drawAmount: bigint, status: 'active' | 'released' | 'delinquent' }`
     (status from the uint8 marker; M1 maps 0→active; treat `LienReleased`/`!open` as `released`; any nonzero non-release
     marker → `delinquent`). All amounts raw 6-dp `bigint`.
   - `loadLine(lineRef): Promise<ZipLine | undefined>` — single-line refresh (re-reads `getLine`/`observeDebt`) for the
     post-repay panel refresh.
   - `allowance(user, lineRef): Promise<bigint>` — `usdc.allowance(user, lineRef)`.
   - `usdcBalanceOf(user): Promise<bigint>` — `usdc.balanceOf(user)` (the repayer's USDC).
3. **`useZipLine.repay` — the permissionless repay write (via `useZipTx`).**
   `repay({ lineRef, borrowAccount, amount, full }): Promise<void>` where `amount` is 6-dp `bigint`:
   - read `allowance(user, lineRef)`. If `< amount` (partial) or always-ensure for `full` → approve via
     `sendZipTx({ key: 'usdc', functionName: 'approve', args: [lineRef, full ? maxUint256 : amount] })`.
   - then `sendRawZipTx({ to: lineRef, abi: EVAULT_ABI, functionName: 'repay', args: [full ? maxUint256 : amount,
     borrowAccount] })` (`EVAULT_ABI = ZIPCODE_CONTRACTS.reservoirBorrowVault.abi`).
   - **Partial:** approve exact `amount` (only if `allowance < amount`); `repay(amount, borrowAccount)`. **Full:**
     approve `maxUint256` (only if `allowance < currentOwed`); `repay(maxUint256, borrowAccount)` so EVK clamps to the
     accrued debt atomically (no dust, no `E_RepayTooMuch`). No allowance reset (note: `ReservoirLoopModule` resets to 0
     for module conservatism; the UI omits it for a 2-tx UX — the lingering allowance is the user's own to a
     repay-only vault).
4. **`ZcLinePanel.vue` — read-only on-chain line surface (FE-03 panel shape).** Props `{ user?: Address, refreshKey?:
   number }`. On mount + watch(`user`/`refreshKey`/`client`), call `loadLines()`. Render per line: a brand-card row with
   **Owed = `formatUnits(owed, 6)`**, **Equity mark = `formatUnits(equityMark, 6)`**, **Draw amount = `formatUnits(
   drawAmount, 6)`**, an open/closed + status badge, and two buttons: **Draw** (emits `@draw(line)` → opens the
   read-only `ZcDrawModal`) and **Repay** (emits `@repay(line)`; **disabled when `owed == 0n` or `!open`**).
   Not-connected / loading / no-lines (empty) states. Pure read, no `defineExpose`, no writes. (One line is the M1
   demo reality; render the list generically so N lines work.)
5. **`ZcDrawModal.vue` — read-only line / draw-status view.** Rewrite: props `{ isOpen: boolean, line: ZipLine | null
   }`, emit `{ close }`. Show the line's `owed`/`equityMark`/`drawAmount`/`status`/`open`, and a clear note:
   **"Draws are originated by the protocol (CRE) at underwriting (§17). This is a read-only view — there is no
   borrower-initiated draw."** No amount input, no submit, no `@draw` mutation. (Replaces the mock "Draw Funds → confirm
   → transferred to your bank account" flow entirely.)
6. **`ZcRepayModal.vue` — the real permissionless repay.** Rewrite: props `{ isOpen: boolean, line: ZipLine | null,
   user?: Address }`, emit `{ close, success }`. Steps:
   - **input:** USDC amount (with a **"Repay full"** that selects the full path); the live **Outstanding = `formatUnits(
     line.owed, 6)`** (re-read fresh on open via `loadLine`); a `gate()` guard disabling submit if `line.owed == 0n`,
     `!line.open`, no `user`, or `usdcBalanceOf(user) < amount`. Cap the input at `line.owed` for the partial path
     (a finite over-repay reverts `E_RepayTooMuch`).
   - **approve + repay:** two-phase loading via `useZipLine.repay({ lineRef, borrowAccount, amount, full })`; show
     **Approve USDC → Repay** stages. On the receipt, **success** state ("Repaid `$X` — outstanding reduced"), emit
     `@success`, auto-close. Toasts via the explicit `useToast` import (FE-02 pattern).
   - errors surface as a toast + return to input (do not leave a half-state).
7. **`pages/borrower/portfolio.vue` integration.** Drop the mock `handleDraw`/`handleRepay` (`store.ts` mutations +
   the "transferred / debited from your bank" copy). Mount `<ZcLinePanel :user="address" :refresh-key="lineRefreshKey"
   @draw="onDraw" @repay="onRepay">`. Own `selectedLine` (the line passed up from the panel) + the two modals
   (`<ZcDrawModal :is-open :line>`, `<ZcRepayModal :is-open :line :user="address" @success="() => lineRefreshKey++">`).
   The existing mock offer/RON ceremony + the `Send` action stay (off-chain originator placeholder, §15 — out of FE-05
   scope; leave their mock paths untouched, but they no longer feed a fake "drawn" balance into the real line surface).
8. **`zipDeployBlock` config.** Add `zipDeployBlock: '47096000'` to `runtimeConfig.public` in `nuxt.config.ts` (string,
   matching the existing public-config entries) + `NUXT_PUBLIC_ZIP_DEPLOY_BLOCK=` to `.env.example`. `useZipLine` reads
   `BigInt(useRuntimeConfig().public.zipDeployBlock)` as the `getLogs` `fromBlock` (bounded scan; the deploy is at block
   47096135, ~135 blocks above the fork base — a tiny range).

## Resolved decisions (close these — no builder guess)
- **No borrower draw write — `ZcDrawModal` is read-only.** Draw is `onlyController` + CRE-originated (§17). The modal
  only displays line state.
- **Repay = native EVK `repay` on `lineRef`, permissionless.** `usdc.approve(lineRef, amount)` → `IEVault(lineRef).
  repay(amount, borrowAccount)`. Direct approve to the vault (not Permit2). Any wallet may repay (credits `borrowAccount`).
- **`lineRef` is a runtime address → `sendRawZipTx`.** Reuse `ZIPCODE_CONTRACTS.reservoirBorrowVault.abi` (the EVK
  `IEVault` ABI) bound to `lineRef`. The buffer is shared, not re-implemented.
- **"Repay full" = `maxUint256`** (EVK clamps to accrued debt; avoids dust + `E_RepayTooMuch`); approve `maxUint256` for
  the full path. **Partial = exact `amount`** approve+repay, input capped at `observeDebt`.
- **`borrowAccount` = `getLine(lineRef)` field 5** — the repay `receiver`. Read it; never derive/guess.
- **Discovery = `LienOriginated` (controller) joined to `getLine`/`observeDebt` (adapter) on `lineRef`.** Bounded
  `getLogs` from `zipDeployBlock`. One line on the fork; render the list generically.
- **Reads are the FE-03 template** (proxy client, null-guarded, raw `bigint`, component formats). No perpetual poll;
  refresh on mount + `refreshKey` + post-write (§17).
- **Decimals:** USDC/`observeDebt`/`equityMark`/`drawAmount` all **6-dp**; `bigint` throughout; `formatUnits(x, 6)` /
  `parseUnits(s, 6)`; `maxUint256` from `viem`.
- **The connected wallet ≠ borrower.** No "my lines" filter; the panel shows the protocol's line(s); repay is
  permissionless. (Faithful to §17 disposable-LineAccount borrower-of-record.)

## Done when
- `npm run build` (`nuxt build`) is **green** in `frontend/zipcode-finance-euler/` (the gate — NOT `npm run dev`).
- `useZipTx.sendRawZipTx` exists and shares the buffer; `useZipLine` reads real line state; `ZcLinePanel` renders the
  real line(s); `ZcDrawModal` is read-only (no write); `ZcRepayModal` runs the real approve→repay; `portfolio.vue`
  drops the mock draw/repay mutations and refreshes the panel on a settled repay. Every import, address, ABI method, the
  repay args (`amount`, `borrowAccount`), and the decimals resolve to a cited file/symbol.
- A cold-build subagent building from this ticket alone returns **zero load-bearing guesses**.
- **Read acceptance (anvil up):** the panel reads the real line — `lineRef 0x7c48…`, `owed = $0.00`, status
  released/closed (`open == false`), equity mark `$100,000`, draw amount `$50,000` — off the live contracts (verifiable
  with `cast call venueAdapter "observeDebt(address)" 0x7c48…` and the `LienOriginated` log). The Repay button is
  correctly **disabled** for this closed/zero-debt line.
- **Repay acceptance (binding-verified now; live state-change needs drawn debt):** the repay path binds to the real
  `repay(uint256,address)` on the live `lineRef` (`asset() == USDC`, `borrowAccount` from `getLine`) and the `approve`/
  `repay` `encodeFunctionData` + gas-estimate succeed against the contract. A live repay *state change* requires a line
  with `observeDebt > 0`; the post-smoke fork's only line is closed, so a true on-fork repay is demonstrated by either
  (a) re-running the SP-14 origination to stand up a fresh drawn line, or (b) the reviewer drawing a line — then the
  modal's approve→repay lands and `observeDebt` drops. **This is a fork-STATE limitation, not a contract/binding gap**
  (logged in PROGRESS; no obligation owed).
- Committed to the **layer repo** (`resi-labs-ai`). PROGRESS updated: FE-05 done; the back-pressure finding
  (draw = CRE-only, repay = native EVK `repay`) + the closed-line state caveat logged; next `NEXT` set.

## Critic triage — pinned details (close every gap; no builder guess)
The four critics returned **spec-fidelity ALL PASS** (faithful to §4/§4.4e/§9/§15, §17 honored, no mechanism invented,
no inbound obligation), **reference-verifier all bindings resolve** (every ABI method/event, registry key, viem export,
and layer auto-import confirmed usable; the RPC proxy `euler-lite/server/api/rpc/[chainId].ts` explicitly allows
`eth_getLogs` in `ALLOWED_METHODS`), and **frontend-binding back-pressure PASS** (every demanded surface exists; repay
mechanics + the permissionless property confirmed against `EulerVenueAdapter.sol:220`/`ReservoirLoopModule.sol:251`).
The junior-dev gaps were **ticket-precision only** — pinned here so the cold-build guesses nothing:

1. **Event query = viem `getContractEvents`** (the proxy supports `eth_getLogs`): `client.value.getContractEvents({
   abi: ZIPCODE_CONTRACTS.controller.abi, address: ZIPCODE_CONTRACTS.controller.address, eventName: 'LienOriginated',
   fromBlock, toBlock: 'latest' })` → typed logs with `args.{lienId,lien,lineRef,proofRef,equityMark,drawAmount}`. Same
   call shape for `LienStatusUpdated` / `LienReleased` (controller abi). `fromBlock = BigInt(useRuntimeConfig().public.
   zipDeployBlock)`. One discovery pass reads all three event sets (3 `getContractEvents` calls), then joins in memory.
2. **Status derivation — pinned precedence (released wins, then delinquent, else active):**
   - default `status = 'active'`.
   - if a `LienReleased` log exists for the `lienId` **OR** `getLine(lineRef).open == false` → `status = 'released'`
     (closed is terminal — released beats any stale status marker).
   - else take the **latest** `LienStatusUpdated` for the `lienId` (max `blockNumber`, tie-break max `logIndex`); if its
     `args.status` (uint8) `!= 0` → `status = 'delinquent'`; `== 0` → `'active'`.
   The `ZipLine.open` field = `getLine(lineRef).open` (the adapter's live flag); `owed = observeDebt(lineRef)`.
3. **`loadLine` takes the prior `ZipLine` (no re-discovery):** signature `loadLine(prev: ZipLine): Promise<ZipLine>` —
   re-reads ONLY `getLine(prev.lineRef)` (→ fresh `open`/`borrowAccount`) + `observeDebt(prev.lineRef)` (→ fresh `owed`)
   + the latest status events for `prev.lienId`, and returns `{ ...prev, open, owed, status, borrowAccount }`. Keeps the
   immutable `lienId`/`equityMark`/`drawAmount` from `prev` (they don't change). Used by the modal on open + the panel
   post-repay refresh.
4. **`EVAULT_ABI` = a local const** at the top of `useZipLine.ts`: `const EVAULT_ABI =
   ZIPCODE_CONTRACTS.reservoirBorrowVault.abi` (the EVK `IEVault` ABI, reused for the runtime `lineRef`). `maxUint256`
   imported from `viem`.
5. **`useZipTx` returns `{ sendZipTx, sendRawZipTx }`;** `sendRawZipTx(...): Promise<SendZipTxResult>` (same `{ hash,
   receipt }`). Refactor the estimate→buffer→send→wait body into one private `sendBuffered({ to, data, value })`; both
   public fns build `data` (one from `ZIPCODE_CONTRACTS[key]`, one from the raw `abi`) then call it. The buffer math is
   unchanged and lives in exactly one place.
6. **`repay({ lineRef, borrowAccount, amount, full })` — `full: boolean` is explicit** (the modal sets it). The
   `amount` is the exact 6-dp `bigint` to repay for the partial path, **and** the current owed (for the allowance check)
   on the full path. Approve gate: `required = full ? maxUint256 : amount`; read `allowance(user, lineRef)`; **skip the
   approve tx when `allowance >= (full ? amount : amount)`** (i.e. partial: skip if `allowance >= amount`; full: skip if
   `allowance >= amount` where `amount == owed`). Then approve `full ? maxUint256 : amount` only if not skipped; then
   `repay(full ? maxUint256 : amount, borrowAccount)`.
7. **`ZcRepayModal` step machine = `'input' | 'loading' | 'success'`** (mirror the existing modal) **plus a
   `loadingLabel` ref** that reads `'Approving USDC…'` during the approve tx and `'Repaying…'` during the repay tx
   (`useZipLine.repay` runs both sequentially; surface the label via a callback or by splitting the two awaits in the
   modal). On open, re-read the line's live `owed` via `loadLine(props.line)` so the Outstanding figure is fresh.
   Input is validated in the continue handler — **reject** (error message, like the current modal) when `parsed >
   line.owed` for a partial; "Repay full" sets `full = true` and bypasses the cap. Success copy: `"Repaid $X —
   outstanding reduced"` where `$X` = the submitted amount (full → the pre-repay owed). `emit('success')` then
   `setTimeout(() => emit('close'), 1400)` (mirror the mock's auto-close). Errors → `useToast` + back to `'input'`.
8. **Panel/page event payload = the full `ZipLine`:** `ZcLinePanel` emits `@draw(line: ZipLine)` / `@repay(line:
   ZipLine)`; `portfolio.vue` owns `const selectedLine = ref<ZipLine | null>(null)` + `drawOpen`/`repayOpen` refs, sets
   `selectedLine` in `onDraw`/`onRepay`, passes `:line="selectedLine"` to both modals, and bumps `lineRefreshKey` on
   `ZcRepayModal @success`. The `Send` mock action + the offer/RON ceremony stay untouched (out of FE-05 scope).
9. **`zipDeployBlock` is a string config, parsed at use.** Add `zipDeployBlock: process.env.NUXT_PUBLIC_ZIP_DEPLOY_BLOCK
   ?? '47096000'` to `runtimeConfig.public` (string, matching the existing public entries) + `NUXT_PUBLIC_ZIP_DEPLOY_BLOCK=`
   to `.env.example`. Read `BigInt(useRuntimeConfig().public.zipDeployBlock)` for `fromBlock`. ("Survives a redeploy"
   just means it is env-configurable — NOT auto-detected; a redeploy that moves the block is repointed via the env.)
10. **`maxUint256` for the full-repay approve/repay arg; all other amounts 6-dp `bigint`.** No `defineExpose` on the
    panel (FE-03). The panel's Repay button is `:disabled="line.owed === 0n || !line.open"`; Draw is always enabled
    (read-only view).

## Depends on
FE-00 (layer boots — DONE), FE-01 (address book + typed ABIs incl. `reservoirBorrowVault`/`venueAdapter`/`controller`/
`usdc` — DONE), FE-02 (`useZipTx` write spine — DONE; this ticket extends it with `sendRawZipTx`), FE-03
(`useZipPosition`/`ZcPositionPanel` read-view template — DONE). No open obligations against FE-05 in PROGRESS (confirmed
during the back-pressure check — every needed surface exists; the implied borrower "draw" write was never owed, it is
CRE-driven by design).
