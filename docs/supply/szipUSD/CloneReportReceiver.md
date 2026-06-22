# SZIPUSD ENGINE — CloneReportReceiver
[zipcode-euler/contracts/src/supply/szipUSD]

The clone-safe base that lets a Chainlink CRE report drive an engine module. Base (chain 8453). Solidity 0.8.24.

* Engine modules are deployed once as a master copy, then cheaply cloned per vault. The standard Chainlink report receiver sets its trusted sender in its constructor — which a clone never runs — so a cloned standard receiver would be callable by anyone.
* This base inverts that: an unconfigured clone is inert. With no trusted sender set, the report path is closed; only after the Timelock wires the sender can a report drive the module.
* It carries no business logic — only the report intake, optional checks on who authored the report, and a hook the concrete module fills in.

==================================================================================
What it does

- CloneReportReceiver.sol → fail-closed CRE report intake for clones
A mixin a module inherits so a Chainlink-signed report, delivered through the trusted forwarder, can drive it alongside the keeper. The report path is closed unless the caller is the wired forwarder, with optional rejection of a mismatched report author or workflow. It has no constructor (so a clone starts inert) and reuses the module's single owner rather than adding a second.
[contracts/src/supply/szipUSD/CloneReportReceiver.sol]
[../../wires/8-B14-SzipBuyBurnModule.md]

Summaries:
[../../wires/8-B14-SzipBuyBurnModule.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — its decisive property (the fail-closed clone behavior) is directly tested; 8 tests via the buy-and-burn suite, its one current consumer.

[contracts/src/supply/szipUSD/x-ray/CloneReportReceiver.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The reason it exists — a fresh clone with no trusted sender rejects the report path from everyone until the Timelock wires it — is proven directly.
* The report path dispatches to the same internal handler as the keeper path, proven to produce byte-identical effect; both author and workflow identity checks are tested.
* Residual: it is designed for reuse across the fleet but is proven by one consumer today, so the follow-up is a dedicated test suite when a second module adopts it. The not-set trusted-sender state is intentional (the inert state), not a bug.

==================================================================================
References:

- Its one current consumer is the buy-and-burn module — [contracts/src/supply/szipUSD/SzipBuyBurnModule.sol] ([SzipBuyBurnModule.md]).
- It re-implements, clone-safely, the Chainlink CRE report-receiver surface (the same role the standard receiver template plays for the non-clone receivers).
