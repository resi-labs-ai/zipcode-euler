// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SzipNavOracle} from "../../src/supply/SzipNavOracle.sol";
import {
    MockToken,
    MockXAlpha,
    MockOHydx,
    MockICHIVault,
    MockGauge,
    MockEscrowVault,
    MockBorrowVault,
    MockRedemptionQueue
} from "./SzipNavOracle.t.sol";

/// @dev A SELF-CONSISTENT stand-in for `SzAlphaRateOracle` (unlike the deterministic suite's `MockRateOracle`,
///      whose `fresh()` is a hand-set bool): `fresh()` is DERIVED from `lastUpdate`/`maxStaleness` exactly like the
///      real oracle, so the freshness-coherence invariant tests the NAV oracle's fold logic, never a mock artifact.
///      `maxStaleness` is set BELOW the NAV `maxAge` so the SEC-13 rate-window fence shift in
///      `oldestRequiredLegTs()` is live on every read.
contract InvariantRateFeed {
    uint256 public exchangeRate;
    uint48 public lastUpdate;
    uint256 public immutable maxStaleness;

    constructor(uint256 maxStaleness_, uint256 rate0, uint48 ts0) {
        maxStaleness = maxStaleness_;
        exchangeRate = rate0;
        lastUpdate = ts0;
    }

    function set(uint256 rate, uint48 ts) external {
        exchangeRate = rate;
        lastUpdate = ts;
    }

    function fresh() external view returns (bool) {
        return lastUpdate != 0 && block.timestamp - lastUpdate <= maxStaleness;
    }
}

/// @dev Bounded action driver for the NAV-oracle invariant suite. Every action lands in a LEGAL state — illegal
///      pushes (zero price, future ts, non-strictly-newer ts, band breach) are already deterministically tested, so
///      the handler stays inside the band/ordering rules and the "Reverts" column must read 0. Legality is also what
///      scopes the decomposition invariant: per-Safe debt is bounded by that Safe's zipUSD leg (the borrow loop
///      credits what it borrows), so the per-Safe saturation branch in `_grossValueOf` is never the source of a
///      gross-vs-sum gap — any gap the fuzzer finds is pure rounding. Ghost: `ghostCumNav` is the accumulator
///      watermark for the monotonicity invariant.
contract SzipNavOracleInvariantHandler is Test {
    struct Env {
        SzipNavOracle oracle;
        address forwarder;
        address dc;
        address safeMain;
        address sidecar;
        address engine;
        MockToken zip;
        MockToken usdcT;
        MockXAlpha xa;
        MockToken szip;
        MockICHIVault ichi;
        MockGauge gauge;
        MockEscrowVault escrow;
        MockBorrowVault borrow;
        MockRedemptionQueue queue;
        InvariantRateFeed feed;
    }

    SzipNavOracle internal oracle;
    address internal forwarder;
    address internal dc;
    address internal safeMain;
    address internal sidecar;
    address internal engine;
    MockToken internal zip;
    MockToken internal usdcT;
    MockXAlpha internal xa;
    MockToken internal szip;
    MockICHIVault internal ichi;
    MockGauge internal gauge;
    MockEscrowVault internal escrow;
    MockBorrowVault internal borrow;
    MockRedemptionQueue internal queue;
    InvariantRateFeed internal feed;
    // Global price sanity range for the CRE walk: [1¢, $100]. This is the ONLY constraint on a push — the per-push
    // deviation band was removed 2026-07-31, so the walk jumps freely inside the range rather than stepping around
    // the prior mark (see `_legalPrice`). Any value in the range is a LEGAL push the forwarder could really deliver.
    uint256 internal constant PRICE_MIN = 0.01e18;
    uint256 internal constant PRICE_MAX = 100e18;

    /// @notice Monotone watermark of `cumNav` — the accumulator may never decrease (ring/TWAP integrity).
    uint256 public ghostCumNav;

    constructor(Env memory e) {
        oracle = e.oracle;
        forwarder = e.forwarder;
        dc = e.dc;
        safeMain = e.safeMain;
        sidecar = e.sidecar;
        engine = e.engine;
        zip = e.zip;
        usdcT = e.usdcT;
        xa = e.xa;
        szip = e.szip;
        ichi = e.ichi;
        gauge = e.gauge;
        escrow = e.escrow;
        borrow = e.borrow;
        queue = e.queue;
        feed = e.feed;
    }

    // ----------------------------------------------------------------- CRE leg pushes (the forwarder)
    /// @notice Push BOTH legs through the forwarder with a strictly-newer ts and in-range prices (a same-ts
    ///         re-push is `StaleReport`, hence the mandatory >=1s warp). Every push can land anywhere in
    ///         [PRICE_MIN, PRICE_MAX] — there is no per-push band to step around (removed 2026-07-31).
    function pushLegs(uint256 pASeed, uint256 pHSeed, uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1, 6 hours));
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = 0; // LEG_ALPHA_USD
        legs[1] = 1; // LEG_HYDX_USD
        ps[0] = _legalPrice(0, pASeed);
        ps[1] = _legalPrice(1, pHSeed);
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);
        _syncCum();
    }

    /// @dev A price anywhere in the full sanity range. The per-push deviation band was REMOVED 2026-07-31, so the
    ///      walk is deliberately NOT constrained to a band around the prior any more — it jumps freely across
    ///      [PRICE_MIN, PRICE_MAX]. That is the point: the invariants below must hold under arbitrary honest price
    ///      moves (a crash, a spike), which is exactly what the band used to hide from this fuzzer.
    ///      Keeping the old band-relative walk here would have kept passing while silently narrowing coverage.
    function _legalPrice(uint8, uint256 seed) internal pure returns (uint256) {
        return bound(seed, PRICE_MIN, PRICE_MAX);
    }

    // ----------------------------------------------------------------- TWAP maintenance
    /// @notice `poke()` at fuzzed gaps: 0 (same-block), sub-`obsSpacing` (head refresh-in-place), past `obsSpacing`
    ///         (new slot), and past `W` (window exit). Repeated max-gap pokes wrap the 65-slot ring several times per
    ///         run. The second same-block poke asserts idempotency (invariant 5b) at every visited state.
    function poke(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 0, 8 hours));
        oracle.poke();
        _syncCum();
        uint256 cumBefore = oracle.cumNav();
        uint32 luBefore = oracle.lastUpdate();
        uint16 idxBefore = oracle.obsIndex();
        oracle.poke(); // dt == 0 ⇒ must be a total no-op
        assertEq(oracle.cumNav(), cumBefore, "poke not idempotent in-block: cumNav");
        assertEq(oracle.lastUpdate(), luBefore, "poke not idempotent in-block: lastUpdate");
        assertEq(oracle.obsIndex(), idxBefore, "poke not idempotent in-block: obsIndex");
    }

    /// @notice Bare time advance (no accumulate) — grows the un-booked `[lastUpdate, now]` leading segment the TWAP
    ///         values at current spot, and pushes the legs/rate toward staleness (`maxAge` 12h, rate window 6h).
    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1, 3 days));
    }

    // ----------------------------------------------------------------- DefaultCoordinator
    /// @notice `writeProvision` as the sole authorized writer. UNBOUNDED at the oracle by design — the ceiling here
    ///         (1e30, ~1000x any reachable basket) routinely drives `provision > grossBasketValue()`, the spot
    ///         saturation edge (invariant 4).
    function writeProvision(uint256 pSeed) external {
        vm.prank(dc);
        oracle.writeProvision(bound(pSeed, 0, 1e30));
        _syncCum();
    }

    // ----------------------------------------------------------------- basket state
    /// @notice Value inflow: fund a Safe's plain legs (deposit proceeds / harvest landings). ADDITIVE only, so the
    ///         zipUSD leg that collateralizes `farmLoop`'s debt bound never shrinks below it.
    function fundSafe(uint256 seed, uint256 zipAmt, uint256 usdcAmt, uint256 xaAmt) external {
        address safe = seed % 2 == 0 ? safeMain : sidecar;
        zip.setBalance(safe, zip.balanceOf(safe) + bound(zipAmt, 0, 1e24));
        usdcT.setBalance(safe, usdcT.balanceOf(safe) + bound(usdcAmt, 0, 1e12));
        xa.setBalance(safe, xa.balanceOf(safe) + bound(xaAmt, 0, 1e24));
    }

    /// @notice Reshape the ICHI LP: reserves, supply, and the 6-way share split (loose / gauge-staked /
    ///         escrow-collateralized, per Safe) — the split-LP states the decomposition's double-floor lives in.
    ///         Holders are capped at supply/6 each so the Safes never claim more than the vault's supply.
    function lpReshape(uint256 lSeed, uint256 t0Seed, uint256 t1Seed, uint256 holdSeed) external {
        uint256 supplyLp = bound(lSeed, 1e18, 1e24);
        ichi.set(address(zip), address(xa), supplyLp, bound(t0Seed, 0, 1e24), bound(t1Seed, 0, 1e24));
        uint256 cap = supplyLp / 6;
        ichi.setBalance(safeMain, bound(uint256(keccak256(abi.encode(holdSeed, uint8(0)))), 0, cap));
        ichi.setBalance(sidecar, bound(uint256(keccak256(abi.encode(holdSeed, uint8(1)))), 0, cap));
        gauge.setBalance(safeMain, bound(uint256(keccak256(abi.encode(holdSeed, uint8(2)))), 0, cap));
        gauge.setBalance(sidecar, bound(uint256(keccak256(abi.encode(holdSeed, uint8(3)))), 0, cap));
        escrow.setBalance(safeMain, bound(uint256(keccak256(abi.encode(holdSeed, uint8(4)))), 0, cap));
        escrow.setBalance(sidecar, bound(uint256(keccak256(abi.encode(holdSeed, uint8(5)))), 0, cap));
    }

    /// @notice Farm utility strike debt, bounded so the Safe's zipUSD leg alone covers it (the real loop credits the
    ///         borrowed USDC to the Safe, so a solvent per-Safe state is the legal envelope). This keeps BOTH
    ///         saturation branches (`_grossValueOf` and `grossBasketValue`) un-triggered by debt, which is what makes
    ///         the decomposition identity a pure-rounding claim.
    function farmLoop(uint256 seed, uint256 debtSeed) external {
        address safe = seed % 2 == 0 ? safeMain : sidecar;
        borrow.setDebt(safe, bound(debtSeed, 0, zip.balanceOf(safe) / 1e12));
    }

    /// @notice Off-ramp receivables (SEC/M-2): pending zipUSD (18-dp) + claimable USDC (6-dp) attributed to the main
    ///         Safe — counted once in `freeValue` and once in `grossBasketValue`, so decomposition-neutral.
    function queueFlow(uint256 pSeed, uint256 cSeed) external {
        queue.setPending(safeMain, bound(pSeed, 0, 1e24));
        queue.setClaimable(safeMain, bound(cSeed, 0, 1e12));
    }

    /// @notice Denominator moves: total szipUSD supply (0 revisits the genesis path) and the engine Safe's transient
    ///         pre-burn balance (bounded <= supply — the engine can only hold what exists).
    function supplyShift(uint256 tsSeed, uint256 engSeed) external {
        uint256 total = bound(tsSeed, 0, 1e27);
        szip.setTotalSupply(total);
        szip.setBalance(engine, bound(engSeed, 0, total));
    }

    /// @notice Cross-chain xALPHA rate refresh: nonzero (a zero rate is `RateUnseeded` fail-closed, deterministically
    ///         tested) and stamped at `now` — the feed then goes stale on its own clock as `warp` advances time.
    function rateUpdate(uint256 rSeed) external {
        feed.set(bound(rSeed, 0.5e18, 5e18), uint48(block.timestamp));
    }

    // ----------------------------------------------------------------- ghost
    function _syncCum() internal {
        uint256 c = oracle.cumNav();
        assertGe(c, ghostCumNav, "cumNav decreased (accumulator must be monotone)");
        ghostCumNav = c;
    }
}

/// @notice Stateful fuzz invariant suite for `SzipNavOracle` — the issuance/exit pricing keystone. Closes the last
///         X-Ray gap ("no stateful fuzz"). The handler drives every real mutating surface (forwarder leg pushes,
///         `poke`, `writeProvision`, time, basket/LP/debt/queue/supply state) through LEGAL inputs only, and the
///         invariants assert the properties every consumer stands on:
///         1. bracket asymmetry (`navEntry = max`, `navExit = min` of spot/twap) in every reachable state;
///         2. `navEntry >= navExit` unconditionally when issuance is open (an inversion = mint+exit free money);
///         3. the per-Safe decomposition `committedValue + freeValue` vs `grossBasketValue` (I-16);
///         4. total views + saturation floors (no underflow at any provision, spot floors at 0);
///         5. TWAP accumulator monotonicity + ring coherence + in-block `poke` idempotency;
///         6. freshness coherence (`fresh()` ⇒ every required leg, rate included, inside its window at `now`).
///         Wiring setters are NOT handler actions — the deterministic suite owns setter behavior (I-15); this suite
///         fuzzes the steady-state write surface under a fixed production-shaped wiring.
contract SzipNavOracleInvariantTest is Test {
    SzipNavOracle internal oracle;
    SzipNavOracleInvariantHandler internal handler;

    address internal forwarder = makeAddr("invForwarder");
    address internal juniorTrancheSafe = makeAddr("invJuniorTrancheSafe");
    address internal juniorTrancheSidecar = makeAddr("invJuniorTrancheSidecar");
    address internal dc = makeAddr("invDefaultCoordinator");
    address internal juniorTrancheEngine = makeAddr("invJuniorTrancheEngine");

    MockToken internal zip;
    MockToken internal usdc;
    MockXAlpha internal xa;
    MockToken internal hydx;
    MockOHydx internal ohydx;
    MockToken internal szip;
    MockICHIVault internal ichi;
    MockGauge internal gauge;
    MockEscrowVault internal escrow;
    MockBorrowVault internal borrow;
    MockRedemptionQueue internal queue;
    InvariantRateFeed internal feed;

    uint32 internal constant W = 4 hours;
    uint256 internal constant MAX_AGE = 12 hours;
    uint256 internal constant RATE_STALENESS = 6 hours; // < MAX_AGE ⇒ the SEC-13 fence shift is live
    uint16 internal constant CARDINALITY = 65;

    function setUp() public {
        vm.warp(1_000_000); // a non-zero base time
        zip = new MockToken(18);
        usdc = new MockToken(6);
        xa = new MockXAlpha();
        hydx = new MockToken(18);
        ohydx = new MockOHydx(30);
        szip = new MockToken(18);
        ichi = new MockICHIVault();
        gauge = new MockGauge();
        escrow = new MockEscrowVault();
        borrow = new MockBorrowVault();
        queue = new MockRedemptionQueue();
        feed = new InvariantRateFeed(RATE_STALENESS, 1e18, uint48(block.timestamp));

        oracle = new SzipNavOracle(
            forwarder,
            address(zip),
            address(usdc),
            address(xa),
            address(hydx),
            address(ohydx),
            juniorTrancheSafe,
            juniorTrancheSidecar,
            W,
            MAX_AGE
        );

        // Production-shaped wiring: every leg live (LP in spot mode — `lpTwapWindow == 0`; the fair-LP TWAP path is
        // an Algebra-fork concern, deterministically covered in SEC-10 tests, not the NAV-ring surface fuzzed here).
        oracle.setShareToken(address(szip));
        oracle.setLpPosition(address(ichi), address(gauge));
        oracle.setFarmUtilityLeg(address(escrow), address(borrow));
        oracle.setJuniorTrancheEngine(juniorTrancheEngine);
        oracle.setDefaultCoordinator(dc);
        oracle.setRedemptionQueue(address(queue));
        oracle.setXAlphaRateOracle(address(feed));

        // Seed a live, non-degenerate genesis state: both legs pushed at $1, a funded basket, a real supply.
        _seedLegs();
        ichi.set(address(zip), address(xa), 1000e18, 500e18, 500e18);
        gauge.setBalance(juniorTrancheSafe, 100e18);
        gauge.setBalance(juniorTrancheSidecar, 100e18);
        zip.setBalance(juniorTrancheSafe, 600e18);
        zip.setBalance(juniorTrancheSidecar, 400e18);
        usdc.setBalance(juniorTrancheSafe, 500e6);
        xa.setBalance(juniorTrancheSafe, 200e18);
        szip.setTotalSupply(1500e18);

        handler = new SzipNavOracleInvariantHandler(
            SzipNavOracleInvariantHandler.Env({
                oracle: oracle,
                forwarder: forwarder,
                dc: dc,
                safeMain: juniorTrancheSafe,
                sidecar: juniorTrancheSidecar,
                engine: juniorTrancheEngine,
                zip: zip,
                usdcT: usdc,
                xa: xa,
                szip: szip,
                ichi: ichi,
                gauge: gauge,
                escrow: escrow,
                borrow: borrow,
                queue: queue,
                feed: feed
            })
        );
        targetContract(address(handler));
    }

    function _seedLegs() internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = 0;
        legs[1] = 1;
        ps[0] = 1e18;
        ps[1] = 1e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);
    }

    // ----------------------------------------------------------------- 1. bracket asymmetry
    /// @notice The core defense: `navExit == min(spot, twap)` in EVERY reachable state, and — whenever issuance is
    ///         open — `navEntry == max(spot, twap)`. A sub-window spot move can therefore never be turned into a
    ///         cheap mint or a rich exit.
    function invariant_bracketAsymmetry() public view {
        uint256 s = oracle.spotNavPerShare();
        uint256 t = oracle.twapNavPerShare();
        uint256 x = oracle.navExit();
        assertEq(x, s < t ? s : t, "navExit != min(spot, twap)");
        assertLe(x, s, "navExit above spot");
        assertLe(x, t, "navExit above twap");
        if (oracle.fresh()) {
            uint256 e = oracle.navEntry();
            assertEq(e, s > t ? s : t, "navEntry != max(spot, twap)");
            assertGe(e, s, "navEntry below spot");
            assertGe(e, t, "navEntry below twap");
        }
    }

    // ----------------------------------------------------------------- 2. entry >= exit (no free money)
    /// @notice If this ever inverts, mint-then-exit in one transaction is free money. When issuance is stale-gated,
    ///         `navEntry` MUST revert (the §7 asymmetry: staleness pauses issuance, never exit) and `navExit` must
    ///         still price.
    function invariant_entryNeverBelowExit() public {
        if (oracle.fresh()) {
            assertGe(oracle.navEntry(), oracle.navExit(), "navEntry < navExit: mint+exit is free money");
        } else {
            try oracle.navEntry() returns (uint256) {
                assertTrue(false, "navEntry must revert while a required leg/rate is stale");
            } catch {}
            oracle.navExit(); // exit must keep pricing off the last good mark
        }
    }

    // ----------------------------------------------------------------- 3. decomposition identity (I-16)
    /// @notice `committedValue() + freeValue()` vs `grossBasketValue()`: does not over-count (the direction the freeze
    ///         floor stands on), and the under-count is bounded by the DERIVED rounding tolerance below.
    ///
    ///         The no-over-count direction is CONDITIONAL, not unconditional — the handler is what makes it hold here.
    ///         `grossBasketValue()` saturates on the COMBINED value-minus-debt while `_grossValueOf()` saturates PER
    ///         SAFE, so a Safe whose farm-utility debt exceeds its own valued legs has that shortfall floored away
    ///         instead of reducing the other Safe's value ⇒ `sum > gross`, with no rounding bound. This suite's
    ///         `farmLoop` action deliberately fences that state off, so the assertion below is sound as written; the
    ///         *documentation* claiming the direction holds always is what is wrong.
    ///
    ///         FINDING (this suite, first run): the documented I-16 tolerance — "EXACT for plain legs, <=2 wei for a
    ///         split LP" (`SzipNavOracle.sol` `committedValue` NatSpec + x-ray I-16) — is FALSIFIED once the xALPHA
    ///         USD mark leaves exactly $1.00. Forge's shrunk counterexample was 2 calls: `pushLegs` (one legal
    ///         in-band push moving alphaUSD off $1) then `lpReshape` (splitting the LP across the Safes) ⇒ gap 3 wei
    ///         > 2. Root cause: the "<=2 wei" claim implicitly assumes the OUTER `_tokenValue` division
    ///         (`amt * price / 1e18`) is lossless, which holds only at price == 1e18; off $1 the per-Safe double
    ///         floor amplifies through the price. Pinned deterministically in
    ///         `test_finding_decompositionGap_scalesWithXAlphaMark_beyond2wei` (gap == 3 from a single legal 20%
    ///         push). Economically nil (wei-scale on 1e18-dp USD), never an over-count — but the NatSpec/x-ray
    ///         constant should be corrected to the price-aware bound.
    ///
    ///         Derived bound (per-token deltas, e_j <= 1 the inner pro-rata floor loss):
    ///           token0 (zip, $1 exact):  delta0 <= e0 <= 1
    ///           token1 (xa,  px):        delta1 <= e1*floor(px/1e18) + 2
    ///           plain xa leg (`_bal` floors once vs per-Safe twice): <= 1
    ///         total <= floor(px/1e18) + 4, where px = exchangeRate * alphaUSD / 1e18.
    function invariant_decompositionAdditivity() public view {
        uint256 gross = oracle.grossBasketValue();
        uint256 sum = oracle.committedValue() + oracle.freeValue();
        assertLe(sum, gross, "per-Safe decomposition over-counts vs gross");
        (uint256 pAlpha,) = oracle.legCache(0);
        uint256 px = feed.exchangeRate() * pAlpha / 1e18; // the xALPHA USD mark (`_xAlphaUSD`)
        assertLe(gross - sum, 4 + px / 1e18, "decomposition gap beyond the derived rounding bound");
    }

    /// @notice Deterministic pin of the finding above: the exact I-16 worst-case LP shape (supply 7e18, reserves
    ///         1e18/1e18, 4e18+4e18 split — the deterministic suite's own 2-wei construction) plus ONE legal push
    ///         (alphaUSD $1.00 -> $1.20; a modest +20% move, well inside anything the CRE would publish) yields a gap
    ///         of 3 wei — above the once-documented "<=2 wei". Token0 loses its 1-wei inner floor; token1's 1-wei
    ///         inner floor is amplified by the $1.20 outer division into 2 wei. Still `sum <= gross` here (the
    ///         per-Safe-debt saturation case that inverts that direction is not constructed by this vector).
    function test_finding_decompositionGap_scalesWithXAlphaMark_beyond2wei() public {
        ichi.set(address(zip), address(xa), 7e18, 1e18, 1e18);
        gauge.setBalance(juniorTrancheSafe, 4e18);
        gauge.setBalance(juniorTrancheSidecar, 4e18);
        // one legal push (+20%), ts strictly newer. No deviation band exists since 2026-07-31 — any magnitude lands.
        vm.warp(block.timestamp + 1);
        uint8[] memory legs = new uint8[](1);
        uint256[] memory ps = new uint256[](1);
        legs[0] = 0; // LEG_ALPHA_USD
        ps[0] = 1.2e18;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(forwarder);
        oracle.onReport("", report);

        uint256 gross = oracle.grossBasketValue();
        uint256 sum = oracle.committedValue() + oracle.freeValue();
        assertLe(sum, gross, "never over-counts");
        assertEq(gross - sum, 3, "the pinned counterexample: 3 wei > the documented 2");
    }

    // ----------------------------------------------------------------- 4. saturation + view totality
    /// @notice Every NAV view is TOTAL in every reachable state (a revert here = a bricked consumer), and the
    ///         saturation floors hold: `spotNavPerShare` floors at exactly 0 once the (unbounded) provision covers
    ///         the gross basket, and the genesis price returns at zero effective supply. Reaching the assertions at
    ///         all proves no checked-arithmetic underflow anywhere in the walk.
    function invariant_saturationAndTotality() public view {
        uint256 gross = oracle.grossBasketValue();
        uint256 spot = oracle.spotNavPerShare();
        oracle.twapNavPerShare();
        oracle.navExit();
        oracle.pathLockedLpEquity();
        oracle.lpShareValue(1e18);
        uint256 ts_ = szip.totalSupply();
        uint256 eng = szip.balanceOf(juniorTrancheEngine);
        uint256 eff = ts_ > eng ? ts_ - eng : 0;
        if (eff == 0) {
            assertEq(spot, oracle.GENESIS_NAV(), "zero effective supply must price at genesis");
        } else if (oracle.provision() >= gross) {
            assertEq(spot, 0, "provision >= gross must floor spot at exactly 0");
        }
    }

    // ----------------------------------------------------------------- 5. TWAP ring monotonicity + coherence
    /// @notice The accumulator never decreases (handler watermark), the ring head is always coherent with
    ///         (`lastUpdate`, `cumNav`), and walking the ring backward from the head every (ts, cum) pair is
    ///         non-increasing — through partial fills, head refresh-in-place, and full wraparound alike.
    function invariant_ringMonotoneCoherent() public view {
        assertGe(oracle.cumNav(), handler.ghostCumNav(), "cumNav fell behind its watermark");
        uint16 head = oracle.obsIndex();
        (uint32 prevTs, uint256 prevCum) = oracle.observations(head);
        assertEq(prevTs, oracle.lastUpdate(), "ring head ts != lastUpdate");
        assertEq(prevCum, oracle.cumNav(), "ring head cum != cumNav");
        uint256 idx = head;
        for (uint256 i = 1; i < CARDINALITY; i++) {
            idx = idx == 0 ? CARDINALITY - 1 : idx - 1;
            (uint32 ts_, uint256 cum_) = oracle.observations(idx);
            assertLe(ts_, prevTs, "ring ts not non-increasing walking back");
            assertLe(cum_, prevCum, "ring cum not non-increasing walking back");
            (prevTs, prevCum) = (ts_, cum_);
        }
    }

    // ----------------------------------------------------------------- 6. freshness coherence
    /// @notice `fresh() == true` ⇒ every required input is inside ITS OWN window at `now`: both pushed legs within
    ///         `maxAge`, and the SEC-13 anchor `oldestRequiredLegTs()` (rate leg folded with the fence shift) within
    ///         `maxAge` of `now` — so a resting bid anchored at `oldest + maxAge` can never fill against an input
    ///         beyond its bound.
    function invariant_freshnessCoherence() public view {
        if (!oracle.fresh()) return;
        (, uint48 aTs) = oracle.legCache(0);
        (, uint48 hTs) = oracle.legCache(1);
        assertLe(block.timestamp - aTs, MAX_AGE, "fresh with a stale alphaUSD leg");
        assertLe(block.timestamp - hTs, MAX_AGE, "fresh with a stale HYDX leg");
        uint48 oldest = oracle.oldestRequiredLegTs();
        assertGt(uint256(oldest), 0, "fresh with a zero freshness anchor");
        assertLe(block.timestamp - oldest, MAX_AGE, "fresh but the bid anchor is outside maxAge");
    }

    // ----------------------------------------------------------------- 7. spot conservation
    /// @notice The X-Ray's named next step: `spotNavPerShare` is EXACTLY the conserved quotient
    ///         `(gross - provision)_+ * 1e18 / effectiveSupply` with the engine Safe's transient balance excluded —
    ///         no hidden term can enter or leave the share price.
    function invariant_spotNavConservation() public view {
        uint256 ts_ = szip.totalSupply();
        uint256 eng = szip.balanceOf(juniorTrancheEngine);
        uint256 eff = ts_ > eng ? ts_ - eng : 0;
        uint256 spot = oracle.spotNavPerShare();
        if (eff == 0) {
            assertEq(spot, oracle.GENESIS_NAV(), "genesis conservation");
            return;
        }
        uint256 gross = oracle.grossBasketValue();
        uint256 prov = oracle.provision();
        uint256 net = gross > prov ? gross - prov : 0;
        assertEq(spot, net * 1e18 / eff, "spot != net basket / effective supply");
    }
}
