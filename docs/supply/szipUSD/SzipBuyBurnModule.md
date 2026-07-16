# SZIPUSD ENGINE — SzipBuyBurnModule
[zipcode-euler/contracts/src/supply/szipUSD]

The protocol's only exit valve: the discounted buyer-of-last-resort for szipUSD. Base (chain 8453). Solidity 0.8.24.

* It posts a single resting buy order for szipUSD on CoW, priced at or below NAV minus a set discount, paid in USDC and signed on-chain from the engine vault.
* Anything it buys is burned by the Exit Gate. A protocol-wide wind-down is just this same bid, sized larger and re-armed — there is no other exit primitive.
* An off-chain Chainlink keeper (or a CRE report) triggers it. It supplies only three order fields (sell amount, buy amount, expiry); every other order detail is fixed in the contract, and it holds no funds.

Outside participants: szipUSD is a plain transferable token that trades freely on CoW. Anyone can post their own buy or sell order from their own wallet without touching any Zipcode contract. This module is special only because it is the protocol's backstop bid, signed on-chain from the vault rather than from an EOA.

==================================================================================
What it does

- SzipBuyBurnModule.sol → the buy-and-burn bid
Posts/cancels one resting CoW buy order for szipUSD. The price is bounded to at most NAV minus the discount (exact integer math, never rounding up into an above-NAV fill), the size is capped (a zero cap is a kill-switch), the post is blocked while the vault is under its coverage floor, and a stale NAV mark blocks it. The order is funded by approving the CoW relayer; the post and the approval are one atomic step.
[contracts/src/supply/szipUSD/SzipBuyBurnModule.sol]
[../../wires/8-B14-SzipBuyBurnModule.md]

Summaries:
[../../wires/8-B14-SzipBuyBurnModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (a hair from HARDENED) — the most-reworked module and the value-out path, with the deepest deterministic suite in the engine (52 tests; the CoW order id is checked against an out-of-band known-answer vector, the on-chain signing is fork-verified against real CoW).

[contracts/src/supply/szipUSD/x-ray/SzipBuyBurnModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* Because this bid is the only exit, its checks ARE the exit-safety model, and each is tested: the exact discount price bound (priced off the exit NAV, never the time-average), the size cap plus kill-switch, the coverage gate, and the NAV-freshness fence (a resting order can't fill against a mark older than the freshness window).
* Only three order fields are caller-supplied; every other field is a fixed constant and the contract hashes exactly the order it validated, so no unchecked field can enter the signed order. Hooks are disabled.
* Residual (off-chain, accepted): the keeper sizes the three fields — bounded by the price/cap/coverage/freshness gates and the buyer being the vault, never theft. A compromised Timelock owner could redirect the vault wiring (accepted; the same Timelock governs everything).

==================================================================================
References:

- It prices off the NAV oracle — [contracts/src/supply/SzipNavOracle.sol] ([../../wires/8-B4-SzipNavOracle.md]).
- It signs orders through the CoW settlement contract — [contracts/src/interfaces/cow/IGPv2Settlement.sol] (see [../../interfaces/interfaces-cow.md]).
- It can also be driven by a Chainlink CRE report through its inherited report socket — [contracts/src/supply/szipUSD/CloneReportReceiver.sol] ([CloneReportReceiver.md]).
- The bought szipUSD is retired by the Exit Gate — [contracts/src/supply/szipUSD/ExitGate.sol] ([ExitGate.md]).
