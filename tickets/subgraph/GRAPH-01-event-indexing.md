# GRAPH-01 — zipcode-euler subgraph: event indexing (schema + manifest + mappings) (README §348 / §9 / §12)

> **Frontend-track / build-only.** The **subgraph** is the history + aggregation layer the Vue UI queries
> (README §348: subgraph owns history/aggregation, the frontend reads cheap point-in-time values directly). Its
> `schema.graphql` is a **binding surface for the UI exactly like the contract ABIs** — so it LEADS the frontend,
> it does not trail it. This ticket is **GRAPH-01: the indexing recipe** (entities + manifest + mappings + a
> Matchstick unit per handler). The five dashboard **metrics** derived on top of these entities are **GRAPH-02**
> (`GRAPH-02-metric-derivation.md`); build GRAPH-01 entities first, GRAPH-02 formulas on top.
>
> **The contract is the truth.** Every datasource ABI and every event signature in this ticket was extracted from
> the **built code** via `cd contracts && forge inspect <Contract> abi` (and the source `event` declarations for
> the param names) — NOT hand-typed from §9 prose. A handler for an event no contract emits is a gate failure.
> The exact signatures are pinned in §2 below with their `selector` so the builder can cross-check.
>
> **The one non-obvious thing (do not miss it): per-line markets are DYNAMIC data-source TEMPLATES.** The venue
> mints a fresh isolated Euler market **per line inside `openLine`** (`EulerVenueAdapter.openLine:109` →
> `new LineAccount{salt}` + two `eVaultFactory.createProxy` + `new EulerRouter`; the addresses do **not** exist at
> manifest time). The borrow vault `lineRef` (= `evault`, `:167`) and the collateral vault are runtime addresses.
> In The Graph this is a **data-source template** instantiated from the `LineOpened` handler via
> `LineBorrowVault.create(lineRef)`. A manifest that lists markets statically **cannot work** — there is no fixed
> market address. (§4 below.)
>
> **NAV: index the oracle's OUTPUTS, never recompute.** `SzipNavOracle` composes NAV on-chain (hybrid compose +
> windowed TWAP + bracket + provision). The subgraph stores `Poked` / `LegPriceUpdated` / `ProvisionWritten` as a
> `NavSnapshot` time-series — it does **not** compute NAV. A second, divergent NAV is the worst failure class.
> Live NAV-per-share is a frontend `navEntry()`/`navExit()` direct read (GRAPH-02 §NAV).

**Deliverable**
A cold-buildable subgraph package under a new `subgraph/` tree at repo root:
- `subgraph/schema.graphql` — the entities + fields of §3.
- `subgraph/subgraph.yaml` — the manifest: the fixed-address datasources of §2 + the per-line **template** of §4.
- `subgraph/src/*.ts` — one AssemblyScript mapping module per datasource (the handlers of §5).
- `subgraph/abis/*.json` — the ABIs, copied from `contracts/out/<C>.sol/<C>.json`'s `.abi` (or `forge inspect <C>
  abi`). **No hand-authored ABIs.**
- `subgraph/tests/*.test.ts` + `subgraph/matchstick.yaml` — the Matchstick unit plan of §6 (one per handler).
- `subgraph/networks.json` + `package.json` (deps: `@graphprotocol/graph-cli`, `@graphprotocol/graph-ts`,
  `matchstick-as`).

**Acceptance (the cold-build gate — `audit/adversarial-spec/track-gates.md` "Subgraph").** The graph CLI is **not
installed in this repo**, so codegen/build is the **deferred acceptance step**: a fresh builder runs `graph
codegen` + `graph build` green against the `forge inspect`-extracted ABIs, and `graph test` (Matchstick) green
with one unit per handler proving the entity field GRAPH-02 reads is written. Authored to BE cold-buildable now;
the only placeholders are the item-10 addresses/startBlocks (§2, §7).

**Spec §**
- `README.md` §348 — the stack: subgraph-for-history + direct-reads-for-point-in-time (the GRAPH-02 boundary).
- `claude-zipcode.md` §9 — the raw event list (this ticket is the subgraph recipe §9 is NOT).
- `claude-zipcode.md` §12 — the on-chain NAV model (why NAV is indexed-from-outputs, never recomputed).
- The emitting contracts: `ZipcodeController.sol`, `LienTokenFactory.sol`, `ZipcodeOracleRegistry.sol`,
  `venue/EulerVenueAdapter.sol`, `supply/ZipDepositModule.sol`, `supply/ZipRedemptionQueue.sol`,
  `supply/szipUSD/ExitGate.sol`, `supply/szipUSD/DurationFreezeModule.sol`, `supply/SzipNavOracle.sol`,
  `supply/SzipReservoirLpOracle.sol`, `loss/LienXAlphaEscrow.sol`, `loss/DefaultCoordinator.sol`, plus the engine
  modules (`supply/szipUSD/{LpStrategy,ReservoirLoop,HarvestVote,Exercise,Sell,Recycle,SzipBuyBurn}Module.sol`).

---

## 1. Architecture: which contract is the emitter, and the two join keys

The protocol has **two universal keys**; everything hangs off them.

- **`lienId : Bytes!`** — the universal join key for the **senior loan lifecycle**. The controller, the lien-token
  factory, the xALPHA escrow, and the default coordinator **all key on `lienId`**. (`bytes32` in every emitter.)
- **`lineRef : Bytes!`** — keys the **venue's isolated market** (= the borrow EVault address; see §4). The venue
  events all key on it.

**The `lienId`↔`lineRef` correlation is RESOLVED (open-Q #1):** it is **explicit and same-tx, carried in a single
event**. `ZipcodeController._open` (`:140`) calls `VENUE.openLine(lienId, lien, FULL_LIEN)` (`:161`) which returns
`lineRef`, then emits

```
LienOriginated(lienId, lien, lineRef, proofRef, equityMark, drawAmount)   // ZipcodeController.sol:76
```

— `lienId` AND `lineRef` are **both fields of the same event** (`:79` `address lineRef`). The handler does **not**
need to infer the join from same-tx heuristics; it reads `lineRef` straight off `LienOriginated`. The venue's own
`LineOpened(lienId, lineRef, …)` (`EulerVenueAdapter.sol`, see §2) **also** carries both keys, so the join is
double-pinned. **Decision: bind `Line.lien` and `Lien.line` from `LienOriginated` (the controller is authoritative
for the pair); use `LineOpened` to populate the per-line vault addresses + spawn the template.**

Datasource roles:

| Datasource | Address | Emits (indexed here) | Keys |
|---|---|---|---|
| `ZipcodeController` | fixed (item-10) | `LienOriginated` `LienDrawn` `LienReleased` `LienStatusUpdated` | `lienId` (+`lineRef` on Originated) |
| `LienTokenFactory` | fixed (item-10) | `LienCreated` | `lienId`→`lien` |
| `ZipcodeOracleRegistry` | fixed (item-10) | `RegistryPriceSeed` `RegistryPriceUpdated` | `lien` (token addr) |
| `EulerVenueAdapter` | fixed (item-10) | `LineOpened` `LineLimitsSet` `LineFunded` `LineDrawn` `LineClosed` | `lineRef` (+`lienId` on Opened) |
| `ZipDepositModule` | fixed (item-10) | `Deposited` `Zapped` | `user` |
| `ZipRedemptionQueue` | fixed (item-10) | `RedeemRequest` `EpochSettled` `Withdraw` | `requestId`/`epoch` |
| `ExitGate` | fixed (item-10) | `Deposited` `ExitRequested` `ExitFilled` `ExitCancelled` `WindowProcessed` `Burned` | `requestId` |
| `DurationFreezeModule` | fixed (item-10) | `Committed` `Released` | `asset` |
| `SzipNavOracle` | fixed (item-10) | `LegPriceUpdated` `ProvisionWritten` `Poked` | (singleton) |
| `SzipReservoirLpOracle` | fixed (item-10) | `LpMarkUpdated` | (singleton) |
| `LienXAlphaEscrow` | fixed (item-10) | `Locked` `Released` `SlashedToCapital` `SlashedToCohort` | `lienId` |
| `DefaultCoordinator` | fixed (item-10) | `BondLocked` `BondReleased` `Defaulted` `Recovered` `Resolved` `WrittenOff` | `lienId` |
| engine modules (7) | fixed (item-10) | the engine telemetry of §2.7 | (singleton each) |
| **`LineBorrowVault`** (TEMPLATE) | **runtime** (§4) | EVK `Borrow` `Repay` `Liquidate` | `lineRef`=event address |

> **Interface vs emitter (open-Q #4, RESOLVED):** `LineOpened`/`LineLimitsSet`/`LineFunded`/`LineDrawn`/`LineClosed`
> are **declared** on `IZipcodeVenue` but **emitted by the concrete `EulerVenueAdapter`** (`emit LineOpened(...)` at
> `EulerVenueAdapter.sol:172`). Bind the datasource to the **adapter's** deployed address + **adapter's** ABI, not
> the interface. (`forge inspect EulerVenueAdapter abi` carries all five.)

---

## 2. The event surface — exact signatures (forge-inspect verified)

Every row below is `forge inspect <C> abi`-verified (selector pinned); param names are from the source `event`
declaration. **Do not write a handler for any event not in this section.**

### 2.1 Origination / lien lifecycle — `ZipcodeController`
```
event LienOriginated(bytes32 indexed lienId, address indexed lien, address lineRef, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)
  // selector 0x7e8fc817…  ZipcodeController.sol:76
event LienDrawn(bytes32 indexed lienId, uint256 equityMark, uint256 drawAmount)        // 0xdbce43b9…  :84
event LienReleased(bytes32 indexed lienId)                                              // 0x5c70e2ed…  :85
event LienStatusUpdated(bytes32 indexed lienId, uint8 status)                          // 0x0798e694…  :86
```
(Ignore the CRE-base config events `ExpectedAuthorUpdated`/`ExpectedWorkflowIdUpdated`/`ForwarderAddressUpdated`/
`OwnershipTransferred`/`SecurityWarning` — config provenance, not dashboard data; index only if a config/audit
panel is added — open-Q deferred to GRAPH-02 §boundary, decided NO for M1.)

### 2.2 Lien token binding — `LienTokenFactory`
```
event LienCreated(bytes32 indexed lienId, address indexed lien)                        // 0x5a918011…  LienTokenFactory.sol:18
```

### 2.3 Origination equity mark + revaluation — `ZipcodeOracleRegistry`
```
event RegistryPriceSeed(address indexed lien, uint256 price)                           // 0x0523d598…  ZipcodeOracleRegistry.sol:60
event RegistryPriceUpdated(address indexed lien, uint256 price, uint48 timestamp)      // 0xe5fb9eca…  :62
```

### 2.4 Venue isolated market — `EulerVenueAdapter` (emitter of the `IZipcodeVenue` events)
```
event LineOpened(bytes32 indexed lienId, address indexed lineRef, address oracleKey, address collateralVault, address router, address borrowAccount)
  // 0xe1c19d5e…  IZipcodeVenue.sol:17 (emitted EulerVenueAdapter.sol:172)
event LineLimitsSet(address indexed lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap)   // 0x4752ac04…
event LineFunded(address indexed lineRef, uint256 amount)                              // 0x4126d7aa…
event LineDrawn(address indexed lineRef, uint256 amount, address receiver)             // 0x9490a497…
event LineClosed(address indexed lineRef)                                              // 0x92504949…
```
> `LineOpened` carries the **four per-line addresses** the §4 template needs: `lineRef` (borrow vault),
> `collateralVault`, `router`, `borrowAccount` (+ `oracleKey` = the lien token).

### 2.5 Senior supply / redemption
```
// ZipDepositModule
event Deposited(address indexed user, uint256 usdcIn, uint256 zipMinted)               // 0x73a19dd2…  ZipDepositModule.sol:78
event Zapped(address indexed user, uint256 usdcIn, uint256 zipMinted, uint256 shares)  // 0x8254cb15…  :79
// ZipRedemptionQueue
event RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares)   // 0x1fdc681a…  ZipRedemptionQueue.sol:128
event EpochSettled(uint256 indexed epoch, uint256 indexed era, uint256 pending, uint256 filledShares, uint256 fillAssets, uint256 availableAssets)   // 0xc6844e41…  :133
event Withdraw(address indexed sender, address indexed receiver, address indexed controller, uint256 assets, uint256 shares)   // 0xfbde797d…  :142
```

### 2.6 Junior vault (Exit Gate) + structural freeze
```
// ExitGate
event Deposited(address indexed receiver, address indexed asset, uint256 amount, uint256 value, uint256 shares)   // 0x8bab6aed…  ExitGate.sol:85
event ExitRequested(uint256 indexed requestId, address indexed owner, uint256 shares)  // 0x2d548901…  :86
event ExitFilled(uint256 indexed requestId, address indexed owner, uint256 shares)     // 0x82662a56…  :87
event ExitCancelled(uint256 indexed requestId, uint256 remainder)                      // 0xc50c4885…  :88
event WindowProcessed(uint256 claimsFilled, uint256 queueHead)                         // 0x4cb52f18…  :89
event Burned(uint256 amount)                                                           // 0xd83c6319…  :90
// DurationFreezeModule (the utilization-sized structural freeze)
event Committed(address indexed asset, uint256 amount, uint256 committedValueAfter)             // 0xd9fbb97b…  DurationFreezeModule.sol:86
event Released(address indexed asset, uint256 amount, uint256 committedValueAfter, uint256 floor)   // 0x7b381718…  :88
```
> **Name clash:** `ZipDepositModule.Deposited`, `ExitGate.Deposited`, and EVK `Deposit` are distinct events on
> distinct datasources/ABIs. AssemblyScript handler names are per-module (`handleDepositModuleDeposited`,
> `handleGateDeposited`) — no collision.

### 2.7 Junior engine telemetry (`EngineAction` — operator dashboard; §5.8)
```
// LpStrategyModule
event LiquidityAdded(uint256 deposit0, uint256 deposit1, uint256 shares)   // LpStrategyModule.sol:60
event Staked(uint256 lpAmount)            // :61
event Unstaked(uint256 lpAmount)          // :62
// ReservoirLoopModule
event CollateralPosted(uint256 lpAmount)  // ReservoirLoopModule.sol:72
event Borrowed(uint256 usdcAmount)        // :73
event Repaid(uint256 usdcAmount)          // :74
event CollateralWithdrawn(uint256 lpAmount)   // :75
// HarvestVoteModule
event RewardClaimed()                     // HarvestVoteModule.sol:62
event Locked(uint256 amount, uint256 nftId)   // :63   (NB distinct from the escrow's Locked(bytes32,…))
event Voted(address[] poolVote, uint256[] weights)   // :64
event RebaseClaimed(uint256[] tokenIds)   // :66
// ExerciseModule / SellModule / RecycleModule / SzipBuyBurnModule
event Exercised(uint256 amount, uint256 paymentAmount)   // ExerciseModule.sol:62
event Sold(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)   // SellModule.sol:75
event FreeValueCredited(uint256 amount, uint256 newAccrued)   // RecycleModule.sol:80
event FreeValueSpent(uint256 amount, uint256 newAccrued)      // :81
event Recycled(uint256 usdcAmount, uint256 zipMinted)         // :82
event BidPosted(...)                       // SzipBuyBurnModule.sol:111   (CoW order uid + amounts; decode minimal)
event BidCancelled(bytes uid)              // :114
```

### 2.8 NAV oracle OUTPUTS (the pricing primitive — index, never recompute)
```
// SzipNavOracle   (leg constants: LEG_ALPHA_USD = 0, LEG_HYDX_USD = 1  — SzipNavOracle.sol:43/:45)
event LegPriceUpdated(uint8 indexed leg, uint256 price, uint48 ts)     // 0x0af876a9…  SzipNavOracle.sol:127
event ProvisionWritten(uint256 provision)                             // 0x38f2008c…  :128
event Poked(uint32 ts, uint256 cumNav)                                // 0xd16b9894…  :129
// SzipReservoirLpOracle
event LpMarkUpdated(uint256 mark, uint32 timestamp)                   // 0xf57eb375…  SzipReservoirLpOracle.sol:54
```

### 2.9 Loss side
```
// LienXAlphaEscrow
event Locked(bytes32 indexed lienId, address indexed originator, uint256 amount)       // 0x515a19a1…  LienXAlphaEscrow.sol:85
event Released(bytes32 indexed lienId, address indexed originator, uint256 amount)      // 0xc8fa66df…  :87
event SlashedToCapital(bytes32 indexed lienId, uint256 amount)                          // 0x0ff211ce…  :89
event SlashedToCohort(bytes32 indexed lienId, uint256 amount)                           // 0x5d02e002…  :91
// DefaultCoordinator
event BondLocked(bytes32 indexed lienId, address indexed originator, uint256 amount)    // 0xc9e330a6…  DefaultCoordinator.sol:113
event BondReleased(bytes32 indexed lienId)                                              // 0x93af6c07…  :114
event Defaulted(bytes32 indexed lienId, uint256 atRisk, uint256 provision)              // 0x4a930897…  :115
event Recovered(bytes32 indexed lienId, uint256 recoveryProceeds, uint256 remainingProvision)   // 0xd0ec9f9a…  :116
event Resolved(bytes32 indexed lienId, uint256 capitalSlashAmount)                      // 0x1df120a9…  :117
event WrittenOff(bytes32 indexed lienId, uint256 capitalSlashAmount)                    // 0xd9a0b59e…  :118
```
> Both `LienXAlphaEscrow.Released(bytes32,address,uint256)` and `DurationFreezeModule.Released(address,…)` exist —
> different ABIs/datasources, per-module handler names (`handleEscrowReleased`, `handleFreezeReleased`).

### 2.10 Per-line borrow vault (TEMPLATE ABI — Euler EVK `EVault`)
From `reference/euler-vault-kit/src/EVault/shared/Events.sol`:
```
event Borrow(address indexed account, uint256 assets)                                  // Events.sol:72
event Repay(address indexed account, uint256 assets)                                   // :77
event Liquidate(address indexed liquidator, address indexed violator, address collateral, uint256 repayAssets, uint256 yieldBalance)   // :90
```
**ABI-source NOTE (build-verified caveat — open-Q #7).** This repo imports only the EVK **interfaces**
(`evk/EVault/IEVault.sol`), and the runtime `Borrow`/`Repay`/`Liquidate` events are declared on the EVK
**implementation** (`reference/euler-vault-kit/src/EVault/shared/Events.sol`), NOT on the interface — so
`forge inspect IEVault abi` does **NOT** surface them, and no EVault-implementation artifact is built into this
repo's `out/`. The template ABI is therefore a **minimal hand-assembled `subgraph/abis/EVault.json`** containing
EXACTLY these three event entries, transcribed verbatim from `Events.sol:72/:77/:90` (signatures in §2.10) — OR
fetched from a deployed EVK EVault ABI at item-10. A subgraph ABI need only contain the events the manifest
references, so the three-event minimal ABI is sufficient and `graph build`-valid. The template needs ONLY these
three events (collateral-vault `Deposit`/`Withdraw` are read directly, open-Q #2 below).

> **Skip list (decided, do NOT handle):** `WarehouseOp(uint8,address,bytes)` (`WarehouseAdminModule.sol:60`,
> opaque `data` — the warehouse balance is a direct read, GRAPH-02 §utilization), and every `*Set`/wiring event
> (`ShareTokenSet`, `EngineSafeSet`, `BorrowCapSet`, `NavOracleSet`, `BaalSet`, `TokensSet`, …) — config provenance,
> not dashboard data. Open-Q #5 (opaque `bytes`) RESOLVED = **skip**: no dashboard need decodes `WarehouseOp.data`
> or CRE report bytes in M1.

---

## 3. `schema.graphql` — the entities (derived from the §2 events + §1 keys)

> Conventions: `id` is `Bytes` for hash/address keys, `String` for composite keys (`"<addr>-<n>"`). All token
> amounts `BigInt` (wei). Timestamps `BigInt` (unix). `@derivedFrom` for reverse links. The entities a GRAPH-02
> metric reads are tagged `[GRAPH-02:<metric>]`.

```graphql
# ─────────────────────────────── the lien spine (key = lienId) ───────────────────────────────
type Lien @entity {
  id: Bytes!                       # lienId (bytes32)
  lienToken: Bytes                 # LienCreated.lien / LienOriginated.lien
  line: Line                       # LienOriginated.lineRef → Line (the §1 join, controller-authoritative)
  proofRef: Bytes                  # LienOriginated.proofRef
  equityMark: BigInt               # latest equityMark (LienOriginated, then LienDrawn)
  drawAmount: BigInt               # cumulative drawn (sum of LienOriginated + LienDrawn draws)
  status: Int                      # last LienStatusUpdated.status (uint8 state machine)
  open: Boolean!                   # true at Originated, false at Released
  originatedAt: BigInt
  originatedTx: Bytes
  releasedAt: BigInt
  # loss side (keyed by the same lienId)
  bond: Bond                       # @derivedFrom not used: 1:1, set explicitly
  lossState: String                # "NONE" | "DEFAULTED" | "RECOVERED" | "RESOLVED" | "WRITTEN_OFF"
  atRisk: BigInt                   # Defaulted.atRisk
  provision: BigInt                # latest per-lien provision (Defaulted → Recovered.remainingProvision → 0)
  capitalSlashAmount: BigInt       # Resolved/WrittenOff.capitalSlashAmount
  # reverse links
  statusEvents: [LienStatusEvent!]! @derivedFrom(field: "lien")
  priceMarks:   [RegistryPriceMark!]! @derivedFrom(field: "lien")
}

type LienStatusEvent @entity(immutable: true) {
  id: Bytes!                       # txHash-logIndex
  lien: Lien!
  status: Int!
  timestamp: BigInt!
  tx: Bytes!
}

type RegistryPriceMark @entity(immutable: true) {  # [GRAPH-02:NAV-per-lien-context]
  id: Bytes!                       # txHash-logIndex
  lien: Lien!                      # via lienToken address → resolve to Lien
  lienToken: Bytes!                # the registry key (address)
  price: BigInt!
  kind: String!                    # "SEED" | "UPDATE"
  timestamp: BigInt!               # RegistryPriceUpdated.timestamp, or block.ts for SEED
  tx: Bytes!
}

# ─────────────────────────────── the isolated market (key = lineRef) ───────────────────────────────
type Line @entity {
  id: Bytes!                       # lineRef (= borrow EVault address)
  lien: Lien                       # back-pointer (LineOpened.lienId / LienOriginated)
  oracleKey: Bytes                 # the lien token priced by this line's router
  collateralVault: Bytes           # per-line escrow vault (LineOpened.collateralVault)
  router: Bytes                    # per-line frozen EulerRouter (LineOpened.router)
  borrowAccount: Bytes             # the fresh per-line borrower (LineOpened.borrowAccount)
  borrowLTV: Int                   # LineLimitsSet.borrowLTV (1e4 scale)
  liqLTV: Int                      # LineLimitsSet.liqLTV
  cap: BigInt                      # LineLimitsSet.cap
  fundedTotal: BigInt!             # Σ LineFunded.amount
  drawnTotal: BigInt!              # Σ LineDrawn.amount  [GRAPH-02:utilization-senior]
  open: Boolean!                   # LineOpened → true, LineClosed → false
  openedAt: BigInt
  closedAt: BigInt
  borrows: [LineBorrow!]! @derivedFrom(field: "line")   # from the §4 template
}

type LineBorrow @entity(immutable: true) {              # [GRAPH-02:utilization-senior]
  id: Bytes!                       # txHash-logIndex
  line: Line!                      # resolved from the borrow-vault address (= lineRef)
  kind: String!                    # "BORROW" | "REPAY" | "LIQUIDATE"
  account: Bytes!                  # Borrow/Repay.account or Liquidate.violator
  assets: BigInt!                  # Borrow/Repay.assets or Liquidate.repayAssets
  liquidator: Bytes                # Liquidate.liquidator
  yieldBalance: BigInt             # Liquidate.yieldBalance
  timestamp: BigInt!
  tx: Bytes!
}

# ─────────────────────────────── senior supply / redemption ───────────────────────────────
type DepositAction @entity(immutable: true) {
  id: Bytes!                       # txHash-logIndex
  user: Bytes!
  usdcIn: BigInt!
  zipMinted: BigInt!
  shares: BigInt                   # null for raw Deposited, set for Zapped (→ szipUSD)
  kind: String!                    # "DEPOSIT" | "ZAP"
  timestamp: BigInt!
  tx: Bytes!
}

type RedemptionRequest @entity {
  id: String!                      # requestId (uint256, stringified)
  controller: Bytes!
  owner: Bytes!
  sender: Bytes!
  shares: BigInt!                  # zipUSD shares requested
  requestedAt: BigInt!
  claimedAssets: BigInt            # set on Withdraw
  claimedShares: BigInt
  claimedAt: BigInt
  status: String!                  # "PENDING" | "CLAIMED"
}

type RedemptionEpoch @entity(immutable: true) {          # [GRAPH-02:utilization-senior(fill history)]
  id: String!                      # epoch (uint256)
  era: BigInt!
  pending: BigInt!                 # pre-settle totalPending
  filledShares: BigInt!            # burned zipUSD
  fillAssets: BigInt!              # USDC reserved
  availableAssets: BigInt!         # free USDC at settle
  settledAt: BigInt!
  tx: Bytes!
}

# ─────────────────────────────── junior vault (Exit Gate) ───────────────────────────────
type JuniorDeposit @entity(immutable: true) {            # [GRAPH-02:NAV(issuance), utilization(TVL)]
  id: Bytes!                       # txHash-logIndex
  receiver: Bytes!
  asset: Bytes!
  amount: BigInt!
  value: BigInt!                   # USD value at deposit (Gate-valued)
  shares: BigInt!                  # szipUSD minted (NAV-proportional)
  timestamp: BigInt!
  tx: Bytes!
}

type ExitRequest @entity {
  id: String!                      # requestId (uint256)
  owner: Bytes!
  shares: BigInt!                  # szipUSD queued
  requestedAt: BigInt!
  filledShares: BigInt             # ExitFilled.shares
  filledAt: BigInt
  cancelledRemainder: BigInt       # ExitCancelled.remainder
  cancelledAt: BigInt
  status: String!                  # "QUEUED" | "FILLED" | "CANCELLED"
}

type ExitWindow @entity(immutable: true) {
  id: Bytes!                       # txHash-logIndex (WindowProcessed)
  claimsFilled: BigInt!
  queueHead: BigInt!
  timestamp: BigInt!
  tx: Bytes!
}

type BurnEvent @entity(immutable: true) {                # 8-B14 buy-and-burn retire (szipUSD supply ↓)
  id: Bytes!
  amount: BigInt!
  timestamp: BigInt!
  tx: Bytes!
}

# ─────────────────────────────── structural freeze (utilization) ───────────────────────────────
type FreezeAction @entity(immutable: true) {             # [GRAPH-02:utilization-junior]
  id: Bytes!                       # txHash-logIndex
  asset: Bytes!
  amount: BigInt!
  committedValueAfter: BigInt!     # the running committed (sidecar) basket value
  floor: BigInt                    # Released.floor only
  kind: String!                    # "COMMIT" | "RELEASE"
  timestamp: BigInt!
  tx: Bytes!
}

# ─────────────────────────────── NAV oracle outputs (the §2 hard rule) ───────────────────────────────
type NavSnapshot @entity(immutable: true) {              # [GRAPH-02:NAV, APR]
  id: Bytes!                       # txHash-logIndex (one per Poked)
  cumNav: BigInt!                  # Poked.cumNav (the TWAP accumulator value)
  oracleTs: BigInt!                # Poked.ts (uint32, the oracle's own timestamp)
  provision: BigInt!               # the latest ProvisionWritten value at this block (carried forward)
  legAlphaUsd: BigInt!             # latest LegPriceUpdated[leg=0] price carried forward
  legHydxUsd: BigInt!              # latest LegPriceUpdated[leg=1] price carried forward
  lpMark: BigInt!                  # latest LpMarkUpdated.mark carried forward
  blockTimestamp: BigInt!
  blockNumber: BigInt!
  tx: Bytes!
}

type LegPrice @entity(immutable: true) {                 # [GRAPH-02:NAV(leg history)]
  id: Bytes!                       # txHash-logIndex
  leg: Int!                        # 0 = ALPHA_USD, 1 = HYDX_USD
  price: BigInt!
  oracleTs: BigInt!                # LegPriceUpdated.ts (uint48)
  blockTimestamp: BigInt!
  tx: Bytes!
}

type Provision @entity(immutable: true) {                # [GRAPH-02:NAV(impairment history)]
  id: Bytes!                       # txHash-logIndex
  provision: BigInt!               # ProvisionWritten.provision (the unbounded oracle value)
  blockTimestamp: BigInt!
  tx: Bytes!
}

type LpMark @entity(immutable: true) {                   # [GRAPH-02:NAV(LP leg)]
  id: Bytes!                       # txHash-logIndex
  mark: BigInt!
  oracleTs: BigInt!                # LpMarkUpdated.timestamp (uint32)
  blockTimestamp: BigInt!
  tx: Bytes!
}

# the carry-forward singleton the NavSnapshot handler reads to compose a full row from a partial event
type OracleState @entity {
  id: Bytes!                       # constant "navOracle"
  legAlphaUsd: BigInt!
  legHydxUsd: BigInt!
  provision: BigInt!
  lpMark: BigInt!
  cumNav: BigInt!
  oracleTs: BigInt!
  updatedAt: BigInt!
}

# ─────────────────────────────── loss / bond ───────────────────────────────
type Bond @entity {                                      # key = lienId (1:1 with Lien)
  id: Bytes!                       # lienId
  lien: Lien!
  originator: Bytes                # Locked/BondLocked.originator
  amount: BigInt                   # locked amount
  state: String!                   # "LOCKED" | "RELEASED" | "SLASHED"
  slashedToCapital: BigInt!        # Σ SlashedToCapital.amount
  slashedToCohort: BigInt!         # Σ SlashedToCohort.amount
  lockedAt: BigInt
  releasedAt: BigInt
}

type LossEvent @entity(immutable: true) {                # per-lien loss timeline
  id: Bytes!                       # txHash-logIndex
  lien: Lien!
  kind: String!                    # "DEFAULTED" | "RECOVERED" | "RESOLVED" | "WRITTEN_OFF" | "BOND_LOCKED" | "BOND_RELEASED" | "SLASH_CAPITAL" | "SLASH_COHORT"
  atRisk: BigInt
  provision: BigInt
  proceeds: BigInt
  capitalSlashAmount: BigInt
  amount: BigInt
  timestamp: BigInt!
  tx: Bytes!
}

# ─────────────────────────────── junior engine telemetry ───────────────────────────────
type EngineAction @entity(immutable: true) {             # operator dashboard (per-module loop steps)
  id: Bytes!                       # txHash-logIndex
  module: String!                  # "LP" | "LOOP" | "HARVEST" | "EXERCISE" | "SELL" | "RECYCLE" | "BUYBURN"
  action: String!                  # "LIQUIDITY_ADDED" | "STAKED" | "BORROWED" | "RECYCLED" | "SOLD" | …
  amount0: BigInt
  amount1: BigInt
  shares: BigInt
  tokenIn: Bytes
  tokenOut: Bytes
  timestamp: BigInt!
  tx: Bytes!
}

# the free-value accrual the RecycleModule tracks (drives szipUSD NAV accretion = the APR source)
type RecycleState @entity {                              # [GRAPH-02:APR(accrual context)]
  id: Bytes!                       # constant "recycle"
  accrued: BigInt!                 # last FreeValue{Credited,Spent}.newAccrued
  totalRecycledUsdc: BigInt!       # Σ Recycled.usdcAmount
  totalZipMinted: BigInt!          # Σ Recycled.zipMinted
  updatedAt: BigInt!
}

# ─────────────────────────────── protocol-wide rollup (cheap dashboard header) ───────────────────────────────
type Protocol @entity {
  id: Bytes!                       # constant "zipcode"
  totalLiens: Int!
  openLiens: Int!
  totalLines: Int!
  openLines: Int!
  totalDefaulted: Int!
  totalWrittenOff: Int!
  szipBurnedTotal: BigInt!         # Σ ExitGate.Burned
  updatedAt: BigInt!
}
```

> **Why `OracleState` + `RecycleState` singletons exist:** `Poked`/`LegPriceUpdated`/`ProvisionWritten` arrive in
> **separate transactions**; a `NavSnapshot` row must carry the *current* legs/provision even when only `Poked`
> fired. The handler reads/writes the singleton to compose a complete row. This is **carry-forward of emitted
> values, NOT recomputation of NAV** (the §2 rule holds — the subgraph never multiplies legs into a NAV).

---

## 4. The per-line market TEMPLATE (the #1 high-fidelity point)

`subgraph.yaml` declares a `templates:` entry `LineBorrowVault` whose `source.abi` is the EVK `EVault` ABI (§2.10)
with **no fixed address**. It is **spawned at runtime** from the `LineOpened` handler:

```ts
// in handleLineOpened (EulerVenueAdapter datasource)
import { LineBorrowVault } from "../generated/templates";
// … populate the Line entity from event.params (lineRef, collateralVault, router, borrowAccount) …
LineBorrowVault.create(event.params.lineRef);   // start indexing THIS line's borrow vault
```

Thereafter the EVK `Borrow`/`Repay`/`Liquidate` events emitted by `event.params.lineRef` (the borrow EVault) flow
into the template's mapping (`src/lineBorrowVault.ts`), which keys `LineBorrow.line` by `event.address` (= the
`lineRef`). **This is the only correct model — there is no manifest-time market address.**

> **`startBlock` for the template** is inherited from `LineOpened`'s block (templates have no `startBlock` field;
> they begin indexing at the spawning block by construction). The base `EulerVenueAdapter` datasource's `startBlock`
> is the item-10 deploy block (§7) — that bounds when the first template can spawn.

**Open-Q #2 RESOLVED — which per-line vault events to index vs read:** index ONLY the **borrow vault**'s
`Borrow`/`Repay`/`Liquidate` (the senior-utilization + liquidation history GRAPH-02 needs). Do **NOT** template the
per-line **collateral** escrow vault — its `Deposit`/`Withdraw` is the deterministic 1e18-lien custody (open at
origination, redeem at close), already fully captured by `LineOpened`/`LineClosed` + the controller events; its
live state is a cheap direct read. One template, three events.

---

## 5. The mapping handlers (one block per datasource → entity writes)

Each handler is `event.transaction.hash.concatI32(event.logIndex.toI32())` for immutable-entity `id`s, and
`changetype<Bytes>(…)` / `Bytes.fromHexString` as needed. The GRAPH-02-read field each handler MUST write is
called out.

### 5.1 `ZipcodeController` (`src/controller.ts`)
- **`handleLienOriginated`** — load-or-create `Lien(id=lienId)`; set `lienToken=lien`, `proofRef`, `equityMark`,
  `drawAmount=drawAmount`, `open=true`, `originatedAt/Tx`. **Set `Lien.line = lineRef`** (the §1 join — load-or-
  create `Line(id=lineRef)`, set its `.lien = lienId` back-pointer). Bump `Protocol.totalLiens/openLiens`. ★writes
  the `Lien.line` join GRAPH-02 needs to attribute per-line borrows to a lien.
- **`handleLienDrawn`** — load `Lien(lienId)`; `equityMark = event.equityMark`; `drawAmount += event.drawAmount`.
- **`handleLienReleased`** — load `Lien`; `open=false`, `releasedAt`; `Protocol.openLiens -= 1`.
- **`handleLienStatusUpdated`** — load `Lien`; `status = event.status`; append a `LienStatusEvent`.

### 5.2 `LienTokenFactory` (`src/factory.ts`)
- **`handleLienCreated`** — load-or-create `Lien(lienId)`; set `lienToken = event.lien`. (Fires in the same
  origination tx, possibly before `LienOriginated`; load-or-create handles either order.)

### 5.3 `ZipcodeOracleRegistry` (`src/registry.ts`)
- **`handleRegistryPriceSeed`** — create `RegistryPriceMark(kind="SEED")` keyed by `lien` token; `timestamp =
  block.timestamp`. Resolve `RegistryPriceMark.lien` by looking up the `Lien` whose `lienToken == event.lien`
  (maintain a `LienByToken` lookup entity, §5.note).
- **`handleRegistryPriceUpdated`** — create `RegistryPriceMark(kind="UPDATE")`; `timestamp = event.timestamp`.

> **§5.note — the `lienToken → lienId` reverse lookup.** Registry events key by **token address**, not `lienId`.
> Add a tiny `LienByToken @entity { id: Bytes!  lien: Bytes! }` written in `handleLienCreated`
> (`id = lien token`, `lien = lienId`) so registry/escrow handlers can resolve the token back to the `Lien`. (One
> extra entity; keeps the spine clean.)

### 5.4 `EulerVenueAdapter` (`src/venue.ts`)
- **`handleLineOpened`** — load-or-create `Line(id=lineRef)`; set `oracleKey`, `collateralVault`, `router`,
  `borrowAccount`, `open=true`, `openedAt`; set `Line.lien = lienId` (and the `Lien.line` back-pointer).
  **`LineBorrowVault.create(event.params.lineRef)`** (§4). `Protocol.totalLines/openLines += 1`. ★spawns the
  template.
- **`handleLineLimitsSet`** — load `Line`; set `borrowLTV`, `liqLTV`, `cap`.
- **`handleLineFunded`** — load `Line`; `fundedTotal += amount`.
- **`handleLineDrawn`** — load `Line`; `drawnTotal += amount`. ★writes the senior-deployed figure GRAPH-02
  utilization reads.
- **`handleLineClosed`** — load `Line`; `open=false`, `closedAt`; `Protocol.openLines -= 1`.

### 5.5 `ZipDepositModule` (`src/deposit.ts`)
- **`handleDepositModuleDeposited`** — create `DepositAction(kind="DEPOSIT")` (`shares=null`).
- **`handleZapped`** — create `DepositAction(kind="ZAP")` with `shares`.

### 5.6 `ZipRedemptionQueue` (`src/redemption.ts`)
- **`handleRedeemRequest`** — create `RedemptionRequest(id=requestId, status="PENDING")`.
- **`handleEpochSettled`** — create `RedemptionEpoch(id=epoch)`.
- **`handleWithdraw`** — the queue's `Withdraw` is keyed by `(sender, receiver, controller)` not `requestId`; mark
  the owner's pending request CLAIMED by matching the most-recent PENDING request for `controller==event.controller`
  (see open-Q #6). Set `claimedAssets/Shares/At`, `status="CLAIMED"`.

### 5.7 `ExitGate` (`src/gate.ts`)
- **`handleGateDeposited`** — create `JuniorDeposit` (`value`, `shares`). ★`value`+`shares` feed GRAPH-02 NAV-
  issuance + TVL.
- **`handleExitRequested`** — create `ExitRequest(id=requestId, status="QUEUED")`.
- **`handleExitFilled`** — load `ExitRequest`; `filledShares`, `filledAt`, `status="FILLED"`.
- **`handleExitCancelled`** — load `ExitRequest`; `cancelledRemainder`, `status="CANCELLED"`.
- **`handleWindowProcessed`** — create `ExitWindow`.
- **`handleBurned`** — create `BurnEvent`; `Protocol.szipBurnedTotal += amount`.

### 5.8 `DurationFreezeModule` (`src/freeze.ts`)
- **`handleCommitted`** — create `FreezeAction(kind="COMMIT")`; `committedValueAfter`. ★the junior-utilization
  numerator series.
- **`handleFreezeReleased`** — create `FreezeAction(kind="RELEASE")`; `committedValueAfter`, `floor`.

### 5.9 `SzipNavOracle` + `SzipReservoirLpOracle` (`src/nav.ts`) — the §2 hard rule
- **`handleLegPriceUpdated`** — create an immutable `LegPrice`; update `OracleState.legAlphaUsd`/`legHydxUsd` by
  `event.leg`.
- **`handleProvisionWritten`** — create immutable `Provision`; update `OracleState.provision`.
- **`handlePoked`** — update `OracleState.cumNav`/`oracleTs`; **create a `NavSnapshot`** composing
  `OracleState`'s carried legs/provision/lpMark + this `Poked`'s `cumNav`/`ts`. ★the NAV + APR time-series.
- **`handleLpMarkUpdated`** — create immutable `LpMark`; update `OracleState.lpMark`.

> The handler **carries forward** emitted values into the snapshot — it **never** multiplies legs into a NAV.
> NAV-per-share is the oracle's job (`navEntry()`/`navExit()` direct read). GRAPH-02 derives APR from the
> `cumNav`/`oracleTs` accumulator deltas (the oracle's own TWAP numbers), not from a re-derived NAV.

### 5.10 `LienXAlphaEscrow` + `DefaultCoordinator` (`src/loss.ts`)
- **`handleEscrowLocked`** / **`handleBondLocked`** — load-or-create `Bond(id=lienId)`; `originator`, `amount`,
  `state="LOCKED"`, `lockedAt`; append `LossEvent(kind="BOND_LOCKED")`; set `Lien.bond`.
- **`handleEscrowReleased`** / **`handleBondReleased`** — `Bond.state="RELEASED"`, `releasedAt`; `LossEvent`.
- **`handleSlashedToCapital`** — `Bond.slashedToCapital += amount`, `state="SLASHED"`; `LossEvent(SLASH_CAPITAL)`.
- **`handleSlashedToCohort`** — `Bond.slashedToCohort += amount`; `LossEvent(SLASH_COHORT)`.
- **`handleDefaulted`** — `Lien.lossState="DEFAULTED"`, `atRisk`, `provision`; `LossEvent`; `Protocol.totalDefaulted++`.
- **`handleRecovered`** — `Lien.lossState="RECOVERED"`, `provision = remainingProvision`; `LossEvent(proceeds)`.
- **`handleResolved`** — `Lien.lossState="RESOLVED"`, `capitalSlashAmount`, `provision=0`; `LossEvent`.
- **`handleWrittenOff`** — `Lien.lossState="WRITTEN_OFF"`, `capitalSlashAmount`; `Protocol.totalWrittenOff++`.

### 5.11 engine modules (`src/engine.ts`)
- One handler per §2.7 event → `EngineAction(module, action, …)`. **`handleRecycled`** ALSO updates
  `RecycleState.totalRecycledUsdc/totalZipMinted`; **`handleFreeValueCredited/Spent`** update `RecycleState.accrued`.
  ★`RecycleState` is the NAV-accretion provenance behind the GRAPH-02 APR (context only — APR is still the NAV
  series slope, never the recycle figure).

### 5.12 `LineBorrowVault` template (`src/lineBorrowVault.ts`) — §4
- **`handleBorrow`** — create `LineBorrow(kind="BORROW", account, assets)`; `line = event.address` (= lineRef).
- **`handleRepay`** — create `LineBorrow(kind="REPAY", account, assets)`.
- **`handleLiquidate`** — create `LineBorrow(kind="LIQUIDATE", account=violator, assets=repayAssets, liquidator,
  yieldBalance)`.

---

## 6. Matchstick unit plan (one per handler — the gate proof)

`subgraph/tests/<datasource>.test.ts`, `matchstick-as`. Each test: build the event via the generated mock
constructor, call the handler, `assert.fieldEquals(...)` on the entity field GRAPH-02 reads. Minimum one test per
handler in §5; the ★-tagged handlers get an explicit GRAPH-02-read assertion.

| Handler | Asserts (the entity write) | GRAPH-02 read proven |
|---|---|---|
| `handleLienOriginated` | `Lien.open=true`, `Lien.line=lineRef`, `Lien.equityMark`, `Line.lien` back-ptr | the lien↔line join |
| `handleLienDrawn` | `Lien.drawAmount` accumulates | — |
| `handleLienReleased` | `Lien.open=false` | — |
| `handleLienStatusUpdated` | `LienStatusEvent` row + `Lien.status` | — |
| `handleLienCreated` | `Lien.lienToken`, `LienByToken` lookup | registry join |
| `handleRegistryPriceSeed/Updated` | `RegistryPriceMark.price`, `.kind`, `.lien` resolved | per-lien mark history |
| `handleLineOpened` | `Line` populated + **`LineBorrowVault` template spawned** (`dataSourceMock`/`assert` template count) | the per-line template (§4) |
| `handleLineLimitsSet` | `Line.borrowLTV/liqLTV/cap` | — |
| `handleLineFunded` | `Line.fundedTotal` accumulates | — |
| `handleLineDrawn` | **`Line.drawnTotal`** accumulates | utilization-senior numerator |
| `handleLineClosed` | `Line.open=false` | — |
| `handleDepositModuleDeposited` / `handleZapped` | `DepositAction.kind`, `.shares` | — |
| `handleRedeemRequest` | `RedemptionRequest.status="PENDING"` | — |
| `handleEpochSettled` | `RedemptionEpoch.filledShares/fillAssets/availableAssets` | senior fill history |
| `handleWithdraw` | request → `CLAIMED` (matched per open-Q #6) | — |
| `handleGateDeposited` | **`JuniorDeposit.value` + `.shares`** | NAV-issuance + TVL |
| `handleExitRequested/Filled/Cancelled` | `ExitRequest.status` transitions | — |
| `handleWindowProcessed` | `ExitWindow.claimsFilled/queueHead` | — |
| `handleBurned` | `BurnEvent.amount`, `Protocol.szipBurnedTotal` | szipUSD supply ↓ |
| `handleCommitted` | **`FreezeAction.committedValueAfter`** | utilization-junior numerator |
| `handleFreezeReleased` | `FreezeAction.committedValueAfter`, `.floor` | utilization-junior |
| `handleLegPriceUpdated` | `LegPrice.price/leg`, `OracleState.legAlphaUsd`/`legHydxUsd` | NAV leg history |
| `handleProvisionWritten` | `Provision.provision`, `OracleState.provision` | impairment history |
| `handlePoked` | **`NavSnapshot.cumNav/oracleTs`** + carried legs/provision/lpMark | NAV + APR series |
| `handleLpMarkUpdated` | `LpMark.mark`, `OracleState.lpMark` | NAV LP leg |
| `handleEscrowLocked`/`handleBondLocked` | `Bond.state="LOCKED"`, `.amount` | — |
| `handleSlashedToCapital/Cohort` | `Bond.slashedTo*` accumulate, `LossEvent` | loss timeline |
| `handleDefaulted/Recovered/Resolved/WrittenOff` | `Lien.lossState`, `Lien.provision`, `LossEvent` | loss timeline |
| engine handlers (×N) | `EngineAction.module/action`; `handleRecycled` → `RecycleState` totals | operator dashboard / APR context |
| `handleBorrow/Repay/Liquidate` (template) | **`LineBorrow.kind/assets`, `.line=event.address`** | utilization-senior + liquidations |

> **`handleLineOpened` template assertion:** Matchstick's `dataSourceMock`/`logStore` + `assert.dataSourceCount(
> "LineBorrowVault", 1)` (or the `mockFunction`/`createMockedFunction` + `assert.entityCount` pattern per the
> installed matchstick-as version) proves the template was created. This is the single most important unit — it
> guards the §4 invariant.

---

## 7. `subgraph.yaml` structure (item-10 address/startBlock placeholders only)

```yaml
specVersion: 1.0.0
schema: { file: ./schema.graphql }
dataSources:
  - kind: ethereum/contract
    name: ZipcodeController
    network: base                                  # Base mainnet 8453 — memory [[deploy-target-base-mainnet]]
    source:
      address: "<ITEM-10: ZipcodeController address>"
      abi: ZipcodeController
      startBlock: <ITEM-10: startBlock>
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      file: ./src/controller.ts
      entities: [Lien, Line, LienStatusEvent, Protocol]
      abis:
        - name: ZipcodeController
          file: ./abis/ZipcodeController.json
      eventHandlers:
        - { event: "LienOriginated(indexed bytes32,indexed address,address,bytes32,uint256,uint256)", handler: handleLienOriginated }
        - { event: "LienDrawn(indexed bytes32,uint256,uint256)", handler: handleLienDrawn }
        - { event: "LienReleased(indexed bytes32)", handler: handleLienReleased }
        - { event: "LienStatusUpdated(indexed bytes32,uint8)", handler: handleLienStatusUpdated }
  # … one dataSources entry per §2 datasource (LienTokenFactory, ZipcodeOracleRegistry, EulerVenueAdapter,
  #   ZipDepositModule, ZipRedemptionQueue, ExitGate, DurationFreezeModule, SzipNavOracle, SzipReservoirLpOracle,
  #   LienXAlphaEscrow, DefaultCoordinator, and the 7 engine modules) — same shape, event signatures from §2 …

templates:
  - kind: ethereum/contract
    name: LineBorrowVault                           # §4 — the per-line dynamic data source
    network: base
    source:
      abi: EVault                                   # NO address/startBlock — spawned at runtime
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      file: ./src/lineBorrowVault.ts
      entities: [Line, LineBorrow]
      abis:
        - name: EVault
          file: ./abis/EVault.json
      eventHandlers:
        - { event: "Borrow(indexed address,uint256)", handler: handleBorrow }
        - { event: "Repay(indexed address,uint256)", handler: handleRepay }
        - { event: "Liquidate(indexed address,indexed address,address,uint256,uint256)", handler: handleLiquidate }
```

- `networks.json` carries the same `<ITEM-10>` addresses for `graph deploy --network base`.
- **The ONLY placeholders are `source.address` + `source.startBlock`** (one per fixed datasource). Everything else
  — schema, mappings, template, event signatures — is concrete now. Wire at deploy (item 10 outputs).

---

## 8. Resolved / escalated open questions (GRAPH-01 scope)

1. **`lienId`↔`lineRef` correlation — RESOLVED:** explicit, same-tx, single-event. `LienOriginated` carries BOTH
   (`lineRef` is field 3, `ZipcodeController.sol:79`); `LineOpened` also carries both. No same-tx heuristic needed.
2. **Which per-line vault events to index — RESOLVED:** template ONLY the borrow vault's `Borrow`/`Repay`/
   `Liquidate`; collateral-vault custody is deterministic + read directly (§4).
3. **Interface vs emitter — RESOLVED:** bind the venue datasource to `EulerVenueAdapter`'s address + ABI (the
   concrete emitter), not `IZipcodeVenue` (§1, §4 note).
4. **Opaque `bytes` (`WarehouseOp.data`, CRE report bytes) — RESOLVED:** skip (no M1 dashboard decodes them; §2.10
   skip list).
5. **Config/wiring events (`*Set`, CRE-base config) — RESOLVED:** skip for M1 (no config/audit panel scoped).
6. **`Withdraw` → request matching — ESCALATED (minor, B-1):** `ZipRedemptionQueue.Withdraw` is keyed by
   `(sender, receiver, controller)` and carries **no `requestId`** (`:142`), so the subgraph cannot deterministically
   close a *specific* `RedemptionRequest` to a `Withdraw` when an owner has multiple pending requests. M1 workaround:
   FIFO-match the oldest PENDING request for that `controller`. **Filed as a contract back-pressure obligation**
   (add `requestId` to `Withdraw`) — see §9 / PROGRESS obligations. Non-blocking (the aggregate claimed totals are
   exact; only per-request attribution is approximate).
7. **EVK template ABI source — RESOLVED (build-verified caveat):** the EVK runtime events live on the
   **implementation** (`reference/euler-vault-kit/src/EVault/shared/Events.sol:72/:77/:90`), NOT the interface — so
   `forge inspect IEVault abi` does NOT carry them and no EVault-impl artifact is in this repo's `out/`. Hand-assemble
   a **minimal three-event `subgraph/abis/EVault.json`** from those `Events.sol` declarations (or fetch a deployed
   EVK EVault ABI at item-10). A subgraph ABI need only carry the referenced events. (§4 ABI-source note.)

---

## 9. Contract back-pressure obligations this ticket files (spec-first, §8-for-CRE discipline)

| # | Gap | Fix (which contract) | Severity |
|---|---|---|---|
| B-1 | `ZipRedemptionQueue.Withdraw` carries no `requestId` (`:142`) → per-request claim attribution is FIFO-approximate when an owner has multiple pending requests | add `uint256 indexed requestId` to `Withdraw` (it is already tracked internally for `RedeemRequest`) | LOW — aggregates exact; only per-request join approximate |

(These are subgraph-driven contract asks, logged in `tickets/PROGRESS.md` "Open cross-ticket obligations" keyed to
the emitting contract. Do not work around in the subgraph beyond the documented FIFO match.)

---

## 10. Build-order note for the cold builder

1. Copy ABIs: `for C in ZipcodeController LienTokenFactory ZipcodeOracleRegistry EulerVenueAdapter ZipDepositModule
   ZipRedemptionQueue ExitGate DurationFreezeModule SzipNavOracle SzipReservoirLpOracle LienXAlphaEscrow
   DefaultCoordinator LpStrategyModule ReservoirLoopModule HarvestVoteModule ExerciseModule SellModule RecycleModule
   SzipBuyBurnModule; do forge inspect $C abi > subgraph/abis/$C.json; done`. **EXCEPTION — the `EVault.json`
   template ABI is NOT forge-inspectable** (interface-only import; §4 note): hand-author `subgraph/abis/EVault.json`
   as a minimal 3-event ABI (`Borrow`/`Repay`/`Liquidate`) transcribed from `reference/euler-vault-kit/src/EVault/
   shared/Events.sol:72/:77/:90`.
2. Author `schema.graphql` (§3), `subgraph.yaml` (§7), then `graph codegen` (deferred — CLI not installed).
3. Author the §5 handlers against the generated types; `graph build` (deferred).
4. Author the §6 Matchstick units; `graph test` (deferred). Each ★ handler proves a GRAPH-02 read.
5. At item-10, fill the `<ITEM-10>` address/startBlock placeholders + `graph deploy --network base`.
