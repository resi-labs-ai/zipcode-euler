# SiloRegistry — the multi-pool / federation silo catalog + admission gate (wiring map)

> Source of truth = the kept code at `contracts/src/SiloRegistry.sol` + its test
> `contracts/test/SiloRegistry.t.sol`. Ticket `build/tickets/contracts/CTR-02-silo-registry.md` is intent —
> the code is final. First contract of the credit-warehouse scaling + federation workstream (CTR-02..10).
> Spec §4.5 / §4.7 / §17. (PROGRESS "Credit-warehouse scaling + federation substrate" section.)

## Role
The catalog that lets the protocol run **N pools** under ONE mutualized senior zipUSD. Each entry is a "silo" —
the set `{venue adapter + warehouse Safe + EulerEarn pool + junior tranche}` plus its loss-side
(escrow + DefaultCoordinator + SzipNavOracle) and freeze (DurationFreezeModule) components. EulerEarn caps a
pool at `MAX_QUEUE_LENGTH = 30` markets (`reference/euler-earn/src/libraries/ConstantsLib.sol:17`, enforced on
the binding withdraw queue at `EulerEarn.sol:785`); with 2 permanent non-line markets per pool (resting USDC +
reservoir vault) → 28 lines/pool. To exceed that the protocol shards across pools; to keep one senior zipUSD
those pools must be enumerated, admitted under a uniform gate, and slot-counted. This is that registry.

It is a **pure catalog**: it touches NO silo-internal contract; silo logic is unchanged. A plain OZ `Ownable`
(v5) whose owner is the Timelock — the `EulerVenueAdapter`/`DefaultCoordinator` build-phase idiom, NOT a Zodiac
module, NOT an EVK hook. Admission (`addSilo`, `onlyOwner`/Timelock) is the federation's underwriting gate: a
curator gets senior backing only by registering a SELF-CONSISTENT silo.

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `SiloRegistry` (`is Ownable`) | The catalog. `addSilo` (admission + the 6-clause topology assert), `retireSilo`/`setActive`/`setCurrentSilo` (governed lifecycle), `incrementLineCount`/`decrementLineCount` (`onlyController` slot accounting, cap `MAX_LINES_PER_SILO = 28`), views (`venueOf`/`getSilo`/`allSiloIds`/`siloCount`), Timelock-settable `controller` wiring (`setController` + `WiringSet`). |
| `IFreeze` / `IEscrow` / `INavWriter` / `ISeniorVenue` (local interfaces in the same file) | Minimal `address`-returning getters the admission assert dereferences: `DurationFreezeModule.{eulerEarn,warehouse,navOracle}()`, `LienXAlphaEscrow.coordinator()`, `DefaultCoordinator.navOracle()`, and the venue-neutral `ISeniorVenue.seniorPool()` (CTR-10b — replaced the Euler-specific `IAdapter.eulerEarn()`; `EulerVenueAdapter.seniorPool()` returns `address(eulerEarn)`, a non-Euler adapter returns its own `ISeniorPool` surface). The GPL silo contracts are not imported; the `ISzipNavOracle`/`IEulerEarn`-typed returns are read as `address` for comparison. |

## Wiring — internal
- **`constructor(address controller_)` / `Ownable(msg.sender)`.** Seeds the `controller` slot (may be re-pointed
  once CTR-03's controller is deployed — the registry is deployed BEFORE its controller, so the constructor does
  NOT zero-check `controller_`; `setController` enforces non-zero on re-point) and the deployer as initial owner
  (transferred to the Timelock at deploy).
- **`addSilo(bytes32 siloId, SiloConfig calldata cfg)`** — `onlyOwner`. Reverts: `ZeroSiloId` (`bytes32(0)` is the
  reserved `currentSilo` "unset" sentinel — never a real id), `DuplicateSilo` (an entry already exists, detected
  via `silos[siloId].adapter != 0`), `ZeroAddress` on ANY zero address among the 9 `cfg` fields, or `SiloMiswired`
  on a failed topology assert. On success writes a `Silo` with `cfg`'s addresses + `lineCount = 0` + `active =
  true` (the registry SEEDS these — they are NEVER caller-supplied, a caller-seeded count being a capacity-desync
  footgun), appends `siloId` to `siloIds`, and adopts it as `currentSilo` iff none is set.
- **The topology assert (load-bearing) — the exact 6-clause web.** All must hold:
  1. `IFreeze(cfg.freeze).eulerEarn()  == cfg.eePool`
  2. `IFreeze(cfg.freeze).warehouseSafe()  == cfg.warehouseSafe`
  3. `IFreeze(cfg.freeze).navOracle()  == cfg.navOracle`
  4. `IEscrow(cfg.escrow).coordinator() == cfg.defaultCoordinator`
  5. `INavWriter(cfg.defaultCoordinator).navOracle() == cfg.navOracle`
  6. `ISeniorVenue(cfg.adapter).seniorPool() == cfg.eePool`  *(CTR-10b: venue-neutral — was `IAdapter.eulerEarn()`)*
  This transitively binds adapter ↔ eePool ↔ freeze ↔ warehouseSafe ↔ navOracle ↔ defaultCoordinator ↔ escrow, so
  a silo pointing at a sibling's pool/safe/oracle/coordinator cannot be admitted (it cannot slash a sibling or skew
  the aggregate). **`eePool` is the silo's `ISeniorPool` senior-read SURFACE** (CTR-10b): the EE pool for an Euler
  silo, a venue pool / thin `ISeniorPool` wrapper for a non-Euler silo. Clauses 1 + 6 compare both the freeze's and
  the adapter's senior getter to it, so the gate is venue-agnostic — a non-Euler venue plugs in (its adapter
  exposing `seniorPool()`) with NO registry change; see the contract NatSpec "VENUE-AGNOSTIC ADMISSION" recipe.
  `curator` and `juniorBasket` are carried for routing/aggregation only — NOT topology-asserted
  (no getter to cross-check; only the non-zero-address check applies). The standalone `WarehouseAdminModule` assert
  the draft ticket proposed was DROPPED: `freeze.warehouseSafe()`/`freeze.eulerEarn()` already pin `warehouseSafe`/
  `eePool`, so a `WarehouseAdminModule` address field would be redundant for self-consistency.
- **`retireSilo` / `setActive` / `setCurrentSilo`** — all `onlyOwner`, all `UnknownSilo`-guarded. `retireSilo` sets
  `active = false` (existing lines close normally, no new routing) and NEVER deletes the record (the book must stay
  readable through close); if the retired silo was `currentSilo`, it clears the sentinel to `bytes32(0)`, forcing
  an explicit `setCurrentSilo` to a live silo before the next origination. `setCurrentSilo` reverts `SiloInactive`
  on a retired target (the registry never auto-rollovers — explicit + governed).
- **`incrementLineCount` / `decrementLineCount`** — `onlyController`, `UnknownSilo`-guarded. Increment reverts
  `SiloFull` at `MAX_LINES_PER_SILO`; decrement reverts `NoLinesToDecrement` on a zero count (double-decrement
  leak guard). The controller (CTR-03) calls increment as the LAST write after a successful `openLine` so a
  reverted origination leaks no phantom count.

## Wiring — cross-component (who points at whom)
- **← `ZipcodeController`** (the `controller`, wired by CTR-03). The ONLY caller of `incrementLineCount` /
  `decrementLineCount`, and the reader of `venueOf(currentSilo)` to route an origination's `openLine`. Today the
  controller still holds a single `address public venue` (`ZipcodeController.sol:51`); CTR-03 swaps that for a
  registry lookup.
- **→ each silo's components (read-only, at admission only).** `addSilo` dereferences the freeze / escrow /
  defaultCoordinator / adapter getters once, to verify self-consistency; it stores plain addresses and never calls
  them again. No write path into any silo contract.
- **← `SeniorNavAggregator`** (CTR-05, BUILT 2026-06-18) reads `allSiloIds()` → `getSilo(id).{eePool,warehouseSafe,
  active}` to sum senior par-backing across silos (`seniorBacking` sums ALL silos; `activeSeniorBacking` filters on
  `active`). The struct getter is the canonical read; no per-field getters owed. See `CTR-05-SeniorNavAggregator.md`.
- **← `SiloDeployer`** (CTR-06) calls `addSilo` after stamping a fresh silo.

## Item-10 / deploy facts
- **Deploy order.** Deploy `SiloRegistry` with `controller_` = the controller (or a placeholder, then
  `setController` once CTR-03's controller exists); transfer `owner` to the Timelock. Register the genesis silo
  (configuration one) via `addSilo` — it becomes `currentSilo` automatically.
- **`MAX_LINES_PER_SILO = 28`** is a compile-time constant derived `30 − resting-USDC market (1) − reservoir vault
  (1)`. CTR-07's split-slot decision keeps it at 28.
- **Non-commingling assert is NOT here.** The §11 `redemptionBox != juniorSafe` / `warehouseSafe != juniorSafe`
  non-commingling check is a deploy-time obligation owed to the **SiloDeployer (CTR-06)**, not the registry — the
  registry's struct carries `warehouseSafe`/`juniorBasket`/`escrow` but no `redemptionBox`. CTR-02 neither discharges
  nor contradicts it.

## Gotchas
- **Slot accounting is concurrent, but the binding EulerEarn cap is LIFETIME until CTR-04 (load-bearing).**
  `lineCount` is a CONCURRENT-line counter, and `decrementLineCount` frees a *registry* slot. But the as-built
  `EulerVenueAdapter.closeLine` (`:415-423`) rebuilds only the SUPPLY queue — it never sets the line's cap to 0,
  never calls `submitMarketRemoval`/`updateWithdrawQueue`, so the binding WITHDRAW-queue slot is NEVER freed. A
  pool therefore bricks at ~28 *lifetime* opens inside `acceptCap` (`EulerVenueAdapter.sol:236`) — BEFORE this
  registry's `SiloFull` would ever trip, and the registry's healthy-looking `lineCount` would never trigger
  `currentSilo` rollover. The registry builds + tests standalone (it is a leaf), but the concurrent-capacity model
  is only fully SOUND once CTR-03 wires increment/decrement AND **CTR-04** makes `closeLine` reclaim the
  withdraw-queue slot (cap→0 + `submitMarketRemoval` + timelock). Do not read `decrementLineCount` as freeing a
  real EulerEarn slot today. (PROGRESS finding 1.)
- **`bytes32(0)` is a reserved siloId**, not a usable key — `addSilo` rejects it so the `currentSilo` "unset"
  sentinel can never collide with a real silo.
- **Caller cannot seed `lineCount`/`active`.** Admission takes `SiloConfig` (addresses only); the storage `Silo`
  struct's `lineCount`/`active` are registry-initialized. A `Silo`-shaped admission input would let a deployer seed
  a non-zero count or admit an inactive silo.
