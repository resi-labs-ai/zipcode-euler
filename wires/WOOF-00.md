# WOOF-00 — Foundry scaffold + integration substrate (wiring map)

> Source of truth = the kept code under `contracts/`. Ticket (`tickets/woof/WOOF-00-scaffold.md`) +
> report (`reports/WOOF-00-report.md`) are intent. This doc reads the code as the final form and
> records how the scaffold is wired and what every downstream contract builds on.

## Role
WOOF-00 is **not a protocol contract** — it is the buildable substrate every other component compiles
into: the Foundry config, the remap closure, the local interface set for the deployed-on-Base protocols
we interface+fork (never compile), the validated Base address book, and the fork helper. The "wiring" of
WOOF-00 is therefore (a) **what is compiled vs interfaced** and (b) **the live external addresses every
downstream contract pins to**.

## Artifacts involved (what each does)
| File | What it is |
|---|---|
| `contracts/foundry.toml` | Build profile: solc **0.8.24**, `evm_version=cancun`, `optimizer_runs=20_000`, `allow_paths=["../reference"]`, rpc `base`=`${BASE_RPC_URL}` (primary) + `base_sepolia` (optional). |
| `contracts/remappings.txt` | The dep closure (see Wiring). No `#` comment lines (this forge rejects them). |
| `contracts/script/BaseAddresses.sol` | `library BaseAddresses` — the validated Base **mainnet (8453)** address constants. The single source of every live external pin. |
| `contracts/test/ForkConfig.sol` | `abstract contract ForkConfig is Test` — `_selectBaseFork()` pins `createSelectFork("base", 47096000)` and asserts chainid 8453. Every fork/integration test inherits it. |
| `contracts/src/interfaces/**` | Minimal local interfaces (only the methods we call) for the **interface+fork** protocols: `safe/`, `baal/`, `zodiac/`, `ichi/`, `hydrex/`, `algebra/`, plus `euler/`, `bridge/`, `cow/`, `loss/`, `supply/` seams authored by later tickets. |
| `contracts/src/{venue,supply,loss,bridge}/…` + top-level stubs | The §7 `src/` tree the protocol logic lands in. |

## Wiring — compiled vs interfaced (the load-bearing rule)
The one hard constraint: **OZ 4.x (Baal/Zodiac-Roles/Safe pin 4.8.3/4.9.3) cannot coexist with Euler's OZ
5.0.2 in one Foundry build.** Strategy A dissolves it — those protocols are **never compiled from source**;
we author local interfaces and fork their live Base deployments.

| Tier | Members | How |
|---|---|---|
| Compiled (vendored) | Euler EVK/EVC/EulerEarn*/EulerRouter/periphery + `ESynth`/`BaseAdapter` (OZ 5.0.2) | the Euler remap lines |
| Compiled (OZ-free) | `zodiac-core` `core/Module`,`core/Operation`,`factory/ModuleProxyFactory` (every engine Zodiac module `is Module`) | `@gnosis-guild/zodiac-core/` remap |
| Compiled (CRE base) | `x402-cre-price-alerts` `ReceiverTemplate` (the `ZipcodeController`/registry/oracle/coordinator base) | `x402-cre-price-alerts/` remap |
| Compiled (bridge only) | Chainlink CCIP `BurnMintTokenPool`/`BurnMintERC20` + Subtensor ifaces (8x window) | `chainlink-ccip/` + `@chainlink/contracts/` + the versioned `@openzeppelin/contracts@4.8.3`/`@5.3.0` remaps |
| **Interface + fork (NOT compiled)** | **Baal, Zodiac Roles, Gnosis Safe, ICHI, Hydrex/Algebra** | local `src/interfaces/**` + Base-mainnet fork |

Notable: `EulerEarn` source pins exact `0.8.26` → it is **mocked**, never imported (it does not fit the
0.8.24 profile); only `ESynth`/`BaseAdapter`/EVC are compiled from the Euler tree. The remap file has grown
past the original 9 Euler lines as later windows added their deps (zodiac-core, x402 CRE base, solady,
chainlink-ccip, the dual-OZ-version bridge remaps) — all additive.

## External pins — the live addresses everything downstream wires to
Every constant below is on-chain-verified (`BaseAddresses.sol`). These are the fixed endpoints the deploy/
wiring script (item 10) passes into constructors and asserts against.

- **CRE / Chainlink:** `CRE_KEYSTONE_FORWARDER 0xF8344CFd…74482` (same on mainnet+Sepolia) — the Forwarder
  wired into every `ReceiverTemplate` (controller/registry/oracle/coordinator/warehouse adapter) and frozen.
- **Euler (8453):** `EVC 0x5301c7dD…8989`, `EVAULT_FACTORY 0x7F32…f8D0` (EVK GenericFactory),
  `EULER_EARN_FACTORY 0x75F4…FAE6`, `ORACLE_ROUTER_FACTORY 0xA928…c116`, `EDGE_FACTORY 0x4B93…0e4A`.
- **Gnosis Safe:** `SAFE_PROXY_FACTORY_1_3_0 0xa6B7…6AB2`, `SAFE_L2_SINGLETON_1_4_1 0x29fc…C762`. **Gotcha:**
  the **BaalSummoner's own** proxy factory is a *different* 1.3.0 deployment `BAAL_SAFE_PROXY_FACTORY
  0xC228…10BC` (read from summoner slot 208) — used for the 8-B1 main-Safe CREATE2 precompute; its
  `gnosisSingleton` = `0x69f4…2938`.
- **Baal (labels were SCRAMBLED, corrected):** `BAAL_SUMMONER 0x22e0…E098` (base, `summonBaal`),
  `BAAL_AND_VAULT_SUMMONER 0x2eF2…0c5D` (DAO+Safe one-tx — what 8-B1 uses), `BAAL_SINGLETON 0xE0F3…D5d4`
  (DAO template). `0x97Aaa…3E11` is the **AdvTokenSummoner**, not the base summoner.
- **Zodiac:** `ZODIAC_ROLES_MASTERCOPY 0x9646…D337`, `ZODIAC_MODULE_PROXY_FACTORY 0x0000…a236`
  (`deployModule` — clones the engine modules + the warehouse Roles instance).
- **Hydrex/Algebra/ICHI:** `HYDX`, `OHYDX 0xA113…cB78`, `HYDREX_VOTER 0xc69E…f17b`, `VEHYDX 0x25B2…d1e1`,
  `HYDREX_REWARDS_DISTRIBUTOR 0x6FCa…eD42` (= `Minter._rewards_distributor()`), `HYDREX_MINTER 0xA7D6…003E`,
  `ALGEBRA_NFPM 0xC63E…Ab86`, `ICHI_VAULT_FACTORY 0x2b52…280a` (**corrected** — `0x7d11…` was a Gnosis Safe,
  now `ICHI_ADMIN_SAFE`), `ICHI_DEPOSIT_GUARD 0x9A0E…C8d8`, `HYDX_USDC_POOL 0x51f0…D3D2`,
  `ALGEBRA_SWAP_ROUTER 0x6f4b…3F9e` (base-factory pool ⇒ `exactInputSingle.deployer == address(0)`),
  `USDC 0x8335…2913`.
- **CoW Protocol:** `COW_SETTLEMENT 0x9008…ab41` (same all chains), `COW_VAULT_RELAYER 0xC92E…0110`
  (read live in `setUp`), `COW_ORDER_SIGNER 0x23dA…1FAB` (reference-only).
- **Dynamically created (no fixed address):** the zipUSD/xALPHA ICHI vault + its Hydrex gauge — created on
  demand, gated on the Hydrex whitelist (OTC); fork tests use a stand-in until the gate clears.

## Gotchas the item-10 script inherits
- **Fork determinism:** tests must pin via `ForkConfig` (`BASE_FORK_BLOCK = 47096000`); an unpinned
  latest-block fork makes fixed-amount deposits into live third-party vaults intermittently revert `DTL`.
- A bare `@word` (e.g. `@gnosis-guild/…`) inside a `///`/`/** */` comment fails the build (solc reads it as
  a NatSpec tag) — use `//` or drop the `@`.
- Foundry fork auto-ABI is not trusted; interface signatures are Basescan/`cast`-verified.
