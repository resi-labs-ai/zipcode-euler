# 8-Bw — CreditWarehouse Safe + `WarehouseAdminModule` (wiring map)

> Source of truth = the kept code: `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` +
> `contracts/script/CreditWarehouseDeployer.sol`. Ticket `tickets/sodo/8-Bw-credit-warehouse.md` + report
> `reports/8-Bw-report.md` + spec `claude-zipcode.md` §4.5/§8.5 are intent — the code is the final form.
> (Build-phase doctrine, §17/2026-06-09: the adapter's cross-component pointers are **Timelock-settable**, not
> immutable, and ownership is **transferred to the Timelock**, not renounced; re-freeze to immutable is DEFERRED
> to pre-prod. The older "six immutables" / "renounce" wording in the ticket/report is reconciled here.)
>
> Last reconciled against the kept code @ `5f3706d` (2026-06-10). If the contract has moved past that commit,
> re-diff this doc before trusting its claims.

**In one breath:** a Gnosis Safe holds the EulerEarn shares that back every zipUSD in circulation. A Chainlink
CRE workflow can move funds between exactly three places — the Safe, the EulerEarn pool, and the redemption
queue — and nowhere else. This doc maps how that "nowhere else" is enforced.

## Role
The **senior-backing custody** — the SENIOR side of the protocol, structurally separate from the junior
`szipUSD` Baal chain (8-B1..B10) and **never commingled** with it (the §11 freeze model depends on the two Safes
never touching). A plain **Gnosis Safe** custodies the `EulerEarn` pool shares that back **all outstanding zipUSD
float** (the "protocol's holding"). The Safe's **admin** is a deployed **Zodiac Roles Modifier v2** instance
(audited Gnosis Guild infra — `enableModule`'d on the Safe), **scoped** to exactly the warehouse op-set
(SUPPLY/APPROVE/REDEEM/REPAY), Call-only, params pinned. The **CRE seam** is a thin authored
`WarehouseAdminModule is ReceiverTemplate` — the **sole Roles role member** (`assignRoles`'d, NOT a Zodiac
`Module`, NEVER `enableModule`'d). It holds **no custody and enforces no scope**: it is a pure encoder that
decodes the §4.4/§8.5 CRE report envelope into exactly one of the four pinned ops and forwards it through
`Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`. **The security boundary is the Roles scope,
not this bytecode** (the user-ratified "no bespoke privileged contract" decision, 2026-06-06).

## Custody character — the Safe accumulates SHARES; USDC is pure pass-through (load-bearing)
The warehouseSafe is a **share-accumulator, not a USDC account.** It holds `EulerEarn` shares; free USDC lives
inside the EE vault (the reservoir line), never as a standing Safe balance. The Safe's value grows two ways, both
in **shares**: (1) its existing shares **appreciate** as credit-line interest (loan APR) accrues into the vault
(`convertToAssets` rises); (2) it is wired as the EE pool's **`feeRecipient`** (`DeployMainnet.s.sol:153` /
`DeployLocal.s.sol:146` / `SiloDeployer.s.sol:163` — `eePool.setFeeRecipient(warehouseSafe)`), so EE mints its
performance-fee cut as **fresh shares to the Safe**.

**The ONLY USDC that ever lands naked in the Safe is REDEEM proceeds** (`eePool.redeem(shares, warehouseSafe,
warehouseSafe)`, the REDEEM op below). Every other inflow is shares or read-only, verified across the tree:
- **Supplier deposits/zap** bypass the Safe — `ZipDepositModule` calls `eePool.deposit(usdcIn, warehouseSafe)`
  (`ZipDepositModule.sol:125,152`): USDC → EE, **shares** → Safe. Same for the engine's `RecycleModule` recycle
  stream (`eePool.deposit(amount, warehouseSafe)`).
- **Loss-recovery** slash proceeds route to the **`adminSafe`**, not here (`LienXAlphaEscrow.sol:23,62`).
- **The 0.5% draw fee** (`EulerVenueAdapter.sol:451-452`, `feeBps=50`) routes to the **`adminSafe`** — a DIFFERENT
  destination from the EE pool fee above (which is shares → warehouseSafe). Do not conflate the two fees.
- `SeniorNavAggregator` only **reads** `convertToAssets(balanceOf(warehouseSafe))` / `maxWithdraw(warehouseSafe)`.

**Consequence (why the CRE-02b funding leg is safe):** because REDEEM is the sole USDC source, the Safe's standing
USDC balance *is* redemption proceeds — so the funding loop's REPAY can size its sink off `usdc.balanceOf(Safe)`
with nothing to conflate it with (no recovery/deposit cash is ever parked here). The SUPPLY op only ever consumes
Safe USDC back into EE. (Barring an out-of-band manual transfer to the Safe, which is an ops concern, not a path
the contracts create.)

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `WarehouseAdminModule` (`is ReceiverTemplate`) | The CRE adapter / role member. Inherits the Forwarder gate (`onReport`) — **Timelock-settable, not immutable** (`ReceiverTemplate is Ownable`, `setForwarderAddress`/identity are `onlyOwner`, §17; as-built correction); overrides `_processReport` to decode `(uint8 opType, bytes payload)` → one of four `abi.encodeWithSelector` calls → `roles.execTransactionWithRole(...)`. Six wiring slots (`roles`/`roleKey`/`warehouseSafe`/`eePool`/`usdc`/`redemptionBox`), all Timelock-settable. No custody, no Safe authority. **PARITY:** the injected `warehouseSafe` and the Roles modifier's `avatar` are independent slots — `setWarehouseSafe` MUST be paired with the Roles `setAvatar` (post-check `roles.avatar() == safe`) or SUPPLY/REDEEM brick (fail-closed). |
| `CreditWarehouseDeployer` (`contracts/script/`) | The callable deploy/wire library (fork-driven). Stands up the Safe + Roles proxy + scope + adapter against LIVE Base infra, as the **transient** owner of both, then hands ownership to `godOwner`. Asserts every proxy init state before scoping. Does NOT renounce / does NOT seal identity (item-10's job). |
| Zodiac Roles Modifier v2 (deployed external) | The audited access engine. A proxy of mastercopy `ZODIAC_ROLES_MASTERCOPY 0x9646…D337` cloned via `ZODIAC_MODULE_PROXY_FACTORY 0x0000…a236`; `setUp(abi.encode(owner, avatar, target))` = `(deployer→godOwner, safe, safe)`. `enableModule`'d on the Safe; holds the scope (trees A–D) + the role membership. The wildcarded `allowFunction` is deliberately NOT used. |
| The warehouse Gnosis Safe (deployed external) | Owner = `godOwner` (threshold 1, no fallbackHandler); the Roles `avatar`/`target`; the EE-share + USDC custodian. Proxy of `SAFE_L2_SINGLETON_1_4_1` via `SAFE_PROXY_FACTORY_1_3_0`. |
| `IEulerEarn` / `IRoles` / `ISafe` (local interfaces) | Minimal local interfaces (interface+fork posture; EulerEarn itself is mocked in test — solc 0.8.26 ≠ 0.8.24). `IRoles` was EXTENDED with `scopeFunction` + `ConditionFlat`; `ISafe` with `setup`. |

## Wiring — internal

### Constructor + the wiring slots
`constructor(address forwarder, address roles_, bytes32 roleKey_, address safe_, address eePool_, address usdc_,
address redemptionBox_) ReceiverTemplate(forwarder)`. The base ctor reverts on a zero `forwarder`; the body reverts
`ZeroAddress()` if any of `roles_`/`safe_`/`eePool_`/`usdc_`/`redemptionBox_` is zero, and `ZeroRoleKey()` if
`roleKey_ == bytes32(0)` (a zero key is the Roles `NoMembership` sentinel — every forward would revert). The six
fields are stored as **mutable state** (not `immutable`), each with an `onlyOwner` setter (`setRoles`/`setRoleKey`/
`setWarehouseSafe`/`setEePool`/`setUsdc`/`setRedemptionBox`, emitting `WiringSet`/`RoleKeySet`) — the §17 build-phase
Timelock-re-point seam. The setters re-assert non-zero (and `setRoleKey` re-asserts non-zero key).

### The §8.5 envelope decode (`_processReport`, `internal override`)
`(uint8 opType, bytes memory payload) = abi.decode(report, (uint8, bytes))`, then a switch on the four constants
`SUPPLY=1` / `APPROVE=2` / `REDEEM=3` / `REPAY=4`, else `revert UnsupportedOpType(opType)`:

| opType | payload decode | built `(to, data)` (selector) | identity source |
|---|---|---|---|
| `SUPPLY = 1` | `(uint256 amount)` | `to = eePool`; `IEulerEarn.deposit(amount, safe)` | `receiver = safe` injected |
| `APPROVE = 2` | `(uint256 amount)` | `to = usdc`; `IERC20.approve(eePool, amount)` | `spender = eePool` injected |
| `REDEEM = 3` | `(uint256 shares)` | `to = eePool`; `IEulerEarn.redeem(shares, safe, safe)` | `receiver = owner = safe` injected (owner is the **3rd** arg, `EulerEarn.sol:596`) |
| `REPAY = 4` | `(address dest, uint256 amount)` | `to = usdc`; `IERC20.transfer(redemptionBox, amount)` | `dest` asserted `== redemptionBox` (`revert WrongRedemptionBox(dest)`), then `redemptionBox` injected — self-enforced AND scope-pinned `EqualTo(redemptionBox)` |

Then `emit WarehouseOp(opType, to, data)` and `bool ok = roles.execTransactionWithRole(to, 0, data, OP_CALL,
roleKey, true); if (!ok) revert RoleExecFailed();`. The three trailing args are **hardcoded literals, never
decoded**: `value = 0`, `operation = OP_CALL` (`uint8 private constant OP_CALL = 0`, Zodiac core
`Operation.Call`), `shouldRevert = true`. The `if (!ok)` is unreachable defense-in-depth — with
`shouldRevert=true` the modifier already reverts `ModuleTransactionFailed` on a failed inner exec.

### roleKey
`roleKey = keccak256("ZIPCODE_WAREHOUSE_CRE")` — a `CreditWarehouseDeployer.ROLE_KEY` constant threaded
identically into (a) the Roles scope (`scopeTarget`/`scopeFunction`/`assignRoles`) and (b) the adapter ctor. Any
non-zero `bytes32` is a valid on-chain key; the zodiac-roles-sdk short-string encoding is an off-chain CRE-track
convention reconciled against this constant.

### The Roles seam + the scope (the actual guard)
The adapter's only authority is being `assignRoles`'d to `roleKey`. Every effect goes through
`Roles.execTransactionWithRole`, which validates against the owner-applied policy `CreditWarehouseDeployer._scope`
installs (all `scopeFunction(..., options = EXEC_NONE)` = Call-only). The four `ConditionFlat[]` trees (BFS order,
root at index 0 = `{parent:0, Calldata(5), Matches(5), ""}`):
- **A — `deposit(assets, receiver)`:** `[root, {Static,Pass} assets, {Static,EqualToAvatar} receiver]`.
- **B — `redeem(shares, receiver, owner)`:** `[root, {Static,Pass} shares, {Static,EqualToAvatar} receiver, {Static,EqualToAvatar} owner]`.
- **C — `approve(spender, amount)`:** `[root, {Static,EqualTo abi.encode(eePool)} spender, {Static,Pass} amount]`.
- **D — `transfer(to, amount)`:** `[root, {Static,EqualTo abi.encode(redemptionBox)} to, {Static,Pass} amount]`.

`EqualToAvatar` (op 15) children carry **empty** `compValue` (the modifier substitutes
`keccak256(abi.encode(avatar))` at scope-load, `PermissionLoader.sol:67-72`). `EqualTo` (op 16) carries the
32-byte `abi.encode(address)`. **APPROVE/REPAY amounts are `Pass` (scope-free)** — they vary per op; the CRE
sizes them, the policy pins only identities. **Tree D's `to` is `EqualTo(redemptionBox)`, never `Pass`** — a `Pass`
would let a compromised CRE `transfer` to any address (full drain). The adapter injecting `warehouseSafe`/`eePool` is
belt-and-suspenders **with** these pins, not a substitute for them (the qa scope-is-load-bearing tests —
`contracts/test/WarehouseAdminModule.t.sol` section (6), `test_Scope_PinsParams_*` — drive a **second** role
member (`MockMember`) through `Roles.execTransactionWithRole` directly with redirected params →
`ConditionViolation(ParameterNotAllowed)`).

### Compromised-CRE blast radius (the consolidated threat model)
A fully compromised CRE (or a stolen workflow identity) controls **amounts and timing only**. Every destination
is pinned by the scope: SUPPLY/REDEEM receiver/owner are `EqualToAvatar` (the Safe), APPROVE's spender is
`EqualTo(eePool)`, REPAY's `to` is `EqualTo(redemptionBox)` (the non-sweepable queue), and the Safe itself is never
a scoped target (no `enableModule` / owner-rotation escalation through the role). The worst cases are therefore
**griefing, not extraction**: refusing to fund redemptions (the senior exit stalls), shuffling float between the
Safe and the pool at bad times, or over-filling the queue (USDC parks in the non-sweepable sink, claimable only
at par by requesters). The residual sharp edge is **unbounded amounts** — a single REDEEM→REPAY can move the
entire float into the queue — which is exactly what the deferred item-10 drain-defense (row 364c:
`WithinAllowance` rate-limit and/or Delay Modifier) exists to bound.

## Wiring — cross-component (who points at whom)
- **Safe = the EE-share `receiver` for deposits.** The re-authored `ZipDepositModule` zap
  (`USDC → mint zipUSD → szipUSD`) and the senior SUPPLY path deposit `EulerEarn` shares with the **warehouse
  Safe as the `receiver`** (§4.5 :537-545); SUPPLY's `deposit(amount, safe)` pins `receiver == avatar`, so shares
  always land in the Safe, never in the adapter or Roles.
- **`redemptionBox == ZipRedemptionQueue` (item 9).** REPAY (`usdc.transfer(redemptionBox, amount)`) funds the senior
  exit queue. The flow is **REDEEM → REPAY**: REDEEM lands USDC in the Safe (`receiver == owner == avatar`), then
  REPAY distributes to the queue. The queue **never calls `EulerEarn` directly** — it settles against its own
  USDC balance (item 9 DISCHARGED this obligation: `grep eulerearn` on the queue matches only a doc comment).
- **The adapter op-set targets EE_POOL + USDC only.** `_scope` `scopeTarget`s exactly two addresses (`eePool`,
  `usdc`); the Safe itself is **never** `scopeTarget`'d, so a member relaying `Safe.enableModule(attacker)` /
  `addOwnerWithThreshold(...)` to `to == safe` reverts `TargetAddressNotAllowed` (escalation blocked). An
  un-scoped selector on a scoped target (e.g. `eePool.withdraw`) → `FunctionNotAllowed`.
- **Scope/role owner = the team multisig.** The Safe owner and the Roles owner are both `godOwner` (a GOD-EOA at
  launch, upgraded to a governance multisig at item-10 via the Safe's native `swapOwner` / `addOwnerWithThreshold`
  on both). The owner is the only address that can re-scope, re-assign, or act through the Safe directly
  (break-glass + policy admin). A role **member** cannot scope/assign (all `PermissionBuilder` mutators are
  `onlyOwner` — no member→owner escalation).
- **Forwarder identity.** The inherited `s_forwarderAddress` is the Chainlink `CRE_KEYSTONE_FORWARDER`; the
  warehouse adapter uses a **distinct workflowId** from the controller/registry/oracle receivers (CRE-04, §8.5).

## Item-10 deploy facts (the seal `CreditWarehouseDeployer` deliberately omits)
`CreditWarehouseDeployer.deploy(godOwner, eePool, usdc, forwarder, redemptionBox, saltNonce)` stands up the Safe (1),
Roles proxy (2), `enableModule` (3, asserts `isModuleEnabled`), the scope (4), the adapter (5), `assignRoles` (6),
and the owner handoff (7, asserts final owners == `godOwner` on both). It asserts every proxy init state
(`getOwners`/`getThreshold`; Roles `avatar`/`target`/`owner`) **before** scoping — never trusting a CREATE2 address
blindly (a front-run with different init params resolves to a different address; the assert fails closed). What it
**deliberately leaves to item-10 / §4.4 S11** (PROGRESS rows 363/364/333):
- **Identity seal (row 364):** `setExpectedWorkflowId(...)` → `transferOwnership(timelock)` with
  `getExpectedWorkflowId() != 0` asserted **before** the hand-off (§17 build-phase = transfer to the Timelock,
  NOT renounce). **Do NOT fund the warehouse before identity is set** — while `expectedWorkflowId == 0` the
  per-workflow gate is OFF and any Forwarder-relayed workflow could drive ops. Use a distinct Forwarder
  identity/workflowId.
- **`redemptionBox` wiring (row 364b):** point it at the item-9 `ZipRedemptionQueue`, which MUST be
  **immutable/non-sweepable** (the residual chokepoint a compromised CRE could REDEEM→REPAY into).
- **Drain-defense (row 364c, ELEVATED optional→recommended):** a Roles `WithinAllowance` rate-limit and/or a
  **Delay Modifier** (owner-cancellable cooldown) on the drain-capable REDEEM/REPAY ops.
- **APPROVE discipline (row 364d):** the CRE issues **exact-amount APPROVE per SUPPLY** (never a standing
  infinite); verify at item-10 whether the live EulerEarn is upgradeable / curator-controlled.
- **Non-commingling asserts (row 364f, §11):** assert `redemptionBox != juniorBaalSafe` **and** `safe !=
  juniorBaalSafe` at deploy.
- **EE supply-queue allocation (row 333):** both the no-borrow `usdcReservoir` and the 8-B5 **farm utility borrow
  vault** (`FarmUtilityMarketDeployer.deploy`'s vault) are capped as EE markets, but the **supply queue is set to
  `[usdcReservoir]` ONLY** (`DeployLocal._configureEulerEarn`) — so idle depositor USDC rests in `usdcReservoir`
  (the warehouse resting vault) and deposits never auto-route into the borrowable vault. The borrow vault holds
  ≈0 at rest and is JIT-funded from the reservoir via `EulerVenueAdapter.fundFarmUtility` (re-absorbed by
  `defundFarmUtility` — it stays reallocate-reachable as a capped market without being in the supply queue); the
  "combined" always-funded topology was rejected (CTR-07). This cap/queue config is an EulerEarn
  **curator/allocator** step, NOT a `WarehouseAdminModule` op — the adapter's op-set never configures the
  allocator. Keep the module's `borrowVault`/governor at the Timelock.
- **CRE §8 reconcile (row 370/CRE-04):** author the warehouse envelope (opType 1/2/3/4, payloads per §8.5) into
  the §8 producer spec; reconcile the on-chain `keccak256("ZIPCODE_WAREHOUSE_CRE")` with the off-chain sdk key.

## Gotchas
- **The adapter never configures the EulerEarn allocator.** Pointing the EE supply queue at the reservoir resting
  vault (row 333) is an item-10 **curator** step on EulerEarn at deploy, orthogonal to the warehouse's
  custody+gate job. The adapter's universe is exactly SUPPLY/APPROVE/REDEEM/REPAY.
- **The scope lives in audited Roles bytecode, not bespoke logic.** No external guard can contain an enabled
  module, so the policy MUST live inside the enabled contract — hence the audited Roles engine, not fresh
  bytecode guarding all senior backing. The adapter is a thin (~80-line) encoder; do not add per-op address
  checks beyond injecting the immutable identities.
- **Build-discovered on-chain corrections** (the deployed mastercopy `0x9646…D337` is NEWER than vendored
  `reference/zodiac-modifier-roles`): a **non-member** reverts `NotAuthorized` (the zodiac-core `moduleOnly` gate
  fires before the inner `NoMembership` — `assignRoles` also registers the member in `modules[]`), and a
  **non-owner** reverts the OZ-5 custom error `OwnableUnauthorizedAccount`, not an OZ-4 require-string. The build
  follows the live chain.
- **`bytes32(uint160(...))` does not compile** — the 1/1 pre-validated owner signature in `_execTransactionAsSelf`
  uses the `bytes32(uint256(uint160(address(this))))` hop (proven in `SummonSubstrate.s.sol:163`). The deployer is
  the transient owner of both Safe and Roles during wiring (the 1/1 `execTransaction` and the `onlyOwner`
  scope/assign calls require `msg.sender == owner`), then `swapOwner` + `transferOwnership` to `godOwner`.
- **EulerEarn is MOCKED in test** (solc 0.8.26 ≠ 0.8.24, the WOOF-04/05 precedent); the novel Roles/Safe/factory
  infra + USDC are fork-real on pinned Base. 23/23 fork, 424/424 full suite.
