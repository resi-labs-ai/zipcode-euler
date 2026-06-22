# WOOF-05 — `ZipcodeController` (wiring map)

> **X-Ray (security verdict):** rated **HARDENED** — the portable core's orchestrator, fork-proven against the
> real EVK/EVC/EulerEarn stack (43 tests). Atomic origination (CREATE2-rollback on any mid-batch revert),
> fail-closed stored-`siloId` routing, the report-type allow-list (revaluation rejected), and
> structural reentrancy-impossibility are all proven. Report: `contracts/src/x-ray/ZipcodeController.md`. ELI20:
> `docs/ZipcodeController.md`. This doc is the code-truth wiring map.

> Source of truth = `contracts/src/ZipcodeController.sol`. Ticket
> `tickets/woof/WOOF-05-controller.md` + report `reports/WOOF-05-report.md` + spec `claude-zipcode.md` §4.4
> are intent. This doc reads the kept code as the final form and records how the controller is wired and what
> it points at. (Build-phase doctrine note, §17/2026-06-09: the cross-component pointers below are now
> **Timelock-settable**, not immutable, and ownership is **transferred to the Timelock**, not renounced — the
> ticket/spec older "immutable via renounce" wording is reconciled against the code throughout.)
>
> **CTR-03 (2026-06-18) — siloId routing over `SiloRegistry`.** The controller is now multi-pool: the report
> paths resolve `venue` per origination from `SiloRegistry.venueOf(siloId)` (CTR-02) instead of the single
> `venue` pointer. Added: a `registry` wiring slot (NOT in ctor — wired post-deploy via `setRegistry`), an inline
> `ISiloRegistry` interface, errors `RegistryUnset`/`SiloUnrouted`, `LienRecord.siloId`, a trailing `siloId` on
> `LienOriginated` + the RT_ORIGINATION payload, and the `incrementLineCount`/`decrementLineCount` slot hooks. The
> `venue` slot/`setVenue`/ctor are RETAINED (deploy-cycle compat) but no longer route. Sections below reflect this.

## Role
The CRE-gated **origination/close orchestrator** — `contract ZipcodeController is ReceiverTemplate` (§4.4). It
is the single trusted on-chain identity and the portable core's command center: the **CRE receiver** (inbound
gated on the Chainlink Forwarder via `ReceiverTemplate.onReport`), the **report decode + per-`reportType`
decision logic** (`_processReport`), and the **lien-token mint/burn authority** (the `create`/`burn` caller).
It is the on-chain **borrower of record**, but it **takes NO EVC handle and touches no EVC type at all** — every
on-chain venue effect (open a line, set LTV/caps, fund, draw, observe debt, close) is driven through the
venue-neutral `IZipcodeVenue` seam (§4.7). The mechanical EVC borrow-on-behalf is the adapter's job as the
line's per-line EVC operator, granted by the line's `LineAccount` **inside** `openLine`; the controller never
calls EVC.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `ZipcodeController` (`is ReceiverTemplate`) | The unit. 5-arg ctor; `_processReport` dispatch; per-lien `liens` map; origination/draw/close branches; lien custody (`approve`/reclaim/`burn`). |
| `ReceiverTemplate` (base, `is IReceiver, Ownable`) | Concrete `onReport` (Forwarder gate + conditional workflow-identity gate) → calls the one `internal virtual` `_processReport`; the `setForwarderAddress`/`setExpected*` `onlyOwner` setters; `Ownable` owner = deployer. `onReport`/`setForwarderAddress` are **non-virtual** (not overridable). |
| `IZipcodeVenue` (`venue` pointer) | The venue-neutral seam — `openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/`closeLine`/`liquidate`. Only `bytes32`/`address`/`uint*` cross it; no Euler types. |
| `ILienTokenFactory` (`lienFactory`, inline iface) | `create(lienId)` (caller-bound CREATE2) + `computeAddress(lienId, controller)`. |
| `ILienToken` (the minted `LIEN_i`, inline iface) | `approve(spender, amount)` + controller-only `burn(amount)`. |
| `IZipcodeOracleRegistry` (`oracleRegistry`, inline iface) | `seedPrice(lien, price)` — the controller-gated origination/draw seed. |
| `ISiloRegistry` (`registry`, inline iface, CTR-03) | `venueOf(siloId)→adapter` (per-origination venue resolution) + `incrementLineCount`/`decrementLineCount` (the concurrent-line slot hooks, `onlyController` on the registry). |
| `erebor` (EOA/off-ramp) | The only legal `venue.draw` receiver (the adapter backstops `receiver == its own erebor`, WOOF-04 F2). |

## Wiring — internal

### Constructor (5 args, NO EVC)
```solidity
constructor(
    address forwarder,
    address venue_,
    address lienFactory_,
    address oracleRegistry_,
    address erebor_
) ReceiverTemplate(forwarder)
```
- `ReceiverTemplate(forwarder)` runs first: reverts `InvalidForwarderAddress` on zero, stores the Forwarder, and
  sets `Ownable` owner = `msg.sender` (the deploying `CONTROLLER_OWNER`).
- Body asserts each of the other four non-zero with **string `require`** (`"ZipcodeController: zero venue"`,
  `…zero lienFactory`, `…zero oracleRegistry`, `…zero erebor`) — string, not `CustomError()`, because the 0.8.24
  pin predates `require(cond, Err())`.
- Stores `venue`, `lienFactory`, `oracleRegistry`, `erebor` into **`address public`** state vars — **NOT
  `immutable`**. Each has a Timelock-only re-point setter (`setVenue`/`setLienFactory`/`setOracleRegistry`/
  `setErebor`, all `onlyOwner`, zero-checked via `revert ZeroAddress()`, each `emit WiringSet(slot, value)`).
  This is the §17 build-phase flexibility (a redeployed dep is a one-call re-point, not a redeploy cascade);
  lock-down deferred to pre-prod.
- There is **no EVC parameter, no EVC immutable, no EVC import** — the central subtraction of the borrower-model
  re-author.
- **`registry` is NOT a ctor arg (CTR-03).** It starts `address(0)` and is wired post-deploy via `setRegistry`
  (`onlyOwner`, `ZeroAddress`-checked, `emit WiringSet("registry", …)`) — symmetric to the oracle registry's
  `setController`. It is **MANDATORY for the report paths**: `_origination`/`_draw`/`_close` resolve venue
  EXCLUSIVELY through `registry` via the private `_venueFor(siloId)` and revert `RegistryUnset` if it is unwired
  (no fallback to the `venue` slot — that dual-mode is a deliberate non-feature; it would let a line opened
  pre-registry become un-closeable post-registry). `_venueFor` also reverts `SiloUnrouted(siloId)` if
  `venueOf(siloId) == address(0)`.

### The onReport identity gate (inherited, not overridden)
`onReport(bytes metadata, bytes report)` is concrete + **non-virtual** in `ReceiverTemplate` and is the only
entrypoint into the controller's logic. It enforces, in order (`ReceiverTemplate.sol:78-120`):
1. **Forwarder gate:** `if (s_forwarderAddress != address(0) && msg.sender != s_forwarderAddress) revert
   InvalidSender(msg.sender, s_forwarderAddress)`.
2. **Conditional workflow-identity gate:** the `(workflowId / author / name)` checks run **only when at least one
   expected value is non-zero**. If `setExpectedAuthor`/`setExpectedWorkflowId`/`setExpectedWorkflowName` were
   never set, this block is **skipped entirely** — the dormant-gate (security F-3): until identity is set,
   `onReport` is Forwarder-sender-only and any co-tenant workflow on the shared Forwarder is accepted.
3. Calls `_processReport(report)` — the one hook the controller overrides.

The controller does **not** override `onReport` or `setForwarderAddress` (both non-virtual); Forwarder/identity
immutability is a deploy-time concern (identity-set → `transferOwnership(timelock)`), not a contract override.

### reportType dispatch in `_processReport`
`_processReport(bytes calldata report) internal override` decodes the shared envelope
`abi.decode(report, (uint8 reportType, bytes payload))` then dispatches:

| `reportType` | const | Branch | Action |
|---|---|---|---|
| `1` | `RT_ORIGINATION` | `_origination(payload)` | the atomic batch (below) |
| `2` | `RT_DRAW` | `_draw(payload)` | re-anchor seed → fund → draw on the open line |
| `3` | (Revaluation) | — | **rejected** — delivered direct to the registry (§4.1); falls through to `else` → `UnsupportedReportType(3)` |
| `4` | `RT_CLOSE` | `_close(payload)` | observeDebt==0 → closeLine → burn |
| `5` / `6` | `RT_DEFAULT` / `RT_LIQUIDATION` | inline | **M1 status-marker only**: `abi.decode(payload,(bytes32,uint8))` → `emit LienStatusUpdated(lienId, status)`; no markdown/escrow/`venue.liquidate` (DefaultCoordinator is M2) |
| else | — | — | `revert UnsupportedReportType(reportType)` (fail closed; also covers `0`) |

### The atomic origination batch (`_origination`)
Payload `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256
drawAmount, uint256 cap, bytes32 siloId)` (CTR-03: trailing `siloId`). Sequence (any revert rolls back the whole
branch incl. the CREATE2 deploys — no orphan lien/market):
0. **Resolve venue (CTR-03):** `address venue_ = _venueFor(siloId)` (fail-closed: `RegistryUnset`/`SiloUnrouted`).
   Steps 3–7 below route through this local `venue_`, NOT the `venue` state var (which is no longer the routing
   source). Resolved first so a bad `siloId` reverts before any CREATE2 deploy.
1. **Dup guard:** `if (liens[lienId].lien != address(0)) revert LienExists(lienId)`.
2. **Precompute + create + assert:** `predicted = ILienTokenFactory(lienFactory).computeAddress(lienId,
   address(this))` then `lien = ILienTokenFactory(lienFactory).create(lienId)`; `if (lien != predicted) revert
   PrecomputeMismatch()`. After `create`, the controller holds the full `1e18` `LIEN_i` (minted to it as the
   `create` caller). `PrecomputeMismatch` is a defensive assert unreachable on real input (both derive from
   `(lienId, this)`).
3. **Custody approve:** `ILienToken(lien).approve(venue, FULL_LIEN)` — exactly `FULL_LIEN = 1e18`, no `max`
   (leaves zero standing allowance, F-7).
4. **Open the line:** `(address lineRef, address oracleKey) = IZipcodeVenue(venue).openLine(lienId, lien,
   FULL_LIEN)` — pass the FULL `1e18` (controller is the primary guarantor; venue backstops `!= 1e18`). The
   adapter deploys the per-line `LineAccount` + issues the EVC operator grant **inside** `openLine`, transparent
   to the controller. `oracleKey == lien`.
5. **Seed (seed-before-draw):** `IZipcodeOracleRegistry(oracleRegistry).seedPrice(oracleKey, equityMark)` — on
   the `openLine`-returned `oracleKey`, **after** `openLine`, **before** `draw` (an un-seeded key would revert
   the borrow's account-status read).
6. **Set limits:** `IZipcodeVenue(venue).setLineLimits(lineRef, borrowLTV, liqLTV, cap)` (1e4-scale LTVs; raw
   `cap`).
7. **Fund + draw:** `IZipcodeVenue(venue).fund(lineRef, drawAmount)` then `IZipcodeVenue(venue).draw(lineRef,
   drawAmount, erebor)`. The controller does **not** pre-check the LTV/cap bound — it is enforced on-chain by the
   EVK account-status check the adapter's borrow triggers; a bad report reverts here and rolls the branch back.
8. **Store LAST + event:** `liens[lienId] = LienRecord({lien, lineRef, open: true, siloId})` (last-write
   reentrancy safety, F-10); `emit LienOriginated(lienId, lien, lineRef, proofRef, equityMark, drawAmount, siloId)`.
9. **Bump the slot count (CTR-03, FINAL statement):** `ISiloRegistry(registry).incrementLineCount(siloId)` — the
   genuinely-last call. A `SiloFull` revert (registry cap = 28) rolls back the WHOLE atomic origination. F-10 is
   preserved despite the post-`liens`-write call because the registry is trusted and makes NO callback into the
   controller (no untrusted reentry surface).

So the ordering is the spec-mandated **create → openLine → seed → setLineLimits → fund → draw** (WOOF-02 obl. 3;
seed before draw), now bracketed by **resolve-venue (step 0)** and **increment-count (step 9)**.

### Draw branch (`_draw`)
Payload `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)`. `LienRecord storage r =
liens[lienId]; if (!r.open) revert UnknownLien(lienId)`. **Re-resolve the SAME venue from the stored siloId
(CTR-03):** `address venue_ = _venueFor(r.siloId)` (NEVER from a global/`currentSilo` pointer — a re-pointed or
retired silo cannot strand the line in the wrong venue). Re-anchor `seedPrice(r.lien, equityMark)` (fresh mark +
refreshed cache timestamp), then `venue_.fund(r.lineRef, drawAmount)` → `venue_.draw(r.lineRef, drawAmount,
erebor)` → `emit LienDrawn`. `proofRef` is carried for off-chain indexing, not stored.

### Close branch (`_close`) — reclaim 1e18 before burn
Payload `(bytes32 lienId)`. `if (!r.open) revert UnknownLien(lienId)`. **Re-resolve the SAME venue from the stored
siloId (CTR-03):** `address venue_ = _venueFor(r.siloId)` (`venueOf` ignores `active`, so an open line closes even
after its silo is retired). `if (IZipcodeVenue(venue_).observeDebt(r.lineRef) != 0) revert DebtOutstanding()`. Then
`IZipcodeVenue(venue_).closeLine(r.lineRef)` — the adapter redeems the escrowed `1e18` `LIEN_i` back to the
controller via the operator-routed `EVC.call`, so the controller holds it **before** `ILienToken(r.lien).burn(
FULL_LIEN)` (else `burn` reverts `ERC20InsufficientBalance` — the WOOF-01 reclaim-before-burn obligation).
`r.open = false` (keep `r.lien` set — single-use `lienId` forever, F-12); `emit LienReleased(lienId)`. **FINAL
statement (CTR-03):** `ISiloRegistry(registry).decrementLineCount(r.siloId)` (trusted no-callback registry).
**CTR-04 capacity caveat:** the decrement corrects the *registry* counter only; the as-built
`EulerVenueAdapter.closeLine` frees the SUPPLY queue but NOT the binding WITHDRAW-queue slot — so until CTR-04
lands a pool's true ceiling is ~28 *lifetime* opens, not concurrent. CTR-03 accounting is correct standalone;
concurrent capacity is fully sound only once CTR-03 + CTR-04 both land.

### Lien ↔ escrow custody (summary)
The controller **holds the `1e18`** from `create`, **`approve`s the adapter** (`venue`) for exactly `1e18` so
`openLine` deposits it into the per-line escrow as collateral, and at close **reclaims it via `closeLine`
before `burn`**. It never holds the lien outside an origination/close call window beyond the escrow leg.

## Wiring — cross-component (who points at whom)
- **controller → venue.** The `venue` pointer (the `IZipcodeVenue` adapter) is the read via the `venue()` public
  getter. Every venue effect (`openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/`closeLine`) flows through
  it. The reverse pin: the **adapter is constructed with `controller`** as its sole privileged caller
  (`EulerVenueAdapter(controller, evc, eulerEarn, …, erebor)`, §4.4) — so controller↔venue is a mutual pin
  resolved at deploy via address precompute.
- **controller → registry.** The `oracleRegistry` pointer; the controller is the registry's **`setController`
  authority** — the registry gates `seedPrice` on `msg.sender == controller` (`ZipcodeOracleRegistry.sol:107`).
  `setController(c)` is `onlyOwner` (the Timelock), Timelock-settable in the build phase (re-pointable, not a
  hard `AlreadyWired` set-once in the kept code), called at deploy **S6** to point the registry at this
  controller. The controller is the registry's only `seedPrice` caller (origination + draw re-anchor).
- **controller → siloRegistry (CTR-03).** The `registry` pointer (the `SiloRegistry`, CTR-02). The controller
  reads `venueOf(siloId)` to route each origination and re-resolves draw/close from the stored `r.siloId`, and is
  the registry's **`incrementLineCount`/`decrementLineCount` caller** — both `onlyController` on the registry,
  gated on `SiloRegistry.controller == this`. The reverse pin: the deploy MUST call
  `siloRegistry.setController(controller)` (and `controller.setRegistry(siloRegistry)`) before the first
  origination, else every origination reverts `NotController` at the increment step (and every close at the
  decrement). Symmetric to the `oracleRegistry.setController` step; assert `siloRegistry.controller() ==
  address(controller)` post-deploy.
- **controller → lienFactory.** The `lienFactory` pointer; `create(lienId)` is **caller-bound** — the new
  `LIEN_i`'s controller becomes the calling `ZipcodeController`. The controller precomputes via
  `computeAddress(lienId, address(this))` and asserts equality (`PrecomputeMismatch`).
- **controller → EREBOR.** The `erebor` pointer is passed as the `receiver` to every `venue.draw` (origination +
  draw); it is the draw off-ramp / dollar-leg endpoint. The adapter independently validates `receiver == its own
  erebor` (the same address, wired separately — defense-in-depth, WOOF-04 F2).
- **Forwarder / identity (the CRE side).** `ReceiverTemplate(forwarder)` pins the Chainlink Keystone Forwarder
  (`CRE_KEYSTONE_FORWARDER`, WOOF-00) at construction. The CRE workflow identity is wired post-deploy via
  `setExpectedAuthor(author)` + `setExpectedWorkflowName(name)` (S10b, CTR-16 — the `workflowId` pin is dropped), which activates the conditional
  identity gate. The CRE Go workflow (§8) ABI-encodes reports as `abi.encode(uint8 reportType, bytes payload)`
  exactly matching the `_processReport` dispatch table.

Spec/PROGRESS grounding: `claude-zipcode.md` §4.4 (5-arg ctor `(forwarder, venue, lienFactory, oracleRegistry,
erebor)`, no EVC handle; immutable-Forwarder-via-non-virtual-setters reconciled to "transfer to Timelock, not
renounce" 2026-06-09); `tickets/PROGRESS.md` item-6/WOOF-05 row (BUILT-VERIFIED, 26/26 live-fork) + item-10
obligations (5-arg ctor, `ZIP_ORACLE_REG.setController` at S6, identity-set-then-`transferOwnership(timelock)`
with the per-receiver author≠0 AND name≠0 pre-gate, CTR-16).

## Item-10 deploy facts
The controller's deploy/wiring is **item-10 (§9)**:
- **S6 — deploy the controller after VENUE** (the adapter, S5): `new ZipcodeController(FORWARDER, VENUE,
  LIEN_FACTORY, ZIP_ORACLE_REG, EREBOR)` (5 args, **no EVC**), deployer = `CONTROLLER_OWNER`. ctor asserts each
  of the four non-Forwarder args non-zero (and the base asserts the Forwarder non-zero).
- **S6 — `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)`** — point the registry's `seedPrice` authority at the
  freshly-deployed controller (registry deployed earlier at S3).
- **No `controller.wireVenueOperator(EVC)` step** — REMOVED by the per-line borrower model; each line's operator
  grant is issued inside `openLine` by the adapter's `LineAccount`. The controller has no EVC deploy step at all.
- **S10b — set identity (CTR-16):** `controller.setExpectedAuthor(AUTHOR)` +
  `controller.setExpectedWorkflowName(WORKFLOW_NAME_CONTROLLER)` (the `workflowId` pin is dropped; activates the
  conditional identity gate; both `onlyOwner`).
- **S11 — finalize ownership with a hard pre-gate:** assert `controller.getExpectedAuthor() != 0` **and**
  `getExpectedWorkflowName() != 0` **and**
  `ZIP_ORACLE_REG.controller() != 0` immediately before sealing, aborting the deploy otherwise (security F-3 /
  F-1). **Code-supported posture (reconciliation):** the kept `ReceiverTemplate` exposes both
  `renounceOwnership()` (inherited OZ `Ownable`) and `transferOwnership(addr)`. The older ticket/spec wording
  said "S11 renounceOwnership"; the **current spec (§4.4, revised 2026-06-09) and §17 build-phase doctrine say
  `transferOwnership(timelock)`, NOT renounce** — so CRE workflows can be rebuilt/upgraded behind the ≈2-day
  Timelock veto. The contract supports either (it adds no override); item-10 should use
  `transferOwnership(timelock)` guarded by the same author≠0 AND name≠0 pre-gate. (The pre-gate is the
  ONLY on-chain defense against the dormant-identity-gate — the contract itself cannot enforce identity-before-
  seal.)

## Gotchas
- **No EVC anywhere.** No EVC ctor arg, no EVC immutable, no EVC import, no `setOperator`/`setAccountOperator`
  call. The controller touches no Euler/EVC type — every venue effect crosses `IZipcodeVenue` (only
  `bytes32`/`address`/`uint*`).
- **No `wireVenueOperator`.** The per-line operator grant is the adapter's `LineAccount` job inside `openLine`;
  the controller has no operator-wiring entrypoint. The live borrow works with zero controller operator-wiring
  (`isAccountOperatorAuthorized(borrowAccount, adapter) == true`, `(…, controller) == false`).
- **The identity gate is dormant until set (F-3).** `ReceiverTemplate.onReport` only validates workflow identity
  when an expected value is non-zero. Before `setExpectedWorkflowId`/`setExpectedAuthor`, a wrong-`workflowId`
  report is **accepted** (Forwarder-sender-only). The contract has no on-chain defense against a seal-before-
  identity deploy; only the item-10 S11 pre-gate covers it.
- **`onReport`/`setForwarderAddress` are non-virtual** — do not (and the controller does not) override them.
  Forwarder/identity authority is governed by the owner (the Timelock post-S11), not by a subclass override.
- **`liens` public getter returns a tuple, not a struct** — use the explicit `getLien(lienId) returns
  (LienRecord memory)` for `.lien`/`.lineRef`/`.open`.
- **`require(cond, CustomError())` is 0.8.26+;** on the 0.8.24 pin the ctor zero-checks use **string `require`**,
  while the runtime guards use `if (!cond) revert CustomError()` (`ZeroAddress`/`LienExists`/`UnknownLien`/
  `PrecomputeMismatch`/`DebtOutstanding`/`UnsupportedReportType`).
- **Cross-component pointers are Timelock-settable (build phase), not immutable** — the §17 reconciliation; the
  ticket's "four immutables" wording is superseded by the kept `address public` + `setVenue`/`setLienFactory`/
  `setOracleRegistry`/`setErebor` re-point setters. Lock-down deferred to pre-prod.
- **`reportType 3` is rejected, not handled** — revaluation goes direct to the registry (§4.1); branch 3 falls
  through to `UnsupportedReportType(3)`. `venue.liquidate` is never called (branches 5/6 emit status markers
  only).
- **`registry` is mandatory for report paths; the `venue` slot no longer routes (CTR-03).** All three report
  branches resolve venue via `_venueFor(siloId)` against `SiloRegistry`; an unwired registry reverts
  `RegistryUnset`. `venue`/`setVenue`/the ctor arg are RETAINED only for the deploy-cycle compat (silo #0's
  adapter is expected to equal the ctor `venue` seed; `controller.venue() == adapter` still holds), NOT consulted
  at runtime. Do NOT reintroduce a `registry == 0 → use venue` fallback (a line opened pre-registry would become
  un-closeable post-registry — the deliberate non-feature).
- **draw/close re-resolve from `r.siloId`, never `currentSilo` (CTR-03).** This is what lets a re-pointed
  `currentSilo` or a retired silo NOT strand an open line — the stored siloId pins the line to its origin venue
  for its whole life (`venueOf` ignores `active`).
