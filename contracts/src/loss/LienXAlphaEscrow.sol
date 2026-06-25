// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LienXAlphaEscrow (item 8-Bx — the per-lien xALPHA first-loss bond custody)
/// @notice The loss-side sibling of the senior `ZipRedemptionQueue` (item 9): a standalone, non-sweepable
///         custody contract holding the originator's xALPHA first-loss bond per lien. It is NOT a Zodiac
///         module, NOT a Baal shaman, NOT a `ReceiverTemplate`. Build phase (2026-06-09, §17): a single
///         **Timelock admin** can re-point the four wiring slots (xAlpha/coordinator/adminSafe/juniorTrancheSafe) so a
///         redeployed oracle/safe/coordinator does not force a redeploy cascade; re-freezing these to immutable
///         (which restores destination-integrity theft-immunity) is DEFERRED to the pre-production lock-down.
///         `claude-zipcode.md` §4.6 / §11 / §2 / §6.4.
///
///         CUSTODY HALF (M1-live): `lockXAlpha` posts the bond at origination (protocol-posted on the
///         originator's behalf at launch, §2/§4.6), `releaseXAlpha` returns it on repayment.
///
///         SLASH HALF (built + mock-tested now, M2-live with the `DefaultCoordinator` driver): on a default,
///         the bond is held through the freeze and applied at resolution in TWO ordered jobs —
///         (1) `slashXAlphaToCapital` routes xALPHA → the `adminSafe` (the off-chain recovery/bridge account
///         that liquidates alpha → TAO → USDC on Bittensor, §11) to cover a REALIZED capital hole, up to the
///         shortfall the coordinator computed off-chain; (2) the remainder is the Duration-Bond premium,
///         `slashXAlphaToCohort`, routed to the `juniorTrancheSafe` (the engine/main basket Safe, CTR-11) — it lands
///         as FREE, liquid value the yield flywheel subsumes, and NAV does the socialized cohort pro-rata for free
///         (no snapshot / per-holder index / RewardsDistributor / SBT, §6.4/§11).
///
///         CUSTODY MODEL — clean-room replication of `reference/moneymarket-contracts/src/InsuranceFund.sol`
///         (`bring`, :33): the single-immutable-authorized-caller + gated `safeTransfer` pattern, generalized to
///         (a) a pull-in at lock, (b) per-lien bookkeeping, (c) three fixed destinations. Not imported (Morpho's
///         own IERC20/SafeTransferLib infra is wrong for us; we use OZ `IERC20` + `SafeERC20`, the project
///         standard, per `ZipDepositModule.sol:4,6` / `ZipRedemptionQueue.sol:4,6`).
///
///         SECURITY THESIS (destination integrity, NOT authorization correctness): no state-changer takes a
///         recipient parameter; xALPHA can only ever flow to three destinations — the recorded `bondOriginator`
///         (captured at lock from the coordinator's arg), the `adminSafe`, the `juniorTrancheSafe`. So a compromised
///         `coordinator` cannot redirect a bond to an attacker — it can only GRIEF (premature release / slash a
///         healthy bond), the coordinator's §13 trust boundary. (BUILD PHASE, §17: the sinks are Timelock-set, so
///         the theft-immunity holds against everyone EXCEPT the Timelock owner, who can re-point them — a
///         grief/redirect, not a drain; re-freezing the sinks to immutable at pre-prod restores the absolute.)
///         The escrow does NOT add on-chain solvency/default gating; the split + timing are the coordinator's job (§4.6).
///
///         CEI + `nonReentrant` (both): every external transfer happens AFTER all state writes for that path,
///         and every state-changer carries `nonReentrant`. xALPHA is hookless/feeless today; the contract is
///         token-agnostic (item-10 swaps a stand-in for production xALPHA), so the guard is mandatory
///         belt-and-suspenders (mirrors `ZipRedemptionQueue is ReentrancyGuard`).
contract LienXAlphaEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- wiring (Timelock-settable; build phase)
    // NOTE (§17): the wiring below is Timelock-settable, NOT immutable — the build phase keeps one admin
    // key that can re-point everything (new oracle/safe/coordinator addresses) without a redeploy cascade.
    // Hardening these back to immutable (which restores the destination-integrity theft-immunity thesis) is DEFERRED
    // to the pre-production lock-down, once the wiring is proven (see §17 / `tickets/loss/8-Bx-...`).
    /// @notice The bond asset — the bridged xALPHA / 8x-01 `SzAlphaMirror` (a generic ERC-20 in M1 tests).
    IERC20 public xAlpha;
    /// @notice The SOLE authorized caller of all four state-changers (the loss-side orchestrator that posts
    ///         launch bonds and, in M2, the `DefaultCoordinator` that drives slash).
    address public coordinator;
    /// @notice The ONLY destination of `slashXAlphaToCapital` — the protocol treasury Safe: the recovery custody
    ///         whose off-chain process bridges xALPHA → TAO → USDC on Bittensor to cover a realized capital hole, §11.
    address public adminSafe;
    /// @notice The ONLY destination of `slashXAlphaToCohort` — the engine/main Safe (CTR-11). The cohort premium
    ///         lands here as FREE, liquid value where the yield flywheel (SellModule / LpStrategyModule, both enabled
    ///         on the engine Safe) subsumes it; NAV still does the cohort pro-rata per-share via gross basket value
    ///         (§4.6/§6.4). Was the juniorTrancheSidecar Safe, where it sat inert (no module could reach it).
    address public juniorTrancheSafe;

    // --------------------------------------------------------------------- per-lien bond book (keyed by lienId)
    /// @notice Current escrowed xALPHA for the lien (the canonical `bytes32 lienId` type, §8.0).
    mapping(bytes32 lienId => uint256) public bondAmount;
    /// @notice Who the bond returns to on release (recorded at lock from the coordinator's arg).
    mapping(bytes32 lienId => address) public bondOriginator;

    // --------------------------------------------------------------------- errors (no string reverts)
    error ZeroAddress();
    error NotCoordinator();
    error ZeroWiring();
    error ZeroOriginator();
    error SelfOriginator();
    error ZeroAmount();
    error BondExists();
    error NoBond();
    error ExceedsBond();

    // --------------------------------------------------------------------- events
    /// @notice A bond was posted for `lienId`, returnable to `originator`.
    event Locked(bytes32 indexed lienId, address indexed originator, uint256 amount);
    /// @notice The full bond was returned to the recorded originator on repayment.
    event Released(bytes32 indexed lienId, address indexed originator, uint256 amount);
    /// @notice `amount` xALPHA was routed to the `adminSafe` to cover a realized capital hole.
    event SlashedToCapital(bytes32 indexed lienId, uint256 amount);
    /// @notice The remaining bond (the premium) was routed to the `juniorTrancheSafe`. Emits the REMAINING amount.
    event SlashedToCohort(bytes32 indexed lienId, uint256 amount);
    /// @notice A Timelock-admin re-point of one of the four wiring slots (build-phase flexibility).
    event WiringSet(bytes32 indexed slot, address value);

    /// @notice The sole authorized caller of every state-changer.
    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    /// @param xAlpha_      The bond asset (bridged xALPHA / 8x-01 `SzAlphaMirror`; a generic ERC-20 in M1 tests).
    /// @param coordinator_ The sole authorized caller of all four state-changers.
    /// @param adminSafe_ The only destination of `slashXAlphaToCapital` (alpha→TAO→USDC bridge account, §11).
    /// @param juniorTrancheSafe_  The only destination of `slashXAlphaToCohort` (the engine/main Safe; CTR-11, §4.6/§6.4).
    constructor(address xAlpha_, address coordinator_, address adminSafe_, address juniorTrancheSafe_) Ownable(msg.sender) {
        if (xAlpha_ == address(0) || coordinator_ == address(0) || adminSafe_ == address(0) || juniorTrancheSafe_ == address(0))
        {
            revert ZeroAddress();
        }
        xAlpha = IERC20(xAlpha_);
        coordinator = coordinator_;
        adminSafe = adminSafe_;
        juniorTrancheSafe = juniorTrancheSafe_;
    }

    // --------------------------------------------------------------------- Timelock re-point (build phase, §17)
    /// @notice Re-point the bond asset. `onlyOwner` (the Timelock). Build-phase flexibility; lock down pre-prod.
    function setXAlpha(address xAlpha_) external onlyOwner {
        if (xAlpha_ == address(0)) revert ZeroWiring();
        xAlpha = IERC20(xAlpha_);
        emit WiringSet("xAlpha", xAlpha_);
    }

    /// @notice Re-point the sole authorized caller. `onlyOwner` (the Timelock).
    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroWiring();
        coordinator = coordinator_;
        emit WiringSet("coordinator", coordinator_);
    }

    /// @notice Re-point the capital-slash destination. `onlyOwner` (the Timelock).
    function setAdminSafe(address adminSafe_) external onlyOwner {
        if (adminSafe_ == address(0)) revert ZeroWiring();
        adminSafe = adminSafe_;
        emit WiringSet("adminSafe", adminSafe_);
    }

    /// @notice Re-point the cohort-premium destination (the engine/main Safe, CTR-11). `onlyOwner` (the Timelock).
    function setJuniorTrancheSafe(address juniorTrancheSafe_) external onlyOwner {
        if (juniorTrancheSafe_ == address(0)) revert ZeroWiring();
        juniorTrancheSafe = juniorTrancheSafe_;
        emit WiringSet("juniorTrancheSafe", juniorTrancheSafe_);
    }

    // --------------------------------------------------------------------- lock (post the bond, M1-live)
    /// @notice Post the first-loss bond for `lienId`, pulled from the coordinator (which funds it on the
    ///         originator's behalf — it must have approved this escrow, an item-10 wiring obligation). No clobber
    ///         or top-up: a lienId that already carries a bond reverts `BondExists`. Custody models
    ///         `InsuranceFund.bring:33` (generalized to a pull-in). CEI: mappings written before the pull, so a
    ///         failed pull reverts the whole tx and leaves NO orphaned bond entry.
    function lockXAlpha(bytes32 lienId, address originator, uint256 amount) external onlyCoordinator nonReentrant {
        if (originator == address(0)) revert ZeroOriginator();
        if (originator == address(this)) revert SelfOriginator();
        if (amount == 0) revert ZeroAmount();
        if (bondAmount[lienId] != 0) revert BondExists();

        bondAmount[lienId] = amount;
        bondOriginator[lienId] = originator;

        xAlpha.safeTransferFrom(msg.sender, address(this), amount);

        emit Locked(lienId, originator, amount);
    }

    // --------------------------------------------------------------------- release (repayment, M1-live)
    /// @notice Return the FULL bond to the recorded originator on repayment. CEI: both mappings zeroed before the
    ///         transfer out.
    function releaseXAlpha(bytes32 lienId) external onlyCoordinator nonReentrant {
        uint256 amount = bondAmount[lienId];
        if (amount == 0) revert NoBond();
        address originator = bondOriginator[lienId];

        bondAmount[lienId] = 0; // zero both mappings first (CEI)
        bondOriginator[lienId] = address(0);

        xAlpha.safeTransfer(originator, amount);

        emit Released(lienId, originator, amount);
    }

    // --------------------------------------------------------------------- slash → capital (resolution job 1, M2-live)
    /// @notice Route `amount` xALPHA (up to the bond, the shortfall the coordinator computed off-chain) to the
    ///         `adminSafe` to cover a REALIZED capital hole — last resort for a realized loss. Partial allowed:
    ///         the lien STAYS OPEN with the remainder for the cohort (`bondOriginator` untouched — mid-resolution).
    ///         `amount == bondAmount` is the exact-equality boundary that PASSES and drives the bond to 0. The
    ///         alpha → TAO → USDC liquidation happens off-chain on Bittensor (§11); this only routes (no swap).
    function slashXAlphaToCapital(bytes32 lienId, uint256 amount) external onlyCoordinator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > bondAmount[lienId]) revert ExceedsBond();

        bondAmount[lienId] -= amount; // effects first; bondOriginator untouched (lien still mid-resolution)

        xAlpha.safeTransfer(adminSafe, amount);

        emit SlashedToCapital(lienId, amount);
    }

    // --------------------------------------------------------------------- slash → cohort (resolution job 2, M2-live)
    /// @notice Route the ENTIRE remaining bond — the Duration-Bond premium — to the `juniorTrancheSafe` (the engine/main
    ///         Safe, CTR-11), where it lands as FREE, liquid value the yield flywheel subsumes; the socialized cohort
    ///         pro-rata is still automatic via NAV (gross basket value sums the main Safe's xALPHA, §4.6/§6.4).
    ///         Delivers whatever `slashXAlphaToCapital` left, or the whole bond if no capital slash ran (the
    ///         pure-premium path). The ordered pair (capital-first, then cohort) realizes §4.6's "sell-to-cover the
    ///         hole, remainder is the premium." If a full-bond capital slash already drove the bond to 0, the
    ///         coordinator SKIPS this (it reverts `NoBond`). CEI: both mappings zeroed before the transfer out.
    function slashXAlphaToCohort(bytes32 lienId) external onlyCoordinator nonReentrant {
        uint256 remaining = bondAmount[lienId];
        if (remaining == 0) revert NoBond();

        bondAmount[lienId] = 0;
        bondOriginator[lienId] = address(0);

        xAlpha.safeTransfer(juniorTrancheSafe, remaining);

        emit SlashedToCohort(lienId, remaining);
    }
}
