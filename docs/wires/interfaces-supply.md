# interfaces-supply — `ISzipNavBasket` + `ISeniorPool` (wiring catalog)

> **X-Ray (trust surface):** internal seams (intra-protocol coupling); `ISeniorPool` carries a documented
> donation-immunity contract. Trust map: `contracts/src/interfaces/x-ray/dependency-surface.md`; overview:
> `docs/interfaces/dependency-surface.md`.

> Source of truth = `contracts/src/interfaces/supply/{ISzipNavBasket,ISeniorPool}.sol`. This is a catalog of the shims, not their intent.

## Role
`ISzipNavBasket` is an **INTERNAL Zipcode seam** (not an external-protocol face): the local interface DurationFreezeModule reads the additive basket-valuation views of the kept `SzipNavOracle` through, so the GPL oracle is never imported (the local-interface house posture).

## What it shims
The basket-valuation face of `SzipNavOracle` (`contracts/src/supply/SzipNavOracle.sol`) — the **implementer**. The oracle is the sole valuation authority for the freeze floor; the module consumes:
- `grossBasketValue()` — whole-basket value (main + juniorTrancheSidecar Safes), backed by the oracle's per-Safe `_grossValueOf(safe)` summation.
- `committedValue()` — juniorTrancheSidecar-only (frozen) value.
- `freeValue()` — main-only value.
- the five movable plain-leg addresses (`zipUSD`/`usdc`/`xAlpha`/`hydx`/`oHydx`) — read LIVE at `setUp` to form the whitelist == exactly what the oracle prices.

`_grossValueOf(address)` is the oracle's `internal` per-Safe summand behind `grossBasketValue()` — it is NOT on this interface (internal-only), named here only as the additive source.

## Declared surface (exact signatures)
```solidity
function grossBasketValue()  external view returns (uint256);          // 18-dp USD, main + juniorTrancheSidecar
function committedValue()    external view returns (uint256);          // 18-dp USD, juniorTrancheSidecar-only (committed)
function freeValue()         external view returns (uint256);          // 18-dp USD, main-only (free)
function pathLockedLpEquity() external view returns (uint256);         // 18-dp USD, ICHI LP across both Safes net of strike debt
function lpShareValue(uint256 lpShares) external view returns (uint256); // 18-dp USD value of lpShares LP
function zipUSD()    external view returns (address);
function usdc()      external view returns (address);
function xAlpha()    external view returns (address);
function hydx()      external view returns (address);
function oHydx()     external view returns (address);
function ichiVault() external view returns (address);                  // the 6th movable asset (zipUSD/xALPHA ICHI LP token)
```

## Consumed by
`grep -rl "ISzipNavBasket" contracts/src`:
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol` — pins `ISzipNavBasket navOracle`; `committedValue()`/`grossBasketValue()` proxy through, `freeValue() = grossBasketValue() - committedValue()`, and the five leg getters seed the live whitelist at `setUp`.
- (self) `contracts/src/interfaces/supply/ISzipNavBasket.sol`.

## Gotchas
- **Additive views.** `committedValue`/`freeValue` were added beside the existing `grossBasketValue` — the 42-test `grossBasketValue` behavior pins UNCHANGED (the seam is purely additive over the kept oracle).
- **Freeze floor.** The module enforces `committedValue() >= requiredFraction(U) × grossBasketValue() / 1e18`, with `requiredFraction == utilization` (`U` read live + donation-immune from EulerEarn). A MAIN→SIDECAR rotation leaves `grossBasketValue` invariant; an over-`release` reverts regardless of operator intent.
- **`_grossValueOf` is not callable here** — internal to the oracle; only `grossBasketValue()`/`committedValue()`/`freeValue()` cross the interface.
- 18-dp USD on all three value getters; addresses are the movable (re-pointable) plain legs, not immutable.

---

# ISeniorPool — venue-neutral senior-surface read (CTR-10a)

> Source of truth = `contracts/src/interfaces/supply/ISeniorPool.sol`. The generalization of the removed
> `IEulerEarnUtil` — same three selectors, named for the federation seam (§4.7) so ANY venue type's senior
> surface (not only EulerEarn) can be read donation-immune.

## Role
The minimal three-view senior-surface read every silo's senior pool must expose so the §8.2 donation-immune
senior par-backing read works venue-neutrally. EulerEarn satisfies it directly (4626 `convertToAssets`/`maxWithdraw`
+ ERC20 `balanceOf`); a non-4626 venue is admitted behind a thin wrapper satisfying the same contract (CTR-10b, deferred).

## Declared surface (exact signatures)
```solidity
function maxWithdraw(address owner) external view returns (uint256);      // free liquidity for owner's shares RIGHT NOW
function convertToAssets(uint256 shares) external view returns (uint256); // backing assets shares represent (donation-immune: real pool accounting)
function balanceOf(address account) external view returns (uint256);      // senior share balance of account (the warehouse Safe)
```

## Consumed by
`grep -rl "ISeniorPool" contracts/src`:
- `contracts/src/SeniorNavAggregator.sol` — `_seniorValue`/`_illiquidValue` read `ISeniorPool(eePool)` per silo.
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol` — `utilization()`/`illiquidSeniorValue()` read `ISeniorPool(eulerEarn)` (storage slot name `eulerEarn` retained — Euler is config one; the read interface is generic).
- (self) `contracts/src/interfaces/supply/ISeniorPool.sol`.

## Gotchas
- **Donation-immunity is a property of the IMPLEMENTATION, not the interface.** Every implementation's `convertToAssets`/`maxWithdraw` must be backed by real pool accounting (for EulerEarn, `Σ expectedSupplyAssets`), so a stray-asset donation to the pool address moves neither term. A skewable implementation breaks §11-B and MUST NOT be admitted. Consumers NEVER read `balanceOf(pool)` — always `balanceOf(warehouse)`.
- **CTR-10a is a no-op re-type for the Euler silo.** `ISeniorPool` is the exact selector-subset of the removed `IEulerEarnUtil`; the cast change emits identical calldata, so the full 919-test suite passes unchanged. The `DurationFreezeModule.eulerEarn` storage slot was NOT renamed (renaming ripples into `SiloRegistry`'s `IFreeze(freeze).eulerEarn()` topology assert — that is CTR-10b scope).
