# WOOF-02 — ZipcodeOracleRegistry (wiring map)

> **X-Ray (security verdict):** rated **HARDENED** — the multi-line collateral price cache (40 tests). The
> shared-scale + strict-18-decimal key guard (a non-18-dp lien is unreachable), all-or-nothing fail-closed
> revaluation, strictly-newer replay defense, and the deliberate no-value-band are all proven. Report:
> `contracts/src/x-ray/ZipcodeOracleRegistry.md`. ELI20: `docs/ZipcodeOracleRegistry.md`. This doc is the
> code-truth wiring map.

> Source of truth = `contracts/src/ZipcodeOracleRegistry.sol`. Ticket `tickets/woof/WOOF-02-oracle-registry.md`
> + report `reports/WOOF-02-report.md` are intent. Where they disagree with the kept code, the code wins — and
> they do diverge on two points (the controller slot is now Timelock-**re-pointable**, not set-once; and `quote`/
> `validityWindow` are mutable storage, not `immutable`). Both flagged in Gotchas.

## Role
The protocol's single multi-asset price oracle. One deployed contract prices **every** lien token at its Proof
of Value mark (`Proof-notarized appraised value − senior debt`, in the unit of account = USDC). It is two faces
in one contract: the **EVK read-adapter** (`BaseAdapter`/`IPriceOracle`) that every per-line `EulerRouter`
resolves `(LIEN_i, USDC)` to, and the **CRE receiver** (`ReceiverTemplate`) the Chainlink Forwarder pushes
revaluations into. Two write paths feed one venue-neutral push-cache keyed on the lien token address: a
controller-gated origination seed (`seedPrice`, single lien, atomic with the controller's batch) and a
Forwarder-gated revaluation (`_processReport`, reportType 3, batch). One stale-checked view (`_getQuote`) serves
it. The mark is event-driven — no heartbeat, a long line-term validity window, fail-closed write guards, and no
on-chain plausibility band (integrity is upstream: Proof + DON consensus + the Timelock-pinned Forwarder).

## Contracts involved (what each does)
| Contract / file | What it does |
|---|---|
| `ZipcodeOracleRegistry` (`is ReceiverTemplate, BaseAdapter`) | The whole component — one contract. Caches `{price, timestamp}` per lien; serves stale-checked quotes; accepts origination seeds (controller) + revaluation reports (Forwarder). |
| `ReceiverTemplate` (`reference/x402-cre-price-alerts/.../ReceiverTemplate.sol`, `is IReceiver, Ownable`) | Inherited base: holds the **private** `s_forwarderAddress`, gates `onReport` on the Forwarder + optional workflow identity, then calls the `_processReport` hook the registry overrides. Provides `getForwarderAddress()`/`get/setExpectedAuthor`/`get/setExpectedWorkflowId`/`get/setExpectedWorkflowName` + `Ownable`. Its `onReport`/`setForwarderAddress` are **non-virtual**. |
| `BaseAdapter` (`euler-price-oracle/adapter/BaseAdapter.sol`) | Inherited base: concrete `getQuote`/`getQuotes` externals (return `(out, out)` = `bid==ask==mid`) delegating to the `_getQuote` hook the registry overrides; `_getDecimals` helper (silent-18 — used only for the trusted `quote`); re-exports `Errors` + `IPriceOracle`. No constructor. |
| `ScaleUtils` (`euler-price-oracle/lib/ScaleUtils.sol`) | `calcScale(18, quoteDec, quoteDec)` → the `Scale` used at read time by `calcOutAmount(inAmount, price, scale, false)`. |
| `ZipcodeDeployAsserts` (`contracts/src/ZipcodeDeployAsserts.sol`) | item-10 deploy library: `requireIdentityWired(address[] receivers, address registry)` (CTR-16) reads `registry.controller()` and, for EACH receiver, its `getExpectedAuthor()` AND `getExpectedWorkflowName()`, reverting `ReceiverIdentityNotWired(receiver)` on the first unwired receiver, `RegistryControllerUnset(registry)` on an unseeded controller, or `EmptyReceiverSet()` on an empty fleet — the fail-closed per-receiver pre-gate before the final wiring lock. |

## Wiring — internal
**Constructor** (`:72`):
```solidity
constructor(address forwarder, address quote_, uint256 validityWindow_) ReceiverTemplate(forwarder)
```
- `forwarder` → `ReceiverTemplate(forwarder)`: stored in the **private** `s_forwarderAddress` (reverts on zero,
  in the base ctor). Read back via inherited `getForwarderAddress()`. Sets `Ownable` owner = `msg.sender` (the
  deployer).
- `quote_` → `quote` storage (USDC, the unit of account). **Mutable** (`address public quote`, `:28`).
- `validityWindow_` → `validityWindow` storage (the long, line-term read-staleness window, no upper-bound cap).
  **Mutable** (`uint256 public validityWindow`, `:30`).
- `scale` (`Scale internal`, `:32`) derived `= ScaleUtils.calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals)`
  where `quoteDecimals = _getDecimals(quote_)`. Re-derived on every `setQuote`. **The ctor reads `quote_.decimals()`**,
  so `quote_` must be a real ERC20 with `decimals()` at deploy.

**Constants:**
- `LIEN_DECIMALS = 18` (`:20`) — the pinned key decimals (= `LienTokenFactory.LIEN_DECIMALS`); every priced key is
  strict-guarded to it. Duplicated as a constant because the factory deploys *after* the registry (§9 S3 < S4).
- `name = "ZipcodeOracleRegistry"` (`:22`) — satisfies `IPriceOracle.name()`.
- `REVALUATION = 3` (`:24`) — the only `reportType` the registry services (§4.4 report ABI).

**Storage:** `mapping(address => Cache) public cache` (`:41`), `struct Cache { uint208 price; uint48 timestamp; }`
(`timestamp == 0` ⇒ unset); `address public controller` (`:43`) — the origination-seed authority.

**Authority / gating:**
- `seedPrice(address lien, uint256 price)` (`:106`) — gated `msg.sender == controller`, else `NotController()`.
  Writes `{price, block.timestamp}`. Emits `RegistryPriceSeed`.
- `_processReport(bytes calldata)` (`:114`, `override`) — reached only via inherited `onReport`, which is
  Forwarder-gated (+ optional identity). Decodes the §4.4 envelope `(uint8 reportType, bytes payload)`, requires
  `reportType == REVALUATION` else `InvalidReportType`, decodes `payload = (address[] liens, uint256[] prices,
  uint32 ts)`, requires equal lengths else `LengthMismatch`, loops `_writePrice` + emits `RegistryPriceUpdated`.
  **Atomic** — one bad entry reverts the whole report.
- `setController` / `setQuote` / `setValidityWindow` (`:82`/`:89`/`:98`) — all `onlyOwner` (the Timelock at
  deploy). Build-phase **re-pointable**, not set-once.
- `_writePrice` (`:127`) shared fail-closed guards: `price != 0` (`PriceOracle_InvalidAnswer`), `price <=
  uint208.max` (`PriceOracle_Overflow`), `ts <= block.timestamp` (`FutureTimestamp`), **`ts <= cache[lien].timestamp`
  (`StaleReport`) — strictly-newer monotonic guard (SEC-01); first write `timestamp==0` passes, covers BOTH `seedPrice`
  and the rt-3 loop**, `_strictDecimals(lien) == 18` (`InvalidLienDecimals`). **No value/plausibility band.**
  - **SEC-01 operational note:** `seedPrice` stamps `block.timestamp`, so two same-lien seeds in one block now revert
    (origination+draw / draw+draw co-located) — intended fail-closed; the CRE producer must not co-locate them.
- `_strictDecimals` (`:137`) — low-level `staticcall(decimals())`; reverts on `!ok || returndata.length != 32`.
  NOT `BaseAdapter._getDecimals` (which silently returns 18 and would no-op the guard, accepting a 6-dp token or
  a code-less EOA).
- `_getQuote(inAmount, base, quoteAsset)` (`:147`, `override`, view): requires `quoteAsset == quote` else
  `PriceOracle_NotSupported`; requires `cache[base].timestamp != 0` else `PriceOracle_NotSupported`; if
  `block.timestamp - ts > validityWindow` reverts `PriceOracle_TooStale(staleness, validityWindow)`; returns
  `calcOutAmount(inAmount, price, scale, false)`. Only `(LIEN_i, quote)` supported; no inverse.

**Events:** `ControllerSet(address indexed)`, `RegistryPriceSeed(address indexed lien, uint256 price)`,
`RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp)`, `WiringSet(bytes32 indexed slot,
address value)` (emitted by `setQuote` with slot `"quote"`), `ValidityWindowSet(uint256 window)`. Plus inherited
`ReceiverTemplate` events (`ForwarderAddressUpdated`, `ExpectedAuthorUpdated`, `ExpectedWorkflowIdUpdated`, …).

**Errors:** contract-local `NotController`, `ZeroAddress`, `InvalidReportType(uint8)`, `LengthMismatch`,
`InvalidLienDecimals(address)`, `FutureTimestamp`; reused `Errors.PriceOracle_{InvalidAnswer,Overflow,TooStale,
NotSupported}`; inherited `InvalidSender(address,address)` / `InvalidWorkflowId(...)` / `OwnableUnauthorizedAccount`.

## Wiring — cross-component (who points at whom)
**Who holds this registry's address:**
- **`ZipcodeController`** holds `oracleRegistry` (the registry address, a ctor arg, §4.4) — its only seam is calling
  `registry.seedPrice(LIEN_i, equityMark)` inside the atomic origination batch (`create → openLine → seed → setLTV
  → borrow`). The controller is the contract whose address is written into the registry's `controller` slot via
  `setController` — a **bidirectional** pointer pair.
- **Per-line `EulerRouter`** (one minted per line inside `EulerVenueAdapter.openLine`, §4.7) is `govSetConfig(LIEN_i,
  USDC, ZipcodeOracleRegistry)` so `resolveOracle(escrowVault → LIEN_i → registry)`, then `transferGovernance(
  address(0))` **freezes** it. There is **no shared `EulerRouter`, no `govSetFallbackOracle`, no per-lien
  `govSetConfig`** at origination (per-line-router redesign — discharged by WOOF-04, not item-10).
- **Chainlink Forwarder** (`CRE_KEYSTONE_FORWARDER`, the constructor `forwarder` arg) calls `onReport` →
  `_processReport`. Same Forwarder the controller is wired to.

**What this registry holds / calls:**
- `controller` (the seed authority — `ZipcodeController`), Timelock-set post-controller-deploy.
- `quote` (USDC), `forwarder` (in the base, private), and — at read time — staticcalls each lien's `decimals()`.
- It calls **out to nothing** except the per-lien `decimals()` staticcall; it never holds value, never stores a
  `lienId` (operates purely by token address), never calls the controller back.

**Oracle key:** the lien token address (`LIEN_i`, from `LienTokenFactory.create` / `LienCollateralToken`, WOOF-01)
IS the cache key. The strict-decimals guard ties every key to `LIEN_DECIMALS = 18` — **discharging the WOOF-01
cross-ticket obligation** (PROGRESS row "3 · ZipcodeOracleRegistry": validate a registered key's `decimals() ==
18` before caching, proven rejecting a 6-dp token AND a code-less EOA).

**Open cross-ticket obligations naming this component (PROGRESS.md):**
- item-10 (§9): `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)` at S6; the **S11 identity pre-gate** asserting
  per-receiver `getExpectedAuthor() != 0 && getExpectedWorkflowName() != 0 && registry.controller() != 0` (CTR-16)
  before the final wiring lock — **GATE PORTION
  TESTED** by WOOF-10a (`ZipcodeDeployAsserts.requireIdentityWired` + a tested negative); `setController`-at-S6
  wiring is **STILL OPEN**.
- WOOF-04 (§4.7): each per-line `ROUTER_i` wired `escrowVault → LIEN_i → ZIP_ORACLE_REG` then frozen — **DISCHARGED**.
- WOOF-05 (controller §4.4a): `seedPrice` inside the atomic batch, ordered `create → openLine → seed → setLTV →
  borrow` — **DISCHARGED**.
- CRE track (§8.1): revaluation reports sharded by a **gas-bounded** batch count, no malformed/duplicate entries
  (the on-chain batch is atomic) — **DISCHARGED-IN-SPEC**.

## Item-10 deploy facts
**Constructor arg order (audit S3):**
```
new ZipcodeOracleRegistry(forwarder, quote_, validityWindow_)
```
1. `forwarder` = `CRE_KEYSTONE_FORWARDER` (must be non-zero — base ctor reverts on zero).
2. `quote_` = `USDC` (must be a live ERC20 with `decimals()` — the ctor reads it to build `scale`).
3. `validityWindow_` = the long line-term window (test stand-in `365 days`).
- Deploy at **S3**, **before** the controller (S6) — that ordering is *why* `controller` is a setter, not a ctor
  immutable (deploy-order circularity: the controller ctor takes `oracleRegistry`).
- Deployer becomes `Ownable` owner.

**Wiring setters that exist (all `onlyOwner` = the Timelock):**
- `setController(address)` — wire the seed authority at **S6**, after the controller exists. Re-pointable.
- `setQuote(address)` — re-point unit of account (re-derives `scale`). Re-pointable.
- `setValidityWindow(uint256)` — re-set the staleness window. Re-pointable.
- (inherited) `setForwarderAddress`, `setExpectedAuthor`, `setExpectedWorkflowName`, `setExpectedWorkflowId` —
  the S10b identity wiring goes through `setExpectedWorkflowName`/`setExpectedAuthor` (CTR-16 — the `workflowId` pin is dropped, though its setter is retained).

**Ownership posture (kept-code = §17 build-phase Timelock-settable):** owner is the deployer, then handed to the
**Timelock**; ALL wiring stays Timelock-re-pointable. The ticket/report/spec/`ZipcodeDeployAsserts` still describe
a `renounceOwnership()` final lock — under the kept §17 build-phase doctrine that final renounce is **deferred to
pre-prod**; the deploy holds owner = Timelock instead. (See Gotchas — this is the live divergence between prose and
kept code.)

**Asserts that must hold (S11 pre-gate, before any irreversible lock):**
- `ZipcodeDeployAsserts.requireIdentityWired(receivers, ZIP_ORACLE_REG)` passes ⇒ `registry.controller() !=
  address(0)` (else `seedPrice` is permanently unreachable — `NotController` forever) AND each receiver's
  `getExpectedAuthor() != 0 && getExpectedWorkflowName() != 0` (CTR-16; else the conditional identity gate degrades `onReport` to Forwarder-
  sender-only, the dormant-identity vuln). The deploy test MUST include a **tested negative** (renounce/lock with
  either unset reverts at the gate).
- Post-S3 sanity: `getForwarderAddress() == FORWARDER`, `quote() == USDC`, `validityWindow() > 0`,
  `LIEN_DECIMALS() == 18`, `name() == "ZipcodeOracleRegistry"`.
- Value identity (the load-bearing scale check): after a seed, `getQuote(1e18, LIEN_i, USDC) == equityMark`
  **exact** (USDC native 6-dp units).

## Gotchas
- **`controller` is NOT set-once (code wins over ticket).** The ticket specifies `setController` with a
  `ControllerAlreadySet` set-once guard; the kept code has **no** such guard — `setController` is plain `onlyOwner`
  and re-pointable (the test sets it twice with different values). Same for `quote`/`validityWindow`: the ticket/
  spec say `immutable`, the kept code makes them **mutable** storage with `setQuote`/`setValidityWindow`. This is
  the deliberate §17 "build-phase Timelock-settable, lock pre-prod" rework (memory: `oracle-replaceable-timelock-
  wiring`), and the `// NOTE (2026-06-09, §17)` comment at `:26` records it.
- **Renounce vs Timelock-held.** Spec §4.1, the WOOF-02 ticket/report, and `ZipcodeDeployAsserts`'s NatSpec all
  frame Forwarder immutability as `renounceOwnership()` after identity wiring. Under the kept §17 build-phase
  posture, ownership is **transferred to the Timelock (not renounced)** and the renounce is deferred to pre-prod.
  The `requireIdentityWired` pre-gate is still the right assert to run before *any* such lock; just don't assume the
  deploy renounces in M1.
- **Decimals scale is exact only because of the `calcScale(18, quoteDec, quoteDec)` convention.** `feedDecimals =
  quoteDecimals` makes `getQuote(1e18, LIEN, USDC) == price`, so the cached `price` IS the equityMark in USDC's
  native 6 decimals. Re-point `quote` to a token with different decimals and the meaning of cached `price` values
  shifts — `setQuote` re-derives `scale` but does **not** re-scale existing cache entries.
- **Strict decimals is fail-closed and load-bearing.** A key whose `decimals()` reverts/returns short data, or a
  code-less EOA (`staticcall` returns `ok=true, len=0`), is rejected — NOT silently priced. Do not "optimize" the
  guard to `BaseAdapter._getDecimals`.
- **`onReport` / `setForwarderAddress` are non-virtual** in `ReceiverTemplate` — they cannot be overridden. The
  registry only overrides `_processReport` (from `ReceiverTemplate`) and `_getQuote` (from `BaseAdapter`); `name()`
  is satisfied by the public constant. No `supportsInterface` collision (`IPriceOracle` does not extend `IERC165`).
- **`forwarder` is private in the base** — read it via `getForwarderAddress()`, there is no public `forwarder` field.
- **Empty revaluation batch is valid** (`liens.length == 0` does not revert, emits nothing); duplicate liens in one
  batch are last-write-wins. `ts` is stored **as reported** (DON-supplied, trusted via the Forwarder + identity) —
  the only `ts` guard is `ts <= block.timestamp`; the seed path uses `block.timestamp`, which always passes.
- **Staleness gates the quote, not liquidation.** A stale/unknown price reverts `_getQuote`; it does not liquidate
  (liquidation is delinquency-driven, §4.4e). `validityWindow` has no upper-bound cap (unlike Redstone's 5-min
  `MAX_STALENESS_UPPER_BOUND`) — the mark is event-driven.
- **0.8.24 pin:** custom-error guards use `if (!cond) revert Err()` (the `require(cond, Err())` overload is 0.8.26+).
