# X-Ray Report

> CreditWarehouse Admin | 107 nSLOC | 1549279 (`main`) | Foundry | 20/06/26

Analyzed branch: `main` at `1549279`. Scope: `contracts/src/supply/CreditWarehouse` (1 contract).

> ⚠️ **The security boundary is NOT this bytecode.** `WarehouseAdminModule` self-describes as a *pure encoder* that holds no custody and enforces no scope. The real enforcement is the **Zodiac Roles-modifier-v2 scope config** (params pinned, Call-only) attached to the warehouse Safe — which lives in deploy/config, *outside this file*. Auditing this contract without auditing the Roles scope policy proves almost nothing.

---

## 1. Protocol Overview

**What it does:** A thin CRE adapter for the senior-side `CreditWarehouse` — it decodes a CRE report into exactly one of four warehouse operations and forwards it through a Zodiac Roles modifier that executes it as the warehouse Safe.

- **Users**: No public users. A CRE workflow (behind the Forwarder) issues warehouse ops; the Timelock owns wiring.
- **Core flow**: `_processReport` decodes `(opType, payload)` → builds calldata for SUPPLY / APPROVE / REDEEM / REPAY → `roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`.
- **Key mechanism**: this contract is `assignRoles`'d as the **sole role member** of a Roles modifier that is `enableModule`'d on the warehouse Safe; every effect routes through that modifier, whose *scope* (param-pinning) is the actual security control.
- **Token model**: moves USDC into/out of an `EulerEarn` 4626 pool whose shares back outstanding zipUSD float; never custodies anything itself.
- **Admin model**: `owner()` is the Timelock — six build-phase wiring setters. No custody, no pause, no value path that this contract controls directly.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Warehouse admin | WarehouseAdminModule | 107 | CRE→Roles encoder for SUPPLY/APPROVE/REDEEM/REPAY; holds no custody, enforces no scope |

*Protocol-authored. Inherited `ReceiverTemplate` and the external Roles modifier / EulerEarn / Safe are out of scope (but the Roles scope is the real control — see banner).*

### How It Fits Together

The core trick: **hardcode everything dangerous, inject everything addressable.** `value` is always 0, `operation` is always `Call` (literal 0), `shouldRevert` is always true — none is ever decoded from a payload, so no caller can request a delegatecall or a value transfer. Receiver/spender/redeem-owner are injected from immutables; only the REPAY `to` comes from the payload, and it is both self-checked (`dest != redemptionBox` reverts) *and* scope-pinned `EqualTo(redemptionBox)`.

### Warehouse op flow (CRE → encoder → modifier → Safe)

```
Forwarder → ReceiverTemplate.onReport → WarehouseAdminModule._processReport(opType, payload)
  ├─ SUPPLY  → to=eePool ; eePool.deposit(amount, warehouseSafe)       receiver injected (scope: receiver==avatar)
  ├─ APPROVE → to=usdc   ; usdc.approve(eePool, amount)                spender injected (scope: spender==eePool)
  ├─ REDEEM  → to=eePool ; eePool.redeem(shares, warehouseSafe, warehouseSafe)  owner/receiver injected (==avatar)
  └─ REPAY   → to=usdc   ; usdc.transfer(redemptionBox, amount)        dest self-checked + scope EqualTo(redemptionBox)
       └─ roles.execTransactionWithRole(to, 0, data, Call, roleKey, shouldRevert=true)
            └─ Roles modifier validates scope, then exec's AS the warehouse Safe (avatar)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield-Vault adapter (EulerEarn 4626)** with **Access-Control-shim** and **Oracle-transport** characteristics

Signals: routes USDC supply/redeem against an EulerEarn 4626 pool (Vault adapter); its entire purpose is to forward through a Zodiac Roles permissioning layer (Access-control shim); driven by a CRE report family (Oracle-transport).

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| CRE Forwarder / workflow | Bounded by the Roles scope | Issues SUPPLY/APPROVE/REDEEM/REPAY with caller-chosen amounts; `to`/destinations are injected or pinned. Its power is exactly what the Roles scope permits — not what this contract allows. |
| `owner()` (Timelock) | Trusted (timelock) | Six build-phase re-points (`setRoles`, `setRoleKey`, `setWarehouseSafe`, `setEePool`, `setUsdc`, `setRedemptionBox`). No custody, no pause. |
| Roles Modifier v2 | Trusted (the boundary) | Validates each forwarded call against its scope and executes it as the warehouse Safe. **The actual security control.** |
| Warehouse Safe | Trusted (custody) | Holds the EulerEarn shares backing all outstanding zipUSD float; acts only via the modifier. |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Mis-scoped Roles policy** — if the off-chain Roles scope is wrong (a param left wildcarded, a delegatecall option granted, the wrong avatar), this contract's hardcoding is the *only* remaining defense. The scope is where the real risk lives.
2. **`warehouseSafe` ↔ `roles.avatar()` parity break** — these are independent slots; a one-sided re-point bricks SUPPLY/REDEEM. Fail-closed (a liveness failure, not a leak), but a live risk.
3. **Compromised CRE workflow** — bounded by the scope + the injection/hardcoding; can grief (e.g. ill-timed redeem) within the permitted ops.
4. **Compromised Timelock owner** — build-phase wiring is re-pointable; the destination guarantees are conditional on correct wiring + the pre-prod re-freeze.

See [entry-points.md](entry-points.md) — no permissionless entry points.

### Trust Boundaries

- **The Roles scope (off-chain config)** — `_processReport:189` forwards through `roles.execTransactionWithRole`; the param-pinning (`receiver==avatar`, `spender==eePool`, `EqualTo(redemptionBox)`, Call-only) is enforced by the modifier's *scope*, **not** this file. This is the single most important thing to audit, and it is out of this scope.
- **Operation hardcoding** — `value=0`, `OP_CALL=0`, `shouldRevert=true` are literals at the call site (`:189`), never payload-decoded; this is the on-chain half of the no-delegatecall/no-value guarantee.
- **`warehouseSafe` parity** — `warehouseSafe` (here) and the modifier's `avatar` are independent (`:43-48`); SUPPLY/REDEEM inject `warehouseSafe` while the scope checks `receiver==avatar`, so they must match. Not checked on-chain. *Git signal: 7 source-touching commits, top fix-score 19 — high churn.*
- **Build-phase wiring** — all six slots are `onlyOwner` re-pointable (§17), to be re-frozen to immutable at pre-prod (off-chain process, not enforced here).

### Key Attack Surfaces

- **The Roles scope is the real control, and it's out of scope** &nbsp;[[X-1](invariants.md#x-1)] — `_processReport:189` trusts the modifier's scope for param-pinning; this contract's injections are explicitly "belt-and-suspenders." Worth auditing the deployed Roles scope tree (receiver/spender/`EqualTo` pins, Call-only, no delegatecall option) as the primary artifact — the bytecode here is secondary.

- **`warehouseSafe` ↔ `avatar` parity is unverified on-chain** &nbsp;[[X-2](invariants.md#x-2)] — `setWarehouseSafe:126` writes `warehouseSafe` but never reads/asserts `roles.avatar()`; the docstring says it MUST be paired with `setAvatar` on the modifier. Worth confirming the runbook/deploy enforces the pair and ideally adding a post-condition parity check.

- **REPAY `dest` is the one payload-carried address** &nbsp;[[I-3](invariants.md#i-3)] — `_processReport:176-182` decodes `dest` then both reverts on `dest != redemptionBox` and re-injects `redemptionBox` into the actual calldata. Worth confirming the injected (not the decoded) value is what's transferred (it is — `:182` uses `redemptionBox`), so even a scope gap can't redirect REPAY.

- **Build-phase mutable wiring** &nbsp;[[X-3](invariants.md#x-3)] — six `onlyOwner` setters re-point roles/roleKey/safe/pool/usdc/redemptionBox; the value-routing guarantees are conditional on correct wiring + the deferred immutable re-freeze. Worth confirming the pre-prod lock-down ships.

- **`roleKey` non-zero** — `setRoleKey:116` rejects zero (the `NoMembership` sentinel that would make every forward revert); a correct but *wrong* non-zero key would silently fail-closed. Worth confirming the assigned key matches the modifier's `assignRoles`.

### Upgrade Architecture Concerns

- **No upgradeability, no custody** — plain constructor-config contract; a change is redeploy + `assignRoles` + re-wire. The blast radius of *this* contract is small precisely because enforcement lives in the modifier; the upgrade risk is concentrated in the Roles scope, not here.

### Protocol-Type Concerns

**As an EulerEarn 4626 adapter:**
- SUPPLY/REDEEM inject `warehouseSafe` as receiver/owner; standard 4626 share-accounting risk lives in EulerEarn (out of scope). Worth confirming amounts/shares are the only caller-chosen values and they can't route value outside the Safe.

**As an access-control shim:**
- The four ops are an allow-list by construction (`UnsupportedOpType` on any other byte, `:184`); the security depends on the modifier's scope matching this op set. Worth confirming the scope grants *only* these four selectors on these targets.

### Temporal Risk Profile

**Deployment & Initialization:**
- Correct operation requires three independent set-ups to agree: this contract's immutables, the modifier's `assignRoles(roleKey)`, and the modifier's `avatar`/scope. A mismatch fails closed (no leak) but bricks the warehouse. Worth confirming the deploy orchestrator wires all three coherently before go-live.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Zodiac Roles Modifier v2** — via `roles.execTransactionWithRole`
> - Assumes: the modifier's scope pins receiver/spender/`to` and forbids delegatecall; this contract is its sole role member.
> - Validates: on-chain here — operation hardcoded to Call, value 0, `shouldRevert` true; the param pins are the modifier's job (off-chain scope).
> - Mutability: Timelock-re-pointable (`setRoles`, `setRoleKey`); the scope itself is owned by the modifier's owner.
> - On failure: `shouldRevert=true` → the modifier reverts `ModuleTransactionFailed`; the unreachable `RoleExecFailed` is defense-in-depth.

> **EulerEarn (4626 pool)** — via injected `eePool.deposit/redeem`
> - Assumes: standard 4626; shares minted to / burned from `warehouseSafe`.
> - Validates: receiver/owner injected from immutables (not payload); amounts caller-chosen.
> - Mutability: Timelock-re-pointable (`setEePool`).
> - On failure: reverts bubble through the modifier.

> **CRE Forwarder** — via `_processReport`
> - Assumes: well-formed `(opType, payload)`.
> - Validates: opType ∈ {1,2,3,4} else `UnsupportedOpType`; REPAY dest self-checked.
> - Mutability: Forwarder identity via `ReceiverTemplate` (Timelock-re-pointable).
> - On failure: reverts on bad opType / wrong REPAY dest.

**Token Assumptions** *(unvalidated only)*:
- USDC is assumed standard (approve/transfer); it is the canonical Base USDC. Blacklist/pause behavior would brick ops (fail-closed), not leak.

**Shared State Exposure:**
- The warehouse Safe's EulerEarn shares back outstanding zipUSD float — a redeem here affects senior NAV/liquidity downstream (the senior par-redemption path).

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> - **9 Enforced Guards** (`G-1` … `G-9`)
> - **3 Single-Contract Invariants** (`I-1` … `I-3`) — operation hardcoding, op allow-list, REPAY injection
> - **3 Cross-Contract Invariants** (`X-1` … `X-3`) — Roles-scope-is-the-boundary, avatar parity, mutable wiring
> - **0 Economic Invariants** — this is a router; the economic invariants live in EulerEarn / the loss + NAV subsystems
>
> The high-signal blocks are all **On-chain=No** cross-contract ones — the security genuinely lives outside this file.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing (in scope dir) | Design in NatSpec + `claude-zipcode.md` §4.5/§8.5, warehouse runbook |
| NatSpec | ~37 annotations | Excellent — the "boundary is the scope not the bytecode" thesis and the avatar-parity hazard are stated inline |
| Spec/Whitepaper | Missing (in scope dir) | External `claude-zipcode.md` (out of dir) |
| Inline Comments | Thorough | Hardcoding rationale, REPAY self-enforcement, parity warning all documented |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files (this scope) | 1 dedicated | `WarehouseAdminModule.t.sol` — **fork integration** vs the real deployed Roles modifier |
| Test functions (this scope) | 24 | integration (not isolated unit) — incl. the full scope-rejection matrix |
| Line coverage | Unavailable — project-wide `Stack too deep` (fails even with `--ir-minimum`) | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 24 | WarehouseAdminModule |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry invariant) | 0 | none |
| Formal Verification | 0 | none |

### Gaps

> **CORRECTION (2026-06-20):** an earlier draft of this report claimed the decisive Roles-scope integration test was "not present." That was wrong. `test/WarehouseAdminModule.t.sol` is a **fork integration suite against the real deployed Roles modifier** and already covers the full scope-rejection matrix: `test_Scope_PinsParams_DepositReceiver`/`_TransferTo` (param pins), `test_CallOnly_RejectsValueAndDelegatecall` (value + **delegatecall** rejected), `test_Escalation_Blocked` (enableModule/addOwner/wrong-target/wrong-selector), `test_NonMember_Reverts`, forwarder-gate, reentrancy, atomicity, malformed-payload. The decisive control IS proven.

- **No fuzz/invariant tests** — low priority: a deterministic stateless encoder with no arithmetic; fuzzing adds little.
- **`warehouseSafe ↔ roles.avatar()` parity is untested** — the contract's own documented #1 hazard (`:43-48`) has no test that a one-sided re-point fails closed (SUPPLY/REDEEM revert, no leak). **This is the one real test gap.**
- **The six `onlyOwner` setters are untested** — no coverage that `setRoles`/`setRoleKey`/`setWarehouseSafe`/`setEePool`/`setUsdc`/`setRedemptionBox` reject non-owners and take effect. Minor but worth a few lines.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 7 source-touching commits over the repo's 30-day life; `WarehouseAdminModule.sol` was modified 7 times.

### Contributors

| Author | Commits | % of Source Changes |
|--------|--------:|--------------------:|
| rootdraws | (sole) | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 | No peer-review trail in git |
| Source-touching commits | 7 | Active rework |
| Test co-change rate | 71.4% | 5 of 7 source commits also touched tests |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| WarehouseAdminModule.sol | 7 | High churn for a 107-nSLOC file |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| a428db7 | 2026-06-14 | fair-LP oracle + redemption-queue/freeze rework | 19 | broad multi-domain diff (file touched among many) |
| c7ac42d | — | 8-Bw CreditWarehouse (senior custody) BUILT-VERIFIED | 16 | the build-verify commit that introduced this contract |
| 81df630 / 5f3706d / ea79c4e | — | Safe-identity standardize / deploy orchestrator / loss-side wiring | 17 | repo-wide wiring sweeps that re-touched this file |

### Security Observations

- **High churn for a tiny file** — 7 modifications of 107 nSLOC; mostly wiring/standardization sweeps rather than logic rewrites.
- **Single-developer, zero merge commits** — no peer-review signal in git.
- **No TODO/FIXME/HACK markers**.
- **The contract's own docs flag its #1 hazard** (avatar parity) — unusual and good discipline.

### Cross-Reference Synthesis

- **The contract is small because the enforcement is elsewhere** → review effort should shift from this bytecode to the deployed Roles scope tree + the avatar-parity wiring (X-1, X-2).
- **Repeated wiring-sweep churn + build-phase mutable slots** → confirm the pre-prod immutable re-freeze and the scope/roleKey/avatar coherence in one go.

---

## X-Ray Verdict

**ADEQUATE** *(revised up from FRAGILE — see correction below)* — clean, well-documented, defensively hardcoded encoder with clear roles + Timelock, and its decisive control (the Zodiac Roles scope) is **proven by a fork integration suite** that exercises the full scope-rejection matrix against the real deployed modifier. Held at ADEQUATE (not HARDENED) only by the two real gaps: the `warehouseSafe ↔ avatar` parity is untested and the `onlyOwner` setters are untested; no fuzz/invariant (low value for a deterministic router).

> **CORRECTION (2026-06-20):** the first draft graded this FRAGILE on the reasoning that the Roles-scope integration test was absent. That was a misread — `WarehouseAdminModule.t.sol` is a fork integration suite that already proves the scope rejects redirected receivers, wrong REPAY dests, value, delegatecall, and target/selector escalation. With the decisive control demonstrably covered, the honest tier is ADEQUATE.

**Structural facts:**
1. 107 nSLOC, 1 non-upgradeable contract holding no custody; 0 permissionless entry points.
2. 6 `onlyOwner` (Timelock) wiring setters + 1 Forwarder-gated `_processReport` dispatching 4 hardcoded ops.
3. `value`/`operation`/`shouldRevert` are literals (0 / Call / true) at the single call site — never payload-decoded.
4. 24 **fork integration** tests vs the real Roles modifier (full scope-rejection matrix); 0 fuzz, 0 invariant. Untested: avatar-parity fail-closed + the six setters.
5. Coverage uninstrumentable — project-wide stack-too-deep even under `--ir-minimum`.
