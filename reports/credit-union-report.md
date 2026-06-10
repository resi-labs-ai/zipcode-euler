# reports/credit-union-report.md — the szipUSD CoW-book exit rework (C1–C4)

**TL;DR.** Built the szipUSD exit rework from `credit-union.md` through the full harness (5 critics → spec-triage
→ cold-build → KEEP). The forfeiting on-chain exit queue is **retired**; the exit is now the CoW book + treasury
buy-and-burn. Four deliverables, all green: **C1** new `OffRampModule` (basket zipUSD → USDC via the redemption
queue), **C2** the NAV-freshness fence (COLLAPSED into `SzipBuyBurnModule` per your directive — no new controller),
**C3** delete the `ExitGate.processWindow` forfeit + its orphans, **C4** hard-gate `ZipRedemptionQueue.requestRedeem`.
Kept on disk, not git-committed (your commit call).

## What the window did
- **5 critics** (junior-dev / spec-fidelity / ref-verifier / qa / security) on the `credit-union.md` draft.
  Every cited signature verified EXACT (incl. the load-bearing `SzipNavOracle.maxAge()`); zero signature blockers.
- **Spec gaps fixed in `claude-zipcode.md` FIRST** (the canonical spec still described the retired mechanism):
  the stale "liquidity window / intent queue / partial-fill-per-window / engine Safe" language in §6-intro (`:1253`),
  §6.4 steps 3/4/5/6 + closing, §11 (`:2024`/`:2047`), §17 (`:2284`) + the §17 reference-map rows (`:153`/`:154`)
  → all reworded to the **CoW-book** model (resting order = the queue; treasury just-in-time buy-and-burn; no
  on-chain window/intent-queue; the `engineSafe` label = the one rq Safe, no separate engine wallet).
- **Cold-build (fresh subagent, zero load-bearing guesses)** materialized C1–C4 + tests, KEPT.
- **Your mid-build directive — COLLAPSE C2 — applied:** deleted the just-built `ExitFulfillmentController` (+ test)
  and folded its only on-chain value-add (the `validTo ≤ now + maxAge` fence) into `SzipBuyBurnModule.postBid`
  (new error `ValidToBeyondNavFreshness`, `maxAge()` added to the module's local `INavOracle`). The CRE drives
  `postBid`/`burnFor` directly (it already holds both roles); the UI tracks fills via existing `BidPosted`/`Burned`.

## Files (kept on disk)
- NEW: `contracts/src/supply/szipUSD/OffRampModule.sol` + `contracts/test/OffRampModule.t.sol` (C1).
- CHANGE: `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` + `.t.sol` (C2 fence).
- CHANGE: `contracts/src/supply/szipUSD/ExitGate.sol` + `.t.sol` (C3 forfeit deletion).
- CHANGE: `contracts/src/supply/ZipRedemptionQueue.sol` + `.t.sol` (C4 hard-gate).
- DELETED: `ExitFulfillmentController.sol` + `.t.sol` (collapsed).

## Test status (run yourself)
- C1 `OffRampModuleUnitTest` 16/16 + `OffRampModuleForkTest` 1/1 = **17/17**.
- C2 `SzipBuyBurnModuleTest` **36/36** (33 prior + 3 new fence-boundary tests; the fence is a no-op at the default
  `maxAge == MAX_BID_TTL`, so the prior 33 are unchanged).
- C3 `ExitGateTest` **14/14** (forfeit/processWindow/requestExit tests + the hidden `test_invariant_sequence`
  landmine removed; grep proves zero remaining references to any deleted symbol).
- C4 `ZipRedemptionQueueTest` **40 unit** + fork/invariant = **44** (item-9's original 44 still pass; the
  `RedeemRequest.sender == rqSafe` proof lives in C1's fork test).
- **Full non-fork suite green** (the 2 transient `RecycleModuleDivertTest` reds from a Stream-2 mid-build snapshot
  are now passing). Commands: bulk `forge test` (0 CU); fork subset `forge test --fork-url base --match-contract <suite>`.

## Note on the shared working tree (Stream-2)
A parallel agent is actively building `RecycleModule.divert` (Stream-2: free-value → senior EulerEarn backing) in
the same working tree. A mid-build snapshot briefly showed 2 red `RecycleModuleDivertTest` tests during my full-suite
run; they are now green (the other agent moved forward). **None of my changes touch `RecycleModule.sol` or the
`divert` path** — zero overlap, no merge risk. Caveat for whoever reads a full `forge test` count: it samples BOTH
streams' work, so use the per-suite breakdown to attribute results; my four suites are self-contained and green.

## Design decisions to sanity-check
1. **C2 collapse (your call) — applied as directed.** The fence binds before `BadValidTo` only when
   `maxAge < MAX_BID_TTL`; at the production default (`maxAge == 1 day == MAX_BID_TTL`) it is inert. If you intend
   `maxAge` to actually bind the resting TTL, set the oracle's `maxAge < 1 day` (it's an immutable ctor arg) or lower
   `MAX_BID_TTL`. Today it's a safety ceiling, not the active bound.
2. **C4 gate authorizes the rq SAFE, not the off-ramp module** (the module `exec`s through the Safe, so the Safe is
   `msg.sender`). The honest consequence: the gate's surface = the union of all Zodiac modules enabled on the rq
   Safe, and its security value is closing the **epoch-dilution / senior-USDC-griefing** vector of an open
   `requestRedeem`, **not** theft (par is fixed, settle is `onlyController`, the queue is non-sweepable).
3. **`burnFor`/the buy-burn retire path is unbounded operator-trusted** (bounded only by the rq Safe's szipUSD
   balance) — documented; safe under the invariant that the rq Safe holds szipUSD only as transient buyback
   inventory. 8-B12 should tripwire `Burned`. (No on-chain bound added — consistent with the §13 trust model + the
   `RecycleModule.creditFreeValue` precedent.)
4. **No new audit/2 rows authored** — the C1 off-ramp + the exit path fold into the deferred item-10 / junior
   acceptance sweep (the same EXCISED-marker pass the Exit Gate deferred). Logged as an obligation.

## Authoritative-doc edits
- `claude-zipcode.md`: §6-intro / §6.4 / §11 / §17 reworded to the CoW-book exit (the retired-mechanism cleanup).
- `credit-union.md`: critic-hardened + reflects the C2 collapse + the built state (it is the consolidated build
  spec for this rework — like `baal-spec.md` was for the 8-B tickets; not fragmented into per-item ticket files).
- The dangling "§5.6/§5.8 RESOLVED" citations in `credit-union.md` (no such § exists) removed — those decisions
  were locked in that doc's own session.

## Status + NEXT
- **Credit-union exit rework: DONE — BUILT-VERIFIED + KEPT** (not git-committed). One of the "two things before
  item 10." The sibling `solvency.md` (loss side) remains open in the working tree.
- The forfeit removal means the **item-10 junior-acceptance audit sweep** (the deferred `audit/2` L-rows) must now
  trace the CoW exit, not `processWindow`.
- NEXT per the kickoff backlog = item 10 (deploy/wiring), unless the superintendent picks the 2nd pre-item-10 thing.
