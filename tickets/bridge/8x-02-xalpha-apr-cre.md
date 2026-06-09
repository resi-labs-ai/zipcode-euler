# 8x-02 — xALPHA-LST intrinsic-APR CRE feed (`XAlphaAprOracle` push-cache + workflow)

> **NEXT / build-only.** The CRE half of the bridge: a **Chainlink CRE workflow** that computes the **intrinsic APR
> of the xALPHA liquid-staking token** — the staking yield the LST throws off on its own — and publishes it on-chain
> as a trust-minimized **push-cache report** the UI, contracts, and engine regime-gates read. The APR is **derived,
> not budgeted**: it is the annualized growth of the wrapper's `exchangeRate()` (`IXAlphaRate`, ticket 8x-01), which
> moves **only** as our subnet validator's dividends compound into the staked alpha pool. **No treasury constant, no
> `$100k` budget** — the number is a byproduct of on-chain reads alone (NAV growth + validator emission).
>
> **This ticket is the detailed build spec for the xALPHA-APR portion of `CRE-03`** (`claude-zipcode.md §8.8/§8.11`);
> it subsumes the former `bridge/xALPHA-apr.md` design doc. CRE-03 builds the §8.6 share-price feeds and this APR feed
> as **one bridge/oracle workflow family** — author the receiver + workflow here, file the build under CRE-03.
>
> **Mocked vs real.** **Real:** the live 964 reads (`exchangeRate()` on the deployed `SzAlpha`, metagraph emission)
> exercised on a Subtensor EVM fork; the receiver on a Base fork. **Mocked:** the CRE DON relay itself (no real DON in
> tests — use the receiver's Forwarder seam with a test signer). Until 8x-01's lane is live, the workflow reads the
> **xALPHA stand-in** (the 18-dp mock also exposing `IXAlphaRate`, `claude-zipcode.md §4.5.1`).
>
> **Sequencing.** M1 but **not on the contract-spine critical path** — depends on 8x-01 (`SzAlpha`/`IXAlphaRate`) for
> real reads and on the CRE-00 scaffold. Schedule against CRE-03 / 8x-01, not ahead. The **post-M1 szipUSD incentive
> APR overlay** (§6) is explicitly **out of scope** here (treasury economics, removed 2026-06-09, re-author post-M1).

---

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

One push-cache receiver, one CRE workflow, one fork/mock test suite.

### 1. `contracts/src/bridge/XAlphaAprOracle.sol` — the on-chain push-cache receiver

`contract XAlphaAprOracle is ReceiverTemplate` — follow the **exact §8.6 push-cache pattern** of
`contracts/src/supply/SzipNavOracle.sol` (Forwarder-gated, identity-immutable, deviation/staleness guards). It caches
the latest DON-signed APR report and exposes getters; it holds **no** trust beyond the Forwarder.

- **reportType:** allocate an APR report type in the `claude-zipcode.md §8.0` envelope table (suggest **`APR = 8`**;
  do **not** silently reuse `7` — that is `NAV_LEG`/`LP_MARK`, per-receiver-scoped). Pin it in the ticket report.
- **Payload (decoded in `_processReport`):**

  | Field | Type | Meaning |
  |---|---|---|
  | `intrinsicAprBps` | `uint32` | the headline — §primary trailing-realized LST staking yield (alpha-denominated) |
  | `exchangeRate` | `uint256` | `exchangeRate()` at compute time (alpha per xALPHA, 18-dp; auditable input) |
  | `windowSeconds` | `uint32` | the Δ lookback used (so consumers see the trailing window) |
  | `forwardAprBps` | `uint32` | §secondary metagraph cross-check (advisory; flagged on divergence) |
  | `xalphaPriceUsd` | `uint256` | LST per-token USD value (display; needs alpha-price + TAO/USD) — `0` if value leg withheld |
  | `incentiveAprBps` | `uint32` | §6 depositor-subsidy APR — **post-M1, `0` until live**, never blended |
  | `computedAt` | `uint32` | freshness timestamp |
  | `flags` | `uint32` | staleness / deviation / cap-hit / validator-out-of-consensus bitfield |

- **On-chain guards (mirror `SzipNavOracle`):** `computedAt <= block.timestamp` (`FutureTimestamp`); a per-push
  **deviation circuit-break** on `intrinsicAprBps` vs the prior cache (`DeviationExceeded`, governed `maxDeviationBps`)
  — the producer must not jump the APR more than the band in one push; a **sanity cap** `intrinsicAprBps <= APR_CAP`
  (`AprCapExceeded`, a price/read glitch must not publish a 9,000% headline); `exchangeRate != 0` (`ZeroRate`).
- **Reads expose `(value, ts, flags)` + a `fresh(maxAge)` view** so consumers (UI, 8-B12, regime gate) can fail-soft
  on a stale APR rather than trust an old number. The APR is **advisory/display** — it gates **nothing** that moves
  funds (unlike `SzipReservoirLpOracle`), so staleness is a flag, not a revert.
- **Authority:** identity (Forwarder + `(receiver,reportType)` filter) immutable post-deploy; no owner mutation of the
  cache; governed knobs (`maxDeviationBps`, `APR_CAP`, `maxAge`) set at deploy under the timelock, recorded in report.

### 2. The CRE workflow — `XAlphaAprWorkflow` (Go, `reference/cre-sdk-go` + `cre-templates` layout)

Stateful across runs (keeps the prior `(exchangeRate, ts)` sample). Per cadence (§cadence):

**Primary (the published `intrinsicAprBps`) — trailing-realized NAV growth, 964 reads only:**
```
r_now  = IXAlphaRate(SzAlpha).exchangeRate()          // 964, alpha per xALPHA, 18-dp
r_prev = prior cached sample                            // workflow state (r_prev, t_prev)
period_growth = r_now / r_prev - 1
intrinsicApr  = period_growth * (SECONDS_PER_YEAR / (now - t_prev))      // simple annualization (conservative)
```
- **Numeraire-clean:** both legs alpha → the real staking yield, independent of alpha's USD price. (USD price enters
  only the value field + §6, never this ratio.)
- Δ (`now - t_prev`) spans **several** subnet tempos so per-epoch dividend granularity averages out; optional EMA over
  the last N samples to damp noise (publish smoothed, carry raw in a side field for audit).
- Persist `(r_now, now)` as the next `r_prev`.

**Secondary (`forwardAprBps`, advisory cross-check + liveness flag) — metagraph `0x802`:**
```
ourUid  = resolve VALIDATOR_HOTKEY -> uid               // scan getHotkey(netuid,uid) over getUidCount, or pinned config
emission = getEmission(netuid, ourUid)                  // uint64, alpha (rao) to our UID this tempo
ourStake = getStake(VALIDATOR_HOTKEY, wrapperColdkey, NETUID)   // StakingV2 0x805
forwardApr ≈ (emission * staker_share / ourStake) * epochs_per_year
```
- **Caveat (why secondary, never the headline):** `getEmission` is the UID's *total* emission; the fraction reaching
  the staked pool (vs validator take + miner split) is not fully exposed by the read. Use `getDividends(netuid,ourUid)`
  (uint16, normalized) + `getValidatorStatus` to bound it. The **ground truth is the §primary NAV growth** — use this
  only to **flag divergence** (realized ≫ forward ⇒ transient; forward → 0 or `getValidatorStatus == false` ⇒
  validator deregistered/out of consensus ⇒ set the liveness flag, the realized number will lag reality).
- `epochs_per_year` from **live subnet tempo** (≈360 blocks × ~12 s ≈ 72 min ⇒ ~7,300 epochs/yr) — **read live, do not
  hardcode.**

**Value field (`xalphaPriceUsd`, display only):** `exchangeRate() × alpha_price_TAO_EMA × TAO_USD`. **EMA, never spot**
for alpha price (`subnet_moving_price`), with a deviation guard vs a secondary source; withhold the leg (push `0` +
flag) if stale/divergent. Does **not** affect `intrinsicAprBps`.

**`incentiveAprBps`:** push `0` in M1 (the depositor-subsidy emission program is post-M1, §6).

`emit WriteReport` to `XAlphaAprOracle` via the Forwarder; honor the **publish-on-change threshold** (only write when a
leg moves > X bps) to control gas/spam.

### 3. `contracts/test/bridge/XAlphaAprOracle.t.sol` + workflow tests

- **Receiver (Base fork or unit):** Forwarder-gated push lands; non-Forwarder push reverts; `FutureTimestamp`,
  `DeviationExceeded`, `AprCapExceeded`, `ZeroRate` each revert on the bad payload; `fresh(maxAge)` flips false past
  `maxAge`; getters return the last good `(value, ts, flags)`.
- **Workflow (Subtensor fork or MOCK — name says MOCK if mocked):**
  - **`test_intrinsicAprFromRateGrowth`:** given `r_prev`/`r_now` and Δ, the published bps equals the hand-computed
    annualized growth; **supply-invariance** — minting/burning xALPHA between samples (NAV-neutral) does **not** change
    the APR.
  - **`test_dividendsOnlyMovesRate`:** an out-of-band validator dividend (stake rises, supply flat) raises the APR; a
    `deposit` (stake + supply rise together) does not.
  - **`test_forwardCrossCheckFlags`:** `getValidatorStatus == false` or `getEmission == 0` sets the liveness flag;
    forward-vs-realized divergence beyond band sets the divergence flag (advisory, still publishes intrinsic).
  - **`test_capAndDeviation`:** a glitched `r_now` that implies a 9,000% APR is rejected by `APR_CAP`/`maxDeviationBps`,
    not published.
  - **`test_valueFieldWithheld`:** stale/divergent alpha-price ⇒ `xalphaPriceUsd == 0` + flag, `intrinsicAprBps`
    unaffected.
  - **`test_uidResolution`:** `getHotkey` scan finds `ourUid` for our `VALIDATOR_HOTKEY`; a UID reshuffle re-resolves.

---

## Inputs (read map)

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
2. **Monotone-rate sanity** — reject a §primary sample where `r_now < r_prev` beyond dust (rate is non-decreasing
   absent a slash) or jumps past the deviation band; a genuine slash (rate drops) is a **flagged event**, not a silent
   negative APR.
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

1. **reportType allocation** — pin `APR = 8` (or next free) in `claude-zipcode.md §8.0`; update the envelope table.
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
