# SZIPUSD ENGINE — SzipUSD
[zipcode-euler/contracts/src/supply/szipUSD]

The transferable junior-vault share token. Base (chain 8453). Solidity 0.8.24.

* It is a plain 18-decimal ERC-20. The only non-standard rule is that only the Exit Gate can mint or burn it.
* It does not rebase. Value accrues in price (tracked by the NAV oracle), never in balance, so holder balances are ordinary ERC-20 balances.
* It trades freely on the secondary market — this is the token holders actually own and sell.

Outside participants: anyone holding szipUSD can transfer or sell it from their own wallet, and the intended exit is to sell it on CoW. The soulbound, ragequit-bearing governance token is a separate thing held only by the Exit Gate; depositors never touch it.

==================================================================================
What it does

- SzipUSD.sol → the user share token
A standard OpenZeppelin ERC-20 with three additions: mint and burn are restricted to the Exit Gate, the Timelock can re-point which contract is the gate (so the token survives a gate redeploy), and the constructor rejects a zero gate. Everything else (transfer, approve, balances) is unmodified OpenZeppelin.
[contracts/src/supply/szipUSD/SzipUSD.sol]
[../../wires/ExitGate-szipUSD.md]

Summaries:
[../../wires/ExitGate-szipUSD.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — a deliberately vanilla, non-rebasing ERC-20 whose only meaningful surface (gate-only mint/burn) is tested; the standard ERC-20 is unmodified OpenZeppelin and correctly not re-tested.

[contracts/src/supply/szipUSD/x-ray/SzipUSD.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Mint and burn revert for any caller other than the gate.
* Its meaningful property — that supply stays one-for-one with the Baal tokens the gate holds — lives in the Exit Gate and is proven by the gate's fuzzed stateful invariant.
* Re-pointing the gate and the constructor's zero-guard are tested (a non-owner is rejected, a re-point takes effect, the old gate loses mint/burn).
* Residual: build-phase gate re-point awaits the pre-production immutable re-freeze; no external audit.

==================================================================================
References:

- Its sole minter/burner is the Exit Gate — [contracts/src/supply/szipUSD/ExitGate.sol] ([ExitGate.md]).
- Its price (NAV per share) is tracked by the NAV oracle, not by balances — [contracts/src/supply/SzipNavOracle.sol] ([../../wires/8-B4-SzipNavOracle.md]).
- It trades on CoW; the protocol's backstop bid is the buy-and-burn module — [contracts/src/supply/szipUSD/SzipBuyBurnModule.sol] ([SzipBuyBurnModule.md]).
