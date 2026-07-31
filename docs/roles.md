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

This is checked on-chain AT ALL THREE PAIRING SITES: the constructor, `setRoles`, and `setWarehouseSafe` each revert `AvatarMismatch(warehouseSafe, avatar)` unless the (new) modifier's `avatar()` equals the (new) `warehouseSafe` — so a one-sided re-point of EITHER slot through the adapter is a hard revert, never a live mismatch.

Why `setRoles` needed the guard and not just `setWarehouseSafe`: under a mismatch SUPPLY/REDEEM fail closed (the scope pins the receiver via `EqualToAvatar`, resolved LIVE, so the injected stale `warehouseSafe` is rejected — a liveness jam, no leak). REPAY does NOT fail closed the same way — `usdc.transfer(redemptionBox, amount)` has no "from" parameter to scope; it spends whatever Safe the modifier is attached to. A mis-paired `setRoles` (new modifier on a different Safe, enabled + scoped + membered) would therefore keep REPAY live against the WRONG Safe, draining it into the redemption queue (unrecoverable — the queue has no sweep and `settleEpoch` consumes any free balance).

The wiring-site checks can't see an EXTERNAL `roles.setAvatar(other)` called directly on the modifier — so the adapter ALSO re-asserts parity at USE time: `_processReport` reverts `AvatarMismatch` before dispatching ANY op whenever `roles.avatar() != warehouseSafe`. Parity is therefore a MAINTAINED invariant at every effect, not just at wiring: no op (REPAY included) can ever execute against a modifier attached to the wrong Safe, whatever the desync path. A desynced pair is a liveness jam until re-paired — never a leak. After ANY re-point, confirm `roles.avatar() == adapter.warehouseSafe()`.

==================================================================================
## Re-pointing the warehouse Safe (runbook — ORDER MATTERS)

Because `setWarehouseSafe` checks parity, the two updates must run in this order:

1. On the Roles modifier instance, as its owner (the Timelock):
   `roles.setAvatar(newSafe)`
2. On the adapter, as its owner (the Timelock):
   `adapter.setWarehouseSafe(newSafe)`   ← reverts `AvatarMismatch` if step 1 was skipped or used a different address

Doing step 2 first reverts. After both, confirm `roles.avatar() == adapter.warehouseSafe()`. The new Safe must also have the modifier `enableModule`'d and be funded/provisioned before live ops resume.

The other adapter wiring (`setRoleKey`, `setEePool`, `setUsdc`, `setRedemptionBox`) has no ordering constraint at the setter, BUT a single-contract re-point of these alone FAILS CLOSED: the REPAY-`to` and APPROVE-`spender` scope pins are deploy-baked `EqualTo(compValue)`, so re-pointing the adapter slot does not move the pin — the modifier rejects the new target (`ParameterNotAllowed`/`TargetAddressNotAllowed`). A real value redirect (e.g. moving the REPAY sink) requires a PAIRED off-chain re-scope on the modifier (`scopeFunction`) too — two Timelock actions on two contracts. `setRoles` is avatar-parity-guarded (see above): the new modifier must already be attached to the wired `warehouseSafe`, so a joint Safe+Roles migration is order-dependent (migrate the Safe via `Roles.setAvatar` + `setWarehouseSafe` first, THEN `setRoles`). All adapter setters are `onlyOwner` (Timelock); re-freezing to immutable is deferred to pre-prod (§17 build-phase flexibility).

==================================================================================
## Why the adapter holds no power

The adapter cannot be made to do anything outside the four scoped ops: a different selector on a scoped target is rejected (`FunctionNotAllowed`), a redirected receiver is rejected (`ParameterNotAllowed`), value/delegatecall are rejected (`SendNotAllowed`/`DelegateCallNotAllowed`), and a non-member caller is rejected (`NotAuthorized`). The CRE Forwarder is the only caller of the adapter's `onReport`. So even a fully compromised CRE workflow can only move funds within the warehouse policy — supply to the pool, approve the pool, redeem to the Safe, repay the one configured redemption box.

[contracts/src/supply/CreditWarehouse/x-ray/x-ray.md]   — full scope-rejection matrix + invariants
[docs/wires/8-Bw-CreditWarehouse.md]                     — wiring + custody character
