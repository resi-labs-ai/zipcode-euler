// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev zipUSD = Euler `ESynth` (18-dp, `mint` capacity-gated, `mint(·,0)` is a silent no-op). Local interface only;
///      do NOT inherit. `reference/euler-vault-kit/src/Synths/ESynth.sol`.
interface IESynth {
    function mint(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @dev The venue pool (`EulerEarn`, ERC4626 over USDC). `deposit(assets, receiver)` pulls `assets` from the caller,
///      mints shares to `receiver`. Local interface only. `reference/euler-earn/src/EulerEarn.sol:560`.
interface IEulerEarn {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @dev The szipUSD junior vault's Exit Gate (PROGRESS item 8) — the generalized NAV-proportional issuance core.
///      `depositFor(asset, amount, receiver)` pulls `amount` of `asset` from the caller (this module) into the junior
///      basket, values it via `SzipNavOracle` (round-down, staleness-guarded), mints soulbound Loot to itself + the
///      transferable szipUSD share to `receiver`, and returns the `shares` minted. `previewDeposit` is the read-only
///      quote. Local interface only. `contracts/src/supply/szipUSD/ExitGate.sol`; `baal-spec.md` §4/§5.
interface IZipExitGate {
    function depositFor(address asset, uint256 amount, address receiver) external returns (uint256 shares);
    function previewDeposit(address asset, uint256 amount) external view returns (uint256 shares);
}

/// @title ZipDepositModule (the zap)
/// @notice The supply-side mint+deposit router: the ONLY entry by which a supplier turns USDC into the protocol's two
///         supply positions. `deposit(usdcIn)` mints zipUSD 1:1-by-value to the depositor and parks the USDC in the
///         venue pool (`EulerEarn`) with the `CreditWarehouse` Safe as the share `receiver` (the module custodies
///         nothing). `zap(usdcIn)` is THE default UX: deposit → mint zipUSD (transient, to the module) → auto-deposit
///         into the Exit Gate on behalf of the caller in one atomic call, so the supplier lands directly in the
///         headline junior position (transferable szipUSD) without ever holding zipUSD or Loot.
///
///         This contract adds NO economic decision — all NAV/pricing lives in the Gate + `SzipNavOracle`. It holds no
///         per-user state and custodies no assets: zipUSD is minted to the user (or, in the zap, minted transiently
///         and immediately handed to the Gate), USDC is deposited to the warehouse Safe, and szipUSD is minted to the
///         user by the Gate. It has no owner/admin/pause/upgrade surface — the lone privileged action is the set-once
///         `setGate` (deployer-gated). `claude-zipcode.md` §4.5/§6.4; `baal-spec.md` §4/§5/§11. WOOF-06.
contract ZipDepositModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- immutables
    /// @notice zipUSD — the $1 utility synth (`ESynth`, 18-dp); the module is a capacity-granted minter.
    address public immutable zipUSD;
    /// @notice USDC — the deposit asset (6-dp).
    address public immutable usdc;
    /// @notice The venue pool (`EulerEarn` over USDC); the USDC sink, shares go to the warehouse.
    address public immutable eePool;
    /// @notice The `CreditWarehouse` Safe (8-Bw) — the EE-share `receiver`; the module never holds shares.
    address public immutable warehouse;
    /// @notice `10 ** (zipDecimals - usdcDecimals)` — the value-1:1 mint scale, DERIVED in the ctor from the tokens'
    ///         own `decimals()` (NOT a hard-coded literal). For 18-dp zipUSD over 6-dp USDC it equals `1e12`.
    uint256 public immutable scaleUp;
    /// @notice The deployer — the only caller of the one-shot `setGate`. No other power.
    address public immutable deployer;

    // --------------------------------------------------------------------- set-once wiring
    /// @notice The Exit Gate (junior vault) — deployed after this module, so wired once via `setGate`. Zero ⇒ un-wired.
    address public gate;

    // --------------------------------------------------------------------- errors
    error ZeroAmount();
    error ZeroAddress();
    error DecimalsTooFew(); // zipUSD decimals < USDC decimals — value-1:1 needs zipUSD the finer unit
    error NotDeployer();
    error AlreadyWired();
    error NotWired();
    error ZeroShares();
    error ResidualBalance();

    // --------------------------------------------------------------------- events
    event Deposited(address indexed user, uint256 usdcIn, uint256 zipMinted);
    event Zapped(address indexed user, uint256 usdcIn, uint256 zipMinted, uint256 shares);
    event GateWired(address indexed gate);

    /// @param zipUSD_    The zipUSD `ESynth` (18-dp). @param usdc_ USDC (6-dp). @param eePool_ the `EulerEarn` pool.
    /// @param warehouse_ The `CreditWarehouse` Safe — the EE-share `receiver`.
    constructor(address zipUSD_, address usdc_, address eePool_, address warehouse_) {
        if (zipUSD_ == address(0) || usdc_ == address(0) || eePool_ == address(0) || warehouse_ == address(0)) {
            revert ZeroAddress();
        }
        uint8 zipDec = IERC20Metadata(zipUSD_).decimals();
        uint8 usdcDec = IERC20Metadata(usdc_).decimals();
        if (zipDec < usdcDec) revert DecimalsTooFew(); // require(zipDec >= usdcDec) — value-1:1 needs zip the finer unit
        zipUSD = zipUSD_;
        usdc = usdc_;
        eePool = eePool_;
        warehouse = warehouse_;
        scaleUp = 10 ** (uint256(zipDec) - uint256(usdcDec));
        deployer = msg.sender;
    }

    // --------------------------------------------------------------------- set-once wiring (the Exit Gate seam)
    /// @notice Wire the Exit Gate (deployed after this module). Deployer-gated, set-once, grants NO standing allowance
    ///         (D1 — the zap approves the Gate exact-amount per call). After this the module has no admin surface.
    function setGate(address gate_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (gate != address(0)) revert AlreadyWired();
        if (gate_ == address(0)) revert ZeroAddress();
        gate = gate_;
        emit GateWired(gate_);
    }

    // --------------------------------------------------------------------- entrypoints
    /// @notice Plain mint: pull `usdcIn` USDC, mint `usdcIn * scaleUp` zipUSD to the depositor, park the USDC in the
    ///         venue pool with the warehouse Safe as the share `receiver`. The user walks away holding zipUSD; the
    ///         module holds nothing. The secondary path (protocols/contracts wanting the $1 utility token).
    /// @return zipMinted The zipUSD minted to the depositor.
    function deposit(uint256 usdcIn) external nonReentrant returns (uint256 zipMinted) {
        if (usdcIn == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        zipMinted = usdcIn * scaleUp;
        IESynth(zipUSD).mint(msg.sender, zipMinted); // capacity-gated; mint(·,0) is a no-op (the ZeroAmount guard covers it)
        IERC20(usdc).forceApprove(eePool, usdcIn);
        IEulerEarn(eePool).deposit(usdcIn, warehouse); // shares -> warehouse Safe; the module never holds shares
        emit Deposited(msg.sender, usdcIn, zipMinted);
    }

    /// @notice THE default UX: deposit → mint zipUSD (transient, to the module) → on-behalf szipUSD mint via the Exit
    ///         Gate, atomic. The supplier ends up holding only the transferable szipUSD share (NAV-proportional),
    ///         never zipUSD or Loot; the warehouse Safe custodies the EE shares; the module holds nothing.
    /// @return shares The szipUSD minted to the caller by the Gate (== the Gate's return).
    function zap(uint256 usdcIn) external nonReentrant returns (uint256 shares) {
        if (usdcIn == 0) revert ZeroAmount();
        if (gate == address(0)) revert NotWired();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        uint256 zipAmount = usdcIn * scaleUp;
        IESynth(zipUSD).mint(address(this), zipAmount); // transient — handed to the Gate below

        IERC20(usdc).forceApprove(eePool, usdcIn);
        IEulerEarn(eePool).deposit(usdcIn, warehouse); // USDC -> venue pool, warehouse custodies the shares

        IERC20(zipUSD).forceApprove(gate, zipAmount); // exact-amount per-zap allowance (D1)
        shares = IZipExitGate(gate).depositFor(zipUSD, zipAmount, msg.sender); // Gate pulls zipUSD, mints szipUSD to the user

        // "holds nothing" enforcement (F1/F7) — never trust the Gate to leave the module clean.
        if (shares == 0) revert ZeroShares(); // fail closed on a no-op/paused Gate
        if (IESynth(zipUSD).balanceOf(address(this)) != 0) revert ResidualBalance(); // the Gate must have pulled the FULL zipAmount
        IERC20(zipUSD).forceApprove(gate, 0); // defensively reset the per-zap allowance

        emit Zapped(msg.sender, usdcIn, zipAmount, shares);
    }

    // --------------------------------------------------------------------- previews (read-only — frontend back-pressure)
    /// @notice The zipUSD a `deposit(usdcIn)` would mint. Works whether or not the Gate is wired (independent of it).
    function previewDeposit(uint256 usdcIn) external view returns (uint256 zipMinted) {
        return usdcIn * scaleUp;
    }

    /// @notice The (zipUSD minted, szipUSD shares) a `zap(usdcIn)` would yield. `shares` is an ESTIMATE — NAV moves
    ///         between preview and tx (the §3 `max(spot,twap)` entry bracket); label it "≈" in the UI. Reverts
    ///         `NotWired` if the Gate is un-wired.
    function previewZap(uint256 usdcIn) external view returns (uint256 zipMinted, uint256 shares) {
        if (gate == address(0)) revert NotWired();
        zipMinted = usdcIn * scaleUp;
        shares = IZipExitGate(gate).previewDeposit(zipUSD, zipMinted);
    }
}
