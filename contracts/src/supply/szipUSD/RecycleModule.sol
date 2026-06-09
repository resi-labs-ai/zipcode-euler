// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";
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

/// @title RecycleModule
/// @notice The 8-B10 engine module (§4.5.1) — the auto-sodomizer's **free-value ledger** and its ONE recycle sink. A
///         CRE-operator-gated Zodiac Module (sibling of 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6 LP-strategy, 8-B7
///         harvest/vote, 8-B8 exercise, 8-B9 sell), enabled on the szipUSD engine Safe
///         (`avatar == target == engineSafe`). It owns the engine's ONE piece of real mutable state — the single
///         `freeValueAccrued` accumulator (no other module writes it; the CRE operator is the only writer, §8 inv. 3) —
///         and routes that free value into the vault basket: `recycle` deposits the free-value USDC as senior backing
///         + mints backed zipUSD 1:1 into the basket (the MAIN Safe holds it in place — no `gate.depositFor`, no share
///         issuance). 8-B6 then single-sides that zipUSD into the ICHI LP. The basket grows, share count is flat →
///         NAV-per-share rises for every holder. There is ONE sink (recycle → NAV), no payout, no xALPHA, no
///         distributor (the prior Mode A/B/C framing + 8-B13 compounder are removed — single-sided LP removes the
///         balanced-add/swap machinery they carried).
///
/// @dev SIBLING of `SellModule` (8-B9) / `ExerciseModule` (8-B8): same `is Module` + `setUp(bytes)`-under-`initializer`
///      + `onlyOperator` + `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles. The
///      structural differences: (a) instead of a swap it drives the `ZipDepositModule.deposit` backed-mint; (b) it
///      carries REAL state (`freeValueAccrued`) — the only engine module that does.
///
/// @dev FREE-VALUE-ONLY, ENFORCED TWO-LAYER (the load-bearing invariant, `auto-sodomizer.md` §8 inv. 3):
///      (a) POLICY CEILING — `recycle` debits `freeValueAccrued` and reverts if it would go negative, so the engine
///          can never *route* more than the HYDX-extracted free value the CRE credited; and
///      (b) HARD BACKING — the actual USDC moved is pulled from the **Safe's real balance** by the `_exec` legs
///          (`ZipDepositModule.deposit` does `safeTransferFrom(Safe,...)`), so even an over-credited accumulator cannot
///          conjure value (the deposit reverts if the Safe is short). The zipUSD is backed 1:1 by construction (the
///          deposit parks the USDC as senior backing BEFORE the mint).
///      TRUST BOUNDARY (§17 single immutable CRE operator): `creditFreeValue` is UNBOUNDED — layer (a) is
///      operator-TRUSTED, not a cryptographic guarantee. Bounded by the single trusted CRE writer + the 8-B11
///      fund-discipline / 8-B12 tripwire (off-chain backstops). The recycle is a REALIZED reinvestment, never a NAV
///      markup — this module never touches `SzipNavOracle` (§8 inv. 7 / `auto-sodomizer.md` §7).
///
/// @dev CLONE FACT (§18.6, proven on 8-B5..B9/B14): a `ModuleProxyFactory` clone shares the mastercopy's runtime
///      bytecode, so `immutable` is identical for every clone — it CANNOT carry per-clone `setUp` config. EVERY
///      per-clone wired address is plain set-once storage written in `setUp` under `initializer`, NOT `immutable`. The
///      mastercopy is init-locked at deploy. (No OZ `ReentrancyGuard` on the module: a clone never runs the guard's
///      constructor, and the siblings avoid it — the reentrancy safety here is effects-before-interaction, i.e. the
///      `_spendFreeValue` decrement lands BEFORE the value-moving `_exec`s, plus the set-once trusted wired targets +
///      `ZipDepositModule`'s own `nonReentrant`.)
contract RecycleModule is Module {
    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The engine Safe (`avatar == target == engineSafe`); the free-value source + the deposit/mint recipient.
    address public engineSafe;
    /// @notice The single CRE operator (gates the action legs + `creditFreeValue`).
    address public operator;
    /// @notice The WOOF-06 zap (`ZipDepositModule`) — the backed-mint path (deposit -> senior backing + mint).
    address public zipDepositModule;
    /// @notice USDC — the free-value asset; the `recycle` deposit input.
    address public usdc;

    /// @notice The engine's free-value ledger (USDC, 6-dp): credited by the CRE after each harvest loop, debited by the
    ///         recycle leg. The ONLY mutable state. 8-B10-owned — no other module writes it.
    uint256 public freeValueAccrued;

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error ZeroAmount();
    error InsufficientFreeValue();
    /// @notice An `exec` through the Safe returned `false` (the Safe swallows inner reverts) with no revert data.
    error ExecFailed();

    // --------------------------------------------------------------------- events
    event FreeValueCredited(uint256 amount, uint256 newAccrued);
    event FreeValueSpent(uint256 amount, uint256 newAccrued);
    event Recycled(uint256 usdcAmount, uint256 zipMinted);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (or the mastercopy at deploy, then init-locked). Decodes 5 addresses
    ///         `(owner, engineSafe, operator, zipDepositModule, usdc)`. ORDER is load-bearing: validate ALL 5 decoded
    ///         addresses nonzero FIRST + `owner != operator` (so a zero address reverts `ZeroAddress` deterministically
    ///         before any use), set `avatar = target = engineSafe`, store the wiring, THEN `_transferOwnership(owner)`.
    ///         No live-read / staticcall in `setUp`.
    function setUp(bytes memory initParams) public override initializer {
        (address owner_, address engineSafe_, address operator_, address zipDepositModule_, address usdc_) =
            abi.decode(initParams, (address, address, address, address, address));

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0)
                || zipDepositModule_ == address(0) || usdc_ == address(0)
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
