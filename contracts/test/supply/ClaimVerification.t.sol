// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SzipNavOracle} from "../../src/supply/SzipNavOracle.sol";
import {DefaultCoordinator} from "../../src/loss/DefaultCoordinator.sol";
import {LienXAlphaEscrow} from "../../src/loss/LienXAlphaEscrow.sol";
import {RecycleModule} from "../../src/supply/szipUSD/RecycleModule.sol";
import {DurationFreezeModule} from "../../src/supply/szipUSD/DurationFreezeModule.sol";
import {ExerciseModule} from "../../src/supply/szipUSD/ExerciseModule.sol";
import {ZipRedemptionQueue} from "../../src/supply/ZipRedemptionQueue.sol";

// REUSED fixtures — no new mock is introduced by this file.
// The `RecordingSafe` from `RecycleModule.t.sol` implements `execTransactionFromModuleReturnData` (the
// `execAndReturnData` surface `RecycleModule`/`ExerciseModule` drive); the one from `DurationFreezeModule.t.sol`
// implements the plain `execTransactionFromModule` surface `DurationFreezeModule` drives.
import {RecordingSafe as ExecSafe, EEMock} from "./szipUSD/RecycleModule.t.sol";
import {
    MockERC20,
    MockXAlphaToken,
    MockOHydxToken,
    MockEulerEarn,
    RecordingSafe as FreezeSafe
} from "./szipUSD/DurationFreezeModule.t.sol";
import {MockOHYDX} from "./szipUSD/ExerciseModule.t.sol";

/// @title ClaimVerification — execution audit of the seven unproven cross-module claims
/// @notice Every finding in `docs/CROSS-MODULE-VALUE-CONSERVATION.md` and `docs/AGGREGATE-CRE-COMPROMISE.md` §5
///         was, until now, a CODE TRACE. This file is the harness those claims always needed: the REAL
///         `SzipNavOracle` wired into the REAL `RecycleModule`, `DefaultCoordinator`, `DurationFreezeModule` and
///         `ExerciseModule` over relaying Safes, so cross-module value conservation is measured, not argued.
///
///         Verdicts carried by this file:
///           F1  (divert double-count)              — PROVEN   (`test_PROVEN_F1_*`)
///           F2  (freeze whitelist admits $0 legs)  — PROVEN, in a corrected form (`test_PROVEN_F2_*`);
///                                                    the "passes at ANY coverage level" variant is REFUTED
///                                                    (`test_REFUTED_F2_*`)
///           A3  (unbounded reversible provision)   — PROVEN   (`test_PROVEN_A3_*`)
///           F3  (discounted-zipUSD issuance arb)   — premises only; the arb needs an exogenous market price
///           F4  (engine/main-Safe identity)        — PROVEN   (`test_PROVEN_F4_*`)
///           F7  (failed sellHydx strands a strike) — UNREACHABLE-IN-TEST (an off-chain keeper plan)
///           F5  (poke-collision TWAP drag)         — PROVEN   (`test_PROVEN_F5_*`)

// ============================================================================================================
//  Shared oracle harness
// ============================================================================================================

/// @dev Builds the REAL `SzipNavOracle` over reused mock legs. Production params (`W = 3600`, `NAV_MAX_AGE = 1d`).
abstract contract RealOracleBase is Test {
    uint32 internal constant W = 3600;
    uint256 internal constant MAX_AGE = 86_400;

    address internal forwarder = makeAddr("navForwarder");

    MockERC20 internal zip; // 18-dp $1
    MockERC20 internal usdcTok; // 6-dp $1
    MockXAlphaToken internal xa; // 18-dp, exchangeRate()
    MockERC20 internal hydxTok; // 18-dp, marked $0
    MockOHydxToken internal ohydxTok; // 18-dp, marked $0
    MockERC20 internal szip; // the share token (denominator)

    SzipNavOracle internal nav;

    function _deployOracle(address mainSafe, address sidecar) internal {
        zip = new MockERC20(18);
        usdcTok = new MockERC20(6);
        xa = new MockXAlphaToken(18);
        hydxTok = new MockERC20(18);
        ohydxTok = new MockOHydxToken(18, 0);
        szip = new MockERC20(18);

        nav = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdcTok),
            address(xa),
            address(hydxTok),
            address(ohydxTok),
            mainSafe,
            sidecar,
            W,
            MAX_AGE
        );
        nav.setShareToken(address(szip));
        _pushLegs(1e18, 1e18);
    }

    function _pushLegs(uint256 alphaUSD, uint256 hydxUSD) internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = nav.LEG_ALPHA_USD();
        legs[1] = nav.LEG_HYDX_USD();
        ps[0] = alphaUSD;
        ps[1] = hydxUSD;
        vm.prank(forwarder);
        nav.onReport("", abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp))));
    }
}

// ============================================================================================================
//  F1 + A3 — the loss lane: RecycleModule.divert ⟂ DefaultCoordinator.provision, over the REAL oracle
// ============================================================================================================

/// @dev The harness `RecycleModule.t.sol` never had: the REAL `SzipNavOracle` (not `MockNavProvision`) behind
///      `divert`, with the REAL `DefaultCoordinator` as its sole provision writer. `divert`'s USDC leaves the
///      Safe the oracle counts, so `grossBasketValue()` moves for real.
contract F1DivertDoubleCountTest is RealOracleBase {
    ExecSafe internal engine; // engine Safe == main Safe (the deploy convention, F4)
    RecycleModule internal recycle;
    DefaultCoordinator internal coord;
    LienXAlphaEscrow internal escrow;
    EEMock internal eePool;

    address internal timelock = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal warehouse = makeAddr("warehouseSafe");
    address internal adminSafe = makeAddr("adminSafe");
    address internal originator = makeAddr("originator");
    address internal holder = makeAddr("szipHolder");
    address internal sidecar = makeAddr("juniorTrancheSidecar");

    bytes32 internal constant LIEN = bytes32(uint256(0xA));
    uint256 internal constant BOND = 1e18; // xALPHA first-loss bond
    uint256 internal constant BASKET_USDC6 = 10_000_000e6; // $10M counted basket
    uint256 internal constant SUPPLY = 10_000_000e18; // 10M szipUSD ⇒ nav $1.00
    uint256 internal constant HOLE18 = 1_000_000e18; // the $1M impairment
    uint256 internal constant FILL6 = 1_000_000e6; // the $1M cash settlement

    function setUp() public {
        vm.warp(1_000_000);
        engine = new ExecSafe();
        engine.setLive(true);

        _deployOracle(address(engine), sidecar);
        nav.setJuniorTrancheEngine(address(engine)); // engine Safe IS the main Safe

        // the loss lane: REAL coordinator + REAL escrow, wired as the oracle's sole provision writer
        coord = new DefaultCoordinator(forwarder, address(nav), address(xa), 0); // recoveryFloor 0 ⇒ provision == atRisk
        escrow = new LienXAlphaEscrow(address(xa), address(coord), adminSafe, address(engine));
        coord.setEscrow(address(escrow));
        nav.setDefaultCoordinator(address(coord));

        // the free-value lane: REAL RecycleModule on the engine Safe, reading the REAL oracle's provision()
        eePool = new EEMock(address(usdcTok));
        recycle = RecycleModule(Clones.clone(address(new RecycleModule())));
        recycle.setUp(
            abi.encode(
                timelock,
                address(engine),
                operator,
                makeAddr("zipDepositModule"),
                address(usdcTok),
                address(nav),
                address(eePool),
                warehouse
            )
        );

        // the F1 seam: divert settles the markdown through the coordinator, atomically with the cash. The module
        // reads the coordinator live off the oracle, so only the acceptance side needs wiring here.
        coord.setRecycleModule(address(recycle));

        // fund: $10M counted USDC in the Safe, 10M szipUSD outstanding ⇒ spot NAV $1.00
        usdcTok.mint(address(engine), BASKET_USDC6);
        szip.mint(holder, SUPPLY);
        xa.mint(address(coord), BOND); // just-in-time bond funding (item-10 discipline)
    }

    // ------------------------------------------------------------------ report helpers
    function _drive(uint8 action, bytes memory data) internal {
        vm.prank(forwarder);
        coord.onReport("", abi.encode(uint8(8), abi.encode(action, data)));
    }

    function _lock() internal {
        _drive(0, abi.encode(LIEN, originator, BOND));
    }

    function _default(uint256 atRisk) internal {
        _drive(2, abi.encode(LIEN, atRisk));
    }

    function _recovery(uint256 proceeds) internal {
        _drive(3, abi.encode(LIEN, proceeds));
    }

    function _writeOff() internal {
        _drive(5, abi.encode(LIEN, BOND)); // full capital slash ⇒ nothing routes to the cohort Safe
    }

    // ================================================================= F1 (FIXED — regression guard)
    /// @notice THE REGRESSION GUARD for F1. Before the fix, `divert` settled the impairment in CASH out of a
    ///         COUNTED basket leg and never wrote `provision`, so the same $1M was subtracted from NAV twice, and a
    ///         `WriteOff` froze the understatement permanently because both heal paths require `Defaulted`.
    ///         `divert` now settles through `DefaultCoordinator.settleFromJunior` in the same transaction, so gross
    ///         and provision fall together and reported NAV equals true NAV throughout. The original inverted
    ///         assertions are kept inline below as `// was:` so the fix is legible against the defect it closes.
    function test_PROVEN_F1_divert_settles_the_markdown_atomically() public {
        assertEq(nav.grossBasketValue(), 10_000_000e18, "baseline gross $10M");
        assertEq(nav.spotNavPerShare(), 1e18, "baseline nav $1.00");

        // ---------------- the markdown
        _lock();
        _default(HOLE18);
        assertEq(nav.provision(), HOLE18, "the coordinator marked the $1M hole");
        assertEq(nav.spotNavPerShare(), 0.9e18, "nav marked down to $0.90 by the provision");

        // ---------------- a PARTIAL cash settlement of that same hole ($500k of the $1M)
        uint256 half6 = FILL6 / 2;
        uint256 half18 = HOLE18 / 2;
        vm.prank(operator);
        recycle.creditFreeValue(FILL6);
        vm.prank(operator);
        recycle.divert(LIEN, half6);

        assertEq(usdcTok.balanceOf(address(engine)), 9_500_000e6, "$500k of COUNTED basket USDC left the Safe");
        assertEq(usdcTok.balanceOf(address(eePool)), half6, "...and landed in the senior pool");
        assertEq(eePool.balanceOf(warehouse), half6, "...crediting the warehouse Safe");
        assertEq(nav.grossBasketValue(), 9_500_000e18, "gross fell by the settlement");

        // ---------------- NO double count: the markdown moved with the cash, by the same amount
        // was: assertEq(nav.provision(), HOLE18, "divert did NOT write provision")
        assertEq(nav.provision(), half18, "the cash settlement retired exactly what it paid");
        (, uint256 lienP) = coord.lienLoss(LIEN);
        assertEq(lienP, half18, "and it came off the LIEN's slot, not just the aggregate");
        assertEq(coord.totalProvision(), nav.provision(), "invariant (b): totalProvision == oracle provision");

        uint256 reported = nav.spotNavPerShare();
        uint256 truth = (nav.grossBasketValue() - nav.provision()) * 1e18 / SUPPLY;
        // was: assertEq(reported, 0.8e18) / assertEq(truth - reported, HOLE18 * 1e18 / SUPPLY)
        assertEq(reported, truth, "reported == true: the loss is counted exactly once, not twice");
        assertEq(reported, 0.9e18, "still $0.90 - $500k of gross gone, $500k of markdown gone with it");

        // ---------------- the WriteOff residual is no longer a permanent understatement
        _writeOff();
        (DefaultCoordinator.LienStatus st, uint256 p) = coord.lienLoss(LIEN);
        assertEq(uint8(st), uint8(DefaultCoordinator.LienStatus.WrittenOff), "terminal WrittenOff");
        assertEq(p, half18, "the residual provision is still left in place by design");

        // Recovery/Resolve still cannot reach a written-off lien — that gate is unchanged and intentional.
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        _recovery(half18);
        vm.expectRevert(DefaultCoordinator.BadStatus.selector);
        _drive(4, abi.encode(LIEN, uint256(0)));

        // ...but junior CASH can settle it, which is exactly what makes the understatement non-permanent.
        vm.prank(operator);
        recycle.divert(LIEN, half6);
        assertEq(nav.provision(), 0, "a WRITTEN-OFF markdown is settleable by the cash that pays it");
        assertEq(nav.spotNavPerShare(), nav.grossBasketValue() * 1e18 / SUPPLY, "reported == true after writeoff");

        // ---------------- and with the hole closed, divert is locked out again
        vm.prank(operator);
        recycle.creditFreeValue(1e6);
        vm.prank(operator);
        vm.expectRevert(RecycleModule.NoHole.selector);
        recycle.divert(LIEN, 1e6);
    }

    // ================================================================= A3
    /// @notice THE DECIDING TEST for A3 (`AGGREGATE-CRE-COMPROMISE.md` §5). `_default` accepts ANY `atRisk` — the
    ///         only on-chain transform is the `recoveryFloor` scaling — and `_recovery` reverses it by an
    ///         `recoveryProceeds` that NOTHING on-chain corroborates: no transfer, no balance change, no receipt.
    function test_PROVEN_A3_provision_is_an_unbounded_reversible_dial() public {
        _lock();
        assertEq(nav.spotNavPerShare(), 1e18, "baseline");

        // ---------------- DOWN: unbounded. $1 trillion of "atRisk" against a $10M basket is accepted.
        uint256 absurd = 1_000_000_000_000e18;
        _default(absurd);
        assertEq(nav.provision(), absurd, "the oracle accepted a provision 100,000x the basket");
        assertEq(nav.spotNavPerShare(), 0, "spot NAV floored at ZERO");
        assertEq(nav.navExit(), 0, "and the exit price with it - every exiter is paid nothing");

        // ---------------- UP: reversible, on an unverified scalar. Snapshot every balance that could be a receipt.
        uint256 safeUsdcBefore = usdcTok.balanceOf(address(engine));
        uint256 safeXaBefore = xa.balanceOf(address(engine));
        uint256 escrowXaBefore = xa.balanceOf(address(escrow));
        uint256 coordXaBefore = xa.balanceOf(address(coord));

        _recovery(absurd); // "recoveryProceeds" — no asset accompanies it

        assertEq(nav.provision(), 0, "the entire markdown was reversed by a bare scalar");
        assertEq(nav.spotNavPerShare(), 1e18, "nav restored to $1.00");
        assertEq(usdcTok.balanceOf(address(engine)), safeUsdcBefore, "NO USDC receipt landed anywhere");
        assertEq(xa.balanceOf(address(engine)), safeXaBefore, "NO xALPHA receipt landed in the basket");
        assertEq(xa.balanceOf(address(escrow)), escrowXaBefore, "the bond escrow was untouched");
        assertEq(xa.balanceOf(address(coord)), coordXaBefore, "the coordinator was untouched");
    }
}

// ============================================================================================================
//  F2 — the freeze whitelist admits the $0-marked legs, over the REAL oracle
// ============================================================================================================

/// @dev The harness `DurationFreezeModule.t.sol` never had in its UNIT suite: the REAL `SzipNavOracle` behind the
///      floor, so the 2026-07-30 `$0` marking of HYDX/oHYDX is expressed rather than modelled away by a settable
///      `MockNavBasket` that sums every token naively.
contract F2FreezeWhitelistTest is RealOracleBase {
    FreezeSafe internal mainSafe;
    FreezeSafe internal sidecarSafe;
    DurationFreezeModule internal freeze;
    MockEulerEarn internal ee;

    address internal timelock = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal warehouse = makeAddr("warehouseSafe");

    uint256 internal constant SIDECAR_USDC6 = 1_000_000e6; // $1M of committed, VALUED collateral
    uint256 internal constant SIDECAR_HYDX = 1_000_000e18; // $0-marked inventory sitting in the freeze

    function setUp() public {
        vm.warp(1_000_000);
        mainSafe = new FreezeSafe();
        sidecarSafe = new FreezeSafe();

        _deployOracle(address(mainSafe), address(sidecarSafe));
        nav.setJuniorTrancheEngine(address(mainSafe));

        ee = new MockEulerEarn();
        freeze = DurationFreezeModule(Clones.clone(address(new DurationFreezeModule())));
        freeze.setUp(
            abi.encode(timelock, address(mainSafe), address(sidecarSafe), operator, address(nav), address(ee), warehouse)
        );

        usdcTok.mint(address(sidecarSafe), SIDECAR_USDC6);
        hydxTok.mint(address(sidecarSafe), SIDECAR_HYDX);
        ohydxTok.mint(address(sidecarSafe), SIDECAR_HYDX);
        szip.mint(makeAddr("szipHolder"), 1_000_000e18);
    }

    /// @dev Senior backing: `illiquidSeniorValue = (sa - free) * 1e12`.
    function _setSeniorDebt(uint256 usdc6) internal {
        ee.setBacking(1, usdc6, 0);
    }

    /// @notice THE DECIDING TEST for F2. At EXACTLY zero floor headroom — where a 1-wei release of any VALUED leg
    ///         reverts — the whitelist still lets the ENTIRE $0-marked HYDX and oHYDX inventory walk out of the
    ///         freeze, because `committedValue()` and `grossBasketValue()` both move zero. That is precisely the
    ///         leak `onlyValued`'s own docstring says it exists to prevent (security #6).
    function test_PROVEN_F2_zero_headroom_still_admits_the_dollar_zero_legs() public {
        _setSeniorDebt(1_000_000e6); // floor == $1M == coverage ⇒ zero headroom

        assertEq(nav.committedValue(), 1_000_000e18, "HYDX/oHYDX contribute NOTHING to committed value");
        assertEq(nav.grossBasketValue(), 1_000_000e18, "...nor to gross");
        assertEq(freeze.coverageValue(), freeze.requiredCommittedValue(), "coverage sits EXACTLY on the floor");
        assertTrue(freeze.covered(), "covered, with zero headroom");

        // the whitelist working as intended: a 1-wei valued release is refused
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 1_000_000e18 - 1e12, 1_000_000e18)
        );
        freeze.release(address(usdcTok), 1);

        // ...and the whitelist defeating itself: the FULL $0-marked inventory leaves, unbounded, in the same state
        uint256 cov = freeze.coverageValue();
        vm.prank(operator);
        freeze.release(address(hydxTok), SIDECAR_HYDX);
        vm.prank(operator);
        freeze.release(address(ohydxTok), SIDECAR_HYDX);

        assertEq(hydxTok.balanceOf(address(sidecarSafe)), 0, "the freeze lost ALL its HYDX");
        assertEq(ohydxTok.balanceOf(address(sidecarSafe)), 0, "...and ALL its oHYDX");
        assertEq(hydxTok.balanceOf(address(mainSafe)), SIDECAR_HYDX, "it is now free-side, monetizable");
        assertEq(ohydxTok.balanceOf(address(mainSafe)), SIDECAR_HYDX, "...as is the option inventory");
        assertEq(freeze.coverageValue(), cov, "the coverage numerator never moved - the floor never saw it");
        assertEq(usdcTok.balanceOf(address(sidecarSafe)), SIDECAR_USDC6, "no valued leg could follow it out");
    }

    /// @notice THE REFUTATION. The F2 write-up claimed the post-move floor check "passes unconditionally at any
    ///         coverage level, including deeply undercovered", and built its exploit on an UNDERCOVERED protocol
    ///         opening the run hatch. It does not. The check is absolute (`coverageValue >= floor`), not a delta:
    ///         a $0-marked release moves neither side, so an already-breached state stays breached and REVERTS.
    ///         The leak is real but strictly bounded to states that are already covered.
    function test_REFUTED_F2_undercovered_release_of_hydx_still_reverts() public {
        usdcTok.mint(address(mainSafe), 1_000_000e6); // free-side value ⇒ gross $2M, coverage $1M
        _setSeniorDebt(1_500_000e6); // floor $1.5M > coverage $1M ⇒ deeply undercovered

        assertEq(freeze.coverageValue(), 1_000_000e18, "coverage $1M");
        assertEq(freeze.requiredCommittedValue(), 1_500_000e18, "floor $1.5M");
        assertFalse(freeze.covered(), "the protocol IS undercovered - the run-hatch precondition");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 1_000_000e18, 1_500_000e18)
        );
        freeze.release(address(hydxTok), SIDECAR_HYDX);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(DurationFreezeModule.FreezeFloorBreach.selector, 1_000_000e18, 1_500_000e18)
        );
        freeze.release(address(ohydxTok), SIDECAR_HYDX);

        assertEq(hydxTok.balanceOf(address(sidecarSafe)), SIDECAR_HYDX, "nothing left the freeze");
    }
}

// ============================================================================================================
//  F4 — engine/main-Safe identity is a deploy convention, not an invariant
// ============================================================================================================

contract F4EngineIdentityTest is RealOracleBase {
    address internal mainSafe = makeAddr("juniorTrancheSafe");
    address internal sidecar = makeAddr("juniorTrancheSidecar");
    address internal engine = makeAddr("aDivergentEngineSafe");
    address internal holder = makeAddr("szipHolder");

    function setUp() public {
        vm.warp(1_000_000);
        _deployOracle(mainSafe, sidecar);
    }

    /// @notice THE REGRESSION GUARD for F4. `juniorTrancheEngine` and `juniorTrancheSafe` are one address with two
    ///         role names (`docs/safe-identities.md`), and nothing enforced that until 2026-08-02. The numerator
    ///         counts the safe while the denominator excludes the engine, so a divergence made every engine-held
    ///         asset invisible to NAV while still shrinking supply. The setter now rejects anything but the safe.
    function test_PROVEN_F4_engine_safe_divergence_is_unasserted_and_zeroes_nav() public {
        usdcTok.mint(mainSafe, 10_000_000e6);
        szip.mint(holder, 10_000_000e18);

        nav.setJuniorTrancheEngine(mainSafe); // the only legal value
        assertEq(nav.juniorTrancheEngine(), nav.juniorTrancheSafe(), "engine == safe, now an invariant");
        assertEq(nav.spotNavPerShare(), 1e18, "$1.00");

        // was: the setter accepted this silently, and NAV went to zero with the basket intact.
        vm.expectRevert(
            abi.encodeWithSelector(SzipNavOracle.EngineMustEqualSafe.selector, engine, nav.juniorTrancheSafe())
        );
        nav.setJuniorTrancheEngine(engine);

        // the coincidence held, so nothing moved
        assertEq(nav.juniorTrancheEngine(), nav.juniorTrancheSafe(), "still equal after the rejected re-point");
        assertEq(nav.grossBasketValue(), 10_000_000e18, "gross still counts the whole USDC leg");
        assertEq(nav.spotNavPerShare(), 1e18, "NAV unmoved");
        assertGt(nav.navExit(), 0, "navExit never collapsed");

        // the denominator exclusion still works — against the safe, which is the engine
        vm.prank(holder);
        szip.transfer(mainSafe, 4_000_000e18);
        assertEq(
            nav.spotNavPerShare(),
            uint256(10_000_000e18) * 1e18 / uint256(6_000_000e18),
            "10M/6M: the engine's szipUSD excluded"
        );
    }
}

// ============================================================================================================
//  F3 — the two on-chain premises of the discounted-zipUSD issuance arb
// ============================================================================================================

contract F3ZipUsdParTest is RealOracleBase {
    address internal mainSafe = makeAddr("juniorTrancheSafe");
    address internal sidecar = makeAddr("juniorTrancheSidecar");
    ZipRedemptionQueue internal queue;

    address internal controller = makeAddr("zipcodeController");
    address internal redeemController = makeAddr("offRampModule");
    address internal publicHolder = makeAddr("aRealZipUsdHolder");

    function setUp() public {
        vm.warp(1_000_000);
        _deployOracle(mainSafe, sidecar);
        queue = new ZipRedemptionQueue(address(zip), address(usdcTok), controller);
        queue.setRedeemController(redeemController);
    }

    /// @notice F3's two premises, EXECUTED. They are only premises: the arb itself needs zipUSD to trade below par
    ///         on a venue this system cannot observe, so the profit leg is not expressible on-chain (see the
    ///         downgraded doc entry). What IS shown: the issuance valuation is a hard par mark with no reference to
    ///         realizable backing, and no public actor can redeem at par to pin it there.
    function test_F3_premises_hard_par_valuation_and_no_public_par_redemption() public {
        // (1) the issuance input mark — the exact call `ExitGate.depositFor` makes (`ExitGate.sol:166-169`)
        assertEq(nav.valueOf(address(zip), 1_000_000e18), 1_000_000e18, "zipUSD valued at a hard $1.00");
        // the mark is a constant: nothing about basket state, impairment or the pushed legs can move it
        vm.warp(block.timestamp + 1); // strictly-newer leg push
        _pushLegs(0.01e18, 0.01e18);
        xa.setExchangeRate(0.01e18);
        assertEq(nav.valueOf(address(zip), 1_000_000e18), 1_000_000e18, "still $1.00 - the leg has no price input");

        // (2) the missing par arb: the only redeem lane is controller-gated, so no public holder can arbitrage a
        //     discount back to par against the protocol
        vm.prank(publicHolder);
        vm.expectRevert(ZipRedemptionQueue.NotRedeemController.selector);
        queue.requestRedeem(1_000_000e18, publicHolder, publicHolder);
    }
}

// ============================================================================================================
//  F5 — the exercise→sell window and the TWAP, over the REAL oracle
// ============================================================================================================

contract F5ExerciseTwapTest is RealOracleBase {
    ExecSafe internal engine;
    ExerciseModule internal exercise;
    MockOHYDX internal oToken;

    address internal timelock = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal keeper = makeAddr("honestKeeper");
    address internal holder = makeAddr("szipHolder");
    address internal sidecar = makeAddr("juniorTrancheSidecar");

    uint256 internal constant BASKET_USDC6 = 10_000_000e6;
    uint256 internal constant SUPPLY = 10_000_000e18;
    uint256 internal constant STRIKE6 = 100_000e6; // the paid strike: 1% of gross

    function setUp() public {
        vm.warp(1_000_000);
        engine = new ExecSafe();
        engine.setLive(true);

        _deployOracle(address(engine), sidecar);
        nav.setJuniorTrancheEngine(address(engine)); // engine Safe IS the counted main Safe

        oToken = new MockOHYDX(address(usdcTok));
        oToken.setPaymentReturn(STRIKE6);
        exercise = ExerciseModule(Clones.clone(address(new ExerciseModule())));
        exercise.setUp(abi.encode(timelock, address(engine), operator, address(oToken)));

        usdcTok.mint(address(engine), BASKET_USDC6);
        szip.mint(holder, SUPPLY);

        // >= W of honest TWAP history at exactly $1.00 (a keeper poking every 72s ~ obsSpacing)
        for (uint256 i = 0; i < 130; i++) {
            vm.warp(block.timestamp + 72);
            vm.prank(keeper);
            nav.poke();
        }
        assertEq(nav.twapNavPerShare(), 1e18, "honest history");
    }

    function _exerciseStrike() internal {
        vm.prank(operator);
        exercise.exercise(1e18, STRIKE6, block.timestamp + 1 hours);
    }

    /// @dev Model `SellModule.sellHydx` landing the proceeds back in the counted Safe (HYDX itself is marked $0,
    ///      so gross recovers ONLY when USDC returns).
    function _sellRestores() internal {
        usdcTok.mint(address(engine), STRIKE6);
    }

    /// @notice THE DECIDING TEST for the re-scoped F5. Two identical exercise→sell cycles, differing only in
    ///         whether a `poke()` lands inside the window. The dip is real and NAV-visible either way; the TWAP
    ///         effect is entirely poke-collision-conditional, and when it does collide the depressed spot is
    ///         applied RETROACTIVELY over the whole gap since the last poke.
    function test_PROVEN_F5_poke_inside_exercise_window_drags_the_twap() public {
        // ---------------- the dip itself is real and counted
        uint256 grossBefore = nav.grossBasketValue();
        vm.warp(block.timestamp + 600); // a 600s gap since the last poke
        _exerciseStrike();
        assertEq(usdcTok.balanceOf(address(engine)), BASKET_USDC6 - STRIKE6, "the strike left a COUNTED leg");
        assertEq(nav.grossBasketValue(), grossBefore - 100_000e18, "gross destroyed by the full strike");
        assertEq(nav.spotNavPerShare(), 0.99e18, "spot dips 1%");
        assertEq(nav.navExit(), 0.99e18, "navExit picks the depressed SPOT immediately - the first-order harm");

        // ---------------- CONTROL: no poke lands inside the window ⇒ zero TWAP contribution
        vm.warp(block.timestamp + 60);
        _sellRestores();
        vm.prank(keeper);
        nav.poke(); // books the RESTORED spot over the whole 660s
        assertEq(nav.spotNavPerShare(), 1e18, "gross restored");
        assertEq(nav.twapNavPerShare(), 1e18, "TWAP untouched - the dip contributed EXACTLY zero");

        // ---------------- COLLISION: the same cycle, with one poke inside the window
        vm.warp(block.timestamp + 600); // an identical 600s gap since the last poke
        _exerciseStrike();
        vm.prank(keeper);
        nav.poke(); // the collision: books 0.99 over the ENTIRE 600s gap, retroactively
        vm.warp(block.timestamp + 60);
        _sellRestores();
        vm.prank(keeper);
        nav.poke();

        uint256 twap = nav.twapNavPerShare();
        assertEq(nav.spotNavPerShare(), 1e18, "gross restored again - the dip lasted 60s of wall clock");
        assertLt(twap, 1e18, "yet the TWAP is dragged below true NAV");
        // the drag is ~ (gap/W) * dip = (600/3600) * 0.01 -- the 600s of history the poke re-marked, not the 60s dip
        uint256 drag = 1e18 - twap;
        assertGt(drag, 1.5e15, "the drag reflects the 600s GAP, not the 60s window - retroactive amplification");
        assertLt(drag, 1.8e15, "...bounded by (gap/W) * dip");
        console2.log("TWAP after collision (18dp):", twap);
        console2.log("drag (18dp):               ", drag);
    }
}
