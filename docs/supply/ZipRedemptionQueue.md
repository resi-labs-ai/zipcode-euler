# SUPPLY — ZipRedemptionQueue
[zipcode-euler/contracts/src/supply]

The senior exit: it redeems zipUSD for USDC at par, burning the zipUSD as it fills. Base (chain 8453). Solidity 0.8.24.

* This is the senior dollar's exit, the inverse of a deposit. It pays a strict one dollar per zipUSD and burns the zipUSD as USDC is delivered.
* It is treasury-internal plumbing, not an open creditor queue: exactly one requester (the redemption vault) is ever open, and it pays par regardless of impairment — the junior side absorbs losses, not this.
* It is the non-sweepable destination the warehouse repays into. There is no pause, no upgrade, and no sweep: the only USDC-out path is a claimant's own withdrawal.

Note on the market: this is NOT where someone "sells" zipUSD on the open market. It is the protocol's internal par-redemption sink, driven only by the redemption vault. zipUSD trades freely elsewhere as a normal token.

==================================================================================
What it does

- ZipRedemptionQueue.sol → senior par-burn redemption sink
A request escrows zipUSD; settling fills as much as the available USDC and pending amount allow, at par, and burns exactly the filled zipUSD; a claim pays the banked USDC. Par credits round down (sub-unit dust is locked, never swept), so the cumulative paid out can never exceed the cumulative delivered — the solvency property. Only the redemption vault may request, only the controller may settle, and only the requester may claim.
[contracts/src/supply/ZipRedemptionQueue.sol]
[../wires/9-ZipRedemptionQueue.md]

Summaries:
[../wires/9-ZipRedemptionQueue.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — the senior par-burn sink, with solvency under stateful invariants and the burn proven against the real zipUSD token (46 tests: 40 unit + 4 stateful invariants + 2 fork).

[contracts/src/supply/x-ray/ZipRedemptionQueue.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Solvency — cumulative USDC out never exceeds cumulative in — is enforced by par round-down and proven by four stateful invariants over randomized request/settle/claim sequences, plus exact multi-epoch par round-trips.
* The single-requester design is correctly fenced: a second open requester reverts rather than silently mis-attributing a fill, and the slot clears and reopens after a full drain.
* There is no fund-extraction surface — settling never moves USDC out (it only banks claimable), and a fork test asserts no sweep, rescue, or pause function exists. Stray-token donations don't corrupt the accounting.
* The burn is proven against the real zipUSD token over two repayment rounds (supply drops by exactly the filled amount, with no coupling to the senior pool). The par scaling factor is derived from decimals and re-derived if the tokens are re-pointed.
* Residual: build-phase wiring awaits the pre-production immutable re-freeze; no external audit.

==================================================================================
References:

- It is driven (request and claim) by the off-ramp module — [contracts/src/supply/szipUSD/OffRampModule.sol] ([szipUSD/OffRampModule.md]).
- It is funded by the warehouse repaying redemption proceeds — [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol] ([CreditWarehouse/WarehouseAdminModule.md]).
- It burns the senior dollar token (zipUSD) and pays USDC; it never touches the senior pool directly.
