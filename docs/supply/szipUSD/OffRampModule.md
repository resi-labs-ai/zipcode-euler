# SZIPUSD ENGINE — OffRampModule
[zipcode-euler/contracts/src/supply/szipUSD]

The zipUSD-to-USDC off-ramp driver. Base (chain 8453). Solidity 0.8.24.

* It turns the basket's idle zipUSD into USDC at par by driving the senior redemption queue.
* It adds no redemption logic of its own — par, the redemption epoch, and pro-rata partial fills are all the queue's job. This module just requests and claims.
* An off-chain keeper triggers it with amounts; every queue argument is pinned to the vault, so redeemed USDC can only land back in the vault.

==================================================================================
What it does

- OffRampModule.sol → request and claim against the redemption queue
Two keeper-only actions: request a redemption (approve the queue, request, reset the approval) and later claim the settled USDC. The requester, owner, and receiver are all the vault, never keeper-supplied, so the queue both authorizes the request and pays the USDC to the vault. The request amount must be a whole multiple of the queue's live unit size, read fresh rather than hard-coded.
[contracts/src/supply/szipUSD/OffRampModule.sol]
[../../wires/OffRampModule.md]

Summaries:
[../../wires/OffRampModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — the cleanest, best-integration-tested fleet driver: 18 unit + 1 fork test, the fork being a full real-queue cycle. Its wiring setters were already tested (no gap).

[contracts/src/supply/szipUSD/x-ray/OffRampModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Destination integrity is the whole safety story: every queue argument is pinned to the vault, proven on a live cycle that decodes the real queue's request and confirms it is the vault's.
* Par neutrality is proven end-to-end: redeeming at par and claiming the USDC back leaves basket value unchanged.
* The whole-unit guard reads the queue's live unit size, so a queue re-scale can't silently desync it; a swallowed queue revert hard-reverts rather than leaving a dangling approval.
* Residual (off-chain): the keeper sizes the amounts each period, bounded by the destination pin and the queue's own par/epoch math; build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It drives the senior redemption queue — [contracts/src/supply/ZipRedemptionQueue.sol] ([../../wires/9-ZipRedemptionQueue.md]).
- The queue is funded by the warehouse repaying redemption proceeds — [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol] ([../CreditWarehouse/WarehouseAdminModule.md]).
