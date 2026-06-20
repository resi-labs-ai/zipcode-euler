# X-Ray Report

> Loss Subsystem | 254 nSLOC | 1549279 (`main`) | Foundry | 20/06/26

Analyzed branch: `main` at `1549279`. Scope: `contracts/src/loss` (2 contracts).

> **CURRENT STATE (2026-06-20): this scope report is the OVERVIEW; the per-contract X-Rays are authoritative.**
> Both contracts now have dedicated, test-connected single-contract X-Rays — both **ADEQUATE** (a hair from
> HARDENED): the strongest-tested scope reviewed (unit + fuzz + Foundry invariants on both).
>
> | Contract | nSLOC | Per-contract X-Ray | Tests | Tier |
> |---|---:|---|---|---|
> | DefaultCoordinator | 158 | `DefaultCoordinator.md` | 66u + 1f + 3i | **ADEQUATE** |
> | LienXAlphaEscrow | 96 | `LienXAlphaEscrow.md` | 44u + 1f + 2i (+5 reentrancy) | **ADEQUATE** |
>
> The bundled `entry-points.md` / `invariants.md` predate the split — see the per-contract files for the
> test-connected detail. Scope-wide residuals: the §13 CRE trust ceiling (grief-not-theft) and the build-phase
> mutable wiring (closed at the pre-prod immutable re-freeze) — both out-of-contract by design.

---

## 1. Protocol Overview

**What it does:** The loss-side of the credit protocol — recognizes/heals NAV impairment provisions and custodies the per-lien xALPHA first-loss bond, both driven by a single CRE-gated orchestrator.

- **Users**: No public users. A CRE workflow (behind the Chainlink Forwarder) drives every loss action; the Timelock owns wiring + the provision floor.
- **Core flow**: `_processReport` (reportType 8) dispatches one of six actions — `Lock`/`Release`/`Default`/`Recovery`/`Resolve`/`WriteOff` — each updating the loss ledger and/or routing the bond.
- **Key mechanism**: a provision is marked **down** only by `atRisk×(1−recoveryFloor)` at default and heals **up** only by realized receipts (or fully to 0 on clean resolve); the escrow can move bonds only to three fixed destinations (originator / treasury / engine Safe).
- **Token model**: holds bridged xALPHA (`SzAlphaMirror`; a generic ERC-20 in M1 tests) as first-loss collateral; pushes an 18-dp USD provision to the NAV oracle.
- **Admin model**: ownership of both contracts is **transferred to the Timelock** at deploy (not renounced). Owner governs `recoveryFloor` + build-phase wiring + the CRE Forwarder identity — explicitly **no theft, no NAV-inflation, no sweep, no pause** power.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Loss orchestration | DefaultCoordinator | 158 | CRE-gated reportType-8 dispatcher; sole `writeProvision` caller; drives the escrow |
| Bond custody | LienXAlphaEscrow | 96 | Standalone non-sweepable per-lien xALPHA custody; `onlyCoordinator` lock/release/slash |

*Both protocol-authored. Inherited `ReceiverTemplate`, OZ `Ownable`/`ReentrancyGuard`/`SafeERC20` are out of scope.*

### How It Fits Together

The core trick: the coordinator **bounds and routes; it does not validate that a default is real** (§13). The CRE (DON consensus, behind the Forwarder) is trusted for the *magnitude/timing/split/originator*; the on-chain code guarantees only the narrow arithmetic + destination integrity — so a compromised CRE can grief but cannot steal or inflate NAV.

### Loss lifecycle (CRE → coordinator)

```
Forwarder → ReceiverTemplate.onReport → DefaultCoordinator._processReport (reportType 8)
  ├─ Lock     → escrow.lockXAlpha(lienId, originator, amount)        status: None → Bonded
  ├─ Release  → escrow.releaseXAlpha(lienId)                         status: Bonded → None  (provision always 0)
  ├─ Default  → provision = atRisk*(1-recoveryFloor)/1e18 (round down)
  │              totalProvision += p ; navOracle.writeProvision(...)  status: Bonded → Defaulted
  ├─ Recovery → totalProvision -= min(provision, proceeds)           status stays Defaulted
  │              navOracle.writeProvision(...)
  ├─ Resolve  → totalProvision -= provision ; provision = 0          status: Defaulted → Resolved
  │              writeProvision ; slashToCapital(amount?) ; slashToCohort(remainder?)
  └─ WriteOff → leave provision IN PLACE (the realized loss)         status: Defaulted → WrittenOff
                 NO writeProvision ; slashToCapital(amount?) ; slashToCohort(remainder?)
```

### Bond custody + slash (coordinator → escrow → fixed sinks)

```
lockXAlpha       → safeTransferFrom(coordinator → escrow)            bondAmount[lien] set (no clobber: BondExists)
releaseXAlpha    → safeTransfer(escrow → bondOriginator)             *recipient recorded at lock, not caller-chosen*
slashXAlphaToCapital(amount<=bond) → safeTransfer(escrow → treasurySafe)   covers realized capital hole
slashXAlphaToCohort(remainder)     → safeTransfer(escrow → engine/main Safe)  premium; NAV socializes pro-rata
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Lending/Borrowing (loss management)** with **Oracle-transport** and **Custody/Escrow** characteristics

Signals: default recognition / loss provisioning / first-loss collateral (Lending loss side); CRE-pushed action family with a documented residual-trust boundary (Oracle-transport); a non-sweepable per-lien bond vault with fixed destinations (Custody).

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| CRE Forwarder / workflow | Bounded (§13 residual trust) | Sole driver of all six loss actions via reportType 8. Trusted for magnitude/timing/split/originator. Can grief (down-mark NAV, slash a healthy bond, reclaim a fresh bond via hostile originator) — **cannot** steal to an arbitrary address or inflate NAV. |
| `owner()` (Timelock) | Trusted (timelock) | `setRecoveryFloor` (bounded `<1e18`), build-phase re-point of escrow/oracle/xAlpha (coordinator) and xAlpha/coordinator/adminSafe/juniorTrancheSafe (escrow), Forwarder identity. **No sweep, no pause, cannot redirect bonds or inflate NAV** — bounds hold against the owner too, except re-pointing sinks (grief/redirect, not drain). |
| DefaultCoordinator | Trusted (in-scope) | The escrow's sole `onlyCoordinator` caller; holds the launch xALPHA reserve + MAX allowance to the escrow. |
| Bond originator | Untrusted (named by CRE) | Receives the bond on `Release`. The one attacker-influenceable destination (the CRE names it at lock). |
| Treasury / Engine Safe | Trusted (fixed sinks) | The only two slash destinations; set at deploy, Timelock-re-pointable in build phase. |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Compromised CRE workflow** — the documented §13 boundary; the whole loss machine moves on its say-so. The audit question is whether its power is truly capped at "grief."
2. **Compromised Timelock owner** — build-phase wiring is re-pointable, so the destination-integrity guarantee is conditional until the pre-prod immutable lock-down.
3. **Accounting / state-machine bug** — the `totalProvision == Σ provision == oracle.provision()` conservation and the lien status machine are the load-bearing invariants.
4. **Token assumptions** — xALPHA is assumed hookless/feeless; a fee/rebase token would desync `bondAmount` bookkeeping.

See [entry-points.md](entry-points.md) — note there are **no permissionless entry points** in this scope.

### Trust Boundaries

- **CRE entry (§13)** — `DefaultCoordinator._processReport:181` is reachable only via the Forwarder-gated `onReport`; that gate **is** the trust boundary. Everything past it trusts the CRE for value/timing/split/originator; the on-chain guarantees are the arithmetic bounds + the status machine. *Git signal: 8 source-touching commits, 3 at fix-score 17 — the most-churned scope reviewed.*
- **Provision write authority** — the coordinator is the *sole* `writeProvision` caller (`_default:244`, `_recovery:262`, `_resolve:284`); `_writeOff` deliberately does **not** call it (residual stays as realized loss). Worth confirming the oracle enforces the sole-writer gate on its side.
- **Escrow destination integrity** — `LienXAlphaEscrow` takes **no recipient parameter** anywhere; xALPHA flows only to `bondOriginator`/`adminSafe`/`juniorTrancheSafe`. This is the theft-immunity thesis — but the sinks are **Timelock-settable in the build phase** (`setAdminSafe:137`, `setJuniorTrancheSafe:144`), so the absolute holds only after the deferred immutable re-freeze.
- **MAX allowance** — `setEscrow:147` grants the escrow `type(uint256).max` xALPHA; safe only because the escrow is non-sweepable and `onlyCoordinator`, whose sole pull is its own `lockXAlpha`.

### Key Attack Surfaces

- **CRE residual-trust ceiling** &nbsp;[[X-1](invariants.md#x-1)] — `_processReport:181` + the six action handlers trust CRE-supplied `atRisk`/`recoveryProceeds`/`capitalSlashAmount`/`originator`. Worth tracing each grief path (unsmoothed down-mark, healthy-bond slash, hostile-originator reclaim) to confirm none escalate past grief into theft or NAV-inflation.

- **Unsmoothed provision → exit interaction** &nbsp;[[I-1](invariants.md#i-1)] — `writeProvision(totalProvision)` is immediate (`_default:244`); a default instantly down-marks NAV, making concurrent exiters exit-poor. Documented as accepted; worth confirming the exit/issuance path (out of scope) handles the step the way §13 assumes.

- **Build-phase mutable sinks** &nbsp;[[X-2](invariants.md#x-2)] — `setAdminSafe`/`setJuniorTrancheSafe`/`setCoordinator`/`setXAlpha` (escrow) + `setEscrow`/`setNavOracle`/`setXAlpha` (coordinator) are all `onlyOwner` re-pointable; the theft-immunity thesis is conditional on the documented pre-prod re-freeze that is **not on-chain enforced**. Worth confirming the lock-down actually ships.

- **`_resolve` over-bond is unasserted by design** &nbsp;[[I-4](invariants.md#i-4)] — `_resolve:276` does not pre-check `capitalSlashAmount <= bondAmount`; it relies on the escrow's `ExceedsBond` revert atomically rolling back the provision heal + status flip (CEI). Worth confirming nothing is stranded on that revert and the CRE can re-submit.

- **xALPHA token assumptions** — every transfer uses recorded `bondAmount`, not `balanceOf`, so the escrow is donation-immune; but a fee-on-transfer/rebasing xALPHA would make `bondAmount` overstate real custody. Worth confirming the production `SzAlphaMirror` is strictly standard ERC-20 (it is — plain BurnMintERC20, per the bridge X-Ray).

- **`_writeOff` leaves provision in place** — `_writeOff:297` intentionally skips `writeProvision`, so the residual persists in `totalProvision` forever as the realized loss. Worth confirming downstream NAV consumers expect a permanently-elevated provision floor for written-off liens.

### Upgrade Architecture Concerns

- **No upgradeability** — both contracts are plain (non-proxy); a change is a redeploy + re-wire. The build-phase re-pointable wiring is the substitute for upgradeability and the main residual (see X-2).

### Protocol-Type Concerns

**As a loss-management system:**
- Provision rounds **down** (`_default:239` truncating div) — favorable (never over-marks); worth confirming no path rounds the other way.
- `recoveryFloor` is not retroactive (`setRecoveryFloor:170` applies to future defaults only) — each lien marked at the floor in force at recognition. Worth confirming this matches the intended loss policy.

**As a custody/escrow:**
- CEI + `nonReentrant` on all four escrow state-changers; transfers after state writes. `lockXAlpha` no-clobber (`BondExists`). Solid; the residual is purely the build-phase mutable wiring.

### Temporal Risk Profile

**Deployment & Initialization:**
- Circular deploy: the coordinator is constructed with the oracle+xAlpha, the escrow is wired post-deploy via `setEscrow` (which also grants the MAX allowance). Worth confirming the deploy orchestrator wires escrow↔coordinator before any action and the ownership handoff to the Timelock is atomic.
- Build-phase wiring is mutable by design (§17); the security absolutes (destination integrity) are stated to hold only after the deferred pre-prod re-freeze — a process step, not on-chain enforced.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **SzipNavOracle** — via `DefaultCoordinator.writeProvision`
> - Assumes: the oracle accepts the pushed `totalProvision` and gates its writer to this coordinator.
> - Validates: coordinator-side, `totalProvision` is the maintained sum; oracle-side gate is out of scope.
> - Mutability: Timelock-re-pointable (`setNavOracle`).
> - On failure: a revert in `writeProvision` reverts the whole action atomically.

> **xALPHA (SzAlphaMirror / generic ERC-20)** — via both contracts
> - Assumes: standard, hookless, feeless ERC-20; `safeTransfer`/`safeTransferFrom` semantics.
> - Validates: SafeERC20 wrappers; per-lien accounting uses recorded amounts (donation-immune).
> - Mutability: Timelock-re-pointable (`setXAlpha` on both).
> - On failure: transfer revert rolls back the action (CEI).

> **CRE Forwarder** — via `_processReport`
> - Assumes: DON consensus delivers a well-formed reportType-8 action with honest magnitude/originator (§13).
> - Validates: reportType, action enum bound; **not** the economic truth of the action.
> - Mutability: Forwarder identity Timelock-re-pointable.
> - On failure: bad reportType/action reverts.

**Token Assumptions** *(unvalidated only)*:
- Fee-on-transfer / rebasing xALPHA would desync `bondAmount` vs real custody — assumed standard (true for the production mirror).

**Shared State Exposure:**
- The cohort-premium slash lands in the engine/main Safe as free liquid value; NAV socializes it pro-rata via gross basket value (no snapshot) — a cross-subsystem coupling to the NAV oracle, not an external pool.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> - **17 Enforced Guards** (`G-1` … `G-17`)
> - **5 Single-Contract Invariants** (`I-1` … `I-5`) — Conservation, Bound, StateMachine
> - **2 Cross-Contract Invariants** (`X-1`, `X-2`) — CRE trust + build-phase mutable sinks
> - **1 Economic Invariant** (`E-1`) — provision can only fall by `atRisk×(1−floor)` and heal by realized receipts
>
> The conservation invariant `totalProvision == Σ lienLoss.provision == oracle.provision()` is the load-bearing one. **On-chain=No** blocks are the high-signal ones.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing (in scope dir) | Design in NatSpec + `claude-zipcode.md` §4.6/§11/§7/§8.4/§13/§17, `docs/` loss summary |
| NatSpec | ~53 annotations | Exceptional — the §13 trust boundary, grief vs theft, and every design trade-off are stated inline |
| Spec/Whitepaper | Missing (in scope dir) | External `claude-zipcode.md` + `baal-spec.md` referenced (out of dir) |
| Inline Comments | Thorough | CEI ordering, rounding direction, deliberate-omission rationale all documented |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files (this scope) | 2 dedicated (+3 touching) | File scan |
| Test functions (this scope) | 116 dedicated | `DefaultCoordinator.t.sol` 70, `LienXAlphaEscrow.t.sol` 46 |
| Line coverage | Unavailable — project-wide `Stack too deep` (fails even with `--ir-minimum`) | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 110 | DefaultCoordinator (66), LienXAlphaEscrow (44) |
| Stateless Fuzz | 2 | both contracts |
| Stateful Fuzz (Foundry invariant) | 5 | DefaultCoordinator (3), LienXAlphaEscrow (2) |
| Formal Verification | 0 | none |

*Plus indirect coverage from `DurationFreezeModule.t.sol` (54/1/1) and `SzipNavOracle.t.sol` (61).* This is the **best-tested scope reviewed** — unit + fuzz + invariant all present.

### Gaps

- **No formal verification** — the conservation invariant (`totalProvision == Σ provision == oracle.provision()`) and the lien status machine are prime Certora/Halmos candidates; the Foundry invariant suite already asserts them under fuzzing, so this is a hardening step, not a gap.
- **Coverage unmeasurable** — project does not compile under the coverage instrumenter (stack-too-deep); test existence (incl. invariant tests) is confirmed by scan.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 8 source-touching commits over 30 days; `DefaultCoordinator.sol` is the single most-modified source file in the repo (8 mods).

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| rootdraws | 106 | +603 / -73 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 106 | No merge commits — no peer-review trail in git |
| Repo age | 2026-05-21 → 2026-06-20 | 30 days |
| Recent source activity (30d) | 8 commits | Active; loss side under continuous rework |
| Test co-change rate | 62.5% | 5 of 8 source commits also touched tests |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| DefaultCoordinator.sol | 8 | #1 churn in the repo — highest-priority review target |
| LienXAlphaEscrow.sol | 5 | High churn |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 81df630 | 2026-06-19 | standardize Safe identities + CTR-11/CTR-13 + line APR | 17 | loosens access control (+61/-76); spans 5 domains |
| 5f3706d | 2026-06-10 | Item-10 deploy orchestrator + wiring map | 17 | tightens access control (+170/-7); spans 5 domains |
| 9a8c06e | 2026-06-09 | szipUSD engine build + RecycleModule rework | 17 | tightens access control (+232/-1); spans 5 domains |
| ea79c4e | 2026-06-09 | Loss side BUILT-VERIFIED + Timelock-settable wiring | 15 | large change (511 lines); spans 5 domains |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| access_control / fund_flows / oracle_price | 8 each | both files |
| state_machines | 8 | DefaultCoordinator.sol |
| liquidation | 5 | LienXAlphaEscrow.sol |

### Security Observations

- **`DefaultCoordinator.sol` is the repo's #1 hotspot** — 8 modifications, 3 fix-score-17 commits; the most-reworked security-critical file reviewed.
- **Single-developer, zero merge commits** — 100% rootdraws; no peer-review trail in git.
- **`81df630` loosened access control (+61/-76)** — a recent broad standardization diff across the loss files; worth a manual diff to confirm no gate was weakened.
- **Strong test discipline** — 5 invariant + 2 fuzz test functions across the two contracts; the only scope reviewed with stateful-fuzz coverage.
- **No TODO/FIXME/HACK markers** — `tech_debt.total_count == 0`.

### Cross-Reference Synthesis

- **#1 churn + 5-domain spread + strong invariant tests** → the high rework is matched by the strongest test suite reviewed; the residual risk is design (§13 trust, build-phase mutable sinks), not under-testing.
- **`81df630` access-control loosen + the §17 mutable-wiring posture** → confirm the pre-prod immutable re-freeze closes the destination-integrity window the loosen + setters leave open.

---

## X-Ray Verdict

**ADEQUATE** (a hair from HARDENED) — strongest scope reviewed: roles + Timelock + `nonReentrant` + CEI throughout, and the only scope with unit **+ fuzz + invariant** tests. Capped at ADEQUATE only because there is no in-scope spec file and no emergency pause; tests and access-control posture are individually HARDENED.

**Structural facts:**
1. 254 nSLOC across 2 non-upgradeable contracts; 0 permissionless entry points.
2. All state-changers are Forwarder-gated (CRE), `onlyCoordinator`, or `onlyOwner` (Timelock); 6 `nonReentrant`, 16 `onlyOwner`, 6 `onlyCoordinator`.
3. 116 dedicated test functions including 2 fuzz + 5 Foundry invariant tests.
4. 100% single-developer; 0 merge commits; `DefaultCoordinator.sol` is the repo's most-modified file (8 commits).
5. Coverage uninstrumentable — project-wide stack-too-deep even under `--ir-minimum`.
