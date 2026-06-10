# 8x-01 — szALPHA bridge: SzAlpha + SzAlphaMirror + SzAlphaTokenPool + DeploySzAlphaBridge (wiring map)

> Source of truth = the kept code under `contracts/src/bridge/` + `contracts/script/DeploySzAlphaBridge.s.sol`.
> Ticket `tickets/bridge/8x-01-szalpha-wrapper-cct.md` + report `reports/8x-01-report.md` are intent only —
> **the `.sol` is final/authoritative**. Every claim below was read out of the code.

## Role
The cross-chain **xALPHA** — the liquid-staked-ALPHA leg the M1 szipUSD basket holds and the CRE marks.
Three contracts, two chains, joined by a Chainlink CCT (Cross-Chain Token) burn/mint lane:

- **`SzAlpha`** (chain **964**, Bittensor EVM) — a self-built UUPS-upgradeable 18-dp ERC-20 **liquid-staking
  wrapper**, the *pooled staker* over the Subtensor `StakingV2` precompile. `deposit(amount)` (payable) stakes
  native alpha under OUR validator on OUR subnet and mints fungible szALPHA shares; `redeem(shares)` unstakes
  and pays native alpha back. It implements `IXAlphaRate.exchangeRate()` (alpha-per-share, read live from
  stake accounting) and the CCT `mint`/`burn` leg. It is the ONLY contract with a stake surface.
- **`SzAlphaMirror`** (chain **Base 8453**) — a PLAIN canonical Chainlink `BurnMintERC20` (18-dp), the bridged
  mirror the protocol's Base-side consumers (basket LP, first-loss escrow) actually hold. **No stake / redeem /
  precompile / `IXAlphaRate` surface** — Base has no Subtensor precompiles, so all value accrual happens on 964
  and is reflected via `SzAlpha.exchangeRate()`. The mirror is a pure transport token; its supply is conserved
  1:1 against the 964 supply burned/minted across the lane.
- **`SzAlphaTokenPool`** (both chains) — a thin `BurnMintTokenPool` subclass (burn-on-source / mint-on-dest)
  that adds two deploy-time invariant asserts (18-dp; canonical RMN) and pins `advancedPoolHooks = address(0)`.
- **`DeploySzAlphaBridge`** — the both-chain deploy + self-serve wire script (no allowlisting), with an
  aggressive deploy-assert battery.

## Contracts involved (what each does)
| Contract / file | Chain | What it is |
|---|---|---|
| `src/bridge/SzAlpha.sol` (`is ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IXAlphaRate`) | 964 | The pooled-staker LST wrapper. `deposit`/`redeem` over `StakingV2` (`0x…0805`); `exchangeRate()`/`totalStaked()`/preview views; CCT `mint`/`burn`/`burnFrom`; `grantMintAndBurnRoles`/`getCCIPAdmin`/`setCCIPAdmin`; `pause`/`unpause`; `_authorizeUpgrade` onlyOwner. Implements the `IBurnMintERC20` face by hand — does **not** inherit the canonical (see Gotchas). |
| `src/bridge/SzAlphaMirror.sol` (`is BurnMintERC20`) | Base 8453 | One-line subclass: `BurnMintERC20(name, symbol, 18, 0, 0)` (decimals 18, `maxSupply 0` = unlimited, `preMint 0`). AccessControl-based mint/burn; inherits the canonical `grantMintAndBurnRoles`/`getCCIPAdmin`/`setCCIPAdmin`. Zero staking surface. |
| `src/bridge/SzAlphaTokenPool.sol` (`is BurnMintTokenPool`) | both | Ctor asserts `localTokenDecimals == 18` (`LocalDecimalsNot18`) + `rmnProxy == canonicalRmn` (`RmnNotCanonical`); pins hooks `address(0)`. `typeAndVersion() = "SzAlphaTokenPool 1.0.0"`. |
| `script/DeploySzAlphaBridge.s.sol` (`is Script`) | both | `deploy964` / `deployBase` / `_wire` / `setRemoteLane` + the assert battery. Holds the verified 964 + Base CCT address books (`bittensorConfig`/`baseConfig`). |
| `src/interfaces/bridge/ISubtensorPrecompiles.sol` | — | Minimal local `IStakingV2` (`addStake`/`removeStake`/`getStake`) + `IAddressMapping` (`addressMapping`) — **selectors only**, never used as a call target. |
| `src/interfaces/bridge/ICctRegistry.sol` | — | Minimal `IRegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin` + `ITokenAdminRegistry.{acceptAdminRole,setPool,getPool}`. |
| `src/interfaces/bridge/IXAlphaRate.sol` | — | The `exchangeRate()` face the NAV oracle (8-B4) + CRE-03 (8x-02) read. |

## Wiring — internal (per chain)

### SzAlpha (964) — construction + init
- **Proxy pattern.** `constructor()` only calls `_disableInitializers()`; all config is set in `initialize(name_, symbol_, netuid_, validatorHotkey_, owner_, ccipAdmin_)` behind an `ERC1967Proxy`. The init guards reject a zero `owner_`/`ccipAdmin_`/`validatorHotkey_`.
- **Authority split (set from genesis).** `owner()` (OZ Ownable, set to `owner_` in `__Ownable_init`) is the **TimelockController** — it gates `_authorizeUpgrade` (UUPS) + `pause`/`unpause`. `ccipAdmin` is a **separate, lower-privilege registrar** role (no mint/upgrade/fund power) that performs the one-time CCIP registration; returned by `getCCIPAdmin()`, transferable via `setCCIPAdmin` (onlyCcipAdmin). `ccipPool` (the SOLE `mint`/`burn`/`burnFrom` caller) is set **once** via `grantMintAndBurnRoles` (onlyCcipAdmin, `PoolAlreadySet` on re-set).
- **Pooled-staker coldkey.** `wrapperColdkey = _readColdkey(address(this))` — derived ONCE at init via the AddressMapping precompile (`0x…080C`) and cached immutable. The wrapper itself is the single staker; there is no per-user SS58 mapping.
- **deposit/redeem (the StakingV2 leg).** `deposit(amount)` is payable, requires `msg.value == amount`, snapshots `_readStake()` + `totalSupply()`, then low-level `_callStaking(addStake(validatorHotkey, amount, netuid))`. **S4 effect-check:** reverts `AddStakeEffectMissing` unless `stakeAfter >= stakeBefore + amount` (a silent precompile fail = fund loss). Mints `_previewDeposit(amount, supplyBefore, stakeBefore)`. `nonReentrant`, `whenNotPaused`. `redeem(shares)` is the inverse — CEI ordering (compute → `_burn` → `removeStake` → pay native `call`), S4-checks BOTH that stake fell and balance rose by `>= alphaOut` (`RemoveStakeEffectMissing`), `NativeTransferFailed` on a failed pay. **`redeem` is `nonReentrant` but never `whenNotPaused`** (S3/S11 — value is NAV-anchored to redeemability). `receive()` accepts the native alpha credited by `removeStake`.
- **exchangeRate / virtual-offset genesis 1:1.** `exchangeRate() = (_readStake() + 1).mulDiv(1e18, totalSupply() + 1)`. The OZ ERC-4626 **virtual offset** (`VIRTUAL_SHARES = VIRTUAL_STAKE = 1`) is used in both `_previewDeposit`/`_previewRedeem` (round **Floor**, in the protocol's favor) and `exchangeRate`: never divides by zero, and at genesis (supply=stake=0) yields a clean **1:1** (`exchangeRate() == 1e18`). This **replaced** the ticket's "mint 1e3 dead shares to address(0)" (impossible in OZ; would not prevent div-by-zero). The classic ERC-4626 donation/inflation attack is **structurally inapplicable** — Subtensor attributes stake to the caller's coldkey and `getStake` reads only `wrapperColdkey`, so a third party cannot inflate the backing stake; only validator rewards lift it (benign).
- **Precompiles called low-level.** State-changing `addStake`/`removeStake` go through `STAKING_V2.call(abi.encodeWithSelector(...))`; `getStake`/`addressMapping` via `staticcall` (decoded `>= 32` bytes else `PrecompileCallFailed`). The interfaces exist only to source the 4-byte selectors (a *typed* call to the Frontier precompile "never reaches the runtime").
- **CCT leg.** `mint(account, amount)` onlyCcipPool + `whenNotPaused`; `burn(amount)` / `burnFrom(account, amount)` / `burn(address, amount)` alias onlyCcipPool, **not** pausable. `decimals()` pinned `pure → 18`. `__gap[45]` reserves UUPS storage.

### SzAlphaMirror (Base 8453)
- A canonical `BurnMintERC20` — **constructor-set** name/symbol/decimals(18)/maxSupply(0)/preMint(0). At construction `DEFAULT_ADMIN_ROLE` + `ccipAdmin` are granted to the deployer (`new SzAlphaMirror` caller = the script). Mint/burn is AccessControl-gated; the pool is granted via the inherited `grantMintAndBurnRoles`. There is **no `owner()`** (it is AccessControl, not Ownable) — which is exactly why registration uses `getCCIPAdmin` (Gotchas).

### SzAlphaTokenPool (both)
- `constructor(token, localTokenDecimals, rmnProxy, router, canonicalRmn)` → `BurnMintTokenPool(token, localTokenDecimals, address(0) /*hooks*/, rmnProxy, router)`, then asserts **18-dp** + `rmnProxy == canonicalRmn`. `rmnProxy` is immutable in `TokenPool` (S9 → redeploy, never mutate, on an RMN rotation). The rate-limiter is **not** set here — it is configured per-lane post-deploy via `applyChainUpdates` (`setRemoteLane`).

### DeploySzAlphaBridge — both-chain deploy + self-serve wire
- **`deploy964(netuid_, validatorHotkey_, timelock, ccipAdmin)`:** `_assertCctAddresses(bittensorConfig())` → deploy `SzAlpha` impl → deploy `ERC1967Proxy(impl, initialize(...))` (owner=timelock, ccipAdmin) → deploy `SzAlphaTokenPool(token, 18, armProxy, router, armProxy)` → `_wire` → `_assertDeployed` (owner==timelock + RMN/decimals).
- **`deployBase(timelock)`:** `_assertCctAddresses(baseConfig())` → `new SzAlphaMirror` → pool → `_wire` → `_assertPoolRmnAndDecimals` → then hands the mirror's authority to the timelock and revokes the deployer: `setCCIPAdmin(timelock)`, `grantRole(DEFAULT_ADMIN_ROLE, timelock)`, `revokeRole(DEFAULT_ADMIN_ROLE, address(this))`. (The revoke target is `address(this)` — the script is the role-holder, not the external caller.)
- **`_wire(token, pool, cfg)` (self-serve, identical both chains):** `token.call(grantMintAndBurnRoles(pool))` (both tokens expose it) → `registerAdminViaGetCCIPAdmin(token)` → `acceptAdminRole(token)` → `setPool(token, pool)`. **No allowlisting.** Lane config is deliberately deferred to `setRemoteLane`.
- **`setRemoteLane(pool, remoteChainSelector, remotePoolAddress, remoteTokenAddress, outbound, inbound)`:** builds one `TokenPool.ChainUpdate` and calls `applyChainUpdates(new uint64[](0), adds)`. Run once both chains' pools exist, per direction, under the timelock.
- **The 5-address re-read battery (`_assertCctAddresses`).** Re-reads `typeAndVersion()` on-chain for router / TAR / registryModule / tokenPoolFactory and matches the expected string, plus `_hasCode(armProxy)`. The NatSpec is explicit that a router-only check is insufficient — a mis-wired registry module would slip a router-only gate. `_assertDeployed` additionally checks `owner()==timelock` (S1) and `_assertPoolRmnAndDecimals` checks the token `decimals()==18` (S8) + `pool.getRmnProxy()==armProxy` (S9). **Wiring MUST NOT proceed unless every assert passes.**
- **Address books (verified on-chain 2026-06-09).** Base: chainSelector `15971525489660198786`, router `0x881e…58bCD` ("Router 1.2.0"), TAR `0x6f6C…1e37` ("TokenAdminRegistry 1.5.0"), registryModule `0xAFEd…D77f` ("RegistryModuleOwnerCustom 1.6.0"), factory `0xcD66…4D16` ("TokenPoolFactory 1.5.1"), armProxy `0xC842…d3E8`. 964 (Bittensor): chainSelector `2135107236357186872`, router `0xD941…60B8`, TAR `0xe72d…8Be6`, registryModule `0xcDca…35C3`, factory `0x8FE3…1602`, armProxy `0x02A4…894d`.

## Wiring — cross-component (who points at whom)
- **The mirror is the xALPHA leg.** The Base `SzAlphaMirror` is the production swap-in for the M1 **stand-in** xALPHA token across every Base consumer:
  - **8-B5/8-B6 basket LP** — the zipUSD/xALPHA ICHI LP leg (`8-B6-LpStrategyModule.md`: `token0()/token1()` = zipUSD/xALPHA); the basket *holds* the mirror.
  - **8-Bx `LienXAlphaEscrow.xAlpha`** — the per-lien first-loss bond asset (`src/loss/LienXAlphaEscrow.sol:56` — "the bridged xALPHA / 8x-01 `SzAlphaMirror`; a generic ERC-20 in M1 tests"). Item-10 re-points it via the Timelock-settable `setXAlpha`, replacing the stand-in.
- **`exchangeRate()` is the rate face, not a balance face.** `SzAlpha.exchangeRate()` (on 964) is the `IXAlphaRate` getter the **NAV oracle (8-B4)** and **CRE-03 (8x-02)** annualize. NOTE the cross-chain seam: on Base the *balance* token is the mirror (no `exchangeRate`), and 8-B4 has a separate `setXAlphaRateOracle` to wire a Base-side rate oracle (8x-02 `SzAlphaRateOracle`) that surfaces the 964 rate; when unset, M1 reads the stand-in's own `exchangeRate()` directly (`8-B4-SzipNavOracle.md` §8x-02 split). So the rate originates on 964 (`SzAlpha`), the balance lives on Base (mirror), and 8x-02 bridges the rate.
- **The CCT lane joins them.** `SzAlpha.ccipPool` (964) ⟷ `SzAlphaMirror`'s pool (Base) via the two `SzAlphaTokenPool`s; burn-on-source/mint-on-dest conserves supply 1:1. The pools register through the **live Base CCT** `RegistryModuleOwnerCustom 1.6.0` + `TokenAdminRegistry 1.5.0` (the `deployBase` fork test exercises the real registry).

## Item-10 deploy facts (PROGRESS row 373)
1. **Supply the real fixtures.** Pass the registered `NETUID` + `VALIDATOR_HOTKEY` to `deploy964` (literals are `initialize` args; fixtures until subnet/validator registration).
2. **Run `deploy964` on a 964 RPC.** Required to exercise the 964 CCT 5-address asserts — un-fork-testable here (no public Subtensor fork node).
3. **Wire the lane.** Once BOTH pools exist, call `setRemoteLane` **per direction** with ops-decided rate limits, **under the timelock**.
4. **Hand off ownership.** Transfer the **pool** ownership to the timelock (2-step `Ownable2Step`) **after** `applyChainUpdates`, and set the token `ccipAdmin → timelock/multisig`. (`deployBase` already hands the mirror's `DEFAULT_ADMIN_ROLE` + `ccipAdmin` to the timelock and revokes the deployer; 964's `owner` is the timelock from genesis, so only its `ccipAdmin` is moved.)
5. **Calibrate denomination.** Calibrate the TAO/alpha/rao denomination of `deposit`'s `msg.value == amount` against the live 964 runtime (the wrapper is delta-robust via S4, but the unit convention is deploy-time).
6. **Wire the consumers.** Wire the deployed `SzAlpha`/mirror as the `xALPHA` leg into 8-B5/8-B6 (basket LP) + 8-Bx `LienXAlphaEscrow.xAlpha` (via `setXAlpha`), replacing the stand-in. Assert the production token is **hookless / feeless / non-rebasing** (8-Bx has no balance-delta defense).

## Gotchas (build-exposed corrections — code wins over the ticket)
- **`registerAdminViaGetCCIPAdmin`, NOT `registerAdminViaOwner`.** `registerAdminViaOwner` calls `IOwner(token).owner()` and requires it to equal `msg.sender` — impossible here: the mirror (`BurnMintERC20`) is AccessControl-based with **no `owner()`** (the call reverts), and `SzAlpha.owner()` is the timelock from genesis (never the deployer EOA). The audited path uses the separate `ccipAdmin` registrar role returned by `getCCIPAdmin()`. `SzAlpha` implements `getCCIPAdmin`/`setCCIPAdmin`; the mirror inherits them.
- **UUPS ⊥ constructor-based `BurnMintERC20`.** The ticket said "`SzAlpha is BurnMintERC20 … UUPSUpgradeable`", but `BurnMintERC20` is non-upgradeable (constructor-set name/symbol/decimals/roles, OZ-4.8.3-bound) — behind a proxy its constructor never runs. So **`SzAlpha` is a FRESH OZ-Upgradeable token** (ERC20/Ownable/Pausable/ReentrancyGuard/UUPS) that implements the `IBurnMintERC20` surface (`mint`/`burn`×2/`burnFrom`/`grantMintAndBurnRoles`/`getCCIPAdmin`) by hand; **only the mirror inherits the canonical** `BurnMintERC20`, so the audited mint/burn/role code is used where it can be.
- **The "8x exception" OZ version seam (WOOF-00 EXTENDED).** Three OZ ecosystems coexist under one solc 0.8.24 invocation via **versioned import-prefix remaps** (no core bump): `chainlink-ccip` pool stack → `@openzeppelin/contracts@5.3.0` onto the scaffold's 5.0.2 tree; the canonical `BurnMintERC20` → `@openzeppelin/contracts@4.8.3` onto chainlink-local's vendored 4.8.3; `SzAlpha`'s UUPS leg → OZ-Upgradeable 5.1.0 from evk-periphery, context-scoped. `AdvancedPoolHooks` (the only `@chainlink/policy-management` dep) is not in the `BurnMintTokenPool` import graph (hooks pinned `address(0)`), so it never compiles → no missing-dep blocker.
- **964 lane is un-fork-testable here.** No public Subtensor fork node — the Subtensor precompiles are `vm.etch`-mocked in unit tests and the CCIP relay is driven at the pool level with mock Router/RMN. Only the Base mirror + its registration is fork-real (against the live Base CCT registry). The `deploy964` 5-address asserts + a real stake round-trip are deferred to the 964 deploy.
- **`maxSupply = 0` is "unlimited", not "frozen".** The mirror's cross-chain supply is bounded by the 964 mint/burn, not a Base cap.
