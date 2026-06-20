# FE-01 — Zipcode address book + typed ABI module in the layer (the shared FE dependency)

**Track:** Frontend ↔ anvil · **Spec §:** §5 · **Status:** NEXT
**Built code lands in:** the LAYER repo `frontend/zipcode-finance-euler/` (own `.git`, remote `resi-labs-ai`)
— never staged in the monorepo. The *ticket file* (this doc) lands in `build/tickets/frontend/`.

---

## Deliverable

The single dependency every later Zipcode composable (FE-02..07) imports: a **typed address book + ABI
module**, authored in the LAYER under `lib/zipcode/` (alongside the existing `lib/zipcode/store.ts` /
`data.ts`). It maps each deployed contract → its anvil address (typed viem `Address`) and → its ABI
(a typed `as const`), and exposes a one-call viem contract getter bound to the fork.

Concretely, all committed to the **layer repo**:

1. **`lib/zipcode/abi/<Name>.ts`** — one file per distinct ABI, `export default ([...]) as const`, so viem
   infers method/event types. These are **generated** (step 2) from the monorepo's frozen anvil ABIs and
   **committed into the layer** (the layer is built standalone on Vercel — it CANNOT read `build/anvil/` at
   build time, so the ABIs must live inside the layer, not be imported across the repo boundary).
2. **`scripts/gen-zipcode-abis.mjs`** — a dev-time Node generator (run locally, never on Vercel) that reads
   `../../build/anvil/abi/index.json` + the referenced ABI JSONs and emits the `abi/*.ts` consts **and**
   `lib/zipcode/generated/registry.ts` (below). Re-running it after a redeploy regenerates the whole
   foundation. (The `abi` field in `index.json` is a path relative to `build/anvil/` — e.g. `abi/SzipUSD.json`,
   `abi/external/IEVault.json` — so join it onto the monorepo `build/anvil/` dir, NOT `build/anvil/abi/`.)
   Its provenance + run command are documented in a header comment. The full `name → canonicalKey`
   table it uses is fixed in **"Canonical key table"** below — embed it verbatim in the generator (keyed by
   `index.json`'s `name` field; names are stable across redeploys even though addresses change).
3. **`lib/zipcode/generated/registry.ts`** (generator output, committed) — imports every `abi/*.ts` const and
   exports `ZIPCODE_CONTRACTS` as a `const`-asserted object: `{ [canonicalKey]: { address: Address, abi } }`
   for every entry in `index.json`. Keys are emitted in `index.json` iteration order (for a stable, no-diff
   re-run); the `abi` value of each entry references the single shared imported const for that ABI file
   (so the 3 EVault keys all point at the one `IEVault` import — see dedup rule below).
4. **`lib/zipcode/contracts.ts`** (hand-authored, the public import surface) — re-exports `ZIPCODE_CONTRACTS`,
   `ZIPCODE_CHAIN_ID = 8453`, `type ZipcodeContractKey = keyof typeof ZIPCODE_CONTRACTS`, a `zipcodeRpcUrl()`
   helper (`process.env.RPC_URL_8453 ?? 'http://127.0.0.1:8545'`), and **`getZipcodeContract(key, client?)`**
   which returns a viem `getContract({ address, abi, client })` instance. When `client` is omitted it builds a
   read-only `PublicClient` **inline with viem** (`createPublicClient({ transport: http(zipcodeRpcUrl()) })`)
   — do NOT import euler-lite's `getPublicClient` via the `~` alias (that alias only resolves inside the nuxt
   build, not in a standalone `tsx`/node script, and would break the verify step + any node-side read). The
   inline client is the node/SSR-config default; **browser screens (FE-02..07) pass euler-lite's proxy client**
   (`useRpcClient().client` → `/api/rpc/8453`) as the `client` arg, because a direct `http://127.0.0.1:8545`
   read CORS-fails from the browser. State that contract in a JSDoc on `getZipcodeContract`.
5. **`scripts/verify-zipcode-binding.ts`** — the acceptance read (step "Done when" #4): a standalone viem
   script, **run with `npx tsx`** (the layer authors scripts in TS — see `package.json` `prototype:build`;
   note `tsx` is not vendored, so `npx tsx` auto-fetches `tsx@4.x` into the npx cache on first run — fine
   online/cached), that imports `contracts.ts` by **relative path** (`../lib/zipcode/contracts.ts`, no `~`
   alias) and prints two reads off the fork through `getZipcodeContract`.

This fills the INFLOW-06 "post-deploy address slots" with the real anvil addresses and supersedes its
`useZipcodeAddresses.ts` / `reference/euler-lite/abis/zipDepositModule.ts` placement (those went in
`reference/euler-lite`; the real home is the LAYER's `lib/zipcode/`).

---

## Binds to (verified by inspection 2026-06-10)

| Surface | Where | Note |
|---|---|---|
| address→{name,abi,kind} resolver | `build/anvil/abi/index.json` (52 entries) | the generator's input; `abi` is a path relative to `build/anvil/` |
| addresses (human board) | `build/anvil/contract-map.md` | cross-check the generated address book against this |
| ABI JSONs | `build/anvil/abi/*.json` + `build/anvil/abi/external/*.json` | bare JSON arrays from `forge inspect` (verified: `SzipUSD.json` is a 31-element array) |
| browser proxy-client pattern (for FE-02..07 to pass in) | `euler-lite/composables/useRpcClient/index.ts` → `useRpcClient().client` (a `PublicClient` over `/api/rpc/{chainId}`) | the browser-safe read path; FE-01's default inline client is node/SSR-only |
| euler-lite ABI/address convention to MODEL | `euler-lite/abis/*.ts` (`as const` fragments), `euler-lite/composables/useEulerAddresses.ts` | model the *shape*; author in the layer, not euler-lite |
| existing Zipcode FE home | `lib/zipcode/store.ts`, `lib/zipcode/data.ts` (imported as `../lib/zipcode/...`) | put the new module beside these |
| viem | `euler-lite/node_modules/viem` 2.48.8 | resolvable via the symlinked `node_modules` |

## Canonical key table (embed verbatim in the generator — keyed by `index.json` `name`)

The generator drives off `index.json` (52 entries at authoring). For each entry: emit/look-up the ABI const
(dedup rule below) and assign the `key` from this table. If a future redeploy's `index.json` adds a `name` not
in this table, the generator MUST throw (no silent guess) so the table is extended deliberately.

| `index.json` name | key | name | key |
|---|---|---|---|
| `TimelockController` | `timelock` | `WarehouseAdminModule` | `warehouseAdminModule` |
| `ZipcodeController` | `controller` | `xALPHA (MockERC20)` | `xAlpha` |
| `EulerVenueAdapter` | `venueAdapter` | `ZeroIRM` | `zeroIrm` |
| `ZipcodeOracleRegistry` | `oracleRegistry` | `EulerEarn pool` | `eePool` |
| `CREGatingHook` | `creGatingHook` | `base USDC market (EVault)` | `usdcReservoir` |
| `LienTokenFactory` | `lienTokenFactory` | `farm utility borrow vault (EVault)` | `farmUtilityVault` |
| `zipUSD (ESynth)` | `zipUsd` | `farm utility escrow vault (EVault)` | `farmUtilityEscrowVault` |
| `szipUSD` | `szipUsd` | `farm utility EulerRouter` | `farmUtilityRouter` |
| `ZipDepositModule` | `depositModule` | `main Safe` | `mainSafe` |
| `ExitGate` | `exitGate` | `sidecar Safe` | `sidecarSafe` |
| `SzipNavOracle` | `navOracle` | `warehouse Safe` | `warehouseSafe` |
| `ZipRedemptionQueue` | `redemptionQueue` | `Baal DAO` | `baalDao` |
| `SzipFarmUtilityLpOracle` | `farmUtilityLpOracle` | `Loot` | `loot` |
| `SzipBuyBurnModule` | `buyBurnModule` | `Shares` | `shares` |
| `FarmUtilityLoopModule` | `farmUtilityLoopModule` | `USDC` | `usdc` |
| `LpStrategyModule` | `lpStrategyModule` | `CoW GPv2Settlement` | `cowSettlement` |
| `HarvestVoteModule` | `harvestVoteModule` | `POL ICHI vault` | `ichiVault` |
| `ExerciseModule` | `exerciseModule` | `Hydrex ALM gauge` | `hydrexGauge` |
| `SellModule` | `sellModule` | `Algebra SwapRouter` | `algebraSwapRouter` |
| `RecycleModule` | `recycleModule` | `HYDX` | `hydx` |
| `OffRampModule` | `offRampModule` | `oHYDX` | `oHydx` |
| `DurationFreezeModule` | `durationFreezeModule` | `CRE KeystoneForwarder` | `keystoneForwarder` |
| `DefaultCoordinator` | `defaultCoordinator` | `EVC` | `evc` |
| `LienXAlphaEscrow` | `lienXAlphaEscrow` | `EulerEarn factory` | `eulerEarnFactory` |
| `SzAlphaRateOracle` | `szAlphaRateOracle` | `warehouse Roles modifier` | `warehouseRoles` |
| `SzipNavOracleDemoVAMM` | `navOracleDemoVamm` | `LpStrategyModuleDemoVAMM` | `lpStrategyModuleDemoVamm` |

**ABI-file / dedup rule.** The generated ABI filename is the **basename of the entry's `abi` path**, minus
`.json` (e.g. `abi/external/IEVault.json` → `lib/zipcode/abi/IEVault.ts`; `abi/SzipUSD.json` →
`lib/zipcode/abi/SzipUSD.ts`). Distinct basenames only ⇒ **one file per distinct ABI** (~46 files: the 3
EVault keys share `IEVault.ts`, the 3 Safes share `GnosisSafe.ts`, USDC/Loot/Shares share `ERC20.ts`).
`registry.ts` imports each distinct const once and the shared keys reference the same import. Each `abi/*.ts`
is `export default ([ …the JSON array… ]) as const`. (The file count is illustrative, not a gate.)

**`index.json` IS the FE board.** It is the contracts the UI binds to — it deliberately excludes dev-account
EOAs and the EVK GenericFactory (not in `index.json`), and the showcase **vAMM pair/gauge LP token + gauge**
(the showcase oracle `navOracleDemoVamm` + module `lpStrategyModuleDemoVamm` ARE in `index.json`; the raw
pair/gauge are not). If a later showcase screen needs the vAMM pair/gauge, add them to `index.json` and
re-run the generator — out of scope for FE-01.

**Verified ABI facts the acceptance read binds to (the contract is truth — §1 inversion):**
- `SzipUSD` (`0x33aD…`) exposes `name() view returns (string)` → live read returns `"Zipcode Junior Vault Share"`.
- `SzipNavOracle` (`0x0C3E…`) exposes **`navEntry()` / `navExit()` / `spotNavPerShare()` / `twapNavPerShare()`**
  (all `view returns (uint256)`, 18-dp; live `navEntry()` = `107265000000000000000`). It does **NOT** expose
  `navPerShare()` (reverts). **Use `navEntry()` (or `spotNavPerShare()`) in the verify read — not
  `navPerShare`.** (See Back-pressure below.)

---

## Starting state (already in place — do NOT redo)

- The layer boots + reads the fork (FE-00 done): `.env` carries `RPC_URL_8453=http://127.0.0.1:8545`, chain
  fixed to 8453, `npm run build` green, anvil up (block ≥ 47096000, currently 47096192).
- `lib/zipcode/` exists with `store.ts` + `data.ts` (mock demo state — untouched this window).
- `viem` resolves through the `node_modules` symlink. No `abis/` dir and no Zipcode ABI/address module yet.

## Do NOT

- **Do NOT edit anything inside `euler-lite/`.** Read-only base; author only in the layer.
- **Do NOT import from `build/anvil/` at runtime/build time.** The layer is built standalone (Vercel) — the
  generated ABIs must be committed *inside* the layer. The generator's monorepo read is dev-time only.
- Do NOT hand-transcribe ABIs (drift risk) — generate them from the frozen JSONs.
- Do NOT bind the verify read to `navPerShare()` (absent) — use `navEntry()`/`spotNavPerShare()`.
- Do NOT introduce a second chain or a chain-switcher — MVP is 8453-only (the fork).
- Do NOT wire any deposit/exit/borrow flow this window — FE-01 is foundation only; the screens are FE-02..07.
- Do NOT widen the ABI type to plain `Abi` (loses inference) — keep `as const` default exports.
- Do NOT import via the `~`/`@` alias in `contracts.ts` or the scripts — those resolve only inside the nuxt
  build, not in a standalone `tsx`/node run. Use viem directly + relative paths.
- Do NOT run the verify script with plain `node` (it imports `.ts`) — use `npx tsx`.
- Do NOT make the default inline client the browser read path — it CORS-fails; the browser passes the proxy
  client. FE-01 only documents that contract; it does not build the proxy wiring (that's per-screen).

## Key requirements

1. **Self-contained ABIs.** `lib/zipcode/abi/<Name>.ts` files are committed; nothing the layer ships imports
   from outside the layer. One file per distinct ABI JSON (dedup: the 3 EVaults share `IEVault`, the 3 Safes
   share `GnosisSafe`, USDC/Loot/Shares share `ERC20`).
2. **Complete board.** The registry covers **every** entry in `index.json` (52 at authoring; all `kind`s:
   `protocol`, `standin`, `external`, `demo`) so FE-02..07 each need only this one import. Keys come from the
   **Canonical key table** above (do not re-derive). Spot the FE-02..07 needs: `depositModule`, `zipUsd`,
   `szipUsd` (FE-02); `navOracle`, `szipUsd`, `zipUsd` (FE-03); `exitGate`, `redemptionQueue` (FE-04);
   `venueAdapter`, `controller` (FE-05); `navOracle`, `zipUsd`, `farmUtilityVault`, `warehouseSafe`
   (FE-06); `farmUtilityVault`, `eePool` (FE-07) — all present.
3. **Typed.** Each address is a viem `Address` (`0x…`); each abi is `as const`;
   `ZipcodeContractKey = keyof typeof ZIPCODE_CONTRACTS`. `getZipcodeContract('szipUsd')` returns a typed
   contract whose `.read.name()` is inferred.
4. **Write path is the raw entry.** FE-02/04/05 writes use `@wagmi/vue` `sendTransactionAsync({ to, data })`
   with `data = encodeFunctionData({ abi, functionName, args })` (the codebase's real write primitive — NOT
   viem `writeContract`; see INFLOW-06 + `euler-lite/composables/useEulerTx.ts`). So the write surface is the
   **re-exported `ZIPCODE_CONTRACTS[key]` = `{ address, abi }`** (read directly for `to` + `encodeFunctionData`);
   `getZipcodeContract` is the read convenience only. Make this explicit in a JSDoc/comment.
5. **Default read client off the fork (node/SSR), proxy for browser.** `getZipcodeContract(key)` with no client
   builds a `PublicClient` inline (`createPublicClient({ transport: http(zipcodeRpcUrl()) })`); `zipcodeRpcUrl()`
   reads `RPC_URL_8453` (fallback `http://127.0.0.1:8545`) so the verify script + node-side reads work without
   the nuxt server up. Browser screens pass `useRpcClient().client` (the `/api/rpc/8453` proxy) — documented in
   the getter's JSDoc, not built here.
6. **Generator is idempotent + documented.** `node scripts/gen-zipcode-abis.mjs` (run from the layer root)
   reads `../../build/anvil/abi/index.json`, regenerates `abi/*.ts` + `generated/registry.ts`, and is safe to
   re-run after a redeploy with **no diff**: iterate `index.json` in its existing key order, emit with a fixed
   2-space indent, no timestamps / random / `Date.now()`. Header comment states: source path, dev-time-only
   (never Vercel), and the one-line run command.
7. **Build gate green.** `npm run build` (`nuxt build`) compiles with the new module present and importable
   (a throwaway import in an existing page is NOT required; the module standing alone in the build is the gate).

## Done when

1. `lib/zipcode/abi/*.ts`, `lib/zipcode/generated/registry.ts`, `lib/zipcode/contracts.ts`,
   `scripts/gen-zipcode-abis.mjs`, `scripts/verify-zipcode-binding.ts` exist and are committed to the **layer
   repo**.
2. The address book matches `contract-map.md` for the spot-check set (`szipUsd 0x33aD…`, `zipUsd 0xC5bd…`,
   `depositModule 0x6ecc…`, `navOracle 0x0C3E…`, `exitGate 0xd9b8…`, `redemptionQueue 0x46c8…`,
   `venueAdapter 0x87dC…`, `controller 0x3602…`).
3. `npm run build` is **green**.
4. With anvil up, `npx tsx scripts/verify-zipcode-binding.ts` prints, through the module's `getZipcodeContract`:
   - `getZipcodeContract('szipUsd').read.name()` → `"Zipcode Junior Vault Share"`
   - `getZipcodeContract('navOracle').read.navEntry()` → a non-zero `uint256` (≈ `1.07e20`)
5. Re-running `node scripts/gen-zipcode-abis.mjs` produces no diff (idempotent) against the committed output.

## Depends on / Obligations

- **Inbound obligations:** none (PROGRESS.md "Open obligations").
- Anvil up for the step-4 read (`cast block-number --rpc-url http://127.0.0.1:8545`); redeploy from
  `contracts/script/DeployLocal.s.sol` if down. The `npm run build` gate (step 3) does **not** need anvil.

## Back-pressure / findings (log in PROGRESS.md at Conclude)

- **`SzipNavOracle` has no `navPerShare()`** — the harness/PROGRESS FE-03 row and INFLOW-06 cite `navPerShare`,
  but the deployed contract exposes `navEntry()` (issuance price), `navExit()` (redemption price),
  `spotNavPerShare()`, `twapNavPerShare()`. This is a binding-name mismatch the FE-03 position/NAV view must
  honor (the contract wins, §1). Not a missing surface — a **rename**: FE-03 reads `navEntry`/`navExit`, not
  `navPerShare`. Logged as a seam so FE-03 binds correctly; no contract change owed.
