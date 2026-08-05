// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IICHIVault} from "../interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../interfaces/algebra/IAlgebraPool.sol";
import {IAlgebraOraclePlugin} from "../interfaces/algebra/IAlgebraOraclePlugin.sol";
import {IGauge} from "../interfaces/hydrex/IGauge.sol";
import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";
import {IchiAlgebraFairReserves} from "./lib/IchiAlgebraFairReserves.sol";

/// @notice The freshness + last-update face of `SzAlphaRateOracle` — issuance gates on `fresh()` for the CRE-pushed
///         cross-chain rate; `lastUpdate()` (the 964 read-time of the latest push, `0` ⇒ unset) is folded into
///         `oldestRequiredLegTs()` so a resting §7 buy-burn bid's freshness anchor reflects the rate leg too (SEC-13).
interface IXAlphaRateFresh {
    function fresh() external view returns (bool);
    function lastUpdate() external view returns (uint48);
    function maxStaleness() external view returns (uint256);
}

/// @notice The farm utility LP escrow collateral vault (8-B5) — only the two views the NAV needs to value the
///         LP posted as collateral (ERC4626 `convertToAssets`/`balanceOf`; the escrow is a bare 1:1 box).
interface IFarmUtilityEscrow {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice The farm utility USDC borrow vault (8-B5) — only the outstanding-debt read the NAV subtracts.
interface IFarmUtilityDebt {
    function debtOf(address account) external view returns (uint256);
}

/// @notice The `ZipRedemptionQueue` receivables face (SEC/M-2): the in-flight senior-redemption value that has left
///         the `juniorTrancheSafe` but is still owned by it — escrowed-pending zipUSD (18-dp $1) plus filled-but-
///         unclaimed USDC (6-dp $1). Reading these closes the off-ramp NAV undercount: during the request→claim
///         window the value is off the Safe (so `_bal` misses it) but economically still basket equity. Both are
///         trivial storage getters (cannot revert), so folding them into `grossBasketValue` adds no brick surface.
interface IZipRedemptionQueueReceivables {
    function pendingRedeemRequest(uint256 requestId, address requester) external view returns (uint256);
    function maxWithdraw(address requester) external view returns (uint256);
}

/// @title SzipNavOracle
/// @notice The szipUSD junior-vault NAV-per-share oracle: the **issuance + exit pricing primitive** (NAV is not
///         display-only). It composes the junior basket's NAV on-chain — reading every quantity trustlessly across
///         the main + juniorTrancheSidecar Safes (incl. the staked ICHI LP read off the Hydrex gauge), CRE-pushing only the
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
///        *issuance* (`navEntry`/`fresh`), never *exit*. The TWAP bracket (`min`/`max(spot, twap)`) ATTENUATES an
///        in-block spot move but does NOT eliminate it: `twapNavPerShare` values the leading `[lastUpdate, now]`
///        segment at the current spot with weight `g/W` (`g = now - lastUpdate`), so a one-block move still leaks
///        `~(g/W)·Δspot` into the read. `poke()` keeps `g` small only under honest keeper liveness — it CANNOT
///        un-weight a spot already moved this block (it books the same spot over the same gap). The only in-block-
///        manipulable leg is the ICHI LP spot reserves when `lpTwapWindow == 0`; its STRUCTURAL defense is
///        `lpTwapWindow != 0` (the fair-reserves TWAP tick), NOT the bracket. Deploy-ordering: do not fund the LP
///        with `lpTwapWindow == 0`, nor open exit/issuance, inside the first `W` of deployed life — the ring falls
///        back to spot until it holds `W` of history. Consumers SHOULD `poke()` before reading (the Gate and the
///        buy-burn module do); `poke()` is permissionless so any keeper can maintain it; `lastUpdate` is public for
///        freshness audit.
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
    address public immutable hydx; // 18-dp; marked $0 in NAV (see grossBasketValue) — kept for freeze-module wiring
    address public immutable oHydx; // 18-dp; marked $0 in NAV (see grossBasketValue) — kept for freeze-module wiring
    address public immutable juniorTrancheSafe; // free equity (Baal avatar)
    address public immutable juniorTrancheSidecar; // committed equity (non-RQ)
    /// @notice The TWAP window (governed, set at deploy via `NAV_W`; default 1h / `W=3600`).
    uint32 public immutable W;
    /// @notice The pushed-leg staleness bound (governed).
    uint256 public immutable maxAge;
    /// @notice Minimum wall-clock between committed TWAP checkpoints, derived from `W` in the ctor. The integral
    ///         (`cumNav`) still advances on every `poke()` with `dt>0`; this only throttles how often a NEW ring
    ///         slot is consumed, so the `CARDINALITY-1` frozen checkpoints always span `>= W` (with headroom)
    ///         regardless of poke frequency. THIS is what makes the ring immune to poke-spam — the TWAP window
    ///         can no longer be collapsed by filling slots faster than once per `obsSpacing`.
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
    ///         cannot move the LP mark (the fair-LP defense-in-depth). Timelock-settable (§17);
    ///         only set once the LP is a live Algebra pool that exposes a TWAP plugin.
    uint32 public lpTwapWindow;
    /// @notice The farm utility LP escrow collateral vault (8-B5). Zero ⇒ the escrow-collateralized LP leg contributes
    ///         0 (M1 pre-loop). Closes the mid-loop blind spot: while the LP is posted as collateral it is neither
    ///         loose in the Safe nor gauge-staked, so without this it reads as gone. Timelock-settable (§17).
    address public escrowVault;
    /// @notice The farm utility USDC borrow vault (8-B5). Zero ⇒ no debt subtraction (M1 pre-loop). The strike USDC the
    ///         loop borrows is counted in the `usdc` leg, so its debt must be subtracted or NAV over-reads mid-loop.
    ///         Timelock-settable (§17).
    address public borrowVault;
    /// @notice The 8-B14 buy-and-burn Safe whose transient pre-burn szipUSD is excluded from the denominator.
    address public juniorTrancheEngine;
    /// @notice The sole impairment-provision writer (M2). Zero ⇒ `writeProvision` reverts for everyone.
    address public defaultCoordinator;
    /// @notice The Base xALPHA rate oracle (`SzAlphaRateOracle`, exposing `exchangeRate()` + `fresh()`). When set,
    ///         the xALPHA NAV leg reads the rate from HERE (the CRE-pushed cross-chain rate) and **issuance gates on
    ///         its `fresh()`** (a stale cross-chain rate must not mint), while exit still prices off the last rate
    ///         (the §7 asymmetry). Zero ⇒ fall back to reading `IXAlphaRate(xAlpha)` directly (the M1 stand-in).
    address public xAlphaRateOracle;
    /// @notice The `ZipRedemptionQueue` (SEC/M-2): the senior par off-ramp sink whose in-flight receivables are added
    ///         back to the basket to close the off-ramp NAV undercount. Zero ⇒ the receivables leg contributes 0 (the
    ///         v0 / pre-off-ramp state — nothing is ever escrowed, so nothing to count). Timelock-settable (§17); the
    ///         attributed requester is always `juniorTrancheSafe` (the rq Safe the OffRampModule drives).
    address public redemptionQueue;

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
    error StalePrice(uint8 leg);
    error UnknownLpToken(address token);
    error ZeroAddress();
    /// @notice `setJuniorTrancheEngine` was given anything other than `juniorTrancheSafe`. The NAV numerator counts
    ///         the safe while the denominator excludes the engine, so the two must be the same address.
    error EngineMustEqualSafe(address given, address juniorTrancheSafe);
    error StaleRate(); // the wired xALPHA rate oracle is stale — issuance halts (exit still prices off last rate)
    error StaleReport(); // a leg push not strictly newer than the cached mark (replay / out-of-order). Mirrors `SzAlphaRateOracle`.
    error RateUnseeded(); // the xALPHA exchange rate was never seeded (genesis/uninitialized, ≠ stale) — fail closed rather than silently value xALPHA at 0
    error LpTwapPluginNotReady(); // setLpTwapWindow(>0) against a pool with no plugin / an uninitialized plugin — would brick every NAV read; reject at set-time
    error RedemptionQueueNotReady(); // setRedemptionQueue(non-zero) with no code / missing the receivables getters — would brick every NAV read; reject at set-time
    /// @notice `setLpTwapWindow(0)` while an LP position is wired. Zero prices counted LP off live pool reserves,
    ///         which an in-block swap moves. That was the documented escape from a halted TWAP, and it is the wrong
    ///         one: if the plugin dies while the LP holds most of the treasury, falling back to spot hands an
    ///         attacker the mark for the majority of NAV. Halting is the correct end state. Recovery is
    ///         `setLpPosition` onto a pool with a live plugin, or unwinding the LP.
    error LpWiredCannotUseSpot();

    // --------------------------------------------------------------------- events
    event ShareTokenSet(address indexed szipUSD);
    event LpPositionSet(address indexed ichiVault, address indexed gauge);
    event FarmUtilityLegSet(address indexed escrowVault, address indexed borrowVault);
    event LpTwapWindowSet(uint32 window);
    event EngineSafeSet(address indexed juniorTrancheEngine);
    event DefaultCoordinatorSet(address indexed dc);
    event XAlphaRateOracleSet(address indexed rateOracle);
    event RedemptionQueueSet(address indexed redemptionQueue);
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
        address juniorTrancheSafe_,
        address juniorTrancheSidecar_,
        uint32 W_,
        uint256 maxAge_
    ) ReceiverTemplate(forwarder) {
        if (
            zipUSD_ == address(0) || usdc_ == address(0) || xAlpha_ == address(0) || hydx_ == address(0)
                || oHydx_ == address(0) || juniorTrancheSafe_ == address(0) || juniorTrancheSidecar_ == address(0) || W_ == 0 || maxAge_ == 0
        ) revert ZeroAddress();
        zipUSD = zipUSD_;
        usdc = usdc_;
        xAlpha = xAlpha_;
        hydx = hydx_;
        oHydx = oHydx_;
        juniorTrancheSafe = juniorTrancheSafe_;
        juniorTrancheSidecar = juniorTrancheSidecar_;
        W = W_;
        maxAge = maxAge_;
        // obsSpacing = ceil(1.25 * W / (CARDINALITY - 1)): the CARDINALITY-1 frozen checkpoints then span ~1.25*W
        // (worst-case >= (CARDINALITY-2)*obsSpacing right after a slot advance, still comfortably >= W). The 25%
        // headroom keeps the query checkpoint off the exact `now - W` boundary under block-time jitter.
        obsSpacing = uint32((uint256(W_) * 5 + (4 * (CARDINALITY - 1) - 1)) / (4 * (CARDINALITY - 1)));
        uint32 nowTs = uint32(block.timestamp);
        observations[0] = Observation(nowTs, 0);
        lastUpdate = nowTs;
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase)
    // NOTE (§17): re-pointable by the Timelock, NOT set-once — build-phase flexibility so a redeployed
    // share token / LP / engine Safe / coordinator is a one-call re-point, not a redeploy cascade. Lock down pre-prod.

    /// @dev Best-effort TWAP checkpoint before a NAV-input re-point: books [lastUpdate, now] at the OLD
    ///      configuration's spot so the change doesn't retroactively re-weight elapsed history at the NEW spot
    ///      (the setter-vs-write-path checkpoint asymmetry). MUST be best-effort, never mandatory: during an
    ///      outage the basket walk reverts, and a hard checkpoint here would brick the very setters that are the
    ///      recovery levers (`setFarmUtilityLeg(0,0)`, `setLpTwapWindow(0)`, rate re-points). The skipped
    ///      checkpoint in that case is unavoidable — correct history is uncomputable while a leg is broken — and
    ///      the residue is bounded by the consumer brackets (`navEntry = max(spot,twap)`, `navExit = min(spot,twap)`).
    function _checkpointBestEffort() internal {
        try this.poke() {} catch {}
    }

    /// @notice Wire/re-point the szipUSD share token (the supply denominator). `onlyOwner` (Timelock).
    function setShareToken(address szipUSD_) external onlyOwner {
        if (szipUSD_ == address(0)) revert ZeroAddress();
        _checkpointBestEffort();
        shareToken = szipUSD_;
        emit ShareTokenSet(szipUSD_);
    }

    /// @notice Wire/re-point the ICHI vault + its Hydrex gauge (the LP position). `onlyOwner` (Timelock).
    function setLpPosition(address ichiVault_, address gauge_) external onlyOwner {
        if (ichiVault_ == address(0) || gauge_ == address(0)) revert ZeroAddress();
        _checkpointBestEffort();
        ichiVault = ichiVault_;
        gauge = gauge_;
        // SEC-10: if a non-zero LP-TWAP window is already live, the re-pointed vault must itself
        // satisfy the readiness invariant — else every LP-containing NAV read would brick (fail-closed) at
        // read-time, irrecoverable after renounce. Re-assert against the NEW vault (the same check `setLpTwapWindow`
        // runs at arm-time), so the invariant holds at BOTH wiring sites, not just where the window is armed.
        if (lpTwapWindow != 0) _assertLpTwapReady();
        emit LpPositionSet(ichiVault_, gauge_);
    }

    /// @notice Wire/re-point the farm utility escrow + borrow vaults (8-B5), set together. `onlyOwner` (Timelock).
    ///         Closes the mid-loop NAV blind spot: the escrow-collateralized LP is added and the strike debt
    ///         subtracted, so a `postCollateral`/`borrow`/`repay`/`withdrawCollateral` cycle is NAV-invariant.
    ///         `(0, 0)` is a valid ATOMIC UNSET — the emergency lever for a regressed escrow/borrow-vault view
    ///         (`convertToAssets`/`debtOf` reverting would otherwise freeze `_accumulate()` and every NAV consumer
    ///         with no recovery path). Both-or-neither: a mixed zero/non-zero pair is rejected, since a half-wired
    ///         leg counts escrow LP without its debt (or vice versa) and silently misprices NAV. Use the unset with
    ///         eyes open: mid-loop it removes escrow LP AND debt from the basket, understating NAV by the loop
    ///         equity — an entry-side arb while engaged — so pause issuance first and re-wire as soon as the
    ///         dependency is healthy. Mirrors the `setLpTwapWindow(0)` emergency-lever pattern.
    function setFarmUtilityLeg(address escrowVault_, address borrowVault_) external onlyOwner {
        if ((escrowVault_ == address(0)) != (borrowVault_ == address(0))) revert ZeroAddress();
        _checkpointBestEffort();
        escrowVault = escrowVault_;
        borrowVault = borrowVault_;
        emit FarmUtilityLegSet(escrowVault_, borrowVault_);
    }

    /// @notice Wire/re-point the LP TWAP window (the fair-LP reconstruction window). Zero ⇒ the
    ///         LP leg reads spot `getTotalAmounts()` (the M1 / non-Algebra default) — unconditionally valid. Set
    ///         non-zero (e.g. 3600) only once the LP is a live Algebra pool exposing a TWAP plugin, else every NAV
    ///         read (`navEntry`/`navExit`/`grossBasketValue` via `_lpValue`→`fairReserves`) would brick.
    /// @dev SEC-10: a non-zero window is validated at set-time — it requires `ichiVault` wired and the vault's pool
    ///      to expose a plugin that reports `isInitialized() == true`, else reverts `LpTwapPluginNotReady()`. This
    ///      guards ONLY the gross "no plugin / uninitialized plugin" brick. `isInitialized() == true` is a
    ///      NECESSARY-NOT-SUFFICIENT precheck: a window longer than the plugin's accumulated history (a
    ///      replaced/reset plugin re-accumulating) still fails closed at read-time — now as the typed, self-healing
    ///      `LpTwapHistoryTooShort(plugin, readyAt)` (see `IchiAlgebraFairReserves` + `lpTwapStatus()`), which
    ///      clears unaided at `readyAt`. `setLpTwapWindow(0)` remains the emergency lever, but use it with eyes
    ///      open: zero values counted LP at SPOT — the manipulable surface the LP-funding gate exists to keep off
    ///      safety paths — so prefer waiting out `readyAt` over reflexively zeroing. `onlyOwner` (Timelock).
    function setLpTwapWindow(uint32 lpTwapWindow_) external onlyOwner {
        if (lpTwapWindow_ != 0) _assertLpTwapReady();
        // Once an LP position is wired, spot is no longer an available valuation. Zero is still legal BEFORE the
        // LP cutover (the M1 posture, where `_lpValue` returns 0 at the `lpShares == 0` guard and never reaches
        // the branch), so this closes the fallback without blocking the pre-LP deploy. A different non-zero window
        // remains settable, so repointing to a working pool is unaffected.
        if (lpTwapWindow_ == 0 && ichiVault != address(0)) revert LpWiredCannotUseSpot();
        _checkpointBestEffort();
        lpTwapWindow = lpTwapWindow_;
        emit LpTwapWindowSet(lpTwapWindow_);
    }

    /// @notice Non-reverting halt-status probe of the LP-TWAP history gate. `ready == false` ⇒ every LP-containing
    ///         NAV read (`navEntry`/`navExit`/`grossBasketValue` and the coverage reads behind it) currently
    ///         reverts `LpTwapHistoryTooShort(plugin, readyAt)` — the pool's Algebra plugin was replaced/reset and
    ///         is re-accumulating history; reads resume unaided at `readyAt` (`readyAt == 0` ⇒ no initialized
    ///         plugin at all, no ETA). `lpTwapWindow == 0` / LP unwired ⇒ the TWAP is not in play ⇒ ready. CRE
    ///         (`cre/buyburn-bid`) polls this before quoting so a halt surfaces as "plugin X replaced, resuming at
    ///         readyAt" + a skipped round instead of an opaque errored run.
    function lpTwapStatus() external view returns (bool ready, address plugin, uint256 readyAt) {
        if (lpTwapWindow == 0 || ichiVault == address(0)) return (true, address(0), 0);
        return IchiAlgebraFairReserves.historyStatus(ichiVault, lpTwapWindow);
    }

    /// @dev SEC-10: assert the LP-TWAP readiness invariant — a non-zero `lpTwapWindow` requires
    ///      `ichiVault` wired and its pool's plugin present + `isInitialized()`. Shared by `setLpTwapWindow` (arm
    ///      the window) and `setLpPosition` (re-point the vault under a live window) so a non-zero window can never
    ///      coexist with an unready vault — the state that bricks every LP-containing NAV read. `isInitialized()`
    ///      is necessary-not-sufficient (a window longer than the plugin's history still fails closed at read-time,
    ///      recoverable via `setLpTwapWindow(0)` while ownership is live); see `setLpTwapWindow` NatSpec.
    function _assertLpTwapReady() internal view {
        if (ichiVault == address(0)) revert LpTwapPluginNotReady();
        address pool = IICHIVault(ichiVault).pool();
        address plugin = IAlgebraPool(pool).plugin();
        if (plugin == address(0) || !IAlgebraOraclePlugin(plugin).isInitialized()) {
            revert LpTwapPluginNotReady();
        }
    }

    /// @notice Wire/re-point the engine Safe (its transient pre-burn szipUSD is excluded). `onlyOwner` (Timelock).
    /// @dev  MUST equal `juniorTrancheSafe`. They are ONE address with two role names — see
    ///       `docs/safe-identities.md`: "the SAME address as juniorTrancheSafe, but a distinct role... Deploy wires
    ///       it equal to the basket Safe; kept distinct for role clarity." Nothing enforced that until now.
    ///       WHY IT MATTERS: `grossBasketValue` counts assets on `juniorTrancheSafe`/`juniorTrancheSidecar`, while
    ///       `_effectiveSupply` subtracts szipUSD held by `juniorTrancheEngine`. The two agree ONLY because the
    ///       addresses coincide. Diverge them and the engine's LP, escrow collateral, farm-utility debt and every
    ///       Sell/Exercise/Recycle proceed go uncounted while the denominator still shrinks: `grossBasketValue`,
    ///       `spotNavPerShare` and `navExit` all read 0 with every token intact, and the resting buy-burn bid
    ///       retires the whole supply for dust. `juniorTrancheSafe` is immutable, so this makes the setter a no-op
    ///       against anything but the one legal value. That is the point — it forecloses nothing, because a
    ///       distinct engine Safe was never the design.
    function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
        if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
        if (juniorTrancheEngine_ != juniorTrancheSafe) revert EngineMustEqualSafe(juniorTrancheEngine_, juniorTrancheSafe);
        _checkpointBestEffort();
        juniorTrancheEngine = juniorTrancheEngine_;
        emit EngineSafeSet(juniorTrancheEngine_);
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
        _checkpointBestEffort();
        xAlphaRateOracle = rateOracle_; // address(0) is a valid "unset / use fallback" value
        emit XAlphaRateOracleSet(rateOracle_);
    }

    /// @notice Wire/re-point (or unset with `address(0)`) the `ZipRedemptionQueue` whose in-flight receivables are
    ///         added back to the basket (SEC/M-2, the off-ramp undercount fix). Zero ⇒ the receivables leg contributes
    ///         0 (v0 / pre-off-ramp). `onlyOwner` (Timelock). Re-pointable, not set-once (§17 build-phase wiring).
    function setRedemptionQueue(address redemptionQueue_) external onlyOwner {
        // Validate at SET time, mirroring the LP side's `_assertLpTwapReady` (SEC-10): `_queueReceivables` makes two
        // high-level staticcalls that expect returndata, so a codeless address (an EOA fat-finger) reverts on the
        // compiler's extcodesize check and bricks EVERY NAV read — grossBasketValue/spot/twap/navEntry/navExit/
        // committedValue/freeValue/_accumulate. Reject the un-priceable wiring here instead. Probe both getters once
        // so a contract missing the surface also fails closed at set time. Zero stays valid (unset / no off-ramp).
        if (redemptionQueue_ != address(0)) {
            if (redemptionQueue_.code.length == 0) revert RedemptionQueueNotReady();
            IZipRedemptionQueueReceivables(redemptionQueue_).pendingRedeemRequest(0, juniorTrancheSafe);
            IZipRedemptionQueueReceivables(redemptionQueue_).maxWithdraw(juniorTrancheSafe);
        }
        _checkpointBestEffort();
        redemptionQueue = redemptionQueue_; // address(0) is a valid "unset / no off-ramp yet" value
        emit RedemptionQueueSet(redemptionQueue_);
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
            // NO DEVIATION BAND (removed 2026-07-31). A per-push band on a SPOT feed rejects the truth: an 11% real
            // move cannot be published honestly against a 10% band. The producer's answer was to CLAMP to the band
            // edge and push a knowingly-wrong number — a silent falsification, strictly worse than a loud revert.
            // The magnitude guard belongs at the SOURCE: the CRE publishes a TWAP of the subnet-46 pool reserves, so
            // a single trade never produces an out-of-band jump and no on-chain clamp is needed. See
            // `bridge/xalpha-price-leg.md`.
            if (prior.ts != 0 && ts <= prior.ts) revert StaleReport(); // strictly-newer: catches the same-price backdated replay (a magnitude check never could)
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
    ///      head but can no longer evict the window.
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
    /// @notice The gross junior basket value (18-dp USD, `1e18 = $1`), summed across main + juniorTrancheSidecar; IL marked-through.
    ///         The LP is counted in ALL states (loose share + gauge-staked + escrow-collateralized) and the farm utility
    ///         strike debt is subtracted, so a `postCollateral`/`borrow`/`repay`/`withdrawCollateral` cycle is
    ///         NAV-invariant (closes the §8.2 mid-loop blind spot). Saturates at 0 (debt can never exceed the basket
    ///         in solvent operation; the floor guards the insolvent edge).
    function grossBasketValue() public view returns (uint256 value) {
        // the flat $1 mark is on the zipUSD BASKET LEG / deposit input only — the szipUSD SHARE itself
        // is NAV-priced (`navEntry = max(spot,twap)`, `navExit = min(spot,twap)`), never flat $1. Latent risk: a
        // zipUSD de-peg would value this leg above its realized backing and over-issue szipUSD (diluting stayers);
        // LOW, mitigated by atomic capacity-gated minting. Optional hardening (price this leg off realized backing)
        // is noted in §7, not owed.
        value += _bal(zipUSD); // 18-dp $1

        value += _bal(usdc) * 1e12; // 6-dp -> 18-dp $1
        value += _bal(xAlpha) * _xAlphaUSD() / 1e18;
        // HYDX, oHYDX, and veHYDX are all marked $0 by design. HYDX is pure sale inventory (spot-marking it
        // overstates realizable value by the dump slippage); oHYDX's intrinsic formula can't track Hydrex's
        // per-token exercise payment floor or that same slippage; exerciseVe absorbs value into permalocked
        // voting power that never returns to the basket. NAV recognizes emission value only when realized
        // proceeds land in a Safe. The LEG_HYDX_USD feed (pushes, deviation band, staleness gates) is KEPT:
        // the live HYDX mark is the input for deciding whether exercising oHYDX is profitable — a separate
        // accounting concern, never a NAV input.
        value += _lpValue(_lpShares(juniorTrancheSafe) + _lpShares(juniorTrancheSidecar));
        value += _queueReceivables(); // SEC/M-2: in-flight off-ramp value (owned by juniorTrancheSafe), 0 if unwired
        uint256 debt = _farmUtilityDebt(juniorTrancheSafe) + _farmUtilityDebt(juniorTrancheSidecar);
        value = value > debt ? value - debt : 0;
    }

    /// @notice The committed (juniorTrancheSidecar-only) basket value, 18-dp USD — the §11-B / §6.4 freeze-floor read the
    ///         DurationFreezeModule bounds `release` against. ADDITIVE: `grossBasketValue()` is unchanged; this is
    ///         an INDEPENDENT per-Safe re-computation. For the three valued plain legs `committedValue() + freeValue()`
    ///         equals `grossBasketValue` EXACTLY; for a split LP the per-Safe pro-rata floors run twice vs once, so
    ///         the sum sits below gross by at most `floor(px/1e18) + 4` wei, where `px = exchangeRate * alphaUSD / 1e18`
    ///         is the xALPHA USD mark. The tolerance is PRICE-DEPENDENT, not a flat 2 wei: the inner floor loss is
    ///         amplified by the outer `_tokenValue` division (`amt * price / 1e18`), which is lossless only at
    ///         `price == 1e18`. Measured gaps: 2 wei at $1.00, 3 at $0.50, 4 at $1.20, 7 at $3.70 (the bound is tight
    ///         there), 101 at $100. Derived + fuzz-verified in `SzipNavOracleInvariant.t.sol`
    ///         (`invariant_decompositionAdditivity`).
    ///         DIRECTION CAVEAT — `sum <= gross` is NOT unconditional. `grossBasketValue` saturates on the COMBINED
    ///         value-minus-debt; `_grossValueOf` saturates PER SAFE. If one Safe's farm-utility debt exceeds its own
    ///         valued legs, that shortfall is floored away here instead of reducing the other Safe's value, and
    ///         `sum > gross` with no rounding bound. The under-count-only direction holds whenever each Safe's legs
    ///         cover its own debt — the only state the farm-utility loop constructs.
    ///         The module only ever moves plain legs (incl. $0-marked HYDX/oHYDX), so gross is exactly
    ///         rotation-invariant.
    function committedValue() external view returns (uint256) {
        return _grossValueOf(juniorTrancheSidecar);
    }

    /// @notice The free (main-only) basket value, 18-dp USD. ADDITIVE; see `committedValue`.
    function freeValue() external view returns (uint256) {
        return _grossValueOf(juniorTrancheSafe);
    }

    /// @dev Value ONE Safe's holdings (18-dp USD), mirroring `grossBasketValue` per-leg + LP marks (incl. the escrow
    ///      leg) minus that Safe's farm utility debt. Used by `committedValue`/`freeValue`. Saturates at 0.
    function _grossValueOf(address safe) internal view returns (uint256 value) {
        value += IERC20(zipUSD).balanceOf(safe); // 18-dp $1
        value += IERC20(usdc).balanceOf(safe) * 1e12; // 6-dp -> 18-dp $1
        value += IERC20(xAlpha).balanceOf(safe) * _xAlphaUSD() / 1e18;
        // HYDX + oHYDX marked $0 — see grossBasketValue; per-Safe additivity holds trivially for $0 legs.
        value += _lpValue(_lpShares(safe));
        // SEC/M-2: the off-ramp receivables are `juniorTrancheSafe` (rq Safe) equity ⇒ they belong to `freeValue`,
        // NOT the sidecar's `committedValue`. Adding here (and ONLY here) keeps `committedValue + freeValue ==
        // grossBasketValue` exact and avoids double-counting the in-flight value across the two Safes.
        if (safe == juniorTrancheSafe) value += _queueReceivables();
        uint256 debt = _farmUtilityDebt(safe);
        value = value > debt ? value - debt : 0;
    }

    /// @notice The main Safe's holdings of the two priced spot legs — zipUSD at $1 and xALPHA at the CRE rate —
    ///         18-dp USD. Counted as coverage alongside `pathLockedLpEquity()`: an ICHI LP share IS zipUSD and
    ///         xALPHA in a wrapper, priced pro-rata off those same two reserves, so counting the wrapped form and
    ///         not the unwrapped form made the freeze depend on the shape of an asset rather than its value. USDC
    ///         is deliberately excluded — it is the form buy-burn spends, and `SzipBuyBurnModule` relies on the
    ///         bid's outflow not reducing coverage. Farm utility debt is NOT subtracted here; `pathLockedLpEquity()`
    ///         already nets the main Safe's debt once, and subtracting it twice would understate coverage.
    function mainSpotEquity() public view returns (uint256) {
        return IERC20(zipUSD).balanceOf(juniorTrancheSafe)
            + IERC20(xAlpha).balanceOf(juniorTrancheSafe) * _xAlphaUSD() / 1e18;
    }

    /// @notice The path-locked LP equity (18-dp USD): the MAIN-Safe ICHI LP in every state (loose + gauge-staked +
    ///         escrow-collateralized), NET of the main Safe's farm utility strike debt. MAIN-SAFE ONLY — the SIDECAR's
    ///         LP + debt are already owned by `committedValue()` (`_grossValueOf(juniorTrancheSidecar)`), so summing this into
    ///         `coverageValue()` counts every Safe's LP exactly once (double-count fix).
    ///         The freeze module adds this to `committedValue()` for its coverage floor. Since `mainSpotEquity()`
    ///         counts the unwrapped form at the same value, dissolving the LP is coverage-neutral — it changes the
    ///         shape of the backing, not its size.
    function pathLockedLpEquity() public view returns (uint256) {
        uint256 lpValue = _lpValue(_lpShares(juniorTrancheSafe));
        uint256 debt = _farmUtilityDebt(juniorTrancheSafe);
        return lpValue > debt ? lpValue - debt : 0;
    }

    /// @dev LP shares held by `safe` across all states: loose ICHI share + gauge-staked + escrow-collateralized.
    ///      Zero when the LP is unwired (`ichiVault == 0`). The escrow leg is added only once `escrowVault` is wired.
    function _lpShares(address safe) internal view returns (uint256 s) {
        if (ichiVault == address(0)) return 0;
        s = IICHIVault(ichiVault).balanceOf(safe) + IGauge(gauge).balanceOf(safe);
        if (escrowVault != address(0)) {
            s += IFarmUtilityEscrow(escrowVault).convertToAssets(IFarmUtilityEscrow(escrowVault).balanceOf(safe));
        }
    }

    /// @notice The 18-dp USD value of `lpShares` ICHI LP shares — the LP-dissolution gate
    ///         (`LpStrategyModule.removeLiquidity` via the freeze module) reads this to bound a dissolution to the
    ///         coverage excess. Public projection of the internal pro-rata mark; 0 if the LP is unwired/empty.
    function lpShareValue(uint256 lpShares) public view returns (uint256) {
        return _lpValue(lpShares);
    }

    /// @dev 18-dp USD value of `lpShares` ICHI LP, pro-rata over the OUR-pool reserves. Returns 0 if the LP is
    ///      unwired or the vault is empty (the `supplyLp == 0` guard). One floor-division pair per call (the
    ///      `floor(px/1e18) + 4` wei gross-vs-per-Safe split note still holds — combined shares floor once, per-Safe
    ///      floor separately, and the residue is then scaled by the outer `_tokenValue` price division).
    function _lpValue(uint256 lpShares) internal view returns (uint256) {
        if (lpShares == 0 || ichiVault == address(0)) return 0;
        uint256 supplyLp = IICHIVault(ichiVault).totalSupply();
        if (supplyLp == 0) return 0;
        // Reserve source: spot `getTotalAmounts()` (default) OR the manipulation-resistant TWAP reconstruction
        // when `lpTwapWindow` is wired (fair-LP reconstruction). Pro-rata + leg pricing are identical either way.
        // OPERATIONS: if the TWAP read reverts (plugin replaced/reset, short history), `lpTwapStatus()` reports
        // `readyAt`; prefer waiting it out — `setLpTwapWindow(0)` is the emergency spot fallback (see its NatSpec).
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

    /// @dev Farm utility strike debt of `safe` in 18-dp USD (USDC 6-dp -> 18-dp). Zero if `borrowVault` unwired.
    function _farmUtilityDebt(address safe) internal view returns (uint256) {
        if (borrowVault == address(0)) return 0;
        return IFarmUtilityDebt(borrowVault).debtOf(safe) * 1e12;
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
    /// @dev  THE SPOT FALLBACK IS NOT ONLY A GENESIS PATH. If the accumulator goes idle for `W` (no leg push, no
    ///       `poke()`), the newest observation is older than `target`, the lookup misses, and this returns EXACTLY
    ///       `spot` — so `navEntry == navExit` and the bracket's asymmetry is absent until someone pokes. Keeper
    ///       liveness is what keeps the window populated; it is an operational assumption, not an on-chain one.
    ///       DO NOT "FIX" THIS BY REVERTING WHEN IDLE. That was built (`TwapAccumulatorStale` plus a partial-window
    ///       fallback for genesis) and REVERTED 2026-07-31. It changes nothing, because `poke()` is permissionless
    ///       and anyone can clear the idle state before reading, and it costs real behaviour: the revert also fires
    ///       on the EXIT path, narrowing the "staleness pauses issuance, never exit" asymmetry documented above
    ///       (60 tests failed, 54 of them purely genesis-path).
    ///       WHY NO READ-PATH GUARD WORKS: `_accumulate()` books a RIGHT-ENDPOINT sample, crediting the CURRENT spot
    ///       across the WHOLE preceding gap, so an idle gap is repriced at whatever spot is true when it is finally
    ///       poked. Leg pushes escape this because `_processReport` accumulates BEFORE writing, booking the old price
    ///       first. A mark living in ANOTHER contract (the xALPHA rate) structurally cannot do that, which is why its
    ///       guard belongs at that contract rather than here.
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
    /// @notice The issuance price `max(spot, twap)`. Reverts `StalePrice` if the required pushed leg is stale.
    /// @dev  LEG_HYDX_USD is NOT a required leg (2026-08-05, finding L10): it is marked $0 in `grossBasketValue`, so
    ///       its price contributes nothing to NAV, and gating issuance on its staleness froze minting on the
    ///       liveness of a feed that prices nothing. It is KEPT as the exercise-profitability input
    ///       (`emission-marking` [2026-07-30]), pushed and cached as before, just no longer a deposit gate.
    function navEntry() external view returns (uint256) {
        if (_legStale(LEG_ALPHA_USD)) revert StalePrice(LEG_ALPHA_USD);
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

    /// @notice True iff the required pushed leg (`LEG_ALPHA_USD`) is within `maxAge` (the §4 issuance guard) and the
    ///         wired xALPHA rate is fresh. `LEG_HYDX_USD` is deliberately NOT gated (finding L10) — it is $0 in NAV,
    ///         so its staleness must not halt issuance; it stays as the exercise-profitability input.
    function fresh() public view returns (bool) {
        if (_legStale(LEG_ALPHA_USD)) return false;
        if (xAlphaRateOracle != address(0) && !IXAlphaRateFresh(xAlphaRateOracle).fresh()) return false;
        return true;
    }

    /// @notice The oldest CRE-push timestamp among the marks `navExit()`/`fresh()` are built from — the required
    ///         pushed leg (`LEG_ALPHA_USD`) and, when wired (`xAlphaRateOracle != 0`), the cross-chain xALPHA rate's
    ///         `lastUpdate()`. `LEG_HYDX_USD` is NOT folded in (finding L10): it prices nothing in NAV and no longer
    ///         gates issuance, so anchoring a resting bid's `validTo` to its staleness would tighten the bid on a
    ///         feed the mark does not depend on. A resting §7 buy-burn bid anchors its `validTo` ceiling to
    ///         `oldestRequiredLegTs() + maxAge` so the NAV mark it can fill against is at
    ///         most `maxAge` old at fill, not `2·maxAge` (the pre-fix post-time anchor allowed legs already up to
    ///         `maxAge` old at post-time to age another full `maxAge` while the bid rests).
    /// @dev    Unset-leg / unseeded-rate handling: an unpushed required leg (`ts == 0`) yields `0`, which fails the
    ///         bid closed at the module's anchor fence. The rate leg is folded only when its own `lastUpdate() != 0`
    ///         so an unseeded-but-wired rate routes to the cleaner `fresh()`/`StaleNav` gate instead of clamping the
    ///         anchor to `0`. Rate-leg window: the rate's native freshness is the rate oracle's own `maxStaleness`
    ///         (6h fixture, tighter than the 24h `maxAge`), so folding the raw `lastUpdate()` would let a bid rest
    ///         up to `maxAge − maxStaleness` past the rate's own trust window (a pre-slash fill lane during
    ///         wind-down-length TTLs). The rate's timestamp is therefore SHIFTED back by that difference before the
    ///         `min`, so the module's `anchor + maxAge` fence lands at `lastUpdate + min(maxAge, maxStaleness)` —
    ///         every input, rate included, is within ITS OWN bound at fill. Shifting only LOWERS the anchor, so the
    ///         per-leg `maxAge` guarantee is never weakened; a shift past zero clamps to `0` and fails the bid
    ///         closed (the rate is far beyond stale there and `fresh()` blocks posting anyway).
    function oldestRequiredLegTs() external view returns (uint48) {
        uint48 oldest = legCache[LEG_ALPHA_USD].ts; // LEG_HYDX_USD excluded (L10): $0 in NAV, not an issuance gate
        address rate = xAlphaRateOracle;
        if (rate != address(0)) {
            uint48 r = IXAlphaRateFresh(rate).lastUpdate();
            if (r != 0) {
                uint256 ms = IXAlphaRateFresh(rate).maxStaleness();
                if (ms < maxAge) {
                    uint256 shift = maxAge - ms;
                    r = uint256(r) > shift ? uint48(uint256(r) - shift) : 0;
                }
                if (r < oldest) oldest = r;
            }
        }
        return oldest;
    }

    // --------------------------------------------------------------------- internals
    function _legStale(uint8 leg) internal view returns (bool) {
        uint48 ts = legCache[leg].ts;
        if (ts == 0) return true;
        return block.timestamp - ts > maxAge;
    }

    function _bal(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(juniorTrancheSafe) + IERC20(token).balanceOf(juniorTrancheSidecar);
    }

    /// @dev SEC/M-2: the in-flight senior-redemption value attributable to `juniorTrancheSafe` (the rq Safe) — the
    ///      escrowed-pending zipUSD (18-dp $1) plus the filled-but-unclaimed USDC (6-dp $1, scaled ×1e12 like every
    ///      other USDC leg). During the OffRampModule request→claim window this value has left the Safe (so `_bal`
    ///      misses it) yet is still basket equity; adding it back keeps NAV continuous across the off-ramp so a
    ///      deposit in the window mints at the true (not a depressed) `navEntry`. No double-count: `settleEpoch` moves
    ///      pending→claimable atomically (burns the zipUSD as it banks the USDC) and `claim` moves claimable→on-Safe
    ///      balance, so `pending + claimable + on-Safe` sums the same value at every instant. Zero when unwired.
    function _queueReceivables() internal view returns (uint256) {
        address q = redemptionQueue;
        if (q == address(0)) return 0;
        uint256 pending = IZipRedemptionQueueReceivables(q).pendingRedeemRequest(0, juniorTrancheSafe); // 18-dp $1
        uint256 claimable = IZipRedemptionQueueReceivables(q).maxWithdraw(juniorTrancheSafe); // 6-dp $1
        return pending + claimable * 1e12;
    }

    /// @dev USD per 1.0 xALPHA (18-dp): on-chain LST exchangeRate × the pushed alphaUSD.
    ///      Fail-closed on an UNSEEDED rate (`exchangeRate() == 0`, genesis/uninitialized) — reverts `RateUnseeded`
    ///      rather than silently valuing the entire xALPHA leg at 0. This is distinct from STALENESS, which is still
    ///      NOT gated here: a stale-but-nonzero rate keeps pricing off the last good mark, preserving the §7
    ///      max-entry/min-exit asymmetry (freshness is gated only at issuance — `navEntry`/`fresh`).
    function _xAlphaUSD() internal view returns (uint256) {
        // Rate source: the wired Base rate oracle (CRE-pushed cross-chain rate) when set, else the direct read
        // (M1 stand-in). Value (not freshness) is read here — freshness is gated at issuance (`navEntry`/`fresh`),
        // so `grossBasketValue`/exit keep pricing off the last good rate (the §7 asymmetry).
        address rateSrc = xAlphaRateOracle == address(0) ? xAlpha : xAlphaRateOracle;
        uint256 rate = IXAlphaRate(rateSrc).exchangeRate();
        if (rate == 0) revert RateUnseeded();
        return rate * legCache[LEG_ALPHA_USD].price / 1e18;
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
        uint256 pend = juniorTrancheEngine == address(0) ? 0 : IERC20(shareToken).balanceOf(juniorTrancheEngine);
        return ts > pend ? ts - pend : 0;
    }
}
