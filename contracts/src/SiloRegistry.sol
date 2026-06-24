// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// =========================================================================================== topology getters
// Minimal local interfaces for the four topology getters the admission assert dereferences. Each is a verified
// public, address-typed getter on the as-built silo components (see the ticket's "Binds to"). `ISzipNavOracle` /
// `IEulerEarn` returns are cast to `address` for comparison, so these declare the getters as `address`-returning.

/// @notice `DurationFreezeModule.{eulerEarn(), warehouseSafe(), navOracle()}`
///         (`contracts/src/supply/szipUSD/DurationFreezeModule.sol:54,56,57`).
interface IFreeze {
    function eulerEarn() external view returns (address);
    function warehouseSafe() external view returns (address);
    function navOracle() external view returns (address);
}

/// @notice `LienXAlphaEscrow.coordinator()` (`contracts/src/loss/LienXAlphaEscrow.sol:60`).
interface IEscrow {
    function coordinator() external view returns (address);
}

/// @notice `DefaultCoordinator.navOracle()` (`contracts/src/loss/DefaultCoordinator.sol:90`,
///         `ISzipNavOracle public navOracle` — cast to `address`).
interface INavWriter {
    function navOracle() external view returns (address);
}

/// @notice The venue-neutral senior-surface getter every `IZipcodeVenue` adapter exposes (CTR-10b): the address
///         that satisfies `ISeniorPool` for this silo. `EulerVenueAdapter.seniorPool()` returns
///         `address(eulerEarn)` (the EE pool IS the senior surface); a non-Euler adapter returns its own pool or a
///         thin `ISeniorPool` wrapper. This is the ONE getter the admission gate dereferences to stay
///         venue-agnostic — `IZipcodeVenue` itself carries no senior-surface method (§4.7).
interface ISeniorVenue {
    function seniorPool() external view returns (address);
}

/// @title SiloRegistry
/// @notice CTR-02: the multi-pool / federation silo catalog + admission gate + concurrent-line slot accounting that
///         lets the protocol run N pools under one mutualized senior zipUSD. A plain OZ `Ownable` (v5) — owner is the
///         Timelock (the `EulerVenueAdapter`/`DefaultCoordinator` idiom; NOT a Zodiac module, NOT an EVK hook). It is
///         a pure catalog: it touches NO silo-internal contract; silo logic is unchanged.
///
/// @dev Each silo is the set `{venue adapter + warehouseSafe Safe + EulerEarn pool + junior tranche}` plus its loss-side
///      and freeze components. Admission (`addSilo`, `onlyOwner`/Timelock) is the federation's underwriting gate:
///      a curator gets senior backing only by registering a SELF-CONSISTENT silo — one whose freeze/escrow/coordinator
///      all point only at its OWN pool/safe/oracle (the §2 topology assert). `lineCount`/`active` are registry-managed
///      (NEVER caller-supplied — a caller-seeded count is a capacity-desync footgun): admission takes a `SiloConfig`
///      (addresses only) and the registry seeds `lineCount = 0` / `active = true`.
///
/// @dev SLOT ACCOUNTING (Key req 1) — `lineCount` is a CONCURRENT-line counter. The controller (CTR-03) calls
///      `incrementLineCount` as the LAST write after a successful `openLine` so a reverted origination leaks no
///      phantom count, and `decrementLineCount` on close. The cap is `MAX_LINES_PER_SILO = 28` (see constant). NOTE
///      (cross-ticket capacity dependency, PROGRESS finding 1 / CTR-04): the as-built `EulerVenueAdapter.closeLine`
///      frees only the SUPPLY queue, NOT the binding WITHDRAW-queue slot, so a pool bricks at ~28 *lifetime* opens
///      inside `acceptCap` BEFORE this registry's `SiloFull` would ever trip. `decrementLineCount` is correct
///      *registry* accounting and builds standalone, but the concurrent-capacity model is only fully sound once CTR-03
///      wires increment/decrement AND CTR-04 makes `closeLine` reclaim the withdraw-queue slot.
///
/// @dev VENUE-AGNOSTIC ADMISSION (CTR-10b — the federation plug-in seam). The admission gate dereferences NO
///      Euler-specific surface: the adapter clause asserts the venue-neutral `ISeniorVenue.seniorPool()` and the
///      freeze clauses assert the venue-neutral `ISeniorPool` slot (`IFreeze.eulerEarn()`, name retained), so a
///      NON-Euler venue plugs in with NO change to this registry. The recipe to add a venue once its adapter is
///      built (none beyond Euler exists today — CTR-10b reference adapter is deferred, P5):
///        1. Write `FooVenueAdapter is IZipcodeVenue` exposing `seniorPool()` → its `ISeniorPool` surface.
///        2. If the venue is not natively 4626, deploy a thin `ISeniorPool` wrapper over its senior shares.
///        3. Deploy a `DurationFreezeModule` whose `eulerEarn` slot = that senior surface (its `setUp`).
///        4. `addSilo(SiloConfig{adapter: fooAdapter, eePool: <the ISeniorPool surface>, freeze: fooFreeze, ...})`.
///      The gate then proves `adapter.seniorPool() == eePool` and `freeze.eulerEarn() == eePool` — the silo reads
///      ONE self-consistent senior surface. `IZipcodeVenue` stays senior-surface-free (the getter lives on the
///      concrete adapter, never the seam). The donation-immunity of a real non-Euler surface is the venue's own
///      property and must be proven against THAT venue (it cannot be proven by a mock).
contract SiloRegistry is Ownable {
    // --------------------------------------------------------------------- constants
    /// @notice The per-silo concurrent-line cap. Derived: `MAX_QUEUE_LENGTH (30) − resting-USDC market (1) −
    ///         farm utility vault (1) = 28`. (CTR-07's split-slot decision keeps it at 28.)
    uint16 public constant MAX_LINES_PER_SILO = 28;

    // --------------------------------------------------------------------- records
    /// @notice The stored silo record. `lineCount`/`active` are registry-managed (never caller-supplied).
    struct Silo {
        address adapter; // the IZipcodeVenue adapter (the seam venueOf returns); for config one, EulerVenueAdapter
        address warehouseSafe; // CreditWarehouse Safe (senior-share + USDC custodian)
        address eePool; // the silo's ISeniorPool senior-read surface (CTR-10b): the EE pool for an Euler silo, a
            // venue pool / thin wrapper for a non-Euler silo. The aggregator + freeze read it via ISeniorPool.
        address juniorBasket; // junior tranche / NAV basket (routing+aggregation only; NOT topology-asserted)
        address escrow; // LienXAlphaEscrow (first-loss bond custody)
        address defaultCoordinator; // DefaultCoordinator (loss orchestrator; escrow.coordinator + navOracle writer)
        address navOracle; // SzipNavOracle
        address freeze; // DurationFreezeModule (per-silo coverage floor)
        address curator; // the silo's curator (routing/labeling only; NOT topology-asserted)
        uint16 lineCount; // registry-managed concurrent-line counter (starts 0)
        bool active; // registry-managed (starts true; flipped by setActive/retireSilo)
    }

    /// @notice The admission input — an all-address view; the caller cannot seed `lineCount`/`active`.
    struct SiloConfig {
        address adapter;
        address warehouseSafe;
        address eePool;
        address juniorBasket;
        address escrow;
        address defaultCoordinator;
        address navOracle;
        address freeze;
        address curator;
    }

    // --------------------------------------------------------------------- storage
    /// @notice The silo catalog, keyed by the caller-chosen `siloId`.
    mapping(bytes32 siloId => Silo) public silos;
    /// @notice Enumeration of every admitted `siloId` (retired silos stay in the book — never deleted).
    bytes32[] public siloIds;
    /// @notice The active fill target for new originations. `bytes32(0)` is the reserved "no current silo" sentinel.
    bytes32 public currentSilo;

    // --------------------------------------------------------------------- wiring (build phase, §17)
    /// @notice The sole authority that may call `incrementLineCount` / `decrementLineCount` (the `ZipcodeController`,
    ///         wired by CTR-03; re-pointable via `setController`).
    address public controller;

    // --------------------------------------------------------------------- errors
    error ZeroSiloId();
    error DuplicateSilo(bytes32 siloId);
    error ZeroAddress();
    error SiloMiswired();
    error UnknownSilo(bytes32 siloId);
    error SiloInactive(bytes32 siloId);
    error SiloFull(bytes32 siloId);
    error NoLinesToDecrement(bytes32 siloId);
    error NotController();

    // --------------------------------------------------------------------- events
    /// @notice Emitted when an owner (Timelock) re-points a wiring slot (build phase, §17).
    event WiringSet(bytes32 indexed slot, address value);
    /// @notice Emitted when a self-consistent silo is admitted.
    event SiloAdded(bytes32 indexed siloId);
    /// @notice Emitted when a silo is retired (active set false; lines close normally).
    event SiloRetired(bytes32 indexed siloId);
    /// @notice Emitted when `active` is flipped.
    event SiloActiveSet(bytes32 indexed siloId, bool active);
    /// @notice Emitted when the active fill target rolls over.
    event CurrentSiloSet(bytes32 indexed siloId);

    // --------------------------------------------------------------------- modifiers
    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /// @notice Seeds `controller` (may be re-pointed once CTR-03's controller is deployed) and the Timelock owner.
    constructor(address controller_) Ownable(msg.sender) {
        controller = controller_;
    }

    // --------------------------------------------------------------------- admission

    /// @notice Admit a self-consistent silo. onlyOwner (Timelock — the federation's underwriting gate).
    /// @dev Reverts: `ZeroSiloId` (zero is the reserved `currentSilo` sentinel), `DuplicateSilo`, `ZeroAddress` on
    ///      ANY zero address in `cfg`, or `SiloMiswired` on a failed topology assert (Key req 2). On success writes a
    ///      `Silo` with `cfg`'s addresses + `lineCount = 0` + `active = true`, appends to `siloIds`, and — if no
    ///      current silo is set — adopts this one as `currentSilo`.
    /// @dev Uniqueness is per-`siloId`: `DuplicateSilo` keys on `silos[siloId].adapter`, NOT on the component set, so
    ///      the same physical pool/components MAY be admitted under two distinct `siloId`s (each carrying its own
    ///      registry-managed `lineCount`). The `MAX_LINES_PER_SILO` cap is therefore per-`siloId`, not per-physical-pool.
    ///      Mapping one physical pool to exactly one `siloId` is a controller-wiring responsibility (the controller
    ///      routes each origination's `incrementLineCount` by the CRE-supplied `siloId`); per-physical-pool uniqueness
    ///      is an intentional non-goal (a curator re-pointing a venue is a separate `addSilo`).
    function addSilo(bytes32 siloId, SiloConfig calldata cfg) external onlyOwner {
        if (siloId == bytes32(0)) revert ZeroSiloId();
        if (silos[siloId].adapter != address(0)) revert DuplicateSilo(siloId);

        // any zero ADDRESS in cfg
        if (
            cfg.adapter == address(0) || cfg.warehouseSafe == address(0) || cfg.eePool == address(0)
                || cfg.juniorBasket == address(0) || cfg.escrow == address(0) || cfg.defaultCoordinator == address(0)
                || cfg.navOracle == address(0) || cfg.freeze == address(0) || cfg.curator == address(0)
        ) revert ZeroAddress();

        // topology assert (Key req 2): the exact 6-clause web. All clauses must hold; the silo must point only at
        // its OWN components (curator/juniorBasket carried for routing only — NOT asserted).
        if (
            IFreeze(cfg.freeze).eulerEarn() != cfg.eePool || IFreeze(cfg.freeze).warehouseSafe() != cfg.warehouseSafe
                || IFreeze(cfg.freeze).navOracle() != cfg.navOracle
                || IEscrow(cfg.escrow).coordinator() != cfg.defaultCoordinator
                || INavWriter(cfg.defaultCoordinator).navOracle() != cfg.navOracle
                || ISeniorVenue(cfg.adapter).seniorPool() != cfg.eePool
        ) revert SiloMiswired();

        silos[siloId] = Silo({
            adapter: cfg.adapter,
            warehouseSafe: cfg.warehouseSafe,
            eePool: cfg.eePool,
            juniorBasket: cfg.juniorBasket,
            escrow: cfg.escrow,
            defaultCoordinator: cfg.defaultCoordinator,
            navOracle: cfg.navOracle,
            freeze: cfg.freeze,
            curator: cfg.curator,
            lineCount: 0,
            active: true
        });
        siloIds.push(siloId);
        if (currentSilo == bytes32(0)) {
            currentSilo = siloId;
            emit CurrentSiloSet(siloId);
        }
        emit SiloAdded(siloId);
    }

    /// @notice Retire a silo: stops new routing; existing lines close normally. onlyOwner. NEVER deletes the record
    ///         (the book must stay readable through close). If it was `currentSilo`, clears the sentinel — forcing an
    ///         explicit `setCurrentSilo` to a live silo before the next origination.
    function retireSilo(bytes32 siloId) external onlyOwner {
        if (silos[siloId].adapter == address(0)) revert UnknownSilo(siloId);
        silos[siloId].active = false;
        if (siloId == currentSilo) {
            currentSilo = bytes32(0);
            emit CurrentSiloSet(bytes32(0));
        }
        emit SiloRetired(siloId);
    }

    /// @notice Flip a silo's `active` flag. onlyOwner.
    /// @dev Unlike `retireSilo`, `setActive(siloId, false)` does NOT clear `currentSilo` if `siloId` was the current
    ///      target — it can leave `currentSilo` pointing at a now-inactive silo. This is intentional and benign:
    ///      `currentSilo` has NO on-chain consumer (it is an advisory off-chain rollover hint), and origination routes
    ///      off the CRE-supplied `siloId` via `venueOf` (which ignores `active`), never off `currentSilo`. Use
    ///      `retireSilo` (or follow with an explicit `setCurrentSilo`) when the sentinel must be cleared.
    function setActive(bytes32 siloId, bool active_) external onlyOwner {
        if (silos[siloId].adapter == address(0)) revert UnknownSilo(siloId);
        silos[siloId].active = active_;
        emit SiloActiveSet(siloId, active_);
    }

    /// @notice The rollover lever (called when the active silo hits the cap). onlyOwner. Reverts if the target is
    ///         unknown or `!active` (the registry never auto-rollovers — explicit + governed).
    function setCurrentSilo(bytes32 siloId) external onlyOwner {
        if (silos[siloId].adapter == address(0)) revert UnknownSilo(siloId);
        if (!silos[siloId].active) revert SiloInactive(siloId);
        currentSilo = siloId;
        emit CurrentSiloSet(siloId);
    }

    // --------------------------------------------------------------------- slot accounting (onlyController)

    /// @notice Bump a silo's concurrent-line count. onlyController. Reverts `SiloFull` at `MAX_LINES_PER_SILO`.
    /// @dev Fail-closed: the controller calls this as the LAST write after a successful `openLine` (CTR-03) so a
    ///      reverted origination leaks no phantom count.
    function incrementLineCount(bytes32 siloId) external onlyController {
        if (silos[siloId].adapter == address(0)) revert UnknownSilo(siloId);
        if (silos[siloId].lineCount >= MAX_LINES_PER_SILO) revert SiloFull(siloId);
        silos[siloId].lineCount += 1;
    }

    /// @notice Decrement a silo's concurrent-line count on close. onlyController. Reverts `NoLinesToDecrement` on an
    ///         already-zero count (guards a double-decrement leak).
    function decrementLineCount(bytes32 siloId) external onlyController {
        if (silos[siloId].adapter == address(0)) revert UnknownSilo(siloId);
        if (silos[siloId].lineCount == 0) revert NoLinesToDecrement(siloId);
        silos[siloId].lineCount -= 1;
    }

    // --------------------------------------------------------------------- views

    /// @notice The IZipcodeVenue seam the controller routes `openLine` through (returns `silos[siloId].adapter`).
    function venueOf(bytes32 siloId) external view returns (address) {
        return silos[siloId].adapter;
    }

    /// @notice The canonical struct read (a public mapping of a struct returns a tuple, not the struct). CTR-05 reads
    ///         `{eePool, warehouseSafe}` via this over `allSiloIds()`.
    function getSilo(bytes32 siloId) external view returns (Silo memory) {
        return silos[siloId];
    }

    /// @notice Every admitted `siloId` (including retired silos — their lines stay observable through close).
    function allSiloIds() external view returns (bytes32[] memory) {
        return siloIds;
    }

    /// @notice The number of admitted silos.
    function siloCount() external view returns (uint256) {
        return siloIds.length;
    }

    // --------------------------------------------------------------------- Timelock-settable wiring (build phase, §17)

    /// @notice Re-point `controller` (build phase, §17). onlyOwner (Timelock).
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit WiringSet("controller", controller_);
    }
}
