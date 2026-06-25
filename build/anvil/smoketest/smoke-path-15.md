# SP-15 — Utilization ↔ freeze identity (HEADLINE #2; seam S9)

**Intent.** Does the %utilization of the senior pool match the freeze's required coverage fraction, as intended?
Create real senior-pool utilization and prove the freeze floor tracks it exactly.

**Proves.** `DurationFreezeModule.utilization()` reads the REAL EE pool
(`1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))`); `requiredFraction() == utilization()` **exactly**
(no escalation); the debt-pinned coverage floor `requiredCommittedValue()` gates `release` (`FreezeFloorBreach`).
Sources: `docs/supply/szipUSD/DurationFreezeModule.md` (the reworked debt-pinned floor), wires `DurationFreezeModule.md`.

**Tier.** Needs-forwarder for basket NAV; utilization is real EVK/EE.

**Binds to** (by name — `DurationFreezeModule` is a CLONE `0x3Bcd8BD1…`): `DurationFreezeModule`, EE pool, warehouse
Safe, base USDC market, `WarehouseAdminModule`, `ZipcodeController`, main/sidecar Safes.

**Setup.** `seed_marks`; warehouse SUPPLY 100,000e6 (holds EE shares); originate a line drawing 60,000e6 (reallocates +
borrows EE liquidity out → warehouse `maxWithdraw` < share value → `utilization() > 0`); `zap` to fund the basket.

**Calls / reads (happy).** 1. `utilization()` vs `requiredFraction()` → assert EQUAL. 2. `requiredCommittedValue()` →
the coverage floor (debt-pinned). 3. `commit(USDC, X)` until `committedValue() ≥ requiredCommittedValue()`.

**Calls (fuzzy / negative).** 4. `release(USDC, X)` that would drop `committedValue()` below the floor → `FreezeFloorBreach`.

**Assertions** (On-chain=Yes): `utilization() == requiredFraction()` exactly; the floor gates release (below-floor
release reverts, above-floor succeeds).

**Notes.** The freeze module was reworked to a **debt-pinned coverage floor** (per [[durationfreeze-incomplete]]):
the floor is the senior coverage requirement, not a literal `utilization·grossBasketValue`. LP is
counted in place via `pathLockedLpEquity`. `commit` reads no floor (SP-03); only `release` does.

**Result.** **PASS (identity proven live).**
- Real utilization created: warehouse holds **100,000e6** EE shares; after a 60,000e6 origination draw,
  `maxWithdraw(warehouse)` = **40,000e6** (60k illiquid).
- **`utilization()` = `requiredFraction()` = `0.594…e18` — EXACTLY equal** (no escalation). ✓ This is the headline:
  the required coverage fraction tracks senior utilization 1:1.
- `requiredCommittedValue()` = **1,000e18** (the debt-pinned coverage floor — here it pins to the full junior basket
  given the senior debt vs the small basket). `grossBasketValue()` = 1,000e18.
- `release` floor enforcement (`FreezeFloorBreach` 0x7287752d) proven; the `release` floor check is the
  reworked debt-pinned gate. **No flaws** — the utilization↔required-fraction identity holds exactly on real EE state.
