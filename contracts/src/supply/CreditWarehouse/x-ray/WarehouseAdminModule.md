# X-Ray — `WarehouseAdminModule.sol` (single-contract, test-connected)

> WarehouseAdminModule | 110 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo the pre-prod immutable re-freeze + no external audit)*

> **Update:** the X-2 residual (parity unverified on-chain) is closed as a **maintained invariant** — checked at
> ALL FOUR sites (the constructor, `setRoles`, `setWarehouseSafe`, and at USE time in `_processReport`), each
> asserting BOTH `roles.avatar() == warehouseSafe` (`AvatarMismatch`) and `roles.target() == warehouseSafe`
> (`TargetMismatch`). The guards matter because SUPPLY/REDEEM fail closed under an avatar mismatch at the scope's
> live `EqualToAvatar` receiver pin, but **REPAY has no "from" parameter to scope** — a Roles instance attached to
> a different Safe would have kept REPAY live against THAT Safe, draining it into the redemption queue (no sweep;
> `settleEpoch` consumes any free balance). Any desync is now a liveness jam until re-paired, never an execution.
>
> **Both slots, not just `avatar` (added 2026-08-04).** The original guard read only `avatar()`, which is the
> *wrong* slot for custody: Zodiac's `Module.exec` is `IAvatar(target).execTransactionFromModule(...)`
> (`Module.sol:50`), while `avatar` is only the scope-comparison operand for `Operator.EqualToAvatar`. A
> `Roles.setTarget(otherSafe)` therefore left every avatar check passing while REPAY/SUPPLY/APPROVE executed
> against a different Safe — proven on a Base fork against the real deployed Roles mastercopy: 500,000e6 USDC
> drained from a second Safe by one honest REPAY report, with no `AvatarMismatch` and no scope rejection.
> `Roles.setTarget` is gated by the Roles owner (`godOwner`), a DIFFERENT key from the Timelock that owns this
> adapter's setters, so checking both slots turns a one-key redirect into a two-key one. Reachability was always
> narrow — the destination Safe must have this Roles instance enabled as a module, and per-silo deploys give each
> silo its own — but the remediation claimed a maintained invariant it did not establish.
>
> Re-points are order-dependent — pair BOTH modifier slots to the Safe first; documented in `docs/roles.md`.
> `IRoles` gained `avatar()`/`setAvatar()`/`target()`/`setTarget()`. 34/34 fork tests green (incl.
> `test_Ctor_RevertsOnAvatarMismatch`, `test_Parity_SetRoles_WrongAvatar_Reverts`,
> `test_Parity_SetRoles_WrongTarget_Reverts`, `test_Parity_SetRoles_MatchingAvatar_Succeeds`,
> `test_Parity_UseTime_ExternalSetAvatar_BlocksAllOps`, `test_Parity_UseTime_ExternalSetTarget_BlocksAllOps`).
> Verdict: HARDENED.

Dedicated single-contract X-Ray for `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`, the sole
contract in the senior-side warehouse-admin scope (the `bridge/x-ray/x-ray.md`-style bundled `x-ray.md` is the scope
overview; this is the per-contract, test-connected file). Connected to `test/WarehouseAdminModule.t.sol` — **28
fork-integration unit tests against the real deployed Zodiac Roles modifier** (0 fuzz, 0 invariant; a deterministic
encoder with no arithmetic).

> ⚠️ **The security boundary is NOT this bytecode.** This contract self-describes as a *pure encoder* that holds no
> custody and enforces no scope. The decisive control is the **Zodiac Roles-modifier-v2 scope config** (params
> pinned, Call-only) attached to the warehouse Safe. The strength of this suite is precisely that it is a **fork
> integration** test exercising that real scope — not a mock of it.

## 1. What it is

The thin CRE adapter for the senior `CreditWarehouse` (§4.5/§8.5). It is the **sole role member** of a Zodiac
Roles-modifier-v2 instance `enableModule`'d on the warehouse Safe (which custodies the `EulerEarn` shares backing
all outstanding zipUSD float). It holds **no custody** and enforces **no scope** — `_processReport` decodes the CRE
envelope `(uint8 opType, bytes payload)` into exactly one of four ops (SUPPLY/APPROVE/REDEEM/REPAY) and forwards it
through `roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`. Ownership is the Timelock (six build-phase
wiring setters; **no custody, no pause, no value path this contract controls**).

**The load-bearing design trick:** *hardcode everything dangerous, inject everything addressable.* `value` is always
`0`, `operation` always `Call` (literal `0`), `shouldRevert` always `true` — none is ever payload-decoded, so no
caller can request a delegatecall or a value transfer. Receiver/spender/redeem-owner are injected from immutables;
only the REPAY `to` comes from the payload, and it is **both** self-checked (`dest != redemptionBox` reverts) **and**
scope-pinned `EqualTo(redemptionBox)`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `_processReport` (via `onReport`) | Forwarder-gated (CRE) | decodes `(opType, payload)` → SUPPLY/APPROVE/REDEEM/REPAY → `execTransactionWithRole`; `else revert UnsupportedOpType` |
| `setRoles(roles_)` | `onlyOwner` (Timelock) | re-point the Roles modifier; non-zero; **parity-guarded on BOTH slots** (`AvatarMismatch` unless `roles_.avatar() == warehouseSafe`, `TargetMismatch` unless `roles_.target() == warehouseSafe`); re-pointable (§17) |
| `setRoleKey(roleKey_)` | `onlyOwner` | re-set the assigned key; must stay non-zero (zero = `NoMembership`) |
| `setWarehouseSafe(safe_)` | `onlyOwner` | re-point custodian; **reverts `AvatarMismatch`/`TargetMismatch` unless BOTH `roles.avatar()` and `roles.target()` equal `safe_`** — pair `Roles.setAvatar` AND `Roles.setTarget` FIRST (X-2); the use-time re-check in `_processReport` covers any later external desync |
| `setEePool(eePool_)` | `onlyOwner` | re-point the EulerEarn pool |
| `setUsdc(usdc_)` | `onlyOwner` | re-point the asset/approve/repay token |
| `setRedemptionBox(box_)` | `onlyOwner` | re-point the REPAY sink |

No permissionless entry points. The four ops are reachable only via the Forwarder-gated dispatch.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | every forward is `value==0`, `operation==Call(0)`, `shouldRevert==true` — never payload-decoded | Yes | `test_CallOnly_RejectsValueAndDelegatecall` (member sending value→`SendNotAllowed`, delegatecall→`DelegateCallNotAllowed`); the adapter only ever emits Call/0 (asserted via every happy-path `WarehouseOp` emit) |
| I-2 | `opType ∈ {1,2,3,4}`; any other byte reverts; each op = one (target, selector) | Yes | `test_Adapter_UnsupportedOpType_Reverts` (0/5/255→`UnsupportedOpType`), `test_Supply_Happy`/`test_Redeem_Happy`/`test_Repay_Happy` (selector+target pinned per op), `test_Escalation_Blocked` (un-scoped selector on a scoped target → `FunctionNotAllowed`) |
| I-3 | REPAY transfers to `redemptionBox` (immutable), never the payload `dest` — validated AND injected | Yes | `test_Repay_Happy` (injects `redemptionBox`), `test_Repay_RevertsOnWrongSink` (`dest=attacker`→`WrongRedemptionBox`), `test_Scope_PinsParams_TransferTo` (member transfer to any non-box → `ParameterNotAllowed`; to box → succeeds) |
| X-1 | the real param-pinning (receiver==avatar / spender==eePool / to==redemptionBox / Call-only) lives in the **Roles scope**, not here | **No** | **fork integration** vs the live modifier: `test_Scope_PinsParams_DepositReceiver` (redirected receiver→`ParameterNotAllowed`), `test_Scope_PinsParams_TransferTo`, `test_CallOnly_RejectsValueAndDelegatecall`, `test_Escalation_Blocked` (enableModule/addOwner/wrong-target/wrong-selector all rejected), `test_NonMember_Reverts` (`NotAuthorized`), `test_NonOwner_CannotScopeOrAssign` |
| I-4 | `warehouseSafe` (injected owner) MUST equal BOTH the modifier's `avatar` (the scope's `EqualToAvatar` operand) and its `target` (the Safe `Module.exec` actually calls) — **checked on-chain at all four sites**, so neither a one-sided re-point nor an external `setAvatar`/`setTarget` can survive. A standing invariant, re-asserted per report | **Yes** (maintained) | **`test_Parity_OneSidedRepoint_RevertsAtSetter`**, **`test_Parity_PairedRepoint_SetAvatarFirst_Succeeds`** (both slots paired → accepted), **`test_Parity_SetRoles_WrongTarget_Reverts`** (avatar matches, target foreign → `TargetMismatch`), **`test_Parity_UseTime_ExternalSetTarget_BlocksAllOps`** (external target-only desync blocks REPAY); the scope-level fail-closed backstop stays proven by `test_Scope_PinsParams_DepositReceiver` |
| X-3 | all six wiring slots are Timelock-re-pointable (build phase; immutable re-freeze deferred) | **No** | `test_Setters_OwnerUpdates_AndRejectsZero` (each setter takes effect + zero/zero-key guards), `test_Setters_RejectNonOwner` (all six revert `OwnableUnauthorizedAccount` for a non-owner) |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| G-1 ctor wiring ≠ 0 (×5) | `test_Ctor_RevertsOnZeroAddress` (forwarder + each of roles/safe/eePool/usdc/box) |
| G-2 ctor `roleKey` ≠ 0 | `test_Ctor_RevertsOnZeroRoleKey` |
| G-3…G-8 setter zero-address / zero-key | `test_Setters_OwnerUpdates_AndRejectsZero` (each setter `ZeroAddress`; `setRoleKey(0)`→`ZeroRoleKey`) |
| G-9 REPAY self-enforced sink | `test_Repay_RevertsOnWrongSink` |
| G-10 `setWarehouseSafe` parity, both slots (`AvatarMismatch` / `TargetMismatch`) | `test_Parity_OneSidedRepoint_RevertsAtSetter` (revert), `test_Parity_PairedRepoint_SetAvatarFirst_Succeeds` (paired ok) |
| G-11 `setRoles` / use-time `target` parity (`TargetMismatch`) | `test_Parity_SetRoles_WrongTarget_Reverts`, `test_Parity_UseTime_ExternalSetTarget_BlocksAllOps` |
| `UnsupportedOpType` allow-list | `test_Adapter_UnsupportedOpType_Reverts` |
| `onlyOwner` on all six setters | `test_Setters_RejectNonOwner` |
| Forwarder gate (incl. reentrancy) | `test_Adapter_NonForwarder_Reverts`, `test_Adapter_Reentrancy_RejectedByForwarderGate` |
| Inner-exec failure → `ModuleTransactionFailed` | `test_InnerExecFail_ZeroSupply`/`_SupplyWithoutApprove`/`_RedeemMoreThanHeld`/`_RepayMoreThanHeld` |
| Malformed payload | `test_MalformedPayload_RevertsCleanly` (garbage report + short inner payload) |
| Atomicity (no partial state on revert) | `test_Atomicity_BalancesUnchangedAfterRevert` |
| Deploy/wire state | `test_DeployWire_State` (owner/threshold, module enabled, all immutables, dormant workflow gate) |
| Senior NAV mark / redeem(0) no-op | `test_SeniorNavMark`, `test_Redeem_ZeroIsNoOpSuccess` |

## 5. Attack surfaces

- **The Roles scope is the real control, and it is out of this file (X-1)** — `_processReport:189` trusts the
  modifier's scope for param-pinning; this contract's injections are explicitly belt-and-suspenders. Uniquely for
  this scope, the suite is a **fork integration** test that drives the *real deployed* modifier (a second
  `MockMember` role member raw-calls `execTransactionWithRole` with redirected params and is rejected) — so the
  decisive control IS demonstrably exercised, not assumed. Remains On-chain=No by design; the deployed scope tree
  (receiver/spender/`EqualTo` pins, Call-only, no delegatecall) is still the primary off-chain audit artifact.
- **`warehouseSafe ↔ roles.avatar()` AND `roles.target()` parity (I-4) — a maintained invariant, checked at all
  four sites.** The contract's own #1 documented hazard. All four sites (ctor, `setRoles`, `setWarehouseSafe`,
  `_processReport`) now assert both slots, so neither a one-sided re-point, a `setRoles` to a mis-paired instance,
  nor an external `Roles.setAvatar`/`setTarget` can survive — each reverts `AvatarMismatch` or `TargetMismatch`.
  Paired re-point order: `Roles.setAvatar` AND `Roles.setTarget` first, then `setWarehouseSafe` (`docs/roles.md`).
- **Why `target` and not just `avatar` — the fix's own correction.** The first version of this guard checked only
  `avatar()`, which is the wrong slot for custody. Zodiac's `Module.exec` is
  `IAvatar(target).execTransactionFromModule(...)` (`Module.sol:50`); `avatar` is only the operand
  `PermissionLoader` patches into `Operator.EqualToAvatar`. So the avatar-only guard pinned the slot that was
  ALREADY fail-closed — SUPPLY/REDEEM are rejected by the scope's live `OP_EQUAL_TO_AVATAR` receiver pin
  (`CreditWarehouseDeployer.sol:185,193,194`) — and left unchecked the slot that decides whose USDC moves. REPAY
  has no "from" to scope, so a `Roles.setTarget(otherSafe)` kept it live against that Safe. Proven on a Base fork
  against the real deployed Roles mastercopy: 500,000e6 USDC drained from a second Safe by one honest REPAY report,
  with every avatar check passing and no `ConditionViolation`. `Roles.setTarget` is Roles-owner-gated (`godOwner`),
  a different key from the Timelock that owns these setters, so checking both slots makes the redirect a two-key
  action. Reachability was narrow throughout — the destination Safe must have this Roles instance enabled, and
  per-silo deploys give each silo its own — and `CreditWarehouseDeployer.sol:130` already asserted
  `target() == safe` at deploy, so the launch state was never wrong. The defect was that the remediation asserted a
  maintained invariant it did not establish.
- **Build-phase mutable wiring (X-3)** — six `onlyOwner` setters re-point roles/roleKey/safe/pool/usdc/box; tested
  for access + effect + zero-guards. The value-routing absolutes (notably the REPAY sink) hold only after the
  deferred pre-prod immutable re-freeze (a process step, not on-chain).
- **REPAY is the one payload-carried address, double-defended (I-3)** — `test_Repay_RevertsOnWrongSink` proves the
  adapter self-rejects a wrong `dest`, and `test_Scope_PinsParams_TransferTo` proves the scope independently pins
  `to == redemptionBox`; even a scope gap can't redirect REPAY because the calldata injects the immutable.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit (fork integration) | 34 | deploy/wire, ctor guards, all four happy ops, the full **scope-rejection matrix** vs the real modifier (param pins, value+delegatecall, target/selector escalation, non-member, non-owner), self-enforced REPAY sink, inner-exec-fail → `ModuleTransactionFailed`, malformed payload, atomicity, senior NAV mark, **avatar AND target parity at all four sites** (one-sided revert, paired-ok, `setRoles` wrong-target, use-time external `setAvatar`/`setTarget`), all six setters |
| Stateless fuzz | 0 | low value — a deterministic encoder, no arithmetic |
| Stateful invariant | 0 | no accumulated state to assert |

All **28 pass** (`forge test --match-path test/WarehouseAdminModule.t.sol` → 28 passed, 0 failed). Coverage %
uninstrumentable (project-wide stack-too-deep, even under `--ir-minimum`); re-verified green at `8b7c67c`. The suite
is the high-water mark for *the right kind* of test here: it proves the **off-chain scope** rejects redirected
receivers, wrong REPAY dests, value, delegatecall, and target/selector escalation — against the live deployed
modifier, not a mock.

> **What changed:** the X-2 avatar-parity residual is **checked in code
> at the `setWarehouseSafe` entry point** — it reverts `AvatarMismatch` unless `roles.avatar() == warehouseSafe_`, so
> a one-sided re-point *through that setter* can't be saved. This is **entry-point-local, not a maintained
> invariant**: `setRoles` and an external `Roles.setAvatar` can re-desync the pair, both fail-closed at the live
> `EqualToAvatar` scope pin (no leak). The two earlier `_FailsClosed` parity tests were rewritten to the new setter
> behavior (`test_Parity_OneSidedRepoint_RevertsAtSetter`, `test_Parity_PairedRepoint_SetAvatarFirst_Succeeds`); the
> setter test was reordered (avatar-paired before re-pointing `roles` away). The Zodiac setup + the invariant + the
> order-dependent re-point runbook are documented in `docs/roles.md`. `IRoles` gained `avatar()`/`setAvatar()`.

## X-Ray Verdict

**HARDENED** *(modulo the pre-prod immutable re-freeze + no external audit)* — a clean, defensively hardcoded encoder
with roles + Timelock and zero permissionless surface, whose decisive control (the Zodiac Roles scope) is **proven by
a fork integration suite** exercising the full scope-rejection matrix against the real deployed modifier. The X-2
avatar-parity residual the earlier draft flagged is **checked on-chain at the `setWarehouseSafe` entry point**
(`AvatarMismatch`) and documented (`docs/roles.md`) — entry-point-local, with the `setRoles`/external-`setAvatar`
re-desync paths fail-closed at the scope's live `EqualToAvatar` pin, so HARDENED rests on the scope's
dynamic pin, not the setter guard. The only residuals are
process — the deferred pre-prod immutable re-freeze of the build-phase wiring — and the absence of an external audit;
no code or coverage gap remains. No fuzz/invariant (correctly judged low-value for a deterministic router).

**Structural facts:**
1. 110 nSLOC; non-upgradeable `ReceiverTemplate`; 0 permissionless entry points (1 Forwarder/CRE handler + 6 Timelock setters).
2. Holds no custody; `value`/`operation`/`shouldRevert` are literals (0 / Call / true) at the single call site — never payload-decoded.
3. Four-op allow-list; receiver/spender/redeem-owner injected from immutables; only REPAY `dest` is payload-carried, and it is self-checked **and** re-injected from the immutable.
4. `setWarehouseSafe` checks avatar parity on-chain (`AvatarMismatch`; order-dependent re-point, `Roles.setAvatar` first) — entry-point-local, NOT a maintained invariant: `setRoles`/external `Roles.setAvatar` re-desync fail-closed at the live `EqualToAvatar` scope pin, so the silent-brick hazard is bounded by the scope, not eliminated at the setter.
5. Tests: **28 fork-integration units** vs the real Roles modifier (full scope-rejection matrix + avatar-parity enforcement + all six setters); 0 fuzz, 0 invariant. The security genuinely lives outside this file (the off-chain Roles scope tree, X-1) and in one remaining off-chain process step (pre-prod immutable re-freeze, X-3).
