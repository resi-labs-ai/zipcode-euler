# ZIPCODE CONTROLLER
[zipcode-euler/contracts/src]

The orchestrator that opens, draws, and closes credit lines on the protocol's say-so. Base (chain 8453). Solidity 0.8.24.

* An off-chain Chainlink keeper sends it a typed instruction; the controller decides what to do and drives it through the venue, the lien token, the price oracle, and the silo registry. It touches no lending venue directly — every venue effect goes through the venue-neutral interface.
* Opening a line is one all-or-nothing batch: create the lien token, open the line, seed its price, set its limits, fund it, draw to the off-ramp, record it, and bump the silo's line count. If any step fails, the whole thing rolls back, including the freshly deployed contracts — so there is never a half-built line.
* Draws and closes re-resolve the venue from the line's stored silo, never a global pointer, so a re-pointed or retired silo can never strand or misroute a line.

==================================================================================
What it does

- ZipcodeController.sol → the credit-line orchestrator
Decodes the keeper's instruction and dispatches by type: originate (the atomic batch above), draw (re-anchor the price, fund, draw), or close (require zero debt, close the line, burn the lien, decrement the count). Default and liquidation instructions are status markers only in this milestone. Any unrecognized instruction reverts — notably the revaluation type, which is delivered straight to the oracle and must not be processed here. It is the borrower of record but holds no funds beyond a transient one-token lien approval.
[contracts/src/ZipcodeController.sol]
[wires/WOOF-05.md]

Summaries:
[wires/WOOF-05.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — the portable core's orchestrator, fork-proven against the real Euler stack (43 tests).

[contracts/src/x-ray/ZipcodeController.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Atomicity is the core property: an origination touches the factory, the venue, the oracle, and the registry, and any failure (over-limit draw, zero price, silo full) rolls back the whole batch including the freshly deployed lien and market — no orphans.
* Routing is fail-closed: draws and closes re-resolve the venue from the line's stored silo via the registry, so a retired or re-pointed silo can't misroute a line, and a line can always close even after its silo is retired. An unwired registry reverts rather than falling back.
* Only origination, draw, close, and the default/liquidation markers are accepted; everything else (including the revaluation type meant for the oracle) reverts. Reentrancy is structurally impossible (the record write is the last state change before a trusted, no-callback registry call).
* Residual (off-chain): the five wiring slots are owner-re-pointable until the pre-production immutable re-freeze; no external audit.

==================================================================================
References:

- It drives the venue through the venue-neutral interface — [contracts/src/venue/IZipcodeVenue.sol], implemented by [contracts/src/venue/EulerVenueAdapter.sol] ([venue.md]).
- It mints each line's lien token via the factory — [contracts/src/LienTokenFactory.sol] ([LienTokenFactory.md]) — and burns it on close — [contracts/src/LienCollateralToken.sol] ([LienCollateralToken.md]).
- It seeds and re-anchors the lien price in the oracle registry — [contracts/src/ZipcodeOracleRegistry.sol] ([ZipcodeOracleRegistry.md]).
- It routes new loans to the current silo and moves the line count — [contracts/src/SiloRegistry.sol] ([SiloRegistry.md]).
