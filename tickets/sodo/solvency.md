# solvency.md — BUILD SPEC: the capital-hole waterfall (loss side)

> **Status: build-spec — Stream 2 BUILT-VERIFIED 2026-06-09.** The waterfall is now fully built on-chain
> (DefaultCoordinator + LienXAlphaEscrow + SzipNavOracle provision + the buy-burn + **Stream 2 `RecycleModule.divert`**
> are live). The only remaining loss-side work is **S2 item-10 wiring** (deploy/assert, not a contract). Every
> interface below is verified against source (sig/auth/events/errors + file:line). Sibling spec = `credit-union.md`
> (the exit side). S1 `divert` shipped via the harness (5 critics → cold-build + KEEP): code at
> `contracts/src/supply/szipUSD/RecycleModule.sol` (the `divert` mode), `contracts/test/RecycleModule.t.sol`
> (15 new tests), `tickets/sodo/S1-recycle-divert.md`, `reports/S1-report.md`. No emojis.

---

## A. The scenario + division of labor (locked)

A drawn credit line reads **100% utilized** the whole term (`cash=0 ⇒ utilization=100%`); only **repayment**
drops it. A defaulted line is identical on the utilization axis — it just never un-sticks at maturity (the
calcification is emergent from the per-line EVK `maxWithdraw`, not coded; `solvency` inherits it).

**Markdown ≠ resolution.** When a line impairs, `DefaultCoordinator` writes a `provision` markdown into
`SzipNavOracle` — an *accounting recognition*, not cash. It does not change utilization, free the calcified
junior, or produce the USDC the line was backing. The result is a **real capital hole** (under-backed value)
behind a markdown ledger.

**The job:** mend the hole fast so depositors stay whole, and let the **protocol carry the duration mismatch** —
front in-house capital now, recover off-chain behind the depositor. Resolution speed keeps the peg, trust, and
inflows alive so the system can keep taking duration.

| Axis | Mechanism | Where | Status |
| --- | --- | --- | --- |
| **Liquidity** | the freeze (holds the calcified position) | `DurationFreezeModule` | BUILT |
| **Value** | the markdown (sizes the hole + who eats it first) | `DefaultCoordinator` → `SzipNavOracle.provision` | BUILT |
| **Recovery** | the waterfall (moves real dollars into the hole) | this spec | 4/5 BUILT, Stream 2 = GAP |

The freeze is the **runway**, not the fix. The markdown only sizes the hole. The waterfall is the fix.

---

## B. The waterfall (verified)

**The hole is the credit warehouse's USDC backing.** A defaulted loan leaves the warehouse short of the USDC that
backs zipUSD (the "hollow zipUSD" sitting in the non-RQ basket). Filling it = **supplying USDC into the warehouse
(EulerEarn), no zipUSD minted**, until backing ≥ zipUSD owed. `capitalSink` (`LienXAlphaEscrow.sol:62`) is **NOT
the hole** — it is the off-chain **alpha→TAO→USDC conversion venue** for the xALPHA slash (Stream 1); its USDC
output also ends up supplying the warehouse. Streams ordered by loss-priority, annotated by speed + build status:

| # | Stream | Who pays | Speed | Status | Verified surface |
| --- | --- | --- | --- | --- | --- |
| 0 | **markdown ledger** (recognition, not cash) | junior NAV (on paper) | instant | **BUILT** | `DefaultCoordinator` `Action{Lock,Release,Default_,Recovery,Resolve,WriteOff}` (`:48-56`), `reportType=8`; provision = `atRisk×(1e18−recoveryFloor)/1e18` at Default (`:235`), `−min(provision,proceeds)` at Recovery (`:254`), `→0` at Resolve (`:271`), **kept** at WriteOff (residual = realized loss, `:284-287`); `navOracle.writeProvision(totalProvision)` |
| 1 | **xALPHA bond slash → `capitalSink`** | bond-poster / originator (first loss) | fast | **BUILT** (M2-live) | `LienXAlphaEscrow.slashXAlphaToCapital(lienId,amount):188` onlyCoordinator+nonReentrant, CEI, `ExceedsBond`; then `slashXAlphaToCohort(lienId):206` → `sidecar` (remainder = premium) |
| 2 | **yield diversion → supply the warehouse** | stayers (forgone yield) | continuous | **GAP — unwired (S1 below)** | engine free-value USDC → `eePool.deposit(amount, warehouse)`, **no zipUSD mint**, fills backing; bound by `provision()` |
| 3 | **buy-at-discount-burn (szipUSD)** | exiters (haircut = NAV − discount) | market | **BUILT** | `SzipBuyBurnModule.postBid:241` (buy szipUSD `≤ navExit×(1−d)`, `d` = the insolvency haircut) → `ExitGate.burnFor:283` (burn → NAV/share up, haircut socialized to stayers) |
| 4 | **lien workout** (foreclosure / insurance / collections) | collateral / insurer | slow (mo.–yr.) | **BUILT** (on-chain hook) | off-chain → `DefaultCoordinator.Recovery` (`:250-260`) → receipts reduce provision; bond `Resolve`/`WriteOff` slash routes to `capitalSink`/`sidecar` |

The fast in-house streams (1, 2, 3) close the hole on **protocol time**; the slow external stream (4)
reimburses the protocol *behind* the depositor. The gap between the two clocks is the protocol's carry — by
design, not the depositor's wait.

**§13 residual-trust boundary (verified, do not erode).** The Coordinator **bounds and routes; it does NOT
validate that a default is real.** On-chain guarantees: provision written DOWN only by `atRisk×(1−recoveryFloor)`,
UP only by realized receipts (floored 0), never above the un-impaired basket; `totalProvision == Σ lienLoss.
provision == oracle.provision()`; bond flows ONLY to `bondOriginator`/`capitalSink`/`sidecar` (no attacker dest);
the status machine forbids re-recognition / post-resolution heal. A compromised CRE can **grief** (down-mark NAV,
mis-time), **not steal** and **not inflate NAV**. Ownership is **Timelock** (governs `recoveryFloor` + the CRE
Forwarder identity), never renounced.

---

## C. Build items

### S1. Stream 2 — divert engine yield into the bank (the warehouse) (NEW)

**Deliverable.** A `divert` mode on **`RecycleModule`** (RESOLVED — not a new contract; it already owns
`freeValueAccrued` + the spend discipline). It **supplies engine free-value USDC straight into the credit
warehouse** — `eePool.deposit(amount, warehouse)`, **no zipUSD minted** — so the warehouse's USDC backing rises
toward ≥ zipUSD owed, filling the hole. Bounded by the live `provision`. Plus tests. (Distinct from Stream 1: the
xALPHA slash goes to `capitalSink` to be *converted* to USDC; Stream 2 is already USDC, so it goes straight to the
bank.)

**Spec §.** `claude-zipcode.md` §2 (USDC over-collateralizes zipUSD in the warehouse), §5 (yield routing), §11
(loss side / fill the hole), §4.5.1 (engine modules). Depositor return is the xALPHA subsidy; the diverted yield
goes to the bank instead of compounding the basket.

**Model from (VERIFIED).**
- `RecycleModule` (`contracts/src/supply/szipUSD/RecycleModule.sol`, BUILT) — the attach point:
  - State: `freeValueAccrued` (`:68`, USDC 6-dp), `engineSafe`/`operator`/`zipDepositModule`/`usdc` (set-once);
    `avatar = target = engineSafe` (= the rq Safe). `creditFreeValue:161`, `recycle:183` (current sink: backed
    zipUSD mint via `zipDepositModule` — **divert must NOT mint zipUSD**), `_spendFreeValue:169` CEI, `_exec`.
- `SzipNavOracle.provision()` (`:102`, BUILT) — the hole size (18-dp USD); the bound (read the oracle).
- **EulerEarn** (`eePool`, the senior pool) — `deposit(uint256 assets, address receiver) returns (uint256 shares)`
  (ERC-4626, `IEulerEarn.sol:13`; "pulls assets from caller, mints shares to receiver"). **VERIFIED MODEL: copy
  `ZipDepositModule.deposit:120-121`** — `usdc.forceApprove(eePool, amount)` then `eePool.deposit(amount,
  warehouse)`, shares → warehouse Safe — **but OMIT the zipUSD mint at `:119`.** That is the whole difference: same
  EE-supply path, no new senior claim. (Builder note: EE is ERC-4626 — respect its `maxDeposit` if a cap exists.)

**Starting state.** `freeValueAccrued` USDC sits on the rq Safe; `recycle()` compounds it into the basket (and
mints zipUSD). Nothing reads `provision` or supplies the warehouse from engine yield.

**Do NOT.**
- Do NOT mint zipUSD — supply **raw USDC** into EE crediting the warehouse (more backing, NOT new senior claims).
- Do NOT route to `capitalSink` — that is Stream 1's xALPHA→USDC conversion venue, a different stream; Stream 2's
  USDC goes straight to the bank.
- Do NOT route to an operator-chosen receiver — the **warehouse** is the wired, set-once receiver (destination
  integrity).
- Do NOT divert more than the live hole (`amount·1e12 ≤ provision()`); do NOT touch `recycle`'s path (divert is a
  second spend of `freeValueAccrued`, CEI-first); do NOT sell xALPHA or pull basket assets (only engine USDC).

**Key requirements.**
1. `setUp` decodes + stores set-once `navOracle` (provision read) + `eePool` (EulerEarn) + `warehouse` (the EE
   deposit receiver). Timelock setters each (§17); `WiringSet`; non-zero guards.
2. `divert(uint256 usdcAmount) external onlyOperator returns (uint256 sent)` — **order load-bearing
   (bounds-before-spend, then CEI):** (a) `usdcAmount > 0` else `ZeroAmount`; (b) `provision() > 0` else `NoHole`;
   (c) **revert** if `usdcAmount * 1e12 > provision()` → `ExceedsHole` (`1e12` scales USDC 6-dp → USD 18-dp; round
   so a divert never over-fills the hole); (d) `_spendFreeValue(usdcAmount)` (CEI; `InsufficientFreeValue`);
   (e) exec the rq Safe: `usdc.approve(eePool, usdcAmount)` → `eePool.deposit(usdcAmount, warehouse)` →
   `usdc.approve(eePool, 0)`; (f) emit `Filled(usdcAmount, warehouse, provisionAfter)`.
3. Reuse `onlyOperator` + `_exec` revert-bubbling, and assert the **warehouse's EE-share balance rose** post-deposit
   (the false-return/FoT guard; model on `DurationFreezeModule.commit`/`release`). Errors `NoHole`, `ExceedsHole`,
   `ZeroAmount`, `ZeroAddress`.

> After a divert fills the bank, the hole is smaller — the CRE writes a `DefaultCoordinator.Recovery` to reduce
> `provision` by the realized fill (the existing recovery path; divert does not write provision itself).

**Done when.** Unit: `divert` supplies USDC into EE crediting the **warehouse** (warehouse EE-share balance up,
rq-Safe USDC + `freeValueAccrued` down), **leaves `recycle` working** on the remainder; emits `Filled`. Reverts:
`provision==0` → `NoHole`; `usdcAmount·1e12 > provision()` → `ExceedsHole`; over-ledger → `InsufficientFreeValue`;
`0` → `ZeroAmount`; non-operator → `NotOperator`. **The `1e12` boundary (qa, HIGH):** pin the rounding with vectors at
`provision = usdcAmount·1e12 ± 1`. **Reentrancy (qa, HIGH):** a re-entrant `divert`/`recycle` mid-`exec` fails
`InsufficientFreeValue` (CEI proof). **Invariant fuzz:** `divert` never sends more than
`min(freeValueAccrued, provision/1e12)`. Mapped to a new `audit/2.md` loss-phase step.

**Depends on.** `RecycleModule` (8-B10, BUILT), `SzipNavOracle.provision` (BUILT), EulerEarn (`eePool`, the
warehouse's senior pool), the `CreditWarehouse` Safe (8-Bw, BUILT). This closes the only unwired stream.

---

### S2. Item-10 wiring (DEPLOY/WIRE — not a contract)

Connect the built pieces into one bank (warehouse) and one provision ledger:
- `SzipNavOracle.setDefaultCoordinator(coordinator)` (`:202`, onlyOwner) — make the Coordinator the sole
  `writeProvision` caller (fail-closed until set: `writeProvision` reverts for everyone).
- `DefaultCoordinator.setEscrow(escrow)` (`:140`), `setNavOracle`, `setXAlpha`, `setRecoveryFloor` —
  Timelock-wired; grant escrow MAX xALPHA allowance.
- `LienXAlphaEscrow` four slots: `setXAlpha`/`setCoordinator(coordinator)`/`setCapitalSink(sink)`/
  `setSidecar(sidecar)` (`:119-144`, onlyOwner).
- `RecycleModule` new slots (S1): `setNavOracle(oracle)`/`setEePool(eePool)`/`setWarehouse(warehouse)`.

**Two deploy-time assertions (testable, in the wire script — qa/security HIGH):**
1. **One bank:** `RecycleModule.warehouse == ZipDepositModule`'s/`WarehouseAdminModule`'s warehouse Safe (the same
   EE-share holder that backs zipUSD) — else diverted USDC supplies the wrong pool and never fills the hole. Revert
   the deploy if mismatched. (Stream 1's `capitalSink` USDC output must also be supplied to this same warehouse — a
   CRE/off-chain step, not on-chain here.)
2. **Single provision / fail-closed:** `SzipNavOracle.defaultCoordinator == DefaultCoordinator`, and
   `writeProvision` reverts `NotDefaultCoordinator` for any other caller (test the pre-wire revert + post-wire
   success).

**Done when.** The wire script runs both assertions before transferring ownership to the Timelock (NOT renounced —
`oracle-replaceable` build-phase); added to `audit/2.md` Phase S.

---

## D. Decisions

**RESOLVED (baked above):**
- **The hole = the warehouse's USDC backing** (not `capitalSink`). Fill it by **supplying USDC into the
  warehouse (EulerEarn), no zipUSD minted** (user-directed: "add USDC straight into the bank").
- **Stream-2 home** — a `divert` mode on `RecycleModule`; destination = the **warehouse** (`eePool.deposit(amount,
  warehouse)`), not `capitalSink`.
- **Provision read source** — `SzipNavOracle.provision()` (lower coupling).
- **Stream-3 buyback = szipUSD only.** The protocol buys the **junior share** (szipUSD) below NAV and burns it; the
  discount `d` = the live solvency haircut (85% solvent → bid ~0.85), socialized to stayers via the burn. The
  **senior hole is filled by supplying USDC into the bank (Stream 2), NOT by buying zipUSD.** No zipUSD buyback;
  a zipUSD backstop stays post-M1.

- **Front-and-recover accounting** — RESOLVED: **one number, no front-ledger.** `provision` IS the running hole;
  every stream (yield-divert now, lien-recovery later) shrinks it; once it hits 0, further recovery is surplus that
  over-backs zipUSD — the protocol's reimbursement for what it fronted. No double-count (all reduce the same number).
- **`capitalSink` freeze** — RESOLVED: `capitalSink` (and the other destination slots) are Timelock-settable only
  during the build/draft phase; **frozen to immutable at the pre-launch lock-down** (§17), so once live nobody —
  not even governance — can redirect recovery funds. On the pre-launch freeze list.
- **Default is the only gate on the bond.** The xALPHA bond releases to the originator on repayment and is **never
  touched unless the lien is marked `Defaulted`.** Two steps: `Default` recognizes the loss (writes `provision`);
  the **slash to `capitalSink`** fires only at `Resolve`/`WriteOff` (which require `Defaulted`), once the workout
  sizes the capital needed. No default → no slash.

**STILL OPEN:** none for M1 — the loss-side is built; S1 (divert) + S2 (item-10 wiring) are the remaining build/
deploy work. (Post-M1: the zipUSD buyback backstop if a loss ever exceeds the entire junior.)

---

## E. Verified interface surface (quick reference)

| Contract | File | Key surface (BUILT) |
| --- | --- | --- |
| `DefaultCoordinator` | `src/loss/DefaultCoordinator.sol` | reportType 8; `Action{Lock0,Release1,Default_2,Recovery3,Resolve4,WriteOff5}:48`; provision `atRisk×(1e18−recoveryFloor)/1e18:235`, recovery `−min:254`, resolve→0 `:271`, writeoff-kept `:284`; `setEscrow:140`/`setNavOracle:148`/`setXAlpha:155`/`setRecoveryFloor:166` onlyOwner; Timelock-owned |
| `LienXAlphaEscrow` | `src/loss/LienXAlphaEscrow.sol` | `lockXAlpha:152`/`releaseXAlpha:169`/`slashXAlphaToCapital:188`(→`capitalSink`)/`slashXAlphaToCohort:206`(→`sidecar`) onlyCoordinator+nonReentrant, CEI; slots `xAlpha/coordinator/capitalSink/sidecar` Timelock-settable; destination-integrity |
| `SzipNavOracle` | `src/supply/SzipNavOracle.sol` | `provision:102` (unbounded at oracle), `writeProvision:246` sole caller=defaultCoordinator, `setDefaultCoordinator:202` onlyOwner; `spotNavPerShare:334` subtracts provision (floored 0) |
| `RecycleModule` | `src/supply/szipUSD/RecycleModule.sol` | `freeValueAccrued:68`, `creditFreeValue:161`/`recycle:183` onlyOperator, `_spendFreeValue:169` CEI; single sink = backed-zipUSD mint; avatar=engineSafe; **no loss coupling (the S1 gap)** |
| `SellModule` | `src/supply/szipUSD/SellModule.sol` | `sellHydx:213`(HYDX→USDC)/`buyXAlpha:228`(zipUSD→xALPHA) onlyOperator, recipient hard-pinned engineSafe |
| `SzipBuyBurnModule`+`ExitGate.burnFor` | `…/SzipBuyBurnModule.sol`,`…/ExitGate.sol` | Stream 3: buy `≤navExit×(1−d)` `:241` → `burnFor:283` (NAV/share up) |

> Note: `engineSafe` above is the **wired avatar label** of the engine modules = the **rq Safe** (Baal avatar),
> not a separate Safe. The substrate (8-B1) summons only rq + sidecar; the warehouse is a third, separate Safe.

---

## F. Out of scope

The **exit side** (off-ramp, fulfillment controller, CoW book) is `credit-union.md`. This spec assumes a line
has gone *bad*; while it is merely *illiquid-but-performing*, credit-union.md's freeze + exit machinery governs.
The two share the same un-lent EulerEarn USDC and the same `capitalSink` discipline (destination integrity),
but they are distinct lifecycles.
