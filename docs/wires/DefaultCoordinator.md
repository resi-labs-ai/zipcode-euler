# DefaultCoordinator — loss-side orchestrator (NAV provision writer + xALPHA bond router) (wiring map)

> Source of truth = the kept code `contracts/src/loss/DefaultCoordinator.sol` +
> `contracts/src/interfaces/loss/{ISzipNavOracle,ILienXAlphaEscrow}.sol`. Ticket
> `tickets/loss/DefaultCoordinator.md` + report `reports/DefaultCoordinator-report.md` are intent only — **the
> code wins.** Where the ticket/report still say "immutable / renounce-frozen / set-once", that is the first-pass
> build; the kept code is the build-phase **Timelock-settable** form (report POST-REVIEW AMENDMENT 2026-06-09;
> memory `oracle-replaceable-timelock-wiring`). This doc reads the code as final. `claude-zipcode.md` §4.6/§11/§7/§8.4/§17.

## Role
The **single loss-side orchestrator**: a CRE-gated `ReceiverTemplate` (`is ReceiverTemplate`, `:40`) that holds
two cross-component authority bindings — it **is** the `LienXAlphaEscrow.coordinator` (the sole caller of all four
escrow state-changers, so it owns the **full** xALPHA bond lifecycle) **and** it **is** the
`SzipNavOracle.defaultCoordinator` (the **sole** `writeProvision` caller, enforcing the impairment bound the oracle
deliberately stores unbounded). It custodies the protocol's **launch xALPHA reserve** and `forceApprove(escrow,
type(uint256).max)` so the escrow's `lockXAlpha` pull from this contract succeeds (`setEscrow`, `:140-145`).

Every action enters through the base's Forwarder-gated `onReport` → the abstract `_processReport` (`:177`) which it
implements as a **reportType-8 action dispatcher** (`REPORT_TYPE = 8`, `:45`). It is **not** a Zodiac module and
**not** a Baal shaman (unlike its escrow sibling) — it is a `ReceiverTemplate` subclass, the same base
`SzipNavOracle`/`ZipcodeController`/registry use. The load-bearing on-chain logic is the **provision bound**; it
**bounds and routes**, it does **not** validate that a default is real (the §13 trust boundary, NatSpec `:21-39`).
The freeze is **not** its job — that is structural and the Exit Gate's (§6.4); this contract writes the NAV markdown
and routes the bond, nothing more. There is **no** sweep, no pause, no freeze/`lockedFraction` surface.

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `DefaultCoordinator` (`is ReceiverTemplate`, `using SafeERC20 for IERC20`) | The orchestrator. Per-lien `lienLoss[lienId] = (LienStatus status, uint256 provision)` ledger + a running `totalProvision`; dispatches the reportType-8 LOCK/RELEASE/DEFAULT/RECOVERY/RESOLVE/WRITEOFF family in `_processReport`; pushes `totalProvision` to the oracle and drives the escrow's lock/release/slash. |
| `ReceiverTemplate` (`x402-cre-price-alerts`, base) | `is IReceiver, Ownable`. Ctor pins the Forwarder (reverts `InvalidForwarderAddress` on zero); `onReport(metadata, report)` checks `msg.sender == forwarder` then the optional `expectedWorkflowId`, then calls `_processReport`; `setExpectedWorkflowId(bytes32)` `onlyOwner`. Supplies the CRE entry gate + the owner. |
| `ISzipNavOracle` (`interfaces/loss/ISzipNavOracle.sol`) | One method: `writeProvision(uint256)`. Concrete impl `SzipNavOracle`; it gates `msg.sender == defaultCoordinator` (`NotDefaultCoordinator`) and stores the value **UNBOUNDED by design** — the bound is the coordinator's job (`SzipNavOracle.sol:34-36`, `:246-249`). |
| `ILienXAlphaEscrow` (`interfaces/loss/ILienXAlphaEscrow.sol`) | The four `onlyCoordinator` state-changers (`lockXAlpha`/`releaseXAlpha`/`slashXAlphaToCapital`/`slashXAlphaToCohort`) + the two views (`bondAmount`/`bondOriginator`) the coordinator reads to route a slash. Concrete impl `LienXAlphaEscrow`. |
| `IERC20`/`SafeERC20` (OZ) | The xALPHA bond asset handle; `forceApprove` grants the escrow the max allowance. **OZ** imports (not `forge-std`) — `forceApprove` needs the OZ `SafeERC20` binding. |

## Wiring — internal (constructor, immutables, ledger, dispatch)
**Constructor** (`:124-132`): `constructor(address forwarder, address navOracle_, address xAlpha_, uint256
recoveryFloor_) ReceiverTemplate(forwarder)`.
- `forwarder` → the base validates `!= 0` (`InvalidForwarderAddress`).
- `navOracle_`/`xAlpha_` → `ZeroAddress` if either is zero.
- `recoveryFloor_` → `InvalidRecoveryFloor` if `>= 1e18` (a 100% floor would mean a zero provision forever). Accepts
  `0` and `1e18 - 1` (the legal boundary).
- Stores `navOracle` (`ISzipNavOracle`), `xAlpha` (`IERC20`), `recoveryFloor` (18-dp fraction, `1e18 = 100%`).

**State slots are Timelock-settable, NOT immutable** (`:83-97`, §17 build phase). `navOracle`, `xAlpha`,
`recoveryFloor` are seeded in the ctor; `escrow` is wired post-deploy (the escrow↔coordinator deploy is circular).
All four have `onlyOwner` re-pointers: `setNavOracle` (`:148`), `setXAlpha` (`:155`, re-`forceApprove`s the escrow if
already wired), `setRecoveryFloor` (`:166`, bounded `< 1e18`, does **not** retro-mark existing provisions), `setEscrow`
(`:140`). **`setEscrow` is re-pointable** (no `AlreadyWired` guard fires on it — the `AlreadyWired` error is declared
but unused in the kept code) and re-grants `xAlpha.forceApprove(escrow_, type(uint256).max)` each call.

**The provision bound** (the reason this contract exists — the oracle omits it):
- **DEFAULT** writes the provision **down** by `p = atRisk * (1e18 - recoveryFloor) / 1e18` (`:235`), truncating —
  rounds **DOWN**, never over-marks. Sets `lienLoss[lienId].provision = p`, status `Defaulted`, `totalProvision += p`,
  then `navOracle.writeProvision(totalProvision)`. `atRisk == 0` reverts `ZeroAtRisk`; a **zero-result** DEFAULT (high
  floor × small `atRisk`) does **not** revert.
- **RECOVERY** writes **up only by realized receipts**: `reduction = min(provision, recoveryProceeds)`; `provision -=
  reduction`, `totalProvision -= reduction`, push (`:249-260`). Floors at 0 — can never write NAV **above** the
  un-impaired basket. Status **stays** `Defaulted` (partial heal).
- **RESOLVE** heals the provision to 0: `totalProvision -= provision; provision = 0; status = Resolved`, push
  (`:267-275`).
- **WRITEOFF** settles **permanently**: leaves `provision` (and so `totalProvision`) **unchanged** — the residual IS
  the realized loss — and does **NOT** call `writeProvision` (no change) (`:288-298`).
- **Sole-writer invariant:** every `totalProvision +=`/`-=` is paired with the identical per-lien `provision` change,
  so `totalProvision == Σ lienLoss.provision == oracle.provision()` holds at all times and no `-=` can underflow
  (0.8.24 checked arithmetic). `totalProvision` counts WrittenOff liens forever (their residual persists).

**The reportType-8 dispatch** (`_processReport`, `:177-197`): decode `(uint8 reportType, bytes payload)`; reject
`reportType != 8` (`InvalidReportType`). Decode `(uint8 action, bytes data)`; branch on the `Action` enum
`{Lock 0, Release 1, Default_ 2, Recovery 3, Resolve 4, WriteOff 5}` to the matching internal handler; `action >= 6`
reverts `InvalidAction`. Each handler `abi.decode`s `data` to its §8.4 sub-tuple:
- `_lock` (`:202`): `(lienId, originator, amount)`. `status != None` ⇒ `BadStatus`. Sets status `Bonded` **before** the
  external `escrow.lockXAlpha(lienId, originator, amount)` (CEI — a failed pull reverts the whole report, no orphan
  status).
- `_release` (`:215`): `(lienId)`. Requires `Bonded` (clean-repay path); sets `None`; `escrow.releaseXAlpha`. A Bonded
  lien always carries provision 0, so `totalProvision` is untouched.
- `_default`/`_recovery`/`_resolve`/`_writeOff`: the bound logic above + the slash driving below.

**The status machine guards** (each illegal source reverts `BadStatus`): `None→Bonded` (LOCK); `Bonded→None`
(RELEASE); `Bonded→Defaulted` (DEFAULT); `Defaulted→Defaulted` (RECOVERY); `Defaulted→Resolved` (RESOLVE);
`Defaulted→WrittenOff` (WRITEOFF). Concretely this forbids: **no re-recognition** (DEFAULT only from `Bonded`); **no
post-resolution heal** (RECOVERY/RESOLVE/WRITEOFF only from `Defaulted`, so `Resolved`/`WrittenOff` are terminal);
**no release of a defaulted lien** (RELEASE only from `Bonded`); **no LOCK on a terminal lien** (LOCK only from `None`
— the escrow would otherwise *allow* a re-lock at `bondAmount == 0`, so this guard is the only thing blocking it).

**The slash driving** (RESOLVE/WRITEOFF, `:277-278` / `:294-295`): `if (capitalSlashAmount != 0)
escrow.slashXAlphaToCapital(lienId, capitalSlashAmount)` then `if (escrow.bondAmount(lienId) != 0)
escrow.slashXAlphaToCohort(lienId)`. Capital-first then cohort; the `bondAmount` read skips the cohort leg when a
full-bond capital slash already cleared the bond (else `slashXAlphaToCohort` would revert `NoBond`). The
capital-vs-premium split (`capitalSlashAmount`) is the CRE's off-chain arg — the escrow enforces only `amount ≤ bond`.

## Wiring — cross-component (who points at whom)
- **It IS `escrow.coordinator`.** `LienXAlphaEscrow.coordinator` is the sole authorized caller of all four
  state-changers (`onlyCoordinator`). The coordinator must be that wired address from deploy — which forces LOCK/RELEASE
  (M1-live launch bonding) into its surface too, not just slash. Wired by `setEscrow` on this side + the escrow's
  `coordinator` slot on the other; `setEscrow` also `forceApprove`s the escrow over xALPHA so `lockXAlpha`'s
  `safeTransferFrom(coordinator, …)` pull succeeds. The escrow is itself non-sweepable + `onlyCoordinator`, so the max
  allowance is safe — its only pull path is this contract's own LOCK.
- **It IS `oracle.defaultCoordinator`.** `SzipNavOracle.writeProvision` reverts `NotDefaultCoordinator` for anyone but
  the wired `defaultCoordinator`; the oracle stores the value **unbounded** (`SzipNavOracle.sol:34-36`). Wired by
  `oracle.setDefaultCoordinator(coordinator)` (`SzipNavOracle.sol:202`, `onlyOwner`/Timelock). This contract is the
  only `writeProvision` caller in the system.
- **Bond destinations are escrow-side immutables-in-spirit** (Timelock-set in the build phase): `bondOriginator`
  (captured at lock from the coordinator's `originator` arg — the RELEASE recipient), `treasurySafe` (the
  `slashXAlphaToCapital` destination, alpha→TAO→USDC recovery account), `sidecar` (the `slashXAlphaToCohort`
  destination, the non-ragequittable cohort Safe; NAV does the socialized pro-rata). The coordinator can route a bond
  only to these three — **no attacker-chosen destination** except the CRE-named `originator` leg.
- **The §13 trust boundary** (NatSpec `:21-39`): under §13 the CRE (DON-consensus, behind the Forwarder + the pinned
  workflow identity) is trusted for the **magnitude** of `atRisk`/`recoveryProceeds`/`capitalSlashAmount`, the
  **timing** of each action, the capital-vs-premium **split**, and the `originator` address. A compromised CRE can
  **grief** (down-mark NAV — making concurrent exiters exit-poor, since `writeProvision` is immediate/unsmoothed; slash
  a healthy bond; reclaim a fresh bond via a hostile `originator`) but **cannot steal to an arbitrary address or
  inflate NAV**. The contract is **non-sweepable** (over-funding xALPHA is a permanent accepted loss — fund exactly
  `amount` just-in-time).

## Item-10 deploy facts (the loss-side wiring — PROGRESS row 47/48/326/367; deploy still OPEN)
The escrow↔coordinator deploy is **circular** — the escrow's ctor needs the coordinator address and the coordinator
needs the escrow. The item-10 sequence (ticket KR-15 + the created obligation):
1. Deploy `SzipNavOracle` first (no circularity — the coordinator takes it as a ctor arg).
2. Deploy `DefaultCoordinator(forwarder, navOracle, xAlpha, recoveryFloor)` — `recoveryFloor` is the governed value set
   at the ctor; `escrow` unset.
3. Deploy `LienXAlphaEscrow(xAlpha, coordinator=this, treasurySafe, sidecar)`.
4. `coordinator.setEscrow(escrow)` (sets `escrow` + `forceApprove(escrow, max)`).
5. `oracle.setDefaultCoordinator(coordinator)`.
6. `coordinator.setExpectedWorkflowId(id)` — a **distinct** Forwarder identity/workflowId from the
   controller/registry/oracle.
7. **Assert before hand-off** (a hard tested `require`, not prose): two-way `escrow.coordinator() == coordinator` AND
   `coordinator.escrow() == escrow` (so the max approval landed on the verified escrow); `oracle.defaultCoordinator()
   == coordinator`; `coordinator.navOracle() == oracle`; `coordinator.getForwarderAddress() ==` the intended Forwarder;
   **`coordinator.getExpectedWorkflowId() != 0`** (else sealed "Forwarder-gated but workflow-blind" — any DON workflow
   could drive reportType-8 actions); `xAlpha.allowance(coordinator, escrow) == type(uint256).max`.
8. `transferOwnership(timelock)` — **NOT `renounceOwnership`** (§17 build phase: the owner is the Timelock, the same
   admin that owns the engine Zodiac modules' CRE flows; ownership is transferred, not renounced).

**Identity pre-gate.** `DefaultCoordinator is ReceiverTemplate`, so the WOOF-10a / S10b / S11 **deploy identity
pre-gate** applies — the fail-closed gate that requires the Forwarder + a non-zero `expectedWorkflowId` be set before
the contract is considered live (the renounce-before-identity / hand-off-before-identity bricking modes the gate
guards against: hand-off before `setEscrow` bricks both the coordinator and the escrow; hand-off before
`setExpectedWorkflowId` opens the workflow-blind grief surface).

**xALPHA funding discipline.** The coordinator custodies the launch xALPHA reserve and is **non-sweepable** —
over-funding leaves xALPHA permanently stuck. The CRE/treasury MUST transfer **exactly** each bond's `amount`
immediately before its LOCK report (no standing reserve), and the wired `xAlpha` MUST be **non-fee-on-transfer /
non-rebasing** (the contract has no balance-delta defense). Every locked lien must be terminalized (release, or
slash-then-cohort) — a never-resolved bond is permanently stuck.

Both inbound obligations are **DISCHARGED** by this build: the **provision bound** owed to `SzipNavOracle` (PROGRESS
row 326) and the **slash split-policy + driver** owed to 8-Bx `LienXAlphaEscrow` (PROGRESS row 367).

## Gotchas
- **NAV can never be marked above the un-impaired basket.** RECOVERY floors the per-lien provision at 0 and there is
  **no path that increases a provision after recognition** — so `totalProvision` can never exceed the ghost sum of
  recognized `atRisk×(1−floor)` markdowns. The truncating `atRisk*(1e18-floor)/1e18` rounds DOWN (favorable). The bound
  constrains the *transform*, not the *magnitude* — `atRisk` is CRE-supplied (§13).
- **WRITEOFF must NOT decrement `totalProvision`.** The residual IS the realized loss and must persist; a copy of the
  RESOLVE decrement here would silently heal a written-off loss and over-state NAV (security F9). WRITEOFF deliberately
  does not call `writeProvision` (no co-emit of `ProvisionWritten`).
- **The kept code is Timelock-settable, NOT renounce-frozen.** The ticket/report/§4.6 "immutable / set-once / frozen
  by renounce" language describes the FIRST-pass build; per the build-phase doctrine (memory
  `oracle-replaceable-timelock-wiring`) the loss side joined the repo-wide Timelock-re-pointable wiring decision.
  `setEscrow`/`setNavOracle`/`setXAlpha`/`setRecoveryFloor` are live `onlyOwner` (Timelock) setters; `recoveryFloor`
  is a governed value, not a ctor-frozen constant; the oracle's `defaultCoordinator` is likewise Timelock-re-pointable
  (`SzipNavOracle.setDefaultCoordinator`). The `AlreadyWired` error remains declared but is **unused** (a vestige of
  the set-once draft). Re-freezing all of this to immutable is **deferred to the pre-production lock-down** — the
  provision-bound + status-machine logic is unchanged; only the wiring mutability changed.
- **`escrow` may be unset at construction.** `_lock`/`_release`/slash handlers will revert if `setEscrow` has not run
  (a call on the zero-address escrow). The item-10 two-way `require` is what guarantees it is wired before the contract
  goes live.
- **No `nonReentrant`.** The entry is Forwarder-gated (single trusted caller) and every external callee (the escrow —
  itself `nonReentrant` — and the oracle) is trusted in-protocol; CEI is maintained (all ledger writes before the
  external escrow/oracle calls in every handler).
