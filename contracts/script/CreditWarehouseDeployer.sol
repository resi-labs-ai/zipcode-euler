// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {BaseAddresses} from "./BaseAddresses.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {ISafeProxyFactory} from "../src/interfaces/safe/ISafeProxyFactory.sol";
import {IModuleProxyFactory} from "../src/interfaces/zodiac/IModuleProxyFactory.sol";
import {IRoles} from "../src/interfaces/zodiac/IRoles.sol";
import {IEulerEarn} from "../src/interfaces/euler/IEulerEarn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WarehouseAdminModule} from "../src/supply/CreditWarehouse/WarehouseAdminModule.sol";

/// @title CreditWarehouseDeployer (8-Bw)
/// @notice The callable deploy/wire library for the SENIOR-side `CreditWarehouse` (§4.5/§8.5). It stands up,
///         against the LIVE Base infra (Safe factory/singleton + Roles-v2 mastercopy + ModuleProxyFactory):
///           1. a fresh Gnosis Safe (owner = `godOwner`, threshold 1) — the EE-share/USDC custodian,
///           2. a Roles-modifier-v2 proxy (`avatar==target==Safe`, `owner==godOwner`), `enableModule`'d on the Safe,
///           3. the parameter-pinned scope (trees A–D) for the four warehouse ops, Call-only,
///           4. the `WarehouseAdminModule` adapter, `assignRoles`'d as the sole role member.
///         It ASSERTS the proxy init state (Safe owners/threshold; Roles avatar/target/owner; module enabled) BEFORE
///         scoping — never trusting a CREATE2 address blindly (a front-run with different init params resolves to a
///         different address; the assert fails closed on a mis-deploy). It does NOT renounce and does NOT set the
///         adapter's identity expectations — that immutability seal is the item-10 / §4.4 S11 deploy pass.
contract CreditWarehouseDeployer {
    /// @notice The on-chain role key (any non-zero bytes32 is valid; the SDK short-string is an off-chain convention).
    bytes32 public constant ROLE_KEY = keccak256("ZIPCODE_WAREHOUSE_CRE");

    // -- Roles ConditionFlat enum ordinals (Types.sol, verified) ------------------------------------------------
    uint8 internal constant ABI_STATIC = 1; // AbiType.Static
    uint8 internal constant ABI_CALLDATA = 5; // AbiType.Calldata
    uint8 internal constant OP_PASS = 0; // Operator.Pass
    uint8 internal constant OP_MATCHES = 5; // Operator.Matches (the Calldata root)
    uint8 internal constant OP_EQUAL_TO_AVATAR = 15; // Operator.EqualToAvatar (Static; empty compValue)
    uint8 internal constant OP_EQUAL_TO = 16; // Operator.EqualTo (Static; 32-byte compValue)
    uint8 internal constant EXEC_NONE = 0; // ExecutionOptions.None (Call-only)

    /// @notice The deployed warehouse handle (single source of truth for the test's `roleKey` read).
    struct Warehouse {
        address safe;
        address roles;
        address adapter;
        bytes32 roleKey;
    }

    /// @notice A post-deploy init-state assertion failed (front-run / mis-deploy guard).
    error SafeInitMismatch();
    /// @notice The Roles proxy init state (avatar/target/owner) did not match expectations.
    error RolesInitMismatch();
    /// @notice The Roles module is not enabled on the Safe.
    error ModuleNotEnabled();

    /// @notice The Safe owner-list sentinel (`SENTINEL_OWNERS`) — `prevOwner` for the sole owner in `swapOwner`.
    address internal constant SENTINEL_OWNERS = address(0x1);

    /// @notice Deploy + wire the full warehouse, then hand BOTH the Safe and the Roles owner to `godOwner`.
    /// @dev The deployer is the TRANSIENT owner of both: it is the only address that can drive the Safe's 1/1
    ///      pre-validated owner-signature path (Safe `v==1` requires `msg.sender == owner`), and the Roles
    ///      `onlyOwner` scope/assign calls (`msg.sender == owner`). After wiring it `swapOwner`s the Safe and
    ///      `transferOwnership`s the Roles to `godOwner` (the GOD-EOA, later upgraded to a multisig at item-10).
    ///      It does NOT renounce the adapter / set its identity expectations — that is the item-10 / §4.4 S11 seal.
    /// @param receiverAdmin The interim owner the `WarehouseAdminModule` adapter (a CRE `ReceiverTemplate`) is handed
    ///        to. This is the item-10 deploy broadcaster — NOT `godOwner`. The Safe + Roles are custody artifacts that
    ///        go to `godOwner`; the adapter is a CRE receiver whose identity the item-10 script seals and whose final
    ///        home is the Timelock, so it must be owned by that script's broadcaster (else it is stranded under this
    ///        throwaway deployer instance and can never be sealed/re-homed).
    function deploy(
        address godOwner,
        address receiverAdmin,
        address eePool,
        address usdc,
        address forwarder,
        address repaySink,
        uint256 saltNonce
    ) external returns (Warehouse memory w) {
        // 1. Safe — owner = this deployer (transient), threshold 1, no fallbackHandler (holds only ERC-20 shares/USDC).
        address safe = _deploySafe(saltNonce);

        // 2. Roles proxy — setUp(abi.encode(owner, avatar, target)) = (this deployer, safe, safe).
        address roles = _deployRoles(safe, saltNonce);

        // 3. enableModule — drive the Safe as its 1/1 owner (pre-validated signature; msg.sender == this == owner).
        _execTransactionAsSelf(safe, abi.encodeWithSelector(ISafe.enableModule.selector, roles));
        if (!ISafe(safe).isModuleEnabled(roles)) revert ModuleNotEnabled();

        // 4. Scope the role (as Roles owner = this). Call-only (options = None).
        _scope(roles, eePool, usdc, repaySink);

        // 5. Adapter.
        address adapter = address(
            new WarehouseAdminModule(forwarder, roles, ROLE_KEY, safe, eePool, usdc, repaySink)
        );

        // 6. assignRoles the adapter as the sole role member; 7. hand off Safe/Roles to godOwner + the adapter (a CRE
        //    receiver) to receiverAdmin (the item-10 broadcaster).
        _assignAndHandoff(safe, roles, adapter, godOwner, receiverAdmin);

        w = Warehouse({safe: safe, roles: roles, adapter: adapter, roleKey: ROLE_KEY});
    }

    function _deploySafe(uint256 saltNonce) internal returns (address safe) {
        address[] memory owners = new address[](1);
        owners[0] = address(this);
        bytes memory initializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,
            uint256(1),
            address(0),
            bytes(""),
            address(0),
            address(0),
            uint256(0),
            payable(address(0))
        );
        safe = ISafeProxyFactory(BaseAddresses.SAFE_PROXY_FACTORY_1_3_0).createProxyWithNonce(
            BaseAddresses.SAFE_L2_SINGLETON_1_4_1, initializer, saltNonce
        );
        // Assert the CREATE2 proxy resolved to the params we asked for (never trust a blind address).
        address[] memory got = ISafe(safe).getOwners();
        if (got.length != 1 || got[0] != address(this) || ISafe(safe).getThreshold() != 1) {
            revert SafeInitMismatch();
        }
    }

    function _deployRoles(address safe, uint256 saltNonce) internal returns (address roles) {
        bytes memory initializer = abi.encodeWithSignature("setUp(bytes)", abi.encode(address(this), safe, safe));
        roles = IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY).deployModule(
            BaseAddresses.ZODIAC_ROLES_MASTERCOPY, initializer, saltNonce
        );
        if (
            IRolesInit(roles).avatar() != safe || IRolesInit(roles).target() != safe
                || IRolesInit(roles).owner() != address(this)
        ) {
            revert RolesInitMismatch();
        }
    }

    function _scope(address roles, address eePool, address usdc, address repaySink) internal {
        bytes32 rk = ROLE_KEY;
        IRoles(roles).scopeTarget(rk, eePool);
        IRoles(roles).scopeFunction(rk, eePool, IEulerEarn.deposit.selector, _treeDeposit(), EXEC_NONE);
        IRoles(roles).scopeFunction(rk, eePool, IEulerEarn.redeem.selector, _treeRedeem(), EXEC_NONE);
        IRoles(roles).scopeTarget(rk, usdc);
        IRoles(roles).scopeFunction(rk, usdc, IERC20.approve.selector, _treeApprove(eePool), EXEC_NONE);
        IRoles(roles).scopeFunction(rk, usdc, IERC20.transfer.selector, _treeTransfer(repaySink), EXEC_NONE);
    }

    function _assignAndHandoff(address safe, address roles, address adapter, address godOwner, address receiverAdmin)
        internal
    {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = ROLE_KEY;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;
        IRoles(roles).assignRoles(adapter, keys, memberOf);

        // Hand off: the adapter (a CRE ReceiverTemplate, OZ-Ownable) to receiverAdmin (the item-10 broadcaster), the
        // Roles `transferOwnership` + the Safe `swapOwner` (drop self) to godOwner.
        IOwnable(adapter).transferOwnership(receiverAdmin);
        IOwnable(roles).transferOwnership(godOwner);
        _execTransactionAsSelf(
            safe, abi.encodeWithSelector(ISafe.swapOwner.selector, SENTINEL_OWNERS, address(this), godOwner)
        );
        // Assert the handoff landed (effect, not "didn't revert").
        address[] memory finalOwners = ISafe(safe).getOwners();
        if (finalOwners.length != 1 || finalOwners[0] != godOwner) revert SafeInitMismatch();
        if (IRolesInit(roles).owner() != godOwner) revert RolesInitMismatch();
        if (IRolesInit(adapter).owner() != receiverAdmin) revert RolesInitMismatch();
    }

    /// @dev Drive `safe` via the owner `execTransaction` path with the 1/1 pre-validated signature (msg.sender ==
    ///      this == the sole owner). The `uint256(uint160(...))` hop is required — `bytes32(uint160(x))` does NOT
    ///      compile (proven in SummonSubstrate.s.sol:163). All call to `safe` itself, value 0, Operation.Call.
    function _execTransactionAsSelf(address safe, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(address(this)))), bytes32(0), uint8(1));
        ISafe(safe).execTransaction(safe, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    // ---------- ConditionFlat trees (BFS order, root at index 0; verified to pass Integrity.enforce) ----------

    /// @dev A — deposit(uint256 assets, address receiver): receiver pinned to the avatar (the Safe).
    function _treeDeposit() internal pure returns (IRoles.ConditionFlat[] memory c) {
        c = new IRoles.ConditionFlat[](3);
        c[0] = _root();
        c[1] = IRoles.ConditionFlat(0, ABI_STATIC, OP_PASS, ""); // assets
        c[2] = IRoles.ConditionFlat(0, ABI_STATIC, OP_EQUAL_TO_AVATAR, ""); // receiver == avatar
    }

    /// @dev B — redeem(uint256 shares, address receiver, address owner): receiver == owner == avatar.
    function _treeRedeem() internal pure returns (IRoles.ConditionFlat[] memory c) {
        c = new IRoles.ConditionFlat[](4);
        c[0] = _root();
        c[1] = IRoles.ConditionFlat(0, ABI_STATIC, OP_PASS, ""); // shares
        c[2] = IRoles.ConditionFlat(0, ABI_STATIC, OP_EQUAL_TO_AVATAR, ""); // receiver == avatar
        c[3] = IRoles.ConditionFlat(0, ABI_STATIC, OP_EQUAL_TO_AVATAR, ""); // owner == avatar
    }

    /// @dev C — approve(address spender, uint256 amount): spender pinned to eePool; amount free.
    function _treeApprove(address eePool) internal pure returns (IRoles.ConditionFlat[] memory c) {
        c = new IRoles.ConditionFlat[](3);
        c[0] = _root();
        c[1] = IRoles.ConditionFlat(0, ABI_STATIC, OP_EQUAL_TO, abi.encode(eePool)); // spender == eePool
        c[2] = IRoles.ConditionFlat(0, ABI_STATIC, OP_PASS, ""); // amount
    }

    /// @dev D — transfer(address to, uint256 amount): `to` pinned to repaySink (MUST be EqualTo, never Pass).
    function _treeTransfer(address repaySink) internal pure returns (IRoles.ConditionFlat[] memory c) {
        c = new IRoles.ConditionFlat[](3);
        c[0] = _root();
        c[1] = IRoles.ConditionFlat(0, ABI_STATIC, OP_EQUAL_TO, abi.encode(repaySink)); // to == repaySink
        c[2] = IRoles.ConditionFlat(0, ABI_STATIC, OP_PASS, ""); // amount
    }

    /// @dev The Calldata-Matches root (index 0, parent 0, empty compValue) every scope tree starts with.
    function _root() internal pure returns (IRoles.ConditionFlat memory) {
        return IRoles.ConditionFlat(0, ABI_CALLDATA, OP_MATCHES, "");
    }
}

/// @notice The Roles proxy init-state getters (avatar/target/owner are public state vars on the Modifier/Ownable base).
interface IRolesInit {
    function avatar() external view returns (address);
    function target() external view returns (address);
    function owner() external view returns (address);
}

/// @notice The Roles owner-transfer surface (zodiac `Ownable.transferOwnership`, onlyOwner).
interface IOwnable {
    function transferOwnership(address newOwner) external;
}
