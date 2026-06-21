// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IRoles} from "../../interfaces/zodiac/IRoles.sol";
import {IEulerEarn} from "../../interfaces/euler/IEulerEarn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WarehouseAdminModule (8-Bw)
/// @notice The thin CRE adapter for the SENIOR-side `CreditWarehouse` (§4.5/§8.5). It is the SOLE Roles
///         role-member of a deployed Zodiac Roles-modifier-v2 instance that is `enableModule`'d on the
///         warehouse Safe (which custodies the `EulerEarn` shares backing all outstanding zipUSD float).
///         This contract holds NO custody and enforces NO scope — it is a pure encoder: it decodes the
///         §4.4/§8.5 CRE report envelope into exactly one of four warehouse ops (SUPPLY/APPROVE/REDEEM/
///         REPAY) and forwards it through `Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`.
///         The SECURITY BOUNDARY is the Roles scope (params pinned, Call-only), NOT this bytecode.
///
///         It is NOT a Zodiac `Module` and is NEVER `enableModule`'d on the Safe; it is `assignRoles`'d as
///         the Roles role member. Every effect routes through the modifier. `value` is always 0, `operation`
///         is always Call (literal 0), `shouldRevert` is always true — none are ever decoded from a payload.
///         The receiver/spender/redeem-owner are INJECTED from immutables (belt-and-suspenders with the scope
///         pins); only the REPAY `to` is passed through the payload, guarded by the scope `EqualTo(redemptionBox)`.
///
///         CUSTODY NOTE (why REPAY's sink can be the standing Safe USDC balance): the warehouse Safe is a
///         SHARE-accumulator — supplier deposits go straight into `EulerEarn` as shares (`ZipDepositModule` /
///         `RecycleModule` call `eePool.deposit(amount, warehouseSafe)`), the EE perf-fee accrues as shares
///         (Safe == `eePool.feeRecipient`), and loss-recovery + the 0.5% draw fee route to the `adminSafe`, NOT
///         here. So the ONLY USDC that ever lands naked in the Safe is REDEEM proceeds (`eePool.redeem(shares,
///         warehouseSafe, warehouseSafe)`); SUPPLY only consumes Safe USDC back into EE. See
///         `docs/wires/8-Bw-CreditWarehouse.md` "Custody character".
contract WarehouseAdminModule is ReceiverTemplate {
    /// @notice SUPPLY: `eePool.deposit(amount, warehouseSafe)`. Scope pins `receiver == avatar`.
    uint8 public constant SUPPLY = 1;
    /// @notice APPROVE: `usdc.approve(eePool, amount)`. Scope pins `spender == EqualTo(eePool)`.
    uint8 public constant APPROVE = 2;
    /// @notice REDEEM: `eePool.redeem(shares, warehouseSafe, warehouseSafe)`. Scope pins `receiver == owner == avatar`.
    uint8 public constant REDEEM = 3;
    /// @notice REPAY: `usdc.transfer(to, amount)`. Scope pins `to == EqualTo(redemptionBox)`.
    uint8 public constant REPAY = 4;

    /// @notice Operation.Call as the IRoles `uint8` operation arg (Zodiac core Operation: 0=Call,1=DelegateCall).
    uint8 private constant OP_CALL = 0;

    // NOTE (2026-06-09, §17): wiring below is Timelock-settable, NOT immutable — build-phase flexibility (redeploy a
    // Roles instance / warehouseSafe / pool / repay sink and re-point with one call). Re-freeze to immutable is DEFERRED to pre-prod.
    /// @notice The deployed Zodiac Roles-modifier-v2 instance this adapter forwards through (role member).
    IRoles public roles;
    /// @notice The role key this adapter is `assignRoles`'d to (must be non-zero — zero is the NoMembership sentinel).
    bytes32 public roleKey;
    /// @notice The warehouse Safe — the Roles `avatar`/`target`; the EE-share + USDC custodian.
    /// @dev PARITY — load-bearing: this injected `warehouseSafe` and the Roles modifier's own `avatar` slot are
    ///      INDEPENDENT storage (`warehouseSafe` is set here via `setWarehouseSafe`; `avatar` is set on the Roles
    ///      instance via its own `setAvatar`). SUPPLY/REDEEM inject this `warehouseSafe` as the deposit/redeem owner
    ///      while the Roles scope checks `receiver == avatar`, so they MUST be the same address. `setWarehouseSafe`
    ///      now ENFORCES this on-chain (reverts `AvatarMismatch` unless `roles.avatar() == warehouseSafe_`), so a
    ///      one-sided re-point can no longer be saved — the paired re-point is `Roles.setAvatar` FIRST, then
    ///      `setWarehouseSafe`. Were the slots ever mismatched anyway, SUPPLY/REDEEM still FAIL CLOSED (the scope
    ///      rejects the mismatched receiver, nothing leaks). See `docs/roles.md` and the runbook.
    address public warehouseSafe;
    /// @notice The `EulerEarn` pool the warehouse supplies into / redeems from.
    address public eePool;
    /// @notice USDC (the EE asset; the APPROVE/REPAY token).
    address public usdc;
    /// @notice The single configured REPAY sink (M1 = the `ZipRedemptionQueue`); pinned in the scope (tree D).
    address public redemptionBox;

    /// @notice A zero address constructor arg.
    error ZeroAddress();
    /// @notice A zero `roleKey` (would make every forward revert `NoMembership` in the modifier).
    error ZeroRoleKey();
    /// @notice The decoded `opType` is not one of SUPPLY/APPROVE/REDEEM/REPAY.
    error UnsupportedOpType(uint8 opType);
    /// @notice A REPAY payload carried a `dest` other than the wired `redemptionBox` (self-enforced, not just scoped).
    error WrongRedemptionBox(address dest);
    /// @notice `setWarehouseSafe` was called with a `warehouseSafe_` that does not equal the Roles modifier's current
    ///         `avatar()`. The two slots are independent (see the `warehouseSafe` docstring), and SUPPLY/REDEEM inject
    ///         this address as the receiver/owner while the scope pins `receiver == avatar` — so a one-sided re-point
    ///         would silently brick senior par-redemption (fail-closed liveness). This guard converts that into a hard
    ///         revert at set-time: the operator MUST run `Roles.setAvatar(new)` FIRST, then this. See `docs/roles.md`.
    error AvatarMismatch(address warehouseSafe, address avatar);
    /// @notice The inner `execTransactionWithRole` returned false (unreachable defense-in-depth: with
    ///         `shouldRevert=true` the modifier already reverts `ModuleTransactionFailed` on a failed exec).
    error RoleExecFailed();

    /// @notice A warehouse op was forwarded to the Roles modifier.
    event WarehouseOp(uint8 indexed opType, address to, bytes data);
    /// @notice A Timelock re-point of a wiring slot (build phase).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice A Timelock re-set of the role key.
    event RoleKeySet(bytes32 roleKey);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`).
    /// @param roles_ The deployed Roles-modifier-v2 instance.
    /// @param roleKey_ The role key this adapter is assigned to (must be non-zero).
    /// @param warehouseSafe_ The warehouse Safe (the Roles avatar; the EE-share/USDC custodian).
    /// @param eePool_ The `EulerEarn` pool.
    /// @param usdc_ USDC.
    /// @param redemptionBox_ The configured REPAY sink.
    constructor(
        address forwarder,
        address roles_,
        bytes32 roleKey_,
        address warehouseSafe_,
        address eePool_,
        address usdc_,
        address redemptionBox_
    ) ReceiverTemplate(forwarder) {
        if (
            roles_ == address(0) || warehouseSafe_ == address(0) || eePool_ == address(0) || usdc_ == address(0)
                || redemptionBox_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (roleKey_ == bytes32(0)) revert ZeroRoleKey();
        roles = IRoles(roles_);
        roleKey = roleKey_;
        warehouseSafe = warehouseSafe_;
        eePool = eePool_;
        usdc = usdc_;
        redemptionBox = redemptionBox_;
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point the Roles-modifier instance. `onlyOwner` (Timelock).
    function setRoles(address roles_) external onlyOwner {
        if (roles_ == address(0)) revert ZeroAddress();
        roles = IRoles(roles_);
        emit WiringSet("roles", roles_);
    }

    /// @notice Re-set the assigned role key (must stay non-zero). `onlyOwner` (Timelock).
    function setRoleKey(bytes32 roleKey_) external onlyOwner {
        if (roleKey_ == bytes32(0)) revert ZeroRoleKey();
        roleKey = roleKey_;
        emit RoleKeySet(roleKey_);
    }

    /// @notice Re-point the warehouse Safe (Roles avatar/custodian). `onlyOwner` (Timelock).
    /// @dev AVATAR PARITY (enforced on-chain): the re-point is REJECTED unless the Roles modifier's `avatar()`
    ///      already equals `warehouseSafe_`. SUPPLY/REDEEM inject this address as the deposit/redeem receiver+owner
    ///      while the scope pins `receiver == avatar`, so the two slots MUST agree; a one-sided re-point would
    ///      otherwise silently brick senior par-redemption (fail-closed liveness). This makes the paired re-point
    ///      ORDER-DEPENDENT: run `Roles.setAvatar(warehouseSafe_)` on the modifier FIRST, then this. The modifier's
    ///      own scope rejection of a mismatched receiver remains the backstop, now unreachable-by-construction here.
    ///      See `docs/roles.md` and the `warehouseSafe` storage docstring above.
    function setWarehouseSafe(address warehouseSafe_) external onlyOwner {
        if (warehouseSafe_ == address(0)) revert ZeroAddress();
        address av = roles.avatar();
        if (av != warehouseSafe_) revert AvatarMismatch(warehouseSafe_, av);
        warehouseSafe = warehouseSafe_;
        emit WiringSet("warehouseSafe", warehouseSafe_);
    }

    /// @notice Re-point the EulerEarn pool. `onlyOwner` (Timelock).
    function setEePool(address eePool_) external onlyOwner {
        if (eePool_ == address(0)) revert ZeroAddress();
        eePool = eePool_;
        emit WiringSet("eePool", eePool_);
    }

    /// @notice Re-point USDC. `onlyOwner` (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point the REPAY sink. `onlyOwner` (Timelock).
    function setRedemptionBox(address redemptionBox_) external onlyOwner {
        if (redemptionBox_ == address(0)) revert ZeroAddress();
        redemptionBox = redemptionBox_;
        emit WiringSet("redemptionBox", redemptionBox_);
    }

    /// @notice The §4.4/§8.5 envelope handler. Gated upstream by the Forwarder check in
    ///         `ReceiverTemplate.onReport`. Decodes `(uint8 opType, bytes payload)`, builds exactly one scoped
    ///         call, and forwards it through the Roles modifier. Reverts `UnsupportedOpType` on any other byte.
    /// @param report The shared envelope `abi.encode(uint8 opType, bytes payload)`.
    function _processReport(bytes calldata report) internal override {
        (uint8 opType, bytes memory payload) = abi.decode(report, (uint8, bytes));

        address to;
        bytes memory data;

        if (opType == SUPPLY) {
            uint256 amount = abi.decode(payload, (uint256));
            to = eePool;
            data = abi.encodeWithSelector(IEulerEarn.deposit.selector, amount, warehouseSafe);
        } else if (opType == APPROVE) {
            uint256 amount = abi.decode(payload, (uint256));
            to = usdc;
            data = abi.encodeWithSelector(IERC20.approve.selector, eePool, amount);
        } else if (opType == REDEEM) {
            uint256 shares = abi.decode(payload, (uint256));
            to = eePool;
            data = abi.encodeWithSelector(IEulerEarn.redeem.selector, shares, warehouseSafe, warehouseSafe);
        } else if (opType == REPAY) {
            (address dest, uint256 amount) = abi.decode(payload, (address, uint256));
            // Self-enforce the sink (belt-and-suspenders with the Roles `EqualTo(redemptionBox)` scope, and parity with
            // SUPPLY/REDEEM injecting `warehouseSafe` from immutables): inject `redemptionBox`, and revert loudly on a CRE drift
            // rather than relying solely on the scope to reject a mismatched `dest`.
            if (dest != redemptionBox) revert WrongRedemptionBox(dest);
            to = usdc;
            data = abi.encodeWithSelector(IERC20.transfer.selector, redemptionBox, amount);
        } else {
            revert UnsupportedOpType(opType);
        }

        emit WarehouseOp(opType, to, data);

        bool ok = roles.execTransactionWithRole(to, 0, data, OP_CALL, roleKey, true);
        if (!ok) revert RoleExecFailed();
    }
}
