// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";
import {IStakingV2, IAddressMapping} from "../interfaces/bridge/ISubtensorPrecompiles.sol";

/// @title SzAlpha — the self-built xALPHA liquid-staking wrapper (Bittensor 964).
/// @notice An upgradeable 18-dp ERC-20 liquid-staking receipt over the Subtensor StakingV2 precompile,
///         pointed at OUR validator on OUR subnet (the Zipcode subnet). It is the token the M1 szipUSD
///         basket holds (the zipUSD/xALPHA Hydrex LP leg) and the one CRE-03 marks via `exchangeRate()`.
///
/// @dev POOLED-STAKER MODEL (the central architecture decision). The *wrapper itself* is the single
///      staker: all deposited alpha is staked under the wrapper's own coldkey (derived once at init via
///      AddressMapping `0x80c`). There is NO per-user SS58 mapping — users hold fungible szALPHA shares;
///      the wrapper holds the aggregate stake. A structural consequence: because Subtensor attributes
///      stake to the *caller's* coldkey, a third party CANNOT add to the wrapper's backing stake, so the
///      classic ERC-4626 donation/inflation attack is structurally inapplicable. The OZ virtual-offset
///      (virtualShares=1 / virtualAssets=1) below is retained anyway for div-by-zero safety + a clean
///      genesis 1:1 rate (see the anti-dilution note on `_previewDeposit`).
///
/// @dev TWO DISTINCT MINT PATHS, gated separately (NEVER one public `mint(amount)`):
///        - `deposit(amount)` (payable): the user staking leg — mints shares ONLY against verified added
///          stake; open to anyone; does NOT touch the CCT mint role.
///        - `mint`/`burn`: the CCT cross-chain leg — callable ONLY by the wired `ccipPool`; moves existing
///          supply across the CCIP lane; never touches stake.
///
/// @dev AUTHORITY: `owner()` (the OZ Ownable upgrade authority) is the TimelockController from genesis —
///      it gates `_authorizeUpgrade` + pause. `ccipAdmin` is a SEPARATE, lower-privilege registrar role
///      (returned by `getCCIPAdmin()`) that performs the one-time CCIP registration/pool wiring; it has
///      no mint, no upgrade, no fund power. `ccipPool` (the only mint/burn caller) is set ONCE.
contract SzAlpha is
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IXAlphaRate
{
    using Math for uint256;

    // --- Subtensor precompiles (constants) ---
    address internal constant STAKING_V2 = 0x0000000000000000000000000000000000000805;
    address internal constant ADDRESS_MAPPING = 0x000000000000000000000000000000000000080C;

    // --- OZ ERC-4626 virtual-offset anti-dilution constants (see _previewDeposit) ---
    uint256 internal constant VIRTUAL_SHARES = 1;
    uint256 internal constant VIRTUAL_STAKE = 1;

    // --- Config (set at initialize, UUPS) ---
    uint256 public netuid; // slot
    bytes32 public validatorHotkey;
    bytes32 public wrapperColdkey; // derived once at init, cached
    address public ccipPool; // the SOLE mint/burn caller; set once
    address public ccipAdmin; // the CCIP registrar (getCCIPAdmin); != owner

    /// @dev Storage gap for future upgrades (UUPS). 50 - 5 used slots = 45.
    uint256[45] private __gap;

    // --- Events ---
    event Deposited(address indexed user, uint256 amountIn, uint256 sharesOut);
    event Redeemed(address indexed user, uint256 sharesIn, uint256 alphaOut);
    event CcipPoolSet(address indexed pool);
    event CcipAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // --- Errors ---
    error ZeroAmount();
    error ZeroAddress();
    error ValueMismatch(uint256 sent, uint256 expected);
    error AddStakeEffectMissing();
    error RemoveStakeEffectMissing();
    error PrecompileCallFailed();
    error PoolAlreadySet();
    error NotCcipPool();
    error NotCcipAdmin();
    error NativeTransferFailed();

    modifier onlyCcipPool() {
        if (msg.sender != ccipPool) revert NotCcipPool();
        _;
    }

    modifier onlyCcipAdmin() {
        if (msg.sender != ccipAdmin) revert NotCcipAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param name_ token name.
    /// @param symbol_ token symbol.
    /// @param netuid_ our registered subnet id (deploy-time fixture).
    /// @param validatorHotkey_ our validator hotkey, SS58 pubkey (deploy-time fixture).
    /// @param owner_ the TimelockController (upgrade + pause authority) — set from genesis, never a bare EOA.
    /// @param ccipAdmin_ the CCIP registrar (registers the token + sets the pool once); != owner.
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 netuid_,
        bytes32 validatorHotkey_,
        address owner_,
        address ccipAdmin_
    ) external initializer {
        if (owner_ == address(0) || ccipAdmin_ == address(0)) revert ZeroAddress();
        if (validatorHotkey_ == bytes32(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        netuid = netuid_;
        validatorHotkey = validatorHotkey_;
        ccipAdmin = ccipAdmin_;

        // Derive + cache the wrapper's own coldkey ONCE (pooled-staker; immutable thereafter).
        wrapperColdkey = _readColdkey(address(this));

        emit CcipAdminTransferred(address(0), ccipAdmin_);
    }

    // ================================================================
    // │                    User staking leg (964)                    │
    // ================================================================

    /// @notice Stake `amount` of native alpha and mint szALPHA shares to the caller.
    /// @dev `msg.value` must equal `amount` (native value carries the alpha on the Subtensor EVM, per
    ///      `stakeV2.sol`). Shares are minted against the verified added stake (S4 effect-check). Pausable.
    function deposit(uint256 amount) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert ValueMismatch(msg.value, amount);

        uint256 stakeBefore = _readStake();
        uint256 supplyBefore = totalSupply();

        // Interaction: stake via the precompile (low-level; a typed call never reaches the runtime).
        _callStaking(abi.encodeWithSelector(IStakingV2.addStake.selector, validatorHotkey, amount, netuid));

        // S4: verify the observable effect — the stake MUST have risen by >= the deposited amount, else
        // a silent precompile failure would be fund loss (alpha accepted, no backing stake).
        uint256 stakeAfter = _readStake();
        if (stakeAfter < stakeBefore + amount) revert AddStakeEffectMissing();

        shares = _previewDeposit(amount, supplyBefore, stakeBefore);
        if (shares == 0) revert ZeroAmount();
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Burn `shares` szALPHA and return the proportional native alpha to the caller.
    /// @dev NEVER pausable (S3/S11): the token's value is NAV-anchored to redeemability; dTAO has no
    ///      unbonding (immediate, slippage-only). CEI: compute -> burn -> unstake -> pay.
    function redeem(uint256 shares) external nonReentrant returns (uint256 alphaOut) {
        if (shares == 0) revert ZeroAmount();

        uint256 supplyBefore = totalSupply();
        uint256 stakeBefore = _readStake();
        alphaOut = _previewRedeem(shares, supplyBefore, stakeBefore);
        if (alphaOut == 0) revert ZeroAmount();

        // Effect: burn the caller's shares first (CEI).
        _burn(msg.sender, shares);

        uint256 balBefore = address(this).balance;

        // Interaction: unstake via the precompile.
        _callStaking(abi.encodeWithSelector(IStakingV2.removeStake.selector, validatorHotkey, alphaOut, netuid));

        // S4: verify BOTH the stake fell and the native balance rose by >= alphaOut.
        uint256 stakeAfter = _readStake();
        if (stakeBefore < stakeAfter + alphaOut) revert RemoveStakeEffectMissing();
        if (address(this).balance < balBefore + alphaOut) revert RemoveStakeEffectMissing();

        // Interaction: pay the caller.
        (bool ok,) = payable(msg.sender).call{value: alphaOut}("");
        if (!ok) revert NativeTransferFailed();

        emit Redeemed(msg.sender, shares, alphaOut);
    }

    // ================================================================
    // │                  Exchange rate (IXAlphaRate)                 │
    // ================================================================

    /// @inheritdoc IXAlphaRate
    /// @notice Alpha-per-szALPHA, 18-dp (`1e18` == 1:1). Read live from the precompile — NO DEX/oracle in
    ///         the path, so validator rewards (which lift `totalStaked`) accrue here non-manipulably.
    /// @dev CRE-03 (`8x-02`) annualizes the GROWTH of this value off-chain; the absolute scale is not an
    ///      on-chain concern. Uses the same virtual offset as the share math for internal consistency.
    function exchangeRate() external view returns (uint256) {
        return (_readStake() + VIRTUAL_STAKE).mulDiv(1e18, totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice The wrapper's current aggregate backing stake (alpha), read live from StakingV2.
    function totalStaked() external view returns (uint256) {
        return _readStake();
    }

    /// @notice Preview the shares minted for a `amount` deposit at the current rate.
    function previewDeposit(uint256 amount) external view returns (uint256) {
        return _previewDeposit(amount, totalSupply(), _readStake());
    }

    /// @notice Preview the alpha returned for redeeming `shares` at the current rate.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _previewRedeem(shares, totalSupply(), _readStake());
    }

    // ================================================================
    // │                  CCT cross-chain leg (CCIP)                  │
    // ================================================================

    /// @notice Mint bridged supply on this chain. CCT leg — callable ONLY by `ccipPool`. Pausable (S11).
    function mint(address account, uint256 amount) external onlyCcipPool whenNotPaused {
        _mint(account, amount);
    }

    /// @notice Burn bridged supply held by the pool. CCT leg — callable ONLY by `ccipPool`. NOT pausable.
    function burn(uint256 amount) external onlyCcipPool {
        _burn(msg.sender, amount);
    }

    /// @notice Burn `amount` from `account` (allowance-spending). CCT leg — `ccipPool` only.
    function burnFrom(address account, uint256 amount) public onlyCcipPool {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @notice Alias of `burnFrom` (older CCIP naming). CCT leg — `ccipPool` only.
    function burn(address account, uint256 amount) external {
        burnFrom(account, amount);
    }

    /// @notice One-time wiring of the CCT pool as the SOLE mint/burn caller.
    /// @dev Named to match the canonical `BurnMintERC20.grantMintAndBurnRoles` so the deploy script is
    ///      uniform across both tokens. Gated to `ccipAdmin` (the registrar), set-once.
    function grantMintAndBurnRoles(address pool) external onlyCcipAdmin {
        if (pool == address(0)) revert ZeroAddress();
        if (ccipPool != address(0)) revert PoolAlreadySet();
        ccipPool = pool;
        emit CcipPoolSet(pool);
    }

    /// @notice The CCIP admin (registrar) — consumed by `registerAdminViaGetCCIPAdmin`.
    function getCCIPAdmin() external view returns (address) {
        return ccipAdmin;
    }

    /// @notice Transfer the CCIP registrar role (e.g. to the timelock/multisig post-wiring). `ccipAdmin` only.
    function setCCIPAdmin(address newAdmin) external onlyCcipAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit CcipAdminTransferred(ccipAdmin, newAdmin);
        ccipAdmin = newAdmin;
    }

    // ================================================================
    // │                       Admin (owner)                          │
    // ================================================================

    /// @notice Pause the mint paths (deposit + CCT mint). Redeem stays available. Owner (timelock) only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause. Owner (timelock) only.
    function unpause() external onlyOwner {
        _unpause();
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @dev UUPS upgrade authority = owner (the TimelockController).
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ================================================================
    // │                         Internals                            │
    // ================================================================

    /// @dev OZ ERC-4626 minimum-shares (virtual-offset) convention: shares = amount * (supply + 1) /
    ///      (stake + 1), rounded DOWN. Replaces the ticket's "mint 1e3 dead shares to address(0)", which
    ///      is impossible in OZ (`_mint` to address(0) reverts) and would not prevent div-by-zero. The
    ///      virtual offset: (a) never divides by zero (denominator >= 1), (b) yields a clean 1:1 genesis
    ///      (supply=stake=0 -> shares=amount), (c) rounds in the protocol's favor. See report 8x-01.
    function _previewDeposit(uint256 amount, uint256 supply, uint256 stake) internal pure returns (uint256) {
        return amount.mulDiv(supply + VIRTUAL_SHARES, stake + VIRTUAL_STAKE, Math.Rounding.Floor);
    }

    /// @dev Inverse of `_previewDeposit`, rounded DOWN (dust is the redeemer's loss, never a gain).
    function _previewRedeem(uint256 shares, uint256 supply, uint256 stake) internal pure returns (uint256) {
        return shares.mulDiv(stake + VIRTUAL_STAKE, supply + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    /// @dev Live `getStake(validatorHotkey, wrapperColdkey, netuid)` via staticcall.
    function _readStake() internal view returns (uint256) {
        (bool ok, bytes memory ret) = STAKING_V2.staticcall(
            abi.encodeWithSelector(IStakingV2.getStake.selector, validatorHotkey, wrapperColdkey, netuid)
        );
        if (!ok || ret.length < 32) revert PrecompileCallFailed();
        return abi.decode(ret, (uint256));
    }

    /// @dev Live `addressMapping(addr)` via staticcall (used once at init for the coldkey).
    function _readColdkey(address addr) internal view returns (bytes32) {
        (bool ok, bytes memory ret) =
            ADDRESS_MAPPING.staticcall(abi.encodeWithSelector(IAddressMapping.addressMapping.selector, addr));
        if (!ok || ret.length < 32) revert PrecompileCallFailed();
        return abi.decode(ret, (bytes32));
    }

    /// @dev Low-level state-changing precompile call (typed calls never reach the runtime precompile).
    function _callStaking(bytes memory data) internal {
        (bool ok,) = STAKING_V2.call(data);
        if (!ok) revert PrecompileCallFailed();
    }

    /// @dev Accept native alpha returned by `removeStake` (the precompile credits this contract).
    receive() external payable {}
}
