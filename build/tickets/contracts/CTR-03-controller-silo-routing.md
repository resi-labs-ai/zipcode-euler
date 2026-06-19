# CTR-03 — ZipcodeController: siloId routing over the registry

> Contract-track change (EXPANSION). Makes the controller multi-pool: instead of one hardcoded `venue` pointer it
> resolves the venue per origination from `SiloRegistry` (CTR-02) via a `siloId` carried in the CRE report, and
> records the `siloId` on the lien so draws/closes re-resolve the same venue. Adds the slot-count hooks. This is
> the routing half of sequential-fill sharding.
> Spec: `claude-zipcode.md` §4.7 (venue-agnostic) / §8 (report envelope) / §17 (Timelock wiring).
> **Open decision A (locked: single controller + registry).**

## Why (the seam)
`ZipcodeController._processReport` dispatches origination/draw/close through ONE mutable `venue`
(`contracts/src/ZipcodeController.sol:51,153-249`). To fill multiple pools the controller must pick which silo a
new line lands in. Decision (session): a **single controller** resolving `venue = registry.venueOf(siloId)` from a
`siloId` in the report — NOT one controller per silo. The CRE composer picks `siloId` (the current fill target),
the registry backstops with a fail-closed slot cap.

## Deliverable
Modify `contracts/src/ZipcodeController.sol`:
1. Add a `registry` wiring slot + `setRegistry` (`onlyOwner`, `WiringSet("registry", …)`) mirroring the existing
   setters (`:118-143`). Keep `venue` as a fallback ONLY if `registry == address(0)` (back-compat for the single
   silo), else resolve through the registry. (Pin: prefer requiring `registry != 0` once silo #0 is registered.)
2. Add `bytes32 siloId` to `LienRecord` (`:62-66`) and to `LienOriginated` (`:80-87`).
3. `_origination` (`:173-212`): decode `siloId` as the FIRST payload field (ABI bump — see Do NOT). Resolve
   `address venue = registry.venueOf(siloId)`; require `venue != 0`. Drive `openLine`/`setLineLimits`/`fund`/`draw`
   through that local `venue`. After step-8 `liens` write succeeds, call `registry.incrementLineCount(siloId)`
   (LAST write — fail-closed, mirrors the `liens`-write-last F-10 rule).
4. `_draw` (`:215-230`) / `_close` (`:233-249`): read `r.siloId`, resolve `venue = registry.venueOf(r.siloId)`,
   drive through it. `_close` calls `registry.decrementLineCount(r.siloId)` after `closeLine` succeeds.
5. Keep the single CRE write-entry `_processReport` and the RT_* routing (`:39-44,153-169`) unchanged in shape.

## Spec §
`claude-zipcode.md` §4.7 (the venue seam stays `IZipcodeVenue`; routing is which instance), §8.0 (the report
payload gains a leading `bytes32 siloId` for RT_ORIGINATION; the §8 producer table row for RT_ORIGINATION must be
updated), §17.

## Binds to (verified)
- `SiloRegistry.venueOf`/`incrementLineCount`/`decrementLineCount` (CTR-02).
- The as-built controller branches: `_processReport` (`:153-169`), `_origination` decode
  `(bytes32,bytes32,uint256,uint16,uint16,uint256,uint256)` (`:174-182`), `_draw` decode
  `(bytes32,bytes32,uint256,uint256)` (`:216-217`), `_close` decode `(bytes32)` (`:234`).
- `IZipcodeVenue` (`contracts/src/venue/IZipcodeVenue.sol`) — unchanged seam.

## Starting state
- `ZipcodeController` as filed: single `venue`, `LienRecord{lien,lineRef,open}`, RT_ORIGINATION payload has no
  `siloId`. Fork-tested. `SiloRegistry` exists (CTR-02).

## Do NOT
- Do NOT change the `IZipcodeVenue` interface — only WHICH instance the controller calls.
- Do NOT change RT_* numerals or the `_processReport` envelope shape; only the RT_ORIGINATION payload gains a
  leading `siloId` (and RT_DRAW/RT_CLOSE re-resolve from the stored `r.siloId`, so their payloads are unchanged).
- Do NOT increment the line count before `openLine` succeeds (phantom-count leak on revert).
- Do NOT remove the single-controller model in favor of per-silo controllers (decision A locked).

## Key requirements
1. **Re-resolve on draw/close from stored `siloId`** — never from a global pointer, so a re-pointed `currentSilo`
   or registry cannot strand an open line in the wrong venue.
2. **Fail-closed routing** — `venueOf(siloId) == 0` reverts origination; `incrementLineCount` reverting `SiloFull`
   rolls the whole atomic origination back (it's the last write).
3. **Atomicity preserved** — origination stays all-or-nothing (`:171-212`); the count hook inside the same tx.
4. **Back-compat** — with one registered silo the behavior equals today's single-pool path (an N=1 identity test).

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/ZipcodeController.t.sol` updated + green: origination routes to the silo
  named by `siloId`; draw/close re-resolve from `r.siloId`; line count increments/decrements; `SiloFull` rolls an
  origination back; `venueOf==0` reverts; N=1 identity vs the pre-change path. The §8.0 RT_ORIGINATION row updated.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02.
- **Unblocks:** CTR-06 (multi-silo deploy can actually route the 29th line); CTR-09 (fee levy lands in the same
  `_origination`/`_draw`/`_close` branches).
