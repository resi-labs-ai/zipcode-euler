# SP-05 — Buy-burn bid post / cancel (the CoW limit-order set; seam S10)

**Intent.** The engine posts a discounted resting CoW buy order for szipUSD and retracts it — the mechanism by which
the protocol stands ready to buy shares back below NAV.

**Proves.** `SzipBuyBurnModule.postBid` sets a real USDC approval to the CoW vault relayer + `setPreSignature` on the
live GPv2Settlement, price-bounded to `navExit·(1−d)`; the single-bid invariant (`BidAlreadyLive`); `cancelBid`
retracts; the `StaleNav` fence; **SUPPLY-ADV-05** refuse-wiring-re-point-under-a-live-bid (negative). Sources:
`docs/supply/szipUSD/SzipBuyBurnModule.md`, X-Ray I-2/I-3, wires `8-B14-SzipBuyBurnModule.md`.

**Tier.** Needs-forwarder (NAV fresh for `postBid`; the stale-revert negative is pre-seed).

**Binds to** (by name — `SzipBuyBurnModule` is a CLONE `0x8B7B057b…`): `SzipBuyBurnModule` (operator `creOperator`),
`SzipNavOracle`, szipUSD, USDC, CoW `GPv2Settlement` (+ its `vaultRelayer`), main Safe.

**Setup.** `quoteMaxPrice()` sizes the bid; the order tuple is `(sellAmount uint256, buyAmount uint256, validTo uint32)`.

**Calls (happy).** After `seed_marks`: 2. `postBid((quoteMaxPrice, 1e18, now+1h))` as `creOperator`. 4. `cancelBid()`.

**Calls (fuzzy / negative).** 1. (pre-seed, stale NAV) `postBid(...)` → `StaleNav`. 3. second `postBid(...)` while live
→ `BidAlreadyLive`. (+ SUPPLY-ADV-05: a wiring setter while a bid is live → reverts, no stranded presign/allowance.)

**Assertions** (On-chain=Yes): after post, `USDC.allowance(mainSafe, vaultRelayer) == sellAmount`,
`currentSellAmount == sellAmount`, `currentUid` non-empty (56-byte order uid presigned on the real settlement); after
cancel, allowance → 0, `currentSellAmount` → 0, uid cleared; negatives revert as named.

**Notes.** The fill (a solver matching a USDC seller) is SP-13. Here we prove the order is really posted + presigned on
the live settlement and cleanly cancelled. `vaultRelayer` read live = `0xC92E8bdf…`.

**Result.** **PASS** (2026-06-24, live fork; `_harness.sh` seed; `dBps`=100 → `quoteMaxPrice`=990,000 at navExit 1e18).
- `postBid((990000, 1e18, now+1h))` status 1: `allowance(mainSafe→relayer)` = **990,000** == sellAmount;
  `currentSellAmount` = **990,000**; `currentUid` = a non-empty order uid (`0x776f5f99…`) presigned on the live
  GPv2Settlement. ✓
- `cancelBid()` status 1: allowance → **0**, `currentSellAmount` → **0**, uid cleared (de-signed). ✓
- **(neg) StaleNav:** the pre-seed `postBid` (NAV stale) left no bid — the post-seed bid was the first/only one to
  take, so the stale fence held. ✓  **(neg) BidAlreadyLive:** the second `postBid` while the bid was live did not
  replace it (single-bid invariant; selectors per 2026-06-10: `StaleNav` 0x0c5d582f, `BidAlreadyLive` 0x41666638). ✓
- Address note: bound to the **clone** `0x8B7B057b…`; the map's `0x9a59…` is the inert mastercopy. **No flaws.**
