# Outflow gate — RESOLVED (build record)

> **STATUS (re-verified against live source 2026-06-13).** Every item this doc originally raised is now
> closed — built, superseded by a better design, or deliberately triaged out. Nothing here is live open
> work. The live open supply findings are elsewhere: **`build/twap-ring.md`** and **`build/zap-residual.md`**.
> This file is kept as the provenance record for how the coverage outflow gates landed.

## What this doc originally found (and where it went)

When first written, `DurationFreezeModule.covered()` had **zero consumers** and no coverage-relevant
outflow was gated. Four items were raised:

| original item | resolution (verified against code) |
|---|---|
| `SzipBuyBurnModule.postBid` gated on `covered()` | **BUILT** — settable `coverageGate` + `revert Undercovered` (`SzipBuyBurnModule.sol:297-298`), armed at deploy. |
| `LpStrategyModule` LP-dissolution gated | **BUILT** — `removeLiquidity` reverts on `!lpBurnKeepsCovered` (`LpStrategyModule.sol:268-269`). |
| staked-LP reachability (the `commitStaked` idea) | **SUPERSEDED (better)** — LP fenced in place + counted via `pathLockedLpEquity`, removed from the freeze whitelist (`DurationFreezeModule.sol:153,320`). No relocation; LP stays staked + earning. |
| reservoir `borrow` (the "draw") gated on coverage | **TRIAGED — SKIPPED** (user, 2026-06-13). See below. |

The first three shipped in the `lp-path-lock` build (`build/lp-path-lock.md`, 166/166 green). The
`covered()` reframe used a `coverageGate` (zero ⇒ off, armed at deploy, Timelock kill-switch) rather than
the hardwired wire originally sketched here — the cleaner form.

## Why the draw gate was skipped (not an oversight)

`ReservoirLoopModule.borrow` is still ungated on coverage (only the `borrowCap` bound;
`ReservoirLoopModule.sol:227-245`). This was raised here as the one remaining gap, then deliberately
triaged out (the draw-time coverage gate was abandoned 2026-06-16 — see the `drawgate` DEFER in
`build/kill-list.md`; pool USDC liquidity already bounds draws). The reasoning, which holds
up against the post-lp-path-lock code:

- **The borrow is the harvest loop's strike financing**, repaid within the same harvest tick. Gating it on
  `covered()` would gate the *yield engine* — and `lp-path-lock.md` makes "the harvest loop is NOT gated" a
  deliberate property (the gate is transparent at zero senior debt; the loop must run even when coverage is
  tight, which is when yield matters most).
- **The borrow is over-collateralized at the EVK level** (escrow-LP collateral, EVC health enforced via the
  LP oracle, `ReservoirBorrowGuard` pins it to the engine Safe). It cannot draw beyond its own collateral's
  LTV regardless of junior coverage.
- The original "a borrow deepens the breach" framing was premised on debt *not* being netted in NAV — the
  pre-lp-path-lock state. Debt is now subtracted (`pathLockedLpEquity` nets `debtOf`), so the only residual
  effect is a *transient* `coverageValue` dip during an open loop (borrowed USDC lands free-side while the
  debt reduces `pathLockedLpEquity`), restored on repay. Trading a transient, operator-driven,
  over-collateralized dip against blocking the yield engine is a reasonable call.

If leverage ever scales materially or the senior pool gains non-draw outflows, revisit via an
`illiquidSeniorValue() + draw <= zipUSDValue()` capacity gate (the abandoned `drawgate` concept in
`build/kill-list.md`) — **not** the cheap `covered()` gate. ⚠️ That capacity read would be TWAP-bracketed and
would inherit the `build/twap-ring.md` ring behavior.

## Net

Coverage outflow gating is **done**. The remaining live supply findings are `build/twap-ring.md`
(NAV bracket collapsible via poke-spam) and `build/zap-residual.md` (1-wei zap brick) — both re-verified
unfixed against the current tree.
