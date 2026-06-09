# DefaultCoordinator — the loss-side orchestrator (NAV provision writer + xALPHA bond router) (§4.6 / §11 / §7 / §8.4)

> **M1 build, M2 demo · build-only.** The **single loss-side orchestrator**. It is the immutable
> `LienXAlphaEscrow.coordinator` (so it owns the **full** xALPHA bond lifecycle) **and** the set-once
> `SzipNavOracle.defaultCoordinator` (the **sole** `writeProvision` caller). A **CRE-gated `ReceiverTemplate`**:
> every action flows through `_processReport` (reportType 8, action-discriminated, §4.4/§8.4); the Forwarder +
> workflow-identity are **renounce-frozen** like the controller/registry/oracle (§4.4/§13). Its **M1-live** surface
> is the bond **LOCK/RELEASE** driving (originator bonds posted at launch, §2); the **DEFAULT/RECOVERY/RESOLVE/
> WRITEOFF** provision+slash paths are **built + mock-tested now**, live with the **M2 default DEMO** (§15) — the same
> "build the M2 paths against mocks now" treatment that landed `LienXAlphaEscrow` (8-Bx, BUILT-VERIFIED 2026-06-09).
>
> **This is NOT a Zodiac module, NOT a Baal shaman.** It IS a `ReceiverTemplate` (unlike its escrow sibling). It
> custodies the protocol's **launch xALPHA reserve** (to fund `lockXAlpha`'s pull) and is otherwise **non-sweepable
> / immutable after renounce** — no owner (renounced), no sweep, no pause, one set-once `setEscrow` frozen by renounce.
>
> **The load-bearing on-chain logic is the BOUND** the oracle deliberately omits (`SzipNavOracle.sol:29-31`): the
> oracle's `writeProvision` is **unbounded**; the coordinator is what constrains the provision to a default-justified
> markdown — **down only by `atRisk × (1 − recoveryFloor)`** at recognition, **up only by realized receipts**, floored
> at 0 — **never an arbitrary NAV** (§7 `:1373`). Everything else (the capital-vs-premium split, timing, default
> state) is computed **off-chain by the CRE** and passed in the report; the contract **bounds + routes** (the §13
> trust boundary, exactly as the escrow trusts its coordinator and the engine modules trust their CRE operator).

**Deliverable**
One contract + tests under the loss tree:
- `contracts/src/loss/DefaultCoordinator.sol` — `contract DefaultCoordinator is ReceiverTemplate` (the base from
  `x402-cre-price-alerts/interfaces/ReceiverTemplate.sol`, the same base `SzipNavOracle` uses, `SzipNavOracle.sol:4,38`;
  `using SafeERC20 for IERC20`). Implements `_processReport` (the abstract hook, `ReceiverTemplate.sol:232`) as a
  reportType-8 action dispatcher. Per-lien loss ledger + `totalProvision`. Drives the escrow (`lockXAlpha`/
  `releaseXAlpha`/`slashXAlphaToCapital`/`slashXAlphaToCohort`) and the oracle (`writeProvision`). All authority +
  destinations immutable / set-once-frozen.
- `contracts/test/DefaultCoordinator.t.sol` — unit (every action happy + negative, the bound, the status machine) +
  an integration test against the **real `LienXAlphaEscrow`** and the **real `SzipNavOracle`** (both in-repo, no fork
  needed) proving the live `writeProvision` + slash wiring, + a no-sweep ABI-negative + a fuzz on the bound. Uses the
  local `MockERC20` (mirror `contracts/test/LienXAlphaEscrow.t.sol`'s mock — ctor `(uint8 d)`, open `mint`) for the
  xALPHA token, and the `vm.prank(forwarder); coordinator.onReport("", report)` driving pattern from
  `SzipNavOracle.t.sol:144-146` (empty metadata is fine — identity check is off until `setExpectedWorkflowId`).
  **No fork test** — both collaborators are local contracts; the coordinator's logic is venue/token-agnostic and
  fully exercised in-process.

**Spec §**
- `claude-zipcode.md` **§4.6** (the `DefaultCoordinator` bullet — the build-grade shape authored this window: CRE-gated
  `ReceiverTemplate`, renounce-frozen; IS the escrow coordinator (full bond lifecycle) + the oracle's set-once
  `defaultCoordinator`; holds the launch xALPHA reserve + approves the escrow; per-lien `(status, provision)` ledger
  pushed to the oracle as `totalProvision`; the bound; the reportType-8 action family; does NOT engage the freeze).
- **§4.4** (the report ABI — reportType **8** → `DefaultCoordinator` direct: `payload = (uint8 action, bytes
  actionData)`, the LOCK/RELEASE/DEFAULT/RECOVERY/RESOLVE/WRITEOFF family; distinct from the bare reportType-5
  default-STATUS report that goes to the controller, §4.4d).
- **§8.4** (the producer-level action decode — `atRisk`/`recoveryProceeds` 18-dp USD; `capitalSlashAmount` xALPHA 18-dp;
  the split is off-chain).
- **§7 `:1361-1374`** (`SzipNavOracle` — "Impairment provisions are written immediately downward by the
  `DefaultCoordinator`; recovery writes back up. … the set-once `DefaultCoordinator` is the **sole** provision writer,
  **bounded** (down only by `atRisk × (1 − recoveryFloor)` on a verified default, up only by realized receipts — never
  an arbitrary NAV)". The `recoveryFloor` metric: §7 `:2144` "the day-one conservative provision floor on a default
  (`provision = atRisk × (1−floor)`)").
- **§11** (the loss/default/recovery machinery: the freeze is structural/Exit-Gate-owned and a default does NOT engage
  it; the at-risk amount sizes the markdown NOT the freeze; recovery writes the provision back up; a confirmed
  permanent shortfall settles the provision permanently (pari passu); the xALPHA bond resolves capital-first then the
  in-kind cohort premium; recovery above the debt → originator → homeowner).
- **Locked §17 (do not reopen):** stack = junior → insurance → xALPHA; xALPHA sold only for a realized loss; the
  Duration-Bond premium is in-kind; **no on-chain economic liquidation**; the freeze is **structural, owned by the
  Exit Gate** — this coordinator neither engages nor reads the freeze; the loss is the **marked NAV**, never a
  share-burn / "cut zipUSD supply" lever; immutable Forwarder via renounce.

**Model from (VERIFIED against the repo this window — by inspection)**
- **The CRE-gated receiver shape — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` (the
  exact base `SzipNavOracle` uses).** VERIFIED: `abstract contract ReceiverTemplate is IReceiver, Ownable`; ctor
  `constructor(address _forwarderAddress)` reverts `InvalidForwarderAddress` on zero (`:42-50`); `onReport(bytes
  metadata, bytes report)` checks `msg.sender == s_forwarderAddress` then the optional identity, then calls the
  abstract `_processReport(bytes report)` (`:78-119, :232`); `setExpectedWorkflowId(bytes32)` is `onlyOwner` (`:184`).
  **Inherit it**; implement `_processReport`; the deploy sets the Forwarder (ctor) + identity (`setExpectedWorkflowId`)
  then `renounceOwnership()` to freeze (the immutability seal §4.4/§13). Resolves via `remappings.txt:11`
  (`x402-cre-price-alerts/`).
- **The oracle provision seam — `contracts/src/supply/SzipNavOracle.sol`.** VERIFIED: `writeProvision(uint256
  newProvision)` (`:228-233`) requires `msg.sender == defaultCoordinator` (else `NotDefaultCoordinator`), `_accumulate()`,
  sets `provision = newProvision`, emits `ProvisionWritten`; **the oracle stores it UNBOUNDED by design** (dev comment
  `:29-31`); `setDefaultCoordinator(address)` is set-once `onlyOwner` (`:191-196`). The coordinator calls
  `writeProvision(totalProvision)` after every ledger change. Use a **minimal local `ISzipNavOracle` interface**
  (`function writeProvision(uint256) external;`) — do NOT import the GPL oracle contract for a one-method call (mirror
  the project's interface-not-import pattern). The integration test deploys the REAL oracle.
- **IERC20 source (do NOT grab the wrong one).** Import `IERC20` + `SafeERC20` from **OZ**
  (`@openzeppelin/contracts/token/ERC20/IERC20.sol` + `.../utils/SafeERC20.sol`) and declare `using SafeERC20 for
  IERC20;` — exactly as `LienXAlphaEscrow.sol:4-5`. **NOT** the `forge-std/interfaces/IERC20.sol` that `SzipNavOracle.sol:5`
  uses — that one has no `SafeERC20` binding, so `xAlpha.forceApprove(...)` won't compile against it.
- **The escrow bond seam — `contracts/src/loss/LienXAlphaEscrow.sol` (BUILT-VERIFIED 2026-06-09).** VERIFIED exact
  signatures: `lockXAlpha(bytes32 lienId, address originator, uint256 amount)` (`:111` — pulls `amount` from
  `msg.sender` = the coordinator via `safeTransferFrom`, so **the coordinator must hold xALPHA + have approved the
  escrow**; reverts `BondExists` on a re-lock); `releaseXAlpha(bytes32 lienId)` (`:128` — full bond → recorded
  originator); `slashXAlphaToCapital(bytes32 lienId, uint256 amount)` (`:147` — `amount ≤ bondAmount` else `ExceedsBond`;
  partial leaves the remainder); `slashXAlphaToCohort(bytes32 lienId)` (`:165` — entire remaining → sidecar; reverts
  `NoBond` if 0); `bondAmount(bytes32) view` (`:60`) + `bondOriginator(bytes32) view` (`:62`) public getters. All four
  state-changers are `onlyCoordinator nonReentrant`. Use a **minimal local `ILienXAlphaEscrow` interface** (the four
  state-changers + **both** `bondAmount` and `bondOriginator` views) — the escrow is in-repo but a thin interface keeps
  the coupling loose (project pattern). The integration test deploys the REAL escrow (and may read `escrow.capitalSink()`/
  `escrow.sidecar()`/`escrow.coordinator()` off the concrete type to assert destinations/wiring).
- **`SafeERC20`/`IERC20`** — OZ (`@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol` + `IERC20.sol`), the same
  imports the escrow uses (`LienXAlphaEscrow.sol:4-5`). `forceApprove` the escrow over xALPHA when the escrow is wired.

**Starting state**
- `contracts/src/loss/DefaultCoordinator.sol` exists as a 2-line `.gitkeep` stub (license + `pragma 0.8.24`) — replace it.
- The scaffold (`forge build` green), the OZ + `x402-cre-price-alerts` remaps, and the real `LienXAlphaEscrow` +
  `SzipNavOracle` (+ their tests' `MockERC20`) are all in place. No new shared interface file is strictly required
  (define the two minimal interfaces inline in the coordinator file or as small `contracts/src/interfaces/loss/*.sol`
  files — author's choice; prefer a small `contracts/src/interfaces/loss/ISzipNavOracle.sol` + `ILienXAlphaEscrow.sol`
  for reuse by item-10/CRE).

**Do NOT**
- Do **NOT** add any sweep/rescue/skim, a pause, an unguarded setter, or keep a live governance owner after wiring.
  After `setExpectedWorkflowId` + `setEscrow`, the deploy **renounces** Ownable — the contract is then fully immutable.
  `recoveryFloor` is an **immutable ctor param** (a governed VALUE set at deploy, not a live setter) — there is no
  `setRecoveryFloor`.
- Do **NOT** read or engage the **freeze**, the Exit Gate, the sidecar's cohort membership, any utilization metric, or
  any `lockedFraction` (§6.4/§11 — the freeze is structural and the Exit Gate's; a default does not move it). The
  coordinator writes the markdown + routes the bond, nothing else.
- Do **NOT** recompute the capital-vs-premium **split** on-chain, read any oracle/AMM for it, or size `atRisk` on-chain
  — the CRE passes `atRisk`/`recoveryProceeds`/`capitalSlashAmount` in the report (§13 trust boundary).
- Do **NOT** market-sell xALPHA, mint/burn any share, run any `_realizeMarkdown`/`escrowLoss`/`finalizeLoss`/share-move,
  or write the oracle's NAV directly (only `writeProvision(totalProvision)`). The loss is the **marked NAV**.
- Do **NOT** let the provision write be unbounded — the bound (down ≤ `atRisk×(1−recoveryFloor)`, up ≤ realized
  receipts, floor 0) is THE reason this contract exists (the oracle trusts it for the bound, `SzipNavOracle.sol:29-31`).
- Do **NOT** decrement `totalProvision` in WRITEOFF (the residual is the realized loss — it must persist; a copy-paste
  of the RESOLVE decrement here would silently heal a written-off loss and over-state NAV — security F9). Do **NOT**
  decrement `totalProvision` by any value other than the matching per-lien `provision` change (keeps the sole-writer
  invariant + 0.8.24 underflow-safety). Do **NOT** let RELEASE touch `totalProvision` (a `Bonded` lien's provision is
  always 0 — RELEASE is legal only from `Bonded`).
- Do **NOT** write any coordinator state (`status`/`provision`/`totalProvision`) AFTER the first external
  (`escrow.*`/`navOracle.*`) call in any handler — finalize all ledger writes first (CEI; security F11).
- Do **NOT** import the concrete GPL `SzipNavOracle` for the one `writeProvision` call (use the minimal interface). Do
  follow **CEI** (write the ledger + push the provision logically before/with external calls) **and** rely on the
  base's caller gate — `onReport` is Forwarder-gated, so `_processReport` is only reachable via the trusted Forwarder.
  (No `nonReentrant` needed: every external callee — the escrow (itself `nonReentrant`) and the oracle — is trusted
  in-protocol and the entry is Forwarder-gated; but if you add one it must not break the Forwarder single-entry model.
  Keep state writes before the escrow/oracle calls regardless.)

**Key requirements**
1. **Inheritance + immutables.** `contract DefaultCoordinator is ReceiverTemplate` with `using SafeERC20 for IERC20`.
   Ctor: `constructor(address forwarder, address navOracle_, address xAlpha_, uint256 recoveryFloor_)
   ReceiverTemplate(forwarder)` —
   - `if (navOracle_ == address(0) || xAlpha_ == address(0)) revert ZeroAddress();`
   - `if (recoveryFloor_ >= 1e18) revert InvalidRecoveryFloor();` (a floor ≥ 100% would mean a zero provision forever —
     degenerate; the day-one floor is HIGH but < 1, §7/§17).
   - Store `ISzipNavOracle public immutable navOracle`, `IERC20 public immutable xAlpha`, `uint256 public immutable
     recoveryFloor` (18-dp fraction, `1e18 = 100%`). (The base validates `forwarder != 0`.)
   - **`navOracle` is immutable** (the oracle is deployed BEFORE the coordinator — no circularity). **`escrow` is
     set-once** (the escrow↔coordinator deploy is **circular**: the escrow's ctor needs the coordinator address and
     vice versa — KR-9). Both `recoveryFloor` and the wired addresses are asserted before renounce (item-10).
2. **Set-once `setEscrow(address escrow_) external onlyOwner`** (the escrow-side of the circular dependency):
   `if (address(escrow) != address(0)) revert AlreadyWired(); if (escrow_ == address(0)) revert ZeroAddress();
   escrow = ILienXAlphaEscrow(escrow_); xAlpha.forceApprove(escrow_, type(uint256).max); emit EscrowSet(escrow_);`
   — the `forceApprove` is what lets `lockXAlpha`'s `safeTransferFrom(coordinator, …)` pull succeed (the escrow is
   fully immutable + non-sweepable, so a max allowance to it is safe — it can only pull into its own gated custody).
   Frozen by the deploy-time `renounceOwnership()`. (Mirrors the oracle's set-once-frozen-by-renounce setters,
   `SzipNavOracle.sol:166-196`.)
3. **Per-lien loss ledger + status machine.**
   - `enum LienStatus { None, Bonded, Defaulted, Resolved, WrittenOff }`.
   - `struct LienLoss { LienStatus status; uint256 provision; }` (18-dp USD provision).
   - `mapping(bytes32 lienId => LienLoss) public lienLoss;`
   - `uint256 public totalProvision;` — **`Σ lienLoss[lienId].provision` over ALL liens whose provision is non-zero,
     INCLUDING `WrittenOff` liens** (whose residual provision persists permanently — that residual IS the realized
     loss); `Resolved`/`None`/`Bonded` liens carry provision 0 so are naturally excluded. (Do not think "active set" —
     a written-off lien's markdown stays counted forever.) Pushed to the oracle after every change via
     `navOracle.writeProvision(totalProvision)`. **Sole-writer invariant:** the coordinator is the only `writeProvision`
     caller, and every `totalProvision +=`/`-=` is paired with the identical per-lien `provision` change, so
     `totalProvision == Σ lienLoss.provision == oracle.provision()` holds at all times and no `-=` can underflow.
   - Legal transitions (each illegal source status reverts `BadStatus`): `None→Bonded` (LOCK); `Bonded→None` (RELEASE);
     `Bonded→Defaulted` (DEFAULT); `Defaulted→Defaulted` (RECOVERY, partial heal); `Defaulted→Resolved` (RESOLVE);
     `Defaulted→WrittenOff` (WRITEOFF). RELEASE is the **clean-repay** path (a defaulted lien resolves via RESOLVE/
     WRITEOFF, never RELEASE).
4. **`_processReport(bytes calldata report)` (the dispatcher).**
   - `(uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));`
   - `if (reportType != REPORT_TYPE) revert InvalidReportType(reportType);` (`uint8 public constant REPORT_TYPE = 8;`).
   - `(uint8 action, bytes memory data) = abi.decode(payload, (uint8, bytes));` then branch on `action` (use an
     `enum Action { Lock, Release, Default_, Recovery, Resolve, WriteOff }` = 0..5; revert `InvalidAction(action)`
     for anything ≥ 6). Each branch `abi.decode`s `data` to its sub-tuple (§8.4) and calls the matching internal
     handler below.
5. **LOCK** `data = (bytes32 lienId, address originator, uint256 amount)`:
   - `if (lienLoss[lienId].status != LienStatus.None) revert BadStatus();`
   - `lienLoss[lienId].status = LienStatus.Bonded;`
   - `escrow.lockXAlpha(lienId, originator, amount);` (the escrow validates originator/amount/no-clobber + pulls
     `amount` xALPHA from this coordinator — which must hold it + has the max approval from `setEscrow`).
   - `emit BondLocked(lienId, originator, amount);` (the escrow also emits its own `Locked`).
6. **RELEASE** `data = (bytes32 lienId)` (M1-live clean repay):
   - `if (lienLoss[lienId].status != LienStatus.Bonded) revert BadStatus();`
   - `lienLoss[lienId].status = LienStatus.None;` (and `delete lienLoss[lienId]` is equivalent — provision is already 0).
   - `escrow.releaseXAlpha(lienId);` `emit BondReleased(lienId);`
7. **DEFAULT** `data = (bytes32 lienId, uint256 atRisk)` (recognition; M2):
   - `if (lienLoss[lienId].status != LienStatus.Bonded) revert BadStatus();`
   - `if (atRisk == 0) revert ZeroAtRisk();`
   - **The bound (down):** `uint256 p = atRisk * (1e18 - recoveryFloor) / 1e18;` set `lienLoss[lienId].provision = p;
     lienLoss[lienId].status = LienStatus.Defaulted; totalProvision += p;` then `navOracle.writeProvision(totalProvision);`
   - `emit Defaulted(lienId, atRisk, p);`
8. **RECOVERY** `data = (bytes32 lienId, uint256 recoveryProceeds)` (partial heal; M2):
   - `if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();`
   - **The bound (up only by realized receipts):** `uint256 cur = lienLoss[lienId].provision; uint256 reduction =
     recoveryProceeds >= cur ? cur : recoveryProceeds; lienLoss[lienId].provision = cur - reduction; totalProvision -=
     reduction;` then `navOracle.writeProvision(totalProvision);` (provision floors at 0 — a recovery can never write
     NAV *above* the un-impaired basket).
   - `emit Recovered(lienId, recoveryProceeds, lienLoss[lienId].provision);`
9. **RESOLVE** `data = (bytes32 lienId, uint256 capitalSlashAmount)` (clean resolution; M2):
   - `if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();`
   - **Heal the provision to 0:** `totalProvision -= lienLoss[lienId].provision; lienLoss[lienId].provision = 0;
     lienLoss[lienId].status = LienStatus.Resolved;` then `navOracle.writeProvision(totalProvision);`
   - **Route the bond (capital-first, then cohort):** `if (capitalSlashAmount != 0) escrow.slashXAlphaToCapital(lienId,
     capitalSlashAmount);` then `if (escrow.bondAmount(lienId) != 0) escrow.slashXAlphaToCohort(lienId);` (read the
     escrow's remaining bond to decide whether to call cohort — skip iff a full-bond capital slash already cleared it,
     which would otherwise revert `NoBond`). `emit Resolved(lienId, capitalSlashAmount);`
10. **WRITEOFF** `data = (bytes32 lienId, uint256 capitalSlashAmount)` (confirmed permanent shortfall; M2):
    - `if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();`
    - **Settle the provision permanently:** leave `lienLoss[lienId].provision` **unchanged** (the residual IS the
      realized loss; `totalProvision` already carries it), set `lienLoss[lienId].status = LienStatus.WrittenOff;` (no
      further RECOVERY/RESOLVE accepted — only `Defaulted` is a legal source). Do **not** call `writeProvision` (no
      change). The senior is made whole off the junior's basket + the slashed bond (§11).
    - **Route the bond** exactly as RESOLVE (`slashXAlphaToCapital` if `>0`, then `slashXAlphaToCohort` if remaining).
      `emit WrittenOff(lienId, capitalSlashAmount);`
11. **Provision-bound invariant (the security thesis — tested):** for any lien, the cumulative downward write equals
    `atRisk × (1 − recoveryFloor)` at recognition and only ever decreases thereafter (recovery) or stays (writeoff);
    `totalProvision == Σ lienLoss[lienId].provision == oracle.provision()` at all times (the coordinator is the sole
    writer). There is **no path that increases a lien's provision after recognition** — so `totalProvision` can never
    exceed the independent ghost sum of recognized `atRisk×(1−floor)` markdowns, and (because recovery floors at 0)
    the oracle's NAV can never be written **above** the un-impaired basket. The truncating `atRisk*(1e18-floor)/1e18`
    rounds **down** (favorable — never over-marks). Verify with an **independent** ghost cap (sum the recognized
    `atRisk*(1e18-floor)/1e18` in the invariant handler and assert `totalProvision <= ghost_cap`), **not** by
    recomputing the formula in the assert (that would be tautological — qa).
12. **Residual-trust NatSpec block (REQUIRED, verbatim-equivalent at the top of the contract — the §13 boundary, stated
    plainly so it is never mistaken for a solvency guard):**
    > This contract **bounds and routes**; it does NOT validate that a default is real. Under §13 the CRE (DON-consensus,
    > behind the immutable Forwarder + renounce-frozen workflow identity) is trusted for: the **magnitude** of
    > `atRisk`/`recoveryProceeds`/`capitalSlashAmount`, the **timing** of each action, the capital-vs-premium **split**,
    > and the **`originator`** address (which becomes the RELEASE recipient). The on-chain guarantees are narrow and
    > exact: (a) a provision is written down only by `atRisk×(1−recoveryFloor)` at recognition and up only by realized
    > receipts, floored at 0 — **never an arbitrary NAV, never above the un-impaired basket**; (b) `totalProvision ==
    > Σ lienLoss.provision == oracle.provision()` at all times (sole writer); (c) every bond can flow only to
    > `bondOriginator` / immutable `capitalSink` / immutable `sidecar` — **no attacker-chosen destination except the
    > CRE-named originator leg**; (d) the status machine forbids re-recognition, post-resolution heal, and release of a
    > defaulted lien. A compromised CRE can **grief** (down-mark NAV — making concurrent exiters exit-poor since
    > `writeProvision` is immediate/unsmoothed; slash a healthy bond; reclaim a freshly-funded bond via a hostile
    > `originator`) but **cannot steal to an arbitrary address or inflate NAV**. The contract is **non-sweepable**
    > (over-funding is a permanent accepted loss — fund exactly `amount` just-in-time) and **fully immutable after
    > renounce** (no owner, no pause, no setter). The MAX xALPHA allowance is granted only to the immutable,
    > non-sweepable, `onlyCoordinator` escrow whose sole pull path is this contract's own LOCK.
13. **Events:** `EscrowSet(address indexed escrow)`, `BondLocked(bytes32 indexed lienId, address indexed originator,
    uint256 amount)`, `BondReleased(bytes32 indexed lienId)`, `Defaulted(bytes32 indexed lienId, uint256 atRisk,
    uint256 provision)`, `Recovered(bytes32 indexed lienId, uint256 recoveryProceeds, uint256 remainingProvision)`,
    `Resolved(bytes32 indexed lienId, uint256 capitalSlashAmount)`, `WrittenOff(bytes32 indexed lienId, uint256
    capitalSlashAmount)`. (The escrow emits its own `Locked`/`Released`/`SlashedTo*`; the oracle emits `ProvisionWritten`.)
14. **Custom errors** (no string reverts): `ZeroAddress`, `InvalidRecoveryFloor`, `AlreadyWired`, `InvalidReportType(uint8)`,
    `InvalidAction(uint8)`, `BadStatus`, `ZeroAtRisk`. Pragma **`0.8.24`**. (Authority + identity errors come from the
    `ReceiverTemplate` base: `InvalidSender`, `InvalidWorkflowId`, etc.)
15. **The circular-deploy contract is the set-once `setEscrow`** (KR-2). It removes any need for CREATE2 precompute in
    the contract; item-10 deploys: oracle → coordinator (navOracle immutable, escrow unset) → escrow (coordinator =
    this coordinator) → `coordinator.setEscrow(escrow)` → `oracle.setDefaultCoordinator(coordinator)` → set identity →
    assert wiring → renounce both. (Recorded as an item-10 obligation below.)

**Done when**
`forge build` green + `forge test --match-contract DefaultCoordinator` green + the **full suite has no regression**
(`forge test`). Test fixtures (mirror `LienXAlphaEscrow.t.sol` idioms):
- xALPHA = local `MockERC20(18)` (ctor `(uint8 d)`, open `mint`).
- **`MockNavOracle` for the UNIT suite** (the real oracle is for the integration test only): `contract MockNavOracle {
  uint256 public provision; event ProvisionWritten(uint256 provision); function writeProvision(uint256 p) external {
  provision = p; emit ProvisionWritten(p); } }` — an **ungated** `writeProvision` + public `provision()` so the unit
  tests can both let the coordinator write and read the value back. **It MUST `emit ProvisionWritten(p)`** (build-exposed):
  the DEFAULT/RECOVERY/RESOLVE co-emit assertions + the WRITEOFF no-co-emit assertion are otherwise untestable. (The
  coordinator's minimal `ISzipNavOracle` interface has only `writeProvision`; assertions read `oracle.provision()` off
  the mock's concrete type.)
- **Asserting a NON-emit (the WRITEOFF "no `ProvisionWritten`" check):** `vm.expectEmit` cannot assert absence — use
  `vm.recordLogs()` + scan the returned `Vm.Log[]` for the `ProvisionWritten` topic and assert it is absent (requires
  `import {Vm} from "forge-std/Vm.sol";` for the `Vm.Log` type — not in `Test.sol`'s default surface).
- Drive via `vm.prank(forwarder); coordinator.onReport("", report)` per `SzipNavOracle.t.sol:145-146` (empty metadata
  passes while identity is unset — verified against `ReceiverTemplate.sol:88`). Renounce **only** in the immutability-
  negative test (LOCK still works post-renounce since `onReport` is Forwarder-gated, not owner-gated).
- Use `vm.expectEmit(true, true, true, true, address(coordinator))` for the coordinator's events; assert both indexed
  topics of `BondLocked`/`Defaulted`, and assert the oracle's `ProvisionWritten(expected)` co-emits on DEFAULT/RECOVERY/
  RESOLVE (and does NOT on WRITEOFF/RELEASE).

Tests:
- **ctor:** rejects `navOracle == 0` / `xAlpha == 0` (`ZeroAddress`), `recoveryFloor >= 1e18` (`InvalidRecoveryFloor`),
  `forwarder == 0` (base `InvalidForwarderAddress`); **accepts `recoveryFloor == 0` and `recoveryFloor == 1e18 - 1`**
  (the legal boundary); stores `navOracle`/`xAlpha`/`recoveryFloor` (getters).
- **setEscrow:** set-once (second call → `AlreadyWired`); zero → `ZeroAddress`; non-owner → `OwnableUnauthorizedAccount`;
  after set, `xAlpha.allowance(coordinator, escrow) == type(uint256).max`; **frozen by renounce** (a `setEscrow` after
  `renounceOwnership()` reverts `OwnableUnauthorizedAccount`).
- **onReport authority:** non-Forwarder caller → base `InvalidSender`; with `setExpectedWorkflowId(id)` set, a report
  with a mismatched metadata workflowId → `InvalidWorkflowId` (mirror the controller/oracle identity test); empty
  metadata passes when identity is unset.
- **dispatch negatives:** `reportType != 8` → `InvalidReportType`; `action >= 6` → `InvalidAction`.
- **LOCK (happy):** fund the coordinator with xALPHA, `setEscrow`; a LOCK report drives `escrow.lockXAlpha` (escrow
  `+amount`, coordinator `−amount`); `escrow.bondAmount(lienId) == amount`; `escrow.bondOriginator(lienId) == originator`;
  `lienLoss[lienId].status == Bonded`; `expectEmit` `BondLocked` (+ the escrow's `Locked`). **LOCK negatives:** re-LOCK a
  Bonded lien → `BadStatus`; LOCK a Defaulted lien → `BadStatus`; LOCK with the coordinator un-funded → the escrow's
  pull reverts (and the whole report reverts — no orphaned status: `lienLoss[lienId].status == None` after).
- **RELEASE (happy + negatives):** `LOCK → RELEASE` returns the full bond to the originator, `escrow.bondAmount == 0`,
  `status == None`; `expectEmit` `BondReleased`. RELEASE a never-bonded lien → `BadStatus`; RELEASE a Defaulted lien →
  `BadStatus` (must resolve, not release).
- **DEFAULT (the bound, happy + boundaries + negatives):** `LOCK → DEFAULT(atRisk)` sets `lienLoss.provision ==
  atRisk*(1e18−floor)/1e18`, `status == Defaulted`, `totalProvision == that`, oracle `provision() == totalProvision`,
  `expectEmit` `Defaulted` + the oracle's `ProvisionWritten`. Boundaries: HIGH floor `0.9e18` → `provision == atRisk/10`;
  `floor == 0` → `provision == atRisk`; **truncation pin** `atRisk == 3, floor == 0.5e18` → `provision == 1` (proves
  round-DOWN / under-provision); **`floor == 1e18-1` with small `atRisk` (e.g. `1e17`)** → `provision == 0`, status
  still `Defaulted`, `totalProvision == 0`, oracle `provision() == 0` (a zero-result DEFAULT must NOT revert — only
  `atRisk == 0` reverts). Negatives: DEFAULT a non-Bonded lien → `BadStatus`; DEFAULT twice (`Defaulted` source) →
  `BadStatus`; `atRisk == 0` → `ZeroAtRisk`. **Replay:** re-submitting an identical DEFAULT report → `BadStatus` (the
  status guard is the replay defense — no nonce).
- **RECOVERY (up only by realized receipts):** `DEFAULT(atRisk) → RECOVERY(proceeds)` reduces provision by
  `min(provision, proceeds)`; **status stays `Defaulted`** (assert it — RECOVERY never transitions status);
  `proceeds == provision` boundary → exactly 0; `proceeds > provision` → floors at 0 (never negative/below); a
  **second RECOVERY on the now-0 provision is a no-op** (no underflow, still emits); multiple RECOVERY reports
  accumulate down to 0. Negative: RECOVERY a non-Defaulted lien (None/Bonded/Resolved/WrittenOff source) → `BadStatus`.
- **RESOLVE (heal + the ordered slash):** `LOCK(B) → DEFAULT → RESOLVE(part)`: provision → 0 (`totalProvision`
  decremented, oracle updated), `status == Resolved`; the bond routes `part` to `capitalSink` and `B−part` to `sidecar`
  (assert the `SlashedToCohort` emitted amount == `B−part`), escrow net 0; `expectEmit` `Resolved`. **Pure-premium
  path:** `RESOLVE(0)` routes the **whole** bond to `sidecar`. **Full-bond capital path:** `RESOLVE(B)` slashes all to
  `capitalSink` and **skips cohort** (no `NoBond` revert — the coordinator reads `bondAmount==0`). Negatives: RESOLVE a
  non-Defaulted lien → `BadStatus`; **RESOLVE after RESOLVE** → `BadStatus`. **Atomic-rollback:** `capitalSlashAmount > B`
  → the escrow reverts `ExceedsBond` and the **whole report reverts** — assert `oracle.provision()`,
  `coordinator.totalProvision()`, and `lienLoss[lienId].status` are all **unchanged** from the pre-RESOLVE `Defaulted`
  value (the provision write — which ran before the slash — must roll back with the revert; this is the one real
  atomicity proof, qa #10).
- **WRITEOFF (settle permanently + slash, FULL parity with RESOLVE):** `LOCK(B) → DEFAULT(atRisk) → WRITEOFF(part)`:
  provision **unchanged** (`totalProvision` still carries the residual; oracle `provision()` unchanged — assert NO
  `ProvisionWritten` co-emits), `status == WrittenOff`; the bond routes `part`→capital, `B−part`→cohort. **`WRITEOFF(B)`
  skips cohort; `WRITEOFF(0)` whole-to-cohort; `capitalSlashAmount > B` bubbles `ExceedsBond`** (whole report reverts,
  state unchanged — same atomic-rollback assertion as RESOLVE). A later RECOVERY/RESOLVE/WRITEOFF/RELEASE on the
  written-off lien → `BadStatus` (terminal).
- **full illegal-transition matrix (table-driven):** from each of the 5 statuses {None, Bonded, Defaulted, Resolved,
  WrittenOff} attempt all 6 actions; assert exactly the legal ones pass (None→LOCK; Bonded→{RELEASE, DEFAULT};
  Defaulted→{RECOVERY, RESOLVE, WRITEOFF}) and every other source→action reverts `BadStatus`. Explicitly include
  **LOCK on Resolved/WrittenOff → `BadStatus`** (the escrow's `bondAmount==0` would otherwise ALLOW a re-lock; the
  coordinator's terminal-status guard is the only thing blocking it — qa #7).
- **LOCK un-funded rollback:** LOCK with the coordinator un-funded → the escrow's pull reverts, the whole report
  reverts; assert `lienLoss[lienId].status == None` AND `escrow.bondAmount(lienId) == 0` (no orphan), and that a
  **subsequent funded LOCK of the same lienId then succeeds** (no sticky orphan).
- **multi-lien independence + full unwind:** liens A, B; `DEFAULT(A)` then `DEFAULT(B)` → `totalProvision == pA + pB`;
  `RESOLVE(A)` heals only A (`totalProvision == pB`, B untouched); then `RESOLVE(B)` → `totalProvision == 0` exactly
  (no underflow, no dust); the oracle tracks every step.
- **integration (real oracle + real escrow, no collaborator mocks):** deploy the real `SzipNavOracle` with the **full
  11-arg ctor** `(forwarder, zipUSD, usdc, xAlpha, hydx, oHydx, mainSafe, sidecar, W, maxAge, maxDeviationBps)` — 5
  `MockERC20` token slots + 2 `makeAddr` Safes + a `makeAddr` forwarder + `W = 4 hours, maxAge = 1 hours,
  maxDeviationBps = 1000` (mirror `SzipNavOracle.t.sol` setUp); **do NOT wire the basket / `setShareToken`** — at zero
  effective supply `writeProvision`'s `_accumulate()` is fine (`spotNavPerShare` returns `GENESIS_NAV`, no basket read
  needed). Deploy the real `LienXAlphaEscrow` (escrow `coordinator =` this coordinator; `makeAddr` capitalSink/sidecar).
  Wire `oracle.setDefaultCoordinator(coordinator)` + `coordinator.setEscrow(escrow)`. Run a full `LOCK → DEFAULT →
  RECOVERY → RESOLVE` and assert the real `oracle.provision()` tracks `coordinator.totalProvision()` at every step and
  the real `escrow.bondAmount`/destinations (`escrow.capitalSink()`/`escrow.sidecar()` balances) move correctly.
  **Gate negatives:** a direct `oracle.writeProvision(x)` from a non-coordinator EOA reverts `NotDefaultCoordinator`,
  and a direct `escrow.lockXAlpha(...)` from a non-coordinator reverts `NotCoordinator` (proves the wiring is
  exclusive, not just functional).
- **non-sweepable / immutable / no-freeze ABI-negative:** low-level `call` each forbidden selector (`sweep(address,
  uint256)`, `rescue(address,uint256)`, `setRecoveryFloor(uint256)`, `setNavOracle(address)`, `setCoordinator(address)`,
  **`freeze()`, `lockedFraction()`, `engageFreeze()`, `setExitGate(address)`** — the freeze-engagement negatives that
  make "does not engage the freeze" verifiable) and assert `!success`; assert a second `setEscrow` and any owner-only
  call revert after `renounceOwnership()` (mirrors `LienXAlphaEscrow.t.sol` / `ZipRedemptionQueue.t.sol` negatives).
- **stateful invariant handler (mirror `LienXAlphaEscrow.t.sol`'s `EscrowHandler`):** a handler driving LOCK/RELEASE/
  DEFAULT/RECOVERY/RESOLVE/WRITEOFF over a small fixed lienId set (with the deploy-cycle break trick the escrow handler
  uses) against the `MockNavOracle` + real escrow, maintaining an **independent ghost** `ghost_cap = Σ recognized
  atRisk*(1e18-floor)/1e18`. Invariants: (i) `totalProvision == Σ lienLoss[lienId].provision` over touched liens;
  (ii) `oracle.provision() == totalProvision`; (iii) `totalProvision <= ghost_cap` (the security thesis — an
  **independent** cap, NOT a re-computation of the formula in the assert); (iv) the handler never reverts on a legal
  sequence (proves `totalProvision` never underflows). Over ≥128k calls.
- **provision-bound fuzz:** over fuzzed `(atRisk, recoveryProceeds, recoveryFloor < 1e18)` bounded to the mock supply,
  assert after any `DEFAULT (+ RECOVERY*)` that `lienLoss.provision <= atRisk` (the true economic cap — NOT the
  formula re-applied) and `totalProvision == Σ lienLoss.provision == oracle.provision()`.

Integration-layer mapping (for item-10 / M2, **not** built here — record below): the LOCK/RELEASE path joins `audit/2.md`
Phase S (launch bonding) alongside the escrow's; the DEFAULT/RECOVERY/RESOLVE/WRITEOFF path joins the M2 default trace.

**Depends on**
- The scaffold (WOOF-00 — `forge build` green, OZ + `x402-cre-price-alerts` remaps, the `contracts/test` `MockERC20`).
- The **real `LienXAlphaEscrow`** (8-Bx, BUILT-VERIFIED 2026-06-09) — the bond seam (interface-only coupling).
- The **real `SzipNavOracle`** (BUILT-VERIFIED 2026-06-07) — the `writeProvision`/`setDefaultCoordinator` seam
  (interface-only coupling). Both are in-repo; no fork.

**Cross-ticket obligations this item DISCHARGES** (mark `DISCHARGED` in PROGRESS at Conclude):
- **`DefaultCoordinator` · provision bound** (owed to `SzipNavOracle`, PROGRESS row "provision bound") — the coordinator
  is the sole `writeProvision` caller and enforces down ≤ `atRisk×(1−recoveryFloor)`, up ≤ realized receipts, floor 0.
- **`DefaultCoordinator` · slash split-policy + driver** (owed to 8-Bx, PROGRESS row) — the coordinator IS
  `LienXAlphaEscrow.coordinator`, drives `slashXAlphaToCapital(part)` then `slashXAlphaToCohort()` (RESOLVE/WRITEOFF) and
  `releaseXAlpha` (clean RELEASE); the split is off-chain, the escrow enforces only `amount ≤ bond`.

**Cross-ticket obligations this item CREATES** (record in PROGRESS at Conclude — discharged by item-10 / CRE later):
- **Item 10 (deploy/wiring) — the renounce gate is a HARD tested `require`, not prose (security F1/F2/F3, HIGH).** The
  escrow↔coordinator deploy is **circular**: deploy oracle → coordinator (navOracle immutable, escrow unset) → escrow
  (`coordinator =` this coordinator) → `coordinator.setEscrow(escrow)` → `oracle.setDefaultCoordinator(coordinator)` →
  `coordinator.setExpectedWorkflowId(id)`. **Then, in the SAME deploy script and BEFORE either `renounceOwnership()`,
  `require` ALL of:** `escrow.coordinator() == coordinator` AND `coordinator.escrow() == escrow` (two-way, so the MAX
  approval landed on the verified escrow, not a hostile address — F12); `oracle.defaultCoordinator() == coordinator`;
  `coordinator.navOracle() == oracle`; `coordinator.getForwarderAddress() == the intended Forwarder`;
  **`coordinator.getExpectedWorkflowId() != 0`** (else the contract is sealed "Forwarder-gated but workflow-blind" —
  any workflow on the shared DON could drive reportType-8 actions, F1); `recoveryFloor` is the governed value;
  `xAlpha.allowance(coordinator, escrow) == type(uint256).max`. Only then **renounce** both the coordinator and the
  oracle (freezing the Forwarder + identity + set-once wiring) — in the same script, never as a deferred "renounce
  later" step (F2/F3). Use a **distinct Forwarder identity/workflowId** from the controller/registry/oracle. Two bricking
  failure modes to guard against: renounce-before-`setEscrow` bricks BOTH the coordinator and the (immutable-coordinator)
  escrow; renounce-before-`setExpectedWorkflowId` opens the workflow-blind grief surface.
- **Item 10 / operational (xALPHA funding discipline):** the coordinator holds the launch xALPHA reserve and is
  **non-sweepable** — over-funding leaves xALPHA permanently stuck. The CRE/treasury MUST transfer **exactly** each
  bond's `amount` to the coordinator immediately before its LOCK report (no standing reserve), and the wired `xAlpha`
  MUST be **non-fee-on-transfer / non-rebasing** (inherits the escrow's load-bearing feeless assumption — the coordinator
  has no balance-delta defense). Mirror the escrow's "terminalize every locked lien" obligation: a bond locked against a
  coordinator with no live successor CRE is stuck.
- **CRE track (§8.4):** the workflow computes `atRisk` (from the §4.1 deviation re-mark + outstanding debt), the
  `recoveryProceeds` staircase, and the capital-vs-premium `capitalSlashAmount` off-chain, and emits the reportType-8
  action family to the coordinator (a **distinct** workflow identity). The default DEMO is the M2 milestone (§15).
- **Item 10 / engine-integration audit sweep:** author the LOCK/RELEASE into `audit/2.md` Phase S and the
  DEFAULT→RECOVERY→RESOLVE/WRITEOFF into the M2 default trace (+ the matching `audit/3-results.md` authority rows:
  Forwarder-only `onReport`, the provision bound, the escrow `onlyCoordinator` gate, renounce-frozen identity + wiring),
  deferred to item-10/M2 like the escrow's (not authorable against an un-wired system).
- **`SzipNavOracle` / §12 (already logged by 8-Bx):** the sidecar's xALPHA leg (grown by `slashXAlphaToCohort` on
  RESOLVE/WRITEOFF) must be in the NAV basket read so the in-kind premium accretes the frozen cohort pari passu (the
  oracle already reads sidecar balances, §7); confirm at item-10.
