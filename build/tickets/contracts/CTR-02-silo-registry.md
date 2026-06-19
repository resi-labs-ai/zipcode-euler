# CTR-02 — SiloRegistry: the multi-pool/federation silo set + admission gate

> Contract-track change (the on-chain stack is being EXPANDED). First ticket of the **credit-warehouse scaling +
> federation** workstream. It introduces the registry that lets the protocol run **N pools** under one senior
> zipUSD, each pool a "silo" of `{venue adapter + warehouse + EulerEarn pool + junior tranche}`. No silo logic
> changes — this is purely the catalog + admission gate + slot accounting that the controller (CTR-03), the NAV
> aggregator (CTR-05), and the deployer (CTR-06) read.
> Spec: `claude-zipcode.md` §4.5 (warehouse custody) / §4.7 (venue-agnostic, Euler = config one) / §17
> (Timelock-settable wiring) — those §§ are retired to `build/wires/`; the as-built getters in "Binds to" are the
> real truth. **Spec extension owed (forward, NOT a precondition):** a federation-substrate § — a Conclude-step
> doc-sync to *reflect* this design once built (per PROGRESS "Spec sync (forward)"). Nothing is owed to the spec
> before this builds.

## Why (the seam this opens)
EulerEarn caps a pool at `MAX_QUEUE_LENGTH = 30` markets (`reference/euler-earn/src/libraries/ConstantsLib.sol:17`,
enforced on the binding withdraw queue at `reference/euler-earn/src/EulerEarn.sol:785`). With 2 permanent non-line
markets per pool (resting USDC + reservoir vault, `contracts/script/DeployLocal.s.sol:138-141`), one pool holds
**28 concurrent lines**. To exceed that the protocol runs multiple pools; to keep ONE mutualized senior zipUSD
those pools must be enumerated, admitted under a uniform gate, and slot-counted. Nothing enumerates them today —
`ZipcodeController` holds a single `venue` pointer (`contracts/src/ZipcodeController.sol:51`).

## Deliverable
A new `contracts/src/SiloRegistry.sol` — a plain OZ `Ownable` (v5; `Ownable(msg.sender)` then owner transferred to
the Timelock at deploy, the `EulerVenueAdapter`/`DefaultCoordinator` idiom — NOT a Zodiac module, NOT an EVK hook)
catalog:

- The stored record (storage-only; `lineCount`/`active` are registry-managed, never caller-supplied):
  ```solidity
  struct Silo {
      address adapter;             // EulerVenueAdapter (the IZipcodeVenue seam — what venueOf returns)
      address warehouseSafe;       // CreditWarehouse Safe (EE-share + USDC custodian)
      address eePool;              // EulerEarn senior pool
      address juniorBasket;        // junior tranche / NAV basket (routing+aggregation only; NOT topology-asserted)
      address escrow;              // LienXAlphaEscrow (first-loss bond custody)
      address defaultCoordinator;  // DefaultCoordinator (loss orchestrator; escrow.coordinator + navOracle writer)
      address navOracle;           // SzipNavOracle
      address freeze;              // DurationFreezeModule (per-silo coverage floor)
      address curator;             // the silo's curator (routing/labeling only; NOT topology-asserted)
      uint16  lineCount;           // registry-managed concurrent-line counter (starts 0)
      bool    active;              // registry-managed (starts true; flipped by setActive/retireSilo)
  }
  ```
- The admission input (an all-address view — the caller cannot seed `lineCount`/`active`):
  ```solidity
  struct SiloConfig {
      address adapter; address warehouseSafe; address eePool; address juniorBasket; address escrow;
      address defaultCoordinator; address navOracle; address freeze; address curator;
  }
  ```
- `mapping(bytes32 siloId => Silo) public silos;` + `bytes32[] public siloIds;` + `bytes32 public currentSilo`
  (the active fill target for new originations).
- `addSilo(bytes32 siloId, SiloConfig calldata cfg)` — `onlyOwner` (Timelock). Reverts on: `siloId == bytes32(0)`
  (zero is the reserved "unset" sentinel for `currentSilo` — see Key req 3), a duplicate id (a silo already exists
  at `siloId`), **any zero ADDRESS in `cfg`**, or a failed topology assert (Key req 2). On success writes a `Silo`
  with `cfg`'s addresses + `lineCount = 0` + `active = true`; appends `siloId` to `siloIds`; if `currentSilo ==
  bytes32(0)`, sets `currentSilo = siloId`.
- `retireSilo(bytes32 siloId)` — `onlyOwner`. Sets `active = false`; existing lines close normally, no new routing.
  Never deletes the record (the book must stay readable through close). If `siloId == currentSilo`, also clears
  `currentSilo = bytes32(0)` (forces an explicit `setCurrentSilo` to a live silo before the next origination).
- `setActive(bytes32 siloId, bool active_)` — `onlyOwner`. Flips `active`.
- `setCurrentSilo(bytes32 siloId)` — `onlyOwner`. The rollover lever (called when the active silo hits the cap).
  Reverts if the target is unknown or `!active`.
- `incrementLineCount(bytes32 siloId)` / `decrementLineCount(bytes32 siloId)` — `onlyController`. Increment reverts
  `SiloFull` at `MAX_LINES_PER_SILO` (a `uint16` constant = 28, with a doc comment deriving it: `MAX_QUEUE_LENGTH
  (30) − resting-USDC market (1) − reservoir vault (1)`; CTR-07's split-slot decision keeps it at 28). Decrement
  reverts on an already-zero count (`NoLinesToDecrement` — guards a double-decrement leak).
- views: `venueOf(bytes32) returns (address)` (returns `silos[siloId].adapter` — the controller routes `openLine`
  through this `IZipcodeVenue` seam), `getSilo(bytes32) returns (Silo memory)`, `allSiloIds() returns (bytes32[]
  memory)`, `siloCount() returns (uint256)`. CTR-05 reads `{eePool,warehouseSafe}` via `getSilo(...)` over
  `allSiloIds()` — no dedicated per-field getters owed (the struct getter is the canonical read).
- the build-phase wiring idiom: a Timelock `owner`, a `controller` slot with `setController` (`onlyOwner`,
  zero-revert), and a `WiringSet(bytes32 slot, address value)` event (emit on `setController` with slot
  `"controller"`, mirroring `EulerVenueAdapter`). Constructor takes `controller_` (may be re-pointed once CTR-03's
  controller is deployed) and seeds `Ownable(msg.sender)`.

## Spec §
`claude-zipcode.md` §4.5/§4.7/§17. The admission gate operationalizes the session decision "new curator = new
junior pool" — a curator gets senior backing only by registering a self-consistent silo.

## Binds to (verified — every getter read from as-built source)
- The build-phase Timelock-wiring idiom to mirror: `contracts/src/venue/EulerVenueAdapter.sol:115-185`
  (`onlyOwner` setters + `WiringSet(bytes32,address)`, OZ `Ownable(msg.sender)` at `:102`). OZ is v5
  (`Ownable(address initialOwner)`). This contract is NOT an EVK hook, so OZ `Ownable` is correct.
- Topology getters the assert dereferences (all verified public, address-typed):
  - `EulerVenueAdapter.eulerEarn()` (`contracts/src/venue/EulerVenueAdapter.sol:39`, `IEulerEarn public eulerEarn`)
  - `DurationFreezeModule.{eulerEarn(), warehouse(), navOracle()}`
    (`contracts/src/supply/szipUSD/DurationFreezeModule.sol:54,56,57`)
  - `LienXAlphaEscrow.coordinator()` (`contracts/src/loss/LienXAlphaEscrow.sol:60`)
  - `DefaultCoordinator.navOracle()` (`contracts/src/loss/DefaultCoordinator.sol:90`, `ISzipNavOracle public navOracle`)
  - Define minimal local `interface`s in `SiloRegistry.sol` for these four getters (or reuse existing interfaces if
    convenient); each returns `address` (cast `ISzipNavOracle`/`IEulerEarn` returns to `address` for comparison).
- `ZipcodeController` is the only `incrementLineCount`/`decrementLineCount` caller (CTR-03 wires it). Today the
  controller holds a single `address public venue` (`contracts/src/ZipcodeController.sol:51`).

## Starting state
- No registry exists. `ZipcodeController.venue` is a single pointer. `EulerEarnFactory.createEulerEarn` already
  stamps independent pools (`reference/euler-earn/src/EulerEarnFactory.sol:90-113`); roles can be shared across
  pools but each pool is independent.

## Do NOT
- Do NOT make `addSilo` permissionless — admission is the federation's underwriting gate (`onlyOwner`/Timelock).
- Do NOT accept `lineCount`/`active` as admission inputs — they are registry-managed (caller-supplied values are a
  capacity-desync footgun). Admission takes `SiloConfig` (addresses only); the registry seeds `lineCount=0`/`active=true`.
- Do NOT touch any silo-internal contract — this is a pure catalog; silo logic is unchanged.
- Do NOT delete a retired silo's record (its lines must stay observable through close).
- Do NOT add a topology assert for `curator` or `juniorBasket` — they are carried for routing/aggregation only (no
  getter to cross-check; only the non-zero-address check applies).
- Do NOT add a standalone `WarehouseAdminModule` field/assert — `freeze.warehouse()`/`freeze.eulerEarn()` already
  pin `warehouseSafe`/`eePool`, so the WarehouseAdminModule address is redundant for self-consistency.
- Do NOT hardcode the resting/reservoir count into `MAX_LINES_PER_SILO` without the deriving doc comment (`30 − 2`).

## Key requirements
1. **Slot accounting is fail-closed.** `incrementLineCount` reverts `SiloFull` at the cap; the controller calls it
   as the LAST write after a successful `openLine` (CTR-03) so a reverted origination leaks no phantom count.
   `decrementLineCount` reverts `NoLinesToDecrement` on a zero count.
   **Sequencing note (back-pressure, see PROGRESS finding 1 / CTR-04):** `lineCount` is a *concurrent*-line counter,
   but the as-built `EulerVenueAdapter.closeLine` (`:415-423`) frees only the SUPPLY queue — it does NOT free the
   binding WITHDRAW-queue slot, so a pool bricks at ~28 *lifetime* opens inside `acceptCap` (`:236`) BEFORE the
   registry's `SiloFull` would ever trip. The registry's decrement is correct accounting and builds standalone, but
   the *concurrent*-capacity model is only fully sound once **CTR-03** wires increment/decrement AND **CTR-04** makes
   `closeLine` actually reclaim the withdraw-queue slot. CTR-02 itself is a leaf (it depends on no other ticket to
   compile + test); this note records the cross-ticket capacity dependency so no one reads `decrementLineCount` as
   freeing a real EulerEarn slot today.
2. **Admission topology assert (load-bearing).** `addSilo` reverts `SiloMiswired()` unless the silo is
   self-consistent and points only at its OWN components. The exact assert web (all clauses must hold), using the
   verified getters:
   1. `IFreeze(cfg.freeze).eulerEarn()  == cfg.eePool`
   2. `IFreeze(cfg.freeze).warehouse()  == cfg.warehouseSafe`
   3. `IFreeze(cfg.freeze).navOracle()  == cfg.navOracle`
   4. `IEscrow(cfg.escrow).coordinator() == cfg.defaultCoordinator`
   5. `INavWriter(cfg.defaultCoordinator).navOracle() == cfg.navOracle`
   6. `IAdapter(cfg.adapter).eulerEarn() == cfg.eePool`
   This web transitively binds adapter↔eePool↔freeze↔warehouseSafe↔navOracle↔coordinator↔escrow, so a mis-wired
   silo (one pointing at a sibling's pool/safe/oracle/coordinator) cannot be admitted (it cannot slash a sibling or
   skew the aggregate). Cast each interface return to `address` for the comparison.
3. **`currentSilo` rollover + the zero sentinel.** `bytes32(0)` is the reserved "no current silo" sentinel:
   `addSilo` reverts on `siloId == bytes32(0)`; the first admitted silo becomes `currentSilo`; new originations
   route to `currentSilo`; when it fills, the Timelock calls `setCurrentSilo(next)` (the registry never
   auto-rollovers — explicit + governed). `retireSilo(currentSilo)` clears `currentSilo` back to `bytes32(0)`.
4. **Timelock-settable wiring (§17)** — `owner` = Timelock, `controller` re-pointable via `setController`,
   `WiringSet` events.

## Done when (gate — `forge test`, contract track)
- `forge build` green; a new `contracts/test/SiloRegistry.t.sol` green, covering:
  - `addSilo` happy-path (a self-consistent silo admits; `lineCount==0`, `active==true`, `currentSilo` set on first);
  - `siloId == bytes32(0)` reverts;
  - duplicate-id reverts;
  - any zero-address `cfg` field reverts;
  - topology-assert reverts (`SiloMiswired`) on a deliberately mis-wired silo (e.g. `freeze.eulerEarn != eePool`,
    or `escrow.coordinator != defaultCoordinator`) — exercise at least two distinct broken clauses;
  - `incrementLineCount` to the cap then `SiloFull`; `decrementLineCount` frees a *registry* slot (the registry's
    own count), and reverts `NoLinesToDecrement` on a zero count;
  - `onlyController` (increment/decrement) and `onlyOwner` (addSilo/retireSilo/setActive/setCurrentSilo/setController)
    gating (revert for a non-authorized caller);
  - `retireSilo` stops routing (`active==false`, clears `currentSilo` if it was current) but keeps the record
    readable via `getSilo`.
  - Use mock contracts (or thin stubs exposing the four getters) to drive the topology assert deterministically.
- A cold-build subagent implements from this ticket with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** nothing to compile + test (leaf). *Capacity-soundness* depends on CTR-03 (wires increment/decrement)
  + CTR-04 (close frees the real withdraw-queue slot) — see Key req 1 sequencing note.
- **Unblocks:** CTR-03 (controller routing reads `venueOf`/line-count), CTR-05 (aggregator loops `siloIds` →
  `getSilo`), CTR-06 (deployer calls `addSilo`).
