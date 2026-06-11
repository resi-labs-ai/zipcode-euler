# FE-01 report — Zipcode address book + typed ABI module

**Window:** 2026-06-10 · **Track:** Frontend ↔ anvil · **Spec §:** §5 · **Status:** DONE → NEXT is FE-02

## What this window did

Built the single dependency every later Zipcode screen (FE-02..07) imports: a typed address book + ABI module,
authored in the LAYER under `lib/zipcode/`, committed to the **layer repo** (`resi-labs-ai`, commit `6ec85b1`):

1. **`scripts/gen-zipcode-abis.mjs`** — a dev-time-only generator (never Vercel) that reads the monorepo's
   frozen `build/anvil/abi/index.json` + the referenced ABI JSONs and emits the two generated artifacts below.
   Re-run it after a redeploy to regenerate the whole foundation. The full `name → canonicalKey` table is
   embedded verbatim; an unknown name throws (no silent guess).
2. **`lib/zipcode/abi/*.ts`** — 46 generated `export default ([…]) as const` ABI files (the 52 index.json
   entries deduped: 3 EVaults → `IEVault`, 3 Safes → `GnosisSafe`, USDC/Loot/Shares → `ERC20`).
3. **`lib/zipcode/generated/registry.ts`** — `ZIPCODE_CONTRACTS`: every one of the 52 contracts →
   `{ address: Address, abi: <as-const> }`, shared ABI imports referenced once.
4. **`lib/zipcode/contracts.ts`** (hand-authored public surface) — re-exports `ZIPCODE_CONTRACTS`,
   `ZIPCODE_CHAIN_ID = 8453`, `ZipcodeContractKey = keyof typeof ZIPCODE_CONTRACTS`, `zipcodeRpcUrl()`, and
   `getZipcodeContract(key, client?)` (viem `getContract`, inline node/SSR `PublicClient` default).
5. **`scripts/verify-zipcode-binding.ts`** — the acceptance read (run with `npx tsx`).

The ticket (`build/tickets/frontend/FE-01-zipcode-address-abi-module.md`) was drafted against verified binding
targets, run through four critic subagents (junior-dev, spec-fidelity, reference-verifier, frontend-binding),
triaged, hardened, then cold-built by a fresh subagent to a green gate with zero residual load-bearing guesses.

## Gate — verified green

- `npm run build` (`nuxt build`) — **green** (`✨ Build complete!`). This is the gate, not `npm run dev`.
- `npx tsx scripts/verify-zipcode-binding.ts` (anvil up, block 47096192), through `getZipcodeContract`:
  - `getZipcodeContract('szipUsd').read.name()` → `"Zipcode Junior Vault Share"`
  - `getZipcodeContract('navOracle').read.navEntry()` → `107265000000000000000` (≈ 1.07e20, non-zero)
- Idempotency: re-running the generator produces a byte-identical `abi/` + `generated/` (no git diff).
- Address spot-check vs `contract-map.md`: all 8 match (`szipUsd 0x33aD…`, `zipUsd 0xC5bd…`, `depositModule
  0x6ecc…`, `navOracle 0x0C3E…`, `exitGate 0xd9b8…`, `redemptionQueue 0x46c8…`, `venueAdapter 0x87dC…`,
  `controller 0x3602…`).

## Holes the harness surfaced → resolution

- **`navPerShare()` does not exist on the deployed `SzipNavOracle`** (the example read in the harness/PROGRESS
  FE-01 done-when + the FE-03 row + INFLOW-06). The real views are `navEntry`/`navExit`/`spotNavPerShare`/
  `twapNavPerShare`. Triaged per harness §1 (contract is truth) as a **rename, not back-pressure — no contract
  change owed**. Resolution: verify read binds to `navEntry()`; logged as a seam in PROGRESS "Open obligations";
  the stale `navPerShare` reference in the PROGRESS FE-03 row was corrected to `navEntry`/`navExit`.
- **`node *.mjs` can't import `.ts`; the `~` nuxt alias doesn't resolve in a standalone script.** Resolution:
  the verify script is `.ts` run with `npx tsx`, imports `contracts.ts` by relative path; `contracts.ts` builds
  its default client inline with viem (no euler-lite `getPublicClient`, no `~`). Folded into the ticket Do-NOTs.
- **Write path.** FE-02/04/05 writes use `@wagmi/vue` `sendTransactionAsync` + `encodeFunctionData`, not viem
  `writeContract` — so the write surface is the raw `ZIPCODE_CONTRACTS[key] = {address, abi}`, documented in the
  getter JSDoc. `getZipcodeContract` is the READ convenience only.
- **Browser CORS.** The inline default client direct-reads `127.0.0.1:8545` (node/SSR only). Browser screens
  must pass euler-lite's proxy client (`useRpcClient().client` → `/api/rpc/8453`). Documented, not built here.
- Minor ticket imprecisions caught by the cold build (entry count 50→52; ABI-path base dir; `tsx` not vendored
  so `npx tsx` auto-fetches it) — all corrected in the ticket; none changed the code.

## Decisions to sanity-check

- **The whole `index.json` board is included (52 contracts, all `kind`s incl. external/standin/demo)**, not just
  the FE-02..07 short-list — so every later screen needs only this one import. `index.json` is treated as "the
  FE board" and deliberately excludes dev-account EOAs / the EVK GenericFactory / the raw showcase vAMM
  pair+gauge (the showcase *oracle* + *module* ARE included). If a showcase screen later needs the vAMM
  pair/gauge, add them to `index.json` and re-run the generator.
- **ABIs are committed INTO the layer (generated), not imported from `build/anvil/`** — required because the
  layer builds standalone on Vercel and can't read the monorepo. The generator's monorepo read is dev-time only.
- **No spec (`claude-zipcode.md`) edit this window** — every finding was a ticket-clarity gap or a
  contract-vs-prose rename, not an under-defined mechanism.

## Status + NEXT

FE-01 DONE, committed to the layer (`6ec85b1`), gate green. **NEXT = FE-02** (supply/zap: wire `ZcDepositModal`
→ real `useZipDeposit` over the FE-01 registry + ship the shared 1.3× EVC gas-buffer tx helper). Anvil must be
up for FE-02's write acceptance; a live signer needs a real `NUXT_PUBLIC_APP_KIT_PROJECT_ID`.
