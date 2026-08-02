# cre/szalpha-rate — the xALPHA exchange-rate cross-chain pull (8x-02)

The CRE workflow that **pulls `SzAlpha.exchangeRate()` from Subtensor (964) and pushes the raw rate to
`SzAlphaRateOracle` on Base** on an hourly cron. It transports the one fact that lives only on Bittensor —
the exchange rate — and nothing else.

## The shape (and why)

```
Bittensor 964:  SzAlpha.exchangeRate()  =  staked alpha / supply   (StakingV2 0x805)
      │  CRE cron pull (this workflow) — the ONLY thing that crosses the chain boundary
      ▼
Base 8453:      SzAlphaRateOracle  (push-cache, IXAlphaRate)  — exchangeRate() / fresh() / lastUpdate()
      │  on-chain reads (no bridge)
      ├─►  SzipNavOracle xALPHA NAV leg   (reads exchangeRate(), gates on fresh())
      ├─►  Euler price-oracle adapter      (NAV / quote)
      └─►  SzAlphaRateOracle.intrinsicAprBps()  — APR DERIVED on-chain from the rate history
```

- **CRE transports the PRIMITIVE (the rate), the chain DERIVES the rest.** NAV and APR are computed on Base
  from the pushed rate — never pushed pre-computed.
- The rate is **ground truth from 964**, so the receiver has **no deviation band** (a validator slash
  legitimately lowers it). The receiver enforces only non-zero / not-future / strictly-newer; consumers
  fail-closed on **staleness** (`fresh()`).
- **S14 (the rule this job exists to honor): a REVERTING `exchangeRate()` read means NO PUSH — never
  "push 0".** `SzAlpha` reverts `BackingVanished` on hotkey drift (the Rubicon state); the revert must
  propagate as SILENCE on Base so the feed goes stale and every consumer fails closed. The handler maps a
  read error to a loud errored run and never reaches the encode path. Pinned by
  `TestSimRevertingReadNoPush`; recorded as seam S14 in `docs/wires/SYSTEM-SEAM-MAP.md`.

## Status (2026-08-02)

- **On-chain `SzAlphaRateOracle`: DONE + forge-green** — `contracts/src/bridge/SzAlphaRateOracle.sol` +
  `contracts/test/bridge/SzAlphaRateOracle.t.sol`. Deployed nowhere yet (deploy is gated on the go-live
  decision).
- **This workflow: BUILT + host-tested (6/6) + wasip1-builds.** `workflow.go` (untagged logic) +
  `workflow_test.go` (sim harness on the sharefeeds model: two chain mocks, capture-and-decode handshake,
  the S14 revert pin, zero-rate / unset-wiring no-ops, schedule pin). Encoding via the shared
  `cre/zipreport` library (`zipreport.Rate`) — this slice does not re-implement the handshake.
- Timestamps are stamped **DON-side** (`runtime.Now()`), never the 964 block time — the receiver judges
  `ts` against Base time, so a remote stamp would import 964's clock skew (and a ms-vs-s producer bug must
  fail loudly on the first push, not poison the strictly-newer cursor).

## Open residuals (pre-deploy)

- **R-1 — the 964 read is unproven against the live chain.** `exchangeRate()` staticcalls the `0x805`
  precompile inside the node's `eth_call`. Expected to work (it is an ordinary `eth_call` to the DON's RPC),
  but prove it in a staging run before relying on it. Both chain selectors are config-driven, so the job can
  rehearse single-chain by pointing `subtensorChainSelector` at Base and `szAlpha` at the 18-dp xALPHA
  stand-in (same `IXAlphaRate` surface).
- **R-2 — consumer gate.** `SzipNavOracle` must gate its xALPHA rate read on `fresh()` when it is wired to
  this oracle; a stale rate mis-marks a fund-moving NAV. (Freshness is separate from the value guard on the
  rate leg, which is the one-directional TWAP ratified 2026-08-02.)
- **Cadence ↔ staleness coupling.** `defaultSchedule` is hourly; the receiver's `maxStaleness` is a
  deploy-time immutable. Choose them together (staleness ≈ 6× cadence gives ~6 missed pushes of slack
  before consumers fail closed).

## Deploy wiring (when go-live is called)

Deploy `SzAlphaRateOracle` on **Base** (forwarder = the CRE Forwarder; `maxStaleness`/`window`/`aprCap`
chosen against the cadence above). Run this workflow on the CRE DON with config: `subtensorChainSelector`
(964 = `2135107236357186872`), `szAlpha` (the production proxy), `baseChainSelector`, `szAlphaRateOracle`.
Then point `SzipNavOracle`'s xALPHA **rate** read at this oracle behind its `fresh()` gate (the token
address stays the mirror for balances).
