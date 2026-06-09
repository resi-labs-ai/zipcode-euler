// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for a Zodiac Roles Modifier v2 instance.
/// Source contract: Roles mastercopy @ Base 0x9646fDAD06d3e24444381f44362a3B0eB343D337
/// VERIFIED 2026-06-06 against vendored reference/zodiac-modifier-roles/packages/evm/contracts/:
///   assignRoles(address,bytes32[],bool[])                       Roles.sol L69
///   execTransactionWithRole(address,uint256,bytes,Operation,bytes32,bool)->bool  Roles.sol L153
///   scopeTarget(bytes32,address)                                PermissionBuilder.sol L86
///   allowFunction(bytes32,address,bytes4,ExecutionOptions)      PermissionBuilder.sol L102
/// `operation` is the Zodiac core Operation enum (Operation.sol: 0=Call, 1=DelegateCall) — used
/// as uint8 here to keep the interface self-contained. `options` is ExecutionOptions
/// (Types.sol L107: 0=None,1=Send,2=DelegateCall,3=Both) — both ordinals confirmed.
/// `scopeFunction` (PermissionBuilder.sol L133, takes ConditionFlat[]) is now INCLUDED — 8-Bw needs
/// parameter-pinned scoping (the wildcarded `allowFunction` skips ALL param checks and would unpin
/// receiver/spender/`to`; it is the wrong tool for the warehouse policy and is NOT used by 8-Bw). The
/// ConditionFlat fields are enums on-chain (Types.sol L123-128: parent uint8, paramType AbiType,
/// operator Operator, compValue bytes) but ABI-encode as `uint8`, so this all-`uint8` mirror is
/// byte-for-byte wire-identical for the external call. `memory` here matches the real `memory` param.
interface IRoles {
    /// @notice Flattened scope-config node. Mirror of Types.sol L123-128 (enum fields encoded as uint8).
    /// @dev AbiType (Types.sol L14-22): None=0, Static=1, Dynamic=2, Tuple=3, Array=4, Calldata=5, AbiEncoded=6.
    ///      Operator (Types.sol L48-105): Pass=0, And=1, Or=2, Nor=3, Matches=5, EqualToAvatar=15, EqualTo=16, ...
    struct ConditionFlat {
        uint8 parent;
        uint8 paramType;
        uint8 operator;
        bytes compValue;
    }

    function assignRoles(address module, bytes32[] calldata roleKeys, bool[] calldata memberOf) external;

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);

    function scopeTarget(bytes32 roleKey, address targetAddress) external;

    /// @notice Pin a function's params via the condition tree (PermissionBuilder.sol L133, onlyOwner).
    /// @dev `options` is ExecutionOptions (Types.sol L107: 0=None/Call-only,1=Send,2=DelegateCall,3=Both) as uint8.
    function scopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] memory conditions,
        uint8 options
    ) external;

    /// @dev `options` is the Roles ExecutionOptions enum (0=None,1=Send,2=DelegateCall,3=Both) as uint8.
    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options) external;
}
