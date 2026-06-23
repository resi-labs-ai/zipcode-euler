// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "../../ForkConfig.sol";
import {SzipBuyBurnModule} from "../../../src/supply/szipUSD/SzipBuyBurnModule.sol";
import {CloneReportReceiver} from "../../../src/supply/szipUSD/CloneReportReceiver.sol";
import {IReceiver} from "x402-cre-price-alerts/interfaces/IReceiver.sol";
import {IERC165} from "x402-cre-price-alerts/interfaces/IERC165.sol";
import {IGPv2Settlement} from "../../../src/interfaces/cow/IGPv2Settlement.sol";
import {SzipNavOracle} from "../../../src/supply/SzipNavOracle.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev SEC-14: mastercopies are init-locked in their ctor, so `setUp` on a bare impl reverts.
///      A fresh EIP-1167 clone (fresh proxy storage) behaves like the old bare instance for setUp.
function _cloneSzipBuyBurnModule() returns (SzipBuyBurnModule) {
    return SzipBuyBurnModule(Clones.clone(address(new SzipBuyBurnModule())));
}

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
    uint48 public oldestTsV; // 0 ⇒ report block.timestamp ("legs just pushed"), so the leg-anchored fence (SEC-13)
        // coincides with the old post-time anchor and existing fence tests behave identically

    function setNavExit(uint256 v) external {
        navExitV = v;
    }

    function setFresh(bool v) external {
        freshV = v;
    }

    function setMaxAge(uint256 v) external {
        maxAgeV = v;
    }

    function setOldestTs(uint48 v) external {
        oldestTsV = v;
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

    function oldestRequiredLegTs() external view returns (uint48) {
        return oldestTsV == 0 ? uint48(block.timestamp) : oldestTsV;
    }
}

// =========================================================================== tests

/// @dev A settable coverage gate (`ICoverageGate`) for the postBid outflow-gate test.
contract MockCoverageGate {
    bool public ret;

    function set(bool v) external {
        ret = v;
    }

    function covered() external view returns (bool) {
        return ret;
    }
}

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

    /// @dev SEC-14: the bare mastercopy is init-locked in its ctor; `setUp` on it reverts AlreadyInitialized.
    function test_SEC14_mastercopy_setUp_reverts() public {
        SzipBuyBurnModule mc = new SzipBuyBurnModule();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mc.setUp(
            abi.encode(
                owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)
            )
        );
    }

    // ----------------------------------------------------------------- helpers
    function _deploy(address juniorTrancheEngine_, address szipUSD_, uint256 cap_) internal returns (SzipBuyBurnModule m) {
        m = _cloneSzipBuyBurnModule();
        m.setUp(
            abi.encode(
                owner, juniorTrancheEngine_, operator, address(oracle), szipUSD_, USDC, COW_SETTLEMENT, D_BPS, cap_, address(0)
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
        assertEq(module.juniorTrancheEngine(), address(safe));
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
            abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0));
        vm.expectRevert(); // zodiac-core AlreadyInitialized
        module.setUp(p);
    }

    /// @dev SEC-15 (I6): `setOperator` re-point must preserve the init-time owner != operator separation.
    ///      Pre-fix the re-point only rejected the zero address, so it could silently collapse the two roles.
    function test_SEC15_setOperator_owner_recheck() public {
        // a valid non-owner, non-zero re-point still succeeds
        address newOp = makeAddr("sec15NewOp");
        vm.prank(owner);
        module.setOperator(newOp);
        assertEq(module.operator(), newOp);
        // re-pointing operator to the owner now reverts OwnerIsOperator (pre-fix it succeeded)
        vm.prank(owner);
        vm.expectRevert(SzipBuyBurnModule.OwnerIsOperator.selector);
        module.setOperator(owner);
        // zero still rejected
        vm.prank(owner);
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setOperator(address(0));
    }

    function test_setUp_rejects_owner_equals_operator() public {
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.OwnerIsOperator.selector);
        m.setUp(abi.encode(owner, address(safe), owner, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));
    }

    function test_setUp_rejects_zero_address() public {
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0), operator, address(oracle), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));
    }

    function test_setUp_rejects_bad_discount() public {
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        m.setUp(abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, uint16(0), CAP, address(0)));
        SzipBuyBurnModule m2 = _cloneSzipBuyBurnModule();
        vm.expectRevert(SzipBuyBurnModule.BadDiscount.selector);
        m2.setUp(
            abi.encode(owner, address(safe), operator, address(oracle), szip, USDC, COW_SETTLEMENT, uint16(10_000), CAP, address(0))
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
        // A bare-deployed mastercopy (never setUp) has zero operator/juniorTrancheEngine — postBid reverts NotOperator for all.
        SzipBuyBurnModule mc = _cloneSzipBuyBurnModule();
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.NotOperator.selector);
        mc.postBid(_order(1e6, 1e18, _validTo()));
        assertEq(mc.operator(), address(0));
        assertEq(mc.juniorTrancheEngine(), address(0));
    }

    function test_juniorTrancheEngine_identity_matches() public view {
        // The module's juniorTrancheEngine is the order receiver/owner; deploy wires the Gate's + oracle's setJuniorTrancheEngine to
        // the same Safe (item-10). Here: the module's juniorTrancheEngine == the Safe it is enabled on.
        assertEq(module.juniorTrancheEngine(), address(safe));
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

    /// @dev The six build-phase wiring setters (besides `setOperator`/`setCoverageGate`/the governed params, covered
    ///      elsewhere): each is `onlyOwner`, non-zero-guarded, and takes effect. Several re-point what is priced/
    ///      signed/spent (`navOracle`/`szipUSD`/`usdc`/`settlement`), so the wiring matters on the value-out module.
    ///      (`setJuniorTrancheEngine` does NOT sync avatar/target here — unlike the swap/LP/exercise modules — so
    ///      there is no sync to assert.)
    function test_wiring_setters_onlyOwner_effect_and_zeroGuard() public {
        address x = makeAddr("rewire");

        // non-owner rejected on every setter
        vm.startPrank(rando);
        bytes memory unauth = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando);
        vm.expectRevert(unauth);
        module.setJuniorTrancheEngine(x);
        vm.expectRevert(unauth);
        module.setNavOracle(x);
        vm.expectRevert(unauth);
        module.setSzipUSD(x);
        vm.expectRevert(unauth);
        module.setUsdc(x);
        vm.expectRevert(unauth);
        module.setSettlement(x);
        vm.expectRevert(unauth);
        module.setVaultRelayer(x);
        vm.stopPrank();

        // owner re-points take effect
        vm.startPrank(owner);
        module.setJuniorTrancheEngine(x);
        assertEq(module.juniorTrancheEngine(), x, "juniorTrancheEngine re-pointed");
        module.setNavOracle(x);
        assertEq(module.navOracle(), x, "navOracle re-pointed (the pricing primitive)");
        module.setSzipUSD(x);
        assertEq(module.szipUSD(), x, "szipUSD re-pointed (the buyToken)");
        module.setUsdc(x);
        assertEq(module.usdc(), x, "usdc re-pointed (the sellToken)");
        module.setSettlement(x);
        assertEq(module.settlement(), x, "settlement re-pointed (the presign target)");
        module.setVaultRelayer(x);
        assertEq(module.vaultRelayer(), x, "vaultRelayer re-pointed (the approve spender)");

        // zero rejected on every setter
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setJuniorTrancheEngine(address(0));
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setNavOracle(address(0));
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setSzipUSD(address(0));
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setUsdc(address(0));
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setSettlement(address(0));
        vm.expectRevert(SzipBuyBurnModule.ZeroAddress.selector);
        module.setVaultRelayer(address(0));
        vm.stopPrank();
    }

    /// @dev SUPPLY-ADV-05: the three value-load-bearing wiring setters `_cancelBid` dereferences (`settlement`/
    ///      `vaultRelayer`/`usdc`) must refuse a re-point while a bid is live. Otherwise a re-point between post and
    ///      cancel would make `_cancelBid` flip the presign / zero the allowance on the NEW wiring, stranding the OLD
    ///      presign + allowance LIVE (a fillable bid the owner believes was cancelled). Cancel-before-rewire is forced.
    function test_SUPPLYADV05_wiring_setters_reject_rewire_under_live_bid() public {
        address x = makeAddr("rewireLive");
        // post a live bid (deep discount, passes)
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, _validTo()));
        assertTrue(module.currentUid().length != 0, "bid is live");

        // each value-load-bearing setter now reverts BidAlreadyLive (the new guard), even for the owner
        vm.startPrank(owner);
        vm.expectRevert(SzipBuyBurnModule.BidAlreadyLive.selector);
        module.setSettlement(x);
        vm.expectRevert(SzipBuyBurnModule.BidAlreadyLive.selector);
        module.setVaultRelayer(x);
        vm.expectRevert(SzipBuyBurnModule.BidAlreadyLive.selector);
        module.setUsdc(x);
        vm.stopPrank();

        // cancel clears the live bid; the same re-points then succeed (no stranding possible)
        vm.prank(operator);
        module.cancelBid();
        assertEq(module.currentUid().length, 0, "bid cleared");
        vm.startPrank(owner);
        module.setSettlement(x);
        assertEq(module.settlement(), x, "settlement re-points once no bid is live");
        module.setVaultRelayer(x);
        assertEq(module.vaultRelayer(), x, "vaultRelayer re-points once no bid is live");
        module.setUsdc(x);
        assertEq(module.usdc(), x, "usdc re-points once no bid is live");
        vm.stopPrank();
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

    function test_postBid_coverage_gate() public {
        MockCoverageGate gate = new MockCoverageGate();
        vm.prank(owner);
        module.setCoverageGate(address(gate));
        uint32 vt = _validTo();

        // coverage below the floor -> the free-side outflow is blocked
        gate.set(false);
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.Undercovered.selector);
        module.postBid(_order(5e5, 1e18, vt));

        // covered -> the bid posts
        gate.set(true);
        vm.prank(operator);
        module.postBid(_order(5e5, 1e18, vt));
        assertTrue(module.currentUid().length != 0, "bid posts once covered");
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

        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));

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
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));

        // Age both pushed legs past maxAge -> fresh() false. SEC-13 (L12): the leg-anchored `validTo` fence now
        // binds BEFORE the `fresh()` gate for an age-stale leg — once a leg is older than maxAge,
        // `oldestRequiredLegTs() + maxAge < now < validTo`, so the fence reverts `ValidToBeyondNavFreshness` first.
        // The bid is still rejected fail-closed; only the selector differs (StaleNav remains reachable via the rate
        // path — fresh legs but a stale cross-chain rate — which the fence's leg-only anchor does not pre-empt).
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(real.fresh());
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        m.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours)));
    }

    function test_freshness_never_pushed_reverts() public {
        // oracle with no legs ever pushed -> fresh() == false, and oldestRequiredLegTs() == 0 (unset legs).
        SzipNavOracle real = _realOracleBare();
        assertFalse(real.fresh());
        assertEq(real.oldestRequiredLegTs(), 0, "unset legs -> anchor 0");
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(real), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));
        // SEC-13 (L12): with the anchor at 0, `0 + maxAge < now < validTo`, so the leg-anchored fence reverts
        // `ValidToBeyondNavFreshness` before the `fresh()`/`StaleNav` gate — the never-pushed oracle is rejected
        // fail-closed at the fence (the design's unset-leg path).
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        m.postBid(_order(5e5, 1e18, uint32(block.timestamp + 1 hours)));
    }

    // ----------------------------------------------------------------- SEC-13 (L12): validTo anchored to oldest leg
    // The resting-bid `validTo` ceiling is anchored to the OLDEST required NAV leg's timestamp + maxAge (not
    // post-time), so the worst-case mark age at fill is `maxAge`, not `2·maxAge`. Real oracle (real legCache ts) with
    // maxAge < MAX_BID_TTL so the leg-anchored fence binds before BadValidTo.
    uint256 internal constant SEC13_MAX_AGE = 1 hours; // < MAX_BID_TTL (1 day)

    // Build a real oracle with a chosen maxAge (the `_newRealOracle` builder hard-codes 1 days == MAX_BID_TTL).
    function _realOracleMaxAge(uint256 maxAge_) internal returns (SzipNavOracle o, address fwd) {
        fwd = makeAddr("fwdSEC13");
        o = new SzipNavOracle(
            fwd,
            address(new OracleMockToken(18)),
            address(new OracleMockToken(6)),
            address(new OracleMockXAlpha()),
            address(new OracleMockToken(18)),
            address(new OracleMockOHydx(30)),
            makeAddr("oracMainSEC13"),
            makeAddr("oracSideSEC13"),
            4 hours,
            maxAge_,
            2000
        );
    }

    function _moduleFor(SzipNavOracle o) internal returns (SzipBuyBurnModule m) {
        m = _cloneSzipBuyBurnModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(o), szip, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0)));
    }

    /// @notice 2·maxAge window CLOSED: legs at t0, warp by a (0<a<maxAge, still fresh); a `validTo` at the OLD
    ///         post-time ceiling (now + maxAge = t0 + a + maxAge) now reverts — the new ceiling is t0 + maxAge.
    function test_SEC13_two_maxAge_window_closed() public {
        (SzipNavOracle o, address fwd) = _realOracleMaxAge(SEC13_MAX_AGE);
        uint256 t0 = block.timestamp;
        _pushBoth(o, fwd, 1e18, 5e17); // legs at t0
        SzipBuyBurnModule m = _moduleFor(o);

        uint256 a = 30 minutes; // 0 < a < maxAge
        vm.warp(t0 + a);
        assertTrue(o.fresh(), "legs still fresh at t0 + a");
        assertEq(o.oldestRequiredLegTs(), t0, "anchor is the leg ts, not post-time");

        uint256 sell = _maxSell(1e18, o.navExit(), D_BPS); // deep-discount sized so the price bound never masks

        // OLD post-time ceiling (now + maxAge) is now PAST the leg-anchored ceiling (t0 + maxAge) — reverts.
        uint32 oldCeil = uint32(t0 + a + SEC13_MAX_AGE);
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        m.postBid(_order(sell, 1e18, oldCeil));

        // The NEW ceiling (t0 + maxAge), only `maxAge - a` ahead, posts cleanly.
        vm.prank(operator);
        m.postBid(_order(sell, 1e18, uint32(t0 + SEC13_MAX_AGE)));
    }

    /// @notice Fill-age bound: the maximum postable `validTo` is exactly `oldestLegTs + maxAge`, so a fill can land
    ///         against a mark at most `maxAge` old (not `2·maxAge`). `+1` past that ceiling reverts.
    function test_SEC13_fill_age_capped_at_maxAge() public {
        (SzipNavOracle o, address fwd) = _realOracleMaxAge(SEC13_MAX_AGE);
        uint256 t0 = block.timestamp;
        _pushBoth(o, fwd, 1e18, 5e17);
        SzipBuyBurnModule m = _moduleFor(o);

        vm.warp(t0 + 10 minutes);
        uint256 sell = _maxSell(1e18, o.navExit(), D_BPS);

        // exact ceiling posts (fence uses strict `>`); the implied max fill-time leg age is maxAge.
        vm.prank(operator);
        m.postBid(_order(sell, 1e18, uint32(t0 + SEC13_MAX_AGE)));

        // one second past the leg-anchored ceiling reverts (would imply a fill-age > maxAge).
        SzipBuyBurnModule m2 = _moduleFor(o);
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        m2.postBid(_order(sell, 1e18, uint32(t0 + SEC13_MAX_AGE + 1)));
    }

    /// @notice Edge fail-closed: legs aged EXACTLY maxAge (anchor + maxAge == now), so no forward-resting window
    ///         exists — any `validTo > now` reverts cleanly (no underflow/panic), legs still technically fresh.
    function test_SEC13_edge_legs_at_freshness_limit_fail_closed() public {
        (SzipNavOracle o, address fwd) = _realOracleMaxAge(SEC13_MAX_AGE);
        uint256 t0 = block.timestamp;
        _pushBoth(o, fwd, 1e18, 5e17);
        SzipBuyBurnModule m = _moduleFor(o);

        vm.warp(t0 + SEC13_MAX_AGE); // age == maxAge: _legStale uses strict `>`, so still fresh
        assertTrue(o.fresh(), "exactly maxAge old is still fresh");
        assertEq(o.oldestRequiredLegTs() + SEC13_MAX_AGE, block.timestamp, "anchor + maxAge == now");

        uint256 sell = _maxSell(1e18, o.navExit(), D_BPS);
        // validTo must be > now (BadValidTo guards <= now); the smallest legal validTo (now+1) trips the fence.
        vm.prank(operator);
        vm.expectRevert(SzipBuyBurnModule.ValidToBeyondNavFreshness.selector);
        m.postBid(_order(sell, 1e18, uint32(block.timestamp + 1)));
    }

    /// @notice Fresh legs still postable: with a small age, a near-term `validTo` posts successfully.
    function test_SEC13_fresh_legs_near_term_validTo_posts() public {
        (SzipNavOracle o, address fwd) = _realOracleMaxAge(SEC13_MAX_AGE);
        uint256 t0 = block.timestamp;
        _pushBoth(o, fwd, 1e18, 5e17);
        SzipBuyBurnModule m = _moduleFor(o);

        vm.warp(t0 + 1 minutes);
        uint256 sell = _maxSell(1e18, o.navExit(), D_BPS);
        vm.prank(operator);
        m.postBid(_order(sell, 1e18, uint32(block.timestamp + 10 minutes))); // well within t0 + maxAge
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
        // A module whose usdc/szipUSD/juniorTrancheEngine match the OUT-OF-BAND cast vector inputs.
        SzipBuyBurnModule m = _cloneSzipBuyBurnModule();
        m.setUp(
            abi.encode(owner, VEC_ENGINE, operator, address(oracle), VEC_SZIPUSD, USDC, COW_SETTLEMENT, D_BPS, CAP, address(0))
        );
        SzipBuyBurnModule.GPv2OrderInput memory o = _order(VEC_SELL, VEC_BUY, VEC_VALIDTO);
        bytes memory uid = m._orderUid(o);
        // the pinned 56-byte known-answer vector (computed via `cast`, see the provenance comment above)
        assertEq(uid, VEC_UID);
        assertEq(uid.length, 56);
        // owner (bytes 32:52) == juniorTrancheEngine (big-endian, left-aligned 20-byte address)
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
        // USDC allowance(juniorTrancheEngine, vaultRelayer) == sellAmount
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

    // =================================================================== CTR-01: CRE report socket (CloneReportReceiver)
    // The module is ALSO drivable by a DON-signed report delivered through the Keystone Forwarder (8-B14 exception):
    // `onReport(metadata, report)` is forwarder-gated (fail-closed on an unset/zero forwarder), then routes the §8.0
    // envelope `abi.encode(uint8 reportType, bytes payload)` to the SAME `_postBid`/`_cancelBid` internals the operator
    // path uses. The mock Forwarder is just a prank address (no mock contract needed — pin 10).

    address internal forwarder = makeAddr("keystoneForwarder");

    /// @dev Build the canonical metadata: abi.encodePacked(workflowId bytes32, workflowName bytes10, owner address).
    function _meta(bytes32 workflowId, bytes10 workflowName, address workflowOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }

    /// @dev Build a POST_BID report: envelope(POST_BID, abi.encode(sellAmount, buyAmount, validTo)).
    function _postBidReport(uint256 sell, uint256 buy, uint32 validTo) internal view returns (bytes memory) {
        return abi.encode(module.POST_BID(), abi.encode(sell, buy, validTo));
    }

    /// @dev Build a CANCEL_BID report: envelope(CANCEL_BID, "") (empty payload).
    function _cancelBidReport() internal view returns (bytes memory) {
        return abi.encode(module.CANCEL_BID(), bytes(""));
    }

    /// @dev A module wired with `forwarder` (and no workflow-identity check), ready for the report path.
    function _deployWired() internal returns (SzipBuyBurnModule m) {
        m = _deploy(address(safe), szip, CAP);
        vm.prank(owner);
        m.setForwarder(forwarder);
    }

    // (a) report-driven POST_BID via the mock Forwarder produces the EXACT same uid/sellAmount/BidPosted as the
    //     equivalent operator postBid (same inputs) — req 1, two doors one guard set.
    function test_CTR01_report_postBid_equals_operator_postBid() public {
        uint32 vt = uint32(block.timestamp + 1 hours);
        SzipBuyBurnModule.GPv2OrderInput memory o = _order(5e5, 1e18, vt);

        // door 1: operator postBid on its own clone
        SzipBuyBurnModule mOp = _deploy(address(safe), szip, CAP);
        vm.prank(operator);
        mOp.postBid(o);
        (bytes memory uidOp, uint256 sellOp) = mOp.currentBid();

        // door 2: report-driven POST_BID on an identically-setUp clone, via the forwarder
        SzipBuyBurnModule mRep = _deployWired();
        bytes memory meta = _meta(bytes32(0), bytes10(0), address(0));
        bytes memory report = _postBidReport(5e5, 1e18, vt);
        vm.expectEmit(false, false, false, true, address(mRep));
        emit SzipBuyBurnModule.BidPosted(uidOp, 5e5, 1e18, vt, 1e18, D_BPS);
        vm.prank(forwarder);
        mRep.onReport(meta, report);
        (bytes memory uidRep, uint256 sellRep) = mRep.currentBid();

        assertEq(uidRep, uidOp, "report uid == operator uid");
        assertEq(sellRep, sellOp, "report sellAmount == operator sellAmount");
        assertEq(uidRep.length, 56);
    }

    // (b) un-wired (zero-forwarder) clone: onReport reverts fail-closed (req 2 — the clone inversion).
    function test_CTR01_unwired_clone_onReport_reverts() public {
        SzipBuyBurnModule m = _deploy(address(safe), szip, CAP); // forwarder defaults to zero
        assertEq(m.forwarder(), address(0));
        bytes memory report = _postBidReport(5e5, 1e18, uint32(block.timestamp + 1 hours));
        vm.expectRevert(
            abi.encodeWithSelector(CloneReportReceiver.InvalidForwarder.selector, address(this), address(0))
        );
        m.onReport(_meta(bytes32(0), bytes10(0), address(0)), report);
    }

    // (c) wrong caller (not the wired forwarder) reverts.
    function test_CTR01_wrong_forwarder_caller_reverts() public {
        SzipBuyBurnModule m = _deployWired();
        bytes memory report = _postBidReport(5e5, 1e18, uint32(block.timestamp + 1 hours));
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(CloneReportReceiver.InvalidForwarder.selector, rando, forwarder));
        m.onReport(_meta(bytes32(0), bytes10(0), address(0)), report);
    }

    // (d) workflow-id mismatch reverts; the matching id passes (req 3).
    function test_CTR01_workflow_id_mismatch_reverts_match_passes() public {
        bytes32 wfId = keccak256("buy-burn-bid-loop");
        SzipBuyBurnModule m = _deployWired();
        vm.prank(owner);
        m.setExpectedWorkflowId(wfId);
        assertEq(m.expectedWorkflowId(), wfId);

        uint32 vt = uint32(block.timestamp + 1 hours);
        bytes memory report = _postBidReport(5e5, 1e18, vt);

        // wrong id -> revert
        bytes32 wrongId = keccak256("some-other-workflow");
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CloneReportReceiver.InvalidWorkflowId.selector, wrongId, wfId));
        m.onReport(_meta(wrongId, bytes10(0), address(0)), report);

        // matching id -> posts
        vm.prank(forwarder);
        m.onReport(_meta(wfId, bytes10(0), address(0)), report);
        assertTrue(m.currentUid().length != 0, "matching workflow id posts the bid");
    }

    // (d2) workflow-AUTHOR mismatch reverts; the matching author passes (the symmetric twin of (d) — the
    //      `expectedAuthor` identity gate in CloneReportReceiver.onReport, otherwise uncovered).
    function test_CTR01_workflow_author_mismatch_reverts_match_passes() public {
        address author = makeAddr("workflowAuthor");
        SzipBuyBurnModule m = _deployWired();
        vm.prank(owner);
        m.setExpectedAuthor(author);
        assertEq(m.expectedAuthor(), author);

        uint32 vt = uint32(block.timestamp + 1 hours);
        bytes memory report = _postBidReport(5e5, 1e18, vt);

        // wrong author -> revert
        address wrongAuthor = makeAddr("notTheAuthor");
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CloneReportReceiver.InvalidAuthor.selector, wrongAuthor, author));
        m.onReport(_meta(bytes32(0), bytes10(0), wrongAuthor), report);

        // matching author -> posts
        vm.prank(forwarder);
        m.onReport(_meta(bytes32(0), bytes10(0), author), report);
        assertTrue(m.currentUid().length != 0, "matching workflow author posts the bid");
    }

    // (e) report-driven CANCEL_BID retracts the live bid.
    function test_CTR01_report_cancelBid_retracts_live_bid() public {
        SzipBuyBurnModule m = _deployWired();
        uint32 vt = uint32(block.timestamp + 1 hours);
        bytes memory meta = _meta(bytes32(0), bytes10(0), address(0));
        bytes memory postReport = _postBidReport(5e5, 1e18, vt);
        bytes memory cancelReport = _cancelBidReport();
        // post via the report path first
        vm.prank(forwarder);
        m.onReport(meta, postReport);
        (bytes memory uid,) = m.currentBid();
        assertEq(uid.length, 56, "bid live before cancel");

        // cancel via the report path
        vm.prank(forwarder);
        m.onReport(meta, cancelReport);
        (bytes memory u2, uint256 s2) = m.currentBid();
        assertEq(u2.length, 0, "uid cleared");
        assertEq(s2, 0, "sellAmount cleared");
    }

    // (f) an unsupported reportType reverts UnsupportedReportType.
    function test_CTR01_unsupported_report_type_reverts() public {
        SzipBuyBurnModule m = _deployWired();
        uint8 bogus = 9;
        bytes memory report = abi.encode(bogus, bytes(""));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CloneReportReceiver.UnsupportedReportType.selector, bogus));
        m.onReport(_meta(bytes32(0), bytes10(0), address(0)), report);
    }

    // (g) — covered by every pre-existing operator-path test above remaining green (req 4).

    /// @dev supportsInterface reports IReceiver + IERC165 (the report-receiver surface).
    function test_CTR01_supportsInterface() public view {
        assertTrue(module.supportsInterface(type(IReceiver).interfaceId), "IReceiver");
        assertTrue(module.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(module.supportsInterface(0xffffffff), "not 0xffffffff");
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
        address main = o.juniorTrancheSafe();
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
