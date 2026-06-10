# cre/szalpha-rate — the xALPHA exchange-rate cross-chain pull (8x-02)

The CRE workflow that **pulls `SzAlpha.exchangeRate()` from Subtensor (964) and pushes the raw rate to
`SzAlphaRateOracle` on Base** every ~minute. It transports the one fact that lives only on Bittensor — the
exchange rate — and nothing else.

## The shape (and why)

```
Bittensor 964:  SzAlpha.exchangeRate()  =  staked alpha / supply   (StakingV2 0x805)
      │  CRE cron pull (this workflow) — the ONLY thing that crosses the chain boundary
      ▼
Base 8453:      SzAlphaRateOracle  (push-cache, IXAlphaRate)  — exchangeRate() / fresh() / lastUpdate()
      │  on-chain reads (no bridge)
      ├─►  SzipNavOracle xALPHA NAV leg   (reads exchangeRate(), gates on fresh())
      ├─►  Euler price-oracle adapter      (NAV / quote)
      └─►  SzAlphaRateOracle.intrinsicAprBps()  — APR DERIVED on-chain from the rate history (UI / 8-B12 / 8-B11)
```

- **CRE transports the PRIMITIVE (the rate), the chain DERIVES the rest.** NAV and APR are computed on Base from
  the pushed rate — never pushed pre-computed. This is the whole correction over the first draft (which pushed a
  finished APR + defended it with adversarial bands).
- The rate is **ground truth from 964**, so the receiver has **no deviation band** (a validator slash legitimately
  lowers it). The receiver enforces only non-zero / not-future / strictly-newer; consumers fail-closed on
  **staleness** (`fresh()`).

## Status / build boundary

- **On-chain `SzAlphaRateOracle`: DONE + forge-green** — `contracts/src/bridge/SzAlphaRateOracle.sol` +
  `contracts/test/bridge/SzAlphaRateOracle.t.sol` (17/17). The verifiable, kept artifact.
- **This workflow (`main.go`): the CRE-03 integration artifact — not compiled in the Foundry repo** (no Go
  toolchain there). Pinned EXACT: the payload `abi.encode(uint256 rate, uint48 ts)` + the `uint8 RATE=8` envelope
  (byte-matching the receiver).
- Until 8x-01's lane is live, point the 964 read at the 18-dp xALPHA **stand-in** (same `IXAlphaRate` surface).

## Open risks (tracked in the ticket, NOT buried here)

The full table is in `tickets/bridge/8x-02-xalpha-apr-cre.md` → "OPEN / BLOCKING RISKS". The two that matter:
- **R-1 (BLOCKING):** can CRE even read 964? `exchangeRate()` staticcalls the `0x805` precompile — the "8x
  exception" says a typed precompile call may never reach the runtime. **Prove it before building on this read.**
- **R-2 (HIGH, fund-safety):** `SzipNavOracle` reads the rate with no `fresh()` gate today — wiring it to this
  pushed oracle without that gate lets a stale rate mis-mark a fund-moving NAV.
- R-4 (wiring): go.mod, 964/8453 selectors + RPC, config unmarshal, the exact `exchangeRate()` read.

## Item-10 wiring

Deploy `SzAlphaRateOracle` on **Base** (forwarder = the CRE Forwarder; `maxStaleness`/`window`/`aprCap` under the
Timelock). Run this workflow on the CRE DON. Point `SzipNavOracle`'s xALPHA **rate** read at this oracle (its NAV
xALPHA leg currently reads `IXAlphaRate(xAlpha)` directly — in production that rate source is `SzAlphaRateOracle`;
the token address stays the mirror for balances). That split is the resolution of the §8.6 cross-chain rate seam.
