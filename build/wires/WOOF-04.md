# WOOF-04 — EulerVenueAdapter + IZipcodeVenue + LineAccount (wiring map)

> Source of truth = the kept code under `contracts/src/venue/`. Ticket
> `tickets/woof/WOOF-04-venue-adapter.md` + report `reports/WOOF-04-report.md` are intent only — the .sol wins.
> Every claim below was read off `EulerVenueAdapter.sol` / `IZipcodeVenue.sol` / `LineAccount.sol`.

## Role
The **venue-agnostic seam** plus its one built configuration (Euler). The controller (§4.4) drives every
on-chain venue effect through `IZipcodeVenue` — only `bytes32`/`address`/`uint*`/opaque `lineRef` cross that
boundary, **no Euler types** — so the administrative core (CRE/oracle/registry) can re-point to Aave/Morpho
behind the adapter (§4.7).

`EulerVenueAdapter` (`is IZipcodeVenue, Ownable`) is the **per-line isolated-market FACTORY**. For each credit
line it mints + aligns, in one atomic `openLine`, a complete isolated cluster: a fresh per-line borrower
account (`LineAccount` + its EVC operator grant), an isolated escrow collateral vault (holds the lien), an
isolated USDC borrow vault (the lending vault), and a dedicated **frozen** per-line `EulerRouter` that prices
the collateral off the shared `ZipcodeOracleRegistry` keyed on the lien token. The adapter is modeled inline
on the verified `EdgeFactory.deploy()` (NOT imported — evk-periphery is un-remapped).

`LineAccount` is the **fresh per-line borrower-of-record**: a constructor-only EVC owner contract,
CREATE2-deployed (salt = `lienId`) by `openLine`. Its deterministic address establishes a fresh EVC
owner-prefix; in its constructor it registers that prefix and grants the **adapter** the EVC operator bit over
its own code-free borrow account (`address(this) ^ 1`). After construction it is inert — the cluster is
abandoned at close (the "graveyard," §4.4/§17). No state, no admin, no teardown. This replaces the old EVC
sub-account model (255 cap) with unbounded disposable per-line accounts.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `IZipcodeVenue` | The venue-neutral interface (§4.7): 7 methods (`openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/`closeLine`/`liquidate`) + 5 events (`LineOpened`/`LineLimitsSet`/`LineFunded`/`LineDrawn`/`LineClosed`). NO Euler types in any signature. |
| `EulerVenueAdapter` (`is IZipcodeVenue, Ownable`) | The Euler config. 10-arg ctor seeds the wiring (all mutable, owner-re-pointable build-phase); `onlyController` on every mutating method; per-line `Line` records keyed by `lineRef` (= borrow vault). Holds the EE allocator+curator roles + each line's market-governor role + the EVC operator bit each `LineAccount` grants it. |
| `LineAccount` | Constructor-only per-line EVC owner. `constructor(address evc_, address operator_)` derives `borrowAccount = address(uint160(address(this)) ^ 1)` and calls `IEVC(evc_).setAccountOperator(borrowAccount, operator_, true)`. The adapter passes `operator_ = address(this)` (itself, the `EVC.call`/`EVC.batch` msg.sender on the borrow path). |

## Wiring — internal

### Constructor
```solidity
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
) Ownable(msg.sender)
```
Note: the kept code is a **10-arg** ctor — the task's `(ZIP_CONTROLLER, EVC, EE_POOL, EVK_FACTORY,
ZIP_ORACLE_REG, GATING_HOOK, IRM, USDC, EREBOR)` 9-tuple plus the trailing **`baseUsdcMarket_`** (the no-borrow
USDC market at the EE supply-queue head that `fund` withdraws from). `Ownable(msg.sender)` sets the deployer as
owner; item-10 hands ownership to the Timelock. Every wiring slot is **plain MUTABLE storage** (not immutable),
re-pointable by the owner via the `setX` setters (build-phase §17; emit `WiringSet(slot, value)`, each guarded
by a `ZeroAddress()` check): `setController`, `setEvc`, `setEulerEarn`, `setEVaultFactory`,
`setOracleRegistry`, `setGatingHook`, `setIrm`, `setUsdc`, `setErebor`, `setBaseUsdcMarket`. No numeric
constant is mutable (`OP_BORROW = 1<<6`, `OP_LIQUIDATE = 1<<11`).

### openLine — what it mints + wires atomically
`openLine(bytes32 lienId, address lienToken, uint256 collateralAmount) onlyController returns (address lineRef, address oracleKey)`

Guard first: `if (collateralAmount != 1e18) revert InvalidCollateralAmount()` — the lien is the 1/1 primitive
(WOOF-01 fixed `1e18` supply); a partial would open a line that can never cleanly close (reclaim underflows),
and a bare `!= 0` is too loose (EVK `deposit(0,..)` does not revert). Steps:

0. **Borrower account + operator grant.** `LineAccount la = new LineAccount{salt: lienId}(address(evc), address(this));` then `borrowAccount = address(uint160(address(la)) ^ 1)`. The `LineAccount` ctor grants **the adapter** the operator bit over `borrowAccount`.
1. **Escrow collateral vault** (bare holding box). `eVaultFactory.createProxy(address(0), false, abi.encodePacked(lienToken, address(0), address(0)))` → `asset() == lienToken (= LIEN_i)`, no oracle, no unit-of-account. Then `setHookConfig(address(0), 0)` + `setGovernorAdmin(address(0))` (no governance).
2. **Per-line router.** `EulerRouter router = new EulerRouter(address(evc), address(this));` (adapter is governor at birth) → `router.govSetResolvedVault(collat, true)` (unwrap escrow shares → lienToken 1:1) → `router.govSetConfig(lienToken, usdc, oracleRegistry)` (price `(lienToken, USDC)` via the registry).
3. **Isolated USDC borrow vault** (the line). `eVaultFactory.createProxy(address(0), false, abi.encodePacked(usdc, address(router), usdc))` → asset=USDC, oracle=this line's router, unit-of-account=USDC (so USDC prices 1:1, no feed). Then `setInterestRateModel(irm)` + `setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE)` — **never** hooks `OP_REPAY` (repay stays ungated/permissionless).
4. **EE onboarding.** `eulerEarn.submitCap(IOZERC4626(evault), type(uint136).max)` → `acceptCap(evault)` → **rebuild** the supply queue appending `evault` (read `supplyQueueLength()`, copy, push, `setSupplyQueue(newQueue)`). `submitCap` is bounded to **ONLY** the freshly-minted local `evault` (security F3 — never a caller-supplied market).
5. **Custody the lien.** `IERC20(lienToken).transferFrom(controller, address(this), 1e18)` (controller approved the adapter in its origination batch) → `approve(collat, 1e18)` → `IEVault(collat).deposit(1e18, borrowAccount)` (deposit-to-receiver needs no consent; EVK credits any receiver).
6. **Freeze the router.** `router.transferGovernance(address(0))` — routing now immutable; nobody can re-point this line's price source. (Price *values* still flow — the registry cache is CRE-updated; only routing is frozen.)
7. **Birth-time wire-check (W3).** `_assertWired(router, collat, lienToken)`: `resolveOracle(1e18, collat, usdc)` must yield base==lienToken and oracle==oracleRegistry, else `WireMismatch()`.

Returns `lineRef = evault`, `oracleKey = lienToken`; records `Line{collateralVault, lienToken, router, lineAccount, borrowAccount, open:true}` keyed by `lineRef`; emits `LineOpened(lienId, lineRef, oracleKey, collat, router, borrowAccount)`.

### setLineLimits → setLTV
`setLineLimits(address lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap) onlyController` — requires the
line open, then `IEVault(lineRef).setLTV(L.collateralVault, borrowLTV, liqLTV, 0)` (1e4 scale, ramp 0) +
`IEVault(lineRef).setCaps(0, _toAmountCap(cap))`. `supplyCap = 0` is **deliberately unlimited** (raw 0 = no
limit, NOT "no supply"); the borrow cap is the risk bound. `_toAmountCap` encodes raw token units to EVK's
uint16 AmountCap `(mantissa<<6)|exponent`, rounding **UP**; `amount == 0` reverts `ZeroCap()` (raw 0 = unlimited).

### draw / fund / closeLine
- `draw(lineRef, amount, receiver) onlyController` — `if (receiver != erebor) revert BadReceiver()` (pinned to the immutable off-ramp, security F2). Builds a 3-item `evc.batch`: (1) `enableController(borrowAccount, lineRef)` self-call, (2) `enableCollateral(borrowAccount, collateralVault)` self-call, (3) `IBorrowing.borrow(amount, erebor)` on-behalf of `borrowAccount`. The adapter is the batch msg.sender + the granted operator → the §4.3 hook's `isAccountOperatorAuthorized` passes. Emits `LineDrawn`.
- `fund(lineRef, amount) onlyController` — two-item **absolute-target** `eulerEarn.reallocate`: read both bases from the EE's *supplied* position via `convertToAssets(balanceOf(eulerEarn))` (NOT `maxWithdraw`, which under-reads once cash is borrowed out), then `allocs[0] = {baseUsdcMarket, baseBalance - amount}` (withdraw) + `allocs[1] = {lineRef, lineBalance + amount}` (supply). Emits `LineFunded`.
- `observeDebt(lineRef) view` → `IEVault(lineRef).debtOf(borrowAccount)`; does **not** guard on `open` (readable post-close).
- `closeLine(lineRef) onlyController` — requires open + `observeDebt == 0` else `LineNotRepaid()`. The escrow shares are owned by `borrowAccount`, so it routes through `evc.call(collateralVault, borrowAccount, 0, redeem(shares, controller, borrowAccount))` (4-arg `IEVC.call`; adapter is the authorized operator). Returns the full `1e18` to the controller. **Then defunds the line's USDC back to base (SEC-07 / audit #4 / ref-B6 / L8):** if `lineBalance != 0` (a never-funded line skips), run the **inverse of `fund`'s reallocate** — `eulerEarn.reallocate([{lineRef, assets: 0}, {baseUsdcMarket, assets: baseBalance + lineBalance}])` where both bases are the supplied position `convertToAssets(balanceOf(eulerEarn))`. `assets: 0` redeems the EE's entire line position; base absorbs it; zero-sum. Without it the EE's `fund`-supplied USDC strands in the closed vault, depressing base until a later `fund`'s `baseBalance - amount` underflows (funding brick). **Then prunes the closed line from the EE supply queue (SEC-06 / audit H2):** rebuild into a `qlen-1` array skipping the entry whose address `== lineRef` (by **address match** — not last-position, since interleaved opens/closes move it) and `setSupplyQueue(newQueue)`. This is the symmetric un-do of `openLine` step 4's append, so the queue is bounded by **concurrent** open lines, not cumulative originations — without it the 30-slot `MAX_QUEUE_LENGTH` cap bricks origination after ~29 lifetime lines. Every surviving entry still has `cap != 0` (base + other open lines), so EE's per-entry cap check passes; no cap-revoke / withdraw-queue / timelock path is touched (the defund just emptied the removed market). Sets `open = false` (record kept readable). Emits `LineClosed`. **Defund MUST precede the prune** so the pruned market carries no balance; the defund stays reallocate-eligible because the line's cap is still non-zero (EE gates on `config[].enabled`, set by `acceptCap`, independent of supply-queue membership).
- `liquidate(address) view onlyController` → always `revert NotImplemented()` (§4.4e — no on-chain economic liquidation).

## Wiring — cross-component (who points at whom)
- **controller ↔ adapter.** The `ZipcodeController` (§4.4/WOOF-05) is the adapter's `controller` immutable-in-spirit (mutable slot, owner-settable). Every mutating method is `onlyController`. The controller never touches EVK/EVC/EulerEarn — it drives `IZipcodeVenue.{openLine,setLineLimits,fund,draw,closeLine}`. The controller pre-approves the adapter for the `1e18` lien before `openLine`'s step-5 `transferFrom`.
- **adapter ↔ EE_POOL (allocator + curator).** The adapter holds **both** EE roles. As **curator** it `submitCap`/`acceptCap`s the new line vault inside `openLine` (bounded to its own minted vault). As **allocator** it `setSupplyQueue` (openLine append **and closeLine prune**, SEC-06) and `reallocate` (fund). Granting these roles is item-10 (§9), not done in this contract.
- **adapter ↔ registry (the price seam).** Each line's router `govSetConfig(lienToken, usdc, oracleRegistry)` points at the shared `ZipcodeOracleRegistry`. The `oracleKey` `openLine` returns **== `lienToken` == `LIEN_i`** — the exact key the controller seeds the equity mark on (`registry.seedPrice(LIEN_i, mark)`). One deterministic chain: `lienId → LIEN_i → cache[LIEN_i] → ROUTER_i`.
- **adapter ↔ hook (borrowDriver).** Every borrow vault installs `gatingHook` at `OP_BORROW | OP_LIQUIDATE`. The §4.3 `CREGatingHook`'s `borrowDriver`/`controller` immutable must equal **the adapter** (the `EVC.call`/`EVC.batch` caller). This is a **deploy circularity** (the adapter ctor needs the hook address; the hook needs the adapter address) — resolved by address-prediction (CREATE2 / two-pass), an existing item-10 / WOOF-03 obligation; there is no settable hook-driver method.

## Item-10 deploy facts (§9 / audit S6, S8)
- **S6 — deploy `VENUE`.** `new EulerVenueAdapter(controller_, evc_, eulerEarn_, eVaultFactory_, oracleRegistry_, gatingHook_, irm_, usdc_, erebor_, baseUsdcMarket_)`. `gatingHook_` must be precomputed (CREATE2 / two-pass) so the deployed adapter == the address wired into the WOOF-03 hook's `borrowDriver`; assert the match. No `wireVenueOperator` step — the operator grant is per-line in `LineAccount`'s ctor, not a controller-level one-time grant.
- **S8 — grant the EE roles to the adapter.** `EE_POOL.setIsAllocator(VENUE, true)` and `EE_POOL.setCurator(VENUE)` (the adapter must hold **both**).
- **Curator timelock-0 (M1).** EE timelock 0 is only reachable via `initialize(initialTimelock = 0)` — `setTimelock` enforces a `1 days` floor (`EulerEarn.sol:748-751`), so the EE pool must be **deployed** with timelock 0 (an S8 deploy constraint, not settable later). Document **single-curator + timelock-0** as M1 production-hardening to revisit (multisig curator + non-zero timelock in production); F3 — adapter-as-curator is over-privilege, structurally bounded by `openLine` only ever capping its own minted vault.
- **baseUsdcMarket obligation.** Onboard a **no-borrow USDC EVault** at the EE supply-queue head as `fund`'s withdrawal source; pass it as the ctor's `baseUsdcMarket_`. EulerEarn has no native idle concept, so this market IS the idle reservoir `fund`'s absolute-target `reallocate` draws from.
- **reservoir-borrow-vault-as-warehouse-resting-vault.** Routed to item-10 by 8-Bw: the EE supply queue must allocate idle depositor USDC into the **reservoir borrow vault** (`ReservoirMarketDeployer.deploy`) so it IS the warehouse "USDC Resting Vault" (8-B5). This is an EulerEarn curator/allocator supply-queue config (an item-10 deploy step), NOT a `WarehouseAdminModule` op.
- **Ownership.** After wiring, `transferOwnership(timelock)` on the adapter (build-phase §17 — Timelock, not renounce). The 10 `setX` slots stay Timelock-re-pointable.

## Gotchas
- **No shared router.** Each line gets its **own** `ROUTER_i`, wired to the registry then **frozen** (`transferGovernance(address(0))`) inside `openLine`. There is no shared/timelocked router (§4.1/§4.7). Post-freeze `governor() == address(0)` and any `govSet*` reverts.
- **No subId / no blanket grant.** The borrower model is a fresh per-line `LineAccount` + per-line operator grant, not an EVC sub-account (the old 255-cap design). The `borrowAccount` is `address(lineAccount) ^ 1` — shares the 19-byte prefix, is **code-free** (so the EVC non-owner-must-be-code-free guard does not trip on the operator path). The grant is `address(this)` (the adapter), NOT the controller, because the adapter is the `EVC.call` msg.sender on the draw path.
- **EE_POOL pins solc 0.8.26 → mocked.** `EulerEarn` cannot `new` under the 0.8.24 profile; the adapter imports only `IEulerEarn`. Tests MOCK it (EVK/EVC/EulerRouter are live on the Base fork). `fund`'s two-item absolute allocation + the F3 onboarding bound are therefore mock-level; the live EE path is the item-10 deploy/wiring concern. **(SEC-06/SEC-07: `MockEulerEarn` was hardened beyond recording — `setSupplyQueue` reverts past `MAX_QUEUE_LENGTH=30`, and `reallocate` is now FAITHFUL: it executes the absolute-target reallocation against the real EVK vaults (`assets:0` → redeem all), so the SEC-07 strand + the `:290` underflow are reproduced in-test rather than only asserted on recorded targets.)**
- **Build-phase Timelock-settable wiring.** All 10 wiring addresses are mutable owner-settable slots (not immutable) — addresses change during the build; re-freeze to immutable is deferred to pre-prod lock-down (memory `oracle-replaceable-timelock-wiring`). Numeric constants (op bitmasks) are not mutable.
- **`liquidate` is `view`.** Implementing the non-view interface method as `view` is legal (narrower mutability); it always reverts `NotImplemented()`.
- **`getLine(lineRef)` accessor.** The public `lines` mapping of a struct returns a tuple; `getLine` returns the `Line memory` struct.
