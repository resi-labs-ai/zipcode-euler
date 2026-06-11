# SP-08 — Revaluation batch → registry

**Intent.** Drive the CRE revaluation rail: push a batch of per-lien prices into the shared oracle registry and read
them back through the EVK price interface, including the staleness window.

**Proves.** `ZipcodeOracleRegistry.onReport` reportType 3 `(liens[], prices[], ts)`; the forwarder gate; the
all-or-nothing batch; `getQuote` staleness window + unit-of-account (USDC) checks.

**Tier.** Needs-forwarder (+ identity match: the registry seals author/workflowId).

**Binds to.** `ZipcodeOracleRegistry` `0x0395da1B…`, Forwarder `0xF834…4482`, USDC. Source:
`contracts/src/ZipcodeOracleRegistry.sol` (`_processReport` reval L114-124, `seedPrice` L106-110, `getQuote` via
BaseAdapter), wires `WOOF-02.md`.

**Setup.**
- A lien token to key on. Either run SP-14 (origination mints a real lien) or `seedPrice` via the controller, or push
  a revaluation directly for a chosen lien address (must have `decimals()==18`).
- Construct the report: `abi.encode(uint8(3), abi.encode(address[] liens, uint256[] prices, uint32 ts))`. Verify the
  exact field order against `ZipcodeOracleRegistry._processReport`.

**Calls.**
1. Impersonate Forwarder → `ZipcodeOracleRegistry.onReport(metadata, report)` with `ts == now`.
2. `getQuote(1e18, lien, USDC)` read → returns the pushed price scaled.
3. `evm_increaseTime(validityWindow+1)`; `getQuote(...)` → expect revert (too stale).
4. (negative) push with a 6-dp or EOA lien key → revert (strict 18-dp).
5. (negative) push from a non-forwarder → revert.

**Assertions.**
- after 1: `getQuote` returns the expected scaled outAmount; cache timestamp == ts.
- 3/4/5 revert as named; a batch with one bad entry reverts wholesale (no partial writes).

**Notes.** This is the price rail origination (SP-14) and liquidation gating ride on. Identity metadata must match the
sealed `workflowAuthor`/`workflowId` (or re-point via the Timelock).

**Result.** **PASS** (2026-06-10, real txs on anvil). The CRE revaluation rail works end-to-end with strict fail-closed guards.

Setup: used two existing 18-dp tokens as lien keys (the registry only requires `decimals()==18`, not a real lien): zipUSD `0xC5bd…` and xAlpha mirror `0xF6CA…`. `quote` = USDC, `validityWindow` = **31,536,000s (365 days)**, sealed id `0x…01` / author `0x90F7…`. Metadata = the proven 62-byte `abi.encodePacked(id, name(10), owner)`.

Calls & deltas:
1. Forwarder `onReport` reportType 3, payload `abi.encode([zipUSD,xAlpha], [1000e6,2000e6], ts)` → status 1.
2. `getQuote` read-back: `(1e18 zipUSD→USDC)` = **1000e6**, `(5e17 zipUSD)` = **500e6** (scales proportionally, 18-dp base → 6-dp quote), `(1e18 xAlpha)` = **2000e6**. `cache(zipUSD).timestamp == ts`. ✓
3. (staleness, under `evm_snapshot`/`evm_revert`) warped +366 days → `getQuote(zipUSD)` reverts **`PriceOracle_TooStale(31622302, 31536000)`** (`0xa6e68d63`). Snapshot reverted → block ts restored, mark fresh again (no contamination of later paths). ✓
4a. (all-or-nothing) batch `[zipUSD=9999e6, USDC=1]` → reverts **`InvalidLienDecimals(USDC)`** (`0x04498422`); zipUSD's mark stays **1000e6** — **no partial write**. ✓
4b/4c. (strict 18-dp) batch `[USDC(6dp)]` → `InvalidLienDecimals(USDC)`; batch `[0x…dEaD no-code EOA]` → `InvalidLienDecimals(0xdEaD)` (strict `decimals()` staticcall, not silent-18). ✓
5. (non-forwarder) alice `onReport` → **`InvalidSender(alice, forwarder)`** (`0xe1130dba`). ✓

No flaws — clean. The price rail that origination (SP-14) and liquidation gating depend on is verified: scaled reads, batch atomicity, decimals strictness, the forwarder + identity gate, and the staleness window all hold.
