# WOOF-10a — Deploy identity pre-gate (the S11 renounce-before-identity gate, §9)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** Real on disk:
> `contracts/src/ZipcodeDeployAsserts.sol` + `contracts/test/ZipcodeDeployIdentityGate.t.sol`. `forge build` green
> (solc 0.8.24); **5/5 new tests pass** (107/107 total across all suites, no regression; independently re-run +
> source read by the superintendent). **No fork needed** — the gate is a pure view and the registry ctor only
> reads `quote.decimals()` (a 6-dp mock satisfies it). The build confirmed this is a **zero-spec-guess keepsake**:
> the library is exactly the ticket's body (combined fail-closed `getExpectedWorkflowId()==0 || controller()==0`
> → `IdentityNotWired`, two inline read interfaces, `internal view`, `if/revert` for 0.8.24), and every signature
> matched the real on-disk WOOF-01/02/05 source (zero discrepancies). All three test classes proven against the
> REAL `ZipcodeOracleRegistry` + `ZipcodeController` keepsakes: NEGATIVE (3 cases → exact
> `IdentityNotWired(controller, registry)`), POSITIVE (gate passes → renounce → inherited setters +
> `setController` revert `OwnableUnauthorizedAccount`), NEGATIVE-CONTROL (the dormancy selector-difference —
> dormant → `UnsupportedReportType(3)`, gate-active → `InvalidWorkflowId(WRONG_WID, WID)`). See
> `reports/WOOF-10a-report.md`. **Code KEPT, not discarded.**

**Slice of item 10 (deploy/wiring, §9).** This is a focused, build-only slice that delivers + TESTS the **one
load-bearing deploy-time assertion** the two item-10 obligation rows (security **F7** / **F-3**) jointly demand:
the S11 pre-gate that BLOCKS a `renounceOwnership()` performed before the CRE workflow-identity is wired (and
before the registry's `controller` is seeded). It does **not** author the full S1–S12 deploy script — only the
reusable assert + its proving test, so item 10 absorbs it verbatim at S11.

(Internal deploy plumbing — **build-only, no interface/frontend ticket**. No user surface; it runs once at
deploy.)

**Deliverable**
1. `contracts/src/ZipcodeDeployAsserts.sol` — a tiny GPL-2.0-or-later library exposing **one** free assertion the
   item-10 deploy script calls **immediately before `controller.renounceOwnership()`** (and before
   `registry.renounceOwnership()`):
   ```solidity
   library ZipcodeDeployAsserts {
       error IdentityNotWired(address controller, address registry);
       function requireIdentityWired(address controller, address registry) internal view {
           if (
               IReceiverIdentity(controller).getExpectedWorkflowId() == bytes32(0) ||
               IOracleRegistryController(registry).controller() == address(0)
           ) revert IdentityNotWired(controller, registry);
       }
   }
   ```
   with the two minimal local read interfaces it needs (`IReceiverIdentity.getExpectedWorkflowId() returns
   (bytes32)`, `IOracleRegistryController.controller() returns (address)`). **One combined check** — the F7 clause
   (`controller() != 0`, registry seedable) and the F-3 clause (`getExpectedWorkflowId() != 0`, identity active)
   are a single assert, exactly as the spec/audit specify (§9, audit/2.md S11 "assert `getExpectedWorkflowId() !=
   bytes32(0)` … Also assert the registry's `controller != address(0)`").
2. `contracts/test/ZipcodeDeployIdentityGate.t.sol` — a Foundry test that proves the gate against the **REAL**
   keepsake contracts (forwarder EOA + real `ZipcodeOracleRegistry` (WOOF-02) + real `ZipcodeController`
   (WOOF-05)), with the three test classes in **Done when**: NEGATIVE (gate reverts when unwired),
   POSITIVE (gate passes → renounce succeeds → owner-gated setters revert), NEGATIVE-CONTROL (the dormant-identity
   vuln the gate prevents: with identity unset + renounced, a WRONG-`workflowId` `onReport` is ACCEPTED; after
   identity set it reverts `InvalidWorkflowId`).

**Spec §**
`claude-zipcode.md` **§9** (the S10b-then-S11 ordering; the hard pre-gate: "assert `getExpectedWorkflowId() != 0`
… immediately before `renounceOwnership()` and abort otherwise … Also assert the registry's `controller !=
address(0)`") + **§4.4** (the Forwarder is immutable via renounce, not an override; the dormant-identity caveat —
the controller has NO on-chain self-defense, the S11 pre-gate is the only defense). Cross:
- `audit/2.md` **S10b** (set `setExpectedAuthor`/`setExpectedWorkflowId` before S11), **S11** (the hard pre-gate +
  the renounce + the post-renounce `OwnableUnauthorizedAccount` post-state), **S6** (`registry.setController`).
- `audit/3-results.md` **F1** (the conditional identity check at `ReceiverTemplate.onReport:88-117` runs ONLY when
  an expected value is non-zero; renounce-before-identity permanently skips it → only the Forwarder-sender check
  survives), rows **20** (`onReport` Forwarder + identity), **183** (registry `setController` set-once).
Locked §17: event-driven Proof valuation, immutable Forwarder — both preserved (this gate only enforces the wiring
order the spec already mandates; it adds no new mechanism).

**Discharges inbound obligations (PROGRESS → the two item-10 rows tagged F7 / F-3, the gate portion only):**
1. **(WOOF-05 row, F-3)** "set identity (S10b) then renounce (S11) with the `getExpectedWorkflowId() != 0`
   pre-gate … as a REQUIRED tested negative: the deploy test MUST include a run that renounces with identity (or
   controller) unset and prove it REVERTS at the gate". Realized: `requireIdentityWired` + the NEGATIVE test.
   Mark the gate portion **TESTED (by WOOF-10a)**; the row's OTHER clauses (5-arg ctor, `wireVenueOperator`-before-
   renounce) stay OPEN for the full item 10.
2. **(WOOF-02 row, F7)** "at S11 assert `getExpectedWorkflowId() != 0` AND `controller() != 0` before
   `renounceOwnership()` … This S11 assert is the SAME gate as the WOOF-05 row above (F-3) — one combined check,
   and it MUST be a tested negative". Realized: the SAME `requireIdentityWired` (the `controller()` clause) + the
   `controller`-unset NEGATIVE case. Mark the gate portion **TESTED (by WOOF-10a)**; the row's OTHER clause
   (`setController` at S6) stays OPEN for the full item 10. (The old `govSetFallbackOracle`@S10 clause is
   dissolved — per-line `ROUTER_i` is wired + frozen inside `openLine`, §4.7; no shared router.)

---

## Design (the deploy-time pre-gate)

**Why a deploy-time assert is the ONLY defense (do not re-litigate — build it).** `ReceiverTemplate.onReport`'s
workflow-identity check is **conditional** (`:88` — it runs only when `s_expectedWorkflowId` /`s_expectedAuthor`
/`s_expectedWorkflowName` is non-zero). `onReport` and `setForwarderAddress` are **non-virtual** (verified) — the
controller/registry **cannot override** them to self-defend, and by the time the overridden `_processReport`
runs, the dormant check has already (not) fired. So a deploy that calls `renounceOwnership()` BEFORE
`setExpectedWorkflowId` freezes the receiver in a state where `onReport` degrades to **Forwarder-sender-only**:
any co-tenant workflow on the shared CRE Forwarder can drive origination. Symmetrically, renouncing before
`registry.setController` leaves `controller == address(0)`, so `seedPrice` reverts `NotController` forever
(origination unseedable). The only place to catch this is a **deploy-time pre-gate at S11**, called immediately
before the irreversible `renounceOwnership()`.

**The library (free function, internal, view).** `ZipcodeDeployAsserts.requireIdentityWired(controller, registry)`
reverts `IdentityNotWired(controller, registry)` if **either**:
- `IReceiverIdentity(controller).getExpectedWorkflowId() == bytes32(0)` (identity unset — the F-3 dormancy
  trigger), OR
- `IOracleRegistryController(registry).controller() == address(0)` (registry unseedable — the F7 brick).

It is `internal` (inlined into the calling deploy script — no separate deployment), `view` (two staticcalls), and
**combined** (one revert covers both clauses). The deploy script (item 10) calls it ONCE at S11 with the
controller + registry addresses, then performs the two `renounceOwnership()` calls. **It asserts on the
controller's identity** as the representative receiver: §9/S10b sets the SAME `WORKFLOW_ID` on every
`ReceiverTemplate` subclass (controller + registry), so a non-zero controller id ⇒ the registry id was wired in
the same S10b loop; item 10 MAY additionally call `requireIdentityWired(registry, registry)` if it wants the
registry's own id asserted independently (cheap, optional — note in §9 step, not required by this slice). The
`controller()` clause is read off the REGISTRY (the only contract with a `controller` set-once getter).

**Why a free function library, not a method on the controller/registry.** The check spans TWO contracts
(controller identity + registry controller) and runs at DEPLOY time, not at runtime — it belongs to the deploy
script's concern, not either contract's surface (the contracts are already renounce-frozen; adding a method would
be dead post-renounce). A `library` with an `internal` function is the minimal, item-10-absorbable shape (it
compiles INTO the deploy script; no extra deployed bytecode). This mirrors how the spec frames it: "the deploy
script MUST assert … before `renounceOwnership()`" (§9) — a script concern.

---

**Model from (verified against `reference/` + the filed WOOF keepsakes)**
- **`ReceiverTemplate.getExpectedWorkflowId()`** — `reference/x402-cre-price-alerts/contracts/interfaces/
  ReceiverTemplate.sol:72`: `function getExpectedWorkflowId() external view returns (bytes32)` (returns the
  private `s_expectedWorkflowId`, `:19`/`:73`). **Verified.** Set by `setExpectedWorkflowId(bytes32) external
  onlyOwner` (`:184`); read returns `bytes32(0)` until set. The conditional identity gate is `:88` (fires only
  when `s_expectedWorkflowId != bytes32(0) || s_expectedAuthor != address(0) || s_expectedWorkflowName !=
  bytes10(0)`); the wrong-id revert is `InvalidWorkflowId(received, expected)` (`:91-93`, error decl `:29`).
  `onReport`/`setForwarderAddress` carry **no `virtual`** keyword (`:78`/`:127`) → non-overridable (the reason the
  controller cannot self-defend). `renounceOwnership()` is inherited from OZ `Ownable` (euler-vault-kit's OZ v5 —
  sets `owner() == address(0)`; post-renounce `onlyOwner` reverts `OwnableUnauthorizedAccount(address)`).
  - **`_decodeMetadata`** (`:213-227`) reads FIXED offsets 32/64/74 from the `metadata` bytes via assembly, so the
    NEGATIVE-CONTROL test must build `metadata` with **`abi.encodePacked(workflowId, workflowName, workflowOwner)`**
    (a `bytes32` + a `bytes10` + an `address` = 62 bytes), NOT `abi.encode` (WOOF-02/WOOF-05 note). For the
    POSITIVE/NEGATIVE gate tests `metadata` is irrelevant (the gate is a pure view of state, not an `onReport`
    call), and where `onReport` IS exercised with identity unset, `metadata = ""` empty bytes is fine (the
    identity branch at `:88` is skipped).
- **`ZipcodeOracleRegistry.controller()`** — `contracts/src/ZipcodeOracleRegistry.sol` (WOOF-02, **filed
  keepsake**): `address public controller;` (the auto-getter `controller() returns (address)`), set ONCE via
  `setController(address) external onlyOwner` (`if (controller != address(0)) revert ControllerAlreadySet();`).
  Returns `address(0)` until `setController` runs. **Verified** against the WOOF-02 ticket (Key requirements →
  "Set-once controller"). Constructor `ZipcodeOracleRegistry(address forwarder, address quote_, uint256
  validityWindow_)`; `seedPrice(address,uint256)` is gated `if (msg.sender != controller) revert NotController();`.
- **`ZipcodeController`** — `contracts/src/ZipcodeController.sol` (WOOF-05, **filed keepsake**): `is
  ReceiverTemplate`; ctor `ZipcodeController(address forwarder, address venue, address lienFactory, address
  oracleRegistry, address erebor)` (**5-arg**, zero-checks on the four non-forwarder args). Inherits
  `getExpectedWorkflowId`/`setExpectedWorkflowId`/`renounceOwnership`/`onReport` from `ReceiverTemplate`. The
  owner-gated setters the POSITIVE test asserts revert post-renounce: `setForwarderAddress`, `setExpectedAuthor`,
  `setExpectedWorkflowId` (all inherited from `ReceiverTemplate`). The controller takes **no EVC handle and has no
  `wireVenueOperator`** — the borrower-model rework (2026-06-05, WOOF-05) removed it; the per-line operator grant
  is issued inside `VENUE.openLine` by the adapter's `LineAccount`.
- **Local read interfaces (declare inline in the library — do NOT import the full contracts; the deploy script
  only needs two view selectors):**
  - `interface IReceiverIdentity { function getExpectedWorkflowId() external view returns (bytes32); }`
  - `interface IOracleRegistryController { function controller() external view returns (address); }`
  (Both faces are satisfied by the real `ZipcodeController`/`ZipcodeOracleRegistry`; declaring local interfaces
  avoids pulling `ReceiverTemplate`/`BaseAdapter` into the library's compile unit.)
- **NOT** an override of `onReport`/`setForwarderAddress` (non-virtual — the whole point is the contract can't
  self-defend). **NOT** `require(cond, CustomError())` (solc ≥ 0.8.26; WOOF-00 pins 0.8.24) → `if (!cond) revert
  CustomError();`.

**Starting state**
- WOOF-00 done; `contracts/src/ZipcodeDeployAsserts.sol` and `contracts/test/ZipcodeDeployIdentityGate.t.sol`
  carry the WOOF-00-pinned header (`// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;`).
- **Remap:** `x402-cre-price-alerts/=../reference/x402-cre-price-alerts/contracts/` + `@solady/=...` were added by
  WOOF-02; `evc/`, `evk/`, `euler-price-oracle/`, `euler-earn/`, `@openzeppelin/contracts/`, `forge-std/` resolve
  via WOOF-00 + WOOF-02. Re-add the two WOOF-02 lines if absent (no comment lines).
- WOOF-00/01/02/04/05 are **filed keepsakes**; the cold-build rebuilds the ones needed to stand up the REAL
  contracts under test — at minimum **WOOF-02 (`ZipcodeOracleRegistry`)** + **WOOF-05 (`ZipcodeController`)** +
  their transitive deps (WOOF-01 factory/token for the controller ctor; WOOF-04 `IZipcodeVenue`/`EulerVenueAdapter`
  for the controller's `venue` immutable; WOOF-00 scaffold). The controller's **5-arg ctor needs
  venue/lienFactory/oracleRegistry/erebor** — this slice does NOT exercise origination, so the venue + factory may
  be **mocked/stub** (any non-zero address that satisfies the ctor zero-checks; e.g. a bare `address(0xVE)` /
  `address(0xFA)` is NOT allowed — the ctor reverts on zero, so pass deployed stub addresses or real keepsakes).
  Simplest: deploy the **real** WOOF-01 `LienTokenFactory`, a **real** WOOF-02 `ZipcodeOracleRegistry` (it is one
  of the contracts under test anyway), and a **minimal stub** for `venue` + `erebor` (EOAs / a 1-line stub
  contract) — the gate + dormancy tests never call into the venue. The unit under test is the **library + the two
  real receivers**.

**Do NOT**
- **Do NOT author the full S1–S12 deploy script.** This slice is the S11 assert + its test ONLY. Item 10 owns the
  rest (5-arg ctor [no EVC] wiring, `setController`@S6, curator/timelock-0, `baseUsdcMarket`, the actual
  `renounceOwnership()` calls in sequence). (No `wireVenueOperator` and no `govSetFallbackOracle` — both
  dissolved by the borrower-model + per-line-router redesigns.)
- **Do NOT reopen §17** or re-derive the design (event-driven Proof, immutable Forwarder). The gate enforces the
  ordering the spec ALREADY mandates (§9/S11); it invents no mechanism. This is a test-authoring + tiny-helper
  item, NOT a spec edit (spec-fidelity: §9 + audit S11 already specify `getExpectedWorkflowId() != 0` AND
  `controller() != 0` before renounce — confirm, do not invent).
- **Do NOT add an override of `onReport`/`setForwarderAddress`** in any contract (non-virtual; the dormancy is the
  reason the gate exists — "fixing" it on the contract is impossible AND off-scope).
- **Do NOT make the assert a method on the controller or registry.** It spans two contracts + is a deploy-time
  concern; a `library` `internal` view function is the minimal absorbable shape (compiles into the deploy script,
  no extra deployed bytecode).
- **Do NOT use `require(cond, CustomError())`** (solc 0.8.24) → `if (!cond) revert IdentityNotWired(...)`.
- **Do NOT assert the registry's identity via the controller, or vice-versa, in the library.** The library reads
  `getExpectedWorkflowId()` off the **controller** (the representative receiver) and `controller()` off the
  **registry** (the only `controller` getter) — exactly the two clauses §9/S11 name. (Item 10 MAY add a redundant
  `requireIdentityWired(registry, registry)` for the registry's own id; out of scope here.)
- **Do NOT build a NEGATIVE-CONTROL that mutates origination/venue state.** The dormancy demo is purely about
  `onReport`'s identity gate accepting a wrong `workflowId` — use a `reportType` payload that is REJECTED *after*
  the identity gate (so the test isolates the identity check, not the downstream branch). Simplest: a
  `reportType 3` (controller rejects → `UnsupportedReportType(3)`) or a `reportType 7`/`255` (unknown →
  `UnsupportedReportType`). The proof is the SELECTOR DIFFERENCE: with identity unset a wrong-id `onReport` gets
  PAST the identity gate and reverts on the DISPATCH (`UnsupportedReportType`) — i.e. the identity check did NOT
  fire; after `setExpectedWorkflowId(WID)` the SAME wrong-id `onReport` reverts `InvalidWorkflowId` FIRST (the
  identity gate now fires). (This isolates "identity gate accepted the wrong id" from any venue effect — no
  origination needed. The WOOF-05 controller test uses this exact dormancy pattern; reuse it.)

**Key requirements**
- **`library ZipcodeDeployAsserts`** with `error IdentityNotWired(address controller, address registry);` and
  `function requireIdentityWired(address controller, address registry) internal view` implementing the combined
  check above. Two local read interfaces (`IReceiverIdentity`, `IOracleRegistryController`). No state, no storage,
  no constructor. GPL-2.0-or-later + `pragma 0.8.24`.
- **The assert is `view` + combined + fail-closed:** reverts `IdentityNotWired(controller, registry)` if EITHER
  `getExpectedWorkflowId() == bytes32(0)` OR `controller() == address(0)`. Passes (no revert) only when BOTH are
  set. (No try/catch — the two getters always succeed on the real contracts; a non-receiver `controller` arg would
  revert the staticcall, which is an acceptable hard-fail at deploy time — the deploy script passes the real
  addresses.)

**Done when**
- `forge build` green (solc 0.8.24); `contracts/test/ZipcodeDeployIdentityGate.t.sol` passes.
- **Harness (REAL keepsakes — minimal stand-up):** deploy a **real** `ZipcodeOracleRegistry(FORWARDER, USDC_MOCK,
  VALIDITY)` (WOOF-02; `USDC_MOCK` a 6-dp mock ERC20, `VALIDITY = 365 days`) and a **real**
  `ZipcodeController(FORWARDER, VENUE_STUB, LIEN_FACTORY, REGISTRY, EREBOR)` (WOOF-05; `FORWARDER`/`EREBOR` test
  EOAs; `VENUE_STUB` = a minimal deployed stub or the real `EulerVenueAdapter` — origination is never exercised, so
  a stub satisfying the ctor zero-check suffices; `LIEN_FACTORY` = real WOOF-01 factory). `CONTROLLER_OWNER` =
  `address(this)` (the test is the deployer/owner, so it owns both receivers and can set identity / renounce). A
  thin test-only wrapper (e.g. `function gate(address c, address r) external view { ZipcodeDeployAsserts.
  requireIdentityWired(c, r); }`) lets `vm.expectRevert` target the library call (an `internal` library fn can't be
  `vm.expectRevert`-pranked directly; wrap it).
- **NEGATIVE — the tested gate (the obligations' REQUIRED negative):**
  - **Identity unset:** with `controller.getExpectedWorkflowId() == 0` (never set) but `registry.setController`
    DONE (`controller() != 0`), `requireIdentityWired(controller, registry)` **reverts**
    `IdentityNotWired(controller, registry)` (assert the exact selector + both args via
    `abi.encodeWithSelector(ZipcodeDeployAsserts.IdentityNotWired.selector, controller, registry)`). This is the
    F-3 case — a deploy that tried to `renounceOwnership()` here is BLOCKED.
  - **Controller unset:** with `controller.setExpectedWorkflowId(WID)` DONE (id != 0) but
    `registry.setController` SKIPPED (`registry.controller() == 0`), `requireIdentityWired` **reverts**
    `IdentityNotWired`. This is the F7 case — a deploy that renounces with the registry unseedable is BLOCKED.
  - **Both unset:** reverts `IdentityNotWired` (sanity).
- **POSITIVE — gate passes → renounce → frozen:**
  - Set `controller.setExpectedAuthor(WORKFLOW_OWNER)` + `controller.setExpectedWorkflowId(WID)` (S10b) AND
    `registry.setController(address(controller))` (S6). Now `requireIdentityWired(controller, registry)` **does
    not revert** (the gate passes).
  - Then `controller.renounceOwnership()` **succeeds**; assert `controller.owner() == address(0)`.
  - **Post-renounce every `onlyOwner` setter reverts `OwnableUnauthorizedAccount`:** as a NON-owner (the test, now
    that owner is `address(0)` — or `vm.prank(someEOA)`), `controller.setForwarderAddress(any)`,
    `controller.setExpectedAuthor(any)`, and `controller.setExpectedWorkflowId(any)` each revert
    `OwnableUnauthorizedAccount(caller)` (pin the selector; these are the three inherited `ReceiverTemplate`
    owner-gated setters — the controller has no `wireVenueOperator`, removed by the borrower-model rework). Also
    `registry.renounceOwnership()`
    succeeds + `registry.setController(any)` then reverts `OwnableUnauthorizedAccount` (the registry's set-once is
    frozen too). (This is the audit S11 post-state.)
- **NEGATIVE-CONTROL — demonstrate the vuln the gate prevents (the dormancy the gate's negative justifies):**
  - **Dormant (identity unset):** with `controller.getExpectedWorkflowId() == 0` (NOT set), and the controller
    renounced (so it is permanently in the unwired state — `renounceOwnership()` from owner BEFORE setting
    identity), `vm.prank(FORWARDER); controller.onReport(metadata_wrongId, abi.encode(uint8(3), ""))` (a
    `reportType 3` the controller REJECTS) reverts **`UnsupportedReportType(3)`** — i.e. it got PAST the identity
    gate (the wrong `workflowId` in `metadata` was ACCEPTED; the revert is from the DISPATCH, not the identity
    check). Build `metadata_wrongId` with `abi.encodePacked(WRONG_WID, bytes10(0), WORKFLOW_OWNER)`. **This is the
    vuln:** any co-tenant workflow's report passes the (skipped) identity gate.
  - **Gate-active (identity set):** on a SEPARATE controller instance (NOT renounced — so identity is still
    settable), `controller2.setExpectedWorkflowId(WID)`; then the SAME `vm.prank(FORWARDER);
    controller2.onReport(metadata_wrongId, abi.encode(uint8(3), ""))` reverts **`InvalidWorkflowId(WRONG_WID,
    WID)`** (the identity gate now FIRES FIRST, before dispatch). The SELECTOR DIFFERENCE
    (`UnsupportedReportType` vs `InvalidWorkflowId`) is the proof that identity was dormant in the first case and
    active in the second — which is exactly why the S11 pre-gate must block renounce-before-identity. (This is the
    SAME dormancy demo the WOOF-05 controller test carries; here it justifies the gate.)
- **Report the observed revert selectors** in the cold-build report: `IdentityNotWired` (the gate, x3 negative
  cases), `OwnableUnauthorizedAccount` (the frozen setters, post-renounce), `UnsupportedReportType(3)` (dormant —
  identity skipped), `InvalidWorkflowId` (gate-active — identity fired).
- **Acceptance (integration — the `audit/2.md` slice this delivers):** `audit/2.md` **S11** (the hard pre-gate
  before renounce + the post-renounce `OwnableUnauthorizedAccount` post-state); `audit/3-results.md` **F1** (the
  conditional identity check, now defended by a TESTED deploy-time gate, not just a §9 prose mandate). The full
  S1–S12 wiring (S6 `setController`, S8 curator/timelock-0, the 5-arg ctor [no EVC]) remains item 10's job —
  this slice owns ONLY the S11 gate assertion. (No `wireVenueOperator` / `govSetFallbackOracle` — dissolved.)

**Spec/audit edits this ticket makes**
- **NONE expected.** §9 + audit/2.md S11 ALREADY specify the combined pre-gate (`getExpectedWorkflowId() != 0` AND
  `controller() != 0` before `renounceOwnership()`, aborting otherwise) and §4.4 already names the dormant-identity
  caveat + that the S11 pre-gate is the only defense. This slice REALIZES that mandate as a reusable assert + a
  tested negative — it is a TEST-AUTHORING + tiny-helper item, NOT a spec gap. (If the cold-build/critics surface a
  genuine gap, triage to `claude-zipcode.md` FIRST per the harness; otherwise confirm-don't-invent.)

**Depends on**
WOOF-00 (scaffold + the `x402-cre-price-alerts/` remap), WOOF-02 (`ZipcodeOracleRegistry` — the `controller()`
getter + `setController` set-once), WOOF-05 (`ZipcodeController` — `is ReceiverTemplate`, the 5-arg ctor [no EVC], the
inherited identity setters + `renounceOwnership`), WOOF-01 (`LienTokenFactory` — the
controller ctor's `lienFactory` arg), WOOF-04 (`IZipcodeVenue`/`EulerVenueAdapter` — the controller ctor's `venue`
arg; stubbable here since origination is not exercised). **Downstream:** the full **item 10 deploy/wiring script**
absorbs `ZipcodeDeployAsserts.requireIdentityWired(ZIP_CONTROLLER, ZIP_ORACLE_REG)` at S11, immediately before the
two `renounceOwnership()` calls (and may add a redundant `requireIdentityWired(ZIP_ORACLE_REG, ZIP_ORACLE_REG)`).

**Cross-ticket obligations this ticket DISCHARGES (the gate portion only):**
1. **Item 10 (WOOF-05 row, F-3) — gate portion TESTED.** The renounce-before-identity defense is now a reusable
   assert + a proven negative; item 10 imports it. The row's OTHER clause (deploy the controller with the 5-arg
   ctor [no EVC]) stays OPEN. (There is **no** `wireVenueOperator`-before-renounce clause — the borrower-model
   rework dissolved it; the per-line operator grant is issued inside `openLine` by WOOF-04's `LineAccount`.)
2. **Item 10 (WOOF-02 row, F7) — gate portion TESTED.** The `controller() != 0` clause of the same combined assert
   is proven. The row's OTHER clause (`setController`@S6 wiring) stays OPEN. (The old `govSetFallbackOracle`@S10
   clause is dissolved — the per-line-router redesign removed the shared router; per-line `ROUTER_i` is wired to
   the registry inside `openLine`, §4.7.)
