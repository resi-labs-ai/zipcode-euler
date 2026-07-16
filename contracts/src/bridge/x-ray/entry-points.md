# Entry Point Map

> SzAlpha Bridge | 8 entry points | 3 permissionless | 2 role-gated | 3 admin/upgrade

> **CURRENT STATE (2026-06-20): scope-level summary; per-contract X-Rays are authoritative.** This bundled map
> predates the one-per-contract pass. The entry points themselves are unchanged, but the test-connected,
> per-contract treatment now lives in [`SzAlpha.md`](SzAlpha.md), [`SzAlphaRateOracle.md`](SzAlphaRateOracle.md),
> [`SzAlphaLockReleasePool.md`](SzAlphaLockReleasePool.md), [`SzAlphaTokenPool.md`](SzAlphaTokenPool.md), and
> [`SzAlphaMirror.md`](SzAlphaMirror.md). Use those for per-contract detail; this remains a quick cross-contract index.

Scope: authored functions only. Inherited Chainlink CCIP pool functions (`lockOrBurn`, `releaseOrMint`, `applyChainUpdates`) and inherited `BurnMintERC20` mint/burn/role functions live in out-of-scope base contracts and are listed under "Inherited (out of scope)".

---

## Protocol Flow Paths

### Setup (Deploy / Owner)

`SzAlpha.initialize()` → genesis seed deposit → handoff `owner()`→Timelock, `ccipAdmin`→multisig
`SzAlphaLockReleasePool(constructor)` / `SzAlphaTokenPool(constructor)` → `applyChainUpdates()` (rate limits, timelock) ◄── before lanes open

### User Flow (964)

`[init above]` → `SzAlpha.deposit{value}()`  ◄── not paused
                      ├─→ `SzAlpha.redeem()`  ◄── caller holds shares (never paused)
                      └─→ `SzAlpha.exchangeRate()` (view, consumed by CRE/NAV)

### Rate Transport (CRE → Base)

`CRE reads exchangeRate() on 964` → `Forwarder` → `SzAlphaRateOracle._processReport()` ◄── ts strictly newer
                                                       └─→ Base `SzipNavOracle` reads `exchangeRate()` ◄── gated on `fresh()`

### Bridge (CCT)

`SzAlphaLockReleasePool` locks szALPHA in `ERC20LockBox` (964)  ⇄  `SzAlphaTokenPool` burn/mint `SzAlphaMirror` (Base)

---

## Permissionless

### `SzAlpha.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, nonReentrant, whenNotPaused |
| Caller | Any staker |
| Parameters | minSharesOut (user-controlled), deadline (user-controlled); msg.value (user-controlled) |
| Call chain | `→ SzAlpha._readStake()` (staticcall getStake) `→ SzAlpha._callStaking()` (STAKING_V2.addStake) `→ _mint()` `→ msg.sender.call` (refund) |
| State modified | `totalSupply`, `_balances[msg.sender]` (+shares) |
| Value flow | TAO: sender → contract (staked); sub-rao remainder refunded → sender |
| Reentrancy guard | yes |

### `SzAlpha.redeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (NOT whenNotPaused — by design) |
| Caller | Any szALPHA holder |
| Parameters | shares (user-controlled), minTaoOut (user-controlled), deadline (user-controlled) |
| Call chain | `→ SzAlpha._previewRedeem()` `→ _burn()` `→ SzAlpha._callStaking()` (STAKING_V2.removeStake) `→ msg.sender.call` (payout) |
| State modified | `totalSupply`, `_balances[msg.sender]` (−shares) |
| Value flow | szALPHA burned; TAO: contract → sender (measured balance delta) |
| Reentrancy guard | yes |

### `SzAlpha.receive()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable |
| Caller | Subtensor precompile (credits TAO on `removeStake`); also any sender |
| Parameters | none |
| Call chain | none (empty body) |
| State modified | `address(this).balance` (+msg.value) |
| Value flow | TAO: sender → contract |
| Reentrancy guard | no (no logic) |

---

## Role-Gated

### `ccipAdmin`

#### `SzAlpha.setCCIPAdmin()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyCcipAdmin` |
| Caller | Current ccipAdmin (registrar) |
| Parameters | newAdmin (admin-provided) |
| Call chain | `→ emit CcipAdminTransferred` |
| State modified | `ccipAdmin` |
| Value flow | none |
| Reentrancy guard | no |

### CRE Forwarder

#### `SzAlphaRateOracle._processReport()`

| Aspect | Detail |
|--------|--------|
| Visibility | internal override (reached via `ReceiverTemplate.onReport`, forwarder-gated) |
| Caller | Chainlink Forwarder (CRE write path) |
| Parameters | report → (reportType, rate (keeper-provided), ts (keeper-provided)) |
| Call chain | `→ abi.decode` `→ anchor roll` `→ set latest/prev/curAnchor` |
| State modified | `latest`, `curAnchor`, `prevAnchor` |
| Value flow | none |
| Reentrancy guard | n/a (no external calls) |

---

## Admin-Only

| Contract | Function | Access | Parameters | State Modified |
|----------|----------|--------|------------|----------------|
| SzAlpha | `pause()` | `onlyOwner` (Timelock) | none | `_paused = true` |
| SzAlpha | `unpause()` | `onlyOwner` (Timelock) | none | `_paused = false` |
| SzAlpha | `_authorizeUpgrade()` | `onlyOwner` (Timelock) | newImplementation (admin-provided) | UUPS implementation slot |

---

## Initialization

| Contract | Function | Access | Notes |
|----------|----------|--------|-------|
| SzAlpha | `initialize(name,symbol,netuid,validatorHotkey,owner,ccipAdmin)` | `initializer` | One-time; derives+caches `wrapperColdkey`; constructor calls `_disableInitializers()` |
| SzAlphaLockReleasePool | `constructor(token,decimals,rmnProxy,router,lockBox,canonicalRmn)` | deploy | Reverts unless decimals==18 and rmnProxy==canonicalRmn |
| SzAlphaTokenPool | `constructor(token,decimals,rmnProxy,router,canonicalRmn)` | deploy | Same S8/S9 deploy-time invariants |
| SzAlphaMirror | `constructor(name,symbol)` | deploy | `BurnMintERC20(name,symbol,18,0,0)`; roles default to deployer |

---

## Inherited (out of scope)

| Contract | Inherited entry points | Source |
|----------|------------------------|--------|
| SzAlphaLockReleasePool | `lockOrBurn`, `releaseOrMint`, `applyChainUpdates`, rate-limit setters | `LockReleaseTokenPool` (Chainlink CCIP) |
| SzAlphaTokenPool | `lockOrBurn`, `releaseOrMint`, `applyChainUpdates`, rate-limit setters | `BurnMintTokenPool` (Chainlink CCIP) |
| SzAlphaMirror | `mint`, `burn`, `grantMintAndBurnRoles`, `getCCIPAdmin`, role admin | `BurnMintERC20` (Chainlink) |
| SzAlpha | ERC20 `transfer`/`approve`/`transferFrom` | `ERC20Upgradeable` (OZ) |

*Authored override `typeAndVersion()` exists on both pools (pure, not an operational entry point).*
