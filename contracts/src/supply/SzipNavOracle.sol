// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IICHIVault} from "../interfaces/ichi/IICHIVault.sol";
import {IGauge} from "../interfaces/hydrex/IGauge.sol";
import {IOptionToken} from "../interfaces/hydrex/IOptionToken.sol";
import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";

/// @title SzipNavOracle
/// @notice The szipUSD junior-vault NAV-per-share oracle: the **issuance + exit pricing primitive** (NAV is not
///         display-only). It composes the junior basket's NAV on-chain — reading every quantity trustlessly across
///         the main + sidecar Safes (incl. the staked ICHI LP read off the Hydrex gauge), CRE-pushing only the
///         off-chain leg prices it cannot read on Base (the xALPHA `alphaUSD` leg; HYDX/USD), and maintaining an
///         on-chain cumulative TWAP accumulator on `navPerShare` over a governed window `W`. Consumers read a
///         bracketed share price: `navEntry = max(spot, twap)` (issuance), `navExit = min(spot, twap)` (exit),
///         each 18-dp (`1e18 = $1.00`). Two write authorities mirror the lien registry's split: the immutable
///         Forwarder pushes leg marks as reportType 7; a set-once `DefaultCoordinator` is the sole impairment-
///         provision writer (M2). `claude-zipcode.md` §7/§12; `baal-spec.md` §3.
/// @dev Documented invariants (the security review's accepted trade-offs):
///      - The bracket defends the PROFITABLE direction both ways: `navEntry = max` so a one-block spot spike UP only
///        makes minting more expensive (a DOWN spike is ignored); `navExit = min` so an UP spike is ignored (no
///        exit-rich). Sub-window spot moves cannot be turned into a profitable mint or exit.
///      - `navExit` prices off the last good mark and MAY be stale (asymmetric by design): staleness pauses
///        *issuance* (`navEntry`/`fresh`), never *exit*. The defense is the TWAP lag (`min(spot, twap)`), so the
///        Gate MUST `poke()` before every exit/issuance read; `poke()` is permissionless so any keeper can maintain
///        it. `lastUpdate` is public for freshness audit.
///      - `writeProvision` is UNBOUNDED at the oracle by design — the bound (down <= atRisk*(1-recoveryFloor), up by
///        realized receipts) lives in the set-once `DefaultCoordinator` (M2), which the oracle trusts. Until wired,
///        `writeProvision` reverts for everyone (fail-closed); item-10 deploy verifies the wiring before renounce.
///      - The xALPHA `exchangeRate()` read is non-manipulable in production (LST stake-accounting, no pool price) but
///        in M1 is a STAND-IN mock; the production Rubicon `LiquidStakedV3` getter + supply-immutability are verified
///        at bridge integration.
///      - Genesis/first-deposit is the Gate's responsibility: the oracle returns `GENESIS_NAV` only at zero effective
///        supply; the Gate rounds shares down and is the first minter (so a pre-deposit donation cannot profit an
///        attacker). The oracle adds no first-depositor guard.
contract SzipNavOracle is ReceiverTemplate {
    // --------------------------------------------------------------------- constants
    /// @notice Genesis share price (`navPerShare0 = $1.00`, §4.2/§17), returned at zero effective supply.
    uint256 public constant GENESIS_NAV = 1e18;
    /// @notice Pushed leg: `alphaUSD` = USD per 1.0 ALPHA (`1e18 = $1`).
    uint8 public constant LEG_ALPHA_USD = 0;
    /// @notice Pushed leg: HYDX/USD = USD per 1.0 HYDX (`1e18 = $1`).
    uint8 public constant LEG_HYDX_USD = 1;
    /// @notice The number of valid leg IDs.
    uint8 public constant NUM_LEGS = 2;
    /// @notice The §4.4 reportType this oracle services (NAV leg price push).
    uint8 public constant NAV_LEG = 7;
    /// @notice The TWAP observation ring cardinality.
    uint16 public constant CARDINALITY = 65;

    // --------------------------------------------------------------------- immutables
    address public immutable zipUSD; // 18-dp, $1
    address public immutable usdc; // 6-dp, $1
    address public immutable xAlpha; // 18-dp, two-layer mark
    address public immutable hydx; // 18-dp, pushed
    address public immutable oHydx; // 18-dp, intrinsic
    address public immutable mainSafe; // free equity (Baal avatar)
    address public immutable sidecar; // committed equity (non-RQ)
    /// @notice The TWAP window (governed; locked 4h).
    uint32 public immutable W;
    /// @notice The pushed-leg staleness bound (governed).
    uint256 public immutable maxAge;
    /// @notice The per-push deviation circuit-break, in bps (governed).
    uint256 public immutable maxDeviationBps;

    // --------------------------------------------------------------------- set-once wiring (frozen by renounce)
    /// @notice szipUSD — the supply denominator (deployed after this oracle).
    address public shareToken;
    /// @notice The zipUSD/xALPHA ICHI vault (LP reserves source). Zero ⇒ LP leg contributes 0 (M1 pre-LP).
    address public ichiVault;
    /// @notice The Hydrex gauge the LP is staked in (staked-LP balance source).
    address public gauge;
    /// @notice The 8-B14 buy-and-burn Safe whose transient pre-burn szipUSD is excluded from the denominator.
    address public engineSafe;
    /// @notice The sole impairment-provision writer (M2). Zero ⇒ `writeProvision` reverts for everyone.
    address public defaultCoordinator;

    // --------------------------------------------------------------------- pushed-leg cache
    struct LegCache {
        uint256 price;
        uint48 ts;
    }

    /// @notice The CRE-pushed leg marks (`ts == 0` ⇒ unset).
    mapping(uint8 => LegCache) public legCache;

    // --------------------------------------------------------------------- provision
    /// @notice The impairment provision (18-dp USD), subtracted from the gross basket value. Sole writer = the
    ///         set-once `DefaultCoordinator`.
    uint256 public provision;

    // --------------------------------------------------------------------- TWAP accumulator
    struct Observation {
        uint32 ts;
        uint256 cum;
    }

    /// @notice The observation ring (newest at `obsIndex`).
    Observation[CARDINALITY] public observations;
    /// @notice The slot of the newest observation.
    uint16 public obsIndex;
    /// @notice The running cumulative `Σ navPerShareSpot × dt`.
    uint256 public cumNav;
    /// @notice The timestamp the accumulator was last advanced.
    uint32 public lastUpdate;

    // --------------------------------------------------------------------- errors
    error AlreadyWired();
    error NotDefaultCoordinator();
    error InvalidReportType(uint8 reportType);
    error LengthMismatch();
    error FutureTimestamp();
    error ZeroPrice();
    error InvalidLeg(uint8 leg);
    error DeviationExceeded(uint8 leg, uint256 prior, uint256 next);
    error StalePrice(uint8 leg);
    error UnknownLpToken(address token);
    error ZeroAddress();

    // --------------------------------------------------------------------- events
    event ShareTokenSet(address indexed szipUSD);
    event LpPositionSet(address indexed ichiVault, address indexed gauge);
    event EngineSafeSet(address indexed engineSafe);
    event DefaultCoordinatorSet(address indexed dc);
    event LegPriceUpdated(uint8 indexed leg, uint256 price, uint48 ts);
    event ProvisionWritten(uint256 provision);
    event Poked(uint32 ts, uint256 cumNav);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`; frozen by deploy-time renounce).
    constructor(
        address forwarder,
        address zipUSD_,
        address usdc_,
        address xAlpha_,
        address hydx_,
        address oHydx_,
        address mainSafe_,
        address sidecar_,
        uint32 W_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    ) ReceiverTemplate(forwarder) {
        if (
            zipUSD_ == address(0) || usdc_ == address(0) || xAlpha_ == address(0) || hydx_ == address(0)
                || oHydx_ == address(0) || mainSafe_ == address(0) || sidecar_ == address(0) || W_ == 0 || maxAge_ == 0
        ) revert ZeroAddress();
        zipUSD = zipUSD_;
        usdc = usdc_;
        xAlpha = xAlpha_;
        hydx = hydx_;
        oHydx = oHydx_;
        mainSafe = mainSafe_;
        sidecar = sidecar_;
        W = W_;
        maxAge = maxAge_;
        maxDeviationBps = maxDeviationBps_;
        uint32 nowTs = uint32(block.timestamp);
        observations[0] = Observation(nowTs, 0);
        lastUpdate = nowTs;
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase)
    // NOTE (2026-06-09, §17): re-pointable by the Timelock, NOT set-once — build-phase flexibility so a redeployed
    // share token / LP / engine Safe / coordinator is a one-call re-point, not a redeploy cascade. Lock down pre-prod.
    /// @notice Wire/re-point the szipUSD share token (the supply denominator). `onlyOwner` (Timelock).
    function setShareToken(address szipUSD_) external onlyOwner {
        if (szipUSD_ == address(0)) revert ZeroAddress();
        shareToken = szipUSD_;
        emit ShareTokenSet(szipUSD_);
    }

    /// @notice Wire/re-point the ICHI vault + its Hydrex gauge (the LP position). `onlyOwner` (Timelock).
    function setLpPosition(address ichiVault_, address gauge_) external onlyOwner {
        if (ichiVault_ == address(0) || gauge_ == address(0)) revert ZeroAddress();
        ichiVault = ichiVault_;
        gauge = gauge_;
        emit LpPositionSet(ichiVault_, gauge_);
    }

    /// @notice Wire/re-point the engine Safe (its transient pre-burn szipUSD is excluded). `onlyOwner` (Timelock).
    function setEngineSafe(address engineSafe_) external onlyOwner {
        if (engineSafe_ == address(0)) revert ZeroAddress();
        engineSafe = engineSafe_;
        emit EngineSafeSet(engineSafe_);
    }

    /// @notice Wire/re-point the sole impairment-provision writer (M2). `onlyOwner` (Timelock).
    function setDefaultCoordinator(address dc_) external onlyOwner {
        if (dc_ == address(0)) revert ZeroAddress();
        defaultCoordinator = dc_;
        emit DefaultCoordinatorSet(dc_);
    }

    // --------------------------------------------------------------------- write paths
    /// @notice Revaluation (§4.4 reportType 7): the Forwarder pushes a batch of off-chain leg marks. All-or-nothing.
    /// @param report The shared §4.4 envelope `abi.encode(uint8 reportType, bytes payload)`.
    function _processReport(bytes calldata report) internal override {
        (uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));
        if (reportType != NAV_LEG) revert InvalidReportType(reportType);
        (uint8[] memory legs, uint256[] memory prices, uint32 ts) =
            abi.decode(payload, (uint8[], uint256[], uint32));
        if (legs.length != prices.length) revert LengthMismatch();
        if (ts > block.timestamp) revert FutureTimestamp();
        // Advance the TWAP accumulator FIRST (book the OLD spot over [lastUpdate, now]) before the new prices apply.
        _accumulate();
        for (uint256 i = 0; i < legs.length; i++) {
            uint8 leg = legs[i];
            if (leg >= NUM_LEGS) revert InvalidLeg(leg);
            uint256 p = prices[i];
            if (p == 0) revert ZeroPrice();
            LegCache memory prior = legCache[leg];
            if (prior.ts != 0) {
                uint256 priorP = prior.price;
                uint256 diff = p > priorP ? p - priorP : priorP - p;
                if (diff * 10_000 / priorP > maxDeviationBps) revert DeviationExceeded(leg, priorP, p);
            }
            legCache[leg] = LegCache(p, uint48(ts));
            emit LegPriceUpdated(leg, p, uint48(ts));
        }
    }

    /// @notice Write the impairment provision. Sole caller = the set-once `DefaultCoordinator`. Immediate (not
    ///         TWAP-smoothed) — the next `spotNavPerShare` reflects it. The bound lives in the coordinator (M2).
    function writeProvision(uint256 newProvision) external {
        if (msg.sender != defaultCoordinator) revert NotDefaultCoordinator();
        _accumulate(); // book the pre-provision spot before the step
        provision = newProvision;
        emit ProvisionWritten(newProvision);
    }

    /// @notice Permissionlessly advance the TWAP accumulator with the current spot. The Gate/zap (and any keeper)
    ///         call this before reading at issuance/exit.
    function poke() external {
        if (_accumulate()) emit Poked(uint32(block.timestamp), cumNav);
    }

    /// @dev Book the current spot over [lastUpdate, now] into the cumulative + ring. Idempotent within a block.
    function _accumulate() internal returns (bool) {
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - lastUpdate;
        if (dt == 0) return false;
        cumNav += spotNavPerShare() * uint256(dt);
        obsIndex = uint16((uint256(obsIndex) + 1) % CARDINALITY);
        observations[obsIndex] = Observation(nowTs, cumNav);
        lastUpdate = nowTs;
        return true;
    }

    // --------------------------------------------------------------------- NAV composition
    /// @notice The gross junior basket value (18-dp USD, `1e18 = $1`), summed across main + sidecar; IL marked-through.
    function grossBasketValue() public view returns (uint256 value) {
        value += _bal(zipUSD); // 18-dp $1
        value += _bal(usdc) * 1e12; // 6-dp -> 18-dp $1
        value += _bal(xAlpha) * _xAlphaUSD() / 1e18;
        value += _bal(hydx) * legCache[LEG_HYDX_USD].price / 1e18;
        value += _bal(oHydx) * _oHydxUSD() / 1e18;
        if (ichiVault != address(0)) {
            uint256 heldShares = IICHIVault(ichiVault).balanceOf(mainSafe) + IICHIVault(ichiVault).balanceOf(sidecar)
                + IGauge(gauge).balanceOf(mainSafe) + IGauge(gauge).balanceOf(sidecar);
            if (heldShares != 0) {
                uint256 supplyLp = IICHIVault(ichiVault).totalSupply();
                if (supplyLp != 0) {
                    (uint256 total0, uint256 total1) = IICHIVault(ichiVault).getTotalAmounts();
                    uint256 amt0 = total0 * heldShares / supplyLp;
                    uint256 amt1 = total1 * heldShares / supplyLp;
                    value += _tokenValue(IICHIVault(ichiVault).token0(), amt0);
                    value += _tokenValue(IICHIVault(ichiVault).token1(), amt1);
                }
            }
        }
    }

    /// @notice The committed (sidecar-only) basket value, 18-dp USD — the §11-B / §6.4 freeze-floor read the
    ///         DurationFreezeModule bounds `release` against. ADDITIVE: `grossBasketValue()` is unchanged; this is
    ///         an INDEPENDENT per-Safe re-computation. For the five plain legs `committedValue() + freeValue()`
    ///         equals `grossBasketValue()` EXACTLY; for a split LP it is within ≤2 wei (the per-Safe pro-rata floors
    ///         twice vs once). The module only ever moves the five plain legs, so gross is exactly rotation-invariant.
    function committedValue() external view returns (uint256) {
        return _grossValueOf(sidecar);
    }

    /// @notice The free (main-only) basket value, 18-dp USD. ADDITIVE; see `committedValue`.
    function freeValue() external view returns (uint256) {
        return _grossValueOf(mainSafe);
    }

    /// @dev Value ONE Safe's holdings (18-dp USD), mirroring `grossBasketValue` per-leg + LP marks but reading a
    ///      single Safe's balances. Same `supplyLp == 0` / `ichiVault == address(0)` guards. NOT used by any
    ///      existing function — purely the per-Safe back-pressure the freeze module reads.
    function _grossValueOf(address safe) internal view returns (uint256 value) {
        value += IERC20(zipUSD).balanceOf(safe); // 18-dp $1
        value += IERC20(usdc).balanceOf(safe) * 1e12; // 6-dp -> 18-dp $1
        value += IERC20(xAlpha).balanceOf(safe) * _xAlphaUSD() / 1e18;
        value += IERC20(hydx).balanceOf(safe) * legCache[LEG_HYDX_USD].price / 1e18;
        value += IERC20(oHydx).balanceOf(safe) * _oHydxUSD() / 1e18;
        if (ichiVault != address(0)) {
            uint256 heldShares = IICHIVault(ichiVault).balanceOf(safe) + IGauge(gauge).balanceOf(safe);
            if (heldShares != 0) {
                uint256 supplyLp = IICHIVault(ichiVault).totalSupply();
                if (supplyLp != 0) {
                    (uint256 total0, uint256 total1) = IICHIVault(ichiVault).getTotalAmounts();
                    uint256 amt0 = total0 * heldShares / supplyLp;
                    uint256 amt1 = total1 * heldShares / supplyLp;
                    value += _tokenValue(IICHIVault(ichiVault).token0(), amt0);
                    value += _tokenValue(IICHIVault(ichiVault).token1(), amt1);
                }
            }
        }
    }

    /// @notice The live (spot) szipUSD NAV-per-share, 18-dp. Returns `GENESIS_NAV` at zero effective supply.
    function spotNavPerShare() public view returns (uint256) {
        uint256 supply = _effectiveSupply();
        if (supply == 0) return GENESIS_NAV;
        uint256 gross = grossBasketValue();
        uint256 net = gross > provision ? gross - provision : 0;
        return net * 1e18 / supply;
    }

    /// @notice The time-weighted (windowed `W`) szipUSD NAV-per-share, 18-dp. Falls back to spot before `W` of history.
    function twapNavPerShare() public view returns (uint256) {
        uint256 spot = spotNavPerShare();
        uint32 nowTs = uint32(block.timestamp);
        uint256 cumNow = cumNav + spot * uint256(nowTs - lastUpdate);
        uint32 target = nowTs > W ? nowTs - W : 0;
        bool found;
        uint32 foundTs;
        uint256 foundCum;
        uint256 idx = obsIndex;
        for (uint256 i = 0; i < CARDINALITY; i++) {
            Observation memory o = observations[idx];
            if (o.ts != 0 && o.ts <= target) {
                found = true;
                foundTs = o.ts;
                foundCum = o.cum;
                break;
            }
            idx = idx == 0 ? uint256(CARDINALITY) - 1 : idx - 1;
        }
        if (!found || foundTs == nowTs) return spot;
        return (cumNow - foundCum) / (nowTs - foundTs);
    }

    // --------------------------------------------------------------------- bracket reads (consumer surface)
    /// @notice The issuance price `max(spot, twap)`. Reverts `StalePrice` if either required pushed leg is stale.
    function navEntry() external view returns (uint256) {
        if (_legStale(LEG_ALPHA_USD)) revert StalePrice(LEG_ALPHA_USD);
        if (_legStale(LEG_HYDX_USD)) revert StalePrice(LEG_HYDX_USD);
        uint256 s = spotNavPerShare();
        uint256 t = twapNavPerShare();
        return s > t ? s : t;
    }

    /// @notice The exit price `min(spot, twap)`. Does NOT revert on staleness (prices off the last good mark).
    function navExit() external view returns (uint256) {
        uint256 s = spotNavPerShare();
        uint256 t = twapNavPerShare();
        return s < t ? s : t;
    }

    /// @notice True iff both required pushed legs are within `maxAge` (the §4 `navOracle.fresh()` issuance guard).
    function fresh() public view returns (bool) {
        return !_legStale(LEG_ALPHA_USD) && !_legStale(LEG_HYDX_USD);
    }

    // --------------------------------------------------------------------- internals
    function _legStale(uint8 leg) internal view returns (bool) {
        uint48 ts = legCache[leg].ts;
        if (ts == 0) return true;
        return block.timestamp - ts > maxAge;
    }

    function _bal(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(mainSafe) + IERC20(token).balanceOf(sidecar);
    }

    /// @dev USD per 1.0 xALPHA (18-dp): on-chain LST exchangeRate × the pushed alphaUSD.
    function _xAlphaUSD() internal view returns (uint256) {
        return IXAlphaRate(xAlpha).exchangeRate() * legCache[LEG_ALPHA_USD].price / 1e18;
    }

    /// @dev USD per 1.0 oHYDX (18-dp): intrinsic = HYDX/USD × (100 - discount)/100, discount read on-chain.
    function _oHydxUSD() internal view returns (uint256) {
        return legCache[LEG_HYDX_USD].price * (100 - IOptionToken(oHydx).discount()) / 100;
    }

    /// @dev The per-whole-token USD mark (`1e18 = $1`) for a valid LP reserve token. OUR ICHI vault is the
    ///      zipUSD/xALPHA pool, so `token0`/`token1` must be zipUSD or xAlpha (both 18-dp) — anything else is a
    ///      wrong/spoofed vault (fail-closed).
    function _legPriceOfToken(address token) internal view returns (uint256) {
        if (token == zipUSD) return 1e18;
        if (token == xAlpha) return _xAlphaUSD();
        revert UnknownLpToken(token);
    }

    /// @dev 18-dp USD value of `amt` (18-dp) of an LP reserve token.
    function _tokenValue(address token, uint256 amt) internal view returns (uint256) {
        return amt * _legPriceOfToken(token) / 1e18;
    }

    /// @notice The per-asset 18-dp USD value of a deposit `amount` of `asset` — the issuance valuation seam the
    ///         Exit Gate reads (the oracle owns valuation; no caller asserts a price, §3.4/§7). Supports the
    ///         whitelisted basket deposit assets {zipUSD, xAlpha} (both 18-dp); reverts `UnknownLpToken` for any
    ///         other asset (fail-closed). Public projection of `_tokenValue`/`_legPriceOfToken` — additive, no
    ///         behavior change to any existing function.
    function valueOf(address asset, uint256 amount) public view returns (uint256) {
        return _tokenValue(asset, amount);
    }

    /// @dev szipUSD total supply net of the engine Safe's transient pre-burn balance. Zero before wiring/genesis.
    function _effectiveSupply() internal view returns (uint256) {
        if (shareToken == address(0)) return 0;
        uint256 ts = IERC20(shareToken).totalSupply();
        uint256 pend = engineSafe == address(0) ? 0 : IERC20(shareToken).balanceOf(engineSafe);
        return ts > pend ? ts - pend : 0;
    }
}
