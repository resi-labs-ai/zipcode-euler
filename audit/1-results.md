# 1-results.md — Worked numeric accounting proof (Baal/Zodiac NAV-vault + withhold money model)

> **SUPERSEDED 2026-06-07 — I1–I5 RETIRED. Do not trust the invariants below as-is.** This proof is derived on the
> 2026-06-06 **withhold-no-markdown** model (szipUSD = a soulbound Loot *claim*; first-loss = WITHHELD-not-marked-down
> + the three-lever permanent-loss realization; `J×p` NAV). That model was **replaced 2026-06-07** by the **two-token
> / NAV-oracle / provision-that-recovers** model (`claude-zipcode.md` §2/§7/§11): szipUSD = a **transferable
> NAV-proportional share**; first-loss = a **conservative recoverable provision on `SzipNavOracle`** (small, writes
> back up), **not** a withhold/burn. The **new model's invariants** — `szipUSD.totalSupply == gate Loot`, the
> `max`/`min` NAV bracket, the bounded `DefaultCoordinator` markdown, never-read-the-market-price — are **re-derived
> per-component through the critic fanout when the 8-B tickets (Exit Gate, `SzipNavOracle`, loss-side) are authored**,
> not in this standalone proof. **Re-author or delete this file when those tickets land.**

> **What this is (provenance).** The standalone accounting proof of the zipcode-euler money model — it walks
> concrete dollars through every protocol phase and asserts the solvency + loss invariants at each step. It
> **re-derives the former pool-share / `J×p` / escrow-burn proof** from scratch on the **new model** (Baal
> Loot share on a Safe basket + WITHHOLD-not-markdown first loss + the three-lever permanent-loss
> realization), which **replaces** the deleted convert-on-stake szipUSD substrate. The authority is the spec:
> `claude-zipcode.md` **§2** (token model), **§4.5** (the junior NAV vault + strategy inventory), **§4.6**
> (loss-side contracts), **§11** (loss/default/recovery), **§12** (NAV/solvency), **§17** (the locked Baal
> junior decisions); design rationale in `reports/design/szipUSD-baal-redesign-report.md`. **To re-run** after any
> change to the accounting: reproduce S0 below exactly, then re-derive S1–S3 with the same formulas; every row
> must keep **I1** except at the single documented insolvency step (S3), and **I2–I5** must hold everywhere.
> These same invariants are the "solvency sanity" assertions the Foundry tests check on-chain (the §15
> acceptance harness; the old `audit/2.md`/`3-results.md` stake/unstake/`ν=J×p` steps are the **deleted**
> model and re-align when the 8-B build tickets are authored — see "Out of scope" below).

Money is stated in **normalized dollars** (per §4.5 — zipUSD is 18-dp, USDC/pool-shares 6-dp; the `1e12`
rescale is elided here, all cross-asset quantities are dollar values). Ratios to 6 dp.

## The two ledgers

The model has **two independent ledgers** (§12 "two NAVs"), and the whole point of the redesign is that they
do **not** share a pool-share price:

1. **Senior ledger (zipUSD).** zipUSD is the **$1 utility dollar**, minted 1:1 on USDC deposit, backed by the
   loan book. Solvency is **`NAV_s / Z ≥ 1`** (§12). The junior's deposited zipUSD lives in the Safe and is
   **part of `Z`** (fungible, circulating) — which is exactly why burning it (lever 1) restores the senior.
2. **Junior ledger (szipUSD = Baal Loot on a Safe basket).** The basket holds **zipUSD + xALPHA + the
   zipUSD/xALPHA ICHI LP** (§2/§4.5). Exit is **ragequit** — `(holder Loot / total Loot) × basket`, **in-kind,
   pro-rata, no oracle in the exit path** (§12). The basket NAV `B` is **multi-oracle, display-only**; it sizes
   the freeze and the dashboard, it is **not** a redemption price.

## Invariants (replace the old I1–I4)

- **I1 — Senior solvency.** `R = NAV_s / Z ≥ 1`, where `NAV_s = C + D` (idle USDC `C` + marked loan value `D`,
  §12) and `Z` = total zipUSD supply (circulating, **including** the Safe's holding). The over-collateralization
  `σ = NAV_s − Z ≥ 0` is the **protocol's** cushion (privatized → treasury → xALPHA, §5/§17), **not** the
  junior's. Holds in every row except the single documented insolvency boundary (S3), and there only **after the
  junior basket is exhausted**.
- **I2 — Subordination (junior-first-loss).** A confirmed loss reduces the **junior basket `B` first** (down to
  0), only then the surplus `σ`, only then senior par. While `B` can cover the shortfall, `σ` and the senior are
  untouched (strict waterfall — the junior bears the loss with its own assets).
- **I3 — Ragequit value-preservation.** A ragequit of `loot_h` Loot moves `(loot_h/Loot) × basket` in-kind;
  afterward every remaining holder's per-Loot claim `B/Loot` is **unchanged**, and `Z`, `NAV_s`, `R` are
  unchanged (the basket's zipUSD merely moves Safe → holder, still circulating and still senior-backed). It can
  neither dilute nor enrich the others; no oracle enters the exit path.
- **I4 — Freeze neutrality.** The FREEZE withholds `lockedFraction = atRiskAmount / B` of **every** position
  from ragequit (the same fraction for all) and **changes no value**: `B`, `Z`, `NAV_s`, `σ`, `R`, and each
  holder's per-Loot claim are all unchanged; total withheld `= lockedFraction × B = atRiskAmount`. The senior
  stays covered (I1 holds) because the loan is still marked (expected to repay) **and** the at-risk junior
  backing is held in place (it cannot be ragequit out of the backing/LP while the waterfall works).
- **I5 — Loss-realization completeness.** For a confirmed permanent shortfall `L`, each lever (§11; applied
  alone or mixed "until the hole is filled") restores `R ≥ 1` **and** shrinks the junior basket by exactly `L`:
  - **Lever 1 — sequester + burn `L` of junior zipUSD:** `Z → Z − L`, `NAV_s` **unchanged**, `B → B − L`
    (removes junior *claims*; does not recover USDC — restores `R` by cutting supply).
  - **Lever 2 — sell `L` of accrued yield → USDC → repay:** `NAV_s → NAV_s + L`, `Z` **unchanged**, `B → B − L`
    (real external USDC refills the hole).
  - **Lever 3 — sell `L` of xALPHA → USDC → repay:** `NAV_s → NAV_s + L`, `Z` **unchanged**, `B → B − L`.
  In all three the junior bears `L`, the senior is made whole, and `σ` is left intact (strict junior-first-loss).

**Columns.** `C` idle USDC · `D` marked loan value · `NAV_s = C + D` · `Z` zipUSD supply · `σ = NAV_s − Z`
(protocol surplus) · `R = NAV_s/Z` (I1) · `B` junior basket NAV (display) · `Loot` total Loot · `B/Loot`
per-Loot ragequit value. Junior basket components `(b_zip, b_xa, b_yld)` = (zipUSD, xALPHA, accrued
LP/HYDX-yield) are broken out in the arithmetic notes.

---

## 1. S0 — baseline lifecycle (deposit → lend → yield-accrue → ragequit)

Establishes I1–I3 in calm operation: a senior deposit, the junior **zap**, a draw, lending interest (the
**protocol's** surplus), the **xALPHA subsidy** + the **HYDX vamp** (the **junior's** pay), and a ragequit.

| Phase | C | D | NAV_s | Z | σ | R | B | Loot | B/Loot |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| init | 0 | 0 | 0 | 0 | 0 | — | 0 | 0 | — |
| P0 Senior deposit 1,000,000 | 1,000,000 | 0 | 1,000,000 | 1,000,000 | 0 | 1.000000 | 0 | 0 | — |
| P1 Junior zap 100,000 | 1,100,000 | 0 | 1,100,000 | 1,100,000 | 0 | 1.000000 | 100,000 | 100,000 | 1.000000 |
| P2 Draw 200,000 | 900,000 | 200,000 | 1,100,000 | 1,100,000 | 0 | 1.000000 | 100,000 | 100,000 | 1.000000 |
| P3 Interest +16,000 (protocol) | 900,000 | 216,000 | 1,116,000 | 1,100,000 | 16,000 | 1.014545 | 100,000 | 100,000 | 1.000000 |
| P4 xALPHA subsidy +60,000 | 900,000 | 216,000 | 1,116,000 | 1,100,000 | 16,000 | 1.014545 | 160,000 | 100,000 | 1.600000 |
| P5 HYDX vamp +50,000 | 950,000 | 216,000 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 210,000 | 100,000 | 2.100000 |
| P6 Ragequit 20,000 Loot | 950,000 | 216,000 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 168,000 | 80,000 | 2.100000 |

**Arithmetic (S0):**
- **P0/P1 (1:1 mint).** Each deposit pulls USDC and mints zipUSD of equal value, so `ΔC = ΔZ` and `R` stays
  1.0. The junior **zap** (§4.5/§5) deposits 100,000 USDC → mints 100,000 zipUSD → stakes it into the Safe → 
  mints 100,000 Loot. The zipUSD is now Safe-held but still part of `Z` (fungible). `b_zip = 100,000`, `B =
  100,000`.
- **P2 (draw).** 200,000 idle USDC leaves the reserve as a loan: `C −200,000`, `D +200,000` at par. `NAV_s`
  unchanged (the lent USDC and the loan are two sides of one asset, §12) → `R` unchanged.
- **P3 (interest — the protocol's, not the junior's).** The credit line accrues 16,000 (≈8% on 200,000):
  `D → 216,000`, `NAV_s → 1,116,000`, `σ = 16,000`. Under §5/§17 this lending yield is the **protocol's**
  privatized surplus (→ treasury → xALPHA); it raises `σ`, **not** `B`. The junior's `B/Loot` is unchanged.
- **P4 (xALPHA subsidy — the junior's pay, leg 1).** The seeded szipUSD xALPHA emission (§17/`treasury.md`)
  drops 60,000 of xALPHA into the Safe: `b_xa = 60,000`, `B → 160,000`. xALPHA is an external token — **not** in
  `NAV_s` — so `C`, `D`, `Z`, `σ`, `R` are all untouched. Only the junior's `B/Loot` grows (1.0 → 1.6).
- **P5 (HYDX vamp — the junior's pay, leg 2).** The auto-compounder vamps **net-new external USDC** out of the
  HYDX/USDC pool (farm → exercise → sell HYDX → USDC), and the **free-value-only invariant** (§4.5,
  `auto-compounder.md` §8) routes it: 50,000 external USDC in → mint 50,000 zipUSD → re-LP into the basket. So
  `C +50,000`, `Z +50,000` (the mint is fully backed — `σ`, `R` essentially flat: `R` 1.014545 → 1.013913,
  still ≥ 1 since `NAV_s > Z`), and `b_yld = 50,000`, `B → 210,000`. The basket grew with **no new Loot** →
  `B/Loot` 1.6 → 2.1. This is "frozen but earning" — the junior's compensation, sourced externally, senior-neutral.
- **P6 (ragequit — I3).** A holder ragequits 20,000 Loot (20% of 100,000) → receives 20% of the basket
  **in-kind**: `0.2 × (b_zip 100,000, b_xa 60,000, b_yld 50,000) = (20,000 zipUSD, 12,000 xALPHA, 10,000 LP)`,
  worth 42,000. Basket → `(80,000, 48,000, 40,000)`, `B = 168,000`; `Loot → 80,000`; `B/Loot = 168,000/80,000 =
  **2.100000 (unchanged)**`. `Z` unchanged (the 20,000 zipUSD moved Safe → holder, still circulating + backed),
  `NAV_s`/`R` unchanged. **No dilution, no oracle in the path.**

**S0 result.** I1 holds every row (`R ≥ 1`); I2 not yet exercised (no loss); I3 confirmed at P6. The lending
interest lifts the **protocol's** `σ`; the xALPHA subsidy + HYDX vamp lift the **junior's** `B/Loot` — the two
ledgers move independently, as designed.

---

## 2. S1 — duration freeze + recovery (junior made whole, no value moves)

Builds on the S0 **P5** state (pre-ragequit: `B = 210,000`, `Loot = 100,000`, loan `D = 216,000`). The loan
goes delinquent; the deviation re-mark (§4.1) sizes `atRiskAmount = 50,000` (an **information** signal — it is
**not** a balance op on the junior, §11). This is a duration hole — *in question, not confirmed lost* — so
the response is **WITHHOLD**, not markdown.

| Phase | C | D | NAV_s | Z | σ | R | B | Loot | B/Loot |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| (carry S0 P5) | 950,000 | 216,000 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 210,000 | 100,000 | 2.100000 |
| Freeze (at-risk 50,000) | 950,000 | 216,000 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 210,000 | 100,000 | 2.100000 |
| Recovery: repay 216,000 | 1,166,000 | 0 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 210,000 | 100,000 | 2.100000 |
| Release + xALPHA premium +5,000 | 1,166,000 | 0 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 215,000 | 100,000 | 2.150000 |

**Arithmetic (S1):**
- **Freeze (I4).** `lockedFraction = atRiskAmount / B = 50,000 / 210,000 = 0.238095`. Every Loot holder has
  23.8095% of their ragequit slice withheld — total withheld `= 0.238095 × 210,000 = 50,000 = atRiskAmount`.
  **Nothing moves:** `B`, `Z`, `NAV_s`, `σ`, `R`, `B/Loot` are all identical to the carry row (no escrow, no
  share-move, no markdown — §11). The withheld backing **stays in place and keeps earning**. The senior stays
  covered (`R = 1.013913 ≥ 1`) because (a) the loan is still marked at par — it is *expected* to repay — and
  (b) the at-risk junior backing is pinned in the Safe, so a junior run cannot drain it (§6.4). **I4 confirmed.**
- **Recovery.** Time + the waterfall (foreclosure → insurance → xALPHA bond → HYDX-vamped USDC, §11) bring
  **external** USDC that repays the loan in full: borrower repays 216,000 → `D → 0`, `C → 1,166,000`. `NAV_s`
  unchanged at 1,166,000 (the par loan repaid at par; the 16,000 interest already in `NAV_s` is now realized as
  cash). The freeze auto-lifts on the DON solvency-restored report. **No "NAV restore" step — the junior was
  only withheld, never marked down.**
- **Premium.** `slashXAlphaToCohort` (§4.6) pays the frozen cohort the xALPHA Duration-Bond premium **in-kind**
  (priced via the CRE feed, never market-sold): 5,000 xALPHA → `b_xa → 65,000`, `B → 215,000`, `B/Loot → 2.15`.
  Distributed pro-rata over the (uniformly frozen) cohort, so I3 still holds.

**S1 result.** I1 holds every row; I4 confirmed (the freeze is value-neutral); the junior comes out **whole +
the premium** (`B/Loot` 2.10 → 2.15). The senior never depended on the junior's zipUSD — only on the external
waterfall USDC and the loan curing.

---

## 3. S2 — confirmed permanent loss, the three levers (the heart)

Builds on the S0 **P5** state again (`B = 210,000` with `b_zip = 100,000`, `b_xa = 60,000`, `b_yld = 50,000`;
`Loot = 100,000`; loan `D = 216,000`). This time the waterfall runs to exhaustion and a **permanent shortfall
is confirmed**. The loss is **realized on the junior's own basket** via the three levers (§11/§4.6) — shown as
**three mutually exclusive branches** from one common loss row, to prove each lever independently satisfies I5.

| Phase | C | D | NAV_s | Z | σ | R | B | Loot | B/Loot | I1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| (carry S0 P5) | 950,000 | 216,000 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 210,000 | 100,000 | 2.100000 | OK |
| Default; recovery 166,000; **L = 50,000** | 1,116,000 | 0 | 1,116,000 | 1,150,000 | −34,000 | 0.970435 | 210,000 | 100,000 | 2.100000 | **FAIL (pending)** |
| → **Branch A** — Lever 1: burn 50,000 zip | 1,116,000 | 0 | 1,116,000 | 1,100,000 | 16,000 | 1.014545 | 160,000 | 100,000 | 1.600000 | OK |
| → **Branch B** — Lever 2: sell 50,000 yield → USDC → repay | 1,166,000 | 0 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 160,000 | 100,000 | 1.600000 | OK |
| → **Branch C** — Lever 3: sell 50,000 xALPHA → USDC → repay | 1,166,000 | 0 | 1,166,000 | 1,150,000 | 16,000 | 1.013913 | 160,000 | 100,000 | 1.600000 | OK |

**Arithmetic (S2):**
- **The loss row (common).** The loan (216,000 owed) defaults; foreclosure + insurance + xALPHA bond + HYDX
  recover **166,000**; the confirmed permanent shortfall is `L = 216,000 − 166,000 = 50,000`. The loan closes:
  `D → 0`, `C += 166,000 → 1,116,000`, `NAV_s = 1,116,000`. `Z` is still 1,150,000 → `σ = −34,000`, `R =
  1,116,000/1,150,000 = 0.970435 < 1`. **I1 fails here, but only pending the resolution** — the
  `DefaultCoordinator` applies a lever atomically at the confirmed-shortfall step, so this under-collateralized
  state is instantaneous, not a state the senior can transact against. The full economic loss is `L = 50,000`
  (34,000 below par + the 16,000 surplus that the shortfall first eats into).
- **Branch A — Lever 1 (burn, I5).** Sequester + burn `L = 50,000` of the junior's Safe zipUSD: `b_zip 100,000
  → 50,000`, so `Z → 1,100,000`. `NAV_s` is **unchanged** at 1,116,000 (burning a zipUSD token touches neither
  `C` nor `D`). `R = 1,116,000/1,100,000 = 1.014545 ≥ 1`, `σ = 16,000` **restored** as the senior cushion. `B →
  160,000`, `B/Loot → 1.60`. Burning **recovered no USDC** — it removed 50,000 of junior *claims* so the
  smaller backing fully covers the smaller senior supply (§11). The junior bore the full 50,000.
- **Branch B — Lever 2 (sell yield, I5).** Market-sell the junior's `b_yld = 50,000` accrued HYDX-vamp yield →
  50,000 USDC → refill the reserve: `C += 50,000 → 1,166,000`, `NAV_s = 1,166,000`, `Z` **unchanged** at
  1,150,000. `R = 1.013913 ≥ 1`, `σ = 16,000`. `b_yld → 0`, `B → 160,000`, `B/Loot → 1.60`. Real external USDC
  refilled the hole, restoring `NAV_s` to its pre-loss level. The junior bore the full 50,000.
- **Branch C — Lever 3 (sell xALPHA, I5).** Same as B but the asset sold is xALPHA (the bond, alpha→TAO→USDC):
  `b_xa 60,000 → 10,000`, `C += 50,000 → 1,166,000`, `Z` unchanged. `R = 1.013913 ≥ 1`, `σ = 16,000`. `B →
  160,000`, `B/Loot → 1.60`. The junior bore the full 50,000.

**S2 result.** All three levers land the junior basket at **`B = 160,000`** (down exactly `L = 50,000`) and the
senior at **`R ≥ 1`** with `σ = 16,000` intact — **I2 + I5 confirmed**. The branches differ only in *which*
basket asset shrinks and in *how* solvency is restored: **lever 1** cuts supply (`Z ↓`, `NAV_s` flat); **levers
2–3** inject USDC (`NAV_s ↑`, `Z` flat). The junior pays the same 50,000 either way; the senior is made whole.
The levers **compose** — if any single asset is short of `L`, mix them "until the hole is filled" (§11) — and
this is the **only** time the junior's zipUSD is touched (never during the S1 duration window).

---

## 4. S3 — insolvency boundary (junior exhausted, then the senior)

The documented boundary (§12: "only after the junior is exhausted is the senior at risk"). A clean minimal
setup (no interest, `σ = 0`) with a **catastrophic** loss that exceeds the whole junior basket, to show I1 can
fail — but only **after** I2 has consumed the junior in full.

| Phase | C | D | NAV_s | Z | σ | R | B | Loot | I1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| P1 Deposit 1,000,000 + zap 100,000 | 1,100,000 | 0 | 1,100,000 | 1,100,000 | 0 | 1.000000 | 100,000 | 100,000 | OK |
| P2 Draw 200,000 | 900,000 | 200,000 | 1,100,000 | 1,100,000 | 0 | 1.000000 | 100,000 | 100,000 | OK |
| Default; recovery 50,000; **L = 150,000** | 950,000 | 0 | 950,000 | 1,100,000 | −150,000 | 0.863636 | 100,000 | 100,000 | **FAIL (pending)** |
| Junior burn 100,000 (basket exhausted) | 950,000 | 0 | 950,000 | 1,000,000 | −50,000 | 0.950000 | 0 | 100,000 | **FAIL (residual 50,000)** |

**Arithmetic (S3):**
- Setup: senior 1,000,000 + junior zap 100,000 → `Z = C = 1,100,000`, `b_zip = 100,000`, `B = 100,000`. Draw
  200,000 → `D = 200,000`, `C = 900,000`. `σ = 0`, `R = 1.0`.
- **Default.** Recovery is only 50,000 of the 200,000 → `L = 150,000`. `D → 0`, `C += 50,000 → 950,000`,
  `NAV_s = 950,000`, `Z = 1,100,000`, `R = 0.863636`. Shortfall = 150,000.
- **Junior absorbs first (I2).** The basket is only `B = 100,000` (all `b_zip`). Realize the loss on it — burn
  the full 100,000 zipUSD: `Z → 1,000,000`, `B → 0` (junior **fully wiped**). `NAV_s = 950,000`, `R =
  0.950000`. The junior absorbed its entire 100,000 of value **before** any senior impairment.
- **Residual.** A `150,000 − 100,000 = 50,000` residual remains; with the junior exhausted and `σ = 0` it falls
  on the senior — `R = 0.95 < 1`. **I1 fails here, exactly once, and only after the junior basket reaches 0.**
  In practice this residual is met by **off-chain insurance beyond the basket** (§11/§13); absent that, it is
  the senior's realized loss — the explicit insolvency boundary.

**S3 result.** I2 held (the junior was consumed in full first); I1 fails **only** at the post-exhaustion
boundary, never before. This is the new-model analog of the old proof's single insolvency row — except the
junior now absorbs via basket-realization (burn/sell), not a pool-share markdown.

---

## Findings

**All invariants hold as required.**
- **I1 (senior solvency `NAV_s/Z ≥ 1`)** holds in every row of S0 and S1, and after **every** lever in S2. It
  fails only (a) **transiently/pending** at the confirmed-loss row of S2 (resolved atomically by the lever) and
  (b) at the **S3 boundary**, and there only **after** the junior basket is exhausted (`B → 0`) — exactly the
  §12 documented insolvency step.
- **I2 (subordination)** confirmed: in S2 the junior bears the full `L` with `σ`/senior untouched; in S3 the
  junior is consumed in full before the senior takes any residual.
- **I3 (ragequit value-preservation)** confirmed at S0 P6: in-kind pro-rata, `B/Loot` unchanged, `Z`/`NAV_s`
  unchanged, no oracle in the exit path.
- **I4 (freeze neutrality)** confirmed at S1: the FREEZE withholds `atRiskAmount/B` of every position and moves
  **no value** — `B`, `Z`, `NAV_s`, `σ`, `R`, `B/Loot` all unchanged; the senior stays covered.
- **I5 (loss-realization completeness)** confirmed at S2: each of the three levers independently restores
  `R ≥ 1` and shrinks `B` by exactly `L`; lever 1 by cutting `Z`, levers 2–3 by injecting USDC into `NAV_s`.

**Model property — strict junior-first-loss, surplus preserved (carried over from the prior proof, re-expressed
on the new substrate).** The old proof established that the junior bears the full loss while the protocol's
surplus stays intact as a senior cushion. That property survives the redesign **mechanism-changed**: there is
**no** `_realizeMarkdown`, **no** `Burn = loss/p` venue-pool-share move, **no** loss-escrow, **no**
markdown/recovery share repricing (the entire old `J×p` machinery is gone, §11). First loss is now (1) a
**WITHHOLD** during the duration window (value-neutral, S1) and (2) a **basket realization** on a confirmed
shortfall (the three levers, S2). The junior still bears `L` first and `σ` still survives — same economics,
different machinery.

**Two-ledger independence (the redesign's core claim) is borne out.** The lending interest (S0 P3) moves only
the **protocol's** `σ`; the xALPHA subsidy + HYDX vamp (S0 P4–P5) move only the **junior's** `B/Loot`. They
never share a price. The junior's `B` is display-only — it sizes the freeze (`lockedFraction`) but never prices
an exit (ragequit is balance-pro-rata), so no oracle sits in any value-moving path.

## Out of scope for this re-derivation (flagged, not rewritten — 8-S3 boundary)

- **`audit/2.md` / `audit/3-results.md`** still carry the **deleted** szipUSD model's acceptance steps —
  convert-on-stake `stake`/`unstake`, the `sUSD3` cooldown, and the `ν = J × p` "I1 sanity" Foundry assertions
  (`A = Z + ν + σ`). Those re-align when the **8-B build tickets** are authored: the on-chain "solvency sanity"
  assertion becomes **I1 (`NAV_s/Z ≥ 1`)** + the basket checks **I3/I5** here; the stake/unstake/cooldown steps
  become the **Baal deposit-shaman / ragequit / lock-shaman** flows (§4.5/§6.4). Noted per the 8-S3 rules; **not
  edited here.**

## Spec changes recommended

**None.** §2/§4.5/§4.6/§11/§12/§17 are internally consistent and fully derivable — the withhold keystone, the
two NAVs, ragequit value-preservation, and the three-lever permanent-loss realization all close arithmetically
across S0–S3. The lever-1 burn correctly assumes the Safe's zipUSD is part of `Z` (so burning it cuts senior
supply, §11) — verified here. No gap or under-specification surfaced; the spec is the authority and `audit/1`
has been made to match it.
