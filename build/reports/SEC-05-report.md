# SEC-05 report — seal the un-looped CRE-push `lpOracle` identity + extend the deploy pre-gate (M4)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-06 (Group 3a / H2 —
`closeLine` supply-queue prune)

## What the window did
Closed kill-list **M4** / audit **ref-B (B3)**: `SzipReservoirLpOracle` is a `ReceiverTemplate` whose `onReport`
workflow-identity check is **conditional** — it only fires when `expectedAuthor`/`expectedWorkflowId` are non-zero.
The deploy's P9 seal loop set those on six receivers (controller, registry, warehouse adapter, coord, navOracle,
rateOracle) but **omitted the lpOracle**, and the fail-closed pre-gate (`requireIdentityWired`) only checked the
controller as a "representative" receiver under the S10b same-WORKFLOW_ID assumption — which never covers the
un-looped lpOracle. Result as-deployed: the lpOracle's identity stays `bytes32(0)` (dormant), so any co-tenant
workflow clearing the **shared** Keystone Forwarder could push an arbitrary `LP_MARK` → mismark reservoir collateral
→ over-borrow.

Two files changed (exactly the ticket's Key requirements; no scope widening):
- **`contracts/src/ZipcodeDeployAsserts.sol`** — added `error ReceiverIdentityNotWired(address receiver)` + the
  sibling `requireReceiverIdentityWired(address receiver)` `internal view` (reverts when
  `getExpectedWorkflowId() == bytes32(0)`). The two-arg `requireIdentityWired(controller, registry)` and its `:534`
  call are byte-for-byte untouched.
- **`contracts/script/DeployZipcode.s.sol`** P9 — `if (address(d.lpOracle) != address(0))
  _sealIdentity(address(d.lpOracle));` (`:535`) after the six-receiver seal loop, and `if (address(d.lpOracle) !=
  address(0)) ZipcodeDeployAsserts.requireReceiverIdentityWired(address(d.lpOracle));` (`:542`) after the existing
  pre-gate. Both guarded `!= address(0)`, mirroring the `:544` `transferOwnership` conditional.

Regression: 7 `test_SEC05_*` added to `contracts/test/ZipcodeDeployIdentityGate.t.sol` (new contract
`SEC05LpOracleIdentityTest` + a `LpGateHarness` external wrapper; reuses the file's `MockUSDC`; a REAL
`SzipReservoirLpOracle`, **no fork** — its ctor only reads `quote.decimals()`).

## Gate
- `cd contracts && forge build` — clean.
- `forge test` — **781 passed / 0 failed / 3 skipped (784 total)**, +7 over SEC-04's 774. The 3 skips are the
  pre-existing `DeployZipcode.t.sol` full-fork scaffold (untouched).
- Focused: `ZipcodeDeployIdentityGateTest` (5, pre-existing) + `SEC05LpOracleIdentityTest` (7, new) = 12 pass.
- **Fail-before/pass-after confirmed:** commenting out the `:535` seal call flips
  `test_SEC05_Behavioral_SealedRejectsWrongIdentity` back to accepting the wrong-workflowId push (reproduces the
  dormant vuln); restoring the seal re-closes it.

## Decisions to sanity-check
1. **New per-receiver gate vs folding into the existing assert.** Added a dedicated
   `requireReceiverIdentityWired(address)` rather than extending `requireIdentityWired(controller, registry)` — the
   ticket's Do-NOT (the S10b same-WORKFLOW_ID-loop assumption does not hold for the un-looped lpOracle, and changing
   the two-arg signature would break the `:534` call). This matches the audit B3 note that the controller-only check
   "can't catch this".
2. **No-fork focused regression instead of the full-deploy run.** The PROGRESS NEXT line and the kill-list driver
   mention "re-run `DeployLocal` against a fresh anvil fork" for deploy-script tickets, but `DeployZipcode.t.sol` is
   an all-`vm.skip(true)` WOOF-10 scaffold (stand-ins/broadcaster/`getDeployment()` not wired) — that full-fork run
   is WOOF-10's deploy-bar, not SEC-05's. I instead proved the fix where it is testable today: the new library
   function (negative/positive) and the **behavioral** dormant-accepts-vs-sealed-rejects pair on the REAL
   `SzipReservoirLpOracle`. This is the same no-fork approach the existing `ZipcodeDeployIdentityGateTest` uses for
   the controller/registry gate. Worth a reviewer nod that this is the right bar for SEC-05.
3. **Fair-LP branch (`lpTwapWindow > 0`) coverage.** The "fair-LP unaffected" Done-when bullet is a *script*
   conditional (`d.lpOracle == address(0)` → neither call executes), not a library behavior. With the full-deploy
   harness skipped, I covered it as guard-by-construction (`test_SEC05_FairLpBranch_GuardSemantics` pins that the
   `!= address(0)` guard is the thing keeping the ownerless branch from fail-closing) + the doc note. The end-to-end
   fair-LP deploy path remains the (skipped) WOOF-10 fork harness's responsibility.

## Holes → resolution
- **Hole:** could not exercise a full fork deploy to assert post-deploy `d.lpOracle.getExpectedWorkflowId() == WID`
  through the real `deploy()`. **Resolution:** asserted the seal semantics directly (the seal step is
  `setExpectedAuthor`+`setExpectedWorkflowId`, replicated in `_seal()`), and the script change is a literal mirror of
  the already-exercised `:544` guard. The full-deploy assertion folds into the WOOF-10 deploy-bar when its scaffold
  is un-skipped.

## Doc edits (doc-sync-checklist)
1. Ticket `sec/SEC-05-seal-lporacle-identity.md` → DONE + Done-note with quoted `forge test` output.
2. `PROGRESS.md` → SEC-05 row DONE, SEC-06 set NEXT (with deliverable/source/done-when), "Just done — SEC-05" note,
   the SEC-track summary line updated.
3. `kill-list.md` M4 → `[x]` + `DONE 2026-06-15 (SEC-05)`.
4. `audit-claude/SUMMARY.md` M4 row → `✅` + RESOLVED note; `audit-claude/reference-diff-findings.md` B3 → RESOLVED
   header + resolution line.
5. `wires/WOOF-10a.md` (owns `ZipcodeDeployAsserts`) → second fn + error added to the contract table and the wiring
   code block; `wires/DeployZipcode.md` → P9 seal row updated (lpOracle seal + per-receiver assert, both guarded).
6. **No `claude-zipcode.md` spec change** (interface-level deploy fix; §9/§17 intent unchanged).
7. This report.
8. Deletion triggers — none fire.

## Status + NEXT
SEC-05 DONE, committed with its gate green. **NEXT: SEC-06** (`closeLine` prunes the closed line's borrow vault from
the EE supply queue — Group 3a / H2). Note the standing concurrent-line-ceiling design obligation: SEC-06 reclaims
*closed*-line slots only, not the ~29 concurrent ceiling.
