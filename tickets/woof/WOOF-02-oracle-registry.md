# WOOF-02 — `ZipcodeOracleRegistry` (§4.1)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** Built from this ticket alone against the
> real WOOF-00/01 scaffold (the two new remap lines added): `forge build` clean (solc 0.8.24) + **34/34 unit tests
> pass** (independently re-run; no WOOF-00/01 regression). Code kept: `contracts/src/ZipcodeOracleRegistry.sol`,
> `contracts/test/ZipcodeOracleRegistry.t.sol`. The real build CONFIRMED the load-bearing claims: the
> `calcScale(18, quoteDec, quoteDec)` convention yields `getQuote(1e18, LIEN, USDC) == equityMark` **exact**, and
> the strict-decimals staticcall genuinely rejects **both a 6-dp token and a code-less EOA** on both write paths
> (a `_getDecimals`-based guard would have silently accepted them). Like WOOF-01, a **zero-spec-guess keepsake** —
> every cited reference line accurate (`ReceiverTemplate`/`BaseAdapter`/`ScaleUtils`/`IPriceOracle` faces all
> resolved; no `supportsInterface` collision; OZ-v5 pin holds). The only open points were cosmetic test mechanics.

**Deliverable**
`contracts/src/ZipcodeOracleRegistry.sol` — `contract ZipcodeOracleRegistry is ReceiverTemplate, BaseAdapter`.
A **single** multi-asset push-cache price adapter that prices **every** lien token at its **Proof of Value**
mark (`Proof-notarized appraised value − senior debt`, in the unit of account). It is the EVK read-adapter
(`BaseAdapter`/`IPriceOracle` face) and the CRE receiver (`ReceiverTemplate`) in one contract. Two write
paths — a controller-gated **origination seed** (single lien, atomic with the controller's batch) and a
Forwarder-gated **revaluation** (batch, off the controller's surface) — feed one venue-neutral `cache`; one
stale-checked view serves it. The mark is **event-driven** (no heartbeat): a long, line-term validity window,
fail-closed guards, and no on-chain plausibility band (integrity is upstream: Proof + DON consensus +
immutable Forwarder).

(No valuation/borrow logic — this is the oracle the isolated lien markets read; the appraisal-error +
value-staleness cushion lives in the LTV gap, §4.2/§4.4, not here.)

**Spec §**
`claude-zipcode.md` §4.1 (the registry). Cross:
- §4.2 (the lien token is the **oracle key**; its `decimals()` is pinned to `18` = `LienTokenFactory.LIEN_DECIMALS`).
- §4.4 (the shared **report ABI** `abi.encode(uint8 reportType, bytes payload)`; the registry is the direct
  recipient of `reportType == 3` Revaluation; the controller seeds it at §4.4a Origination — `reportType 1`,
  routed to the controller, which calls the registry within its atomic batch).
- §4.4/§4.1 Registration: each line's `ROUTER_i` is minted, wired `escrowVault → LIEN_i → registry`, and
  **frozen** (`transferGovernance(address(0))`) inside `VENUE.openLine` (§4.7) — the registry is each per-line
  router's resolved oracle for `(LIEN_i, USDC)`. There is **no shared `EulerRouter`, no `govSetFallbackOracle`,
  no per-lien `govSetConfig`** and no timelock call at origination *(per-line-router redesign — supersedes the
  earlier single-shared-router-fallback "F4")*.
- §13 / `audit/3-results.md` rows **21** (`onReport` = Forwarder only), **22** (`_processReport` guards), and
  the seed-authority + Forwarder-immutability rows (see Key requirements / the spec edits this ticket makes).
Locked §17: valuation = **Proof of Value, event-driven** (no AVM/HPI/heartbeat); the mark is held flat
between Proof events (nothing on-chain consumes it — performing loans mark at par for NAV §12; liquidation is
delinquency-driven §4.4e, **not** staleness-driven).

**Model from (verified against `reference/`)**
- **`is ReceiverTemplate`** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`.
  **Inherit it.** Verified: it is `abstract contract ReceiverTemplate is IReceiver, Ownable`; constructor
  `constructor(address _forwarderAddress)` reverts on `address(0)` (`:45`) and stores the Forwarder in a
  **`private`** `s_forwarderAddress` (`:14`); `onReport(bytes,bytes) external` (`:78`) gates
  `msg.sender == s_forwarderAddress` (`:83`) + the optional workflow-identity checks (`:88-117`, enforced only
  when `setExpectedAuthor`/`setExpectedWorkflowId` are non-zero) then calls **`_processReport(report)`**
  (`:119`) — the one `internal virtual` hook we override (`:232`). Import alias **must be added** (see Starting
  state) — `x402-cre-price-alerts/` is **not** in WOOF-00's remap set. Its relative imports `./IReceiver.sol`
  + `./IERC165.sol` resolve as siblings (verified present); `@openzeppelin/contracts/access/Ownable.sol`
  resolves via the existing OZ remap to **euler-vault-kit's OZ copy = v5.0.2** (`Ownable(msg.sender)` at `:44`
  compiles; error `OwnableUnauthorizedAccount(address)`; `renounceOwnership()` present). **Hard dependency:**
  WOOF-00's `@openzeppelin/contracts/` remap MUST stay on euler-vault-kit's OZ (v5) — euler-price-oracle's own
  OZ copy is **v4.9.6** and would NOT compile `ReceiverTemplate` (no `Ownable(initialOwner)` /
  `OwnableUnauthorizedAccount`).
  - **`setForwarderAddress` (`:127`) and `onReport` (`:78`) are NOT `virtual`** (verified — no `virtual`
    keyword) → they **cannot be overridden**. The spec's "override `setForwarderAddress` to revert" is
    therefore *unimplementable against this reference*; immutability is instead enforced by
    **`renounceOwnership()`** after identity wiring (audit/2.md S10b → S11): once `owner() == address(0)`, the
    inherited `onlyOwner` setters (`setForwarderAddress`, `setExpectedAuthor`, `setExpectedWorkflowId`) all
    revert `OwnableUnauthorizedAccount`, permanently freezing the constructor-set Forwarder + the wired
    identity. **This ticket does NOT add an override of `setForwarderAddress`** (it is impossible and
    unnecessary). (Spec edit folded into §4.1/§4.4 + audit S3/N7/3-results row 20 — see PROGRESS.)
- **`is BaseAdapter`** — `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` (resolves via the existing
  `euler-price-oracle/` remap; verified compiled by WOOF-00's probe). **Inherit it.** It has **no
  constructor**; it re-exports `Errors` + `IPriceOracle` (so `import {BaseAdapter, Errors, IPriceOracle} from
  "euler-price-oracle/adapter/BaseAdapter.sol"` works, matching `RedstoneCoreOracle.sol:7`). Override its
  `_getQuote(uint256, address, address) internal view virtual` (`:45`). Its `getQuote`/`getQuotes` externals
  (`:18`/`:24`) delegate to `_getQuote` and return `(out, out)` = `bid==ask==mid` (exactly §4.1). Use its
  `_getDecimals(address) internal view` (`:37`) **only** for the trusted `quote` asset at construction —
  **NOT** for the per-lien decimals guard (it silently returns `18` on a failed `decimals()` staticcall
  `:40`, which would make the guard a no-op — see Do NOT).
- **`name()`** — `IPriceOracle` requires `name() external view returns (string memory)` (verified
  `IPriceOracle.sol`). Satisfy it with `string public constant name = "ZipcodeOracleRegistry";` exactly as
  `RedstoneCoreOracle.sol:26` does (a public constant satisfies the interface fn — verified no `override`
  keyword needed; the cold-build confirms).
- **Scale / `ScaleUtils`** — `reference/euler-price-oracle/src/lib/ScaleUtils.sol` (import
  `{ScaleUtils, Scale} from "euler-price-oracle/lib/ScaleUtils.sol"`). Compute one **immutable** `Scale` at
  construction with `ScaleUtils.calcScale(baseDecimals, quoteDecimals, feedDecimals)` (`:53`) and serve via
  `ScaleUtils.calcOutAmount(inAmount, price, scale, inverse=false)` (`:63`), exactly as `RedstoneCoreOracle`
  does (`:69`, `:129`). **Convention (pinned — see §4.1 spec edit):** `baseDecimals = LIEN_DECIMALS = 18`
  (every lien is guarded to 18 → one immutable scale is valid for all); `quoteDecimals = _getDecimals(quote)`;
  `feedDecimals = quoteDecimals`. With this, `getQuote(1e18, LIEN, USDC) == price`, so the cached `price` **is
  the `equityMark` reported in the quote asset's native units** (USDC = 6 dp) — `getQuote(1e18, LIEN_i, USDC)
  == equityMark` (audit/2.md L4). **`ScaleUtils` imports `@solady/utils/FixedPointMathLib.sol`** — add the
  `@solady` remap (Starting state); verified the solady submodule is present.
- **Cache + stale-checked view pattern** — `reference/euler-price-oracle/src/adapter/redstone/RedstoneCoreOracle.sol`.
  **Replicate the *pattern*, generalized to multi-asset** (do NOT inherit — it is a Redstone consumer):
  the cache struct (`RedstoneCoreOracle.sol:16` declares it with field `priceTimestamp`; **our struct uses
  field name `timestamp`** — `struct Cache { uint208 price; uint48 timestamp; }`), the `price == 0 → revert` +
  `price > type(uint208).max → revert` guards (`:99`/`:100`), and the read-time staleness check guarded by
  `if (block.timestamp > ts)` to avoid underflow (`:122`). **Differences (intended):** one `mapping(address =>
  Cache) cache` keyed on the lien (not a single `cache`); **a long, line-term `validityWindow`** (NOT
  Redstone's 5-min `MAX_STALENESS_UPPER_BOUND` `:24` — there is no upper-bound cap; the mark is event-driven);
  **no on-chain plausibility/value band** (§4.1 — a deviation event may legitimately re-mark far below prior
  value; a band would fight exactly that; integrity is upstream); but **a write-time `ts > block.timestamp`
  reject** (a *timestamp-sanity* guard, NOT a value band — an appraisal cannot be dated after now; closes the
  "far-future `ts` → never-stale" footgun cheaply).
- **Errors** — reuse `Errors.PriceOracle_InvalidAnswer()` (price 0), `Errors.PriceOracle_Overflow()`
  (`> uint208`), `Errors.PriceOracle_TooStale(staleness, validityWindow)` (read past window),
  `Errors.PriceOracle_NotSupported(base, quote)` (unknown lien / wrong quote) — verified signatures in
  `euler-price-oracle/src/lib/Errors.sol`. Declare contract-local custom errors only for the net-new authority
  guards (see Key requirements).
- **Strict decimals** — `import {IERC20} from "forge-std/interfaces/IERC20.sol"` (the same one `BaseAdapter`
  imports; `decimals()` present). Use a **low-level `staticcall`** that reverts on failure (NOT
  `_getDecimals`): `(bool ok, bytes memory d) = lien.staticcall(abi.encodeCall(IERC20.decimals, ()));` then
  require `ok && d.length == 32 && abi.decode(d,(uint8)) == LIEN_DECIMALS`.

**Starting state**
- WOOF-00 done; `contracts/src/ZipcodeOracleRegistry.sol` is an empty stub with the WOOF-00-pinned header —
  `// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;` (**keep both exactly**). The
  `test/ZipcodeOracleRegistry.t.sol` you add carries the same two-line header.
- **Add two `remappings.txt` lines** (WOOF-00 §: "add lines only as later tickets need them"):
  ```
  x402-cre-price-alerts/=../reference/x402-cre-price-alerts/contracts/
  @solady/=../reference/euler-price-oracle/lib/solady/src/
  ```
  (no comment lines — this forge version rejects `#`). The first is the `ReceiverTemplate` base (also reused by
  the §4.4 controller ticket); the second is `ScaleUtils`'s transitive solady dep. All other imports
  (`euler-price-oracle/`, `@openzeppelin/contracts/`, `forge-std/`) resolve via WOOF-00's existing set.
- `WOOF-01` (`LienCollateralToken`/`LienTokenFactory`) exists; its tokens are the oracle keys. This ticket is
  built/unit-tested against **real `LienCollateralToken`s** (deployed via the factory or directly — they pin
  `decimals()` to 18) plus a **mock controller** (any EOA, set via `setController`) and a **mock Forwarder**
  (any EOA passed as the constructor `forwarder`). The `ZipcodeController` (§4.4) does not exist yet.

**Do NOT**
- **Do NOT add an override of `setForwarderAddress` (or `onReport`).** Both base functions are **non-virtual**
  (verified) → an override fails to compile (`Error: Trying to override non-virtual function`). Forwarder
  immutability is achieved by `renounceOwnership()` at deploy (audit/2.md S11), **not** by an override. (This
  corrects the §4.1/§4.4 "override to revert" wording — folded into the spec by this ticket.)
- **Do NOT use `BaseAdapter._getDecimals` for the per-lien decimals guard.** It silently returns `18` on a
  failed `decimals()` staticcall (`BaseAdapter.sol:40`), so the guard would pass for any non-conforming token
  and be a **no-op** — defeating the very check (`§4.2`: an off-by-decimal is a silent 10× mispricing). Use the
  strict `staticcall` (Model from) that **reverts** on failure or on `decimals() != 18`. (`_getDecimals` is
  fine **only** for the trusted `quote` at construction.)
- **Do NOT gate `seedPrice` with a constructor `controller` immutable.** The registry deploys (audit/2.md
  **S3**) **before** the `ZipcodeController` (**S6**), and the controller constructor takes `oracleRegistry`
  (§4.4) — a registry-held controller immutable is a **deploy-order circularity** (same shape as WOOF-01's
  factory). Use the **set-once `setController(address)` (`onlyOwner`)** wired at deploy (audit/2.md S6/S10b)
  and frozen by the S11 renounce; gate `seedPrice` on `msg.sender == controller`.
- **Do NOT make `seedPrice` Forwarder-gated, and do NOT make revaluation go through `seedPrice`.** They are two
  deliberately distinct paths: origination is a **controller** call inside the controller's atomic batch
  (so the price write is ordered `create → seed → setLTV → borrow`, §4.1/§4.4a — a separate CRE→registry
  report could not be ordered inside that batch); revaluation is a **Forwarder** call (`onReport →
  _processReport`), off the controller's privileged surface (§4.1 events 2–3).
- **Do NOT add an on-chain price band / plausibility check / timestamp-future band** in either write path
  (§4.1). A deviation event may legitimately re-mark a home far below its prior value; a band would fight
  that. The only write guards are: `price != 0`, `price ≤ uint208.max`, and `decimals() == 18`. (The
  revaluation `ts` is stored as reported — the DON is trusted via the immutable Forwarder + identity; the seed
  path uses `block.timestamp`.)
- **Do NOT enforce staleness at write time or use staleness to gate liquidation.** `validityWindow` is checked
  **only** in `_getQuote` (read time); a stale/unknown price reverts the *quote*, it does not liquidate
  (liquidation is delinquency-driven, §4.4e). Do **not** import a `MAX_STALENESS_UPPER_BOUND`-style cap on the
  window — it is intentionally long/line-term.
- **Do NOT support the inverse direction** (`base == quote`, pricing USDC in liens) or any `quote != QUOTE`.
  Revert `PriceOracle_NotSupported`. The router only ever queries `(LIEN_i, USDC)` (base==quote is
  short-circuited upstream by `EulerRouter`). `calcOutAmount` is always called with `inverse = false`.
- **Do NOT use `require(cond, CustomError())`** — that overload is solc ≥ 0.8.26; WOOF-00 pins **0.8.24**. Use
  `if (!cond) revert CustomError();` for every custom-error guard.
- **Do NOT store a `lienId`** or any per-lien config beyond the `Cache` — the registry operates purely by
  token address (§4.2: "the registry never stores `lienId`"). No `Ownable`-gated price setter, no admin price
  override, no per-lien `setX`.

**Key requirements**

*Inheritance & immutables*
- **`contract ZipcodeOracleRegistry is ReceiverTemplate, BaseAdapter`.** Constructor
  `constructor(address forwarder, address quote_, uint256 validityWindow_) ReceiverTemplate(forwarder)`:
  store `address public immutable quote = quote_;` (the unit of account, USDC) and `uint256 public immutable
  validityWindow = validityWindow_;` (long/line-term — audit/2.md S3 `validityWindow = long_line_term`);
  compute `Scale internal immutable scale = ScaleUtils.calcScale(LIEN_DECIMALS, _getDecimals(quote_),
  _getDecimals(quote_))` (baseDecimals=18, quoteDecimals=feedDecimals=quote's decimals). `ReceiverTemplate`
  sets `Ownable` owner = `msg.sender` and stores the immutable-by-renounce Forwarder.
  - **Diamond/override surface:** the only functions you must implement/override are `_processReport` (from
    `ReceiverTemplate`), `_getQuote` (from `BaseAdapter`), and `name()` (from `IPriceOracle`, unimplemented by
    `BaseAdapter`). There is **no `supportsInterface` collision**: `IPriceOracle` does **not** extend
    `IERC165`, so `supportsInterface` exists only via `ReceiverTemplate` (already concrete) — do **not**
    re-declare or override it. `getQuote`/`getQuotes` come concrete from `BaseAdapter`.
- **`uint8 public constant LIEN_DECIMALS = 18;`** — the registry's copy of the pin (it cannot read
  `LienTokenFactory.LIEN_DECIMALS()` — the factory deploys at S4, *after* the registry at S3, so it is not a
  constructor immutable). The value MUST equal `LienTokenFactory.LIEN_DECIMALS` (both pinned 18; the per-lien
  guard ties every priced key to it). **Discharges the WOOF-01 cross-ticket obligation** ("validate a
  registered key's `decimals()` == `LIEN_DECIMALS` (18) before caching its mark").
- **`string public constant name = "ZipcodeOracleRegistry";`** (IPriceOracle requirement).
- **`uint8 public constant REVALUATION = 3;`** — the `reportType` the registry accepts (§4.4 report ABI).
- `mapping(address => Cache) public cache;` with `struct Cache { uint208 price; uint48 timestamp; }`
  (`timestamp == 0` ⇒ unset). `address public controller;` (set-once).

*Set-once controller (origination-seed authority)*
- **`setController(address c) external onlyOwner`** — `if (controller != address(0)) revert
  ControllerAlreadySet();` then `controller = c; emit ControllerSet(c);`. Callable once during wiring (after
  the controller is deployed, audit/2.md S6/S10b), then permanently frozen by the S11 `renounceOwnership`.
  (No zero-check needed beyond the set-once guard; setting `address(0)` would only disable `seedPrice`, which a
  governance deployer would not do — but it is harmless and recoverable only pre-renounce. Keep it minimal.)

*Write paths*
- **`seedPrice(address lien, uint256 price) external`** (origination, §4.4a) — `if (msg.sender != controller)
  revert NotController();` then `_writePrice(lien, price, uint48(block.timestamp));` and `emit
  RegistryPriceSeed(lien, price);`. Uses **`block.timestamp`** (the atomic seed happens now). This is the
  method the controller calls inside its origination batch (audit/2.md L4 → `RegistryPriceSeed(LIEN_i,
  equityMark)`).
- **`_processReport(bytes calldata report) internal override`** (revaluation, §4.4 reportType 3, inherited
  Forwarder gate) —
  - `(uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));` — the shared §4.4
    envelope; `if (reportType != REVALUATION) revert InvalidReportType(reportType);` (fail-closed — the
    registry only services type 3).
  - `(address[] memory liens, uint256[] memory prices, uint32 ts) = abi.decode(payload, (address[],
    uint256[], uint32));` (§4.1); `if (liens.length != prices.length) revert LengthMismatch();`.
  - loop `i`: `_writePrice(liens[i], prices[i], uint48(ts)); emit RegistryPriceUpdated(liens[i], prices[i],
    uint48(ts));`. Stores the **reported `ts`** (DON-supplied; no *value* band — §4.1). **Atomicity:** the loop
    is all-or-nothing — one bad entry (failing any `_writePrice` guard) reverts the whole `onReport` (no
    partial writes). (Report ≤ 5 KB caps batch size; the CRE workflow must additionally shard by a
    **gas-bounded** batch count so an oversized report can't revert and brick a cohort's revaluation — a
    CRE-workflow obligation, not on-chain.)
- **`_writePrice(address lien, uint256 price, uint48 ts) internal`** (shared guards, fail-closed):
  `if (price == 0) revert Errors.PriceOracle_InvalidAnswer();`
  `if (price > type(uint208).max) revert Errors.PriceOracle_Overflow();`
  `if (ts > block.timestamp) revert FutureTimestamp();` (timestamp-sanity, NOT a value band — the seed path
  passes `uint48(block.timestamp)`, which is never `> block.timestamp`; only a malformed/hostile revaluation
  `ts` is rejected, closing the never-stale footgun, §4.1)
  `if (_strictDecimals(lien) != LIEN_DECIMALS) revert InvalidLienDecimals(lien);`
  `cache[lien] = Cache({price: uint208(price), timestamp: ts});`.
- **`_strictDecimals(address lien) internal view returns (uint8)`** — strict (revert on failure, NOT
  silent-18): `(bool ok, bytes memory d) = lien.staticcall(abi.encodeCall(IERC20.decimals, ())); if (!ok ||
  d.length != 32) revert InvalidLienDecimals(lien); return abi.decode(d, (uint8));`.

*Read path*
- **`_getQuote(uint256 inAmount, address base, address quoteAsset) internal view override returns
  (uint256)`** (param named `quoteAsset` to avoid shadowing the `quote` immutable):
  `if (quoteAsset != quote) revert Errors.PriceOracle_NotSupported(base, quoteAsset);`
  `Cache memory c = cache[base]; if (c.timestamp == 0) revert Errors.PriceOracle_NotSupported(base,
  quoteAsset);`
  `if (block.timestamp > c.timestamp) { uint256 s = block.timestamp - c.timestamp; if (s > validityWindow)
  revert Errors.PriceOracle_TooStale(s, validityWindow); }`
  `return ScaleUtils.calcOutAmount(inAmount, c.price, scale, false);` (always non-inverse; `bid==ask==mid`
  via `BaseAdapter.getQuotes`).

*Errors & events*
- Contract-local: `error NotController(); error ControllerAlreadySet(); error InvalidReportType(uint8
  reportType); error LengthMismatch(); error InvalidLienDecimals(address lien); error FutureTimestamp();` (the
  price/staleness/support reverts reuse `Errors.*`).
- Events: `event ControllerSet(address indexed controller); event RegistryPriceSeed(address indexed lien,
  uint256 price); event RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp);`.

**Done when**
- `forge build` green (solc 0.8.24); new unit test passes (`contracts/test/ZipcodeOracleRegistry.t.sol`).
- **Unit (Foundry) — provable in isolation with real lien tokens + mock Forwarder/controller (EOAs).** Use
  `abi.encodeWithSelector(...)` in `vm.expectRevert` to pin the **exact** error + args wherever named below.
  - *Deploy + name:* deploy `new ZipcodeOracleRegistry(FORWARDER, USDC_MOCK, VALIDITY)` (USDC_MOCK = a mock
    ERC20 with `decimals()==6`; `VALIDITY = 365 days`, a concrete stand-in for the long line-term window).
    Assert `name() == "ZipcodeOracleRegistry"`, `quote() == USDC_MOCK`, `validityWindow() == VALIDITY` (and
    `> 0`), `LIEN_DECIMALS() == 18`, `getForwarderAddress() == FORWARDER` (inherited).
  - *Scale / value identity (load-bearing — audit L4):* `setController(ctrl)`; `vm.prank(ctrl);
    seedPrice(LIEN, 300_000e6)` with `LIEN` a real `LienCollateralToken`; assert `getQuote(1e18, LIEN,
    USDC_MOCK) == 300_000e6` (**exact ==**); `getQuotes(...) == (300_000e6, 300_000e6)` (bid==ask==mid);
    `getQuote(0.5e18, ...) == 150_000e6`; `getQuote(0, LIEN, USDC_MOCK) == 0`.
  - *Scale truncation + jumbo (no overflow, floor direction):* seed `333_333e6 + 1`; assert `getQuote(3e17,
    LIEN, ...)` equals the hand-computed `fullMulDiv(3e17, 1e6 * price, 1e24)` (floor). Seed a fresh lien with
    `50_000_000e6`; assert `getQuote(1e18) == 50_000_000e6` (proves no overflow in the `inAmount·priceScale·
    price` intermediate at jumbo-loan scale).
  - *Seed authority + event:* `seedPrice` from a non-controller reverts `NotController`; from `ctrl` succeeds,
    `vm.expectEmit(true,false,false,true)` on `RegistryPriceSeed(LIEN, 300_000e6)`; cached `timestamp ==
    block.timestamp`.
  - *Re-seed / overwrite:* seed `(LIEN, p1)` at `t1`; `vm.warp(t1+100)`; re-seed `(LIEN, p2)`; assert
    `cache(LIEN)` returns `price == p2` AND `timestamp == t1+100` (both updated, not stale).
  - *set-once controller:* `setController` from non-owner reverts `OwnableUnauthorizedAccount`; first call from
    owner emits `ControllerSet(ctrl)` (`vm.expectEmit(true,false,false,false)`); a second `setController` (even
    by owner) reverts `ControllerAlreadySet`.
  - *Revaluation (Forwarder path):* with identity expectations unset, `vm.prank(FORWARDER); onReport(metadata,
    abi.encode(uint8(3), abi.encode([LIEN_A,LIEN_B], [pA,pB], uint32(block.timestamp))))` — including with a
    **non-empty garbage `metadata`** (proves the identity branch at `ReceiverTemplate.sol:88` is skipped when
    expectations are zero) — writes both caches, `vm.expectEmit` `RegistryPriceUpdated` for each (indexed
    `lien` + data `price`,`timestamp`==reported ts), `getQuote` returns the new marks.
  - *Revaluation overwriting a seeded entry:* seed `(LIEN, p1)`; then revalue `LIEN` with `p2` at an earlier-but-
    valid `ts`; assert price+timestamp both move to the revaluation's values.
  - *Forwarder gate + reportType + length:* `onReport` from a non-Forwarder reverts `InvalidSender(caller,
    FORWARDER)`; `reportType ∈ {0,1,2,255}` each reverts `InvalidReportType(reportType)`; `liens.length=2,
    prices.length=1` AND `1,2` both revert `LengthMismatch`; an **empty** batch (`0,0`) does **not** revert and
    emits zero `RegistryPriceUpdated`.
  - *Duplicate liens in a batch:* `[LIEN_A, LIEN_A]` with `[p1,p2]`, `p1!=p2` → `cache(LIEN_A).price == p2`
    (last-write-wins), `RegistryPriceUpdated` emitted twice.
  - *Write guards — BOTH paths (seed + revaluation single-element batch):* `price == 0` reverts
    `PriceOracle_InvalidAnswer`; `price == type(uint208).max` **succeeds** (boundary, `>` not `>=`) and caches
    it; `price > type(uint208).max` reverts `PriceOracle_Overflow`; `ts > block.timestamp` (revaluation only —
    seed can't reach it) reverts `FutureTimestamp`.
  - *Strict-decimals guard is REAL (both paths) — the key defensive proof:* a key whose `decimals()` returns
    **6** (a mock ERC20) reverts `InvalidLienDecimals(key)`; an **EOA with no code** reverts
    `InvalidLienDecimals(eoa)` (staticcall returns `ok=true, len=0` → strict guard rejects). Both cases would
    have been **silently accepted** by a `_getDecimals`-based guard (which returns 18). Exercise each on the
    seed path AND inside a revaluation batch.
  - *No value band (positive proof):* seed `(LIEN, 300_000e6)`, then revalue the same lien to `1e6` (>99%
    drop) in one report; assert it **succeeds** and `cache(LIEN).price == 1e6` — operationalizes "no band
    fights a legitimate deviation event."
  - *Read guards:* `getQuote`/`getQuotes` for an un-cached lien revert `PriceOracle_NotSupported(base, quote)`;
    with `quoteAsset != quote` revert `PriceOracle_NotSupported`; after `vm.warp(seedTs + VALIDITY + 1)` a
    quote reverts `abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY)`
    (exact staleness arg); at exactly `seedTs + VALIDITY` it still succeeds (boundary).
  - *Forwarder immutability + identity (simulates S10b→S11):* construct `metadata` with **`abi.encodePacked`**
    (NOT `abi.encode` — `_decodeMetadata` reads fixed offsets 32/64/74). `setExpectedAuthor(owner_)` +
    `setExpectedWorkflowId(WID)`; before renounce, `vm.prank(FORWARDER); onReport(packed(wrongId,name,owner),
    report)` reverts `InvalidWorkflowId(wrongId, WID)`. Then `renounceOwnership()`; assert `owner() ==
    address(0)`, and `setForwarderAddress(any)`, `setExpectedAuthor(any)`, `setController(any)` all revert
    `OwnableUnauthorizedAccount`; the identity gate stays **live** (a wrong-id `onReport` still reverts
    `InvalidWorkflowId`). Separately, a registry **renounced without `setController`** leaves `controller ==
    address(0)`, so every `seedPrice` reverts `NotController` forever (the frozen-unseedable state — why S11's
    pre-gate also asserts `controller != address(0)`).
- **Acceptance (integration harness — needs the controller §4.4, the market/router/hook, the deploy/wiring
  ticket; listed so the slice is owned, NOT satisfied by the unit test):**
  - `audit/2.md` **S3** (deploy `ZIP_ORACLE_REG(FORWARDER, USDC, validityWindow=long_line_term)`;
    `getForwarderAddress() == FORWARDER`). **The immutability post-condition lands at S11** (post-renounce),
    not S3 — see the spec/audit edit this ticket makes.
  - `audit/2.md` **L4** origination: `ZIP_ORACLE_REG` seeds `cache[LIEN_i] = (equityMark, block.timestamp)`
    via `ZIP_CONTROLLER.… → registry.seedPrice(LIEN_i, equityMark)` (controller-gated); event
    `RegistryPriceSeed(LIEN_i, equityMark)`; afterward `EulerRouter.resolveOracle(LIEN_i, USDC) ==
    ZIP_ORACLE_REG` and `getQuote(1e18, LIEN_i, USDC) ≈ equityMark`. (The atomic-batch ordering + the router
    fallback are the controller/wiring tickets' jobs.)
  - `audit/2.md` **N2/N2b** (the registry, as a `ReceiverTemplate`, reverts `InvalidWorkflowId` on a bad
    identity once wired, and `InvalidSender` from a wrong sender) — inherited, exercised in the unit test
    above; the live wiring is S10b. **N7** (post-renounce `setForwarderAddress` reverts) is realized as
    `OwnableUnauthorizedAccount` (the spec/audit edit corrects N7's "overridden to revert").
  - Authority realized: `audit/3-results.md` **row 21** (`onReport` Forwarder-only), **row 22**
    (`_processReport` guards: `price!=0`, `≤uint208`, strict decimals, no band), plus the **new rows** this
    ticket adds for `seedPrice` (controller-only) and the renounce-based Forwarder immutability (row 20
    correction).

**Depends on**
WOOF-00 (scaffold + the two new remap lines) and WOOF-01 (`LienCollateralToken` is the oracle key — its
pinned `decimals()==18` is what the strict guard validates). Nothing else: the registry + its unit test are
completable and provable in isolation with real lien tokens + mock Forwarder/controller EOAs. Downstream:
`ZipcodeController` (§4.4, the real `seedPrice` caller + CRE receiver sibling), the deploy/wiring ticket
(§9 — `setController`, S10b identity, S11 renounce), and the venue/market (§4.7, which mints + wires + freezes
each per-line `ROUTER_i` to this registry inside `openLine`) consume this but are not needed to build or prove it.

**Cross-ticket obligations this ticket CREATES (must be discharged by the named ticket — verify at the end):**
1. **Deploy/wiring ticket (item 10, §9):** call `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)` (set-once) at
   S6 after the controller is deployed; and at S11 **assert `getExpectedWorkflowId() != bytes32(0)` AND
   `controller() != address(0)` immediately before `renounceOwnership()`, aborting the deploy otherwise**
   (security F7 — renouncing with identity unset permanently bypasses the workflow-identity check; renouncing
   without a controller permanently bricks origination seeding). Renounce MUST be the final wiring op.
2. **Venue/market ticket (item 5, §4.7 — NOT the deploy ticket):** each per-line `ROUTER_i` minted inside
   `VENUE.openLine` MUST be wired `escrowVault → LIEN_i → ZIP_ORACLE_REG` then frozen
   (`transferGovernance(address(0))`), so `(LIEN_i, USDC)` resolves to this registry with no shared router and
   no `govSetFallbackOracle` *(per-line-router redesign — discharged by WOOF-04)*.
3. **`ZipcodeController` ticket (item 6, §4.4a):** the origination branch MUST call `registry.seedPrice(LIEN_i,
   equityMark)` **inside** its atomic batch in the `create → seed → setLTV → borrow` order; batch-atomicity is
   the controller ticket's test.
4. **CRE/subnet track (§8):** the revaluation workflow MUST shard each report by a **gas-bounded** batch count
   (not just ≤ 5 KB) and never include a malformed/duplicate entry — the on-chain batch is atomic (one bad
   entry reverts the whole cohort's revaluation).
