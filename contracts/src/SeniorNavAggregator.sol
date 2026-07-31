// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ISeniorPool} from "./interfaces/supply/ISeniorPool.sol";
import {SiloRegistry} from "./SiloRegistry.sol";

/// @title SeniorNavAggregator
/// @notice CTR-05: a donation-immune Σ of each silo's SENIOR par-backing across every registered silo, so zipUSD's
///         senior solvency (Σ backing vs supply) is observable across N pools. This is solvency telemetry + the input
///         to any circuit-breaker — NOT a pricing oracle (zipUSD still mints by value and redeems at par).
///
/// @dev Per silo the senior read is the §8.2 donation-immune pattern, NEVER `balanceOf(eePool)`:
///      `sa = convertToAssets(balanceOf(warehouseSafe))` (USDC 6-dp). A stray-USDC donation to the pool address
///      moves neither `convertToAssets` nor `maxWithdraw`, so the aggregate cannot be manipulated by an outsider.
///      The per-silo guards (`sa == 0` → 0; `free >= sa` → 0) are VERBATIM from `DurationFreezeModule:302-309`.
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
    ///      `DurationFreezeModule:302-309`: `sa == 0` → 0 (a drained/empty silo). Never reads `balanceOf(eePool)`.
    function _seniorValue(address eePool, address warehouseSafe) internal view returns (uint256) {
        ISeniorPool e = ISeniorPool(eePool);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouseSafe));
        if (sa == 0) return 0;
        return sa * 1e12; // USDC 6-dp -> 18-dp USD
    }

    /// @dev The lent-out (illiquid) senior dollars of one silo, 18-dp USD. Guards VERBATIM from
    ///      `DurationFreezeModule:302-309`: `sa == 0` → 0; `free >= sa` → 0. `free` only read when `sa != 0`.
    function _illiquidValue(address eePool, address warehouseSafe) internal view returns (uint256) {
        ISeniorPool e = ISeniorPool(eePool);
        uint256 sa = e.convertToAssets(e.balanceOf(warehouseSafe));
        if (sa == 0) return 0;
        uint256 free = e.maxWithdraw(warehouseSafe);
        if (free >= sa) return 0;
        return (sa - free) * 1e12; // USDC 6-dp -> 18-dp USD
    }

    // --------------------------------------------------------------------- aggregate reads

    /// @dev The shared Σ loop, deduplicated by PHYSICAL backing (audit F10). The value lives on the
    ///      `(eePool, warehouseSafe)` pair — `convertToAssets(balanceOf(warehouseSafe))` — while `SiloRegistry`
    ///      deliberately admits the SAME pair under multiple siloIds (per-physical-pool uniqueness is an intentional
    ///      non-goal: an adapter re-point over the same pool is a separate `addSilo`, and the retired entry stays in
    ///      `allSiloIds()` forever). Without dedup that documented flow permanently double-counts the pair — and the
    ///      error points the DANGEROUS way for this contract's stated purpose (overstated backing = a breaker that
    ///      fails to trip). Pair-keyed on purpose: two silos sharing an `eePool` under DIFFERENT Safes hold genuinely
    ///      distinct share balances and must both count. `activeOnly` filters BEFORE dedup, so a retired duplicate
    ///      never suppresses its live twin. O(n²) seen-scan over the admitted-silo count (tens) — view-path cheap.
    ///
    ///      PER-SILO FAILURE ISOLATION (added ahead of the Morpho/Aave venue expansion): each pair's read runs under
    ///      try/catch, so one broken pool cannot brick the Σ. Today every venue is EulerEarn, whose views answer from
    ///      its own storage and cannot revert; a future third-party pool is upgradeable by ITS governance, and silos
    ///      can never be removed from `allSiloIds()` — without isolation, one post-retirement upgrade could blind the
    ///      solvency views forever. A broken pair counts as ZERO backing, which errs the SAFE way (understated
    ///      backing = a breaker that trips early), and is never silent: `unreadablePairs()` reports the skip count,
    ///      and the strict per-silo getters (`seniorBackingOf`) still revert loudly for diagnosis.
    function _aggregate(bool activeOnly, bool illiquid) private view returns (uint256 total, uint256 skipped) {
        if (address(registry) == address(0)) revert RegistryUnset();
        bytes32[] memory ids = registry.allSiloIds();
        bytes32[] memory seen = new bytes32[](ids.length);
        uint256 seenCount;
        for (uint256 i = 0; i < ids.length; i++) {
            SiloRegistry.Silo memory s = registry.getSilo(ids[i]);
            if (activeOnly && !s.active) continue;
            bytes32 key = keccak256(abi.encodePacked(s.eePool, s.warehouseSafe));
            bool dup;
            for (uint256 j; j < seenCount; j++) {
                if (seen[j] == key) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen[seenCount++] = key;
            if (illiquid) {
                try this.pairIlliquidValue(s.eePool, s.warehouseSafe) returns (uint256 v) {
                    total += v;
                } catch {
                    skipped++;
                }
            } else {
                try this.pairSeniorValue(s.eePool, s.warehouseSafe) returns (uint256 v) {
                    total += v;
                } catch {
                    skipped++;
                }
            }
        }
    }

    /// @notice The raw per-pair senior read, external ONLY so the Σ loop can try/catch it. Dashboards should use
    ///         `seniorBackingOf(siloId)`.
    function pairSeniorValue(address eePool, address warehouseSafe) external view returns (uint256) {
        return _seniorValue(eePool, warehouseSafe);
    }

    /// @notice The raw per-pair illiquid read, external ONLY so the Σ loop can try/catch it. Dashboards should use
    ///         `illiquidSeniorValueOf(siloId)`.
    function pairIlliquidValue(address eePool, address warehouseSafe) external view returns (uint256) {
        return _illiquidValue(eePool, warehouseSafe);
    }

    /// @notice How many physical `(eePool, warehouseSafe)` pairs the all-silos senior Σ currently CANNOT read (their
    ///         views revert). Zero means every aggregate above is complete. Non-zero means the totals understate by
    ///         the broken pairs' backing — pollers must treat the aggregates as a conservative lower bound and probe
    ///         the strict per-silo getters to find the broken venue.
    function unreadablePairs() external view returns (uint256 skipped) {
        (, skipped) = _aggregate(false, false);
    }

    /// @notice Σ senior par-backing over ALL silos (the §12 senior-solvency numerator while no impairment is
    ///         outstanding; includes retired silos — they still back outstanding zipUSD). Each physical
    ///         `(eePool, warehouseSafe)` pair counts ONCE regardless of how many siloIds reference it. 18-dp USD.
    function seniorBacking() public view returns (uint256 total) {
        (total,) = _aggregate(false, false);
    }

    /// @notice Σ senior par-backing over silos with `active == true` only (the routable-capacity telemetry view).
    ///         Pair-deduplicated among the active entries. 18-dp USD.
    function activeSeniorBacking() external view returns (uint256 total) {
        (total,) = _aggregate(true, false);
    }

    /// @notice Σ lent-out senior dollars over ALL silos (the §12 utilization/duration-squeeze input).
    ///         Pair-deduplicated. 18-dp USD.
    function illiquidSeniorValue() external view returns (uint256 total) {
        (total,) = _aggregate(false, true);
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
