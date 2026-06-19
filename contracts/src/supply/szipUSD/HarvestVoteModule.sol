// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IGauge} from "../../interfaces/hydrex/IGauge.sol";
import {IVoter} from "../../interfaces/hydrex/IVoter.sol";
import {IVotingEscrow} from "../../interfaces/hydrex/IVotingEscrow.sol";
import {IOptionToken} from "../../interfaces/hydrex/IOptionToken.sol";
import {IRewardsDistributor} from "../../interfaces/hydrex/IRewardsDistributor.sol";

/// @title HarvestVoteModule
/// @notice The on-chain seam of the 8-B7 harvest/vote leg (§4.5.1): the fourth engine Zodiac Module (after the 8-B14
///         buy-and-burn, the 8-B5 reservoir loop, and the 8-B6 LP strategy), CRE-operator-gated, enabled on the
///         szipUSD engine Safe (`avatar == target == juniorTrancheEngine`). It owns the emissions + governance leg of the
///         auto-compounder: per epoch it (1) CLAIMS the gauge's oHYDX to the Safe (`gauge.getReward()`), (2) takes the
///         vote-floor `exerciseVe` slice FIRST (the free permalock → grows the Safe's account-aggregate veHYDX),
///         (3) re-VOTES our gauge (votes reset weekly), and (4) claims the anti-dilution REBASE on the veNFTs.
///
/// @dev SECURITY BOUNDARY (§10.1, the module's whole reason for shape): the operator supplies ONLY scalars/arrays
///      (`amount`, `poolVote`/`weights`, `tokenIds`). The module builds ALL calldata to the set-once wired targets
///      (`gauge`/`voter`/`oHYDX`/`rewardsDistributor`), the `exerciseVe` recipient is hard-pinned to the literal
///      set-once `juniorTrancheEngine`, and every balance/floor read is `juniorTrancheEngine`. NO generic call/exec passthrough, NO
///      delegatecall, `value == 0` on every `exec`. The Voter is ACCOUNT-KEYED (no tokenId); the veNFT and votes
///      accrue to the Safe purely because the Safe is the `exec` msg.sender. There is NO `tokenId` state — the module
///      is stateless beyond the set-once wiring. There are NO token approvals (`getReward`/`exerciseVe`/`vote`/
///      `reset`/`claim_many` all act on the Safe's own holdings/account directly).
///
/// @dev CLONE FACT (§18.6, proven on 8-B14/8-B5/8-B6): a `ModuleProxyFactory` clone shares the mastercopy's runtime
///      bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY
///      per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`.
///      The mastercopy is init-locked in its constructor (see {MastercopyInitLock}).
contract HarvestVoteModule is MastercopyInitLock {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == juniorTrancheEngine`); the `exerciseVe` recipient + every balance read.
    address public juniorTrancheEngine;
    /// @notice The single CRE operator (gates the five mutators).
    address public operator;
    /// @notice The Hydrex gauge over our pool (`getReward()` claims its oHYDX to the Safe).
    address public gauge;
    /// @notice The Hydrex Voter (account-keyed `vote`/`reset`).
    address public voter;
    /// @notice The Hydrex RewardsDistributor (per-veNFT anti-dilution rebase `claim_many`).
    address public rewardsDistributor;
    /// @notice The gauge's reward token (read live in `setUp` off `gauge.rewardToken()`) — the `exerciseVe` target.
    address public oHYDX;
    /// @notice The Voter's voting escrow (read live in `setUp` off `voter.ve()`) — the account-aggregate floor read.
    address public ve;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    error EmptyArray();
    error LengthMismatch();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event RewardClaimed();
    event Locked(uint256 amount, uint256 nftId);
    event Voted(address[] poolVote, uint256[] weights);
    event VoteReset();
    event RebaseClaimed(uint256[] tokenIds);
    /// @notice A Timelock re-point of a wired component address (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). One-shot via the zodiac-core
    ///         `initializer`. Decodes the 6 addresses `(owner, juniorTrancheEngine, operator, gauge, voter, rewardsDistributor)`;
    ///         reads `oHYDX`/`ve` LIVE off the wired dependencies. ORDER is load-bearing: validate all six decoded
    ///         addresses nonzero FIRST + `owner != operator` (so a zero `gauge` reverts `ZeroAddress`, not a confusing
    ///         staticcall-to-zero), set `avatar = target = juniorTrancheEngine`, store the wiring, THEN read + assert the live
    ///         `oHYDX`/`ve` nonzero, THEN `_transferOwnership(owner)`.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address juniorTrancheEngine_,
            address operator_,
            address gauge_,
            address voter_,
            address rewardsDistributor_
        ) = abi.decode(initParams, (address, address, address, address, address, address));

        if (
            owner_ == address(0) || juniorTrancheEngine_ == address(0) || operator_ == address(0) || gauge_ == address(0)
                || voter_ == address(0) || rewardsDistributor_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == juniorTrancheEngine.
        avatar = juniorTrancheEngine_;
        target = juniorTrancheEngine_;

        juniorTrancheEngine = juniorTrancheEngine_;
        operator = operator_;
        gauge = gauge_;
        voter = voter_;
        rewardsDistributor = rewardsDistributor_;

        // Read the reward token + escrow LIVE off the wired dependencies (the 8-B6 live-read pattern) — guarantees the
        // `exerciseVe` target == the gauge's reward token and the floor-read escrow == the Voter's escrow.
        address oHYDX_ = IGauge(gauge_).rewardToken();
        address ve_ = IVoter(voter_).ve();
        if (oHYDX_ == address(0) || ve_ == address(0)) revert ZeroAddress();
        oHYDX = oHYDX_;
        ve = ve_;

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the
    //      hot key) CANNOT call them — only `owner` (the Timelock) can, and a redirect by governance is a deliberate
    //      timelocked act, not an attack path. We do NOT hard-lock them (that would require marking the vendored
    //      zodiac-core setters `virtual` — reference deps stay pristine). Tested: a non-owner caller reverts.

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    // Re-point cross-component wiring during the build phase. onlyOwner == the Timelock; the CRE `operator` (hot key)
    // cannot reach these. A redirect is a deliberate timelocked governance act, not an attack path.

    /// @notice Re-point `juniorTrancheEngine` (build phase, §17). onlyOwner (Timelock).
    function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
        if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
        juniorTrancheEngine = juniorTrancheEngine_;
        emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `gauge` (build phase, §17). onlyOwner (Timelock).
    function setGauge(address gauge_) external onlyOwner {
        if (gauge_ == address(0)) revert ZeroAddress();
        gauge = gauge_;
        emit WiringSet("gauge", gauge_);
    }

    /// @notice Re-point `voter` (build phase, §17). onlyOwner (Timelock).
    function setVoter(address voter_) external onlyOwner {
        if (voter_ == address(0)) revert ZeroAddress();
        voter = voter_;
        emit WiringSet("voter", voter_);
    }

    /// @notice Re-point `rewardsDistributor` (build phase, §17). onlyOwner (Timelock).
    function setRewardsDistributor(address rewardsDistributor_) external onlyOwner {
        if (rewardsDistributor_ == address(0)) revert ZeroAddress();
        rewardsDistributor = rewardsDistributor_;
        emit WiringSet("rewardsDistributor", rewardsDistributor_);
    }

    /// @notice Re-point `oHYDX` (build phase, §17). onlyOwner (Timelock).
    function setOHYDX(address oHYDX_) external onlyOwner {
        if (oHYDX_ == address(0)) revert ZeroAddress();
        oHYDX = oHYDX_;
        emit WiringSet("oHYDX", oHYDX_);
    }

    /// @notice Re-point `ve` (build phase, §17). onlyOwner (Timelock).
    function setVe(address ve_) external onlyOwner {
        if (ve_ == address(0)) revert ZeroAddress();
        ve = ve_;
        emit WiringSet("ve", ve_);
    }

    // --------------------------------------------------------------------- the harvest/vote leg (operator-only)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data so the original Hydrex error surfaces (the Gnosis Safe
    ///      `execTransactionFromModuleReturnData` catches inner reverts and returns `(false, revertData)` rather than
    ///      bubbling, so an unchecked `exec` would silently swallow a failed claim/lock/vote and the step would wrongly
    ///      report success). Returns the inner return data (only `lockVe` decodes it — the fresh veNFT id).
    function _exec(address to, bytes memory data) private returns (bytes memory) {
        (bool ok, bytes memory ret) = execAndReturnData(to, 0, data, Operation.Call);
        if (!ok) {
            if (ret.length == 0) revert ExecFailed();
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Claim the gauge's oHYDX emissions to the Safe (step 1 of the per-epoch harvest). The oHYDX lands in the
    ///         Safe (= the gauge call's msg.sender).
    function claimReward() external onlyOperator {
        _exec(gauge, abi.encodeCall(IGauge.getReward, ()));
        emit RewardClaimed();
    }

    /// @notice The vote-floor FREE permalock: burn `amount` oHYDX from the Safe and permalock the underlying HYDX into
    ///         a FRESH account-owned veHYDX NFT minted to the Safe. Decodes + emits the new `nftId` (the veNFT is owned
    ///         by the Safe; the module stores no id — the Voter is account-keyed).
    function lockVe(uint256 amount) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        bytes memory ret = _exec(oHYDX, abi.encodeCall(IOptionToken.exerciseVe, (amount, juniorTrancheEngine)));
        uint256 nftId = abi.decode(ret, (uint256));
        emit Locked(amount, nftId);
    }

    /// @notice Re-vote our gauge (account-keyed; votes reset weekly, so this runs every epoch). The Voter votes with
    ///         the Safe's whole veHYDX position — no tokenId.
    function vote(address[] calldata poolVote, uint256[] calldata weights) external onlyOperator {
        if (poolVote.length == 0) revert EmptyArray();
        if (poolVote.length != weights.length) revert LengthMismatch();
        _exec(voter, abi.encodeCall(IVoter.vote, (poolVote, weights)));
        emit Voted(poolVote, weights);
    }

    /// @notice Clear the Safe's current-epoch vote (account-keyed; the unwind/emergency path).
    function resetVote() external onlyOperator {
        _exec(voter, abi.encodeCall(IVoter.reset, ()));
        emit VoteReset();
    }

    /// @notice Claim the per-veNFT anti-dilution rebase (the operator enumerates the Safe's veNFTs off-chain). The
    ///         module ignores `claim_many`'s bool return (the rebase credits each veNFT's own lock; it cannot be
    ///         redirected, so an imperfect operator-curated array is harmless).
    function claimRebase(uint256[] calldata tokenIds) external onlyOperator {
        if (tokenIds.length == 0) revert EmptyArray();
        _exec(rewardsDistributor, abi.encodeCall(IRewardsDistributor.claim_many, (tokenIds)));
        emit RebaseClaimed(tokenIds);
    }

    // --------------------------------------------------------------------- views (8-B11/8-B12 back-pressure)
    /// @notice The claimable oHYDX sitting on the gauge for the Safe (the two-arg `earned(token, account)` form).
    function pendingReward() external view returns (uint256) {
        return IGauge(gauge).earned(oHYDX, juniorTrancheEngine);
    }

    /// @notice The Safe's account-aggregate veHYDX voting power (the floor metric — summed across ALL its veNFTs).
    function voteFloor() external view returns (uint256) {
        return IVotingEscrow(ve).getVotes(juniorTrancheEngine);
    }

    /// @notice The claimable rebase on a single veNFT (per-id; the operator enumerates off-chain).
    function rebaseClaimable(uint256 tokenId) external view returns (uint256) {
        return IRewardsDistributor(rewardsDistributor).claimable(tokenId);
    }
}
