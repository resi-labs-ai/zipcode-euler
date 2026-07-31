# The buy-burn round — one lifecycle, four transports

The szipUSD exit is one repeating round: **raise → bid → fill → burn**. Every leg is documented where it
lives; this page is the stitch — the whole round in order, with who acts, what moves, and why NAV never
wobbles. (Contracts: `build/claude-zipcode.md` §6.1/§6.4/§7; per-leg docs linked each step.)

One Safe carries the whole round: `juniorTrancheSafe` (== `juniorTrancheEngine` — ONE address, two role
names; `docs/safe-identities.md`). The basket, the raised USDC, and the pre-burn szipUSD all sit there.
There is no cross-Safe routing.

## 0. Standing state

- Holders exit by resting CoW SELL orders for their szipUSD (the book IS the queue).
- The Safe holds the junior basket (zipUSD, xALPHA, LP, …) and NO idle USDC — bid money is raised
  just-in-time, per round.
- `cre/buyburn-bid` (CRE-05a, wasip1) keeps the single resting BUY bid reconciled; it never funds anything.

## 1. RAISE — basket zipUSD → USDC at par (two transports, (R) then (K))

1a. **(K)** `cre/keeper` RedemptionJob (`internal/job/redemption_job.go`) escrows idle basket zipUSD:
    `OffRampModule.requestRedeem` → `ZipRedemptionQueue` (whole-USDC units only).
1b. **(R)** `cre/warehouse` (CRE-04) drives the funding: `WarehouseAdminModule` REDEEM
    (`eePool.redeem(shares, warehouseSafe, warehouseSafe)` — **this is the moment un-lent EulerEarn cash
    comes out**) then REPAY (`usdc.transfer(redemptionBox)` — destination hard-pinned to the queue).
1c. **(K)** RedemptionJob settles + claims: `ZipRedemptionQueue.settleEpoch` fills `min(available, pending)`
    at par and **burns the filled zipUSD** (first burn of the round); `OffRampModule.claim` lands the USDC
    on the `juniorTrancheSafe`.

NAV through the raise: value-neutral. zipUSD (counted at $1) becomes queue receivables (counted — the
finding-2 fix) becomes USDC (counted). An asset changes clothes; nothing leaves the books.

## 2. BID — fill-only (ratified 2026-07-30)

The protocol only fills. It never makes a market. `cre/buyburn-bid` reads the CoW book for resting
szipUSD sell orders asking at or below the current fair price (`quoteMaxPrice` = `navExit × (1 − dBps)`).
No acceptable order resting ⇒ no bid. Orders resting ⇒ one bid sized to exactly that demand, capped by the
warehouse's free liquidity (`maxWithdraw(warehouse)` net of working-capital reserves) and `buybackCap`,
posted via the report path (`SzipBuyBurnModule._postBid`: coverage-gated, freshness-fenced, presigned).
Repost on size/price drift; cancel when not postable or when the acceptable demand disappears. This kills
the stale-resting-bid family at the root: there is no resting protocol price without someone already there
to fill it. See `cre/buyburn-bid/README.md`.

## 3. FILL — atomic swap on CoW

A solver matches an exiting holder against the bid. In ONE settlement transaction: the Safe's USDC pays the
seller; the seller's szipUSD lands on the Safe. The instant it lands, `SzipNavOracle._effectiveSupply`
stops counting it (the pre-burn exclusion) — so the fill is one clean step: counted USDC out, dead shares
out of the denominator, same tx. **NAV per share steps UP at the fill** (the bid price sits below NAV; the
spread accretes to stayers). No dip, no gap.

## 4. BURN — the blowtorch (fill-triggered)

**(K)** `cre/keeper` BurnJob (`internal/job/burn_job.go`) fires only on EVIDENCE OF A FILL —
`GPv2Settlement.filledAmount(uid)` for the bid module's live/last uid, a mapping a szipUSD donor cannot
touch — and then calls `ExitGate.burnFor(fullBalance)`: the szipUSD and its matching Loot destroyed in
lockstep (second burn of the round). Price does NOT move here: the oracle already excluded the balance at
step 3. The burn is housekeeping — deliberately ungated by coverage/freshness (`burn_job.go` header: a
lagging or missed burn cannot dilute or inflate NAV-per-share).

Stranger DONATIONS ("let the dusters dust", ratified 2026-07-28): a donor transferring szipUSD to the Safe
never costs the keeper a tx — no fill evidence, no burn. The donation sits, already priced as an instant
irrevocable gift to holders (supply-excluded on arrival, the audit finding-12 surface, won't-fix), until
the next real fill sweeps the full balance — loot and dust together, no floor, no partial-burn mode.

## The round in one line

zipUSD dies at par (step 1c); szipUSD dies below NAV (step 4); the spread between those two prices is the
stayers' gain — and the only NAV movement in the entire round is that single step-up at the fill.

## Who may act

| Leg | Actor | Gate |
|---|---|---|
| requestRedeem / claim | keeper (K), `OffRampModule` operator | `onlyOperator` |
| REDEEM / REPAY | `cre/warehouse` (R) → `WarehouseAdminModule` | Forwarder + Zodiac Roles scope |
| settleEpoch | keeper as queue `controller` | `onlyController` |
| postBid / cancelBid | `cre/buyburn-bid` (R) or operator key | forwarder / `onlyOperator` |
| burnFor | keeper as `windowController` | `onlyWindowController` |
