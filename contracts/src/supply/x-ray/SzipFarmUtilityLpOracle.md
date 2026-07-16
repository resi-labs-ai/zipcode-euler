# X-Ray — `SzipFarmUtilityLpOracle.sol` (single-contract, test-connected)

> SzipFarmUtilityLpOracle | 80 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

> **Update:** the coverage gaps below (the read-path liveness contract, write-value guards, forwarder
> gate, reportType pin, and the three Timelock setters + ctor zero-guards) are **CLOSED** — 15 new tests added to
> `SzipFarmUtilityLpOracle.t.sol` (22/22 green incl. the 3 strict-18-dp-key tests). Every guard, every entry point, and the full read/write path are now
> exercised; the verdict is lifted from ADEQUATE-minus to **ADEQUATE**, alongside its trustless twin.

Dedicated single-contract X-Ray for `contracts/src/supply/SzipFarmUtilityLpOracle.sol`, the **CRE-fed push-cache**
LP-collateral price oracle for the 8-B5 farm utility loop (§4.5.1). It is the **twin** of
[`AlgebraIchiFairLpOracle`](AlgebraIchiFairLpOracle.md): same EVK `_getQuote(lpShares) → USDC` face the farm
utility's `EulerRouter` resolves LP collateral through, but the price is **pushed off-chain by CRE** (a per-LP-share
USD mark) instead of reconstructed on-chain from the pool TWAP. Exercised by `SzipFarmUtilityLpOracle.t.sol` — but
**only the SEC-01 write-staleness guard** (4 tests); the read path, the other write guards, the forwarder gate, and
the three Timelock setters are untested.

> Two faces in one contract: a **CRE receiver** (`ReceiverTemplate` — the Forwarder pushes the mark via `onReport`
> → `_processReport`) and an **EVK read-adapter** (`BaseAdapter`/`IPriceOracle` — `getQuote` reads the cached mark).
> It is modeled directly on `ZipcodeOracleRegistry`, with three deltas: a **single fixed key** (`lpToken`, not a
> per-key map), a dedicated `LP_MARK = 7` reportType, and **no controller-seed path** (the *only* writer is the
> Forwarder push). This is the deploy **default**; the trustless `AlgebraIchiFairLpOracle` is the opt-in alternative
> (`DeployZipcode` P5: `lpTwapWindow == 0` ⇒ this oracle; `!= 0` ⇒ the fair oracle). The key difference vs the twin:
> this one has a **liveness dependency** — a stale/missing mark fails the borrow CLOSED.

## 1. What it is

An 80-nSLOC dual-inheritance adapter (`ReceiverTemplate, BaseAdapter`). Prices `(lpToken, quote=USDC)` from a single
push-cache:

- **Write (CRE only):** `onReport` (forwarder-gated in `ReceiverTemplate`) → `_processReport` (reportType must be
  `LP_MARK = 7`) → `_writePrice` (fail-closed: `mark != 0`, `mark <= uint208.max`, `ts <= now`, `ts` strictly newer
  than cached) → updates `cache = {price, timestamp}`.
- **Read (EVK):** `_getQuote` supports only `(lpToken, quote)`; reverts if the cache is unset (`timestamp == 0`),
  reverts `TooStale` if `now - ts > validityWindow`, else `ScaleUtils.calcOutAmount(inAmount, price, scale, false)`
  — **rounded DOWN**, against the borrower.

Wiring is **Timelock-settable, not immutable** (build phase, §17): `setQuote` (re-derives `scale`), `setLpToken`,
`setValidityWindow` — `onlyOwner`, to be frozen pre-prod. `scale` is `calcScale(18, quoteDecimals, quoteDecimals)`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `onReport(metadata, report)` | forwarder-only (`ReceiverTemplate`) | the only writer; → `_processReport` → `_writePrice`; `InvalidSender` otherwise |
| `getQuote / getQuotes` (BaseAdapter) → `_getQuote` | public view | only `(lpToken, quote)`; fail-closed on unset/stale; `bid==ask==mid` |
| `setQuote(quote_)` | `onlyOwner` (Timelock) | re-derives `scale`; `ZeroAddress` guard; `WiringSet` event |
| `setLpToken(lpToken_)` | `onlyOwner` (Timelock) | `ZeroAddress` + strict-18-dp guard (`InvalidLpDecimals`); `WiringSet` event |
| `setValidityWindow(w)` | `onlyOwner` (Timelock) | no zero-guard (0 ⇒ every read past `ts` fails closed); `ValidityWindowSet` event |
| `cache()` / `name()` / `LP_MARK` / `LP_DECIMALS` / inherited `getForwarder…` | public view | getters |
| `constructor(forwarder, quote_, validityWindow_, lpToken_)` | deploy | `ZeroAddress` (quote/lpToken); strict-18-dp `lpToken` guard (`InvalidLpDecimals`); forwarder-zero reverts `InvalidForwarderAddress` (parent); derives `scale` |

No CRE-operator scalars; no custody. The contract holds only the cache + wiring.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **SEC-01 strictly-newer write** — a mark whose `ts` is not strictly newer than the cached one reverts `StaleReport` (replay / out-of-order / stale-higher-mark over-crediting) | Yes | **`test_SEC01_lp_firstWrite_succeeds` / `_backdated_mark_reverts` / `_equalTs_reverts` / `_strictlyNewer_succeeds`** |
| I-2 | **forwarder-only writes** — any non-Forwarder `onReport` reverts `InvalidSender` | Yes (parent) | **`test_onReport_nonForwarder_reverts`** |
| I-3 | **reportType pinned** — a report whose type != `LP_MARK` reverts `InvalidReportType` | Yes | **`test_processReport_wrongType_reverts`** (rejects the registry's `REVALUATION=3`) |
| I-4 | **write value guards** — `mark==0`→`PriceOracle_InvalidAnswer`; `mark>uint208.max`→`PriceOracle_Overflow`; `ts>now`→`FutureTimestamp` | Yes | **`test_writePrice_zeroMark_reverts` / `_overflowMark_reverts` / `_futureTs_reverts`** |
| I-5 | **read fail-closed** — unsupported `(base,quote)`→`NotSupported`; unset cache (`ts==0`)→`NotSupported`; `now-ts>validityWindow`→`TooStale` | Yes | **`test_getQuote_unsupportedPair_reverts` / `_unsetCache_reverts` / `_stale_reverts`** (the latter also pins the `s==window` boundary as fresh) — the liveness contract that defines this oracle vs its trustless twin |
| I-6 | **quote correctness + rounds DOWN** — `getQuote(1e18, lpToken, USDC) == mark`; `calcOutAmount(...,false)` truncates against the borrower | Yes | **`test_getQuote_value_and_roundsDown`** (value + linearity + a proven non-zero truncated remainder) |
| I-7 | **setters onlyOwner + zero-guard + 18-dp guard + effect** — `setQuote` re-derives `scale`; `setLpToken`/`setQuote` reject zero; `setLpToken` rejects a non-18-dp/code-less key (`InvalidLpDecimals` — `scale` bakes in base=18 and is NOT re-derived on a key re-point); non-owner reverts | Yes | **`test_setQuote_guards_and_effect` / `test_setLpToken_guards_and_effect` / `_non18Decimals_reverts` / `_codeless_reverts` / `test_setValidityWindow_guards_and_effect`** (each: non-owner revert + zero-guard + re-point/tighten effect, old pair reverts) |
| I-8 | **ctor zero-guards + 18-dp guard** — zero quote/lpToken → `ZeroAddress`; non-18-dp `lpToken` → `InvalidLpDecimals`; zero forwarder → `InvalidForwarderAddress` | Yes | **`test_ctor_zeroQuote_reverts` / `_zeroLpToken_reverts` / `_non18LpToken_reverts` / `_zeroForwarder_reverts`** |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `StaleReport` (strictly-newer) | `_writePrice:136` | `test_SEC01_lp_*` (4 tests) |
| `InvalidSender` (forwarder-only) | `ReceiverTemplate.onReport` | `test_onReport_nonForwarder_reverts` |
| `InvalidReportType` | `_processReport:125` | `test_processReport_wrongType_reverts` |
| `PriceOracle_InvalidAnswer` (mark==0) | `_writePrice:133` | `test_writePrice_zeroMark_reverts` |
| `PriceOracle_Overflow` (mark>uint208.max) | `_writePrice:134` | `test_writePrice_overflowMark_reverts` |
| `FutureTimestamp` (ts>now) | `_writePrice:135` | `test_writePrice_futureTs_reverts` |
| `PriceOracle_NotSupported` (wrong pair) | `_getQuote:150` | `test_getQuote_unsupportedPair_reverts` |
| `PriceOracle_NotSupported` (unset cache) | `_getQuote:152` | `test_getQuote_unsetCache_reverts` |
| `PriceOracle_TooStale` (read staleness) | `_getQuote:155` | `test_getQuote_stale_reverts` (+ `s==window` boundary) |
| `setQuote`/`setLpToken` onlyOwner + `ZeroAddress` | `setQuote`/`setLpToken` | `test_setQuote_guards_and_effect` / `test_setLpToken_guards_and_effect` |
| `InvalidLpDecimals` (strict-18-dp LP key) | `_strictLpDecimals`, called in ctor + `setLpToken` | `test_setLpToken_non18Decimals_reverts` / `_codeless_reverts` / `test_ctor_non18LpToken_reverts` |
| `setValidityWindow` onlyOwner + effect | `setValidityWindow` | `test_setValidityWindow_guards_and_effect` |
| ctor `ZeroAddress` / forwarder-zero | ctor / parent | `test_ctor_zeroQuote_reverts` / `_zeroLpToken_reverts` / `_zeroForwarder_reverts` |

**Every guard is now exercised.** The full read path (the liveness-fail-closed behavior that is
the whole point of a push oracle), all write guards, the forwarder gate, and the three Timelock setters now have
dedicated tests.

## 5. Attack surfaces

- **The liveness contract — the defining property — is now proven (I-5).** This oracle exists *because* it accepts a
  liveness dependency the trustless twin avoids: a stale or missing mark must FAIL THE BORROW CLOSED (`TooStale` /
  unset-cache `NotSupported`), never open an unsafe one. `test_getQuote_stale_reverts` proves the `TooStale` past the
  window AND pins the `s == window` boundary as still-fresh; `test_getQuote_unsetCache_reverts` proves the unset-cache
  fail-closed; `test_getQuote_unsupportedPair_reverts` the pair gate. The safety claim the design trades
  manipulation-resistance for is now exercised.
- **Write-value guards now proven (I-4).** `mark==0` (`InvalidAnswer`), `mark > uint208.max` (`Overflow`), and `ts >
  now` (`FutureTimestamp`) each reject a malformed CRE push — all three have dedicated tests; a malformed-payload push
  is exactly what these fail-closed write guards exist to catch.
- **Forwarder gate now proven (I-2).** The *only* writer is the Chainlink Forwarder (`ReceiverTemplate`
  `InvalidSender`); `test_onReport_nonForwarder_reverts` confirms a non-Forwarder caller cannot write the cache.
- **SEC-01 — the original well-covered surface.** The strictly-newer guard (`ts <= cache.timestamp → StaleReport`)
  blocks a stale-but-higher mark from over-crediting collateral; first-write / backdated / equal-ts / strictly-newer
  are all proven. This was the regression the test file was authored for.
- **Timelock setters now proven (I-7).** `setQuote` re-derives `scale` (a decimals mismatch here would silently
  mis-scale every quote) and re-points the quote; `setLpToken` re-points the priced key; `setValidityWindow` tightens
  the staleness window. Each test asserts the non-owner revert, the zero-guard (where applicable), and the re-point
  effect (the new pair prices, the old reverts `NotSupported`) — closing the subsystem's recurring setter-gap class.
- **The shared-`scale` 18-dp key invariant is now enforced on BOTH key-entry paths.** `scale` is
  derived once from the `LP_DECIMALS = 18` constant and is NOT re-derived against the key, so a non-18-dp `lpToken`
  would silently mis-scale every quote (over-value for >18dp — the dangerous direction). The ctor and `setLpToken`
  now strict-read `lpToken.decimals()` (`_strictLpDecimals`, reverts `InvalidLpDecimals` on a non-18 / code-less /
  failed-call key — NOT silent-18 like `BaseAdapter._getDecimals`), mirroring the load-bearing
  `ZipcodeOracleRegistry._strictDecimals` guard this contract had previously dropped on the re-point path the
  registry doesn't even expose. The trustless twin is structurally immune (its `lpToken` is `immutable`).
- **`reportType` collision residual (I-3, documented).** `LP_MARK = 7` is a §8 placeholder distinct from the
  registry's `REVALUATION = 3`; CRE-§8 ratifies it later (the 8-B5 cross-ticket obligation). Not a code bug; a
  process residual to confirm the wire-level reportType is final pre-prod.
- **No custody, no upgrade surface beyond the Timelock setters** — the contract holds only the cache + wiring;
  Ownable is transferred to the §17 Timelock at deploy (not renounced, by design, until pre-prod freeze).

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Dedicated unit (SEC-01 write-staleness) | 4 | `test_SEC01_lp_firstWrite_succeeds` / `_backdated_mark_reverts` / `_equalTs_reverts` / `_strictlyNewer_succeeds` |
| Read path (unsupported / unset / stale + boundary / quote value + rounds-down) | 5 | `test_getQuote_unsupportedPair_reverts` / `_unsetCache_reverts` / `_stale_reverts` / `_value_and_roundsDown` |
| Write guards (forwarder / reportType / mark / overflow / future-ts) | 5 | `test_onReport_nonForwarder_reverts` / `_processReport_wrongType_reverts` / `_writePrice_zeroMark` / `_overflowMark` / `_futureTs` |
| Setters + ctor guards | 8 | `test_setQuote/_setLpToken/_setValidityWindow_guards_and_effect` + `test_setLpToken_non18Decimals/_codeless_reverts` + `test_ctor_zeroQuote/_zeroLpToken/_non18LpToken/_zeroForwarder` |
| Fork / fuzz / invariant | 0 | not needed — pure cache + scalar conversion; the CRE/EVK integration is covered in the consumer suites |

Coverage % uninstrumentable (project-wide `Stack too deep`); **22/22 green** (4 SEC-01 + 15 + 3 strict-18-dp). All 8
invariant clusters are now covered. The contract mirrors the well-tested `ZipcodeOracleRegistry` /
`SzAlphaRateOracle` pattern and now carries a full dedicated suite for its own surface.

## X-Ray Verdict

**ADEQUATE** — a well-constructed, pattern-proven CRE-fed push-cache LP oracle (the deploy-default twin of the
trustless `AlgebraIchiFairLpOracle`), with correct fail-closed semantics now **proven across its full surface**
(22/22): the read-path liveness contract (unset/stale/unsupported fail-closed — the property the design exists to
provide, incl. the `s==window` boundary), the SEC-01 strictly-newer write guard, the other write-value guards
(`mark==0` / overflow / future-ts), the reportType pin, the forwarder gate, and the three Timelock setters + ctor
zero-guards. The logic is the same shape as the audited registry, and its own surface is now fully exercised. Held
below HARDENED only by the build-phase mutable wiring (to be frozen pre-prod, the subsystem-wide residual), the
inherited CRE/Forwarder trust, and no external audit.

**Structural facts:**
1. 80 nSLOC; `ReceiverTemplate` (CRE receiver) + `BaseAdapter` (EVK `IPriceOracle`); single fixed key `(lpToken, USDC)`, `LP_MARK = 7`, no controller-seed (Forwarder is the only writer).
2. Push-cache: CRE pushes a per-LP-share USD mark via `onReport`→`_processReport`→`_writePrice`; `getQuote` reads it, **rounded DOWN**, fail-closed on unset/stale.
3. The deploy default (`DeployZipcode` P5, `lpTwapWindow == 0`); `AlgebraIchiFairLpOracle` is the opt-in trustless alternative. Trades manipulation-resistance for a **liveness dependency** — stale ⇒ borrow fails closed.
4. Wiring is Timelock-settable, not immutable (`setQuote` re-derives `scale`, `setLpToken`, `setValidityWindow`); Ownable → §17 Timelock at deploy, frozen pre-prod.
5. Tests: 22/22 — 4 SEC-01 write-staleness + 15 (read path I-5/I-6, write-value guards I-3/I-4, forwarder gate I-2, setters/ctor I-7/I-8) + 3 strict-18-dp `lpToken` guard on ctor + `setLpToken`. All 8 invariant clusters covered; no outstanding in-file coverage gap.
