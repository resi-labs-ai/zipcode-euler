// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {DeployZipcode} from "./DeployZipcode.s.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {ReservoirMarketDeployer} from "./ReservoirMarketDeployer.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";
import {SzipPerspectiveProbe} from "./SzipPerspectiveProbe.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @title DeployLocal — item-10 deploy against a LOCAL Base-mainnet-fork anvil
/// @notice Drives the full `DeployZipcode` orchestrator on a local `anvil --fork-url <BASE_RPC_URL>` node. It
///         provisions the six `(T)` stand-ins the orchestrator needs as ENV addresses (IRM, xALPHA mirror, EE pool,
///         base USDC market) plus the two live LP legs (the live HYDX ICHI vault + its Hydrex gauge — the matched
///         pair the module fork tests already use), pins the principals to anvil's deterministic dev accounts, and
///         runs phases P0..P9 in the same order `deploy()` does — all inside ONE team-broadcast.
///
/// @dev Run with the anvil acct[0] key (which becomes `i.team`, the Safe pre-validated `v==1` broadcaster):
///        anvil --fork-url $BASE_RPC_URL --fork-block-number 47096000 &
///        forge script script/DeployLocal.s.sol:DeployLocal --sig "runLocal()" \
///          --rpc-url http://127.0.0.1:8545 --broadcast \
///          --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --slow
///
///      `i`, `d` and the `_phaseP*` helpers are `internal` on `DeployZipcode` — this subclass reuses them directly,
///      bypassing `_loadInputs()` (env) in favour of the hardcoded local config below.
contract DeployLocal is DeployZipcode {
    // anvil deterministic dev accounts (default mnemonic) — principals only; none of these broadcast except acct[0].
    address internal constant ANVIL_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // team / broadcaster
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // godOwner
    address internal constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // creOperator
    address internal constant ANVIL_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // workflowAuthor
    address internal constant ANVIL_4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // erebor
    address internal constant ANVIL_5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; // treasurySafe

    // The matched live ICHI vault + its Hydrex ALM gauge (POL stand-ins for the module fork tests). The vault is the
    // live WETH/USDC ICHI ALM (pool 0x82dbe1834). The gauge MUST be the vault-keyed ALM gauge `Voter.gauges(vault)`
    // (0x4328CE8A), NOT `Voter.gauges(pool)` — the per-pool CL gauge rejects ICHI ALM shares (reverts 0x87c5d02a; the
    // staking token is the ALM wrapper, not the raw pool position). Verified on the fork: addLiquidity → stake works
    // against 0x4328CE8A; the prior 0xAC396Cab was the HYDX/USDC *pool* gauge — a mismatched pair. (Both gauges are
    // alive; the bug was wiring, not a killed gauge.)
    address internal constant LIVE_ICHI_VAULT = 0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad;
    address internal constant LIVE_HYDREX_GAUGE = 0x4328CE8ADC23F1c4E5A3049F63Ffbdd8e73F99Ce;

    function runLocal() external {
        _loadLocalInputs();

        vm.startBroadcast();
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
        _configureEulerEarn(); // real-EE curator/allocator config (needs adapter[P1], warehouse[P4], borrowVault[P5])
        vm.stopBroadcast();
    }

    /// @notice Pin principals + numeric knobs (mirrors `.env.example`). The `(T)` addresses are left zero here and set
    ///         by `_provisionStandins()` inside the broadcast.
    function _loadLocalInputs() internal {
        i.team = ANVIL_0;
        i.godOwner = ANVIL_1;
        i.creOperator = ANVIL_2;
        i.workflowAuthor = ANVIL_3;
        i.erebor = ANVIL_4;
        i.treasurySafe = ANVIL_5;
        i.saltNonce = 1;
        i.workflowId = bytes32(uint256(1)); // non-zero (identity pre-gate)

        // live LP legs (matched pair)
        i.polIchiVault = LIVE_ICHI_VAULT;
        i.polGauge = LIVE_HYDREX_GAUGE;

        // numeric knobs (mirror .env.example)
        i.validityWindow = 31_536_000;
        i.W = 3600;
        i.maxAge = 86_400;
        i.maxDeviationBps = 1000;
        i.tvlCap = 100_000_000e18;
        i.recoveryFloor = 0.5e18;
        i.borrowCap = 1_000_000e6;
        i.borrowLTV = 8000;
        i.liqLTV = 9000;
        i.dBps = 100;
        i.buybackCap = 1_000_000e18;
        // SzAlphaRateOracle immutables — keep in lockstep with DeployMainnet (8x-02 fixtures: 6h/30d/500%).
        i.rateMaxStaleness = 6 hours;
        i.rateWindow = 30 days;
        i.rateAprCap = 50_000;
    }

    /// @notice Provision the stand-ins inside the broadcast. The EE pool + base USDC market are REAL contracts (a live
    ///         EulerEarn pool + a real EVK USDC vault); only the IRM (a real 0%-rate contract) and xALPHA (an inherent
    ///         cross-chain stand-in — no real Base asset exists pre-bridge) are local. Collateral/Proof-of-Value stays
    ///         mocked per §17. CoW solver + CRE DON are simulated at smoke-time (the contracts they hit are real).
    function _provisionStandins() internal {
        i.irm = address(new ZeroIRM());
        i.xAlphaMirror = address(new MockERC20("Zipcode xALPHA mirror", "xALPHA", 18));

        // REAL no-borrow USDC resting market — the EE supply-queue head. A bare EVK proxy (asset=USDC, no oracle/uoa
        // => supply-only). EVK-factory proxies pass the EulerEarn "EVK Factory Perspective", so EE will onboard it.
        address baseMkt = GenericFactory(BaseAddresses.EVAULT_FACTORY).createProxy(
            address(0), false, abi.encodePacked(BaseAddresses.USDC, address(0), address(0))
        );
        IEVault(baseMkt).setHookConfig(address(0), 0);
        i.baseUsdcMarket = baseMkt;

        // REAL EulerEarn senior pool off the LIVE factory. owner = team; timelock 0 => immediate cap config below.
        (bool ok, bytes memory ret) = BaseAddresses.EULER_EARN_FACTORY.call(
            abi.encodeWithSignature(
                "createEulerEarn(address,uint256,address,string,string,bytes32)",
                i.team, uint256(0), BaseAddresses.USDC, "Zipcode Senior USDC", "zSNR", bytes32(i.saltNonce)
            )
        );
        require(ok, "createEulerEarn failed");
        i.eePool = abi.decode(ret, (address));
    }

    /// @notice The EE curator runbook the base deploy intentionally omits (admin ABI not compiled). Run as the EE
    ///         owner (team): set fee recipient + 0 fee, onboard the resting USDC market + the reservoir borrow vault
    ///         (both EVK-factory proxies => perspective-verified), point the supply queue at the resting market, then
    ///         hand curator (which also satisfies the allocator role) to the venue adapter so `openLine` can onboard
    ///         per-line vaults and `fund` can reallocate at origination.
    function _configureEulerEarn() internal {
        address ee = i.eePool;
        uint256 capMax = type(uint136).max;

        // fee defaults to 0 (setFee(0) reverts AlreadySet); set only the recipient so a future non-zero fee routes
        // lending yield to the warehouse Safe (treasury).
        _eeCall(ee, abi.encodeWithSignature("setFeeRecipient(address)", d.warehouse.safe));

        _eeCall(ee, abi.encodeWithSignature("submitCap(address,uint256)", i.baseUsdcMarket, capMax));
        _eeCall(ee, abi.encodeWithSignature("acceptCap(address)", i.baseUsdcMarket));
        _eeCall(ee, abi.encodeWithSignature("submitCap(address,uint256)", d.borrowVault, capMax));
        _eeCall(ee, abi.encodeWithSignature("acceptCap(address)", d.borrowVault));

        address[] memory q = new address[](1);
        q[0] = i.baseUsdcMarket;
        _eeCall(ee, abi.encodeWithSignature("setSupplyQueue(address[])", q));

        _eeCall(ee, abi.encodeWithSignature("setCurator(address)", address(d.adapter)));

        // Deploy-time perspective probe. Build a throwaway vault with the SAME shape `openLine`
        // mints for a credit line and assert the EE factory's CONFIGURED perspective accepts it (reach the factory via
        // `creator()`). The live perspective is provenance-only so this passes today; its value is failing LOUDLY at
        // deploy if a FUTURE external perspective swap (e.g. an ungoverned-only perspective) would reject the
        // governed+hooked line vault and brick origination — instead of an opaque mid-`openLine` revert. The probe lien
        // is a throwaway 18-dp token (`i.polIchiVault`); the perspective never resolves the oracle so the choice is
        // immaterial to the result.
        new SzipPerspectiveProbe().assertLineVaultAllowed(
            GenericFactory(BaseAddresses.EVAULT_FACTORY),
            ee,
            BaseAddresses.EVC,
            BaseAddresses.USDC,
            address(d.registry),
            i.irm,
            address(d.hook),
            i.polIchiVault
        );
    }

    /// @dev Low-level EE admin call (the EulerEarn admin ABI is deliberately not compiled into the repo), bubbling the
    ///      inner revert reason on failure.
    function _eeCall(address ee, bytes memory data) internal {
        (bool ok, bytes memory ret) = ee.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice P5 override: seed an initial `LP_MARK` between oracle creation and the market build, so the reservoir
    ///         `setLTV`'s `getQuote` resolves. In production the CRE `LP_MARK` push does this; here the broadcaster
    ///         (the oracle's owner at birth) seeds it by briefly pointing the forwarder at itself.
    function _phaseP5() internal override {
        // 23. LP oracle.
        d.lpOracle = new SzipReservoirLpOracle(
            BaseAddresses.CRE_KEYSTONE_FORWARDER, BaseAddresses.USDC, i.validityWindow, i.polIchiVault
        );

        // seed an initial mark: $1.00 per 1e18 LP share (6-dp quote).
        _seedLpMark(1e6);

        // 24. reservoir market (governor = the Timelock; engineSafe = the main basket Safe).
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

        // 25. shared-LP invariant: POL_ICHI_VAULT == escrow.asset() (seam #4).
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

// ============================================================================ local stand-in mocks

/// @notice A zero-rate IRM (EVK `IIRM` face) — installed on the reservoir borrow vault.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A minimal 18-dp ERC20 stand-in for the Base xALPHA leg (NavOracle reads `balanceOf`; SellModule swaps it).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

