# Boot context — SiloRegistry adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md` / `4.md`) before you begin.

## The contract under review
- `contracts/src/SiloRegistry.sol` (150 nSLOC) — CTR-02, the multi-pool / federation **silo catalog +
  admission gate + concurrent-line slot accounting** that lets the protocol run N pools under one mutualized
  senior zipUSD. A plain OZ `Ownable` (v5), owner = the Timelock — **NOT a Zodiac module, NOT an EVC hook**.
  A silo is the set `{adapter, warehouseSafe, eePool, juniorBasket, escrow, defaultCoordinator, navOracle,
  freeze, curator}` + registry-managed `lineCount`/`active`. The surfaces:
  - `addSilo(siloId, cfg)` (`:164`, onlyOwner) — the underwriting gate: `ZeroSiloId` / `DuplicateSilo` /
    `ZeroAddress` (any of 9 cfg fields) / the **6-clause `SiloMiswired` topology web** (`:177-183`); on success
    seeds `lineCount=0` / `active=true`, appends to `siloIds`, adopts as `currentSilo` if none set.
  - `retireSilo` (`:209`) / `setActive` (`:220`) / `setCurrentSilo` (`:228`) (onlyOwner) — the silo lifecycle.
  - `incrementLineCount` (`:240`) / `decrementLineCount` (`:248`) (onlyController) — concurrent-line
    accounting; `SiloFull` at `MAX_LINES_PER_SILO=28`, `NoLinesToDecrement` at zero.
  - views (`venueOf`/`getSilo`/`allSiloIds`/`siloCount`) + `setController` (`:280`, onlyOwner re-point).

**Why it matters:** admission is the federation's underwriting gate — a curator earns senior backing for a
new pool ONLY by registering a SELF-CONSISTENT silo, one whose freeze/escrow/coordinator/adapter all point
ONLY at its OWN pool/safe/oracle (the 6-clause topology web). The other load-bearing piece is that
`lineCount`/`active` are **registry-managed, never caller-supplied** — a caller-seeded count is a
capacity-desync footgun — with the controller bumping the count as the LAST write after a successful
`openLine` so a reverted origination leaks no phantom count. A bug here is a miswired silo slipping the gate
(a silo pointing a component at a *neighbor's* pool/safe/oracle — senior backing for an inconsistent silo), a
slot-count desync (over-fill past 28, an underflow leak, a non-controller moving the count), a lifecycle
hole (a retired silo losing its record and stranding its open lines' close path, or `currentSilo` left
pointing at a retired/inactive silo), or a caller seeding `lineCount`/`active`.

## These are ORIGINAL contracts — the precedent is the §2 topology-assert posture + OZ Ownable
There is no audited parent to diff line-for-line. Your "supposed to be" baselines:
- **OZ `Ownable` (v5)** — `@openzeppelin/contracts/access/Ownable.sol`, an **audited base**. The constructor
  is `Ownable(msg.sender)` (`:153`); every governed setter carries `onlyOwner`. Confirm the gate is the base's
  `onlyOwner` (reverting `OwnableUnauthorizedAccount`), not a re-implemented check, and attack only what this
  contract adds on top.
- **The §2 topology-assert posture** (stated in the contract NatSpec `:45-73`, authoritative): admission is
  the underwriting gate — a curator gets senior backing only by registering a self-consistent silo, proven by
  the 6-clause web (`:177-183`). The strongest finding is a path where a silo points ANY component at a
  DIFFERENT (neighbor's) pool/safe/oracle and the gate admits it, a clause that doesn't bind, a zero field
  passing, or `lineCount`/`active` becoming caller-seeded.
- **The X-Ray is your ground truth** — `contracts/src/x-ray/SiloRegistry.md` (per-contract, authoritative;
  I-1…I-13, the guard table). Every finding cites the invariant/guard it attacks.

## Tests
`contracts/test/SiloRegistry.t.sol` — **30 unit tests** (mock topology components), 0 fuzz, 0 invariant
(deterministic catalog writes). Every revert path, branch, guard, and the `setActive` effect are exercised:
all 6 `test_addSilo_miswired_*` (each topology clause negated), the zero-id / duplicate / per-field
zero-address guards, the slot cap + decrement symmetry + `onlyController`, the full lifecycle
(retire / rollover / active flip), all 5 owner gates + the `setController` re-point, and the `UnknownSilo`
branch on all five by-id functions. See what is proven (don't re-report it) and where the tests STOP (the
build-phase `controller` re-point window; the cross-ticket CTR-04 withdraw-queue caveat noted in NatSpec).

## Ground rules
- Cite exact lines in `SiloRegistry.sol` AND the topology-getter source line where the admission assert
  crosses (`DurationFreezeModule.{eulerEarn,warehouseSafe,navOracle}`, `LienXAlphaEscrow.coordinator()`,
  `DefaultCoordinator.navOracle()`, `EulerVenueAdapter.seniorPool()`).
- **No funds, pure catalog.** The registry touches NO silo-internal contract, holds NO funds, writes ONLY
  catalog state + the `controller` slot. The worst an outsider can do is read. There is no value to drain —
  so frame every finding as a CATALOG-INTEGRITY break (a miswired silo admitted, a slot-count desync, a
  lifecycle record loss, a caller-seeded count/flag), not a theft. A finding that posits a fund movement is
  off-surface.
- **Build-phase residual is INFO.** The build-phase mutable `controller` slot (frozen pre-prod via the
  immutable re-freeze — process, not code) is the documented subsystem residual. A finding that merely
  restates "the Timelock can re-point `controller`" (or any `onlyOwner` re-point) is INFO unless you show a
  re-point that breaks an ON-CHAIN invariant — and `controller` re-point's only effect is changing who may
  move the count, an `onlyOwner` + zero-guarded act.
- **Venue-agnostic trust (CTR-10b, I-11).** The gate dereferences only the venue-neutral
  `ISeniorVenue.seniorPool()` + `ISeniorPool` slots (`IFreeze.eulerEarn()`, name retained), so a non-Euler
  venue plugs in with NO registry change. The donation-immunity of a real non-Euler senior surface is THAT
  venue's own property — it cannot be proven (or refuted) by a mock here; distrusting the topology getters'
  return values (the components are the silo curator's own, asserted self-consistent) is a wiring residual,
  not a registry flaw.
- **Soundness is a valid result.** This is rated HARDENED. For a pure catalog with an exhaustively-proven
  6-clause admission web, "the gate binds, the slots can't desync, the lifecycle keeps the record, here's
  what I diffed" is the expected outcome; a manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard you attack (I-1…I-13, G-n)>
- **Location:** <fn / exact line in SiloRegistry.sol + the topology-getter source line where the seam crosses>
- **Delta from posture:** <how it breaks the §2 topology-assert / registry-managed-count posture, or "build-phase residual (INFO)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it ADMITS a miswired silo, DESYNCS
  the slot count, LOSES a lifecycle record / strands a close path, or lets a caller SEED `lineCount`/`active` —
  and confirm there is no fund-movement surface (pure catalog).

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: does the 6-clause topology web bind, and are `lineCount`/`active` un-seedable by a
caller?).
