# SP-08 — Revaluation batch → registry (the lien price rail)

**Intent.** Drive the CRE revaluation rail: push a batch of per-lien prices into the shared oracle registry and read
them back through the EVK `getQuote` interface, including the staleness window and the strict guards.

**Proves.** `ZipcodeOracleRegistry.onReport` reportType 3 `(liens[], prices[], ts)`; the forwarder + identity gate;
all-or-nothing batch atomicity; strict-18-dp lien keys; the **StaleReport** backdated-replay guard; `getQuote`
staleness + unit-of-account (USDC). Sources: `docs/ZipcodeOracleRegistry.md`, `contracts/src/x-ray/ZipcodeOracleRegistry.md`,
wires `WOOF-02.md`.

**Tier.** Needs-forwarder (+ identity match — the registry seals author/workflowId).

**Binds to** (by name): `ZipcodeOracleRegistry`, CRE Forwarder, USDC; two existing 18-dp tokens as lien keys
(zipUSD, xALPHA mirror — the registry only requires `decimals()==18`, not a real lien).

**Setup.** Report = `abi.encode(uint8(3), abi.encode(address[] liens, uint256[] prices, uint32 ts))`.

**Calls (happy).** 1. push `[zipUSD, xALPHA]` prices `[1000e6, 2000e6]` ts=now. 2. `getQuote(1e18/5e17, zipUSD/xALPHA, USDC)`.

**Calls (fuzzy / negative).** 3. batch `[zipUSD=9999e6, USDC(6dp)]` → `InvalidLienDecimals(USDC)`, no partial write.
4. re-push zipUSD with a **backdated** ts → `StaleReport` (no overwrite). 5. push from a non-forwarder → `InvalidSender`.
6. (window) warp > validityWindow → `getQuote` reverts `PriceOracle_TooStale`.

**Assertions** (On-chain=Yes): readbacks scale (18-dp base → 6-dp quote): 1e18→1000e6, 5e17→500e6, xALPHA 1e18→2000e6;
batch-with-bad-entry leaves the prior mark intact; backdated replay rejected; non-forwarder rejected.

**Notes.** This is the price rail origination (SP-14) and liquidation gating ride on. `validityWindow` = 365 days.

**Result.** **PASS** (2026-06-24, live fork; registry `0xbF1801C7…`).
- Push reportType-3 `[zipUSD=1000e6, xALPHA=2000e6]` → ok. Readback: `1e18 zipUSD`→**1000e6**, `5e17 zipUSD`→**500e6**,
  `1e18 xALPHA`→**2000e6** (proportional, 18→6 dp). ✓
- **(neg) all-or-nothing + strict-18dp:** batch `[zipUSD=9999e6, USDC]` left zipUSD's mark at **1000e6** (no partial
  write; `InvalidLienDecimals(USDC)`). ✓
- **(neg) StaleReport:** backdated re-push of zipUSD left the mark at **1000e6** (rejected the replay). ✓
- **(neg) non-forwarder:** alice's `onReport` did not write (`InvalidSender`). ✓
- Staleness window + `PriceOracle_TooStale` proven 2026-06-10 (needs a 365-day warp). **No flaws** — the strict-18dp +
  StaleReport ADV guards hold.
