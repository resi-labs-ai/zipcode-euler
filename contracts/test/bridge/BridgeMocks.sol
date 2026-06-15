// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IBurnMintERC20} from "chainlink-ccip/interfaces/IBurnMintERC20.sol";

/// @notice Mock of the Subtensor StakingV2 precompile (etched at 0x805 in tests) — UNIT-FAITHFUL.
/// @dev Mirrors the live runtime semantics verified against Rubicon's LiquidStakedV3 (8x-01):
///       - `addStake(hotkey, amountRao, netuid)`: amount is TAO in rao (9-dp); the TAO is swapped to
///         alpha at `priceRaoPerAlpha` (TAO-rao per 1.0 alpha; 1e9 = par) — set off-par to exercise
///         the wrapper's measured-delta + slippage paths. The real runtime debits the caller's
///         substrate-mapped native balance; an EVM mock cannot pull native from its caller, so it only
///         ASSERTS sufficiency and skips the debit. Safe because the wrapper never reads its own
///         balance on the deposit path, and redeem measures a balance DELTA (leftover deposit TAO
///         cannot skew a delta).
///       - `removeStake(hotkey, alphaRao, netuid)`: amount is alpha 9-dp; pays the caller TAO (wei) at
///         the same price.
///       - `getStake` returns alpha 9-dp. Stake is attributed to the CALLER's coldkey (keccak of
///         msg.sender), mirroring HashedAddressMapping.
///      `addReward` raises stake with no caller action — it simulates BOTH validator emissions AND a
///      third-party `transferStake` donation (identical observable effect on the wrapper). The
///      `break*` toggles exercise the S4 effect-verification negatives (silent precompile failure).
contract MockSubtensorStaking {
    uint256 internal constant RAO = 1e9;

    // stake[hotkey][coldkey][netuid] — alpha, 9-dp
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stake;
    /// @notice TAO-rao per 1.0 alpha (1e9 = par; 2e9 = 1 alpha costs 2 TAO).
    uint256 public priceRaoPerAlpha = 1e9;
    bool public breakAddStake;
    bool public breakRemoveStake;

    function _coldkeyOf(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(a));
    }

    function setPrice(uint256 raoPerAlpha) external {
        priceRaoPerAlpha = raoPerAlpha;
    }

    function setBreakAddStake(bool v) external {
        breakAddStake = v;
    }

    function setBreakRemoveStake(bool v) external {
        breakRemoveStake = v;
    }

    /// @dev `amountRao` = TAO in rao (9-dp). Swaps TAO -> alpha at the configured price.
    function addStake(bytes32 hotkey, uint256 amountRao, uint256 netuid) external payable {
        if (breakAddStake) return; // silent no-op: getStake will NOT rise -> wrapper must revert
        // The real runtime debits the caller's substrate balance; assert sufficiency only (see header).
        require(msg.sender.balance >= amountRao * RAO, "insufficient TAO");
        stake[hotkey][_coldkeyOf(msg.sender)][netuid] += amountRao * RAO / priceRaoPerAlpha;
    }

    /// @dev `alphaRao` = alpha 9-dp. Swaps alpha -> TAO at the configured price, pays the caller wei.
    function removeStake(bytes32 hotkey, uint256 alphaRao, uint256 netuid) external payable {
        if (breakRemoveStake) return; // silent no-op: getStake/balance will NOT change
        bytes32 ck = _coldkeyOf(msg.sender);
        require(stake[hotkey][ck][netuid] >= alphaRao, "insufficient stake");
        stake[hotkey][ck][netuid] -= alphaRao;
        uint256 taoOutWei = (alphaRao * priceRaoPerAlpha / RAO) * RAO; // rao -> wei
        (bool ok,) = payable(msg.sender).call{value: taoOutWei}("");
        require(ok, "pay failed");
    }

    /// @return The staked alpha in 9-dp units.
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return stake[hotkey][coldkey][netuid];
    }

    /// @notice Raise backing stake with no share mint (9-dp alpha): validator rewards — or, identically
    ///         observable, a third-party `transferStake` DONATION to the wrapper's coldkey.
    function addReward(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        stake[hotkey][coldkey][netuid] += alphaRao;
    }

    /// @notice Simulate a slash (lowers backing stake; 9-dp alpha).
    function slash(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        stake[hotkey][coldkey][netuid] -= alphaRao;
    }

    receive() external payable {}
}

/// @notice Mock of the Alpha precompile (etched at 0x808) — the AMM quoting surface (IAlpha, 8x-01).
/// @dev Decimals mirror the real precompile: sims are 9-dp in/out; price getters are 18-dp. Quotes use
///      the same `priceRaoPerAlpha` convention as `MockSubtensorStaking` — etched bytecode does NOT
///      share storage, so tests must `setPrice` on BOTH mocks to keep previews and execution coherent.
contract MockAlphaPrecompile {
    uint256 internal constant RAO = 1e9;

    /// @notice TAO-rao per 1.0 alpha (1e9 = par) — keep in sync with the staking mock's price.
    uint256 public priceRaoPerAlpha = 1e9;

    function setPrice(uint256 raoPerAlpha) external {
        priceRaoPerAlpha = raoPerAlpha;
    }

    /// @return 18-dp TAO per 1.0 alpha (rao price scaled x1e9, as the runtime does).
    function getAlphaPrice(uint16) external view returns (uint256) {
        return priceRaoPerAlpha * RAO;
    }

    /// @return 18-dp TAO per 1.0 alpha (the mock's EMA equals spot).
    function getMovingAlphaPrice(uint16) external view returns (uint256) {
        return priceRaoPerAlpha * RAO;
    }

    /// @param taoRao TAO in, 9-dp. @return alpha out, 9-dp.
    function simSwapTaoForAlpha(uint16, uint64 taoRao) external view returns (uint256) {
        return uint256(taoRao) * RAO / priceRaoPerAlpha;
    }

    /// @param alphaRao alpha in, 9-dp. @return TAO out, 9-dp (rao).
    function simSwapAlphaForTao(uint16, uint64 alphaRao) external view returns (uint256) {
        return uint256(alphaRao) * priceRaoPerAlpha / RAO;
    }
}

/// @notice Mock of the AddressMapping precompile (etched at 0x80C).
contract MockAddressMapping {
    bool public flipped;

    function setFlipped(bool v) external {
        flipped = v;
    }

    function addressMapping(address target) external view returns (bytes32) {
        // After `flipped`, return a DIFFERENT value to prove the wrapper cached its coldkey at init (S5).
        return flipped ? keccak256(abi.encode(target, "flipped")) : keccak256(abi.encode(target));
    }
}

/// @notice Mock CCIP Router exposing getOnRamp/isOffRamp (the pool's ramp gating) + typeAndVersion
///         (the deploy script's 5-address `_assertCctAddresses` probe — see SzAlphaAdminHandoffTest).
contract MockRouter {
    mapping(uint64 => address) public onRamp;
    mapping(uint64 => mapping(address => bool)) public offRamp;

    /// @dev Must match `CctConfig.expRouter` so `_assertCctAddresses` passes when etched at the router slot.
    function typeAndVersion() external pure returns (string memory) {
        return "Router 1.2.0";
    }

    function setOnRamp(uint64 sel, address r) external {
        onRamp[sel] = r;
    }

    function setOffRamp(uint64 sel, address r, bool ok) external {
        offRamp[sel][r] = ok;
    }

    function getOnRamp(uint64 sel) external view returns (address) {
        return onRamp[sel];
    }

    function isOffRamp(uint64 sel, address r) external view returns (bool) {
        return offRamp[sel][r];
    }
}

/// @notice Mock RMN (ARMProxy) exposing isCursed (the pool's curse gate).
contract MockRMN {
    bool public cursed;

    function setCursed(bool v) external {
        cursed = v;
    }

    function isCursed() external view returns (bool) {
        return cursed;
    }

    function isCursed(bytes16) external view returns (bool) {
        return cursed;
    }
}

/// @notice A 6-dp BurnMint-ish token to prove the pools' 18-dp constructor guards (works as plain
///         IERC20 for the lock/release pool too).
contract Mock6DecimalToken is IBurnMintERC20 {
    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address, uint256) external {}
    function burn(uint256) external {}
    function burn(address, uint256) external {}
    function burnFrom(address, uint256) external {}

    // IERC20 surface (unused).
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal `getCCIPAdmin()` surface (the registrar identity the module reads). The real SzAlpha /
///      SzAlphaMirror both expose this; the mock module calls it via this interface.
interface IGetCCIPAdminMock {
    function getCCIPAdmin() external view returns (address);
}

/// @notice Mock CCIP `TokenAdminRegistry` (SEC-03/H4) — UNIT-FAITHFUL to the reference at
///         `reference/chainlink-ccip/chains/evm/contracts/tokenAdminRegistry/TokenAdminRegistry.sol`.
/// @dev Records `administrator`/`pendingAdministrator`/`tokenPool`, enforces `onlyTokenAdmin` on
///      `setPool`/`transferAdminRole`, and implements the 2-step `proposeAdministrator` (registry-module
///      only) -> `acceptAdminRole` (pending only) -> `transferAdminRole` (admin only) -> `acceptAdminRole`
///      lifecycle exactly as the reference. `typeAndVersion` is a `constant` so it survives `vm.etch` at the
///      hard-coded CCT address the deploy script reads (etch copies code, NOT storage). Skips the reference's
///      `isSupportedToken` pool-support check (not needed to exercise the admin-slot handoff).
contract MockTokenAdminRegistry {
    error OnlyAdministrator(address sender, address token);
    error OnlyPendingAdministrator(address sender, address token);
    error OnlyRegistryModuleOrOwner(address sender);

    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    string public constant typeAndVersion = "TokenAdminRegistry 1.5.0";

    mapping(address token => TokenConfig) internal s_config;
    mapping(address module => bool) public isRegistryModule;

    /// @notice Test helper: authorize a module to call `proposeAdministrator`.
    function addRegistryModule(address module) external {
        isRegistryModule[module] = true;
    }

    /// @dev Reference `proposeAdministrator`: registry-module (or owner) gated; sets the pending admin on a
    ///      fresh token. Kept lenient on the owner branch (no owner in the mock) but module-gated.
    function proposeAdministrator(address localToken, address administrator) external {
        if (!isRegistryModule[msg.sender]) revert OnlyRegistryModuleOrOwner(msg.sender);
        s_config[localToken].pendingAdministrator = administrator;
    }

    function acceptAdminRole(address localToken) external {
        TokenConfig storage c = s_config[localToken];
        if (c.pendingAdministrator != msg.sender) revert OnlyPendingAdministrator(msg.sender, localToken);
        c.administrator = msg.sender;
        c.pendingAdministrator = address(0);
    }

    function setPool(address localToken, address pool) external onlyTokenAdmin(localToken) {
        s_config[localToken].tokenPool = pool;
    }

    function transferAdminRole(address localToken, address newAdmin) external onlyTokenAdmin(localToken) {
        s_config[localToken].pendingAdministrator = newAdmin;
    }

    function getPool(address token) external view returns (address) {
        return s_config[token].tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return s_config[token];
    }

    modifier onlyTokenAdmin(address token) {
        if (s_config[token].administrator != msg.sender) revert OnlyAdministrator(msg.sender, token);
        _;
    }
}

/// @notice Mock CCIP `RegistryModuleOwnerCustom` (SEC-03/H4) — mirrors the reference at
///         `reference/chainlink-ccip/.../RegistryModuleOwnerCustom.sol`: `registerAdminViaGetCCIPAdmin`
///         reads the token's `getCCIPAdmin()`, requires it == `msg.sender` (self-registration), then calls
///         `proposeAdministrator` on the registry.
/// @dev The registry is `immutable` so it survives `vm.etch` (immutables are baked into runtime code).
///      Construct the instance pointing at the etched registry address, then etch its code at the module slot.
///      `typeAndVersion` is `constant` for the same etch-survival reason.
contract MockRegistryModuleOwnerCustom {
    error CanOnlySelfRegister(address admin, address token);

    string public constant typeAndVersion = "RegistryModuleOwnerCustom 1.6.0";

    MockTokenAdminRegistry internal immutable i_registry;

    constructor(MockTokenAdminRegistry registry) {
        i_registry = registry;
    }

    function registerAdminViaGetCCIPAdmin(address token) external {
        address admin = IGetCCIPAdminMock(token).getCCIPAdmin();
        if (admin != msg.sender) revert CanOnlySelfRegister(admin, token);
        i_registry.proposeAdministrator(token, admin);
    }
}

/// @notice Mock `TokenPoolFactory` — only the `typeAndVersion` the deploy `_assertCctAddresses` probe reads
///         (`constant`, survives `vm.etch`). The factory is never otherwise called by deploy964/deployBase.
contract MockTokenPoolFactory {
    string public constant typeAndVersion = "TokenPoolFactory 1.5.1";
}
