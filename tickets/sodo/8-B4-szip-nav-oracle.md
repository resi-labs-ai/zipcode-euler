# 8-B4 — `SzipNavOracle` (§7 / `reports/design/baal-spec.md §3`) — the szipUSD NAV-per-share oracle

> **MATERIALIZED + BUILDS GREEN 2026-06-07 (keep-the-build doctrine).** Built from this ticket against the kept
> WOOF-00..05/8-B1 scaffold: `forge build` clean (solc 0.8.24) + **39/39 unit tests pass** (incl. a live
> Base-mainnet fork sig-verification); **154/154 total, no regression** (`forge test --fork-url $BASE_RPC_URL`).
> Code kept: `contracts/src/supply/SzipNavOracle.sol` (~330 LOC), `contracts/src/interfaces/bridge/IXAlphaRate.sol`,
> `contracts/test/SzipNavOracle.t.sol`; `IOptionToken.discount()` added to the stub (on-chain verified == 30).
> The real build surfaced **no spec/ticket contradiction** (the critic-fanout hardening — esp. the explicit TWAP
> walk-back, the uint256 `cumNav`, the flat constructor, the `_legPriceOfToken`/`supplyLp==0` LP clarity, and the
> pinned required-leg set — paid off). Spec edits this window: `claude-zipcode.md` §4.4 (reportType 7), §7 (two
> write authorities + denominator + genesis), §12 (rewrote the stale display-only/WITHHOLD model). Re-run:
> `cd contracts && forge test --match-contract SzipNavOracleTest` (+ `--fork-url $BASE_RPC_URL` for the fork test).

> **Item ID:** `SzipNavOracle` (historically "8-B4"). **Team folder:** `tickets/sodo/`. **Build-only** (internal
> plumbing — the Exit Gate + WOOF-06 read its views; the depositor-facing NAV/APR view is INFLOW-06's job, so no
> interface ticket — same call as WOOF-02, the other `ReceiverTemplate` oracle).
> **NEXT after this:** the Exit Gate + szipUSD (`reports/design/baal-spec.md §4/§5`).

**Deliverable**
`contracts/src/supply/SzipNavOracle.sol` — `contract SzipNavOracle is ReceiverTemplate`.
The **szipUSD junior-vault NAV-per-share oracle**: the **issuance + exit pricing primitive** (NAV is **not**
display-only). It composes the junior basket's NAV **on-chain** — reading every **quantity** trustlessly across
the **main + sidecar** Safes (incl. the **staked** ICHI LP read off the Hydrex gauge), CRE-**pushing only** the
off-chain leg prices it cannot read on Base (the xALPHA `alphaUSD` leg; HYDX/USDC if the pool is thin), and
maintaining an **on-chain cumulative TWAP accumulator** on `navPerShare` over a governed window **`W ≈ 4h`**.
It serves consumers a **bracketed** share price: **`navEntry = max(spot, twap)`** (issuance) and
**`navExit = min(spot, twap)`** (exit), each **18-dp (`1e18 = $1.00`)**. Two write authorities mirror the lien
registry's split (§4.1): the **immutable Forwarder** pushes leg marks as **reportType 7**; a **set-once
`DefaultCoordinator`** is the **sole** impairment-provision writer (M2). Guards: per-pushed-leg **staleness**
(pauses *issuance* only) + a per-push **deviation circuit-break**; **IL is marked-through** (the ICHI LP marks at
true reserve value); **veHYDX is not a leg** (permalocked → ~0 principal); the protocol **never reads the szipUSD
market price** for accounting.

(No yield/strategy logic — this is purely the price oracle the Gate/zap read. The engine modules 8-B5…8-B14 mutate
the basket; this contract only *marks* it.)

**Spec §**
`claude-zipcode.md` **§7** (the `SzipNavOracle` paragraph — the issuance/exit primitive; the three pricing inputs;
the two-layer xALPHA mark) + **`reports/design/baal-spec.md §3`** (the build-grade per-leg source table, composition/TWAP/safety
rails, invariants). Cross:
- **§4.4** report ABI — the shared envelope `abi.encode(uint8 reportType, bytes payload)`; this oracle is the
  **direct** recipient of the **new `reportType == 7`** (NAV leg price), `payload = (uint8[] legs, uint256[]
  prices, uint32 ts)` *(added to §4.4 this window — see "Spec edits this ticket makes")*.
- **§4.5 / §4.5.1 / `reports/design/baal-spec.md §10`** — the basket the oracle marks (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP
  gauge-farmed on Hydrex + transient USDC/HYDX/oHYDX) and the two Safes (main = free equity / sidecar = committed).
- **§11 / §4.6 / `reports/design/baal-spec.md §9`** — the **provision-that-recovers**: the `DefaultCoordinator` (M2) writes a
  bounded, immediately-downward provision into this oracle; recovery writes it back up.
- **§12** — NAV/solvency: this oracle is the junior `navPerShare` primitive *(§12 rewritten this window from the
  retired "display-only / WITHHOLD-not-markdown / in-kind exit with no oracle" model — see "Spec edits")*.
- **§17** — locked: `W = 4h`; `navPerShare₀ = $1.00`; **no self-issuance haircut**; NAV is the issuance/exit
  primitive (not display-only). `tickets/bridge/8x-01-szalpha-wrapper-cct.md` — the two-layer xALPHA mark source.

**Model from (verified against `reference/` + the kept WOOF-02 keepsake)**
- **`is ReceiverTemplate`** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`, imported
  `x402-cre-price-alerts/interfaces/ReceiverTemplate.sol` (the remap already in `remappings.txt` from WOOF-02).
  **Inherit it** — exactly as the kept `contracts/src/ZipcodeOracleRegistry.sol` does. Verified-by-keepsake facts
  (do not re-discover): it is `abstract contract ReceiverTemplate is IReceiver, Ownable`; ctor
  `constructor(address _forwarderAddress)` reverts on `address(0)`; `onReport(bytes,bytes) external` is **non-virtual**
  and gates `msg.sender == s_forwarderAddress` (`InvalidSender`) + the optional workflow-identity checks (enforced
  only when `setExpectedAuthor`/`setExpectedWorkflowId` are non-zero, `InvalidWorkflowId`/`InvalidAuthor`) then calls
  the one `internal virtual` hook **`_processReport(bytes calldata)`** — the only function we override from this base.
  `setForwarderAddress`/`onReport` are **NOT virtual** → cannot be overridden; **Forwarder + identity immutability is
  by `renounceOwnership()` at deploy** (do NOT add an override — it won't compile). `Ownable` resolves to
  euler-vault-kit's **OZ v5.0.2** via the existing `@openzeppelin/contracts/` remap (`OwnableUnauthorizedAccount`,
  `renounceOwnership()` present). `_decodeMetadata` reads fixed offsets 32/64/74 → tests build identity metadata with
  **`abi.encodePacked`**, not `abi.encode`.
- **Do NOT inherit `BaseAdapter`** (unlike WOOF-02). This oracle is **not** an EVK `IPriceOracle` read-adapter wired
  into an `EulerRouter` — its consumers (the Exit Gate, WOOF-06) read its **own** view functions (`navEntry`,
  `navExit`, `spotNavPerShare`, `twapNavPerShare`, `fresh`). No `name()`, no `getQuote`, no `Scale`/`ScaleUtils`.
- **The CRE push-cache pattern + write guards** — replicate the WOOF-02 `ZipcodeOracleRegistry` *pattern*
  (`contracts/src/ZipcodeOracleRegistry.sol`, kept + 34/34 green): `_processReport` strips the §4.4 envelope and
  `require(reportType == <ours>)`; a per-key `Cache { uint256 price; uint48 ts }`; fail-closed write guards
  (`price != 0`, `ts <= block.timestamp` → `FutureTimestamp`); the read-time staleness check guarded by `if
  (block.timestamp > ts)` to avoid underflow; immutability by renounce; set-once authority wired post-deploy
  (`setController` there → `setDefaultCoordinator`/`setShareToken`/etc. here). **Differences (intended):** the keys
  are **fixed leg IDs** (`uint8`), not arbitrary token addresses; this oracle **composes** marks into a NAV rather
  than serving them raw; it adds the **on-chain TWAP accumulator** + the **deviation circuit-break** (WOOF-02 has
  neither). **0.8.24 gotcha (from WOOF-02):** use `if (!cond) revert CustomError();`, **never**
  `require(cond, CustomError())` (that overload is ≥ 0.8.26).
- **xALPHA two-layer mark** (`reports/design/baal-spec.md §3.2` + `tickets/bridge/8x-01-szalpha-wrapper-cct.md`): `xAlphaUSD = exchangeRate ×
  alphaUSD`, where **`exchangeRate` (alpha-per-xAlpha, 18-dp) is read ON-CHAIN** from the xALPHA token (LST
  exchange rate = `staked alpha ÷ supply` — stake accounting, **no pool price**, so subnet emissions accrue here
  non-manipulably) and **`alphaUSD` (USD per 1.0 ALPHA, 18-dp, `1e18 = $1`) is the CRE-pushed market leg** (TWAP'd
  upstream + staleness + deviation guarded here). **M1: xALPHA is a STAND-IN test token** (an 18-dp mock ERC20
  exposing `exchangeRate() returns (uint256)`); the **production** swap-in is the bridged Rubicon LST wrapper
  (`LiquidStakedV3`) — **verify the production rate-getter selector when the 8x bridge lands** (PROGRESS xALPHA
  stand-in resolution; flag, do not block). Minimal local interface: `IXAlphaRate { function exchangeRate()
  external view returns (uint256); }` under `contracts/src/interfaces/bridge/`.
- **ICHI LP reserves (IL marked-through)** — `contracts/src/interfaces/ichi/IICHIVault.sol` (kept; on-chain-verified
  against the live HYDX ICHI vault `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad`): `getTotalAmounts() → (total0,
  total1)` (the vault's full reserves), `totalSupply()` (vault shares), `token0()`/`token1()`, `balanceOf(addr)`.
  Our LP-held-shares = `ichiVault.balanceOf(safe)` (unstaked) **+** `gauge.balanceOf(safe)` (staked), summed over
  **both** Safes; our reserve share = `total0 × heldShares / vaultTotalSupply` (and `total1`), valued at the leg
  price of `token0`/`token1` → **true reserve value, IL not hidden**.
- **Gauge staked balance** — `contracts/src/interfaces/hydrex/IGauge.sol` (kept; verified): `balanceOf(address)`
  (the staker's staked-LP balance; the gauge custodies the ICHI shares). Use **only** `balanceOf` here (no
  deposit/withdraw/claim — that is 8-B6/8-B7).
- **oHYDX intrinsic** — `contracts/src/interfaces/hydrex/IOptionToken.sol` (kept): `discount() returns (uint256)`
  (= 30 on Base, fork-verified 2026-06-06). Intrinsic per oHYDX = `hydxUSD × (100 − discount) / 100`. **Verify
  `discount()` is in the stub; if absent, add it** (cited in `reports/design/baal-spec.md §10.8` 8-B8).
- **Token balances** — `import {IERC20} from "forge-std/interfaces/IERC20.sol"` (the WOOF-02 import; `balanceOf`,
  `totalSupply`, `decimals` present). zipUSD (`ESynth`, 18-dp), USDC (6-dp), HYDX (18-dp), oHYDX (18-dp), xALPHA
  (18-dp stand-in). Read balances via `IERC20(token).balanceOf(safe)`.
- **TWAP accumulator** — there is **no `reference/` to inherit**; author the standard cumulative-observation
  pattern (Uniswap-V3 / Algebra-Integral style, here over `navPerShareSpot`): a fixed-cardinality ring of
  `(uint32 ts, uint224 cum)`, advanced on every push/poke, read by walking back to the observation at-or-before
  `now − W`. Spec'd fully under "Key requirements / TWAP".

**Starting state**
- 8-B1 done (`contracts/script/SummonSubstrate.s.sol` + the `IBaal`/`ISafe` interfaces; the main + sidecar Safe
  addresses are the basket containers this oracle sums over). WOOF-00..05 + WOOF-10a kept + green on disk.
- `contracts/src/supply/SzipNavOracle.sol` is created fresh with the WOOF-00-pinned header — exactly
  `// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;` (keep both). The test
  `contracts/test/SzipNavOracle.t.sol` carries the same two-line header.
- **Remaps:** none new — `x402-cre-price-alerts/`, `@openzeppelin/contracts/`, `forge-std/` are all already in
  `contracts/remappings.txt` (added by WOOF-00/02). The new local interface `IXAlphaRate` lives under
  `contracts/src/interfaces/bridge/` and is imported by relative path.
- Built/tested on the **live Base-mainnet fork** (`BASE_RPC_URL` wired into gitignored `contracts/.env`): real
  USDC + a real ICHI vault + a real gauge + real oHYDX verify the external sigs; **mocked** for controlled NAV math
  are a mock ICHI vault (settable `getTotalAmounts`/`token0`/`token1`/`totalSupply`/`balanceOf`), a mock gauge
  (settable `balanceOf`), a stand-in xALPHA (settable `exchangeRate`), mock zipUSD/HYDX/oHYDX ERC20s, a mock szipUSD
  (settable `totalSupply`/`balanceOf`), and two EOA "Safe" addresses holding mock-token balances (same shape as
  WOOF-04: real Euler live, EulerEarn mocked).

**Do NOT**
- **Do NOT add an override of `setForwarderAddress` or `onReport`** (both non-virtual → won't compile). Forwarder +
  identity immutability is by **`renounceOwnership()`** at deploy (item-10 wiring), not an override.
- **Do NOT inherit `BaseAdapter`/`IPriceOracle`, declare `name()`, `getQuote`, or a `Scale`.** This oracle is not
  wired into an `EulerRouter`; it exposes its own views.
- **Do NOT read or store the szipUSD *market* (CoW) price**, and do NOT let any consumer pass a price — the oracle
  **owns** valuation (§3.4/§7). Issuance/exit/buyback price **only** off this oracle.
- **Do NOT push any quantity or any on-chain-readable leg price.** `reportType 7` carries **only** `alphaUSD` and
  (optionally) `HYDX/USDC` — the legs that cannot be sourced on Base. Every balance, the xALPHA `exchangeRate`, the
  oHYDX `discount`, and the ICHI reserves are **read on-chain, never trusted from a push** (`reports/design/baal-spec.md §3.2`).
- **Do NOT TWAP-smooth the impairment provision.** A `DefaultCoordinator` write takes effect **immediately**
  (it is subtracted from the spot basket value so `navExit = min(spot, twap)` drops at once — no escape); recovery
  writes back up. There is no mechanism that smooths a markdown *away* (§7).
- **Do NOT mark veHYDX as basket principal** (permalocked, non-redeemable → ~0; only realized oHYDX + fees count,
  once claimed into the basket — they then mark as oHYDX/HYDX/xALPHA/zipUSD legs). It is **not** a leg here.
- **Do NOT make `navExit` revert on staleness.** Staleness pauses **issuance** (`navEntry` reverts / `fresh()` is
  false); **exits price off the last good mark** (`navExit` uses the cached prices regardless, §3.3). Asymmetric by
  design.
- **Do NOT divide by zero at genesis.** When `effectiveSupply == 0`, return the genesis `navPerShare₀ = 1e18`
  (the §4.2 seed price), not a revert. Round shares **down** is the Gate's job (§4.1); the oracle returns the price.
- **Do NOT add an on-chain *value* band / plausibility clamp on a leg price** beyond the **deviation circuit-break**
  (a relative per-push move guard, not an absolute band) — a legitimate market move may be large; the band that
  fights manipulation is the deviation guard + upstream TWAP/DON, not a hard min/max (mirrors WOOF-02 §4.1).
- **Do NOT gate the provision write on the oracle re-deriving the bound.** The oracle cannot know `atRiskAmount`;
  the **bound (down by `atRisk×(1−recoveryFloor)`, up by realized receipts) is enforced by the `DefaultCoordinator`**
  (M2, §11). The oracle only enforces **`msg.sender == defaultCoordinator`** (set-once) — exactly the WOOF-02
  controller-gate shape.

**Key requirements**

*Inheritance, immutables, set-once wiring*
- **`contract SzipNavOracle is ReceiverTemplate`.** Use a **single flat constructor** (DEFINITIVE — not a
  `struct` arg; 13 args is within solc's stack limit):
  ```solidity
  constructor(
      address forwarder,        // ReceiverTemplate base (reverts on 0)
      address zipUSD_, address usdc_, address xAlpha_, address hydx_, address oHydx_,   // fixed basket legs
      address mainSafe_, address sidecar_,                                              // the two basket Safes (8-B1)
      uint32 W_, uint256 maxAge_, uint256 maxDeviationBps_                              // governed guards (set at deploy)
  ) ReceiverTemplate(forwarder)
  ```
  Store all as `immutable`. `W` = `4 hours`; `maxAge` = the pushed-leg staleness bound (e.g. `12 hours` — sized
  conservatively per the security note below); `maxDeviationBps` = the per-push circuit-break (e.g. `2000` = 20%).
  `ReceiverTemplate(forwarder)` sets `Ownable` owner = `msg.sender` and stores the renounce-frozen Forwarder.
  - Reject `address(0)` on each token/Safe immutable + `W != 0` + `maxAge != 0` (`ZeroAddress`/fail-closed). (The
    LP/gauge, szipUSD, engineSafe, and DefaultCoordinator are **not** ctor args — they are set-once post-deploy,
    below, because they are deployed after the oracle: the same deploy-order circularity as WOOF-02's controller.)
  - **Seed observation[0] = `Observation(uint32(block.timestamp), 0)`**, `obsIndex = 0`, `cumNav = 0`, and
    `lastUpdate = uint32(block.timestamp)` in the ctor so the accumulator is well-formed from genesis.
- **Set-once, `onlyOwner`, frozen by the deploy-time renounce** (deploy-order: szipUSD/Gate, the LP/gauge, the
  engine Safe, and the `DefaultCoordinator` are all deployed *after* this oracle — same circularity as WOOF-02's
  controller). Each reverts `AlreadyWired(...)` on a second call, and **each rejects a zero-address argument with
  `revert ZeroAddress()`** (fail-closed — a deploy-time mis-wire to `address(0)` must abort the wiring, not silently
  succeed and leave the slot re-settable). For `setLpPosition`, reject if **either** `ichiVault_` or `gauge_` is
  `address(0)` (they are wired together); the AlreadyWired guard keys on `ichiVault != address(0)` only.
  *(ZERO-GUESS GATE 8-B4: an independent re-materialization omitted these setter zero-checks — they were not pinned
  here; the kept build has them and tests each (`ZeroAddress` revert per setter). Folded in.)*
  - **`setShareToken(address szipUSD_)`** — the supply denominator (`szipUSD.totalSupply()`); REQUIRED before
    `navEntry`/`navExit` return a real (non-genesis) price.
  - **`setLpPosition(address ichiVault_, address gauge_)`** — the zipUSD/xALPHA ICHI vault + its Hydrex gauge
    (created at deploy / by 8-B6). While unset (both `address(0)`), the LP leg contributes **0** (M1 pre-LP basket =
    zipUSD/xALPHA/USDC only) — a deliberate, documented degrade, **not** a revert.
  - **`setEngineSafe(address engineSafe_)`** — the 8-B14 buy-and-burn Safe whose **transient pre-burn szipUSD** is
    excluded from the denominator (`reports/design/baal-spec.md §2.3`/§3.3). While unset, the pending-burn adjustment is **0**.
  - **`setDefaultCoordinator(address dc_)`** — the sole provision writer (M2). While unset, `writeProvision`
    reverts `NotDefaultCoordinator` for everyone (no provision path until wired) and the provision stays 0.
- Genesis price constant: **`uint256 public constant GENESIS_NAV = 1e18;`** (= `navPerShare₀ = $1.00`, §4.2/§17).
- Leg IDs: **`uint8 public constant LEG_ALPHA_USD = 0;` `uint8 public constant LEG_HYDX_USD = 1;` `uint8 public
  constant NUM_LEGS = 2;`** and **`uint8 public constant NAV_LEG = 7;`** (the §4.4 reportType). `alphaUSD` =
  USD per 1.0 ALPHA (`1e18 = $1`); `HYDX/USD` = USD per 1.0 HYDX (`1e18 = $1`).

*Pushed-leg cache + the §4.4 reportType-7 path*
- `struct LegCache { uint256 price; uint48 ts; }` and `mapping(uint8 => LegCache) public legCache;`
  (`ts == 0` ⇒ unset).
- **`_processReport(bytes calldata report) internal override`** (Forwarder-gated by the base):
  - `(uint8 reportType, bytes memory payload) = abi.decode(report, (uint8, bytes));`
    `if (reportType != NAV_LEG) revert InvalidReportType(reportType);` (fail-closed — services only type 7).
  - `(uint8[] memory legs, uint256[] memory prices, uint32 ts) = abi.decode(payload, (uint8[], uint256[], uint32));`
    `if (legs.length != prices.length) revert LengthMismatch();` `if (ts > block.timestamp) revert FutureTimestamp();`
  - **Advance the TWAP accumulator FIRST** (`_accumulate()` — books the *old* spot over the elapsed `dt` before the
    new prices apply), **then** write the new leg prices.
  - For each `i`: `uint8 leg = legs[i];` `if (leg >= NUM_LEGS) revert InvalidLeg(leg);` `if (prices[i] == 0) revert
    ZeroPrice();` **deviation circuit-break:** if `legCache[leg].ts != 0`, compute the relative move vs the prior
    price and `if (move_bps > maxDeviationBps) revert DeviationExceeded(leg, prior, prices[i]);`
    (`move_bps = |new − prior| * 10_000 / prior`); then `legCache[leg] = LegCache(prices[i], uint48(ts)); emit
    LegPriceUpdated(leg, prices[i], uint48(ts));`. **Atomicity:** one bad entry reverts the whole `onReport`
    (no partial writes) — the CRE workflow must shard gas-bounded (downstream obligation).

*Spot NAV composition (the heart — `reports/design/baal-spec.md §3.3`)*
- `grossBasketValue() public view returns (uint256)` — **all values in 18-dp USD (`1e18 = $1`)**, summed across
  *(ZERO-GUESS GATE 8-B4: `public`, not `internal` — the kept build exposes it as a view getter that the unit suite
  reads directly to pin the NAV math; downstream introspection is harmless. An independent rebuild that read it as
  `internal` could not assert gross directly.)*
  `mainSafe` + `sidecar`:
  1. **zipUSD** (18-dp, $1): `+ _bal(zipUSD)` (already `1e18 = $1`).
  2. **USDC** (6-dp, $1): `+ _bal(usdc) * 1e12`.
  3. **xALPHA** (18-dp): `+ _bal(xAlpha) * _xAlphaUSD() / 1e18`, where `_xAlphaUSD() = IXAlphaRate(xAlpha).
     exchangeRate() * legCache[LEG_ALPHA_USD].price / 1e18` (both 18-dp → `1e18 = $1` per whole xALPHA).
  4. **HYDX** (18-dp): `+ _bal(hydx) * legCache[LEG_HYDX_USD].price / 1e18`.
  5. **oHYDX** (18-dp): `+ _bal(oHydx) * _oHydxUSD() / 1e18`, where `_oHydxUSD() = legCache[LEG_HYDX_USD].price *
     (100 - IOptionToken(oHydx).discount()) / 100`.
  6. **ICHI LP** (reserves, IL marked-through) — only if `ichiVault != address(0)`:
     `heldShares = ichiVault.balanceOf(mainSafe) + ichiVault.balanceOf(sidecar) + gauge.balanceOf(mainSafe) +
     gauge.balanceOf(sidecar)`; `if (heldShares == 0) → 0;` `supplyLp = ichiVault.totalSupply();`
     **`if (supplyLp == 0) → 0`** (div-by-zero guard — impossible if `heldShares > 0`, but fail-safe);
     `(total0, total1) = ichiVault.getTotalAmounts(); amt0 = total0 * heldShares / supplyLp; amt1 = total1 *
     heldShares / supplyLp;` then `+= _tokenValue(ichiVault.token0(), amt0) + _tokenValue(ichiVault.token1(),
     amt1)`.
     - **`_legPriceOfToken(address token) internal view returns (uint256)`** — the per-**whole-token** USD mark
       (`1e18 = $1`): returns `1e18` for `zipUSD`, `_xAlphaUSD()` for `xAlpha`; **reverts `UnknownLpToken(token)`
       for anything else.** OUR ICHI vault is the **zipUSD/xALPHA** pool, so `token0`/`token1` ∈ `{zipUSD, xAlpha}`
       **only** — both **18-dp** — and any other reserve token is a wrong/spoofed vault (fail-closed). (USDC/HYDX/
       oHYDX are direct-balance legs, never LP reserve tokens.)
     - **`_tokenValue(address token, uint256 amt) internal view returns (uint256)`** — `amt` (18-dp, both LP
       tokens are 18-dp) × `_legPriceOfToken(token)` / `1e18` → 18-dp USD. (No per-token decimal branch is needed
       because both valid LP tokens are 18-dp; `_legPriceOfToken`'s revert is the guard that keeps it so.)
  - veHYDX: **not summed** (§3.2 note).
- **`spotNavPerShare() public view returns (uint256)`**:
  `uint256 supply = _effectiveSupply();` `if (supply == 0) return GENESIS_NAV;`
  `uint256 gross = grossBasketValue();` `uint256 net = gross > provision ? gross - provision : 0;`
  `return net * 1e18 / supply;` (18-dp).
- **`_effectiveSupply() internal view returns (uint256)`**: if `shareToken == address(0)` return 0 (genesis);
  `uint256 ts = IERC20(shareToken).totalSupply();` `uint256 pend = engineSafe == address(0) ? 0 :
  IERC20(shareToken).balanceOf(engineSafe);` `return ts > pend ? ts - pend : 0;`.
- **`_bal(token)`** = `IERC20(token).balanceOf(mainSafe) + IERC20(token).balanceOf(sidecar)`.

*TWAP accumulator (windowed, on `navPerShareSpot`)*
- State: `struct Observation { uint32 ts; uint256 cum; }` (**`cum` is `uint256`**, not packed — removes the
  overflow/precision ambiguity; the gas cost of a 2-slot observation is acceptable for a pricing primitive);
  `Observation[CARDINALITY] public observations;` with **`uint16 public constant CARDINALITY = 65;`**;
  `uint16 public obsIndex;` (the slot of the NEWEST observation); `uint256 public cumNav;` (running
  `Σ navPerShareSpot × dt`); `uint32 public lastUpdate;`.
- **`_accumulate() internal returns (bool advanced)`** (called at the top of `_processReport`, `poke()`, and
  `writeProvision`; returns `true` iff it advanced — `poke()` gates its `Poked` emit on this):
  ```
  uint32 nowTs = uint32(block.timestamp);
  uint32 dt = nowTs - lastUpdate;
  if (dt == 0) return false;                    // already advanced this block (idempotent)
  cumNav += spotNavPerShare() * uint256(dt);    // books the CURRENT (pre-new-price) spot over [lastUpdate, now]
  obsIndex = uint16((uint256(obsIndex) + 1) % CARDINALITY);   // advance ring, wrapping at CARDINALITY
  observations[obsIndex] = Observation(nowTs, cumNav);
  lastUpdate = nowTs;
  return true;
  ```
  Because it reads the *current* spot, in `_processReport` it MUST run **before** the new leg prices are written
  (and in `writeProvision` **before** the new provision is set). `cumNav` is `uint256` and never realistically
  overflows (`spotNavPerShare ~1e18..1e20` × `dt ≤ ~3e7s/yr` × many years ≪ `2^256`); no cast/overflow guard
  needed.
- **`poke() external`** — permissionless; emit `Poked` **only when the accumulator actually advanced** — i.e.
  `if (_accumulate()) emit Poked(uint32(block.timestamp), cumNav);` where **`_accumulate()` returns a `bool`**
  (`true` iff `dt != 0`). The Gate/zap (and any keeper) call this to refresh the accumulator before reading at
  issuance/exit (see the staleness/poke security note). *(ZERO-GUESS GATE 8-B4: the unconditional
  `_accumulate(); emit Poked(...)` form contradicted the `dt == 0` idempotence requirement under "Done when" —
  a same-block second `poke()` must emit NO `Poked` event; pinned to the gated form the kept build uses.)*
- **`twapNavPerShare() public view returns (uint256)`** — explicit ring walk-back (no ambiguity):
  ```
  uint256 spot = spotNavPerShare();
  uint32 nowTs = uint32(block.timestamp);
  uint256 cumNow = cumNav + spot * uint256(nowTs - lastUpdate);   // extrapolate to now at current spot
  uint32 target = nowTs > W ? nowTs - W : 0;                      // want the newest obs with ts <= target
  // walk back from the newest slot, at most CARDINALITY steps, skipping never-written slots (ts == 0):
  bool found; uint32 foundTs; uint256 foundCum;
  uint256 idx = obsIndex;
  for (uint256 i = 0; i < CARDINALITY; i++) {
      Observation memory o = observations[idx];
      if (o.ts != 0 && o.ts <= target) { found = true; foundTs = o.ts; foundCum = o.cum; break; }
      idx = idx == 0 ? CARDINALITY - 1 : idx - 1;                 // step back, wrapping at 0
  }
  if (!found || foundTs == nowTs) return spot;                    // < W of history, or all obs newer than target
  return (cumNow - foundCum) / (nowTs - foundTs);                 // time-weighted avg over [foundTs, now]
  ```
  Graceful fallback to **spot** when the vault is younger than `W` or the ring does not yet span `W`. `CARDINALITY
  = 65` spans `W` at the expected push/poke cadence; if pushes are so dense the ring is < `W` deep, a `poke()`-free
  read simply falls back to spot — the Gate's periodic `poke()` is the coverage guarantee (documented; harmless,
  fail-safe). The walk is bounded to `CARDINALITY` iterations (no unbounded loop / DoS).

*Bracket reads (the consumer surface)*
- **Required pushed-leg set (M1) = `{LEG_ALPHA_USD, LEG_HYDX_USD}`** — **both are ALWAYS pushed in M1.** The
  HYDX/USDC pool is thin + net-draining (`pending-docs/hydrex.md §2.3/§5`), so the §3.2 "HYDX = pool TWAP, **else
  pushed if thin**" resolves to **pushed** for M1 (no on-chain Algebra-oracle TWAP plugin read; the `IAlgebraPool`
  stub only exposes instantaneous `globalState()`, not a windowed TWAP — do NOT use it). A leg is **stale** iff
  `legCache[leg].ts == 0` (never pushed) OR `block.timestamp - legCache[leg].ts > maxAge`.
- **`navEntry() external view returns (uint256)`** — issuance price. **Reverts `StalePrice(leg)` if EITHER
  required leg is stale** (issuance pauses on staleness, §3.3/§7 — check `LEG_ALPHA_USD` then `LEG_HYDX_USD`).
  Then `uint256 s = spotNavPerShare(); uint256 t = twapNavPerShare(); return s > t ? s : t;` (`max(spot,twap)` —
  an up-spike makes minting *more* expensive, a down-spike is ignored; resident-protective both ways).
- **`navExit() external view returns (uint256)`** — exit price; **does NOT revert on staleness** (prices off the
  last good mark, §3.3). `uint256 s = spotNavPerShare(); uint256 t = twapNavPerShare(); return s < t ? s : t;`
  (`min(spot,twap)` — an up-spike is ignored, a down move is taken; resident-protective both ways). **Consumers
  (the Gate) MUST `poke()` immediately before reading `navExit` so the TWAP reflects any move since the last
  update** — see the documented invariants.
- **`fresh() external view returns (bool)`** — `true` iff BOTH required legs are within `maxAge` (the §4
  `navOracle.fresh()` issuance guard). `navEntry` succeeding ⟺ `fresh() == true`.

*Provision (the DefaultCoordinator seam — M2)*
- `uint256 public provision;` (18-dp USD, subtracted from `grossBasketValue` in `spotNavPerShare`).
- **`writeProvision(uint256 newProvision) external`** — `if (msg.sender != defaultCoordinator) revert
  NotDefaultCoordinator();` `_accumulate();` (book the pre-provision spot before the step) `provision =
  newProvision; emit ProvisionWritten(newProvision);`. **Immediate** (not smoothed): the next `spotNavPerShare`
  reflects it, so `navExit = min(spot,twap)` drops at once (no escape), `navEntry = max` stays conservative until
  twap catches up; a recovery (lower `newProvision`) raises spot, exit stays low until twap catches up. The
  **bound** lives in the DefaultCoordinator (M2) — the oracle stores what it is told (§11/§7).

*Documented invariants (NatSpec on the contract — the security review's accepted trade-offs)*
- **The bracket defends the *profitable* direction both ways** (not a bug): issuance `= max(spot, twap)` so an
  attacker who one-block-spikes spot UP only makes their own mint *more* expensive (a spike DOWN is ignored);
  exit `= min(spot, twap)` so a spike UP is ignored (no exit-rich) and only a real down-move is taken. One-block
  spot moves below the TWAP's temporal resolution cannot be turned into a profitable mint or exit.
- **`navExit` prices off the last good mark and may be stale** (asymmetric by design, §3.3): staleness pauses
  *issuance* (`navEntry`/`fresh`), never *exit*. The defense against exiting on a stale-favorable mark is the TWAP
  lag (`min(spot, twap)`) — so **the Gate MUST `poke()` before every exit/issuance read** to fold the latest spot
  into the accumulator (downstream obligation; `poke()` is permissionless so any keeper can also maintain it).
  Document this on `navExit` + expose `lastUpdate` (already public) so consumers can audit TWAP freshness.
- **`writeProvision` is UNBOUNDED at the oracle by design** — the bound (`down ≤ atRisk×(1−recoveryFloor)`, up by
  realized receipts) lives in the set-once `DefaultCoordinator` (M2, §11), which the oracle trusts. The oracle's
  only defenses are `msg.sender == defaultCoordinator` + set-once + the deploy-time renounce. Until wired,
  `writeProvision` reverts for everyone (fail-closed); the item-10 deploy MUST verify the wiring before renounce.
- **The xALPHA `exchangeRate()` read is non-manipulable in production** (LST stake-accounting = `staked alpha ÷
  supply`, **no pool price**, `tickets/bridge/8x-01-szalpha-wrapper-cct.md`) but in **M1 is a STAND-IN mock** — the production
  Rubicon `LiquidStakedV3` rate-getter selector + its supply-immutability are verified at 8x/bridge integration
  (flag, do not block).
- **Genesis / first-deposit is the Gate's responsibility:** the oracle returns `GENESIS_NAV = 1e18` only at zero
  effective supply; the Gate rounds shares **down** and is the first minter, so a pre-deposit basket donation
  cannot profit an attacker (under round-down + pari-passu + the §4.2 seed, a donor recovers less than they
  donate). The oracle does **not** add a first-depositor guard — that is the Gate's (§4.1/§4.2).

*Errors & events*
- `error AlreadyWired(); error NotDefaultCoordinator(); error InvalidReportType(uint8 reportType); error
  LengthMismatch(); error FutureTimestamp(); error ZeroPrice(); error InvalidLeg(uint8 leg); error
  DeviationExceeded(uint8 leg, uint256 prior, uint256 next); error StalePrice(uint8 leg); error
  UnknownLpToken(address token); error ZeroAddress();`.
- `event ShareTokenSet(address indexed szipUSD); event LpPositionSet(address indexed ichiVault, address indexed
  gauge); event EngineSafeSet(address indexed engineSafe); event DefaultCoordinatorSet(address indexed dc); event
  LegPriceUpdated(uint8 indexed leg, uint256 price, uint48 ts); event ProvisionWritten(uint256 provision); event
  Poked(uint32 ts, uint256 cumNav);`. *(ZERO-GUESS GATE 8-B4: `cumNav` is a `uint256` state var, so the `Poked`
  arg is `uint256` — NO cast/truncation. The earlier `uint224` here was inconsistent with the accumulator and
  would force a lossy `uint224(cumNav)` cast in `poke()`; corrected to `uint256` to match the kept build.)*

**Done when**
- `forge build` green (solc 0.8.24); new suite `contracts/test/SzipNavOracle.t.sol` passes; **no regression** in the
  existing suite (run `forge test`).
- **Unit (Foundry, mocks for controlled math).** Pin exact errors/args with `abi.encodeWithSelector` in
  `vm.expectRevert` where named.
  - *Deploy + wiring:* deploy with all immutables (W = 4h, maxAge = 1 days, maxDeviationBps = 2000); assert each
    getter; `getForwarderAddress() == FORWARDER` (inherited). `setShareToken`/`setLpPosition`/`setEngineSafe`/
    `setDefaultCoordinator` each succeed once from owner, revert `OwnableUnauthorizedAccount` from non-owner, and
    revert `AlreadyWired` on a second call.
  - *Genesis price:* before `setShareToken` (or with `totalSupply == 0`), `spotNavPerShare() == 1e18` and
    `navExit() == 1e18`; `navEntry()` reverts `StalePrice` (no leg pushed yet).
  - *Push path (reportType 7):* `vm.prank(FORWARDER); onReport(packedMeta, abi.encode(uint8(7),
    abi.encode([LEG_ALPHA_USD, LEG_HYDX_USD], [alphaUSD, hydxUSD], uint32(block.timestamp))))` writes both
    caches + emits `LegPriceUpdated` each; `onReport` from a non-Forwarder reverts `InvalidSender`; `reportType ∈
    {0,3,6,255}` reverts `InvalidReportType`; `legs.length != prices.length` reverts `LengthMismatch`; an empty
    batch does not revert; `leg >= NUM_LEGS` reverts `InvalidLeg`; `price == 0` reverts `ZeroPrice`;
    `ts > block.timestamp` reverts `FutureTimestamp`.
  - *Deviation circuit-break:* push `alphaUSD = 1e18`; a re-push to `1.19e18` (≤ 20%) succeeds; a re-push to
    `1.21e18` (> 20%) reverts `DeviationExceeded(LEG_ALPHA_USD, 1e18, 1.21e18)`; first-ever push (prior `ts == 0`)
    is never deviation-checked.
  - *NAV composition (the load-bearing math):* set mock balances on `mainSafe`+`sidecar` (zipUSD, USDC, xAlpha
    with a set `exchangeRate`, HYDX, oHYDX with a set `discount`), push `alphaUSD`/`hydxUSD`, set mock szipUSD
    `totalSupply`, and assert `spotNavPerShare()` equals the **hand-computed** 18-dp value — including: USDC's
    `×1e12` scale; xALPHA's `exchangeRate × alphaUSD`; oHYDX's `(100−discount)/100`; the **two-Safe sum**;
    the **engine pending-burn** subtraction (`setEngineSafe`, give it a szipUSD balance, assert the denominator
    drops). A separate case: `exchangeRate = 1.1e18` (LST APR accrual) raises NAV proportionally.
  - *ICHI LP marked-through:* `setLpPosition(mockIchi, mockGauge)`; `mockIchi.token0()=zipUSD, token1()=xAlpha`,
    set `getTotalAmounts()` + `totalSupply()`, give `mainSafe`+`sidecar` both unstaked (`ichiVault.balanceOf`)
    **and** staked (`gauge.balanceOf`) shares; assert the LP leg value = reserve-share × leg prices (hand-computed)
    and that a change in `alphaUSD` (the xALPHA reserve leg) moves the LP value (**IL marked through**). A reserve
    token outside the known legs reverts `UnknownLpToken`. With `ichiVault == address(0)` the LP leg is 0.
  - *TWAP + bracket:* push at `t0`; `vm.warp(t0 + 1h)`; `poke()`; change a balance/price so spot rises; `vm.warp(t0
    + 5h)`; `poke()`; assert `twapNavPerShare()` is between the old and new spot (time-weighted) and
    `navEntry() == max(spot, twap)`, `navExit() == min(spot, twap)`. Before `W` of history, `twap == spot` (and
    `navEntry == navExit == spot`). A `poke()` twice in one block is a no-op (`dt == 0`).
  - *Staleness asymmetry:* push at `t0`; `vm.warp(t0 + maxAge + 1)`; `navEntry()` reverts `StalePrice`,
    `fresh() == false`, but `navExit()` **succeeds** off the last mark (asserts a number).
  - *Provision (immediate, downward, recovers):* `setDefaultCoordinator(dc)`; `writeProvision` from non-`dc`
    reverts `NotDefaultCoordinator`; from `dc`, write a provision and assert `spotNavPerShare()` (and `navExit`)
    drop **immediately** by `provision / supply`; write a smaller provision (recovery) and assert it rises back;
    a provision ≥ gross floors `spotNavPerShare` at 0 (not underflow). `writeProvision(type(uint256).max)` from
    `dc` **succeeds** (unbounded at the oracle — the bound is the coordinator's); before `setDefaultCoordinator`,
    `writeProvision` reverts `NotDefaultCoordinator` for everyone (fail-closed).
  - *Edge cases & rounding (qa hardening — pin floor-division + the safety guards):*
    - **Atomicity:** a `reportType-7` batch `[ALPHA, HYDX]` where the 2nd entry trips a guard (`ZeroPrice` /
      `DeviationExceeded` / `InvalidLeg`) reverts the WHOLE `onReport` — assert BOTH legs keep their prior
      cached values and **zero** `LegPriceUpdated` events fired (no partial write).
    - **TWAP ring wrap-around:** `poke()` > `CARDINALITY` (e.g. 70) times across warps; assert `obsIndex` cycles
      `…→64→0→…` and `twapNavPerShare()` still returns a correct windowed value (no stale/overwritten-slot leak).
    - **`dt == 0` idempotence:** two `poke()`s in one block → the 2nd is a no-op (`cumNav`/`obsIndex`/`lastUpdate`
      unchanged, no `Poked` event).
    - **TWAP boundary at `now − W`:** with observations straddling `W`, assert the obs at-or-before `now − W` is
      selected (exactly at `now − W` selects it; `1s` newer falls back to spot); spot-check the floor-division
      `(cumNow − foundCum)/(nowTs − foundTs)` against a hand-computed time-weighted average.
    - **Per-leg rounding = floor:** 1 wei of xALPHA at `exchangeRate=1.5e18`, `alphaUSD=1e18` contributes 0 (floor);
      pin USDC `×1e12` (1e6 → 1e18 in the numerator); pin oHYDX `×(100−discount)/100`; pin the final
      `net * 1e18 / supply` floor with odd numerator/denominator.
    - **LP reserve-share floor + guards:** `getTotalAmounts=(1e18+1,1e18+2)`, `totalSupply=1e18+3`,
      `heldShares=1e18` → hand-computed floored `amt0/amt1`; `supplyLp==0` → LP leg `0` (no div-by-zero);
      a reserve `token0`/`token1` outside `{zipUSD, xAlpha}` → `UnknownLpToken`.
    - **Engine pending-burn underflow:** `engineSafe` szipUSD balance `>` `totalSupply` → `_effectiveSupply()`
      floors at 0 → `spotNavPerShare()` returns `GENESIS_NAV` (no underflow/revert).
    - **One-block spike resistance (the bracket proof):** inflate spot in one block (donate a basket token to a
      Safe) WITHOUT a `poke()`; assert `navEntry() == max(spot, twap)` rose (minting is **more** expensive, not
      cheap) and `navExit() == min(spot, twap)` ignored the up-spike (still the lower twap) — an attacker cannot
      mint cheap or exit rich on a sub-window spike.
  - *Forwarder immutability (simulates item-10 renounce):* `setExpectedWorkflowId(WID)` + `setExpectedAuthor`;
    a wrong-id `onReport` reverts `InvalidWorkflowId`; `renounceOwnership()`; then `setShareToken`/`setForwarderAddress`/
    `setExpectedAuthor` all revert `OwnableUnauthorizedAccount`; a still-correct `onReport` push still works
    (the Forwarder + identity gate stay live).
- **Fork sig-verification (the keep-the-build mandate — verify external faces against the live chain, not just
  "it compiles").** On a Base-mainnet fork, staticcall the REAL contracts to confirm the interface signatures the
  NAV math depends on: a live ICHI vault `getTotalAmounts()`/`token0()`/`token1()`/`totalSupply()`/`balanceOf`,
  a live gauge `balanceOf`, **`IOptionToken(OHYDX).discount() == 30`**, USDC `decimals() == 6`. (Our zipUSD/xALPHA
  ICHI pool does not exist on Base yet → the LP *math* is mock-driven, the *interface* is fork-verified — exactly
  the WOOF-04 pattern.) Document that the xALPHA `exchangeRate()` getter is **stand-in-verified** for M1, with the
  production wrapper selector to be confirmed at 8x/bridge integration.
- **Acceptance (integration — owned here, satisfied downstream):** the **Exit Gate** (`reports/design/baal-spec.md §4/§5`) reads
  `navEntry()` at `depositFor` (issuance) + `navExit()` at window-RQ (exit) + `poke()`s the accumulator; **WOOF-06**
  reads `navEntry()` (NAV-proportional, round-down); **item 10** wires `setShareToken`/`setLpPosition`/`setEngineSafe`/
  `setDefaultCoordinator` then `renounceOwnership()` (asserting they are wired first); the **CRE track** produces the
  `reportType 7` push (`audit/2` Phase S/L rows + `audit/3-results` authority rows are authored when the CRE track is
  built — the §4.4 type-7 row is added this window).

**Depends on**
8-B1 (the main + sidecar Safe addresses — the basket containers) and WOOF-00 (scaffold + the `x402-cre-price-alerts`
remap). Buildable + provable in isolation with mocks for the not-yet-built basket components (szipUSD, our ICHI
pool/gauge, the engine Safe, the DefaultCoordinator) + fork sig-verification of the real ICHI/gauge/oHYDX faces.
Downstream consumers: the **Exit Gate + szipUSD** (`reports/design/baal-spec.md §4/§5`), **WOOF-06** (the zap re-author),
**8-B14** (buy-and-burn reads NAV), the **DefaultCoordinator** (M2 provision writer), **item 10** (wiring + renounce),
the **CRE track** (the reportType-7 producer).

**Spec edits this ticket makes (folded into `claude-zipcode.md` this window)**
1. **§4.4** — added **`reportType 7` NAV leg price** `(uint8[] legs, uint256[] prices, uint32 ts)` (→ `SzipNavOracle`)
   to the report-ABI table + the routing note.
2. **§7** — named the two write authorities (Forwarder reportType-7 push vs the set-once bounded `DefaultCoordinator`
   provision writer), the `navPerShare` denominator (`totalSupply − engine pending-burn`), the set-once share-token
   wiring + renounce-freeze, and the zero-supply genesis `navPerShare₀`.
3. **§12** — rewrote the stale "**NAV display-only / WITHHOLD-not-markdown / in-kind exit with no oracle in the path**"
   model to the **two-token / `SzipNavOracle` issuance-exit primitive / pari-passu provision-that-recovers** model
   (consistent with §7/§4.5/§11/§17 — the PROGRESS-flagged stale residual).

**Cross-ticket obligations this ticket CREATES (discharge by the named item)**
1. **Exit Gate + szipUSD (next item, `reports/design/baal-spec.md §4/§5`):** issue NAV-proportionally off `navEntry()` (round down),
   exit/window-RQ at `navExit()`, and `poke()` the accumulator before reading; `szipUSD` is wired via `setShareToken`.
2. **8-B14 buy-and-burn (`reports/design/baal-spec.md §7`):** the engine Safe holding transient pre-burn szipUSD is wired via
   `setEngineSafe` so it is excluded from the denominator.
3. **DefaultCoordinator (M2, §11/§4.6):** it is the sole `writeProvision` caller (wired via `setDefaultCoordinator`)
   and MUST enforce the bound (down by `atRisk×(1−recoveryFloor)`, up by realized receipts) — the oracle does not.
4. **Item 10 deploy/wiring (§9):** after deploying szipUSD/Gate, the LP/gauge, the engine Safe, and the
   DefaultCoordinator, call all four set-once setters, **assert `shareToken != 0` before `renounceOwnership()`**
   (else the oracle is permanently stuck at the genesis price), and renounce LAST (freezing the Forwarder + identity).
5. **CRE track (§8):** produce the `reportType 7` push (`alphaUSD`, `HYDX/USD`), **gas-bounded** per report (the
   on-chain batch is atomic — one bad/duplicate entry reverts the cohort), and provision the upstream `alphaUSD`
   TWAP + the xALPHA `exchangeRate` source (production bridge wrapper selector confirmed at 8x integration).
