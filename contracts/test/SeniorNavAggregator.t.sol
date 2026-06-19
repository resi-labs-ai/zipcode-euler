// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SiloRegistry} from "../src/SiloRegistry.sol";
import {SeniorNavAggregator} from "../src/SeniorNavAggregator.sol";

// =========================================================================================== mocks

/// @dev Topology stubs mirroring `SiloRegistry.t.sol` so the REAL admission topology assert passes.
contract MockFreeze {
    address public eulerEarn;
    address public warehouse;
    address public navOracle;

    constructor(address eePool_, address warehouseSafe_, address navOracle_) {
        eulerEarn = eePool_;
        warehouse = warehouseSafe_;
        navOracle = navOracle_;
    }
}

contract MockEscrow {
    address public coordinator;

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }
}

contract MockCoordinator {
    address public navOracle;

    constructor(address navOracle_) {
        navOracle = navOracle_;
    }
}

contract MockAdapter {
    address public seniorPool;

    constructor(address eePool_) {
        seniorPool = eePool_;
    }
}

/// @dev Settable-backing EulerEarn stand-in (the §8.2 senior pool), modeled on
///      `DurationFreezeModule.t.sol:107-130`. PER-ACCOUNT `balanceOf` so `balanceOf(warehouseSafe)` differs from a
///      donation minted to the `eePool` address. `convertToAssets` HONORS its share argument (donation-immune: a
///      donation that bumps a DIFFERENT account's shares does not change the warehouse's `convertToAssets` input).
///      `setBacking(account, shares, totalBacking, free)` drives any U.
contract MockEulerEarn {
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public backingOf; // convertToAssets(sharesOf[account]) for that account
    mapping(address => uint256) public freeOf; // maxWithdraw(account)

    /// @dev Set an account's position. `shares` is the share balance; `totalBacking` is what `convertToAssets(shares)`
    ///      returns; `free_` is `maxWithdraw(account)`.
    function setBacking(address account, uint256 shares, uint256 totalBacking, uint256 free_) external {
        sharesOf[account] = shares;
        backingOf[account] = totalBacking;
        freeOf[account] = free_;
    }

    function balanceOf(address account) external view returns (uint256) {
        return sharesOf[account];
    }

    /// @dev shares==0 -> 0; else resolve the account whose share balance equals `shares` and return its backing.
    ///      In these tests warehouse share balances are distinct, so the lookup is unambiguous.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (shares == 0) return 0;
        // The aggregator calls convertToAssets(balanceOf(warehouse)); map shares back to the configured backing.
        return _backingForShares(shares);
    }

    function maxWithdraw(address account) external view returns (uint256) {
        return freeOf[account];
    }

    // --- internal: the test configures backing keyed by account, but convertToAssets only gets `shares`. We track a
    //     shares->backing map alongside, written by setBacking via the account's share count. ---
    mapping(uint256 => uint256) internal _sharesToBacking;

    function _backingForShares(uint256 shares) internal view returns (uint256) {
        return _sharesToBacking[shares];
    }

    /// @dev Settable variant that also registers the shares->backing mapping convertToAssets needs.
    function setPosition(address account, uint256 shares, uint256 totalBacking, uint256 free_) external {
        sharesOf[account] = shares;
        backingOf[account] = totalBacking;
        freeOf[account] = free_;
        _sharesToBacking[shares] = totalBacking;
    }

    /// @dev A donation: mint shares to the POOL address (or any account) WITHOUT touching the warehouse's position.
    ///      Mirrors `DurationFreezeModule.t.sol:455-461` — the warehouse's convertToAssets/maxWithdraw are unchanged.
    function donateShares(address to, uint256 shares) external {
        sharesOf[to] += shares;
    }
}

contract SeniorNavAggregatorTest is Test {
    SiloRegistry internal reg;
    SeniorNavAggregator internal agg;

    address internal owner = address(this);
    address internal stranger = makeAddr("stranger");

    // zipUSD mock (ESynth stand-in: 18-dp, settable totalSupply)
    MockZipUsd internal zip;

    function setUp() public {
        reg = new SiloRegistry(makeAddr("controller"));
        zip = new MockZipUsd();
        agg = new SeniorNavAggregator(address(reg), address(zip));
    }

    // ----- helpers: admit a self-consistent silo whose eePool is a settable MockEulerEarn -----

    struct Silo {
        bytes32 id;
        MockEulerEarn ee;
        address warehouseSafe;
    }

    /// @dev Admit a self-consistent silo with a fresh MockEulerEarn pool + a fresh warehouse address.
    function _addSilo(string memory label) internal returns (Silo memory out) {
        MockEulerEarn ee = new MockEulerEarn();
        address warehouseSafe = makeAddr(string.concat(label, "-warehouse"));
        address navOracle = makeAddr(string.concat(label, "-oracle"));
        address juniorBasket = makeAddr(string.concat(label, "-junior"));
        address curator = makeAddr(string.concat(label, "-curator"));

        address coordinator_ = address(new MockCoordinator(navOracle));
        address escrow_ = address(new MockEscrow(coordinator_));
        address freeze_ = address(new MockFreeze(address(ee), warehouseSafe, navOracle));
        address adapter_ = address(new MockAdapter(address(ee)));

        SiloRegistry.SiloConfig memory cfg = SiloRegistry.SiloConfig({
            adapter: adapter_,
            warehouseSafe: warehouseSafe,
            eePool: address(ee),
            juniorBasket: juniorBasket,
            escrow: escrow_,
            defaultCoordinator: coordinator_,
            navOracle: navOracle,
            freeze: freeze_,
            curator: curator
        });
        bytes32 id = keccak256(bytes(label));
        reg.addSilo(id, cfg);
        out = Silo({id: id, ee: ee, warehouseSafe: warehouseSafe});
    }

    // ============================================================== N=1 identity
    function test_n1_identity() public {
        Silo memory a = _addSilo("A");
        // 1000 USDC backing (6-dp), 1 share, half free
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 500e6);

        // identity: convertToAssets(balanceOf(safe)) * 1e12
        uint256 expected = 1_000e6 * 1e12;
        assertEq(agg.seniorBacking(), expected, "n=1 seniorBacking identity");
        assertEq(agg.activeSeniorBacking(), expected, "n=1 active identity");
        assertEq(agg.seniorBackingOf(a.id), expected, "n=1 per-silo");
    }

    // ============================================================== two-silo Σ
    function test_twoSilo_sum() public {
        Silo memory a = _addSilo("A");
        Silo memory b = _addSilo("B");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 1_000e6);
        b.ee.setPosition(b.warehouseSafe, 2, 250e6, 250e6);

        uint256 expected = (1_000e6 + 250e6) * 1e12;
        assertEq(agg.seniorBacking(), expected, "two-silo sum");
        assertEq(agg.activeSeniorBacking(), expected, "two-silo active sum");
    }

    // ============================================================== donation no-op (the whole point)
    function test_donation_immune() public {
        Silo memory a = _addSilo("A");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 300e6);
        uint256 before = agg.seniorBacking();
        uint256 illiqBefore = agg.illiquidSeniorValue();

        // Donate shares to the POOL address itself (and to a stranger) — warehouse position untouched.
        a.ee.donateShares(address(a.ee), 1_000_000);
        a.ee.donateShares(stranger, 999);

        assertEq(agg.seniorBacking(), before, "donation moved seniorBacking");
        assertEq(agg.illiquidSeniorValue(), illiqBefore, "donation moved illiquid");
    }

    // ============================================================== CTR-10b: non-Euler venue plugs in donation-immune
    /// @dev The federation plug-in proof. `_addSilo` admits a silo whose adapter (`MockAdapter`) exposes ONLY the
    ///      venue-neutral `seniorPool()` getter and has NO `eulerEarn()` — i.e. a NON-Euler venue stand-in. That
    ///      admission SUCCEEDS is itself the proof the host seam is venue-agnostic (the registry dereferences
    ///      `ISeniorVenue.seniorPool()`, never an Euler-specific getter; CTR-10b). The aggregator then reads its
    ///      senior surface through `ISeniorPool` exactly as for an Euler silo, donation-immune.
    function test_ctr10b_nonEuler_venue_plugs_in() public {
        Silo memory a = _addSilo("nonEuler"); // adapter has no eulerEarn() — admission proves venue-neutrality

        // the adapter exposes the venue-neutral getter and NOT the Euler-specific one
        (bool okSenior,) = a_adapter(a.id).staticcall(abi.encodeWithSignature("seniorPool()"));
        (bool okEuler,) = a_adapter(a.id).staticcall(abi.encodeWithSignature("eulerEarn()"));
        assertTrue(okSenior, "non-Euler adapter exposes seniorPool()");
        assertFalse(okEuler, "non-Euler adapter has NO eulerEarn(): genuinely not an Euler venue");

        a.ee.setPosition(a.warehouseSafe, 1, 2_000e6, 800e6);
        uint256 expected = 2_000e6 * 1e12;
        assertEq(agg.seniorBacking(), expected, "non-Euler silo aggregates");
        assertEq(agg.illiquidSeniorValue(), (2_000e6 - 800e6) * 1e12, "non-Euler illiquid aggregates");

        // donation-immune just like Euler: a stray donation to the senior surface moves nothing
        uint256 before = agg.seniorBacking();
        a.ee.donateShares(address(a.ee), 5_000_000);
        assertEq(agg.seniorBacking(), before, "non-Euler silo donation-immune");
    }

    /// @dev The admitted silo's adapter address (the venue seam `venueOf` returns).
    function a_adapter(bytes32 id) internal view returns (address) {
        return reg.venueOf(id);
    }

    // ============================================================== retired silo: counted in seniorBacking, not active
    function test_retired_stillCounted_droppedFromActive() public {
        Silo memory a = _addSilo("A"); // becomes currentSilo
        Silo memory b = _addSilo("B");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 1_000e6);
        b.ee.setPosition(b.warehouseSafe, 2, 400e6, 400e6);

        uint256 fullSum = (1_000e6 + 400e6) * 1e12;
        assertEq(agg.seniorBacking(), fullSum, "pre-retire total");
        assertEq(agg.activeSeniorBacking(), fullSum, "pre-retire active");

        reg.retireSilo(b.id); // b.active = false; still holds backing

        assertEq(agg.seniorBacking(), fullSum, "retired still counted in seniorBacking");
        assertEq(agg.activeSeniorBacking(), 1_000e6 * 1e12, "retired dropped from active");
    }

    // ============================================================== drained silo contributes 0 to both
    function test_drained_silo_zero() public {
        Silo memory a = _addSilo("A");
        Silo memory b = _addSilo("B");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 1_000e6);
        // b is drained: 0 shares -> convertToAssets(0)==0
        b.ee.setPosition(b.warehouseSafe, 0, 0, 0);

        uint256 expected = 1_000e6 * 1e12;
        assertEq(agg.seniorBacking(), expected, "drained adds 0 to seniorBacking");
        assertEq(agg.activeSeniorBacking(), expected, "drained adds 0 to active");
        assertEq(agg.seniorBackingOf(b.id), 0, "drained per-silo 0");
        assertEq(agg.illiquidSeniorValueOf(b.id), 0, "drained illiquid 0");
    }

    // ============================================================== illiquidSeniorValue matches freeze-module formula
    function test_illiquid_matches_formula() public {
        Silo memory a = _addSilo("A");
        // sa=100e6, free=30e6 -> illiquid = (100-30)e6 * 1e12
        a.ee.setPosition(a.warehouseSafe, 1, 100e6, 30e6);
        assertEq(agg.illiquidSeniorValue(), (100e6 - 30e6) * 1e12, "illiquid sa-free");
        assertEq(agg.illiquidSeniorValueOf(a.id), (100e6 - 30e6) * 1e12, "per-silo illiquid");

        // free >= sa -> 0 (verbatim guard)
        a.ee.setPosition(a.warehouseSafe, 1, 100e6, 100e6);
        assertEq(agg.illiquidSeniorValue(), 0, "free==sa -> 0");
        a.ee.setPosition(a.warehouseSafe, 1, 100e6, 200e6);
        assertEq(agg.illiquidSeniorValue(), 0, "free>sa -> 0");

        // sa==0 -> 0
        a.ee.setPosition(a.warehouseSafe, 0, 0, 0);
        assertEq(agg.illiquidSeniorValue(), 0, "sa==0 -> 0");
    }

    // ============================================================== collateralization math + zero-supply -> max
    function test_collateralization_math() public {
        Silo memory a = _addSilo("A");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 1_000e6); // backing = 1000e18

        // supply 1000e18 -> exactly 1e18 (100%)
        assertEq(agg.collateralization(1_000e18), 1e18, "100% backed");
        // supply 2000e18 -> 0.5e18
        assertEq(agg.collateralization(2_000e18), 0.5e18, "50% backed");
        // zero supply -> max
        assertEq(agg.collateralization(0), type(uint256).max, "zero supply -> max");
    }

    // ============================================================== systemCollateralization wired vs ZipUsdUnset
    function test_systemCollateralization_wired() public {
        Silo memory a = _addSilo("A");
        a.ee.setPosition(a.warehouseSafe, 1, 1_000e6, 1_000e6); // backing 1000e18
        zip.setSupply(500e18);
        assertEq(agg.systemCollateralization(), agg.collateralization(500e18), "matches arg form");
        assertEq(agg.systemCollateralization(), 2e18, "200% backed");

        // zero supply path -> max
        zip.setSupply(0);
        assertEq(agg.systemCollateralization(), type(uint256).max, "zero supply -> max");
    }

    function test_systemCollateralization_zipUsdUnset_reverts() public {
        SeniorNavAggregator a2 = new SeniorNavAggregator(address(reg), address(0));
        vm.expectRevert(SeniorNavAggregator.ZipUsdUnset.selector);
        a2.systemCollateralization();
    }

    // ============================================================== per-silo getters: unknown silo -> 0
    function test_perSilo_unknown_zero() public view {
        bytes32 ghost = keccak256("ghost");
        assertEq(agg.seniorBackingOf(ghost), 0, "unknown senior 0");
        assertEq(agg.illiquidSeniorValueOf(ghost), 0, "unknown illiquid 0");
    }

    // ============================================================== RegistryUnset on aggregate reads
    function test_registryUnset_reverts() public {
        SeniorNavAggregator a2 = new SeniorNavAggregator(address(0), address(zip));
        vm.expectRevert(SeniorNavAggregator.RegistryUnset.selector);
        a2.seniorBacking();
        vm.expectRevert(SeniorNavAggregator.RegistryUnset.selector);
        a2.activeSeniorBacking();
        vm.expectRevert(SeniorNavAggregator.RegistryUnset.selector);
        a2.illiquidSeniorValue();
        vm.expectRevert(SeniorNavAggregator.RegistryUnset.selector);
        a2.seniorBackingOf(keccak256("x"));
        vm.expectRevert(SeniorNavAggregator.RegistryUnset.selector);
        a2.illiquidSeniorValueOf(keccak256("x"));
    }

    // ============================================================== setRegistry / setZipUsd gating + zero-reject
    function test_setRegistry_happy() public {
        address newReg = address(new SiloRegistry(makeAddr("c2")));
        vm.expectEmit(true, false, false, true, address(agg));
        emit SeniorNavAggregator.WiringSet("registry", newReg);
        agg.setRegistry(newReg);
        assertEq(address(agg.registry()), newReg, "registry re-pointed");
    }

    function test_setRegistry_zero_reverts() public {
        vm.expectRevert(SeniorNavAggregator.ZeroAddress.selector);
        agg.setRegistry(address(0));
    }

    function test_setRegistry_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        agg.setRegistry(makeAddr("x"));
    }

    function test_setZipUsd_happy() public {
        address newZip = address(new MockZipUsd());
        vm.expectEmit(true, false, false, true, address(agg));
        emit SeniorNavAggregator.WiringSet("zipUsd", newZip);
        agg.setZipUsd(newZip);
        assertEq(agg.zipUsd(), newZip, "zipUsd re-pointed");
    }

    function test_setZipUsd_zero_reverts() public {
        vm.expectRevert(SeniorNavAggregator.ZeroAddress.selector);
        agg.setZipUsd(address(0));
    }

    function test_setZipUsd_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        agg.setZipUsd(makeAddr("x"));
    }

    // ============================================================== ctor accepts zero for BOTH
    function test_ctor_acceptsZeroForBoth() public {
        SeniorNavAggregator a2 = new SeniorNavAggregator(address(0), address(0));
        assertEq(address(a2.registry()), address(0), "registry zero");
        assertEq(a2.zipUsd(), address(0), "zipUsd zero");
    }
}

/// @dev Minimal ESynth stand-in: 18-dp, settable totalSupply (the only thing systemCollateralization reads).
contract MockZipUsd {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    function setSupply(uint256 s) external {
        totalSupply = s;
    }
}
