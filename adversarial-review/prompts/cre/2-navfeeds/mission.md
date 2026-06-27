CLUSTER 2 — NAV / share-price feeds

Read `../_boot.md` first (persona + the A–E output schema). Map the push-cache oracle feeds that
price szipUSD issuance/exit and the farm-utility borrow gate.

## Workflows you own
- `cre/sharefeeds/` (CRE-03) — composes the NAV alpha leg + LP mark; emits TWO reportType-7 reports
  (NAV_LEG → `SzipNavOracle`, LP_MARK → `SzipFarmUtilityLpOracle`). Note the §8.6 coherence rule
  (same band-clamped alphaUSD prices both legs) and the as-built vs spec difference on HYDX
  (pushed unconditionally vs "only if thin").
- `cre/szalpha-rate/` (8x-02) — the **rate source** into `SzAlphaRateOracle` (reportType 8 RATE).
  Map it as a NAV-input here; the bridge/transport side belongs to cluster 6 (note the crossing).

## On-chain seams to classify (C section)
`SzipNavOracle` (report-socket, rt 7 leg marks; also the protocol's sole price oracle via
`IPriceOracle`/`BaseAdapter`), `SzipFarmUtilityLpOracle` (report-socket, rt 7 LP_MARK; stale ⇒
borrow fails closed), `SzAlphaRateOracle` (report-socket, rt 8 RATE), `AlgebraIchiFairLpOracle`
(the trustless fair-LP alternative — is it CRE-fed or fully on-chain? classify precisely).

## Gap focus (D section)
- The **xALPHA rate push** is DEFERRED/blocked (needs mainnet xALPHA + proven 964 read) — flag what
  unblocks it and what the NAV stands in with meanwhile.
- The **xALPHA APR** (§8.8) is derived on-chain, NOT a separate producer — confirm and record so it
  isn't mistaken for an owed workflow.
- Is the on-chain HYDX TWAP read deferred (contract has none)? Record the as-built truth.

## Read-set
Workflows: `cre/sharefeeds/{workflow.go,main.go}`, `cre/szalpha-rate/{README.md,main.go}`,
`cre/zipreport/README.md` (rt7 NAV_LEG + LP_MARK payloads).
Contracts: `contracts/src/supply/SzipNavOracle.sol`, `contracts/src/supply/SzipFarmUtilityLpOracle.sol`,
`contracts/src/bridge/SzAlphaRateOracle.sol`, `contracts/src/supply/AlgebraIchiFairLpOracle.sol`.
Wires: `docs/wires/8-B4-SzipNavOracle.md`, `docs/wires/8-B5-FarmUtilityLoop.md`,
`docs/wires/8x-02-SzAlphaRateOracle.md`, `docs/wires/FairLpOracle.md`.
Spec: `build/claude-zipcode.md §8.6` (share-price feeds), `§8.8` (xALPHA rate + derived APR).
