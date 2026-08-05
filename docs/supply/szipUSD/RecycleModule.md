# SZIPUSD ENGINE — RecycleModule
[zipcode-euler/contracts/src/supply/szipUSD]

The free-value ledger: it puts realized yield back to work. Base (chain 8453). Solidity 0.8.24.

* It is the one engine module that holds real bookkeeping state — a single running total of free value the keeper has credited.
* It spends that total two ways. Recycle parks USDC as senior backing and mints backed zipUSD into the basket, lifting NAV per share for everyone. Divert tops up the senior pool to cover a recognized loss, capped by the size of the loss.
* An off-chain keeper triggers it with amounts; the module routes value only to the basket or the warehouse, never to a keeper-supplied address.

==================================================================================
What it does

- RecycleModule.sol → free-value ledger and its two sinks
Tracks the credited free-value total and debits it on every spend, reverting on overspend. Recycle deposits USDC as senior backing and mints backed zipUSD into the basket; divert supplies raw USDC into the senior pool crediting the warehouse and retires the loss markdown by exactly the amount paid in the same transaction, so the live provision is always the remaining budget and the hole can never be over-filled. Beyond the ledger ceiling, every spend is hard-backed: the vault's real USDC must fall by exactly the spent amount, so an over-credited total cannot conjure value. Where the divert USDC comes from is the loss-side funding procedure in [../../solvency.md].
[contracts/src/supply/szipUSD/RecycleModule.sol]
[../../wires/8-B10-RecycleModule.md]

Summaries:
[../../wires/8-B10-RecycleModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — the most stateful fleet module and the best-tested after the freeze: 40 unit + 2 fork tests, including a dedicated suite for the divert bound and its atomic settlement.

[contracts/src/supply/szipUSD/x-ray/RecycleModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Two-layer free-value enforcement: a policy ceiling (debit first, revert on overspend) plus a hard-backing check (the vault's USDC must fall by exactly the spent amount), so even an over-credited ledger cannot invent value.
* The divert bound is the subtle property and is tested thoroughly: each divert retires the provision by exactly what it paid, so total diverted can never exceed the loss, exact fill is allowed, and one wei over reverts. The old per-epoch tally was removed once the settlement became atomic; the hole itself is the budget.
* It uses no reentrancy guard (a clone can't run one) — safety is effects-before-interaction: the ledger and tally update before the value-moving calls. Tested, but a structural argument, not a guard.
* Residual (off-chain): crediting the ledger is unbounded and keeper-trusted (bounded by the hard-backing layer — it can mis-route real free value, never invent it). Build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- Recycle deposits backed zipUSD through the deposit module — [contracts/src/supply/ZipDepositModule.sol] (WOOF-06).
- Divert supplies the senior EulerEarn pool crediting the warehouse — [contracts/src/interfaces/euler/IEulerEarn.sol] (see [../../interfaces/interfaces-euler.md]); the warehouse is [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol] ([../CreditWarehouse/WarehouseAdminModule.md]).
- The loss provision that bounds divert is written by the default coordinator — [contracts/src/loss/DefaultCoordinator.sol] ([../../wires/DefaultCoordinator.md]); divert retires it through settleFromJunior in the same transaction.
- The loss-side funding procedure (harvest free value and the off-ramp haircut route) — [../../solvency.md].
