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
///         pins); only the REPAY `to` is passed through the payload, guarded by the scope `EqualTo(repaySink)`.
contract WarehouseAdminModule is ReceiverTemplate {
    /// @notice SUPPLY: `eePool.deposit(amount, safe)`. Scope pins `receiver == avatar`.
    uint8 public constant SUPPLY = 1;
    /// @notice APPROVE: `usdc.approve(eePool, amount)`. Scope pins `spender == EqualTo(eePool)`.
    uint8 public constant APPROVE = 2;
    /// @notice REDEEM: `eePool.redeem(shares, safe, safe)`. Scope pins `receiver == owner == avatar`.
    uint8 public constant REDEEM = 3;
    /// @notice REPAY: `usdc.transfer(to, amount)`. Scope pins `to == EqualTo(repaySink)`.
    uint8 public constant REPAY = 4;

    /// @notice Operation.Call as the IRoles `uint8` operation arg (Zodiac core Operation: 0=Call,1=DelegateCall).
    uint8 private constant OP_CALL = 0;

    /// @notice The deployed Zodiac Roles-modifier-v2 instance this adapter forwards through (role member).
    IRoles public immutable roles;
    /// @notice The role key this adapter is `assignRoles`'d to (must be non-zero — zero is the NoMembership sentinel).
    bytes32 public immutable roleKey;
    /// @notice The warehouse Safe — the Roles `avatar`/`target`; the EE-share + USDC custodian.
    address public immutable safe;
    /// @notice The `EulerEarn` pool the warehouse supplies into / redeems from.
    address public immutable eePool;
    /// @notice USDC (the EE asset; the APPROVE/REPAY token).
    address public immutable usdc;
    /// @notice The single configured REPAY sink (M1 = the `ZipRedemptionQueue`); pinned in the scope (tree D).
    address public immutable repaySink;

    /// @notice A zero address constructor arg.
    error ZeroAddress();
    /// @notice A zero `roleKey` (would make every forward revert `NoMembership` in the modifier).
    error ZeroRoleKey();
    /// @notice The decoded `opType` is not one of SUPPLY/APPROVE/REDEEM/REPAY.
    error UnsupportedOpType(uint8 opType);
    /// @notice The inner `execTransactionWithRole` returned false (unreachable defense-in-depth: with
    ///         `shouldRevert=true` the modifier already reverts `ModuleTransactionFailed` on a failed exec).
    error RoleExecFailed();

    /// @notice A warehouse op was forwarded to the Roles modifier.
    event WarehouseOp(uint8 indexed opType, address to, bytes data);

    /// @param forwarder The Chainlink Forwarder (reverts on zero in `ReceiverTemplate`).
    /// @param roles_ The deployed Roles-modifier-v2 instance.
    /// @param roleKey_ The role key this adapter is assigned to (must be non-zero).
    /// @param safe_ The warehouse Safe (the Roles avatar; the EE-share/USDC custodian).
    /// @param eePool_ The `EulerEarn` pool.
    /// @param usdc_ USDC.
    /// @param repaySink_ The configured REPAY sink.
    constructor(
        address forwarder,
        address roles_,
        bytes32 roleKey_,
        address safe_,
        address eePool_,
        address usdc_,
        address repaySink_
    ) ReceiverTemplate(forwarder) {
        if (
            roles_ == address(0) || safe_ == address(0) || eePool_ == address(0) || usdc_ == address(0)
                || repaySink_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (roleKey_ == bytes32(0)) revert ZeroRoleKey();
        roles = IRoles(roles_);
        roleKey = roleKey_;
        safe = safe_;
        eePool = eePool_;
        usdc = usdc_;
        repaySink = repaySink_;
    }

    /// @notice The §4.4/§8.5 envelope handler. Gated upstream by the immutable-Forwarder check in
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
            data = abi.encodeWithSelector(IEulerEarn.deposit.selector, amount, safe);
        } else if (opType == APPROVE) {
            uint256 amount = abi.decode(payload, (uint256));
            to = usdc;
            data = abi.encodeWithSelector(IERC20.approve.selector, eePool, amount);
        } else if (opType == REDEEM) {
            uint256 shares = abi.decode(payload, (uint256));
            to = eePool;
            data = abi.encodeWithSelector(IEulerEarn.redeem.selector, shares, safe, safe);
        } else if (opType == REPAY) {
            (address dest, uint256 amount) = abi.decode(payload, (address, uint256));
            to = usdc;
            data = abi.encodeWithSelector(IERC20.transfer.selector, dest, amount);
        } else {
            revert UnsupportedOpType(opType);
        }

        emit WarehouseOp(opType, to, data);

        bool ok = roles.execTransactionWithRole(to, 0, data, OP_CALL, roleKey, true);
        if (!ok) revert RoleExecFailed();
    }
}
