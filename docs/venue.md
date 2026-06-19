# VENUE
[zipcode-euler/contracts/src/venue]

The layer that actually opens and runs credit lines on a lending venue. Base (chain 8453). Solidity 0.8.24.

* A "venue" is wherever the loans live — the lending platform whose pool the borrowed USDC comes out of. Today there is exactly one: Euler.
* The rest of the protocol talks to a venue only through one interface, so it never learns which venue it is. Adding a new platform means writing a new adapter, not rewiring the protocol.
* Each credit line is its own isolated cluster: a collateral box, a borrow vault, a frozen price source, and a fresh borrower account. One line's debt or default can never reach another line.
* The controller is the only caller. It opens a line, sets its limits, funds it, draws against it, reads its debt, and closes it — all through the interface.

* Built today: the full Euler venue and its credit lines (WOOF-04), the per-draw origination fee (CTR-09), the line interest rate (CTR-13, a real flat rate of about 7.5% a year), revolving lines (CTR-08), and the on-close slot reclaim that lets a pool churn lines (CTR-04). The venue-neutral senior read and admission gate are also done (CTR-10a/b). The one piece deferred is a second, non-Euler venue (CTR-10c).

==================================================================================
A federation, built to welcome other curation platforms.

The protocol is designed so that many credit pools can run under one shared senior dollar, and so those pools do not all have to live on the same lending platform. The venue interface is the place that openness lives. It is venue-neutral on purpose: only plain values cross it — a line handle, an amount, an address — and never any Euler-specific type. Because of that, the controller that drives lending has no idea whether the venue underneath is Euler or something else.

So a new curation platform plugs in as "just another adapter." Someone writes a contract that implements the same interface against their platform's own mechanics, and a future venue (Aave, Morpho, an orderbook) joins as a new silo with no change to the controller, the registry, or the shared senior. Each platform's curator runs their own lines and earns the curator fee on them, while loss stays walled off inside that silo's own junior tranche — the shared zipUSD only ever sees what is left after a junior is exhausted.

The plumbing for that is already in place. Each adapter answers a venue-neutral question — "what is your senior pool?" — that the registry checks at admission and the senior solvency math reads, so neither one is tied to Euler (CTR-10a/b). What is NOT built yet is a real second adapter (CTR-10c). That step is deferred, not for lack of scaffolding, but because it needs a venue actually chosen and actually deployed on-chain to bind against and to prove its balances cannot be cheaply manipulated. A mock cannot prove that. So the seam is ready and waiting; the open work is the real integration, to be built when a second venue is wanted.

==================================================================================
What the venue layer is made of. Three files, ordered by importance.

- IZipcodeVenue.sol → the venue interface
The one boundary the controller drives every venue action through: open a line, set its limits, fund it, draw to the off-ramp, read its debt, close it. Only plain values cross it, no platform-specific types, so the controller stays venue-agnostic and a new platform is just another implementation of this interface.
[contracts/src/venue/IZipcodeVenue.sol]
[wires/WOOF-04.md]

- EulerVenueAdapter.sol → the Euler venue (the only one built today)
The implementation of the interface against Euler. For each line it mints an isolated cluster — an escrow vault for the collateral, a borrow vault for the USDC, a frozen price router, and a fresh borrower account — then funds, draws, and closes it. It also charges the per-draw origination fee (CTR-09) and the per-line interest rate (CTR-13), sends the curator's share of that interest to the curator vault, and keeps the resting-cash reservoir topped up just in time.
[contracts/src/venue/EulerVenueAdapter.sol]
[wires/WOOF-04.md]

- LineAccount.sol → the per-line borrower account
A tiny contract created fresh for each line, deterministically from the lien identity. It is the borrower-of-record, and it gives the adapter permission to borrow on its behalf. This is what isolates one line's debt and collateral from every other line. After it is set up it does nothing more, and the cluster is abandoned when the line closes.
[contracts/src/venue/LineAccount.sol]
[wires/WOOF-04.md]

Summaries:
[wires/WOOF-04.md]

==================================================================================
References:

The venue layer is driven from above by the controller and read by the federation machinery; underneath, the Euler adapter is built on the live Euler stack.

- The controller is the sole caller — it routes a new loan to the current silo's adapter and drives open, fund, draw, and close through the interface — [contracts/src/ZipcodeController.sol] (CTR-03; [wires/WOOF-05.md]).
- The silo registry admits a silo only after asking its adapter, through the venue-neutral senior-pool getter, who its senior pool is — [contracts/src/SiloRegistry.sol] (CTR-10b; [docs/siloregistry.md]).
- The senior NAV aggregator sums each silo's senior backing through the venue-neutral senior read, so it does not care which venue backs a silo — [contracts/src/SeniorNavAggregator.sol] (CTR-05; reads [contracts/src/interfaces/supply/ISeniorPool.sol], CTR-10a).
- The Euler adapter uses, at line birth: the shared price registry [contracts/src/ZipcodeOracleRegistry.sol] (WOOF-02) and the borrow gating hook [contracts/src/CREGatingHook.sol] (WOOF-03). It installs the interest rate from its own interest-model slot, which the deploy fills with the roughly 7.5% model in [contracts/script/LineIrm.sol] (CTR-13). It funds lines out of, and is the curator of, the silo's EulerEarn senior pool.
