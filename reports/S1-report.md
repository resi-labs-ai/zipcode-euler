# S1 report — Stream 2 (`RecycleModule.divert`): divert engine yield into the bank

**To:** superintendent · **Window:** 2026-06-09 · **Status:** BUILT-VERIFIED + KEPT · **NEXT:** S2 item-10 wiring (deploy, not a contract)

## TL;DR
The loss-side waterfall's one genuine build gap — **Stream 2** (`solvency.md` §C.S1) — is built. A `divert` mode
added to the BUILT `RecycleModule` (8-B10) **supplies engine free-value USDC straight into the credit warehouse**
(`eePool.deposit(amount, warehouse)`, **NO zipUSD minted**), bounded by the live `SzipNavOracle.provision()` hole.
It is a second spend of the same `freeValueAccrued` ledger `recycle` already governs. Shipped through the harness:
ticket → 5 critics → synthesize/triage → cold-build + KEEP. **No spec gap surfaced (no `claude-zipcode.md` edit).**
Code: `RecycleModule.sol` (the `divert` mode + 3 wiring slots/setters), `RecycleModule.t.sol` (15 new tests).

## What the window did
- Filed `tickets/sodo/S1-recycle-divert.md` (build-only; loss-side internal plumbing, no INFLOW ticket).
- Extended `contracts/src/supply/szipUSD/RecycleModule.sol`:
  - 3 new set-once wiring slots `navOracle` / `eePool` / `warehouse` (clone-safe, NOT `immutable`); `setUp` decode
    grows 5 → 8; 3 `onlyOwner` (Timelock) re-point setters emitting `WiringSet` (build-phase §17).
  - `divert(uint256 usdcAmount) external onlyOperator returns (uint256 sent)` — order load-bearing
    (**bounds-before-spend, then CEI**): ZeroAmount → NoHole → ExceedsHole → `_spendFreeValue` → approve/deposit/reset
    execs → two value guards → `emit Filled`.
  - 2 local interfaces (`ISzipNavProvision`, `IEulerEarn`); 4 new errors (`NoHole`, `ExceedsHole`,
    `NoSharesMinted`, `BackingShortfall`); 1 event (`Filled`).
- Extended `contracts/test/RecycleModule.t.sol`: updated every setUp rig 5 → 8; added `RecycleModuleDivertTest`
  (13 tests, LIVE Safe + real `EEMock` + `MockNavProvision`) + a `RecycleModuleForkTest` divert case + the
  Stream-2 setter test.
- Updated `solvency.md` status (Stream 2 BUILT); PROGRESS + LEDGER digests; this report.

## Design decisions to sanity-check
1. **`divert` lives on `RecycleModule` (not a new contract)** — per `solvency.md` §D RESOLVED. It reuses the exact
   `_spendFreeValue` CEI debit, the `_exec`-bubble dance, the `onlyOperator` gate, and the setUp order-guard. The
   only divergence from `recycle`: the middle exec is `eePool.deposit(usdcAmount, warehouse)` (raw USDC, **no
   `ZipDepositModule.deposit`, no `ESynth.mint`**) and a `provision()` bound is read before the spend.
2. **The `1e12` bound: `usdcAmount * 1e12 > provision()` → `ExceedsHole`, strict `>`.** USDC 6-dp × 1e12 → 18-dp USD;
   strict `>` allows an exact fill, never an over-fill. Pinned with ±1 vectors + a `provision == usdcAmount·1e12`
   exact-fill vector. (spec-fidelity critic confirmed direction + strictness.)
3. **HARDENED BEYOND THE LITERAL SPEC (security MED F5):** the spec's required guard was "warehouse EE-share balance
   rose" (a *liveness* check). The security critic flagged that a malicious/buggy EE pool could mint shares to the
   warehouse **without pulling USDC** (passing the share-rose guard while no value moved). I promoted the
   **hard-backing** check into the contract: the Safe's USDC must have fallen by **exactly `usdcAmount`**
   (`BackingShortfall`), in addition to the share-rose guard (`NoSharesMinted`). This matches the module's own stated
   "HARD BACKING" doctrine (the USDC moved is pulled from the Safe's real balance). Both guards are tested with
   dedicated stingy/free-mint EE mocks. **Flag for review:** this adds one assertion the spec did not name — I judged
   it preserve-intent (it strengthens, sands nothing off). If you'd rather keep the contract literally spec-minimal,
   the `BackingShortfall` check can be demoted to a test-only assertion.
4. **`Filled(usdcAmount, warehouse, provisionAfter=hole)`** emits the pre-spend `provision()` read; `divert` does
   NOT write provision (the CRE reduces the hole later via `DefaultCoordinator.Recovery`), so `provisionAfter` equals
   the live hole at divert time — documented in NatSpec to preempt the "shouldn't this be reduced?" reading.
5. **No `nonReentrant`** — consistent with `recycle` and the clone fact (a `ModuleProxyFactory` clone never runs OZ
   `ReentrancyGuard`'s constructor); safety is effects-before-interaction (the `_spendFreeValue` decrement lands
   before any value-moving exec), proven observably by a readback EE mock.

## Critic fanout → triage (5 critics, ~218k subagent tokens)
- **spec-fidelity: FAITHFUL-WITH-NITS** (1e12 direction correct; no drift/invention; §17 honored; correctly does NOT
  route to capitalSink and does NOT write provision). **No spec gap → no `claude-zipcode.md` edit.**
- **junior-dev: buildable as-is** (only test-authoring discretion — new mocks).
- **reference-verifier: all 6 "Model from" sources resolve** at the cited lines; listed the exact setUp call sites to
  grow 5 → 8 (all updated).
- **qa:** confirmed the live-Safe rig requirement (a non-live RecordingSafe would falsely trip the share-rose guard);
  flagged the new 2-arg `deposit` mocks needed (stingy + readback); asked for callCount==0/ledger-unchanged on the
  pre-spend reverts, a two-bound `min()` test, and the overflow vector. **All folded in.**
- **security:** no real-theft vector (destination integrity + CEI close F1/F4). Two MEDs: **F2** huge-provision →
  drain free value = §13-accepted **grief** (USDC still lands in the bank; bounded by the trusted Coordinator+CRE
  pair + the deferred invariant-fuzz); **F5** the share-rose-alone bypass → **promoted the USDC-fell hard-backing
  check into the contract** (decision 3 above).

## Holes surfaced → resolution
- None were spec holes. All findings were ticket/test-quality or the one security hardening (F5) folded into the
  build. The two deferred items (the loss-phase `audit/2` step + the `divert ≤ min(freeValueAccrued, provision/1e12)`
  invariant-fuzz) are logged as item-10 obligations, matching every prior engine module's deferred integration sweep.

## Authoritative-doc edits
- `solvency.md` status header → Stream 2 BUILT.
- **No `claude-zipcode.md` / `audit/*` edits** (no spec gap; the spec faithfully covers the mechanism).

## Verification (exactly what I ran)
- `forge build` clean.
- `forge test --match-path test/RecycleModule.t.sol` (no-fork) — **32/32** (17 unit + 2 integrated + 13 divert).
- `forge test --fork-url $BASE_RPC_URL --match-contract RecycleModuleForkTest` — **2/2** (recycle + divert, both
  against a real summoned Gnosis Safe).
- `forge test` (full **non-fork** suite) — **712 passed / 0 failed**. No regression.
- **NOT run to completion:** the full **fork** suite (`forge test --fork-url`). The change is purely additive to
  `RecycleModule.sol` and no other contract imports it, so the fork-regression surface is the 2 RecycleModule fork
  tests above (green). Superintendent: run `forge test --fork-url $BASE_RPC_URL` for the full-fork tally before
  release if you want it on record.

## New cross-ticket obligations created (in PROGRESS)
- **Item 10 / S2 wiring:** `setNavOracle` / `setEePool` / `setWarehouse`; deploy-assert `RecycleModule.warehouse ==`
  the `ZipDepositModule`/`WarehouseAdminModule` warehouse Safe **and** `RecycleModule.eePool == ZipDepositModule.eePool()`
  (one bank — revert the deploy on mismatch).
- **Item 10 / loss-side audit sweep:** the `divert` L-step + the `divert ≤ min(freeValueAccrued, provision/1e12)`
  invariant-fuzz + the `audit/3-results` authority rows.
- **8-B11 / CRE §8:** the CRE sizes `usdcAmount` within `min(freeValueAccrued, provision()/1e12)` and writes a
  `DefaultCoordinator.Recovery` to reduce provision by the realized fill after a divert.

## Status + NEXT
S1 DONE (BUILT-VERIFIED + KEPT). The loss side is now fully built on-chain. **NEXT = S2 (item-10 deploy/wiring)** —
not a contract; the loss-side wiring folds into the item-10 deploy window with the two deploy-time assertions above.
