// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {DeployZipcode} from "./DeployZipcode.s.sol";
import {ZeroIRM, MockERC20} from "./DeployLocal.s.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {ReservoirMarketDeployer} from "./ReservoirMarketDeployer.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @title DeployMainnet — item-10 deploy to LIVE Base mainnet (8453)
/// @notice The real-network counterpart of `DeployLocal`. It runs the same `DeployZipcode` orchestrator (phases
///         P0..P9) but — unlike the bare `DeployZipcode:deploy()` — it also (a) PROVISIONS the two create-time
///         contracts whose addresses cannot be known in advance (the EulerEarn USDC pool + the no-borrow USDC EVault
///         at its supply-queue head), (b) seeds the initial `LP_MARK` so the reservoir `setLTV.getQuote` resolves
///         before CRE is live (P5 override), and (c) runs the EulerEarn curator config (`_configureEulerEarn`) that
///         `deploy()` leaves as a fork-only TODO. Everything is one team-broadcast.
///
/// @dev Principals come from ENV (real EOAs you control), NOT anvil dev accounts. The broadcaster MUST equal
///      `TEAM_MULTISIG` (the Safe pre-validated `v==1` path needs `msg.sender == owner`). Run:
///        forge script script/DeployMainnet.s.sol:DeployMainnet --sig "runMainnet()" \
///          --rpc-url base --broadcast --slow --private-key $DEPLOYER_PRIVATE_KEY
///      (or use --account/--ledger instead of a raw key). DEPLOYER_PRIVATE_KEY's EOA must == TEAM_MULTISIG and hold
///      enough ETH on Base for the full P0..P9 + EE-config gas.
///
///      Provision-if-zero seams (env override OR script-create): IRM, XALPHA_MIRROR, EE_POOL, BASE_USDC_MARKET.
///      Set the env var to a real address to use it; leave it unset/zero to have this script create it. POL_ICHI_VAULT
///      and POL_GAUGE are ALWAYS required env inputs (a live matched ICHI-vault/ALM-gauge pair — `Voter.gauges(vault)`,
///      NOT `Voter.gauges(pool)`; see DeployLocal's gauge note). The shared-LP seam asserts POL_ICHI_VAULT ==
///      escrow.asset(), so it must be the SAME vault the reservoir market collateralises.
contract DeployMainnet is DeployZipcode {
    bool internal _eeProvisioned; // true iff this run CREATED the EE pool (=> we own it => run curator config)

    function runMainnet() external {
        _loadMainnetInputs();

        vm.startBroadcast(); // broadcaster MUST be TEAM_MULTISIG (Safe pre-validated v==1 path)
        _provisionStandins();
        _phaseP0();
        _phaseP1();
        _phaseP2();
        _phaseP4(); // warehouse BEFORE the P3 deposit module (immutable warehouse ctor arg)
        _phaseP3();
        _phaseP5();
        _phaseP6();
        _phaseP7();
        _phaseP8();
        _phaseP9();
        if (_eeProvisioned) _configureEulerEarn(); // only when we own the freshly-created EE pool
        vm.stopBroadcast();
    }

    // ----------------------------------------------------------------- env load
    /// @notice Principals + LP legs are REQUIRED env. IRM/XALPHA/EE_POOL/BASE_USDC_MARKET are provision-if-zero. The
    ///         numeric knobs fall back to the documented defaults (.env.example / DeployLocal) via `envOr`.
    function _loadMainnetInputs() internal {
        // --- principals (real EOAs you control) ---
        i.team = vm.envAddress("TEAM_MULTISIG"); // == the broadcaster EOA
        i.godOwner = vm.envAddress("GOD_OWNER");
        i.creOperator = vm.envAddress("CRE_OPERATOR");
        i.workflowAuthor = vm.envAddress("WORKFLOW_AUTHOR");
        i.erebor = vm.envAddress("EREBOR");
        i.capitalSink = vm.envAddress("CAPITAL_SINK");
        i.saltNonce = vm.envUint("SUMMON_SALT_NONCE");
        i.workflowId = vm.envBytes32("WORKFLOW_ID");

        // --- live LP legs (matched ICHI-vault + ALM gauge pair; REQUIRED) ---
        i.polIchiVault = vm.envAddress("POL_ICHI_VAULT");
        i.polGauge = vm.envAddress("POL_GAUGE");

        // --- provision-if-zero seams (env override OR script-create in _provisionStandins) ---
        i.irm = vm.envOr("IRM", address(0));
        i.xAlphaMirror = vm.envOr("XALPHA_MIRROR", address(0));
        i.eePool = vm.envOr("EE_POOL", address(0));
        i.baseUsdcMarket = vm.envOr("BASE_USDC_MARKET", address(0));

        // --- numeric knobs (documented defaults; override via env) ---
        i.validityWindow = vm.envOr("VALIDITY_WINDOW", uint256(31_536_000));
        // 0 = CRE-push LP oracle + spot NAV LP leg (the M1 / pre-LP default). Set (e.g. 3600 = 1h) only once the
        // zipUSD/xALPHA LP is a live Algebra pool with a TWAP plugin ⇒ trustless fair-LP for both. build/fair-lp.md.
        i.lpTwapWindow = uint32(vm.envOr("LP_TWAP_WINDOW", uint256(0)));
        i.W = uint32(vm.envOr("NAV_W", uint256(3600)));
        i.maxAge = vm.envOr("NAV_MAX_AGE", uint256(86_400));
        i.maxDeviationBps = vm.envOr("NAV_MAX_DEVIATION_BPS", uint256(1000));
        i.tvlCap = vm.envOr("TVL_CAP", uint256(100_000_000e18));
        i.recoveryFloor = vm.envOr("RECOVERY_FLOOR", uint256(0.5e18));
        i.borrowCap = vm.envOr("BORROW_CAP", uint256(1_000_000e6));
        i.borrowLTV = uint16(vm.envOr("BORROW_LTV", uint256(8000)));
        i.liqLTV = uint16(vm.envOr("LIQ_LTV", uint256(9000)));
        i.dBps = uint16(vm.envOr("BUYBURN_DBPS", uint256(100)));
        i.buybackCap = vm.envOr("BUYBACK_CAP", uint256(1_000_000e18));
        // SzAlphaRateOracle immutables — MUST match the 8x-02 doc/test fixtures (6h / 30d / 500%):
        // 6h staleness = ~5 missed hourly CRE pushes before issuance fails closed; a 30d APR window keeps
        // intrinsicAprBps smooth (a 1h window annualizes hourly noise). Immutable post-deploy.
        i.rateMaxStaleness = vm.envOr("RATE_MAX_STALENESS", uint256(6 hours));
        i.rateWindow = uint32(vm.envOr("RATE_WINDOW", uint256(30 days)));
        i.rateAprCap = vm.envOr("RATE_APR_CAP", uint256(50_000));
    }

    /// @notice Create the seams left zero by `_loadMainnetInputs`. IRM: a 0%-rate model (reservoir borrowing is
    ///         internal POL; swap a real IRM in later via the Timelock if desired). XALPHA_MIRROR: an M1 ERC20
    ///         stand-in (no real Base xALPHA exists pre-bridge; see [[supply-side-redesign-locked]]). EE_POOL +
    ///         BASE_USDC_MARKET: real EVK/EulerEarn contracts off the live factories.
    function _provisionStandins() internal {
        if (i.irm == address(0)) i.irm = address(new ZeroIRM());
        if (i.xAlphaMirror == address(0)) {
            i.xAlphaMirror = address(new MockERC20("Zipcode xALPHA mirror", "xALPHA", 18));
        }

        // no-borrow USDC resting market — the EE supply-queue head. A bare EVK proxy (asset=USDC, no oracle/uoa =>
        // supply-only). EVK-factory proxies pass the EulerEarn "EVK Factory Perspective", so EE will onboard it.
        if (i.baseUsdcMarket == address(0)) {
            address baseMkt = GenericFactory(BaseAddresses.EVAULT_FACTORY).createProxy(
                address(0), false, abi.encodePacked(BaseAddresses.USDC, address(0), address(0))
            );
            IEVault(baseMkt).setHookConfig(address(0), 0);
            i.baseUsdcMarket = baseMkt;
        }

        // EulerEarn senior USDC pool off the LIVE factory. owner = team; timelock 0 => immediate cap config in
        // _configureEulerEarn. Only run that config when WE created the pool (we own it).
        if (i.eePool == address(0)) {
            (bool ok, bytes memory ret) = BaseAddresses.EULER_EARN_FACTORY.call(
                abi.encodeWithSignature(
                    "createEulerEarn(address,uint256,address,string,string,bytes32)",
                    i.team, uint256(0), BaseAddresses.USDC, "Zipcode Senior USDC", "zSNR", bytes32(i.saltNonce)
                )
            );
            require(ok, "createEulerEarn failed");
            i.eePool = abi.decode(ret, (address));
            _eeProvisioned = true;
        }
    }

    /// @notice EE curator runbook (admin ABI not compiled). Run as the EE owner (team): set fee recipient, onboard the
    ///         resting USDC market + the reservoir borrow vault (both EVK-factory proxies => perspective-verified),
    ///         point the supply queue at the resting market, then hand curator (also satisfies allocator) to the venue
    ///         adapter so `openLine` can onboard per-line vaults and `fund` can reallocate at origination.
    function _configureEulerEarn() internal {
        address ee = i.eePool;
        uint256 capMax = type(uint136).max;

        _eeCall(ee, abi.encodeWithSignature("setFeeRecipient(address)", d.warehouse.safe));

        _eeCall(ee, abi.encodeWithSignature("submitCap(address,uint256)", i.baseUsdcMarket, capMax));
        _eeCall(ee, abi.encodeWithSignature("acceptCap(address)", i.baseUsdcMarket));
        _eeCall(ee, abi.encodeWithSignature("submitCap(address,uint256)", d.borrowVault, capMax));
        _eeCall(ee, abi.encodeWithSignature("acceptCap(address)", d.borrowVault));

        address[] memory q = new address[](1);
        q[0] = i.baseUsdcMarket;
        _eeCall(ee, abi.encodeWithSignature("setSupplyQueue(address[])", q));

        _eeCall(ee, abi.encodeWithSignature("setCurator(address)", address(d.adapter)));
    }

    /// @dev Low-level EE admin call, bubbling the inner revert reason on failure.
    function _eeCall(address ee, bytes memory data) internal {
        (bool ok, bytes memory ret) = ee.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice P5 override: seed an initial `LP_MARK` between oracle creation and the market build, so the reservoir
    ///         `setLTV`'s `getQuote` resolves. In production the CRE `LP_MARK` push overwrites this; the broadcaster
    ///         (the oracle's owner at birth) seeds it once here. Mark = LP_SEED_MARK (6-dp USD per 1e18 LP share);
    ///         default $1.00 — override to the chosen ICHI vault's real per-share value.
    function _phaseP5() internal override {
        d.lpOracle = new SzipReservoirLpOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER, BaseAddresses.USDC, i.validityWindow, i.polIchiVault
        );

        _seedLpMark(vm.envOr("LP_SEED_MARK", uint256(1e6)));

        (d.escrowVault, d.borrowVault, d.router) = new ReservoirMarketDeployer().deploy(
            ReservoirMarketDeployer.Params({
                factory: GenericFactory(BaseAddresses.EVAULT_FACTORY),
                evc: BaseAddresses.EVC,
                governor: address(d.timelock),
                lpToken: i.polIchiVault,
                usdc: BaseAddresses.USDC,
                lpOracle: address(d.lpOracle),
                irm: i.irm,
                engineSafe: d.sub.mainSafe,
                borrowLTV: i.borrowLTV,
                liqLTV: i.liqLTV
            })
        );

        if (i.polIchiVault != IEVault(d.escrowVault).asset()) revert SeamSharedLp();
    }

    /// @dev Push a single `LP_MARK` as the broadcaster: temporarily point the oracle's forwarder at `i.team` (the
    ///      broadcaster, which owns the just-created oracle), push, then restore the real CRE Forwarder.
    function _seedLpMark(uint256 mark) internal {
        d.lpOracle.setForwarderAddress(i.team);
        d.lpOracle.onReport("", abi.encode(d.lpOracle.LP_MARK(), abi.encode(mark, uint32(block.timestamp))));
        d.lpOracle.setForwarderAddress(BaseAddresses.CRE_KEYSTONE_FORWARDER);
    }
}
