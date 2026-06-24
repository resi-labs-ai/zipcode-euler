# X-Ray — `SiloRegistry.sol` (single-contract, test-connected)

> SiloRegistry | 150 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo the pre-prod controller re-freeze + no external audit)*

> **Update 2026-06-20:** the I-12/I-13 gaps are **CLOSED** — `test_unknownSilo_reverts_on_all_byId_functions` covers
> the `UnknownSilo` branch on the four previously-untested by-id functions (`retireSilo`/`setActive`/
> `incrementLineCount`/`decrementLineCount`), and `test_setActive_effect_flipsBothWays_andEmits` asserts the flag flip
> both directions + the `SiloActiveSet` event. 30/30 green. Verdict lifted to HARDENED.

Per-contract X-Ray for `contracts/src/SiloRegistry.sol` (CTR-02), the **multi-pool federation catalog + admission
gate + concurrent-line slot accounting** that lets the protocol run N pools under one mutualized senior zipUSD. A
plain OZ `Ownable` (Timelock) — a *pure catalog*: it touches no silo-internal contract. Exercised by
`SiloRegistry.t.sol` — **28 unit tests** (mock topology components).

> The decisive surface is **admission** (`addSilo`, Timelock-gated): a curator gets senior backing only by
> registering a SELF-CONSISTENT silo, proven by a 6-clause **topology web** that asserts the silo's
> freeze/escrow/coordinator/adapter all point only at its OWN pool/safe/oracle. The other load-bearing piece is the
> **registry-managed `lineCount`/`active`** — never caller-supplied (a caller-seeded count is a capacity-desync
> footgun), with the controller bumping `lineCount` as the LAST write after a successful `openLine` so a reverted
> origination leaks no phantom count. The admission gate is also **venue-agnostic** (CTR-10b): it dereferences only
> the venue-neutral `ISeniorVenue.seniorPool()` + `ISeniorPool` slots, so a non-Euler venue plugs in unchanged.

## 1. What it is

A 150-nSLOC `Ownable` catalog. Each silo is `{adapter, warehouseSafe, eePool, juniorBasket, escrow,
defaultCoordinator, navOracle, freeze, curator}` + registry-managed `lineCount`/`active`. Surfaces:

- **`addSilo(siloId, cfg)`** (`onlyOwner`) — `ZeroSiloId` / `DuplicateSilo` / `ZeroAddress` (any of 9 fields) / the 6-clause `SiloMiswired` topology assert; on success seeds `lineCount=0`/`active=true`, appends to `siloIds`, adopts as `currentSilo` if none set.
- **`retireSilo` / `setActive` / `setCurrentSilo`** (`onlyOwner`) — lifecycle: retire stops routing but keeps the record (and clears the sentinel if it was current); `setCurrentSilo` is the governed rollover (rejects unknown/inactive).
- **`incrementLineCount` / `decrementLineCount`** (`onlyController`) — concurrent-line accounting; `SiloFull` at `MAX_LINES_PER_SILO = 28`, `NoLinesToDecrement` at zero.
- **views** — `venueOf`, `getSilo`, `allSiloIds`, `siloCount`; **`setController`** (`onlyOwner`) re-point.

No funds, no custody; writes only catalog state + the `controller` slot.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `addSilo(siloId, cfg)` | `onlyOwner` | the underwriting gate: zero/dup/zero-addr/6-clause topology assert |
| `retireSilo` / `setActive` / `setCurrentSilo` | `onlyOwner` | lifecycle; `setCurrentSilo` rejects unknown/inactive |
| `incrementLineCount` / `decrementLineCount` | `onlyController` | slot accounting; `SiloFull` / `NoLinesToDecrement` |
| `venueOf` / `getSilo` / `allSiloIds` / `siloCount` | public view | catalog reads |
| `setController` | `onlyOwner` | re-point the slot-accounting authority |
| `constructor(controller_)` | deploy | seeds `controller` + Timelock owner |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **6-clause topology web** — `freeze.eulerEarn==eePool`, `freeze.warehouseSafe==warehouseSafe`, `freeze.navOracle==navOracle`, `escrow.coordinator==defaultCoordinator`, `coordinator.navOracle==navOracle`, `adapter.seniorPool==eePool`; any failure → `SiloMiswired` | Yes | **all 6**: `test_addSilo_miswired_{freezeEePool,escrowCoordinator,freezeWarehouse,freezeNavOracle,coordinatorNavOracle,adapterEePool}_reverts` |
| I-2 | **admission guards** — `ZeroSiloId`, `DuplicateSilo`, `ZeroAddress` on each of 9 fields. Uniqueness is per-`siloId` (`DuplicateSilo` keys on `silos[siloId].adapter`, NOT the component set) → one physical pool may be admitted under two `siloId`s with independent `lineCount`s; the cap is per-`siloId`, not per-physical-pool. Per-physical-pool uniqueness is an intentional non-goal (controller-wiring responsibility). | Yes | **`test_addSilo_zeroId_reverts`**, `_duplicate_reverts`, `_zeroAddress_eachField_reverts` (loops all 9) |
| I-3 | **happy admission + currentSilo adoption** — seeds `lineCount=0`/`active=true`, first silo becomes `currentSilo` | Yes | **`test_addSilo_happyPath`**, `_currentSilo_onlyFirst` |
| I-4 | **slot cap** — increment to `MAX_LINES_PER_SILO=28` then `SiloFull` | Yes | **`test_incrementToCap_thenSiloFull`** |
| I-5 | **slot accounting symmetry** — decrement frees a slot; `NoLinesToDecrement` at zero | Yes | **`test_decrement_freesRegistrySlot`**, `_decrement_zeroCount_reverts` |
| I-6 | **slot accounting is `onlyController`** | Yes | **`test_incrementLineCount_onlyController`**, `_decrementLineCount_onlyController` |
| I-7 | **retire stops routing, keeps record, clears sentinel if current.** Note the asymmetry: `setActive(currentSilo, false)` does NOT clear `currentSilo` (only `retireSilo` does) — intentional and benign, since `currentSilo` has no on-chain consumer (advisory rollover hint) and origination routes off the CRE-supplied `siloId` via `venueOf`, never off `currentSilo`. | Yes | **`test_retireSilo_stopsRouting_keepsRecord`**, `_retireSilo_nonCurrent_keepsCurrent` |
| I-8 | **`setCurrentSilo` governed rollover** — rejects unknown / inactive; happy rollover | Yes | **`test_setCurrentSilo_unknown_reverts`**, `_inactive_reverts`, `_rollover` |
| I-9 | **all owner gates** — `addSilo`/`retireSilo`/`setActive`/`setCurrentSilo`/`setController` revert for a non-owner | Yes | **`test_*_onlyOwner`** (5) |
| I-10 | **`setController` re-point + zero-guard** | Yes | **`test_setController_repoints`**, `_zero_reverts` |
| I-11 | **CTR-10b venue-agnostic admission** — the gate dereferences only `ISeniorVenue.seniorPool()` + `ISeniorPool` slots | Yes (structural) | the topology assert uses only venue-neutral getters; the adapter clause is `adapter.seniorPool() == eePool` (proven in `test_addSilo_*` with mocks) |
| I-12 | **`UnknownSilo` on ALL state-mutating-by-id functions** — `retireSilo`/`setActive`/`setCurrentSilo`/`incrementLineCount`/`decrementLineCount` | Yes | **`test_unknownSilo_reverts_on_all_byId_functions`** (the four previously-untested fns, owner + controller paths) + `test_setCurrentSilo_unknown_reverts` |
| I-13 | **`setActive` effect** — the flag flips and is readable (not just the gate) | Yes | **`test_setActive_effect_flipsBothWays_andEmits`** (false→true→false flip + `SiloActiveSet` event) + `test_setActive_onlyOwner` (gate) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `ZeroSiloId` / `DuplicateSilo` / `ZeroAddress` (9 fields) | `addSilo:165-173` | `test_addSilo_{zeroId,duplicate,zeroAddress_eachField}_reverts` |
| `SiloMiswired` (6 clauses) | `addSilo:177-183` | the 6 `test_addSilo_miswired_*` |
| `SiloFull` / `NoLinesToDecrement` | `:242,:250` | `test_incrementToCap_thenSiloFull`, `_decrement_zeroCount_reverts` |
| `NotController` (increment/decrement) | `:148` | `test_{inc,dec}rementLineCount_onlyController` |
| `SiloInactive` (setCurrentSilo) | `:230` | `test_setCurrentSilo_inactive_reverts` |
| `OwnableUnauthorized` (5 owner fns) | OZ | `test_*_onlyOwner` |
| `ZeroAddress` (setController) | `:281` | `test_setController_zero_reverts` |
| `UnknownSilo` (5 fns) | `:210,221,229,241,249` | `test_unknownSilo_reverts_on_all_byId_functions` (4) + `test_setCurrentSilo_unknown_reverts` (1) |

Every revert path, branch, guard, and the `setActive` effect are now exercised — no untested surface.

## 5. Attack surfaces

- **The 6-clause topology web is the underwriting gate — and every clause is individually proven (I-1).** A curator
  can only get senior backing for a self-consistent silo; each of the six cross-references
  (freeze↔pool/safe/oracle, escrow↔coordinator, coordinator↔oracle, adapter↔pool) is negated in its own test, so a
  silo that pointed any component at a *different* pool/safe/oracle is rejected `SiloMiswired`. This is the contract's
  reason to exist and it has the densest coverage.
- **`lineCount`/`active` are registry-managed, never caller-supplied (I-3/I-6).** Admission takes addresses only and
  seeds `lineCount=0`/`active=true`; only the controller mutates the count, fail-closed (the LAST write after a
  successful `openLine`). The cap (`SiloFull` at 28) and the `NoLinesToDecrement` zero-guard prevent both over-fill
  and a double-decrement leak. **Documented cross-ticket caveat:** the as-built `EulerVenueAdapter.closeLine` (post
  CTR-04) reclaims the withdraw-queue slot, but the registry's NatSpec notes the concurrent-capacity model is only
  fully sound with CTR-03 wiring increment/decrement + CTR-04's slot reclaim — a wiring dependency, not a flaw here.
- **Venue-agnostic admission (CTR-10b, I-11).** The gate dereferences only `ISeniorVenue.seniorPool()` and the
  `ISeniorPool` slots, so the registry needs no change for a non-Euler venue — the donation-immunity of a real
  non-Euler senior surface is that venue's own property (cannot be mock-proven here, correctly noted).
- **`UnknownSilo` branch (I-12) — CLOSED.** The guard on all five by-id functions is now exercised:
  `test_unknownSilo_reverts_on_all_byId_functions` covers the four that were untested
  (`incrementLineCount`/`decrementLineCount` via the controller path, `retireSilo`/`setActive` via the owner path),
  alongside the pre-existing `setCurrentSilo` case. `setActive`'s flip effect (both directions + the `SiloActiveSet`
  event) is now directly asserted (I-13), not just via `retireSilo`.
- **No funds, no custody, no pricing.** The registry writes only catalog state + the `controller` slot; the worst an
  outsider can do is read. Build-phase mutable wiring (`controller`, frozen pre-prod) is the subsystem residual —
  `setController` is `onlyOwner` + zero-guarded + tested.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Admission (happy / currentSilo / zero-id / dup / zero-addr) | 5 | `test_addSilo_*` |
| Topology web (6 clauses) | 6 | `test_addSilo_miswired_*` (each clause negated) |
| Slot accounting (cap / decrement / zero / onlyController) | 4 | `test_increment*`, `test_decrement*` |
| Lifecycle (retire / setCurrentSilo / setActive) | 6 | `test_retireSilo_*`, `_setCurrentSilo_*`, `_setActive_onlyOwner` |
| Owner gates + setController | 7 | `test_*_onlyOwner`, `_setController_repoints`/`_zero_reverts` |
| `UnknownSilo` on inc/dec/retire/setActive + `setActive` effect | 2 | `test_unknownSilo_reverts_on_all_byId_functions`, `_setActive_effect_flipsBothWays_andEmits` (added 2026-06-20) |

Coverage % uninstrumentable (project-wide `Stack too deep`); **30 unit tests green**. The admission/topology gate,
slot accounting, every guard branch, and the `setActive` effect are all exercised — no coverage gap.

## X-Ray Verdict

**HARDENED** *(modulo the pre-prod controller re-freeze + no external audit)* — the federation catalog + admission
gate, with its decisive surface (the 6-clause self-consistency topology web, each clause individually negated)
exhaustively proven, alongside the registry-managed slot accounting (cap/`SiloFull`, decrement symmetry,
`onlyController`, fail-closed count), the full silo lifecycle (retire/rollover/active), all owner gates, the CTR-10b
venue-agnostic admission, and — now closed (I-12/I-13) — the `UnknownSilo` branch on all five by-id functions plus
the direct `setActive` flip effect. No code or coverage gap remains; the only residuals are the deferred pre-prod
immutable re-freeze of the build-phase `controller` slot (`onlyOwner` + zero-guarded) and the absence of an external
audit.

**Structural facts:**
1. 150 nSLOC; OZ `Ownable` (Timelock) pure catalog; no funds, no custody; writes catalog state + the `controller` slot.
2. Admission = the 6-clause topology web proving a silo points only at its own components; `lineCount`/`active` registry-managed (never caller-supplied).
3. Slot accounting: `MAX_LINES_PER_SILO=28`, `onlyController` increment (fail-closed, last write) / decrement (`NoLinesToDecrement` guard).
4. CTR-10b venue-agnostic: the gate dereferences only `ISeniorVenue.seniorPool()` + `ISeniorPool` slots — a non-Euler venue plugs in unchanged.
5. Tests: 30 unit (all 6 topology clauses + cap + slot accounting + lifecycle + owner gates + `UnknownSilo` on all 5 by-id fns + `setActive` flip effect). No coverage gap; capped only by the pre-prod re-freeze + no audit.
