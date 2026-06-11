# FE-07 — Euler-native vault dashboard: surface the real reservoir EVK market + senior EE pool through euler-lite's OWN lend/borrow/earn pages

> The euler-native counterpart to FE-06 (the Zipcode-protocol dashboard). FE-06 read the Zipcode contracts directly;
> FE-07 makes euler-lite's **own** lend/borrow/earn surfaces render the live fork's **real Euler markets** — the
> reservoir EVK borrow + escrow vaults and the senior `EulerEarn` pool — through euler-lite's existing data layer.
> **Config + labels only — no new Zipcode composables, no contract writes.** The contract is truth (harness §1): the
> back-pressure check below confirms every surface already exists and the markets already *render* from FE-00's labels;
> the new work is the `entities.json` **addresses map** that upgrades them from a rendered-but-**unverified** chip to a
> rendered-**verified** badge — euler-lite's native curation gate. Two findings are logged (a contract obligation + a
> fork-state limitation), neither owed by FE-07.

## Deliverable
Make euler-lite's native pages render the real fork vaults **with the verified presentation**. The mechanism is
euler-lite's own (no Zipcode override files): the server snapshot (`server/utils/vaults-cache.ts → refreshChainVaults`)
already sources the vault list from FE-00's `public/labels/8453/{products,earn-vaults}.json`; the only missing piece is
the **entity governance declaration** that euler-lite's verification gate matches against. Ship:

1. **`public/labels/8453/entities.json`** — add an `addresses` map to the existing `zipcode` entity declaring the
   real on-chain governance authorities of the reservoir vaults + EE pool (the exact addresses + the schema are below).
   This is the whole functional change. Keep `name`/`description`/`url` as FE-00 set them.

No other files change. (FE-00 already wrote `products.json` with the 3 reservoir EVK vaults under the `zipcode-reservoir`
product and `earn-vaults.json` with the senior EE pool; FE-00 also repointed RPC + labels-base + vault-source. FE-07
adds the one map FE-00 left empty.)

## Spec §
- **§4.7** — venue-agnostic; **Euler = config one**. FE-07 is literally "show the Euler venue's native market through
  the Euler-native UI." No new mechanism — euler-lite already lends/borrows/earns against any EVK/EE market it is told
  about; we are only telling it (via labels/entities) that these fork vaults are ours.
- §17 locked decisions honored: no economic-liquidation surface added, no spec mechanism invented, build-phase wiring
  is the live fork's. This ticket adds **no on-chain surface and no write path**.

## Binds to (verified against the live fork @ `127.0.0.1:8545`, chainId 8453)
| Surface | Address | ABI / source | Role |
|---|---|---|---|
| reservoir borrow vault (USDC) | `0x1aFc8c641BE6E8a0849f00f3c90a27D44710D267` | `external/IEVault.json` | the borrow market (lend + borrow pages) |
| reservoir escrow vault (LP collateral) | `0x8A5FA36779693584E0e52246f05C5b0bF55Df1b1` | `external/IEVault.json` | borrow-pair collateral |
| base USDC market (resting; supply-queue head) | `0x3A48aaaa90CF3938290f12F6A1E58C1aeb54699D` | `external/IEVault.json` | a lend market |
| senior EulerEarn pool (USDC) | `0x1a7A8A5a6A2B34895201CFBC997C4eC419ba8A3d` | `external/EulerEarn.json` | the earn page |

These are the contract-map addresses already in FE-00's `products.json` (`zipcode-reservoir.vaults[]`) and
`earn-vaults.json`. FE-07 does NOT touch those two files — it binds to the **on-chain governors/owners** of these
vaults (read live, below) and declares them on the entity.

### The governance addresses to declare (read live; EIP-55 checksummed — `hasEntityAddress` is a case-sensitive `Object.keys(...).includes()`)
| Address | What it governs on-chain | Read |
|---|---|---|
| `0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa` | reservoir borrow vault `governorAdmin` (the `ReservoirMarketDeployer` instance — see Finding A) | `cast call 0x1aFc… "governorAdmin()(address)"` |
| `0x89ae086561ed831C4f5ebF31d825f0364C8c3B27` | TimelockController — the reservoir EulerRouter `governor()` (and the protocol root, contract-map "Roots") | `cast call 0x5a451f… "governor()(address)"` |
| `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `team` — base USDC market `governorAdmin` **and** the EE pool `owner()` | `cast call 0x3A48… "governorAdmin()"` / `cast call 0x1a7A… "owner()"` |

Every declared address is a **real, live zipcode-controlled address on the fork** (the contract-map principals /
Timelock / the deployer it created) — this declares fact, it does not fabricate trust.

**The three addresses in the table above are the verified live-read values (read against `127.0.0.1:8545` and
checked against `build/anvil/contract-map.md`) — use them verbatim. No re-derivation is needed**; the `cast` commands
are shown only so the values can be re-confirmed after a redeploy (see Finding A's fragility note). They are already
EIP-55 checksummed.

### The exact final file (assemble verbatim — this is the whole deliverable)
`public/labels/8453/entities.json`:
```json
{
  "zipcode": {
    "name": "Zip Code Finance",
    "description": "On-chain home-equity credit warehouse on Base.",
    "url": "https://zipcode.finance",
    "addresses": {
      "0x77C2Cb207Ee27F8fB5Fc1586da3Bfef40Fba3ffa": "Reservoir market deployer (borrow-vault governor)",
      "0x89ae086561ed831C4f5ebF31d825f0364C8c3B27": "Timelock (router governor / protocol root)",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266": "Team multisig (base-market governor / EE owner)"
    }
  }
}
```
Keep `name`/`description`/`url` exactly as FE-00 set them; only the `addresses` object is added. (`EulerLabelEntity`'s
`logo`/`social` fields are optional and FE-00 omitted them — the loader tolerates a partial entity, accessing
`entity.addresses ?? {}`; do not add them.)

## Starting state
- FE-00 done (`resi-labs-ai` `1ace24b`): RPC→`127.0.0.1:8545`, `NUXT_PUBLIC_BROWSER_VAULT_SOURCE=onchain`,
  labels-base→`http://127.0.0.1:3000/labels`, and `public/labels/8453/{products,earn-vaults,entities}.json` populated.
  Current `entities.json` `zipcode` entry has **no `addresses` field**.
- Live anvil up (Base fork @47096000, chainId 8453). `cast block-number` responds.
- euler-lite is a read-only submodule; **do not edit inside `euler-lite/`** — only the layer's `public/labels/...`.

## How euler-lite consumes this (the mechanism — verified, do NOT re-architect)
- **List inclusion = label membership, NOT governor matching.** `server/utils/vaults-cache.ts:refreshChainVaults`
  reads `products.json` `vaults[]` + `deprecatedVaults[]` → `verifiedVaultAddresses` and `earn-vaults.json` → `earnVaults`,
  fetches them via the SDK, and the client hydrate marks every snapshot vault `verified:true` from membership
  (`composables/useVaults.ts:200,255,615`; `verifiedAddresses = new Set(eVaultAddresses…)` at `:712-717`).
  `getVerifiedEVaults()` (`useVaultRegistry.ts:174`) and `isVerifiedVault()` (`:198`) filter on that membership flag.
  ⇒ **the reservoir + EE vaults already render on lend/borrow/earn from FE-00 alone** (the lend list at
  `pages/lend/index.vue:27`, the borrow pairs at `pages/borrow/index.vue:62` via `borrowList`, the earn list at
  `pages/earn/index.vue:30`).
- **Verified BADGE = governor/owner ∈ the product's declared entity addresses.** The display components
  (`components/entities/vault/VaultItem.vue:23-27`, `VaultEarnItem.vue:18-21`, `VaultBorrowItem.vue:20-28`,
  `VaultTypeChip.vue`, `DiscoveryMarketAttributeMatrix.vue`) call `useVaults().isVaultGovernorVerified` /
  `isEarnVaultOwnerVerified`, which run `utils/vault/governor-verification.ts`. The rule
  (`isVaultGovernorVerified`): for a vault in a product, `getDeclaredEntityKeys` → the product's `entity` (`"zipcode"`)
  → and `hasEntityAddress("zipcode", governorAdmin)` must be true, plus the EulerRouter `governor` must also match.
  `hasEntityAddress` (`useVaults.ts:1076-1078`) = `Object.keys(entities["zipcode"].addresses ?? {}).includes(address)`
  where `address` is `getAddress(governor)` (checksummed). With no `addresses` map, this is false ⇒ the reservoir
  market currently shows an **unverified** chip. Declaring the three governors above flips it to **verified**.
- **EE pool**: `isEarnVaultOwnerVerified` — the EE pool is in `earn-vaults.json` but NOT in `products.json`, so
  `getDeclaredEntityKeys` returns `undefined` ⇒ the rule trusts it on earn-list membership alone and returns `true`
  **even without** an entities address (`governor-verification.ts:99-107`). Declaring its owner (`team`,
  `0xf39Fd…`) is harmless and future-proofs the pool if it is ever added to a product, but is not strictly required for
  the earn page. (It IS required so the base USDC market and reservoir borrow vault verify — see the table.)

## Key requirements
1. **Edit only `public/labels/8453/entities.json` in the layer.** Add `"addresses"` to the `zipcode` entity as a
   `Record<checksummedAddress, label>` (the `EulerLabelEntity.addresses: Record<string,string>` type,
   `euler-lite/entities/euler/labels.ts:6`). Keys = the three checksummed addresses from the table; values = short
   honest labels (e.g. `"Reservoir market deployer (governor)"`, `"Timelock (router governor / protocol root)"`,
   `"Team multisig (base-market governor / EE owner)"`). Do not invent addresses not read from the fork.
2. **Checksum the keys.** They must byte-equal `getAddress(governor)`. The three `cast` outputs above are already
   EIP-55; if regenerating, run each through `viem getAddress`. A lowercase key silently fails the badge.
3. **Do not edit `products.json` or `earn-vaults.json`** — FE-00 set them correctly; re-deriving them is out of scope.
4. **Do not add Zipcode composables / components / overrides.** FE-07 is config; euler-lite's native pipeline does the
   rendering. No `lib/zipcode/*`, no `components/zipcode/*`, no `useZip*`.
5. **Do not edit anything under `euler-lite/`** (read-only submodule).
6. **Back-pressure check is satisfied with no obligation owed** — every surface euler-lite needs (the SDK reads off
   `IEVault`/`EulerEarn`, the governor/owner views, the labels pipeline) already exists. Confirm this; do not invent
   around anything.

## Findings to record (NOT FE-07 scope to fix — log at Conclude)
- **Finding A — contract obligation (back-pressure owed to the contract track, NOT FE-07):** the reservoir **borrow
  vault's `governorAdmin` is the throwaway `ReservoirMarketDeployer` instance `0x77C2Cb…`, never transferred to the
  Timelock.** `ReservoirMarketDeployer.sol:88` transfers only the **router** governance to `p.governor` (the Timelock);
  the borrow vault is created via `factory.createProxy` (deployer = governor at birth, `:77`) and never gets
  `setGovernorAdmin(p.governor)`. The comment at `:75` ("Governor RETAINED so the Timelock can tune LTV/caps") is wrong
  for the borrow vault — the Timelock cannot govern it. FE workaround: declare the live deployer address so the market
  verifies today; once the contract transfers borrow-vault governance to the Timelock, the live `governorAdmin` becomes
  `0x89ae…` (already declared) and the deployer entry can be dropped. **Fragility note:** `0x77C2Cb…` is nonce-derived;
  a deploy-script change can move it → re-read `governorAdmin()` and update the entity after any redeploy.
- **Finding B — fork-state limitation (no obligation, no config fix):** the reservoir **escrow collateral vault
  `0x8A5F…` is fork-deployed, so it is absent from Base's real `escrowedCollateralPerspective`** that
  `utils/vault/categories.ts:fetchEscrowAddressSet` reads → euler-lite classifies it `evk`, not `escrow`. Escrow vaults
  auto-pass `isVaultGovernorVerified` (`governor-verification.ts:64`), but this one won't, and its `governorAdmin` is
  `0x0` (undeclarable). ⇒ the borrow **pair still renders** (it's in `borrowList` via membership + `borrowLTV>0`), but
  the collateral leg shows an **unverified** chip in `VaultBorrowItem`. This is a fork-state limitation (mirrors FE-05's
  closed-line caveat), not a contract gap and not config-fixable. Acceptable for the MVP.

## Done when
- `npm run build` (`nuxt build`) green in `frontend/zipcode-finance-euler/` — the gate is the build process exiting 0
  with no errors (NOT `npm run dev`, which EMFILE-floods; NOT a test-suite run — the JSON edit can't break TS types).
- Against the live anvil (build + `node .output/server/index.mjs`, env exported per FE-00's `.env`, `HOST=127.0.0.1
  PORT=3000`): `/api/vaults?chainId=8453` returns a snapshot containing the reservoir borrow vault, base USDC market,
  escrow vault (as evk), and the EE pool; and `/api/labels/entities.json?chainId=8453` returns the `zipcode` entity
  with the three addresses. (Page-route render is the same data path; the `/api/*` reads are the headless-verifiable
  proof — wallet-connect needs a Reown id per FE-00, out of scope here.)
- The committed `entities.json` declares exactly the three checksummed governors with honest labels.
- Committed to the **layer repo** (`resi-labs-ai`): run `git commit` **inside** `frontend/zipcode-finance-euler/`
  (it has its own `.git`, remote `origin = resi-labs-ai/zipcode-finance-euler`); the monorepo gitignores that path, so
  never `git add` the layer from the monorepo root.

## Depends on
- FE-00 (labels + RPC + vault-source config) — done.
- Live anvil deploy (item-10 / REAL-EE smoke deploy) — done; addresses per `build/anvil/contract-map.md`.
