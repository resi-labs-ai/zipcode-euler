# INTERFACES — ICHI
[zipcode-euler/contracts/src/interfaces/ichi]

Small interfaces for ICHI, the automated liquidity manager that holds the junior's LP. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Ichi is necessary for two reasons: 

1) Ichi provides single sided deposit LP tokens denominated in zipUSD. -- This actually tends toward a 70% zipUSD / 30% xALPHA LP position, but that strategy is managed by Ichi. 

2) The Ichi LP has a receipt token, which is listed as collateral on an Euler Vault which is only accessible by the Zodiac Module responsible for exercising oHYDX rewards. 

This allows zipUSD holders to earn boosted yield through Hydrex, while remaining within the Junior Tranche.

Note: ICHI is an outside protocol on Base — we don't compile its code, we hand-write interfaces with only the functions we call.

- IICHIVault.sol → an ICHI liquidity-manager vault (the zipUSD/xALPHA pool; created on demand, no fixed address)
The automated LP vault the junior's liquidity sits in. The LP strategy deposits the two tokens into it to build the LP; the NAV oracle reads its reserves and the held share balance to value that LP. ICHI runs the underlying Algebra position for us.
[contracts/src/supply/szipUSD/LpStrategyModule.sol]
[contracts/src/supply/SzipNavOracle.sol]
[contracts/src/supply/AlgebraIchiFairLpOracle.sol]
[contracts/src/supply/lib/IchiAlgebraFairReserves.sol]
[wires/8-B6-LpStrategyModule.md]

- IICHIVaultFactory.sol → the ICHI vault factory `0x2b52c416F723F16e883E53f3f16435B51300280a`
Creates and looks up ICHI vaults. No contract uses it — the production vault is created out of band and its address passed in. Kept for the create/lookup path and fork-test setup.
[wires/interfaces-ichi.md]

- IICHIDepositGuard.sol → the ICHI deposit guard `0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8`
A convenience forwarder for deposits and withdrawals. Not used — the engine deposits into the vault directly. Kept as a documented alternative.
[wires/interfaces-ichi.md]

Summaries:
[../wires/interfaces-ichi.md]

==================================================================================
References:

- ICHI — the automated liquidity manager on Base; forked for tests, never compiled.
- One address, used everywhere: the POL vault is created once, and that same address must be wired into the strategy, the NAV oracle, and the gauge. A mismatch silently mis-prices NAV and strands the LP.
