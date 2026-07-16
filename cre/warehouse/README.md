# cre-warehouse — the §8.5 senior-warehouse op producer (opType 1/2/3/4 → `WarehouseAdminModule`)

A wasip1 CRE report-path (R) workflow. It is the senior-warehouse op producer: an off-chain warehouse-op event
arrives via the `http.Trigger`, the workflow reaches **identical consensus** on the event record, normalizes +
**dispatches on the op discriminant**, validates the per-op required fields, encodes the matching payload via
the shared `cre/zipreport` library, and emits **one `WriteReport`** to the `WarehouseAdminModule` (8-Bw) as the
§8.5 envelope `abi.encode(uint8 opType, bytes payload)`.

This is **CRE-04**. It clones the proven http+zipreport shape of **CRE-01c** (`cre/coordinator/`).

The `CreditWarehouse` is a plain Gnosis Safe custodying the protocol's `EulerEarn` shares (backing all
outstanding zipUSD float); CRE drives it **only** through the audited Zodiac Roles Modifier v2. The
`WarehouseAdminModule` is a thin `is ReceiverTemplate` adapter (Forwarder-gated, Timelock-owned) `assignRoles`'d
as the role member: on a report it decodes `(uint8 opType, bytes payload)`, **re-encodes the corresponding
pinned Safe call**, and invokes `Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`. The adapter
holds **NO custody** and enforces **NO scope of its own** beyond the `dest == redemptionBox` self-check — the
real **security boundary is the Zodiac Roles scope** (params pinned, Call-only). The producer sizes the
scalars; the on-chain policy pins the identities.

## The trigger + the event

One trigger only: `http.Trigger` (§8.5 — the senior-warehouse ops are driven on demand by the off-chain
redemption/recovery sequencer; **no cron heartbeat**). The off-chain pipeline POSTs one JSON op event;
`http.Payload.Input` is the JSON body. The consensus carrier (`WarehouseOp`) is **string fields only** — every
magnitude/address is carried as a string and parsed on the DON side **after** consensus.

```json
{ "op": "supply", "amount": "1000000" }
```

## The 4-op discriminant

The op string is normalized (`strings.ToLower(strings.TrimSpace(...))`), so `"Supply"` / `" supply "` all
match. An unknown or empty op ⇒ error, no write. **There is no Proof gate** — every well-formed op emits
exactly one report.

| op | opType | encoder | payload tuple | the pinned Safe call the adapter re-encodes | required fields |
|---|---|---|---|---|---|
| `supply` | 1 `SUPPLY` | `zipreport.WhSupplyReport` | `(uint256 amount)` | `eePool.deposit(amount, receiver==SAFE)` | amount (**> 0**) |
| `approve` | 2 `APPROVE` | `zipreport.WhApproveReport` | `(uint256 amount)` | `usdc.approve(spender==eePool, amount)` | amount (**> 0**, exact-amount) |
| `redeem` | 3 `REDEEM` | `zipreport.WhRedeemReport` | `(uint256 shares)` | `eePool.redeem(shares, receiver==SAFE, owner==SAFE)` | shares (**> 0**) |
| `repay` | 4 `REPAY` | `zipreport.WhRepayReport` | `(address dest, uint256 amount)` | `usdc.transfer(to==dest, amount)` (adapter pins `dest==redemptionBox`) | dest (**non-zero**), amount (**> 0**) |

**All four magnitudes are `> 0`** — `deposit(0)` reverts (EE `ZeroShares`); `approve` is an exact-amount
allowance; `redeem(0)` is a wasted no-op write the producer never intends; a 0-value `transfer` is meaningless.
A missing/unparseable required field ⇒ error, no write — a malformed event is a producer-side bug to surface.

`REPAY`'s `dest` is the **one field the producer carries** (§8.5); every other identity
(receiver/spender/redeem-owner) is adapter-injected from wiring and scope-pinned (belt-and-suspenders). The
producer validates `dest` is a non-zero address and surfaces the on-chain `WrongRedemptionBox` / Roles
`EqualTo(redemptionBox)` revert if it drifts — it does **NOT** read the on-chain `redemptionBox` to pre-check.

### Example events

```json
{ "op": "supply",  "amount": "1000000" }
{ "op": "approve", "amount": "1000000" }
{ "op": "redeem",  "shares": "750000000000000000" }
{ "op": "repay",   "dest": "0x…40hex", "amount": "1000000" }
```

## The §8.5 sizing + the §8.5/§8.9 mock-feed seam

§8.5 has the producer compute `amount`/`shares` (the redemption shortfall, the recovery draw) off the live NAV
(`eePool.convertToAssets(eePool.balanceOf(warehouseSafe))`). **For the build that sizing arrives pre-computed on
the `http.Trigger` payload** (the §8.5/§8.9 MOCK-FEED seam) — exactly as CRE-01c's loss magnitudes arrive on its
trigger. `observe` `json.Unmarshal`s the identical trigger-supplied op event on every node (deterministic →
identical consensus holds).

The **production swap-in** replaces that `json.Unmarshal` with the on-chain NAV sizing: a per-node
`evmClient.CallContract` reading `eePool.convertToAssets(eePool.balanceOf(warehouseSafe))` + the redemption
shortfall / recovery draw, deriving `amount`/`shares` per node. The `RunInNodeMode` + consensus + dispatch +
encode + write machinery is unchanged. `observe` MUST NOT read secrets (NodeRuntime has no SecretsProvider); the
on-chain NAV read needs none, and any future authenticated off-chain shortfall-feed token is read in the
**handler**, never `observe`. The producer **cannot widen the call set** (that needs the Safe owner: GOD-EOA →
multisig).

## No Proof gate (§8.9 / CRE-01a/01c posture)

There is **no on-chain boolean Proof gate** on the warehouse op family. The `WarehouseAdminModule`'s decode is a
pure `(opType, payload)` → one pinned Roles-forwarded call; it exposes no boolean gate surface. The **identical
consensus over the op facts IS the attestation**, and the §13 distinct-Forwarder + Timelock-pinned workflow
identity + the Zodiac Roles scope (the real param-pinning security boundary) are the entry guards. There is **no
`Gates` struct and no "emit only if gates pass" branch** here.

## Distinct Forwarder identity (deploy note)

The warehouse adapter uses a **distinct Forwarder identity / workflowId** from the controller / registry /
oracle receivers (§8.5, `WarehouseAdminModule.sol:76,91`). Deploy this workflow under its own owner / workflow
identity — do not share the controller's.

## Anticipated on-chain reverts (surfaced, not pre-checked)

The producer sends a well-formed report; it does **NOT** replicate the warehouse balance / Roles scope state.
These on-chain backstops surface as the returned write error: `supply` can revert on EE `ZeroShares`/cap or an
unwired Roles instance; `approve`/`redeem`/`repay` can revert in the Roles checker
(`ParameterNotAllowed`/`ModuleTransactionFailed`) if a wiring drift makes the re-encoded call fall outside the
scope; `repay` reverts `WrongRedemptionBox` if `dest != redemptionBox`; `redeem`/`repay` revert on insufficient
shares/USDC in the Safe.

## The gate

```sh
cd cre/warehouse
go build ./... && go vet ./...
GOOS=wasip1 GOARCH=wasm go build ./...   # the wasip1 target — the real gate
go test ./... -count=1 -v
```

## Cross-references

- Spec §8.5 (senior-warehouse ops: SUPPLY/APPROVE/REDEEM/REPAY via the Roles adapter), §8.9 (no boolean gate on
  the warehouse op family), §8.0 (the shared envelope), §17 (Config-driven wiring), §13 (the trust boundary).
- `cre/zipreport` (CRE-00) — the shared §8.5 encoder (`WhSupplyReport`/`WhApproveReport`/`WhRedeemReport`/
  `WhRepayReport`). This slice imports it; it does NOT re-encode.
- `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` — the filed receiver (the decode sites + the
  `WrongRedemptionBox` self-check).
- `cre/coordinator/` (CRE-01c) — the http + zipreport sibling this module was cloned from.
- **Unblocks CRE-02** (redemption-settle): CRE-02 reuses this warehouse-op package for the (R) REDEEM→REPAY
  funding calls.
