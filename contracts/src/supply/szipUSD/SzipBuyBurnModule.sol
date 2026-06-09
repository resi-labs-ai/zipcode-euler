// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Module} from "@gnosis-guild/zodiac-core/core/Module.sol";
import {Operation} from "@gnosis-guild/zodiac-core/core/Operation.sol";
import {IGPv2Settlement} from "../../interfaces/cow/IGPv2Settlement.sol";

/// @dev The minimal NAV oracle surface this module reads (`SzipNavOracle`): the buyer-conservative §3 mark and the
///      issuance-freshness gate. Priced off `navExit()` (= `min(spot, twap)`, does NOT revert on staleness), gated on
///      `fresh()` (both required pushed legs within `maxAge`).
interface INavOracle {
    function navExit() external view returns (uint256);
    function fresh() external view returns (bool);
}

/// @dev The minimal ERC20 surface the module needs (the USDC `approve` the module builds calldata for).
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
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
///      storage written in `setUp` under `initializer`, NOT `immutable`. The mastercopy is init-locked at deploy.
contract SzipBuyBurnModule is Module {
    // --------------------------------------------------------------------- GPv2 canonical constants (verified `cast`)
    /// @notice The canonical GPv2 order EIP-712 type hash (verified `cast keccak` of the order string).
    bytes32 public constant TYPE_HASH = 0x1a59c8ffcce6fc2e6738119e0d2e050163ef0912ac7168f28acd39badd252b51;
    /// @notice `keccak256("buy")` — the order kind (BUY only; never an operator input).
    bytes32 public constant KIND_BUY = 0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc;
    /// @notice `keccak256("erc20")` — sell/buy token balance source (plain ERC20).
    bytes32 public constant BALANCE_ERC20 = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;
    /// @notice The single pinned appData. A non-zero/unconstrained appData could attach hooks/partner-fees the
    ///         validation never saw — pin it to a constant so the signed order carries no unvalidated surface.
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
    error StaleNav();
    error BidAboveDiscount();
    error BuyAmountTooLarge();

    // --------------------------------------------------------------------- events
    event BidPosted(
        bytes uid, uint256 sellAmount, uint256 buyAmount, uint32 validTo, uint256 navExit18, uint16 dBps
    );
    event BidCancelled(bytes uid);
    event DiscountSet(uint16 dBps);
    event BuybackCapSet(uint256 buybackCap);
    event WiringSet(bytes32 indexed slot, address value);

    // --------------------------------------------------------------------- setUp (initializer; NO immutable)
    /// @notice Initialize a clone (or the mastercopy at deploy, which is then init-locked). One-shot via the
    ///         zodiac-core `initializer`. Decodes `(owner, engineSafe, operator, navOracle, szipUSD, usdc,
    ///         settlement, dBps, buybackCap)`; reads the VaultRelayer + domain separator LIVE off the settlement.
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
            uint256 buybackCap_
        ) = abi.decode(initParams, (address, address, address, address, address, address, address, uint16, uint256));

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

    // --------------------------------------------------------------------- the bid (§7.2)
    /// @notice Post the single resting CoW `BUY szipUSD` bid, priced at or below `navExit × (1 − d)`. Operator-only.
    function postBid(GPv2OrderInput calldata order) external onlyOperator {
        if (currentUid.length != 0) revert BidAlreadyLive();
        if (order.sellAmount == 0 || order.buyAmount == 0) revert ZeroAmount();
        if (order.buyAmount > MAX_BUY_AMOUNT) revert BuyAmountTooLarge();
        if (order.sellAmount > buybackCap) revert CapExceeded();
        if (order.validTo <= block.timestamp || order.validTo > block.timestamp + MAX_BID_TTL) revert BadValidTo();
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
