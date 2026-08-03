// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {SzipNavOracleDemoVAMM} from "../src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol";
import {LpStrategyModuleDemoVAMM} from "../src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol";
import {IModuleProxyFactory} from "../src/interfaces/zodiac/IModuleProxyFactory.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {BaseAddresses} from "./BaseAddresses.sol";

/// @title DeployShowcaseVAMM
/// @notice **Post-deploy, DEMO/SHOWCASE step — run AFTER the main deploy** (`DeployLocal`/`DeployZipcode`). Stands up
///         the auto-compounder showcase on the **already-deployed** engine Safe, using an EXISTING live venue (the
///         vAMM HYDX/USDC pair + its gauge) so it can run on mainnet BEFORE our real zipUSD/xALPHA ICHI pool exists:
///           1. deploy `SzipNavOracleDemoVAMM` (prices the vAMM LP — the prod oracle reverts `UnknownLpToken` on it),
///              wire it (shareToken + juniorTrancheEngine + LP position + CRE identity);
///           2. deploy + clone `LpStrategyModuleDemoVAMM` and **enable it on the existing engine (main) Safe** via the
///              same team-owner `execTransaction` path the main deploy uses for every engine module.
///         No new Safe, no new system: the demo modules sit alongside the prod ones on the SAME Safe. Retire by
///         `disableModule` + pulling the showcase LP out. Run as the **team** (a Safe owner):
///           `forge script script/DeployShowcaseVAMM.s.sol:DeployShowcaseVAMM --rpc-url <rpc> --broadcast --slow --private-key <team>`
///         See `docs/wires/SHOWCASE-VAMM.md`.
contract DeployShowcaseVAMM is Script {
    // --- principals (anvil deterministic; == the main deploy) ---
    address internal constant TEAM = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // broadcaster + Safe owner + demo owner
    address internal constant OPERATOR = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // creOperator (engine ops)

    // --- already-deployed protocol addresses (from the main deploy; regenerate with build/anvil/smoketest/regen-addresses.sh
    //     after EVERY main redeploy — these drift with the bytecode; on 2026-08-03 the stale SZIPUSD constant here
    //     pointed at the LIVE SzipNavOracle and bricked the demo oracle's spotNavPerShare) ---
    address internal constant MAIN_SAFE = 0x0B9C95c7fc6048Bd4B568b637707D7dC5381B2ac; // engine Safe (avatar)
    address internal constant SIDECAR = 0x39D229610e52A1229cF5728CAb0A862F650AF6f0;
    address internal constant ZIPUSD = 0xabe34eC6072F35F956450159D7238bCB719Fde6a;
    address internal constant SZIPUSD = 0x783A08cb688a94cb6bCaE9f74eDe6762b44f3ACd; // shareToken
    address internal constant XALPHA_MIRROR = 0x237C95e376FCA422316a18264936C426BBc686B6;

    // --- governed params (mirrors the live SzipNavOracle: W / maxAge) ---
    uint32 internal constant W = 3600;
    uint256 internal constant MAX_AGE = 86400;

    // --- CRE identity (so the same reportType-7 sharefeeds leg pushes feed the demo oracle) ---
    // CTR-16: author + workflowName (the shared `workflowId` pin is dropped). The demo NAV oracle is fed by the
    // sharefeeds daemon, so it shares the sharefeeds local label.
    address internal constant WORKFLOW_AUTHOR = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    string internal constant WORKFLOW_NAME = "zip-sharefeeds";

    // --- the live vAMM substitute (HYDX/USDC pair + its ALM-style gauge; verified alive on the fork) ---
    address internal constant VAMM_PAIR = 0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d;
    address internal constant VAMM_GAUGE = 0x2dA5744C7205ae9CacBB1AB8a72A2fA3896d39F8;

    // --- the deployed SzAlphaRateOracle (so the demo oracle can value the juniorTrancheSidecar's xALPHA leg; else grossBasketValue
    //     reverts on the mock mirror, which has no exchangeRate()) ---
    address internal constant SZALPHA_RATE_ORACLE = 0x46C89c1A4E86b7F025871C35f08aa7da95F79d8f;

    // --- a distinct clone salt (the demo module is a different mastercopy, so it can't collide — but be explicit) ---
    uint256 internal constant SALT = uint256(keccak256("zipcode-showcase-vamm-v1"));

    function run() external {
        vm.startBroadcast(); // broadcast as TEAM (pass --private-key <team>)

        // 1. demo NAV oracle — same ctor as SzipNavOracle, only the LP-leg pricing differs.
        SzipNavOracleDemoVAMM oracle = new SzipNavOracleDemoVAMM(
            BaseAddresses.CRE_KEYSTONE_FORWARDER,
            ZIPUSD,
            BaseAddresses.USDC,
            XALPHA_MIRROR,
            BaseAddresses.HYDX,
            BaseAddresses.OHYDX,
            MAIN_SAFE,
            SIDECAR,
            W,
            MAX_AGE
        );
        oracle.setShareToken(SZIPUSD); // supply denominator for spotNavPerShare
        oracle.setJuniorTrancheEngine(MAIN_SAFE); // the buy-burn denominator-excluded address (mirrors prod)
        oracle.setLpPosition(VAMM_PAIR, VAMM_GAUGE); // <-- prices/staked-reads the vAMM HYDX/USDC LP
        oracle.setXAlphaRateOracle(SZALPHA_RATE_ORACLE); // value the xALPHA leg (else grossBasketValue reverts on the mock mirror)
        oracle.setExpectedAuthor(WORKFLOW_AUTHOR); // CRE identity (reportType-7 sharefeeds legs feed it)
        oracle.setExpectedWorkflowName(WORKFLOW_NAME);

        // 2. demo LP-manager module — clone (mastercopy + setUp) and enable on the EXISTING engine Safe.
        address lpStrategy = _cloneModule(
            address(new LpStrategyModuleDemoVAMM()),
            abi.encode(TEAM, MAIN_SAFE, OPERATOR, VAMM_PAIR, VAMM_GAUGE), // (owner, juniorTrancheEngine, operator, pair, gauge)
            MAIN_SAFE
        );

        vm.stopBroadcast();

        console2.log("SzipNavOracleDemoVAMM   :", address(oracle));
        console2.log("LpStrategyModuleDemoVAMM:", lpStrategy);
        console2.log("enabled on engine Safe  :", MAIN_SAFE);
        console2.log("vAMM pair / gauge       :", VAMM_PAIR, VAMM_GAUGE);
    }

    // ----- helpers (copied verbatim from DeployZipcode's verified module-enable path) -----

    /// @notice Deploy a Zodiac module clone (mastercopy + setUp) via the ModuleProxyFactory, then enable it on `safe`.
    function _cloneModule(address mastercopy, bytes memory setUpData, address safe) internal returns (address proxy) {
        bytes memory initializer = abi.encodeWithSignature("setUp(bytes)", setUpData);
        proxy = IModuleProxyFactory(BaseAddresses.ZODIAC_MODULE_PROXY_FACTORY).deployModule(mastercopy, initializer, SALT);
        _enableModuleOnSafe(safe, proxy);
    }

    /// @notice team (an owner of `safe`) drives `safe.enableModule(module)` via the 1-of-n pre-validated v==1 signature.
    function _enableModuleOnSafe(address safe, address module) internal {
        bytes memory data = abi.encodeWithSelector(ISafe.enableModule.selector, module);
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(TEAM))), bytes32(0), uint8(1));
        ISafe(safe).execTransaction(safe, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }
}
