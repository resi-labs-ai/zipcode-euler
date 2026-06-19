# CTR-03 — ZipcodeController: siloId routing over the registry

> Contract-track change (EXPANSION). Makes the controller multi-pool: instead of one hardcoded `venue` pointer it
> resolves the venue per origination from `SiloRegistry` (CTR-02) via a `siloId` carried in the CRE report, and
> records the `siloId` on the lien so draws/closes re-resolve the SAME venue. Adds the slot-count hooks. This is
> the routing half of sequential-fill sharding.
> Spec: `claude-zipcode.md` §4.7 (venue-agnostic) / §8.0 (report envelope) / §17 (Timelock wiring).
> **Open decision A (locked: single controller + registry).**

## Why (the seam)
`ZipcodeController._processReport` dispatches origination/draw/close through ONE mutable `venue`
(`contracts/src/ZipcodeController.sol:51,153-249`). To fill multiple pools the controller must pick which silo a
new line lands in. Decision (session): a **single controller** resolving `venue = registry.venueOf(siloId)` from a
`siloId` in the report — NOT one controller per silo. The CRE composer picks `siloId` (the current fill target);
the registry backstops with a fail-closed slot cap.

## Design decision — registry is MANDATORY (no `venue` fallback). [Critic-driven, this window.]
The first draft kept `venue` as a fallback when `registry == address(0)`. The critic pass (junior-dev #4/#8/#9,
contract-binding #1/#2) showed this dual mode is a silent line-bricking hazard: a line opened while `registry == 0`
(no `incrementLineCount`, `r.siloId == bytes32(0)`) becomes **un-closeable** once a registry is later wired —
`_close` would resolve `venueOf(0) == 0` and/or call `decrementLineCount(0)` which reverts `UnknownSilo(0)`. The
collateral strands behind a revert. There are **zero live lines** (the stack is fork-tested only), so the fallback
buys nothing. **Resolution: the report-driven paths (`_origination`/`_draw`/`_close`) resolve venue EXCLUSIVELY via
the registry and revert `RegistryUnset()` if `registry == address(0)`.** This collapses the state space to one mode
and removes the brick hazard and the decrement-underflow hazard entirely.

`venue` (the state var) + `setVenue` are **RETAINED unchanged** — the constructor still seeds `venue` (so the
existing deploy/test adapter-prediction cycle and `controller.venue() == adapter` assert are untouched), and silo
#0's adapter is expected to equal that seed. `venue` is simply no longer the routing source for report paths.
`registry` starts `address(0)` and is wired post-deploy via `setRegistry` (exactly like the oracle registry's
`setController` is wired post-deploy today, `ZipcodeController.t.sol:236`).

## Deliverable
Modify `contracts/src/ZipcodeController.sol`:
1. Add an inline `ISiloRegistry` interface (mirror the existing inline-interface pattern at `:9-25`), exactly three
   methods — nothing else is needed:
   ```solidity
   interface ISiloRegistry {
       function venueOf(bytes32 siloId) external view returns (address);
       function incrementLineCount(bytes32 siloId) external;
       function decrementLineCount(bytes32 siloId) external;
   }
   ```
2. Add `address public registry;` wiring slot (NOT in the constructor — starts `address(0)`) + `setRegistry(address)`
   (`onlyOwner`, `require(registry_ != address(0)) else ZeroAddress`, `emit WiringSet("registry", registry_)`),
   mirroring the existing setters (`:118-143`).
3. Add two errors: `error RegistryUnset();` and `error SiloUnrouted(bytes32 siloId);`.
4. Add `bytes32 siloId` to `LienRecord` (`:62-66`) — **append after `bool open`** (4 fields: `lien, lineRef, open,
   siloId`). Add `bytes32 siloId` to `LienOriginated` (`:80-87`) — **append as the LAST field** (7 fields). Only
   `LienOriginated` gains it (not `LienDrawn`/`LienReleased`/`LienStatusUpdated`).
5. Add a private resolver used by all three branches:
   ```solidity
   function _venueFor(bytes32 siloId) private view returns (address v) {
       if (registry == address(0)) revert RegistryUnset();
       v = ISiloRegistry(registry).venueOf(siloId);
       if (v == address(0)) revert SiloUnrouted(siloId);
   }
   ```
6. `_origination` (`:173-212`): decode `siloId` as the **LAST** payload field (ABI bump — new tuple
   `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount,
   uint256 cap, bytes32 siloId)`). Resolve `address venue_ = _venueFor(siloId)` (local name — do NOT shadow the
   `venue` state var) and drive `openLine`/`setLineLimits`/`fund`/`draw` through `venue_`. Store
   `siloId` on the record (step-8 `liens` write gains `siloId: siloId`); add `siloId` to the `LienOriginated` emit.
   **After** the step-8 `liens` write + emit, call `ISiloRegistry(registry).incrementLineCount(siloId)` as the
   FINAL statement (fail-closed — a `SiloFull` revert rolls back the whole atomic origination incl. the CREATE2
   deploys; F-10 is preserved because the registry is trusted and makes no callback into the controller — add a
   one-line comment to that effect).
7. `_draw` (`:215-230`): payload UNCHANGED. Resolve `address venue_ = _venueFor(r.siloId)`; drive `fund`/`draw`
   through `venue_`.
8. `_close` (`:233-249`): payload UNCHANGED. Resolve `address venue_ = _venueFor(r.siloId)`; drive
   `observeDebt`/`closeLine` through `venue_`. **After** `closeLine`/`burn`/`r.open = false`/emit, call
   `ISiloRegistry(registry).decrementLineCount(r.siloId)` as the FINAL statement.
9. Keep the single CRE write-entry `_processReport` and the RT_* routing (`:39-44,153-169`) unchanged in shape
   (RT_DEFAULT/RT_LIQUIDATION markers unchanged).

## Spec §
`claude-zipcode.md` §4.7 (the venue seam stays `IZipcodeVenue`; routing is which instance), §8.0 (the RT_ORIGINATION
payload gains a **trailing** `bytes32 siloId`; the §8.0 producer table row for RT_ORIGINATION must be updated;
RT_DRAW/RT_CLOSE rows are unchanged — `siloId` is re-resolved from the stored `r.siloId`, not re-sent), §17.

## Binds to (verified)
- `SiloRegistry.venueOf(bytes32)→address` (`:239-241`), `incrementLineCount(bytes32)` (`:222-226`, `onlyController`,
  reverts `SiloFull` at `MAX_LINES_PER_SILO = 28`), `decrementLineCount(bytes32)` (`:230-234`, `onlyController`,
  reverts `NoLinesToDecrement` at 0). All three confirmed against `contracts/src/SiloRegistry.sol` (CTR-02).
- `SiloRegistry.controller` (`:103`) gates increment/decrement; seeded in the ctor (`:135-137`), re-pointed via
  `setController(address)` (`:262-266`, `onlyOwner`). **The registry's `controller` MUST equal the deployed
  ZipcodeController** (else every origination/close reverts `NotController`) — see Key req 5 + the deploy obligation.
- The as-built controller branches: `_processReport` (`:153-169`), `_origination` decode (`:174-182`), `_draw`
  decode (`:216-217`), `_close` decode (`:234`), setter pattern (`:118-143`), `LienRecord` (`:62-66`),
  `LienOriginated` (`:80-87`). Line citations verified accurate this window.
- `IZipcodeVenue` (`contracts/src/venue/IZipcodeVenue.sol`) — unchanged seam.

## Starting state
- `ZipcodeController` as filed: single `venue`, `LienRecord{lien,lineRef,open}`, RT_ORIGINATION payload has no
  `siloId`, no `registry`. Fork-tested (`contracts/test/ZipcodeController.t.sol`). `SiloRegistry` exists (CTR-02,
  with its own 28-test suite). The controller test currently deploys NO `SiloRegistry` (the `registry` field in
  that test is the `ZipcodeOracleRegistry`).

## Do NOT
- Do NOT change the `IZipcodeVenue` interface — only WHICH instance the controller calls.
- Do NOT change RT_* numerals or the `_processReport` envelope shape; only the RT_ORIGINATION payload gains a
  trailing `siloId` (RT_DRAW/RT_CLOSE payloads are unchanged).
- Do NOT increment the line count before `openLine` succeeds, and do NOT put it before the `liens` write
  (phantom-count leak / F-10).
- Do NOT shadow the `venue` state var with the resolved local (use `venue_`).
- Do NOT reintroduce a `registry == 0` fallback in the report paths (the brick hazard above).
- Do NOT remove the single-controller model in favor of per-silo controllers (decision A locked).
- Do NOT remove the `venue` state var / `setVenue` / the ctor `venue_` arg (keeps the deploy cycle intact).
- Do NOT commit — leave the working tree for the reviewer to commit at Conclude.

## Key requirements
1. **Re-resolve on draw/close from stored `r.siloId`** — NEVER from `currentSilo` or any global pointer, so a
   re-pointed `currentSilo` or a retired silo cannot strand an open line in the wrong venue. (Verified sound:
   `SiloRegistry.venueOf` ignores `active` and `retireSilo` keeps the record — an open line always re-resolves to
   its original adapter and can close even after its silo is retired.)
2. **Fail-closed routing** — `registry == 0` reverts `RegistryUnset`; `venueOf(siloId) == 0` reverts `SiloUnrouted`;
   `incrementLineCount` reverting `SiloFull` rolls the whole atomic origination back (it's the last statement).
3. **Atomicity preserved** — origination stays all-or-nothing; the count hook is inside the same tx, after the
   `liens` write, calling a trusted no-callback registry (no F-10 reentrancy regression).
4. **Back-compat (N=1 identity)** — defined concretely: with ONE registered silo whose `adapter == ` the venue the
   pre-change path used, every observable venue effect is identical. Operationally proven by running the FULL
   existing `ZipcodeController.t.sol` suite routed through the registry (setUp registers `SILO_0 → adapter`, wires
   `controller.setRegistry` + `registry.setController(controller)`), with only the local `LienOriginated` event
   declaration updated to the new 7-field signature. The lien token, lineRef, seed, debt, draw, and close behavior
   are unchanged; identity = "the pre-change assertions still hold verbatim."
5. **Registry control wiring** — the controller's increment/decrement only succeed if `SiloRegistry.controller ==
   address(controller)`. The test setUp MUST call `registry.setController(address(controller))`; the deploy must do
   the same (logged as a deploy obligation in PROGRESS).

## CTR-04 capacity caveat (carry forward — do NOT silently imply full reclaim)
`decrementLineCount` corrects the *registry* counter on close, but the as-built `EulerVenueAdapter.closeLine` frees
only the SUPPLY queue, NOT the binding WITHDRAW-queue slot (`EulerVenueAdapter.sol:415-423`; PROGRESS finding 1).
So until **CTR-04** lands, a pool's true capacity is ~28 *lifetime* opens, not concurrent — the registry decrement
does NOT free the underlying slot. CTR-03 is correct registry accounting and builds standalone, but concurrent
capacity is only fully sound once CTR-03 (this) AND CTR-04 both land. Note this in the contract NatSpec + the wire.

## Done when (gate — `forge test`)
- `forge build` green.
- `contracts/test/ZipcodeController.t.sol` updated + green:
  - setUp deploys + wires the registry (`SILO_0 → adapter`, `setRegistry`, `setController`); the `_origReport`
    helper appends `siloId`; the local `LienOriginated` event declaration is bumped to 7 fields.
  - The full pre-existing suite passes through routing (N=1 identity, Key req 4).
  - New tests: (a) origination routes to the venue named by `siloId`; (b) draw/close re-resolve from `r.siloId`
    (incl. a test that an open line still closes after its silo's `currentSilo`/active state changes — proving
    `r.siloId` not `currentSilo` is used); (c) line count increments on origination + decrements on close
    (assert via the registry's count/`getSilo`); (d) `SiloFull` rolls an origination fully back (`_assertNoOrphan`);
    (e) `venueOf(unknownSilo) == 0` reverts `SiloUnrouted`; (f) `registry == 0` reverts `RegistryUnset`.
  - At least ONE integration test against the REAL `SiloRegistry` (deploy it + minimal self-consistent topology
    stubs so `addSilo`'s 6-clause assert passes — adapter is the real one, `adapter.eulerEarn() == ee`; stub
    freeze/escrow/coordinator getters return the wired addresses), registering `SILO_0 → adapter` and originating
    + closing through it — proving the real binding resolves (venueOf/increment/decrement). The remaining
    routing/branch tests MAY use a 3-method `MockSiloRegistry` for isolation (the real registry's admission/topology
    is already exhaustively covered by `SiloRegistry.t.sol`).
- The §8.0 RT_ORIGINATION row updated (trailing `siloId`); the `WOOF-05` wire (`docs/wires/`) updated for the new
  `registry` slot + `LienRecord.siloId` + `LienOriginated` field + the routing behavior + the CTR-04 caveat.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02 (done).
- **Unblocks:** CTR-06 (multi-silo deploy can actually route the cross-silo 29th line); CTR-09 (fee levy lands in
  the same `_origination`/`_draw`/`_close` branches). Pairs with CTR-04 (concurrent-capacity soundness — see caveat).
- **Deploy obligation (log in PROGRESS):** the deploy/wiring must call `registry.setRegistry`-side wiring —
  `controller.setRegistry(siloRegistry)` AND `siloRegistry.setController(controller)` — before the first
  origination, and assert `siloRegistry.controller() == address(controller)` post-deploy (symmetric to the existing
  `oracleRegistry.setController` step).
