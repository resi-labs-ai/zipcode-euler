# LIEN TOKEN FACTORY
[zipcode-euler/contracts/src]

The deterministic minter for per-line lien tokens. Base (chain 8453). Solidity 0.8.24.

* It deploys one fixed-supply lien token per line, at an address derived from both the line id and the caller — so the controller can compute the address before it opens the line.
* Binding the address to the caller makes it squat-proof: a stranger reusing a line id lands at a different address and cannot pre-occupy the controller's slot. And the same line id from the same caller can only ever deploy once.
* It is stateless — it stores no map, has no admin, owner, setter, or upgrade. Whoever calls it becomes the new token's controller; that caller-binding is the whole authorization.

==================================================================================
What it does

- LienTokenFactory.sol → caller-bound CREATE2 lien minter
Deploys a lien token at a deterministic address keyed on both the line id and the calling controller, and emits an event linking the line id to its token. It also exposes the pure address-prediction the controller uses to know the token's address ahead of time, and publishes the canonical 18-decimal constant the oracle registry validates every lien against. A re-deploy of the same line-id-and-caller reverts, and burning a token's supply never frees its address.
[contracts/src/LienTokenFactory.sol]
[wires/WOOF-01.md]

Summaries:
[wires/WOOF-01.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a stateless CREATE2 factory whose entire safety model is directly proven (7 dedicated tests, plus the real origination path).

[contracts/src/x-ray/LienTokenFactory.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Squat-proofing is the crux: because the address is bound to the caller, a stranger cannot front-run a controller by calling first — their token lands at a different address, leaving the controller's predicted address free.
* Single-use forever: the same line-id-and-caller reverts (the address is already occupied), and because the token never self-destructs, even a fully-burned line permanently keeps its address — so a line id is genuinely one-shot per caller.
* It carries none of the build-phase mutable-wiring residual: no admin, no state, no setter, no upgrade. The canonical 18-decimal constant it publishes is the one the oracle registry trusts, keeping the scale coherent across all three contracts.
* Residual: only the absence of an external audit; the CREATE2 primitive itself is audited OpenZeppelin.

==================================================================================
References:

- It mints the fixed-supply lien token — [contracts/src/LienCollateralToken.sol] ([LienCollateralToken.md]).
- The controller calls it in the origination batch and pre-computes the address — [contracts/src/ZipcodeController.sol] ([ZipcodeController.md]).
- Its 18-decimal constant is the pin the oracle registry validates every lien against — [contracts/src/ZipcodeOracleRegistry.sol] ([ZipcodeOracleRegistry.md]).
