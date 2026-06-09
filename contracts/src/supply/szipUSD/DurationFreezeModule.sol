// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";
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
///      destination, no custody; (b) `release` cannot drop the sidecar below `requiredFraction(U) ×
///      grossBasketValue`, where `U` is read live and donation-immune from EulerEarn and is not outsider-
///      manipulable (§4.3/§8.2) — so a compromised operator cannot open the run hatch while utilization is
///      breached; (c) `requiredFraction` only ever *rises* with utilization (no off-chain floor input exists in
///      M1); (d) only the five oracle-valued legs are movable (no unvalued-asset leak). A compromised operator can
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
///      mastercopy is init-locked at deploy. OZ `ReentrancyGuard` (non-upgradeable) is storage-safe under clones.
contract DurationFreezeModule is Module, ReentrancyGuard {
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

    // -- governed §11-B sizing params (18-dp; 1e18 = 100%) --
    /// @notice The utilization below which no escalation applies (`U_lock`). `uLock < uMax`.
    uint256 public uLock;
    /// @notice The utilization at which escalation saturates to `maxLockFraction` (`U_max`). `uMax <= 1e18`.
    uint256 public uMax;
    /// @notice The cap on the escalation term (NOT the effective lock — the lock is capped at 1e18). `0 < x <= 1e18`.
    uint256 public maxLockFraction;

    // -- the movable whitelist == exactly the five oracle leg addresses (read LIVE at setUp) --
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
    /// @notice Initialize a clone (or the mastercopy at deploy, then init-locked). One-shot via the zodiac-core
    ///         `initializer`. Decodes the wired addresses + governed params, reads the five movable legs LIVE off
    ///         the oracle (so the whitelist == exactly what the oracle prices — no drift), sets `avatar == target
    ///         == mainSafe` (the inherited single-avatar exec is NOT used; both rotations go through explicit
    ///         `ISafe(src)` calls), and transfers ownership to the Timelock `owner`.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address mainSafe_,
            address sidecar_,
            address operator_,
            address navOracle_,
            address eulerEarn_,
            address warehouse_,
            uint256 uLock_,
            uint256 uMax_,
            uint256 maxLockFraction_
        ) = abi.decode(
            initParams,
            (address, address, address, address, address, address, address, uint256, uint256, uint256)
        );

        if (
            owner_ == address(0) || mainSafe_ == address(0) || sidecar_ == address(0) || operator_ == address(0)
                || navOracle_ == address(0) || eulerEarn_ == address(0) || warehouse_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();
        // distinctness is load-bearing: equal Safes make a rotation a self-transfer that trivially passes the floor.
        if (mainSafe_ == sidecar_) revert BadParams();
        if (!(uLock_ < uMax_ && uMax_ <= 1e18 && maxLockFraction_ != 0 && maxLockFraction_ <= 1e18)) revert BadParams();

        // The module is enabled ON the main Safe; the inherited single-avatar exec is inert (rotation uses ISafe(src)).
        avatar = mainSafe_;
        target = mainSafe_;

        mainSafe = mainSafe_;
        sidecar = sidecar_;
        operator = operator_;
        navOracle = navOracle_;
        eulerEarn = eulerEarn_;
        warehouse = warehouse_;
        uLock = uLock_;
        uMax = uMax_;
        maxLockFraction = maxLockFraction_;

        // Read the five movable legs LIVE off the wired oracle (the LpStrategyModule "read token0/token1 live"
        // idiom) — the whitelist is EXACTLY what the oracle prices, removing drift and five setUp args.
        ISzipNavBasket o = ISzipNavBasket(navOracle_);
        zipUSD = o.zipUSD();
        usdc = o.usdc();
        xAlpha = o.xAlpha();
        hydx = o.hydx();
        oHydx = o.oHydx();

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
    /// @notice Only the five oracle-valued legs may rotate. Releasing/committing an unvalued asset is barred — a
    ///         release of an unvalued asset would leave the sidecar without moving `committedValue()`, so the floor
    ///         would pass while real value exits the freeze (the non-basket-asset leak, security #6).
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

    /// @notice The required sidecar floor FRACTION (§11-B sizing + §6.4 structural baseline):
    ///         `min(1e18, max(U, escalation))`, escalation = `maxLockFraction × clamp((U−uLock)/(uMax−uLock),0,1)`.
    ///         `max` not sum (§11-B): φ_A = utilization is the liquidity-path identity. All divisions truncate DOWN
    ///         (sub-wei under-floor; documented direction — qa #2).
    function requiredFraction() public view returns (uint256 f) {
        uint256 u = utilization();
        uint256 esc;
        if (u > uLock) {
            esc = u >= uMax ? maxLockFraction : maxLockFraction * (u - uLock) / (uMax - uLock);
        }
        uint256 r = u > esc ? u : esc;
        f = r > 1e18 ? 1e18 : r;
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

    /// @notice The required committed VALUE the floor enforces = `requiredFraction() × grossBasketValue() / 1e18`.
    ///         A `gross == 0` basket floors to 0 (any release allowed; no div-by-zero — the ratio truncates DOWN).
    function requiredCommittedValue() public view returns (uint256) {
        return requiredFraction() * grossBasketValue() / 1e18;
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
    ///         holds at least `requiredFraction(U) × grossBasketValue`. `U` is read live → an over-release reverts
    ///         regardless of operator intent. `grossBasketValue` is invariant under a rotation (the module never
    ///         moves the LP; value moves between Safes, total constant), so the floor is a pure "did the sidecar
    ///         keep enough value" check.
    function release(address asset, uint256 amount) external nonReentrant onlyValued(asset) {
        if (msg.sender != operator) revert NotOperator();
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBal = IERC20(asset).balanceOf(mainSafe);
        bool ok = ISafe(sidecar).execTransactionFromModule(
            asset, 0, abi.encodeCall(IERC20.transfer, (mainSafe, amount)), 0
        );
        if (!ok) revert ExecFailed();
        if (IERC20(asset).balanceOf(mainSafe) - beforeBal != amount) revert TransferShortfall();

        // THE FLOOR — read AFTER the move; the revert atomically rolls the transfer back.
        uint256 floor = requiredCommittedValue();
        uint256 c = committedValue();
        if (c < floor) revert FreezeFloorBreach(c, floor);

        emit Released(asset, amount, c, floor);
    }
}
