# WOOF-10a — ZipcodeDeployAsserts (S11 deploy identity pre-gate, wiring map)

> **X-Ray (security verdict):** rated **HARDENED** — the deploy-time assertion library defending the
> dormant-identity hazard (13 tests). The hazard is concretely demonstrated (a receiver sealed before its
> identity is wired accepts a wrong identity); the gate checks each receiver's author + workflow name and the
> registry controller, fail-closed. No runtime surface. Report: `contracts/src/x-ray/ZipcodeDeployAsserts.md`.
> ELI20: `docs/ZipcodeDeployAsserts.md`. This doc is the code-truth wiring map.

> Source of truth = `contracts/src/ZipcodeDeployAsserts.sol` (read in full). Ticket
> `tickets/woof/WOOF-10a-deploy-identity-gate.md` + report `reports/WOOF-10a-report.md` + spec §9 / §4.1-F7
> are intent. This doc reads the kept code as the final form. Test: `contracts/test/deployer/ZipcodeDeployIdentityGate.t.sol`.

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
| `library ZipcodeDeployAsserts` (`contracts/src/ZipcodeDeployAsserts.sol`) | Stateless helper. Two `internal view` fns: `requireReceiverIdentityWired(address receiver)` (the per-receiver gate — reverts unless BOTH `getExpectedAuthor() != 0` AND `getExpectedWorkflowName() != bytes10(0)`) and `requireIdentityWired(address[] receivers, address registry)` (the fleet gate — rejects an empty set, loops EACH receiver through the per-receiver gate, then asserts `registry.controller() != 0`). Three errors: `ReceiverIdentityNotWired(address receiver)`, `RegistryControllerUnset(address registry)`, `EmptyReceiverSet()`. No state, no storage, no constructor. GPL-2.0-or-later, pragma `0.8.24`. |
| `interface IReceiverIdentity` (inline) | `getExpectedAuthor() external view returns (address)` + `getExpectedWorkflowName() external view returns (bytes10)` — the two read faces on every sealed `ReceiverTemplate` receiver. Declared inline to avoid pulling `ReceiverTemplate`/`BaseAdapter` into the library's compile unit. CTR-16 keys on author+name, NOT the dropped `getExpectedWorkflowId()` pin. |
| `interface IOracleRegistryController` (inline) | `function controller() external view returns (address)` — the set-once controller getter on `ZipcodeOracleRegistry` (the only contract with a `controller` getter, WOOF-02). |

## Wiring — internal
The library is two functions plus the errors they guard:

```solidity
error ReceiverIdentityNotWired(address receiver);
error RegistryControllerUnset(address registry);
error EmptyReceiverSet();

function requireReceiverIdentityWired(address receiver) internal view {
    if (
        IReceiverIdentity(receiver).getExpectedAuthor() == address(0)
            || IReceiverIdentity(receiver).getExpectedWorkflowName() == bytes10(0)
    ) revert ReceiverIdentityNotWired(receiver);
}

function requireIdentityWired(address[] memory receivers, address registry) internal view {
    if (receivers.length == 0) revert EmptyReceiverSet();
    for (uint256 k = 0; k < receivers.length; k++) {
        requireReceiverIdentityWired(receivers[k]);
    }
    if (IOracleRegistryController(registry).controller() == address(0)) {
        revert RegistryControllerUnset(registry);
    }
}
```

- **What it reads (pure view staticcalls):**
  - `getExpectedAuthor()` / `getExpectedWorkflowName()` on EACH receiver — its CRE workflow identity. Author
    `address(0)` OR name `bytes10(0)` ⇒ identity unset ⇒ F-3 dormancy. (`ReceiverTemplate.onReport` enforces the
    name only when the author is also set, so BOTH slots are load-bearing.)
  - `IOracleRegistryController(registry).controller()` — the registry's set-once controller. `address(0)` ⇒ F7
    unseedable brick.
- **The fail-closed conditions:** an empty `receivers` fleet reverts `EmptyReceiverSet` (defense-in-depth — the
  per-receiver loop would otherwise pass vacuously); each receiver reverts `ReceiverIdentityNotWired(receiver)` on
  the FIRST unset author/name; the registry reverts `RegistryControllerUnset(registry)` if its controller is
  unseeded. Passes ONLY when the fleet is non-empty, every receiver carries both slots, AND the controller is
  seeded — reverting on the first failure.
- **`if/revert`, not `require(cond, CustomError())`** — the latter is 0.8.26+; this repo pins 0.8.24.
- **CTR-16 — EACH receiver, not a representative.** The earlier design inferred "all wired" from one shared
  `WORKFLOW_ID` on every subclass ⇒ a single representative read. CTR-16 **DROPPED** that: under the
  separate-daemon model each receiver carries its OWN `workflowName`, so the gate loops and asserts every receiver
  individually — a representative-only check would miss an unset name on one receiver. `workflowName` is what
  separates two same-author daemons sharing the one deploy wallet (the K5 reason both author AND name are required).
- **The dormancy proof the gate is load-bearing** (`CTR16ReceiverIdentityTest`, against the real
  `SzipFarmUtilityLpOracle`):
  - **Dormant** (`test_Behavioral_DormantAcceptsWrongIdentity`): identity never set ⇒ a wrong-identity `LP_MARK`
    push from the (shared) Forwarder is ACCEPTED and writes the cache. Any co-tenant workflow clearing the
    Forwarder can drive it. This IS the vuln.
  - **Sealed** (`test_Behavioral_SealedRejectsWrongName`): a report whose author matches but whose name does NOT
    reverts `ReceiverTemplate.InvalidWorkflowName(wrong, sealed)` BEFORE dispatch; the matching report
    (`test_Behavioral_SealedAcceptsCorrectIdentity`) still pushes through.
  - **K5** (`test_K5_PrivilegeSeparation_NameSeparatesSameAuthorDaemons`): two receivers, SAME author, DIFFERENT
    names — a daemon-A report is accepted by receiver-A and rejected (`InvalidWorkflowName`) by receiver-B. Only
    the per-receiver name separates them.
  - `metadata` is built `abi.encodePacked(bytes32(0), name, WORKFLOW_OWNER)` per `_decodeMetadata` fixed offsets
    32/64/74 (packed, NOT `abi.encode`); the `workflowId` slot is left zero (the pin is dropped — `onReport` skips
    a zero expected id).

## Wiring — cross-component (what it gates)
- **`ZipcodeController` (WOOF-05)** — read for `getExpectedAuthor()` + `getExpectedWorkflowName()` (F-3 leg), as
  one receiver in the fleet array.
- **`ZipcodeOracleRegistry` (WOOF-02)** — read for `controller()` (F7 leg); the only contract with the set-once
  `controller` getter, and the gate's `registry` argument. It is ALSO a receiver in the array, so it gets both an
  identity check (as a receiver) and the distinct `controller()` check.
- **Every `ReceiverTemplate` subclass is asserted individually (CTR-16).** The deploy passes the full live fleet
  as `receivers[]` — controller, registry, warehouse adapter, coordinator, navOracle, rateOracle, and the CRE-push
  `lpOracle` when present (`!= address(0)`; the ownerless fair-LP branch is neither sealed nor asserted). The
  kept-code subclasses are `ZipcodeController`, `ZipcodeOracleRegistry`, `loss/DefaultCoordinator`,
  `supply/CreditWarehouse/WarehouseAdminModule`, `supply/SzipNavOracle`, `supply/SzipFarmUtilityLpOracle`,
  `bridge/SzAlphaRateOracle` (all `is ReceiverTemplate`). The old "same `WORKFLOW_ID` ⇒ a representative stands in
  for the whole set" inference is DROPPED — each receiver carries its own per-daemon `workflowName`, so a missing
  name on any one fails closed.
- **`PROGRESS.md` grounding** (grep `WOOF-10a` / `requireIdentityWired` / `S11`): backlog row 10a =
  **BUILT-VERIFIED 2026-06-06** (5/5 tests, 107/107 total at that window; no fork). The two item-10 obligation
  rows are marked **"GATE PORTION TESTED (by WOOF-10a)"**: the WOOF-05 F-3 row (controller identity leg) and the
  WOOF-02 F7 row (registry `controller()` leg) are discharged jointly by this one assert; their **OTHER clauses
  remain OPEN** (the 5-arg ctor, `setController`@S6 wiring, and the sequenced ownership hand-off calls are still
  item 10's job). WOOF-10a is explicitly recorded as **independent of the borrower-model rework** — there is no
  controller-level `wireVenueOperator`-before-handoff step (per-line operator grant moved into `openLine`).

## Item-10 deploy facts
- **Where imported/called:** item 10's deploy script imports `ZipcodeDeployAsserts` and calls
  `requireIdentityWired(address[] receivers, address registry)` at **S11** (CTR-16: takes the receiver array, asserts
  EACH sealed receiver individually), AFTER **S10b** sets identity (`setExpectedAuthor(WORKFLOW_OWNER)` +
  `setExpectedWorkflowName(<per-receiver daemon name>)` on every receiver — the `workflowId` pin is dropped) and AFTER **S6**
  seeds the registry (`registry.setController(ZIP_CONTROLLER)`), and IMMEDIATELY BEFORE the final ownership
  hand-off. Because the library is `internal`, it compiles into the deploy script — no separate deployment.
- **Tested-negative requirement (the discharge):** the deploy test MUST include runs that attempt the hand-off
  with a receiver (or the controller) unwired and prove they REVERT at the gate. WOOF-10a delivers exactly this
  against the REAL receivers via a `GateHarness` external wrapper (an `internal` lib fn can't be
  `vm.expectRevert`-targeted directly) — `ZipcodeDeployIdentityGateTest`:
  - `test_Negative_ReceiverUnsealed_GateReverts` (registry seeded, one receiver's identity unset → `ReceiverIdentityNotWired`),
  - `test_Negative_NameUnset_GateReverts` (author set, name unset → `ReceiverIdentityNotWired`),
  - `test_Negative_RegistryControllerUnset_GateReverts` (every receiver sealed, `controller() == 0` → `RegistryControllerUnset`),
  - `test_Negative_EmptyReceivers_GateReverts` (empty fleet → `EmptyReceiverSet`, defense-in-depth),
  - `test_Positive_GatePasses_ThenRenounce_ThenFrozen` (gate passes → hand-off → inherited setters revert
    `OwnableUnauthorizedAccount`).
  The per-receiver author+name posture and the dormancy/K5 proofs live in the second test contract,
  `CTR16ReceiverIdentityTest` (the `test_Behavioral_*` / `test_PreGate_*` / `test_K5_*` set, against the real
  `SzipFarmUtilityLpOracle`). 13 tests total.
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
  **tested negative** — a real deploy run that attempts the hand-off with a receiver's `getExpectedAuthor()` /
  `getExpectedWorkflowName()` (or the registry's `controller()`) unset and proves a `ReceiverIdentityNotWired` /
  `RegistryControllerUnset` REVERT. A receiver cannot self-defend (the conditional identity check in
  `ReceiverTemplate` degrades `onReport` to Forwarder-sender-only if identity is blank); the gate must externalize
  and prove it.
- **`internal` library ⇒ no direct `vm.expectRevert`.** Tests must route through an external `GateHarness` /
  `LpGateHarness` wrapper to assert the revert selector+args.
- **No fork, no external addresses.** The gate is a pure view of the identity + controller getters; the registry
  ctor's `quote.decimals()` is satisfied by a 6-dp `MockUSDC` and the LP oracle ctor strict-reads an 18-dp
  `MockLp18` (SUPPLY-ADV-13); the controller ctor only stores immutables (EOA stubs for forwarder/venue/erebor are
  fine — origination is never exercised).
- **CTR-16 reads every receiver — the representative shortcut is gone.** The old design read one representative
  `WORKFLOW_ID` and inferred the rest; CTR-16 loops the full `receivers[]` array and asserts each author+name, so
  a per-subclass name divergence (the separate-daemon model) can no longer slip through. The remaining residual is
  the call-site invariant: the deploy must pass the complete live fleet (the `EmptyReceiverSet` guard fail-closes
  an empty array, but the gate still trusts the script to enumerate every receiver).
