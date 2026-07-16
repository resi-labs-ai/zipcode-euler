# Entry Point Map

> CreditWarehouse Admin | 7 entry points | 0 permissionless | 1 CRE-gated | 6 admin (Timelock)

Scope: `WarehouseAdminModule`. View/pure excluded. No permissionless entry points; no custody. Every effect is forwarded through the external Roles modifier (out of scope) and executed as the warehouse Safe.

---

## Protocol Flow Paths

### Setup (Deploy / Timelock)

`WarehouseAdminModule(constructor)` (forwarder, roles, roleKey, warehouseSafe, eePool, usdc, redemptionBox)
   ‖ on the Roles modifier: `assignRoles(this, roleKey)` + `scopeFunction(...)` (the four pinned ops) + `setAvatar(warehouseSafe)`  ◄── three set-ups MUST agree

### Warehouse ops (CRE → encoder → modifier → Safe)

`Forwarder → _processReport(opType, payload)` →
   ├─ SUPPLY  → `roles.execTransactionWithRole(eePool, 0, deposit(amount, warehouseSafe), Call, roleKey, true)`
   ├─ APPROVE → `roles.execTransactionWithRole(usdc, 0, approve(eePool, amount), Call, roleKey, true)`
   ├─ REDEEM  → `roles.execTransactionWithRole(eePool, 0, redeem(shares, warehouseSafe, warehouseSafe), …)`
   └─ REPAY   → `roles.execTransactionWithRole(usdc, 0, transfer(redemptionBox, amount), …)`  ◄── dest self-checked + scope-pinned

---

## Role-Gated

### CRE Forwarder

#### `_processReport()` (via `ReceiverTemplate.onReport`)

| Aspect | Detail |
|--------|--------|
| Visibility | internal override (forwarder-gated entry) |
| Caller | Chainlink Forwarder (CRE workflow) |
| Parameters | report → `(opType, payload)`; opType (keeper-provided) ∈ {SUPPLY=1, APPROVE=2, REDEEM=3, REPAY=4}; payload = `amount` / `shares` / `(dest, amount)` (keeper-provided; `dest` guarded) |
| Call chain | `→ build calldata (receiver/spender/owner injected from immutables) → roles.execTransactionWithRole(to, 0, data, Call, roleKey, true) → (modifier) Safe.exec` |
| State modified | none in this contract (no storage writes on the op path) |
| Value flow | indirect: USDC into/out of EulerEarn via the Safe; REPAY USDC → redemptionBox. None held here. |
| Reentrancy guard | none — no custody, single external call, no post-call state (no reentrancy surface) |

**Hardcoded at the call site (never decoded):** `value = 0`, `operation = Call (0)`, `shouldRevert = true`. **Injected from immutables (not payload):** SUPPLY/REDEEM receiver+owner = `warehouseSafe`; APPROVE spender = `eePool`; REPAY `to` = `redemptionBox`. **Only payload-carried address:** REPAY `dest` — reverts `WrongRedemptionBox` if `!= redemptionBox`, and the injected `redemptionBox` (not `dest`) is what's transferred.

---

## Admin-Only (Timelock `onlyOwner`)

| Function | Parameters | State Modified | Notes |
|----------|-----------|----------------|-------|
| `setRoles()` | roles_ | `roles` | re-point the Roles modifier instance |
| `setRoleKey()` | roleKey_ (`!= 0`) | `roleKey` | must match the modifier's `assignRoles` |
| `setWarehouseSafe()` | warehouseSafe_ | `warehouseSafe` | **reverts `AvatarMismatch` unless `roles.avatar() == warehouseSafe_`** — pair `Roles.setAvatar(new)` FIRST, then this (parity enforced on-chain; `docs/roles.md`) |
| `setEePool()` | eePool_ | `eePool` | re-point the EulerEarn pool |
| `setUsdc()` | usdc_ | `usdc` | re-point the asset |
| `setRedemptionBox()` | redemptionBox_ | `redemptionBox` | re-point the REPAY sink |

*All build-phase re-pointable (§17), to be re-frozen to immutable at pre-prod (off-chain process, not enforced here).*

---

## Initialization

| Contract | Function | Access | Notes |
|----------|----------|--------|-------|
| WarehouseAdminModule | `constructor(forwarder, roles, roleKey, warehouseSafe, eePool, usdc, redemptionBox)` | deploy | all-nonzero guard; `roleKey != 0`; ownership (via `ReceiverTemplate`/Ownable) → Timelock post-deploy |

---

## Out-of-scope but load-bearing

| Contract | Why it matters |
|----------|----------------|
| Roles Modifier v2 (Zodiac) | Holds the **scope** that param-pins receiver/spender/`to` and forbids delegatecall — the real security boundary. `assignRoles(this, roleKey)` + `scopeFunction` config is deploy/off-chain. |
| Warehouse Safe | The `avatar`/`target`; custodies the EulerEarn shares. Its `avatar` must equal this contract's `warehouseSafe`. |
