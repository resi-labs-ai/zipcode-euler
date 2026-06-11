# SP-10 — Senior par-epoch redemption

**Intent.** Run the senior exit: escrow zipUSD into the redemption queue via the off-ramp, fund the queue with USDC,
settle the 30-day epoch pro-rata, and claim at par.

**Proves.** `OffRampModule.requestRedeem` (operator, through the rq Safe) → `ZipRedemptionQueue.requestRedeem`;
`settleEpoch()` (CRE controller) pro-rata fill + zipUSD burn + USDC reservation at par; `withdraw`/`claim`.

**Tier.** Needs-forwarder (settle controller = `creOperator`; the warehouse REPAY funding = SP-09).

**Binds to.** `OffRampModule` `0xc595aa93…` (operator `creOperator`, rq Safe = main `0x0B9C95c7…`),
`ZipRedemptionQueue` `0x46c89c1a…` (controller = `creOperator`, redeemController = main Safe), zipUSD, USDC.
Source: `contracts/src/supply/szipUSD/OffRampModule.sol` (`requestRedeem` L143-154, `claim` L160-165),
`contracts/src/supply/ZipRedemptionQueue.sol` (`requestRedeem`, `settleEpoch`, `withdraw`, `claimableAssets`),
wires `OffRampModule.md`, `9-ZipRedemptionQueue.md`.

**Setup.**
- The rq Safe (main) must hold zipUSD to escrow (from SP-06 the basket holds zipUSD; or `deal`/mint zipUSD to it).
- Fund the queue with USDC at par (SP-09 REPAY → `USDC.transfer(queue, amount)`), or `deal` USDC to the queue.

**Calls.**
1. `OffRampModule.requestRedeem(<whole-unit zipAmount>) as creOperator` (approve→requestRedeem→approve 0 through the Safe).
2. `cast rpc evm_increaseTime <30 days>` ; `evm_mine`.
3. `ZipRedemptionQueue.settleEpoch() as creOperator`.
4. `ZipRedemptionQueue.withdraw(<assets>, mainSafe, mainSafe)` (or `claim` via OffRamp) as the operator/requester.

**Assertions.**
- after 1: queue escrowed the zipAmount; `totalPending` rose.
- after 3: `epoch` incremented; zipUSD burned (supply down); `claimableAssets(requester) > 0` (pro-rata fill at par,
  ÷scaleUp into USDC).
- after 4: USDC delivered at par; claimable cleared.

**Notes.** Par-epoch math: `filled = totalPending · availableLiquidity / reserved`; unfilled carries forward. zipUSD
`burn` (queue-only) is exercised here — the other half of SP-01's lifecycle.

**Result.** **PASS** (2026-06-10, real txs on anvil). The senior exit runs end-to-end: escrow zipUSD → 30-day epoch settle (par, pro-rata, burn) → claim at par. Exercises the **queue-only zipUSD burn** — the other half of SP-01's lifecycle.

Wiring read live: offramp operator = `creOperator`, rqSafe = main Safe; queue settle-controller = `creOperator`, redeemController = main Safe, scaleUp = 1e12, EPOCH_DURATION = 30 days. Pre-state: main Safe held 1000e18 zipUSD (SP-06 basket), queue held 2000e6 USDC (SP-09 REPAY).

1. **requestRedeem(1000e18)** via OffRampModule as creOperator (approve→requestRedeem(amount, rqSafe, rqSafe)→approve 0, through the Safe) → main Safe zipUSD 1000e18 → **0**, queue zipUSD 0 → **1000e18**, `totalPending` → **1000e18**, `pendingRedeemRequest(rqSafe)` = 1000e18. ✓
2. `evm_increaseTime` +30 days (one-way; later CRE paths re-push fresh legs).
3. **settleEpoch()** as creOperator → 135,886 gas. availableAssets 2000e6, maxFill 1000e6 (= 1000e18/scaleUp), fill 1000e6 = pending ⇒ **100% drain**: `epoch` 0→**1**, `era` 0→**1**, `totalPending` → **0**, `reservedAssets` → **1000e6**, queue zipUSD **burned** (totalSupply 2000e18 → **1000e18** — the queue is a capacity-granted burner). ✓
4. **claim(1000e6)** via OffRampModule → queue.withdraw(1000e6, rqSafe, rqSafe) → rqSafe USDC 0 → **1000e6** (par, ÷scaleUp), queue USDC 2000e6 → **1000e6**, `claimableAssets`/`maxWithdraw`/`reservedAssets` all → **0**. ✓
- (negative) re-claim 1 more → **`InsufficientClaimable` (0xeb6def51)**. ✓

Par math: 1000e18 zipUSD ÷ 1e12 = 1000e6 USDC, exact $1 par, no loss.

**Note (lazy-realize, by design, not a flaw):** immediately post-settle `claimableAssets(rqSafe)` storage reads **0** while `maxWithdraw(rqSafe)` reads the true **1000e6**. The queue uses O(1) lazy realization (the `_realize` factor banks a requester's fill on their next touch); the realize-aware views (`maxWithdraw`/`previewRealize`/`claimableRedeemRequest`) report the correct claimable, and `withdraw` banks it before paying. The spec's "claimableAssets(requester) > 0" assertion holds via the realize-aware view. Front-ends must read `maxWithdraw`, not the raw `claimableAssets` slot.
