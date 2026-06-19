// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {IBaalAndVaultSummoner} from "../src/interfaces/baal/IBaalAndVaultSummoner.sol";
import {IBaalSummoner} from "../src/interfaces/baal/IBaalSummoner.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {ISafeProxyFactory} from "../src/interfaces/safe/ISafeProxyFactory.sol";

/// @title SummonSubstrate (8-B1)
/// @notice Summons the szipUSD junior-vault substrate against the LIVE Baal `BaalAndVaultSummoner` on
/// Base 8453: a Baal (Moloch v3) DAO + its main Gnosis Safe (avatar/ragequit target = FREE equity) + a
/// non-ragequittable juniorTrancheSidecar Safe (COMMITTED equity / the structural freeze) + Loot/Shares clones (Loot
/// soulbound/paused at genesis, Shares = 0 forever). It injects the TEAM MULTISIG as a Safe owner/signer
/// on BOTH Safes so the otherwise governance-inert substrate is driveable (the two-tier admin/operator
/// model, claude-zipcode.md §4.5 item-0 / baal-spec.md 8-B1).
///
/// We INTERACT with the live Baal (solc 0.8.7) through minimal local interfaces — we never compile it.
contract SummonSubstrate is Script {
    /// @dev Returned-and-computed main-Safe address disagreed (factory/singleton/salt assumption wrong).
    error MainSafeMismatch(address computed, address actual);
    /// @dev The team-admin owner injection did not land on a Safe.
    error TeamOwnerNotSet(address safe);

    struct Substrate {
        address baal;
        address juniorTrancheSafe;
        address juniorTrancheSidecar;
        address loot;
        address shares;
    }

    // -- permanently-inert governance config (zero Shares makes it moot; unmeetable sponsor is belt-and-suspenders)
    uint32 internal constant VOTING_PERIOD = 2 days;
    uint32 internal constant GRACE_PERIOD = 1 days;
    uint256 internal constant PROPOSAL_OFFERING = 0;
    uint256 internal constant QUORUM_PERCENT = 0;
    uint256 internal constant SPONSOR_THRESHOLD = type(uint256).max;
    uint256 internal constant MIN_RETENTION_PERCENT = 0;

    string internal constant TOKEN_NAME = "Zipcode szipUSD Junior";
    string internal constant TOKEN_SYMBOL = "zJR";
    string internal constant VAULT_NAME = "Zipcode szipUSD Junior Sidecar";

    /// @notice Script entrypoint. Reads TEAM_MULTISIG + SUMMON_SALT_NONCE from env and broadcasts the summon.
    /// @dev The broadcaster MUST be the team multisig signer (the juniorTrancheSidecar owner-add uses the Safe pre-validated
    /// signature path, which requires `msg.sender == owner`). In production the team is a k-of-n Gnosis Safe and the
    /// juniorTrancheSidecar owner-add + all later wiring are separate team-signed Safe txs; this script models the MVP path.
    function run() external returns (Substrate memory s) {
        address team = vm.envAddress("TEAM_MULTISIG");
        uint256 saltNonce = vm.envUint("SUMMON_SALT_NONCE");
        vm.startBroadcast();
        s = _summon(team, saltNonce);
        vm.stopBroadcast();
    }

    /// @notice Summon the substrate and inject `teamMultisig` as a signer on BOTH Safes (the full, driveable
    /// substrate). The CALLER must be `teamMultisig` (the juniorTrancheSidecar owner-add requires `msg.sender == owner`).
    /// Reusable from `run()` and the fork test.
    function _summon(address teamMultisig, uint256 saltNonce) internal returns (Substrate memory s) {
        // Summon + main-Safe team owner-add (init action, caller-agnostic).
        s = _summonCore(teamMultisig, saltNonce);

        // Sidecar owner-add (the juniorTrancheSidecar ships Baal-only; close it now). The team (caller) drives the main Safe
        // -> Baal.executeAsBaal(juniorTrancheSidecar, ...) -> juniorTrancheSidecar.execTransactionFromModule(self, addOwnerWithThreshold).
        _addOwnerToJuniorTrancheSidecar(s.baal, s.juniorTrancheSafe, s.juniorTrancheSidecar, teamMultisig);
        if (!ISafe(s.juniorTrancheSidecar).isOwner(teamMultisig)) revert TeamOwnerNotSet(s.juniorTrancheSidecar);
    }

    /// @notice Summon the substrate + add `teamMultisig` to the MAIN Safe (via the summon init-action — so this is
    /// caller-agnostic; no prank/broadcast-as-team needed). The juniorTrancheSidecar is NOT yet team-owned after this — see
    /// `_summon` / `_addOwnerToJuniorTrancheSidecar`.
    function _summonCore(address teamMultisig, uint256 saltNonce) internal returns (Substrate memory s) {
        // 1. Predict the main Safe (deterministic CREATE2 over factory/singleton/saltNonce, empty initializer).
        address predictedMainSafe = computeMainSafe(saltNonce);

        // 2. Build init params (new tokens, new main safe, no forwarder) + the 6 ordered init-actions.
        bytes memory initParams =
            abi.encode(TOKEN_NAME, TOKEN_SYMBOL, address(0), address(0), address(0), address(0));
        bytes[] memory actions = _buildInitActions(predictedMainSafe, teamMultisig);

        // 3. Summon: Baal + main Safe + Loot/Shares (+ run init-actions, incl. the main-Safe team owner-add) then
        //    the juniorTrancheSidecar. daoAddress = Baal; vaultAddress = juniorTrancheSidecar.
        (address baal, address juniorTrancheSidecar) = IBaalAndVaultSummoner(BaseAddresses.BAAL_AND_VAULT_SUMMONER)
            .summonBaalAndVault(initParams, actions, saltNonce, bytes32(0), VAULT_NAME);

        // 4. Resolve the rest from getters; FAIL CLOSED if the predicted main Safe is wrong.
        address juniorTrancheSafe = IBaal(baal).avatar();
        if (predictedMainSafe != juniorTrancheSafe) revert MainSafeMismatch(predictedMainSafe, juniorTrancheSafe);

        s = Substrate({
            baal: baal,
            juniorTrancheSafe: juniorTrancheSafe,
            juniorTrancheSidecar: juniorTrancheSidecar,
            loot: IBaal(baal).lootToken(),
            shares: IBaal(baal).sharesToken()
        });

        // 5. Assert the main-Safe admin injection landed (effect, never just "didn't revert").
        if (!ISafe(juniorTrancheSafe).isOwner(teamMultisig)) revert TeamOwnerNotSet(juniorTrancheSafe);
    }

    /// @notice Predict the main Safe address the summoner will deploy for `saltNonce`.
    /// @dev Safe 1.3.0 `createProxyWithNonce(gnosisSingleton, "", saltNonce)` (BaalSummoner.sol:231-237,314).
    /// Reads `proxyCreationCode()` from the live factory and `gnosisSingleton()` from the live summoner — never
    /// hardcoded. The factory is `SAFE_PROXY_FACTORY_1_3_0` (the summoner's factory field is internal/no getter);
    /// the `_summon` compute==avatar assert fails closed on any factory mismatch.
    function computeMainSafe(uint256 saltNonce) public view returns (address) {
        address factory = BaseAddresses.BAAL_SAFE_PROXY_FACTORY;
        address singleton = IBaalSummoner(BaseAddresses.BAAL_SUMMONER).gnosisSingleton();
        bytes memory creationCode = ISafeProxyFactory(factory).proxyCreationCode();
        bytes32 salt = keccak256(abi.encodePacked(keccak256(bytes("")), saltNonce));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(creationCode, abi.encode(uint256(uint160(singleton)))));
        return vm.computeCreate2Address(salt, initCodeHash, factory);
    }

    function _buildInitActions(address juniorTrancheSafe, address teamMultisig)
        internal
        pure
        returns (bytes[] memory actions)
    {
        address[] memory none = new address[](0);
        uint256[] memory noneAmt = new uint256[](0);

        bytes memory governanceConfig = abi.encode(
            VOTING_PERIOD, GRACE_PERIOD, PROPOSAL_OFFERING, QUORUM_PERCENT, SPONSOR_THRESHOLD, MIN_RETENTION_PERCENT
        );

        actions = new bytes[](6);
        // 1. confirm Loot/Shares paused (already paused by deployTokens; no-op confirm of soulbound-from-genesis).
        actions[0] = abi.encodeWithSelector(IBaal.setAdminConfig.selector, true, true);
        // 2. permanently-inert governance.
        actions[1] = abi.encodeWithSelector(IBaal.setGovernanceConfig.selector, governanceConfig);
        // 3. no shaman at summon (the Exit Gate gets manager(2) later via the team-admin signer).
        actions[2] = abi.encodeWithSelector(IBaal.setShamans.selector, none, noneAmt);
        // 4. zero Shares forever (ragequit purity + governance inertness).
        actions[3] = abi.encodeWithSelector(IBaal.mintShares.selector, none, noneAmt);
        // 5. zero Loot at summon (genesis seed happens later via the Gate once it holds manager).
        actions[4] = abi.encodeWithSelector(IBaal.mintLoot.selector, none, noneAmt);
        // 6. THE authority injection: add the team multisig as a main-Safe owner/signer (threshold stays 1).
        //    executeAsBaal calls AS the Baal, so route through the Safe's self-authorized owner-management.
        actions[5] = abi.encodeWithSelector(
            IBaal.executeAsBaal.selector, juniorTrancheSafe, uint256(0), _selfAddOwnerPayload(juniorTrancheSafe, teamMultisig)
        );
    }

    /// @dev `execTransactionFromModule(safe, 0, addOwnerWithThreshold(team,1), Call)` — the Baal (an enabled module
    /// on `safe`) makes `safe` call its own `addOwnerWithThreshold` (Safe self-auth).
    function _selfAddOwnerPayload(address safe, address teamMultisig) internal pure returns (bytes memory) {
        bytes memory addOwner = abi.encodeWithSelector(ISafe.addOwnerWithThreshold.selector, teamMultisig, uint256(1));
        return abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, safe, uint256(0), addOwner, uint8(0));
    }

    /// @dev Team (caller, an owner of `juniorTrancheSafe`) drives the main Safe via the owner `execTransaction` path to reach
    /// the juniorTrancheSidecar through the Baal. Pre-validated single-owner signature (v=1, no ECDSA) since msg.sender == team.
    function _addOwnerToJuniorTrancheSidecar(address baal, address juniorTrancheSafe, address juniorTrancheSidecar, address teamMultisig) internal {
        bytes memory execAsBaal = abi.encodeWithSelector(
            IBaal.executeAsBaal.selector, juniorTrancheSidecar, uint256(0), _selfAddOwnerPayload(juniorTrancheSidecar, teamMultisig)
        );
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(teamMultisig))), bytes32(0), uint8(1));
        ISafe(juniorTrancheSafe).execTransaction(
            baal, 0, execAsBaal, 0, 0, 0, 0, address(0), payable(address(0)), sig
        );
    }
}
