# interfaces-zodiac — `contracts/src/interfaces/zodiac/` (wiring map)

> Source of truth = the kept code under `contracts/src/interfaces/zodiac/`. These are minimal local
> CALL-shims (only the methods we call) for the **interface+fork** Zodiac infra on Base — never compiled
> from source (OZ 4.x can't coexist with Euler's OZ 5.0.2; WOOF-00 Strategy A). Distinct from the
> compiled OZ-free `zodiac-core` `Module`/`Operation`/`ModuleProxyFactory` the engine modules `is Module`
> inherit. Live Base pins read from `contracts/script/BaseAddresses.sol`.

## Role
Two shims for the deploy-time Zodiac substrate: the **CREATE2 clone factory** (`IModuleProxyFactory`,
`deployModule`) that mints every engine Zodiac-module proxy + the warehouse Roles instance, and the
**Roles Modifier v2** call surface (`IRoles`) the warehouse uses for parameter-pinned, Call-only scoped
forwarding. Both consumed only at the boundary: factory by the deployer, Roles by the warehouse deployer
(setup) + the live `WarehouseAdminModule` (runtime forward).

## Files

### `IModuleProxyFactory.sol`
- **Shims:** the canonical Zodiac **ModuleProxyFactory** (EIP-1167 minimal-proxy CREATE2 cloner).
  Pin **`ZODIAC_MODULE_PROXY_FACTORY 0x000000000000aDdB49795b0f9bA5BC298cDda236`**; signature modeled
  from `reference/zodiac-core/contracts/factory/ModuleProxyFactory.sol`.
- **Surface (as written):**
  - `deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce) returns (address proxy)`
- **Consumed by:** `contracts/script/CreditWarehouseDeployer.sol:119` — clones the Roles-v2 instance:
  `IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY).deployModule(ZODIAC_ROLES_MASTERCOPY,
  setUp(owner=this, avatar=safe, target=safe)-initializer, saltNonce)`, then asserts the cloned instance's
  `avatar()/target()/owner()` via `IRolesInit`. This is the CREATE2 clone path for **every** engine Zodiac
  module at full deploy (item 10) — each szipUSD engine module (Recycle/ReservoirLoop/HarvestVote/
  LpStrategy/DurationFreeze/SzipBuyBurn/Exercise/Sell/OffRamp) is a `is Module` mastercopy cloned the same way.
- **Gotchas:** the NatSpec flags the alternative — a shaman/module may instead **INHERIT** the OZ-free
  `Module` via the `@gnosis-guild/zodiac-core/` remap (compiled) rather than call through this shim. Two
  worlds: (a) this **call-shim** = how the deploy script clones a mastercopy; (b) the compiled `Module`
  base every engine module extends. `deployModule` reverts on salt/initializer collision (deterministic
  address); pass a fresh `saltNonce` per clone.

### `IRoles.sol`
- **Shims:** a deployed **Zodiac Roles Modifier v2** instance. Mastercopy pin
  **`ZODIAC_ROLES_MASTERCOPY 0x9646fDAD06d3e24444381f44362a3B0eB343D337`**; instances are CREATE2 clones
  (no fixed address — the `deployModule` return). Verified 2026-06-06 against vendored
  `reference/zodiac-modifier-roles/packages/evm/contracts/` (`Roles.sol`, `PermissionBuilder.sol`,
  `Types.sol`).
- **Surface (as written):**
  - `assignRoles(address module, bytes32[] roleKeys, bool[] memberOf)` — Roles.sol L69
  - `execTransactionWithRole(address to, uint256 value, bytes data, uint8 operation, bytes32 roleKey, bool shouldRevert) returns (bool success)` — Roles.sol L153
  - `scopeTarget(bytes32 roleKey, address targetAddress)` — PermissionBuilder.sol L86
  - `scopeFunction(bytes32 roleKey, address targetAddress, bytes4 selector, ConditionFlat[] conditions, uint8 options)` — PermissionBuilder.sol L133 (param-pinned)
  - `allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options)` — PermissionBuilder.sol L102 (wildcard, declared but NOT used)
  - struct `ConditionFlat { uint8 parent; uint8 paramType; uint8 operator; bytes compValue; }` — mirror of Types.sol L123-128 (enum fields ABI-encode as `uint8`, byte-for-byte wire-identical).
  - `operation` = Zodiac core Operation as `uint8` (0=Call, 1=DelegateCall). `options` = ExecutionOptions
    as `uint8` (Types.sol L107: 0=None/Call-only, 1=Send, 2=DelegateCall, 3=Both).
  - (`allowTarget` is NOT declared — speculative in the brief; not present and not consumed.)
- **Consumed by:**
  - `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` — `IRoles public roles`; runtime forward
    `roles.execTransactionWithRole(to, 0, data, OP_CALL, roleKey, true)` (L174) for the four warehouse ops
    (DEPOSIT/REDEEM/APPROVE/REPAY). It is NOT a Zodiac `Module` and is never `enableModule`'d — it is
    `assignRoles`'d as the sole role member; the Roles scope IS the security boundary, not its bytecode.
  - `contracts/script/CreditWarehouseDeployer.sol` — deploy-time scoping: `scopeTarget` + `scopeFunction`
    (trees A–D) over `eePool`(deposit/redeem)+`usdc`(approve/transfer), all `EXEC_NONE` (Call-only), then
    `assignRoles(adapter)` and owner hand-off to `godOwner`. Builds `ConditionFlat[]` trees via this struct.
- **Gotchas:**
  - **Roles v2 scoped policy** is the warehouse op-set: DEPOSIT/REDEEM pin `receiver`/`owner ==`
    `EqualToAvatar`(15); APPROVE pins `spender == EqualTo(eePool)`(16); REPAY pins `to == EqualTo(repaySink)`(16);
    amounts are `Pass`(0). The wildcard `allowFunction` skips ALL param checks (would unpin receiver/spender/`to`)
    — it is the WRONG tool for the warehouse and is deliberately unused; `scopeFunction` is the one wired.
  - **`EXEC_NONE`(0) = Call-only** on every scoped function — no Send/DelegateCall escalation.
  - **`EqualTo` compValue** is the 32-byte `abi.encode(addr)` for `spender`/`to`; `EqualToAvatar` carries
    empty compValue (resolves to the Safe at check-time). Condition trees are BFS order, root at index 0
    (`ABI_CALLDATA`/`Matches`), verified to pass `Integrity.enforce`.
  - All-`uint8` enum mirror is intentional (wire-identical ABI); never compiled against the real enums.
  - This call-shim is distinct from the compiled `zodiac-core` `Module` base the engine modules inherit.
