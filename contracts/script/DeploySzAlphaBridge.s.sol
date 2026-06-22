// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenPool} from "chainlink-ccip/pools/TokenPool.sol";
import {ERC20LockBox} from "chainlink-ccip/pools/ERC20LockBox.sol";
import {RateLimiter} from "chainlink-ccip/libraries/RateLimiter.sol";
import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";

import {SzAlpha} from "../src/bridge/SzAlpha.sol";
import {SzAlphaMirror} from "../src/bridge/SzAlphaMirror.sol";
import {SzAlphaTokenPool} from "../src/bridge/SzAlphaTokenPool.sol";
import {SzAlphaLockReleasePool} from "../src/bridge/SzAlphaLockReleasePool.sol";
import {IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "../src/interfaces/bridge/ICctRegistry.sol";
import {IAlpha} from "../src/interfaces/bridge/ISubtensorPrecompiles.sol";

/// @title DeploySzAlphaBridge — deploy + self-serve wire of the szALPHA CCT bridge (964 <-> Base 8453).
/// @notice TOPOLOGY (the proven Rubicon shape, see `reference/rubicon/`): LOCK/RELEASE on 964
///         (SzAlphaLockReleasePool + ERC20LockBox custody — bridged-out supply stays in `totalSupply()`
///         so `exchangeRate()` stays truthful) and BURN/MINT on Base (SzAlphaMirror + SzAlphaTokenPool).
///         Per chain: deploy token -> deploy pool (+lockbox on 964) -> wire roles -> register admin via
///         getCCIPAdmin -> accept -> setPool -> applyChainUpdates(remote lane). NO allowlisting.
/// @dev Registration uses `registerAdminViaGetCCIPAdmin` (NOT `registerAdminViaOwner`): the Base mirror
///      (`BurnMintERC20`) is AccessControl-based with no `owner()`, and `SzAlpha.owner()` is the timelock
///      from genesis — so the registrar is the separate `ccipAdmin` role (`getCCIPAdmin()`). On 964 the
///      wrapper is initialized with THIS contract as `ccipAdmin` (so `acceptAdminRole` can run in the
///      same transaction) and the role is handed to the real registrar at the end of `deploy964`.
/// @dev The deploy asserts are intentionally aggressive (S1/S8/S9 + the 5-address re-read + the 964
///      precompile probe): a single router re-read is insufficient — a mis-wired registry module passes
///      a router-only check. Wiring MUST NOT proceed unless every assert passes.
contract DeploySzAlphaBridge is Script {
    address internal constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;

    /// @dev BRIDGE-ADV-02: the in-broadcast genesis seed (~1 TAO). Staked at supply 0 and the shares
    ///      burned (sent to 0xdead) so the first-depositor griefing window never opens permissionlessly.
    uint256 internal constant GENESIS_SEED = 1e18; // ~1 TAO

    // --- CCT address book (verified on-chain 2026-06-09; Base typeAndVersion re-read live) ---
    struct CctConfig {
        uint64 chainSelector;
        address router; // Router 1.2.0
        address tokenAdminRegistry; // TokenAdminRegistry 1.5.0
        address registryModuleOwnerCustom; // RegistryModuleOwnerCustom 1.6.0
        address tokenPoolFactory; // TokenPoolFactory 1.5.1
        address armProxy; // ARMProxy / RMN 1.0.0 (canonical, immutable in the pool)
        string expRouter;
        string expTar;
        string expReg;
        string expFactory;
    }

    function baseConfig() public pure returns (CctConfig memory) {
        return CctConfig({
            chainSelector: 15971525489660198786,
            router: 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD,
            tokenAdminRegistry: 0x6f6C373d09C07425BaAE72317863d7F6bb731e37,
            registryModuleOwnerCustom: 0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f,
            tokenPoolFactory: 0xcD66e8e103D05BC3a5059746283949A45C594D16,
            armProxy: 0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8,
            expRouter: "Router 1.2.0",
            expTar: "TokenAdminRegistry 1.5.0",
            expReg: "RegistryModuleOwnerCustom 1.6.0",
            expFactory: "TokenPoolFactory 1.5.1"
        });
    }

    function bittensorConfig() public pure returns (CctConfig memory) {
        return CctConfig({
            chainSelector: 2135107236357186872,
            router: 0xD941fBEcD2b971d0F54b4C34286C95faB52B60B8,
            tokenAdminRegistry: 0xe72d25aDd538E8ef9CeF85622eA8912a6CB98Be6,
            registryModuleOwnerCustom: 0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3,
            tokenPoolFactory: 0x8FE3B17E6B0863aeEA3D38DF063AEa39D4Ab1602,
            armProxy: 0x02A4D69cFfeC00Fbf7F3B60c93e3529Dfc58894d,
            expRouter: "Router 1.2.0",
            expTar: "TokenAdminRegistry 1.5.0",
            expReg: "RegistryModuleOwnerCustom 1.6.0",
            expFactory: "TokenPoolFactory 1.5.1"
        });
    }

    // ================================================================
    // │                    Deploy (per chain)                        │
    // ================================================================

    /// @notice Deploy the 964 wrapper (UUPS proxy) + its LOCK/RELEASE custody (lockbox + pool),
    ///         fully wired-but-laned-later.
    /// @param netuid_ our subnet id (fixture until registration); validatorHotkey_ our validator hotkey.
    /// @param timelock the upgrade/pause authority AND the post-deploy lockbox owner.
    /// @param ccipAdmin the registrar the role is handed to AFTER wiring (init uses this contract).
    function deploy964(uint256 netuid_, bytes32 validatorHotkey_, address timelock, address ccipAdmin)
        public
        returns (SzAlpha token, SzAlphaLockReleasePool pool, ERC20LockBox lockBox)
    {
        CctConfig memory cfg = bittensorConfig();
        _assertCctAddresses(cfg);
        _assertAlphaPrecompile(netuid_);

        SzAlpha impl = new SzAlpha();
        // ccipAdmin = THIS contract during wiring (acceptAdminRole must be called by the registrar);
        // handed to the real `ccipAdmin` below.
        bytes memory initData = abi.encodeCall(
            SzAlpha.initialize, ("Staked xALPHA", "szALPHA", netuid_, validatorHotkey_, timelock, address(this))
        );
        token = SzAlpha(payable(address(new ERC1967Proxy(address(impl), initData))));

        // BRIDGE-ADV-02: seed the genesis stake IN-BROADCAST so there is no permissionless zero-supply
        // window. At supply 0 the deposit slippage floor is exempt (this is the only legitimate
        // `minSharesOut == 0` caller). The seed shares are a burnt cost, not a position — send to 0xdead.
        uint256 seedShares = token.deposit{value: GENESIS_SEED}(0, type(uint256).max);
        token.transfer(address(0xdead), seedShares);

        // Lock/release custody: bridged-out szALPHA is held by the lockbox (NOT burned), so the pool
        // can be rotated (RMN/CCIP upgrades) by re-pointing the authorized caller — no fund migration.
        lockBox = new ERC20LockBox(address(token));
        pool = new SzAlphaLockReleasePool(
            IERC20(address(token)), 18, cfg.armProxy, cfg.router, address(lockBox), cfg.armProxy
        );
        address[] memory added = new address[](1);
        added[0] = address(pool);
        lockBox.applyAuthorizedCallerUpdates(
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: added, removedCallers: new address[](0)})
        );

        // Register on the CCT registry. NO mint/burn grant on 964 (lock/release).
        // THIS contract becomes the registry administrator (it is the registrar + accepts the role) so it
        // can wire `setPool` in-broadcast. That admin role is the ONLY authority that can ever re-point or
        // delist the bridge pool, so it MUST be handed to the durable authority before the script exits.
        IRegistryModuleOwnerCustom(cfg.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).setPool(address(token), address(pool));

        // SEC-03/H4: hand the REGISTRY administrator role to the durable ccipAdmin (2-step — proposes
        // `ccipAdmin` as `pendingAdministrator`). `setCCIPAdmin` alone only mutates the token's
        // `getCCIPAdmin()` view, which the registry consumed once at registration and never re-reads — it
        // does NOT move the registry's `administrator` slot. Without this transfer the ephemeral script
        // stays the sole admin forever and the pool can never be re-pointed (RMN/CCIP upgrades, incident).
        // RUNBOOK (unavoidable post-deploy step): the durable `ccipAdmin` MUST call
        //   ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)
        // to finalize the handoff. Until it does, THIS script remains a live admin — the one residual
        // interruption window; accept promptly. The script cannot accept on `ccipAdmin`'s behalf mid-broadcast.
        ITokenAdminRegistry(cfg.tokenAdminRegistry).transferAdminRole(address(token), ccipAdmin);

        // Hand off: token ccipAdmin view to the real ccipAdmin (kept aligned for any future
        // re-registration via getCCIPAdmin); lockbox ownership PROPOSED to the timelock (Chainlink 2-step
        // ownership — the timelock must call `lockBox.acceptOwnership()`, a runbook step).
        token.setCCIPAdmin(ccipAdmin);
        lockBox.transferOwnership(timelock);

        _assertDeployed(address(token), address(pool), timelock, cfg);
        require(pool.getLockBox() == address(lockBox), "pool lockbox mismatch");
        // SEC-03/H4: assert the REGISTRY pending-administrator is the durable ccipAdmin (NOT the old
        // `getCCIPAdmin()==ccipAdmin` view check — that gave false confidence on the wrong slot).
        // `administrator` is still THIS script pre-accept, so assert `pendingAdministrator` per the 2-step.
        require(
            ITokenAdminRegistry(cfg.tokenAdminRegistry).getTokenConfig(address(token)).pendingAdministrator
                == ccipAdmin,
            "registry admin handoff failed"
        );
        // BRIDGE-ADV-02: a broadcast that didn't seed must fail loudly — genesis must never go live empty.
        require(token.totalSupply() > 0, "genesis not seeded");
    }

    /// @notice Deploy the Base (8453) mirror + its BURN/MINT CCT pool.
    function deployBase(address timelock) public returns (SzAlphaMirror token, SzAlphaTokenPool pool) {
        CctConfig memory cfg = baseConfig();
        _assertCctAddresses(cfg);

        token = new SzAlphaMirror("Staked xALPHA", "szALPHA");
        pool = new SzAlphaTokenPool(IBurnMintERC20(address(token)), 18, cfg.armProxy, cfg.router, cfg.armProxy);

        // Burn/mint wiring (Base only): grant pool mint/burn -> register -> accept -> setPool.
        // As on 964, THIS contract becomes the registry administrator so it can wire `setPool` in-broadcast.
        token.grantMintAndBurnRoles(address(pool));
        IRegistryModuleOwnerCustom(cfg.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(address(token));
        ITokenAdminRegistry(cfg.tokenAdminRegistry).setPool(address(token), address(pool));

        // SEC-03/H4: hand the REGISTRY administrator role to the durable timelock (2-step — proposes
        // `timelock` as `pendingAdministrator`). `setCCIPAdmin(timelock)` below only updates the token view;
        // it does NOT move the registry `administrator` slot. RUNBOOK (unavoidable): the timelock MUST call
        //   ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)
        // post-deploy to finalize. Until then this script remains a live admin (the one residual window).
        ITokenAdminRegistry(cfg.tokenAdminRegistry).transferAdminRole(address(token), timelock);

        // Mirror has no owner(); the pool ownership hand-off to the timelock is asserted by the caller.
        _assertPoolRmnAndDecimals(address(token), address(pool), cfg);
        // SEC-03/H4: assert the REGISTRY pending-administrator is the durable timelock (administrator is
        // still THIS script pre-accept, per the 2-step — assert `pendingAdministrator`).
        require(
            ITokenAdminRegistry(cfg.tokenAdminRegistry).getTokenConfig(address(token)).pendingAdministrator
                == timelock,
            "registry admin handoff failed"
        );
        // Hand the mirror's mint-control + ccipAdmin view to the timelock; revoke the deployer. The mirror's
        // constructor granted DEFAULT_ADMIN_ROLE + ccipAdmin to THIS contract (the `new SzAlphaMirror`
        // caller), so the revoke target is `address(this)`, not the external caller.
        token.setCCIPAdmin(timelock);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), timelock);
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // ================================================================
    // │                    Lane config (post-deploy)                 │
    // ================================================================

    /// @notice Configure the remote lane (idempotent per-direction rate limits). Run once both pools exist.
    function setRemoteLane(
        address pool,
        uint64 remoteChainSelector,
        bytes memory remotePoolAddress,
        bytes memory remoteTokenAddress,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) public {
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = remotePoolAddress;

        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: remoteTokenAddress,
            outboundRateLimiterConfig: outbound,
            inboundRateLimiterConfig: inbound
        });
        TokenPool(pool).applyChainUpdates(new uint64[](0), adds);
    }

    // ================================================================
    // │                         Asserts                              │
    // ================================================================

    /// @dev Re-read ALL FIVE CCT addresses on-chain and assert they match the table (S-deploy). A
    ///      router-only check is insufficient — a mis-wired registry module would slip through.
    function _assertCctAddresses(CctConfig memory cfg) internal view {
        require(_eqStr(_typeAndVersion(cfg.router), cfg.expRouter), "router mismatch");
        require(_eqStr(_typeAndVersion(cfg.tokenAdminRegistry), cfg.expTar), "TAR mismatch");
        require(_eqStr(_typeAndVersion(cfg.registryModuleOwnerCustom), cfg.expReg), "registry module mismatch");
        require(_eqStr(_typeAndVersion(cfg.tokenPoolFactory), cfg.expFactory), "factory mismatch");
        require(_hasCode(cfg.armProxy), "armProxy has no code");
    }

    /// @dev 964-only live calibration probe (replaces item-10's "calibrate denomination" guesswork):
    ///      the Alpha precompile must quote a non-zero spot price AND a non-zero 1-TAO swap sim for our
    ///      netuid — proving the precompile address, the uint16 netuid, the 9-dp sim units, and the
    ///      subnet pool's existence in one read. Skipped automatically off-964 (no code at 0x808).
    function _assertAlphaPrecompile(uint256 netuid_) internal view {
        if (ALPHA_PRECOMPILE.code.length == 0 && block.chainid != 964) return; // not on 964 (e.g. unit tests on anvil)
        (bool ok1, bytes memory p) = ALPHA_PRECOMPILE.staticcall(
            abi.encodeWithSelector(IAlpha.getAlphaPrice.selector, uint16(netuid_))
        );
        require(ok1 && p.length >= 32 && abi.decode(p, (uint256)) != 0, "alpha price probe failed");
        (bool ok2, bytes memory s) = ALPHA_PRECOMPILE.staticcall(
            abi.encodeWithSelector(IAlpha.simSwapTaoForAlpha.selector, uint16(netuid_), uint64(1e9))
        );
        require(ok2 && s.length >= 32 && abi.decode(s, (uint256)) != 0, "simSwap probe failed");
    }

    function _assertDeployed(address token, address pool, address timelock, CctConfig memory cfg) internal view {
        // S1: upgrade authority is the timelock from genesis (no bare-EOA window).
        require(SzAlpha(payable(token)).owner() == timelock, "owner != timelock");
        _assertPoolRmnAndDecimals(token, pool, cfg);
    }

    function _assertPoolRmnAndDecimals(address token, address pool, CctConfig memory cfg) internal view {
        // S8: equal decimals (cross-chain conservation). S9: canonical RMN, immutable.
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && abi.decode(ret, (uint8)) == 18, "token decimals != 18");
        require(TokenPool(pool).getRmnProxy() == cfg.armProxy, "pool rmn != canonical");
    }

    function _typeAndVersion(address a) internal view returns (string memory) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeWithSignature("typeAndVersion()"));
        require(ok, "no typeAndVersion");
        return abi.decode(ret, (string));
    }

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function _eqStr(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
