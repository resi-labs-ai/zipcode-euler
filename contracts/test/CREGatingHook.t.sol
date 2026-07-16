// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {CREGatingHook} from "../src/CREGatingHook.sol";

/// @notice Mock EVK GenericFactory — `isProxy` returns true for a settable set of vault addresses.
contract MockFactory {
    mapping(address => bool) public proxies;

    function setProxy(address proxy, bool isProxy_) external {
        proxies[proxy] = isProxy_;
    }

    function isProxy(address proxy) external view returns (bool) {
        return proxies[proxy];
    }
}

/// @notice Mock EVC — per-(account, operator) authorization map, mirroring the real predicate.
contract MockEVC {
    mapping(address => mapping(address => bool)) public authorized;

    function setAuthorized(address account, address operator, bool ok) external {
        authorized[account][operator] = ok;
    }

    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool) {
        return authorized[account][operator];
    }
}

contract CREGatingHookTest is Test {
    MockFactory factory;
    MockEVC evc;
    CREGatingHook hook;

    address borrowDriver = makeAddr("borrowDriver");
    address vault = makeAddr("vault"); // the proxy / EVK vault that invokes the hook
    address nonProxy = makeAddr("nonProxy"); // a non-vault caller (EOA), isProxy == false

    address lineAccount = makeAddr("lineAccount"); // a line's fresh per-line borrow account (authorized)
    address foreignAccount = makeAddr("foreignAccount"); // an external account (unauthorized)
    address spoofedAccount = makeAddr("spoofedAccount"); // appended-bytes spoof target (authorized)

    // mirrors of the contract events (for vm.expectEmit)
    event WiringSet(bytes32 indexed slot, address value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        factory = new MockFactory();
        evc = new MockEVC();
        hook = new CREGatingHook(address(factory), address(evc), borrowDriver);

        // The vault is a recognized factory proxy.
        factory.setProxy(vault, true);

        // lineAccount has granted borrowDriver the operator bit (a real per-line borrow account).
        evc.setAuthorized(lineAccount, borrowDriver, true);
        // foreignAccount has NOT (the N1/N1b external case).
        evc.setAuthorized(foreignAccount, borrowDriver, false);
        // spoofedAccount IS authorized — used to prove the isProxy guard blocks spoofing.
        evc.setAuthorized(spoofedAccount, borrowDriver, true);
    }

    /// @dev Invokes the hook fallback the way EVK Base.sol does: calldata = selector/data ++ 20-byte
    /// on-behalf account, from `from` as msg.sender. Returns the low-level call result.
    function _callFallbackAs(address from, bytes4 selector, address appendedAccount)
        internal
        returns (bool success, bytes memory ret)
    {
        bytes memory data = abi.encodePacked(selector, appendedAccount);
        vm.prank(from);
        (success, ret) = address(hook).call(data);
    }

    // (a) isHookTarget() returns 0x87439e04 from a proxy; 0x0 from a non-proxy.
    function test_a_isHookTarget_proxy_returnsMagic() public {
        vm.prank(vault);
        bytes4 magic = hook.isHookTarget();
        assertEq(magic, IHookTarget.isHookTarget.selector, "magic must equal selector");
        assertEq(magic, bytes4(0x87439e04), "magic must be 0x87439e04");
    }

    function test_a_isHookTarget_nonProxy_returnsZero() public {
        vm.prank(nonProxy);
        bytes4 magic = hook.isHookTarget();
        assertEq(magic, bytes4(0), "non-proxy must get 0x0");
    }

    // (b) fallback with an appended authorized account (a line's fresh borrow account) passes.
    function test_b_fallback_authorizedAccount_passes() public {
        // Use OP_BORROW's selector slot is irrelevant — the hook is op-agnostic; use an arbitrary 4 bytes.
        (bool ok, bytes memory ret) = _callFallbackAs(vault, bytes4(0xaabbccdd), lineAccount);
        assertTrue(ok, "authorized line account must pass the hook");
        assertEq(ret.length, 0, "hook returns no data on success");
    }

    // (c) fallback with an appended UNauthorized account reverts the named custom error.
    function test_c_fallback_unauthorizedAccount_reverts() public {
        (bool ok, bytes memory ret) = _callFallbackAs(vault, bytes4(0xaabbccdd), foreignAccount);
        assertFalse(ok, "foreign account must be rejected");
        assertEq(bytes4(ret), CREGatingHook.NotAuthorizedOperator.selector, "must revert NotAuthorizedOperator");
    }

    // (d) isProxy-guard spoof test: a NON-proxy msg.sender appending an *authorized* account is rejected,
    // because _msgSender() falls back to msg.sender (the non-proxy EOA), which is NOT authorized.
    function test_d_isProxyGuard_spoofRejected() public {
        // Sanity: the appended account IS authorized, so any success would mean the appended bytes were trusted.
        assertTrue(evc.isAccountOperatorAuthorized(spoofedAccount, borrowDriver), "spoof target is authorized");
        // The non-proxy msg.sender is NOT authorized.
        assertFalse(evc.isAccountOperatorAuthorized(nonProxy, borrowDriver), "non-proxy msg.sender not authorized");

        (bool ok, bytes memory ret) = _callFallbackAs(nonProxy, bytes4(0xaabbccdd), spoofedAccount);
        assertFalse(ok, "non-proxy must not spoof an appended authorized account");
        assertEq(bytes4(ret), CREGatingHook.NotAuthorizedOperator.selector, "guard used msg.sender, not appended bytes");
    }

    // (d-converse) When the non-proxy msg.sender ITSELF is authorized, the fallback passes — confirming
    // the guard fell back to msg.sender (and that the path is sound), not to the appended bytes.
    function test_d_nonProxy_authorizedSelf_passes() public {
        evc.setAuthorized(nonProxy, borrowDriver, true);
        (bool ok,) = _callFallbackAs(nonProxy, bytes4(0xaabbccdd), foreignAccount);
        assertTrue(ok, "authorized msg.sender passes even with unauthorized appended bytes (proves msg.sender used)");
    }

    // (e) Repay stays permissionless BY CONSTRUCTION: the gate is op-agnostic — the same authorization
    // predicate applies regardless of which 4-byte selector prefixes the calldata. The contract has no
    // OP_REPAY branch; deploy installs only OP_BORROW | OP_LIQUIDATE so repay never reaches this hook.
    function test_e_opAgnostic_uniformGate() public {
        // Two different leading "selectors" (stand-ins for borrow vs liquidate) yield identical behavior.
        (bool okBorrow,) = _callFallbackAs(vault, bytes4(0x00000001), lineAccount);
        (bool okLiquidate,) = _callFallbackAs(vault, bytes4(0x00000002), lineAccount);
        assertTrue(okBorrow, "op-agnostic: authorized account passes (selector 1)");
        assertTrue(okLiquidate, "op-agnostic: authorized account passes (selector 2)");

        (bool failBorrow,) = _callFallbackAs(vault, bytes4(0x00000001), foreignAccount);
        (bool failLiquidate,) = _callFallbackAs(vault, bytes4(0x00000002), foreignAccount);
        assertFalse(failBorrow, "op-agnostic: unauthorized rejected (selector 1)");
        assertFalse(failLiquidate, "op-agnostic: unauthorized rejected (selector 2)");
    }

    // Records the actual custom-error selector for the evidence trail.
    function test_errorSelector() public pure {
        assertEq(CREGatingHook.NotAuthorizedOperator.selector, bytes4(0x3d9adf1c), "NotAuthorizedOperator() selector");
    }

    // ============================================================
    // (I-6) Build-phase admin surface — onlyOwner + ZeroAddress + effect/event
    // ============================================================
    // The owner == this test (deployed the hook in setUp). The bespoke onlyOwner checks the RAW msg.sender.

    /// @notice Every admin function is `onlyOwner` — a non-owner reverts `NotOwner`.
    function test_f_admin_onlyOwner() public {
        address bad = makeAddr("notOwner");
        vm.startPrank(bad);
        vm.expectRevert(CREGatingHook.NotOwner.selector);
        hook.transferOwnership(bad);
        vm.expectRevert(CREGatingHook.NotOwner.selector);
        hook.setEVaultFactory(bad);
        vm.expectRevert(CREGatingHook.NotOwner.selector);
        hook.setEvc(bad);
        vm.expectRevert(CREGatingHook.NotOwner.selector);
        hook.setBorrowDriver(bad);
        vm.stopPrank();
    }

    /// @notice Every admin function zero-guards: `address(0)` reverts `ZeroAddress` (as the owner).
    function test_f_admin_zeroGuards() public {
        vm.expectRevert(CREGatingHook.ZeroAddress.selector);
        hook.transferOwnership(address(0));
        vm.expectRevert(CREGatingHook.ZeroAddress.selector);
        hook.setEVaultFactory(address(0));
        vm.expectRevert(CREGatingHook.ZeroAddress.selector);
        hook.setEvc(address(0));
        vm.expectRevert(CREGatingHook.ZeroAddress.selector);
        hook.setBorrowDriver(address(0));
    }

    /// @notice The three wiring setters re-point their slot and emit `WiringSet(slot, value)`.
    function test_f_setters_effect_and_events() public {
        address x = makeAddr("rewire");

        vm.expectEmit(true, false, false, true, address(hook));
        emit WiringSet("eVaultFactory", x);
        hook.setEVaultFactory(x);
        assertEq(address(hook.eVaultFactory()), x, "eVaultFactory re-pointed");

        vm.expectEmit(true, false, false, true, address(hook));
        emit WiringSet("evc", x);
        hook.setEvc(x);
        assertEq(address(hook.evc()), x, "evc re-pointed");

        vm.expectEmit(true, false, false, true, address(hook));
        emit WiringSet("borrowDriver", x);
        hook.setBorrowDriver(x);
        assertEq(hook.borrowDriver(), x, "borrowDriver re-pointed");
    }

    /// @notice `transferOwnership` hands off the admin (emits `OwnershipTransferred`); the old owner then loses power.
    function test_f_transferOwnership_effect() public {
        address newOwner = makeAddr("timelock");
        vm.expectEmit(true, true, false, false, address(hook));
        emit OwnershipTransferred(address(this), newOwner);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner, "owner handed off");

        // the OLD owner (this test) can no longer call an admin function.
        vm.expectRevert(CREGatingHook.NotOwner.selector);
        hook.setBorrowDriver(makeAddr("x"));

        // the NEW owner can.
        vm.prank(newOwner);
        hook.setBorrowDriver(makeAddr("d"));
    }

    /// @notice The highest-stakes re-point: `setBorrowDriver` changes WHICH operator the gate authorizes against.
    ///         After the re-point, an account that authorized the NEW driver passes the fallback gate, while the
    ///         line account that only authorized the OLD driver is now rejected `NotAuthorizedOperator`.
    function test_f_setBorrowDriver_repoint_changes_gate() public {
        address newDriver = makeAddr("newBorrowDriver");
        address acctNew = makeAddr("acctAuthorizedToNewDriver");
        evc.setAuthorized(acctNew, newDriver, true); // authorizes only the NEW driver
        // sanity: lineAccount authorized the OLD driver (setUp), not the new one.
        assertTrue(evc.isAccountOperatorAuthorized(lineAccount, borrowDriver), "lineAccount -> old driver");
        assertFalse(evc.isAccountOperatorAuthorized(lineAccount, newDriver), "lineAccount NOT -> new driver");

        hook.setBorrowDriver(newDriver);

        // the old line account (only authorized to the old driver) is now rejected.
        (bool okOld, bytes memory retOld) = _callFallbackAs(vault, bytes4(0xaabbccdd), lineAccount);
        assertFalse(okOld, "old-driver account rejected after re-point");
        assertEq(bytes4(retOld), CREGatingHook.NotAuthorizedOperator.selector, "reverts NotAuthorizedOperator");

        // an account authorized to the NEW driver now passes.
        (bool okNew,) = _callFallbackAs(vault, bytes4(0xaabbccdd), acctNew);
        assertTrue(okNew, "new-driver account passes the re-pointed gate");
    }
}
