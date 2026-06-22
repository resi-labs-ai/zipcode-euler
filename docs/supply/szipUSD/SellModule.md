# SZIPUSD ENGINE — SellModule
[zipcode-euler/contracts/src/supply/szipUSD]

The market-sell leg: it swaps tokens on the Algebra DEX. Base (chain 8453). Solidity 0.8.24.

* Three swaps: sell HYDX for USDC (the leg that repays the strike loan), buy xALPHA with zipUSD, and sell xALPHA back to zipUSD (the wind-down hop).
* The HYDX sale carries a per-call size cap so a compromised keeper can't dump the whole HYDX basket in one transaction — the slippage floor bounds price, the cap bounds size.
* An off-chain keeper triggers it with amounts, a minimum out, and a deadline; the swap output can only land in the vault.

==================================================================================
What it does

- SellModule.sol → the Algebra swap seam
Three keeper-only swaps sharing one approve-swap-reset sequence. The token pair is hard-pinned per swap and the recipient is hard-pinned to the vault, so a keeper cannot redirect the output or swap an arbitrary pair. The minimum-out is the slippage guard (the router reverts a bad-price fill), and the HYDX sale additionally reverts above the owner-set size cap.
[contracts/src/supply/szipUSD/SellModule.sol]
[../../wires/8-B9-SellModule.md]

Summaries:
[../../wires/8-B9-SellModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — a clean swap leg, tested unit plus live-fork against the real Algebra router: 34 unit + 4 fork tests.

[contracts/src/supply/szipUSD/x-ray/SellModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The recipient and the token pair are hard-pinned (output only to the vault); proven against the live router.
* The HYDX size cap is the distinctive control — the minimum-out only bounds price, so the cap is what stops a full-basket dump; the buy and the xALPHA sale are correctly uncapped (different token / the protocol's own pool). The cap is Timelock-resizable to track pool depth.
* A too-high minimum-out or a past deadline aborts with state unchanged; no standing approval survives.
* Residual (off-chain): the keeper sizes the swaps, bounded by the cap, the minimum-out, and the pins. Build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It swaps through the Algebra router — [contracts/src/interfaces/algebra/ISwapRouter.sol] (see [../../interfaces/interfaces-algebra.md]).
- It sells the HYDX produced by the exercise leg — [contracts/src/supply/szipUSD/ExerciseModule.sol] ([ExerciseModule.md]).
