# SYSTEM-SEAM-MAP — protocol interconnectedness (cross-contract)

> **Truth source = the kept code under `contracts/` + the per-component `wires/` docs.** This map is *derived*:
> it stitches the cross-contract (`X-N`) and economic (`E-N`) seam blocks from the per-contract X-Rays
> (`contracts/src/**/x-ray/`) onto the wiring edges in this folder. Where it disagrees with `contracts/`, the
> code wins. Authored 2026-06-20 from the X-Ray pass (bridge / loss / CreditWarehouse / hydrex-demo + the
> szipUSD portfolio) + `8-B4-SzipNavOracle.md` and the `interfaces/` dependency surface.

## What this is (and is not)

Per-contract X-Rays audit **nodes**. Protocols fail at **seams** — the joints where one contract's *guarantee*
meets another's *assumption*. This map is the seam layer: the value/price/trust graph, a **seam ledger** (every
joint, with "producer guarantee ↔ consumer assumption ↔ where it's enforced"), and the systemic blast-radius
analysis. It does NOT re-derive node internals — see each contract's `x-ray/` for that.

**Method:** every `On-chain=No` X-N block in a node's invariant map *is* a seam — it literally says "this contract
trusts something it does not itself enforce." Collect them, find the other side of each joint, and check whether
the producer's guarantee matches the consumer's assumption.

---

## 1. The hub — `SzipNavOracle` (the systemic single point)

Everything that moves value prices off NAV. The oracle is the one contract whose inputs are the protocol's
*aggregate* attack surface and whose output feeds every value decision.

**Inputs NAV reads** (`grossBasketValue()` + legs, per `8-B4-SzipNavOracle.md`):
- raw `balanceOf` of the **main + sidecar Safes** for the 5 plain legs (zipUSD/USDC/xALPHA/HYDX/oHYDX)
- the **escrow-collateralized ICHI LP** (counted in place) **minus reservoir strike debt**
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
| S1 | Subtensor precompile → `SzAlpha` | mint/redeem use the *measured* stake/balance delta; only the **sign** is guarded, the **magnitude** is trusted runtime [bridge X-1] | off-chain (runtime) |
| S2 | `SzAlpha.exchangeRate` → `SzAlphaRateOracle` → `SzipNavOracle` | the bridged rate stays truthful **iff** 964 supply is *locked, not burned* + decimals==18 [bridge E-1] | deploy-topology |
| S3 | `SzAlphaRateOracle.fresh()` → `SzipNavOracle.navEntry` | a stale cross-chain rate must **not** mint; issuance reverts `StaleRate`, exit prices last good (the §7 asymmetry) | on-chain |
| S4 | CRE Forwarder → every `ReceiverTemplate` (rate oracle, NAV, `DefaultCoordinator`, `WarehouseAdminModule`, engine modules) | each report path is Forwarder-gated; CRE is trusted for magnitude/timing, bounded to *grief* per-contract [loss X-1] | off-chain (correlated) |
| S5 | `DefaultCoordinator` → `SzipNavOracle.provision` | DC guarantees the provision bound on-chain (down by `atRisk·(1−floor)`, heal by receipts, floored at 0) [loss E-1]; NAV gates the writer to DC-only [demo X-1] | on-chain (both sides) |
| S6 | `DefaultCoordinator` ↔ `LienXAlphaEscrow` | escrow is `onlyCoordinator`; bonds flow only to originator/treasury/engine — destination integrity, absolute only once sinks are immutable [loss X-2] | build-phase |
| S7 | counted Safes / LP venues → `SzipNavOracle.grossBasketValue` | NAV prices raw `balanceOf` + spot LP reserves; a direct **donation** into a counted Safe moves NAV with no deposit — the Gate's denominator is the only tie-back [demo I-1/I-2] | off-chain (design) |
| S8 | `SzipNavOracle` → `ExitGate` | bracket fail-closed: `navEntry` reverts on stale (pause issuance); Gate mints down-rounded and is the **first-depositor guard** NAV delegates | on-chain + Gate-discipline |
| S9 | `SzipNavOracle` → `DurationFreezeModule` | coverage floor = `committedValue()+pathLockedLpEquity()`; `release` cannot drop below it; LP counted in place (the demo notes a ≤2-wei split-LP drift) [demo I-4] | on-chain |
| S10 | `SzipNavOracle` → `SzipBuyBurnModule` | the buy-and-burn bid is priced at `navExit` and fenced to `oldestRequiredLegTs` (`validTo`) — no stale-mark bid | on-chain |
| S11 | `WarehouseAdminModule` → Roles scope → Warehouse Safe → `EulerEarn` | the **real** param-pinning is the Roles **scope config**, not the module bytecode [warehouse X-1]; `warehouseSafe` must equal the modifier's `avatar` [warehouse X-2] | off-chain scope + on-chain* |
| S12 | `EulerEarn` shares → senior NAV (`SeniorNavAggregator` via `ISeniorPool`) | senior par read is donation-immune (`convertToAssets`/`maxWithdraw`, never `balanceOf(pool)`) — every venue must satisfy this contract | on-chain (interface contract) |
| S13 | engine module fleet → shared engine/main Safe(s) | many Zodiac modules `enableModule`'d on shared Safes; the **module set** is the access control and it spans contracts | on-chain (Safe) |

*S11 avatar-parity is now integration-tested (`test/WarehouseAdminModule.t.sol::test_Parity_*`) — fail-closed proven.

---

## 3. The four systemic seam-classes

The 13 seams collapse into four recurring whole-protocol patterns. Audit each *class* once.

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

One contaminated price input fans out to **four** value sinks. The defenses are layered: fair-LP math (LP), the
deviation band + freshness (CRE legs), the lock/release topology (rate), the DC bound (provision), and the
spot/TWAP bracket (everything). The only input with no on-chain bound is the raw-balance donation seam (S7).

---

## 6. Residual ledger — what is NOT enforced on-chain today

| Residual | Seams | Closes when |
|---|---|---|
| CRE magnitude/timing trusted (grief-bounded) | S1, S4, S5(value) | by design (§13) — DON consensus + per-contract bounds are the control |
| Cross-chain conservation = deploy choice | S2 | item-10 deploy wires the lock/release pool on 964 + asserts decimals==18 |
| Donation into a counted Safe moves NAV | S7 | by design — the Gate's denominator + round-down absorb it; verify the Gate side |
| Build-phase wiring re-pointable | S6, S11, S13 | the deferred pre-prod **immutable re-freeze** (process step) |
| Roles scope is the real warehouse boundary | S11 | the deployed scope tree (audit it directly; parity now tested) |

---

## 7. Verification next steps (ordered)

1. **X-Ray `SzipNavOracle`** — the hub; not yet done. Confirm: the donation seam (S7) bound on the Gate side, the
   provision writer gate (S5), the LP/debt accounting, the bracket + freshness logic. Highest leverage in the repo.
2. **Audit the deployed Roles scope tree** (S11) — the warehouse's real control lives off-chain; the bytecode is proven.
3. **Cross-module integration / invariant tests** for one full flow (deposit → LP → harvest → loss → exit) — the
   cross-contract value conservation (the §2 edges) is currently proven only node-by-node, never end-to-end.
4. **Confirm the pre-prod immutable re-freeze** is scripted (S6/S11/S13) — the single process step that closes the
   protocol-wide build-phase residual.
5. **Aggregate-CRE-compromise review** (S4) — model all engine + loss + warehouse reports firing correlated under
   one compromised workflow; confirm the union is still bounded to grief.

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
