# CTR-02 — SiloRegistry: the multi-pool/federation silo set + admission gate

> Contract-track change (the on-chain stack is being EXPANDED). First ticket of the **credit-warehouse scaling +
> federation** workstream. It introduces the registry that lets the protocol run **N pools** under one senior
> zipUSD, each pool a "silo" of `{venue adapter + warehouse + EulerEarn pool + junior tranche}`. No silo logic
> changes — this is purely the catalog + admission gate + slot accounting that the controller (CTR-03), the NAV
> aggregator (CTR-05), and the deployer (CTR-06) read.
> Spec: `claude-zipcode.md` §4.5 (warehouse custody) / §4.7 (venue-agnostic, Euler = config one) / §17
> (Timelock-settable wiring). **Spec extension owed**: a federation-substrate § (logged in PROGRESS) — author it
> before this builds if the harness flow flags a spec gap.

## Why (the seam this opens)
EulerEarn caps a pool at `MAX_QUEUE_LENGTH = 30` markets (`reference/euler-earn/src/libraries/ConstantsLib.sol:17`,
enforced on the binding withdraw queue at `reference/euler-earn/src/EulerEarn.sol:785`). With 2 permanent non-line
markets per pool (resting USDC + reservoir vault, `contracts/script/DeployLocal.s.sol:138-141`), one pool holds
**28 concurrent lines**. To exceed that the protocol runs multiple pools; to keep ONE mutualized senior zipUSD
those pools must be enumerated, admitted under a uniform gate, and slot-counted. Nothing enumerates them today —
`ZipcodeController` holds a single `venue` pointer (`contracts/src/ZipcodeController.sol:51`).

## Deliverable
A new `contracts/src/SiloRegistry.sol` — a plain `Ownable`-style (build-phase Timelock-admin idiom, NOT a Zodiac
module) catalog:
- `struct Silo { address adapter; address warehouseSafe; address eePool; address juniorBasket; address escrow;
  address navOracle; address curator; uint16 lineCount; bool active; }`
- `mapping(bytes32 siloId => Silo) public silos;` + `bytes32[] public siloIds;` + `bytes32 public currentSilo`
  (the active fill target for new originations).
- `addSilo(bytes32 siloId, Silo calldata s)` — `onlyOwner` (Timelock). Reverts on a dup id, any zero field, or a
  failed topology assert (Key req 2). Appends to `siloIds`; if `currentSilo == 0`, sets it.
- `retireSilo(bytes32 siloId)` / `setActive(bytes32, bool)` — `onlyOwner`. Flips `active`; existing lines close
  normally, no new routing. `retireSilo` never deletes (book must stay readable).
- `setCurrentSilo(bytes32 siloId)` — `onlyOwner`. The rollover lever (called when the active silo hits the cap).
- `incrementLineCount(bytes32 siloId)` / `decrementLineCount(bytes32 siloId)` — `onlyController`. Increment
  reverts `SiloFull` at `MAX_LINES_PER_SILO` (a constant = 28, documented as `30 − resting − reservoir`).
- views: `venueOf(bytes32) returns (address)`, `getSilo(bytes32) returns (Silo memory)`, `allSiloIds()`,
  `siloCount()`, plus `{eePool,warehouseSafe}` getters the aggregator (CTR-05) loops.
- the build-phase wiring idiom: a Timelock `owner`, a `controller` slot with `setController` (`onlyOwner`), and
  `WiringSet(bytes32 slot, address value)` events.

## Spec §
`claude-zipcode.md` §4.5/§4.7/§17. The admission gate operationalizes the session decision "new curator = new
junior pool" — a curator gets senior backing only by registering a self-consistent silo.

## Binds to (verified)
- The build-phase Timelock-wiring idiom to mirror: `contracts/src/venue/EulerVenueAdapter.sol:115-185`
  (`onlyOwner` setters + `WiringSet`) and `contracts/src/CREGatingHook.sol:46-98` (the non-Ownable raw-`msg.sender`
  admin pattern — use whichever matches; this contract is NOT an EVK hook so OZ `Ownable` is fine).
- Topology getters to assert against (all public): `DefaultCoordinator.navOracle()`, `LienXAlphaEscrow.coordinator()`
  (`contracts/src/loss/LienXAlphaEscrow.sol:60`), `DurationFreezeModule.{eulerEarn,warehouse,navOracle}()`
  (`contracts/src/supply/szipUSD/DurationFreezeModule.sol:50-58`), `WarehouseAdminModule.{eePool,safe,repaySink}()`
  (`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol:49-55`).
- `ZipcodeController` is the only `incrementLineCount` caller (CTR-03 wires it).

## Starting state
- No registry exists. `ZipcodeController.venue` is a single pointer. `EulerEarnFactory.createEulerEarn` already
  stamps independent pools (`reference/euler-earn/src/EulerEarnFactory.sol:90-113`); roles can be shared across
  pools but each pool is independent.

## Do NOT
- Do NOT make `addSilo` permissionless — admission is the federation's underwriting gate (`onlyOwner`/Timelock).
- Do NOT touch any silo-internal contract — this is a pure catalog; silo logic is unchanged.
- Do NOT delete a retired silo's record (its lines must stay observable through close).
- Do NOT hardcode the resting/reservoir count into `MAX_LINES_PER_SILO` without a doc comment deriving it
  (`30 − 2`); CTR-07's split-slot decision keeps it at 28.

## Key requirements
1. **Slot accounting is fail-closed.** `incrementLineCount` reverts `SiloFull` at the cap; the controller calls it
   as the LAST write after a successful `openLine` (CTR-03) so a reverted origination leaks no phantom count.
2. **Admission topology assert (load-bearing).** `addSilo` verifies the silo is self-consistent and points only at
   its OWN components: `escrow.coordinator() == s.defaultCoordinator`-equivalent wiring,
   `freeze.{eulerEarn==s.eePool, warehouse==s.warehouseSafe, navOracle==s.navOracle}`,
   `WarehouseAdminModule.{eePool==s.eePool, safe==s.warehouseSafe}`. A mis-wired silo cannot be admitted (so it
   cannot slash a sibling or skew the aggregate). (Confirm the exact field set against the as-built getters.)
3. **`currentSilo` rollover.** New originations route to `currentSilo`; when it fills, the Timelock calls
   `setCurrentSilo(next)`. The registry does not auto-rollover (keep it explicit + governed).
4. **Timelock-settable wiring (§17)** — `owner` = Timelock, `controller` re-pointable, `WiringSet` events.

## Done when (gate — `forge test`, contract track)
- `forge build` green; a new `contracts/test/SiloRegistry.t.sol` green: addSilo happy-path; dup reverts; zero-field
  reverts; topology-assert reverts on a deliberately mis-wired silo; increment to the cap then `SiloFull`;
  decrement frees a slot; `onlyController`/`onlyOwner` gating; retire stops routing but keeps the record.
- A cold-build subagent implements from this ticket with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** nothing (leaf).
- **Unblocks:** CTR-03 (controller routing reads `venueOf`/line-count), CTR-05 (aggregator loops `siloIds`),
  CTR-06 (deployer calls `addSilo`).
