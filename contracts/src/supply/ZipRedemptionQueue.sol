// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IZipUSD} from "../interfaces/euler/IZipUSD.sol";

/// @title ZipRedemptionQueue (item 9 — the senior exit)
/// @notice The SENIOR exit: un-staked zipUSD → USDC at strict par ($1) via a 30-day epoch queue with pro-rata
///         partial fills when the warehouse can't free enough cash. It is the inverse of the WOOF-06 zap's
///         `deposit` (mint zipUSD against USDC parked in the warehouse). It is NOT the junior Exit Gate (§6.4):
///         different instrument (zipUSD = the senior $1 dollar, not the szipUSD junior share), different exit,
///         different pricing (par, NOT NAV). Never conflate. `claude-zipcode.md` §6.1/§4.5/§6.2/§6.3/§8.3/§8.5;
///         `baal-spec.md` §12/§11/§19.x.
///
///         LIFECYCLE (ERC-7540 shape, clean-room — modeled on, NOT inherited from,
///         `reference/erc7540-reference/src/ControlledAsyncRedeem.sol`:39/65/81/104 + `BaseERC7540.sol:34`):
///           `requestRedeem(shares, requester, owner)`  — escrows EXTERNAL zipUSD (`ESynth`, 18-dp);
///           `settleEpoch()` onlyController              — reserves the USDC the CRE delivered (warehouse
///                                                          REDEEM → REPAY, §8.5), burns the filled zipUSD;
///           `withdraw`/`redeem`                         — claim USDC at par (÷scaleUp).
///         WHY NOT inherit solmate `BaseERC7540 is ERC4626, Owned, IERC7540Operator`: that base assumes (a) the
///         share token IS the vault (`share == address(this)`) — but our redeemed "shares" are external zipUSD;
///         (b) NAV `convertToAssets` — but zipUSD redeems at PAR, not NAV; (c) a mutable `Owned` owner with
///         `transferOwnership` — §4.5 forbids that (immutable controller). So we keep the function
///         names/signatures, events, and operator-approval semantics, but escrow external zipUSD, pay USDC at par,
///         and gate the lone privileged op on an immutable `controller`.
///
///         The PRO-RATA + CARRY-FORWARD idea is modeled (clean-room) on
///         `reference/maple-withdrawal-manager/contracts/MapleWithdrawalManager.sol:367-387/262-273`
///         (`redeemableShares = lockedShares * availableLiquidity / totalRequestedLiquidity` on a partial; the
///         unfilled remainder rolls forward). Maple is a PULL model (each owner acts in their window); we use a
///         PUSH `settleEpoch()` + a global cumulative-remaining factor (`cumRemaining`, scoped by an `era`
///         counter) so fills AUTO-CARRY across epochs with NO per-user action and NO unbounded loop.
///
///         FUNDING (KR-1): the queue references NO EulerEarn and calls NOTHING to acquire USDC — the CRE cron does
///         warehouse REDEEM then REPAY (`USDC.transfer(queue, amount)`, scope-pinned `EqualTo(repaySink==queue)`)
///         then `settleEpoch()`. The queue treats its OWN USDC balance as the settlement liquidity.
///
///         OWNERSHIP (KR-6): the ctor `controller` (the CRE redemption-settle operator, CRE-02) is stored
///         immutable and non-zero; `settleEpoch` is `onlyController`. There is NO `Owned`, NO `owner()`, NO
///         `transferOwnership`, NO renounce, NO pause, NO upgrade, NO sweep — the queue is the NON-SWEEPABLE REPAY
///         sink (KR-2): the only path that moves USDC out is a claimant's `withdraw`/`redeem` against their own
///         `claimableAssets`. The immutable `controller` is DISTINCT from the per-request 7540 `requester`/claimant
///         and from the EIP-7540 `operator` (a per-requester delegate set via `setOperator`).
///
///         OPERATOR SEMANTICS (security F7 — intended, not a bug): a requester-approved 7540 `operator`
///         (`setOperator`) can call `withdraw(assets, receiver, requester)` with an ARBITRARY `receiver` — i.e.
///         redirect the requester's claimed USDC. Only the requester can grant it (the `msg.sender != operator`
///         guard stands); an operator grant is therefore FULL claim control.
///
///         SOLVENCY DUST (KR-5): per-requester par credits round DOWN and the per-requester `ceil` on `pendingNow`
///         only DEFERS crediting, so cumulative paid-out ≤ cumulative delivered at every point. Round-down dust
///         (`reservedAssets − Σ credited`, bounded < 1e-6 USDC per requester-realize) stays locked permanently
///         (NEVER swept — that would break KR-2); `availableAssets` is understated by the accumulated dust over
///         time (bounded, sub-cent across the protocol lifetime; acceptable for M1).
contract ZipRedemptionQueue is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- wiring (Timelock-settable; build phase)
    // NOTE (2026-06-09, §17): wiring below is Timelock-settable, NOT immutable — build-phase flexibility (redeploy a
    // token/controller and re-point with one call). Re-freezing to immutable is DEFERRED to pre-prod.
    /// @notice zipUSD — the $1 utility synth (`ESynth`, 18-dp); escrowed on request, burned on settle.
    address public zipUSD;
    /// @notice USDC — the redemption asset (6-dp); delivered by the warehouse REPAY, paid out at par on claim.
    address public usdc;
    /// @notice `10 ** (zipDecimals - usdcDecimals)` — the SAME par scale as the WOOF-06 mint (`1e12` for 18/6),
    ///         derived from the tokens' own `decimals()` (mint/redeem stay exact inverses). Re-derived on `setTokens`.
    uint256 public scaleUp;
    /// @notice The CRE redemption-settle operator (CRE-02) — the sole caller of `settleEpoch`. Timelock-settable,
    ///         non-zero. NOT the 7540 `requester` nor the `operator`.
    address public controller;
    /// @notice The SOLE authorized `requestRedeem` caller — the rq Safe (the `OffRampModule` `exec`s through it, so
    ///         the `msg.sender` the queue sees is the Safe, NOT the module). Hard-gates new escrow to the off-ramp
    ///         path ("must exit through the vault"), closing the epoch-dilution / senior-USDC-griefing vector of an
    ///         OPEN `requestRedeem` (an external whale escrowing just before `settleEpoch` to shrink honest pro-rata
    ///         fills). Timelock-settable, non-zero. NOT theft prevention (par is fixed, `settleEpoch` is
    ///         `onlyController`, the queue is non-sweepable) — only griefing closure. The CLAIM path
    ///         (`withdraw`/`redeem`) stays OPEN for existing requesters.
    address public redeemController;

    // --------------------------------------------------------------------- constants
    /// @notice High-precision RAY for `cumRemaining` (so many small partial fills don't lose resolution).
    uint256 public constant PREC = 1e27;
    /// @notice The locked governed epoch cadence (§6.1).
    uint256 public constant EPOCH_DURATION = 30 days;
    /// @notice The ERC-7540 singleton request id (all requests share id 0).
    uint256 internal constant REQUEST_ID = 0;

    // --------------------------------------------------------------------- global accounting
    /// @notice Increments ONLY on a 100%-fill (full-drain) settle — the factor's epoch of validity. Resets
    ///         `cumRemaining` to `PREC`; requesters whose `eraAt < era` are fully filled (KR-4a).
    uint256 public era;
    /// @notice The running product of per-epoch UNFILLED fractions within the current era (RAY). Init `PREC`.
    ///         Invariant: `0 < cumRemaining <= PREC` at all times (a would-be-0 is the full-drain era bump).
    uint256 public cumRemaining;
    /// @notice The authoritative aggregate escrowed-and-unfilled zipUSD. ALWAYS a multiple of `scaleUp` (the
    ///         whole-unit guard). Backs the `zipBalance >= totalPending` invariant + the fill-ratio denominator.
    uint256 public totalPending;
    /// @notice USDC committed to fulfilled-but-unclaimed claims (book reserve; never moved except by claims).
    uint256 public reservedAssets;
    /// @notice Increments each `settleEpoch` (display/UX; DISTINCT from `era`).
    uint256 public epoch;
    /// @notice The 30-day gate anchor; advanced by a fixed `EPOCH_DURATION` increment per settle (no drift).
    uint256 public lastEpochTime;

    // --------------------------------------------------------------------- per-requester (O(1), no loops)
    /// @notice Escrowed-and-unfilled zipUSD, normalized to `cumAt[r]` (lazily realized).
    mapping(address => uint256) public sharesAt;
    /// @notice The `cumRemaining` snapshot at the requester's last touch. Invariant: `!= 0`.
    mapping(address => uint256) public cumAt;
    /// @notice The `era` at the requester's last touch.
    mapping(address => uint256) public eraAt;
    /// @notice USDC ready to withdraw (banked at par, round-down).
    mapping(address => uint256) public claimableAssets;

    // --------------------------------------------------------------------- EIP-7540 operator approval
    /// @notice `isOperator[controller_acct][operator]` — the EIP-7540 per-requester delegate. NOTE: the first key
    ///         is the 7540 "controller" (the requester/claimant), NOT this contract's immutable `controller`.
    mapping(address => mapping(address => bool)) public isOperator;

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error DecimalsTooFew();
    error ZeroShares();
    error ZeroAssets();
    error NotWholeUnit();
    error NotAuthorized();
    error NotController();
    error NotRedeemController();
    error EpochNotElapsed();
    error CannotSetSelfAsOperator();
    error InsufficientClaimable();

    // --------------------------------------------------------------------- events
    /// @notice EIP-7540 redeem request (id is the singleton 0). `sender == msg.sender`.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    /// @notice An epoch was settled. `pending` is the pre-settle `totalPending`; `filledShares` the burned zipUSD;
    ///         `fillAssets` the USDC reserved; `availableAssets` the free USDC at settle time.
    event EpochSettled(
        uint256 indexed epoch,
        uint256 indexed era,
        uint256 pending,
        uint256 filledShares,
        uint256 fillAssets,
        uint256 availableAssets
    );
    /// @notice A claim paid USDC out at par. `assets` USDC, `shares` zipUSD-equivalent (`assets * scaleUp`).
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed controller, uint256 assets, uint256 shares
    );
    /// @notice EIP-7540 operator approval set/cleared.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
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
        cumRemaining = PREC; // never 0 (KR-4a)
        lastEpochTime = block.timestamp; // anchor the first 30-day window
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

    /// @notice Re-point the redeem controller — the rq Safe authorized to call `requestRedeem` (build phase, §17;
    ///         re-pointable, NOT set-once). `onlyOwner` (Timelock), `ZeroAddress`-guarded. Wire this to the rq SAFE
    ///         (the `OffRampModule` `exec`s through it), NOT the module — wiring it to the module would make the C1
    ///         off-ramp path revert (the queue sees the Safe as `msg.sender`).
    function setRedeemController(address redeemController_) external onlyOwner {
        if (redeemController_ == address(0)) revert ZeroAddress();
        redeemController = redeemController_;
        emit RedeemControllerSet(redeemController_);
    }

    // --------------------------------------------------------------------- gate
    /// @dev Hard-gate `requestRedeem` to the wired `redeemController` (the rq Safe). New escrow must come through the
    ///      off-ramp path; the claim path stays open for existing requesters.
    modifier onlyRedeemController() {
        if (msg.sender != redeemController) revert NotRedeemController();
        _;
    }

    // --------------------------------------------------------------------- internal realize (O(1) lazy fill)
    /// @dev Bank prior fills for `r` and re-base its (era, cumAt) to the current global factor. Called at the
    ///      START of every per-requester touch. `pendingNow` rounds UP ⇒ `filled` rounds DOWN ⇒ Σ credited ≤
    ///      reserved (solvency, KR-5). The `eraAt[r] < era` branch credits a fully-drained cohort's entire
    ///      `sharesAt` with NO stale-factor division (zero-safe, KR-4a).
    function _realize(address r) internal {
        uint256 s = sharesAt[r];
        if (s == 0) {
            eraAt[r] = era;
            cumAt[r] = cumRemaining;
            return;
        }
        uint256 pendingNow;
        if (eraAt[r] < era) {
            pendingNow = 0; // the requester's era ended in a 100% drain ⇒ fully filled
        } else {
            // same era: cumAt[r] >= cumRemaining (non-increasing within an era), so pendingNow <= s. ceil.
            pendingNow = (s * cumRemaining + cumAt[r] - 1) / cumAt[r];
        }
        uint256 filled = s - pendingNow; // >= 0 always
        if (filled != 0) claimableAssets[r] += filled / scaleUp; // par, round DOWN
        sharesAt[r] = pendingNow;
        eraAt[r] = era;
        cumAt[r] = cumRemaining;
    }

    /// @dev A pure-view mirror of `_realize` (same era/ceil/floor math). Returns `pendingNow` and
    ///      `totalClaimableAssets = claimableAssets[r] + (s - pendingNow) / scaleUp` (banked + not-yet-realized).
    function _previewRealize(address r) internal view returns (uint256 pendingNow, uint256 totalClaimableAssets) {
        uint256 s = sharesAt[r];
        if (s == 0) return (0, claimableAssets[r]);
        if (eraAt[r] < era) {
            pendingNow = 0;
        } else {
            pendingNow = (s * cumRemaining + cumAt[r] - 1) / cumAt[r];
        }
        totalClaimableAssets = claimableAssets[r] + (s - pendingNow) / scaleUp;
    }

    // --------------------------------------------------------------------- request (escrow external zipUSD)
    /// @notice Escrow `shares` zipUSD into the queue, joining the CURRENT open epoch (filled at the NEXT
    ///         `settleEpoch` boundary, §6.1). `shares` MUST be a whole multiple of `scaleUp` (the F1/F2 fix — keeps
    ///         `totalPending` an exact multiple of `scaleUp` so a fully-funded settle reaches the full-drain era
    ///         bump; a sub-`scaleUp` request is structurally unfillable, redeem the whole-unit floor + keep/sell
    ///         the dust on the AMM, §6.2). The 7540 claimant param is named `requester` to disambiguate from the
    ///         privileged `controller`; param names don't affect the selector `requestRedeem(uint256,address,address)`.
    /// @param shares    The zipUSD to escrow (whole multiple of `scaleUp`, non-zero).
    /// @param requester The 7540 controller/claimant whose pending balance this joins.
    /// @param owner     The zipUSD source (must be `msg.sender` or have approved it as an operator).
    /// @return requestId The 7540 singleton (always 0).
    function requestRedeem(uint256 shares, address requester, address owner)
        external
        nonReentrant
        onlyRedeemController
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroShares();
        if (shares % scaleUp != 0) revert NotWholeUnit();
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotAuthorized();

        IERC20(zipUSD).safeTransferFrom(owner, address(this), shares); // escrow external zipUSD
        _realize(requester); // bank prior fills; sets eraAt/cumAt[requester] to current
        sharesAt[requester] += shares; // joins at the CURRENT (era, cumRemaining) ⇒ no retroactive fill
        totalPending += shares; // eligible for the NEXT settle (§6.1)

        emit RedeemRequest(requester, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    // --------------------------------------------------------------------- settle (the 4-step pro-rata fill)
    /// @notice The CRE redemption-settle step (§8.3): reserve the REPAY-delivered USDC against the open pending,
    ///         pro-rata, and burn the filled zipUSD. O(1), no loops. A 100% fill closes the era (zero-safe);
    ///         a partial fill folds an UP-rounded unfilled fraction into `cumRemaining` (stays > 0). Never moves
    ///         USDC out (KR-2). Reverts before the 30-day boundary (`EpochNotElapsed`).
    function settleEpoch() external nonReentrant {
        if (msg.sender != controller) revert NotController();
        if (block.timestamp < lastEpochTime + EPOCH_DURATION) revert EpochNotElapsed();
        lastEpochTime += EPOCH_DURATION; // fixed increment ⇒ cadence cannot drift earlier (KR-8)
        epoch += 1;

        uint256 pending = totalPending;
        uint256 availableAssets = IERC20(usdc).balanceOf(address(this)) - reservedAssets; // free REPAY USDC
        uint256 maxFillAssets = pending / scaleUp; // par capacity (floor)
        uint256 fillAssets = availableAssets < maxFillAssets ? availableAssets : maxFillAssets;
        uint256 filledShares = fillAssets * scaleUp; // <= pending, EXACT multiple of scaleUp

        if (filledShares == pending && pending != 0) {
            // 100% DRAIN ⇒ close the era (zero-safe, KR-4a)
            era += 1;
            cumRemaining = PREC; // fresh factor for the next era
            totalPending = 0;
            reservedAssets += fillAssets;
            IZipUSD(zipUSD).burn(address(this), filledShares);
        } else if (filledShares != 0) {
            // PARTIAL fill — round R UP so a partial can NEVER floor R to 0 (only a true full drain hits 0)
            uint256 R = ((pending - filledShares) * PREC + pending - 1) / pending; // ceil, in [1, PREC)
            cumRemaining = (cumRemaining * R + PREC - 1) / PREC; // ceil ⇒ stays >= 1 (never 0)
            totalPending = pending - filledShares;
            reservedAssets += fillAssets;
            IZipUSD(zipUSD).burn(address(this), filledShares);
        }
        // else: zero/no-op fill — still advanced epoch + lastEpochTime, era/cumRemaining untouched.

        emit EpochSettled(epoch, era, pending, filledShares, fillAssets, availableAssets);
    }

    // --------------------------------------------------------------------- claim (par payout)
    /// @notice Claim `assets` USDC (par) to `receiver` against `requester`'s realized `claimableAssets`. Gated by
    ///         the 7540 operator approval. Effects-before-interaction.
    /// @return shares The zipUSD-equivalent claimed (`assets * scaleUp`).
    function withdraw(uint256 assets, address receiver, address requester)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (requester != msg.sender && !isOperator[requester][msg.sender]) revert NotAuthorized();
        if (assets == 0) revert ZeroAssets();
        _realize(requester);
        if (assets > claimableAssets[requester]) revert InsufficientClaimable(); // over-claim / re-claim reverts
        shares = assets * scaleUp;

        claimableAssets[requester] -= assets; // effects BEFORE interaction
        reservedAssets -= assets;
        IERC20(usdc).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, requester, assets, shares);
    }

    /// @notice Claim `shares`-worth of zipUSD-equivalent as USDC (par) to `receiver`. `redeem(shares < scaleUp)`
    ///         reverts (`assets == 0` guard) rather than a phantom zero-transfer. Gated by operator approval.
    /// @return assets The USDC paid (`shares / scaleUp`).
    function redeem(uint256 shares, address receiver, address requester)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (requester != msg.sender && !isOperator[requester][msg.sender]) revert NotAuthorized();
        if (shares == 0) revert ZeroShares();
        assets = shares / scaleUp;
        if (assets == 0) revert ZeroAssets(); // reject redeem(shares < scaleUp)
        _realize(requester);
        if (assets > claimableAssets[requester]) revert InsufficientClaimable();

        claimableAssets[requester] -= assets; // effects BEFORE interaction
        reservedAssets -= assets;
        IERC20(usdc).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, requester, assets, shares);
    }

    // --------------------------------------------------------------------- EIP-7540 operator approval
    /// @notice EIP-7540 `setOperator` (modeled on `BaseERC7540.sol:34`). Cannot set self as operator.
    ///         (The EIP-7441 `authorizeOperator` signature path is OUT of M1 scope — a deferred extension.)
    function setOperator(address operator, bool approved) external returns (bool success) {
        if (msg.sender == operator) revert CannotSetSelfAsOperator();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // --------------------------------------------------------------------- views (frontend back-pressure surface)
    /// @notice The realized-then-pure-mirrored pending/claimable for `r` (a view of what the next touch banks).
    /// @return pendingNow             The still-unfilled escrowed zipUSD after lazy realization.
    /// @return totalClaimableAssets   The USDC claimable (banked + not-yet-realized increment).
    function previewRealize(address r) external view returns (uint256 pendingNow, uint256 totalClaimableAssets) {
        return _previewRealize(r);
    }

    /// @notice EIP-7540 `pendingRedeemRequest(requestId, controller)` — the still-pending escrowed zipUSD. The
    ///         leading id is the 7540 singleton (ignored).
    function pendingRedeemRequest(uint256, address r) external view returns (uint256 pendingShares) {
        (pendingShares,) = _previewRealize(r);
    }

    /// @notice EIP-7540 `claimableRedeemRequest(requestId, controller)` — claimable in 7540 share-terms
    ///         (`claimableAssets * scaleUp`).
    function claimableRedeemRequest(uint256, address r) external view returns (uint256 claimableShares) {
        (, uint256 totalClaimableAssets) = _previewRealize(r);
        claimableShares = totalClaimableAssets * scaleUp;
    }

    /// @notice The USDC `r` could `withdraw` right now (banked + not-yet-realized).
    function maxWithdraw(address r) external view returns (uint256 maxAssets) {
        (, maxAssets) = _previewRealize(r);
    }

    /// @notice The zipUSD-share-terms `r` could `redeem` right now (`maxWithdraw * scaleUp`).
    function maxRedeem(address r) external view returns (uint256 maxShares) {
        (, uint256 totalClaimableAssets) = _previewRealize(r);
        maxShares = totalClaimableAssets * scaleUp;
    }
}
