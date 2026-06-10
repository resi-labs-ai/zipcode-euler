# monitoring.md — Surveillance spec: the race, the whale, the backing, the floor

> **Disposition:** forward input for **FE-04** (solvency dashboard) + **CRE-05** (the 8-B11 strategy-robot
> triggers). Dies when 8-B11/8-B12 land (`build/tickets/PROGRESS.md` → Deletion triggers). The on-chain engine modules it watches are BUILT —
> their spec is `build/wires/` (8-B* docs) + `claude-zipcode.md §8.7`; older `§4.5.1` refs resolve there.
> The "REDESIGN DELTAS" banner below already flags the superseded backing-ratio/boost-loop framings.

> **REDESIGN DELTAS — read through these (authoritative: `claude-zipcode.md` §2/§4.5/§4.5.1/§17):** the gauged LP/POL
> is `zipUSD/xALPHA` (not szipUSD/xALPHA); `sdVAULT` collapsed into the **`szipUSD`** vault share. **Single-sink
> rework (2026-06-08):** excess value is NOT paid out or used to buy xALPHA — it is **recycled (8-B10) into the
> szipUSD basket → NAV-per-share accretion**, and the real lending yield is the **protocol's** (it over-collateralizes
> zipUSD in the `CreditWarehouse`). So the old **"szipUSD backing ratio" / "boost-loop" / "redemption-depth ratio"**
> framings below are superseded — the live solvency checks are **zipUSD warehouse over-collateralization** + **szipUSD
> NAV-per-share**; the redemption-depth ratio belongs to the **deferred post-M1 xALPHA-emission program**, not M1.

> **What this watches:** the four things that can quietly end the Hydrex leg or the depositor product, each with an
> on-chain source, a cadence, a threshold, and the action it fires. Built as a **read-only multicall + archive
> reads + event indexer**; no writes. Consolidates the dashboards in `hydrex.md` §10 and `auto-compounder.md` §7
> and adds the four critical watch-items. The dashboard is the trigger source for the CRE bot (`hydrex.md` §10,
> `auto-compounder.md` §4).
> Refs: `hydrex.md`, `auto-compounder.md`, `claude-zipcode.md §4.5.1`. Memory: [[hydrex-gauge-architecture]].

---

## 1. The four critical watch-items

### A. Vote-power growth per epoch — the race

The denominator we're a share of. If it grows faster than we compound, our gauge starves.

| Metric | Source | Cadence | Threshold → action |
|---|---|---|---|
| Total vote weight | `Voter.totalWeightAt(epochTs)` | per epoch | — |
| **Race rate `g`** = Δtotal / total | deltas of above | per epoch | baseline ~0.4%/epoch. **`g > 1%` → someone is locking aggressively → raise our re-lock split** |
| Total locked HYDX | `HYDX.balanceOf(ve 0x25B2…)` | per epoch | rising → new capital locking; cross-check with `g` |
| New-lock vs improved-lock decomposition | Δ`balanceOf(ve)` (new HYDX in) vs Δ vote-weight (extensions) | per epoch | distinguishes fresh entrants (capital race) from re-ups (compounding war) |
| **Our share** = our_votes / total | `Voter.votes(ourVeNFT, ourGauge)` / `totalWeightAt` | per epoch | **drop > tolerance vs target floor → re-lock more, or accept dilution** |
| Our gauge weight + top-5 rivals | `Voter.weightsAt(pool, epochTs)` for our gauge + sink + top gauges | per epoch | contestable-bloc context |

### B. Whale / team-treasury surveillance — the regime-change tripwire

The single most important alert. The team can dilute us 7:1 the week they decide to (`hydrex.md` §4). We must see
it *coming*, not after.

| Metric | Source | Cadence | Threshold → action |
|---|---|---|---|
| **Team lock power (tokenId 1)** | `ve.balanceOfNFT(1)` (Safe A `0xd9e966a6…`) | per epoch | **any meaningful jump = they are `exerciseVe`-locking the overhang → the dilution war has begun → execute the defensive playbook (max re-lock OR accept minority + lean on deposits)** |
| Team liquid HYDX overhang | `HYDX.balanceOf(SafeA)` | daily | falling fast → OTC sales / about to lock; sudden drop → watch for a market dump |
| Team oHYDX hoard | `oHYDX.balanceOf(SafeB 0x1ae3…)` + `EOA 0x7426…` | daily | growing = warehousing (benign); **shrinking fast = they are exercising → about to sell or lock at scale** |
| Sink gauge weight | `Voter.weightsAt(0xb0eac8aa…, epochTs)` | per epoch | the 62% moving = team redirecting emissions; if it *drops*, contestable bloc grows (good); if they point it at us, unexpected |
| Team HYDX burns | `Transfer(SafeA → 0x0)` events | continuous | context (deflation / signalling) |
| Team multisig txs | Safe A/B `ExecutionSuccess` events | continuous | early warning of any of the above before balances settle |

> **Defensive playbook trigger:** Safe A lock-power jump **or** oHYDX-hoard rapid drawdown → the bot shifts its
> default split hard toward `exerciseVe` (defend the floor) and Treasury is paged for a buy/lock decision. Do not
> wait for our share to actually fall — by then it's too late.

### C. Recycle inflow & zipUSD backing — the solvency watch

The recycle (8-B10) pumps real USDC into the warehouse as senior backing; backing is fine *by construction*, but the
**inflow-vs-origination** balance is not automatic — the loop adds lending capacity faster than organic deposits.

| Metric | Source | Cadence | Threshold → action |
|---|---|---|---|
| Recycle USDC inflow | cumulative warehouse deposits routed from the auto-compounder recycle | per epoch | tracks AUM growth from the bleed |
| **zipUSD over-collateralization** = warehouse NAV ÷ zipUSD float | warehouse + `EE_POOL.convertToAssets` | continuous | **< 1.0 → HALT all minting + escalate** (should never happen — deposit precedes mint; a breach means an accounting bug) |
| **szipUSD NAV-per-share** = basket NAV ÷ szipUSD supply | `SzipNavOracle` | continuous | should accrete; a *drop* = a loss event (provision booked) → investigate |
| **Origination throughput** = USDC deployed-in-loans ÷ USDC idle | warehouse state | per epoch | **idle fraction rising → origination lagging the recycle inflow → throttle the recycle**; this is the *real* constraint, not backing |
| **Redemption-depth ratio** *(deferred — post-M1 xALPHA-emission program only)* = POL zipUSD depth ÷ cumulative emitted-but-unsold xALPHA | POL reserves + emission accounting | per epoch | N/A in M1 (no raw-xALPHA emission); re-activates if/when that program ships |
| Net new external USDC | depositor inflows − redemptions | per epoch | the prize metric — is the lure actually acquiring deposits |

### D. Option-floor proximity — slippage/spread vs the inflexible strike

The auto-compounder's profitability **mechanically collapses** as spot falls toward the $0.01 strike floor, because
the option strike is **rigid** (`strike = max(30%·2h-TWAP, $0.01)`) while the HYDX you sell keeps dropping. Watch
the two converge.

| Metric | Source | Cadence | Threshold → action |
|---|---|---|---|
| HYDX spot | `pool.globalState()` | continuous | — |
| Current strike | `oHYDX.getDiscountedPrice(1e18)` (= `max(30%·TWAP, $0.01)`) | continuous | floor binds below spot ~$0.033 |
| **Effective spread** = (spot − strike) / spot | derived | continuous | **70% → 50% (@$0.02) → 33% (@$0.015) → 0% (@$0.01)** |
| **2h-TWAP vs spot gap** | `oHYDX.getTimeWeightedAveragePrice` vs `pool` spot | continuous | **spot < 30%·TWAP → exercise *unprofitable now* (TWAP lag) → pause sell path even above the price floor** |
| Realized per-order slippage | range-sell fills vs mid | per order | **> 2–3% → reduce order size** (`hydrex.md` §9.3) |
| **Profitability halt** | HYDX < $0.015 loop cutoff (amber-taper begins ~$0.018) | continuous | **halt the sell path; route 100% of oHYDX to `exerciseVe`**; below $0.015 the borrow→exercise→sell→repay round-trip stops netting (the ~33% gross spread no longer covers slippage); $0.01 = mechanical dead floor |
| Distance-to-floor | spot ÷ $0.01 | continuous | dashboard gauge of remaining runway (plan: bleeds to ~$0.014–0.018) |

> **The inflexibility, stated:** the strike cannot adapt downward past $0.01, and it lags the price by the 2h
> TWAP. So profit = (a declining sale price) − (a floored, lagging strike) — a spread that shrinks faster than
> linear and dies at the floor. The auto-compounder must **detect the convergence and stop selling**, not grind the
> last unprofitable basis points.

---

## 2. Consolidated metric registry (all sources)

| Group | Metrics | Primary sources |
|---|---|---|
| **Entitlement** | our share, locked float, emission `E`, cost-per-1% | `Voter`, `HYDX.balanceOf(ve)`, `Minter.weekly()` |
| **Race (A)** | total weight, `g`, new-vs-improved locks, gauge weights | `Voter.totalWeightAt/weightsAt`, `ve` deltas |
| **Whale (B)** | team lock power, liquid overhang, oHYDX hoard, sink weight, burns, Safe txs | `ve.balanceOfNFT(1)`, `HYDX/oHYDX.balanceOf(team)`, events |
| **Extraction** | USDC depth, tick-enumerated fill curve, measured net Swap flow, price, 2h-TWAP | `pool` reads, `pool.ticks()`, Swap events, `oHYDX.twapOracle` |
| **Floor (D)** | spot, strike, effective spread, TWAP-gap, per-order slippage, distance-to-floor | `oHYDX.getDiscountedPrice/getMinPaymentAmount/getTimeWeightedAveragePrice`, `pool` |
| **Clock** | rebase %, emission decay, weeks-to-sunset | `Minter.calculate_rebase`, `EmissionSchedule` |
| **Backing (C)** | zipUSD over-collateralization, szipUSD NAV-per-share, origination throughput, net new USDC | warehouse state, `SzipNavOracle` |
| **Product** | vault TVL vs bleed cap, trailing-realized APR, net deposit flow | `auto-compounder` vault, CRE APR oracle |

---

## 3. Escalation tiers

- **Green (auto):** bot acts on the trigger (re-lock, re-vote, taper, sweep). No human.
- **Amber (notify):** `g > 1%`, idle-USDC rising, effective spread < 40% → log + dashboard flag + daily digest to
  Treasury.
- **Red (page):** **team lock-power jump**, **oHYDX hoard rapid drawdown**, zipUSD over-collateralization < 1.0,
  profitability-halt tripped → page Treasury; bot defaults to the conservative posture (all-to-ve, pause
  sells, halt minting) until a human decides.

---

## 4. Implementation

- **Read layer:** Multicall3 batch of the registry each epoch + a continuous (per-block-ish) poll of the floor/
  price/TWAP group (group D moves fast).
- **History:** archive `eth_call` for `totalWeightAt`/`weightsAt`/`balanceOf` at weekly checkpoints (the 90-day
  USDC trajectory was built this way — `hydrex.md` Sources); event indexer for team Safe txs, burns, and Swap-flow
  net.
- **Fill curve:** enumerate initialized ticks (`pool.ticks()` via tickBitmap) for the exact USDC-per-%-move; feeds
  both the extraction cap and the TVL cap.
- **Outputs:** (1) the CRE trigger panel (drives the bot); (2) the trailing-realized APR oracle (depositor-facing);
  (3) the Treasury digest/pages.
- **No writes** — surveillance only; all actions flow through the permissioned CRE bot.

## 5. Open items

- [ ] Multicall registry + per-epoch snapshotter (archive checkpoints).
- [ ] Team-Safe event indexer + the **lock-power-jump / hoard-drawdown red tripwires** (highest priority — the
      regime-change early warning).
- [ ] zipUSD over-collateralization + szipUSD NAV-per-share + origination-throughput feeds from the warehouse/oracle.
- [ ] Effective-spread / TWAP-gap / distance-to-floor continuous monitor + the **profitability-halt** signal into
      the auto-compounder.
- [ ] Tick-enumeration fill curve (shared with `hydrex.md` §5 / `auto-compounder.md` §7).
