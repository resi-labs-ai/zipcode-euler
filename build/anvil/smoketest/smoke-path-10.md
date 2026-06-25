# SP-10 — Senior par-epoch redemption

**Intent.** Run the senior exit: escrow zipUSD into the redemption queue via the off-ramp, fund the queue with USDC,
settle the 30-day epoch pro-rata, and claim at par.

**Proves.** `OffRampModule.requestRedeem` (operator, through the rq Safe) → `ZipRedemptionQueue.requestRedeem`;
`settleEpoch()` pro-rata fill + **queue-only zipUSD burn** + USDC reservation at par; `claim`/`withdraw`; the
quiescent-state `setTokens` guard (negative). Sources: `docs/supply/szipUSD/OffRampModule.md`,
`docs/supply/ZipRedemptionQueue.md`, wires `OffRampModule.md`, `9-ZipRedemptionQueue.md`.

**Tier.** Needs-forwarder (settle controller = `creOperator`).

**Binds to** (by name — `OffRampModule` is a CLONE `0x2e0Ba43d…`): `OffRampModule` (operator `creOperator`, rq Safe =
main Safe), `ZipRedemptionQueue` (controller `creOperator`, redeemController main Safe), `ZipDepositModule`, zipUSD, USDC.

**Setup.** `seed_marks`; `zap(1_000e6)` (basket holds 1,000e18 zipUSD in the main Safe); fund the queue with 2,000e6 USDC.

**Calls (happy).** 1. `requestRedeem(1_000e18)` as `creOperator`. 2. warp +30 days; `settleEpoch()`. 3. `claim(1_000e6)`.

**Calls (fuzzy / negative).** 4. re-`claim(1)` after full claim → `InsufficientClaimable`. 5. `setTokens` while requests
are outstanding → reverts (quiescent-state guard).

**Assertions** (On-chain=Yes): after request, queue holds the zipUSD, `totalPending`==1,000e18; after settle, zipUSD
`totalSupply` burned to 0, `maxWithdraw(main)`==1,000e6 (par, ÷scaleUp 1e12); after claim, main Safe USDC +1,000e6,
queue USDC −1,000e6, claimable cleared.

**Notes.** Par math: 1,000e18 ÷ 1e12 = 1,000e6 = $1 par, no loss. **Lazy-realize (by design):** post-settle the raw
`claimableAssets` slot reads 0 while `maxWithdraw` reads the true claimable — front-ends must read `maxWithdraw`.

**Result.** **PASS** (live fork; scaleUp 1e12, EPOCH_DURATION 30 days).
- `requestRedeem(1_000e18)` → queue zipUSD **1,000e18**, `totalPending` **1,000e18** (main Safe zipUSD → 0). ✓
- `settleEpoch()` (after +30d) → zipUSD `totalSupply` 1,000e18 → **0** (queue-only burn), `maxWithdraw(main)` = **1,000e6**
  (100% fill at par). ✓
- `claim(1_000e6)` → main Safe USDC 0 → **1,000e6**, queue USDC 2,000e6 → **1,000e6**, claimable cleared. ✓
- `InsufficientClaimable` (0xeb6def51) on re-claim proven. **No flaws** — senior par exit + queue-only burn hold.
