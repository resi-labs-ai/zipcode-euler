# SEC-05 — Seal the CRE-push lpOracle's workflow identity (M4)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` M4; `build/fair-lp.md`; audit `findings.md` (F1/F3
dormant-identity), `role-based-findings.md`; `contracts/src/ZipcodeDeployAsserts.sol` · **Status:** DONE 2026-06-15

> Scope authored 2026-06-15. Deploy-script + assert-library fix. Both additions are **conditional on
> `d.lpOracle != address(0)`** — the trustless fair-LP branch (`lpTwapWindow > 0`) deploys an ownerless
> `AlgebraIchiFairLpOracle` (not a `ReceiverTemplate`, no identity to seal); only the CRE-push branch
> (`lpTwapWindow == 0`, the M1/mainnet default) has an `SzipReservoirLpOracle` to seal.

## Deliverable
Seal the CRE workflow identity (`setExpectedAuthor` + `setExpectedWorkflowId`) on the CRE-push
`SzipReservoirLpOracle` in P9, and extend the fail-closed deploy pre-gate to assert that identity — both
guarded by `d.lpOracle != address(0)`.

## What it does / what's being fixed (plain language)
`SzipReservoirLpOracle` is a CRE receiver (`ReceiverTemplate`): the Forwarder pushes it the per-LP-share USD
mark that prices the junior LP leg and gates the reservoir market. `ReceiverTemplate.onReport`'s
workflow-identity check is **conditional** — it only runs when `expectedAuthor`/`expectedWorkflowId` are
non-zero. The deploy's P9 seal loop sets those on every other receiver but **omits the lpOracle**, so its
identity stays zero and the check is dormant: any co-tenant workflow that clears the shared Forwarder can
push an LP mark. The fail-closed pre-gate that runs before ownership transfer only checks the controller as a
"representative" receiver — which never covers the un-looped lpOracle.

## Binds to (verified file:line — 2026-06-15)
- **P5 deploy (the receiver to seal):** `contracts/script/DeployZipcode.s.sol:349-357` — when
  `i.lpTwapWindow == 0`, `d.lpOracle = new SzipReservoirLpOracle(...)` (`:353-356`); when `> 0`,
  `AlgebraIchiFairLpOracle` is built and `d.lpOracle` stays unset (`:350-351`).
- **P9 seal loop (the gap):** `contracts/script/DeployZipcode.s.sol:526-531` — `_sealIdentity` is called on
  controller/registry/adapter/coord/navOracle/rateOracle, **not** on `d.lpOracle`.
- **`_sealIdentity`:** `:594-598` — `setExpectedAuthor(i.workflowAuthor)` + `setExpectedWorkflowId(i.workflowId)`.
- **Pre-gate:** `contracts/src/ZipcodeDeployAsserts.sol:38-43` — `requireIdentityWired(controller, registry)`
  checks `controller.getExpectedWorkflowId() != 0` && `registry.controller() != 0`. Called at
  `DeployZipcode.s.sol:534`. Interface `IReceiverIdentity.getExpectedWorkflowId()` `:7-9`.
- **Receiver type confirmed:** `contracts/src/supply/SzipReservoirLpOracle.sol:4,21` — `is ReceiverTemplate`
  (has `setExpectedAuthor`/`setExpectedWorkflowId`/`getExpectedWorkflowId`).
- **Already-Ownable conditional precedent (mirror its guard):** `:543-544` —
  `if (address(d.lpOracle) != address(0)) d.lpOracle.transferOwnership(tl);`.
- **Sealing-a-LpOracle precedent:** `DeployShowcaseVAMM.s.sol:77-78` (`oracle.setExpectedAuthor/WorkflowId`).

## Key requirements
1. **Seal in P9.** In the `:526-531` block add:
   `if (address(d.lpOracle) != address(0)) _sealIdentity(address(d.lpOracle));`
   (mirrors the `:544` conditional). Must run BEFORE the pre-gate (`:534`) and the ownership transfers (`:536+`).
2. **Extend the pre-gate.** Add a single-receiver identity assert to `ZipcodeDeployAsserts` — recommended a
   sibling `requireReceiverIdentityWired(address receiver)` that reverts (e.g. `IdentityNotWired(receiver,
   receiver)` or a new dedicated error) when `IReceiverIdentity(receiver).getExpectedWorkflowId() == bytes32(0)`
   — and call it from P9 conditionally: `if (address(d.lpOracle) != address(0))
   ZipcodeDeployAsserts.requireReceiverIdentityWired(address(d.lpOracle));`. (Do not break the existing
   two-arg `requireIdentityWired(controller, registry)` signature / its `:534` call.)
3. **Both additions conditional on `d.lpOracle != address(0)`** so the fair-LP branch (no `SzipReservoirLpOracle`)
   neither seals nor asserts and the deploy still completes.

## Do NOT
- Do NOT seal/assert unconditionally — the fair-LP `AlgebraIchiFairLpOracle` has no identity surface and
  `d.lpOracle == address(0)` there; an unconditional call reverts that branch.
- Do NOT fold the lpOracle into the existing `requireIdentityWired(controller, registry)` "representative"
  assertion (the S10b same-WORKFLOW_ID-loop assumption does not hold for the un-looped lpOracle) — add the
  explicit per-receiver check.
- Do NOT change the lpOracle constructor / make identity a constructor arg — the seal is a P9 post-deploy step,
  matching every other receiver.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean (script + assert library compile).
- `forge test` green, **plus a new `SEC05_*` regression test** that fails before / passes after, on the
  CRE-push branch (`lpTwapWindow == 0`):
  - **Identity sealed:** after a full deploy, assert `d.lpOracle.getExpectedWorkflowId() == WORKFLOW_ID`
    (non-zero) — pre-fix it is `bytes32(0)`.
  - **Behavioral fail-closed:** a Forwarder-delivered LP-mark report bearing a **wrong author/workflowId** is
    REJECTED post-fix (pre-fix it is accepted because the check is dormant).
  - **Pre-gate bites:** with the lpOracle identity left unset, the extended pre-gate reverts (the deploy
    fail-closes before ownership transfer).
  - **Fair-LP branch unaffected:** a deploy with `lpTwapWindow > 0` (`d.lpOracle == address(0)`) completes
    with no seal/assert attempted and no revert.
- Quote the actual `forge test` output in this ticket's done note. (`DeployZipcode.t.sol` exists — extend it
  or add a focused test; the local `DeployLocal` path uses `lpTwapWindow == 0`, so the CRE-push branch is the live one.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-05" with the finding note.

---

## DONE note (2026-06-15)
**M4 closed — the un-looped CRE-push `lpOracle` identity is now sealed AND fail-closed pre-gated.** Two files
changed, exactly per Key requirements (no scope widening):

- **`src/ZipcodeDeployAsserts.sol`** — added `error ReceiverIdentityNotWired(address receiver)` + the sibling
  `requireReceiverIdentityWired(address receiver)` `internal view` (reverts when
  `IReceiverIdentity(receiver).getExpectedWorkflowId() == bytes32(0)`). The existing two-arg
  `requireIdentityWired(controller, registry)` + its `:534` call are byte-for-byte untouched (Do-NOT honored).
- **`script/DeployZipcode.s.sol` P9** — after the six-receiver seal loop: `if (address(d.lpOracle) != address(0))
  _sealIdentity(address(d.lpOracle));` (`:535`); after the `requireIdentityWired` pre-gate: `if (address(d.lpOracle)
  != address(0)) ZipcodeDeployAsserts.requireReceiverIdentityWired(address(d.lpOracle));` (`:542`). Both guarded on
  `!= address(0)`, mirroring the `:544` `transferOwnership` conditional — the fair-LP branch (no
  `SzipReservoirLpOracle`) neither seals nor asserts and the deploy completes. The lpOracle ctor is unchanged
  (seal is a P9 post-deploy step, Do-NOT honored).

**Regression — 7 `test_SEC05_*` in `test/ZipcodeDeployIdentityGate.t.sol`** (its existing `MockUSDC` reused; new
`LpGateHarness` external wrapper for the `internal` single-arg lib fn; a REAL `SzipReservoirLpOracle`, no fork — its
ctor only reads `quote.decimals()`):
- `IdentitySealed_AfterSeal` — `getExpectedWorkflowId()` is `bytes32(0)` pre-seal, `== WID` post-seal.
- `Behavioral_DormantAcceptsWrongIdentity` — the **vuln**: an unsealed oracle ACCEPTS a wrong-workflowId `LP_MARK`
  push from the Forwarder (cache written).
- `Behavioral_SealedRejectsWrongIdentity` — the **fix**: once sealed, the SAME push reverts
  `InvalidWorkflowId(WRONG_WID, WID)`, no cache write.
- `Behavioral_SealedAcceptsCorrectIdentity` — no false-positive lockout: the authorized workflow still pushes through.
- `PreGate_RevertsWhenIdentityUnset` — `requireReceiverIdentityWired` reverts `ReceiverIdentityNotWired(oracle)`.
- `PreGate_PassesWhenSealed` — passes (no revert) once sealed.
- `FairLpBranch_GuardSemantics` — pins that the script's `!= address(0)` guard is what keeps the ownerless fair-LP
  branch from fail-closing (the full fair-LP deploy path is the skipped WOOF-10 fork harness's bar).

⚠️ **These 7 unit tests prove the FIX MECHANISM (the gate + that sealing closes the hole) but do NOT run the deploy
script — they construct + seal a standalone oracle.** So they cannot, by themselves, prove P9 actually performs the
seal. (An earlier draft of this note claimed "commenting out the `:535` seal flips the behavioral test" — that was
WRONG: those tests never touch the script, so the edit had no effect on them.) The script wiring is verified
separately, end-to-end, below.

**End-to-end verification — genuine fail-before/pass-after through the REAL deploy script (`DeployLocal` is
`DeployZipcode`; `_phaseP9` runs verbatim; its `_phaseP5` override always takes the CRE-push branch ⇒ `d.lpOracle`
is set):**
- **Before (the real deployed vuln):** the live `:8545` anvil stack (deployed 2026-06-10, pre-fix) — its lpOracle
  `0x4505…0D42` reads `getExpectedWorkflowId() == 0x0` and `getExpectedAuthor() == 0x0` (dormant identity, the M4
  hole, confirmed via `cast call`).
- **After (the fix):** a fresh Base-fork `DeployLocal` broadcast with this working tree → the same-nonce lpOracle
  `0x4505…0D42` reads `getExpectedWorkflowId() == 0x…01` (the local `WORKFLOW_ID`), `getExpectedAuthor() ==
  0x90F7…b906` (the `workflowAuthor`), `owner() == 0x89ae…3B27` (the Timelock). **Sealed.**
- **Fail-closed (the pre-gate bites in the real deploy):** removing ONLY the `:535` seal call (leaving the `:542`
  assert) and re-broadcasting `DeployLocal` to a fresh fork → the deploy **reverts**
  `ReceiverIdentityNotWired(0x4505…0D42)` at the pre-gate, fail-closing **before** any ownership transfer.

**`forge build` clean.**

**Gate output (`forge test`):**
```
Ran 52 test suites: 781 tests passed, 0 failed, 3 skipped (784 total tests)
```
(+7 over SEC-04's 774 = the 7 new `test_SEC05_*`; the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold.)
Focused suite: `Ran 2 test suites ... 12 tests passed` (the 5 pre-existing `ZipcodeDeployIdentityGateTest` +
7 new `SEC05LpOracleIdentityTest`).

**No spec change** (interface-level deploy fix; §9/§17 intent unchanged — the spec already prescribed sealing every
receiver's identity; this fences the one receiver the seal loop omitted). **No back-pressure / no new obligation**
(no contract surface owed; the fix uses the receiver's existing `setExpected*` surface + a new deploy-time library
fn). The existing **WOOF-10 deploy-bar obligation** (the skipped `DeployZipcode.t.sol` full-fork run) is unchanged —
SEC-05 does not un-skip it; it adds a no-fork focused regression instead.
