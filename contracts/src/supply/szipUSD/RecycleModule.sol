// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The supply-side zap (WOOF-06), in-repo. `deposit(usdcIn)` pulls `usdcIn` USDC from the CALLER
///      (`safeTransferFrom(msg.sender,...)` — so the engine Safe must approve first), mints `usdcIn * scaleUp` BACKED
///      zipUSD to the caller (msg.sender = the engine Safe), and parks the USDC into the venue pool with the warehouse
///      Safe as the EE-share receiver (senior backing). Local interface only.
///      `contracts/src/supply/ZipDepositModule.sol:115`.
interface IZipDepositModule {
    function deposit(uint256 usdcIn) external returns (uint256 zipMinted);
}

/// @dev The `SzipNavOracle` impairment-provision read (the hole size, 18-dp USD). `provision` is `uint256 public`
///      (`contracts/src/supply/SzipNavOracle.sol:135`), sole writer = the `DefaultCoordinator`. Local interface only —
///      `divert` READS it (the bound) and never writes it.
interface ISzipNavProvision {
    function provision() external view returns (uint256);
}

/// @dev The senior pool (`EulerEarn`, ERC-4626 over USDC). `deposit(assets, receiver)` pulls `assets` from the caller
///      (the engine Safe) and mints shares to `receiver` (the warehouse). Local interface only — same surface
///      `ZipDepositModule` uses. `reference/euler-earn/src/EulerEarn.sol:560`.
interface IEulerEarn {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @title RecycleModule
/// @notice The 8-B10 engine module (§4.5.1) — the auto-compounder's **free-value ledger** and the spends that draw it
///         down. A CRE-operator-gated Zodiac Module (sibling of 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6
///         LP-strategy, 8-B7 harvest/vote, 8-B8 exercise, 8-B9 sell), enabled on the szipUSD engine Safe
///         (`avatar == target == engineSafe`). It owns the engine's ONE piece of real mutable state — the single
///         `freeValueAccrued` accumulator (no other module writes it; the CRE operator is the only writer, §8 inv. 3) —
///         and spends it through TWO sinks, both debiting the same ledger:
///         (1) `recycle` (NAV accretion) deposits the free-value USDC as senior backing + mints backed zipUSD 1:1 into
///             the basket (the MAIN Safe holds it in place — no `gate.depositFor`, no share issuance); 8-B6 then
///             single-sides that zipUSD into the ICHI LP. The basket grows, share count is flat → NAV-per-share rises
///             for every holder.
///         (2) `divert` (loss-side Stream 2, `solvency.md` §C.S1) supplies the free-value USDC as RAW USDC into the
///             senior pool crediting the warehouse (`eePool.deposit(amount, warehouse)`, NO zipUSD minted), bounded by
///             the live `provision()` hole — filling the capital hole a default left behind so depositors stay whole.
///         No payout, no xALPHA, no distributor (the prior Mode A/B/C framing + 8-B13 compounder are removed —
///         single-sided LP removes the balanced-add/swap machinery they carried).
///
/// @dev SIBLING of `SellModule` (8-B9) / `ExerciseModule` (8-B8): same `is Module` + `setUp(bytes)`-under-`initializer`
///      + `onlyOperator` + `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles. The
///      structural differences: (a) instead of a swap it drives the `ZipDepositModule.deposit` backed-mint; (b) it
///      carries REAL state (`freeValueAccrued`) — the only engine module that does.
///
/// @dev FREE-VALUE-ONLY, ENFORCED TWO-LAYER (the load-bearing invariant, `auto-compounder.md` §8 inv. 3):
///      (a) POLICY CEILING — `recycle` debits `freeValueAccrued` and reverts if it would go negative, so the engine
///          can never *route* more than the HYDX-extracted free value the CRE credited; and
///      (b) HARD BACKING — the actual USDC moved is pulled from the **Safe's real balance** by the `_exec` legs
///          (`ZipDepositModule.deposit` does `safeTransferFrom(Safe,...)`), so even an over-credited accumulator cannot
///          conjure value (the deposit reverts if the Safe is short). The zipUSD is backed 1:1 by construction (the
///          deposit parks the USDC as senior backing BEFORE the mint).
///      TRUST BOUNDARY (§17 single immutable CRE operator): `creditFreeValue` is UNBOUNDED — layer (a) is
///      operator-TRUSTED, not a cryptographic guarantee. Bounded by the single trusted CRE writer + the 8-B11
///      fund-discipline / 8-B12 tripwire (off-chain backstops). The recycle is a REALIZED reinvestment, never a NAV
///      markup — this module never touches `SzipNavOracle` (§8 inv. 7 / `auto-compounder.md` §7).
///
/// @dev CLONE FACT (§18.6, proven on 8-B5..B9/B14): a `ModuleProxyFactory` clone shares the mastercopy's runtime
///      bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY
///      per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`. The
///      mastercopy is init-locked in its constructor (see {MastercopyInitLock}). (No OZ `ReentrancyGuard` on the module: a clone never runs the guard's
///      constructor, and the siblings avoid it — the reentrancy safety here is effects-before-interaction, i.e. the
///      `_spendFreeValue` decrement lands BEFORE the value-moving `_exec`s, plus the set-once trusted wired targets +
///      `ZipDepositModule`'s own `nonReentrant`.)
contract RecycleModule is MastercopyInitLock {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == engineSafe`); the free-value source + the deposit/mint recipient.
    address public engineSafe;
    /// @notice The single CRE operator (gates the action legs + `creditFreeValue`).
    address public operator;
    /// @notice The WOOF-06 zap (`ZipDepositModule`) — the backed-mint path (deposit -> senior backing + mint).
    address public zipDepositModule;
    /// @notice USDC — the free-value asset; the `recycle` deposit input + the `divert` supply input.
    address public usdc;

    /// @notice The `SzipNavOracle` — the `provision()` hole-size read (Stream 2 bound). Set-once, Timelock-re-pointable.
    address public navOracle;
    /// @notice The `EulerEarn` senior pool the warehouse supplies into (Stream 2 sink). Set-once, Timelock-re-pointable.
    address public eePool;
    /// @notice The `CreditWarehouse` Safe — the `eePool.deposit` share **receiver** (the bank). Set-once, re-pointable.
    address public warehouse;

    /// @notice The engine's free-value ledger (USDC, 6-dp): credited by the CRE after each harvest loop, debited by the
    ///         recycle leg (NAV accretion) AND the divert leg (Stream 2, fill the bank). The ONLY mutable state.
    ///         8-B10-owned — no other module writes it.
    uint256 public freeValueAccrued;

    /// @notice The last `provision()` hole observed by `divert` (18-dp USD). Pairs with `divertedSinceProvisionChange`
    ///         to bound diverts CUMULATIVELY against the live hole across calls (SEC-09). `0` is a safe "never observed"
    ///         sentinel: `divert` reverts `NoHole` on `hole == 0`, so the reset block can never set this to 0.
    uint256 public lastSeenProvision;
    /// @notice Running tally (18-dp USD) of USDC diverted into the senior pool since the last provision re-mark — reset
    ///         to 0 whenever `divert` observes a changed `provision()`. Bounds the cumulative divert per provision-epoch.
    uint256 public divertedSinceProvisionChange;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    error InsufficientFreeValue();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();
    /// @notice `divert` was called with `provision() == 0` — there is no hole to fill (Stream 2).
    error NoHole();
    /// @notice `divert` would over-fill the hole (`usdcAmount * 1e12 > provision()`) — bounded by the live provision.
    error ExceedsHole();
    /// @notice The `eePool.deposit` did not credit the warehouse with new shares (false-return / FoT / no-op pool guard).
    error NoSharesMinted();
    /// @notice The deposit did not pull exactly `usdcAmount` USDC from the engine Safe (hard-backing / value guard).
    error BackingShortfall();

    // --------------------------------------------------------------------- events
    event FreeValueCredited(uint256 amount, uint256 newAccrued);
    event FreeValueSpent(uint256 amount, uint256 newAccrued);
    event Recycled(uint256 usdcAmount, uint256 zipMinted);
    /// @notice Stream 2: `usdcAmount` USDC supplied into `eePool` crediting `warehouse`. `provisionAfter` is the live
    ///         hole at divert time — divert does NOT itself write provision (the CRE reduces it later via
    ///         `DefaultCoordinator.Recovery`), so it equals the pre-spend `provision()` read.
    event Filled(uint256 usdcAmount, address indexed warehouse, uint256 provisionAfter);
    /// @notice A Timelock-settable wiring slot was re-pointed (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). Decodes 8 addresses
    ///         `(owner, engineSafe, operator, zipDepositModule, usdc, navOracle, eePool, warehouse)`. ORDER is
    ///         load-bearing: validate ALL 8 decoded addresses nonzero FIRST + `owner != operator` (so a zero address
    ///         reverts `ZeroAddress` deterministically before any use), set `avatar = target = engineSafe`, store the
    ///         wiring, THEN `_transferOwnership(owner)`. No live-read / staticcall in `setUp`.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address engineSafe_,
            address operator_,
            address zipDepositModule_,
            address usdc_,
            address navOracle_,
            address eePool_,
            address warehouse_
        ) = abi.decode(initParams, (address, address, address, address, address, address, address, address));

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0)
                || zipDepositModule_ == address(0) || usdc_ == address(0) || navOracle_ == address(0)
                || eePool_ == address(0) || warehouse_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (owner_ == operator_) revert OwnerIsOperator();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == engineSafe.
        avatar = engineSafe_;
        target = engineSafe_;

        engineSafe = engineSafe_;
        operator = operator_;
        zipDepositModule = zipDepositModule_;
        usdc = usdc_;
        navOracle = navOracle_;
        eePool = eePool_;
        warehouse = warehouse_;

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the hot
    //      key) CANNOT call them — only `owner` (the Timelock). We do NOT hard-lock them (that would dirty the vendored
    //      zodiac-core setters by marking them `virtual`). Tested: a non-owner caller reverts.

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)
    /// @notice Re-point `engineSafe` (build phase, §17). onlyOwner (Timelock).
    function setEngineSafe(address engineSafe_) external onlyOwner {
        if (engineSafe_ == address(0)) revert ZeroAddress();
        engineSafe = engineSafe_;
        emit WiringSet("engineSafe", engineSafe_);
    }

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `zipDepositModule` (build phase, §17). onlyOwner (Timelock).
    function setZipDepositModule(address zipDepositModule_) external onlyOwner {
        if (zipDepositModule_ == address(0)) revert ZeroAddress();
        zipDepositModule = zipDepositModule_;
        emit WiringSet("zipDepositModule", zipDepositModule_);
    }

    /// @notice Re-point `usdc` (build phase, §17). onlyOwner (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point `navOracle` (build phase, §17). onlyOwner (Timelock).
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert ZeroAddress();
        navOracle = navOracle_;
        emit WiringSet("navOracle", navOracle_);
    }

    /// @notice Re-point `eePool` (build phase, §17). onlyOwner (Timelock).
    function setEePool(address eePool_) external onlyOwner {
        if (eePool_ == address(0)) revert ZeroAddress();
        eePool = eePool_;
        emit WiringSet("eePool", eePool_);
    }

    /// @notice Re-point `warehouse` (build phase, §17). onlyOwner (Timelock).
    function setWarehouse(address warehouse_) external onlyOwner {
        if (warehouse_ == address(0)) revert ZeroAddress();
        warehouse = warehouse_;
        emit WiringSet("warehouse", warehouse_);
    }

    // --------------------------------------------------------------------- the accumulator (CRE-written)
    /// @notice Increment the free-value ledger. `onlyOperator`. The operand is the USDC realized by the 8-B9 sell
    ///         **net of** the 8-B5 strike-borrow repaid for that loop — the CRE passes `max(0, realized − borrowRepaid)`
    ///         (only HYDX sold above the ~30% strike is free value). SINGLE-ARG + operator-trusted: the module cannot
    ///         reconstruct `realized`/`borrowRepaid` on-chain (historical), exactly as every sibling trusts the single
    ///         immutable CRE to size scalars (§17). 8-B9 does NOT credit — this is 8-B10's owned accumulator.
    function creditFreeValue(uint256 amount) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        freeValueAccrued += amount;
        emit FreeValueCredited(amount, freeValueAccrued);
    }

    /// @dev The single debit path. Effects FIRST — the decrement lands before any value-moving `_exec`, so a re-entrant
    ///      spend can't double-spend the same budget. Reverts `InsufficientFreeValue` if `amount > freeValueAccrued`.
    function _spendFreeValue(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > freeValueAccrued) revert InsufficientFreeValue();
        freeValueAccrued -= amount;
        emit FreeValueSpent(amount, freeValueAccrued);
    }

    // --------------------------------------------------------------------- the recycle sink (deposit -> backed mint)
    /// @notice Spend `usdcAmount` of free value into senior backing + a backed zipUSD mint into the basket. Debits the
    ///         accumulator FIRST, then drives the Safe: `usdc.approve(zipDepositModule, usdcAmount)` ->
    ///         `zipDepositModule.deposit(usdcAmount)` (mints `usdcAmount * scaleUp` BACKED zipUSD to the Safe, parks the
    ///         USDC as senior warehouse backing) -> `usdc.approve(zipDepositModule, 0)` (reset). 8-B6 single-sides the
    ///         minted zipUSD into the LP next (CRE-sequenced). The basket grows, share count is flat → NAV accretes.
    /// @return zipMinted The backed zipUSD minted to the Safe (decoded from the `deposit` return).
    function recycle(uint256 usdcAmount) external onlyOperator returns (uint256 zipMinted) {
        _spendFreeValue(usdcAmount); // effects first (the policy gate)

        address zdm = zipDepositModule;
        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, zdm, usdcAmount));
        bytes memory ret = _exec(zdm, abi.encodeCall(IZipDepositModule.deposit, (usdcAmount)));
        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, zdm, uint256(0)));

        zipMinted = abi.decode(ret, (uint256));
        emit Recycled(usdcAmount, zipMinted);
    }

    // --------------------------------------------------------------------- the divert sink (Stream 2 — fill the bank)
    /// @notice STREAM 2 (`solvency.md` §C.S1): supply `usdcAmount` of free value as **raw USDC** into the senior pool
    ///         crediting the **warehouse** — `eePool.deposit(usdcAmount, warehouse)`, **NO zipUSD minted** — so the
    ///         warehouse's USDC backing rises toward ≥ zipUSD owed, filling the capital hole a default left behind. A
    ///         SECOND spend of `freeValueAccrued` (distinct from `recycle`'s backed-mint-into-the-basket sink); both
    ///         debit the same ledger and leave the other working on the remainder. Bounded CUMULATIVELY by the LIVE hole
    ///         (`provision()`): the total diverted across calls can never over-fill it WITHIN a provision-epoch (SEC-09).
    ///
    /// @dev ORDER is load-bearing — **bounds-before-spend, then CEI**: (a) `usdcAmount > 0`; (b) read the hole, revert
    ///      `NoHole` if 0; (c) **reset-on-change** — if the observed `hole != lastSeenProvision` the provision was
    ///      re-marked, so adopt it (`lastSeenProvision = hole`) and zero the tally (`divertedSinceProvisionChange = 0`);
    ///      (d) revert `ExceedsHole` if `divertedSinceProvisionChange + usdcAmount * 1e12 > hole` (`1e12` scales USDC
    ///      6-dp → USD 18-dp; strict `>` allows an EXACT cumulative fill, never an over-fill) — these checks land BEFORE
    ///      any ledger debit, so an over-hole/no-hole divert records no exec and leaves the ledger untouched; (e)
    ///      `_spendFreeValue` (effects first — the policy gate), then `divertedSinceProvisionChange += scaled` (also
    ///      effects-phase, so a reentrant divert sees the updated tally — it rolls back atomically with the ledger if a
    ///      post-deposit guard reverts); (f) the Safe drives `approve(eePool, usdcAmount)` → `deposit(usdcAmount,
    ///      warehouse)` → `approve(eePool, 0)`. TWO value guards after the deposit: **hard backing** — the Safe's USDC
    ///      MUST have fallen by exactly `usdcAmount` (`BackingShortfall`, proves real value moved, not a trusted-pool
    ///      no-op); and **liveness** — the warehouse's EE-share balance MUST have risen (`NoSharesMinted`, the
    ///      false-return/FoT guard, since the Safe swallows inner reverts). Divert never WRITES `provision` (the CRE
    ///      reduces the hole later via `DefaultCoordinator.Recovery`); the cumulative bound is enforced by OBSERVING
    ///      `provision()` and resetting the tally on any change.
    ///
    /// @dev CUMULATIVE GUARANTEE is **per-provision-epoch** (between re-marks): because the tally resets whenever a new
    ///      hole is observed, total diverted ≤ hole holds within each epoch but NOT across re-marks — a `$100 → $80 →
    ///      $100` re-mark does NOT resurrect the prior `$100`-epoch tally (the value-key approach would; this last-seen +
    ///      single-counter approach does not). Cross-epoch over-supply of the senior pool is possible but benign — extra
    ///      USDC backing only strengthens the peg, and every spend is hard-capped by `freeValueAccrued` (a finite
    ///      CRE-credited budget) + the trusted single CRE writer (§17). `lastSeenProvision == 0` is a safe "never
    ///      observed" sentinel because `hole == 0` reverts `NoHole`, so the reset block can never set it to 0.
    /// @return sent The USDC supplied (== `usdcAmount`).
    function divert(uint256 usdcAmount) external onlyOperator returns (uint256 sent) {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 hole = ISzipNavProvision(navOracle).provision(); // read fresh each call (no memoization)
        if (hole == 0) revert NoHole();
        // reset-on-change: a re-marked provision starts a fresh epoch budget (never keyed by value — see docstring).
        if (hole != lastSeenProvision) {
            lastSeenProvision = hole;
            divertedSinceProvisionChange = 0;
        }
        // bounds-before-spend, CUMULATIVE: USDC 6-dp -> USD 18-dp; strict `>` so an exact cumulative fill is allowed.
        uint256 scaled = usdcAmount * 1e12;
        if (divertedSinceProvisionChange + scaled > hole) revert ExceedsHole();

        _spendFreeValue(usdcAmount); // effects first (the policy gate; the CEI decrement)
        divertedSinceProvisionChange += scaled; // effects-phase tally bump (before the value-moving execs)

        address pool = eePool;
        address wh = warehouse;
        address safe = engineSafe;

        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, pool, usdcAmount));
        uint256 beforeUsdc = IERC20(usdc).balanceOf(safe);
        uint256 beforeShares = IERC20(pool).balanceOf(wh);
        _exec(pool, abi.encodeCall(IEulerEarn.deposit, (usdcAmount, wh)));
        // hard backing: the deposit MUST have pulled exactly `usdcAmount` from the Safe (value conservation).
        if (beforeUsdc - IERC20(usdc).balanceOf(safe) != usdcAmount) revert BackingShortfall();
        // liveness: the warehouse MUST have been credited new senior shares (catches a no-op / FoT / false-return pool).
        if (IERC20(pool).balanceOf(wh) <= beforeShares) revert NoSharesMinted();
        _exec(usdc, abi.encodeWithSelector(IERC20.approve.selector, pool, uint256(0)));

        sent = usdcAmount;
        emit Filled(usdcAmount, wh, hole);
    }

    // --------------------------------------------------------------------- exec (Call-only, value 0, bubble-on-fail)
    /// @dev Drive the Safe via the inherited `execAndReturnData` (Operation.Call, value 0) and HARD-REVERT if it
    ///      returns false — BUBBLING the inner revert data (the Gnosis Safe `execTransactionFromModuleReturnData`
    ///      catches inner reverts and returns `(false, revertData)` rather than bubbling, so an unchecked `exec` would
    ///      silently swallow a failed deposit/transfer). Returns the inner return data (only `recycle` decodes it —
    ///      the `deposit`'s `zipMinted`).
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
}
