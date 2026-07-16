# SILO REGISTRY
[zipcode-euler/contracts/src]

The catalog that lets the protocol run many credit pools under one shared senior dollar. Base (chain 8453). Solidity 0.8.24.

* A "silo" is one complete credit stack: a venue adapter that opens lines, a Safe that holds the senior backing, an EulerEarn pool, and a junior tranche that absorbs the first loss.
* One EulerEarn pool can hold at most 28 credit lines. (Why 28: an EulerEarn pool's withdraw queue holds at most 30 markets, and every silo permanently spends two of them — one on the idle USDC reservoir and one on the junior tranche's farm-utility credit line — leaving 28 for actual credit lines.) To run more lines than that, the protocol runs more silos. The registry is the list that ties them all back to one mutualized senior zipUSD.
* Loss stays local to a silo's own junior; the senior is shared, so only the leftover after a junior is exhausted ever reaches zipUSD.
* Admission is the underwriting gate. A curator earns senior backing only by registering a silo whose parts all point at each other and not at a neighbor's.

* The scaling workstream is now built out: controller routing (CTR-03), close-line slot reclaim (CTR-04), the senior NAV aggregator (CTR-05), the silo deployer that stamps and registers a silo (CTR-06a/b/c), the split-slot farm utility fund/defund (CTR-07), structure-2 revolving lines (CTR-08), the per-revolution draw fee (CTR-09), and the federation generalization (CTR-10a/b). The one piece left is a reference adapter for an actual non-Euler venue (CTR-10c) — deferred until a second venue is chosen and exists on-chain.
* The admission gate is now venue-agnostic (CTR-10b). It no longer assumes the venue is Euler: it asks each adapter for its senior pool through a venue-neutral getter, so a future non-Euler venue (Aave, Morpho, an orderbook) can be admitted with no change to the registry — only the new adapter has to be built.

==================================================================================
The registry does three jobs, and nothing else. It never touches a silo's internals.

It admits silos. Only the Timelock can register one, and only if the silo is self-consistent. Before admitting, the registry asks the silo's freeze module, escrow, loss coordinator, and venue adapter who they point at, and rejects the silo unless they all point at its own senior pool, Safe, and oracle. The adapter is asked through a venue-neutral getter (its "senior pool"), so the same check works whether the venue is Euler or something else (CTR-10b). A mis-wired silo is turned away, so it can never drain or distort a sibling. The caller hands in only the addresses; the registry sets the live-line count to zero and marks the silo active itself.

It counts open lines. Each silo has a running count of how many credit lines are open, and a new line is refused once a silo hits 28. Only the controller can move the count, and it bumps the count as its very last step after a line opens, so a failed origination leaves no phantom line.

It names the active silo. New loans route to whichever silo is "current." When that silo fills, the Timelock points "current" at the next one. The registry never rolls over on its own; the move is always a governed step. A retired silo keeps its record so its open lines can still be read and closed.

A caveat that used to matter, now resolved: closing a line frees the registry's own count, and since CTR-04 the underlying EulerEarn withdraw-queue slot is physically freed on close too. So a pool churns 28 lines at a time (concurrent), not just 28 over its lifetime.

- SiloRegistry.sol → the silo catalog + admission gate
A plain Timelock-owned list of silos. It admits self-consistent silos, counts open lines per silo against the 28-line cap, and names the silo new loans route to. It holds no funds and changes no silo logic.
[contracts/src/SiloRegistry.sol]
[wires/CTR-02-SiloRegistry.md]

Summaries:
[wires/CTR-02-SiloRegistry.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a pure catalog that holds no funds; its admission gate and slot accounting are fully tested (30 unit tests).

[contracts/src/x-ray/SiloRegistry.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* Admission is the underwriting gate, and every clause is individually proven: a six-part topology check asserts the silo's freeze, escrow, loss coordinator, and adapter all point only at its own senior pool, Safe, and oracle. A silo that points any part at a neighbor is rejected.
* The line count and active flag are registry-managed, never caller-supplied: admission seeds the count to zero, only the controller moves it (as its last step after a line opens, so a failed origination leaves no phantom line), and the cap fails closed at 28.
* The admission gate is venue-agnostic — it asks each adapter for its senior pool through a venue-neutral getter, so a non-Euler venue plugs in unchanged.
* Residual (off-chain): the controller slot is owner-re-pointable until the pre-production immutable re-freeze; no external audit. It holds no funds and prices nothing.

==================================================================================
References:

The registry is read by the rest of the credit-warehouse scaling workstream, and it checks each silo against the components that stack already ships.

- The controller routes new loans to the current silo and moves the line count — [contracts/src/ZipcodeController.sol] (the siloId routing is CTR-03, built; [wires/WOOF-05.md]).
- The senior NAV aggregator sums every silo's senior par-backing into one solvency number — [contracts/src/SeniorNavAggregator.sol] (CTR-05, built; [wires/CTR-05-SeniorNavAggregator.md]). It reads only the registry's catalog and each silo's senior pool — through the venue-neutral ISeniorPool read (CTR-10a), so it does not care what venue backs the silo; nothing points back at it.
- The deployer stamps a fresh silo and registers it here — [contracts/script/SiloDeployer.s.sol] (CTR-06c, built; [wires/CTR-06c-SiloDeployer.md]), composing the per-piece sub-deployers (CTR-06a/b) into one complete silo the Timelock then admits.
- At admission the registry asks these for their wiring: the venue adapter via its venue-neutral seniorPool() getter [contracts/src/venue/EulerVenueAdapter.sol], the freeze module [contracts/src/supply/szipUSD/DurationFreezeModule.sol], the bond escrow [contracts/src/loss/LienXAlphaEscrow.sol], and the loss coordinator [contracts/src/loss/DefaultCoordinator.sol].
