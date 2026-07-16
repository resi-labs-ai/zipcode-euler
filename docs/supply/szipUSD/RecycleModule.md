# SZIPUSD ENGINE — RecycleModule
[zipcode-euler/contracts/src/supply/szipUSD]

The free-value ledger: it puts realized yield back to work. Base (chain 8453). Solidity 0.8.24.

* It is the one engine module that holds real bookkeeping state — a single running total of free value the keeper has credited.
* It spends that total two ways. Recycle parks USDC as senior backing and mints backed zipUSD into the basket, lifting NAV per share for everyone. Divert tops up the senior pool to cover a recognized loss, capped by the size of the loss.
* An off-chain keeper triggers it with amounts; the module routes value only to the basket or the warehouse, never to a keeper-supplied address.

==================================================================================
What it does

- RecycleModule.sol → free-value ledger and its two sinks
Tracks the credited free-value total and debits it on every spend, reverting on overspend. Recycle deposits USDC as senior backing and mints backed zipUSD into the basket; divert supplies raw USDC into the senior pool crediting the warehouse, bounded cumulatively by the live loss provision (it cannot over-fill the hole within a provision epoch, and a re-marked-then-restored provision does not resurrect spent budget). Beyond the ledger ceiling, every spend is hard-backed: the vault's real USDC must fall by exactly the spent amount, so an over-credited total cannot conjure value.
[contracts/src/supply/szipUSD/RecycleModule.sol]
[../../wires/8-B10-RecycleModule.md]

Summaries:
[../../wires/8-B10-RecycleModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — the most stateful fleet module and the best-tested after the freeze: 40 unit + 2 fork tests, including a dedicated five-test suite for the cumulative divert bound.

[contracts/src/supply/szipUSD/x-ray/RecycleModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Two-layer free-value enforcement: a policy ceiling (debit first, revert on overspend) plus a hard-backing check (the vault's USDC must fall by exactly the spent amount), so even an over-credited ledger cannot invent value.
* The cumulative divert bound is the subtle property and is tested thoroughly: per-epoch total diverted can never exceed the live loss provision, exact fill is allowed, and a stale-value re-mark does not resurrect the tally.
* It uses no reentrancy guard (a clone can't run one) — safety is effects-before-interaction: the ledger and tally update before the value-moving calls. Tested, but a structural argument, not a guard.
* Residual (off-chain): crediting the ledger is unbounded and keeper-trusted (bounded by the hard-backing layer — it can mis-route real free value, never invent it). Build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- Recycle deposits backed zipUSD through the deposit module — [contracts/src/supply/ZipDepositModule.sol] (WOOF-06).
- Divert supplies the senior EulerEarn pool crediting the warehouse — [contracts/src/interfaces/euler/IEulerEarn.sol] (see [../../interfaces/interfaces-euler.md]); the warehouse is [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol] ([../CreditWarehouse/WarehouseAdminModule.md]).
- The loss provision that bounds divert is written by the default coordinator — [contracts/src/loss/DefaultCoordinator.sol] ([../../wires/DefaultCoordinator.md]).
