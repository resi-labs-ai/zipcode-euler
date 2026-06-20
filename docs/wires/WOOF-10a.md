# WOOF-10a — ZipcodeDeployAsserts (S11 deploy identity pre-gate, wiring map)

> Source of truth = `contracts/src/ZipcodeDeployAsserts.sol` (read in full). Ticket
> `tickets/woof/WOOF-10a-deploy-identity-gate.md` + report `reports/WOOF-10a-report.md` + spec §9 / §4.1-F7
> are intent. This doc reads the kept code as the final form. Test: `contracts/test/ZipcodeDeployIdentityGate.t.sol`.

## Role
The single load-bearing **deploy-time** assertion the item-10 script calls at **S11 — IMMEDIATELY before the
final ownership hand-off** of the two `Ownable` receivers (`ZipcodeController` + `ZipcodeOracleRegistry`). It is
the only defense against the dormant-identity vuln (§4.4 / audit F1 / security F-3+F7): in
`ReceiverTemplate`, the workflow-identity check inside `onReport` is **conditional** (it fires only when the
expected values are non-zero), and `onReport` / `setForwarderAddress` are **non-virtual**. So a deploy that
hands off ownership **before** wiring identity freezes the receiver in a Forwarder-sender-only state that any
co-tenant workflow the Forwarder relays can drive (F-3 dormancy). Symmetrically, handing off **before**
`registry.setController` leaves `registry.controller() == address(0)`, so the registry is unseedable forever
(F7 brick). The gate is **fail-closed**: it reverts unless BOTH identity and controller are wired, and the
discharge obligation is a **tested negative** — a deploy run that tries to hand off with either slot unset must
REVERT at the gate. Its shape is a `library internal view`: it compiles INTO the deploy script (no extra
deployed bytecode), spans both contracts, and is a pure deploy-time read.

## Contracts involved (what each does)
| Artifact | What it is |
|---|---|
| `library ZipcodeDeployAsserts` (`contracts/src/ZipcodeDeployAsserts.sol`) | Stateless helper. Two `internal view` fns: `requireIdentityWired(address controller, address registry)` (the combined controller+registry S11 gate) and `requireReceiverIdentityWired(address receiver)` (a single-receiver identity gate for a `ReceiverTemplate` outside the S10b same-WORKFLOW_ID loop — used for the un-looped CRE-push `lpOracle`, SEC-05/M4). Two errors: `IdentityNotWired(address controller, address registry)` + `ReceiverIdentityNotWired(address receiver)`. No state, no storage, no constructor. GPL-2.0-or-later, pragma `0.8.24`. |
| `interface IReceiverIdentity` (inline) | `function getExpectedWorkflowId() external view returns (bytes32)` — the one read face on the representative `ReceiverTemplate` receiver. Declared inline to avoid pulling `ReceiverTemplate`/`BaseAdapter` into the library's compile unit. |
| `interface IOracleRegistryController` (inline) | `function controller() external view returns (address)` — the set-once controller getter on `ZipcodeOracleRegistry` (the only contract with a `controller` getter, WOOF-02). |

## Wiring — internal
The whole library is one function plus the revert it guards:

```solidity
error IdentityNotWired(address controller, address registry);

function requireIdentityWired(address controller, address registry) internal view {
    if (
        IReceiverIdentity(controller).getExpectedWorkflowId() == bytes32(0)
            || IOracleRegistryController(registry).controller() == address(0)
    ) revert IdentityNotWired(controller, registry);
}

// SEC-05 (M4): the un-looped CRE-push lpOracle is a ReceiverTemplate NOT covered by the S10b same-WORKFLOW_ID
// assumption above, so it gets an explicit per-receiver gate. P9 seals it and calls this, both guarded
// `!= address(0)` (the fair-LP branch has no SzipFarmUtilityLpOracle → nothing to seal/assert).
error ReceiverIdentityNotWired(address receiver);

function requireReceiverIdentityWired(address receiver) internal view {
    if (IReceiverIdentity(receiver).getExpectedWorkflowId() == bytes32(0)) {
        revert ReceiverIdentityNotWired(receiver);
    }
}
```

- **What it reads (two pure view staticcalls):**
  - `IReceiverIdentity(controller).getExpectedWorkflowId()` — the controller's CRE workflow identity. `bytes32(0)`
    ⇒ identity unset ⇒ F-3 dormancy.
  - `IOracleRegistryController(registry).controller()` — the registry's set-once controller. `address(0)` ⇒ F7
    unseedable brick.
- **The combined fail-closed condition:** OR of the two `== zero` checks ⇒ reverts if **EITHER** is unwired;
  passes **only** when BOTH are non-zero. The revert carries `(controller, registry)` for diagnosis.
- **`if/revert`, not `require(cond, CustomError())`** — the latter is 0.8.26+; this repo pins 0.8.24.
- **Single-controller arg is sufficient by construction.** §9/S10b sets the **same** `WORKFLOW_ID` on every
  `ReceiverTemplate` subclass in one loop, so a non-zero `controller` id ⇒ the registry's id (and every other
  subclass's id) was wired in the same pass; the gate only needs to read the representative receiver plus the
  registry's distinct `controller()` slot. (Per the WOOF-10a superintendent review: the registry's own
  `getExpectedWorkflowId()` re-check is left optional for item 10.)
- **Dormancy selector-difference demo (the proof the gate is load-bearing),** asserted in
  `test_NegativeControl_DormantVsActiveIdentity_SelectorDifference`:
  - **Dormant** (identity never set + ownership renounced → permanently unwired): a wrong-`workflowId`
    reportType-3 `onReport` gets PAST the skipped identity check and reverts only on dispatch →
    `ZipcodeController.UnsupportedReportType(3)`. This IS the vuln.
  - **Gate-active** (a separate non-renounced controller with `setExpectedWorkflowId(WID)`): the SAME report
    reverts `ReceiverTemplate.InvalidWorkflowId(WRONG_WID, WID)` FIRST (identity check fires before dispatch).
  - The **selector difference** (`UnsupportedReportType` vs `InvalidWorkflowId`) is the proof that an unset
    identity silently degrades `onReport` to a Forwarder-sender-only path.
  - `metadata` is built `abi.encodePacked(WRONG_WID, bytes10(0), WORKFLOW_OWNER)` per `_decodeMetadata` fixed
    offsets 32/64/74 (packed, NOT `abi.encode`).

## Wiring — cross-component (what it gates)
- **`ZipcodeController` (WOOF-05)** — read for `getExpectedWorkflowId()` (F-3 leg). The representative receiver.
- **`ZipcodeOracleRegistry` (WOOF-02)** — read for `controller()` (F7 leg). The only contract with the set-once
  `controller` getter; the gate's second argument.
- **Every other `ReceiverTemplate` subclass** is covered transitively: §9/S10b sets the same `WORKFLOW_ID` on all
  of them in one loop, so the controller's non-zero id stands in for the whole set. The kept-code subclasses are
  `ZipcodeController`, `ZipcodeOracleRegistry`, `loss/DefaultCoordinator`, `supply/CreditWarehouse/WarehouseAdminModule`,
  `supply/SzipNavOracle`, `supply/SzipFarmUtilityLpOracle`, `bridge/SzAlphaRateOracle` (all `is ReceiverTemplate`).
  Per `PROGRESS.md`, the **warehouse/coordinator** `ReceiverTemplate` subclasses are the same-identity, same-gate
  population the S11 assert protects — they each get `setExpectedWorkflowId`→ownership hand-off in the same
  audit Phase-S seal (their item-10 wire is deferred to the engine-integration pass, `PROGRESS.md` row "Item 10 /
  engine-integration pass · audit sweep (8-Bw)").
- **`PROGRESS.md` grounding** (grep `WOOF-10a` / `requireIdentityWired` / `S11`): backlog row 10a =
  **BUILT-VERIFIED 2026-06-06** (5/5 tests, 107/107 total at that window; no fork). The two item-10 obligation
  rows are marked **"GATE PORTION TESTED (by WOOF-10a)"**: the WOOF-05 F-3 row (controller identity leg) and the
  WOOF-02 F7 row (registry `controller()` leg) are discharged jointly by this one assert; their **OTHER clauses
  remain OPEN** (the 5-arg ctor, `setController`@S6 wiring, and the sequenced ownership hand-off calls are still
  item 10's job). WOOF-10a is explicitly recorded as **independent of the borrower-model rework** — there is no
  controller-level `wireVenueOperator`-before-handoff step (per-line operator grant moved into `openLine`).

## Item-10 deploy facts
- **Where imported/called:** item 10's deploy script imports `ZipcodeDeployAsserts` and calls
  `requireIdentityWired(controller, registry)` at **S11**, AFTER **S10b** sets identity
  (`setExpectedAuthor(WORKFLOW_OWNER)` + `setExpectedWorkflowId(WORKFLOW_ID)` on every receiver) and AFTER **S6**
  seeds the registry (`registry.setController(ZIP_CONTROLLER)`), and IMMEDIATELY BEFORE the final ownership
  hand-off. Because the library is `internal`, it compiles into the deploy script — no separate deployment.
- **Tested-negative requirement (the discharge):** the deploy test MUST include a run that attempts the hand-off
  with identity (or controller) unset and prove it REVERTS `IdentityNotWired` at the gate. WOOF-10a delivers
  exactly this against the REAL receivers via a `GateHarness` external wrapper (an `internal` lib fn can't be
  `vm.expectRevert`-targeted directly):
  - `test_Negative_IdentityUnset_GateReverts` (registry seeded, id 0),
  - `test_Negative_ControllerUnset_GateReverts` (id set, registry unseeded),
  - `test_Negative_BothUnset_GateReverts`,
  - `test_Positive_GatePasses_ThenRenounce_ThenFrozen` (gate passes → hand-off → inherited setters revert
    `OwnableUnauthorizedAccount`),
  - `test_NegativeControl_DormantVsActiveIdentity_SelectorDifference`.
- **Applies to every `ReceiverTemplate` subclass** — the same S10b-set identity + S11 assert + hand-off pattern
  seals the controller, registry, coordinator, and warehouse-admin receivers.
- **Build-phase doctrine shift — hand-off, not renounce.** The spec/PROGRESS were updated (§9 `:1810-1820`,
  §4.4/§17): in the **build phase the Forwarder + every wiring slot stay Timelock-re-pointable** (immutability/
  renounce is **deferred to the pre-prod lock-down**), so the final S11 wiring op is
  **`transferOwnership(timelock)`**, NOT `renounceOwnership()`. **The gate logic is unchanged** — the assert still
  fires "set identity first (assert it), THEN hand off ownership," only the irreversible target moved from
  `address(0)` to the OZ `TimelockController` (delay ≈2 days, §17). The WOOF-10a tests still exercise the
  `renounceOwnership()` post-state (proving the frozen-setter behavior); under the kept doctrine item 10
  substitutes `transferOwnership(timelock)` for the same call site, with the same pre-gate.
- **Boundary:** this slice delivers ONLY the S11 assert + its proof. The full S1–S12 deploy/wire (5-arg
  `ZipcodeController` ctor incl. `EREBOR`, `setController`@S6, per-line routers wired in `openLine`, the
  sequenced ownership hand-offs) remains item 10's job.

## Gotchas
- **Documentation / an unexercised assert line does NOT discharge.** The obligation is satisfied only by a
  **tested negative** — a real deploy run that attempts the hand-off with `getExpectedWorkflowId()` (or
  `controller()`) unset and proves an `IdentityNotWired` REVERT. The controller cannot self-defend (the
  conditional identity check in `ReceiverTemplate` degrades `onReport` to Forwarder-sender-only if identity is
  blank); the gate must externalize and prove it.
- **`internal` library ⇒ no direct `vm.expectRevert`.** Tests must route through an external `GateHarness`
  wrapper to assert the revert selector+args.
- **No fork, no external addresses.** The gate is a pure two-getter view; the registry ctor's `quote.decimals()`
  is satisfied by a 6-dp `MockUSDC`, the controller ctor only stores immutables (EOA stubs for
  forwarder/venue/erebor are fine — origination is never exercised).
- **Single-controller arg relies on the §9/S10b same-`WORKFLOW_ID`-in-one-loop invariant.** If a future deploy
  ever sets per-subclass workflow ids, the representative-controller shortcut would no longer cover the whole set
  and the assert would need to read each receiver.
