# zipcode-euler — Run A: role-based pass (one specialist per attack discipline)

_8 parallel role agents (reentrancy, access-control, oracle, economic, arithmetic, dos, mev, proxy),
each sweeping the **whole** codebase for its discipline. Complements the per-subsystem pass
(`findings.md`) — a role agent develops a cross-contract view of its discipline, which is how the new
items below were found. Severities and IDs continue from `findings.md`._

## The headline systemic finding (the role lens surfaced this cleanly)

**Freshness / monotonicity enforcement is inconsistent across all four CRE push-oracle write surfaces.**
Only one of four guards against replay / out-of-order / backdated pushes:

| Oracle write surface | non-zero | not-future | deviation band | **monotonic `ts` guard** | freshness gate exposed |
|---|---|---|---|---|---|
| `SzAlphaRateOracle` (RT8 RATE) | ✅ | ✅ | n/a | ✅ `ts<=latest.ts → StaleReport` | ✅ `fresh()` |
| `SzipNavOracle` leg-cache (RT7) | ✅ | ✅ | ✅ (after 1st) | ❌ **OMITTED** | ✅ on `navEntry` only |
| `ZipcodeOracleRegistry` (RT3) | ✅ | ✅ | ❌ | ❌ **OMITTED** | read-side only |
| `SzipReservoirLpOracle` (RT7) | ✅ | ✅ | ❌ | ❌ **OMITTED** | read-side (fail-closed) |

The reference implementation (`SzAlphaRateOracle.sol:86`) exists *in the same repo* and its own NatSpec
explains why the guard is mandatory — yet three sibling oracles omit it. Fix is one line each:
`if (ts <= prior.timestamp) revert StaleReport();`. This single inconsistency is the root of findings
#1, #3, and the new R1/R3 below.

## NEW findings (not in the subsystem pass)

### R1 — `SzipNavOracle` leg-cache has no monotonic guard → backdated report freezes all issuance
- **MED / high.** `SzipNavOracle._processReport` — `src/supply/SzipNavOracle.sol:286-299`. class: oracle.
- A validly-signed but **out-of-order or replayed** NAV-leg report with the same price and an older
  `ts = now − maxAge − 1` passes every check (`ts<now`; deviation band on price only) and is written
  unconditionally, moving the cached timestamp **backward**. `_legStale` then returns true →
  `navEntry()` reverts `StalePrice`, `fresh()` is false → **all zap/issuance halts and `postBid` reverts
  `StaleNav`.** Protocol-wide DoS with no value manipulation. The leg-cache lacks the guard the sibling
  rate oracle has. **fix:** `if (ts <= prior.ts) revert StaleReport()`.

### R3 — `SzipReservoirLpOracle` has no monotonic guard → reservoir-borrow collateral clock rewind
- **LOW / high.** `src/supply/SzipReservoirLpOracle.sol:104-118`. class: oracle. Out-of-order/replayed
  LP_MARK overwrite resets the staleness clock backward; fail-closed at read (borrow reverts), so worst
  case is liveness/grief on the reservoir loop, not an unsafe open. Same one-line fix.

### R-DoS group — liveness dead-ends and fail-closed traps
- **`lpTwapWindow` misconfig cascade-bricks NAV (LOW-MED).** If the Timelock sets `lpTwapWindow>0`
  against an Algebra pool with no plugin or insufficient observation history, `IchiAlgebraFairReserves`
  reverts (`NoPlugin`/"OLD"), and because `grossBasketValue`→`_lpValue` is on the path, **every** NAV
  read reverts — issuance, exit, `covered()`, and `poke`/`writeProvision` all die. Recoverable
  (`setLpTwapWindow(0)`), but no plugin/cardinality sanity-check exists. `SzipNavOracle.sol:420-421`.
- **Revaluation batch all-or-nothing (LOW).** One malformed lien key (`price==0`/bad decimals) reverts
  the whole RT-3 batch, so every healthy lien in it goes unrefreshed and ages toward `TooStale` →
  fail-closed lending DoS. `ZipcodeOracleRegistry.sol:114-133`.
- **`postBid` unsatisfiable when `maxAge()==0` (LOW).** `validTo>now` ∧ `validTo<=now+maxAge` are jointly
  impossible at `maxAge==0` → exit valve un-armable. Only bites if navOracle is re-pointed to a 0-maxAge
  source (SzipNavOracle ctor forbids it). `SzipBuyBurnModule.sol:299,304`.
- **RESOLVE/WRITEOFF can strand a lien in Defaulted (LOW).** If the CRE supplies
  `capitalSlashAmount > bondAmount`, `slashXAlphaToCapital` reverts `ExceedsBond`, rolling back the whole
  report so the lien can't leave `Defaulted` until re-submitted correctly. `DefaultCoordinator.sol:277,294`.
- **szALPHA sub-rao dust unredeemable (LOW).** `redeem` reverts `ZeroAmount` when `alphaOut18 < 1e9`,
  locking dust balances out of exit. `SzAlpha.sol:228-230`.
- **Junior szipUSD has no on-chain exit (LOW / design note).** `burnFor` is windowController-only and
  pays no assets; holders depend entirely on the trusted windowController + an off-chain CoW buyer. A
  documented design trade-off, surfaced for the liveness lens. `ExitGate.sol:199-206`.

### Informational (doc-vs-reality / hygiene)
- **R9 — `setOperator` peer-guard divergence.** `LpStrategyModule.setOperator` re-checks
  `operator != owner` on re-point; its **7 sibling modules do not**. Only the (trusted) Timelock can
  exploit, so not a break — but a real inconsistency the spec's "`OwnerIsOperator` at every module" wording
  papers over.
- **R10 — Zodiac mastercopies are never init-locked.** Every module's header claims "mastercopy is
  init-locked at deploy"; in fact no constructor/`_disableInitializers` exists and the deploy script never
  `setUp`s the mastercopy → anyone can initialize it. Benign today (CALL-only, not enabled on any Safe,
  no delegatecall/UUPS) but a false safety claim + foot-gun for any future delegatecall variant.
- **R11 — `SzAlphaRateOracle` "no owner / all knobs immutable" is inaccurate.** The *economic* knobs are
  immutable, but it inherits `ReceiverTemplate(Ownable)` with Timelock-mutable Forwarder + workflow
  identity (incl. Forwarder→0 disabling validation), like every other receiver. Correct the §2/§6 wording.

## Cross-confirmations (independently re-derived → high confidence)
- **#2 queue-cap origination brick** — re-derived by the DoS specialist *and verified directly against
  `reference/euler-earn/src/EulerEarn.sol:328` (MAX_QUEUE_LENGTH=30) and `ConstantsLib.sol`*, confirming no
  prune path exists anywhere in `src/`.
- **#3 registry no monotonic guard** — independently hit by the oracle *and* proxy specialists.
- **#6 xALPHA zero-rate** — oracle specialist confirmed and **extended**: the un-gated read also feeds
  `DurationFreezeModule.covered()`/`release()`, so a stale/zero cross-chain rate steers the autonomous
  freeze floor, not just exit pricing.
- **#7 coverage double-count** — economic specialist confirmed and **escalated reachability**: ICHI LP is a
  freely-transferable ERC20, so *any external address* can transfer LP into the sidecar to trigger the
  double-count (it is not gated behind the operator/Timelock as the subsystem pass assumed).

## Verified sound (attacked across the whole codebase, held)
- **Reentrancy:** zero findings. `nonReentrant`+CEI is present exactly on the permissionless / cross-trust
  contracts (ExitGate, escrow, queue, deposit, freeze, SzAlpha) and deliberately/safely omitted on the
  operator-only engine modules (effects-before-interaction, Safe-pinned recipients). The pattern is
  consistent, not a gap.
- **Arithmetic:** zero findings. Every scale factor, cast (uint208/uint136/uint48), 6↔18↔native decimal
  conversion, mulDiv ordering, and rounding direction checks out against integer semantics.
- **MEV:** no profitable unprivileged extraction. The `max/min(spot,twap)` bracket + the buy-burn discount
  `d` + the `maxSellHydx` size cap neutralize the sandwich/flash-skew theses; the CREATE2 lien deploy is
  not front-runnable (caller bound into initcode → distinct address). One transient grief surface only
  (flash-skewing spot LP to flip `covered()` and revert an operator tx — no profit, self-reversing).
