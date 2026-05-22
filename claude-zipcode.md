# zipcode-euler — Technical Scope

> A decentralized home-equity credit protocol. A RESI-incentivized USDC credit pool (built on
> EulerEarn) extends warehouse-style credit lines to KYB'd HELOC originators. Each line is
> collateralized by an on-chain **1/1 lien token** whose price is set by a **Chainlink CRE** workflow
> that fans in a real-estate valuation (Bittensor Subnet 46) plus identity / title / lien / income
> data. Every sensitive on-chain operation is gated so that **only the CRE-driven controller** can
> open a line, price collateral, or move pool funds.

This document is an engineering scope. Reused primitives are cited as `repo/path/File.sol :: fn()`;
net-new contracts are specified down to the interfaces they implement and the reference contract they
are modeled on. All reference repos live under `reference/`.

---

## 1. System overview & component map

```
        USDC LPs (+ RESI liquidity mining)
                  │ deposit
                  ▼
        ┌───────────────────────┐        allocator role (via EVC)
        │  EulerEarn USDC pool   │◀───────────────────────────────┐
        │  (credit pool)         │                                │
        └───────────┬───────────┘                                │
                    │ reallocate(MarketAllocation[])              │
                    ▼                                             │
        ┌───────────────────────┐   collateral    ┌──────────────┴───────────┐
        │ Isolated EVK market    │◀───────────────│  ZipcodeController         │
        │ (per originator/lien)  │   setLTV        │  (CRE receiver / orch.)    │
        │  borrow gated by hook ─┼────────────────▶│  - allocator role          │
        └───────────┬───────────┘  CREGatingHook   │  - router + vault governor │
                    │ getQuote()                    │  - lien mint authority     │
                    ▼                               └──────────────┬───────────┘
        ┌───────────────────────┐                                 │ onReport()
        │ EulerRouter            │  govSetConfig(lien,USDC,reg)    │
        │   → ZipcodeOracleReg.  │◀────────────────────────────────┤
        └───────────────────────┘  cache[lien].price               │ DON-signed report
                                                                    │ (KeystoneForwarder)
                  ┌─────────────────────────────────────────────────┴────────┐
                  │              CRE workflows (Go, cre-sdk-go)              │
                  │  underwriting/origination · revaluation · funding        │
                  └───────────────────────────────┬──────────────────────────┘
                                                   │ HTTP / proofs / consensus
        ┌──────────────────────────────────────────┴───────────────────────────┐
        │ Subnet 46 (appraisal) · Plaid (KYC/income) · Credit Karma (score)      │
        │ Pippin/DART (title/liens) · Reclaim+EigenLayer (zkTLS) · Block Analitica│
        └────────────────────────────────────────────────────────────────────────┘
```

Off-chain (legal/custody, not on the trust path): an **SPV** custodies the perfected lien;
**Fireblocks/Erebor** handle custody and the USD↔stablecoin dollar leg.

> **Supply side is a stand-in here.** This doc shows supplier deposits as plain EulerEarn 4626 shares to
> keep the base loop clean. The actual supply-side design — a 1:1-mint $1 credit dollar (`zipUSD`) +
> staked junior (`szipUSD`) + a 30-day epoch redemption queue — lives in its own exploration spec,
> [`supply-redemption.md`](./supply-redemption.md), and will be merged in during synthesis. It is not a
> deferred phase; the plain-shares view here is just a simplification, not the final design.

---

## 2. Reused on-chain primitives

| Concern | Surface we call | Path |
|---|---|---|
| Credit pool | `EulerEarn :: reallocate(MarketAllocation[])`, `setIsAllocator`, `submitCap/acceptCap` (cap increase timelocked), `setSupplyQueue/updateWithdrawQueue`; roles owner/curator/guardian/allocator | `reference/euler-earn/src/EulerEarn.sol`, `EulerEarnFactory.sol` |
| Pool auth | allocator check resolves caller via EVC `onBehalfOfAccount` (EVCUtil `_msgSenderOnlyEVCAccountOwner`) | `reference/euler-earn/src` |
| Market creation | `GenericFactory :: createProxy(impl, upgradeable, abi.encodePacked(asset, oracle, unitOfAccount))` | `reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol` |
| Deploy reference flow | `EdgeFactory` (vault + IRM + hook + LTV wiring in one shot) | `reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol` |
| Vault governance | `Governance :: setLTV / setInterestRateModel / setHookConfig / setGovernorAdmin / setCaps / setMaxLiquidationDiscount / setLiquidationCoolOffTime` (all `governorOnly`) | `reference/euler-vault-kit/src/EVault/modules/Governance.sol` |
| LTV type | `LTVConfig { borrowLTV, liquidationLTV, … rampDuration }` | `reference/euler-vault-kit/src/EVault/shared/types/LTVConfig.sol` |
| Hook dispatch | `Base :: callHook / invokeHookTarget` — appends 20-byte `caller` to calldata; flags `OP_DEPOSIT=1<<0`, `OP_BORROW=1<<6`, `OP_REPAY=1<<7`, `OP_LIQUIDATE=1<<11` | `reference/euler-vault-kit/src/EVault/shared/{Base.sol,Constants.sol}` |
| Hook interface | `IHookTarget :: isHookTarget() → bytes4`; base impl `BaseHookTarget` | `reference/euler-vault-kit/src/interfaces/IHookTarget.sol`, `reference/evk-periphery/src/HookTarget/BaseHookTarget.sol` |
| Oracle interface | `IPriceOracle :: getQuote / getQuotes` (PULL, view) | `reference/euler-vault-kit/src/interfaces/IPriceOracle.sol` |
| Oracle base | `BaseAdapter` (immutable base/quote, override `_getQuote`, `_getDecimals`) — we return `bid==ask==mid` (the honest equity mark; conservatism lives in the LTV gap, not a synthetic spread) | `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` |
| Router | `EulerRouter :: govSetConfig(base,quote,oracle)` (O(1); upstream has no timelock — zipcode holds the router governor **behind a timelock**, see §3.4/§9), `resolveOracle` | `reference/euler-price-oracle/src/EulerRouter.sol` |
| Decimal math | `ScaleUtils :: calcScale / getDirectionOrRevert / calcOutAmount` | `reference/euler-price-oracle/src/lib/ScaleUtils.sol` |
| **Signed-report oracle pattern** | `RedstoneCoreOracle` — state-changing `updatePrice()` caches `{price, timestamp}`; view `_getQuote` reads cache + enforces `maxStaleness`. We adopt the cache→stale-checked-view *pattern* but set a home-appropriate validity window, **not** its 5-min `MAX_STALENESS_UPPER_BOUND` (§3.1/§7) | `reference/euler-price-oracle/src/adapter/redstone/RedstoneCoreOracle.sol` |
| Adapter whitelist + validation | `SnapshotRegistry :: add/revoke/isValid`; `EulerUngovernedPerspective :: verifyAssetPricing`; `EulerRouterFactory` | `reference/evk-periphery/src/{SnapshotRegistry,Perspectives/deployed,EulerRouterFactory}/` |
| Connector | `EVC :: setAccountOperator / setOperator / call / batch(BatchItem{target,onBehalfOfAccount,value,data}) / getCurrentOnBehalfOfAccount`; single-controller + `checkAccountStatus` | `reference/ethereum-vault-connector/src/EthereumVaultConnector.sol` |
| CRE inbound | `ReceiverTemplate :: onReport(metadata, report) → _processReport`; `_decodeMetadata → (workflowId, workflowName, workflowOwner)`; gated on the **immutable** CRE Forwarder (`s_forwarderAddress`, set once at construction — we drop the setter; a zero address makes `onReport` permissionless, ReceiverTemplate.sol:83) | `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` |
| Data Streams (optional transport) | `VerifierProxy :: verify` (state-changing, charges LINK/native fee via `FeeManager`), RWA report v4/v8. Not required: the regional HPI bound arrives as a CRE HTTP input (§4.1/§5), not via DS | `reference/chainlink-evm/contracts/src/v0.8/llo-feeds/v0.5.1/VerifierProxy.sol` |
| IRM | set via `setInterestRateModel`. **Uses a flat/fixed rate** — `IRMLinearKink(baseRate, 0, 0, kink)` (zero slopes → constant APR, a negotiated credit-line rate, not utilization-floating) | `reference/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol`, `reference/evk-periphery/src` (IRM) |

---

## 3. Net-new contracts

### 3.1 `ZipcodeOracleRegistry` — `is ReceiverTemplate, BaseAdapter`
A **single** multi-asset adapter that prices every lien token, fed by the CRE DON. The cached price is
the lien's **honest equity mark** — `Subnet 46 home value − senior debt ahead of the lien`, in the unit
of account. It is a verified underwriting attestation, not a market quote (a 1/1 lien has no market). It
reports `bid==ask==mid`; the appraisal-error + drift cushion lives in the LTV gap (§3.2/§3.4), not here.

- **Storage:** `address immutable quote` (USDC/unit of account); `mapping(address lien => Cache)` where
  `struct Cache { uint208 price; uint48 timestamp; }`; `uint256 immutable validityWindow` — a
  home-appropriate window of days that we set, **not** RedstoneCoreOracle's 5-min `MAX_STALENESS_UPPER_BOUND`.
- **`_processReport(bytes report)`** (from `ReceiverTemplate.onReport`, immutable-Forwarder-gated):
  decode `(address[] liens, uint256[] prices, uint32 ts)` and write `cache[lien] = {price, ts}` in a loop.
  **Defensive guards (fail closed):** reject `price == 0` (a zero price hits a free-seize path in EVK
  liquidation) and `price > type(uint208).max`; require each lien's decimals/scale to match the value
  pinned at factory deploy (§3.2); apply the **HPI sanity band** — reject/clamp a per-home value that
  deviates beyond a configured band from the regional-HPI input in the report (catches *systematic*
  Subnet 46 model bias the underwriting waterfall cannot). These guards catch code/units bugs and model
  drift, not market manipulation. One DON report → many prices; report ≤ 5 KB caps batch size, shard
  across cohorts above that.
- **`_getQuote(inAmount, base, quote)`** (view, override of `BaseAdapter`): read `cache[base]`, revert
  `PriceOracle_TooStale` if `block.timestamp - ts > validityWindow`, scale via `ScaleUtils.calcOutAmount`,
  return `bid==ask==mid`. Staleness here does **not** gate liquidation — liquidation is delinquency-driven
  (§3.4e), so a stale/fake price alone cannot liquidate.
- **Registration:** `EulerRouter.govSetConfig(lien, USDC, registry)` once per lien (router governor
  timelocked, §3.4) — all liens route to this one instance; one `SnapshotRegistry.add` entry for
  perspective validation.
- **Modeled on:** `RedstoneCoreOracle` (updatePrice→cache→stale-checked view) generalized to multi-asset.

### 3.2 `LienCollateralToken` + `LienTokenFactory`
- 1/1 ERC-20, one instance per lien (EVK collateral must be ERC-20-shaped; no native NFT collateral).
- Holds lien metadata id; `mint`/`burn` restricted to `ZipcodeController`.
- **Decimals pinned to a constant** in the factory (fail closed): `BaseAdapter._getDecimals` silently
  returns 18 on a failed `decimals()` staticcall, so an off-by-decimal is a silent 10× mispricing; pinning
  makes the registry's per-lien scale (§3.1) exact.
- Registered as collateral on the lien's isolated market via `Governance.setLTV(lienToken, borrowLTV, liqLTV, ramp)`.
  The `borrowLTV` vs `liquidationLTV` gap is **where the appraisal-error + drift conservatism lives** — the
  oracle reports the honest equity mark (§3.1), the LTV gap is the cushion.
- Factory deploys deterministically (CREATE2) so the controller/CRE can precompute the address.

### 3.3 `CREGatingHook` — `is IHookTarget`
- `isHookTarget()` validates `msg.sender` is a vault from `GenericFactory` and returns the selector.
- `fallback()` extracts the appended 20-byte caller (`shr(96, calldataload(sub(calldatasize(),20)))`)
  and reverts unless `caller == zipcodeController`.
- Installed via `setHookConfig(hook, OP_BORROW | OP_LIQUIDATE)`. **Repay is deliberately ungated**
  (permissionless): `Borrowing.repay` runs `initOperation(OP_REPAY, CHECKACCOUNT_NONE)` and reduces the
  *receiver*'s debt regardless of caller (`euler-vault-kit/src/EVault/modules/Borrowing.sol :: repay()`),
  so gating it would only block honest paydown without adding protection.
- **Caller semantics (why borrow must come from the controller):** the 20-byte caller EVK appends is the
  EVC `onBehalfOfAccount`, **not** the operator — `Base.initOperation` sets `account =
  EVCAuthenticateDeferred(...)` and passes it to `callHook`, and `invokeHookTarget` appends that same
  `account` (`euler-vault-kit/src/EVault/shared/Base.sol:87,89,132`; `EVCClient.sol:49` returns
  `onBehalfOfAccount`). So `caller == zipcodeController` passes **only when the controller is the
  borrowing account** — i.e. the controller is the on-chain borrower of record (see §3.4).
- **Modeled on:** `BaseHookTarget`.

### 3.4 `ZipcodeController` — `is ReceiverTemplate` (the orchestrator)
The single trusted on-chain identity. Holds: EulerEarn **allocator** role, EulerRouter **governor**
(exercised **behind a timelock** — repointing any lien's oracle then has a delay window to be caught and
vetoed, §9), isolated-market **governor**, lien-token **mint authority**, and is the **gating hook's**
trusted caller for borrow and liquidate (repay is ungated). Its CRE inbound is gated on an **immutable**
Forwarder (`s_forwarderAddress` set once at construction, no setter). **It is also the on-chain borrower
of record:** the
originator is not an on-chain actor in the funding path — they apply and draw via API, the controller
performs every on-chain `borrow`, and the dollar leg (USD wire to the originator, USD collection on
repayment) is handled off-chain by **Erebor** (see §6).

Because EVC enforces a single controller (borrow vault) per account, the controller borrows on a
**dedicated EVC sub-account per isolated market** (sub-account *i* ↔ market *i*); lien token *i* is the
collateral enabled on sub-account *i*. The vault is still per-originator/lien; the *borrowing account* is
the controller's sub-account, not an originator account.

`_processReport` branches on a report-type discriminator:
- **(a) Origination** → `LienTokenFactory.create` (mint 1/1 token) → `EulerRouter.govSetConfig(lien,USDC,registry)` →
  seed `ZipcodeOracleRegistry` price → `setLTV` on the lien's market → `EVC.batch` →
  `EulerEarn.reallocate` pool→market, then `borrow` on the controller's sub-account for that market (the
  hook passes because the borrowing account is the controller). The drawn USDC routes to the Erebor
  off-ramp, which wires USD to the originator.
- **(a′) Draw** → a later draw on an open line is the same `reallocate`+`borrow` step on the existing
  sub-account, driven by a fresh report (each draw re-prices the home and re-checks delinquency). Funding
  is fund-at-draw; there is no idle pre-funded facility.
- **(b) Revaluation** → forward new price into `ZipcodeOracleRegistry` (or registry receives directly).
- **(c) Close/release** → once debt is confirmed zero (repay is permissionless, §6), `burn` the lien
  token (controller mint authority) and emit `LienReleased(lienId)` to signal off-chain SPV release.
  Closing is controller-only even though repaying is not.
- **(d) Default** → mark delinquent/default, apply a **recovery-aware** markdown (toward expected recovery
  = home value × lien position × haircut, **not** a time-linear decay to zero), and emit the legal-action
  event. The continuous markdown and the socialized-lock / RESI / recovery machinery are specified in the
  loss-side spec (`tokenomics-layer.md`); the controller's default branch emits the status + legal-action event.
- **(e) Liquidation** → controller-gated `liquidate` (a 1/1 lien has no liquidator market, so the
  controller is the only liquidator). Resolution may be **MBS absorption**: structure THREE buys the debt
  and the position transfers to an MBS account (deferred — see `vision.md` stage THREE).

---

## 4. CRE workflows (Go, `cre-sdk-go`)

Workflows are authored in **Go** and compiled to `wasip1` (patterns in
`reference/cre-sdk-go/standard_tests/*/main_wasip1.go`). Go is the workflow language; the on-chain write
takes `runtime` as its first positional arg (no signature footgun). Our workflows are deterministic (no
RNG), but the Go SDK's consensus-safe `runtime.Rand()` (`cre/runtime.go:25`) is available if ever needed
(the TypeScript SDK lacked it).

### 4.1 Underwriting / origination / revaluation workflow
- **Trigger:** `http.Trigger(*Config)` (`capabilities/networking/http/trigger_sdk_gen.go:16`, originator
  submits an application) for origination; a **1-day `cron.Trigger`** (`capabilities/scheduler/cron/trigger_sdk_gen.go:16`)
  heartbeat that re-prices open liens (revaluation, §3.4b); plus event-driven re-pricing on draws/status changes.
- **Inputs (fetched per-node, then aggregated):** Reclaim/EigenLayer zkTLS proofs (identity, title, lien
  position), Subnet 46 appraisal, **regional HPI** (the systematic-bias bound, §5), Block Analitica
  LTV/risk params — via `http.Client.SendRequest(nodeRuntime, *Request)`
  (`capabilities/networking/http/client_sdk_gen.go:44`, runs in **node mode**) + `runtime.GetSecret`
  (`cre/runtime.go:35-59`, **DON-Runtime only, not node mode** — so raw PII never enters a consensus
  observation; only proofs/derived bounds do).
- **Consensus:** `cre.RunInNodeMode(...)` (`cre/runtime.go:166`) + `cre.ConsensusMedianAggregation[T]()`
  (valuation/equity) / `cre.ConsensusIdenticalAggregation[T]()` (boolean proof gates)
  (`cre/consensus_aggregators.go:27,33`).
- **Output:** ABI-encode the payload into a `cre.ReportRequest`, `runtime.GenerateReport(req)`
  (`cre/runtime.go:58`) → `evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{Receiver:
  ZipcodeController, Report: report, GasConfig: &evm.GasConfig{...}})`
  (`capabilities/blockchain/evm/client_sdk_gen.go:293`).

### 4.2 Funding / cash-reserve (no optimizer)
There is **no cross-market yield optimizer** — the lien markets are credit lines funded to demand, not
yield venues to optimize across, so the euler-allocator-bot pattern does not apply. "Allocation" is two
deterministic actions:
- **Per-line funding:** the origination/draw report (§3.4a) does `EulerEarn.reallocate` pool→market up to
  the line's supply `cap` (= the credit limit), inline — no separate workflow.
- **Cash-reserve ratio:** keep a reserve fraction of pool USDC un-supplied for LP withdrawals and lend the
  rest to demand — a deterministic rule (optionally a `cron.Trigger` rebalance reading state via
  `evmClient.CallContract`), no RNG, no annealing. Fixed-% vs dynamic (scaling with the pending redemption
  queue) is open (§13).

---

## 5. Off-chain underwriting + proof layer

| Credit question | Source | On-chain surfacing |
|---|---|---|
| Real, ID-verified, not sanctioned? | Plaid (KYC, facecheck, sanctions) | Reclaim proof → boolean gate in report |
| Creditworthy? | Credit Karma (VantageScore 3.0; TransUnion/Equifax) | Reclaim proof → score band |
| Can repay (stable income)? | Plaid (account reads) | Reclaim proof → income ≥ threshold |
| Clean title / unpaid tax? | Pippin Title | Reclaim proof → boolean |
| Lien room / position? | DART + Pippin | Reclaim proof → senior debt, lien position |
| Home value → equity / LTV? | Bittensor Subnet 46 (resi appraisal/AVM) | median consensus → valuation → `ZipcodeOracleRegistry` |
| Regional price sanity (systematic bias)? | HPI API (e.g. FHFA / Case-Shiller) | consensus → band that clamps/rejects the per-home AVM before it becomes the mark (§3.1) |
| Optimal LTV / risk params | Block Analitica | report params → `setLTV` bounds (the borrow/liquidation LTV gap carries the conservatism cushion) |

Cred Protocol / Blockchain Bureau add on-chain-address credit scoring on top of off-chain VantageScore.

---

## 6. Authorization & control-flow trace

**One-time setup** (governor/owner): `EulerEarn.setIsAllocator(controller, true)`;
`EVault.setGovernorAdmin(controller)`; `EVault.setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)` (repay ungated);
`EVault.setInterestRateModel(irm)`; set the **EulerRouter governor to a timelock** and route
`govSetConfig(lien, USDC, registry)` through it; deploy registry/controller with an **immutable** Forwarder
(no setter); `SnapshotRegistry.add(registry, lien, USDC)`; (optional) `EVC.setAccountOperator(poolAccount, controller, true)`.

**Origination path:**
```
CRE underwriting workflow
  → runtime.GenerateReport(req) (f+1 DON sigs)
  → evmClient.WriteReport(runtime, {receiver: ZipcodeController})
  → CRE Forwarder (immutable; verifies DON sigs)
  → ZipcodeController.onReport → _decodeMetadata (workflowId/owner check) → _processReport
       ├─ LienTokenFactory.create(lienId)            // mint 1/1 collateral
       ├─ EulerRouter.govSetConfig(lien, USDC, reg)  // controller is router governor
       ├─ ZipcodeOracleRegistry price seed           // collateral now priceable
       ├─ EVault.setLTV(lien, borrowLTV, liqLTV, 0)  // controller is vault governor
       └─ EVC.batch([
            { EulerEarn.reallocate(...) },            // pool → market (allocator role)
            { EVault.borrow(amount, receiver) }       // onBehalfOf = controller sub-account i
          ])                                          //   ⇒ hook caller == controller (passes)
                                                      //   receiver = Erebor off-ramp; wires USD to originator
```

**Repay path:** originator pays USD to Erebor → Erebor on-ramps USD→USDC → permissionless `EVault.repay`
against the controller's sub-account debt (no hook, no report needed). **Closing is separate:** once the
controller observes debt is zero, a close report burns the lien token and emits `LienReleased` →
off-chain SPV releases the recorded lien.

---

## 7. Oracle architecture & rationale (decision: push-cache)

| Axis | CRE push-cache (chosen) | Data Streams |
|---|---|---|
| Bespoke per-home feed | yes — any asset we define | no — feeds permissioned/standardized only |
| CRE support | yes — native `WriteReport` | no — no DS capability in `cre-sdk-go` |
| Decentralization | yes — f+1 DON sigs | yes — (but only for existing feeds) |
| On-chain read | view read of cache | view read of cache (DS `verify` is tx+fee, can't run in view → still cached) |
| Per-update cost | DON report + 1 EVM tx | LINK/native fee + subscription |
| New asset provisioning | one `govSetConfig` we control | Chainlink Labs negotiation |

Both approaches are cache-then-view underneath; the only real difference is who signs/provisions.
**Push-cache via CRE is the only option that supports per-home pricing, is CRE-native, stays
DON-decentralized, and is cheapest at scale.**

The registry is a **verified underwriting attestation of equity, not a market price** — a 1/1 lien has no
market to discover a price or to manipulate. Housing is slow (not ETH-volatile), so the design carries:
(1) the honest equity mark on-chain (§3.1), conservatism in the LTV gap (§3.2), not synthetic bid/ask
spreads; (2) a home-appropriate validity window refreshed by a **1-day heartbeat** + event re-pricing, not
a 5-min staleness clock; (3) liquidation driven by **delinquency status** (§3.4e), so a stale/fake price
alone cannot liquidate. The genuine threat is the write path, hardened by the **timelocked router
governor** and **immutable Forwarder** (§3.4/§9). The **regional HPI is a mandatory P1 input** (§4.1/§5),
fanned in by the CRE as a systematic-bias band on the per-home AVM (the underwriting waterfall covers
idiosyncratic error; HPI covers model-wide drift). Data Streams remains an optional transport, not required.

---

## 8. Lien lifecycle state machine

```
[origination] ──mint+setLTV+allocate+borrow──▶ [active]
   [active] ──draw/accrue (fixed-rate IRM)──▶ [active]
   [active] ──full repay──▶ [closed] (burn token, LienReleased → SPV release)
   [active] ──missed payment──▶ [delinquent] ──grace elapsed──▶ [default]
   [default] ──markdown / legal exercise (off-chain via SPV)──▶ [resolved/written-off]
```
Each transition maps to controller `_processReport` branches + EVK ops + emitted events.

**Credit-line mechanics.** Each isolated market is a credit line funded to its `cap` on demand
(capital-efficient — no idle per-line buffer; a line runs near its borrow LTV). A line may drift *past*
`liquidationLTV` purely from interest accrual and is **not** auto-liquidated — there is no liquidator
market, and liquidation is controller-gated + delinquency-driven (§3.4e). EVK's account-status check then
blocks *further draws* on that line (you can't extend more credit to an underwater line) without
force-closing it. On default the protocol injects **no new USDC**: the line simply accrues and waits, and
is repaid from legal recovery, marked to **recovery value** (§3.4d) — the junior tranche absorbs any
shortfall, not the senior/pool (see risk-vision.md).

---

## 9. Trust & security model

- **Trust-minimized:** DON f+1 consensus on every report; `ReceiverTemplate` workflow-identity check
  behind an **immutable Forwarder**; **EulerRouter governor behind a timelock** (an oracle repoint has a
  veto window); `CREGatingHook` restricts borrow and liquidate to the controller (repay is permissionless
  — it only reduces debt); EVC controller + account-status checks; `EulerUngovernedPerspective` validates
  the market's oracle wiring.
- **Trusted (off-chain):** SPV legal custody/enforceability of the lien; originator KYB; servicing/
  dollar leg (Erebor/Fireblocks).
- **Key failure modes:** stale valuation (mitigated by a home-appropriate validity window + 1-day
  heartbeat — and liquidation is delinquency-driven, so a stale/fake price alone cannot liquidate); proof
  spoofing (mitigated by Reclaim+EigenLayer cryptoeconomic security); systematic AVM bias (mitigated by
  the HPI band, §3.1); governor/forwarder key compromise (mitigated by the timelocked router governor +
  immutable Forwarder, and by making the controller the only privileged caller and minimizing its surface).

---

## 10. Business context (compressed)

Three structures form one originate-to-distribute machine; **ONE is built first**, shaped so TWO/THREE
reuse the same collateral tokens + oracle:
- **ONE — Warehouse credit pool (built first):** RESI-incentivized USDC pool → credit lines to HELOC originators
  against pledged lien rights. "Warehouse" = the originator *relationship* (many per-lien lines under one
  counterparty), not co-mingled collateral — each line is an isolated per-home market (§13).
- **TWO — P2P matchmaker:** qualified lenders ↔ borrowers, one isolated market + oracle per loan.
- **THREE — Tokenized MBS (Securitize):** standing takeout buyer of the loans; closes ONE's capital
  loop and monetizes the per-home oracle network.

---

## 11. Proof-of-operations scope & acceptance

Vertical slice on **Base Sepolia**, one originator / one lien, mocked-but-realistic oracle + proof
inputs. **Acceptance:** the full loop runs tx-by-tx — underwrite → mint lien token → price via registry
→ open isolated market gated to the controller → allocate pool USDC → controller draws on its sub-account
(originator funded via Erebor) → permissionless repay → controller closes (burn) → `LienReleased`.
A candidate first integration milestone (a fundable proof of operations), not a feature-gated version.

---

## 12. Reference-repo map

| Repo (`reference/`) | What we use it for |
|---|---|
| `euler-earn` | the USDC credit pool + allocation surface |
| `euler-vault-kit` | isolated market (GenericFactory/EVault), hooks, IPriceOracle, IHookTarget |
| `evk-periphery` | EdgeFactory wiring, BaseHookTarget, SnapshotRegistry, Perspectives, EulerRouterFactory, IRMs |
| `euler-price-oracle` | BaseAdapter, EulerRouter, ScaleUtils, RedstoneCoreOracle pattern |
| `ethereum-vault-connector` | EVC auth (operator, batch, onBehalfOf) |
| `cre-sdk-go`, `cre-cli` | **Go** CRE workflow authoring (compiles to `wasip1`) + deploy |
| `x402-cre-price-alerts` (Solidity `ReceiverTemplate`/`onReport`), `cre-sdk-go/standard_tests` (Go workflow patterns) | receiver contract + working CRE patterns |
| `chainlink-datastreams-consumer`, `chainlink-evm` | Data Streams (optional transport, not required) |
| `base/docs` | Base chain deployment specifics |
| `moneymarket-contracts` (3Jane) | structural reference (credit pool → facilities → waterfall) |

---

## 13. Open technical decisions

- ~~Single-lien lines vs warehouse-of-many-liens per originator market.~~ **RESOLVED:** default is
  **per-lien singles** — one isolated market per home, no cap on the number of lines (gated only by
  underwriting validation + pool supply), each priced and each exiting independently. We build the
  per-lien oracle mark for every home regardless. A **bundled collateral** (one market, custom oracle =
  Σ of the per-lien marks) is **opt-in**, offered only when the originator asks and the bundle will exit
  together — it trades per-loan granularity (and per-lien RESI/recovery, individual MBS sale) for
  diversification + fewer markets. Risk is **the home's lien** (collateral/recovery); the originator is
  the underwritten counterparty.
- ~~Senior/junior tranche mechanics (where loop yield splits).~~ **RESOLVED:** zipUSD senior (1:1 mint) +
  szipUSD junior; yield routes to the junior via EulerEarn's `feeRecipient` (`supply-redemption.md`); loss
  via continuous markdown + a socialized pro-rata term-lock (`tokenomics-layer.md`).
- **Cash-reserve ratio: fixed-% vs dynamic** (scaling with the pending redemption queue / expected draw
  volume) — open (§4.2, `supply-redemption.md` §9).
- RESI liquidity-mining/incentive module (rewards distributor).
- SPV custody partner + exact on-chain ↔ legal handoff (Reclaim proof schema for "lien perfected") — `spv-lien-proof.md`.
- Whether markets must be perspective-verified for the proof-of-operations demo.
- Should `ZipcodeOracleRegistry` receive prices directly from CRE, or only via `ZipcodeController`.

---

## 14. Glossary

**EVK** Euler Vault Kit · **EVC** Ethereum Vault Connector · **EulerEarn** ERC-4626 meta-vault (the pool)
· **IPriceOracle** EVK pull oracle interface · **HookTarget** EVK operation hook · **CRE** Chainlink
Runtime Environment · **DON** Decentralized Oracle Network · **KeystoneForwarder** contract that verifies
DON sigs and calls receivers · **Reclaim** zkTLS proofs of off-chain API responses · **Subnet 46 (resi)**
Bittensor real-estate appraisal subnet · **HELOC** home-equity line of credit · **OTD** originate-to-
distribute · **warehouse** revolving line against pledged receivables/liens · **LTV** loan-to-value.
