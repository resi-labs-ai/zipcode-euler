# monitoring.md — Surveillance spec: the race, the whale, the backing, the floor

> **SUPPLY-SIDE REDESIGN (2026-06-05) — read through these deltas (authoritative: `claude-zipcode.md` §2/§4.5/§17):**
> POL depth + the redemption-depth ratio are measured in **zipUSD** (the LP is `zipUSD/xALPHA`, not
> szipUSD/xALPHA). `sdVAULT` collapsed into the **`szipUSD`** vault share. The **"szipUSD backing ratio"** below
> is superseded: the real lending yield is the **protocol's** (privatized → buy xALPHA), so szipUSD is the
> freezable vault share (backed by the zipUSD/xALPHA LP), not a USDC-share claim — this metric needs re-deriving
> when the treasury/buyback module is specced (tracked post-M1).

> **What this watches:** the four things that can quietly end the Hydrex leg or the depositor product, each with an
> on-chain source, a cadence, a threshold, and the action it fires. Built as a **read-only multicall + archive
> reads + event indexer**; no writes. Consolidates the dashboards in `hydrex.md` §10 and `auto-sodomizer.md` §7
> and adds the four critical watch-items. The dashboard is the trigger source for the CRE bot (`hydrex.md` §10,
> `auto-sodomizer.md` §4).
> Refs: `hydrex.md`, `treasury.md`, `auto-sodomizer.md`. Memory: [[hydrex-gauge-architecture]].

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

### C. USDC inflows & szipUSD backing — the boost-loop solvency watch

The boost loop (`treasury.md` §4.7) pumps real USDC into the book; backing is fine *by construction*, but the
**inflow-vs-origination** balance and the **redemption-depth ratio** are not automatic.

| Metric | Source | Cadence | Threshold → action |
|---|---|---|---|
| Boost-loop USDC inflow | cumulative loan-book deposits routed from the auto-sodomizer | per epoch | tracks AUM growth from the bleed |
| **szipUSD backing ratio** = total USDC/loan-value ÷ szipUSD supply | lending-market accounting | continuous | **< 1.0 → HALT all minting + escalate** (should never happen — deposit precedes mint; a breach means an accounting bug) |
| **Origination throughput** = USDC deployed-in-loans ÷ USDC idle | lending-market state | per epoch | **idle fraction rising → origination lagging the inflow → throttle the loop (Mode A / slow buys)**; this is the *real* constraint, not backing |
| **Redemption-depth ratio** = POL zipUSD depth ÷ cumulative emitted-but-unsold xALPHA | POL reserves + emission accounting | per epoch | **< 1.0 → "Current APR" un-realizable → headline at risk → cut emissions or deepen POL** (load-bearing, `treasury.md` §4.1) |
| Net new external USDC | depositor inflows − redemptions | per epoch | the prize metric — is the lure actually acquiring deposits |

### D. Option-floor proximity — slippage/spread vs the inflexible strike

The auto-sodomizer's profitability **mechanically collapses** as spot falls toward the $0.01 strike floor, because
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
> linear and dies at the floor. The auto-sodomizer must **detect the convergence and stop selling**, not grind the
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
| **Backing (C)** | szipUSD backing ratio, origination throughput, redemption-depth ratio, net new USDC | lending-market state, POL reserves |
| **Product** | vault TVL vs bleed cap, trailing-realized APR, net deposit flow | `auto-sodomizer` vault, CRE APR oracle |

---

## 3. Escalation tiers

- **Green (auto):** bot acts on the trigger (re-lock, re-vote, taper, sweep). No human.
- **Amber (notify):** `g > 1%`, idle-USDC rising, effective spread < 40%, redemption ratio approaching 1.0 → log
  + dashboard flag + daily digest to Treasury.
- **Red (page):** **team lock-power jump**, **oHYDX hoard rapid drawdown**, backing ratio < 1.0, redemption ratio
  < 1.0, profitability-halt tripped → page Treasury; bot defaults to the conservative posture (all-to-ve, pause
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
- [ ] szipUSD backing + origination-throughput + redemption-depth feeds from the lending market.
- [ ] Effective-spread / TWAP-gap / distance-to-floor continuous monitor + the **profitability-halt** signal into
      the auto-sodomizer.
- [ ] Tick-enumeration fill curve (shared with `hydrex.md` §5 / `auto-sodomizer.md` §7).
