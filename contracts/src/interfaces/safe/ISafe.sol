// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Gnosis Safe (L2 singleton 1.4.1).
/// Source contract: SafeL2 @ Base 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
/// Only the methods Zipcode calls are declared. Signatures matched to the
/// Basescan-verified SafeL2 ABI (operation is the Safe Enum.Operation: 0=call,1=delegatecall).
interface ISafe {
    /// @notice The Safe initializer (SafeL2 1.4.1). Signature matched to the Basescan-verified ABI.
    /// @dev Passed as the `initializer` to `ISafeProxyFactory.createProxyWithNonce`; the proxy delegatecalls
    ///      it into the singleton at construction (owners/threshold/module-set/fallback all set atomically).
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function enableModule(address module) external;

    function isModuleEnabled(address module) external view returns (bool);

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);

    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;

    function addOwnerWithThreshold(address owner, uint256 _threshold) external;

    function removeOwner(address prevOwner, address owner, uint256 _threshold) external;

    function getOwners() external view returns (address[] memory);

    function isOwner(address owner) external view returns (bool);

    function getThreshold() external view returns (uint256);

    /// @dev The owner-signed execution path. For a 1/1 owner that is `msg.sender`, the pre-validated
    /// signature scheme is `signatures = abi.encodePacked(bytes32(uint160(owner)), bytes32(0), uint8(1))`
    /// (no ECDSA / no prior approveHash needed when `msg.sender == owner`).
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}
