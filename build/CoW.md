# CoW.md — driver: paste this to a fresh session to ticket + build the szipUSD CoW-exit workstream

> Copy everything below the line into a new Claude Code session in `/Users/root1/zipcode-euler`.
> It is self-contained: the agent reads the cited docs + the contracts itself. Its job is to take the
> **CoW-exit design (work-in-progress)** the rest of a clean codebase to **built status** — author the FE + CRE
> tickets it implies, run each through the harness, and STOP for review one item at a time.

---

You are picking up the **szipUSD CoW-exit workstream** on **zipcode-euler** (a decentralized home-equity credit
protocol on Base). The **on-chain exit MECHANISM is already built and fork-tested** — what remains is the two
off-chain/UI layers that drive it: a **CRE control loop** that sizes the protocol's resting buy-burn bid, and a
**frontend exit-book page**. Your job: author + build these through the adversarial harness, one item per window,
then conclude on disk and STOP.

## 0. Orient (read these first, in order)
1. **`build/harness.md`** — THE build loop you run (draft ticket → fan critic subagents → triage → cold-build to
   zero guesses → conclude). Follow it exactly. Per-track gates + ticket fields are there.
2. **`build/CoW-exit.md`** — the **design source** for this whole workstream: how a holder exits (CoW sell →
   treasury buy-burn → `burnFor`), where the USDC comes from (warehouse `REDEEM`→`REPAY`→`ZipRedemptionQueue`),
   the **two-sided NAV book** UI concept, the **bid-automation loop** (`clamp(freeReservoir − harvestReserve, 0,
   buybackCap)`), the **stinkbid / `d`-knob** relief-valve mechanics, and the exit-vs-harvest reservoir contention.
   **This is the spec for the work; consume it, then it can be retired** (see §5).
3. **`build/claude-zipcode.md`** §6.2 / §6.4 (junior exit) · §7 (`SzipNavOracle` pricing) · §8.7 (engine operator
   path) · §12 (dashboard metrics) — the **intent**. The contract rules the interface; the spec rules intent.
4. **`build/tickets/PROGRESS.md`** — the live tracker. The CoW-exit work is already scoped there as **CRE-05**
   (the buy-burn bid-automation loop) and **CRE-06** (the cross-cutting exit-vs-harvest capital split), and the FE
   track is COMPLETE through FE-07 (the withdraw spine `ZcWithdrawModal`/`useCowExit` shipped in FE-04 — the
   **depth-chart exit-book page is net-new** on top of it). Set the `NEXT` here as you go.

## 1. What is ALREADY BUILT (bind to it — do NOT rebuild)
Verified live in `contracts/src/`:
- **`SzipBuyBurnModule`** (8-B14): `postBid` / `cancelBid` (single resting CoW BUY-szipUSD order, `≤ navExit×(1−dBps)`,
  PRESIGN), `currentBid()` → (uid, `currentSellAmount`), `quoteMaxPrice()`, `buybackCap()`/`dBps()` views, the
  `covered()` outflow gate. Wire: `build/wires/8-B14-SzipBuyBurnModule.md`.
- **`OffRampModule`** (`requestRedeem`/`claim`, CRE-operator-gated, execs through the rq Safe) +
  **`ZipRedemptionQueue`** (`settleEpoch` on-demand, `claim` at par, emits `RedemptionSettled`; single-requester).
  Wires: `OffRampModule.md`, `9-ZipRedemptionQueue.md`.
- **`WarehouseAdminModule`** (8-Bw): `REDEEM`/`REPAY`, Roles-scoped, `repaySink` pinned to the queue. Wire:
  `8-Bw-CreditWarehouse.md`.
- **`ExitGate.burnFor`** (`windowController`-gated, NAV-accretive burn) + **`SzipUSD`** (no redemption fn).
- **`SzipNavOracle`**: `navExit`/`navEntry`/`spotNavPerShare`/`twapNavPerShare`; `DurationFreezeModule.utilization()`
  (= `EulerEarn.maxWithdraw(warehouse)` vs `convertToAssets(balanceOf(warehouse))`).
- The harvest-loop contracts (`ReservoirLoopModule`/`ExerciseModule`/`SellModule`) that contend for the same USDC.

## 2. What to BUILD (the tickets to author — one per window, harness loop each)
1. **CRE — buy-burn bid-automation loop** (PROGRESS CRE-05's exit half). A Go→wasip1 CRE workflow that maintains the
   single resting bid: **target size** `clamp(freeReservoir − harvestReserve − safetyBuffer, 0, buybackCap)`,
   **price** `navExit × (1−d)` off a fresh oracle, **single-resting-bid** ⇒ `cancelBid`→`postBid` on meaningful
   drift, **triggers** = `RedemptionSettled` / utilization move / NAV move / fill. Binds to the BuyBurn views +
   `EulerEarn` reads above. Gate: `go build` wasip1 + the §8.0 report/encode test + simulated run (per harness CRE gate).
2. **CRE — exit-vs-harvest capital split** (CRE-06, cross-cutting). The policy that arbitrates the one reservoir
   between the CoW exit bid (REDEEM→REPAY→CoW) and the 8-B5 strike borrow. Currently unencoded CRE discretion —
   scope it explicitly (it co-moves with CRE-02/04/05). May be folded into #1's sizing rather than a standalone
   workflow — decide at triage.
3. **FE — NAV exit-book page** (net-new on the shipped withdraw spine). The two-sided depth chart (x = % of NAV,
   y = cumulative USDC), liquidity gauge (free reservoir / harvest reserve / utilization), and one-click CoW exit.
   **MVP = read-only depth chart first** (NAV line + protocol bid block + external CoW book via the CoW Orderbook
   API), then the exit action (CoW SDK, wallet-signed SELL). Built in the `frontend/zipcode-finance-euler` LAYER;
   reuse the existing `useZipTx` 1.3× gas-buffer helper + the anvil address/ABI books. Gate: `nuxt build` green in
   the layer (NOT `npm run dev`), anvil up.

## 3. Sequence + ticketing
Work them **one at a time**, harness loop each (draft → critics → triage → cold-build → conclude → STOP). File CRE
tickets under `build/tickets/cre/`, FE tickets under `build/tickets/frontend/`. Suggested order: the **CRE
bid-loop (#1)** first (it is the protocol's side and the FE page reads its `currentBid`), then the **FE page (#3)**,
then fold **#2** into the CRE policy. Update PROGRESS (`NEXT`, the CRE/FE backlog rows) as each lands.

## 4. Guardrails (do NOT reopen — `claude-zipcode.md` §17 + the as-built reality)
- **No new contract.** Everything binds to the existing surface (`postBid`/`cancelBid`/`currentBid`/`quoteMaxPrice`).
  Protocol-**laddered** depth (multiple protocol bid tiers) is the ONE thing that would need a contract change
  (relax the single-resting-bid invariant or run staggered modules) — **defer it**, MVP is one protocol bid + the
  external book.
- **szipUSD is NAV-priced, not $1** — the exit book's axis is **% of NAV** (`navExit` = 100%), never absolute $.
- **The protocol is bid-only on CoW** (buys to burn, never resells; entry is Gate-only). Ask side on CoW = exiters'
  SELL orders; entry stays at the Gate.
- **CoW is a batch auction, not a CLOB** — the "book" is a UI aggregation over open CoW orders, not price-time FIFO.
- A binding to a contract surface that doesn't exist is **back-pressure** — log it as an obligation in PROGRESS, do
  not invent around it.

## 5. Endgame — consolidate, then retire this driver + CoW-exit.md
The point of this driver is to move `CoW-exit.md` (a WIP design note) to **built status**. Once the CRE bid-loop +
the FE exit-book page have landed (code committed, gates green, PROGRESS updated, the per-contract behavior in
`build/wires/`), **`build/CoW-exit.md` and this `build/CoW.md` are spent** and should be deleted — the durable
record is then the built code + the wires + PROGRESS, same as every other completed track. Until then, `CoW-exit.md`
stays as the design source you read in §0.
