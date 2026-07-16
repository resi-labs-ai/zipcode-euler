// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAddresses} from "../../script/BaseAddresses.sol";

// External "minimal mirror" interfaces under audit. Selectors are taken at COMPILE TIME
// via `IFoo.bar.selector` so this test breaks loudly if a mirror's signature is edited.
import {ISafe} from "../../src/interfaces/safe/ISafe.sol";
import {IGPv2Settlement} from "../../src/interfaces/cow/IGPv2Settlement.sol";
import {IRoles} from "../../src/interfaces/zodiac/IRoles.sol";
import {IAlgebraPool} from "../../src/interfaces/algebra/IAlgebraPool.sol";
import {IAlgebraOraclePlugin} from "../../src/interfaces/algebra/IAlgebraOraclePlugin.sol";
import {ISwapRouter} from "../../src/interfaces/algebra/ISwapRouter.sol";
import {IICHIVault} from "../../src/interfaces/ichi/IICHIVault.sol";
import {IEulerEarn} from "../../src/interfaces/euler/IEulerEarn.sol";
import {IGauge} from "../../src/interfaces/hydrex/IGauge.sol";
import {IOptionToken} from "../../src/interfaces/hydrex/IOptionToken.sol";
import {IVammPair} from "../../src/interfaces/hydrex/IVammPair.sol";
import {IVoter} from "../../src/interfaces/hydrex/IVoter.sol";
import {IVotingEscrow} from "../../src/interfaces/hydrex/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../src/interfaces/hydrex/IRewardsDistributor.sol";
import {IBaal} from "../../src/interfaces/baal/IBaal.sol";

interface IEulerEarnFactoryView {
    function getVaultListLength() external view returns (uint256);
    function getVaultListSlice(uint256 start, uint256 end) external view returns (address[] memory list);
}

interface IBeacon {
    function implementation() external view returns (address);
}

interface IErc4626AssetView {
    function asset() external view returns (address);
}

/// @title InterfaceSelectorDrift
/// @notice Base-fork guard for the one open residual in
///         `src/interfaces/x-ray/dependency-surface.md`: the local "minimal mirror" interfaces
///         cite a live Base address + verified selectors in NatSpec, but nothing re-validates
///         those selectors against the LIVE deployed bytecode. An upgraded external contract can
///         drift from the mirror silently. This test makes that check exist and runnable.
///
///         For each EXTERNAL dependency interface that cites a live Base address, every CONSUMED
///         function selector (taken at compile time via `IFoo.bar.selector`) is asserted present in
///         the live bytecode at that address. Selectors are scanned as a PUSH4 dispatch heuristic,
///         with the solc-optimizer leading-zero-stripped variant covered (low selectors are pushed
///         as PUSH3/PUSH2 with the leading zero byte dropped) so the heuristic does not false-
///         negative on selectors like ICHIVault.withdraw (0x00f714ce).
///
///         PROXIES: many vendors deploy behind a proxy whose own runtime code is just a dispatch +
///         delegatecall (the consumed selectors live in the implementation). `_resolveImpl` follows
///         the EIP-1967 implementation slot and the EIP-1967 beacon slot (calling `implementation()`
///         on the beacon) so the scan always lands on the bytecode that actually contains the
///         dispatcher. This also turns a silent vendor upgrade into a visible, still-passing check
///         as long as the consumed ABI survives the upgrade (see the Voter note below).
///
///         EXCLUSIONS:
///           - Subtensor precompiles (bridge/ISubtensorPrecompiles.sol) — 964-only, no public Base
///             fork exists, so they stay SNAPSHOT-TRUSTED (verified against Rust source + Rubicon).
///             They cannot be checked here and are intentionally omitted.
///           - STAGED interfaces (IAlgebraFactory, INonfungiblePositionManager, IICHIVaultFactory,
///             IICHIDepositGuard) — declared, wired nowhere; forward scaffolding, not live trust.
///           - Internal seams + deploy/test-only summoner/factory/registry mirrors — not external
///             runtime trust.
contract InterfaceSelectorDriftTest is Test {
    // EIP-1967 slots.
    bytes32 internal constant EIP1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1967_BEACON_SLOT =
        0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));
        assertEq(block.chainid, 8453, "fork is not Base mainnet (8453)");
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    /// @notice Follow EIP-1967 impl + beacon proxy pointers so the selector scan lands on the
    ///         bytecode that actually holds the function dispatcher. Returns `a` itself if `a` is
    ///         not a recognized proxy. Bounded loop to defend against a pointer cycle.
    function _resolveImpl(address a) internal view returns (address impl) {
        impl = a;
        for (uint256 i = 0; i < 4; ++i) {
            address direct = address(uint160(uint256(vm.load(impl, EIP1967_IMPL_SLOT))));
            if (direct != address(0) && direct.code.length > 0) {
                impl = direct;
                continue;
            }
            address beacon = address(uint160(uint256(vm.load(impl, EIP1967_BEACON_SLOT))));
            if (beacon != address(0) && beacon.code.length > 0) {
                try IBeacon(beacon).implementation() returns (address bImpl) {
                    if (bImpl != address(0) && bImpl.code.length > 0 && bImpl != impl) {
                        impl = bImpl;
                        continue;
                    }
                } catch {}
            }
            break;
        }
    }

    /// @notice True iff the 4 selector bytes appear contiguously in `code`, OR (for selectors whose
    ///         leading byte(s) are zero) the optimizer's leading-zero-stripped PUSH3/PUSH2/PUSH1
    ///         encoding appears. solc pushes a 4-byte selector for `EQ` dispatch; the optimizer
    ///         drops leading zero bytes, so e.g. 0x00f714ce is emitted as PUSH3 0xf714ce.
    function _codeContainsSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        // Significant (leading-zero-stripped) bytes of the selector.
        bytes memory needle = _stripLeadingZeros(sel);
        return _contains(code, needle);
    }

    function _stripLeadingZeros(bytes4 sel) internal pure returns (bytes memory out) {
        bytes memory full = abi.encodePacked(sel);
        uint256 start = 0;
        // Keep at least one byte even if the (degenerate) selector were all-zero.
        while (start < 3 && full[start] == 0x00) {
            start++;
        }
        out = new bytes(4 - start);
        for (uint256 i = start; i < 4; ++i) {
            out[i - start] = full[i];
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || haystack.length < needle.length) return false;
        uint256 end = haystack.length - needle.length;
        for (uint256 i = 0; i <= end; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @notice Core assertion: the contract at `a` (proxy-resolved) still exposes `sel` in its
    ///         live bytecode. A genuinely-absent selector is a REAL drift finding — this fails.
    function assertSelectorLive(address a, bytes4 sel, string memory what) internal view {
        require(a.code.length > 0, string.concat("DEAD CONTRACT (no code): ", what));
        address impl = _resolveImpl(a);
        require(impl.code.length > 0, string.concat("DEAD IMPL (proxy resolved to empty): ", what));
        bytes memory code = impl.code;
        if (!_codeContainsSelector(code, sel)) {
            revert(
                string.concat(
                    "SELECTOR DRIFT: ",
                    what,
                    " selector ",
                    vm.toString(bytes32(sel)),
                    " ABSENT from live bytecode at ",
                    vm.toString(a),
                    " (impl ",
                    vm.toString(impl),
                    ")"
                )
            );
        }
    }

    // ----------------------------------------------------------------------------------------
    // Gnosis Safe — SafeL2 1.4.1 singleton (mastercopy holds the dispatcher).
    // ----------------------------------------------------------------------------------------
    function test_Safe_selectorsLive() public view {
        address a = BaseAddresses.SAFE_L2_SINGLETON_1_4_1; // 0x29fcB4...
        assertSelectorLive(a, ISafe.setup.selector, "ISafe.setup");
        assertSelectorLive(a, ISafe.enableModule.selector, "ISafe.enableModule");
        assertSelectorLive(a, ISafe.isModuleEnabled.selector, "ISafe.isModuleEnabled");
        assertSelectorLive(a, ISafe.execTransactionFromModule.selector, "ISafe.execTransactionFromModule");
        assertSelectorLive(a, ISafe.swapOwner.selector, "ISafe.swapOwner");
        assertSelectorLive(a, ISafe.addOwnerWithThreshold.selector, "ISafe.addOwnerWithThreshold");
        assertSelectorLive(a, ISafe.removeOwner.selector, "ISafe.removeOwner");
        assertSelectorLive(a, ISafe.getOwners.selector, "ISafe.getOwners");
        assertSelectorLive(a, ISafe.isOwner.selector, "ISafe.isOwner");
        assertSelectorLive(a, ISafe.getThreshold.selector, "ISafe.getThreshold");
        assertSelectorLive(a, ISafe.execTransaction.selector, "ISafe.execTransaction");
    }

    // ----------------------------------------------------------------------------------------
    // CoW Protocol — GPv2Settlement (same address all chains).
    // ----------------------------------------------------------------------------------------
    function test_Cow_selectorsLive() public view {
        address a = BaseAddresses.COW_SETTLEMENT; // 0x9008D1...
        assertSelectorLive(a, IGPv2Settlement.domainSeparator.selector, "IGPv2Settlement.domainSeparator");
        assertSelectorLive(a, IGPv2Settlement.vaultRelayer.selector, "IGPv2Settlement.vaultRelayer");
        assertSelectorLive(a, IGPv2Settlement.setPreSignature.selector, "IGPv2Settlement.setPreSignature");
        assertSelectorLive(a, IGPv2Settlement.preSignature.selector, "IGPv2Settlement.preSignature");
    }

    // ----------------------------------------------------------------------------------------
    // Zodiac Roles Modifier v2 — mastercopy (holds the dispatcher; live instances delegatecall it).
    // ----------------------------------------------------------------------------------------
    function test_ZodiacRoles_selectorsLive() public view {
        address a = BaseAddresses.ZODIAC_ROLES_MASTERCOPY; // 0x9646fD...
        assertSelectorLive(a, IRoles.avatar.selector, "IRoles.avatar");
        assertSelectorLive(a, IRoles.setAvatar.selector, "IRoles.setAvatar");
        assertSelectorLive(a, IRoles.assignRoles.selector, "IRoles.assignRoles");
        assertSelectorLive(a, IRoles.execTransactionWithRole.selector, "IRoles.execTransactionWithRole");
        assertSelectorLive(a, IRoles.scopeTarget.selector, "IRoles.scopeTarget");
        assertSelectorLive(a, IRoles.scopeFunction.selector, "IRoles.scopeFunction");
        assertSelectorLive(a, IRoles.allowFunction.selector, "IRoles.allowFunction");
    }

    // ----------------------------------------------------------------------------------------
    // Algebra Integral — HYDX/USDC pool, its TWAP plugin (EIP-1967 beacon proxy), and SwapRouter.
    // ----------------------------------------------------------------------------------------
    function test_AlgebraPool_selectorsLive() public view {
        address a = BaseAddresses.HYDX_USDC_POOL; // 0x51f0B9...
        assertSelectorLive(a, IAlgebraPool.swap.selector, "IAlgebraPool.swap");
        assertSelectorLive(a, IAlgebraPool.globalState.selector, "IAlgebraPool.globalState");
        assertSelectorLive(a, IAlgebraPool.token0.selector, "IAlgebraPool.token0");
        assertSelectorLive(a, IAlgebraPool.token1.selector, "IAlgebraPool.token1");
        assertSelectorLive(a, IAlgebraPool.plugin.selector, "IAlgebraPool.plugin");
    }

    function test_AlgebraOraclePlugin_selectorsLive() public view {
        // The pool's live plugin, read on-chain (NatSpec cites 0xe33a2...; read live so it cannot drift).
        address plugin = IAlgebraPool(BaseAddresses.HYDX_USDC_POOL).plugin();
        // The plugin is an EIP-1967 beacon proxy; assertSelectorLive resolves to the beacon impl.
        assertSelectorLive(plugin, IAlgebraOraclePlugin.getTimepoints.selector, "IAlgebraOraclePlugin.getTimepoints");
        assertSelectorLive(plugin, IAlgebraOraclePlugin.isInitialized.selector, "IAlgebraOraclePlugin.isInitialized");
    }

    function test_AlgebraSwapRouter_selectorsLive() public view {
        address a = BaseAddresses.ALGEBRA_SWAP_ROUTER; // 0x6f4bE2...
        assertSelectorLive(a, ISwapRouter.exactInputSingle.selector, "ISwapRouter.exactInputSingle");
    }

    // ----------------------------------------------------------------------------------------
    // ICHI — a live HYDX ICHI vault (read from the factory; NatSpec cites 0x07e72...).
    //   Covers ICHIVault.withdraw (0x00f714ce) — the leading-zero-stripped PUSH3 case.
    // ----------------------------------------------------------------------------------------
    function test_IchiVault_selectorsLive() public view {
        // Use the NatSpec-cited live HYDX ICHI vault directly.
        address a = 0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad;
        assertSelectorLive(a, IICHIVault.deposit.selector, "IICHIVault.deposit");
        assertSelectorLive(a, IICHIVault.withdraw.selector, "IICHIVault.withdraw"); // 0x00f714ce
        assertSelectorLive(a, IICHIVault.token0.selector, "IICHIVault.token0");
        assertSelectorLive(a, IICHIVault.token1.selector, "IICHIVault.token1");
        assertSelectorLive(a, IICHIVault.totalSupply.selector, "IICHIVault.totalSupply");
        assertSelectorLive(a, IICHIVault.balanceOf.selector, "IICHIVault.balanceOf");
        assertSelectorLive(a, IICHIVault.getTotalAmounts.selector, "IICHIVault.getTotalAmounts");
        assertSelectorLive(a, IICHIVault.allowToken0.selector, "IICHIVault.allowToken0");
        assertSelectorLive(a, IICHIVault.allowToken1.selector, "IICHIVault.allowToken1");
        assertSelectorLive(a, IICHIVault.pool.selector, "IICHIVault.pool");
        assertSelectorLive(a, IICHIVault.getBasePosition.selector, "IICHIVault.getBasePosition");
        assertSelectorLive(a, IICHIVault.getLimitPosition.selector, "IICHIVault.getLimitPosition");
        assertSelectorLive(a, IICHIVault.baseLower.selector, "IICHIVault.baseLower");
        assertSelectorLive(a, IICHIVault.baseUpper.selector, "IICHIVault.baseUpper");
        assertSelectorLive(a, IICHIVault.limitLower.selector, "IICHIVault.limitLower");
        assertSelectorLive(a, IICHIVault.limitUpper.selector, "IICHIVault.limitUpper");
    }

    // ----------------------------------------------------------------------------------------
    // Euler — IEulerEarn cites no single live vault address (per-market deployments). Discover a
    //   live USDC EulerEarn vault from EULER_EARN_FACTORY and check the consumed 4626 surface.
    // ----------------------------------------------------------------------------------------
    function test_EulerEarn_selectorsLive() public view {
        address vault = _firstUsdcEulerEarnVault();
        require(vault != address(0), "no live EulerEarn USDC vault discovered from factory");
        assertSelectorLive(vault, IEulerEarn.deposit.selector, "IEulerEarn.deposit");
        assertSelectorLive(vault, IEulerEarn.redeem.selector, "IEulerEarn.redeem");
        assertSelectorLive(vault, IEulerEarn.convertToAssets.selector, "IEulerEarn.convertToAssets");
        assertSelectorLive(vault, IEulerEarn.balanceOf.selector, "IEulerEarn.balanceOf");
        assertSelectorLive(vault, IEulerEarn.asset.selector, "IEulerEarn.asset");
    }

    function _firstUsdcEulerEarnVault() internal view returns (address) {
        IEulerEarnFactoryView f = IEulerEarnFactoryView(BaseAddresses.EULER_EARN_FACTORY);
        uint256 len = f.getVaultListLength();
        if (len == 0) return address(0);
        uint256 end = len > 25 ? 25 : len; // scan a bounded prefix
        address[] memory vaults = f.getVaultListSlice(0, end);
        for (uint256 i = 0; i < vaults.length; ++i) {
            try IErc4626AssetView(vaults[i]).asset() returns (address asset) {
                if (asset == BaseAddresses.USDC) return vaults[i];
            } catch {}
        }
        // Fall back to the first deployment if none happens to be USDC (still a live EulerEarn).
        return vaults[0];
    }

    // ----------------------------------------------------------------------------------------
    // Hydrex — gauge (beacon proxy), oHYDX option token (non-proxy), Voter (EIP-1967 proxy),
    //   veHYDX (EIP-1967 proxy), RewardsDistributor (non-proxy), vAMM pair (demo seam).
    // ----------------------------------------------------------------------------------------
    function test_HydrexGauge_selectorsLive() public view {
        // NatSpec example gauge (BeaconProxy); assertSelectorLive resolves to the current beacon impl.
        address a = 0xAC396CabF5832A49483B78225D902C0999829993;
        assertSelectorLive(a, IGauge.deposit.selector, "IGauge.deposit");
        assertSelectorLive(a, IGauge.withdraw.selector, "IGauge.withdraw");
        assertSelectorLive(a, IGauge.getReward.selector, "IGauge.getReward");
        assertSelectorLive(a, IGauge.rewardToken.selector, "IGauge.rewardToken");
        assertSelectorLive(a, IGauge.earned.selector, "IGauge.earned"); // 2-arg (token, account)
        assertSelectorLive(a, IGauge.balanceOf.selector, "IGauge.balanceOf");
    }

    function test_HydrexOptionToken_selectorsLive() public view {
        address a = BaseAddresses.OHYDX; // 0xA11360... (non-proxy)
        assertSelectorLive(a, IOptionToken.exercise.selector, "IOptionToken.exercise");
        assertSelectorLive(a, IOptionToken.exerciseVe.selector, "IOptionToken.exerciseVe");
        assertSelectorLive(a, IOptionToken.paymentToken.selector, "IOptionToken.paymentToken");
        assertSelectorLive(a, IOptionToken.getDiscountedPrice.selector, "IOptionToken.getDiscountedPrice");
        assertSelectorLive(a, IOptionToken.getMinPaymentAmount.selector, "IOptionToken.getMinPaymentAmount");
        assertSelectorLive(a, IOptionToken.discount.selector, "IOptionToken.discount");
    }

    function test_HydrexVoter_selectorsLive() public view {
        // VoterV5Proxy. NatSpec cites impl 0x0379...; the live EIP-1967 impl has since been UPGRADED
        // (now 0x9cb9fc7d...). assertSelectorLive resolves the CURRENT impl — the consumed ABI must
        // survive the upgrade; if a consumed selector vanished, that is real drift and this fails.
        address a = BaseAddresses.HYDREX_VOTER; // 0xc69E3e...
        assertSelectorLive(a, IVoter.vote.selector, "IVoter.vote");
        assertSelectorLive(a, IVoter.reset.selector, "IVoter.reset");
        assertSelectorLive(a, IVoter.ve.selector, "IVoter.ve");
        assertSelectorLive(a, IVoter.createGauge.selector, "IVoter.createGauge");
        assertSelectorLive(a, IVoter.gauges.selector, "IVoter.gauges");
        assertSelectorLive(a, IVoter.claimRewards.selector, "IVoter.claimRewards");
    }

    function test_HydrexVotingEscrow_selectorsLive() public view {
        address a = BaseAddresses.VEHYDX; // 0x25B2ED... (EIP-1967 proxy)
        assertSelectorLive(a, IVotingEscrow.createLock.selector, "IVotingEscrow.createLock");
        assertSelectorLive(a, IVotingEscrow.balanceOfNFT.selector, "IVotingEscrow.balanceOfNFT");
        assertSelectorLive(a, IVotingEscrow.getVotes.selector, "IVotingEscrow.getVotes");
        assertSelectorLive(a, IVotingEscrow.balanceOf.selector, "IVotingEscrow.balanceOf");
        assertSelectorLive(a, IVotingEscrow.ownerOf.selector, "IVotingEscrow.ownerOf");
        assertSelectorLive(a, IVotingEscrow.tokenOfOwnerByIndex.selector, "IVotingEscrow.tokenOfOwnerByIndex");
    }

    function test_HydrexRewardsDistributor_selectorsLive() public view {
        address a = BaseAddresses.HYDREX_REWARDS_DISTRIBUTOR; // 0x6FCa20...
        assertSelectorLive(a, IRewardsDistributor.claim.selector, "IRewardsDistributor.claim");
        assertSelectorLive(a, IRewardsDistributor.claim_many.selector, "IRewardsDistributor.claim_many");
        assertSelectorLive(a, IRewardsDistributor.claimable.selector, "IRewardsDistributor.claimable");
    }

    function test_HydrexVammPair_selectorsLive() public view {
        // Demo/showcase seam (hydrex-demo-fork); the live vAMM HYDX/USDC pair.
        address a = 0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d;
        assertSelectorLive(a, IVammPair.mint.selector, "IVammPair.mint");
        assertSelectorLive(a, IVammPair.getReserves.selector, "IVammPair.getReserves");
        assertSelectorLive(a, IVammPair.token0.selector, "IVammPair.token0");
        assertSelectorLive(a, IVammPair.token1.selector, "IVammPair.token1");
        assertSelectorLive(a, IVammPair.totalSupply.selector, "IVammPair.totalSupply");
        assertSelectorLive(a, IVammPair.balanceOf.selector, "IVammPair.balanceOf");
    }

    // ----------------------------------------------------------------------------------------
    // Baal (Moloch v3) — the IBaal NatSpec cites 0xD69e5B8F... as the "Baal impl", but that address
    //   is the BaalAdvTokenSummoner IMPLEMENTATION (BaseAddresses.BAAL_ADV_TOKEN_SUMMONER_IMPL), NOT
    //   the Baal DAO. The IBaal consumed selectors (executeAsBaal/ragequit/sharesToken/...) live on
    //   the Baal DAO template at BaseAddresses.BAAL_SINGLETON (0xE0F33E95...). This is a NatSpec
    //   CITATION bug in the mirror, not selector drift on the real contract. We check the CORRECT
    //   address (the Baal DAO singleton, where ExitGate's calls actually dispatch). See the returned
    //   drift report for the mirror's stale address to fix.
    // ----------------------------------------------------------------------------------------
    function test_Baal_selectorsLive() public view {
        address a = BaseAddresses.BAAL_SINGLETON; // 0xE0F33E95... (the actual Baal DAO master copy)
        assertSelectorLive(a, IBaal.ragequit.selector, "IBaal.ragequit");
        assertSelectorLive(a, IBaal.mintLoot.selector, "IBaal.mintLoot");
        assertSelectorLive(a, IBaal.burnLoot.selector, "IBaal.burnLoot");
        assertSelectorLive(a, IBaal.setShamans.selector, "IBaal.setShamans");
        assertSelectorLive(a, IBaal.mintShares.selector, "IBaal.mintShares");
        assertSelectorLive(a, IBaal.setAdminConfig.selector, "IBaal.setAdminConfig");
        assertSelectorLive(a, IBaal.setGovernanceConfig.selector, "IBaal.setGovernanceConfig");
        assertSelectorLive(a, IBaal.executeAsBaal.selector, "IBaal.executeAsBaal");
        assertSelectorLive(a, IBaal.submitProposal.selector, "IBaal.submitProposal");
        assertSelectorLive(a, IBaal.sponsorProposal.selector, "IBaal.sponsorProposal");
        assertSelectorLive(a, IBaal.processProposal.selector, "IBaal.processProposal");
        assertSelectorLive(a, IBaal.lootToken.selector, "IBaal.lootToken");
        assertSelectorLive(a, IBaal.sharesToken.selector, "IBaal.sharesToken");
        assertSelectorLive(a, IBaal.avatar.selector, "IBaal.avatar");
        assertSelectorLive(a, IBaal.target.selector, "IBaal.target");
        assertSelectorLive(a, IBaal.shamans.selector, "IBaal.shamans");
        assertSelectorLive(a, IBaal.totalShares.selector, "IBaal.totalShares");
        assertSelectorLive(a, IBaal.totalLoot.selector, "IBaal.totalLoot");
        assertSelectorLive(a, IBaal.totalSupply.selector, "IBaal.totalSupply");
        assertSelectorLive(a, IBaal.quorumPercent.selector, "IBaal.quorumPercent");
        assertSelectorLive(a, IBaal.sponsorThreshold.selector, "IBaal.sponsorThreshold");
        assertSelectorLive(a, IBaal.proposalOffering.selector, "IBaal.proposalOffering");
        assertSelectorLive(a, IBaal.votingPeriod.selector, "IBaal.votingPeriod");
        assertSelectorLive(a, IBaal.gracePeriod.selector, "IBaal.gracePeriod");
        assertSelectorLive(a, IBaal.adminLock.selector, "IBaal.adminLock");
        assertSelectorLive(a, IBaal.managerLock.selector, "IBaal.managerLock");
        assertSelectorLive(a, IBaal.governorLock.selector, "IBaal.governorLock");
    }
}
