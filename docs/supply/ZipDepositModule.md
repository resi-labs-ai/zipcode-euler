# SUPPLY — ZipDepositModule
[zipcode-euler/contracts/src/supply]

The supply-side entry: it turns a supplier's USDC into the protocol's two supply positions. Base (chain 8453). Solidity 0.8.24.

* Deposit mints zipUSD one-for-one by value to the supplier and parks the USDC in the senior pool, with the warehouse vault as the share holder.
* Zap is the default experience: it deposits, mints zipUSD to itself, and immediately hands it to the Exit Gate on the caller's behalf, so the supplier lands directly in the transferable junior share.
* It makes no pricing decision of its own — all valuation lives in the Exit Gate and the NAV oracle. Its whole job is to be a clean conduit that keeps no funds.

Outside participants: anyone can call deposit or zap from their own wallet — this is the open front door for supplying USDC. zipUSD itself is a transferable token that circulates freely once minted.

==================================================================================
What it does

- ZipDepositModule.sol → mint-and-deposit router (the zap)
Pulls USDC, mints zipUSD (the amount scaled by the two tokens' decimals, derived not hard-coded), and deposits the USDC into the senior pool crediting the warehouse. The zap path additionally mints transient zipUSD and routes it through the Exit Gate so the caller receives szipUSD atomically. It holds nothing after any call, uses exact-amount approvals, is reentrancy-guarded on both external calls, and rolls back fully on any downstream failure.
[contracts/src/supply/ZipDepositModule.sol]
[../wires/WOOF-06.md]

Summaries:
[../wires/WOOF-06.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a stateless, custody-free conduit whose decisive properties are hygiene, exhaustively proven (29 mock-gate tests including fuzz, plus 3 real-gate fork tests).

[contracts/src/supply/x-ray/ZipDepositModule.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Net-zero custody is asserted after every path, and the cleanliness check is a balance delta, not an absolute zero, so a stray donation cannot brick the zap while an under-pull still reverts.
* The zap trusts the Exit Gate only within a fence: it approves exactly the needed amount, requires non-zero shares, checks the zipUSD delta is zero, and resets the approval; a bad gate (no-share, under-pull, mid-call revert, reentrancy) fails closed with a clean rollback.
* The mint bound is the token's own capacity, which reverts and rolls back rather than overflowing; the scaling factor is derived from the tokens' decimals (a regression that hard-coded it would fail the non-default cases).
* Residual: the gate re-point is deployer-gated and awaits the pre-production immutable re-freeze; no external audit. There is no owner, pause, or upgrade surface.

==================================================================================
References:

- It parks USDC in the senior EulerEarn pool crediting the warehouse — [contracts/src/interfaces/euler/IEulerEarn.sol] (see [../interfaces/interfaces-euler.md]); the warehouse is [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol] ([CreditWarehouse/WarehouseAdminModule.md]).
- The zap hands the minted zipUSD to the Exit Gate — [contracts/src/supply/szipUSD/ExitGate.sol] ([szipUSD/ExitGate.md]).
- It is also the recycle module's deposit path for backed zipUSD — [contracts/src/supply/szipUSD/RecycleModule.sol] ([szipUSD/RecycleModule.md]).
