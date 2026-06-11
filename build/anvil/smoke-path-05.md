# SP-05 — Buy-burn bid post / cancel (the CoW limit-order set)

**Intent.** Show the engine posting a discounted resting CoW buy order for szipUSD and retracting it — the
mechanism by which the protocol stands ready to buy shares back below NAV.

**Proves.** `SzipBuyBurnModule.postBid` sets a real USDC approval to the CoW vault relayer + `setPreSignature` on the
live GPv2Settlement, price-bounded to `navExit·(1−d)`; the single-bid invariant; `cancelBid` retracts; `StaleNav`
fence.

**Tier.** Needs-forwarder (NAV legs must be fresh for `postBid`; the stale-revert negative is pure on-chain).

**Binds to.** `SzipBuyBurnModule` `0x12881a80…` (operator `creOperator`), `SzipNavOracle` `0x0C3E7731…`,
szipUSD `0x33aD3E23…`, USDC, CoW settlement `0x9008D19f…`. Source:
`contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` (`postBid` L243-286, `cancelBid` L290-307, `quoteMaxPrice`
L347-350, `_orderUid` L316-336), wires `8-B14-SzipBuyBurnModule.md`.

**Setup.**
- Push fresh NAV legs (impersonate Forwarder → `SzipNavOracle.onReport`, reportType 7 legs `(legs[],prices[],ts)`;
  verify the exact encoding against `SzipNavOracle._processReport`). Confirm `SzipNavOracle.fresh() == true`.
- Read `quoteMaxPrice()` to size the bid.

**Calls.**
1. (negative, pre-push) `postBid(order) as creOperator` while stale → revert `StaleNav`.
2. `postBid(order) as creOperator` with `sellAmount ≤ buybackCap`, `validTo ≤ now+1d & ≤ now+maxAge`, price within bound.
3. `currentBid()` read.
4. `cancelBid() as creOperator`.

**Assertions.**
- after 2: `USDC.allowance(mainSafe, COW_vaultRelayer) == sellAmount`; `GPv2Settlement.preSignature(uid) == true`;
  `currentBid()` returns a non-zero uid; a second `postBid` reverts `BidAlreadyLive`.
- after 4: allowance back to 0; `preSignature(uid) == false`; `currentBid()` cleared.

**Notes.** The fill (a solver matching a USDC seller) is simulated in SP-13. Here we only prove the order is really
posted + presigned on the real settlement contract and can be cancelled. `vaultRelayer` is read live in `setUp`.

**Result.** **PASS** (2026-06-10, real txs on anvil). The discounted resting CoW buy order is genuinely posted, presigned on the **live GPv2Settlement**, and cancellable.

Module params read live: operator = `creOperator`, engineSafe = main Safe, dBps = **100 (1%)**, buybackCap effectively unlimited, vaultRelayer `0xC92E8bdf…` (read off settlement in setUp). NAV state at start: **stale** (from SP-10's +30-day warp); navExit = 106e18 (basket is USDC-heavy vs 1000e18 szipUSD supply — a state artifact; mechanics unaffected).

1. (negative, stale) `postBid` while `fresh()==false` → **`StaleNav` (0x0c5d582f)**. ✓ (the resting-bid-must-not-fill-against-stale-NAV fence)
2. Re-pushed xALPHA rate + NAV legs (Forwarder) → `fresh()==true`. `quoteMaxPrice()` = navExit·(10000−dBps)/10000/1e12 = **104,940,000** (USDC-6dp per 1e18 share). `postBid(sellAmount=104,940,000, buyAmount=1e18, validTo=now+1h)` → status 1, 381,987 gas. Sized at the exact `quoteMaxPrice` ceiling, the price bound `sellAmount·1e12·1e4·1e18 ≤ buyAmount·navExit·(1e4−dBps)` passed (no `BidAboveDiscount`). ✓
3. **after postBid:** `currentUid` = a **56-byte** order uid; `currentSellAmount` = 104,940,000; `USDC.allowance(mainSafe, vaultRelayer)` = **104,940,000** (== sellAmount); `GPv2Settlement.preSignature(uid)` = **nonzero `PRE_SIGNED` sentinel** (order genuinely presigned on the real settlement). ✓
4. (negative) second `postBid` → **`BidAlreadyLive` (0x41666638)** — the single-resting-bid invariant. ✓
5. `cancelBid()` as creOperator → status 1. **after cancel:** `allowance(main→relayer)` → **0**; `currentUid` → **0x** (empty); `currentSellAmount` → **0**; `GPv2Settlement.preSignature(uid)` → **0** (de-signed). ✓

No flaws. The buy-and-burn BID side is real: a price-bounded (`≤ navExit·(1−d)`) resting BUY-szipUSD order, presigned on-chain via `setPreSignature` on the live CoW settlement, single-bid-enforced, fenced on NAV staleness, and cleanly retractable. The fill (a solver matching a USDC seller) is SP-13.
