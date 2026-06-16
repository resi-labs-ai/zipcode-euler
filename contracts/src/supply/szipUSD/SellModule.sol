// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "../../interfaces/algebra/ISwapRouter.sol";

/// @title SellModule
/// @notice The on-chain swap seam of the 8-B9 market-sell leg (§4.5.1): the sixth engine Zodiac Module (after the
///         8-B14 buy-and-burn, the 8-B5 reservoir loop, the 8-B6 LP strategy, the 8-B7 harvest/vote, and the 8-B8
///         exercise), CRE-operator-gated, enabled on the szipUSD engine Safe (`avatar == target == engineSafe`). It
///         owns the SWAP leg of the auto-compounder: per harvest the CRE robot (8-B11) market-sells the exercised HYDX
///         (from 8-B8) → USDC immediately so it can then repay the 8-B5 strike-borrow (`debtOf(safe)→0`), and it also
///         runs the zipUSD→xALPHA on-our-POL swap that the 8-B10/8-B13 recycle/compound Modes B/C consume.
///
/// @dev DISTINCT FROM the siblings: this is the Algebra `SwapRouter.exactInputSingle` market-sell — NO EVC leg, NO
///      oracle, NO LP, NO veNFT, NO oHYDX exercise, NO repay (the repay that consumes the proceeds is 8-B5's
///      `ReservoirLoopModule.repay`, sequenced by the CRE robot AFTER this sell). It is pure swap mechanism.
///
/// @dev SECURITY BOUNDARY (§10.1, the module's whole reason for shape): the operator supplies ONLY scalars (`amountIn`,
///      `minOut`, `deadline`). The module builds ALL calldata to the set-once wired targets (`swapRouter`, the token
///      pair), `deployer` is hard-pinned to address(0) (the HYDX/USDC + POL pools are base-factory pools, verified),
///      `recipient` is hard-pinned to the literal set-once `engineSafe` (the output token can only ever land in the
///      basket, never the operator or a third party), and `tokenIn`/`tokenOut` are hard-pinned per entrypoint. NO
///      generic call/exec passthrough, NO arbitrary token pair, NO delegatecall, `value == 0` on every `exec`. `minOut`
///      is the SLIPPAGE GUARD: the Algebra router enforces `amountOut >= amountOutMinimum` and reverts otherwise (the
///      revert bubbles through `_exec`), so a price move between the CRE's quote and tx execution safely ABORTS the swap
///      instead of dumping at a bad price. 8-B11 sizes `minOut = expectedOut × (1 − the §9.3 slippage cap)`. The
///      reset-to-0 (the 3rd exec) leaves no standing approval (hygiene). The per-epoch soft-bleed cap is a SIZE GATE
///      enforced UPSTREAM (8-B8 exercise size) + at the 8-B11/8-B12 CRE/monitoring layer, NOT on-chain (§4.5.1 / §17).
///
/// @dev CLONE FACT (§18.6, proven on 8-B14/8-B5/8-B6/8-B7/8-B8): a `ModuleProxyFactory` clone shares the mastercopy's
///      runtime bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY
///      per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`. The
///      mastercopy is init-locked in its constructor (see {MastercopyInitLock}).
contract SellModule is MastercopyInitLock {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == engineSafe`); the swap `recipient` + the `tokenIn` holder.
    address public engineSafe;
    /// @notice The single CRE operator (gates both swap entrypoints).
    address public operator;
    /// @notice The Algebra Integral `SwapRouter` (the swap target + the approve spender).
    address public swapRouter;
    /// @notice HYDX — the `sellHydx` input token.
    address public hydx;
    /// @notice USDC — the `sellHydx` output token.
    address public usdc;
    /// @notice zipUSD — the `buyXAlpha` input token (our `ESynth`, wired at deploy).
    address public zipUSD;
    /// @notice xALPHA — the `buyXAlpha` output token (the bridge stand-in, wired at deploy).
    address public xAlpha;
    /// @notice The HARD per-call ceiling on `sellHydx`'s `amountIn` (HYDX, 18-dp). A defense-in-depth SIZE backstop:
    ///         `minOut` bounds only PRICE (slippage), never SIZE, so a compromised operator could otherwise dump the
    ///         whole HYDX basket in one tx (`minOut = 1`) and crater HYDX (we are long it via veHYDX + the LP). This
    ///         cap bounds any single sell to the intended weekly clip (default 300_000e18 ≈ ~3% slippage ≈ ~$10k on
    ///         the live pool, wired at deploy). Owner(Timelock)-settable so it can track pool depth as it changes; the
    ///         per-epoch THROUGHPUT cap remains 8-B11/8-B12 CRE/monitoring policy (§4.5.1 / §17). It is set-once
    ///         config, NOT a running accumulator — the module stays stateless beyond wiring. The buy leg is NOT capped
    ///         here (different token; bounded upstream by 8-B10's `freeValueAccrued` gate).
    uint256 public maxSellHydx;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    /// @notice `sellHydx`'s `amountIn` exceeded the governed per-call `maxSellHydx` size ceiling.
    error ExceedsMaxSell();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event Sold(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event MaxSellHydxSet(uint256 maxSellHydx);
    /// @notice A Timelock-settable wiring slot was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). One-shot via the zodiac-core
    ///         `initializer`. Decodes the 8 addresses
    ///         `(owner, engineSafe, operator, swapRouter, hydx, usdc, zipUSD, xAlpha)` + the `uint256 maxSellHydx`
    ///         per-call HYDX size ceiling. ORDER is load-bearing: validate all eight decoded addresses nonzero FIRST +
    ///         `owner != operator` (so a zero address reverts `ZeroAddress` deterministically before any use), assert
    ///         `maxSellHydx > 0` (`ZeroAmount` — a zero cap would brick `sellHydx`), set `avatar = target = engineSafe`,
    ///         store the wiring + the cap, THEN `_transferOwnership(owner)`. NO live-read / staticcall in `setUp` — all
    ///         tokens are wired directly.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address engineSafe_,
            address operator_,
            address swapRouter_,
            address hydx_,
            address usdc_,
            address zipUSD_,
            address xAlpha_,
            uint256 maxSellHydx_
        ) = abi.decode(
            initParams, (address, address, address, address, address, address, address, address, uint256)
        );

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0) || swapRouter_ == address(0)
                || hydx_ == address(0) || usdc_ == address(0) || zipUSD_ == address(0) || xAlpha_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (owner_ == operator_) revert OwnerIsOperator();
        if (maxSellHydx_ == 0) revert ZeroAmount();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == engineSafe.
        avatar = engineSafe_;
        target = engineSafe_;

        engineSafe = engineSafe_;
        operator = operator_;
        swapRouter = swapRouter_;
        hydx = hydx_;
        usdc = usdc_;
        zipUSD = zipUSD_;
        xAlpha = xAlpha_;
        maxSellHydx = maxSellHydx_;
        emit MaxSellHydxSet(maxSellHydx_);

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- governed cap setter (owner = Timelock)
    /// @notice Update the per-call `sellHydx` size ceiling. `onlyOwner` (the Timelock, NOT the hot CRE operator) so a
    ///         re-size to track pool depth is a deliberate timelocked act. Reverts `ZeroAmount` on a zero cap.
    function setMaxSellHydx(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert ZeroAmount();
        maxSellHydx = newMax;
        emit MaxSellHydxSet(newMax);
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    // Re-point any cross-component wired address for build-phase flexibility. `onlyOwner` (the Timelock, NOT the hot CRE
    // operator) so every redirect is a deliberate timelocked act. Numeric/format params (e.g. `maxSellHydx`) are NOT
    // here — only address wiring. Each rejects address(0) and emits `WiringSet`.

    /// @notice Re-point `engineSafe` (build phase, §17). onlyOwner (Timelock). Keeps `avatar`/`target` in sync since the
    ///         module is enabled ON the engine Safe and only ever mutates it (`avatar == target == engineSafe`).
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
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `swapRouter` (build phase, §17). onlyOwner (Timelock).
    function setSwapRouter(address swapRouter_) external onlyOwner {
        if (swapRouter_ == address(0)) revert ZeroAddress();
        swapRouter = swapRouter_;
        emit WiringSet("swapRouter", swapRouter_);
    }

    /// @notice Re-point `hydx` (build phase, §17). onlyOwner (Timelock).
    function setHydx(address hydx_) external onlyOwner {
        if (hydx_ == address(0)) revert ZeroAddress();
        hydx = hydx_;
        emit WiringSet("hydx", hydx_);
    }

    /// @notice Re-point `usdc` (build phase, §17). onlyOwner (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point `zipUSD` (build phase, §17). onlyOwner (Timelock).
    function setZipUSD(address zipUSD_) external onlyOwner {
        if (zipUSD_ == address(0)) revert ZeroAddress();
        zipUSD = zipUSD_;
        emit WiringSet("zipUSD", zipUSD_);
    }

    /// @notice Re-point `xAlpha` (build phase, §17). onlyOwner (Timelock).
    function setXAlpha(address xAlpha_) external onlyOwner {
        if (xAlpha_ == address(0)) revert ZeroAddress();
        xAlpha = xAlpha_;
        emit WiringSet("xAlpha", xAlpha_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the hot
    //      key) CANNOT call them — only `owner` (the Timelock) can, and a redirect by governance is a deliberate
    //      timelocked act, not an attack path. We do NOT hard-lock them (that would require marking the vendored
    //      zodiac-core setters `virtual` — reference deps stay pristine). Tested: a non-owner caller reverts.

    // --------------------------------------------------------------------- the market sells (operator-only)
    /// @notice Market-sell `amountIn` HYDX → USDC into the Safe (the strike-loop repay leg). `_swap(hydx, usdc, ...)`.
    /// @param amountIn The HYDX to sell (pulled from the Safe). MUST be `<= maxSellHydx` (the governed size backstop).
    /// @param minOut The slippage floor (the router reverts if `amountOut < minOut`; the meaningful floor is 8-B11's).
    /// @param deadline The swap deadline (the router enforces it; the operator sets `block.timestamp + buffer`).
    /// @return amountOut The USDC received (≥ minOut), sent to the Safe.
    function sellHydx(uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        onlyOperator
        returns (uint256 amountOut)
    {
        if (amountIn > maxSellHydx) revert ExceedsMaxSell();
        amountOut = _swap(hydx, usdc, amountIn, minOut, deadline);
    }

    /// @notice Buy `amountOut` xALPHA with `amountIn` zipUSD on our POL (the Mode-B/C buy leg, consumed by 8-B10/8-B13).
    ///         `_swap(zipUSD, xAlpha, ...)` — identical mechanism on the wired POL pair.
    /// @param amountIn The zipUSD to spend (pulled from the Safe).
    /// @param minOut The slippage floor (the router reverts if `amountOut < minOut`).
    /// @param deadline The swap deadline (the router enforces it).
    /// @return amountOut The xALPHA received (≥ minOut), sent to the Safe.
    function buyXAlpha(uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        onlyOperator
        returns (uint256 amountOut)
    {
        amountOut = _swap(zipUSD, xAlpha, amountIn, minOut, deadline);
    }

    /// @notice Sell `amountIn` xALPHA → zipUSD on our POL — the reverse of `buyXAlpha`, same wired pair. It unstrands
    ///         the xALPHA leg: after `LpStrategyModule.removeLiquidity` decomposes the LP into zipUSD + xALPHA, this
    ///         routes the xALPHA back to zipUSD (then zipUSD exits to USDC via the senior par queue — xALPHA has no
    ///         direct USDC pool, it is the bridge stand-in). It is the on-module xALPHA→USDC hop the global wind-down
    ///         previously lacked, and it equally lets the protocol **accept xALPHA** (e.g. incentive/LM strategies
    ///         that take xALPHA in) and recycle it to zipUSD on demand.
    /// @dev    NO size cap (unlike `sellHydx`). The `maxSellHydx` backstop exists because the oHYDX harvest system
    ///         becomes unprofitable past a clip — a HYDX-specific ceiling. xALPHA has no such profitability ceiling
    ///         (it is our own POL asset, sold back into our own pair), so a per-call size cap would be arbitrary;
    ///         `minOut` + `deadline` remain the price/staleness guards, and throughput stays 8-B11/8-B12 CRE policy.
    /// @param amountIn The xALPHA to sell (pulled from the Safe).
    /// @param minOut The slippage floor (the router reverts if `amountOut < minOut`).
    /// @param deadline The swap deadline (the router enforces it).
    /// @return amountOut The zipUSD received (≥ minOut), sent to the Safe.
    function sellXAlpha(uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        onlyOperator
        returns (uint256 amountOut)
    {
        amountOut = _swap(xAlpha, zipUSD, amountIn, minOut, deadline);
    }

    // --------------------------------------------------------------------- the swap mechanism (shared)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data so the original router error (e.g. a `minOut` slippage revert
    ///      or a past-deadline revert) surfaces (the Gnosis Safe `execTransactionFromModuleReturnData` catches inner
    ///      reverts and returns `(false, revertData)` rather than bubbling, so an unchecked `exec` would silently
    ///      swallow a failed swap and the step would wrongly report success). Returns the inner return data (only the
    ///      `exactInputSingle` call decodes it — the `amountOut`).
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

    /// @dev The approve → exactInputSingle → reset-approve dance. Exactly 3 `exec`s, in order:
    ///      (1) `tokenIn.approve(swapRouter, amountIn)` — the swap allowance from the Safe;
    ///      (2) `swapRouter.exactInputSingle(params)` — pulls `amountIn` tokenIn from the Safe, sends `amountOut`
    ///          tokenOut to the Safe (`amountOut >= minOut` or it reverts), returns `amountOut`. `deployer` pinned to
    ///          address(0) (base-factory pool), `recipient` pinned to `engineSafe`, `limitSqrtPrice` pinned to 0.
    ///          TYPED `encodeCall`, NOT `encodeWithSelector` — a struct-field-order regression fails to compile;
    ///      (3) `tokenIn.approve(swapRouter, 0)` — reset the residual allowance (no standing approval).
    ///      Only the 2nd `_exec` return is decoded (`amountOut`); the two `approve` returns are ignored.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        private
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || minOut == 0) revert ZeroAmount();

        address router = swapRouter;
        _exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, router, amountIn));
        bytes memory ret = _exec(
            router,
            abi.encodeCall(
                ISwapRouter.exactInputSingle,
                (
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        deployer: address(0),
                        recipient: engineSafe,
                        deadline: deadline,
                        amountIn: amountIn,
                        amountOutMinimum: minOut,
                        limitSqrtPrice: 0
                    })
                )
            )
        );
        _exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, router, uint256(0)));

        amountOut = abi.decode(ret, (uint256));
        emit Sold(tokenIn, tokenOut, amountIn, amountOut);
    }
}
