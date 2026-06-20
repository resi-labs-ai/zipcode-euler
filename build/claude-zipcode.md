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
   │ (USDC → EulerEarn) │            │($1 utility)│           │ junior /        │
   └─────────┬──────────┘            └────────────┘           │ first loss      │
             │ deposit USDC                                  └────────┬────────┘
             ▼                                                        │ perf fee → warehouse (senior)
   ┌───────────────────────┐        allocator role (via EVC)          │
   │  EulerEarn USDC pool   │◀───────────────────────────────┐        │
   │  (credit pool)         │── setFeeRecipient(warehouse) ───┼────────┘
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
| **zipUSD** | The **$1 utility dollar** — minted 1:1 on USDC deposit, redeemed for USDC (on-demand par queue, §6.1) or sold (secondary, §6.2). The protocol's dollar plumbing: the **exit hatch** out of szipUSD and a composable USDC-pegged asset other markets can lend against (vs szipUSD, a future **zipCRED** RWA, or other RWAs) — not an investment tranche. Mechanically still **insulated from loss until the junior is exhausted** (loss waterfall, §11). | mintable/burnable ERC-20 (`ESynth`) |
| **szipUSD** | The junior, **the main product** — a **transferable ERC-20 share** (18-dp) over a **Baal/Moloch-v3 Gnosis Safe basket** (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex, §4.5). The **Exit Gate** mints szipUSD **1:1 against soulbound Baal Loot it custodies** — Loot is the ragequit-bearing layer, held + ragequitted **only** by the gate (no raw-ragequit footgun), while the user share is **freely transferable**. Deposit → **NAV-proportional** szipUSD (`shares = value / navEntry`, priced via `SzipNavOracle`, §7). **Exit:** **sell szipUSD on the CoW book** (§6.4/§6.2) — NAV-discovery priced (treasury discounted buyer-of-last-resort + external buyers; no windowed ragequit). Duration-Bond **freeze structural via the juniorTrancheSidecar** (§6.4/§11). **Depositor return = NAV accretion** — the HYDX-vamp free value is recycled into the basket (8-B10) lifting NAV-per-share weekly, realized on exit at NAV (+ the Duration-Bond premium + any post-M1 xALPHA emission incentive). (Real lending APR/fees are the **protocol's** → they over-collateralize zipUSD in the `CreditWarehouse` now; future treasury buybacks, §17.) **NAV is the issuance/exit pricing primitive** (`SzipNavOracle`, §7/§12). Bears **residual** first loss as a **pari-passu conservative provision-that-recovers** (§11): a default is **freeze-dominant** (duration-risk — insured/collateralized HELOC), the day-one markdown is small and writes back up on verified recovery. | transferable ERC-20 share; gate mints 1:1 vs soulbound Loot; NAV-priced; CoW-book exit |
| **xALPHA** | **ONE token — the liquid-staked Zipcode-subnet alpha (LST), bridged to Base via CCIP** (`build/wires/8x-01-szALPHA-bridge.md`). It does **six jobs**: per-lien **first-loss bond** (protocol-posted at launch, originators self-fund via OTC as they scale, §4.6); the **Duration-Bond premium** (in-kind, priced via the CRE feed, never market-sold, §11); the **szipUSD incentive emission** (post-M1); the **zipUSD/xALPHA POL pair leg** (post-M1, §4.5); a **last-resort capital backstop** — liquidated **alpha → TAO → USDC on Bittensor** to cover a realized loss after insurance (§11); and the **treasury buyback target** (real USDC lending yield → buy xALPHA, the closed loop — post-M1, §17). Yield-bearing because it is the LST. | external ERC-20 — the bridged subnet LST (xALPHA) |

The peg is **"minted 1:1,"** not a NAV. zipUSD stays $1; the pool's growth accrues to `szipUSD`, and any
retained growth is surplus NAV over the zipUSD supply (an over-collateralization cushion held by the
protocol). zipUSD is solvent while backing NAV ≥ zipUSD supply (§12). 3Jane mapping (mechanical, loss-
waterfall only — zipUSD is a utility dollar, not an investment tranche): zipUSD plays the `USD3`
senior-claim role, szipUSD the `sUSD3` first-loss role.

**Junior accounting unit (Baal two-token model, 2026-06-07; see the §4.5 / §6.4 substrate).** You deposit USDC
(the zap) → receive **transferable szipUSD** (an ERC-20 share), minted **NAV-proportionally** by the Exit Gate,
which custodies the soulbound **Loot** (the ragequit-bearing layer) 1:1 against your share. A **Gnosis Safe** (+ a
non-ragequittable **juniorTrancheSidecar**) holds the junior basket (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP). **Exit:**
**exit** = sell szipUSD on the **CoW book** (§6.4/§6.2), NAV-discovery priced — the treasury is the discounted
buyer-of-last-resort (buys `≤ navExit×(1−d)`, burns) and external buyers fill the same book (no windowed ragequit).
**NAV (`SzipNavOracle`, §7) is the pricing primitive** — issuance is NAV-proportional, exit is at
`min(spot, twap)`. **The depositor's return is the HYDX-vamp yield + the xALPHA subsidy** (§4.5/§5/§17), not the
lending yield (which is the protocol's → treasury). **First-loss is a pari-passu conservative provision-that-recovers
(§11):** on default the at-risk equity **freezes** (juniorTrancheSidecar; keeps earning) while the recovery waterfall runs; a
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
| CRE inbound | `ReceiverTemplate :: onReport(metadata, report) (:78) → _processReport (:119)`; `_decodeMetadata → (workflowId, workflowName, workflowOwner)`; gated on the CRE Forwarder (`s_forwarderAddress`, set at construction `:48`). **As-built correction (supersedes the earlier "immutable / we drop the setter" framing):** `ReceiverTemplate is Ownable`, and the setter is **RETAINED** — `setForwarderAddress`/`setExpectedAuthor`/`setExpectedWorkflowId` are all `onlyOwner`, so the Forwarder + the workflow identity are **Timelock-mutable** in the build phase per §17 (re-pointable in an emergency; immutability is the deferred pre-prod lock-down). A zero Forwarder still makes `onReport` permissionless `:82-85`. (So `SzAlphaRateOracle` and every other `ReceiverTemplate` HAS an owner; only the economic knobs are immutable.) | `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` |
| Data Streams (optional transport) | `VerifierProxy :: verify` (state-changing, charges LINK/native fee via `FeeManager`), RWA report v4/v8. Not required: the regional HPI bound arrives as a CRE HTTP input (§4.1/§8.10), not via DS | `reference/chainlink-evm/contracts/src/v0.8/llo-feeds/v0.5.1/VerifierProxy.sol` |
| IRM | set via `setInterestRateModel`. **Uses a flat/fixed rate** — `IRMLinearKink(baseRate, 0, 0, kink)` (`baseRate` immutable line 14; the two slope args 0 → constant APR; constructor line 22 — a negotiated credit-line rate, not utilization-floating) | `reference/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol`, `reference/evk-periphery/src` (IRM) |
| Async redeem base | `BaseERC7540 is ERC4626, Owned, IERC7540Operator` (`:12`, `setOperator :34`), `ControlledAsyncRedeem` (`requestRedeem :39`, `fulfillRedeem onlyOwner :65`, pending/claimable `:22-32`) | `reference/erc7540-reference/src/{BaseERC7540,ControlledAsyncRedeem}.sol` (**MIT — fork**) |
| Epoch + pro-rata (concept) | `MapleWithdrawalManager :: getRedeemableAmounts` (`:367-387`, `redeemable = locked × available/totalRequested`), carry-forward (`:262-271`) | `reference/maple-withdrawal-manager/contracts/MapleWithdrawalManager.sol` (**BSL/GPL — clean-room concept only**) |
| Senior/junior loss waterfall | `USD3 :: _postReportHook (:502) / _burnSharesFromSusd3 (:567)` (junior absorbs first loss; senior protected first — **concept only**: our junior NAV = `basketNAV/supply` via `SzipNavOracle` §7, and first-loss is a recoverable **provision** that lowers the junior NAV per share, **not** a share-burn, §11) | `reference/moneymarket-contracts/src/usd3/USD3.sol` (AGPL — concept only) |
| Subordination **floor** (model; cap NOT used) | `sUSD3 :: availableWithdrawLimit (:277, floor)` — kept but **re-anchored to outstanding loan exposure** (§2/§6.4); the **cap** (`availableDepositLimit :249` / `maxSubordinationRatio :408`) is **not used** (junior is the dominant capital, §2) | `reference/moneymarket-contracts/src/usd3/sUSD3.sol` (AGPL — concept only) |
| Junior exit (CoW book + gate-internal burn) | depositors hold **no raw Loot** (the gate is sole Loot-holder, so raw `ragequit` is impossible); exit = a **resting CoW sell order** filled by the treasury's 8-B14 buy-and-burn or an external buyer → `ExitGate.burnFor` (gate-internal `burnLoot`, pure supply reduction) — the junior exit (§6.4); **replaces** the old `sUSD3` cooldown + the in-kind-ragequit/lock-shaman model | `reference/Baal/contracts/Baal.sol` (`burnLoot`; `ragequit` `:619` unused by depositors) |
| **Duration Bond** (freeze) | the `DurationFreezeModule` **debt-pinned coverage floor** (§11): `requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`, checked against `coverageValue = committedValue(juniorTrancheSidecar) + pathLockedLpEquity` — the staked LP is counted **in place**, not moved, so the juniorTrancheSidecar is empty in normal operation. `covered()` gates the real outflows (`SzipBuyBurnModule.postBid`, `LpStrategyModule.removeLiquidity`); the physical `commit`/`release` (main↔juniorTrancheSidecar) is the dormant exception-only lever. | net-new (`DurationFreezeModule`; `DefaultCoordinator` only writes the NAV markdown + runs the xALPHA recovery waterfall, §4.6) |
| xALPHA bond slash (capital + in-kind premium) | **NOT a proportional slash** — `slashXAlphaToCapital`/`slashXAlphaToCohort` are dumb routers; the capital-vs-premium split is computed off-chain by `DefaultCoordinator` and passed in (`MarkdownController :: slashJaneProportional (:146)` was the concept template, **rejected** — see §4.6 / `LienXAlphaEscrow`) | `reference/moneymarket-contracts/src/MarkdownController.sol` (concept only — not the as-built model) |
| xALPHA escrow custody | `InsuranceFund :: bring (:33)` — the single-immutable-caller + gated-`safeTransfer` model, as built in `LienXAlphaEscrow` (§4.6) | `reference/moneymarket-contracts/src/InsuranceFund.sol` (concept only) |
| Pro-rata premium to the cohort | **NO distributor built** — `slashXAlphaToCohort` routes the premium to the **main/engine Safe** (CTR-11; was the juniorTrancheSidecar) so the existing flywheel sells it for zipUSD and folds it into the basket; the socialized pro-rata stays automatic via NAV ("no per-position index, no SBT", §4.6/§11). `RewardsDistributor`/SBT distributors **not built**. | `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol` (concept only — superseded by route-to-main-Safe + flywheel) |
| Settle / write-off (recovery shortfall) | `MorphoCredit :: settleAccount (:834) / _applySettlement (:874)` | `reference/moneymarket-contracts/src/MorphoCredit.sol` (concept only) |
| Delinquency state machine (lock trigger) | `MorphoCredit :: getRepaymentStatus (:526)` (Current/Grace/Delinquent/Default) | `reference/moneymarket-contracts/src/MorphoCredit.sol` (concept only) |
| CRE schedule | Go CRE `cron.Trigger` (`capabilities/scheduler/cron/trigger_sdk_gen.go:16`) + controller as privileged caller | `reference/cre-sdk-go` |

Note: `MarkdownController.calculateMarkdown (:91)` (time-linear unsecured decay, `:110`) **exists but is
deliberately not used** — our markdown is recovery-aware and continuous (§11), not time-linear.

---

## 4. Net-new contracts

> **The contracts formerly specified in detail here (§4.1–§4.7) are BUILT and fork-tested.** Their
> authoritative, code-derived specification is now the wiring map under `build/wires/` (index:
> `build/wires/COVERAGE.md`) — one doc per contract, read straight from `contracts/src/...`. The full
> pre-build design that lived in this section has been retired to remove the now-vs-then maintenance burden.
> **For anything bindable — constructor args, signatures, wiring, authority — `wires/` + `contracts/` are the
> truth, and the code wins on any conflict.** Other sections still reference `§4.x` for these contracts; read
> those pointers as "see the wires doc below."
>
> | Former § | Contract(s) | wires doc |
> |---|---|---|
> | §4.1 | `ZipcodeOracleRegistry` | `WOOF-02.md` |
> | §4.2 | `LienCollateralToken` + `LienTokenFactory` | `WOOF-01.md` |
> | §4.3 | `CREGatingHook` | `WOOF-03.md` |
> | §4.4 | `ZipcodeController` (report ABI also in §8.0) | `WOOF-05.md` |
> | §4.5 | supply-side szipUSD vault + Exit Gate + engine (incl. former §4.5.1 module specs) | `ExitGate-szipUSD.md`, `8-B4-SzipNavOracle.md`, `8-B5..8-B14`, `8-Bw-CreditWarehouse.md`, `9-ZipRedemptionQueue.md`, `OffRampModule.md`, `DurationFreezeModule.md` |
> | §4.6 | loss-side | `8-Bx-LienXAlphaEscrow.md`, `DefaultCoordinator.md` |
> | §4.7 | `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount` (venue boundary) | `WOOF-04.md` |
>
> The forward (unbuilt) intent that referenced these contracts lives in §5 (supply UX), §8 (CRE workflows),
> §11 (loss policy), §12 (dashboard), §17 (locked decisions).
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
`feeShares` to the recipient (`_mint(feeRecipient, feeShares)`, `:889`). **Resolved (§17):** the recipient is the
**warehouse Safe** (`DeployLocal.s.sol:136`) — the senior EE-share custodian — so the perf-fee accrues to senior
backing (raising the over-collateralization cushion above zipUSD), never to szipUSD. Mechanically this is the same
performance-fee mechanism 3Jane uses with `USD3`/`sUSD3` — but here the accrued fee-shares are the
**protocol's privatized yield** (the real lending APR + fees), held protocol-side and resolved to the
**treasury, which recycles them into buying xALPHA** (§17 yield routing); they are **not** the depositor's
return. **The szipUSD depositor's return is the xALPHA subsidy** (+ the HYDX/USDC pool + the Duration-Bond
premium). zipUSD itself stays flat $1 (a fixed claim, not a share). The perf-fee `f` and the subordination
**floor** (no cap, §2) are governance-configurable build-time parameters (§17). (`feeRecipient` = the warehouse
Safe for M1, §17.) **Venue note:** this perf-fee
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

**Per-revolution draw fee (BUILT — CTR-09; distinct from the perf-fee above).** Separate from the EulerEarn
NAV-yield perf-fee, the protocol levies a **volume-based origination fee on every draw**: `EulerVenueAdapter.draw`
appends a fourth EVC borrow leg `borrow(fee, feeRecipient)` where `fee = amount * feeBps / 10_000`
(`feeBps` defaults 0.50% = 50 bps — a market-standard per-origination fee, dartboard-calibrated against bank
warehouse lines (SOFR+2.25–3.25%) and Maple's 0.5%; Timelock-settable, capped at 5%). It is the only on-chain-enforceable levy point —
the controller holds no USDC and drawn USDC crosses to the off-chain Erebor rail immediately. The fee is **financed
by the line** (debt becomes `amount + fee`, repaid with the principal) and credits a Timelock-set `feeRecipient`
(the protocol treasury). Because it re-fires on **every** draw, a revolving structure-2 line (CTR-08) pays it per
revolution — this is the per-revolution revenue the model assumes. **Default OFF** (`feeRecipient == address(0)`)
until wired at deploy. Draw-only (close is a full repay → burn, no draw leg to levy on).

**Line APR (BUILT — CTR-13; the time-based rate, distinct from the per-draw fee above).** The per-line borrow
vaults run a real **flat ~7.5%-APR IRM** (`IRMLinearKink`, `slope1=slope2=0`, `kink=type(uint32).max`), wired into
the `EulerVenueAdapter.irm` slot (`LineIrm`, `baseRate = 0.075·1e27 / SECONDS_PER_YEAR` per-second RAY, anchored to
bank warehouse lines SOFR+2.25–3.25% and ≤ the consumer HELOC so the originator's gain-on-sale survives). A flat
rate fits the single-borrower isolated line (~binary utilization). EVK compounds per-second, so the effective APY
is marginally above nominal (~7.788% = e^0.075−1). Every `openLine` installs it; the slot is **Timelock-settable**
(§17). The **reservoir** borrow vault stays on `ZeroIRM` (internal POL, §4.5.1 — charging the protocol itself is
pointless) — the adapter `irm` slot and the reservoir IRM are independent. The net interest accrues to the
warehouse Safe (the **sole senior EE-share custodian**) as over-collateralization cushion via share appreciation;
the EulerEarn perf-fee `f` stays **dormant at 0** (recipient pre-wired) — a non-zero `f` would only mint fee-shares
to the entity that already owns the pool (a no-op until external senior LPs ever deposit, post-M1). Pre-CTR-13 /
pre-swap lines roll off at the next quarterly revolution and the redrawn line gets the real rate (no forced
re-price). Borrower all-in per revolution ≈ `APR × (sit/12) + feeBps`. Truth: `docs/wires/WOOF-04.md`.

---

## 6. Redemption & exit (senior vs junior)

zipUSD (the **$1 utility dollar**) and szipUSD (the **junior**, the main product) leave by different
mechanisms, because they are different instruments. zipUSD is a $1 hard claim where many holders compete for
limited cash → a **par-burn queue** (treasury-internal, §6.1). szipUSD is share-backed, NAV-floating, first-loss
capital → the **Exit Gate** (Loot-custody) + the **CoW book** (a resting sell order *is* the queue; the treasury
fills it just-in-time via buy-and-burn, §6.4), which fits the floating NAV, removes the raw-ragequit footgun, and
deters runs. Both ultimately hit the same liquidity ceiling: you can only get out as much USDC/value as the pool
can free (§6.3).

### 6.1 Par-burn sink (primary, zipUSD) — `ZipRedemptionQueue`
> **As-built (2026-06-13):** this began as a 30-day epoch queue with pro-rata partial fills, but the time gate
> (2026-06-12) and then the pro-rata / `era` / `cumRemaining` engine + 7540 operator surface (2026-06-13) were
> removed. `requestRedeem` is gated to a **single requester** (the rq Safe), so pro-rata computed a fraction over a
> set of size one. What remains is a **par-burn sink**: escrow → `min(available, pending)` fill + burn → claim at
> par. Par redemption is **treasury-internal plumbing** — it converts the rq Safe's idle basket zipUSD into the USDC
> that funds the CoW buy-burn bid; a real holder never redeems here (see
> `build/wires/9-ZipRedemptionQueue.md` + `8-B14-SzipBuyBurnModule.md`). The prose below is retained as design history.

The USDC backing zipUSD is lent out to illiquid lien markets, so par redemption fills only as far as the pool can
free cash. Lifecycle (`requestRedeem → settleEpoch → withdraw`/`redeem`):

- A redeemer (the rq Safe) calls `requestRedeem(zipUSD)`; the zipUSD is escrowed. Redemption is at **par to 6-dp
  USDC**, so a request must be a **whole USDC-unit** of zipUSD (`amount % 1e12 == 0`); an odd balance redeems the
  whole-unit floor and keeps/sells the sub-unit remainder on the AMM (§6.2).
- `settleEpoch()` (controller-only, on-demand): read the queue's **own** free USDC balance (`balanceOf(this) −
  reservedAssets`) — the cash the warehouse **REDEEM → REPAY** already delivered (§8.5); the queue calls EulerEarn
  **never** (it is the non-sweepable REPAY sink). Fill `min(available, pending)` at par, burn the filled zipUSD
  (own-balance burn — no allowance/capacity), bank the USDC as `claimable`. The unfilled remainder stays pending
  for the next settle.
- **Trigger:** `settleEpoch()` is called by the controller via a Go CRE `cron.Trigger` (§8) after the REDEEM/REPAY.
- Claiming is a separate `withdraw`/`redeem` against the `claimable` balance.

### 6.2 Instant secondary (market)
Sell zipUSD into a **zipUSD/USDC** AMM at the market price for an immediate exit (below par when the
queue is backed up; arbitrageurs who will wait the queue buy the dip). The queue is the at-par path; the
AMM is the fast path. **zipUSD's primary peg-liquidity (the par-burn queue + a zipUSD/USDC AMM) is kept
independent of xALPHA** (the reflexivity finding) — zipUSD's exit must not depend on xALPHA's depth. The
post-M1 **zipUSD/xALPHA POL** (the engine's LP, §4.5) is the *yield/incentive* venue, deliberately
**off-center** from zipUSD's primary exit, so an xALPHA crash cannot crater zipUSD's redemption path.

**Junior secondary (szipUSD).** Because szipUSD is a **transferable** ERC-20 share, the *impatient* junior exit
(§6.4) is **selling szipUSD/USDC on a CoW order book** — instant, peer-funded, no basket touched, the market pricing
the duration/impairment risk. This is a **separate book from the senior zipUSD/USDC AMM above** — different
instrument, do not conflate. The protocol's **8-B14 buy-and-burn** posts discounted standing bids (engine USDC,
below NAV) and burns the szipUSD it fills (§4.5.1).

### 6.3 The real constraint: redemption vs. draw contention
`settleEpoch()` can only fill up to the USDC the warehouse can free at that moment (via **REDEEM → REPAY**,
§6.1/§8.5), which depends on the EulerEarn pool's liquidity / the lien markets having repaid. **Redemptions
compete with new draws for that free cash.** That
contention — not the queue mechanics — is the binding limiter (and the same contention a **duration squeeze**
stresses, §11), and it is why par redemption is queued rather than instant. Policy levers: the **cash-reserve ratio** (§8.2) and pacing
draws against pending redemptions. This contention is exactly what the **systemic Duration Bond (§11 trigger
B)** defends against — a utilization breach engages the junior lock to prevent a run.

### 6.4 Junior exit (szipUSD) — the Exit Gate (custody) + the CoW book
The junior does **not** use the at-par redemption queue (that is zipUSD's mechanism) and does **not** expose raw Baal
`ragequit` to depositors. Baal `ragequit` is permissionless on the **Loot-holder** and **cannot be paused**
(`reference/Baal/contracts/Baal.sol:619`; pause blocks transfers, not ragequit) — so the only way to gate it is to
keep depositors from ever **holding** raw Loot. The szipUSD vault therefore exits through an **Exit Gate** — the
canonical Loot custodian of the **two-token model** (soulbound gate-held Loot + a transferable szipUSD share;
supersedes the old `sUSD3` cooldown + soulbound-claim model, which assumed a ragequit gate Baal does not have):

1. **Custody + issuance (this is what removes the footgun).** On deposit, the Gate (which holds Baal `manager`,
   absorbing the old mint shaman) mints **Loot to itself** (mint bypasses the Loot pause — `LootERC20` allows
   `from==0`) and mints the depositor **transferable szipUSD**, **NAV-proportional** (`shares = value / navEntry`
   via `SzipNavOracle`, §7; round-down, staleness-guarded). The **soulbound property is on the internal Loot** —
   the gate is the sole Loot-holder and thus the sole ragequit caller, so it controls *when* exits happen — **not**
   on the user share, which is a freely transferable ERC-20. So no depositor can call `ragequit`, yet szipUSD trades
   on the CoW book (§6.2). (The gate keeps `szipUSD.totalSupply() == its Loot balance`.)
2. **The CoW book is the queue.** To leave, a holder rests a **CoW sell order** for their szipUSD at their own
   limit — that resting order *is* their place in the queue; only their own token rests (no parked protocol
   capital, no on-chain escrow window).
3. **Fill = the CoW book (treasury just-in-time + external buyers).** A resting sell order is filled by either
   the **protocol treasury** — which posts a *transient, just-in-time* CoW `BUY szipUSD` bid (**8-B14**, priced
   `≤ navExit × (1 − d)`, **never above NAV** — paying above NAV would rob stayers), funded by the back-office
   **zipUSD → USDC off-ramp** (basket zipUSD redeemed at par via `ZipRedemptionQueue`, §6.1) — **or** by **external
   buyers** (adversarial bids on the same book). On a treasury fill the bought szipUSD lands in the **rq/main Safe**
   (the `juniorTrancheEngine` label resolves there — there is **no separate engine Safe**; the basket, the buyback, and the
   redeemed USDC all live on the one ragequit Safe, so there is no cross-Safe routing) and
   `ExitGate.burnFor` burns it + the matching Loot: pure supply reduction → **NAV/share rises, the discount accretes
   to stayers**. Price is **discovery, not administered** (the junior is paid the yield *for* bearing the risk —
   there is no par floor on szipUSD; only zipUSD carries par). A holder who wants more than the market offers simply
   **sits unfilled, still in the vault, still earning**, until the market rises to them or they capitulate. **No
   forfeit** — the basket is never confiscated against a frozen slice; the frozen equity stays the holder's (steps
   4-6) and clears as it frees. The operator tier here is a **set-once `windowController`** (narrow blast radius —
   it can only post the discounted bid + drive `burnFor`, never mint or change authority). **The buy-burn FILL is
   intentionally NOT fill-time coverage-gated:** `postBid` checks `covered()` at POST time, but the
   solver fill is not re-gated, because the USDC the bid spends is free-side engine-Safe value that the coverage
   floor (`coverageValue()`) already EXCLUDES — so a fill after coverage drifts cannot breach the floor. A CoW
   pre-/post-interaction hook to re-check coverage at fill is **rejected** (`APP_DATA` is pinned to `0`, which
   forbids hooks). The undercovered-fill window is bounded by the NAV `maxAge`; shrinking the deployed `NAV_MAX_AGE`
   to tighten it is a deploy-tuning knob, not a code change (§7).
4. **Free vs committed — the debt-pinned coverage floor IS the freeze.** The `DurationFreezeModule` holds junior
   **coverage ≥ the outstanding senior debt** (`requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`),
   where `coverageValue = committedValue (juniorTrancheSidecar) + pathLockedLpEquity` — the staked LP is counted **in place**, not
   moved, so in normal operation the **juniorTrancheSidecar is empty**. The real junior outflows (the 8-B14 buy-burn `postBid`, the
   LP `removeLiquidity`) are gated by `covered()`, so a CoW exit can never take junior backing below the floor while
   loans are live. This *is* the Duration Bond freeze (§11) — **structural, not a ragequit gate**. The floor is pinned
   to **absolute outstanding debt**, NOT a utilization fraction of the basket (so shrinking the basket can't lower it);
   a single default's at-risk amount sizes only the NAV markdown (§4.6/§11). See `build/wires/DurationFreezeModule.md`.
5. **Coverage floor = the freeze (not a governed knob).** The floor is the debt-pinned `requiredCommittedValue`
   above — `covered()` gates outflow, so junior NAV can never drain below the outstanding first-loss backing.
   Structural, enforced by the freeze; **no separate floor percentage to set** (§2).
6. **Default / stasis.** If lines stall or default, the outstanding debt keeps the floor binding → `covered()` keeps
   gating the junior outflows → **nobody front-runs the loss**. The slashed xALPHA Duration-Bond premium lands in the
   **main Safe** (CTR-11) where the flywheel folds it into the basket; the floor relaxes when the hole is made whole
   (§11/§4.6).
7. **Patience vs price is the holder's own call (no forfeit).** Whether a holder waits for a near-NAV fill or
   capitulates to a lower bid now, it is one book and their own limit — never a protocol haircut. Their share of
   the frozen slice is theirs throughout; it is realized when the market fills them or the freeze releases.

**Re-affirmed:** there is **no on-chain junior redeem-for-assets** — the szipUSD exit is the
NAV-tracking CoW secondary above (rest a sell → treasury just-in-time buy-burn or external fill → `burnFor`), never
an on-chain "burn share, receive basket" call. This is the **junior-exit valve only — zipUSD itself never freezes**
(the senior is the composable dollar; its only throttle is the par queue, §6.1). The juniorTrancheSidecar is the freeze; gate custody removes the raw-ragequit footgun; the
CoW book + 8-B14 buy-and-burn is the single exit. The discount `d`/`f` and the subordination floor remain governed
params (§17). The **resting CoW order is the only queue** — there is **no on-chain intent queue, escrow window, or
liquidity window to schedule** (the old `ExitGate` `requestExit`/`processWindow` forfeit path is retired; exit =
rest a CoW sell → treasury just-in-time buy-and-burn or external fill → `burnFor`).

**Legibility (so a depositor never panics about "where are my tokens").** The depositor UI shows **one position** —
"szipUSD: $X, ~Y% APR" — never raw Loot or the gate/juniorTrancheSidecar internals. Exit is one button → a clear status track:
**Order resting (your limit) → Filled (treasury or market) → szipUSD burned**, showing the live `navExit` mark and
the standing treasury bid so the holder sees exactly what they'd get now vs by waiting. The gate and juniorTrancheSidecar are surfaced
as named, audited components that hold her claim explicitly — her funds are never "lost in a weird contract," they
are in a tracked queue with a visible clock.

---

## 7. Oracle architecture & rationale (decision: push-cache)

There are **three pricing inputs**, all CRE-mediated (same DON push-cache trust model):
1. **Collateral equity mark** (the **Proof of Value** appraisal − senior debt) → the zipUSD dollar NAV — the lien oracle (`ZipcodeOracleRegistry`, §4.1).
2. **xALPHA mark** — a junior basket leg + the **Duration-Bond premium**. **Two layers** (`build/wires/8x-01-szALPHA-bridge.md`):
   the **LST exchange rate** (`staked alpha ÷ xAlpha supply`, read from the validator stake — stake accounting,
   **no pool price** in the mint/redeem path, so the subnet emissions accrue here non-manipulably) × **`alphaUSD`**
   (the subnet **TAO/alpha AMM TWAP** × TAO/USD). Only the `alphaUSD` market leg is TWAP'd + staleness/circuit-break
   guarded. xALPHA is never sold to defend the peg; it is sold (alpha→TAO→USDC) only as a bounded last resort to
   cover a *realized* loss (§11) — the mark sizes that backstop, the sale executes at market.
3. **szipUSD NAV-per-share** (`SzipNavOracle`) — **the junior share price; the issuance + exit pricing primitive**
   (NAV is **no longer display-only**). See below.

**`SzipNavOracle` — the szipUSD share price (the issuance/exit primitive).** A `ReceiverTemplate`-based hybrid: the
CRE pushes **only** the prices it cannot read on Base (the xALPHA `alphaUSD` leg; HYDX if thin); the contract **reads
all quantities on-chain** (balances across the main + juniorTrancheSidecar Safes incl. the **staked** ICHI LP read off the gauge),
composes the basket NAV, and maintains an **on-chain cumulative TWAP accumulator** on `navPerShare`. Consumers read
the **time-weighted** share price over a governed window **`W ≈ 4h`** (§17). **(Precise:** the
szipUSD **share** is NAV-priced both ways (`navEntry = max(spot,twap)` / `navExit = min(spot,twap)`); the flat **$1**
appears **only** as the **zipUSD basket-leg / deposit-input** mark, never on the share. The real latent risk is a
zipUSD **de-peg**: it would value the zipUSD leg above its realized backing and **over-issue szipUSD, diluting
stayers** — LOW, mitigated by atomic capacity-gated minting. Optional hardening (price the zipUSD leg off realized
backing) is a noted, **not-owed** future option.) Per-leg: zipUSD/USDC = $1; xALPHA = the
two-layer mark (input 2); HYDX = pool TWAP, oHYDX = intrinsic (`HYDX × (1−discount)`); the **ICHI LP marks at true
reserve value so IL is marked-through** (not hidden); **veHYDX is permalocked → NOT a markable leg** (only the oHYDX +
fees it yields count, as claimed). **Bracket:** issuance at `max(spot, twap)`, exit at `min(spot, twap)` — protecting
resident holders both directions; **staleness pauses issuance**; a per-push **deviation circuit-break** rejects a bad
mark. Impairment provisions (§11) are written **immediately downward** by the `DefaultCoordinator` (never
TWAP-smoothed up); recovery writes back up. **Two write authorities, mirroring the lien registry's split
(§4.1):** the **Timelock-pinned Forwarder** pushes the off-chain leg marks as **reportType 7** (§4.4); a **Timelock-settable
`DefaultCoordinator`** (§11, M2) is the **sole** provision writer, **bounded** (mark down only by
`atRisk × (1 − recoveryFloor)` on a verified default, up only by realized receipts — never an arbitrary NAV).
**szipUSD's own supply is the denominator** (`navPerShare = basketNAV / (szipUSD.totalSupply() − engine
pending-burn)`); the oracle is wired to the szipUSD token via a **Timelock-settable** setter (the
Gate/share are deployed after the oracle); immutability is the deferred pre-prod lock-down (§17), not a deploy-time renounce. At zero
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
write path, hardened by the **timelocked router governor** and **Timelock-pinned Forwarder** (§4.4/§13). The value
is the **Proof-notarized origination appraisal** (§4.1/§8.10) — there is no model AVM to de-bias, so there is
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
Either way the on-chain **gate shape** (Timelock-pinned Forwarder + workflow identity) is unchanged — only the
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

**Two on-chain write paths (the whole producer surface decomposes into these).** CRE touches chain in exactly
two trust modes; every workflow below is one or the other.
1. **The report path — DON-signed reports through the immutable KeystoneForwarder → `ReceiverTemplate.onReport`.**
   The `f+1`-DON-signed, workflow-identity-gated path (§4.4/§17). Every report is the shared envelope
   `abi.encode(uint8 reportType, bytes payload)`; the workflow targets one `Receiver` per `WriteReport` and the
   `(receiver, reportType)` pair selects the on-chain decode. The receivers: `ZipcodeController` (origination/
   draw/close/status), `ZipcodeOracleRegistry` (revaluation), `SzipNavOracle` (NAV legs), `SzipReservoirLpOracle`
   (LP mark), the `CreditWarehouse` CRE-receiver/Roles-adapter (senior-custody ops), and `DefaultCoordinator`
   (default/recovery, M2). Full per-type table: §8.0.
2. **The operator path — the single immutable CRE operator → the engine modules' `onlyOperator` entrypoints.**
   The auto-compounder engine (8-B5…8-B10, §4.5/§4.5.1) is driven by **one immutable operator identity** calling
   plain `msg.sender == operator` entrypoints on the engine Zodiac modules — **not** DON-signed reports
   (§8.7; `pending-docs/auto-compounder.md §8` inv. 1). This path is **operator-TRUSTED** (e.g.
   `RecycleModule.creditFreeValue` is unbounded), and that trust is exactly what makes the revolving reservoir
   borrow safe (it kills the external-oracle-manipulation exploit, §4.5.1). Full surface: §8.7.
The two paths are independent identities by construction (the engine `operator` is asserted `!= owner` at module
`setUp`, and is never the controller/registry Forwarder). §17 governs both (Timelock-settable in build, immutability
deferred to pre-prod): the Forwarder identity and the single engine operator.

### 8.0 Report envelope + per-type producer table (the WOOF-05 discharge)
The on-chain convention is `abi.encode(uint8 reportType, bytes payload)`; **`reportType` is scoped per
receiver** — the workflow ABI-encodes the payload, calls `runtime.GenerateReport(req)` → `evmClient.WriteReport(
runtime, {Receiver, Report, GasConfig})` (`cre/runtime.go:58`, `client_sdk_gen.go:293`), and the receiver's
`_processReport` decodes `payload` by its own type constant. Because each `WriteReport` names one `Receiver`, the
**type-number space is keyed by `(receiver, reportType)`, not globally** — so `SzipNavOracle.NAV_LEG == 7` and
`SzipReservoirLpOracle.LP_MARK == 7` are the **same numeral on two different receivers and never collide** (each
push targets exactly one). This is the ratification the 8-B5 placeholder asked for: **`LP_MARK = 7` stands**
(`SzipReservoirLpOracle.sol:27`), distinct from the registry's `REVALUATION = 3` (`ZipcodeOracleRegistry.sol:24`)
as required; no contract change.

| reportType | Receiver | payload ABI (on-chain decode, exact) | Producing workflow (§) | CRE ticket |
|---|---|---|---|---|
| `1` Origination | `ZipcodeController` | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount, uint256 cap, bytes32 siloId)` | Underwriting/origination (§8.1) | CRE-01 |
| `2` Draw | `ZipcodeController` | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)` | Draw (§8.1) | CRE-01 |
| `3` Revaluation | `ZipcodeOracleRegistry` | `(address[] liens, uint256[] prices, uint32 ts)` | Revaluation, gas-bounded sharded (§8.1) | CRE-01 |
| `4` Close | `ZipcodeController` | `(bytes32 lienId)` | Close/release (§8.1) | CRE-01 |
| `5`/`6` Default/Liquidation | `ZipcodeController` | `(bytes32 lienId, uint8 status)` | Default/recovery (§8.4) | CRE-01 |
| `7` NAV_LEG | `SzipNavOracle` | `(uint8[] legs, uint256[] prices, uint32 ts)` — `legs ∈ {0 ALPHA_USD, 1 HYDX_USD}` | Share-price feeds (§8.6) | CRE-03 |
| `7` LP_MARK | `SzipReservoirLpOracle` | `(uint256 mark, uint32 ts)` | Share-price feeds (§8.6) | CRE-03 |
| SUPPLY/APPROVE/REDEEM/REPAY | `CreditWarehouse` CRE-receiver | `(uint8 opType, bytes payload)` → re-encoded Safe call (§8.5) | Warehouse ops (§8.5) | CRE-04 |
| default/recovery (reportType 8) | `DefaultCoordinator` | `(uint8 action, bytes actionData)` — LOCK/RELEASE/DEFAULT/RECOVERY/RESOLVE/WRITEOFF (§8.4) | Default/recovery (§8.4) | CRE-01 (LOCK/RELEASE M1-live; default actions go live with the M2 demo) |
| `8` RATE | `SzAlphaRateOracle` (Base) | `(uint256 rate, uint48 ts)` — the raw xALPHA `exchangeRate()` pulled from 964 | xALPHA rate pull (§8.8) | CRE-03 (8x-02) |
| `1` POST_BID | `SzipBuyBurnModule` | `(uint256 sellAmount, uint256 buyAmount, uint32 validTo)` → `_postBid` | buy-burn bid-loop (§8.7) | CRE-05 (via CTR-01) |
| `2` CANCEL_BID | `SzipBuyBurnModule` | empty payload → `_cancelBid` | buy-burn bid-loop (§8.7) | CRE-05 (via CTR-01) |

**Per-receiver scoping note (CTR-01, 2026-06-16):** `SzipBuyBurnModule.POST_BID == 1` / `CANCEL_BID == 2` are
the SAME numerals as the controller's `Origination`/`Draw`, but `reportType` is **per-`(receiver, type)`** — a
report names exactly one `Receiver`, so a `1` to the controller and a `1` to the buy-burn module never collide.
8-B14 is the deliberate **§8.7 exception** (below): the operator-path engine module made ALSO report-drivable.

**siloId routing (CTR-03, 2026-06-18):** the RT_ORIGINATION payload carries a **trailing `bytes32 siloId`** — the
controller resolves `venue = SiloRegistry.venueOf(siloId)` per origination (multi-pool sharding, §4.7) and stores
`siloId` on the lien. RT_DRAW/RT_CLOSE payloads are **unchanged** — those branches re-resolve the same venue from
the stored `r.siloId`, so the CRE producer does NOT re-send it. The CRE composer (CRE-01) picks `siloId` (the
current fill target); the registry backstops with a fail-closed `SiloFull` cap (28 lines/silo).

`equityMark` = the Proof-of-Value mark (home value − senior debt, §4.1); `proofRef` = a commitment to the Proof
attestation bundle (lien-perfected + value + insurance); the lien/insurance **gates** are off-chain
preconditions — the workflow emits a report **only if they pass** (§8.9/§8.10). `regionalHPI` is in no payload
(§4.1). The on-chain decoders are the source of truth: the workflow's report struct + `consensus_aggregation`
tags MUST match these exactly (§4.4 / `ZipcodeOracleRegistry.sol:93` / `SzipNavOracle.sol:201` /
`SzipReservoirLpOracle.sol:72`).

**This envelope + every per-`(receiver, reportType)` payload encoder is now BUILT as the shared
`cre/zipreport` Go package (CRE-00, 2026-06-19)** — an SDK-free library whose round-trip test pins each builder
to the exact filed-contract decode tuple above. CRE-01/03/04 import it rather than re-implementing the
handshake. (POST_BID/CANCEL_BID → `SzipBuyBurnModule` stay in CRE-05a's own workflow, not `zipreport`.)

### 8.1 Underwriting / origination / revaluation
- **Trigger:** `http.Trigger(*Config)` (`capabilities/networking/http/trigger_sdk_gen.go:16`, originator
  submits an application) for origination; **event-driven re-pricing** on **secondary acquisition / deviation
  / draw** events (revaluation, writes **direct** to the registry, §4.1/§4.4b). **No cron heartbeat** — the
  mark is event-driven Proof (§4.1).
- **Inputs (fetched per-node, zk-verified, then aggregated; the full source→surfacing map is §8.10):** the
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
  `ZipcodeController` (origination/draw, reportType 1/2 — atomic price seed) or the `ZipcodeOracleRegistry`
  (revaluation, reportType 3).
- **Revaluation sharding (the WOOF-02 discharge).** `ZipcodeOracleRegistry._processReport` applies the whole
  `(liens, prices, ts)` arrays in **one atomic loop** (`ZipcodeOracleRegistry.sol:93-111`): equal lengths are
  enforced (`LengthMismatch`, `:98`), and any single bad entry (`price==0`, `ts>now`, wrong-decimals lien)
  reverts the **entire** report (`:107-110`). So the producer rule is: (i) **shard** a multi-lien re-mark into
  **gas-bounded batches** — size each batch's `liens.length` so the worst-case `_processReport` gas stays under
  a conservative block-gas fraction (the loop is O(n) with a per-entry `decimals()` staticcall; size to a fixed
  `MAX_LIENS_PER_REPORT` constant calibrated on the target chain, log the shard count); (ii) emit **one
  `WriteReport` per shard** (each batch is independently atomic — a poison entry only fails its own shard, not
  the sweep); (iii) **dedup across the full sweep** so no `lien` appears in two shards in the same epoch
  (on-chain it is last-write-wins, so a dup is a silent-correctness footgun the producer must prevent) and
  enforce equal-length `liens`/`prices` **before** encoding (don't rely on the on-chain revert to catch a
  malformed batch). No malformed/dup entry, atomic per batch.
  - **(The all-or-nothing batch is the mitigation, not a bug.)** The per-batch atomicity is the
    intentional fail-closed design: a poison key reverts its own shard so no partial/inconsistent revaluation lands.
    Adding a per-key `try/catch` inside `_processReport` to skip-and-continue is **rejected** — it would swallow
    poison keys and let an inconsistent partial set through, weakening exactly the WOOF-02 guarantee. The producer
    mitigates blast radius by **sharding** (above), and the long line-term validity window means a failed shard's
    keys simply stay on their prior mark until the next push — no liveness cliff.

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
  rebalance reads utilization `U`; on a `U ≥ U_lock` breach it (i) **paces new draws
  against pending redemptions** and (ii) engages the **§11 trigger-B** systemic junior lock. This is the
  on-chain host for the squeeze trigger (the optional CRE "secondaries-down" report can trip it earlier, §8.4).
  **`U` is the illiquid fraction of the senior backing, read donation-immune from the EulerEarn senior pool:**
  `U = 1 − maxWithdraw(CreditWarehouse) / convertToAssets(balanceOf(CreditWarehouse))` (clamped to `[0,1]`) — i.e.
  one minus the fraction of the warehouse's senior position that can be withdrawn *right now* given how much USDC the
  credit-line strategies have lent out. This reads the **controller-gated borrow side** (loans the homeowners drew,
  §4.3 — the only thing that moves it), **not** a stray-balance "idle" figure: EulerEarn's `totalAssets()` is
  `Σ expectedSupplyAssets(strategy)` (it ignores USDC merely transferred to the pool address), and `maxWithdraw`
  measures real strategy liquidity, so the §11-B "**not outsider-manipulable**" guarantee holds (a USDC donation to
  the pool address moves neither term). **`U` must NOT be derived from `IERC20(asset).balanceOf(eulerEarn)`** — that
  is donatable + is ~0 for a pure-allocator EulerEarn (it would pin `U≈1` and brick releases). The residual
  manipulation surface (donating into a *strategy* vault's cash to raise `maxWithdraw`) is bounded, costly, and an
  item-10 live-pool verification, not a free public lever.

### 8.3 Redemption settlement
A `cron.Trigger` calls `settleEpoch()` (§6.1), which settles against the queue's own REPAY-delivered USDC balance
(on-demand — no time gate). When that balance is short of the fulfillable claims, the same cron **first** funds the
queue via the warehouse **REDEEM** op (§8.5 — `EE_POOL.redeem(shares, receiver==SAFE, owner==SAFE)` through the
Roles adapter, USDC into the Safe) **then** a **REPAY** to the queue sink, **then** calls `settleEpoch()`. Sizing
the REDEEM (how many shares to release) is the producer's job; the on-chain Roles policy only pins the call shape,
not the amount. (`ZipRedemptionQueue.settleEpoch` is controller-gated, not renounced — the controller keeps calling
it, §4.5.)

### 8.4 Default / recovery
Delinquency status and recovery amounts are **off-chain truths** that arrive as DON-signed reports, **reportType 8**
to the `DefaultCoordinator` (§4.4/§4.6) via `runtime.GenerateReport → evmClient.WriteReport(runtime, {receiver:
DefaultCoordinator})`. The coordinator verifies the report (immutable CRE Forwarder + workflow identity) before acting.
The report is **action-discriminated**: `payload = abi.encode(uint8 action, bytes actionData)`, with `actionData`
decoded per action (the on-chain decode mirrors this exactly):
- `0 LOCK (bytes32 lienId, address originator, uint256 amount)` — post the launch xALPHA bond (M1-live; pulls `amount`
  xALPHA from the coordinator's reserve into the escrow).
- `1 RELEASE (bytes32 lienId)` — clean repay: return the full bond to the recorded originator (M1-live).
- `2 DEFAULT (bytes32 lienId, uint256 atRisk)` — recognition: the coordinator sets the lien's provision to
  `atRisk × (1 − recoveryFloor)` and pushes `totalProvision` to `SzipNavOracle`. **The markdown `atRisk` IS in this report**
  (the off-chain re-appraisal computes it from the §4.1 deviation re-mark + the outstanding debt); the bare reportType-5
  default-status report still goes to the **controller** (§4.4d) to mark status + emit the legal-action event — two
  receivers for one real-world default.
- `3 RECOVERY (bytes32 lienId, uint256 recoveryProceeds)` — partial heal: reduce the lien's provision by ≤ the reported
  18-dp-USD `recoveryProceeds` (clamped to 0), push `totalProvision` (writes back up).
- `4 RESOLVE (bytes32 lienId, uint256 capitalSlashAmount)` — clean resolution: zero the lien's provision, then route the
  xALPHA bond (`slashXAlphaToCapital(capitalSlashAmount)` if `> 0`, then `slashXAlphaToCohort`).
- `5 WRITEOFF (bytes32 lienId, uint256 capitalSlashAmount)` — confirmed permanent shortfall: the provision **settles**
  (residual stays, no further recovery accepted), then route the xALPHA bond as in RESOLVE.

`atRisk`/`recoveryProceeds` are **18-dp USD**; `capitalSlashAmount` is **xALPHA (18-dp)**. The **capital-vs-premium split**
(`capitalSlashAmount`) is computed **off-chain** (the shortfall after foreclosure + insurance) — the escrow enforces only
`amount ≤ bond`; the split + timing + default-state policy live in the workflow (the §13 trust boundary).

**Secrets/config & scaffolding:** project + secrets config; DON-only `GetSecret` (no PII in node-mode
consensus). For the concrete Go scaffold a fresh engineer should clone the trigger→node-mode-fetch→
consensus→`GenerateReport`→`WriteReport` shape from `reference/cre-sdk-go/standard_tests/*/main_wasip1.go`
and the project layout from `reference/cre-templates`; the report struct + `consensus_aggregation` tags
must match the on-chain report ABI in §4.4; secrets-declaration format, `GasConfig`, and `cre-cli`
simulate/deploy are cre-cli mechanics documented in those references.

### 8.5 Senior-warehouse ops (SUPPLY / REDEEM / REPAY — the Roles-gated path)
The `CreditWarehouse` is a plain Gnosis Safe custodying the protocol's `EulerEarn` shares; CRE drives it
**only** through the audited Zodiac **Roles Modifier v2**, never by a bespoke privileged contract (§4.5).
The CRE seam is a thin **`is ReceiverTemplate`** receiver
(Forwarder-gated, Timelock-owned — not renounced, exactly as §4.1/§4.4/§17) that is `assignRoles`'d as the role
member. On a report it decodes the warehouse envelope `abi.encode(uint8 opType, bytes payload)`, **re-encodes
the corresponding pinned Safe call**, and invokes `Roles.execTransactionWithRole(to, 0, data, Call, roleKey,
true)` (`reference/zodiac-modifier-roles` `Roles.sol:153`); the Roles checker validates against the
owner-applied permissions policy and forwards to the Safe — anything outside the policy reverts **in the Roles
checker before the Safe is touched**. The producer emits one op per report, each mapping to one pinned call
(§4.5 op-set):

| opType (byte) | producer emits | Safe call the adapter re-encodes (params pinned) | when the workflow emits it |
|---|---|---|---|
| `SUPPLY = 1` | `(uint256 amount)` | `EE_POOL.deposit(amount, receiver==SAFE)` | put routed/recovered USDC to work as senior backing |
| `APPROVE = 2` | `(uint256 amount)` | `USDC.approve(spender==EE_POOL, amount)` | the allowance `deposit` pulls against (precedes SUPPLY); exact-amount, not infinite |
| `REDEEM = 3` | `(uint256 shares)` | `EE_POOL.redeem(shares, receiver==SAFE, owner==SAFE)` | redeem shares → USDC **into the Safe** (then REPAY); fund the redemption queue (§8.3) / recovery |
| `REPAY = 4` | `(address to, uint256 amount)` | `USDC.transfer(to==<pinned sink>, amount)` | distribute Safe USDC to the pinned sink — the `ZipRedemptionQueue` (§6.1) or a recovery sink (§4.6/§11) |

**The producer sizes the scalars; the policy pins identities** — the workflow computes `amount`/`shares` (e.g.
the redemption shortfall, the recovery draw) off the live NAV (`EE_POOL.convertToAssets(EE_POOL.balanceOf(SAFE))`,
read via `evmClient.CallContract`), but cannot widen the call set (that needs the Safe owner: GOD-EOA → multisig).
The `to` of REPAY is the one field the producer carries (the scope pins it `EqualTo(<sink>)`, so a re-scope, not a
redeploy, retargets it); every other identity is adapter-injected AND scope-pinned (belt-and-suspenders).
**RECONCILED WITH THE BUILD (8-Bw, `WarehouseAdminModule`, `build/wires/8-Bw-CreditWarehouse.md`):** the opType
bytes above (1/2/3/4), the `abi.encode(uint8 opType, bytes payload)` envelope, and the open 8-Bw choices are now
resolved against the built adapter (EulerEarn `redeem(shares, receiver, owner)` — owner 3rd; redeemed USDC →
Safe-then-REPAY, not direct-to-sink; APPROVE exact-amount with `spender` pinned). CRE-04 builds against THIS table +
the built `WarehouseAdminModule` decode; the warehouse adapter uses a **distinct Forwarder identity / workflowId**
from the controller/registry/oracle receivers.

### 8.6 szipUSD share-price feeds (NAV legs + LP mark — the push-cache producers)
The szipUSD share price and the engine's LP-collateral price are **hybrid push-cache oracles** (§7): the
contracts read every on-chain quantity/leg themselves, and CRE pushes **only** the off-chain leg marks it
cannot read on Base. Two receivers, both `ReceiverTemplate` push-caches:
- **`SzipNavOracle` (reportType `NAV_LEG = 7`, `SzipNavOracle.sol:49`).** Payload `(uint8[] legs, uint256[]
  prices, uint32 ts)` with `legs ∈ {LEG_ALPHA_USD=0, LEG_HYDX_USD=1}` (`:43/:45`). The workflow pushes the
  **xALPHA `alphaUSD` leg** (leg 0 — the subnet TAO/alpha AMM TWAP × TAO/USD, two-layer mark per §7/input 2;
  the on-chain `xAlpha.exchangeRate()` is read trustlessly and multiplied in, `:345`) and **HYDX/USD** (leg 1,
  pushed only if the pool is thin; the contract derives oHYDX intrinsic from it, `:350`). **All quantities and
  every on-chain leg (zipUSD/USDC=$1, the staked-ICHI-LP reserves, the LST exchange rate) are read on-chain —
  never pushed.** On-chain guards the producer must respect: equal `legs`/`prices` lengths (`LengthMismatch`),
  `ts<=now` (`FutureTimestamp`), non-zero prices (`ZeroPrice`), and a per-push **deviation circuit-break**
  `maxDeviationBps` vs. the prior cached leg (`DeviationExceeded`, `:219`) — so the producer must **not** jump a
  leg more than the governed band in one push (push intermediate marks, or the band rejects it). Cadence:
  push on the engine epoch and on a material leg move; the `fresh()` issuance guard (`:328`) pauses **issuance**
  if either required leg ages past `maxAge`, while exit prices off the last good mark (asymmetric by design).
- **`SzipReservoirLpOracle` (reportType `LP_MARK = 7`, `SzipReservoirLpOracle.sol:27`).** Payload `(uint256
  mark, uint32 ts)` — a **single fixed key** (the ICHI LP share, quote USDC; no per-key map, no controller
  seed, the Forwarder is the only writer). The workflow computes the mark off-chain as
  `(reserve_xALPHA × priceXAlpha + reserve_zipUSD × priceZipUSD) / ICHI_LP_totalSupply` (the same reserve-value
  LP math `SzipNavOracle` runs for the basket's staked-LP leg, so the two feeds stay coherent — produce them
  from one computation) and pushes per engine epoch. **Fail-closed by design:** a stale/missing mark reverts
  `_getQuote` → the reservoir borrow's EVC account-status check reverts (`:100-103`), never opening an unsafe
  borrow. So the producer's only obligation is **liveness** — re-push within `validityWindow` (generous,
  engine-cadence); a missed push is safe (closes the borrow), an over-stale one blocks new strike-loop draws
  until refreshed. `mark!=0`, `mark<=uint208.max`, `ts<=now` are enforced on-chain (`:82-84`).

### 8.7 Engine strategy-admin operator (8-B11 — the operator path, NOT a report)
The auto-compounder engine (§4.5/§4.5.1, 8-B5…8-B10) is driven by the **single immutable CRE operator** calling
the engine Zodiac modules' `onlyOperator` (`msg.sender == operator`) entrypoints — a **different write path
from every §8.0 report** (§8.7; `pending-docs/auto-compounder.md §8` inv. 1). This is the off-chain
orchestrator whose **on-chain surface is 8-B11** (a plain `onlyOperator` modifier + an immutable operator
address on each module); the workflow itself is this CRE build. It is **not** Forwarder-gated and emits **no
DON-signed report** — the operator submits ordinary transactions (it may still run as a CRE workflow using
`evmClient.WriteReport`'s sibling write surface / a keeper identity, but the on-chain gate is the operator
address, not the Forwarder identity). **Trust model:** the operator is **TRUSTED** — `RecycleModule.creditFreeValue`
is unbounded (`RecycleModule.sol`), so the single-immutable-operator permissioning (set at module `setUp`,
asserted `operator != owner`) is the security boundary that makes the revolving reservoir borrow safe (§4.5.1).

**EXCEPTION — CTR-01 (2026-06-16): the operator path has no `cre-sdk-go` write surface, so a module may ALSO
carry a report socket.** This section assumed "the operator submits ordinary transactions … using
`WriteReport`'s *sibling write surface* / a keeper identity." That sibling surface does **not exist**:
`cre-sdk-go`'s evm client exposes reads + exactly one write, `WriteReport` (DON-signed report → immutable
Keystone Forwarder → `IReceiver.onReport`) — there is **no raw-tx / keeper primitive**. So a wasip1 CRE
workflow cannot drive an `onlyOperator` entrypoint. **Resolution:** the reusable `CloneReportReceiver` base
(`contracts/src/supply/szipUSD/CloneReportReceiver.sol`) adds a clone-safe report socket so a module can be
driven by the DON-signed report path **alongside** its operator key — both doors route through the same
validated internals (two doors, one guard set). `SzipBuyBurnModule` (8-B14) is the first to adopt it (the bid
is the protocol's own automation, not a borrow-side trust surface). The other operator/controller modules
(8-B5…8-B10, `DurationFreezeModule`, `OffRampModule`, and the controller-keyed `ZipRedemptionQueue.settleEpoch`
/ `ExitGate.burnFor`) have the **identical gap** and can adopt the same base, OR be driven by an off-chain
keeper holding the operator/controller key — a per-module decision (logged in `build/tickets/PROGRESS.md`).

**ROUTING DECISION RESOLVED (2026-06-16, `build/tickets/cre/CRE-OPS-ROUTING.md`).** The per-module choice is made:
**(R) report path ONLY for 8-B14**; **(K) the single trusted operator/keeper for the whole engine harvest loop
(8-B5…8-B10), the redemption operator sequencing (`OffRampModule` + `ZipRedemptionQueue`), and `ExitGate.burnFor`**;
**`DurationFreezeModule.commit/release` stays DORMANT** (driven only on a coverage shortfall — the on-chain
`covered()` gate is the fail-closed backstop). Principle: (R) iff the write is a DON-attestable economic value AND
report-driving opens no attack surface — which is why `RecycleModule.creditFreeValue` is **(K)**, NOT (R)
(report-driving it would re-open the §4.5.1 oracle-manipulation exploit operator-trust exists to kill). So
**CTR-01's socket is the EXCEPTION, not the template** — no further sockets are bolted onto the operator/controller
surface. The (K) surface is the **CRE keeper service** (off-chain Go + go-ethereum, NOT wasip1); failure is
liveness-only + fail-safe (the on-chain caps/coverage/EVC guards hold; `setOperator` is the Timelock recovery, §17).

Per epoch + on triggers the operator runs the loop (each leg an `onlyOperator` call, the operator supplying
**only scalar amounts** — never addresses/calldata — so its blast radius is bounded, `LpStrategyModule.sol:19`):
1. **claim** oHYDX + fees and **vote** (8-B7 harvest/vote — `Voter.vote` each epoch, `exerciseVe` to defend the
   floor); **classify regime** (price vs. short EMA: UP/FLAT/DOWN, `hydrex.md §9.2`).
2. **strike loop:** post LP collateral → CRE-only **borrow** USDC from the reservoir (8-B5
   `ReservoirLoopModule`, gated by `LP_MARK` being live, §8.6) → **exercise** oHYDX (8-B8) → **sell** HYDX→USDC
   via NFPM range orders with retrace-guard + soft-bleed caps (8-B9).
3. **credit + recycle the free value:** `RecycleModule.creditFreeValue(net)` (the operator-trusted accumulator
   write) then `recycle(usdc)` → `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing → backed
   zipUSD minted into the MAIN Safe basket) → **8-B6 single-sides** it into the gauge-staked LP → **NAV-per-share
   accretes for every holder** (8-B10, the single sink — no payout, no xALPHA distribution; 8-B13 is absorbed
   here, §4.5.1). **Free-value-only invariant:** only HYDX-extracted USDC is recycled — never depositor USDC,
   never unbacked mint.
4. **LP lifecycle:** `LpStrategyModule.addLiquidity/stake/unstake` (8-B6) to re-post and gauge-stake; each call
   carries a `minShares`/slippage floor the producer computes (the module reverts on a sandwiched/thin mint).
5. **rotate** free↔committed equity main↔juniorTrancheSidecar via the **dormant** `commit`/`release` lever — driven only on a
   coverage shortfall against the debt-pinned floor (§6.4/§11), not a per-utilization rotation.
The split/regime/caps are **CRE-workflow policy** (8-B10's allocation weights are the only open economic knob,
deferred to the treasury module, §17); no additional on-chain mechanism is invented here. **This path is the
junior's pay + self-insurance** (the loop vamps net-new USDC, compounding the basket = "frozen but earning",
waterfall leg (e), §11). It is bounded — TVL-capped, front-loaded, trailing-realized (`hydrex.md`).

> **Strike-loop core-slice policy RATIFIED 2026-06-19** (the build gate for KEEPER-01b's first slice;
> full record + rationale in `build/tickets/cre/KEEPER-01b-OPEN-POLICY.md`). The execution floors + sizing
> constants are pinned:
> - **`sellHydx` `minOut` = a LIVE quote − cushion, NOT a 2h-TWAP.** The keeper eth_call's an Algebra QuoterV2
>   `quoteExactInputSingle` on the HYDX/USDC pool at decision time and floors at `quote × (1 − cushion)`. A TWAP
>   floor is *wrong* for an exit-biased seller — in HYDX's declining regime the 2h-TWAP sits above spot and would
>   revert the sell exactly when selling is needed. The 2h-TWAP keeps its job as the per-epoch **volume/cadence**
>   governor ("never sell faster than the TWAP follows"), not a single-swap price floor.
> - **cushion = 200 bps (2%)** — one constant on `minOut` / `maxPayment` / `minShares` (§9.3 ≤2–3% band).
> - `addLiquidity` ratio from ICHI `getTotalAmounts()`, `minShares = expected × (1 − cushion)`; `exercise`
>   `maxPayment = quoteStrike(amount) × (1 + cushion)` (`quoteStrike` is the existing on-chain read).
> - **borrow size + recycle/reserve split = fixed, TUNABLE M1 config constants** (mirror CRE-05a's
>   `harvestReserve`/`safetyBuffer`); a dynamic-from-collateral policy is a later swap.
> - **price taper/halt** (user-ratified 2026-06-08): taper from $0.033 → shrink loop at the ~$0.018 amber tier →
>   halt `exercise` at the $0.015 profitability cutoff (accrue oHYDX below it) — a level check on the live price,
>   so no EMA/state store is needed for the core slice.
>
> So the **strike-loop core** (claim → borrow → exercise → sell → credit/recycle → restake; **no** regime gate,
> vote, or rotation) is buildable now. **STILL policy-blocked / own later slices:** the regime classifier + EMA
> params, the keeper STATE store (an infra decision), the vote/allocation weights (§17-deferred), the explicit
> per-epoch volume cap, and the main↔sidecar rotation (→ `KEEPER-01c`, `DurationFreezeModule` premise under
> review). `KEEPER-00` (the spine) + `KEEPER-01a` (buy-burn `burnFor`) + the **strike-loop core slice
> (KEEPER-01b, BUILT 2026-06-19** — `cre/keeper/internal/job/strike_loop_job.go`: the ordered
> claim→borrow→exercise→sell→repay→creditFreeValue→recycle→addLiquidity→stake Plan, stateless, conservative
> floors; `minShares` from the exact canonical ICHI deposit formula, the HYDX price from the pool `globalState()`)
> shipped. **The restake leg is now side-aware (KEEPER-01b-R1, BUILT 2026-06-19):** the quoter resolves which
> vault token is the recycled zipUSD each tick (`recycle.zipDepositModule().zipUSD()` vs `vault.token0()`) and
> the Job builds `addLiquidity` on that side — `(expectedZip,0)` for token0, `(0,expectedZip)` for token1 — so
> the compounder closes regardless of the zipUSD/xALPHA address sort. **Own-later:** B1/B2/C1–C3/C5 (PROGRESS).

### 8.8 xALPHA exchange-rate Base oracle + the DERIVED APR (8x-02)
**The one fact that lives only on Bittensor is the xALPHA `exchangeRate()`** (`staked alpha ÷ supply`, StakingV2
`0x805`, native to **Subtensor 964**; the Base `SzAlphaMirror` is a plain `BurnMintERC20` with no stake surface). So
a CRE workflow (`cre/szalpha-rate/`) **pulls that ONE primitive from 964 and pushes it — raw — to a Base oracle**
`SzAlphaRateOracle` (`contracts/src/bridge/SzAlphaRateOracle.sol`, `reportType RATE = 8`, payload `(uint256 rate,
uint48 ts)`). **CRE transports the rate; the chain derives everything else** (NAV, APR) on Base from it — nothing
pre-computed is ever pushed or bridged. `SzAlphaRateOracle` is the Base-side `IXAlphaRate`: `exchangeRate()` (the
last pushed rate) + `fresh()`/`lastUpdate()`. (**As-built:** it `is ReceiverTemplate is Ownable` — it
is NOT "ownerless / fully immutable." The Forwarder + workflow identity are **Timelock-mutable** (§17); only the
economic knobs — `maxStaleness`/`window`/`aprCap` — are `immutable`.) Push guards are truthful, not adversarial — non-zero, not-future,
**strictly-newer** (no replay/out-of-order); deliberately **no deviation band** (a validator slash legitimately
lowers the rate); consumers **fail-closed on staleness** via `fresh()` (a rate that moves NAV must not serve stale).

- **NAV consumes the rate directly.** `SzipNavOracle`'s xALPHA leg reads `exchangeRate()` from this oracle (in
  production; the M1 18-dp stand-in exposes the same surface). This **resolves the §8.6 cross-chain rate seam** —
  the rate the NAV oracle needs on Base now has a defined producer.
- **The intrinsic APR is DERIVED on-chain** from the pushed rate's history: `SzAlphaRateOracle.intrinsicAprBps()` =
  `(rate_now / rate_prev − 1) × year/Δ` over two rolling checkpoints the pushes maintain — **floored at 0** (a
  slash/decline is 0, not negative — no brick), clamped to an immutable `aprCap` display bound. **Trailing-realized,
  never projected** (§12), numeraire-clean (supply cancels), **no treasury/budget constant.** It is advisory —
  consumed by the depositor UI / 8-B12 monitoring / the 8-B11 regime gate — and **gates no funds**, so it is never
  pushed or bridged; it is a pure read on the rate. (A metagraph `getEmission`/`getDividends` `0x802` read stays an
  off-chain **forward cross-check only**.) This is **distinct from** the szipUSD depositor APR (NAV accretion from
  the recycle loop — the 8-B12 / §8.6 product feed); it is xALPHA's *own* yield. The stale "lending-spread + coupon"
  base leg is **dropped** (lending yield → treasury, §17/[[supply-side-redesign-locked]]); the **post-M1 szipUSD
  incentive APR** (`emitted × xALPHA_USD ÷ szipUSD_TVL`) is a separate, deferred overlay consuming this primitive —
  never blended (its USD/value leg is the only piece that touches cross-chain supply, post-M1).

### 8.9 The Proof capability gate (DEC-01 — RESOLVED, two-layer model)
Every report in §8.0 carrying a credit fact (origination 1, draw 2, revaluation 3, §8.4 recovery) needs its facts
attested in a CRE-consumable (per-lien, signed, deterministic, identical-consensus) form. **DEC-01 RESOLVED
(2026-06-09, `pending-docs/spv-lien-proof.md §6.1`):** a notarization attests *signer identity + document
integrity* — **not the truth of the contents** — so the model is **two layers**. The **facts** come from
authoritative feeds (county recorder/title = existence/position + anti-fabrication; appraiser = value →
`equityMark`; carrier = insurance), and **Proof** seals that the SPV's lien instrument + assignment is genuine and
ours. The DON downloads each signed artifact (the sealed Proof PDF behind a rotating pre-signed URL; the
recorder/appraiser/carrier responses), **hashes it on-node**, verifies the cert chain, and aggregates
`ConsensusIdenticalAggregation` (`reference/cre-sdk-go/cre/consensus_aggregators.go:33`); fetches are DON-only
(`runtime.GetSecret`). **Not a live-origination blocker:** CRE-01 builds against **mock Proof + mock feeds** and
swaps the real endpoints in as they integrate (the §8.10 source map; the xALPHA-stand-in pattern). The remaining
external dependencies are the insurance **product** (SPV-doc §6.2), **legal** (§6.3), and pinning the feed vendors /
SPV partner — those gate *real-collateral* origination, not the build.

### 8.10 Off-chain underwriting & proof layer
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

### 8.11 CRE build-ticket map (the workflows above are now authorable)
Each workflow above is a CRE-NN ticket basis. This table is the CRE build map (the live status pane is in
`tickets/PROGRESS.md`):

| Ticket | Scope (§) | Path | Gate |
|---|---|---|---|
| `CRE-00` | Project + secrets scaffold (DON-only `GetSecret`; `reference/cre-templates` layout) **+ the shared §8.0 `cre/zipreport` encoder package** — **BUILT 2026-06-19** (`cre/zipreport` lib + `cre/scaffold` template; gate green) | — | none |
| `CRE-01` | Origination / draw / close / status reports → controller (1/2/4/5,6); revaluation → registry (3, **gas-bounded sharded**, §8.1); default/recovery → `DefaultCoordinator` (8, action family §8.4) | report | DEC-01 (§8.9) |
| `CRE-02` | Redemption-settle `cron` (§8.3) + the warehouse **REDEEM** funding call (§8.5) | report (Roles) + cron | 8-Bw reconcile |
| `CRE-03` | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipReservoirLpOracle` (§8.6) — and the xALPHA-APR feed (§8.8) | report (push-cache) | DEC-02 cleared 2026-06-09 (self-serve CCT confirmed on 964); xALPHA lane build-only |
| `CRE-04` (new) | Senior-warehouse **SUPPLY/APPROVE/REPAY** ops via the Roles adapter (§8.5) | report (Roles) | **8-Bw `WarehouseAdminModule` reconcile** (§8.5) |
| `CRE-05` | Engine strategy-admin **operator** orchestrator (§8.7). **SPLIT:** exit half = **CRE-05a (DONE)**; the harvest loop (8-B5…8-B10) + main↔juniorTrancheSidecar rotation = **KEEPER-01b/01c** on the (K) keeper track (POLICY-BLOCKED/deferred). Live status in PROGRESS. | operator / (K) | none (operator-trusted; engine modules built) |

**Discharged this window:** the WOOF-05 report-ABI envelope per-type table (§8.0) and the WOOF-02 gas-bounded
revaluation sharding (§8.1). **Open before the live CRE-01 build:** DEC-01 (§8.9). **Open before CRE-04
finalizes:** the 8-Bw `WarehouseAdminModule` decode reconcile (§8.5).

---

## 9. Authorization & control-flow trace

**One-time setup** (governor/owner). The Euler calls below wire the **`EulerVenueAdapter`** (config one; for
M1 it may be the controller itself, §4.4) — it holds the Euler roles — while the controller/registry get the
Timelock-pinned Forwarder + identity. Venue wiring: `venuePool.setIsAllocator(adapter, true)`;
`venuePool.setFeeRecipient(...)` + `setFee(f)` (recipient = the warehouse Safe, §5); grant
`ESynth` mint capacity to **`ZipDepositModule`** (the module mints zipUSD 1:1-by-value on deposit, and the zap
mints transiently to the module before handing it to the szipUSD mint shaman, §4.5) — **size the capacity to its
expected flow (a bounded cap, not `max`)**;
**`ZipDepositModule.setStakingVault(szipUSD)`** (set-once) to store the szipUSD address — the zap grants szipUSD
a per-zap **zipUSD** allowance and calls `depositFor` (the Baal mint shaman); there is **no** EE-share allowance
(the warehouse Safe holds the EE shares, §4.5 szipUSD seam); then **transfer `ESynth` ownership to the Timelock** (§17; the
renounce that permanently freezes `setCapacity`/`allocate`/`deallocate` is deferred to pre-prod), leaving the
live mint surface as those two pre-granted capacities;
grant the adapter **EulerEarn curator + allocator** (the per-line market onboarding inside `openLine`
requires curator, §4.7; deploy the EE pool with **timelock 0** for M1 so `submitCap`→`acceptCap` is atomic —
a single-curator simplification, production-hardening item); the **isolated EVK markets + per-line routers are
created per-lien inside the venue adapter's `openLine`** (§4.7: escrow collateral vault + USDC borrow vault
with `setGovernorAdmin(adapter)`, `setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)` repay-ungated,
`setInterestRateModel(irm)`, a dedicated `EulerRouter` wired to the registry and frozen) — there is **no
shared router and no `govSetFallbackOracle`**; the per-line router keys `(LIEN_i, USDC)` on the registry and
is frozen at birth (§4.1). Deploy an **OpenZeppelin `TimelockController`** (delay ≈2 days) **for §17
parameter governance only** (szipUSD floor / `f` / cooldown — §17), **not** as a router governor;
deploy registry/controller; in the **build phase the Forwarder + every wiring slot stay Timelock-re-pointable**
(§17 — immutability/renounce is deferred to the pre-prod lock-down), so the final wiring op **transfers `Ownable`
ownership to the Timelock** (`transferOwnership(timelock)`), **not** renounce;
**but first, before the hand-off, call `setExpectedAuthor(WORKFLOW_OWNER)` and
`setExpectedWorkflowId(WORKFLOW_ID)` on every `ReceiverTemplate` subclass** (`ZipcodeController`,
`ZipcodeOracleRegistry`, and — when added — `DefaultCoordinator`) **and assert `getExpectedWorkflowId() != 0`
on each immediately before `transferOwnership(timelock)`, aborting the deploy otherwise**. The workflow-identity
check in `ReceiverTemplate.onReport (:88-117)` is enforced **only when these expected values are non-zero**
(`x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol:143,184`); if ownership is handed off
first, the identity check is bypassed and any workflow the Forwarder accepts can call `onReport`. **Set
identity first (assert it), then transfer `Ownable` ownership to the Timelock** (§4.4/§17). **No controller-level operator-wiring
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
  → CRE Forwarder (Timelock-pinned; verifies DON sigs)
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

**Redeem path:** `ZipRedemptionQueue.requestRedeem(zipUSD)` (escrowed) → on-demand `settleEpoch()` (CRE cron,
after warehouse REDEEM→REPAY) par fill from freeable USDC → `claim`.

### 9.1 Local fork dev-harness (Anvil) — the item-10 stand-up target + RPC cost discipline

Item 10's deploy/wiring script (`DeployZipcode`, built — `DeployLocal`/`DeployMainnet` wrap it) targets a **persistent local Anvil forked off Base
mainnet** before it ever targets real Base. This is the dev/integration substrate: the whole Base-side system
(`ZipcodeOracleRegistry` → `CREGatingHook` → `EulerVenueAdapter` → `ZipcodeController`; the szipUSD Baal
substrate + `SzipNavOracle` + Exit Gate + `SzipUSD` + the 8 engine modules; `CreditWarehouse` + redemption
queue; loss side; `SzAlphaMirror` + its CCT pool) deployed + wired in dependency order, then exercised by the
`audit/2` S→L traces against live forked Euler/EulerEarn/ICHI/Hydrex/CCT-registry. (The **964 leg** — `SzAlpha`
over the Subtensor StakingV2 precompile — **cannot** run on a Base fork; it needs a separate Subtensor EVM fork
and is validated standalone, 8x-01.)

**Stand-up (the proven recipe, 8x-01 window):**
```
anvil --fork-url $BASE_RPC_URL --fork-block-number <PINNED> --chain-id 8453 --port 8545
# deploy with the well-known Anvil account 0 as the local team multisig:
#   TEAM_MULTISIG=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
#   key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/DeployZipcode.s.sol --rpc-url http://localhost:8545 --broadcast --slow --private-key <ANVIL0>
```
- **`--slow` is mandatory** for multi-tx broadcasts: without it Anvil drops txs from the mempool on nonce
  races (observed: the substrate summon failed without `--slow`, succeeded with it).
- **Pin `--fork-block-number`** (do NOT fork "latest"). A pinned block makes Foundry's on-disk RPC cache
  (`~/.foundry/cache/rpc/base/<block>/`) reusable across runs and makes fork tests deterministic — it also
  fixes the logged 8-B6 `DTL` flake (unpinned `createSelectFork("base")` = latest-block roulette).
- **Chain-id 8453** so contracts reading `block.chainid` behave as Base.
- The substrate summon is proven on this harness: `SummonSubstrate` deploys Baal + both Safes with
  `totalShares()==0` (inert), `avatar()` wired, and the team multisig an owner of both Safes.

**RPC compute-unit discipline (LOAD-BEARING — fork reads spend real Alchemy CUs).** Foundry persists every
fetched fork slot to a disk cache at **`~/.foundry/cache/rpc/<chain>/<block>/`** (Anvil and `forge` both write
it), keyed by **block number** (`--no-storage-caching` disables it — never set it). Reads only cost CUs on a
cache **miss**; an already-cached `(block, slot)` is free forever. Alchemy meters per call (e.g. `eth_call` ≈ 26
CU, `eth_getStorageAt` etc.) at ~500 CUPS, so an uncached heavy run burns millions of CUs needlessly — the goal
is not a CU *ceiling* (PAYG has ample credit) but **not wasting CUs on re-fetches that a pinned cache makes
free**. Rules, in impact order:
1. **PIN THE FORK BLOCK everywhere.** This is the dominant fix. The current suite uses unpinned
   `vm.createSelectFork("base")` (= "latest"), so **every run forks a different block and re-fetches the entire
   working set** — verified: the cache held **265 distinct block dirs / 654 MB**, i.e. near-zero reuse across
   runs. Pin one block (in `ForkConfig` + `foundry.toml`/Anvil `--fork-block-number`) → a single cache entry,
   reused across all future runs and Anvil restarts → steady-state ≈ 0 CU. (Also fixes the 8-B6 `DTL` flake.)
2. **Never run the heavy invariant/fuzz suites against a fork.** The 128k-call stateful invariants
   (`DefaultCoordinator`, `LienXAlphaEscrow`/8-Bx, `ZipRedemptionQueue`, `FreezeHandler`) touch enormous numbers
   of unique slots and have **no live-state dependency** — run them on the plain local EVM (`forge test`, no
   `--fork-url`) = **0 CU**. Running the *full* suite with `--fork-url` was the dominant CU burn in the 8x-01
   window and is forbidden. Fork only the tests that read live deployed contracts (Euler/EulerEarn/ICHI/Hydrex/
   CCT registry); tag them (`*Fork*` / `--match-path`).
3. **Persist Anvil's deployed state across restarts** with `--state state.json` (alias for `--dump-state` on
   exit + `--load-state` on start) so a stood-up + wired system survives a restart without re-deploying — and,
   with the block pinned (rule 1), the fork cache is reused too, so a restart is cheap.
4. **Throttle Anvil to the provider** with `--compute-units-per-second <N>` (default 330; set at/under the
   Alchemy 500 CUPS ceiling) rather than `--no-rate-limit`, so a burst can't trip provider rate limits.
5. Use **`--slow`** for the deploy broadcast (multi-tx nonce-race → dropped tx without it, observed 8x-01).

A full green run is therefore: **plain-EVM suite (0 CU) for the bulk + a small forked subset for the
live-contract integration**, against **one pinned, state-persisted Anvil** — not the whole suite forking a
fresh latest block and re-fetching from Alchemy.

**Default path:** CRE default report → junior coverage is already held by the **debt-pinned freeze floor** (the
staked LP counted in place via `pathLockedLpEquity`; the juniorTrancheSidecar is empty in normal operation, §11) — a default does
not move the freeze → `DefaultCoordinator` **writes a conservative provision into
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
> 1. **The Duration Bond freeze is a time-HOLD, not a loss.** It is the `DurationFreezeModule` debt-pinned
>    coverage floor that keeps junior coverage ≥ outstanding senior debt and gates the real outflows (buy-burn
>    `postBid`, LP `removeLiquidity`); the basket **keeps accruing while frozen**. It exists to pin the junior in
>    place during the resolution window so it cannot run (§6.4). **zipUSD itself never freezes** (the senior is
>    throttled only by the par redemption queue, §6.1).
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
>    auto-compounder (the vault's **core** CRE strategy, NOT a post-M1 bolt-on) continuously vamps USDC out of
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
**two parts**: (1) **provide the time via the FREEZE** (§6.4 — the `DurationFreezeModule` debt-pinned coverage floor keeps
junior coverage ≥ outstanding senior debt, with the staked LP counted in place (`pathLockedLpEquity`) and the
juniorTrancheSidecar empty in normal operation; the real outflows (CoW buy-burn, LP dissolution) are gated by `covered()` so the
backing can't exit below the floor while loans are live; the basket **keeps earning** — "frozen but earning"); AND (2) **carry a conservative provision
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
2. **Freeze (structural via the juniorTrancheSidecar — NOT a ragequit gate, NOT engaged by the coordinator).** The **Duration Bond
   FREEZE** is **already in place** — a default does not engage it. The junior equity committed to live credit lines
   is held by the **debt-pinned coverage floor** `requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`
   (the staked LP counted in place via `pathLockedLpEquity`; juniorTrancheSidecar empty in normal operation; `covered()` gates
   the real outflows, §6.4). A default simply keeps debt outstanding, so the floor **stays** binding until the line
   repays; the at-risk amount sizes the **NAV markdown** (the
   provision into `SzipNavOracle`, §7/§4.6), **not** the freeze. The committed backing **stays in place and keeps earning** (auto-compounder in the
   juniorTrancheSidecar; no escrow, no share-move, no markdown). **Implemented via Exit-Gate custody + the juniorTrancheSidecar (§6.4), not a
   ragequit gate** — Baal `ragequit` cannot be paused, so the freeze is the equity simply not being in the
   redeemable main Safe; the Exit Gate (sole Loot-holder) only clears CoW exits against the free main-Safe
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
lock of every szipUSD position for a fixed term, realized as the **juniorTrancheSidecar/utilization split** behind the Exit
Gate, §6.4; no per-position index, no SBT) fires on **either**:
- **(A) a default — loss-driven (the flow above).** A lien defaults → the debt-pinned coverage floor is **already
  binding** (the freeze was never "engaged"; it just doesn't relax while the line is unresolved) so the gated
  outflows can't take the backing below the floor → the at-risk amount sized from the deviation re-mark
  drives the **NAV markdown** (the provision, §7/§4.6) → the committed slice rotates back to the main Safe when the
  waterfall fills the hole and the line closes → the frozen cohort receives the **xALPHA premium**
  (`slashXAlphaToCohort`, the in-kind bond). **A conservative recoverable provision on NAV (§7), no share-escrow/burn,
  no ragequit gate** — the committed backing is simply not in the redeemable main Safe (the freeze).
- **(B) a duration squeeze — liquidity-driven, no realized loss.** A system-wide liquidity event (secondaries
  freeze, loans sit past schedule, utilization spikes and the pool cannot free USDC, §6.3) with **every loan
  performing**. The danger is a junior **run** that depegs zipUSD; because the at-risk equity is **committed in the
  juniorTrancheSidecar** (utilization high → it isn't rotated back to the redeemable Safe) and depositors hold no raw Loot (Exit
  Gate custody, §6.4), the run's instant-exit escape hatch is **structurally closed** — no ragequit gate needed.
  - **Trigger:** an **on-chain utilization floor**. `U` = the illiquid fraction of the senior backing
    (`U = 1 − maxWithdraw(CreditWarehouse)/convertToAssets(balanceOf(CreditWarehouse))` off the EulerEarn senior
    pool, §8.2; the §12 metric-4 early-warning) breaching a governed `U_lock` engages the lock automatically.
    Borrowing is controller-gated (§4.3) and the read is donation-immune (§8.2), so `U` is not outsider-manipulable
    — it moves only via real originations and real redemption pressure. An optional CRE "secondaries-down" report (a
    new `reportType`, modeled on the §8.4 default/recovery report) may trip it **earlier**, but cannot un-trip a live
    on-chain breach.
  - **Sizing:** see the as-built note below — the M1 floor is the **debt-pinned** `min(illiquidSeniorValue,
    grossBasketValue)`, NOT a `φ_B = U` fraction (the fraction/escalation model is superseded).
  - **Stacking with (A):** a position's effective lock is `max(φ_A, φ_B)`, capped at `1.0` — the same shares
    serve the larger need; never summed. Each lock releases on its own condition; a governed `maxDuration`
    backstops both.
  - **Release:** auto-releases when free liquidity recovers — `U` falls below `U_lock − releaseHysteresis`
    (the hysteresis prevents flap).
  - **As-built (M1 `DurationFreezeModule`) — SUPERSEDES the `freeze% = utilization%` model above.** The floor is
    NOT `requiredFraction(U) = U` / `juniorTrancheSidecar ≥ U × grossBasketValue` (that fraction model is superseded); it is the
    **debt-pinned absolute** `requiredCommittedValue = min(illiquidSeniorValue, grossBasketValue)`, checked against
    `coverageValue = committedValue + pathLockedLpEquity` (the staked LP counted in place, juniorTrancheSidecar empty in normal
    operation), with `covered()` gating the real outflows. `requiredFraction()`/`utilization()` are retained only as
    the §12 metric. The escalation/binary-lock params (`U_lock`/`U_max`/`maxLockFraction`/`maxDuration`/
    `releaseHysteresis`) are NOT built for M1. Full mechanism: `build/wires/DurationFreezeModule.md`.
  - **Compensation: none beyond the continuing yield.** The Duration Bond premium *is* the slashed xALPHA bond;
    a squeeze slashes nothing, so it pays **no premium** — and needs none: the loans are performing and
    accruing at the fixed credit-line rate (§3 IRM; §10 "the line simply accrues"), with the perf-fee routed
    to szipUSD elevated by high utilization (§5). The locked junior keeps earning (the "boosted-yield bond");
    §12 metric 3 displays this elevated while-locked APR. No protocol surplus is spent (it stays as the senior
    cushion, §2/§12) and no treasury xALPHA is spent (avoiding the §6.2/§7 peg reflexivity).
  - **Senior side:** no new mechanism — the par queue settles on-demand from REPAY-delivered USDC
    (§6.1); the only senior lever is pacing new draws against pending redemptions (§6.3 / §8.2). The
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
On default the at-risk junior backing is held in place by the **debt-pinned coverage floor** (§6.4/§11; exit is
CoW-only, no ragequit) while time + the recovery waterfall (legal recovery → insurance → xALPHA bond → HYDX-vamped USDC)
bring **external** USDC to repay the loan — the dominant effect is **duration, not loss** (insured/
collateralized HELOC). A genuine shortfall is carried as a **pari-passu conservative provision-that-recovers**
written into **`SzipNavOracle`** (§7/§11): junior `navPerShare` marks down at recognition (small, because
recovery is high) and **writes back up on verified recovery**; the loss is borne **pari passu by every szipUSD
holder via the lower share price**, never by a per-holder share-burn, and only after the junior is exhausted is
the senior at risk.

**Impairment routing — where the "bad-loan" signal lands.** The premise that there is "no
loan-marked-bad signal" is **wrong**: `DefaultCoordinator.writeProvision` writes the impairment into the **junior**
`SzipNavOracle` NAV, so the junior `ExitGate` CoW exit **self-prices on impairment continuously** (an exiter sells
into a marked-down NAV). The **senior par queue** (`ZipRedemptionQueue`, §6.1) is **intentionally impairment-blind** —
it pays strict $1 par regardless — because it is **single-requester treasury-internal plumbing**, not an open creditor
queue: the rq Safe escrows its **own** idle basket zipUSD and claims its own par USDC. The on-chain `MultipleRequesters`
guard is the **sole** defense keeping it single-requester, so **`redeemController` must never be set to an untrusted
party** (an untrusted requester could redeem at par ahead of an impairment the senior queue does not see). The
Maple/Centrifuge impaired-rate / pro-rata comparison applies to open multi-requester queues, **not** this design — no
pro-rata machinery belongs in the senior queue.

**Junior NAV-per-share (`SzipNavOracle`) — the issuance/exit pricing primitive (§7), not display-only.** The
junior is a **transferable szipUSD share** the Exit Gate mints **NAV-proportionally** against soulbound Loot it
custodies over a **Baal/Moloch-v3 Safe basket** (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP, §4.5).
`SzipNavOracle` (`is ReceiverTemplate`, §7) computes `navPerShare = basketNAV / szipUSD.totalSupply()`
**on-chain**: it **reads all quantities on-chain** (balances across the main + juniorTrancheSidecar Safes incl. the
**staked** ICHI LP), CRE-**pushes only** the off-chain leg prices it cannot read on Base (the xALPHA
`alphaUSD` leg; HYDX if thin), and maintains an **on-chain cumulative TWAP accumulator** (window `W ≈ 4h`,
§17). Issuance prices at `navEntry = max(spot, twap)`, exit at `navExit = min(spot, twap)` (protecting resident
holders both directions). The Gate's exit is the **CoW book**: the treasury's buyback bids at **`navExit×(1−d)`**
and burns the fill (§6.4) — **NAV drives the exit price** via the bid; the protocol **never reads the szipUSD CoW
market price for accounting** (§7). The basket compounds off the
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
   **off-chain insurance** coverage (Proof of Insurance, §8.10).

Both pricing inputs feed this (§7): the **Proof of Value** equity mark → the zipUSD dollar NAV; the xALPHA
price feed → the **Duration Bond premium** NAV and the szipUSD bonus APR (metric 3). Off-chain insurance
coverage is attested separately (Proof of Insurance, §8.10), not via a price feed. All are required for
solvency reporting.

These metrics are aggregates over §9 events + pool state, served to the frontend via an off-chain indexer
(the subgraph workstream, `README.md` §4) — not computed per-request on-chain. The peg is the secondary-AMM
price (§6.2); off-chain insurance coverage is a CRE-published figure (§8.10).

---

## 13. Trust & security model

- **Trust-minimized:** **f+1 DON consensus** on every report — at launch the signer is a **standard
  Chainlink CRE DON** (Shape B, §7), with the Zipcode subnet becoming the DON as the endgame (Shape A);
  `ReceiverTemplate` workflow-identity check behind a **Timelock-pinned Forwarder** (the
  `setForwarderAddress`/identity setters are `onlyOwner`; per §17 ownership transfers to the Timelock after
  identity wiring — immutability is the deferred pre-prod lock-down, not a renounce, §4.4); the venue's
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
  by **per-line frozen price routers** + Timelock-pinned Forwarder, and by making the controller the only privileged
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
**zap** (deposit USDC → mint zipUSD → auto-stake szipUSD), the depositor return is the **xALPHA** subsidy (lending yield privatized protocol-side, §5/§17), and an
on-demand par redemption settles. This is the fundable proof of operations.

**Milestone 2 — loss / default flow.** Exercises an engineered default: deviation Proof re-mark → `DefaultCoordinator`
**writes a conservative provision into `SzipNavOracle`** (the debt-pinned coverage floor is already holding the backing — the coordinator does not engage the freeze) → **Duration Bond** →
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
| `cre-templates` | Go CRE workflow project layout / scaffold (build aid, §8) |
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
- **Junior exit = the CoW book** (a resting szipUSD sell order *is* the queue; the treasury fills just-in-time via
  8-B14 buy-and-burn priced `≤ navExit×(1−d)`, or an external buyer fills; an unfilled holder simply stays in the
  vault, still earning) — §6.4; **not** a fixed cooldown and **not** an on-chain intent queue / liquidity window
  (the `requestExit`/`processWindow` forfeit path is retired). The **coverage floor is the freeze itself**
  (structural, not a governed knob). *(Supersedes "≈30d sUSD3 cooldown" and the "liquidity-window / partial-fill"
  framing.)*
- **Systemic-squeeze params** — M1 has **none governed**: the freeze floor is the **debt-pinned** `requiredCommittedValue
  = min(illiquidSeniorValue, grossBasketValue)` (`requiredFraction`/`U` retained only as the §12 metric, not the floor; §11-B). The escalation band (`U_lock`, `U_max`, `maxLockFraction`) + `maxDuration`/`releaseHysteresis` (the Duration
  Bond's liquidity-driven trigger B, §11) are **post-M1, not built**; metric-4 utilization (§12) is the trigger input.
- **Junior accounting unit** *(two-token model, 2026-06-07)* — the junior is a **transferable szipUSD ERC-20
  share** the **Exit Gate** mints **NAV-proportionally** 1:1 against soulbound Baal Loot it holds, over a Baal Safe
  basket (zipUSD + xALPHA + the ICHI LP). **NAV (`SzipNavOracle`, §7) IS the issuance/exit pricing primitive** (not
  display-only). **Exit:** sell szipUSD on the **CoW book** (§6.4/§6.2) — treasury buys at `navExit×(1−d)` + burns.
  **Depositor return = NAV accretion** (HYDX-vamp free value recycled into the basket, 8-B10; lending fee → warehouse over-collateralization, future treasury). **First-loss = a pari-passu
  conservative provision-that-recovers** (§11): the freeze handles duration; a small conservative markdown is
  written at recognition and recovers on verified facts. Pari passu inside the junior; no subordination cap.
  Substrate = Baal + Zodiac (§4.5).
- **xALPHA bond sizing** — a first-loss percentage (target ~5–15%, warehouse-equity range), not 100% of lien value.
- **Always-liquid micro-reserve** — whether a small reserve sits outside the venue pool to smooth small
  redemptions between settlements.

**Resolved — the locked decisions (current state; items revised in the 2026-06-03 model rewrite are flagged):**
- **Cash-reserve ratio** → **fixed-%** (dynamic = later parameter swap), §8.2.
- **Senior redemption** → **on-demand par-burn queue** (treasury-internal, single-requester; AMM is the early-exit path), §6.1. *(Supersedes the 30-day epoch + pro-rata.)*
- **Duration Bond + haircut** → governed params with defaults (≈180d / ≈0.65), §11. *(revised: "term-lock" →
  Duration Bond; trigger = default OR duration squeeze.)*
- **xALPHA mark** → **two-layer**: the LST **exchange rate** (`staked alpha ÷ supply`, stake accounting — no pool
  price) × **`alphaUSD`** (subnet TAO/alpha AMM **TWAP** × TAO/USD); only the `alphaUSD` market leg is TWAP'd +
  guarded, §7. *(Refines "CRE-reported feed, no DEX TWAP" — the value-bearing layer is stake accounting; the market
  leg is the subnet-AMM TWAP, not an Ethereum DEX.)*
- **Junior unit** → **transferable szipUSD share** the Exit Gate mints **NAV-proportionally** vs soulbound Loot;
  **CoW exits** (windowed-RQ retired); **NAV is the pricing primitive** (`SzipNavOracle`, §7); depositor return = HYDX-vamp
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
- **Junior = a transferable szipUSD share over a Baal Safe basket — SUPERSEDED by the 2026-06-07 two-token model
  above; this 06-06 bullet is retained only as history.** Current model: the Exit Gate mints **transferable szipUSD
  NAV-proportionally** against soulbound Loot it custodies; the Safe holds the basket (zipUSD + xALPHA + the ICHI
  LP); **exit = the CoW book** (NOT raw ragequit); **NAV (`SzipNavOracle`) IS the issuance/exit pricing primitive**
  (NOT display-only); first-loss = the pari-passu provision-that-recovers (§11). Depositor return = NAV accretion
  (HYDX-vamp) + the xALPHA subsidy; the lending yield is the protocol's. (The 06-06 raw-ragequit / NAV-for-display
  framing and the deleted WOOF-07 pool-share model are both superseded — see §2/§4.5/§6.4.)
- **Per-line isolated markets with per-line frozen routers** *(revised — per-line-router design, this session;
  supersedes the earlier single-shared-router-fallback "F4")* — each line is its own isolated EVK market
  (escrow collateral vault + USDC borrow vault + a dedicated `EulerRouter`), minted and wired inside the venue
  adapter's `openLine` (§4.7) and **frozen** (`transferGovernance(address(0))`). The per-line router resolves
  `escrowVault → LIEN_i → ZipcodeOracleRegistry`, so origination still writes `cache[LIEN_i]` directly (oracle
  key unchanged, §4.1/§4.2) with **no per-lien `govSetConfig` on a shared/timelocked router** and **no timelock
  conflict** with the atomic origination batch (§4.1/§4.4a). Stronger than the old shared fallback: a line's
  price wiring can never be re-pointed.
- **Build phase: ONE Timelock admin, ALL wiring Timelock-settable (NOT immutable / NOT renounced)** *(revised
  2026-06-09, user-ratified — supersedes the earlier "seal the immutable Forwarder by renouncing `Ownable`" lock
  AND the per-contract set-once `AlreadyWired` freezes).* While the system is a rough draft on mock data, **every
  contract carries a single Timelock owner and every cross-component wiring slot is re-pointable by that owner**
  — the CRE `setForwarderAddress` + workflow-identity (`setExpectedAuthor`/`setExpectedWorkflowId`), the oracle
  pointers, the safe addresses, the inter-component pointers (controller/venue/escrow/gate/coordinator/oracle/
  tokens), the engine-module `operator` + vault/gauge wiring, and governed values (`recoveryFloor`). **Rationale:**
  the oracles/safes are still being built (e.g. the NAV oracle may take several redeploys) — making wiring settable
  turns a component redeploy into a **one Timelock call re-point** instead of a cascade of dependent redeploys (a
  NAV-oracle redeploy otherwise cascades through coordinator → escrow → gate → szipUSD → zap; §17 trace). The
  engine modules already had this shape (Timelock owner + CRE operator); this generalizes it. **The single
  exception:** `LienCollateralToken.controller` stays immutable — it is a per-line disposable token, not
  re-pointable infrastructure (open a new line to change it). **No fund-extraction path was added anywhere** — no
  `sweep`/`rescue`/`pause`; the only new power is re-pointing wiring, gated by the 2-day Timelock veto. The EVK
  hooks (`CREGatingHook`, `ReservoirBorrowGuard`) use a **manual `owner`/`onlyOwner`** (checking raw `msg.sender`),
  NOT OZ `Ownable`, because the inherited `Context._msgSender()` would collide with the hook's EVK trailing-data
  `_msgSender()` decoder. **Governance MUST never set a CRE Forwarder to `address(0)`** (`ReceiverTemplate`
  disables Forwarder validation at zero and emits a `SecurityWarning`).
  - **DEFERRED to the pre-production lock-down (a future §17 decision):** re-freezing wiring to `immutable`/set-once
    where appropriate and deciding the final owner posture per contract (renounce vs keep the Timelock). Until then
    the **Timelock + 2-day veto is the safety boundary**, not code-level immutability. The build reports + the
    `LienXAlphaEscrow` destination-integrity / `SzipNavOracle` provision-bound theses note where re-freezing
    restores a stronger guarantee.
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
  junior coverage is **already** held by the debt-pinned coverage floor (`min(illiquidSeniorValue, gross)`; LP counted
  in place; juniorTrancheSidecar empty in normal op; §6.4 — not engaged by the coordinator), and `DefaultCoordinator` writes a **small conservative provision** into
  `SzipNavOracle` at recognition (`recoveryFloor`
  HIGH, §7/§17) that **re-marks on a staircase of verified facts** (Proof-attested foreclosure milestones / realized
  receipts) and **writes back up**, trued-up at resolution. The waterfall (secondary → insurance → xALPHA bond →
  HYDX-vamped USDC) fills the hole; an unrecoverable residual is the marked loss (pari passu). `LienXAlphaEscrow`
  holds the xALPHA bond; the loss-side contracts (`DefaultCoordinator` / `LienXAlphaEscrow` + the **Foreclosure
  Proof oracle**) are **M2** (§11/§4.6).

**Resolved 2026-06-05 (supply-side redesign — user-directed + ratified):**
- **xALPHA — one token.** The liquid-staked Zipcode-subnet
  alpha (LST), bridged via CCIP (§2, `build/wires/8x-01-szALPHA-bridge.md`). One token does first-loss bond /
  Duration-Bond premium / szipUSD incentive / zipUSD-xALPHA POL leg / last-resort backstop (alpha→TAO→USDC) /
  treasury buyback target. (The M2-sketch loss-side names are now `LienXAlphaEscrow` / `slashXAlphaToCapital` /
  `slashXAlphaToCohort` / `lockXAlpha` / `releaseXAlpha`.)
- **szipUSD collapses sdVAULT into one token.** *(SUPERSEDED by the 2026-06-07 two-token model: a transferable szipUSD share + soulbound Loot, §2.)* The junior is a single **freezable vault share** (named
  szipUSD); the Hydrex/oHYDX autocompounder is a **post-M1 yield-engine module** that bolts onto the same vault,
  not a second token (§4.5).
- **The Duration Bond freeze = a redemption-gate-with-boost, not a seizure.** *(SUPERSEDED: the freeze is the debt-pinned coverage floor; senior throttle = the on-demand par queue, not an epoch.)* Pro-rata share subset, accrues
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
  **seeded xALPHA emission** (post-M1 treasury budget, TBD); the **treasury buyback strategy that recycles the
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
  hard ceiling) → so the per-line-account model is no longer the limiter. **The binding ceiling is now the
  EulerEarn withdraw-queue cap (~28 lines/pool)** — the CTR-02..10 sharding workstream scales it across pools. The whole per-loan cluster (borrower
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
vault (zipUSD/xALPHA ICHI LP + CRE oHYDX autocompounder; `auto-compounder.md`) — **not a separate token** · **zap**
deposit → mint zipUSD → auto-stake szipUSD in one tx · **zipCRED** a future RWA token (tokenized credit) ·
**xALPHA** — the **one** liquid-staked Zipcode-subnet alpha (LST), bridged via CCIP
(`build/wires/8x-01-szALPHA-bridge.md`): per-lien first-loss bond + Duration-Bond premium + szipUSD incentive +
zipUSD/xALPHA POL leg + last-resort backstop (alpha→TAO→USDC) + treasury buyback target · **markdown**
event-driven recovery-aware debt-value haircut (`debt − equity
mark × haircut`; set at the deviation Proof re-mark, not continuous, not time-linear) · **settle** write-off
of unrecoverable debt on a recovery shortfall (after insurance + xALPHA) · **Duration Bond** the lock mechanism:
the debt-pinned coverage floor holds junior coverage ≥ outstanding senior debt and gates junior outflow, resolving
with the xALPHA premium on a default; fires on **default OR a duration squeeze** — no per-position index or claim token · **NPL**
non-performing loan (a transferable recovery-claim market is a possible future feature, not built).

---

## 19. Explicitly NOT using

- **`PegStabilityModule`** (instant 1:1 swap peg) — replaced by `ZipDepositModule` (1:1 mint) + the on-demand
  par queue. The PSM has no queue (it reverts when its reserve is short), which doesn't fit lent-out cash.
- **`EulerSavingsRate`** (gulp / 2-week smear) — replaced by EulerEarn's native perf-fee routing (§5).
- **3Jane `UserCooldown`** — **dropped entirely.** The senior (zipUSD) redemption is an **on-demand par-burn
  queue** (§6.1; the 7540 async-redeem base + pro-rata machinery were collapsed out). The junior (szipUSD) exit is
  the **CoW book** (§6.4), **NOT** a cooldown — the `sUSD3`-style per-staker cooldown was retired; run-deterrence
  comes from the Exit-Gate-custody / no-raw-Loot topology + the debt-pinned coverage floor.
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

*Plain-language narrative: the [Vision](./README.md#vision) section of `README.md`. Build plan / per-team task map: [`README.md`](./README.md).
Off-chain leg (SPV custody + Proof attestation): [`spv-lien-proof.md`](./pending-docs/spv-lien-proof.md). The venue-agnostic
boundary is §4.7.*
