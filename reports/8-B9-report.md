# 8-B9 report — `SellModule` (the swap module: market-sell HYDX→USDC + the zipUSD→xALPHA POL buy leg)

**TL;DR.** 8-B9 is authored, built, and **BUILT-VERIFIED on a live Base fork** — kept on disk, not discarded.
`SellModule` is the 6th engine Zodiac Module (a close sibling of 8-B8 `ExerciseModule`): two `onlyOperator` swap
entrypoints sharing a private `_swap` approve→`exactInputSingle`→reset-approve dance — `sellHydx` (HYDX→USDC, the
8-B5 strike-loop repay leg) and `buyXAlpha` (zipUSD→xALPHA, the 8-B10/8-B13 Mode-B/C POL buy leg). **31/31 tests
(27 unit + 4 Base-fork), 382/382 full suite (was 351 after 8-B8, no regression). Zero load-bearing guesses, zero
ticket discrepancies.** I independently re-ran the tests (`--match-path test/SellModule.t.sol` and the full fork
suite) — green. One spec-gap fixed (§4.5.1 8-B9 "State" line) + a user-directed post-build hardening (the per-call
`maxSellHydx` size cap, default 300k HYDX — see decision #1). NOT git-committed (the whole tree is untracked —
your commit call).

**NEXT = 8-B10** (recycle/payout Mode A/B — the `freeValueAccrued` free-value-only accumulator).

---

## What this window did
1. **Authored `tickets/sodo/8-B9-sell-module.md`** from `claude-zipcode.md §4.5.1` + `reports/baal-spec.md §10.8` +
   `auto-compounder.md`/`hydrex.md`, modeling 8-B8 `ExerciseModule` (the same token-approve dance + `_exec`-bubble +
   return decode + 4-→8-address `setUp` order-guard).
2. **Verified the new external surface (Algebra `SwapRouter`) on the live chain BEFORE drafting** — this was the
   high-risk part (a brand-new external interface, not previously touched by any built module):
   - `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))` = selector
     **`0x1679c792`** FOUND as a PUSH4 in the deployed router bytecode `0x6f4b…`; the Algebra-classic (`0xbc651188`)
     and UniV3 (`0x04e45aaf`) variants are ABSENT; `algebraSwapCallback` `0x2c8958f6` present ⇒ **Algebra Integral,
     not Uniswap V3** (no `fee` field, has `deployer` + `limitSqrtPrice`).
   - `router.factory() == pool.factory() == 0x36077D39…`; `factory.poolByPair(HYDX, USDC) == the live pool 0x51f0…`
     ⇒ it is a **base-factory pool** ⇒ the router's `deployer` arg is **`address(0)`**. `pool.token0()==HYDX`,
     `pool.token1()==USDC`.
3. **Fanned out 5 critics** (junior-developer, spec-fidelity, reference-verifier, qa-engineer, security-engineer).
4. **Triaged** → one spec-gap fixed in `claude-zipcode.md` + a handful of ticket/test-completeness folds.
5. **Cold-built it for real** (a fresh subagent, from the ticket alone, zero-guess gate) → green → KEPT on disk.
6. Concluded: ticket filed, `PROGRESS.md`/`LEDGER.md` updated, this report. STOP.

---

## Design decisions to sanity-check (the ones worth your eyes)

### 1. The module is STATELESS — no on-chain per-epoch volume cap. (The one spec-gap.)
`§4.5.1` 8-B9 literally read **"State: the per-epoch volume accumulator."** That contradicts (a) the *adjacent*
§4.5.1 text "Caps are a SIZE GATE on the loop, not a 'sell slowly' rule... 8-B8 bounds the exercise size so the
repay sell fits this budget", (b) every sibling engine module (8-B5/8-B6/8-B7/8-B8) being stateless-beyond-wiring,
and (c) §17 putting caps/regime/cutoff — and time-policy — at the CRE layer. **I fixed §4.5.1** to reconcile the
"State" line to "no module state; the per-epoch volume tracking + soft-bleed cap are an 8-B11/8-B12 CRE/monitoring
concern." The on-chain safety bound is the operator-supplied **`minOut`** slippage floor only.

I **considered an on-chain epoch accumulator as defense-in-depth and rejected it**: it would need epoch-boundary +
reset logic (the exact stateful time-policy §17 puts at CRE), and would make 8-B9 the lone stateful engine module.
**Both the spec-fidelity and security critics independently confirmed** the stateless triage is correct and
spec-faithful.

**UPDATE (user-directed, post-build, 2026-06-08): added a per-CALL `maxSellHydx` size ceiling** (default 300k HYDX ≈
~3% slippage ≈ ~$10k = the intended weekly clip; set-once + `onlyOwner setMaxSellHydx`; `sellHydx` reverts
`ExceedsMaxSell` above it). This is the belt-and-suspenders the user chose — and it threads the needle: it is set-once
**config**, not a running **accumulator**, so the module stays stateless beyond wiring and keeps sibling symmetry, yet
any single whole-basket dump is now bounded on-chain. The only piece left off-chain is the per-**epoch** throughput
across many calls (still the 8-B12 tripwire). `buyXAlpha` is not capped (different token; bounded upstream by 8-B10's
free-value gate). +7 tests. So the open question in this section is now **resolved: there IS an on-chain backstop.**

### 2. Both legs (`sellHydx` + `buyXAlpha`) live in 8-B9.
`baal-spec §10.8` is explicit: 8-B9 is the swap **mechanism** for both the HYDX→USDC repay leg and the zipUSD→xALPHA
Mode-B/C buy leg; **8-B10/8-B13 own the policy** (the free-value gate + when to buy) and call `buyXAlpha`. The
spec-fidelity critic confirmed this is spec-faithful, not scope-creep. The two legs share one private `_swap`, so the
buy leg is ~free surface. **`buyXAlpha` is unit-only this window** — there is no live zipUSD/xALPHA POL pool on Base
yet (zipUSD = our fresh `ESynth`, xALPHA = the 8x bridge stand-in), so its live-swap fork proof is **deferred to
8-B10/8-B13** (logged as an obligation); its router calldata shape is fork-grounded by the shared sell-leg sig-verify.

### 3. The compromised-operator economic risk is accepted (not a module bug).
With no on-chain size cap, a compromised CRE operator could `sellHydx(wholeBasket, minOut=1)` and crater HYDX (which
we are long via veHYDX + the LP). The security critic's verdict: **not an exploit** — under §17's
CRE-permissioned-single-writer model the operator is the trust anchor; if it's compromised the loss is a
key-compromise, bounded by the **8-B12 off-chain volume tripwire** (a new obligation), not by on-chain code. `minOut`
bounds *price*, never *size*. Consistent with how every sibling module treats the operator.

---

## Holes surfaced → resolution
- **§4.5.1 "State: per-epoch accumulator" contradiction** → **spec-fixed** to stateless (see #1; logged in
  PROGRESS "Open spec gaps").
- **`IAlgebraPool` lacked `token0()/token1()`** the fork test asserts (caught by reference-verifier + junior-dev) →
  **added** to the interface (on-chain-verified).
- **qa test-completeness folds** (all strict additions, no contract-semantics change → no critic re-fan needed):
  assert every `ExactInputSingleParams` field incl. `deployer==0`/`limitSqrtPrice==0`/`deadline`; `buyXAlpha` gets its
  own authority+guard tests; a `test_getters`; all 8 zero-address `setUp` reverts enumerated; fork determinism
  (quote+exec same block, small `amountIn`, generous integer-math `minOut`, 18→6 dp). All present in the kept tests.

## Authoritative-doc edits this window
- **`claude-zipcode.md` §4.5.1 8-B9** — the "State" line reconciled to stateless (the lone spec-gap). No §17 reopened.
- **`tickets/PROGRESS.md`** — banner + 8-B9 row → DONE/BUILT-VERIFIED; NEXT=8-B10; HYDX hand-off DISCHARGED; 5 new
  obligations added; spec-gap logged.
- **`tickets/LEDGER.md`** — 8-B9 design digest added.
- No `audit/2.md`/`audit/3-results.md` edits — the 8-B9 acceptance is part of the **deferred engine-integration audit
  sweep** (authored once the engine is integration-testable with item-10), same as 8-B5..B8/Exit-Gate.

## Judgment calls
- **Stateless over an on-chain epoch cap** (#1) — the main one; flagged for your review.
- **`deployer = address(0)` hard-coded** — verified base-factory for the HYDX/USDC pair; for the not-yet-created POL
  pair the same must be re-verified at 8-B10/8-B13 (obligation logged).
- **`minOut > 0` enforced** (fail-fast `ZeroAmount`, parity with 8-B8's `maxPayment > 0`) — a zero floor = no
  protection; the *meaningful* floor is an 8-B11 sizing obligation.
- **Test contract names** are `SellModuleUnitTest` / `SellModuleForkTest` (not `SellModuleTest`) — the ticket's
  Done-when run command was corrected to `--match-path test/SellModule.t.sol`.

## Status + how to verify
- **BUILT-VERIFIED, kept on disk, NOT git-committed** (whole tree untracked — your commit decision).
- Run it yourself: `cd contracts && set -a; source .env; set +a && forge test --fork-url "$BASE_RPC_URL"
  --match-path test/SellModule.t.sol` (31/31) and the full suite `forge test --fork-url "$BASE_RPC_URL"` (382/382).
- Files: `contracts/src/supply/szipUSD/SellModule.sol`, `contracts/test/SellModule.t.sol`, NEW
  `contracts/src/interfaces/algebra/ISwapRouter.sol`, edits to `contracts/src/interfaces/algebra/IAlgebraPool.sol`
  (+`token0`/`token1`) and `contracts/script/BaseAddresses.sol` (+`ALGEBRA_SWAP_ROUTER`).
- **NEXT = 8-B10** (recycle/payout Mode A/B; the `freeValueAccrued` accumulator; depends 8-B9).
