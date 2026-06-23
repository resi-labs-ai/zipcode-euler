// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISzipNavOracle} from "../interfaces/loss/ISzipNavOracle.sol";
import {ILienXAlphaEscrow} from "../interfaces/loss/ILienXAlphaEscrow.sol";

/// @title DefaultCoordinator — the loss-side orchestrator (NAV provision writer + xALPHA bond router)
/// @notice The single loss-side orchestrator: the immutable `LienXAlphaEscrow.coordinator` (owns the full xALPHA
///         bond lifecycle) AND the set-once `SzipNavOracle.defaultCoordinator` (the sole `writeProvision` caller).
///         A CRE-gated `ReceiverTemplate`: every action flows through `_processReport` (reportType 8,
///         action-discriminated, §4.4/§8.4) gated by the Timelock-pinned Forwarder. Ownership is TRANSFERRED to the
///         Timelock at deploy (NOT renounced — the same admin that owns the engine Zodiac modules' CRE flows,
///         user-directed 2026-06-09): the owner governs `recoveryFloor` (`setRecoveryFloor`) and may redirect the
///         CRE Forwarder/workflow identity in an emergency, but holds no theft / NAV-inflation power. It custodies
///         the protocol's launch xALPHA reserve; non-sweepable; the escrow is wired via a Timelock-re-pointable
///         `setEscrow` (§17 build phase — NOT set-once; see `setEscrow` below).
///         `claude-zipcode.md` §4.6 / §11 / §7 / §8.4 / §17.
///
/// @dev RESIDUAL-TRUST BOUNDARY (§13 — stated plainly so it is never mistaken for a solvency guard):
///      This contract BOUNDS and ROUTES; it does NOT validate that a default is real. Under §13 the CRE
///      (DON-consensus, behind the Forwarder + the Timelock-pinned workflow identity) is trusted for: the
///      MAGNITUDE of `atRisk`/`recoveryProceeds`/`capitalSlashAmount`, the TIMING of each action, the
///      capital-vs-premium SPLIT, and the `originator` address (which becomes the RELEASE recipient). The
///      on-chain guarantees are narrow and exact: (a) a provision is written down only by
///      `atRisk×(1−recoveryFloor)` at recognition and heals up only by realized receipts (`_recovery`, partial) OR
///      fully to 0 on terminal clean resolution (`_resolve`, the ratified §8.4 — NOT a fresh receipt, the whole
///      residual is cleared); floored at 0 — never an arbitrary NAV, never above the un-impaired basket. (A
///      WRITEOFF leaves the residual provision IN PLACE — it is the realized loss — and never calls
///      `writeProvision`.) (b) `totalProvision == Σ lienLoss.provision ==
///      oracle.provision()` at all times (sole writer); (c) every bond can flow only to `bondOriginator` /
///      immutable `adminSafe` / immutable `juniorTrancheSafe` — no attacker-chosen destination except the CRE-named
///      originator leg; (d) the status machine forbids re-recognition, post-resolution heal, and release of a
///      defaulted lien. A compromised CRE can GRIEF (down-mark NAV — making concurrent exiters exit-poor since
///      `writeProvision` is immediate/unsmoothed; slash a healthy bond; reclaim a freshly-funded bond via a
///      hostile `originator`) but CANNOT steal to an arbitrary address or inflate NAV. The contract is
///      non-sweepable (over-funding is a permanent accepted loss — fund exactly `amount` just-in-time) and
///      Timelock-owned (the owner governs `recoveryFloor` + the CRE Forwarder/workflow identity; no sweep, no
///      pause; the owner cannot redirect bond destinations or inflate NAV — those bounds hold against the owner
///      too). The MAX xALPHA allowance is granted only to the immutable, non-sweepable, `onlyCoordinator` escrow
///      whose sole pull path is this contract's own LOCK.
contract DefaultCoordinator is ReceiverTemplate {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- constants
    /// @notice The §4.4 reportType this coordinator services (the loss-action family).
    uint8 public constant REPORT_TYPE = 8;

    /// @notice The §8.4 action family carried in a reportType-8 payload.
    enum Action {
        Lock, // 0
        Release, // 1
        Default_, // 2
        Recovery, // 3
        Resolve, // 4
        WriteOff // 5

    }

    // --------------------------------------------------------------------- per-lien loss ledger
    /// @notice The per-lien loss status machine.
    enum LienStatus {
        None,
        Bonded,
        Defaulted,
        Resolved,
        WrittenOff
    }

    /// @notice Per-lien loss record: status + the 18-dp USD impairment provision.
    struct LienLoss {
        LienStatus status;
        uint256 provision;
    }

    /// @notice The per-lien loss ledger.
    mapping(bytes32 lienId => LienLoss) public lienLoss;

    /// @notice `Σ lienLoss[lienId].provision` over ALL liens carrying a non-zero provision — INCLUDING WrittenOff
    ///         liens (whose residual provision persists permanently — that residual IS the realized loss). Pushed
    ///         to the oracle after every change via `navOracle.writeProvision(totalProvision)`.
    uint256 public totalProvision;

    // --------------------------------------------------------------------- immutables / set-once wiring
    // NOTE (2026-06-09, §17): wiring below is Timelock-settable, NOT immutable — build-phase flexibility so a
    // redeployed oracle/escrow is a one-call re-point, not a redeploy cascade. Lock down pre-production.
    /// @notice The NAV oracle (sole provision sink). Timelock-settable.
    ISzipNavOracle public navOracle;
    /// @notice The bond asset (bridged xALPHA / `SzAlphaMirror`; a generic ERC-20 in M1 tests). Timelock-settable.
    IERC20 public xAlpha;
    /// @notice The conservative provision floor on a default (18-dp fraction, `1e18 = 100%`): a default marks down
    ///         `atRisk × (1 − recoveryFloor)`. A governed VALUE — the Timelock owner may update it via
    ///         `setRecoveryFloor` (ownership is transferred to the Timelock at deploy, NOT renounced — the same
    ///         admin that owns the engine Zodiac modules' CRE flows, user-directed 2026-06-09).
    uint256 public recoveryFloor;

    /// @notice The xALPHA bond escrow this coordinator drives. Wired post-deploy (the escrow↔coordinator deploy is
    ///         circular); re-pointable by the Timelock owner via `setEscrow` (§17 build phase — NOT renounce-frozen).
    ILienXAlphaEscrow public escrow;

    // --------------------------------------------------------------------- errors (no string reverts)
    error ZeroAddress();
    error InvalidRecoveryFloor();
    error InvalidReportType(uint8 reportType);
    error InvalidAction(uint8 action);
    error BadStatus();
    error ZeroAtRisk();

    // --------------------------------------------------------------------- events
    event EscrowSet(address indexed escrow);
    event NavOracleSet(address indexed navOracle);
    event XAlphaSet(address indexed xAlpha);
    event RecoveryFloorSet(uint256 oldFloor, uint256 newFloor);
    event BondLocked(bytes32 indexed lienId, address indexed originator, uint256 amount);
    event BondReleased(bytes32 indexed lienId);
    event Defaulted(bytes32 indexed lienId, uint256 atRisk, uint256 provision);
    event Recovered(bytes32 indexed lienId, uint256 recoveryProceeds, uint256 remainingProvision);
    event Resolved(bytes32 indexed lienId, uint256 capitalSlashAmount);
    event WrittenOff(bytes32 indexed lienId, uint256 capitalSlashAmount);

    /// @param forwarder    The Chainlink Forwarder (the base reverts `InvalidForwarderAddress` on zero).
    /// @param navOracle_   The set-once-deployed-already NAV oracle (sole provision sink).
    /// @param xAlpha_      The bond asset.
    /// @param recoveryFloor_ The day-one provision floor (18-dp fraction, `< 1e18`).
    constructor(address forwarder, address navOracle_, address xAlpha_, uint256 recoveryFloor_)
        ReceiverTemplate(forwarder)
    {
        if (navOracle_ == address(0) || xAlpha_ == address(0)) revert ZeroAddress();
        if (recoveryFloor_ >= 1e18) revert InvalidRecoveryFloor();
        navOracle = ISzipNavOracle(navOracle_);
        xAlpha = IERC20(xAlpha_);
        recoveryFloor = recoveryFloor_;
    }

    // --------------------------------------------------------------------- escrow wiring (Timelock-re-pointable, §17)
    /// @notice Wire the bond escrow (the escrow-side of the circular dependency). **Re-pointable by the Timelock
    ///         owner** (`onlyOwner`, §17 build phase — NOT set-once, NOT renounce-frozen; uniform with the other
    ///         wiring setters, all re-frozen together at the pre-prod immutable lock-down). Grants NO standing
    ///         allowance: `_lock` approves exactly the bond `amount` just-in-time around its pull and resets to 0
    ///         (LOSS-ADV-01), so a re-pointed escrow has nothing to drain — re-pointing is grief/redirect, never a
    ///         drain of the launch reserve. (An ERC-20 allowance authorizes the SPENDER to move the owner's tokens
    ///         to any destination, so a standing MAX allowance to a re-pointable escrow WOULD be a drain primitive
    ///         regardless of the escrow's own non-sweepability — hence the exact-amount JIT approval below.)
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = ILienXAlphaEscrow(escrow_);
        emit EscrowSet(escrow_);
    }

    /// @notice Re-point the NAV oracle (sole provision sink). `onlyOwner` (the Timelock). Build-phase flexibility.
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert ZeroAddress();
        navOracle = ISzipNavOracle(navOracle_);
        emit NavOracleSet(navOracle_);
    }

    /// @notice Re-point the bond asset. `onlyOwner` (the Timelock). No re-approval needed: `_lock` grants the escrow
    ///         an exact-amount just-in-time allowance per bond (LOSS-ADV-01), so there is no standing allowance to
    ///         re-establish on a token re-point.
    function setXAlpha(address xAlpha_) external onlyOwner {
        if (xAlpha_ == address(0)) revert ZeroAddress();
        xAlpha = IERC20(xAlpha_);
        emit XAlphaSet(xAlpha_);
    }

    /// @notice Update the conservative provision floor. `onlyOwner` (the Timelock — the same admin that owns the
    ///         engine modules' CRE flows). Bounded `< 1e18` like the ctor. Does NOT retroactively re-mark existing
    ///         provisions (each lien was marked at the floor in force at its recognition); applies to subsequent
    ///         DEFAULT recognitions only.
    function setRecoveryFloor(uint256 newFloor) external onlyOwner {
        if (newFloor >= 1e18) revert InvalidRecoveryFloor();
        uint256 old = recoveryFloor;
        recoveryFloor = newFloor;
        emit RecoveryFloorSet(old, newFloor);
    }

    // --------------------------------------------------------------------- report dispatcher
    /// @notice The reportType-8 action dispatcher (§4.4/§8.4). Only reachable via the base's Forwarder-gated
    ///         `onReport`, so the §13 trust boundary is the entry guard.
    /// @param report The shared §4.4 envelope `abi.encode(uint8 reportType, bytes payload)`.
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (reportType != REPORT_TYPE) revert InvalidReportType(reportType);

        (uint8 action, bytes memory data) = abi.decode(payload, (uint8, bytes));
        if (action == uint8(Action.Lock)) {
            _lock(data);
        } else if (action == uint8(Action.Release)) {
            _release(data);
        } else if (action == uint8(Action.Default_)) {
            _default(data);
        } else if (action == uint8(Action.Recovery)) {
            _recovery(data);
        } else if (action == uint8(Action.Resolve)) {
            _resolve(data);
        } else if (action == uint8(Action.WriteOff)) {
            _writeOff(data);
        } else {
            revert InvalidAction(action);
        }
    }

    // --------------------------------------------------------------------- LOCK (M1-live)
    /// @dev `data = (bytes32 lienId, address originator, uint256 amount)`. Ledger written before the external pull
    ///      (CEI); a failed pull reverts the whole report leaving no orphan status.
    function _lock(bytes memory data) internal {
        (bytes32 lienId, address originator, uint256 amount) = abi.decode(data, (bytes32, address, uint256));
        if (lienLoss[lienId].status != LienStatus.None) revert BadStatus();

        lienLoss[lienId].status = LienStatus.Bonded;

        // Exact-amount just-in-time allowance (LOSS-ADV-01): grant the escrow ONLY this bond's `amount` for its pull,
        // then reset to 0, so the coordinator never carries a standing allowance a re-pointed escrow could drain.
        // Mirrors the house per-zap pattern (docs/wires/WOOF-06). The escrow's `lockXAlpha` is `onlyCoordinator` +
        // `nonReentrant` and pulls exactly `amount`, so the approve→pull→reset is atomic from the coordinator's view.
        xAlpha.forceApprove(address(escrow), amount);
        escrow.lockXAlpha(lienId, originator, amount);
        xAlpha.forceApprove(address(escrow), 0);

        emit BondLocked(lienId, originator, amount);
    }

    // --------------------------------------------------------------------- RELEASE (M1-live clean repay)
    /// @dev `data = (bytes32 lienId)`. A Bonded lien always carries provision 0, so `totalProvision` is untouched.
    function _release(bytes memory data) internal {
        bytes32 lienId = abi.decode(data, (bytes32));
        if (lienLoss[lienId].status != LienStatus.Bonded) revert BadStatus();

        lienLoss[lienId].status = LienStatus.None;

        escrow.releaseXAlpha(lienId);

        emit BondReleased(lienId);
    }

    // --------------------------------------------------------------------- DEFAULT (M2 recognition)
    /// @dev `data = (bytes32 lienId, uint256 atRisk)`. The bound (down): `provision = atRisk×(1−recoveryFloor)`,
    ///      truncating (rounds DOWN — favorable, never over-marks). A zero-result DEFAULT does NOT revert; only
    ///      `atRisk == 0` reverts.
    function _default(bytes memory data) internal {
        (bytes32 lienId, uint256 atRisk) = abi.decode(data, (bytes32, uint256));
        if (lienLoss[lienId].status != LienStatus.Bonded) revert BadStatus();
        if (atRisk == 0) revert ZeroAtRisk();

        uint256 p = atRisk * (1e18 - recoveryFloor) / 1e18;
        lienLoss[lienId].provision = p;
        lienLoss[lienId].status = LienStatus.Defaulted;
        totalProvision += p;

        navOracle.writeProvision(totalProvision);

        emit Defaulted(lienId, atRisk, p);
    }

    // --------------------------------------------------------------------- RECOVERY (M2 partial heal)
    /// @dev `data = (bytes32 lienId, uint256 recoveryProceeds)`. The bound (up only by realized receipts): provision
    ///      reduces by `min(provision, proceeds)`, floored at 0 (never writes NAV above the un-impaired basket).
    ///      Status STAYS `Defaulted`.
    function _recovery(bytes memory data) internal {
        (bytes32 lienId, uint256 recoveryProceeds) = abi.decode(data, (bytes32, uint256));
        if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();

        uint256 cur = lienLoss[lienId].provision;
        uint256 reduction = recoveryProceeds >= cur ? cur : recoveryProceeds;
        lienLoss[lienId].provision = cur - reduction;
        totalProvision -= reduction;

        navOracle.writeProvision(totalProvision);

        emit Recovered(lienId, recoveryProceeds, lienLoss[lienId].provision);
    }

    // --------------------------------------------------------------------- RESOLVE (M2 clean resolution)
    /// @dev `data = (bytes32 lienId, uint256 capitalSlashAmount)`. Heal the provision to 0, then route the bond
    ///      capital-first (`slashXAlphaToCapital` if `>0`) then cohort (`slashXAlphaToCohort` if any remains —
    ///      reading the escrow's remaining bond avoids a `NoBond` revert when a full-bond capital slash cleared it).
    ///      rejected assert — the rejection is the finding: an over-bond `capitalSlashAmount` is NOT
    ///      pre-asserted here. `slashXAlphaToCapital` reverts in the escrow on insufficient bond, which reverts the
    ///      WHOLE tx atomically (CEI: the provision heal + status flip roll back, nothing is stranded), and the CRE
    ///      can re-submit with a corrected amount. An explicit `capitalSlashAmount <= bondAmount` guard would be a
    ///      no-op (same revert, one block earlier) — deliberately omitted.
    function _resolve(bytes memory data) internal {
        (bytes32 lienId, uint256 capitalSlashAmount) = abi.decode(data, (bytes32, uint256));
        if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();

        totalProvision -= lienLoss[lienId].provision;
        lienLoss[lienId].provision = 0;
        lienLoss[lienId].status = LienStatus.Resolved;

        navOracle.writeProvision(totalProvision);

        if (capitalSlashAmount != 0) escrow.slashXAlphaToCapital(lienId, capitalSlashAmount);
        if (escrow.bondAmount(lienId) != 0) escrow.slashXAlphaToCohort(lienId);

        emit Resolved(lienId, capitalSlashAmount);
    }

    // --------------------------------------------------------------------- WRITEOFF (M2 permanent shortfall)
    /// @dev `data = (bytes32 lienId, uint256 capitalSlashAmount)`. Settle the provision PERMANENTLY: leave the
    ///      per-lien provision (and so `totalProvision`) UNCHANGED — the residual IS the realized loss; do NOT call
    ///      `writeProvision` (no change). Route the bond exactly as RESOLVE. Only `Defaulted` is a legal source, so
    ///      `WrittenOff` accepts no further RECOVERY/RESOLVE/WRITEOFF/RELEASE.
    function _writeOff(bytes memory data) internal {
        (bytes32 lienId, uint256 capitalSlashAmount) = abi.decode(data, (bytes32, uint256));
        if (lienLoss[lienId].status != LienStatus.Defaulted) revert BadStatus();

        lienLoss[lienId].status = LienStatus.WrittenOff;

        if (capitalSlashAmount != 0) escrow.slashXAlphaToCapital(lienId, capitalSlashAmount);
        if (escrow.bondAmount(lienId) != 0) escrow.slashXAlphaToCohort(lienId);

        emit WrittenOff(lienId, capitalSlashAmount);
    }
}
