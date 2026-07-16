// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Gnosis Safe Proxy Factory 1.3.0.
/// Source contract: GnosisSafeProxyFactory @ Base 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
/// Signature matched to the Basescan-verified "Safe: Proxy Factory 1.3.0 default" ABI.
interface ISafeProxyFactory {
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);

    /// @dev The proxy contract creation bytecode. CREATE2 deployment data is
    /// `abi.encodePacked(proxyCreationCode(), abi.encode(uint256(uint160(_singleton))))`,
    /// salt = `keccak256(abi.encodePacked(keccak256(initializer), saltNonce))`. Used by 8-B1 to
    /// precompute the main-Safe address (initializer is empty per BaalSummoner.sol:233).
    function proxyCreationCode() external pure returns (bytes memory);
}
