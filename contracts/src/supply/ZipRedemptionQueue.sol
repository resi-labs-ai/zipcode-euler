// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IZipUSD} from "../interfaces/euler/IZipUSD.sol";

/// @title ZipRedemptionQueue (item 9 — the senior par-burn sink)
/// @notice The SENIOR exit primitive: escrowed zipUSD → USDC at strict par ($1), burning the zipUSD as it is filled.
///         It is the inverse of the WOOF-06 zap's `deposit` (mint zipUSD against USDC parked in the warehouse). It is
///         NOT the junior Exit Gate (§6.4): different instrument (zipUSD = the senior $1 dollar, not the szipUSD
///         junior share), different exit, different pricing (par, NOT NAV). Never conflate.
///
///         IMPAIRMENT-BLIND BY DESIGN (the "loan-marked-bad signal is absent" premise is WRONG):
///         a bad-loan signal DOES exist — `DefaultCoordinator.writeProvision` marks the impairment into the JUNIOR
///         `SzipNavOracle` NAV, so the junior `ExitGate` CoW exit self-prices on impairment continuously (§11/§12).
///         This SENIOR par queue is INTENTIONALLY impairment-blind: it pays strict $1 par regardless, because it is
///         single-requester treasury plumbing (see `redeemController` below), not an open creditor queue. No pro-rata
///         / impaired-rate machinery belongs here.
///
///         SINGLE-REQUESTER TOPOLOGY (2026-06-13): `requestRedeem` is gated to ONE caller — the rq Safe (the
///         `OffRampModule` `exec`s through it). With a single requester, par redemption is treasury-internal
///         plumbing: the rq Safe escrows its own idle basket zipUSD, the CRE delivers USDC (warehouse REDEEM → REPAY),
///         `settleEpoch` burns the zipUSD against that USDC, and the rq Safe claims it back to fund the CoW buy-burn
///         bid (see `build/CoW-exit.md`). A real holder NEVER redeems here — they exit by selling szipUSD on CoW.
///         The pro-rata / era / cumulative-remaining engine that earlier versions carried (for an OPEN queue with
///         many untrusted requesters) was COLLAPSED OUT — it computed a fraction over a set of size one. What remains
///         is the par-burn core: escrow → fill `min(available, pending)` + burn → claim at par.
///
///         FUNDING (KR-1): the queue references NO EulerEarn and calls NOTHING to acquire USDC — the CRE cron does
///         warehouse REDEEM then REPAY (`USDC.transfer(queue, amount)`, scope-pinned `EqualTo(repaySink==queue)`)
///         then `settleEpoch()`. The queue treats its OWN USDC balance as the settlement liquidity.
///
///         OWNERSHIP (build phase, §17): wiring (`zipUSD`/`usdc`/`controller`/`redeemController`) is `Ownable`
///         (Timelock)-settable for build-phase flexibility — redeploy a token/controller and re-point with one call.
///         Re-freezing to immutable is DEFERRED to pre-prod. There is NO pause, NO upgrade, NO sweep: the queue is the
///         NON-SWEEPABLE REPAY sink (KR-2) — the only path that moves USDC out is a claimant's `withdraw`/`redeem`
///         against their own `claimableAssets`.
///
///         SOLVENCY DUST (KR-5): par credits round DOWN (`fillAssets = pending / scaleUp`, floor), so cumulative
///         paid-out ≤ cumulative delivered at every point. Sub-`scaleUp` round-down dust stays locked permanently
///         (NEVER swept — that would break KR-2); bounded, sub-cent across the protocol lifetime, acceptable for M1.
contract ZipRedemptionQueue is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- wiring (Timelock-settable; build phase §17)
    /// @notice zipUSD — the $1 utility synth (`ESynth`, 18-dp); escrowed on request, burned on settle.
    address public zipUSD;
    /// @notice USDC — the redemption asset (6-dp); delivered by the warehouse REPAY, paid out at par on claim.
    address public usdc;
    /// @notice `10 ** (zipDecimals - usdcDecimals)` — the SAME par scale as the WOOF-06 mint (`1e12` for 18/6),
    ///         derived from the tokens' own `decimals()` (mint/redeem stay exact inverses). Re-derived on `setTokens`.
    uint256 public scaleUp;
    /// @notice The CRE redemption-settle operator (CRE-02) — the sole caller of `settleEpoch`. Timelock-settable,
    ///         non-zero. NOT the per-request `requester`.
    address public controller;
    /// @notice The SOLE authorized `requestRedeem` caller — the rq Safe (the `OffRampModule` `exec`s through it, so
    ///         the `msg.sender` the queue sees is the Safe, NOT the module). Timelock-settable, non-zero. The CLAIM
    ///         path (`withdraw`/`redeem`) stays open for the requester.
    /// @dev TRUST INVARIANT: par-burn at strict 1:1 is sound ONLY because this is treasury-internal —
    ///      a SINGLE requester escrows its OWN idle basket zipUSD and claims its own par USDC. The `MultipleRequesters`
    ///      guard (enforced on escrow) is the SOLE defense keeping the topology single-requester; there is no
    ///      impaired-rate / pro-rata haircut here by design (the Maple/Centrifuge open-queue comparison does NOT
    ///      apply). Therefore `redeemController` MUST NEVER be set to an untrusted party — an untrusted requester
    ///      could redeem at par ahead of an impairment that the senior queue is intentionally blind to (see prorata).
    address public redeemController;

    // --------------------------------------------------------------------- accounting
    /// @notice The escrowed-and-unfilled zipUSD. ALWAYS a multiple of `scaleUp` (the whole-unit guard). Backs the
    ///         `zipBalance >= totalPending` invariant + the fill capacity.
    uint256 public totalPending;
    /// @notice USDC committed to fulfilled-but-unclaimed claims (book reserve; never moved except by claims).
    uint256 public reservedAssets;
    /// @notice The single requester with open pending (the rq Safe). Set on the first escrow, cleared when pending
    ///         drains to 0. Settle credits this address — no loop, no pro-rata (single-requester topology).
    address public pendingRequester;

    /// @notice Per-requester escrowed-and-unfilled zipUSD (one key in practice: the rq Safe).
    mapping(address => uint256) public pendingShares;
    /// @notice Per-requester USDC ready to withdraw (banked at par, round-down).
    mapping(address => uint256) public claimableAssets;

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error DecimalsTooFew();
    error ZeroShares();
    error ZeroAssets();
    error NotWholeUnit();
    error NotAuthorized();
    error NotController();
    error NotRedeemController();
    error MultipleRequesters();
    error InsufficientClaimable();

    // --------------------------------------------------------------------- events
    /// @notice A redeem request escrowed zipUSD. `sender == msg.sender` (the rq Safe).
    event RedeemRequest(address indexed requester, address indexed owner, address sender, uint256 shares);
    /// @notice A redemption settle ran. `pending` is the pre-settle `totalPending`; `filledShares` the burned zipUSD;
    ///         `fillAssets` the USDC reserved; `availableAssets` the free USDC at settle time.
    event RedemptionSettled(uint256 pending, uint256 filledShares, uint256 fillAssets, uint256 availableAssets);
    /// @notice A claim paid USDC out at par. `assets` USDC, `shares` zipUSD-equivalent (`assets * scaleUp`).
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed requester, uint256 assets, uint256 shares
    );
    event TokensSet(address indexed zipUSD, address indexed usdc);
    event ControllerSet(address indexed controller);
    event RedeemControllerSet(address indexed redeemController);

    /// @param zipUSD_     The zipUSD `ESynth` (18-dp). @param usdc_ USDC (6-dp). @param controller_ the CRE
    ///                    redemption-settle operator (the sole `settleEpoch` caller).
    constructor(address zipUSD_, address usdc_, address controller_) Ownable(msg.sender) {
        if (zipUSD_ == address(0) || usdc_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        uint8 zipDec = IERC20Metadata(zipUSD_).decimals();
        uint8 usdcDec = IERC20Metadata(usdc_).decimals();
        if (zipDec < usdcDec) revert DecimalsTooFew(); // value-1:1 par needs zipUSD the finer unit
        zipUSD = zipUSD_;
        usdc = usdc_;
        scaleUp = 10 ** (uint256(zipDec) - uint256(usdcDec));
        controller = controller_;
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point the zipUSD + USDC tokens (re-derives `scaleUp`). `onlyOwner` (Timelock), build-phase.
    function setTokens(address zipUSD_, address usdc_) external onlyOwner {
        if (zipUSD_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        uint8 zipDec = IERC20Metadata(zipUSD_).decimals();
        uint8 usdcDec = IERC20Metadata(usdc_).decimals();
        if (zipDec < usdcDec) revert DecimalsTooFew();
        zipUSD = zipUSD_;
        usdc = usdc_;
        scaleUp = 10 ** (uint256(zipDec) - uint256(usdcDec));
        emit TokensSet(zipUSD_, usdc_);
    }

    /// @notice Re-point the settle controller (CRE-02). `onlyOwner` (Timelock), build-phase.
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit ControllerSet(controller_);
    }

    /// @notice Re-point the redeem controller — the rq Safe authorized to call `requestRedeem`. `onlyOwner`
    ///         (Timelock). Wire to the rq SAFE (the `OffRampModule` `exec`s through it), NOT the module.
    function setRedeemController(address redeemController_) external onlyOwner {
        if (redeemController_ == address(0)) revert ZeroAddress();
        redeemController = redeemController_;
        emit RedeemControllerSet(redeemController_);
    }

    // --------------------------------------------------------------------- gate
    modifier onlyRedeemController() {
        if (msg.sender != redeemController) revert NotRedeemController();
        _;
    }

    // --------------------------------------------------------------------- request (escrow external zipUSD)
    /// @notice Escrow `shares` zipUSD into the queue for par redemption (filled at the next `settleEpoch`). `shares`
    ///         MUST be a whole multiple of `scaleUp` so `totalPending` stays an exact multiple and a fully-funded
    ///         settle reaches a clean zero. Single-requester: every open request shares one `pendingRequester`.
    /// @param shares    The zipUSD to escrow (whole multiple of `scaleUp`, non-zero).
    /// @param requester The claimant whose pending balance this joins (the rq Safe).
    /// @param owner     The zipUSD source (must be `msg.sender`).
    /// @return requestId Always 0 (singleton; kept for `OffRampModule`/7540 call-shape compatibility).
    function requestRedeem(uint256 shares, address requester, address owner)
        external
        nonReentrant
        onlyRedeemController
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroShares();
        if (shares % scaleUp != 0) revert NotWholeUnit();
        if (owner != msg.sender) revert NotAuthorized();
        // Single-requester guard. In practice it never trips: `onlyRedeemController` already pins the sole caller to
        // the rq Safe, which always passes itself as `requester`. It exists to defend the invariant the collapse
        // rests on — `settleEpoch` credits ONE `pendingRequester` with no loop, which is only correct if exactly one
        // requester is ever open. If `redeemController` is later rewired to admit two distinct requesters, fills
        // would be silently misattributed; this turns that mistake into a hard revert instead of a solvency bug.
        if (pendingRequester == address(0)) {
            pendingRequester = requester;
        } else if (pendingRequester != requester) {
            revert MultipleRequesters();
        }

        IERC20(zipUSD).safeTransferFrom(owner, address(this), shares); // escrow external zipUSD
        pendingShares[requester] += shares;
        totalPending += shares;

        emit RedeemRequest(requester, owner, msg.sender, shares);
        return 0;
    }

    // --------------------------------------------------------------------- settle (par fill + burn)
    /// @notice The CRE redemption-settle step (§8.3): fill the open pending against the REPAY-delivered USDC at par
    ///         (`min(available, pending)`), burn the filled zipUSD, and bank the USDC as claimable. O(1). Never moves
    ///         USDC out (KR-2). On-demand — the controller may settle at any time (no time gate).
    function settleEpoch() external nonReentrant {
        if (msg.sender != controller) revert NotController();

        uint256 pending = totalPending;
        uint256 availableAssets = IERC20(usdc).balanceOf(address(this)) - reservedAssets; // free REPAY USDC
        uint256 maxFillAssets = pending / scaleUp; // par capacity (floor)
        uint256 fillAssets = availableAssets < maxFillAssets ? availableAssets : maxFillAssets;
        uint256 filledShares = fillAssets * scaleUp; // <= pending, EXACT multiple of scaleUp

        if (filledShares != 0) {
            address r = pendingRequester;
            totalPending = pending - filledShares;
            pendingShares[r] -= filledShares;
            claimableAssets[r] += fillAssets; // par, round DOWN (KR-5)
            reservedAssets += fillAssets;
            if (pendingShares[r] == 0) pendingRequester = address(0); // fully drained
            IZipUSD(zipUSD).burn(address(this), filledShares);
        }
        // else: zero/no-op fill (no USDC delivered yet, or nothing pending).

        emit RedemptionSettled(pending, filledShares, fillAssets, availableAssets);
    }

    // --------------------------------------------------------------------- claim (par payout)
    /// @notice Claim `assets` USDC (par) to `receiver` against `requester`'s `claimableAssets`. Only the requester
    ///         may claim. Effects-before-interaction.
    /// @return shares The zipUSD-equivalent claimed (`assets * scaleUp`).
    function withdraw(uint256 assets, address receiver, address requester)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (requester != msg.sender) revert NotAuthorized();
        if (assets == 0) revert ZeroAssets();
        if (assets > claimableAssets[requester]) revert InsufficientClaimable(); // over-claim / re-claim reverts
        shares = assets * scaleUp;

        claimableAssets[requester] -= assets; // effects BEFORE interaction
        reservedAssets -= assets;
        IERC20(usdc).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, requester, assets, shares);
    }

    /// @notice Claim `shares`-worth of zipUSD-equivalent as USDC (par) to `receiver`. `redeem(shares < scaleUp)`
    ///         reverts (`assets == 0` guard) rather than a phantom zero-transfer.
    /// @return assets The USDC paid (`shares / scaleUp`).
    function redeem(uint256 shares, address receiver, address requester)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (requester != msg.sender) revert NotAuthorized();
        if (shares == 0) revert ZeroShares();
        assets = shares / scaleUp;
        if (assets == 0) revert ZeroAssets(); // reject redeem(shares < scaleUp)
        if (assets > claimableAssets[requester]) revert InsufficientClaimable();
        shares = assets * scaleUp; // canonical zipUSD-equivalent actually redeemed (mirror withdraw :221)

        claimableAssets[requester] -= assets; // effects BEFORE interaction
        reservedAssets -= assets;
        IERC20(usdc).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, requester, assets, shares);
    }

    // --------------------------------------------------------------------- views
    /// @notice The still-pending escrowed zipUSD for `r`.
    function pendingRedeemRequest(uint256, address r) external view returns (uint256) {
        return pendingShares[r];
    }

    /// @notice The USDC `r` could `withdraw` right now.
    function maxWithdraw(address r) external view returns (uint256) {
        return claimableAssets[r];
    }
}
