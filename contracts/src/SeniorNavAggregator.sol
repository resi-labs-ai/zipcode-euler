// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IEulerEarnUtil} from "./interfaces/euler/IEulerEarnUtil.sol";
import {SiloRegistry} from "./SiloRegistry.sol";

/// @title SeniorNavAggregator
/// @notice CTR-05: a donation-immune Σ of each silo's SENIOR par-backing across every registered silo, so zipUSD's
///         senior solvency (Σ backing vs supply) is observable across N pools. This is solvency telemetry + the input
///         to any circuit-breaker — NOT a pricing oracle (zipUSD still mints by value and redeems at par).
///
/// @dev Per silo the senior read is the §8.2 donation-immune pattern, NEVER `balanceOf(eePool)`:
///      `sa = convertToAssets(balanceOf(warehouseSafe))` (USDC 6-dp). A stray-USDC donation to the pool address
///      moves neither `convertToAssets` nor `maxWithdraw`, so the aggregate cannot be manipulated by an outsider.
///      The per-silo guards (`sa == 0` → 0; `free >= sa` → 0) are VERBATIM from `DurationFreezeModule:295-302`.
///
/// @dev `seniorBacking()`/`illiquidSeniorValue()` sum ALL silos (retired silos keep backing the zipUSD their still-open
///      lines minted; the donation-immune math makes a drained silo contribute 0 with no special case). The `active`
///      filter belongs ONLY to `activeSeniorBacking()` (the routable-capacity telemetry view).
///
/// @dev Pure view + Timelock wiring. Holds no funds, transfers nothing, writes only the two wiring slots.
contract SeniorNavAggregator is Ownable {
    // --------------------------------------------------------------------- wiring (build phase, §17)
    /// @notice The CTR-02 `SiloRegistry` (the silo catalog the aggregate loops). MAY be zero at deploy; the aggregate
    ///         reads revert `RegistryUnset` until wired.
    SiloRegistry public registry;
    /// @notice The zipUSD ESynth (18-dp). MAY be zero at deploy; `systemCollateralization()` reverts `ZipUsdUnset`
    ///         until wired (the arg form `collateralization(supply)` still works).
    address public zipUsd;

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error RegistryUnset();
    error ZipUsdUnset();

    // --------------------------------------------------------------------- events
    /// @notice Emitted when an owner (Timelock) re-points a wiring slot (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    /// @notice Seeds both wiring slots (either MAY be zero — deploy-order flexibility). Owner is the Timelock.
    constructor(address registry_, address zipUsd_) Ownable(msg.sender) {
        registry = SiloRegistry(registry_);
        zipUsd = zipUsd_;
    }

    // --------------------------------------------------------------------- per-silo donation-immune reads

    /// @dev The §8.2 donation-immune senior value of one silo, 18-dp USD. Guards VERBATIM from
    ///      `DurationFreezeModule:295-302`: `sa == 0` → 0 (a drained/empty silo). Never reads `balanceOf(eePool)`.
    function _seniorValue(address eePool, address warehouseSafe) internal view returns (uint256) {
        IEulerEarnUtil e = IEulerEarnUtil(eePool);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouseSafe));
        if (sa == 0) return 0;
        return sa * 1e12; // USDC 6-dp -> 18-dp USD
    }

    /// @dev The lent-out (illiquid) senior dollars of one silo, 18-dp USD. Guards VERBATIM from
    ///      `DurationFreezeModule:295-302`: `sa == 0` → 0; `free >= sa` → 0. `free` only read when `sa != 0`.
    function _illiquidValue(address eePool, address warehouseSafe) internal view returns (uint256) {
        IEulerEarnUtil e = IEulerEarnUtil(eePool);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouseSafe));
        if (sa == 0) return 0;
        uint256 free = e.maxWithdraw(warehouseSafe);
        if (free >= sa) return 0;
        return (sa - free) * 1e12; // USDC 6-dp -> 18-dp USD
    }

    // --------------------------------------------------------------------- aggregate reads

    /// @notice Σ senior par-backing over ALL silos (the §12 senior-solvency numerator while no impairment is
    ///         outstanding; includes retired silos — they still back outstanding zipUSD). 18-dp USD.
    function seniorBacking() public view returns (uint256 total) {
        if (address(registry) == address(0)) revert RegistryUnset();
        bytes32[] memory ids = registry.allSiloIds();
        for (uint256 i = 0; i < ids.length; i++) {
            SiloRegistry.Silo memory s = registry.getSilo(ids[i]);
            total += _seniorValue(s.eePool, s.warehouseSafe);
        }
    }

    /// @notice Σ senior par-backing over silos with `active == true` only (the routable-capacity telemetry view).
    ///         18-dp USD.
    function activeSeniorBacking() external view returns (uint256 total) {
        if (address(registry) == address(0)) revert RegistryUnset();
        bytes32[] memory ids = registry.allSiloIds();
        for (uint256 i = 0; i < ids.length; i++) {
            SiloRegistry.Silo memory s = registry.getSilo(ids[i]);
            if (s.active) total += _seniorValue(s.eePool, s.warehouseSafe);
        }
    }

    /// @notice Σ lent-out senior dollars over ALL silos (the §12 utilization/duration-squeeze input). 18-dp USD.
    function illiquidSeniorValue() external view returns (uint256 total) {
        if (address(registry) == address(0)) revert RegistryUnset();
        bytes32[] memory ids = registry.allSiloIds();
        for (uint256 i = 0; i < ids.length; i++) {
            SiloRegistry.Silo memory s = registry.getSilo(ids[i]);
            total += _illiquidValue(s.eePool, s.warehouseSafe);
        }
    }

    /// @notice `seniorBacking() * 1e18 / zipUsdSupply` (18-dp ratio; `1e18` == exactly 100% backed). The stress-test /
    ///         hypothetical-supply form. `zipUsdSupply == 0` → `type(uint256).max` (no zipUSD outstanding ⇒ not
    ///         insolvent; a breaker reading `< threshold` must NOT trip).
    function collateralization(uint256 zipUsdSupply) public view returns (uint256) {
        if (zipUsdSupply == 0) return type(uint256).max;
        return seniorBacking() * 1e18 / zipUsdSupply;
    }

    /// @notice `collateralization(zipUsd.totalSupply())` using the wired `zipUsd` (the live breaker input). Reverts
    ///         `ZipUsdUnset` if `zipUsd` is unwired.
    function systemCollateralization() external view returns (uint256) {
        if (zipUsd == address(0)) revert ZipUsdUnset();
        return collateralization(IERC20(zipUsd).totalSupply());
    }

    // --------------------------------------------------------------------- per-silo getters (dashboards)

    /// @notice The senior par-backing of one silo (any active state). Unknown/empty silo (`eePool == 0`) → 0; never
    ///         calls into `address(0)`. 18-dp USD.
    function seniorBackingOf(bytes32 siloId) external view returns (uint256) {
        if (address(registry) == address(0)) revert RegistryUnset();
        SiloRegistry.Silo memory s = registry.getSilo(siloId);
        if (s.eePool == address(0)) return 0;
        return _seniorValue(s.eePool, s.warehouseSafe);
    }

    /// @notice The lent-out senior dollars of one silo. Unknown/empty silo (`eePool == 0`) → 0; never calls into
    ///         `address(0)`. 18-dp USD.
    function illiquidSeniorValueOf(bytes32 siloId) external view returns (uint256) {
        if (address(registry) == address(0)) revert RegistryUnset();
        SiloRegistry.Silo memory s = registry.getSilo(siloId);
        if (s.eePool == address(0)) return 0;
        return _illiquidValue(s.eePool, s.warehouseSafe);
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (§17)

    /// @notice Re-point `registry`. onlyOwner (Timelock). Rejects zero.
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = SiloRegistry(registry_);
        emit WiringSet("registry", registry_);
    }

    /// @notice Re-point `zipUsd`. onlyOwner (Timelock). Rejects zero.
    function setZipUsd(address zipUsd_) external onlyOwner {
        if (zipUsd_ == address(0)) revert ZeroAddress();
        zipUsd = zipUsd_;
        emit WiringSet("zipUsd", zipUsd_);
    }
}
