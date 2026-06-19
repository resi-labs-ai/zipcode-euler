# CTR-10b — Federation host seam: venue-agnostic admission (the plug-in point) — DONE 2026-06-19

> Contract-track change. The host-side half of CTR-10: make `SiloRegistry` admission + the senior-read path
> venue-agnostic so a future non-Euler venue adapter plugs in with NO host change. Resolves CTR-10 obligation #3
> (the senior-surface plumbing decision). The actual reference non-Euler adapter (obligations #1/#2/#4 — needs a
> chosen, deployed venue) stays deferred as CTR-10c. Spec: `claude-zipcode.md` §4.7 (venue-agnostic).

## Why (the seam)
After CTR-10a the senior READ is venue-neutral (`ISeniorPool`). But the registry's `addSilo` topology assert still
dereferenced the Euler-specific `IAdapter(adapter).eulerEarn()`, so a non-Euler adapter (no `eulerEarn()`) could
not be admitted — admission would revert on the missing getter. That hardcode was the last Euler coupling on the
host side. Generalizing it is what turns "add a venue" from registry surgery into a plug-in.

## Deliverable (built)
1. `EulerVenueAdapter.seniorPool()` — a venue-neutral view returning `address(eulerEarn)` (the EE pool IS the
   `ISeniorPool` surface for this venue). NOT added to `IZipcodeVenue` (the seam stays senior-surface-free, §4.7).
2. `SiloRegistry`: rename the local `IAdapter` interface → `ISeniorVenue { seniorPool() }`; change the adapter
   clause of the `addSilo` assert from `IAdapter(adapter).eulerEarn() == eePool` →
   `ISeniorVenue(adapter).seniorPool() == eePool`. Re-document `eePool` as the silo's generic `ISeniorPool`
   senior-read surface (EE pool for Euler; venue pool / wrapper for non-Euler). Add the "VENUE-AGNOSTIC ADMISSION"
   plug-in recipe to the contract NatSpec.
3. The decision (CTR-10 obligation #3): **REUSE `eePool` as the read surface** — NOT a new `seniorRead` field.
   This is zero-churn (no struct change, no `SiloConfig` caller edits); the field name is documented as generic.
4. Test mocks: rename the venue `MockAdapter` stub's getter `eulerEarn`→`seniorPool` in `SiloRegistry.t.sol`,
   `SeniorNavAggregator.t.sol`, `SiloDeployer.t.sol`, `JuniorTrancheDeployer.t.sol` (the `MockFreeze` stubs keep
   `eulerEarn()` — the freeze clause is unchanged). A NEW `test_ctr10b_nonEuler_venue_plugs_in` proves a venue
   stand-in with NO `eulerEarn()` admits + aggregates donation-immune.

## Spec §
`claude-zipcode.md` §4.7, §8.2, §11, §17. No spec EDIT owed (the host seam invents no mechanism — it removes an
Euler hardcode; the federation §-sync stays forward-deferred for CTR-10c).

## Binds to (verified)
- `EulerVenueAdapter.eulerEarn` (`IEulerEarn public eulerEarn`) — `seniorPool()` returns `address(eulerEarn)`.
- `SiloRegistry.addSilo` clause 6 (was `SiloRegistry.sol:164`) + the local `IAdapter` interface (was `:30-34`).
- `SeniorNavAggregator` already reads `s.eePool` via `ISeniorPool` (CTR-10a) — no change needed.
- The freeze clause `IFreeze(freeze).eulerEarn() == eePool` already compares to `eePool` → generalizes for free.

## Do NOT
- Do NOT add a senior-surface method to `IZipcodeVenue` (it lives on the concrete adapter).
- Do NOT add a new `Silo`/`SiloConfig` field (reuse `eePool`; avoids caller churn).
- Do NOT rename the `DurationFreezeModule.eulerEarn` storage slot (CTR-10a scope decision; ripples into the freeze
  clause). Do NOT remove `EulerVenueAdapter.eulerEarn()` (other call sites + tests read it).
- Do NOT claim donation-immunity for a real non-Euler venue here (CTR-10c — needs the real venue, not a mock).

## Key requirements
1. The registry admission gate dereferences NO Euler-specific getter on the adapter (venue-agnostic).
2. The existing Euler path is byte-identical (`seniorPool() == eulerEarn == eePool`); full suite stays green.
3. A non-Euler venue stand-in (adapter with `seniorPool()` only, no `eulerEarn()`) admits + aggregates.

## Done when (gate — `forge test`)
- `forge build` green; FULL suite green. **MET: 920 passed / 0 failed / 3 skipped (56 suites)** (the +1 is the new
  plug-in test). The 6 silo/aggregator/deployer suites = 140/140.
- Cold-build with ZERO load-bearing guesses. **MET.**

## Depends on / unblocks
- **Depends on:** CTR-10a (`ISeniorPool`), CTR-02 (`SiloRegistry`), CTR-05 (aggregator).
- **Unblocks:** CTR-10c (a real non-Euler adapter now plugs in with no host change) — itself still gated on a
  chosen, deployed second venue (CTR-10 obligations #1/#2/#4).
