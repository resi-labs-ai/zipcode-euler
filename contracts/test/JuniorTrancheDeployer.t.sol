// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

import {JuniorTrancheDeployer} from "../script/JuniorTrancheDeployer.s.sol";
import {ReservoirMarketDeployer} from "../script/ReservoirMarketDeployer.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";

import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

// =========================================================================== mocks

/// @dev Minimal configurable-decimals ERC20 (the freeze-leg / token stand-ins). Mirrors DurationFreezeModule.t.sol.
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amt) public {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev A MockERC20 that ALSO exposes `exchangeRate()` (the xAlpha LST leg the NAV oracle marks).
contract MockXAlphaToken is MockERC20 {
    uint256 public exchangeRate = 1e18;

    constructor(uint8 d) MockERC20(d) {}
}

/// @dev A MockERC20 that ALSO exposes `discount()` (the oHYDX intrinsic-mark leg) + `paymentToken()` (ExerciseModule
///      reads it live at setUp).
contract MockOHydxToken is MockERC20 {
    uint256 public discount;
    address public paymentToken;

    constructor(uint8 d, uint256 disc, address paymentToken_) MockERC20(d) {
        discount = disc;
        paymentToken = paymentToken_;
    }
}

/// @dev Settable EulerEarn stand-in (the §8.2 senior pool) — the same shape as DurationFreezeModule.t.sol's mock.
contract MockEulerEarn {
    uint256 public sharesOf;
    uint256 public assetsPerShareBacking;
    uint256 public free;

    function setBacking(uint256 shares, uint256 totalBacking, uint256 free_) external {
        sharesOf = shares;
        assetsPerShareBacking = totalBacking;
        free = free_;
    }

    function balanceOf(address) external view returns (uint256) {
        return sharesOf;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares == 0 ? 0 : assetsPerShareBacking;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return free;
    }
}

/// @dev A minimal 18-dp ERC20 stand-in for the ICHI LP share (the §4.5.1 stand-in posture; mirrors
///      ReservoirLoopModule.t.sol's MockLpToken). ALSO exposes `token0()`/`token1()` — the ICHI-vault legs the
///      `LpStrategyModule.setUp` reads LIVE off the vault.
contract MockLpToken {
    string public constant name = "Mock ICHI LP";
    string public constant symbol = "mLP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public token0;
    address public token1;

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A minimal Hydrex ALM gauge stand-in: HarvestVoteModule.setUp reads `rewardToken()` LIVE off the gauge (the
///      `exerciseVe` target). The real per-pool gauge rejects the mock LP wrapper shares, so the §4.5.1 stand-in
///      posture applies here too.
contract MockGauge {
    address public rewardToken;

    constructor(address rewardToken_) {
        rewardToken = rewardToken_;
    }
}

/// @dev A zero-rate IRM (IIRM face) for the reservoir borrow vault — mirrors ReservoirLoopModule.t.sol's ZeroIRM.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev A minimal venue adapter stand-in: the registry topology assert reads `ISeniorVenue(adapter).seniorPool() ==
///      eePool` (clause 6, the warehouse-side input CTR-06c supplies; CTR-10b made it venue-neutral). The real
///      EulerVenueAdapter exposes the same getter; this stand-in models that side without building the full venue spine.
contract MockAdapter {
    address public seniorPool;

    constructor(address eePool_) {
        seniorPool = eePool_;
    }
}

// =========================================================================== test

/// @notice CTR-06b fork test (D3). On `_selectBaseFork()` (live BaalAndVaultSummoner + live EVK/EVC): inject mock NAV
///         legs + a MockEulerEarn (eePool) + a MockLpToken (polIchiVault) + the reservoir escrow/borrow vaults built
///         via the REAL `ReservoirMarketDeployer` over the live EVK + mock LP, run `deploy(...)`, and assert: (a) the
///         deploy did not revert closed / the seams hold; (b) every OZ-ownable owner is the Timelock, each engine
///         module owner is the Timelock, both Safes owned by `team` and NOT the deployer instance; (c) the returned
///         handles satisfy `SiloRegistry.addSilo` topology clauses 1–5 (with a warehouse-side adapter/eePool/
///         warehouseSafe) from a pranked Timelock; (d) the non-commingling assert holds.
contract JuniorTrancheDeployerTest is ForkConfig {
    // -- actors --
    address internal team = makeAddr("teamMultisig");
    address internal creOperator = makeAddr("creOperator");
    address internal warehouseSafe = makeAddr("warehouseSafe");
    address internal curator = makeAddr("curator");
    address internal treasurySafe = makeAddr("treasurySafe");
    address internal workflowAuthor = makeAddr("workflowAuthor");
    address internal rateOracle = makeAddr("rateOracle"); // a shared hub input (never owned/transferred here)
    bytes32 internal workflowId = keccak256("zipcode.cre.workflow.junior");

    uint256 internal constant SALT = uint256(keccak256("zipcode.junior.ctr06b.salt.a"));

    // -- roots / hub --
    TimelockController internal timelock;

    // -- mocks --
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockXAlphaToken internal xalpha;
    MockERC20 internal hydx;
    MockOHydxToken internal ohydx;
    MockEulerEarn internal ee;
    MockLpToken internal lp;
    MockGauge internal gauge;
    ZeroIRM internal irm;

    // -- reservoir --
    address internal escrowVault;
    address internal borrowVault;

    function setUp() public {
        _selectBaseFork();

        // a real Timelock (the OZ-ownable + engine-module handoff target).
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(2 days, proposers, executors, address(this));

        // mock NAV legs (zip 18-dp, usdc 6-dp, xalpha 18-dp, hydx 18-dp, ohydx 18-dp).
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockXAlphaToken(18);
        hydx = new MockERC20(18);
        ohydx = new MockOHydxToken(18, 30, address(usdc)); // 30% exercise discount; paymentToken = USDC mock
        ee = new MockEulerEarn();
        lp = new MockLpToken();
        lp.setTokens(address(zip), address(usdc)); // the ICHI-vault legs LpStrategyModule.setUp reads live
        gauge = new MockGauge(address(ohydx)); // HarvestVoteModule.setUp reads gauge.rewardToken() live
        irm = new ZeroIRM();

        // reservoir market: real ReservoirMarketDeployer over the live EVK + a CRE-fed LP oracle (mark pushed so the
        // deployer's setLTV getQuote resolves), governor = the Timelock. polIchiVault == escrowVault.asset() (seam #4).
        SzipReservoirLpOracle lpOracle =
            new SzipReservoirLpOracle(BaseAddresses.CRE_KEYSTONE_FORWARDER, address(usdc), 1 days, address(lp));
        lpOracle.renounceOwnership();
        _pushLpMark(lpOracle, 1e6); // $1.00 per LP share (6-dp USDC quote)

        ReservoirMarketDeployer dep = new ReservoirMarketDeployer();
        (escrowVault, borrowVault,) = dep.deploy(
            ReservoirMarketDeployer.Params({
                factory: GenericFactory(BaseAddresses.EVAULT_FACTORY),
                evc: BaseAddresses.EVC,
                governor: address(timelock),
                lpToken: address(lp),
                usdc: address(usdc),
                lpOracle: address(lpOracle),
                irm: address(irm),
                engineSafe: makeAddr("reservoirEngineSafePlaceholder"),
                borrowLTV: 0.7e4,
                liqLTV: 0.8e4
            })
        );
    }

    function _pushLpMark(SzipReservoirLpOracle o, uint256 mark) internal {
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(mark, uint32(block.timestamp)));
        vm.prank(BaseAddresses.CRE_KEYSTONE_FORWARDER);
        o.onReport("", report);
    }

    function _params() internal view returns (JuniorTrancheDeployer.JuniorParams memory) {
        return JuniorTrancheDeployer.JuniorParams({
            timelock: address(timelock),
            team: team,
            creOperator: creOperator,
            saltNonce: SALT,
            workflowAuthor: workflowAuthor,
            workflowId: workflowId,
            zipUSD: address(zip),
            rateOracle: rateOracle,
            eePool: address(ee),
            warehouseSafe: warehouseSafe,
            escrowVault: escrowVault,
            borrowVault: borrowVault,
            usdc: address(usdc),
            xAlphaMirror: address(xalpha),
            hydx: address(hydx),
            oHydx: address(ohydx),
            polIchiVault: address(lp),
            polGauge: address(gauge),
            treasurySafe: treasurySafe,
            W: 4 hours,
            maxAge: 1 hours,
            maxDeviationBps: 1000,
            tvlCap: 10_000_000e18,
            dBps: 50,
            buybackCap: 1_000_000e18,
            borrowCap: 1_000_000e6,
            recoveryFloor: 0.1e18
        });
    }

    /// @notice (a) deploy succeeds (every seam holds — a closed seam would revert), and the engine modules wired live.
    function test_deploy_seams_hold() public {
        JuniorTrancheDeployer deployer = new JuniorTrancheDeployer();
        JuniorTrancheDeployer.JuniorTranche memory t = deployer.deploy(_params());

        assertTrue(t.baal != address(0), "baal deployed");
        assertTrue(t.mainSafe != address(0) && t.sidecar != address(0), "safes deployed");
        assertTrue(t.mainSafe != t.sidecar, "main != sidecar");
        // share token wired both ways (NAV + Gate).
        assertEq(address(t.gate.shareToken()), address(t.szip), "gate share token");
        assertEq(t.navOracle.shareToken(), address(t.szip), "nav share token");
        // engine-safe denominator-exclusion seam holds across NAV/Gate/buyBurn.
        assertEq(t.navOracle.engineSafe(), t.mainSafe, "nav engineSafe == mainSafe");
        assertEq(t.gate.engineSafe(), t.mainSafe, "gate engineSafe == mainSafe");
        // loss side closed.
        assertEq(t.escrow.coordinator(), address(t.coord), "escrow.coordinator");
        // deposit-module gate wired (step 4) + warehouse pinned.
        assertEq(t.depositModule.gate(), address(t.gate), "deposit module gate");
        assertEq(t.depositModule.warehouse(), warehouseSafe, "deposit module warehouse");
        // shaman grant landed: totalShares stays 0 (governance-inert).
        assertEq(IBaalShares(t.baal).totalShares(), 0, "totalShares 0");
    }

    /// @notice (b) OZ-ownable owners = Timelock, engine module owners = Timelock, both Safes = team & NOT the deployer.
    function test_ownership_handoff() public {
        JuniorTrancheDeployer deployer = new JuniorTrancheDeployer();
        JuniorTrancheDeployer.JuniorTranche memory t = deployer.deploy(_params());

        address tl = address(timelock);
        // OZ-ownable -> Timelock.
        assertEq(Ownable(address(t.navOracle)).owner(), tl, "navOracle -> TL");
        assertEq(Ownable(address(t.gate)).owner(), tl, "gate -> TL");
        assertEq(Ownable(address(t.szip)).owner(), tl, "szip -> TL");
        assertEq(Ownable(address(t.escrow)).owner(), tl, "escrow -> TL");
        assertEq(Ownable(address(t.coord)).owner(), tl, "coord -> TL");

        // engine modules already Timelock-owned from setUp (owner_ == p.timelock).
        assertEq(Ownable(t.durationFreeze).owner(), tl, "freeze owner TL");
        assertEq(Ownable(t.buyBurn).owner(), tl, "buyBurn owner TL");
        assertEq(Ownable(t.reservoirLoop).owner(), tl, "reservoirLoop owner TL");
        assertEq(Ownable(t.lpStrategy).owner(), tl, "lpStrategy owner TL");
        assertEq(Ownable(t.harvestVote).owner(), tl, "harvestVote owner TL");
        assertEq(Ownable(t.exercise).owner(), tl, "exercise owner TL");
        assertEq(Ownable(t.sell).owner(), tl, "sell owner TL");
        assertEq(Ownable(t.recycle).owner(), tl, "recycle owner TL");

        // both Safes -> team, NOT the throwaway deployer instance.
        assertTrue(ISafe(t.mainSafe).isOwner(team), "main owned by team");
        assertTrue(ISafe(t.sidecar).isOwner(team), "sidecar owned by team");
        assertFalse(ISafe(t.mainSafe).isOwner(address(deployer)), "main NOT owned by deployer");
        assertFalse(ISafe(t.sidecar).isOwner(address(deployer)), "sidecar NOT owned by deployer");

        // the shared rate oracle was never transferred (we never owned it) — it stays a plain input address.
        assertEq(t.navOracle.xAlphaRateOracle(), rateOracle, "rate oracle wired (not owned)");
    }

    /// @notice (c) the returned handles satisfy SiloRegistry topology clauses 1–5 via a real addSilo from the Timelock.
    function test_addSilo_topology_clauses_1_to_5() public {
        JuniorTrancheDeployer deployer = new JuniorTrancheDeployer();
        JuniorTrancheDeployer.JuniorTranche memory t = deployer.deploy(_params());

        // a real SiloRegistry — ctor sets Ownable(msg.sender) = this test; re-home to the Timelock for the
        // onlyOwner `addSilo` (matching the §17 production posture: the registry is Timelock-owned).
        SiloRegistry registry = new SiloRegistry(creOperator);
        registry.transferOwnership(address(timelock));

        // the warehouse-side adapter (clause 6) — CTR-06c's input: ISeniorVenue(adapter).seniorPool() == eePool.
        MockAdapter adapter = new MockAdapter(address(ee));

        SiloRegistry.SiloConfig memory cfg = SiloRegistry.SiloConfig({
            adapter: address(adapter),
            warehouseSafe: warehouseSafe,
            eePool: address(ee),
            juniorBasket: t.mainSafe,
            escrow: address(t.escrow),
            defaultCoordinator: address(t.coord),
            navOracle: address(t.navOracle),
            freeze: t.durationFreeze,
            curator: curator
        });

        vm.prank(address(timelock));
        registry.addSilo(keccak256("silo-1"), cfg); // reverts SiloMiswired if any clause 1–6 fails

        SiloRegistry.Silo memory s = registry.getSilo(keccak256("silo-1"));
        assertEq(s.freeze, t.durationFreeze, "freeze admitted");
        assertEq(s.navOracle, address(t.navOracle), "navOracle admitted");
        assertTrue(s.active, "silo active");
    }

    /// @notice (d) §2 non-commingling: main AND sidecar are both distinct from the warehouse Safe.
    function test_non_commingling() public {
        JuniorTrancheDeployer deployer = new JuniorTrancheDeployer();
        JuniorTrancheDeployer.JuniorTranche memory t = deployer.deploy(_params());

        assertTrue(t.mainSafe != warehouseSafe, "main != warehouse");
        assertTrue(t.sidecar != warehouseSafe, "sidecar != warehouse");
    }
}

/// @notice Minimal Baal totalShares read for the governance-inertness assert.
interface IBaalShares {
    function totalShares() external view returns (uint256);
}
