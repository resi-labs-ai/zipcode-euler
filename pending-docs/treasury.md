# treasury.md — Closed-loop economics: xALPHA incentives, szipUSD, POL, the depositor product, and the rewards validator

> **SUPPLY-SIDE REDESIGN (2026-06-05) — read this doc through these deltas (authoritative: `claude-zipcode.md`
> §2/§4.5/§11/§17):**
> - **The LP / POL pair is `zipUSD/xALPHA`** (not szipUSD/xALPHA). The stable leg is **zipUSD — the clean,
>   *yieldless* $1 reference** (better than szipUSD, which carried lending solvency + the duration throttle). The
>   "both legs yield-bearing / triple-productive" framing is superseded: zipUSD is yieldless by design.
> - **`sdVAULT` collapsed into `szipUSD`** — one junior token: deposit **zipUSD (or xALPHA) single-sided → the
>   freezable `szipUSD` vault share**. Where this doc says the vault/share, read **szipUSD**.
> - **The real lending yield (APR + fees) is the PROTOCOL's** — privatized into this treasury strategy that buys
>   xALPHA. Depositors are **subsidized by xALPHA + the HYDX/USDC engine, NOT by the lending yield**. So the
>   "~5% szipUSD base = lending spread" framing below is superseded — the depositor's return is xALPHA.
> A full line-by-line economic reconciliation of this doc is a tracked post-M1 follow-up; the deltas above govern.

> **What this decides:** how Zipcode spends its subnet-alpha incentive budget so the spend **compounds the
> protocol** instead of leaking to dumpers — via a **rewards validator** emitting a yield-bearing wrapped token
> (xALPHA), a **closed loop** routing the only fast exit through **szipUSD**, **protocol-owned liquidity (POL)**
> that turns sell pressure into discounted accumulation, a **depositor-facing product** that abstracts the
> complexity, and a **Hydrex acquisition subsidy** (own doc) that strip-mines a third party's emissions to bait
> deposits. **The north star: every loop must end in real USDC in the lending book.** That book — not any token
> loop — is the only thing that survives the subsidies (§7).
> This doc is **economics/treasury**: budgets, yield stacks, exit dynamics, peg arb, the recycle loops, risk knobs,
> and canonical-vs-fork *rationale*. Build details: `bridge/xalpha-bridge-impl.md`. Hydrex execution + the
> acquisition-subsidy reframe: **`hydrex.md`**.
> Refs: `bridge/xalpha-bridge-impl.md`, `bridge/xALPHA-apr.md` (CRE APR workflow), `hydrex.md` (Hydrex leg),
> `claude-zipcode.md` (supply zap, szipUSD, §11 exit throttle), `vision.md`.
> Memory: [[supply-zap-and-resi-bond-bootstrap]], [[zipcode-subnet-role]], [[lien-perfection-proof-and-risk]],
> [[rubicon-fork-and-closed-loop]], [[hydrex-gauge-architecture]].

## 1. The thesis

Raw subnet-alpha incentives are **existentially priced and self-consuming**: APR = `alpha emission × alpha price ÷
TVL`, and both multiplicands fall when recipients sell — selling drops the price *and* (post-Nov-2025 net-flow
rules) drops the emission rate. Paying in raw alpha funds your own exit-liquidity crisis.

The closed loop fixes this with three structural choices:
1. **Emit a yield-bearing wrapper (xALPHA), not raw alpha** — the staked pile keeps earning while it backs the reward.
2. **Make the only fast exit go through szipUSD** — dumping the reward market-buys our own credit token.
3. **Own the venue (POL)** — sell pressure accrues to *us* as discounted, NAV-redeemable inventory.

Layered on top: a **depositor product** (§4.6) that converts the messy multi-token rewards into a clean headline
yield, and a **Hydrex subsidy** (`hydrex.md`) that funds part of that headline with a *third party's* inflation.
**All of it is scaffolding for one foundation — the USDC lending book.** When the subsidies expire (~6 months),
the standing ~5% szipUSD base is what retains the deposits the scaffolding acquired.

## 2. Canonical vs fork — the economic decision

- **Fork (`szALPHA`) buys a structural closed loop.** A proprietary wrapper whose venues we fully control: pair it
  **only** with szipUSD, never seed another pair, control the bridge → "the only liquid exit is szipUSD" is true
  **by construction**, not by outspending. Plus end-to-end ownership of validator, lock policy, fee routing
  ([[zipcode-subnet-role]]). Single strongest reason to fork.
- **Canonical xAlpha is cheaper but leaks.** One fungible ERC-20 — we **cannot prevent** a competing venue (e.g.
  a seeded xAlpha/USDC pool on Aerodrome). The loop degrades from *structural* to *whoever-is-deepest*. Whether
  such a pool exists depends on GTV's cohort program (§6).
- **Recommended sequencing:** prototype on canonical (zero contract work) to validate mechanics, resolve gates in
  parallel, **fork once committed to structural control.**

## 3. The closed-loop mechanism

**3.1 Rewards validator.** Route the monthly budget (§4) into **our own validator**, emit the yield-bearing
wrapper. The staked pile (a) backs the wrapper, (b) earns validator take/dividends, (c) raises stake weight →
emission share. A compounding reserve.

**3.2 Pair = xALPHA/zipUSD on Hydrex.** Both legs yield-bearing. szipUSD sourced capital-efficiently:
USDC → Zipcode lending → szipUSD receipt → seed the pool. Triple-productive quote leg — USDC funds the lending
book, szipUSD earns lending/xALPHA yield in-pool, the LP earns swap fees + HYDX emissions. **Caveat:** the "stable"
leg is **szipUSD, not USDC** → inherits Zipcode lending solvency + the duration throttle. Not a clean USD
reference. **And the HYDX-emission leg is not cashable at scale** (`hydrex.md` §5) — book it as an acquisition
lure, not realizable yield.

**3.3 Forced re-buy.** If xALPHA's only liquid venue is xALPHA/zipUSD, dumping it **market-buys szipUSD** — itself
throttled by duration holds. Holds **only** while we are the dominant venue (structural under fork; a spend under
canonical).

**3.4 The two exits.** **Swap exit** (fast) → forced through szipUSD (fork locks this). **Redeem exit** (xALPHA →
unstake → alpha → bridge → subnet AMM) → bypasses szipUSD, dumps on our subnet pool, throttled. The subnet AMM is
the **ultimate sink**, with the duration-bond freeze (`claude-zipcode.md` §11) as the throttle.

**3.5 Peg arbitrage as protocol revenue.** xALPHA below NAV → protocol buys the discount, redeems at NAV (clean —
dTAO has no unbonding), closes the gap. Permissionless, self-healing; our edge is speed/size. Cost basis =
dual-AMM slippage + CCIP latency. **Distinct from the boost loop (§4.7):** arb buys *below NAV* to capture a
discount (value-positive); the boost loop buys *to source tokens* with free HYDX value (acquisition spend). Keep
them separate.

## 4. Incentive program: issue raw xALPHA + own the POL

**Preferred shape.** Pay the incentive as **raw xALPHA**; protocol **owns the xALPHA/zipUSD POL** on Hydrex —
moving the multi-token yield stack off the depositor onto the balance sheet.

**4.1 Budget — two dials.**
- **Emission budget:** ~**$100k/mo max**, USD-denominated, paid in xALPHA at spot. Headline spend.
- **Redemption budget = POL zipUSD depth.** *This* is the exit liquidity: a depositor selling xALPHA draws
  szipUSD from the POL, ultimately against the USDC lending book. **POL zipUSD depth must track cumulative
  emitted-but-unsold xALPHA.** If outstanding rewards exceed depth, "Current APR" becomes un-realizable — headline
  collapse. **This ratio is load-bearing, not the $100k.** Now stressed by *two* things — xALPHA exit *and* the
  boost loop (§4.7) — track both.

**4.2 Depositor sees a clean single-asset APR**, valued at spot:
`Current APR = (xALPHA emitted/yr × alpha price) ÷ TVL`. Present **floor + variable**, never blended:

```
szipUSD supply
  Base APR        4.8%   ← USD, underwritten (lending spread + xALPHA coupon)   [the only real, surviving number]
+ Incentive APR  27.3%   ← variable, xALPHA at current alpha price            [degrades visibly]
= Current APR    32.1%   ← updates live on-chain (CRE workflow)
```

Only the base is underwritten; the incentive is existentially priced and **must degrade visibly**, not "miss" a
fixed number. Most depositors sell the xALPHA.

**4.3 The combined yield stack is the POL return, not the depositor's** (USD-normalized, weight-adjusted):

| Source | Applies to | USD-on-USD |
|---|---|---|
| xALPHA NAV yield (~32% alpha-denom) | xALPHA leg (½V) | `0.5·32% ≈ 16%` ± alpha drift |
| szipUSD base (lending + xALPHA) | szipUSD leg (½V) | `0.5·~5% ≈ 2.5%` |
| Swap fees | full V | `fee · vol/TVL` (recaptured — we own LP + veNFT) |
| oHYDX emissions | full V | `gauge_APR · δ` — **δ = option discount AND floored AND exit-capped** (`hydrex.md` §2.4/§5); book conservatively |
| Impermanent loss | full V | **negative** |

`Combined POL APR = 16% + 2.5% + fees + (oHYDX·δ) − IL ± alpha drift`. Corrections: (a) the 32% hits only the
xALPHA half; (b) oHYDX is an **option, floored at $0.01, not cashable at scale** — nearly worthless as *cash*,
valuable only as ve/lure; (c) volatile/stable pair carries real IL + yield leakage.

**4.4 Why POL is the right holder.** Every "cost" flips to a benefit on our balance sheet: **IL → discounted
accumulation** (exiters dumping xALPHA = we buy back our incentive, still earning ~32%, NAV-redeemable);
**accumulated xALPHA → compounding stake** (redeem → restake → emission share, §3.1); **fees + oHYDX accrue to us.**

**4.5 POL is how we *become* the dominant venue** — §3.3's forced re-buy with us as the structural re-buyer. We
don't outspend for depth; we **are** the depth.

**4.6 The depositor product — the structured-product vault ("auto-sodomizer").** Full spec: `auto-sodomizer.md`.
The user-facing surface: **"Deposit xALPHA (or zipUSD single-sided), earn [trailing-realized] yield"** —
depositors never touch oHYDX/options/gauges. A CRE-driven vault farms the gauge oHYDX, exercises from a cycling
buffer, range-sells/recycles, and pays out. It does three jobs: (1) **abstracts complexity** (adoption); (2)
**converts xALPHA dump-pressure into LPs** (single-sided deposit instead of a sell); (3) **routes proceeds into
the loan book** (§4.7). The yield is a **wind-down** funded by HYDX bleed — advertise trailing, cap TVL to the
bleed (`hydrex.md` §6).

**4.7 The xALPHA boost loop — recycling the bleed into real AUM.**

> **SUPERSEDED (2026-06-08) — read against `claude-zipcode.md §4.5.1`.** The boost loop's *last two legs* are
> retired: there is **no** `swap zipUSD → xALPHA` and **no** "+30% xALPHA boost distribution." The first two legs
> stand — HYDX sale → USDC **deposited into the lending book** (real AUM) → **mint backed zipUSD 1:1** — but the
> zipUSD is now recycled **into the auto-sodomizer basket** (single-sided LP, gauge-farmed), lifting **NAV-per-share
> for every depositor** instead of being swapped to xALPHA and handed out. The depositor's return is NAV accretion,
> not an xALPHA boost. (The standalone raw-xALPHA emission incentive program, §4.1, is a separate, deferred matter.)

A value-creating recursion that turns the
Hydrex bleed into loan-book growth *plus* a louder lure:

```
HYDX sale → $X USDC → DEPOSIT into lending book (real AUM +$X)
                    → mint $X zipUSD (backed 1:1 by the just-deposited USDC — BY CONSTRUCTION)
                    → swap zipUSD → xALPHA on OUR POL (swap fee recaptured)
                    → distribute xALPHA as a "+30%" boost on a token depositors already receive
```

- **Backed by construction, not dilutive.** Deposit precedes mint → every new szipUSD has fresh USDC behind it;
  backing scales 1:1 with supply. The earlier "inflation stresses the peg" concern was wrong — **the USDC is real
  and stays in the book.**
- **Not the death-spiral, because the fuel is free.** The xALPHA buy-side is funded by **HYDX-extracted value (the
  team's bleed), never our reserves.** That distinction is the whole game (guardrail below).
- **Guardrails:** (1) **only free HYDX-extracted value buys xALPHA** — unbacked minting / spending real reserves to
  prop xALPHA = spiral, forbidden; (2) **watch origination throughput** — the loop pumps real capital into the
  book faster than organic deposits; ensure loan origination keeps pace or it's idle drag / credit creep (the real
  constraint, not backing); (3) **time-limited + reflexive** — the boost rides xALPHA→HYDX, evaporates in ~6
  months; advertise trailing-realized.

## 5. Risk knobs (these carry the design)

1. **Dominant-venue requirement.** The loop leaks the moment a competing xALPHA venue has depth. Fork + POL makes
   it structural; canonical makes it a spend. **Decide first.**
2. **Duration-lock vs subnet absorption.** szipUSD's ultimate exit lands on the subnet alpha pool (§3.4) → every
   exit is alpha sell pressure → lower subnet emissions (reflexive). Cap **max releasable szipUSD/epoch < subnet
   alpha-absorption rate**, or peg defense becomes an emission spiral. The lock also governs **POL zipUSD
   depletion** *and* the boost-loop inflow. Load-bearing (`claude-zipcode.md` §11).
3. **Validator stickiness vs redemption liquidity.** `lock_stake` (~365d decay) makes the pile sticky but locked
   alpha can't service redemptions/arb. Target a reserve ratio: bulk locked, a liquid buffer unlocked.
4. **Reflexive token triangle — and the Hydrex host risk.** Headline APR couples to **alpha**, **HYDX**, and
   **zipUSD**. Keep szipUSD's *floor* on real revenue (lending + xALPHA); alpha/HYDX are *topping* that **expire**.
   On Hydrex specifically (`hydrex.md`): treat it as a **time-limited acquisition subsidy, not yield** — emissions
   aren't cashable (net-draining pool, $0.01 strike floor); the host is **team-controlled** (one 2-of-3 multisig
   votes a 62% insider sink and holds ~28% of supply + 52% of votes); we are a **minority tenant** who **cannot win
   a vote war (7:1)**. So: **defend a vote floor, run a soft/capped bleed that doesn't break the team's narrative,
   stay a partner, and graduate off it.** Never depend on HYDX for a number that must survive.
5. **POL inventory concentration.** POL goes long xALPHA hardest when alpha is weakest. Acceptable only because we
   are long our own subnet and NAV-redeem + restake — concentration of existing risk, not new.
6. **Owner/upgrade centralization** (fork only). UUPS + owner controls = trust surface; govern with timelocks.
7. **Boost-loop discipline** (§4.7). Free HYDX value only; origination must absorb the inflow; backing is fine by
   construction.

## 6. Open commercial gate: GTV pairing terms

Decides canonical-vs-fork. Does cohort onboarding let us bring **szipUSD** as the pairing instead of taking a
seeded **USDC** pool? **Yes** → canonical can run the loop (residual: permissionless third-party pools). **USDC
mandated** → fork. (Technical gate — CCT registration on chain 964 — in `bridge/xalpha-bridge-impl.md` §4.)

## 7. The foundation — the lending book is the only real thing

Everything above is **customer acquisition**. The thing it acquires, and the only thing that survives the
subsidies, is **USDC deposits funding the loan book.** Reference economics: **$10M deployed = 100 lines × $100k ×
0.7%/30d ≈ $852k/yr (~8.5% gross)** → ~5% net szipUSD base after defaults/servicing/xALPHA/protocol spread. That ~5%
is the **only underwritten, perpetual number** in this entire document.

**The honest hierarchy of value:** real loan yield (foundation) > deposits acquired (the prize) > governance/POL
(durable, cheap) > xALPHA incentive (your spend, loop-mitigated, expires) > HYDX emissions (free, not cashable,
expires in ~6 months). **Year-one is a deliberate subsidy loss** (~$1.2M/yr xALPHA gross vs ~$852k/yr book
revenue) — justified only if **retention is real**, which routes entirely through **loan-book performance and
origination quality** (the RWA/xALPHA/secondary-sourcing question). That is where the scrutiny belongs now that the
token mechanics are solved.

## Sources

- Bittensor dTAO emission rules (net-flow, post-Nov-2025); no unbonding; `lock_stake`/`unlock_stake` decay.
- Subnet 46 (Zipcode/xALPHA) emission split + price — taomarketcap SSR, CoinGecko xALPHA/SN46 (sizes the ~32% NAV yield).
- GTV/PRNewswire launch — cohort liquidity, Aerodrome xAlpha/USDC seeding (canonical-leak basis).
- `hydrex.md` (Hydrex leg, on-chain-verified), `auto-sodomizer.md` (the depositor product), `bridge/xalpha-bridge-impl.md`.
