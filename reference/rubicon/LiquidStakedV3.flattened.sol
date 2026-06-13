// PROVENANCE — vendored verified source (read-only reference; NOT compiled by this repo)
// Project Rubicon (General TAO Ventures) — LiquidStakedV3, the production Bittensor xAlpha LST wrapper.
// Implementation: 0x395d0996C345b6e16590dB82917c1BFb00577fba (Subtensor EVM 964)
//   (proxied by e.g. xSN64 token 0x3D44B9c5eBA6DE51f4Da3152341EBe591962e843, ERC1967)
// Fetched: 2026-06-12 from the Taostats Blockscout verified-source API
//   https://evm.taostats.io/api/v2/smart-contracts/0x395d0996C345b6e16590dB82917c1BFb00577fba
// Compiler: v0.8.24+commit.e11b9ed9, evm: cancun. Audit: Hashlock (Oct 2025).
// Why vendored: this is the proven-pattern source of truth for the 8x-01 SzAlpha rework — precompile
// unit semantics (rao 9-dp), measured-delta minting, slippage params, lock/release CCIP topology.
// See reference/rubicon/README.md + build/wires/8x-01-szALPHA-bridge.md (§Provenance).

// Sources flattened with hardhat v2.26.1 https://hardhat.org

// SPDX-License-Identifier: GPL-3.0 AND MIT

// File @openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.3.0) (proxy/utils/Initializable.sol)

pragma solidity ^0.8.20;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```solidity
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 *
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Storage of the initializable contract.
     *
     * It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions
     * when using with upgradeable contracts.
     *
     * @custom:storage-location erc7201:openzeppelin.storage.Initializable
     */
    struct InitializableStorage {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        uint64 _initialized;
        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /**
     * @dev The contract is already initialized.
     */
    error InvalidInitialization();

    /**
     * @dev The contract is not initializing.
     */
    error NotInitializing();

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint64 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that in the context of a constructor an `initializer` may be invoked any
     * number of times. This behavior in the constructor can be useful during testing and is not expected to be used in
     * production.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        // Cache values to avoid duplicated sloads
        bool isTopLevelCall = !$._initializing;
        uint64 initialized = $._initialized;

        // Allowed calls:
        // - initialSetup: the contract is not in the initializing state and no previous version was
        //                 initialized
        // - construction: the contract is initialized at version 1 (no reinitialization) and the
        //                 current contract is just being deployed
        bool initialSetup = initialized == 0 && isTopLevelCall;
        bool construction = initialized == 1 && address(this).code.length == 0;

        if (!initialSetup && !construction) {
            revert InvalidInitialization();
        }
        $._initialized = 1;
        if (isTopLevelCall) {
            $._initializing = true;
        }
        _;
        if (isTopLevelCall) {
            $._initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: Setting the version to 2**64 - 1 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint64 version) {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    /**
     * @dev Reverts if the contract is not in an initializing state. See {onlyInitializing}.
     */
    function _checkInitializing() internal view virtual {
        if (!_isInitializing()) {
            revert NotInitializing();
        }
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing) {
            revert InvalidInitialization();
        }
        if ($._initialized != type(uint64).max) {
            $._initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint64) {
        return _getInitializableStorage()._initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _getInitializableStorage()._initializing;
    }

    /**
     * @dev Pointer to storage slot. Allows integrators to override it with a custom storage location.
     *
     * NOTE: Consider following the ERC-7201 formula to derive storage locations.
     */
    function _initializableStorageSlot() internal pure virtual returns (bytes32) {
        return INITIALIZABLE_STORAGE;
    }

    /**
     * @dev Returns a pointer to the storage namespace.
     */
    // solhint-disable-next-line var-name-mixedcase
    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        bytes32 slot = _initializableStorageSlot();
        assembly {
            $.slot := slot
        }
    }
}


// File @openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}


// File @openzeppelin/contracts/utils/introspection/IERC165.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/IERC165.sol)

pragma solidity >=0.4.16;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}


// File @openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/ERC165.sol)

pragma solidity ^0.8.20;


/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165Upgradeable is Initializable, IERC165 {
    function __ERC165_init() internal onlyInitializing {
    }

    function __ERC165_init_unchained() internal onlyInitializing {
    }
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}


// File @openzeppelin/contracts/access/IAccessControl.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (access/IAccessControl.sol)

pragma solidity >=0.8.4;

/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted to signal this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}


// File @openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (access/AccessControl.sol)

pragma solidity ^0.8.20;





/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControlUpgradeable is Initializable, ContextUpgradeable, IAccessControl, ERC165Upgradeable {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;


    /// @custom:storage-location erc7201:openzeppelin.storage.AccessControl
    struct AccessControlStorage {
        mapping(bytes32 role => RoleData) _roles;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.AccessControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessControlStorageLocation = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    function _getAccessControlStorage() private pure returns (AccessControlStorage storage $) {
        assembly {
            $.slot := AccessControlStorageLocation
        }
    }

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    function __AccessControl_init() internal onlyInitializing {
    }

    function __AccessControl_init_unchained() internal onlyInitializing {
    }
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        return $._roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        return $._roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        AccessControlStorage storage $ = _getAccessControlStorage();
        bytes32 previousAdminRole = getRoleAdmin(role);
        $._roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        if (!hasRole(role, account)) {
            $._roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` from `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        if (hasRole(role, account)) {
            $._roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}


// File @openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.Ownable
    struct OwnableStorage {
        address _owner;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OwnableStorageLocation = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function _getOwnableStorage() private pure returns (OwnableStorage storage $) {
        assembly {
            $.slot := OwnableStorageLocation
        }
    }

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    function __Ownable_init(address initialOwner) internal onlyInitializing {
        __Ownable_init_unchained(initialOwner);
    }

    function __Ownable_init_unchained(address initialOwner) internal onlyInitializing {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        OwnableStorage storage $ = _getOwnableStorage();
        return $._owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        OwnableStorage storage $ = _getOwnableStorage();
        address oldOwner = $._owner;
        $._owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


// File @openzeppelin/contracts/interfaces/draft-IERC1822.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/draft-IERC1822.sol)

pragma solidity >=0.4.16;

/**
 * @dev ERC-1822: Universal Upgradeable Proxy Standard (UUPS) documents a method for upgradeability through a simplified
 * proxy whose upgrades are fully controlled by the current implementation.
 */
interface IERC1822Proxiable {
    /**
     * @dev Returns the storage slot that the proxiable contract assumes is being used to store the implementation
     * address.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy.
     */
    function proxiableUUID() external view returns (bytes32);
}


// File @openzeppelin/contracts/interfaces/IERC1967.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC1967.sol)

pragma solidity >=0.4.11;

/**
 * @dev ERC-1967: Proxy Storage Slots. This interface contains the events defined in the ERC.
 */
interface IERC1967 {
    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Emitted when the admin account has changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Emitted when the beacon is changed.
     */
    event BeaconUpgraded(address indexed beacon);
}


// File @openzeppelin/contracts/proxy/beacon/IBeacon.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (proxy/beacon/IBeacon.sol)

pragma solidity >=0.4.16;

/**
 * @dev This is the interface that {BeaconProxy} expects of its beacon.
 */
interface IBeacon {
    /**
     * @dev Must return an address that can be used as a delegate call target.
     *
     * {UpgradeableBeacon} will check that this address is a contract.
     */
    function implementation() external view returns (address);
}


// File @openzeppelin/contracts/utils/Errors.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Errors.sol)

pragma solidity ^0.8.20;

/**
 * @dev Collection of common custom errors used in multiple contracts
 *
 * IMPORTANT: Backwards compatibility is not guaranteed in future versions of the library.
 * It is recommended to avoid relying on the error API for critical functionality.
 *
 * _Available since v5.1._
 */
library Errors {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error InsufficientBalance(uint256 balance, uint256 needed);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedCall();

    /**
     * @dev The deployment failed.
     */
    error FailedDeployment();

    /**
     * @dev A necessary precompile is missing.
     */
    error MissingPrecompile(address);
}


// File @openzeppelin/contracts/utils/Address.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (utils/Address.sol)

pragma solidity ^0.8.20;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert Errors.InsufficientBalance(address(this).balance, amount);
        }

        (bool success, bytes memory returndata) = recipient.call{value: amount}("");
        if (!success) {
            _revert(returndata);
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {Errors.FailedCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert Errors.InsufficientBalance(address(this).balance, value);
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {Errors.FailedCall}) in case
     * of an unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {Errors.FailedCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {Errors.FailedCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        } else {
            revert Errors.FailedCall();
        }
    }
}


// File @openzeppelin/contracts/utils/StorageSlot.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}


// File @openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (proxy/ERC1967/ERC1967Utils.sol)

pragma solidity ^0.8.21;




/**
 * @dev This library provides getters and event emitting update functions for
 * https://eips.ethereum.org/EIPS/eip-1967[ERC-1967] slots.
 */
library ERC1967Utils {
    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev The `implementation` of the proxy is invalid.
     */
    error ERC1967InvalidImplementation(address implementation);

    /**
     * @dev The `admin` of the proxy is invalid.
     */
    error ERC1967InvalidAdmin(address admin);

    /**
     * @dev The `beacon` of the proxy is invalid.
     */
    error ERC1967InvalidBeacon(address beacon);

    /**
     * @dev An upgrade function sees `msg.value > 0` that may be lost.
     */
    error ERC1967NonPayable();

    /**
     * @dev Returns the current implementation address.
     */
    function getImplementation() internal view returns (address) {
        return StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value;
    }

    /**
     * @dev Stores a new address in the ERC-1967 implementation slot.
     */
    function _setImplementation(address newImplementation) private {
        if (newImplementation.code.length == 0) {
            revert ERC1967InvalidImplementation(newImplementation);
        }
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = newImplementation;
    }

    /**
     * @dev Performs implementation upgrade with additional setup call if data is nonempty.
     * This function is payable only if the setup call is performed, otherwise `msg.value` is rejected
     * to avoid stuck value in the contract.
     *
     * Emits an {IERC1967-Upgraded} event.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) internal {
        _setImplementation(newImplementation);
        emit IERC1967.Upgraded(newImplementation);

        if (data.length > 0) {
            Address.functionDelegateCall(newImplementation, data);
        } else {
            _checkNonPayable();
        }
    }

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /**
     * @dev Returns the current admin.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by ERC-1967) using
     * the https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
     */
    function getAdmin() internal view returns (address) {
        return StorageSlot.getAddressSlot(ADMIN_SLOT).value;
    }

    /**
     * @dev Stores a new address in the ERC-1967 admin slot.
     */
    function _setAdmin(address newAdmin) private {
        if (newAdmin == address(0)) {
            revert ERC1967InvalidAdmin(address(0));
        }
        StorageSlot.getAddressSlot(ADMIN_SLOT).value = newAdmin;
    }

    /**
     * @dev Changes the admin of the proxy.
     *
     * Emits an {IERC1967-AdminChanged} event.
     */
    function changeAdmin(address newAdmin) internal {
        emit IERC1967.AdminChanged(getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /**
     * @dev The storage slot of the UpgradeableBeacon contract which defines the implementation for this proxy.
     * This is the keccak-256 hash of "eip1967.proxy.beacon" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /**
     * @dev Returns the current beacon.
     */
    function getBeacon() internal view returns (address) {
        return StorageSlot.getAddressSlot(BEACON_SLOT).value;
    }

    /**
     * @dev Stores a new beacon in the ERC-1967 beacon slot.
     */
    function _setBeacon(address newBeacon) private {
        if (newBeacon.code.length == 0) {
            revert ERC1967InvalidBeacon(newBeacon);
        }

        StorageSlot.getAddressSlot(BEACON_SLOT).value = newBeacon;

        address beaconImplementation = IBeacon(newBeacon).implementation();
        if (beaconImplementation.code.length == 0) {
            revert ERC1967InvalidImplementation(beaconImplementation);
        }
    }

    /**
     * @dev Change the beacon and trigger a setup call if data is nonempty.
     * This function is payable only if the setup call is performed, otherwise `msg.value` is rejected
     * to avoid stuck value in the contract.
     *
     * Emits an {IERC1967-BeaconUpgraded} event.
     *
     * CAUTION: Invoking this function has no effect on an instance of {BeaconProxy} since v5, since
     * it uses an immutable beacon without looking at the value of the ERC-1967 beacon slot for
     * efficiency.
     */
    function upgradeBeaconToAndCall(address newBeacon, bytes memory data) internal {
        _setBeacon(newBeacon);
        emit IERC1967.BeaconUpgraded(newBeacon);

        if (data.length > 0) {
            Address.functionDelegateCall(IBeacon(newBeacon).implementation(), data);
        } else {
            _checkNonPayable();
        }
    }

    /**
     * @dev Reverts if `msg.value` is not zero. It can be used to avoid `msg.value` stuck in the contract
     * if an upgrade doesn't perform an initialization call.
     */
    function _checkNonPayable() private {
        if (msg.value > 0) {
            revert ERC1967NonPayable();
        }
    }
}


// File @openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.3.0) (proxy/utils/UUPSUpgradeable.sol)

pragma solidity ^0.8.22;



/**
 * @dev An upgradeability mechanism designed for UUPS proxies. The functions included here can perform an upgrade of an
 * {ERC1967Proxy}, when this contract is set as the implementation behind such a proxy.
 *
 * A security mechanism ensures that an upgrade does not turn off upgradeability accidentally, although this risk is
 * reinstated if the upgrade retains upgradeability but removes the security mechanism, e.g. by replacing
 * `UUPSUpgradeable` with a custom implementation of upgrades.
 *
 * The {_authorizeUpgrade} function must be overridden to include access restriction to the upgrade mechanism.
 */
abstract contract UUPSUpgradeable is Initializable, IERC1822Proxiable {
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable __self = address(this);

    /**
     * @dev The version of the upgrade interface of the contract. If this getter is missing, both `upgradeTo(address)`
     * and `upgradeToAndCall(address,bytes)` are present, and `upgradeTo` must be used if no function should be called,
     * while `upgradeToAndCall` will invoke the `receive` function if the second argument is the empty byte string.
     * If the getter returns `"5.0.0"`, only `upgradeToAndCall(address,bytes)` is present, and the second argument must
     * be the empty byte string if no function should be called, making it impossible to invoke the `receive` function
     * during an upgrade.
     */
    string public constant UPGRADE_INTERFACE_VERSION = "5.0.0";

    /**
     * @dev The call is from an unauthorized context.
     */
    error UUPSUnauthorizedCallContext();

    /**
     * @dev The storage `slot` is unsupported as a UUID.
     */
    error UUPSUnsupportedProxiableUUID(bytes32 slot);

    /**
     * @dev Check that the execution is being performed through a delegatecall call and that the execution context is
     * a proxy contract with an implementation (as defined in ERC-1967) pointing to self. This should only be the case
     * for UUPS and transparent proxies that are using the current contract as their implementation. Execution of a
     * function through ERC-1167 minimal proxies (clones) would not normally pass this test, but is not guaranteed to
     * fail.
     */
    modifier onlyProxy() {
        _checkProxy();
        _;
    }

    /**
     * @dev Check that the execution is not being performed through a delegate call. This allows a function to be
     * callable on the implementing contract but not through proxies.
     */
    modifier notDelegated() {
        _checkNotDelegated();
        _;
    }

    function __UUPSUpgradeable_init() internal onlyInitializing {
    }

    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev Implementation of the ERC-1822 {proxiableUUID} function. This returns the storage slot used by the
     * implementation. It is used to validate the implementation's compatibility when performing an upgrade.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.
     */
    function proxiableUUID() external view virtual notDelegated returns (bytes32) {
        return ERC1967Utils.IMPLEMENTATION_SLOT;
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call
     * encoded in `data`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     *
     * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, data);
    }

    /**
     * @dev Reverts if the execution is not performed via delegatecall or the execution
     * context is not of a proxy with an ERC-1967 compliant implementation pointing to self.
     */
    function _checkProxy() internal view virtual {
        if (
            address(this) == __self || // Must be called through delegatecall
            ERC1967Utils.getImplementation() != __self // Must be called through an active proxy
        ) {
            revert UUPSUnauthorizedCallContext();
        }
    }

    /**
     * @dev Reverts if the execution is performed via delegatecall.
     * See {notDelegated}.
     */
    function _checkNotDelegated() internal view virtual {
        if (address(this) != __self) {
            // Must not be called through delegatecall
            revert UUPSUnauthorizedCallContext();
        }
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeToAndCall}.
     *
     * Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.
     *
     * ```solidity
     * function _authorizeUpgrade(address) internal onlyOwner {}
     * ```
     */
    function _authorizeUpgrade(address newImplementation) internal virtual;

    /**
     * @dev Performs an implementation upgrade with a security check for UUPS proxies, and additional setup call.
     *
     * As a security check, {proxiableUUID} is invoked in the new implementation, and the return value
     * is expected to be the implementation slot in ERC-1967.
     *
     * Emits an {IERC1967-Upgraded} event.
     */
    function _upgradeToAndCallUUPS(address newImplementation, bytes memory data) private {
        try IERC1822Proxiable(newImplementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != ERC1967Utils.IMPLEMENTATION_SLOT) {
                revert UUPSUnsupportedProxiableUUID(slot);
            }
            ERC1967Utils.upgradeToAndCall(newImplementation, data);
        } catch {
            // The implementation is not UUPS
            revert ERC1967Utils.ERC1967InvalidImplementation(newImplementation);
        }
    }
}


// File @openzeppelin/contracts/interfaces/draft-IERC6093.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/draft-IERC6093.sol)
pragma solidity >=0.8.4;

/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}


// File @openzeppelin/contracts/token/ERC20/IERC20.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

pragma solidity >=0.4.16;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}


// File @openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity >=0.6.2;

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}


// File @openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;





/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20Upgradeable is Initializable, ContextUpgradeable, IERC20, IERC20Metadata, IERC20Errors {
    /// @custom:storage-location erc7201:openzeppelin.storage.ERC20
    struct ERC20Storage {
        mapping(address account => uint256) _balances;

        mapping(address account => mapping(address spender => uint256)) _allowances;

        uint256 _totalSupply;

        string _name;
        string _symbol;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20StorageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    function _getERC20Storage() private pure returns (ERC20Storage storage $) {
        assembly {
            $.slot := ERC20StorageLocation
        }
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * Both values are immutable: they can only be set once during construction.
     */
    function __ERC20_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal onlyInitializing {
        ERC20Storage storage $ = _getERC20Storage();
        $._name = name_;
        $._symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        ERC20Storage storage $ = _getERC20Storage();
        return $._name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        ERC20Storage storage $ = _getERC20Storage();
        return $._symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        ERC20Storage storage $ = _getERC20Storage();
        return $._totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual returns (uint256) {
        ERC20Storage storage $ = _getERC20Storage();
        return $._balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        ERC20Storage storage $ = _getERC20Storage();
        return $._allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        ERC20Storage storage $ = _getERC20Storage();
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            $._totalSupply += value;
        } else {
            uint256 fromBalance = $._balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                $._balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                $._totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                $._balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner`'s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        ERC20Storage storage $ = _getERC20Storage();
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        $._allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}


// File @openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.3.0) (utils/Pausable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract PausableUpgradeable is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.Pausable
    struct PausableStorage {
        bool _paused;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Pausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PausableStorageLocation = 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;

    function _getPausableStorage() private pure returns (PausableStorage storage $) {
        assembly {
            $.slot := PausableStorageLocation
        }
    }

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    /**
     * @dev The operation failed because the contract is paused.
     */
    error EnforcedPause();

    /**
     * @dev The operation failed because the contract is not paused.
     */
    error ExpectedPause();

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    function __Pausable_init() internal onlyInitializing {
    }

    function __Pausable_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        PausableStorage storage $ = _getPausableStorage();
        return $._paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        if (paused()) {
            revert EnforcedPause();
        }
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        if (!paused()) {
            revert ExpectedPause();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        PausableStorage storage $ = _getPausableStorage();
        $._paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        PausableStorage storage $ = _getPausableStorage();
        $._paused = false;
        emit Unpaused(_msgSender());
    }
}


// File @openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol@v5.4.0

// OpenZeppelin Contracts (last updated v5.1.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /// @custom:storage-location erc7201:openzeppelin.storage.ReentrancyGuard
    struct ReentrancyGuardStorage {
        uint256 _status;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ReentrancyGuardStorageLocation = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function _getReentrancyGuardStorage() private pure returns (ReentrancyGuardStorage storage $) {
        assembly {
            $.slot := ReentrancyGuardStorageLocation
        }
    }

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if ($._status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        $._status = ENTERED;
    }

    function _nonReentrantAfter() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        return $._status == ENTERED;
    }
}


// File contracts/AlphaInterface.sol

pragma solidity ^0.8.0;

address constant IALPHA_ADDRESS = 0x0000000000000000000000000000000000000808;

interface IAlpha {
    /// @dev Returns the current alpha price for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The alpha price in RAO per alpha.
    function getAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @dev Returns the moving (EMA) alpha price for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The moving alpha price in RAO per alpha.
    function getMovingAlphaPrice(uint16 netuid) external view returns (uint256);

    /// @dev Returns the amount of TAO in the pool for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The TAO amount in the pool.
    function getTaoInPool(uint16 netuid) external view returns (uint64);

    /// @dev Returns the amount of alpha in the pool for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The alpha amount in the pool.
    function getAlphaInPool(uint16 netuid) external view returns (uint64);

    /// @dev Returns the amount of alpha outside the pool for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The alpha amount outside the pool.
    function getAlphaOutPool(uint16 netuid) external view returns (uint64);

    /// @dev Returns the total alpha issuance for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The total alpha issuance.
    function getAlphaIssuance(uint16 netuid) external view returns (uint64);

    /// @dev Returns the global TAO weight.
    /// @return The TAO weight value.
    function getTaoWeight() external view returns (uint256);

    /// @dev Simulates swapping TAO for alpha.
    /// @param netuid The subnet identifier.
    /// @param tao The amount of TAO to swap.
    /// @return The amount of alpha that would be received.
    function simSwapTaoForAlpha(
        uint16 netuid,
        uint64 tao
    ) external view returns (uint256);

    /// @dev Simulates swapping alpha for TAO.
    /// @param netuid The subnet identifier.
    /// @param alpha The amount of alpha to swap.
    /// @return The amount of TAO that would be received.
    function simSwapAlphaForTao(
        uint16 netuid,
        uint64 alpha
    ) external view returns (uint256);

    /// @dev Returns the mechanism type for a subnet (0 for Stable, 1 for Dynamic).
    /// @param netuid The subnet identifier.
    /// @return The subnet mechanism type.
    function getSubnetMechanism(uint16 netuid) external view returns (uint16);

    /// @dev Returns the root subnet unique identifier.
    /// @return The root subnet ID.
    function getRootNetuid() external view returns (uint16);

    /// @dev Returns the EMA price halving blocks parameter for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The number of blocks for EMA price halving.
    function getEMAPriceHalvingBlocks(
        uint16 netuid
    ) external view returns (uint64);

    /// @dev Returns the transaction volume for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The subnet volume.
    function getSubnetVolume(uint16 netuid) external view returns (uint256);

    /// @dev Returns the amount of tao emission into the pool per block for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The tao-in emission per block.
    function getTaoInEmission(uint16 netuid) external view returns (uint256);

    /// @dev Returns the amount of alpha emission into the pool per block for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The alpha-in emission per block.
    function getAlphaInEmission(uint16 netuid) external view returns (uint256);

    /// @dev Returns the amount of alpha emission outside the pool per block for a subnet.
    /// @param netuid The subnet identifier.
    /// @return The alpha-out emission per block.
    function getAlphaOutEmission(uint16 netuid) external view returns (uint256);

    /// @dev Returns the sum of alpha prices for all subnets.
    /// @return The sum of alpha prices.
    function getSumAlphaPrice() external view returns (uint256);
}


// File contracts/MetaGraphInterface.sol

pragma solidity ^0.8.0;

address constant IMetagraph_ADDRESS = 0x0000000000000000000000000000000000000802;

struct AxonInfo {
  uint64 block;
  uint32 version;
  uint128 ip;
  uint16 port;
  uint8 ip_type;
  uint8 protocol;
}

interface IMetagraph {
  
  /**
   * @dev Returns the count of unique identifiers (UIDs) associated with a given network identifier (netuid).
   * @param netuid The network identifier for which to retrieve the UID count.
   * @return The count of UIDs associated with the specified netuid.
   */
  function getUidCount(uint16 netuid) external view returns (uint16);

  /**
   * @dev Retrieves the stake amount associated with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the stake.
   * @param uid The unique identifier for which to retrieve the stake.
   * @return The stake amount associated with the specified netuid and uid.
   */
  function getStake(uint16 netuid, uint16 uid) external view returns (uint64);

  /**
   * @dev Retrieves the rank of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the rank.
   * @param uid The unique identifier for which to retrieve the rank.
   * @return The rank of the node with the specified netuid and uid.
   */
  function getRank(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Retrieves the trust value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the trust value.
   * @param uid The unique identifier for which to retrieve the trust value.
   * @return The trust value of the node with the specified netuid and uid.
   */
  function getTrust(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Retrieves the consensus value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the consensus value.
   * @param uid The unique identifier for which to retrieve the consensus value.
   * @return The consensus value of the node with the specified netuid and uid.
   */
  function getConsensus(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Retrieves the incentive value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the incentive value.
   * @param uid The unique identifier for which to retrieve the incentive value.
   * @return The incentive value of the node with the specified netuid and uid.
   */
  function getIncentive(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Retrieves the dividend value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the dividend value.
   * @param uid The unique identifier for which to retrieve the dividend value.
   * @return The dividend value of the node with the specified netuid and uid.
   */
  function getDividends(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Retrieves the emission value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the emission value.
   * @param uid The unique identifier for which to retrieve the emission value.
   * @return The emission value of the node with the specified netuid and uid.
   */
  function getEmission(uint16 netuid, uint16 uid) external view returns (uint64);

  /**
   * @dev Retrieves the v-trust value of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the v-trust value.
   * @param uid The unique identifier for which to retrieve the v-trust value.
   * @return The v-trust value of the node with the specified netuid and uid.
   */
  function getVtrust(uint16 netuid, uint16 uid) external view returns (uint16);

  /**
   * @dev Checks the validator status of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to check the validator status.
   * @param uid The unique identifier for which to check the validator status.
   * @return Returns true if the node is a validator, false otherwise.
   */
  function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool);

  /**
   * @dev Retrieves the last update timestamp of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the last update timestamp.
   * @param uid The unique identifier for which to retrieve the last update timestamp.
   * @return The last update timestamp of the node with the specified netuid and uid.
   */
  function getLastUpdate(uint16 netuid, uint16 uid) external view returns (uint64);

  /**
   * @dev Checks if a node with a given network identifier (netuid) and unique identifier (uid) is active.
   * @param netuid The network identifier for which to check the node's activity.
   * @param uid The unique identifier for which to check the node's activity.
   * @return Returns true if the node is active, false otherwise.
   */
  function getIsActive(uint16 netuid, uint16 uid) external view returns (bool);

  /**
   * @dev Retrieves the axon information of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the axon information.
   * @param uid The unique identifier for which to retrieve the axon information.
   * @return The axon information of the node with the specified netuid and uid.
   */
  function getAxon(uint16 netuid, uint16 uid) external view returns (AxonInfo memory);

  /**
   * @dev Retrieves the hotkey of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the hotkey.
   * @param uid The unique identifier for which to retrieve the hotkey.
   * @return The hotkey of the node with the specified netuid and uid.
   */
  function getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32);

  /**
   * @dev Retrieves the coldkey of a node with a given network identifier (netuid) and unique identifier (uid).
   * @param netuid The network identifier for which to retrieve the coldkey.
   * @param uid The unique identifier for which to retrieve the coldkey.
   * @return The coldkey of the node with the specified netuid and uid.
   */
  function getColdkey(uint16 netuid, uint16 uid) external view returns (bytes32);
}


// File contracts/StakingV2Interface.sol

pragma solidity ^0.8.0;

address constant ISTAKING_ADDRESS = 0x0000000000000000000000000000000000000805;

interface IStaking {
    /**
     * @dev Adds a subtensor stake `amount` associated with the `hotkey`.
     *
     * This function allows external accounts and contracts to stake TAO into the subtensor pallet,
     * which effectively calls `add_stake` on the subtensor pallet with specified hotkey as a parameter
     * and coldkey being the hashed address mapping of H160 sender address to Substrate ss58 address as
     * implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param amount The amount to stake in rao.
     * @param netuid The subnet to stake to (uint256).
     *
     * Requirements:
     * - `hotkey` must be a valid hotkey registered on the network, ensuring that the stake is
     *   correctly attributed.
     */
    function addStake(
        bytes32 hotkey,
        uint256 amount,
        uint256 netuid
    ) external payable;

    /**
     * @dev Removes a subtensor stake `amount` from the specified `hotkey`.
     *
     * This function allows external accounts and contracts to unstake TAO from the subtensor pallet,
     * which effectively calls `remove_stake` on the subtensor pallet with specified hotkey as a parameter
     * and coldkey being the hashed address mapping of H160 sender address to Substrate ss58 address as
     * implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param amount The amount to unstake in alpha.
     * @param netuid The subnet to stake to (uint256).
     *
     * Requirements:
     * - `hotkey` must be a valid hotkey registered on the network, ensuring that the stake is
     *   correctly attributed.
     * - The existing stake amount must be not lower than specified amount
     */
    function removeStake(
        bytes32 hotkey,
        uint256 amount,
        uint256 netuid
    ) external;

    /**
     * @dev Moves a subtensor stake `amount` associated with the `hotkey` to a different hotkey
     * `destination_hotkey`.
     *
     * This function allows external accounts and contracts to move staked TAO from one hotkey to another,
     * which effectively calls `move_stake` on the subtensor pallet with specified origin and destination
     * hotkeys as parameters being the hashed address mappings of H160 sender address to Substrate ss58
     * address as implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param origin_hotkey The origin hotkey public key (32 bytes).
     * @param destination_hotkey The destination hotkey public key (32 bytes).
     * @param origin_netuid The subnet to move stake from (uint256).
     * @param destination_netuid The subnet to move stake to (uint256).
     * @param amount The amount to move in rao.
     *
     * Requirements:
     * - `origin_hotkey` and `destination_hotkey` must be valid hotkeys registered on the network, ensuring
     * that the stake is correctly attributed.
     */
    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external;

    /**
     * @dev Transfer a subtensor stake `amount` associated with the transaction signer to a different coldkey
     * `destination_coldkey`.
     *
     * This function allows external accounts and contracts to transfer staked TAO to another coldkey,
     * which effectively calls `transfer_stake` on the subtensor pallet with specified destination
     * coldkey as a parameter being the hashed address mapping of H160 sender address to Substrate ss58
     * address as implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param destination_coldkey The destination coldkey public key (32 bytes).
     * @param hotkey The hotkey public key (32 bytes).
     * @param origin_netuid The subnet to move stake from (uint256).
     * @param destination_netuid The subnet to move stake to (uint256).
     * @param amount The amount to move in rao.
     *
     * Requirements:
     * - `origin_hotkey` and `destination_hotkey` must be valid hotkeys registered on the network, ensuring
     * that the stake is correctly attributed.
     */
    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external;

    /**
     * @dev Returns the amount of RAO staked by the coldkey.
     *
     * This function allows external accounts and contracts to query the amount of RAO staked by the coldkey
     * which effectively calls `get_total_coldkey_stake` on the subtensor pallet with
     * specified coldkey as a parameter.
     *
     * @param coldkey The coldkey public key (32 bytes).
     * @return The amount of RAO staked by the coldkey.
     */
    function getTotalColdkeyStake(
        bytes32 coldkey
    ) external view returns (uint256);

    /**
     * @dev Returns the total amount of stake under a hotkey (delegative or otherwise)
     *
     * This function allows external accounts and contracts to query the total amount of RAO staked under a hotkey
     * which effectively calls `get_total_hotkey_stake` on the subtensor pallet with
     * specified hotkey as a parameter.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @return The total amount of RAO staked under the hotkey.
     */
    function getTotalHotkeyStake(
        bytes32 hotkey
    ) external view returns (uint256);

    /**
     * @dev Returns the stake amount associated with the specified `hotkey` and `coldkey`.
     *
     * This function retrieves the current stake amount linked to a specific hotkey and coldkey pair.
     * It is a view function, meaning it does not modify the state of the contract and is free to call.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param coldkey The coldkey public key (32 bytes).
     * @param netuid The subnet the stake is on (uint256).
     * @return The current stake amount in uint256 format.
     */
    function getStake(
        bytes32 hotkey,
        bytes32 coldkey,
        uint256 netuid
    ) external view returns (uint256);

    /**
     * @dev Delegates staking to a proxy account.
     *
     * @param delegate The public key (32 bytes) of the delegate.
     */
    function addProxy(bytes32 delegate) external;

    /**
     * @dev Removes staking proxy account.
     *
     * @param delegate The public key (32 bytes) of the delegate.
     */
    function removeProxy(bytes32 delegate) external;

    /**
     * @dev Returns the validators that have staked alpha under a hotkey.
     *
     * This function retrieves the validators that have staked alpha under a specific hotkey.
     * It is a view function, meaning it does not modify the state of the contract and is free to call.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param netuid The subnet the stake is on (uint256).
     * @return An array of validators that have staked alpha under the hotkey.
     */
    function getAlphaStakedValidators(
        bytes32 hotkey,
        uint256 netuid
    ) external view returns (uint256[] memory);

    /**
     * @dev Returns the total amount of alpha staked under a hotkey.
     *
     * This function retrieves the total amount of alpha staked under a specific hotkey.
     * It is a view function, meaning it does not modify the state of the contract and is free to call.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param netuid The subnet the stake is on (uint256).
     * @return The total amount of alpha staked under the hotkey.
     */
    function getTotalAlphaStaked(
        bytes32 hotkey,
        uint256 netuid
    ) external view returns (uint256);

    /**
     * @dev Returns the minimum required stake for a nominator.
     *
     * This function retrieves the minimum required stake for a nominator.
     * It is a view function, meaning it does not modify the state of the contract and is free to call.
     *
     * @return The minimum required stake for a nominator.
     */
    function getNominatorMinRequiredStake() external view returns (uint256);

    /**
     * @dev Adds a subtensor stake `amount` associated with the `hotkey` within a price limit.
     *
     * This function allows external accounts and contracts to stake TAO into the subtensor pallet,
     * which effectively calls `add_stake_limit` on the subtensor pallet with specified hotkey as a parameter
     * and coldkey being the hashed address mapping of H160 sender address to Substrate ss58 address as
     * implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param amount The amount to stake in rao.
     * @param limit_price The price limit to stake at in rao. Number of rao per alpha.
     * @param allow_partial Whether to allow partial stake.
     * @param netuid The subnet to stake to (uint256).
     *
     * Requirements:
     * - `hotkey` must be a valid hotkey registered on the network, ensuring that the stake is
     *   correctly attributed.
     */
    function addStakeLimit(
        bytes32 hotkey,
        uint256 amount,
        uint256 limit_price,
        bool allow_partial,
        uint256 netuid
    ) external payable;

    /**
     * @dev Removes a subtensor stake `amount` from the specified `hotkey` within a price limit.
     *
     * This function allows external accounts and contracts to unstake TAO from the subtensor pallet,
     * which effectively calls `remove_stake_limit` on the subtensor pallet with specified hotkey as a parameter
     * and coldkey being the hashed address mapping of H160 sender address to Substrate ss58 address as
     * implemented in Frontier HashedAddressMapping:
     * https://github.com/polkadot-evm/frontier/blob/2e219e17a526125da003e64ef22ec037917083fa/frame/evm/src/lib.rs#L739
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param amount The amount to unstake in alpha.
     * @param limit_price The price limit to unstake at in rao. Number of rao per alpha.
     * @param allow_partial Whether to allow partial unstake.
     * @param netuid The subnet to stake to (uint256).
     *
     * Requirements:
     * - `hotkey` must be a valid hotkey registered on the network, ensuring that the stake is
     *   correctly attributed.
     * - The existing stake amount must be not lower than specified amount
     */
    function removeStakeLimit(
        bytes32 hotkey,
        uint256 amount,
        uint256 limit_price,
        bool allow_partial,
        uint256 netuid
    ) external;

    /**
     * @dev Removes all stake from a hotkey on a subnet with a price limit.
     *
     * This function allows external accounts and contracts to remove all stake from a specified hotkey
     * on a subnet, with an optional limit price for alpha token at which or better (higher) the staking
     * should execute. Without a limit price, it removes all the stake similar to `removeStake` function.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param netuid The subnet to remove stake from (uint256).
     */
    function removeStakeFull(bytes32 hotkey, uint256 netuid) external;

    /**
     * @dev Removes all stake from a hotkey on a subnet with a price limit.
     *
     * This function allows external accounts and contracts to remove all stake from a specified hotkey
     * on a subnet, with an optional limit price for alpha token at which or better (higher) the staking
     * should execute. Without a limit price, it removes all the stake similar to `removeStake` function.
     *
     * @param hotkey The hotkey public key (32 bytes).
     * @param netuid The subnet to remove stake from (uint256).
     * @param limitPrice The limit price for alpha token (uint256).
     */
    function removeStakeFullLimit(
        bytes32 hotkey,
        uint256 netuid,
        uint256 limitPrice
    ) external;
}


// File contracts/LiquidStakedV3.sol

// Fixed pragma version 0.8.24 for Bittensor EVM compatibility
// See: Bittensor EVM documentation - requires 0.8.24 or below to avoid precompile errors
// Using cancun as evm version to prevent InvalidCode(Opcode(94)) errors
pragma solidity 0.8.24;










/**
 * @title LiquidStakedV3
 * @notice Upgradeable version of LiquidStakedV2 using UUPS proxy pattern
 * @dev This contract is upgradeable and can be improved in future versions
 */
contract LiquidStakedV3 is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    error DeadlineExpired();
    error InvalidAmount();
    error InvalidMinAmount();
    error InsufficientBalance();
    error InvalidRecipient();
    error InvalidRate();
    error SlippageTooHigh();
    error TransferFailed();
    error CallFailed();
    error NoStake();
    error FeeExceedsMax();
    error TimelockActive();
    error NoPendingWithdrawal();
    error WithdrawalPending();
    error ChangePending();
    error InvalidAddress();
    error SameAddress();
    error ExceedsAvailable();
    error Unauthorized();

    // Changed from immutable to storage variables for upgradeability
    uint256 public NETUID;
    bytes32 public VALIDATOR_HOTKEY;

    IStaking public staking;
    IMetagraph public metagraph;

    uint256 public fee;
    address public treasuryEvm; // DEPRECATED in V3 - kept for storage layout compatibility, DO NOT USE
    bytes32 public treasuryBytes32; // Bytes32 address for LSA token minting

    uint256 public constant FEE_SCALED = 10000; // Basis points: 10000 = 100%, 100 = 1%, 1 = 0.01%

    // Named numeric constants to replace magic numbers
    // RAO - 9 decimals (alpha/tao smallest unit)
    uint256 public constant RAO = 1e9;
    // WAD - 18 decimals (wei / ERC20 standard)
    uint256 public constant WAD = 1e18;

    // Role for automated fee claiming
    bytes32 public constant FEE_CLAIMER_ROLE = keccak256("FEE_CLAIMER_ROLE");

    // Yield fee tracking
    uint256 public yieldFee; // Fee on yield in basis points (e.g., 100 = 10%)
    uint256 public lastRecordedAlphaBalance; // Last recorded total alpha balance
    uint256 public accumulatedYieldFees; // Total yield fees collected

    // Network fee for exchange rate stability buffer
    uint256 public networkFee; // Network fee in basis points (e.g., 6 = 0.06%)

    // TVL tracking
    uint256 public totalValueLockedInAlpha; // Total alpha staked (9 decimals)
    uint256 public totalValueLockedInTao; // Cached TVL in TAO (9 decimals)
    uint256 public tvlLastUpdated; // Timestamp of last TVL update

    // Emergency withdrawal timelock
    uint256 public constant EMERGENCY_TIMELOCK = 48 hours; // 48 hour timelock for emergency withdrawals
    uint256 public emergencyWithdrawInitiated; // Timestamp when emergency withdrawal was initiated
    uint256 public emergencyWithdrawAmount; // Amount requested for emergency withdrawal
    bool public emergencyWithdrawPending; // Whether an emergency withdrawal is pending

    // Emergency TAO withdrawal timelock
    uint256 public emergencyTaoWithdrawInitiated; // Timestamp when emergency TAO withdrawal was initiated
    uint256 public emergencyTaoWithdrawAmount; // Amount requested for emergency TAO withdrawal
    address public emergencyTaoWithdrawRecipient; // Recipient for emergency TAO withdrawal
    bool public emergencyTaoWithdrawPending; // Whether an emergency TAO withdrawal is pending

    // Community governance for emergency situations
    address public communityRepresentative; // Address that can cancel emergency withdrawals if owner is compromised

    // Community representative timelock
    uint256 public communityRepresentativeChangeInitiated; // Timestamp when community representative change was initiated
    address public pendingCommunityRepresentative; // New community representative waiting for timelock
    bool public communityRepresentativeChangePending; // Whether a community representative change is pending

    // User LSA amount tracking
    uint256 public totalUserLsaAmount; // Total LSA amount minted to users through depositAlpha (18 decimals)

    // Pending treasury fees (accumulated alpha fees to be transferred later)
    uint256 public pendingTreasuryAlphaFees; // Accumulated treasury alpha fees (9 decimals)

    // Pending yield fees (accumulated alpha yield fees to be transferred later)
    uint256 public pendingYieldFee; // Accumulated yield fees in alpha (9 decimals)

    IAlpha public alpha;
    bytes32 public contractSS58Pub;

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @dev Prevents initialization of the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable LiquidStakedV3 contract
     * @dev Replaces the constructor for upgradeable contracts
     * @param _name The name of the LSA token (e.g., "Liquid Staked Alpha")
     * @param _symbol The symbol of the LSA token (e.g., "LSA")
     * @param _netuid The Bittensor subnet ID where the validator operates (uint16)
     * @param _validatorHotkey The unique identifier of the validator within the subnet (bytes32)
     * @param _contractSS58Pub The SS58 public key of this contract (calculated off-chain)
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        uint16 _netuid,
        bytes32 _validatorHotkey,
        bytes32 _contractSS58Pub
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_CLAIMER_ROLE, msg.sender);

        staking = IStaking(ISTAKING_ADDRESS);
        alpha = IAlpha(IALPHA_ADDRESS);
        metagraph = IMetagraph(IMetagraph_ADDRESS);

        NETUID = _netuid;
        VALIDATOR_HOTKEY = _validatorHotkey;
        contractSS58Pub = _contractSS58Pub;

        fee = 0; // default: no fee
        yieldFee = 0; // default: no yield fee
        networkFee = 6; // default: 0.06% network fee buffer
        lastRecordedAlphaBalance = 0; // Initialize alpha balance tracking

        // Initialize TVL tracking
        totalValueLockedInAlpha = 0;
        totalValueLockedInTao = 0;
        tvlLastUpdated = block.timestamp;
    }

    /**
     * @dev Function that authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation contract
     * @custom:oz-upgrades Can only be called by the owner
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @notice Returns the current implementation version
     * @return Version string
     */
    function version() public pure virtual returns (string memory) {
        return "3.0.4";
    }

    // [EVENTS - Same as V2]
    event Staked(
        address indexed user,
        bytes32 indexed hotkey,
        uint256 taoAmount,
        uint256 alphaAmount,
        uint256 lsaAmount,
        uint256 exchangeRate,
        uint256 treasuryFee,
        uint256 timestamp
    );

    event TreasuryUpdated(
        bytes32 indexed oldTreasury,
        bytes32 indexed newTreasury,
        address indexed updatedBy
    );

    // event TreasuryEvmUpdated(
    //     address indexed oldTreasuryEvm,
    //     address indexed newTreasuryEvm,
    //     address indexed updatedBy
    // );

    event TreasuryBytes32Updated(
        bytes32 indexed oldTreasuryBytes32,
        bytes32 indexed newTreasuryBytes32,
        address indexed updatedBy
    );

    event ContractSS58PubUpdated(
        bytes32 indexed oldContractSS58Pub,
        bytes32 indexed newContractSS58Pub,
        address indexed updatedBy
    );

    event TreasuryFeeUpdated(
        uint256 oldFeeBPS,
        uint256 newFeeBPS,
        address indexed updatedBy
    );

    event YieldFeeUpdated(
        uint256 oldYieldFeeBPS,
        uint256 newYieldFeeBPS,
        address indexed updatedBy
    );

    event NetworkFeeUpdated(
        uint256 oldNetworkFeeBPS,
        uint256 newNetworkFeeBPS,
        address indexed updatedBy
    );

    event YieldCollected(
        uint256 yieldAmount,
        uint256 feeAmount,
        uint256 netYield,
        address indexed triggeredBy
    );

    event YieldMintedToLSA(
        uint256 yieldAmount,
        uint256 lsaMinted,
        uint256 totalSupplyAfter,
        address indexed triggeredBy
    );

    event YieldDistributed(
        uint256 totalYieldInAlpha,
        uint256 totalYieldInTao,
        uint256 treasuryYieldInAlpha,
        uint256 holderYieldInAlpha,
        uint256 totalSupplyBefore,
        uint256 totalSupplyAfter,
        uint256 exchangeRateBefore,
        uint256 exchangeRateAfter,
        uint256 timestamp,
        address indexed triggeredBy
    );

    event Redeemed(
        address indexed user,
        uint256 lsaAmountBurned,
        uint256 taoReceived,
        uint256 alphaRemoved,
        uint256 exchangeRate,
        uint256 treasuryFee,
        uint256 timestamp,
        uint256 totalStakedBefore,
        uint256 totalStakedAfter,
        uint256 pendingTreasuryAlphaFeesBefore,
        uint256 pendingTreasuryAlphaFeesAfter
    );

    event AlphaRedeemed(
        address indexed user,
        bytes32 indexed recipient,
        uint256 lsaAmountBurned,
        uint256 calculatedAlphaAmount,
        uint256 actualAlphaTransferred,
        uint256 treasuryAlphaFee,
        uint256 exchangeRate,
        uint256 timestamp,
        uint256 totalSupplyBefore,
        uint256 totalSupplyAfter
    );

    event TVLUpdated(
        uint256 totalAlphaStaked,
        uint256 totalTaoValue,
        uint256 totalLsaSupply,
        uint256 exchangeRate,
        uint256 alphaPrice,
        uint256 backingRatio,
        uint256 utilizationRate,
        uint256 timestamp,
        address indexed triggeredBy,
        string indexed updateReason
    );

    event EmergencyWithdrawalInitiated(
        address indexed owner,
        uint256 alphaAmount,
        uint256 availableAt,
        uint256 timestamp
    );

    event EmergencyWithdrawalCancelled(
        address indexed owner,
        uint256 alphaAmount,
        uint256 timestamp
    );

    event EmergencyWithdrawal(
        address indexed owner,
        uint256 alphaAmount,
        uint256 stakeBefore,
        uint256 stakeAfter,
        uint256 lsaSupply,
        uint256 timestamp
    );

    event EmergencyTaoWithdrawalInitiated(
        address indexed owner,
        address indexed recipient,
        uint256 taoAmount,
        uint256 availableAt,
        uint256 timestamp
    );

    event EmergencyTaoWithdrawalCancelled(
        address indexed owner,
        address indexed recipient,
        uint256 taoAmount,
        uint256 timestamp
    );

    event EmergencyTaoWithdrawal(
        address indexed owner,
        address indexed recipient,
        uint256 taoAmount,
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 timestamp
    );

    event CommunityRepresentativeUpdated(
        address indexed oldRepresentative,
        address indexed newRepresentative,
        address indexed updatedBy
    );

    event CommunityRepresentativeChangeInitiated(
        address indexed owner,
        address indexed currentRepresentative,
        address indexed newRepresentative,
        uint256 availableAt,
        uint256 timestamp
    );

    event CommunityRepresentativeChangeCancelled(
        address indexed owner,
        address indexed cancelledRepresentative,
        uint256 timestamp
    );

    event FeesClaimed(
        bytes32 indexed treasury,
        uint256 treasuryAlphaAmount,
        uint256 yieldAlphaAmount,
        uint256 totalAlphaAmount,
        address indexed claimedBy,
        uint256 timestamp
    );

    // Note: Role management events are provided by AccessControlUpgradeable:
    // - RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)
    // - RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)
    // Use these events to track FEE_CLAIMER_ROLE changes

    /**
     * @notice Stakes TAO with slippage protection by specifying minimum LSA tokens expected
     * @dev Collects yield before staking, applies treasury fee in alpha, refunds leftover wei
     * @param minLsaAmount Minimum LSA tokens user expects to receive (slippage protection)
     * @param deadline Unix timestamp after which the transaction will revert
     *
     * Requirements:
     * - msg.value must be greater than 0
     * - minLsaAmount must be greater than 0
     * - deadline must be in the future
     * - Actual LSA received must be >= minLsaAmount
     * - Contract must not be paused
     *
     * Emits a {Staked} event.
     */
    function stakeWithSlippage(
        uint256 minLsaAmount,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (minLsaAmount == 0) revert InvalidMinAmount();

        _calculateAndCollectYield();

        uint256 amountIn9Decimals = msg.value / RAO;
        if (amountIn9Decimals == 0) revert InvalidAmount();

        uint256 leftoverWei = msg.value % RAO;
        if (leftoverWei > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: leftoverWei}("");
            if (!refundSuccess) revert TransferFailed();
        }

        bytes32 hotkey = getValidatorHotkey();
        uint256 beforeStake = _getTotalContractStake();
        uint256 rate = _exchangeRate();

        bytes memory data = abi.encodeWithSelector(
            IStaking.addStake.selector,
            hotkey,
            amountIn9Decimals,
            NETUID
        );
        (bool success, ) = address(staking).call{gas: gasleft()}(data);
        if (!success) revert CallFailed();

        uint256 afterStake = _getTotalContractStake();
        uint256 alphaStaked = afterStake - beforeStake;
        if (alphaStaked == 0) revert NoStake();

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (alphaStaked * fee) / FEE_SCALED;
            // Accumulate fee in state for later transfer
            pendingTreasuryAlphaFees += treasuryAlphaFee;
        }

        // Calculate LSA to mint based on net alpha (after treasury fee)
        uint256 netAlphaForUser = alphaStaked - treasuryAlphaFee;
        uint256 alphaIn18Decimals = netAlphaForUser * RAO;
        if (rate == 0) revert InvalidRate();
        uint256 userLsaAmount = (alphaIn18Decimals * WAD) / rate;
        if (userLsaAmount == 0) revert InvalidAmount();

        if (userLsaAmount < minLsaAmount) revert SlippageTooHigh();

        _mint(msg.sender, userLsaAmount);

        totalUserLsaAmount += userLsaAmount;
        _updateRecordedAlphaBalance();
        _updateTVL("stake");

        emit Staked(
            msg.sender,
            hotkey,
            amountIn9Decimals,
            alphaStaked,
            userLsaAmount,
            rate,
            treasuryAlphaFee,
            block.timestamp
        );
    }

    /**
     * @notice Returns the validator hotkey this contract stakes with
     * @return bytes32 The validator's hotkey identifier
     */
    function getValidatorHotkey() public view returns (bytes32) {
        return VALIDATOR_HOTKEY;
    }

    /**
     * @notice Returns the current LSA to alpha exchange rate
     * @return uint256 Exchange rate with 18 decimals precision (WAD)
     */
    function exchangeRate() external view returns (uint256) {
        return _exchangeRate();
    }

    /**
     * @dev Internal function to calculate the LSA to alpha exchange rate
     * @dev Accounts for pending treasury fees and projected yield fees
     * @return uint256 Exchange rate with 18 decimals precision, returns 1e18 if no supply or stake
     */
    function _exchangeRate() internal view returns (uint256) {
        uint256 totalLSA = totalSupply();
        uint256 totalStaked = _getTotalContractStake();

        if (totalLSA == 0) return 1e18;
        if (totalStaked == 0) return 1e18;

        // Calculate pending yield that hasn't been collected yet
        uint256 projectedPendingYieldFee = pendingYieldFee;

        if (
            yieldFee > 0 &&
            lastRecordedAlphaBalance > 0 &&
            totalStaked > lastRecordedAlphaBalance
        ) {
            uint256 unaccountedYield = totalStaked - lastRecordedAlphaBalance;
            uint256 additionalYieldFee = (unaccountedYield * yieldFee) /
                FEE_SCALED;
            projectedPendingYieldFee += additionalYieldFee;
        }

        uint256 totalPendingFees = pendingTreasuryAlphaFees +
            projectedPendingYieldFee;
        uint256 netStaked = totalStaked > totalPendingFees
            ? totalStaked - totalPendingFees
            : 0;

        return (netStaked * 1e27) / totalLSA;
    }

    /**
     * @dev Internal function to get the total alpha staked by this contract with the validator
     * @return uint256 Total alpha staked in 9 decimals (rao)
     */
    function _getTotalContractStake() internal view returns (uint256) {
        bytes32 hotkey = getValidatorHotkey();
        bytes memory data = abi.encodeWithSelector(
            IStaking.getStake.selector,
            hotkey,
            contractSS58Pub,
            NETUID
        );

        (bool success, bytes memory result) = address(staking).staticcall(data);
        if (!success) revert CallFailed();

        return abi.decode(result, (uint256));
    }

    /**
     * @dev Updates the last recorded alpha balance for yield calculation
     */
    function _updateRecordedAlphaBalance() internal {
        lastRecordedAlphaBalance = _getTotalContractStake();
    }

    /**
     * @dev Internal function to update Total Value Locked tracking
     * @param reason Description of why TVL is being updated (for event logging)
     */
    function _updateTVL(string memory reason) internal {
        uint256 currentAlphaStaked = _getTotalContractStake();
        totalValueLockedInAlpha = currentAlphaStaked;

        if (currentAlphaStaked > 0) {
            totalValueLockedInTao = _calculateTaoFromAlpha(currentAlphaStaked);
        } else {
            totalValueLockedInTao = 0;
        }

        tvlLastUpdated = block.timestamp;

        uint256 currentExchangeRate = _exchangeRate();
        uint256 lsaSupply = totalSupply();

        emit TVLUpdated(
            totalValueLockedInAlpha,
            totalValueLockedInTao,
            lsaSupply,
            currentExchangeRate,
            0,
            0,
            0,
            tvlLastUpdated,
            msg.sender,
            reason
        );
    }

    /**
     * @notice Deposits alpha tokens with slippage and deadline protection
     * @dev User must have pre-staked alpha with the validator that can be transferred to this contract
     * @dev Applies treasury fee in alpha and accumulates in pendingTreasuryAlphaFees
     * @param alphaAmount The amount of alpha to deposit (9 decimals)
     * @param minLsaAmount Minimum LSA tokens user expects to receive (slippage protection)
     * @param deadline Unix timestamp after which the transaction will revert
     * @return uint256 The amount of LSA tokens minted to the user
     *
     * Requirements:
     * - alphaAmount must be greater than 0
     * - minLsaAmount must be greater than 0
     * - deadline must be in the future
     * - Actual LSA received must be >= minLsaAmount
     * - Contract must not be paused
     *
     * Emits a {Staked} event.
     */
    function depositAlphaWithSlippage(
        uint256 alphaAmount,
        uint256 minLsaAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (alphaAmount == 0) revert InvalidAmount();
        if (minLsaAmount == 0) revert InvalidMinAmount();

        _calculateAndCollectYield();

        bytes32 hotkey = getValidatorHotkey();
        uint256 beforeStake = _getTotalContractStake();
        uint256 rate = _exchangeRate();

        bytes memory data = abi.encodeWithSelector(
            IStaking.transferStake.selector,
            contractSS58Pub,
            hotkey,
            NETUID,
            NETUID,
            alphaAmount
        );
        (bool success, ) = address(staking).delegatecall{gas: gasleft()}(data);
        if (!success) revert TransferFailed();

        uint256 afterStake = _getTotalContractStake();
        uint256 actualAlphaReceived = afterStake - beforeStake;
        if (actualAlphaReceived == 0) revert NoStake();

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (actualAlphaReceived * fee) / FEE_SCALED;
            // Accumulate fee in state for later transfer
            pendingTreasuryAlphaFees += treasuryAlphaFee;
        }

        // Calculate LSA to mint based on net alpha (after treasury fee)
        uint256 netAlphaForUser = actualAlphaReceived - treasuryAlphaFee;
        uint256 alphaIn18Decimals = netAlphaForUser * RAO;
        if (rate == 0) revert InvalidRate();

        uint256 userLsaAmount = (alphaIn18Decimals * WAD) / rate;
        if (userLsaAmount == 0) revert InvalidAmount();
        if (userLsaAmount < minLsaAmount) revert SlippageTooHigh();

        _mint(msg.sender, userLsaAmount);

        totalUserLsaAmount += userLsaAmount;
        _updateRecordedAlphaBalance();
        _updateTVL("alpha_deposit");

        emit Staked(
            msg.sender,
            hotkey,
            0,
            actualAlphaReceived,
            userLsaAmount,
            rate,
            pendingTreasuryAlphaFees,
            block.timestamp
        );

        return userLsaAmount;
    }

    /**
     * @notice Redeems LSA tokens for TAO with slippage protection
     * @dev Burns LSA, calculates fees in alpha, removes stake and transfers TAO to user
     * @param lsaAmount Amount of LSA tokens to burn
     * @param minTaoAmount Minimum TAO amount user expects to receive (slippage protection)
     * @param deadline Unix timestamp after which the transaction will revert
     *
     * Requirements:
     * - lsaAmount must be greater than 0
     * - minTaoAmount must be greater than 0
     * - deadline must be in the future
     * - User must have sufficient LSA balance
     * - Actual TAO received must be >= minTaoAmount
     * - Contract must not be paused
     *
     * Emits a {Redeemed} event.
     */
    function redeemWithSlippage(
        uint256 lsaAmount,
        uint256 minTaoAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (lsaAmount == 0) revert InvalidAmount();
        if (minTaoAmount == 0) revert InvalidMinAmount();
        if (balanceOf(msg.sender) < lsaAmount) revert InsufficientBalance();

        _calculateAndCollectYield();

        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        uint256 alphaToRemove;
        uint256 actualAlpha;
        uint256 taoAmount;

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;

        {
            // Convert LSA to gross alpha first
            uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

            if (fee > 0) {
                treasuryAlphaFee = (grossAlpha * fee) / FEE_SCALED;
                // Accumulate fee in state for later transfer
                pendingTreasuryAlphaFees += treasuryAlphaFee;
            }

            // Apply network fee buffer to alpha as well
            uint256 networkFeeAlpha = 0;
            if (networkFee > 0) {
                networkFeeAlpha = (grossAlpha * networkFee) / FEE_SCALED;
            }

            // Net alpha to remove after fees
            alphaToRemove = grossAlpha - treasuryAlphaFee - networkFeeAlpha;
        }

        _burn(msg.sender, lsaAmount);

        uint256 stakeBalance = _getTotalContractStake();
        uint256 taoBalance = address(this).balance;

        _removeStake(alphaToRemove);

        actualAlpha = stakeBalance - _getTotalContractStake();
        taoAmount = address(this).balance - taoBalance;

        if (taoAmount < minTaoAmount) revert SlippageTooHigh();

        (bool sent, ) = msg.sender.call{value: taoAmount}("");
        if (!sent) revert TransferFailed();

        totalUserLsaAmount -= lsaAmount;
        _updateRecordedAlphaBalance();
        _updateTVL("redeem");

        emit Redeemed(
            msg.sender,
            lsaAmount,
            taoAmount,
            actualAlpha,
            rate,
            treasuryAlphaFee,
            block.timestamp,
            stakeBalance,
            _getTotalContractStake(),
            pendingTreasuryAlphaFees - treasuryAlphaFee,
            pendingTreasuryAlphaFees
        );
    }

    /**
     * @notice Redeems LSA tokens for Alpha stake directly to a recipient's SS58 address
     * @dev Burns LSA, calculates fees in alpha, transfers stake directly to recipient's coldkey
     * @param lsaAmount Amount of LSA tokens to burn
     * @param to Recipient's SS58 address (as bytes32)
     * @param minAlphaAmount Minimum alpha amount user expects to be transferred (slippage protection)
     * @param deadline Unix timestamp after which the transaction will revert
     *
     * Requirements:
     * - lsaAmount must be greater than 0
     * - to must not be zero address
     * - minAlphaAmount must be greater than 0
     * - deadline must be in the future
     * - User must have sufficient LSA balance
     * - Actual alpha transferred must be >= minAlphaAmount
     * - Contract must not be paused
     *
     * Emits {AlphaRedeemed} and {Redeemed} events.
     */
    function redeemAsAlphaWithSlippage(
        uint256 lsaAmount,
        bytes32 to,
        uint256 minAlphaAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (lsaAmount == 0) revert InvalidAmount();
        if (minAlphaAmount == 0) revert InvalidMinAmount();
        if (balanceOf(msg.sender) < lsaAmount) revert InsufficientBalance();
        if (to == bytes32(0)) revert InvalidRecipient();

        _calculateAndCollectYield();
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Convert LSA to gross alpha first
        uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

        uint256 pendeingTreasuryAlphaFeesBefore = pendingTreasuryAlphaFees;

        uint256 totalSupplyBefore = totalSupply();

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (grossAlpha * fee) / FEE_SCALED;
            // Accumulate fee in state for later transfer
            pendingTreasuryAlphaFees += treasuryAlphaFee;
        }

        // Net alpha to transfer after fee
        uint256 alphaAmount = grossAlpha - treasuryAlphaFee;
        if (alphaAmount == 0) revert InvalidAmount();

        _burn(msg.sender, lsaAmount);

        uint256 beforeStake = _getTotalContractStake();
        _transferStake(alphaAmount, to);

        uint256 actualAlpha = beforeStake - _getTotalContractStake();

        if (actualAlpha == 0) revert TransferFailed();
        if (actualAlpha < minAlphaAmount) revert SlippageTooHigh();
        totalUserLsaAmount -= lsaAmount;
        _updateRecordedAlphaBalance();
        _updateTVL("alpha_redeem");

        emit AlphaRedeemed(
            msg.sender,
            to,
            lsaAmount,
            alphaAmount,
            actualAlpha,
            treasuryAlphaFee,
            rate,
            block.timestamp,
            totalSupplyBefore,
            totalSupply()
        );

        emit Redeemed(
            msg.sender,
            lsaAmount,
            0,
            actualAlpha,
            rate,
            treasuryAlphaFee,
            block.timestamp,
            beforeStake,
            _getTotalContractStake(),
            pendeingTreasuryAlphaFeesBefore,
            pendingTreasuryAlphaFees
        );
    }

    // // Governance functions
    // /**
    //  * @notice Sets the EVM treasury address (currently unused in V3)
    //  * @dev Only callable by contract owner when not paused
    //  * @param _treasuryEvm The new treasury EVM address
    //  *
    //  * Requirements:
    //  * - _treasuryEvm must not be zero address
    //  * - Caller must be owner
    //  * - Contract must not be paused
    //  *
    //  * Emits a {TreasuryEvmUpdated} event.
    //  */
    // function setTreasuryEvm(
    //     address _treasuryEvm
    // ) external onlyOwner whenNotPaused {
    //     if (_treasuryEvm == address(0)) revert InvalidAddress();
    //     address oldTreasuryEvm = treasuryEvm;
    //     treasuryEvm = _treasuryEvm;
    //     emit TreasuryEvmUpdated(oldTreasuryEvm, _treasuryEvm, msg.sender);
    // }

    /**
     * @notice Sets the treasury bytes32 address for receiving alpha fees
     * @dev Only callable by contract owner when not paused
     * @param _treasuryBytes32 The new treasury bytes32 address (SS58 format)
     *
     * Requirements:
     * - _treasuryBytes32 must not be zero
     * - Caller must be owner
     * - Contract must not be paused
     *
     * Emits a {TreasuryBytes32Updated} event.
     */
    function setTreasuryBytes32(
        bytes32 _treasuryBytes32
    ) external onlyOwner whenNotPaused {
        if (_treasuryBytes32 == bytes32(0)) revert InvalidAddress();
        bytes32 oldTreasuryBytes32 = treasuryBytes32;
        treasuryBytes32 = _treasuryBytes32;
        emit TreasuryBytes32Updated(
            oldTreasuryBytes32,
            _treasuryBytes32,
            msg.sender
        );
    }

    /**
     * @notice Sets the treasury fee percentage for stake/redeem operations
     * @dev Only callable by contract owner when not paused. Max fee is 20% (2000 basis points)
     * @param _fee The new fee in basis points (e.g., 100 = 1%, 2000 = 20%)
     *
     * Requirements:
     * - _fee must not exceed 2000 (20%)
     * - Caller must be owner
     * - Contract must not be paused
     *
     * Emits a {TreasuryFeeUpdated} event.
     */
    function setTreasuryFee(uint256 _fee) external onlyOwner whenNotPaused {
        if (_fee > 2000) revert FeeExceedsMax();
        uint256 oldFee = fee;
        fee = _fee;
        emit TreasuryFeeUpdated(oldFee, _fee, msg.sender);
    }

    /**
     * @notice Sets the yield fee percentage collected from generated yield
     * @dev Only callable by contract owner when not paused. Max fee is 20% (2000 basis points)
     * @dev Collects any pending yield before updating the fee
     * @param _yieldFee The new yield fee in basis points (e.g., 100 = 1%, 2000 = 20%)
     *
     * Requirements:
     * - _yieldFee must not exceed 2000 (20%)
     * - Caller must be owner
     * - Contract must not be paused
     *
     * Emits a {YieldFeeUpdated} event.
     */
    function setYieldFee(uint256 _yieldFee) external onlyOwner whenNotPaused {
        if (_yieldFee > 2000) revert FeeExceedsMax();
        _calculateAndCollectYield();
        uint256 oldYieldFee = yieldFee;
        yieldFee = _yieldFee;
        emit YieldFeeUpdated(oldYieldFee, _yieldFee, msg.sender);
    }

    /**
     * @notice Sets the network fee buffer percentage for redemptions
     * @dev Only callable by contract owner when not paused. Max fee is 1% (100 basis points)
     * @param _networkFee The new network fee in basis points (e.g., 6 = 0.06%, 100 = 1%)
     *
     * Requirements:
     * - _networkFee must not exceed 100 (1%)
     * - Caller must be owner
     * - Contract must not be paused
     *
     * Emits a {NetworkFeeUpdated} event.
     */
    function setNetworkFee(
        uint256 _networkFee
    ) external onlyOwner whenNotPaused {
        if (_networkFee > 100) revert FeeExceedsMax();
        uint256 oldNetworkFee = networkFee;
        networkFee = _networkFee;
        emit NetworkFeeUpdated(oldNetworkFee, _networkFee, msg.sender);
    }

    /**
     * @notice Sets the SS58 public key for this contract
     * @dev Calculate the SS58 key off-chain using blake2b hash of "evm:" + address
     * @param _contractSS58Pub The SS58 public key (bytes32)
     *
     * Requirements:
     * - _contractSS58Pub must not be zero
     * - Caller must be owner
     *
     * Emits a {ContractSS58PubUpdated} event.
     */
    function setContractSS58Pub(bytes32 _contractSS58Pub) external onlyOwner {
        if (_contractSS58Pub == bytes32(0)) revert InvalidAddress();
        bytes32 oldContractSS58Pub = contractSS58Pub;
        contractSS58Pub = _contractSS58Pub;
        emit ContractSS58PubUpdated(
            oldContractSS58Pub,
            _contractSS58Pub,
            msg.sender
        );
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by contract owner. Prevents stake/redeem operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by contract owner. Resumes stake/redeem operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Returns the FEE_CLAIMER_ROLE constant for role management
     * @dev Use this with AccessControl's grantRole/revokeRole/hasRole functions
     * @return bytes32 The role identifier for fee claimers
     *
     * Example usage:
     *   bytes32 role = getFeeClaimerRole();
     *   grantRole(role, account);  // Requires DEFAULT_ADMIN_ROLE
     */
    function getFeeClaimerRole() external pure returns (bytes32) {
        return FEE_CLAIMER_ROLE;
    }

    /**
     * @dev Modifier to restrict functions to owner or community representative
     */
    modifier onlyOwnerOrCommunity() {
        if (msg.sender != owner() && msg.sender != communityRepresentative)
            revert Unauthorized();
        _;
    }

    // Community representative management (with all timelock functions)
    /**
     * @notice Initiates a change to the community representative address with timelock
     * @dev Only callable by contract owner. Requires 48 hour timelock before execution
     * @param _newCommunityRepresentative The address of the new community representative
     *
     * Requirements:
     * - No pending community representative change
     * - _newCommunityRepresentative must not be zero address
     * - _newCommunityRepresentative must not be the owner
     * - _newCommunityRepresentative must not be current representative
     * - Caller must be owner
     *
     * Emits a {CommunityRepresentativeChangeInitiated} event.
     */
    function initiateCommunityRepresentativeChange(
        address _newCommunityRepresentative
    ) external onlyOwner {
        if (communityRepresentativeChangePending) revert ChangePending();
        if (_newCommunityRepresentative == address(0)) revert InvalidAddress();
        if (_newCommunityRepresentative == owner()) revert SameAddress();
        if (_newCommunityRepresentative == communityRepresentative)
            revert SameAddress();

        communityRepresentativeChangePending = true;
        communityRepresentativeChangeInitiated = block.timestamp;
        pendingCommunityRepresentative = _newCommunityRepresentative;

        uint256 availableAt = block.timestamp + EMERGENCY_TIMELOCK;
        emit CommunityRepresentativeChangeInitiated(
            msg.sender,
            communityRepresentative,
            _newCommunityRepresentative,
            availableAt,
            block.timestamp
        );
    }

    /**
     * @notice Cancels a pending community representative change
     * @dev Only callable by contract owner. Can be used to abort a pending change before timelock expires
     *
     * Requirements:
     * - A community representative change must be pending
     * - Caller must be owner
     *
     * Emits a {CommunityRepresentativeChangeCancelled} event.
     */
    function cancelCommunityRepresentativeChange() external onlyOwner {
        if (!communityRepresentativeChangePending) revert NoPendingWithdrawal();
        address cancelledRepresentative = pendingCommunityRepresentative;
        communityRepresentativeChangePending = false;
        communityRepresentativeChangeInitiated = 0;
        pendingCommunityRepresentative = address(0);
        emit CommunityRepresentativeChangeCancelled(
            msg.sender,
            cancelledRepresentative,
            block.timestamp
        );
    }

    /**
     * @notice Executes a pending community representative change after timelock expires
     * @dev Only callable by contract owner after 48 hour timelock period
     *
     * Requirements:
     * - A community representative change must be pending
     * - 48 hour timelock period must have passed
     * - Caller must be owner
     *
     * Emits a {CommunityRepresentativeUpdated} event.
     */
    function executeCommunityRepresentativeChange() external onlyOwner {
        if (!communityRepresentativeChangePending) revert NoPendingWithdrawal();
        if (
            block.timestamp <
            communityRepresentativeChangeInitiated + EMERGENCY_TIMELOCK
        ) revert TimelockActive();

        address oldRepresentative = communityRepresentative;
        address newRepresentative = pendingCommunityRepresentative;

        communityRepresentativeChangePending = false;
        communityRepresentativeChangeInitiated = 0;
        pendingCommunityRepresentative = address(0);

        communityRepresentative = newRepresentative;

        emit CommunityRepresentativeUpdated(
            oldRepresentative,
            newRepresentative,
            msg.sender
        );
    }

    // Emergency withdrawal functions (Alpha)
    /**
     * @notice Initiates an emergency withdrawal of alpha stake with 48 hour timelock
     * @dev Only callable by contract owner when contract is paused. If amount is 0, withdraws all staked alpha
     * @param amount Amount of alpha to withdraw (9 decimals). Use 0 to withdraw all staked alpha
     *
     * Requirements:
     * - Contract must be paused
     * - No pending emergency alpha withdrawal
     * - Total staked alpha must be greater than 0
     * - amount must not exceed total staked alpha
     * - Caller must be owner
     *
     * Emits an {EmergencyWithdrawalInitiated} event.
     */
    function initiateEmergencyWithdrawAlpha(
        uint256 amount
    ) external onlyOwner whenPaused {
        if (emergencyWithdrawPending) revert WithdrawalPending();
        uint256 totalStaked = _getTotalContractStake();
        if (totalStaked == 0) revert NoStake();

        uint256 withdrawAmount = (amount == 0) ? totalStaked : amount;
        if (withdrawAmount > totalStaked) revert ExceedsAvailable();

        emergencyWithdrawPending = true;
        emergencyWithdrawInitiated = block.timestamp;
        emergencyWithdrawAmount = withdrawAmount;

        uint256 availableAt = block.timestamp + EMERGENCY_TIMELOCK;
        emit EmergencyWithdrawalInitiated(
            msg.sender,
            withdrawAmount,
            availableAt,
            block.timestamp
        );
    }

    /**
     * @notice Cancels a pending emergency alpha withdrawal
     * @dev Callable by contract owner or community representative to abort emergency withdrawal
     *
     * Requirements:
     * - An emergency alpha withdrawal must be pending
     * - Caller must be owner or community representative
     *
     * Emits an {EmergencyWithdrawalCancelled} event.
     */
    function cancelEmergencyWithdrawAlpha() external onlyOwnerOrCommunity {
        if (!emergencyWithdrawPending) revert NoPendingWithdrawal();
        uint256 cancelledAmount = emergencyWithdrawAmount;
        emergencyWithdrawPending = false;
        emergencyWithdrawInitiated = 0;
        emergencyWithdrawAmount = 0;
        emit EmergencyWithdrawalCancelled(
            msg.sender,
            cancelledAmount,
            block.timestamp
        );
    }

    /**
     * @notice Executes a pending emergency alpha withdrawal after 48 hour timelock
     * @dev Only callable by contract owner when paused, after timelock expires. Transfers stake to recipient
     * @param recipient The SS58 address (bytes32) to receive the alpha stake
     *
     * Requirements:
     * - Contract must be paused
     * - An emergency alpha withdrawal must be pending
     * - 48 hour timelock period must have passed
     * - Total staked alpha must be greater than 0
     * - recipient must not be zero
     * - Caller must be owner
     *
     * Emits an {EmergencyWithdrawal} event.
     */
    function executeEmergencyWithdrawAlpha(
        bytes32 recipient
    ) external onlyOwner whenPaused {
        if (!emergencyWithdrawPending) revert NoPendingWithdrawal();
        if (recipient == bytes32(0)) revert InvalidRecipient();
        require(
            block.timestamp >= emergencyWithdrawInitiated + EMERGENCY_TIMELOCK,
            "Timelock period not yet passed"
        );

        uint256 requestedAmount = emergencyWithdrawAmount;
        uint256 totalStaked = _getTotalContractStake();
        if (totalStaked == 0) revert NoStake();

        uint256 actualWithdrawAmount = (requestedAmount <= totalStaked)
            ? requestedAmount
            : totalStaked;
        if (actualWithdrawAmount == 0) revert InvalidAmount();

        emergencyWithdrawPending = false;
        emergencyWithdrawInitiated = 0;
        emergencyWithdrawAmount = 0;

        uint256 lsaSupplyBefore = totalSupply();
        uint256 stakeBefore = totalStaked;

        _transferStake(actualWithdrawAmount, recipient);
        _updateRecordedAlphaBalance();
        _updateTVL("emergency_withdrawal");

        emit EmergencyWithdrawal(
            msg.sender,
            actualWithdrawAmount,
            stakeBefore,
            _getTotalContractStake(),
            lsaSupplyBefore,
            block.timestamp
        );
    }

    // Emergency withdrawal functions (TAO)
    /**
     * @notice Initiates an emergency withdrawal of TAO from contract balance with 48 hour timelock
     * @dev Only callable by contract owner when paused. If amount is 0, withdraws all TAO balance
     * @param recipient Address to receive the TAO
     * @param amount Amount of TAO to withdraw (in wei). Use 0 to withdraw entire balance
     *
     * Requirements:
     * - Contract must be paused
     * - No pending emergency TAO withdrawal
     * - recipient must not be zero address
     * - Contract TAO balance must be greater than 0
     * - amount must not exceed contract TAO balance
     * - Caller must be owner
     *
     * Emits an {EmergencyTaoWithdrawalInitiated} event.
     */
    function initiateEmergencyWithdrawTao(
        address payable recipient,
        uint256 amount
    ) external onlyOwner whenPaused {
        if (emergencyTaoWithdrawPending) revert WithdrawalPending();
        if (recipient == address(0)) revert InvalidRecipient();

        uint256 contractTaoBalance = address(this).balance;
        if (contractTaoBalance == 0) revert NoStake();

        uint256 withdrawAmount = (amount == 0) ? contractTaoBalance : amount;
        if (withdrawAmount > contractTaoBalance) revert ExceedsAvailable();

        emergencyTaoWithdrawPending = true;
        emergencyTaoWithdrawInitiated = block.timestamp;
        emergencyTaoWithdrawAmount = withdrawAmount;
        emergencyTaoWithdrawRecipient = recipient;

        uint256 availableAt = block.timestamp + EMERGENCY_TIMELOCK;
        emit EmergencyTaoWithdrawalInitiated(
            msg.sender,
            recipient,
            withdrawAmount,
            availableAt,
            block.timestamp
        );
    }

    /**
     * @notice Cancels a pending emergency TAO withdrawal
     * @dev Callable by contract owner or community representative to abort emergency TAO withdrawal
     *
     * Requirements:
     * - An emergency TAO withdrawal must be pending
     * - Caller must be owner or community representative
     *
     * Emits an {EmergencyTaoWithdrawalCancelled} event.
     */
    function cancelEmergencyWithdrawTao() external onlyOwnerOrCommunity {
        if (!emergencyTaoWithdrawPending) revert NoPendingWithdrawal();
        uint256 cancelledAmount = emergencyTaoWithdrawAmount;
        address cancelledRecipient = emergencyTaoWithdrawRecipient;

        emergencyTaoWithdrawPending = false;
        emergencyTaoWithdrawInitiated = 0;
        emergencyTaoWithdrawAmount = 0;
        emergencyTaoWithdrawRecipient = address(0);

        emit EmergencyTaoWithdrawalCancelled(
            msg.sender,
            cancelledRecipient,
            cancelledAmount,
            block.timestamp
        );
    }

    /**
     * @notice Executes a pending emergency TAO withdrawal after 48 hour timelock
     * @dev Only callable by contract owner when paused, after timelock expires. Sends TAO to recipient
     *
     * Requirements:
     * - Contract must be paused
     * - An emergency TAO withdrawal must be pending
     * - 48 hour timelock period must have passed
     * - Contract TAO balance must be greater than 0
     * - Caller must be owner
     *
     * Emits an {EmergencyTaoWithdrawal} event.
     */
    function executeEmergencyWithdrawTao() external onlyOwner whenPaused {
        if (!emergencyTaoWithdrawPending) revert NoPendingWithdrawal();
        require(
            block.timestamp >=
                emergencyTaoWithdrawInitiated + EMERGENCY_TIMELOCK,
            "Timelock period not yet passed"
        );

        uint256 requestedAmount = emergencyTaoWithdrawAmount;
        address payable recipient = payable(emergencyTaoWithdrawRecipient);
        uint256 contractTaoBalance = address(this).balance;

        if (contractTaoBalance == 0) revert NoStake();

        uint256 actualWithdrawAmount = (requestedAmount <= contractTaoBalance)
            ? requestedAmount
            : contractTaoBalance;
        if (actualWithdrawAmount == 0) revert InvalidAmount();

        emergencyTaoWithdrawPending = false;
        emergencyTaoWithdrawInitiated = 0;
        emergencyTaoWithdrawAmount = 0;
        emergencyTaoWithdrawRecipient = address(0);

        uint256 balanceBefore = contractTaoBalance;

        (bool success, ) = recipient.call{value: actualWithdrawAmount}("");
        if (!success) revert TransferFailed();

        emit EmergencyTaoWithdrawal(
            msg.sender,
            recipient,
            actualWithdrawAmount,
            balanceBefore,
            address(this).balance,
            block.timestamp
        );
    }

    /**
     * @notice Claims accumulated treasury and yield alpha fees to treasury address
     * @dev Can only be called by owner. Must be done in separate transaction from staking
     * @dev Resets both pendingTreasuryAlphaFees and pendingYieldFee to zero before transfer for reentrancy protection
     *
     * Requirements:
     * - At least one of pendingTreasuryAlphaFees or pendingYieldFee must be greater than 0
     * - treasuryBytes32 must be set
     * - Caller must be owner
     * - Contract must not be paused
     *
     * Emits a {FeesClaimed} event.
     */
    function claimFee()
        external
        onlyRole(FEE_CLAIMER_ROLE)
        nonReentrant
        whenNotPaused
    {
         _calculateAndCollectYield();
         
        uint256 treasuryAmount = pendingTreasuryAlphaFees;
        uint256 yieldAmount = pendingYieldFee;
        uint256 totalAmount = treasuryAmount + yieldAmount;

        if (totalAmount == 0) revert InvalidAmount();
        if (treasuryBytes32 == bytes32(0)) revert InvalidAddress();

        // Reset pending fees before transfer (reentrancy protection)
        pendingTreasuryAlphaFees = 0;
        pendingYieldFee = 0;

        // Transfer accumulated fees to treasury
        _transferStake(totalAmount, treasuryBytes32);

        emit FeesClaimed(
            treasuryBytes32,
            treasuryAmount,
            yieldAmount,
            totalAmount,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @notice Returns pending treasury alpha fees
     * @return uint256 Pending treasury fees in alpha (9 decimals)
     */
    function getPendingTreasuryFees() external view returns (uint256) {
        return pendingTreasuryAlphaFees;
    }

    /**
     * @notice Returns pending yield alpha fees
     * @return uint256 Pending yield fees in alpha (9 decimals)
     */
    function getPendingYieldFees() external view returns (uint256) {
        return pendingYieldFee;
    }

    /**
     * @notice Returns total pending fees (treasury + yield)
     * @return uint256 Total pending fees in alpha (9 decimals)
     */
    function getTotalPendingFees() external view returns (uint256) {
        return pendingTreasuryAlphaFees + pendingYieldFee;
    }

    // View functions
    /**
     * @notice Returns the current treasury fee percentage
     * @return uint256 Treasury fee in basis points (e.g., 100 = 1%)
     */
    function getTreasuryFee() public view returns (uint256) {
        return fee;
    }

    /**
     * @notice Returns the current yield fee percentage
     * @return uint256 Yield fee in basis points (e.g., 100 = 1%)
     */
    function getYieldFee() public view returns (uint256) {
        return yieldFee;
    }

    /**
     * @notice Returns the current network fee buffer percentage
     * @return uint256 Network fee in basis points (e.g., 6 = 0.06%)
     */
    function getNetworkFee() public view returns (uint256) {
        return networkFee;
    }

    /**
     * @notice Returns the current community representative address
     * @return address Community representative who can cancel emergency withdrawals
     */
    function getCommunityRepresentative() public view returns (address) {
        return communityRepresentative;
    }

    /**
     * @notice Returns the status of a pending community representative change
     * @return isPending Whether a community representative change is pending
     * @return newRepresentative Address of the new community representative
     * @return initiatedAt Timestamp when the change was initiated
     * @return availableAt Timestamp when the change can be executed (after timelock)
     * @return timeRemaining Seconds remaining until timelock expires (0 if expired)
     */
    function getCommunityRepresentativeChangeStatus()
        external
        view
        returns (
            bool isPending,
            address newRepresentative,
            uint256 initiatedAt,
            uint256 availableAt,
            uint256 timeRemaining
        )
    {
        isPending = communityRepresentativeChangePending;
        newRepresentative = pendingCommunityRepresentative;
        initiatedAt = communityRepresentativeChangeInitiated;

        if (isPending) {
            availableAt =
                communityRepresentativeChangeInitiated +
                EMERGENCY_TIMELOCK;
            if (block.timestamp < availableAt) {
                timeRemaining = availableAt - block.timestamp;
            } else {
                timeRemaining = 0;
            }
        } else {
            availableAt = 0;
            timeRemaining = 0;
        }
    }

    /**
     * @notice Checks if a pending community representative change can be executed
     * @return canExecute True if change is pending and timelock has expired
     */
    function canExecuteCommunityRepresentativeChange()
        external
        view
        returns (bool canExecute)
    {
        if (!communityRepresentativeChangePending) {
            return false;
        }
        return
            block.timestamp >=
            communityRepresentativeChangeInitiated + EMERGENCY_TIMELOCK;
    }

    /**
     * @notice Returns the status of a pending emergency alpha withdrawal
     * @return isPending Whether an emergency alpha withdrawal is pending
     * @return amount Amount of alpha to withdraw (9 decimals)
     * @return initiatedAt Timestamp when the withdrawal was initiated
     * @return availableAt Timestamp when the withdrawal can be executed (after 48 hour timelock)
     * @return timeRemaining Seconds remaining until timelock expires (0 if expired)
     */
    function getEmergencyWithdrawStatus()
        external
        view
        returns (
            bool isPending,
            uint256 amount,
            uint256 initiatedAt,
            uint256 availableAt,
            uint256 timeRemaining
        )
    {
        isPending = emergencyWithdrawPending;
        amount = emergencyWithdrawAmount;
        initiatedAt = emergencyWithdrawInitiated;

        if (isPending) {
            availableAt = emergencyWithdrawInitiated + EMERGENCY_TIMELOCK;
            if (block.timestamp < availableAt) {
                timeRemaining = availableAt - block.timestamp;
            } else {
                timeRemaining = 0;
            }
        } else {
            availableAt = 0;
            timeRemaining = 0;
        }
    }

    /**
     * @notice Returns the status of a pending emergency TAO withdrawal
     * @return isPending Whether an emergency TAO withdrawal is pending
     * @return amount Amount of TAO to withdraw (in wei)
     * @return recipient Address that will receive the TAO
     * @return initiatedAt Timestamp when the withdrawal was initiated
     * @return availableAt Timestamp when the withdrawal can be executed (after 48 hour timelock)
     * @return timeRemaining Seconds remaining until timelock expires (0 if expired)
     */
    function getEmergencyTaoWithdrawStatus()
        external
        view
        returns (
            bool isPending,
            uint256 amount,
            address recipient,
            uint256 initiatedAt,
            uint256 availableAt,
            uint256 timeRemaining
        )
    {
        isPending = emergencyTaoWithdrawPending;
        amount = emergencyTaoWithdrawAmount;
        recipient = emergencyTaoWithdrawRecipient;
        initiatedAt = emergencyTaoWithdrawInitiated;

        if (isPending) {
            availableAt = emergencyTaoWithdrawInitiated + EMERGENCY_TIMELOCK;
            if (block.timestamp < availableAt) {
                timeRemaining = availableAt - block.timestamp;
            } else {
                timeRemaining = 0;
            }
        } else {
            availableAt = 0;
            timeRemaining = 0;
        }
    }

    /**
     * @notice Checks if a pending emergency alpha withdrawal can be executed
     * @return canExecute True if withdrawal is pending and 48 hour timelock has expired
     */
    function canExecuteEmergencyWithdraw()
        external
        view
        returns (bool canExecute)
    {
        if (!emergencyWithdrawPending) {
            return false;
        }
        return
            block.timestamp >= emergencyWithdrawInitiated + EMERGENCY_TIMELOCK;
    }

    /**
     * @notice Checks if a pending emergency TAO withdrawal can be executed
     * @return canExecute True if withdrawal is pending and 48 hour timelock has expired
     */
    function canExecuteEmergencyTaoWithdraw()
        external
        view
        returns (bool canExecute)
    {
        if (!emergencyTaoWithdrawPending) {
            return false;
        }
        return
            block.timestamp >=
            emergencyTaoWithdrawInitiated + EMERGENCY_TIMELOCK;
    }

    /**
     * @notice Returns the last recorded alpha balance used for yield calculation
     * @return uint256 Last recorded alpha balance in 9 decimals
     */
    function getLastRecordedAlphaBalance() public view returns (uint256) {
        return lastRecordedAlphaBalance;
    }

    /**
     * @notice Returns the total accumulated yield fees collected historically
     * @return uint256 Total accumulated yield fees in alpha (9 decimals)
     */
    function getAccumulatedYieldFees() public view returns (uint256) {
        return accumulatedYieldFees;
    }

    /**
     * @notice Estimates the treasury fee for a TAO deposit in alpha
     * @param amount TAO amount to deposit (9 decimals)
     * @return uint256 Estimated treasury fee in alpha (9 decimals)
     */
    function estimatedMintingFee(
        uint256 amount
    ) external view returns (uint256) {
        uint256 expectedAlphaAmount = _calculateAlphaFromTao(amount);

        // Calculate treasury fee in alpha (not LSA)
        if (fee > 0) {
            uint256 treasuryAlphaFee = (expectedAlphaAmount * fee) / FEE_SCALED;
            return treasuryAlphaFee;
        }
        return 0;
    }

    /**
     * @notice Estimates the LSA tokens to be minted for a TAO deposit
     * @param amount TAO amount to deposit (9 decimals)
     * @return uint256 Estimated LSA tokens to mint (18 decimals)
     */
    function estimatedLsaToMint(
        uint256 amount
    ) external view returns (uint256) {
        return _estimatedLsaToMint(amount);
    }

    /**
     * @dev Internal function to estimate LSA tokens to be minted for a TAO deposit
     * @param amount TAO amount to deposit (9 decimals)
     * @return uint256 Estimated LSA tokens to mint (18 decimals)
     */
    function _estimatedLsaToMint(
        uint256 amount
    ) internal view returns (uint256) {
        uint256 expectedAlphaAmount = _calculateAlphaFromTao(amount);

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (expectedAlphaAmount * fee) / FEE_SCALED;
        }

        // Calculate LSA to mint based on net alpha (after treasury fee)
        uint256 netAlphaForUser = expectedAlphaAmount - treasuryAlphaFee;
        uint256 rate = _exchangeRate();
        uint256 alphaIn18Decimals = netAlphaForUser * RAO;
        uint256 userLsaAmount = (alphaIn18Decimals * WAD) / rate;

        return userLsaAmount;
    }

    /**
     * @notice Estimates the treasury fee for a TAO deposit in TAO
     * @param amount TAO amount to deposit (9 decimals)
     * @return uint256 Estimated treasury fee in TAO (9 decimals)
     */
    function estimatedMintingFeeInTao(
        uint256 amount
    ) external view returns (uint256) {
        uint256 expectedAlphaAmount = _calculateAlphaFromTao(amount);

        // Calculate treasury fee in alpha (not LSA)
        if (fee > 0) {
            uint256 treasuryAlphaFee = (expectedAlphaAmount * fee) / FEE_SCALED;
            // Convert alpha fee to TAO
            uint256 feeTaoAmount = _calculateTaoFromAlpha(treasuryAlphaFee);
            return feeTaoAmount;
        }
        return 0;
    }

    /**
     * @notice Estimates the TAO to be received when redeeming LSA tokens
     * @param lsaAmount Amount of LSA tokens to redeem (18 decimals)
     * @return uint256 Estimated TAO amount after fees (9 decimals)
     */
    function estimatedTaoFromLsa(
        uint256 lsaAmount
    ) external view returns (uint256) {
        return _estimatedTaoFromLsa(lsaAmount);
    }

    /**
     * @dev Internal function to estimate TAO from LSA redemption
     * @dev Calculates fees in alpha, then converts net alpha to TAO
     * @param lsaAmount Amount of LSA tokens to redeem (18 decimals)
     * @return uint256 Estimated TAO amount after fees (9 decimals)
     */
    function _estimatedTaoFromLsa(
        uint256 lsaAmount
    ) internal view returns (uint256) {
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Convert LSA to gross alpha first
        uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (grossAlpha * fee) / FEE_SCALED;
        }

        // Apply network fee buffer to alpha as well
        uint256 networkFeeAlpha = 0;
        if (networkFee > 0) {
            networkFeeAlpha = (grossAlpha * networkFee) / FEE_SCALED;
        }

        // Net alpha to remove after fees
        uint256 alphaAmount = grossAlpha - treasuryAlphaFee - networkFeeAlpha;
        if (alphaAmount == 0) revert InvalidAmount();

        uint256 taoAmount = _calculateTaoFromAlpha(alphaAmount);
        return taoAmount;
    }

    /**
     * @notice Estimates the redemption fees for burning LSA tokens in alpha
     * @param lsaAmount Amount of LSA tokens to redeem (18 decimals)
     * @return treasuryFee Treasury fee in alpha (9 decimals)
     * @return networkFeeBuffer Network fee buffer in alpha (9 decimals)
     */
    function estimatedRedemptionFees(
        uint256 lsaAmount
    ) external view returns (uint256 treasuryFee, uint256 networkFeeBuffer) {
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Convert LSA to gross alpha first
        uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

        // Calculate treasury fee in alpha (not LSA)
        treasuryFee = 0;
        if (fee > 0) {
            treasuryFee = (grossAlpha * fee) / FEE_SCALED;
        }

        // Calculate network fee in alpha (not LSA)
        networkFeeBuffer = 0;
        if (networkFee > 0) {
            networkFeeBuffer = (grossAlpha * networkFee) / FEE_SCALED;
        }

        return (treasuryFee, networkFeeBuffer);
    }

    /**
     * @notice Estimates the redemption fees for burning LSA tokens in TAO
     * @param lsaAmount Amount of LSA tokens to redeem (18 decimals)
     * @return treasuryFeeInTao Treasury fee in TAO (9 decimals)
     * @return networkFeeBufferInTao Network fee buffer in TAO (9 decimals)
     */
    function estimatedRedemptionFeesInTao(
        uint256 lsaAmount
    )
        external
        view
        returns (uint256 treasuryFeeInTao, uint256 networkFeeBufferInTao)
    {
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Convert LSA to gross alpha
        uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

        // Calculate treasury fee on gross alpha
        treasuryFeeInTao = 0;
        if (fee > 0) {
            uint256 treasuryFeeAlpha = (grossAlpha * fee) / FEE_SCALED;
            if (treasuryFeeAlpha > 0) {
                treasuryFeeInTao = _calculateTaoFromAlpha(treasuryFeeAlpha);
            }
        }

        // Calculate network fee on gross alpha
        networkFeeBufferInTao = 0;
        if (networkFee > 0) {
            uint256 networkFeeAlpha = (grossAlpha * networkFee) / FEE_SCALED;
            if (networkFeeAlpha > 0) {
                networkFeeBufferInTao = _calculateTaoFromAlpha(networkFeeAlpha);
            }
        }

        return (treasuryFeeInTao, networkFeeBufferInTao);
    }

    /**
     * @notice Returns the conversion rate from TAO to LSA
     * @return uint256 LSA tokens received per 1 TAO (in 18 decimals)
     */
    function taoToLsaRate() external view returns (uint256) {
        uint256 expectedAlphaAmount = _calculateAlphaFromTao(RAO);
        uint256 rate = _exchangeRate();
        uint256 alphaIn18Decimals = expectedAlphaAmount * RAO;
        return (alphaIn18Decimals * WAD) / rate;
    }

    /**
     * @notice Calculates minimum LSA tokens expected from TAO deposit with slippage
     * @param taoAmount TAO amount to deposit (9 decimals)
     * @param slippagePercent Slippage tolerance in basis points (e.g., 100 = 1%)
     * @return minLsaAmount Minimum LSA tokens to expect (18 decimals)
     */
    function calculateMinLsaWithSlippage(
        uint256 taoAmount,
        uint256 slippagePercent
    ) external view returns (uint256 minLsaAmount) {
        if (slippagePercent > 10000) revert SlippageTooHigh();
        uint256 taoAmount9Decimals = taoAmount / RAO;
        uint256 estimatedLsa = _estimatedLsaToMint(taoAmount9Decimals);
        minLsaAmount = (estimatedLsa * (10000 - slippagePercent)) / 10000;
    }

    /**
     * @notice Calculates minimum TAO expected from LSA redemption with slippage
     * @param lsaAmount LSA tokens to redeem (18 decimals)
     * @param slippagePercent Slippage tolerance in basis points (e.g., 100 = 1%)
     * @return minTaoAmount Minimum TAO to expect (9 decimals in wei)
     */
    function calculateMinTaoWithSlippage(
        uint256 lsaAmount,
        uint256 slippagePercent
    ) external view returns (uint256 minTaoAmount) {
        if (slippagePercent > 10000) revert SlippageTooHigh();
        uint256 estimatedTao9Decimals = _estimatedTaoFromLsa(lsaAmount);
        uint256 estimatedTaoWei = estimatedTao9Decimals * RAO;
        minTaoAmount = (estimatedTaoWei * (10000 - slippagePercent)) / 10000;
    }

    /**
     * @notice Calculates minimum alpha expected from LSA redemption with slippage
     * @param lsaAmount LSA tokens to redeem (18 decimals)
     * @param slippagePercent Slippage tolerance in basis points (e.g., 100 = 1%)
     * @return minAlphaAmount Minimum alpha to expect (9 decimals)
     */
    function calculateMinAlphaWithSlippage(
        uint256 lsaAmount,
        uint256 slippagePercent
    ) external view returns (uint256 minAlphaAmount) {
        if (slippagePercent > 10000) revert SlippageTooHigh();
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Compute gross alpha represented by the provided LSA amount
        // alpha = ((lsa * rate) / WAD) / RAO
        uint256 grossAlpha = (lsaAmount * rate) / (WAD * RAO);

        // Calculate treasury fee in alpha (deduct fee from alpha, not from LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (grossAlpha * fee) / FEE_SCALED;
        }

        uint256 netAlpha = grossAlpha > treasuryAlphaFee
            ? grossAlpha - treasuryAlphaFee
            : 0;

        // Apply slippage to net alpha
        minAlphaAmount = (netAlpha * (10000 - slippagePercent)) / 10000;
    }

    /**
     * @notice Calculates minimum LSA expected from alpha deposit with slippage
     * @param alphaAmount Alpha amount to deposit (9 decimals)
     * @param slippagePercent Slippage tolerance in basis points (e.g., 100 = 1%)
     * @return minLsaAmount Minimum LSA tokens to expect (18 decimals)
     */
    function calculateMinLsaFromAlphaWithSlippage(
        uint256 alphaAmount,
        uint256 slippagePercent
    ) external view returns (uint256 minLsaAmount) {
        if (slippagePercent > 10000) revert SlippageTooHigh();
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (alphaAmount * fee) / FEE_SCALED;
        }

        // Calculate LSA to mint based on net alpha (after treasury fee)
        uint256 netAlphaForUser = alphaAmount - treasuryAlphaFee;
        uint256 alphaIn18Decimals = netAlphaForUser * RAO;
        uint256 estimatedUserLsa = (alphaIn18Decimals * WAD) / rate;

        // Apply slippage to the estimated LSA amount
        minLsaAmount = (estimatedUserLsa * (10000 - slippagePercent)) / 10000;
    }

    /**
     * @notice Estimates the LSA tokens to be minted for an alpha deposit
     * @param alphaAmount Alpha amount to deposit (9 decimals)
     * @return estimatedLsa Estimated LSA tokens to mint (18 decimals)
     */
    function estimatedLsaFromAlphaDeposit(
        uint256 alphaAmount
    ) external view returns (uint256 estimatedLsa) {
        if (alphaAmount == 0) revert InvalidAmount();
        uint256 rate = _exchangeRate();
        if (rate == 0) revert InvalidRate();

        // Calculate treasury fee in alpha (not LSA)
        uint256 treasuryAlphaFee = 0;
        if (fee > 0) {
            treasuryAlphaFee = (alphaAmount * fee) / FEE_SCALED;
        }

        // Calculate LSA to mint based on net alpha (after treasury fee)
        uint256 netAlphaForUser = alphaAmount - treasuryAlphaFee;
        uint256 alphaIn18Decimals = netAlphaForUser * RAO;
        estimatedLsa = (alphaIn18Decimals * WAD) / rate;
    }

    /**
     * @notice Gets a user's stake balance with the validator
     * @param coldkey The user's coldkey address (bytes32)
     * @return uint256 Stake balance in alpha (9 decimals)
     */
    function getMyStakeBalance(
        bytes32 coldkey
    ) external view returns (uint256) {
        return _getMyStakeBalance(coldkey);
    }

    /**
     * @dev Internal function to get a user's stake balance with the validator
     * @param coldkey The user's coldkey address (bytes32)
     * @return uint256 Stake balance in alpha (9 decimals)
     */
    function _getMyStakeBalance(
        bytes32 coldkey
    ) internal view returns (uint256) {
        bytes32 hotkey = getValidatorHotkey();
        bytes memory data = abi.encodeWithSelector(
            IStaking.getStake.selector,
            hotkey,
            coldkey,
            NETUID
        );

        (bool success, bytes memory result) = address(staking).staticcall(data);
        if (!success) revert CallFailed();

        return abi.decode(result, (uint256));
    }

    /**
     * @notice Returns the total alpha staked by this contract
     * @return uint256 Total alpha stake in 9 decimals
     */
    function getTotalContractStake() external view returns (uint256) {
        return _getTotalContractStake();
    }

    /**
     * @notice Calculates expected alpha from TAO swap simulation
     * @param taoAmount TAO amount to swap (9 decimals)
     * @return alphaAmount Expected alpha from swap (9 decimals)
     */
    function calculateAlphaFromTao(
        uint256 taoAmount
    ) external view returns (uint256 alphaAmount) {
        return _calculateAlphaFromTao(taoAmount);
    }

    /**
     * @notice Calculates expected TAO from alpha swap simulation
     * @param alphaAmount Alpha amount to swap (9 decimals)
     * @return taoAmount Expected TAO from swap (9 decimals)
     */
    function calculateTaoFromAlpha(
        uint256 alphaAmount
    ) external view returns (uint256 taoAmount) {
        return _calculateTaoFromAlpha(alphaAmount);
    }

    /**
     * @dev Internal function to calculate expected alpha from TAO swap
     * @param taoAmount TAO amount to swap (9 decimals)
     * @return alphaAmount Expected alpha from swap (9 decimals)
     */
    function _calculateAlphaFromTao(
        uint256 taoAmount
    ) internal view returns (uint256 alphaAmount) {
        bytes memory data = abi.encodeWithSelector(
            IAlpha.simSwapTaoForAlpha.selector,
            uint16(NETUID),
            uint64(taoAmount)
        );

        (bool success, bytes memory result) = address(alpha).staticcall(data);
        if (!success) revert CallFailed();

        alphaAmount = abi.decode(result, (uint256));
    }

    /**
     * @dev Internal function to calculate expected TAO from alpha swap
     * @param alphaAmount Alpha amount to swap (9 decimals)
     * @return taoAmount Expected TAO from swap (9 decimals)
     */
    function _calculateTaoFromAlpha(
        uint256 alphaAmount
    ) internal view returns (uint256 taoAmount) {
        bytes memory data = abi.encodeWithSelector(
            IAlpha.simSwapAlphaForTao.selector,
            uint16(NETUID),
            uint64(alphaAmount)
        );

        (bool success, bytes memory result) = address(alpha).staticcall(data);
        if (!success) revert CallFailed();

        taoAmount = abi.decode(result, (uint256));
    }

    /**
     * @notice Returns the current alpha price for this subnet
     * @return uint256 Alpha price (scaled value)
     */
    function getAlphaPrice() external view returns (uint256) {
        bytes memory data = abi.encodeWithSelector(
            IAlpha.getAlphaPrice.selector,
            uint16(NETUID)
        );

        (bool success, bytes memory result) = address(alpha).staticcall(data);
        if (!success) revert CallFailed();

        return abi.decode(result, (uint256));
    }

    /**
     * @notice Returns the moving average alpha price for this subnet
     * @return uint256 Moving average alpha price (scaled value)
     */
    function getMovingAlphaPrice() external view returns (uint256) {
        bytes memory data = abi.encodeWithSelector(
            IAlpha.getMovingAlphaPrice.selector,
            uint16(NETUID)
        );

        (bool success, bytes memory result) = address(alpha).staticcall(data);
        if (!success) revert CallFailed();

        return abi.decode(result, (uint256));
    }

    /**
     * @notice Returns the Total Value Locked (TVL) in the contract
     * @return alphaAmount Total alpha staked (9 decimals)
     * @return taoValue Total TAO equivalent value (9 decimals)
     * @return lastUpdated Timestamp of last TVL update
     */
    function getTVL()
        external
        view
        returns (uint256 alphaAmount, uint256 taoValue, uint256 lastUpdated)
    {
        alphaAmount = totalValueLockedInAlpha;
        taoValue = totalValueLockedInTao;
        lastUpdated = tvlLastUpdated;
    }

    /**
     * @notice Returns the total LSA token supply
     * @return uint256 Total LSA supply (18 decimals)
     */
    function getTotalLSASupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Returns TVL along with LSA supply
     * @return alphaAmount Total alpha staked (9 decimals)
     * @return taoValue Total TAO equivalent value (9 decimals)
     * @return lsaSupply Total LSA token supply (18 decimals)
     * @return lastUpdated Timestamp of last TVL update
     */
    function getTVLWithLSA()
        external
        view
        returns (
            uint256 alphaAmount,
            uint256 taoValue,
            uint256 lsaSupply,
            uint256 lastUpdated
        )
    {
        alphaAmount = totalValueLockedInAlpha;
        taoValue = totalValueLockedInTao;
        lsaSupply = totalSupply();
        lastUpdated = tvlLastUpdated;
    }

    /**
     * @notice Calculates current TVL in TAO (not cached)
     * @return uint256 Current TVL in TAO (9 decimals)
     */
    function getCurrentTVLInTao() external view returns (uint256) {
        uint256 currentAlphaStaked = _getTotalContractStake();
        if (currentAlphaStaked == 0) {
            return 0;
        }
        return _calculateTaoFromAlpha(currentAlphaStaked);
    }

    /**
     * @notice Gets a user's LSA balance and its value in alpha and TAO
     * @param user User's address
     * @return lsaBalance User's LSA token balance (18 decimals)
     * @return alphaValue LSA value in alpha (9 decimals)
     * @return taoValue LSA value in TAO (9 decimals)
     * @return currentExchangeRate Current exchange rate (18 decimals)
     */
    function getUserLsaValue(
        address user
    )
        external
        view
        returns (
            uint256 lsaBalance,
            uint256 alphaValue,
            uint256 taoValue,
            uint256 currentExchangeRate
        )
    {
        lsaBalance = balanceOf(user);
        currentExchangeRate = _exchangeRate();

        if (lsaBalance > 0) {
            alphaValue = (lsaBalance * currentExchangeRate) / (WAD * RAO);

            if (alphaValue > 0) {
                taoValue = _calculateTaoFromAlpha(alphaValue);
            } else {
                taoValue = 0;
            }
        } else {
            alphaValue = 0;
            taoValue = 0;
        }
    }

    /**
     * @notice Manually triggers a TVL update
     * @dev Can be called by anyone to update cached TVL values
     */
    function updateTVL() external {
        _updateTVL("manual");
    }

    /**
     * @dev Internal function to remove stake from the validator
     * @param amount Amount of alpha to remove (9 decimals)
     */
    function _removeStake(uint256 amount) internal {
        bytes32 hotkey = getValidatorHotkey();
        bytes memory data = abi.encodeWithSelector(
            IStaking.removeStake.selector,
            hotkey,
            amount,
            NETUID
        );
        (bool success, ) = address(staking).call{gas: gasleft()}(data);
        if (!success) revert CallFailed();
    }

    /**
     * @dev Internal function to transfer stake to a recipient
     * @param amount Amount of alpha to transfer (9 decimals)
     * @param to Recipient's SS58 address (bytes32)
     */
    function _transferStake(uint256 amount, bytes32 to) internal {
        bytes32 hotkey = getValidatorHotkey();
        bytes memory data = abi.encodeWithSelector(
            IStaking.transferStake.selector,
            to,
            hotkey,
            NETUID,
            NETUID,
            amount
        );
        (bool success, ) = address(staking).call{gas: gasleft()}(data);
        if (!success) revert CallFailed();
    }

    /**
     * @dev Internal function to calculate and collect yield fees
     * @dev Accumulates yield fees in pendingYieldFee instead of minting LSA
     * @dev Holder yield remains in stake, naturally increasing exchange rate
     * @return yieldLSAMinted Always returns 0 (no LSA minted in V3)
     */
    function _calculateAndCollectYield()
        internal
        returns (uint256 yieldLSAMinted)
    {
        if (yieldFee == 0) {
            lastRecordedAlphaBalance = _getTotalContractStake();
            return 0;
        }

        uint256 currentAlphaBalance = _getTotalContractStake();

        if (
            lastRecordedAlphaBalance == 0 ||
            currentAlphaBalance <= lastRecordedAlphaBalance
        ) {
            lastRecordedAlphaBalance = currentAlphaBalance;
            return 0;
        }

        uint256 yieldGenerated = currentAlphaBalance - lastRecordedAlphaBalance;

        if (yieldGenerated > 0) {
            // Calculate yield fee in alpha (not LSA)
            uint256 treasuryYieldAlpha = (yieldGenerated * yieldFee) /
                FEE_SCALED;

            if (treasuryYieldAlpha > 0) {
                // Accumulate yield fee in state for later transfer
                pendingYieldFee += treasuryYieldAlpha;
                accumulatedYieldFees += treasuryYieldAlpha;

                uint256 rateBefore = _exchangeRate();
                uint256 totalSupplyBefore = totalSupply();
                uint256 holderYieldAlpha = yieldGenerated - treasuryYieldAlpha;
                uint256 totalYieldInTao = _calculateTaoFromAlpha(
                    yieldGenerated
                );

                // Update exchange rate naturally increases as holder yield remains in stake
                uint256 rateAfter = _exchangeRate();
                uint256 totalSupplyAfter = totalSupply();

                emit YieldDistributed(
                    yieldGenerated,
                    totalYieldInTao,
                    treasuryYieldAlpha,
                    holderYieldAlpha,
                    totalSupplyBefore,
                    totalSupplyAfter,
                    rateBefore,
                    rateAfter,
                    block.timestamp,
                    msg.sender
                );

                lastRecordedAlphaBalance = currentAlphaBalance;
                return 0; // No LSA minted, yield is accumulated as alpha
            }

            lastRecordedAlphaBalance = currentAlphaBalance;
        }

        return 0;
    }

    receive() external payable {}
    fallback() external payable {}

    /**
     * @dev Storage gap for future upgrades
     * This reserves storage slots for future versions
     */
    uint256[50] private __gap;
}
