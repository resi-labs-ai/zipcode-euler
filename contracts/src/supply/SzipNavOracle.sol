// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IICHIVault} from "../interfaces/ichi/IICHIVault.sol";
import {IGauge} from "../interfaces/hydrex/IGauge.sol";
import {IOptionToken} from "../interfaces/hydrex/IOptionToken.sol";
import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";
import {IchiAlgebraFairReserves} from "./lib/IchiAlgebraFairReserves.sol";

/// @notice The freshness face of `SzAlphaRateOracle` — issuance gates on this for the CRE-pushed cross-chain rate.
interface IXAlphaRateFresh {
    function fresh() external view returns (bool);
}

/// @notice The reservoir LP escrow collateral vault (8-B5) — only the two views the NAV needs to value the
///         LP posted as collateral (ERC4626 `convertToAssets`/`balanceOf`; the escrow is a bare 1:1 box).
interface IReservoirEscrow {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice The reservoir USDC borrow vault (8-B5) — only the outstanding-debt read the NAV subtracts.
interface IReservoirDebt {
    function debtOf(address account) external view returns (uint256);
}

/// @title SzipNavOracle
/// @notice The szipUSD junior-vault NAV-per-share oracle: the **issuance + exit pricing primitive** (NAV is not
///         display-only). It composes the junior basket's NAV on-chain — reading every quantity trustlessly across
///         the main + sidecar Safes (incl. the staked ICHI LP read off the Hydrex gauge), CRE-pushing only the
///         off-chain leg prices it cannot read on Base (the xALPHA `alphaUSD` leg; HYDX/USD), and maintaining an
///         on-chain cumulative TWAP accumulator on `navPerShare` over a governed window `W`. Consumers read a
///         bracketed share price: `navEntry = max(spot, twap)` (issuance), `navExit = min(spot, twap)` (exit),
///         each 18-dp (`1e18 = $1.00`). Two write authorities mirror the lien registry's split: the immutable
///         Forwarder pushes leg marks as reportType 7; a `DefaultCoordinator` is the sole impairment-
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
///        realized receipts) lives in the `DefaultCoordinator` (M2), which the oracle trusts. Until wired,
///        `writeProvision` reverts for everyone (fail-closed); item-10 deploy verifies the wiring before the Timelock hand-off.
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
    /// @notice Minimum wall-clock between committed TWAP checkpoints, derived from `W` in the ctor. The integral
    ///         (`cumNav`) still advances on every `poke()` with `dt>0`; this only throttles how often a NEW ring
    ///         slot is consumed, so the `CARDINALITY-1` frozen checkpoints always span `>= W` (with headroom)
    ///         regardless of poke frequency. THIS is what makes the ring immune to poke-spam — the TWAP window
    ///         can no longer be collapsed by filling slots faster than once per `obsSpacing`. See build/twap-ring.md.
    uint32 public immutable obsSpacing;

    // --------------------------------------------------------------------- wiring (Timelock-re-pointable, §17)
    /// @notice szipUSD — the supply denominator (deployed after this oracle).
    address public shareToken;
    /// @notice The zipUSD/xALPHA ICHI vault (LP reserves source). Zero ⇒ LP leg contributes 0 (M1 pre-LP).
    address public ichiVault;
    /// @notice The Hydrex gauge the LP is staked in (staked-LP balance source).
    address public gauge;
    /// @notice The Algebra TWAP window (seconds) for manipulation-resistant LP reserve reconstruction. Zero ⇒ the
    ///         LP leg reads spot `getTotalAmounts()` (M1 / non-Algebra pools — unchanged). Non-zero ⇒ `_lpValue`
    ///         reconstructs the reserves at the pool's TWAP tick (`IchiAlgebraFairReserves`), so an in-block swap
    ///         cannot move the LP mark — the build/twap-ring.md fair-LP defense-in-depth. Timelock-settable (§17);
    ///         only set once the LP is a live Algebra pool that exposes a TWAP plugin.
    uint32 public lpTwapWindow;
    /// @notice The reservoir LP escrow collateral vault (8-B5). Zero ⇒ the escrow-collateralized LP leg contributes
    ///         0 (M1 pre-loop). Closes the mid-loop blind spot: while the LP is posted as collateral it is neither
    ///         loose in the Safe nor gauge-staked, so without this it reads as gone. Timelock-settable (§17).
    address public escrowVault;
    /// @notice The reservoir USDC borrow vault (8-B5). Zero ⇒ no debt subtraction (M1 pre-loop). The strike USDC the
    ///         loop borrows is counted in the `usdc` leg, so its debt must be subtracted or NAV over-reads mid-loop.
    ///         Timelock-settable (§17).
    address public borrowVault;
    /// @notice The 8-B14 buy-and-burn Safe whose transient pre-burn szipUSD is excluded from the denominator.
    address public engineSafe;
    /// @notice The sole impairment-provision writer (M2). Zero ⇒ `writeProvision` reverts for everyone.
    address public defaultCoordinator;
    /// @notice The Base xALPHA rate oracle (`SzAlphaRateOracle`, exposing `exchangeRate()` + `fresh()`). When set,
    ///         the xALPHA NAV leg reads the rate from HERE (the CRE-pushed cross-chain rate) and **issuance gates on
    ///         its `fresh()`** (a stale cross-chain rate must not mint), while exit still prices off the last rate
    ///         (the §7 asymmetry). Zero ⇒ fall back to reading `IXAlphaRate(xAlpha)` directly (the M1 stand-in).
    address public xAlphaRateOracle;

    // --------------------------------------------------------------------- pushed-leg cache
    struct LegCache {
        uint256 price;
        uint48 ts;
    }

    /// @notice The CRE-pushed leg marks (`ts == 0` ⇒ unset).
    mapping(uint8 => LegCache) public legCache;

    // --------------------------------------------------------------------- provision
    /// @notice The impairment provision (18-dp USD), subtracted from the gross basket value. Sole writer = the
    ///         `DefaultCoordinator`.
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
    error StaleRate(); // the wired xALPHA rate oracle is stale — issuance halts (exit still prices off last rate)

    // --------------------------------------------------------------------- events
    event ShareTokenSet(address indexed szipUSD);
    event LpPositionSet(address indexed ichiVault, address indexed gauge);
    event ReservoirLegSet(address indexed escrowVault, address indexed borrowVault);
    event LpTwapWindowSet(uint32 window);
    event EngineSafeSet(address indexed engineSafe);
    event DefaultCoordinatorSet(address indexed dc);
    event XAlphaRateOracleSet(address indexed rateOracle);
    event LegPriceUpdated(uint8 indexed leg, uint256 price, uint48 ts);
    event ProvisionWritten(uint256 provision);
    event Poked(uint32 ts, uint256 cumNav);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`; Timelock-re-pointable, §17 — not renounce-frozen).
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
        // obsSpacing = ceil(1.25 * W / (CARDINALITY - 1)): the CARDINALITY-1 frozen checkpoints then span ~1.25*W
        // (worst-case >= (CARDINALITY-2)*obsSpacing right after a slot advance, still comfortably >= W). The 25%
        // headroom keeps the query checkpoint off the exact `now - W` boundary under block-time jitter.
        obsSpacing = uint32((uint256(W_) * 5 + (4 * (CARDINALITY - 1) - 1)) / (4 * (CARDINALITY - 1)));
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

    /// @notice Wire/re-point the reservoir escrow + borrow vaults (8-B5), set together. `onlyOwner` (Timelock).
    ///         Closes the mid-loop NAV blind spot: the escrow-collateralized LP is added and the strike debt
    ///         subtracted, so a `postCollateral`/`borrow`/`repay`/`withdrawCollateral` cycle is NAV-invariant.
    function setReservoirLeg(address escrowVault_, address borrowVault_) external onlyOwner {
        if (escrowVault_ == address(0) || borrowVault_ == address(0)) revert ZeroAddress();
        escrowVault = escrowVault_;
        borrowVault = borrowVault_;
        emit ReservoirLegSet(escrowVault_, borrowVault_);
    }

    /// @notice Wire/re-point the LP TWAP window (the fair-LP reconstruction window, build/twap-ring.md). Zero ⇒ the
    ///         LP leg reads spot `getTotalAmounts()` (the M1 / non-Algebra default). Set non-zero (e.g. 3600) only
    ///         once the LP is a live Algebra pool exposing a TWAP plugin, else `_lpValue` would revert `NoPlugin`.
    ///         `onlyOwner` (Timelock).
    function setLpTwapWindow(uint32 lpTwapWindow_) external onlyOwner {
        lpTwapWindow = lpTwapWindow_; // zero is a valid "use spot" value
        emit LpTwapWindowSet(lpTwapWindow_);
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

    /// @notice Wire/re-point (or unset with `address(0)`) the Base xALPHA rate oracle. When set, the xALPHA NAV leg
    ///         reads the rate from it and issuance gates on its `fresh()`. Zero ⇒ fall back to `IXAlphaRate(xAlpha)`.
    ///         `onlyOwner` (Timelock). Re-pointable, not set-once (§17 build-phase wiring).
    function setXAlphaRateOracle(address rateOracle_) external onlyOwner {
        xAlphaRateOracle = rateOracle_; // address(0) is a valid "unset / use fallback" value
        emit XAlphaRateOracleSet(rateOracle_);
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

    /// @notice Write the impairment provision. Sole caller = the `DefaultCoordinator`. Immediate (not
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
    ///      The integral (`cumNav`/`lastUpdate`) advances on EVERY call with `dt>0` so the time-weighting stays
    ///      exact; a NEW ring slot is consumed only once `obsSpacing` has elapsed since the newest committed
    ///      checkpoint, otherwise the head slot is refreshed in place. This decoupling bounds ring consumption to
    ///      one slot per `obsSpacing` so the frozen checkpoints always span `>= W` — poke-spam can refresh the
    ///      head but can no longer evict the window (build/twap-ring.md).
    function _accumulate() internal returns (bool) {
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - lastUpdate;
        if (dt == 0) return false;
        cumNav += spotNavPerShare() * uint256(dt);
        lastUpdate = nowTs;
        // advance to a fresh slot only once obsSpacing has elapsed since the newest checkpoint; else refresh in place.
        if (nowTs - observations[obsIndex].ts >= obsSpacing) {
            obsIndex = uint16((uint256(obsIndex) + 1) % CARDINALITY);
        }
        observations[obsIndex] = Observation(nowTs, cumNav);
        return true;
    }

    // --------------------------------------------------------------------- NAV composition
    /// @notice The gross junior basket value (18-dp USD, `1e18 = $1`), summed across main + sidecar; IL marked-through.
    ///         The LP is counted in ALL states (loose share + gauge-staked + escrow-collateralized) and the reservoir
    ///         strike debt is subtracted, so a `postCollateral`/`borrow`/`repay`/`withdrawCollateral` cycle is
    ///         NAV-invariant (closes the §8.2 mid-loop blind spot). Saturates at 0 (debt can never exceed the basket
    ///         in solvent operation; the floor guards the insolvent edge).
    function grossBasketValue() public view returns (uint256 value) {
        value += _bal(zipUSD); // 18-dp $1
        value += _bal(usdc) * 1e12; // 6-dp -> 18-dp $1
        value += _bal(xAlpha) * _xAlphaUSD() / 1e18;
        value += _bal(hydx) * legCache[LEG_HYDX_USD].price / 1e18;
        value += _bal(oHydx) * _oHydxUSD() / 1e18;
        value += _lpValue(_lpShares(mainSafe) + _lpShares(sidecar));
        uint256 debt = _reservoirDebt(mainSafe) + _reservoirDebt(sidecar);
        value = value > debt ? value - debt : 0;
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

    /// @dev Value ONE Safe's holdings (18-dp USD), mirroring `grossBasketValue` per-leg + LP marks (incl. the escrow
    ///      leg) minus that Safe's reservoir debt. Used by `committedValue`/`freeValue`. Saturates at 0.
    function _grossValueOf(address safe) internal view returns (uint256 value) {
        value += IERC20(zipUSD).balanceOf(safe); // 18-dp $1
        value += IERC20(usdc).balanceOf(safe) * 1e12; // 6-dp -> 18-dp $1
        value += IERC20(xAlpha).balanceOf(safe) * _xAlphaUSD() / 1e18;
        value += IERC20(hydx).balanceOf(safe) * legCache[LEG_HYDX_USD].price / 1e18;
        value += IERC20(oHydx).balanceOf(safe) * _oHydxUSD() / 1e18;
        value += _lpValue(_lpShares(safe));
        uint256 debt = _reservoirDebt(safe);
        value = value > debt ? value - debt : 0;
    }

    /// @notice The path-locked LP equity (18-dp USD): the ICHI LP in every state (loose + gauge-staked + escrow-
    ///         collateralized) across BOTH Safes, NET of the reservoir strike debt. The freeze module adds this to
    ///         `committedValue()` for its coverage floor because the LP is fenced — its only dissolution path
    ///         (`LpStrategyModule.removeLiquidity`) is coverage-gated, so it cannot reach an exit below the floor.
    ///         build/lp-path-lock.md.
    function pathLockedLpEquity() public view returns (uint256) {
        uint256 lpValue = _lpValue(_lpShares(mainSafe) + _lpShares(sidecar));
        uint256 debt = _reservoirDebt(mainSafe) + _reservoirDebt(sidecar);
        return lpValue > debt ? lpValue - debt : 0;
    }

    /// @dev LP shares held by `safe` across all states: loose ICHI share + gauge-staked + escrow-collateralized.
    ///      Zero when the LP is unwired (`ichiVault == 0`). The escrow leg is added only once `escrowVault` is wired.
    function _lpShares(address safe) internal view returns (uint256 s) {
        if (ichiVault == address(0)) return 0;
        s = IICHIVault(ichiVault).balanceOf(safe) + IGauge(gauge).balanceOf(safe);
        if (escrowVault != address(0)) {
            s += IReservoirEscrow(escrowVault).convertToAssets(IReservoirEscrow(escrowVault).balanceOf(safe));
        }
    }

    /// @notice The 18-dp USD value of `lpShares` ICHI LP shares — the LP-dissolution gate
    ///         (`LpStrategyModule.removeLiquidity` via the freeze module) reads this to bound a dissolution to the
    ///         coverage excess. Public projection of the internal pro-rata mark; 0 if the LP is unwired/empty.
    function lpShareValue(uint256 lpShares) public view returns (uint256) {
        return _lpValue(lpShares);
    }

    /// @dev 18-dp USD value of `lpShares` ICHI LP, pro-rata over the OUR-pool reserves. Returns 0 if the LP is
    ///      unwired or the vault is empty (the `supplyLp == 0` guard). One floor-division pair per call (the ≤2 wei
    ///      gross-vs-per-Safe split note still holds — combined shares floor once, per-Safe floor separately).
    function _lpValue(uint256 lpShares) internal view returns (uint256) {
        if (lpShares == 0 || ichiVault == address(0)) return 0;
        uint256 supplyLp = IICHIVault(ichiVault).totalSupply();
        if (supplyLp == 0) return 0;
        // Reserve source: spot `getTotalAmounts()` (default) OR the manipulation-resistant TWAP reconstruction
        // when `lpTwapWindow` is wired (build/twap-ring.md fair-LP). Pro-rata + leg pricing are identical either way.
        uint256 total0;
        uint256 total1;
        if (lpTwapWindow != 0) {
            (total0, total1,) = IchiAlgebraFairReserves.fairReserves(ichiVault, lpTwapWindow);
        } else {
            (total0, total1) = IICHIVault(ichiVault).getTotalAmounts();
        }
        uint256 amt0 = total0 * lpShares / supplyLp;
        uint256 amt1 = total1 * lpShares / supplyLp;
        return _tokenValue(IICHIVault(ichiVault).token0(), amt0) + _tokenValue(IICHIVault(ichiVault).token1(), amt1);
    }

    /// @dev Reservoir strike debt of `safe` in 18-dp USD (USDC 6-dp -> 18-dp). Zero if `borrowVault` unwired.
    function _reservoirDebt(address safe) internal view returns (uint256) {
        if (borrowVault == address(0)) return 0;
        return IReservoirDebt(borrowVault).debtOf(safe) * 1e12;
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
        // Cross-chain rate freshness: a stale CRE-pushed xALPHA rate must not mint (exit is unaffected — `navExit`
        // does not call this). Only enforced when the rate oracle is wired (M1 stand-in path is unchanged).
        if (xAlphaRateOracle != address(0) && !IXAlphaRateFresh(xAlphaRateOracle).fresh()) revert StaleRate();
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
        if (_legStale(LEG_ALPHA_USD) || _legStale(LEG_HYDX_USD)) return false;
        if (xAlphaRateOracle != address(0) && !IXAlphaRateFresh(xAlphaRateOracle).fresh()) return false;
        return true;
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
        // Rate source: the wired Base rate oracle (CRE-pushed cross-chain rate) when set, else the direct read
        // (M1 stand-in). Value (not freshness) is read here — freshness is gated at issuance (`navEntry`/`fresh`),
        // so `grossBasketValue`/exit keep pricing off the last good rate (the §7 asymmetry).
        address rateSrc = xAlphaRateOracle == address(0) ? xAlpha : xAlphaRateOracle;
        return IXAlphaRate(rateSrc).exchangeRate() * legCache[LEG_ALPHA_USD].price / 1e18;
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
