# hydrex.md — Hydrex as a customer-acquisition subsidy: governance floor, structured-product surface, the recycle sink

> **SUPPLY-SIDE REDESIGN (2026-06-05) — read through these deltas (authoritative: `claude-zipcode.md` §2/§4.5/§17):**
> The gauged pool / POL is **`zipUSD/xALPHA`** (not szipUSD/xALPHA) — the stable leg is the clean, *yieldless*
> zipUSD. The recycle loop mints **zipUSD** (backed 1:1 by the deposited USDC) and swaps **zipUSD→xALPHA**.
> `sdVAULT` collapsed into the **`szipUSD`** vault share (deposit zipUSD/xALPHA single-sided → szipUSD). The real
> lending yield is the **protocol's** (it over-collateralizes zipUSD in the credit warehouse). **SINGLE-SINK REWORK
> (2026-06-08):** the depositor's return is **NAV accretion** — the HYDX-extracted free value is recycled into the
> szipUSD basket (8-B10 `RecycleModule` → backed zipUSD → single-sided gauge-staked LP, 8-B6), lifting NAV-per-share;
> there is **no buy-xALPHA / no "+30% boost" distribution / no payout** (those legs are retired). The standalone
> raw-xALPHA *emission* incentive is a separate, deferred post-M1 program. Authoritative: `claude-zipcode.md §4.5.1`.

> **What this decides:** how Zipcode uses Hydrex — a **team-controlled ve(3,3) emission machine** — as a
> **time-limited, mostly-free customer-acquisition subsidy** for the szipUSD lending book, NOT as a yield or
> liquidity engine. We buy a cheap **governance floor**, point a gauge at our own pool to manufacture a headline
> APR, abstract the option complexity behind a **depositor-facing vault**, recycle the proceeds into **real
> loan-book AUM**, and **graduate off the subsidy in ~6 months** when HYDX bleeds out. Every figure is
> on-chain-verified (Base, Sourcify / `cast`, week 38 of emissions, ~2026-06-04).
>
> **The correction that reframed this doc:** Hydrex emissions are **not cashable at scale.** The HYDX/USDC pool is
> *net-draining* (measured −$156k over 90 days, no buy-side), and a **$0.01 strike floor** strangles the option
> below spot ~$0.015. So direct extraction is ≈ **break-even on the $89k entry** — the value is the **deposits the
> lure acquires** and the **votes that power it**, fueled by the *team's* bleed, not our balance sheet.
> Refs: `claude-zipcode.md §4.5.1` (the recycle sink / engine modules) + §11 (exit throttle), `tickets/bridge/8x-01-szalpha-wrapper-cct.md` (CCIP arb). *(The post-M1 closed-loop/POL/emission economics doc `treasury.md` was removed 2026-06-09 — to be re-authored.)* Memory: [[hydrex-gauge-architecture]],
> [[rubicon-fork-and-closed-loop]], [[supply-zap-and-resi-bond-bootstrap]].

---

## 1. Thesis — subsidy, not yield

Hydrex is a **Lynex/Thena fork** on **Algebra Integral** (Base). Its emission faucet (oHYDX) is large relative to
its tiny locked float, so vote power is *cheap*. We exploit that — but only for what it actually buys:

1. A **gauge** on our own xALPHA/zipUSD pool → a loud **headline APR** that pulls in deposits.
2. A **defended minority vote floor** → keep that gauge fed without paying bribes.
3. A **structured product** that converts the (un-cashable-at-scale) oHYDX into a clean USDC/xALPHA yield for
   depositors, and recycles the proceeds into the **loan book** (the real business).

What it does **not** buy: a yield stream, control of Hydrex, or a deep exit. The host is owned by a 3-person team
(§2). We are a **minority tenant strip-mining a free subsidy** for a 6-month window, then we **graduate** to the
standing szipUSD lending yield. Plan the whole thing as **acquisition spend with a hard expiry**, not a profit center.

---

## 2. Know your host — the verified landscape

Reverse-mapped from the live deployment (core contracts not open-sourced). Four findings define the host:

**2.1 62% of all emissions are an insider sink.** The top gauge (`0xb0eac8aa…`, 62.3% of votes, ~$5M/yr of
emissions) is on a pool of two tokens literally named **`SGT1` / `SGT2` ("SpecialGaugeToken1/2"), total supply 1
each** — a fake "black-hole" gauge. The whole flow is team-internal: **Safe A** (`0xd9e966a6…`, the *first* veNFT
minted) votes the sink → **Safe B** (`0x1ae3753d…`) collects the oHYDX → forwards to an **EOA** (`0x74266f2b…`)
that **hoards 8.9M oHYDX and growing**. So the team captures 62% of issuance and warehouses it.

**2.2 The team is a 2-of-3 multisig holding ~28% of supply.** Safe A is a Gnosis Safe (owners `0xEa1bf4…`,
`0x813F98…`, `0xB4d286…`); Safe B shares those signers +1. Combined the team controls **~24.7M HYDX-equivalent
(~28% of supply):** 7.57M locked + 8.26M liquid + 8.9M oHYDX. They sell via **OTC** (not the pool — which is why
the pool hasn't fully collapsed) and **burn** occasionally (144k HYDX burned in one recent week).

**2.3 The HYDX/USDC pool is net-draining — there is no buy-side.** Measured USDC reserve over 90 days:
$585k → **$429k (−$156k)**, while HYDX in pool rose — i.e. *net selling*. There is **no net buy demand to realize
emissions against.** (This corrects an earlier hand-wavy "$220–450k/yr absorbable" — measured reality is the
*opposite sign*.) Recent weeks have flattened ~$430k (thin equilibrium, not zero).

**2.4 The option has a $0.01 strike floor — you cannot bleed it to zero.** `strike = max(30% × 2h-TWAP, $0.01)`.
The floor binds below spot ~$0.033; the spread craters (70% → 50% at $0.02 → 33% at $0.015 → **0% at $0.01**) and
the option is **underwater below $0.01.** Plan for HYDX to bleed to **~$0.014–0.018**, where extraction dies. **Our
loop's profitability cutoff = $0.015** (user-ratified 2026-06-08): at $0.015 the ~33% gross spread still covers the
~2–3% sell-side slippage, so the borrow→exercise→sell→repay round-trip nets a profit; below it we **skip `exercise`**
and accrue oHYDX until a profitable epoch. ($0.01 is the mechanical dead floor — never reached; we stop at $0.015.) The
2h-TWAP also means fast dumping prices the strike off the *older, higher* average — fast selling self-punishes.

> **Implication:** the host is a team-steered faucet where 62% is pre-allocated to an insider sink, the exit pool
> is draining, and the option is floored. You can rent a slice of the remaining ~38% cheaply, but **do not depend
> on cashing it, controlling it, or it lasting.**

### 2.5 Contract address book (Base, chainId 8453)

| Contract | Address |
|---|---|
| HYDX (token, 18 dec) | `0x00000e7efa313F4E11Bfff432471eD9423AC6B30` |
| oHYDX (`OptionTokenV4`) | `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` |
| Voter (proxy → `VoterV5`) | `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b` → impl `0x03796788a91e521197e05865a55b2ee251148aa4` |
| VotingEscrow (veHYDX) | `0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1` |
| VE Token Lens | `0xF4d3fCA00640F5bEb7480AA113ED7B0C2c366866` |
| Minter (proxy → `MinterUpgradeableV3`) | `0xA7D64625F45548a19B2A19e28E7546bb2839003E` → impl `0xf0d683c701736a58e63f42c99aca1a4afbf93b8d` |
| EmissionSchedule | `0x5aAa65Af617FA50041325F46Ecee5613aafF2727` |
| NFPM / SwapRouter | `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86` / `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e` |
| ICHI Vault **Factory** / Deposit Guard | `0x2b52c416F723F16e883E53f3f16435B51300280a` (on-chain verified 2026-06-06: read from the guard's `ICHIVaultFactory()`) / `0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8` |
| ICHI admin Safe (NOT the factory) | `0x7d11De61c219b70428Bb3199F0DD88bA9E76bfEE` (Gnosis Safe, 7 owners — was mis-labeled "Vault Deployer") |
| **HYDX/USDC pool (deepest)** | `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2` |
| Team Safe A (sink voter) / Safe B (collector) / hoard EOA | `0xd9e966a6…50aF` / `0x1ae3753d…0311` / `0x74266f2b…ae03` |
| USDC / WETH | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` / `0x4200000000000000000000000000000000000006` |

### 2.6 Live parameters (week 38)

| Parameter | Value | Source |
|---|---|---|
| Epoch | 1 week (604,800s) | `Voter.getEpochDuration()` |
| Weekly emission `E` | **3.40M oHYDX → 2.0M tail** by ~wk 64 (−0.1M/wk) | `Minter.weekly()`, `EmissionSchedule` |
| Anti-dilution rebase | **7% → 0% by ~wk 64** (scheduled) | `Minter.calculate_rebase()` |
| Team skim | 4% (max 5%) | `Minter.teamRate()` |
| Total locked HYDX | **12.25M (~$556k)** — confirmed: `totalSupply − circulating = balanceOf(ve)`, exact | `HYDX.balanceOf(ve)` |
| 5 gauge types | PAIR_CLASSIC / ALM_ALGEBRA / ALM_ICHI_UNIV3 / ALM_GAMMA_UNIV4 / **MORPHO (accepts Euler ERC4626)** | `VoterV5.createGauge` |
| HYDX price | **$0.0452** | `pool.globalState()` |
| oHYDX strike | **max(30% × 2h-TWAP, $0.01 floor)** = $0.0134 now; **`exerciseVe` = free permalock** | `oHYDX.discount/getDiscountedPrice/getMinPaymentAmount` |
| HYDX/USDC pool | 16.09M HYDX + **$429k USDC**; dynamic fee 0.05%→0.75%; tickSpacing 60 | on-chain |
| Volume | ~$94.5k/24h | DEX agg |

> **`ve` power-unit note (resolved):** `totalSupply()` (~450M) is a cosmetic ~36.8× scaling, *not* a multiplier —
> it **cancels in ratios**. Size everything off **locked HYDX / 12.25M**. (Confirmed: the 62% sink wallet holds
> ~7.57M locked = ~62% of the float.) Ignore the "voting power" number entirely.

---

## 3. The three decoupled quantities

| | What | Status |
|---|---|---|
| **Entitlement** | veHYDX vote share → your slice of `E` | cheap, dilutes on a clock (§4) |
| **Extraction** | what the HYDX/USDC pool can absorb | **net-draining, capped, floored — not yours to grow** (§5) |
| **Sink** | xALPHA/zipUSD pool + the depositor product | endogenous; fed by extraction, doesn't feed back |

The earlier framing maximized extraction. **Corrected:** extraction is ≈ break-even and self-limiting; the leg
exists to (a) keep a gauge fed for the lure and (b) feed the loan book. Optimize for **deposits acquired**, not
USDC extracted.

---

## 4. Entitlement — vote-share sizing and the governance reality

**Share ≈ locked_HYDX / 12.25M.** A **$100k position (≈2.2M HYDX) → ~15.3%** of votes; vs the contestable
(non-sink) bloc you'd be **~1/3.** Diluting the team sink from 62% → 52% is a side effect, not control.

**You cannot win a power war — you're outgunned ~7:1.** Your 15% exists *only because the team's HYDX is unlocked.*
The instant you threaten them they `exerciseVe` their ~17M overhang: total locked 12M → ~29M, your share → ~7.5%,
and they out-compound you every week (52% emission vs your 15%). **They can't redirect *your* votes** (your gauge
always gets your share), but they can **dilute** you at will.

**So: defend a floor, don't seek dominance.** Lock enough to keep your gauge meaningfully fed (it powers the lure),
read as a committed partner, and accept minority status. Acquisition is via the **OTC deal (§9.4)**, never a
market buy into a $429k pool.

**Ownership of the dials:** **Treasury sets the target floor `s*`** (the minority share we defend) and the
auto-compounder **payout mode** (§6 / `auto-compounder.md` §6); the CRE bot enforces `s*` via the per-epoch
lock-vs-sell split and pages Treasury on the regime-change tripwire (`monitoring.md` §B).

---

## 5. Extraction — the binding constraint (corrected)

The exit ceiling is the **USDC side ($429k), net-draining**, *not* a number we set. Selling HYDX = the bleed.

- **No sustainable "absorbable/yr" figure exists** — net flow is *negative*. Realizable cash ≈ your competitive
  slice of whatever thin buy-flow appears, minus your own price impact. Treat it as **demand-gated and uncertain**,
  measured empirically (Swap-event net flow), never asserted.
- **Per-order risk is a slippage knob, not a market risk.** The option default condition is literally "does this
  order slip >70%" (you'd have to dump ~the whole pool at once). You size orders to a few % → never near it. The
  *only* real governor is **cumulative throughput** (the bleed), set at the operation level.
- **Plan assumption: HYDX bleeds to ~$0.014–0.018** over ~6 months (§2.4 floor). Model declining per-token $ down
  to there; beyond it the option is dead.
- **Fill curve (active-tick approx; team-quoted ~11% slippage on a $100k order implies the real curve is ~2×
  deeper than this):** +1%≈$4k, +5%≈$20k, +10%≈$39k, +25%≈$94k, +63%≈$222k. Bot/dashboard must enumerate
  `pool.ticks()` for the exact multi-tick curve.

**Levers we control:** order size, exercise-vs-burn split, soft-bleed cap. **Levers we don't:** HYDX price,
external demand. We are structurally **long HYDX demand even as the seller** — which is why §9.3 (soft bleed) and
Austin's BD matter more than execution tricks.

---

## 6. The depositor surface — the structured-product vault ("auto-compounder")

The product that makes Hydrex usable: **"Deposit your xALPHA, earn [trailing-7-day realized] APR in USDC"** —
depositors never see an oHYDX. The vault robot:

1. Farms oHYDX (gauge on the deposited LP / position).
2. **Exercises from a cycling USDC working-capital buffer** (NOT a flash loan — that forces an atomic market sell
   at worst impact; NOT LP-collateral leverage against an *open/permissionless* oracle — the **CRE-permissioned**
   borrow below is the safe form, since permissioning removes the manipulation surface).
3. **Range-sells** the HYDX over time (good execution, §9).
4. Replenishes the buffer, distributes net USDC by vault share.

**Strike-financing — the CRE-permissioned borrow (optional, safe):** if you want capital efficiency over an idle
buffer, source the 30% strike via an Euler borrow **restricted to the CRE workflow only.** Permissioning kills the
external oracle-manipulation exploit, and the 30% strike makes it **self-collateralizing** — you borrow 30% to
unlock 100%, default needs >71% single-order slippage (which you never place). **Fund it from your own
treasury/buffer, never depositor USDC** — keep the lending book walled off from the dump engine.

**Rules:** (a) **cap vault TVL to the bleed** — an uncapped vault farms a firehose of oHYDX, dumps it, and kills
its own APR; (b) advertise **trailing-realized** USDC, never a projection — it's a *wind-down* yield funded by
managed-dumping HYDX, and the number degrades visibly; (c) the abstraction is for the *user* — **you** must keep
sizing to the pool's absorption.

---

## 7. The recycle sink — turning the bleed into real AUM + NAV accretion

A value-creating recursion (the single sink, 8-B10 `RecycleModule`; spec `claude-zipcode.md §4.5.1`). Per HYDX sale
of $X:

```
HYDX → $X USDC → DEPOSIT into the credit warehouse (senior backing, real AUM +$X)
              → mint $X (·scaleUp) zipUSD, backed 1:1 by the just-deposited USDC
              → recycle that zipUSD into the basket as single-sided gauge-staked LP (8-B6)
              → szipUSD NAV-per-share accretes for every holder
```

**Why it's sound (and not the death-spiral):** the fuel is **free HYDX-extracted value (the team's bleed), not our
reserves.** Every zipUSD is minted *after* a real USDC deposit → **fully backed by construction** (no dilution,
backing scales 1:1). The USDC **stays as senior backing** (over-collateralizing zipUSD / funding lending capacity)
and the recycled zipUSD becomes real basket assets (LP) → the depositor's return is **NAV accretion**, realized on
exit at NAV. There is **no zipUSD→xALPHA buy and no "+30% boost" distribution** — those legs were retired in the
single-sink rework.

**Guardrails (the line you don't cross):**
1. **Only ever recycle HYDX-extracted (free) value.** Real reserves / unbacked minting → spiral. Free money → fine.
2. **Watch origination throughput, not backing.** The loop pumps real new capital into the warehouse faster than
   organic deposits — make sure loan origination keeps pace or it's idle drag / credit-quality creep. (The real
   constraint.)
3. **Time-limited.** The HYDX bleed funding it ends in ~6 months; the NAV accretion it produces is trailing-realized,
   never a projected APR.

---

## 8. Posture — the dutiful auto-locker (soft bleed, partner not parasite)

Your extraction and the team's interests are **short-term adversarial** (your selling craters the token they
sell), but you depend on them (gauge whitelist, 52% of votes, the demand Austin brings). So run the **soft**
version:

- **Default the un-sold surplus to `exerciseVe` (permalock).** Compounds your vote floor, signals commitment,
  reads as non-adversarial. The same oHYDX can't be both locked and sold — split the stream deliberately: enough
  to ve to hold your floor, the rest soft-sold within caps.
- **Bleed gently enough not to break Austin's chart.** A falling price is an impossible BD deck; aggressive
  dumping sours the relationship and invites dilution.
- **You need Austin to bring *demand* (buyers, LPs), not more extractors** (more farmers = more sellers fighting
  you for the same $429k pool). Your interests align on *keeping HYDX afloat* — as long as you don't dump faster
  than he can sell.
- **The team-conversation framing:** "We buy, hold the votes, run a capped soft extraction that won't break your
  chart, and help pitch the model — in exchange for the gauge + emissions direction." Partner, not parasite.

---

## 9. Execution

**9.1 Range-sell ladder.** Rest exercised HYDX as **single-sided CL above spot** (`NFPM.mint`, range
`[P_low ≥ spot, P_high]`) — a fee-earning limit-sell that converts on up-moves and earns the dynamic Algebra fee
(more during the volatility you sell into). **Prime directive: sweep realized USDC at each fill** (range orders
reverse on retrace until withdrawn); re-mint above new spot. Hand-set ranges earn **fees only** (no oHYDX); gauge
emissions need an ICHI/Gamma ALM.

**9.2 Regime switch.** UP/spike → ladder fills → szipUSD. FLAT/DOWN → ladder idle → `exerciseVe` → vote floor.
Never dump into weakness.

**9.3 Soft-bleed caps (the governors):** per-order slippage ≤2–3%; per-epoch volume ≤1–2% of pool USDC
(~$4–9k/epoch); **taper auto-sell from $0.033 → begin shrinking loop size at the ~$0.018 amber tier → fully halt at
the $0.015 profitability cutoff** (§2.4, user-ratified 2026-06-08); never sell faster than the 2h-TWAP follows;
emergency market-sell only.

**9.4 The OTC entry — conditional on the gauge.** Team offer: **market-buy $100k notional** of HYDX; the buy
incurs **~11% (~$11k) slippage** on the $429k pool; the team **OTC-comps that ~$11k** (make-up HYDX at spot) so we
still receive the full **~2.2M HYDX (~15.3%)** position. **Net cost basis ≈ $89k** — i.e. the team *absorbs the
slippage* to secure our buy (the $100k is notional; the $89k is what we're out after the comp). The 11% also
confirms the pool is ~2× deeper than the active-L estimate.
> **Term-sheet item (pin before signing):** the **comp mechanism** must be explicit — OTC make-up tokens vs. cash
> rebate — and it must deliver the **full ~2.2M HYDX**. If the comp is only partial, the net cost rises toward
> $100k and the §11 break-even shifts; do not assume the $89k until the mechanism is in writing.

**Do not execute without a live gauge.** Verify on-chain *before* wiring: `Voter.gauges(ourPool) != 0` ∧
`isGauge` ∧ `isWhitelistedPool[ourPool]` ∧ `isWhitelisted[xALPHA]` ∧ `isWhitelisted[szipUSD]` — all four are
governance actions, not promises. Sequence: gauge live → verify → buy → vote. Bundle emissions/bribe terms while
you still have the leverage (they want your buy more than you need their comp — you provide the pump + pool refill
their ~28% overhang benefits from).

---

## 10. Bot + dashboard

**Bot** (per epoch + triggers): Monitor (`NFPM.positions`, accrued) → Regime classifier (EMA + fill%) →
Range Manager (`mint`/`increaseLiquidity`) → Harvester (`decreaseLiquidity`/`collect`, fill-lock + retrace-guard)
→ Rebalancer (USDC → loan book / szipUSD; re-lock to hold floor; surplus → ladder or `exerciseVe`) →
Voter (`Voter.vote` each epoch — votes reset weekly). CRE owns the optional strike-borrow. Safety: slippage caps,
per-epoch ceiling, multisig/timelock on the silo.

**Dashboard / surveillance — full spec in `monitoring.md`.** Read-only multicall + archive + event indexer over:
**Entitlement** (`s`, locked float, `E`); **Race** (total weight, `g`≈0.4%/epoch, new-vs-improved locks);
**Whale** (team lock-power, liquid overhang, oHYDX hoard, sink weight — the **regime-change tripwire**);
**Extraction** (USDC depth, tick-enumerated fill curve, measured net Swap flow, price/2h-TWAP); **Floor**
(effective spread, TWAP-gap, distance-to-$0.01, profitability-halt); **Clock** (rebase, decay, weeks-to-sunset);
**Backing** (zipUSD warehouse over-collateralization, origination throughput; szipUSD NAV-per-share); **Product**
(vault TVL vs bleed cap, trailing-realized APR). Trigger panel maps each amber/red to a §9 action; the red
tripwires (team lock-power jump, backing < 1) page Treasury.

---

## 11. Economics + the graduation

**Direct extraction ≈ break-even** on the ~$89k entry (net of the §9.4 slippage comp; rises toward $100k if the
comp is only partial) over the 6-month window (front-loaded; emission 3.4M→2.0M, rebase 7%→0%, price
$0.045→~$0.015, exit-bound + floored). The cash is *not* the win.

**The win, in order:** (1) **deposits** — real USDC into the loan book, acquired by the lure; (2) **POL depth** +
the vote floor; (3) the **recycle sink** pumping HYDX-extracted USDC into warehouse AUM + szipUSD NAV. All fueled by the *team's* bleed.

**Graduation (~6 months):** when HYDX hits ~$0.014–0.018 the option dies, the boost evaporates, and the team will
likely have diluted your votes. **What stands: the loan book and the deposits.** Hydrex was the cheap acquisition
channel; the standing **~5% real szipUSD base** (lending spread + xALPHA) retains whoever the subsidy brought in.
Lending-book performance is the only thing under all of this that's real — that's where the scrutiny goes.

---

## 12. Risk knobs

1. **Don't depend on cashing emissions** — exit is net-draining + floored; size as acquisition spend.
2. **Governance is unwinnable at scale** — defend a floor, stay a committed minority; the team is 7:1.
3. **Governance dependency** — the gauge whitelist is theirs to grant; entry is conditional on it (§9.4).
4. **Front-loaded** — edge is weeks 38–64; re-budget the lock-vs-sell split as the rebase sunsets.
5. **Boost loop discipline** — free HYDX value only; watch origination throughput; backing is fine *by
   construction* (deposit precedes mint).
6. **Reflexive markdown / inventory** — every HYDX sold marks down your own veHYDX; `exerciseVe` regime is the hedge.
7. **The host could change** — team holds ~28% + 52% votes + the sink; they can redirect, dilute, or dump the
   overhang. Monitor `totalWeight` growth and the team Safes for regime change.

---

## 13. Open items

- [ ] **Gauge whitelist** for xALPHA/zipUSD (or Euler-ERC4626 MORPHO gauge) — the gating dependency. Verify §9.4 conditions on-chain.
- [ ] **Tick-enumeration fill-curve** + **measured net Swap flow** (replace estimates with data).
- [ ] **Structured-product vault** — single-sided ICHI + buffer/CRE-borrow strike financing + trailing-APR + TVL cap.
- [ ] **recycle sink** wired with the "free-value-only" + backed-by-construction invariants (`claude-zipcode.md §4.5.1`, 8-B10).
- [ ] **Bot + dashboard** (§10).
- [ ] **OTC term sheet** — slippage comp + gauge + emissions/bribe terms, executed atomically with the buy.

## Sources

On-chain (`cast`, Base, week 38): Voter `0xc69E…`, Minter `0xA7D6…`, EmissionSchedule `0x5aAa…`, ve `0x25B2…`,
oHYDX `0xA113…`, pool `0x51f0…`, team Safes `0xd9e9…`/`0x1ae3…`/`0x7426…`. Verified source (Sourcify): `VoterV5`,
`MinterUpgradeableV3`, `OptionTokenV4`. SDK `@hydrexfi/hydrex-sdk` (`LendingGauge` Euler/Morpho routing). 90-day
USDC reserve trajectory via archive reads. Companions: `auto-compounder.md` + `monitoring.md`.
