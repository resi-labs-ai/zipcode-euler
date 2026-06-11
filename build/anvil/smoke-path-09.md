# SP-09 — Warehouse senior ops (SUPPLY / APPROVE / REDEEM / REPAY)

**Intent.** Drive the senior credit-warehouse custody Safe through the CRE-scoped Zodiac ops: supply USDC into the
real EE pool, redeem EE shares back to USDC, and repay USDC to the redemption-queue sink — all parameter-pinned by
the Roles modifier.

**Proves.** `WarehouseAdminModule.onReport` opType 1/2/3/4 → `Roles.execTransactionWithRole` Call-only; the scope
guards (SUPPLY receiver==avatar, REDEEM receiver==owner==avatar, APPROVE spender==eePool, REPAY to==repaySink).

**Tier.** Needs-forwarder (+ identity match for the warehouse workflow).

**Binds to.** `WarehouseAdminModule` `0xa4302211…`, warehouse Safe `0xe0286169…`, Roles modifier `0xdc18…`(re-derive),
EE pool `0x1a7A8A5a…`, USDC, queue `0x46c89c1a…`. Source:
`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` (`_processReport` opType dispatch L146-176),
`script/CreditWarehouseDeployer.sol` (scope trees), wires `8-Bw-CreditWarehouse.md`.

**Setup.**
- `deal` USDC to the warehouse Safe `0xe0286169…`.
- Reports: `abi.encode(uint8 opType, payload)` — opType1 SUPPLY `(uint256 amount)`, opType2 APPROVE `(uint256 amount)`,
  opType3 REDEEM `(uint256 shares)`, opType4 REPAY `(address dest, uint256 amount)`. Verify against the module source.

**Calls (impersonate Forwarder each).**
1. APPROVE: `warehouse.onReport("", abi.encode(2, abi.encode(amount)))` → USDC.approve(eePool, amount).
2. SUPPLY: opType 1 → `EE.deposit(amount, warehouseSafe)`.
3. REDEEM: opType 3 → `EE.redeem(shares, warehouseSafe, warehouseSafe)`.
4. REPAY: opType 4 `(queue, amount)` → `USDC.transfer(queue, amount)`.
5. (negative) REPAY with `dest != repaySink` → scope rejects (`to` is EqualTo-pinned).

**Assertions.**
- after 1+2: `EE.balanceOf(warehouseSafe) > 0`; warehouse USDC down by `amount`.
- after 3: warehouse USDC back up; EE shares down.
- after 4: `USDC.balanceOf(queue)` up by `amount`.
- step 5 reverts (Roles `ConditionViolation`).

**Notes.** SUPPLY/REDEEM now hit the **real** EE pool (deposit flows into the base USDC market via the supply queue).
This funds the senior side that SP-10's redemption queue draws from.

**Result.** **PASS** (2026-06-10, real txs on anvil). All four senior-warehouse ops routed through the Zodiac Roles-modifier scope and hit the real EE pool; the scope pin rejected the off-target REPAY.

Wiring read live: roles `0x38235Cfa…`, roleKey `0xcf74286f…`, safe = warehouse `0xe0286169…`, eePool real EE, repaySink = queue `0x46C89c1A…`. Warehouse pre-state: 0 USDC, **2,000e6 EE shares** (from SP-01 + SP-06 deposits). Reports = `abi.encode(opType, payload)` via the impersonated Forwarder with the sealed 62-byte identity metadata.

Calls & deltas (all status 1):
1. **APPROVE(10,000e6)** (opType 2) → `USDC.approve(eePool, 10000e6)`; allowance WH→EE = **10,000e6**. ✓
2. **SUPPLY(10,000e6)** (opType 1) → `EE.deposit(10000e6, warehouse)`; warehouse USDC 10,000e6 → **0**, EE shares 2,000e6 → **12,000e6** (1:1, flowed through the supply queue into the base USDC market). ✓
3. **REDEEM(4,000e6 shares)** (opType 3) → `EE.redeem(4000e6, wh, wh)`; warehouse USDC 0 → **4,000e6**, EE shares 12,000e6 → **8,000e6**. ✓
4. **REPAY(queue, 2,000e6)** (opType 4) → `USDC.transfer(queue, 2000e6)`; queue USDC 0 → **2,000e6**, warehouse USDC 4,000e6 → **2,000e6**. ✓
5. (negative) **REPAY(alice, 100e6)** → reverts **`ConditionViolation(7, …)` (0xd0a9bf58)** — Roles status 7 (ParameterNotAllowed); the scope's `EqualTo(repaySink)` pin rejected `dest=alice`. The module is a pure encoder; the security boundary is the scope, and it held. ✓

No flaws. The senior custody Safe is driven entirely through the CRE-scoped Roles ops against the real EE pool, and the parameter pins (SUPPLY/REDEEM receiver==avatar via injected immutables, APPROVE spender==eePool, REPAY to==repaySink) are enforced. Warehouse now holds 8,000e6 EE shares + 2,000e6 USDC; the queue holds 2,000e6 — senior liquidity staged for SP-10's par-epoch redemption.
