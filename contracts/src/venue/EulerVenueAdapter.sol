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
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_LIQUIDATE = 1 << 11;

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
    address public baseUsdcMarket;

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

    // ----- events -----
    /// @notice Emitted when an owner (Timelock) re-points a wiring slot (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);

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
        baseUsdcMarket = baseUsdcMarket_;
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

    /// @notice Re-point `baseUsdcMarket` (build phase, §17). onlyOwner (Timelock).
    function setBaseUsdcMarket(address baseUsdcMarket_) external onlyOwner {
        if (baseUsdcMarket_ == address(0)) revert ZeroAddress();
        baseUsdcMarket = baseUsdcMarket_;
        emit WiringSet("baseUsdcMarket", baseUsdcMarket_);
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

        // SEC-08 (kill-list M6): runtime timelock precheck. `submitCap` sets `pendingCap.validAt = now + timelock`
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

        // Defund the line's USDC supply back to the base market (security L8). `fund` moved the EE pool's USDC
        // from base INTO this line's borrow vault (an absolute-target reallocate, :289-292); without returning it
        // on close that USDC strands in the now-closed vault, permanently depressing the base market's EE balance
        // until a later `fund`'s `baseBalance - amount` (:290) underflows and origination funding bricks. Reclaim
        // it with the INVERSE of fund's reallocate: redeem ALL of the EE's line shares (absolute target 0 -> EE
        // redeems the full position) and add that USDC to base's absolute target. Read the SUPPLIED position
        // (convertToAssets(balanceOf(EE))), matching fund's sizing (NOT maxWithdraw, which under-reads). The
        // line's cap is still non-zero (openLine left it type(uint136).max; never revoked) so the market stays
        // reallocate-eligible (EE gates on config[].enabled, set by acceptCap — independent of supply-queue
        // membership). Must run BEFORE the queue prune below so the pruned market is already emptied. No-op guard:
        // a line opened/closed without ever being funded has lineBalance == 0 -> skip (a zero-sum reallocate on an
        // empty market is pointless and a {x:0} withdrawal-only leg cannot balance).
        uint256 lineBalance = IEVault(lineRef).convertToAssets(IEVault(lineRef).balanceOf(address(eulerEarn)));
        if (lineBalance != 0) {
            uint256 baseBalance =
                IEVault(baseUsdcMarket).convertToAssets(IEVault(baseUsdcMarket).balanceOf(address(eulerEarn)));
            MarketAllocation[] memory defund = new MarketAllocation[](2);
            defund[0] = MarketAllocation({id: IOZERC4626(lineRef), assets: 0});
            defund[1] = MarketAllocation({id: IOZERC4626(baseUsdcMarket), assets: baseBalance + lineBalance});
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
