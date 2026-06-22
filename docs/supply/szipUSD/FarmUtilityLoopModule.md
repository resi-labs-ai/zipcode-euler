# SZIPUSD ENGINE — FarmUtilityLoopModule
[zipcode-euler/contracts/src/supply/szipUSD]

The leverage loop that finances the option strikes. Base (chain 8453). Solidity 0.8.24.

* It borrows the warehouse's resting USDC from an isolated Euler lending vault, collateralized by the vault's own LP, to pay the option strikes — then repays and releases the LP to re-stake.
* This is the only module that borrows shared depositor cash, so three independent limits bound it: an owner-set aggregate borrow cap with a kill-switch, the lending market's own health check, and a borrow guard that pins borrowing to the vault.
* An off-chain keeper triggers the four loop steps with amounts; the module drives the vault's own lending account and holds no funds.

==================================================================================
What it does

- FarmUtilityLoopModule.sol → post, borrow, repay, withdraw
Four keeper-only steps: post the LP as collateral, borrow strike USDC (checked against the aggregate cap and the market's health), repay the borrow, and withdraw the collateral once debt is clear. Every borrow, repay, and withdraw is for the vault's own account; there is no recipient parameter and no standing approval, and a withdraw with outstanding debt is blocked.
[contracts/src/supply/szipUSD/FarmUtilityLoopModule.sol]
[../../wires/8-B5-FarmUtilityLoop.md]

Summaries:
[../../wires/8-B5-FarmUtilityLoop.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — the highest-consequence fleet module (it borrows shared depositor USDC), with its borrow controls proven on the real Euler market: ~16 of a 43-test shared suite, mostly fork.

[contracts/src/supply/szipUSD/x-ray/FarmUtilityLoopModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Three independent borrow bounds, all tested on the live market: the aggregate cap plus kill-switch (a zero cap blocks every borrow), the lending market's over-collateralization health check (over-LTV or no-collateral borrows revert), and the borrow guard pinning borrowing to the vault (a third party can't lever the same collateral on its own account).
* A stale or never-pushed collateral price reverts the borrow (fail-closed); repay is exact and resets the approval; the full four-step loop round-trips cleanly with no duplicate enables.
* Residual (off-chain): the keeper sizes the amounts (bounded by cap, health, and guard); build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It borrows from and repays an isolated Euler lending vault — [contracts/src/interfaces/euler/IEulerEarn.sol] (the resting USDC pool; see [../../interfaces/interfaces-euler.md]).
- The borrow is pinned to the vault by the borrow guard — [contracts/src/supply/szipUSD/FarmUtilityBorrowGuard.sol] ([FarmUtilityBorrowGuard.md]).
- The resting USDC it borrows is funded just-in-time by the venue adapter — [contracts/src/venue/EulerVenueAdapter.sol] ([../../venue.md]).
