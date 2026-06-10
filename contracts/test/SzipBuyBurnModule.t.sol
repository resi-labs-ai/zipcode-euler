// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {SzipBuyBurnModule} from "../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {IGPv2Settlement} from "../src/interfaces/cow/IGPv2Settlement.sol";
import {SzipNavOracle} from "../src/supply/SzipNavOracle.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe: implements the Zodiac avatar surface (`execTransactionFromModule`), records every
///         `(to, value, data, operation)` it is handed, and (when `live`) actually performs the call so the live
///         settlement/USDC fork assertions see real state. Can be forced to fail the 2nd exec (atomicity test).
contract RecordingSafe {
    struct Recorded {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    Recorded[] public calls;
    bool public live; // when true, forwards as a real call
    uint256 public failOnCallIndex = type(uint256).max; // revert when calls.length == this index (pre-record)

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
        if (calls.length == failOnCallIndex) revert("forced-fail");
        calls.push(Recorded({to: to, value: value, data: data, operation: operation}));
        if (live) {
            (bool ok, bytes memory ret) = to.call{value: value}(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return true;
    }

    receive() external payable {}
}

/// @notice A fully-controllable NAV oracle stand-in: settable `navExit()`/`fresh()` for the price-bound, cap, and
///         freshness gate tests (exact control of the 18-dp mark).
contract MockNavOracle {
    uint256 public navExitV;
    bool public freshV;
    uint256 public maxAgeV = 1 days; // default == MAX_BID_TTL, so the NAV-freshness fence is a no-op at default

    function setNavExit(uint256 v) external {
        navExitV = v;
    }

    function setFresh(bool v) external {
        freshV = v;
    }

    function setMaxAge(uint256 v) external {
        maxAgeV = v;
    }

    function navExit() external view returns (uint256) {
        return navExitV;
    }

    function fresh() external view returns (bool) {
        return freshV;
    }

    function maxAge() external view returns (uint256) {
        return maxAgeV;
    }
}

// =========================================================================== tests

/// @notice 8-B14 buy-and-burn BID module. Unit tests (recording mock Safe) for validation/authority/atomicity/exec-
///         discipline + Base-mainnet fork tests for the LIVE GPv2Settlement PRESIGN + USDC allowance + uid vector.
contract SzipBuyBurnModuleTest is ForkConfig {
    // -- live Base CoW / USDC (verified `cast`, 2026-06-08) ------------------
    address internal constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    bytes32 internal constant COW_DOMAIN_SEPARATOR =
        0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6-dp

    // -- pinned uid vector inputs (the engine Safe + szipUSD are fixed constants for the known-answer test) --
    // The uid was computed OUT-OF-BAND with `cast` (different tooling than the contract's Solidity); the commands:
    //   TYPE_HASH=0x1a59c8ffcce6fc2e6738119e0d2e050163ef0912ac7168f28acd39badd252b51
    //   DOMSEP=0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b
    //   STRUCT_ENC=$(cast abi-encode \
    //     'f(bytes32,address,address,address,uint256,uint256,uint256,bytes32,uint256,bytes32,bool,bytes32,bytes32)' \
    //     $TYPE_HASH 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0x000000000000000000000000000000000000bEEF \
    //     0x00000000000000000000000000000000DeaDBeef 1000000000 1000000000000000000000 2000000000 \
    //     0x00..00 0 $KIND_BUY true $BALANCE_ERC20 $BALANCE_ERC20)
    //   STRUCT_HASH=$(cast keccak $STRUCT_ENC)            # 0x462aa4c3...f78bcb4
    //   DIGEST=$(cast keccak $(cast concat-hex 0x1901 $DOMSEP $STRUCT_HASH))   # 0x8ca3ba43...3c0fd153
    //   UID = DIGEST(32) ++ 0x00..DeaDBeef(owner,20) ++ 0x77359400(validTo=2000000000, uint32 BE, 4)
    address internal constant VEC_SZIPUSD = 0x000000000000000000000000000000000000bEEF;
    address internal constant VEC_ENGINE = 0x00000000000000000000000000000000DeaDBeef;
    uint256 internal constant VEC_SELL = 1_000_000_000; // 1000 USDC (6-dp)
    uint256 internal constant VEC_BUY = 1_000_000_000_000_000_000_000; // 1000 szipUSD (18-dp)
    uint32 internal constant VEC_VALIDTO = 2_000_000_000;
    bytes internal constant VEC_UID =
        hex"8ca3ba43cdfa09f243e87e393d7a46b4ce57c05a8f1232a60bfb0d943c0fd15300000000000000000000000000000000DeaDBeef77359400";

    // -- actors --
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    uint16 internal constant D_BPS = 200; // 2% discount
    uint256 internal constant CAP = 1_000_000e6; // 1,000,000 USDC

    SzipBuyBurnModule internal module; // unit module over a recording mock Safe
    RecordingSafe internal safe;
    MockNavOracle internal oracle;
    address internal szip = makeAddr("szipUSD");

    function setUp() public {
        _selectBaseFork();
        vm.warp(1_000_000);
        safe = new RecordingSafe();
        oracle = new MockNavOracle();
        oracle.setFresh(true);
        oracle.setNavExit(1e18); // $1.00 NAV/share
        module = _deploy(address(safe), szip, CAP);
    }

    // ----------------------------------------------------------------- helpers
    function _deploy(address engineSafe_, address szipUSD_, uint256 cap_) internal returns (SzipBuyBurnModule m) {
        m = new SzipBuyBurnModule();
        m.setUp(
            abi.encode(
                owner, engineSafe_, operator, address(oracle), szipUSD_, USDC, COW_SETTLEMENT, D_BPS, cap_
            )
        );
    }

    function _order(uint256 sell, uint256 buy, uint32 validTo) internal pure returns (SzipBuyBurnModule.GPv2OrderInput memory o) {
        o.sellAmount = sell;
        o.buyAmount = buy;
        o.validTo = validTo;
    }

    function _validTo() internal view returns (uint32) {
        return uint32(block.timestamp + 1 hours);
    }

    // ----------------------------------------------------------------- setUp / substrate / locks
    function test_setUp_wires_storage_and_reads_live() public view {
        assertEq(module.owner(), owner);
        assertEq(module.operator(), operator);
        assertEq(module.engineSafe(), address(safe));
        assertEq(module.avatar(), address(safe));
        assertEq(module.target(), address(safe));
        assertEq(module.navOracle(), address(oracle));
        assertEq(module.szipUSD(), szip);
        assertEq(module.usdc(), USDC);
        assertEq(module.settlement(), COW_SETTLEMENT);
        // read LIVE off the settlement in setUp
        assertEq(module.vaultRelayer(), COW_VAULT_RELAYER);
        assertEq(module.domainSeparator(), COW_DOMAIN_SEPARATOR);
        assertEq(module.dBps(), D_BPS);
        assertEq(module.buybackCap(), CAP);
    }

    function test_setUp_initializer_once() public {
        bytes memory p =
            abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP);
        vm.expectRevert(); // zodiac-core AlreadyInitialized
        module.setUp(p);
    }

    function test_setUp_rejects_owner_equals_operator() public {
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.OwnerIsOperator.selector);
        m.setUp(abi.encode(owner, address(safe), owner, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP));
    }

    function test_setUp_rejects_zero_address() public {
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0), operator, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP));
    }

    function test_setUp_rejects_bad_discount() public {
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        m.setUp(abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, uint16(0), CAP));
        SzipBuyBurnModule m2 = new SzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        m2.setUp(
            abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, uint16(10_000), CAP)
        );
    }

    /// @dev The CRE operator (the hot key) cannot redirect the Safe: `setAvatar`/`setTarget` are inherited
    ///      zodiac-core `onlyOwner`. The operator (and any non-owner) reverts; only the Timelock `owner` could, which
    ///      is a deliberate governance act, not an attack path. (We do NOT hard-lock — that would require patching the
    ///      pristine vendored zodiac-core to add `virtual`.)
    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        module.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        module.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        // A bare-deployed mastercopy (never setUp) has zero operator/engineSafe — postBid reverts NotOperator for all.
        SzipBuyBurnModule mc = new SzipBuyBurnModule();
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.NotOperator.selector);
        mc.postBid(_order(1e6, 1e18, _validTo()));
        assertEq(mc.operator(), address(0));
        assertEq(mc.engineSafe(), address(0));
    }

    function test_engineSafe_identity_matches() public view {
        // The module's engineSafe is the order receiver/owner; deploy wires the Gate's + oracle's setEngineSafe to
        // the same Safe (item-10). Here: the module's engineSafe == the Safe it is enabled on.
        assertEq(module.engineSafe(), address(safe));
    }

    // ----------------------------------------------------------------- authority
    function test_postBid_only_operator() public {
        vm.prank(rando);
        vm.expectRevert(SzipBuyBurnModule.NotOperator.selector);
        module.postBid(_order(1e6, 1e18, _validTo()));
    }

    function test_cancelBid_only_operator_or_owner() public {
        vm.prank(rando);
        vm.expectRevert(SzipBuyBurnModule.NotOperator.selector);
        module.cancelBid();
        // operator + owner may both cancel (idempotent no-op here)
        vm.prank(operator);
        module.cancelBid();
        vm.prank(owner);
        module.cancelBid();
    }

    function test_governed_params_only_owner() public {
        vm.prank(rando);
        vm.expectRevert();
        module.setDiscountBps(300);
        vm.prank(rando);
        vm.expectRevert();
        module.setBuybackCap(1);
        // owner can
        vm.prank(owner);
        module.setDiscountBps(300);
        assertEq(module.dBps(), 300);
        vm.prank(owner);
        module.setBuybackCap(123e6);
        assertEq(module.buybackCap(), 123e6);
    }

    function test_setDiscountBps_bounds() public {
        vm.prank(owner);
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        module.setDiscountBps(0);
        vm.prank(owner);
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        module.setDiscountBps(10_000);
    }

    // ----------------------------------------------------------------- zero-amount / validTo
    function test_zero_amounts_revert() public {
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ZeroAmount.selector);
        module.postBid(_order(0, 1e18, _validTo()));
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ZeroAmount.selector);
        module.postBid(_order(1e6, 0, _validTo()));
    }

    function test_validTo_bounds_revert() public {
        // <= now
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BadValidTo.selector);
        module.postBid(_order(1e6, 1e18, uint32(block.timestamp)));
        // > now + MAX_BID_TTL
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BadValidTo.selector);
        module.postBid(_order(1e6, 1e18, uint32(block.timestamp + 1 days + 1)));
    }

    function test_buyAmount_too_large_reverts() public {
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BuyAmountTooLarge.selector);
        module.postBid(_order(1e6, 1e30 + 1, _validTo()));
    }

    // ---------------------------------------------- NAV-freshness fence (collapsed "fulfillment controller")
    // A resting bid's `validTo` must not exceed `now + navOracle.maxAge()` — so a fill cannot land against a NAV
    // mark that has since aged past the oracle's freshness window. Binds before `BadValidTo` when maxAge < TTL.
    function test_validTo_at_maxAge_boundary_ok() public {
        oracle.setMaxAge(1 hours); // < MAX_BID_TTL (1 day)
        // validTo == now + maxAge → exactly the boundary, the fence uses `>` so this PASSES (deep-discount price).
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours)));
        assertTrue(module.currentUid().length != 0, "bid posted at the freshness boundary");
    }

    function test_validTo_one_past_maxAge_reverts() public {
        oracle.setMaxAge(1 hours);
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        module.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours + 1)));
    }

    function test_freshness_fence_binds_before_BadValidTo() public {
        oracle.setMaxAge(1 hours); // maxAge < MAX_BID_TTL
        // validTo = now + 2h: within MAX_BID_TTL (so BadValidTo would NOT fire) but past maxAge → the fence binds.
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        module.postBid(_order(5e5, 1e18, uint32(block.timestamp + 2 hours)));
    }

    // ----------------------------------------------------------------- cap / kill-switch / single bid
    function test_cap_exceeded_reverts() public {
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.CapExceeded.selector);
        module.postBid(_order(CAP + 1, 1e30, _validTo()));
    }

    function test_killswitch_zero_cap_always_reverts() public {
        SzipBuyBurnModule m = _deploy(address(safe), szip, 0); // buybackCap == 0
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.CapExceeded.selector);
        m.postBid(_order(1, 1e18, _validTo()));
    }

    function test_single_resting_bid() public {
        // navExit $1, d 2% -> ceiling 0.98 USDC/share. Pay 0.5 USDC for 1 share (deep discount) -> passes.
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, vt)); // 0.5 USDC for 1 szipUSD
        (bytes memory uid, uint256 sell) = module.currentBid();
        assertEq(uid.length, 56);
        assertEq(sell, 5e5);
        // second post while live reverts
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAlreadyLive.selector);
        module.postBid(_order(5e5, 1e18, vt));
        // outstanding allowance always <= buybackCap (the sellAmount is)
        assertLe(module.currentSellAmount(), module.buybackCap());
    }

    // ----------------------------------------------------------------- price bound (exact integer form)
    // navExit18 = N (18-dp). Pay `sellAmount` USDC (6-dp) for `buyAmount` szipUSD (18-dp). Gate:
    //   sellAmount * 1e12 * 10_000 * 1e18  <=  buyAmount * N * (10_000 - dBps).
    // Largest passing sellAmount = floor( buyAmount * N * (10_000 - dBps) / (1e12 * 10_000 * 1e18) ).
    function _maxSell(uint256 buy, uint256 nav, uint16 d) internal pure returns (uint256) {
        return (buy * nav * (10_000 - uint256(d))) / (uint256(1e12) * 10_000 * 1e18);
    }

    function test_price_bound_boundary_divisible() public {
        // navExit $1, buy 1e18, d 2% -> ceiling = 0.98 USDC (980000 6-dp). Divisible case.
        uint256 nav = 1e18;
        uint256 buy = 1e18;
        uint256 maxSell = _maxSell(buy, nav, D_BPS);
        assertEq(maxSell, 980_000); // 0.98 USDC
        uint32 vt = _validTo();
        // exactly the max passes
        vm.prank(operator);
        module.postBid(_order(maxSell, buy, vt));
        // +1 reverts BidAboveDiscount (after cancel to clear the live bid)
        vm.prank(operator);
        module.cancelBid();
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        module.postBid(_order(maxSell + 1, buy, _validTo()));
    }

    function test_price_bound_boundary_non_divisible() public {
        // A buyAmount*nav*(10_000-d) NOT divisible by 1e22 (= 1e12*1e4*1e18 / 1e... ) — the floor must round against
        // the buyer. Use nav = 1.234567890123456789e18, buy = 7e18, d = 200.
        uint256 nav = 1_234_567_890_123_456_789;
        uint256 buy = 7e18;
        oracle.setNavExit(nav);
        // prove the RHS product is NOT divisible by 1e22 (the denominator's 1e22 == 1e12*1e4*1e... ; here the
        // divisor in _maxSell is 1e12*1e4*1e18 = 1e34, and the numerator buy*nav*(10000-d) is not a multiple of it).
        uint256 numer = buy * nav * (10_000 - uint256(D_BPS));
        assertTrue(numer % (uint256(1e12) * 10_000 * 1e18) != 0, "RHS must be non-divisible");
        uint256 maxSell = _maxSell(buy, nav, D_BPS);
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(maxSell, buy, vt)); // floor passes
        vm.prank(operator);
        module.cancelBid();
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        module.postBid(_order(maxSell + 1, buy, _validTo())); // +1 over the floored ceiling reverts
    }

    function test_bid_at_or_above_nav_reverts() public {
        // pay exactly NAV (1 USDC for 1 share) -> above the 0.98 ceiling -> reverts
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        module.postBid(_order(1e6, 1e18, _validTo()));
    }

    function test_deep_discount_passes() public {
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, vt)); // 0.50 USDC/share, well below 0.98
        (, uint256 sell) = module.currentBid();
        assertEq(sell, 5e5);
    }

    // ----------------------------------------------------------------- navExit vs twap (buyer-conservative)
    function test_prices_off_navExit_not_twap() public {
        // Build a REAL oracle where spot < twap, so navExit = min = spot. A bid that passes off twap must REVERT
        // off navExit (= spot, the lower mark) — proving buyer-conservative pricing.
        SzipNavOracle real = _realOracleSpotBelowTwap();
        uint256 spot = real.spotNavPerShare();
        uint256 twap = real.twapNavPerShare();
        assertLt(spot, twap, "need spot < twap");
        assertEq(real.navExit(), spot);

        SzipBuyBurnModule m = new SzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP));

        // Choose a sellAmount that passes against TWAP but fails against SPOT (navExit).
        uint256 buy = 1e18;
        uint256 maxOffTwap = _maxSell(buy, twap, D_BPS);
        uint256 maxOffSpot = _maxSell(buy, spot, D_BPS);
        assertGt(maxOffTwap, maxOffSpot, "twap ceiling must exceed spot ceiling");
        // a sellAmount in (maxOffSpot, maxOffTwap] passes vs twap, fails vs navExit
        uint256 sell = maxOffSpot + 1;
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        m.postBid(_order(sell, buy, _validTo()));
        // and the spot ceiling itself passes
        vm.prank(operator);
        m.postBid(_order(maxOffSpot, buy, _validTo()));
    }

    // ----------------------------------------------------------------- freshness (real oracle, warp)
    function test_freshness_gate_stale_reverts() public {
        SzipNavOracle real = _realOracleFresh();
        assertTrue(real.fresh());
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP));

        // age past maxAge -> not fresh -> postBid reverts StaleNav
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(real.fresh());
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.StaleNav.selector);
        m.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours)));
    }

    function test_freshness_never_pushed_reverts() public {
        // oracle with no legs ever pushed -> fresh() == false
        SzipNavOracle real = _realOracleBare();
        assertFalse(real.fresh());
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP));
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.StaleNav.selector);
        m.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours)));
    }

    // ----------------------------------------------------------------- exec discipline (recording mock)
    function test_exec_discipline_postBid_calls() public {
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, vt));
        assertEq(safe.callCount(), 2);
        // call 0: usdc.approve(vaultRelayer, sellAmount), Call, value 0
        (address to0, uint256 v0, bytes memory d0, uint8 op0) = safe.getCall(0);
        assertEq(to0, USDC);
        assertEq(v0, 0);
        assertEq(op0, 0); // Operation.Call
        assertEq(d0, abi.encodeWithSignature("approve(address,uint256)", COW_VAULT_RELAYER, uint256(5e5)));
        // call 1: settlement.setPreSignature(uid, true), Call, value 0
        (address to1, uint256 v1, bytes memory d1, uint8 op1) = safe.getCall(1);
        assertEq(to1, COW_SETTLEMENT);
        assertEq(v1, 0);
        assertEq(op1, 0);
        (bytes memory uid,) = module.currentBid();
        assertEq(d1, abi.encodeWithSelector(IGPv2Settlement.setPreSignature.selector, uid, true));
    }

    function test_exec_discipline_cancelBid_calls() public {
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, vt));
        (bytes memory uid,) = module.currentBid();
        vm.prank(operator);
        module.cancelBid();
        assertEq(safe.callCount(), 4);
        // call 2: settlement.setPreSignature(uid, false)
        (address to2, uint256 v2, bytes memory d2, uint8 op2) = safe.getCall(2);
        assertEq(to2, COW_SETTLEMENT);
        assertEq(v2, 0);
        assertEq(op2, 0);
        assertEq(d2, abi.encodeWithSelector(IGPv2Settlement.setPreSignature.selector, uid, false));
        // call 3: usdc.approve(vaultRelayer, 0)
        (address to3, uint256 v3, bytes memory d3, uint8 op3) = safe.getCall(3);
        assertEq(to3, USDC);
        assertEq(v3, 0);
        assertEq(op3, 0);
        assertEq(d3, abi.encodeWithSignature("approve(address,uint256)", COW_VAULT_RELAYER, uint256(0)));
        // state cleared
        (bytes memory u2, uint256 s2) = module.currentBid();
        assertEq(u2.length, 0);
        assertEq(s2, 0);
    }

    // ----------------------------------------------------------------- atomicity (2nd exec reverts -> rollback)
    function test_atomicity_second_exec_revert_rolls_back() public {
        // live executing safe so the approve really lands; force the 2nd exec (setPreSignature, call index 1) to fail.
        RecordingSafe esafe = new RecordingSafe();
        esafe.setLive(true);
        esafe.setFailOnCallIndex(1); // fail on the settlement call
        SzipBuyBurnModule m = _deploy(address(esafe), szip, CAP);

        vm.prank(operator);
        vm.expectRevert(); // the forced settlement failure bubbles up (whole tx reverts)
        m.postBid(_order(5e5, 1e18, _validTo()));

        // the approve is rolled back with the tx: allowance 0, currentUid unset
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 0);
        (bytes memory uid, uint256 sell) = m.currentBid();
        assertEq(uid.length, 0);
        assertEq(sell, 0);
    }

    // ----------------------------------------------------------------- uid vector (non-circular) + TYPE_HASH
    function test_typehash_constant() public view {
        assertEq(
            module.TYPE_HASH(),
            keccak256(
                "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,bytes32 kind,bool partiallyFillable,bytes32 sellTokenBalance,bytes32 buyTokenBalance)"
            )
        );
        assertEq(module.KIND_BUY(), keccak256("buy"));
        assertEq(module.BALANCE_ERC20(), keccak256("erc20"));
    }

    function test_orderUid_known_answer_vector() public {
        // A module whose usdc/szipUSD/engineSafe match the OUT-OF-BAND cast vector inputs.
        SzipBuyBurnModule m = new SzipBuyBurnModule();
        m.setUp(
            abi.encode(owner, VEC_ENGINE, operator, address(oracle), VEC_SZIPUSD, USDC, COW_SETTLEMENT, D_BPS, CAP)
        );
        SzipBuyBurnModule.GPv2OrderInput memory o = _order(VEC_SELL, VEC_BUY, VEC_VALIDTO);
        bytes memory uid = m._orderUid(o);
        // the pinned 56-byte known-answer vector (computed via `cast`, see the provenance comment above)
        assertEq(uid, VEC_UID);
        assertEq(uid.length, 56);
        // owner (bytes 32:52) == engineSafe (big-endian, left-aligned 20-byte address)
        bytes20 ownerInUid;
        assembly {
            // uid memory: [len][32-byte digest][20-byte owner][4-byte validTo]; owner at offset 0x20 + 32
            ownerInUid := mload(add(uid, add(0x20, 32)))
        }
        assertEq(address(ownerInUid), VEC_ENGINE);
        // validTo (bytes 52:56) big-endian == VEC_VALIDTO
        uint32 vtInUid;
        assembly {
            // load the last word covering bytes 52..56; shift it down to a uint32
            let w := mload(add(uid, add(0x20, 52)))
            vtInUid := shr(224, w)
        }
        assertEq(vtInUid, VEC_VALIDTO);
    }

    // ----------------------------------------------------------------- live fork: preSignature stored + allowance
    function test_fork_postBid_stores_presignature_and_allowance() public {
        // a LIVE executing engine Safe (forwards exec as real calls to the live settlement + USDC).
        RecordingSafe esafe = new RecordingSafe();
        esafe.setLive(true);
        SzipBuyBurnModule m = _deploy(address(esafe), szip, CAP);

        SzipBuyBurnModule.GPv2OrderInput memory o = _order(5e5, 1e18, uint32(block.timestamp + 1 hours));
        vm.prank(operator);
        m.postBid(o);

        (bytes memory uid,) = m.currentBid();
        // live Base settlement stored it under the packed owner = the engine Safe (msg.sender of setPreSignature)
        assertTrue(IGPv2Settlement(COW_SETTLEMENT).preSignature(uid) != 0, "presignature not stored");
        // USDC allowance(engineSafe, vaultRelayer) == sellAmount
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 5e5);

        // cancel flips it false + resets allowance to 0
        vm.prank(operator);
        m.cancelBid();
        assertEq(IGPv2Settlement(COW_SETTLEMENT).preSignature(uid), 0, "presignature not cleared");
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 0);
    }

    // ----------------------------------------------------------------- partial-fill-then-repost (double-fill guard)
    function test_partial_fill_then_repost() public {
        RecordingSafe esafe = new RecordingSafe();
        esafe.setLive(true);
        SzipBuyBurnModule m = _deploy(address(esafe), szip, CAP);

        uint32 vt1 = uint32(block.timestamp + 1 hours);
        vm.prank(operator);
        m.postBid(_order(5e5, 1e18, vt1));
        (bytes memory oldUid,) = m.currentBid();
        assertTrue(IGPv2Settlement(COW_SETTLEMENT).preSignature(oldUid) != 0);
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 5e5);

        // simulate a partial fill by warping forward (the resting order would partially fill off-chain); then cancel.
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(operator);
        m.cancelBid();
        assertEq(IGPv2Settlement(COW_SETTLEMENT).preSignature(oldUid), 0, "old presig cleared");
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 0, "allowance reset");

        // re-post with a NEW validTo -> new uid, allowance == new sellAmount only (never additive, no residue)
        uint32 vt2 = uint32(block.timestamp + 2 hours);
        vm.prank(operator);
        m.postBid(_order(3e5, 1e18, vt2));
        (bytes memory newUid, uint256 newSell) = m.currentBid();
        assertTrue(keccak256(newUid) != keccak256(oldUid), "new uid (new validTo)");
        assertEq(newSell, 3e5);
        assertEq(IERC20(USDC).allowance(address(esafe), COW_VAULT_RELAYER), 3e5, "allowance == new sellAmount only");
        assertTrue(IGPv2Settlement(COW_SETTLEMENT).preSignature(newUid) != 0);
    }

    // ----------------------------------------------------------------- quoteMaxPrice round-trip
    function test_quoteMaxPrice_roundtrip() public {
        // the 6-dp ceiling used as sellAmount per 1e18 buyAmount exactly passes postBid (no scale mismatch).
        uint256 ceil6 = module.quoteMaxPrice();
        // navExit $1, d 2% -> 0.98 USDC = 980000 (6-dp)
        assertEq(ceil6, 980_000);
        uint32 vt = _validTo();
        vm.prank(operator);
        module.postBid(_order(ceil6, 1e18, vt)); // exactly passes
        (, uint256 sell) = module.currentBid();
        assertEq(sell, ceil6);
        // ceil6 + 1 per 1e18 share reverts
        vm.prank(operator);
        module.cancelBid();
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.BidAboveDiscount.selector);
        module.postBid(_order(ceil6 + 1, 1e18, _validTo()));
    }

    // ----------------------------------------------------------------- real-oracle builders
    function _newRealOracle() internal returns (SzipNavOracle o, address fwd) {
        fwd = makeAddr("fwd");
        // minimal mock basket tokens (only addresses + balances matter for NAV).
        address zip = address(new OracleMockToken(18));
        address usdcM = address(new OracleMockToken(6));
        address xa = address(new OracleMockXAlpha());
        address hydx = address(new OracleMockToken(18));
        address ohydx = address(new OracleMockOHydx(30));
        address main = makeAddr("oracMain");
        address side = makeAddr("oracSide");
        o = new SzipNavOracle(fwd, zip, usdcM, xa, hydx, ohydx, main, side, 4 hours, 1 days, 2000);
    }

    function _pushBoth(SzipNavOracle o, address fwd, uint256 a, uint256 h) internal {
        uint8[] memory legs = new uint8[](2);
        uint256[] memory ps = new uint256[](2);
        legs[0] = o.LEG_ALPHA_USD();
        legs[1] = o.LEG_HYDX_USD();
        ps[0] = a;
        ps[1] = h;
        bytes memory report = abi.encode(uint8(7), abi.encode(legs, ps, uint32(block.timestamp)));
        vm.prank(fwd);
        o.onReport("", report);
    }

    function _realOracleFresh() internal returns (SzipNavOracle o) {
        address fwd;
        (o, fwd) = _newRealOracle();
        _pushBoth(o, fwd, 1e18, 5e17); // both legs fresh
    }

    function _realOracleBare() internal returns (SzipNavOracle o) {
        (o,) = _newRealOracle(); // no legs ever pushed -> fresh() false
    }

    /// @dev A real oracle wired so spot < twap (navExit = min = spot). Establish a higher twap over the window, then
    ///      drop spot in the latest block.
    function _realOracleSpotBelowTwap() internal returns (SzipNavOracle o) {
        address fwd;
        (o, fwd) = _newRealOracle();
        // share token + balances: set a high spot, build twap, then drop spot.
        OracleMockToken szipTok = new OracleMockToken(18);
        o.setShareToken(address(szipTok));
        szipTok.setTotalSupply(1000e18);
        address main = o.mainSafe();
        OracleMockToken zip = OracleMockToken(o.zipUSD());
        zip.setBalance(main, 3000e18); // spot = 3e18
        _pushBoth(o, fwd, 1e18, 5e17);
        uint256 T = block.timestamp;
        vm.warp(T + 2 hours);
        o.poke(); // book spot 3e18
        vm.warp(T + 4 hours);
        o.poke(); // book spot 3e18 again -> twap ~3e18
        // now DROP spot below twap in the latest block
        zip.setBalance(main, 1000e18); // spot = 1e18 < twap ~3e18
        // refresh legs so fresh() is true at the new time
        _pushBoth(o, fwd, 1e18, 5e17);
    }
}

// =========================================================================== oracle mock tokens (for the real NAV)
contract OracleMockToken {
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 d) {
        decimals = d;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
    }

    function setTotalSupply(uint256 v) external {
        totalSupply = v;
    }
}

contract OracleMockXAlpha is OracleMockToken {
    uint256 public exchangeRate = 1e18;

    constructor() OracleMockToken(18) {}
}

contract OracleMockOHydx is OracleMockToken {
    uint256 public discount;

    constructor(uint256 d) OracleMockToken(18) {
        discount = d;
    }
}
