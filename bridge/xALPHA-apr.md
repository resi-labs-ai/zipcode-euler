# xALPHA-apr.md — CRE workflow spec: rewards APR from xALPHA emissions

> **What this builds:** a **Chainlink CRE (Chainlink Runtime Environment) workflow** that computes the
> **Current APR** for szipUSD supply incentivized in xALPHA, and publishes it on-chain as a trust-minimized
> report the UI and contracts consume. It implements the APR math defined in `pending-docs/treasury.md` §4 over the
> contract/precompile reads defined in `bridge/xalpha-bridge-impl.md`. This doc is a **high-level spec** — data
> sources, computation, output schema, cadence, and safety — **not** a finished workflow implementation.
> Status: **spec / design**. Refs: `pending-docs/treasury.md` (the APR formula + floor-vs-variable rule it implements),
> `bridge/xalpha-bridge-impl.md` (precompiles/contracts it reads), `claude-zipcode.md` (szipUSD, base yield),
> `claude-zipcode.md` §11 (throttle context). Memory: [[zipcode-subnet-role]] (subnet validators = the DON/validation
> fabric feeding CRE), [[supply-zap-and-resi-bond-bootstrap]], [[rubicon-fork-and-closed-loop]].

## 1. Purpose

Publish the depositor-facing **Current APR**, split as **floor + variable** (never blended, per `pending-docs/treasury.md`
§4.2):
- **Base APR** — underwritten, USD, from real revenue (lending spread + xALPHA coupon).
- **Incentive APR** — variable, existentially priced, from xALPHA emissions valued at live NAV × alpha price.

The variable leg is **self-consuming and reflexive** (selling the reward drops both alpha price and, under
net-flow emission rules, the emission rate). So this workflow exists to recompute it **frequently, on-chain, and
trust-minimized** — not as a one-off or a frontend estimate that on-chain consumers can't trust.

## 2. Why CRE (not a subgraph or frontend calc)

1. **Cross-chain reads.** Inputs live on **two** chains — xALPHA NAV / alpha price / emission state on Bittensor
   mainnet (**964**), and TVL / pool reserves / lending state on Base (**8453**). CRE reads both and aggregates
   in one workflow; a per-chain subgraph cannot.
2. **DON consensus → on-chain consumable.** The output may feed contracts (UI display, dynamic gauge-bribe
   sizing, risk caps), so it must be on-chain and trust-minimized. A single frontend/oracle is a trust point;
   CRE's DON gives consensus over the computed report.
3. **Validation fabric is ours.** Our subnet validators are the DON/validation fabric feeding CRE
   ([[zipcode-subnet-role]]) — the subnet-side inputs (alpha price EMA, emission, NAV) are attested by the same
   validators we already run, then aggregated by CRE. Vertical integration of the data path.

## 3. Inputs

| Input | Source (read path) | Chain | Notes |
|---|---|---|---|
| **xALPHA emission rate** (reward tokens / epoch) | rewards-distributor contract (actual emitted) | 8453 | Read **actual** emission, not the $100k budget constant — reflects any throttle/pause. |
| **xALPHA NAV** (alpha per xALPHA) | wrapper exchange rate = `staked alpha ÷ xALPHA supply`; staked alpha via **StakingV2 `0x805`** `getStake`, supply via token `totalSupply` | 964 | **NAV, not DEX pool price** — mint/redeem has no pool dependency (`bridge/xalpha-bridge-impl.md` §2); the thin pool is manipulable. |
| **Alpha price** (TAO / alpha) | subnet AMM **EMA / moving price** via **Metagraph `0x802`** (`subnet_moving_price`); cross-check a secondary (CoinGecko SN46) | 964 | Use the **EMA**, never spot — a single large stake/unstake moves spot (see §6). |
| **TAO / USD** | Chainlink TAO/USD feed if available, else aggregated source | — | Converts the alpha leg to USD. |
| **TVL** (incentivized deposit / pool, USD) | szipUSD supply and/or Hydrex xALPHA/szipUSD pool reserves | 8453 | The APR denominator. Define exactly which TVL the incentive targets. |
| **Base-APR components** | lending-market spread + xALPHA coupon config on the szipUSD market | 8453 | The underwritten floor (real revenue). |

## 4. Computation (implements `pending-docs/treasury.md` §4)

```
xALPHA_price_USD       = NAV_alpha_per_xALPHA × alpha_price_TAO_EMA × TAO_USD
incentive_USD_per_year = emission_xALPHA_per_epoch × epochs_per_year × xALPHA_price_USD
Incentive_APR          = incentive_USD_per_year ÷ TVL_USD
Base_APR               = lending_spread + xALPHA_coupon          (USD, underwritten)
Current_APR            = Base_APR + Incentive_APR              (reported as SEPARATE fields)
```

- `epochs_per_year` derived from subnet tempo (≈360 blocks ≈ 72 min → ~7,300 epochs/yr); confirm against live
  tempo, don't hardcode.
- **Optional secondary output — POL combined yield** (`pending-docs/treasury.md` §4.3): the protocol-side stack
  `0.5·NAV_yield + 0.5·szipUSD_base + fees + oHYDX·δ − IL`. More inputs (gauge rate, option discount δ, pool
  fee/volume, IL estimate); ship as a **separate, clearly-labeled** report, not folded into the depositor APR.

## 5. Output (on-chain report)

A single report struct the UI and contracts read:

| Field | Meaning |
|---|---|
| `base_apr_bps` | underwritten floor (USD) |
| `incentive_apr_bps` | variable xALPHA-emission leg |
| `current_apr_bps` | sum (consumers should still display the split) |
| `xalpha_nav` | alpha per xALPHA at compute time |
| `alpha_price_used` | the EMA price used (auditable) |
| `tvl_usd` | denominator used |
| `computed_at` / `epoch` | freshness |
| `flags` | staleness / deviation / cap-hit bitfield (§6) |

## 6. Manipulation resistance & safety

1. **NAV, not pool price** for xALPHA valuation — the redeem value is the real value; the DEX pool is thin and
   ours (POL), so quoting off it is circular and manipulable.
2. **EMA, not spot** for alpha price (`subnet_moving_price`), plus a **deviation guard**: if EMA vs spot, or
   EMA vs the secondary source, diverges beyond a threshold, set a flag and/or withhold the update.
3. **Staleness bound** — each input carries a max age; stale input → flag, don't silently publish a number off
   old data.
4. **Sanity cap / circuit breaker** — bound the reportable APR; a price glitch must not publish a 9,000% APR.
   Cap-hit sets a flag rather than emitting a garbage headline.
5. **Publish-on-change threshold** — only write when a leg moves more than X bps, to control gas/report spam
   while staying fresh enough for a reflexive number.
6. **Label variable** — `incentive_apr_bps` is descriptive of *now*, never a forward promise; the split exists
   so it degrades visibly toward the floor when alpha sells off (`pending-docs/treasury.md` §4.2).

## 7. Cadence

Recompute **per subnet epoch** (≈ tempo, ~72 min) or hourly — frequent enough that the self-consuming variable
leg tracks reality, throttled by the publish-on-change threshold (§6.5). The base leg moves slowly; the
incentive leg is the one that needs the freshness.

## 8. Open items

1. **TVL definition** — exactly which deposit/pool the incentive APR is denominated against (szipUSD supply vs
   the Hydrex LP vs both). Decides the denominator.
2. **TAO/USD source** — confirm a Chainlink TAO/USD feed exists for CRE consumption, else specify the aggregated
   fallback.
3. **Emission-rate read** — confirm the rewards-distributor exposes a clean on-chain emitted-per-epoch value (vs
   reconstructing from transfer events).
4. **Validator-attested vs precompile-direct** — whether subnet-side inputs come through our validators'
   attestation ([[zipcode-subnet-role]]) or CRE reads the precompiles directly; the former is the
   vertical-integration play, the latter is simpler to ship first.
5. **POL combined-yield report** — ship now or defer; needs δ (option discount), gauge rate, and an IL estimator.
