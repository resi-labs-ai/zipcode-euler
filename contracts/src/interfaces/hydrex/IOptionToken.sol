// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the Hydrex option token (oHYDX).
/// Source contract: oHYDX @ Base 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78 (non-proxy).
/// verified on-chain 2026-06-06 against the deployed bytecode + verified ABI:
///   exercise(uint256,uint256,address,uint256) -> 0xa1d50c3a (FOUND) returns paymentAmount
///   exerciseVe(uint256,address)               -> 0x9130325d (FOUND) returns nftId;
///       CORRECTED — the guessed exerciseVe(uint256,uint256,address,uint256)->(uint256,uint256)
///       (0x62994c05) is ABSENT. The real exerciseVe takes only (amount, recipient).
///   getDiscountedPrice(uint256)               -> 0x339ccade (FOUND); staticcall(1e18) returned 12083.
///   discount()                                -> 0x6b6f4a9d (FOUND); staticcall returned 30 (verified
///       on-chain 2026-06-07 for the SzipNavOracle oHYDX intrinsic mark = HYDX x (100 - discount)/100).
interface IOptionToken {
    function exercise(uint256 amount, uint256 maxPaymentAmount, address recipient, uint256 deadline)
        external
        returns (uint256 paymentAmount);

    function exerciseVe(uint256 amount, address recipient) external returns (uint256 nftId);

    /// @notice The ERC20 the option strike is paid in. On-chain-verified 2026-06-08:
    ///   paymentToken() -> 0x3013ce29 (FOUND); staticcall returned USDC
    ///   0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913. Read LIVE in a module's setUp so the strike-approval target can
    ///   never drift from the option's actual payment token.
    function paymentToken() external view returns (address);

    function getDiscountedPrice(uint256 amount) external view returns (uint256);

    /// @notice The flat minimum payment floor for any exercise (NO args). On-chain-verified 2026-06-08:
    ///   getMinPaymentAmount() -> 0x2abb945c (FOUND); staticcall returned 10000 (= $0.01 in USDC 6-dp). The strike the
    ///   contract charges = max(getDiscountedPrice(amount), getMinPaymentAmount()); the no-arg shape is the corrected
    ///   surface (an earlier per-amount guess was wrong).
    function getMinPaymentAmount() external view returns (uint256);

    /// @notice The option exercise discount as a whole-number percent (30 == 30%). Read at mark time so the
    ///         NAV oracle never caches a stale discount; oHYDX intrinsic per token = HYDX x (100 - discount)/100.
    function discount() external view returns (uint256);
}
