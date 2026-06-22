# CREDIT WAREHOUSE — WarehouseAdminModule
[zipcode-euler/contracts/src/supply/CreditWarehouse]

The senior side's vault and its gatekeeper. Base (chain 8453). Solidity 0.8.24.

* A plain Gnosis Safe holds the EulerEarn pool shares that back every zipUSD in circulation. This is the senior backing, kept completely separate from the junior szipUSD side.
* An audited access-control engine (a Zodiac Roles Modifier, from Gnosis Guild) sits in front of that Safe. It permits exactly four operations, each only to the right address, and nothing else.
* WarehouseAdminModule is the thin adapter a Chainlink CRE workflow drives. It turns one CRE instruction into one of the four allowed operations and forwards it through the access engine. It holds no funds and grants no permissions of its own.
* The four operations: supply USDC into the pool, approve the pool to pull USDC, redeem shares back to USDC, and repay USDC to the redemption queue. There is no fifth thing it can do.

* TODO — Build the CRE workflow that drives the four operations.
* TODO — Set the CRE workflow identity (author + workflow name) BEFORE funding the warehouse. Until it is set, the per-workflow gate is off and any forwarded workflow could drive ops.
* TODO — Wire the repay destination to the live redemption queue, which must be non-sweepable.
* TODO — Add a drain-defense (a rate-limit and/or an owner-cancellable delay) on the redeem and repay operations.
* TODO — Pre-production: re-freeze the build-phase wiring from re-pointable to immutable.

==================================================================================
What the warehouse is made of. Two files, plus two pieces of external infrastructure it is wired to.

- WarehouseAdminModule.sol → the CRE adapter and gatekeeper
The only authored contract here. It is the sole member of the access engine's role, so it is the one caller allowed to drive the Safe. A CRE instruction names an operation and an amount; the adapter builds the matching call to the pool or the USDC token and forwards it. The dangerous choices are hardcoded and can never be set by the caller: it never sends value, never delegates a call, and never picks its own recipient. The only address a caller supplies is the repay destination, and that is both checked against the wired queue and re-supplied from it, so it cannot be redirected.
[contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol]
[../../wires/8-Bw-CreditWarehouse.md]

- CreditWarehouseDeployer.sol → the deploy and wiring script
Stands up the Safe, the access engine, the scope (the list of what is allowed), and the adapter against the live Base infrastructure, then hands ownership to the protocol's owner. It checks every piece is wired correctly before allowing the scope to be set.
[contracts/script/CreditWarehouseDeployer.sol]
[../../wires/8-Bw-CreditWarehouse.md]

The two external pieces it relies on, both deployed (not authored here):
- The warehouse Gnosis Safe — the vault that custodies the EulerEarn shares and is the only place redeemed USDC lands.
- The Zodiac Roles Modifier — the audited access engine that actually enforces "only these four operations, only to these addresses." This is the real security boundary, not the adapter.

There is no public entry. Only the CRE workflow (behind Chainlink's forwarder) and the owner (the Timelock, which re-points wiring) can call anything. No one can drive this from a wallet.

Summaries:
[../../wires/8-Bw-CreditWarehouse.md]

==================================================================================
Security X-Ray (audit fidelity)

The warehouse-admin scope has a dedicated, test-connected X-Ray under contracts/src/supply/CreditWarehouse/x-ray/. The adapter is rated HARDENED, proven by 28 fork-integration tests that drive the REAL deployed access engine, not a mock.

[contracts/src/supply/CreditWarehouse/x-ray/x-ray.md] — scope-level overview + verdict
[contracts/src/supply/CreditWarehouse/x-ray/WarehouseAdminModule.md] — the per-contract review

The load-bearing points an auditor should check (full catalog + test connection live in the X-Ray):

* The real control is the access engine's scope, NOT this bytecode. The adapter holds no funds and enforces no permissions; the decisive rule set — receiver must be the Safe, the approve spender must be the pool, the repay destination must be the queue, calls only (no delegate-calls, no value) — lives in the deployed Roles scope. The strength of the test suite is that it exercises that real deployed scope: a second role member sending redirected parameters is rejected.
* Everything dangerous is hardcoded; only addressable things are injected. A caller can never request a value transfer or a delegate-call, and never names the supply/approve/redeem recipient. The one address a caller does supply (the repay destination) is double-defended — the adapter rejects a wrong one, and the scope independently pins it to the queue.
* A compromised CRE controls amounts and timing only. The worst case is griefing, not theft: stalling redemption funding, or shuffling the backing between the Safe and the pool at bad times. It cannot move funds to an attacker, change the Safe's owners, or reach any other operation.
* The Safe-versus-engine identity must agree. The adapter's wired Safe and the access engine's target Safe are separate slots; a one-sided re-point used to silently break supply and redeem. That hazard is now caught on-chain — the setter reverts unless the two already match, so the re-point must be done in the right order (set the engine's target first).

Residuals (process, not code gaps):
* The deployed access-engine scope tree is the primary off-chain audit artifact — audit it directly.
* The build-phase wiring is owner-re-pointable until the deferred pre-production immutable re-freeze.
* No external audit yet.

==================================================================================
References:

The warehouse is the senior backing; it is driven by Chainlink CRE and read by the senior solvency math. The pieces it touches:

- The senior pool it supplies and redeems against is the silo's EulerEarn USDC vault — [contracts/src/interfaces/euler/IEulerEarn.sol] (see [../../interfaces/interfaces-euler.md]).
- The access engine and the Safe are reached through minimal local interfaces — [contracts/src/interfaces/zodiac/IRoles.sol], [contracts/src/interfaces/safe/ISafe.sol] (see [../../interfaces/interfaces-zodiac.md], [../../interfaces/interfaces-safe.md]).
- Suppliers' USDC reaches the Safe as shares without passing through it — the deposit module deposits straight into the pool with the Safe as the share recipient — [contracts/src/supply/ZipDepositModule.sol] (WOOF-06).
- Redeemed USDC is repaid to the senior exit queue — [contracts/src/supply/ZipRedemptionQueue.sol] (item 9; [../../wires/9-ZipRedemptionQueue.md]).
- The senior NAV aggregator only reads the Safe's share balance to mark senior backing — [contracts/src/SeniorNavAggregator.sol] (CTR-05).
- The Zodiac setup and the order-dependent re-point rule are documented in [../../roles.md].
