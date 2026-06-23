# SUPPLY-ADV-04 — `DurationFreezeModule`: mirror the `setUp` Safe-distinctness guard into the two Safe setters

> **STATUS: BUILT (2026-06-23)** on `main`. Shipped: the `juniorTrancheSafe != juniorTrancheSidecar` re-check on
> both Safe setters (`DurationFreezeModule.setJuniorTrancheSafe`/`setJuniorTrancheSidecar`, reusing the existing
> `BadParams` error); regression test `test_setSafes_reject_collapse_to_equal` (distinct re-point succeeds; either
> collapse-to-equal reverts `BadParams`; zero-guard still fires). GATE: `forge build` clean + scoped suite
> **57/57** green (56 baseline + 1 new). Doc-sync: X-Ray `DurationFreezeModule.md` §4 guard row + §5 X-3 note. No
> divergence from the planned fix — the setters do NOT sync avatar/target (the illustrative snippet's avatar lines
> were correctly omitted from the real edit). Source: adversarial-review on
> `contracts/src/supply/szipUSD/DurationFreezeModule.sol`
> (`adversarial-review/reports/src/supply/durationfreezemodule/synthesis.md`, missions 3 + 5 converged).

> BUILD item (LOW). A guard-symmetry finding: `setUp` and `setOperator` each re-check their distinctness
> invariant, but the two Safe-pointer setters do not — so a Timelock misconfiguration can re-introduce the
> self-transfer degeneracy `setUp` exists to forbid, neutralizing the autonomous floor (I-1) in that state.
> Timelock-gated build-phase wiring (X-3), closed by the pre-prod immutable re-freeze — not a live exploit;
> ticketed because the fix is two lines matching the existing in-contract pattern and the X-Ray flags the
> 12 setters' effects as untested.

## The gap (verified in code)

`setUp` treats Safe-distinctness as load-bearing: `DurationFreezeModule.sol:116`
`if (juniorTrancheSafe_ == juniorTrancheSidecar_) revert BadParams();` — with the inline rationale "distinctness
is load-bearing: equal Safes make a rotation a self-transfer that trivially passes the floor" (`:115`).

`setOperator` follows the same defend-your-invariant pattern (SEC-15): `:160`
`if (operator_ == owner) revert OwnerIsOperator();`.

But the two Safe-pointer setters guard **only** `== address(0)`:
- `setJuniorTrancheSafe` (`:144-148`) — `if (juniorTrancheSafe_ == address(0)) revert ZeroAddress();` then sets
  `juniorTrancheSafe = juniorTrancheSafe_`. No re-check against `juniorTrancheSidecar`.
- `setJuniorTrancheSidecar` (`:151-155`) — symmetric; no re-check against `juniorTrancheSafe`.

So `owner` (the Timelock) can call `setJuniorTrancheSafe(juniorTrancheSidecar)` (or the mirror) and collapse the
two Safes to one address with no revert.

**Consequence.** With `juniorTrancheSafe == juniorTrancheSidecar`, `release(asset, amount)` (`:377-395`) becomes a
self-transfer: the transfer (`:382-383`) moves `amount` from the Safe back to itself, the dest-balance delta equals
`amount` so the `TransferShortfall` check passes (`:386`), and `committedValue()`/`grossBasketValue()` are
unchanged (the oracle sums the now-single Safe), so `coverageValue() >= requiredCommittedValue()` holds trivially
(`:390-392`) and the floor **never fires**. The autonomous floor (I-1) — the contract's load-bearing property — is
neutralized in this misconfigured state.

## The fix

Add the distinctness re-check `setUp:116` already enforces, to both Safe setters:

```solidity
function setJuniorTrancheSafe(address juniorTrancheSafe_) external onlyOwner {
    if (juniorTrancheSafe_ == address(0)) revert ZeroAddress();
    if (juniorTrancheSafe_ == juniorTrancheSidecar) revert BadParams();   // <-- add (mirror setUp:116)
    juniorTrancheSafe = juniorTrancheSafe_;
    avatar = juniorTrancheSafe_;     // (verify the real setter body when building — match existing fields)
    target = juniorTrancheSafe_;
    emit WiringSet("juniorTrancheSafe", juniorTrancheSafe_);
}

function setJuniorTrancheSidecar(address juniorTrancheSidecar_) external onlyOwner {
    if (juniorTrancheSidecar_ == address(0)) revert ZeroAddress();
    if (juniorTrancheSidecar_ == juniorTrancheSafe) revert BadParams();   // <-- add (mirror setUp:116)
    juniorTrancheSidecar = juniorTrancheSidecar_;
    emit WiringSet("juniorTrancheSidecar", juniorTrancheSidecar_);
}
```

`BadParams` already exists (`:77`, used by `setUp:116`) — no new error. **Verify the real setter bodies before
editing** (the avatar/target sync, exact field names) per the execute-cycle rule "verify the base API before
fixing" — the snippet above is illustrative, not a literal patch.

## Severity rationale (LOW, deflated from the raw MEDIUM)

- The trigger is `onlyOwner` (the Timelock), **not** the CRE operator hot key — so it is a governance
  misconfiguration, not an operator/attacker path.
- It is build-phase mutable wiring (X-3), closed by the documented pre-prod immutable re-freeze.
- Deflated from mission 5's raw MEDIUM for those two reasons; raised above mission 3's INFO because it is a real
  guard asymmetry on the contract's #1 invariant that `setUp` itself declares load-bearing, with a trivial fix.
- Mirrors the bridge-group precedent of shipping LOW guard-hardening fixes.

## Acceptance criteria

1. `setJuniorTrancheSafe(juniorTrancheSidecar)` reverts `BadParams`; `setJuniorTrancheSidecar(juniorTrancheSafe)`
   reverts `BadParams`.
2. A non-degenerate re-point (a fresh distinct Safe) still succeeds and keeps `avatar`/`target` in sync.
3. Regression test: after setUp, no setter sequence can leave `juniorTrancheSafe == juniorTrancheSidecar`, and a
   `release` cannot self-transfer.
4. GATE: `forge build` clean + `forge test --match-path test/supply/szipUSD/DurationFreezeModule.t.sol` green
   (incl. the new test); the 56 existing + new pass.

## Documentation-propagation step

- `contracts/src/supply/szipUSD/x-ray/DurationFreezeModule.md` (authoritative, code-truth): add a guard-table row
  for the Safe-setter distinctness re-check (§4) and a note in §5 X-3 that the setters now defend the `setUp:116`
  invariant. **Gate this edit on the code landing.**
- Grep-verified: no `docs/wires/` doc carries a claim about the Safe-setter guards (the wire docs describe the
  freeze topology, not setter internals) — nothing else to propagate. The freeze X-Ray is the only truth-source
  that asserts the distinctness invariant.
