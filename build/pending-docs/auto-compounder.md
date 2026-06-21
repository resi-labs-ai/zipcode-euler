# auto-compounder.md — Structured-product vault: oHYDX→yield abstraction (design narrative)

> **Disposition:** forward input for **CRE-05** (harvest-loop policy) + **FE-04** (trailing-realized APR display).
> Dies when 8-B11/8-B12 land (`build/tickets/PROGRESS.md` → Deletion triggers). The on-chain engine modules (8-B5…8-B10) are BUILT — their spec
> is `build/wires/` + `claude-zipcode.md §8.7`; older `§4.5.1` refs resolve there.

> **What this builds:** the depositor-facing vault that makes the Hydrex leg usable. Surface: **"deposit
> single-sided (xALPHA or zipUSD), earn a [trailing-realized] yield"** — depositors **never see an oHYDX, a
> strike, or a gauge.** Under the hood a CRE-driven robot farms gauge oHYDX, exercises it **via a
> self-collateralizing borrow loop (the LP is its own working capital)**, **market-sells** the HYDX within the
> soft-bleed caps, and **recycles** the proceeds into the basket — backed zipUSD → single-sided gauge-staked LP →
> **NAV-per-share accretion** (the single sink; no payout, no xALPHA buy, no boost). It is a **HYDX-bleed-funded yield** — designed to abstract complexity, convert
> xALPHA dump-pressure into LPs, and feed the loan book.
>
> **Status / where the build spec lives.** This file is the design **narrative** (rationale, economics, the
> failure-mode→invariant map). The canonical, contract-cited build spec is **`claude-zipcode.md` §4.5.1** (engine
> modules **8-B5…8-B13**) — build tickets are authored from there, not from here. The supply-side token model is
> locked in `claude-zipcode.md` §2/§4.5/§11/§17 and assumed throughout: **the vault IS `szipUSD`** (one junior
> ERC-4626 share); **depositors deposit `zipUSD` or `xALPHA` single-sided** and receive `szipUSD`; the **LP is
> `zipUSD/xALPHA`** (clean, yieldless $1 leg); real lending yield is the **protocol's** (it over-collateralizes
> zipUSD in the credit warehouse) and the depositor's return is **NAV accretion** — the HYDX-vamp free value
> recycled into the basket (single sink, 8-B10), realized on exit at NAV, plus the §11 Duration-Bond premium.
> Refs: `hydrex.md` (the Hydrex leg, exit constraint, soft-bleed caps), `claude-zipcode.md §4.5.1` (the engine modules / recycle sink), `monitoring.md` (surveillance
> — TVL cap, profitability-halt, backing feeds),
> `tickets/bridge/8x-02-xalpha-apr-cre.md` (CRE APR pattern). Memory: [[hydrex-gauge-architecture]].

---

## 1. Purpose & non-goals

**Purpose.** Convert the un-cashable-at-scale, option-shaped, gauge-gated oHYDX reward into a **single clean number
paid in a token the depositor already holds**, while (a) maximizing adoption via abstraction, (b) turning xALPHA
sellers into LPs, and (c) feeding net proceeds into the loan book.

**Non-goals (hard).** It is **not** a leverage product, **not** a perpetual yield, **not** a way to extract more
than the HYDX pool absorbs. It must **never**: market-dump beyond the soft-bleed caps; put depositor principal at
risk (the strike borrows un-utilized warehouse USDC **over-collateralized by the LP and repaid each loop**, §5, so
principal is never the counterparty); use depositor USDC to buy xALPHA; mint unbacked zipUSD; or advertise a
projected (vs realized) APR. Every one of those is
the failure mode the design exists to prevent.

---

## 2. Deposit surface & roles

| Role | Action | Receives |
|---|---|---|
| **Depositor** | single-sided deposit of **xALPHA** *or* **zipUSD** | the **szipUSD** vault share (ERC-4626) |
| **Vault (szipUSD Safe)** | holds the basket and its **ICHI single-sided** zipUSD/xALPHA LP, **gauge-staked** | oHYDX emissions + swap fees |
| **CRE robot** | the only permissioned operator (harvest, exercise, sell, recycle) | — |
| **Protocol treasury** | receives loan-book USDC + the lending spread/fees (the strike loop borrows the warehouse's un-utilized USDC, NOT treasury) | — |

- **Single-sided in (ICHI):** a depositor holding xALPHA deposits it directly — *not a sell.* This is the
  dump-pressure→LP conversion. zipUSD single-sided is symmetric. ICHI factory `0x2b52c416…`, deposit guard
  `0x9A0EBEc4…` (`hydrex.md` §2.5; the old `0x7d11De61…` was a mis-labeled Gnosis Safe, not the factory).
- **Vault share = ERC-4626** so it is composable downstream (collateral, etc.) — but **do not list it as Euler
  collateral against a manipulable oracle** (`hydrex.md` §6); that's a separate, gated decision.
- **TVL is capped** (see §7). Deposits gate (`maxDeposit` → 0) when the vault's farmed-oHYDX run-rate would exceed
  the HYDX pool's absorption.

---

## 3. Architecture

```
        depositor (xALPHA/zipUSD)
                 │ deposit
                 ▼
        ┌─────────────────────┐         gauge oHYDX + fees
        │  szipUSD Safe        │◀────────────────────────────┐
        │  basket + ICHI LP,   │                             │
        │  staked in gauge     │                             │
        └─────────┬───────────┘                             │
                  │ CRE harvest                             │
                  ▼                                         │
        ┌─────────────────────┐  unstake slice  ┌───────────┴────────────┐
        │  CRE robot (only     │───────────────▶│ self-collateralizing   │
        │  permissioned op)    │  collateralize  │ borrow loop (§5):      │
        │  exercise→market-sell│◀───────────────│ EVK escrow LP →        │
        │  →repay→re-stake     │  ~30% strike    │ borrow USDC (resting)  │
        └─────────┬───────────┘                 └────────────────────────┘
                  │ free value (USDC, residual above strike+interest)
        ┌─────────▼───────────────────────────────────┐
        │  Recycle sink (§6 — the single sink, 8-B10)   │
        │   →deposit USDC into the credit warehouse     │
        │    (senior backing / lending capacity ↑)      │
        │   →mint backed zipUSD into the basket         │
        │   →8-B6 single-sides it into gauge-staked LP  │
        │   →szipUSD NAV-per-share accretes             │
        └──────────────────────────────────────────────┘
```

**The CRE robot is the only writer.** Everything that touches the borrow facility, the market-sell, and the
recycle is permissioned to the CRE workflow address. This is what makes the revolving borrow safe (§5);
depositor principal is protected by the LP collateral on the strike borrow.

---

## 4. The harvest cycle (core loop, per epoch + on triggers)

1. **Claim** gauge oHYDX + fees to the basket.
2. **Classify regime** (price vs short EMA): `UP | FLAT | DOWN` (`hydrex.md` §9.2).
3. **Split the oHYDX** per the regime + the vote-floor policy (vote-floor first, inv. 8):
   - a slice → `oHYDX.exerciseVe()` (free permalock) to **defend the vote floor** (`hydrex.md` §4/§8);
   - the rest → the sell path (UP/FLAT) or *also* to ve (DOWN regime — never dump into weakness).
4. **The self-collateralizing strike loop** (§5) for the sell slice — one ordered process:
   - a. `gauge.withdraw(slice)` — unstake the LP slice (emissions on it pause until re-staked).
   - b. post the slice as EVK escrow collateral; **borrow** the ~30% strike from the **farm utility borrow vault** (JIT-funded from the warehouse's un-utilized resting USDC).
   - c. **profitability-cutoff pre-check** (skip if HYDX < $0.015 → route those tokens to ve, `hydrex.md` §2.4; $0.018 = amber/taper-start); then
     `oHYDX.exercise(amount, maxPayment, recipient[, deadline])` (prefer the deadline overload) paying
     `max(30%·TWAP, $0.01)` per token → HYDX.
   - d. **market-sell** the HYDX (`SwapRouter.exactInputSingle`) **immediately**, sized within the §9.3 soft-bleed cap.
   - e. **repay** the borrow from the proceeds; **withdraw** the LP from escrow (unlocks at debt = 0); **re-stake**
     to resume emissions.
   - f. the **residual** (proceeds above strike + interest) is the **free value**.
5. **Recycle the free value** → the single sink (§6, 8-B10): deposit → backed zipUSD into the basket → 8-B6 single-sided LP → NAV accretion.
6. **Rebalance** (epoch boundary): re-vote (`Voter.vote` — votes reset weekly); update the trailing-APR accumulator.

**Caps on every sell** (`hydrex.md` §9.3): per-order slippage ≤2–3%; per-epoch volume ≤1–2% of pool USDC; never
faster than the 2h-TWAP; taper from $0.033 → amber-taper ~$0.018 → halt $0.015. **The cap sizes the loop** (only borrow/exercise an
amount whose repay market-sell fits the cap) — it is not a "sell slowly" rule.

---

## 5. Strike financing — the self-collateralizing borrow loop

Exercising oHYDX costs ~30%·spot in USDC, so the harvest needs a USDC source. The source is **the LP itself**:
**borrow 30% to unlock 100%.** The LP slice is unstaked, posted as escrow collateral, and used to borrow the
strike; the HYDX sale repays the borrow; the LP returns to the gauge. This is an inherent step of every harvest —
**not** a fallback to a standing buffer.

| Approach | Mechanism | Verdict |
|---|---|---|
| **Self-collateralizing borrow loop** | unstake an LP slice → post as EVK escrow collateral → borrow the ~30% strike from the **farm utility borrow vault** (JIT-funded from un-utilized resting USDC, CRE-only) → exercise → **market-sell to repay immediately** → withdraw + re-stake | **CANONICAL — this is the harvest process.** Safe because: (a) CRE-permissioning kills the external oracle-manipulation exploit; (b) the 30% strike is **self-collateralizing** — borrow 30% to unlock 100%, default requires **>71% single-order slippage** (never placed, §4 caps); (c) the borrow **revolves** (resting USDC out only for the loop window), so no idle buffer. **Borrow only un-utilized resting USDC, over-collateralized by the LP, repaid each loop — depositor principal is never the counterparty.** |
| Standing USDC buffer | vault/treasury holds ~30%-of-flow USDC standing idle; exercise → sell → replenish | **Rejected.** Ties up idle treasury capital the revolving borrow avoids; no capital-efficiency win. |
| Flash loan | borrow strike atomically, repay same tx | **Rejected** — forces an *atomic market sell* at worst impact. |

**Why the sell is a MARKET sell, not a resting range order.** Two reasons: (1) the loop must **repay the borrow
immediately** — interest accrues and the unstaked LP earns no oHYDX while the loop is open; (2) the pool is
**net-draining with no buy-side** (`hydrex.md` §2.3), so resting orders above spot rarely fill. The soft-bleed
caps therefore act as a **size gate on the loop** (§4), and the **regime gate** (enter the loop only in UP/FLAT;
DOWN → `exerciseVe`) keeps the engine from ever being forced to dump into weakness. Only the ~30% strike must be
sold to repay + re-stake; the residual free value is market-sold within the cap and does **not** block the
re-stake, so the unstake window is short by construction.

**Invariant.** The strike borrows the warehouse's **un-utilized USDC** (JIT-funded into the farm utility borrow vault from the resting `usdcReservoir`),
**over-collateralized by the ICHI LP** and **repaid from the HYDX sale** each loop. Depositor principal is protected
by the LP collateral — it is **never** the counterparty to the dump engine. Worst case is a *stall* (CRE holds
over-collateralized HYDX waiting for
liquidity, the LP slice unstaked + the borrow open), **not** depositor bad debt.

**Tradeoff (inherent):** the unstaked slice earns no oHYDX until re-staked → size each loop's slice so the repay
sale completes within an epoch.

---

## 6. The recycle sink — the single free-value destination

> Single sink (2026-06-08; `claude-zipcode.md §4.5.1`, 8-B10 `RecycleModule`). The earlier three-mode framing
> (Mode A clean USDC / Mode B boosted xALPHA / Mode C compound) is **retired** — there is no USDC payout, no
> zipUSD→xALPHA buy, no "+30% boost" distribution, and no pull-claim distributor. `8-B13` is removed (absorbed here).

The free value (§4 step 4f) has **one** destination: it is recycled into the basket so NAV-per-share rises for
every holder.

- **`ZipDepositModule.deposit(usdc)`** parks the free USDC as **senior backing in the `CreditWarehouse`** (the
  recycle module runs on the MAIN Safe — no `gate.depositFor`, no new shares) and mints **backed zipUSD 1:1**
  directly into the basket.
- **8-B6 single-sides** that zipUSD into the **gauge-staked LP** (single-sided zipUSD ICHI vault — no balanced
  add, no xALPHA leg to fund).
- The basket grows, share count is flat → **NAV-per-share accretes.** The depositor's return is that accretion,
  realized on exit at NAV (plus the §11 Duration-Bond premium).

**Free-value-only (the load-bearing invariant, §8 inv. 3).** The recycle spends **only** `freeValueAccrued`
(HYDX-extracted), and the zipUSD it mints is backed 1:1 by the just-deposited USDC (deposit precedes mint) — never
depositor principal, never an unbacked mint, never a reserve spend. The same USDC does double duty: **senior
backing** (over-collateralizes zipUSD / lending capacity ↑) **and** the raw material for the LP growth. The
recycle *amount* each epoch is a Treasury-owned weight (the numbers are open, pinned post-M1; the mechanism is fixed).

---

## 7. Accounting, APR, and the TVL cap

- **Shares.** ERC-4626. `szipUSD` NAV = (ICHI LP value + idle basket assets + accrued, un-distributed proceeds +
  any in-flight loop balance net of the open borrow) / supply. The recycle adds **real basket assets** (backed
  zipUSD → single-sided LP), so NAV-per-share genuinely rises — not a paper markup; the headline is honest.
- **APR — trailing realized only.** `APR = (NAV-per-share growth over trailing 7d, annualized)`. Computed/published on-chain by the CRE (reuse `tickets/bridge/8x-02-xalpha-apr-cre.md` pattern). **Never** publish a
  projection. The number **degrades visibly** as the HYDX bleed/floor bite — that's the design, not a bug.
- **TVL cap (the critical governor).** The vault's farmed-oHYDX run-rate scales with TVL; if it exceeds the HYDX
  pool's absorption, the vault dumps faster than the market clears → it **kills its own APR.** So:
  `maxDeposit` gates such that `expected_weekly_oHYDX_sold ≤ pool_absorption(measured)`. An uncapped vault is the
  primary failure mode. Re-derive the cap each epoch from the measured net Swap flow (`hydrex.md` §5).

---

## 8. Invariants (the hard rules — enforce in code, not policy)

1. **Permissioned writer.** Only the CRE address operates harvest/exercise/borrow/sell/recycle.
2. **Depositor principal is never at risk in the dump.** The strike borrow draws the warehouse's **un-utilized
   resting USDC** (JIT-funded into the farm utility borrow vault), **over-collateralized by the ICHI LP**, CRE-only, repaid each loop — never USDC already
   committed to a credit line.
3. **Free-value-only.** The recycle spends **only** HYDX-extracted free value; the zipUSD it mints is backed 1:1
   by the just-deposited USDC (deposit precedes mint). No unbacked mint, no reserve spend, no xALPHA buy.
4. **Soft-bleed caps** (`hydrex.md` §9.3) enforced on every sell; amber-taper ~$0.018, halt below $0.015.
5. **Loop sizing + regime gate.** Borrow/exercise only an amount whose repay market-sell fits the soft-bleed cap;
   enter the loop only in **UP/FLAT** (DOWN → `exerciseVe`, no loop); the LP slice is unstaked **only inside the
   loop window** — no open position is carried across epochs. This is what guarantees the engine is never forced
   to dump into weakness.
6. **TVL cap** to measured absorption; gate deposits when exceeded.
7. **Trailing-realized APR only** — no projection ever surfaced to a depositor.
8. **Vote-floor first** — the `exerciseVe` slice to defend the gauge is taken before the sell slice.

---

## 9. Contract / interface surface

- **Vault / basket:** the **szipUSD Baal Safe** (8-B1) holds the basket (zipUSD + xALPHA + the ICHI LP); the
  `szipUSD` share is ERC-4626 with the `maxDeposit` TVL gate (8-B2); NAV + trailing-APR oracle (8-B4).
- **ICHI single-sided:** factory `0x2b52c416…`, guard `0x9A0EBEc4…`; the LP token is gauged (gauge from
  `Voter.gauges(pool)`); add liquidity via the ICHI vault `deposit(deposit0, deposit1, to)`, stake via
  `gauge.deposit`.
- **oHYDX (`0xA113…`):** *(fork-verified Base 8453, 2026-06-06)* `exercise(amount,maxPayment,recipient)` **and**
  `exercise(amount,maxPayment,recipient,deadline)` (prefer the deadline overload), `exerciseVe(amount,recipient)`,
  `getDiscountedPrice(amount)`, `getTimeWeightedAveragePrice(amount)`, **`getMinPaymentAmount()` — NO args**,
  `discount()` (= 30).
- **Sell:** `SwapRouter (0x6f4b…)` `exactInputSingle` — HYDX→USDC (the loop's market-sell). *(No zipUSD→xALPHA buy
  leg — the recycle adds single-sided zipUSD LP, 8-B6.)*
- **Strike borrow (the loop):** an EVK isolated market — the **farm utility borrow vault** (JIT-funded from the warehouse's un-utilized resting USDC) + an **ICHI-LP
  escrow collateral vault** + a dedicated `EulerRouter`, driven by the CRE-gated module
  (`postCollateral`/`borrow`/`repay`/`withdrawCollateral`). Borrower-of-record = the szipUSD Safe (its own EVC
  account). Build detail: `claude-zipcode.md` §4.5.1 (8-B5).
- **Governance:** `Voter (0xc69E…)` `vote/reset`; rebase claim on the veNFT.
- **Recycle (8-B10):** `ZipDepositModule.deposit` → backed zipUSD mint (+ warehouse senior backing) → 8-B6
  single-sided `gauge.deposit` the LP into the basket. No zipUSD→xALPHA swap, no payout, no distributor.
- **CRE workflow:** the orchestrator; same trust pattern as `tickets/bridge/8x-02-xalpha-apr-cre.md`.

---

## 10. Failure modes & open items

**Failure modes (each maps to an invariant):** uncapped TVL → APR death (→ inv. 6); flash-loan exercise → forced
worst-impact sell (→ §5); uncollateralized strike or depositor-funded recycle → cascade (→ inv. 2/3); projected APR → broken
trust when it degrades (→ inv. 7); thin pool can't absorb the repay sale → **loop stall** (LP unstaked + borrow
open, but over-collateralized — no bad debt), bounded by the size gate + the DOWN-regime gate (→ inv. 5); spot
below floor → underwater exercise (→ §4 step 4c soft-halt pre-check).

**Open items (→ the 8-B build modules):**
- [ ] szipUSD ERC-4626 + ICHI single-sided integration + gauge staking (8-B1/8-B2/8-B6).
- [ ] CRE harvest workflow — regime classifier, split policy, the self-collateralizing loop, rebalance
      (8-B11 on-chain seam / `claude-zipcode.md §8.7` workflow).
- [ ] The self-collateralizing strike loop — EVK isolated market (farm utility borrow vault, JIT-funded from resting USDC, + ICHI-LP escrow),
      CRE-only (8-B5).
- [ ] Recycle sink (8-B10 `RecycleModule`) — free-value-only gate; deposit → backed zipUSD → 8-B6 single-sided LP → NAV.
- [ ] ~~Compounder / LP-rebalance (Mode C / 8-B13)~~ **REMOVED — absorbed into the 8-B10 single-sided recycle.**
- [ ] Trailing-realized APR oracle — reuse `tickets/bridge/8x-02-xalpha-apr-cre.md` (8-B4).
- [ ] TVL-cap controller wired to measured net Swap flow — `hydrex.md` §5 (8-B2 enforce / 8-B12 compute).
- [ ] Gauge whitelist confirmed (`hydrex.md` §9.4) — the gating dependency for the whole product.

---

## 11. The compounding flywheel — LP growth + credit-line expansion

> Single sink (2026-06-08): the separate "Mode C / 8-B13" compounder/LP-rebalance module is **REMOVED** — the
> compounding below is the **8-B10 recycle + 8-B6 single-sided LP**, with **no balanced add and no zipUSD→xALPHA
> swap-to-fund** (single-sided LP needs no xALPHA leg). `claude-zipcode.md §4.5.1` is the contract-cited spec.

The recycle (§6) is the single sink, and it is reflexively growth-creating — it does two things at once that the
design maximizes:

1. **It grows the gauge-staked LP** → more oHYDX emissions → more HYDX to extract and market-sell → more free
   value next epoch. **We earn the most by extracting and selling HYDX, so the engine's own output should buy
   more of the engine.** This is the reflexive growth leg.
2. **It expands the credit lines.** The free-value USDC is deposited as **senior backing in the warehouse**
   (`claude-zipcode.md` §4.5 `CreditWarehouse`) before any zipUSD is minted against it — so the very same USDC
   that funds the LP growth **also increases lending capacity** (more lines can be originated). One USDC inflow
   does double duty: senior backing *and* the raw material for new LP. This is the credit-expansion leg.

So the flywheel is: **dump HYDX → free-value USDC → warehouse (credit-line capacity ↑) → mint backed zipUSD →
grow staked LP (emissions ↑) → dump more HYDX.** Bounded by the same governors as everything else — the TVL cap
(§7), the soft-bleed caps (§4), and the free-value-only invariant (§8 inv. 3).

### 11.1 The add is single-sided (no "how much xALPHA" question)

The LP is the **single-sided zipUSD ICHI vault** (`hydrex.md` §2.5, 8-B6): the recycle deposits **only zipUSD**.
Per epoch (CRE-driven): take the recycle budget `B` of `freeValueAccrued`, `ZipDepositModule.deposit(B)` parks it
as warehouse senior backing + mints `B·scaleUp` backed zipUSD into the basket, and 8-B6 single-sides that zipUSD
into the gauge-staked LP (`ICHI deposit` + `gauge.deposit`). ICHI's ALM acquires the ~30% xALPHA leg from the
pool's own flow. **There is no xALPHA-shortfall evaluator, no zipUSD→xALPHA swap-to-fund, and no idle-xALPHA
accumulation** — the retired balanced-add machinery is moot. `freeValueAccrued` is decremented by `B` (the
free-value-only gate, §8 inv. 3); the mint is deposit-backed, so it never touches depositor USDC or mints unbacked.

### 11.2 The recycle amount (Treasury-owned)

There is one sink, so the only open parameter is **how much** of each epoch's `freeValueAccrued` to recycle now vs
leave as basket cash — a Treasury-owned weight (the growth-window default is recycle-heavy, tapering as the HYDX
bleed degrades, §7). **FLAG (Treasury decision):** the concrete default + taper schedule + whether the vote-floor
`exerciseVe` slice (§4 step 3) is taken before or after the recycle budget are open policy numbers, pinned when the
engine economics are finalized post-M1. The mechanism is fixed; only the numbers are open.

### 11.3 Invariants (in addition to §8)

- **Free-value-only (inherits §8 inv. 3).** The compounder spends only `freeValueAccrued`; the zipUSD it mints is
  backed 1:1 by the just-deposited free-value USDC (deposit precedes mint). Never depositor USDC, never reserves,
  never an unbacked mint.
- **Single-sided, no swap.** The add deposits only zipUSD; there is no zipUSD→xALPHA swap, so no thin-pool slippage
  surface and no idle-xALPHA position to manage.
- **Backing is automatic.** Because the USDC is deposited to the warehouse before the mint, the new zipUSD is
  always senior-backed — the credit-expansion leg and the LP-growth leg are the same capital viewed two ways,
  never double-counted.
