# 8x-02 — SzAlphaRateOracle + cre/szalpha-rate (wiring map)

> Source of truth = the kept code: `contracts/src/bridge/SzAlphaRateOracle.sol`,
> `contracts/src/interfaces/bridge/IXAlphaRate.sol`, the consumer wiring in
> `contracts/src/supply/SzipNavOracle.sol`, and the CRE workflow `cre/szalpha-rate/{main.go,README.md}`.
> Ticket `tickets/bridge/8x-02-xalpha-apr-cre.md` + report `reports/8x-02-report.md` are intent — the
> code is the final form (REDESIGNED ×2; the v1 push-APR receiver and the v2 964-native `XAlphaAprOracle`
> were DELETED, v3 below is what shipped).

## Role
The one fact that lives **only** on Bittensor is xALPHA's exchange rate — `staked alpha ÷ supply`, read from the
StakingV2 precompile `0x805`, native to **Subtensor EVM (964)**. The bridged Base mirror (`SzAlphaMirror`) is a
plain `BurnMintERC20` with **no stake surface**, so the rate cannot be read on Base. A CRE workflow
(`cre/szalpha-rate/`) therefore **pulls that single primitive from 964 and pushes it RAW to Base** — `reportType
RATE = 8`, payload `abi.encode(uint256 rate, uint48 ts)`. `SzAlphaRateOracle` is the Base landing site: it caches
the last pushed rate and **the chain derives the rest** (NAV and the intrinsic APR are computed on Base from the
rate — never pushed pre-computed, never bridged). The principle is **CRE transports the primitive, the chain
derives NAV + APR** (`claude-zipcode.md` §8.6/§8.8; the §8.0 envelope table carries the `8` RATE / `SzAlphaRateOracle`
row at `claude-zipcode.md:1505`).

## Contracts involved (what each does)
| Contract / artifact | What it does |
|---|---|
| `SzAlphaRateOracle` (`is ReceiverTemplate, IXAlphaRate`) | The Base-side rate cache + `IXAlphaRate` drop-in. `_processReport` decodes the `RATE = 8` push `(uint256 rate, uint48 ts)`, guards it (non-zero / not-future / strictly-newer), stores `latest`, and rolls the two APR checkpoints. Exposes `exchangeRate()` / `lastUpdate()` / `fresh()` (consumer surface) + `intrinsicAprBps()` (derived advisory view). Forwarder-gated; `maxStaleness`/`window`/`aprCap` are deploy-time immutables. |
| `cre/szalpha-rate/main.go` (`SzAlphaRateWorkflow`) | The CRE-03 cron pull. Reads `IXAlphaRate.exchangeRate()` on `SzAlpha` (964) + the read-block timestamp, packs `(uint256 rate, uint48 ts)`, wraps it in the `(uint8 RATE=8, bytes)` envelope, `GenerateReport` (ecdsa/keccak256), and `WriteReport` to `SzAlphaRateOracle` on Base. Does **no** math. Not compiled in the Foundry repo (no Go toolchain) — the contract-coupled parts (the two ABI packings) are pinned byte-exact, the 964 read + go.mod/RPC/config are CRE-03 (`main.go:9-20`, `readExchangeRate` is the only stub). |

## Wiring — internal
- **`is ReceiverTemplate, IXAlphaRate`** (`SzAlphaRateOracle.sol:22`). The base `ReceiverTemplate` gives the
  Forwarder-gated `onReport` → `_processReport` path and an `Ownable(msg.sender)` owner; this contract overrides
  `_processReport` and implements the `IXAlphaRate.exchangeRate()` face. `RATE = 8` is `(receiver, reportType)`-scoped
  (`:24-26`) — it does **not** collide with `DefaultCoordinator`'s `8`, since each `WriteReport` names one receiver.
- **The push (`_processReport`, `:80-103`).** Decodes the envelope `(uint8 reportType, bytes payload)`, requires
  `reportType == RATE` (`InvalidReportType`), decodes `payload` to `(uint256 rate, uint48 ts)`, then the three
  guards: `rate != 0` (`ZeroRate`), `ts <= block.timestamp` (`FutureTimestamp`), `ts > latest.ts`
  (`StaleReport` — strictly newer, no replay / out-of-order). **No deviation band by design** (`:87-89`): the rate is
  ground truth from 964 and a validator slash legitimately lowers it, so a band would either brick a real move or
  need a bypass; DON f+1 consensus catches a misread, `fresh()` catches a frozen feed.
- **Checkpoint roll (the derived-APR machinery, `:91-99`).** `curAnchor` seeds on the first push; once a push is
  `>= window` newer than `curAnchor`, the matured `curAnchor` retires to `prevAnchor` and `curAnchor` resets
  (`rolled = true` in the `RatePushed` event). `latest` updates every push.
- **`exchangeRate()` (`:109-111`).** Returns `latest.rate` — the Base-side `IXAlphaRate`. The drop-in for
  `SzipNavOracle`'s xALPHA NAV leg and any Euler price-oracle adapter.
- **`fresh()` / `lastUpdate()` (`:114-121`).** `lastUpdate()` = `latest.ts` (`0` ⇒ never pushed). `fresh()` is true
  iff a rate has been pushed **and** it is within `maxStaleness`. This is the consumer's fail-closed gate — a rate
  that moves NAV must not be served stale; the oracle **exposes** freshness, it does not silently serve old.
- **`intrinsicAprBps()` (DERIVED view, `:128-141`).** `(rate_now / rate_prev − 1) × year / Δ` over the trailing
  checkpoint (`prevAnchor`, else `curAnchor`). **Floored at 0** (slash/decline/flat ⇒ `0`, never negative — return
  type is `uint32`), **clamped to `aprCap`**, `0` until a trailing checkpoint exists. Never reverts; **advisory only**
  — NAV does NOT consume it (NAV reads `exchangeRate()` directly). The annualization is **one expression**
  (`(rNow − rPrev) * BPS * SECONDS_PER_YEAR / (rPrev * dt)`): a two-step `growthBps`-then-annualize truncates real
  sub-bps per-tempo Bittensor growth to `0` (the bug the live netuid-64 data caught; the single expression recovers
  the true ~11.4% — `test_derives_real_validator_short_window`).
- **Constructor guards (`:66-75`).** `ReceiverTemplate(forwarder)` reverts `InvalidForwarderAddress` on zero;
  `maxStaleness != 0` (`ZeroMaxStaleness`), `window != 0` (`ZeroWindow`), `aprCap != 0 && aprCap <= type(uint32).max`
  (`InvalidAprCap`). Deploy fixtures (per the test): `maxStaleness 6h`, `window 30d`, `aprCap 50_000` (500%).

## Wiring — cross-component (who points at whom)
This window **resolves the §8.6 cross-chain rate seam** — `SzipNavOracle`'s xALPHA rate now has a defined producer
(`SzAlphaRateOracle`). The consumer side is already wired in the kept `SzipNavOracle` code (PROGRESS row 329 split):

- **The rate/balance split (`SzipNavOracle.sol`).** `xAlpha` (immutable, `:61`) stays the **balance token** — the
  basket holds the `SzAlphaMirror`, read as `IERC20(xAlpha).balanceOf(...)` for the basket weight (`:276/:315`). A
  **separate** `xAlphaRateOracle` address (`:88`, Timelock-settable via `setXAlphaRateOracle`, `:211-213`,
  `onlyOwner`, `XAlphaRateOracleSet` event) supplies the **rate**. This is NOT a re-point of one immutable address —
  the mirror has no `exchangeRate()` and the rate oracle has no `balanceOf`, so the two sources are distinct by
  construction (the PROGRESS row-329 correction to the naive "token stays the mirror, rate re-points" framing).
- **The rate read (`_xAlphaUSD`, `:405-410`).** `rateSrc = xAlphaRateOracle == address(0) ? xAlpha : xAlphaRateOracle`
  — when the oracle is wired it reads `IXAlphaRate(rateSrc).exchangeRate()`; when unset (M1) it falls back to reading
  the xALPHA stand-in directly (same `IXAlphaRate` surface). **Value, not freshness**, is read here, so
  `grossBasketValue`/`navExit` keep pricing off the last good rate (the §7 issuance/exit asymmetry).
- **The freshness gate (additive, fund-safety).** A local `IXAlphaRateFresh` face (`:11-13`) gates `fresh()`. When
  `xAlphaRateOracle != address(0)`, **issuance** fails closed on a stale cross-chain rate: `navEntry()` reverts
  `StaleRate` (`:373`) and `fresh()` returns false (`:389`). **Exit is unaffected** — `navExit()` does not call the
  gate (`:380-384`). Unwired (`address(0)`) ⇒ the M1 path is byte-unchanged (the NAV suite passes intact). This
  discharges the §8.6 R-2 fund-safety risk (a stale pushed rate can no longer silently mint mis-marked NAV).

## Item-10 deploy facts
- **Deploy `SzAlphaRateOracle` on Base** as a `ReceiverTemplate`: constructor `(forwarder, maxStaleness, window,
  aprCap)` with `forwarder = CRE_KEYSTONE_FORWARDER` (the WOOF-00 `BaseAddresses` pin) and the knob fixtures
  (`6h / 30d / 50_000`). The S10b/S11 Forwarder + owner-identity gate applies (`is ReceiverTemplate`: owner =
  `Ownable(msg.sender)`; `setForwarderAddress` is owner-only and is the documented footgun — `setForwarderAddress(0)`
  disables the sender check). Owner → Timelock per the build-phase doctrine ([[oracle-replaceable-timelock-wiring]]);
  the knobs are immutable, so there is no per-knob setter to hold.
- **Wire the consumer.** Either call `SzipNavOracle.setXAlphaRateOracle(<rateOracle>)` (Timelock, the additive seam
  already in the kept code), **or** redeploy the NavOracle clone with the rate oracle wired (the oracle is a clone —
  cheap, and oracles are designed replaceable, PROGRESS row 329). The `xAlpha` balance token is **not** changed (it
  stays the mirror).
- **Deploy the CRE workflow.** Run `cre/szalpha-rate/` on the CRE DON as the hourly rate pull (cadence
  `0 0 * * * *` ⇒ the `maxStaleness 6h` bound). Until 8x-01's lane is live, point the 964 read at the 18-dp xALPHA
  stand-in (same `IXAlphaRate` surface). Residual = confirm CRE has a 964 chain selector + RPC (the read **pattern**
  is proven; `SzAlpha.exchangeRate()` low-level-staticcalls `0x805`).

## Gotchas
- **v3 is final; v1 and v2 are DELETED.** The v1 push-cache (a Forwarder-gated receiver that received a
  **pre-computed APR** + defended it with an adversarial deviation band) and the v2 964-native `XAlphaAprOracle`
  (right principle — derive — wrong chain: the consumers are Base-side) were both removed. v3 = **Base + rate-only +
  APR-derived**. Do not resurrect a pushed APR or a deviation band.
- **Slash ⇒ rate down ⇒ APR 0, not brick.** A downward rate push lands (no band rejects it); `intrinsicAprBps()`
  returns `0` (floored), `exchangeRate()` serves the lower rate, `fresh()` stays true
  (`test_apr_slash_is_zero_not_negative`). The feed never bricks on a legitimate decline.
- **`intrinsicAprBps()` gates no funds.** It is consumed by the depositor UI / 8-B12 monitoring / the 8-B11 regime
  gate only — advisory. NAV consumes `exchangeRate()` directly; the APR is never pushed or bridged.
- **The Go workflow is an integration artifact, not a compiled deliverable.** Only the two ABI packings are
  load-bearing-pinned (`encodeRatePayload` = `(uint256 rate, uint48 ts)`, `encodeEnvelope` = `(uint8 RATE=8, bytes)`,
  byte-matching `_processReport`). `readExchangeRate` is a stub gated on R-1 (CRE-964 reachability) — tracked in the
  ticket's OPEN/BLOCKING table, not buried in code.
