// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title StrikeLoopProbe
/// @notice A single combined recorder probe for the KEEPER-01b StrikeLoopJob sim
///         test. It (a) returns scripted VIEW values for every gate read the Job
///         makes off the engine modules, and (b) RECORDS the ordered
///         (selector, args) of every state-changing leg the Runner submits. One
///         contract stands in for all six engine modules + the oHYDX/HYDX tokens:
///         the sim test points all six module configs (and the token getters) at
///         this one address, exactly as the KEEPER-01a burn probe returns itself
///         for shareToken()/engineSafe().
///
/// @dev The price/share Quoter is NOT served here — it is injected as a fake into
///      the Job in the sim test (the Quoter interface is injectable by design).
///      This probe's job is to prove the Runner submits the ordered multi-leg
///      Plan with the correct decoded scalar args against a real EVM (EstimateGas
///      dry-run + execution).
contract StrikeLoopProbe {
    // ---- scripted view state (settable by the test) ----
    address public engineSafe;       // returned by juniorTrancheEngine()
    uint256 public bal;              // returned by balanceOf(address)
    uint256 public pending;          // returned by pendingReward()
    uint256 public maxSell;          // returned by maxSellHydx()
    uint256 public strike;           // returned by quoteStrike(uint256)

    // ---- ordered recorder ----
    struct Rec { bytes4 sel; uint256 a0; uint256 a1; uint256 a2; }
    Rec[] public recs;

    function recordCount() external view returns (uint256) { return recs.length; }

    /// @notice The i-th recorded call: (selector, arg0, arg1, arg2). Unused args are 0.
    function record(uint256 i) external view returns (bytes4, uint256, uint256, uint256) {
        Rec storage r = recs[i];
        return (r.sel, r.a0, r.a1, r.a2);
    }

    // ---- test seeders ----
    function setEngineSafe(address a) external { engineSafe = a; }
    function setBal(uint256 v) external { bal = v; }
    function setPending(uint256 v) external { pending = v; }
    function setMaxSell(uint256 v) external { maxSell = v; }
    function setStrike(uint256 v) external { strike = v; }

    // ---- scripted views the Job reads ----
    function juniorTrancheEngine() external view returns (address) { return engineSafe; }
    // oHYDX()/hydx()/ichiVault() all resolve to THIS probe so balanceOf hits here.
    function oHYDX() external view returns (address) { return address(this); }
    function hydx() external view returns (address) { return address(this); }
    function ichiVault() external view returns (address) { return address(this); }
    function balanceOf(address) external view returns (uint256) { return bal; }
    function pendingReward() external view returns (uint256) { return pending; }
    function maxSellHydx() external view returns (uint256) { return maxSell; }
    function quoteStrike(uint256) external view returns (uint256) { return strike; }

    // ---- state-changing legs (recorded, in submission order) ----
    function claimReward() external {
        recs.push(Rec(this.claimReward.selector, 0, 0, 0));
    }
    function borrow(uint256 amount) external {
        recs.push(Rec(this.borrow.selector, amount, 0, 0));
    }
    function exercise(uint256 amount, uint256 maxPayment, uint256 deadline) external returns (uint256) {
        recs.push(Rec(this.exercise.selector, amount, maxPayment, deadline));
        return maxPayment;
    }
    function sellHydx(uint256 amountIn, uint256 minOut, uint256 deadline) external returns (uint256) {
        recs.push(Rec(this.sellHydx.selector, amountIn, minOut, deadline));
        return minOut;
    }
    function repay(uint256 amount) external {
        recs.push(Rec(this.repay.selector, amount, 0, 0));
    }
    function creditFreeValue(uint256 amount) external {
        recs.push(Rec(this.creditFreeValue.selector, amount, 0, 0));
    }
    function recycle(uint256 amount) external returns (uint256) {
        recs.push(Rec(this.recycle.selector, amount, 0, 0));
        return amount;
    }
    function addLiquidity(uint256 d0, uint256 d1, uint256 minShares) external returns (uint256) {
        recs.push(Rec(this.addLiquidity.selector, d0, d1, minShares));
        return minShares;
    }
    function stake(uint256 lpAmount) external {
        recs.push(Rec(this.stake.selector, lpAmount, 0, 0));
    }
}
