# SEC-05 — Seal the CRE-push lpOracle's workflow identity (M4)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` M4; `build/fair-lp.md`; audit `findings.md` (F1/F3
dormant-identity), `role-based-findings.md`; `contracts/src/ZipcodeDeployAsserts.sol` · **Status:** PROPOSED

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
