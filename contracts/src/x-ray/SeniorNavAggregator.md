# X-Ray — `SeniorNavAggregator.sol` (single-contract, test-connected)

> SeniorNavAggregator | 85 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)*

Per-contract X-Ray for `contracts/src/SeniorNavAggregator.sol` (CTR-05), the **donation-immune Σ of senior
par-backing** across every registered silo — solvency *telemetry* (Σ backing vs zipUSD supply) and the input to any
circuit-breaker, **not a pricing oracle** (zipUSD still mints by value and redeems at par). Pure view + Timelock
wiring; holds no funds, transfers nothing. Exercised by `SeniorNavAggregator.t.sol` — **20 unit tests** (mock
`ISeniorPool` + `SiloRegistry`).

> The whole contract exists to make one number un-manipulable by outsiders: senior backing summed across N pools.
> The trick is the **§8.2 donation-immune read** — per silo, `convertToAssets(balanceOf(warehouseSafe))`, NEVER
> `balanceOf(eePool)`. A stray-USDC donation to a pool address moves neither `convertToAssets` nor `maxWithdraw`, so
> nobody can inflate (or deflate) the aggregate by sending tokens. The guards are lifted VERBATIM from
> `DurationFreezeModule:295-302`, so the aggregate agrees with the freeze module's per-silo math by construction.

## 1. What it is

An 85-nSLOC `Ownable` (Timelock) pure-view aggregator over the CTR-02 `SiloRegistry`. Two wiring slots (`registry`,
`zipUsd`, both MAY be zero at deploy — deploy-order flexibility; the reads revert until wired). Per silo it computes
two donation-immune values and sums them three ways:

- **`_seniorValue`** = `convertToAssets(balanceOf(warehouseSafe)) × 1e12` (USDC 6→18-dp); `sa == 0 → 0`.
- **`_illiquidValue`** = `(sa − free) × 1e12` where `free = maxWithdraw(warehouseSafe)`; `sa == 0 → 0`, `free >= sa → 0`.
- **`seniorBacking()`** / **`illiquidSeniorValue()`** sum ALL silos (retired silos still back the zipUSD their open lines minted — a drained silo contributes 0 with no special case); **`activeSeniorBacking()`** sums only `active` silos (routable-capacity view).
- **`collateralization(supply)`** = `seniorBacking() × 1e18 / supply`; `supply == 0 → type(uint256).max` (no zipUSD ⇒ not insolvent — a breaker reading `< threshold` must NOT trip). **`systemCollateralization()`** = the live form over `zipUsd.totalSupply()`.
- per-silo dashboard getters (`seniorBackingOf` / `illiquidSeniorValueOf`) — unknown silo (`eePool == 0`) → 0.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `seniorBacking` / `activeSeniorBacking` / `illiquidSeniorValue` | public view | aggregate Σ (all / active-only / lent-out); `RegistryUnset` until wired |
| `collateralization(supply)` / `systemCollateralization()` | public view | ratio; `supply==0 → max`; live form reverts `ZipUsdUnset` until wired |
| `seniorBackingOf(id)` / `illiquidSeniorValueOf(id)` | public view | per-silo; unknown → 0 |
| `setRegistry` / `setZipUsd` | `onlyOwner` (Timelock) | `ZeroAddress`-guarded re-points; emit `WiringSet` |
| `constructor(registry_, zipUsd_)` | deploy | both may be zero (deploy-order flexibility) |

No mutator beyond the two wiring setters; no funds, no custody.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **donation immunity** — the aggregate reads `convertToAssets(balanceOf(warehouseSafe))`, never `balanceOf(eePool)`; a stray donation cannot move it | Yes | **`test_donation_immune`** |
| I-2 | **Σ across silos** — single-silo identity + two-silo sum | Yes | **`test_n1_identity`**, **`test_twoSilo_sum`** |
| I-3 | **retired silos still counted in `seniorBacking`; dropped from `activeSeniorBacking`** | Yes | **`test_retired_stillCounted_droppedFromActive`** |
| I-4 | **drained/empty silo contributes 0** (`sa == 0 → 0`, no special case) | Yes | **`test_drained_silo_zero`** |
| I-5 | **illiquid = sa − free, with the verbatim guards** (`sa==0→0`, `free>=sa→0` for both `==` and `>`) | Yes | **`test_illiquid_matches_formula`** (all three branches) |
| I-6 | **collateralization math + zero-supply → max** (the breaker-must-not-trip case) | Yes | **`test_collateralization_math`** (100%/50%/`supply==0→max`) |
| I-7 | **systemCollateralization wired vs `ZipUsdUnset`** | Yes | **`test_systemCollateralization_wired`**, **`_zipUsdUnset_reverts`** |
| I-8 | **`RegistryUnset` until wired** | Yes | **`test_registryUnset_reverts`** |
| I-9 | **per-silo getters: unknown silo → 0** (never calls into `address(0)`) | Yes | **`test_perSilo_unknown_zero`** |
| I-10 | **CTR-10b venue-agnostic** — a non-Euler venue's `ISeniorPool` surface plugs in | Yes | **`test_ctr10b_nonEuler_venue_plugs_in`** |
| I-11 | **wiring setters** — `onlyOwner` + `ZeroAddress` + effect/`WiringSet`; ctor accepts zero for both | Yes | **`test_setRegistry_happy`/`_zero_reverts`/`_onlyOwner`**, **`test_setZipUsd_*`** (3), **`test_ctor_acceptsZeroForBoth`** |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `RegistryUnset` (aggregate reads) | `:75,:86,:96,:124,:133` | `test_registryUnset_reverts` |
| `ZipUsdUnset` (live ratio) | `systemCollateralization:115` | `test_systemCollateralization_zipUsdUnset_reverts` |
| `sa == 0 → 0` / `free >= sa → 0` (per-silo) | `_seniorValue:55`, `_illiquidValue:64,66` | `test_drained_silo_zero`, `test_illiquid_matches_formula` |
| `supply == 0 → max` | `collateralization:108` | `test_collateralization_math` |
| `eePool == 0 → 0` (per-silo getters) | `:126,:135` | `test_perSilo_unknown_zero` |
| `setRegistry`/`setZipUsd` onlyOwner + `ZeroAddress` | `:142,:149` | `test_setRegistry_*`, `test_setZipUsd_*` |

Every read path, every guard, every edge branch, and both setters are exercised — no untested surface.

## 5. Attack surfaces

- **Donation immunity is the entire security claim — and it's directly proven (I-1).** A solvency aggregate that read
  `balanceOf(eePool)` could be inflated by anyone sending USDC/shares to a pool; this one reads the
  warehouse-safe-owned position via `convertToAssets`/`maxWithdraw`, which a donation cannot move. `test_donation_immune`
  confirms the aggregate is unchanged under a stray donation. The math is verbatim from `DurationFreezeModule`, so
  the two never disagree.
- **It is telemetry, not pricing (by design).** zipUSD mints by value and redeems at par regardless of this number;
  the aggregate feeds a circuit-breaker / dashboards. The `collateralization(0) → type(uint256).max` choice (I-6) is
  the load-bearing safety detail: with no zipUSD outstanding the system is *not* insolvent, so a breaker reading
  `ratio < threshold` must not trip — tested explicitly.
- **Retired-silo accounting is intentional (I-3).** Retired silos still back the zipUSD their still-open lines
  minted, so `seniorBacking`/`illiquidSeniorValue` include them; only the routable-capacity view (`activeSeniorBacking`)
  filters on `active`. A drained retired silo contributes 0 via the donation-immune math with no special case.
- **Venue-agnostic (CTR-10b, I-10).** The per-silo read is against `ISeniorPool` (the `{balanceOf, convertToAssets,
  maxWithdraw}` surface), so a non-Euler venue's senior surface plugs in unchanged — proven with a non-Euler mock.
- **No funds, no custody, no pricing authority.** The contract writes only its two wiring slots and transfers
  nothing; the worst an outsider can do is read. Build-phase mutable wiring (`registry`/`zipUsd`, frozen pre-prod) is
  the subsystem-wide residual — both setters are `onlyOwner` + zero-guarded and fully tested.
- **Inherent trust:** the `SiloRegistry` catalog it loops and the `ISeniorPool` 4626 math are upstream; a wrong
  registry entry would mis-sum, but the registry is itself gated (see `SiloRegistry`, separate X-ray) and re-pointing
  it is `onlyOwner`.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Aggregate reads (sum / active filter / illiquid / donation / drained / n1) | 6 | `test_twoSilo_sum`, `_retired_*`, `_illiquid_matches_formula`, `_donation_immune`, `_drained_silo_zero`, `_n1_identity` |
| Collateralization (math / wired / unset) | 3 | `test_collateralization_math`, `_systemCollateralization_wired`, `_zipUsdUnset_reverts` |
| Per-silo getters / RegistryUnset / CTR-10b | 3 | `test_perSilo_unknown_zero`, `_registryUnset_reverts`, `_ctr10b_nonEuler_venue_plugs_in` |
| Wiring setters + ctor flexibility | 7 | `test_setRegistry_*` (3), `test_setZipUsd_*` (3), `_ctor_acceptsZeroForBoth` |

Coverage % uninstrumentable (project-wide `Stack too deep`); 20 unit tests green. Every read, guard, edge branch, and
setter is exercised; the donation-immune property — the reason the contract exists — is directly proven. No coverage
gap.

## X-Ray Verdict

**HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)* — a pure-view senior-solvency telemetry
aggregator whose decisive property (donation immunity) is directly proven, whose per-silo math is verbatim from the
freeze module (so they never disagree), and whose every read path, guard, edge branch (drained / fully-liquid /
zero-supply-→-max), venue-agnostic plug-in (CTR-10b), and both Timelock setters are tested. It holds no funds, prices
nothing, and writes only two wiring slots. No coverage gap; the only residuals are the deferred pre-prod immutable
re-freeze of the build-phase wiring (both setters are `onlyOwner` + zero-guarded) and the absence of an external
audit.

**Structural facts:**
1. 85 nSLOC; `Ownable` (Timelock) pure-view aggregator over `SiloRegistry`; holds no funds, transfers nothing, writes only `registry`/`zipUsd`.
2. Donation-immune per-silo read (`convertToAssets(balanceOf(warehouseSafe))`, never `balanceOf(eePool)`) — verbatim from `DurationFreezeModule:295-302`.
3. Telemetry, not pricing: `collateralization(0) → type(uint256).max` so a breaker can't false-trip with no zipUSD outstanding; retired silos counted in backing, filtered only from the active view.
4. CTR-10b venue-agnostic via `ISeniorPool` — a non-Euler senior surface plugs in.
5. Tests: 20 unit covering every read/guard/edge/setter + the donation-immunity proof + the non-Euler plug-in. No gap; capped only by the pre-prod re-freeze + no audit.
