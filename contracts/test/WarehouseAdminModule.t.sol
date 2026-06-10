// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {CreditWarehouseDeployer} from "../script/CreditWarehouseDeployer.sol";
import {WarehouseAdminModule} from "../src/supply/CreditWarehouse/WarehouseAdminModule.sol";
import {MockEulerEarn} from "./mocks/MockEulerEarn.sol";
import {IRoles} from "../src/interfaces/zodiac/IRoles.sol";
import {IEulerEarn} from "../src/interfaces/euler/IEulerEarn.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {ReceiverTemplate} from "x402-cre-price-alerts/interfaces/ReceiverTemplate.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A tiny second role member, used to prove the SCOPE (not the adapter hardcoding) is the guard —
///         it calls `Roles.execTransactionWithRole` directly with redirected params and must be rejected.
contract MockMember {
    IRoles public immutable roles;

    constructor(address roles_) {
        roles = IRoles(roles_);
    }

    function exec(address to, uint256 value, bytes calldata data, uint8 op, bytes32 roleKey)
        external
        returns (bool)
    {
        return roles.execTransactionWithRole(to, value, data, op, roleKey, true);
    }
}

/// @notice A re-entry attacker: from a callback it tries to re-enter `onReport` as a NON-Forwarder; the
///         immutable-Forwarder gate must reject it (mirrors ZipcodeController.t.sol's MaliciousVenue/F-10).
contract ReentrantAttacker {
    WarehouseAdminModule public adapter;
    bool public reentered;

    function setAdapter(address a) external {
        adapter = WarehouseAdminModule(a);
    }

    function attack() external {
        try adapter.onReport("", abi.encode(uint8(1), abi.encode(uint256(1)))) {
            reentered = true;
        } catch {
            reentered = false;
        }
    }
}

contract WarehouseAdminModuleTest is ForkConfig {
    // -- Roles ConditionViolation Status ordinals (PermissionChecker.sol:728) --
    uint8 internal constant ST_DELEGATECALL_NOT_ALLOWED = 1;
    uint8 internal constant ST_TARGET_NOT_ALLOWED = 2;
    uint8 internal constant ST_FUNCTION_NOT_ALLOWED = 3;
    uint8 internal constant ST_SEND_NOT_ALLOWED = 4;
    uint8 internal constant ST_PARAMETER_NOT_ALLOWED = 7;

    // -- opType bytes --
    uint8 internal constant SUPPLY = 1;
    uint8 internal constant APPROVE = 2;
    uint8 internal constant REDEEM = 3;
    uint8 internal constant REPAY = 4;
    uint8 internal constant OP_CALL = 0;
    uint8 internal constant OP_DELEGATECALL = 1;

    bytes4 internal constant CONDITION_VIOLATION_SEL = bytes4(keccak256("ConditionViolation(uint8,bytes32)"));
    /// @dev The DEPLOYED Roles mastercopy gates `execTransactionWithRole` with the zodiac-core `moduleOnly`
    ///      modifier (Modifier.sol:82-95): `assignRoles` ALSO registers the member as an enabled module, and a
    ///      caller absent from `modules[]` reverts `NotAuthorized(sender)` BEFORE the `NoMembership` check ever
    ///      runs. This is newer than the vendored reference (where `_authorize` had no moduleOnly gate). A truly
    ///      unassigned caller therefore reverts `NotAuthorized`, not `NoMembership` — verified on the live fork.
    bytes4 internal constant NOT_AUTHORIZED_SEL = bytes4(keccak256("NotAuthorized(address)"));
    bytes4 internal constant MODULE_TX_FAILED_SEL = bytes4(keccak256("ModuleTransactionFailed()"));
    bytes4 internal constant OWNABLE_UNAUTH_SEL = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    CreditWarehouseDeployer internal deployer;
    CreditWarehouseDeployer.Warehouse internal w;

    MockEulerEarn internal ee;
    address internal usdc;
    address internal forwarder = makeAddr("forwarder");
    address internal repaySink = makeAddr("repaySink");
    address internal godOwner; // = this test contract (drives the 1/1 Safe owner sig)
    address internal attacker = makeAddr("attacker");

    WarehouseAdminModule internal adapter;
    address internal safe;
    address internal roles;
    bytes32 internal rk;

    uint256 internal constant SUPPLY_AMT = 1_000_000e6; // $1M

    event WarehouseOp(uint8 indexed opType, address to, bytes data);

    function setUp() public {
        _selectBaseFork();

        usdc = BaseAddresses.USDC;
        godOwner = address(this);

        ee = new MockEulerEarn(usdc);

        deployer = new CreditWarehouseDeployer();
        w = deployer.deploy(godOwner, godOwner, address(ee), usdc, forwarder, repaySink, 1);

        adapter = WarehouseAdminModule(w.adapter);
        safe = w.safe;
        roles = w.roles;
        rk = w.roleKey;
    }

    // ---------- helpers ----------

    function _onReport(uint8 opType, bytes memory payload) internal {
        vm.prank(forwarder);
        adapter.onReport("", abi.encode(opType, payload));
    }

    /// @dev Raw-call the Roles modifier (as a role member) and assert it reverts ConditionViolation with the
    ///      EXACT expected Status ordinal (the `info` word is left free). Pins the status, not just the selector.
    function _assertConditionViolation(MockMember m, address to, uint256 value, bytes memory data, uint8 op, uint8 expectedStatus)
        internal
    {
        (bool ok, bytes memory ret) =
            address(m).call(abi.encodeWithSelector(MockMember.exec.selector, to, value, data, op, rk));
        assertFalse(ok, "expected revert");
        assertGe(ret.length, 4, "revert payload too short");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        assertEq(sel, CONDITION_VIOLATION_SEL, "not ConditionViolation");
        // decode (uint8 status, bytes32 info) from the 4-byte-offset body.
        uint8 status;
        assembly {
            status := mload(add(ret, 0x24))
        }
        assertEq(status, expectedStatus, "wrong Status ordinal");
    }

    function _assertRawRevertSelector(MockMember m, address to, uint256 value, bytes memory data, uint8 op, bytes4 expSel)
        internal
    {
        (bool ok, bytes memory ret) =
            address(m).call(abi.encodeWithSelector(MockMember.exec.selector, to, value, data, op, rk));
        assertFalse(ok, "expected revert");
        assertGe(ret.length, 4, "revert payload too short");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        assertEq(sel, expSel, "wrong revert selector");
    }

    function _newMember() internal returns (MockMember m) {
        m = new MockMember(roles);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = rk;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;
        IRoles(roles).assignRoles(address(m), keys, memberOf); // as Roles owner (this test = godOwner)
    }

    function _fundSafe(uint256 amount) internal {
        deal(usdc, safe, amount);
    }

    // ============================================================
    // (1) Deploy/wire
    // ============================================================

    function test_DeployWire_State() public view {
        // Safe owner/threshold.
        address[] memory owners = ISafe(safe).getOwners();
        assertEq(owners.length, 1, "one owner");
        assertEq(owners[0], godOwner, "owner == godOwner");
        assertEq(ISafe(safe).getThreshold(), 1, "threshold 1");

        // Roles module enabled.
        assertTrue(ISafe(safe).isModuleEnabled(roles), "roles enabled on safe");

        // Adapter immutables.
        assertEq(address(adapter.roles()), roles, "adapter.roles");
        assertEq(adapter.safe(), safe, "adapter.safe");
        assertEq(adapter.eePool(), address(ee), "adapter.eePool");
        assertEq(adapter.usdc(), usdc, "adapter.usdc");
        assertEq(adapter.repaySink(), repaySink, "adapter.repaySink");
        assertEq(adapter.roleKey(), rk, "adapter.roleKey");
        assertTrue(rk != bytes32(0), "roleKey != 0");
        assertEq(adapter.getForwarderAddress(), forwarder, "forwarder");
        assertEq(adapter.getExpectedWorkflowId(), bytes32(0), "workflow gate dormant");
    }

    // ============================================================
    // (2) Constructor reverts
    // ============================================================

    function test_Ctor_RevertsOnZeroAddress() public {
        vm.expectRevert(); // ReceiverTemplate.InvalidForwarderAddress
        new WarehouseAdminModule(address(0), roles, rk, safe, address(ee), usdc, repaySink);

        vm.expectRevert(WarehouseAdminModule.ZeroAddress.selector);
        new WarehouseAdminModule(forwarder, address(0), rk, safe, address(ee), usdc, repaySink);

        vm.expectRevert(WarehouseAdminModule.ZeroAddress.selector);
        new WarehouseAdminModule(forwarder, roles, rk, address(0), address(ee), usdc, repaySink);

        vm.expectRevert(WarehouseAdminModule.ZeroAddress.selector);
        new WarehouseAdminModule(forwarder, roles, rk, safe, address(0), usdc, repaySink);

        vm.expectRevert(WarehouseAdminModule.ZeroAddress.selector);
        new WarehouseAdminModule(forwarder, roles, rk, safe, address(ee), address(0), repaySink);

        vm.expectRevert(WarehouseAdminModule.ZeroAddress.selector);
        new WarehouseAdminModule(forwarder, roles, rk, safe, address(ee), usdc, address(0));
    }

    function test_Ctor_RevertsOnZeroRoleKey() public {
        vm.expectRevert(WarehouseAdminModule.ZeroRoleKey.selector);
        new WarehouseAdminModule(forwarder, roles, bytes32(0), safe, address(ee), usdc, repaySink);
    }

    // ============================================================
    // (3) SUPPLY (happy) — APPROVE then SUPPLY
    // ============================================================

    function test_Supply_Happy() public {
        _fundSafe(SUPPLY_AMT);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit WarehouseOp(APPROVE, usdc, abi.encodeWithSelector(IERC20.approve.selector, address(ee), SUPPLY_AMT));
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));

        vm.expectEmit(true, false, false, true, address(adapter));
        emit WarehouseOp(SUPPLY, address(ee), abi.encodeWithSelector(IEulerEarn.deposit.selector, SUPPLY_AMT, safe));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));

        assertEq(ee.balanceOf(safe), SUPPLY_AMT, "shares to the Safe");
        assertEq(IERC20(usdc).balanceOf(safe), 0, "Safe USDC drawn down");
        assertEq(ee.balanceOf(address(adapter)), 0, "adapter holds no shares");
        assertEq(ee.balanceOf(roles), 0, "roles holds no shares");
        assertEq(IERC20(usdc).balanceOf(address(adapter)), 0, "adapter holds no USDC");
    }

    // ============================================================
    // (4) REDEEM (happy)
    // ============================================================

    function test_Redeem_Happy() public {
        _fundSafe(SUPPLY_AMT);
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));

        uint256 slice = 300_000e6;
        vm.expectEmit(true, false, false, true, address(adapter));
        emit WarehouseOp(REDEEM, address(ee), abi.encodeWithSelector(IEulerEarn.redeem.selector, slice, safe, safe));
        _onReport(REDEEM, abi.encode(slice));

        assertEq(ee.balanceOf(safe), SUPPLY_AMT - slice, "shares burned");
        assertEq(IERC20(usdc).balanceOf(safe), slice, "USDC returned to the Safe (receiver==owner==avatar)");
    }

    // ============================================================
    // (5) REPAY (happy)
    // ============================================================

    function test_Repay_Happy() public {
        _fundSafe(SUPPLY_AMT);
        uint256 amount = 250_000e6;

        vm.expectEmit(true, false, false, true, address(adapter));
        emit WarehouseOp(REPAY, usdc, abi.encodeWithSelector(IERC20.transfer.selector, repaySink, amount));
        _onReport(REPAY, abi.encode(repaySink, amount));

        assertEq(IERC20(usdc).balanceOf(repaySink), amount, "repaySink received USDC");
        assertEq(IERC20(usdc).balanceOf(safe), SUPPLY_AMT - amount, "Safe drawn down");
    }

    // ============================================================
    // (6) Scope pin load-bearing (a real role MEMBER cannot redirect params)
    // ============================================================

    function test_Scope_PinsParams_DepositReceiver() public {
        _fundSafe(SUPPLY_AMT);
        MockMember m = _newMember();
        // member tries deposit to ATTACKER instead of the avatar -> ParameterNotAllowed.
        _assertConditionViolation(
            m,
            address(ee),
            0,
            abi.encodeWithSelector(IEulerEarn.deposit.selector, SUPPLY_AMT, attacker),
            OP_CALL,
            ST_PARAMETER_NOT_ALLOWED
        );
    }

    function test_Scope_PinsParams_TransferTo() public {
        _fundSafe(SUPPLY_AMT);
        MockMember m = _newMember();
        uint256 amt = 100e6;

        // to == ATTACKER -> ParameterNotAllowed.
        _assertConditionViolation(
            m, usdc, 0, abi.encodeWithSelector(IERC20.transfer.selector, attacker, amt), OP_CALL, ST_PARAMETER_NOT_ALLOWED
        );
        // to == address(0) -> ParameterNotAllowed.
        _assertConditionViolation(
            m, usdc, 0, abi.encodeWithSelector(IERC20.transfer.selector, address(0), amt), OP_CALL, ST_PARAMETER_NOT_ALLOWED
        );
        // to == eePool -> ParameterNotAllowed.
        _assertConditionViolation(
            m, usdc, 0, abi.encodeWithSelector(IERC20.transfer.selector, address(ee), amt), OP_CALL, ST_PARAMETER_NOT_ALLOWED
        );

        // to == repaySink -> SUCCEEDS (proves the pin is exactly repaySink, not adapter hardcoding).
        bool ok = m.exec(usdc, 0, abi.encodeWithSelector(IERC20.transfer.selector, repaySink, amt), OP_CALL, rk);
        assertTrue(ok, "member transfer to repaySink succeeds");
        assertEq(IERC20(usdc).balanceOf(repaySink), amt, "repaySink received the member transfer");
    }

    // ============================================================
    // (7) Call-only
    // ============================================================

    function test_CallOnly_RejectsValueAndDelegatecall() public {
        _fundSafe(SUPPLY_AMT);
        MockMember m = _newMember();

        // value > 0 -> SendNotAllowed.
        _assertConditionViolation(
            m, address(ee), 1, abi.encodeWithSelector(IEulerEarn.deposit.selector, SUPPLY_AMT, safe), OP_CALL, ST_SEND_NOT_ALLOWED
        );
        // operation == DelegateCall -> DelegateCallNotAllowed.
        _assertConditionViolation(
            m,
            address(ee),
            0,
            abi.encodeWithSelector(IEulerEarn.deposit.selector, SUPPLY_AMT, safe),
            OP_DELEGATECALL,
            ST_DELEGATECALL_NOT_ALLOWED
        );
    }

    // ============================================================
    // (8) Non-member — the DEPLOYED Roles moduleOnly gate rejects an unassigned caller
    // ============================================================

    function test_NonMember_Reverts() public {
        // A fresh, unassigned contract: it is neither a role member NOR an enabled module on the Roles modifier
        // (on the deployed mastercopy, `assignRoles` registers a member as a module; a caller absent from
        // `modules[]` reverts `NotAuthorized` via the `moduleOnly` gate BEFORE the `NoMembership` check). See
        // the NOT_AUTHORIZED_SEL doc note for the on-chain-verified discrepancy from the ticket's NoMembership.
        MockMember stranger = new MockMember(roles);
        _assertRawRevertSelector(
            stranger, address(ee), 0, abi.encodeWithSelector(IEulerEarn.deposit.selector, uint256(1), safe), OP_CALL, NOT_AUTHORIZED_SEL
        );
    }

    // ============================================================
    // (9) Non-owner cannot scope/assign — the DEPLOYED Roles is zodiac Ownable (custom error, NOT the OZ-4 string)
    // ============================================================

    function test_NonOwner_CannotScopeOrAssign() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = rk;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH_SEL, attacker));
        IRoles(roles).assignRoles(attacker, keys, memberOf);

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH_SEL, attacker));
        IRoles(roles).scopeTarget(rk, attacker);
        vm.stopPrank();
    }

    // ============================================================
    // (10) Escalation blocked — un-scoped target/selector
    // ============================================================

    function test_Escalation_Blocked() public {
        MockMember m = _newMember();

        // to == safe (never scopeTarget'd): try Safe.enableModule(attacker) -> TargetAddressNotAllowed.
        _assertConditionViolation(
            m, safe, 0, abi.encodeWithSelector(ISafe.enableModule.selector, attacker), OP_CALL, ST_TARGET_NOT_ALLOWED
        );
        // to == safe: addOwnerWithThreshold(attacker, 1) -> TargetAddressNotAllowed.
        _assertConditionViolation(
            m, safe, 0, abi.encodeWithSelector(ISafe.addOwnerWithThreshold.selector, attacker, uint256(1)), OP_CALL, ST_TARGET_NOT_ALLOWED
        );
        // un-scoped target (a random address) -> TargetAddressNotAllowed.
        _assertConditionViolation(
            m, attacker, 0, abi.encodeWithSelector(IERC20.transfer.selector, repaySink, uint256(1)), OP_CALL, ST_TARGET_NOT_ALLOWED
        );
        // un-scoped selector on a SCOPED target (eePool.withdraw via random selector) -> FunctionNotAllowed.
        _assertConditionViolation(
            m, address(ee), 0, abi.encodeWithSelector(bytes4(keccak256("withdraw(uint256,address,address)")), uint256(1), safe, safe), OP_CALL, ST_FUNCTION_NOT_ALLOWED
        );
    }

    // ============================================================
    // (11) Adapter authority
    // ============================================================

    function test_Adapter_NonForwarder_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, attacker, forwarder));
        adapter.onReport("", abi.encode(SUPPLY, abi.encode(uint256(1))));
    }

    function test_Adapter_UnsupportedOpType_Reverts() public {
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WarehouseAdminModule.UnsupportedOpType.selector, uint8(0)));
        adapter.onReport("", abi.encode(uint8(0), abi.encode(uint256(1))));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WarehouseAdminModule.UnsupportedOpType.selector, uint8(5)));
        adapter.onReport("", abi.encode(uint8(5), abi.encode(uint256(1))));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WarehouseAdminModule.UnsupportedOpType.selector, uint8(255)));
        adapter.onReport("", abi.encode(uint8(255), abi.encode(uint256(1))));
    }

    function test_Adapter_Reentrancy_RejectedByForwarderGate() public {
        ReentrantAttacker ra = new ReentrantAttacker();
        ra.setAdapter(address(adapter));
        // The re-entry into onReport comes from `ra` (NOT the Forwarder) -> InvalidSender; try/catch records false.
        ra.attack();
        assertFalse(ra.reentered(), "reentrant onReport rejected by Forwarder gate");
    }

    // ============================================================
    // (12) Inner-exec failure -> ModuleTransactionFailed (scope passes, exec fails)
    // ============================================================

    function test_InnerExecFail_ZeroSupply() public {
        // deposit(0) -> mock ZeroShares -> ModuleTransactionFailed. (scope passes: receiver==avatar, amount Pass)
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(SUPPLY, abi.encode(uint256(0))));
    }

    function test_InnerExecFail_SupplyWithoutApprove() public {
        _fundSafe(SUPPLY_AMT);
        // No prior APPROVE -> the mock's transferFrom allowance pull fails -> ModuleTransactionFailed.
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(SUPPLY, abi.encode(SUPPLY_AMT)));
    }

    function test_InnerExecFail_RedeemMoreThanHeld() public {
        _fundSafe(SUPPLY_AMT);
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));
        // redeem MORE than held -> underflow in the mock -> ModuleTransactionFailed.
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(REDEEM, abi.encode(SUPPLY_AMT + 1)));
    }

    function test_InnerExecFail_RepayMoreThanHeld() public {
        _fundSafe(SUPPLY_AMT);
        // REPAY more USDC than the Safe holds -> transfer fails -> ModuleTransactionFailed.
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(REPAY, abi.encode(repaySink, SUPPLY_AMT + 1)));
    }

    function test_Redeem_ZeroIsNoOpSuccess() public {
        _fundSafe(SUPPLY_AMT);
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));
        uint256 sharesBefore = ee.balanceOf(safe);
        uint256 usdcBefore = IERC20(usdc).balanceOf(safe);

        // redeem(0): no-op success (mirrors EulerEarn.sol:604) — asymmetric to deposit(0).
        _onReport(REDEEM, abi.encode(uint256(0)));

        assertEq(ee.balanceOf(safe), sharesBefore, "shares unchanged by redeem(0)");
        assertEq(IERC20(usdc).balanceOf(safe), usdcBefore, "USDC unchanged by redeem(0)");
    }

    // ============================================================
    // (13) Malformed payload
    // ============================================================

    function test_MalformedPayload_RevertsCleanly() public {
        // A garbage report (not a valid abi-encoded (uint8,bytes)) reverts at abi.decode.
        vm.prank(forwarder);
        vm.expectRevert();
        adapter.onReport("", hex"deadbeef");

        // A SUPPLY op whose inner payload is too short to decode a uint256 -> reverts at the inner abi.decode.
        vm.prank(forwarder);
        vm.expectRevert();
        adapter.onReport("", abi.encode(SUPPLY, bytes("")));
    }

    // ============================================================
    // (14) Atomicity — balances unchanged after a revert
    // ============================================================

    function test_Atomicity_BalancesUnchangedAfterRevert() public {
        _fundSafe(SUPPLY_AMT);
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));

        uint256 sharesBefore = ee.balanceOf(safe);
        uint256 usdcBefore = IERC20(usdc).balanceOf(safe);

        // A failing REDEEM (over-held) reverts; balances must be untouched.
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(REDEEM, abi.encode(SUPPLY_AMT + 1)));

        // A failing REPAY (over-held) reverts; balances untouched.
        vm.prank(forwarder);
        vm.expectRevert(MODULE_TX_FAILED_SEL);
        adapter.onReport("", abi.encode(REPAY, abi.encode(repaySink, SUPPLY_AMT + 1)));

        // A malformed payload reverts; balances untouched.
        vm.prank(forwarder);
        vm.expectRevert();
        adapter.onReport("", hex"deadbeef");

        assertEq(ee.balanceOf(safe), sharesBefore, "shares unchanged after reverts");
        assertEq(IERC20(usdc).balanceOf(safe), usdcBefore, "USDC unchanged after reverts");
    }

    // ============================================================
    // (15) Senior NAV mark
    // ============================================================

    function test_SeniorNavMark() public {
        _fundSafe(SUPPLY_AMT);
        _onReport(APPROVE, abi.encode(SUPPLY_AMT));
        _onReport(SUPPLY, abi.encode(SUPPLY_AMT));

        uint256 redeemed = 400_000e6;
        _onReport(REDEEM, abi.encode(redeemed));

        uint256 net = SUPPLY_AMT - redeemed;
        assertApproxEqAbs(ee.convertToAssets(ee.balanceOf(safe)), net, 1, "senior NAV mark == supplied net of redeemed");
    }
}
