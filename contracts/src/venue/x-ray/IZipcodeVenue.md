# X-Ray — `IZipcodeVenue.sol` (interface, conformance-connected)

> IZipcodeVenue | 24 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(pure interface — no runtime surface; capped only by no external audit)*

Per-contract X-Ray for `contracts/src/venue/IZipcodeVenue.sol`, the **venue-neutral seam** (§4.7) — the interface
the `ZipcodeController` (§4.4) drives every on-chain venue effect through. It is a **pure interface**: no bytecode,
no storage, no guards, no invariants of its own. The meaningful properties are (1) the **venue-neutrality
discipline** it enforces by its type signatures, and (2) **dual-sided conformance** — `EulerVenueAdapter` implements
it and `ZipcodeController` consumes it through the interface type. Both are proven in `EulerVenueAdapter.t.sol` +
`ZipcodeController.t.sol`.

> ⚠️ **An interface has no attack surface of its own.** Nothing here executes; there is nothing to guard, no value to
> move, no state to corrupt. The X-Ray for an interface is about (a) whether the abstraction achieves its design goal
> — keeping the controller venue-agnostic — and (b) whether the one implementation actually conforms and the one
> consumer actually routes through it. Runtime safety lives entirely in the implementation
> ([EulerVenueAdapter.md](EulerVenueAdapter.md)).

## 1. What it is

A 24-nSLOC interface declaring the **entire** controller↔venue boundary: 5 events (`LineOpened`, `LineLimitsSet`,
`LineFunded`, `LineDrawn`, `LineClosed`) + 7 functions (`openLine`, `setLineLimits`, `fund`, `draw`, `observeDebt`,
`closeLine`, `liquidate`). The defining design rule: **only `bytes32` / `address` / `uint*` / an opaque `lineRef`
cross this boundary** — NO Euler types (`IEVault` / `MarketAllocation` / `BatchItem` / EVC / router / `LineAccount`).
One config (Euler) is built today; the interface is what would let a second venue config drop in without touching the
controller (§4.7 #10).

The `lineRef` is deliberately **opaque** (an `address`, happens to be the borrow vault) — the controller treats it as
a handle and never introspects it, so the venue can change what `lineRef` *means* without breaking the controller.

## 2. Surface

| Member | Kind | Notes |
|---|---|---|
| `openLine(lienId, lienToken, collateralAmount) → (lineRef, oracleKey)` | function | mint + wire a line cluster; returns the opaque handle + the price key |
| `setLineLimits(lineRef, borrowLTV, liqLTV, cap)` | function | LTV + borrow cap |
| `fund(lineRef, amount)` | function | reallocate base liquidity into the line |
| `draw(lineRef, amount, receiver)` | function | draw to the off-ramp |
| `observeDebt(lineRef) → uint256` | function (view) | outstanding debt, readable after close |
| `closeLine(lineRef)` | function | close a repaid line |
| `liquidate(lineRef)` | function | defensive stub (always reverts in the impl, §4.4e) |
| `LineOpened` / `LineLimitsSet` / `LineFunded` / `LineDrawn` / `LineClosed` | events | the line-lifecycle log |

Every parameter and return is a primitive or opaque `address` — the venue-neutrality rule holds across all 7
functions and 5 events (no Euler type appears in any signature).

## 3. Properties — with test connection

| ID | Property | Proven by |
|---|---|---|
| P-1 | **conformance** — `EulerVenueAdapter` is assignable to `IZipcodeVenue` (compile-time) | `test_InterfaceImplemented` (`IZipcodeVenue(address(adapter))`) — compiles iff every member is implemented |
| P-2 | **behavioral conformance** — every function + event behaves as specified | the full `EulerVenueAdapter.t.sol` lifecycle suite drives `openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/`closeLine`/`liquidate` and asserts each event (53 fork tests — see [EulerVenueAdapter.md](EulerVenueAdapter.md)) |
| P-3 | **the controller consumes ONLY through the seam** — `ZipcodeController` holds `venue` and calls `IZipcodeVenue(venue_).{openLine,setLineLimits,fund,draw,closeLine}`; no Euler type leaks into the controller | `ZipcodeController.sol:58,240-279` (typed `IZipcodeVenue` calls) + `ZipcodeController.t.sol` |
| P-4 | **venue-neutrality** — no Euler type crosses the boundary; `lineRef` is opaque | structural (the source); the controller never introspects `lineRef` |

## 4. Guards / Invariants

None — a pure interface declares no executable logic. All guards (`onlyController`, `BadReceiver`, the cluster-mint
checks, the queue-reclaim invariants) live in the implementation and are catalogued in
[EulerVenueAdapter.md](EulerVenueAdapter.md). There is no storage, no access control, and no value path here.

## 5. Attack surfaces

- **None intrinsic.** An interface cannot be attacked; it has no runtime presence. The only "interface-level" risk
  classes are design-time: (a) a **leaky abstraction** — an Euler type sneaking into a signature would couple the
  controller to Euler and defeat §4.7; none does. (b) a **conformance drift** — the implementation diverging from the
  declared shape; prevented by Solidity's compile-time `is IZipcodeVenue` check (P-1) and the behavioral suite (P-2).
- **The opaque-`lineRef` discipline is the load-bearing design choice** — because the controller treats `lineRef` as
  a handle and never assumes it is a borrow vault (or anything Euler-specific), a different venue can return a
  different kind of handle. This is what makes the seam genuinely venue-agnostic rather than Euler-shaped-with-an-
  interface-on-top. Verified structurally: `ZipcodeController` only ever passes `lineRef` back to the venue.
- **Senior-surface deliberately excluded** — `IZipcodeVenue` carries no senior-pool getter; that is the venue
  adapter's `seniorPool()` (the one venue-specific getter the registry needs), kept off the line-only interface by
  design (§4.7). Noted here because it is an intentional *omission*, not a gap.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Compile-time conformance | 1 | `test_InterfaceImplemented` |
| Behavioral conformance (via the impl) | 53 | the entire `EulerVenueAdapter.t.sol` fork suite exercises every member |
| Controller-side consumption | via `ZipcodeController.t.sol` | the seam is driven venue-agnostically |
| Interface-only unit tests | 0 | N/A — an interface has nothing to unit-test in isolation |

There is no coverage gap: an interface's only testable properties are conformance (compile-time + behavioral) and
consumption, and all three are present.

## X-Ray Verdict

**ADEQUATE** — a clean, minimal, correctly venue-neutral seam. It declares the whole controller↔venue boundary in
primitives + an opaque `lineRef`, with **no Euler type crossing it**, and it is conformance-proven on both sides:
`EulerVenueAdapter` implements it (compile-time `is IZipcodeVenue` + a 53-test behavioral suite) and `ZipcodeController`
consumes it through the interface type. As a pure interface it carries no runtime risk — no guards, no storage, no
value path — so there is nothing to harden and no coverage gap; it sits at ADEQUATE (not HARDENED) only by the
project-wide absence of an external audit. The design discipline (opaque handle, senior-surface excluded) is the
notable part, and it is sound.

**Structural facts:**
1. 24 nSLOC; pure interface; 7 functions + 5 events; no bytecode, no storage, no guards.
2. Venue-neutral by construction — only `bytes32`/`address`/`uint*`/opaque `lineRef` cross; no Euler types.
3. Dual-sided conformance: implemented by `EulerVenueAdapter` (P-1/P-2), consumed by `ZipcodeController` through the interface type (P-3).
4. `lineRef` is an opaque handle the controller never introspects — the property that makes the seam genuinely venue-agnostic (§4.7 #10).
5. Senior-pool getter deliberately excluded (it lives on the adapter as `seniorPool()`); runtime safety lives entirely in the implementation ([EulerVenueAdapter.md](EulerVenueAdapter.md)).
