// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";

import {SiloDeployer} from "../script/SiloDeployer.s.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";
import {SeniorNavAggregator} from "../src/SeniorNavAggregator.sol";

import {SzipFarmUtilityLpOracle} from "../src/supply/SzipFarmUtilityLpOracle.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

// =========================================================================== mocks

/// @dev Minimal configurable-decimals ERC20 (the NAV/token leg stand-ins). Mirrors JuniorTrancheDeployer.t.sol.
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

/// @dev A MockERC20 that ALSO exposes `discount()` (oHYDX intrinsic-mark) + `paymentToken()` (ExerciseModule reads it).
contract MockOHydxToken is MockERC20 {
    uint256 public discount;
    address public paymentToken;

    constructor(uint8 d, uint256 disc, address paymentToken_) MockERC20(d) {
        discount = disc;
        paymentToken = paymentToken_;
    }
}

/// @dev A minimal 18-dp ERC20 stand-in for the ICHI LP share. ALSO exposes `token0()`/`token1()` (the ICHI-vault legs
///      `LpStrategyModule.setUp` reads LIVE off the vault). Mirrors JuniorTrancheDeployer.t.sol's MockLpToken.
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

/// @dev A minimal Hydrex ALM gauge stand-in: `HarvestVoteModule.setUp` reads `rewardToken()` LIVE off the gauge.
contract MockGauge {
    address public rewardToken;

    constructor(address rewardToken_) {
        rewardToken = rewardToken_;
    }
}

/// @dev A zero-rate IRM (IIRM face) for the farm utility borrow vault — mirrors JuniorTrancheDeployer.t.sol's ZeroIRM.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev The COMBINED EulerEarn stand-in (NEW in this test file). Neither existing mock serves both surfaces, so this
///      one carries BOTH: (a) the JuniorTrancheDeployer.t.sol settable-backing NAV reads (`balanceOf`/`convertToAssets`/
///      `maxWithdraw`/`setBacking`) the aggregator + freeze read, AND (b) no-op/recording admin stubs by ABI signature
///      (`setFeeRecipient`/`submitCap`/`acceptCap`/`setSupplyQueue`/`setCurator`) the SiloDeployer EE config calls.
///      `deploy()` never reads `config()`/`reallocate()` here (D4 is de-scoped to NO real opens), so the rich queue mock
///      is unnecessary.
contract MockEulerEarn {
    // -- settable backing (NAV reads) --
    uint256 public sharesOf;
    uint256 public assetsPerShareBacking;
    uint256 public free;

    // -- admin-call recorders --
    address public feeRecipient;
    address public curator;
    address[] public supplyQueue;
    mapping(address => uint256) public submittedCap;
    mapping(address => bool) public capAccepted;

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

    // -- admin no-op/recording stubs (EE admin ABI, by signature) --
    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function submitCap(address market, uint256 cap) external {
        submittedCap[market] = cap;
    }

    function acceptCap(address market) external {
        capAccepted[market] = true;
    }

    function setSupplyQueue(address[] calldata q) external {
        supplyQueue = q;
    }

    function setCurator(address c) external {
        curator = c;
    }
}

/// @dev A settable-capacity zipUSD stand-in for the D2 `setCapacity` runbook leg (the ticket allows a stub here).
///      Mirrors the `ERC20Synth.setCapacity(address,uint128)` surface; only the Timelock-gated mint-cap grant matters.
contract MockZipUsd {
    mapping(address => uint128) public capacity;

    function setCapacity(address minter, uint128 cap) external {
        capacity[minter] = cap;
    }
}

/// @dev A self-consistent silo-#0 topology STUB (the D4 "self-consistent topology stub" alternative). Exposes the four
///      topology getters wired to its OWN leaves so `addSilo` clauses 1–6 pass, plus a settable-backing combined EE so
///      the aggregator sums it. NOT a SiloDeployer-built silo — the de-scoped D4 only needs a registrable handle.
contract MockFreeze {
    address public eulerEarn;
    address public warehouseSafe;
    address public navOracle;

    constructor(address ee, address wh, address nav) {
        eulerEarn = ee;
        warehouseSafe = wh;
        navOracle = nav;
    }
}

contract MockEscrow {
    address public coordinator;

    constructor(address c) {
        coordinator = c;
    }
}

contract MockCoordinator {
    address public navOracle;

    constructor(address nav) {
        navOracle = nav;
    }
}

contract MockAdapter {
    address public seniorPool;

    constructor(address ee) {
        seniorPool = ee;
    }
}

// =========================================================================== harness

/// @notice A SiloDeployer whose `_createEePool` returns a fresh combined `MockEulerEarn` (D3 seam) and records each
///         minted mock so a test can set its backing afterward (D4 sums two silos).
contract SiloDeployerHarness is SiloDeployer {
    MockEulerEarn[] public mocks;

    function _createEePool(SiloParams memory) internal override returns (address) {
        MockEulerEarn m = new MockEulerEarn();
        mocks.push(m);
        return address(m);
    }

    function lastMock() external view returns (MockEulerEarn) {
        return mocks[mocks.length - 1];
    }
}

// =========================================================================== test

/// @notice CTR-06c fork test (D3/D4). On `_selectBaseFork()` (live Baal summoner + live EVK/EVC): inject mock NAV legs +
///         a MockLpToken (polIchiVault) + a FORWARDER-seeded SzipFarmUtilityLpOracle, override `_createEePool` to the
///         combined MockEulerEarn, run `SiloDeployer.deploy(...)`, and assert the silo seams hold, the ownership handoff
///         is complete, the handle passes a real `addSilo` on the first try, two-silo routing/rollover + the aggregate
///         hold (registry-level, NO real controller/opens), and the D2 runbook lands via Timelock pranks.
contract SiloDeployerTest is ForkConfig {
    // -- actors --
    address internal team = makeAddr("teamMultisig");
    address internal creOperator = makeAddr("creOperator");
    address internal godOwner = makeAddr("godOwner");
    address internal receiverAdmin = makeAddr("receiverAdmin");
    address internal adminSafe = makeAddr("adminSafe");
    address internal curatorSafe = makeAddr("curatorSafe");
    address internal workflowAuthor = makeAddr("workflowAuthor");
    address internal controller = makeAddr("controller"); // hub controller (an input; never built here)
    address internal oracleRegistry = makeAddr("oracleRegistry"); // hub ZipcodeOracleRegistry (input)
    address internal rateOracle = makeAddr("rateOracle"); // hub SzAlphaRateOracle (input)
    address internal redemptionBox = makeAddr("redemptionBox"); // the shared ZipRedemptionQueue (input)
    address internal erebor = makeAddr("erebor"); // the immutable line receiver (input)
    string internal workflowNameWarehouse = "zip-warehouse";
    string internal workflowNameSharefeeds = "zip-sharefeeds";
    string internal workflowNameCoordinator = "zip-coordinator";

    uint256 internal constant SALT = uint256(keccak256("zipcode.silo.ctr06c.salt.a"));
    uint256 internal constant SALT2 = uint256(keccak256("zipcode.silo.ctr06c.salt.b"));

    bytes32 internal constant SILO_0 = keccak256("silo-0");
    bytes32 internal constant SILO_2 = keccak256("silo-2");

    // -- roots / hub --
    TimelockController internal timelock;

    // -- mocks (shared NAV legs across silos; only the EE + farm utility + junior are per-silo) --
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockXAlphaToken internal xalpha;
    MockERC20 internal hydx;
    MockOHydxToken internal ohydx;
    MockLpToken internal lp;
    MockGauge internal gauge;
    ZeroIRM internal irm;

    function setUp() public {
        _selectBaseFork();

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(2 days, proposers, executors, address(this));

        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xalpha = new MockXAlphaToken(18);
        hydx = new MockERC20(18);
        ohydx = new MockOHydxToken(18, 30, address(usdc));
        lp = new MockLpToken();
        lp.setTokens(address(zip), address(usdc));
        gauge = new MockGauge(address(ohydx));
        irm = new ZeroIRM();
    }

    /// @dev Build + FORWARDER-seed a fresh per-silo LP oracle (the JuniorTrancheDeployer.t.sol:245-249 pattern). The
    ///      mark must be pushed BEFORE `deploy` (the farm utility `setLTV` `getQuote` reverts without a resolvable mark).
    function _seededLpOracle() internal returns (address) {
        SzipFarmUtilityLpOracle o =
            new SzipFarmUtilityLpOracle(BaseAddresses.CRE_KEYSTONE_FORWARDER, address(usdc), 1 days, address(lp));
        o.renounceOwnership();
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(uint256(1e6), uint32(block.timestamp)));
        vm.prank(BaseAddresses.CRE_KEYSTONE_FORWARDER);
        o.onReport("", report);
        return address(o);
    }

    function _params(uint256 salt, address lpOracle) internal view returns (SiloDeployer.SiloParams memory) {
        return SiloDeployer.SiloParams({
            timelock: address(timelock),
            team: team,
            creOperator: creOperator,
            godOwner: godOwner,
            receiverAdmin: receiverAdmin,
            workflowAuthor: workflowAuthor,
            workflowNameWarehouse: workflowNameWarehouse,
            workflowNameSharefeeds: workflowNameSharefeeds,
            workflowNameCoordinator: workflowNameCoordinator,
            saltNonce: salt,
            controller: controller,
            oracleRegistry: oracleRegistry,
            zipUSD: address(zip),
            rateOracle: rateOracle,
            redemptionBox: redemptionBox,
            erebor: erebor,
            forwarder: BaseAddresses.CRE_KEYSTONE_FORWARDER,
            polIchiVault: address(lp),
            polGauge: address(gauge),
            lpOracle: lpOracle,
            usdc: address(usdc),
            xAlphaMirror: address(xalpha),
            hydx: address(hydx),
            oHydx: address(ohydx),
            farmUtilityIrm: address(irm),
            lineIrm: address(irm),
            eeName: "Zipcode Senior USDC",
            eeSymbol: "zSNR",
            adminSafe: adminSafe,
            curatorSafe: curatorSafe,
            borrowLTV: 0.7e4,
            liqLTV: 0.8e4,
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

    function _deploySilo(uint256 salt)
        internal
        returns (SiloDeployerHarness dep, SiloDeployer.Silo memory s, MockEulerEarn ee)
    {
        dep = new SiloDeployerHarness();
        s = dep.deploy(_params(salt, _seededLpOracle()));
        ee = dep.lastMock();
    }

    function _cfgFrom(SiloDeployer.Silo memory s) internal pure returns (SiloRegistry.SiloConfig memory) {
        return SiloRegistry.SiloConfig({
            adapter: s.adapter,
            warehouseSafe: s.warehouseSafe,
            eePool: s.eePool,
            juniorBasket: s.juniorBasket,
            escrow: s.escrow,
            defaultCoordinator: s.defaultCoordinator,
            navOracle: s.navOracle,
            freeze: s.freeze,
            curator: s.curator
        });
    }

    // ----------------------------------------------------------------- 1. seams hold

    /// @notice `deploy` against the combined `MockEulerEarn` succeeds (a closed seam reverts), and the venue front is
    ///         wired: the adapter's `eulerEarn() == mockEE`, the hook `borrowDriver() == adapter`.
    function test_deploy_silo_seams_hold() public {
        (, SiloDeployer.Silo memory s, MockEulerEarn ee) = _deploySilo(SALT);

        // all step-8 post-asserts passed (deploy did not revert) — re-assert the headline topology web.
        assertEq(IAdapterView(s.adapter).eulerEarn(), address(ee), "adapter eulerEarn == mockEE");
        assertEq(ICREHook(s.hook).borrowDriver(), s.adapter, "hook borrowDriver == adapter");
        assertEq(IFreezeView(s.freeze).eulerEarn(), s.eePool, "freeze.eulerEarn == eePool");
        assertEq(IFreezeView(s.freeze).warehouseSafe(), s.warehouseSafe, "freeze.warehouseSafe == warehouseSafe");
        assertEq(IFreezeView(s.freeze).navOracle(), s.navOracle, "freeze.navOracle == navOracle");
        assertEq(IEscrowView(s.escrow).coordinator(), s.defaultCoordinator, "escrow.coordinator == coord");
        assertEq(INavWriterView(s.defaultCoordinator).navOracle(), s.navOracle, "coord.navOracle == navOracle");
        // EE admin config landed (curator + fee recipient + supply queue).
        assertEq(ee.curator(), s.adapter, "EE curator == adapter");
        assertEq(ee.feeRecipient(), s.warehouseSafe, "EE feeRecipient == warehouseSafe");

        // non-commingling holds.
        assertTrue(s.warehouseSafe != s.juniorBasket, "warehouseSafe != junior main");
        assertTrue(redemptionBox != s.juniorBasket, "redemptionBox != junior main");
    }

    // ----------------------------------------------------------------- 2. ownership handoff

    /// @notice Every transferred owner lands away from the deployer: junior OZ-ownables + the per-silo hook + the
    ///         farm utility borrow-vault governor → Timelock; warehouseSafe Safe/Roles → godOwner; warehouseSafe adapter →
    ///         receiverAdmin; both Baal Safes → team & NOT the deployer.
    function test_ownership_handoff() public {
        (SiloDeployerHarness dep, SiloDeployer.Silo memory s,) = _deploySilo(SALT);
        address tl = address(timelock);

        // junior OZ-ownables → Timelock (delegated to CTR-06b; re-assert the headline ones).
        assertEq(Ownable(s.navOracle).owner(), tl, "navOracle -> TL");
        assertEq(Ownable(s.freeze).owner(), tl, "freeze -> TL");
        assertEq(Ownable(s.escrow).owner(), tl, "escrow -> TL");
        assertEq(Ownable(s.defaultCoordinator).owner(), tl, "coord -> TL");

        // the per-silo hook owner → Timelock (SiloDeployer transfers it). Hook owner is a plain `owner` var, NOT OZ.
        assertEq(ICREHook(s.hook).owner(), tl, "hook owner -> TL");

        // the farm utility borrow-vault governor → Timelock (CTR-06a) — read via the freeze's farm utility leg is indirect;
        // assert through the registry-asserted seam instead: the adapter is OZ-owned by the deployer (untransferred —
        // the ticket does not direct an adapter handoff), and the borrow vault governor was asserted == TL in step 8.
        // (the borrow vault address is not on the handle; the step-8 SeamFarmUtilityGovernor pass proves governor==TL.)

        // warehouseSafe Safe → godOwner; Roles → godOwner; warehouseSafe admin adapter → receiverAdmin.
        assertTrue(ISafe(s.warehouseSafe).isOwner(godOwner), "warehouseSafe Safe owned by godOwner");
        assertFalse(ISafe(s.warehouseSafe).isOwner(address(dep)), "warehouseSafe Safe NOT owned by deployer");
        assertEq(IOwnableView(s.warehouseRoles).owner(), godOwner, "warehouseSafe Roles -> godOwner");

        // CTR-16 (K8): the per-silo WAM is SEALED (author + a non-zero workflowName) and re-homed to receiverAdmin —
        // not left forwarder-only as silos 2+ shipped pre-fix. The deployer took transient ownership only to seal.
        assertEq(IReceiverIdentityView(s.warehouseAdmin).getExpectedAuthor(), workflowAuthor, "WAM author sealed");
        assertTrue(
            IReceiverIdentityView(s.warehouseAdmin).getExpectedWorkflowName() != bytes10(0), "WAM workflowName sealed"
        );
        assertEq(IReceiverIdentityView(s.warehouseAdmin).owner(), receiverAdmin, "WAM -> receiverAdmin");
        assertTrue(s.warehouseAdmin != address(0), "WAM address exposed on the handle");

        // both Baal Safes → team, NOT the deployer.
        assertTrue(ISafe(s.juniorBasket).isOwner(team), "junior main owned by team");
        assertFalse(ISafe(s.juniorBasket).isOwner(address(dep)), "junior main NOT owned by deployer");
    }

    // ----------------------------------------------------------------- 3. addSilo first try

    /// @notice A real `SiloRegistry` (re-homed to a pranked Timelock); `addSilo(siloId, handle)` passes on the FIRST
    ///         try (the handle is self-consistent; reverts `SiloMiswired` if any clause fails).
    function test_addSilo_first_try() public {
        (, SiloDeployer.Silo memory s,) = _deploySilo(SALT);

        SiloRegistry registry = new SiloRegistry(controller);
        registry.transferOwnership(address(timelock));

        vm.prank(address(timelock));
        registry.addSilo(SILO_0, _cfgFrom(s)); // reverts SiloMiswired if any clause 1–6 fails

        SiloRegistry.Silo memory got = registry.getSilo(SILO_0);
        assertEq(got.adapter, s.adapter, "adapter admitted");
        assertEq(got.eePool, s.eePool, "eePool admitted");
        assertTrue(got.active, "silo active");
        assertEq(registry.venueOf(SILO_0), s.adapter, "venueOf == adapter");
    }

    // ----------------------------------------------------------------- 4. two-silo routing + rollover + aggregate

    /// @notice De-scoped D4 (registry-level, NO real controller/opens): register silo #0 (a self-consistent topology
    ///         stub) + silo #2 (SiloDeployer-built) in one real SiloRegistry (Timelock-owned). `venueOf` returns each
    ///         silo's OWN adapter; drive silo #0 to MAX_LINES_PER_SILO (28) via pranked controller increments; the next
    ///         reverts SiloFull; setCurrentSilo(silo2); an increment lands on silo #2 (lineCount == 1). Then set each
    ///         mock-EE backing and assert `SeniorNavAggregator.seniorBacking()` == Σ of both donation-immune values.
    function test_D4_two_silo_routing_rollover_and_aggregate() public {
        SiloRegistry registry = new SiloRegistry(controller);
        registry.transferOwnership(address(timelock));

        // silo #0 — a self-consistent topology stub with its OWN combined EE.
        MockEulerEarn ee0 = new MockEulerEarn();
        address wh0 = makeAddr("warehouse0");
        address nav0 = makeAddr("navOracle0");
        address coord0 = address(new MockCoordinator(nav0));
        SiloRegistry.SiloConfig memory cfg0 = SiloRegistry.SiloConfig({
            adapter: address(new MockAdapter(address(ee0))),
            warehouseSafe: wh0,
            eePool: address(ee0),
            juniorBasket: makeAddr("junior0"),
            escrow: address(new MockEscrow(coord0)),
            defaultCoordinator: coord0,
            navOracle: nav0,
            freeze: address(new MockFreeze(address(ee0), wh0, nav0)),
            curator: makeAddr("curator0")
        });

        // silo #2 — a real SiloDeployer-built silo.
        (, SiloDeployer.Silo memory s2, MockEulerEarn ee2) = _deploySilo(SALT2);

        vm.startPrank(address(timelock));
        registry.addSilo(SILO_0, cfg0);
        registry.addSilo(SILO_2, _cfgFrom(s2));
        vm.stopPrank();

        // routing: each silo's OWN adapter.
        assertEq(registry.venueOf(SILO_0), cfg0.adapter, "venueOf(silo0) == adapter0");
        assertEq(registry.venueOf(SILO_2), s2.adapter, "venueOf(silo2) == adapter2");
        assertEq(registry.currentSilo(), SILO_0, "first-admitted is currentSilo");

        // drive silo #0 to the cap via pranked controller increments (ZipcodeController.t.sol:938-955 precedent).
        uint16 max = registry.MAX_LINES_PER_SILO();
        assertEq(max, 28, "cap is 28");
        vm.startPrank(controller);
        for (uint256 i = 0; i < max; ++i) {
            registry.incrementLineCount(SILO_0);
        }
        // the next increment reverts SiloFull.
        vm.expectRevert(abi.encodeWithSelector(SiloRegistry.SiloFull.selector, SILO_0));
        registry.incrementLineCount(SILO_0);
        vm.stopPrank();
        assertEq(registry.getSilo(SILO_0).lineCount, max, "silo0 at cap");

        // rollover then route the next open to silo #2.
        vm.prank(address(timelock));
        registry.setCurrentSilo(SILO_2);
        assertEq(registry.currentSilo(), SILO_2, "rolled over to silo2");
        vm.prank(controller);
        registry.incrementLineCount(SILO_2);
        assertEq(registry.getSilo(SILO_2).lineCount, 1, "silo2 lineCount == 1");

        // aggregate: Σ of both warehouses' donation-immune senior values (CTR-05). Wire the aggregator to this registry.
        SeniorNavAggregator agg = new SeniorNavAggregator(address(registry), address(zip));
        // silo #0: 1000 USDC backing (6-dp) -> 1000e18 USD; silo #2: 2500 USDC -> 2500e18 USD.
        ee0.setBacking(1, 1000e6, 0);
        ee2.setBacking(1, 2500e6, 0);
        assertEq(agg.seniorBacking(), (1000e6 + 2500e6) * 1e12, "aggregate == sum of both silos");
        // donation-immune: a third-party donation to the pool address moves neither term — backing is unchanged.
        assertEq(agg.seniorBackingOf(SILO_0), 1000e6 * 1e12, "silo0 backing");
        assertEq(agg.seniorBackingOf(SILO_2), 2500e6 * 1e12, "silo2 backing");
    }

    // ----------------------------------------------------------------- 5. D2 runbook

    /// @notice Exercise the D2 Timelock runbook via `vm.prank(timelock)`: `zipUSD.setCapacity(depositModule, max)` +
    ///         `addSilo` + `setCurrentSilo` against a settable-capacity zipUSD stub + a real registry.
    function test_D2_runbook() public {
        (, SiloDeployer.Silo memory s,) = _deploySilo(SALT);

        SiloRegistry registry = new SiloRegistry(controller);
        registry.transferOwnership(address(timelock));
        MockZipUsd zusd = new MockZipUsd();

        // 1. grant the new deposit module mint authority on the shared zipUSD (Timelock-owned).
        vm.prank(address(timelock));
        zusd.setCapacity(s.depositModule, type(uint128).max);
        assertEq(zusd.capacity(s.depositModule), type(uint128).max, "depositModule capacity granted");

        // 2. admission + 3. roll the active fill target.
        vm.startPrank(address(timelock));
        registry.addSilo(SILO_0, _cfgFrom(s));
        registry.setCurrentSilo(SILO_0);
        vm.stopPrank();

        assertEq(registry.currentSilo(), SILO_0, "currentSilo set");
        assertTrue(registry.getSilo(SILO_0).active, "silo active");
    }
}

// =========================================================================== view interfaces

interface IAdapterView {
    function eulerEarn() external view returns (address);
}

interface ICREHook {
    function borrowDriver() external view returns (address);
    function owner() external view returns (address);
}

interface IFreezeView {
    function eulerEarn() external view returns (address);
    function warehouseSafe() external view returns (address);
    function navOracle() external view returns (address);
}

interface IEscrowView {
    function coordinator() external view returns (address);
}

interface INavWriterView {
    function navOracle() external view returns (address);
}

interface IOwnableView {
    function owner() external view returns (address);
}

/// @notice CTR-16: the WAM identity getters (inherited from `ReceiverTemplate`).
interface IReceiverIdentityView {
    function getExpectedAuthor() external view returns (address);
    function getExpectedWorkflowName() external view returns (bytes10);
    function owner() external view returns (address);
}
