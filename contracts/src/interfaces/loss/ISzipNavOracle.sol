// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title ISzipNavOracle — minimal provision-writer seam
/// @notice The single method the `DefaultCoordinator` needs on `SzipNavOracle`: push the bounded impairment
///         provision. Interface-not-import (the concrete oracle is GPL + carries the full NAV machinery the
///         coordinator must not depend on for a one-method call). `SzipNavOracle.sol:228` is the concrete impl;
///         it gates `msg.sender == defaultCoordinator` and stores the value UNBOUNDED (the bound is the
///         coordinator's job, `SzipNavOracle.sol:29-31`).
interface ISzipNavOracle {
    function writeProvision(uint256 newProvision) external;
}
