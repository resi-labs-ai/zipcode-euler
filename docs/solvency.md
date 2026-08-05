# SOLVENCY
[zipcode-euler/contracts/src/supply/szipUSD + contracts/src/loss]

How a recognized loss gets paid for real. Base (chain 8453). Solidity 0.8.24.

* A default marks NAV down with a provision. That is recognition, not payment.
* `divert` is the payment lever. It moves junior USDC into the senior pool and retires the same amount of provision in one transaction.
* The USDC it spends must first be credited to a policy ledger by the CRE operator. That credit is a deliberate act, not plumbing.

This doc is the living home for the loss-side funding stream. `RecycleModule.sol` cites it as `solvency.md §C.S1` from before the ticket files were retired; the divert section below is what that citation now resolves to.

==================================================================================
The loss lifecycle in one pass

1. The CRE marks a default. `DefaultCoordinator` writes the impairment provision into `SzipNavOracle`, and spot NAV falls immediately. See [loss.md].
2. The operator pays the loss with `RecycleModule.divert(lienId, usdcAmount)`. It debits the free-value ledger, calls `DefaultCoordinator.settleFromJunior` to retire the provision by exactly the amount paid, and then deposits the USDC into the senior EulerEarn pool crediting `warehouseSafe`, all in one transaction. Anything less than an exact apply reverts, and a failed deposit rolls the settlement back with it.
3. The bound is the live hole itself. Each divert shrinks `provision()`, so the remaining budget is always the live read, and an over-fill reverts `ExceedsHole`.

[contracts/src/supply/szipUSD/RecycleModule.sol]
[contracts/src/loss/DefaultCoordinator.sol]
[wires/8-B10-RecycleModule.md]

==================================================================================
Where the divert USDC comes from

Both sources land in the same Safe. `juniorTrancheEngine` and `juniorTrancheSafe` are one address with two role names (see [safe-identities.md]), so USDC claimed by the off-ramp is spendable by the engine modules.

Source 1 — harvest proceeds. The 8-B8 exercise loop produces HYDX, `SellModule.sellHydx` sells it for USDC into the engine Safe, and the strike borrow is repaid. The CRE then credits `max(0, realized − borrowRepaid)` to the ledger via `creditFreeValue`. This is the normal, steady-state source.
[contracts/src/supply/szipUSD/SellModule.sol]

Source 2 — the off-ramp haircut. The junior burns its own zipUSD to free that zipUSD's backing USDC, then points the USDC at the hole. Hop by hop:

1. `OffRampModule.requestRedeem(zipAmount)` escrows basket zipUSD into `ZipRedemptionQueue` with `requester == owner == juniorTrancheSafe`.
2. The CRE drives the warehouse REDEEM then REPAY through `WarehouseAdminModule`; REPAY is a USDC transfer whose destination is scope-pinned to the queue. This is un-lent senior pool cash.
3. `ZipRedemptionQueue.settleEpoch()` fills pending at par, burns the escrowed zipUSD, and banks the USDC as claimable.
4. `OffRampModule.claim(assets)` lands the USDC in `juniorTrancheSafe`.
5. The CRE credits that USDC to the ledger via `creditFreeValue`, then runs `divert`.

Net effect of the full loop: junior zipUSD is burned, the senior pool's cash round-trips, and the provision is retired. The junior paid the loss with its own equity, which is the first-loss job. This is the protocol's self-haircut.

[contracts/src/supply/szipUSD/OffRampModule.sol]
[contracts/src/supply/ZipRedemptionQueue.sol]
[wires/OffRampModule.md]

==================================================================================
What is plumbing and what is policy

* Plumbing (enforced on-chain): the hole bound, the exact atomic settle, the hard-backing check that the Safe's USDC fell by exactly the spent amount, the liveness check that warehouse shares rose, destination integrity on every leg (no operator-supplied addresses).
* Policy (CRE-trusted, off-chain): `creditFreeValue` is unbounded and operator-gated. Nothing on-chain classifies Safe USDC as spendable free value or distinguishes harvest USDC from off-ramped USDC. Crediting off-ramped USDC for a divert is a policy decision the operator makes explicitly.
* Every step in both chains is gated on the single CRE operator (or the queue's controller), so the whole procedure is a CRE runbook, not an autonomous mechanism. No CRE keeper job drives `divert` or `creditFreeValue` today.
* Neither the off-ramp nor `divert` consults the `DurationFreezeModule` coverage floor. Both convert or spend counted value; the coverage gate sits on the buy-burn and LP-removal paths instead.

==================================================================================
References:

- The provision writer and its bounds — [contracts/src/loss/DefaultCoordinator.sol] ([wires/DefaultCoordinator.md], [loss.md]).
- The free-value ledger and both spend sinks — [contracts/src/supply/szipUSD/RecycleModule.sol] ([wires/8-B10-RecycleModule.md], [supply/szipUSD/RecycleModule.md]).
- The zipUSD→USDC off-ramp driver — [contracts/src/supply/szipUSD/OffRampModule.sol] ([wires/OffRampModule.md]).
- The par-burn queue — [contracts/src/supply/ZipRedemptionQueue.sol].
- Safe identities — [safe-identities.md].
