# 8-SY — yield-engine spec pull (auto-sodomizer modules) → build-grade §4.5

**From:** spec-edit window (this session). **To:** the superintendent. **Item:** 8 — `szipUSD`, phase **8-SY**.
**Outcome:** §4.5's yield-engine strategy inventory (the auto-sodomizer loop) **pulled to build-grade,
contract-cited, zero-guess** detail in a new **§4.5.1** so the **8-B5…8-B12** build tickets are authorable
through the normal harness. **No money-model change** (§11/§12/§17 untouched; the spec closes as before).
**Date:** 2026-06-06. **Verdict requested:** ratify §4.5.1; rule on the two flagged build decisions; release 8-B5.

## What this was
A SPEC-EDIT window like Phase 8-S — **not** a build ticket: no `tickets/`, no `contracts/`, no cold-build, no
critic fan-out. I edited **`claude-zipcode.md` only**. The move mirrors Phase 8-S for the money model: the engine
mechanics lived as design narrative in `pending-docs/auto-sodomizer.md` + `hydrex.md` + `monitoring.md`; this
window reconciled them into the spec at WOOF-ticket granularity (the WOOF-07 wrong-vault failure mode is
"building against un-reconciled narrative" — done here before any 8-B5+ ticket).

## What was pulled (into the new §4.5.1)
A shared-architecture preamble + one build-grade block per module:
- **Shared:** every strategy module is a **Zodiac module** on the szipUSD Baal Safe, mutating the basket only via
  `execTransactionFromModule` (`zodiac-core/.../Modifier.sol:60`); the **CRE operator (8-B11) is the only caller**
  (set-once-immutable, §4.4 pattern); the **Safe is its own EVC account** for the reservoir borrow; the `[EXT]`
  compile-vs-interface+fork tiers + the Base address book + the stand-in xALPHA/gauge posture.
- **8-B5** reservoir USDC vault + ICHI-LP escrow collateral + CRE-borrow (EdgeFactory/`createProxy`, `setLTV`,
  `EVC.enableCollateral/enableController`, `EVC.call`→`Borrowing.borrow`, `repay`, `debtOf` — all cited).
- **8-B6** single-sided ICHI LP + gauge-stake; **8-B7** harvest/`Voter.vote`/`exerciseVe` (vote-floor-first);
  **8-B8** exercise/strike-financing (floor pre-check, buffer-first); **8-B9** NFPM range-sell (retrace-guard +
  soft-bleed caps); **8-B10** recycle/payout Mode A/B with the **on-chain free-value-only gate**; **8-B11** the
  on-chain operator surface only (workflow → `spec-clear-CRE.md`); **8-B12** read-only monitoring/TVL-cap.

## Signature verification (the honesty split)
- **Verified against `reference/` (cited `file:line`):** EVK `Borrowing.borrow(:65)/repay(:81)/debtOf(:40)`,
  `Vault.deposit(:124)/withdraw(:153)`, `Governance.setLTV(:281)/setCaps(:369)`, `GenericFactory.createProxy(:116)`,
  `EdgeFactory.deploy(:56)` + `IEdgeFactory.DeployParams(:54)`, `EVC.enableCollateral(:416)/enableController(:462)/call(:553)`,
  `zodiac-core Modifier.execTransactionFromModule(:60)/…ReturnData(:73)` + `Operation.Call=0`, Baal `ragequit(:619)`
  (substrate). These compile/fork-test as cited.
- **NOT in `reference/` → interface+fork, pinned to the Basescan/Sourcify ABI at build (per WOOF-00 `[EXT]`):**
  **ICHI** (`deposit(deposit0,deposit1,to)`), **Hydrex** (oHYDX `exercise`/`exerciseVe`/`getDiscountedPrice`/
  `getMinPaymentAmount`/`getTimeWeightedAveragePrice`; `Voter.vote`/`reset`/`gauges`/`getEpochDuration`; `gauge.deposit`/
  `getReward`; `ve.balanceOfNFT`), **Algebra** (`NFPM.mint`/`increaseLiquidity`/`decreaseLiquidity`/`collect`/`positions`;
  `SwapRouter.exactInputSingle`; `pool.globalState`/`ticks`). These are **design intent from the pending-docs'
  on-chain reverse-mapping** (Sourcify-verified VoterV5 / MinterUpgradeableV3 / OptionTokenV4); the spec marks them
  `[EXT]` and requires the exact signatures be matched to the Basescan-verified ABI at build — **this is the
  established Strategy A, not a gap.** `EulerEarn` is exact `0.8.26` → **mocked** (recycle leg goes through
  `ZipDepositModule`, not a raw EulerEarn import).

## Decisions to sanity-check
1. **Strike capital is protocol/treasury USDC, never depositor or senior backing** — kept the `auto-sodomizer.md`
   §5/§8 invariant. M1 = a fixed protocol USDC buffer; the standing treasury-funded reservoir is the **post-M1
   treasury module** (`treasury.md`). Stated as such, not invented.
2. **The recycle (Mode B) deposit reuses `ZipDepositModule.deposit`** to mint zipUSD backed 1:1 — no new mint
   path, no §5 reopen. zipUSD→xALPHA swap on our POL via Algebra `SwapRouter`.
3. **Free-value-only is enforced on-chain** via a `freeValueAccrued` accumulator the xALPHA-buy leg cannot exceed
   (revert) — promoted from narrative "rule" to a coded invariant, matching `auto-sodomizer.md` §8 ("enforce in
   code, not policy").
4. **8-B11 / `spec-clear-CRE.md` boundary:** I spec only the on-chain operator seam + entrypoint registry; the Go
   workflow + scheduling are explicitly deferred to the CRE window. No duplication.

## Gaps flagged for the user (surfaced, NOT guessed)
- **(Build decision, 8-B5) The reservoir LP-collateral oracle source** — a CRE-fed cache adapter (lien-registry
  shape) vs a fixed conservative-haircut mark. Both are manipulation-safe under CRE-only borrow, so it is a
  **mechanism choice, not an economic one** (§17 honored); flagged in §4.5.1 for the 8-B5 ticket to resolve.
- **External gates (surfaced, not resolved, as instructed):** (1) the **Hydrex gauge whitelist** for our
  zipUSD/xALPHA pool — run against stand-in gauge addresses until the OTC lands (`hydrex.md` §9.4); (2) the
  **xALPHA bridge (8x)** — modules validate against the stand-in 18-dp mock token; real token swaps in.

## §17 / money-model untouched
No new economic decision was introduced. **No `audit/1` follow-up:** none of 8-B5…8-B12 changes a §11/§12
invariant — the strike capital is segregated protocol/treasury USDC (never depositor or senior backing), and
the recycle mint is the existing backed `ZipDepositModule` path. The yield routing (§5/§17: lending APR = the
protocol's → xALPHA; depositor pay = HYDX-vamp + xALPHA subsidy; bounded/TVL-capped/trailing-realized) is
honored verbatim.

## Edits this session
- **`claude-zipcode.md`:** added **§4.5.1** (the build-grade engine spec) at the tail of §4.5; added a
  forward-pointer to it in the §4.5 engine-inventory bullet. Nothing else changed (the §4.5 SUPERSEDED guardrail
  + the `:566-607` convert-on-stake residual are 8-B1's to clear, left untouched).
- **`reports/design/8-SY-spec-report.md`** (this file); **`tickets/PROGRESS.md`** (8-SY DONE; 8-B5…B12 authorable).

## Fidelity pass (post-authoring — fork-reads + adversarial review, 2026-06-06)
After the first draft I hardened §4.5.1 against live Base (8453, via the user's RPC) + a dedicated adversarial
reviewer. **All findings folded in.**

**Fork-verified live (Base 8453; Sourcify ABI for oHYDX `OptionTokenV4`):** all addresses carry code; confirmed
`exercise(_amount,_maxPaymentAmount,_recipient[,_deadline])`, `exerciseVe(_amount,_recipient)`,
`getDiscountedPrice(_amount)` (`discount()=30`, `getDiscountedPrice(1e18)≈12084`), `getTimeWeightedAveragePrice(_amount)`;
`Voter.getEpochDuration()=604800`, `gauges(pool)` resolves to a live gauge `0xAC396Cab…` (`rewardToken()=oHYDX`,
`DURATION()=604800`, `earned`/`balanceOf`); `ve.balanceOfNFT(1)`; `pool.globalState()`.
- **Correction (was wrong):** `getMinPaymentAmount()` takes **NO args** (I had written `(amount)`) — fixed in
  §4.5.1 + the 8-B12 reads list.
- **Added:** the deadline overload of `exercise` (preferred for the bot); NFPM Algebra-Integral `mint(MintParams)`
  carries a `deployer` field; the gauge's staking-token accessor varies by gauge **type** — both pinned at build.

**Two BLOCKERs caught by the reviewer + fixed:**
1. **`EdgeFactory.deploy` renounces all governance** (`setGovernorAdmin(0)` `:88/:117`, `transferGovernance(0)`
   `:123`, LTV baked in `:111`) → `setLTV`/`setCaps` are uncallable afterward and the oracle adapter can't be
   re-pointed. Reworked 8-B5 to the **`GenericFactory.createProxy` path with the §17 TimelockController retained**
   as governor (a standing, tunable facility — distinct from the frozen per-line lien routers §4.7); the oracle
   adapter is now a **deploy prerequisite**, not a deferrable flag.
2. **Gauge-staked-LP vs EVK-collateral simultaneity** was hand-waved. A staked LP is gauge-custodied and can't
   also be escrow collateral. **User correction (this is the right model):** the unstake→collateralize→borrow→
   exercise→sell→repay→re-stake is **THE harvest process**, not an optional leg — the LP is its own working
   capital (self-collateralizing: borrow the ~30% strike against the LP, repay from the HYDX sale, re-stake).
   Rewrote 8-B5 as the **ordered 7-step loop** (spanning 8-B5/B6/B8/B9); the standing USDC buffer is **gone** (the
   borrow revolves — treasury USDC is out only for the short loop window); only the ~30% strike must be sold to
   repay + re-stake, so the unstake window is short and the residual ~70% sells as free value held by the Safe.
   This supersedes `auto-sodomizer.md` §5's "buffer = recommended" lean.

**Lucidity + doc-reconciliation pass (2026-06-06, user-directed):**
- **§4.5.1 now opens with an end-to-end "harvest cycle" overview** — a 7-step read-top-to-bottom flow showing how
  the sub-routines chain (8-B6 LP → 8-B7 harvest → 8-B8 exercise → 8-B5 self-finance loop → 8-B9 sell/repay/re-stake
  → 8-B10 recycle → 8-B11 drives / 8-B12 watches), so each module's flow is legible at a glance. 8-B6 now explicitly
  owns the LP's full lifecycle (build/stake **and** the loop's unstake/re-stake).
- **`auto-sodomizer.md` reconciled + marked** (the established dated-callout pattern): a top **"STRIKE-FINANCING
  CORRECTION (2026-06-06)"** callout; §5 rewritten ("the self-collateralizing borrow loop" — buffer row struck as
  superseded, borrow row marked CANONICAL); §4 step 4 and §9 oHYDX signatures marked with the fork-verified fixes
  (the deadline overload, `getMinPaymentAmount()` no-arg). The pending-doc and the spec now agree.

**Sell-mechanism correction (2026-06-06, user-directed — 8-B9 reframed range-sell → market-sell):**
The loop must **repay the borrow immediately** (interest accrues + the LP earns no oHYDX while it's open), and the
HYDX/USDC pool is **net-draining with no buy-side** (`hydrex.md` §2.3) — so resting NFPM range orders *above spot*
(the old §9.1 ladder) rarely fill. **8-B9 now market-sells** (`SwapRouter.exactInputSingle`) to repay on the spot.
The soft-bleed caps stop being a "sell slowly" rule and become a **size gate on the loop** (only ever borrow an
amount whose repay market-sell fits ~1–2% of the pool); the **regime gate moved upstream to 8-B8** (borrow +
exercise only in UP/FLAT; DOWN → `exerciseVe`, no loop — the commitment gate, so we're never forced to dump into
weakness). Retrace-guard / range-position state dropped. Marked in `auto-sodomizer.md` (top callout + §4 step 5 +
§5 table + §9.1 superseded-for-the-loop); 8-B11 registry updated (`marketSell`; + 8-B6 `unstake`/`restake`, 8-B5
`withdrawCollateral`). **Judgment flagged:** I extended market-sell to the **residual** free value too (not just
the repay), since a net-draining pool won't fill patient orders — if you'd rather pace the residual in UP regimes, say so.

**SHOULD-FIX folded:** corrected the `Modifier.sol:60` cite → the module's inherited `exec(...)`
(`core/Module.sol:43`) forwarding to the Safe's `[EXT]` `execTransactionFromModule`; fixed the `IEdgeFactory.sol`
path → `EdgeFactory/interfaces/IEdgeFactory.sol:54`; pinned `freeValueAccrued` ownership (8-B10-owned, CRE-only
writer, explicit increment/decrement formula); split the **soft profitability-halt (~$0.018)** from the **hard
underwater floor ($0.01)**; scoped the "verified signatures" claim to the vendored set (the `[EXT]` set is
fork-verified + pinned-at-build). The reviewer **confirmed correct**: all EVK/EVC/Zodiac/GenericFactory/EdgeFactory
`file:line`, the Safe-as-its-own-EVC-owner borrow pattern, and the §5/§17 yield-routing invariants.

## Status & NEXT
**8-SY ✅ — 8-B5…8-B12 are now authorable zero-guess from §4.5.1.** The superintendent reviews + releases the
first **8-B5** build window (still gated only on the substrate chain 8-B1…8-B4 + the 8x stand-in xALPHA, all
spec-ready / tracked). The Hydrex gauge whitelist + the LP-collateral oracle source are the two open flags.

## Addendum — 8-B13 Compounder / LP-rebalance (Mode C) added post-8-SY (2026-06-06)
After 8-SY closed, a user-directed pass added a **new engine module beyond the original 8-B5…8-B12 scope**: the
recycle loop's **growth sink**. 8-SY's §4.5.1 left the re-LP/compounding path as a hand-wave ("optionally re-LP
via 8-B6" in 8-B10 / inventory item 7); this addendum promotes it to a first-class module. **The engine is now
8-B5…8-B13.**

**What 8-B13 is.** Modes A/B *distribute* free value; **Mode C reinvests it** and is the strategically dominant
mode — it does two things at once the design is built to maximize: (1) grows the gauge-staked LP (→ more oHYDX →
more HYDX to market-sell = the flywheel), and (2) expands credit lines (the free-value USDC lands as
`CreditWarehouse` senior backing *before* the backed zipUSD is minted, so the same USDC is both lending capacity
and LP raw material — one inflow, double duty, never double-counted).

**The evaluator (the "how much xALPHA" question).** Per CRE pass: budget the Mode-C slice of `freeValueAccrued` →
deposit to warehouse + mint backed zipUSD (`ZipDepositModule.deposit`) → read the ICHI vault target ratio →
**inventory check:** if the basket holds enough xALPHA, add the LP directly; if short, **swap zipUSD→xALPHA on our
POL** (`SwapRouter.exactInputSingle`, slippage-capped — a *buy* of xALPHA, supports the token) to cover the
shortfall → re-derive the balanced pair from post-swap balances → ICHI `deposit` + `gauge.deposit` (delegates to
8-B6's stake leg).

**Invariants (inherit + add).** Free-value-only (the spend is gated by 8-B10's `freeValueAccrued` decrement, same
`onlyCRE` gate as the Mode-B buy leg — reverts if it would exceed; the mint is deposit-backed so never unbacked);
swap is buy-side **and** slippage-capped; no idle-xALPHA accumulation (convert on demand, use on-hand first);
backing automatic. **No §11/§12/§17 change** — Mode C reuses the existing backed `ZipDepositModule` mint path and
the segregated free-value accumulator; no `audit/1` follow-up.

**FLAGGED (Treasury policy, not a build blocker):** the concrete Mode-C/B/A default weights, the taper as the
HYDX bleed degrades, and whether the §4-step-3 vote-floor `exerciseVe` slice is taken before or after the Mode-C
budget. The module is weight-agnostic; only the numbers are open (`treasury.md`).

**Edits.** `claude-zipcode.md` §4.5.1 (new 8-B13 block + engine-inventory item 9 + harvest-cycle step 7 + 8-B10
pointer + 8-B11 registry `compound` + the 8-B5…8-B13 range bumps); `pending-docs/auto-sodomizer.md` (§6 Mode C +
new §11 "The compounding flywheel"); `tickets/PROGRESS.md` (8-B13 row + range bumps; fixed the stale 8-B9
"range-sell"→market-sell and 8-B10 re-LP rows). **8-B13 is now authorable zero-guess alongside 8-B5…8-B12.**
