# 8x-02 — xALPHA exchange-rate Base oracle + derived APR (`SzAlphaRateOracle`)

> **FINAL SHAPE 2026-06-09 (user-directed) — CRE pulls the RATE to Base; the chain derives the rest.** The real
> deliverable is **a Base oracle that holds the xALPHA `exchangeRate`** so `SzipNavOracle` / the Euler price-oracle
> adapter can read it (and the APR derives on top). The arc that got here: v1 pushed a pre-computed APR (defended by
> adversarial bands — over-built; the band spawned the slash-brick knot it then "solved"); v2 tried to derive
> natively on 964 (right principle, wrong chain — the protocol + consumers are Base-side). **v3 (this):** the ONE
> fact that lives only on Bittensor is the **rate** (`staked/supply`, StakingV2 `0x805`, native to **964**; the Base
> mirror has no stake surface). A CRE workflow (`cre/szalpha-rate/`) **pulls that one primitive from 964 and pushes
> it RAW to `SzAlphaRateOracle` on Base** (`reportType RATE = 8`, payload `(uint256 rate, uint48 ts)`). **CRE
> transports the primitive; the chain derives NAV + APR from it** — nothing pre-computed is ever pushed/bridged.
>
> **`SzAlphaRateOracle` (Base) is the Base-side `IXAlphaRate`:** `exchangeRate()` (last pushed) + `fresh()` /
> `lastUpdate()`. Push guards are truthful not adversarial — non-zero, not-future, **strictly-newer** (no
> replay/out-of-order); **no deviation band** (a slash legitimately lowers the rate); consumers **fail-closed on
> staleness** via `fresh()` (a rate that moves NAV must not serve stale). The intrinsic **APR is a DERIVED view**
> on the pushed rate's history (`intrinsicAprBps()`, floored-0/cap-clamped) — advisory, gates no funds. **This
> resolves the §8.6 cross-chain rate seam:** the rate `SzipNavOracle`'s xALPHA leg needs on Base now has a producer.
>
> **Sequencing.** M1 but **not on the contract-spine critical path** — depends on 8x-01 (`SzAlpha`/`IXAlphaRate`).
> The **post-M1 szipUSD incentive APR overlay** (§6) is explicitly **out of scope** here (treasury economics).

---

## OPEN / BLOCKING RISKS (NOT buried — every TODO in the code lives here)

These are the things this window did **not** close. They are tracked here, in the ticket, not hidden in code
comments. The contract (`SzAlphaRateOracle`) is forge-green; that does not mean the feed works end-to-end.

| # | Risk | Severity | Where it bites | Status |
|---|---|---|---|---|
| **R-1** | **Can CRE READ 964?** — NARROWED after reading `SzAlpha` (was overstated as "the precompile call won't work"). `SzAlpha.exchangeRate()` (`SzAlpha.sol:201`) does NOT make a typed precompile call — it already uses the **workaround**: low-level `STAKING_V2.staticcall(abi.encodeWithSelector(getStake...))` (`SzAlpha.sol:308-309`), the pattern that DOES reach the runtime (the "8x exception" `ISubtensorPrecompiles.sol:13` / `reference/evm-bittensor/solidity/stakeV2.sol:46` is about *typed* calls, which `SzAlpha` avoids). So an `eth_call` to `exchangeRate()` works on-chain. **Residual = a config/support question, not impossibility:** is 964 a CRE-supported chain (selector + DON RPC access), and does the DON's `eth_call` against the 964 node execute the staticcall. | **CONFIG-VERIFY** (downgraded from BLOCKING) | the pull needs 964 read access | **VERIFY at CRE-03:** confirm CRE supports a 964 chain selector + has a 964 RPC, and a test `eth_call` to live `SzAlpha.exchangeRate()` returns. The read pattern itself is proven (the wrapper uses it). |
| **R-2** | **The fund-moving consumer is not safe yet.** `SzipNavOracle._xAlphaUSD()` reads `IXAlphaRate(xAlpha).exchangeRate()` with **NO freshness check** today (it trusts the M1 stand-in). Pointed at this PUSHED oracle, a stale-or-zero rate silently mis-marks the xALPHA NAV leg — which gates issuance/exit. "Resolves the §8.6 seam" is only half-true until this is fixed. | **HIGH (fund-safety)** | NAV mis-mark → wrong issuance/exit price | **OPEN.** Fix: `SzipNavOracle` consumes `SzAlphaRateOracle` for the rate (token addr stays the mirror for `balanceOf`) AND gates the rate read on `fresh()` (revert issuance / fall back to TWAP on stale). Touches the 42-pinned `SzipNavOracle` suite ⇒ its own focused change, NOT a silent item-10 line. |
| **R-3** | **Standalone oracle vs. a leg in the existing NAV push — a chosen tradeoff, stated.** `SzipNavOracle` already has a CRE Forwarder push (`NAV_LEG=7`) + already reads the rate. The rate COULD be one more leg in that push instead of a new contract+reportType+workflow. **Chose standalone** for single-responsibility + independent reuse (an Euler adapter can read just the rate). Revisit if the extra surface isn't worth it. | LOW (design) | — | **DECIDED (standalone), documented.** |
| **R-4** | **CRE-03 wiring checklist** (the ex-`TODO(CRE-03)` from `cre/szalpha-rate/main.go`, enumerated): (a) `go.mod` pinning `cre-sdk-go`; (b) the 964 + 8453 chain selectors + RPCs in `project.yaml`; (c) config unmarshal; (d) the exact 964 `exchangeRate()` read (gated by R-1). | MED | the workflow can't run until done | **OPEN, tracked (was buried in code).** |

## The yield, mechanically (why the formula is what it is)

`SzAlpha` (8x-01) is a **pooled staker**: all deposited alpha is staked under **one validator hotkey + the wrapper's
own coldkey** on our subnet. Bittensor dTAO pays validator **dividends in alpha that auto-compound into the staked
balance** — no claim step. So per epoch, absent deposits/redeems:

```
totalStaked_{t+1} = totalStaked_t + dividends_to_our_stake_t      // alpha, compounding
exchangeRate()    = totalStaked / circulatingSupply               // alpha per xALPHA, 18-dp (IXAlphaRate)
```

`deposit`/`redeem` mint/burn at the prevailing rate (NAV-neutral, 8x-01 §1 round-down), so they move `totalStaked`
and `circulatingSupply` **together** and leave `exchangeRate()` unchanged. **Therefore every move in `exchangeRate()`
is validator dividends** — a clean realized-yield accumulator, no pool price in the path.

**Key simplification — circulating supply cancels out of the APR.** APR is a growth *rate* (`Δstake / stake`); supply
sits in both the NAV numerator and denominator, so it drops. **Total circulating xALPHA (964 + Base) is needed for the
per-token NAV/USD *value* and for the post-M1 incentive *denominator* (§6) — not for the intrinsic yield ratio.** This
is why the published number (Deliverable 2, §primary) reads **one chain only** and is immune to the cross-chain
supply-accounting seam (§safety).

---

## Build prerequisite — CRE/Subtensor read self-check (the "8x exception", WOOF-00 EXTENDED)

Before writing workflow logic: confirm the workflow can read (a) `IXAlphaRate.exchangeRate()` on the deployed
`SzAlpha` over the 964 RPC, and (b) the metagraph precompile `0x802` (`getEmission`/`getDividends`/`getHotkey`/
`getValidatorStatus`/`getUidCount`). Wire the Subtensor EVM fork RPC + chainId into the CRE config / `.env.example`;
if no public Subtensor fork node is available, the precompile reads are **mocked and the test name/log says MOCK** —
state the chosen fallback in the report. (Mirrors 8x-01's fork-real-vs-mock gate.)

---

## Deliverable

One contract — `contracts/src/bridge/SzAlphaRateOracle.sol` — deployed on **Base**, + the CRE workflow
`cre/szalpha-rate/` that feeds it. `forge`-tested with a mock-EOA Forwarder pushing the rate.

### The contract — `SzAlphaRateOracle is ReceiverTemplate, IXAlphaRate` (Base)
- **The push.** `_processReport` decodes the §8.0 envelope `abi.encode(uint8 reportType, bytes payload)`,
  `require(reportType == RATE)` (`RATE = 8`, `(receiver,reportType)`-scoped — non-colliding with
  `DefaultCoordinator`'s `8`), then `abi.decode(payload, (uint256 rate, uint48 ts))`. Guards: `rate != 0`
  (`ZeroRate`), `ts <= block.timestamp` (`FutureTimestamp`), **`ts > latest.ts`** (`StaleReport` — strictly newer,
  no replay/out-of-order). **No deviation band** (the rate is ground truth from 964; a slash legitimately lowers
  it). Maintains two rolling checkpoints for the derived APR (`curAnchor` → `prevAnchor` once `window` old).
- **The deliverable — Base `IXAlphaRate`.** `exchangeRate() returns (uint256)` (the last pushed rate; the drop-in
  `SzipNavOracle`'s xALPHA leg + an Euler adapter read), `lastUpdate()`, `fresh()` (within `maxStaleness`). A rate
  that moves NAV **must** be gated on `fresh()` by the consumer (fail-closed on a stale push).
- **The APR — DERIVED view.** `intrinsicAprBps()` = `(rate_now/rate_prev − 1) × year/Δ` over the checkpoints,
  **floored at 0** (slash/decline ⇒ 0, no brick), clamped to immutable `aprCap`. Advisory; gates no funds; `0`
  before warm. NAV does NOT use this — it reads `exchangeRate()` directly.
- **Constructor** `(address forwarder, uint256 maxStaleness, uint32 window, uint256 aprCap)`: forwarder zero
  reverts in `ReceiverTemplate`; `maxStaleness/window != 0`; `aprCap != 0 && <= type(uint32).max`. Owner = the
  Timelock (re-pointable Forwarder, build-phase doctrine [[oracle-replaceable-timelock-wiring]]); knobs immutable.

### The CRE workflow — `cre/szalpha-rate/` (the cross-chain pull; CRE-03 integration artifact)
Cron (~1 min) → read `SzAlpha.exchangeRate()` on **964** → `GenerateReport(abi.encode(RATE, abi.encode(rate, ts)))`
→ `WriteReport` to `SzAlphaRateOracle` on Base. **Transports the raw rate ONLY — no off-chain math.** Pinned exact:
the payload/envelope ABI (byte-matching the receiver). `TODO(CRE-03)`: go.mod, 964/8453 selectors + RPC, the exact
964 read. Not compiled in the Foundry repo (no Go toolchain).

### Tests — `contracts/test/bridge/SzAlphaRateOracle.t.sol`
Ctor guards; Forwarder-gated push lands + serves the rate; `exchangeRate()` drop-in through `IXAlphaRate`;
non-Forwarder / wrong-reportType / `ZeroRate` / `FutureTimestamp` / `StaleReport`(replay) reverts; `fresh()` flips
false past `maxStaleness` (rate still served — consumer gates); the derived APR vs a hand-computed 1216 bps; slash ⇒
0-not-brick (rate still served, fresh); cap-clamp; APR 0 before warm.

### What this DELETED vs the prior drafts
The v1 push-cache that received a **pre-computed APR** (Forwarder + the 8-field pushed payload + deviation band +
its one-sided/first-push/atomic/slash-flag fallout) and the v2 `XAlphaAprOracle`-on-964 (read-native) are both
**removed**. What ships pushes the **rate** (the irreducible cross-chain primitive) and derives NAV/APR on-chain.


## Inputs (read map)

> **NOTE (post-redesign):** for the **on-chain derivation** (this ticket's deliverable) the ONLY input is the first
> row — `exchangeRate()` on `SzAlpha` (964), read natively + the contract's own checkpoint as `r_prev`. The
> remaining rows (metagraph `0x802` forward cross-check, subnet tempo, alpha-price/TAO-USD, cross-chain circulating
> supply) are **off-chain `8-B12` monitoring / post-M1 `xalphaPriceUsd` + incentive concerns**, NOT part of the
> contract. The `Safety / manipulation resistance`, `Cadence`, and `§6` sections below describe that off-chain
> overlay + the post-M1 value/incentive leg and are kept for the monitoring build — they do not gate the derivation.

| Input | Source (read path) | Chain | Use |
|---|---|---|---|
| **xALPHA exchange rate** | `IXAlphaRate.exchangeRate()` on `SzAlpha` (8x-01) — `getStake(hotkey,wrapperColdkey,netuid)` ÷ supply, **StakingV2 `0x805`** | 964 | §primary (the headline) |
| **Prior rate sample + ts** | workflow state `(r_prev, t_prev)` | — | §primary trailing window |
| **Validator emission/dividends/status/hotkey** | `getEmission`/`getDividends`/`getValidatorStatus`/`getHotkey`/`getUidCount` (**Metagraph `0x802`**) | 964 | §secondary cross-check + liveness flag |
| **Subnet tempo** | subnet params (Metagraph / Subnet `0x803`) | 964 | `epochs_per_year`, read live |
| **Alpha price (TAO/alpha) EMA** | `subnet_moving_price`; cross-check CoinGecko SN46 | 964 | value field only — EMA never spot |
| **TAO/USD** | Chainlink TAO/USD feed if available, else aggregated fallback | — | value field only |
| **Circulating xALPHA** (value field only) | `SzAlpha.totalSupply()` (964) + `SzAlphaMirror.totalSupply()` (8453) | 964+8453 | per-token NAV/USD value — **not** the APR ratio |

## Safety / manipulation resistance

1. **NAV, not pool price** — the APR is built from `exchangeRate()` (stake accounting), never the thin POL DEX pool
   (circular/manipulable). `IXAlphaRate` reads stake on-chain, no oracle in the path.
2. **Monotone-rate sanity (WORKFLOW guard, NOT the receiver — R4).** The **workflow** rejects/clamps a §primary
   sample where `r_now < r_prev` beyond dust (rate is non-decreasing absent a slash): a genuine slash (rate drops)
   ⇒ the workflow publishes `intrinsicAprBps = 0` + the slash bit in `flags` (a **flagged event**, never a silent
   negative APR — and `uint32` cannot carry a negative anyway). The **receiver** does NO `r_now < r_prev` reject
   (it holds no prior rate; on-chain that would brick the feed on a real slash). The on-chain per-push bound is the
   one-sided-UP deviation band (R3), which lets honest downward moves through.
3. **EMA, not spot** for any alpha price (value field), + deviation guard vs a secondary source.
4. **Staleness bound** — every input has a max age; stale → flag (the APR is advisory, so flag not revert).
5. **Sanity cap / circuit breaker** — `APR_CAP` bounds the publishable APR; cap-hit flags, never emits garbage.
6. **Validator liveness** — `getValidatorStatus == false` / `getEmission == 0` ⇒ flag (realized number lags reality).
7. **Publish-on-change** — write only past an X-bps move.
8. **Cross-chain supply seam (value fields only).** Per-token NAV/USD uses **global** circulating xALPHA
   (964 + Base). 8x-01 bridges via **burn/mint**, so a bridge to Base **drops 964 `totalSupply`** while `totalStaked`
   is unchanged ⇒ 964-local `exchangeRate()` **over-states** per-token NAV. **The §primary APR ratio is immune**
   (supply cancels); the **value fields are not** — the workflow MUST divide staked alpha by `supply_964 + supply_base`
   for `xalphaPriceUsd`, OR 8x-01 must conserve home-chain supply (lock/release on 964). **Open cross-ticket item with
   8x-01 + §8.6** — resolve coherently with the `NAV_LEG` leg-0 producer; do not silently assume.

## Cadence

Recompute on the **engine epoch** (≈ tempo, ~72 min) or hourly, throttled by publish-on-change. The §primary window Δ
spans several cadences (averages per-epoch granularity); cadence = how often to re-evaluate, Δ = the lookback.

## Open items

1. **reportType allocation** — **RESOLVED (R1):** `APR = 8` pinned on the `XAlphaAprOracle` receiver; it is a
   non-collision with `DefaultCoordinator`'s `8` by the `(receiver,reportType)` rule (§8.0). The §8.0 envelope
   table row is **added** (this window). (The earlier "do not reuse 7 / next free" framing wrongly implied a
   global type space — corrected.)
2. **uid resolution** — `getHotkey` scan vs pinned `ourUid` config (re-validate on UID reshuffle). Decide at build.
3. **rao vs alpha scaling** — StakingV2 ABI comments are inconsistent (`getStake`→"RAO"; `removeStake`→"alpha");
   confirm `getStake` units (1 alpha = 1e9 rao) on a fork before trusting §secondary/value absolutes. The §primary
   ratio is scale-invariant.
4. **Cross-chain supply accounting (safety §8)** — resolve with 8x-01 + the §8.6 `NAV_LEG` producer.
5. **TAO/USD source** — confirm a Chainlink TAO/USD feed exists, else specify the aggregated fallback (value field +
   §6 only; §primary needs none).
6. **Validator-attested vs precompile-direct** — whether 964-side reads come through our validators' attestation
   ([[zipcode-subnet-role]], the vertical-integration play) or CRE reads precompiles directly (simpler first). §primary
   is identical either way.
7. **Incentive / POL overlay (§6)** — post-M1 only; ships when the emission program + treasury economics are
   re-authored.

## §6 — post-M1 szipUSD incentive APR (OUT OF SCOPE here; recorded for the re-author)

When the protocol emits xALPHA as a depositor subsidy (post-M1, `claude-zipcode.md §4.5/§17`), the depositor-facing
incentive APR is a **budget allocation valued through this ticket's primitive** — a *different* number, published in
`incentiveAprBps` as its **own field**, never blended into the intrinsic APR:
```
xalphaPriceUsd        = exchangeRate() × alpha_price_TAO_EMA × TAO_USD
incentive_USD_per_year = xALPHA_emitted_to_depositors_per_year × xalphaPriceUsd
incentiveAprBps        = incentive_USD_per_year ÷ szipUSD_TVL_USD      // szipUSD supply / Hydrex pool reserves, 8453
```
Self-consuming/reflexive (selling the subsidy drops alpha price and emission rate) → label descriptive-of-now, never a
forward promise. **The program, budget, and pool seeding are post-M1 treasury economics** (`pending-docs/treasury.md`
removed 2026-06-09 — re-author post-M1). M1 publishes `incentiveAprBps = 0`. An optional POL combined-yield report
(`0.5·intrinsicApr + 0.5·szipUSD_base + LP fees + oHYDX·δ − IL`) is likewise post-M1 and, if shipped, a **separate**
clearly-labeled report.

## Cross-ticket obligations

- **8x-01** (`SzAlpha`/`IXAlphaRate.exchangeRate()`) — the §primary read; run against the **xALPHA stand-in** until the
  lane is live (the stand-in implements `IXAlphaRate`, `claude-zipcode.md §4.5.1`). Resolve the supply-seam (safety §8)
  jointly.
- **CRE-03** (`claude-zipcode.md §8.8/§8.11`) — this ticket IS the xALPHA-APR portion of CRE-03; file the build there,
  alongside the §8.6 `NAV_LEG`/`LP_MARK` share-price feeds (one workflow family). The value field + the §8.6 leg-0
  `alphaUSD` mark must use the **same** cross-chain supply resolution.
- **claude-zipcode.md §8.0** — allocate the APR reportType in the envelope table (open item 1).
- **8-B12 monitoring** (`monitoring.md`) + **8-B11 regime gate** — consume `intrinsicAprBps`/`flags`; this is **display
  + regime input**, distinct from the szipUSD NAV-accretion APR (the 8-B12 / §8.6 product feed) — do not conflate.
- **Treasury (post-M1)** — the §6 incentive overlay, emission budget, POL combined yield — explicitly NOT here.

## References

- Spec provenance (subsumed): the former `bridge/xALPHA-apr.md` (deleted — content folded into this ticket).
- `tickets/bridge/8x-01-szalpha-wrapper-cct.md` (`SzAlpha`, `IXAlphaRate`, `SzAlphaMirror`, the pooled-staker model).
- `contracts/src/interfaces/bridge/IXAlphaRate.sol` (`exchangeRate()`, alpha-per-xALPHA 18-dp, read on-chain).
- `contracts/src/supply/SzipNavOracle.sol` (the `ReceiverTemplate` push-cache pattern to mirror).
- `reference/subtensor/precompiles/src/solidity/stakingV2.sol` (`getStake` `0x805`),
  `.../metagraph.sol` (`getEmission`/`getDividends`/`getValidatorStatus`/`getHotkey`/`getUidCount` `0x802`).
- `reference/cre-sdk-go`, `reference/cre-templates` (workflow layout); `claude-zipcode.md §8.0/§8.6/§8.8/§8.11`
  (envelope table, push-cache producers, this feed, CRE-NN map), §12 (trailing-realized rule), §17 (post-M1 yield).
- Memory: [[zipcode-subnet-role]], [[supply-side-redesign-locked]], [[rubicon-fork-and-closed-loop]],
  [[prefer-simplest-mechanism]].
