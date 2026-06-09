# 8-Bw — CreditWarehouse (senior-backing custody Safe + `WarehouseAdminModule`) — Zodiac Roles-modifier-v2

> **NEXT / build-only.** The **SENIOR** side of the protocol — independent of the junior `szipUSD` Baal chain
> (8-B1..B10), **never conflated** with it (the §11 freeze model depends on the two Safes never commingling). It is
> the custody home for the **`EulerEarn` shares** that back **all outstanding zipUSD float** (the "protocol's
> holding"). A plain **Gnosis Safe** holds the shares; a deployed **Zodiac Roles-modifier-v2** (audited Gnosis Guild
> infra — `enableModule`'d on the Safe) is the access-control engine; and a thin, authored **`is ReceiverTemplate`
> CRE adapter** (`WarehouseAdminModule`) is the **sole role member** — it decodes the §4.4/§8.5 CRE envelope into
> exactly one of four scoped warehouse ops (SUPPLY / APPROVE / REDEEM / REPAY) and forwards it through
> `Roles.execTransactionWithRole`. The Roles **scope** is the security boundary (params pinned, Call-only); the
> adapter holds **no custody and enforces no scope itself**. Internal senior plumbing driven by the CRE →
> **build-only** (no INFLOW ticket). **No bespoke privileged contract is authored** beyond the ~80-line
> `WarehouseAdminModule`; the scope lives in the audited Roles engine, not in fresh bytecode (decided 2026-06-06,
> user-ratified).
>
> **`EulerEarn` is MOCKED** (it pins solc 0.8.26 ≠ our 0.8.24, the WOOF-04/05 precedent — those tickets mocked
> EulerEarn and fork-tested the live EVK/EVC). The **novel infra is fork-real**: the deployed Roles-v2 mastercopy +
> ModuleProxyFactory + Safe factory/singleton + real USDC on a live Base fork. Mocking the EE pool ALSO removes the
> behavioral unknown that a freshly-created, un-allocated EulerEarn pool may not mint shares on `deposit` (the
> supply-queue/allocation wiring is genuinely item-10). The warehouse's job is to **custody shares + Roles-gate the
> ops** — orthogonal to EulerEarn's internal allocation.

**Deliverable**
One authored contract, two extended/new interfaces, one deploy/wire library, one test (+ test mocks):

- `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` — `contract WarehouseAdminModule is
  ReceiverTemplate` (`x402-cre-price-alerts/interfaces/ReceiverTemplate.sol`, the SAME CRE-receiver base as
  `ZipcodeOracleRegistry`/`ZipcodeController`). **NOT** a Zodiac `Module` — it does **not** get `enableModule`'d on
  the Safe; it is `assignRoles`'d as the Roles **role member** and calls `Roles.execTransactionWithRole(...)`. Holds
  six immutables — `roles` (the Roles-modifier instance), `roleKey` (`bytes32`), `safe` (the warehouse Safe = the
  Roles `avatar`), `eePool`, `usdc`, `repaySink` — plus the inherited immutable Forwarder. Four warehouse-local
  opTypes (the §8.5 byte values), each carrying the payload below, decoded in the overridden `_processReport`:
  | opType | payload decode | built call (`to`, Call-only, value 0) | scope pin (in Roles, not here) |
  |---|---|---|---|
  | `SUPPLY = 1` | `(uint256 amount)` | `eePool.deposit(amount, safe)` | `receiver == avatar` (EqualToAvatar) |
  | `APPROVE = 2` | `(uint256 amount)` | `usdc.approve(eePool, amount)` | `spender == EqualTo(eePool)` |
  | `REDEEM = 3` | `(uint256 shares)` | `eePool.redeem(shares, safe, safe)` | `receiver == owner == avatar` (EqualToAvatar) |
  | `REPAY  = 4` | `(address to, uint256 amount)` | `usdc.transfer(to, amount)` | `to == EqualTo(repaySink)` |
  `_processReport(bytes calldata report)` (the `internal override`): `(uint8 opType, bytes memory payload) =
  abi.decode(report,(uint8, bytes))`; switch opType → build `(address to, bytes memory data)`; revert
  `UnsupportedOpType(opType)` on any other value; then
  `bool ok = roles.execTransactionWithRole(to, 0, data, 0 /* Operation.Call as uint8 — IRoles takes uint8 */,
  roleKey, true); if (!ok) revert RoleExecFailed();`. `value` is **always 0**, `operation` is **always the literal
  `0` (Call)**, `shouldRevert` is **always `true`** — none are ever decoded from the payload. (Note: with
  `shouldRevert=true` a failed inner exec already reverts `ModuleTransactionFailed()` inside the modifier, so the
  `if (!ok)` is unreachable defense-in-depth — keep it, but no test asserts `RoleExecFailed` and the build must not
  rely on reaching it.) The receiver/spender/redeem-owner the adapter **injects** from immutables (belt-and-suspenders
  with the Roles pin); the one field the CRE genuinely varies (`REPAY to`) is **passed through** the payload and
  **guarded by the scope** (`EqualTo(repaySink)`) — the "scope-is-the-guard" architecture. **No generic call
  passthrough, no arbitrary target, no delegatecall, `value == 0` on every exec.** Constructor `(address forwarder,
  address roles_, bytes32 roleKey_, address safe_, address eePool_, address usdc_, address repaySink_)
  ReceiverTemplate(forwarder)` — every arg stored immutable; revert `ZeroAddress()` on any zero **address** arg
  (`roles_`/`safe_`/`eePool_`/`usdc_`/`repaySink_`; `forwarder` is already zero-checked by the `ReceiverTemplate`
  ctor) and `ZeroRoleKey()` on `roleKey_ == 0` (the Roles `NoMembership` sentinel — a zero roleKey would make every
  forward revert `NoMembership`). `event WarehouseOp(uint8 indexed opType, address to, bytes data)` emitted on each
  forward (before the `execTransactionWithRole` call, or after — pick one and assert it).

- `contracts/src/interfaces/zodiac/IRoles.sol` — **EXTEND** the existing minimal interface (WOOF-00; it deliberately
  omitted `scopeFunction` + the condition types). ADD, verified against
  `reference/zodiac-modifier-roles/packages/evm/contracts/`:
  ```solidity
  // Types.sol L14-22  (AbiType): None=0, Static=1, Dynamic=2, Tuple=3, Array=4, Calldata=5, AbiEncoded=6
  // Types.sol L48-105 (Operator): Pass=0, And=1, Or=2, Nor=3, ..., Matches=5, ..., EqualToAvatar=15, EqualTo=16
  // Types.sol L107    (ExecutionOptions): None=0(Call-only), Send=1, DelegateCall=2, Both=3
  // Types.sol L123-128 (ConditionFlat) — fields are enums on-chain but ABI-encode as uint8, so the all-uint8 mirror
  //   is byte-for-byte wire-identical; `memory` here vs the real `memory` param is identical for an external call.
  struct ConditionFlat { uint8 parent; uint8 paramType; uint8 operator; bytes compValue; }
  function scopeFunction(bytes32 roleKey, address targetAddress, bytes4 selector,
      ConditionFlat[] memory conditions, uint8 options) external; // PermissionBuilder.sol L133, onlyOwner
  ```
  Keep the existing `assignRoles` / `execTransactionWithRole` / `scopeTarget` / `allowFunction` declarations. UPDATE
  the file's header note that currently says `scopeFunction` is "intentionally omitted" — it is now required for
  parameter-pinned scoping (`allowFunction` is wildcarded / skips ALL param checks → it would unpin
  receiver/spender/`to`; do NOT use it for this policy).

- `contracts/src/interfaces/euler/IEulerEarn.sol` — **NEW** minimal local interface (the WOOF-00 `[EXT]` house
  posture; do NOT import the `euler-earn/` remap to avoid any OZ-version ambiguity, mirroring
  `ZipDepositModule.sol:18`'s local declaration but with the fuller surface the warehouse + test need):
  `deposit(uint256 assets, address receiver) returns (uint256 shares)`; `redeem(uint256 shares, address receiver,
  address owner) returns (uint256 assets)`; `convertToAssets(uint256 shares) returns (uint256)`;
  `balanceOf(address) returns (uint256)`; `asset() returns (address)`. (Doc-cite `EulerEarn.sol:560/596`.)

- `contracts/src/interfaces/safe/ISafe.sol` — **EXTEND**: ADD `function setup(address[] calldata owners, uint256
  threshold, address to, bytes calldata data, address fallbackHandler, address paymentToken, uint256 payment,
  address payable paymentReceiver) external;` (the Safe initializer; currently ABSENT — the deploy lib needs it).
  Signature matched to the Basescan SafeL2 1.4.1 ABI. Everything else (`enableModule`/`isModuleEnabled`/
  `execTransaction`/`addOwnerWithThreshold`/`getOwners`/`getThreshold`/`isOwner`) already exists.

- `contracts/script/CreditWarehouseDeployer.sol` — a deploy/wire **library/contract** (callable on a fork by the
  test; model `contracts/script/ReservoirMarketDeployer.sol` + `contracts/script/SummonSubstrate.s.sol`).
  Parameterized by `(address godOwner, address eePool, address usdc, address forwarder, address repaySink, uint256
  saltNonce)`; returns `struct Warehouse { address safe; address roles; address adapter; bytes32 roleKey; }`
  (declared in the deployer; the test reads `roleKey` off it — single source of truth). Steps:
  1. **Safe** — `ISafeProxyFactory(SAFE_PROXY_FACTORY_1_3_0).createProxyWithNonce(SAFE_L2_SINGLETON_1_4_1,
     initializer, saltNonce)` where `initializer = abi.encodeWithSelector(ISafe.setup.selector, [godOwner], 1,
     address(0), "", address(0), address(0), 0, payable(address(0)))` (owner=godOwner, threshold 1, no
     fallbackHandler — the Safe only hosts the Roles module + holds ERC-20 EE shares/USDC, no ERC-721/1271 callback
     needed). The 1.3.0 factory is version-agnostic (it CREATE2s a proxy pointing at whatever singleton you pass);
     **VERIFY on the fork** that the proxy's `getOwners()==[godOwner]` and `getThreshold()==1` post-deploy (assert in
     the lib — security: never trust a CREATE2 address blindly; a front-run with different init params would resolve
     to a different address, so an assert catches a mis-deploy).
  2. **Roles proxy** — `IModuleProxyFactory(ZODIAC_MODULE_PROXY_FACTORY).deployModule(ZODIAC_ROLES_MASTERCOPY,
     initializer, saltNonce)` where `initializer = abi.encodeWithSignature("setUp(bytes)", abi.encode(godOwner /*owner*/,
     safe /*avatar*/, safe /*target*/))` (Roles.sol:43/51). **Assert** the proxy's `avatar()`/`target()`/`owner()`
     are as expected post-deploy.
  3. **enableModule** — as the Safe owner, `ISafe(safe).execTransaction(safe, 0,
     abi.encodeWithSelector(ISafe.enableModule.selector, roles), 0 /*Call*/, 0,0,0, address(0), payable(address(0)),
     sig)` where `sig = abi.encodePacked(bytes32(uint256(uint160(godOwner))), bytes32(0), uint8(1))` (the 1/1-owner
     pre-validated signature — note the **`uint256(uint160(...))`** hop; `bytes32(uint160(x))` does NOT compile —
     proven in `SummonSubstrate.s.sol:163`). Roles' `exec` runs through `execTransactionFromModule`, so the modifier
     MUST be an enabled Safe module. Assert `isModuleEnabled(roles)`.
  4. **scope the role** (as Roles owner — all `onlyOwner` on `PermissionBuilder`): `scopeTarget(roleKey, eePool)`;
     `scopeFunction(roleKey, eePool, IEulerEarn.deposit.selector, A, 0)`; `scopeFunction(roleKey, eePool,
     IEulerEarn.redeem.selector, B, 0)`; `scopeTarget(roleKey, usdc)`; `scopeFunction(roleKey, usdc,
     IERC20.approve.selector, C, 0)`; `scopeFunction(roleKey, usdc, IERC20.transfer.selector, D, 0)`. (`options = 0`
     = `ExecutionOptions.None` = Call-only.) `roleKey = keccak256("ZIPCODE_WAREHOUSE_CRE")` (a deploy-lib constant;
     any non-zero `bytes32` is a valid on-chain roleKey — the zodiac-roles-sdk short-string key encoding is an
     off-chain convention reconciled with the CRE track). The `ConditionFlat[]` arrays A–D are pinned in Key
     requirement C. **Tree D's `to`-param operator MUST be `EqualTo` — never `Pass`/parameterized** (a Pass on `to`
     would let a compromised CRE transfer to any address = full drain).
  5. **adapter** — `new WarehouseAdminModule(forwarder, roles, roleKey, safe, eePool, usdc, repaySink)`.
  6. **assignRoles** — as Roles owner, `roles.assignRoles(adapter, [roleKey], [true])` (Roles.sol:69).
  **Transient-owner handoff (build-discovered):** because the 1/1-owner pre-validated `execTransaction` signature
  requires `msg.sender == owner`, the **deployer contract** must be the transient Safe + Roles owner DURING wiring
  (it makes the `enableModule` `execTransaction` and the `onlyOwner` `scopeTarget`/`scopeFunction`/`assignRoles`
  calls), then hand off to `godOwner` at the end: `ISafe(safe).swapOwner(SENTINEL /*0x1*/, deployer, godOwner)` (via
  an owner `execTransaction`) + `roles.transferOwnership(godOwner)`. Net effect is identical (final owner =
  `godOwner` on both); the deployer holds ownership only for the duration of `deploy()`. Assert the final owners.
  7. **(item-10, NOT here)** `adapter.setExpectedWorkflowId(...)` + `renounceOwnership()` immutability seal (the
     §4.4/§9 S11 pattern, asserted-before-renounce). The contract supports it via the inherited `ReceiverTemplate`
     surface; the deploy lib does NOT renounce and does NOT set identity expectations (the test needs the live
     un-renounced contract; expectations stay 0 in M1 so the workflow-id check is skipped — exactly as the kept
     WOOF-02/03/05 tests).

- `contracts/test/WarehouseAdminModule.t.sol` — fork test on live Base (`is ForkConfig`, selecting the **pinned**
  block via `_selectBaseFork()`). It deploys, via `CreditWarehouseDeployer`: the warehouse Safe, the Roles proxy
  (REAL mastercopy + ModuleProxyFactory), the scope, the adapter. The **`forwarder` is a test address**
  (`makeAddr("forwarder")`) injected at construction and `vm.prank`'d to drive `onReport` (mirrors
  `ZipcodeController.t.sol` — no dependency on the live Keystone; identity expectations are 0 so the workflow-id
  check is off and `metadata` can be empty bytes). The **`eePool` is a `MockEulerEarn`** test mock (next bullet);
  USDC is real Base USDC (`deal` the Safe). See **Done when** for the full matrix.

- `contracts/test/mocks/MockEulerEarn.sol` (test-only) — a minimal 0.8.24 ERC-4626-ish vault over real USDC: `deposit`
  pulls `assets` USDC via `transferFrom` (so APPROVE→SUPPLY ordering is real) and mints 1:1 shares to `receiver`,
  **reverting `ZeroShares()` on `deposit(0)`** (mirrors EulerEarn `EulerEarn.sol:565` so the "scope passes, inner
  exec fails → `ModuleTransactionFailed`" branch is testable); `redeem` burns `shares` from `owner` and transfers
  `assets` USDC to `receiver` (no zero-check — `redeem(0)` is a no-op success, mirroring `EulerEarn.sol:604`);
  `convertToAssets`/`balanceOf`/`asset` ERC-4626 1:1. A second tiny `MockMember` contract (an address the test
  `assignRoles`' to the same role) is used to prove the scope rejects redirected params from a real role member
  (Done-when 5/6/9/10).

**Spec §**
`claude-zipcode.md` §4.5 (the `CreditWarehouse` bullet + sub-bullets, `:488-536`); §8.5 (the warehouse op-set /
opType bytes / pinned-call table, the post-spec-edit version this window); §4.4 (report envelope `abi.encode(uint8,
bytes)` `:424-426` + the immutable-Forwarder / `setExpectedWorkflowId` / renounce seam `:358-369`); §4.5
`ZipDepositModule` (the zap deposits with the **warehouse Safe as the EE-share `receiver`**, `:537-545`); §6.1/§8.3
senior queue (draws via REDEEM→REPAY); §11/§4.6 recovery (via REPAY). `reports/baal-spec.md §11` (8-Bw build-grade companion)
+ §13 (build order). **No §17 decision reopened** (CRE-permissioned single writer; senior/junior Safes never
conflated; venue-agnostic; no on-chain economic liquidation; Roles-v2-over-bespoke; GOD-EOA→multisig owner).

**Model from** (VERIFIED this window against actual `reference/` + the kept `contracts/` tree — file:line):
- **Roles-modifier-v2 (deployed mastercopy on Base; do NOT compile its OZ-4.9.3 / `>=0.8.17` source — OZ-4/5
  collision, the WOOF-00 doctrine):** `reference/zodiac-modifier-roles/packages/evm/contracts/`:
  - `Roles.sol:43` `constructor(address _owner, address _avatar, address _target)` → `setUp(abi.encode(owner,
    avatar, target))` (`:51`); `assignRoles(address module, bytes32[] roleKeys, bool[] memberOf) onlyOwner` (`:69`);
    `execTransactionWithRole(address to, uint256 value, bytes data, Operation operation, bytes32 roleKey, bool
    shouldRevert) returns (bool)` — **not payable** (`:153`).
  - `PermissionBuilder.sol`: `scopeTarget(bytes32, address) onlyOwner` (`:86`); `scopeFunction(bytes32, address,
    bytes4, ConditionFlat[] memory, ExecutionOptions) onlyOwner` → `Integrity.enforce(conditions)` (`:133-140`); all
    `PermissionBuilder` mutators + `assignRoles` are `onlyOwner` (a role MEMBER cannot scope/assign — no
    member→owner escalation; verified).
  - `Types.sol`: `ConditionFlat{uint8 parent; AbiType paramType; Operator operator; bytes compValue}` (`:123-128`);
    `AbiType` (`:14-22`, Static=1/Calldata=5); `Operator` (`:48-105`, Pass=0/Matches=5/EqualToAvatar=15/EqualTo=16);
    `ExecutionOptions.None=0` = Call-only (`:107`).
  - `Integrity.sol`: root = index 0, `parent==0` (`:42`, `UnsuitableRootNode`), `paramType==Calldata` +
    `operator==Matches` + empty `compValue` (`:62-73`, `:247-249`); `Pass` empty `compValue` (`:51-54`); `EqualTo`
    `compValue.length>0 && %32==0` (`:92-103`); `EqualToAvatar` valid **only** on `Static` + **must** be empty
    `compValue` (`:85-91`). **The four trees A–D below pass `Integrity.enforce` as written** (reference-verifier
    confirmed).
  - `PermissionLoader.sol:67-72` — `EqualToAvatar` is patched at scope-load to `EqualTo` with `compValue =
    keccak256(abi.encode(avatar))` (we pass empty bytes; the modifier substitutes the live avatar at load).
  - `PermissionChecker.sol`: Call-only `:187-211` (`value>0 && options∉{Send,Both}`→`SendNotAllowed`=4;
    `DelegateCall && options∉{DelegateCall,Both}`→`DelegateCallNotAllowed`=1); non-member → `NoMembership()`
    (`:34/767`); scope/param violation → `ConditionViolation(Status, bytes32)` (`:64/775`, `ParameterNotAllowed`=7);
    un-scoped target → `ConditionViolation(TargetAddressNotAllowed,…)`; un-scoped selector on a scoped target →
    `ConditionViolation(FunctionNotAllowed,…)`. A brand-new role default-denies everything (verified: Clearance.None).
    `_Periphery.setTransactionUnwrapper` is `onlyOwner` (the multisend-unwrap bypass is closed to members).
  - **Addresses (Base 8453, `contracts/script/BaseAddresses.sol`, all live-bytecode-confirmed via `cast` this
    window):** `ZODIAC_ROLES_MASTERCOPY = 0x9646fDAD…337` (`:43`); `ZODIAC_MODULE_PROXY_FACTORY = 0x000000000000aDdB…236`
    (`:44`) — `deployModule(address masterCopy, bytes initializer, uint256 saltNonce) returns (address)`
    (`reference/zodiac-core/contracts/factory/ModuleProxyFactory.sol:37`; proxy salt `=
    keccak256(abi.encodePacked(keccak256(initializer), saltNonce))` `:44`). (The `0xce0042…b868…` in
    `mastercopies.json` is the SingletonFactory for WriteOnce storage — NOT the module factory; do not use it.)
- **EulerEarn (MOCKED — solc 0.8.26):** `reference/euler-earn/src/EulerEarn.sol`: `deposit(uint256 assets, address
  receiver) returns (uint256 shares)` (`:560`, reverts `ZeroShares` `:565`); `redeem(uint256 shares, address
  receiver, address owner) returns (uint256 assets)` (`:596`, **owner is the 3rd arg** — resolves the §4.5 open
  item; `redeem(0)` no-op `:604`); `withdraw(...)` (`:580`). The mock mirrors these exactly. (The local
  `IEulerEarn` interface the adapter uses matches the deposit/redeem selectors.)
- **ReceiverTemplate base** (identical to the kept registry/controller): `reference/x402-cre-price-alerts/contracts/
  interfaces/ReceiverTemplate.sol` — `constructor(address forwarder)` reverts on zero (`:42`); `onReport(bytes
  metadata, bytes report)` gated on the immutable `s_forwarderAddress`, reverts `InvalidSender` for a non-Forwarder
  caller (`:78-120`, the gate ~`:83`), calls `_processReport(report)` (`:119`); abstract `_processReport(bytes
  calldata) internal virtual` (`:232`, virtual-overridable); `setExpectedWorkflowId` (`:184`) + the workflow-id
  check skipped when expected==0 (~`:88/:91`); immutability by `renounceOwnership()` (OZ-5 `Ownable`, custom
  `OwnableUnauthorizedAccount`). Kept models: `contracts/src/ZipcodeOracleRegistry.sol:4,67,93`;
  `contracts/src/ZipcodeController.sol:119` (the envelope decode) + its `MaliciousVenue` re-entry/`InvalidSender`
  test (`:98-109`) as the re-entrancy model.
- **Local Zodiac/Safe interfaces (REUSE/EXTEND — authored + on-chain-verified at WOOF-00/8-B1):**
  `contracts/src/interfaces/zodiac/IRoles.sol` (EXTEND), `IModuleProxyFactory.sol`,
  `contracts/src/interfaces/safe/ISafe.sol` (EXTEND — add `setup`) / `ISafeProxyFactory.sol`. Safe-deploy +
  owner-`execTransaction` 1/1-sig pattern proven in `contracts/test/SummonSubstrate.t.sol` +
  `contracts/script/SummonSubstrate.s.sol:163`.
- **Deploy-lib + exec conventions:** `contracts/script/ReservoirMarketDeployer.sol` (a callable deploy library a
  fork test drives); `contracts/src/supply/szipUSD/RecycleModule.sol` (ctor-immutable + `ZeroAddress` style — note
  8-Bw routes through Roles, NOT zodiac `Module`'s `execAndReturnData`, so it does NOT inherit `Module`).

**Starting state**
- `contracts/` builds green (`forge build`; `forge test` 401/401 per PROGRESS). The supply tree, BaseAddresses,
  ForkConfig (pinned `BASE_FORK_BLOCK`), the zodiac/safe/euler interfaces, and the `ReceiverTemplate` remap exist
  and are on-chain-verified.
- `reference/` submodules initialized. `BASE_RPC_URL` set (the `base` rpc endpoint in `foundry.toml`).
- SPDX `// SPDX-License-Identifier: GPL-2.0-or-later` + `pragma solidity 0.8.24;` on every authored file.
- `contracts/src/supply/CreditWarehouse/` exists but is EMPTY.

**Do NOT**
- **Do NOT compile** any Roles-modifier / Safe / EulerEarn **implementation** source (OZ-4.9.3 vs our OZ-5; solc
  `>=0.8.17`/`0.8.26` vs 0.8.24). Author local minimal interfaces + **fork-interact** with the deployed Roles/Safe
  infra; **mock** EulerEarn. Only `WarehouseAdminModule.sol` + the interface edits + the deploy lib + the test/mocks
  are authored.
- **Do NOT** make `WarehouseAdminModule` a Zodiac `Module` / `enableModule` it on the Safe. It is a **role member**
  (`assignRoles`'d), with zero direct Safe authority; every effect routes through `Roles.execTransactionWithRole`.
- **Do NOT** put scope/whitelist logic inside `WarehouseAdminModule` (no per-op address checks beyond injecting the
  immutables). The **scope is the guard** and lives in the Roles policy; the adapter is a thin encoder.
- **Do NOT** widen the op-set beyond SUPPLY/APPROVE/REDEEM/REPAY, add a generic-call opType, decode
  `value`/`operation` from the payload, allow `value != 0`, or allow `Operation.DelegateCall` —
  `execTransactionWithRole` is always `(…, 0, …, 0/*Call*/, roleKey, true)`.
- **Do NOT** scope with `allowTarget`/`allowFunction` (wildcarded — no param check). Use `scopeFunction` + the
  `ConditionFlat[]` trees. **Do NOT** author tree D with `Pass` (or parameterize the operator) on the REPAY `to` —
  it MUST be `EqualTo(repaySink)`, or a compromised CRE drains to any address.
- **Do NOT** renounce the adapter's ownership or set its identity expectations inside the deploy lib / test (item-10
  /S11 seals immutability after wiring; the test needs the live un-renounced contract).
- **Do NOT** touch the junior Baal `szipUSD` Safe, NAV oracle, or any engine module — 8-Bw is the **senior** side,
  structurally separate.

**Key requirements**

**A. `WarehouseAdminModule` — the thin CRE adapter (`is ReceiverTemplate`).**
1. Six immutables + the inherited Forwarder; ctor reverts `ZeroAddress()` on any zero address arg and `ZeroRoleKey()`
   on `roleKey == 0`.
2. `_processReport` decodes `(uint8 opType, bytes payload)`, switches per the opType table, reverts
   `UnsupportedOpType(opType)` otherwise, forwards via `roles.execTransactionWithRole(to, 0, data, 0, roleKey,
   true)`, asserts `ok`, emits `WarehouseOp(opType, to, data)`. `value`/`operation`/`shouldRevert` are hardcoded
   literals (`0`/`0`/`true`), never decoded.
3. Calldata is built with `abi.encodeWithSelector` against the `IEulerEarn` deposit/redeem selectors + the ERC-20
   `approve`/`transfer` selectors; receiver (`safe`), spender (`eePool`), redeem owner/receiver (`safe`,`safe`) are
   **injected from immutables**; only `REPAY`'s `to` comes from the payload (guarded by the scope).
4. Inherits the immutable-Forwarder gate + `setExpectedWorkflowId`/`renounceOwnership` immutability seam unchanged
   (no override — those are non-virtual; immutability by renounce, per §4.4 + the kept registry/controller).

**B. The four warehouse ops (resolving the §4.5/§8.5 open items — folded back into the spec this window).**
1. **REDEEM arg order:** `redeem(shares, receiver, owner)` — owner is the **3rd** arg (`EulerEarn.sol:596`). Adapter
   passes `redeem(shares, safe, safe)`.
2. **Redeemed USDC → Safe** (not direct-to-sink): REDEEM pins `receiver == owner == avatar`; a separate **REPAY**
   distributes. (Fully avatar-pinned; the queue/recovery never read EulerEarn directly.)
3. **APPROVE amount scope-free; CRE passes exact.** `amount` cannot be a static pin (varies per deposit); `spender`
   pinned to `eePool`. The CRE policy is **exact-amount per deposit** (never a standing infinite — an 8-B11/CRE
   obligation, not a contract cap, since EulerEarn is factory-deployed and may carry a curator surface).
4. **REPAY `to` = a single configured `repaySink`** (the §4.5/§8.5 `LOANBOOK` noun is retired): M1 sink =
   `ZipRedemptionQueue` (item 9, wired at item-10); M2 recovery sink via owner re-scope. Scope pins `to ==
   EqualTo(repaySink)`. Test uses a stand-in sink address.

**C. The Roles scope (the security boundary — exact `ConditionFlat[]` trees, BFS order, root at index 0).**
All `scopeFunction(..., options = 0 /* None = Call-only */)`. Each tree: index 0 = root `{parent:0, paramType:5
(Calldata), operator:5 (Matches), compValue:""}`, then one child per parameter (all `parent:0`, in arg order):
- **A — `deposit(uint256 assets, address receiver)`:** `[ root, {1,0,""} /*assets: Static,Pass*/, {1,15,""}
  /*receiver: Static,EqualToAvatar*/ ]`.
- **B — `redeem(uint256 shares, address receiver, address owner)`:** `[ root, {1,0,""} /*shares*/, {1,15,""}
  /*receiver*/, {1,15,""} /*owner*/ ]`.
- **C — `approve(address spender, uint256 amount)`:** `[ root, {1,16,abi.encode(eePool)} /*spender: Static,EqualTo,
  32 bytes*/, {1,0,""} /*amount*/ ]`.
- **D — `transfer(address to, uint256 amount)`:** `[ root, {1,16,abi.encode(repaySink)} /*to: Static,EqualTo,
  32 bytes*/, {1,0,""} /*amount*/ ]`.
`EqualToAvatar` (15) children carry **empty** `compValue` (the modifier substitutes `keccak256(abi.encode(avatar))`
at load). `EqualTo` (16) `compValue` is the 32-byte `abi.encode(address)`. `scopeTarget` once per target (`eePool`,
`usdc`) before its `scopeFunction`s.

**D. Deploy/wire library** — the 7 steps above (renounce/identity deferred to item-10), returning the `Warehouse`
struct, asserting post-deploy init state (Safe owners/threshold; Roles avatar/target/owner) before scoping.

**Done when** (every check a passing `forge test` assertion; fork = live Base via `ForkConfig._selectBaseFork()`,
`block.chainid == 8453`, pinned block):
1. **Deploy/wire** — `CreditWarehouseDeployer` produces a Safe (owner = test EOA, threshold 1), a Roles proxy
   (`avatar==target==Safe`, `owner==testEOA`), `isModuleEnabled(roles)` on the Safe, the role scoped (A–D), the
   adapter deployed + `assignRoles`'d. Assert the adapter immutables + `roleKey != 0` (read off `Warehouse.roleKey`).
2. **Constructor reverts** — each zero address arg → `ZeroAddress()`; `roleKey==0` → `ZeroRoleKey()`.
3. **SUPPLY (happy)** — `deal` the Safe USDC; drive APPROVE then SUPPLY as the (test) Forwarder (`vm.prank(forwarder);
   adapter.onReport("", abi.encode(uint8(2), abi.encode(amount)))` then opType 1). Assert `eePool.balanceOf(safe)`
   ↑ (shares to the Safe), Safe USDC ↓ by `amount`, adapter/Roles hold no shares/USDC. `expectEmit
   WarehouseOp(2,…)` and `WarehouseOp(1,…)`.
4. **REDEEM (happy)** — redeem a slice; shares ↓, USDC returned **to the Safe** (`receiver==owner==Safe`). `expectEmit`.
5. **REPAY (happy)** — REPAY `(repaySink, amount)`; `repaySink` USDC ↑ by `amount`, Safe ↓. `expectEmit`.
6. **Scope pin load-bearing (NOT just adapter hardcoding)** — `assignRoles` a `MockMember` to the same role; it calls
   `roles.execTransactionWithRole(eePool, 0, deposit(amount, ATTACKER), 0, roleKey, true)` →
   `ConditionViolation(Status.ParameterNotAllowed /*7*/, …)`. Same for REPAY `transfer(ATTACKER,…)`, `transfer(0,…)`,
   `transfer(eePool,…)` → `ParameterNotAllowed`; and `transfer(repaySink,…)` from the member SUCCEEDS (proves the
   pin is exactly `repaySink`). **Pin the Status ordinal in the `expectRevert`, not just the selector.**
7. **Call-only** — the `MockMember` tries `execTransactionWithRole(eePool, 1 /*value*/, deposit(...), 0, roleKey,
   true)` → `ConditionViolation(SendNotAllowed /*4*/,…)`; and operation `1 /*DelegateCall*/` →
   `ConditionViolation(DelegateCallNotAllowed /*1*/,…)`.
8. **Non-member** — an unassigned EOA/contract calls `execTransactionWithRole(...)` → **`NotAuthorized(sender)`**
   (`0x4a0bfec1`), NOT `NoMembership()`. *(Build-discovered on-chain: the DEPLOYED mastercopy `0x9646…D337` is a
   newer Roles version where `assignRoles` also registers the member in the zodiac-core `modules[]` mapping and
   `_authorize` is fronted by the `moduleOnly()` gate — `Modifier.sol`; a never-assigned caller is absent from
   `modules[]`, so `moduleOnly` reverts `NotAuthorized` BEFORE the inner `NoMembership()` check is reached. The
   vendored reference Roles has no such gate; the build follows the live chain.)*
9. **Non-owner cannot scope/assign** — a non-owner calls `roles.assignRoles(...)` / `scopeFunction(...)` → reverts
   the **custom error `OwnableUnauthorizedAccount(address)`** (`0x118cdaa7`), NOT a string. *(Build-discovered: the
   deployed mastercopy uses the zodiac-core OZ-5-style `Ownable` custom error — `reference/zodiac-core/contracts/
   factory/Ownable.sol` — not the OZ-4.9.3 require-string the vendored package suggested.)*
10. **Escalation blocked** — the `MockMember` relays `to == safe` with `Safe.enableModule(attacker)` /
    `addOwnerWithThreshold(...)` calldata → `ConditionViolation(TargetAddressNotAllowed,…)` (the Safe is never
    `scopeTarget`'d). And an un-scoped selector/target (e.g. `eePool.withdraw(...)`) → `FunctionNotAllowed` /
    `TargetAddressNotAllowed`.
11. **Adapter authority** — `onReport` from a non-Forwarder → `InvalidSender`; unsupported opType → `UnsupportedOpType`.
    A re-entrancy attempt (re-enter `onReport` from a callback) is rejected by the Forwarder gate (mirror
    `ZipcodeController.t.sol`'s `MaliciousVenue`/F-10 pattern) → `InvalidSender`.
12. **Inner-exec failure → `ModuleTransactionFailed` (scope passes, exec fails)** — zero-SUPPLY (`deposit(0)` →
    mock `ZeroShares`) → `ModuleTransactionFailed`; SUPPLY without a prior APPROVE (allowance pull fails) →
    `ModuleTransactionFailed`; REDEEM more shares than held → `ModuleTransactionFailed`; REPAY more USDC than held →
    `ModuleTransactionFailed`. (Pin the asymmetry: `redeem(0)` is a no-op success, not a revert.)
13. **Malformed payload** — a short/garbage `report` reverts cleanly at `abi.decode` (no silent mis-execution).
14. **Atomicity** — after any reverted op (12/13), assert the Safe's shares + USDC are **unchanged** (no partial
    effect).
15. **Senior NAV mark** — `assertApproxEqAbs(eePool.convertToAssets(eePool.balanceOf(safe)), suppliedNetOfRedeemed,
    1)` (floor-rounding tolerance) — the §4.5 senior NAV mark the queue/oracle will read.
16. `forge build` clean; the **full** `forge test` suite green (no regression to the existing 401). Every external
    signature + address re-verified on-chain (`cast` / fork) — NOT merely "compiles."

**Depends on**
- 8-S2b (two-Safe custody + `CreditWarehouse` spec, DONE) — the §4.5 source.
- WOOF-00 scaffold (DONE) — BaseAddresses, ForkConfig, the zodiac/safe interfaces, the `ReceiverTemplate` remap, the
  no-OZ-collision build config.
- Live Base infra: Roles-v2 mastercopy + ModuleProxyFactory + Safe factory/singleton (all on-chain-verified).
  **Independent of the junior 8-B1..B10 chain.**

**Inbound cross-ticket obligations discharged**
- **§4.5/§8.5 "Open items for the 8-Bw ticket"** — RESOLVED + folded back into `claude-zipcode.md` this window:
  EulerEarn `redeem` owner-is-3rd-arg; redeemed USDC → Safe-then-REPAY; APPROVE amount scope-free + CRE exact-amount;
  REPAY `to` = pinned `repaySink` (LOANBOOK noun retired); opType bytes 1/2/3/4 pinned in §8.5.
- **`8-Bw / item-10` · reservoir borrow vault = warehouse resting vault (from 8-B5, PROGRESS :261)** — **routed to
  item-10.** Pointing EulerEarn's supply queue at the 8-B5 reservoir borrow vault (so it IS the `USDC Resting
  Vault`) is a **curator/allocator op on EulerEarn at deploy**, NOT a `WarehouseAdminModule` concern (the adapter's
  op-set is SUPPLY/APPROVE/REDEEM/REPAY; it never configures the allocator). 8-Bw establishes the warehouse + its EE
  custody; the live allocation stays item-10. The obligation row stays **OPEN** (jointly owed by item-10).

**New cross-ticket obligations this item creates**
- **Item 10 / deploy** · `enableModule` + scope + `assignRoles` + the §4.4/S11 `setExpectedWorkflowId` →
  `renounceOwnership()` seal (assert `getExpectedWorkflowId() != 0` before renounce; **do NOT fund the warehouse
  before the identity is sealed** — while `expectedWorkflowId==0` the per-workflow gate is OFF and any
  Forwarder-relayed workflow could drive ops); the **real `repaySink` = `ZipRedemptionQueue`** wired into the scope;
  the **GOD-EOA → multisig** owner upgrade (`swapOwner`/`addOwnerWithThreshold` on both the Safe and the Roles
  owner); the EulerEarn curator/timelock-0 + `baseUsdcMarket` supply-queue config (reuse WOOF-05), pointing the
  resting vault at the 8-B5 reservoir vault. **Assert at deploy:** `repaySink != juniorBaalSafe` and `safe !=
  juniorBaalSafe` (the §11 non-commingling invariant); the proxy init state (owner/avatar/target; owners/threshold)
  matches expectations before wiring (front-run-safe).
- **Item 10 / 8-B11 (defense-in-depth — ELEVATED from optional to recommended, security HIGH)** · because this
  single Safe backs ALL zipUSD float and a compromised CRE can `REDEEM`-then-`REPAY` to the sink, add a Roles
  **`WithinAllowance`** rate-limit and/or a **Delay Modifier** (owner-cancellable cooldown) on the drain-capable
  REDEEM/REPAY ops; the `ZipRedemptionQueue` (`repaySink`) MUST be **immutable/non-sweepable** (the residual
  chokepoint). The CRE MUST issue **exact-amount APPROVE** per SUPPLY (never a standing infinite); verify at item-10
  whether the live EulerEarn is upgradeable / has a curator able to alter pull behavior.
- **Item 9 / `ZipRedemptionQueue`** · `settleEpoch` redeems via REDEEM (USDC → Safe) then pulls via REPAY to the
  queue (`repaySink == queue`); the queue never calls EulerEarn directly.
- **CRE track (§8 / CRE-04)** · author the warehouse envelope (opType 1/2/3/4, payloads per §8.5) into the §8
  producer spec with a **distinct Forwarder identity / workflowId** from the controller/registry/oracle receivers;
  reconcile the on-chain `roleKey = keccak256("ZIPCODE_WAREHOUSE_CRE")` with the zodiac-roles-sdk off-chain key
  encoding.

**Audit-sweep obligation**
The §4.5/PROGRESS audit-sweep (author the warehouse deploy/wire into `audit/2.md` Phase S — the `CreditWarehouse`
Safe + Roles `enableModule` + the opType 1/2/3/4 L-steps + revert N-steps + the S8 wiring — and the
`audit/3-results.md` authority rows the `EXCISED` markers point at) is **DEFERRED to the item-10 /
engine-integration pass**, exactly as the 8-B5..B10 engine modules deferred theirs (PROGRESS rows 258/263/272/276/
277/286): a Phase-S deploy/wire trace is not authorable against a standalone un-wired warehouse (no live
controller/queue/deposit-module). Logged as an item-10 obligation (added to PROGRESS's "Open cross-ticket
obligations" at conclude).
