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
                  │            CRE workflows (TypeScript, cre-sdk)            │
                  │  underwriting/origination  ·  allocation/rebalance       │
                  └───────────────────────────────┬──────────────────────────┘
                                                   │ HTTP / proofs / consensus
        ┌──────────────────────────────────────────┴───────────────────────────┐
        │ Subnet 46 (appraisal) · Plaid (KYC/income) · Credit Karma (score)      │
        │ Pippin/DART (title/liens) · Reclaim+EigenLayer (zkTLS) · Block Analitica│
        └────────────────────────────────────────────────────────────────────────┘
```

Off-chain (legal/custody, not on the trust path): an **SPV** custodies the perfected lien;
**Fireblocks/Erebor** handle custody and the USD↔stablecoin dollar leg.

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
| Oracle base | `BaseAdapter` (immutable base/quote, override `_getQuote`, `_getDecimals`) | `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` |
| Router | `EulerRouter :: govSetConfig(base,quote,oracle)` (O(1), no limit, no timelock), `resolveOracle` | `reference/euler-price-oracle/src/EulerRouter.sol` |
| Decimal math | `ScaleUtils :: calcScale / getDirectionOrRevert / calcOutAmount` | `reference/euler-price-oracle/src/lib/ScaleUtils.sol` |
| **Signed-report oracle pattern** | `RedstoneCoreOracle` — state-changing `updatePrice()` caches `{price, timestamp}`; view `_getQuote` reads cache + enforces `maxStaleness` | `reference/euler-price-oracle/src/adapter/redstone/RedstoneCoreOracle.sol` |
| Adapter whitelist + validation | `SnapshotRegistry :: add/revoke/isValid`; `EulerUngovernedPerspective :: verifyAssetPricing`; `EulerRouterFactory` | `reference/evk-periphery/src/{SnapshotRegistry,Perspectives/deployed,EulerRouterFactory}/` |
| Connector | `EVC :: setAccountOperator / setOperator / call / batch(BatchItem{target,onBehalfOfAccount,value,data}) / getCurrentOnBehalfOfAccount`; single-controller + `checkAccountStatus` | `reference/ethereum-vault-connector/src/EthereumVaultConnector.sol` |
| CRE inbound | `ReceiverTemplate :: onReport(metadata, report) → _processReport`; `_decodeMetadata → (workflowId, workflowName, workflowOwner)`; gated on KeystoneForwarder | `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` |
| Data Streams (deferred) | `VerifierProxy :: verify` (state-changing, charges LINK/native fee via `FeeManager`), RWA report v4/v8 | `reference/chainlink-evm/contracts/src/v0.8/llo-feeds/v0.5.1/VerifierProxy.sol` |
| IRM | linear-kink / adaptive-curve IRM, set via `setInterestRateModel` | `reference/evk-periphery/src` (IRM), `reference/euler-vault-kit` |

---

## 3. Net-new contracts

### 3.1 `ZipcodeOracleRegistry` — `is ReceiverTemplate, BaseAdapter`
A **single** multi-asset adapter that prices every lien token, fed by the CRE DON.

- **Storage:** `address immutable quote` (USDC/unit of account); `mapping(address lien => Cache)` where
  `struct Cache { uint208 price; uint48 timestamp; }`; `uint256 immutable maxStaleness`.
- **`_processReport(bytes report)`** (from `ReceiverTemplate.onReport`, KeystoneForwarder-gated):
  decode `(address[] liens, uint256[] prices, uint32 ts)` and write `cache[lien] = {price, ts}` in a
  loop (one DON report → many prices; report ≤ 5 KB caps batch size, shard across cohorts above that).
- **`_getQuote(inAmount, base, quote)`** (view, override of `BaseAdapter`): read `cache[base]`, revert
  `PriceOracle_TooStale` if `block.timestamp - ts > maxStaleness`, scale via `ScaleUtils.calcOutAmount`.
- **Registration:** `EulerRouter.govSetConfig(lien, USDC, registry)` once per lien — all liens route to
  this one instance; one `SnapshotRegistry.add` entry for perspective validation.
- **Modeled on:** `RedstoneCoreOracle` (updatePrice→cache→stale-checked view) generalized to multi-asset.

### 3.2 `LienCollateralToken` + `LienTokenFactory`
- 1/1 ERC-20, one instance per lien (EVK collateral must be ERC-20-shaped; no native NFT collateral).
- Holds lien metadata id; `mint`/`burn` restricted to `ZipcodeController`.
- Registered as collateral on the borrower's isolated market via `Governance.setLTV(lienToken, borrowLTV, liqLTV, ramp)`.
- Factory deploys deterministically (CREATE2) so the controller/CRE can precompute the address.

### 3.3 `CREGatingHook` — `is IHookTarget`
- `isHookTarget()` validates `msg.sender` is a vault from `GenericFactory` and returns the selector.
- `fallback()` extracts the appended 20-byte caller (`shr(96, calldataload(sub(calldatasize(),20)))`)
  and reverts unless `caller == zipcodeController`.
- Installed via `setHookConfig(hook, OP_BORROW | OP_REPAY | OP_LIQUIDATE)`.
- **Modeled on:** `BaseHookTarget`.

### 3.4 `ZipcodeController` — `is ReceiverTemplate` (the orchestrator)
The single trusted on-chain identity. Holds: EulerEarn **allocator** role, EulerRouter **governor**,
isolated-market **governor**, lien-token **mint authority**, and is the **gating hook's** trusted caller.

`_processReport` branches on a report-type discriminator:
- **(a) Origination** → `LienTokenFactory.create` (mint 1/1 token) → `EulerRouter.govSetConfig(lien,USDC,registry)` →
  seed `ZipcodeOracleRegistry` price → `setLTV` on the originator's market → `EVC.batch` →
  `EulerEarn.reallocate` pool→market and open the borrower's line.
- **(b) Revaluation** → forward new price into `ZipcodeOracleRegistry` (or registry receives directly).
- **(c) Repayment/close** → `burn` lien token, emit `LienReleased(lienId)` (signals off-chain SPV release).
- **(d) Default** → mark delinquent/default, emit legal-path event; optional markdown.

---

## 4. CRE workflows (TypeScript, `cre-sdk`)

### 4.1 Underwriting / origination workflow
- **Trigger:** `HTTPCapability.trigger` (originator submits an application) or `CronCapability`.
- **Inputs:** Reclaim/EigenLayer zkTLS proofs (identity, title, lien position), Subnet 46 appraisal,
  Block Analitica LTV/risk params — fetched via `HTTPClient`/`ConfidentialHTTPClient` + `runtime.getSecret`.
- **Consensus:** `runInNodeMode` + `consensusMedianAggregation` (valuation) / `consensusIdenticalAggregation`
  (boolean proof gates). PII never traverses the DON raw — only **proofs and derived bounds**.
- **Output:** `runtime.report(prepareReportRequest(encodeAbiParameters(...)))` →
  `evmClient.writeReport({ receiver: ZipcodeController, report, gasConfig })`.

### 4.2 Allocation / rebalance workflow
- **Trigger:** `CronCapability`.
- **Reads:** pool + market state via `evmClient.callContract` (`encodeCallMsg` + `decodeFunctionResult`)
  — supply/borrow/utilization, caps, IRM config; rewards via HTTP (Merkl) where applicable.
- **Compute:** ports the `reference/euler-allocator-bot` objective (blend supply APY + reward APY,
  subject to caps + cash reserve). **Determinism constraint (critical):** the bot's simulated annealing
  uses `Math.random()`, which breaks DON consensus — the port must seed the RNG deterministically from
  on-chain data (e.g. block hash) or use a deterministic optimizer, so every node produces the same
  allocation.
- **Output:** signed report → `EulerEarn.reallocate` via the controller / EVC.

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
| Optimal LTV / risk params | Block Analitica | report params → `setLTV` bounds |

Cred Protocol / Blockchain Bureau add on-chain-address credit scoring on top of off-chain VantageScore.

---

## 6. Authorization & control-flow trace

**One-time setup** (governor/owner): `EulerEarn.setIsAllocator(controller, true)`;
`EVault.setGovernorAdmin(controller)`; `EVault.setHookConfig(gatingHook, OP_BORROW|OP_REPAY|OP_LIQUIDATE)`;
`EVault.setInterestRateModel(irm)`; `EulerRouter.govSetConfig(lien, USDC, registry)`;
`SnapshotRegistry.add(registry, lien, USDC)`; (optional) `EVC.setAccountOperator(poolAccount, controller, true)`.

**Origination path:**
```
CRE underwriting workflow
  → runtime.report() (f+1 DON sigs)
  → evmClient.writeReport({receiver: ZipcodeController})
  → KeystoneForwarder (verifies DON sigs)
  → ZipcodeController.onReport → _decodeMetadata (workflowId/owner check) → _processReport
       ├─ LienTokenFactory.create(lienId)            // mint 1/1 collateral
       ├─ EulerRouter.govSetConfig(lien, USDC, reg)  // controller is router governor
       ├─ ZipcodeOracleRegistry price seed           // collateral now priceable
       ├─ EVault.setLTV(lien, borrowLTV, liqLTV, 0)  // controller is vault governor
       └─ EVC.batch([
            { EulerEarn.reallocate(...) },            // pool → originator market (allocator role)
            { EVault.borrow(amount, originator) }     // CREGatingHook asserts caller == controller
          ])
```

**Repay path:** originator repays → controller report → `EVault.repay` (hook-gated) → `burn` lien token →
`LienReleased` event → off-chain SPV releases the recorded lien.

---

## 7. Oracle architecture & rationale (decision: push-cache)

| Axis | CRE push-cache (chosen) | Data Streams |
|---|---|---|
| Bespoke per-home feed | ✅ any asset we define | ❌ feeds permissioned/standardized only |
| CRE support | ✅ native `writeReport` | ❌ no DS capability in `cre-sdk` |
| Decentralization | ✅ f+1 DON sigs | ✅ (but only for existing feeds) |
| On-chain read | view read of cache | view read of cache (DS `verify` is tx+fee, can't run in view → still cached) |
| Per-update cost | DON report + 1 EVM tx | LINK/native fee + subscription |
| New asset provisioning | one `govSetConfig` we control | Chainlink Labs negotiation |

Both approaches are cache-then-view underneath; the only real difference is who signs/provisions.
**Push-cache via CRE is the only option that supports per-home pricing, is CRE-native, stays
DON-decentralized, and is cheapest at scale.** Data Streams is retained as a swappable future adapter
(behind `IPriceOracle`) for a market-level index (e.g. a regional HPI) used only as a sanity bound.

---

## 8. Lien lifecycle state machine

```
[origination] ──mint+setLTV+allocate+borrow──▶ [active]
   [active] ──draw/accrue (IRM + premium)──▶ [active]
   [active] ──full repay──▶ [closed] (burn token, LienReleased → SPV release)
   [active] ──missed payment──▶ [delinquent] ──grace elapsed──▶ [default]
   [default] ──markdown / legal exercise (off-chain via SPV)──▶ [resolved/written-off]
```
Each transition maps to controller `_processReport` branches + EVK ops + emitted events.

---

## 9. Trust & security model

- **Trust-minimized:** DON f+1 consensus on every report; `ReceiverTemplate` workflow-identity check;
  `CREGatingHook` restricts borrow/repay/liquidate to the controller; EVC controller + account-status
  checks; `EulerUngovernedPerspective` validates the market's oracle wiring.
- **Trusted (off-chain):** SPV legal custody/enforceability of the lien; originator KYB; servicing/
  dollar leg (Erebor/Fireblocks).
- **Key failure modes:** stale valuation (mitigated by `maxStaleness`), proof spoofing (mitigated by
  Reclaim+EigenLayer cryptoeconomic security), governor/controller key compromise (mitigated by making
  the controller the only privileged caller and minimizing its surface).

---

## 10. Business context (compressed)

Three structures form one originate-to-distribute machine; **V1 = ONE**, shaped so TWO/THREE reuse the
same collateral tokens + oracle:
- **ONE — Warehouse credit pool (V1):** RESI-incentivized USDC pool → credit lines to HELOC originators
  against pledged lien rights.
- **TWO — P2P matchmaker:** qualified lenders ↔ borrowers, one isolated market + oracle per loan.
- **THREE — Tokenized MBS (Securitize):** standing takeout buyer of the loans; closes ONE's capital
  loop and monetizes the per-home oracle network.

---

## 11. V1 demo scope & acceptance

Vertical slice on **Base Sepolia**, one originator / one lien, mocked-but-realistic oracle + proof
inputs. **Acceptance:** the full loop runs tx-by-tx — underwrite → mint lien token → price via registry
→ open isolated market gated to the controller → allocate pool USDC → originator draws → repay → burn →
`LienReleased`. Sufficient as a fundable proof of operations.

---

## 12. Reference-repo map

| Repo (`reference/`) | What we use it for |
|---|---|
| `euler-earn` | the USDC credit pool + allocation surface |
| `euler-vault-kit` | isolated market (GenericFactory/EVault), hooks, IPriceOracle, IHookTarget |
| `evk-periphery` | EdgeFactory wiring, BaseHookTarget, SnapshotRegistry, Perspectives, EulerRouterFactory, IRMs |
| `euler-price-oracle` | BaseAdapter, EulerRouter, ScaleUtils, RedstoneCoreOracle pattern |
| `ethereum-vault-connector` | EVC auth (operator, batch, onBehalfOf) |
| `euler-allocator-bot` | allocation objective to port into the CRE allocation workflow |
| `cre-sdk-typescript`, `cre-cli` | workflow authoring + deploy |
| `x402-cre-price-alerts`, `cre-bootcamp-2026`, `cre-templates` | ReceiverTemplate + working CRE workflow patterns |
| `chainlink-datastreams-consumer`, `chainlink-evm` | Data Streams (deferred future adapter) |
| `base/docs` | Base chain deployment specifics |
| `moneymarket-contracts` (3Jane) | structural reference (credit pool → facilities → waterfall) |

---

## 13. Open technical decisions

- Single-lien lines vs warehouse-of-many-liens per originator market (affects collateral granularity).
- Senior/junior tranche mechanics (where loop yield splits).
- RESI liquidity-mining/incentive module (rewards distributor).
- SPV custody partner + exact on-chain ↔ legal handoff (Reclaim proof schema for "lien perfected").
- Whether markets must be perspective-verified for V1.
- Should `ZipcodeOracleRegistry` receive prices directly from CRE, or only via `ZipcodeController`.

---

## 14. Glossary

**EVK** Euler Vault Kit · **EVC** Ethereum Vault Connector · **EulerEarn** ERC-4626 meta-vault (the pool)
· **IPriceOracle** EVK pull oracle interface · **HookTarget** EVK operation hook · **CRE** Chainlink
Runtime Environment · **DON** Decentralized Oracle Network · **KeystoneForwarder** contract that verifies
DON sigs and calls receivers · **Reclaim** zkTLS proofs of off-chain API responses · **Subnet 46 (resi)**
Bittensor real-estate appraisal subnet · **HELOC** home-equity line of credit · **OTD** originate-to-
distribute · **warehouse** revolving line against pledged receivables/liens · **LTV** loan-to-value.
