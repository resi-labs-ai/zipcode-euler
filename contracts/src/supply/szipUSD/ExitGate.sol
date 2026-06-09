// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBaal} from "../../interfaces/baal/IBaal.sol";
import {SzipNavOracle} from "../SzipNavOracle.sol";
import {SzipUSD} from "./SzipUSD.sol";

/// @title ExitGate
/// @notice The szipUSD junior vault's custody + issuance + exit valve (absorbs the old 8-B2 mint shaman + 8-B3
///         lock/freeze shaman). It is the **sole Baal `Loot` custodian** (holds `manager` = 2, granted post-deploy
///         by the team-admin via `setShamans`), the **sole szipUSD minter/burner**, and the **sole `ragequit`
///         caller** — so depositors hold only the transferable szipUSD (never raw Loot) and the Gate controls
///         *when* exits happen. `claude-zipcode.md` §6.4/§7; `baal-spec.md` §4/§5/§7.
///
///         Flows:
///         1. `depositFor` — NAV-proportional issuance off `SzipNavOracle.navEntry()` (round down); pulls the asset
///            into the main Safe (the basket), mints Loot to itself + transferable szipUSD to the receiver.
///         2. `requestExit` — escrow szipUSD, queue the claim; no assets move.
///         3. `processWindow` — keeper-driven (rides the harvest cadence): **pure ragequit** of each queued claim —
///            the exiter gets their pro-rata in-kind slice of the (free, main-Safe) basket (zipUSD + xALPHA), the
///            matching Loot + escrowed szipUSD are burned. No oracle on exit, no cap, no numeraire.
///         4. `burnFor` — the §7 / 8-B14 paired buy-and-burn retire (pure supply reduction, no asset payout).
///
///         The leaver's downstream path is NOT this contract: a separate Zodiac auto-dump module market-sells the
///         xALPHA leg → zipUSD on Hydrex (so they hold only zipUSD), then the existing `ZipRedemptionQueue` turns
///         that zipUSD → USDC. The Gate only ragequits the pro-rata share and burns the loot.
///
/// @dev Documented invariants (the design's accepted trade-offs):
///      - Two-token invariant: `szipUSD.totalSupply() == loot.balanceOf(gate)` at all times — every Loot mint/burn is
///        paired with an equal szipUSD mint/burn. The engine Safe's transient pre-burn szipUSD (excluded from the
///        *oracle* denominator, not here) is the only transient asymmetry, resolved on the next `burnFor`.
///      - Exit is **pure in-kind ragequit**: the share is a volatile NAV-bearing claim; you leave, you get your
///        pro-rata slice of the treasury (worth `shares × NAV/share` by construction — the slice self-prices, so no
///        oracle read is needed in the exit path; the oracle prices *issuance*). zipUSD-numeraire/cap/sweep is GONE.
///      - The freeze is structural: `processWindow` ragequits only `mainSafe`; the committed slice is in the non-RQ
///        sidecar (item 9 rotation) → unreachable. A leaver gets their share of the free (main-Safe) basket.
///      - Zero-Shares forever: the Gate never calls `mintShares`; only `mintLoot`/`burnLoot`/`ragequit`.
contract ExitGate is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- immutables
    IBaal public immutable baal;
    SzipNavOracle public immutable navOracle;
    address public immutable zipUSD; // 18-dp, $1 — a deposit asset + a basket leg (ragequit pays it in-kind)
    address public immutable xAlpha; // 18-dp — in-kind (POL-as-LM) deposit asset + a basket leg (ragequit pays it in-kind)
    uint256 public immutable tvlCap; // 18-dp USD gross-basket cap (governed; see 8-B12 overlap note)
    address public immutable loot; // baal.lootToken()
    address public immutable mainSafe; // baal.avatar() — the ragequit target / the basket

    // --------------------------------------------------------------------- set-once wiring (frozen by renounce at item-10)
    address public shareToken; // szipUSD (deployed after the Gate — its ctor takes the Gate)
    address public windowController; // the CRE operator/keeper that opens windows
    address public engineSafe; // the 8-B14 buy-and-burn Safe whose szipUSD `burnFor` retires

    // --------------------------------------------------------------------- exit queue
    struct Claim {
        address owner;
        uint256 shares;
        uint256 filled;
    }

    /// @notice The FIFO exit-intent queue (never reordered/removed; `queueHead` advances).
    Claim[] public claims;
    /// @notice The next unfilled claim index `processWindow` resumes from.
    uint256 public queueHead;

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error AlreadyWired();
    error NotWired();
    error UnsupportedAsset(address asset);
    error TvlCapExceeded();
    error NotWindowController();
    error NotClaimOwner();
    error NoSuchClaim();
    error AlreadyClosed();

    // --------------------------------------------------------------------- events
    event Deposited(address indexed receiver, address indexed asset, uint256 amount, uint256 value, uint256 shares);
    event ExitRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event ExitFilled(uint256 indexed requestId, address indexed owner, uint256 shares);
    event ExitCancelled(uint256 indexed requestId, uint256 remainder);
    event WindowProcessed(uint256 claimsFilled, uint256 queueHead);
    event Burned(uint256 amount);
    event ShareTokenSet(address indexed szipUSD);
    event WindowControllerSet(address indexed controller);
    event EngineSafeSet(address indexed engineSafe);

    constructor(address baal_, address navOracle_, address zipUSD_, address xAlpha_, uint256 tvlCap_)
        Ownable(msg.sender)
    {
        if (baal_ == address(0) || navOracle_ == address(0) || zipUSD_ == address(0) || xAlpha_ == address(0)) {
            revert ZeroAddress();
        }
        if (tvlCap_ == 0) revert ZeroAmount();
        baal = IBaal(baal_);
        navOracle = SzipNavOracle(navOracle_);
        zipUSD = zipUSD_;
        xAlpha = xAlpha_;
        tvlCap = tvlCap_;
        loot = IBaal(baal_).lootToken();
        mainSafe = IBaal(baal_).avatar();
    }

    // --------------------------------------------------------------------- set-once wiring
    /// @notice Wire the szipUSD share token (the Gate is its immutable minter). Set-once, `onlyOwner`, renounce-frozen.
    function setShareToken(address szipUSD_) external onlyOwner {
        if (shareToken != address(0)) revert AlreadyWired();
        if (szipUSD_ == address(0)) revert ZeroAddress();
        shareToken = szipUSD_;
        emit ShareTokenSet(szipUSD_);
    }

    /// @notice Wire the window controller (the CRE operator/keeper). Set-once, `onlyOwner`, renounce-frozen.
    function setWindowController(address controller_) external onlyOwner {
        if (windowController != address(0)) revert AlreadyWired();
        if (controller_ == address(0)) revert ZeroAddress();
        windowController = controller_;
        emit WindowControllerSet(controller_);
    }

    /// @notice Wire the engine Safe (the 8-B14 buy-and-burn target). Set-once, `onlyOwner`, renounce-frozen.
    function setEngineSafe(address engineSafe_) external onlyOwner {
        if (engineSafe != address(0)) revert AlreadyWired();
        if (engineSafe_ == address(0)) revert ZeroAddress();
        engineSafe = engineSafe_;
        emit EngineSafeSet(engineSafe_);
    }

    // --------------------------------------------------------------------- issuance
    /// @notice NAV-proportional issuance (absorbs the mint shaman): value the deposit via the oracle, mint Loot to
    ///         the Gate + transferable szipUSD to `receiver`, route the asset straight into the main Safe (basket).
    /// @param asset    A whitelisted basket deposit asset ({zipUSD, xALPHA}); the caller asserts NO value.
    /// @param amount   The raw token amount (the Gate must be approved by `msg.sender` for it).
    /// @param receiver The szipUSD recipient.
    /// @return shares  The szipUSD minted (== Loot minted to the Gate), round-down.
    function depositFor(address asset, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (asset != zipUSD && asset != xAlpha) revert UnsupportedAsset(asset);
        if (amount == 0) revert ZeroAmount();
        if (shareToken == address(0)) revert NotWired();

        navOracle.poke();
        uint256 navE = navOracle.navEntry(); // reverts StalePrice if a required leg is stale (issuance pauses)
        uint256 value = navOracle.valueOf(asset, amount); // the Gate owns valuation; no caller asserts a price
        if (navOracle.grossBasketValue() + value > tvlCap) revert TvlCapExceeded();

        shares = value * 1e18 / navE; // round DOWN (favor the vault)
        if (shares == 0) revert ZeroShares();

        // Pull the asset into the basket (main Safe) — the Gate keeps zero custody of it.
        IERC20(asset).safeTransferFrom(msg.sender, mainSafe, amount);

        // Mint Loot to the Gate (manager(2)) + transferable szipUSD to the receiver — paired, equal amounts.
        baal.mintLoot(_one(address(this)), _one(shares));
        SzipUSD(shareToken).mint(receiver, shares);

        emit Deposited(receiver, asset, amount, value, shares);
    }

    /// @notice A read-only quote of the szipUSD a `depositFor(asset, amount, …)` would mint right now — the UI/zap
    ///         estimate the §4/§5 zap (`ZipDepositModule.previewZap`) reads. Mirrors `depositFor`'s pricing exactly
    ///         (value the asset via `SzipNavOracle.valueOf`, divide by `navEntry()`, round DOWN) WITHOUT the
    ///         `poke()`/`mint`/cap side-effects. It is an ESTIMATE: NAV (and the staleness state) can move between
    ///         this read and the tx (the §3 `max(spot,twap)` entry bracket), so the realized `shares` may differ; in
    ///         the same block with a fresh oracle it is exact. Reverts identically to `depositFor` on an unsupported
    ///         asset, a zero amount, or a stale oracle (`navEntry()` propagates `StalePrice`).
    /// @dev    Does NOT check the TVL cap or whether `shareToken` is wired — it is a pure pricing projection; the cap
    ///         and wiring are enforced by `depositFor` at execution. View-only, so it cannot `poke()` first; it reads
    ///         the accumulator as-is (any keeper `poke()` keeps it tight).
    function previewDeposit(address asset, uint256 amount) external view returns (uint256 shares) {
        if (asset != zipUSD && asset != xAlpha) revert UnsupportedAsset(asset);
        if (amount == 0) revert ZeroAmount();
        uint256 navE = navOracle.navEntry(); // reverts StalePrice if a required leg is stale (matches depositFor)
        uint256 value = navOracle.valueOf(asset, amount);
        shares = value * 1e18 / navE; // round DOWN — identical to depositFor
    }

    // --------------------------------------------------------------------- exit intent queue
    /// @notice Signal exit intent: escrow `shares` szipUSD and queue the claim. No assets move.
    function requestExit(uint256 shares) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (shareToken == address(0)) revert NotWired();
        IERC20(shareToken).safeTransferFrom(msg.sender, address(this), shares);
        claims.push(Claim({owner: msg.sender, shares: shares, filled: 0}));
        requestId = claims.length - 1;
        emit ExitRequested(requestId, msg.sender, shares);
    }

    /// @notice Withdraw the unfilled remainder of a queued claim. Closes the claim (processWindow skips it).
    function cancelExit(uint256 requestId) external nonReentrant {
        if (requestId >= claims.length) revert NoSuchClaim();
        Claim storage c = claims[requestId];
        if (c.owner != msg.sender) revert NotClaimOwner();
        uint256 remainder = c.shares - c.filled;
        if (remainder == 0) revert AlreadyClosed();
        c.filled = c.shares; // close
        IERC20(shareToken).safeTransfer(msg.sender, remainder);
        emit ExitCancelled(requestId, remainder);
    }

    // --------------------------------------------------------------------- liquidity window (the patient exit)
    /// @notice Process the exit queue during a liquidity window (keeper-driven, rides the harvest cadence). FIFO:
    ///         for each queued claim, **pure ragequit** — the exiter gets their pro-rata in-kind slice of the
    ///         (free, main-Safe) basket (zipUSD + xALPHA), and the matching Loot + escrowed szipUSD are burned.
    ///         No oracle, no cap, no numeraire conversion. The committed slice in the non-RQ sidecar is the freeze
    ///         (structurally unreachable). xALPHA→zipUSD dump + zipUSD→USDC are separate downstream legs.
    /// @param maxClaims The max number of queued claims to process this window (gas-bounded; the keeper shards).
    function processWindow(uint256 maxClaims) external nonReentrant {
        if (msg.sender != windowController) revert NotWindowController();

        address[] memory tokens = _basketTokens(); // [zipUSD, xALPHA] sorted ascending (Baal `!order` check)
        uint256 filledCount;

        for (uint256 i = 0; i < maxClaims; i++) {
            if (queueHead >= claims.length) break; // empty / exhausted
            Claim storage c = claims[queueHead];
            uint256 s = c.shares - c.filled;
            if (s == 0) {
                queueHead++; // a cancelled/closed claim — skip it
                continue;
            }
            // Pure ragequit: the exiter gets their pro-rata in-kind slice of the (free, main-Safe) basket —
            // zipUSD + xALPHA — sent straight to them; burn the matching Loot + the escrowed szipUSD. No oracle,
            // no cap, no numeraire: you leave, you get your share. (xALPHA→zipUSD dump + zipUSD→USDC queue are
            // separate downstream legs, not this contract.)
            baal.ragequit(c.owner, 0, s, tokens);
            SzipUSD(shareToken).burn(address(this), s);

            c.filled = c.shares;
            emit ExitFilled(queueHead, c.owner, s);
            queueHead++;
            filledCount++;
        }

        emit WindowProcessed(filledCount, queueHead);
    }

    // --------------------------------------------------------------------- paired buy-and-burn (§7 / 8-B14)
    /// @notice Retire `amount` szipUSD the engine Safe bought below NAV on CoW: pure supply reduction, NO asset
    ///         payout — `burnLoot` from the Gate + burn the engine Safe's szipUSD. NAV-per-share ticks up for stayers.
    function burnFor(uint256 amount) external nonReentrant {
        if (msg.sender != windowController) revert NotWindowController();
        if (engineSafe == address(0)) revert NotWired();
        if (amount == 0) revert ZeroAmount();
        baal.burnLoot(_one(address(this)), _one(amount));
        SzipUSD(shareToken).burn(engineSafe, amount);
        emit Burned(amount);
    }

    // --------------------------------------------------------------------- views / internals
    /// @notice The number of queued claims (for off-chain / frontend enumeration).
    function claimCount() external view returns (uint256) {
        return claims.length;
    }

    /// @dev The basket tokens to ragequit, sorted strictly ascending (the Baal `!order` check, `Baal.sol:625`).
    ///      M1 basket = zipUSD + xALPHA (the harvest decomposes the ICHI LP to its underlying into the main Safe
    ///      before a window, so both legs are liquid and claimable pro-rata).
    function _basketTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        (address lo, address hi) = zipUSD < xAlpha ? (zipUSD, xAlpha) : (xAlpha, zipUSD);
        tokens[0] = lo;
        tokens[1] = hi;
    }

    function _one(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 v) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
