# Invariant Map

> CreditWarehouse Admin | 10 guards | 6 inferred | 2 not enforced on-chain (X-1 scope, X-3 re-freeze)

> The defining feature of this scope: the load-bearing invariants are **cross-contract** — the primary enforcement (param-pinning, Call-only) lives in the Zodiac Roles scope, not this bytecode (X-1, On-chain=No). The avatar-parity invariant (X-2) was On-chain=No; it is now **checked on-chain at the `setWarehouseSafe` entry point** (`AvatarMismatch`) — but this is entry-point-local, NOT a maintained standing invariant: `setRoles` and an external `Roles.setAvatar` can re-desync the pair afterward (both **fail-closed** at the scope's live `EqualToAvatar` receiver pin — no leak; see X-2 / CWH-ADV-01). The single-contract guards below are the "belt" to the scope's "suspenders".

---

## 1. Enforced Guards (Reference)

#### G-1
`if (roles_||warehouseSafe_||eePool_||usdc_||redemptionBox_ == 0) revert ZeroAddress()` · `WarehouseAdminModule.sol:92-97` · ctor: every wiring slot must be a real address.

#### G-2
`if (roleKey_ == bytes32(0)) revert ZeroRoleKey()` · `WarehouseAdminModule.sol:98` · zero is the modifier's `NoMembership` sentinel — a zero key would make every forward revert.

#### G-3
`if (roles_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:110` · `setRoles` keeps a live modifier.

#### G-4
`if (roleKey_ == bytes32(0)) revert ZeroRoleKey()` · `WarehouseAdminModule.sol:117` · `setRoleKey` preserves the non-zero-key invariant.

#### G-5
`if (warehouseSafe_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:145` · `setWarehouseSafe` non-zero (the avatar-parity check follows — see G-10).

#### G-6
`if (eePool_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:134` · `setEePool` non-zero.

#### G-7
`if (usdc_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:141` · `setUsdc` non-zero.

#### G-8
`if (redemptionBox_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:148` · `setRedemptionBox` non-zero.

#### G-9
`if (dest != redemptionBox) revert WrongRedemptionBox(dest)` · `WarehouseAdminModule.sol:189` · REPAY self-enforces the sink even before the Roles scope checks it.

#### G-10
`if (roles.avatar() != warehouseSafe_) revert AvatarMismatch(warehouseSafe_, av)` · `WarehouseAdminModule.sol:148` · `setWarehouseSafe` checks avatar parity on-chain (X-2 / I-4): a one-sided re-point **through this setter** cannot be saved (the paired re-point is `Roles.setAvatar` first). NOTE: this is entry-point-local — `setRoles` and an external `Roles.setAvatar` can still desync the pair (fail-closed at the scope; CWH-ADV-01).

*Plus the `UnsupportedOpType` revert and the unreachable `RoleExecFailed` (defense-in-depth — the modifier already reverts with `shouldRevert=true`).*

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`StateMachine` (constant) · On-chain: **Yes**

> Every forwarded call is `value == 0`, `operation == Call (0)`, `shouldRevert == true` — none is ever decoded from a payload, so no caller can request a delegatecall or attach value.

**Derivation** — literal constants at the sole call site: `roles.execTransactionWithRole(to, 0, data, OP_CALL, roleKey, true)` (`:189`); `OP_CALL = 0` (`:34`). No code path decodes operation/value/shouldRevert.

**If violated** — a delegatecall or value transfer could be requested; the hardcoding makes that unreachable from this contract (the on-chain half of the no-delegatecall guarantee; the modifier scope is the other half).

#### I-2

`Bound` (allow-list) · On-chain: **Yes**

> `opType ∈ {SUPPLY=1, APPROVE=2, REDEEM=3, REPAY=4}`; any other byte reverts. Each op maps to exactly one (target, selector) with injected addressable params.

**Derivation** — the `_processReport:163-185` if/else chain with `else revert UnsupportedOpType(opType)` (`:184`); targets/selectors are literals (`eePool`/`usdc` + `deposit`/`approve`/`redeem`/`transfer`).

**If violated** — an unexpected op could be forwarded; the allow-list + the modifier's selector scope prevent it.

#### I-3

`Bound` · On-chain: **Yes**

> REPAY transfers to `redemptionBox` (the immutable), never to the payload's `dest`: `dest` is validated (`dest == redemptionBox`) AND the calldata injects `redemptionBox`, not `dest`.

**Derivation** — `_processReport:180,182`: `if (dest != redemptionBox) revert; … encode(transfer.selector, redemptionBox, amount)`. Even if the validation were removed, the injected address is the immutable.

**If violated** — n/a; REPAY cannot be redirected from this contract even with a scope gap (double-defended).

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No** (enforcement is in the external Roles scope)

> The real param-pinning — SUPPLY/REDEEM `receiver == avatar`, APPROVE `spender == EqualTo(eePool)`, REPAY `to == EqualTo(redemptionBox)`, Call-only, no delegatecall — is enforced by the **Roles modifier's scope config**, not this contract. This contract's injections are belt-and-suspenders.

**Caller side** — `WarehouseAdminModule._processReport:189` forwards to `roles.execTransactionWithRole`.

**Callee side** — the deployed Roles-modifier-v2 **scope tree** (`scopeFunction`/`scopeTarget` config) — **out of scope** (deploy/off-chain).

**If violated** — a mis-scoped policy (wildcarded param, granted delegatecall option, wrong selector set) removes the primary control; only this contract's hardcoding/injection remains. This is the #1 audit artifact and it is not in this file.

#### X-2 (checked on-chain at the setWarehouseSafe entry point — see I-4; CWH-ADV-01)

On-chain: **entry-point-local** (checked in `setWarehouseSafe`; NOT a maintained invariant — other re-point paths fail-closed)

> `warehouseSafe` (this contract's injected deposit/redeem owner) MUST equal the Roles modifier's `avatar` (which the scope checks `receiver == avatar` against). They are independent slots. `setWarehouseSafe` **reads and asserts `roles.avatar()`**: it reverts `AvatarMismatch` unless `roles.avatar() == warehouseSafe_`. **This check is entry-point-local, not a standing invariant** — two ratified Timelock paths re-desync the pair without tripping it: `setRoles(newModifier)` (no parity re-check) and an external `Roles.setAvatar(other)` on the modifier.

**Caller side** — `setWarehouseSafe` (`AvatarMismatch` guard) / the SUPPLY+REDEEM injection; the UNGUARDED re-desync paths are `setRoles` and external `Roles.setAvatar`.

**Callee side** — the modifier's `avatar` slot, set via its own `setAvatar`. The paired re-point through this setter is order-dependent: `Roles.setAvatar(new)` FIRST, then `setWarehouseSafe(new)` (else the setter reverts). Documented in `docs/roles.md`.

**If violated** — a `setWarehouseSafe` one-sided re-point reverts; but a `setRoles` re-point or an external `setAvatar` CAN desync the pair. In every desync case SUPPLY/REDEEM **fail-closed**: the scope's receiver/owner pin is `OP_EQUAL_TO_AVATAR` (resolved live), so the stale injected `warehouseSafe` is rejected (`ParameterNotAllowed`) — bricked par-redemption liveness, never a leak (the pin can only resolve to the actual current avatar). Proven by `test_Parity_OneSidedRepoint_RevertsAtSetter` + `test_Parity_PairedRepoint_SetAvatarFirst_Succeeds` (setter path) and `test_Scope_PinsParams_DepositReceiver` (the scope fail-closed backstop).

#### X-3

On-chain: **No** (build phase)

> All six wiring slots (`roles`, `roleKey`, `warehouseSafe`, `eePool`, `usdc`, `redemptionBox`) are Timelock-re-pointable; the value-routing guarantees are conditional on correct wiring + the deferred immutable re-freeze.

**Caller side** — the six `onlyOwner` setters (`:109-151`).

**Callee side** — the documented pre-prod immutable lock-down (§17) — a process step, **not** on-chain enforced.

**If violated** — a compromised/over-powered owner re-points a slot (e.g. `redemptionBox`/`eePool`/`usdc`). A single-contract re-point alone **fails-closed**: the REPAY-`to` and APPROVE-`spender` scope pins are deploy-baked `OP_EQUAL_TO(compValue)`, so re-pointing the adapter slot does NOT move the pin — the modifier rejects the new target (`ParameterNotAllowed` / `TargetAddressNotAllowed`). A real value redirect (e.g. the REPAY sink becoming owner-chosen) requires a **paired off-chain re-scope** — re-pointing the slot here AND re-running `scopeFunction` on the modifier, i.e. two Timelock actions on two contracts. The pre-prod re-freeze closes this. (CWH-ADV-01.)

---

## 4. Economic Invariants

*None in scope.* This contract is a stateless router; the economic invariants (4626 share accounting, senior par-backing, provision conservation) live in EulerEarn and the loss/NAV subsystems, not here.
