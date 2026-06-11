# FE-04 — szipUSD exit via the CoW book: rest a sell order + the `navExit`/treasury-bid status track (§6.4)

> Replaces the mock withdraw path (`ZcWithdrawModal` → `store.ts` mutation) with the **real szipUSD junior exit** as the
> contract actually implements it. **Back-pressure check done — it reshaped this ticket (the original FE-04 row was a
> conflation the spec explicitly warns against):**
> - **szipUSD (junior) exit is NOT a contract write.** Spec §6.4 + `ExitGate.sol:21-28`: the forfeiting on-chain
>   `requestExit`/`processWindow` queue is **RETIRED**. To exit, a holder **rests a CoW sell order** for their szipUSD;
>   the protocol treasury (`SzipBuyBurnModule`, 8-B14) posts a standing discounted BUY bid or an external buyer fills it,
>   and `ExitGate.burnFor` (CRE `windowController`-only) retires what was bought. There is **no `requestExit`, no
>   `cancelExit`, no user-callable exit write** on `ExitGate` — only the off-chain CoW order + the on-chain
>   `approve(vaultRelayer)` it needs.
> - **`ZipRedemptionQueue` is the SENIOR (zipUSD→USDC) treasury off-ramp, not this.** `requestRedeem` is
>   `onlyRedeemController` = the rq Safe driven by `OffRampModule` (CRE-operated); `requester == owner == rqSafe`. A
>   retail lender **cannot** enter that queue or claim from it. `ZipRedemptionQueue.sol:14-17` + `OffRampModule.sol:33-40`
>   say so explicitly: *"It is NOT the junior Exit Gate… different instrument… Never conflate."* **FE-04 does not touch
>   the senior queue or any "cooldown panel."** (No szipUSD cooldown exists — the resting CoW order *is* the queue.)
>
> **Deploy target is Base mainnet; anvil is only a local fork.** Build the exit for how it works on **mainnet** (real
> EIP-712 CoW order → CoW Order Book API → solver/treasury fill) and **spoof the un-forkable leg locally** (no CoW solver
> runs against the fork, and our fork-only szipUSD isn't a real-Base token, so the real API would reject it). Everything
> else — the `approve`, the EIP-712 signature, the reads — is **real on the fork**.

## Deliverable
Ship three layer files (commit to the **layer repo** `resi-labs-ai`, never the monorepo):
1. `composables/useCowExit.ts` — the szipUSD→USDC CoW sell-order spine: reads the CoW wiring + pricing **live from our
   deployed `SzipBuyBurnModule`** (no hard-coded CoW addresses), builds + signs the GPv2 order (mirror of the module's
   BUY order, `kind = sell`), and posts/tracks it — **live** against the CoW Order Book REST API or **spoofed** locally
   behind one `isCowLive` flag. The on-chain `approve(vaultRelayer)` routes through the shared **`useZipTx`** spine.
2. `components/zipcode/ZcWithdrawModal.vue` — rewrite the mock modal into the §6.4 exit: input szipUSD (with max),
   surface **what you'd get now (treasury bid) vs by waiting (`navExit`)**, then run the status track
   **Order resting (your limit) → Filled (treasury or market) → szipUSD burned**.
3. `pages/lender/portfolio.vue` — drop the mock `handleWithdraw` (which mutates `store.ts`); drive the real modal,
   refresh the FE-03 position panel on a confirmed/settled exit. Cross-link FE-03's `navExit` redeemable mark.

## Spec §
`build/claude-zipcode.md` **§6.4** (junior exit = Exit Gate custody + the CoW book; the resting CoW order is the only
queue; treasury just-in-time buy-and-burn or external fill → `burnFor`; the literal UI "status track" blueprint) and
**§6.2** ("Junior secondary (szipUSD)… selling szipUSD/USDC on a CoW order book… separate book from the senior
zipUSD/USDC AMM"). Honors §17: NAV is the on-chain pricing primitive (read `navExit`, never compute); no AVM/heartbeat;
szipUSD is the NAV-priced **transferable** share; **no forfeit** (the basket is never confiscated — an unfilled holder
just sits, still earning). Discount `d` is a governed param read on-chain (`dBps`), not a UI input.

## Binds to (verified against the deployed ABIs, the FE-01 registry, and our own `SzipBuyBurnModule.sol`)
All Zipcode contracts via the **FE-01 module** (`ZIPCODE_CONTRACTS[key] = { address, abi }`; keys confirmed in
`lib/zipcode/generated/registry.ts`). Reads go through the **browser proxy client** (`useRpcClient().client`,
null-guarded) exactly like FE-02/FE-03. The write (`approve`) goes through **`useZipTx`** (FE-02 — never re-implement the
1.3× gas buffer).

**Read the CoW wiring LIVE from our module (do NOT hard-code CoW addresses — derive them, then they survive a redeploy):**
- **`buyBurnModule`** = `0x12881a80c4f4eee7430d1c1c53bbbcfc4c92f71b` (`SzipBuyBurnModule`). Back-pressure check PASSES
  against `build/anvil/abi/SzipBuyBurnModule.json` — every field below is a real `view`:
  - `settlement() → address` → `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (canonical GPv2Settlement, **EIP-712
    `verifyingContract`**). Code confirmed present on the fork.
  - `vaultRelayer() → address` → `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` (the **`approve` spender** — the szipUSD
    allowance target). Code confirmed present on the fork.
  - `usdc() → address` → `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base USDC, **6-dp** — the order `buyToken`).
  - `szipUSD() → address` → `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` (**18-dp** — the order `sellToken`).
  - `domainSeparator() → bytes32` → live `0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b` (the
    GPv2 EIP-712 domain separator for chainId 8453; use it to **self-verify** the FE-computed domain — Key req 4).
  - `quoteMaxPrice() → uint256` → the **6-dp USDC the treasury will pay per `1e18` share** = `navExit × (10_000 −
    dBps)/10_000 / 1e12`, round-down. Live ≈ `105943634` (= $105.94, i.e. `navExit` $107.01 × 0.99). **This is the
    "standing treasury bid" / "what you'd get now" figure** the §6.4 status track shows.
  - `dBps() → uint16` → the governed discount in bps. Live `100` (= 1%). Display-only; the price math reads it live.
  - `TYPE_HASH() → bytes32`, `KIND_BUY() → bytes32`, `BALANCE_ERC20() → bytes32`, `APP_DATA() → bytes32` — the GPv2
    constants. `TYPE_HASH = 0x1a59c8ffcce6fc2e6738119e0d2e050163ef0912ac7168f28acd39badd252b51`; `BALANCE_ERC20 =
    0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9`; `APP_DATA = bytes32(0)`. (Read them live OR
    pin them as module-mirroring constants — they are `constant`s in `SzipBuyBurnModule.sol:39-46`.)
- **`szipUsd`** = `0x33aD…` (`SzipUSD`, 18-dp). Reads: `balanceOf(user) → uint256`, `allowance(user, vaultRelayer) →
  uint256`. Write: `approve(vaultRelayer, sellAmount) → bool` (via `useZipTx`: `sendZipTx({ key: 'szipUsd',
  functionName: 'approve', args: [vaultRelayer, sellAmount] })` — the spender is just an arg; the `to` is the szipUSD
  token, which IS in the registry).
- **`navOracle`** = `0x0C3E…` (`SzipNavOracle`) — `navExit() → uint256` (18-dp redeemable mark, **never reverts**; FE-03
  seam). **Reuse FE-03's `useZipPosition`** for `navExit` + `szipBal` rather than re-reading (cross-link the redeemable
  value the FE-03 panel already shows).

**The GPv2 sell order (mirror `SzipBuyBurnModule._orderUid`, `SzipBuyBurnModule.sol:316-336`) — the lender's order is the
MIRROR of the module's BUY order:** the struct, field order, domain, and `0x1901` digest are IDENTICAL; only three
things flip for the lender's SELL:

| field | treasury BUY (`_orderUid`) | lender SELL (this ticket) |
|---|---|---|
| `sellToken` | `usdc` | **`szipUSD`** |
| `buyToken` | `szipUSD` | **`usdc`** |
| `receiver` | `engineSafe` | **the lender (`user`)** |
| `sellAmount` | USDC (6-dp) | **szipUSD (18-dp)** = the exit size |
| `buyAmount` | szipUSD (18-dp) | **min USDC out (6-dp)** = the limit (Key req 3) |
| `kind` | `KIND_BUY` | **`keccak256("sell")` = `0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775`** (verified `cast keccak "sell"`; the module only exposes `KIND_BUY`, so pin the sell hash as a constant) |
| `validTo`, `appData`, `feeAmount`, `partiallyFillable`, `sellTokenBalance`, `buyTokenBalance` | — | **identical**: `validTo = now + TTL` (uint32), `appData = APP_DATA (bytes32(0))`, `feeAmount = 0`, `partiallyFillable = false` (Key req 3), `sellTokenBalance = buyTokenBalance = BALANCE_ERC20` |

**Signing differs from the module by design:** the module is a **contract** → it signs via on-chain PRESIGN
(`setPreSignature`). The lender is an **EOA** → it signs the order **EIP-712** with its wallet (`signingScheme: "eip712"`
to the CoW API). Use viem's `signTypedData` via **`@wagmi/vue` `useSignTypedData`** with the GPv2 domain
`{ name: "Gnosis Protocol", version: "v2", chainId: 8453, verifyingContract: <settlement> }` and the canonical `Order`
type (12 fields, matching `TYPE_HASH`). **Do NOT add `@cowprotocol/cow-sdk`** (ethers-v6 peer dep conflicts with the
layer's viem/wagmi stack) — hand-roll with viem `signTypedData` + a plain `fetch` to the documented CoW REST endpoints
(`POST {base}/api/v1/orders`, `GET {base}/api/v1/orders/{uid}`, mainnet base `https://api.cow.fi/base`). The order struct
is fully specified by our in-repo `SzipBuyBurnModule.sol`; the API shape is the only off-repo surface and it is the leg
that is spoofed locally anyway.

**Model from (verified layer files):**
- write spine — `composables/useZipTx.ts` (`sendZipTx({ key, functionName, args })`; the `approve` is one such call).
- read shape — `composables/useZipPosition.ts` (proxy-client `readContract`, null-guarded; raw `bigint` returns,
  component formats) + `useZipDeposit.ts`.
- sign primitive — `@wagmi/vue` `useSignTypedData()` → `signTypedDataAsync(...)` (same package the layer already uses for
  `useSendTransaction`; confirm the export — reference-verifier).
- the modal shell + step machine — the existing `components/zipcode/ZcWithdrawModal.vue` (`ZcModal`, `step` ref,
  `surface-sharp`/`field-sharp`/`btn-pill-*` classes, `formatUsdc`) and the FE-02 `ZcDepositModal.vue` (approve→action
  two-phase loading, `gate()` guard, toasts via an explicit `import { useToast }`).
- the consuming page — `pages/lender/portfolio.vue` (`handleWithdraw` mock to replace + the `<ZcWithdrawModal>` wiring +
  the FE-03 `<ZcPositionPanel :user :refresh-key>` to refresh on a settled exit).

## Starting state
- FE-01/02/03 done: registry + typed ABIs; `useZipTx` (gas-buffer write spine); `useZipPosition` + `ZcPositionPanel`
  (reads `navExit`/`szipBal`). `portfolio.vue` mounts the position panel + a mock `ZcWithdrawModal` whose
  `handleWithdraw` mutates `store.ts` and shows "Withdraw USDC… arrives in your wallet."
- Anvil up @ `127.0.0.1:8545` (Base fork, chainId 8453, block 47096192). GPv2Settlement + VaultRelayer have code on the
  fork; `buyBurnModule.quoteMaxPrice()` ≈ `105943634`, `navExit()` ≈ `1.07e20`, `dBps` = `100`.
- No `useCowExit` composable exists. The mock `ZcWithdrawModal` is szipUSD-unaware (treats the balance as USDC dollars).

## Do NOT
- Do **not** bind `ExitGate.requestExit`/`cancelExit`/`processWindow` — **they do not exist** (retired, §6.4 /
  `ExitGate.sol:26-28`). Do **not** call `ExitGate.burnFor` from the UI — it is `onlyWindowController` (the CRE keeper).
- Do **not** route the junior exit through `ZipRedemptionQueue` or render a senior epoch/30-day **cooldown panel** — that
  is the senior zipUSD→USDC treasury off-ramp (`requestRedeem` is `onlyRedeemController`; a lender call **reverts**).
  Never conflate (spec §6 + `ZipRedemptionQueue.sol:14-17`).
- Do **not** add `@cowprotocol/cow-sdk` or any ethers dependency. viem `signTypedData` + `fetch` only.
- Do **not** hard-code the CoW settlement/relayer/usdc/szipUSD addresses in the composable — **read them live from
  `buyBurnModule`** (survives a redeploy; matches the FE-01 "derive from chain" seam).
- Do **not** re-implement the gas buffer — the `approve` MUST go through `useZipTx.sendZipTx`.
- Do **not** POST to the live `api.cow.fi` when `isCowLive` is false (the fork's szipUSD is not a real-Base token; the
  real solver/orderbook would reject it). Spoof the post + status locally; keep the `approve` + the EIP-712 sign real.
- Do **not** invent a par/$1 value for szipUSD — it is NAV-priced (~$107/share). Price the exit off `navExit` and the
  treasury `quoteMaxPrice`, both read on-chain. **No forfeit math, no haircut beyond the on-chain `dBps`.**
- Do **not** float-scale. szipUSD/navExit are 18-dp; USDC/`quoteMaxPrice` are 6-dp. bigint math; `formatUnits`/`parseUnits`.
- Do **not** stage built Vue/composables in the monorepo — commit to the **layer repo**; only this ticket lands here.

## Key requirements
1. **`useCowExit` — the exit spine.** Mirror `useZipPosition`'s shape (proxy-client reads, null-guarded, raw `bigint`s;
   the component formats). Expose:
   - `loadCowWiring(): Promise<CowWiring>` — one batched read off `buyBurnModule`: `{ settlement, vaultRelayer, usdc,
     szipUSD, domainSeparator, dBps, quoteMaxPrice }` (all from the live module). Returns all-`undefined` if `!client`.
   - `allowanceOf(user): Promise<bigint>` — `szipUsd.allowance(user, vaultRelayer)`.
   - `approveRelayer(sellAmount): Promise<void>` — `sendZipTx({ key: 'szipUsd', functionName: 'approve', args:
     [vaultRelayer, sellAmount] })`. (Approve exactly `sellAmount`, or `MaxUint256` for fewer future approvals — pick
     one; a Resolved decision below pins exact-amount.)
   - `buildOrder({ user, sellAmount, limitUsdc6, validTo }): GPv2SellOrder` — the 12-field struct above (kind = sell).
   - `signOrder(order): Promise<Hex>` — `useSignTypedData().signTypedDataAsync({ domain, types, primaryType: 'Order',
     message })`; `domain` from the live `settlement` + chainId 8453.
   - `submitOrder(order, signature): Promise<{ uid: string }>` — **live** (`isCowLive`): `POST {base}/api/v1/orders`
     with `{ ...order, signingScheme: 'eip712', signature, from: user }`; **spoof**: compute the uid locally (mirror
     `_orderUid`: `digest = keccak256(0x1901 ++ domainSeparator ++ structHash)`, `uid = digest ++ user ++ validTo`,
     viem `keccak256`/`encodeAbiParameters`/`encodePacked`) and register an in-memory order record `{ uid, status:
     'open', createdAtMs }`.
   - `orderStatus(uid): Promise<'open' | 'fulfilled' | 'cancelled' | 'expired'>` — **live**: `GET
     {base}/api/v1/orders/{uid}` → map CoW status; **spoof**: return `'open'` until a fixed sim delay after creation
     (representing the treasury just-in-time fill), then `'fulfilled'`.
   - `isCowLive: ComputedRef<boolean>` — `useRuntimeConfig().public.cowLive === true` (env `NUXT_PUBLIC_COW_LIVE`,
     **default false** → spoof on the fork; set `true` only on the mainnet deploy). Add the key to
     `nuxt.config.ts` `runtimeConfig.public` + `.env.example`.
2. **`ZcWithdrawModal` — the §6.4 status track.** Replace the mock entirely. Steps:
   - **input:** szipUSD amount (with a Max from `szipBal`); live preview of **two numbers**: "Sell now (treasury bid):
     `sellAmount × quoteMaxPrice / 1e18`" (6-dp USDC) and "Patient (≈ NAV): `sellAmount × navExit / 1e18 / 1e12`"
     (6-dp USDC) — so the holder sees **now vs waiting** (§6.4 legibility). A `gate()` guard: if `quoteMaxPrice == 0`
     or `szipBal == 0`, disable.
   - **approve (only if `allowance < sellAmount`):** two-phase loading via `useZipTx`; on success continue.
   - **sign + submit:** `buildOrder` → `signOrder` → `submitOrder`; show the wallet-sign prompt state.
   - **status track:** render the three §6.4 stages **Order resting (your limit) → Filled (treasury or market) →
     szipUSD burned**, polling `orderStatus(uid)` (one-shot watcher / a short bounded interval, **not** a perpetual
     poll — §17 no-heartbeat: stop on a terminal status). Show the live `navExit` mark + the standing treasury bid the
     whole time. On `fulfilled`, surface "szipUSD burned — NAV/share accretes to stayers" and emit `@success` so the
     page refreshes the position.
   - **cancel:** before submit, plain modal close. (There is **no on-chain cancel** for a resting EOA order in this
     ticket — an EOA cancels via the CoW API `DELETE`/signed cancellation; out of M1 scope, note it. The on-chain
     `cancelBid` is the *treasury's* bid, not the lender's.)
3. **Pricing + the limit (pin the math, no builder guess).** All bigint:
   - `treasuryUsdc6(sellAmount18) = sellAmount18 * quoteMaxPrice / 1e18` (USDC the treasury bid pays; `quoteMaxPrice` is
     already 6-dp-per-1e18-share, so dividing by `1e18` yields 6-dp USDC).
   - `navUsdc6(sellAmount18) = sellAmount18 * navExit / 1e18 / 1e12` (the un-discounted NAV ceiling in 6-dp USDC).
   - **Default `limitUsdc6 = treasuryUsdc6(sellAmount)`** → the order matches the standing treasury bid and fills
     immediately (best "exit now" UX). The user MAY raise the limit toward `navUsdc6` (wait for the market); never below
     `treasuryUsdc6` shown as the floor. `buyAmount = limitUsdc6`.
   - `validTo = nowSec + TTL`, `TTL` = a bounded constant (e.g. 20 min for the resting order; the treasury's own bids are
     ≤ 1 day per `MAX_BID_TTL` — keep the lender's well under that). Read `nowSec` from `Date.now()` (UI-side is fine).
4. **Domain self-check (closes the only off-chain-struct guess).** Before signing, compute the EIP-712 domain separator
   from `{ name: "Gnosis Protocol", version: "v2", chainId: 8453, verifyingContract: settlement }` and assert it equals
   the on-chain `buyBurnModule.domainSeparator()` (`0xd72ffa78…`). If they differ, **throw** (do not sign a
   mismatched-domain order) — this turns the GPv2 domain name/version (the one thing not in our ABI) into a verified,
   not-guessed, fact. viem: `domainSeparator(domain)` from `viem` (or hash the EIP-712 domain type yourself).
5. **Spoof is behind the interface, not the UI.** The modal calls the SAME `useCowExit` methods on mainnet and the fork;
   only `submitOrder`/`orderStatus` branch on `isCowLive`. The `approve` + `signOrder` are identical (real) on both. The
   status track, previews, and reads are identical. (Mainnet readiness is the point; the fork just can't run a solver.)
6. **Page integration.** `portfolio.vue` drops the mock `handleWithdraw` (the `store.ts` `withdraw()` mutation + the
   "arrives in your wallet" copy). Keep the mock hero/tabs. Wire `<ZcWithdrawModal :user="address"
   @success="() => positionRefreshKey++">` so a settled exit refreshes the FE-03 panel. The withdraw button opens the
   modal only when connected.

## Resolved decisions (close these — no builder guess)
- **szipUSD exit is the CoW book, full stop.** No `requestExit`/`cancelExit`/queue/cooldown. The resting order is the
  queue (§6.4). The only on-chain user write is `approve(vaultRelayer)`.
- **CoW wiring is read live from `buyBurnModule`**, not hard-coded. The addresses above are the *expected* live values
  (assert-able), not constants to bake in.
- **Order struct mirrors `SzipBuyBurnModule._orderUid` exactly**, flipping sell/buy/receiver/kind per the table. Same
  `TYPE_HASH`, `APP_DATA = 0`, `BALANCE_ERC20`, `feeAmount = 0`, `partiallyFillable = false`, 12-field order. `kind =
  keccak256("sell")` (`0xf3b2777…`, verified).
- **EOA signs EIP-712** (`signingScheme: "eip712"`), via `@wagmi/vue useSignTypedData`. The module's PRESIGN path is
  contract-only and irrelevant to the lender.
- **No `@cowprotocol/cow-sdk`** — viem `signTypedData` + `fetch`. The order struct is in-repo-verified; the API is a
  documented REST surface and is the spoofed leg.
- **`isCowLive` env-gated, default false.** Fork → spoof submit/status; mainnet build sets `NUXT_PUBLIC_COW_LIVE=true`.
  The `approve` + sign are always real.
- **Default limit = the treasury bid (`quoteMaxPrice`)** → instant fill; user may raise toward `navExit`. `navExit` and
  `quoteMaxPrice` are both read on-chain; `dBps` is display-only.
- **Reuse FE-03 `useZipPosition`** for `navExit` + `szipBal` (don't re-read; cross-link the redeemable value).
- **Approve exact `sellAmount`** (not MaxUint256) — minimal standing allowance for a one-shot exit; the
  `SzipBuyBurnModule` resets its own allowance to 0 after, mirror that conservatism.
- **No on-chain cancel of the lender's order in M1.** Pre-submit = modal close; post-submit = let it expire at `validTo`
  or (mainnet) a CoW API signed cancellation — noted as a deferred extension, not built.
- **Decimals.** szipUSD 18-dp, `navExit` 18-dp, USDC 6-dp, `quoteMaxPrice` 6-dp-per-1e18-share, `dBps` bps. bigint
  throughout; `formatUnits(x, 6)` for USDC display, `formatUnits(x, 18)` for szipUSD.

## Done when
- `npm run build` (`nuxt build`) is **green** in `frontend/zipcode-finance-euler/` (the gate — NOT `npm run dev`).
- `useCowExit` exists; `ZcWithdrawModal` runs the real exit (input → approve via `useZipTx` → EIP-712 sign → submit →
  the §6.4 status track), shows the live `navExit` + treasury bid, and binds **only** to surfaces the contracts actually
  expose; `portfolio.vue` drops the mock withdraw and refreshes the FE-03 panel on a settled exit.
- The domain self-check (Key req 4) passes against the on-chain `domainSeparator` (`0xd72ffa78…`).
- A cold-build subagent building from this ticket alone returns **zero load-bearing guesses** (every import, address,
  ABI method, the order struct/field order, the sell-kind hash, the price math, the spoof boundary, and the sign call
  resolve to a cited file/symbol).
- **Acceptance (anvil up, signer-supplied `NUXT_PUBLIC_APP_KIT_PROJECT_ID`, `NUXT_PUBLIC_COW_LIVE` unset → spoof):**
  connected with a szipUSD balance, the modal previews now-vs-waiting off the live oracle/module, the **real**
  `approve(vaultRelayer)` lands on the fork (allowance set — verifiable with `cast call szipUsd "allowance"`), the order
  is signed + (spoof) submitted, and the status track advances `open → fulfilled`. (If no project id for click-connect,
  the gate is the green `nuxt build` + the cold-build zero-guess verdict + the on-fork `approve` allowance check via a
  scripted signer; the click-through is the signer-supplied extension.)
- Committed to the **layer repo** (`resi-labs-ai`). PROGRESS updated: FE-04 done; the back-pressure finding logged;
  next `NEXT` set (FE-05).

## Critic triage — pinned details (close every gap; no builder guess)
The four critics returned **spec-fidelity PASS, back-pressure PASS, all bindings resolve**. The junior-dev gaps were
ticket-precision only — pinned here:

1. **REUSE euler-lite's CoW stack for the status track + explorer + cancel** (do NOT hand-roll polling). The base
   `extends`-parent exposes, from `~/entities/cowswap` (re-exported from `@eulerxyz/euler-v2-sdk`):
   `fetchCowSwapOrderStatus({ orderUid, chainId })`, `isCowSwapTerminalOrderStatus`, `resolveCowSwapOrderStatusType`,
   `getCowSwapOrderExplorerUrl(uid)`, `cancelCowSwapOrder(...)`, the `CowSwapOrderStatus`/`CowSwapOrderUid` types, and
   `COWSWAP_ORDER_POLL_INTERVAL_MS`/`COWSWAP_ORDER_POLL_MAX_DURATION_MS`. The composable
   `~/composables/cowswap/useCowSwapOrderStatus.ts` (`euler-lite/composables/cowswap/useCowSwapOrderStatus.ts`) is a
   bounded, terminal-aware, `onUnmounted`-cleaned poller — **use it directly for the live path** (`isCowLive`). It
   satisfies §17 no-heartbeat (it stops on terminal/`MAX_DURATION`). **Do NOT** reuse
   `useCowSwapExecutionCore`/`executeCowSwapTransactionPlan` — that builds Euler-*position* CoW plans (collateral
   swap / close), not a plain szipUSD→USDC ERC-20 sell; our order build/sign/post stays bespoke.
2. **EIP-712 signing — pin the `bytes32` form (matches our `TYPE_HASH` + `_orderUid`).** The on-chain canonical GPv2
   type our `SzipBuyBurnModule` hashes uses **`bytes32 kind`, `bytes32 sellTokenBalance`, `bytes32 buyTokenBalance`,
   `bytes32 appData`** (TYPE_HASH `0x1a59c8ff…`). So sign in that form so the digest matches `domainSeparator`:
   ```ts
   const domain = { name: 'Gnosis Protocol', version: 'v2', chainId: 8453, verifyingContract: settlement }
   const types = { Order: [
     { name: 'sellToken', type: 'address' }, { name: 'buyToken', type: 'address' },
     { name: 'receiver', type: 'address' }, { name: 'sellAmount', type: 'uint256' },
     { name: 'buyAmount', type: 'uint256' }, { name: 'validTo', type: 'uint32' },
     { name: 'appData', type: 'bytes32' }, { name: 'feeAmount', type: 'uint256' },
     { name: 'kind', type: 'bytes32' }, { name: 'partiallyFillable', type: 'bool' },
     { name: 'sellTokenBalance', type: 'bytes32' }, { name: 'buyTokenBalance', type: 'bytes32' } ] }
   const message = { sellToken: szipUSD, buyToken: usdc, receiver: user, sellAmount, buyAmount,
     validTo, appData: APP_DATA /*0x0…0*/, feeAmount: 0n, kind: KIND_SELL /*0xf3b2…*/,
     partiallyFillable: false, sellTokenBalance: BALANCE_ERC20, buyTokenBalance: BALANCE_ERC20 }
   const signature = await signTypedDataAsync({ domain, types, primaryType: 'Order', message })
   ```
   (`signTypedDataAsync` from `@wagmi/vue` `useSignTypedData` — **explicit import**, not auto-imported, like `useToast`.)
3. **Domain self-check (Key req 4) uses viem `domainSeparator`.** `import { domainSeparator } from 'viem'` →
   `domainSeparator({ domain })` must equal the on-chain `buyBurnModule.domainSeparator()` (`0xd72ffa78…`); throw on
   mismatch. (Confirmed exported by the installed viem 2.48.8.)
4. **Local uid for the spoof path** = viem `hashTypedData({ domain, types, primaryType: 'Order', message })` (that IS
   `keccak256(0x1901 ++ domainSeparator ++ structHash)`), then `uid = encodePacked(['bytes32','address','uint32'],
   [digest, user, validTo])` — mirrors `_orderUid` (`SzipBuyBurnModule.sol:334-335`). `hashTypedData`, `encodePacked`,
   `keccak256` all from `viem`.
5. **The live API POST (mainnet-only, the spoofed leg) maps the enum `bytes32`s to CoW's string form:**
   `POST {orderbookUrl}/api/v1/orders` with JSON `{ sellToken, buyToken, receiver, sellAmount: String, buyAmount:
   String, validTo: Number, appData: "0x000…0", feeAmount: "0", kind: "sell", partiallyFillable: false,
   sellTokenBalance: "erc20", buyTokenBalance: "erc20", signingScheme: "eip712", signature, from: user }`. The
   response uid + `fetchCowSwapOrderStatus` drive the track. This JSON mapping is **not fork-verifiable** (no CoW
   solver/clone); it is modeled on the documented CoW REST surface + euler-lite's SDK order shape, and is reached only
   when `isCowLive` (mainnet). The **fork-testable** parts (approve, EIP-712 sign, domain self-check, local uid) are
   fully grounded above. CSP already allows `https://api.cow.fi` (`euler-lite/server/plugins/csp.ts`).
6. **`isCowLive`.** Add `cowLive: 'false'` to `runtimeConfig.public` in `nuxt.config.ts` (string, matching the existing
   `configEnable*` entries) + `NUXT_PUBLIC_COW_LIVE=` to `.env.example`. Read `useRuntimeConfig().public.cowLive ===
   'true'` → default `false` (spoof on the fork). Branch ONLY `submitOrder`/`orderStatus` on it; approve + sign are
   always real.
7. **Pinned constants:** spoof open→fulfilled delay = `2500` ms; lender order `TTL` = `20 * 60` s (well under the
   treasury's `MAX_BID_TTL` 1 day). `useToast` import path: `import { useToast } from
   '~/components/ui/composables/useToast'` (per `ZcDepositModal.vue:164`).
8. **Limit validation:** default `limitUsdc6 = treasuryUsdc6(sellAmount)` (the floor = instant treasury fill); the user
   may RAISE toward `navUsdc6` but the submit button is **disabled** while `limitUsdc6 < treasuryUsdc6` (never sign a
   below-floor order). `buyAmount = limitUsdc6`.
9. **`@success` timing:** emit when the order reaches a terminal **fulfilled** status — live: `fetchCowSwapOrderStatus`
   resolves terminal-fulfilled; spoof: the 2500 ms timer flips to fulfilled. (A terminal `cancelled`/`expired` does NOT
   emit success.) Pre-submit modal close = plain no-op + `reset()` (clears any local spoof record).

## Depends on
FE-00 (layer boots — DONE), FE-01 (address book + typed ABIs — DONE), FE-02 (`useZipTx` write spine — DONE), FE-03
(`useZipPosition` `navExit`/`szipBal` reads — DONE). No open obligations against FE-04 in PROGRESS (confirmed during the
back-pressure check — the contract surfaces all exist; the missing `requestExit`/`cancelExit` were never owed, they were
retired by design). Reverse cross-link: the FE-03 panel's "redeemable ≈ $X / szipUSD" is the same `navExit` mark this
modal prices the patient exit at.
