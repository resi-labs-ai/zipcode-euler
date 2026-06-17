# INTERFACES — COW
[zipcode-euler/contracts/src/interfaces/cow]

A minimal shim over CoW Protocol's settlement contract — the bit the buy-and-burn bid touches. Base (chain 8453). Solidity 0.8.24.

==================================================================================
CoW provides a orderbook, which allows the Baal Safe, as well as outside buyers, to post limit orders for szipUSD.

* An outside buyer posts their own limit order ("buy szipUSD with USDC at $0.89").
* A holder who wants out posts a sell order.
* CoW matches it against whoever offers the best price — another buyer, or the protocol's standing bid.

The protocol's module is only special because it bids from a Safe with no private key, so it has to sign on-chain. Everyone else signs in their wallet.

Note:

We don't import CoW's real code — we hand-write a small interface listing only the functions we call, and we verified (with `cast`) that those signatures match the live contract.

- IGPv2Settlement.sol → CoW Protocol `GPv2Settlement` `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (same address on every chain)
CoW's settlement contract — where CoW trades execute. SzipBuyBurnModule uses it to rest a standing order to buy back szipUSD with USDC, signed directly on-chain (no private key).
[contracts/src/supply/szipUSD/SzipBuyBurnModule.sol]
[wires/8-B14-SzipBuyBurnModule.md]

Summaries:
[../wires/interfaces-cow.md]

==================================================================================
References:

The shim declares only the presignature + domain surface; selectors and addresses are verified against the live Base settlement.

- CoW Protocol — the `GPv2Settlement` singleton on Base (`0x9008D19f58AAbD9eD0D60971565AA8510560ab41`).

Two things to get right (see the wire doc):

- The order's owner is the engine Safe, not the module — the Safe is what calls the settlement.
- USDC is approved to the vault relayer (`0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`), not to the settlement contract.
