// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TokenPool} from "chainlink-ccip/pools/TokenPool.sol";
import {RateLimiter} from "chainlink-ccip/libraries/RateLimiter.sol";
import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

import {SzAlpha} from "../src/bridge/SzAlpha.sol";
import {SzAlphaMirror} from "../src/bridge/SzAlphaMirror.sol";
import {SzAlphaTokenPool} from "../src/bridge/SzAlphaTokenPool.sol";
import {IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "../src/interfaces/bridge/ICctRegistry.sol";

/// @title DeploySzAlphaBridge — deploy + self-serve wire of the szALPHA CCT bridge (964 <-> Base 8453).
/// @notice Per chain: deploy token (SzAlpha proxy on 964 / SzAlphaMirror on Base) -> deploy pool ->
///         grantMintAndBurnRoles(pool) -> registerAdminViaGetCCIPAdmin(token) -> acceptAdminRole(token) ->
///         setPool(token, pool) -> applyChainUpdates(remote lane). NO allowlisting (self-serve).
/// @dev Registration uses `registerAdminViaGetCCIPAdmin` (NOT `registerAdminViaOwner`): the Base mirror
///      (`BurnMintERC20`) is AccessControl-based with no `owner()`, and `SzAlpha.owner()` is the timelock
///      from genesis — so the registrar is the separate `ccipAdmin` role (`getCCIPAdmin()`).
/// @dev The deploy asserts are intentionally aggressive (S1/S8/S9 + the 5-address re-read): a single
///      router re-read is insufficient — a mis-wired registry module passes a router-only check. Wiring
///      MUST NOT proceed unless every assert passes.
contract DeploySzAlphaBridge is Script {
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

    /// @notice Deploy the 964 wrapper (UUPS proxy) + its CCT pool, fully wired-but-laned-later.
    /// @param netuid_ our subnet id (fixture until registration); validatorHotkey_ our validator hotkey.
    /// @param timelock the upgrade/pause authority (set from genesis); ccipAdmin the registrar.
    function deploy964(uint256 netuid_, bytes32 validatorHotkey_, address timelock, address ccipAdmin)
        public
        returns (SzAlpha token, SzAlphaTokenPool pool)
    {
        CctConfig memory cfg = bittensorConfig();
        _assertCctAddresses(cfg);

        SzAlpha impl = new SzAlpha();
        bytes memory initData = abi.encodeCall(
            SzAlpha.initialize, ("Staked xALPHA", "szALPHA", netuid_, validatorHotkey_, timelock, ccipAdmin)
        );
        token = SzAlpha(payable(address(new ERC1967Proxy(address(impl), initData))));

        pool = new SzAlphaTokenPool(IBurnMintERC20(address(token)), 18, cfg.armProxy, cfg.router, cfg.armProxy);
        _wire(address(token), address(pool), cfg);
        _assertDeployed(address(token), address(pool), timelock, cfg);
    }

    /// @notice Deploy the Base (8453) mirror + its CCT pool.
    function deployBase(address timelock) public returns (SzAlphaMirror token, SzAlphaTokenPool pool) {
        CctConfig memory cfg = baseConfig();
        _assertCctAddresses(cfg);

        token = new SzAlphaMirror("Staked xALPHA", "szALPHA");
        pool = new SzAlphaTokenPool(IBurnMintERC20(address(token)), 18, cfg.armProxy, cfg.router, cfg.armProxy);
        _wire(address(token), address(pool), cfg);
        // Mirror has no owner(); the pool ownership hand-off to the timelock is asserted by the caller.
        _assertPoolRmnAndDecimals(address(token), address(pool), cfg);
        // Hand the mirror's mint-control + registrar to the timelock; revoke the deployer. The mirror's
        // constructor granted DEFAULT_ADMIN_ROLE + ccipAdmin to THIS contract (the `new SzAlphaMirror`
        // caller), so the revoke target is `address(this)`, not the external caller.
        token.setCCIPAdmin(timelock);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), timelock);
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // ================================================================
    // │                    Wire (self-serve)                         │
    // ================================================================

    /// @dev grant pool mint/burn -> register admin via getCCIPAdmin -> accept -> setPool. Lane config
    ///      (`applyChainUpdates`) is a separate step (`setRemoteLane`) once both chains' pools exist.
    function _wire(address token, address pool, CctConfig memory cfg) internal {
        // SzAlpha + SzAlphaMirror both expose `grantMintAndBurnRoles(address)`.
        (bool ok,) = token.call(abi.encodeWithSignature("grantMintAndBurnRoles(address)", pool));
        require(ok, "grantMintAndBurnRoles failed");

        IRegistryModuleOwnerCustom(cfg.registryModuleOwnerCustom).registerAdminViaGetCCIPAdmin(token);
        ITokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(token);
        ITokenAdminRegistry(cfg.tokenAdminRegistry).setPool(token, pool);
    }

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
