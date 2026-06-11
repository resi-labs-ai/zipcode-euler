// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IVammPair} from "../interfaces/hydrex/IVammPair.sol";
import {IGauge} from "../interfaces/hydrex/IGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LpStrategyModuleDemoVAMM
/// @notice DEMO/SHOWCASE fork of `LpStrategyModule` (8-B6) — outside the audited core. Identical to the prod module
///         EXCEPT the LP-mint seam: it builds a **Solidly vAMM pair** LP (`addLiquidity` → transfer both legs to the
///         pair → `IVammPair.mint`) instead of an ICHI vault deposit, so the auto-compounder can be shown running on
///         mainnet BEFORE our real zipUSD/xALPHA ICHI pool exists. `stake`/`unstake` are unchanged (the gauge
///         interface `IGauge.deposit/withdraw(uint256)` is the same; the pair IS the LP token). Wire it to the live
///         vAMM HYDX/USDC pair + its gauge; enable it on the EXISTING engine Safe via Zodiac `enableModule` for the
///         show, `disableModule` after. The prod `LpStrategyModule` stays enabled + untouched. Pairs with the demo
///         oracle `SzipNavOracleDemoVAMM` (the paired oracle fork). See `build/wires/SHOWCASE-VAMM.md`.
///
/// @notice [prod docstring, unchanged below] The on-chain seam of the 8-B6 LP strategy (§4.5.1): the third engine
///         Zodiac Module, CRE-operator-gated, enabled on the szipUSD engine Safe (`avatar == target == engineSafe`).
///         It owns the LP's whole lifecycle: build the LP (`addLiquidity`), gauge-stake it to farm oHYDX (`stake` →
///         `IGauge.deposit`), and unstake/re-stake slices for the 8-B5 harvest loop (`unstake` → `IGauge.withdraw`).
///         The LP token IS the pool/pair contract; the gauge custodies the staked LP.
///
/// @dev SECURITY BOUNDARY (§10.1, the module's whole reason for shape): the operator supplies ONLY scalar amounts
///      (`deposit0`/`deposit1`/`minShares`/`lpAmount`). The module builds ALL calldata to the set-once wired targets
///      (`ichiVault`/`gauge`/`token0`/`token1`), the deposit `to` is the literal set-once `engineSafe`, and every
///      balance read is `engineSafe`. NO generic call/exec passthrough, NO delegatecall, `value == 0` on every
///      `exec`. There is no EVC leg (the module never borrows) — the gauge/vault calls credit/debit the Safe purely
///      because the Safe is the `exec` msg.sender. The module writes NO storage in any mutating path (no live-bid
///      analog) and holds no custody — the Safe holds the tokens, the LP, and the staked position.
///
/// @dev CLONE FACT (§18.6, proven on 8-B14/8-B5): a `ModuleProxyFactory` clone shares the mastercopy's runtime
///      bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY
///      per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`.
///      The mastercopy is init-locked at deploy.
contract LpStrategyModuleDemoVAMM is Module {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == engineSafe`); the deposit `to` + every balance read.
    address public engineSafe;
    /// @notice The single CRE operator (gates `addLiquidity`/`stake`/`unstake`).
    address public operator;
    /// @notice DEMO: the Solidly vAMM **pair** (the pair contract IS the LP token, an 18-dp ERC20). Named `ichiVault`
    ///         so the `setUp` ABI + setters + deploy wiring stay identical to the prod module — it holds the vAMM pair.
    address public ichiVault;
    /// @notice The Hydrex gauge over our pool (staking the LP here is what earns oHYDX; the claim is 8-B7).
    address public gauge;
    /// @notice The ICHI vault's `token0()` (read live in `setUp`) — the approval target for the `deposit0` leg.
    address public token0;
    /// @notice The ICHI vault's `token1()` (read live in `setUp`) — the approval target for the `deposit1` leg.
    address public token1;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    /// @notice `minShares == 0` — the slippage floor must be a real bound (a zero floor would no-op the only
    ///         sandwich protection on a direct ICHI deposit; the CRE robot always sizes a non-zero floor).
    error ZeroMinShares();
    /// @notice The ICHI `deposit` minted fewer shares than the operator-supplied `minShares` floor (sandwiched / thin).
    error Slippage();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event LiquidityAdded(uint256 deposit0, uint256 deposit1, uint256 shares);
    event Staked(uint256 lpAmount);
    event Unstaked(uint256 lpAmount);
    /// @notice A Timelock-settable wiring field was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (or the mastercopy at deploy, then init-locked). One-shot via the zodiac-core
    ///         `initializer`. Decodes `(owner, engineSafe, operator, ichiVault, gauge)`; reads `token0`/`token1` LIVE
    ///         off the vault. ORDER is load-bearing: validate the five addresses nonzero FIRST (so an `ichiVault == 0`
    ///         reverts `ZeroAddress`, not the live `token0()` staticcall), then read + assert the tokens nonzero.
    function setUp(bytes memory initParams) public override initializer {
        (address owner_, address engineSafe_, address operator_, address ichiVault_, address gauge_) =
            abi.decode(initParams, (address, address, address, address, address));

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0) || ichiVault_ == address(0)
                || gauge_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == engineSafe.
        avatar = engineSafe_;
        target = engineSafe_;

        engineSafe = engineSafe_;
        operator = operator_;
        ichiVault = ichiVault_;
        gauge = gauge_;

        // Read the LP legs LIVE off the wired vault (the SzipBuyBurnModule.setUp pattern) — guarantees the approved
        // tokens match the vault and removes two setUp args.
        address t0 = IVammPair(ichiVault_).token0();
        address t1 = IVammPair(ichiVault_).token1();
        if (t0 == address(0) || t1 == address(0)) revert ZeroAddress();
        token0 = t0;
        token1 = t1;

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    // Re-point cross-component wiring during the build phase. onlyOwner == the Timelock (a deliberate timelocked act,
    // never the hot CRE `operator`). These mirror the set-once `setUp` wiring; numeric/format params (minShares floors,
    // decimals) are NOT settable. `avatar`/`target` (also onlyOwner via zodiac-core) track `engineSafe`.

    /// @notice Re-point `engineSafe` (build phase, §17). onlyOwner (Timelock). Keeps `avatar`/`target` in lockstep
    ///         (the module is enabled ON the engine Safe and only ever mutates it).
    function setEngineSafe(address engineSafe_) external onlyOwner {
        if (engineSafe_ == address(0)) revert ZeroAddress();
        engineSafe = engineSafe_;
        avatar = engineSafe_;
        target = engineSafe_;
        emit WiringSet("engineSafe", engineSafe_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `ichiVault` (build phase, §17). onlyOwner (Timelock).
    function setIchiVault(address ichiVault_) external onlyOwner {
        if (ichiVault_ == address(0)) revert ZeroAddress();
        ichiVault = ichiVault_;
        emit WiringSet("ichiVault", ichiVault_);
    }

    /// @notice Re-point `gauge` (build phase, §17). onlyOwner (Timelock).
    function setGauge(address gauge_) external onlyOwner {
        if (gauge_ == address(0)) revert ZeroAddress();
        gauge = gauge_;
        emit WiringSet("gauge", gauge_);
    }

    /// @notice Re-point `token0` (build phase, §17). onlyOwner (Timelock).
    function setToken0(address token0_) external onlyOwner {
        if (token0_ == address(0)) revert ZeroAddress();
        token0 = token0_;
        emit WiringSet("token0", token0_);
    }

    /// @notice Re-point `token1` (build phase, §17). onlyOwner (Timelock).
    function setToken1(address token1_) external onlyOwner {
        if (token1_ == address(0)) revert ZeroAddress();
        token1 = token1_;
        emit WiringSet("token1", token1_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the
    //      hot key) CANNOT call them — only `owner` (the Timelock) can, and a redirect by governance is a deliberate
    //      timelocked act, not an attack path. We do NOT hard-lock them (that would require marking the vendored
    //      zodiac-core setters `virtual` — reference deps stay pristine). Tested: a non-owner caller reverts.

    // --------------------------------------------------------------------- the LP lifecycle (operator-only)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data so the original ICHI/gauge error surfaces (the Gnosis Safe
    ///      `execTransactionFromModuleReturnData` catches inner reverts and returns `(false, revertData)` rather than
    ///      bubbling, so an unchecked `exec` would silently swallow a failed deposit/stake and the step would wrongly
    ///      report success). Returns the inner return data (the ICHI `deposit` share-return is decoded from it).
    function _exec(address to, bytes memory data) private returns (bytes memory) {
        (bool ok, bytes memory ret) = execAndReturnData(to, 0, data, Operation.Call);
        if (!ok) {
            if (ret.length == 0) revert ExecFailed();
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Build the zipUSD/xALPHA ICHI LP: approve + deposit (single-sided ⇒ one side 0; balanced ⇒ both > 0,
    ///         the 8-B13 Mode-C path) + reset the approvals. The minted LP lands in the engine Safe.
    /// @param deposit0   token0 amount to add (0 to skip the token0 leg).
    /// @param deposit1   token1 amount to add (0 to skip the token1 leg).
    /// @param minShares  the non-zero slippage floor — revert `Slippage` if the deposit mints fewer LP shares.
    /// @return shares    the LP shares minted to the Safe.
    function addLiquidity(uint256 deposit0, uint256 deposit1, uint256 minShares)
        external
        onlyOperator
        returns (uint256 shares)
    {
        if (deposit0 == 0 && deposit1 == 0) revert ZeroAmount();
        if (minShares == 0) revert ZeroMinShares();

        // DEMO vAMM add (Solidly): the pair IS the LP token — transfer both legs STRAIGHT to it, then `mint(to)`
        // credits LP to the Safe. NO approval (direct `transfer`, not `transferFrom`). The operator MUST size
        // deposit0:deposit1 ~ the live reserve ratio (`getReserves()`); any excess of one side is donated to the pool
        // (Solidly `mint` keeps the lesser-side ratio). `minShares` is the slippage floor against a bad ratio.
        if (deposit0 != 0) {
            _exec(token0, abi.encodeWithSelector(IERC20.transfer.selector, ichiVault, deposit0));
        }
        if (deposit1 != 0) {
            _exec(token1, abi.encodeWithSelector(IERC20.transfer.selector, ichiVault, deposit1));
        }

        bytes memory ret = _exec(ichiVault, abi.encodeCall(IVammPair.mint, (engineSafe)));
        shares = abi.decode(ret, (uint256));

        if (shares < minShares) revert Slippage();

        emit LiquidityAdded(deposit0, deposit1, shares);
    }

    /// @notice Gauge-stake an LP slice to (resume) earning oHYDX (the build/stake step + the 8-B5 loop step 7
    ///         re-stake). Exactly 3 `exec`s (approve / deposit / reset). The LP token == `ichiVault`.
    function stake(uint256 lpAmount) external onlyOperator {
        if (lpAmount == 0) revert ZeroAmount();
        _exec(ichiVault, abi.encodeWithSelector(IERC20.approve.selector, gauge, lpAmount));
        _exec(gauge, abi.encodeCall(IGauge.deposit, (lpAmount)));
        _exec(ichiVault, abi.encodeWithSelector(IERC20.approve.selector, gauge, uint256(0)));
        emit Staked(lpAmount);
    }

    /// @notice Un-stake an LP slice from the gauge back to the Safe (the 8-B5 loop step 1, before `postCollateral`).
    ///         Exactly 1 `exec`. The gauge returns the LP to the Safe (= the gauge call's msg.sender).
    function unstake(uint256 lpAmount) external onlyOperator {
        if (lpAmount == 0) revert ZeroAmount();
        _exec(gauge, abi.encodeCall(IGauge.withdraw, (lpAmount)));
        emit Unstaked(lpAmount);
    }

    // --------------------------------------------------------------------- views (8-B5/8-B11/8-B12 back-pressure)
    /// @notice The gauge-staked LP balance (read live from the gauge; 8-B5 sizes the unstake slice off it).
    function stakedBalance() external view returns (uint256) {
        return IGauge(gauge).balanceOf(engineSafe);
    }

    /// @notice The unstaked LP sitting in the Safe (read live from the pair LP token).
    function lpBalance() external view returns (uint256) {
        return IVammPair(ichiVault).balanceOf(engineSafe);
    }
}
