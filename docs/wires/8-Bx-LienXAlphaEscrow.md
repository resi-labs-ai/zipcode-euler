# 8-Bx — LienXAlphaEscrow (wiring map)

> Source of truth = the kept code `contracts/src/loss/LienXAlphaEscrow.sol` +
> `contracts/src/interfaces/loss/ILienXAlphaEscrow.sol`. Ticket `tickets/loss/8-Bx-lien-xalpha-escrow.md`
> + report `reports/8-Bx-report.md` are intent — **code wins**. Spec: `claude-zipcode.md` §4.6 / §11
> (+ §2 / §6.4 / §7). This doc reads the code as the final form.
>
> **Code-vs-ticket delta (load-bearing):** the ticket/report describe four `immutable` slots on a
> `ReentrancyGuard`-only base. The KEPT code is the **post-review amendment** (`reports/8-Bx-report.md`
> §"POST-REVIEW AMENDMENT") that joined the repo-wide **build-phase Timelock-settable wiring** decision
> (§17, memory `[[oracle-replaceable-timelock-wiring]]`): the contract `is ReentrancyGuard, Ownable`, the
> four slots are **storage (Timelock-re-pointable), not `immutable`**, and four `onlyOwner` setters exist.
> The destination-integrity theft-immunity is therefore the **pre-production** shape (re-freeze the four
> slots to `immutable` at lock-down restores the absolute); in the build phase it holds against everyone
> **except the Timelock owner**, who can re-point (a grief/redirect, never a drain — see Gotchas).

## Role
The loss-side sibling of the senior `ZipRedemptionQueue` (item 9): a **standalone, non-sweepable custody
contract** holding the originator's **xALPHA first-loss bond per lien** — a slashable reservoir. It is
**not** a Zodiac module, **not** a Baal shaman, **not** a CRE `ReceiverTemplate`. Base set is
`ReentrancyGuard, Ownable` (`:48`) — `ReentrancyGuard` mirrors the item-9 sibling (belt-and-suspenders,
the token is swappable); `Ownable` is the build-phase Timelock admin (the only added authority, and it
holds **no fund-extraction path** — there is no sweep/rescue/skim/pause). Two halves:

- **CUSTODY (M1-live):** `lockXAlpha` posts the bond at origination (protocol-posted on the originator's
  behalf at launch, §2/§4.6), `releaseXAlpha` returns the full bond on repayment.
- **SLASH (built + mock-tested now, M2-live with the `DefaultCoordinator` driver):** on a default the
  bond is held through the freeze and applied at resolution in **two ordered jobs** —
  `slashXAlphaToCapital` (xALPHA → `treasurySafe`, off-chain alpha→TAO→USDC, covers a realized capital
  hole) then `slashXAlphaToCohort` (remainder = the in-kind Duration-Bond premium → `sidecar`; NAV does
  the socialized cohort pro-rata for free).

The escrow adds **no** on-chain solvency / default gating — the capital-vs-premium split and the timing
are the coordinator's job (§4.6, the §13 trust boundary). It is a dumb router with one structural
guarantee: destination integrity.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `LienXAlphaEscrow` (`is ReentrancyGuard, Ownable`) | Holds the per-lien xALPHA bond. Four `onlyCoordinator nonReentrant` state-changers (`lockXAlpha`/`releaseXAlpha`/`slashXAlphaToCapital`/`slashXAlphaToCohort`); four `onlyOwner` wiring setters (`setXAlpha`/`setCoordinator`/`setTreasurySafe`/`setSidecar`); per-lien book `bondAmount[lienId]` + `bondOriginator[lienId]`. No recipient param on any transfer. Custody-models `reference/.../InsuranceFund.sol:bring(:33)` (single-authorized-caller + gated `safeTransfer`), replicated clean-room over OZ `IERC20`+`SafeERC20` (not imported). |
| `ILienXAlphaEscrow` | The seam the `DefaultCoordinator` drives: the four state-changers + the two views (`bondAmount`, `bondOriginator`) it reads to route a slash. Interface-not-import (loose coupling, project pattern). |

## Wiring — internal
### The four wiring slots (Timelock-settable; build phase, §17)
All four are public storage, set in the constructor (`:106-115`, ctor reverts `ZeroAddress` if any is
`address(0)`) and re-pointable by the `onlyOwner` setters (the lock-down re-freezes them to `immutable`):

- **`IERC20 public xAlpha`** (`:57`) — the bond asset (the bridged xALPHA / 8x-01 `SzAlphaMirror`; a
  generic ERC-20 stand-in in M1 tests). Setter `setXAlpha` (`:119`).
- **`address public coordinator`** (`:60`) — the **SOLE** authorized caller of all four state-changers
  (`onlyCoordinator`, `:97-100`, reverts `NotCoordinator`). Setter `setCoordinator` (`:126`).
- **`address public treasurySafe`** (`:62`) — the **ONLY** destination of `slashXAlphaToCapital`. Setter
  `setTreasurySafe` (`:133`).
- **`address public sidecar`** (`:65`) — the **ONLY** destination of `slashXAlphaToCohort`. Setter
  `setSidecar` (`:140`).

Each setter is `onlyOwner`, rejects `address(0)` (`ZeroWiring`), and emits
`WiringSet(bytes32 slot, address value)` (slot = `"xAlpha"`/`"coordinator"`/`"treasurySafe"`/`"sidecar"`).

### Per-lien bond book
- **`bondAmount[bytes32 lienId] → uint256`** (`:69`) — current escrowed xALPHA for the lien. `lienId` is
  the **canonical `bytes32`** type (aligned to controller / factory / venue / CRE-report; a security-critic
  catch over a `uint256` draft).
- **`bondOriginator[bytes32 lienId] → address`** (`:71`) — who the bond returns to on release (recorded at
  lock from the coordinator's arg, **not** a per-call recipient).

### The four `onlyCoordinator nonReentrant` entrypoints (CEI throughout)
- **`lockXAlpha(bytes32 lienId, address originator, uint256 amount)`** (`:152`) — post the bond, pulled
  from the coordinator. Guards: `originator != 0` (`ZeroOriginator`), `originator != address(this)`
  (`SelfOriginator`, the self-lock footgun), `amount != 0` (`ZeroAmount`), `bondAmount[lienId] == 0`
  (`BondExists` — **no clobber / no top-up**). CEI: both mappings written **before** the
  `safeTransferFrom(msg.sender, this, amount)` pull, so a failed pull reverts the whole tx and leaves
  **no orphaned entry**. Emits `Locked`.
- **`releaseXAlpha(bytes32 lienId)`** (`:169`) — return the **FULL** bond to the recorded `bondOriginator`.
  Reverts `NoBond` if `bondAmount == 0`. CEI: both mappings zeroed before `safeTransfer(originator, amount)`.
  Emits `Released`. (No `amount` param — it is structurally the whole bond.)
- **`slashXAlphaToCapital(bytes32 lienId, uint256 amount)`** (`:188`) — route `amount` (≤ bond) xALPHA to
  `treasurySafe`. Guards: `amount != 0` (`ZeroAmount`), `amount <= bondAmount[lienId]` (`ExceedsBond`;
  `amount == bondAmount` is the exact-equality boundary that **passes** and drives the bond to 0). Partial
  allowed: `bondAmount -= amount` (effects first), `bondOriginator` **untouched** (lien still
  mid-resolution). No swap here — alpha→TAO→USDC happens off-chain (§11). Emits `SlashedToCapital`.
- **`slashXAlphaToCohort(bytes32 lienId)`** (`:206`) — route the **ENTIRE remaining** bond (the in-kind
  premium) to `sidecar`. Reverts `NoBond` if `remaining == 0` (so the coordinator **skips** this when a
  full-bond capital slash already cleared the bond). CEI: both mappings zeroed before
  `safeTransfer(sidecar, remaining)`. Emits `SlashedToCohort` (the REMAINING amount).

**No entrypoint takes a recipient parameter.** xALPHA can only flow to `bondOriginator[lienId]` (release),
`treasurySafe` (capital slash), or `sidecar` (cohort slash). The destinations are structurally fixed (per
call) — see the security thesis.

## Wiring — cross-component (who points at whom)
- **`coordinator` = `DefaultCoordinator`** — the sole caller of all four state-changers, set as the
  `coordinator` slot at deploy. The coordinator **is** that wired address from S-deploy; it owns the full
  bond lifecycle (LOCK/RELEASE M1-live, slash M2), custodies the protocol's launch xALPHA reserve, and
  `forceApprove(escrow, max)`s the escrow so `lockXAlpha`'s `safeTransferFrom(coordinator, …)` pull
  succeeds. (`DefaultCoordinator` wiring: PROGRESS row 367 — `setEscrow` + RESOLVE/WRITEOFF →
  `slashXAlphaToCapital`(if>0)→`slashXAlphaToCohort`, reading `escrow.bondAmount` to skip cohort on a
  full-capital-slash; the capital-vs-premium split is the off-chain CRE `capitalSlashAmount` arg.)
- **`xAlpha` = the bridged `SzAlphaMirror`** (8x-01) — a **generic ERC-20 stand-in until the CCIP lane is
  live**; item-10 / 8x-01 wiring (PROGRESS row 373(f)) repoints `LienXAlphaEscrow.xAlpha` to the deployed
  `SzAlpha`/mirror, replacing the stand-in.
- **`treasurySafe` = the protocol treasury Safe — the recovery custody** (§11) — receives `slashXAlphaToCapital`;
  its off-chain process liquidates alpha → TAO → USDC on Bittensor and supplies that USDC to the warehouse to
  fill the realized hole. The escrow only **routes** xALPHA to it (no swap on-chain).
- **`sidecar` = the 8-B1 substrate sidecar Safe** (§6.4) — the non-ragequittable Safe whose xALPHA balance
  **accretes the frozen cohort's NAV pro-rata**. `SzipNavOracle` values the sidecar's xALPHA leg (PROGRESS
  row 368), so routing the premium into the sidecar grows every frozen holder's `navPerShare` equally — the
  socialized pro-rata is automatic via NAV (**no snapshot / per-holder index / RewardsDistributor / SBT** —
  the §4.6 spec fix this window; `HaircutLockAccountant`/`RecoveryClaimSBT` are NOT built).
- **`Ownable(msg.sender)` → Timelock** — item-10 `transferOwnership(timelock)`; the Timelock is the sole
  re-point authority for the four slots (and holds no fund path).

## Item-10 deploy facts (PROGRESS row 366)
- Construct with the **four wiring args** `(xAlpha, coordinator, treasurySafe, sidecar)`; ctor reverts
  `ZeroAddress` on any zero. `Ownable(msg.sender)` sets the deployer as owner → `transferOwnership(timelock)`.
- Wire: `xAlpha`→ the bridged xALPHA (8x-01 `SzAlphaMirror`, stand-in until the lane is live);
  `coordinator`→ the loss-side orchestrator that posts launch bonds (the `DefaultCoordinator`);
  `treasurySafe`→ the protocol treasury Safe / recovery custody (alpha→TAO→USDC); `sidecar`→ the 8-B1 substrate
  sidecar Safe.
- **Assert** all four slots wired correctly **AND** the coordinator has **approved** the escrow over the
  protocol's launch xALPHA **before any `lockXAlpha`** (else the `safeTransferFrom` pull reverts) **AND**
  the wired `xAlpha` is **non-fee-on-transfer / non-rebasing** (load-bearing — the contract has **no
  balance-delta defense**; a generic mock is fine in tests, the production-token swap MUST be asserted
  hookless+feeless).
- **Operational invariant:** the coordinator **MUST terminalize every locked lien** (release, or
  slash-then-cohort) — a never-resolved bond is **permanently stuck** (non-sweepable by design). Do NOT
  lock a bond against a coordinator that may be decommissioned without a live successor.
- Tested 44/44 (→ 40/40 after the amendment's no-sweep ABI-negative reframe); 512/512 total no regression.
  Not git-committed (superintendent commit decision, consistent with the item-9 / 8-B* windows).

## Gotchas
- **Destination integrity (the security thesis).** No state-changer takes a recipient parameter; xALPHA can
  only ever reach `{recorded bondOriginator, treasurySafe, sidecar}`. So a **compromised `coordinator`
  cannot redirect a bond to an attacker** — it can only **GRIEF** (premature release / slash a healthy
  bond), which is the coordinator's §13 trust boundary. Proven by a 128k-call stateful invariant
  (fork-of-funds: xALPHA never lands outside that set, never on `address(this)`). **Build-phase caveat:**
  the four slots are Timelock-settable, so the theft-immunity holds against everyone **except the Timelock
  owner**, who can re-point a destination — still a grief/redirect, **not a drain** (there is no
  sweep/rescue path). Re-freezing the slots to `immutable` at the pre-prod lock-down restores the absolute.
- **No balance-delta defense → the token must be hookless + feeless.** The contract trusts `amount`
  one-to-one against `bondAmount` bookkeeping; it does **not** measure `balanceBefore/After`. A
  fee-on-transfer or rebasing `xAlpha` would desync the book and strand/over-route funds — hence the
  item-10 non-fee/non-rebasing assertion is load-bearing, and `nonReentrant` is mandatory because the
  token is swappable (a future hooked token could reenter; CEI + the guard together close it).
- **`bytes32 lienId`** aligned to the canonical controller / factory / venue / CRE-report type — a
  `uint256` key would break the join across the loss-side and the origination spine.
- **Non-sweepable, no recovery path.** A never-resolved bond is permanently stuck — by design (a sweep
  would be a 4th privileged path over the first-loss bond). The mitigation is the terminal-call operational
  invariant above, not a rescue function.
- **`Ownable` adds NO fund authority.** The owner can only re-point the four wiring slots (each guarded
  `ZeroWiring`); it cannot move bonds, sweep, pause, or release. Every fund-moving path stays
  `onlyCoordinator`.
