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
/// `scopeFunction` (PermissionBuilder.sol L133, takes ConditionFlat[]) is intentionally omitted
/// from this minimal surface — it EXISTS but needs the ConditionFlat[]/ExecutionOptions types;
/// the wildcarded `allowFunction` is the minimal-surface substitute. Omission is deliberate, not a gap.
interface IRoles {
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

    /// @dev `options` is the Roles ExecutionOptions enum (0=None,1=Send,2=DelegateCall,3=Both) as uint8.
    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options) external;
}
