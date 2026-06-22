# X-Ray — `ZipcodeDeployAsserts.sol` (library, test-connected)

> ZipcodeDeployAsserts | 26 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo no external audit)*

Per-contract X-Ray for `contracts/src/ZipcodeDeployAsserts.sol` (§9 / audit S11), the **one load-bearing
deploy-time assertion** the item-10 deploy script runs IMMEDIATELY before the irreversible ownership hand-off /
renounce. A `library` of `internal view` checks (no deployed bytecode of its own — it compiles INTO the deploy
script). Exercised by `ZipcodeDeployIdentityGate.t.sol` — **12 tests** across two contracts (the gate + the CTR-16
per-receiver behavioral suite).

> ## Why "asserts"?
> It is a small library of **deploy-time assertions** — functions that *verify a precondition holds and revert
> (fail-closed) if it doesn't*, the general programming sense of "assert," not Solidity's `assert()` opcode (these use
> custom-error `revert`s — `ReceiverIdentityNotWired` / `RegistryControllerUnset` — which carry data and refund gas,
> unlike `assert()` which consumes all gas and signals a bug). Plural because it bundles two checks: every sealed CRE
> receiver's identity is fully wired, and the registry's set-once controller is seeded. The deploy script *asserts*
> these invariants right before it renounces, so a misconfigured fleet can never be frozen live.

## 1. What it is

A 26-nSLOC `library` defending the **dormant-identity vuln** (audit F1/M4). The problem: `ReceiverTemplate.onReport`'s
identity check is CONDITIONAL — each expected slot (author / workflowName) is enforced *only when set* — and
`onReport`/`setForwarderAddress` are non-virtual. So a deploy that seals (renounces) BEFORE wiring identity freezes
the receiver in a **Forwarder-sender-only** state any co-tenant workflow on the same Forwarder can drive.
Symmetrically, sealing before `registry.setController` leaves `controller == address(0)` so the registry is
unseedable forever (F7 brick). Two `internal view` functions:

- **`requireReceiverIdentityWired(receiver)`** — reverts `ReceiverIdentityNotWired` unless BOTH `getExpectedAuthor() != 0` AND `getExpectedWorkflowName() != 0` (the CTR-16 author+name posture; `onReport` enforces the name only when the author is also set, so both are load-bearing).
- **`requireIdentityWired(receivers[], registry)`** — asserts EACH receiver individually (CTR-16 dropped the old "same `workflowId` on every subclass ⇒ one representative check" inference — under the separate-daemon model each receiver carries its OWN name), then asserts `registry.controller() != 0`. Reverts on the first failure.

No state, no admin, no deployed bytecode, no runtime surface — purely a deploy-time concern.

## 2. Surface

| Function | Kind | Notes |
|---|---|---|
| `requireReceiverIdentityWired(address)` | `internal view` | per-receiver author+name gate; `ReceiverIdentityNotWired` |
| `requireIdentityWired(address[], address)` | `internal view` | fleet loop + registry-controller check; `ReceiverIdentityNotWired` / `RegistryControllerUnset` |

Both are `internal`, so they have no external ABI — they inline into the caller (`DeployZipcode.s.sol`).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **per-receiver gate** — author-unset OR name-unset → `ReceiverIdentityNotWired`; both set → passes | Yes (deploy-time) | **`test_PreGate_RevertsWhenAuthorUnset`**, **`_RevertsWhenNameUnset`**, **`_PassesWhenSealed`** |
| I-2 | **fleet gate** — an unsealed receiver in the array reverts (pointing at it); a name-unset receiver reverts | Yes | **`test_Negative_ReceiverUnsealed_GateReverts`**, **`_NameUnset_GateReverts`** |
| I-3 | **registry-controller gate** — `controller() == 0` → `RegistryControllerUnset` | Yes | **`test_Negative_RegistryControllerUnset_GateReverts`** |
| I-4 | **happy path then freeze** — gate passes when every receiver is sealed + registry seeded, then renounce leaves the fleet correctly frozen | Yes | **`test_Positive_GatePasses_ThenRenounce_ThenFrozen`** |
| I-5 | **the vuln it defends is real (behavioral)** — a DORMANT (unsealed) receiver accepts a wrong identity; a SEALED one rejects a wrong name and accepts the correct one | Yes | **`test_Behavioral_DormantAcceptsWrongIdentity`**, **`_SealedRejectsWrongName`**, **`_SealedAcceptsCorrectIdentity`**, **`_IdentitySealed_AfterSeal`** |
| I-6 | **K5 privilege separation** — `workflowName` separates two same-author daemons (so author alone is insufficient — the CTR-16 reason both are required) | Yes | **`test_K5_PrivilegeSeparation_NameSeparatesSameAuthorDaemons`** |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `ReceiverIdentityNotWired` (author OR name unset) | `:50-53` | `test_PreGate_RevertsWhen{Author,Name}Unset`, `test_Negative_{ReceiverUnsealed,NameUnset}_GateReverts` |
| `RegistryControllerUnset` (`controller()==0`) | `:67-69` | `test_Negative_RegistryControllerUnset_GateReverts` |

Both revert paths and both happy paths (per-receiver + combined) are exercised, plus the behavioral proof that the
gate defends a real dormancy vuln.

## 5. Attack surfaces

- **The gate IS a defense, not a surface.** This library exists to *prevent* a deploy-time misconfiguration (sealing
  a CRE receiver before its identity is wired). It has no state, no admin, no value path, and no deployed bytecode —
  there is nothing to attack at runtime. The risk it addresses is entirely off-chain/deploy-time: a fleet sealed in a
  dormant state.
- **The dormancy vuln is concretely demonstrated (I-5).** `test_Behavioral_DormantAcceptsWrongIdentity` shows an
  unsealed receiver accepting a report from the wrong identity (the exact F1 failure), and the sealed-receiver tests
  show the gate's premise holds — so the assertion is guarding a proven hazard, not a hypothetical.
- **CTR-16 per-receiver checking is the right granularity (I-6).** The earlier design inferred "all wired" from one
  representative `workflowId`; CTR-16 drops that because each receiver now carries its own `workflowName` under the
  separate-daemon model. `requireIdentityWired` loops every receiver, and the K5 test proves `workflowName` actually
  separates two same-author daemons — so a representative-only check would miss an unset name on one receiver. The
  contract's NatSpec is explicit that the registry is itself a receiver and should appear in the array too.
- **The one residual is a process invariant, not a code gap:** the deploy script MUST actually call
  `requireIdentityWired` before the hand-off. That call is present in `DeployZipcode.s.sol` and covered by
  `DeployZipcode.t.sol`; the library can only assert when invoked. No mutable wiring, no admin — none of the
  build-phase residual the stateful contracts carry.
- **Inherent trust:** the `IReceiverIdentity` getters (`getExpectedAuthor`/`getExpectedWorkflowName`) are
  `ReceiverTemplate`'s, and `controller()` is the registry's — both separately X-rayed; the library only reads them.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Per-receiver gate (author / name / sealed) | 3 | `test_PreGate_*` |
| Combined gate (unsealed / name-unset / registry-unset / happy+freeze) | 4 | `test_Negative_*` (3) + `_Positive_GatePasses_ThenRenounce_ThenFrozen` |
| Behavioral (dormancy vuln + sealed accept/reject) | 4 | `test_Behavioral_*` (3) + `_IdentitySealed_AfterSeal` |
| K5 privilege separation | 1 | `test_K5_PrivilegeSeparation_NameSeparatesSameAuthorDaemons` |

Coverage % uninstrumentable (project-wide `Stack too deep`); 12 tests green. Both library functions, both revert
paths, both happy paths, and the behavioral proof of the defended vuln are all exercised — no coverage gap for a
deploy-time assertion library.

## X-Ray Verdict

**HARDENED** *(modulo no external audit)* — a 26-nSLOC deploy-time assertion library defending the dormant-identity
vuln (audit F1/S11): the single check the item-10 script runs immediately before the irreversible renounce, proving
every sealed CRE receiver's identity (author + workflowName, CTR-16) is wired and the registry's set-once controller
is seeded. Both functions, both revert paths, the happy-then-freeze path, the K5 privilege separation, and a
behavioral demonstration of the actual dormancy vuln are all tested (12 green). As an `internal` library it has no
state, no admin, no deployed bytecode, and no runtime surface — none of the build-phase residual; the only thing
below a clean bill is the project-wide absence of an external audit. (The "must be invoked by the deploy script"
process invariant is itself covered by `DeployZipcode.t.sol`.)

**Structural facts:**
1. 26 nSLOC; `library` with two `internal view` functions; no state, no admin, no deployed bytecode (inlines into the deploy script).
2. Defends the dormant-identity vuln: `ReceiverTemplate.onReport`'s identity check is conditional + non-virtual, so a seal-before-wiring leaves a Forwarder-sender-only receiver any co-tenant can drive.
3. CTR-16 posture: asserts EACH receiver's author + workflowName individually (dropped the representative-`workflowId` inference) + the registry's `controller() != 0`; fail-closed on the first miss.
4. "Asserts" = deploy-time precondition checks that `revert` (custom errors, not the `assert()` opcode) right before the irreversible ownership hand-off.
5. Tests: 12 (per-receiver + combined gate, both reverts, happy+freeze, behavioral dormancy proof, K5 separation). No gap; capped only by no external audit.
