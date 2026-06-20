# SP-15 — Utilization ↔ freeze identity (HEADLINE #2)

**Intent.** Answer directly: *does the %utilization match the % committed in the non-rq (sidecar) Safe, as intended?*
Create real senior-pool utilization and prove the freeze floor tracks it exactly.

**Proves.** `DurationFreezeModule.utilization()` reads the REAL EE pool
(`1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))`); `requiredFraction() == utilization()` exactly
(no escalation); `release` enforces `committedValue() ≥ utilization()·grossBasketValue()` — so the sidecar committed
fraction must track utilization.

**Tier.** Needs-forwarder for basket NAV; the utilization mechanics are real EVK/EE.

**Binds to.** `DurationFreezeModule` `0x66e0e342…`, EE pool `0x1a7A8A5a…`, warehouse Safe `0xe0286169…`, base USDC
market `0x3A48aaaa…`, farm utility borrow vault `0x1aFc8c64…` (onboarded to EE), main `0x0B9C95c7…`/sidecar `0x39D22961…`.
Source: `DurationFreezeModule.sol` (`utilization` L233-240, `requiredFraction` L246-248, `requiredCommittedValue`
L267-269, `release` floor L300-317), wires `DurationFreezeModule.md`.

**Setup.**
- Warehouse supplies USDC into the EE pool (SP-09 SUPPLY) so `balanceOf(warehouse) > 0`.
- Create utilization: reallocate EE USDC from the base market into the farm utility borrow vault (adapter is allocator),
  then have the engine `borrow` against LP collateral (SP-04) so `maxWithdraw(warehouse)` < total → `utilization() > 0`.
- Fund the basket (SP-06) so `grossBasketValue() > 0`.

**Calls / reads.**
1. `utilization()`, `requiredFraction()` → assert EQUAL.
2. `requiredCommittedValue()` → assert `== utilization()·grossBasketValue()/1e18`.
3. `DurationFreezeModule.commit(USDC, X) as creOperator` until `committedValue() ≥ requiredCommittedValue()`.
4. `DurationFreezeModule.release(USDC, small) as creOperator` that would drop below the floor → revert `FreezeFloorBreach`.
5. `release(USDC, tiny) as creOperator` that stays above the floor → succeeds.

**Assertions.**
- `requiredFraction() == utilization()` (the identity).
- floor `== utilization·gross`; `release` reverts iff it would breach; the sidecar committed fraction = utilization fraction.

**Notes.** This was Tier-C-blocked under the mock EE (no `maxWithdraw`); the real EulerEarn pool makes it genuine.
The headline economic invariant of the structural freeze.

**Result.** **PASS** (2026-06-10, real txs on anvil). The headline economic invariant holds against real EE/EVK utilization: **%committed in the sidecar tracks %utilization exactly**, and `release` enforces the floor autonomously.

**Creating real utilization** (the prior Tier-C blocker, now genuine): `utilization()` reads `1 − maxWithdraw(warehouse)/sa` off the real pool, and `maxWithdraw` is bounded by *total* pool liquidity — so the warehouse's 8,000e6 had to become the whole pool first:
- Supplier acct[9] `redeem`'d all 100,000e6 EE shares → EE totalAssets **108,000e6 → 8,000e6** (warehouse-only; its 8k landed in the SP-14 line vault). Also `redeem`'d its 200,000e6 from the farm utility vault → farm utility cash **0**.
- Team (EE owner) `setIsAllocator(team,true)` + `reallocate` moved EE's 8,000e6 line→farm utility → farm utility holds EE's 8,000e6 (still liquid, U=0).
- Engine `postCollateral(10,000 LP)` (dealt then posted in one breath — main Safe never holds raw POL LP at oracle-read time, avoiding the SP-06 `UnknownLpToken` trap) + `borrow(6,000e6)` from the farm utility → farm utility cash **8,000e6 → 2,000e6**; `maxWithdraw(warehouse)` **8,000e6 → 2,000e6**, sa 8,000e6.

Reads / calls (all ✓):
1. **`requiredFraction() == utilization() == 0.75e18`** — (8000−2000)/8000 = 75%, the exact identity, no escalation/`min`/`max`.
2. `grossBasketValue` = **106,000e18** (main 56,000e6 USDC incl. the 6k borrowed + sidecar 50,000e6); **`requiredCommittedValue` = 79,500e18 == `utilization·gross/1e18` = 79,500e18** exactly.
3. **commit(USDC, 30,000e6)** → committedValue 50,000e18 → **80,000e18** > floor 79,500e18 (500-USDC buffer).
4. (breach) `release(USDC, 1,000e6)` → would drop committed to 79,000e18 < floor 79,500e18 → **`FreezeFloorBreach(79000e18, 79500e18)` (0x7287752d)** — floor read AFTER the move, atomically rolled back. ✓
5. (above floor) `release(USDC, 400e6)` → committed **79,600e18** > floor 79,500e18 → **succeeds**. Then `release(USDC, 200e6)` (would hit 79,400e18) → **`FreezeFloorBreach(79400e18, 79500e18)`**. ✓

No flaws. The structural-freeze invariant is real: the sidecar's committed fraction is pinned to senior utilization (`committedValue ≥ utilization·grossBasketValue`), `release` fails-closed on any breach regardless of operator intent, and `requiredFraction` is the bare `utilization` (M1 baseline, no §11-B escalation).

**State note for later paths:** EE pool is now warehouse-only 8,000e6 (supplier exited); team is an EE allocator; the farm utility carries a 6,000e6 engine borrow against 10,000 LP collateral; the basket freeze is committed 79,600e18 (sidecar) / main 26,400e6 USDC. SP-17 (flywheel) should manage/repay the farm utility loop as needed.
