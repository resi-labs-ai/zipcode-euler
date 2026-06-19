// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";
import {IBaalToken} from "../src/interfaces/baal/IBaalToken.sol";
import {IBaalAndVaultSummoner} from "../src/interfaces/baal/IBaalAndVaultSummoner.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";

/// @notice 8-B1 substrate scaffold — Base-mainnet fork test. Summons against the LIVE
/// `BaalAndVaultSummoner` and proves the substrate is correctly configured AND driveable (the whole point:
/// a zero-Shares Baal-owned Safe must still be operable, via the team-admin owner injection).
contract SummonSubstrateTest is ForkConfig, SummonSubstrate {
    // Distinctive salts (compile-time constants; reproducible, astronomically unlikely to collide with an
    // existing mainnet CREATE2 slot). NEVER block.timestamp/entropy — the compute must re-derive deterministically.
    uint256 internal constant SALT = uint256(keccak256("zipcode.szipusd.substrate.8b1.salt.a"));
    uint256 internal constant SALT2 = uint256(keccak256("zipcode.szipusd.substrate.8b1.salt.b"));

    address internal team = makeAddr("teamMultisig");
    address internal mockGate = makeAddr("mockGate");
    address internal mockModule = makeAddr("mockModule");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _selectBaseFork();
    }

    // External wrapper so `vm.expectRevert` can target the whole summon as one call (collision test).
    function summonCoreExternal(address teamMultisig, uint256 saltNonce) external returns (Substrate memory) {
        return _summonCore(teamMultisig, saltNonce);
    }

    /// @dev Team (owner) drives `safe` via the pre-validated single-owner signature path (v=1; valid because
    /// msg.sender == owner). Pranks `team` for the single execTransaction call.
    function _ownerExec(address safe, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    // --- summon shape + address compute ---------------------------------------------------------------

    function test_summonShape_andAddressCompute() public {
        Substrate memory s = _summonCore(team, SALT);

        assertTrue(s.baal != address(0), "baal=0");
        assertTrue(s.juniorTrancheSafe != address(0), "juniorTrancheSafe=0");
        assertTrue(s.juniorTrancheSidecar != address(0), "juniorTrancheSidecar=0");
        assertTrue(s.loot != address(0), "loot=0");
        assertTrue(s.shares != address(0), "shares=0");
        assertTrue(s.juniorTrancheSafe != s.juniorTrancheSidecar, "main==juniorTrancheSidecar");

        assertEq(IBaal(s.baal).avatar(), s.juniorTrancheSafe, "avatar!=main");
        assertEq(IBaal(s.baal).target(), s.juniorTrancheSafe, "target!=main");
        assertEq(IBaal(s.baal).lootToken(), s.loot, "loot getter");
        assertEq(IBaal(s.baal).sharesToken(), s.shares, "shares getter");

        // Compute is load-bearing + salt-sensitive (not a constant/coincidence).
        assertEq(computeMainSafe(SALT), s.juniorTrancheSafe, "compute!=main");
        assertTrue(computeMainSafe(SALT2) != s.juniorTrancheSafe, "compute not salt-sensitive");
    }

    // --- token state: Loot soulbound, Shares=0 ---------------------------------------------------------

    function test_tokenState_soulboundLoot_zeroShares() public {
        Substrate memory s = _summonCore(team, SALT);

        assertTrue(IBaalToken(s.loot).paused(), "loot not paused");
        assertTrue(IBaalToken(s.shares).paused(), "shares not paused");
        assertEq(IBaalToken(s.loot).decimals(), 18, "loot decimals");
        assertEq(IBaalToken(s.loot).totalSupply(), 0, "loot supply");
        assertEq(IBaalToken(s.shares).totalSupply(), 0, "shares supply");
        assertEq(IBaal(s.baal).totalShares(), 0, "totalShares");
        assertEq(IBaal(s.baal).totalLoot(), 0, "totalLoot");
        assertEq(IBaal(s.baal).totalSupply(), 0, "totalSupply");
        assertEq(IBaalToken(s.loot).owner(), s.baal, "loot owner");
        assertEq(IBaalToken(s.shares).owner(), s.baal, "shares owner");
    }

    // --- governance permanently inert -----------------------------------------------------------------

    function test_governanceConfig_inert() public {
        Substrate memory s = _summonCore(team, SALT);

        assertEq(IBaal(s.baal).quorumPercent(), 0, "quorum");
        assertEq(IBaal(s.baal).sponsorThreshold(), type(uint256).max, "sponsor");
        assertEq(IBaal(s.baal).proposalOffering(), 0, "offering");
        assertEq(IBaal(s.baal).votingPeriod(), 2 days, "voting");
        assertEq(IBaal(s.baal).gracePeriod(), 1 days, "grace");
        assertFalse(IBaal(s.baal).adminLock(), "adminLock");
        assertFalse(IBaal(s.baal).managerLock(), "managerLock");
        assertFalse(IBaal(s.baal).governorLock(), "governorLock");
        assertEq(IBaal(s.baal).shamans(mockGate), 0, "no shaman at summon");
    }

    // --- Safe wiring + the admin injection on BOTH Safes ----------------------------------------------

    function test_safeWiring_baalModule_teamOwner_bothSafes() public {
        // _summonCore adds team to the MAIN safe only; the juniorTrancheSidecar must be Baal-only until the owner-add.
        Substrate memory s = _summonCore(team, SALT);

        assertTrue(ISafe(s.juniorTrancheSafe).isModuleEnabled(s.baal), "baal not module on main");
        assertTrue(ISafe(s.juniorTrancheSidecar).isModuleEnabled(s.baal), "baal not module on juniorTrancheSidecar");
        assertEq(ISafe(s.juniorTrancheSafe).getThreshold(), 1, "main threshold");
        assertEq(ISafe(s.juniorTrancheSidecar).getThreshold(), 1, "juniorTrancheSidecar threshold");
        assertTrue(ISafe(s.juniorTrancheSafe).isOwner(s.baal), "baal not owner main");
        assertTrue(ISafe(s.juniorTrancheSidecar).isOwner(s.baal), "baal not owner juniorTrancheSidecar");

        // Admin injection: team on MAIN (from the init action), NOT yet on the juniorTrancheSidecar.
        assertTrue(ISafe(s.juniorTrancheSafe).isOwner(team), "team not owner main");
        assertFalse(ISafe(s.juniorTrancheSidecar).isOwner(team), "team unexpectedly owner of juniorTrancheSidecar pre-add");

        // The owner-add closes the juniorTrancheSidecar window (effect asserted, not just "didn't revert").
        vm.prank(team);
        _addOwnerToJuniorTrancheSidecar(s.baal, s.juniorTrancheSafe, s.juniorTrancheSidecar, team);
        assertTrue(ISafe(s.juniorTrancheSidecar).isOwner(team), "team not owner juniorTrancheSidecar post-add");
    }

    // --- juniorTrancheSidecar registered in the summoner's vault registry -------------------------------------------

    function test_juniorTrancheSidecarRegistered() public {
        Substrate memory s = _summonCore(team, SALT);
        IBaalAndVaultSummoner summoner = IBaalAndVaultSummoner(BaseAddresses.BAAL_AND_VAULT_SUMMONER);
        uint256 idx = summoner.vaultIdx();
        (uint256 id, bool active, address dao, address vault,) = summoner.vaults(idx);
        assertEq(id, idx, "vault id");
        assertTrue(active, "vault inactive");
        assertEq(dao, s.baal, "vault dao");
        assertEq(vault, s.juniorTrancheSidecar, "vault juniorTrancheSidecar");
    }

    // --- WIREABILITY: the substrate is driveable by the team-admin OWNER path, with zero Shares ---------

    function test_wireability_teamAdminDrivesBothSafes_zeroShares() public {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT); // full: team on both Safes
        vm.stopPrank();

        assertEq(IBaal(s.baal).totalShares(), 0, "shares must stay 0");

        // (a) Grant the (mock) Exit Gate manager(2) via team -> juniorTrancheSafe.execTransaction -> Baal.setShamans.
        assertEq(IBaal(s.baal).shamans(mockGate), 0, "gate pre-shaman");
        _ownerExec(s.juniorTrancheSafe, s.baal, abi.encodeWithSelector(IBaal.setShamans.selector, _one(mockGate), _one2(2)));
        assertEq(IBaal(s.baal).shamans(mockGate), 2, "gate not manager");

        // (b) Enable a (mock) module on BOTH Safes via the team-owner self-call path.
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, mockModule);
        _ownerExec(s.juniorTrancheSafe, s.juniorTrancheSafe, enableMod); // main self-call
        _ownerExec(s.juniorTrancheSidecar, s.juniorTrancheSidecar, enableMod); // juniorTrancheSidecar self-call (team is now a juniorTrancheSidecar owner)
        assertTrue(ISafe(s.juniorTrancheSafe).isModuleEnabled(mockModule), "module not on main");
        assertTrue(ISafe(s.juniorTrancheSidecar).isModuleEnabled(mockModule), "module not on juniorTrancheSidecar");
    }

    // --- NEGATIVE: governance is a genuine dead-end; setShamans is avatar-only -------------------------

    function test_negative_governanceDeadEnd_and_setShamansAvatarOnly() public {
        Substrate memory s = _summonCore(team, SALT);

        // submitProposal SUCCEEDS (offering==0) but the proposal can never be sponsored or processed.
        uint256 pid = IBaal(s.baal).submitProposal(bytes(""), 0, 0, "x");
        vm.expectRevert(bytes("!sponsor"));
        IBaal(s.baal).sponsorProposal(uint32(pid));
        vm.expectRevert(bytes("!sponsor"));
        IBaal(s.baal).processProposal(uint32(pid), bytes(""));

        // Direct setShamans by a non-avatar reverts (only the team->Safe->Baal chain reaches it).
        vm.prank(attacker);
        vm.expectRevert(bytes("!baal"));
        IBaal(s.baal).setShamans(_one(mockGate), _one2(2));
    }

    // --- collision / distinctness ---------------------------------------------------------------------

    function test_saltReuse_reverts_and_distinctSaltsDistinctAddrs() public {
        Substrate memory s = _summonCore(team, SALT);

        // Same salt -> Safe proxy CREATE2 collision in the summoner -> the whole summon reverts.
        vm.expectRevert();
        this.summonCoreExternal(team, SALT);

        // A different salt produces a fully distinct, independent substrate.
        Substrate memory s2 = _summonCore(team, SALT2);
        assertTrue(s2.baal != s.baal, "baal collision");
        assertTrue(s2.juniorTrancheSafe != s.juniorTrancheSafe, "juniorTrancheSafe collision");
        assertTrue(s2.juniorTrancheSidecar != s.juniorTrancheSidecar, "juniorTrancheSidecar collision");
    }

    // -- tiny array helpers ----------------------------------------------------------------------------
    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one2(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
