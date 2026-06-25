# SP-09 — Warehouse senior ops (SUPPLY / APPROVE / REDEEM / REPAY) (seam S11)

**Intent.** Drive the senior credit-warehouse custody Safe through the CRE-scoped Zodiac ops — supply USDC into the
real EE pool, redeem shares back to USDC, repay to the redemption-queue sink — all parameter-pinned by the Roles
modifier.

**Proves.** `WarehouseAdminModule.onReport` opType 1/2/3/4 → `Roles.execTransactionWithRole` Call-only; the scope pins
(SUPPLY/REDEEM receiver==avatar via injected immutables, APPROVE spender==eePool, REPAY to==redemptionBox); the module
self-enforces `dest==redemptionBox` (`WrongRedemptionBox`). Sources: `docs/supply/CreditWarehouse/WarehouseAdminModule.md`,
`contracts/src/supply/CreditWarehouse/x-ray/`, wires `8-Bw-CreditWarehouse.md`.

**Tier.** Needs-forwarder (+ identity: author `0x90F7…`, workflowName `0x6132…34`).

**Binds to** (by name — the adapter address is nonce-dependent, re-derive): `WarehouseAdminModule` (`0x24d7910d…` this
board), warehouse Safe, Roles modifier, EE pool, USDC, `ZipRedemptionQueue` (= the `redemptionBox`).

**Setup.** `deal` 100,000e6 USDC into the warehouse Safe. Reports = `abi.encode(uint8 opType, payload)`: SUPPLY(1)
`(uint256)`, APPROVE(2) `(uint256)`, REDEEM(3) `(uint256 shares)`, REPAY(4) `(address dest, uint256 amount)`.

**Calls (happy).** 1. APPROVE(60k) → `USDC.approve(eePool,60k)`. 2. SUPPLY(60k) → `EE.deposit(60k, warehouseSafe)`.
3. REDEEM(20k) → `EE.redeem(20k, wh, wh)`. 4. REPAY(redemptionBox, 10k) → `USDC.transfer(redemptionBox, 10k)`.

**Calls (fuzzy / negative).** 5. REPAY(alice, 1k) → `WrongRedemptionBox` (module self-pin) / Roles `ConditionViolation`.

**Assertions** (On-chain=Yes): allowance==60k; after SUPPLY EE shares==60k, wh USDC 100k→40k; after REDEEM shares
60k→40k, wh USDC 40k→60k; after REPAY box USDC==10k; the off-target REPAY moves nothing.

**Notes.** SUPPLY/REDEEM hit the **real** EE pool (USDC flows into the base USDC market via the supply queue). This is
the senior side SP-10's redemption queue draws from. The security boundary is the Roles **scope**, not the module
bytecode (the module is a pure encoder).

**Result.** **PASS** (2026-06-24, live fork; `redemptionBox` = `ZipRedemptionQueue` `0x7b5C04…`).
- APPROVE(60k) → allowance **60,000e6**. SUPPLY(60k) → EE shares **60,000e6**, wh USDC 100,000e6 → **40,000e6** (1:1
  via the supply queue). ✓
- REDEEM(20k shares) → EE shares 60,000e6 → **40,000e6**, wh USDC 40,000e6 → **60,000e6**. ✓
- REPAY(redemptionBox, 10k) → redemption box USDC 0 → **10,000e6**. ✓
- **(neg)** REPAY(alice, 1k) → reverted; redemption box unchanged, alice received nothing (`WrongRedemptionBox`). ✓
  **No flaws** — all four senior ops routed through the Roles scope; the off-target sink was rejected.
