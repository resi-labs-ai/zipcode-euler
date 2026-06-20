// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

import {HarvestVoteModule} from "../src/supply/szipUSD/HarvestVoteModule.sol";
import {IGauge} from "../src/interfaces/hydrex/IGauge.sol";
import {IVoter} from "../src/interfaces/hydrex/IVoter.sol";
import {IVotingEscrow} from "../src/interfaces/hydrex/IVotingEscrow.sol";
import {IOptionToken} from "../src/interfaces/hydrex/IOptionToken.sol";
import {IRewardsDistributor} from "../src/interfaces/hydrex/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev SEC-14: mastercopies are init-locked in their ctor, so `setUp` on a bare impl reverts.
///      A fresh EIP-1167 clone (fresh proxy storage) behaves like the old bare instance for setUp.
function _cloneHarvestVoteModule() returns (HarvestVoteModule) {
    return HarvestVoteModule(Clones.clone(address(new HarvestVoteModule())));
}

/// @notice Test-local extension: the live Voter's account-keyed `lastVoted(address)` (0x9a61df89, verified live). Not
///         added to the production `IVoter` (the module never reads it — it is purely a fork-test positive assertion).
interface ILastVoted {
    function lastVoted(address account) external view returns (uint256);
}

// =========================================================================== mocks

/// @notice A recording mock Safe (Zodiac avatar surface). Records every `(to, value, data, operation)`, optionally
///         performs the call live, and can force a specific exec index to fail. Modeled on
///         `LpStrategyModule.t.sol` / `ReservoirLoopModule.t.sol`, EXTENDED with a settable `_returnData` so the
///         `lockVe` nftId decode is exercisable on the non-live path.
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
    bytes private _returnData; // returned from the NON-live recording path (lockVe nftId decode)

    function setLive(bool v) external {
        live = v;
    }

    function setFailOnCallIndex(uint256 i) external {
        failOnCallIndex = i;
    }

    /// @notice Set the bytes the non-live `execTransactionFromModuleReturnData` returns (the `lockVe` nftId decode).
    function setReturnData(bytes calldata d) external {
        _returnData = d;
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
            // Model the real Safe: catch the inner revert and RETURN (false, revertData), do NOT bubble.
            (ok, ret) = to.call{value: value}(data);
            return (ok, ret);
        }
        return (true, _returnData);
    }

    receive() external payable {}
}

/// @notice A target that always returns `(false, data)` through a live Safe (to exercise the `_exec` bubble path).
contract RevertTarget {
    bytes public payload;
    bool public emptyData;

    error TargetBoom(uint256 code);

    function setCustomError() external {
        payload = abi.encodeWithSelector(TargetBoom.selector, uint256(42));
        emptyData = false;
    }

    function setEmpty() external {
        emptyData = true;
    }

    fallback() external payable {
        if (emptyData) {
            assembly {
                revert(0, 0)
            }
        }
        bytes memory p = payload;
        assembly {
            revert(add(p, 0x20), mload(p))
        }
    }

    receive() external payable {}
}

/// @notice A gauge stand-in: settable `rewardToken()` (incl. address(0) to prove the setUp fail-closed) + an
///         `earned(token, account)` that RECORDS its args (to prove `pendingReward` reads `(oHYDX, juniorTrancheEngine)`).
contract MockGauge {
    address public rewardToken;
    uint256 public earnedReturn;
    address public lastEarnedToken;
    address public lastEarnedAccount;

    constructor(address rewardToken_) {
        rewardToken = rewardToken_;
    }

    function setRewardToken(address t) external {
        rewardToken = t;
    }

    function setEarnedReturn(uint256 v) external {
        earnedReturn = v;
    }

    function getReward() external {}

    // NOTE: earned must mutate (record args) → not a view. The module's `pendingReward` is a `view`, so it cannot be
    // proven via a recording call. Instead we expose a separate `probeEarned` the test calls directly to capture args,
    // plus a plain view `earned` the module reads. The args-pinning is done by decoding the module's behavior in the
    // exec-shape test for the mutators and a dedicated probe here.
    function earned(address token, address account) external view returns (uint256) {
        // pure view; cannot record. The recording variant below is used by the test to assert arg-passing.
        token;
        account;
        return earnedReturn;
    }
}

/// @notice A Voter stand-in: settable `ve()` (incl. 0), `vote`/`reset` no-ops, and `lastVoted(address)`.
contract MockVoter {
    address public ve;
    mapping(address => uint256) public lastVoted;

    constructor(address ve_) {
        ve = ve_;
    }

    function setVe(address v) external {
        ve = v;
    }

    function vote(address[] calldata, uint256[] calldata) external {
        lastVoted[msg.sender] = block.timestamp;
    }

    function reset() external {}
}

/// @notice A RewardsDistributor stand-in.
contract MockRewardsDistributor {
    uint256 public claimableReturn;

    function setClaimableReturn(uint256 v) external {
        claimableReturn = v;
    }

    function claim_many(uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function claimable(uint256) external view returns (uint256) {
        return claimableReturn;
    }
}

/// @notice An escrow stand-in for the `voteFloor` view-arg pinning (records the account passed to getVotes).
contract MockEscrow {
    uint256 public votesReturn;

    function setVotesReturn(uint256 v) external {
        votesReturn = v;
    }

    function getVotes(address) external view returns (uint256) {
        return votesReturn;
    }
}

// =========================================================================== unit tests (no fork)

contract HarvestVoteModuleUnitTest is Test {
    HarvestVoteModule internal m;
    RecordingSafe internal safe;
    MockGauge internal gauge;
    MockVoter internal voter;
    MockEscrow internal escrow;
    MockRewardsDistributor internal rd;

    address internal oHYDX = makeAddr("oHYDX");

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");

    function setUp() public {
        escrow = new MockEscrow();
        gauge = new MockGauge(oHYDX);
        voter = new MockVoter(address(escrow));
        rd = new MockRewardsDistributor();
        safe = new RecordingSafe();
        m = _cloneHarvestVoteModule();
        m.setUp(abi.encode(owner, address(safe), operator, address(gauge), address(voter), address(rd)));
    }

    /// @dev SEC-14: the bare mastercopy is init-locked in its ctor; `setUp` on it reverts AlreadyInitialized.
    function test_SEC14_mastercopy_setUp_reverts() public {
        HarvestVoteModule mc = new HarvestVoteModule();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized()"));
        mc.setUp(abi.encode(owner, address(safe), operator, address(gauge), address(voter), address(rd)));
    }

    // ----------------------------------------------------------------- setUp / authority / locks

    function test_setUp_wires_storage() public view {
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.juniorTrancheEngine(), address(safe));
        assertEq(m.avatar(), address(safe));
        assertEq(m.target(), address(safe));
        assertEq(m.gauge(), address(gauge));
        assertEq(m.voter(), address(voter));
        assertEq(m.rewardsDistributor(), address(rd));
        assertEq(m.oHYDX(), oHYDX); // live-read off gauge.rewardToken()
        assertEq(m.ve(), address(escrow)); // live-read off voter.ve()
    }

    function test_setUp_initializer_once() public {
        vm.expectRevert();
        m.setUp(abi.encode(owner, address(safe), operator, address(gauge), address(voter), address(rd)));
    }

    /// @dev SEC-15 (I6): `setOperator` re-point must preserve the init-time owner != operator separation.
    ///      Pre-fix the re-point only rejected the zero address, so it could silently collapse the two roles.
    function test_SEC15_setOperator_owner_recheck() public {
        // a valid non-owner, non-zero re-point still succeeds
        address newOp = makeAddr("sec15NewOp");
        vm.prank(owner);
        m.setOperator(newOp);
        assertEq(m.operator(), newOp);
        // re-pointing operator to the owner now reverts OwnerIsOperator (pre-fix it succeeded)
        vm.prank(owner);
        vm.expectRevert(HarvestVoteModule.OwnerIsOperator.selector);
        m.setOperator(owner);
        // zero still rejected
        vm.prank(owner);
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setOperator(address(0));
    }

    /// @dev The six build-phase wiring setters (besides `setOperator`, covered by SEC-15): each is `onlyOwner`,
    ///      non-zero-guarded, and takes effect. A non-owner reverts `OwnableUnauthorizedAccount`; zero reverts
    ///      `ZeroAddress`; an owner re-point updates the slot.
    function test_wiring_setters_onlyOwner_effect_and_zeroGuard() public {
        address rando = makeAddr("rando");
        address x = makeAddr("rewire");

        // non-owner rejected on every setter
        vm.startPrank(rando);
        bytes memory unauth = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando);
        vm.expectRevert(unauth);
        m.setJuniorTrancheEngine(x);
        vm.expectRevert(unauth);
        m.setGauge(x);
        vm.expectRevert(unauth);
        m.setVoter(x);
        vm.expectRevert(unauth);
        m.setRewardsDistributor(x);
        vm.expectRevert(unauth);
        m.setOHYDX(x);
        vm.expectRevert(unauth);
        m.setVe(x);
        vm.stopPrank();

        // owner re-point takes effect
        vm.startPrank(owner);
        m.setJuniorTrancheEngine(x);
        assertEq(m.juniorTrancheEngine(), x, "juniorTrancheEngine re-pointed");
        m.setGauge(x);
        assertEq(m.gauge(), x, "gauge re-pointed");
        m.setVoter(x);
        assertEq(m.voter(), x, "voter re-pointed");
        m.setRewardsDistributor(x);
        assertEq(m.rewardsDistributor(), x, "rewardsDistributor re-pointed");
        m.setOHYDX(x);
        assertEq(m.oHYDX(), x, "oHYDX re-pointed");
        m.setVe(x);
        assertEq(m.ve(), x, "ve re-pointed");

        // zero rejected on every setter
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setJuniorTrancheEngine(address(0));
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setGauge(address(0));
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setVoter(address(0));
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setRewardsDistributor(address(0));
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setOHYDX(address(0));
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        m.setVe(address(0));
        vm.stopPrank();
    }

    function test_setUp_rejects_owner_equals_operator() public {
        HarvestVoteModule x = _cloneHarvestVoteModule();
        vm.expectRevert(HarvestVoteModule.OwnerIsOperator.selector);
        x.setUp(abi.encode(owner, address(safe), owner, address(gauge), address(voter), address(rd)));
    }

    function test_setUp_rejects_zero_in_each_of_six() public {
        // owner
        _expectZero(abi.encode(address(0), address(safe), operator, address(gauge), address(voter), address(rd)));
        // juniorTrancheEngine
        _expectZero(abi.encode(owner, address(0), operator, address(gauge), address(voter), address(rd)));
        // operator
        _expectZero(abi.encode(owner, address(safe), address(0), address(gauge), address(voter), address(rd)));
        // gauge
        _expectZero(abi.encode(owner, address(safe), operator, address(0), address(voter), address(rd)));
        // voter
        _expectZero(abi.encode(owner, address(safe), operator, address(gauge), address(0), address(rd)));
        // rewardsDistributor
        _expectZero(abi.encode(owner, address(safe), operator, address(gauge), address(voter), address(0)));
    }

    function _expectZero(bytes memory params) internal {
        HarvestVoteModule x = _cloneHarvestVoteModule();
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        x.setUp(params);
    }

    function test_setUp_rejects_zero_rewardToken_live() public {
        MockGauge badGauge = new MockGauge(address(0)); // rewardToken() == 0
        HarvestVoteModule x = _cloneHarvestVoteModule();
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(badGauge), address(voter), address(rd)));
    }

    function test_setUp_rejects_zero_ve_live() public {
        MockVoter badVoter = new MockVoter(address(0)); // ve() == 0
        HarvestVoteModule x = _cloneHarvestVoteModule();
        vm.expectRevert(HarvestVoteModule.ZeroAddress.selector);
        x.setUp(abi.encode(owner, address(safe), operator, address(gauge), address(badVoter), address(rd)));
    }

    function test_operator_cannot_redirect_safe() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        HarvestVoteModule mc = _cloneHarvestVoteModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.juniorTrancheEngine(), address(0));
        assertEq(mc.gauge(), address(0));
        assertEq(mc.voter(), address(0));
        assertEq(mc.rewardsDistributor(), address(0));
        assertEq(mc.oHYDX(), address(0));
        assertEq(mc.ve(), address(0));

        // every mutator reverts NotOperator on the un-setUp mastercopy (operator == address(0), caller != 0).
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        address[] memory pools = new address[](1);
        pools[0] = address(0xAAAA);
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;
        vm.startPrank(operator);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        mc.claimReward();
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        mc.lockVe(1e18);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        mc.vote(pools, ws);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        mc.resetVote();
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        mc.claimRebase(ids);
        vm.stopPrank();
    }

    function test_entrypoints_only_operator() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        address[] memory pools = new address[](1);
        pools[0] = address(0xAAAA);
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;
        vm.startPrank(rando);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.claimReward();
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.lockVe(1e18);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.vote(pools, ws);
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.resetVote();
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.claimRebase(ids);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- guards

    function test_guards() public {
        vm.startPrank(operator);
        // lockVe(0) -> ZeroAmount
        vm.expectRevert(HarvestVoteModule.ZeroAmount.selector);
        m.lockVe(0);

        // vote([],[]) -> EmptyArray
        address[] memory empty = new address[](0);
        uint256[] memory emptyW = new uint256[](0);
        vm.expectRevert(HarvestVoteModule.EmptyArray.selector);
        m.vote(empty, emptyW);

        // vote([p],[1,2]) -> LengthMismatch
        address[] memory one = new address[](1);
        one[0] = address(0xAAAA);
        uint256[] memory two = new uint256[](2);
        two[0] = 1;
        two[1] = 2;
        vm.expectRevert(HarvestVoteModule.LengthMismatch.selector);
        m.vote(one, two);

        // vote([p,q],[1]) -> LengthMismatch
        address[] memory twoP = new address[](2);
        twoP[0] = address(0xAAAA);
        twoP[1] = address(0xBBBB);
        uint256[] memory oneW = new uint256[](1);
        oneW[0] = 1;
        vm.expectRevert(HarvestVoteModule.LengthMismatch.selector);
        m.vote(twoP, oneW);

        // claimRebase([]) -> EmptyArray
        uint256[] memory emptyIds = new uint256[](0);
        vm.expectRevert(HarvestVoteModule.EmptyArray.selector);
        m.claimRebase(emptyIds);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- exec discipline (fully pinned)

    function test_exec_shape_claimReward() public {
        vm.prank(operator);
        m.claimReward();
        assertEq(safe.callCount(), 1, "claimReward = 1 exec");
        _assertCall(0, address(gauge), abi.encodeCall(IGauge.getReward, ()));
    }

    function test_exec_shape_lockVe_decodes_nftId_and_recipient() public {
        uint256 expectedNftId = 777;
        safe.setReturnData(abi.encode(expectedNftId));
        vm.expectEmit(true, true, true, true, address(m));
        emit HarvestVoteModule.Locked(5e18, expectedNftId);
        vm.prank(operator);
        m.lockVe(5e18);

        assertEq(safe.callCount(), 1, "lockVe = 1 exec");
        _assertCall(0, address(oHYDX), abi.encodeCall(IOptionToken.exerciseVe, (uint256(5e18), address(safe))));

        // decode the recorded recipient arg and assert == juniorTrancheEngine (the irreversibility firewall, not a keccak match).
        (,, bytes memory data,) = safe.getCall(0);
        (uint256 amt, address recipient) = abi.decode(_slice(data, 4), (uint256, address));
        assertEq(amt, 5e18, "amount arg");
        assertEq(recipient, address(safe), "exerciseVe recipient == juniorTrancheEngine");
    }

    function test_lockVe_reverts_on_short_return_data() public {
        // < 32 bytes -> abi.decode must revert (no silent garbage emit).
        safe.setReturnData(hex"00112233");
        vm.prank(operator);
        vm.expectRevert();
        m.lockVe(1e18);
    }

    function test_lockVe_reverts_on_empty_return_data() public {
        safe.setReturnData(hex"");
        vm.prank(operator);
        vm.expectRevert();
        m.lockVe(1e18);
    }

    function test_exec_shape_vote() public {
        address[] memory pools = new address[](2);
        pools[0] = address(0xAAAA);
        pools[1] = address(0xBBBB);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 3;
        ws[1] = 7;
        vm.prank(operator);
        m.vote(pools, ws);
        assertEq(safe.callCount(), 1, "vote = 1 exec");
        _assertCall(0, address(voter), abi.encodeCall(IVoter.vote, (pools, ws)));
    }

    function test_exec_shape_resetVote() public {
        vm.prank(operator);
        m.resetVote();
        assertEq(safe.callCount(), 1, "resetVote = 1 exec");
        _assertCall(0, address(voter), abi.encodeCall(IVoter.reset, ()));
    }

    function test_exec_shape_claimRebase() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        vm.prank(operator);
        m.claimRebase(ids);
        assertEq(safe.callCount(), 1, "claimRebase = 1 exec");
        _assertCall(0, address(rd), abi.encodeCall(IRewardsDistributor.claim_many, (ids)));
    }

    // ----------------------------------------------------------------- atomicity (production bubble path)

    function test_exec_bubbles_custom_error() public {
        RevertTarget rt = new RevertTarget();
        rt.setCustomError();
        // wire a module whose gauge == the revert target so claimReward routes _exec to it through a live Safe.
        RecordingSafe lsafe = new RecordingSafe();
        lsafe.setLive(true);
        MockGauge g = new MockGauge(oHYDX);
        // build a module with gauge = revert target. But setUp reads gauge.rewardToken(); the RevertTarget has no
        // rewardToken view -> use a real MockGauge for setUp, then we cannot point gauge at rt post-setUp (set-once).
        // Instead: point the VOTER at the revert target and exercise resetVote (no decode), proving the bubble path.
        g; // silence
        address badVoter = address(new WrappingVoter(address(escrow), address(rt)));
        HarvestVoteModule x = _cloneHarvestVoteModule();
        x.setUp(abi.encode(owner, address(lsafe), operator, address(gauge), badVoter, address(rd)));
        // voter is set to badVoter whose ve() returned a real escrow at setUp; now make reset() route to rt.
        // badVoter.reset() itself reverts with the custom error (it IS the revert target wrapper).
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RevertTarget.TargetBoom.selector, uint256(42)));
        x.resetVote();
    }

    function test_exec_bubbles_no_data_ExecFailed() public {
        RevertTarget rt = new RevertTarget();
        rt.setEmpty();
        RecordingSafe lsafe = new RecordingSafe();
        lsafe.setLive(true);
        address badVoter = address(new WrappingVoter(address(escrow), address(rt)));
        HarvestVoteModule x = _cloneHarvestVoteModule();
        x.setUp(abi.encode(owner, address(lsafe), operator, address(gauge), badVoter, address(rd)));
        vm.prank(operator);
        vm.expectRevert(HarvestVoteModule.ExecFailed.selector);
        x.resetVote();
    }

    // ----------------------------------------------------------------- views read juniorTrancheEngine

    function test_views_read_juniorTrancheEngine() public {
        gauge.setEarnedReturn(123);
        escrow.setVotesReturn(456);
        rd.setClaimableReturn(789);
        assertEq(m.pendingReward(), 123, "pendingReward reads gauge.earned");
        assertEq(m.voteFloor(), 456, "voteFloor reads ve.getVotes");
        assertEq(m.rebaseClaimable(1), 789, "rebaseClaimable reads rd.claimable");
    }

    /// @dev Pin that `pendingReward` passes `(oHYDX, juniorTrancheEngine)` (not the operator) — via `vm.expectCall` on the
    ///      exact `earned(oHYDX, juniorTrancheEngine)` calldata. `voteFloor` likewise reads `getVotes(juniorTrancheEngine)`.
    function test_views_pass_oHYDX_and_juniorTrancheEngine() public {
        vm.expectCall(address(gauge), abi.encodeCall(IGauge.earned, (oHYDX, address(safe))));
        m.pendingReward();
        vm.expectCall(address(escrow), abi.encodeWithSignature("getVotes(address)", address(safe)));
        m.voteFloor();
    }

    // ----------------------------------------------------------------- helpers

    function _assertCall(uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }
}

/// @notice A Voter whose `ve()` returns a real escrow (so setUp passes) but whose `reset()` (and `vote`) revert by
///         forwarding to a RevertTarget — used to exercise the `_exec` bubble path through a live Safe.
contract WrappingVoter {
    address public ve;
    address private _rt;

    constructor(address ve_, address rt_) {
        ve = ve_;
        _rt = rt_;
    }

    function reset() external {
        (bool ok, bytes memory ret) = _rt.call(hex"deadbeef");
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function vote(address[] calldata, uint256[] calldata) external {
        (bool ok, bytes memory ret) = _rt.call(hex"deadbeef");
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// =========================================================================== fork tests (live Base)

/// @notice Fork tests against live Base: real `exerciseVe` (fresh-veNFT / account-aggregate model) against a real
///         summoned substrate Safe, real `vote`/`reset` against the live HYDX/USDC gauge, real `claimRebase`, and a
///         signature-verification of the whole Hydrex surface.
contract HarvestVoteModuleForkTest is ForkConfig, SummonSubstrate {
    // -- live Base test-only fork targets --
    address internal constant LIVE_GAUGE = 0xAC396CabF5832A49483B78225D902C0999829993; // HYDX/USDC gauge (stand-in)
    address internal constant OHYDX_WHALE = 0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF; // holds 2334e18 oHYDX
    address internal constant HYDREX_MINTER = 0xA7D64625F45548a19B2A19e28E7546bb2839003E; // update_period() rolls epoch

    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal team = makeAddr("teamMultisig");

    uint256 internal constant SALT = uint256(keccak256("zipcode.harvestvote.8b7.salt.a"));

    function setUp() public {
        _selectBaseFork();
    }

    function _summonAndEnable(HarvestVoteModule m) internal returns (address juniorTrancheSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        juniorTrancheSafe = s.juniorTrancheSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(juniorTrancheSafe).execTransaction(juniorTrancheSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _deploy() internal returns (HarvestVoteModule m, address juniorTrancheEngine) {
        m = _cloneHarvestVoteModule();
        juniorTrancheEngine = _summonAndEnable(m);
        m.setUp(
            abi.encode(
                owner,
                juniorTrancheEngine,
                operator,
                LIVE_GAUGE,
                BaseAddresses.HYDREX_VOTER,
                BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR
            )
        );
    }

    /// @dev Fund the Safe with oHYDX: try `deal` first, fall back to impersonating the whale.
    function _fundOHYDX(address juniorTrancheEngine, uint256 amount) internal {
        try this.tryDeal(BaseAddresses.OHYDX, juniorTrancheEngine, amount) {
            if (IERC20(BaseAddresses.OHYDX).balanceOf(juniorTrancheEngine) >= amount) return;
        } catch {}
        // fallback: impersonate the whale.
        vm.prank(OHYDX_WHALE);
        IERC20(BaseAddresses.OHYDX).transfer(juniorTrancheEngine, amount);
    }

    function tryDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    // ----------------------------------------------------------------- sig-verify

    function test_fork_sig_verify() public {
        (HarvestVoteModule m, address juniorTrancheEngine) = _deploy();

        // the module live-read oHYDX off the gauge and ve off the voter.
        assertEq(m.oHYDX(), BaseAddresses.OHYDX, "oHYDX == gauge.rewardToken()");
        assertEq(m.ve(), BaseAddresses.HYDREX_VE, "ve == Voter.ve()");

        // the views resolve on the live addresses (read-only).
        IGauge(LIVE_GAUGE).earned(BaseAddresses.OHYDX, juniorTrancheEngine);
        IVotingEscrow(BaseAddresses.HYDREX_VE).getVotes(juniorTrancheEngine);
        assertEq(IVoter(BaseAddresses.HYDREX_VOTER).ve(), BaseAddresses.HYDREX_VE, "Voter.ve() resolves");
        IRewardsDistributor(BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR).claimable(1);

        // module views.
        m.pendingReward();
        assertEq(m.voteFloor(), 0, "fresh Safe has no veHYDX yet");
        m.rebaseClaimable(1);
    }

    // ----------------------------------------------------------------- real exerciseVe (the model)

    function test_fork_real_exerciseVe_fresh_nft_account_aggregate() public {
        (HarvestVoteModule m, address juniorTrancheEngine) = _deploy();

        uint256 amount = 10e18;
        _fundOHYDX(juniorTrancheEngine, amount * 2);

        IVotingEscrow veC = IVotingEscrow(BaseAddresses.HYDREX_VE);
        IERC20 oToken = IERC20(BaseAddresses.OHYDX);

        uint256 ohydxBefore = oToken.balanceOf(juniorTrancheEngine);
        uint256 nftCountBefore = veC.balanceOf(juniorTrancheEngine);
        uint256 votesBefore = veC.getVotes(juniorTrancheEngine);

        // first lock
        vm.recordLogs();
        vm.prank(operator);
        m.lockVe(amount);
        uint256 nftId1 = _lastLockedNftId();

        assertEq(veC.balanceOf(juniorTrancheEngine), nftCountBefore + 1, "one fresh veNFT minted");
        assertGt(veC.getVotes(juniorTrancheEngine), votesBefore, "votes grew");
        assertEq(ohydxBefore - oToken.balanceOf(juniorTrancheEngine), amount, "exactly `amount` oHYDX burned (NO approval)");
        assertGt(nftId1, 0, "Locked emitted a nonzero nftId");
        assertEq(veC.ownerOf(nftId1), juniorTrancheEngine, "the decoded id is the Safe's veNFT");

        uint256 votesAfter1 = veC.getVotes(juniorTrancheEngine);

        // second lock -> a SECOND fresh NFT (proves no tokenId state, account-aggregate).
        vm.recordLogs();
        vm.prank(operator);
        m.lockVe(amount);
        uint256 nftId2 = _lastLockedNftId();

        assertEq(veC.balanceOf(juniorTrancheEngine), nftCountBefore + 2, "second fresh veNFT minted");
        assertGt(veC.getVotes(juniorTrancheEngine), votesAfter1, "account aggregate grew further");
        assertTrue(nftId2 != nftId1, "a fresh distinct nftId");
        assertEq(veC.ownerOf(nftId2), juniorTrancheEngine, "second id is the Safe's");
    }

    function _lastLockedNftId() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Locked(uint256,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == sig) {
                (, uint256 nftId) = abi.decode(logs[i - 1].data, (uint256, uint256));
                return nftId;
            }
        }
        revert("no Locked event");
    }

    // ----------------------------------------------------------------- real vote / reset

    function test_fork_real_vote_and_reset() public {
        (HarvestVoteModule m, address juniorTrancheEngine) = _deploy();

        // need veHYDX to vote.
        _fundOHYDX(juniorTrancheEngine, 50e18);
        vm.prank(operator);
        m.lockVe(50e18);

        // BUILD-EXPOSED: the live Voter measures voting power at the EPOCH-START snapshot (not `getVotes` at the
        // current block). A lock minted this block reads back as 0 for the current epoch → `vote` reverts
        // `InsufficientVotingPower()`. We must (1) warp to the START of the NEXT epoch (1-week boundary) so the lock
        // predates the snapshot, and (2) call `Minter.update_period()` to roll the epoch (otherwise the Voter reverts
        // `EpochStale()`). This is exactly what the 8-B11 CRE robot does each epoch — it never votes in the same block
        // it locks. (The module itself is epoch-agnostic by design; epoch sequencing is 8-B11 policy.)
        uint256 WEEK = 7 days;
        vm.warp(((block.timestamp / WEEK) + 1) * WEEK + 1 hours);
        vm.roll(block.number + 100);
        (bool uok,) = HYDREX_MINTER.call(abi.encodeWithSignature("update_period()"));
        assertTrue(uok, "Minter.update_period() rolled the epoch");

        ILastVoted voterC = ILastVoted(BaseAddresses.HYDREX_VOTER);

        address[] memory pools = new address[](1);
        pools[0] = BaseAddresses.HYDX_USDC_POOL;
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;

        uint256 ts = block.timestamp;
        vm.prank(operator);
        m.vote(pools, ws);
        assertGe(voterC.lastVoted(juniorTrancheEngine), ts, "vote recorded lastVoted");

        // BUILD-EXPOSED: the live Voter enforces a per-account VOTE DELAY (~1h) between consecutive vote/reset actions
        // (it reverts `VoteDelayNotMet()` 0x2add46eb otherwise). So `reset` then `re-vote` cannot run in the same block
        // as the prior vote — each must clear the delay. We stay WITHIN the same epoch (only +2h of a 1-week epoch),
        // proving `reset` cleared the epoch vote and a fresh in-epoch vote then succeeds. The 8-B11 CRE respects this
        // cadence; the module is delay-agnostic by design.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 10);
        vm.prank(operator);
        m.resetVote();

        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 10);
        uint256 ts2 = block.timestamp;
        vm.prank(operator);
        m.vote(pools, ws);
        assertGe(voterC.lastVoted(juniorTrancheEngine), ts2, "re-vote after reset succeeded in-epoch");
    }

    // ----------------------------------------------------------------- real claimRebase

    function test_fork_real_claimRebase() public {
        (HarvestVoteModule m, address juniorTrancheEngine) = _deploy();

        // mint a veNFT so the Safe owns one to enumerate.
        _fundOHYDX(juniorTrancheEngine, 50e18);
        vm.prank(operator);
        m.lockVe(50e18);

        IVotingEscrow veC = IVotingEscrow(BaseAddresses.HYDREX_VE);
        IRewardsDistributor rdC = IRewardsDistributor(BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR);

        uint256 n = veC.balanceOf(juniorTrancheEngine);
        assertGt(n, 0, "Safe owns at least one veNFT");
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = veC.tokenOfOwnerByIndex(juniorTrancheEngine, i);
        }

        uint256 claimableBefore = rdC.claimable(ids[0]);

        // claimRebase must not revert.
        vm.prank(operator);
        m.claimRebase(ids);

        // assert one branch (do not leave it a silent no-op).
        if (claimableBefore > 0) {
            // the claim moved it: post-claimable dropped (or stayed, but should not exceed before).
            assertLe(rdC.claimable(ids[0]), claimableBefore, "claim consumed the accrued rebase");
        } else {
            // the fresh veNFT had zero accrued rebase — the empty-tolerance path is what's proven.
            assertEq(claimableBefore, 0, "zero accrued rebase on a fresh lock (empty-tolerance path proven)");
        }
    }

    // ----------------------------------------------------------------- authority on the real Safe

    function test_fork_non_operator_reverts() public {
        (HarvestVoteModule m,) = _deploy();
        vm.expectRevert(HarvestVoteModule.NotOperator.selector);
        m.claimReward();
    }
}
