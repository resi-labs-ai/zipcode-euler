# interfaces-loss — `contracts/src/interfaces/loss/` (wiring map)

> **X-Ray (trust surface):** internal seams (intra-protocol coupling, lower attack value), not external trust.
> Trust map: `contracts/src/interfaces/x-ray/dependency-surface.md`; overview: `docs/interfaces/dependency-surface.md`.

> Source of truth = the kept code. These are the two **internal-seam** faces the loss-side consumer
> (`DefaultCoordinator.sol`) holds of in-repo contracts it deliberately does NOT import. Signatures below
> are read straight off the `.sol` files.

## Role
Two narrow `interface`-not-import seams. Both shim **in-repo** Zipcode contracts (not external/forked
protocols): the coordinator drives `LienXAlphaEscrow.sol` (xALPHA bond lifecycle) and `SzipNavOracle.sol`
(impairment provision sink) through thin faces so the loss orchestrator does not compile-depend on the full
escrow/NAV machinery. Loose-coupling pattern; both are Timelock-re-pointable at the consumer.

---

## ILienXAlphaEscrow.sol
**Shims** (internal-seam): the bond seam `DefaultCoordinator` drives. Concrete implementer =
`contracts/src/supply/szipUSD/.../LienXAlphaEscrow.sol` (kept in-repo; signatures BUILT-VERIFIED 2026-06-09
against `:111/:128/:147/:165/:60/:62`). Four `onlyCoordinator` state-changers + two bond views.

**Declared surface** (exact):
```solidity
function lockXAlpha(bytes32 lienId, address originator, uint256 amount) external;
function releaseXAlpha(bytes32 lienId) external;
function slashXAlphaToCapital(bytes32 lienId, uint256 amount) external;
function slashXAlphaToCohort(bytes32 lienId) external;
function bondAmount(bytes32 lienId) external view returns (uint256);
function bondOriginator(bytes32 lienId) external view returns (address);
```
No events, no errors on the seam (they live on the concrete impl).

**Consumed by:** `contracts/src/loss/DefaultCoordinator.sol` (sole consumer) — `escrow` is
`ILienXAlphaEscrow public escrow;` (`:97`), re-pointed via the `onlyOwner`/Timelock `setEscrow` (`:142`);
`escrow.lockXAlpha` (`:208`), `escrow.releaseXAlpha` (`:221`), and the two `slashXAlphaTo*` in the
capital/cohort routing paths.

**Gotchas:**
- Narrow face, not the full escrow contract — only the 4 coordinator-callable mutators + 2 views are exposed;
  the escrow's own admin/state surface is intentionally invisible here.
- **Destination-integrity by construction:** `slashXAlphaToCapital`/`slashXAlphaToCohort` and the
  `lock`/`release` take **no recipient parameter** — the bond can flow only to the escrow-recorded
  `bondOriginator` / capital / cohort sinks; the coordinator cannot redirect it to an arbitrary address.
- `lockXAlpha`'s `safeTransferFrom(coordinator, …)` pull requires the coordinator hold + approve the xALPHA
  allowance (noted at `setEscrow`, `:136`) — a wiring precondition, not visible on the seam.

---

## ISzipNavOracle.sol
**Shims** (internal-seam): the minimal provision-writer seam. Concrete implementer =
`contracts/src/supply/SzipNavOracle.sol:228` (full NAV machinery; GPL). The coordinator must not depend on
that machinery for a one-method call, so the seam exposes a single mutator.

**Declared surface** (exact):
```solidity
function writeProvision(uint256 newProvision) external;
```

**Consumed by:** `contracts/src/loss/DefaultCoordinator.sol` (sole consumer) — `navOracle` is
`ISzipNavOracle public navOracle;` (`:86`), set at construction (`:129`) and re-pointed via Timelock
`setNavOracle` (`:150`); `navOracle.writeProvision(totalProvision)` pushed after every provision change
(`:240`, `:258`).

**Gotchas:**
- **`provision` is NOT on this seam.** The interface declares only `writeProvision`. The concrete oracle's
  `provision()` public getter is read directly off `SzipNavOracle`, not through `ISzipNavOracle`; the seam is
  a pure write face.
- **Bound is the consumer's job, not the oracle's.** `SzipNavOracle.writeProvision` stores `newProvision`
  **UNBOUNDED** (`:249`); it only gates `msg.sender == defaultCoordinator` (`:247`, reverting
  `NotDefaultCoordinator`). The down-bound (`atRisk×(1−recoveryFloor)`) and up-only-by-realized-receipts
  bound are enforced in `DefaultCoordinator` (`:227`, `:247`) before the value is pushed.
- Sole-writer invariant: `totalProvision == Σ lienLoss.provision == oracle.provision()` holds only because
  the coordinator is the single `writeProvision` caller; zero `defaultCoordinator` ⇒ `writeProvision` reverts
  for everyone (fail-closed), verified by the item-10 deploy wiring before Timelock hand-off.
