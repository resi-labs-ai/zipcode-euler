// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MastercopyInitLock} from "./MastercopyInitLock.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";
import {IGPv2Settlement} from "../../interfaces/cow/IGPv2Settlement.sol";

/// @dev The minimal NAV oracle surface this module reads (`SzipNavOracle`): the buyer-conservative §3 mark and the
///      issuance-freshness gate. Priced off `navExit()` (= `min(spot, twap)`, does NOT revert on staleness), gated on
///      `fresh()` (both required pushed legs within `maxAge`).
interface INavOracle {
    function navExit() external view returns (uint256);
    function fresh() external view returns (bool);
    function maxAge() external view returns (uint256);
    function oldestRequiredLegTs() external view returns (uint48);
}

/// @dev The minimal ERC20 surface the module needs (the USDC `approve` the module builds calldata for).
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev The coverage seam the `postBid` outflow gate reads (the `DurationFreezeModule`): a buy-and-burn bid is a
///      free-side outflow, blocked while coverage is below the liability floor (build/lp-path-lock.md).
interface ICoverageGate {
    function covered() external view returns (bool);
}

/// @title SzipBuyBurnModule
/// @notice The §7 "haircut buy-and-burn" BID side (8-B14): a CRE-operator-gated Zodiac Module enabled on the engine
///         Safe (`avatar == target == engineSafe`) that makes the protocol the **discounted buyer of last resort**
///         for szipUSD. On the operator's tick it posts a SINGLE resting CoW `BUY szipUSD` limit order
///         (`sellToken = USDC`, `receiver = engineSafe`, `partiallyFillable`), priced **at or below
///         `navExit × (1 − d)`** off `SzipNavOracle`, `sellAmount ≤ buybackCap`, signed on-chain via PRESIGN
///         (`GPv2Settlement.setPreSignature`). Everything it buys lands in the engine Safe; the BURN is the existing
///         `ExitGate.burnFor` (the CRE windowController's authority — OUT of this contract's scope).
///         `baal-spec.md` §7 / §10.1; `claude-zipcode.md` §4.5.1 / §17.
///
/// @dev CRITICAL clone fact (§18.6): a `ModuleProxyFactory` clone shares the mastercopy's runtime bytecode, so
///      `immutable` values are baked into the mastercopy at ITS construction and are identical for every clone — they
///      CANNOT carry per-clone `setUp` config. EVERY per-clone wired address/param is therefore plain set-once
///      storage written in `setUp` under `initializer`, NOT `immutable`. The mastercopy is init-locked in its constructor (see {MastercopyInitLock}).
///
/// @dev SCALING TO A GLOBAL WIND-DOWN (the system-wide RQ exit — CRE-orchestrated, no new exit primitive).
///      This module is the protocol's ONLY exit valve and the hinge of any full unwind. There is no global
///      `baal.ragequit` wired (deliberate — see ExitGate): a complete exit is an **orchestrated CoW drain**, opt-in
///      by construction (holders must post the SELL szipUSD; the protocol can only rest the standing BID). Nothing
///      here changes for a wind-down — it is the SAME bid, sized larger and re-posted until supply is zero.
///
///      The drain is bounded by ONE fact: a resting bid fills only against USDC actually in the engine Safe at
///      solver-settlement time. So a global exit is a feeder pipeline into this Safe, choreographed by the CRE:
///        1. LIQUIDATE every basket leg to USDC via the existing driver modules — unstake LP from the gauge
///           (`LpStrategyModule`), exercise/sell rewards (`ExerciseModule`/`SellModule`), repay reservoir debt
///           (`ReservoirLoopModule`), and run zipUSD → USDC through the senior par sink (`OffRampModule` +
///           `ZipRedemptionQueue`). At utilization 0% the whole reservoir is free, so 100%-depth funding is reachable.
///        2. CONSOLIDATE the proceeds as USDC in the engine Safe (the `receiver`/`owner` of every bid).
///        3. RAISE `buybackCap` (Timelock) toward the total NAV value of `szipUSD.totalSupply()`, and keep the
///           resting bid posted at `navExit × (1 − d)`. The single-resting-bid invariant means the CRE operator
///           `cancelBid` → `postBid` to re-arm as fills consume `currentSellAmount` (watch `currentBid()`); each
///           bought tranche lands in the Safe and is retired by `ExitGate.burnFor` (windowController authority).
///      Because `burnFor` is pure supply reduction matched by the asset outflow that funded the bid, NAV-per-share
///      holds ~flat as the book drains — every exiter clears at the same NAV-minus-haircut mark, 1:1 with backing,
///      until `szipUSD.totalSupply() == 0`. `dBps` is the only value lever (haircut → split between stayers and
///      mercenary stinkbidders); `buybackCap == 0` is the kill switch. The wind-down is therefore CRE policy over
///      this unchanged surface — the work is the feeder modules + the orchestration, never a new exit mechanism.
contract SzipBuyBurnModule is MastercopyInitLock {
    // --------------------------------------------------------------------- GPv2 canonical constants (verified `cast`)
    /// @notice The canonical GPv2 order EIP-712 type hash (verified `cast keccak` of the order string).
    bytes32 public constant TYPE_HASH = 0x1a59c8ffcce6fc2e6738119e0d2e050163ef0912ac7168f28acd39badd252b51;
    /// @notice `keccak256("buy")` — the order kind (BUY only; never an operator input).
    bytes32 public constant KIND_BUY = 0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc;
    /// @notice `keccak256("erc20")` — sell/buy token balance source (plain ERC20).
    bytes32 public constant BALANCE_ERC20 = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;
    /// @notice The single pinned appData. A non-zero/unconstrained appData could attach hooks/partner-fees the
    ///         validation never saw — pin it to a constant so the signed order carries no unvalidated surface.
    /// @dev kill-list M3: buy-burn FILL is INTENTIONALLY not fill-time coverage-gated. The `postBid` `covered()` gate
    ///      below gates POSTING, not the solver fill — but a fill after coverage drifts below the floor cannot breach
    ///      it, because the USDC the bid spends is engine-Safe value that `coverageValue()` already EXCLUDES (it is
    ///      free-side, not committed sidecar value). Adding a CoW pre-/post-interaction HOOK to re-check coverage at
    ///      fill is REJECTED — `APP_DATA == 0` deliberately forbids any hook (the rejection is the finding). (The
    ///      undercovered-fill WINDOW is bounded by the NAV freshness `maxAge`; optionally shrinking the DEPLOYED
    ///      `NAV_MAX_AGE` to tighten it is a deploy-tuning decision, not changed here — §6/§7.)
    bytes32 public constant APP_DATA = bytes32(0);

    // --------------------------------------------------------------------- module bounds
    /// @notice The max resting-bid TTL: a bid's `validTo` must be in `(now, now + MAX_BID_TTL]`. Far-but-bounded
    ///         resting exposure (pinned 1 day).
    uint32 public constant MAX_BID_TTL = 1 days;
    /// @notice A sanity upper bound on the operator-supplied (NOT cap-bounded) `buyAmount`, guarding the price-bound
    ///         products against any pathological overflow (1e30 szipUSD = 1e12 whole tokens — far beyond realistic).
    uint256 public constant MAX_BUY_AMOUNT = 1e30;

    // --------------------------------------------------------------------- set-once storage (NOT immutable — clone)
    /// @notice The single CRE operator (gates `postBid`/`cancelBid`).
    address public operator;
    /// @notice The engine Safe (`avatar == target == engineSafe`); the order `receiver` and the uid `owner`.
    address public engineSafe;
    /// @notice The `SzipNavOracle` (the pricing primitive — priced off `navExit()`, gated on `fresh()`).
    address public navOracle;
    /// @notice The szipUSD share token (the `buyToken`, 18-dp).
    address public szipUSD;
    /// @notice USDC (the `sellToken`, 6-dp).
    address public usdc;
    /// @notice The CoW `GPv2Settlement` (PRESIGN target).
    address public settlement;
    /// @notice The CoW `GPv2VaultRelayer` (the USDC `approve` spender; read live in `setUp`).
    address public vaultRelayer;
    /// @notice The coverage gate (`DurationFreezeModule`) — `postBid` is blocked while `!covered()`. Zero ⇒ gate OFF
    ///         (M1 pre-wiring; legacy behavior). Wired by the Timelock post-deploy (build/lp-path-lock.md).
    address public coverageGate;
    /// @notice The CoW EIP-712 domain separator for this chain (read live in `setUp`).
    bytes32 public domainSeparator;

    // --------------------------------------------------------------------- governed params (onlyOwner setters)
    /// @notice The discount, in bps: the implied limit price must be ≤ `navExit × (10_000 − dBps)/10_000`. In
    ///         `(0, 10_000)` strictly.
    uint16 public dBps;
    /// @notice The per-bid USDC cap (6-dp). `buybackCap == 0` ⇒ every `postBid` reverts (the kill-switch).
    uint256 public buybackCap;

    // --------------------------------------------------------------------- live-bid state
    /// @notice The uid of the live resting bid (empty ⇒ no live bid). Single-resting-bid invariant.
    bytes public currentUid;
    /// @notice The USDC `sellAmount` (= outstanding VaultRelayer allowance) of the live bid.
    uint256 public currentSellAmount;

    // --------------------------------------------------------------------- operator-supplied order (3 fields only)
    /// @notice The ONLY operator-supplied order fields. Every other GPv2 field is a module-fixed constant (the §4
    ///         hardening — no unvalidated field enters the hash). The module validates these, builds the full
    ///         canonical order from `(usdc, szipUSD, engineSafe, sellAmount, buyAmount, validTo, APP_DATA, 0,
    ///         KIND_BUY, true, BALANCE_ERC20, BALANCE_ERC20)`, and hashes EXACTLY that into the uid.
    struct GPv2OrderInput {
        uint256 sellAmount; // USDC (6-dp) — validated ≤ buybackCap, > 0
        uint256 buyAmount; // szipUSD (18-dp) — validated > 0, ≤ MAX_BUY_AMOUNT; sets the limit price with sellAmount
        uint32 validTo; // unix expiry — validated > now, ≤ now + MAX_BID_TTL
    }

    // --------------------------------------------------------------------- errors
    error NotOperator();
    error ZeroAddress();
    error OwnerIsOperator();
    error BadDiscount();
    error BidAlreadyLive();
    error ZeroAmount();
    error CapExceeded();
    error BadValidTo();
    error ValidToBeyondNavFreshness();
    error StaleNav();
    error BidAboveDiscount();
    error BuyAmountTooLarge();
    /// @notice `postBid` blocked: coverage is below the liability floor (the path-lock outflow gate).
    error Undercovered();

    // --------------------------------------------------------------------- events
    event BidPosted(
        bytes uid, uint256 sellAmount, uint256 buyAmount, uint32 validTo, uint256 navExit18, uint16 dBps
    );
    event BidCancelled(bytes uid);
    event DiscountSet(uint16 dBps);
    event BuybackCapSet(uint256 buybackCap);
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (the mastercopy is locked in its constructor and CANNOT be setUp). One-shot via the
    ///         zodiac-core `initializer`. Decodes `(owner, engineSafe, operator, navOracle, szipUSD, usdc,
    ///         settlement, dBps, buybackCap, coverageGate)`; reads the VaultRelayer + domain separator LIVE off the
    ///         settlement. `coverageGate` MAY be address(0) (gate OFF) — no zero-check, mirrors setCoverageGate.
    function setUp(bytes memory initParams) public override initializer {
        (
            address owner_,
            address engineSafe_,
            address operator_,
            address navOracle_,
            address szipUSD_,
            address usdc_,
            address settlement_,
            uint16 dBps_,
            uint256 buybackCap_,
            address coverageGate_
        ) = abi.decode(
            initParams, (address, address, address, address, address, address, address, uint16, uint256, address)
        );

        if (
            owner_ == address(0) || engineSafe_ == address(0) || operator_ == address(0) || navOracle_ == address(0)
                || szipUSD_ == address(0) || usdc_ == address(0) || settlement_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == operator_) revert OwnerIsOperator();
        if (dBps_ == 0 || dBps_ >= 10_000) revert BadDiscount();

        // The module is enabled ON the engine Safe and only ever mutates it: avatar == target == engineSafe.
        avatar = engineSafe_;
        target = engineSafe_;

        engineSafe = engineSafe_;
        operator = operator_;
        navOracle = navOracle_;
        szipUSD = szipUSD_;
        usdc = usdc_;
        settlement = settlement_;
        dBps = dBps_;
        buybackCap = buybackCap_;
        coverageGate = coverageGate_; // gate ON at deploy (the freeze module); address(0) = OFF (legacy)

        // Read the spender + domain separator LIVE off the settlement (do not hard-trust a constant), cache them.
        vaultRelayer = IGPv2Settlement(settlement_).vaultRelayer();
        domainSeparator = IGPv2Settlement(settlement_).domainSeparator();

        _transferOwnership(owner_);
    }

    // --------------------------------------------------------------------- gates
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // @dev `setAvatar`/`setTarget` are inherited from zodiac-core `Module` as `onlyOwner`. The CRE `operator` (the
    //      hot key) CANNOT call them — only `owner` (the TimelockController) can, and a redirect by governance is a
    //      deliberate, timelocked act, not an attack path. We do NOT hard-lock them: that would require marking the
    //      vendored `reference/zodiac-core` setters `virtual`, and reference deps are kept pristine. Residual: a
    //      compromised Timelock could redirect avatar/target — accepted (the same Timelock governs the whole module).
    //      The operator-can't-redirect property IS tested (a non-owner caller reverts in the inherited onlyOwner).

    // --------------------------------------------------------------------- governed params
    function setDiscountBps(uint16 dBps_) external onlyOwner {
        if (dBps_ == 0 || dBps_ >= 10_000) revert BadDiscount();
        dBps = dBps_;
        emit DiscountSet(dBps_);
    }

    function setBuybackCap(uint256 buybackCap_) external onlyOwner {
        buybackCap = buybackCap_;
        emit BuybackCapSet(buybackCap_);
    }

    // --- Timelock-settable wiring (build phase, §17) ---

    /// @notice Re-point `operator` (build phase, §17). onlyOwner (Timelock).
    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == owner) revert OwnerIsOperator();
        operator = operator_;
        emit WiringSet("operator", operator_);
    }

    /// @notice Re-point `engineSafe` (build phase, §17). onlyOwner (Timelock).
    function setEngineSafe(address engineSafe_) external onlyOwner {
        if (engineSafe_ == address(0)) revert ZeroAddress();
        engineSafe = engineSafe_;
        emit WiringSet("engineSafe", engineSafe_);
    }

    /// @notice Re-point `navOracle` (build phase, §17). onlyOwner (Timelock).
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert ZeroAddress();
        navOracle = navOracle_;
        emit WiringSet("navOracle", navOracle_);
    }

    /// @notice Re-point `szipUSD` (build phase, §17). onlyOwner (Timelock).
    function setSzipUSD(address szipUSD_) external onlyOwner {
        if (szipUSD_ == address(0)) revert ZeroAddress();
        szipUSD = szipUSD_;
        emit WiringSet("szipUSD", szipUSD_);
    }

    /// @notice Re-point `usdc` (build phase, §17). onlyOwner (Timelock).
    function setUsdc(address usdc_) external onlyOwner {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit WiringSet("usdc", usdc_);
    }

    /// @notice Re-point `settlement` (build phase, §17). onlyOwner (Timelock).
    function setSettlement(address settlement_) external onlyOwner {
        if (settlement_ == address(0)) revert ZeroAddress();
        settlement = settlement_;
        emit WiringSet("settlement", settlement_);
    }

    /// @notice Re-point `vaultRelayer` (build phase, §17). onlyOwner (Timelock).
    function setVaultRelayer(address vaultRelayer_) external onlyOwner {
        if (vaultRelayer_ == address(0)) revert ZeroAddress();
        vaultRelayer = vaultRelayer_;
        emit WiringSet("vaultRelayer", vaultRelayer_);
    }

    /// @notice Wire/re-point the coverage gate (`DurationFreezeModule`) that blocks `postBid` while `!covered()`.
    ///         `onlyOwner` (Timelock). Zero is permitted (turns the gate OFF — the M1 pre-wiring state).
    function setCoverageGate(address coverageGate_) external onlyOwner {
        coverageGate = coverageGate_; // address(0) is a valid "gate off" value
        emit WiringSet("coverageGate", coverageGate_);
    }

    // --------------------------------------------------------------------- the bid (§7.2)
    /// @notice Post the single resting CoW `BUY szipUSD` bid, priced at or below `navExit × (1 − d)`. Operator-only.
    function postBid(GPv2OrderInput calldata order) external onlyOperator {
        if (currentUid.length != 0) revert BidAlreadyLive();
        if (order.sellAmount == 0 || order.buyAmount == 0) revert ZeroAmount();
        if (order.buyAmount > MAX_BUY_AMOUNT) revert BuyAmountTooLarge();
        if (order.sellAmount > buybackCap) revert CapExceeded();
        // PATH-LOCK outflow gate (build/lp-path-lock.md): a buy-and-burn bid spends basket USDC to retire szipUSD — a
        // free-side outflow. Block it while sidecar+LP coverage is below the floor (a price-drift breach), so exits
        // cannot drain coverage. Gate OFF (coverageGate == 0) is the M1 pre-wiring state. Wired by the Timelock.
        address gate = coverageGate;
        if (gate != address(0) && !ICoverageGate(gate).covered()) revert Undercovered();
        if (order.validTo <= block.timestamp || order.validTo > block.timestamp + MAX_BID_TTL) revert BadValidTo();
        // NAV-freshness fence (the collapsed "fulfillment controller", 2026-06-09): a resting bid must not be able
        // to fill against a NAV mark that has since gone stale. `navExit` is priced now off `fresh()` legs, but the
        // order rests until `validTo`. The legs feeding `navExit` may already be up to `maxAge` old at post-time
        // (`fresh()` only requires age ≤ `maxAge`), so anchoring the ceiling to POST-time (`now + maxAge`) allowed a
        // worst-case fill-time mark age of `2·maxAge` (SEC-13 / kill-list L12). Anchor instead to the OLDEST required
        // leg's timestamp, so the mark a fill lands against is at most `maxAge` old. Pure addition (`anchor + maxAge`,
        // never subtraction): the oldest-leg-age==maxAge / unset-leg / maxAge==0 edges fail closed via this fence plus
        // the `:299` `validTo > now` check — no underflow. Binds before `BadValidTo` whenever `anchor + maxAge < now + MAX_BID_TTL`.
        uint256 anchor = INavOracle(navOracle).oldestRequiredLegTs();
        if (order.validTo > anchor + INavOracle(navOracle).maxAge()) revert ValidToBeyondNavFreshness();
        if (!INavOracle(navOracle).fresh()) revert StaleNav();
        if (dBps == 0 || dBps >= 10_000) revert BadDiscount();

        uint256 navExit18 = INavOracle(navOracle).navExit(); // USD-18dp per 1e18 share

        // Price bound (§7.2/§7.4), exact integer form (USD 18-dp basis), reconciling USDC-6dp ↔ szipUSD-18dp ↔
        // nav-18dp. Value paid (18-dp USD) = sellAmount * 1e12. Value of shares at the discounted ceiling (18-dp
        // USD) = buyAmount * navExit18 * (10_000 - dBps) / 10_000 / 1e18. Require paid ≤ ceiling; both /10_000 and
        // /1e18 are moved to the LHS as multipliers so the comparison is EXACT (no truncation on the bound — the
        // ceiling never rounds UP into an above-NAV fill).
        if (
            order.sellAmount * 1e12 * 10_000 * 1e18
                > order.buyAmount * navExit18 * (10_000 - uint256(dBps))
        ) revert BidAboveDiscount();

        bytes memory uid = _orderUid(order);

        // Two `exec`s in one tx → atomic: a revert of the 2nd (setPreSignature) rolls back the approve.
        exec(
            usdc, 0, abi.encodeWithSelector(IERC20Approve.approve.selector, vaultRelayer, order.sellAmount), Operation.Call
        );
        exec(
            settlement,
            0,
            abi.encodeWithSelector(IGPv2Settlement.setPreSignature.selector, uid, true),
            Operation.Call
        );

        currentUid = uid;
        currentSellAmount = order.sellAmount;

        emit BidPosted(uid, order.sellAmount, order.buyAmount, order.validTo, navExit18, dBps);
    }

    /// @notice Retract the resting bid: flip the presignature false + reset the VaultRelayer allowance to 0. Operator
    ///         OR owner (owner = emergency). Idempotent (no-op, no revert) when no live bid.
    function cancelBid() external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        bytes memory uid = currentUid;
        if (uid.length == 0) return; // idempotent no-op

        exec(
            settlement,
            0,
            abi.encodeWithSelector(IGPv2Settlement.setPreSignature.selector, uid, false),
            Operation.Call
        );
        exec(usdc, 0, abi.encodeWithSelector(IERC20Approve.approve.selector, vaultRelayer, uint256(0)), Operation.Call);

        delete currentUid;
        currentSellAmount = 0;

        emit BidCancelled(uid);
    }

    // --------------------------------------------------------------------- order hashing (Call-only, in-contract)
    /// @notice Build the canonical GPv2 order from the fixed constants + the 3 validated fields and return its 56-byte
    ///         uid. The module signs the SAME struct it validates (no field is both operator-supplied and unvalidated).
    /// @dev    `structHash = keccak256(abi.encode(TYPE_HASH, sellToken, buyToken, receiver, sellAmount, buyAmount,
    ///         uint256(validTo), appData, feeAmount, kind, partiallyFillable, sellTokenBalance, buyTokenBalance))`;
    ///         `digest = keccak256(0x1901 ++ domainSeparator ++ structHash)`;
    ///         `uid = digest(32) ++ owner(20 = engineSafe) ++ validTo(uint32, 4)` → 56 bytes.
    function _orderUid(GPv2OrderInput calldata order) public view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPE_HASH,
                usdc, // sellToken
                szipUSD, // buyToken
                engineSafe, // receiver
                order.sellAmount,
                order.buyAmount,
                uint256(order.validTo),
                APP_DATA,
                uint256(0), // feeAmount
                KIND_BUY,
                true, // partiallyFillable
                BALANCE_ERC20, // sellTokenBalance
                BALANCE_ERC20 // buyTokenBalance
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        return abi.encodePacked(digest, engineSafe, order.validTo);
    }

    // --------------------------------------------------------------------- views (CRE op surface / monitoring)
    /// @notice The live resting bid (empty uid + 0 when none).
    function currentBid() external view returns (bytes memory uid, uint256 sellAmount) {
        return (currentUid, currentSellAmount);
    }

    /// @notice The current 6-dp USDC ceiling per 1e18 share = `navExit × (10_000 − dBps)/10_000 / 1e12`. The
    ///         off-chain bid builder sizes against this; the on-chain check re-validates. (The view rounds DOWN, the
    ///         buyer-conservative direction — a `sellAmount = maxUsdc6PerShare` per 1e18 `buyAmount` passes the gate.)
    function quoteMaxPrice() external view returns (uint256 maxUsdc6PerShare) {
        uint256 navExit18 = INavOracle(navOracle).navExit();
        return navExit18 * (10_000 - uint256(dBps)) / 10_000 / 1e12;
    }
}
