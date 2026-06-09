// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IERC4626 as IEVKERC4626} from "evk/EVault/IEVault.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReservoirLoopModule
/// @notice The on-chain seam of the 8-B5 strike-financing loop (§4.5.1): the second engine Zodiac Module (after the
///         8-B14 buy-and-burn), CRE-operator-gated, enabled on the szipUSD engine Safe (`avatar == target ==
///         engineSafe`). It drives the **Safe's own EVC account** (borrower-of-record = the Safe, NOT a fresh
///         `LineAccount`) through the four loop entrypoints — `postCollateral` / `borrow` / `repay` /
///         `withdrawCollateral`. Per harvest the CRE robot unstakes an LP slice (8-B6), POSTS it as collateral here,
///         BORROWS the ~30% strike USDC from the warehouse resting vault (8-B8 exercises → 8-B9 sells), REPAYS the
///         borrow, and WITHDRAWS the LP to re-stake. The LP self-collateralizes its own oHYDX strike.
///
/// @dev SECURITY BOUNDARY (§10.1, the module's whole reason for shape): the operator supplies ONLY scalar amounts
///      (`lpAmount` / `usdcAmount`). The module builds ALL calldata to the set-once wired targets
///      (`lpToken`/`escrowVault`/`borrowVault`/`usdc`/`evc`), and every borrow/repay/withdraw `receiver`/`owner` and
///      every EVC `onBehalfOfAccount` is the literal set-once `engineSafe`. NO generic call/exec passthrough, NO
///      delegatecall, `value == 0` on every `exec`. The borrow/repay/withdraw are run on behalf of the Safe via
///      `IEVC.call(target, engineSafe, 0, ...)` — the Safe is the EVC msg.sender and owns the EVC account whose
///      address == the Safe address (sub-account 0), so the on-behalf is authorized with NO operator bit.
///
/// @dev CLONE FACT (§18.6, proven on 8-B14): a `ModuleProxyFactory` clone shares the mastercopy's runtime bytecode,
///      so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY per-clone wired
///      address/param is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`. The
///      mastercopy is init-locked at deploy.
contract ReservoirLoopModule is Module {
    /// @notice The EVK `OP_BORROW` op bit (`1 << 6`) — reference only (the guard is installed by the deployer).
    uint32 internal constant OP_BORROW = 1 << 6;

    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == engineSafe`); the borrower-of-record + every receiver/owner.
    address public engineSafe;
    /// @notice The single CRE operator (gates the four loop entrypoints).
    address public operator;
    /// @notice The Ethereum Vault Connector.
    address public evc;
    /// @notice The reservoir USDC borrow vault (the warehouse resting USDC vault; created by the deployer).
    address public borrowVault;
    /// @notice The LP escrow collateral vault (the bare 1:1 holding box; created by the deployer).
    address public escrowVault;
    /// @notice The ICHI LP share token (the collateral asset; 8-B6 mints it).
    address public lpToken;
    /// @notice USDC (the borrow asset; 6-dp).
    address public usdc;

    // --------------------------------------------------------------------- governed param (onlyOwner setter)
    /// @notice The AGGREGATE outstanding-debt bound (security F1): a `borrow` requires `debtOf(engineSafe) + amount
    ///         <= borrowCap`. `borrowCap == 0` ⇒ every `borrow` reverts (the kill-switch). NOT operator-settable.
    uint256 public borrowCap;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    error CapExceeded();
    error DebtOutstanding();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts — e.g. an EVC
    ///         account-status `E_AccountLiquidity`, a `PriceOracle_*` revert, or `E_RepayTooMuch`). We surface it as a
    ///         hard revert so a failed loop step never reports success (otherwise the operator would believe a borrow
    ///         landed when it did not).
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event CollateralPosted(uint256 lpAmount);
    event Borrowed(uint256 usdcAmount);
    event Repaid(uint256 usdcAmount);
    event CollateralWithdrawn(uint256 lpAmount);
    event BorrowCapSet(uint256 borrowCap);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (or the mastercopy at deploy, then init-locked). One-shot via the zodiac-core
    ///         `initializer`. Decodes `(owner, engineSafe, operator, evc, borrowVault, escrowVault, lpToken, usdc,
    ///         borrowCap)`. All addresses nonzero; `owner != operator`; `avatar = target = engineSafe`.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address engineSafe_,
            address operator_,
            address evc_,
            address borrowVault_,
            address escrowVault_,
            address lpToken_,
            address usdc_,
            uint256 borrowCap_
        ) = abi.decode(
            initParams,
            (address, address, address, address, address, address, address, address, uint256)
        );

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0) || evc_ == address(0)
                || borrowVault_ == address(0) || escrowVault_ == address(0) || lpToken_ == address(0)
                || usdc_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == engineSafe.
        avatar = engineSafe_;
        target = engineSafe_;

        engineSafe = engineSafe_;
        operator = operator_;
        evc = evc_;
        borrowVault = borrowVault_;
        escrowVault = escrowVault_;
        lpToken = lpToken_;
        usdc = usdc_;
        borrowCap = borrowCap_;

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

    // --------------------------------------------------------------------- governed param
    /// @notice Set the AGGREGATE outstanding-debt cap. `onlyOwner` (the Timelock), NOT operator (security F1).
    function setBorrowCap(uint256 borrowCap_) external onlyOwner {
        borrowCap = borrowCap_;
        emit BorrowCapSet(borrowCap_);
    }

    // --------------------------------------------------------------------- the loop (operator-only)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data so the original error surfaces (EVK `E_AccountLiquidity`,
    ///      `EulerRouter` `PriceOracle_TooStale`/`_NotSupported`, EVK `E_RepayTooMuch`, …). The Gnosis Safe
    ///      `execTransactionFromModule(ReturnData)` catches inner reverts and returns `(false, revertData)` rather than
    ///      bubbling, so an unchecked `exec` would silently swallow a failed EVC borrow/repay/withdraw and the step
    ///      would wrongly report success. If the Safe returns no revert data, fall back to `ExecFailed`.
    function _exec(address to, bytes memory data) private {
        (bool ok, bytes memory ret) = execAndReturnData(to, 0, data, Operation.Call);
        if (!ok) {
            if (ret.length == 0) revert ExecFailed();
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Loop steps 1–2: approve + enable + deposit the unstaked LP slice as collateral. Exactly 3 `exec`s.
    function postCollateral(uint256 lpAmount) external onlyOperator {
        if (lpAmount == 0) revert ZeroAmount();

        _exec(lpToken, abi.encodeWithSelector(IERC20.approve.selector, escrowVault, lpAmount));
        // idempotent — a re-enable is an EVC no-op.
        _exec(evc, abi.encodeCall(IEVC.enableCollateral, (engineSafe, escrowVault)));
        _exec(escrowVault, abi.encodeCall(IEVKERC4626.deposit, (lpAmount, engineSafe)));

        emit CollateralPosted(lpAmount);
    }

    /// @notice Loop step 3: borrow the strike USDC on behalf of the Safe. Exactly 2 `exec`s (after the cap check).
    function borrow(uint256 usdcAmount) external onlyOperator {
        if (usdcAmount == 0) revert ZeroAmount();
        // AGGREGATE outstanding bound (security F1): borrowCap == 0 ⇒ always reverts (kill-switch).
        if (IBorrowing(borrowVault).debtOf(engineSafe) + usdcAmount > borrowCap) revert CapExceeded();

        // idempotent.
        _exec(evc, abi.encodeCall(IEVC.enableController, (engineSafe, borrowVault)));
        // borrow on behalf of the Safe; receiver = the Safe. The EVC end-of-call account-status check enforces
        // health via the router → LP oracle (over-LTV reverts E_AccountLiquidity; a stale/missing mark reverts).
        _exec(
            evc,
            abi.encodeCall(
                IEVC.call,
                (borrowVault, engineSafe, 0, abi.encodeCall(IBorrowing.borrow, (usdcAmount, engineSafe)))
            )
        );

        emit Borrowed(usdcAmount);
    }

    /// @notice Loop step 5: repay the borrow from the Safe's USDC. Exactly 3 `exec`s (approve / repay / reset).
    function repay(uint256 usdcAmount) external onlyOperator {
        if (usdcAmount == 0) revert ZeroAmount();

        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, borrowVault, usdcAmount));
        // 2nd arg `receiver` = the account whose debt is reduced = engineSafe. NOTE: EVK `repay` reverts
        // `E_RepayTooMuch` for a literal amount > outstanding debt (only `type(uint256).max` means "all") — the
        // operator repays the EXACT strike it borrowed.
        _exec(
            evc,
            abi.encodeCall(
                IEVC.call,
                (borrowVault, engineSafe, 0, abi.encodeCall(IBorrowing.repay, (usdcAmount, engineSafe)))
            )
        );
        // reset the residual approval (leave no standing approval — security F13).
        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, borrowVault, uint256(0)));

        emit Repaid(usdcAmount);
    }

    /// @notice Loop step 6: release the LP from escrow back to the Safe (to re-stake). Exactly 1 `exec`.
    function withdrawCollateral(uint256 lpAmount) external onlyOperator {
        if (lpAmount == 0) revert ZeroAmount();
        // defense in depth — the EVC would block an unhealthy withdraw anyway; fail fast + make it testable.
        if (IBorrowing(borrowVault).debtOf(engineSafe) != 0) revert DebtOutstanding();

        // owner = receiver = the Safe. The controller may stay enabled (next loop's enable is idempotent).
        _exec(
            evc,
            abi.encodeCall(
                IEVC.call,
                (escrowVault, engineSafe, 0, abi.encodeCall(IEVKERC4626.withdraw, (lpAmount, engineSafe, engineSafe)))
            )
        );

        emit CollateralWithdrawn(lpAmount);
    }

    // --------------------------------------------------------------------- views (8-B11/8-B12 back-pressure)
    /// @notice The live outstanding reservoir debt (read from the vault, NOT a cached field).
    function outstandingDebt() external view returns (uint256) {
        return IBorrowing(borrowVault).debtOf(engineSafe);
    }

    /// @notice The live posted collateral (escrow shares held by the Safe).
    function postedCollateral() external view returns (uint256) {
        return IEVault(escrowVault).balanceOf(engineSafe);
    }
}
