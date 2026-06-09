# reports/ — the index (READ THIS FIRST)

Three kinds of file live here: **build reports**, a **design** (spec-pivot) trail, and **research**. **Every file
listed below is current — we do NOT keep dead reports.** Filenames carry no status, so this index is the source
of truth; read it before opening any report.

A **window report** is written when a window concludes (`audit/adversarial-spec/README.md` §6 "Conclude"):
TL;DR · what it did · decisions to sanity-check · holes → resolution · doc edits · status + NEXT. It is the trail
that lets a fresh context resume without conversation history.

---

## Folder layout + filing rules

| Location | Holds | File a NEW one here when… |
|---|---|---|
| `reports/*.md` (top) | **BUILD reports** — one per built/cold-built contract ticket (`WOOF-NN`, item reports). | a window concludes by authoring/building a ticket. Name it `<ITEM>-report.md`. |
| `reports/design/` | **DESIGN-PIVOT / SPEC reports** — a window that concluded on a **spec change** (a redesign, a spec-step edit, the `audit/1` re-derivation). The **"why the spec says what it says"** trail. | a window concludes on a spec edit rather than a ticket. |
| `reports/research/` | **RESEARCH / THEORY** — standalone investigations that *ground* a decision (multi-repo + web research, `deep-research` outputs, option A-vs-B studies). | you produce an investigation that weighs options or verifies facts. |

**Keep the tree lean — no dead reports.** The reliable recipe is the **tickets + the committed, building code**
(+ `claude-zipcode.md` + the `audit/` harness); reports are the rationale trail that supports them. *(Note: the
old "a cold-build is a disposable byproduct" framing is RETIRED as of 2026-06-06 — under the keep-the-build
doctrine the build is committed, not discarded; see `kickoff.md`. Reports remain disposable rationale; the **code**
is now a kept artifact.)* When a report is **superseded, delete it** (do not archive it) **and fix every
reference to it** — a kept-but-dead report is just a stale reference waiting to mislead (we have been bitten by
these repeatedly). A report that goes *partly* dead is resolved the same way: lift any still-live decision into
the **live spec/memory**, then delete the report. There is no `archive/`.

> **Pruning is permanent right now:** `reports/` and `tickets/` are **untracked in git** (only the original design
> docs are committed), so deleting here cannot be undone via `git`. If you want a recoverable snapshot before a
> large prune, **commit first** — and ideally get `tickets/` into git, since the recipe itself is uncommitted.

---

## Current report per item (the map you actually need)

| Thing | Current report(s) | Notes |
|---|---|---|
| **WOOF-00** scaffold | `WOOF-00-report.md` | **BUILT-VERIFIED 2026-06-06** — materialized + builds green on disk (`contracts/`); interfaces + address book on-chain-verified (2 address bugs + 10/25 sigs fixed). First item under the keep-the-build doctrine. |
| **WOOF-01** lien token/factory | `WOOF-01-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **14/14 tests pass**; code kept on disk. Zero-spec-guess keepsake (no build-exposed errors). |
| **WOOF-02** oracle registry | `WOOF-02-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **34/34 tests pass**; scale identity + strict-decimals guard proven on-chain-shape. Zero-spec-guess keepsake. |
| **WOOF-03** gating hook | `WOOF-03-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **8/8 tests pass** (56/56 total); `borrowDriver` immutable + `NotAuthorizedOperator()` `0x3d9adf1c` + isProxy spoof-guard confirmed. Consolidated re-author/reconcile narrative + the materialization. |
| **WOOF-04** venue adapter | `WOOF-04-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **20/20 new tests pass** on a live Base-mainnet fork (76/76 total); two-line distinct-prefix both-draw isolation + operator-grant + AmountCap + router-freeze + close-reclaim live-fork-proven, EulerEarn mocked (0.8.26). Zero spec-guesses (1 mild ticket cap-seed clarification folded). |
| **WOOF-05** controller | `WOOF-05-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **26/26 new tests pass** on a live Base-mainnet fork (102/102 total, no regression); zero-EVC-coupling + 5-arg ctor + `create→openLine→seed→setLineLimits→fund→draw` ordering + reclaim-before-burn + the no-controller-operator-wiring borrow all live-fork-proven. Zero-spec-guess keepsake confirmed (no build-exposed errors). |
| **WOOF-10a** deploy identity gate | `WOOF-10a-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-06** — `forge build` green, **5/5 tests pass** (107/107 total, no regression; no fork — pure view over the real WOOF-02/05 keepsakes). The combined fail-closed S11 pre-gate + the dormancy selector-difference proof; zero-spec-guess keepsake confirmed. |
| **8-B1** Baal substrate scaffold | `8-B1-report.md` | **BUILT-VERIFIED 2026-06-07** — summon script against the live `BaalAndVaultSummoner`; 8/8 fork tests (115/115 total). Two-tier authority model ratified; main-Safe addr computed-then-asserted. |
| **8-B4** `SzipNavOracle` | `8-B4-report.md` | **MATERIALIZED + BUILT-VERIFIED 2026-06-07** — `forge build` green, **39/39 tests** (incl. live Base-fork sig-verification); 154/154 total, no regression. The szipUSD issuance/exit NAV primitive (on-chain compose + windowed-TWAP + bracket + provision seam). 3 spec gaps fixed (§4.4/§7/§12); `IOptionToken.discount()` added. Caveat: authored+built in one window (build-subagent dropped), fresh-subagent zero-guess gate not run independently. |
| **Exit Gate + szipUSD** | `Exit-Gate-report.md` | **BUILT-VERIFIED 2026-06-08** — `SzipUSD` (transferable share) + `ExitGate` (sole Loot custodian/manager(2)/szipUSD minter/ragequit caller): `depositFor` NAV-proportional issuance, `processWindow` **plain in-kind ragequit** (pro-rata slice of the free basket → the leaver; structural sidecar freeze), `burnFor` the §7/8-B14 retire. **17/17 on a live Base fork** (real Baal substrate + real oracle + mock basket), 174/174 total. 2 spec gaps fixed (§7 `valueOf` + the kept-oracle view; §6.4 windowController + in-kind exit). Exit reworked from a first zipUSD-numeraire draft to pure in-kind (user-directed 2026-06-08); xALPHA→zipUSD dump = new ticket `8-B-exit-autodump.md`. Caveat: authored+built one window. |
| **8-B5** reservoir strike-loop | `8-B5-report.md` | **BUILT-VERIFIED 2026-06-08** — the 2nd engine Zodiac Module (`ReservoirLoopModule`) + `SzipReservoirLpOracle` (CRE push-cache, `LP_MARK`) + `ReservoirBorrowGuard` (pins `OP_BORROW` to the engine Safe) + `ReservoirMarketDeployer`. CRE-`onlyOperator` `is Module` driving the szipUSD Safe's OWN EVC account through unstake→post→borrow→repay→withdraw. **33/33 Base-fork, 271/271 total** (superintendent-reverified). 4 build-exposed corrections folded (C1 Safe-swallows-reverts→`_exec` bubbles — a pattern for 8-B6…B13; C2 `repay` reverts `E_RepayTooMuch`; C3 borrow gates `borrowLTV`; C4 `setLTV` needs live mark + `transferGovernance(timelock)`). 2 §4.5.1 clarifications; 1 SPEC-GAP (`LP_MARK` in §8) deferred to CRE. |
| **8-B6** LP strategy module | `8-B6-report.md` | **BUILT-VERIFIED 2026-06-08** — `LpStrategyModule`, the 3rd engine Zodiac Module (simplest: no EVC/oracle/hook). `addLiquidity`(direct `IICHIVault.deposit` + `minShares` floor)/`stake`/`unstake`, all `onlyOperator` scalar-only, deposit-`to`/views pinned to `engineSafe`, Call-only, no custody, no storage in any mutating path. **29/29 (24 unit + 5 Base-fork), 300/300 total** — superintendent-reverified against the pinned Alchemy RPC (builder's public-RPC run confirmed). Direct deposit proven against the real ICHI vault `0x07e72…` (DepositGuard not needed). 1 spec gap fixed (§4.5.1 "single-sided only" → balanced add allowed for 8-B13; `allowToken0/1` gates legality). Superintendent pinned the 8-B5↔8-B6 LP-token-identity item-10 obligation. |
| **8-B7** harvest/vote module | `8-B7-report.md` | **BUILT-VERIFIED 2026-06-08** — `HarvestVoteModule`, the 4th engine Zodiac Module (simplest sibling of 8-B6: no EVC/oracle/custody/approvals, **NO tokenId state**). 5 `onlyOperator` mutators (`claimReward`/`lockVe`/`vote`/`resetVote`/`claimRebase`) + 3 views; `exec(Call,value 0)` via `_exec`-bubble; `exerciseVe` recipient + reads pinned to `engineSafe` (the irreversibility firewall). **26/26 (21 unit + 5 Base-fork), 326/326 total**, **ZERO load-bearing guesses**. **5 spec corrections to the on-chain-verified Hydrex surface** (`§4.5.1` + `baal-spec §10.8`): VoterV5 is **account-keyed** (`vote`/`reset` no tokenId), floor=`ve.getVotes(account)` not `balanceOfNFT`, state=none/no-tokenId, rebase via the **RewardsDistributor** not the Minter, `getEpochDuration`=604800. Build-exposed test-sequencing folded (epoch snapshot + `Minter.update_period()`; per-account ~1h vote-delay). Over-lock guard → 8-B11/8-B12 monitoring obligation (`exerciseVe` is irreversible). |
| **8-B8** exercise module | `8-B8-report.md` | **BUILT-VERIFIED 2026-06-08** — `ExerciseModule`, the 5th engine Zodiac Module: the **paid** oHYDX-exercise (strike-financing) leg — the *paid* counterpart to 8-B7's free `exerciseVe`. Sibling of 8-B5's approve→call→reset USDC dance MINUS the EVC leg; stateless, no EVC/oracle/LP/veNFT. ONE `onlyOperator` `exercise(amount, maxPayment, deadline)` = `USDC.approve(oHYDX,maxPayment)` → `oHYDX.exercise(amount,maxPayment,engineSafe,deadline)` (4-arg deadline overload; burns the Safe's oHYDX, pulls ≤maxPayment USDC, mints HYDX to the Safe) → `approve(oHYDX,0)`; recipient-pinned to `engineSafe`, value-0/Call-only/`_exec`-bubble, `paymentToken` live-read, KR5 `paymentAmount≤maxPayment` honesty guard, `quoteStrike` view. **25/25 (21 unit + 4 Base-fork real `oHYDX.exercise`), 351/351 total**, **ZERO load-bearing guesses**. All oHYDX selectors on-chain-verified. Spec-fidelity FAITHFUL (no §17 reopen, no inbound obligations); 1 cosmetic §4.5.1 8-B8 "State" tidy. Critic-hardened: malicious-oHYDX single-tx pull ceiling = `maxPayment` → 8-B11 TIGHT-cushion obligation; state-moving allowance-reset/rollback tests; atomic front-run-safe deploy+setUp obligation. |
| **8-B9** sell module | `8-B9-report.md` | **BUILT-VERIFIED 2026-06-08** — `SellModule`, the 6th engine Zodiac Module: the **swap leg** (sibling of 8-B8, NO EVC/oracle/repay). Two `onlyOperator` mutators sharing a private `_swap` approve→`exactInputSingle`→reset dance: `sellHydx`(HYDX→USDC, the 8-B5 strike-loop repay leg) + `buyXAlpha`(zipUSD→xALPHA, the 8-B10/8-B13 Mode-B/C POL buy leg). recipient/`deployer=0`/`limitSqrtPrice=0`/token-pair hard-pinned, typed `abi.encodeCall`, `minOut` slippage guard (PRICE bound) + a per-call `maxSellHydx` SIZE cap (default 300k HYDX, owner-settable, `ExceedsMaxSell` — the on-chain whole-basket-dump backstop, user-directed; `buyXAlpha` uncapped), value-0/Call-only/`_exec`-bubble, decode+emit `Sold`. **31/31 (27 unit + 4 Base-fork real `exactInputSingle`), 382/382 total**, **ZERO load-bearing guesses, zero ticket discrepancies**. Algebra Integral router on-chain-verified (selector `0x1679c792`, `algebraSwapCallback` present, no `fee`; base-factory pool ⇒ `deployer=0`; token0=HYDX/token1=USDC; the real fork swap pins the struct field order). **1 spec-gap fixed:** §4.5.1 8-B9 "State: per-epoch accumulator" → "no module state" (cap = 8-B11/8-B12 CRE size-gate; on-chain epoch accumulator considered + REJECTED for sibling-consistency + §17; spec-fidelity + security critics confirmed). Security: compromised-operator whole-basket dump = CRE-key loss bounded by the 8-B12 off-chain tripwire, not a module bug. `buyXAlpha` unit-only (no live POL pool yet → fork proof deferred to 8-B10/8-B13). |
| **8-B10** `RecycleModule` (single recycle sink) | `8-B10-report.md` | **REWORKED → `RecycleModule` + BUILT-VERIFIED 2026-06-08** (user-directed single-sink redesign; supersedes the original `RecyclePayoutModule`). ONE action: `recycle(usdc)` = `_spendFreeValue` → `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the MAIN-Safe basket** (no `gate.depositFor`, no shares); 8-B6 single-sides it into the gauge-staked LP → **NAV-per-share accretes for every holder** (the depositor's M1 return). Kept `freeValueAccrued`+`creditFreeValue`+`recycle`+internal `_spendFreeValue`; **DELETED** `payoutClean`/`payoutBoost`/public `spendFreeValue`/`setCompounder`/`xAlpha`/`distributor`/`compounder` + the entire `SzipRewardsDistributor`. **8-B13 REMOVED** (absorbed here — single-sided LP moots the balanced-add compounder). **19/19 (16 unit + 2 integrated + 1 Base-fork), superintendent-reverified**; full suite **401/401 GREEN** (an 8-B6 fork non-determinism can intermittently show 2 `LpStrategyModule` DTL reverts — unpinned fork + fixed live-vault deposit; passes 5/5 in isolation, zero coupling; fix = pin the fork block). Spec/docs reconciled (§4.5.1/§2/§17; baal-spec/auto-sodomizer/treasury). `RecyclePayoutModule.*`+`SzipRewardsDistributor.*` deleted. |
| **8-B14** `SzipBuyBurnModule` | `8-B14-report.md` | **BUILT-VERIFIED 2026-06-08** — the §7 buy-and-burn **bid side** (the burn = the kept `ExitGate.burnFor`). First engine Zodiac Module (`is Module`/`setUp`/`onlyOperator`/Call-only): posts a single resting CoW `BUY szipUSD` PRESIGN bid priced `≤ navExit×(1−d)`, `≤ buybackCap`, on-chain GPv2 uid + `setPreSignature` (no delegatecall), exact USDC approve. **33/33 Base-fork, 238/238 total**, zero load-bearing guesses. 3 spec edits to `baal-spec §7.2/§7.4` (price off `navExit`=min not twap; windowController burn caller; drop "Roles-scoped"). **Caught + reverted a forbidden `reference/zodiac-core` edit** by the cold-build subagent (reference is pristine; dropped the `setAvatar`/`setTarget` hard-lock for the inherited `onlyOwner`). |
| **item 7 — `ZipDepositModule` (the zap)** | `WOOF-06-report.md` | **SUPERSEDED-AGAIN 2026-06-07 → re-author in progress.** The 2026-06-06 re-author (Baal+`CreditWarehouse`, cold-build 32/32) was for the pre-two-token design (zap minted **Loot on-behalf to the user**). The two-token/Exit-Gate redesign (`baal-spec.md`) flips the junior seam to `Gate.depositFor(zipUSD, amount, user)` → **transferable szipUSD, NAV-proportional**; WOOF-06+INFLOW-06 re-authored, stub deleted, cold-build deferred to post-Gate. Custody/decimals/hardening carry forward. |
| **item 8 — `szipUSD` (Baal NAV vault)** | `design/szipUSD-baal-redesign-report.md` + `design/8-S3-report.md` + `research/zodiac-warehouse-research.md` | the current design. WOOF-07 was DELETED; item 8 is the Baal/Zodiac auto-sodomizer vault, decomposed into Phase 8-S (spec edits, **DONE**) + Phase 8-B (build tickets, TODO). 8-Bw (`CreditWarehouse`) admin = **Roles Modifier v2** (see the research). |
| **borrower model** (why WOOF-03/04/05 look as they do) | `design/borrower-model-spec-report.md` | per-line `LineAccount` + controller-as-operator → unbounded lines. Rework complete. |
| **xALPHA / yield routing** | *(no report — the supply-side redesign report was deleted as half-dead)* | the live decisions are in `claude-zipcode.md` §5/§17 + memory `supply-side-redesign-locked`. |

---

## Timeline — live reports only (oldest → newest)

| When (Jun) | Report | Loc | Note |
|---|---|---|---|
| 04 21:31 | `WOOF-01-report.md` — lien token/factory | top | |
| 04 22:16 | `WOOF-02-report.md` — oracle registry | top | |
| 05 01:48 | `WOOF-00-report.md` — scaffold | top | |
| 05 13:58 | `WOOF-10a-report.md` — deploy identity pre-gate | top | |
| 05 18:06 | `borrower-model-spec-report.md` — borrower rework (spec) | design | |
| 05 18:19 | `WOOF-03-report.md` — operator-auth gate on borrowDriver (re-author + reconcile, consolidated) | top | final WOOF-03 |
| 05 18:44 | `WOOF-04-report.md` — +`LineAccount` | top | |
| 05 19:15 | `WOOF-05-report.md` — no EVC handle | top | |
| 06 01:41 | `szipUSD-baal-redesign-report.md` — item 8 → Baal NAV vault + withhold money model | design | current szipUSD design |
| 06 01:54 | `8-S3-report.md` — `audit/1` re-derivation (I1–I5, S0–S3) | design | completes Phase 8-S |
| 06 11:18 | `WOOF-06-report.md` — item 7 re-author (Baal + `CreditWarehouse`, cold-build 32/32) | top | |
| 06 (build) | `WOOF-04-report.md` — venue adapter MATERIALIZED + BUILT-VERIFIED (20/20 fork, 76/76 total) | top | rewritten from the re-author report to the kept-code verdict |
| 06 (build) | `WOOF-05-report.md` — controller MATERIALIZED + BUILT-VERIFIED (26/26 fork, 102/102 total) | top | rewritten from the re-author cold-build report to the kept-code verdict |
| 06 (build) | `WOOF-10a-report.md` — deploy identity gate MATERIALIZED + BUILT-VERIFIED (5/5, 107/107 total) | top | rewritten from the cold-build report to the kept-code verdict |

(The 1st-pass WOOF-03/04/05 reports + their cold-builds + the supply-side redesign report were **deleted** when
superseded — no archive is kept.)

---

## design/ — the design-pivot & spec trail (the "why" behind the spec)

Decision records, not build reports. Read them for *why* a major design decision was made, not to build a
contract. **Point-in-time records: their "NEXT" lines may be stale** — for current state trust
`claude-zipcode.md` + `tickets/PROGRESS.md`; trust these for the *why*.

| File | What it decided | How to treat it |
|---|---|---|
| `design/szipUSD-baal-redesign-report.md` | Reopened item 8; szipUSD → **Baal/Zodiac NAV vault** + **withhold-not-markdown** money model; deleted WOOF-07; decomposed item 8 into Phase 8-S/8-B. | **CURRENT** — the live item-8 design + money model. Load-bearing for any item-8 work. |
| `design/8-S3-report.md` | Re-derived `audit/1` to the new model (invariants I1–I5, scenarios S0–S3, three-lever loss proof). | **CURRENT** — the proof behind the live money model; completes Phase 8-S. |
| `design/borrower-model-spec-report.md` | The borrower-of-record rework (per-line `LineAccount` + controller-as-operator → unbounded lines). | **ACCURATE, historical-complete** — the rework is done (WOOF-03/04/05 re-authored); this is *why* they look the way they do. |
| `design/structural-freeze-shrink-report.md` | Locked the Duration-Bond freeze as **structural/utilization-sized, owned by the Exit Gate** (not engaged on default); **shrunk `DefaultCoordinator`** to markdown-writer + xALPHA recovery waterfall; **pulled `LienXAlphaEscrow` forward** off M2 (item 8-Bx). | **CURRENT** — the live freeze/loss-ownership split. Load-bearing for the Exit Gate + the loss-side builds. |

---

## research/ — investigations that ground decisions

| File | What | Status |
|---|---|---|
| `research/zodiac-warehouse-research.md` | The `CreditWarehouse` admin-mechanism study: purpose-built Zodiac module (A) vs **Roles Modifier v2** (B), across 7 Gnosis Guild repos + web/audit sources. Resolved → **B**, user-ratified. The hard-truth basis for the 8-Bw build. | CURRENT |

---

## The story so far (one paragraph)

Items 00–05 + 10a were authored first; then the **supply-side redesign** (xALPHA/yield decisions — now in the
spec; its report was deleted); then the **borrower-model rework** re-authored WOOF-03/04/05 to the per-line
`LineAccount` model; then the **szipUSD Baal redesign** reopened item 8 — deleted the wrong WOOF-07 vault,
rewrote the §11/§12/§17/§4.5/§4.6 money model to **withhold-not-markdown + three-lever** loss realization, and
decomposed item 8 into Phase 8-S (spec edits, now DONE — incl. the two-Safe `CreditWarehouse` custody) + Phase
8-B (build tickets, TODO). The **Zodiac research** settled the warehouse admin on **Roles Modifier v2**, and
**item 7 (the zap) was re-authored** to the Baal + `CreditWarehouse` model and **passed cold-build (32/32)**.
**Phase 8-S is complete. The substrate + supply chain is built (8-B1, `SzipNavOracle`, Exit Gate + szipUSD, the
WOOF-06 zap, and 8-B14 buy-and-burn — all BUILT-VERIFIED). The yield engine is underway: **8-B5 (reservoir
strike-loop) + 8-B6 (LP strategy module) + 8-B7 (harvest/vote module) + 8-B8 (exercise module) + 8-B9 (sell module) + 8-B10 (`RecycleModule` — the single recycle sink) BUILT-VERIFIED 2026-06-08. **8-B13 REMOVED** (absorbed into 8-B10 by the single-sink rework). **The engine's on-chain contracts are DONE** — 8-B11 (CRE robot) + 8-B12 (monitoring) are off-chain; remaining contracts are 8-Bw (CreditWarehouse), the loss side (M2), the senior queue, and item-10 deploy (`baal-spec §13` order / `§10.8` per-module specs);
then 8-Bw (`CreditWarehouse`), the loss side, and the senior queue. (Trust `tickets/PROGRESS.md` for live state.)

## Stray root-level `../report.md`
A June-4 one-off WOOF-01 authoring report at the repo root — historical leftover, not part of this index, not a
living doc. (Delete it too if you want the tree fully lean.)
