# Invariant Map

> CreditWarehouse Admin | 9 guards | 6 inferred | 3 not enforced on-chain

> The defining feature of this scope: the load-bearing invariants are **cross-contract and On-chain=No** — the enforcement lives in the Zodiac Roles scope, not this bytecode. The single-contract invariants below are real but secondary (they are the "belt" to the scope's "suspenders").

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
`if (warehouseSafe_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:127` · `setWarehouseSafe` non-zero (but does NOT assert avatar parity — see X-2).

#### G-6
`if (eePool_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:134` · `setEePool` non-zero.

#### G-7
`if (usdc_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:141` · `setUsdc` non-zero.

#### G-8
`if (redemptionBox_ == address(0)) revert ZeroAddress()` · `WarehouseAdminModule.sol:148` · `setRedemptionBox` non-zero.

#### G-9
`if (dest != redemptionBox) revert WrongRedemptionBox(dest)` · `WarehouseAdminModule.sol:180` · REPAY self-enforces the sink even before the Roles scope checks it.

*Plus the `UnsupportedOpType` revert (`:184`) and the unreachable `RoleExecFailed` (`:190`, defense-in-depth — the modifier already reverts with `shouldRevert=true`).*

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

#### X-2

On-chain: **No**

> `warehouseSafe` (this contract's injected deposit/redeem owner) MUST equal the Roles modifier's `avatar` (which the scope checks `receiver == avatar` against). They are independent slots and this contract never reads `roles.avatar()`.

**Caller side** — `setWarehouseSafe:126` / the SUPPLY+REDEEM injection (`:166,174`).

**Callee side** — the modifier's `avatar` slot, set via its own `setAvatar` — **out of scope**.

**If violated** — a one-sided re-point bricks SUPPLY/REDEEM (the scope rejects the mismatched receiver) — fail-closed (liveness loss, no leak). Not asserted on-chain; the docstring (`:43-48`) mandates pairing.

#### X-3

On-chain: **No** (build phase)

> All six wiring slots (`roles`, `roleKey`, `warehouseSafe`, `eePool`, `usdc`, `redemptionBox`) are Timelock-re-pointable; the value-routing guarantees are conditional on correct wiring + the deferred immutable re-freeze.

**Caller side** — the six `onlyOwner` setters (`:109-151`).

**Callee side** — the documented pre-prod immutable lock-down (§17) — a process step, **not** on-chain enforced.

**If violated** — a compromised/over-powered owner re-points a slot (e.g. `redemptionBox`); fail-closed for SUPPLY/REDEEM via parity, but the REPAY sink becomes owner-chosen. The pre-prod re-freeze closes this.

---

## 4. Economic Invariants

*None in scope.* This contract is a stateless router; the economic invariants (4626 share accounting, senior par-backing, provision conservation) live in EulerEarn and the loss/NAV subsystems, not here.
