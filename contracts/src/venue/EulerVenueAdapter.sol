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

/// @title EulerVenueAdapter
/// @notice Config one (§4.7 #10): a per-line isolated-market FACTORY. For each credit line it mints + aligns, in one
///         atomic call, a fresh per-line borrower account (`LineAccount` + its operator grant), an isolated escrow
///         collateral vault (holds the lien), an isolated USDC borrow vault (the lending vault), and a dedicated
///         frozen per-line `EulerRouter` that prices the collateral from the shared `ZipcodeOracleRegistry` keyed on
///         the lien token. Holds the per-line market governor role + each line's EVC operator bit (granted by the
///         line's own `LineAccount` at origination). Modeled inline on the verified `EdgeFactory.deploy()` (NOT
///         imported — evk-periphery is un-remapped).
contract EulerVenueAdapter is IZipcodeVenue {
    // ----- EVK op bitmask constants (§3 line 133) -----
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_LIQUIDATE = 1 << 11;

    // ----- immutables (constructor-wired; §9/item 10 grants roles separately) -----
    /// @notice The sole authority that may call the mutating venue methods.
    address public immutable controller;
    /// @notice The Ethereum Vault Connector.
    IEVC public immutable evc;
    /// @notice The EulerEarn pool the lines fund out of (allocator + curator role held by this adapter).
    IEulerEarn public immutable eulerEarn;
    /// @notice The EVK GenericFactory used to mint per-line vaults (caller becomes vault governor via initialize).
    GenericFactory public immutable eVaultFactory;
    /// @notice The shared `ZipcodeOracleRegistry` — each line's price source, keyed on the lien token.
    address public immutable oracleRegistry;
    /// @notice The `CREGatingHook` installed on every borrow vault at OP_BORROW | OP_LIQUIDATE.
    address public immutable gatingHook;
    /// @notice The interest rate model installed on every borrow vault.
    address public immutable irm;
    /// @notice The USDC token (borrow asset + unit-of-account, prices 1:1 with no feed).
    address public immutable usdc;
    /// @notice The ONLY legal draw receiver (the Erebor off-ramp, §4.4a/§9).
    address public immutable erebor;
    /// @notice The no-borrow base USDC market at the EE supply-queue head that `fund` withdraws from.
    address public immutable baseUsdcMarket;

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

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
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
        address baseUsdcMarket_
    ) {
        controller = controller_;
        evc = IEVC(evc_);
        eulerEarn = IEulerEarn(eulerEarn_);
        eVaultFactory = GenericFactory(eVaultFactory_);
        oracleRegistry = oracleRegistry_;
        gatingHook = gatingHook_;
        irm = irm_;
        usdc = usdc_;
        erebor = erebor_;
        baseUsdcMarket = baseUsdcMarket_;
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
        IEVault(evault).setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE); // never hook OP_REPAY

        // step 4: onboard EVAULT to the EE pool so `fund` can reallocate into it. Curator submitCap is bounded to
        // ONLY the freshly-minted local EVAULT (security F3 — never a caller-supplied market). M1 shortcut: the
        // supply queue is [baseUsdcMarket, EVAULT]; rebuild it preserving the existing queue.
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

    /// @inheritdoc IZipcodeVenue
    function fund(address lineRef, uint256 amount) external onlyController {
        if (!lines[lineRef].open) revert UnknownLine(lineRef);

        // reallocate is zero-sum + ABSOLUTE-target. Read both absolute bases from the EE's SUPPLIED position
        // (convertToAssets(balanceOf(EE))), NOT maxWithdraw (which is capped by idle cash and under-reads once a
        // prior line borrowed the cash out). Two-item allocation: withdraw `amount` from baseUsdcMarket, supply it
        // to lineRef to reach the new absolute target.
        uint256 baseBalance =
            IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(eulerEarn)));
        uint256 lineBalance = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(eulerEarn)));

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation({id: IOZERC4626(baseUsdcMarket), assets: baseBalance - amount});
        allocs[1] = MarketAllocation({id: IOZERC4626(lineRef), assets: lineBalance + amount});
        eulerEarn.reallocate(allocs);

        emit LineFunded(lineRef, amount);
    }

    /// @inheritdoc IZipcodeVenue
    function draw(address lineRef, uint256 amount, address receiver) external onlyController {
        Line storage L = lines[lineRef];
        if (!L.open) revert UnknownLine(lineRef);
        // The draw target is pinned to the immutable Erebor off-ramp (security F2) — do not trust the arg blindly.
        if (receiver != erebor) revert BadReceiver();

        address borrowAccount = L.borrowAccount;

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
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

        // The adapter is the batch msg.sender and the granted operator of borrowAccount (granted at openLine). EVK
        // appends borrowAccount as the hook caller -> the §4.3 hook's isAccountOperatorAuthorized passes.
        evc.batch(items);

        emit LineDrawn(lineRef, amount, receiver);
    }

    /// @inheritdoc IZipcodeVenue
    function observeDebt(address lineRef) public view returns (uint256) {
        // Readable AFTER close (L7/L8 read observeDebt == 0 post-close) — does NOT guard on `open`.
        return IEVault(lineRef).debtOf(lines[lineRef].borrowAccount);
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

        L.open = false; // keep the record readable so post-close observeDebt == 0 stays queryable
        emit LineClosed(lineRef);
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
        // Unreachable for any uint256 amount: 1023 * 10**63 / 100 >> type(uint256).max would be required to fail,
        // and 10**63 * 1023 / 100 ~ 1.02e64 covers all 256-bit token amounts. Revert defensively.
        revert ZeroCap();
    }
}
