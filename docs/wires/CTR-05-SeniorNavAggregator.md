# SeniorNavAggregator — donation-immune Σ senior par-backing across silos (wiring map)

> Source of truth = the kept code at `contracts/src/SeniorNavAggregator.sol` + its test
> `contracts/test/SeniorNavAggregator.t.sol`. Ticket `build/tickets/contracts/CTR-05-senior-nav-aggregator.md` is
> intent — the code is final. Fourth contract of the credit-warehouse scaling + federation workstream (CTR-02..10);
> depends on CTR-02 (`SiloRegistry`). Spec §7 (NAV) / §8.2 (donation-immune senior read) / §11 (loss) / §12 (solvency).

## Role
With N silos each holding senior EulerEarn shares in its OWN warehouse Safe, this read-only view sums the per-silo
senior value into one number — "how much USDC actually backs all outstanding zipUSD" across pools. It is **solvency
telemetry + the input to any circuit-breaker**, NOT a pricing oracle: zipUSD still mints by value and redeems at par.
Holds no funds, transfers nothing, writes only its two wiring slots.

**What it measures — SENIOR PAR backing, not full §12 NAV (load-bearing distinction).** §12 protocol NAV = idle USDC +
outstanding loan value **marked to recovery on impairment**. This aggregator sums the senior EulerEarn **share
value** per silo, which per §8.2 is `totalAssets() = Σ expectedSupplyAssets(strategy)` = idle-USDC-in-pool + lent-out
principal **at par**. It does NOT mark impaired loans to recovery — by the locked loss model (§11 / §12:1177-1179)
impairment lands in the **junior** `SzipNavOracle` provision, leaving the senior $1-backed. So `seniorBacking()` is the
**senior par-backing coverage** of zipUSD: it equals the §12 NAV numerator exactly while no impairment is outstanding,
and the junior provision is the buffer that absorbs the difference. A breaker keyed off it reads senior-par coverage —
the correct senior-solvency signal (senior stays par; junior eats first loss).

## Contracts involved (what each does)
| Contract / interface | What it does |
|---|---|
| `SeniorNavAggregator` (`is Ownable`) | The Σ view. Aggregate reads (`seniorBacking`/`activeSeniorBacking`/`illiquidSeniorValue`), ratio reads (`collateralization(supply)`/`systemCollateralization`), per-silo getters (`seniorBackingOf`/`illiquidSeniorValueOf`), Timelock-settable `registry`/`zipUsd` wiring (`setRegistry`/`setZipUsd` + `WiringSet`). Plain OZ `Ownable` v5, Timelock owner — same build-phase idiom as `SiloRegistry`. |
| `SiloRegistry` (CTR-02, imported) | The catalog looped: `allSiloIds()` → `getSilo(id).{eePool, warehouseSafe, active}`. Imported directly (the `Silo` struct return requires it; no inline-interface shortcut exists). |
| `ISeniorPool` (`contracts/src/interfaces/supply/ISeniorPool.sol`, reused) | The 3 donation-immune views per silo: `balanceOf`/`convertToAssets`/`maxWithdraw`. Venue-neutral seam (CTR-10a) — the generalization of the removed `IEulerEarnUtil`; EulerEarn satisfies it directly. |
| `IERC20` (`forge-std/interfaces/IERC20.sol`) | `zipUsd.totalSupply()` for `systemCollateralization` (the `ZipcodeOracleRegistry.sol:7` idiom). |

## The per-silo senior read (donation-immune, §8.2) — replicated VERBATIM from DurationFreezeModule:295-302
Per silo, keyed on `(eePool, warehouseSafe)`, NEVER `balanceOf(eePool)`:
```
sa   = ISeniorPool(eePool).convertToAssets(ISeniorPool(eePool).balanceOf(warehouseSafe))   // USDC 6-dp
seniorValue   = (sa == 0) ? 0 : sa * 1e12                          // 6→18dp; a drained silo → 0
free = ISeniorPool(eePool).maxWithdraw(warehouseSafe)              // only read when sa != 0
illiquidValue = (sa == 0 || free >= sa) ? 0 : (sa - free) * 1e12   // matches DurationFreezeModule:295-302
```
Donation-immune because real EulerEarn's `convertToAssets` reads `totalAssets() = Σ expectedSupplyAssets(strategy)`
(the controller-gated borrow side) and `balanceOf(warehouseSafe)` is the warehouse's shares — a stray-USDC donation
to the pool address moves neither term (§8.2 CRITICAL; `ISeniorPool.sol` NatSpec). `*1e12` is the 6→18dp scale
from `DurationFreezeModule.sol:301`.

## Functions (the surface)
- **`seniorBacking() → uint256`** (18-dp USD) — Σ `seniorValue` over **ALL** silos in `allSiloIds()` (the senior
  par-backing coverage numerator). Reverts `RegistryUnset` if `registry == 0`.
- **`activeSeniorBacking() → uint256`** — Σ `seniorValue` over silos with `active == true` only (routable-capacity
  telemetry). `RegistryUnset` guard.
- **`illiquidSeniorValue() → uint256`** — Σ `illiquidValue` over ALL silos (the lent-out senior dollars; the §12
  utilization / duration-squeeze input). `RegistryUnset` guard.
- **`collateralization(uint256 zipUsdSupply) → uint256`** — `seniorBacking() * 1e18 / zipUsdSupply` (18-dp ratio,
  `1e18` == 100% backed). **`zipUsdSupply == 0` → `type(uint256).max`** (no zipUSD outstanding ⇒ not insolvent; a
  breaker reading `< threshold` must NOT trip). The stress-test / hypothetical-supply form.
- **`systemCollateralization() → uint256`** — `collateralization(IERC20(zipUsd).totalSupply())` (the live breaker
  input). Reverts `ZipUsdUnset` if `zipUsd == 0`.
- **`seniorBackingOf(bytes32) → uint256` / `illiquidSeniorValueOf(bytes32) → uint256`** — per-silo dashboards; an
  unknown/empty silo (`getSilo` yields a zero struct, `eePool == 0`) returns **0**, never calls into `address(0)`.
  Both `RegistryUnset`-guarded.

## Why sum ALL silos, not just active (load-bearing — corrected from the draft ticket)
The draft excluded inactive silos from the live backing sum. That is **wrong for the solvency numerator**:
`SiloRegistry.retireSilo` (`:191`) only stops NEW routing — "existing lines close normally" — so a retired silo keeps
holding senior backing for the zipUSD its still-open lines minted. zipUSD is fungible at the hub (one shared senior
dollar), so §12 solvency (NAV ÷ **total** zipUSD minted) must count that backing while the zipUSD is outstanding;
excluding it understates the numerator and could **falsely trip a breaker** during a wind-down. The donation-immune
math makes inclusion safe AND free of special cases: a fully-drained silo has `balanceOf(warehouseSafe) == 0` ⇒
contributes 0. `activeSeniorBacking()` is the separate, honest "active routable capacity" number.

## Wiring — internal
- **`constructor(address registry_, address zipUsd_)` / `Ownable(msg.sender)`.** Seeds both wiring slots; BOTH may be
  zero (deploy-order flexibility, mirroring `SiloRegistry`'s zero-tolerant ctor). Owner = deployer → transferred to
  the Timelock at deploy.
- **`setRegistry` / `setZipUsd`** — `onlyOwner` (Timelock), reject zero with `ZeroAddress`, emit
  `WiringSet(bytes32 indexed slot, address value)` with slot labels `"registry"` / `"zipUsd"`. Same §17 re-pointable
  build-phase posture as every other wiring slot in the stack.
- **Errors:** `ZeroAddress` (setters), `RegistryUnset` (aggregate/per-silo reads when `registry == 0`), `ZipUsdUnset`
  (`systemCollateralization` when `zipUsd == 0`).

## Wiring — cross-component (who points at whom)
- **→ `SiloRegistry`** (CTR-02): read-only, every aggregate call. `allSiloIds()` + `getSilo(id)`; no write path.
- **→ each silo's `eePool`** (read-only): `convertToAssets`/`balanceOf`/`maxWithdraw` via `ISeniorPool` (CTR-10a). Reads the
  warehouse Safe's position, never the pool's own balance.
- **→ `zipUsd`** (the hub ESynth, 18-dp): `totalSupply()` for `systemCollateralization`.
- **← FE federation solvency dashboard / the mint kill-switch / circuit-breaker** (future consumers).
- **← CTR-10** will swap the per-silo read behind an `ISeniorPool` interface (non-Euler venues).

## Item-10 / deploy facts
- **Deploy order.** Deploy `SeniorNavAggregator(registry, zipUSD)` AFTER `SiloRegistry` and zipUSD exist (both known
  at deploy in configuration-one), OR with zeros + `setRegistry`/`setZipUsd` later. Transfer `owner` to the Timelock.
- **No silo-side wiring owed** — it is a pure downstream reader; no silo contract points back at it, nothing must
  register it. Adding/retiring silos is picked up automatically via `allSiloIds()`.

## Gotchas
- **Senior par ≠ §12 NAV under impairment.** `systemCollateralization()` reads senior-par coverage, not full
  protocol NAV (which marks impaired loans to recovery and nets the junior provision). They coincide pre-impairment;
  the junior `SzipNavOracle` provision is the buffer. Do not wire this as the junior NAV or the zipUSD price.
- **NEVER `balanceOf(eePool)`.** EulerEarn is a pure allocator (idle ≈ 0) and that read is both broken and donatable
  (§8.2 CRITICAL). Always `convertToAssets(balanceOf(warehouseSafe))`.
- **`collateralization(0)` returns `type(uint256).max`, not 0** — zero supply is fully-covered, not insolvent. A
  breaker comparing `< threshold` must treat max as "fine."
- **Test infra:** EulerEarn is the settable-backing mock (per-account `balanceOf`, settable
  `convertToAssets`/`maxWithdraw`, a `donateShares` path that does NOT move warehouse backing) modeled on
  `DurationFreezeModule.t.sol:107-130` / its donation test at `:455-461` — NOT `test/mocks/MockEulerEarn.sol` (which
  has no `maxWithdraw` and can't model `free < sa`). `SiloRegistry` is the REAL contract with self-consistent
  topology stubs (mirrors `SiloRegistry.t.sol`). Gate: `forge build` green + `forge test --match-path
  test/SeniorNavAggregator.t.sol` = 18 passed / 0 failed.
