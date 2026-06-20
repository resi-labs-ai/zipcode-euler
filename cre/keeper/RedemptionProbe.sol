// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title RedemptionProbe
/// @notice A single combined recorder probe for the CRE-02 RedemptionJob sim test.
///         It (a) returns scripted VIEW values for every gate read the Job makes
///         off the OffRampModule + ZipRedemptionQueue + the two tokens, and (b)
///         RECORDS the ordered (selector, arg) of every operator/controller leg the
///         Runner submits. One contract stands in for the off-ramp, the queue, and
///         the usdc/zipUSD tokens: the sim test points the Job's offramp config at
///         this address, and the probe returns itself for queue()/juniorTrancheSafe()/
///         zipUSD()/usdc() — exactly as the KEEPER-01a burn probe returns itself for
///         shareToken()/engineSafe().
contract RedemptionProbe {
    // ---- scripted view state (settable by the test) ----
    address public rqSafe;       // returned by juniorTrancheSafe()
    uint256 public scaleUp;      // returned by scaleUp()
    uint256 public totalPending; // returned by totalPending()
    uint256 public reservedAssets; // returned by reservedAssets()
    uint256 public bal;          // returned by balanceOf(address) — serves both usdcBal(queue) and idleZip(rqSafe)
    uint256 public claimable;    // returned by maxWithdraw(address)
    address public operatorAddr; // returned by operator() / controller()

    // ---- ordered recorder ----
    struct Rec { bytes4 sel; uint256 a0; }
    Rec[] public recs;

    function recordCount() external view returns (uint256) { return recs.length; }

    /// @notice The i-th recorded call: (selector, arg0). settleEpoch's arg0 is 0.
    function record(uint256 i) external view returns (bytes4, uint256) {
        Rec storage r = recs[i];
        return (r.sel, r.a0);
    }

    // ---- test seeders ----
    function setRqSafe(address a) external { rqSafe = a; }
    function setScaleUp(uint256 v) external { scaleUp = v; }
    function setTotalPending(uint256 v) external { totalPending = v; }
    function setReservedAssets(uint256 v) external { reservedAssets = v; }
    function setBal(uint256 v) external { bal = v; }
    function setClaimable(uint256 v) external { claimable = v; }
    function setOperator(address a) external { operatorAddr = a; }

    // ---- scripted address getters (all resolve to THIS probe so reads hit here) ----
    function juniorTrancheSafe() external view returns (address) { return rqSafe; }
    // pendingRequester() returns rqSafe so the escrow serialization guard (pendingRequester == 0 || == rqSafe)
    // passes in the sim (escrow fires). A foreign value is exercised in the unit test, not here.
    function pendingRequester() external view returns (address) { return rqSafe; }
    function queue() external view returns (address) { return address(this); }
    function zipUSD() external view returns (address) { return address(this); }
    function usdc() external view returns (address) { return address(this); }
    function operator() external view returns (address) { return operatorAddr; }
    function controller() external view returns (address) { return operatorAddr; }

    // ---- scripted scalar views the Job reads ----
    function balanceOf(address) external view returns (uint256) { return bal; }
    function maxWithdraw(address) external view returns (uint256) { return claimable; }

    // ---- state-changing legs (recorded, in submission order) ----
    function settleEpoch() external {
        recs.push(Rec(this.settleEpoch.selector, 0));
    }
    function claim(uint256 assets) external {
        recs.push(Rec(this.claim.selector, assets));
    }
    function requestRedeem(uint256 zipAmount) external {
        recs.push(Rec(this.requestRedeem.selector, zipAmount));
    }
}
