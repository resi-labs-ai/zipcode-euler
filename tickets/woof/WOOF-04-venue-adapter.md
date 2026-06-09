# WOOF-04 — `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount` (§4.7)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** All three contracts + the test are
> committed on disk: `contracts/src/venue/{IZipcodeVenue,LineAccount,EulerVenueAdapter}.sol` +
> `contracts/test/EulerVenueAdapter.t.sol`. `forge build` clean (solc 0.8.24) + **20/20 new tests pass against a
> live Base-mainnet fork** (76/76 total, no WOOF-00/01/02/03 regression — independently re-run). Live EVK/EVC/
> EulerRouter stand-up; `EulerEarn` MOCKED (pins solc 0.8.26). The two-line distinct-prefix BOTH-draw isolation,
> the operator-grant-authorizes-the-adapter assertion, foreign-account hook rejection, AmountCap round-trip,
> `!=1e18` guard, router freeze, and close-reclaim are all **live-fork-proven**. Every external interface
> signature + the AmountCap encode were re-verified against `reference/` before keeping (zero discrepancies).
> **Zero spec-guesses** — three minor test-harness guesses (a `ZeroIRM` test IRM; `submitCap` cap-seed =
> `type(uint136).max` mock-level; the hook↔adapter deploy-cycle resolved in-test via `computeCreateAddress`) are
> NOT spec/ticket defects: the IRM + cap-seed are §9 deploy/governance concerns, and the deploy-cycle is the
> already-tracked item-10/WOOF-03 precompute-or-two-pass obligation (now empirically confirmed as the forced
> path). `fund` + the F3 onboarding bound are mock-level (the live EE path is the audit S9/L4 integration). See
> `reports/WOOF-04-report.md`.

> **RE-AUTHORED 2026-06-05 (borrower-model rework, Step 2b) — supersedes the sub-account version.** The
> borrower account changed: OLD = each line borrowed on a **controller sub-account** (`sub_i = controller XOR
> subId`, a per-line `subId` counter, blanket `setOperator(prefix, venue, ~uint256(1))`, hook gated on
> `haveCommonOwner`) → a hard **255-line cap**. NEW = each line gets a **fresh per-line EVC account**: `openLine`
> CREATE2-deploys a minimal **`LineAccount`** owner contract (salt = `lienId`) that registers its own fresh
> prefix and grants the **borrow-driver** the EVC **operator** bit over a **code-free borrow account it owns**
> (sub-account 1 of its own prefix) via `EVC.setAccountOperator(borrowAccount, operator, true)` where `operator =
> the adapter` (the `EVC.call` `msg.sender` on the draw path — see "THE OPERATOR IDENTITY"). The adapter draws as
> the operator (`EVC.call/batch(borrowVault, borrowAccount, 0, borrowData)`); the §4.3 hook (WOOF-03,
> re-authored) gates on `isAccountOperatorAuthorized(borrowAccount, adapter)` (the hook's `controller` immutable
> wired = the adapter). Result: **unbounded disposable
> lines** — no `subId` counter, no controller sub-account, no blanket grant. **Everything else is unchanged**: the
> per-line isolated-market factory (escrow collateral vault + isolated USDC borrow vault + dedicated frozen
> `EulerRouter` wired `escrow→lien→registry`), the EulerEarn funding via `baseUsdcMarket` + two-item `reallocate`,
> the AmountCap encoding `(mantissa<<6)|exponent` (reject 0), the `draw` receiver pinned to Erebor, `liquidate` =
> `NotImplemented` stub, the `collateralAmount == 1e18` guard, EulerEarn mocked in the unit test.

**Deliverable**
Three files (one symbol per file, README §7):
- `contracts/src/venue/IZipcodeVenue.sol` — `interface IZipcodeVenue`. The venue-neutral seam the
  `ZipcodeController` (§4.4) drives every on-chain venue effect through: `openLine` / `setLineLimits` /
  `fund` / `draw` / `observeDebt` / `closeLine` / `liquidate`. No Euler types cross it.
- `contracts/src/venue/LineAccount.sol` — `contract LineAccount`. A **minimal per-line EVC owner contract**,
  CREATE2-deployed by the adapter inside `openLine` (salt = `lienId`). Its deterministic address establishes a
  **fresh owner-prefix**; in its **constructor** it registers that prefix and grants the **borrow-driver (the
  adapter)** the EVC operator bit over its own **code-free** borrow account (sub-account 1 of its prefix) by
  calling `EVC.setAccountOperator(borrowAccount, operator_, true)` where the adapter passes `operator_ =
  address(this)`. After construction it is inert (no further calls needed; the cluster is abandoned at close —
  the on-chain "graveyard," §4.4/§17). This is the borrower-of-record mechanism: nobody borrows on their own
  behalf — the adapter borrows as `borrowAccount`'s **EVC operator** (the `EVC.call` `msg.sender`).
- `contracts/src/venue/EulerVenueAdapter.sol` — `contract EulerVenueAdapter is IZipcodeVenue`. Configuration
  one: a **per-line isolated-market factory**. For each credit line it mints and aligns, in one atomic call:
  a **fresh per-line borrower account** (CREATE2 `LineAccount` + its operator grant), an **isolated collateral
  (escrow) vault** (holds the lien token), an **isolated USDC borrow vault** (the lending vault), and a
  **dedicated per-line `EulerRouter`** wired to price that collateral from the shared `ZipcodeOracleRegistry`
  under that lien's key — then freezes the router. Holds the Euler roles: EulerEarn allocator **+ curator**, the
  per-line market governor (via `createProxy` caller), and is each line's **EVC account operator** for that
  line's borrow account (granted by the line's own `LineAccount` at origination — **not** a blanket controller-prefix grant).

(Internal plumbing — build-only, no interface/frontend ticket. The venue boundary is consumed by the
controller, not by users.)

**Spec §**
`claude-zipcode.md` §4.7 (the venue boundary + the `IZipcodeVenue` method table). Cross:
- §4.4 (the controller calls `openLine → setLineLimits → fund → draw` inside its origination batch; the
  borrower-of-record is a **fresh per-line EVC account** owned by a `LineAccount`, with the controller wired as
  that account's EVC **operator**; §4.4c close; §4.4e liquidate is a defensive stub).
- §4.4 "Borrower-of-record mechanism" (`:377-403`): the per-line `LineAccount` CREATE2-deploy, the
  `setAccountOperator` owner-self grant on a code-free sub-account, the operator-`call` borrow, and the
  unbounded-disposable-cluster reasoning (the cap dissolves; the graveyard is accepted).
- §4.1 (the registry is each line's price source; **the price stays keyed on the lien token** — the per-line
  router resolves the escrow vault → lien token → registry, so §4.1's "the lien token is the oracle key"
  wording **stands unchanged**; WOOF-02 unchanged).
- §4.3 (`CREGatingHook` is installed on each borrow vault at `OP_BORROW | OP_LIQUIDATE`; it checks
  `EVC.isAccountOperatorAuthorized(caller, ZIP_CONTROLLER)` on the appended borrow account — so the borrow
  account is the line's **fresh per-line account** that authorized the controller as its operator, **not** a
  controller sub-account; WOOF-03 re-authored to this gate).
- §3 reused primitives (the verified Euler surface) and §9/§13 (deploy/wiring + governance; role grants are
  item 10).
- `audit/3-results.md` rows 4 (`reallocate`, allocator=VENUE), 5–8 (`setGovernorAdmin`/`setLTV`/`setHookConfig`/
  `setIRM`, governor=VENUE), 9 (`borrow`, operator-auth via hook on the line's fresh borrow account).
Locked §17: **venue-agnostic, Euler = config one** (§4.7 #10); **no on-chain economic liquidation**
(`liquidate` is a defensive stub, §4.4e); event-driven Proof valuation (this contract never reads a heartbeat);
**fresh per-line account + controller-as-operator → unbounded disposable lines** (the resolved 2026-06-05
borrower-of-record decision; the §17 supply-side yield/xALPHA decisions are LOCKED — do NOT touch them).

**Discharges inbound obligation (PROGRESS → row owed by item 5):** "register `LIEN_i` as collateral
(`setLTV` / market wiring)" (owed to WOOF-01). Realized here: `openLine` deposits the lien into a per-lien
**escrow collateral vault** and `setLineLimits` calls `IEVault(EVAULT_i).setLTV(COLLAT_i, …)` to register it.
Mark `DISCHARGED (by WOOF-04)` at Conclude.

---

## Design (per-line isolated-market factory + fresh per-line borrower account — verified against `reference/`)

Modeled on the **verified** `reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol::deploy()`
(`:56-128`) — the reference for deploying + wiring an isolated EVK market. Per line, `openLine` performs the
EdgeFactory sequence inline (do **not** import/inherit `EdgeFactory` — it is in `evk-periphery`, not in
WOOF-00's remap set; and it renounces vault governance + uses a router factory we don't want), **plus** the
new fresh-per-line-account deploy at the front:

0. **Fresh per-line borrower account `LineAccount` + its operator grant** — CREATE2-deploy
   `new LineAccount{salt: lienId}(evc, address(this))` (the adapter passes **itself** as the operator — it is the
   `EVC.call` `msg.sender` on the `draw` path; see "THE OPERATOR IDENTITY"). The `LineAccount` constructor (see
   "`LineAccount`" below) registers its own prefix and grants the adapter the EVC operator bit over
   `borrowAccount = address(lineAccount) ^ 1` (sub-account 1 of its own prefix — code-free). After step 0,
   `EVC.isAccountOperatorAuthorized(borrowAccount, address(this)) == true`, and `borrowAccount` is the line's
   borrower-of-record (the lien is its collateral; the per-line USDC vault is its single controller). **This
   replaces the old `sub_i = controller XOR subId` controller sub-account.**
1. **Escrow collateral vault `COLLAT`** — `GenericFactory.createProxy(address(0), false,
   abi.encodePacked(lienToken, address(0), address(0)))`; `setHookConfig(address(0), 0)`;
   `setGovernorAdmin(address(0))` (a bare holding box: no oracle, no governance — `EdgeFactory.sol:81-90`).
2. **Per-line router `ROUTER`** — `new EulerRouter(evc, address(this))` (ctor `EulerRouter.sol:47`; the adapter
   is its governor at birth). Wire it so the borrow vault prices `COLLAT` from the registry, **keyed on the
   lien token**: `ROUTER.govSetResolvedVault(COLLAT, true)` (`:69` — unwrap escrow shares → lienToken, 1:1)
   then `ROUTER.govSetConfig(lienToken, usdc, oracleRegistry)` (`:56` — price `(lienToken, USDC)` via the
   registry). Net: `ROUTER.resolveOracle(amt, COLLAT, USDC)` resolves `COLLAT → lienToken → oracleRegistry`
   (`EulerRouter.resolveOracle:123-143`, verified).
3. **USDC borrow vault `EVAULT`** — `GenericFactory.createProxy(address(0), false, abi.encodePacked(usdc,
   ROUTER, usdc))` (oracle = this line's `ROUTER`, **unit of account = USDC** so USDC prices 1:1 with no feed,
   `resolveOracle:129`); `setInterestRateModel(irm)`; `setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE)`
   (this adapter is governor via `createProxy`; **never hook `OP_REPAY`**).
4. **Onboard `EVAULT` to `EE_POOL`** so `fund` can `reallocate` into it: `EE_POOL.submitCap(EVAULT, capSeed)`
   (curator) → `EE_POOL.acceptCap(EVAULT)` → **rebuild** the supply queue to append `EVAULT` (allocator).
   (**`capSeed`** = the EE pool's per-market supply cap, the `uint136` cap field — pass a high seed like
   `type(uint136).max`; this is mock-level in the unit test and the real bound is the per-line `setCaps`/the
   §9 governance config, not this seed. **Build-confirmed 2026-06-06:** materialized as `type(uint136).max`.)
   NOTE `setSupplyQueue(IERC4626[])` **REPLACES** the whole queue: read the existing queue via
   **`supplyQueueLength()` (`EulerEarn.sol:477`) + `supplyQueue(i)`** and pass `[existing…, EVAULT]`; do NOT
   clobber prior lines. (M1 shortcut: queue = `[baseUsdcMarket, EVAULT]`.) (`reallocate` reverts
   `MarketNotEnabled`/`SupplyCapExceeded` otherwise — `EulerEarn.sol:390,428`.) **Two gates the build must
   honor:** (i) `submitCap`/`acceptCap` revert `UnauthorizedMarket` unless `EulerEarnFactory.isStrategyAllowed(EVAULT)`
   — confirm who whitelists the freshly-minted vault and when (a deploy/factory concern — `EulerEarn.sol:301,508`);
   (ii) **timelock 0 is only reachable via `initialize(initialTimelock = 0)`** — `setTimelock` enforces a
   `1 days` floor (`EulerEarn.sol:748-751`), so the EE pool must be **deployed** with timelock 0 (a §9/S8
   deploy constraint, not settable later). **Security F3 — curator is over-privilege:** the adapter holding EE
   **curator** lets a compromised controller onboard an arbitrary ERC4626 + `reallocate` the whole pool into
   it. Bound it: `openLine` must `submitCap` **ONLY the `EVAULT` it just created in step 3** (a local address,
   never a caller-supplied market) — make that structural. Carry adapter-as-curator + EE-timelock-0 as an
   explicit **production-hardening** item (a multisig curator + non-zero timelock in production), NOT an
   M1-silent grant.
5. **Custody the lien as collateral** for the line's `borrowAccount`: pull `collateralAmount` (= 1e18) of
   `lienToken` from the controller, `approve(COLLAT, amount)`, `IEVault(COLLAT).deposit(amount, borrowAccount)`
   so the **borrowAccount** holds the escrow shares (the controller `approve`s the adapter as part of its
   origination batch — see Cross-ticket obligations). (`deposit` to receiver `borrowAccount` needs no consent —
   EVK credits shares to any receiver.)
6. **Freeze the router** — `ROUTER.transferGovernance(address(0))` (`EdgeFactory.sol:123`): the wiring is now
   immutable; nobody can re-point this line's price source. (Price *values* still flow — the registry's
   `cache[lienToken]` is updated by the CRE; only the routing is frozen.)
7. **Wire-check + record** (see "No-cross-wire methodology").

### `LineAccount` (the fresh per-line borrower-account owner — the borrower-model change)
A minimal owner contract, **one deployed per line, abandoned at close** (zero ongoing cost — the §4.4/§17
graveyard). Its only job is to establish a fresh EVC owner-prefix and grant the controller the operator bit, in
its **constructor**, so origination stays a single atomic call.

- `constructor(address evc_, address operator_)` (the adapter passes `operator_ = address(adapter)` — the
  `EVC.call` `msg.sender` on the borrow path):
  - `address borrowAccount = address(uint160(address(this)) ^ 1);` — sub-account 1 of **this** contract's own
    prefix (shares the 19-byte prefix; is **code-free** — it is a plain account address, not the contract's own
    coded address, so the EVC's non-owner-must-be-code-free guard does NOT trip, `EthereumVaultConnector.sol:787`).
  - `IEVC(evc_).setAccountOperator(borrowAccount, operator_, true);` — the **owner-self path**
    (`EthereumVaultConnector.sol:364-401`): the call to `setAccountOperator(borrowAccount, …)`
    `authenticateCaller(borrowAccount, allowOperator:true)` finds `haveCommonOwnerInternal(borrowAccount,
    address(this)) == true` (shared prefix) and **registers** `ownerLookup[prefix].owner = address(this)`
    (`:772-774`, the `LineAccount` becomes its prefix's owner) — the code-free guard passes because
    `borrowAccount.code.length == 0` (`:787`). Then on the owner-self path `owner = msgSender = address(this)`
    (`:372`), `bitMask = 1 << (uint160(owner) ^ uint160(borrowAccount)) = 1 << 1`, and `operator_`'s operator
    bit is set (`:387-397`). Net post-state: `isAccountOperatorAuthorized(borrowAccount, operator_) == true`
    over **only** sub-account 1 of this fresh prefix. (`operator_ == the adapter`, the `EVC.call` `msg.sender`;
    `operator_ != address(this)` — the `LineAccount` — and `operator_` does NOT share the borrow account's
    prefix, so the EVC's `operator == EVC || haveCommonOwner(owner, operator)` reject (`:380`) does not fire.)
- **No other functions are required.** The lien-collateral deposit (`borrowAccount` holds the escrow shares),
  the `enableController`/`enableCollateral`, and the `borrow` are all driven by the controller **as the
  operator** (verified: `enableController`/`enableCollateral` are `onlyOwnerOrOperator(account)`,
  `EthereumVaultConnector.sol:419,465` — the operator can call them on-behalf; the `borrow` goes through
  `EVC.call`/`batch` with `allowOperator:true`, `:903`). So the `LineAccount` needs no `enable*`/`borrow` code —
  it is purely the prefix-owner + the one-time grant. Keep it minimal (constructor only; do **not** add an
  `Ownable`/admin/teardown surface — the cluster is disposable).
- **The adapter derives the same `borrowAccount`** off the deterministic `LineAccount` address
  (`borrowAccount = address(lineAccount) ^ 1`) and stores it on the `Line` record. **Do not** re-derive it any
  other way; the deploy and the store read the same expression.
- **Why a contract (not a bare fresh address):** the EVC requires the borrow account's **prefix-owner** to be
  registered and to have granted the operator bit (`isAccountOperatorAuthorizedInternal :1213` returns `false`
  for an unregistered prefix), and an operator may only act on-behalf of a **code-free** account (`:787`). A
  brand-new bare address has no registered owner and no key the protocol holds. The minimal `LineAccount` is the
  deterministic, key-free discharge: its constructor (acting as the prefix owner) registers the prefix and grants
  the bit; the **distinct** code-free sub-account 1 is the actual borrow account. (User-ratified mechanism, Step 1.)

### No-cross-wire methodology (the load-bearing invariant — "crossing wires" = a line reads another lien's price)
Three structural guarantees, all enforced at line-creation:
- **(W1) One call, all local.** `openLine(lienId, lienToken, collateralAmount)` derives every artifact
  (`LineAccount`/`borrowAccount`, COLLAT, ROUTER, EVAULT) from the single `(lienId, lienToken)` args + freshly-created
  local addresses **within the one call**. No shared array/index that could be off-by-one; no later call looks a
  lien up across lines.
- **(W2) One source of truth for the key.** `openLine` **returns** `(lineRef, oracleKey)` and stores
  `lines[lineRef] = Line{collateralVault, lienToken, router, lineAccount, borrowAccount, open}`. The controller
  seeds the returned `oracleKey` (never re-derives it); every later method reads `lines[lineRef]`, never a global.
  So "the address the router reads" and "the address the controller seeds" are the same by construction.
- **(W3) Birth-time wire-check, then frozen.** Before `openLine` returns (after step 2, before/after freeze):
  `(, address rBase,, address rOracle) = ROUTER.resolveOracle(1e18, COLLAT, usdc); if (rBase != lienToken ||
  rOracle != address(oracleRegistry)) revert WireMismatch();` — proves the chain resolves `COLLAT → this lien →
  the registry` (structural; needs no seeded price). Then step 6 freezes the router so it can never be
  re-crossed. The cold-build proves isolation with a **two-line** test (below) — now with **distinct
  `LineAccount` prefixes** (replacing the old per-`subId` test).

---

**Model from (verified against `reference/`)**
- **`EdgeFactory`** (`reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol:56-128`) — the verified per-line
  sequence (escrow vault `:81-90`, borrow vault `:91-99`, per-deployment router `:60` + `govSetConfig`/
  `govSetResolvedVault` `:66-72,:102`, `setLTV` `:106-112`, freeze `:123`). Replicate inline; **do not import**
  (evk-periphery not remapped). Differences (intended): keep `setGovernorAdmin(VENUE)` on the borrow vault (we
  re-tune LTV/caps per report; EdgeFactory renounces); install the **`CREGatingHook`** (EdgeFactory passes 0);
  router via `new EulerRouter` not the router factory; `upgradeable=false` (audit S9 — immutable meta-proxy
  market) vs EdgeFactory's `true`.
- **`GenericFactory.createProxy(address desiredImplementation, bool upgradeable, bytes trailingData)`**
  (`reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol:116`) — pass `desiredImplementation =
  address(0)` (factory's current impl); `createProxy` calls `IComponent(proxy).initialize(msg.sender)`
  (`:142`), so **the caller (this adapter) becomes the vault's governor** — no separate `setGovernorAdmin` to
  self. `trailingData` = `abi.encodePacked(asset, oracle, unitOfAccount)`. Import `import {GenericFactory} from
  "evk/GenericFactory/GenericFactory.sol";` (WOOF-00 `evk/` remap, verified by WOOF-00's probe).
- **`EulerRouter`** (`reference/euler-price-oracle/src/EulerRouter.sol`, import `import {EulerRouter} from
  "euler-price-oracle/EulerRouter.sol";` — verified remap) — ctor `(address evc, address governor) (:47)`;
  `govSetConfig(base,quote,oracle) (:56)`, `govSetResolvedVault(vault,bool) (:69)`, `transferGovernance (Governable)`,
  `resolveOracle(amt,base,quote) returns (uint256, address base, address quote, address oracle) (:123, view)`.
- **`IEVault`** (`reference/euler-vault-kit/src/EVault/IEVault.sol`, `import {IEVault} from "evk/EVault/IEVault.sol";`)
  — `setInterestRateModel(:511)`, `setHookConfig(address,uint32) (:519)`, `setLTV(address collateral, uint16
  borrowLTV, uint16 liqLTV, uint32 rampDuration) (:492, 1e4 scale)`, `setCaps(uint16 supplyCap, uint16 borrowCap)
  (:528, AmountCap)`, `setGovernorAdmin(:481)`, `borrow(uint256 amount, address receiver) (:234, on IBorrowing)`,
  `debtOf(address) (:210)`, `deposit(uint256, address receiver) (:144)` (escrow deposit), `governorAdmin() (:370)`,
  `LTVBorrow(:405)`/`LTVLiquidation(:411)`, `oracle() (:468)`, `liquidate(:295)`. **Escrow share balance** uses
  `IEVault(COLLAT).balanceOf` (IEVault aggregates IToken→IERC20; EVK's bare `IERC4626` does **not** declare
  `balanceOf`).
- **`EVC`** (`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol`, `import {IEVC} from
  "evc/interfaces/IEthereumVaultConnector.sol";`) — `batch(BatchItem[]) (:355 iface)` with `struct BatchItem {
  address targetContract; address onBehalfOfAccount; uint256 value; bytes data; } (:12-23)`; **`call(address
  targetContract, address onBehalfOfAccount, uint256 value, bytes data) (:553, FOUR args)`**; `enableController
  (:462)`, `enableCollateral (:416)`, **`setAccountOperator(address account, address operator, bool authorized)
  (:364)`** (the owner-self grant `LineAccount` issues — registers the prefix owner + sets the bit, `:372-401`),
  `isAccountOperatorAuthorized(address account, address operator) view (:286)` (the hook's gate; internal
  `:1205-1221`, fail-closed for an unregistered prefix `:1213`). The borrow-batch self-call items
  (`enableController`/`enableCollateral`) carry `targetContract = address(evc)`, `onBehalfOfAccount = address(0)`,
  `value = 0` (the EVC reverts `EVC_InvalidAddress`/`EVC_InvalidValue` if either is non-zero on a self-call,
  `:888-895`); the borrow item carries `targetContract = lineRef`, `onBehalfOfAccount = borrowAccount`. The
  controller acts as the **operator** (`authenticateCaller(borrowAccount, allowOperator:true)` `:903`).
- **`EulerEarn`** (`reference/euler-earn/src/EulerEarn.sol`, `import {IEulerEarn, MarketAllocation} from
  "euler-earn/interfaces/IEulerEarn.sol";`) — `reallocate(MarketAllocation[]) (:383, onlyAllocatorRole)`,
  `struct MarketAllocation { IERC4626 id; uint256 assets; } (:11-16)`; onboarding `submitCap(IERC4626,uint256)
  (:287, onlyCuratorRole)`, `acceptCap (:507)`, `setSupplyQueue(IERC4626[]) (:325)`, `supplyQueueLength() (:477)`.
  `reallocate` sets each listed market to the **absolute** target balance `assets` (withdraws from or supplies to
  the market to reach exactly `assets`), `:404-417` — so `fund` passes **absolute** targets (`baseBalance -
  amount`, `lineBalance + amount`), never deltas (see the `fund` step). Reverts `InconsistentReallocation` unless
  `totalWithdrawn == totalSupplied` (`:441`); `type(uint256).max` is the "supply-all-withdrawn" sentinel on the
  supply leg (`:421-422`).
- **`AmountCapLib`** (`reference/euler-vault-kit/src/EVault/shared/types/AmountCap.sol`) — `cap` (raw
  uint256, token units) → the `uint16` AmountCap format `setCaps` expects. The 16-bit layout is **low 6 bits =
  exponent, high 10 bits = mantissa (scaled by 100)**; `resolve` (`:18-28`) decodes as `10**(raw & 63) *
  (raw >> 6) / 100`. So **encode = `(mantissa << 6) | exponent`** — NOT exponent-high; choose the smallest
  `exponent` for which `mantissa = ceil(cap * 100 / 10**exponent) <= 1023` (**round UP**, so the realized cap is
  never below the requested limit). **Raw `0` means NO LIMIT / unlimited** (`:14,:21` → `type(uint256).max`), so
  the adapter MUST reject a requested `cap == 0` (revert `ZeroCap`) rather than emit raw 0 — an unbounded
  borrow/supply cap is a security hole, not a zero cap.
- **NOT** a shared `EulerRouter` with a single fallback (replaced by per-line routers). **NOT** import
  `EdgeFactory`/its `EulerRouterFactory` (use `new EulerRouter`). **NOT** a controller sub-account borrower
  (`sub_i = controller XOR subId`) — that scheme + the `subId` counter + the blanket `setOperator(prefix, …,
  ~uint256(1))` are **retired**; the borrower is the line's fresh `borrowAccount` (sub 1 of the `LineAccount`'s
  own prefix).

**Starting state**
- WOOF-00 done; `contracts/src/venue/IZipcodeVenue.sol` + `contracts/src/venue/LineAccount.sol` +
  `contracts/src/venue/EulerVenueAdapter.sol` are empty stubs with the WOOF-00 header
  (`// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;` — keep both exactly).
  `test/EulerVenueAdapter.t.sol` carries the same header.
- No new `remappings.txt` lines (`evk/`, `evc/`, `euler-earn/`, `euler-price-oracle/`, `@openzeppelin/contracts/`,
  `forge-std/` all resolve via WOOF-00). `evk-periphery` stays un-remapped → `EdgeFactory` is replicated, not
  imported.
- WOOF-01/02/03 exist (WOOF-03 = the **re-authored** operator-auth hook). `ZipcodeController` (§4.4, item 6) does
  **not** — built/tested against a **mock controller** (an EOA that is the operator the `LineAccount` grants;
  authorizes nothing itself — the per-line grant is issued by `LineAccount`; holds the lien) + real
  EVK/EVC/EulerEarn/EulerRouter (or focused recording mocks — see Done when).

**Do NOT**
- **Do NOT let Euler types cross `IZipcodeVenue`** (only `bytes32`/`address`/`uint*`/opaque `lineRef`). No
  `IEVault`/`MarketAllocation`/`BatchItem`/EVC/router/`LineAccount` types in the interface.
- **Do NOT use a shared router or a per-lien `govSetFallbackOracle` on a timelocked router.** Each line owns a
  fresh `EulerRouter`, wired by the adapter (its governor at birth) and **frozen** (`transferGovernance(0)`) —
  this keeps origination atomic (no per-lien timelock).
- **Do NOT borrow on a controller sub-account, and do NOT add a `subId` counter or a blanket
  `setOperator(prefix, …, ~uint256(1))`.** The borrower is the line's fresh `borrowAccount` (sub 1 of the
  per-line `LineAccount` prefix); the grant is **one operator bit per line**, issued by that line's `LineAccount`
  at origination over **that one** account. (This is strictly **more** isolated than the old blanket grant — one
  grant, one account, its own prefix — see Security below. Each line is a separate prefix, so a buggy/compromised
  grant on one line cannot reach another line's account.)
- **Do NOT make the `LineAccount` (or its `borrowAccount`) adapter-owned or controller-owned.** The `LineAccount`
  is its **own** prefix's owner; the controller is merely the **operator** of `borrowAccount`. The adapter borrows
  as that operator, not as the account owner. (The §4.3 hook's `isAccountOperatorAuthorized(borrowAccount,
  controller)` passes precisely because `LineAccount` granted that bit, not because of any shared prefix.)
- **Do NOT use the `LineAccount`'s own coded address as the borrow account.** It must be a **code-free**
  sub-account (sub 1) of the `LineAccount`'s prefix — using `address(lineAccount)` itself trips the EVC
  non-owner-must-be-code-free guard (`EthereumVaultConnector.sol:787`) and bricks the operator path.
- **Do NOT call `EVAULT.borrow` directly** as `msg.sender`. Borrow inside an `EVC.batch` (or `EVC.call`) with
  `onBehalfOfAccount = borrowAccount` so EVK appends `borrowAccount` (not the adapter) as the hook's caller; the
  controller is the authenticated **operator**.
- **Do NOT seed the oracle here.** `registry.seedPrice(lienToken, equityMark)` is the **controller's**
  atomic-batch step; the adapter only **returns** `oracleKey = lienToken` from `openLine`. No registry
  authority on the adapter.
- **Do NOT implement on-chain economic liquidation.** `liquidate(lineRef)` reverts `NotImplemented()` (§4.4e);
  keep it in the interface (venue-completeness) but build no seize path.
- **Do NOT use `require(cond, CustomError())`** (solc ≥ 0.8.26; WOOF-00 pins 0.8.24) — use `if (!cond) revert
  CustomError();`.
- **Do NOT add an `Ownable`/admin override** beyond the controller-gated venue methods. Every mutating
  `IZipcodeVenue` method is **`onlyController`**; role grants (allocator/curator/governor) are §9/item 10, not
  settable here post-deploy. (The per-line operator grant is the `LineAccount`'s constructor, not a settable adapter method.)
- **Do NOT add teardown/`selfdestruct` to `LineAccount`.** The cluster is abandoned at close (the §4.4/§17
  graveyard — user-accepted, zero ongoing cost).

**Key requirements**

*`IZipcodeVenue` (the seam — venue-neutral, UNCHANGED from the sub-account version)*
- `function openLine(bytes32 lienId, address lienToken, uint256 collateralAmount) external returns (address
  lineRef, address oracleKey);`
- `function setLineLimits(address lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap) external;`
- `function fund(address lineRef, uint256 amount) external;`
- `function draw(address lineRef, uint256 amount, address receiver) external;`
- `function observeDebt(address lineRef) external view returns (uint256);`
- `function closeLine(address lineRef) external;`
- `function liquidate(address lineRef) external;` (defensive stub)
- Events (subgraph, §9): `LineOpened(bytes32 indexed lienId, address indexed lineRef, address oracleKey,
  address collateralVault, address router, address borrowAccount);` `LineLimitsSet(address indexed lineRef,
  uint16 borrowLTV, uint16 liqLTV, uint256 cap);` `LineFunded(address indexed lineRef, uint256 amount);`
  `LineDrawn(address indexed lineRef, uint256 amount, address receiver);` `LineClosed(address indexed lineRef);`.
  (`LineOpened` gains `borrowAccount` so the subgraph can index the fresh per-line account; `lienId` carries the
  `LineAccount` salt.)

*`LineAccount` (the fresh per-line borrower-account owner — the borrower-model change)*
- `constructor(address evc_, address operator_)` — derive `borrowAccount = address(uint160(address(this)) ^ 1)`;
  call `IEVC(evc_).setAccountOperator(borrowAccount, operator_, true)`. The adapter passes `operator_ =
  address(this)` (the adapter is the `EVC.call` `msg.sender` on the borrow path — see "THE OPERATOR IDENTITY").
  No state, no other functions, no `Ownable`. (The mechanism is fully described under "Design → `LineAccount`".)
- **Determinism:** the adapter CREATE2-deploys it with `salt = lienId` (`new LineAccount{salt: lienId}(evc,
  controller)`), so the `LineAccount` address — and hence `borrowAccount` — is deterministic in `lienId` for this
  adapter. (Squat-proofing is not load-bearing here: the adapter is the only deployer and `openLine` is
  `onlyController`; if a `lienId` is re-opened, the CREATE2 redeploy reverts on a live cluster — see the
  double-`openLine` test note.)

*`EulerVenueAdapter` (config one)*
- **Constructor** `EulerVenueAdapter(address controller_, address evc_, address eulerEarn_, address
  eVaultFactory_, address oracleRegistry_, address gatingHook_, address irm_, address usdc_, address erebor_,
  address baseUsdcMarket_)` — all `immutable`. (`baseUsdcMarket_` = the no-borrow USDC market at the EE supply-queue
  head that holds un-drawn LP liquidity; `fund` withdraws from it — see `fund`. A setup/supply-side dependency,
  item 10.) (`controller_` = the sole authority **and** the EVC operator each `LineAccount` grants;
  `eVaultFactory_` = the EVK `GenericFactory`; `oracleRegistry_` = `ZIP_ORACLE_REG`; `erebor_` = the **only**
  legal draw receiver, §4.4a/§9. **No shared router, no timelock arg.**) `modifier onlyController { if (msg.sender
  != controller) revert NotController(); _; }`.
- `mapping(address => Line) public lines;` `struct Line { address collateralVault; address lienToken; address
  router; address lineAccount; address borrowAccount; bool open; }`. `lineRef = EVAULT` (the borrow vault).
  **There is NO `subId` field and NO `nextSubId` counter** (retired — each line is its own `LineAccount` prefix).
  Add a `getLine(address lineRef) returns (Line)` struct getter if the public mapping's tuple-getter is awkward
  to consume (a public mapping of a struct returns a tuple, not the struct — same trap WOOF-05 hit).
- **`openLine`** (onlyController) — **`if (collateralAmount != 1e18) revert InvalidCollateralAmount();`** first.
  The lien is a **1/1 primitive** (WOOF-01: fixed `1e18` supply @ 18 dp = the whole property's lien), and the
  close path (§4.4c) reclaims **exactly `1e18`** from the escrow before `burn` — so the design assumes the
  **full** lien is deposited. A bare `!= 0` is too loose: it would wave through a *partial* deposit (e.g.
  `0.3e18`), opening a line that can never be cleanly closed (the reclaim-`1e18`-before-burn underflows
  `ERC20InsufficientBalance`). This rejects both the zero case (EVK `deposit(0, …)` does NOT revert, so it would
  silently open a zero-share line) and any partial. (Defense-in-depth: the controller §4.4a is the primary
  guarantor that it passes the full `1e18` — this is the venue backstop matching the close-path invariant.)
  Then perform steps 0–7 above:
  - step 0: `LineAccount la = new LineAccount{salt: lienId}(evc, address(this));` then `address borrowAccount =
    address(uint160(address(la)) ^ 1);`. (After the deploy `isAccountOperatorAuthorized(borrowAccount,
    address(this)) == true` — the constructor granted the **adapter**, the `EVC.call` caller.)
  - steps 1–4: mint COLLAT, ROUTER, EVAULT; wire + onboard EVAULT.
  - step 5: deposit the lien into `COLLAT` for `borrowAccount`.
  - step 6: freeze the router.
  - assert (W3) `WireMismatch`; store `lines[EVAULT] = Line{COLLAT, lienToken, ROUTER, address(la), borrowAccount,
    true}`; `emit LineOpened(lienId, EVAULT, lienToken, COLLAT, ROUTER, borrowAccount)`; `return (EVAULT,
    lienToken)`.
  (NB: `openLine` needs **NO outer `EVC.batch`** — the CREATE2 deploy + the vault/router governor calls are
  direct adapter calls; a revert in any step rolls back the intra-call deploys, including the `LineAccount`. Only
  `draw`/`closeLine` go through the EVC operator path.)
- **`setLineLimits`** (onlyController, line-open) — `IEVault(lineRef).setLTV(L.collateralVault, borrowLTV,
  liqLTV, 0)` (1e4 scale; ramp 0); `IEVault(lineRef).setCaps(0, _toAmountCap(cap))`; `emit LineLimitsSet(...)`.
  (`supplyCap = 0` is **deliberately** unlimited — raw `0` = unlimited supply; the line's risk bound is the
  borrowCap = `_toAmountCap(cap)` + the LTV×mark gate, not a supply cap. State this intent in a comment so `0` is
  not mistaken for "no supply allowed.")
- **`fund`** (onlyController, line-open) — **`reallocate` is zero-sum and ABSOLUTE-target, NOT a single-item
  top-up (critical build — verified).** `EulerEarn.reallocate` treats each `allocation.assets` as the market's
  **desired ending balance** (`EulerEarn.sol:394,423`) and reverts `InconsistentReallocation` unless
  `totalWithdrawn == totalSupplied` (`:441`). A lone `MarketAllocation{lineRef, amount}` that raises the
  market's balance has `totalSupplied > 0, totalWithdrawn == 0` → **revert**. `fund` must pass a **two-item**
  allocation that withdraws `amount` from the pool's **idle/cash source** and supplies it to `lineRef`:
  `a[0] = {baseUsdcMarket, baseBalance - amount}` (withdraw), `a[1] = {IERC4626(lineRef), currentLineBalance +
  amount}` (supply to the new absolute target). **Read both absolute bases from the EE's *supplied position*, NOT
  a cash-capped view:** `baseBalance = IERC4626(baseUsdcMarket).convertToAssets(IERC4626(baseUsdcMarket).balanceOf(EE_POOL))`
  (and likewise `currentLineBalance` for `lineRef`). **Do NOT use `maxWithdraw`** — it is capped by the market's
  idle cash, so once a prior line has borrowed the cash out, `maxWithdraw` under-reads the base position and the
  next `fund` reverts/under-withdraws (verified in the WOOF-05 integrated cold-build). **This EulerEarn has NO `idle`/`cash` concept** (Morpho-style,
  all assets sit in supply-queue markets; no idle-market immutable). So the funding source must be a **designated
  base USDC market** — a plain no-borrow EVault that holds un-drawn LP liquidity, onboarded to `EE_POOL` at the
  queue head at setup, where `ZipDepositModule` deposits land (§4.5/§9). **This base market is a setup/wiring +
  supply-side dependency, NOT created by the adapter** — it is the constructor immutable `baseUsdcMarket` (or read
  `EE_POOL.supplyQueue(0)`), carried as a cross-ticket obligation on item 10 (deploy/wiring) + the supply side.
  `reallocate(type(uint256).max)` is the "supply all withdrawn" sentinel (`EulerEarn.sol:421-422`) — may simplify
  the supply leg. `emit LineFunded(...)`. (Adapter is the allocator. **`fund` is mock-tested in WOOF-04**; the
  live EE path is the audit/2.md S9/L4 integration.)
- **`draw`** (onlyController, line-open) — **`if (receiver != erebor) revert BadReceiver();`** (security F2 —
  the draw target is pinned to the immutable Erebor off-ramp, §4.4a/§9; do not trust the controller's arg
  blindly). Then build an `EVC.batch` (`borrowAccount = lines[lineRef].borrowAccount`) with **exactly** these
  item encodings (security/build — the self-call vs vault-call encodings differ; `IEthereumVaultConnector.sol:15-19`):
  - item (1) **enable controller** — `targetContract = address(evc)`, `onBehalfOfAccount = address(0)`,
    `value = 0`, `data = abi.encodeCall(IEVC.enableController, (borrowAccount, lineRef))` (EVC self-call: the
    account is in the calldata, NOT in `onBehalfOfAccount`; a non-zero `onBehalfOfAccount` on a self-call reverts
    `EVC_InvalidAddress`, `:888-890`).
  - item (2) **enable collateral** — same self-call shape, `data = abi.encodeCall(IEVC.enableCollateral,
    (borrowAccount, L.collateralVault))`.
  - item (3) **borrow** — `targetContract = lineRef`, `onBehalfOfAccount = borrowAccount`, `value = 0`,
    `data = abi.encodeCall(IBorrowing.borrow, (amount, erebor))`. **`abi.encodeCall` needs the declaring
    sub-interface, NOT the aggregate `IEVault`:** `borrow` is on `IBorrowing` (`evk/EVault/IEVault.sol`
    re-exports it, but `abi.encodeCall(IEVault.borrow, …)` does **not compile** — the function pointer must be
    `IBorrowing.borrow`). Likewise `deposit`/`redeem`/`withdraw` are on EVK's `IERC4626` face (alias the import
    to avoid colliding with OZ's `IERC4626` used by `MarketAllocation`).
  The adapter is the batch `msg.sender` and the **granted operator** of `borrowAccount` (the grant was issued by
  the line's `LineAccount` at `openLine` — **already in place** before any `draw`); EVK appends `borrowAccount`
  as the hook caller → the §4.3 hook's `isAccountOperatorAuthorized(borrowAccount, <hook controller immutable>)`
  passes. `emit LineDrawn(...)`. ((1)/(2) are idempotent across draws — safe to repeat; or guard on a per-line
  `enabled` flag.)

  **THE OPERATOR IDENTITY (resolved — do NOT re-litigate at cold-build; pin it as written).** The EVC
  authenticates the operator against **`_msgSender()` of `EVC.call`/`batch`** (`authenticateCaller(borrowAccount,
  allowOperator:true)`, `EthereumVaultConnector.sol:903,782`). The contract that executes `EVC.call`/`batch` on
  the `draw` path is **the adapter** (the controller drives the borrow only indirectly, through
  `IZipcodeVenue.draw` — §4.4/§4.7). Therefore: **the `LineAccount` must grant the operator bit to the
  ADAPTER**, and the **§4.3 hook's `controller` immutable must be wired to the SAME address (the adapter)**. The
  §4.4 prose calls this address "the controller" abstractly (the privileged borrow-driver); mechanically it is
  the `EVC.call` `msg.sender` = the adapter (in M1 the adapter may be collapsed into the controller — §4.7 — in
  which case they are one address and the wording is literal). **Build consequence:** pass `address(this)` (the
  adapter) — not the venue's `controller_` immutable — as the operator argument to `LineAccount`'s constructor
  (`new LineAccount{salt: lienId}(evc, address(this))`), and wire the test's `CREGatingHook` with
  `controller = address(adapter)`. (`controller_` remains the **authority** that may call `venue.openLine`/`draw`
  — a separate concern from the EVC operator.) This is the spec-clarified, mechanically-forced identity; the
  spec was tightened to say so (§4.4 "borrower-of-record mechanism": the granted operator + the hook gate = the
  `EVC.call` `msg.sender` = the adapter).
- **`observeDebt`** (view) — `return IEVault(lineRef).debtOf(lines[lineRef].borrowAccount);`.
- **`closeLine`** (onlyController, line-open) — `if (observeDebt(lineRef) != 0) revert LineNotRepaid();` unwind
  the escrow collateral back to the controller so it can `burn` the lien (§4.4c). **The escrow shares are owned
  by `borrowAccount`, so a DIRECT `IEVault(COLLAT).redeem(.., borrowAccount)` reverts `E_InsufficientAllowance`**
  (the adapter is not `borrowAccount`'s owner). Route the redeem **through `EVC.call(COLLAT, borrowAccount, 0,
  abi.encodeCall(IERC4626.redeem, (shares, controller, borrowAccount)))`** (the adapter is `borrowAccount`'s
  authorized operator — same mechanism as `draw`; **`IEVC.call` takes FOUR args `(targetContract,
  onBehalfOfAccount, value, data)` — pass `value = 0`**), redeeming the lien out of escrow to the controller.
  `lines[lineRef].open = false` (keep the `Line` record readable so post-close `observeDebt == 0` stays
  queryable); `emit LineClosed(lineRef)`. (The lien `burn` is the controller's step; coordinate with WOOF-01's
  burn-custody note.) `shares = IEVault(COLLAT).balanceOf(borrowAccount)`.
- **`liquidate`** (onlyController) — `revert NotImplemented();` (§4.4e).
- **`_toAmountCap(uint256 amount) internal pure returns (uint16)`** — encode to EVK AmountCap. **The layout is
  `(mantissa << 6) | exponent`** (low 6 bits = exponent, high 10 bits = mantissa scaled ×100), inverting
  `resolve = 10**(cap & 63) * (cap >> 6) / 100` (`AmountCap.sol:18-26`) — **NOT** the `(exponent<<10|mantissa)`
  form. `resolve` truncates **down**, so round the encode UP (pick the smallest representable cap ≥ `amount`)
  so a line capped exactly at `drawAmount` does not revert `SupplyCapExceeded`. **`amount == 0` is forbidden**:
  raw AmountCap `0` decodes to `type(uint256).max` = **unlimited** (`AmountCap.sol:21`), the opposite of a
  zero cap — `if (amount == 0) revert ZeroCap();` (a closed line is `closeLine`, not a zero cap). Pin the
  encode with a round-trip test (`resolve(_toAmountCap(x)) >= x`, smallest such). `OP_BORROW = 1 << 6;
  OP_LIQUIDATE = 1 << 11;` (§3 line 133).
- Errors: `NotController(); UnknownLine(address); WireMismatch(); LineNotRepaid(); NotImplemented();
  BadReceiver(); ZeroCap(); InvalidCollateralAmount();`. Guard every `lineRef` method (except `openLine`) with `if
  (!lines[lineRef].open) revert UnknownLine(lineRef);` — **except `observeDebt`/`closeLine` must remain readable
  AFTER close** (L7/L8 read `observeDebt == 0` post-close): keep the `Line` record (set `open=false` but leave
  `borrowAccount` readable) and let `observeDebt` read a closed line. Resolve so the post-close `observeDebt == 0`
  acceptance stays verifiable.

**Done when**
- `forge build` green (solc 0.8.24); new unit test passes (`contracts/test/EulerVenueAdapter.t.sol`).
- **No-cross-wire proof + two-line distinct-prefix isolation (the load-bearing test — against a real
  EVK/EVC/EulerEarn/EulerRouter stand-up):** open **two** lines for two distinct lien tokens `LIEN_A`/`LIEN_B`
  (distinct `lienId`s → **distinct `LineAccount` prefixes** → distinct `borrowAccount`s); seed
  `cache[LIEN_A]=pA`, `cache[LIEN_B]=pB` (`pA != pB`) on the registry; assert:
  - each line's router resolves to its **own** lien (`ROUTER_A.resolveOracle(1e18, COLLAT_A, USDC)` → `(_, LIEN_A,
    USDC, registry)`, likewise B);
  - **distinct prefixes:** `lineAccount_A != lineAccount_B`, `borrowAccount_A != borrowAccount_B`, and the two
    accounts do **not** share an owner prefix (`EVC.getAddressPrefix(borrowAccount_A) !=
    getAddressPrefix(borrowAccount_B)`); each `LineAccount` is the registered owner of its own prefix;
  - **both lines draw** (the unbounded-isolation proof that replaces the old per-`subId` test): open A, **draw A**
    (bounded by `borrowLTV × pA`), open B, **draw B succeeds** bounded by `pB` alone (each on its **own**
    `borrowAccount` with its **own** single controller = its own borrow vault → no `EVC_ControllerViolation`,
    which the old shared-sub-account bug would have hit); assert `debtOf(borrowAccount_A) == drawA` and
    `debtOf(borrowAccount_B) == drawB`, each unaffected by the other;
  - **the grant authorizes the borrow-driver on the borrow account:** `isAccountOperatorAuthorized(borrowAccount_A,
    address(adapter)) == true` after `openLine` (before any `draw`) — the `LineAccount` granted the adapter (the
    `EVC.call` caller) — and the `draw` clears the **re-authored WOOF-03 hook** wired with `controller =
    address(adapter)` (operator-auth, not `haveCommonOwner`);
  - **a foreign account is rejected by the hook:** an account that did **not** authorize the operator (e.g. an
    arbitrary EOA, or `borrowAccount_B` attempting to borrow against line A's vault) is rejected — the hook
    reverts (N1/N1b → `HookReverted`);
  - **revaluation-independence:** re-mark B to a new price; assert line A's quote/borrow-capacity is byte-for-byte
    unchanged.
  Then **swap-attempt** (W3): prove an `openLine` that tries to point one line's router at the other lien would
  fail the `WireMismatch` check (harness subclass that mis-wires deliberately, OR label it explicitly
  unreachable-by-design — `openLine` builds the wiring itself, so no input drives a mismatch; do NOT claim a
  normal `openLine` "proves" `WireMismatch`).
- **Authority:** every mutating method reverts `NotController` from a non-controller and succeeds from the
  controller; `draw`'s borrow item carries `onBehalfOfAccount == lines[lineRef].borrowAccount`; `liquidate`
  reverts `NotImplemented`; `closeLine` reverts `LineNotRepaid` while debt > 0, succeeds at 0; unknown
  `lineRef` reverts `UnknownLine`.
- **`LineAccount` mechanics:** after `openLine`, `EVC.getAccountOwner(borrowAccount) == address(lineAccount)`
  (the `LineAccount` registered its prefix), `borrowAccount == address(uint160(address(lineAccount)) ^ 1)`, and
  `isAccountOperatorAuthorized(borrowAccount, address(adapter)) == true` (the adapter is the granted operator =
  the `EVC.call` caller); `borrowAccount.code.length == 0` (code-free). `closeLine` reclaims the lien via the
  operator-routed `EVC.call` redeem.
- **Interface neutrality:** `IZipcodeVenue.sol` has **no** Euler-type / `LineAccount` import (grep it);
  `EulerVenueAdapter is IZipcodeVenue` implements every method.
- **Market wiring:** after `openLine`, `IEVault(EVAULT).governorAdmin() == address(adapter)`,
  `IEVault(EVAULT).hookConfig() == (gatingHook, OP_BORROW|OP_LIQUIDATE)` (`OP_REPAY` unset),
  `IEVault(EVAULT).oracle() == ROUTER`, `IEVault(COLLAT).asset() == lienToken`, and the router is frozen
  (`govSet*` reverts post-`transferGovernance(0)`); after `setLineLimits`, `LTVBorrow(COLLAT)==borrowLTV` &
  `LTVLiquidation(COLLAT)==liqLTV`; after `fund`, `EE_POOL` shows the allocation (mock-level — see synthesis);
  `observeDebt` reads `debtOf(borrowAccount)`.
- **EulerEarn MOCKED in the unit test** (`EulerEarn.sol` is `pragma 0.8.26` — cannot `new` under 0.8.24). The
  adapter imports only `IEulerEarn`. The test uses a **recording `IEulerEarn` mock** for
  `reallocate`/`submitCap`/`acceptCap`/`setSupplyQueue` (assert the right args). **EVK/EVC/EulerRouter = live
  stand-up** (precedent `reference/euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol:72-148`); **EulerEarn =
  mock** → "EE_POOL shows the allocation" degrades to "adapter called `reallocate` with the right two-item
  allocation." Label mock-level vs live per assertion. `fund` records the two-item absolute allocation
  `[{baseUsdcMarket, bal-amount}, {lineRef, …}]`; `openLine` `submitCap`s **only** its own freshly-minted EVAULT
  (security F3).
- **Discharges** the WOOF-01 obligation (lien registered as collateral via `setLTV` on `COLLAT`).
- **Acceptance (integration harness — needs the controller §4.4 + wiring ticket; listed so the slice is owned):**
  `audit/2.md` **S6** (deploy `VENUE`, new ctor), **S8** (allocator **+ curator**, EE timelock 0 — spec edit),
  **S9** (per-line onboarding inside `openLine`), **L4** (`openLine→setLineLimits→fund→draw` →
  `LTVSet`/`Allocation`/`Borrow(onBehalfOf=borrowAccount)`; `debtOf(borrowAccount)==drawAmount`;
  `USDC.balanceOf(EREBOR)==drawAmount`; `getQuote(1e18, LIEN_i, USDC)==equityMark` — key unchanged), **L7/L8**
  (`observeDebt==0`, `closeLine`), **N1/N1b** (hook rejects non-operator borrow/liquidate), **N6** (over-LTV
  draw reverts in the borrow step), **N5** (per-line router frozen — `govSet*` reverts). Authority realized:
  `audit/3-results.md` rows **4**, **5–8**, **9** (borrow operator-auth on the line's fresh account).

**Synthesis — critic triage (these AMEND the above; from the inline 5-lens fan-out)**
- **Test feasibility — EulerEarn must be MOCKED in the unit test** (above; the live EE path → audit/2 S9/L4).
- **(W3) `WireMismatch` is a DEFENSIVE invariant, not a caller-reachable branch.** `openLine` builds the
  wiring itself, so no input drives a mismatch. Implement the wire-check as an `internal` function asserted at
  the end of `openLine`; cover it by a harness subclass that mis-wires deliberately, OR label it explicitly
  unreachable-by-design. The real isolation proof is the two-line distinct-prefix both-draw + revaluation test.
- **Tests to include** (qa + security): (1) **revaluation-independence**; (2) **draw BOTH lines** with distinct
  `LineAccount` prefixes (the test that proves the unbounded model — the old `subId` test is retired); (3)
  structural: `ROUTER_A != ROUTER_B`, `EVAULT_A.oracle() != EVAULT_B.oracle()`, `COLLAT_A != COLLAT_B`,
  `lineAccount_A != lineAccount_B`, `borrowAccount_A != borrowAccount_B`, **distinct owner prefixes**; (4)
  cross-resolve negative: `ROUTER_A.resolveOracle(1e18, COLLAT_B, USDC)` does not resolve to a registry price;
  (5) `COLLAT.convertToAssets(1e18) == 1e18` (bare escrow, 1:1 — keep COLLAT single-depositor/no-IRM or the
  equity-mark valuation breaks); (6) revert-atomicity: force a late `openLine` step to revert → no `LineOpened`,
  line not queryable, **and the `LineAccount` deploy rolled back** (the EVM revert rolls back the intra-call
  CREATE2 — `openLine` needs NO outer batch); (7) `collateralAmount != 1e18` reverts `InvalidCollateralAmount` —
  assert **both** `0` AND a partial (e.g. `0.3e18`); a full `1e18` succeeds; (8) `draw` before `fund`; (9)
  **double `openLine` same `lienId`** — the CREATE2 redeploy at `salt=lienId` reverts (`FailedDeployment` /
  create-collision) while the cluster is live → a same-`lienId` re-open reverts; decide + assert (do NOT silently
  open a second line at a colliding address); (10) `closeLine` with residual escrow shares (operator-redeem path
  + the `LineNotRepaid` revert path); (11) `_toAmountCap` round-trip + `cap==0` reverts `ZeroCap`; (12)
  router-freeze assertion inside `openLine` (`ROUTER.governor()==address(0)`); (13) **`LineAccount` grant
  assertion** — `isAccountOperatorAuthorized(borrowAccount, address(adapter))==true` after `openLine`, **false**
  for the adapter on a foreign account; (14) **foreign-account hook rejection** — an un-granted account's borrow
  reverts the re-authored hook.
- **EVC-operator test setup.** The grant is now issued **by the `LineAccount` constructor inside `openLine`** —
  the test does **not** need to `vm.prank(...).setAccountOperator(...)` (that was the old controller-prefix
  blanket-grant setup). After `openLine`, the grant already exists, authorizing **the adapter** (the `EVC.call`
  caller) over `borrowAccount`. Wire the test's `CREGatingHook` with `controller = address(adapter)` so the
  re-authored hook's `isAccountOperatorAuthorized(borrowAccount, controller)` matches the granted operator. The
  mock controller is an EOA used only as the venue's `controller_` **authority** (it calls
  `openLine`/`setLineLimits`/`fund`/`draw`/`closeLine`); it must hold + `approve` the lien for the escrow deposit
  (the adapter `transferFrom`s it in step 5). It is **not** the EVC operator — the adapter is.
- **Vault/router governor calls are DIRECT (not EVC-wrapped).** `EdgeFactory` calls `IEVault(vault).setHookConfig`
  / `router.govSetConfig` **directly** (`EdgeFactory.sol:66,87,98,111`); the adapter is the governor via
  `createProxy`'s `initialize(msg.sender)` / the router ctor, so `onlyEVCAccountOwner onlyGovernor` /
  `governorOnly` pass on a plain call. No `EVC.call` wrapping needed.
- **`openLine` step-5 custody + `collateralAmount`.** Pass the validated `collateralAmount` (always `1e18` after
  the guard) through to `deposit`. Custody: adapter `transferFrom(controller, address(this), amount)` →
  `approve(COLLAT, amount)` → `IEVault(COLLAT).deposit(amount, borrowAccount)` (the controller `approve`s the
  adapter as part of its origination batch — Cross-ticket obligation 1c). A `deposit` to receiver `borrowAccount`
  does not need its consent (EVK credits shares to any receiver).

**Depends on**
WOOF-00, WOOF-01 (`LienCollateralToken` = the escrow vault's asset), WOOF-02 (`ZipcodeOracleRegistry` = the
per-line price source), WOOF-03 **re-authored** (`CREGatingHook` = installed on each borrow vault, gating on
`isAccountOperatorAuthorized(borrowAccount, controller)`). Nothing else to build/prove the authority +
wire-isolation slice. Downstream: `ZipcodeController` (§4.4 — seeds `cache[lienToken]` using the returned
`oracleKey`, owns lien↔escrow custody sequencing; **no longer wires a controller-level operator grant** — that is
now per-line in `openLine`) + the deploy/wiring ticket (§9 — allocator+curator grant, EE timelock 0,
`baseUsdcMarket`).

**Cross-ticket obligations this ticket CREATES (verify discharged by the named ticket):**
1. **`ZipcodeController` (item 6, §4.4a):** (a) **REWORKED (borrower-model 2026-06-05) — the operator grant is no
   longer the controller's job.** The per-line operator grant is issued **inside `VENUE.openLine`** by the
   adapter's `LineAccount` (`EVC.setAccountOperator(borrowAccount, adapter, true)` — grants the adapter, the
   `EVC.call` borrow-driver), so the controller has
   **no `wireVenueOperator`/blanket `setOperator(prefix, …)` step and takes no EVC handle**. (b) seed
   `registry.seedPrice(oracleKey, equityMark)` using the `oracleKey` **returned by `openLine`** (= `lienToken`);
   (c) own the lien↔escrow custody sequencing (controller holds the `1e18` from `create`, `approve`s the adapter
   so `openLine` can deposit it into `COLLAT` for `borrowAccount`, and at close reclaims it before `burn`); (d)
   pass the **full `1e18` lien** as `collateralAmount` (the venue asserts `== 1e18`/`InvalidCollateralAmount` as a
   backstop, but the controller is the primary guarantor — §4.4c's reclaim-`1e18`-before-`burn` underflows on any
   partial).
2. **Deploy/wiring (item 10, §9 / audit S8):** grant the adapter **curator + allocator** on `EE_POOL`; deploy
   `EE_POOL` with curator **timelock 0** for M1; document the single-curator simplification as production
   hardening. **Onboard a `baseUsdcMarket`** (a no-borrow USDC EVault) at the EE supply-queue head as the
   funding source `fund` withdraws from, and pass it to the adapter constructor — coordinate with the supply
   side (§4.5: `ZipDepositModule` deposits LP USDC into `EE_POOL`, which must land in this base market). **The
   old `ZIP_CONTROLLER.wireVenueOperator(EVC)`-before-renounce obligation is REMOVED** — there is no
   controller-level operator wiring; each line's grant is the `LineAccount`'s constructor inside `openLine`.
3. **Spec/audit consequence edits (this window's sweep):** the borrower-account change (`subId` sub-account →
   `LineAccount` + per-line operator grant) threaded through §4.4/§4.7/§17 (Step 1) + this ticket; sweep the
   residual stale `sub_i`/`haveCommonOwner`/blanket-grant references the borrower model left in `audit/2.md`
   (S6 `wireVenueOperator` step + post-state; L6/L7/L8 `ZIP_CONTROLLER_SUB(1)` → the line's `borrowAccount`) and
   `audit/3-results.md` (the access-control `wireVenueOperator` row). **§4.1 oracle key UNCHANGED.** §17
   supply-side decisions UNTOUCHED.
