# 8-B10 — RecycleModule (single-sink recycle/payout engine + S1 divert) (wiring map)

> Source of truth = the kept code `contracts/src/supply/szipUSD/RecycleModule.sol`. Tickets
> `tickets/sodo/8-B10-recycle.md` + `tickets/sodo/S1-recycle-divert.md` and reports
> `reports/8-B10-report.md` + `reports/S1-report.md` are intent — **code wins**. Spec: `claude-zipcode.md`
> §4.5.1 (8-B10) + §8.7 / §17 (the trust boundary). Test: `contracts/test/RecycleModule.t.sol`.

## Role
The 8-B10 engine module (§4.5.1) — the auto-compounder's **free-value ledger** and the two spends that draw it
down. A CRE-operator-gated Zodiac `Module` (`is Module`), enabled ON the szipUSD engine Safe
(`avatar == target == engineSafe`), sibling of 8-B5..B9/B14. It owns the engine's **one** piece of real mutable
state — the single `freeValueAccrued` accumulator (no other module writes it; the CRE operator is the only
writer, §8 inv. 3) — and spends it through **two sinks that both debit the same ledger**:

1. **`recycle(usdcAmount)` (NAV accretion).** Debits `freeValueAccrued`, then drives the Safe to
   `usdc.approve(zipDepositModule)` → `ZipDepositModule.deposit(usdcAmount)` (the WOOF-06 zap: parks the USDC as
   senior `CreditWarehouse` backing and mints `usdcAmount * scaleUp` **backed** zipUSD to the Safe — the MAIN Safe
   holds it in place, **no `gate.depositFor`, no share issuance**) → `approve(…, 0)`. 8-B6 then single-sides the
   minted zipUSD into the gauge-staked ICHI LP next (CRE-sequenced). The basket grows, share count is flat →
   **NAV-per-share rises for every holder**.
2. **`divert(usdcAmount)` (S1 / loss-side Stream 2, `solvency.md` §C.S1).** Debits the same ledger, then supplies
   the free-value USDC as **raw USDC** into the senior pool crediting the warehouse —
   `eePool.deposit(usdcAmount, warehouse)`, **NO zipUSD minted, NO senior claim** — filling the capital hole a
   default left behind so depositors stay whole. Bounded by the **live `SzipNavOracle.provision()` hole**.

The prior Mode A/B/C framing + the 8-B13 compounder + the whole payout/distributor path were **removed** in the
single-sink rework — single-sided LP makes the balanced-add/swap machinery moot (see Gotchas).

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `RecycleModule` (`is Module`, `RecycleModule.sol`) | The 8-B10 module. Holds `freeValueAccrued` + the 7 set-once wiring slots; exposes `creditFreeValue`/`recycle`/`divert` (`onlyOperator`) + 7 `onlyOwner` re-point setters. Drives the Safe via inherited `execAndReturnData` (Call-only, value 0, bubble-on-fail). |
| `IZipDepositModule` (local iface; `ZipDepositModule.sol:115`) | The WOOF-06 zap. `deposit(usdcIn)` `safeTransferFrom`s `usdcIn` USDC from the caller (the engine Safe), mints `usdcIn*scaleUp` BACKED zipUSD to the caller, parks the USDC into the venue pool with the warehouse as EE-share receiver. The `recycle` mint path. |
| `ISzipNavProvision` (local iface; `SzipNavOracle.sol:135`) | The impairment-provision read (the hole size, 18-dp USD). `provision()` is `uint256 public`, sole writer = the `DefaultCoordinator`. `divert` READS it (the bound) and **never writes it**. |
| `IEulerEarn` (local iface; `reference/euler-earn/src/EulerEarn.sol:560`) | The senior pool (ERC-4626 over USDC). `deposit(assets, receiver)` pulls `assets` from the Safe, mints shares to `receiver` (the warehouse). The `divert` Stream-2 sink — same surface `ZipDepositModule` uses. |

## Wiring — internal
- **`setUp(bytes)` decodes 8 addresses** (S1 grew it 5 → 8): `(owner, engineSafe, operator, zipDepositModule,
  usdc, navOracle, eePool, warehouse)`. ORDER is load-bearing: validate ALL 8 decoded addresses nonzero FIRST +
  `owner != operator` (`OwnerIsOperator`), so a zero reverts `ZeroAddress` deterministically before any use; then
  set `avatar = target = engineSafe`, store the wiring, THEN `_transferOwnership(owner)`. No live-read/staticcall
  in `setUp`. The first 5 are the recycle wiring; `navOracle`/`eePool`/`warehouse` are the S1 divert add (the same
  set-once, NOT-`immutable`, clone-safe pattern).
- **`onlyOperator` entrypoints** (`msg.sender != operator` → `NotOperator`):
  - `creditFreeValue(amount)` — `amount==0`→`ZeroAmount`; `freeValueAccrued += amount`; emits `FreeValueCredited`.
    The CRE passes `max(0, realized − borrowRepaid)` (single-arg, operator-trusted — the module cannot reconstruct
    historical realized/repaid on-chain). 8-B9 does NOT credit; this is 8-B10's owned accumulator.
  - `recycle(usdcAmount) returns (uint256 zipMinted)` — `_spendFreeValue(usdcAmount)` (effects first) → Safe execs
    `approve(zdm, usdcAmount)` → `deposit(usdcAmount)` → `approve(zdm, 0)`; decodes `zipMinted` from the deposit
    return; emits `Recycled`.
  - `divert(usdcAmount) returns (uint256 sent)` — Stream 2 (see bounds below).
- **`freeValueAccrued` ledger** — the ONLY mutable state. `creditFreeValue` is the sole increment; `recycle` AND
  `divert` BOTH debit it via the single private gate `_spendFreeValue(amount)` (`amount==0`→`ZeroAmount`;
  `amount > freeValueAccrued` → `InsufficientFreeValue`; decrement; emit `FreeValueSpent`). **Effects-before-
  interaction**: the decrement lands BEFORE any value-moving `_exec` (the reentrancy safety — no OZ `ReentrancyGuard`
  on a clone; see Gotchas).
- **`divert` bounds — bounds-before-spend, then CEI** (order load-bearing; **CUMULATIVE** since SEC-09):
  1. `usdcAmount == 0` → `ZeroAmount`.
  2. read `hole = navOracle.provision()` fresh each call (no memoization); `hole == 0` → `NoHole`.
  3. **reset-on-change:** `if (hole != lastSeenProvision) { lastSeenProvision = hole; divertedSinceProvisionChange = 0; }`
     — a re-marked provision starts a fresh epoch budget. `lastSeenProvision == 0` is a safe "never observed"
     sentinel (the `hole == 0` → `NoHole` check means the reset block can never set it to 0).
  4. `scaled = usdcAmount * 1e12` (USDC 6-dp → USD 18-dp); **cumulative** bound
     `divertedSinceProvisionChange + scaled > hole` → `ExceedsHole` (**strict `>`** allows an EXACT cumulative fill,
     never an over-fill). The cumulative check subsumes the old per-call `usdcAmount * 1e12 > hole` (strictly
     tighter; SEC-09 replaced the per-call line). Both pre-spend checks land BEFORE any ledger debit, so an
     over-hole/no-hole divert records no exec and leaves the ledger untouched.
  5. `_spendFreeValue(usdcAmount)` — the CEI decrement (effects first, the policy gate) — then
     `divertedSinceProvisionChange += scaled` (effects-phase tally bump, before the value-moving execs; rolls back
     atomically with the ledger if a post-deposit guard reverts). **`divert` never writes `provision`** — the
     tally is enforced by OBSERVING `provision()`, not by mutating it (the CRE owns the hole reduction). Guarantee
     is **per-provision-epoch** (between re-marks); cross-re-mark over-supply is possible but benign (peg-strengthening,
     hard-capped by `freeValueAccrued` + the trusted single CRE writer, §17). The `lastSeenProvision`/
     `divertedSinceProvisionChange` state is `uint256 public` (free getters), 18-dp USD.
  6. Safe execs `approve(eePool, usdcAmount)` → `eePool.deposit(usdcAmount, warehouse)` → `approve(eePool, 0)`.
  7. **TWO value guards** captured around the deposit: **hard backing** — `beforeUsdc − balanceOf(safe)` MUST
     equal exactly `usdcAmount` (`BackingShortfall`, proves real value moved, not a trusted-pool no-op); and
     **liveness** — the warehouse's EE-share balance MUST have risen (`NoSharesMinted`, the false-return/FoT guard,
     since the Safe swallows inner reverts).
  8. emit `Filled(usdcAmount, warehouse, hole)` — `provisionAfter == hole` (the pre-spend read): **divert never
     writes `provision`** (the CRE reduces the hole later via `DefaultCoordinator.Recovery`).
- **The internal `_spendFreeValue` gate** is `private` — there is NO public `spendFreeValue` and NO compounder
  seam (both deleted in the rework). The only paths that draw the ledger down are `recycle` and `divert`.
- **`_exec(to, data)`** drives the Safe via inherited `execAndReturnData(to, 0, data, Operation.Call)` and
  HARD-REVERTS bubbling inner revert data if the Safe returns `false` (`ExecFailed` when no data) — the Gnosis Safe
  `execTransactionFromModuleReturnData` catches inner reverts and returns `(false, revertData)` rather than
  bubbling, so an unchecked exec would silently swallow a failed deposit/transfer.

## Wiring — cross-component (who points at whom)
- **`zipDepositModule` → WOOF-06 `ZipDepositModule`** (the deployed zap). The `recycle` backed-mint path; the
  module never calls `ESynth.mint` directly, so the zipUSD is **backed 1:1 by construction** (USDC parked as
  senior backing BEFORE the mint) — discharges the 8-B6 backed-zipUSD invariant (PROGRESS row "8-B10 · 8-B6
  backed-zipUSD invariant", mechanism side).
- **`navOracle` → the SAME `SzipNavOracle`** the `DefaultCoordinator` writes `provision` to. The `divert` bound
  reads the live hole; if `navOracle` pointed at a different oracle the bound would read a stale/zero hole. (S1
  obligation, item-10 wiring below.)
- **`eePool` / `warehouse` → the ONE bank.** `eePool` MUST equal `ZipDepositModule.eePool()` and `warehouse` MUST
  equal the `ZipDepositModule`/`WarehouseAdminModule` warehouse Safe — else diverted USDC supplies the wrong pool
  / credits the wrong receiver and never fills the hole. Stream 1's `treasurySafe` USDC output is supplied to THIS
  same warehouse too (a CRE/off-chain step, not on-chain). Enforced by the item-10 deploy-asserts.
- **`creditFreeValue` is operator-trusted UNBOUNDED** — §17 / §8.7 trust boundary. The policy ceiling (the ledger
  can never route more than the credited free value) is operator-TRUSTED, not cryptographic: an over-credit could
  route depositor principal. The single immutable CRE operator (set at `setUp`, asserted `operator != owner`) IS
  the security boundary; backstopped by the 8-B11 fund-discipline + the 8-B12 tripwire (off-chain). The hard-
  backing layer (the Safe's real USDC is pulled by the `deposit`/`exec` legs, which revert if the Safe is short)
  means even an over-credited accumulator cannot conjure value.

## Item-10 deploy facts
- **Deploy** the module clone via `ModuleProxyFactory` CREATE2 **+ `setUp` ATOMICALLY in one factory tx**
  (front-run-safe) (the 8-B5/8-B8/8-B9/8-B14 pattern; never two-tx). The mastercopy is locked AUTOMATICALLY by its
  constructor (`MastercopyInitLock`, SEC-14) the instant it is deployed — NO separate deploy-time lock step, and
  `setUp` on the mastercopy reverts `AlreadyInitialized`.
- **Recycle wiring (PROGRESS row 357, RECYCLE-ONLY):** wire the single CRE operator as `RecycleModule.operator`;
  `zipDepositModule` → the deployed WOOF-06 module; `usdc` → the live token. (No `xAlpha`/`distributor`/
  `compounder` — deleted in the rework.) `owner` = the Timelock, `!= operator` (asserted in `setUp`).
- **S1 divert wiring (PROGRESS row 375):** call the three Timelock setters on the deployed module —
  `setNavOracle(SzipNavOracle)` / `setEePool(EE_POOL)` / `setWarehouse(CreditWarehouse Safe)` — then **deploy-time
  assert the one-bank invariant**, reverting the deploy on mismatch:
  - `RecycleModule.warehouse == ` the `ZipDepositModule`/`WarehouseAdminModule` warehouse Safe;
  - `RecycleModule.eePool() == ZipDepositModule.eePool()`;
  - `RecycleModule.navOracle == ` the `DefaultCoordinator`'s oracle (the SAME `SzipNavOracle` that holds
    `provision`).
- All 7 wiring slots are Timelock-re-pointable (`setEngineSafe`/`setOperator`/`setZipDepositModule`/`setUsdc`/
  `setNavOracle`/`setEePool`/`setWarehouse`, each `onlyOwner` + zero-guard + `WiringSet` event) — build-phase §17,
  not set-once-renounce-frozen. `setAvatar`/`setTarget` are inherited `onlyOwner` (the hot operator key CANNOT
  call them).
- **`setOperator` re-checks `operator != owner` (`OwnerIsOperator`), SEC-15.** Beyond the zero-guard, the re-point
  preserves the init-time (`setUp`) role separation across re-points — it cannot collapse the Timelock owner and the
  CRE operator into one key.

## Gotchas
- **DELETED in the single-sink rework** (do not look for them — the historical `RecyclePayoutModule` carried
  them): `payoutClean` / `payoutBoost` / the public `spendFreeValue` / `setCompounder` / the `xAlpha` /
  `distributor` / `compounder` slots / `onlyOperatorOrCompounder` — and the **entire `SzipRewardsDistributor`**
  (the pull-claim Merkle payout contract). **8-B13 is absorbed** (single-sided LP needs no balanced-add/swap-to-
  fund compounder). Holder return is NAV accretion, realized on exit at NAV — there is no Merkle root to fund/post
  and no claim path.
- **`freeValueAccrued` is a POLICY COUNTER, not value.** It is a pure off-chain-fed spend-GATE; the recycled value
  lands as REAL basket assets (backed zipUSD → single-sided LP) and the diverted value as REAL warehouse backing.
  `SzipNavOracle` / 8-B12 MUST value the Safe's REAL token/LP balances and **NEVER add `freeValueAccrued`** —
  adding it would double-count. 8-B10 never writes NAV; the recycle is genuinely NAV-accretive (basket grows,
  shares flat), never a NAV markup (§8 inv. 7).
- **No OZ `ReentrancyGuard`** — a `ModuleProxyFactory` clone never runs the guard's constructor (immutable/storage
  set in a constructor doesn't apply to clones). Safety is **effects-before-interaction** (the `_spendFreeValue`
  decrement lands before any value-moving `_exec`) + the set-once trusted wired targets + `ZipDepositModule`'s own
  `nonReentrant`. Same for all wired addresses being plain set-once storage, NOT `immutable` (a clone shares the
  mastercopy runtime bytecode → `immutable` would be identical for every clone and cannot carry per-clone config).
- **`divert` value-flow tests need a LIVE Safe + a real `EEMock`** — a non-live RecordingSafe would falsely trip
  the share-rose guard. The `BackingShortfall` hard-backing assert is a security hardening (S1 F5) beyond the
  literal spec's share-rose-only guard (which proves liveness, not value-moved); it matches the module's own
  HARD-BACKING doctrine.
