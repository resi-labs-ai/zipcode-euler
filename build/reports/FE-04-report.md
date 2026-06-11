# FE-04 report — szipUSD junior exit via the CoW book (§6.4)

**Window:** 2026-06-11 · **Track:** Frontend ↔ anvil (the `zipcode-finance-euler` layer) · **Status:** DONE, gate green,
committed to the layer repo (`resi-labs-ai`, `5f6d170`). **NEXT:** FE-05 (borrower flow).

## What this window did
Replaced the mock withdraw path (`ZcWithdrawModal` → `store.ts` mutation) with the **real szipUSD junior exit** as the
contracts actually implement it: a CoW sell order priced off NAV, with the §6.4 status track. Three layer files +
`nuxt.config.ts` + `.env.example`; `npm run build` (nuxt build) green; committed to the layer repo (monorepo untouched).

- `composables/useCowExit.ts` — the CoW sell-order spine. Reads CoW wiring **live from the deployed
  `SzipBuyBurnModule`** (no hard-coded GPv2 addresses); `approveRelayer` via the FE-02 `useZipTx` spine; builds + signs
  the GPv2 order as the **mirror of our own `SzipBuyBurnModule._orderUid`** (bytes32 EIP-712 form, `kind =
  keccak256("sell")`) via `@wagmi/vue useSignTypedData`; a **domain self-check** (viem `domainSeparator` ==
  on-chain `0xd72ffa78…`) gates signing; `submitOrder`/`orderStatus` branch on `isCowLive`.
- `components/zipcode/ZcWithdrawModal.vue` — rewritten into the §6.4 track **Order resting → Filled → szipUSD burned**,
  with a now-vs-waiting preview (`quoteMaxPrice` treasury bid vs `navExit`).
- `pages/lender/portfolio.vue` — dropped the mock `handleWithdraw`; `@success` refreshes the FE-03 position panel.
- `nuxt.config.ts` `runtimeConfig.public.cowLive` + `.env.example` `NUXT_PUBLIC_COW_LIVE` — the mainnet/spoof toggle.

## The load-bearing decision this window (surfaced, user-resolved)
The original FE-04 row assumed user-callable exit **writes** (`requestExit`/`cancelExit` on `ExitGate`; a
`ZipRedemptionQueue` cooldown). The back-pressure check proved all of those are **wrong** (see PROGRESS finding). I
initially proposed downscoping to a read-only panel "because the fork has no CoW solver." **The user corrected the
framing:** the deploy target is **Base mainnet**; anvil is only a local fork — *"Do not prepare for a future which is
not real. Create a system that will work when we deploy to mainnet, and then spoof its functionality on anvil."* Saved
as the working principle `build-for-mainnet-spoof-on-anvil`. FE-04 was then built as the **real mainnet CoW exit**, with
only the un-forkable solver leg spoofed.

## Decisions to sanity-check (reviewer)
1. **Spoof boundary.** `isCowLive` (env `NUXT_PUBLIC_COW_LIVE`, default false) branches ONLY `submitOrder`/`orderStatus`.
   On the fork the `approve` + EIP-712 sign + domain self-check + local-uid are **real**; the CoW REST POST/poll is
   spoofed (a local 2500 ms open→fulfilled timer). On mainnet (`=true`) the real `POST /api/v1/orders` + the reused
   `fetchCowSwapOrderStatus` poller drive the track. **The live API POST JSON shape is the one leg not fork-verifiable**
   (no CoW solver/clone) — modeled on the documented CoW REST surface + euler-lite's SDK order shape. Worth a glance
   before mainnet.
2. **EIP-712 form.** Signed in the **bytes32** GPv2 form (`kind`/`*Balance`/`appData` as bytes32 hashes) to match our
   contract's `TYPE_HASH 0x1a59c8ff…` + `_orderUid`; the domain self-check makes this verifiable, not guessed. The live
   API maps those enums to CoW's string form (`kind:"sell"`, `sellTokenBalance:"erc20"`).
3. **Default limit = the treasury bid (`quoteMaxPrice`)** → instant fill; the user may raise toward `navExit`; submit is
   disabled below the floor. `dBps` (1% live) is read on-chain, display-only.
4. **Reuse split.** Reused euler-lite's `~/entities/cowswap` status/poll/explorer helpers; did NOT reuse
   `executeCowSwapTransactionPlan` (Euler-position-specific). The cold-build used the modal's own bounded poller
   (same constants/terminal-aware/onUnmounted) rather than wrapping `useCowSwapOrderStatus`, because `orderStatus`
   already branches live/spoof internally — faithful to §17 no-heartbeat.

## Holes → resolution
- **CoW REST POST shape unverifiable on the fork** → isolated behind `isCowLive`; never hit locally; all fork-testable
  legs are in-repo-grounded. Resolution: verify against the live CoW Base orderbook during mainnet bring-up.
- **No on-chain cancel for the lender's resting EOA order in M1** → pre-submit = modal close; post-submit = expire at
  `validTo` (20 min) or (mainnet) a CoW API signed cancellation. Noted as a deferred extension, not built.

## Doc edits
- `build/tickets/frontend/FE-04-exit-cow-book.md` — the ticket (with the critic-triage pinned-details section).
- `build/tickets/PROGRESS.md` — FE-04 → DONE; FE-05 → NEXT; the back-pressure finding logged in Open obligations/seams.
- **No `build/claude-zipcode.md` change** — §6.4 was already correct; the conflation lived only in the old PROGRESS row.
- Memory: `build-for-mainnet-spoof-on-anvil` (new working principle).

## Status + NEXT
FE-04 done; gate green; layer commit `5f6d170`; cold-build zero-guess; critics clean. **NEXT = FE-05** (borrower flow:
line-state reads + permissionless repay) — run its back-pressure check first (FE-04 proved it necessary): confirm which
`EulerVenueAdapter`/`ZipcodeController` surfaces are borrower-callable vs CRE/operator-gated before binding. **STOP for
review.**
