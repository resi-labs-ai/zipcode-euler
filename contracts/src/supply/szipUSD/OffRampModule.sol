// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The minimal `ZipRedemptionQueue` surface this module drives (the BUILT item-9 senior off-ramp,
///      `contracts/src/supply/ZipRedemptionQueue.sol`). `scaleUp()` is read LIVE (mutable storage re-derived on
///      `setTokens`); `requestRedeem`'s positional args are `(shares, requester, owner)`; `withdraw`'s are
///      `(assets, receiver, requester)`.
interface IZipRedemptionQueue {
    function scaleUp() external view returns (uint256);
    function requestRedeem(uint256 shares, address requester, address owner) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address requester) external returns (uint256);
}

/// @title OffRampModule (credit-union.md C1)
/// @notice The treasury's zipUSD → USDC par off-ramp driver: a CRE-operator-gated Zodiac Module enabled on the
///         main/Baal/rq Safe (`avatar == target == juniorTrancheSafe`). It turns the basket's idle zipUSD into USDC by driving
///         the BUILT `ZipRedemptionQueue` (item 9) — sourcing the USDC the treasury bids exits with from un-lent
///         EulerEarn cash — with NO new redemption logic. Pure driver: par + the 30-day epoch + pro-rata partial
///         fills are the queue's job (it is `onlyController`-settled by the CRE after the warehouse REDEEM/REPAY).
///         `claude-zipcode.md` §6.1/§6.3/§8.2 (senior redemption + epoch settlement), §4.5.1/§10.1 (engine module
///         pattern), §17 (build-phase Timelock-settable wiring). Sibling of `RecycleModule`/`SzipBuyBurnModule`.
///
/// @dev SIBLING of `RecycleModule` (8-B10): same `is MastercopyInitLock` (Module) + `setUp(bytes)`-under-`initializer` + `onlyOperator`
///      + a private **bubbling `_exec`** (`execTransactionFromModuleReturnData` then revert-on-`false`, bubbling the
///      inner revert data — a plain `exec` would let the Safe SWALLOW a queue revert and silently no-op, leaving a
///      dangling approval). All per-clone wired addresses are plain set-once storage written in `setUp`, NOT
///      `immutable` (the §18.6 clone fact: a `ModuleProxyFactory` clone shares the mastercopy bytecode).
///
/// @dev TRUST/SCOPE: the redeemed USDC sink is the wired `juniorTrancheSafe` ONLY (destination integrity — `requester` is never
///      operator-supplied). The off-ramp NEVER touches the warehouse Safe (the CRE drives REDEEM/REPAY through the
///      `WarehouseAdminModule`); it NEVER sells xALPHA or any other basket leg. `requestRedeem`/`claim` are
///      operator-gated, sized by the operator each period (not autonomic). The rq Safe authorizes this driver at the
///      queue via its `redeemController` (C4) — because the module `exec`s THROUGH the Safe, the queue sees the Safe
///      as `msg.sender`, so `requester == owner == juniorTrancheSafe` satisfies the queue's `owner == msg.sender` check AND the
///      USDC claim accrues to the rq Safe.
contract OffRampModule is MastercopyInitLock {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The rq Safe (`avatar == target == juniorTrancheSafe` = `Baal.avatar()`); the zipUSD source + the USDC sink + the
    ///         queue's authorized `redeemController` (C4) + the per-request `requester`/`owner`.
    address public juniorTrancheSafe;
    /// @notice The single CRE operator (gates `requestRedeem`/`claim`).
    address public operator;
    /// @notice zipUSD (18-dp) — the basket leg redeemed at par for USDC.
    address public zipUSD;
    /// @notice The `ZipRedemptionQueue` (item 9) — the par/epoch/pro-rata redemption engine this module drives.
    address public queue;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    error NotWholeUnit();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event Redeemed(uint256 zipAmount, address requester);
    event Claimed(uint256 assets, address receiver);
    /// @notice A Timelock-settable wiring slot was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). Decodes 5 addresses
    ///         `(owner, juniorTrancheSafe, operator, zipUSD, queue)`. ORDER is load-bearing: validate ALL decoded addresses
    ///         nonzero FIRST + `owner != operator`, set `avatar = target = juniorTrancheSafe`, store the wiring, THEN
    ///         `_transferOwnership(owner)`. No live-read / staticcall in `setUp`.
    function setUp(bytes memory initParams) public override initializer {
        (address owner_, address juniorTrancheSafe_, address operator_, address zipUSD_, address queue_) =
            abi.decode(initParams, (address, address, address, address, address));

        if (
            owner_ == address(0) || juniorTrancheSafe_ == address(0) || operator_ == address(0) || zipUSD_ == address(0)
                || queue_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the rq Safe and only ever mutates it: avatar == target == juniorTrancheSafe.
        avatar = juniorTrancheSafe_;
        target = juniorTrancheSafe_;

        juniorTrancheSafe = juniorTrancheSafe_;
        operator = operator_;
        zipUSD = zipUSD_;
        queue = queue_;

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner` — only the Timelock
    //      (`owner`) can move them, never the CRE `operator`. Not hard-locked (would dirty the vendored setters).

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point `juniorTrancheSafe` (also re-points avatar/target — kept in lock-step). onlyOwner (Timelock).
    function setJuniorTrancheSafe(address juniorTrancheSafe_) external onlyOwner {
        if (juniorTrancheSafe_ == address(0)) revert ZeroAddress();
        juniorTrancheSafe = juniorTrancheSafe_;
        avatar = juniorTrancheSafe_;
        target = juniorTrancheSafe_;
        emit WiringSet("juniorTrancheSafe", juniorTrancheSafe_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `zipUSD` (build phase, §17). onlyOwner (Timelock).
    function setZipUSD(address zipUSD_) external onlyOwner {
        if (zipUSD_ == address(0)) revert ZeroAddress();
        zipUSD = zipUSD_;
        emit WiringSet("zipUSD", zipUSD_);
    }

    /// @notice Re-point `queue` (build phase, §17). onlyOwner (Timelock).
    function setQueue(address queue_) external onlyOwner {
        if (queue_ == address(0)) revert ZeroAddress();
        queue = queue_;
        emit WiringSet("queue", queue_);
    }

    // --------------------------------------------------------------------- the off-ramp (zipUSD -> escrow)
    /// @notice Escrow `zipAmount` of the rq Safe's basket zipUSD into the queue for par redemption. Operator-only.
    ///         Drives the rq Safe (bubbling `_exec`): (a) `zipUSD.approve(queue, zipAmount)`; (b)
    ///         `queue.requestRedeem(zipAmount, juniorTrancheSafe, juniorTrancheSafe)` — so `requester == owner == juniorTrancheSafe`; (c)
    ///         `approve(queue, 0)` reset. `zipAmount` MUST be `> 0` and a whole multiple of the queue's LIVE
    ///         `scaleUp()` (re-derived on `setTokens` — never hard-code `1e12`).
    function requestRedeem(uint256 zipAmount) external onlyOperator {
        if (zipAmount == 0) revert ZeroAmount();
        if (zipAmount % IZipRedemptionQueue(queue).scaleUp() != 0) revert NotWholeUnit();

        address q = queue;
        address rq = juniorTrancheSafe;
        _exec(zipUSD, abi.encodeWithSelector(IERC20.approve.selector, q, zipAmount));
        _exec(q, abi.encodeCall(IZipRedemptionQueue.requestRedeem, (zipAmount, rq, rq)));
        _exec(zipUSD, abi.encodeWithSelector(IERC20.approve.selector, q, uint256(0)));

        emit Redeemed(zipAmount, rq);
    }

    // --------------------------------------------------------------------- the claim (escrow -> USDC into the basket)
    /// @notice Claim `assets` USDC (par) of the rq Safe's realized fill back into the rq Safe (the basket), where the
    ///         buyback spends it — no cross-Safe routing. Operator-only. Drives the rq Safe (bubbling `_exec`) to
    ///         call `queue.withdraw(assets, juniorTrancheSafe, juniorTrancheSafe)` = `(assets, receiver, requester)`.
    function claim(uint256 assets) external onlyOperator {
        if (assets == 0) revert ZeroAmount();
        address rq = juniorTrancheSafe;
        _exec(queue, abi.encodeCall(IZipRedemptionQueue.withdraw, (assets, rq, rq)));
        emit Claimed(assets, rq);
    }

    // --------------------------------------------------------------------- exec (Call-only, value 0, bubble-on-fail)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data (the Gnosis Safe `execTransactionFromModuleReturnData`
    ///      catches inner reverts and returns `(false, revertData)` rather than bubbling, so an unchecked `exec`
    ///      would silently swallow a failed requestRedeem/withdraw and leave a dangling approval).
    function _exec(address to, bytes memory data) private {
        (bool ok, bytes memory ret) = execAndReturnData(to, 0, data, Operation.Call);
        if (!ok) {
            if (ret.length == 0) revert ExecFailed();
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
