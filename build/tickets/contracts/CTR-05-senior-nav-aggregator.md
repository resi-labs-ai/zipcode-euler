# CTR-05 — SeniorNavAggregator: donation-immune Σ senior backing across silos

> Contract-track change (EXPANSION). A read-only view that sums each silo's senior backing into one number, so
> zipUSD's solvency (Σ backing vs supply) is observable across N pools. This is solvency telemetry + the input to
> any circuit-breaker — NOT a pricing oracle (zipUSD still mints by value and redeems at par).
> Spec: `claude-zipcode.md` §7 (NAV) / §11 (loss) / §12 (NAV / dashboard / solvency) / §8.2 (donation-immune senior read).

## Why (the seam)
With N silos each holding senior EulerEarn shares in its own warehouse Safe, the protocol needs one aggregate
"how much USDC actually backs all outstanding zipUSD." Each silo already exposes a donation-immune per-silo read
(in `DurationFreezeModule`); nothing sums them. The aggregator loops `SiloRegistry.allSiloIds()` and adds the
per-silo senior values.

**What this measures (read carefully — it is SENIOR PAR backing, not full §12 NAV).** §12 defines protocol solvency as
`NAV ÷ zipUSD minted ≥ 1`, where §12 NAV = idle USDC + outstanding loan value **marked to recovery on impairment**
(§12:1162-1165). This aggregator sums the senior EulerEarn **share value** per silo — which per §8.2 is
`totalAssets() = Σ expectedSupplyAssets(strategy)` = idle-USDC-in-pool + lent-out principal **at par**. It does NOT
mark impaired loans to recovery: by the locked loss model (§11/§12:1177-1179) impairment lands in the **junior**
`SzipNavOracle` provision, leaving the **senior** $1-backed. So `seniorBacking()` is the **senior par-backing
coverage** of zipUSD — it equals the §12 NAV numerator exactly while no impairment is outstanding, and the junior
provision (§11) is the buffer that absorbs the difference under impairment. A breaker keyed off this reads
**senior-par coverage**, which is the correct senior-solvency signal (senior stays par; junior eats first loss).
This contract is telemetry/breaker input only — zipUSD still mints by value and redeems at par.

## Deliverable
A new `contracts/src/SeniorNavAggregator.sol` (pure view contract — holds no funds, changes no silo logic):

- A `registry` (CTR-02 `SiloRegistry`) pointer, Timelock-settable (`setRegistry` + `WiringSet`, §17; seeded in ctor,
  MAY be zero at deploy — the aggregate reads then revert `RegistryUnset` until wired).
- A `zipUsd` (ESynth) pointer, Timelock-settable (`setZipUsd` + `WiringSet`, §17; seeded in ctor, MAY be zero at
  deploy — `systemCollateralization()` then reverts `ZipUsdUnset`, the arg form `collateralization(supply)` still works).
- Constructor `(address registry_, address zipUsd_)` — accepts zero for BOTH (deploy-order flexibility; mirror
  `SiloRegistry`'s ctor accepting a zero `controller_`). `Ownable(msg.sender)` = the Timelock owner.
- Interfaces:
  - `IEulerEarnUtil` — REUSE the existing `contracts/src/interfaces/euler/IEulerEarnUtil.sol`
    (`balanceOf`/`convertToAssets`/`maxWithdraw`). Import it; do NOT redeclare.
  - **Read the registry by `import {SiloRegistry} from "./SiloRegistry.sol";`** and calling `registry.allSiloIds()`
    + `registry.getSilo(siloId)` (returns `SiloRegistry.Silo memory`, fields `eePool`/`warehouseSafe`/`active`). Do
    NOT try a pure inline interface here — naming the `Silo` struct return type REQUIRES importing `SiloRegistry`
    anyway (CTR-03's inline `ISiloRegistry` only declares the 3 non-struct methods; there is no struct-read
    precedent — importing the contract is the only self-contained option). `zipUsd.totalSupply()` via
    `forge-std/interfaces/IERC20.sol` (the `ZipcodeOracleRegistry.sol:7` idiom).

### The senior read (per silo) — replicate `DurationFreezeModule` EXACTLY
Both reads use the §8.2 donation-immune pattern, NEVER `balanceOf(eePool)`:

```
// helper, per (eePool, warehouseSafe). Guards are VERBATIM from DurationFreezeModule:295-302 — keep them, do not
// rely on convertToAssets(0)==0 implicitly.
sa(silo)   = IEulerEarnUtil(eePool).convertToAssets(IEulerEarnUtil(eePool).balanceOf(warehouseSafe))   // USDC 6-dp
seniorValue(silo)   = (sa == 0) ? 0 : sa * 1e12                            // 6→18dp; a drained silo → 0
free(silo) = IEulerEarnUtil(eePool).maxWithdraw(warehouseSafe)            // only read if sa != 0
illiquidValue(silo) = (sa == 0 || free >= sa) ? 0 : (sa - free) * 1e12    // matches DurationFreezeModule:295-302
```

### Functions
- `seniorBacking() returns (uint256)` — **Σ `seniorValue(silo)` over ALL silos in `allSiloIds()`** (the senior
  par-backing coverage; see "Why"). A fully-drained silo contributes 0 (its `balanceOf(warehouseSafe)`→0→
  `convertToAssets`→0), so summing every silo is safe AND correct: see "Active-filter resolution" below. Reverts
  `RegistryUnset` if `registry == address(0)`.
- `activeSeniorBacking() returns (uint256)` — Σ `seniorValue(silo)` over silos with `active == true` only (the
  routable-capacity telemetry view). Reverts `RegistryUnset` if `registry == address(0)`.
- `illiquidSeniorValue() returns (uint256)` — Σ `illiquidValue(silo)` over ALL silos (the lent-out senior dollars,
  18-dp; the §12 utilization/duration-squeeze input). Reuses the exact `DurationFreezeModule.illiquidSeniorValue`
  formula (`:295-302`). Reverts `RegistryUnset` if `registry == address(0)`.
- `collateralization(uint256 zipUsdSupply) returns (uint256)` — `seniorBacking() * 1e18 / zipUsdSupply` (18-dp ratio;
  `1e18` == exactly 100% backed). **`zipUsdSupply == 0` → `type(uint256).max`** (no zipUSD outstanding ⇒ not insolvent;
  a breaker reading `< threshold` must NOT trip). The stress-test / hypothetical-supply form.
- `systemCollateralization() returns (uint256)` — `collateralization(IERC20(zipUsd).totalSupply())` using the wired
  `zipUsd` (the live breaker input). Reverts `ZipUsdUnset` if `zipUsd == address(0)`.
- Per-silo getters (dashboards; cover retired silos too) — **return 0 for an unknown/empty silo** (`getSilo` on an
  unregistered id yields a zero-filled struct; `eePool == 0` ⇒ return 0, never call into `address(0)`):
  - `seniorBackingOf(bytes32 siloId) returns (uint256)` — `seniorValue(silo)` for one silo (any active state).
  - `illiquidSeniorValueOf(bytes32 siloId) returns (uint256)` — `illiquidValue(silo)` for one silo.

## Spec §
`claude-zipcode.md` §8.2 (the donation-immune senior read — `U = 1 − maxWithdraw(warehouse)/convertToAssets(
balanceOf(warehouse))`, NEVER `balanceOf(eePool)`); §12 (solvency = NAV ÷ zipUSD minted ≥ 1, system-wide); §7/§11.

## Binds to (verified by inspection — line-pinned)
- `contracts/src/interfaces/euler/IEulerEarnUtil.sol:12-21` — `maxWithdraw(address)`, `convertToAssets(uint256)`,
  `balanceOf(address)`, all `view`. CONFIRMED exists; reuse, do not redeclare.
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol:243-302` — the donation-immune `utilization()`/
  `illiquidSeniorValue()` to replicate per silo; the `*1e12` 6→18dp scale is at `:301`.
- `contracts/src/SiloRegistry.sol` (CTR-02, BUILT): `allSiloIds() returns (bytes32[])` (`:250`); `getSilo(bytes32)
  returns (Silo memory)` (`:245`); the `Silo` struct's `eePool`/`warehouseSafe`/`active` fields (`:65-77`).
- zipUSD is an ESynth, **18 decimals — VERIFIED**: `DeployZipcode.s.sol:260` constructs `new ESynth(EVC, "Zipcode
  USD", "zipUSD")`; `ESynth is ERC20EVCCompatible (→ EVCUtil, ERC20Permit)` with NO `decimals()` override → OZ ERC20
  default 18 (corroborated: `ZipDepositModule.sol:88` reads `decimals()` and derives the `1e12` 6→18 scale).
  `totalSupply()` via `forge-std/interfaces/IERC20.sol` (the idiom in `ZipcodeOracleRegistry.sol:7`). seniorBacking
  is 18-dp USD ⇒ `collateralization` is a clean 18-dp ratio (the `*1e18 / supply` cancels supply's 18 dp).

## Starting state
- No aggregator exists; `DurationFreezeModule` does the per-silo donation-immune read for ONE pool. `SiloRegistry`
  exists (CTR-02). `IEulerEarnUtil` exists.

## Do NOT
- Do NOT ever read `balanceOf(eePool)` — EulerEarn is a pure allocator (idle ≈ 0) and that read is both broken and
  donatable (the §8.2 CRITICAL). Always `convertToAssets(balanceOf(warehouseSafe))`.
- Do NOT sum junior NAV here — loss is local to each silo's junior; this view is senior backing only.
- Do NOT let zipUSD price off this — it is telemetry/breaker input; zipUSD mints by value and redeems at par.
- Do NOT exclude retired/inactive silos from `seniorBacking()`/`illiquidSeniorValue()` — see the resolution below.
  (The `active` filter belongs ONLY to `activeSeniorBacking()`, the routing-capacity view.)
- Do NOT hold funds, write state beyond the two wiring slots, or asset-transfer. Pure view + Timelock wiring.

## Active-filter resolution (load-bearing — changed from the original draft)
The original draft excluded inactive silos from the live backing sum. That is **wrong for the solvency numerator**:
`retireSilo` (CTR-02 `:191`) only stops NEW routing — "existing lines close normally" — so a retired silo keeps
holding senior backing for the zipUSD its still-open lines minted. zipUSD is fungible at the hub (one shared senior
dollar), so §12 solvency (NAV ÷ **total** zipUSD minted) must count that backing while the zipUSD is outstanding;
excluding it understates the numerator and could **falsely trip a breaker** during a wind-down. The donation-immune
math makes inclusion safe: a fully-drained silo has `balanceOf(warehouseSafe)==0` ⇒ contributes 0 with no special
case. So: `seniorBacking()`/`illiquidSeniorValue()` sum **all** silos; the honest "active routable capacity" number
is the separate `activeSeniorBacking()`. (Spec §12 unchanged — it already says system-wide; this is a ticket fix.)

## Key requirements
1. **Donation-immunity is the whole point** — a test donates USDC (and/or mints shares) to an `eePool` address and
   asserts `seniorBacking()` does not move (only `convertToAssets(balanceOf(warehouseSafe))` moves it).
2. **N=1 identity** — with one silo, `seniorBacking()` equals that warehouse's `convertToAssets(balanceOf(safe))*1e12`.
3. **Σ correctness + active semantics** — two silos sum in `seniorBacking()`; retiring one (active=false) does NOT
   change `seniorBacking()` (it still backs outstanding zipUSD) but DOES drop it from `activeSeniorBacking()`; a
   fully-drained silo contributes 0 to both.
4. **6→18dp scaling matches** `DurationFreezeModule` exactly (`*1e12`, `:301`).
5. **`collateralization` edge** — `zipUsdSupply==0` → `type(uint256).max`; `systemCollateralization()` reverts
   `ZipUsdUnset` when `zipUsd` is unwired and equals `collateralization(totalSupply())` when wired.
6. **Wiring §17** — `setRegistry`/`setZipUsd` are `onlyOwner` (Timelock), reject zero with `ZeroAddress` and emit
   `WiringSet(bytes32 indexed slot, address value)` with slot labels `"registry"` / `"zipUsd"` respectively (mirror
   `SiloRegistry.setController:262-266` + the `WiringSet` event at `:118`). Error catalog: `ZeroAddress` (setters),
   `RegistryUnset` (aggregate reads when `registry==0`), `ZipUsdUnset` (`systemCollateralization` when `zipUsd==0`).

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/SeniorNavAggregator.t.sol` green covering: N=1 identity; two-silo Σ; donation
  no-op; retired-silo still-counted-in-`seniorBacking`-but-dropped-from-`activeSeniorBacking`; drained-silo-zero;
  `illiquidSeniorValue` matches the freeze-module formula; `collateralization` math + zero-supply→max;
  `systemCollateralization` wired vs `ZipUsdUnset`; per-silo getters; `setRegistry`/`setZipUsd` gating + zero-reject.
- EulerEarn is **mocked** on the **settable-backing precedent in `DurationFreezeModule.t.sol:107-130`** (NOT
  `test/mocks/MockEulerEarn.sol`, which has no `maxWithdraw` and can't model `free<sa` so it would not exercise
  donation-immunity). The mock MUST have: per-account `balanceOf` (so `balanceOf(warehouseSafe)` differs from a
  donation to `eePool`), a settable `convertToAssets`/`maxWithdraw` model (e.g. `setBacking(account, shares,
  totalBacking, free)`), and a donate path that mints to the pool address WITHOUT moving the warehouse's backing —
  mirror the donation test at `DurationFreezeModule.t.sol:455-461` (`utilization()` unchanged after a donation).
  `SiloRegistry` is the REAL contract with self-consistent topology stubs for `addSilo` (mirror `SiloRegistry.t.sol`'s
  admission setup; the topology assert dereferences freeze/escrow/coordinator/adapter getters).
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02 (`SiloRegistry`, BUILT).
- **Unblocks:** a federation solvency dashboard (FE), the mint kill-switch / circuit-breaker, and CTR-10's
  `ISeniorPool` generalization (which swaps the per-silo read behind an interface).
