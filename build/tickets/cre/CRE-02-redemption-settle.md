# CRE-02 — Redemption-settle workflow + warehouse REDEEM funding

> Scope authored 2026-06-12. Spec: `claude-zipcode.md` §8.3 / §8.5 (+ §8.0 envelope, §8.7 operator path).
> Contracts (truth): `ZipRedemptionQueue.sol`, `WarehouseAdminModule.sol`, `OffRampModule.sol`; wires:
> `build/wires/9-ZipRedemptionQueue.md`, `8-Bw-CreditWarehouse.md`, `OffRampModule.md`. Builds on CRE-00.

## Purpose
The Go/CRE workflow that runs the senior **par-redemption cycle**: free USDC from EulerEarn, deliver it to the
`ZipRedemptionQueue`, settle (burn zipUSD, reserve USDC at $1 par), and realize it back to the rq Safe basket
(which funds the §6.4 CoW buybacks). **On-demand** — the 30-day epoch gate was removed 2026-06-12, so this is
condition/event-driven, NOT the fixed 30-day `cron` the spec §8.3 still describes (that wording is now stale).

## Two CRE interaction modes (both in this one ticket)
- **Report path** (Forwarder → `WarehouseAdminModule`, §8.5): `REDEEM (uint256 shares)` + `REPAY (address to,
  uint256 amount)`, envelope `abi.encode(uint8 opType, bytes payload)`, a **distinct workflowId** from the
  controller/oracle receivers. Reuses the §8.0 report-encoding package (CRE-00) and the warehouse-op encoding
  shared with CRE-04.
- **Operator path** (direct tx, "NOT a report" — the §8.7 pattern): `ZipRedemptionQueue.settleEpoch()` as the
  queue's `controller`; `OffRampModule.requestRedeem(zipAmount)` / `claim(assets)` as the off-ramp `operator`.
  These are CRE-held keys, not Forwarder reports.

## The cycle this workflow sequences
1. **(operator)** `OffRampModule.requestRedeem(zipAmount)` — escrow basket zipUSD into the queue. `zipAmount` MUST
   be a whole multiple of the queue's live `scaleUp()` (else `NotWholeUnit`); execs through the rq Safe.
2. **(report)** Warehouse `REDEEM(shares)` — `EE_POOL.redeem(shares, SAFE, SAFE)`: EE shares → USDC into the
   warehouse Safe. Size `shares` off live NAV (`EE_POOL.convertToAssets(EE_POOL.balanceOf(SAFE))`).
3. **(report)** Warehouse `REPAY(queue, amount)` — `USDC.transfer(queue, amount)`; `to` is scope-pinned
   `EqualTo(repaySink == queue)`.
4. **(operator)** `settleEpoch()` — reserve delivered USDC against `totalPending`, burn the filled zipUSD at par.
   Emits `RedemptionSettled(settleCount, era, pending, filledShares, fillAssets, availableAssets)`.
5. **(operator)** `OffRampModule.claim(assets)` — USDC → rq Safe (the basket).

## Triggering (on-demand)
Drive when there is pending redemption demand (the off-ramp needs USDC for buybacks) AND fundable free liquidity.
Event-driven off **`RedemptionSettled`**: settle → if backlog remains (`pending − filledShares > 0`) and liquidity
allows, sequence another REDEEM→REPAY→settle. A low-frequency heartbeat `cron` is a fine backstop, but there is no
required 30-day cadence.

## Policy / sizing decisions
- **REDEEM sizing** (shares to free) is the producer's job (§8.5), off live NAV + the epoch shortfall
  (`pending/scaleUp − queue's free USDC`).
- **Exit-vs-harvest split — DEFER to CRE-06.** The reservoir is shared with the 8-B5 strike borrow; over-redeeming
  starves the harvest loop and (by raising/holding `U`) tightens the freeze. CRE-02 must respect whatever
  working-capital reserve CRE-06 sets — do not drain the free reservoir blind.
- Partial fills are fine: an under-funded settle does a pro-rata (here, single-requester ⇒ 100%-to-rq) fill and
  carries the remainder; the next trigger funds more.

## Binds to
- `WarehouseAdminModule` (8-Bw) REDEEM/REPAY via the Chainlink Forwarder — `build/wires/8-Bw-CreditWarehouse.md`.
- `ZipRedemptionQueue.settleEpoch` (controller, on-demand) — `build/wires/9-ZipRedemptionQueue.md`.
- `OffRampModule.requestRedeem`/`claim` (operator) — `build/wires/OffRampModule.md`.
- The §8.0 report-encoding package (CRE-00) + the CRE-04 warehouse-op encoding (shared).
- `reference/cre-sdk-go` — trigger (`cron`/condition), `evmClient.WriteReport` (reports), and the operator-path tx
  submission for the controller/operator calls.

## Open seams to resolve while scoping
- **CRE-02 ↔ CRE-04 boundary.** §8.11 lists REDEEM under CRE-02 but SUPPLY/APPROVE/REPAY under CRE-04 — yet the
  redemption cycle needs REPAY too. Decide: CRE-02 imports CRE-04's warehouse-op encoding package, or owns the
  redemption-specific REDEEM/REPAY emissions. (Recommend: one shared warehouse-op package, both tickets call it.)
- **Operator-path mechanism.** Confirm the `cre-sdk-go` way to submit the direct `settleEpoch`/`requestRedeem`/
  `claim` txs (the §8.7 "operator path, NOT a report") — these run from CRE-held keys distinct from the warehouse
  Forwarder workflowId.
- **CRE-06 reserve contract.** CRE-02 consumes the exit-vs-harvest reserve policy; that policy must exist (even as
  a constant) before CRE-02 can size REDEEM safely.

## Identities to wire (deploy / item-10)
- `queue.controller` = the CRE-02 redemption-settle identity (distinct from the §4.4 origination controller AND the
  warehouse Forwarder workflowId).
- `OffRampModule.operator` = the CRE off-ramp identity; `queue.redeemController` = the **rq Safe** (not the module).
- warehouse adapter = its own distinct Forwarder identity / workflowId.

## Done when
- A trigger-driven Go workflow (builds to `wasip1`) runs the full cycle against the anvil fork — requestRedeem →
  REDEEM → REPAY → settleEpoch → claim — and a table-driven test asserts: zipUSD burned == `filledShares`; queue
  `reservedAssets` rose by the par `fillAssets`; rq Safe USDC rose by the claim; `RedemptionSettled` emitted with
  the expected fields.
- The **partial-fill** path is tested (under-funded REDEEM → partial settle → carry-forward → a later top-up
  settle drains it).
- REDEEM sizing reads live NAV and respects the CRE-06 reserve (a starved-reservoir case does NOT over-redeem).
- Warehouse ops use the distinct Forwarder workflowId; `settleEpoch`/off-ramp use the operator path.
