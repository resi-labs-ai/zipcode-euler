# interfaces-supply — `ISzipNavBasket` (wiring catalog)

> Source of truth = `contracts/src/interfaces/supply/ISzipNavBasket.sol`. This is a catalog of the shim, not its intent.

## Role
`ISzipNavBasket` is an **INTERNAL Zipcode seam** (not an external-protocol face): the local interface DurationFreezeModule reads the additive basket-valuation views of the kept `SzipNavOracle` through, so the GPL oracle is never imported (the local-interface house posture).

## What it shims
The basket-valuation face of `SzipNavOracle` (`contracts/src/supply/SzipNavOracle.sol`) — the **implementer**. The oracle is the sole valuation authority for the freeze floor; the module consumes:
- `grossBasketValue()` — whole-basket value (main + sidecar Safes), backed by the oracle's per-Safe `_grossValueOf(safe)` summation.
- `committedValue()` — sidecar-only (frozen) value.
- `freeValue()` — main-only value.
- the five movable plain-leg addresses (`zipUSD`/`usdc`/`xAlpha`/`hydx`/`oHydx`) — read LIVE at `setUp` to form the whitelist == exactly what the oracle prices.

`_grossValueOf(address)` is the oracle's `internal` per-Safe summand behind `grossBasketValue()` — it is NOT on this interface (internal-only), named here only as the additive source.

## Declared surface (exact signatures)
```solidity
function grossBasketValue()  external view returns (uint256);          // 18-dp USD, main + sidecar
function committedValue()    external view returns (uint256);          // 18-dp USD, sidecar-only (committed)
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
