# ROLES
[zipcode-euler/contracts/src/supply/CreditWarehouse]

How the senior CreditWarehouse uses a Zodiac Roles Modifier v2 to let a CRE adapter move warehouse funds without ever holding custody — and the one invariant (avatar parity) that keeps it working. Base (chain 8453). Solidity 0.8.24.

* The warehouse Safe custodies the EulerEarn shares backing all outstanding zipUSD float.
* A Zodiac Roles modifier sits in front of that Safe as a permission firewall (the "bouncer").
* `WarehouseAdminModule` is the only role member; it encodes CRE instructions into exactly four allowed moves and forwards them through the modifier.
* The security boundary is the modifier's scope config, NOT the adapter bytecode.

==================================================================================
## The pieces

- The warehouse Safe — holds the money (EulerEarn shares + any naked USDC from redemptions).
- The Roles modifier (Zodiac Roles Modifier v2) — `enableModule`'d on the Safe. It only forwards calls that match its scope: specific targets, specific function selectors, with specific parameters pinned, Call-only (no delegatecall, no value).
- `WarehouseAdminModule` (the adapter) — `assignRoles`'d as the sole role member (it is NOT `enableModule`'d on the Safe). It is a pure encoder: it turns a CRE report into one of four ops and calls `roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`.
  [contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol]
  [contracts/src/interfaces/zodiac/IRoles.sol]

The four ops the adapter can encode:
- SUPPLY  — `eePool.deposit(amount, warehouseSafe)`     (scope pins receiver == avatar)
- APPROVE — `usdc.approve(eePool, amount)`              (scope pins spender == eePool)
- REDEEM  — `eePool.redeem(shares, warehouseSafe, warehouseSafe)`  (scope pins receiver == owner == avatar)
- REPAY   — `usdc.transfer(redemptionBox, amount)`      (scope pins to == redemptionBox)

The dangerous fields are hardcoded, never decoded from the payload: `value` is always 0, `operation` is always Call, `shouldRevert` is always true. Addresses (receiver / spender / redeem-owner) are injected from the adapter's own immutables; only the REPAY destination is payload-carried, and it is BOTH self-checked (`dest != redemptionBox` reverts) AND scope-pinned.

==================================================================================
## The avatar-parity invariant (load-bearing)

There are two independent records of "which Safe are we operating on":

- the adapter stores it in `warehouseSafe` (set via `WarehouseAdminModule.setWarehouseSafe`)
- the modifier stores it in `avatar` (set via `Roles.setAvatar` on the modifier instance)

SUPPLY and REDEEM inject the adapter's `warehouseSafe` as the deposit/redeem receiver+owner, while the modifier's scope checks `receiver == avatar`. So the two MUST be the same address. If they drift apart, every SUPPLY/REDEEM is rejected by the scope — senior par-redemption jams. This fails CLOSED (nothing leaks; it just stops working), but it is a real liveness failure.

This is checked on-chain AT THE `setWarehouseSafe` ENTRY POINT. `setWarehouseSafe` reverts `AvatarMismatch(warehouseSafe_, avatar)` unless the modifier's `avatar()` ALREADY equals the new address — so a one-sided re-point *through that setter* can't be saved.

IMPORTANT: this check is entry-point-local, NOT a maintained invariant. Two other Timelock-power paths can still desync the pair WITHOUT tripping `AvatarMismatch`:
- `adapter.setRoles(newModifier)` — re-points to a modifier whose `avatar()` may differ from the current `warehouseSafe` (no parity re-check on this setter);
- `roles.setAvatar(other)` called directly on the modifier — changes `avatar` without touching the adapter.

In BOTH cases the result is the same fail-CLOSED jam: the scope pins the receiver via `EqualToAvatar` (resolved LIVE), so SUPPLY/REDEEM inject the now-stale `warehouseSafe` and the modifier rejects it (`ParameterNotAllowed`). The pin can only ever resolve to the actual current avatar, so this is a liveness jam, never a leak. The scope's rejection (`test_Scope_PinsParams_DepositReceiver`) is the real, always-on backstop; the setter guard is a convenience belt for the common re-point path. After ANY of the three paths, always re-establish parity (`roles.avatar() == adapter.warehouseSafe()`).

==================================================================================
## Re-pointing the warehouse Safe (runbook — ORDER MATTERS)

Because `setWarehouseSafe` checks parity, the two updates must run in this order:

1. On the Roles modifier instance, as its owner (the Timelock):
   `roles.setAvatar(newSafe)`
2. On the adapter, as its owner (the Timelock):
   `adapter.setWarehouseSafe(newSafe)`   ← reverts `AvatarMismatch` if step 1 was skipped or used a different address

Doing step 2 first reverts. After both, confirm `roles.avatar() == adapter.warehouseSafe()`. The new Safe must also have the modifier `enableModule`'d and be funded/provisioned before live ops resume.

The other adapter wiring (`setRoleKey`, `setEePool`, `setUsdc`, `setRedemptionBox`) has no ordering constraint at the setter, BUT a single-contract re-point of these alone FAILS CLOSED: the REPAY-`to` and APPROVE-`spender` scope pins are deploy-baked `EqualTo(compValue)`, so re-pointing the adapter slot does not move the pin — the modifier rejects the new target (`ParameterNotAllowed`/`TargetAddressNotAllowed`). A real value redirect (e.g. moving the REPAY sink) requires a PAIRED off-chain re-scope on the modifier (`scopeFunction`) too — two Timelock actions on two contracts. `setRoles` additionally re-desyncs avatar parity (see above) — re-establish parity after it. All adapter setters are `onlyOwner` (Timelock); re-freezing to immutable is deferred to pre-prod (§17 build-phase flexibility).

==================================================================================
## Why the adapter holds no power

The adapter cannot be made to do anything outside the four scoped ops: a different selector on a scoped target is rejected (`FunctionNotAllowed`), a redirected receiver is rejected (`ParameterNotAllowed`), value/delegatecall are rejected (`SendNotAllowed`/`DelegateCallNotAllowed`), and a non-member caller is rejected (`NotAuthorized`). The CRE Forwarder is the only caller of the adapter's `onReport`. So even a fully compromised CRE workflow can only move funds within the warehouse policy — supply to the pool, approve the pool, redeem to the Safe, repay the one configured redemption box.

[contracts/src/supply/CreditWarehouse/x-ray/x-ray.md]   — full scope-rejection matrix + invariants
[docs/wires/8-Bw-CreditWarehouse.md]                     — wiring + custody character
