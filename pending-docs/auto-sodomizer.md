# auto-sodomizer.md — Structured-product vault: oHYDX→yield abstraction (design narrative)

> **What this builds:** the depositor-facing vault that makes the Hydrex leg usable. Surface: **"deposit
> single-sided (xALPHA or zipUSD), earn a [trailing-realized] yield"** — depositors **never see an oHYDX, a
> strike, or a gauge.** Under the hood a CRE-driven robot farms gauge oHYDX, exercises it **via a
> self-collateralizing borrow loop (the LP is its own working capital)**, **market-sells** the HYDX within the
> soft-bleed caps, and either **pays out** (USDC or boosted xALPHA) or **compounds** the proceeds back into more
> staked LP + loan-book capacity. It is a **HYDX-bleed-funded yield** — designed to abstract complexity, convert
> xALPHA dump-pressure into LPs, and feed the loan book.
>
> **Status / where the build spec lives.** This file is the design **narrative** (rationale, economics, the
> failure-mode→invariant map). The canonical, contract-cited build spec is **`claude-zipcode.md` §4.5.1** (engine
> modules **8-B5…8-B13**) — build tickets are authored from there, not from here. The supply-side token model is
> locked in `claude-zipcode.md` §2/§4.5/§11/§17 and assumed throughout: **the vault IS `szipUSD`** (one junior
> ERC-4626 share); **depositors deposit `zipUSD` or `xALPHA` single-sided** and receive `szipUSD`; the **LP is
> `zipUSD/xALPHA`** (clean, yieldless $1 leg); real lending yield is the **protocol's** (privatized → buys
> xALPHA) and the depositor's pay is the **HYDX-vamp + the xALPHA subsidy**, frozen-but-accruing through the §11
> duration bond.
> Refs: `hydrex.md` (the Hydrex leg, exit constraint, soft-bleed caps), `treasury.md` (§4.6 product, §4.7 boost
> loop, §7 foundation), `monitoring.md` (surveillance — TVL cap, profitability-halt, backing feeds),
> `bridge/xALPHA-apr.md` (CRE APR pattern). Memory: [[hydrex-gauge-architecture]].

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
| **CRE robot** | the only permissioned operator (harvest, exercise, sell, payout, compound, rebalance) | — |
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
        │  Allocation / payout router (§6, §11)         │
        │   Mode A: pay depositors USDC                 │
        │   Mode B: →warehouse→mint zipUSD→buy xALPHA   │  (treasury.md §4.7)
        │           →pay boosted xALPHA                 │
        │   Mode C: →warehouse→mint zipUSD→(swap if     │  (the flywheel, §11)
        │           short)→add+stake LP; credit-line ↑  │
        └──────────────────────────────────────────────┘
```

**The CRE robot is the only writer.** Everything that touches the borrow facility, the market-sell, and the
payout/compound is permissioned to the CRE workflow address. This is what makes the revolving borrow safe (§5);
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
   - b. post the slice as EVK escrow collateral; **borrow** the ~30% strike from the warehouse **USDC Resting Vault** (un-utilized USDC).
   - c. **profitability-cutoff pre-check** (skip if HYDX < $0.015 → route those tokens to ve, `hydrex.md` §2.4; $0.018 = amber/taper-start); then
     `oHYDX.exercise(amount, maxPayment, recipient[, deadline])` (prefer the deadline overload) paying
     `max(30%·TWAP, $0.01)` per token → HYDX.
   - d. **market-sell** the HYDX (`SwapRouter.exactInputSingle`) **immediately**, sized within the §9.3 soft-bleed cap.
   - e. **repay** the borrow from the proceeds; **withdraw** the LP from escrow (unlocks at debt = 0); **re-stake**
     to resume emissions.
   - f. the **residual** (proceeds above strike + interest) is the **free value**.
5. **Route the free value** → the allocation / payout router (§6, §11): Mode A / B / C per the Treasury-owned weight.
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
| **Self-collateralizing borrow loop** | unstake an LP slice → post as EVK escrow collateral → borrow the ~30% strike from the **warehouse USDC Resting Vault** (un-utilized USDC, CRE-only) → exercise → **market-sell to repay immediately** → withdraw + re-stake | **CANONICAL — this is the harvest process.** Safe because: (a) CRE-permissioning kills the external oracle-manipulation exploit; (b) the 30% strike is **self-collateralizing** — borrow 30% to unlock 100%, default requires **>71% single-order slippage** (never placed, §4 caps); (c) the borrow **revolves** (resting USDC out only for the loop window), so no idle buffer. **Borrow only un-utilized resting USDC, over-collateralized by the LP, repaid each loop — depositor principal is never the counterparty.** |
| Standing USDC buffer | vault/treasury holds ~30%-of-flow USDC standing idle; exercise → sell → replenish | **Rejected.** Ties up idle treasury capital the revolving borrow avoids; no capital-efficiency win. |
| Flash loan | borrow strike atomically, repay same tx | **Rejected** — forces an *atomic market sell* at worst impact. |

**Why the sell is a MARKET sell, not a resting range order.** Two reasons: (1) the loop must **repay the borrow
immediately** — interest accrues and the unstaked LP earns no oHYDX while the loop is open; (2) the pool is
**net-draining with no buy-side** (`hydrex.md` §2.3), so resting orders above spot rarely fill. The soft-bleed
caps therefore act as a **size gate on the loop** (§4), and the **regime gate** (enter the loop only in UP/FLAT;
DOWN → `exerciseVe`) keeps the engine from ever being forced to dump into weakness. Only the ~30% strike must be
sold to repay + re-stake; the residual free value is market-sold within the cap and does **not** block the
re-stake, so the unstake window is short by construction.

**Invariant.** The strike borrows the warehouse's **un-utilized USDC** (the `USDC Resting Vault`),
**over-collateralized by the ICHI LP** and **repaid from the HYDX sale** each loop. Depositor principal is protected
by the LP collateral — it is **never** the counterparty to the dump engine. Worst case is a *stall* (CRE holds
over-collateralized HYDX waiting for
liquidity, the LP slice unstaked + the borrow open), **not** depositor bad debt.

**Tradeoff (inherent):** the unstaked slice earns no oHYDX until re-staked → size each loop's slice so the repay
sale completes within an epoch.

---

## 6. Payout / allocation modes

> **SUPERSEDED (2026-06-08) — read against `claude-zipcode.md §4.5.1`.** The three-mode framing below (Mode A clean
> USDC / Mode B boosted xALPHA / Mode C compound) is **retired.** There is now **one sink:** the free value is
> recycled — `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing) mints backed zipUSD **directly
> into the basket** (the recycle module runs on the MAIN Safe — no `gate.depositFor`, no shares), and 8-B6
> single-sides it into the gauge-staked LP. The basket grows, share count is flat → **NAV-per-share accretes for
> every holder.** No USDC payout, no xALPHA boost distribution, no pull-claim distributor; the depositor's return is
> NAV accretion realized on exit. 8-B13 (Mode C) is removed — absorbed into the recycle.

The free value (§4 step 4f) is routed by a Treasury-owned policy across three sinks:

**Mode A — clean USDC.** Net USDC distributed pro-rata to `szipUSD` shares. Simplest; the cash *leaves* (no AUM
growth). Use when the goal is a plain USDC-yield product.

**Mode B — boosted xALPHA (the recycle loop, `treasury.md` §4.7).** Net USDC → **deposit into the loan book /
warehouse** (real AUM) → **mint zipUSD (backed 1:1 by the just-deposited USDC, by construction)** → **swap
zipUSD→xALPHA on our POL** (fee recaptured: we own LP + veNFT) → distribute xALPHA as a **"+30% boost"** on the
token depositors already receive.
- **Retains the USDC in the loan book** (AUM-accretive) and **markets louder** ("+30% APR, stake here").
- **The boost buy-side must be funded ONLY by HYDX-extracted (free) value** — never reserves, never unbacked mint.
  This is the load-bearing invariant (§8 inv. 3).
- Boost value is **reflexive + time-limited** (rides xALPHA→HYDX, expires ~6mo) → present trailing-realized.

**Mode C — compound (the recycle loop's growth sink, §11).** Instead of distributing the value, the free-value
USDC is recycled into **more staked LP** (grow the engine) and the same USDC stays as **senior backing / lending
capacity** (expand credit lines). The bought xALPHA is **not** handed to depositors — it is **paired with zipUSD
and added to the gauge-staked LP** (§11).

**Mode selection is a Treasury-owned vault parameter** (per-vault, not per-deposit; set alongside the vote-floor
target `s*`, `hydrex.md` §4). The three are not mutually exclusive — the **free-value allocation policy** (§11.2)
splits each epoch's free value across {compound (Mode C), boost (Mode B), clean USDC (Mode A)} per a Treasury
weight. Mode C is the compounding/growth default once the engine is live and the vote floor is held; Mode B is
the acquisition-window distribute-and-market default; Mode A is the clean fallback.

---

## 7. Accounting, APR, and the TVL cap

- **Shares.** ERC-4626. `szipUSD` NAV = (ICHI LP value + idle basket assets + accrued, un-distributed proceeds +
  any in-flight loop balance net of the open borrow) / supply. Payouts are realized distributions, not NAV
  markups, so the headline is honest.
- **APR — trailing realized only.** `APR = (USD value actually distributed over trailing 7d, annualized) ÷ avg
  TVL`. Computed/published on-chain by the CRE (reuse `bridge/xALPHA-apr.md` pattern). **Never** publish a
  projection. The number **degrades visibly** as the HYDX bleed/floor bite — that's the design, not a bug.
- **TVL cap (the critical governor).** The vault's farmed-oHYDX run-rate scales with TVL; if it exceeds the HYDX
  pool's absorption, the vault dumps faster than the market clears → it **kills its own APR.** So:
  `maxDeposit` gates such that `expected_weekly_oHYDX_sold ≤ pool_absorption(measured)`. An uncapped vault is the
  primary failure mode. Re-derive the cap each epoch from the measured net Swap flow (`hydrex.md` §5).

---

## 8. Invariants (the hard rules — enforce in code, not policy)

1. **Permissioned writer.** Only the CRE address operates harvest/exercise/borrow/sell/payout/compound.
2. **Depositor principal is never at risk in the dump.** The strike borrow draws the warehouse's **un-utilized
   `USDC Resting Vault`**, **over-collateralized by the ICHI LP**, CRE-only, repaid each loop — never USDC already
   committed to a credit line.
3. **Free-value-only.** In Mode B (boost) and Mode C (compound), xALPHA is bought **only** with HYDX-extracted
   free value; no unbacked zipUSD mint, no reserve spend to prop xALPHA. (Backing is automatic — deposit precedes
   mint.)
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
- **Sell:** `SwapRouter (0x6f4b…)` `exactInputSingle` — HYDX→USDC (the loop's market-sell), and zipUSD→xALPHA on
  our POL (Mode B/C buy leg).
- **Strike borrow (the loop):** an EVK isolated market — the warehouse **`USDC Resting Vault`** (un-utilized USDC) + an **ICHI-LP
  escrow collateral vault** + a dedicated `EulerRouter`, driven by the CRE-gated module
  (`postCollateral`/`borrow`/`repay`/`withdrawCollateral`). Borrower-of-record = the szipUSD Safe (its own EVC
  account). Build detail: `claude-zipcode.md` §4.5.1 (8-B5).
- **Governance:** `Voter (0xc69E…)` `vote/reset`; rebase claim on the veNFT.
- **Payout Mode B/C:** `ZipDepositModule.deposit` → backed zipUSD mint (+ warehouse senior backing); `SwapRouter`
  zipUSD→xALPHA on our POL; Mode C additionally `gauge.deposit` the re-built LP.
- **CRE workflow:** the orchestrator; same trust pattern as `bridge/xALPHA-apr.md`.

---

## 10. Failure modes & open items

**Failure modes (each maps to an invariant):** uncapped TVL → APR death (→ inv. 6); flash-loan exercise → forced
worst-impact sell (→ §5); uncollateralized strike or depositor-funded xALPHA buy → cascade (→ inv. 2/3); projected APR → broken
trust when it degrades (→ inv. 7); thin pool can't absorb the repay sale → **loop stall** (LP unstaked + borrow
open, but over-collateralized — no bad debt), bounded by the size gate + the DOWN-regime gate (→ inv. 5); spot
below floor → underwater exercise (→ §4 step 4c soft-halt pre-check).

**Open items (→ the 8-B build modules):**
- [ ] szipUSD ERC-4626 + ICHI single-sided integration + gauge staking (8-B1/8-B2/8-B6).
- [ ] CRE harvest workflow — regime classifier, split policy, the self-collateralizing loop, rebalance
      (8-B11 on-chain seam / `spec-clear-CRE.md` workflow).
- [ ] The self-collateralizing strike loop — EVK isolated market (warehouse USDC Resting Vault + ICHI-LP escrow),
      CRE-only (8-B5).
- [ ] Payout router (Mode A/B) with the free-value-only gate enforced on Mode B (8-B10).
- [ ] **Compounder / LP-rebalance (Mode C, §11)** — the "how much xALPHA → swap-if-short → add+stake LP"
      evaluator + the free-value allocation policy (8-B13).
- [ ] Trailing-realized APR oracle — reuse `bridge/xALPHA-apr.md` (8-B4).
- [ ] TVL-cap controller wired to measured net Swap flow — `hydrex.md` §5 (8-B2 enforce / 8-B12 compute).
- [ ] Gauge whitelist confirmed (`hydrex.md` §9.4) — the gating dependency for the whole product.

---

## 11. The compounding flywheel — LP growth + credit-line expansion (Mode C)

> **SUPERSEDED (2026-06-08) — the flywheel is the same, the module is not.** "Mode C / 8-B13" as a separate
> compounder/LP-rebalance module is **REMOVED.** The compounding it describes (free value → senior backing +
> gauge-staked LP → more oHYDX → more free value) is now done by the **8-B10 recycle + 8-B6 single-sided LP** — no
> balanced add, no zipUSD→xALPHA swap-to-fund (single-sided LP needs no xALPHA leg). See `claude-zipcode.md §4.5.1`.

> **Build module:** `claude-zipcode.md` §4.5.1 **8-B13 (Compounder / LP-rebalance)**. This section is the design
> narrative; §4.5.1 is the contract-cited spec the ticket is authored from.

Modes A/B (§6) *distribute* the free value. **Mode C reinvests it** — and it is the strategically dominant mode,
because reinvesting does two things at once that the design is built to maximize:

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

### 11.1 The LP-rebalance evaluator (the "how much xALPHA" question)

The LP is the **ICHI single-sided zipUSD/xALPHA** position (`hydrex.md` §2.5). To grow it the compounder must
supply tokens in the vault's current target composition. The evaluator, per epoch (CRE-driven):

1. **Budget.** Take the Mode-C slice of this epoch's `freeValueAccrued` (USDC) per the allocation policy
   (§11.2). Call it `B`.
2. **Deposit `B` to the warehouse** (`EE_POOL.deposit(B, CreditWarehouse)`) and **mint `B·scaleUp` zipUSD**
   against it (backed 1:1, the §4.5 zap path / `ZipDepositModule` — the same mechanism Mode B uses; the USDC is
   now senior backing AND lending capacity). The basket now holds `B·scaleUp` fresh **zipUSD**.
3. **Read the LP target ratio.** Query the ICHI vault for its current xALPHA:zipUSD deposit ratio `r` (the
   amount of xALPHA needed per unit zipUSD for a balanced add). Compute `xNeeded = r · zipToDeposit`.
4. **Inventory check — "do we already have the xALPHA?"** Read the basket's idle **xALPHA** balance `xHave`.
   - **`xHave ≥ xNeeded`** → we have the tokens: add the LP directly (step 6).
   - **`xHave < xNeeded`** → **swap-to-fund.** Swap part of the fresh zipUSD → xALPHA on **our POL** (the
     zipUSD/xALPHA pool, `SwapRouter.exactInputSingle`, fee recaptured — we own the LP + veNFT) to cover the
     `xNeeded − xHave` shortfall, **within a slippage cap** (the swap is a *buy* of xALPHA, so it supports the
     token — but it still moves price; cap per-order impact like every other swap, §4). This is the
     **zipUSD→xALPHA acquisition path** the depositor never sees.
5. **Re-derive** the balanced (zipUSD, xALPHA) pair from the *actual* post-swap balances (the swap consumed some
   zipUSD), so the add uses what we truly hold — no second swap, no dust chase.
6. **Add + stake.** ICHI `deposit(zipAmount, xAlphaAmount)` → receive LP → `gauge.deposit(LP)` (8-B6). Emissions
   on the new LP start next claim.
7. **Account.** Decrement `freeValueAccrued` by `B` (the free-value-only gate, §8 inv. 3, enforced exactly as
   Mode B's buy leg — the compounder can spend **only** HYDX-extracted free value; it never touches depositor
   USDC or mints unbacked zipUSD, because the mint in step 2 is deposit-backed).

**Why swap zipUSD rather than hold idle xALPHA:** the basket should not sit on idle xALPHA waiting to be paired —
idle xALPHA earns nothing and carries price risk. The compounder mints exactly the zipUSD it needs from free
value and converts the short leg on demand. If the basket *does* already hold xALPHA (e.g. from single-sided
depositor inflows, §2), the evaluator uses it first and swaps less — that is the `xHave ≥ xNeeded` branch.

### 11.2 The free-value allocation policy (Treasury-owned)

Each epoch's free value splits across the three sinks: **compound (Mode C) / boost (Mode B) / clean USDC (Mode
A)**. The split is a **Treasury-owned vault parameter** (the same governance seam as Mode selection, §6) — *not*
hard-coded and *not* per-deposit. The design default during the growth window is **compound-weighted** (the
flywheel), tapering toward boost/clean payout as the HYDX bleed degrades (§7). **FLAG (Treasury decision):** the
concrete default weights, the taper schedule, and whether the vote-floor `exerciseVe` slice (§4 step 3) is taken
before or after the Mode-C budget are open policy parameters — pin them when the engine economics are finalized
(`treasury.md`). The mechanism here is weight-agnostic; only the numbers are open.

### 11.3 Invariants (in addition to §8)

- **Free-value-only (inherits §8 inv. 3).** The compounder spends only `freeValueAccrued`; the zipUSD it mints is
  backed 1:1 by the just-deposited free-value USDC (deposit precedes mint). Never depositor USDC, never reserves,
  never an unbacked mint.
- **Swap is buy-side + capped.** The zipUSD→xALPHA swap is on our own POL and is a *buy* of xALPHA (supports the
  token); still slippage-capped per-order like every sell (§4) so a thin pool can't be moved on the add.
- **No idle-xALPHA accumulation.** The evaluator converts on demand and uses on-hand xALPHA first; it does not
  build a standing idle xALPHA position to pair later.
- **Backing is automatic.** Because the USDC is deposited to the warehouse before the mint, the new zipUSD (in
  LP and in the swap) is always senior-backed — the credit-expansion leg and the LP-growth leg are the same
  capital viewed two ways, never double-counted.
