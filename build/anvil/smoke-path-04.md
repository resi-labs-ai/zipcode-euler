# SP-04 — Farm utility borrow / repay (real EVK)

**Intent.** Stand up a real line of credit and utilization on the farm utility EVK market: post LP collateral, borrow
USDC against it, repay, withdraw — all driven by the engine operator through the main Safe.

**Proves.** `FarmUtilityLoopModule` borrow/repay lifecycle on a real EVK borrow vault; the borrow cap; over-repay
revert; the `FarmUtilityBorrowGuard` pinning the engine Safe as the sole legal borrower; live debt/collateral views.

**Tier.** Pure on-chain (operator EOA) — but needs token seeding (LP shares + USDC liquidity in the borrow vault).

**Binds to.** `FarmUtilityLoopModule` `0x61cdc9c8…`, borrow vault `0x1aFc8c64…`, escrow vault `0x8A5FA367…`,
EulerRouter `0x5a451fEB…`, POL ICHI vault `0x07e72E46…` (LP), USDC, EVC `0x5301c7dD…`, `creOperator`.
Source: `contracts/src/supply/szipUSD/FarmUtilityLoopModule.sol` (`postCollateral`, `borrow` w/ cap, `repay`,
`withdrawCollateral`, `outstandingDebt`, `postedCollateral`), `script/FarmUtilityMarketDeployer.sol`,
`contracts/src/supply/szipUSD/FarmUtilityBorrowGuard.sol`, wires `8-B5-FarmUtilityLoop.md`.

**Setup.**
- Acquire ICHI LP shares for the main Safe: `deal` the ICHI vault token `0x07e72E46…` balance to `0x0B9C95c7…`, or
  deposit WETH/USDC into the live ICHI vault from the Safe. (ICHI shares are an ERC-20 — `deal` works if its balance
  slot is found; else do a real ICHI `deposit`.)
- Provide borrowable USDC liquidity: `deal` USDC to a supplier and `deposit` into the borrow vault `0x1aFc8c64…`
  (or have the EE pool reallocate into it — see SP-15).

**Calls.**
1. `FarmUtilityLoopModule.postCollateral(<lpAmount>) as creOperator`.
2. `FarmUtilityLoopModule.borrow(100_000e6) as creOperator`.
3. (negative) `borrow(<over cap>) as creOperator` → revert `CapExceeded`.
4. `FarmUtilityLoopModule.repay(100_000e6) as creOperator`.
5. (negative) `repay(1) as creOperator` after full repay → EVK `E_RepayTooMuch`.
6. `FarmUtilityLoopModule.withdrawCollateral(<lpAmount>) as creOperator` (requires debt == 0).

**Assertions.**
- after 1: `postedCollateral() == lpAmount`; escrow vault shares held by the main Safe rose.
- after 2: main-Safe USDC +100,000e6; `outstandingDebt() == 100_000e6`.
- 3/5 revert as named.
- after 4: `outstandingDebt() == 0`. after 6: LP back in the main Safe.
- (guard) a `borrow` initiated by a non-engine-Safe account reverts `NotEngineSafe`.

**Notes.** This utilization is the **farm utility** vault's, not the EE senior pool's — the freeze module reads the EE
pool (SP-15). IRM is `ZeroIRM` so no interest accrues; that's a deliberate, real 0%-rate config.

**Result.** **PASS** (2026-06-10, real txs on anvil). The full farm utility loop ran on the real EVK market driven by `creOperator` through the main Safe's own EVC account.

Setup: dealt 200,000e18 ICHI LP (`0x07e72E46…`, balance slot 0) to the main Safe `0x0B9C95c7…`; seeded borrowable USDC by dealing 300,000e6 USDC to supplier acct[9] and `deposit(200,000e6)` into the borrow vault → `cash` 0 → **200,000e6**. Wiring read live: engineSafe=main Safe, lpToken=ICHI, borrowCap=**1e12 ($1M)**, BV LTVBorrow=80%/LTVLiq=90%, oracle=EulerRouter, LP priced **1 LP = $1.00** by the real `SzipFarmUtilityLpOracle`.

Calls & deltas:
1. `postCollateral(150,000 LP)` → `postedCollateral` 0 → **150,000e18** escrow shares; Safe LP 200k → **50k**. ✓
2. `borrow(100,000e6)` → Safe USDC 0 → **100,000e6**; `outstandingDebt` 0 → **100,000e6**. ✓ (EVC end-of-call liquidity check passed against the LP oracle.)
3. (neg) `borrow(950,000e6)` → **`CapExceeded` (0xa4875a49)** — module aggregate-cap check (100k+950k > 1M) fires before the EVC. ✓
4. `repay(100,000e6)` → `outstandingDebt` → **0**; Safe USDC → **0**. ✓
5. (neg) `repay(1)` after full repay → reverted, but with **`ERC20: transfer amount exceeds balance`** (EVC-wrapped `0x9773bb71`), NOT `E_RepayTooMuch` — because step 4 drained the Safe to exactly 0, so EVK pulls the 1 USDC (and fails) *before* the debt-cap check. Re-tested with the Safe funded 10 USDC: `repay(1)` at debt 0 → **`E_RepayTooMuch` (0xb2be531b)** as specced. Both reverts confirmed; the over-repay guard is intact, just gated by the asset pull first.
6. `withdrawCollateral(150,000 LP)` (debt==0 required) → `postedCollateral` → **0**; Safe LP 50k → **200,000e18** (full release). ✓
- (guard) attacker EOA `0x15d34AAf…` enabled BV as its own controller and called `borrow(1000e6, attacker)` directly → **`NotEngineSafe` (0x455156ee)** from `FarmUtilityBorrowGuard` on `OP_BORROW`. ✓

**Note (spec refinement, not a flaw):** step-5's named error depends on the Safe's USDC balance at the time. With a drained Safe (the realistic post-repay state) you get the ERC20 balance revert; the `E_RepayTooMuch` path only surfaces when the Safe holds spare USDC. Either way the spurious-repay is rejected. Real 0%-IRM (`ZeroIRM`) meant no interest accrued, so the exact-amount repay zeroed the debt cleanly.
