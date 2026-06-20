# X-Ray — `WarehouseAdminModule.sol` (single-contract, test-connected)

> WarehouseAdminModule | 107 nSLOC | 95ed3dd (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED)*

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
| `setRoles(roles_)` | `onlyOwner` (Timelock) | re-point the Roles modifier; non-zero; re-pointable (§17) |
| `setRoleKey(roleKey_)` | `onlyOwner` | re-set the assigned key; must stay non-zero (zero = `NoMembership`) |
| `setWarehouseSafe(safe_)` | `onlyOwner` | re-point avatar/custodian; **must be paired with `Roles.setAvatar`** (X-2) |
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
| X-2 | `warehouseSafe` (injected owner) MUST equal the modifier's `avatar`; independent slots, never asserted on-chain | **No** | **`test_Parity_OneSidedRepoint_SupplyFailsClosed`**, **`test_Parity_OneSidedRepoint_RedeemFailsClosed`** — a one-sided re-point fails closed (scope rejects mismatched receiver; **no shares/USDC leak to either safe**) |
| X-3 | all six wiring slots are Timelock-re-pointable (build phase; immutable re-freeze deferred) | **No** | `test_Setters_OwnerUpdates_AndRejectsZero` (each setter takes effect + zero/zero-key guards), `test_Setters_RejectNonOwner` (all six revert `OwnableUnauthorizedAccount` for a non-owner) |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| G-1 ctor wiring ≠ 0 (×5) | `test_Ctor_RevertsOnZeroAddress` (forwarder + each of roles/safe/eePool/usdc/box) |
| G-2 ctor `roleKey` ≠ 0 | `test_Ctor_RevertsOnZeroRoleKey` |
| G-3…G-8 setter zero-address / zero-key | `test_Setters_OwnerUpdates_AndRejectsZero` (each setter `ZeroAddress`; `setRoleKey(0)`→`ZeroRoleKey`) |
| G-9 REPAY self-enforced sink | `test_Repay_RevertsOnWrongSink` |
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
- **`warehouseSafe ↔ roles.avatar()` parity (X-2)** — the contract's own #1 documented hazard (`:43-48`):
  `setWarehouseSafe` writes the slot but never reads/asserts `roles.avatar()`. **Now tested fail-closed** — a
  one-sided re-point makes SUPPLY/REDEEM revert at the scope check with nothing leaked. The *paired* re-point that
  restores liveness (adapter `setWarehouseSafe` + `Roles.setAvatar` together) is a deploy/runbook concern. Worth
  adding an on-chain post-condition parity check as defense-in-depth.
- **Build-phase mutable wiring (X-3)** — six `onlyOwner` setters re-point roles/roleKey/safe/pool/usdc/box; tested
  for access + effect + zero-guards. The value-routing absolutes (notably the REPAY sink) hold only after the
  deferred pre-prod immutable re-freeze (a process step, not on-chain).
- **REPAY is the one payload-carried address, double-defended (I-3)** — `test_Repay_RevertsOnWrongSink` proves the
  adapter self-rejects a wrong `dest`, and `test_Scope_PinsParams_TransferTo` proves the scope independently pins
  `to == redemptionBox`; even a scope gap can't redirect REPAY because the calldata injects the immutable.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit (fork integration) | 28 | deploy/wire, ctor guards, all four happy ops, the full **scope-rejection matrix** vs the real modifier (param pins, value+delegatecall, target/selector escalation, non-member, non-owner), self-enforced REPAY sink, inner-exec-fail → `ModuleTransactionFailed`, malformed payload, atomicity, senior NAV mark, **avatar-parity fail-closed**, all six setters |
| Stateless fuzz | 0 | low value — a deterministic encoder, no arithmetic |
| Stateful invariant | 0 | no accumulated state to assert |

All **28 pass** (`forge test --match-path test/WarehouseAdminModule.t.sol` → 28 passed, 0 failed). Coverage %
uninstrumentable (project-wide stack-too-deep, even under `--ir-minimum`); existence + green run confirmed by scan.
The suite is the high-water mark for *the right kind* of test here: it proves the **off-chain scope** rejects
redirected receivers, wrong REPAY dests, value, delegatecall, and target/selector escalation — against the live
deployed modifier, not a mock.

> **What changed since the bundled `x-ray.md`'s first draft:** that draft (24 tests) listed two open gaps — the
> avatar-parity fail-closed and the six `onlyOwner` setters were *untested*. **Both are now closed**
> (`test_Parity_OneSidedRepoint_Supply/RedeemFailsClosed`, `test_Setters_RejectNonOwner`,
> `test_Setters_OwnerUpdates_AndRejectsZero`), bringing the suite to 28. No real on-chain test gap remains.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — a clean, well-documented, defensively hardcoded encoder with roles +
Timelock and zero permissionless surface, whose decisive control (the Zodiac Roles scope) is **proven by a fork
integration suite** that exercises the full scope-rejection matrix against the real deployed modifier. The two gaps
the earlier draft flagged (avatar-parity, the six setters) are now both covered. Capped at ADEQUATE (not HARDENED)
only by: no in-scope spec/README, no on-chain avatar-parity assertion (mandated by runbook instead), and the
deferred pre-prod immutable re-freeze; no fuzz/invariant (correctly judged low-value for a deterministic router).

**Structural facts:**
1. 107 nSLOC; non-upgradeable `ReceiverTemplate`; 0 permissionless entry points (1 Forwarder/CRE handler + 6 Timelock setters).
2. Holds no custody; `value`/`operation`/`shouldRevert` are literals (0 / Call / true) at the single call site — never payload-decoded.
3. Four-op allow-list; receiver/spender/redeem-owner injected from immutables; only REPAY `dest` is payload-carried, and it is self-checked **and** re-injected from the immutable.
4. Tests: **28 fork-integration units** vs the real Roles modifier (full scope-rejection matrix); 0 fuzz, 0 invariant. Avatar-parity fail-closed and all six setters are now covered.
5. The security genuinely lives outside this file (the off-chain Roles scope tree, X-1) and in two off-chain process steps (avatar parity X-2, pre-prod immutable re-freeze X-3).
