// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the canonical Zodiac ModuleProxyFactory.
/// Source contract: ModuleProxyFactory @ Base 0x000000000000aDdB49795b0f9bA5BC298cDda236
/// Signature modeled from reference/zodiac-core/contracts/factory/ModuleProxyFactory.sol.
/// Note: a shaman/module may instead INHERIT the OZ-free `Module` via the
/// zodiac-core remap (the gnosis-guild alias) rather than call through this interface.
interface IModuleProxyFactory {
    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}
