# 8-B1 — szipUSD Baal substrate scaffold (summon script) (§4.5 / `reports/design/baal-spec.md` 8-B1)

> **BUILT-VERIFIED 2026-06-07 (keep-the-build doctrine).** Materialized + kept on disk; `forge build` green +
> **8/8 fork tests pass on a live Base-mainnet fork** (115/115 total, no regression — run it yourself:
> `forge test --match-contract SummonSubstrateTest`). Code: `contracts/script/SummonSubstrate.s.sol`,
> `contracts/test/SummonSubstrate.t.sol`, interfaces under `contracts/src/interfaces/{baal,safe}/`. The full
> authority lifecycle is fork-proven: summon → team-owner injection on BOTH Safes → wireability (team drives
> `setShamans([gate],[2])` + `enableModule` on both Safes with **zero Shares**) → governance proven inert
> (`sponsorProposal`/`processProposal` revert `!sponsor`; direct `setShamans` reverts `!baal`). **Build-discovered
> correction (code is truth):** the BaalSummoner's Safe proxy factory is **`0xC22834581EbC…`** (verified via
> on-chain storage slot 208), **NOT** `SAFE_PROXY_FACTORY_1_3_0` (`0xa6B7…`) — the first compute used the wrong
> factory and the `compute==avatar` fail-closed assert caught it (exactly as designed). New constant
> `BaseAddresses.BAAL_SAFE_PROXY_FACTORY`; `gnosisSingleton` (read live) = `0x69f4D178…`.

**Deliverable**
The szipUSD junior-vault substrate: a **summon SCRIPT** (not a compiled-from-source contract — Baal is solc 0.8.7
and **live on Base 8453**; we interact, never compile it, same rule as the Euler deps) that calls the deployed
`BaalAndVaultSummoner` to produce, in one flow:
- a **Baal (Moloch v3) DAO**,
- its **main Gnosis Safe** (the Baal avatar/target — ragequit target, holds FREE equity),
- a **non-ragequittable sidecar Safe** (holds COMMITTED equity — the structural freeze, §8),
- the **Loot** and **Shares** ERC20 clones (Loot soulbound/paused at genesis; **Shares = 0 forever**),

and injects the **team multisig as a Safe owner/signer** (the ADMIN authority) so the otherwise governance-inert
substrate is driveable. Files:
- `contracts/script/SummonSubstrate.s.sol` — `contract SummonSubstrate is Script` with an internal
  `_summon(address teamMultisig, uint256 saltNonce) returns (Substrate memory)` callable from both `run()` and the
  fork test. Returns a `struct Substrate { address baal; address mainSafe; address sidecar; address loot; address
  shares; }`.
- `contracts/src/interfaces/baal/IBaalAndVaultSummoner.sol` — NET-NEW. `summonBaalAndVault(bytes,bytes[],uint256,
  bytes32,string) returns (address,address)` + `vaultIdx() returns (uint256)` + `vaults(uint256) returns (uint256
  id, bool active, address daoAddress, address vaultAddress, string name)` (the full 5-field struct, for the
  registration assert).
- `contracts/src/interfaces/baal/IBaalToken.sol` — NET-NEW. `paused()`, `name()`, `symbol()`, `decimals()`,
  `owner()`, `totalSupply()` (the Loot/Shares clone surface the test reads).
- Extend `contracts/src/interfaces/baal/IBaal.sol` — add `target()`, `executeAsBaal(address,uint256,bytes)`,
  `totalShares()`, `totalLoot()`, `totalSupply()`, `quorumPercent()`, `sponsorThreshold()`, `proposalOffering()`,
  `votingPeriod()`, `gracePeriod()`, `adminLock()`, `managerLock()`, `governorLock()`, and the proposal-lifecycle
  fns for the negative test: `submitProposal(bytes,uint32,uint256,string) payable returns (uint256)`,
  `sponsorProposal(uint32)`, `processProposal(uint32,bytes)`. (`avatar`/`lootToken`/`sharesToken`/`shamans` already
  present.)
- Extend `contracts/src/interfaces/baal/IBaalSummoner.sol` — add `gnosisSingleton() returns (address)` (public
  getter, `BaalSummoner.sol:20`), read live for the main-Safe compute.
- Extend the EXISTING `contracts/src/interfaces/safe/ISafe.sol` — add `getOwners()`, `isOwner(address)`,
  `getThreshold()`, and `execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,
  uint256 baseGas,uint256 gasPrice,address gasToken,address payable refundReceiver,bytes signatures) returns
  (bool)` (the owner-exec path for wiring). (`enableModule`/`isModuleEnabled`/`execTransactionFromModule`/
  `addOwnerWithThreshold` already present.)
- Extend the EXISTING `contracts/src/interfaces/safe/ISafeProxyFactory.sol` — add `proxyCreationCode() returns
  (bytes)` for the main-Safe address compute (do NOT create a second factory interface).
- `contracts/test/SummonSubstrate.t.sol` — Base-mainnet **fork** test (inherits `ForkConfig`) summoning against the
  live `BaalAndVaultSummoner` and asserting the full substrate config + the admin-injection + wireability. Imports
  `BaseAddresses` from `../script/BaseAddresses.sol` (it lives in `script/`, not `src/`).

(No protocol economics here — this is the bare substrate every other 8-B component bolts onto.)

**Spec §**
`claude-zipcode.md` §4.5 (the substrate; the new §4.5 item-0 "Safe authority — two-tier admin/operator" note) +
`reports/design/baal-spec.md` 8-B1 (the authoritative build recipe + the Authority model block, both rewritten 2026-06-07). Cross:
- §4.5.1 (the substrate is referenced by the engine modules), §6.4 (Exit Gate consumes `baal`+`loot`+`manager`),
  §7/§12 (`SzipNavOracle` sums balances across **both** Safes), §11 (the sidecar = the freeze).
- `BAAL-ZODIAC-REFERENCE-MAP.md` §2.1 (bitmask: manager=2), §2.2 (ragequit can't be gated → Exit-Gate custody),
  §2.3 (the freeze is ONE structural sidecar), §3 "8-B1".
Locked §17 (honored, not reopened): Baal/Zodiac substrate; **Shares = 0** (ragequit pro-rata pure-Loot); the
junior is the main product; collateral mocked. The **authority model** (team-admin signer + CRE operator module) is
the §4.5 item-0 / `reports/design/baal-spec.md` resolution of the old (un-reachable) "post-deploy `setShamans`" seam — user-ratified
2026-06-07; it does not reopen a §17 token-model decision (Shares still 0; authority is Safe ownership, not votes).

**Model from (verified against `reference/`)**
All paths are `reference/Baal/contracts/` unless noted. **Inherit/compile nothing from `reference/Baal`** (pragma
0.8.7, OZ-4 upgradeable — would collide); call the **live** deployments through minimal local 0.8.24 interfaces.
- **`BaalAndVaultSummoner.summonBaalAndVault(bytes initializationParams, bytes[] initializationActions, uint256
  saltNonce, bytes32 referrer, string name) returns (address daoAddress, address vaultAddress)`** —
  `higherOrderFactories/BaalAndVaultSummoner.sol:62-76` (VERIFIED). It (1) calls
  `_baalSummoner.summonBaalFromReferrer(...)` → Baal + main Safe + Loot/Shares clones + runs the init-actions, then
  (2) `summonVault(dao,name) → _baalSummoner.deployAndSetupSafe(dao)` deploys the **sidecar** (`:79-87`) and registers
  it (`vaults`/`vaultIdx`, `:31/:144-153`). `daoAddress` = Baal; `vaultAddress` = **sidecar**. The interface to
  author matches `reference/Baal/contracts/interfaces/IBaalAndVaultSummoner.sol` (VERIFIED exists, same selector).
- **`initializationParams = abi.encode(string name, string symbol, address safe(0), address forwarder(0), address
  loot(0), address shares(0))`** — `BaalSummoner.sol:281-288` `_summonBaal` decode (VERIFIED). All-zero safe/loot/
  shares ⇒ the summoner deploys fresh ones; forwarder 0 ⇒ no EIP-2771. Mirrors `getBaalParams` (`test/utils/baal.ts:
  252-262`). `name`/`symbol` name the **internal** tokens only (Loot = "`<name>` LOOT"/"`<symbol>`-LOOT", Shares =
  `name`/`symbol`, `BaalSummoner.sol:166-180`); these are never user-facing (Loot held only by the Gate; Shares = 0).
  Use clear non-user names, e.g. `name="Zipcode szipUSD Junior"`, `symbol="zJR"` (cosmetic — flag in report).
- **`initializationActions`** — each entry is `abi.encodeWithSelector(<Baal fn>.selector, args...)`; the summoner
  multisends them as one DelegateCall during `Baal.setUp`, executed BY the Safe (avatar) so every `baalOnly`/
  `baalOr*Only` guard passes (`Baal.sol:280-288` exec; `_msgSender()==avatar`). Order per `getBaalParams`
  (`baal.ts:242-249`) + the NEW admin action:
  1. `setAdminConfig(bool pauseShares=true, bool pauseLoot=true)` — `Baal.sol:749` (VERIFIED). No-op confirm (tokens
     already paused by `deployTokens`, `BaalSummoner.sol:303-304`).
  2. `setGovernanceConfig(bytes)` — `Baal.sol:853` (VERIFIED); payload `abi.encode(uint32 voting, uint32 grace,
     uint256 offering, uint256 quorum, uint256 sponsor, uint256 minRetention)` (`Baal.sol:857-867`,
     `baal.ts:204-214`). Use **inert** values: `voting=2 days`, `grace=1 days` (sane, never bind), `offering=0`,
     `quorum=0`, **`sponsor=type(uint256).max`** (un-meetable sponsor threshold), `minRetention=0`. Constraint
     `minRetention<=100` (`Baal.sol:868-869`) — satisfied. Zero Shares makes this moot regardless; the un-meetable
     sponsor is belt-and-suspenders.
  3. `setShamans(address[] (empty), uint256[] (empty))` — `Baal.sol:686` (VERIFIED). No shaman at summon (no Gate
     address yet). Empty arrays = no-op loop.
  4. `mintShares(address[] (empty), uint256[] (empty))` — `Baal.sol:774`. **Zero Shares.**
  5. `mintLoot(address[] (empty), uint256[] (empty))` — `Baal.sol:814`. **Zero Loot at summon.**
  6. **`executeAsBaal(address mainSafe, uint256 0, bytes addOwnerPayload)`** — `Baal.sol:601-614` (VERIFIED: does
     `_to.call{value}(_data)` **as the Baal**, `baalOnly`). `addOwnerPayload =
     abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, mainSafe, 0, addOwnerCalldata, uint8(0))`
     where `addOwnerCalldata = abi.encodeWithSelector(ISafe.addOwnerWithThreshold.selector, teamMultisig,
     uint256(1))`. Chain: Safe→`Baal.executeAsBaal` (avatar ✓) → Baal→`mainSafe.execTransactionFromModule(mainSafe,
     0, addOwner, Call)` (Baal is the Safe's enabled module ✓) → Safe→`mainSafe.addOwnerWithThreshold(team,1)`
     (`msg.sender==self`, `authorized` ✓). **Requires `mainSafe` at encode time** — see compute-then-assert below.
- **Main-Safe address compute (`reference/Baal/contracts/BaalSummoner.sol:225-244,248-266` + Safe 1.3.0 factory).**
  The main Safe = `gnosisSafeProxyFactory.createProxyWithNonce(gnosisSingleton, bytes(""), saltNonce)`
  (`BaalSummoner.sol:231-237` via `deployAndSetupSafe(baal, saltNonce)` at `:314`). Safe 1.3.0
  `createProxyWithNonce` salt = `keccak256(abi.encodePacked(keccak256(bytes("")), saltNonce))`; address =
  `keccak256(0xff ++ factory ++ salt ++ keccak256(proxyCreationCode ++ abi.encode(uint256(uint160(singleton)))))`.
  Read `proxyCreationCode()` from the **live** factory and `gnosisSingleton()` from the **live** `BaalSummoner`
  (public getter, `BaalSummoner.sol:20`) — DO NOT hardcode the creation code or the singleton. **Note:**
  `BaalSummoner.gnosisSafeProxyFactory` is **internal (no getter)** — so the factory address can't be read off the
  summoner. **BUILD-VERIFIED FACTORY:** it is `BaseAddresses.BAAL_SAFE_PROXY_FACTORY` (`0xC22834581EbC…`, confirmed
  by reading BaalSummoner storage slot 208 — a 1.3.0 factory, but a DIFFERENT address from the `0xa6B7…`
  `SAFE_PROXY_FACTORY_1_3_0`). This is safe because **the `require(computed == IBaal(baal).avatar())` assert after
  summon fails CLOSED on any factory mismatch**: if the summoner ever used a different factory, `computed` ≠
  `avatar` (the real deploy) → revert, no silent/wrong-Safe adoption (this assert actually caught the initial
  wrong-factory guess during the build). `vm.computeCreate2Address(salt, initCodeHash, deployer=factory)` is the forge helper;
  `salt = keccak256(abi.encodePacked(keccak256(bytes("")), saltNonce))`, `initCodeHash =
  keccak256(abi.encodePacked(proxyCreationCode, abi.encode(uint256(uint160(gnosisSingleton)))))`.
- **Sidecar owner-add (post-summon, team-signed via the OWNER `execTransaction` path — CONCRETE).**
  `summonVault → deployAndSetupSafe(dao)` (NO-nonce overload, `BaalSummoner.sol:248-266`, `createProxy` `:254`)
  deploys the sidecar AFTER the Baal `setUp`, so it can't ride the init-actions — the sidecar ships **owned 1/1 by
  Baal, no team owner** (the one genuine inert window, security F6.2). `_summon` MUST close it in the same flow (do
  NOT defer it): the team-admin is now an owner of the **main** Safe, so it drives the main Safe to reach the
  sidecar through Baal:
  `mainSafe.execTransaction(baal, 0, executeAsBaal(sidecar, 0, execTransactionFromModule(sidecar, 0,
  addOwnerWithThreshold(team,1), Call)), Call, …)`.
  **The exact signature scheme (deterministic, fork-provable, also the production path):** Safe's
  pre-validated-signature path accepts `v=1` when **`msg.sender == owner`** (no prior `approveHash` needed). So the
  caller (the team owner) passes `signatures = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0),
  uint8(1))` and ALL other `execTransaction` params zero (`safeTxGas=baseGas=gasPrice=0`, `gasToken=refundReceiver=
  address(0)`). In the **fork test** make `team` a plain EOA and `vm.startPrank(team)` so `msg.sender == owner` holds
  (no ECDSA needed). The SAME owner-exec path is used for the wireability proof (`setShamans`, `enableModule`). In
  production the real Gnosis multisig collects m-of-n sigs instead of the pre-validated single-owner form; the
  on-chain `execTransaction` shape is identical. **`run()` performs the sidecar owner-add (or hard-reverts) — it must
  NOT exit "successful" having left the sidecar Baal-only/undriveable** (the failure mode this ticket exists to
  prevent, applied to the sidecar).
- **Getters** (`Baal.sol`): `avatar()`/`target()` (Zodiac Module base state vars; both == main Safe,
  `Baal.sol:263-264`), `lootToken()`/`sharesToken()` (`:29-30`), `totalLoot()` (`:989`), `totalShares()` (`:994`),
  `totalSupply()` (`:999` = loot+shares), `shamans(address)` (`:47`), `adminLock()/managerLock()/governorLock()`
  (`:44-46`). `IBaalToken.paused()/name()/symbol()/decimals()/owner()/totalSupply()` on the Loot/Shares clones
  (`LootERC20.sol`; no `decimals()` override → 18). Safe: `getOwners()/isOwner(address)/getThreshold()/
  isModuleEnabled(address)` (Basescan SafeL2 1.4.1 ABI — verify on fork).
- **NOT** `summonBaal`/`summonBaalFromReferrer` directly (those don't make the sidecar) and **NOT**
  `BaalAdvTokenSummoner` (bring-your-own tokens — we want fresh paused clones). **NOT** the `SummonBaal` event for
  address extraction (use the return tuple + getters — a Solidity script can't parse an external call's event).

**Starting state**
- WOOF-00 scaffold present; `foundry.toml` `base` rpc (`BASE_RPC_URL`) + `allow_paths=["../reference"]`; `ForkConfig`
  + `BaseAddresses` present. `contracts/src/interfaces/baal/{IBaal,IBaalSummoner}.sol` and `safe/ISafe.sol` exist
  (extend them). Header on every new file: `// SPDX-License-Identifier: GPL-2.0-or-later` then
  `pragma solidity 0.8.24;` (keep exactly; do not bump).
- Add `BaseAddresses` constant if missing: the Loot/Shares singletons + the proxy factory are already present
  (`SAFE_PROXY_FACTORY_1_3_0`, `BAAL_AND_VAULT_SUMMONER`, `BAAL_SUMMONER`, `BAAL_SINGLETON`). Add Loot/Shares
  singleton constants if used by the test (`0x52ac…`, `0xc650…`).
- The Exit Gate (item 3) and the CRE operator/strategy modules do **not** exist yet — 8-B1 leaves their wiring
  seams open (manager grant + module enabling), provably reachable via the team-admin signer (proven in the test
  with a **mock gate** address and a **mock module** address).

**Do NOT**
- **Do NOT compile any `reference/Baal` / Safe / Zodiac source** (OZ-4 / pragma-0.8.7 collision). Call live
  deployments via the local 0.8.24 interfaces only.
- **Do NOT mint any Shares, ever** (zero Shares is the ragequit-purity + governance-inertness invariant). Do NOT add
  "bootstrap shares" — authority is **Safe ownership**, not votes (the ratified model).
- **Do NOT** attempt to grant the Gate `manager` or enable strategy modules via a **Baal proposal** — governance is
  inert by design (no Shares). All such wiring is the **team-admin signer** path.
- **Do NOT** `executeAsBaal(mainSafe, 0, addOwnerWithThreshold(...))` directly — it reverts (caller = Baal ≠ Safe);
  it MUST wrap through `execTransactionFromModule(mainSafe, …)` (Safe self-auth).
- **Do NOT hardcode the main-Safe address or the Safe proxy creation code** — compute from live chain + assert
  `== baal.avatar()` (the WOOF-00 lesson: a hardcoded/unverified address is the failure mode).
- **Do NOT** `lockManager`/`lockGovernor`/`lockAdmin` here (deferred — the Gate needs `manager` granted later).
- **Do NOT** leave the substrate un-driveable (zero-Shares + Baal-owned Safe with no other authority = a frozen
  vault — the bug this ticket exists to prevent).

**Key requirements**
- `_summon(teamMultisig, saltNonce)` builds `initializationParams` + the 6 `initializationActions` above and calls
  `IBaalAndVaultSummoner(BaseAddresses.BAAL_AND_VAULT_SUMMONER).summonBaalAndVault(params, actions, saltNonce,
  bytes32(0) /*referrer*/, name)`. Before the call it **computes** `predictedMainSafe` (live `proxyCreationCode` +
  `gnosisSingleton` + salt). After: read `baal=daoAddress`, `sidecar=vaultAddress`, `mainSafe=IBaal(baal).avatar()`,
  `loot`/`shares` from getters; **`require(predictedMainSafe == mainSafe)`** (custom error). Then perform the
  **sidecar owner-add** (team-signed) so both Safes carry the team owner.
- `run()` reads `teamMultisig` + `saltNonce` from env (`vm.envAddress`/`vm.envOr`) and broadcasts `_summon`.
- Discharge: the substrate is **wireable** — the test must prove the team-admin can (a) `setShamans([mockGate],[2])`
  through the main Safe and (b) `enableModule(mockModule)` on **both** Safes, with **zero Shares / no proposal**.

**Done when**
`forge build` green (solc 0.8.24) + `contracts/test/SummonSubstrate.t.sol` passes on a **live Base-mainnet fork**
(`vm.createSelectFork("base")`). Tests:
- *Summon shape:* after `_summon(team, salt)`: `baal != 0`, `mainSafe != 0`, `sidecar != 0`, `mainSafe != sidecar`;
  `IBaal(baal).avatar() == IBaal(baal).target() == mainSafe`; `loot == IBaal(baal).lootToken()`,
  `shares == IBaal(baal).sharesToken()`.
- *Address compute (load-bearing):* `predictedMainSafe == mainSafe` (the script's own assert) — additionally
  re-derive it in the test independently and assert equality (proves the compute, not just the assert).
  Also assert `loot != address(0)` and `shares != address(0)` (a failed clone deploy → zero/reverting getters).
  Use **compile-time constant** saltNonces in the test (e.g. `uint256 constant SALT = 1; SALT2 = 2;`) — never
  `block.timestamp`/entropy (the compute re-derivation must be reproducible across the fork-block pin).
- *Address compute (load-bearing) + salt-sensitivity:* the script's own `require(predicted == mainSafe)` plus an
  independent in-test re-derivation `== mainSafe`; AND assert the re-derivation with `SALT2` does **NOT** equal
  `mainSafe` (proves the compute is genuinely salt-sensitive, not a constant/coincidence).
- *Token state:* `IBaalToken(loot).paused() == true`, `IBaalToken(shares).paused() == true`;
  `IBaalToken(loot).decimals() == 18`; `loot.totalSupply() == 0`, `shares.totalSupply() == 0`;
  `IBaal(baal).totalShares() == 0`, `IBaal(baal).totalLoot() == 0`, `totalSupply() == 0`; both tokens
  `owner() == baal`.
- *Governance inert:* `quorumPercent()==0`, `sponsorThreshold()==type(uint256).max`, `proposalOffering()==0`,
  `votingPeriod()==2 days`, `gracePeriod()==1 days`; `adminLock()==managerLock()==governorLock()==false`.
- *Safe wiring:* both Safes have `isModuleEnabled(baal) == true`, `getThreshold() == 1`;
  `getOwners()` contains `baal`; **`isOwner(teamMultisig) == true` on BOTH Safes** (the admin injection). Assert
  `isOwner(team)==false` on the **sidecar BEFORE** the owner-add and `==true` after (proves the add did it, not the
  summoner — catches a swallowed `execTransactionFromModule` no-op; the inner module-exec returns bool, doesn't
  revert, so always assert the *effect*).
- *Sidecar registered:* snapshot `idx = IBaalAndVaultSummoner(SUMMONER).vaultIdx()` after summon, then
  `vaults(idx)` returns `(id=idx, active=true, daoAddress=baal, vaultAddress=sidecar, name=…)`.
- *Wireability (the core proof — drive the OWNER `execTransaction` path, not the module path):* with **zero
  Shares**, `vm.startPrank(teamMultisig)` and call `mainSafe.execTransaction(...)` (pre-validated single-owner sig)
  to (a) `Baal.setShamans([mockGate],[2])` — assert `shamans(mockGate)==0` before and `==2` after (manager bit); and
  (b) `enableModule(mockModule)` on the main Safe AND, via the main-Safe→`executeAsBaal`→sidecar path, on the
  sidecar — assert `isModuleEnabled(mockModule)==true` on **both**. (Proves the production team-owner route is live,
  with zero Shares / no proposal.)
- *Negative — governance is a genuine dead-end (CORRECTED — `submitProposal` does NOT revert at zero Shares + zero
  offering; it succeeds unsponsored):* submit a proposal (`submitProposal(data,0,0,"x")` succeeds, `sponsor==0`),
  then `vm.expectRevert("!sponsor")` on `sponsorProposal(pid)` AND on `processProposal(pid,data)` (`Baal.sol:382/508`).
  PLUS the access-control negative: `vm.prank(0xBAD); vm.expectRevert("!baal"); IBaal(baal).setShamans(...)` (direct
  call, `_msgSender()!=avatar`) — proves the team-owner→Safe→Baal chain is the ONLY path to `setShamans`.
- *Idempotency / collision:* `vm.expectRevert()` around a second `_summon` with the **same** `saltNonce` (Safe proxy
  CREATE2 collision in the summoner); a **different** `saltNonce` produces distinct, independent addresses.

**Depends on**
WOOF-00 (scaffold + `ForkConfig` + `BaseAddresses` + the baal/safe interface stubs). Nothing else. Downstream:
`SzipNavOracle` (sums both Safes), the **Exit Gate** (consumes `baal`/`loot`, granted `manager(2)` by the team-admin),
items 8-B5…14 (strategy modules the team-admin enables under the CRE operator), item 9 (sidecar rotation), item 10
(real deploy: real team multisig, env-driven `saltNonce`, then the team wires the Gate + the engine module set).

**Open obligations this ticket CREATES (for PROGRESS "Open cross-ticket obligations"):**
- *Exit Gate (item 3):* the manager grant is `team-admin → Safe.execTransaction → Baal.setShamans([gate],[2])`
  (NOT a proposal, NOT raw post-deploy `setShamans` by anyone). Genesis seed mints Loot only **after** the Gate
  holds `manager`. **The Gate (and EVERY `manager`-holder) MUST be structurally unable to call `mintShares`**
  (`Baal.sol:774` is `baalOrManagerOnly`) — `manager` grants both `mintLoot` AND `mintShares`; minting any Shares
  destroys the zero-Shares governance-inertness invariant (security F4.2). Gate code only ever calls
  `mintLoot`/`burnLoot`; every downstream fork test asserts `IBaal(baal).totalShares()==0`.
- *Item 9 (sidecar rotation):* do **not** fund/route value into the sidecar until `isOwner(team)==true` on it and the
  team has proven it can drive it (security F6.2 — the sidecar ships Baal-only until 8-B1's owner-add lands).
- *Item 10 (deploy/wiring):*
  - real `TEAM_MULTISIG` MUST be a true **k-of-n (k≥2) Gnosis Safe**, never an EOA / 1-of-n — the main Safe's
    threshold-1 delegates ALL admin security to the team multisig's internal quorum (security F3.2). `run()` should
    reject an EOA (`code.length>0`) or loudly flag it.
  - **Remove Baal as a Safe OWNER** (`removeOwner`) once human signers are settled — keep Baal only as the ragequit
    **module**; a contract left as a threshold-1 owner is a standing signature-path surface (security F3.1).
  - the CRE operator module MUST be enabled **Roles-modifier-v2-scoped** (only its strategy entrypoints; NEVER
    `enableModule`/`addOwner`/`setShamans`/`mintShares`), never as a bare unscoped module (security F5.1/F5.2 — the
    `mockModule` enable in 8-B1's test is **test-only**, not the production wiring template).
  - use an **unpredictable, single-use** `saltNonce` + private (flashbots-style) submission — the main-Safe CREATE2
    address depends only on `(factory, singleton, saltNonce)` (empty initializer), so a fixed/sequential salt is
    front-run-griefable (a mirror tx pre-occupies the slot → summon reverts; fail-closed but a cheap grief, security
    F1.1/F6.1). The fork test's constant salts are test-only.
  - the team enables the CRE operator + strategy modules on both Safes + applies role-locks once the set is settled.
