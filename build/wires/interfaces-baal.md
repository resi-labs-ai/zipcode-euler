# interfaces-baal — `contracts/src/interfaces/baal/` (wiring map)

> Source of truth = the kept code under `contracts/src/interfaces/baal/`. These are minimal local
> interfaces (only the methods we call) for the **interface+fork** Baal / Moloch-v3 protocol on Base —
> never compiled from source (OZ 4.x can't coexist with Euler's OZ 5.0.2; WOOF-00 Strategy A).

## Role
The local interface set for **Baal (Moloch v3)** — the DAO substrate the szipUSD vault summons in 8-B1.
Four shims: the DAO itself (`IBaal`), the two summoner factories (`IBaalSummoner` base,
`IBaalAndVaultSummoner` higher-order DAO+sidecar-Safe), and the Loot/Shares ERC20 clones (`IBaalToken`).
All signatures Basescan/`cast`-verified against vendored `reference/Baal/` (forge fork auto-ABI not
trusted). Live Base pins read from `contracts/script/BaseAddresses.sol`. Consumed by the summon script
and the ExitGate.

## Files

### `IBaal.sol`
- **Shims:** a deployed **Baal (Moloch v3) DAO** instance (Zodiac Module; avatar = main Safe). Impl/template
  master copy `BAAL_SINGLETON 0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4`; verified against
  `reference/Baal/contracts/Baal.sol`. Instances are proxies produced by the summoner — no fixed address;
  the address is the `daoAddress` returned by `summonBaalAndVault`.
- **Surface (signatures as written):**
  - `ragequit(address to, uint256 sharesToBurn, uint256 lootToBurn, address[] tokens)`
  - `mintLoot(address[] to, uint256[] amount)` / `burnLoot(address[] from, uint256[] amount)`
  - `mintShares(address[] to, uint256[] amount)`
  - `setShamans(address[] _shamans, uint256[] _permissions)`
  - `setAdminConfig(bool pauseShares, bool pauseLoot)`
  - `setGovernanceConfig(bytes _governanceConfig)`
  - `executeAsBaal(address _to, uint256 _value, bytes _data)` — raw `_to.call{value}(_data)` AS the Baal; baalOnly (avatar). Baal.sol:601.
  - proposal lifecycle (test-only inertness proof): `submitProposal(bytes,uint32,uint256,string) payable returns (uint256)`, `sponsorProposal(uint32 id)`, `processProposal(uint32 id, bytes proposalData)`
  - view getters: `lootToken()`, `sharesToken()`, `avatar()`, `target()`, `shamans(address) returns (uint256)`, `totalShares()`, `totalLoot()`, `totalSupply()`, `quorumPercent()`, `sponsorThreshold()`, `proposalOffering()`, `votingPeriod() returns (uint32)`, `gracePeriod() returns (uint32)`, `adminLock()`, `managerLock()`, `governorLock()`
- **Consumed by:**
  - `contracts/script/SummonSubstrate.s.sol` — reads `avatar()`/`lootToken()`/`sharesToken()`; encodes init `actions[]` via selectors `setAdminConfig`/`setGovernanceConfig`/`setShamans`/`mintShares`/`mintLoot` and `executeAsBaal` (self-add team-multisig owner onto main Safe + sidecar).
  - `contracts/src/supply/szipUSD/ExitGate.sol` — `IBaal public baal`; resolves `loot = baal.lootToken()`, `mainSafe = baal.avatar()`.
- **Gotchas:** zero-Shares ⇒ governance-**inert** by design (proposal fns exist only to PROVE inertness in tests). `ragequit` is the windowed patient-exit path (Loot held by the Gate). `setShamans` grants the manager(2) shaman bit (mint/burn) — admin=1/manager=2/governor=4. `executeAsBaal` is the only post-summon mutator used (avatar-gated). NatSpec must avoid bare `@word` (solc reads it as a tag).

### `IBaalSummoner.sol`
- **Shims:** the base **BaalSummoner** factory. NatSpec source-cites
  `0x97Aaa5be8B38795245f1c38A883B44cccdfB3E11`, but `BaseAddresses.sol` pins the consumed constant
  **`BAAL_SUMMONER 0x22e0382194AC1e9929E023bBC2fD2BA6b778E098`** (`0x97Aa…` is labeled
  `BAAL_ADV_TOKEN_SUMMONER`, the AdvTokenSummoner — label scramble was corrected; see Gotchas).
- **Surface:**
  - `summonBaal(bytes initializationParams, bytes[] initializationActions, uint256 _saltNonce) returns (address)`
  - `summonBaalFromReferrer(bytes initializationParams, bytes[] initializationActions, uint256 _saltNonce, bytes32 referrer) payable returns (address)`
  - `gnosisSingleton() returns (address)` — the Gnosis Safe singleton the summoner clones; read live for main-Safe CREATE2 precompute.
- **Consumed by:** `contracts/script/SummonSubstrate.s.sol` — `IBaalSummoner(BaseAddresses.BAAL_SUMMONER).gnosisSingleton()` (the actual DAO+Safe summon goes through the *vault* summoner, not this one).
- **Gotchas:** `summonBaalAndSafe` does **NOT** exist on the base summoner (zero hits over `reference/Baal/`) — the phantom from WOOF-00 was removed; the higher-order summoner exposes the differently-selectored `summonBaalAndVault`. The summoner's **own** proxy factory is internal — use `BaseAddresses.SAFE_PROXY_FACTORY_1_3_0` (validated by the compute==avatar assert), NOT `gnosisSingleton`'s factory.

### `IBaalAndVaultSummoner.sol`
- **Shims:** the higher-order **BaalAndVaultSummoner** — produces a Baal DAO + main Safe + a
  non-ragequittable sidecar ("vault") Safe in one tx. Pin
  **`BAAL_AND_VAULT_SUMMONER 0x2eF2fC8a18A914818169eFa183db480d31a90c5D`**; verified against
  `reference/Baal/contracts/higherOrderFactories/BaalAndVaultSummoner.sol`.
- **Surface:**
  - `summonBaalAndVault(bytes initializationParams, bytes[] initializationActions, uint256 saltNonce, bytes32 referrer, string name) returns (address daoAddress, address vaultAddress)` — `daoAddress` = the Baal; `vaultAddress` = the sidecar Safe (`deployAndSetupSafe(dao)`).
  - `vaultIdx() returns (uint256)` — public counter.
  - `vaults(uint256 id) returns (uint256 vaultId, bool active, address daoAddress, address vaultAddress, string name)` — Vault registry struct (BaalAndVaultSummoner.sol:24-31).
- **Consumed by:** `contracts/script/SummonSubstrate.s.sol` — `IBaalAndVaultSummoner(BaseAddresses.BAAL_AND_VAULT_SUMMONER).summonBaalAndVault(initParams, actions, saltNonce, bytes32(0), VAULT_NAME)` → `(baal, sidecar)`. This is what 8-B1 actually summons through.
- **Gotchas:** `summonBaalAndVault` lives on **this** contract, NOT the base `BaalSummoner` (different contract + selector). The returned `vaultAddress` is the structural utilization-sized sidecar freeze Safe (non-ragequittable), distinct from the main avatar Safe.

### `IBaalToken.sol`
- **Shims:** the Baal **Loot / Shares ERC20 clones** (`reference/Baal/contracts/LootERC20.sol` /
  `SharesERC20.sol`; ERC20Upgradeable + Ownable). **INTERNAL** in the sense of no fixed address — instances
  are deployed per-DAO by `BaalSummoner.deployTokens`, paused at summon (:303-304), owned by the Baal
  (`transferOwnership` :305-306). No `decimals()` override ⇒ 18.
- **Surface (only the 8-B1 reads):** `paused() returns (bool)`, `name() returns (string)`,
  `symbol() returns (string)`, `decimals() returns (uint8)`, `owner() returns (address)`,
  `totalSupply() returns (uint256)`.
- **Consumed by:** no direct `import` hit (read via `IBaal.lootToken()`/`sharesToken()` returning the token
  address; this shim is the assertion surface for summon/post-summon checks — paused state, ownership = Baal, 18 decimals).
- **Gotchas:** tokens are **paused** at summon (transfers disabled) and **owned by the Baal**, not the team
  — Loot/Shares move only via Baal mint/burn (manager shaman) and ragequit. Decimals is implicit-18 (no override).
