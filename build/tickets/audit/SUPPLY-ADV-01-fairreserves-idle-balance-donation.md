# SUPPLY-ADV-01 — fair reserves count raw idle vault balances (in-block donation seam) → WONTFIX

> BUILD item. Source: adversarial-review on `AlgebraIchiFairLpOracle` + `IchiAlgebraFairReserves`
> (`adversarial-review/reports/src/supply/algebraichifairlpooracle/`, mission 1). Re-rated to **WONTFIX**
> on review against the deployed topology (2026-06-22). The synthesis rated this LOW on the premise of a
> "live borrow market → bad debt"; that premise does not hold for any consumer of this lib, and the proposed
> fix would actively harm honest valuation while not closing the theoretical seam.

## The original observation (source-verified, still true)
`IchiAlgebraFairReserves.fairReserves:69-70` adds the vault's idle balances into the reconstructed TVL:
```
amount0 += IERC20(IICHIVault(vault).token0()).balanceOf(vault);
amount1 += IERC20(IICHIVault(vault).token1()).balanceOf(vault);
```
The position legs (`:47-66`) are reconstructed at the TWAP `sqrtP` (in-block-immune); `balanceOf(vault)` is a
live read of an in-block-movable quantity. A donation raises `tvlInQuote` with `totalSupply()` unchanged →
per-share value rises. That mechanic is real. **What is NOT real is any path to convert it into value.**

## Why WONTFIX — no extraction path, and the term is correct
Walking the would-be exploit against the actual deployment kills every leg:

1. **Idle balances are real assets the vault owns.** Counting them is *correct* NAV. Excluding them (the
   synthesis's "canonical" fix) would under-report real value **every block**, not just under attack — a
   permanent, continuous markdown of honest TVL to defend against a non-threat. Wrong direction.

2. **No collateral-borrow path.** szipUSD is not used as borrow collateral anywhere — there is no szipUSD
   borrow vault. The lib's *other* consumer, `AlgebraIchiFairLpOracle` on the farm-utility market, has a
   borrow vault, but `FarmUtilityMarketDeployer.sol:18,38` installs `FarmUtilityBorrowGuard` pinning
   `OP_BORROW` to the engine Safe as **the sole legal borrower**. No external party can borrow against an
   inflated mark.

3. **No exit-at-mark.** The only szipUSD exit is the CoW order book (§17): a holder exits at what a
   counterparty (the CRE buy-burn bid, or another taker) is willing to pay — **not** at the oracle's NAV
   mark. Pumping NAV does not pump your sale proceeds. There is no liquid redemption at the mark.

4. **The collateral is protocol-owned liquidity.** The donation attack needs a *dominant external holder*;
   the engine Safe is the dominant holder of the POL ICHI vault, so a donation is mostly a self-gift, split
   pro-rata to every other holder. Self-defeating.

5. **The proposed fix does not even close the seam.** Excluding idle does not remove the ability to inflate
   TVL with real money — deposit the stray cash, let an ICHI rebalance sweep it into the LP, and it is now
   counted in the position leg the fix *keeps*. Same inflation, one block later. The only thing that actually
   neutralizes inflate-then-extract is the absence of liquid redemption at the mark — which already holds
   (leg 3). So "drop idle" moves the goalpost; it closes nothing.

The oracle is also **opt-in and currently off**: `DeployMainnet.s.sol:91` defaults `LP_TWAP_WINDOW = 0`, at
which `AlgebraIchiFairLpOracle` is never deployed (CRE-push `SzipFarmUtilityLpOracle` + spot NAV leg are used).

## Disposition
**WONTFIX. No code change.** Keep the idle term — it is real value and belongs in NAV. The in-block-movable
property is inert: there is no borrow-against-mark and no redeem-at-mark path to monetize an inflated TVL, and
the "fix" would (a) under-mark honest value continuously and (b) fail to close the theoretical seam anyway.

## Acceptance criteria
- No source change to `fairReserves`. The idle term stays.
- X-Ray / wire note updated: idle inclusion is deliberate (real assets); the donation seam is documented as
  inert given no-collateral-borrow + CoW-only-exit + no-redeem-at-mark, not as an open finding.
