// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";

/// @dev Shared init-lock base for the szipUSD engine-module mastercopies (SEC-14 / kill-list L18).
///      Each engine module is deployed once as a `ModuleProxyFactory` mastercopy, then EIP-1167-cloned
///      per Safe; the clone's wiring is written by `setUp(bytes)` under the zodiac-core one-shot
///      `initializer` modifier. WITHOUT this base the mastercopy's `_initialized` stays false, so anyone
///      can call `setUp` on the bare mastercopy — harmless (a bare mastercopy is never enabled on a Safe)
///      but the modules' docstrings claimed it was already locked. Inheriting this base makes the claim true.
///
///      The lock runs `_lockMastercopy()` from the constructor — an EMPTY `initializer`-guarded function.
///      It flips the inherited (private, in zodiac-core `Initializable`) `_initialized = true` WITHOUT
///      running `setUp`, so it sidesteps `setUp`'s non-zero / `owner != operator` validation (a ctor that
///      called `setUp(abi.encode(zeros))` would revert `ZeroAddress`). After construction any `setUp` on
///      the mastercopy reverts `AlreadyInitialized`.
///
///      EIP-1167 clones NEVER run this constructor (a proxy does not execute the implementation's ctor; its
///      storage `_initialized` is fresh-zero), so clones `setUp` exactly once as before — the deploy path
///      (`DeployZipcode._cloneModule` → `ModuleProxyFactory.deployModule`) is unchanged.
abstract contract MastercopyInitLock is Module {
    constructor() {
        _lockMastercopy();
    }

    /// @dev Empty body — the `initializer` modifier (zodiac-core `Initializable`) flips `_initialized`.
    function _lockMastercopy() private initializer {}
}
