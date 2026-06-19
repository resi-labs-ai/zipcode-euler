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
///         by the team-admin via `setShamans`) and the **sole szipUSD minter/burner** — so depositors hold only
///         the transferable szipUSD (never raw Loot) and the Gate controls *when* exits happen. The kept design
///         wires NO `ragequit`. `claude-zipcode.md` §6.4/§7; `baal-spec.md` §4/§5/§7.
///
///         Flows:
///         1. `depositFor` — NAV-proportional issuance off `SzipNavOracle.navEntry()` (round down); pulls the asset
///            into the main Safe (the basket), mints Loot to itself + transferable szipUSD to the receiver.
///         2. `burnFor` — the §7 / 8-B14 paired buy-and-burn retire (pure supply reduction, no asset payout): the
///            ONLY exit executor. The exit path is now the CoW book — an exiter rests a CoW sell order, the treasury
///            (`SzipBuyBurnModule`) or an external buyer fills it, and the bought szipUSD is retired here via
///            `burnFor`. The forfeiting `requestExit`/`processWindow` on-chain queue is RETIRED (credit-union.md C3):
///            it ragequit the FULL claim against the free main-Safe basket, so an exiter at utilization `U` forfeited
///            `U` of their equity to stayers. That confiscation is replaced by the CoW buy-and-burn rail.
///
/// @dev Documented invariants (the design's accepted trade-offs):
///      - Two-token invariant: `szipUSD.totalSupply() == loot.balanceOf(gate)` at all times — every Loot mint/burn is
///        paired with an equal szipUSD mint/burn. The engine Safe's transient pre-burn szipUSD (excluded from the
///        *oracle* denominator, not here) is the only transient asymmetry, resolved on the next `burnFor`.
///      - Exit is the **CoW book**: a holder rests a SELL szipUSD order; the treasury's resting buy-and-burn bid
///        (`SzipBuyBurnModule`, priced off `navExit × (1 − d)`) or an external buyer fills it, and the bought szipUSD
///        is retired here via `burnFor`. NO in-kind ragequit, no on-chain forfeiting queue. The oracle prices
///        *issuance* (`navEntry`) and the buy-and-burn bid (`navExit`). zipUSD-numeraire/cap/sweep is GONE.
///      - Zero-Shares forever: the Gate never calls `mintShares`; only `mintLoot`/`burnLoot`.
contract ExitGate is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- wiring (Timelock-settable; build phase)
    // NOTE (2026-06-09, §17): all wiring below is Timelock-settable, NOT immutable — build-phase flexibility so a
    // redeployed Baal substrate / oracle / token / safe is a one-call re-point, not a redeploy cascade. Lock pre-prod.
    IBaal public baal;
    SzipNavOracle public navOracle;
    address public zipUSD; // 18-dp, $1 — a deposit asset + a basket leg
    address public xAlpha; // 18-dp — (POL-as-LM) deposit asset + a basket leg
    uint256 public tvlCap; // 18-dp USD gross-basket cap (governed; see 8-B12 overlap note)
    address public loot; // baal.lootToken()
    address public juniorTrancheSafe; // baal.avatar() — the main Safe / the basket
    address public shareToken; // szipUSD (deployed after the Gate — its ctor takes the Gate)
    address public windowController; // the CRE operator/keeper that opens windows
    address public juniorTrancheEngine; // the 8-B14 buy-and-burn Safe whose szipUSD `burnFor` retires

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error AlreadyWired();
    error NotWired();
    error UnsupportedAsset(address asset);
    error TvlCapExceeded();
    error NotWindowController();

    // --------------------------------------------------------------------- events
    event Deposited(address indexed receiver, address indexed asset, uint256 amount, uint256 value, uint256 shares);
    event Burned(uint256 amount);
    event ShareTokenSet(address indexed szipUSD);
    event WindowControllerSet(address indexed controller);
    event EngineSafeSet(address indexed juniorTrancheEngine);
    event BaalSet(address indexed baal, address loot, address juniorTrancheSafe);
    event NavOracleSet(address indexed navOracle);
    event TokensSet(address indexed zipUSD, address indexed xAlpha);
    event TvlCapSet(uint256 tvlCap);

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
        juniorTrancheSafe = IBaal(baal_).avatar();
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase)
    /// @notice Wire/re-point the szipUSD share token. `onlyOwner` (Timelock), build-phase flexibility.
    function setShareToken(address szipUSD_) external onlyOwner {
        if (szipUSD_ == address(0)) revert ZeroAddress();
        shareToken = szipUSD_;
        emit ShareTokenSet(szipUSD_);
    }

    /// @notice Wire/re-point the window controller (the CRE operator/keeper). `onlyOwner` (Timelock).
    function setWindowController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        windowController = controller_;
        emit WindowControllerSet(controller_);
    }

    /// @notice Wire/re-point the engine Safe (the 8-B14 buy-and-burn target). `onlyOwner` (Timelock).
    function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
        if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
        juniorTrancheEngine = juniorTrancheEngine_;
        emit EngineSafeSet(juniorTrancheEngine_);
    }

    /// @notice Re-point the Baal substrate (re-derives `loot` + `juniorTrancheSafe`). `onlyOwner` (Timelock), build-phase.
    function setBaal(address baal_) external onlyOwner {
        if (baal_ == address(0)) revert ZeroAddress();
        baal = IBaal(baal_);
        loot = IBaal(baal_).lootToken();
        juniorTrancheSafe = IBaal(baal_).avatar();
        emit BaalSet(baal_, loot, juniorTrancheSafe);
    }

    /// @notice Re-point the NAV oracle. `onlyOwner` (Timelock), build-phase.
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert ZeroAddress();
        navOracle = SzipNavOracle(navOracle_);
        emit NavOracleSet(navOracle_);
    }

    /// @notice Re-point the zipUSD + xALPHA basket-leg/deposit tokens. `onlyOwner` (Timelock), build-phase.
    function setTokens(address zipUSD_, address xAlpha_) external onlyOwner {
        if (zipUSD_ == address(0) || xAlpha_ == address(0)) revert ZeroAddress();
        zipUSD = zipUSD_;
        xAlpha = xAlpha_;
        emit TokensSet(zipUSD_, xAlpha_);
    }

    /// @notice Re-set the governed gross-basket TVL cap. `onlyOwner` (Timelock).
    function setTvlCap(uint256 tvlCap_) external onlyOwner {
        if (tvlCap_ == 0) revert ZeroAmount();
        tvlCap = tvlCap_;
        emit TvlCapSet(tvlCap_);
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
        IERC20(asset).safeTransferFrom(msg.sender, juniorTrancheSafe, amount);

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

    // --------------------------------------------------------------------- paired buy-and-burn (§7 / 8-B14)
    /// @notice Retire `amount` szipUSD the engine Safe bought below NAV on CoW: pure supply reduction, NO asset
    ///         payout — `burnLoot` from the Gate + burn the engine Safe's szipUSD. NAV-per-share ticks up for stayers.
    function burnFor(uint256 amount) external nonReentrant {
        if (msg.sender != windowController) revert NotWindowController();
        if (juniorTrancheEngine == address(0)) revert NotWired();
        if (amount == 0) revert ZeroAmount();
        baal.burnLoot(_one(address(this)), _one(amount));
        SzipUSD(shareToken).burn(juniorTrancheEngine, amount);
        emit Burned(amount);
    }

    // --------------------------------------------------------------------- internals
    function _one(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 v) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
