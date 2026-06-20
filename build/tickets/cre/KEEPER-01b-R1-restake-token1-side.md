# KEEPER-01b-R1 — generalize the strike-loop restake leg to the token1-side case

> One item. The own-later follow-up flagged in the KEEPER-01b core-slice note (PROGRESS "KNOWN LIMITATION"):
> the restake leg hardcodes the recycled zipUSD as the LP vault's **token0**
> (`addLiquidity(deposit0=expectedZip, deposit1=0, minShares)`), and `ZipToShares` prices the token0 side.
> If zipUSD's deployed address sorts ABOVE xALPHA's (so zipUSD is the vault's **token1**), the leg is malformed
> — it asks the vault to pull `token0 = xALPHA`, which the Safe lacks — and `addLiquidity` reverts. Generalize:
> read which side is zipUSD and build the deposit + price the share floor on the correct side. NO other
> behavior change (claim → … → recycle unchanged; the leg ORDER unchanged; all scalar sizing unchanged).

## Deliverable
Modify the existing built code in `cre/keeper/` (NO new contract; off-chain Go only):
- `internal/quote/quote.go` — the `Quoter.ZipToShares` seam now resolves which vault side is the recycled
  zipUSD and returns that as a flag alongside the shares; `ichiSingleSidedShares` takes the side and selects
  the correct numerator.
- `internal/job/strike_loop_job.go` — build `addLiquidity` with the recycled zipUSD on the correct side
  (`(expectedZip, 0, minShares)` when zipUSD is token0, `(0, expectedZip, minShares)` when token1), using the
  flag the quoter returns. Delete the now-obsolete KNOWN-LIMITATION comment block + the inline token0-side
  warning.
- Tests (`internal/quote/quote_test.go`, `internal/job/strike_loop_job_test.go`,
  `internal/job/strike_loop_job_sim_test.go`) — update the seam signature, keep the token0-side cases green,
  and ADD a token1-side case in both the unit and (cheaply) the share-math layers.

Gate: `go build ./...` + `go vet ./...` green; the table-driven `Evaluate` test asserts the `addLiquidity`
args + side per branch; the `quote` test asserts the share-math numerator differs correctly per side; the sim
test still proves ordered multi-leg submission (unchanged — it injects a fake Quoter). Committed to
`cre/keeper`.

## Spec §
`claude-zipcode.md` §8.7 (the operator path; the LP-strategy restake step) and §4.5.1 (the auto-compounder /
free-value-only invariant). No spec MECHANISM change — single-sided `addLiquidity` on either side is the same
mechanism the spec already describes; this corrects an implementation assumption, not the design. §17
re-pointability is honored (the side is re-read each tick off live getters, never cached).

## Binds to (verified against live source — re-confirm at build)
The ICHI vault side-slotting is by ADDRESS SORT (lower address = token0), fixed at pool creation. To route the
single-sided deposit the keeper must know which of the vault's two tokens is the recycled zipUSD. The chain of
truth (all re-pointable getters, read each tick — §17):

- **`LpStrategyModule.ichiVault() returns(address)`** (`contracts/src/supply/szipUSD/LpStrategyModule.sol:44`,
  public set-once storage) — the LP vault. (The Job ALREADY reads this each tick; unchanged.)
- **`IICHIVault.token0() / token1() returns(address)`** — the vault's two tokens (read live; the `ProdQuoter`
  ALREADY reads both for the `getQuoteAtTick` direction, `quote.go:97-104`).
- **`RecycleModule.zipDepositModule() returns(address)`** (`RecycleModule.sol:80`, public set-once storage) —
  the WOOF-06 zap that mints the recycled zipUSD.
- **`ZipDepositModule.zipUSD() returns(address)`** (`contracts/src/supply/ZipDepositModule.sol:50`,
  `address public immutable zipUSD`) — THE zipUSD token. This is the recycled token (the `recycle` leg drives
  `RecycleModule.recycle` → `ZipDepositModule.deposit` which mints `usdcAmount·scaleUp` zipUSD to the Safe,
  `RecycleModule.sol:263-273`). So `zipUSD` is, by construction, one of the vault's two tokens.

  **Side determination:** `zipIsToken0 = (zipUSD == vault.token0())`. If `zipUSD == vault.token1()` →
  token1-side. If `zipUSD` matches NEITHER → a wiring fault (the vault is not the zipUSD/xALPHA vault); the
  production quoter returns an error (see Key req 4).

- **`LpStrategyModule.addLiquidity(uint256 deposit0, uint256 deposit1, uint256 minShares) returns(uint256)`**
  (`LpStrategyModule.sol:215-246`): single-sided allowed — reverts `ZeroAmount` only if BOTH are 0
  (`:220`); reverts `ZeroMinShares` if `minShares==0` (`:221`); reverts `Slippage` if `shares < minShares`
  (`:243`). The contract approves+deposits the non-zero leg(s) symmetrically — `(0, expectedZip, minShares)`
  is the exact mirror of `(expectedZip, 0, minShares)`; no extra surface needed (back-pressure: none).

The ICHI single-sided share math (canonical `ICHIVault.deposit`, pinned in the KEEPER-01b ticket §"Binds to"):

```
deposit0PricedInToken1 = deposit0 · min(price,twap) / PRECISION         // token0 valued at the WORSE price
shares = (deposit1 + deposit0PricedInToken1) · totalSupply
         / (pool0 · max(price,twap)/PRECISION + pool1)                  // pool at the BETTER price; denom in token1 terms
PRECISION = 1e18 ; price = getQuoteAtTick(spotTick, 1e18, token0→token1) ; twap = same at the mean tick
```

The denominator (total pool value in token1 terms) and `price`/`twap` (always token0→token1) are
SIDE-INDEPENDENT. Only the NUMERATOR changes with which side is deposited:
- **zipUSD == token0** (`deposit1 = 0`): `numerator = depositZip · min(price,twap) / 1e18` (today's path).
- **zipUSD == token1** (`deposit0 = 0`): `numerator = depositZip` — the deposit is ALREADY in token1 terms,
  so it is NOT priced by `min(price,twap)` (this is the bug today: the token0-pricing was applied
  unconditionally).
- Both: `shares = numerator · totalSupply / denom`.

Reference patterns: the existing `cre/keeper/internal/quote/quote.go` (`ZipToShares`, `ichiSingleSidedShares`),
`internal/job/strike_loop_job.go` (the restake block, `:247-275`), `internal/chain/read.go` (`CallAddress`).

## Starting state
- `cre/keeper/` builds; the StrikeLoopJob ships with the token0-side restake + its KNOWN-LIMITATION comment.
- `Quoter.ZipToShares(ctx, vault, depositZip) (*big.Int, error)` reads `token0/token1/pool/totalSupply/
  getTotalAmounts/globalState/meanTick` and computes the token0-side share floor unconditionally.
- `ichiSingleSidedShares(depositSide0, totalSupply, pool0, pool1, price, twap)` always prices the deposit on
  the token0 side.
- The Job builds `addLiquidity(expectedZip, big.NewInt(0), minShares)` unconditionally.
- The sim test injects a `fakeQuoter`; the `StrikeLoopProbe` is NOT read for the side (the quoter is the seam).

## Do NOT
- Do NOT change the leg ORDER, the no-op gates, the taper/halt logic, the profit gate, or any scalar sizing
  (exerciseAmount, maxPayment, borrowAmount, sellAmount, minOut, conservativeNet, recycleAmount, creditAmount,
  expectedZip, minShares, stakeAmount) — this is restake-side routing ONLY.
- Do NOT recompile the `StrikeLoopProbe` bytecode or add view selectors to it. The side-resolution lives in
  the PRODUCTION `ProdQuoter`; the sim test uses the injected `fakeQuoter`, so the probe needs no new reads.
- Do NOT cache the side across ticks (§17 — a Timelock re-point of `ichiVault`/`zipDepositModule` must take
  effect; read the getters each tick, same as the existing per-tick address reads).
- Do NOT hard-code token addresses in Go (resolve zipUSD off the module getters).
- Do NOT widen the operator surface — the keeper still supplies only scalar amounts.

## Key requirements
1. **`Quoter.ZipToShares` returns the side.** New signature:
   `ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int) (shares *big.Int, zipIsToken0 bool, err error)`.
   The `recycle` module address is passed so the PRODUCTION impl can resolve zipUSD
   (`recycle.zipDepositModule()` → `zdm.zipUSD()`); putting the resolution behind the seam keeps the sim test's
   `fakeQuoter` in control of the flag (no probe change). The Job passes its `j.recycle` field.
2. **`ProdQuoter.ZipToShares`** (concrete signature:
   `func (q *ProdQuoter) ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int)
   (*big.Int, bool, error)`): resolve `zdm = CallAddress(recycle,"zipDepositModule()")`,
   `zipUSD = CallAddress(zdm,"zipUSD()")`; read `token0`/`token1` (as today); set
   `zipIsToken0 = (zipUSD == token0)`; compute `price`/`twap` UNCHANGED (always token0→token1); call
   `ichiSingleSidedShares(depositZip, totalSupply, pool0, pool1, price, twap, zipIsToken0)`; return
   `(shares, zipIsToken0, nil)`. **Rewrite the now-stale `ZipToShares` doc comment** (it currently asserts
   "depositZip is ALWAYS the token0-side amount … zipUSD is token0 by construction") to describe the
   side-aware behavior.
3. **`ichiSingleSidedShares` takes `zipIsToken0 bool`** (rename the first param `depositSide0`→`depositZip`
   and fix its doc comment — it is no longer always the token0 side): `numerator = mulDiv(depositZip,
   min(price,twap), PRECISION)` when `zipIsToken0`, else `numerator = depositZip` (raw). Denominator + the
   degenerate `denom==0 → 0` guard unchanged. `shares = mulDiv(numerator, totalSupply, denom)`.
4. **Neither-match is a fault, not a silent skip.** If `zipUSD` equals neither `token0` nor `token1`, the
   production quoter returns a descriptive error (the vault is not the zipUSD/xALPHA vault — a bad re-point).
   `Evaluate` propagates it; the Runner logs+continues (the tick no-ops, loud). This can only arise from a
   misconfigured wiring and should never happen post-deploy.
5. **The Job branches the deposit side.** In the restake block (`strike_loop_job.go`), call
   `expectedShares, zipIsToken0, err := j.quoter.ZipToShares(ctx, j.recycle, vault, expectedZip)`; build
   `addLiquidity(expectedZip, 0, minShares)` when `zipIsToken0`, else `addLiquidity(0, expectedZip, minShares)`.
   `minShares`/`stakeAmount` sizing + the `minShares==0 → recycle-without-restake` skip are UNCHANGED. Delete
   the file-top KNOWN-LIMITATION block and the inline token0-side warning; replace with a one-line note that
   the deposit side now follows the live `token0()/token1()` slotting.
6. **Re-pointable each tick (§17).** The side is recomputed every `Evaluate` from live getters; nothing is
   cached on the Job or the quoter.

## Done when (the gate — verified by re-run, not just the cold-build's claim)
- `go build ./...` exit 0; `go vet ./...` clean.
- `quote_test.go`: **update ALL existing callers to the new 4-arg / 3-return signature** —
  `TestZipToShares_ScriptedFormula` (add `zipDepositModule()`/`zipUSD()` to the scripted reader's `addrs` map,
  keyed by selector, so `zipUSD == token0` → discard the new `zipIsToken0` return or assert it `true`),
  `TestZipToShares_ReaderErrorPropagates` (pass a `recycle` arg, discard the bool), and the kernel-level
  `TestZipToShares_WorseBetterPriceSelection` (pass `true` for the existing token0 case). NEW cases:
  (a) a `ProdQuoter` case with scripted `zipUSD == token1` asserting `zipIsToken0 == false` AND that the
  returned shares equal the kernel result with `zipIsToken0=false`; (b) a `ProdQuoter` case with `zipUSD`
  scripted to NEITHER token asserting the error; (c) a kernel-level `zipIsToken0=false` sibling of the
  worse/better test asserting `shares == mulDiv(depositZip, totalSupply, denom)` (i.e. the numerator is the
  RAW `depositZip`, NOT priced) — pick `price≠twap` so this is provably distinct from the token0-side result.
  (`numerator` is an unexported local; assert on the returned `shares`, not on `numerator` directly.)
- `strike_loop_job_test.go`: existing happy-path/sim cases pass with `fakeQuoter{zipIsToken0:true}` and still
  assert `addLiquidity(expectedZip, 0, minShares)`; a NEW token1-side case (`fakeQuoter{zipIsToken0:false}`)
  asserts the plan builds `addLiquidity(0, expectedZip, minShares)` and `stake(minShares)`, same 9 labels.
- `strike_loop_job_sim_test.go`: unchanged assertions (token0 side); the `fakeQuoter` is updated to the new
  signature with `zipIsToken0:true`. The probe bytecode is NOT touched.
- The cold-build introduces ZERO load-bearing guesses; every getter (`zipDepositModule`, `zipUSD`, `token0`,
  `token1`) is confirmed against live source. The Go module committed to `cre/keeper` with the gate green.

## Depends on
KEEPER-01b core slice (DONE) — this modifies its restake leg. No inbound cross-ticket obligation. The engine
modules (`LpStrategyModule`, `RecycleModule`, `ZipDepositModule`) are built + fork-tested; their ABIs are the
truth source.
