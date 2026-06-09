# 8-B8 report — Exercise module (`ExerciseModule`)

**TL;DR.** Authored + built + KEPT the 5th engine Zodiac Module — the **paid** oHYDX-exercise (strike-financing) leg
of the auto-sodomizer. It pays the ~30% USDC strike (financed by the 8-B5 borrow) to `oHYDX.exercise(...)` and
receives liquid **HYDX** to the Safe, which 8-B9 then market-sells to repay. **25/25 green** (21 unit + 4 Base-fork
proving a real `oHYDX.exercise`), **351/351 total no-regression**, **ZERO load-bearing guesses**. This was a clean,
low-surprise window: the ticket was faithful out of the gate (the 5-critic fanout found **no spec-mechanism gap**,
§17 untouched), the verified-correct sibling pattern (8-B5's approve-dance minus the EVC leg) transferred directly,
and every oHYDX selector was re-verified on live Base before the build.

---

## What the window did
1. **Verified the oHYDX surface on live Base before drafting.** `cast`-checked every selector against the deployed
   `OptionTokenV4` `0xA113…`: `paymentToken()`=`0x3013ce29`→**USDC** (the strike is paid in USDC, confirmed),
   `getMinPaymentAmount()`=`0x2abb945c` **no-args**→10000 ($0.01 floor), `getDiscountedPrice(uint256)`=`0x339ccade`
   (= 30%·TWAP), `exercise(uint256,uint256,address,uint256)`=`0xa1d50c3a` + the 3-arg `0xd6379b72` both present in
   the bytecode, `discount()`=30. The existing `IOptionToken` already had the 4-arg `exercise`/`getDiscountedPrice`/
   `discount`; I added only `paymentToken()` + `getMinPaymentAmount()`.
2. Drafted the build ticket (`tickets/sodo/8-B8-exercise-ohydx.md`) — build-only (internal engine plumbing; the
   8-B11 CRE robot drives the one entrypoint). Primary model = the sibling `ReservoirLoopModule` (8-B5) for the
   approve→call→reset USDC dance, and `HarvestVoteModule` (8-B7) for the `_exec`-that-returns-bytes decode.
3. **5-critic fanout** (junior / spec-fidelity / ref-verifier / qa / security). Spec-fidelity verdict: **FAITHFUL**
   (no §17 reopen; no inbound cross-ticket obligations owed by 8-B8 — confirmed against the table). All findings were
   ticket gaps or hardening → folded (below).
4. **Built it for real + KEPT it.** `ExerciseModule.sol` + `ExerciseModule.t.sol` materialized from the ticket,
   `forge build` green, `forge test` green (21 unit + 4 Base-fork), independently re-ran with the full suite.
5. Concluded: ticket filed, PROGRESS + LEDGER updated, the one cosmetic spec tidy saved, this report. **NEXT = 8-B9.**

## The contract (locked shape)
A pure-mechanism Zodiac module enabled on the szipUSD engine Safe (`avatar==target==engineSafe`), one set-once CRE
`operator`, **stateless beyond set-once wiring**, NO EVC/oracle/LP/veNFT. One `onlyOperator` mutator:

```
exercise(uint256 amount, uint256 maxPayment, uint256 deadline) → paymentAmount   // 3 execs, all (Call, value 0):
  (1) USDC.approve(oHYDX, maxPayment)
  (2) oHYDX.exercise(amount, maxPayment, engineSafe, deadline)   // 4-arg deadline overload; returns paymentAmount
  (3) USDC.approve(oHYDX, 0)                                     // reset — no standing approval
  assert paymentAmount <= maxPayment (PaymentExceedsMax)         // event-honesty guard (KR5)
  emit Exercised(amount, paymentAmount)
```

- The `recipient` is hard-pinned to the literal `engineSafe` (HYDX can only mint to the basket). `paymentToken` is
  **live-read** off `oHYDX.paymentToken()` at setUp (fail-closed nonzero) so the approve target can never drift.
- `quoteStrike(amount)` view = `max(getDiscountedPrice(amount), getMinPaymentAmount())` — 8-B5/8-B11 back-pressure
  to size the borrow + the `maxPayment` cushion.
- The *paid* counterpart to 8-B7's **free** `exerciseVe` permalock — a different oHYDX function with a USDC strike.

## Design decisions to sanity-check (superintendent)
1. **The profitability cutoff ($0.015 loop cutoff / $0.018 amber-taper / $0.01 dead floor), regime gate (UP/FLAT-only), and commitment gate are deliberately OFF-chain (8-B11).**
   Per §4.5.1 the module is pure mechanism (pay strike, get HYDX); it is correctly agnostic to regime/spot/loop-size.
   I kept them out of the contract and logged them as an 8-B11 obligation. (Spec-fidelity confirmed this is faithful,
   not an omission.)
2. **`maxPayment` is the SLIPPAGE/spike guard — CORRECTED from the original "compromised oHYDX" framing (your
   review + on-chain evidence).** oHYDX is immutable + non-proxy (verified on Base: empty EIP-1967 slot, no `owner()`)
   and pulls **exactly** its TWAP-computed strike — **fork-proven** that the charge `== quoteStrike(amount)` read in
   the same block. So `maxPayment` is not a malware defense; it is the **slippage tolerance** (like a Uniswap swap):
   it aborts the loop on a genuine TWAP spike between the CRE's quote and tx execution, instead of overpaying the
   basket. The only real risk a loose `maxPayment` creates is **overpaying the honest strike on a spike** — a real but
   bounded economic loss, the 8-B11 tight-cushion obligation. **I evaluated module-self-quote-exact and REJECTED it:**
   it would *delete* the spike guard (pay whatever the current strike is, unconditionally) and wouldn't simplify the
   system (the CRE must compute the strike regardless, to size the 8-B5 borrow — the binding constraint). The KR5
   `paymentAmount ≤ maxPayment` guard is defense-in-depth re-asserting the bound oHYDX already enforces internally.
3. **HYDX is asserted to merely *increase* on the fork** (`assertGt`), not `== amount`, in case of any fee. The oHYDX/
   USDC burn/pay are asserted **exact** (`oHYDX −exactly amount`, `USDC −exactly paymentAmount`). If you want the
   HYDX delta pinned exact too, say so — the live exercise returned a clean 1:1 in practice.

## Holes surfaced → resolution (critic findings folded, all strict hardening → cold-build-only, no re-fan)
- **qa/security:** added the **KR5 honesty guard** (`PaymentExceedsMax`) + the malicious-oHYDX ceiling note + an
  8-B11 tight-cushion obligation.
- **qa:** the kept `RecordingSafe` returns `_returnData` for *every* non-live call → corrected the ticket's wrong
  "approve calls return (true,"")" claim; the module only decodes exec #2, so the global mock suffices (no per-index
  variant). Added **state-moving** allowance-reset (happy path) + **rollback** (no dangling approval on a mid-loop
  revert) tests on a live mock — the calldata-shape unit test alone never proves the *effective* reset.
- **qa:** decode **all four** exercise args (not just recipient) + the reset-approve args; `quoteStrike(0)`==floor +
  tie boundary; per-recorded-call `value==0` + `Operation.Call`; assert `module.paymentToken()==USDC` on the fork.
- **junior/spec-fidelity:** fixed the "3 addresses"→"4" typo; removed a dangling `EXERCISE_4ARG_SELECTOR` artifact
  (use typed `abi.encodeCall`); added the explicit `IERC20` import note + the test-harness file paths.
- **security:** logged the **atomic, front-run-safe deploy+setUp** (single `ModuleProxyFactory` tx, mastercopy
  init-locked) as an item-10 obligation.

## Authoritative-doc edits
- **`claude-zipcode.md §4.5.1` 8-B8 "State" line** — the only spec touch, cosmetic: "pending-exercise accounting; the
  in-flight strike-borrow (tracked by 8-B5)" → "no module state (stateless beyond set-once wiring, like the sibling
  engine modules); the in-flight strike-borrow is tracked by 8-B5 (`debtOf`) and the pending-exercise sequencing by
  the 8-B11 robot." No §17 reopened. (`reports/design/baal-spec.md §10.8` 8-B8 already described the module faithfully — untouched.)
- No `audit/2.md` / `audit/3-results.md` edits (the engine-integration audit sweep is the deferred item-10 pass,
  logged as an obligation — matching 8-B5/8-B6/8-B7/Exit-Gate).

## Status + NEXT
- **8-B8 DONE — BUILT-VERIFIED + KEPT on disk** (NOT git-committed; whole tree untracked — your commit decision).
  Code: `contracts/src/supply/szipUSD/ExerciseModule.sol` + `contracts/test/ExerciseModule.t.sol` + `IOptionToken`
  adds. Run it: `forge test --fork-url $BASE_RPC_URL --match-contract ExerciseModule` (25/25); full suite 351/351.
- **NEXT = 8-B9** (sell module — HYDX→USDC via `SwapRouter.exactInputSingle` market-sell to repay the 8-B5 borrow
  immediately + the zipUSD→xALPHA POL buy leg; soft-bleed caps = the loop size gate; `reports/design/baal-spec.md §10.8` 8-B9,
  depends 8-B8). It consumes exactly the HYDX this module mints to the Safe.
