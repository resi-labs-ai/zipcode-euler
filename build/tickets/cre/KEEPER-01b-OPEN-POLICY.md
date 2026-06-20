# KEEPER-01b — OPEN POLICY (what's NOT decided before the harvest orchestrator can be built)

> A **decision-needed record**, not a build item (sibling to `CRE-OPS-ROUTING.md`). KEEPER-01b drives the engine
> harvest loop (8-B5…8-B10 `onlyOperator` legs) off the `cre/keeper/` spine. The contracts deliberately push all
> *execution policy* off-chain ("8-B11/8-B12 CRE policy") and §17 defers the *economic* knobs to the treasury
> module — so the modules are built and gated, but the **policy that tells the keeper what numbers to pass is not
> pinned anywhere**. This enumerates each undecided knob so the reviewer can ratify it (most have a candidate value
> in `pending-docs/hydrex.md` that just needs lifting into `claude-zipcode.md` §8.7) before a slice is ticketed.
>
> **Verified while writing:** no HYDX price oracle is wired in the engine (`SellModule.sol` has only `swapRouter`;
> `ExerciseModule` reads `oHYDX.getDiscountedPrice/getMinPaymentAmount` for the *strike* only). So every "price" knob
> below is a genuine CRE-side source decision, not an on-chain read that already exists.

---

## RATIFIED 2026-06-19 (reviewer-driven) — the strike-loop core slice is now UNBLOCKED

The cheapest-first-slice set (A1–A4 + C4, plus the B3 quick-win) is decided. The **strike-loop core**
(claim → borrow → exercise → sell → credit/recycle → restake, M1-constant slippage, **no** regime gate / vote /
rotation) is fully specified and buildable as one ordered multi-leg Job. Lifted into `claude-zipcode.md` §8.7.

- **A1 — `sellHydx` `minOut` = live quote − A2 cushion. NOT a 2h-TWAP.** A TWAP sits *above* spot in a declining
  market (the whole thesis: HYDX bleeds to ~$0.015), so a TWAP-derived floor would revert the sell exactly when
  selling is needed; in a rising market the lagging TWAP sets `minOut` too loose and donates value to MEV. The
  keeper eth_call's an **Algebra QuoterV2 `quoteExactInputSingle`** on the HYDX/USDC pool (`0x51f0B932...`) at
  decision time and floors at `quote × (1 − A2)`. **The 2h-TWAP "never sell faster than it follows" steer is
  RELOCATED to C5** — it is a per-epoch *volume/cadence* governor, not a single-swap price floor.
  *Build-time verify (not a blocker for ratification): the exact Algebra QuoterV2 address (the hydrex table lists
  only SwapRouter `0x6f4bE24d...` / NFPM `0xC63E96...`) — resolve it, or read pool `globalState` sqrtPrice + tick
  liquidity. This is the one binding the cold-build must confirm.*
- **A2 — per-order cushion = 200 bps (2%).** ONE M1 constant applied to A1 `minOut`, A3 `minShares`, A4 `maxPayment`.
  Conservative end of the §9.3 ≤2–3% band.
- **A3 — DERIVED (no separate decision).** `addLiquidity` ratio computed from ICHI `getTotalAmounts()`; `minShares`
  = expected × (1 − A2).
- **A4 — DERIVED (no separate decision).** `exercise` `maxPayment` = on-chain `quoteStrike(amount)` × (1 + A2).
  `quoteStrike` already exists on-chain; only the cushion (A2) was open.
- **C4 — fixed M1 Config constants (TUNABLE).** Per-cycle borrow size + recycle-vs-reserve split are hardcoded
  config values mirroring CRE-05a's `harvestReserve`/`safetyBuffer` clamp pattern. **Reviewer flagged these WILL
  need adjustment** with observed performance — they are explicitly tunable M1 constants, and a dynamic-from-LP-
  collateral policy is a documented later swap. The fixed per-cycle borrow inherently bounds the core-slice sell
  volume (each cycle sells only what its borrowed USDC exercised), so C5's per-epoch volume cap is partially
  subsumed for M1 (the on-chain `maxSellHydx` backstop already exists).
- **B3 — LIFTED verbatim (was already user-ratified 2026-06-08).** Taper auto-sell from $0.033 → begin shrinking
  loop size at the ~$0.018 amber tier → fully halt `exercise` at the $0.015 profitability cutoff (accrue oHYDX
  below it). This is a **level check on the A1 live price** — no EMA / state store needed, so it ships in the core
  slice.

**STILL OPEN (own slices, NOT this unblock):** none — the entire own-later set is CLOSED (see note below). Only D1
(rotation) survives, and it is separately deferred to KEEPER-01c (the freeze rebuild).

> **CLOSED — the entire KEEPER-01b own-later set (reviewer-driven 2026-06-19): B1, B2, C1, C2, C3, C5.** These were
> the regime / ve-allocation / epoch-cadence knobs: B1 (regime classifier + EMA), B2 (keeper STATE store), C1 (vote
> weights), C2 (lock-vs-sell split), C3 (`claimRebase` set), C5 (per-epoch volume cap + epoch definition + the
> relocated TWAP cadence steer). All cut: they are the ve-allocation / regime / epoch-cadence **process, which is
> not built out in the MVP.** None is a build item. The strike-loop core already ships the only price-reactive
> behavior in scope — the level-based B3 taper/halt (shrink at the amber tier, halt below the profitability
> cutoff). The B/C rows below are retained only as the historical record of the questions. Rotation (D1) stays
> separately deferred to KEEPER-01c.

---

## A. Execution / slippage floors (the args the legs REQUIRE; source = "CRE policy")
| # | Undecided knob | Leg | Candidate (source) | Blocks |
|---|---|---|---|---|
| A1 | **`sellHydx` `minOut` price source** — no on-chain HYDX→USDC reference exists. Algebra QuoterV2 quote − bps? a pool 2h-TWAP? an off-chain feed? | 8-B9 `sellHydx` | "never sell faster than the **2h-TWAP**" (hydrex §9.3) ⇒ TWAP-bracketed minOut is the steer, but the *source contract* isn't chosen | the sell leg AND the regime EMA (same price) |
| A2 | **Per-order slippage cushion** for `minOut` / `maxPayment` / `minShares` | 8-B8/B9/B6 | per-order slippage **≤ 2–3%** (hydrex §9.3) — ratify the exact bps | every priced leg |
| A3 | **`addLiquidity` ratio + `minShares`** — single-side vs balanced split + the share floor (off ICHI `getTotalAmounts()`) | 8-B6 | none pinned (compute ratio from `getTotalAmounts`, floor by A2 bps) | the restake leg |
| A4 | **`exercise` `maxPayment`** = `quoteStrike(amount)` × (1 + cushion) | 8-B8 | `quoteStrike` EXISTS on-chain — only the cushion (A2) is open. *Nearly decided.* | the exercise leg |

## B. Regime classifier + keeper state
| # | Undecided knob | Detail | Candidate | Blocks |
|---|---|---|---|---|
| ~~B1~~ | ~~**Regime price source + EMA params**~~ **— REMOVED as a slice (see note above).** A UP/FLAT/DOWN regime gate (price vs short EMA + fill%) was speculative policy machinery; the core loop's level-based taper/halt (B3) is the only price-reactive behavior in scope. | — | — |
| ~~B2~~ | ~~**Keeper STATE store**~~ **— REMOVED as a standalone slice (see note above).** The KEEPER-00 spine is a stateless poll; if B1 needs cross-tick memory it is decided + built *inside B1* (leading candidate: recompute-from-chain off the Algebra oracle timepoints — no persistence). | — | — |
| B3 | **Price tapering / halt tiers** | shrink loop size as HYDX falls; halt below the profitability cutoff | **taper from $0.033 → shrink at ~$0.018 → halt at $0.015** (hydrex §9.3, marked **user-ratified 2026-06-08**) — appears DECIDED, just **not lifted into §8.7**; confirm + pin | loop-size sizing |

## C. Governance / allocation (the §17-deferred economic knobs)
| # | Undecided knob | Leg | Note | Blocks |
|---|---|---|---|---|
| ~~C1~~ | ~~**Vote weights**~~ **— REMOVED as a slice (reviewer-driven 2026-06-19).** Pool/weight allocation for `vote(poolVote[], weights[])` is §17-parked on the treasury module with no ratified pool set or weights; not a build item. | — | — |
| ~~C2~~ | ~~**lock-vs-sell split**~~ **— CLOSED (out of MVP scope).** The lock-vs-sell ve allocation is not built out in the MVP. | — | — |
| ~~C3~~ | ~~**`claimRebase` ve-position set**~~ **— CLOSED (out of MVP scope).** ve rebase claiming is not built out in the MVP. | — | — |
| C4 | **Borrow size + recycle/reserve split** — per-cycle borrow off LP collateral; recycle vs working-capital reserve | 8-B5/B10 | mirror CRE-05a's `harvestReserve`/`safetyBuffer` **M1 constants** (a dynamic policy is a later swap) | sizing the strike loop |
| ~~C5~~ | ~~**Per-epoch volume cap + epoch definition**~~ **— CLOSED (out of MVP scope).** The per-epoch cadence/cap governor is not built out in the MVP; the on-chain `maxSellHydx` backstop + the fixed C4 per-cycle borrow already bound sell volume for M1. | — | — |

## D. Deferred (do NOT decide here)
| # | Item | Why deferred |
|---|---|---|
| D1 | **main↔sidecar rotation** (`commit`/`release` sizing) | Entangled with `DurationFreezeModule`, which is **INCOMPLETE / premise-under-review** (can't move the staked LP that is the bulk of TVL — PROGRESS Open obligations + `wires/DurationFreezeModule.md`). Re-decide at the freeze rebuild = **KEEPER-01c**, not 01b. |

---

## What this implies for building 01b
- **Cheapest path to a first slice:** ratify **A1–A4 + C4** (execution floors + sizing constants) — then the
  **strike-loop core** (claim → borrow → exercise → sell → credit/recycle → restake) is buildable as one ordered
  multi-leg Job with M1-constant slippage, **no regime gate** (run on a `pendingReward` threshold), no vote, no
  rotation. That is the smallest coherent, fully-specified unit.
- **The entire own-later set (B1, B2, C1, C2, C3, C5) is CLOSED** — the regime / ve-allocation / epoch-cadence
  process is not built out in the MVP (see the note above). Nothing in it is a build item.
- **D1 (rotation)** stays with the freeze rebuild (01c).
- **Quick win:** **B3** (price taper/halt) looks already user-ratified in hydrex.md — likely just needs lifting into
  `claude-zipcode.md` §8.7 verbatim, not re-deciding.

## Done when (this record)
- This file enumerates the open knobs with their candidate sources + what each blocks. **No code.**
- A pointer added in `claude-zipcode.md` §8.7 (the harvest-orchestrator policy is tracked here).
- `PROGRESS.md` updated: KEEPER-01b is **policy-blocked**; this record is its agenda; the strike-loop slice is
  unblocked once A+C4 are ratified.
