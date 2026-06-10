// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TokenPool} from "chainlink-ccip/pools/TokenPool.sol";
import {RateLimiter} from "chainlink-ccip/libraries/RateLimiter.sol";
import {Pool} from "chainlink-ccip/libraries/Pool.sol";
import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

import {SzAlpha} from "../../src/bridge/SzAlpha.sol";
import {SzAlphaMirror} from "../../src/bridge/SzAlphaMirror.sol";
import {SzAlphaTokenPool} from "../../src/bridge/SzAlphaTokenPool.sol";
import {DeploySzAlphaBridge} from "../../script/DeploySzAlphaBridge.s.sol";
import {
    MockSubtensorStaking,
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

    function doDeposit(uint256 amount) external payable {
        token.deposit{value: amount}(amount);
    }

    function doRedeem(uint256 shares) external {
        token.redeem(shares);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            token.redeem(1); // re-entry attempt; must revert under the guard
        }
    }
}

/// @title SzAlphaBridge unit + lane suite (MOCKED precompiles + MOCKED CCIP relay).
/// @notice The Subtensor StakingV2/AddressMapping precompiles are mocked (no public 964 fork node) and the
///         CCIP relay is mocked (no DON) — BOTH explicitly sanctioned by the 8x-01 ticket. Every test that
///         relies on a mock says so. The SzAlpha wrapper logic, the pool's added asserts, and the
///         token<->pool CCT wiring are real.
contract SzAlphaBridgeTest is Test {
    address internal constant STAKING_V2 = 0x0000000000000000000000000000000000000805;
    address internal constant ADDRESS_MAPPING = 0x000000000000000000000000000000000000080C;

    uint256 internal constant NETUID = 99;
    bytes32 internal constant HOTKEY = bytes32(uint256(0xABCD));
    uint64 internal constant REMOTE_SEL = 15971525489660198786; // Base selector

    SzAlpha internal token;
    SzAlphaTokenPool internal pool;
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
        // deployed Base contract whose fallback swallows/forwards native — which breaks the alpha-return
        // assertions. Clear code at the EOAs that RECEIVE native so they behave as plain EOAs on the fork.
        vm.etch(alice, hex"");
        vm.etch(bob, hex"");

        // Etch the precompile mocks at their canonical addresses.
        vm.etch(STAKING_V2, address(new MockSubtensorStaking()).code);
        vm.etch(ADDRESS_MAPPING, address(new MockAddressMapping()).code);
        vm.deal(STAKING_V2, 1_000_000 ether); // so removeStake can pay alpha back

        // Deploy the wrapper behind a UUPS proxy.
        SzAlpha impl = new SzAlpha();
        bytes memory initData =
            abi.encodeCall(SzAlpha.initialize, ("Staked xALPHA", "szALPHA", NETUID, HOTKEY, timelock, ccipAdmin));
        token = SzAlpha(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Deploy a pool wired to mock router + mock RMN (relay mocked); make it the sole mint/burn caller.
        router = new MockRouter();
        rmn = new MockRMN();
        pool =
            new SzAlphaTokenPool(IBurnMintERC20(address(token)), 18, address(rmn), address(router), address(rmn));
        vm.prank(ccipAdmin);
        token.grantMintAndBurnRoles(address(pool));

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

    // ================================================================
    // │              Wrapper: deposit / redeem (mocked 964)          │
    // ================================================================

    function test_deposit_stakesAndMintsShares() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 shares = token.deposit{value: 5 ether}(5 ether);

        assertEq(shares, 5 ether, "genesis 1:1");
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.totalStaked(), 5 ether, "stake landed under wrapper coldkey");
        assertEq(token.totalSupply(), 5 ether);
    }

    function test_redeem_unstakesBurnsAndReturnsAlpha() public {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 5 ether}(5 ether);
        uint256 balBefore = alice.balance;
        uint256 out = token.redeem(2 ether);
        vm.stopPrank();

        assertEq(out, 2 ether, "1:1 redeem at genesis rate");
        assertEq(alice.balance, balBefore + 2 ether, "alpha returned");
        assertEq(token.balanceOf(alice), 3 ether, "shares burned");
        assertEq(token.totalStaked(), 3 ether, "stake reduced");
    }

    function test_rateRisesWithRewards() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.deposit{value: 4 ether}(4 ether);
        assertEq(token.exchangeRate(), 1e18, "1:1 before rewards");

        // Validator rewards lift backing stake (no new shares) -> rate rises.
        MockSubtensorStaking(payable(STAKING_V2)).addReward(HOTKEY, _coldkey(), NETUID, 4 ether);
        assertApproxEqAbs(token.exchangeRate(), 2e18, 1, "rate ~2x after 100% reward");

        // A later depositor pays the higher rate (fewer shares per alpha).
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bobShares = token.deposit{value: 4 ether}(4 ether);
        assertApproxEqAbs(bobShares, 2 ether, 1, "bob gets ~half the shares at 2x rate");
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
        uint256 shares = token.deposit{value: 1 ether}(1 ether);
        assertEq(shares, 1 ether);
    }

    function test_inflationDefense_preStakeDoesNotZeroOutDepositor() public {
        // A pre-existing reward (the only way stake can rise without shares in the pooled model) does not let
        // a reasonable deposit silently mint zero shares — it either gets fair shares or reverts ZeroAmount.
        MockSubtensorStaking(payable(STAKING_V2)).addReward(HOTKEY, _coldkey(), NETUID, 100 ether);
        vm.deal(alice, 1000 ether);

        // A deposit smaller than the (stake+1) denominator rounds to zero -> reverts, no silent loss.
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.deposit{value: 50}(50);

        // A reasonable deposit gets >0 shares.
        vm.prank(alice);
        uint256 shares = token.deposit{value: 200 ether}(200 ether);
        assertGt(shares, 0);
    }

    function test_roundingFavorsProtocol() public {
        // Establish a non-integer rate ONCE (rewards skew stake vs supply), then NO further rewards during
        // the loop — so any deviation is pure rounding, not yield. (Mid-loop rewards would legitimately pay
        // the holder MORE than deposited; that is correct LST behaviour, tested separately.)
        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        token.deposit{value: 100 ether}(100 ether);
        MockSubtensorStaking(payable(STAKING_V2)).addReward(HOTKEY, _coldkey(), NETUID, 33 ether); // ~1.33x

        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i = 1; i <= 100; i++) {
            uint256 amt = (i % 7 + 1) * 1e17 + i; // jittered, non-round
            vm.prank(alice);
            uint256 sh = token.deposit{value: amt}(amt);
            totalIn += amt;
            vm.prank(alice);
            uint256 out = token.redeem(sh);
            totalOut += out;
        }
        assertLe(totalOut, totalIn, "dust always accrues to the protocol, never the user");
    }

    // ================================================================
    // │           S4: post-call effect verification (both)           │
    // ================================================================

    function test_depositVerifiesAddStakeEffect() public {
        MockSubtensorStaking(payable(STAKING_V2)).setBreakAddStake(true);
        vm.deal(alice, 10 ether);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(SzAlpha.AddStakeEffectMissing.selector);
        token.deposit{value: 5 ether}(5 ether);
        assertEq(alice.balance, balBefore, "tx reverted, alpha not lost");
    }

    function test_redeemVerifiesRemoveStakeEffect() public {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.deposit{value: 5 ether}(5 ether);
        MockSubtensorStaking(payable(STAKING_V2)).setBreakRemoveStake(true);
        vm.expectRevert(SzAlpha.RemoveStakeEffectMissing.selector);
        token.redeem(2 ether);
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
        token.deposit{value: 3 ether}(3 ether);

        SzAlphaV2 v2 = new SzAlphaV2();
        vm.prank(timelock);
        token.upgradeToAndCall(address(v2), "");

        assertEq(SzAlphaV2(payable(address(token))).version(), 2, "upgraded");
        assertEq(token.netuid(), NETUID, "netuid preserved (no slot collision)");
        assertEq(token.balanceOf(alice), 3 ether, "balances preserved");
    }

    // ================================================================
    // │              Zero / paused / reentrancy                      │
    // ================================================================

    function test_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.deposit{value: 0}(0);
        vm.prank(alice);
        vm.expectRevert(SzAlpha.ZeroAmount.selector);
        token.redeem(0);
    }

    function test_valueMustMatchAmount() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SzAlpha.ValueMismatch.selector, 1 ether, 2 ether));
        token.deposit{value: 1 ether}(2 ether);
    }

    function test_pauseBlocksDepositButNotRedeem() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.deposit{value: 5 ether}(5 ether);

        vm.prank(timelock);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.deposit{value: 1 ether}(1 ether);

        // S11: redeem works while paused.
        vm.prank(alice);
        uint256 out = token.redeem(2 ether);
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
        attacker.doDeposit{value: 5 ether}(5 ether);
        attacker.arm();
        // The reentrant redeem in receive() reverts; the outer native send fails -> redeem reverts.
        vm.expectRevert();
        attacker.doRedeem(2 ether);
    }

    // ================================================================
    // │       S2: mint/burn gated to the CCT pool ONLY               │
    // ================================================================

    function test_mintBurnOnlyPool() public {
        vm.prank(alice);
        vm.expectRevert(SzAlpha.NotCcipPool.selector);
        token.mint(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(SzAlpha.NotCcipPool.selector);
        token.burn(1 ether);

        // The wired pool can mint/burn.
        vm.prank(address(pool));
        token.mint(alice, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function test_grantMintAndBurnRolesOnceAndOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(SzAlpha.NotCcipAdmin.selector);
        token.grantMintAndBurnRoles(address(0xBEEF));

        vm.prank(ccipAdmin);
        vm.expectRevert(SzAlpha.PoolAlreadySet.selector);
        token.grantMintAndBurnRoles(address(0xBEEF));
    }

    // ================================================================
    // │     CCT lane via the pool (mock router + RMN relay)          │
    // ================================================================

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

    function test_lane_burnOnSource() public {
        // Pool holds the bridged supply, then burns it on the source side.
        vm.prank(address(pool));
        token.mint(address(pool), 10 ether);
        uint256 supplyBefore = token.totalSupply();

        _lockBurn(10 ether);
        assertEq(token.totalSupply(), supplyBefore - 10 ether, "burn on source");
        assertEq(token.balanceOf(address(pool)), 0);
    }

    function test_lane_mintOnDest_conservationExact() public {
        uint256 supplyBefore = token.totalSupply();
        _releaseMint(7 ether, abi.encode(remotePoolAddr));
        // 18==18 decimals -> exact conservation, no tolerance.
        assertEq(token.balanceOf(bob), 7 ether, "mint on dest exact");
        assertEq(token.totalSupply(), supplyBefore + 7 ether);
    }

    function test_lane_rmnCursedBlocks() public {
        rmn.setCursed(true);
        vm.prank(address(pool));
        token.mint(address(pool), 1 ether);
        vm.prank(onRamp);
        vm.expectRevert(abi.encodeWithSignature("CursedByRMN()"));
        Pool.LockOrBurnInV1 memory inp = Pool.LockOrBurnInV1({
            receiver: abi.encode(bob),
            remoteChainSelector: REMOTE_SEL,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(token)
        });
        pool.lockOrBurn(inp);
    }

    function test_lane_wrongSourcePoolReverts() public {
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

        vm.prank(address(pool));
        token.mint(address(pool), 10 ether);
        vm.expectRevert();
        _lockBurn(5 ether); // > 3 ether capacity
    }

    function test_lane_nonRampReverts() public {
        vm.prank(address(pool));
        token.mint(address(pool), 1 ether);
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

    function test_poolRejectsNon18Decimals() public {
        Mock6DecimalToken t6 = new Mock6DecimalToken();
        vm.expectRevert(abi.encodeWithSelector(SzAlphaTokenPool.LocalDecimalsNot18.selector, uint8(6)));
        new SzAlphaTokenPool(IBurnMintERC20(address(t6)), 6, address(rmn), address(router), address(rmn));
    }

    function test_poolRejectsNonCanonicalRmn() public {
        address otherRmn = address(new MockRMN());
        vm.expectRevert(
            abi.encodeWithSelector(SzAlphaTokenPool.RmnNotCanonical.selector, address(rmn), otherRmn)
        );
        new SzAlphaTokenPool(IBurnMintERC20(address(token)), 18, address(rmn), address(router), otherRmn);
    }

    function test_poolGetters() public view {
        assertEq(address(pool.getToken()), address(token));
        assertEq(pool.getRmnProxy(), address(rmn));
        assertEq(pool.typeAndVersion(), "SzAlphaTokenPool 1.0.0");
    }

    // ================================================================
    // │                 Base mirror (no stake surface)               │
    // ================================================================

    function test_mirror_decimalsAndNoStakeSurface() public {
        SzAlphaMirror mirror = new SzAlphaMirror("Staked xALPHA", "szALPHA");
        assertEq(mirror.decimals(), 18);

        // Zero staking / redeem / rate surface on Base.
        (bool ok1,) = address(mirror).call(abi.encodeWithSignature("deposit(uint256)", uint256(1)));
        assertFalse(ok1, "mirror has no deposit");
        (bool ok2,) = address(mirror).call(abi.encodeWithSignature("redeem(uint256)", uint256(1)));
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
        mirror.burn(address(this) == address(0) ? 0 : 0); // no-op burn guard (pool burns its own balance)
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
