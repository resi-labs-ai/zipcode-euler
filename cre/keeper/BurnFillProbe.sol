// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Anvil/simulated-backend probe for the FILL-TRIGGERED BurnJob (KEEPER-01a, 2026-07-28 shape).
///         One contract answers every read the job makes — it returns ITSELF as `shareToken()`/`engineSafe()`/
///         `settlement()` (so the gate, module, token, Safe, and settlement are all this address in the sim) —
///         plus the two settable fill-evidence knobs:
///           - `setBal(uint256)`     — the engine Safe's szipUSD balance (`balanceOf(address)` returns it).
///           - `setUidPresent(bool)` — whether `currentBid()` returns a live 56-byte uid (0xAB…AB) or empty.
///           - `setFilled(uint256)`  — `filledAmount(bytes)` for any uid (the GPv2 cumulative-fill stand-in).
///         `burnFor(amount)` records `lastBurned` and zeroes the balance (the drain the job's latch observes).
///         Compiled with forge solc 0.8.24; creation bytecode embedded in burn_job_sim_test.go (the repo
///         pattern — see RedemptionProbe.sol / StrikeLoopProbe.sol).
contract BurnFillProbe {
    uint256 public bal;
    uint256 public lastBurned;
    uint256 internal filled;
    bool internal uidPresent;

    function setBal(uint256 v) external {
        bal = v;
    }

    function setUidPresent(bool v) external {
        uidPresent = v;
    }

    function setFilled(uint256 v) external {
        filled = v;
    }

    function shareToken() external view returns (address) {
        return address(this);
    }

    function engineSafe() external view returns (address) {
        return address(this);
    }

    function settlement() external view returns (address) {
        return address(this);
    }

    function balanceOf(address) external view returns (uint256) {
        return bal;
    }

    function currentBid() external view returns (bytes memory uid, uint256 sellAmount) {
        if (uidPresent) {
            uid = new bytes(56);
            for (uint256 i; i < 56; i++) {
                uid[i] = 0xAB;
            }
        }
        return (uid, 0);
    }

    function filledAmount(bytes calldata) external view returns (uint256) {
        return filled;
    }

    function burnFor(uint256 amount) external {
        lastBurned = amount;
        bal = 0;
    }
}
