// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IXAlphaRate} from "../interfaces/bridge/IXAlphaRate.sol";
import {IStakingV2, IAlpha, IAddressMapping} from "../interfaces/bridge/ISubtensorPrecompiles.sol";

/// @title SzAlpha — the self-built xALPHA liquid-staking wrapper (Bittensor 964).
/// @notice An upgradeable 18-dp ERC-20 liquid-staking receipt over the Subtensor StakingV2 precompile,
///         pointed at OUR validator on OUR subnet (the Zipcode subnet). It is the token the M1 szipUSD
///         basket holds (the zipUSD/xALPHA Hydrex LP leg) and the one CRE-03 marks via `exchangeRate()`.
///         The flow mirrors the audited production precedent (Rubicon `LiquidStakedV3`, see
///         `reference/rubicon/`): TAO in, alpha-denominated backing, TAO out.
///
/// @dev UNIT TABLE (the load-bearing convention; see `ISubtensorPrecompiles` for the runtime facts):
///        - msg.value / native payouts:  TAO, 18-dp wei.
///        - precompile stake amounts:    addStake takes TAO in rao (9-dp); removeStake takes alpha 9-dp;
///                                       getStake returns alpha 9-dp. 1 TAO = 1e9 rao = 1e18 wei.
///        - shares (this token):         18-dp. All share math runs in 18-dp space via `_stake18()`
///                                       (= getStake x 1e9), so `exchangeRate()` stays 18-dp
///                                       alpha-per-szALPHA (1e18 == 1:1) for CRE/NAV consumers.
///        - deposits swap TAO -> alpha through the subnet AMM at a VARIABLE price: shares are minted
///          against the MEASURED stake delta (never against msg.value); redemptions pay the MEASURED
///          TAO balance delta. Both legs take user slippage bounds (minSharesOut / minTaoOut).
///
/// @dev POOLED-STAKER MODEL. The *wrapper itself* is the single staker: all deposited value is staked
///      under the wrapper's own coldkey (derived once at init via AddressMapping `0x80C`). There is NO
///      per-user SS58 mapping — users hold fungible szALPHA shares; the wrapper holds the aggregate stake.
///
/// @dev DONATIONS (honest version — replaces an earlier, wrong "structurally inapplicable" claim).
///      Subtensor's `transferStake` lets a third party attribute staked alpha to the wrapper's coldkey,
///      so the backing CAN be raised externally. Consequences under measured-delta minting + floor
///      rounding + the `ZeroSharesOut` guard:
///        - a donation only raises `exchangeRate()` — a pure, irrecoverable gift to existing holders
///          (the donor holds no claim on it);
///        - the classic first-depositor inflation attack is strictly value-destroying: to skew a victim
///          depositing V the attacker must donate >= V, all of which accrues to others, and a deposit
///          rounding to zero shares reverts (`ZeroSharesOut`) rather than silently losing funds;
///        - `deploy964` makes a small SEED DEPOSIT in-broadcast at genesis (BRIDGE-ADV-02), closing the
///          griefing window STRUCTURALLY (not a manual step); and a non-zero `minSharesOut` is mandatory
///          for every non-genesis deposit (the seed, at supply 0, is the one exempt caller).
///      The OZ virtual-offset (1/1) is retained for div-by-zero safety + a clean genesis 1:1 rate.
///
/// @dev CCIP/CCT TOPOLOGY (lock/release — the proven Rubicon shape). Bridged-out szALPHA is LOCKED in
///      the 964 `SzAlphaLockReleasePool` (+ `ERC20LockBox`), never burned — so `totalSupply()` keeps
///      counting it and `exchangeRate()` stays truthful while supply circulates on Base. (Burn-on-source
///      would shrink local supply against unchanged stake, inflating the rate and letting 964 redeemers
///      drain the backing of Base holders.) This wrapper therefore exposes NO pool mint/burn surface;
///      the only CCIP-facing role is `ccipAdmin` (the TokenAdminRegistry registrar via `getCCIPAdmin`).
///
/// @dev AUTHORITY: `owner()` (the OZ Ownable upgrade authority) is the TimelockController from genesis —
///      it gates `_authorizeUpgrade` + pause. `ccipAdmin` is a SEPARATE, lower-privilege registrar role
///      (returned by `getCCIPAdmin()`); it has no mint, no upgrade, no fund power.
///
/// @dev v2 candidate (deliberately out of scope): a `getMovingAlphaPrice`-based EMA view for NAV-grade
///      pricing; the previews below use the spot `simSwap*` quotes (advisory only).
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
    address internal constant ALPHA = 0x0000000000000000000000000000000000000808;
    address internal constant ADDRESS_MAPPING = 0x000000000000000000000000000000000000080C;

    /// @dev 1 TAO = 1e9 rao; alpha is 9-dp on-chain. Scales 9-dp precompile units <-> 18-dp share space.
    uint256 internal constant RAO = 1e9;

    // --- OZ ERC-4626 virtual-offset constants (18-dp space; see the donation note above) ---
    uint256 internal constant VIRTUAL_SHARES = 1;
    uint256 internal constant VIRTUAL_STAKE = 1;

    // --- Config (set at initialize, UUPS) ---
    uint256 public netuid; // slot (<= type(uint16).max, enforced at init — IAlpha takes uint16)
    bytes32 public validatorHotkey;
    bytes32 public wrapperColdkey; // derived once at init, cached
    address public ccipAdmin; // the CCIP registrar (getCCIPAdmin); != owner

    /// @dev Storage gap for future upgrades (UUPS). 50 - 4 used slots = 46.
    uint256[46] private __gap;

    // --- Events ---
    /// @param taoIn TAO actually staked (wei, 18-dp; excludes the refunded sub-rao remainder).
    /// @param alphaStakedRao alpha received from the AMM swap (9-dp) — the measured stake delta.
    event Deposited(address indexed user, uint256 taoIn, uint256 alphaStakedRao, uint256 sharesOut);
    /// @param alphaOutRao alpha unstaked (9-dp). @param taoOut TAO paid to the redeemer (wei, 18-dp).
    event Redeemed(address indexed user, uint256 sharesIn, uint256 alphaOutRao, uint256 taoOut);
    event CcipAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // --- Errors ---
    error ZeroAmount();
    error ZeroAddress();
    error ZeroSharesOut();
    error DeadlineExpired();
    error SlippageExceeded(uint256 actual, uint256 minOut);
    error SlippageFloorRequired();
    error NetuidTooLarge(uint256 netuid);
    error AmountOverflowsUint64(uint256 amountRao);
    error AddStakeEffectMissing();
    error RemoveStakeEffectMissing();
    error PrecompileCallFailed();
    error NotCcipAdmin();
    error NativeTransferFailed();

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
    /// @param netuid_ our registered subnet id (deploy-time fixture; must fit uint16 for IAlpha).
    /// @param validatorHotkey_ our validator hotkey, SS58 pubkey (deploy-time fixture).
    /// @param owner_ the TimelockController (upgrade + pause authority) — set from genesis, never a bare EOA.
    /// @param ccipAdmin_ the CCIP registrar (TokenAdminRegistry admin via getCCIPAdmin); != owner.
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
        if (netuid_ > type(uint16).max) revert NetuidTooLarge(netuid_);

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

    /// @notice Stake `msg.value` TAO and mint szALPHA shares against the alpha actually received.
    /// @dev Units: `msg.value` is wei; the precompile is fed `msg.value / 1e9` rao with NO attached
    ///      value (it debits this contract's substrate-mapped balance, which holds the sent TAO). The
    ///      sub-rao remainder (`msg.value % 1e9`) is refunded. The TAO -> alpha AMM conversion is
    ///      variable-price, so shares are minted against the MEASURED `getStake` delta at the
    ///      pre-deposit rate (S4: the delta must be > 0, else a silent precompile failure would be
    ///      fund loss). Slippage: caller MUST bound the mint with a non-zero `minSharesOut` — a 0 floor is
    ///      rejected (`SlippageFloorRequired`) EXCEPT at genesis (`totalSupply() == 0`), the only call that
    ///      cannot derive a floor (no rate yet) and is the deploy seed. `ZeroSharesOut` also applies. Pausable.
    /// @param minSharesOut Minimum shares acceptable (derive from `previewDeposit` minus tolerance).
    /// @param deadline Unix time after which the call reverts (`type(uint256).max` = none).
    function deposit(uint256 minSharesOut, uint256 deadline)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        // BRIDGE-ADV-02/03: a real caller MUST set a slippage floor. Only the genesis deposit
        // (supply 0 — the deploy seed, which has no rate to derive a floor from) may pass 0.
        if (minSharesOut == 0 && totalSupply() != 0) revert SlippageFloorRequired();
        uint256 amountRao = msg.value / RAO;
        if (amountRao == 0) revert ZeroAmount();
        uint256 refund = msg.value % RAO;

        uint256 stakeRaoBefore = _readStake();
        uint256 supplyBefore = totalSupply();

        // Interaction: stake via the precompile (low-level; a typed call never reaches the runtime).
        _callStaking(abi.encodeWithSelector(IStakingV2.addStake.selector, validatorHotkey, amountRao, netuid));

        // S4 (direction): the backing stake MUST have risen — the delta IS the alpha received.
        uint256 stakeRaoAfter = _readStake();
        if (stakeRaoAfter <= stakeRaoBefore) revert AddStakeEffectMissing();
        uint256 alphaDeltaRao = stakeRaoAfter - stakeRaoBefore;

        // Mint against the measured delta at the PRE-deposit rate (18-dp space).
        shares = _previewDeposit(alphaDeltaRao * RAO, supplyBefore, stakeRaoBefore * RAO);
        if (shares == 0) revert ZeroSharesOut();
        if (shares < minSharesOut) revert SlippageExceeded(shares, minSharesOut);
        _mint(msg.sender, shares);

        // Interaction (last, CEI): return the sub-rao remainder.
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert NativeTransferFailed();
        }

        emit Deposited(msg.sender, msg.value - refund, alphaDeltaRao, shares);
    }

    /// @notice Burn `shares` szALPHA, unstake the proportional alpha, and pay the caller the TAO the
    ///         alpha -> TAO AMM swap actually produced.
    /// @dev NEVER pausable (S3/S11): the token's value is NAV-anchored to redeemability; dTAO has no
    ///      unbonding (immediate, slippage-only). CEI: compute -> burn -> unstake -> measure -> pay.
    ///      S4: the stake must fall AND the native balance must rise; the payout is the MEASURED
    ///      balance delta (never the estimate). Sub-rao share dust (< 1e9 18-dp units of alpha) is
    ///      floored away and stays staked, accruing to remaining holders.
    /// @param minTaoOut Minimum TAO (wei) acceptable (derive from `previewRedeem` minus tolerance).
    /// @param deadline Unix time after which the call reverts (`type(uint256).max` = none).
    function redeem(uint256 shares, uint256 minTaoOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 taoOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (shares == 0) revert ZeroAmount();
        // BRIDGE-ADV-03: redeem always requires a real floor (supply is never 0 here — no genesis exemption).
        if (minTaoOut == 0) revert SlippageFloorRequired();

        uint256 stakeRaoBefore = _readStake();
        uint256 alphaOut18 = _previewRedeem(shares, totalSupply(), stakeRaoBefore * RAO);
        uint256 alphaOutRao = alphaOut18 / RAO; // floor: dust stays staked for remaining holders
        if (alphaOutRao == 0) revert ZeroAmount();

        // Effect: burn the caller's shares first (CEI).
        _burn(msg.sender, shares);

        uint256 balBefore = address(this).balance;

        // Interaction: unstake via the precompile (alpha -> TAO swap at the AMM price).
        _callStaking(abi.encodeWithSelector(IStakingV2.removeStake.selector, validatorHotkey, alphaOutRao, netuid));

        // S4 (direction + measured output): stake fell, and TAO landed in our native balance.
        if (_readStake() >= stakeRaoBefore) revert RemoveStakeEffectMissing();
        taoOut = address(this).balance - balBefore;
        if (taoOut == 0) revert RemoveStakeEffectMissing();
        if (taoOut < minTaoOut) revert SlippageExceeded(taoOut, minTaoOut);

        // Interaction: pay the caller the measured output.
        (bool ok,) = payable(msg.sender).call{value: taoOut}("");
        if (!ok) revert NativeTransferFailed();

        emit Redeemed(msg.sender, shares, alphaOutRao, taoOut);
    }

    // ================================================================
    // │                  Exchange rate (IXAlphaRate)                 │
    // ================================================================

    /// @inheritdoc IXAlphaRate
    /// @notice Alpha-per-szALPHA, 18-dp (`1e18` == 1:1). Read live from the precompile — NO DEX/oracle in
    ///         the path, so validator rewards (which lift the backing stake) accrue here non-manipulably.
    /// @dev CRE-03 (`8x-02`) annualizes the GROWTH of this value off-chain; the absolute scale is not an
    ///      on-chain concern. Stake is normalized to 18-dp (`_stake18`) so the rate's external semantics
    ///      are unchanged by the 9-dp precompile units. Bridged-out supply stays in `totalSupply()`
    ///      (lock/release — see the topology note), keeping this rate truthful across chains.
    function exchangeRate() external view returns (uint256) {
        return (_stake18() + VIRTUAL_STAKE).mulDiv(1e18, totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice The wrapper's aggregate backing alpha, normalized to 18-dp (raw precompile units are
    ///         9-dp rao-scale; this is `getStake x 1e9`).
    function totalStaked() external view returns (uint256) {
        return _stake18();
    }

    /// @notice Quote the shares a `taoWei` deposit would mint RIGHT NOW, via the Alpha precompile's
    ///         AMM swap simulation (fee-inclusive, size-aware) + the current share rate.
    /// @dev ADVISORY: a current-block estimate — the AMM price can move before execution; derive
    ///      `minSharesOut` from this minus a tolerance. Spot-based (manipulable in-block), so never
    ///      consume it for pricing funds on-chain; NAV reads `exchangeRate()` only.
    function previewDeposit(uint256 taoWei) external view returns (uint256 shares) {
        uint256 amountRao = taoWei / RAO;
        if (amountRao == 0) return 0;
        uint256 alphaOutRao = _simSwapTaoForAlpha(amountRao);
        return _previewDeposit(alphaOutRao * RAO, totalSupply(), _stake18());
    }

    /// @notice Quote the TAO (wei) redeeming `shares` would pay RIGHT NOW: exact share->alpha rate
    ///         math, then the Alpha precompile's alpha->TAO swap simulation.
    /// @dev ADVISORY, same caveats as `previewDeposit`; derive `minTaoOut` from this minus a tolerance.
    function previewRedeem(uint256 shares) external view returns (uint256 taoWei) {
        uint256 alphaOutRao = _previewRedeem(shares, totalSupply(), _stake18()) / RAO;
        if (alphaOutRao == 0) return 0;
        return _simSwapAlphaForTao(alphaOutRao) * RAO;
    }

    // ================================================================
    // │                  CCIP registrar (CCT, lock/release)          │
    // ================================================================

    /// @notice The CCIP admin (registrar) — consumed by `registerAdminViaGetCCIPAdmin`. The 964 pool is
    ///         lock/release: this token grants NO mint/burn to anything (see the topology note).
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

    /// @notice Pause deposits. Redeem stays available (S3/S11). Owner (timelock) only.
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

    /// @dev OZ ERC-4626 minimum-shares (virtual-offset) convention in 18-dp space: shares =
    ///      amount18 * (supply + 1) / (stake18 + 1), rounded DOWN. The virtual offset: (a) never
    ///      divides by zero, (b) yields a clean 1:1 genesis (supply=stake=0 -> shares=amount),
    ///      (c) rounds in the protocol's favor. See the donation note for why 1/1 suffices.
    function _previewDeposit(uint256 amount18, uint256 supply, uint256 stake18) internal pure returns (uint256) {
        return amount18.mulDiv(supply + VIRTUAL_SHARES, stake18 + VIRTUAL_STAKE, Math.Rounding.Floor);
    }

    /// @dev Inverse of `_previewDeposit`, rounded DOWN (dust is the redeemer's loss, never a gain).
    function _previewRedeem(uint256 shares, uint256 supply, uint256 stake18) internal pure returns (uint256) {
        return shares.mulDiv(stake18 + VIRTUAL_STAKE, supply + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    /// @dev Live `getStake(validatorHotkey, wrapperColdkey, netuid)` via staticcall. Returns 9-dp alpha.
    function _readStake() internal view returns (uint256) {
        (bool ok, bytes memory ret) = STAKING_V2.staticcall(
            abi.encodeWithSelector(IStakingV2.getStake.selector, validatorHotkey, wrapperColdkey, netuid)
        );
        if (!ok || ret.length < 32) revert PrecompileCallFailed();
        return abi.decode(ret, (uint256));
    }

    /// @dev The backing stake normalized to the 18-dp space all share math + the rate use.
    function _stake18() internal view returns (uint256) {
        return _readStake() * RAO;
    }

    /// @dev `simSwapTaoForAlpha(netuid, taoRao)` via staticcall. 9-dp in/out (see IAlpha).
    function _simSwapTaoForAlpha(uint256 taoRao) internal view returns (uint256) {
        if (taoRao > type(uint64).max) revert AmountOverflowsUint64(taoRao);
        (bool ok, bytes memory ret) = ALPHA.staticcall(
            abi.encodeWithSelector(IAlpha.simSwapTaoForAlpha.selector, uint16(netuid), uint64(taoRao))
        );
        if (!ok || ret.length < 32) revert PrecompileCallFailed();
        return abi.decode(ret, (uint256));
    }

    /// @dev `simSwapAlphaForTao(netuid, alphaRao)` via staticcall. 9-dp in/out (see IAlpha).
    function _simSwapAlphaForTao(uint256 alphaRao) internal view returns (uint256) {
        if (alphaRao > type(uint64).max) revert AmountOverflowsUint64(alphaRao);
        (bool ok, bytes memory ret) = ALPHA.staticcall(
            abi.encodeWithSelector(IAlpha.simSwapAlphaForTao.selector, uint16(netuid), uint64(alphaRao))
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

    /// @dev Accept native TAO credited by `removeStake` (the precompile pays this contract).
    receive() external payable {}
}
