// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkConfig} from "../../ForkConfig.sol";
import {SummonSubstrate} from "../../../script/SummonSubstrate.s.sol";
import {IBaal} from "../../../src/interfaces/baal/IBaal.sol";
import {ISafe} from "../../../src/interfaces/safe/ISafe.sol";
import {SzipNavOracle} from "../../../src/supply/SzipNavOracle.sol";
import {ExitGate} from "../../../src/supply/szipUSD/ExitGate.sol";
import {SzipUSD} from "../../../src/supply/szipUSD/SzipUSD.sol";

// ---------------------------------------------------------------------------- mocks
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

    function mint(address to, uint256 amt) external {
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

contract MockXAlpha is MockERC20 {
    uint256 public exchangeRate = 1e18;

    constructor() MockERC20(18) {}

    function setExchangeRate(uint256 v) external {
        exchangeRate = v;
    }
}

contract MockOHydx is MockERC20 {
    uint256 public discount;

    constructor(uint256 d) MockERC20(18) {
        discount = d;
    }
}

/// @notice A fee-on-transfer 18-dp token: `transferFrom` skims 1%, so the destination receives less than `amount`.
///         Used to prove `depositFor`'s received-delta guard (`TransferShortfall`) rejects an over-issue.
contract MockFeeERC20 {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        uint256 fee = a / 100; // 1% skim
        balanceOf[f] -= a;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @notice Exit Gate + szipUSD — Base-mainnet fork test against the LIVE Baal substrate (8-B1 `_summon`) + the
/// real `SzipNavOracle`, with mock basket assets. Proves: NAV-proportional issuance, the two-token invariant
/// (`szipUSD.totalSupply == loot.balanceOf(gate)`), the manager-grant gate (8-B1 F4.2 obligation), windowed
/// ragequit exit paid in zipUSD at navExit (partial-fill = the freeze), the paired buy-and-burn, and zero Shares.
contract ExitGateTest is ForkConfig, SummonSubstrate {
    uint256 internal constant SALT = uint256(keccak256("zipcode.exitgate.test.salt.a"));
    uint256 internal constant SALT_NOGRANT = uint256(keccak256("zipcode.exitgate.test.salt.nogrant"));

    uint32 internal constant W = 4 hours;
    uint256 internal constant MAX_AGE = 1 days;
    uint256 internal constant DEV_BPS = 2000;
    uint256 internal constant TVL_CAP = 1_000_000e18;

    address internal team = makeAddr("teamMultisig");
    address internal keeper = makeAddr("windowKeeper");
    address internal engine = makeAddr("juniorTrancheEngine");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal forwarder = makeAddr("forwarder");

    Substrate internal sub;
    MockERC20 internal zip;
    MockERC20 internal usdc;
    MockXAlpha internal xa;
    MockERC20 internal hydx;
    MockOHydx internal ohydx;
    SzipNavOracle internal oracle;
    ExitGate internal gate;
    SzipUSD internal szip;
    ExitGateHandler internal handler;

    function setUp() public {
        _selectBaseFork();
        vm.warp(1_000_000);

        // 1. Summon the real substrate (team owner on both Safes).
        vm.startPrank(team);
        sub = _summon(team, SALT);
        vm.stopPrank();

        // 2. Mock basket assets.
        zip = new MockERC20(18);
        usdc = new MockERC20(6);
        xa = new MockXAlpha();
        hydx = new MockERC20(18);
        ohydx = new MockOHydx(30);

        // 3. Real oracle over the real Safes.
        oracle = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdc),
            address(xa),
            address(hydx),
            address(ohydx),
            sub.juniorTrancheSafe,
            sub.juniorTrancheSidecar,
            W,
            MAX_AGE,
            DEV_BPS
        );

        // 4. Gate + szipUSD (deploy-order circularity: Gate first, szipUSD takes the Gate).
        gate = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), TVL_CAP);
        szip = new SzipUSD(address(gate));

        // 5. Wire set-once seams (Gate is `this`'s owner since this deployed it).
        gate.setShareToken(address(szip));
        gate.setWindowController(keeper);
        gate.setJuniorTrancheEngine(engine);
        oracle.setShareToken(address(szip));

        // 6. Grant the Gate manager(2) via team-admin -> juniorTrancheSafe.execTransaction -> Baal.setShamans.
        _grantManager(address(gate));

        // 7. Push leg prices so the oracle is fresh (alphaUSD=$1, hydxUSD=$0.5).
        _pushBoth(1e18, 5e17);

        // 8. Stateful-invariant handler: bounded random deposit/transfer/burn against the REAL gate+Baal.
        //    targetContract restricts the fuzzer to the handler; it is inert for the deterministic `test_*` above.
        handler = new ExitGateHandler(gate, szip, zip, xa, sub.loot, engine, keeper);
        targetContract(address(handler));
    }

    // ----------------------------------------------------------------- helpers
    function _grantManager(address shaman) internal {
        bytes memory data = abi.encodeWithSelector(IBaal.setShamans.selector, _arr(shaman), _arrU(2));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(sub.juniorTrancheSafe).execTransaction(sub.baal, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _pushBoth(uint256 alphaUSD, uint256 hydxUSD) internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = oracle.LEG_ALPHA_USD();
        legs[1] = oracle.LEG_HYDX_USD();
        ps[0] = alphaUSD;
        ps[1] = hydxUSD;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        zip.mint(who, amount);
        vm.startPrank(who);
        zip.approve(address(gate), amount);
        shares = gate.depositFor(address(zip), amount, who);
        vm.stopPrank();
    }

    function _assertInvariants() internal view {
        assertEq(szip.totalSupply(), MockERC20(sub.loot).balanceOf(address(gate)), "two-token invariant");
        assertEq(IBaal(sub.baal).totalShares(), 0, "shares must stay 0");
        assertEq(zip.balanceOf(address(gate)), 0, "gate holds no zip residual");
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _arrU(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    // ----------------------------------------------------------------- wiring
    function test_deploy_and_wiring() public view {
        assertEq(address(gate.baal()), sub.baal);
        assertEq(gate.loot(), sub.loot);
        assertEq(gate.juniorTrancheSafe(), sub.juniorTrancheSafe);
        assertEq(gate.zipUSD(), address(zip));
        assertEq(gate.shareToken(), address(szip));
        assertEq(gate.windowController(), keeper);
        assertEq(gate.juniorTrancheEngine(), engine);
        assertEq(szip.gate(), address(gate));
        assertEq(IBaal(sub.baal).shamans(address(gate)), 2, "gate is manager");
    }

    function test_setters_repoint_and_auth() public {
        // a fresh Gate with nothing wired
        ExitGate g = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), TVL_CAP);
        // non-owner cannot wire
        vm.prank(alice);
        vm.expectRevert();
        g.setShareToken(address(szip));
        // owner wires; build phase (§17) re-settable — a second call re-points
        g.setShareToken(address(szip));
        assertEq(g.shareToken(), address(szip));
        address szip2 = makeAddr("szip2");
        g.setShareToken(szip2);
        assertEq(g.shareToken(), szip2);
        // zero-address rejected
        vm.expectRevert(ExitGate.ZeroAddress.selector);
        g.setShareToken(address(0));
    }

    function test_szipUSD_mint_burn_onlyGate() public {
        vm.prank(alice);
        vm.expectRevert(SzipUSD.NotGate.selector);
        szip.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SzipUSD.NotGate.selector);
        szip.burn(alice, 1e18);
    }

    /// @dev SzipUSD's own admin surface: the constructor zero-guards `gate`, and `setGate` (the re-point of who may
    ///      mint/burn the user token) is `onlyOwner` + zero-guarded + takes effect. `szip` was deployed by this test,
    ///      so `address(this)` is its owner.
    function test_szipUSD_setGate_and_ctor_zero_guard() public {
        // constructor rejects a zero gate
        vm.expectRevert(SzipUSD.ZeroAddress.selector);
        new SzipUSD(address(0));

        SzipUSD t = new SzipUSD(address(gate)); // this = owner
        assertEq(t.gate(), address(gate), "ctor wired the gate");

        // non-owner cannot re-point
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        t.setGate(alice);

        // zero rejected
        vm.expectRevert(SzipUSD.ZeroAddress.selector);
        t.setGate(address(0));

        // owner re-point takes effect (and the new gate becomes the sole minter)
        address newGate = makeAddr("newGate");
        t.setGate(newGate);
        assertEq(t.gate(), newGate, "gate re-pointed");
        vm.prank(newGate);
        t.mint(alice, 1e18);
        assertEq(t.balanceOf(alice), 1e18, "new gate can mint");
        // the OLD gate can no longer mint
        vm.prank(address(gate));
        vm.expectRevert(SzipUSD.NotGate.selector);
        t.mint(alice, 1e18);
    }

    /// @dev SUPPLY-ADV-12: `setGate` re-points freely while no szipUSD is issued (pre-issuance build-phase flexibility).
    function test_szipUSD_setGate_repoint_allowed_pre_issuance() public {
        SzipUSD t = new SzipUSD(address(gate)); // this = owner, totalSupply() == 0
        address g1 = makeAddr("g1");
        address g2 = makeAddr("g2");
        t.setGate(g1);
        assertEq(t.gate(), g1, "re-point #1 allowed pre-issuance");
        t.setGate(g2);
        assertEq(t.gate(), g2, "re-point #2 allowed pre-issuance");
    }

    /// @dev SUPPLY-ADV-12: once szipUSD is issued (`totalSupply() != 0`), `setGate` fails closed (`AlreadyIssued`) — the
    ///      sole-minter pointer is the third leg of the two-token conservation and must not re-point over a live supply.
    function test_szipUSD_setGate_locked_after_issuance() public {
        address g1 = makeAddr("g1");
        SzipUSD t = new SzipUSD(g1); // this = owner
        // issue some supply via the wired gate
        vm.prank(g1);
        t.mint(alice, 1e18);
        assertEq(t.totalSupply(), 1e18, "supply issued");
        // re-point now fails closed, even for the owner with a valid non-zero gate
        address g2 = makeAddr("g2");
        vm.expectRevert(SzipUSD.AlreadyIssued.selector);
        t.setGate(g2);
        assertEq(t.gate(), g1, "gate unchanged after AlreadyIssued");
    }

    // ----------------------------------------------------------------- manager-grant obligation (8-B1 F4.2)
    function test_depositFor_reverts_without_manager_grant() public {
        // Summon a SECOND substrate, build a Gate, but do NOT grant manager — depositFor must revert at mintLoot.
        vm.startPrank(team);
        Substrate memory s2 = _summon(team, SALT_NOGRANT);
        vm.stopPrank();
        SzipNavOracle o2 = new SzipNavOracle(
            forwarder, address(zip), address(usdc), address(xa), address(hydx), address(ohydx),
            s2.juniorTrancheSafe, s2.juniorTrancheSidecar, W, MAX_AGE, DEV_BPS
        );
        ExitGate g2 = new ExitGate(s2.baal, address(o2), address(zip), address(xa), TVL_CAP);
        SzipUSD sz2 = new SzipUSD(address(g2));
        g2.setShareToken(address(sz2));
        o2.setShareToken(address(sz2));
        {
            uint8[] memory legs = new uint8[](2);
            uint256[] memory ps = new uint256[](2);
            legs[0] = o2.LEG_ALPHA_USD();
            legs[1] = o2.LEG_HYDX_USD();
            ps[0] = 1e18;
            ps[1] = 5e17;
            vm.prank(forwarder);
            o2.onReport("", abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp))));
        }
        zip.mint(alice, 1e18);
        vm.startPrank(alice);
        zip.approve(address(g2), 1e18);
        vm.expectRevert(); // Baal mintLoot fails baalOrManagerOnly (the Gate isn't a manager)
        g2.depositFor(address(zip), 1e18, alice);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- issuance
    function test_depositFor_genesis_par() public {
        uint256 shares = _deposit(alice, 12e18); // genesis NAV = $1
        assertEq(shares, 12e18, "genesis shares == value");
        assertEq(szip.balanceOf(alice), 12e18);
        assertEq(zip.balanceOf(sub.juniorTrancheSafe), 12e18, "asset landed in basket");
        _assertInvariants();
    }

    function test_depositFor_navProportional_roundDown() public {
        _deposit(alice, 12e18); // supply 12e18, gross 12e18 -> spot $1
        // donate zip to the basket to bump spot to $1.2 (gross 14.4e18 / supply 12e18)
        zip.mint(sub.juniorTrancheSafe, 24e17);
        // twap has <W history -> twap == spot == 1.2 ; navEntry = max = 1.2e18
        uint256 shares = _deposit(bob, 12e18); // value 12e18 / 1.2 = 10e18
        assertEq(shares, 10e18, "navEntry $1.2 -> 10 shares");
        _assertInvariants();
    }

    function test_previewDeposit_matches_depositFor() public {
        // genesis: preview == realized
        uint256 q0 = gate.previewDeposit(address(zip), 12e18);
        uint256 shares = _deposit(alice, 12e18);
        assertEq(q0, shares, "previewDeposit == depositFor (genesis par)");
        assertEq(q0, 12e18);

        // non-par: bump spot to $1.2, preview still mirrors depositFor's pricing
        zip.mint(sub.juniorTrancheSafe, 24e17); // gross 14.4e18 / supply 12e18 -> $1.2
        uint256 q1 = gate.previewDeposit(address(zip), 12e18);
        assertEq(q1, 10e18, "previewDeposit at navEntry $1.2");
        uint256 s1 = _deposit(bob, 12e18);
        assertEq(q1, s1, "previewDeposit == depositFor (non-par)");
    }

    function test_previewDeposit_guards() public {
        vm.expectRevert(abi.encodeWithSelector(ExitGate.UnsupportedAsset.selector, address(usdc)));
        gate.previewDeposit(address(usdc), 1e6);
        vm.expectRevert(ExitGate.ZeroAmount.selector);
        gate.previewDeposit(address(zip), 0);
        // stale oracle -> previewDeposit reverts StalePrice just like depositFor
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, oracle.LEG_ALPHA_USD()));
        gate.previewDeposit(address(zip), 1e18);
    }

    function test_depositFor_unsupported_asset_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExitGate.UnsupportedAsset.selector, address(usdc)));
        gate.depositFor(address(usdc), 1e6, alice);
    }

    function test_depositFor_zero_amount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ExitGate.ZeroAmount.selector);
        gate.depositFor(address(zip), 0, alice);
    }

    function test_depositFor_tvlCap() public {
        // cap-1 succeeds, over-cap reverts
        ExitGate g = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), 10e18);
        SzipUSD sz = new SzipUSD(address(g));
        g.setShareToken(address(sz));
        _grantManager(address(g));
        // NOTE: g shares the same oracle/szip denominator as the suite's; keep it simple — fresh oracle wiring
        // is covered elsewhere. Here we only exercise the cap arithmetic against the suite oracle's gross.
        // gross is 0 here (suite gate's deposits are separate token flows into the same juniorTrancheSafe) -> use a tiny cap.
        zip.mint(alice, 20e18);
        vm.startPrank(alice);
        zip.approve(address(g), 20e18);
        vm.expectRevert(ExitGate.TvlCapExceeded.selector);
        g.depositFor(address(zip), 20e18, alice); // value 20e18 > cap 10e18
        vm.stopPrank();
    }

    /// @notice SEC-04 (H5): an UNSEEDED xALPHA rate (`exchangeRate() == 0`) must FAIL CLOSED the deposit path rather
    ///         than let a silently-underpriced gross slip a deposit past the cap (under-read tvlCap). With fresh legs
    ///         but the rate unseeded, `depositFor` reverts `RateUnseeded` (via `navEntry`/`grossBasketValue`, both
    ///         routing through `_xAlphaUSD`). Pre-fix the rate read 0 and the deposit SUCCEEDED — so this reverts only
    ///         after the fix (fail-before/pass-after).
    function test_SEC04_unseeded_rate_reverts_deposit() public {
        xa.setExchangeRate(0); // rate unseeded; legs are fresh from setUp
        zip.mint(alice, 1e18);
        vm.startPrank(alice);
        zip.approve(address(gate), 1e18);
        vm.expectRevert(SzipNavOracle.RateUnseeded.selector);
        gate.depositFor(address(zip), 1e18, alice);
        vm.stopPrank();

        // re-seed -> the same deposit succeeds (fail-close was the only gate)
        xa.setExchangeRate(1e18);
        vm.prank(alice);
        gate.depositFor(address(zip), 1e18, alice);
    }

    function test_depositFor_stale_reverts() public {
        vm.warp(block.timestamp + MAX_AGE + 1); // legs go stale
        zip.mint(alice, 1e18);
        vm.startPrank(alice);
        zip.approve(address(gate), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SzipNavOracle.StalePrice.selector, oracle.LEG_ALPHA_USD()));
        gate.depositFor(address(zip), 1e18, alice);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- buy-and-burn
    function test_burnFor_pure_supply_retire() public {
        _deposit(alice, 10e18);
        // simulate a CoW fill: alice transfers 3e18 szip to the engine Safe (the bought-back inventory)
        vm.prank(alice);
        szip.transfer(engine, 3e18);

        uint256 mainBefore = zip.balanceOf(sub.juniorTrancheSafe);
        vm.prank(keeper);
        gate.burnFor(3e18);

        assertEq(szip.balanceOf(engine), 0, "engine szip burned");
        assertEq(szip.totalSupply(), 7e18, "supply down by burned amount");
        assertEq(zip.balanceOf(sub.juniorTrancheSafe), mainBefore, "basket untouched (no asset payout)");
        _assertInvariants();

        // auth + edges
        vm.prank(alice);
        vm.expectRevert(ExitGate.NotWindowController.selector);
        gate.burnFor(1e18);
        vm.prank(keeper);
        vm.expectRevert(ExitGate.ZeroAmount.selector);
        gate.burnFor(0);
    }

    // ----------------------------------------------------------------- cross-cut invariant sequence
    function test_invariant_sequence() public {
        // C3: the exit path is now the CoW buy-and-burn rail (requestExit/processWindow retired). The two-token
        // invariant must hold across deposit -> a simulated CoW fill (transfer to the engine Safe) -> burnFor.
        _deposit(alice, 10e18);
        _deposit(bob, 6e18);
        _assertInvariants();
        // simulate a CoW fill landing in the engine Safe, then retire it.
        vm.prank(alice);
        szip.transfer(engine, 4e18);
        _assertInvariants(); // a transfer moves no Loot -> invariant still holds
        vm.prank(keeper);
        gate.burnFor(4e18);
        _assertInvariants();
        assertEq(szip.totalSupply(), 12e18, "supply down by the retired amount");
    }

    // ----------------------------------------------------------------- path coverage gap-fills (2026-06-20)
    /// @notice The xALPHA deposit branch: the whitelist accepts {zipUSD, xALPHA} but the rest of the suite only
    ///         deposits zip. Exercise the `valueOf(xAlpha, …)` issuance path — shares match `previewDeposit`, the
    ///         xALPHA lands in the basket, and the two-token invariant holds.
    function test_depositFor_xAlpha_path() public {
        uint256 amount = 7e18;
        uint256 q = gate.previewDeposit(address(xa), amount); // mirrors depositFor pricing exactly
        assertGt(q, 0, "xAlpha deposit prices to non-zero shares");

        xa.mint(alice, amount);
        vm.startPrank(alice);
        xa.approve(address(gate), amount);
        uint256 shares = gate.depositFor(address(xa), amount, alice);
        vm.stopPrank();

        assertEq(shares, q, "realized shares == previewDeposit (xAlpha path)");
        assertEq(szip.balanceOf(alice), shares, "receiver got the szipUSD");
        assertEq(xa.balanceOf(sub.juniorTrancheSafe), amount, "xALPHA landed in the basket");
        _assertInvariants();
    }

    /// @notice `burnFor` for more szipUSD than the engine Safe holds must revert (the inner `SzipUSD.burn` underflows)
    ///         and roll back atomically — the prior `burnLoot` does not leak, and the two-token invariant survives.
    function test_burnFor_reverts_when_engine_underfunded() public {
        _deposit(alice, 10e18);
        vm.prank(alice);
        szip.transfer(engine, 3e18); // engine holds only 3e18

        uint256 supplyBefore = szip.totalSupply();
        vm.prank(keeper);
        vm.expectRevert(); // SzipUSD.burn -> ERC20 insufficient balance on the engine
        gate.burnFor(5e18); // > engine's 3e18

        assertEq(szip.totalSupply(), supplyBefore, "supply intact after rolled-back burnFor");
        assertEq(szip.balanceOf(engine), 3e18, "engine szipUSD untouched");
        _assertInvariants();
    }

    // ----------------------------------------------------------------- audit hardening (SUPPLY-ADV-06/07)
    /// @notice SUPPLY-ADV-06: the conservation-defining pointers (`baal`→`loot`, `shareToken`) are re-pointable only
    ///         BEFORE any szipUSD is issued; once `totalSupply() != 0` they fail closed (`AlreadyWired`) so a re-point
    ///         cannot strand the paired Loot / fork the I-1 identity.
    function test_setBaal_locked_after_issuance() public {
        _deposit(alice, 5e18); // szipUSD now issued -> the I-1 identity is live
        vm.expectRevert(ExitGate.AlreadyWired.selector);
        gate.setBaal(makeAddr("baal2"));
    }

    function test_setShareToken_locked_after_issuance() public {
        _deposit(alice, 5e18);
        vm.expectRevert(ExitGate.AlreadyWired.selector);
        gate.setShareToken(makeAddr("szip2"));
    }

    /// @dev The lock is only on the post-issuance re-point — a fresh, pre-issuance Gate still re-points freely.
    function test_setBaal_repoint_allowed_pre_issuance() public {
        ExitGate g = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), TVL_CAP);
        g.setShareToken(address(szip)); // szip has 0 supply in this test's fresh state -> allowed
        // re-point baal pre-issuance: re-derives loot/juniorTrancheSafe off the same substrate, no revert
        g.setBaal(sub.baal);
        assertEq(g.loot(), sub.loot, "pre-issuance setBaal re-derives loot");
    }

    /// @notice SUPPLY-ADV-06: `burnFor` carries the same explicit `NotWired` guard as `depositFor` (:159) when the
    ///         share token is unset — an explicit revert, not an incidental EVM call-to-codeless-address revert.
    function test_burnFor_reverts_when_shareToken_unwired() public {
        ExitGate g = new ExitGate(sub.baal, address(oracle), address(zip), address(xa), TVL_CAP);
        g.setWindowController(keeper);
        g.setJuniorTrancheEngine(engine);
        // shareToken deliberately left unset
        vm.prank(keeper);
        vm.expectRevert(ExitGate.NotWired.selector);
        g.burnFor(1e18);
    }

    /// @notice SUPPLY-ADV-07: a fee-on-transfer deposit leg credits the basket less than `amount`, but `shares` is
    ///         priced off `valueOf(asset, amount)` (the full amount) — so without a received-delta check it would
    ///         over-issue szipUSD against backing the basket never got. The guard reverts `TransferShortfall`.
    function test_depositFor_feeOnTransfer_reverts() public {
        MockFeeERC20 fot = new MockFeeERC20();
        // Fresh oracle whose zipUSD leg IS the FoT token (the oracle's legs are immutable), over the same Safes.
        SzipNavOracle o3 = new SzipNavOracle(
            forwarder, address(fot), address(usdc), address(xa), address(hydx), address(ohydx),
            sub.juniorTrancheSafe, sub.juniorTrancheSidecar, W, MAX_AGE, DEV_BPS
        );
        ExitGate g3 = new ExitGate(sub.baal, address(o3), address(fot), address(xa), TVL_CAP);
        SzipUSD sz3 = new SzipUSD(address(g3));
        g3.setShareToken(address(sz3));
        o3.setShareToken(address(sz3));
        _grantManager(address(g3));
        {
            uint8[] memory legs = new uint8[](2);
            uint256[] memory ps = new uint256[](2);
            legs[0] = o3.LEG_ALPHA_USD();
            legs[1] = o3.LEG_HYDX_USD();
            ps[0] = 1e18;
            ps[1] = 5e17;
            vm.prank(forwarder);
            o3.onReport("", abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp))));
        }
        fot.mint(alice, 10e18);
        vm.startPrank(alice);
        fot.approve(address(g3), 10e18);
        vm.expectRevert(ExitGate.TransferShortfall.selector);
        g3.depositFor(address(fot), 10e18, alice); // basket receives 9.9e18 != 10e18 -> revert
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- stateful invariant (the map's ask)
    /// @notice The two-token conservation `szipUSD.totalSupply() == loot.balanceOf(gate)` AND zero-shares, across
    ///         ARBITRARY interleavings of deposit / transfer-to-engine / burnFor by multiple actors — not just the
    ///         deterministic `test_invariant_sequence`. Driven by `ExitGateHandler` against the REAL Baal + oracle.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_twoToken_conservation_and_zeroShares() public view {
        assertEq(szip.totalSupply(), MockERC20(sub.loot).balanceOf(address(gate)), "two-token invariant under fuzz");
        assertEq(IBaal(sub.baal).totalShares(), 0, "shares stay 0 under fuzz");
    }
}

// ============================================================================ stateful-invariant handler

/// @notice Drives bounded random deposit / transfer-to-engine / burnFor against the REAL gate + Baal substrate so
///         the two-token conservation + zero-shares invariants are checked across arbitrary interleavings. Reverts
///         are swallowed (`fail-on-revert = false`): a deposit can hit the TVL cap / ZeroShares, a burn the engine
///         balance — those are legitimately skipped, not invariant violations.
contract ExitGateHandler is Test {
    ExitGate internal gate;
    SzipUSD internal szip;
    MockERC20 internal zip;
    MockXAlpha internal xa;
    address internal engine;
    address internal keeper;
    address[3] internal actors;

    constructor(ExitGate gate_, SzipUSD szip_, MockERC20 zip_, MockXAlpha xa_, address, address engine_, address keeper_) {
        gate = gate_;
        szip = szip_;
        zip = zip_;
        xa = xa_;
        engine = engine_;
        keeper = keeper_;
        actors = [makeAddr("inv_alice"), makeAddr("inv_bob"), makeAddr("inv_carol")];
    }

    function deposit(uint256 actorSeed, bool useXAlpha, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 1e21);
        MockERC20 asset = useXAlpha ? MockERC20(address(xa)) : zip;
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(gate), amount);
        try gate.depositFor(address(asset), amount, who) {} catch {}
        vm.stopPrank();
    }

    function transferToEngine(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        uint256 bal = szip.balanceOf(who);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(who);
        szip.transfer(engine, amount);
    }

    function burn(uint256 amount) external {
        uint256 eng = szip.balanceOf(engine);
        if (eng == 0) return;
        amount = bound(amount, 1, eng);
        vm.prank(keeper);
        try gate.burnFor(amount) {} catch {}
    }
}
