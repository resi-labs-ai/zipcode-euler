# SUPPLY — SzipNavOracle
[zipcode-euler/contracts/src/supply]

The junior vault's price engine: NAV per share, used to both mint and exit. Base (chain 8453). Solidity 0.8.24.

* It values the whole junior basket on-chain — every token leg, including the staked LP — and divides by the share supply to get NAV per share. This is a live price the protocol acts on, not a display number.
* Most prices it reads trustlessly on-chain. The two it cannot read on Base (the xALPHA-to-USD and HYDX-to-USD marks) are pushed by an off-chain Chainlink keeper.
* It also keeps a time-averaged price over a set window, and serves a bracketed price: issuance uses the higher of the current and average price, exit uses the lower. So a momentary price spike can never be used to mint cheap or exit rich.

==================================================================================
What it does

- SzipNavOracle.sol → basket NAV-per-share oracle
Composes the basket value across the main and sidecar vaults, maintains the time-averaged price (a permissionless poke advances it), and exposes the share price plus freshness. It is the issuance price for the Exit Gate, the coverage floor for the freeze module, the freshness anchor and exit price for the buy-and-burn bid, and the sink for the loss provision. A stale leg pauses issuance but never blocks exit; an unseeded xALPHA rate fails every read closed.
[contracts/src/supply/SzipNavOracle.sol]
[../wires/8-B4-SzipNavOracle.md]

Summaries:
[../wires/8-B4-SzipNavOracle.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (a hair from HARDENED) — the economic keystone of the junior vault and the best-tested contract in the supply subsystem (64 tests).

[contracts/src/supply/x-ray/SzipNavOracle.md]

The load-bearing properties an auditor should check (full catalog + test connection in the X-Ray):

* The bracket asymmetry is the whole defense: issuance prices off the higher of current/average, exit off the lower, so a one-block spike can't cheapen a mint or enrich an exit. The time-average is poke-spam-immune (a fixed minimum spacing caps how fast its history can be consumed).
* The basket composition is exact and hand-checked across all seven legs, with the LP marked through in every state (loose, gauge-staked, borrow-collateralized) net of strike debt.
* The off-chain price push is all-or-nothing and guarded (deviation band, future-timestamp, strictly-newer, zero-price); a stale leg pauses issuance only; an unseeded xALPHA rate fails closed.
* The committed-plus-free decomposition equals the gross basket value exactly (to within 2 wei on a split LP) — the double-count-free split the freeze floor relies on.
* Residuals (off-chain): no stateful fuzz invariant yet; the time-average's depth is a pool-config property (inherited from the fair-reserves library); the off-chain push is trusted; build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- The Exit Gate prices deposits off it — [contracts/src/supply/szipUSD/ExitGate.sol] ([szipUSD/ExitGate.md]).
- The freeze module reads its coverage floor from it — [contracts/src/supply/szipUSD/DurationFreezeModule.sol] ([szipUSD/DurationFreezeModule.md]).
- The buy-and-burn bid prices off it — [contracts/src/supply/szipUSD/SzipBuyBurnModule.sol] ([szipUSD/SzipBuyBurnModule.md]).
- The default coordinator is its sole provision writer — [contracts/src/loss/DefaultCoordinator.sol] ([../wires/DefaultCoordinator.md]).
- Its cross-chain xALPHA rate comes from the bridge's Base rate oracle — [contracts/src/bridge/SzAlphaRateOracle.sol] ([../bridge.md]).
- Its LP leg is reconstructed manipulation-resistantly by the fair-reserves library — [contracts/src/supply/lib/IchiAlgebraFairReserves.sol] ([lib/IchiAlgebraFairReserves.md]).
