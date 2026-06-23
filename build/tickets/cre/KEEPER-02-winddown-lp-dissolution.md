# KEEPER-02 — the wind-down LP-dissolution driver (`unstake` → `removeLiquidity`), TWAP-floored, privately submitted

> BUILD item (K-transport keeper Job). Drives the ONE engine leg that has **no off-chain driver today**:
> `LpStrategyModule.removeLiquidity` — the global-wind-down LP→legs hop. Sibling to the StrikeLoop harvest
> orchestrator (KEEPER-01b); this is a separate, exception-only Job, not part of the auto-compounder.
>
> Source: adversarial-review on `LpStrategyModule.sol` (`adversarial-review/reports/src/supply/lpstrategymodule/
> synthesis.md`, mission 3 + the verified-ICHI-source follow-up) → the audit finding **SUPPLY-ADV-09** (size the
> remove floor off TWAP fair-reserves). That finding established the *rule*; this ticket builds the *hand* that
> applies it. Routing: `CRE-OPS-ROUTING.md:37` puts `LpStrategyModule` on **(K) keeper**.

## The gap (verified)

`removeLiquidity(shares, minAmount0, minAmount1)` (`contracts/src/supply/szipUSD/LpStrategyModule.sol:259-273`)
is the wind-down LP→legs dissolution hop — the global-drain feeder (`unstake` → `removeLiquidity` →
`SellModule.sellXAlpha` → zipUSD → senior par queue). It is `onlyOperator`, coverage-gated (reverts
`Undercovered` unless `coverageGate.lpBurnKeepsCovered(shares)`, `:269`), and the contract itself records it has
**NO live-ops caller** (`:248-253`).

Confirmed: no keeper Job builds it. Registered jobs are `identity, burn, strikeLoop, redemption`
(`cre/keeper/cmd/keeper/main.go:166`); a grep for `removeLiquidity`/wind-down/teardown across
`cre/keeper/internal/job` + `internal/chain/encode.go` returns nothing. The StrikeLoopJob drives
`LpStrategyModule` only for the restake legs (`unstake`→…→`addLiquidity`→`stake`), never `removeLiquidity`.

**So the dissolution path is an on-chain function whose only caller does not exist.** Two consequences this
ticket closes:
1. **The floor is unsized.** SUPPLY-ADV-09: ICHI's `withdraw` self-protects with *nothing* (it decomposes
   liquidity at the current pool tick — no hysteresis/TWAP, verified against Base vault
   `0xfF8B…73f7`), so the caller's `minAmount0/1` is the *sole* sandwich guard. There is no code sizing it.
2. **No MEV-protected submission.** The hop is public-mempool-exposed; nothing routes it privately.

The good news: the *pattern* already exists. `cre/keeper/internal/quote/quote.go` already ports
`IchiAlgebraFairReserves._meanTick` (`quote.go:159-160`) and the ICHI deposit math to TWAP-size StrikeLoop's
`addLiquidity` `minShares`. This ticket applies the **same TWAP source** to the **withdraw** side — the side
that actually needs it (the add side is already vault-protected by ICHI's hysteresis).

## The Job (one ordered `chain.Plan`, exception-only)

A `WindDownLpJob` (mirroring `StrikeLoopJob`'s read→compute→submit shape), triggered on an explicit wind-down
signal (config flag / treasury directive — NOT a routine poll). Per invocation it dissolves a coverage-bounded
slice:

1. **Size the burn `shares` to the coverage EXCESS.** `removeLiquidity` only liquefies LP excess over the floor
   (`:269`). Compute the dissolvable amount off the same oracle the gate uses:
   `excessValue = coverageValue() − requiredCommittedValue()` (read off `DurationFreezeModule` /
   `SzipNavOracle`); `maxShares = excessValue / lpShareValue(1e18)`; clamp to `lpBalance()`
   (`LpStrategyModule.lpBalance`, `:302`). Optionally fall back to probe-and-shrink on an `Undercovered` revert.
   (As senior liabilities are redeemed during the drain, the floor falls and successive invocations dissolve
   more — the Job is re-runnable to completion.)
2. **`unstake` the slice first.** The LP is gauge-staked; `removeLiquidity` burns LP held *in the Safe*. Call
   `unstake(shares)` (`:288`) to pull it back from the gauge before the burn (the contract notes this ordering,
   `:251-252`).
3. **TWAP-size `minAmount0/1`** (the SUPPLY-ADV-09 rule — withdraw variant):
   ```
   (fair0, fair1) = fairReserves(ichiVault, KEEPER_TWAP_PERIOD)   // reuse quote.go meanTick / plugin read
   supply         = IICHIVault.totalSupply()
   expected_i     = fair_i * shares / supply                       // honest pro-rata at the TWAP tick
   minAmount_i    = expected_i * (1 − KEEPER_CUSHION_BPS)          // 200 bps = 2%, the A2 constant
   ```
   `fairReserves` already returns base+limit positions reconstructed at the TWAP tick **plus idle balances** —
   exactly what an unmanipulated `withdraw` decomposes to pro-rata. Both legs are floored (the withdraw returns
   both; this is not single-sided). Fail closed if the pool has no plugin / unready TWAP (same `NoPlugin`/
   `PluginNotReady`/`BadTimepoints` posture the lib and `quote.go` already enforce — never size off spot).
4. **Submit privately.** Broadcast this tx through a Base-supporting protected/private RPC, not the public
   mempool (closes the sandwich *window*; the TWAP floor bounds the worst case if it ever lands public). See
   "Private submission" below.
5. **Hand off.** The legs land in `juniorTrancheEngine` (the pinned `to`, `:270`); the downstream sell
   (`SellModule.sellXAlpha`) is a separate leg/Job — out of scope here.

## Private submission (the operational half — NEEDS-CONFIG, no new code)

The keeper broadcasts via plain `eth_sendRawTransaction` to a configurable endpoint
(`cre/keeper/internal/chain/chain.go` `Submit` → `SendTransaction`; endpoint = `KEEPER_RPC_URL`,
`README.md:33`). Pointing the broadcast at a protected RPC routes the signed tx privately with **no code
change**. Two caveats:
- **Base, not L1.** Flashbots Protect is Ethereum-L1-centric; source a Base-supporting protected endpoint
  (MEV-Blocker / a Base-native private RPC / builder endpoint). This is the one build-time to-do.
- **Scope the private endpoint to the wind-down write** (a separate `KEEPER_PRIVATE_RPC_URL` used only by this
  Job's `Submit`, or run the wind-down with `KEEPER_RPC_URL` swapped) so routine read traffic isn't forced
  through it.

## New config knobs (extend `internal/config` + `.env.example`)

| Var | Meaning | Default |
|---|---|---|
| `KEEPER_PRIVATE_RPC_URL` | protected/private RPC for the wind-down `removeLiquidity` broadcast (Base-supporting) | — (falls back to `KEEPER_RPC_URL` if unset, with a logged warning) |
| `KEEPER_WINDDOWN_ENABLED` | arm the `WindDownLpJob` (exception-only; default off) | `false` |
| `KEEPER_WINDDOWN_MAX_SLICE` | optional per-invocation share cap (defense-in-depth on top of the coverage-excess clamp) | — (0 = no cap) |

Reuses existing `KEEPER_CUSHION_BPS` (200) and `KEEPER_TWAP_PERIOD` (3600s) — same constants StrikeLoop floors
`addLiquidity` with (A2/A3, `KEEPER-01b`).

## Gate / acceptance

- `cd cre/keeper && go vet ./... && go build ./... && go test ./...` green (native, not wasip1).
- The submit spine for the Job is tested against `ethclient/simulated` (the `OnlyOperatorProbe` pattern) — assert
  it builds `unstake` then `removeLiquidity` with `minAmount0/1` derived from a stubbed `Quoter` returning a
  known `(fair0, fair1)`, and that `minAmount_i == expected_i * (1 − cushion)`.
- A unit test asserts the share-sizing clamps to the coverage excess and to `lpBalance()`, and that a `NoPlugin`/
  unready-TWAP Quoter error **aborts** the Job (never falls back to spot).
- A test asserts the Job's `Submit` uses `KEEPER_PRIVATE_RPC_URL` when set.
- Doc: `cre/keeper/README.md` gains a `WindDownLpJob` row + the two/three new env vars; `CRE-OPS-ROUTING.md:45`
  (the DurationFreeze/wind-down row) cross-references this Job.

## Cross-references

- **SUPPLY-ADV-09** (audit) — the floor-sizing rule + the doc corrections (deposit is vault-protected; withdraw
  is not). This ticket is where that rule is realized in code. Update SUPPLY-ADV-09's "fix" to point here.
- **SUPPLY-ADV-10** (optional on-chain backstop) — `ZeroMinAmount` "at-least-one-floor" guard in
  `removeLiquidity`; belt to this ticket's suspenders.
- **CRE-OPS-ROUTING.md** — (K) routing for `LpStrategyModule`; the liveness-only/fail-safe model (the on-chain
  `covered()` gate is the backstop if this Job is down).
- **KEEPER-01b** — the StrikeLoop harvest orchestrator whose `quote.go` TWAP pattern + cushion constants this
  Job reuses.

## Scope / non-goals

- NOT the downstream sell (`SellModule.sellXAlpha`) or the senior par-queue settle — separate legs.
- NOT the dormant `DurationFreezeModule.commit`/`release` lever (D1, freeze rebuild).
- NOT a routine poll — wind-down is exception/directive-driven; the Job stays disarmed by default.
- The contract is unchanged; this is purely the (K) keeper driver + config. (`removeLiquidity` already exists and
  is gated/tested on-chain.)
