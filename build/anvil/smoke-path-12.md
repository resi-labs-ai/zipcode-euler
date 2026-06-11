# SP-12 — xALPHA rate push (bridge oracle)

**Intent.** Push the cross-chain xALPHA exchange rate into the Base-side rate oracle and show the NAV oracle's xALPHA
leg consumes it with a freshness gate.

**Proves.** `SzAlphaRateOracle.onReport` (rate, ts) with strict-newer/no-replay; `exchangeRate()`/`lastUpdate()`/
`fresh()`; staleness flips `fresh()`; the NAV oracle's xALPHA valuation reads through it when wired.

**Tier.** Needs-forwarder (+ identity for the rate workflow).

**Binds to.** `SzAlphaRateOracle` `0x7251a305…`, `SzipNavOracle` `0x0C3E7731…` (xALPHA leg / `setXAlphaRateOracle`),
xALPHA mirror `0xF6CAAF72…`. Source: `contracts/src/bridge/SzAlphaRateOracle.sol` (`_processReport` L80-103,
`exchangeRate` L109-111, `fresh` L119-121), wires `8x-02-SzAlphaRateOracle.md`.

**Setup.**
- Report: `abi.encode(uint8 reportType, abi.encode(uint256 rate, uint48 ts))`. Verify reportType + field order against
  `SzAlphaRateOracle._processReport` (the agent noted reportType 8; confirm in source).

**Calls (impersonate Forwarder).**
1. `SzAlphaRateOracle.onReport("", report)` with `rate = 1.05e18`, `ts = now`.
2. Reads: `exchangeRate()`, `lastUpdate()`, `fresh()`.
3. `evm_increaseTime(maxStaleness+1)` → `fresh()` flips to false.
4. (negative) push with `ts <= lastUpdate` → revert (no replay).
5. With xALPHA in a Safe basket, read `SzipNavOracle.grossBasketValue()` before/after a rate change to see the xALPHA
   leg move.

**Assertions.**
- after 1: `exchangeRate()==1.05e18`, `lastUpdate()==ts`, `fresh()==true`.
- after 3: `fresh()==false`.
- step 4 reverts; step 5: the xALPHA leg's USD contribution scales with the rate.

**Notes.** xALPHA is a stand-in token, but the rate **oracle + freshness gate + NAV consumption** are real. This is
the bridge seam (8x-02) feeding the junior NAV.

**Result.** **PASS** (2026-06-10, real txs on anvil). The bridge rate oracle ingests the cross-chain rate with strict-newer/no-replay, exposes freshness, and the NAV oracle's xALPHA leg consumes it live. Report = `abi.encode(8, abi.encode(uint256 rate, uint48 ts))` (reportType **8** confirmed in source). maxStaleness = **86,400s (1 day)**. The sidecar's 400e18 xALPHA (from SP-11) made the leg directly observable.

1. Push `rate=1.05e18, ts=now` → `exchangeRate()` = **1.05e18**, `lastUpdate()` = ts, `fresh()` = **true**. `grossBasketValue` = **85,432e18** = 85,012 (USDC) + 400·1.05 = 420 (xALPHA leg). ✓
5. Push `rate=2.0e18, ts=now+1` → `grossBasketValue` = **85,812e18** = 85,012 + 400·2.0 = 800. **The xALPHA leg's USD contribution scaled with the rate** (420 → 800), proving `SzipNavOracle` reads valuation through `SzAlphaRateOracle.exchangeRate()`. ✓
4. (negative) push `ts ≤ lastUpdate` → **`StaleReport` (0xf803a2ca)** — no replay / out-of-order. ✓
3. (staleness, under `evm_snapshot`/`evm_revert`) warp +86,401s → `fresh()` true → **false**; `exchangeRate()` still **2.0e18** (value persists, only freshness flips). Knock-on: `SzipNavOracle.fresh()` → **false** (a stale cross-chain rate **halts issuance** — `navEntry` would `StaleRate`), while **`navExit` still prices off the last rate** (107.265e18) — the §7 asymmetry: staleness pauses minting, never exit. Snapshot reverted → fresh restored, node clean. ✓

No flaws. The bridge seam (8x-02) feeding the junior NAV is real and load-bearing: the rate push guards (non-zero / not-future / strictly-newer, no deviation band by design), the `fresh()`/`lastUpdate()` freshness surface, the NAV leg's live consumption of `exchangeRate()`, and the fail-closed-on-issuance / open-on-exit asymmetry all hold. (Post-run rate = 2.0e18, fresh.)
