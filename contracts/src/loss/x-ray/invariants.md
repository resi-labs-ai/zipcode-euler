# Invariant Map

> Loss Subsystem | 17 guards | 8 inferred | 3 not enforced on-chain

> **CURRENT STATE (2026-06-20): scope-level catalog; per-contract X-Rays are authoritative for test connection.**
> Each invariant is now connected to the test that proves it (incl. fuzz + Foundry invariants) in
> `DefaultCoordinator.md` (conservation `totalProvision==Σ`, the sole-writer ↔ oracle seam, the default bound, the
> status machine) and `LienXAlphaEscrow.md` (per-lien donation-immune conservation, three-destination routing,
> reentrancy battery).

---

## 1. Enforced Guards (Reference)

#### G-1
`if (navOracle_==0 || xAlpha_==0) revert ZeroAddress()` · `DefaultCoordinator.sol:131` · ctor: the provision sink and bond asset must exist.

#### G-2
`if (recoveryFloor_ >= 1e18) revert InvalidRecoveryFloor()` · `DefaultCoordinator.sol:132` · the floor is a fraction < 100%; a default must mark down a positive amount.

#### G-3
`if (escrow_==0) revert ZeroAddress()` · `DefaultCoordinator.sol` `setEscrow` · `setEscrow` cannot wire a null escrow. Grants NO standing allowance; `_lock` approves the exact bond amount just-in-time and resets to 0.

#### G-4
`if (navOracle_==0) revert ZeroAddress()` · `DefaultCoordinator.sol:153` · re-point keeps a live provision sink.

#### G-5
`if (xAlpha_==0) revert ZeroAddress()` · `DefaultCoordinator.sol:160` · re-point keeps a live bond asset.

#### G-6
`if (newFloor >= 1e18) revert InvalidRecoveryFloor()` · `DefaultCoordinator.sol:171` · the setter preserves the ctor bound on the floor.

#### G-7
`if (reportType != REPORT_TYPE) revert InvalidReportType(reportType)` · `DefaultCoordinator.sol:183` · scopes the dispatcher to reportType 8.

#### G-8
`else revert InvalidAction(action)` · `DefaultCoordinator.sol:199` · only the six defined actions dispatch.

#### G-9
`if (lienLoss[lienId].status != LienStatus.None) revert BadStatus()` · `DefaultCoordinator.sol:208` · LOCK only from a fresh lien (no re-bond).

#### G-10
`if (lienLoss[lienId].status != LienStatus.Bonded) revert BadStatus()` · `DefaultCoordinator.sol:221,236` · RELEASE and DEFAULT require a Bonded lien.

#### G-11
`if (atRisk == 0) revert ZeroAtRisk()` · `DefaultCoordinator.sol:237` · a default must recognize a positive at-risk amount.

#### G-12
`if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus()` · `DefaultCoordinator.sol:255,278,299` · RECOVERY/RESOLVE/WRITEOFF require a Defaulted lien (no skipping the machine).

#### G-13
`if (xAlpha_||coordinator_||adminSafe_||juniorTrancheSafe_ == 0) revert ZeroAddress()` · `LienXAlphaEscrow.sol:111` · ctor: all four wiring slots non-zero.

#### G-14
`if (... == 0) revert ZeroWiring()` · `LienXAlphaEscrow.sol:124,131,138,145` · each Timelock re-point rejects the zero address.

#### G-15
`if (originator==0) ZeroOriginator; if (originator==address(this)) SelfOriginator; if (amount==0) ZeroAmount; if (bondAmount[lienId]!=0) BondExists` · `LienXAlphaEscrow.sol:157-160` · LOCK preconditions: real recipient, not the escrow itself, positive amount, no clobber.

#### G-16
`if (amount==0) ZeroAmount; if (amount > bondAmount[lienId]) ExceedsBond` · `LienXAlphaEscrow.sol:193-194` · capital slash is positive and bounded by the recorded bond.

#### G-17
`if (amount==0 / remaining==0) revert NoBond()` · `LienXAlphaEscrow.sol:175,213` · RELEASE / cohort-slash require an existing bond.

*All four escrow state-changers also carry `nonReentrant` and `onlyCoordinator`; the coordinator setters carry `onlyOwner`.*

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Conservation` · On-chain: **Yes** (within the coordinator)

> `totalProvision == Σ lienLoss[lienId].provision` over all liens (including WrittenOff, whose residual persists).

**Derivation** — Δ-pairs: `_default:240-242` (`provision = p; totalProvision += p`), `_recovery:259-260` (`provision -= reduction; totalProvision -= reduction`), `_resolve:280-281` (`totalProvision -= provision; provision = 0`). `_writeOff` changes neither. No other writer of `totalProvision` or `provision` exists.

**If violated** — the NAV provision desyncs from the per-lien ledger; the whole loss accounting is wrong.

#### I-2

`Bound` · On-chain: **Yes**

> Every default provision = `atRisk × (1 − recoveryFloor) / 1e18`, rounded down; with `recoveryFloor ∈ [0, 1e18)`.

**Derivation** — guard-lift: `_default:239` formula + `recoveryFloor < 1e18` enforced at every write site (`ctor:132`, `setRecoveryFloor:171`). Truncating div never over-marks.

**If violated** — NAV could be marked down by more than the at-risk amount; the bound prevents over-impairment.

#### I-3

`Bound` · On-chain: **Yes**

> A recovery never heals a provision below 0: `reduction = min(provision, proceeds)`.

**Derivation** — `_recovery:258` (`reduction = recoveryProceeds >= cur ? cur : recoveryProceeds`); `provision` and `totalProvision` both decremented by the same clamped `reduction`.

**If violated** — `totalProvision` could underflow / NAV rise above the un-impaired basket; the clamp prevents it.

#### I-4

`StateMachine` · On-chain: **Yes**

> Lien status follows `None → Bonded → {None | Defaulted}`, `Defaulted → {Resolved | WrittenOff}`, with no reverse edges and no re-entry: no re-recognition, no post-resolution heal, no release of a defaulted lien.

**Derivation** — edges: `_lock` (None→Bonded, `:208,210`), `_release` (Bonded→None, `:221,223`), `_default` (Bonded→Defaulted, `:236,241`), `_recovery` (Defaulted→Defaulted, `:255`), `_resolve` (Defaulted→Resolved, `:278,282`), `_writeOff` (Defaulted→WrittenOff, `:299,301`). Each guarded by `BadStatus`. No path writes a status its guard would forbid as a source.

**If violated** — double-counting a loss, healing a written-off loss, or releasing a defaulted bond.

#### I-5

`Conservation` · On-chain: **Yes** (donation-immune)

> Per lien, the escrow holds exactly `bondAmount[lienId]`; all transfers use the recorded amount, never `balanceOf` — so a direct token donation cannot affect any lien's accounting.

**Derivation** — `LienXAlphaEscrow`: `lockXAlpha:162-165` sets then pulls `amount`; `releaseXAlpha:178-181` zeroes then sends `amount`; `slashXAlphaToCapital:196-198` subtracts then sends `amount`; `slashXAlphaToCohort:215-218` zeroes then sends `remaining`. No path reads `balanceOf`.

**If violated** — n/a on-chain; the design is donation-immune. (A fee/rebase token would break the bond==custody equality — see X-2.)

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No**

> The coordinator assumes the CRE-supplied `atRisk` / `recoveryProceeds` / `capitalSlashAmount` / `originator` reflect a real default of that magnitude. Only well-formedness is checked on-chain, not economic truth (§13).

**Caller side** — `DefaultCoordinator._processReport:181` + handlers (`_default:235`, `_recovery:254`, `_resolve:277`, `_writeOff:298`, `_lock:207`).

**Callee side** — the CRE workflow behind the Forwarder — **out of scope** (off-chain DON). The on-chain code caps the damage to grief (down-mark NAV, slash a healthy bond, reclaim a fresh bond via a hostile `originator`); it cannot be steered to an arbitrary destination or to inflate NAV.

**If violated** — a compromised CRE griefs within the documented ceiling. On-chain=No because the magnitude/timing/originator are trusted, not verified.

#### X-2

On-chain: **No** (build phase)

> Destination integrity ("xALPHA can only reach originator / treasury / engine Safe") holds absolutely only once the sinks are immutable. In the build phase the Timelock can re-point `adminSafe` / `juniorTrancheSafe` / `coordinator` / `xAlpha`.

**Caller side** — the slash transfers read `adminSafe` / `juniorTrancheSafe` (`LienXAlphaEscrow.sol:198,218`).

**Callee side** — the wiring setters `setAdminSafe:137` / `setJuniorTrancheSafe:144` / `setCoordinator:130` / `setXAlpha:123` (all `onlyOwner`).

**If violated** — a compromised/over-powered Timelock re-points a sink (grief/redirect, not a drain to an arbitrary EOA per call — but the sink itself becomes attacker-chosen if the owner is). The documented pre-prod immutable re-freeze closes this; it is **not** on-chain enforced today.

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes**

> The NAV impairment provision can only move **down** by `atRisk×(1−recoveryFloor)` at recognition and heal **up** by realized receipts (partial) or fully to 0 on clean resolve; floored at 0, never above the un-impaired basket; a WriteOff leaves the residual in place as the realized loss.

**Follows from** — `I-1` (conservation) + `I-2` (default bound) + `I-3` (recovery floor-at-0) + `I-4` (status machine forbids re-recognition / post-resolution heal). `_writeOff` not calling `writeProvision` keeps the residual.

**If violated** — NAV could be inflated above real backing or a loss double-counted; the combination of the bounds + the sole-writer conservation prevents both on-chain.
