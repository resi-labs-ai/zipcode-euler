# zipcode-euler — Build Spec

> A decentralized home-equity credit protocol. A xALPHA-incentivized USDC credit pool (built on EulerEarn,
> the first settlement venue) extends warehouse-style credit lines to KYB'd HELOC originators who already
> feed established secondary takeout markets. Each line is collateralized by an on-chain **1/1 lien token**
> whose value is the **Proof**-notarized origination appraisal, surfaced on-chain by a **Chainlink CRE**
> workflow fed by the **Zipcode Bittensor subnet** — validator containers that fetch and zk-verify the
> lien / value / insurance / identity / title / income data. Suppliers deposit USDC and, by default, **zap**
> into the junior **szipUSD** (the headline yield product — it earns the pool yield and takes first loss);
> **zipUSD** is the $1 utility dollar (exit hatch + composable lending asset). Every sensitive on-chain
> operation is gated so that **only the CRE-driven controller** can open a line, price collateral, or move
> pool funds.

This document is the single engineering build spec (assembled from the prior base/supply/loss
fragments). Reused primitives are cited as `repo/path/File.sol :: fn()`; net-new contracts are specified
down to the interfaces they implement and the reference contract they are modeled on. All reference repos
live under `reference/`. The protocol is **permissioned end-to-end** — KYB'd originators, a single
trusted controller as governor / borrower-of-record / funder — so there is no permissionless market
discovery and no oracle/market "perspective" verification (see §13). **Euler is the first settlement venue
(configuration one); the administrative core — CRE / oracle / registry — is venue-agnostic and can re-point
to Aave or Morpho behind the adapter boundary in §4.7.** The off-chain SPV custody + **Proof**
attestation layer (lien / value / insurance) is in `spv-lien-proof.md`: Proof addresses the attestation, but
the SPV custody partner and the CRE integration are still to wire, so collateral is mocked until then.

---

## 1. System overview & component map

```
        USDC suppliers                       subnet incentives
              │ deposit (zap)                  (→ szipUSD APR)
              ▼
   ┌────────────────────┐  mint 1:1  ┌────────────┐ zap/stake ┌─────────────────┐
   │ ZipDepositModule   │───────────▶│   zipUSD   │──────────▶│ szipUSD (junior)│
   │ (USDC → EulerEarn) │            │($1 utility)│           │ feeRecipient,   │
   └─────────┬──────────┘            └────────────┘           │ first loss      │
             │ deposit USDC                                  └────────┬────────┘
             ▼                                                        │ pool yield (perf fee)
   ┌───────────────────────┐        allocator role (via EVC)          │
   │  EulerEarn USDC pool   │◀───────────────────────────────┐        │
   │  (credit pool)         │── setFeeRecipient(szipUSD) ─────┼────────┘
   └───────────┬───────────┘                                 │
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
   │ EulerRouter (per-line) │  per-line, wired to registry &   │
   │   resolves escrowVault │  frozen at origination (§4.1/§4.7)│
   │   → lien → registry    │◀────── cache[lien].price ───────┤
   └───────────────────────┘                                  │ DON-signed report
                                                               │ (KeystoneForwarder, immutable)
             ┌─────────────────────────────────────────────────┴────────┐
             │              CRE workflows (Go, cre-sdk-go)              │
             │  underwriting/origination · revaluation · funding ·      │
             │  redemption settle · default/recovery                    │
             └───────────────────────────────┬──────────────────────────┘
                                              │ validated data (DON-signed)
   ┌──────────────────────────────────────────┴───────────────────────────┐
   │  Zipcode Bittensor subnet — validator/miner containers (the DON)       │
   │  fetch each API · zk-verify (no PII exposed) · consensus → feed CRE     │
   │  [subnet ↔ CRE integration mechanism: OPEN — resolve in §7/§8]          │
   └──────────────────────────────────────────┬───────────────────────────┘
                                              │ HTTP (per-node fetch)
   ┌──────────────────────────────────────────┴───────────────────────────┐
   │ Proof (lien/value/insurance) · Plaid (KYC/income) · Credit Karma        │
   │ (score) · Pippin/DART (title/liens) · Block Analitica (risk params)     │
   └────────────────────────────────────────────────────────────────────────┘
```

The EulerEarn pool, EVK market, EulerRouter, and `CREGatingHook` above are the **Euler venue adapter
(configuration one)**; they sit behind the venue-agnostic boundary in §4.7, while the portable
core is the CRE receiver, the `ZipcodeOracleRegistry`, and the controller's decision logic.

On the loss side, a per-lien **`LienXAlphaEscrow`** holds the originator's xALPHA first-loss bond (posted by the
protocol on the originator's behalf at launch, §4.6) and a **`DefaultCoordinator`** drives the default →
continuous markdown → **Duration Bond** (socialized pro-rata lock) → off-chain insurance → xALPHA premium →
recovery flow (§4, §11). Off-chain (legal/custody, not on the trust path): an **SPV** custodies the
perfected lien, **Proof** notarizes the lien / value / insurance attestations (`spv-lien-proof.md`), and
**Fireblocks/Erebor** handle custody and the USD↔stablecoin dollar leg.

---

## 2. Token model

| Token | Role | Form |
|---|---|---|
| **zipUSD** | The **$1 utility dollar** — minted 1:1 on USDC deposit, redeemed for USDC (epoch queue, §6.1) or sold (secondary, §6.2). The protocol's dollar plumbing: the **exit hatch** out of szipUSD and a composable USDC-pegged asset other markets can lend against (vs szipUSD, a future **zipCRED** RWA, or other RWAs) — not an investment tranche. Mechanically still **insulated from loss until the junior is exhausted** (loss waterfall, §11). | mintable/burnable ERC-20 (`ESynth`) |
| **szipUSD** | The junior, **the main product** — a **transferable ERC-20 share** (18-dp) over a **Baal/Moloch-v3 Gnosis Safe basket** (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex, §4.5). The **Exit Gate** mints szipUSD **1:1 against soulbound Baal Loot it custodies** — Loot is the ragequit-bearing layer, held + ragequitted **only** by the gate (no raw-ragequit footgun), while the user share is **freely transferable**. Deposit → **NAV-proportional** szipUSD (`shares = value / navPerShare`, priced via `SzipNavOracle`, §7). **Two exits:** *patient* = the gate's intent-queue + liquidity-window ragequit at NAV (**partial-fill per window**, §6.4); *impatient* = **sell szipUSD on a CoW book** (§6.2). Duration-Bond **freeze structural via the sidecar** (§6.4/§11). **Depositor return = NAV accretion** — the HYDX-vamp free value is recycled into the basket (8-B10) lifting NAV-per-share weekly, realized on exit at NAV (+ the Duration-Bond premium + any post-M1 xALPHA emission incentive). (Real lending APR/fees are the **protocol's** → they over-collateralize zipUSD in the `CreditWarehouse` now; future treasury buybacks, §17.) **NAV is the issuance/exit pricing primitive** (`SzipNavOracle`, §7/§12). Bears **residual** first loss as a **pari-passu conservative provision-that-recovers** (§11): a default is **freeze-dominant** (duration-risk — insured/collateralized HELOC), the day-one markdown is small and writes back up on verified recovery. | transferable ERC-20 share; gate mints 1:1 vs soulbound Loot; NAV-priced; window-RQ / CoW exits |
| **xALPHA** | **ONE token — the liquid-staked Zipcode-subnet alpha (LST), bridged to Base via CCIP** (`bridge/xalpha-bridge-impl.md`). It does **six jobs**: per-lien **first-loss bond** (protocol-posted at launch, originators self-fund via OTC as they scale, §4.6); the **Duration-Bond premium** (in-kind, priced via the CRE feed, never market-sold, §11); the **szipUSD incentive emission** (post-M1); the **zipUSD/xALPHA POL pair leg** (post-M1, §4.5); a **last-resort capital backstop** — liquidated **alpha → TAO → USDC on Bittensor** to cover a realized loss after insurance (§11); and the **treasury buyback target** (real USDC lending yield → buy xALPHA, the closed loop, `pending-docs/treasury.md`). Yield-bearing because it is the LST. | external ERC-20 — the bridged subnet LST (xALPHA) |

The peg is **"minted 1:1,"** not a NAV. zipUSD stays $1; the pool's growth accrues to `szipUSD`, and any
retained growth is surplus NAV over the zipUSD supply (an over-collateralization cushion held by the
protocol). zipUSD is solvent while backing NAV ≥ zipUSD supply (§12). 3Jane mapping (mechanical, loss-
waterfall only — zipUSD is a utility dollar, not an investment tranche): zipUSD plays the `USD3`
senior-claim role, szipUSD the `sUSD3` first-loss role.

**Junior accounting unit (Baal two-token model, 2026-06-07; see the §4.5 / §6.4 substrate).** You deposit USDC
(the zap) → receive **transferable szipUSD** (an ERC-20 share), minted **NAV-proportionally** by the Exit Gate,
which custodies the soulbound **Loot** (the ragequit-bearing layer) 1:1 against your share. A **Gnosis Safe** (+ a
non-ragequittable **sidecar**) holds the junior basket (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP). **Exit:**
*patient* = the gate's windowed ragequit at NAV (**partial-fill per window**, §6.4); *impatient* = sell szipUSD on a
CoW book (§6.2). **NAV (`SzipNavOracle`, §7) is the pricing primitive** — issuance is NAV-proportional, exit is at
`min(spot, twap)`. **The depositor's return is the HYDX-vamp yield + the xALPHA subsidy** (§4.5/§5/§17), not the
lending yield (which is the protocol's → treasury). **First-loss is a pari-passu conservative provision-that-recovers
(§11):** on default the at-risk equity **freezes** (sidecar; keeps earning) while the recovery waterfall runs; a
**conservative provision** marks NAV down at recognition — **small**, because the underlying is insured/collateralized
(duration-risk, not loss) — and **writes back up on verified recovery**, trued-up at resolution. **No subordination
cap** (the junior is the dominant capital, §5); inside the junior everyone is **pari passu** (no team subordination).
The **coverage floor is the freeze itself** (structural — the committed slice can't be exited), **not** a separate
governed knob (§6.4). *(Supersedes the 2026-06-06 soulbound-claim / withhold-no-markdown / NAV-display-only model.)*

---

## 3. Reused on-chain primitives

> Most rows below are the **Euler venue adapter's** surface (configuration one); on another venue (Aave,
> Morpho) these are re-implemented behind the `IZipcodeVenue` boundary (§4.7). The portable
> core — the CRE receiver, `ZipcodeOracleRegistry`, and the controller's decision logic — is venue-neutral.
> Loss-side rows model 3Jane primitives (concept only; AGPL).

| Concern | Surface we call | Path |
|---|---|---|
| Credit pool | `EulerEarn :: reallocate(MarketAllocation[])` (`:383`), `setIsAllocator` (`:218`), `submitCap/acceptCap` (`:287,:507`, cap increase timelocked), `setSupplyQueue/updateWithdrawQueue` (`:325,:340`); roles owner/curator/guardian/allocator | `reference/euler-earn/src/EulerEarn.sol`, `EulerEarnFactory.sol` |
| Pool auth | allocator check resolves caller via EVC `onBehalfOfAccount` (EVCUtil `_msgSenderOnlyEVCAccountOwner`) | `reference/euler-earn/src` |
| zipUSD token | `ESynth` — controlled-mint ERC-20 (`setCapacity` per minter `:47`, `mint :55`/`burn :81`); **PSM peg machinery NOT used** (§19) | `reference/euler-vault-kit/src/Synths/ESynth.sol` |
| Yield routing | `EulerEarn :: setFeeRecipient` (`:258`), `setFee` (`:243`), accrual `_mint(feeRecipient, feeShares)` (`:889`) via `_accruedFeeAndAssets` (`:898`) | `reference/euler-earn/src/EulerEarn.sol` |
| Market creation | `GenericFactory :: createProxy(address desiredImplementation, bool upgradeable, bytes trailingData = abi.encodePacked(asset, oracle, unitOfAccount))` (`:116`) | `reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol` |
| Deploy reference flow | `EdgeFactory` (vault + IRM + hook + LTV wiring in one shot) | `reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol` |
| Vault governance | `Governance :: setLTV (:281) / setInterestRateModel (:333) / setHookConfig (:347) / setGovernorAdmin (:256) / setCaps (:369) / setMaxLiquidationDiscount (:318) / setLiquidationCoolOffTime (:327)` (all `governorOnly :93`) | `reference/euler-vault-kit/src/EVault/modules/Governance.sol` |
| LTV type | `LTVConfig { borrowLTV, liquidationLTV, initialLiquidationLTV, targetTimestamp, rampDuration }` (`:9-20`) | `reference/euler-vault-kit/src/EVault/shared/types/LTVConfig.sol` |
| Hook dispatch | `Base :: callHook (:114) / invokeHookTarget (:127)` — appends 20-byte `caller` to calldata (`:132`); flags `OP_DEPOSIT=1<<0 (:32)`, `OP_BORROW=1<<6 (:38)`, `OP_REPAY=1<<7 (:39)`, `OP_LIQUIDATE=1<<11 (:43)` | `reference/euler-vault-kit/src/EVault/shared/{Base.sol,Constants.sol}` |
| Hook interface | `IHookTarget :: isHookTarget() → bytes4 (:13)`; base impl `BaseHookTarget` | `reference/euler-vault-kit/src/interfaces/IHookTarget.sol`, `reference/evk-periphery/src/HookTarget/BaseHookTarget.sol` |
| Oracle interface | `IPriceOracle :: getQuote (:20) / getQuotes (:28)` (PULL, view) | `reference/euler-vault-kit/src/interfaces/IPriceOracle.sol` |
| Oracle base | `BaseAdapter` (immutable base/quote, override `_getQuote :45`, `_getDecimals :37`) — we return `bid==ask==mid` (the honest equity mark; conservatism lives in the LTV gap, not a synthetic spread) | `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` |
| Router | `EulerRouter :: ctor(evc, governor) (:47) / govSetConfig(base,quote,oracle) (:56) / govSetResolvedVault(vault,bool) (:69) / resolveOracle (:123) / transferGovernance` — **per-line**: the venue adapter mints one router per line, wires it to the registry, and **freezes** it (`transferGovernance(address(0))`) inside `openLine`; no shared/timelocked router (§4.1/§4.7) | `reference/euler-price-oracle/src/EulerRouter.sol` |
| Decimal math | `ScaleUtils :: calcScale (:53) / getDirectionOrRevert (:38) / calcOutAmount (:63)` | `reference/euler-price-oracle/src/lib/ScaleUtils.sol` |
| **Signed-report oracle pattern** | `RedstoneCoreOracle` — state-changing `updatePrice() (:78)` caches `{price, timestamp}`; view `_getQuote` reads cache + enforces `maxStaleness`. We adopt the cache→stale-checked-view *pattern* but set a home-appropriate validity window, **not** its 5-min `MAX_STALENESS_UPPER_BOUND (:24)` (§4.1/§7) | `reference/euler-price-oracle/src/adapter/redstone/RedstoneCoreOracle.sol` |
| Connector | `EVC :: setAccountOperator (:364) / setOperator (:343) / call (:553) / batch(BatchItem{target,onBehalfOfAccount,value,data}) (:600) / getCurrentOnBehalfOfAccount (:206)`; single-controller + `checkAccountStatus` | `reference/ethereum-vault-connector/src/EthereumVaultConnector.sol` |
| CRE inbound | `ReceiverTemplate :: onReport(metadata, report) (:78) → _processReport (:119)`; `_decodeMetadata → (workflowId, workflowName, workflowOwner)`; gated on the **immutable** CRE Forwarder (`s_forwarderAddress` set once at construction `:48` — we drop the setter; a zero address makes `onReport` permissionless `:82-85`) | `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` |
| Data Streams (optional transport) | `VerifierProxy :: verify` (state-changing, charges LINK/native fee via `FeeManager`), RWA report v4/v8. Not required: the regional HPI bound arrives as a CRE HTTP input (§4.1/§8.5), not via DS | `reference/chainlink-evm/contracts/src/v0.8/llo-feeds/v0.5.1/VerifierProxy.sol` |
| IRM | set via `setInterestRateModel`. **Uses a flat/fixed rate** — `IRMLinearKink(baseRate, 0, 0, kink)` (`baseRate` immutable line 14; the two slope args 0 → constant APR; constructor line 22 — a negotiated credit-line rate, not utilization-floating) | `reference/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol`, `reference/evk-periphery/src` (IRM) |
| Async redeem base | `BaseERC7540 is ERC4626, Owned, IERC7540Operator` (`:12`, `setOperator :34`), `ControlledAsyncRedeem` (`requestRedeem :39`, `fulfillRedeem onlyOwner :65`, pending/claimable `:22-32`) | `reference/erc7540-reference/src/{BaseERC7540,ControlledAsyncRedeem}.sol` (**MIT — fork**) |
| Epoch + pro-rata (concept) | `MapleWithdrawalManager :: getRedeemableAmounts` (`:367-387`, `redeemable = locked × available/totalRequested`), carry-forward (`:262-271`) | `reference/maple-withdrawal-manager/contracts/MapleWithdrawalManager.sol` (**BSL/GPL — clean-room concept only**) |
| Senior/junior loss waterfall | `USD3 :: _postReportHook (:502) / _burnSharesFromSusd3 (:567)` (junior absorbs first loss; senior protected first — **concept only**: our junior NAV = `basketNAV/supply` via `SzipNavOracle` §7, and first-loss is a recoverable **provision** on `navPerShare`, **not** a share-burn, §11) | `reference/moneymarket-contracts/src/usd3/USD3.sol` (AGPL — concept only) |
| Subordination **floor** (model; cap NOT used) | `sUSD3 :: availableWithdrawLimit (:277, floor)` — kept but **re-anchored to outstanding loan exposure** (§2/§6.4); the **cap** (`availableDepositLimit :249` / `maxSubordinationRatio :408`) is **not used** (junior is the dominant capital, §2) | `reference/moneymarket-contracts/src/usd3/sUSD3.sol` (AGPL — concept only) |
| Junior exit (ragequit + lock) | **Baal `ragequit`** (Loot → pro-rata **in-kind** basket slice) + a custom **lock-shaman** (`lockUntil`, ~30d) — the junior exit (§6.4); **replaces** the old `sUSD3` cooldown model | `reference/Baal/contracts/Baal.sol` (`ragequit` `:619`) |
| **Duration Bond** (freeze) | **structural** via the **Exit Gate + sidecar** (§6.4): the **utilization-committed slice** (sized to credit-warehouse utilization) is **held in the non-ragequittable sidecar Safe** (frozen-but-earning, objective release) so window exits reach only the free equity — the §11 Duration Bond (default OR duration squeeze) | net-new (Exit-Gate custody + sidecar; **not** a Baal-ragequit gate; **owned by the Exit Gate** — `DefaultCoordinator` only writes the NAV markdown + runs the xALPHA recovery waterfall, §4.6) |
| xALPHA bond slash (proportional, in-kind) | `MarkdownController :: slashJaneProportional (:146) / slashJaneFull (:187)` | `reference/moneymarket-contracts/src/MarkdownController.sol` (concept only) |
| xALPHA escrow custody | `InsuranceFund :: bring (:33)` | `reference/moneymarket-contracts/src/InsuranceFund.sol` (concept only) |
| Pro-rata in-kind bonus distribution | `RewardsDistributor :: claim (:131) / claimMultiple (:141)` | `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol` (concept only) |
| Settle / write-off (recovery shortfall) | `MorphoCredit :: settleAccount (:834) / _applySettlement (:874)` | `reference/moneymarket-contracts/src/MorphoCredit.sol` (concept only) |
| Delinquency state machine (lock trigger) | `MorphoCredit :: getRepaymentStatus (:526)` (Current/Grace/Delinquent/Default) | `reference/moneymarket-contracts/src/MorphoCredit.sol` (concept only) |
| CRE schedule | Go CRE `cron.Trigger` (`capabilities/scheduler/cron/trigger_sdk_gen.go:16`) + controller as privileged caller | `reference/cre-sdk-go` |

Note: `MarkdownController.calculateMarkdown (:91)` (time-linear unsecured decay, `:110`) **exists but is
deliberately not used** — our markdown is recovery-aware and continuous (§11), not time-linear.

---

## 4. Net-new contracts

### 4.1 `ZipcodeOracleRegistry` — `is ReceiverTemplate, BaseAdapter`
A **single** multi-asset adapter that prices every lien token, fed by the DON (the Zipcode subnet validators
via CRE, §7/§8). The cached price is the lien's **honest equity mark** — `Proof-notarized appraised value −
senior debt ahead of the lien`, in the unit of account (Proof of Value, §8.5 / `spv-lien-proof.md`). It is a
verified underwriting attestation, not a market quote (a 1/1 lien has no market). It reports `bid==ask==mid`;
the appraisal-error + value-staleness cushion lives in the LTV gap (§4.2/§4.4), not here. **Venue note:** the
`BaseAdapter`/`IPriceOracle` face is the **Euler read-adapter**; on another venue a sibling read-adapter
reads the **same cache** (§4.7) — the cache itself is venue-neutral.

- **Storage / constructor:** `address immutable quote` (USDC/unit of account); `mapping(address lien =>
  Cache)` where `struct Cache { uint208 price; uint48 timestamp; }`; `uint256 immutable validityWindow` —
  a **long** window (line-term scale): the mark is **event-driven** (origination / secondary acquisition /
  deviation), not heartbeat-refreshed, so a line that outlives its window must re-appraise (a Proof event)
  to draw further. This is **not** RedstoneCoreOracle's 5-min `MAX_STALENESS_UPPER_BOUND`. Constructor: `ZipcodeOracleRegistry(address forwarder, address quote,
  uint256 validityWindow)` (`BaseAdapter` has no constructor; only `ReceiverTemplate`'s `forwarder` arg is
  required). The Forwarder is made **immutable** as in §4.4 — note the base `setForwarderAddress`/`onReport`
  are **non-virtual** so they cannot be overridden; immutability is enforced by **renouncing `Ownable`
  ownership** after identity wiring (§9), which neutralizes every `onlyOwner` setter (any later
  `setForwarderAddress` reverts `OwnableUnauthorizedAccount`). `_getQuote(inAmount, base, quote)` takes
  `base` as a parameter (`BaseAdapter.sol:45`, `virtual`), so one adapter pricing many liens via
  `cache[base]` fits the base contract cleanly.
- **Scale (one immutable, all liens) + value units.** Every lien is pinned to `LIEN_DECIMALS = 18` (§4.2,
  enforced per-write below), so a **single** immutable `Scale = ScaleUtils.calcScale(18, quoteDecimals,
  feedDecimals)` prices all of them, with `feedDecimals = quoteDecimals = _getDecimals(quote)`. With this
  convention `getQuote(1e18, LIEN_i, USDC) == price`, i.e. the cached `price` **is the `equityMark` reported
  in the quote asset's native units** (USDC = 6 dp). The registry holds its own
  `uint8 constant LIEN_DECIMALS = 18` (it cannot read `LienTokenFactory.LIEN_DECIMALS()` — the factory
  deploys *after* the registry, §9 S3<S4 — so the constant is duplicated and the per-write guard ties every
  priced key to it).
- **Origination seed (controller path) + set-once controller.** Origination (§4.4a) is seeded **inside the
  controller's atomic batch** by a controller-gated `seedPrice(address lien, uint256 price)` that writes
  `cache[lien] = {price, block.timestamp}` (same guards as `_processReport`) and emits `RegistryPriceSeed`.
  Its authority is a `controller` pointer set **once** via `setController(address)` (`onlyOwner`, at wiring,
  §9) and then frozen by the deploy renounce — **not** a constructor immutable, because the registry deploys
  *before* the controller (whose own constructor takes `oracleRegistry`, §4.4) — a registry-held controller
  immutable would be a deploy-order circularity (same shape as the §4.2 factory). This is the only seam
  between §4.1's atomic seed and the controller; revaluation (events 2–3) instead goes Forwarder-direct (below).
- **`_processReport(bytes report)`** (revaluation, events 2–3; from `ReceiverTemplate.onReport`,
  immutable-Forwarder-gated): the report is the shared §4.4 envelope `abi.encode(uint8 reportType, bytes
  payload)` — decode it, **require `reportType == 3`** (Revaluation; the registry services only this type;
  fail closed otherwise), then decode `payload = (address[] liens, uint256[] prices, uint32 ts)`, require
  `liens.length == prices.length`, and write `cache[lien] = {price, ts}` in a loop. **Defensive guards (fail
  closed), applied per write on both this path and `seedPrice`:** reject `price == 0` (a zero price hits a
  free-seize path in EVK liquidation) and `price > type(uint208).max`; **strictly** require the key's
  `decimals() == LIEN_DECIMALS` (a low-level `staticcall` that **reverts** on failure — **not**
  `BaseAdapter._getDecimals`, which silently returns 18 on a failed call (`BaseAdapter.sol:40`) and would make
  the guard a no-op, §4.2); and reject a `ts` in the **future** (`ts > block.timestamp`) as a timestamp-sanity
  guard (an appraisal cannot be dated after now; the seed path uses `block.timestamp`, which always passes).
  The value is always an authoritative **Proof appraisal**, so the registry does **not** plausibility-band the
  *price* on-chain — a deviation event can legitimately re-mark a home far below its prior value, and a band
  would fight exactly that write; integrity is upstream (Proof + DON consensus + immutable Forwarder). These
  guards catch code/units bugs, not values (the future-`ts` reject is a units guard, not a value band). The
  batch is **atomic** — one bad entry reverts the whole report (no partial writes), so the CRE workflow must
  shard not only by the ≤ 5 KB report size but by a **gas-bounded** batch count, and never include a malformed
  entry, or the cohort's revaluation reverts wholesale.
- **`_getQuote(inAmount, base, quote)`** (view, override of `BaseAdapter`): read `cache[base]`, revert
  `PriceOracle_TooStale` if `block.timestamp - ts > validityWindow`, scale via `ScaleUtils.calcOutAmount`,
  return `bid==ask==mid`. Staleness here does **not** gate liquidation — liquidation is delinquency-driven
  (§4.4e), so a stale/fake price alone cannot liquidate.
- **Price path (event-driven Proof appraisal — the only value source).** The mark is **always a Proof of
  Value appraisal** (home value − senior debt); there is **no daily heartbeat, no HPI, no index drift**. It
  is written at exactly three kinds of event:
  1. **Origination** — seeded inside the controller's atomic batch (§4.4a), preserving the
     mint→price→setLTV→borrow ordering invariant.
  2. **Secondary acquisition** — when the loan is taken out / acquired on the secondary market (§4.4e), a
     fresh Proof appraisal is written for the sale.
  3. **Deviation event** — a default / material change (§11) re-appraises (for recovery).
  Events 2–3 write **direct** to the registry (off the controller's privileged surface); origination seeds
  via the controller. Between events the mark is held flat — nothing on-chain consumes it (performing loans
  are marked at par for NAV, §12; liquidation is delinquency-driven, §4.4e). Conservatism lives in the LTV
  gap (§4.2) and the recovery haircut (§11). Both the registry and the controller are CRE receivers gated on
  the same immutable Forwarder.
- **Registration (per-line router, wired at origination, frozen).** Each isolated line gets its **own
  `EulerRouter`**, minted and wired inside the venue adapter's `openLine` (§4.7) — the canonical EVK "edge
  market" pattern (`evk-periphery/src/EdgeFactory/EdgeFactory.sol:56-128`): the adapter (the fresh router's
  governor at birth) calls `govSetResolvedVault(escrowCollateralVault)` + `govSetConfig(LIEN_i, USDC,
  ZipcodeOracleRegistry)`, so `resolveOracle(amt, escrowVault, USDC)` resolves `escrowVault → LIEN_i →
  registry` (`euler-price-oracle/src/EulerRouter.sol:123-143`), then `transferGovernance(address(0))` **freezes
  it**. **The oracle key stays `LIEN_i`** (the registry still serves `cache[LIEN_i]` — §4.2 unchanged). This
  supersedes the earlier single-shared-router-fallback design (validation pass "F4"): per-line routers wired
  atomically at origination are strictly stronger than a timelock-governed shared fallback (a line's price
  wiring can **never** be re-pointed — immutable, like the renounced CRE Forwarder), and there is **no
  per-lien timelock call** (origination stays atomic). The OZ `TimelockController` is retained for §17
  **parameter** governance (szipUSD floor / `f` / cooldown), **not** as a router governor. Trade-off: a
  mis-wired or compromised registry can't be re-pointed for an already-open line — recovery is "open a new
  line" (consistent with the immutable-Forwarder philosophy, §13).
- **Modeled on:** `RedstoneCoreOracle` (updatePrice→cache→stale-checked view) generalized to multi-asset.

### 4.2 `LienCollateralToken` + `LienTokenFactory`
- ERC-20, one instance per lien (EVK collateral must be ERC-20-shaped; no native NFT collateral).
- **Fixed total supply of exactly `1e18` (one whole token at 18 decimals), minted once to the controller
  at creation — only after the Proof of Lien + Proof of Insurance gates pass at origination (§4.4a/§8.5);
  `mint`/`burn` restricted to `ZipcodeController`.** "1/1" = one token, one lien. The unit
  total supply makes the borrowing identity clean: with the registry pricing `1 lien → equityMark` (§4.1),
  the collateral value of the whole position is `equityMark`, so **max borrow ≈ `equityMark × borrowLTV`**.
- **Decimals pinned to the constant `18`** (the token overrides `decimals()` to return 18, never relying
  on a fallible call): `BaseAdapter._getDecimals` silently returns 18 on a failed `decimals()` staticcall
  (`euler-price-oracle/src/adapter/BaseAdapter.sol:40`), so an off-by-decimal is a silent 10× mispricing;
  pinning makes the registry's per-lien scale (§4.1) exact.
- Registered as collateral on the lien's isolated market via `Governance.setLTV(lienToken, borrowLTV, liqLTV, ramp)`.
  The `borrowLTV` vs `liquidationLTV` gap is **where the appraisal-error + value-staleness conservatism
  lives** — the oracle reports the honest equity mark (§4.1) and holds it flat between Proof events, so the
  LTV gap is the cushion. **Venue note:** the ERC-20 shape suits EVK collateral; on another venue the
  collateral registration goes through `IZipcodeVenue.openLine/setLineLimits` (§4.7).
- **`LienTokenFactory` deploys via CREATE2** with `salt = keccak256(abi.encode(lienId))` and a fixed
  init-code (decimals/name/symbol hardcoded; the **only** constructor arg is `controller`, constant across
  liens), so the controller/CRE can **precompute** the address before the origination batch (note: EVK's
  `GenericFactory` is not CREATE2, so this is a net-new factory). **`create(bytes32 lienId)` takes the caller
  (`msg.sender`) as the new token's mint/burn authority** (§9 trace `LienTokenFactory.create(lienId)`) — the
  factory holds **no** controller immutable (which would be a deploy-order circularity, since the
  `ZipcodeController` constructor takes `lienFactory`, §4.4, so the factory must deploy *first*). The token's
  `controller` is therefore immutable at the **token's own** construction (audit/3-results row 18), set from the
  caller. Because the CREATE2 init-code embeds that caller, **the address binds to the caller**: a lien's slot is
  derived from `(lienId, controller)`, so it is deterministic in `lienId` for the single `ZipcodeController` and
  **inherently squat-proof** — an attacker calling `create(lienId)` only ever produces a token authorized to
  *themselves* at a *different* address; they can never occupy or grief `LIEN_i` (derived from
  `ZipcodeController`), so the origination batch's CREATE2 cannot be forced into `FailedDeployment`. No
  authorization gate is needed on `create`; the caller-binding is the authorization. The precompute view is the
  explicit two-arg `computeAddress(bytes32 lienId, address controller)` (anyone can predict any lien's address
  deterministically; the controller calls it with `address(this)`).
- **Identity & oracle binding.** Name and symbol are **constant across all lien tokens** (hardcoded —
  `name = "Zipcode Lien Collateral"`, `symbol = "zLIEN"`), so the init-code (hence its CREATE2 init-code
  hash) is identical for every lien and the address precomputes from `lienId` alone. A lien's **identity is
  its address**, not its name: `lienId → salt = keccak256(abi.encode(lienId)) → LIEN_i`, and the
  `LienCreated(lienId, LIEN_i)` event records the link on-chain. That same address is the **oracle key** —
  the registry caches and serves price as `cache[LIEN_i]`, and each line's per-line `ROUTER_i` (wired + frozen
  inside `openLine`, §4.7) resolves every `(LIEN_i, USDC)` query to it (§4.1). So `lienId → address → cache → router` is one deterministic chain; the
  registry never stores `lienId` (it operates purely by token address). Per-lien human-readable names are a
  later option (a `lienId`-derived constructor arg — still precomputable, but per-lien init-code), not needed
  for an internal 1/1 collateral token.

### 4.3 `CREGatingHook` — `is IHookTarget`
- `isHookTarget()` validates `msg.sender` is a vault from `GenericFactory` and returns the selector.
- `fallback()` extracts the appended 20-byte caller (`shr(96, calldataload(sub(calldatasize(),20)))`)
  and reverts unless the **borrow-driver** is the caller's **authorized EVC operator** —
  `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`
  (`ethereum-vault-connector/src/EthereumVaultConnector.sol:286`, internal `:1205-1221`). The **`borrowDriver`**
  is the address that makes the `EVC.call(borrowVault, borrowAccount, …)` — the **`EulerVenueAdapter`** (the EVC
  authenticates *it* as the operator, since the controller drives every venue effect **through**
  `IZipcodeVenue.draw`, §4.4/§4.7); it equals the controller **only if M1 collapses the adapter into the
  controller** (one address). **This is an operator-authorization check, not an owner check.** Each credit line
  borrows on a **fresh per-line EVC account** with its **own owner-prefix** (§4.4), and the borrow-driver is
  wired as that account's **operator** (by the per-line `LineAccount`, §4.4) to drive the borrow on-behalf — so
  `haveCommonOwner(caller, borrowDriver)` is **false** (the borrower is *not* a borrow-driver sub-account). The
  operator check is the venue-neutral invariant the hook enforces: "only an account that has authorized the
  borrow-driver as its EVC operator may borrow here." A naive `haveCommonOwner`/`caller == borrowDriver` would
  reject **every** line (no line shares the borrow-driver's prefix). `isAccountOperatorAuthorizedInternal` is
  keyed on the caller's address-prefix owner and checks `operatorLookup[prefix][operator]` (`:1220`), returning
  `false` for an unregistered prefix (`:1213`) — so the gate clears **only** when `operator == borrowDriver`
  (the exact `EVC.call` caller) and the line's owner granted it the operator bit (§4.4).
- Installed via `setHookConfig(hook, OP_BORROW | OP_LIQUIDATE)`. **The `OP_LIQUIDATE` gate is purely
  defensive** — a line can drift past `liqLTV` from interest accrual (§10), and the gate blocks any *external*
  party from seizing that interest-underwater position via EVK liquidation; the controller does **not** call
  liquidation as a resolution path (there is no on-chain economic liquidation for a home lien, §4.4e).
  **Repay is deliberately ungated** (permissionless): `Borrowing.repay` runs `initOperation(OP_REPAY,
  CHECKACCOUNT_NONE)` (`Borrowing.sol:82`) and reduces the *receiver*'s debt regardless of caller
  (`decreaseBorrow`, `Borrowing.sol:91`), so gating it would only block honest paydown without adding
  protection.
- **Caller semantics (why the operator check is the right primitive):** the 20-byte caller EVK appends is the
  EVC `onBehalfOfAccount` — the **borrowing account**, not the operator — `Base.initOperation` sets `account =
  EVCAuthenticateDeferred(...)` and passes it to `callHook`, and `invokeHookTarget` appends that same
  `account` (`euler-vault-kit/src/EVault/shared/Base.sol:87,89,132`; `EVCClient.sol:49` returns
  `onBehalfOfAccount`). The borrow-driver never borrows on its own behalf — it drives the borrow as the **EVC
  operator** of the per-line account (`EVC.call(borrowVault, borrowAccount, 0, borrowData)`, authenticated via
  `authenticateCaller(account, allowOperator: true, …)`, `EthereumVaultConnector.sol:782`). The borrow-driver
  (and hence the hook's **`borrowDriver`** immutable) is **the address that makes the `EVC.call`** — the
  `EulerVenueAdapter`, since the controller drives venue effects through `IZipcodeVenue.draw` (§4.4/§4.7); in M1
  the adapter may be the controller (collapsed). So the hook checks the *appended borrowing account*, and the
  borrow passes **only when that account has authorized the borrow-driver as its operator** (granted by the
  line's `LineAccount` at origination, §4.4) — i.e. the line is a registered, adapter-driven line.
- **Venue boundary.** This hook is **internal to the Euler venue adapter** — it is how the EVK enforces
  "only the borrow-driver (the adapter, as the line account's operator) may borrow/liquidate." It is **not** part of the
  portable core; on another venue the same invariant (the controller is the sole borrower-of-record) is
  enforced by that venue's own mechanism behind `IZipcodeVenue` (§4.7). Repay stays permissionless on every venue.
- **Modeled on:** `BaseHookTarget`.

### 4.4 `ZipcodeController` — `is ReceiverTemplate` (the orchestrator)
The single trusted on-chain identity and the **portable core's** command center. It holds the
**venue-neutral** authorities: the **CRE receiver** (inbound gated on an **immutable** Forwarder), the
**report decode + decision logic** (branches below), and **lien-token mint authority**. Every on-chain
**venue effect** — funding a line, setting LTV/caps, drawing, closing, liquidating — it drives through the
**`IZipcodeVenue`** adapter (§4.7), **not** by calling EVK/EulerEarn directly. For
configuration one the adapter is the **`EulerVenueAdapter`**, which holds the Euler-specific roles: EulerEarn
**allocator + curator** (per-line market onboarding inside `openLine`, §4.7), **per-line `EulerRouter` governor
at birth → frozen** (each line's router is minted, wired to the registry, and `transferGovernance(address(0))`-frozen
inside `openLine`; no shared/timelocked router, §4.1/§4.7), isolated-market **governor** (retained, to re-tune
LTV/caps per report), and is the **EVC operator** of each line's fresh borrower account, which the **gating
hook** authorizes for borrow + liquidate (repay ungated). The OZ `TimelockController` governs §17
**parameters**, not the routers.

**Immutable Forwarder (enforced by the subclass, not inherited):** `ReceiverTemplate` ships a
`setForwarderAddress` `onlyOwner` setter (`x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol:127`)
and is `Ownable` — but that setter and `onReport` are **non-virtual** (verified), so they **cannot be
overridden**. Immutability is instead enforced by **renouncing `Ownable` ownership** after wiring (the
alternative — implementing `IReceiver` directly with an `immutable s_forwarderAddress` — is also valid but
not used in M1): once `owner() == address(0)` every `onlyOwner` setter (`setForwarderAddress`,
`setExpectedAuthor`, `setExpectedWorkflowId`) reverts `OwnableUnauthorizedAccount`, permanently freezing the
constructor-set Forwarder and the wired identity. Renounce **only after** setting the workflow-identity
expectations (`setExpectedAuthor`, `setExpectedWorkflowId`, §9) — the deploy script MUST assert
`getExpectedWorkflowId() != 0` immediately before `renounceOwnership()` and abort otherwise, or the identity
check is permanently bypassed and **any** workflow the Forwarder relays could call `onReport`. (The base
constructor reverts on `address(0)` (`:45`), so the "permissionless on zero-Forwarder" path `:82-85` is
unreachable once ownership is renounced.) **The controller is the on-chain borrower of
record:** the originator is not an on-chain actor — they apply and draw via API; the adapter performs every
on-chain `borrow` as the **EVC operator** of the line's fresh borrower account (the controller drives it
on-behalf), and the dollar leg (USD wire to the originator, USD collection on repayment) is handled off-chain
by **Erebor** (§9).

**Constructor (sketch).** `ZipcodeController(address forwarder, address venue, address lienFactory, address
oracleRegistry, address erebor)` — all immutable; `venue` is the `IZipcodeVenue` adapter; `erebor` is the
draw off-ramp the controller passes to `venue.draw` (the adapter validates `receiver == its own erebor`, so
the two are wired to the same address — defense-in-depth). For config one the
`EulerVenueAdapter(controller, evc, eulerEarn, eVaultFactory, oracleRegistry, gatingHook, irm, usdc, erebor)`
is wired separately and holds the Euler roles (it mints + freezes a per-line router itself; **no shared-router
or timelock arg** — the timelock governs §17 params only). M1 may collapse the adapter into the controller as
long as the `IZipcodeVenue` seam is preserved, so venue two is a drop-in adapter. (The controller does **not**
take the EVC as an immutable — the EVC is venue-specific. With the **per-line** borrower model the operator
grant is issued **per line at origination** by the adapter's per-line `LineAccount` (below), not by a one-time
controller-level wiring call, so the controller needs no EVC handle at all — keeping the core venue-neutral.)

**Borrower-of-record mechanism (Euler adapter, internal) — a fresh per-line account, controller-as-operator.**
EVC enforces a single controller (borrow vault) per account, so concurrent borrows need distinct *borrowing
accounts*. Rather than draw those from the controller's own 256 sub-accounts (a hard 255-line cap — the
controller's prefix has only sub-accounts 0…255), **each line gets its own fresh EVC account with its own
owner-prefix**, deployed by the adapter inside `openLine` (§4.7). The borrow-driver (the `EVC.call` caller =
the **`EulerVenueAdapter`**, not the controller contract — see the operator-identity reconciliation below) is
wired as that account's **EVC operator** so it can drive the borrow on-behalf. Because every line has a distinct prefix, the protocol
hosts **unbounded concurrent lines** — the disposable per-loan clusters (borrower account + USDC debt vault +
escrow collateral vault + lien token + per-line oracle/router) are simply abandoned at close (the on-chain
"graveyard" is accepted — zero ongoing cost, §17).

The wiring discharges an EVC constraint that the old single-controller scheme hid. Operator authorization is
keyed on the **borrowing account's address-prefix owner** (`isAccountOperatorAuthorizedInternal` returns
`false` for an unregistered prefix, `EthereumVaultConnector.sol:1213`), and an operator may only act on-behalf
of a **code-free** account (`authenticateCaller` rejects a contract-coded non-owner account,
`:786-789`). So per line the adapter CREATE2-deploys a **minimal per-line owner contract** (`LineAccount`,
salt = `lienId`) whose deterministic address establishes a fresh prefix; on init it registers its prefix and
calls `EVC.setAccountOperator(borrowAccount, operator, true)` (`:364`, owner-self path `:372-377`) for a
**code-free sub-account it owns** (e.g. sub-account 1 of its own prefix — the borrow account that holds the
debt + collateral, never the contract's own coded address). The lien token is the collateral enabled on that
borrow account; the per-line USDC borrow vault is its single controller (single-liability). The **operator**
then borrows: `EVC.call(borrowVault, borrowAccount, 0, borrowData)`, which the EVK reads as
`onBehalfOfAccount == borrowAccount` and the gating hook (§4.3) clears via `isAccountOperatorAuthorized`.
**The "operator" here is the address that actually makes the `EVC.call` — the `EulerVenueAdapter` itself**,
since the controller drives every venue effect **through** `IZipcodeVenue.draw` (the adapter is `EVC.call`'s
`msg.sender`, so the EVC authenticates the adapter, not the controller). So the `LineAccount` grants the
**adapter** the operator bit, and the §4.3 hook's `borrowDriver` immutable is wired to that **same** address (the
borrow-driver). In M1 the adapter may be collapsed into the controller (§4.7), in which case they are one
address; when distinct, "the controller" in this section's prose means the adapter's privileged borrow-driver
identity — the EVC actor and the hook gate are the same address by construction. The
fresh-account model is **strictly more isolated** than the old blanket grant: there is **one operator grant
per line**, over **one** borrow account on its **own** prefix — no shared sub-account space, no blanket
`setOperator(prefix, …, ~uint256(1))`, and a buggy/compromised operator grant on one line cannot reach another
line's account (each is a separate prefix). This per-line scheme is **Euler-specific** — another venue enforces
the same "controller is the only borrower" invariant its own way behind `IZipcodeVenue`.

**Report ABI (shared by the Go workflow's `GenerateReport` and the on-chain `_processReport` decode).**
Every report is `abi.encode(uint8 reportType, bytes payload)`; `reportType` selects the branch and the
`payload` decode. The CRE workflow targets the correct `Receiver` per type (controller for 1/2/4/5/6,
registry direct for 3, `SzipNavOracle` direct for 7, `DefaultCoordinator` for default/recovery, §8):
- `1` Origination — `payload = (bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount, uint256 cap)`
- `2` Draw — `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)`
- `3` Revaluation — `(address[] liens, uint256[] prices, uint32 ts)` (→ registry)
- `4` Close — `(bytes32 lienId)`
- `5` Default / `6` Liquidation — `(bytes32 lienId, uint8 status)`
- `7` NAV leg price — `(uint8[] legs, uint256[] prices, uint32 ts)` (→ `SzipNavOracle`, §7) — the off-chain junior-basket leg marks (the xALPHA `alphaUSD` leg; HYDX/USDC if the pool is thin) the NAV oracle cannot read on Base; every **quantity** and every on-chain leg price (zipUSD/USDC $1, the xALPHA LST exchange rate, oHYDX intrinsic, the ICHI LP reserves) is read trustlessly on-chain, never pushed.

`equityMark` is the **Proof of Value** mark (home value − senior debt, §4.1). `proofRef` is a commitment to
the Proof attestation bundle (lien-perfected + value + insurance) for on-chain provenance; the lien and
insurance **gates** themselves are off-chain preconditions — the CRE only emits the report if they pass
(§8.5). `regionalHPI` is **removed** from every payload (no on-chain drift, §4.1).

`_processReport` branches on `reportType` (venue effects go through `IZipcodeVenue`, §4.4 part 1):
- **(a) Origination** → `LienTokenFactory.create` (mint 1/1 token, after the Proof gates, §4.2) →
  `venue.openLine(lienId, LIEN_i, 1e18)` returns `(line, oracleKey)` (mints + freezes the per-line market +
  router, §4.7) → seed `ZipcodeOracleRegistry` `cache[oracleKey]` with the **Proof of Value** mark (atomic
  seed of the `oracleKey` **openLine returns** — `oracleKey == LIEN_i`; the per-line router wired inside
  `openLine` resolves `escrow → LIEN_i → registry`, §4.1/§4.7, so the controller makes **no** router call) →
  `venue.setLineLimits(borrowLTV, liqLTV, cap)` → `venue.fund(line, drawAmount)` +
  `venue.draw(line, drawAmount, Erebor)`. **Ordering invariant:** `create → openLine → seed → setLineLimits →
  fund → draw` — `openLine` precedes `seed` so the controller seeds exactly the key the router resolves to, and
  `seed` precedes `draw` because the borrow's account-status check reads the mark (an un-seeded key reverts
  `PriceOracle_NotSupported`); the whole branch is one atomic `onReport` call (any revert rolls back the CREATE2
  deploy — no orphan lien/market/seed). **`drawAmount` is carried in the report and bounded on-chain** by
  `borrowLTV × equityMark` and the line `cap` (the venue's account-status check rejects an over-LTV borrow), so
  a bad report cannot draw beyond `borrowLTV × the reported mark` (the on-chain bound is on `draw/mark`, not on
  the mark's truthfulness — a forged-high mark over-borrows within that ratio, mitigated upstream by Proof +
  DON consensus + the borrowLTV/liqLTV cushion, not by an on-chain value band, §4.1/§13). The drawn USDC routes
  to the Erebor off-ramp, which wires USD to the originator. (The Euler adapter realizes this as
  `GenericFactory.createProxy`/`setLTV` + the per-line `LineAccount` deploy/operator-grant →
  `EVC.batch([EulerEarn.reallocate, borrow on the line's fresh borrow account])`, §4.3/§4.4 mechanism.)
- **(a′) Draw** → a later draw on an open line is the same `fund`+`draw` step, driven by a fresh report that
  carries a **fresh Proof of Value re-anchor** (a line that has outlived its validity window must re-appraise
  to draw, §4.1) and re-checks delinquency; the new `drawAmount` is again LTV/cap-bounded. Funding is
  fund-at-draw; there is no idle pre-funded facility.
- **(b) Revaluation** → an **event-driven** re-mark (secondary acquisition or a deviation event, §4.1 price
  path) is written **direct** to `ZipcodeOracleRegistry` by the workflow, not routed through the controller.
  There is no heartbeat.
- **(c) Close/release** → once debt is confirmed zero (`venue.observeDebt`; repay is permissionless, §9),
  `burn` the lien token (controller mint authority) and emit `LienReleased(lienId)` to signal off-chain SPV
  release. Closing is controller-only even though repaying is not.
- **(d) Default** → mark delinquent/default and emit the status + legal-action event; the loss-side flow
  (**mark-to-recovery** set from the deviation-event Proof re-mark, §4.1; **Duration Bond**; **off-chain
  insurance**; **xALPHA** premium/slash; recovery) is driven by `DefaultCoordinator` (§4.6, §11). Markdown is
  **not** applied here — it comes from the deviation re-appraisal (§4.1) and is realized by the
  `DefaultCoordinator` step (§11).
- **(e) Liquidation / secondary acquisition** → **there is no on-chain economic liquidation.** A home cannot
  be atomically seized and sold on-chain, and the 1/1 lien token has no liquidator market — so `venue.liquidate`
  is a **defensive control surface, not a mechanism**: the `CREGatingHook` gates `OP_LIQUIDATE` to the
  controller **only to block an external party from seizing an interest-underwater line** (§4.3), and the
  controller itself **never calls it to liquidate**. Real resolution is **off-chain** — a **secondary purchase**,
  or **insurance + foreclosure** — surfaced on-chain only as **permissionless `repay`** that zeroes the debt
  (then the controller closes the lien, §4.4c); the markdown / recovery bookkeeping is the `DefaultCoordinator`
  (§4.6, §11, **M2**). **M1 builds no liquidation execution path** — only the defensive gate. The
  `IZipcodeVenue.liquidate` method stays in the interface (venue-completeness / future secondary acquisition)
  but is a **controller-only stub in M1**. (Secondary acquisition / MBS absorption — the §4.1 "secondary
  acquisition" price event where a takeout buys the debt and the position transfers to the buyer — is
  deferred, `vision.md` stage THREE.)

### 4.5 Supply-side contracts
- **`CreditWarehouse` — the senior-backing custody Safe (CRE-administered via the Zodiac Roles Modifier v2).** A
  plain **Gnosis Safe** that custodies the protocol's **`EulerEarn` pool shares** — the senior backing for all
  outstanding zipUSD float (the "protocol's holding," replacing the deposit-module-as-custodian of the deleted
  convert-on-stake model). Its **owner** is a **GOD-EOA at launch, upgraded to a governance multisig** via the
  Safe's native `swapOwner` / `addOwnerWithThreshold` (no migration contract) — break-glass + policy admin, can
  re-scope or disable the admin module or act through the Safe directly. **Two Safes, never commingled:** this
  senior warehouse Safe vs the junior Baal `szipUSD` Safe — Loot `ragequit` touches only the junior basket and
  can never reach senior backing (the structural separation behind the §11 freeze model).
  - **Structure (allocator).** `EulerEarn` is an **allocator** — it directs the deposited USDC across a
    **`USDC Resting Vault`** (the un-utilized USDC not yet lent) + the **per-line isolated credit lines** (§4.7). The
    strike loop (8-B5, §4.5.1) **borrows the un-utilized `USDC Resting Vault`** against ICHI-LP collateral (CRE-only,
    over-collateralized, short-term) — there is **no separate "treasury" borrow vault**; the strike is safe by
    collateral, not by avoiding depositor capital.
  - **Admin = the Zodiac Roles Modifier v2** (audited Gnosis Guild infrastructure — `reference/zodiac-modifier-roles`;
    the production-canonical pattern for scoped keeper/treasury automation, run by karpatkey/ENS/Gnosis/Balancer).
    It is `enableModule`'d on the Safe and **scoped by an owner-applied permissions policy** to exactly the
    warehouse op-set — **no bespoke privileged contract is authored.** **Hard truth driving the choice
    (decided 2026-06-06, user-ratified; `reports/research/zodiac-warehouse-research.md`):** no external guard can contain
    an enabled module (a Safe Transaction Guard covers only the owner `execTransaction` path pre-Safe-1.5.0;
    Zodiac's `GuardableModule` is voluntary self-policing), so the scope **must** live inside the enabled
    contract — we use the *audited* Roles engine rather than fresh bespoke bytecode guarding all senior backing.
  - **The permissions policy (the role's scope).** Via `scopeTarget` / `scopeFunction` + a `ConditionFlat[]`
    condition tree (`reference/zodiac-modifier-roles/packages/evm/contracts/PermissionBuilder.sol:133`), the role
    is restricted to exactly these calls, all **Call-only** (`ExecutionOptions=None` — no `delegatecall`, no
    value; `PermissionChecker.sol:187-211`), with params **pinned** (`EqualTo` / `EqualToAvatar`):
    | op | Permitted call (params pinned) | purpose |
    |---|---|---|
    | SUPPLY | `EE_POOL.deposit(amount, receiver==SAFE)` | put routed USDC to work |
    | APPROVE | `USDC.approve(spender==EE_POOL, amount)` | the allowance `deposit` pulls against |
    | REDEEM | `EE_POOL.redeem(shares, receiver==<pinned>, owner==SAFE)` | fund the epoch queue / recovery |
    | REPAY | `USDC.transfer(to==LOANBOOK, amount)` | waterfall — fill a capital hole |
    Anything outside the policy reverts in the Roles checker **before** the Safe is touched; widening it requires
    the Safe **owner** (GOD-EOA → multisig). Policy authored "as code" via `reference/permissions-starter-kit`
    and applied as an owner-signed diff. (Optional `WithinAllowance` rate-limits per op are available.)
  - **The CRE seam (role member + encoding adapter).** A thin **`is ReceiverTemplate` CRE receiver** — immutable
    KeystoneForwarder-gated (`onReport`, set-once then renounce-immutable, exactly as §4.1/§4.4) — is
    `assignRoles`'d as the role's member (`Roles.sol:69`; an immutable-contract member is supported). On a report
    it decodes the §4.4 envelope `abi.encode(uint8 opType, bytes payload)`, ABI-encodes the corresponding
    permitted Safe call, and invokes `Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`
    (`Roles.sol:153`); the Roles Modifier validates against the policy and forwards to the Safe. This
    receiver/adapter is the **only Solidity authored on this seam** — it holds no custody and enforces no scope
    itself (the audited Roles engine does), so its surface is minimal.
  - **Senior NAV mark (§12):** `EE_POOL.convertToAssets(EE_POOL.balanceOf(SAFE))`. **Wiring:** the zap
    (`ZipDepositModule`, re-authored) deposits with the warehouse Safe as the EE-share `receiver`; the redemption
    queue (§6.1) draws via REDEEM; the recovery waterfall (§11/§4.6) via REPAY. **Open items for the 8-Bw ticket**
    (`reports/research/zodiac-warehouse-research.md`): confirm EulerEarn `redeem(shares, receiver, owner)` arg order +
    whether redeemed USDC lands in the Safe (`receiver==SAFE`, then REPAY distributes) or directly at a sink; the
    APPROVE standing-infinite-vs-exact-amount choice. Optional defense-in-depth: a **Delay Modifier** behind the
    role (owner-cancellable cooldown on a compromised-CRE action).
- **`ZipDepositModule` — mint at $1, with a zap.** `deposit(uint256 usdc)`: pull USDC, **mint zipUSD 1:1 by
  value** (zipUSD = `ESynth`, the module is the capacity-granted minter), deposit the USDC into the venue pool
  (`EulerEarn` for config one). Peg held by the 1:1 mint, not a swap. **`zap(uint256 usdc)` is the default
  UX:** deposit → mint zipUSD → **auto-stake into `szipUSD`** in one atomic call, so the depositor lands in
  the headline yield position (§2/§5). zipUSD is the user's $1 claim against the pool's NAV; the
  **`CreditWarehouse` Safe** (above) is the EE-share custodian — `deposit`/`zap` deposit the USDC into the pool
  with the **warehouse Safe** as the share `receiver`, so the warehouse holds all `EulerEarn` shares backing
  un-staked zipUSD (the "protocol's holding"); the module itself holds **no** shares. No instant redeem here — zipUSD redemption is the
  epoch queue (§6.1) or the secondary market (§6.2); the junior exits on its own cooldown (§6.4).
  **Decimals (verified — `ESynth` is fixed-18, not constructor-settable).** zipUSD = `ESynth` reports **18
  decimals** (OZ ERC20 default; the ctor is `(address evc, string name, string symbol)` — no decimals arg).
  USDC is **6 decimals**; `EulerEarn` shares over a 6-dp asset are **6 decimals** (offset 0; `VIRTUAL_AMOUNT
  = 1e6` → shares ≈ assets at par). So "1:1" is **value**-1:1: `deposit(usdc)` mints `usdc * 1e12` zipUSD
  (`1e12 = 10**(18 − 6)`), and any zipUSD↔share/USDC conversion carries the same `1e12` scale. All cross-asset
  invariants are stated in **normalized dollars**, not raw units.
  **Exit-Gate seam (set-once wiring).** The module exposes a **set-once `setGate(gate)`** (deploy-time,
  deployer-gated): it stores the **Exit Gate** address. The zap grants the gate a **per-zap zipUSD allowance** and
  calls **`gate.depositFor(zipUSD, zipAmount, user)`** with the end user as `receiver`; the gate pulls the
  `zipAmount` zipUSD by `transferFrom`, **values it via `SzipNavOracle` (NAV-proportional, §7), mints Loot to
  itself, and mints transferable szipUSD to the user** (on-behalf), returning the `shares`. There is **no** EE-share
  allowance — the warehouse Safe holds the EE shares. After wiring, the module has no owner surface (permissionless
  `deposit`/`zap`). (Build ticket: **WOOF-06**, re-authored to this seam.)
- **`szipUSD` — the junior NAV vault, the main product (§6/§11).**

  > **MODEL LOCKED 2026-06-07 — the current spec is the two-token model above (§2/§4.5/§6.4/§7/§11) +
  > `baal-spec.md`.** The narrative below predates that lock. **CURRENT (build from it):** the Baal+Zodiac substrate,
  > the multi-asset basket held natively in the Safe, the windows + sidecar-freeze, the auto-sodomizer engine.
  > **SUPERSEDED (do NOT build from the phrasing below):** *NAV-display-only* → NAV is the pricing primitive (§7);
  > *withhold-with-no-markdown* → pari-passu conservative provision-that-recovers (§11); *soulbound szipUSD claim* →
  > transferable szipUSD share (the soulbound is on the Loot); *ERC-4626 / convert-on-stake / `J×p` / pool-shares* →
  > Gate-minted NAV-proportional share. Read it for engine/substrate color, not for share/NAV/loss semantics:
  > - **Substrate = Baal (Moloch v3) + Zodiac** (user-decided 2026-06-06, reversing an interim 7540 lean — we do
  >   NOT need 7540's single-asset exit / 4626 composability; Baal's native multi-asset treasury + oracle-free
  >   loss-socialization + programmable shaman/Zodiac control fit better). Depositor share = **Loot** (a
  >   transfer-gated ERC20 exit-claim); treasury = a **Gnosis Safe** holding the basket natively; exit =
  >   **ragequit** (pro-rata, **in-kind** across the basket — single-asset conversion NOT required). NOT a
  >   convert-on-stake 4626 over pool shares; NOT a single-numeraire 7540 vault. Baal + Zodiac are cloned into
  >   `reference/` (pragma 0.8.7 → **summon** a live DAO + Safe and drive it via the CRE module, fork-test).
  > - **Holds a multi-asset basket NATIVELY in the Safe**, with room for **several strategies running in harmony
  >   at different times** (multi-strategy via multiple Zodiac modules/shamans): zipUSD (deposits), **xALPHA**
  >   (reward emissions), the **zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex** (oHYDX), the reservoir/borrow leg,
  >   etc. **NAV is a TRACKED/DISPLAYED number** (computed from **multiple oracle sources** for the basket
  >   assets) — a dashboard/monitoring concern, **NOT** a redemption-accounting primitive. Ragequit is
  >   balance-pro-rata, so loss socializes automatically with no markdown math and no oracle in the exit path.
  > - **CRE strategy-admin robot = a manager shaman** (mint/burn Loot on deposit/exit) **+ Zodiac module(s)**
  >   (`execTransactionFromModule` on the Safe) running the loop (post LP → gauge-stake → claim oHYDX → pull LP →
  >   reservoir collateral → borrow USDC → exercise oHYDX → sell HYDX→USDC → repay → mint zipUSD → swap to xALPHA
  >   → re-LP). Multiple modules = multiple strategies.
  > - **TWO distinct exit gates (both via the Exit Gate, §6.4 — depositors hold no raw Loot, so raw `ragequit`
  >   is impossible; the gate is the sole Loot-holder):** (1) **WINDOWS** — exits are an intent queue processed
  >   only in liquidity windows (the harvest ICHI-unstake cadence). (2) **FREEZE
  >   (duration bond)** — structural: a pro-rata NAV amount sized to however much
  >   must stay backed to cover the hole / duration issue**, while the frozen capital **keeps earning** from the
  >   underlying strategies ("frozen but earning"); released on the objective resolution trigger.
  > - **First-loss / duration is NOT a markdown and NOT a seizure (user correction 2026-06-06): you do NOT cover
  >   a hole by spending or handling the zipUSD.** The only lever is to **WITHHOLD the at-risk zipUSD from
  >   withdrawal** (via the FREEZE) so a ragequit cannot drain it out of the backing (and out of the LP pool)
  >   while the duration is being managed; the withheld zipUSD stays as backing and **keeps earning**. A
  >   genuinely unrecoverable residual loss socializes **passively** (ragequit reflects the actual remaining
  >   basket); the protocol never actively spends zipUSD to plug a hole. The recovery waterfall (secondary →
  >   insurance → xALPHA-duration → xALPHA-hole → HYDX-farmed USDC) buys the time the freeze holds. NO "burn
  >   `loss/p` pool shares," NO NAV-markdown event, NO rate-snapshot.
  > - **Build/validate by Foundry FORK of live Base** — summon a real Baal DAO + Safe on the fork and drive it
  >   via the CRE module against the real ICHI/gauge/oHYDX/NFPM/EulerEarn with **stand-in pool/gauge addresses**
  >   (our zipUSD/xALPHA gauge whitelist is pending the Hydrex OTC); production = swap addresses.
  > - **Decomposes into the 8-B build tickets** (substrate 8-B1, `SzipNavOracle`, the Exit Gate, engine 8-B5…8-B14;
  >   see `baal-spec.md` §13 + `tickets/PROGRESS.md` item 8). **The §2/§5/§6.4/§7/§11/§12/§17 money-model text was
  >   rewritten to the two-token / NAV-oracle / provision-that-recovers model (2026-06-07); `audit/1` I1–I4 still need
  >   a re-derivation pass.** Tickets are now authorable against the rewritten mechanism.

  Stake zipUSD → szipUSD; the deposit
  zap (above) lands here by default. **szipUSD IS the vault share — `sdVAULT` collapses into it** (resolved
  2026-06-05): one junior token does subordination + first-loss + the duration-freeze + the depositor reward,
  and the Hydrex/oHYDX yield-engine is a **post-M1 module that bolts onto this same vault** (no new token; see
  the `sdVAULT` bullet below). **M1 scope = the vault shell:** deposit zipUSD → a freezable,
  first-loss(-residual) ERC-4626 share whose **depositor return is the xALPHA subsidy** (the real lending
  perf-fee is the **protocol's**, privatized to the treasury → xALPHA, §5/§17 — **not** the depositor's yield).
  The shell exposes the seams the post-M1 modules plug into (a reward-distribution hook, the **freeze gate**).
  **The freeze (Duration Bond, §11) is a redemption-gate on a pro-rata share subset that keeps accruing while
  frozen** ("frozen but printing"), released on an **objective DON-verified solvency-restored trigger** — never
  a discretionary or indefinite lock, never a seizure. The staked zipUSD is the subordinated principal the
  junior puts at risk; the lending perf-fee routes **protocol-side** (`feeRecipient`, §5 — M1 destination
  settled with the treasury module, §17). (**Venue note:** the supply-side yield capture is venue-coupled —
  its portability is a deferred item, §4.7.)
  **Deposit/exit mechanism (two-token model).** Entry is via the **Exit Gate** (which holds Baal `manager`,
  absorbing the old mint shaman): **`gate.depositFor(zipUSD, zipAmount, receiver)`** (the zap passes `receiver = the
  end user`; a direct depositor passes itself). The gate pulls `zipAmount` zipUSD by `transferFrom` into the **Safe
  basket**, **values it via `SzipNavOracle` (NAV-proportional, §7)**, mints **Loot to itself**, and mints
  **transferable szipUSD to `receiver`** (round-down). szipUSD holds the multi-asset basket (zipUSD + xALPHA + the
  ICHI LP), **never EE pool shares**. **Exit:** *patient* = the gate's windowed ragequit at `min(spot,twap)` NAV
  (partial-fill, §6.4); *impatient* = sell szipUSD on a CoW book (§6.2). **First loss = a pari-passu conservative
  provision-that-recovers** (§11): the freeze handles the duration; the `DefaultCoordinator` writes a **small
  conservative markdown** at recognition (the underlying is insured/collateralized → duration-risk) that re-marks on
  verified facts and writes back up — **not** withhold-with-no-markdown. The depositor's return is the **HYDX-vamp +
  xALPHA subsidy** (the lending fee routes protocol-side, §5/§17) + the in-kind **xALPHA Duration-Bond premium**
  (§11). **No subordination cap; pari passu inside the junior.** The **coverage floor is the freeze itself** (§6.4),
  not a separate cooldown/floor knob.
- **The auto-sodomizer engine = the szipUSD vault's CORE strategies (Baal shamans + Zodiac modules), NOT a
  post-M1 bolt-on.** szipUSD is a **Baal/Moloch-v3 + Zodiac** vault (§4.5 guardrail): the depositor share is
  **Loot**; the **Gnosis Safe** holds the basket (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP); exit is
  **ragequit** (in-kind, pro-rata). The "strategies that must be built on the Zodiac side" — each a Zodiac
  module (`execTransactionFromModule` on the Safe) or a Baal shaman, all driven by the CRE strategy-admin
  robot — are the ticket-level components:
  0. **Safe authority — two-tier admin/operator (RATIFIED 2026-06-07; `baal-spec.md` 8-B1).** The summoner forces
     each Safe owned **1/1 by the Baal**, and with **zero Shares the Baal is governance-inert** (no proposal can
     pass), so the substrate must be made driveable at summon. **Admin = the team multisig added as a Safe
     owner/signer** on both Safes (cold; governs the module set — enable/disable/swap = "change what the CRE can
     do" — grants the Exit Gate `manager(2)` via `setShamans`, does all wiring through `Safe.execTransaction`).
     **CRE operator = a Zodiac module** the admin enables (hot; runs the strategy modules' `onlyOperator`
     entrypoints). Enabling a module = full Safe power ⇒ only the admin may change the set. The team owner is
     injected at summon (init-action `executeAsBaal(mainSafe,0, execTransactionFromModule(mainSafe,0,
     addOwnerWithThreshold(team,1), Call))`; main-Safe address computed from the live proxy factory + asserted ==
     `baal.avatar()`). **Shares stay 0 forever** (authority = Safe ownership, not votes). This is the canonical
     resolution of the old "post-deploy `setShamans`" seam, which was un-reachable as written.
  1. **Deposit (the Exit Gate, holds `manager` — absorbs the mint shaman).** On deposit → the Gate mints Loot to
     itself + **NAV-proportional transferable szipUSD** to the depositor (§4/§6.4/§7); enforce the **TVL cap** (gate
     deposits to the measured HYDX-pool absorption, `hydrex.md` §5 — load-bearing).
  2. **Exit Gate + sidecar (the exit/freeze mechanism — NOT a ragequit gate).** The **Exit Gate** is the canonical
     Loot custodian + szipUSD minter (it holds `manager`, absorbing the mint shaman): a deposit mints Loot **to the
     gate** and mints the depositor **transferable szipUSD** 1:1 against it (the soulbound is on the Loot, not the
     share → raw `ragequit` is impossible → no footgun, yet the share trades on CoW); exits are an **intent queue**
     processed in **liquidity windows**
     (the harvest loop's ICHI-unstake cadence) so they pay full pro-rata. The **FREEZE** is **structural**: the
     **utilization-committed** equity sits in a **non-ragequittable sidecar Safe** (`BaalAndVaultSummoner`)
     running the auto-sodomizer (frozen-but-earning, sized to credit-warehouse **utilization**), so window exits reach
     only the free main-Safe equity; objective release; **owned by the Exit Gate** — `DefaultCoordinator` only writes
     the NAV markdown (§4.6/§11). Full mechanism: §6.4.
  3. **LP strategy module.** Take zipUSD + xALPHA from the Safe → post the **ICHI single-sided zipUSD/xALPHA
     LP** → **gauge-stake** it (gauge-staking is required to earn oHYDX — holding the LP alone earns only swap
     fees, `hydrex.md` §9.1).
  4. **Harvest / vote module.** Claim **oHYDX** + fees from the gauge; manage the **veHYDX** position
     (`Voter.vote` each epoch; `exerciseVe` to defend the vote floor, `hydrex.md` §8).
  5. **Exercise / strike-financing module.** Pull LP → post as collateral in the **reservoir USDC vault** →
     **CRE-only borrow** USDC → **exercise oHYDX** (pay the ~30% strike) → receive HYDX.
  6. **Range-sell module.** Sell HYDX → USDC via **NFPM** range orders (retrace-guard + soft-bleed caps,
     `hydrex.md` §9.1/§9.3).
  7. **Recycle module (the single sink).** Route the free value: `ZipDepositModule.deposit` (USDC →
     `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the basket** (the module runs on the
     MAIN Safe) → 8-B6 single-sides it into the gauge-staked LP → **NAV-per-share accretes for every holder.** No
     payout, no xALPHA distribution (the compounder/Mode-C 8-B13 is **absorbed here** — single-sided LP needs no
     balanced add). **Free-value-only invariant:** only HYDX-extracted USDC is recycled — never depositor USDC,
     never unbacked mint (`auto-sodomizer.md` §8).
  8. **NAV + APR oracle module (read-only / dashboard).** Compute/publish **basket NAV from multiple oracle
     sources** + the **trailing-realized** APR (never projected).
  *(The former separate "Compounder / LP-rebalance module (Mode C / 8-B13)" is **removed — absorbed into item 7's
  recycle**: the recycle already mints backed zipUSD into the basket and 8-B6 single-sides it into the gauge-staked
  LP, so the balanced-add / swap-to-fund machinery is moot. There is one sink, not three modes.)*
  **Why this is the junior's pay + self-insurance:** the loop vamps net-new USDC out of the HYDX/USDC pool, so
  the basket compounds — that is what compensates the junior for duration risk ("frozen but earning") and is
  **waterfall leg (e)** (partial self-insurance, §11). **Bounded** (`hydrex.md`): TVL-capped, front-loaded,
  trailing-realized + degrading over ~6 months. **Full design: `pending-docs/auto-sodomizer.md`** (economics:
  `treasury.md`; the xALPHA CCIP leg: `bridge/xalpha-bridge-impl.md`). **Gating dependency:** the Hydrex gauge
  **whitelist** for our zipUSD/xALPHA pool (`hydrex.md` §9.4, via the OTC) — until it lands, **build + fork-test
  against live Base with stand-in pool/gauge addresses**, swap for production.
  **Build-grade per-module specs (8-B5…8-B10): see §4.5.1 below** — the contract behavior, external signatures
  (vendored EVK/EVC/Zodiac/Baal cited `file:line`; ICHI/Hydrex/Algebra `[EXT]`, fork-verified live + pinned to the
  Basescan ABI at build), CRE op sequence, state, invariants, and failure modes each engine ticket is authored from.
- **`ZipRedemptionQueue` — epoch redemption for zipUSD (§6.1).** The senior/utility-token redemption path
  (un-staked zipUSD → USDC). Fork of MIT `erc7540-reference` for the `requestRedeem → fulfill → claim`
  lifecycle, plus a clean-room Maple-style pro-rata settle. (The junior exits separately on its cooldown, §6.4.)
  **Ownership:** the queue's privileged ops (`settleEpoch` / `fulfillRedeem`) are gated on an **immutable
  controller** address set at deploy — *not* the forked `Owned` owner; the inherited `transferOwnership` is
  removed (or rendered inert) so no mutable owner role exists. (Note this contract is **not** renounced like
  the CRE receivers: the controller must keep calling `settleEpoch` every epoch, so the gate is an immutable
  controller, not a zeroed owner.)

#### 4.5.1 Yield-engine strategy modules (8-B5…8-B14) — build-grade

The auto-sodomizer loop (the engine inventory above) decomposes into the build tickets **8-B5…8-B14**. Each is
raised here to zero-guess detail; **the substrate is referenced, not re-spec'd here** (8-B1 Baal + main-Safe +
**sidecar** scaffold; the **Exit Gate** — holds `manager`, absorbs the mint/TVL + lock/freeze shamans + the
buy-and-burn; and **`SzipNavOracle`**; see `baal-spec.md §13`).

> **2026-06-07 additions (`baal-spec.md` §10):** (1) **8-B14 — szipUSD buy-and-burn** — engine USDC posts discounted
> `BUY szipUSD` CoW bids *below* NAV, then **burns** the fills (the impatient-exit liquidity floor + the
> haircut-to-stayers mechanism, §6.2/§6.4). (2) The **xALPHA emission program / POL-as-liquidity-mining** — the
> protocol deposits its monthly xALPHA emissions **in-kind** (NAV-proportional, §4.5) and the engine pairs them with
> resting zipUSD into the 70/30 ICHI LP; the lending spread + arbs accrue to **treasury, not the junior** (§17). (3)
> The **strike loop borrows the warehouse `USDC Resting Vault`** (un-utilized USDC, LP-collateralized), **not** a
> treasury vault (8-B5). Full design narrative: `pending-docs/auto-sodomizer.md` +
`hydrex.md` + `monitoring.md`; economics `treasury.md`. **§5/§17 yield routing is honored, not reopened** (lending
APR = the protocol's → xALPHA; depositor pay = the HYDX-vamp + the xALPHA subsidy; bounded, TVL-capped,
trailing-realized). None of these modules changes a §11/§12 money-model invariant (the strike is borrowed from the warehouse
**`USDC Resting Vault`** — un-utilized USDC — **over-collateralized by the ICHI LP and repaid each loop**, so
depositor principal is protected by the collateral, never the counterparty; §11/§12 untouched).

**The harvest cycle, end to end (how the sub-routines chain).** One CRE-driven pass per epoch (+ on triggers,
`auto-sodomizer.md` §4). Read top to bottom — each module is one step of the same loop:
1. **8-B6 LP** — the basket's zipUSD + xALPHA sit as a single-sided ICHI LP, **gauge-staked** (staking is what
   earns oHYDX; the bare LP earns only swap fees).
2. **8-B7 Harvest/vote** — claim the gauge's **oHYDX + fees**; take the **vote-floor `exerciseVe` slice first**
   (defend the gauge); re-vote; pass the remaining oHYDX (the "sell slice") on.
3. **8-B8 Exercise** — for the sell slice, profitability-cutoff pre-check (skip if HYDX < $0.015 — see §4.5.1 8-B8), then **redeem the option
   by paying the ~30% strike** in USDC → HYDX. The strike's USDC is sourced by →
4. **8-B5 Reservoir loop** — **the LP self-finances its own strike:** unstake a slice → post as collateral →
   **borrow** the ~30% strike → (8-B8 exercises) → (8-B9 sells) → **repay** → withdraw → **re-stake**. The borrow
   revolves; no idle buffer.
5. **8-B9 Sell** — **market-sell** the HYDX immediately (within the soft-bleed cap — the cap sizes the loop, it
   doesn't slow the sell); the proceeds **repay the 8-B5 borrow** (freeing the LP to re-stake), and the **residual
   is the free value**.
6. **8-B10 Recycle** — the free value is recycled: USDC → `CreditWarehouse` senior backing + backed zipUSD minted
   into the basket → 8-B6 single-sided LP → **NAV accretion for every holder**, gated so only HYDX-extracted free
   value is ever spent (no payout, no xALPHA distribution; 8-B13 absorbed here).
   *(8-B10's recycle IS the reinvest — USDC → warehouse credit-line capacity + backed zipUSD minted into the basket
   + 8-B6 single-side LP → emissions ↑. The former separate "8-B13 Compounder / Mode C" is removed/absorbed; there
   is one sink, not three modes.)*
8. **8-B11** is the **only writer** that drives steps 1–6; **8-B12** watches the whole loop (NAV, trailing APR,
   the TVL cap, the floor/whale tripwires) and feeds 8-B11's triggers.

**Shared architecture (applies to 8-B5…8-B11 — every engine module).**
- **Each strategy module is a Zodiac module** (`is Module`, `reference/zodiac-core/contracts/core/Module.sol`)
  `enableModule`'d on the szipUSD Baal **Gnosis Safe** (the basket treasury, 8-B1). It mutates the basket only by
  calling its inherited internal helpers `exec(to, value, data, operation)` (`core/Module.sol:43`) /
  `execAndReturnData(...)` (`:59`), which forward to **the Safe's** `execTransactionFromModule(address, uint256,
  bytes, Operation)` / `…ReturnData(...)` (`Module.sol:50`/`:66`). `Operation.Call = 0`
  (`reference/zodiac-core/contracts/core/Operation.sol`). **The Safe-side `execTransactionFromModule` is `[EXT]`**
  (Gnosis Safe is interface+fork via `IAvatar`, `reference/zodiac-core/contracts/interfaces/IAvatar.sol`; not
  vendored — WOOF-00). The module holds **no custody**; the Safe holds the basket.
- **The CRE strategy-admin robot (8-B11) is the only caller** of every module entrypoint: a single immutable
  **CRE operator address**, set-once-then-immutable exactly as the §4.4 receivers (assert non-zero, then seal),
  gates each entrypoint (`onlyCRE`). This is `auto-sodomizer.md` §8 invariant 1 (permissioned writer).
- **The Safe is itself an EVC account owner.** The reservoir borrow (8-B5/8-B8) runs on the **Safe's own** EVC
  account (not a fresh per-line `LineAccount`, §4.7) — the module drives the Safe to `enableController` /
  `enableCollateral` / borrow on-behalf. Distinct from the senior lien borrowers (§4.4).
- **`[EXT]` posture (WOOF-00 Strategy A).** Verifiable + vendored: **EVK / EVC / Zodiac-core / Baal**
  (signatures cited below with `file:line`). **EulerEarn is exact `0.8.26` → mocked**, never compiled (WOOF-00
  fold-back). **ICHI, Hydrex (oHYDX / Voter / veHYDX / gauge / Minter), Algebra (NFPM / SwapRouter / pool) are
  NOT vendored** — interface+fork against **live Base (8453)**; their method sets are **pinned to the
  Basescan/Sourcify-verified ABI at build** (do NOT trust Foundry auto-ABI), fork-tested with **stand-in
  pool/gauge addresses until the Hydrex gauge whitelist lands** (`hydrex.md` §9.4 — the gating dependency).
  **xALPHA = the 8x stand-in 18-dp mock ERC20**; the real bridged token swaps in (PROGRESS item 8x). Addresses
  (`hydrex.md` §2.5): oHYDX `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78`; Voter `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b`;
  veHYDX `0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1`; NFPM/SwapRouter
  `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86` / `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`; ICHI
  factory/guard `0x2b52c416F723F16e883E53f3f16435B51300280a` / `0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8` (on-chain verified 2026-06-06; the old `0x7d11De61…` was a mis-labeled Gnosis Safe, not the factory);
  HYDX/USDC pool `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`; USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
- **Fork-verified live (Base 8453, 2026-06-06; Sourcify ABI for oHYDX `OptionTokenV4`).** All addresses above carry
  code. Confirmed exact `[EXT]` signatures used below: **oHYDX** `exercise(uint256 _amount, uint256
  _maxPaymentAmount, address _recipient)` (and a 4-arg overload `(…, uint256 _deadline)` — **prefer the deadline
  overload** for the bot), `exerciseVe(uint256 _amount, address _recipient)`, `getDiscountedPrice(uint256 _amount)`
  (and `(uint256,uint256)` overload), **`getMinPaymentAmount()` — NO args** (corrected; the per-amount value is
  `getDiscountedPrice`/`getTimeWeightedAveragePrice(uint256 _amount)`), `discount() = 30`, `getDiscountedPrice(1e18)
  ≈ 12084`; **Voter** `getEpochDuration() = 604800`, `gauges(address) → gauge` (the HYDX/USDC pool resolves to a
  live gauge `0xAC396CabF5832A49483B78225D902C0999829993`), `isGauge(address)`; **gauge** `rewardToken() = oHYDX`,
  `isForPair()`, `DURATION() = 604800`, `earned(address)`, `balanceOf(address)`; **veHYDX** `balanceOfNFT(uint256)`;
  **pool** `globalState()`. NFPM/SwapRouter/ICHI-vault ABIs are not on Sourcify → **pin to the Basescan-verified
  ABI at build** (the Algebra-Integral `mint(MintParams)` struct carries a `deployer` field for custom pools —
  verify the exact struct); the gauge's staking-token accessor varies by gauge **type** (PAIR_CLASSIC vs the
  ALM_ICHI type our zipUSD/xALPHA pool uses) → pin at build against the actual whitelisted gauge.

**8-B5 — Reservoir USDC vault + ICHI-LP collateral + CRE-borrow** (the strike-financing **process** — the
self-collateralizing harvest loop; the LP is its own working capital).
- **The mechanism (not an optional leg — THE process).** oHYDX is an option: redeeming it requires paying the
  ~30% strike in USDC (8-B8), so the harvest needs a source of USDC. That source is the **LP itself**: you
  **unstake** the LP slice from the gauge, **post it as collateral**, **borrow** the ~30% strike, **exercise**
  the oHYDX, **sell** the resulting HYDX, **repay** the borrow, and **re-stake** the slice to resume emissions.
  This is `auto-sodomizer.md` §5's "self-collateralizing — borrow 30% to unlock 100%": the borrow funds the
  strike, the HYDX sale repays the borrow, the LP returns to the gauge. The unstake→re-stake is an inherent step
  of every harvest, **not** a fallback to a standing USDC buffer.
- **What it is.** An EVK isolated market: a treasury-supplied **USDC borrow vault** + an **escrow collateral
  vault** (asset = the ICHI LP token) + a dedicated `EulerRouter`, plus the thin CRE-gated Zodiac module
  (`postCollateral` / `borrow` / `repay` / `withdrawCollateral`). **Borrower-of-record = the szipUSD Safe.** The
  treasury USDC is out only for the short loop window (borrow → repay from the first HYDX fills), so the facility
  **revolves** — it is not a large standing idle buffer (the capital-efficiency win). **Borrow is pinned to the
  Safe (8-B5 hardening):** because the USDC borrow vault is the warehouse's *shared* resting vault (depositors'
  idle USDC), the vault installs an `OP_BORROW` guard hook (the `CREGatingHook` shape, §4.3) restricting the borrow
  to the engine Safe's own EVC account — so no third party holding the ICHI LP can lever the resting USDC by
  posting the escrow collateral on their own account. The module's `borrowCap` bounds **aggregate outstanding**
  reservoir debt (not a single call).
- **The harvest loop (the ordered process — driven by 8-B11; spans 8-B5/8-B6/8-B8/8-B9):**
  1. `gauge.withdraw(slice)` — unstake the LP slice (8-B6). Emissions on that slice pause until step 7.
  2. `EVC.enableCollateral(safe, escrowLpVault)` + `EVC.enableController(safe, usdcBorrowVault)`; deposit the
     slice into escrow `Vault.deposit(slice, safe)`.
  3. `EVC.call(usdcBorrowVault, safe, 0, abi.encodeCall(IBorrowing.borrow, (strikeUsdc, safe)))` — borrow the ~30% strike.
  4. exercise oHYDX paying the strike → HYDX (8-B8).
  5. **market-sell** HYDX → USDC (8-B9, immediately, within the cap); from the proceeds `Borrowing.repay(debt, safe)` until `debtOf(safe) == 0`.
  6. `Vault.withdraw(slice, safe, safe)` — release the LP from escrow (escrow unlocks once debt is 0).
  7. `gauge.deposit(slice)` — re-stake to resume emissions (8-B6).
  Only ~30% of the exercised HYDX must be sold to repay + release; the **residual ~70% (the free value) is held by
  the Safe** and market-sold within the cap (8-B9) — it does **not** block the re-stake. So the unstake window is
  short by construction — size each loop's slice so step 5's repay completes within an epoch.
- **One-time wiring — `GenericFactory`, governor RETAINED (NOT `EdgeFactory`).** `EdgeFactory.deploy`
  (`reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol:56`; `DeployParams`,
  `EdgeFactory/interfaces/IEdgeFactory.sol:54`) **renounces all governance** at the end
  (`setGovernorAdmin(address(0))` `:88/:117`, `router.transferGovernance(address(0))` `:123`) and bakes LTV in via
  `DeployParams` (`:111`) — so **post-deploy `setLTV`/`setCaps` is impossible** on that path, and the oracle
  adapter (configured via `router.govSetConfig` `:66` during deploy) **can never be re-pointed.** The reservoir is
  a **standing, tunable** facility, so build it via `GenericFactory.createProxy(impl, false,
  abi.encodePacked(asset, oracle, unitOfAccount))` (`reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol:116`)
  with a dedicated `EulerRouter`, set the gap with `Governance.setLTV`
  (`reference/euler-vault-kit/src/EVault/modules/Governance.sol:281`) so a 30%-strike borrow sits well inside
  `liquidationLTV` (self-collateralizing, `auto-sodomizer.md` §5) and cap with `setCaps (:369)`; **governor = the
  §17 OZ `TimelockController` (retained, not renounced)** — distinct from the **frozen** per-line lien routers
  (§4.7), because LTV/caps/oracle must stay tunable under the 2-day veto as the LP economics shift.
- **Collateral oracle — a DEPLOY PREREQUISITE, not a deferrable flag.** The router needs the LP-mark adapter
  **at wiring time** (`govSetConfig`). Because the whole borrow is **CRE-permissioned** (which kills external
  oracle-manipulation, `auto-sodomizer.md` §5), the mark is a **CRE-fed conservative mark** — the same push-cache
  adapter shape as the lien registry (`BaseAdapter`/`IPriceOracle`, §4.1/§7), keyed on the LP token, written by the
  robot from the 8-B4 basket NAV; the retained timelock can re-point it (via `router.govSetConfig`, not an
  oracle-local owner). **RESOLVED 2026-06-08 (was a build flag): CRE-fed push-cache** (not a fixed-haircut
  constant) — the CRE robot computes the per-LP-share mark off-chain (`(reserve_xALPHA × priceXAlpha +
  reserve_zipUSD × priceZipUSD) / ICHI_LP_totalSupply`, the same reserve×price mark `SzipNavOracle` runs for the
  basket LP leg) and pushes it via a **dedicated CRE `reportType` (`LP_MARK`, defined in §8)** distinct from the
  lien registry's `REVALUATION=3`; the on-chain `SzipReservoirLpOracle` is the thin stale-checked cache. A
  stale/missing mark **fails the borrow closed** (the router read reverts → the EVC account-status check reverts),
  never opening an unsafe position. (8-B5 ticket `tickets/sodo/8-B5-reservoir-loop.md`.)
- **Verified call signatures (loop steps 2–6):** `EVC.enableCollateral(safe, escrowLpVault)`
  (`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol:416`) / `enableController(safe, usdcBorrowVault)`
  (`:462`) / `call (:553)`; `Vault.deposit(amount, safe) (:124)` / `withdraw(amount, safe, safe) (:153)`
  (`reference/euler-vault-kit/src/EVault/modules/Vault.sol`); `Borrowing.borrow(uint256, address) (:65)` /
  `repay(amount, safe) (:81)` / `debtOf(safe) (:40)` (`reference/euler-vault-kit/src/EVault/modules/Borrowing.sol`).
- **Lender side (INVARIANT — corrected 2026-06-07).** The USDC borrow vault **is the warehouse's `USDC Resting
  Vault`** — the un-utilized USDC `EulerEarn` has not allocated to credit lines (§4.5) — borrowed
  **over-collateralized by the ICHI LP, CRE-only, short-term, repaid from the HYDX sale each loop**, so depositor
  principal is **protected by the collateral, never the counterparty.** *(Supersedes "protocol/treasury USDC, never
  depositor"; there is no separate treasury borrow vault.)* Because the borrow revolves, the idle USDC is out only
  for the loop window.
- **State:** the reservoir market addresses, the borrow cap, the in-flight unstaked LP slice, outstanding borrow (`debtOf`).
- **Invariants:** treasury/protocol-funded lender only; borrow ≤ the self-collateralizing bound (default requires
  >71% single-order slippage, never placed — §4 caps); CRE-only; the unstaked slice is re-staked within the epoch.
- **Failure modes:** reservoir under-funded → harvest paused that epoch (no strike financing); if a loop's repay
  market-sell wouldn't fit the soft-bleed cap (thin pool) → **size the loop smaller** (exercise less, 8-B8), don't
  leave the borrow open; worst case is a *stall* (CRE holds over-collateralized HYDX awaiting liquidity), **not**
  depositor bad debt (`auto-sodomizer.md` §5).

**8-B6 — LP strategy module** (owns the LP's whole lifecycle: build it, stake it, and unstake/re-stake for the loop).
- **External calls `[EXT]`:** ICHI vault `deposit(uint256 deposit0, uint256 deposit1, address to) → shares`
  (single-sided ⇒ one deposit arg `0`; the vault is deployed via the ICHI **factory** `0x2b52c416…`
  (`createICHIVault`)). **Direct `vault.deposit` is the add path — BUILD-VERIFIED on live Base (8-B6): a real
  single-sided ICHI vault on this factory accepts a direct deposit, so the deposit guard `0x9A0EBEc4…` is NOT
  needed** (the module's slippage protection is an operator-supplied `minShares` post-check, not the guard's
  `minimumProceeds`). Resolve the gauge `Voter.gauges(ourPool) → address` (`0xc69E…`) — **which MUST be a Hydrex
  `ALM_ICHI_UNIV3`-type gauge** (its staking token is the ICHI vault share; the hard external whitelist dependency,
  `Voter.createGauge(ourPool, ALM_ICHI_UNIV3)`, `hydrex.md §9.4`). **gauge-stake** `gauge.deposit(uint256 amount)` /
  **unstake** `gauge.withdraw(uint256 amount)` (Solidly-style — **staking is REQUIRED to earn oHYDX**; the bare LP
  earns only swap fees, `hydrex.md` §9.1). Approvals via the Safe.
- **CRE op seq (two directions):** *build/stake* — pull **zipUSD** from the basket → `ICHI.deposit` (single-sided
  zipUSD) → receive LP → `gauge.deposit` (cycle step 1). *Loop service* —
  `gauge.withdraw(slice)` so 8-B5 can collateralize it (step 1 of the harvest loop), then `gauge.deposit(slice)` to
  re-stake once 8-B9 has repaid (step 7).
- **State:** ICHI vault address, gauge address, staked-LP balance (read from the gauge).
- **Vault = single-sided zipUSD YieldIQ (DECIDED 2026-06-08).** The wired ICHI vault is a **single-sided zipUSD**
  YieldIQ vault: only **zipUSD** is deposited; ICHI's ALM holds the two-token position (toward ~70/30 zipUSD/xALPHA)
  and rebalances against IL, acquiring the xALPHA leg from the underlying Algebra pool's flow (the vault's zipUSD is
  resting buy-side that fills as xALPHA is sold in). The **vault share is the tokenized receipt listed as
  collateral** — the whole point: it backs the USDC borrow that finances the oHYDX strike (8-B5). The xALPHA leg is
  fed by the **emissions flywheel** — monthly xALPHA incentives market-buy zipUSD from the pool → xALPHA lands in the
  pool → absorbed by the single-sided vault → the bought zipUSD is re-deposited (parking lent USDC as protocol-owned
  collateralizable LP, paying yield in exchange). **The contract stays vault-agnostic** — single-sided is the
  *wired vault's* property (its `allowToken0()`/`allowToken1()` gate legality fail-closed), **NOT a module-level
  gate**, so the vault definition can still be finalized with ICHI without re-authoring the module. LP must be
  gauge-staked to earn oHYDX; the deposited zipUSD is **backed** — minted only via 8-B10's free-value path, never
  unbacked. *(Exact vault config pending an ICHI conversation — single-sided zipUSD is the decided shape; full-range
  and single-sided-xALPHA were the rejected alternatives.)*
- **Staked/collateral exclusivity (the reason for the loop):** a staked LP is custodied by the gauge, so it
  cannot *simultaneously* be EVK collateral — collateralizing requires unstaking, and the unstaked slice stops
  earning oHYDX until re-staked. This is exactly why 8-B5 is a tight unstake→borrow→repay→re-stake loop, not a hold.
- **Failure modes:** gauge not whitelisted as `ALM_ICHI_UNIV3` (stand-in until the OTC, `hydrex.md` §9.4); a deposit
  that breaches `minShares` (thin/sandwiched) reverts; a wrong-side (vault-disallowed) deposit reverts **in the vault**
  (the single-sided `allowToken*` gate — fail-closed, not a module check).

**8-B7 — Harvest/vote module** (claim oHYDX; defend the vote floor via `exerciseVe`; re-vote each epoch).
- **External calls `[EXT]` (Hydrex VoterV5 / veHYDX / oHYDX / RewardsDistributor, on-chain-verified Base 2026-06-08
  — the host core is NOT open-sourced, so every selector is reverse-verified from deployed bytecode):**
  `gauge.getReward()` (claim the gauge's **oHYDX emissions** to the Safe — the LP swap fees auto-compound inside the
  ICHI ALM vault, so they are captured in the LP/NAV mark, NOT separately claimed here; the veHYDX voting
  bribes/fees are a deferred extension); **`Voter.vote(address[] poolVote, uint256[] weights)`** and
  **`Voter.reset()`** (`0xc69E…`, VoterV5 — the Voter is **account-keyed, NOT tokenId-keyed**: `vote`/`reset` carry
  **no `tokenId`** and act on the caller account's whole veHYDX position; selectors `0x6f816a20`/`0xd826f88f` FOUND,
  the guessed `vote(uint256,address[],uint256[])`/`reset(uint256)` are ABSENT; **votes reset weekly → re-vote each
  epoch**); `oHYDX.exerciseVe(uint256 amount, address recipient)` (**free permalock** → mints a **fresh**
  account-owned veNFT each call, `hydrex.md` §4/§8); read **`ve.getVotes(address account)`** (`0x25B2…`, the
  **account-aggregate** voting power across all the Safe's veNFTs — NOT `balanceOfNFT(tokenId)`, which reads only one
  NFT) for the floor metric; `Voter.getEpochDuration() (= 604800)`. **Rebase (anti-dilution, 7%→0% by ~wk64):**
  claimed on the **RewardsDistributor** (`Minter._rewards_distributor()` = `0x6FCa2…`) via
  **`claim_many(uint256[] tokenIds)`** — per-veNFT, the CRE operator enumerates the Safe's veNFTs off-chain
  (`ve.tokenOfOwnerByIndex`); claiming only credits each veNFT's own lock (cannot redirect), so an imperfect array is
  harmless.
- **CRE op seq (per epoch):** claim (`gauge.getReward()`) → take the **vote-floor `exerciseVe` slice FIRST**
  (`auto-sodomizer.md` §8 inv. 8 — defend `s*` before any sell slice) → re-`vote` our gauge → pass the remaining
  oHYDX to 8-B8 per the regime split. (The rebase claim is an independent, idempotent op.)
- **State:** **none beyond the set-once wiring** — each `exerciseVe` mints a fresh account-owned veNFT and voting /
  floor / rebase are all account-keyed or operator-curated, so the module tracks **no `tokenId`** (the earlier "the
  veHYDX tokenId" framing is corrected away). The target floor `s*` (Treasury-set, `hydrex.md` §4) and the
  lock-vs-sell split live in the **8-B11 CRE** policy, off-chain.
- **Invariants:** vote-floor-first; re-vote every epoch; `exerciseVe` is the FLAT/DOWN hedge (never dump into
  weakness, §9.2); the module is the Safe's **sole** voter (account-keyed — one vote per account per epoch).
- **Failure modes:** missed epoch vote → gauge starves; floor drift under team dilution (the 8-B12 red tripwire).

**8-B8 — Exercise/strike-financing module** (LP → reservoir collateral → CRE-borrow USDC → exercise oHYDX → HYDX).
- **External calls `[EXT]` (oHYDX, fork-verified) + reference (borrow leg via 8-B5):** pre-checks
  `oHYDX.getDiscountedPrice(uint256 _amount)` + `getTimeWeightedAveragePrice(uint256 _amount)` (strike =
  `max(30%·2h-TWAP, $0.01)`, `hydrex.md` §2.4; **`getMinPaymentAmount()` takes NO args** — corrected); finance the
  strike via the **8-B5 self-collateralizing borrow** (loop steps 1–3 — unstake the LP slice → collateralize →
  borrow the ~30% strike); `oHYDX.exercise(uint256 _amount, uint256 _maxPaymentAmount, address _recipient, uint256
  _deadline)` (the **deadline overload** — slippage+deadline protection; the 3-arg form also exists) paying
  `max(30%·TWAP, $0.01)` → receive HYDX to the Safe (then 8-B9 sells, repays the borrow, and re-stakes — steps 5–7).
- **Three price tiers (do not conflate) — ALL are governed CRE/monitoring policy (8-B11), NOT contract constants
  (the 8-B8 module holds no threshold; the cutoff tracks live pool depth + slippage):** the **loop profitability
  cutoff = $0.015** (the operative skip — our borrow→exercise→sell→repay loop nets a profit only above it: at $0.015
  the gross spread is ~33%, enough to cover the ~2–3% sell-side slippage on the thin draining pool; below it the
  round-trip stops netting → **skip `exercise`**, the oHYDX accrues to the Safe until a profitable epoch,
  `auto-sodomizer.md` §4 step 4 / `monitoring.md` §D) > a **$0.018 amber / begin-taper tier** (start shrinking the
  loop size as price approaches the cutoff — a graceful taper, not a cliff, `hydrex.md` §9.3) > the **hard underwater
  floor $0.01** (mechanical: `strike = max(30%·TWAP, $0.01)` ⇒ spread = 0% at $0.01 and the option is literally dead
  below it; = `getMinPaymentAmount()`, `hydrex.md` §2.4 — never reached, we stop at $0.015). *(Canonical loop cutoff
  set to $0.015 — user-ratified 2026-06-08; the $0.018 round number was a conservative proxy, now the taper-start.)*
- **CRE op seq:** classify regime (UP/FLAT/DOWN, `hydrex.md` §9.2) → for the sell slice: **profitability-cutoff
  pre-check (skip if HYDX < $0.015)** → finance the strike via the 8-B5 borrow (steps 1–3) → `exercise` → hand HYDX
  to 8-B9.
- **State:** none in the module (stateless beyond set-once wiring, like the sibling engine modules); the
  in-flight strike-borrow is tracked by **8-B5** (`debtOf`) and the pending-exercise sequencing by the **8-B11** robot.
- **Invariants:** strike funded only by the 8-B5 borrow against treasury USDC (never depositor USDC, inv. 2);
  profitability-cutoff pre-check (skip if HYDX < $0.015); the vote-floor slice was already taken (8-B7). **Commitment gate (load-bearing):
  borrowing + exercising COMMITS you to market-selling to repay — so enter the loop ONLY in UP/FLAT regime and
  ONLY at a size whose repay market-sell fits the 8-B9 per-epoch cap.** In DOWN regime, do not borrow at all →
  route the oHYDX to `exerciseVe` (8-B7). This is what prevents ever being forced to dump into weakness.
- **Failure modes:** spot at/below the $0.015 loop cutoff, or DOWN regime → no loop, route to `exerciseVe`; reservoir under-funded → harvest paused.

**8-B9 — Sell module** (market-sell HYDX → USDC **immediately** to repay the borrow; the residual is free value).
- **Market-sell, NOT patient range orders — and why.** Two forces require immediate market execution: (1) the
  loop holds an **open strike-borrow** (8-B5) accruing interest while the LP slice sits unstaked (no emissions), so
  the **fastest payoff wins** — sell now, repay, release, re-stake; (2) the HYDX/USDC pool is **net-draining with
  no buy-side** (`hydrex.md` §2.3), so resting sell orders *above* spot (the old range-ladder) rarely fill — you
  must take the bid that exists. So this module **market-sells** the exercised HYDX into the pool. *(supersedes the
  earlier NFPM range-ladder — `hydrex.md` §9.1 / `auto-sodomizer.md` §4 step 5; an UP-regime range-rest of the
  **residual only** is an optional fee optimization, never the repay leg.)*
- **External calls `[EXT]`, Algebra `SwapRouter` `0x6f4b…`:** `exactInputSingle(...)` HYDX→USDC (market sell into
  the HYDX/USDC pool `0x51f0…`); read spot/TWAP from `pool.globalState()` to size the order against the cap.
- **CRE op seq:** market-sell the exercised HYDX (sized within the per-epoch cap) → from the proceeds
  `Borrowing.repay` the 8-B5 strike-borrow until `debtOf(safe) == 0` (loop steps 5b–6) → 8-B6 re-stakes the LP
  (step 7) → the **residual USDC** (proceeds above the strike + interest) → **8-B10**.
- **Caps are a SIZE GATE on the loop, not a "sell slowly" rule (`hydrex.md` §9.3):** per-epoch volume ≤1–2% of
  pool USDC (~$4–9k → ~1–2% realized slippage at that size); per-order slippage ≤2–3%. **8-B8 bounds the exercise
  size so the repay market-sell fits this budget** — so you never have to choose between leaving the borrow open
  and cratering the pool; you only ever borrowed an amount you can market-sell within the cap.
- **State:** none in the module (stateless beyond set-once wiring, like the sibling engine modules); the per-epoch
  volume *throughput* tracking remains an **8-B11/8-B12 CRE/monitoring concern** (an on-chain epoch accumulator —
  running sum + boundary/reset — was considered and rejected for sibling-consistency + because that stateful
  time-policy is what §17 puts at CRE). **On-chain safety bounds = two, both set-once config (not accumulators):**
  (1) the operator-supplied `minOut` slippage floor (bounds PRICE — the router reverts if `amountOut < minOut`); and
  (2) a governed per-call **`maxSellHydx` size ceiling** (bounds SIZE — `sellHydx` reverts `ExceedsMaxSell` if
  `amountIn > maxSellHydx`; default 300k HYDX ≈ ~3% slippage ≈ ~$10k = the intended weekly clip, owner/Timelock-settable
  to track pool depth). The size ceiling is the defense-in-depth backstop against a compromised operator dumping the
  whole HYDX basket in one tx (`minOut` alone bounds only price, never size); the per-epoch *throughput* limit across
  many calls is still CRE/8-B12. The buy leg (`buyXAlpha`) is not size-capped here — bounded upstream by 8-B10's
  `freeValueAccrued` gate.
- **Invariants:** market-sell within the per-epoch soft-bleed cap (don't crater HYDX — we're long it via
  veHYDX + the LP, `hydrex.md` §12 reflexivity); repay-first from the proceeds; the **regime gate is at 8-B8**
  (only enter the loop in UP/FLAT — never borrow into weakness you'd have to dump to repay).
- **Failure modes:** thin bid → an order would exceed the per-order slippage cap → split across the epoch + size
  the next loop smaller; **never** market-dump past the per-epoch cap (that craters HYDX and our own veHYDX/LP).

**8-B10 — Recycle module** (USDC → backed zipUSD → into the vault basket → NAV accretion; the free-value-only invariant).
- **The single sink — recycle into the vault.** After 8-B9 sweeps a HYDX-sale fill and 8-B5 repays the strike
  borrow, the net free-value USDC sits in the MAIN (engine) Safe. `recycle(usdcAmount)`: debit `freeValueAccrued`,
  then `ZipDepositModule.deposit(usdc)` (the §4.5 zap path) — the USDC lands as **`CreditWarehouse` senior backing**
  (credit-line capacity ↑) and `usdc·scaleUp` **backed zipUSD** is minted **1:1 directly into the basket** (the
  module runs on the MAIN Safe, so the mint lands in place — **no `gate.depositFor`, no share issuance**). 8-B6 then
  single-sides that zipUSD into the ICHI LP + gauge-stakes it (CRE-sequenced next). The basket grows, share count is
  flat → **NAV-per-share rises for every holder** — the depositor's return is this **weekly NAV accretion, not a
  distribution.**
- **No payout, no xALPHA, no distributor.** The harvested value is reinvested as basket NAV (realized by holders on
  exit at NAV, §6.4/§7) — there is no USDC-to-holder payout and no xALPHA boost. (Supersedes the prior Mode A/B/C
  framing + `treasury.md §4.7`; the reinvest sink formerly split out as **8-B13 is absorbed here** — single-sided LP
  removes the balanced-add/swap machinery 8-B13 carried.)
- **Free-value-only invariant (load-bearing, `auto-sodomizer.md` §8 inv. 3) — ENFORCE ON-CHAIN.** The
  **8-B10 module owns** the single `uint256 freeValueAccrued` storage (no other module writes it); the **CRE
  operator is the only writer** (`onlyCRE`, the same gate as every entrypoint). Two mutators: `creditFreeValue(uint256
  realizedUsdc)` — called after 8-B9 sweeps a fill, **increments** by the USDC realized **net of** the 8-B5 strike
  borrow repaid (principal + interest) for that loop, i.e. `freeValueAccrued += max(0, realized − borrowRepaid)`
  (only the HYDX sold above the ~30% strike is free value); and `recycle`, which **decrements** by exactly the USDC
  it deposits into the vault and **reverts if the spend would exceed `freeValueAccrued`**. So the recycle can only
  ever reinvest HYDX-extracted free value — never depositor USDC, never unbacked mint (backing is automatic —
  deposit precedes mint).
- **State:** **only** the single `freeValueAccrued` accumulator (8-B10-owned, CRE-written) + the set-once wiring
  (engineSafe / operator / zipDepositModule / usdc). No xALPHA, no distributor, no compounder. The module is
  stateless beyond the accumulator + wiring, like every sibling engine module.
- **Invariants:** free-value-only (the gate above); the reinvest is NAV-accretive (USDC→backed zipUSD→basket, share
  count flat), realized by holders on exit at NAV — the module **never** writes `SzipNavOracle` (NAV reads the
  basket, not the accumulator); zipUSD minted only after a real USDC deposit.
- **Failure modes:** free-value gate breach → revert; origination not keeping pace with the loop's USDC inflow →
  idle drag (the 8-B12 origination-throughput watch — a throughput concern, not a backing risk).

**8-B13 — REMOVED (absorbed into 8-B10).** The compounder / LP-rebalance "Mode C" was a separate balanced-LP-add
module (size xALPHA, swap zipUSD→xALPHA to fund the short leg, balanced ICHI add). It is **fully subsumed by the
8-B10 recycle + 8-B6 single-sided LP**: the recycle mints backed zipUSD into the basket and 8-B6 single-sides it
into the gauge-staked LP — so the balanced-add/swap-to-fund machinery is moot (single-sided LP needs no xALPHA
leg). There is one sink (recycle → NAV), not three modes; the engine's on-chain contracts end at 8-B10.

**8-B11 — CRE strategy-admin robot: the on-chain module surface only** (the off-chain Go workflow is authored by
`spec-clear-CRE.md` §8 — **coordinate, do not duplicate**).
- The robot is the off-chain Go orchestrator (CRE, `cre-sdk-go` → wasip1). **Its §8 workflow lives in
  `spec-clear-CRE.md`** (the 8-B11 robot-ops row it enumerates). **This window pins only the on-chain seam it drives:**
  - A single immutable **CRE operator address** is the sole authorized caller of every 8-B5…8-B10 entrypoint
    (`onlyCRE`, set-once-then-immutable, mirroring §4.4). It is the Zodiac-module `msg.sender`; the module then
    forwards to the Safe via its inherited `exec(...)` (`core/Module.sol:43`). This realizes `auto-sodomizer.md` §8 inv. 1.
  - **The driven-entrypoint registry** (the surface the §8 workflow calls): 8-B5 `postCollateral`/`borrow`/`repay`/`withdrawCollateral`;
    8-B6 `postLp`/`stake`/`unstake`/`restake`; 8-B7 `harvestAndVote`; 8-B8 `exercise`; 8-B9 `marketSell`; 8-B10
    `recycle`. Each is revert-bounded by its
    module's invariants (caps / free-value / regime + soft-halt pre-check) so a malformed CRE call cannot violate them.
  - **Scheduling is off-chain** (a `cron.Trigger` per epoch + event triggers, §8/§8.2) — there is **no on-chain
    scheduler**; the on-chain modules are stateless executors gated to the operator.
- **Failure mode / defense:** operator-key compromise is bounded by each module's on-chain invariants; an optional
  **Zodiac Delay Modifier** cooldown (the §4.5 warehouse defense-in-depth) is available behind the operator.

**8-B12 — Dashboard / monitoring** (NAV, trailing-realized APR, TVL cap; **read-only / off-chain**, `monitoring.md`).
- **Type:** read-only / off-chain — **no writes** (`monitoring.md` §4). The only on-chain Solidity is the **8-B4
  NAV+APR oracle** (substrate — publishes basket NAV + trailing-realized APR on-chain) and the **8-B2 `maxDeposit`
  TVL-cap gate** (substrate); 8-B12 is the read / index / alert layer that consumes and feeds them.
- **Reads (`monitoring.md` §2 registry):** Entitlement/Race (`Voter.totalWeightAt`/`weightsAt`/`votes`,
  `HYDX.balanceOf(ve)`, `Minter.weekly()`); the **Whale tripwire** (`ve.balanceOfNFT(1)`, team-Safe
  `oHYDX/HYDX.balanceOf`, sink-gauge weight); Extraction (pool depth, `pool.ticks()` tick-enumerated fill curve,
  measured net Swap flow, 2h-TWAP); Floor (`oHYDX.getDiscountedPrice(_amount)` / `getMinPaymentAmount()` (no-arg) /
  `getTimeWeightedAveragePrice(_amount)` vs spot — effective spread, distance-to-$0.01, the **profitability-halt**);
  Backing (origination throughput, redemption-depth ratio — **NB:** `monitoring.md` §C's "szipUSD backing ratio"
  is superseded by the Baal redesign; the live senior solvency check is §12's `NAV_s/Z ≥ 1`, see the note below);
  Product (vault TVL vs bleed cap, trailing-realized APR).
- **Implementation (`monitoring.md` §4):** a Multicall3 batch per epoch + a continuous floor/price poll + archive
  `eth_call` checkpoints + a team-Safe event indexer.
- **Outputs:** (1) the CRE trigger panel that drives the 8-B11 robot (each amber/red → a `hydrex.md` §9 action);
  (2) the depositor-facing **trailing-realized** APR (never projected, `auto-sodomizer.md` §7); (3) the Treasury digest/pages.
- **Escalation tiers (`monitoring.md` §3):** Green (bot auto-acts) / Amber (notify) / Red (page Treasury — team
  lock-power jump, oHYDX-hoard drawdown, profitability-halt → bot defaults to all-to-ve / pause-sells / halt-minting).
- **TVL cap (the binding governor, `auto-sodomizer.md` §7 / `hydrex.md` §5):** `maxDeposit` gates so
  `expected_weekly_oHYDX_sold ≤ measured pool absorption`, re-derived each epoch from the measured net Swap flow.
  **Enforced on-chain at 8-B2;** 8-B12 computes the cap value from the fill curve and feeds it.
- **Superseded-metric note:** `monitoring.md` §C's "szipUSD backing ratio" is superseded by the Baal redesign
  (szipUSD is a freezable Loot share over the basket, not a USDC-share claim); the live solvency check is §12's
  senior `NAV_s/Z ≥ 1` + the basket display-NAV. The redemption-depth + origination-throughput watches stand.

### 4.6 Loss-side contracts (Milestone-2 detail)

> **Loss-side detail is Milestone-2 scope — with one carve-out.** `DefaultCoordinator`'s default/recovery state
> machine is M2 (no default occurs in M1). **`LienXAlphaEscrow` is pulled forward as buildable now (M1-adjacent):**
> its **custody half** — `lockXAlpha` (bond posted by the protocol at launch, §2) + `releaseXAlpha` on repayment —
> is exercised in M1 (originator bonds are posted at launch), and the **slash half** (`slashXAlphaToCapital` /
> `slashXAlphaToCohort`) is built + tested against mocks now, going live with the M2 default flow. The
> `DefaultCoordinator` sketch below is the markdown-writer-only shape after the freeze moved to the Exit Gate (§6.4).

- **`LienXAlphaEscrow` — per-lien xALPHA bond custody (the loss-escrow/share-move half is GONE — the markdown is a
  recoverable NAV provision, §7/§11).** `lockXAlpha(lienId, amount)` at origination — **posted by the protocol on the
  originator's behalf at launch** (§2; originators fund their own via OTC xALPHA as they scale).
  `releaseXAlpha(lienId)` on repayment. On a default the bond is **held through the freeze** and applied at
  resolution in **two jobs, in order**: (1) if foreclosure + insurance leave a **capital hole**,
  `slashXAlphaToCapital` **sells xALPHA → external USDC** to cover it (last resort for a *realized loss* —
  **not** peg defense) up to the shortfall; the USDC repays the loan / fills the hole; (2) the **remainder is
  the premium**, `slashXAlphaToCohort` — **in-kind**, **priced** (CRE xALPHA feed, §7), never market-sold —
  distributed pro-rata to the frozen cohort. Custody models `InsuranceFund.bring:33`. **Caveat:**
  `MarkdownController.slashJaneProportional:146` is a *proportional-slash concept template*, not a drop-in; the
  in-kind pro-rata cohort distributor (snapshot → per-holder xALPHA share) is net-new
  (`RewardsDistributor:131,:141`-style). To detail for M2: cohort storage + the capital-vs-premium split.
  **(There is NO `escrowLoss`/`releaseLoss`/`finalizeLoss` venue-pool-share machinery — the loss is a recoverable
  **provision on `SzipNavOracle`** (§7), not an escrow/share-move; this contract holds only the xALPHA bond.)**
- **`DefaultCoordinator` — the NAV markdown writer + the xALPHA recovery waterfall (the freeze is NOT its job).** The
  single loss-side orchestrator, gated to the CRE receiver (immutable Forwarder). Receives the CRE default/recovery
  report (§8). **It does NOT engage the freeze** — the freeze is **structural and owned by the Exit Gate**: the junior
  equity committed to live credit lines already sits in the non-ragequittable sidecar Safe, sized to credit-warehouse
  **utilization** (§6.4), so a default changes **nothing** about the freeze (utilization stays high → the committed
  slice stays in the sidecar by default, until the line repays). The coordinator's two real jobs are: On a **default**
  report — (1) **size the at-risk amount** from the deviation-event Proof re-mark (§4.1/§4.4d) and **write a
  conservative provision into `SzipNavOracle`** (§7; small, because the underlying is insured/collateralized →
  duration-risk, `recoveryFloor` HIGH; **no `_realizeMarkdown`/escrow/share-move/ragequit gate** — the markdown is a
  **recoverable NAV provision**, the at-risk amount sizes the *markdown*, **not** the freeze); (2) **lock the xALPHA
  bond** for resolution (held, routed into the sidecar via `LienXAlphaEscrow`). On a **recovery** report (carrying
  **foreclosure + insurance + xALPHA + HYDX-vamped** USDC, Proof-attested): the external USDC repays the loan
  (`repay` → debt 0 → the controller closes the lien), the **provision writes back up** as recovery lands (§7), the
  xALPHA bond resolves (premium to the cohort via `slashXAlphaToCohort`, or sell-to-cover-the-hole-first
  `slashXAlphaToCapital` then premium), and the committed slice **rotates back to the main Safe** as the line closes —
  the structural freeze **releasing on its own** (the Exit Gate's utilization accounting, §6.4; the coordinator does
  not lift it). Recovery above the debt → **originator → homeowner** (locked decision 6, §17). On a confirmed
  **permanent shortfall** (waterfall exhausted), the **provision settles permanently** — `SzipNavOracle` carries the
  realized loss, so junior `navPerShare` drops **pari passu** (every holder bears it equally) and the senior stays
  $1-backed against the reduced junior NAV; the junior's own basket assets + the slashed xALPHA bond fill the senior's
  USDC hole. **No share-burn / "cut zipUSD supply" lever — the loss is the marked NAV.** To detail for M2: per-lien
  default state, the provision sizing/staircase true-up, and the capital-vs-premium xALPHA split. **(The freeze cohort
  storage / `lockedFraction` / objective release are NOT here — they are the Exit Gate's structural sidecar
  accounting, §6.4.)**

### 4.7 `IZipcodeVenue` + `EulerVenueAdapter` — the venue boundary
The administrative core (CRE receiver, `ZipcodeOracleRegistry`, the controller's decision logic) is
**venue-agnostic**; the lending venue is a swappable backend behind the **`IZipcodeVenue`** interface. Euler
is **configuration one** (`EulerVenueAdapter`); Aave / Morpho would be new adapters behind the same interface,
not a controller rewrite. **Administrative primacy lives in CRE / oracle / registry**, which decide and
command; the venue merely executes.

**Portable core vs venue adapter:**

| Portable core (the engine) | Venue adapter (Euler today, swappable) |
|---|---|
| CRE receiver: `onReport`, immutable Forwarder, workflow identity (§4.4) | EulerEarn allocator + `reallocate` (fund a line) |
| Report ABI + `reportType` decision logic (§4.4) | EVK market: `createProxy`, `setLTV`, `setHookConfig`, `setIRM`, `setGovernorAdmin` |
| `ZipcodeOracleRegistry` equity-mark cache (§4.1) | per-line fresh borrower account (`LineAccount`) + EVC `call`/`batch`; the borrower-of-record mechanism |
| Lien collateral representation (§4.2) | `CREGatingHook` (§4.3); EulerRouter governor + fallback-oracle wiring |

**The interface `IZipcodeVenue`** (the controller's report logic calls these; the Euler adapter realizes them):

| Method | Purpose | Euler adapter maps to |
|---|---|---|
| `openLine(lienId, lienToken, collateralAmount) → (lineRef, oracleKey)` | stand up an isolated credit line | mint, in one atomic call: a **fresh per-line borrower account** (CREATE2 `LineAccount`, which grants the borrow-driver — the adapter, the `EVC.call` `msg.sender`; §4.4 — the EVC operator bit over its code-free borrow account) + an **escrow collateral vault** (`createProxy`, asset=lien) + a **USDC borrow vault** (`createProxy`, oracle=a fresh per-line `EulerRouter`) + that **per-line router** wired `escrowVault→lien→registry` then frozen (`transferGovernance(0)`); deposit the lien into escrow for the line's borrow account; onboard the borrow vault to EulerEarn. `oracleKey = lienToken` (what the controller seeds). EVK pattern: `EdgeFactory` |
| `setLineLimits(lineRef, borrowLTV, liqLTV, cap)` | set the LTV gap + credit cap | `EVAULT.setLTV` + `setCaps` |
| `fund(lineRef, amount)` | move pool capital to the line | `EulerEarn.reallocate` |
| `draw(lineRef, amount, receiver)` | borrower-of-record draw | `EVC.call(borrowVault, lineBorrowAccount, 0, borrow)` (controller-as-operator, §4.4) |
| `observeDebt(lineRef) → uint256` | read outstanding (confirm repay/close) | `EVAULT.debtOf` |
| `closeLine(lineRef)` | release on zero debt | controller burns the lien token (§4.4c) |
| `liquidate(lineRef)` | **defensive surface, M1-stub** — no on-chain economic liquidation (§4.4e) | `EVAULT.liquidate` behind the hook; not called in M1 |

The borrower-of-record mechanism (fresh per-line `LineAccount` + controller-as-operator + the gating hook,
§4.3/§4.4) is **internal to the Euler adapter**; other venues enforce "only the controller borrows" their own
way. M1 may collapse the adapter into the controller as long as the `IZipcodeVenue` seam holds, so venue two is
a drop-in adapter.

**Oracle/registry portability — one cache, per-venue read adapters.** The registry's *data* (the CRE-written
equity-mark cache keyed on `LIEN_i`, §4.1) is venue-neutral; its *read interface* is not. The
`BaseAdapter`/`IPriceOracle` face is the **Euler read-adapter**, reached on Euler through a **per-line
`EulerRouter`** that resolves the line's escrow collateral vault → `LIEN_i` → registry and is **frozen at
origination** (no shared router; the oracle key stays `LIEN_i`, §4.1). Aave / Morpho each get a sibling
read-adapter over the **same cache** (their own price-read shape). Re-pointing pricing to a new venue is a new
read-adapter, not a re-underwrite.

**Known secondary coupling — the supply side.** The named primacy is CRE/oracle/registry; the supply side is
*also* venue-coupled (the protocol's privatized lending yield is captured via the venue-pool fee-shares, §5/§17). For M1/M2 the yield engine is Euler's (EulerEarn); other venues come later;
deeper supply-side venue portability is a deferred item, re-decided when a second venue is actually targeted.

---

## 5. Supply, mint & yield routing

**Mint / deposit flow:**
```
deposit(USDC)                          // plain mint (hold zipUSD)
  → ZipDepositModule pulls USDC
  → ESynth.mint(user, USDC * scaleUp)   // value-1:1; zipUSD is 18-dp, USDC 6-dp (scaleUp = 1e12); module is the capacity-gated minter
  → venuePool.deposit(USDC, WAREHOUSE_SAFE)  // USDC goes to work; the CreditWarehouse Safe is the EE-share receiver (protocol custody, §4.5); the module holds no shares

zap(USDC)                              // default UX: deposit → stake in one tx
  → ESynth.mint(module, USDC * scaleUp)      // mint zipUSD to the MODULE (transient)
  → venuePool.deposit(USDC, WAREHOUSE_SAFE)  // USDC to work; warehouse Safe is the EE-share receiver
  → szipUSD.depositFor(USDC * scaleUp, user) // Baal mint shaman pulls the module's zipUSD via transferFrom (per-zap zipUSD allowance) and mints Loot to user (§4.5)
  → user holds szipUSD Loot (the headline junior position)
```

**Yield routing (native venue perf-fee — no new contract).** Set the venue pool's `setFeeRecipient(...)`
(`EulerEarn:258` for config one) and `setFee(f)` (`:243`). On interest accrual, `_accruedFeeAndAssets` mints
`feeShares` to the recipient (`_mint(feeRecipient, feeShares)`, `:889`). **Open wiring item:** whether the
recipient is the **szipUSD Baal Safe** itself or a separate protocol holder/the treasury directly is an open
8-B/treasury wiring question (under the Baal model szipUSD is a Loot share over a basket Safe, not an EE-share
holder) — economically the yield is the protocol's either way (§17). Mechanically this is the same
performance-fee mechanism 3Jane uses with `USD3`/`sUSD3` — but here the accrued fee-shares are the
**protocol's privatized yield** (the real lending APR + fees), held protocol-side and resolved to the
**treasury, which recycles them into buying xALPHA** (§17 yield routing); they are **not** the depositor's
return. **The szipUSD depositor's return is the xALPHA subsidy** (+ the HYDX/USDC pool + the Duration-Bond
premium). zipUSD itself stays flat $1 (a fixed claim, not a share). The perf-fee `f` and the subordination
**floor** (no cap, §2) are governance-configurable build-time parameters (§17). (The exact M1 destination of
`feeRecipient` — a protocol holder vs the treasury directly — is the implementation detail settled with the
treasury module; economically the yield is the protocol's either way, §17.) **Venue note:** this perf-fee
routing is the Euler venue's; capturing the yield on another venue is part of the deferred supply-side
portability (§4.7).

> **Yield routing (DECIDED — §17).** The lending APR + protocol fees are the **protocol's** real yield; for M1 they
> **over-collateralize zipUSD in the `CreditWarehouse`** (the surplus cushion), with the treasury buyback that
> privatizes them into **xALPHA** deferred **post-M1**. The szipUSD depositor's M1 return is **NAV accretion** — the
> HYDX-vamp free value recycled into the basket (8-B10), realized on exit at NAV — **not** the lending yield (+ any
> post-M1 xALPHA emission incentive). See §17.

**Note on `f` (build-time calibration).** `f` is the venue perf-fee parameter (EulerEarn for config one) — the
fraction of pool interest captured **protocol-side** as fee-shares (the privatized yield, §17). It does **not**
set the depositor's return (that is the **xALPHA subsidy**); it sizes how much of the lending interest the
protocol captures versus leaves as the over-collateralization cushion above the zipUSD supply. Calibrate `f`
against the treasury's xALPHA-buyback budget, not against a junior APR.

---

## 6. Redemption & exit (senior vs junior)

zipUSD (the **$1 utility dollar**) and szipUSD (the **junior**, the main product) leave by different
mechanisms, because they are different instruments. zipUSD is a $1 hard claim where many holders compete for
limited cash → a **pro-rata epoch queue at par** (§6.1). szipUSD is share-backed, NAV-floating, first-loss
capital → the **Exit Gate** (Loot-custody + intent queue + liquidity windows, §6.4), which fits the floating NAV,
removes the raw-ragequit footgun, and deters runs. Both ultimately hit the same liquidity ceiling: you can only get
out as much USDC/value as the pool can free (§6.3).

### 6.1 Epoch queue at par (primary, zipUSD) — `ZipRedemptionQueue`
The USDC backing zipUSD is lent out to illiquid lien markets, so par redemption is a **30-day epoch
queue** with **pro-rata partial fills** when the pool can't free enough cash. **(Locked: 30-day epoch; no
mid-epoch cancellation** — a committed request keeps the pro-rata denominator stable until settle, and the
secondary AMM (§6.2) is the early-exit path.**)**

- **Base:** fork `erc7540-reference` `BaseERC7540` + `ControlledAsyncRedeem` (MIT) for the
  `requestRedeem → fulfill → claim` lifecycle + operator approval. A redeemer calls `requestRedeem(zipUSD)`;
  the zipUSD is escrowed and the request joins the current epoch's queue.
- **Epoch + pro-rata (clean-room, modeled on Maple):** at the 30-day boundary, `settleEpoch()`:
  1. read freeable USDC from the venue pool (what the pool can withdraw now);
  2. `redeemable = queued × freeable / totalQueuedValue` per requester (pro-rata; full fill if liquidity
     suffices) — the `MapleWithdrawalManager:383` idea, reimplemented;
  3. burn the filled zipUSD, withdraw the USDC from the venue pool, mark each requester `claimable`;
  4. carry the unfilled remainder to the next epoch (`Maple:262-271` carry-forward idea).
- **Trigger:** `settleEpoch()` is called by the controller on the 30-day boundary via a Go CRE
  `cron.Trigger` (§8) — reuses the controller-as-privileged-caller and the cron workflow.
- Claiming is a separate `withdraw`/`redeem` against the `claimable` balance (7540 semantics).

### 6.2 Instant secondary (market)
Sell zipUSD into a **zipUSD/USDC** AMM at the market price for an immediate exit (below par when the
queue is backed up; arbitrageurs who will wait the queue buy the dip). The queue is the at-par path; the
AMM is the fast path. **zipUSD's primary peg-liquidity (the epoch queue + a zipUSD/USDC AMM) is kept
independent of xALPHA** (the reflexivity finding) — zipUSD's exit must not depend on xALPHA's depth. The
post-M1 **zipUSD/xALPHA POL** (the engine's LP, §4.5) is the *yield/incentive* venue, deliberately
**off-center** from zipUSD's primary exit, so an xALPHA crash cannot crater zipUSD's redemption path.

**Junior secondary (szipUSD).** Because szipUSD is a **transferable** ERC-20 share, the *impatient* junior exit
(§6.4) is **selling szipUSD/USDC on a CoW order book** — instant, peer-funded, no basket touched, the market pricing
the duration/impairment risk. This is a **separate book from the senior zipUSD/USDC AMM above** — different
instrument, do not conflate. The protocol's **8-B14 buy-and-burn** posts discounted standing bids (engine USDC,
below NAV) and burns the szipUSD it fills (§4.5.1).

### 6.3 The real constraint: redemption vs. draw contention
`settleEpoch()` can only fill up to the USDC the venue pool can free at that moment, which depends on the
lien markets having repaid. **Redemptions compete with new draws for the pool's free cash.** That
contention — not the queue mechanics — is the binding limiter (and the same contention a **duration squeeze**
stresses, §11), and it is why par redemption is an epoch queue rather than instant. Policy levers: the **cash-reserve ratio** (§8.2), epoch length, and pacing
draws against pending redemptions. This contention is exactly what the **systemic Duration Bond (§11 trigger
B)** defends against — a utilization breach engages the junior lock to prevent a run.

### 6.4 Junior exit (szipUSD) — the Exit Gate (custody + intent queue + liquidity windows)
The junior does **not** use the at-par epoch queue (that is zipUSD's mechanism) and does **not** expose raw Baal
`ragequit` to depositors. Baal `ragequit` is permissionless on the **Loot-holder** and **cannot be paused**
(`reference/Baal/contracts/Baal.sol:619`; pause blocks transfers, not ragequit) — so the only way to gate it is to
keep depositors from ever **holding** raw Loot. The szipUSD vault therefore exits through an **Exit Gate** — the
canonical Loot custodian of the **two-token model** (soulbound gate-held Loot + a transferable szipUSD share;
supersedes the old `sUSD3` cooldown + soulbound-claim model, which assumed a ragequit gate Baal does not have):

1. **Custody + issuance (this is what removes the footgun).** On deposit, the Gate (which holds Baal `manager`,
   absorbing the old mint shaman) mints **Loot to itself** (mint bypasses the Loot pause — `LootERC20` allows
   `from==0`) and mints the depositor **transferable szipUSD**, **NAV-proportional** (`shares = value / navPerShare`
   via `SzipNavOracle`, §7; round-down, staleness-guarded). The **soulbound property is on the internal Loot** —
   the gate is the sole Loot-holder and thus the sole ragequit caller, so it controls *when* exits happen — **not**
   on the user share, which is a freely transferable ERC-20. So no depositor can call `ragequit`, yet szipUSD trades
   on the CoW book (§6.2). (The gate keeps `szipUSD.totalSupply() == its Loot balance`.)
2. **Intent queue.** To leave, a holder signals intent — `gate.requestExit(amount)` — which queues the claim; no
   assets move yet. ("Marie taps Exit once; her request joins the next window's queue.")
3. **Liquidity windows (free — they ride the harvest cadence).** The gate processes the queue **only during
   liquidity windows**: the recurring moments when the auto-sodomizer harvest loop has **unstaked the ICHI LP** (it
   pulls the LP off the gauge for borrow collateral every cycle, §4.5.1 / 8-B5/8-B6), so the basket is liquid in the
   main Safe and a ragequit pays **full pro-rata**. (A raw ragequit while the LP is staked reads `balanceOf(LP)=0`
   and shortchanges the LP leg — the gate exists precisely to avoid that mechanical haircut.) A window is opened by a
   **set-once `windowController`** — the **CRE operator / keeper** that coordinates with the harvest (the *operator*
   tier of the §4.5 item-0 two-tier model: narrow blast radius — it can only *process the queue*, never mint or
   change authority) — calling `gate.processWindow(maxClaims)` (gas-bounded; the keeper shards). At the window the
   gate **ragequits the queued Loot against the main Safe — a plain in-kind, pro-rata claim across the basket legs**
   (`tokens[]` = the sorted basket assets: zipUSD + xALPHA, the LP having been decomposed to its underlying by the
   harvest). The exiter receives **their pro-rata slice of the (free, main-Safe) treasury, in-kind** — worth
   `shares × NAV/share` by construction (the share is a volatile NAV-bearing claim; the slice self-prices, so there
   is **no oracle read, no value-cap, and no numeraire conversion in the exit path** — the NAV oracle prices
   *issuance*, not exit). The matching Loot + escrowed szipUSD are burned. **The leaver's downstream legs are NOT the
   gate:** a separate Zodiac **auto-dump module** market-sells the xALPHA leg → zipUSD on Hydrex (so they end holding
   only zipUSD), and the existing **`ZipRedemptionQueue`** (§6.1) turns that zipUSD → USDC. The gate's sole job is
   *ragequit the pro-rata share + burn the loot.*
4. **Free vs committed — the sidecar IS the freeze.** Only the **free** junior equity lives in the main
   (ragequit-target) Safe. The equity **committed to live credit lines** — sized to credit-warehouse **utilization**
   — lives in a **non-ragequittable sidecar Safe** (`BaalAndVaultSummoner`, §4.5) running the auto-sodomizer, so it
   keeps earning HYDX while reserved. A window exit redeems your share of the **free** equity; the **committed**
   slice is not redeemable until those lines close/repay and the CRE rotates that equity back to the main Safe. This
   *is* the Duration Bond freeze (§11) — **structural, not a ragequit gate**: the committed equity simply isn't in the
   redeemable Safe. The withhold fraction `committedFraction = committed backing / basketNAV` = credit-warehouse
   **utilization** (§11) = the fraction held in the sidecar — **not** sized by any single default's at-risk amount
   (that sizes only the NAV markdown, §4.6/§11).
5. **Coverage floor = the freeze (not a governed knob).** The floor *is* the committed/utilization slice the sidecar
   already locks (item 4) — window exits reach only the **free** equity, so junior NAV can never drain below the
   utilized first-loss backing. Structural, enforced by the freeze; **no separate floor percentage to set** (§2).
6. **Default / stasis.** If lines stall or default, utilization stays high → the committed slice stays in the sidecar
   → window exits keep redeeming only the free equity → **nobody front-runs the loss**. The slashed xALPHA duration
   bond lands **in the sidecar**; the sidecar keeps printing HYDX; the slice releases when the hole is made whole
   (§11/§4.6).
7. **Impatient exit = the CoW secondary (no forfeit).** A holder who wants out *now* — including their share of the
   frozen slice — **sells szipUSD on the CoW book** (§6.2) to patient capital that prices the duration/impairment
   risk; the basket isn't touched. There is **no protocol forfeit-haircut** — the market prices it. The protocol's
   **8-B14 buy-and-burn** posts discounted standing bids (engine USDC, below NAV) and **burns** the szipUSD it buys,
   actualizing the seller's haircut to the patient holders.

This is the **junior-exit valve only — zipUSD itself never freezes** (the senior is the composable dollar; its only
throttle is the epoch queue, §6.1). The window cadence is the timing gate, the sidecar is the freeze, and gate
custody removes the raw-ragequit footgun. Window cadence / floor / `f` remain governed params (§17).

**Legibility (so a depositor never panics about "where are my tokens").** The depositor UI shows **one position** —
"szipUSD: $X, ~Y% APR" — never raw Loot or the gate/sidecar internals. Exit is one button → a clear status track:
**Requested → Window opens ~<date / live countdown> → Claimable → Claimed**, with the **next-window estimate** (it
rides the predictable harvest + line-expiry cadence) and an **estimated payout**. The gate and sidecar are surfaced
as named, audited components that hold her claim explicitly — her funds are never "lost in a weird contract," they
are in a tracked queue with a visible clock.

---

## 7. Oracle architecture & rationale (decision: push-cache)

There are **three pricing inputs**, all CRE-mediated (same DON push-cache trust model):
1. **Collateral equity mark** (the **Proof of Value** appraisal − senior debt) → the zipUSD dollar NAV — the lien oracle (`ZipcodeOracleRegistry`, §4.1).
2. **xALPHA mark** — a junior basket leg + the **Duration-Bond premium**. **Two layers** (`bridge/xalpha-bridge-impl.md §2`):
   the **LST exchange rate** (`staked alpha ÷ xAlpha supply`, read from the validator stake — stake accounting,
   **no pool price** in the mint/redeem path, so the subnet emissions accrue here non-manipulably) × **`alphaUSD`**
   (the subnet **TAO/alpha AMM TWAP** × TAO/USD). Only the `alphaUSD` market leg is TWAP'd + staleness/circuit-break
   guarded. xALPHA is never sold to defend the peg; it is sold (alpha→TAO→USDC) only as a bounded last resort to
   cover a *realized* loss (§11) — the mark sizes that backstop, the sale executes at market.
3. **szipUSD NAV-per-share** (`SzipNavOracle`) — **the junior share price; the issuance + exit pricing primitive**
   (NAV is **no longer display-only**). See below.

**`SzipNavOracle` — the szipUSD share price (the issuance/exit primitive).** A `ReceiverTemplate`-based hybrid: the
CRE pushes **only** the prices it cannot read on Base (the xALPHA `alphaUSD` leg; HYDX if thin); the contract **reads
all quantities on-chain** (balances across the main + sidecar Safes incl. the **staked** ICHI LP read off the gauge),
composes the basket NAV, and maintains an **on-chain cumulative TWAP accumulator** on `navPerShare`. Consumers read
the **time-weighted** share price over a governed window **`W ≈ 4h`** (§17). Per-leg: zipUSD/USDC = $1; xALPHA = the
two-layer mark (input 2); HYDX = pool TWAP, oHYDX = intrinsic (`HYDX × (1−discount)`); the **ICHI LP marks at true
reserve value so IL is marked-through** (not hidden); **veHYDX is permalocked → NOT a markable leg** (only the oHYDX +
fees it yields count, as claimed). **Bracket:** issuance at `max(spot, twap)`, exit at `min(spot, twap)` — protecting
resident holders both directions; **staleness pauses issuance**; a per-push **deviation circuit-break** rejects a bad
mark. Impairment provisions (§11) are written **immediately downward** by the `DefaultCoordinator` (never
TWAP-smoothed up); recovery writes back up. **Two write authorities, mirroring the lien registry's split
(§4.1):** the **immutable Forwarder** pushes the off-chain leg marks as **reportType 7** (§4.4); a **set-once
`DefaultCoordinator`** (§11, M2) is the **sole** provision writer, **bounded** (mark down only by
`atRisk × (1 − recoveryFloor)` on a verified default, up only by realized receipts — never an arbitrary NAV).
**szipUSD's own supply is the denominator** (`navPerShare = basketNAV / (szipUSD.totalSupply() − engine
pending-burn)`); the oracle is wired to the szipUSD token **set-once** (like the registry's controller, since
the Gate/share are deployed after the oracle) and the wiring is frozen by the deploy-time renounce. At zero
supply the oracle returns the genesis `navPerShare₀ = $1.00`. The protocol **never reads the szipUSD *market*
(CoW) price** for accounting — only `SzipNavOracle`. The oracle also exposes a **`valueOf(address asset, uint256
amount) public view returns (uint256)`** per-asset 18-dp USD mark (for the whitelisted basket deposit assets
{zipUSD, xALPHA}) — the **Exit Gate calls it at issuance so the Gate owns valuation and no caller asserts a price**
(§3.4/§6.4); it is the public projection of the oracle's existing per-leg mark, additive (no behavior change).

| Axis | CRE push-cache (chosen) | Data Streams |
|---|---|---|
| Bespoke per-home feed | yes — any asset we define | no — feeds permissioned/standardized only |
| CRE support | yes — native `WriteReport` | no — no DS capability in `cre-sdk-go` |
| Decentralization | yes — f+1 DON sigs | yes — (but only for existing feeds) |
| On-chain read | view read of cache | view read of cache (DS `verify` is tx+fee, can't run in view → still cached) |
| Per-update cost | DON report + 1 EVM tx | LINK/native fee + subscription |
| New asset provisioning | one-time fallback set; no per-lien config | Chainlink Labs negotiation |

Both approaches are cache-then-view underneath; the only real difference is who signs/provisions.
**Push-cache via CRE is the only option that supports per-home pricing, is CRE-native, stays
DON-decentralized, and is cheapest at scale.**

The registry is a **verified underwriting attestation of equity, not a market price** — a 1/1 lien has no
market to discover a price or to manipulate. Housing is slow (not ETH-volatile), so the design carries:
(1) the honest equity mark on-chain (§4.1), conservatism in the LTV gap (§4.2), not synthetic bid/ask
spreads; (2) a **long validity window refreshed by event-driven Proof re-marks** (origination / secondary
acquisition / deviation, §4.1), not a 5-min staleness clock or a daily heartbeat; (3) liquidation driven by
**delinquency status** (§4.4e), so a stale/fake price alone cannot liquidate. The genuine threat is the
write path, hardened by the **timelocked router governor** and **immutable Forwarder** (§4.4/§13). The value
is the **Proof-notarized origination appraisal** (§4.1/§8.5) — there is no model AVM to de-bias, so there is
no HPI band, and HPI is not an on-chain input. Data Streams remains an optional transport, not required.

**Subnet ↔ CRE integration (resolved: Shape B for M1, Shape A as endgame).** The decentralized
validation/compute is the **Zipcode Bittensor subnet**: its validators run the containers that fetch each
API and **zk-verify** the data (no PII exposed), scoring and reaching consensus on the underwriting inputs
and the equity mark. The open question is *who signs the report the Keystone Forwarder accepts* — a CRE DON
is a permissioned, Chainlink-registered node set, not an arbitrary one. Two shapes:
- **Shape B (the M1 design).** The subnet is the **validated-data / compute layer**; a **standard Chainlink
  CRE DON** reads the subnet's output in node-mode, aggregates, and signs the report for the immutable
  **Keystone Forwarder** (f+1 DON sig, §4.4). Trust root = the Chainlink DON — exactly what this spec
  assumes; buildable on stock CRE/Keystone.
- **Shape A (endgame).** The **subnet validators are themselves the signing DON** (provisioned as a CRE DON
  in the Keystone registry, or via a custom forwarder accepting subnet-consensus sigs). Trust root = the
  subnet's consensus — cheaper and fully incentive-aligned, but a different security model and non-stock
  plumbing; pursued with Chainlink once supported.
Either way the on-chain **gate shape** (immutable Forwarder + workflow identity) is unchanged — only the
signer's provenance differs. See §8.

---

## 8. CRE workflows (Go, `cre-sdk-go`)

Workflows are authored in **Go** and compiled to `wasip1` (patterns in
`reference/cre-sdk-go/standard_tests/*/main_wasip1.go`). Go is the workflow language; the on-chain write
takes `runtime` as its first positional arg (no signature footgun). Our workflows are deterministic (no
RNG), but the Go SDK's consensus-safe `runtime.Rand()` (`cre/runtime.go:25`) is available if ever needed
(the TypeScript SDK lacked it). The workflows run on the DON per **Shape B** (§7): the Zipcode subnet
validators produce the zk-verified inputs, and a standard Chainlink CRE DON aggregates them and signs the
report for the Keystone Forwarder.

### 8.1 Underwriting / origination / revaluation
- **Trigger:** `http.Trigger(*Config)` (`capabilities/networking/http/trigger_sdk_gen.go:16`, originator
  submits an application) for origination; **event-driven re-pricing** on **secondary acquisition / deviation
  / draw** events (revaluation, writes **direct** to the registry, §4.1/§4.4b). **No cron heartbeat** — the
  mark is event-driven Proof (§4.1).
- **Inputs (fetched per-node, zk-verified, then aggregated; the full source→surfacing map is §8.5):** the
  **Proof attestations** — **Proof of Lien** (perfected + ownership), **Proof of Value** (the appraisal),
  **Proof of Insurance** — plus identity/income/credit/title proofs (Plaid, Credit Karma, Pippin/DART) and
  Block Analitica LTV/risk params, via `http.Client.SendRequest(nodeRuntime, *Request)`
  (`capabilities/networking/http/client_sdk_gen.go:44`, runs in **node mode**) + `runtime.GetSecret`
  (`cre/runtime.go:35-59`, **DON-Runtime only, not node mode** — so raw PII never enters a consensus
  observation; only proofs/derived bounds do). zkTLS verification (Reclaim/EigenLayer or subnet-native) runs
  at the subnet/node layer (§7). **No Subnet 46 AVM, no regional HPI** (§4.1).
- **Consensus:** `cre.RunInNodeMode(...)` (`cre/runtime.go:166`) + `cre.ConsensusIdenticalAggregation[T]()`
  (`cre/consensus_aggregators.go:33`) for **both** the Proof value and the boolean gates — the value is a
  notarized **fact** (one appraisal), not a model estimate, so the old `ConsensusMedianAggregation` for an
  AVM is no longer needed.
- **Output:** ABI-encode the payload into a `cre.ReportRequest`, `runtime.GenerateReport(req)`
  (`cre/runtime.go:58`) → `evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{Receiver: …, Report:
  report, GasConfig: …})` (`capabilities/blockchain/evm/client_sdk_gen.go:293`). Receiver is the
  `ZipcodeController` (origination/draw, atomic price seed) or the `ZipcodeOracleRegistry` (revaluation).

### 8.2 Funding / cash-reserve (no optimizer)
There is **no cross-market yield optimizer** — the lien markets are credit lines funded to demand, not
yield venues to optimize across, so the euler-allocator-bot pattern does not apply. "Allocation" is two
deterministic actions:
- **Per-line funding:** the origination/draw report (§4.4a) does `venue.fund` pool→market up to the line's
  `cap` (= the credit limit), inline — no separate workflow. (Euler adapter: `EulerEarn.reallocate`.)
- **Cash-reserve ratio (locked: fixed-%):** keep a **fixed** reserve fraction of pool USDC un-supplied for
  LP withdrawals and lend the rest to demand — a deterministic rule (optionally a `cron.Trigger` rebalance
  reading state via `evmClient.CallContract`), no RNG, no annealing. A dynamic ratio (scaling with the
  pending redemption queue) is a later parameter swap, not a redesign (§17).
- **Duration-squeeze response (the on-chain trigger host).** The same `cron.Trigger` / `evmClient.CallContract`
  rebalance reads utilization `U = borrowed/totalAssets`; on a `U ≥ U_lock` breach it (i) **paces new draws
  against pending redemptions** and (ii) engages the **§11 trigger-B** systemic junior lock. This is the
  on-chain host for the squeeze trigger (the optional CRE "secondaries-down" report can trip it earlier, §8.4).

### 8.3 Redemption settlement
A `cron.Trigger` on the 30-day boundary calls `settleEpoch()` (§6.1) against the venue pool's freeable USDC.

### 8.4 Default / recovery
Delinquency status and recovery amounts are **off-chain truths** that arrive as DON-signed reports. This
path reports `(lienId, delinquency status, recovery proceeds = foreclosure + insurance on resolution)` via
`runtime.GenerateReport → evmClient.WriteReport(runtime, {receiver: DefaultCoordinator})`. **Markdown is not
in this report** — it comes from the **deviation-event Proof re-mark** (§4.1); the report triggers the
**Duration Bond** and carries the recovery proceeds. The coordinator verifies the report (immutable CRE
Forwarder + workflow identity) before acting.

**Secrets/config & scaffolding:** project + secrets config; DON-only `GetSecret` (no PII in node-mode
consensus). For the concrete Go scaffold a fresh engineer should clone the trigger→node-mode-fetch→
consensus→`GenerateReport`→`WriteReport` shape from `reference/cre-sdk-go/standard_tests/*/main_wasip1.go`
and the project layout from `reference/cre-templates`; the report struct + `consensus_aggregation` tags
must match the on-chain report ABI in §4.4; secrets-declaration format, `GasConfig`, and `cre-cli`
simulate/deploy are cre-cli mechanics documented in those references.

### 8.5 Off-chain underwriting & proof layer
The CRE workflow (§8.1) fans these in per-node (zk-verified at the subnet/node layer) and aggregates them
into the origination report's gates and the equity mark. Each off-chain truth becomes a **zk-verified
attestation** — a boolean gate or a value reached by **identical consensus** (the inputs are facts, not
model estimates) — and raw PII never enters consensus (§8.1).

| Credit question | Source | On-chain surfacing |
|---|---|---|
| Real, ID-verified, not sanctioned? | Plaid (KYC, facecheck, sanctions) | Reclaim proof → boolean gate in report |
| Creditworthy? | Credit Karma (VantageScore 3.0; TransUnion/Equifax) | Reclaim proof → score band |
| Can repay (stable income)? | Plaid (account reads) | Reclaim proof → income ≥ threshold |
| Clean title / unpaid tax? | Pippin Title | Reclaim proof → boolean |
| Lien room / position? | DART + Pippin | Reclaim proof → senior debt, lien position |
| **Lien perfected & enforceable?** | **Proof of Lien** (notarization over SPV docs, `spv-lien-proof.md`) | identical consensus → **boolean gate before mint** |
| Home value → equity / LTV? | **Proof of Value** (notarized origination appraisal from SPV docs) | identical consensus → equity mark → `ZipcodeOracleRegistry` (§4.1) |
| **Insured?** | **Proof of Insurance** (policy covers the position) | identical consensus → **boolean gate before mint**; claim path at recovery (§4.6/§11) |
| Optimal LTV / risk params | Block Analitica | report params → `setLTV` bounds (the borrow/liquidation LTV gap carries the conservatism cushion) |

Cred Protocol / Blockchain Bureau add on-chain-address credit scoring on top of off-chain VantageScore.

---

## 9. Authorization & control-flow trace

**One-time setup** (governor/owner). The Euler calls below wire the **`EulerVenueAdapter`** (config one; for
M1 it may be the controller itself, §4.4) — it holds the Euler roles — while the controller/registry get the
immutable Forwarder + identity. Venue wiring: `venuePool.setIsAllocator(adapter, true)`;
`venuePool.setFeeRecipient(...)` + `setFee(f)` (recipient wiring is an open 8-B/treasury item, §5); grant
`ESynth` mint capacity to **`ZipDepositModule`** (the module mints zipUSD 1:1-by-value on deposit, and the zap
mints transiently to the module before handing it to the szipUSD mint shaman, §4.5) — **size the capacity to its
expected flow (a bounded cap, not `max`)**;
**`ZipDepositModule.setStakingVault(szipUSD)`** (set-once) to store the szipUSD address — the zap grants szipUSD
a per-zap **zipUSD** allowance and calls `depositFor` (the Baal mint shaman); there is **no** EE-share allowance
(the warehouse Safe holds the EE shares, §4.5 szipUSD seam); then **renounce `ESynth` ownership** (S7) so
its entire owner-only surface (`setCapacity`, `allocate`, `deallocate`) is permanently frozen and the only
live mint surface is those two pre-granted capacities;
grant the adapter **EulerEarn curator + allocator** (the per-line market onboarding inside `openLine`
requires curator, §4.7; deploy the EE pool with **timelock 0** for M1 so `submitCap`→`acceptCap` is atomic —
a single-curator simplification, production-hardening item); the **isolated EVK markets + per-line routers are
created per-lien inside the venue adapter's `openLine`** (§4.7: escrow collateral vault + USDC borrow vault
with `setGovernorAdmin(adapter)`, `setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)` repay-ungated,
`setInterestRateModel(irm)`, a dedicated `EulerRouter` wired to the registry and frozen) — there is **no
shared router and no `govSetFallbackOracle`**; the per-line router keys `(LIEN_i, USDC)` on the registry and
is frozen at birth (§4.1). Deploy an **OpenZeppelin `TimelockController`** (delay ≈2 days) **for §17
parameter governance only** (szipUSD floor / `f` / cooldown — §17), **not** as a router governor;
deploy registry/controller with an **immutable** Forwarder — the base `setForwarderAddress` is non-virtual
(not overridable), so immutability is sealed by **renouncing `Ownable` ownership** as the final wiring op;
**but first, before renouncing, call `setExpectedAuthor(WORKFLOW_OWNER)` and
`setExpectedWorkflowId(WORKFLOW_ID)` on every `ReceiverTemplate` subclass** (`ZipcodeController`,
`ZipcodeOracleRegistry`, and — when added — `DefaultCoordinator`) **and assert `getExpectedWorkflowId() != 0`
on each immediately before `renounceOwnership()`, aborting the deploy otherwise**. The workflow-identity
check in `ReceiverTemplate.onReport (:88-117)` is enforced **only when these expected values are non-zero**
(`x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol:143,184`); if `renounceOwnership` runs
first, the identity check is bypassed and any workflow the Forwarder accepts can call `onReport`. **Set
identity first (assert it), then renounce `Ownable` ownership** (§4.4). **No controller-level operator-wiring
step is needed** — under the per-line borrower model (§4.4) each line's operator grant is issued **at
origination** by the adapter's per-line `LineAccount` (which deploys, registers its fresh prefix, and calls
`EVC.setAccountOperator(borrowAccount, adapter, true)` — granting the **adapter** (the borrow-driver), §4.7),
so there is no
controller-prefix blanket `setOperator` to wire before the renounce and no deploy-time EVC step gating
`draw`.

**Origination path:**
```
CRE underwriting workflow (Proof gates passed: lien + insurance)
  → runtime.GenerateReport(req) (f+1 DON sigs; Shape B §7)
  → evmClient.WriteReport(runtime, {receiver: ZipcodeController})
  → CRE Forwarder (immutable; verifies DON sigs)
  → ZipcodeController.onReport → _decodeMetadata (workflowId/owner check) → _processReport
       ├─ LienTokenFactory.create(lienId)            // mint 1/1 collateral (gates passed)
       ├─ ZipcodeOracleRegistry seed cache[LIEN_i]   // Proof of Value mark; the per-line ROUTER_i
       │                                             // resolves (LIEN_i,USDC) here (§4.1) — frozen in openLine, no router gov call
       ├─ venue.openLine + venue.setLineLimits(...)  // controller drives via IZipcodeVenue
       └─ venue.fund(line, drawAmount)               // pool → market
          venue.draw(line, drawAmount, Erebor)       // borrower-of-record; Erebor wires USD to originator
```
(Euler adapter realizes the venue calls as `setLTV` + the per-line `LineAccount` deploy/operator-grant +
`EVC.call(borrowVault, lineBorrowAccount, 0, borrow)`; the gating hook passes because the borrowing account
has authorized the **adapter** (the borrow-driver = the `EVC.call` caller) as its EVC operator, §4.3.)

**Supply path:** default **`ZipDepositModule.zap(USDC)`** → `ESynth.mint` 1:1 → `venuePool.deposit` →
auto-stake `zipUSD → szipUSD` (§4.5); or plain `deposit` to hold zipUSD. The szipUSD depositor's return is the
**xALPHA** subsidy; the lending perf-fee routes **protocol-side** (`feeRecipient`, §5/§17).

**Repay path:** originator pays USD to Erebor → Erebor on-ramps USD→USDC → permissionless repay against the
line's borrow position (no hook, no report needed; Euler adapter: `EVault.repay` on the line's borrow account).
**Closing is separate:** once the controller observes debt is zero (`venue.observeDebt`), a close report
burns the lien token and emits `LienReleased` → off-chain SPV releases the recorded lien.

**Redeem path:** `ZipRedemptionQueue.requestRedeem(zipUSD)` (escrowed) → 30-day `settleEpoch()` (CRE cron)
pro-rata fill from freeable USDC → `claim`.

**Default path:** CRE default report → the committed slice is **already frozen** in the sidecar (structural,
utilization-sized — a default does not move it, §6.4) → `DefaultCoordinator` **writes a conservative provision into
`SzipNavOracle`** (§7; sized from the deviation Proof re-mark, §4.1) and **holds the xALPHA bond**. On recovery
(foreclosure + **insurance** proceeds, Proof-attested): the **provision writes back up** (junior heals); the
Duration Bond auto-releases with the **xALPHA premium** (`slashXAlphaToCohort`), or xALPHA is slashed to a remaining
capital hole first (`slashXAlphaToCapital`). On confirmed shortfall (after insurance + xALPHA): the **provision
settles permanently** — junior `navPerShare` carries the realized loss, **pari passu** (no escrow-share burn).

---

## 10. Lien lifecycle state machine

```
[origination] ──mint + Proof-of-Value seed + venue.openLine/fund/draw──▶ [active]
   [active] ──draw/accrue (fixed-rate IRM)──▶ [active]
   [active] ──full repay──▶ [closed] (burn token, LienReleased → SPV release)
   [active] ──acquired on secondary / MBS absorption──▶ [taken out] (fresh Proof; debt transfers, §4.4e)
   [active] ──missed payment──▶ [delinquent] ──grace elapsed──▶ [default]
   [default] ──deviation Proof re-mark + Duration Bond──▶ [in recovery]
   [in recovery] ──foreclosure + insurance repay loan──▶ [resolved] (Duration Bond releases + xALPHA premium)
   [in recovery] ──recovery + insurance + xALPHA short──▶ [written-off] (settleAccount; junior bears residual)
```
Each transition maps to controller / `DefaultCoordinator` `_processReport` branches + venue ops + events.

**Credit-line mechanics.** Each credit line (an isolated market on the venue) is funded to its `cap` on
demand (capital-efficient — no idle per-line buffer; a line runs near its borrow LTV). A line may drift
*past* `liquidationLTV` purely from interest accrual and is **not** auto-liquidated — there is no liquidator
market, and liquidation is controller-gated + delinquency-driven (§4.4e). The venue's account-status check
then blocks *further draws* on that line (you can't extend more credit to an underwater line) without
force-closing it. On default the protocol injects **no new USDC**: the line simply accrues and waits, and is
repaid from legal recovery + insurance, marked to **recovery value at the deviation event** (§11) — the
junior tranche absorbs any shortfall, not the senior/pool (§11).

---

## 11. Loss / default / recovery machinery

The base **gating model is unchanged**: borrow and liquidate stay controller-only, repay stays
permissionless (§4.3), and the controller remains the on-chain borrower of record; this machinery enriches
the default path via `DefaultCoordinator` (§4.6) and `LienXAlphaEscrow`.

> **Duration-lock design (locked 2026-06-05; loss model refined to the provision-that-recovers, 2026-06-07).**
> Five clarifications, design-locked (loss-side contracts are M2; the model below is current):
> 1. **The Duration Bond freeze is a time-HOLD, not a loss.** It is a redemption-gate on a pro-rata subset of
>    szipUSD shares; the gated shares **keep accruing while frozen**. It exists to pin the junior in place
>    during the resolution window so it cannot run (§6.4). **zipUSD itself never freezes** (the senior is
>    throttled only by the epoch queue, §6.1).
> 2. **The recovery waterfall (the freeze buys time for these to land), in order:** (a) **secondary purchase**
>    of the distressed lien (recover off the collateral), (b) **outside insurance** payout, (c) **xALPHA
>    bond liquidation — alpha → TAO → USDC on Bittensor** (this *is* "slashXAlphaToCapital"; xALPHA = the
>    "xALPHA" bond, §2), then (d) **residual → the frozen junior**.
> 3. **A conservative provision-that-recovers, marked on a staircase of verified facts (2026-06-07).** A default is
>    **freeze-dominant** (insured/collateralized HELOC = duration-risk, `recoveryFloor` HIGH, §7/§17), so the
>    `DefaultCoordinator` writes a **small conservative provision** into `SzipNavOracle` at recognition that
>    **re-marks on Proof-attested foreclosure milestones / realized receipts** (a NET-NEW **Foreclosure Proof
>    oracle**) and **writes back up**, trued-up at resolution. The waterfall (a)–(d) fills the hole; an unrecoverable
>    residual is the marked loss (pari passu). **No share-burn / escrow / `_realizeMarkdown` / `J×p`** — the mark
>    lives in the NAV oracle (§7), not a pool-share move. *(Supersedes "no markdown / passive-only".)*
> 4. **Release is objective, not discretionary** — the freeze auto-lifts on a DON-verified solvency-restored
>    report (or the §11-B utilization-hysteresis release), never a manual/open-ended lock (a trust + rug
>    surface otherwise).
> 5. **The basket NAV grows off the HYDX vamp — that is the junior's compensation AND the hole-plug.** The
>    auto-sodomizer (the vault's **core** CRE strategy, NOT a post-M1 bolt-on) continuously vamps USDC out of
>    the HYDX/USDC pool (farm oHYDX → exercise → sell HYDX → USDC → recycle into the basket), compounding the
>    Safe basket. This is what makes "frozen but earning" substantial — the junior is **well-paid for the
>    duration risk it bears** — and is itself **waterfall leg (e)**: "HYDX/USDC liquidity pays for duration and
>    plugs holes," partial **self-insurance** off the HYDX bleed. **Bounded, not infinite** (`hydrex.md`):
>    TVL-capped to the pool's absorption, front-loaded, trailing-realized + degrading over a ~6-month window —
>    a strong subsidy we **size to the pool**, with the freeze + waterfall as the backstops when it isn't enough.

**The loss is the lent-out USDC; the junior bears it as a conservative provision-that-recovers (2026-06-07).** A
defaulted lien's at-risk asset is the **USDC already lent into that loan**, recoverable only by **TIME** (cure /
foreclosure / secondary takeout) + the **recovery waterfall** (secondary purchase → outside insurance → xALPHA-bond
liquidation [alpha→TAO→USDC] → HYDX-farmed USDC — each brings **external** USDC). The junior's first-loss role has
**two parts**: (1) **provide the time via the FREEZE** (§6.4 — the utilization-committed slice of the junior basket
sits in the non-ragequittable sidecar, sized to credit-warehouse utilization, so a ragequit cannot drain the backing
while loans are live; the withheld capital **keeps earning** — "frozen but earning"); AND (2) **carry a conservative provision
on NAV** — the `DefaultCoordinator` writes a **small markdown into `SzipNavOracle`** (§7) at recognition (small,
because the underlying is insured/collateralized → duration-risk, `recoveryFloor` HIGH, §17) that **re-marks on a
staircase of Proof-attested foreclosure milestones / realized receipts** (the NET-NEW **Foreclosure Proof oracle**)
and **writes back up** as recovery lands, trued-up at resolution. The equity-mark re-mark at the deviation event
(§4.1) *sizes* the at-risk amount + the freeze; the provision is what the junior carries on `navPerShare`.

**There is no `_realizeMarkdown` escrow / tentative-burn / `loss / share_price` share move / `finalizeLoss`.** The
mark lives in the **NAV oracle**, not a pool-share operation. The junior bears the loss **pari passu via
`navPerShare`** (a lower share price = every holder's slice is worth less), never by burning specific holders'
shares.

**Realizing a confirmed permanent loss.** When the waterfall has run and a residual is **confirmed permanent**, the
provision **settles** to the realized loss: `SzipNavOracle` carries the markdown permanently (it stops writing back
up), so junior `navPerShare` reflects the true smaller basket and the **senior (circulating zipUSD) stays
$1-backed** against the reduced junior NAV. The junior's own basket assets (its accrued yield / xALPHA, via the
waterfall) and the slashed xALPHA bond are what fill the senior's USDC hole; the **junior bears the residual on
NAV, pari passu**, the senior is made whole. *(Supersedes the "WITHHELD, never marked down / sequester + burn the
frozen junior's zipUSD" levers — the loss is now the marked NAV, recoverable, not a share-burn.)*

**Default = socialized pro-rata Duration Bond.**
1. **Trigger.** `MorphoCredit.getRepaymentStatus (:526)` → delinquent → grace elapsed → default. The CRE
   reports `(lienId, status)`; `DefaultCoordinator` acts. (The same Duration Bond primitive also fires on a
   **duration squeeze**, §6.4 — there the trigger is a utilization/liquidity threshold, not a default.)
2. **Freeze (structural via the sidecar — NOT a ragequit gate, NOT engaged by the coordinator).** The **Duration Bond
   FREEZE** is **already in place** — a default does not engage it. The junior equity committed to live credit lines
   permanently sits in the **non-ragequittable sidecar Safe**, the same fraction for everyone, **sized to
   credit-warehouse utilization** (`committedFraction = committed backing / basketNAV` = the fraction held in the
   sidecar, recomputed as lines draw/repay — the Exit Gate's accounting, §6.4). A default simply keeps utilization
   high, so that slice **stays** frozen until the line repays; the at-risk amount sizes the **NAV markdown** (the
   provision into `SzipNavOracle`, §7/§4.6), **not** the freeze. The committed backing **stays in place and keeps earning** (auto-sodomizer in the
   sidecar; no escrow, no share-move, no markdown). **Implemented via Exit-Gate custody + the sidecar (§6.4), not a
   ragequit gate** — Baal `ragequit` cannot be paused, so the freeze is the equity simply not being in the
   redeemable main Safe; the Exit Gate (sole Loot-holder) only processes window exits against the free main-Safe
   equity. (UX: "xx% bonded for the resolution window, resolves with the xALPHA premium.")
3. **xALPHA bond (held, applied at resolution).** The lien's xALPHA bond is **held** through the freeze and
   applied at resolution in two jobs, in order: `slashXAlphaToCapital` — **sell xALPHA → external USDC** to fill
   any hole foreclosure + insurance left (last-resort backstop for a *realized* loss, never peg defense); then
   `slashXAlphaToCohort` — the **premium**, in-kind, priced (CRE xALPHA feed, §7), to the frozen cohort.
4. **Recovery / resolution.** **Foreclosure + insurance** (+ xALPHA, + HYDX-vamped USDC) repay the loan with
   **external USDC** (permissionless `repay`; debt → 0; the controller closes the lien) → the hole is filled →
   the **freeze releases** (the withheld backing is freely ragequit-able again) → the junior is whole + its
   accrued in-kind yield + the **xALPHA premium**, and the **provision releases** (the recognition markdown writes
   back up as recovery lands, §7). If recovery + insurance + xALPHA + HYDX confirm a **permanent shortfall**, the
   **provision settles to the realized loss**: `SzipNavOracle` carries the markdown permanently, so junior
   `navPerShare` drops **pari passu** (every holder bears it equally) and the senior stays $1-backed against the
   reduced junior NAV; the junior's own basket assets + the slashed xALPHA bond fill the senior's USDC hole. **No
   share-burn / "cut zipUSD supply" lever — the loss is the marked NAV.** **Surplus (locked):** recovery above the full debt is the homeowner's
   equity, returned **originator → homeowner** (the protocol's lien claim caps at the debt); the junior's
   compensation is being made whole + the xALPHA premium, not the homeowner's residual equity.

**Duration Bond — two triggers (loss vs liquidity).** The Duration Bond primitive (a socialized pro-rata
lock of every szipUSD position for a fixed term, realized as the **sidecar/utilization split** behind the Exit
Gate, §6.4; no per-position index, no SBT) fires on **either**:
- **(A) a default — loss-driven (the flow above).** A lien defaults → its committed backing is **already in the
  sidecar** (structural, utilization-sized — the freeze was never "engaged"; it just doesn't release while the line is
  unresolved) so window exits keep reaching only the free equity → the at-risk amount sized from the deviation re-mark
  drives the **NAV markdown** (the provision, §7/§4.6) → the committed slice rotates back to the main Safe when the
  waterfall fills the hole and the line closes → the frozen cohort receives the **xALPHA premium**
  (`slashXAlphaToCohort`, the in-kind bond). **A conservative recoverable provision on NAV (§7), no share-escrow/burn,
  no ragequit gate** — the committed backing is simply not in the redeemable main Safe (the freeze).
- **(B) a duration squeeze — liquidity-driven, no realized loss.** A system-wide liquidity event (secondaries
  freeze, loans sit past schedule, utilization spikes and the pool cannot free USDC, §6.3) with **every loan
  performing**. The danger is a junior **run** that depegs zipUSD; because the at-risk equity is **committed in the
  sidecar** (utilization high → it isn't rotated back to the redeemable Safe) and depositors hold no raw Loot (Exit
  Gate custody, §6.4), the run's instant-exit escape hatch is **structurally closed** — no ragequit gate needed.
  - **Trigger:** an **on-chain utilization floor**. `U = borrowed / totalAssets` (readable from EulerEarn,
    §8.2; the §12 metric-4 early-warning) breaching a governed `U_lock` engages the lock automatically.
    Borrowing is controller-gated (§4.3), so `U` is not outsider-manipulable — it moves only via real
    originations and real redemption pressure. An optional CRE "secondaries-down" report (a new `reportType`,
    modeled on the §8.4 default/recovery report) may trip it **earlier**, but cannot un-trip a live on-chain
    breach.
  - **Sizing:** `lockFraction = maxLockFraction × clamp((U − U_lock) / (U_max − U_lock), 0, 1)` — anchored to
    utilization, the squeeze's stress variable (cf. trigger A's `atRisk/juniorNAV`).
  - **Stacking with (A):** a position's effective lock is `max(φ_A, φ_B)`, capped at `1.0` — the same shares
    serve the larger need; never summed. Each lock releases on its own condition; a governed `maxDuration`
    backstops both.
  - **Release:** auto-releases when free liquidity recovers — `U` falls below `U_lock − releaseHysteresis`
    (the hysteresis prevents flap).
  - **Compensation: none beyond the continuing yield.** The Duration Bond premium *is* the slashed xALPHA bond;
    a squeeze slashes nothing, so it pays **no premium** — and needs none: the loans are performing and
    accruing at the fixed credit-line rate (§3 IRM; §10 "the line simply accrues"), with the perf-fee routed
    to szipUSD elevated by high utilization (§5). The locked junior keeps earning (the "boosted-yield bond");
    §12 metric 3 displays this elevated while-locked APR. No protocol surplus is spent (it stays as the senior
    cushion, §2/§12) and no treasury xALPHA is spent (avoiding the §6.2/§7 peg reflexivity).
  - **Senior side:** no new mechanism — the epoch queue already fills pro-rata and carries the remainder
    forward (§6.1); the only senior lever is pacing new draws against pending redemptions (§6.3 / §8.2). The
    systemic lock is **junior-only** (it defends the peg by closing the junior's instant-exit path).

**Loss/recovery waterfall.** zipUSD is a fixed $1 claim; **szipUSD bears first loss** (its NAV = `basketNAV /
supply` via `SzipNavOracle`, §7 — the protocol holds surplus separately, §2/§12). On default the loss lands on the
junior first — the senior stays $1 until the junior is exhausted — via the **conservative provision** the
`DefaultCoordinator` writes into `SzipNavOracle` (§7/§11): a small markdown at recognition that **re-marks on
verified facts and writes back up**. **No share-escrow / `_burnSharesFromSusd3` / `finalizeLoss`** — the mark lives
in the oracle, not a pool-share move. The senior is backed by **junior NAV + the home's legal recovery + off-chain insurance
+ (last resort) xALPHA sold to cover a realized loss**; the Duration Bond premium is a separate **in-kind**
payment to the junior. zipUSD is insulated from xALPHA's price in normal operation (xALPHA is never sold to
defend the peg) and leans on it only in that rare last-resort capital-loss sale.

**Parameters (locked: governed + defaults).** The **recovery haircut** (default ≈ 0.65) and the **Duration
Bond length** (default ≈ 180 days) are governance-configurable, not hardcoded constants — recovery rates and
foreclosure timelines are empirical and vary by jurisdiction (§17). The dropped `HaircutLockAccountant`
(index/per-position lock) and `RecoveryClaimSBT` are not built — the socialized Duration Bond needs neither;
a transferable NPL-claim secondary market is a possible future feature, not a built component.

---

## 12. NAV / dashboard / solvency

**Backing NAV = idle USDC (cash/reserve) + outstanding loan value** — where each loan is marked at par
(performing) or **marked to recovery** (at the deviation event, §4.1) when impaired (equity mark × recovery haircut, §11). Do **not**
double-count: the lent-out USDC and the lien collateral securing it are two sides of one loan, so the
loan's *marked value* is the asset, not the cash plus the full home equity.

Solvency = **NAV ÷ zipUSD minted ≥ 1** (the senior peg). The **junior (szipUSD)** is the first-loss buffer.
On default the at-risk junior backing is **frozen from ragequit** (structural sidecar, §6.4/§11) so it stays
in place while time + the recovery waterfall (legal recovery → insurance → xALPHA bond → HYDX-vamped USDC)
bring **external** USDC to repay the loan — the dominant effect is **duration, not loss** (insured/
collateralized HELOC). A genuine shortfall is carried as a **pari-passu conservative provision-that-recovers**
written into **`SzipNavOracle`** (§7/§11): junior `navPerShare` marks down at recognition (small, because
recovery is high) and **writes back up on verified recovery**; the loss is borne **pari passu by every szipUSD
holder via the lower share price**, never by a per-holder share-burn, and only after the junior is exhausted is
the senior at risk.

**Junior NAV-per-share (`SzipNavOracle`) — the issuance/exit pricing primitive (§7), not display-only.** The
junior is a **transferable szipUSD share** the Exit Gate mints **NAV-proportionally** against soulbound Loot it
custodies over a **Baal/Moloch-v3 Safe basket** (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP, §4.5).
`SzipNavOracle` (`is ReceiverTemplate`, §7) computes `navPerShare = basketNAV / szipUSD.totalSupply()`
**on-chain**: it **reads all quantities on-chain** (balances across the main + sidecar Safes incl. the
**staked** ICHI LP), CRE-**pushes only** the off-chain leg prices it cannot read on Base (the xALPHA
`alphaUSD` leg; HYDX if thin), and maintains an **on-chain cumulative TWAP accumulator** (window `W ≈ 4h`,
§17). Issuance prices at `navEntry = max(spot, twap)`, exit at `navExit = min(spot, twap)` (protecting resident
holders both directions). The Gate's windowed ragequit pulls the basket pro-rata and pays each queued exiter at
**`navExit`** (partial-fill, §6.4) — **NAV is in the exit path**; the impatient alternative is selling szipUSD
on the CoW book (§6.2), which the protocol **never reads for accounting** (§7). The basket compounds off the
**HYDX vamp** (§4.5) — that growth, plus the duration-risk boost, is the junior's pay for the duration risk it
bears (the freeze keeps it "frozen but earning").

**Dashboard — five metrics:**
1. **Total protocol NAV** (cash + marked loan value).
2. **Total zipUSD minted** (utility-dollar supply) + **zipUSD peg vs USDC** (deviation = stress signal).
3. **szipUSD APR** (the headline yield = the **HYDX-vamp trailing-realized yield + the xALPHA subsidy**, §4.5)
   + the **junior `navPerShare`** (`SzipNavOracle`, §7 — the issuance/exit primitive, not display-only) + the
   **Duration Bond premium APR** on frozen positions.
4. **Utilization / free liquidity** — the duration-squeeze early warning.
5. **Insurance coverage** — the **xALPHA fund** in escrow (`LienXAlphaEscrow`, via the CRE xALPHA feed) + the
   **off-chain insurance** coverage (Proof of Insurance, §8.5).

Both pricing inputs feed this (§7): the **Proof of Value** equity mark → the zipUSD dollar NAV; the xALPHA
price feed → the **Duration Bond premium** NAV and the szipUSD bonus APR (metric 3). Off-chain insurance
coverage is attested separately (Proof of Insurance, §8.5), not via a price feed. All are required for
solvency reporting.

These metrics are aggregates over §9 events + pool state, served to the frontend via an off-chain indexer
(the subgraph workstream, `README.md` §4) — not computed per-request on-chain. The peg is the secondary-AMM
price (§6.2); off-chain insurance coverage is a CRE-published figure (§8.5).

---

## 13. Trust & security model

- **Trust-minimized:** **f+1 DON consensus** on every report — at launch the signer is a **standard
  Chainlink CRE DON** (Shape B, §7), with the Zipcode subnet becoming the DON as the endgame (Shape A);
  `ReceiverTemplate` workflow-identity check behind an **immutable Forwarder** (the base
  `setForwarderAddress` is non-virtual, so immutability is sealed by renouncing `Ownable` ownership after
  identity wiring, §4.4); the venue's
  **per-line price routers are minted and frozen at origination** (`transferGovernance(address(0))`, §4.1/§4.7
  — a line's price wiring can never be re-pointed, stronger than a timelock veto; the OZ `TimelockController`
  is retained for §17 **parameter** governance, not the routers); `CREGatingHook`
  restricts borrow and liquidate to controller-owned accounts via an EVC owner check (repay is permissionless
  — it only reduces debt); EVC controller + account-status checks.
- **Trusted (off-chain):** the lien's existence, value, and insurance are **attested by Proof**
  (`spv-lien-proof.md`) — but the SPV's **legal execution on recovery** (foreclosure / force-sale) and the
  **insurance carrier's payout** remain trusted legs; originator KYB; servicing/dollar leg
  (Erebor/Fireblocks). Secondaries-first sourcing reduces the recovery-confidence risk (we serve originators
  already feeding established takeout markets).
- **Junior / loss-side trust:** szipUSD bears first loss, realized via the explicit loss-application step
  (§11); capital shortfalls are covered first by **off-chain insurance**, with **xALPHA** as a last-resort
  backstop; the Duration Bond premium is paid **in-kind**, and xALPHA is **sold only as a last resort to cover
  a realized capital loss** after insurance (bounded, not peg defense — never reflexively dumped); zipUSD
  leans on xALPHA's price only in that rare sale; recovery-timing risk (the junior sits in a **Duration Bond**
  while recovery/insurance play out) is compensated by yield + the **xALPHA premium**.
- **Permissioned by design:** there is no permissionless market discovery — the controller is the sole
  governor (via the venue adapter), borrower-of-record, and funder, and originators are KYB'd — so no
  oracle/market "perspective" verification applies (a config stamp for strangers serves no party here; §17).
- **Key failure modes:** stale valuation (mitigated by **event-driven Proof re-marks** + a long validity
  window — and liquidation is delinquency-driven, so a stale/fake price alone cannot liquidate); proof
  spoofing (mitigated by zk verification + Proof notarization); governor/forwarder key compromise (mitigated
  by **per-line frozen price routers** + immutable Forwarder, and by making the controller the only privileged
  caller and minimizing its surface — note the borrow vault's **governor is deliberately retained** by the
  adapter to re-tune LTV/caps per report, so frozen-router immutability bounds the *price-routing* wire, **not**
  LTV/hook, which stay live behind the `onlyController` adapter). (No AVM model-bias risk — the value is a
  notarized appraisal, not a model output.)

---

## 14. Business context (compressed)

Three structures form one originate-to-distribute machine; **ONE is built first**, shaped so TWO/THREE
reuse the same collateral tokens, oracle, and venue-agnostic engine (§4.7):
- **ONE — Warehouse credit pool (built first):** xALPHA-incentivized USDC pool → credit lines to HELOC
  originators **already feeding established secondary takeout markets** (Figure / Saluda Grade), against
  pledged lien rights. "Warehouse" = the originator *relationship* (many per-lien lines under one
  counterparty), not co-mingled collateral — each line is an isolated per-home market (§17).
- **TWO — P2P matchmaker:** qualified lenders ↔ borrowers, one isolated market + oracle per loan.
- **THREE — Tokenized MBS (Securitize):** a standing takeout buyer of the loans. Near-term we plug into the
  **existing** secondaries (Figure / Saluda) as the takeout; THREE is **becoming our own** — closing ONE's
  capital loop and monetizing the per-home oracle network.

---

## 15. Proof-of-operations scope & acceptance

Vertical slice on **Base mainnet** (Euler venue, config one; deploy + test on mainnet — the Baal/Safe/Zodiac/ICHI/
Hydrex vault deps are 8453-only), one originator / one lien, with **mocked Proof inputs** (lien / value /
insurance) — collateral is mocked throughout until the Proof integrations + SPV partner are wired (§17).

**Milestone 1 — base loop + supply side.** The full loop runs tx-by-tx — underwrite (Proof gates) → mint
lien token → seed the **Proof-of-Value** mark in the registry → `venue.openLine`/`setLineLimits` (gated to
the controller) → `venue.fund` → `venue.draw` on the line's fresh borrower account (controller-as-operator; originator funded via Erebor)
→ permissionless repay → controller closes (burn) → `LienReleased`. The **real supply side** is wired: the
**zap** (deposit USDC → mint zipUSD → auto-stake szipUSD), the depositor return is the **xALPHA** subsidy (lending yield privatized protocol-side, §5/§17), and a
30-day epoch redemption settles. This is the fundable proof of operations.

**Milestone 2 — loss / default flow.** Exercises an engineered default: deviation Proof re-mark → `DefaultCoordinator`
**freezes the at-risk slice (sidecar) + writes a conservative provision into `SzipNavOracle`** → **Duration Bond** →
recovery (**foreclosure + insurance**, Proof-attested) → the **provision writes back up** (junior heals) → Duration
Bond release with the **xALPHA premium** (`slashXAlphaToCohort`; `slashXAlphaToCapital` first if a hole remains), or
the **provision settles permanently** (junior `navPerShare` carries the realized loss, pari passu) on a shortfall
after insurance + xALPHA. Split out because it needs an engineered default to demonstrate and carries the most surface.

---

## 16. Reference-repo map

| Repo (`reference/`) | What we use it for |
|---|---|
| `euler-earn` | the USDC credit pool + allocation surface + perf-fee yield routing |
| `euler-vault-kit` | isolated market (GenericFactory/EVault), hooks, IPriceOracle, IHookTarget, `ESynth` |
| `evk-periphery` | EdgeFactory wiring, BaseHookTarget, EulerRouterFactory, IRMs |
| `euler-price-oracle` | BaseAdapter, EulerRouter, ScaleUtils, RedstoneCoreOracle pattern |
| `ethereum-vault-connector` | EVC auth (operator, batch, onBehalfOf) |
| `cre-sdk-go`, `cre-cli` | **Go** CRE workflow authoring (compiles to `wasip1`) + deploy |
| `x402-cre-price-alerts` (Solidity `ReceiverTemplate`/`onReport`), `cre-sdk-go/standard_tests` (Go workflow patterns) | receiver contract + working CRE patterns |
| `erc7540-reference` (MIT) | async redeem base — **forked** for the redemption queue |
| `maple-withdrawal-manager` (BSL/GPL) | epoch + pro-rata **concept only** (clean-room) |
| `centrifuge-liquidity-pools` (AGPL) | epoch/pro-rata **concept only** (off-chain in upstream; no copy) |
| `moneymarket-contracts` (3Jane) | senior/junior waterfall, subordination **floor** (cap not used), xALPHA slash, settle — structural reference / concept only |
| `chainlink-datastreams-consumer`, `chainlink-evm` | Data Streams (optional transport, not required) |
| `cre-templates` | Go CRE workflow project layout / scaffold (build aid, §8.5) |
| `euler-interfaces` | EVK/EVC/oracle interface definitions (build aid) |
| `euler-lite` (Nuxt/Vue) | the frontend — forked + branded for zipcode; the convergence point for all teams (the demo + product UI) |
| `docs` | Base chain deployment specifics |

The Euler repos above are the **Euler venue adapter** surface (config one); a second venue (Aave, Morpho)
would add its own reference repos behind the `IZipcodeVenue` boundary (§4.7).

---

## 17. Open decisions & locked parameters

**Genuinely open (off-chain/integration, not Solidity blockers):**
- **SPV custody partner + Proof integrations** — the lien/value/insurance attestations are **addressed by
  Proof** (`spv-lien-proof.md`), but the SPV custody partner, the Proof-of-Insurance policy terms, and the
  CRE wiring of each Proof endpoint are still to pin. Collateral is mocked until they land (§15).
- **Shape A (subnet-as-DON)** — the endgame where the Zipcode subnet validators are the signing DON (vs the
  M1 Shape-B standard Chainlink DON); requires Chainlink provisioning, not M1-blocking (§7/§13).

**Named build-time parameters (governance-configurable, defaults documented):**

> **Change path (locked):** every governance-configurable parameter below — the subordination floor, the
> yield-split fee `f`, the junior cooldown length, the recovery haircut, and the Duration Bond length — is
> changed **through the OZ `TimelockController`** (≈2-day veto window, §4.4/§9), never via a bare EOA
> setter. The setter on each holding contract (`szipUSD`, `EE_POOL`, the IRM/market governor) is owned by
> the timelock (or the venue adapter behind it), so a parameter change inherits the same veto window as an
> oracle repoint.
- **`recoveryFloor`** — the day-one conservative provision floor on a default (`provision = atRisk × (1−floor)`).
  **HIGH** (the underlying is insured/collateralized HELOC → **duration-risk, not loss**, so the day-one markdown is
  small and writes back up on verified recovery); **underwriting-derived per originator/insurance terms**, not a
  single protocol number. **Duration Bond length** (default ≈ 180d) — §11. *(Supersedes "recovery haircut ≈ 0.65".)*
- **`W` — the NAV TWAP window = 4h** (locked 2026-06-07), fixed, decoupled from harvest; plus the `SzipNavOracle`
  ops guards (`maxAge` staleness, `maxDeviation` per-push circuit-break) — governed defaults — §7.
- **Perf-fee `f`** (venue perf-fee parameter — the lending yield it routes is **protocol-side**, **not** the
  junior's return; the depositor's return is the **xALPHA subsidy**, see Yield routing below) and the
  **subordination floor** (re-anchored to outstanding loan exposure; **no cap**) — §2/§5/§6.4.
- **Junior exit = liquidity windows** (ride the harvest cadence; **partial-fill-per-window**, remainder re-queued +
  still-accruing) — §6.4; **not** a fixed cooldown. The **coverage floor is the freeze itself** (structural, not a
  governed knob). *(Supersedes "≈30d sUSD3 cooldown".)*
- **Systemic-squeeze params** — `U_lock`, `U_max`, `maxLockFraction`, `maxDuration`, `releaseHysteresis`
  (the Duration Bond's liquidity-driven trigger B, §11); metric-4 utilization (§12) is the trigger input.
- **Junior accounting unit** *(two-token model, 2026-06-07)* — the junior is a **transferable szipUSD ERC-20
  share** the **Exit Gate** mints **NAV-proportionally** 1:1 against soulbound Baal Loot it holds, over a Baal Safe
  basket (zipUSD + xALPHA + the ICHI LP). **NAV (`SzipNavOracle`, §7) IS the issuance/exit pricing primitive** (not
  display-only). **Exit:** windowed ragequit at `min(spot,twap)` NAV (partial-fill) / CoW secondary (§6.4/§6.2).
  **Depositor return = NAV accretion** (HYDX-vamp free value recycled into the basket, 8-B10; lending fee → warehouse over-collateralization, future treasury). **First-loss = a pari-passu
  conservative provision-that-recovers** (§11): the freeze handles duration; a small conservative markdown is
  written at recognition and recovers on verified facts. Pari passu inside the junior; no subordination cap.
  Substrate = Baal + Zodiac (§4.5).
- **xALPHA bond sizing** — a first-loss percentage (target ~5–15%, warehouse-equity range), not 100% of lien value.
- **Always-liquid micro-reserve** — whether a small reserve sits outside the venue pool to smooth small
  redemptions between epochs.

**Resolved — the locked decisions (current state; items revised in the 2026-06-03 model rewrite are flagged):**
- **Cash-reserve ratio** → **fixed-%** (dynamic = later parameter swap), §8.2.
- **Redemption epoch** → **30 days, no mid-epoch cancel** (AMM is the early-exit path), §6.1.
- **Duration Bond + haircut** → governed params with defaults (≈180d / ≈0.65), §11. *(revised: "term-lock" →
  Duration Bond; trigger = default OR duration squeeze.)*
- **xALPHA mark** → **two-layer**: the LST **exchange rate** (`staked alpha ÷ supply`, stake accounting — no pool
  price) × **`alphaUSD`** (subnet TAO/alpha AMM **TWAP** × TAO/USD); only the `alphaUSD` market leg is TWAP'd +
  guarded, §7. *(Refines "CRE-reported feed, no DEX TWAP" — the value-bearing layer is stake accounting; the market
  leg is the subnet-AMM TWAP, not an Ethereum DEX.)*
- **Junior unit** → **transferable szipUSD share** the Exit Gate mints **NAV-proportionally** vs soulbound Loot;
  **windowed-RQ / CoW exits**; **NAV is the pricing primitive** (`SzipNavOracle`, §7); depositor return = HYDX-vamp
  + xALPHA subsidy (not lending yield); first-loss = **pari-passu provision-that-recovers** (§11). *(2026-06-07
  two-token model; supersedes the soulbound-claim / NAV-display-only / withhold-no-markdown phrasing; subordination
  cap removed; zipUSD = senior $1 utility, §2.)*
- **Surplus recovery** → above the debt → originator → homeowner; junior recovers to par + **xALPHA premium**;
  capital shortfalls covered by **insurance first, xALPHA last-resort**, §11. *(revised: insurance leg added.)*
- **Demo scope** → Milestone 1 base loop + supply side; Milestone 2 loss/default, §15.
- **Valuation + price path** → **event-driven Proof** (Proof of Value seeded at origination; re-marked on
  secondary acquisition / deviation), §4.1. *(revised: dropped the 1-day heartbeat, the Subnet 46 AVM, and the
  HPI band — valuation source is Proof, not a subnet model.)*
- **Perspectives** → **dropped entirely**; the protocol is permissioned end-to-end, so no
  oracle/market perspective verification (and `EulerUngovernedPerspective` is incompatible with our
  governed+hooked markets — it requires `governorAdmin==0`/`hookTarget==0`), §13. The `SnapshotRegistry`
  adapter-whitelist step is removed with it (`EulerRouter.govSetConfig` does not consult the registry).
- **Venue model** → **venue-agnostic engine**, Euler = configuration one (§4.7). *(new.)*
- **Underwriting fabric** → the **Zipcode Bittensor subnet** validators (zk-verify + the DON, Shape B for
  M1), §7. *(new.)*

**Resolved this validation pass (corrections from the section-by-section build review):**
- **Junior = Baal Loot on a Safe basket (flipped 2026-06-06; supersedes "share-backed convert-on-stake").**
  You deposit zipUSD → receive **Loot** (the szipUSD share); the **Gnosis Safe** holds the basket (zipUSD +
  xALPHA + the zipUSD/xALPHA ICHI LP); **exit = ragequit** (pro-rata, in-kind). There is **no convert-on-stake,
  no EulerEarn-pool-share custody, no single-numeraire redemption, no NAV-markdown.** **NAV is tracked from
  multiple oracles for display**, not in the exit path. The **lending yield is the protocol's** (privatized →
  treasury → xALPHA, §17); the depositor's return is the **HYDX-vamp yield + the xALPHA subsidy** (§4.5). The
  full prior bullet (EulerEarn pool shares / `stake`/`unstake` / `J×p`) is the deleted WOOF-07 model — see the
  §4.5 guardrail.
- **Per-line isolated markets with per-line frozen routers** *(revised — per-line-router design, this session;
  supersedes the earlier single-shared-router-fallback "F4")* — each line is its own isolated EVK market
  (escrow collateral vault + USDC borrow vault + a dedicated `EulerRouter`), minted and wired inside the venue
  adapter's `openLine` (§4.7) and **frozen** (`transferGovernance(address(0))`). The per-line router resolves
  `escrowVault → LIEN_i → ZipcodeOracleRegistry`, so origination still writes `cache[LIEN_i]` directly (oracle
  key unchanged, §4.1/§4.2) with **no per-lien `govSetConfig` on a shared/timelocked router** and **no timelock
  conflict** with the atomic origination batch (§4.1/§4.4a). Stronger than the old shared fallback: a line's
  price wiring can never be re-pointed.
- **Immutable Forwarder is enforced by the subclass** — the base `setForwarderAddress`/`onReport` are
  **non-virtual** (not overridable), so immutability is sealed by **renouncing `Ownable`** after identity
  wiring (assert `getExpectedWorkflowId() != 0` before renounce), §4.4; renounce neutralizes the otherwise
  owner-mutable setter.
- **Per-line price routers are immutable (frozen at origination), NOT timelock-governed** *(revised this
  session — supersedes "Router governor = OZ `TimelockController`")*: each line's `EulerRouter` is minted by
  the venue adapter, wired to the registry, and `transferGovernance(address(0))`-frozen inside `openLine`
  (§4.1/§4.7). The OZ `TimelockController` (delay ≈2d) is **retained for §17 parameter governance** (szipUSD
  floor / `f` / cooldown), **not** as a router governor (there is no shared router to govern).
- **Report ABI + `reportType` discriminator** defined for the controller branches / Go workflow (§4.4/§8).
- **Lien token** = fixed `1e18` supply at 18 decimals → borrow ≈ `equityMark × borrowLTV`; `LienTokenFactory`
  CREATE2 salt = `keccak256(lienId)` (§4.2).
- **Loss = a pari-passu conservative provision-that-recovers (2026-06-07; supersedes "withhold, no markdown").**
  The primary risk is **duration, not loss** (insured/collateralized HELOC), so a default is **freeze-dominant**: the
  committed slice is **already** frozen in the sidecar (structural, utilization-sized, owned by the Exit Gate, §6.4 —
  not engaged by the coordinator), and `DefaultCoordinator` writes a **small conservative provision** into
  `SzipNavOracle` at recognition (`recoveryFloor`
  HIGH, §7/§17) that **re-marks on a staircase of verified facts** (Proof-attested foreclosure milestones / realized
  receipts) and **writes back up**, trued-up at resolution. The waterfall (secondary → insurance → xALPHA bond →
  HYDX-vamped USDC) fills the hole; an unrecoverable residual is the marked loss (pari passu). `LienXAlphaEscrow`
  holds the xALPHA bond; the loss-side contracts (`DefaultCoordinator` / `LienXAlphaEscrow` + the **Foreclosure
  Proof oracle**) are **M2** (§11/§4.6).

**Resolved 2026-06-05 (supply-side redesign — user-directed + ratified):**
- **xALPHA — one token.** The liquid-staked Zipcode-subnet
  alpha (LST), bridged via CCIP (§2, `bridge/xalpha-bridge-impl.md`). One token does first-loss bond /
  Duration-Bond premium / szipUSD incentive / zipUSD-xALPHA POL leg / last-resort backstop (alpha→TAO→USDC) /
  treasury buyback target. (The M2-sketch loss-side names are now `LienXAlphaEscrow` / `slashXAlphaToCapital` /
  `slashXAlphaToCohort` / `lockXAlpha` / `releaseXAlpha`.)
- **szipUSD collapses sdVAULT into one token.** The junior is a single **freezable vault share** (named
  szipUSD); the Hydrex/oHYDX autocompounder is a **post-M1 yield-engine module** that bolts onto the same vault,
  not a second token (§4.5).
- **The Duration Bond freeze = a redemption-gate-with-boost, not a seizure.** Pro-rata share subset, accrues
  while frozen, objective DON-verified release; **zipUSD never freezes** (senior throttle = the epoch queue);
  credit loss = recovery waterfall (secondary → insurance → xALPHA-bond) → frozen-junior residual, **marked on a
  staircase of verified facts** (conservative provision at recognition → Proof-attested re-marks → true-up at
  resolution, §11); the boost + hole-plug are funded by the HYDX free-value stream (§6.4/§11/§4.5).
- **Yield routing — DECIDED: the real lending yield (EulerEarn APR + protocol fees) is the PROTOCOL's,
  privatized into a treasury strategy that buys xALPHA.** USDC/szipUSD depositors are **subsidized by xALPHA +
  the HYDX/USDC pool**, **not** by the lending yield — the underlying lending value + APR are privatized. The
  treasury strategy recycles that privatized yield into **buying xALPHA**, targeting **net-accretion**:
  eventually buying *more* xALPHA than is spent on incentives (the APR directed into the strategy was
  effectively the xALPHA the treasury spent to attract the USDC in the first place). **This resolves the old
  "f split"** — there is **no szipUSD "real base" from the lending yield**; the depositor's return is the
  xALPHA subsidy. **Implementation is flexible (user's call): the yield may live in the protocol-held shares and
  be resolved to the treasury at each credit-cycle end, OR accrue to the treasury directly — economically
  identical.** **M1 scope:** the protocol holds the yield-bearing lending shares; the szipUSD headline is the
  **seeded xALPHA emission** (`treasury.md` §4.1 budget); the **treasury buyback strategy that recycles the
  privatized yield is post-M1**. **Money-model note:** this supersedes the §2/§5/§12 "szipUSD NAV = its own EE
  fee-shares" framing *at the economic level* (depositor yield = xALPHA, not the fee-shares); for M1 the yield
  may still accrue in the protocol-held shares (so `audit/1-results.md` I1–I4 hold mechanically), but **I3–I4
  must be revisited when the treasury/buyback module is specced** (post-M1).

**Resolved 2026-06-05 (borrower-of-record rework — user-directed + ratified):**
- **Borrower of record = a fresh per-line EVC account + the controller wired as its operator (NOT a
  controller sub-account).** Each credit line gets its **own** fresh EVC account (own owner-prefix), deployed
  by the venue adapter inside `openLine` as a minimal CREATE2 `LineAccount` that grants the controller the EVC
  **operator** bit over a code-free borrow account; the controller drives every borrow on-behalf (§4.4/§4.7).
  **This removes the 256/255 cap** (the old scheme borrowed on the controller's own sub-accounts 1…255 — a
  hard ceiling) → the protocol hosts **unbounded concurrent lines**. The whole per-loan cluster (borrower
  account + USDC debt vault + escrow collateral vault + lien token + per-line oracle/router) is **fully
  disposable** — abandoned at close; the on-chain "graveyard" of dead clusters is **explicitly accepted**
  (zero ongoing cost, preferred to sub-account reuse or a 255 cap). *(supersedes the prior "controller
  sub-account *i* ↔ market *i*" / blanket `setOperator(prefix, venue, ~uint256(1))` / 255-line-ceiling framing
  — all dissolved; the new model is strictly **more** isolated: one operator grant per line over one account
  on its own prefix, no shared sub-account space.)*
- **Gating hook = operator-authorization, not owner-commonality.** Because each line's borrower has a distinct
  prefix, `CREGatingHook` gates borrow/liquidate on `EVC.isAccountOperatorAuthorized(borrowAccount,
  borrowDriver)` (`EthereumVaultConnector.sol:286`), **not** `haveCommonOwner(caller, controller)` (§4.3). The
  granted operator and the hook's gate are the **same** address — the one that actually makes the `EVC.call`,
  i.e. the **`EulerVenueAdapter`** (the controller drives the borrow through `IZipcodeVenue.draw`, so the EVC
  authenticates the adapter); in M1 the adapter may be collapsed into the controller (§4.4/§4.7), in which case
  they are one address. So the line's `LineAccount` grants the adapter, and the hook's `borrowDriver` immutable is
  wired to the adapter. *(supersedes the resolved-this-pass "Hook gating uses an EVC owner check" line — correct
  for the sub-account model, now retired.)*

**Previously resolved (design):**
- **Collateral granularity** → **per-lien singles** by default (one isolated market per home; no cap on
  the number of lines); an opt-in **bundle** (one market, custom oracle = Σ of per-lien marks) is offered
  only when the originator asks and the bundle exits together. Risk is the home's lien; the originator is
  the underwritten counterparty.
- **Senior/junior mechanics** → zipUSD $1 utility (1:1 mint) + szipUSD junior (the main product, via the
  zap); depositor return = **xALPHA** (lending yield privatized protocol-side, §5/§17); loss via **event-driven Proof markdown + Duration Bond +
  insurance** (§11).
- xALPHA liquidity-mining/incentive module (rewards distributor) — later part of the one pathway.

---

## 18. Glossary

**EVK** Euler Vault Kit · **EVC** Ethereum Vault Connector · **EulerEarn** ERC-4626 meta-vault (the venue
pool, config one) · **IPriceOracle** EVK pull oracle interface · **HookTarget** EVK operation hook · **CRE**
Chainlink Runtime Environment · **DON** Decentralized Oracle Network · **KeystoneForwarder** contract that
verifies DON sigs and calls receivers · **Shape B / Shape A** M1 signer = standard Chainlink DON / endgame =
the subnet validators as the DON (§7) · **Zipcode subnet** our Bittensor subnet — the validator/DON fabric
(containers fetch + zk-verify + consensus on underwriting inputs); **not** an appraiser · **Proof**
notarization service over the SPV documents; the **Proof family** = **Proof of Lien** (perfected + ownership),
**Proof of Value** (origination appraisal → equity mark), **Proof of Insurance** (policy covers the position)
· **Reclaim** a zkTLS proof mechanism for off-chain API responses · **HELOC** home-equity line of credit ·
**OTD** originate-to-distribute · **secondary takeout market** an existing buyer of the loans (Figure, Saluda
Grade) · **warehouse** revolving line against pledged receivables/liens · **LTV** loan-to-value · **venue
adapter / `IZipcodeVenue`** the boundary that makes the engine venue-agnostic (Euler = config one;
§4.7) · **zipUSD** $1 utility credit dollar (1:1 mint) — exit hatch from szipUSD + composable
lending asset; **never freezes** · **szipUSD** the **freezable junior vault share**, the main product (the
**zap** target); **`sdVAULT` collapses into it** (one junior token); depositor return = **xALPHA** subsidy
(the lending yield is the protocol's, §5/§17); staked zipUSD = subordinated principal; bears **residual** first loss; frozen-but-accruing during
a Duration Bond · **sdVAULT** the **post-M1 Hydrex/oHYDX yield-engine module** that bolts onto the szipUSD
vault (zipUSD/xALPHA ICHI LP + CRE oHYDX autocompounder; `auto-sodomizer.md`) — **not a separate token** · **zap**
deposit → mint zipUSD → auto-stake szipUSD in one tx · **zipCRED** a future RWA token (tokenized credit) ·
**xALPHA** — the **one** liquid-staked Zipcode-subnet alpha (LST), bridged via CCIP
(`bridge/xalpha-bridge-impl.md`): per-lien first-loss bond + Duration-Bond premium + szipUSD incentive +
zipUSD/xALPHA POL leg + last-resort backstop (alpha→TAO→USDC) + treasury buyback target · **markdown**
event-driven recovery-aware debt-value haircut (`debt − equity
mark × haircut`; set at the deviation Proof re-mark, not continuous, not time-linear) · **settle** write-off
of unrecoverable debt on a recovery shortfall (after insurance + xALPHA) · **Duration Bond** the lock mechanism:
a fixed pro-rata fraction of every junior position locks for a fixed term at an elevated APR and resolves with
the xALPHA premium; fires on **default OR a duration squeeze** — no per-position index or claim token · **NPL**
non-performing loan (a transferable recovery-claim market is a possible future feature, not built).

---

## 19. Explicitly NOT using

- **`PegStabilityModule`** (instant 1:1 swap peg) — replaced by `ZipDepositModule` (1:1 mint) + the epoch
  queue. The PSM has no queue (it reverts when its reserve is short), which doesn't fit lent-out cash.
- **`EulerSavingsRate`** (gulp / 2-week smear) — replaced by EulerEarn's native perf-fee routing (§5).
- **3Jane `UserCooldown`** — dropped **for the senior (zipUSD) redemption only**, replaced by the 7540 +
  epoch queue (par, pro-rata, §6.1). The **junior (szipUSD) exit deliberately *does* use the `sUSD3`-style
  per-staker cooldown** (§6.4) — it is not dropped there; the senior's pro-rata-par logic doesn't fit
  first-loss capital, and the cooldown's run-deterrence does.
- **`MarkdownController.calculateMarkdown`** (time-linear unsecured decay) — replaced by the event-driven
  recovery-aware markdown (§11).
- **Subnet 46 as a home-pricing AVM + the HPI sanity band** — not used; valuation is the **Proof of Value**
  notarized appraisal (§4.1), and the Zipcode subnet is the validation/DON fabric, not an appraiser.
- **`EulerUngovernedPerspective` / `SnapshotRegistry` adapter whitelist** — the protocol is permissioned;
  no permissionless market discovery means no perspective verification, and the router does not consult
  the registry (§13/§17).
- **Centrifuge code** (`centrifuge-liquidity-pools`, AGPL) — its epoch/pro-rata is off-chain anyway;
  concepts only, no copy.
- **Maple code** (`maple-withdrawal-manager`, BSL → GPL, copyleft) — clean-room reimplementation of the
  pro-rata idea only; no copied code.
- **3Jane `moneymarket-contracts`** (AGPL) — structural reference / concept only; no copied code.

Only the **MIT** `erc7540-reference` is forked directly; all other external repos are concept-only.

---

*Plain-language narrative: [`vision.md`](./pending-docs/vision.md). Build plan / per-team task map: [`README.md`](./README.md).
Off-chain leg (SPV custody + Proof attestation): [`spv-lien-proof.md`](./pending-docs/spv-lien-proof.md). The venue-agnostic
boundary is §4.7.*
