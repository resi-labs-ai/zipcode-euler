# Report — item 9 `ZipRedemptionQueue` (the senior zipUSD → USDC epoch queue)

**Window:** 2026-06-09 · build-only (internal senior-exit plumbing; redeem UI folds into the post-deploy frontend sweep)
**Ticket:** `tickets/sodo/9-zip-redemption-queue.md` · **Code (kept, green):** `contracts/src/supply/ZipRedemptionQueue.sol` + `contracts/src/interfaces/euler/IZipUSD.sol` + `contracts/test/ZipRedemptionQueue.t.sol`

---

## TL;DR
The senior exit is built and fork-proven: un-staked **zipUSD → USDC at par**, a **30-day pro-rata epoch queue** with carry-forward, funded by the warehouse REDEEM→REPAY seam, gated by an immutable `controller`, non-sweepable, never renounced. **44/44 new tests** (37 unit + 5 invariant/fuzz over 128k calls + 2 Base-fork), **468/468 full suite, no regression.** ZERO load-bearing guesses. The harness caught **two real bugs before any code was written** — a div-by-zero and a CRITICAL silent value-destruction — both fixed in the ticket. Code is on disk, **not committed** (consistent with recent windows; your call).

## What the window did
1. Verified the "Model from" by inspection: `reference/erc7540-reference` (the `requestRedeem→fulfill→claim` lifecycle + `setOperator`), `reference/maple-withdrawal-manager` (the pro-rata `:367-387`), `ESynth.sol:81` (the own-balance burn seam), `ZipDepositModule.sol` (the `scaleUp` derivation + the inverse mint), `WarehouseAdminModule.sol:115-118` (the REPAY funder).
2. Drafted the ticket; fanned out 5 critics (junior/spec-fidelity/ref-verifier/qa/security).
3. Triaged + revised the ticket; fixed the two bugs; folded all qa/security/ref findings.
4. Made one faithful spec clarification (`claude-zipcode.md §6.1`).
5. Cold-built from the ticket (fresh subagent, zero-guess) and **independently re-ran** the full suite myself: 468/468.

## Design decisions to sanity-check (the ones I'd want a second opinion on)
1. **Clean-room, not inherited.** The ERC-7540 reference (`BaseERC7540 is ERC4626, Owned`) assumes the share == the vault itself + NAV `convertToAssets` + a mutable owner — all three wrong for us (the redeemed share is *external* zipUSD, conversion is *par*, ownership is an *immutable controller*). I built clean-room keeping the function names/signatures/events + operator-approval, and cite the reference lines as the model. **Faithful to "fork the lifecycle" intent?** I judged yes (you can't inherit it without fighting it on every axis), and spec-fidelity agreed.
2. **The pro-rata mechanism = a global cumulative-remaining factor + `era` counter** (O(1), iteration-free, auto-carry, censorship-resistant). I considered the simpler "controller passes the requester list" model (mirrors Maple's delegate-driven settle + `fulfillRedeem`), but it either loops unboundedly or breaks fairness under sharding (a sharded pro-rata can't share one global denominator). The global factor is the minimal *correct* primitive for fair + carry-forward + O(1). **It is the one intricate part of the contract** — the rounding directions (ceil pendingNow / floor filled / round-up R) and the era reset are subtle, which is why the solvency proof is encoded as a fuzz invariant (`ghost_totalPaid <= ghost_totalDelivered`, 128k calls). If you want a simpler-but-loopier design, this is the place to push back.
3. **`require(shares % scaleUp == 0)` (whole-USDC-unit requests).** This is the fix for the CRITICAL below, but it is also a *user-visible constraint*: a holder with an odd zipUSD balance redeems the whole-unit floor and keeps/sells the sub-unit (<$0.000001) remainder on the AMM. I judged this natural for par redemption to 6-dp USDC (you can't redeem a fraction of the smallest USDC unit) and added a §6.1 note. **Confirm you're comfortable with the constraint** (the alternative — handling sub-`scaleUp` dust internally — reintroduces the value-destruction failure mode).
4. **`controller` = a single immutable address = the CRE redemption-settle operator** (CRE-02), decoupled from the §4.4 `ZipcodeController`. §4.5/§8.3 say "the controller keeps calling `settleEpoch`"; I read that as the settle operator, not the origination controller. Wire it at item-10 as a *distinct* identity. **Flag if you intended the §4.4 controller.**
5. **The queue is funded by REPAY, reads its own USDC balance, calls no EulerEarn.** §6.1's prose says "read freeable USDC from the venue pool," but §8.3/§8.5 + the as-built 8-Bw reconciled this to REDEEM(→Safe)→REPAY(→queue)→settle. I followed the as-built seam (the obligation row 317). spec-fidelity confirmed this is reconciliation, not drift.

## Holes surfaced → resolution
- **(div-by-zero, junior-dev, blocking)** `cumRemaining *= R` hits 0 on a 100% fill → next request sets `cumAt=0` → division-by-zero. **Fixed:** an `era` counter — a full drain bumps `era` + resets `cumRemaining=PREC`; `eraAt[r] < era ⇒ fully filled` (no stale factor ever divided).
- **(CRITICAL, security)** the era bump keyed on `filledShares == pending`, but `filledShares` is always a `scaleUp` multiple while `pending` (zipUSD) can carry sub-`scaleUp` dust → the era could **never** bump → `cumRemaining` decays to 1 → the queue burns zipUSD while **no requester can ever claim**, and *every stated invariant still passes*. **Fixed:** `require(shares % scaleUp == 0)` ⇒ `totalPending` is always a `scaleUp` multiple ⇒ a full fund reaches `filledShares == pending` ⇒ the era bump fires. Also eliminates the sub-`scaleUp` dust-trap (an unfillable, uncancellable request). This was the highest-value find of the window — it would have passed every "happy path" test.
- **(qa)** the internal invariants couldn't catch a *systematic* over-credit → added the **ghost-accumulator** harness (`ghost_totalDelivered`/`ghost_totalPaid`); made `zipBalance >= totalPending` donation-tolerant; added redeem(<scaleUp)/zero/over-claim/re-claim guards, cross-era carry-forward + over-funded + epoch-boundary + reentrancy + donation + preview-parity tests; anchored the epoch clock to `block.timestamp` (no back-to-back catch-up settle).
- **(ref-verifier, wording)** corrected the ESynth burn-branch attribution (`burnFrom==sender`, not the owner-self-burn branch) and two off-by-one line cites. No contract impact.
- **(build, test-construction)** preview-parity must force a realize when the fill increment floors to sub-`scaleUp` (else a skip-on-zero false mismatch). Folded into the ticket; contract math was correct.

## Authoritative-doc edits
- **`claude-zipcode.md §6.1`** — added the whole-USDC-unit redemption-granularity note (`amount % 1e12 == 0`; odd balances redeem the floor + keep/sell the remainder on the AMM). Faithful clarification, no mechanism change, no §17 reopen.
- **No `audit/2.md` / `audit/3-results.md` edit** — the senior-queue L-rows + authority rows are deferred to item-10 (like 8-Bw / 8-B5..B10; not authorable against an un-wired system), logged as an OPEN obligation.

## Judgment calls
- **Did not commit the code.** The global rule is "commit only when the user asks," and recent windows left code "NOT git-committed — superintendent commit decision pending." Code is on disk, green, independently re-run. Your call to commit.
- **No INFLOW ticket.** Build-only per the doctrine (redeem UI = the post-deploy frontend sweep); I pinned the events/views the sweep will need (`RedeemRequest`/`EpochSettled`/`Withdraw`/`OperatorSet`, the 7540 + `previewRealize` views, `epoch`/`lastEpochTime`/`totalPending` getters).
- **Row 272 ("Item 9 · sidecar rotation") is NOT this contract.** It is baal-spec §8's internal numbering for the junior freeze/rotation module (an item-10/8-B11 component). The senior queue touches no sidecar. I annotated row 272 in PROGRESS so the next reader isn't misled.
- **`reservedAssets` retains sub-cent floor dust permanently** (never decremented away) — bounded, negligible across the protocol lifetime, and I did NOT add a sweep (would break non-sweepable). Documented in KR-5.

## Status + NEXT
**Item 9 DONE — BUILT-VERIFIED + KEPT.** Obligation row 317 (warehouse REDEEM/REPAY) DISCHARGED. New item-10 obligations created (repaySink + controller wiring; the REPAY re-scope authority = timelock/multisig, security F6).
**NEXT** (your pick): **item 10 (deploy/wiring)** — now the natural convergence point (it has accumulated the audit-sweep + wiring obligations from 8-Bw, the Exit Gate, `SzipNavOracle`, and now item 9) — **OR 8x bridge (M1) OR 8-Bx `LienXAlphaEscrow`** (M1-adjacent).
