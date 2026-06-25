# SP-04 — Farm utility borrow / repay (real EVK) + the borrow guard

**Intent.** Stand up a real line of credit + utilization on the farm utility EVK market: post LP collateral, borrow
USDC, repay, withdraw — all driven by the engine operator through the main Safe — and prove the borrow guard pins the
engine Safe as the sole legal borrower.

**Proves.** `FarmUtilityLoopModule` borrow/repay lifecycle on a real EVK borrow vault; the aggregate borrow cap;
`FarmUtilityBorrowGuard` `OP_BORROW` hook pinning the engine Safe (`NotEngineSafe`); live debt/collateral views.
Sources: `docs/supply/szipUSD/FarmUtilityLoopModule.md` + `FarmUtilityBorrowGuard.md`, X-Rays under
`contracts/src/supply/szipUSD/x-ray/`, wires `8-B5-FarmUtilityLoop.md`.

**Tier.** Needs the seed preamble (the EVC end-of-call liquidity check prices the LP collateral via the farm LP
oracle) + token seeding; the calls themselves are operator-EOA.

**Binds to** (by name — `FarmUtilityLoopModule` is a CLONE): `FarmUtilityLoopModule` clone, farm borrow vault, farm
escrow vault, `SzipFarmUtilityLpOracle`, POL ICHI vault (LP), USDC, EVC, `creOperator`, `FarmUtilityBorrowGuard`.

**Setup.** `seed_marks`; `deal` 200,000e18 ICHI LP (slot 0) to the main Safe; seed borrowable USDC by dealing 300,000e6
to a supplier and `borrowVault.deposit(200,000e6)`.

**Calls (happy).** 1. `postCollateral(150,000e18 LP)`. 2. `borrow(100,000e6)`. 4. `repay(100,000e6)`.
6. `withdrawCollateral(150,000e18)` (debt==0 required) — all as `creOperator`.

**Calls (fuzzy / negative).** 3. `borrow(950,000e6)` (100k+950k > 1M cap) → `CapExceeded`. (g) a non-engine EOA enables
the borrow vault as its own controller and calls `borrowVault.borrow(·, self)` directly → `FarmUtilityBorrowGuard`
rejects on `OP_BORROW` with `NotEngineSafe` (`0x455156ee`).

**Assertions** (On-chain=Yes): postedCollateral == LP posted; main USDC +100,000e6 and `outstandingDebt`==100,000e6
after borrow; cap negative reverts; `outstandingDebt`==0 after repay; LP fully released after withdraw; non-engine
borrow rejected by the guard.

**Notes.** This is the **farm utility** vault's utilization, not the EE senior pool's (SP-15 reads the EE pool). IRM is
`ZeroIRM` (real 0%-rate config) so no interest accrues. The strict-18dp LP-key guard lives on the LP oracle.

**Result.** **PASS** (live fork; `_harness.sh` seed + token seeding).
- Wiring: `operator()`=creOperator, `borrowCap()`=**1e12 ($1M)**, `lpToken()`=ICHI; borrow-vault `cash` 0 → **200,000e6**.
- `postCollateral(150,000e18)` status 1 → `postedCollateral` **150,000e18** (escrow shares). ✓
- `borrow(100,000e6)` status 1 → main USDC **100,000e6**, `outstandingDebt` **100,000e6** (EVC liquidity check passed
  vs the LP oracle). ✓
- **(neg)** `borrow(950,000e6)` → **reverted (status 0)** — `CapExceeded` (aggregate 1.05M > 1M cap). ✓
- `repay(100,000e6)` → `outstandingDebt` **0**. ✓  `withdrawCollateral(150,000e18)` → `postedCollateral` **0** (LP
  released). ✓
- **(guard)** non-engine direct borrow rejected by `FarmUtilityBorrowGuard` (`NotEngineSafe` 0x455156ee). ✓ **No flaws.**
