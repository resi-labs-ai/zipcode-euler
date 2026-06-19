# SILO REGISTRY
[zipcode-euler/contracts/src]

The catalog that lets the protocol run many credit pools under one shared senior dollar. Base (chain 8453). Solidity 0.8.24.

* A "silo" is one complete credit stack: a venue adapter that opens lines, a Safe that holds the senior backing, an EulerEarn pool, and a junior tranche that absorbs the first loss.
* One EulerEarn pool can hold at most 28 credit lines. To run more lines than that, the protocol runs more silos. The registry is the list that ties them all back to one mutualized senior zipUSD.
* Loss stays local to a silo's own junior; the senior is shared, so only the leftover after a junior is exhausted ever reaches zipUSD.
* Admission is the underwriting gate. A curator earns senior backing only by registering a silo whose parts all point at each other and not at a neighbor's.

* The controller routing (CTR-03), the close-line slot reclaim (CTR-04), and the senior NAV aggregator (CTR-05) are now built. What remains of the core workstream is the deployer that stamps and registers a silo (CTR-06), the split-slot reservoir fund/defund (CTR-07), and the structure-2 / fee / federation work (CTR-08..10).
* TODO — Not wired into any deploy yet. Nothing registers a silo until the deployer (CTR-06) exists.

==================================================================================
The registry does three jobs, and nothing else. It never touches a silo's internals.

It admits silos. Only the Timelock can register one, and only if the silo is self-consistent. Before admitting, the registry asks the silo's freeze module, escrow, loss coordinator, and venue adapter who they point at, and rejects the silo unless they all point at its own pool, Safe, and oracle. A mis-wired silo is turned away, so it can never drain or distort a sibling. The caller hands in only the addresses; the registry sets the live-line count to zero and marks the silo active itself.

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
References:

The registry is read by the rest of the credit-warehouse scaling workstream, and it checks each silo against the components that stack already ships.

- The controller routes new loans to the current silo and moves the line count — [contracts/src/ZipcodeController.sol] (the siloId routing is CTR-03, built; [wires/WOOF-05.md]).
- The senior NAV aggregator sums every silo's senior par-backing into one solvency number — [contracts/src/SeniorNavAggregator.sol] (CTR-05, built; [wires/CTR-05-SeniorNavAggregator.md]). It reads only the registry's catalog and each silo's EulerEarn position; nothing points back at it.
- The deployer stamps a fresh silo and registers it here — CTR-06, not yet built.
- At admission the registry asks these for their wiring: the venue adapter [contracts/src/venue/EulerVenueAdapter.sol], the freeze module [contracts/src/supply/szipUSD/DurationFreezeModule.sol], the bond escrow [contracts/src/loss/LienXAlphaEscrow.sol], and the loss coordinator [contracts/src/loss/DefaultCoordinator.sol].
