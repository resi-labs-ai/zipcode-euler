# interfaces-safe — Gnosis Safe shims (wiring map)

> Source of truth = the kept code under `contracts/src/interfaces/safe/`. This doc reads the two
> interface shims as final form and records what they shim, the exact declared surface, every
> consumer, and the Safe-auth gotchas the engine modules / deploy scripts inherit.

## Role
`contracts/src/interfaces/safe/` is **not protocol code** — it is the minimal local interface set for
the **interface+fork** (never-compiled) Gnosis Safe contracts deployed on Base (WOOF-00 Strategy A: OZ
4.x Safe cannot coexist with Euler OZ 5.0.2 in one build). Only the methods Zipcode actually calls are
declared; signatures are Basescan/`cast`-verified, not Foundry auto-ABI. Two files: the Safe singleton
(`ISafe`) and the proxy factory (`ISafeProxyFactory`). Live Base pins live in
`contracts/script/BaseAddresses.sol`.

## Live addresses shimmed (BaseAddresses.sol)
- `SAFE_PROXY_FACTORY_1_3_0 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2` — generic Safe Proxy Factory
  1.3.0 (used by `CreditWarehouseDeployer` to deploy the warehouse Safe).
- `SAFE_L2_SINGLETON_1_4_1 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` — SafeL2 1.4.1 singleton; the
  `initializer` target (`setup`) that proxies delegatecall at construction.
- `BAAL_SAFE_PROXY_FACTORY = 0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC` — **the BaalSummoner's OWN**
  1.3.0 factory (a *different* 1.3.0 deployment, read from summoner slot 208; its `gnosisSingleton` =
  `0x69f4…2938`). Used by 8-B1 / `SummonSubstrate` for the main-Safe CREATE2 address precompute (Baal
  summons the main Safe through this factory, not the generic one).

## Per-file catalog

### `ISafe.sol`
- **Shims:** SafeL2 1.4.1 singleton @ `0x29fcB43b…C762` (the L2 `operation` enum: `0=Call`, `1=DelegateCall`).
- **Declared surface (exact):**
  - `setup(address[] owners, uint256 threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address payable paymentReceiver)` — the initializer passed to `createProxyWithNonce`; sets owners/threshold/module-set/fallback atomically via delegatecall.
  - `enableModule(address module)`
  - `isModuleEnabled(address module) → bool`
  - `execTransactionFromModule(address to, uint256 value, bytes data, uint8 operation) → bool success` — the enabled-module exec path.
  - `swapOwner(address prevOwner, address oldOwner, address newOwner)`
  - `addOwnerWithThreshold(address owner, uint256 _threshold)`
  - `removeOwner(address prevOwner, address owner, uint256 _threshold)`
  - `getOwners() → address[]`
  - `isOwner(address owner) → bool`
  - `getThreshold() → uint256`
  - `execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes signatures) → bool success` — owner-signed path.
- **Consumed by:**
  - `contracts/src/supply/szipUSD/DurationFreezeModule.sol` — drives BOTH Safes via `ISafe(mainSafe).execTransactionFromModule(...)` (line 283) and `ISafe(sidecar).execTransactionFromModule(...)` (line 305) for share rotation. Its inherited single-avatar Zodiac exec is inert; rotation goes through explicit `ISafe(src)` calls (lines 89/110/225).
  - `contracts/script/SummonSubstrate.s.sol` — asserts `ISafe(sidecar).isOwner(team)` / `ISafe(mainSafe).isOwner(team)`; builds the `addOwnerWithThreshold(team,1)` payload that Baal (an enabled module) self-calls via `execTransactionFromModule`; drives the main Safe as owner via `execTransaction`.
  - `contracts/script/CreditWarehouseDeployer.sol` — `setup` (build the warehouse Safe initializer), `enableModule`+`isModuleEnabled` (enable the Roles modifier), `getOwners`/`getThreshold` (post-deploy assert), `swapOwner` (hand the 1/1 owner from the deployer to the god owner), all owner-driven via `execTransaction`.
  - `contracts/script/DeployZipcode.s.sol` — enables the engine Zodiac modules on the engine Safe via the owner `execTransaction` → `enableModule` path.
  - `contracts/script/DeployShowcaseVAMM.s.sol` — enables the demo LP module on the existing engine Safe the same way.

### `ISafeProxyFactory.sol`
- **Shims:** GnosisSafeProxyFactory 1.3.0 @ `0xa6B71E26…6AB2` (generic) and the Baal-owned `0xC22834…10BC` (precompute path).
- **Declared surface (exact):**
  - `createProxyWithNonce(address _singleton, bytes initializer, uint256 saltNonce) → address proxy`
  - `proxyCreationCode() → bytes` (pure) — used to precompute the main-Safe CREATE2 address: deploy data `= abi.encodePacked(proxyCreationCode(), abi.encode(uint256(uint160(_singleton))))`, salt `= keccak256(abi.encodePacked(keccak256(initializer), saltNonce))`. 8-B1 passes empty initializer (BaalSummoner.sol:233).
- **Consumed by:**
  - `contracts/script/CreditWarehouseDeployer.sol` — `createProxyWithNonce(SAFE_L2_SINGLETON, setup(...), nonce)` on the generic `SAFE_PROXY_FACTORY_1_3_0` to deploy the warehouse Safe.
  - `contracts/script/SummonSubstrate.s.sol` — reads `proxyCreationCode()` off the live factory + `gnosisSingleton()` off the live summoner to precompute the main-Safe address (never deploys it itself; Baal summons it).

## Gotchas (inherited by consumers)
- **Module-exec is Call-only, value 0:** the engine Zodiac modules (e.g. `DurationFreezeModule`) drive the
  Safe via `execTransactionFromModule(to, 0, data, 0)` — `operation=0` (Call), `value=0`. No DelegateCall,
  no ETH.
- **Two distinct 1.3.0 factories:** generic `0xa6B7…6AB2` (warehouse Safe) vs Baal's own `0xC228…10BC`
  (main-Safe precompute). Don't conflate — wrong factory ⇒ wrong CREATE2 address.
- **1/1 owner pre-validated signature:** the owner-`execTransaction` path used by the deploy scripts relies
  on the `msg.sender == owner` scheme `signatures = abi.encodePacked(bytes32(uint160(owner)), bytes32(0), uint8(1))`
  (no ECDSA / no prior `approveHash`). Requires a threshold-1 Safe.
- **Team multisig becomes a Safe OWNER, not a module:** added via `addOwnerWithThreshold(team, 1)` —
  on the main Safe driven by Baal self-calling `execTransactionFromModule`; on the warehouse Safe the
  deployer's 1/1 owner is rotated to the god owner via `swapOwner`.
- **Empty initializer on the Baal main-Safe summon:** the CREATE2 salt uses `keccak256("")` (BaalSummoner
  passes `""` as initializer); the precompute must match this exactly or the asserted address diverges.
- **Never compiled:** these shims exist only because Safe (OZ 4.x) can't share a build with Euler (OZ
  5.0.2); signatures are matched to the Basescan-verified ABI, not trusted from a fork's auto-ABI.
