// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionToken} from "../../interfaces/hydrex/IOptionToken.sol";

/// @title ExerciseModule
/// @notice The on-chain seam of the 8-B8 paid-exercise leg (§4.5.1): the fifth engine Zodiac Module (after the 8-B14
///         buy-and-burn, the 8-B5 farm utility loop, the 8-B6 LP strategy, and the 8-B7 harvest/vote), CRE-operator-gated,
///         enabled on the szipUSD engine Safe (`avatar == target == juniorTrancheEngine`). It owns the PAID exercise of the sell
///         slice: per harvest the CRE robot (8-B11) finances the ~30% USDC strike via the 8-B5 borrow (the USDC is
///         already in the Safe), then calls `exercise(amount, maxPayment, deadline)` here — the module approves the
///         strike to oHYDX, calls `oHYDX.exercise(...)` (burns the Safe's oHYDX, pulls the strike USDC, mints liquid
///         HYDX to the Safe), and resets the approval. 8-B9 then market-sells the HYDX to repay the borrow.
///
/// @dev DISTINCT FROM 8-B7's FREE `exerciseVe` permalock: this is the *paid* `oHYDX.exercise` (a different oHYDX
///      function, with a USDC strike). This module has NO EVC leg (the borrow that funds the strike is 8-B5's job),
///      NO oracle, NO LP, NO veNFT — it is pure exercise mechanism.
///
/// @dev SECURITY BOUNDARY (§10.1, the module's whole reason for shape): the operator supplies ONLY scalars (`amount`,
///      `maxPayment`, `deadline`). The module builds ALL calldata to the set-once wired targets (`oHYDX`,
///      `paymentToken`), and the exercise `recipient` is hard-pinned to the literal set-once `juniorTrancheEngine` (the HYDX
///      can only ever mint to the basket, never the operator or a third party). NO generic call/exec passthrough, NO
///      delegatecall, `value == 0` on every `exec`. `maxPayment` is the SLIPPAGE GUARD: oHYDX (immutable, non-proxy,
///      verified on Base) computes the strike from its own TWAP and pulls EXACTLY that, reverting if it would exceed
///      `maxPayment` — so a TWAP spike between the CRE's quote and tx execution safely ABORTS the loop instead of
///      overpaying the basket. Fork-proven: the charge == `quoteStrike(amount)` read in the same block. 8-B11 sets
///      `maxPayment = quoteStrike × a small cushion` (too tight → normal drift reverts; too loose → a spike could be
///      paid). The reset-to-0 (the 3rd exec) leaves no standing approval (hygiene).
///
/// @dev CLONE FACT (§18.6, proven on 8-B14/8-B5/8-B6/8-B7): a `ModuleProxyFactory` clone shares the mastercopy's
///      runtime bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config.
///      EVERY per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT
///      `immutable`. The mastercopy is init-locked in its constructor (see {MastercopyInitLock}).
contract ExerciseModule is MastercopyInitLock {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == juniorTrancheEngine`); the exercise `recipient` + the strike payer.
    address public juniorTrancheEngine;
    /// @notice The single CRE operator (gates the exercise entrypoint).
    address public operator;
    /// @notice The Hydrex option token (oHYDX) — the exercise target.
    address public oHYDX;
    /// @notice The strike payment token (read LIVE in `setUp` off `oHYDX.paymentToken()` — USDC on Base) — the
    ///         `approve` target. Live-read so it can never drift from the option's actual payment token.
    address public paymentToken;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    /// @notice oHYDX reported a `paymentAmount` larger than the operator's `maxPayment` (an honesty guard on the
    ///         emitted event — the USDC approval already bounds the real pull at `maxPayment`).
    error PaymentExceedsMax();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event Exercised(uint256 amount, uint256 paymentAmount);
    /// @notice A Timelock-settable wiring field was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). One-shot via the zodiac-core
    ///         `initializer`. Decodes the 4 addresses `(owner, juniorTrancheEngine, operator, oHYDX)`; reads `paymentToken`
    ///         LIVE off `oHYDX.paymentToken()`. ORDER is load-bearing: validate all four decoded addresses nonzero
    ///         FIRST + `owner != operator` (so a zero `oHYDX` reverts `ZeroAddress`, not a confusing staticcall-to-
    ///         zero), set `avatar = target = juniorTrancheEngine`, store the wiring, THEN read + assert the live `paymentToken`
    ///         nonzero, THEN `_transferOwnership(owner)`.
    function setUp(bytes memory initParams) public override initializer {
        (address owner_, address juniorTrancheEngine_, address operator_, address oHYDX_) =
            abi.decode(initParams, (address, address, address, address));

        if (owner_ == address(0) || juniorTrancheEngine_ == address(0) || operator_ == address(0) || oHYDX_ == address(0)) {
            revert ZeroAddress();
        }
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == juniorTrancheEngine.
        avatar = juniorTrancheEngine_;
        target = juniorTrancheEngine_;

        juniorTrancheEngine = juniorTrancheEngine_;
        operator = operator_;
        oHYDX = oHYDX_;

        // Read the strike payment token LIVE off the wired option (the 8-B7 live-read pattern) — guarantees the
        // `approve` target == the option's actual payment token, fail-closed.
        address paymentToken_ = IOptionToken(oHYDX_).paymentToken();
        if (paymentToken_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;

        _transferOwnership(owner_);
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

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point `juniorTrancheEngine` (build phase, §17). onlyOwner (Timelock). Keeps `avatar`/`target` in sync since the
    ///         module is enabled ON, and only mutates, the engine Safe (avatar == target == juniorTrancheEngine).
    function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
        if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
        juniorTrancheEngine = juniorTrancheEngine_;
        avatar = juniorTrancheEngine_;
        target = juniorTrancheEngine_;
        emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `oHYDX` (build phase, §17). onlyOwner (Timelock). Re-reads `paymentToken` LIVE off the new
    ///         option (fail-closed) so the `approve` target can never drift from the option's actual payment token.
    function setOHYDX(address oHYDX_) external onlyOwner {
        if (oHYDX_ == address(0)) revert ZeroAddress();
        oHYDX = oHYDX_;
        address paymentToken_ = IOptionToken(oHYDX_).paymentToken();
        if (paymentToken_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        emit WiringSet("oHYDX", oHYDX_);
        emit WiringSet("paymentToken", paymentToken_);
    }

    /// @notice Re-point `paymentToken` (build phase, §17). onlyOwner (Timelock). Normally derived LIVE from `oHYDX` (and
    ///         re-derived by `setOHYDX`); exposed for a direct override should the option's payment token need pinning.
    function setPaymentToken(address paymentToken_) external onlyOwner {
        if (paymentToken_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        emit WiringSet("paymentToken", paymentToken_);
    }

    // --------------------------------------------------------------------- the paid exercise (operator-only)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data so the original oHYDX error (e.g. a `maxPayment`-exceeded
    ///      slippage revert or a past-deadline revert) surfaces (the Gnosis Safe `execTransactionFromModuleReturnData`
    ///      catches inner reverts and returns `(false, revertData)` rather than bubbling, so an unchecked `exec` would
    ///      silently swallow a failed exercise and the step would wrongly report success). Returns the inner return
    ///      data (only the exercise call decodes it — the `paymentAmount`).
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

    /// @notice Pay the strike + exercise `amount` oHYDX → liquid HYDX to the Safe. Exactly 3 `exec`s:
    ///         (1) `paymentToken.approve(oHYDX, maxPayment)` — the strike allowance from the Safe;
    ///         (2) `oHYDX.exercise(amount, maxPayment, juniorTrancheEngine, deadline)` — burns the Safe's oHYDX, pulls
    ///             `paymentAmount` (≤ maxPayment) USDC from the Safe, mints HYDX to the Safe, returns `paymentAmount`;
    ///         (3) `paymentToken.approve(oHYDX, 0)` — reset the residual allowance (no standing approval, security
    ///             parity with 8-B5 `repay`).
    /// @param amount The oHYDX to exercise (burned from the Safe).
    /// @param maxPayment The strike slippage bound = the USDC pull ceiling (8-B11 sizes it = quoteStrike × a small
    ///        cushion). oHYDX enforces `paymentAmount <= maxPayment` and reverts otherwise (bubbled via `_exec`).
    /// @param deadline The exercise deadline (oHYDX enforces it; the operator sets `block.timestamp + buffer`).
    /// @return paymentAmount The USDC actually paid (≤ maxPayment).
    function exercise(uint256 amount, uint256 maxPayment, uint256 deadline)
        external
        onlyOperator
        returns (uint256 paymentAmount)
    {
        if (amount == 0 || maxPayment == 0) revert ZeroAmount();

        _exec(paymentToken, abi.encodeWithSelector(IERC20.approve.selector, oHYDX, maxPayment));
        bytes memory ret = _exec(oHYDX, abi.encodeCall(IOptionToken.exercise, (amount, maxPayment, juniorTrancheEngine, deadline)));
        _exec(paymentToken, abi.encodeWithSelector(IERC20.approve.selector, oHYDX, uint256(0)));

        paymentAmount = abi.decode(ret, (uint256));
        // Defense-in-depth: oHYDX already enforces `paymentAmount <= maxPayment` internally (it reverts otherwise), so
        // this re-asserts the same bound on the decoded return rather than trusting the external contract's enforcement
        // — the emitted `Exercised` event / return (which 8-B11/8-B12 accounting reads) can never exceed the authorized
        // strike, even against a malformed return decode.
        if (paymentAmount > maxPayment) revert PaymentExceedsMax();

        emit Exercised(amount, paymentAmount);
    }

    // --------------------------------------------------------------------- view (8-B5/8-B11 back-pressure)
    /// @notice The USDC strike the contract will charge for exercising `amount` oHYDX = `max(getDiscountedPrice(amount),
    ///         getMinPaymentAmount())` (the floor dominates for small `amount`). 8-B5 sizes the borrow + 8-B11 sets the
    ///         `maxPayment` cushion off this.
    function quoteStrike(uint256 amount) external view returns (uint256) {
        uint256 discounted = IOptionToken(oHYDX).getDiscountedPrice(amount);
        uint256 floor = IOptionToken(oHYDX).getMinPaymentAmount();
        return discounted > floor ? discounted : floor;
    }
}
