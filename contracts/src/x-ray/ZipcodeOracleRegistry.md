# X-Ray — `ZipcodeOracleRegistry.sol` (single-contract, test-connected)

> ZipcodeOracleRegistry | 97 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)*

> **Update 2026-06-20:** the I-11 gap is **CLOSED** — `test_I11_setQuote_guards_and_effect` (onlyOwner + `ZeroAddress`
> + re-point/`WiringSet` + new-pair-prices/old-reverts) and `test_I11_setValidityWindow_guards_and_effect` (onlyOwner
> + the observable staleness tighten) cover the two previously-untested setters. 40/40 green. Verdict lifted to
> HARDENED. (Note: `setQuote`'s `scale` is numerically decimals-invariant by construction — `feedDecimals ==
> quoteDecimals` collapses it to `/1e18` — so the re-derive is proven by "the new quote prices without bricking",
> not a value delta.)

Per-contract X-Ray for `contracts/src/ZipcodeOracleRegistry.sol`, the **multi-asset Proof-of-Value push-cache** that
prices every lien token at its appraised-value-minus-senior-debt mark. The EVK read-adapter
(`BaseAdapter`/`IPriceOracle`) and CRE receiver (`ReceiverTemplate`) in one contract — the multi-asset sibling of
`SzipFarmUtilityLpOracle`. Exercised by `ZipcodeOracleRegistry.t.sol` — a **40-test** suite. This is the LAST loose
top-level contract in `src/`.

> Two write paths feed one venue-neutral cache: a **controller-gated origination seed** (`seedPrice`, single lien,
> atomic inside the controller's batch) and a **Forwarder-gated revaluation** (`_processReport`, reportType 3,
> all-or-nothing batch). One stale-checked `_getQuote` serves it. The defining choices: (1) **one shared `scale`**
> (`baseDecimals=18`), which makes the strict 18-dp key guard load-bearing — a non-18-dp lien is UNREACHABLE by
> design; (2) **all-or-nothing revaluation** — a single poison key reverts the whole report (no partial revaluation),
> with blast radius bounded off-chain by sharding; (3) **no on-chain value band** — integrity is upstream (Proof +
> DON consensus + the Timelock-pinned Forwarder), so even a big mark drop is accepted (it's a real revaluation).

## 1. What it is

A 97-nSLOC dual `ReceiverTemplate, BaseAdapter`. Per-lien `Cache{price, timestamp}` keyed on the lien address; three
Timelock-settable slots (`controller`, `quote`, `validityWindow`) + the derived `scale`.

- **`seedPrice(lien, price)`** — `controller`-only; one mark, `ts = now`; → `_writePrice` + event.
- **`_processReport`** (reportType `REVALUATION=3`) — Forwarder-gated batch: length-match → loop `_writePrice`; all-or-nothing.
- **`_writePrice`** (shared guards) — `price != 0` (`InvalidAnswer`), `price <= uint208.max` (`Overflow`), `ts <= now` (`FutureTimestamp`), `ts` strictly newer than cached (`StaleReport`, SEC-01), `_strictDecimals(lien) == 18` (`InvalidLienDecimals`).
- **`_getQuote`** — only `(lien, quote)`; unset cache / wrong quote → `NotSupported`; `now-ts > validityWindow` → `TooStale`; else `calcOutAmount(..., false)` (rounds down).
- **setters** — `setController`/`setQuote` (re-derives `scale`)/`setValidityWindow`, all `onlyOwner`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `seedPrice(lien, price)` | `controller`-only | `NotController`; origination seed |
| `onReport` → `_processReport` | Forwarder-gated | reportType 3 batch; all-or-nothing |
| `getQuote / getQuotes` → `_getQuote` | public view | only `(lien, quote)`; fail-closed on unset/stale; forward-only |
| `setController` / `setQuote` / `setValidityWindow` | `onlyOwner` (Timelock) | re-points; `setQuote` re-derives `scale` |
| `constructor(forwarder, quote_, validityWindow_)` | deploy | derives `scale` |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **scale: value identity + rounds DOWN + jumbo-no-overflow** | Yes | **`test_ScaleValueIdentity`**, `_ScaleTruncationFloor`, `_JumboNoOverflow` |
| I-2 | **seedPrice controller-gated + event + reseed overwrite** | Yes | **`test_SeedAuthorityAndEvent`**, `_ReseedOverwrite` |
| I-3 | **revaluation all-or-nothing batch** — Forwarder-gated, reportType 3, length-match, empty-ok, a duplicate lien in-batch reverts the whole report (`StaleReport`) | Yes | **`test_RevaluationForwarderPath`**, `_ForwarderGate`, `_InvalidReportTypes`, `_LengthMismatch`, `_EmptyBatchNoRevert`, `_DuplicateLiensInBatchRevertStale`, `_RevaluationOverwritesSeed` |
| I-4 | **write value guards** — `price==0`→`InvalidAnswer`; `>uint208.max`→`Overflow`; `ts>now`→`FutureTimestamp` — on BOTH seed + reval; the uint208 boundary succeeds | Yes | **`test_WriteGuard_ZeroPrice_{Seed,Reval}`**, `_Overflow_{Seed,Reval}`, `_Uint208Boundary_Succeeds_{Seed,Reval}`, `_FutureTimestamp_Reval` |
| I-5 | **strict 18-dp key guard** — a 6-dp lien and a code-less EOA both reject (`InvalidLienDecimals`), on BOTH paths | Yes | **`test_StrictDecimals_6dp_Rejected_{Seed,Reval}`**, `_EOA_Rejected_{Seed,Reval}` |
| I-6 | **SEC-01 strictly-newer** — seed equal-ts, reval backdated, reval equal-ts all revert `StaleReport`; strictly-newer succeeds | Yes | **`test_SEC01_seedPrice_equalTs_reverts`**, `_reval_backdated_reverts`, `_reval_equalTs_reverts`, `_strictlyNewer_succeeds` |
| I-7 | **read guards** — unset cache / wrong quote → `NotSupported`; `s > window` → `TooStale(s, window)`; boundary `s == window` still fresh | Yes | **`test_ReadGuard_UncachedNotSupported`**, `_WrongQuoteNotSupported`, `_TooStale_ExactArgs`, `_BoundaryStillFresh` |
| I-8 | **no on-chain value band** — a big mark drop is accepted (integrity is upstream) | Yes | **`test_NoValueBand_BigDrop_Succeeds`** |
| I-9 | **identity / renounce** — wrong workflowId reverts pre-renounce; renounce freezes setters but the identity gate stays live; renounced-without-controller → seed forever reverts; forwarder immutable after renounce | Yes | **`test_IdentityGate_WrongWorkflowId_BeforeRenounce`**, `_Renounce_FreezesSettersButIdentityStaysLive`, `_RenouncedWithoutController_SeedForeverReverts`, `_ForwarderImmutableAfterRenounce` |
| I-10 | **`setController` onlyOwner + `ZeroAddress` + effect + event + re-point** | Yes | **`test_SetControllerRepoint`** |
| I-11 | **`setQuote` (onlyOwner + `ZeroAddress` + `scale` re-derive) and `setValidityWindow` (onlyOwner + effect)** | Yes | **`test_I11_setQuote_guards_and_effect`** (onlyOwner / zero / re-point+`WiringSet` / new-pair-prices / old-quote-`NotSupported`) + **`test_I11_setValidityWindow_guards_and_effect`** (onlyOwner / tighten→`TooStale`) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `NotController` (seed) | `:114` | `test_SeedAuthorityAndEvent` |
| `InvalidReportType` / `LengthMismatch` | `:130,133` | `test_InvalidReportTypes`, `_LengthMismatch` |
| `InvalidAnswer` / `Overflow` / `FutureTimestamp` / `StaleReport` | `_writePrice:142-145` | `test_WriteGuard_*`, `_SEC01_*` |
| `InvalidLienDecimals` (strict, both paths) | `_strictDecimals:154` | `test_StrictDecimals_*` |
| `NotSupported` (wrong quote / unset) / `TooStale` | `_getQuote:172-177` | `test_ReadGuard_*` |
| Forwarder / identity gate | `ReceiverTemplate` | `test_ForwarderGate`, `_IdentityGate_*`, `_Renounce_*` |
| `setController` onlyOwner + `ZeroAddress` | `:89-90` | `test_SetControllerRepoint` |
| `setQuote` onlyOwner + `ZeroAddress`; `setValidityWindow` onlyOwner | `:96-97,:105` | `test_I11_setQuote_guards_and_effect`, `_setValidityWindow_guards_and_effect` |

Every write path, read path, value/decimals/staleness guard, the identity/renounce surface, and all three setters
are now exercised — no untested surface.

## 5. Attack surfaces

- **The shared-scale + strict-18-dp invariant is the load-bearing design — and it's proven (I-1/I-5).** There is ONE
  `scale` (derived with `baseDecimals=18`), so a non-18-dp lien would be silently mis-scaled; `_strictDecimals`
  rejects any key whose `decimals() != 18` (and a code-less EOA), on both write paths. The NatSpec warns never to
  relax the 18-dp guard without per-key scaling — the tests pin both the rejection and the scale math (incl.
  rounds-down + jumbo-no-overflow).
- **All-or-nothing revaluation is intentional fail-closed (I-3).** A single poison key (zero/overflow price,
  future/stale ts, off-decimal) reverts the whole reportType-3 batch — proven via the duplicate-lien-in-batch test
  (the second write hits `StaleReport` and rolls back the batch). A per-key try/catch would weaken this and is
  deliberately omitted; blast radius is bounded off-chain by the producer's sharding + the long validity window.
- **SEC-01 strictly-newer is the replay/clobber defense (I-6).** A backdated or equal-ts write (seed or reval)
  reverts `StaleReport`, covering both a seed-clobber and out-of-order reportType-3 — the value-only guards can't
  catch a same-price replay, so the monotonic-ts check is load-bearing and tested four ways.
- **No on-chain value band is a deliberate design point (I-8), tested.** Integrity is upstream (Proof + DON + the
  Timelock-pinned Forwarder), so a big mark drop is accepted as a real revaluation — `test_NoValueBand_BigDrop`
  confirms the registry adds no plausibility band. The read path fails closed on staleness/unset instead.
- **Identity/renounce surface is dense (I-9).** Wrong-workflowId rejection pre-renounce, setters frozen but identity
  gate still live post-renounce, the seed-forever-reverts brick if renounced without a controller, and forwarder
  immutability — all tested. This is the dormant-identity hazard `ZipcodeDeployAsserts` guards at deploy time.
- **`setQuote`/`setValidityWindow` (I-11) — CLOSED.** Both are now swept: `setQuote` (onlyOwner / `ZeroAddress` /
  re-point + `WiringSet` / the new pair prices via the re-derived scale / the old quote reverts `NotSupported`) and
  `setValidityWindow` (onlyOwner / tighten the window so a previously-fresh mark reads `TooStale`). `setQuote`'s
  `scale` is numerically decimals-invariant by construction (`feedDecimals == quoteDecimals` ⇒ `/1e18`), so the
  re-derive is proven by "the new quote prices correctly without bricking/overflow" rather than a value delta — the
  same load-bearing re-derive as `SzipFarmUtilityLpOracle.setQuote`, now pinned.
- **Inherent trust:** the CRE Forwarder/identity, the upstream Proof-of-Value producer, and the EVK `ScaleUtils` math
  are trusted; build-phase mutable wiring (frozen pre-prod) is the subsystem residual.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Scale / value | 4 | deploy+name, value identity, truncation floor, jumbo-no-overflow |
| seedPrice + revaluation paths | 9 | authority/event, reseed, forwarder path/gate, reportType, length, empty, duplicate-stale, reval-overwrites-seed |
| Write guards (value + strict decimals) | 11 | zero/overflow/uint208-boundary/future-ts (seed+reval) + 6dp/EOA strict-decimals (seed+reval) |
| Read guards + no-value-band | 5 | uncached, wrong-quote, too-stale exact-args, boundary-fresh, big-drop |
| Identity / renounce | 4 | wrong-id, renounce-freezes, renounced-no-controller, forwarder-immutable |
| SEC-01 strictly-newer | 4 | seed equal-ts, reval backdated/equal-ts, strictly-newer |
| `setController` / `setQuote` / `setValidityWindow` | 3 | onlyOwner + zero + effect/event across all three setters |

Coverage % uninstrumentable (project-wide `Stack too deep`); **40 tests green**. The two write paths, the read path,
every value/decimals/staleness guard, SEC-01, the identity/renounce surface, and all three setters are exhaustively
covered — no coverage gap.

## X-Ray Verdict

**HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)* — the multi-asset Proof-of-Value
push-cache, with its decisive surfaces exhaustively proven: the shared-scale + strict-18-dp key invariant (a
non-18-dp lien is unreachable), the all-or-nothing fail-closed revaluation, SEC-01 strictly-newer replay defense, the
full write/read guard matrix (zero/overflow/future-ts/strict-decimals/unset/wrong-quote/too-stale + the staleness
boundary), the deliberate no-value-band, the identity/renounce surface, and — now closed (I-11) — all three Timelock
setters incl. `setQuote`'s scale re-derive. No code or coverage gap remains; the only residuals are the deferred
pre-prod immutable re-freeze of the build-phase wiring (`onlyOwner` + zero-guarded) and the absence of an external
audit.

**Structural facts:**
1. 97 nSLOC; dual `ReceiverTemplate` + `BaseAdapter`; per-lien push-cache; two write paths (controller seed + Forwarder reportType-3 batch) → one stale-checked read.
2. One shared `scale` (`baseDecimals=18`) + strict-18-dp key guard make a non-18-dp lien unreachable by design (load-bearing; never relax in isolation).
3. All-or-nothing revaluation (a poison key reverts the batch); SEC-01 strictly-newer ts (replay/clobber defense); no on-chain value band (integrity is upstream).
4. Forward-only `_getQuote` (only `(lien, quote)`; reverse pair fails closed); fail-closed on unset/stale.
5. Tests: 40 (scale, both write paths, full guard matrix, SEC-01, read guards, identity/renounce, all three setters incl. `setQuote` scale re-derive). No coverage gap; capped only by the pre-prod re-freeze + no audit.
