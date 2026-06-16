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
- **Two-layer verification** (the unit tests alone are NOT sufficient — see Correction below):
  - **Unit (mechanism):** the 7 `test_SEC05_*` prove the new gate (negative/positive) and that sealing a REAL
    `SzipReservoirLpOracle` closes the dormant hole. They do **not** run the deploy script.
  - **End-to-end (script wiring), via `DeployLocal` on a fresh Base-fork anvil** — `DeployLocal` is `DeployZipcode`,
    so `_phaseP9` runs verbatim and its `_phaseP5` override always builds `d.lpOracle` (CRE-push branch):
    - **before** — the live `:8545` pre-fix stack's lpOracle `0x4505…0D42`: `getExpectedWorkflowId()==0x0`,
      author `0x0` (the real deployed dormant vuln, via `cast call`);
    - **after** — a fresh broadcast with this fix: same-nonce lpOracle reads `getExpectedWorkflowId()==0x…01`,
      author `0x90F7…b906`, `owner()==0x89ae…3B27` (Timelock) — sealed;
    - **fail-closed** — removing ONLY the `:535` seal (leaving the `:542` assert) → `DeployLocal` reverts
      `ReceiverIdentityNotWired(0x4505…0D42)` at the pre-gate, before any ownership transfer.

## Correction (added after reviewer challenge)
The first version of this report (and the ticket/PROGRESS/kill-list notes) claimed "commenting out the `:535` seal
flips `test_SEC05_Behavioral_SealedRejectsWrongIdentity` back to accepting the wrong-id push." **That was wrong.**
Those 7 unit tests construct + seal a *standalone* oracle (`_seal()`); they never invoke the deploy script, so
editing the script has zero effect on them — they pass in both states. The unit tests prove the fix *mechanism* but
cannot prove the *script wires the seal*. I closed that gap by running the genuine deploy-script gate (`DeployLocal`
against a fresh Base-fork anvil, the PROGRESS-mandated gate for deploy-script tickets), which gives the real
fail-before/pass-after summarized above. The user's challenge on decisions 1–2 was correct; both are now resolved by
the end-to-end run rather than deferred.

## Decisions to sanity-check
1. **New per-receiver gate vs folding into the existing assert.** Added a dedicated
   `requireReceiverIdentityWired(address)` rather than extending `requireIdentityWired(controller, registry)` — the
   ticket's Do-NOT (the S10b same-WORKFLOW_ID-loop assumption does not hold for the un-looped lpOracle, and changing
   the two-arg signature would break the `:534` call). This matches the audit B3 note that the controller-only check
   "can't catch this".
2. **Test layering: unit (mechanism) + DeployLocal (script wiring).** Initially I treated the no-fork unit tests as
   sufficient and deferred the full-deploy run to WOOF-10. That was a mis-judgement: the unit tests cannot prove P9
   seals `d.lpOracle`. The `DeployZipcode.t.sol` *in-process* harness is indeed a skipped WOOF-10 scaffold, but the
   **`DeployLocal` broadcast against anvil** (which `is DeployZipcode` and runs `_phaseP9` verbatim) is available and
   is the PROGRESS-mandated gate for deploy-script tickets — so I ran it (fresh ephemeral Base-fork on a separate port,
   leaving the user's `:8545` node untouched). That run is what now backs the fail-before/pass-after; the unit tests
   are the mechanism layer beneath it.
3. **Fair-LP branch (`lpTwapWindow > 0`).** Still the one deploy *permutation* not run end-to-end (DeployLocal only
   exercises the CRE-push branch). It is a literal one-line guard read (`if (address(d.lpOracle) != address(0))`,
   identical to the already-exercised `:544` `transferOwnership` conditional; `d.lpOracle` is never assigned on that
   branch), and `test_SEC05_FairLpBranch_GuardSemantics` pins the guard's load-bearing half. A full fair-LP DeployLocal
   variant would close it completely; given the guard is a verbatim mirror of an exercised one, I judged that
   disproportionate. Flagging it explicitly rather than claiming coverage I don't have.

## Holes → resolution
- **Hole (was the main one):** the unit tests don't exercise the deploy script, so on their own they don't prove the
  script seals the lpOracle. **Resolved:** ran `DeployLocal` against a fresh Base-fork anvil — pre-fix live deploy
  shows `getExpectedWorkflowId()==0x0`, post-fix deploy seals it, and seal-removed deploy fail-closes at the pre-gate
  (`ReceiverIdentityNotWired`). This is the genuine deploy-script gate.
- **Residual:** the fair-LP-branch (`lpTwapWindow > 0`) deploy permutation is not run end-to-end (guard-by-construction
  only). Low risk (one-line guard mirroring an exercised one); a fair-LP DeployLocal variant would close it.

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
