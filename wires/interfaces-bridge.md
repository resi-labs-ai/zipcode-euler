# interfaces-bridge — local interface shims for the szALPHA bridge (catalog)

> Source of truth = the kept code under `contracts/src/interfaces/bridge/`. This doc reads each `.sol`
> as the final form and records what it shims, its declared surface, who consumes it, and the gotchas.

## Role
`contracts/src/interfaces/bridge/` is the minimal local interface set the szALPHA CCT bridge (964 <-> Base
8453) compiles against: two **external shims** (Chainlink CCT admin registry on Base; Bittensor 964 staking
precompiles) plus one **internal seam** (the Zipcode xALPHA rate face the NAV oracle reads). Per WOOF-00 the
rule is "only the methods we call" — selectors are Basescan/`cast`-verified, never trusted from auto-ABI.

---

## ICctRegistry.sol — EXTERNAL shim (Chainlink CCT admin registry, Base + 964)

**What it shims.** The Chainlink CCT (Cross-Chain Token) self-serve admin registry pair the deploy script
wires the szALPHA token + pool into. Verified against
`reference/chainlink-ccip/.../RegistryModuleOwnerCustom.sol` + `.../ITokenAdminRegistry.sol`. Two faces:
- `IRegistryModuleOwnerCustom` → the `RegistryModuleOwnerCustom` contract (`typeAndVersion` "RegistryModuleOwnerCustom 1.6.0").
- `ITokenAdminRegistry` → the `TokenAdminRegistry` contract ("TokenAdminRegistry 1.5.0").

Addresses (from the deploy script's on-chain-verified CCT address book, `DeploySzAlphaBridge.s.sol`):
- **Base 8453:** TokenAdminRegistry `0x6f6C373d09C07425BaAE72317863d7F6bb731e37`,
  RegistryModuleOwnerCustom `0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f`.
- **Bittensor 964:** TokenAdminRegistry `0xe72d25aDd538E8ef9CeF85622eA8912a6CB98Be6`,
  RegistryModuleOwnerCustom `0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3`.

**Declared surface.**
```
interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(address token) external;
}
interface ITokenAdminRegistry {
    function acceptAdminRole(address localToken) external;
    function setPool(address localToken, address pool) external;
    function getPool(address token) external view returns (address);
}
```

**Consumed by.** `contracts/script/DeploySzAlphaBridge.s.sol` only (the `_wire` step:
`registerAdminViaGetCCIPAdmin` → `acceptAdminRole` → `setPool`; `getPool` is read in the deploy asserts).

**Gotchas.** Self-registration goes via `registerAdminViaGetCCIPAdmin` (NOT `registerAdminViaOwner`): the
canonical `BurnMintERC20` Base mirror is AccessControl-based with no `owner()`, and `SzAlpha.owner()` is the
TimelockController from genesis — so the CCIP admin is a *separate* `ccipAdmin` role returned by
`getCCIPAdmin()` (caller must equal it). See `reports/8x-01-report.md`.

---

## ISubtensorPrecompiles.sol — EXTERNAL shim (Bittensor 964 StakingV2 / AddressMapping precompiles)

**What it shims.** The Subtensor (964) Frontier-EVM precompiles the 964-side `SzAlpha` wrapper stakes
through. Authored locally rather than imported from `reference/subtensor/precompiles/src/solidity/` because
the reference `stakingV2.sol` does not compile under strict solc (trailing comma in `allowance(...)`), and
only four selectors are load-bearing. Two faces:
- `IStakingV2` → the **StakingV2** precompile at `0x...0805`.
- `IAddressMapping` → the **AddressMapping** precompile at `0x...080C`.

**Declared surface.**
```
interface IStakingV2 {
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);
}
interface IAddressMapping {
    function addressMapping(address targetAddress) external view returns (bytes32);
}
```

**Consumed by.** `contracts/src/bridge/SzAlpha.sol` only (the 964 wrapper).

**Gotchas.** These interfaces exist ONLY to source the 4-byte selectors and decode return data — they are
NEVER used as a typed call target. On Subtensor's Frontier EVM a *typed* call to these precompiles "never
reaches the runtime precompile" (see `reference/evm-bittensor/solidity/stakeV2.sol`). So `SzAlpha` invokes
`addStake`/`removeStake` via low-level `call` + `abi.encodeWithSelector` and reads `getStake`/`addressMapping`
via `staticcall`. `getStake` is in alpha; `addStake` amount is rao, `removeStake` amount is alpha;
`addressMapping` converts an EVM H160 to its Substrate AccountId32 (H256) coldkey.

---

## IXAlphaRate.sol — INTERNAL seam (Zipcode xALPHA exchange-rate face)

**What it shims.** Not an external protocol — the internal Zipcode rate face: a single `exchangeRate()`
getter returning alpha-per-xAlpha (18-dp; `1e18` == 1.0 ALPHA per 1.0 xALPHA), read on-chain from stake
accounting (`staked alpha / supply`), so subnet emissions accrue non-manipulably (no pool price). It is the
one face the NAV oracle depends on. Implemented on both sides of the seam:
- on **964** by `SzAlpha.exchangeRate()` (native — computed from precompile stake accounting),
- on **Base 8453** by `SzAlphaRateOracle` (a `ReceiverTemplate` that re-exposes the CRE-pushed 964 rate as a
  drop-in `exchangeRate()`).

**Declared surface.**
```
interface IXAlphaRate {
    function exchangeRate() external view returns (uint256);
}
```

**Consumed by.**
- `contracts/src/bridge/SzAlpha.sol` — `is IXAlphaRate`, implements `exchangeRate()` (the 964 native rate).
- `contracts/src/bridge/SzAlphaRateOracle.sol` — `is ReceiverTemplate, IXAlphaRate`, implements
  `exchangeRate()` (the Base-side re-exposed rate; the 8x-02 deliverable).
- `contracts/src/supply/SzipNavOracle.sol` — the reader: marks the xALPHA NAV leg via
  `IXAlphaRate(rateSrc).exchangeRate() * alphaUSD / 1e18`. `rateSrc` = the Base `SzAlphaRateOracle` when set,
  else falls back to reading `IXAlphaRate(xAlpha)` directly (the M1 stand-in mock).
- `contracts/src/bridge/SzAlphaMirror.sol` — references it only in NatSpec to state it has **zero**
  `IXAlphaRate` surface (the mirror is a pure transport token; rate lives on 964).

**Gotchas.**
- **Cross-chain rate seam:** the rate is native ONLY on 964. The mirror token on Base carries no rate; Base
  reads come from `SzAlphaRateOracle` (CRE-pushed) — this is the §7 asymmetry. `SzipNavOracle` gates issuance
  on the oracle's freshness via a separate `IXAlphaRateFresh.fresh()` probe (declared inline in
  `SzipNavOracle.sol`, not in this folder); zero-address `xAlphaRateOracle` ⇒ M1 stand-in path with no
  freshness gate.
- **`exchangeRate()` is the drop-in NAV read** on both sides — no pushed APR is needed (resolves 8x-02; see
  `SzAlphaRateOracle.sol`). The interface pins only this one face.
- **M1 vs production:** M1 xALPHA is an 18-dp mock ERC20 exposing this getter; the production swap-in is the
  bridged Rubicon LST wrapper (`LiquidStakedV3`), whose rate-getter selector + supply-immutability are
  VERIFIED AT THE 8x/BRIDGE INTEGRATION (flag, do not block). See `bridge/xalpha-bridge-impl.md §2`.
