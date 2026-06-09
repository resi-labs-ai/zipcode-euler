// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for the zipUSD `ESynth` burn seam used by the `ZipRedemptionQueue`.
/// @dev zipUSD = Euler `ESynth` (18-dp). Verified against `reference/euler-vault-kit/src/Synths/ESynth.sol:81`:
///        `burn(address burnFrom, uint256 amount)` — when `burnFrom == _msgSender()` (the queue burning its OWN
///        escrowed balance, `burnFrom == address(this) == caller`) the `_spendAllowance` branch (:91) is SKIPPED,
///        so the queue needs NO allowance and NO minter-capacity grant. `burn` only *decrements*
///        `minters[sender].minted` with an underflow-safe floor (stays 0 for a non-minter queue). `burn(·,0)` is a
///        silent no-op (:85). Local declaration only (the WOOF-00 `[EXT]` house posture; do NOT inherit/import the
///        full `ESynth`). Transfers of zipUSD use the OpenZeppelin IERC20 via SafeERC20.
interface IZipUSD {
    function burn(address burnFrom, uint256 amount) external;
}
