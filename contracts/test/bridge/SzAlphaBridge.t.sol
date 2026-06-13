// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenPool} from "chainlink-ccip/pools/TokenPool.sol";
import {ERC20LockBox} from "chainlink-ccip/pools/ERC20LockBox.sol";
import {RateLimiter} from "chainlink-ccip/libraries/RateLimiter.sol";
import {Pool} from "chainlink-ccip/libraries/Pool.sol";
import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";

import {SzAlpha} from "../../src/bridge/SzAlpha.sol";
import {SzAlphaMirror} from "../../src/bridge/SzAlphaMirror.sol";
import {SzAlphaTokenPool} from "../../src/bridge/SzAlphaTokenPool.sol";
import {SzAlphaLockReleasePool} from "../../src/bridge/SzAlphaLockReleasePool.sol";
import {DeploySzAlphaBridge} from "../../script/DeploySzAlphaBridge.s.sol";
import {
    MockSubtensorStaking,
    MockAlphaPrecompile,
    MockAddressMapping,
    MockRouter,
    MockRMN,
    Mock6DecimalToken
} from "./BridgeMocks.sol";

/// @dev A trivial V2 implementation for the UUPS upgrade / storage-gap test.
contract SzAlphaV2 is SzAlpha {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Re-enters `redeem` from its native callback to prove `nonReentrant` blocks a drain.
contract ReentrantRedeemer {
    SzAlpha public immutable token;
    bool public armed;

    constructor(SzAlpha t) {
        token = t;
    }

    function arm() external {
        armed = true;
    }

    function doDeposit() external payable {
        token.deposit{value: msg.value}(0, type(uint256).max);
    }

    function doRedeem(uint256 shares) external {
        token.redeem(shares, 0, type(uint256).max);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            token.redeem(1, 0, type(uint256).max); // re-entry attempt; must revert under the guard
        }
    }
}

/// @title SzAlphaBridge unit + lane suite (MOCKED precompiles + MOCKED CCIP relay).
/// @notice The Subtensor StakingV2/Alpha/AddressMapping precompiles are mocked (no public 964 fork node)
///         and the CCIP relay is mocked (no DON) — BOTH explicitly sanctioned by the 8x-01 ticket. Every
///         test that relies on a mock says so. The SzAlpha wrapper logic, the pools' added asserts, and
///         the lock/release custody wiring are real. Mocks are UNIT-FAITHFUL: rao 9-dp stake ledger and
///         a settable TAO<->alpha AMM price (par by default) — see BridgeMocks.sol.
contract SzAlphaBridgeTest is Test {
    address internal constant STAKING_V2 = 0x0000000000000000000000000000000000000805;
    address internal constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address internal constant ADDRESS_MAPPING = 0x000000000000000000000000000000000000080C;

    uint256 internal constant NETUID = 99;
    bytes32 internal constant HOTKEY = bytes32(uint256(0xABCD));
    uint64 internal constant REMOTE_SEL = 15971525489660198786; // Base selector
    uint256 internal constant RAO = 1e9;
    uint256 internal constant MAX_DL = type(uint256).max;

    SzAlpha internal token;
    SzAlphaLockReleasePool internal pool;
    ERC20LockBox internal lockBox;
    MockRouter internal router;
    MockRMN internal rmn;

    address internal timelock = makeAddr("timelock");
    address internal ccipAdmin = makeAddr("ccipAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal onRamp = makeAddr("onRamp");
    address internal offRamp = makeAddr("offRamp");
    address internal remotePoolAddr = makeAddr("remotePool");
    address internal remoteTokenAddr = makeAddr("remoteToken");

    function setUp() public {
        // When the whole suite runs under `--fork-url base`, a `makeAddr` EOA can collide with a real
        // deployed Base contract whose fallback swallows/forwards native — which breaks the TAO-return
        // assertions. Clear code at the EOAs that RECEIVE native so they behave as plain EOAs on the fork.
        vm.etch(alice, hex"");
        vm.etch(bob, hex"");

        // Etch the precompile mocks at their canonical addresses.
        vm.etch(STAKING_V2, address(new MockSubtensorStaking()).code);
        vm.etch(ALPHA_PRECOMPILE, address(new MockAlphaPrecompile()).code);
        vm.etch(ADDRESS_MAPPING, address(new MockAddressMapping()).code);
        vm.deal(STAKING_V2, 1_000_000 ether); // so removeStake can pay TAO back
        _setPrice(1e9); // vm.etch copies bytecode but NOT storage: the mocks' par-price field
        // initializers are zeroed at the etched addresses — set par explicitly.

        // Deploy the wrapper behind a UUPS proxy.
        SzAlpha impl = new SzAlpha();
        bytes memory initData =
            abi.encodeCall(SzAlpha.initialize, ("Staked xALPHA", "szALPHA", NETUID, HOTKEY, timelock, ccipAdmin));
        token = SzAlpha(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Deploy the 964 lock/release custody: lockbox holds bridged-out supply; the pool is an
        // authorized caller. NO mint/burn role exists on the token (lock/release topology).
        router = new MockRouter();
        rmn = new MockRMN();
        lockBox = new ERC20LockBox(address(token));
        pool = new SzAlphaLockReleasePool(
            IERC20(address(token)), 18, address(rmn), address(router), address(lockBox), address(rmn)
        );
        address[] memory added = new address[](1);
        added[0] = address(pool);
        lockBox.applyAuthorizedCallerUpdates(
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: added, removedCallers: new address[](0)})
        );

        // Configure the remote lane on the pool (test contract is the pool owner).
        router.setOnRamp(REMOTE_SEL, onRamp);
        router.setOffRamp(REMOTE_SEL, offRamp, true);
        _applyLane(1_000_000 ether, 1_000_000 ether);
    }

    function _applyLane(uint128 outCap, uint128 inCap) internal {
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(remotePoolAddr);
        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: REMOTE_SEL,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteTokenAddr),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: outCap, rate: outCap}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: inCap, rate: inCap})
        });
        pool.applyChainUpdates(new uint64[](0), adds);
    }

    function _coldkey() internal view returns (bytes32) {
        return keccak256(abi.encode(address(token)));
    }

    function _staking() internal pure returns (MockSubtensorStaking) {
        return MockSubtensorStaking(payable(STAKING_V2));
    }

    /// @dev Set the TAO<->alpha AMM price on BOTH mocks (etched bytecode does not share storage).
    function _setPrice(uint256 raoPerAlpha) internal {
        _staking().setPrice(raoPerAlpha);
        MockAlphaPrecompile(ALPHA_PRECOMPILE).setPrice(raoPerAlpha);
    }

    // ================================================================
    // │              Wrapper: deposit / redeem (mocked 964)          │
    // ================================================================

    function test_deposit_stakesAndMintsShares() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 5 ether}(0, MAX_DL);

        assertEq(shares, 5 ether, "genesis 1:1 at par price");
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.totalStaked(), 5 ether, "stake landed under wrapper coldkey (18-dp normalized)");
        assertEq(token.totalSupply(), 5 ether);
    }

    function test_redeem_unstakesBurnsAndReturnsTao() public {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 5 ether}(0, MAX_DL);
        uint256 balBefore = alice.balance;
        uint256 out = token.redeem(2 ether, 0, MAX_DL);
        vm.stopPrank();

        assertEq(out, 2 ether, "1:1 redeem at genesis rate, par price");
        assertEq(alice.balance, balBefore + 2 ether, "TAO returned");
        assertEq(token.balanceOf(alice), 3 ether, "shares burned");
        assertEq(token.totalStaked(), 3 ether, "stake reduced");
    }

    function test_rateRisesWithRewards() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.deposit{value: 4 ether}(0, MAX_DL);
        assertEq(token.exchangeRate(), 1e18, "1:1 before rewards");

        // Validator rewards lift backing stake (no new shares) -> rate rises. 9-dp alpha units.
        _staking().addReward(HOTKEY, _coldkey(), NETUID, 4 * 1e9);
        assertApproxEqAbs(token.exchangeRate(), 2e18, 1, "rate ~2x after 100% reward");

        // A later depositor pays the higher rate (fewer shares per alpha).
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bobShares = token.deposit{value: 4 ether}(0, MAX_DL);
        assertApproxEqAbs(bobShares, 2 ether, 1e9, "bob gets ~half the shares at 2x rate");
    }

    // ================================================================
    // │     Units: rao conversion, remainder refund, sub-rao guard   │
    // ================================================================

    function test_deposit_refundsSubRaoRemainder() public {
        vm.deal(alice, 10 ether);
        uint256 balBefore = alice.balance;
        vm.expectEmit(true, false, false, true);
        emit SzAlpha.Deposited(alice, 5 ether, 5 * 1e9, 5 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 5 ether + 7}(0, MAX_DL);

        assertEq(shares, 5 ether, "shares priced on the rao-aligned amount only");
        assertEq(alice.balance, balBefore - 5 ether, "the 7-wei sub-rao remainder was refunded");
    }

    function test_deposit_subRaoAmountReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.deposit{value: 1e9 - 1}(0, MAX_DL); // < 1 rao of TAO
    }

    // ================================================================
    // │     AMM price: measured-delta minting + slippage bounds      │
    // ================================================================

    function test_deposit_offParPrice_mintsMeasuredDelta() public {
        // 1 alpha costs 2 TAO (mocked AMM price; both mocks kept in sync).
        _setPrice(2e9);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 4 ether}(0, MAX_DL);

        // 4 TAO buys 2 alpha; genesis rate 1:1 alpha-per-share -> 2e18 shares, NOT 4e18.
        assertEq(shares, 2 ether, "shares minted against the MEASURED alpha delta");
        assertEq(token.totalStaked(), 2 ether, "backing is 2 alpha (18-dp normalized)");
    }

    function test_deposit_slippageExceededReverts() public {
        _setPrice(2e9);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SzAlpha.SlippageExceeded.selector, 2 ether, 2 ether + 1));
        token.deposit{value: 4 ether}(2 ether + 1, MAX_DL);
    }

    function test_redeem_offParPrice_paysMeasuredTao() public {
        _setPrice(2e9);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 4 ether}(0, MAX_DL); // 2e18 shares backed by 2 alpha
        uint256 balBefore = alice.balance;
        uint256 out = token.redeem(1 ether, 0, MAX_DL); // 1 share -> 1 alpha -> 2 TAO
        vm.stopPrank();

        assertEq(out, 2 ether, "payout is the measured TAO from the alpha->TAO swap");
        assertEq(alice.balance, balBefore + 2 ether);
    }

    function test_redeem_slippageExceededReverts() public {
        _setPrice(2e9);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 4 ether}(0, MAX_DL);
        vm.expectRevert(abi.encodeWithSelector(SzAlpha.SlippageExceeded.selector, 2 ether, 2 ether + 1));
        token.redeem(1 ether, 2 ether + 1, MAX_DL);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2 ether, "whole redeem reverted; shares restored");
    }

    function test_deadlineExpiredReverts() public {
        vm.warp(1000);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(SzAlpha.DeadlineExpired.selector);
        token.deposit{value: 1 ether}(0, 999);

        vm.prank(alice);
        vm.expectRevert(SzAlpha.DeadlineExpired.selector);
        token.redeem(1, 0, 999);
    }

    // ================================================================
    // │     Previews: honest AMM-sim quotes (mocked Alpha 0x808)     │
    // ================================================================

    function test_previews_matchExecution_atParAndOffPar() public {
        vm.deal(alice, 100 ether);

        // Par.
        uint256 quoted = token.previewDeposit(5 ether);
        vm.prank(alice);
        uint256 minted = token.deposit{value: 5 ether}(0, MAX_DL);
        assertEq(quoted, minted, "previewDeposit == executed shares (static price)");

        uint256 quotedOut = token.previewRedeem(2 ether);
        vm.prank(alice);
        uint256 paid = token.redeem(2 ether, 0, MAX_DL);
        assertEq(quotedOut, paid, "previewRedeem == executed TAO out (static price)");

        // Off-par.
        _setPrice(3e9);
        uint256 quoted2 = token.previewDeposit(9 ether); // 9 TAO -> 3 alpha at price 3
        vm.prank(alice);
        uint256 minted2 = token.deposit{value: 9 ether}(0, MAX_DL);
        assertEq(quoted2, minted2, "preview tracks the AMM price, not par");
    }

    function test_previewDeposit_subRaoReturnsZero() public view {
        assertEq(token.previewDeposit(1e9 - 1), 0, "sub-rao deposit quotes zero (would revert)");
    }

    // ================================================================
    // │              S3: anti-dilution / first mint                  │
    // ================================================================

    function test_firstDeposit_oneToOne_noDivByZero() public {
        // Fresh wrapper: supply=0, stake=0. Virtual offset (1/1) -> 1:1, never divides by zero.
        assertEq(token.totalSupply(), 0);
        assertEq(token.exchangeRate(), 1e18);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 1 ether}(0, MAX_DL);
        assertEq(shares, 1 ether);
    }

    function test_donationHonesty_griefingIsValueDestroying() public {
        // A third party CAN raise the backing stake (transferStake — simulated by addReward; same
        // observable effect). The donation is a pure gift: the donor holds no shares to reclaim it.
        _staking().addReward(HOTKEY, _coldkey(), NETUID, 100 * 1e9); // donate 100 alpha pre-genesis
        vm.deal(alice, 1000 ether);

        // A dust deposit rounds to zero shares -> reverts ZeroSharesOut (no silent loss).
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroSharesOut.selector);
        token.deposit{value: 1e9}(0, MAX_DL); // 1 rao of TAO vs a 100-alpha pre-stake

        // A depositor protecting with minSharesOut is shielded from donation-skewed pricing.
        uint256 quote = token.previewDeposit(200 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 200 ether}(quote, MAX_DL);
        assertGe(shares, quote, "minSharesOut floor held");
        assertGt(shares, 0);

        // The donated alpha is reflected in the rate (gift to holders), not recoverable by the donor.
        assertGt(token.exchangeRate(), 1e18, "donation lifted the rate for holders");
    }

    function test_roundingFavorsProtocol() public {
        // Establish a non-integer rate ONCE (rewards skew stake vs supply), then NO further rewards
        // during the loop — so any deviation is pure rounding, not yield. Jitter is sub-rao on purpose:
        // the refunded remainder must be excluded from totalIn.
        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        token.deposit{value: 100 ether}(0, MAX_DL);
        _staking().addReward(HOTKEY, _coldkey(), NETUID, 33 * 1e9); // ~1.33x

        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i = 1; i <= 100; i++) {
            uint256 amt = (i % 7 + 1) * 1e17 + i; // jittered, non-round, sub-rao tail
            vm.prank(alice);
            uint256 sh = token.deposit{value: amt}(0, MAX_DL);
            totalIn += amt - (amt % RAO); // the sub-rao tail is refunded, not deposited
            vm.prank(alice);
            uint256 out = token.redeem(sh, 0, MAX_DL);
            totalOut += out;
        }
        assertLe(totalOut, totalIn, "dust always accrues to the protocol, never the user");
    }

    function test_redeemDust_staysStaked_rateNonDecreasing() public {
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        token.deposit{value: 100 ether}(0, MAX_DL);
        _staking().addReward(HOTKEY, _coldkey(), NETUID, 33 * 1e9); // non-integer rate ~1.33

        uint256 rateBefore = token.exchangeRate();
        vm.prank(alice);
        token.redeem(1e9, 0, MAX_DL); // tiny redeem: alpha leg floors to whole rao
        assertGe(token.exchangeRate(), rateBefore, "floored dust stays staked for remaining holders");
    }

    // ================================================================
    // │           S4: post-call effect verification (both)           │
    // ================================================================

    function test_depositVerifiesAddStakeEffect() public {
        _staking().setBreakAddStake(true);
        vm.deal(alice, 10 ether);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(SzAlpha.AddStakeEffectMissing.selector);
        token.deposit{value: 5 ether}(0, MAX_DL);
        assertEq(alice.balance, balBefore, "tx reverted, TAO not lost");
    }

    function test_redeemVerifiesRemoveStakeEffect() public {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 5 ether}(0, MAX_DL);
        _staking().setBreakRemoveStake(true);
        vm.expectRevert(SzAlpha.RemoveStakeEffectMissing.selector);
        token.redeem(2 ether, 0, MAX_DL);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 5 ether, "shares intact, redeem atomic");
    }

    // ================================================================
    // │              S5: coldkey derived once at init                │
    // ================================================================

    function test_coldkeyImmutable() public {
        bytes32 before = token.wrapperColdkey();
        MockAddressMapping(ADDRESS_MAPPING).setFlipped(true);
        assertEq(token.wrapperColdkey(), before, "cached coldkey unchanged by a later mapping value");
    }

    // ================================================================
    // │              S1: UUPS upgrade authority                      │
    // ================================================================

    function test_upgradeRevertsIfNotTimelock() public {
        SzAlphaV2 v2 = new SzAlphaV2();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        token.upgradeToAndCall(address(v2), "");
    }

    function test_upgradePreservesStateForTimelock() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.deposit{value: 3 ether}(0, MAX_DL);

        SzAlphaV2 v2 = new SzAlphaV2();
        vm.prank(timelock);
        token.upgradeToAndCall(address(v2), "");

        assertEq(SzAlphaV2(payable(address(token))).version(), 2, "upgraded");
        assertEq(token.netuid(), NETUID, "netuid preserved (no slot collision)");
        assertEq(token.balanceOf(alice), 3 ether, "balances preserved");
    }

    function test_initRejectsNetuidOverUint16() public {
        SzAlpha impl = new SzAlpha();
        bytes memory initData = abi.encodeCall(
            SzAlpha.initialize,
            ("Staked xALPHA", "szALPHA", uint256(type(uint16).max) + 1, HOTKEY, timelock, ccipAdmin)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SzAlpha.NetuidTooLarge.selector, uint256(type(uint16).max) + 1)
        );
        new ERC1967Proxy(address(impl), initData);
    }

    // ================================================================
    // │              Zero / paused / reentrancy                      │
    // ================================================================

    function test_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.deposit{value: 0}(0, MAX_DL);
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.redeem(0, 0, MAX_DL);
    }

    function test_pauseBlocksDepositButNotRedeem() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.deposit{value: 5 ether}(0, MAX_DL);

        vm.prank(timelock);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.deposit{value: 1 ether}(0, MAX_DL);

        // S11: redeem works while paused.
        vm.prank(alice);
        uint256 out = token.redeem(2 ether, 0, MAX_DL);
        assertEq(out, 2 ether, "redeem available while paused");
    }

    function test_pauseOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        token.pause();
    }

    function test_reentrancyBlocked() public {
        ReentrantRedeemer attacker = new ReentrantRedeemer(token);
        vm.deal(address(attacker), 10 ether);
        attacker.doDeposit{value: 5 ether}();
        attacker.arm();
        // The reentrant redeem in receive() reverts; the outer native send fails -> redeem reverts.
        vm.expectRevert();
        attacker.doRedeem(2 ether);
    }

    // ================================================================
    // │   Lock/release topology: NO mint/burn surface on the token   │
    // ================================================================

    function test_token_hasNoMintBurnSurface() public {
        (bool ok1,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok1, "no CCT mint on the 964 token");
        (bool ok2,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok2, "no CCT burn");
        (bool ok3,) = address(token).call(abi.encodeWithSignature("grantMintAndBurnRoles(address)", alice));
        assertFalse(ok3, "no role-granting surface");
    }

    function test_ccipAdminTransferGated() public {
        vm.prank(alice);
        vm.expectRevert(SzAlpha.NotCcipAdmin.selector);
        token.setCCIPAdmin(alice);

        vm.prank(ccipAdmin);
        token.setCCIPAdmin(timelock);
        assertEq(token.getCCIPAdmin(), timelock);
    }

    // ================================================================
    // │   CCT lane via lock/release pool (mock router + RMN relay)   │
    // ================================================================

    /// @dev In production the onRamp transfers the tokens to the pool before calling lockOrBurn; the
    ///      tests replicate that transfer explicitly.
    function _fundPool(uint256 amount) internal {
        vm.deal(alice, amount + 1 ether);
        vm.startPrank(alice);
        token.deposit{value: amount}(0, MAX_DL);
        token.transfer(address(pool), amount);
        vm.stopPrank();
    }

    function _lockBurn(uint256 amount) internal {
        Pool.LockOrBurnInV1 memory inp = Pool.LockOrBurnInV1({
            receiver: abi.encode(bob),
            remoteChainSelector: REMOTE_SEL,
            originalSender: alice,
            amount: amount,
            localToken: address(token)
        });
        vm.prank(onRamp);
        pool.lockOrBurn(inp);
    }

    function _releaseMint(uint256 amount, bytes memory sourcePool) internal {
        Pool.ReleaseOrMintInV1 memory inp = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: REMOTE_SEL,
            receiver: bob,
            sourceDenominatedAmount: amount,
            localToken: address(token),
            sourcePoolAddress: sourcePool,
            sourcePoolData: abi.encode(uint8(18)),
            offchainTokenData: ""
        });
        vm.prank(offRamp);
        pool.releaseOrMint(inp);
    }

    function test_lane_lockOnSource_supplyAndRateInvariant() public {
        _fundPool(10 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 rateBefore = token.exchangeRate();

        _lockBurn(10 ether);

        // THE topology regression test: bridging out must not change supply, so the rate stays truthful.
        assertEq(token.totalSupply(), supplyBefore, "lock, not burn: totalSupply unchanged");
        assertEq(token.exchangeRate(), rateBefore, "exchangeRate invariant across bridge-out");
        assertEq(token.balanceOf(address(lockBox)), 10 ether, "bridged supply custodied in the lockbox");
        assertEq(token.balanceOf(address(pool)), 0, "pool holds nothing (lockbox custody)");
    }

    function test_lane_releaseOnDest_fromLockedLiquidity() public {
        _fundPool(10 ether);
        _lockBurn(10 ether);
        uint256 supplyBefore = token.totalSupply();

        _releaseMint(7 ether, abi.encode(remotePoolAddr));

        // 18==18 decimals -> exact conservation, no tolerance; released from custody, never minted.
        assertEq(token.balanceOf(bob), 7 ether, "release on return exact");
        assertEq(token.totalSupply(), supplyBefore, "release, not mint: totalSupply unchanged");
        assertEq(token.balanceOf(address(lockBox)), 3 ether, "remainder still locked");
    }

    function test_lane_roundTrip_rateInvariant() public {
        vm.deal(alice, 20 ether);
        vm.prank(alice);
        token.deposit{value: 10 ether}(0, MAX_DL);
        _staking().addReward(HOTKEY, _coldkey(), NETUID, 5 * 1e9); // non-trivial rate
        uint256 rateBefore = token.exchangeRate();

        vm.prank(alice);
        token.transfer(address(pool), 6 ether);
        _lockBurn(6 ether);
        assertEq(token.exchangeRate(), rateBefore, "rate invariant after lock");
        _releaseMint(6 ether, abi.encode(remotePoolAddr));
        assertEq(token.exchangeRate(), rateBefore, "rate invariant after full round-trip");
    }

    function test_lane_rmnCursedBlocks() public {
        _fundPool(1 ether);
        rmn.setCursed(true);
        Pool.LockOrBurnInV1 memory inp = Pool.LockOrBurnInV1({
            receiver: abi.encode(bob),
            remoteChainSelector: REMOTE_SEL,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(token)
        });
        vm.prank(onRamp);
        vm.expectRevert(abi.encodeWithSignature("CursedByRMN()"));
        pool.lockOrBurn(inp);
    }

    function test_lane_wrongSourcePoolReverts() public {
        _fundPool(1 ether);
        _lockBurn(1 ether);
        // A release claiming an unconfigured source pool must revert (CCT source-pool validation).
        vm.expectRevert();
        _releaseMint(1 ether, abi.encode(address(0xDEAD)));
    }

    function test_lane_rateLimiterCaps() public {
        // Tighten the outbound capacity via the rate-limit setter, then a transfer above it reverts.
        TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
        args[0] = TokenPool.RateLimitConfigArgs({
            remoteChainSelector: REMOTE_SEL,
            fastFinality: false,
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 3 ether, rate: 1}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 3 ether, rate: 1})
        });
        pool.setRateLimitConfig(args);

        _fundPool(10 ether);
        vm.expectRevert();
        _lockBurn(5 ether); // > 3 ether capacity
    }

    function test_lane_nonRampReverts() public {
        _fundPool(1 ether);
        Pool.LockOrBurnInV1 memory inp = Pool.LockOrBurnInV1({
            receiver: abi.encode(bob),
            remoteChainSelector: REMOTE_SEL,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(token)
        });
        vm.prank(alice); // not the onRamp
        vm.expectRevert();
        pool.lockOrBurn(inp);
    }

    // ================================================================
    // │              Pool constructor asserts (S8/S9)                │
    // ================================================================

    function test_lockReleasePoolRejectsNon18Decimals() public {
        Mock6DecimalToken t6 = new Mock6DecimalToken();
        ERC20LockBox box6 = new ERC20LockBox(address(t6));
        vm.expectRevert(abi.encodeWithSelector(SzAlphaLockReleasePool.LocalDecimalsNot18.selector, uint8(6)));
        new SzAlphaLockReleasePool(
            IERC20(address(t6)), 6, address(rmn), address(router), address(box6), address(rmn)
        );
    }

    function test_lockReleasePoolRejectsNonCanonicalRmn() public {
        address otherRmn = address(new MockRMN());
        vm.expectRevert(
            abi.encodeWithSelector(SzAlphaLockReleasePool.RmnNotCanonical.selector, address(rmn), otherRmn)
        );
        new SzAlphaLockReleasePool(
            IERC20(address(token)), 18, address(rmn), address(router), address(lockBox), otherRmn
        );
    }

    function test_lockReleasePoolGetters() public view {
        assertEq(address(pool.getToken()), address(token));
        assertEq(pool.getRmnProxy(), address(rmn));
        assertEq(pool.getLockBox(), address(lockBox), "custody wired to the lockbox");
        assertEq(pool.typeAndVersion(), "SzAlphaLockReleasePool 1.0.0");
    }

    function test_burnMintPoolAssertsStillHold_baseSide() public {
        // The Base-side pool class keeps its own S8/S9 guards (exercised here against the mocks).
        Mock6DecimalToken t6 = new Mock6DecimalToken();
        vm.expectRevert(abi.encodeWithSelector(SzAlphaTokenPool.LocalDecimalsNot18.selector, uint8(6)));
        new SzAlphaTokenPool(IBurnMintERC20(address(t6)), 6, address(rmn), address(router), address(rmn));
    }

    // ================================================================
    // │                 Base mirror (no stake surface)               │
    // ================================================================

    function test_mirror_decimalsAndNoStakeSurface() public {
        SzAlphaMirror mirror = new SzAlphaMirror("Staked xALPHA", "szALPHA");
        assertEq(mirror.decimals(), 18);

        // Zero staking / redeem / rate surface on Base (new two-arg/three-arg signatures included).
        (bool ok1,) = address(mirror).call(abi.encodeWithSignature("deposit(uint256,uint256)", 0, 0));
        assertFalse(ok1, "mirror has no deposit");
        (bool ok2,) = address(mirror).call(abi.encodeWithSignature("redeem(uint256,uint256,uint256)", 1, 0, 0));
        assertFalse(ok2, "mirror has no redeem");
        (bool ok3,) = address(mirror).staticcall(abi.encodeWithSignature("exchangeRate()"));
        assertFalse(ok3, "mirror has no exchangeRate");
    }

    function test_mirror_mintBurnGatedToPool() public {
        SzAlphaMirror mirror = new SzAlphaMirror("Staked xALPHA", "szALPHA");
        // Before granting, a random caller cannot mint.
        vm.prank(alice);
        vm.expectRevert();
        mirror.mint(alice, 1 ether);

        // Grant the pool role (this test contract is DEFAULT_ADMIN), then the pool mints.
        mirror.grantMintAndBurnRoles(address(this));
        mirror.mint(alice, 5 ether);
        assertEq(mirror.balanceOf(alice), 5 ether);
    }
}

/// @title Base-fork deploy integration — exercises the REAL Base CCT registry/registration against a live
///        Base mainnet fork (the 5-address asserts + registerAdminViaGetCCIPAdmin -> accept -> setPool).
/// @dev Runs whenever the `base` RPC endpoint is configured (BASE_RPC_URL); the 964 leg cannot be
///      fork-tested (no public Subtensor fork node) and is covered by the unit suite + documented.
contract SzAlphaBaseForkTest is Test {
    DeploySzAlphaBridge internal deployer;
    address internal timelock = makeAddr("timelock");

    function setUp() public {
        vm.createSelectFork("base");
        deployer = new DeploySzAlphaBridge();
    }

    function test_fork_deployBase_registersAgainstRealCct() public {
        (SzAlphaMirror mirror, SzAlphaTokenPool pool) = deployer.deployBase(timelock);

        assertEq(mirror.decimals(), 18, "mirror 18-dp");
        assertEq(pool.getRmnProxy(), deployer.baseConfig().armProxy, "canonical RMN wired");

        // The token is registered + linked to its pool on the REAL TokenAdminRegistry.
        (, address tar,,,,,,,) = _cfg();
        (bool ok, bytes memory ret) =
            tar.staticcall(abi.encodeWithSignature("getPool(address)", address(mirror)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(pool), "setPool landed on real registry");

        // Mirror admin handed to the timelock (deployer revoked).
        assertEq(mirror.getCCIPAdmin(), timelock, "ccipAdmin -> timelock");
        assertTrue(mirror.hasRole(mirror.DEFAULT_ADMIN_ROLE(), timelock), "admin -> timelock");
        assertFalse(mirror.hasRole(mirror.DEFAULT_ADMIN_ROLE(), address(deployer)), "deployer revoked");
    }

    function _cfg()
        internal
        view
        returns (uint64, address, address, address, address, string memory, string memory, string memory, string memory)
    {
        DeploySzAlphaBridge.CctConfig memory c = deployer.baseConfig();
        return (
            c.chainSelector,
            c.tokenAdminRegistry,
            c.router,
            c.registryModuleOwnerCustom,
            c.armProxy,
            c.expRouter,
            c.expTar,
            c.expReg,
            c.expFactory
        );
    }
}
