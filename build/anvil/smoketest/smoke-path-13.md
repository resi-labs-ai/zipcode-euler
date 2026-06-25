# SP-13 — Buy-burn full exit (sell shares for USDC, then exit) (seam S10)

**Intent.** The full exit cycle: post a discounted CoW buy order (engine pulls USDC), a counterparty's szipUSD is
bought, and the bought shares are burned — NAV-per-share ticks up for the stayers.

**Proves.** `postBid` (SP-05) → settlement delivers szipUSD to the engine Safe (simulated solver) → `ExitGate.burnFor`
(windowController) burns Loot + szipUSD with no asset payout → spot NAV/share rises; the two-token invariant survives
the burn; SUPPLY-ADV-14 poke-before-`navExit`. Sources: `docs/supply/szipUSD/SzipBuyBurnModule.md` + `ExitGate.md`,
wires `8-B14-SzipBuyBurnModule.md`, `ExitGate-szipUSD.md`.

**Tier.** Needs-forwarder (NAV legs) + simulated CoW fill (boundary #3).

**Binds to** (by name — clones): `SzipBuyBurnModule`, `ExitGate` (windowController = `creOperator`), szipUSD, Loot,
main (engine) Safe, CoW `GPv2Settlement`, USDC.

**Setup.** `seed_marks`; `zap(1_000e6)` (alice holds szipUSD; basket funded); `deal` USDC to the main Safe to fund the bid.

**Calls (happy/simulated).** 1. `postBid((quoteMaxPrice·200, 200e18, now+1h))` as `creOperator`. 2. simulate the solver
fill: transfer 200e18 szipUSD alice→engine Safe + move the bid's USDC out (boundary #3). 3. read `spotNavPerShare`
pre/post-fill. 4. `burnFor(200e18)` as `creOperator`.

**Assertions** (On-chain=Yes): after fill, NAV/share rises (engine Safe's szipUSD excluded from `_effectiveSupply`);
after burn, `szipUSD.totalSupply()` −200e18, `Loot.balanceOf(gate)` −200e18 (two-token invariant preserved), engine
Safe szipUSD → 0; NAV2 == NAV1 (the burn finalizes the fill-time tick-up).

**Notes.** The settlement contract + presignature are real; only the off-chain solver match is simulated. The NAV
benefit realizes at the **fill** (effective-supply drop), `burnFor` permanently finalizes it.

**Result.** **PASS** (2026-06-24, live fork; basket NAV0 = 1.5e18 from 1,000e18 zipUSD + 500e6 USDC over 1,000 shares).
- `postBid(sell=297e6, buy=200e18)` (= quoteMaxPrice·200 at the 1% discount) status 1.
- **NAV0 (pre-exit) = 1.5e18 → NAV1 (post-fill) = 1.50375e18** (+0.25%): engine Safe holds 200e18 szipUSD, excluded
  from `_effectiveSupply` (1000→800); the discounted USDC left the basket → haircut accrues to stayers. ✓
- `burnFor(200e18)` status 1: `szipUSD.totalSupply()` 1,000e18 → **800e18**; `Loot.balanceOf(gate)` 1,000e18 →
  **800e18** (two-token invariant preserved); engine Safe szipUSD → **0** (burned, no asset payout). ✓
- **NAV2 (post-burn) = 1.50375e18 == NAV1** (burn finalizes; no further NAV change). NAV2 > NAV0 — the economic claim
  holds. **No flaws.**
