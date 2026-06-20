# Entry Point Map

> Hydrex Demo (vAMM) | 16 entry points | 1 permissionless | 4 role-gated | 11 admin/init

Scope: `SzipNavOracleDemoVAMM`, `LpStrategyModuleDemoVAMM`. View/pure functions excluded. Inherited zodiac-core `Module` setters (`setAvatar`/`setTarget`, `onlyOwner`) and `ReceiverTemplate.onReport` (forwarder-gated entry to `_processReport`) noted at the end.

---

## Protocol Flow Paths

### Setup (Deploy / Timelock)

`Module.setUp()` (clone init) → `setOperator()` / `setIchiVault()` / `setGauge()` …  ◄── Timelock build-phase wiring
`Oracle(constructor)` → `setShareToken()` → `setLpPosition()` → `setDefaultCoordinator()` → `setXAlphaRateOracle()`  ◄── re-pointable

### LP lifecycle (Operator)

`[setup above]` → `addLiquidity()`  ◄── tokens in engine Safe
                      ├─→ `stake()`     ◄── LP minted to Safe
                      └─→ `unstake()`   ◄── LP staked in gauge

### NAV pricing (writers + consumer)

`Forwarder → _processReport()` (leg marks)  +  `DefaultCoordinator → writeProvision()`  +  `anyone → poke()`
   └─→ Exit Gate reads `navEntry()` / `navExit()` / `fresh()` / `valueOf()`  ◄── poke() before each read

---

## Permissionless

### `SzipNavOracleDemoVAMM.poke()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Any keeper / the Gate / zap |
| Parameters | none |
| Call chain | `→ _accumulate()` (books spot over [lastUpdate, now] into `cumNav` + ring) |
| State modified | `cumNav`, `obsIndex`, `observations`, `lastUpdate` |
| Value flow | none |
| Reentrancy guard | no (view-only reads inside; no external value transfer) |

---

## Role-Gated

### CRE `operator` (LpStrategyModuleDemoVAMM)

#### `addLiquidity()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyOperator` |
| Caller | CRE operator (hot key) |
| Parameters | deposit0 (operator-provided), deposit1 (operator-provided), minShares (operator-provided) |
| Call chain | `→ _exec(token0.transfer→pair)` `→ _exec(token1.transfer→pair)` `→ _exec(IVammPair.mint(juniorTrancheEngine))` (all via Safe `execAndReturnData`) |
| State modified | none in module (Safe holds LP) |
| Value flow | token0/token1: Safe → pair; LP: pair → Safe |
| Reentrancy guard | no (module writes no storage; Safe is the actor) |

#### `stake()` / `unstake()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyOperator` |
| Caller | CRE operator |
| Parameters | lpAmount (operator-provided) |
| Call chain | stake: `→ _exec(LP.approve(gauge))` `→ _exec(IGauge.deposit)` `→ _exec(LP.approve(0))`; unstake: `→ _exec(IGauge.withdraw)` |
| State modified | none in module |
| Value flow | LP: Safe ⇄ gauge |
| Reentrancy guard | no |

### Forwarder (SzipNavOracleDemoVAMM)

#### `_processReport()` (via `ReceiverTemplate.onReport`)

| Aspect | Detail |
|--------|--------|
| Visibility | internal override (reached via forwarder-gated `onReport`) |
| Caller | Chainlink Forwarder |
| Parameters | report → (reportType, legs[] (keeper-provided), prices[] (keeper-provided), ts (keeper-provided)) |
| Call chain | `→ _accumulate()` `→ per-leg deviation check` `→ set legCache[leg]` |
| State modified | `legCache`, `cumNav`, `obsIndex`, `observations`, `lastUpdate` |
| Value flow | none |
| Reentrancy guard | n/a |

### DefaultCoordinator (SzipNavOracleDemoVAMM)

#### `writeProvision()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, gated `msg.sender == defaultCoordinator` |
| Caller | DefaultCoordinator (M2) |
| Parameters | newProvision (coordinator-provided — **unbounded at the oracle**) |
| Call chain | `→ _accumulate()` `→ provision = newProvision` |
| State modified | `provision`, TWAP accumulator |
| Value flow | none |
| Reentrancy guard | no |

---

## Admin-Only (Timelock `onlyOwner`)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| SzipNavOracleDemoVAMM | `setShareToken()` | szipUSD_ | `shareToken` |
| SzipNavOracleDemoVAMM | `setLpPosition()` | ichiVault_, gauge_ | `ichiVault`, `gauge` |
| SzipNavOracleDemoVAMM | `setJuniorTrancheEngine()` | juniorTrancheEngine_ | `juniorTrancheEngine` |
| SzipNavOracleDemoVAMM | `setDefaultCoordinator()` | dc_ | `defaultCoordinator` |
| SzipNavOracleDemoVAMM | `setXAlphaRateOracle()` | rateOracle_ (zero allowed) | `xAlphaRateOracle` |
| LpStrategyModuleDemoVAMM | `setJuniorTrancheEngine()` | juniorTrancheEngine_ | `juniorTrancheEngine`, `avatar`, `target` |
| LpStrategyModuleDemoVAMM | `setOperator()` | operator_ | `operator` |
| LpStrategyModuleDemoVAMM | `setIchiVault()` | ichiVault_ | `ichiVault` |
| LpStrategyModuleDemoVAMM | `setGauge()` | gauge_ | `gauge` |
| LpStrategyModuleDemoVAMM | `setToken0()` | token0_ | `token0` |
| LpStrategyModuleDemoVAMM | `setToken1()` | token1_ | `token1` |

---

## Initialization

| Contract | Function | Access | Notes |
|----------|----------|--------|-------|
| LpStrategyModuleDemoVAMM | `setUp(initParams)` | `initializer` (zodiac-core) | One-shot clone init; decodes (owner, engine, operator, ichiVault/pair, gauge); reads token0/token1 live off the pair; sets avatar==target==engine; mastercopy init-locked at deploy |
| SzipNavOracleDemoVAMM | `constructor(...)` | deploy | 9 zero-address/zero-value guards; sets immutables + first TWAP observation |

---

## Inherited (out of scope)

| Contract | Inherited entry points | Source |
|----------|------------------------|--------|
| LpStrategyModuleDemoVAMM | `setAvatar`, `setTarget` (`onlyOwner`), `enableModule`/`disableModule` (on the Safe) | zodiac-core `Module` |
| SzipNavOracleDemoVAMM | `onReport` (forwarder-gated wrapper around `_processReport`) | `ReceiverTemplate` |

*Note: `setAvatar`/`setTarget` are intentionally not hard-locked (vendored zodiac kept pristine); only the Timelock owner can call them — the operator cannot (`LpStrategyModuleDemoVAMM:167-170`).*
