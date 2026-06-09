# WOOF-00 — Scaffold the Foundry project + `src/` layout + deps

> **EXTENDED 2026-06-06 (superintendent holistic audit) — Euler-only → complete multi-ecosystem scaffold.**
> The original scaffold (below, UNCHANGED) is correct for the Euler stack (items 1–6/9/10). The item-8 / 8-Bw /
> xALPHA-bridge design pulled in four more ecosystems (Baal, Zodiac, Gnosis Safe, Chainlink CCIP/Subtensor) +
> ICHI/Hydrex. Baal/Zodiac/Safe are npm/Hardhat-based and pin **OpenZeppelin 4.8.3 / 4.9.3**, which collides
> with Euler's **OZ 5.0.2** — so they are NOT compiled. **Strategy A (interface + fork, user-locked):** author
> minimal local interface files + fork live **Base mainnet** for the real deployments. The completion sections
> are marked **[EXT]**.
>
> **MATERIALIZED + BUILDS GREEN 2026-06-06.** The scaffold is now real on disk under `contracts/` (`forge build`
> clean; all 3 self-checks pass incl. a live Base-mainnet fork read). Every external interface signature + every
> Base address was verified against the live chain — **two address bugs were found and fixed** (the ICHI "factory"
> `0x7d11…` was actually a Gnosis Safe → corrected to `0x2b52c416…`; the Baal summoner labels were scrambled →
> corrected against `reference/Baal/deployments/base/*.json`), and **10 of 25 guessed interface signatures were
> wrong → corrected**. Per the keep-the-build doctrine the materialized scaffold is **committed, not discarded.**

**Deliverable**
A green-building Foundry project under `contracts/`, matching `README.md` §7:
- `contracts/foundry.toml`, `contracts/remappings.txt`, `contracts/.env.example`
- top-level `contracts/src/*.sol` placeholder files named per §7 (empty stubs), keeping `venue/ supply/ loss/`
- `contracts/.gitignore` (or root) extended for build artifacts
- **[EXT]** `contracts/src/interfaces/` (the minimal local interfaces for the deployed-on-Base protocols we
  interface+fork) + `contracts/script/BaseAddresses.sol` (validated Base address constants) +
  `contracts/test/ForkConfig.sol` (Base-mainnet fork helper)
(No protocol logic — only the buildable skeleton + the integration-layer interfaces every later ticket uses.)

**[EXT] Strategy A — what is compiled vs. interfaced (the load-bearing rule)**
| Tier | Members | Handling |
|---|---|---|
| Compiled (vendored, unchanged) | Euler EVK/EVC/EulerEarn/EulerRouter/periphery — **OZ 5.0.2** | existing 9-line remaps; solc 0.8.24/cancun |
| Compiled (new, OZ-free) | `zodiac-core` `core/Module.sol`,`core/Operation.sol`,`factory/ModuleProxyFactory.sol` (`^0.8.24`, **no OZ import** in production) — only if a shaman/module `extend`s `Module` | one remap `@gnosis-guild/zodiac-core/` |
| Compiled (bridge exception — VERIFY in 8x) | `chainlink-ccip` base pool, `chainlink-common`, `chain-selectors`, `chainlink-local`, Subtensor precompile ifaces | Foundry-native; its OZ/solc compat with the 5.0.2 baseline is checked in the **8x** window, not here |
| **Interface + fork (NO source compiled)** | **Baal, Zodiac Roles Modifier (deployed, we call it), Gnosis Safe, ICHI, Hydrex/Algebra** | local interfaces under `src/interfaces/` + Base-mainnet fork. **This is what avoids the OZ-4/5 collision.** |

**Spec §**
`README.md` §7 (layout + Foundry conventions) · `claude-zipcode.md` §16 (reference-repo map = dep sources).
Inherited decisions: `reference/` is read-only and is the *only* dep source; one contract per file named as
the symbol; `loss/` is M2-sketch. **[EXT]** §4.5 (Baal/Zodiac/ICHI/Hydrex)
(Roles v2), `tickets/bridge/8x-01-szalpha-wrapper-cct.md` (CCIP/Subtensor) define the interface+fork dependency surface.

**Model from**
`reference/evk-periphery/foundry.toml` (solc/optimizer profile to match). *(`reference/evk-periphery/remappings.txt`
is reference only — do NOT transpose it by hand; the exact, verified remap set is pinned in Key requirements.)*
**[EXT]** Interface signatures: model from vendored source — `reference/Baal/contracts/`,
`reference/zodiac-modifier-roles/packages/evm/contracts/`, `reference/zodiac-core/contracts/` — and match the
final method set to the **Basescan-verified ABI** of each deployed contract (do NOT trust Foundry auto-ABI).

**Starting state (already in the repo — do not recreate)**
- `contracts/` **exists** with `src/{venue,supply,loss}/.gitkeep`, `script/.gitkeep`, `test/.gitkeep` (committed).
- `.gitignore` exists and ignores **only** `reference/`.
- The Euler dep repos exist under `reference/` (`euler-vault-kit`, `euler-earn`, `evk-periphery`,
  `ethereum-vault-connector`, `euler-price-oracle`, `erc7540-reference`, `euler-interfaces`) — their nested `lib/`
  submodules (OZ, forge-std, EVC, permit2) are **populated** in this checkout (see Prerequisite).
- **[EXT]** The new-ecosystem repos also exist under `reference/`: `Baal`, `zodiac-core`, `zodiac-modifier-roles`
  (+ other `zodiac-*`), `permissions-starter-kit`, `chainlink-ccip`, `chainlink-common`, `chain-selectors`,
  `chainlink-local`, `ccip-starter-kit-foundry`, `subtensor`, `evm-bittensor`, `x402-cre-price-alerts`
  (the CRE `ReceiverTemplate` base). **ICHI and Hydrex/Algebra source are NOT vendored — and do not need to be**
  (interface+fork; their contracts are read off the Base fork by address).

**Prerequisite (one-time, repo-wide — provisions the COMPILED deps)**
Initialize the **Euler** dep submodules (network fetch, one-time): in each of `reference/{euler-vault-kit,
ethereum-vault-connector, euler-earn, euler-price-oracle, erc7540-reference, evk-periphery}` run
`git submodule update --init`. Verify with `find reference/euler-vault-kit/lib/openzeppelin-contracts -type f
| head` (non-empty).
**[EXT]** `reference/zodiac-core` (only `core/`+`factory/`, OZ-free) compiles without its npm deps for the
files we use — confirm at build. **Baal / Zodiac-Roles / Safe / ICHI / Hydrex are interface+fork → do NOT
`npm install` / provision their Hardhat `node_modules`; we never compile their source.** The bridge Chainlink
repos' provisioning is an **8x**-window concern. The "`reference/` is read-only, no fetch" rule applies to the
*build loop*, not this one-time provisioning.

**Do NOT**
- **Do NOT run `forge init`** (the tree is non-empty; it would fail or scaffold `Counter.sol` + a `lib/` submodule).
- **Do NOT create a `contracts/lib/` or fetch any dependency** — everything, including `forge-std`, remaps into
  `reference/`.
- Do not commit secrets — only `.env.example` with placeholder values.
- **[EXT] Do NOT vendor or compile Baal / Zodiac-Roles / Gnosis-Safe / ICHI / Hydrex source** — they pin OZ 4.x
  and would collide with Euler's OZ 5.0.2. Interface + fork only.
- **[EXT] Do NOT add remap aliases pointing at those five protocols' source.** The only NEW source remaps are
  `@gnosis-guild/zodiac-core/` (OZ-free) and the bridge set (8x-window).
- **[EXT] Do NOT trust Foundry's fork auto-ABI** for the interface files — match signatures to the
  Basescan-verified source/ABI.
- **[EXT] Do NOT put a bare `@word` (e.g. `@gnosis-guild/...`) inside a `///` or `/** */` comment** — solc parses
  `@word` as a NatSpec tag and fails the build ("Documentation tag ... not valid"). Use a plain `//` comment, or
  drop the `@` (write `gnosis-guild/...`), when referencing a remap alias in a doc comment.

**Key requirements**
- **solc 0.8.24, `evm_version = cancun`, `optimizer_runs = 20000`** in `foundry.toml` (matches
  `reference/evk-periphery` + Base Sepolia). *(PROBE-VALIDATED 2026-06-06: the 3-part coexistence compiles clean —
  `ESynth`/`BaseAdapter`/EVC (`^0.8.0`) + zodiac-core `core/Module`+`factory/ModuleProxyFactory` (`^0.8.24`,
  **independently confirmed OZ-free**: zero `openzeppelin` imports in zodiac-core core/factory — it vendors its own
  `Ownable`/`FactoryFriendly`) + the local interfaces, all under ONE 0.8.24 profile with **NO OZ-4/5 collision**.
  **CORRECTION (fold-back):** `euler-earn` source (`EulerEarn.sol`/`EulerEarnFactory.sol`) pins **exact `0.8.26`** —
  it does NOT fit the 0.8.24 profile and MUST be **MOCKED**, never imported as source into this build (the same
  Strategy-A mock rule WOOF-04/05/06 already follow). `ESynth`/`BaseAdapter`/EVC do fit. The only `^0.8.28` files
  are zodiac-core TEST files, outside our closure.)*
- **`foundry.toml` must include `allow_paths = ["../reference"]`** — forge rejects reading source outside the
  project root without it ("File outside of allowed directories"). Verified required.
- **`remappings.txt` — the 9 Euler lines below, NO comment lines** (this forge version rejects `#` lines and
  fails the whole build). All OZ/forge-std/permit2 point to the **single** `euler-vault-kit/lib` copy (verified:
  no version split across evk / euler-price-oracle / euler-earn):
  ```
  evc/=../reference/ethereum-vault-connector/src/
  evk/=../reference/euler-vault-kit/src/
  euler-price-oracle/=../reference/euler-price-oracle/src/
  euler-earn/=../reference/euler-earn/src/
  ethereum-vault-connector/=../reference/ethereum-vault-connector/src/
  openzeppelin-contracts/=../reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/
  @openzeppelin/contracts/=../reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/
  forge-std/=../reference/euler-vault-kit/lib/forge-std/src/
  permit2/=../reference/euler-vault-kit/lib/permit2/
  ```
  Add lines only as later tickets need them — e.g. `ReceiverTemplate` (the `ZipcodeController`/`ZipcodeOracleRegistry`
  base, §4.4) lives in `reference/x402-cre-price-alerts/` and is **not** in this set; add its alias in that ticket.
  - **[EXT]** The **only NEW source remap WOOF-00 adds** is `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/`
    (the OZ-free `Module`/`Operation`/`ModuleProxyFactory` a shaman may inherit). The bridge Chainlink/Subtensor
    aliases are added in the **8x** window (they're the one place external source — `BurnMintTokenPool` etc. — is
    compiled, so the OZ/forge-std single-copy dedup is RE-VERIFIED there, not assumed). Baal/Roles/Safe/ICHI/Hydrex
    get **no source remap** — local interfaces only.
- **`[rpc_endpoints]`** in `foundry.toml`: **`base = "${BASE_RPC_URL}"` is the PRIMARY** — Base **mainnet (8453)**
  is BOTH the **deploy target AND the fork/integration-test target** (decision 2026-06-06: **ship to Base mainnet,
  test there** — Base gas is cheap, and Baal/Safe/Zodiac/ICHI/Hydrex + the Euler factories all live on 8453;
  Base **Sepolia lacks the farm/vault deps**, so deploying there was never actually runnable for item 8). Keep
  `base_sepolia = "${BASE_SEPOLIA_RPC_URL}"` as an **optional** secondary (CRE + Euler exist there, the vault deps
  do not). Env keys **`BASE_RPC_URL`** (primary), `BASE_SEPOLIA_RPC_URL` (optional), `DEPLOYER_PRIVATE_KEY`, in
  `.env.example`.
- Record the CRE selector **`ethereum-mainnet-base-1`** (Base mainnet 8453 — the deploy target) as a comment in
  `.env.example` (no contract use yet); `ethereum-testnet-sepolia-base-1` is the optional secondary. *(Fixed
  2026-06-06: the deploy-target selector is the MAINNET one — see the verification-pass line below; an earlier
  draft recorded the Sepolia selector, which contradicts the locked "ship to Base mainnet" decision.)*
- **Extend `.gitignore`** to add `contracts/out/`, `contracts/cache/`, `contracts/broadcast/` (currently only
  `reference/` is ignored).
- Top-level `src/*.sol` placeholders: create the files named in §7 as empty stubs — **exactly** the SPDX line
  `// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;` (nothing else). GPL-2.0-or-later
  is pinned for **every** `contracts/src/*.sol` (and `test/`/`script/`) file the protocol authors: these contracts
  import GPL-2.0-or-later `evk`/EVC code, so a derivative is kept GPL-2.0-or-later (GPL-compatible with the OZ
  MIT imports). Do NOT leave the license to the author's discretion — every later ticket inherits this exact line.
  Leave the `.gitkeep` dirs intact. **[EXT]** Interface files in `src/interfaces/` are local-authored (not Euler
  derivatives) but keep the same SPDX line + pragma for consistency.
- **[EXT] `src/interfaces/` inventory** (minimal local interfaces — only the methods we call; tag each file with
  its source contract + Base address from `BaseAddresses.sol`):
  - `interfaces/safe/ISafe.sol` (`enableModule`/`isModuleEnabled`/`execTransactionFromModule`/`swapOwner`/`addOwnerWithThreshold`) · `ISafeProxyFactory.sol` (`createProxyWithNonce`)
  - `interfaces/baal/IBaal.sol` (`ragequit`, `mintLoot`/`burnLoot`, `setShamans`, `lootToken`/`sharesToken`/`avatar`, `shamans(addr)`) · `IBaalSummoner.sol` (`summonBaal`/`summonBaalFromReferrer` — **`summonBaalAndSafe` does NOT exist on the base summoner**; the DAO+Safe one-tx path is `BaalAndVaultSummoner`, a separate contract)
  - `interfaces/zodiac/IRoles.sol` (`execTransactionWithRole`, `assignRoles`, `scopeTarget`/`scopeFunction`/`allowFunction`) · `IModuleProxyFactory.sol` (`deployModule`) — note `Module` may instead be inherited from the `zodiac-core` remap
  - `interfaces/ichi/IICHIVault.sol` (ERC4626 + `getTotalAmounts`/`allowToken0`/`allowToken1`) · `IICHIVaultFactory.sol` (`getICHIVault(bytes32)`/`createICHIVault(address,bool,address,bool)` — **on-chain-verified names; NOT `getVault`/`createVault`**) · `IICHIDepositGuard.sol` (`forwardDepositToICHIVault`/`forwardWithdrawFromICHIVault(vault,deployer,shares,to,minAmount0,minAmount1)→(uint256,uint256)`)
  - `interfaces/hydrex/IVoter.sol` (`vote`/`createGauge`/`gauges`/`claimRewards`) · `IGauge.sol` (`deposit`/`withdraw`/`getReward`/`earned`/`balanceOf`) · `IOptionToken.sol` (`exercise`/`exerciseVe`/`getDiscountedPrice`) · `IVotingEscrow.sol` (`create_lock`/`balanceOfNFT`)
  - `interfaces/algebra/INonfungiblePositionManager.sol` (`mint`/`increaseLiquidity`/`decreaseLiquidity`/`collect`/`burn`/`positions`) · `IAlgebraPool.sol` (`swap`/`globalState`) · `IAlgebraFactory.sol` (`poolByPair`)
  - (the bridge `interfaces/ccip/` + Subtensor precompile interfaces are **deferred to the 8x window**)
- **[EXT] `script/BaseAddresses.sol`** — a `library` of the validated Base addresses. **Verification pass
  2026-06-06 (superintendent): statuses below; even CONFIRMED ones get one final Basescan glance at build.**
  - **CRE KeystoneForwarder** — **same address on Base mainnet AND Base Sepolia**:
    `0xF8344CFd5c43616a4366C34E3EEE75af79a74482`. **CONFIRMED on-chain on BOTH** (verified `KeystoneForwarder` on
    basescan.org [8453] and sepolia.basescan.org [84532]) + the Chainlink forwarder directory. **Deploy-target
    selector = Base mainnet `ethereum-mainnet-base-1`** (the MVP ships to mainnet); Base Sepolia
    `ethereum-testnet-sepolia-base-1` is the optional secondary. `ReceiverTemplate` is **inherited (compiled)**,
    not interfaced — the forwarder is wired into the controller/registry ctor and frozen by renounce (§4.4/§9).
  - **Euler** (8453) — **CONFIRMED, repo-authoritative** (`reference/euler-interfaces/EulerChains.json`, chainId
    8453, status=production): EVC `0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989`, `eVaultFactory` (the EVK
    GenericFactory) `0x7F321498A801A191a93C840750ed637149dDf8D0`, `eulerEarnFactory`
    `0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6`, `oracleRouterFactory` `0xA9287853987B107969f181Cce5e25e0D09c1c116`,
    `edgeFactory` `0x4B930F0222349c2092b8531A42295262cc4F0e4A` (perspectives dropped §17). *(We deploy + test on
    Base mainnet, so these 8453 factory addresses are the live targets — no Sepolia Euler sourcing needed.)*
  - **Safe** (8453) — ProxyFactory 1.3.0 `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2` (EIP-55 checksummed — the
    all-lowercase form does NOT compile as a Solidity address literal) **CONFIRMED on Basescan**
    (verified `GnosisSafeProxyFactory`, label "Safe: Proxy Factory 1.3.0 default"); L2 singleton 1.4.1
    `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` **CONFIRMED on Basescan** (verified `SafeL2`).
  - **Baal** (8453) — **CORRECTED 2026-06-06: the prior labels were SCRAMBLED** (source of truth =
    `reference/Baal/deployments/base/*.json`, cross-checked on-chain via `template()`). The real **`BaalSummoner`**
    (base, `summonBaal`/`summonBaalFromReferrer`) is **`0x22e0382194AC1e9929E023bBC2fD2BA6b778E098`** (confirmed:
    its `template()` → `0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4` = the `Baal.json` DAO singleton). The
    **`BaalAndVaultSummoner`** (summon DAO + Safe in one tx — likely what **8-B1** uses) is
    `0x2eF2fC8a18A914818169eFa183db480d31a90c5D`. The address previously mislabeled "BaalSummoner"
    (`0x97Aaa5be8B38795245f1c38A883B44cccdfB3E11`, impl `0xD69e5B8F6FA0E5d94B93848700655A78DF24e387`) is actually
    the **`BaalAdvTokenSummoner`** proxy — a *different* summoner, not the base one, and not a Baal DAO impl.
  - **Zodiac** (8453) — Roles Modifier mastercopy `0x9646fDAD06d3e24444381f44362a3B0eB343D337` **CONFIRMED on
    Basescan** (verified contract `Roles`; surface `allowFunction`/`allowTarget`/`assignRoles`/`scopeFunction`).
    ModuleProxyFactory `0x000000000000aDdB49795b0f9bA5BC298cDda236` **CONFIRMED on Basescan** (verified
    `ModuleProxyFactory`, `deployModule` salt-deterministic deploy; canonical Zodiac factory, also in
    `reference/zodiac-core` tooling) — used to `deployModule` the Roles instance in 8-Bw.
  - **Hydrex / Algebra / ICHI** (8453) — **use the verified table in `pending-docs/hydrex.md` as the source of
    truth** (do NOT re-transcribe — one SwapRouter transcription error was already caught this way). Confirmed
    there: HYDX `0x00000e7efa313F4E11Bfff432471eD9423AC6B30`, oHYDX `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78`,
    Voter `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b`, veHYDX `0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1`, NFPM
    `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86`, ICHI vault **factory** `0x2b52c416F723F16e883E53f3f16435B51300280a`
    (**CORRECTED 2026-06-06, on-chain verified** — read from the deposit guard's `ICHIVaultFactory()`; the old
    `0x7d11De61…` was a mis-labeled Gnosis Safe, not the factory),
    ICHI deposit guard `0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8`, HYDX/USDC pool
    `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`, USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
  - **Dynamically created (NO fixed address):** the zipUSD/xALPHA ICHI vault + its Hydrex gauge — created on demand
    (`ICHIVaultFactory.createICHIVault` + `Voter.createGauge(lp, ALM_ICHI_UNIV3)`), gated on the Hydrex whitelist (OTC). Fork
    tests use a stand-in until the live gate clears (mirrors the xALPHA stand-in-token decision).
- **[EXT] `test/ForkConfig.sol`** — a fork helper (`vm.createSelectFork("base")` + the `BaseAddresses` constants) the integration/fork tests inherit.

**Done when**
- `forge build` succeeds on the scaffold. **Self-check 1 (Euler cross-repo, unchanged):** temporarily add a
  throwaway `test/Probe.t.sol` importing `ESynth` from `evk/Synths/ESynth.sol` **and** `BaseAdapter` from
  `euler-price-oracle/adapter/BaseAdapter.sol` (ESynth pulls OZ + EVC transitively — the hard case), confirm
  `forge build` compiles them ("Compiler run successful!"). *(A single-file EVC import is not a sufficient probe
  — it hides the OZ/EVC dedup that breaks.)*
- **[EXT] Self-check 2 (cross-ecosystem coexistence):** the same throwaway also imports a local interface (e.g.
  `interfaces/safe/ISafe.sol`, `interfaces/baal/IBaal.sol`, `interfaces/ichi/IICHIVault.sol`) **and** (if a shaman
  uses it) inherits `@gnosis-guild/zodiac-core/core/Module.sol` — proving local interfaces + OZ-free zodiac-core
  source **coexist with the OZ-5 Euler stack in one compilation unit, with NO OZ version-collision error**. This
  is the real "scaffold is done" signal now.
- **[EXT] Self-check 3 (interface+fork runs):** a fork smoke-test does `vm.createSelectFork("base")` then a read
  call through a local interface against a real deployed Base address (e.g. `ISafeProxyFactory` code exists;
  `IVoter.gauges(addr)`; an ICHI deployer read) — proving the interface+fork path works end-to-end against the
  live deployments. **Re-confirm each address on Basescan first.** Then delete the throwaway probes; the committed
  tree builds green ("No files changed" / exit 0).
- The `src/` tree matches `README.md` §7 (`venue/ supply/ loss/` + `supply/szipUSD/` + `supply/CreditWarehouse/`
  + **`interfaces/`** present; top-level stub files named correctly).
- **Byproduct discipline:** discard protocol-logic byproduct (`contracts/` back to skeleton) — **but the
  interface files, `BaseAddresses.sol`, and `ForkConfig.sol` ARE the scaffold keepsake and persist** (they are
  not byproduct).
- *Downstream note (not a WOOF-00 acceptance criterion):* this scaffold is the substrate `audit/2.md` Phase S
  deploys into. **[EXT]** The bridge (8x) is the one workstream that compiles external (Chainlink) source — its
  OZ/solc compat check + the CCT remap aliases land in the 8x window, not here.

**Depends on**
Nothing — this is the root ticket. Every WOOF/sodo/bridge contract + deploy/wiring ticket depends on it.
