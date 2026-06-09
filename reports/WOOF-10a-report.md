# WOOF-10a — Deploy identity pre-gate (§9 S11, security F7/F-3) — MATERIALIZED + BUILT-VERIFIED

**Status:** **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (keep-the-build doctrine). **Item:** WOOF-10a — the S11
renounce-before-identity deploy pre-gate (`ZipcodeDeployAsserts`, a slice of item 10, §9). **Branch:** `main`.
**Outcome:** materialized from the ticket alone against the live on-disk WOOF-00..05 keepsakes; `forge build`
green; **5/5 new tests pass** (107/107 total, no regression; independently re-run + source read by the
superintendent). Code **KEPT** at `contracts/src/ZipcodeDeployAsserts.sol` +
`contracts/test/ZipcodeDeployIdentityGate.t.sol`.

> Supersedes the prior 2026-06-05 **cold-build** report (6/6, byproduct discarded under the retired
> discard-the-byproduct doctrine). Under keep-the-build, the gate is now committed code; the verdict is
> "compiles + tests green against the real keepsakes + the two read interfaces verified against the on-disk
> WOOF-02/05 source." (The new materialization is 5 tests, not the old 6 — same three classes, the dormancy demo
> consolidated into one selector-difference test; coverage is equivalent.)

## TL;DR
- **Proves the highest real risk in the system (HIGH)** — the F-3/F7 renounce-before-identity vuln — with a REAL
  test against the REAL receivers, not a paper obligation left for item 10. `ReceiverTemplate.onReport`'s
  workflow-identity check is conditional and `onReport`/`setForwarderAddress` are non-virtual, so a deploy that
  renounces before wiring identity freezes the receiver in a Forwarder-sender-only state any co-tenant workflow
  can drive; renouncing before `registry.setController` leaves the registry unseedable. The only defense is a
  deploy-time pre-gate at S11, which this slice delivers + tests.
- **Zero-spec-guess keepsake confirmed.** The library is exactly the ticket's body; every signature it reads
  (`getExpectedWorkflowId()` on the controller, `controller()` on the registry) matched the real on-disk source.
  No `claude-zipcode.md` edit (§9 + audit S11 + §4.4 already mandate the combined gate — realized, not invented).
- **Code kept; no fork needed** (the gate is a pure view; the registry ctor's `quote.decimals()` is satisfied by a
  6-dp mock; the controller ctor only stores immutables).

## Build evidence (REAL forge output, observed + independently re-run)
- `forge build` → **Compiler run successful!** (solc 0.8.24; only pre-existing lint notes).
- `forge test --match-path test/ZipcodeDeployIdentityGate.t.sol -vv` (no fork, 852µs) →
  ```
  [PASS] test_NegativeControl_DormantVsActiveIdentity_SelectorDifference()
  [PASS] test_Negative_BothUnset_GateReverts()
  [PASS] test_Negative_ControllerUnset_GateReverts()
  [PASS] test_Negative_IdentityUnset_GateReverts()
  [PASS] test_Positive_GatePasses_ThenRenounce_ThenFrozen()
  Suite result: ok. 5 passed; 0 failed; 0 skipped
  ```
- Full suite `source .env && forge test --fork-url "$BASE_RPC_URL"` → **Ran 6 test suites: 107 tests passed, 0
  failed, 0 skipped.** Was 102 (WOOF-00..05) + 5 = 107. No regression.

### The library (`src/ZipcodeDeployAsserts.sol`)
`library ZipcodeDeployAsserts` with `error IdentityNotWired(address controller, address registry)` and
`function requireIdentityWired(address controller, address registry) internal view` — combined fail-closed:
reverts if EITHER `IReceiverIdentity(controller).getExpectedWorkflowId() == bytes32(0)` (F-3 dormancy) OR
`IOracleRegistryController(registry).controller() == address(0)` (F7 brick). Two inline read interfaces; no state,
no storage, no constructor; GPL-2.0-or-later + pragma 0.8.24; `if/revert` (not `require(cond, CustomError())` —
0.8.26+). `internal` so it compiles INTO item 10's deploy script (no extra deployed bytecode).

### Test coverage (all 5 green — the full three-class "Done when" plan)
- **NEGATIVE (the obligations' required negative), 3 cases** via a `GateHarness` external wrapper (so
  `vm.expectRevert` can target the `internal` lib call): identity-unset (registry seeded, id 0), controller-unset
  (id set, registry unseeded), both-unset — each reverts the exact
  `IdentityNotWired(address(controller), address(registry))` selector+args, with positive state pre-assertions.
- **POSITIVE:** set `setExpectedAuthor` + `setExpectedWorkflowId` (S10b) + `registry.setController` (S6) → gate
  passes (no revert) → `controller.renounceOwnership()` succeeds (`owner()==0`) → the three inherited owner-gated
  setters (`setForwarderAddress`/`setExpectedAuthor`/`setExpectedWorkflowId`) each revert
  `OwnableUnauthorizedAccount` → `registry.renounceOwnership()` + frozen `setController` likewise.
- **NEGATIVE-CONTROL (the dormancy the gate prevents):** the selector-difference proof on REAL controllers —
  dormant (identity unset + renounced) → a wrong-`workflowId` reportType-3 `onReport` gets PAST the skipped
  identity gate and reverts `UnsupportedReportType(3)` (dispatch); gate-active (a second non-renounced controller
  with `setExpectedWorkflowId(WID)`) → the SAME report reverts `InvalidWorkflowId(WRONG_WID, WID)` (identity gate
  fires first). `metadata` built with `abi.encodePacked(WRONG_WID, bytes10(0), WORKFLOW_OWNER)` per the
  `_decodeMetadata` fixed offsets 32/64/74.

## On-chain / interface verification (the step the doc layer can't do)
- **No external addresses, no fork.** The library reads only two view getters on the on-disk WOOF-02/05 keepsakes;
  the test deploys the REAL `ZipcodeOracleRegistry`/`ZipcodeController`/`LienTokenFactory` + a 6-dp `MockUSDC` + EOA
  stubs for venue/erebor (origination never exercised). Both getters' signatures were confirmed against the real
  on-disk source.
- **Source independently read** by the superintendent: the combined fail-closed check, the `internal view` shape,
  and the dormancy selector-difference assertions in the test all confirmed by reading the two files (not just
  trusting the build subagent).
- **Observed revert selectors** (all asserted in tests): `IdentityNotWired` (×3 negative), `OwnableUnauthorizedAccount`
  (frozen setters post-renounce), `UnsupportedReportType(3)` (dormant — identity skipped), `InvalidWorkflowId`
  (gate-active — identity fired).

## Guesses / boundary (honest)
- **Zero load-bearing spec-guesses.** The cosmetic choices: EOA stubs for venue/erebor/forwarder/workflow-owner
  (the ticket explicitly authorizes any non-zero address), a 6-dp `MockUSDC` for the registry quote (matches the
  ticket's `USDC_MOCK`), the `GateHarness` external wrapper (ticket-specified verbatim), and including
  `setExpectedAuthor` in the POSITIVE path (the gate only reads `getExpectedWorkflowId()`, so it is belt-and-braces).
- **Boundary:** this slice delivers ONLY the S11 gate assertion + its proof. The full S1–S12 deploy/wiring
  (5-arg ctor [no EVC], `setController`@S6, curator/timelock-0, `baseUsdcMarket`, the sequenced `renounceOwnership()`
  calls) remains item 10's job.

## Doc updates done (this window)
- `tickets/woof/WOOF-10a-deploy-identity-gate.md` — added the MATERIALIZED + BUILDS GREEN banner.
- `reports/WOOF-10a-report.md` — this report (rewritten from the cold-build report to the kept-code verdict).
- `reports/README.md` — WOOF-10a row note → MATERIALIZED + BUILT-VERIFIED.
- `tickets/LEDGER.md` — WOOF-10a digest extended with the materialization.
- `tickets/PROGRESS.md` — backlog row 10a → BUILT-VERIFIED; the two item-10 F7/F-3 rows confirmed GATE-PORTION
  TESTED + KEPT; session-log entry.
- `superintendent-auditor.md` — CURRENT STATE + worklist row → BUILT-VERIFIED.
- **No `claude-zipcode.md` edit** (no spec error — zero-spec-guess keepsake confirmed).

## Status & next
WOOF-10a is **BUILT-VERIFIED + kept on disk** (5/5, 107/107 total). The **pure-Euler M1 contract spine is now all
real on disk: WOOF-00, 01, 02, 03, 04, 05, 10a.** The remaining code-UNVERIFIED items both have external
dependencies: **WOOF-06** (`ZipDepositModule`) builds against mocks for the still-unbuilt 8-B2 `depositFor` + 8-Bw
`CreditWarehouse` seams; **INFLOW-06** is a frontend interface ticket verified vs `reference/euler-lite`, not
`forge`. The full **item 10 deploy/wiring script** (which absorbs this gate at S11) is the natural next contract
once the supply-side (item 7/8) lands.
