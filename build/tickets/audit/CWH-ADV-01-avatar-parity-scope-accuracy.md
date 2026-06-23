# CWH-ADV-01 — I-4 avatar-parity is entry-point-local, not a maintained on-chain invariant (doc-accuracy)

> **STATUS: BUILT + SHIPPED to `main` (2026-06-22) — DOC-ONLY.** Corrected the overstated I-4/X-2 claims in the
> per-contract X-Ray (`WarehouseAdminModule.md`), the scope catalog (`invariants.md`), and the operator runbook
> (`docs/roles.md`): avatar parity is **checked entry-point-local at `setWarehouseSafe`**, NOT a maintained
> on-chain invariant — `setRoles` and an external `Roles.setAvatar` can re-desync the pair, both **fail-closed**
> at the live `EqualToAvatar` scope pin (no leak); HARDENED rests on the scope's dynamic pin, not the setter
> guard. Also qualified the X-3 note: a single-contract `redemptionBox`/`eePool`/`usdc` re-point fails-closed
> (deploy-baked `EqualTo` pins don't move) — a redirect needs a paired off-chain re-scope. **NO contract change.**
> The optional `setRoles` parity re-check (#4 below) was **DECLINED**: it breaks the build-phase "re-point freely"
> model (`test_Setters_OwnerUpdates_AndRejectsZero` re-points `roles` to a non-modifier address), can't cover the
> external `setAvatar` path, and adds nothing over the already-fail-closed scope. Contract untouched → the 28
> fork-integration tests are unaffected (green at baseline this session).
>
> BUILD item (INFO/LOW — doc-correction primary, landable immediately; optional defense-in-depth hardening).
> Source: adversarial-review on `WarehouseAdminModule`
> (`adversarial-review/reports/src/creditwarehouse/warehouseadminmodule/`, mission 2, verified against the
> live deployer scope tree). **No code vulnerability** — the contract is HARDENED and every desync path
> fails-closed. The actionable item is that an authoritative truth-source (the X-Ray + `invariants.md`)
> **overstates** the enforcement scope of invariant I-4.

## The gap (source-verified)
The X-Ray claims I-4 (avatar parity) is a maintained on-chain invariant:
- `WarehouseAdminModule.md` §I-4 / §5: *"a one-sided re-point can no longer be saved"*, verdict lifted to
  HARDENED on that basis.
- `invariants.md` I-4 / X-2: **"On-chain: Yes"**, *"setWarehouseSafe now reads and asserts roles.avatar()"*.

But the `AvatarMismatch` guard is **entry-point-local** — it fires only inside `setWarehouseSafe`
(`WarehouseAdminModule.sol:148-149`). Two ratified Timelock-power paths re-break the
`warehouseSafe == roles.avatar()` pairing AFTER a valid `setWarehouseSafe`, without ever tripping it:
1. **`setRoles(newModifier)`** (`WarehouseAdminModule.sol:125-129`) checks only `roles_ != 0` — no parity
   re-check. If `newModifier.avatar() != warehouseSafe`, the pair is now desynced.
2. **External `Roles.setAvatar(other)`** on the modifier (`IRoles.sol:40`, the modifier's own owner path) —
   desyncs without touching this contract at all.

So I-4 is enforced at one entry point, not maintained as a standing invariant. The X-Ray's "can no longer be
saved" and `invariants.md`'s "On-chain: Yes" are too strong.

## Mechanism + impact (FAIL-CLOSED — no drain)
Both desync paths fail-closed, which is why this is doc-accuracy and not a vuln. Verified against the live
deployed scope tree in `contracts/script/CreditWarehouseDeployer.sol`:
- The SUPPLY/REDEEM receiver/owner pin is `OP_EQUAL_TO_AVATAR` (operator 15, *dynamic* — resolved live at
  check time): `CreditWarehouseDeployer.sol:185,193,194`. After a desync, SUPPLY/REDEEM inject the stale
  `warehouseSafe` (`WarehouseAdminModule.sol:188,196`) while the modifier compares against the new/different
  `avatar()` → `ConditionViolation(ParameterNotAllowed)` → senior par-redemption bricked (liveness), no leak.
- `EqualToAvatar` can never resolve to an attacker unless the attacker is ALREADY the modifier's avatar (i.e.
  already custodies the Safe shares), so no receiver/owner redirect to an arbitrary address is reachable.
This is the same fail-closed backstop `test_Scope_PinsParams_DepositReceiver` already proves.

Related (fold-in): the X-3 note `invariants.md:115` says a `redemptionBox` re-point makes "the REPAY sink
owner-chosen." That is true only AFTER a paired off-chain re-scope. The REPAY-`to` / APPROVE-`spender` pins
are deploy-baked `OP_EQUAL_TO` compValues (`CreditWarehouseDeployer.sol:209,201`), so re-pointing the slot on
the adapter alone leaves the scope pinning the OLD target → `ParameterNotAllowed`/`TargetAddressNotAllowed`
(fail-closed). A real redirect needs two Timelock actions on two contracts (the adapter slot AND a modifier
re-scope) — a fully-compromised Timelock (X-3), not a one-call drain.

## Fix
**Doc correction (PRIMARY — landable now, independent of code):**
1. `contracts/src/supply/CreditWarehouse/x-ray/WarehouseAdminModule.md` — soften §I-4 and the §5
   avatar-parity bullet + the §X-Ray-Verdict / "What changed" notes: I-4 is enforced **entry-point-local at
   `setWarehouseSafe`**, NOT a maintained invariant; `setRoles` and an external `Roles.setAvatar` can
   re-desync the pair, both **fail-closed** at the `EqualToAvatar` scope pin (no leak). Keep the HARDENED
   verdict — the property that matters (no receiver redirect to an attacker) holds by the dynamic scope pin,
   not by the setter guard.
2. `contracts/src/supply/CreditWarehouse/x-ray/invariants.md` — I-4 / X-2: change **"On-chain: Yes"** to
   "On-chain: entry-point-local (setWarehouseSafe); fail-closed on the other re-point paths"; add to the X-3
   note (`:115`) the one-line qualifier that a `redemptionBox`/`eePool`/`usdc` re-point is fail-closed at the
   deploy-baked scope pin and a redirect needs a paired off-chain re-scope (two-contract Timelock action).
3. `docs/roles.md` (the order-dependent re-point runbook) — note that `setRoles` and `Roles.setAvatar` also
   require re-establishing parity, and that the failure mode is fail-closed (bricked par-redemption), so the
   operator must re-pair after either.

**Optional defense-in-depth (code — NOT security-required):**
4. Add a symmetric parity re-check in `setRoles`: after `roles = IRoles(roles_)`, `if (roles.avatar() !=
   warehouseSafe) revert AvatarMismatch(warehouseSafe, roles.avatar());` — closes the asymmetry so I-4 is
   maintained across the `roles` re-point too. (Cannot cover an external `Roles.setAvatar`; that stays
   fail-closed by the scope.) Decide whether to make I-4 a true standing invariant or leave it entry-point-
   local + documented; the fail-closed backstop makes either acceptable.

## Gate (only if the optional code change is taken)
`forge build` clean + `forge test --match-path 'test/supply/CreditWarehouse/*.t.sol'` green. Add
`test_setRoles_RepointToMismatchedAvatar_Reverts` (re-point `roles` to a modifier whose `avatar()` differs →
`AvatarMismatch`, slot unchanged). The 28 existing fork-integration tests stay green.

## Acceptance criteria
- The X-Ray + `invariants.md` no longer claim I-4 is a maintained on-chain invariant; they state it is
  entry-point-local with the other re-point paths fail-closed, and the X-3 redirect is qualified as needing a
  paired off-chain re-scope.
- (If the optional change is taken) `setRoles` re-checks avatar parity; regression test added; suite green.
- HARDENED verdict retained (the soundness rests on the dynamic `EqualToAvatar` scope pin, not the setter
  guard).
