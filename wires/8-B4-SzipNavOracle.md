# 8-B4 — SzipNavOracle (wiring map)

> Source of truth = the kept code `contracts/src/supply/SzipNavOracle.sol` (read as the final form).
> Ticket `tickets/sodo/8-B4-szip-nav-oracle.md` + report `reports/8-B4-report.md` are intent only — **code
> wins**. Spec cites `claude-zipcode.md` §7/§12 (+ §4.4 reportType 7, §11/§4.6 provision, §17 W/genesis).

## Role
The szipUSD junior-vault **NAV-per-share pricing primitive** — NAV is **not** display-only; both issuance and
exit price off it. It composes the junior basket's NAV on-chain across the main + sidecar Safes, CRE-pushes
only the off-chain leg marks it cannot read on Base, and maintains an on-chain cumulative TWAP on `navPerShare`
over a governed window `W`. Consumers read a **bracketed** 18-dp share price (`1e18 = $1.00`):

- **`navEntry() = max(spot, twap)`** — issuance (Gate mints NAV-proportionally, rounds shares **down**).
  Reverts `StalePrice`/`StaleRate` if a required pushed leg or the wired xALPHA rate is stale ⇒ **staleness
  pauses issuance only**.
- **`navExit() = min(spot, twap)`** — exit (CoW buy-and-burn / windowed reads). **Never** reverts on staleness
  (prices off the last good mark) — the §7 asymmetry, defended by the TWAP lag.

The bracket defends the profitable direction both ways: a one-block spot spike UP only makes minting more
expensive (`max`) and is ignored on exit (`min`); a DOWN spike is ignored on entry. The Gate MUST `poke()`
(permissionless) before every issuance/exit read. The third consumer is the loss side: the
`DefaultCoordinator` writes the recoverable impairment `provision` here (M2), which `spotNavPerShare` subtracts
from gross.

## Contracts involved
| Contract | What it does |
|---|---|
| `SzipNavOracle` (`is ReceiverTemplate`) | The whole primitive. Flat-ctor immutables for the basket tokens + both Safes + W/maxAge/maxDeviationBps; the `_processReport` reportType-7 leg-push path (Forwarder-gated by the base); `poke()`/`_accumulate()` TWAP ring; `grossBasketValue()` + per-leg valuation; `writeProvision` (DC-only); the four wiring setters + the fifth `setXAlphaRateOracle`; the consumer reads `navEntry`/`navExit`/`spotNavPerShare`/`twapNavPerShare`/`fresh`/`valueOf`. |
| `DurationFreezeModule` (8-B / §6.4 freeze) | Reads this oracle's **ADDITIVE** per-Safe views `committedValue()` (= `_grossValueOf(sidecar)`) and `freeValue()` (= `_grossValueOf(mainSafe)`) as the freeze-floor back-pressure. These re-compute one Safe's holdings independently; for the five plain legs `committedValue()+freeValue() == grossBasketValue()` exactly, for a split LP within ≤2 wei. `grossBasketValue()` is unchanged by their addition. |
| `IXAlphaRate` (`contracts/src/interfaces/bridge/IXAlphaRate.sol`) | The `exchangeRate()` face the xALPHA NAV leg reads (LST stake-accounting; non-manipulable in production, M1 stand-in mock). |
| `IXAlphaRateFresh` (declared inline in the .sol) | The `fresh()` face of the wired Base `SzAlphaRateOracle` — issuance gates on it when `xAlphaRateOracle != 0`. |

## Wiring — internal
**Constructor** (`ReceiverTemplate(forwarder)` base):
```
constructor(
    address forwarder, address zipUSD_, address usdc_, address xAlpha_,
    address hydx_, address oHydx_, address mainSafe_, address sidecar_,
    uint32 W_, uint256 maxAge_, uint256 maxDeviationBps_
)
```
All token/Safe addresses + `W_` + `maxAge_` are zero/`0`-guarded (`ZeroAddress`); `maxDeviationBps_` is **not**
guarded (0 = no deviation tolerance is a valid governed value). The ctor seeds `observations[0]=(now,0)` and
`lastUpdate=now`. `forwarder` is zero-guarded by the base and is **Timelock-re-pointable** (`setForwarderAddress`
is NOT renounce-frozen here, §17).

**The basket legs** (summed across `mainSafe` + `sidecar` via `_bal`):
1. `zipUSD` — 18-dp, valued $1 (added as raw balance).
2. `usdc` — 6-dp, scaled `× 1e12` to 18-dp $1.
3. `xAlpha` — `balanceOf × _xAlphaUSD() / 1e18`, where `_xAlphaUSD = IXAlphaRate(rateSrc).exchangeRate() × legCache[LEG_ALPHA_USD].price / 1e18` (the two-layer mark; `rateSrc` resolved below).
4. `hydx` — `balanceOf × legCache[LEG_HYDX_USD].price / 1e18` (pushed leg).
5. `oHydx` — `balanceOf × _oHydxUSD() / 1e18`, intrinsic `= HYDX/USD × (100 − IOptionToken(oHydx).discount())/100` (discount read on-chain).
6. **LP leg** (only if `ichiVault != 0`): held shares = `IICHIVault.balanceOf(mainSafe)+balanceOf(sidecar)+IGauge(gauge).balanceOf(mainSafe)+IGauge(gauge).balanceOf(sidecar)` (unstaked + **staked** off the Hydrex gauge). Reserve share = `getTotalAmounts() × heldShares / totalSupply`, each reserve valued via `_tokenValue`/`_legPriceOfToken` (only `zipUSD`/`xAlpha` accepted — else `UnknownLpToken`, fail-closed). **IL is marked through** (true reserve value). Guarded by `supplyLp != 0`.

**`grossBasketValue()`** sums (1)–(6). **`spotNavPerShare()`** = `(gross − provision) / _effectiveSupply × 1e18`,
returning `GENESIS_NAV (1e18)` at zero effective supply. `_effectiveSupply` = `shareToken.totalSupply −
engineSafe balance` (the transient pre-burn szipUSD excluded), 0 if `shareToken` unset.

**`poke()` / `_accumulate()`** — books the OLD spot over `[lastUpdate, now]` into `cumNav` + the
`CARDINALITY=65` observation ring, idempotent within a block (`dt==0 ⇒ no-op`). Called first inside both
`_processReport` (before applying new prices) and `writeProvision` (before the provision step). `twapNavPerShare`
walks the ring back to the observation at-or-before `now − W`, falling back to `spot` before `W` of history.

**`valueOf(asset, amount)`** — public projection of `_tokenValue`/`_legPriceOfToken` (the issuance valuation
seam the Gate reads; supports `{zipUSD, xAlpha}`, else `UnknownLpToken`). The oracle owns valuation — no caller
asserts a price (§3.4/§7).

**`writeProvision(newProvision)`** — `msg.sender == defaultCoordinator` only (`NotDefaultCoordinator`).
**Unbounded at the oracle by design**: the bound (down ≤ `atRisk×(1−recoveryFloor)`, up by realized receipts)
lives in the DC (M2), which the oracle trusts. Until `defaultCoordinator` is wired it is the zero address ⇒
`writeProvision` reverts for everyone (fail-closed).

**The four wiring setters** (`onlyOwner`, Timelock; each emits an event; all zero-guarded):
- `setShareToken(szipUSD_)` → `shareToken` (the supply denominator).
- `setLpPosition(ichiVault_, gauge_)` → `ichiVault` + `gauge` (the LP reserves + staked-LP source).
- `setEngineSafe(engineSafe_)` → `engineSafe` (the 8-B14 buy-and-burn Safe, denominator-excluded).
- `setDefaultCoordinator(dc_)` → `defaultCoordinator` (the sole `writeProvision` caller).

(A **fifth** setter `setXAlphaRateOracle(rateOracle_)` exists — `onlyOwner`, **not** zero-guarded because
`address(0)` is the valid "use M1 fallback" value. When set, `rateSrc = xAlphaRateOracle` and `navEntry`/`fresh`
additionally gate on its `fresh()`; when zero, `rateSrc = xAlpha` directly.)

## Wiring — cross-component (who points at whom)
- **ExitGate → oracle.** The Gate reads `navEntry()` (mint, round down) and `navExit()` (exit), `poke()`s before
  reading, and is the address passed to `setShareToken` (so the Gate's minted szipUSD becomes the denominator).
  The Gate is the **first minter** (no first-depositor guard here — see Gotchas).
- **DefaultCoordinator → oracle.** Wired in via `setDefaultCoordinator`; it is the **sole** `writeProvision`
  caller, pushing `totalProvision = Σ per-lien provision` after each loss/recovery change (§11/§4.6). The oracle
  stores it unbounded; the DC enforces the bound.
- **8-B14 buy-and-burn engine Safe → oracle.** Wired via `setEngineSafe`; its transient pre-burn szipUSD is
  subtracted in `_effectiveSupply` so a bought-not-yet-burned position cannot dilute navPerShare. (8-B14's
  `SzipBuyBurnModule.engineSafe` is asserted == `ExitGate.engineSafe()`.)
- **LP position (ICHI vault + Hydrex gauge) → oracle.** Wired via `setLpPosition`; before it the LP leg
  contributes 0 (M1 pre-LP). The oracle reads both Safes' vault + gauge balances.
- **DurationFreezeModule → oracle.** Reads `committedValue()`/`freeValue()` (ADDITIVE per-Safe views) as the
  freeze-floor it bounds `release` against — does not write the oracle.
- **CRE Forwarder → oracle.** Pushes reportType 7 `(uint8[] legs, uint256[] prices, uint32 ts)` for
  `{LEG_ALPHA_USD=0, LEG_HYDX_USD=1}`, all-or-nothing, deviation-circuit-broken per leg (`maxDeviationBps`).
- **SzAlphaRateOracle → oracle (production).** Optionally wired via `setXAlphaRateOracle`; supplies the
  cross-chain xALPHA `exchangeRate()` + `fresh()`.

## Item-10 deploy facts (PROGRESS rows 324/326/327/328/329)
- Deploy order: deploy the oracle, then szipUSD/Gate, the LP/gauge, the engine Safe, and the DefaultCoordinator;
  **then call the four wiring setters** `setShareToken` / `setLpPosition` / `setEngineSafe` /
  `setDefaultCoordinator` (Timelock-re-pointable, §17).
- **Assert `shareToken() != 0` before `transferOwnership(timelock)`** — else the oracle is stuck returning the
  genesis price (zero effective supply) forever.
- **`transferOwnership(timelock)` LAST — NOT `renounceOwnership()`** (§17 build-phase: Forwarder/identity/wiring
  stay Timelock-re-pointable; hard immutability deferred to pre-prod). This supersedes the older "renounce-freeze
  at deploy" framing the ticket inherited from the WOOF-02 pattern.
- **8x-02 xALPHA rate-source split (OPEN, superintendent 2026-06-09).** The built oracle originally **conflated**
  rate-source and balance-token: the single immutable `xAlpha` was read BOTH as `IXAlphaRate(xAlpha).exchangeRate()`
  (the rate) AND `IERC20(xAlpha).balanceOf(...)` (the basket balance) — fine in M1 because the stand-in exposed
  both faces. Production splits them: the basket holds `SzAlphaMirror` (a plain `BurnMintERC20`, **no**
  `exchangeRate()`), and the rate comes from a separate Base `SzAlphaRateOracle` (**no** `balanceOf`). The code
  now carries the **`xAlphaRateOracle` seam + `setXAlphaRateOracle`** to read the rate from the distinct oracle
  while `xAlpha` stays the mirror for balances. Because `xAlpha` is **immutable** + single-purpose, swapping the
  *balance* token is not a re-point — it requires a **redeploy** (the oracle is a cheap clone, designed
  replaceable). The 8x-01 "swap mirror in with no surface change" discharge holds for ERC20-balance-only consumers
  (8-B5/8-B6/8-Bx) but NOT for this consumer.

## Gotchas
- **Timelock-re-pointable by design, not set-once.** Every setter (incl. Forwarder/identity on the base) is a
  one-call re-point — a redeployed share token / LP / engine Safe / coordinator / rate oracle does not cascade a
  redeploy. There is **no `AlreadyWired` lockout** on these (the error is declared but unused for the setters).
  Immutability is deferred to pre-prod, per [[oracle-replaceable-timelock-wiring]].
- **No first-depositor guard.** Genesis is the Gate's responsibility: the oracle returns `GENESIS_NAV` only at
  zero effective supply, and the Gate is the first minter (rounds shares down), so a pre-deposit donation cannot
  profit an attacker. The oracle deliberately adds no inflation guard.
- **`navExit` may price off a stale mark (by design).** Staleness/freshness gates `navEntry`/`fresh` only;
  `navExit`/`grossBasketValue` keep pricing off the last good rate. The Gate's `poke()` obligation + the TWAP lag
  (`min(spot, twap)`) are the defense.
- **0.8.24 pin:** guards use `if (!cond) revert CustomError()`, never `require(cond, CustomError())` (≥0.8.26).
- **`maxDeviationBps` is not zero-guarded** in the ctor (0 is a valid governed value); all other ctor args are.
