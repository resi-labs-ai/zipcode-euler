# interfaces-ichi — local ICHI shims (wiring map)

> Source of truth = the kept code under `contracts/src/interfaces/ichi/`. This doc reads each shim as
> the final form and records what external Base contract it stands in for, its declared surface, who
> consumes it, and the gotchas. Addresses are pinned in `contracts/script/BaseAddresses.sol`.

## Role
`contracts/src/interfaces/ichi/` is the minimal local interface set (only the methods we call) for the
**interface+fork** ICHI Automated-Liquidity-Manager protocol on Base — never compiled from ICHI source;
we author these shims and fork the live Base-mainnet deployments. Three files: the vault, its factory,
and the (unused-in-prod) deposit guard.

## External pins (BaseAddresses.sol, Base 8453)
- `ICHI_VAULT_FACTORY 0x2b52c416F723F16e883E53f3f16435B51300280a` — the real factory (**corrected**: the
  old `0x7d11…` is `ICHI_ADMIN_SAFE`, a Gnosis Safe v1.3.0, not the factory).
- `ICHI_DEPOSIT_GUARD 0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8` — the deposit/withdraw forwarder.
- The production POL (zipUSD/xALPHA single-sided) ICHI vault is **dynamically created** on demand
  (gated on the Hydrex whitelist / OTC) — no fixed address constant; it lives in storage on the
  consumers as `ichiVault`.

---

## IICHIVault.sol

**What it shims.** A single live ICHI vault (ERC4626-style ALM share token). Verified 2026-06-06 against
a live HYDX ICHI vault `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad` (`allVaults(0)` of the factory,
`ammName()=="HYDX"`); in production this is the dynamically-created zipUSD/xALPHA POL vault. External shim.

**Declared surface.**
- ERC4626-style core:
  - `deposit(uint256 deposit0, uint256 deposit1, address to) returns (uint256 shares)` — selector
    `0x8dbdbe6d`, confirmed present in bytecode. Lands shares directly to `to`.
  - `withdraw(uint256 shares, address to) returns (uint256 amount0, uint256 amount1)`.
  - `token0() view returns (address)`, `token1() view returns (address)`.
  - `totalSupply() view returns (uint256)`, `balanceOf(address) view returns (uint256)`.
- ICHI-specific:
  - `getTotalAmounts() view returns (uint256 total0, uint256 total1)` — the vault's full token reserves
    (used for NAV pro-rata valuation of held LP shares).
  - `allowToken0() view returns (bool)`, `allowToken1() view returns (bool)` — **single-sidedness is a
    property of the vault itself**: the vault's `allowToken*` flags gate which leg(s) a deposit may
    fund. The shim does not encode single-sidedness; it reads the vault's flags.

**Consumed by.**
- `contracts/src/supply/szipUSD/LpStrategyModule.sol` — reads `token0()`/`token1()`, executes
  `IICHIVault.deposit(deposit0, deposit1, engineSafe)` (`addLiquidity`), reads `balanceOf(engineSafe)`.
- `contracts/src/supply/SzipNavOracle.sol` — values held LP: `balanceOf(mainSafe)+balanceOf(sidecar)`
  (and gauge balance) over `totalSupply()`, pro-rated against `getTotalAmounts()` priced per
  `token0()`/`token1()`.

**Gotchas.**
- **DepositGuard NOT needed** — calling `IICHIVault.deposit(...)` directly lands the shares; the guard is
  a convenience forwarder, not a required hop.
- The vault's `allowToken0/allowToken1` gates leg legality **fail-closed**; `LpStrategyModule` deposits
  single-sided or balanced and lets the vault reject illegal legs.

---

## IICHIVaultFactory.sol

**What it shims.** The ICHI vault factory/registry, `ICHI_VAULT_FACTORY
0x2b52c416F723F16e883E53f3f16435B51300280a` (read directly off the verified DepositGuard's
`ICHIVaultFactory()` getter). External shim.

**Declared surface.**
- `getICHIVault(bytes32 key) view returns (address ichiVault)` — selector `0x50309615`. Lookup is by a
  **bytes32 key** (`genKey(deployer,token0,token1,allowToken0,allowToken1)`), NOT a raw token pair;
  returns `address(0)` if none.
- `createICHIVault(address tokenA, bool allowTokenA, address tokenB, bool allowTokenB) returns (address
  ichiVault)` — selector `0x5f715016`.
- `allVaults(uint256 index) view returns (address ichiVault)`.

Method **names matter**: it is `createICHIVault`/`getICHIVault`, NOT `createVault`/`getVault`. The
previously-guessed `getVault(address,address,bool,bool)` and `createVault(...,uint24)` selectors are
ABSENT from the deployed bytecode and were replaced with the verified ones.

**Consumed by.** No `src/` consumer imports this shim today (the production vault is created/registered
out of band and passed in as the stored `ichiVault` address). It exists for the create/lookup path and
fork-test setup.

**Gotchas.**
- `ICHI_ADMIN_SAFE 0x7d11…` is NOT this factory — it is the ICHI admin multisig (Gnosis Safe v1.3.0,
  7 owners, `VERSION()=="1.3.0"`). Pin the factory at `0x2b52…280a`.
- Lookup key is the `genKey` bytes32 hash, not the token pair — callers must reconstruct the key.

---

## IICHIDepositGuard.sol

**What it shims.** The ICHI Deposit Guard (deposit/withdraw forwarder), `ICHI_DEPOSIT_GUARD
0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8`. External shim. Its hardcoded factory `ICHIVaultFactory()`
reads on-chain to `0x2b52…280a` (= `ICHI_VAULT_FACTORY`), confirming the corrected factory address.

**Declared surface.**
- `forwardDepositToICHIVault(address vault, address vaultDeployer, address token, uint256 amount,
  uint256 minimumProceeds, address to) returns (uint256 vaultTokens)` — selector `0x5d123e3f`, present
  in deployed bytecode and matching Basescan-verified source.
- `forwardWithdrawFromICHIVault(address vault, address vaultDeployer, uint256 shares, address to,
  uint256 minAmount0, uint256 minAmount1) returns (uint256 amount0, uint256 amount1)` — arg order +
  return type CORRECTED to the verified source (was guessed wrong originally).

**Consumed by.** No `src/` consumer. The shim is kept for completeness/optional routing; the engine does
not use the guard.

**Gotchas.**
- **DepositGuard NOT needed in production** — the direct `IICHIVault.deposit` path lands shares without
  it. This shim is the documented alternative, not the wired one.

---

## Cross-file invariant — shared LP address
The POL ICHI vault address is **dynamically created once** and must be the **same address everywhere it
appears**: the strategy that adds liquidity (8-B5 ReservoirLoop / 8-B6 LpStrategyModule), the NAV oracle
(`SzipNavOracle`), and the gauge wiring. A mismatch silently mis-prices NAV and strands LP. The address
is not a `BaseAddresses` constant — it is stored on each consumer and must be wired consistently at
deploy/setup time.
