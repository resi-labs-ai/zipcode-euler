// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {ISzipNavBasket} from "../../interfaces/supply/ISzipNavBasket.sol";
import {IEulerEarnUtil} from "../../interfaces/euler/IEulerEarnUtil.sol";

/// @title DurationFreezeModule
/// @notice The §11-B / §6.4 / §8.2 duration-squeeze freeze actuator: the seventh engine Zodiac `Module`, and the
///         first enabled on BOTH Safes (main + sidecar), because the freeze moves value across them. It fills the
///         non-ragequittable sidecar (`commit`, MAIN→SIDECAR) and drains it (`release`, SIDECAR→MAIN), keeping the
///         utilization-committed junior equity structurally unreachable by an Exit-Gate window exit. This is the
///         Duration-Bond trigger B — a LIQUIDITY squeeze: no realized loss, no xALPHA premium/slash, no markdown.
///
/// @dev RESIDUAL-TRUST BLOCK (§13): this module **rotates and bounds**; it does NOT decide the liquidity regime.
///      The CRE `operator` (single, trusted, the same authority every engine module trusts) is trusted for *which*
///      whitelisted asset to move, *how much*, the timing, and whether to `commit`. The on-chain guarantees are
///      narrow and exact: (a) value can only move between the two wired Safes — no recipient parameter, no third
///      destination, no custody; (b) `release` cannot drop the sidecar below `requiredCommittedValue()` — the
///      senior LIABILITY (`min(illiquidSeniorValue, grossBasketValue)`), read live and donation-immune from
///      EulerEarn and not outsider-manipulable (§4.3/§8.2) — so a compromised operator cannot open the run hatch
///      while debt is outstanding; the floor is pinned to ABSOLUTE debt, not a junior-basket fraction, so shrinking
///      the basket cannot lower it (structural — no governed knob; build/wires/DurationFreezeModule.md); (c) `utilization()`/`requiredFraction()` are
///      retained only as the §12 liquidity-run metric — no longer the floor; (d) only oracle-valued assets are
///      movable (no unvalued-asset leak). A compromised operator can
///      **grief** (over-commit free equity, delaying exits; §12 metrics + governance watch it) but **cannot steal**
///      and **cannot under-freeze**. zipUSD never freezes (junior-only, §17). The floor read is sound under the
///      single-operator invariant (no concurrent sibling-module rotation mid-`release`).
///
/// @dev SECURITY BOUNDARY (the module's whole shape): the operator supplies ONLY `(asset, amount)`. The module
///      builds ALL calldata; the source and destination of every transfer are the literal set-once `mainSafe` /
///      `sidecar` — NO recipient parameter, NO generic exec/delegatecall, `value == 0` on every exec. The module
///      holds no custody (the Safes hold the tokens) and never touches the Exit Gate, any default/loss state, the
///      oracle's `provision`, or any xALPHA bond. `U` is read DONATION-IMMUNE off the senior pool (§8.2): never
///      `IERC20(usdc).balanceOf(eulerEarn)`.
///
/// @dev CLONE FACT (§18.6, proven on 8-B14/8-B5/8-B6): a `ModuleProxyFactory` clone shares the mastercopy's
///      runtime bytecode, so `immutable` CANNOT carry per-clone `setUp` config. EVERY per-clone wired
///      address/param is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`. The
///      mastercopy is init-locked in its constructor (see {MastercopyInitLock}). OZ `ReentrancyGuard` (non-upgradeable) is storage-safe under clones.
contract DurationFreezeModule is MastercopyInitLock, ReentrancyGuard {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The free-equity (ragequit-target) Safe — `avatar == target == mainSafe`; the `commit` source / `release` dest.
    address public mainSafe;
    /// @notice The committed-equity (non-ragequittable) sidecar Safe — the `commit` dest / `release` source.
    address public sidecar;
    /// @notice The single CRE operator (gates `commit`/`release`).
    address public operator;
    /// @notice The `SzipNavOracle` (read via `ISzipNavBasket`): the sole valuation authority for the floor.
    address public navOracle;
    /// @notice The EulerEarn senior pool (read via `IEulerEarnUtil`): the donation-immune `U` source (§8.2).
    address public eulerEarn;
    /// @notice The CreditWarehouse Safe holding the EulerEarn senior shares (the `owner` arg of the `U` read).
    address public warehouse;

    // -- the movable whitelist: the FIVE oracle plain legs ONLY (read LIVE at setUp). The ICHI LP share is NOT
    //    movable: it is fenced in place and counted via the oracle's `pathLockedLpEquity()`.
    //    This RESOLVES the former line-74 freeze-lp gotcha — we never try to physically commit the staked LP (which
    //    isn't a transferable ERC20 in the Safe); instead the floor's coverage numerator ADDS the LP equity in place
    //    (`coverageValue() = committedValue() + pathLockedLpEquity()`), and the LP's only dissolution path
    //    (`LpStrategyModule.removeLiquidity`) is coverage-gated so it cannot reach an exit below the floor.
    address public zipUSD;
    address public usdc;
    address public xAlpha;
    address public hydx;
    address public oHydx;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error BadParams();
    error ZeroAmount();
    error UnvaluedAsset(address asset);
    error ExecFailed();
    error TransferShortfall();
    error FreezeFloorBreach(uint256 committed, uint256 floor);

    // --------------------------------------------------------------------- events
    /// @notice MAIN→SIDECAR rotation (increase the freeze). `committedValueAfter` is read post-move from the oracle.
    event Committed(address indexed asset, uint256 amount, uint256 committedValueAfter);
    /// @notice SIDECAR→MAIN rotation (shrink the freeze). Emits the post-move committed value + the floor it cleared.
    event Released(address indexed asset, uint256 amount, uint256 committedValueAfter, uint256 floor);
    /// @notice A Timelock-settable wiring field was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). One-shot via the zodiac-core
    ///         `initializer`. Decodes the wired addresses, reads the movable assets (5 plain legs + the ICHI LP
    ///         share, the latter possibly address(0) pre-LP) LIVE off the oracle (so the
    ///         whitelist == exactly what the oracle prices — no drift), sets `avatar == target == mainSafe` (the
    ///         inherited single-avatar exec is NOT used; both rotations go through explicit `ISafe(src)` calls), and
    ///         transfers ownership to the Timelock `owner`.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address mainSafe_,
            address sidecar_,
            address operator_,
            address navOracle_,
            address eulerEarn_,
            address warehouse_
        ) = abi.decode(initParams, (address, address, address, address, address, address, address));

        if (
            owner_ == address(0) || mainSafe_ == address(0) || sidecar_ == address(0) || operator_ == address(0)
                || navOracle_ == address(0) || eulerEarn_ == address(0) || warehouse_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();
        // distinctness is load-bearing: equal Safes make a rotation a self-transfer that trivially passes the floor.
        if (mainSafe_ == sidecar_) revert BadParams();

        // The module is enabled ON the main Safe; the inherited single-avatar exec is inert (rotation uses ISafe(src)).
        avatar = mainSafe_;
        target = mainSafe_;

        mainSafe = mainSafe_;
        sidecar = sidecar_;
        operator = operator_;
        navOracle = navOracle_;
        eulerEarn = eulerEarn_;
        warehouse = warehouse_;

        // Read the movable assets LIVE off the wired oracle (the LpStrategyModule "read token0/token1 live"
        // idiom) — the whitelist is EXACTLY what the oracle prices, removing drift and five setUp args.
        ISzipNavBasket o = ISzipNavBasket(navOracle_);
        zipUSD = o.zipUSD();
        usdc = o.usdc();
        xAlpha = o.xAlpha();
        hydx = o.hydx();
        oHydx = o.oHydx();
        // the ICHI LP share is intentionally NOT whitelisted — it is fenced in place + counted via pathLockedLpEquity().

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point `mainSafe` (build phase, §17). onlyOwner (Timelock).
    function setMainSafe(address mainSafe_) external onlyOwner {
        if (mainSafe_ == address(0)) revert ZeroAddress();
        mainSafe = mainSafe_;
        emit WiringSet("mainSafe", mainSafe_);
    }

    /// @notice Re-point `sidecar` (build phase, §17). onlyOwner (Timelock).
    function setSidecar(address sidecar_) external onlyOwner {
        if (sidecar_ == address(0)) revert ZeroAddress();
        sidecar = sidecar_;
        emit WiringSet("sidecar", sidecar_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `navOracle` (build phase, §17). onlyOwner (Timelock).
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert ZeroAddress();
        navOracle = navOracle_;
        emit WiringSet("navOracle", navOracle_);
    }

    /// @notice Re-point `eulerEarn` (build phase, §17). onlyOwner (Timelock).
    function setEulerEarn(address eulerEarn_) external onlyOwner {
        if (eulerEarn_ == address(0)) revert ZeroAddress();
        eulerEarn = eulerEarn_;
        emit WiringSet("eulerEarn", eulerEarn_);
    }

    /// @notice Re-point `warehouse` (build phase, §17). onlyOwner (Timelock).
    function setWarehouse(address warehouse_) external onlyOwner {
        if (warehouse_ == address(0)) revert ZeroAddress();
        warehouse = warehouse_;
        emit WiringSet("warehouse", warehouse_);
    }

    /// @notice Re-point `zipUSD` (build phase, §17). onlyOwner (Timelock).
    function setZipUSD(address zipUSD_) external onlyOwner {
        if (zipUSD_ == address(0)) revert ZeroAddress();
        zipUSD = zipUSD_;
        emit WiringSet("zipUSD", zipUSD_);
    }

    /// @notice Re-point `usdc` (build phase, §17). onlyOwner (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point `xAlpha` (build phase, §17). onlyOwner (Timelock).
    function setXAlpha(address xAlpha_) external onlyOwner {
        if (xAlpha_ == address(0)) revert ZeroAddress();
        xAlpha = xAlpha_;
        emit WiringSet("xAlpha", xAlpha_);
    }

    /// @notice Re-point `hydx` (build phase, §17). onlyOwner (Timelock).
    function setHydx(address hydx_) external onlyOwner {
        if (hydx_ == address(0)) revert ZeroAddress();
        hydx = hydx_;
        emit WiringSet("hydx", hydx_);
    }

    /// @notice Re-point `oHydx` (build phase, §17). onlyOwner (Timelock).
    function setOHydx(address oHydx_) external onlyOwner {
        if (oHydx_ == address(0)) revert ZeroAddress();
        oHydx = oHydx_;
        emit WiringSet("oHydx", oHydx_);
    }

    // --------------------------------------------------------------------- gates
    /// @notice Only the FIVE oracle-valued plain legs may rotate. Releasing/committing an unvalued asset is barred — a
    ///         release of an unvalued asset would leave the sidecar without moving `committedValue()`, so the floor
    ///         would pass while real value exits the freeze (the non-basket-asset leak, security #6). The ICHI LP
    ///         share is deliberately NOT here: it is fenced in place, not rotated.
    modifier onlyValued(address asset) {
        if (asset != zipUSD && asset != usdc && asset != xAlpha && asset != hydx && asset != oHydx) {
            revert UnvaluedAsset(asset);
        }
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the
    //      hot key) CANNOT call them — only `owner` (the Timelock) can; a redirect by governance is a deliberate
    //      timelocked act, not an attack path, AND it is INERT for rotation (rotation uses the explicit set-once
    //      `ISafe(mainSafe)` / `ISafe(sidecar)` calls, not the avatar-bound exec). We do NOT hard-lock them (that
    //      would require marking the vendored zodiac-core setters `virtual` — reference deps stay pristine).

    // --------------------------------------------------------------------- views (the §11-B / §8.2 math)
    /// @notice On-chain, donation-immune utilization `U` (18-dp, in `[0, 1e18]`): the illiquid fraction of the
    ///         senior backing, `U = 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` (§8.2). NEVER
    ///         reads `balanceOf(eulerEarn)` (donatable AND ≈0 for a pure-allocator pool). `sa == 0` → 0;
    ///         `free >= sa` → 0.
    function utilization() public view returns (uint256 u) {
        IEulerEarnUtil e = IEulerEarnUtil(eulerEarn);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouse));
        if (sa == 0) return 0;
        uint256 free = e.maxWithdraw(warehouse);
        if (free >= sa) return 0;
        u = (sa - free) * 1e18 / sa;
    }

    /// @notice The required sidecar floor FRACTION: `freeze% = utilization%` exactly. `utilization()` is already
    ///         clamped to `[0, 1e18]`, so this IS the whole formula — no escalation, no `min`/`max`. The §11-B
    ///         escalation surface (`U_lock`/`U_max`/`maxLockFraction`) is post-M1, not built. φ_A = utilization is
    ///         the liquidity-path identity (§6.4 structural baseline).
    function requiredFraction() public view returns (uint256) {
        return utilization();
    }

    /// @notice The committed (sidecar-only) basket value, read FROM the oracle (18-dp USD).
    function committedValue() public view returns (uint256) {
        return ISzipNavBasket(navOracle).committedValue();
    }

    /// @notice The gross (both-Safes) basket value, read FROM the oracle (18-dp USD).
    function grossBasketValue() public view returns (uint256) {
        return ISzipNavBasket(navOracle).grossBasketValue();
    }

    /// @notice The free (main-only) basket value = gross − committed (18-dp USD).
    function freeValue() public view returns (uint256) {
        return grossBasketValue() - committedValue();
    }

    /// @notice The path-locked LP equity (18-dp USD), read FROM the oracle: the fenced zipUSD/xALPHA ICHI LP in every
    ///         state (loose + gauge-staked + escrow-collateralized) net of reservoir strike debt. It backs the floor
    ///         IN PLACE — the LP's only dissolution path (`LpStrategyModule.removeLiquidity`) is coverage-gated, so it
    ///         cannot reach an exit below the floor.
    function pathLockedLpEquity() public view returns (uint256) {
        return ISzipNavBasket(navOracle).pathLockedLpEquity();
    }

    /// @notice The coverage numerator the floor is checked against: sidecar liquid legs (`committedValue`) + the
    ///         fenced LP equity (`pathLockedLpEquity`). Using this — NOT `committedValue()` alone — is what lets the
    ///         productive LP back the floor without being hoarded idle in the sidecar (the line-74 resolution).
    function coverageValue() public view returns (uint256) {
        return committedValue() + pathLockedLpEquity();
    }

    /// @notice The absolute lent-out (illiquid) senior dollars = the liability the junior backs, 18-dp USD. This is
    ///         the NUMERATOR of `utilization()` (`sa − free`), scaled from the USDC-6dp senior unit to 18-dp. Same
    ///         donation-immune reads as `utilization()` (never `balanceOf(eulerEarn)`). Unlike `utilization()` this
    ///         does NOT divide by `sa`, so shrinking the junior basket cannot move it — that is what makes the floor
    ///         un-drainable. `sa == 0` → 0; `free >= sa` → 0.
    function illiquidSeniorValue() public view returns (uint256) {
        IEulerEarnUtil e = IEulerEarnUtil(eulerEarn);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouse));
        if (sa == 0) return 0;
        uint256 free = e.maxWithdraw(warehouse);
        if (free >= sa) return 0;
        return (sa - free) * 1e12; // USDC 6-dp -> 18-dp USD
    }

    /// @notice The required committed VALUE the floor enforces — pinned 1:1 to the senior LIABILITY, not a fraction of
    ///         the junior basket: `floor = min( illiquidSeniorValue(), grossBasketValue() )`. Capped at gross because
    ///         you cannot freeze more value than the basket holds (the insolvent edge `floor > gross` → freeze
    ///         everything). Because `debt` is read off the senior pool and does not move when `grossBasketValue`
    ///         shrinks, the re-leveling drain has no denominator left to game. STRUCTURAL — no governed knob (§17);
    ///         the floor is exactly the lent-out senior dollars, live-marked. `requiredFraction()`/`utilization()`
    ///         are RETAINED only as the §12 liquidity-run metric — they no longer gate `release`.
    function requiredCommittedValue() public view returns (uint256) {
        uint256 debt = illiquidSeniorValue();
        uint256 gross = grossBasketValue();
        return debt < gross ? debt : gross;
    }

    /// @notice True iff the coverage value (`committedValue + pathLockedLpEquity`) covers the liability floor. The
    ///         outflow predicate: `release` enforces it post-move, and the free-side outflow gates (buy-and-burn
    ///         `postBid`, the LP-dissolution `removeLiquidity`) read it so a PRICE-DRIFT breach —
    ///         coverage falling below the floor with no `release` — freezes outflow until a `commit`/re-stake tops it
    ///         back up.
    /// @dev DOUBLE-SQUEEZE — bucket holds, the "debt nets out consistently" rationale was wrong: a
    ///      reservoir borrow against the fenced LP pushes BOTH sides of this inequality the wrong way at once —
    ///      (1) the NUMERATOR drops, because `pathLockedLpEquity()` subtracts the reservoir strike debt from the LP
    ///      mark; and (2) the FLOOR rises, because the borrow draws senior cash so `maxWithdraw(warehouse)` falls,
    ///      lifting `illiquidSeniorValue()` and thus `requiredCommittedValue()`. The two effects do NOT cancel. This
    ///      is FAIL-CLOSED / SELF-DoS by design: the borrower can only freeze its own outflow, and it recovers fully
    ///      on repay (the debt clears, both sides relax). Liveness footgun only — never a solvency hole.
    function covered() public view returns (bool) {
        return coverageValue() >= requiredCommittedValue();
    }

    /// @notice True iff dissolving `lpShares` of the fenced LP would leave coverage still at/above the floor — the
    ///         excess bound the LP-dissolution gate (`LpStrategyModule.removeLiquidity`) enforces so the floor-backing
    ///         LP cannot be liquefied into exitable legs. Dissolving the LP drops the coverage
    ///         numerator by exactly its mark (the legs land free/exitable, no longer path-locked), so the check is
    ///         `coverageValue − lpShareValue(lpShares) >= requiredCommittedValue`. Saturating.
    function lpBurnKeepsCovered(uint256 lpShares) external view returns (bool) {
        uint256 lpVal = ISzipNavBasket(navOracle).lpShareValue(lpShares);
        uint256 cov = coverageValue();
        uint256 remaining = cov > lpVal ? cov - lpVal : 0;
        return remaining >= requiredCommittedValue();
    }

    // --------------------------------------------------------------------- commit (MAIN→SIDECAR — increase the freeze)
    /// @notice Rotate `amount` of a whitelisted `asset` from the main Safe into the non-ragequittable sidecar,
    ///         INCREASING the freeze. Operator-gated, whitelist-gated, `nonReentrant`. NO value floor/ceiling
    ///         (§11 canonical): `commit` is always peg-safe so it is ungated-by-value; an unbounded commit can
    ///         freeze 100% — the intended squeeze. The residual operator-grief (over-freeze) is accepted (item-10
    ///         wires the §12 metric-4 alarm). The dest balance delta MUST equal `amount` (the FoT/false-return
    ///         defense).
    function commit(address asset, uint256 amount) external nonReentrant onlyValued(asset) {
        if (msg.sender != operator) revert NotOperator();
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBal = IERC20(asset).balanceOf(sidecar);
        bool ok = ISafe(mainSafe).execTransactionFromModule(
            asset, 0, abi.encodeCall(IERC20.transfer, (sidecar, amount)), 0
        );
        if (!ok) revert ExecFailed();
        if (IERC20(asset).balanceOf(sidecar) - beforeBal != amount) revert TransferShortfall();

        emit Committed(asset, amount, committedValue());
    }

    // --------------------------------------------------------------------- release (SIDECAR→MAIN — THE autonomous floor)
    /// @notice Rotate `amount` of a whitelisted `asset` from the sidecar back to the main Safe, SHRINKING the
    ///         freeze. Operator-gated, whitelist-gated, `nonReentrant`. THE autonomous floor (checked AFTER the
    ///         move; the revert atomically rolls the transfer back): `release` reverts unless the sidecar still
    ///         holds at least `requiredCommittedValue()` — the senior LIABILITY (`min(illiquidSeniorValue, gross)`),
    ///         NOT a fraction of the junior basket. The liability is read live → an over-release
    ///         reverts regardless of operator intent. `grossBasketValue` is invariant under a rotation because the oracle
    ///         sums BOTH Safes for every valued asset (the five legs via `_bal`, and the LP across both Safes +
    ///         their gauge stakes), so moving any whitelisted asset — incl. the ICHI LP share — main↔sidecar leaves
    ///         the total constant; the floor is a pure "did the sidecar keep enough value" check.
    function release(address asset, uint256 amount) external nonReentrant onlyValued(asset) {
        if (msg.sender != operator) revert NotOperator();
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBal = IERC20(asset).balanceOf(mainSafe);
        bool ok = ISafe(sidecar).execTransactionFromModule(
            asset, 0, abi.encodeCall(IERC20.transfer, (mainSafe, amount)), 0
        );
        if (!ok) revert ExecFailed();
        if (IERC20(asset).balanceOf(mainSafe) - beforeBal != amount) revert TransferShortfall();

        // THE FLOOR — read AFTER the move; the revert atomically rolls the transfer back. The coverage numerator is
        // `committedValue + pathLockedLpEquity` (the fenced LP backs the floor in place).
        uint256 floor = requiredCommittedValue();
        uint256 c = coverageValue();
        if (c < floor) revert FreezeFloorBreach(c, floor);

        emit Released(asset, amount, c, floor);
    }
}
