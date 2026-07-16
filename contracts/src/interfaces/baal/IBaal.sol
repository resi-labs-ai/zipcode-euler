// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @notice Minimal local interface for a Baal (Moloch v3) DAO.
/// Source contract: Baal DAO master copy/template @ Base 0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4
/// (`BaseAddresses.BAAL_SINGLETON`; per-DAO clones delegatecall to it — where ExitGate's calls dispatch).
/// CORRECTED 2026-06-22 (InterfaceSelectorDrift fork check): the prior `0xD69e5B8F…` is the SUMMONER impl,
/// not the Baal — the IBaal selectors (executeAsBaal/ragequit/sharesToken/…) are absent there and live on
/// the template above (verified against live Base bytecode). VERIFIED 2026-06-06 against vendored
/// reference/Baal/contracts/Baal.sol: ragequit (L619-624), setShamans (L686-688),
/// mintLoot (L814), burnLoot (L834), public state-vars lootToken/sharesToken (L29-30),
/// shamans mapping (L47), avatar (Zodiac Module base). All signatures match as-written.
interface IBaal {
    function ragequit(address to, uint256 sharesToBurn, uint256 lootToBurn, address[] calldata tokens) external;

    function mintLoot(address[] calldata to, uint256[] calldata amount) external;

    function burnLoot(address[] calldata from, uint256[] calldata amount) external;

    function setShamans(address[] calldata _shamans, uint256[] calldata _permissions) external;

    function mintShares(address[] calldata to, uint256[] calldata amount) external;

    function setAdminConfig(bool pauseShares, bool pauseLoot) external;

    function setGovernanceConfig(bytes calldata _governanceConfig) external;

    /// @dev Execute arbitrary code AS the Baal (raw `_to.call{value}(_data)`); baalOnly (avatar). Baal.sol:601.
    function executeAsBaal(address _to, uint256 _value, bytes calldata _data) external;

    /// @dev Governance proposal lifecycle (used only to PROVE inertness in tests).
    function submitProposal(bytes calldata proposalData, uint32 expiration, uint256 baalGas, string calldata details)
        external
        payable
        returns (uint256);

    function sponsorProposal(uint32 id) external;

    function processProposal(uint32 id, bytes calldata proposalData) external;

    /// @dev public state-var getters
    function lootToken() external view returns (address);

    function sharesToken() external view returns (address);

    function avatar() external view returns (address);

    function target() external view returns (address);

    function shamans(address shaman) external view returns (uint256 permissionLevel);

    function totalShares() external view returns (uint256);

    function totalLoot() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function quorumPercent() external view returns (uint256);

    function sponsorThreshold() external view returns (uint256);

    function proposalOffering() external view returns (uint256);

    function votingPeriod() external view returns (uint32);

    function gracePeriod() external view returns (uint32);

    function adminLock() external view returns (bool);

    function managerLock() external view returns (bool);

    function governorLock() external view returns (bool);
}
