# SYSTEM-SEAM-MAP — protocol interconnectedness (cross-contract)

> **Truth source = the kept code under `contracts/` + the per-component `wires/` docs.** This map is *derived*:
> it stitches the cross-contract (`X-N`) and economic (`E-N`) seam blocks from the per-contract X-Rays
> (`contracts/src/**/x-ray/`) onto the wiring edges in this folder. Where it disagrees with `contracts/`, the
> code wins. Authored from the X-Ray pass (bridge / loss / CreditWarehouse / hydrex-demo + the
> szipUSD portfolio) + `8-B4-SzipNavOracle.md` and the `interfaces/` dependency surface.

## What this is (and is not)

Per-contract X-Rays audit **nodes**. Protocols fail at **seams** — the joints where one contract's *guarantee*
meets another's *assumption*. This map is the seam layer: the value/price/trust graph, a **seam ledger** (every
joint, with "producer guarantee ↔ consumer assumption ↔ where it's enforced"), and the systemic blast-radius
analysis. It does NOT re-derive node internals — see each contract's `x-ray/` for that.

**Method:** every `On-chain=No` X-N block in a node's invariant map *is* a seam — it literally says "this contract
trusts something it does not itself enforce." Collect them, find the other side of each joint, and check whether
the producer's guarantee matches the consumer's assumption.

> **Update 2026-07-31:** revised for the Octane audit response (commit `7551f5b`) + the bridge Phase-0 hardening
> (`bridge/SN46-BRIDGE-MVP-V2.md`, working tree). Material changes: S1/S3 semantics (the 964 rate now FAILS
> CLOSED on vanished backing — a drift incident becomes a stale feed, not a ~0 price), two NEW seams (S14 the
> CRE no-push-on-revert producer contract, S15 the SEC/H-1 fair-LP funding gate), S10 gains the rate-staleness
> fence, and the hub's HYDX/oHYDX legs are now marked $0 in NAV.

---

## 1. The hub — `SzipNavOracle` (the systemic single point)

Everything that moves value prices off NAV. The oracle is the one contract whose inputs are the protocol's
*aggregate* attack surface and whose output feeds every value decision.

**Inputs NAV reads** (`grossBasketValue()` + legs, per `8-B4-SzipNavOracle.md`):
- raw `balanceOf` of the **main + sidecar Safes** for the plain legs — zipUSD/USDC/xALPHA valued; **HYDX + oHYDX
  (+ veHYDX) marked $0 since 2026-07-31** (emission value recognized only on realized stable proceeds; the
  HYDX/USD push feed is kept to price LP reserves + as the exercise-profitability input)
- the **escrow-collateralized ICHI LP** (counted in place) **minus farm utility strike debt**
- the **xALPHA rate** — from the wired Base `SzAlphaRateOracle` (CRE-pushed from 964), else the M1 stand-in
- the **impairment provision** — written only by `DefaultCoordinator`

**Consumers NAV feeds** (its blast radius):

| Consumer | Reads | Used for |
|---|---|---|
| `ExitGate` | `navEntry()` = max(spot,twap) | issuance mint (rounds shares down) |
| `ExitGate` / `SzipBuyBurnModule` | `navExit()` = min(spot,twap) | exit / buy-and-burn bid price |
| `SzipBuyBurnModule` | `oldestRequiredLegTs()` | CoW order `validTo` freshness fence (SEC-13) |
| `DurationFreezeModule` | `committedValue()` + `pathLockedLpEquity()` | the solvency coverage floor gating outflow |
| `DefaultCoordinator` | (writes) `writeProvision()` | mark down NAV on a recognized loss |

**Blast radius:** a wrong input *anywhere upstream* — a donation into a counted Safe, a stale/bad xALPHA rate, a
mis-bounded provision, an LP mis-price — propagates through NAV into issuance, exit, the buy-and-burn bid, AND the
freeze floor simultaneously. **This is the #1 whole-protocol review target.** The per-contract X-Ray of
`SzipNavOracle` itself is still PENDING (it is the highest-value drill not yet done).

---

## 2. Seam ledger

Each row is a joint between two components. **Enforcement** column: `on-chain` (both sides coded), `off-chain`
(trusted actor/config), `build-phase` (Timelock-mutable until the deferred pre-prod immutable re-freeze),
`deploy-topology` (correctness depends on a deploy choice, not runtime code). Sourced X-N/E-N IDs in brackets.

| # | Producer → Consumer | The joint (guarantee ↔ assumption) | Enforcement |
|---|---|---|---|
| S1 | Subtensor precompile → `SzAlpha` | mint/redeem use the *measured* stake/balance delta; the **sign** AND the **vanished state** (`supply>0 && stake==0` → `BackingVanished`, the Rubicon drift class) are guarded, the **magnitude** is trusted runtime [bridge X-1, both directions tested] | off-chain (runtime) + on-chain (vanished) |
| S2 | `SzAlpha.exchangeRate` → `SzAlphaRateOracle` → `SzipNavOracle` | the bridged rate stays truthful **iff** 964 supply is *locked, not burned* + decimals==18 [bridge E-1] | deploy-topology |
| S3 | `SzAlphaRateOracle.fresh()` → `SzipNavOracle.navEntry` | a stale cross-chain rate must **not** mint; issuance reverts `StaleRate`, exit prices last good (the §7 asymmetry). Since Phase 0 this seam also carries the CATASTROPHIC-VALUE case: a vanished-backing 964 rate REVERTS at the producer, so it arrives here as staleness (fail-closed via `fresh()`), never as a ~0 price — the "bad push is a stale push" assumption now actually holds for the zero class; a well-formed wrong-VALUE push remains DON-trust (S4) | on-chain |
| S4 | CRE Forwarder → every `ReceiverTemplate` (rate oracle, NAV, `DefaultCoordinator`, `WarehouseAdminModule`, engine modules) | each report path is Forwarder-gated; CRE is trusted for magnitude/timing, bounded to *grief* per-contract [loss X-1] | off-chain (correlated) |
| S5 | `DefaultCoordinator` → `SzipNavOracle.provision` | DC guarantees the provision bound on-chain (down by `atRisk·(1−floor)`, heal by receipts, floored at 0) [loss E-1]; NAV gates the writer to DC-only [demo X-1] | on-chain (both sides) |
| S6 | `DefaultCoordinator` ↔ `LienXAlphaEscrow` | escrow is `onlyCoordinator`; bonds flow only to originator/treasury/engine — destination integrity, absolute only once sinks are immutable [loss X-2] | build-phase |
| S7 | counted Safes / LP venues → `SzipNavOracle.grossBasketValue` | NAV prices raw `balanceOf` + spot LP reserves; a direct **donation** into a counted Safe moves NAV with no deposit — the Gate's denominator is the only tie-back [demo I-1/I-2] | off-chain (design) |
| S8 | `SzipNavOracle` → `ExitGate` | bracket fail-closed: `navEntry()` reverts on stale (pause issuance); Gate mints down-rounded and is the **first-depositor guard** NAV delegates | on-chain + Gate-discipline |
| S9 | `SzipNavOracle` → `DurationFreezeModule` | coverage floor = `committedValue+pathLockedLpEquity`; `release` cannot drop below it; LP counted in place (the demo notes a split-LP drift of up to `floor(px/1e18)+4` wei — ≤2 only at a $1.00 xALPHA mark) [demo I-4] | on-chain |
| S10 | `SzipNavOracle` → `SzipBuyBurnModule` | the buy-and-burn bid is priced at `navExit()` and fenced to `oldestRequiredLegTs()` (`validTo`) — no stale-mark bid; since `7551f5b` the fence also honors the RATE ORACLE's own `maxStaleness()`, so a bid can never outlive the rate that priced it (closed the 18h stale-live window) | on-chain |
| S11 | `WarehouseAdminModule` → Roles scope → Warehouse Safe → `EulerEarn` | the **real** param-pinning is the Roles **scope config**, not the module bytecode [warehouse X-1]; `warehouseSafe` must equal the modifier's `avatar` [warehouse X-2] | off-chain scope + on-chain* |
| S12 | `EulerEarn` shares → senior NAV (`SeniorNavAggregator` via `ISeniorPool`) | senior par read is donation-immune (`convertToAssets`/`maxWithdraw`, never `balanceOf(pool)`) — every venue must satisfy this contract | on-chain (interface contract) |
| S13 | engine module fleet → shared engine/main Safe(s) | many Zodiac modules `enableModule`'d on shared Safes; the **module set** is the access control and it spans contracts | on-chain (Safe) |
| S14 | `SzAlpha.exchangeRate` (reverting) → `cre/szalpha-rate` job → `SzAlphaRateOracle` | a REVERTING 964 read means **no push** — never "push 0" (the `ZeroRate` guard is the last-line tripwire). The whole S3 fail-closed conversion rests on the job honoring this; it is a SPEC requirement on a job that does not exist yet [`SN46-BRIDGE-MVP-V2.md` §B5]. Companion: `ts` is the DON push time (`runtime.Now()`), never 964 block time | **off-chain (job spec, UNBUILT)** |
| S15 | `SzipNavOracle.lpTwapWindow`/`ichiVault`/`gauge` → `LpStrategyModule.addLiquidity` | LP may enter the counted Safe ONLY while the oracle prices THIS vault off its fair-reserves TWAP (SEC/H-1): unwired oracle / window==0 / vault-or-gauge mismatch all fail closed. `addLiquidity` is the sole minter of new counted LP, so this one gate closes the in-block spot-LP mint at the FUNDING boundary (the read-path bracket, S7/S8, stays the pricing defense) | on-chain |

*S11 avatar-parity is now integration-tested (`test/WarehouseAdminModule.t.sol::test_Parity_*`) — fail-closed proven.

---

## 3. The four systemic seam-classes

The 15 seams collapse into four recurring whole-protocol patterns. Audit each *class* once.

1. **The NAV hub (S2,S3,S5,S7–S10).** Every value decision prices off `SzipNavOracle`; its inputs (raw Safe
   balances, LP marks, the xALPHA rate, the provision) are the aggregate attack surface. The bracket
   (`max`/`min` of spot vs TWAP) + freshness gates are the defenses; the donation seam (S7) is the one with no
   on-chain bound (mitigated only by the Gate being the first/round-down minter). **Drill `SzipNavOracle` next.**
2. **The CRE driver (S4).** One Forwarder/operator pattern across bridge, loss, warehouse, and all engine
   modules. Each is bounded to *grief* locally, but a CRE compromise fires them **correlated** — simultaneous
   down-marks, ill-timed redeems, healthy-bond slashes. Audit the per-contract grief ceilings, then the
   aggregate.
3. **Build-phase mutable wiring (S6, S11, + every setter in every contract).** The protocol-wide residual: all
   cross-component pointers are Timelock-re-pointable until the deferred pre-prod immutable re-freeze. This is a
   **process gate, not on-chain enforced** — one freeze closes it everywhere, or nowhere.
4. **Shared Safes / module sets (S13).** The engine Safe(s) custody the basket; the set of modules enabled on
   them *is* the access control. A wrong `enableModule`/`disableModule` or a mis-scoped Roles instance is a
   cross-contract authority change invisible to any single node X-Ray.

---

## 4. Value flow (follow the money)

```
TAO ─SzAlpha.deposit─▶ staked alpha (964)  ──CCT lock/release──▶  szALPHA on Base (mirror)
USDC ─ZipDepositModule─▶ main Safe basket ─ExitGate.issueFor─▶ Loot(gate)+szipUSD(user)   [priced at navEntry]
main basket ──engine modules (LP/loop/harvest/exercise/sell/recycle)──▶ oHYDX yield ──▶ free value (RecycleModule ledger)
junior loss ─DefaultCoordinator─▶ LienXAlphaEscrow ──slash──▶ treasury Safe (capital) / engine Safe (cohort premium)
exit:  holder SELL szipUSD on CoW  ◀─bid─ SzipBuyBurnModule (USDC from warehouse redeem) ─ExitGate.burnFor─▶ supply ↓   [priced at navExit]
senior: USDC ─WarehouseAdminModule→Roles→Safe─▶ EulerEarn shares (back zipUSD float) ─OffRamp/RedemptionQueue─▶ par USDC out
```

Every `─▶` that crosses a contract boundary is a seam in §2. The two value *exits* (buy-and-burn retire, senior
par redemption) both price off NAV (S8/S10) — so NAV correctness is solvency.

## 5. Price flow (follow the price)

```
Subtensor getStake ─(magnitude trusted S1)─▶ SzAlpha.exchangeRate ─(CRE push S2/S3)─▶ SzAlphaRateOracle
ICHI/Algebra reserves ─(fair-LP, FairLpOracle)─▶ LP mark ─┐
CRE leg push (alphaUSD, HYDX/USD) ───────────────────────┼─▶ SzipNavOracle.grossBasketValue ─provision(S5)─▶ spot/TWAP
raw Safe balanceOf (donation seam S7) ───────────────────┘                                   │
                                                                     navEntry(max)──▶ ExitGate issuance (S8)
                                                                     navExit(min) ──▶ BuyBurn bid (S10) / exit
                                                                     committed+LP ──▶ DurationFreeze floor (S9)
```

One contaminated price input fans out to **four** value sinks. The defenses are layered: fair-LP math (LP),
freshness + shape/monotonicity guards (CRE legs), the lock/release topology (rate), the DC bound (provision), and the
spot/TWAP bracket (everything). The only input with no on-chain bound is the raw-balance donation seam (S7).

**Changed 2026-07-31 — the CRE-leg layer is no longer a magnitude defense.** The `maxDeviationBps` deviation band
was removed from `SzipNavOracle` and `SzipNavOracleDemoVAMM`. A per-push band on a
SPOT feed rejects the truth — an 11% real move cannot be published against a 10% band — and the CRE producer's
`bandClamp` workaround pushed the band EDGE, i.e. a knowingly-wrong number, silently. Magnitude is now guarded at the
**source**: the CRE publishes a TWAP of the subnet-46 pool reserves, so an implausible jump never arises. It is
**not** replaced by another on-chain check. What survives on the leg-push path is shape, timing, and identity
(`InvalidReportType`, `LengthMismatch`, `FutureTimestamp`, `InvalidLeg`, `ZeroPrice`, `StaleReport`, Forwarder-only +
author/workflow identity). `StaleReport` (strictly-newer) is correspondingly *more* load-bearing — it catches the
same-price backdated replay a magnitude check never could.

---

## 6. Residual ledger — what is NOT enforced on-chain today

| Residual | Seams | Closes when |
|---|---|---|
| CRE magnitude/timing trusted (grief-bounded) | S1, S4, S5(value) | by design (§13) — DON consensus + per-contract bounds are the control |
| Cross-chain conservation = deploy choice | S2 | item-10 deploy wires the lock/release pool on 964 + asserts decimals==18 |
| Donation into a counted Safe moves NAV | S7 | by design — the Gate's denominator + round-down absorb it; verify the Gate side |
| Build-phase wiring re-pointable | S6, S11, S13 | the deferred pre-prod **immutable re-freeze** (process step). The re-freeze list MUST include `DefaultCoordinator.recycleModule`: it is the one slot whose re-point INFLATES NAV (`settleFromJunior` retires markdowns on the wired caller's word — the cash proof lives in `RecycleModule`), where every other lever redirects or griefs |
| `juniorTrancheEngine == juniorTrancheSafe` is a deploy convention, not an on-chain invariant (seam-class 3) | S6, S13 | one equality check in `setJuniorTrancheEngine` + a deploy assert. **Partially closed:** the check exists on `SzipNavOracle` (`01efa48`) and on `RecycleModule` (2026-08-05 — the module where a desync retires markdowns against uncounted cash); the other engine modules' `setJuniorTrancheEngine` setters remain zero-check-only |
| Roles scope is the real warehouse boundary | S11 | the deployed scope tree (audit it directly; parity now tested) |
| CRE rate job: reverting read = no push, never "push 0" | S14 | **BUILT 2026-08-02, NOT DEPLOYED.** `cre/szalpha-rate` enforces it: a reverting `exchangeRate()` read returns a loud errored run and never reaches the encode path, pinned by `TestSimRevertingReadNoPush`. Closes on deploy of the job + the Base `SzAlphaRateOracle`. |
| Hotkey-drift DETECTION latency (the halt is on-chain; the alarm is not) | S1 | **BUILT 2026-08-02, NOT RUNNING.** `cre/szalpha-watch` — the 4 alarms (a reverting rate classified as alarm-1-equivalent, not a script error) + `hotkey_swap_watch.py` for the `HotkeySwappedOnSubnet` subscription (untested against the live chain). Closes when it runs against the production wrapper with a real paging channel — required before the second depositor. |
| The xALPHA rate leg is unbanded on both sides: `SzAlphaRateOracle` publishes what it is given, and `SzipNavOracle` multiplies it in without a consumer-side bound | S3, S4 | a one-directional TWAP on the rate leg, consuming `min(spot, twap)` so a downward move still lands instantly. Ratified 2026-08-02, not yet built |
| `twapNavPerShare()` falls back to `spot` when the accumulator has been idle for `W` | S3, S4 | nothing on-chain. `poke()` is permissionless and books the current spot across the whole gap, so a read-path guard does not close it. Mitigated by keeper liveness, which is an operational assumption. Mechanics and the reverted fix attempt are recorded in the `twapNavPerShare` NatSpec |
| No minimum wall-clock interval between leg pushes | S1, S4 | ruled 2026-08-02: no change. Push frequency only matters against a hostile publisher, which is out of scope per the same ruling |

---

## 7. Verification next steps (ordered)

1. ~~**X-Ray `SzipNavOracle`**~~ — **DONE 2026-07-30**, verdict ADEQUATE
   (`contracts/src/supply/x-ray/SzipNavOracle.md`). All four named items are covered there: the donation seam (S7)
   on the Gate side, the provision writer gate (S5, I-9), the LP/debt accounting (`pathLockedLpEquity()`, I-16
   decomposition identity), and the bracket + freshness logic (I-1, I-5). The **stateful fuzz invariant** on
   `spotNavPerShare()` conservation once listed here as remaining hardening now **exists** —
   `contracts/test/supply/SzipNavOracleInvariant.t.sol`, a 10-action `targetContract` handler carrying 7
   `invariant_*` properties (incl. `invariant_spotNavConservation`) plus 1 deterministic pin, green at 12,800 calls
   per invariant with 0 reverts over an unconstrained `[0.01e18, 100e18]` price walk. What remains on the keystone
   is the external audit.
2. **Audit the deployed Roles scope tree** (S11) — the warehouse's real control lives off-chain; the bytecode is proven.
3. ~~**Cross-module integration / invariant tests** for one full flow~~ — **DONE 2026-08-02.** The deliverable was
   one fork harness wiring the REAL `SzipNavOracle` into `RecycleModule`, `DefaultCoordinator`, `LienXAlphaEscrow`,
   `DurationFreezeModule` and `ExerciseModule` over relaying Safes, replacing mocks that structurally could not
   express cross-module value conservation. It exists and is green. Eight seams were attacked and recorded sound;
   the open items it produced are tracked in the internal work log.
4. **Confirm the pre-prod immutable re-freeze** is scripted (S6/S11/S13) — the single process step that closes the
   protocol-wide build-phase residual.
5. ~~**Aggregate-CRE-compromise review** (S4)~~ — **CLOSED 2026-08-02 BY RULING, not by test.** A publisher that
   lies is out of scope: it already controls provisions, every NAV mark, and the senior draw, so the protocol is
   lost before any single lane matters and bounding one more buys nothing. `WarehouseAdminModule` was separately
   confirmed to route no value to a publisher-named address. The follow-on multi-receiver adversarial harness that
   this item used to require is **cancelled** under the same ruling. Every residual still listed above is reachable
   with an honest publisher.

## Provenance

| Seam source | File |
|---|---|
| bridge X-1, E-1 | `contracts/src/bridge/x-ray/invariants.md` |
| loss X-1, X-2, E-1 | `contracts/src/loss/x-ray/invariants.md` |
| warehouse X-1, X-2, X-3 | `contracts/src/supply/CreditWarehouse/x-ray/invariants.md` |
| NAV provision/donation/bracket (demo proxy for prod) | `contracts/src/hydrex-demo-fork/x-ray/invariants.md` |
| hub inputs/consumers | `docs/wires/8-B4-SzipNavOracle.md` |
| external trust surface | `contracts/src/interfaces/x-ray/dependency-surface.md` |
| engine fleet skeleton | `contracts/src/supply/szipUSD/x-ray/portfolio-map.md` |

> Pending nodes that would tighten this map: per-contract X-Rays of `SzipNavOracle`, `ExitGate`, and
> `SeniorNavAggregator`/`ZipRedemptionQueue` (the senior exit). Their wire docs are cited above; their `x-ray/`
> deep reads are not yet written.
