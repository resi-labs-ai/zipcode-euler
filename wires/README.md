# wires/ — the protocol wiring map

One file per built component, each read **from the kept code under `contracts/` as the authoritative final
form** (tickets/reports/spec are intent only — where they disagree, the code wins). Each doc records: Role ·
Contracts involved · Wiring internal (ctor/setUp, immutables, setter-wired pointers, authority/gating) ·
Wiring cross-component (who points at whom) · Item-10 deploy facts · Gotchas.

This map is the substrate the **item-10 deploy/wiring script** is authored from: the deploy script connects
documented pins, it does not rediscover them. Authored 2026-06-09/10 (a full pass over the built contract set).

**Completeness:** `COVERAGE.md` is the file-level manifest — every `.sol` under `contracts/` (32 product
contracts + 5 scripts + 30 interface shims + 28 test/helper files) mapped to its doc. Nobody forgotten.

## Index
| Cluster | Component | Doc | Core contract(s) |
|---|---|---|---|
| Scaffold | Foundry substrate + address book | `WOOF-00.md` | `BaseAddresses`, `ForkConfig`, `src/interfaces/**` |
| Venue spine | Lien identity | `WOOF-01.md` | `LienCollateralToken`, `LienTokenFactory` |
| Venue spine | Oracle registry | `WOOF-02.md` | `ZipcodeOracleRegistry` |
| Venue spine | CRE gating hook | `WOOF-03.md` | `CREGatingHook` |
| Venue spine | Venue adapter cluster | `WOOF-04.md` | `EulerVenueAdapter`, `IZipcodeVenue`, `LineAccount` |
| Venue spine | Controller | `WOOF-05.md` | `ZipcodeController` |
| Venue spine | Deploy identity gate | `WOOF-10a.md` | `ZipcodeDeployAsserts` |
| Supply | Deposit zap | `WOOF-06.md` | `ZipDepositModule` |
| Supply | Baal two-Safe substrate | `8-B1.md` | `SummonSubstrate` (script) |
| Supply | NAV pricing primitive | `8-B4-SzipNavOracle.md` | `SzipNavOracle` |
| Supply | Deposit/exit seam | `ExitGate-szipUSD.md` | `ExitGate`, `SzipUSD` |
| Supply | Senior custody | `8-Bw-CreditWarehouse.md` | `WarehouseAdminModule`, `CreditWarehouseDeployer` |
| Supply | Senior par exit | `9-ZipRedemptionQueue.md` | `ZipRedemptionQueue` |
| Supply | CoW off-ramp | `OffRampModule.md` | `OffRampModule` |
| Engine | Buy-and-burn | `8-B14-SzipBuyBurnModule.md` | `SzipBuyBurnModule` |
| Engine | Reservoir borrow loop | `8-B5-ReservoirLoop.md` | `ReservoirLoopModule`, `SzipReservoirLpOracle`, `ReservoirBorrowGuard`, `ReservoirMarketDeployer` |
| Engine | LP strategy | `8-B6-LpStrategyModule.md` | `LpStrategyModule` |
| Engine | Harvest/vote | `8-B7-HarvestVoteModule.md` | `HarvestVoteModule` |
| Engine | oHYDX exercise | `8-B8-ExerciseModule.md` | `ExerciseModule` |
| Engine | Algebra sell/buy | `8-B9-SellModule.md` | `SellModule` |
| Engine | Single-sink recycle + divert | `8-B10-RecycleModule.md` | `RecycleModule` |
| Engine | Duration freeze | `DurationFreezeModule.md` | `DurationFreezeModule` |
| Loss | xALPHA bond custody | `8-Bx-LienXAlphaEscrow.md` | `LienXAlphaEscrow` |
| Loss | Loss orchestrator | `DefaultCoordinator.md` | `DefaultCoordinator` |
| Bridge | szALPHA CCT bridge | `8x-01-szALPHA-bridge.md` | `SzAlpha`, `SzAlphaMirror`, `SzAlphaTokenPool`, `DeploySzAlphaBridge` |
| Bridge | xALPHA rate oracle | `8x-02-SzAlphaRateOracle.md` | `SzAlphaRateOracle` + `cre/szalpha-rate` |

### Interface shims (`src/interfaces/`, cataloged per folder)
The minimal local interfaces for the deployed-on-Base protocols (interface+fork) + the internal Zipcode seams.
| Folder | Doc | Nature |
|---|---|---|
| `algebra/` | `interfaces-algebra.md` | external (Algebra Integral / Hydrex periphery) |
| `baal/` | `interfaces-baal.md` | external (Baal/Moloch-v3) |
| `bridge/` | `interfaces-bridge.md` | external (CCT registry, Subtensor precompiles) + internal (`IXAlphaRate`) |
| `cow/` | `interfaces-cow.md` | external (CoW GPv2Settlement) |
| `euler/` | `interfaces-euler.md` | external (EulerEarn) + internal (`IZipUSD`) |
| `hydrex/` | `interfaces-hydrex.md` | external (Voter/Gauge/oHYDX/veHYDX/RewardsDistributor) |
| `ichi/` | `interfaces-ichi.md` | external (ICHI vault/factory/guard) |
| `loss/` | `interfaces-loss.md` | internal (`ILienXAlphaEscrow`, `ISzipNavOracle`) |
| `safe/` | `interfaces-safe.md` | external (Gnosis Safe) |
| `supply/` | `interfaces-supply.md` | internal (`ISzipNavBasket`) |
| `zodiac/` | `interfaces-zodiac.md` | external (Roles v2, ModuleProxyFactory) |

## Cross-cutting wiring patterns (the load-bearing seams)
These recur across many components and are where the item-10 deploy script lives or dies.

1. **Build-phase Timelock-settable wiring (CODE-CONFIRMED, supersedes "immutable/set-once/renounce" prose).**
   Across the codebase the wiring slots that tickets/reports/spec describe as *immutable / set-once
   `AlreadyWired` / renounce-frozen* are, in the **kept code**, plain `onlyOwner` Timelock-settable storage
   with `setX` re-point setters (registry, controller, warehouse adapter, redemption queue, **LienXAlphaEscrow**,
   **DefaultCoordinator**, NAV oracle, every engine module). The deploy posture is therefore
   **`transferOwnership(timelock)` on every contract, NOT `renounceOwnership()`** (memory
   [[oracle-replaceable-timelock-wiring]]; PROGRESS 161-172). Immutability/re-freeze is **deferred to a
   pre-prod lock-down** (item-10-adjacent). Exceptions: `LienCollateralToken.controller` (immutable per-line),
   EVK hooks use a manual `owner` (`CREGatingHook`). No contract has a sweep/rescue/pause path.

2. **The `ReceiverTemplate` identity-seal family.** Every CRE-driven contract `is ReceiverTemplate`:
   `ZipcodeController`, `ZipcodeOracleRegistry`, `WarehouseAdminModule`, `DefaultCoordinator`,
   `SzipNavOracle`, `SzAlphaRateOracle`. Each needs, in order, at deploy: Forwarder wired (ctor) →
   `setExpectedAuthor`/`setExpectedWorkflowId` (S10b) → the `ZipcodeDeployAsserts.requireIdentityWired`-style
   pre-gate (`getExpectedWorkflowId() != 0`) → `transferOwnership(timelock)` (S11). The identity check is
   **conditional on the expected values being non-zero** — sealing before they are set permanently bypasses it.
   This must be a **tested negative** per contract, not an unexercised assert line (`WOOF-10a.md`).

3. **The engineSafe denominator-exclusion chain.** One address must be identical across:
   `SzipBuyBurnModule.engineSafe == ExitGate.engineSafe == SzipNavOracle.engineSafe == order.receiver`. The
   module-side equalities are tested; the **oracle-side `SzipNavOracle.setEngineSafe`** is an OPEN item-10
   step (so the transient pre-burn szipUSD is excluded from navPerShare). (`8-B14`, `8-B4`, PROGRESS 325.)

4. **The shared-LP-address invariant.** One ICHI vault share address must be identical across:
   `LpStrategyModule.ichiVault` (8-B6) == the 8-B5 reservoir escrow collateral `asset()` ==
   `SzipReservoirLpOracle` LP_MARK key == `SzipNavOracle` basket-LP leg. If any diverge, the unstake→post-
   collateral harvest loop silently fractures. Deploy MUST assert equality. (`8-B5`, `8-B6`, PROGRESS 338.)

5. **The one-bank invariant (loss/supply join).** `RecycleModule.warehouse == ZipDepositModule`'s warehouse
   AND `RecycleModule.eePool == ZipDepositModule.eePool()` AND `RecycleModule.navOracle ==` the SzipNavOracle
   the `DefaultCoordinator` writes provision to — else diverted USDC supplies the wrong pool / reads the wrong
   hole. Deploy-time assert, revert on mismatch. (`8-B10`, `WOOF-06`, PROGRESS 357/375.)

6. **The repaySink chain (senior funding).** `WarehouseAdminModule.repaySink == ZipRedemptionQueue` (Roles
   scope `EqualTo`); the queue is non-sweepable and never calls EulerEarn (settles own balance). The REPAY
   re-scope authority must be the timelock/multisig, NOT the CRE settle operator. (`8-Bw`, `9`, PROGRESS 369.)

7. **The engine module deploy template.** Every engine Zodiac module (`8-B5..B10`, `8-B14`,
   `DurationFreezeModule`, `OffRampModule`) is: CREATE2-cloned via `ModuleProxyFactory.deployModule` + `setUp`
   atomically in one tx (front-run-safe) + mastercopy init-locked; `avatar = target = engineSafe`;
   `owner = Timelock != operator (CRE)`; all calls `Operation.Call` value-0 via a bubbling `_exec`. The
   `DurationFreezeModule` is enabled on **both** Safes (sidecar only after `isOwner(team)`).

8. **The xALPHA rate/balance split (production).** `SzipNavOracle` holds `xAlpha` immutable as the **balance**
   token but reads the **rate** from a distinct Timelock-settable `xAlphaRateOracle` (`setXAlphaRateOracle`).
   Production wires the basket to the `SzAlphaMirror` (no `exchangeRate`) and the rate to `SzAlphaRateOracle`.
   The 8x-01 "swap in the mirror with no surface change" discharge holds for the ERC20-balance consumers
   (8-B5/8-B6/8-Bx) but the NAV oracle needs the explicit rate seam. (`8-B4`, `8x-01`, `8x-02`, PROGRESS 329.)

## Deploy dependency order (sketch, for the item-10 script)
Roughly the `audit/2.md` Phase S order, extended for the full current contract set:
1. **Roots:** USDC EE pool (`EulerEarnFactory`), `TimelockController`, `ZipcodeOracleRegistry`, `LienTokenFactory`.
2. **Venue spine:** `CREGatingHook` (precompute `VENUE` for `borrowDriver`) → `EulerVenueAdapter` (10-arg) →
   `ZipcodeController` (5-arg) → `registry.setController` → EE_POOL `setIsAllocator`+`setCurator(VENUE)` (curator
   timelock 0) + `setFeeRecipient` (protocol-side).
3. **Bridge first (xALPHA leg is a dependency):** `8x-01` mirror + pool, `8x-02` `SzAlphaRateOracle`.
4. **Supply substrate:** `SummonSubstrate` (main + sidecar Safe) → `ESynth` zipUSD + `setCapacity(module)` →
   `ZipDepositModule` → `SzipNavOracle` → `ExitGate` + `SzipUSD` (Gate manager(2) grant; `setShareToken`) →
   `CreditWarehouse` Safe + `WarehouseAdminModule` (Roles) → `ZipRedemptionQueue` (`repaySink` wiring).
5. **Engine modules:** create the POL ICHI vault + resolve the gauge (whitelist-gated) → deploy `8-B5`
   reservoir market (governor → timelock; point EE supply queue at it) → clone `8-B5..B10`, `8-B14`,
   `DurationFreeze`, `OffRamp` (enable on the right Safe(s), wire operators, the shared-LP/one-bank/engineSafe
   asserts).
6. **Loss side:** `LienXAlphaEscrow` → `DefaultCoordinator` (`setEscrow` + `forceApprove`, oracle
   `setDefaultCoordinator`, fund launch xALPHA).
7. **Seal:** the four NAV-oracle wiring setters; all `ReceiverTemplate` identity-set (S10b) → the
   `requireIdentityWired` pre-gate → `transferOwnership(timelock)` everywhere (S11). Subgraph addresses +
   the deferred `audit/2`/`audit/3` engine/junior/loss L-row sweeps follow.

> **Open obligations** for item-10 remain tracked in `tickets/PROGRESS.md` → "Open cross-ticket obligations";
> each component doc's "Item-10 deploy facts" section names the rows it owes.
