# CoW-exit.md — the szipUSD exit + redemption-liquidity map

> Process note (not a wire doc), authored 2026-06-12. Truth-source = the kept contracts under
> `contracts/src/supply/`; per-contract detail lives in `build/wires/`. This traces how a szipUSD holder exits,
> where the USDC comes from, and how exit liquidity contends with the harvest loop for the same reservoir.

## The one-line shape
szipUSD has **no redemption** — the only exit is **selling the share on CoW**, where the protocol rests a
discounted buy-and-burn bid. That bid is funded by USDC the CRE frees from EulerEarn and walks through the senior
redemption queue. The same free EulerEarn USDC also finances the oHYDX harvest loop, so **exit liquidity and
harvest working capital are two claims on one reservoir**, coupled in real time through utilization.

## The shared liquidity pool
- **`EulerEarn` (external) + the reservoir borrow vault** — the warehouse's resting USDC. The single pool both
  exits and the harvest loop draw from. Only the un-lent (free) fraction is reachable; at utilization `U`, only
  `1 − U` of the float is liquid.
- **`WarehouseAdminModule` (8-Bw)** — `REDEEM` (`eePool.redeem(shares, safe, safe)`: EE shares → USDC in the
  warehouse Safe) / `REPAY` (`usdc.transfer(queue, amount)`: USDC → the redemption queue). CRE-only via the
  Chainlink Forwarder, Roles-scoped, `repaySink` pinned `EqualTo(queue)`. Wire: `build/wires/8-Bw-CreditWarehouse.md`.

## The exit path (zipUSD → USDC → CoW → burn)
1. **`OffRampModule`** — `requestRedeem` / `claim`, execs **through the rq Safe** (so the queue sees the Safe as
   `msg.sender`). CRE-operator gated. Wire: `build/wires/OffRampModule.md`.
2. **`ZipRedemptionQueue` (item 9)** — `settleEpoch` (reserve REPAY-delivered USDC against pending, burn the filled
   **zipUSD**) / `claim` (USDC → rq Safe, at par). `onlyController` (CRE), **on-demand** (the 30-day epoch time gate
   was removed 2026-06-12). Emits `RedemptionSettled`. `requestRedeem` is C4-gated to the rq Safe (single requester
   → the pro-rata `era`/`cumRemaining` engine is dormant; open TODO). Wire: `build/wires/9-ZipRedemptionQueue.md`.
3. **`SzipBuyBurnModule` (8-B14)** — `postBid` / `cancelBid`: a single resting CoW BUY szipUSD order, `sellToken =
   USDC`, `receiver = engineSafe`, partially fillable, priced **≤ `navExit × (1 − dBps)`**, signed via PRESIGN.
   **`postBid` sets the USDC→vaultRelayer approval + presignature with NO balance check** — posting is free and can
   be over-sized; the order only **fills** against USDC actually in the engine Safe at solver-settlement time.
   `sellAmount ≤ buybackCap` (cap = 0 = kill switch). Wire: `build/wires/8-B14-SzipBuyBurnModule.md`.
4. **`ExitGate.burnFor`** — retires the bought szipUSD (`burnLoot` + `SzipUSD.burn` from the engine Safe), **no
   asset payout** → NAV-per-share ticks up for stayers. `windowController` (CRE) gated.
5. **`SzipUSD`** — the transferable share; `mint`/`burn` are `onlyGate`. No redemption function exists.

**Consequence:** the buyback is NAV-accretive, not a payout — value transfers from impatient exiters (who eat the
haircut `d`) to stayers (who get the NAV bump). Demand past the protocol's funded bid depth clears against external
CoW buyers below the floor (a "lowball"), which the protocol can itself later buy and burn.

## Pricing — `SzipNavOracle`
- `navExit = min(spot, twap)` — **does NOT revert on staleness** (exit always prices off the last good mark).
- `navEntry = max(spot, twap)` — reverts `StalePrice` if a required leg is stale (issuance pauses).
- `fresh()` gates issuance AND the bid's `validTo ≤ now + maxAge` freshness fence in `postBid`.
- `_bal` sums both Safes; `grossBasketValue` / `_grossValueOf(safe)` value the ICHI LP per-Safe (incl. gauge stakes).

## The contention — the harvest loop draws the SAME USDC
- **`ReservoirLoopModule` (8-B5)** — `postCollateral` / `borrow` / `repay` / `withdrawCollateral`. **Borrows the
  ~30% strike USDC FROM the warehouse resting vault** (`borrowVault` = the reservoir borrow vault inside EE = the
  warehouse's free USDC), borrower-of-record = the engine Safe (EVC sub-account 0). `borrowCap` bounds aggregate
  debt. The LP **self-collateralizes**: 8-B6 unstakes an LP slice → `postCollateral` → `borrow` → exercise → sell →
  `repay` → re-stake.
- **`ExerciseModule` (8-B8)** — `exercise(amount, maxPayment, deadline)`: pays the USDC strike (already in the Safe
  from the 8-B5 borrow) to oHYDX, mints liquid HYDX to the engine Safe. `maxPayment` is the strike slippage guard.
- **`SellModule` (8-B9)** — `sellHydx` HYDX → USDC, to repay the 8-B5 borrow.

## The structural coupling (the point)
The 8-B5 strike borrow and the warehouse `REDEEM` draw on the **same reservoir**, and they interact through
utilization:
- A harvest borrow **raises `U`** (consumes free cash) → **raises the freeze floor** (`requiredFraction = U`) →
  **shrinks what's redeemable**, in real time.
- So exit liquidity and harvest working capital don't just share a static pool — **the harvest loop's borrowing
  dynamically tightens the exit window.**
- The LP is **unstaked transiently mid-harvest** (as 8-B5 collateral), which intersects the `DurationFreezeModule`
  staked-LP problem (the freeze can only move unstaked LP; see below).
- Net: the genuinely exit-available USDC at any moment ≈ `free reservoir − harvest working-capital reserve`, and
  the protocol's CoW bid is the throttle that offers exactly that slice. There is **no on-chain reservation** of
  this split — it is CRE policy each cycle.

## The exchange view — a two-sided NAV book (the frontend concept)
The protocol is **already a two-sided market maker**, just split across two venues with a structural spread. The UI
unifies them into one order-book view.

| Side | Action | Price | Venue | Depth |
|---|---|---|---|---|
| **Ask** (buy szipUSD / enter) | Gate `depositFor`/zap (primary mint) | `navEntry = max(spot, twap)` | ExitGate | Deep — up to `tvlCap − grossBasketValue` |
| **Bid** (sell szipUSD / exit) | buy-and-burn (`postBid`) | `navExit × (1−d) = min(spot,twap)×(1−d)` | CoW | Shallow — spare reservoir, utilization-gated |

The **spread is by design**: enter at `max(spot,twap)`, exit at `min(spot,twap)×(1−d)`. The max/min TWAP bracket +
haircut `d` *is* the protocol's bid-ask; the gap accrues to stayers. Two facts to honor in the UI:
- **CoW is a batch auction, not a CLOB.** The "book" is a UI **aggregation over open CoW orders** (CoW Orderbook
  API). Render it like a depth chart, but fills are solver-matched in batches — not price-time-priority/FIFO.
- **The protocol is bid-only on CoW.** It buys to **burn**, never resells (issuance is Gate-only, to hold the
  paired-mint invariant). So on CoW: the **bid** side = protocol anchor + external bidders; the **ask** side =
  exiters posting SELL szipUSD. Entry stays at the Gate.
- **Axis = % of NAV**, not absolute dollars (szipUSD is NAV-priced, not $1 — that's zipUSD). Top of book =
  `navExit` (100% of NAV); bids fan out below. Y = cumulative USDC depth.

## Making it buildable — concrete spec
**Data sources (all read-only, exist today):**
- NAV reference → `SzipNavOracle.navExit()` / `spotNavPerShare()` / `twapNavPerShare()` / `navEntry()`.
- Protocol bid (price + size) → `SzipBuyBurnModule.quoteMaxPrice()`, `currentBid()` (uid + `currentSellAmount`),
  `buybackCap()`, `dBps()`.
- Underlying liquidity / utilization → `EulerEarn.maxWithdraw(warehouse)` vs `convertToAssets(balanceOf(warehouse))`
  (same read as `DurationFreezeModule.utilization`).
- External orders (both sides) → the **CoW Protocol Orderbook API** (off-chain REST), szipUSD/USDC pair.
- Gate ask depth → `tvlCap − grossBasketValue`.

**Components:**
1. **Depth chart** — two-sided, x = % of NAV, y = cumulative USDC. NAV line at top; protocol bid block at the
   haircut; external orders fanned around it.
2. **Liquidity gauge** — free reservoir, harvest reserve, utilization. *Explains* the protocol bid's depth and
   visibly tightens as utilization rises.
3. **Exit action** — post a CoW SELL szipUSD order (wallet-signed via the CoW SDK): "sell to floor" (price at the
   protocol bid) or a custom limit (rests until an external bid fills it).
4. **Entry action** — reuse the existing Gate deposit/zap flow (already in the FE).

**Keep it simple (MVP):**
- Ship a **read-only depth chart first**: NAV line + the single protocol bid block + the external CoW book. No
  protocol laddering, **no new contract**.
- One **Exit** button → post a CoW sell order at/above the protocol floor. Entry reuses the existing Gate flow.
- Phase 2: arbitrary limit orders + protocol-laddered depth (the latter needs the single-resting-bid invariant
  relaxed — see Open items).
- Built in the `frontend/zipcode-finance-euler` layer over `euler-lite`; CoW SDK for order signing; same address/ABI
  books the FE track already uses (`build/anvil/contract-map.md` + `build/anvil/abi/`).

## Automating the protocol bid (a CRE control loop — no new contract)
The buy-burn module already exposes `postBid`/`cancelBid`/`quoteMaxPrice`/`currentBid`. A CRE workflow maintains the
resting bid sized to available capital:
- **Target size** = `clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)`.
- **Price** = `navExit × (1−d)` off a fresh oracle.
- **Single-resting-bid** ⇒ on meaningful drift (size or price past a threshold), `cancelBid` then `postBid` anew.
- **Triggers** — the `RedemptionSettled` event (already wired to sequence REDEEM→REPAY), a utilization change, a NAV
  move, or a fill (`currentSellAmount` drops).
- **Effect:** bid depth tracks utilization **automatically** — a harvest borrow raises `U` → shrinks the free
  reservoir → the CRE shrinks the bid → the depth chart's protocol block visibly contracts. This is CRE policy on
  the existing surface; buildable now.

## Stinkbids — external exit liquidity (the relief valve)
External parties post low BUY szipUSD orders **below the protocol floor** (e.g. 90% of NAV) — "stinkbids." When the
protocol bid is exhausted (high `U`, no spare capital — *exactly when the protocol can't fund exits*), an impatient
seller hits a stinkbid, eating the discount. The stinkbidder captures discount-to-NAV as equity (paid 90%, holds a
share worth NAV — realized via later NAV accretion or reselling into the protocol bid).
- **Healthy by design:** offloads liquidity provision to mercenary capital precisely when the protocol can't fund
  it; impatience is always priced; the book deepens permissionlessly below the floor with no protocol capital.
- **The knob is `d`:** the haircut sets where the protocol floor sits, hence how much exit-discount accrues to
  **stayers** (protocol buys + burns) vs **mercenaries** (stinkbids fill the gap). Small `d` → the protocol outbids
  stinkbidders, bears all the liquidity cost, stayers capture the discount. Large `d` → stinkbidders fill the gap,
  capture the equity, the protocol conserves capital. `d` tunes that split — a governance lever.
- **The UI enables the market** by surfacing the external book: sellers see every bid (protocol + stinks);
  stinkbidders see live exit demand and size their bids to it.

## Open items this map touches (see `build/tickets/PROGRESS.md`)
- **`DurationFreezeModule` incomplete** — premise (defend committed equity from a ragequit drain) is obviated by
  Loot-in-Gate + CoW-only exits, and it can't act on the staked LP that is most of TVL. `build/wires/DurationFreezeModule.md`.
- **`ZipRedemptionQueue` pro-rata machinery dormant** under single-requester — candidate to collapse, or keep as
  optionality for a future open queue.
- **Exit-funding vs. harvest working-capital split is unencoded CRE discretion** — the open design question is
  whether (and how) to size the CoW bid against the utilization/harvest contention, or to make any of it explicit
  on-chain.
- **NEW buildable item — the NAV exit book page + the bid-automation CRE loop.** A frontend page (the two-sided
  depth chart + liquidity gauge + one-click exit, MVP read-only) and a CRE workflow that auto-sizes the resting
  buy-burn bid to `clamp(freeReservoir − harvestReserve, 0, buybackCap)`. Both buildable on the existing contract
  surface (no new contract); the CRE loop is a natural CRE-track ticket. Protocol-laddered depth (multiple bid
  tiers the protocol controls) is the one piece that needs a contract change — relax `SzipBuyBurnModule`'s
  single-resting-bid invariant or run staggered modules.
