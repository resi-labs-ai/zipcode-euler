# INTERFACES — EULER
[zipcode-euler/contracts/src/interfaces/euler]

Small interfaces for the EulerEarn senior pool and our own zipUSD token. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Euler enables onchain settlement for the credit warehouse.

Note: we don't import EulerEarn's real code — it pins a different Solidity version (0.8.26) than our build, so we hand-write small interfaces with only the functions we call. (Other contracts declare their own `IEulerEarn` inline; those are not the same file as this folder's.)

- IEulerEarn.sol → the EulerEarn senior pool (a USDC vault on Base)
The senior lending pool that backs zipUSD. The Credit Warehouse deposits USDC into it and redeems USDC back out, and the NAV mark reads the pool's share value. Forked on Base for tests; never compiled.
[contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol]
[contracts/script/CreditWarehouseDeployer.sol]
[wires/8-Bw-CreditWarehouse.md]

- IEulerEarnUtil.sol → the same pool, read-only
A small read-only view of the same EulerEarn pool. The DurationFreezeModule uses it to measure how much of the warehouse is currently lent out. It is measured so an outsider can't skew it by donating stray USDC to the pool.
[contracts/src/supply/szipUSD/DurationFreezeModule.sol]
[wires/DurationFreezeModule.md]

- IZipUSD.sol → zipUSD's burn function (our own token)
zipUSD is our dollar token (an Euler ESynth). This interface exposes only its `burn` function. The redemption queue uses it to burn the zipUSD it has escrowed once a senior redemption settles at par.
[contracts/src/supply/ZipRedemptionQueue.sol]
[wires/9-ZipRedemptionQueue.md]

Summaries:
[../wires/interfaces-euler.md]

==================================================================================
References:

These declare only the calls we make; signatures are verified against the vendored source.

- EulerEarn — [reference/euler-earn] (the senior pool the two external shims target; forked on Base, never compiled).
- zipUSD ESynth — [reference/euler-vault-kit] (the `ESynth` our dollar token is built on; the `burn` seam).
