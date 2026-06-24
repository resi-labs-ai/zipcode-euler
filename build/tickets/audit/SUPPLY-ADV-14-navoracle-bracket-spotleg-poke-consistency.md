# SUPPLY-ADV-14 — bracket does not defend an in-block-manipulable spot leg; `postBid` reads `navExit` un-poked

> **STATUS: BUILT + SHIPPED to `main`** (2026-06-24). `_postBid` now `poke()`s before `navExit` (`INavOracle`
> extended with `poke()`); NatSpec `SzipNavOracle.sol:48` corrected (bracket attenuates to `g/W`; fair-reserves is
> the structural LP defense; deploy-ordering documented). **Divergence from the planned fix:** the optional
> `maxPokeGap` ctor-revert hardening (fix item 3) was DEFERRED — it needs a new ctor immutable threading through
> every deploy script + test ctor, too wide a blast radius for a LOW, and no TWAP-math change was shipped (the
> leak's structural defense is `lpTwapWindow != 0`, already present). The cold-ring window (fix item 2's
> deploy-ordering clause) is addressed by docs, not a read-time revert, for the same reason. Regression
> `test_SUPPLYADV14_postBid_pokes_before_navExit`; buy-burn 54/54, NAV 64/64, `forge build` clean.
>
> BUILD item (LOW, deflated from a raw MEDIUM). Source: adversarial-review on `SzipNavOracle`
> (`adversarial-review/reports/src/supply/szipnavoracle/`, mission 1). Single-model (Claude) run.
> **Not a defeated bracket on a clean basket** — it is the consumer-side articulation of why `lpTwapWindow`
> (fair-reserves) is the real defense for the LP leg, plus a cheap cross-module poke-consistency fix.

## The gap (source-verified)
- `twapNavPerShare` (`SzipNavOracle.sol:481,498`) values the leading segment `[lastUpdate, now]` at the
  **current spot** with weight `g/W` where `g = now − lastUpdate`: `twap = histAvg·(1 − g/W) + spot·(g/W)`.
  `navExit = min(spot, twap)` / `navEntry = max(spot, twap)` (`:516-518` / `:509-511`) therefore inherit a
  `g/W`-weighted slice of any in-block-manipulable spot move.
- **`poke()` does NOT remove it.** `_accumulate()` (`:351`) books `cumNav += spotNavPerShare()·g` over the same
  `[lastUpdate, now]` gap at the same spot, so poking-before-read yields an identical TWAP. The NatSpec at
  `:49-51` ("the Gate MUST `poke()` before every exit/issuance read … the defense is the TWAP lag") overstates
  what poke achieves: poke keeps `g` small only if an *honest* keeper poked recently; it cannot retroactively
  un-weight a spot already moved in the current block.
- The only in-block-manipulable leg is the ICHI LP spot reserves when `lpTwapWindow == 0` (`_lpValue:454-455`
  reads spot `getTotalAmounts()`). When `lpTwapWindow != 0` the fair-reserves TWAP-tick path (`:452-453`) closes
  it — i.e. **the structural defense for the LP leg is `lpTwapWindow`, not the bracket.**
- **Cross-module inconsistency:** `ExitGate.depositFor` pokes before reading (`ExitGate.sol:164` →
  `navEntry()` `:165`), but `SzipBuyBurnModule.postBid` reads `navExit()` (`SzipBuyBurnModule.sol:365`) with NO
  poke anywhere in the path — leaving `g` = time-since-last-keeper-poke on the one path that pays USDC out of
  the basket (`:374` ceiling).
- **Cold-ring corollary:** for the first `W` of *deployed life* (not just zero-supply genesis), the
  `twapNavPerShare` loop finds no `o.ts ≤ target` (only `observations[0]=(deployTs,0)` is seeded, ctor `:219`)
  and returns spot (`:497`), so `navExit == navEntry == spot` even with live supply.

## Mechanism + impact
An attacker who moves the ICHI LP reserves UP in the same block as an exit read makes `navExit = twap` price a
**rich exit** above the honest window by `(g/W)·Δspot·(LP-fraction-of-NAV)`; a DOWN move makes `navEntry` a
**cheap mint** by the same weight. On the `postBid` path an inflated `navExit` raises the USDC ceiling the
protocol pays to retire szipUSD; if it exceeds the discount `d`, basket value leaks out. Bounded by: requires
`lpTwapWindow == 0`, the LP is a fraction of the basket, the attacker cannot inflate `g` themselves (only keeper
absence does), capacity-gated minting, and the `d` discount on the buy-burn path. Not reproducible by the
deterministic tests, which poke at the read block (forcing `g = 0`).

## Honest severity (LOW)
Conditional on the `lpTwapWindow == 0` state (the documented M1 pre-Algebra residual that fair-reserves is
designed to retire), value-bounded by `g/W` and the LP fraction, and the buy-burn leak is further buffered by
`d`. Not an unconditional bracket defeat. What IS definitive: poke does not defend the leading edge (NatSpec is
wrong on this), and `postBid` is gratuitously un-poked vs its sibling.

## Fix
1. **`SzipBuyBurnModule.postBid`:** add `INavOracle(navOracle).poke()` before the `navExit()` read (`:365`).
   Extend the local `INavOracle` interface (`:12-16`) with `function poke() external;` (it is currently
   view-only). Mirrors `ExitGate.depositFor`.
2. **NatSpec correction (`SzipNavOracle.sol:49-51`):** state that the bracket attenuates an in-block spot move
   to `g/W` but does NOT eliminate it, that `poke()` keeps `g` small only under honest keeper liveness, and that
   the structural defense for the in-block-manipulable LP leg is `lpTwapWindow != 0` (fair-reserves). Document
   the deploy-ordering constraint: do not fund the LP with `lpTwapWindow == 0`, and do not open exit/issuance,
   inside the first `W` of deployed life — wire `lpTwapWindow` (or keep `ichiVault == 0`) until the ring has `W`
   of poked history.
3. **(Optional hardening)** add a governed `maxPokeGap ≪ W` and revert `navEntry`/`navExit` when
   `now − lastUpdate > maxPokeGap`, so the leading-segment weight self-bounds independent of keeper liveness.

## Gate
`forge build` clean + `forge test --match-path 'test/supply/SzipNavOracle.t.sol'` AND
`'test/supply/SzipBuyBurnModule.t.sol'` green. Add a regression that: (a) with `lpTwapWindow == 0` and a large
`g`, an LP-reserve spike moves `navExit` by ~`g/W·Δ` and the same spike under `lpTwapWindow != 0` (fair-reserves)
does NOT; (b) `postBid` calls `poke()` (assert `lastUpdate == block.timestamp` after a `postBid`).

## Doc-sync (after code)
- `contracts/src/supply/x-ray/SzipNavOracle.md` — §5 "Documented accepted trade-offs": refine the
  `navExit`-off-stale / keeper-`poke` note to state the `g/W` leading-segment bound and that fair-reserves
  (not the bracket) defends the LP spot leg; note the `postBid` poke now matches `ExitGate`.
- `contracts/src/supply/szipUSD/x-ray/SzipBuyBurnModule.md` — record the added `poke()` before `navExit`.
- grep-verify the `:49-51` claim is not restated verbatim elsewhere in `docs/`/`build/` before editing (filter
  generic "poke" hits).

## Acceptance criteria
- `postBid` pokes before `navExit`; `INavOracle` extended; both suites green with the new regressions.
- NatSpec `:49-51` corrected (poke does not defend the leading edge; fair-reserves defends the LP leg);
  deploy-ordering constraint documented.
- X-Rays updated; the `g/W` bound and the `lpTwapWindow`-is-the-real-defense framing recorded.
