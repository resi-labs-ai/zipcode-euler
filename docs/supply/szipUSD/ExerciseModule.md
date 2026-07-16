# SZIPUSD ENGINE — ExerciseModule
[zipcode-euler/contracts/src/supply/szipUSD]

The paid-exercise leg: it turns the HYDX reward options into liquid HYDX. Base (chain 8453). Solidity 0.8.24.

* The harvest leg claims HYDX options; this module pays the USDC strike to exercise them, minting liquid HYDX into the vault.
* The strike is computed by the option contract itself from its own time-average price; the module just caps the most it will pay, so a price spike between the keeper's quote and execution safely aborts instead of overpaying.
* An off-chain keeper triggers it with an amount, a max payment, and a deadline; the module builds the call and holds no funds.

==================================================================================
What it does

- ExerciseModule.sol → pay the strike, mint liquid HYDX
One keeper-only action that runs exactly three steps: approve the option for the capped payment, exercise (which burns the vault's options, pulls the USDC strike, and mints HYDX), then reset the approval to zero. The minted HYDX is hard-pinned to the vault, and the max-payment cap is the slippage guard, re-checked on the return so even a misreporting option cannot pull more than the cap.
[contracts/src/supply/szipUSD/ExerciseModule.sol]
[../../wires/8-B8-ExerciseModule.md]

Summaries:
[../../wires/8-B8-ExerciseModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — a tightly-scoped fleet module, tested unit plus live-fork against the real deployed option contract: 26 unit + 4 fork tests.

[contracts/src/supply/szipUSD/x-ray/ExerciseModule.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The minted HYDX recipient is hard-pinned to the vault — there is no recipient parameter for a keeper to set. Proven on a live fork.
* The strike is bounded by the max-payment cap (enforced by the option, re-asserted by the module, and bounded by the capped approval); a too-low cap or a past deadline aborts with state unchanged.
* No standing approval survives (approve, exercise, reset), and a failed inner call hard-reverts.
* Residual (off-chain): the keeper sizes the max-payment cushion (a loose cushion is a griefing-cost ceiling, not a leak). Build-phase wiring awaits the pre-production immutable re-freeze.

==================================================================================
References:

- It exercises the Hydrex HYDX option — [contracts/src/interfaces/hydrex/IOptionToken.sol] (see [../../interfaces/interfaces-hydrex.md]).
- It exercises options claimed by the harvest leg — [contracts/src/supply/szipUSD/HarvestVoteModule.sol] ([HarvestVoteModule.md]).
- The resulting HYDX is market-sold by the sell module — [contracts/src/supply/szipUSD/SellModule.sol] ([SellModule.md]).
