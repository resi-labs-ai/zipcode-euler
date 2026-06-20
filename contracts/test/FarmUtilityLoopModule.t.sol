// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";

import {FarmUtilityLoopModule} from "../src/supply/szipUSD/FarmUtilityLoopModule.sol";
import {SzipFarmUtilityLpOracle} from "../src/supply/SzipFarmUtilityLpOracle.sol";
import {FarmUtilityBorrowGuard} from "../src/supply/szipUSD/FarmUtilityBorrowGuard.sol";
import {FarmUtilityMarketDeployer} from "../script/FarmUtilityMarketDeployer.sol";

import {EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerEarn, MarketAllocation} from "euler-earn/interfaces/IEulerEarn.sol";
import {IERC4626 as IOZERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors as PriceErrors} from "euler-price-oracle/lib/Errors.sol";
import {Errors as EvkErrors} from "evk/EVault/shared/Errors.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev SEC-14: mastercopies are init-locked in their ctor, so `setUp` on a bare impl reverts.
///      A fresh EIP-1167 clone (fresh proxy storage) behaves like the old bare instance for setUp.
function _cloneFarmUtilityLoopModule() returns (FarmUtilityLoopModule) {
    return FarmUtilityLoopModule(Clones.clone(address(new FarmUtilityLoopModule())));
}

// =========================================================================== mocks

/// @notice A recording mock Safe: implements the Zodiac avatar surface (`execTransactionFromModule`), records every
///         `(to, value, data, operation)`, and (when `live`) actually performs the call. Can be forced to fail a
///         specific exec index (atomicity test). Modeled verbatim on `SzipBuyBurnModule.t.sol`.
contract RecordingSafe {
    struct Recorded {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    Recorded[] public calls;
    bool public live;
    uint256 public failOnCallIndex = type(uint256).max;

    function setLive(bool v) external {
        live = v;
    }

    function setFailOnCallIndex(uint256 i) external {
        failOnCallIndex = i;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (address to, uint256 value, bytes memory data, uint8 operation) {
        Recorded storage r = calls[i];
        return (r.to, r.value, r.data, r.operation);
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        (bool ok,) = _record(to, value, data, operation);
        return ok;
    }

    /// @notice The module drives the Safe via `execTransactionFromModuleReturnData` (so a failed inner call surfaces
    ///         as `(false, revertData)` — modeling the real Gnosis Safe, which catches inner reverts and returns false
    ///         rather than bubbling).
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool, bytes memory)
    {
        return _record(to, value, data, operation);
    }

    function _record(address to, uint256 value, bytes calldata data, uint8 operation)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (calls.length == failOnCallIndex) revert("forced-fail");
        calls.push(Recorded({to: to, value: value, data: data, operation: operation}));
        if (live) {
            (ok, ret) = to.call{value: value}(data);
            // Model the real Safe: catch the inner revert and RETURN (false, revertData), do NOT bubble.
            return (ok, ret);
        }
        return (true, "");
    }

    receive() external payable {}
}

/// @notice A minimal 18-dp ERC20 stand-in for the ICHI LP share (8-B6 mints the real one; the §4.5.1 stand-in posture).
contract MockLpToken {
    string public constant name = "Mock ICHI LP";
    string public constant symbol = "mLP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

/// @notice A zero-rate IRM (IIRM face) — model `EulerVenueAdapter.t.sol`.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A recording IEulerEarn mock — only the surface the adapter touches. EulerEarn pins solc 0.8.26 so it
///         cannot be `new`-ed under 0.8.24; the adapter imports only the interface, so a focused recording mock
///         suffices for the unit/fork test (the live EE path is the audit S9/L4 integration). Ported verbatim from
///         `EulerVenueAdapter.t.sol` so CTR-07's farm utility fund/defund reallocate runs against the same faithful EE.
contract MockEulerEarn {
    // Mirror the real EulerEarn supply-queue cap so the H2 brick (SEC-06) is reproducible at the unit level.
    uint256 internal constant MAX_QUEUE_LENGTH = 30; // ConstantsLib.MAX_QUEUE_LENGTH

    error MaxQueueLengthExceeded();
    /// @dev Mirrors EulerEarn's `afterTimelock` (reference EulerEarn.sol:185-189,507): a same-tx `acceptCap` after a
    ///      `submitCap` that set `validAt = now + timelock` reverts while `timelock != 0`. SEC-08's openLine precheck
    ///      fires BEFORE this — so without the fix, openLine builds all line proxies, THEN reverts here (orphaned).
    error TimelockNotElapsed();
    /// @dev Mirrors EulerEarn.reallocate's terminal invariant (reference EulerEarn.sol:441): the zero-sum check
    ///      `if (totalWithdrawn != totalSupplied) revert InconsistentReallocation()`. This is the exact revert
    ///      the L9/SEC-11 donation grief triggers when `fund` sizes targets off the donation-skewed live balance
    ///      while reallocate measures positions off the unskewed TRACKED `config.balance`.
    error InconsistentReallocation();
    /// @dev Mirrors EulerEarn.reallocate's per-market gate (reference EulerEarn.sol:390).
    error MarketNotEnabled(address id);
    /// @dev Mirrors EulerEarn.updateWithdrawQueue's removal guard (reference EulerEarn.sol:362): a market whose cap is
    ///      not yet zeroed cannot be removed from the withdraw queue. CTR-04's closeLine zeroes the cap (submitCap 0)
    ///      BEFORE the prune, so it never trips; a removal without the cap-zero would.
    error InvalidMarketRemovalNonZeroCap(address id);
    /// @dev Mirrors EulerEarn.updateWithdrawQueue's removal guard (reference EulerEarn.sol:366): a non-empty market
    ///      can only be removed after its removableAt timelock elapses. closeLine defunds to zero first, so the
    ///      removed market is empty and this never bites; modeled for faithfulness.
    error InvalidMarketRemovalNonZeroSupply(address id);

    /// @notice The pool asset (USDC) the mock moves between markets during a faithful reallocate.
    address public immutable asset;

    // ----- EE-tracked per-market config (security L9/SEC-11) -----
    // The crux of the donation bug: EE tracks each market's supplied SHARE balance INTERNALLY (`config.balance`),
    // updated ONLY through the deposits/redeems EE itself performs. A direct share transfer into the pool inflates
    // the market vault's live `balanceOf(EE)` but NOT this tracked balance (reference IEulerEarn.sol:69,73 "ignores
    // direct shares transfer"). reallocate measures every position as `previewRedeem(config.balance)` — NOT
    // `convertToAssets(balanceOf)` — so a target sized off the live balance diverges from EE's own accounting and
    // breaks the zero-sum check. This mock mirrors that: `cfgBalance` is bumped only inside `reallocate`/`seedConfig`.
    mapping(address => uint112) public cfgBalance; // EE-tracked share balance per market
    mapping(address => bool) public cfgEnabled; // a market is reallocate-eligible once its cap is accepted
    // CTR-04: per-market cap (reference _setCap :801 sets `marketConfig.cap = supplyCap`). openLine submits
    // type(uint136).max so a line's cap is max until closeLine's submitCap(0). A cap DECREASE (incl. ->0) applies
    // immediately (reference :298-299 / _setCap decrease branch). The withdraw-queue removal guard (reference :362)
    // requires this to be 0 before a market drops. NOT the hardcoded max the old config() returned.
    mapping(address => uint136) public cfgCap;

    /// @notice The EE pool timelock (SEC-08). Default 0 (immediate cap config); a test raises it as the EE owner.
    uint256 public timelock;
    /// @notice The EE pool's factory (SEC-08); `SzipPerspectiveProbe` reaches it via `creator()` to gate the probe.
    address public creator;

    address[] public submittedCaps;
    address[] public acceptedCaps;
    IOZERC4626[] internal _queue;
    // CTR-04: the WITHDRAW queue — the array whose hard MAX_QUEUE_LENGTH cap (reference _setCap :785) actually
    // bricks origination. Independent of the supply queue (`_queue`). Pushed once on a market's first enable, and
    // pruned by updateWithdrawQueue on closeLine.
    IOZERC4626[] internal _withdrawQueue;

    // last-reallocate recording
    address[] public lastReallocIds;
    uint256[] public lastReallocAssets;
    uint256 public reallocCount;

    constructor(address asset_) {
        asset = asset_;
    }

    function submitCap(IOZERC4626 id, uint256 cap) external {
        submittedCaps.push(address(id));
        // CTR-04: record the per-market cap. A decrease (incl. ->0, closeLine's revoke) is IMMEDIATE — matching
        // _setCap's decrease branch (reference :298-299,801), no timelock. openLine submits type(uint136).max so a
        // line's cap reads max until close. The withdraw-queue removal guard reads this (must be 0 to remove).
        cfgCap[address(id)] = uint136(cap);
    }

    function acceptCap(IOZERC4626 id) external {
        if (timelock != 0) revert TimelockNotElapsed(); // faithful afterTimelock: same-tx accept fails while > 0
        acceptedCaps.push(address(id));
        _enableMarket(address(id)); // faithful: accepting a cap enables the market + pushes the withdraw-queue slot
    }

    /// @dev CTR-04: faithful first-enable path (reference _setCap :782-794). Called by BOTH acceptCap (the line
    ///      onboarding path) and the base/farm utility seedConfig enable path. On a market's FIRST enable it pushes the
    ///      market onto the WITHDRAW queue and enforces the hard MAX_QUEUE_LENGTH (30) cap (reference :783-785) — the
    ///      BINDING cap that bricks the ~29th lifetime openLine absent CTR-04's reclaim. Guarded against double-push
    ///      (an already-enabled market re-onboarded does not re-push), like _setCap's `if (!marketConfig.enabled)`.
    function _enableMarket(address id) internal {
        if (cfgEnabled[id]) return; // already enabled -> no re-push (reference _setCap :782 guard)
        _withdrawQueue.push(IOZERC4626(id));
        if (_withdrawQueue.length > MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded(); // reference :785
        cfgEnabled[id] = true;
    }

    /// @dev The EE-tracked config getter the L9/SEC-11 `_eeSupplyAssets` helper reads. ABI-identical to the real
    ///      `IEulerEarn.config(IERC4626)` (struct `MarketConfig memory` — encodes the same as this 4-tuple).
    ///      CTR-04: `cap` now reports the TRACKED per-market cap (max for an open line, 0 after closeLine's
    ///      submitCap(0)) rather than a hardcoded max — the withdraw-queue removal guard reads it. `removableAt`
    ///      stays 0 (no per-market timelock in the mock); `.balance`/`.enabled` remain load-bearing as before.
    function config(IOZERC4626 id) external view returns (uint112 balance, uint136 cap, bool enabled, uint64 removableAt) {
        return (cfgBalance[address(id)], cfgCap[address(id)], cfgEnabled[address(id)], 0);
    }

    /// @dev Test helper: seed the EE-tracked position for a market the test funded DIRECTLY (bypassing reallocate,
    ///      e.g. `_fundBaseMarket`/`_supplyToLine`). Records `shares` as legitimately-tracked supply + enables the
    ///      market. A donation, by contrast, transfers shares to the EE address WITHOUT calling this — so
    ///      `balanceOf(EE) > cfgBalance`, which is exactly the L9 skew.
    function seedConfig(address market, uint256 shares) external {
        cfgBalance[market] += uint112(shares);
        // CTR-04: the base/farm utility enable path also takes a withdraw-queue slot on first enable (faithful to
        // _setCap's first-enable push), via the SAME guarded helper acceptCap uses — so re-seeding an already-enabled
        // market does not re-push, and a freshly-seeded base market occupies one slot exactly like the real EE.
        _enableMarket(market);
    }

    /// @dev SEC-08 test hook: the external EE owner raises the timelock post-deploy.
    function setTimelock(uint256 t) external {
        timelock = t;
    }

    /// @dev SEC-08 test hook: point the probe at a given factory (the live EE factory, or a mock that rejects).
    function setCreator(address c) external {
        creator = c;
    }

    function setSupplyQueue(IOZERC4626[] calldata q) external {
        // Faithful to EulerEarn.setSupplyQueue (reference :328): reject a queue past the hard cap. This is the
        // exact revert SEC-06's prune prevents — without the prune the queue grows unboundedly to this bound.
        if (q.length > MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded();
        delete _queue;
        for (uint256 i; i < q.length; ++i) {
            _queue.push(q[i]);
        }
    }

    /// @dev test helper: is `market` present in the current supply queue?
    function queueContains(address market) external view returns (bool) {
        for (uint256 i; i < _queue.length; ++i) {
            if (address(_queue[i]) == market) return true;
        }
        return false;
    }

    function supplyQueueLength() external view returns (uint256) {
        return _queue.length;
    }

    function supplyQueue(uint256 i) external view returns (IOZERC4626) {
        return _queue[i];
    }

    // ----- CTR-04: withdraw-queue surface (the BINDING queue) -----

    function withdrawQueueLength() external view returns (uint256) {
        return _withdrawQueue.length;
    }

    function withdrawQueue(uint256 i) external view returns (IOZERC4626) {
        return _withdrawQueue[i];
    }

    /// @dev test helper: is `market` present in the current withdraw queue?
    function withdrawQueueContains(address market) external view returns (bool) {
        for (uint256 i; i < _withdrawQueue.length; ++i) {
            if (address(_withdrawQueue[i]) == market) return true;
        }
        return false;
    }

    /// @dev Faithful to EulerEarn.updateWithdrawQueue (reference EulerEarn.sol:340-380): KEEP-indexes semantics — the
    ///      caller passes the indexes to retain; every current index NOT listed is removed. For each removed market the
    ///      removal guards (reference :362-371) run: cap must be 0 (else InvalidMarketRemovalNonZeroCap), and a NON-empty
    ///      market needs its removableAt timelock elapsed (the mock has no per-market removableAt, so a non-empty
    ///      removal reverts InvalidMarketRemovalNonZeroSupply — closeLine defunds first, so the removed line is empty
    ///      and removes freely). Removed markets have their config cleared (`delete config[id]` :373); the queue is
    ///      rebuilt from the kept indexes. closeLine passes the surviving indexes by ADDRESS, dropping only lineRef.
    function updateWithdrawQueue(uint256[] calldata indexes) external {
        uint256 currLength = _withdrawQueue.length;
        bool[] memory seen = new bool[](currLength);
        IOZERC4626[] memory newQueue = new IOZERC4626[](indexes.length);

        for (uint256 i; i < indexes.length; ++i) {
            uint256 prevIndex = indexes[i]; // out-of-bounds reverts natively, like the reference
            newQueue[i] = _withdrawQueue[prevIndex];
            seen[prevIndex] = true;
        }

        for (uint256 i; i < currLength; ++i) {
            if (!seen[i]) {
                address id = address(_withdrawQueue[i]);
                // reference :362 — a non-zeroed cap blocks removal (closeLine's submitCap(0) clears this).
                if (cfgCap[id] != 0) revert InvalidMarketRemovalNonZeroCap(id);
                // reference :365-366 — a non-empty market can only drop after its (here-absent) removableAt; closeLine
                // defunds to zero first, so expectedSupplyAssets(id) == previewRedeem(0) == 0 and this is skipped.
                if (expectedSupplyAssets(IOZERC4626(id)) != 0) revert InvalidMarketRemovalNonZeroSupply(id);
                // reference :373 — clear the removed market's config.
                cfgEnabled[id] = false;
                cfgCap[id] = 0;
                cfgBalance[id] = 0;
            }
        }

        delete _withdrawQueue;
        for (uint256 i; i < newQueue.length; ++i) {
            _withdrawQueue.push(newQueue[i]);
        }
    }

    /// @dev reference EulerEarn.sol:492 — expectedSupplyAssets(id) = previewRedeem(config.balance). Identical to the
    ///      adapter's `_eeSupplyAssets`; the withdraw-queue removal guard sizes the empty-market check off it.
    function expectedSupplyAssets(IOZERC4626 id) public view returns (uint256) {
        return IEVault(address(id)).previewRedeem(cfgBalance[address(id)]);
    }

    /// @dev Faithful to EulerEarn.reallocate (reference EulerEarn.sol:383-442): ABSOLUTE-target, zero-sum, sized off
    ///      the TRACKED `config.balance` (NOT live `balanceOf`). Single-pass in allocation order, mirroring the
    ///      reference exactly so both the SEC-07 strand/reclaim AND the L9/SEC-11 donation-grief are reproducible:
    ///      per market, `supplyAssets = previewRedeem(config.balance)`; if `target < supplyAssets` it withdraws the
    ///      difference (or, when `target == 0`, redeems ALL tracked shares — the reference's :397-402
    ///      "donations can be withdrawn" full-redeem branch); else it supplies `target - supplyAssets`; finally the
    ///      `totalWithdrawn != totalSupplied -> InconsistentReallocation` invariant (reference :441). `cfgBalance`
    ///      is updated on every move (reference :415,:431) so the tracked balance stays the source of truth — a
    ///      direct share donation never touches it. Callers (`fund`, `closeLine` defund) order withdraw-before-supply
    ///      so the single in-order pass has cash before it deposits. Real USDC moves between the real EVK vaults.
    function reallocate(MarketAllocation[] calldata allocs) external {
        delete lastReallocIds;
        delete lastReallocAssets;
        uint256 totalSupplied;
        uint256 totalWithdrawn;
        for (uint256 i; i < allocs.length; ++i) {
            lastReallocIds.push(address(allocs[i].id));
            lastReallocAssets.push(allocs[i].assets);
            address id = address(allocs[i].id);
            if (!cfgEnabled[id]) revert MarketNotEnabled(id);
            IEVault v = IEVault(id);

            uint256 supplyShares = cfgBalance[id];
            uint256 supplyAssets = v.previewRedeem(supplyShares);
            uint256 target = allocs[i].assets;
            uint256 withdrawn = supplyAssets > target ? supplyAssets - target : 0;

            if (withdrawn > 0) {
                uint256 shares;
                if (target == 0) {
                    // reference :397-402: target 0 redeems ALL shares (sweeps any donation), withdrawn reset to 0.
                    shares = supplyShares;
                    withdrawn = 0;
                }
                uint256 withdrawnAssets;
                uint256 withdrawnShares;
                if (shares == 0) {
                    withdrawnAssets = withdrawn;
                    withdrawnShares = v.withdraw(withdrawn, address(this), address(this));
                } else {
                    withdrawnAssets = v.redeem(shares, address(this), address(this));
                    withdrawnShares = shares;
                }
                cfgBalance[id] = uint112(supplyShares - withdrawnShares);
                totalWithdrawn += withdrawnAssets;
            } else {
                uint256 suppliedAssets = target > supplyAssets ? target - supplyAssets : 0;
                if (suppliedAssets == 0) continue;
                IERC20(asset).approve(id, suppliedAssets);
                uint256 suppliedShares = v.deposit(suppliedAssets, address(this));
                cfgBalance[id] = uint112(supplyShares + suppliedShares);
                totalSupplied += suppliedAssets;
            }
        }
        if (totalWithdrawn != totalSupplied) revert InconsistentReallocation();
        reallocCount++;
    }

    function submittedCapsLength() external view returns (uint256) {
        return submittedCaps.length;
    }

    function lastReallocLength() external view returns (uint256) {
        return lastReallocIds.length;
    }
}

/// @notice A deployer harness that deliberately mis-wires the wire-check against the WRONG LP token, so the (W3)
///         WireMismatch invariant is reachable — model `MisWiringAdapter`.
contract MisWiringDeployer is FarmUtilityMarketDeployer {
    address public immutable wrongLpToken;

    constructor(address wrongLpToken_) {
        wrongLpToken = wrongLpToken_;
    }

    function _assertWired(address router, address escrowVault, address, address usdc, address lpOracle)
        internal
        view
        override
    {
        // Feed the WRONG expected lpToken -> the real resolve (correct lpToken) must trip WireMismatch.
        super._assertWired(router, escrowVault, wrongLpToken, usdc, lpOracle);
    }
}

// =========================================================================== tests

/// @notice 8-B5 farm utility strike-financing loop. Unit (recording mock Safe — exec-shape/authority/atomicity) + fork
///         (live Base EVK/EVC/EulerRouter, real summoned substrate Safe — the post→borrow→repay→withdraw loop) +
///         LP-oracle + guard + deployer.
contract FarmUtilityLoopModuleTest is ForkConfig, SummonSubstrate {
    // -- live Base --
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6-dp
    address internal constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // -- actors --
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");
    address internal team = makeAddr("teamMultisig");
    address internal supplier = makeAddr("usdcSupplier");
    // CTR-07: the farm utility-fund allocator — a DISTINCT key from `operator` (two-key separation, §4.5.1).
    address internal allocatorKey = makeAddr("farmUtilityAllocator");

    uint256 internal constant BORROW_CAP = 1_000_000e6; // 1,000,000 USDC aggregate cap
    uint256 internal constant VALIDITY = 1 days; // generous engine-cadence window
    uint256 internal constant SALT = uint256(keccak256("zipcode.farm utility.8b5.salt.a"));

    // -- common deploys --
    GenericFactory internal factory;
    IEVC internal evc;
    ZeroIRM internal irm;
    MockLpToken internal lp;

    function setUp() public {
        _selectBaseFork();
        factory = GenericFactory(BaseAddresses.EVAULT_FACTORY);
        evc = IEVC(BaseAddresses.EVC);
        irm = new ZeroIRM();
        lp = new MockLpToken();
    }

    // ----------------------------------------------------------------- helpers
    /// @dev Deploy + setUp a module over an arbitrary engine Safe + market (recording-mock unit context).
    function _deployModule(
        address juniorTrancheEngine_,
        address borrowVault_,
        address escrowVault_,
        uint256 cap_
    ) internal returns (FarmUtilityLoopModule m) {
        m = _cloneFarmUtilityLoopModule();
        m.setUp(
            abi.encode(
                owner, juniorTrancheEngine_, operator, address(evc), borrowVault_, escrowVault_, address(lp), USDC, cap_
            )
        );
    }

    /// @dev Deploy a fresh LP oracle (renounced, as production) wired to `lpToken_`.
    function _deployOracle(address lpToken_) internal returns (SzipFarmUtilityLpOracle o) {
        o = new SzipFarmUtilityLpOracle(FORWARDER, USDC, VALIDITY, lpToken_);
        o.renounceOwnership();
    }

    /// @dev Push an LP mark via the CRE Forwarder (the only writer).
    function _pushMark(SzipFarmUtilityLpOracle o, uint256 mark) internal {
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(mark, uint32(block.timestamp)));
        vm.prank(FORWARDER);
        o.onReport("", report);
    }

    /// @dev Stand up the farm utility market through the deployer for `juniorTrancheEngine_`/`oracle`.
    function _deployMarket(address juniorTrancheEngine_, address oracle_, uint16 borrowLTV, uint16 liqLTV)
        internal
        returns (address escrowVault, address borrowVault, address router)
    {
        FarmUtilityMarketDeployer dep = new FarmUtilityMarketDeployer();
        (escrowVault, borrowVault, router) = dep.deploy(
            FarmUtilityMarketDeployer.Params({
                factory: factory,
                evc: address(evc),
                governor: owner,
                lpToken: address(lp),
                usdc: USDC,
                lpOracle: oracle_,
                irm: address(irm),
                juniorTrancheEngine: juniorTrancheEngine_,
                borrowLTV: borrowLTV,
                liqLTV: liqLTV
            })
        );
    }

    /// @dev Seed the borrow vault with USDC liquidity (a supplier deposit) so borrows have cash.
    function _seedBorrowVault(address borrowVault, uint256 amount) internal {
        deal(USDC, supplier, amount);
        vm.startPrank(supplier);
        IERC20(USDC).approve(borrowVault, amount);
        IEVault(borrowVault).deposit(amount, supplier);
        vm.stopPrank();
    }

    /// @dev Summon a real substrate + enable the module on its main Safe (team-owner drives the enable).
    function _summonAndEnable(FarmUtilityLoopModule m) internal returns (address juniorTrancheSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        juniorTrancheSafe = s.juniorTrancheSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(juniorTrancheSafe).execTransaction(juniorTrancheSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    // =================================================================== setUp / authority / locks (unit)

    function test_setUp_wires_storage() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.juniorTrancheEngine(), address(0xBEEF));
        assertEq(m.avatar(), address(0xBEEF));
        assertEq(m.target(), address(0xBEEF));
        assertEq(m.evc(), address(evc));
        assertEq(m.borrowVault(), address(0xB));
        assertEq(m.escrowVault(), address(0xE));
        assertEq(m.lpToken(), address(lp));
        assertEq(m.usdc(), USDC);
        assertEq(m.borrowCap(), BORROW_CAP);
    }

    /// @dev SEC-14: the bare mastercopy is init-locked in its ctor; `setUp` on it reverts AlreadyInitialized.
    function test_SEC14_mastercopy_setUp_reverts() public {
        FarmUtilityLoopModule mc = new FarmUtilityLoopModule();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mc.setUp(
            abi.encode(owner, address(0xBEEF), operator, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP)
        );
    }

    function test_setUp_initializer_once() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.expectRevert();
        m.setUp(
            abi.encode(owner, address(0xBEEF), operator, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP)
        );
    }

    /// @dev SEC-15 (I6): `setOperator` re-point must preserve the init-time owner != operator separation.
    ///      Pre-fix the re-point only rejected the zero address, so it could silently collapse the two roles.
    function test_SEC15_setOperator_owner_recheck() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        // a valid non-owner, non-zero re-point still succeeds
        address newOp = makeAddr("sec15NewOp");
        vm.prank(owner);
        m.setOperator(newOp);
        assertEq(m.operator(), newOp);
        // re-pointing operator to the owner now reverts OwnerIsOperator (pre-fix it succeeded)
        vm.prank(owner);
        vm.expectRevert(FarmUtilityLoopModule.OwnerIsOperator.selector);
        m.setOperator(owner);
        // zero still rejected
        vm.prank(owner);
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setOperator(address(0));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        vm.expectRevert(FarmUtilityLoopModule.OwnerIsOperator.selector);
        m.setUp(abi.encode(owner, address(0xBEEF), owner, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_setUp_rejects_zero_address_evc() public {
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0xBEEF), operator, address(0), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_setUp_rejects_zero_address_juniorTrancheEngine() public {
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0), operator, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_operator_cannot_redirect_safe() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        FarmUtilityLoopModule mc = _cloneFarmUtilityLoopModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.juniorTrancheEngine(), address(0));
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        mc.postCollateral(1e18);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        mc.borrow(1e6);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        mc.repay(1e6);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        mc.withdrawCollateral(1e18);
    }

    function test_entrypoints_only_operator() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.startPrank(rando);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        m.postCollateral(1e18);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        m.borrow(1e6);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        m.repay(1e6);
        vm.expectRevert(FarmUtilityLoopModule.NotOperator.selector);
        m.withdrawCollateral(1e18);
        vm.stopPrank();
    }

    function test_setBorrowCap_only_owner() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.prank(rando);
        vm.expectRevert();
        m.setBorrowCap(123);
        vm.prank(operator);
        vm.expectRevert();
        m.setBorrowCap(123);
        vm.prank(owner);
        m.setBorrowCap(456e6);
        assertEq(m.borrowCap(), 456e6);
    }

    /// @dev The six build-phase wiring setters (besides `setBorrowCap`/`setOperator`, covered above/by SEC-15): each
    ///      is `onlyOwner`, non-zero-guarded, and takes effect. Several re-point what is borrowed against
    ///      (`borrowVault`/`escrowVault`/`lpToken`), so the wiring matters more here than on a benign module.
    ///      `setJuniorTrancheEngine` additionally keeps `avatar`/`target` in lockstep (the borrower-of-record invariant).
    function test_wiring_setters_onlyOwner_effect_and_zeroGuard() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        address x = makeAddr("rewire");

        // non-owner rejected on every setter
        vm.startPrank(rando);
        bytes memory unauth = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando);
        vm.expectRevert(unauth);
        m.setJuniorTrancheEngine(x);
        vm.expectRevert(unauth);
        m.setEvc(x);
        vm.expectRevert(unauth);
        m.setBorrowVault(x);
        vm.expectRevert(unauth);
        m.setEscrowVault(x);
        vm.expectRevert(unauth);
        m.setLpToken(x);
        vm.expectRevert(unauth);
        m.setUsdc(x);
        vm.stopPrank();

        // owner re-points take effect
        vm.startPrank(owner);
        m.setEvc(x);
        assertEq(m.evc(), x, "evc re-pointed");
        m.setBorrowVault(x);
        assertEq(m.borrowVault(), x, "borrowVault re-pointed (the borrow market)");
        m.setEscrowVault(x);
        assertEq(m.escrowVault(), x, "escrowVault re-pointed (the collateral box)");
        m.setLpToken(x);
        assertEq(m.lpToken(), x, "lpToken re-pointed (the collateral asset)");
        m.setUsdc(x);
        assertEq(m.usdc(), x, "usdc re-pointed");

        // setJuniorTrancheEngine keeps avatar/target in lockstep (borrower-of-record invariant)
        address newEngine = makeAddr("newEngineSafe");
        m.setJuniorTrancheEngine(newEngine);
        assertEq(m.juniorTrancheEngine(), newEngine, "juniorTrancheEngine re-pointed");
        assertEq(m.avatar(), newEngine, "avatar synced to juniorTrancheEngine");
        assertEq(m.target(), newEngine, "target synced to juniorTrancheEngine");

        // zero rejected on every setter
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setJuniorTrancheEngine(address(0));
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setEvc(address(0));
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setBorrowVault(address(0));
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setEscrowVault(address(0));
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setLpToken(address(0));
        vm.expectRevert(FarmUtilityLoopModule.ZeroAddress.selector);
        m.setUsdc(address(0));
        vm.stopPrank();
    }

    function test_zero_amount_reverts() public {
        FarmUtilityLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.startPrank(operator);
        vm.expectRevert(FarmUtilityLoopModule.ZeroAmount.selector);
        m.postCollateral(0);
        vm.expectRevert(FarmUtilityLoopModule.ZeroAmount.selector);
        m.borrow(0);
        vm.expectRevert(FarmUtilityLoopModule.ZeroAmount.selector);
        m.repay(0);
        vm.expectRevert(FarmUtilityLoopModule.ZeroAmount.selector);
        m.withdrawCollateral(0);
        vm.stopPrank();
    }

    // =================================================================== exec discipline (recording mock)

    /// @dev THE security-boundary test (exhaustive): exact callCount per entrypoint, every call Operation.Call +
    ///      value==0 targeting only the wired addresses, and the inner IEVC.call calldata decoded to prove the
    ///      onBehalfOfAccount + innermost receiver/owner == juniorTrancheEngine.
    function test_exec_discipline_full() public {
        RecordingSafe safe = new RecordingSafe();
        address bv = address(0xB0B0);
        address ev = address(0xE5C0);
        FarmUtilityLoopModule m = _deployModule(address(safe), bv, ev, BORROW_CAP);
        address es = address(safe);

        // ---- postCollateral: exactly 3 ----
        vm.prank(operator);
        m.postCollateral(50e18);
        assertEq(safe.callCount(), 3);
        _assertCall(safe, 0, address(lp), abi.encodeWithSelector(IERC20.approve.selector, ev, uint256(50e18)));
        _assertCall(safe, 1, address(evc), abi.encodeCall(IEVC.enableCollateral, (es, ev)));
        _assertCall(safe, 2, ev, abi.encodeWithSelector(_depositSelector(), uint256(50e18), es));

        // ---- borrow: exactly 2 more (cap not exceeded; debtOf is a view on a non-vault stub -> stub returns 0) ----
        // bv is a bare address with no code -> debtOf staticcall returns empty; use a debt-stub instead.
        // Re-deploy with a DebtStub borrow vault so debtOf() == 0 succeeds in the cap check.
        DebtStub stub = new DebtStub();
        RecordingSafe safe2 = new RecordingSafe();
        FarmUtilityLoopModule m2 = _deployModule(address(safe2), address(stub), ev, BORROW_CAP);
        address es2 = address(safe2);

        vm.prank(operator);
        m2.borrow(79e6);
        assertEq(safe2.callCount(), 2);
        _assertCall(safe2, 0, address(evc), abi.encodeCall(IEVC.enableController, (es2, address(stub))));
        // call 1: EVC.call(borrowVault, juniorTrancheEngine, 0, borrow(79e6, juniorTrancheEngine))
        _assertEvcCall(safe2, 1, address(stub), es2, abi.encodeCall(IBorrowing.borrow, (uint256(79e6), es2)));

        // ---- repay: exactly 3 ----
        RecordingSafe safe3 = new RecordingSafe();
        FarmUtilityLoopModule m3 = _deployModule(address(safe3), address(stub), ev, BORROW_CAP);
        address es3 = address(safe3);
        vm.prank(operator);
        m3.repay(40e6);
        assertEq(safe3.callCount(), 3);
        _assertCall(safe3, 0, USDC, abi.encodeWithSelector(IERC20.approve.selector, address(stub), uint256(40e6)));
        _assertEvcCall(safe3, 1, address(stub), es3, abi.encodeCall(IBorrowing.repay, (uint256(40e6), es3)));
        _assertCall(safe3, 2, USDC, abi.encodeWithSelector(IERC20.approve.selector, address(stub), uint256(0)));

        // ---- withdrawCollateral: exactly 1 (after debtOf view == 0) ----
        RecordingSafe safe4 = new RecordingSafe();
        FarmUtilityLoopModule m4 = _deployModule(address(safe4), address(stub), ev, BORROW_CAP);
        address es4 = address(safe4);
        vm.prank(operator);
        m4.withdrawCollateral(30e18);
        assertEq(safe4.callCount(), 1);
        _assertEvcCall(safe4, 0, ev, es4, abi.encodeWithSelector(_withdrawSelector(), uint256(30e18), es4, es4));
    }

    function _assertCall(RecordingSafe safe, uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }

    /// @dev Decode the outer EVC.call and assert target/onBehalf/value + the innermost calldata.
    function _assertEvcCall(RecordingSafe safe, uint256 i, address expTarget, address expOnBehalf, bytes memory expInner)
        internal
        view
    {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, address(evc), "outer to must be EVC");
        assertEq(value, 0, "outer value 0");
        assertEq(op, 0, "Operation.Call");
        // strip the 4-byte EVC.call selector, decode (address,address,uint256,bytes)
        bytes memory args = _slice(data, 4);
        (address target, address onBehalf, uint256 innerValue, bytes memory inner) =
            abi.decode(args, (address, address, uint256, bytes));
        assertEq(target, expTarget, "EVC.call target");
        assertEq(onBehalf, expOnBehalf, "EVC.call onBehalfOfAccount == juniorTrancheEngine");
        assertEq(innerValue, 0, "inner value 0");
        assertEq(keccak256(inner), keccak256(expInner), "innermost calldata (receiver/owner == juniorTrancheEngine)");
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }

    function _depositSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("deposit(uint256,address)"));
    }

    function _withdrawSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("withdraw(uint256,address,address)"));
    }

    // =================================================================== atomicity (recording mock, live)

    function test_atomicity_postCollateral_deposit_revert_rolls_back() public {
        // live safe so approve really lands on the real LP; force the 3rd exec (deposit, index 2) to fail.
        RecordingSafe safe = new RecordingSafe();
        safe.setLive(true);
        safe.setFailOnCallIndex(2);
        // a real escrow-ish target is not needed; deposit goes to `ev` which has no code -> live call would fail
        // anyway, but the FORCED fail at index 2 happens BEFORE the deposit is recorded, so approve+enableCollateral
        // (indices 0,1) ran live. enableCollateral on the real EVC for a code-less account is a no-op success.
        address ev = address(0xE5C0);
        FarmUtilityLoopModule m = _deployModule(address(safe), address(new DebtStub()), ev, BORROW_CAP);

        vm.prank(operator);
        vm.expectRevert();
        m.postCollateral(10e18);

        // the whole tx reverted -> no standing LP allowance, no dangling collateral-enable.
        assertEq(lp.allowance(address(safe), ev), 0, "approve rolled back");
        address[] memory cols = evc.getCollaterals(address(safe));
        assertEq(cols.length, 0, "enableCollateral rolled back");
    }

    function test_atomicity_repay_call_revert_rolls_back() public {
        RecordingSafe safe = new RecordingSafe();
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // fail on the EVC.call(repay)
        DebtStub stub = new DebtStub();
        FarmUtilityLoopModule m = _deployModule(address(safe), address(stub), address(0xE5C0), BORROW_CAP);

        vm.prank(operator);
        vm.expectRevert();
        m.repay(40e6);

        // approve rolled back with the tx.
        assertEq(IERC20(USDC).allowance(address(safe), address(stub)), 0, "approve rolled back");
    }

    // =================================================================== LP oracle (unit)

    function test_oracle_push_and_quote_roundtrip() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // $1.00 per 1e18 LP share
        assertEq(o.getQuote(1e18, address(lp), USDC), 1e6, "full share == $1");
        assertEq(o.getQuote(5e17, address(lp), USDC), 5e5, "half share == $0.50");
    }

    function test_oracle_non_divisible_floors_against_borrower() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        // mark = 3 (6-dp); inAmount = 1 wei LP share -> 1 * 1e6 * 3 / 1e24 floors to 0 (against the borrower).
        _pushMark(o, 3);
        assertEq(o.getQuote(1, address(lp), USDC), 0, "floors against borrower");
        // a mark*inAmount not divisible by feedScale -> floor. mark=1e6, inAmount=333333333333333333 (1/3 share).
        // SEC-01: the second mark needs a strictly-newer ts (monotonic guard); a re-push lands in a later block.
        vm.warp(block.timestamp + 1);
        _pushMark(o, 1e6);
        uint256 inAmt = 333_333_333_333_333_333;
        assertEq(o.getQuote(inAmt, address(lp), USDC), inAmt / 1e12, "floor of 1/3 share value");
        assertTrue((inAmt * 1e6) % 1e24 != 0, "must be non-divisible");
    }

    function test_oracle_only_forwarder_can_push() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(uint256(1e6), uint32(block.timestamp)));
        vm.prank(rando);
        vm.expectRevert();
        o.onReport("", report);
    }

    function test_oracle_wrong_reportType_reverts() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        bytes memory report = abi.encode(uint8(3), abi.encode(uint256(1e6), uint32(block.timestamp)));
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(SzipFarmUtilityLpOracle.InvalidReportType.selector, uint8(3)));
        o.onReport("", report);
    }

    function test_oracle_base_or_quote_mismatch_reverts() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(0xAAAA), USDC));
        o.getQuote(1e18, address(0xAAAA), USDC); // base != lpToken
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), address(0xBBBB)));
        o.getQuote(1e18, address(lp), address(0xBBBB)); // quote != USDC
    }

    function test_oracle_failclosed_zero_mark_and_future_ts() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        bytes memory zeroMark = abi.encode(o.LP_MARK(), abi.encode(uint256(0), uint32(block.timestamp)));
        vm.prank(FORWARDER);
        vm.expectRevert(PriceErrors.PriceOracle_InvalidAnswer.selector);
        o.onReport("", zeroMark);

        bytes memory futureTs = abi.encode(o.LP_MARK(), abi.encode(uint256(1e6), uint32(block.timestamp + 1)));
        vm.prank(FORWARDER);
        vm.expectRevert(SzipFarmUtilityLpOracle.FutureTimestamp.selector);
        o.onReport("", futureTs);
    }

    function test_oracle_never_pushed_reverts_notsupported() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), USDC));
        o.getQuote(1e18, address(lp), USDC);
    }

    function test_oracle_stale_reverts_toostale() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6);
        vm.warp(block.timestamp + VALIDITY + 1);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY));
        o.getQuote(1e18, address(lp), USDC);
    }

    function test_oracle_lp_mark_is_not_three() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        assertEq(o.LP_MARK(), 7);
        assertTrue(o.LP_MARK() != 3, "LP_MARK must not be the registry REVALUATION=3");
    }

    // =================================================================== guard (unit + fork-ish)

    function test_guard_isHookTarget_only_for_factory_proxy() public {
        FarmUtilityBorrowGuard g = new FarmUtilityBorrowGuard(address(factory), address(0xBEEF));
        // a non-proxy caller (this test) -> 0
        assertEq(g.isHookTarget(), bytes4(0));
        // a real factory proxy caller -> the magic selector
        address proxy = factory.createProxy(address(0), false, abi.encodePacked(USDC, address(0), address(0)));
        vm.prank(proxy);
        assertEq(g.isHookTarget(), g.isHookTarget.selector);
    }

    /// @dev The guard's admin surface (security-relevant: `setJuniorTrancheEngine` is the borrow allowlist). The
    ///      `onlyOwner` gate uses the RAW `msg.sender` (NOT the EVK `_msgSender()` decoder, to avoid the `Context`
    ///      collision), so a non-owner caller reverts `NotOwner`. The constructor sets `owner = msg.sender` (this).
    function test_guard_admin_onlyOwner_transfer_and_wiring() public {
        FarmUtilityBorrowGuard g = new FarmUtilityBorrowGuard(address(factory), address(0xBEEF));
        assertEq(g.owner(), address(this), "deployer is the build-phase admin");

        address newFactory = makeAddr("newFactory");
        address newEngine = makeAddr("newEngineSafe");

        // raw-msg.sender onlyOwner: a non-owner reverts NotOwner on every admin function
        vm.startPrank(rando);
        vm.expectRevert(FarmUtilityBorrowGuard.NotOwner.selector);
        g.setEVaultFactory(newFactory);
        vm.expectRevert(FarmUtilityBorrowGuard.NotOwner.selector);
        g.setJuniorTrancheEngine(newEngine);
        vm.expectRevert(FarmUtilityBorrowGuard.NotOwner.selector);
        g.transferOwnership(rando);
        vm.stopPrank();

        // zero-guard on each (owner caller = this)
        vm.expectRevert(FarmUtilityBorrowGuard.ZeroAddress.selector);
        g.setEVaultFactory(address(0));
        vm.expectRevert(FarmUtilityBorrowGuard.ZeroAddress.selector);
        g.setJuniorTrancheEngine(address(0));
        vm.expectRevert(FarmUtilityBorrowGuard.ZeroAddress.selector);
        g.transferOwnership(address(0));

        // owner re-points take effect (setJuniorTrancheEngine is the borrow allowlist)
        g.setEVaultFactory(newFactory);
        assertEq(address(g.eVaultFactory()), newFactory, "eVaultFactory re-pointed");
        g.setJuniorTrancheEngine(newEngine);
        assertEq(g.juniorTrancheEngine(), newEngine, "borrow allowlist re-pointed");

        // transferOwnership hands the admin to the Timelock; the old owner then loses the gate
        g.transferOwnership(owner);
        assertEq(g.owner(), owner, "ownership transferred to the Timelock");
        vm.expectRevert(FarmUtilityBorrowGuard.NotOwner.selector);
        g.setJuniorTrancheEngine(address(0xCAFE)); // old owner (this) no longer authorized
    }

    // =================================================================== deployer wiring (fork)

    function test_deployer_governor_RETAINED() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // the deployer's setLTV reads getQuote
        (address ev, address bv, address router) = _deployMarket(address(0xBEEF), address(o), 0.7e4, 0.8e4);

        // The §4.5.1 inversion of WOOF-04: the router governor is RETAINED (NOT address(0)).
        assertEq(EulerRouter(router).governor(), owner, "router governor RETAINED at the Timelock");
        assertTrue(EulerRouter(router).governor() != address(0), "router NOT frozen");

        // escrow is a bare 1:1 holding box, governance renounced.
        assertEq(IEVault(ev).convertToAssets(1e18), 1e18, "escrow 1:1 shares<->assets");
        assertEq(IEVault(ev).governorAdmin(), address(0), "escrow governance renounced");

        // borrow vault governor RETAINED at the Timelock (CTR-06a): the §17 standing-tunable facility — the deployer
        // instance no longer governs it (it was created via createProxy(address(0), …)).
        assertEq(IEVault(bv).governorAdmin(), owner, "borrow vault governor RETAINED at the Timelock");

        // borrow vault oracle == the router; guard installed at OP_BORROW.
        assertEq(IEVault(bv).oracle(), router, "borrow vault oracle == router");
        (address hookTarget, uint32 hookedOps) = IEVault(bv).hookConfig();
        assertEq(hookedOps, uint32(1 << 6), "OP_BORROW only");
        assertEq(FarmUtilityBorrowGuard(hookTarget).juniorTrancheEngine(), address(0xBEEF), "guard pins the engine Safe");

        // The retained governor can still re-point the router (re-pointable).
        SzipFarmUtilityLpOracle o2 = _deployOracle(address(lp));
        vm.prank(owner);
        EulerRouter(router).govSetConfig(address(lp), USDC, address(o2));
    }

    function test_deployer_wiremismatch_reachable() public {
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // the deployer's setLTV reads getQuote (runs before the wire-check)
        MockLpToken wrongLp = new MockLpToken();
        MisWiringDeployer dep = new MisWiringDeployer(address(wrongLp));
        vm.expectRevert(FarmUtilityMarketDeployer.WireMismatch.selector);
        dep.deploy(
            FarmUtilityMarketDeployer.Params({
                factory: factory,
                evc: address(evc),
                governor: owner,
                lpToken: address(lp),
                usdc: USDC,
                lpOracle: address(o),
                irm: address(irm),
                juniorTrancheEngine: address(0xBEEF),
                borrowLTV: 0.7e4,
                liqLTV: 0.8e4
            })
        );
    }

    // =================================================================== the full loop (fork, headline)

    function test_full_loop_revolves_twice() public {
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        address juniorTrancheEngine = _summonAndEnable(m);

        // push a fresh LP mark ($1/share) before the deployer's setLTV (which reads getQuote).
        _pushMark(o, 1e6);
        (address ev, address bv, address router) = _deployMarket(juniorTrancheEngine, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        router; // silence

        // seed the borrow vault with USDC; deal LP to the Safe.
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(juniorTrancheEngine, 1000e18);

        uint256 slice = 100e18; // $100 collateral
        uint256 strike = 50e6; // $50 borrow, well inside 0.7 * $100

        for (uint256 round = 0; round < 2; round++) {
            // post
            vm.prank(operator);
            m.postCollateral(slice);
            assertEq(m.postedCollateral(), slice, "posted == slice");
            assertEq(evc.getCollaterals(juniorTrancheEngine).length, 1, "collateral enabled (no dup)");

            // borrow
            uint256 usdcBefore = IERC20(USDC).balanceOf(juniorTrancheEngine);
            vm.prank(operator);
            m.borrow(strike);
            assertEq(IERC20(USDC).balanceOf(juniorTrancheEngine) - usdcBefore, strike, "Safe received strike");
            assertEq(m.outstandingDebt(), strike, "outstandingDebt == strike");
            assertEq(m.outstandingDebt(), IBorrowing(bv).debtOf(juniorTrancheEngine), "view reads the vault live");
            assertEq(evc.getControllers(juniorTrancheEngine).length, 1, "controller enabled (no dup)");

            // repay (give the Safe the USDC to repay — in production from 8-B9 sale proceeds)
            deal(USDC, juniorTrancheEngine, strike);
            vm.prank(operator);
            m.repay(strike);
            assertEq(m.outstandingDebt(), 0, "debt cleared");
            assertEq(IERC20(USDC).allowance(juniorTrancheEngine, bv), 0, "no standing approval");

            // withdraw
            vm.prank(operator);
            m.withdrawCollateral(slice);
            assertEq(m.postedCollateral(), 0, "collateral withdrawn");
            assertEq(lp.balanceOf(juniorTrancheEngine), 1000e18, "LP back to the Safe");
        }

        // after 2 loops: no duplicate enables.
        assertEq(evc.getCollaterals(juniorTrancheEngine).length, 1, "no dup collateral after revolve");
        assertEq(evc.getControllers(juniorTrancheEngine).length, 1, "controller stays enabled, no dup");
    }

    // =================================================================== over-LTV / cap / stale / guard (fork)

    function test_over_LTV_reverts_AccountLiquidity() public {
        (FarmUtilityLoopModule m, address juniorTrancheEngine, address ev, address bv) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);

        // post $100 collateral.
        vm.prank(operator);
        m.postCollateral(100e18);

        // EVK gates NEW borrows against the BORROW LTV (0.7), not the liq LTV (0.8): max healthy borrow = $70.
        // A healthy borrow just under the boundary succeeds (proves enableController + the boundary): 69 < 70.
        vm.prank(operator);
        m.borrow(69e6);
        assertEq(m.outstandingDebt(), 69e6);

        // a further borrow taking the total over $70 (the borrow LTV) reverts E_AccountLiquidity.
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_AccountLiquidity.selector);
        m.borrow(5e6);
        ev;
        bv;
    }

    function test_no_collateral_borrow_reverts_AccountLiquidity() public {
        (FarmUtilityLoopModule m,,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_AccountLiquidity.selector);
        m.borrow(1e6);
    }

    function test_aggregate_cap_boundary_and_killswitch() public {
        // cap == strike exactly: borrow(cap) succeeds, +1 reverts CapExceeded.
        (FarmUtilityLoopModule m, address juniorTrancheEngine,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        juniorTrancheEngine;
        // need cap small; redeploy module with cap = 60e6 against the same market.
        // (the _liveLoopSetup module has cap BORROW_CAP; just test boundary on a fresh small-cap module.)
        vm.prank(operator);
        m.postCollateral(100e18);

        // set a small cap via owner so debt(0)+cap succeeds and +1 fails. cap = 50e6.
        vm.prank(owner);
        m.setBorrowCap(50e6);
        vm.prank(operator);
        m.borrow(50e6); // exactly the cap, debt 0 -> 50 <= 50 OK and < liqLTV*$100
        assertEq(m.outstandingDebt(), 50e6);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.CapExceeded.selector);
        m.borrow(1); // 50 + 1 > 50 cap

        // kill-switch: cap 0 -> every borrow reverts.
        vm.prank(owner);
        m.setBorrowCap(0);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.CapExceeded.selector);
        m.borrow(1);
    }

    function test_stale_and_never_pushed_mark_fail_borrow_closed() public {
        // Stand up with a live mark (the deployer's setLTV needs one); then test the two fail-closed borrow paths.
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        address juniorTrancheEngine = _summonAndEnable(m);
        _pushMark(o, 1e6);
        (address ev, address bv, address router) = _deployMarket(juniorTrancheEngine, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(juniorTrancheEngine, 1000e18);

        vm.prank(operator);
        m.postCollateral(100e18);

        // (1) PATH A — STALE: warp past the validity window -> borrow reverts TooStale (bubbled from the router).
        vm.warp(block.timestamp + VALIDITY + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY));
        m.borrow(10e6);

        // (2) PATH B — NEVER-PUSHED: the (retained) governor re-points the router to a fresh, never-pushed oracle ->
        //     borrow reverts NotSupported (bubbled from the router; the cache timestamp == 0).
        SzipFarmUtilityLpOracle bare = _deployOracle(address(lp));
        vm.prank(owner);
        EulerRouter(router).govSetConfig(address(lp), USDC, address(bare));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), USDC));
        m.borrow(10e6);
    }

    function test_withdraw_with_debt_reverts() public {
        (FarmUtilityLoopModule m,,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(10e6);
        vm.prank(operator);
        vm.expectRevert(FarmUtilityLoopModule.DebtOutstanding.selector);
        m.withdrawCollateral(50e18);
    }

    function test_exact_repay_clears_debt_and_resets_allowance_overrepay_reverts() public {
        // NOTE (ticket factual correction): EVK `repay(amount, receiver)` does NOT cap a literal `amount` at the
        // outstanding debt — a literal over-amount reverts `E_RepayTooMuch` (only `type(uint256).max` means "all").
        // So the loop repays the EXACT debt: an exact repay clears it + resets the residual approval; an over-repay
        // reverts (the operator never over-pays — it repays the strike it borrowed). See the build report.
        (FarmUtilityLoopModule m, address juniorTrancheEngine, , address bv) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(40e6);

        // an over-repay (> outstanding debt) reverts E_RepayTooMuch (EVK does not cap a literal amount).
        deal(USDC, juniorTrancheEngine, 100e6);
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_RepayTooMuch.selector);
        m.repay(60e6);
        assertEq(m.outstandingDebt(), 40e6, "over-repay reverted, debt unchanged");

        // an EXACT repay clears the debt and resets the residual approval to 0 (security F13).
        uint256 before = IERC20(USDC).balanceOf(juniorTrancheEngine);
        vm.prank(operator);
        m.repay(40e6);
        assertEq(m.outstandingDebt(), 0, "debt cleared");
        assertEq(before - IERC20(USDC).balanceOf(juniorTrancheEngine), 40e6, "exactly the debt debited");
        assertEq(IERC20(USDC).allowance(juniorTrancheEngine, bv), 0, "allowance reset to 0");
    }

    function test_third_party_borrow_blocked_by_guard() public {
        // The engine Safe's loop passes the guard; a third party that posts the escrow on its OWN account is blocked.
        FarmUtilityLoopModule m = _cloneFarmUtilityLoopModule();
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        address juniorTrancheEngine = _summonAndEnable(m);
        _pushMark(o, 1e6);
        (address ev, address bv,) = _deployMarket(juniorTrancheEngine, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(juniorTrancheEngine, 1000e18);

        // engine Safe loop borrows fine (passes the guard).
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(10e6);
        assertEq(m.outstandingDebt(), 10e6, "engine borrow passes the guard");

        // third party: holds LP, deposits into the SAME escrow on its OWN account, enables, attempts a direct borrow.
        address thirdParty = makeAddr("thirdPartyLeverager");
        lp.mint(thirdParty, 200e18);
        vm.startPrank(thirdParty);
        lp.approve(ev, 200e18);
        IEVault(ev).deposit(200e18, thirdParty);
        evc.enableCollateral(thirdParty, ev);
        evc.enableController(thirdParty, bv);
        // direct borrow via EVC.call on its own account -> the guard rejects (NotEngineSafe).
        vm.expectRevert();
        evc.call(bv, thirdParty, 0, abi.encodeCall(IBorrowing.borrow, (1e6, thirdParty)));
        vm.stopPrank();
    }

    /// @dev Shared live-loop setup: summon Safe, enable module, stand up market, seed USDC, push mark, mint LP.
    function _liveLoopSetup(uint16 borrowLTV, uint16 liqLTV, uint256 mark)
        internal
        returns (FarmUtilityLoopModule m, address juniorTrancheEngine, address ev, address bv)
    {
        m = _cloneFarmUtilityLoopModule();
        SzipFarmUtilityLpOracle o = _deployOracle(address(lp));
        juniorTrancheEngine = _summonAndEnable(m);
        // The mark must exist before the deployer's `setLTV` (which reads `getQuote` to validate the collateral
        // price at config time) — in production CRE pushes the mark at/before deploy.
        _pushMark(o, mark);
        address router;
        (ev, bv, router) = _deployMarket(juniorTrancheEngine, address(o), borrowLTV, liqLTV);
        router;
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(juniorTrancheEngine, 1000e18);
    }

    // =================================================================== CTR-07 farm utility fund/defund (fork)
    // The EE side does NOT exist in the borrow-leg fixture above; CTR-07 layers it on. The farm utility vault `bv` is a
    // real EVK USDC vault with an OP_BORROW-only hook (the deployer's `setHookConfig(guard, OP_BORROW)`), so the EE's
    // reallocate deposit/withdraw legs into `bv` are UN-hooked and net — the load-bearing fund-path invariant.

    /// @dev A live base USDC resting market (no-borrow holding vault) the farm utility funds OUT OF / re-absorbs INTO —
    ///      ported verbatim from `EulerVenueAdapter.t.sol`. Set once by `_ee07Setup`.
    address internal usdcReservoir;
    MockEulerEarn internal ee;
    EulerVenueAdapter internal adapter;

    /// @dev Seed the EE mock's tracked position in the base resting market so `fundFarmUtility`'s `base - amount` has
    ///      cash to withdraw — ported verbatim from `EulerVenueAdapter.t.sol:_fundBaseMarket`. Deposit as the EE, then
    ///      record the minted shares as EE-tracked config.balance (security L9/SEC-11): a legitimate supply IS tracked
    ///      (unlike a donation). Seeding the ACTUAL shares minted (not usdcAmount) keeps cfgBalance == balanceOf(EE).
    function _fundBaseMarket(uint256 usdcAmount) internal {
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(usdcReservoir, usdcAmount);
        uint256 shares = IEVault(usdcReservoir).deposit(usdcAmount, address(ee));
        ee.seedConfig(usdcReservoir, shares);
    }

    /// @dev Stand up the full CTR-07 fixture on top of the existing farm utility borrow leg: summon + enable the loop
    ///      module, deploy the farm utility market, mint a fresh $1 LP mark, wire a real `EulerVenueAdapter` (line-side
    ///      ctor args are real-but-unused placeholders — CTR-07 opens no lines), seed the base resting market, enable
    ///      the farm utility vault on the EE mock at ZERO balance (submitCap+acceptCap — NOT seeded with shares, so it
    ///      holds ≈0 at rest), and wire the farm utility vault + allocator (allocatorKey ≠ operator).
    function _ee07Setup(uint256 baseUsdc)
        internal
        returns (FarmUtilityLoopModule m, address juniorTrancheEngine, address ev, address bv, SzipFarmUtilityLpOracle o)
    {
        m = _cloneFarmUtilityLoopModule();
        o = _deployOracle(address(lp));
        juniorTrancheEngine = _summonAndEnable(m);
        _pushMark(o, 1e6); // $1/share, before the deployer's setLTV reads getQuote
        address router;
        (ev, bv, router) = _deployMarket(juniorTrancheEngine, address(o), 0.7e4, 0.8e4);
        router;
        m.setUp(abi.encode(owner, juniorTrancheEngine, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        lp.mint(juniorTrancheEngine, 1000e18);

        // EE side: a fresh faithful mock + a live base resting market (no-borrow holding vault).
        ee = new MockEulerEarn(USDC);
        usdcReservoir = factory.createProxy(address(0), false, abi.encodePacked(USDC, address(0), address(0)));
        IEVault(usdcReservoir).setHookConfig(address(0), 0);
        IEVault(usdcReservoir).setGovernorAdmin(address(0));

        // Real adapter (10-arg ctor; line-side args are real-but-unused placeholders). The test contract is the owner.
        adapter = new EulerVenueAdapter(
            address(this), // controller (unused by CTR-07)
            address(evc),
            address(ee),
            address(factory),
            address(0xDEAD), // oracleRegistry (unused)
            address(0xBEEF), // gatingHook (unused)
            address(irm),
            USDC,
            address(0xE6E6), // erebor (unused)
            usdcReservoir
        );

        // Seed the EE supply queue with the base market ONLY (the farm utility vault stays a NON-supply-queue market).
        IOZERC4626[] memory q = new IOZERC4626[](1);
        q[0] = IOZERC4626(usdcReservoir);
        ee.setSupplyQueue(q);

        // Seed the base resting position so fundFarmUtility has cash to withdraw.
        _fundBaseMarket(baseUsdc);

        // Enable the farm utility vault on the EE mock at ZERO balance (mirrors DeployLocal submitCap+acceptCap) — NOT
        // seeded with shares, so it is reallocate-eligible (enabled, cap != 0) but holds ≈0 at rest.
        ee.submitCap(IOZERC4626(bv), type(uint136).max);
        ee.acceptCap(IOZERC4626(bv));

        // Wire the farm utility slots. allocatorKey is DISTINCT from operator (two-key separation).
        adapter.setFarmUtilityVault(bv);
        adapter.setFarmUtilityAllocator(allocatorKey);
    }

    function test_ctr07_roundtrip_restores_resting() public {
        (FarmUtilityLoopModule m, address juniorTrancheEngine, , address bv, SzipFarmUtilityLpOracle o) = _ee07Setup(1_000_000e6);
        uint256 X = 100e6; // $100 funded into the farm utility
        uint256 baseBefore = ee.expectedSupplyAssets(IOZERC4626(usdcReservoir));

        // fund: base -X, farm utility == X.
        vm.prank(allocatorKey);
        adapter.fundFarmUtility(X);
        assertEq(ee.expectedSupplyAssets(IOZERC4626(usdcReservoir)), baseBefore - X, "base debited X");
        assertEq(ee.expectedSupplyAssets(IOZERC4626(bv)), X, "farm utility holds X");

        // a real borrow leg < X through the loop operator ($50 against $100 LP collateral, inside 0.7 LTV).
        o; // mark already $1 from setup; the validity window is generous
        uint256 strike = 50e6;
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(strike);
        assertEq(m.outstandingDebt(), strike, "borrowed out of the farm utility");
        // repay (give the Safe the USDC, as production from sale proceeds).
        deal(USDC, juniorTrancheEngine, strike);
        vm.prank(operator);
        m.repay(strike);
        assertEq(m.outstandingDebt(), 0, "repaid in full");

        // defund: base restored, farm utility == 0.
        vm.prank(allocatorKey);
        adapter.defundFarmUtility(X);
        assertEq(ee.expectedSupplyAssets(IOZERC4626(usdcReservoir)), baseBefore, "resting restored after full cycle");
        assertEq(ee.expectedSupplyAssets(IOZERC4626(bv)), 0, "farm utility back to 0");
    }

    function test_ctr07_defund_reverts_when_lent_out() public {
        (FarmUtilityLoopModule m,, , address bv,) = _ee07Setup(1_000_000e6);
        bv;
        uint256 X = 100e6;
        vm.prank(allocatorKey);
        adapter.fundFarmUtility(X);

        // borrow out of the farm utility WITHOUT repaying — the farm utility EVK vault now lacks the cash for a withdraw.
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(50e6);

        // a defund of the full X reverts: the withdraw leg has no cash (redemption-isolation / JIT discipline).
        vm.prank(allocatorKey);
        vm.expectRevert(EvkErrors.E_InsufficientCash.selector);
        adapter.defundFarmUtility(X);
    }

    function test_ctr07_operator_cannot_fund() public {
        _ee07Setup(1_000_000e6);
        uint256 X = 100_000e6;
        // the loop hot key (operator), lacking the allocator role, cannot fund OR defund.
        vm.prank(operator);
        vm.expectRevert(EulerVenueAdapter.NotFarmUtilityAllocator.selector);
        adapter.fundFarmUtility(X);
        vm.prank(operator);
        vm.expectRevert(EulerVenueAdapter.NotFarmUtilityAllocator.selector);
        adapter.defundFarmUtility(X);
    }

    function test_ctr07_donation_noop_on_sizing() public {
        (, , , address bv,) = _ee07Setup(1_000_000e6);
        uint256 X = 100_000e6;

        // A donor mints farm utility-vault shares then RAW-transfers them to the EE — inflating balanceOf(ee) but NOT the
        // tracked cfgBalance. Sizing off the tracked balance (`_eeSupplyAssets`), fund/defund still net.
        address donor = makeAddr("donor");
        deal(USDC, donor, 250_000e6);
        vm.startPrank(donor);
        IERC20(USDC).approve(bv, 250_000e6);
        uint256 donatedShares = IEVault(bv).deposit(250_000e6, donor);
        IEVault(bv).transfer(address(ee), donatedShares); // raw share donation
        vm.stopPrank();
        assertGt(IEVault(bv).balanceOf(address(ee)), ee.cfgBalance(bv), "donation skews live, not tracked");

        // fund + defund still net (no InconsistentReallocation), because sizing is off cfgBalance not balanceOf.
        uint256 baseBefore = ee.expectedSupplyAssets(IOZERC4626(usdcReservoir));
        vm.prank(allocatorKey);
        adapter.fundFarmUtility(X);
        vm.prank(allocatorKey);
        adapter.defundFarmUtility(X);
        assertEq(ee.expectedSupplyAssets(IOZERC4626(usdcReservoir)), baseBefore, "donation-immune round-trip nets");
    }

    function test_ctr07_farmUtility_zero_at_rest() public {
        (FarmUtilityLoopModule m, address juniorTrancheEngine, , address bv,) = _ee07Setup(1_000_000e6);
        uint256 X = 100e6;
        uint256 strike = 50e6;

        vm.prank(allocatorKey);
        adapter.fundFarmUtility(X);
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(strike);
        deal(USDC, juniorTrancheEngine, strike);
        vm.prank(operator);
        m.repay(strike);
        vm.prank(allocatorKey);
        adapter.defundFarmUtility(X);

        assertEq(ee.expectedSupplyAssets(IOZERC4626(bv)), 0, "farm utility == 0 at rest after a full cycle");
    }

    /// @dev CTR-07 fail-fast: `setFarmUtilityVault` refuses a vault whose hook would block the EE reallocate legs. The
    ///      farm utility vault is purpose-built OP_BORROW-only; here the governor (Timelock) widens its mask to ALSO hook
    ///      deposits (the §17 footgun) — re-wiring it must now revert `FarmUtilityHookBlocksReallocate` rather than
    ///      silently accept a vault `fundFarmUtility` would brick on.
    function test_ctr07_setFarmUtilityVault_rejects_reallocate_blocking_hook() public {
        (, , , address bv,) = _ee07Setup(1_000_000e6);
        (address hookTarget,) = IEVault(bv).hookConfig();
        // OP_BORROW (1<<6) | OP_DEPOSIT (1<<0): keep the borrow guard, but now also hook deposits.
        vm.prank(owner);
        IEVault(bv).setHookConfig(hookTarget, uint32((1 << 6) | (1 << 0)));
        vm.expectRevert(EulerVenueAdapter.FarmUtilityHookBlocksReallocate.selector);
        adapter.setFarmUtilityVault(bv);
    }
}

/// @notice A minimal borrow-vault stub for the unit exec-discipline + atomicity tests: `debtOf` returns 0 so the cap
///         check passes; everything else is irrelevant (the recording Safe records, it does not execute on it).
contract DebtStub {
    function debtOf(address) external pure returns (uint256) {
        return 0;
    }
}
