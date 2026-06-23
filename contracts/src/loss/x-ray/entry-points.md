# Entry Point Map

> Loss Subsystem | 12 entry points | 0 permissionless | 5 CRE/coordinator-gated | 7 admin (Timelock)

> **CURRENT STATE (2026-06-20): scope-level index; per-contract X-Rays are authoritative.** This bundled map
> predates the one-per-contract pass. Entry points are unchanged; the test-connected per-contract detail lives in
> `DefaultCoordinator.md` and `LienXAlphaEscrow.md`.

Scope: `DefaultCoordinator`, `LienXAlphaEscrow`. View/pure excluded. **There are no permissionless entry points** — every state-changer is Forwarder-gated (CRE), `onlyCoordinator`, or `onlyOwner`.

---

## Protocol Flow Paths

### Setup (Deploy / Timelock)

`DefaultCoordinator(constructor)` (oracle, xAlpha, recoveryFloor) → `setEscrow()` (wires escrow; no standing allowance — JIT per lock)
`LienXAlphaEscrow(constructor)` (xAlpha, coordinator, adminSafe, juniorTrancheSafe) → ownership → Timelock  ◄── circular escrow↔coordinator wiring

### Loss lifecycle (CRE → coordinator → escrow)

`Forwarder → _processReport(8)` →
   Lock → `escrow.lockXAlpha`  ◄── status None
     ├─→ Release → `escrow.releaseXAlpha`            ◄── status Bonded (clean repay)
     └─→ Default → `navOracle.writeProvision`        ◄── status Bonded
            ├─→ Recovery → `writeProvision` (partial heal)   ◄── status Defaulted
            ├─→ Resolve  → `writeProvision` + `slashToCapital?` + `slashToCohort?`   ◄── status Defaulted
            └─→ WriteOff → `slashToCapital?` + `slashToCohort?` (NO writeProvision)  ◄── status Defaulted

---

## Role-Gated

### CRE Forwarder (DefaultCoordinator)

#### `_processReport()` (via `ReceiverTemplate.onReport`)

| Aspect | Detail |
|--------|--------|
| Visibility | internal override (forwarder-gated entry) |
| Caller | Chainlink Forwarder (CRE workflow) |
| Parameters | report → (reportType=8, (action, data)); action ∈ {Lock,Release,Default,Recovery,Resolve,WriteOff} (keeper-provided); data carries lienId/originator/amount/atRisk/proceeds/capitalSlashAmount (keeper-provided) |
| Call chain | `→ _lock/_release/_default/_recovery/_resolve/_writeOff → escrow.* and/or navOracle.writeProvision` |
| State modified | `lienLoss[lienId]` (status, provision), `totalProvision` |
| Value flow | indirect — drives escrow transfers; none directly in the coordinator |
| Reentrancy guard | escrow legs carry `nonReentrant`; coordinator writes ledger before external calls (CEI) |

*Internal handlers (not directly callable): `_lock`, `_release`, `_default`, `_recovery`, `_resolve`, `_writeOff`.*

### `onlyCoordinator` (LienXAlphaEscrow)

| Function | Parameters | Call chain | State | Value flow | Guard |
|----------|-----------|-----------|-------|-----------|-------|
| `lockXAlpha()` | lienId, originator, amount (all coordinator-supplied) | `→ xAlpha.safeTransferFrom(coordinator→escrow)` | `bondAmount[lien]`, `bondOriginator[lien]` set | xALPHA: coordinator → escrow | nonReentrant; no-clobber (`BondExists`) |
| `releaseXAlpha()` | lienId | `→ xAlpha.safeTransfer(→ bondOriginator)` | both mappings zeroed | xALPHA: escrow → originator | nonReentrant; CEI |
| `slashXAlphaToCapital()` | lienId, amount (≤ bond) | `→ xAlpha.safeTransfer(→ adminSafe)` | `bondAmount[lien] -= amount` | xALPHA: escrow → treasury | nonReentrant; `ExceedsBond` |
| `slashXAlphaToCohort()` | lienId | `→ xAlpha.safeTransfer(→ juniorTrancheSafe)` | both mappings zeroed | xALPHA: escrow → engine Safe | nonReentrant; `NoBond` |

*All four reachable only by the wired `coordinator` (the `DefaultCoordinator`). No recipient parameter exists on any path — destinations are recorded-at-lock or fixed wiring.*

---

## Admin-Only (Timelock `onlyOwner`)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| DefaultCoordinator | `setEscrow()` | escrow_ | `escrow` (no standing allowance; `_lock` approves exact amount JIT — LOSS-ADV-01) |
| DefaultCoordinator | `setNavOracle()` | navOracle_ | `navOracle` |
| DefaultCoordinator | `setXAlpha()` | xAlpha_ | `xAlpha` (+ re-approve escrow if wired) |
| DefaultCoordinator | `setRecoveryFloor()` | newFloor (`<1e18`) | `recoveryFloor` (future defaults only) |
| LienXAlphaEscrow | `setXAlpha()` | xAlpha_ | `xAlpha` |
| LienXAlphaEscrow | `setCoordinator()` | coordinator_ | `coordinator` |
| LienXAlphaEscrow | `setAdminSafe()` | adminSafe_ | `adminSafe` (capital-slash sink) |
| LienXAlphaEscrow | `setJuniorTrancheSafe()` | juniorTrancheSafe_ | `juniorTrancheSafe` (cohort sink) |

*All build-phase re-pointable (§17), to be re-frozen to immutable at pre-prod lock-down (off-chain process, not enforced here).*

---

## Initialization

| Contract | Function | Access | Notes |
|----------|----------|--------|-------|
| DefaultCoordinator | `constructor(forwarder, navOracle, xAlpha, recoveryFloor)` | deploy | `recoveryFloor < 1e18`; ownership → Timelock post-deploy; escrow wired later via `setEscrow` |
| LienXAlphaEscrow | `constructor(xAlpha, coordinator, adminSafe, juniorTrancheSafe)` | deploy | all-nonzero guard; `Ownable(msg.sender)` → transferred to Timelock |
