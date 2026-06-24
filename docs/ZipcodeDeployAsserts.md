# ZIPCODE DEPLOY ASSERTS
[zipcode-euler/contracts/src]

The last safety check the deploy runs before it hands the keys to the Timelock. Base (chain 8453). Solidity 0.8.24.

* It is a small library of deploy-time checks, run immediately before the irreversible ownership hand-off, that verify the system was wired correctly so it can never be frozen in a broken state.
* It guards a real hazard: a report receiver's identity check only bites once its expected author and workflow name are set. Sealing the system before those are wired would leave a receiver any co-tenant workflow on the same channel could drive.
* It also confirms the oracle registry's one-time controller is set, so the registry can't be sealed unseedable.

==================================================================================
What it does

- ZipcodeDeployAsserts.sol → deploy-time wiring assertions
Two checks the deploy script calls before the ownership hand-off to the Timelock (build-phase §17 — a transfer, not a renounce): every sealed CRE receiver must have both its expected author and workflow name wired (each is checked individually), and the oracle registry's controller must be set. It also fails closed on an empty receiver list. It reverts on the first failure — fail-closed — so a misconfigured fleet can never be frozen live. It is an internal library with no deployed code of its own; it compiles into the deploy script.
[contracts/src/ZipcodeDeployAsserts.sol]
[wires/WOOF-10a.md]

Summaries:
[wires/WOOF-10a.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a deploy-time assertion library defending the dormant-identity hazard, with the hazard itself demonstrated in tests (13 tests).

[contracts/src/x-ray/ZipcodeDeployAsserts.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* The hazard it defends is concretely demonstrated: a receiver sealed before its identity is wired accepts a report from the wrong identity, while a properly sealed one rejects a wrong name and accepts the correct one.
* It checks each receiver individually (author and workflow name both required, since the name separates two same-author keepers) and confirms the registry's controller is seeded; it reverts on the first miss.
* It is a defense, not a surface: no state, no admin, no deployed code, no runtime path. The one residual is a process invariant — the deploy script must actually call it before the hand-off — which is itself covered by the deploy test.
* Residual: only the absence of an external audit.

==================================================================================
References:

- It is called by the main deploy script before the ownership hand-off — [contracts/script/DeployZipcode.s.sol] ([wires/DeployZipcode.md]).
- It checks the identity of every CRE receiver (the controller, the oracle registry, and the engine receivers) and the oracle registry's controller — [contracts/src/ZipcodeController.sol] ([ZipcodeController.md]), [contracts/src/ZipcodeOracleRegistry.sol] ([ZipcodeOracleRegistry.md]).
- The identity posture it enforces is documented alongside the Zodiac and CRE wiring — [roles.md].
