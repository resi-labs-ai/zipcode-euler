# LIEN COLLATERAL TOKEN
[zipcode-euler/contracts/src]

The one-token-per-line collateral marker. Base (chain 8453). Solidity 0.8.24.

* Each credit line has its own instance of this token: exactly one whole token (1e18) minted once to the controller at deployment, and the token's address IS the line's identity.
* It can only shrink. There is no second mint, and only the controller can burn — which it does when the line closes. The controller is fixed at deployment with no admin, setter, or upgrade.
* It is posted as the line's collateral inside the lending market. The fixed one-token supply is what lets a line open cleanly and close without a reclaim shortfall.

==================================================================================
What it does

- LienCollateralToken.sol → fixed-supply lien collateral token
A near-vanilla ERC-20 with exactly three changes: the constructor mints the whole 1e18 supply to the controller (no other mint path exists), decimals are pinned to 18 (so the oracle's inferred scale can't drift), and burn is controller-only. Everything else is unmodified OpenZeppelin.
[contracts/src/LienCollateralToken.sol]
[wires/WOOF-01.md]

Summaries:
[wires/WOOF-01.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a minimal fixed-supply token whose every non-standard surface is tested (8 dedicated tests, plus used as the real lien token across the controller, venue, and oracle suites).

[contracts/src/x-ray/LienCollateralToken.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Fixed one-token supply, mint-once, supply-only-shrinks: there is no mint function after construction, and burn (controller-only, including the zero and over-balance edges) is the only supply mutator.
* The fixed 1e18 is load-bearing for the venue: opening a line requires exactly one token and close reclaims exactly one before burning, so a token that could mint more or start at a different supply would break the line lifecycle — made impossible here by construction.
* It is unique in the subsystem for having no build-phase mutable wiring: the controller is immutable, there is no owner, setter, or upgrade. The only authority is burn-from-own-balance, which cannot move value to a third party.
* Residual: only the absence of an external audit; the standard ERC-20 is unmodified OpenZeppelin.

==================================================================================
References:

- It is minted, one per line, by the factory — [contracts/src/LienTokenFactory.sol] ([LienTokenFactory.md]).
- Its controller (sole burner) is the controller — [contracts/src/ZipcodeController.sol] ([ZipcodeController.md]).
- It is posted as collateral in the lending market — [contracts/src/venue/EulerVenueAdapter.sol] ([venue.md]) — and priced by the oracle registry, which validates its 18-decimal pin — [contracts/src/ZipcodeOracleRegistry.sol] ([ZipcodeOracleRegistry.md]).
