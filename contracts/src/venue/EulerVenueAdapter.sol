// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IZipcodeVenue} from "./IZipcodeVenue.sol";
import {LineAccount} from "./LineAccount.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IERC4626 as IEVKERC4626} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerEarn, MarketAllocation} from "euler-earn/interfaces/IEulerEarn.sol";
import {IERC4626 as IOZERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title EulerVenueAdapter
/// @notice Config one (§4.7 #10): a per-line isolated-market FACTORY. For each credit line it mints + aligns, in one
///         atomic call, a fresh per-line borrower account (`LineAccount` + its operator grant), an isolated escrow
///         collateral vault (holds the lien), an isolated USDC borrow vault (the lending vault), and a dedicated
///         frozen per-line `EulerRouter` that prices the collateral from the shared `ZipcodeOracleRegistry` keyed on
///         the lien token. Holds the per-line market governor role + each line's EVC operator bit (granted by the
///         line's own `LineAccount` at origination). Modeled inline on the verified `EdgeFactory.deploy()` (NOT
///         imported — evk-periphery is un-remapped).
contract EulerVenueAdapter is IZipcodeVenue, Ownable {
    // ----- EVK op bitmask constants (§3 line 133) -----
    uint32 internal constant OP_DEPOSIT = 1 << 0;
    uint32 internal constant OP_MINT = 1 << 1;
    uint32 internal constant OP_WITHDRAW = 1 << 2;
    uint32 internal constant OP_REDEEM = 1 << 3;
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_LIQUIDATE = 1 << 11;
    /// @notice The ops an EE `reallocate` leg invokes on a market: supply = deposit/mint, withdraw = withdraw/redeem.
    ///         If the farm utility vault hooks ANY of these, `fundFarmUtility`/`defundFarmUtility` brick (the hook reverts the
    ///         reallocate leg) — `setFarmUtilityVault` refuses to wire such a vault (CTR-07).
    uint32 internal constant REALLOC_OPS = OP_DEPOSIT | OP_MINT | OP_WITHDRAW | OP_REDEEM;

    // ----- wiring (constructor-seeded; §9/item 10 grants roles separately) -----
    // NOTE (build phase, §17 2026-06-09): every cross-component / external-infra address below is plain MUTABLE
    // storage (not immutable) and re-pointable by the owner (Timelock) via the `setX` setters grouped under
    // "Timelock-settable wiring" — addresses will change during the build. No numeric constant is mutable.
    /// @notice The sole authority that may call the mutating venue methods.
    address public controller;
    /// @notice The Ethereum Vault Connector.
    IEVC public evc;
    /// @notice The EulerEarn pool the lines fund out of (allocator + curator role held by this adapter).
    IEulerEarn public eulerEarn;
    /// @notice The EVK GenericFactory used to mint per-line vaults (caller becomes vault governor via initialize).
    GenericFactory public eVaultFactory;
    /// @notice The shared `ZipcodeOracleRegistry` — each line's price source, keyed on the lien token.
    address public oracleRegistry;
    /// @notice The `CREGatingHook` installed on every borrow vault at OP_BORROW | OP_LIQUIDATE.
    address public gatingHook;
    /// @notice The interest rate model installed on every borrow vault.
    address public irm;
    /// @notice The USDC token (borrow asset + unit-of-account, prices 1:1 with no feed).
    address public usdc;
    /// @notice The ONLY legal draw receiver (the Erebor off-ramp, §4.4a/§9).
    address public erebor;
    /// @notice The no-borrow base USDC market at the EE supply-queue head that `fund` withdraws from.
    address public usdcReservoir;
    /// @notice The farm utility USDC borrow vault (`FarmUtilityMarketDeployer.deploy`'s `borrowVault`) — an enabled,
    ///         NON-supply-queue EE market (acceptCap'd at deploy). `fundFarmUtility`/`defundFarmUtility` reallocate
    ///         resting USDC in/out of it just-in-time so it holds ≈0 at rest (§4.5.1 farm utility loop).
    address public farmUtilityVault;
    /// @notice The sole authority that may call `fundFarmUtility`/`defundFarmUtility`. Two-key separation (§4.5.1, do-NOT):
    ///         this MUST be set to an identity DISTINCT from the `FarmUtilityLoopModule.operator` that drives
    ///         `borrow`/`repay`, so funding the farm utility and borrowing from it require different keys (draining idle
    ///         USDC needs BOTH). The distinctness is a DEPLOY invariant — there is no on-chain handle on the loop
    ///         module to assert it, so the gate proof is that the loop `operator` key (lacking this role) reverts
    ///         `NotFarmUtilityAllocator`.
    address public farmUtilityAllocator;

    // ----- per-revolution protocol fee (CTR-09, §5/§17) -----
    /// @notice The protocol-fee recipient. DEFAULTS to `address(0)` = fee OFF until the Timelock wires it via
    ///         `setAdminSafe`. When non-zero and the computed fee is non-dust, `draw` appends a fourth EVC borrow
    ///         leg crediting `fee` USDC here (financed by the line: line debt becomes `amount + fee`).
    address public adminSafe;
    /// @notice The per-draw fee in basis points. INLINE-initialized to 50 (= 0.50%) — NOT a constructor arg (a ctor arg
    ///         would break `MisWiringAdapter`'s super-call). Timelock-settable via `setFeeBps`, capped at `MAX_FEE_BPS`.
    ///         CALIBRATION (CTR-09, dartboard 2026-06-19): 50 bps reads as a market-standard per-origination fee
    ///         (Maple 0.5% parity; low end of warehouse upfront) — and since each revolution is a fresh origination
    ///         (warehouse → secondary take-out → redraw), it is charged per draw. At a HELOC ≤quarterly revolution
    ///         (≤4 turns/yr) that is ≤~2%/yr of drawn volume. Re-address with observed velocity/originator demand. The
    ///         time-based APR is the borrow vault's IRM (currently `ZeroIRM`; a real rate is a Timelock IRM-swap), NOT
    ///         this fee.
    uint16 public feeBps = 50;
    /// @notice The hard ceiling on `feeBps` (5%). `setFeeBps` reverts `FeeTooHigh` above this.
    uint16 internal constant MAX_FEE_BPS = 500;

    // ----- per-line curator fee (CTR-13, §5/§17) -----
    /// @notice The EVK line-vault `feeReceiver` (governor fee-share recipient) installed on every per-line borrow
    ///         vault at `openLine` — the curator's payment for designing/running the vaults. It captures the governor
    ///         share of each line's EVK `interestFee` (the default 10% skimmed off borrow interest): EULER takes its
    ///         protocol share (capped at 50% — EVK `MAX_PROTOCOL_FEE_SHARE`), this address takes the remaining
    ///         governor share (≥50%). The share arrives as fee-SHARES of each line vault, realized via that vault's
    ///         permissionless `convertFees()` (then redeem → USDC). DEFAULTS to `address(0)` = the EVK "governor
    ///         forfeits" sentinel ⇒ 100% to Euler (no curator fee); the Timelock wires it via `setCuratorSafe`.
    ///         DISTINCT from `adminSafe` (the CTR-09 per-DRAW fee) and from the EE pool-level perf-fee `f`.
    address public curatorSafe;

    /// @notice Per-line record. `lineRef` = the borrow vault address.
    struct Line {
        address collateralVault;
        address lienToken;
        address router;
        address lineAccount;
        address borrowAccount;
        bool open;
    }

    /// @notice lineRef (= borrow vault) => Line record.
    mapping(address => Line) public lines;

    // ----- errors -----
    error NotController();
    error UnknownLine(address lineRef);
    error WireMismatch();
    error LineNotRepaid();
    error NotImplemented();
    error BadReceiver();
    error ZeroCap();
    error InvalidCollateralAmount();
    error ZeroAddress();
    /// @notice `openLine` aborts early: the EE pool's timelock is non-zero, so the same-tx `submitCap`+`acceptCap`
    ///         onboarding (`afterTimelock`) would revert mid-origination — fail loud BEFORE any line state is built.
    error EulerEarnTimelockNonZero();
    /// @notice `fundFarmUtility`/`defundFarmUtility` caller is not the wired `farmUtilityAllocator` (two-key separation).
    error NotFarmUtilityAllocator();
    /// @notice `setFarmUtilityVault` rejected a vault whose hook would block the EE reallocate legs (deposit/withdraw),
    ///         which would brick `fundFarmUtility`/`defundFarmUtility` (CTR-07 fail-fast).
    error FarmUtilityHookBlocksReallocate();
    /// @notice `setFeeBps` rejected a bps value above `MAX_FEE_BPS` (CTR-09).
    error FeeTooHigh();

    // ----- events -----
    /// @notice Emitted when an owner (Timelock) re-points a wiring slot (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice Emitted when the owner (Timelock) sets `feeBps` (CTR-09). `WiringSet` cannot carry it — its 2nd param
    ///         is `address`; the fee bps is a uint16.
    event FeeSet(uint16 feeBps);
    /// @notice Emitted ONLY when the per-draw fee leg is appended (live recipient + non-dust fee) — never with `fee == 0`.
    event FeeLevied(address indexed lineRef, uint256 fee);

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /// @notice Gate for the farm utility fund/defund path. The `farmUtilityAllocator` is a DISTINCT key from the
    ///         `FarmUtilityLoopModule.operator` (two-key separation, §4.5.1) — funding the farm utility and borrowing from
    ///         it require different identities.
    modifier onlyFarmUtilityAllocator() {
        if (msg.sender != farmUtilityAllocator) revert NotFarmUtilityAllocator();
        _;
    }

    constructor(
        address controller_,
        address evc_,
        address eulerEarn_,
        address eVaultFactory_,
        address oracleRegistry_,
        address gatingHook_,
        address irm_,
        address usdc_,
        address erebor_,
        address usdcReservoir_
    ) Ownable(msg.sender) {
        controller = controller_;
        evc = IEVC(evc_);
        eulerEarn = IEulerEarn(eulerEarn_);
        eVaultFactory = GenericFactory(eVaultFactory_);
        oracleRegistry = oracleRegistry_;
        gatingHook = gatingHook_;
        irm = irm_;
        usdc = usdc_;
        erebor = erebor_;
        usdcReservoir = usdcReservoir_;
    }

    // --- Timelock-settable wiring (build phase, §17) ---

    /// @notice Re-point `controller` (build phase, §17). onlyOwner (Timelock).
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit WiringSet("controller", controller_);
    }

    /// @notice Re-point `evc` (build phase, §17). onlyOwner (Timelock).
    function setEvc(address evc_) external onlyOwner {
        if (evc_ == address(0)) revert ZeroAddress();
        evc = IEVC(evc_);
        emit WiringSet("evc", evc_);
    }

    /// @notice Re-point `eulerEarn` (build phase, §17). onlyOwner (Timelock).
    function setEulerEarn(address eulerEarn_) external onlyOwner {
        if (eulerEarn_ == address(0)) revert ZeroAddress();
        eulerEarn = IEulerEarn(eulerEarn_);
        emit WiringSet("eulerEarn", eulerEarn_);
    }

    /// @notice Re-point `eVaultFactory` (build phase, §17). onlyOwner (Timelock).
    function setEVaultFactory(address eVaultFactory_) external onlyOwner {
        if (eVaultFactory_ == address(0)) revert ZeroAddress();
        eVaultFactory = GenericFactory(eVaultFactory_);
        emit WiringSet("eVaultFactory", eVaultFactory_);
    }

    /// @notice Re-point `oracleRegistry` (build phase, §17). onlyOwner (Timelock).
    function setOracleRegistry(address oracleRegistry_) external onlyOwner {
        if (oracleRegistry_ == address(0)) revert ZeroAddress();
        oracleRegistry = oracleRegistry_;
        emit WiringSet("oracleRegistry", oracleRegistry_);
    }

    /// @notice Re-point `gatingHook` (build phase, §17). onlyOwner (Timelock).
    function setGatingHook(address gatingHook_) external onlyOwner {
        if (gatingHook_ == address(0)) revert ZeroAddress();
        gatingHook = gatingHook_;
        emit WiringSet("gatingHook", gatingHook_);
    }

    /// @notice Re-point `irm` (build phase, §17). onlyOwner (Timelock).
    function setIrm(address irm_) external onlyOwner {
        if (irm_ == address(0)) revert ZeroAddress();
        irm = irm_;
        emit WiringSet("irm", irm_);
    }

    /// @notice Re-point `usdc` (build phase, §17). onlyOwner (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point `erebor` (build phase, §17). onlyOwner (Timelock).
    function setErebor(address erebor_) external onlyOwner {
        if (erebor_ == address(0)) revert ZeroAddress();
        erebor = erebor_;
        emit WiringSet("erebor", erebor_);
    }

    /// @notice Re-point `usdcReservoir` (build phase, §17). onlyOwner (Timelock).
    function setUsdcReservoir(address usdcReservoir_) external onlyOwner {
        if (usdcReservoir_ == address(0)) revert ZeroAddress();
        usdcReservoir = usdcReservoir_;
        emit WiringSet("usdcReservoir", usdcReservoir_);
    }

    /// @notice Re-point `farmUtilityVault` (build phase, §17). onlyOwner (Timelock). The farm utility borrow vault the
    ///         JIT fund/defund path moves resting USDC in/out of.
    function setFarmUtilityVault(address farmUtilityVault_) external onlyOwner {
        if (farmUtilityVault_ == address(0)) revert ZeroAddress();
        // Fail-fast (CTR-07): the EE reallocate legs DEPOSIT/MINT into and WITHDRAW/REDEEM out of this vault, so if any
        // of those ops is hooked the guard reverts and `fundFarmUtility`/`defundFarmUtility` brick. The farm utility vault is
        // purpose-built hooked OP_BORROW-only (`FarmUtilityMarketDeployer`); refuse to wire any vault whose hook would
        // block reallocate. (Catches a mis-wire at SET time; the Timelock can still re-hook an already-wired vault
        // later — that remains a governed §17 invariant, outside this adapter's reach.)
        (, uint32 hookedOps) = IEVault(farmUtilityVault_).hookConfig();
        if (hookedOps & REALLOC_OPS != 0) revert FarmUtilityHookBlocksReallocate();
        farmUtilityVault = farmUtilityVault_;
        emit WiringSet("farmUtilityVault", farmUtilityVault_);
    }

    /// @notice Re-point `farmUtilityAllocator` (build phase, §17). onlyOwner (Timelock). DEPLOY INVARIANT: set this to
    ///         an identity DISTINCT from the `FarmUtilityLoopModule.operator` (two-key separation, §4.5.1).
    function setFarmUtilityAllocator(address farmUtilityAllocator_) external onlyOwner {
        if (farmUtilityAllocator_ == address(0)) revert ZeroAddress();
        farmUtilityAllocator = farmUtilityAllocator_;
        emit WiringSet("farmUtilityAllocator", farmUtilityAllocator_);
    }

    /// @notice Set the per-draw fee recipient (CTR-09, §17). onlyOwner (Timelock). UNLIKE the other wiring setters this
    ///         DELIBERATELY omits the `ZeroAddress` guard: `address(0)` is the legal "fee disabled" sentinel (a draw with
    ///         `adminSafe == address(0)` appends no fee leg), so wiring it to zero is how the Timelock turns the fee OFF.
    function setAdminSafe(address adminSafe_) external onlyOwner {
        adminSafe = adminSafe_;
        emit WiringSet("adminSafe", adminSafe_);
    }

    /// @notice Set the per-line curator fee receiver (CTR-13, §17). onlyOwner (Timelock). Installed as the EVK
    ///         `feeReceiver` on every SUBSEQUENT `openLine`'s borrow vault. Like `setAdminSafe` this DELIBERATELY
    ///         omits the `ZeroAddress` guard: `address(0)` is the legal "no curator fee" sentinel (the EVK governor
    ///         forfeits its fee-share ⇒ 100% to Euler), so wiring it to zero is how the Timelock turns the fee OFF.
    function setCuratorSafe(address curatorSafe_) external onlyOwner {
        curatorSafe = curatorSafe_;
        emit WiringSet("curatorSafe", curatorSafe_);
    }

    /// @notice Set the per-draw fee in basis points (CTR-09, §17). onlyOwner (Timelock). Capped at `MAX_FEE_BPS` (5%).
    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    /// @notice Struct getter (a public mapping of a struct returns a tuple, not the struct).
    function getLine(address lineRef) external view returns (Line memory) {
        return lines[lineRef];
    }

    /// @inheritdoc IZipcodeVenue
    function openLine(bytes32 lienId, address lienToken, uint256 collateralAmount)
        external
        onlyController
        returns (address lineRef, address oracleKey)
    {
        // The lien is a 1/1 primitive (WOOF-01: fixed 1e18 supply). The close path reclaims exactly 1e18 before
        // burn, so a partial deposit would open a line that can never be cleanly closed (reclaim underflows). A
        // bare `!= 0` is too loose — reject both 0 (EVK deposit(0,..) does NOT revert → silent zero-share line)
        // and any partial.
        if (collateralAmount != 1e18) revert InvalidCollateralAmount();

        // runtime timelock precheck. `submitCap` sets `pendingCap.validAt = now + timelock`
        // and the SAME-TX `acceptCap` carries `afterTimelock(validAt)` (EulerEarn.sol:507) — so a non-zero EE
        // timelock makes step-4 onboarding revert AFTER the LineAccount + both EVK proxies + router are already
        // built (orphaned state). The EE owner is EXTERNAL and can RAISE the timelock post-deploy, so a deploy-time
        // `timelock()==0` snapshot is insufficient; this reads it LIVE per origination and aborts before step 0.
        if (eulerEarn.timelock() != 0) revert EulerEarnTimelockNonZero();

        // step 0: fresh per-line borrower account + its operator grant (the adapter is the granted operator).
        LineAccount la = new LineAccount{salt: lienId}(address(evc), address(this));
        address borrowAccount = address(uint160(address(la)) ^ 1);

        // step 1: escrow collateral vault (bare holding box: no oracle, no unit-of-account, no governance).
        address collat =
            eVaultFactory.createProxy(address(0), false, abi.encodePacked(lienToken, address(0), address(0)));
        IEVault(collat).setHookConfig(address(0), 0);
        IEVault(collat).setGovernorAdmin(address(0));

        // step 2: dedicated per-line router; wire COLLAT -> lienToken -> registry (the adapter is governor at birth).
        EulerRouter router = new EulerRouter(address(evc), address(this));
        router.govSetResolvedVault(collat, true); // unwrap escrow shares -> lienToken, 1:1
        router.govSetConfig(lienToken, usdc, oracleRegistry); // price (lienToken, USDC) via the registry

        // step 3: isolated USDC borrow vault (oracle = this line's router; unit-of-account = USDC so it prices 1:1).
        address evault =
            eVaultFactory.createProxy(address(0), false, abi.encodePacked(usdc, address(router), usdc));
        IEVault(evault).setInterestRateModel(irm);
        // CTR-13: route this line vault's EVK interest-fee governor share to the curator vault (Euler keeps only its
        // protocol share, capped at 50%). `address(0)` ⇒ skip, leaving the EVK default `feeReceiver == 0` (governor
        // forfeits ⇒ 100% to Euler). The adapter is this vault's governor, so `setFeeReceiver` is authorized.
        if (curatorSafe != address(0)) IEVault(evault).setFeeReceiver(curatorSafe);
        IEVault(evault).setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE); // never hook OP_REPAY

        // step 4: onboard EVAULT to the EE pool so `fund` can reallocate into it. Curator submitCap is bounded to
        // ONLY the freshly-minted local EVAULT (security F3 — never a caller-supplied market). M1 shortcut: the
        // supply queue is [usdcReservoir, EVAULT]; rebuild it preserving the existing queue.
        eulerEarn.submitCap(IOZERC4626(evault), type(uint136).max);
        eulerEarn.acceptCap(IOZERC4626(evault));
        uint256 qlen = eulerEarn.supplyQueueLength();
        IOZERC4626[] memory newQueue = new IOZERC4626[](qlen + 1);
        for (uint256 i; i < qlen; ++i) {
            newQueue[i] = eulerEarn.supplyQueue(i);
        }
        newQueue[qlen] = IOZERC4626(evault);
        eulerEarn.setSupplyQueue(newQueue);

        // step 5: custody the lien as collateral for borrowAccount. The controller approved the adapter as part of
        // its origination batch. deposit to receiver `borrowAccount` needs no consent (EVK credits any receiver).
        IERC20(lienToken).transferFrom(controller, address(this), collateralAmount);
        IERC20(lienToken).approve(collat, collateralAmount);
        IEVault(collat).deposit(collateralAmount, borrowAccount);

        // step 6: freeze the router — the wiring is now immutable; nobody can re-point this line's price source.
        // (Price values still flow — the registry's cache is CRE-updated; only the routing is frozen.)
        router.transferGovernance(address(0));

        // step 7: birth-time wire-check (W3): prove COLLAT -> this lien -> the registry resolves.
        _assertWired(address(router), collat, lienToken);

        lineRef = evault;
        oracleKey = lienToken;
        lines[lineRef] =
            Line({collateralVault: collat, lienToken: lienToken, router: address(router), lineAccount: address(la), borrowAccount: borrowAccount, open: true});

        emit LineOpened(lienId, lineRef, oracleKey, collat, address(router), borrowAccount);
    }

    /// @notice Defensive wire-check (W3): proves the router resolves `collat -> lienToken -> registry`. Not a
    ///         caller-reachable branch — `openLine` builds the wiring itself; covered by a deliberately-mis-wiring
    ///         harness subclass override.
    function _assertWired(address router, address collat, address lienToken) internal view virtual {
        (, address rBase,, address rOracle) = EulerRouter(router).resolveOracle(1e18, collat, usdc);
        if (rBase != lienToken || rOracle != oracleRegistry) revert WireMismatch();
    }

    /// @inheritdoc IZipcodeVenue
    function setLineLimits(address lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap) external onlyController {
        Line storage L = lines[lineRef];
        if (!L.open) revert UnknownLine(lineRef);

        IEVault(lineRef).setLTV(L.collateralVault, borrowLTV, liqLTV, 0); // 1e4 scale; ramp 0
        // supplyCap = 0 is DELIBERATELY unlimited (raw 0 = no supply limit). The line's risk bound is the borrowCap
        // + the LTV x mark gate, not a supply cap — NOT "no supply allowed".
        IEVault(lineRef).setCaps(0, _toAmountCap(cap));

        emit LineLimitsSet(lineRef, borrowLTV, liqLTV, cap);
    }

    /// @notice The EE pool's INTERNALLY-TRACKED supplied assets in `market`, byte-matching what `reallocate`
    ///         measures (security L9 / SEC-11). `reallocate` sizes each market's current position as
    ///         `previewRedeem(config[id].balance)` (EulerEarn.sol:392-393) — the EE's *tracked* share balance,
    ///         which deliberately IGNORES direct share transfers (IEulerEarn.sol:69,73). Sizing the absolute
    ///         reallocate targets from `convertToAssets(balanceOf(EE))` (the *live* balance) instead lets anyone
    ///         donate even 1 EVK share into the pool to skew the targets so the withdraw/supply deltas no longer
    ///         net — `reallocate` then reverts `InconsistentReallocation` and funding/defunding bricks (grief).
    ///         Reading the same `previewRedeem(config.balance)` the pool uses is donation-immune by construction.
    function _eeSupplyAssets(address market) internal view returns (uint256) {
        return IEVault(market).previewRedeem(eulerEarn.config(IOZERC4626(market)).balance);
    }

    /// @notice Shared absolute-target, zero-sum move: withdraw `amount` from `from` and supply it to `to` in one
    ///         in-order reallocate (withdraw leg first, so the pass has cash before it deposits). BOTH absolute
    ///         targets are sized off the EE's TRACKED supplied position (`_eeSupplyAssets` =
    ///         `previewRedeem(config.balance)`, security L9/SEC-11) — donation-immune by construction (NOT
    ///         `convertToAssets(balanceOf(EE))`, which a share donation skews into `InconsistentReallocation`).
    ///         `fund`/`fundFarmUtility`/`defundFarmUtility` are this exact shape; reading `from` before `to`
    ///         preserves each caller's original read order. (`closeLine`'s defund differs — absolute target 0 —
    ///         and stays inline.)
    function _eeMove(address from, address to, uint256 amount) internal {
        uint256 fromBalance = _eeSupplyAssets(from);
        uint256 toBalance = _eeSupplyAssets(to);
        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({id: IOZERC4626(from), assets: fromBalance - amount});
        allocs[1] = MarketAllocation({id: IOZERC4626(to), assets: toBalance + amount});
        eulerEarn.reallocate(allocs);
    }

    /// @inheritdoc IZipcodeVenue
    function fund(address lineRef, uint256 amount) external onlyController {
        if (!lines[lineRef].open) revert UnknownLine(lineRef);

        // reallocate is zero-sum + ABSOLUTE-target. Read both absolute bases from the EE's TRACKED supplied
        // position (`previewRedeem(config.balance)` via `_eeSupplyAssets`, security L9) — the SAME measure
        // `reallocate` uses internally, so a direct share donation cannot skew the targets (NOT
        // `convertToAssets(balanceOf(EE))`, which counts donated shares the pool's accounting ignores; NOT
        // `maxWithdraw`, which is capped by idle cash and under-reads once a prior line borrowed the cash out).
        // Two-item allocation: withdraw `amount` from usdcReservoir, supply it to lineRef to reach the new
        // absolute target.
        _eeMove(usdcReservoir, lineRef, amount);

        emit LineFunded(lineRef, amount);
    }

    /// @inheritdoc IZipcodeVenue
    function draw(address lineRef, uint256 amount, address receiver) external onlyController {
        Line storage L = lines[lineRef];
        if (!L.open) revert UnknownLine(lineRef);
        // The draw target is pinned to the immutable Erebor off-ramp (security F2) — do not trust the arg blindly.
        if (receiver != erebor) revert BadReceiver();

        address borrowAccount = L.borrowAccount;

        // Per-revolution protocol fee (CTR-09, §5/§17). Round-DOWN (Solidity integer div). `feeBps == 0` => `fee == 0`,
        // so `levyFee` also covers a zeroed bps; `adminSafe == address(0)` is the disabled sentinel; a dust draw
        // (`fee == 0`) appends NO leg (never a `borrow(0, ..)` leg, never `FeeLevied(.., 0)`).
        uint256 fee = amount * feeBps / 10_000;
        bool levyFee = adminSafe != address(0) && fee != 0;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](levyFee ? 4 : 3);
        // (1) enable controller — EVC self-call (account in calldata, onBehalfOf == 0, value == 0).
        items[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (borrowAccount, lineRef))
        });
        // (2) enable collateral — same self-call shape.
        items[1] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (borrowAccount, L.collateralVault))
        });
        // (3) borrow — vault-call on behalf of borrowAccount. `borrow` is on IBorrowing (NOT the aggregate IEVault).
        items[2] = IEVC.BatchItem({
            targetContract: lineRef,
            onBehalfOfAccount: borrowAccount,
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (amount, erebor))
        });
        // (4, optional) the fee leg — a SECOND borrow on the SAME borrowAccount, crediting `fee` to `adminSafe`. The
        // line's debt becomes `amount + fee` (financed by the line, repaid with it). The principal leg above keeps the
        // hardcoded `erebor` receiver (F2 preserved); only this leg's receiver differs. Both borrows on one
        // borrowAccount in one batch are mechanically valid — the deferred account-status check runs once at batch end
        // against the final `amount + fee` debt.
        if (levyFee) {
            items[3] = IEVC.BatchItem({
                targetContract: lineRef,
                onBehalfOfAccount: borrowAccount,
                value: 0,
                data: abi.encodeCall(IBorrowing.borrow, (fee, adminSafe))
            });
        }

        // The adapter is the batch msg.sender and the granted operator of borrowAccount (granted at openLine). EVK
        // appends borrowAccount as the hook caller -> the §4.3 hook's isAccountOperatorAuthorized passes.
        evc.batch(items);

        if (levyFee) emit FeeLevied(lineRef, fee);
        emit LineDrawn(lineRef, amount, receiver);
    }

    /// @inheritdoc IZipcodeVenue
    function observeDebt(address lineRef) public view returns (uint256) {
        // Readable AFTER close (L7/L8 read observeDebt == 0 post-close) — does NOT guard on `open`.
        return IEVault(lineRef).debtOf(lines[lineRef].borrowAccount);
    }

    /// @notice The silo's senior-read surface — the address that satisfies `ISeniorPool` (the donation-immune
    ///         `{balanceOf, convertToAssets, maxWithdraw}` read the `SeniorNavAggregator`/`DurationFreezeModule` use)
    ///         and that the `SiloRegistry` admission gate asserts against `SiloConfig.eePool` (CTR-10b). For this
    ///         Euler venue the senior surface IS the EulerEarn pool itself (4626 satisfies `ISeniorPool` directly), so
    ///         this returns `address(eulerEarn)`. A non-Euler venue adapter returns its own `ISeniorPool` surface
    ///         (the venue's pool if 4626, else a thin wrapper) — that is the ONE getter the registry needs to be
    ///         venue-agnostic; `IZipcodeVenue` itself stays senior-surface-free (§4.7).
    function seniorPool() external view returns (address) {
        return address(eulerEarn);
    }

    /// @inheritdoc IZipcodeVenue
    function closeLine(address lineRef) external onlyController {
        Line storage L = lines[lineRef];
        if (!L.open) revert UnknownLine(lineRef);
        if (observeDebt(lineRef) != 0) revert LineNotRepaid();

        // The escrow shares are owned by borrowAccount, so a direct redeem reverts E_InsufficientAllowance. Route
        // through EVC.call (the adapter is borrowAccount's authorized operator) — IEVC.call takes FOUR args.
        uint256 shares = IEVault(L.collateralVault).balanceOf(L.borrowAccount);
        evc.call(
            L.collateralVault,
            L.borrowAccount,
            0,
            abi.encodeCall(IEVKERC4626.redeem, (shares, controller, L.borrowAccount))
        );

        // Defund the line's USDC supply back to the base market (security L8). `fund` moved the EE pool's USDC
        // from base INTO this line's borrow vault (an absolute-target reallocate, :289-292); without returning it
        // on close that USDC strands in the now-closed vault, permanently depressing the base market's EE balance
        // until a later `fund`'s `baseBalance - amount` (:290) underflows and origination funding bricks. Reclaim
        // it with the INVERSE of fund's reallocate: redeem ALL of the EE's line shares (absolute target 0 -> EE
        // redeems the full position) and add that USDC to base's absolute target. Size BOTH legs off the EE's
        // TRACKED position (`_eeSupplyAssets` = `previewRedeem(config.balance)`, security L9/SEC-11) so the defund
        // is equally donation-immune (matching fund's sizing; NOT `convertToAssets(balanceOf(EE))`, which a share
        // donation skews into an `InconsistentReallocation` revert; NOT maxWithdraw, which under-reads). The line
        // leg stays `assets:0` (a full redeem already sweeps any donated shares per EulerEarn.sol:397-402); only
        // the base target adds the line's tracked assets. The line's cap is still non-zero (openLine left it
        // type(uint136).max; never revoked) so the market stays reallocate-eligible (EE gates on config[].enabled,
        // set by acceptCap — independent of supply-queue membership). Must run BEFORE the queue prune below so the
        // pruned market is already emptied. No-op guard: a line opened/closed without ever being funded has
        // lineBalance == 0 -> skip (a zero-sum reallocate on an empty market is pointless and a {x:0}
        // withdrawal-only leg cannot balance).
        uint256 lineBalance = _eeSupplyAssets(lineRef);
        if (lineBalance != 0) {
            uint256 baseBalance = _eeSupplyAssets(usdcReservoir);
            MarketAllocation[] memory defund = new MarketAllocation[](2);
            defund[0] = MarketAllocation({id: IOZERC4626(lineRef), assets: 0});
            defund[1] = MarketAllocation({id: IOZERC4626(usdcReservoir), assets: baseBalance + lineBalance});
            eulerEarn.reallocate(defund);
        }

        // Prune the closed line's borrow vault from the EE supply queue (security H2). `openLine` appends every
        // new EVAULT to the queue (:227-233); without this prune the queue grows monotonically toward the hard
        // MAX_QUEUE_LENGTH = 30 cap, and once ~29 lines exist the next openLine's setSupplyQueue reverts
        // MaxQueueLengthExceeded -> origination permanently bricks even though most lines are long since closed.
        // Rebuild into a qlen-1 array, skipping `lineRef` by ADDRESS match (do NOT assume it is the last entry —
        // interleaved opens/closes move it). Every surviving entry still has cap != 0 (base market + other open
        // lines), so EE's per-entry cap check passes; no cap-revoke / withdraw-queue / timelock path is needed.
        // The defund above just returned the line's USDC to base, so the removed market carries no balance.
        uint256 qlen = eulerEarn.supplyQueueLength();
        IOZERC4626[] memory newQueue = new IOZERC4626[](qlen - 1);
        uint256 j;
        for (uint256 i; i < qlen; ++i) {
            IOZERC4626 m = eulerEarn.supplyQueue(i);
            if (address(m) == lineRef) continue;
            newQueue[j++] = m;
        }
        eulerEarn.setSupplyQueue(newQueue);

        // Reclaim the line's BINDING withdraw-queue slot (CTR-04). The supply-queue prune above frees the
        // NON-binding queue (SEC-06); the hard MAX_QUEUE_LENGTH (30) cap that actually bricks origination fires on
        // the WITHDRAW queue inside _setCap when a market is first enabled (EulerEarn.sol:783-785). `openLine`
        // enables the line's market (submitCap max + acceptCap, :235-236) and so consumes a withdraw-queue slot;
        // without removing it on close the slot stays consumed FOREVER and the ~29th LIFETIME openLine's acceptCap
        // reverts MaxQueueLengthExceeded — even though most lines are long closed. Inline, single-tx, no keeper /
        // submitMarketRemoval / timelock branch: the defund above emptied the market, so removal of an EMPTY market
        // never engages the EE timelock (updateWithdrawQueue's removableAt guard EulerEarn.sol:366-370 sits inside
        // `if (expectedSupplyAssets(id) != 0)` :365, and previewRedeem(0) == 0). Sequence mirrors _setCap's removal
        // guards (EulerEarn.sol:362-371):
        //   1. Zero the line's EE cap. A cap DECREASE applies IMMEDIATELY via _setCap with no timelock
        //      (EulerEarn.sol:298-299); the removal guard :362 requires cap == 0. openLine left the cap at
        //      type(uint136).max (:235) and setLineLimits touches only the EVK vault's OWN caps, so this is always a
        //      valid max->0 decrease.
        eulerEarn.submitCap(IOZERC4626(lineRef), 0);
        //   2. Build keepIndexes = every current withdraw-queue index whose market != lineRef, by ADDRESS (do NOT
        //      assume the line is the last entry — interleaved opens/closes move it, like the supply-prune above).
        //      Keep the base USDC market (and any farm utility/resting market); only lineRef drops.
        uint256 wqlen = eulerEarn.withdrawQueueLength();
        uint256 keepCount;
        for (uint256 i; i < wqlen; ++i) {
            if (address(eulerEarn.withdrawQueue(i)) != lineRef) ++keepCount;
        }
        uint256[] memory keepIndexes = new uint256[](keepCount);
        uint256 k;
        for (uint256 i; i < wqlen; ++i) {
            if (address(eulerEarn.withdrawQueue(i)) != lineRef) keepIndexes[k++] = i;
        }
        //   3. updateWithdrawQueue takes the indexes to KEEP; any current index NOT listed is removed
        //      (EulerEarn.sol:340-380). lineRef passes the removal guards (:362-371): cap == 0 (step 1), no pending
        //      cap, and expectedSupplyAssets == previewRedeem(0) == 0 (the defund above) -> the removableAt/timelock
        //      sub-block is skipped entirely and delete config[lineRef] runs.
        eulerEarn.updateWithdrawQueue(keepIndexes);

        L.open = false; // keep the record readable so post-close observeDebt == 0 stays queryable
        emit LineClosed(lineRef);
    }

    // --- farm utility JIT fund/defund (adapter-LOCAL; NOT on IZipcodeVenue — the venue interface stays line-only) ---

    /// @notice Move `amount` resting USDC into the farm utility borrow vault so a junior strike-financing harvest has
    ///         lendable cash (§4.5.1). The farm utility holds ≈0 at rest; the CRE calls this JUST-IN-TIME pre-borrow,
    ///         then `defundFarmUtility` re-absorbs it after the junior repays — so idle USDC is never standing-borrowable
    ///         (the rejected "combined" topology) and senior-redemption liquidity stays in the no-borrow resting market.
    ///         Mirrors `fund` exactly: an ABSOLUTE-target, zero-sum two-item reallocate sized off the EE's TRACKED
    ///         supplied position (`_eeSupplyAssets` = `previewRedeem(config.balance)`, security L9/SEC-11) — NOT
    ///         `convertToAssets(balanceOf(EE))`, which a direct share donation skews into `InconsistentReallocation`.
    ///         Withdraw `amount` from usdcReservoir, supply it to the farm utility vault (withdraw leg first, so the
    ///         single in-order reallocate pass has cash before it deposits). `onlyFarmUtilityAllocator` — a DISTINCT key
    ///         from the `FarmUtilityLoopModule.operator` (two-key separation): both are needed to move idle USDC out.
    function fundFarmUtility(uint256 amount) external onlyFarmUtilityAllocator {
        _eeMove(usdcReservoir, farmUtilityVault, amount);
    }

    /// @notice The inverse of `fundFarmUtility`: re-absorb `amount` USDC from the farm utility vault back to the resting
    ///         market after the junior repays, restoring resting liquidity and returning the farm utility to ≈0 at rest
    ///         (§4.5.1). Sized off `_eeSupplyAssets` like `closeLine`'s defund (donation-immune). Withdraw the farm utility
    ///         leg first, then supply to base. A `defundFarmUtility` issued while the farm utility's cash is still borrowed
    ///         out (no repay yet) REVERTS — the EVK withdraw leg has no cash (`E_InsufficientCash`); this is the
    ///         JIT/redemption-isolation discipline, NOT a silent under-defund. `onlyFarmUtilityAllocator`.
    function defundFarmUtility(uint256 amount) external onlyFarmUtilityAllocator {
        _eeMove(farmUtilityVault, usdcReservoir, amount);
    }

    /// @inheritdoc IZipcodeVenue
    function liquidate(address) external view onlyController {
        revert NotImplemented(); // §4.4e — no on-chain economic liquidation
    }

    /// @notice Encode a raw token-unit cap to the EVK AmountCap uint16 format. Layout: low 6 bits = exponent,
    ///         high 10 bits = mantissa (scaled x100); resolve = 10**(raw&63) * (raw>>6) / 100. Encode rounds UP
    ///         (smallest representable cap >= `amount`) so a line capped exactly at the draw does not revert
    ///         SupplyCapExceeded. `amount == 0` is forbidden: raw AmountCap 0 means UNLIMITED, the opposite of a
    ///         zero cap (a closed line is closeLine, not a zero cap).
    function _toAmountCap(uint256 amount) internal pure returns (uint16) {
        if (amount == 0) revert ZeroCap();

        // Find the smallest exponent e in [0,63] such that mantissa = ceil(amount * 100 / 10**e) <= 1023.
        for (uint256 e; e <= 63; ++e) {
            uint256 pow = 10 ** e;
            uint256 num = amount * 100;
            uint256 mantissa = (num + pow - 1) / pow; // round UP
            if (mantissa <= 1023) {
                return uint16((mantissa << 6) | e);
            }
        }
        // Defensive: the largest encodable cap is 1023 * 10**63 / 100 ~ 1.02e64 raw token units — astronomically
        // beyond any real token supply, but NOT all of uint256 (type(uint256).max ~ 1.16e77). An `amount` above
        // ~1.02e64 falls through here (one above ~1.16e75 overflows `amount * 100` first); both revert.
        revert ZeroCap();
    }
}
