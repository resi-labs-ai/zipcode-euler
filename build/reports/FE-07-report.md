# FE-07 report — Euler-native vault dashboard (reservoir EVK market + senior EE pool via euler-lite's native pages)

**Window:** 2026-06-11 · **Track:** Frontend ↔ anvil (the **last** FE-anvil item) · **Spec §:** §4.7
**Commit:** layer repo `resi-labs-ai` `85f6908` · **Gate:** `nuxt build` green + live-verified against the anvil fork.

## What the window did
FE-07 makes euler-lite's **own** lend/borrow/earn pages render the live fork's **real Euler markets** — the reservoir
EVK borrow + escrow vaults, the base USDC market, and the senior `EulerEarn` pool. Config + labels only: **no Zipcode
composables, no contract writes, no euler-lite edits.**

The substantive discovery (from the back-pressure check, before writing any code):
- **The vaults already *rendered* from FE-00's labels.** euler-lite's server snapshot (`vaults-cache.ts:
  refreshChainVaults`) sources the vault list from `products.json` (`zipcode-reservoir.vaults[]` → evk) +
  `earn-vaults.json` (→ earn), and **list inclusion = label membership** (`getVerifiedEVaults`/`isVerifiedVault` filter
  the `verified` flag, which is set true on snapshot membership), NOT governor matching.
- **The missing piece was only the verified BADGE.** The display components run `governor-verification.ts`, which needs
  the product's declared **entity** to list the vault's on-chain `governorAdmin` + the EulerRouter `governor`. FE-00's
  `zipcode` entity had **no `addresses` map**, so the reservoir market showed an *unverified* chip.

**Deliverable (one file):** added an `addresses` map to the `zipcode` entity in
`public/labels/8453/entities.json` declaring the three real, live on-chain governance authorities:

| Address | Governs | Source |
|---|---|---|
| `0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa` | reservoir borrow-vault `governorAdmin` (the `ReservoirMarketDeployer` — see Holes) | `IEVault.governorAdmin()` |
| `0x89ae086561ed831C4f5ebF31d825f0364C8c3B27` | Timelock — reservoir EulerRouter `governor()` + protocol root | `EulerRouter.governor()` |
| `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | team — base USDC market `governorAdmin` + EE pool `owner()` | `IEVault.governorAdmin()` / `EulerEarn.owner()` |

Keys are EIP-55 checksummed (`hasEntityAddress` is a case-sensitive `Object.keys(addresses).includes(getAddress(gov))`).

## Gate (green)
- `npm run build` (`nuxt build`) → `✨ Build complete!`.
- Built + served (`node .output/server/index.mjs`, env exported, `HOST=127.0.0.1 PORT=3000`) against the live anvil:
  - `GET /` → 200.
  - `GET /api/labels/entities.json?chainId=8453` → the `zipcode` entity with the three addresses.
  - `GET /api/vaults?chainId=8453` → **all four fork vaults**: reservoir borrow `0x1aFc`, escrow `0x8A5F`, base USDC
    `0x3A48` in `evkVaults` (=3); EE pool `0x1a7A` in `earnVaults` (=1). (Wallet-connect click-through needs a Reown id
    per FE-00 — the `/api/*` reads are the headless-verifiable proof; the page routes are the same data path.)

## Critics
- **spec-fidelity: ALL PASS** — §4.7 faithful (this is literally the "Euler = config one" leg), §17 honored (no
  economic-liquidation surface, no mechanism, no write path), no inbound obligation; declaring a live zipcode-controlled
  address is fact-not-fabrication, acceptable under §17 build-phase permissiveness.
- **reference-verifier:** every binding resolves — the three governor reads confirmed live, schema
  (`EulerLabelEntity.addresses: Record<string,string>`), case-sensitivity, the EE `declaredKeys===undefined` auto-pass,
  and the membership-based list inclusion. Confirmed Finding A (the *contract* never transfers the borrow-vault
  governor) and that FE-00's `entities.json` lacked `addresses`.
- **frontend-binding: back-pressure PASS** — all four vaults render through the native pipeline, **no obligation owed**
  (every read already exists on `IEVault`/`EulerEarn`), Finding B confirmed, no hidden filters
  (notExplorable/deprecated/restricted/geo/asset-allowlist/perspective all clear), and the base USDC market `oracle()`
  is `0x0` so the router-governor verification gate short-circuits → it verifies on `team` alone.
- **junior-dev:** only clarity gaps (no spec/mechanism issue). Triaged as **ticket gaps** and fixed before cold-build:
  the ticket now spells out the **exact final `entities.json` verbatim**, states the table addresses are the verified
  live-read values (use as-is), and pins the build gate + the layer-repo commit target.

Cold-build is zero-guess by construction (the ticket gives the final file verbatim); the substantive proof is the green
build + the three live endpoint checks.

## Decisions to sanity-check
1. **Declaring the throwaway deployer `0x77C2Cb…` as a zipcode governance address.** It is the live, real
   `governorAdmin` of the reservoir borrow vault and is a zipcode-deployed contract, so the declaration states fact and
   makes the flagship reservoir market show as **verified** for the demo. The cleaner end-state is the contract fix
   (Finding A) that transfers borrow-vault governance to the Timelock (`0x89ae…`, already declared), after which the
   deployer entry is dropped. If you'd prefer the UI show the reservoir market as *unverified* until that contract fix
   lands (rather than verify against the deployer), remove the first address — the market still renders, just without
   the badge. I chose to declare it (best demo + every declared address is genuinely zipcode's).
2. **base USDC market surfaced as a zipcode product.** It's the resting supply-queue head (reservoir plumbing), carried
   over from FE-00's `products.json`. It renders as a lend market labelled "Zip Code Reservoir." Harmless; flag if you
   want it hidden (a `notExplorableLend` vault override would do it without dropping it from the snapshot).

## Holes → resolution
- **Finding A (contract obligation, logged in PROGRESS "Open obligations"):** `ReservoirMarketDeployer.deploy` transfers
  only the **router** governance to the Timelock (`:88`); the borrow vault's `governorAdmin` is never moved off the
  deployer. The `:75` comment ("Governor RETAINED so the Timelock can tune LTV/caps") is wrong for the borrow vault.
  **Fix owed to the contract track:** add `IEVault(borrowVault).setGovernorAdmin(p.governor)`. Not an FE back-pressure
  (no missing UI surface); owed to contracts. Fragility: `0x77C2Cb…` is nonce-derived — re-read after any redeploy.
- **Finding B (fork-state limitation, no obligation, no config fix):** the fork-deployed escrow collateral `0x8A5F` is
  absent from Base's `escrowedCollateralPerspective` → classified `evk` not `escrow` (confirmed: it's in the `evkVaults`
  bucket) → `governorAdmin` `0x0` (undeclarable) → the borrow pair renders but the collateral leg shows an *unverified*
  chip. Also cosmetic: the LP collateral has no fork USD price (`priceService SOURCE_UNAVAILABLE`). Both resolve with
  the post-MVP Hydrex/Base escrow + LP-price plumbing.

## Doc edits
- `build/tickets/frontend/FE-07-euler-native-vault-dashboard.md` — filed.
- `build/tickets/PROGRESS.md` — FE-07 marked DONE; "Just done — FE-07" section added; FE-06 demoted to "Done earlier";
  NEXT set to **CRE-00**; the **Frontend ↔ anvil track marked COMPLETE**; Finding A logged as a contract obligation.
- `build/claude-zipcode.md` — **no change** (§4.7 already correct; FE-07 invented nothing).

## Status + NEXT
- **FE-07 DONE.** The **Frontend ↔ anvil track is COMPLETE** (FE-00…FE-07). The skinned app is interactive against the
  live local protocol; euler-lite's native pages render the real fork Euler markets.
- **NEXT = CRE-00** — the CRE (Go → wasip1) track scaffold + the shared §8.0 report-encoding package. Head of the
  remaining build work. **STOP for review.**
