# WOOF-05 — `ZipcodeController` (§4.4) — MATERIALIZED + BUILT-VERIFIED

**Status:** **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (keep-the-build doctrine). **Item:** WOOF-05
(`ZipcodeController`, §4.4) — the portable-core orchestrator + CRE receiver. **Branch:** `main`.
**Outcome:** materialized from the ticket alone against the live on-disk WOOF-00..04 scaffold; `forge build`
green; **26/26 new tests pass on a live Base-mainnet fork** (102/102 total, no regression; independently re-run
by the superintendent). Code **KEPT** at `contracts/src/ZipcodeController.sol` + `contracts/test/ZipcodeController.t.sol`.

> Supersedes the prior 2026-06-05 re-author **cold-build** report (17/17, byproduct discarded). That report was
> written under the retired discard-the-byproduct doctrine. Under keep-the-build, the controller is now committed
> code and the verdict is "compiles + tests green on a live fork + interfaces verified against the on-disk deps."

## TL;DR
- **Materialized faithfully — zero-spec-guess keepsake confirmed.** The ticket's claim of "no `claude-zipcode.md`
  edit / signatures match / zero load-bearing guesses" is **confirmed by the real build**. No contradiction, wrong
  address, or wrong external signature surfaced (unlike WOOF-00). Every external signature the controller calls was
  re-verified against the real on-disk WOOF-01/02/03/04 source, not the ticket's quotes.
- **The central subtraction holds on disk.** The controller imports ONLY `ReceiverTemplate` +
  `IZipcodeVenue` (+ three inline local interfaces `ILienTokenFactory`/`ILienToken`/`IZipcodeOracleRegistry`). It
  has **no EVC import, no EVC immutable, no `wireVenueOperator`, no `setOperator`/`setAccountOperator` call** — it
  touches **no EVC type at all**. 5-arg ctor `(forwarder, venue, lienFactory, oracleRegistry, erebor)`, NO EVC.
- **The re-author proof is live-fork-proven.** A `reportType 1` origination produces a live EVK debt with NO
  controller operator-wiring; the borrow is authorized solely because the adapter's per-line `LineAccount` granted
  **the adapter** the EVC operator bit inside `openLine`. Asserted directly:
  `isAccountOperatorAuthorized(borrowAccount, adapter) == true` AND `(…, controller) == false`.
- **Code kept, byproduct doctrine retired.** `contracts/src/ZipcodeController.sol` (was a 2-line stub) +
  `contracts/test/ZipcodeController.t.sol` (new, 680 lines, 26 tests) are committed.

## Build evidence (REAL forge output, observed + independently re-run)
- `forge build` → **Compiler run successful!** (solc 0.8.24; only pre-existing lint notes).
- `source .env && forge test --fork-url "$BASE_RPC_URL"` →
  ```
  Suite result: ok. 8 passed   (CREGatingHook)
  Suite result: ok. 14 passed  (LienToken)
  Suite result: ok. 34 passed  (ZipcodeOracleRegistry)
  Suite result: ok. 26 passed  (ZipcodeController)   <-- NEW
  Suite result: ok. 20 passed  (EulerVenueAdapter)
  Ran 5 test suites: 102 tests passed, 0 failed, 0 skipped
  ```
  The pre-existing 76 (8+14+34+20) are intact + the new 26 = 102. No regression.

### Harness (verified genuine live-fork)
Live Base-mainnet `EVC`/`EVAULT_FACTORY`/`USDC` (from `BaseAddresses.sol`), real WOOF-01/02/03/04 contracts on
disk (incl. the per-line `LineAccount` the adapter deploys inside `openLine`), live `GenericFactory.createProxy`
for the base USDC market. The controller↔venue↔hook ctor cycle is broken with `vm.computeCreateAddress(this,
n+2)` and the prediction is **asserted** (`assertEq(address(adapter), predictedAdapter)`). `EulerEarn` is **mocked**
(pragma 0.8.26 — cannot `new` under 0.8.24); the mock actively deposits the funded delta into the live line vault
on `reallocate` (the ticket's sanctioned recipe — "the IEulerEarn mock deposits `amount` USDC into the borrow
vault so the live borrow has real cash"). The hook is wired `borrowDriver = address(adapter)`. The controller is
the genuine **unit under test** (no mock controller).

### Test coverage (all 26 green — the full ticket "Done when" list)
- **Live borrow / no-operator-wiring proof** (`test_LiveBorrow_NoControllerOperatorWiring`): live debt
  `== DRAW_AMOUNT`; adapter is the operator, controller is not.
- **Origination L4 full transcript** + **events**: `lien == computeAddress(lienId, controller)`,
  `totalSupply==1e18`, `decimals==18`, escrow holds **exactly** `1e18`, `getQuote(1e18,LIEN,USDC)==equityMark`,
  both LTVs (1e4), `debtOf(borrowAccount)==drawAmount`, `USDC.balanceOf(EREBOR)==drawAmount`, `allowance==0`
  (F-7), and `LienCreated`/`RegistryPriceSeed`/`LienOriginated` events.
- **Batch-atomicity** (the controller's signature test): over-LTV → **exact** `E_AccountLiquidity()` (NOT
  `E_InsufficientCash` — proves the mock pre-funds and the LTV gate is what fires); mid-batch `equityMark=0`
  rolls back the CREATE2 deploys (re-origination with the same `lienId` then succeeds, proving the `LineAccount`
  slot freed); cap-only → **exact** `E_BorrowCapExceeded()`. Each asserts the full no-orphan post-state
  (`predictedLien.code.length==0`, no record, no orphan seed via `getQuote` revert).
- **Draw (a′):** exact accrual `d0 + drawAmount2`; re-anchor-below-LTV rollback (mark + debt unchanged);
  `UnknownLien` on unknown + closed lines.
- **Close (L7/L8):** permissionless repay zeroes debt (and cannot *add* debt); type-4 close reclaims via the
  operator-routed redeem, `burn(1e18)` → supply 0, escrow drained, `open==false`; `DebtOutstanding` with state
  unchanged; double-close + never-opened → `UnknownLien`; **burn-after-reclaim sequencing** (`closeLine` mocked
  no-op → `burn` reverts `ERC20InsufficientBalance`).
- **Dispatch + dup:** reportType 3 → `UnsupportedReportType(3)`; 0/7/255 rejected; truncated payload reverts
  (inner `abi.decode` bounds-check); duplicate origination → `LienExists`, no double-mint.
- **Default/Liquidation markers:** 5/6 emit ONLY `LienStatusUpdated`, no state change, `liquidate` mock-reverted
  to prove it is never reached.
- **Authority + dormant-gate:** non-Forwarder → `InvalidSender`; the dormancy demo (wrong `workflowId` ACCEPTED
  while expectations unset — reaches the dispatcher → `UnsupportedReportType(3)`; after `setExpectedWorkflowId` →
  `InvalidWorkflowId`); post-renounce setters → `OwnableUnauthorizedAccount`.
- **Reentrancy structurally impossible:** a `ReentrantVenue` whose `openLine` re-enters `onReport` has the
  reentrant call rejected by the Forwarder gate (`reentered == false`).

## On-chain / interface verification (the step the doc layer can't do)
- **No new external interfaces or hardcoded addresses introduced by the controller.** It calls only the on-disk
  Zipcode deps (factory/token/registry/venue) via local interfaces; the live Euler addresses it transitively
  touches (EVC/EVAULT_FACTORY/USDC) were already on-chain-verified in the WOOF-00/04 passes. The integration
  passing on a **live Base fork** against the already-verified WOOF-04 venue discharges the on-chain-verify burden.
- **Error selectors re-verified with `cast sig`:** `E_AccountLiquidity()` = `0x34373fbc`,
  `E_BorrowCapExceeded()` = `0x6ef90ef1`, `E_InsufficientCash()` = `0xf077d877` (the one that must NOT surface in
  the over-LTV test — confirming the pre-fund), `NotAuthorizedOperator()` = `0x3d9adf1c` (the WOOF-03 hook).
- **Source independently read** by the superintendent (not just trusting the build subagent): the
  `create→openLine→seed→setLineLimits→fund→draw` ordering, the reclaim-before-burn close path, the
  reportType-3-rejected dispatch, and the zero-EVC-coupling are all confirmed by reading
  `contracts/src/ZipcodeController.sol`.

## Guesses / boundary (honest)
- **Zero load-bearing spec-guesses** (the keepsake held). Two test-harness isolation choices (not contract gaps):
  (1) the reentrancy test `vm.mockCall`s the registry `seedPrice` for the second (non-registered) controller `c2`
  so the outer batch completes deterministically and the reentrancy signal is isolated — the load-bearing fact
  (the reentrant `onReport` is rejected by the Forwarder gate) is unaffected; (2) the `MockEulerEarn.reallocate`
  deposit recipe is the ticket's prescribed funding pattern, not a guess.
- **Boundary (still mocked / not exercised here):** `EulerEarn` is a recording mock (the live EE path is the
  audit S9/L4 / item-10 deploy concern); the `fund` two-item `reallocate` allocation args are mock-recorded (the
  cash deposit into the line vault is the live leg). reportType 2/5/6 are exercised by these unit tests but are
  ABI-complete-only in the `audit/2.md` Phase L acceptance harness (only 1 and 4 are in Phase L).

## Doc updates done (this window)
- `tickets/woof/WOOF-05-controller.md` — added the MATERIALIZED + BUILDS GREEN banner.
- `reports/WOOF-05-report.md` — this report (rewritten from the re-author cold-build report to the kept-code verdict).
- `reports/README.md` — WOOF-05 row note → MATERIALIZED + BUILT-VERIFIED.
- `tickets/LEDGER.md` — WOOF-05 digest extended with the materialization.
- `tickets/PROGRESS.md` — backlog row → BUILT-VERIFIED; obligations confirmed discharged; session-log entry.
- `README.md` — the `ZipcodeController` checklist box checked.
- `superintendent-auditor.md` — CURRENT STATE + worklist row → BUILT-VERIFIED.
- **No `claude-zipcode.md` edit** (no spec error surfaced — zero-spec-guess keepsake confirmed).

## Status & next
WOOF-05 is **BUILT-VERIFIED + kept on disk** (26/26 live-fork, 102/102 total). Per the superintendent-auditor
worklist, the next code-UNVERIFIED items are **WOOF-06** (`ZipDepositModule` — build against mocks for the 8-B2
`depositFor` + 8-Bw `CreditWarehouse` seams, both still unbuilt), **INFLOW-06** (frontend interface — verify vs
`reference/euler-lite`), and **WOOF-10a** (deploy identity pre-gate — needs the real WOOF-02 + WOOF-05 on disk,
both now present). The pure-Euler M1 contract spine (00–05, 10a) is otherwise materializable now.
