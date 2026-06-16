# 8-B14 — SzipBuyBurnModule (wiring map)

> Source of truth = the kept code `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` +
> `contracts/src/interfaces/cow/IGPv2Settlement.sol` (read as the final form). Ticket
> `tickets/sodo/8-B14-buy-burn-module.md` + reports `reports/8-B14-report.md` /
> `reports/credit-union-report.md` are intent only — **code wins**. Spec cites `claude-zipcode.md`
> §4.5.1 / §6.4 / §11 / §17 + `reports/baal-spec.md` §7.2 / §7.4 / §10.1.

## Role
The §7 **haircut buy-and-burn BID side** — the protocol-as-discounted-buyer-of-last-resort for szipUSD, the
impatient-exit liquidity floor. A CRE-operator-gated Zodiac Module enabled ON the engine Safe
(`avatar == target == engineSafe`) that posts a **single resting CoW `BUY szipUSD` limit order** —
`sellToken = USDC`, `buyToken = szipUSD`, `receiver = engineSafe`, `partiallyFillable` — priced **at or below
`navExit × (1 − d)`** off `SzipNavOracle`, `sellAmount ≤ buybackCap`, signed on-chain via PRESIGN
(`GPv2Settlement.setPreSignature`). Everything it buys lands in the engine Safe at a discount; the discount
is the haircut accruing to stayers when the bought szipUSD is later burned.

This module is **bid-only**. The **BURN is out of scope** — it is the already-built `ExitGate.burnFor`, gated
on the CRE `windowController`, which `burnLoot`s the Gate's Loot and burns the engine Safe's szipUSD (no asset
payout ⇒ NAV-per-share ticks up). Buy and burn are split by *authority*: the burn needs the Gate's `manager(2)`
Loot capability, which this module does not hold. The cycle `{postBid → async CoW fill → windowController:burnFor}`
is a CRE-orchestrated 3-step (the CRE holds BOTH `operator` here and `windowController` on the Gate). This is
the **first engine Zodiac Module** — it set the `is Module` / `setUp`-under-`initializer` / `onlyOperator` /
`exec(Call)` / clone-via-ModuleProxyFactory pattern for 8-B5…B13.

## Contracts involved
| Contract | What it does |
|---|---|
| `SzipBuyBurnModule` (`is Module`, zodiac-core) | The whole bid engine. `setUp`-under-`initializer` set-once wiring (10 args, +`coverageGate`; NO immutable — clone); `onlyOperator` `postBid` (validate the 3-field order → cap → **coverage gate `covered()`** → price-bound vs `navExit` → NAV-freshness fence → build canonical GPv2 uid → `exec` USDC `approve(vaultRelayer)` + `exec` `setPreSignature(uid,true)`) + `cancelBid` (operator-or-owner; presig→false + allowance→0; idempotent); `_orderUid` (in-contract canonical GPv2 hashing); `onlyOwner` (Timelock) governed-param setters (`setDiscountBps`/`setBuybackCap`) + 8 Timelock-settable wiring setters (incl. `setCoverageGate`); `currentBid`/`quoteMaxPrice` views. |
| `IGPv2Settlement` (`contracts/src/interfaces/cow/IGPv2Settlement.sol`) | The minimal CoW `GPv2Settlement` surface (Base 8453 `0x9008…ab41`, same address all chains): `domainSeparator()` + `vaultRelayer()` (both read LIVE in `setUp`), `setPreSignature(bytes,bool)` (the PRESIGN target — the `owner` packed into `orderUid` MUST == `msg.sender` == the engine Safe), `preSignature(bytes)` (read-back: 0 = unsigned). |
| `INavOracle` (declared inline in the .sol) | The minimal `SzipNavOracle` surface the module reads: `navExit()` (= `min(spot, twap)`, NEVER reverts on staleness — the §3 buyer-conservative exit mark), `fresh()` (both pushed legs within `maxAge` — gates `postBid`), `maxAge()` (the NAV-freshness fence bound), `oldestRequiredLegTs()` (SEC-13 — the oldest required-leg push timestamp; the fence anchors `validTo ≤ this + maxAge`). |
| `ICoverageGate` (declared inline in the .sol) | The coverage seam `postBid` reads (the `DurationFreezeModule`): `covered() → bool`. Zero ⇒ gate OFF (M1 / kill-switch). |
| `IERC20Approve` (declared inline) | The `approve(spender, amount)` face the module builds calldata for (the USDC → VaultRelayer allowance). |

## Wiring — internal

### Module identity (clone fact, §18.6)
A `ModuleProxyFactory` clone shares the mastercopy runtime bytecode, so `immutable` values are baked into the
mastercopy at ITS construction and are identical for every clone — they **cannot** carry per-clone `setUp`
config. EVERY wired address/param is therefore plain **set-once storage written in `setUp`** under
`initializer`, NOT `immutable`. The mastercopy is init-locked in its constructor (see `MastercopyInitLock`,
SEC-14) — a bare mastercopy `setUp` reverts `AlreadyInitialized`, and one that was never `setUp` has zero
`operator`/`engineSafe` ⇒ every `postBid` reverts `NotOperator`).

### `setUp(bytes initParams)` (`public override initializer`)
Decodes **10 fields** `(address owner_, address engineSafe_, address operator_, address navOracle_, address
szipUSD_, address usdc_, address settlement_, uint16 dBps_, uint256 buybackCap_, address coverageGate_)`:
- Zero-guards the seven required addresses (`ZeroAddress`); asserts `owner_ != operator_` (`OwnerIsOperator` —
  the Timelock owner must not be the CRE hot key); asserts `0 < dBps_ < 10_000` (`BadDiscount`). `buybackCap_` is
  NOT guarded (0 = kill-switch). `coverageGate_` MAY be `address(0)` (gate OFF) — no zero-check.
- Sets `avatar = target = engineSafe_` — the module is enabled ON the engine Safe and only ever `exec`s through it.
- Writes set-once storage: `engineSafe`, `operator`, `navOracle`, `szipUSD`, `usdc`, `settlement`, `dBps`,
  `buybackCap`, `coverageGate` (the `DurationFreezeModule`; ARMED at deploy, Timelock-re-pointable / kill-switch).
- **Reads LIVE off the settlement** (does not hard-trust a constant): `vaultRelayer = IGPv2Settlement(settlement_).vaultRelayer()` (the USDC `approve` spender) + `domainSeparator = IGPv2Settlement(settlement_).domainSeparator()` (the EIP-712 domain for the uid), caches both.
- `_transferOwnership(owner_)` — the zodiac-core `Module` owner (= the Timelock at item 10).

### `postBid(GPv2OrderInput order)` (`onlyOperator`)
The operator supplies ONLY 3 fields — `{uint256 sellAmount (USDC 6-dp), uint256 buyAmount (szipUSD 18-dp),
uint32 validTo}`; every other GPv2 field is a module-fixed constant (the §4 hardening — no unvalidated field
enters the hash). Validation order:
1. `currentUid.length != 0` ⇒ `BidAlreadyLive` (single-resting-bid invariant — a re-post must `cancelBid` first).
2. `sellAmount == 0 || buyAmount == 0` ⇒ `ZeroAmount`; `buyAmount > MAX_BUY_AMOUNT (1e30)` ⇒ `BuyAmountTooLarge`.
3. `sellAmount > buybackCap` ⇒ `CapExceeded` (so `buybackCap == 0` reverts every post = the kill-switch).
3b. **COVERAGE GATE** (LP path-lock, 2026-06-13): `if coverageGate != 0 && !ICoverageGate(coverageGate).covered()
   ⇒ Undercovered` — a buy-burn bid is a free-side outflow (spends basket USDC to retire szipUSD), blocked while
   sidecar+LP coverage is below the debt floor (incl. a price-drift breach). Transparent at zero senior debt
   (`floor = 0 ⇒ covered() == true`). `coverageGate == 0` is the M1 / kill-switch state.
4. `validTo <= now || validTo > now + MAX_BID_TTL (1 day)` ⇒ `BadValidTo`.
5. **NAV-freshness fence (SEC-13 / L12, leg-anchored):** `anchor = INavOracle(navOracle).oldestRequiredLegTs()`;
   `validTo > anchor + INavOracle(navOracle).maxAge()` ⇒ `ValidToBeyondNavFreshness` (see Gotchas — the collapsed
   "fulfillment controller"). The anchor is the OLDEST required-leg push ts (not post-time), so the mark a fill can
   land against is at most `maxAge` old, not `2·maxAge`. Pure addition (`anchor + maxAge`) — no underflow at the
   `oldest-leg-age == maxAge` / `maxAge == 0` edges. An unset leg (`ts == 0`) ⇒ `anchor == 0` ⇒ fails closed here.
6. `!INavOracle(navOracle).fresh()` ⇒ `StaleNav`; `dBps == 0 || dBps >= 10_000` ⇒ `BadDiscount` (re-asserted). NB
   (SEC-13): an **age-stale pushed leg** now trips the fence (#5) BEFORE this `fresh()` gate (the fence is strictly
   tighter — `anchor + maxAge < now < validTo`); `StaleNav` stays reachable via the **rate-stale** path (fresh pushed
   legs but a stale wired cross-chain rate, which the leg-only anchor does not pre-empt).
7. Read `navExit18 = INavOracle(navOracle).navExit()` (USD-18dp per 1e18 share). **Price bound** (exact
   no-truncation integer form, USD-18dp basis, floored against the buyer): `sellAmount * 1e12 * 10_000 * 1e18 >
   buyAmount * navExit18 * (10_000 − dBps)` ⇒ `BidAboveDiscount`. (The `/10_000` and `/1e18` are moved to the LHS
   as multipliers so the discounted ceiling never rounds UP into an above-NAV fill.)

Then `uid = _orderUid(order)` and TWO `exec`s in ONE tx (atomic — a revert of the 2nd rolls back the 1st):
- `exec(usdc, 0, approve(vaultRelayer, sellAmount), Operation.Call)` — the exact-`sellAmount` allowance.
- `exec(settlement, 0, setPreSignature(uid, true), Operation.Call)` — the **CoW GPv2 presign seam**. `msg.sender`
  to the settlement is the engine Safe (avatar), and `engineSafe` is the `owner` packed into the uid — so
  `setPreSignature`'s `owner == msg.sender` requirement holds.

Records `currentUid = uid`, `currentSellAmount = sellAmount`; emits `BidPosted(uid, sellAmount, buyAmount,
validTo, navExit18, dBps)`. Everything is `Operation.Call` (NO delegatecall) — §10.1.

### `cancelBid()` (operator OR owner)
`msg.sender != operator && msg.sender != owner` ⇒ `NotOperator`. Idempotent no-op (returns, no revert) when no
live bid. Else `exec setPreSignature(uid, false)` + `exec approve(vaultRelayer, 0)` (retract the presignature +
zero the allowance), `delete currentUid`, `currentSellAmount = 0`, emit `BidCancelled`. The presig→false + the
allowance→0 together close the partial-fill double-fill (stale presignature + refreshed approval) vector.

### `_orderUid(order)` (`public view`) — the canonical GPv2 hashing the module owns
Builds the full order from the 3 validated fields + the module-fixed constants and returns the 56-byte uid:
`structHash = keccak256(abi.encode(TYPE_HASH, usdc, szipUSD, engineSafe, sellAmount, buyAmount,
uint256(validTo), APP_DATA, 0 /*feeAmount*/, KIND_BUY, true /*partiallyFillable*/, BALANCE_ERC20,
BALANCE_ERC20))`; `digest = keccak256(0x1901 ++ domainSeparator ++ structHash)`; `uid = digest(32) ++
engineSafe(20) ++ validTo(uint32, 4)`. The module signs the SAME struct it validates — no field is both
operator-supplied and unvalidated. `APP_DATA = bytes32(0)` is pinned (a non-zero/unconstrained appData could
attach hooks/partner-fees the validation never saw). Pinned constants: `TYPE_HASH`, `KIND_BUY` (buy only),
`BALANCE_ERC20`, `MAX_BID_TTL = 1 days`, `MAX_BUY_AMOUNT = 1e30`. A mis-hash fails CLOSED (no solver matches —
liveness only).

### Governed params + Timelock-settable wiring (`onlyOwner` = Timelock, build phase §17)
- `setDiscountBps(dBps_)` — re-asserts `0 < dBps_ < 10_000`; `setBuybackCap(buybackCap_)` — unguarded (0 = kill-switch).
- **8 wiring setters** (emit `WiringSet(slot, value)`): `setOperator`, `setEngineSafe`,
  `setNavOracle`, `setSzipUSD`, `setUsdc`, `setSettlement`, `setVaultRelayer` (each zero-guarded), plus
  `setCoverageGate` (allows `address(0)` = gate OFF kill-switch / re-point the `DurationFreezeModule`). A
  redeployed oracle/Safe/settlement/gate is a one-call re-point, not a redeploy cascade
  ([[oracle-replaceable-timelock-wiring]]).
- **`setAvatar`/`setTarget`** are inherited from zodiac-core `Module` as `onlyOwner` — the CRE `operator` (hot key)
  CANNOT call them (proven by `test_operator_cannot_redirect_safe`); only the Timelock can, a deliberate timelocked
  act. NOT hard-locked (would require marking the vendored `reference/zodiac-core` setters `virtual` — reference is
  kept pristine). Residual: a compromised Timelock could redirect avatar/target — accepted (same Timelock governs
  the whole module).

### `quoteMaxPrice()` view
The CRE bid-builder's sizing seam: `navExit18 × (10_000 − dBps)/10_000 / 1e12` (6-dp USDC ceiling per 1e18
share), rounds DOWN (buyer-conservative — a `sellAmount = maxUsdc6PerShare` per 1e18 `buyAmount` passes the
on-chain gate). `currentBid()` returns `(currentUid, currentSellAmount)` for monitoring.

## Wiring — cross-component (who points at whom)
- **`engineSafe` is the single shared Safe — the three-way wire.** `SzipBuyBurnModule.engineSafe ==
  ExitGate.engineSafe == SzipNavOracle.engineSafe == order.receiver`. The bought szipUSD lands in this one Safe
  (it is the `receiver` + the uid `owner`); `ExitGate.burnFor` burns szipUSD FROM exactly this Safe; and
  `SzipNavOracle` **excludes** this Safe's transient pre-burn szipUSD from the navPerShare denominator
  (`_effectiveSupply = shareToken.totalSupply − engineSafe balance`) so a bought-not-yet-burned position cannot
  dilute NAV. A test asserts `module.engineSafe() == ExitGate.engineSafe()` (PROGRESS row 325).
- **`operator` + `windowController` = the CRE.** The single CRE keeper holds `SzipBuyBurnModule.operator` (drives
  `postBid`/`cancelBid`) AND `ExitGate.windowController` (drives `burnFor`) — it orchestrates the async 3-step
  buy-then-burn directly (no separate on-chain controller; see Gotchas).
- **→ `SzipNavOracle`.** Reads `navExit()` (the price reference), `fresh()` (the post gate), `maxAge()` (the
  fence). Does NOT write the oracle. The oracle's `navExit` = `min(spot, twap)` and never reverts on staleness —
  the module's own `fresh()` gate + the fence are what keep a resting bid from filling against a price that has
  since gone stale.
- **→ `ExitGate.burnFor`.** No call edge from this module — the cycle is async: `postBid` here → CoW solver fills
  the resting order, szipUSD arrives in `engineSafe` → the CRE `windowController` calls `ExitGate.burnFor(amount)`
  separately (it cannot be atomic with the buy — async CoW fill).
- **→ CoW `GPv2Settlement` / `GPv2VaultRelayer`.** `settlement` = `COW_SETTLEMENT 0x9008…ab41` (PRESIGN target,
  `setPreSignature`); `vaultRelayer` = `COW_VAULT_RELAYER 0xC92E…0110` (read LIVE off the settlement in `setUp` —
  the USDC `approve` spender, the address sell tokens are pulled from). `domainSeparator` read LIVE off the
  settlement (`0xd72f…7b4b` on Base 8453). Same settlement address on all chains.

## Item-10 deploy facts (PROGRESS rows 325 / 346 / 350 / 357)
- **Clone via `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in ONE factory tx** (front-run-safe — never the
  two-tx deploy-then-init) (the canonical 8-B5/8-B8/8-B9/8-B14 engine-module pattern). The mastercopy is locked
  AUTOMATICALLY by its constructor (`MastercopyInitLock`, SEC-14) the instant it is deployed — NO separate
  deploy-time lock step, and `setUp` on the mastercopy reverts `AlreadyInitialized`. After cloning,
  **`enableModule(module)` on the engine Safe** so the clone can `exec` through it.
- **`owner = Timelock`, `operator = CRE` — and `owner != operator` is asserted in `setUp`** (the hot key must not
  be the governance owner). Wire the single CRE operator via the `operator` `setUp` field (or `setOperator`).
- **`coverageGate = durationFreeze` wired at `setUp` (ARMED at deploy).** Deploy clones `DurationFreezeModule` at
  the TOP of P6 (before this module) and passes it as the 10th `setUp` arg; a `SeamCoverageGate` assert confirms
  `coverageGate() == durationFreeze`. `postBid` then blocks while `!covered()`. Kill-switch: Timelock
  `setCoverageGate(0)`. build/lp-path-lock.md.
- **Wire `module.engineSafe == ExitGate.engineSafe == SzipNavOracle.engineSafe == order.receiver`** (PROGRESS row
  325). The module side is proven (`module.engineSafe() == ExitGate.engineSafe()`); the **oracle-side**
  `SzipNavOracle.setEngineSafe(engineSafe)` (denominator exclusion of the transient pre-burn szipUSD) is the
  **remaining OPEN item-10 deploy-wiring step**.
- **CoW addresses** (`BaseAddresses.sol`): `settlement = COW_SETTLEMENT 0x9008D19f58AAbD9eD0D60971565AA8510560ab41`;
  `vaultRelayer` + `domainSeparator` are read live in `setUp` (not passed) — `COW_VAULT_RELAYER
  0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` is the verified live value. (`COW_ORDER_SIGNER 0x23dA…1FAB` is
  reference-only — this module self-hashes the uid + signs PRESIGN instead of delegatecalling the order signer.)
- Set the governed params: `dBps` (the haircut, `0 < dBps < 10_000`) + `buybackCap` (the per-bid USDC cap; 0 ⇒
  kill-switch). `MAX_BID_TTL`, `MAX_BUY_AMOUNT`, `APP_DATA` are pinned constants, not deploy args.
- All wiring is **Timelock-settable** (§17) — immutability deferred to pre-prod (supersedes any older
  "renounce-freeze at deploy" framing).

## Gotchas
- **The NAV-freshness fence is the COLLAPSED "fulfillment controller" (credit-union C2, 2026-06-09).** Per the
  superintendent directive there is **no separate `ExitFulfillmentController`** — its only on-chain value-add (the
  `validTo` freshness fence) was folded directly into `postBid` (error `ValidToBeyondNavFreshness`, plus
  `maxAge()` + `oldestRequiredLegTs()` added to the local `INavOracle`). A resting bid must not fill against a NAV
  mark that has since gone stale: `navExit` is priced now off `fresh()` legs, but the order rests until `validTo`,
  so the fence bounds `validTo` to the oracle's freshness window. The CRE drives `postBid`/`burnFor` directly (it
  already holds both `operator` and `windowController`); the UI tracks fills via the existing `BidPosted` / Gate
  `Burned` events.
- **SEC-13 (L12): the fence is LEG-ANCHORED, not post-time-anchored.** It originally read `validTo > now + maxAge`,
  but the legs feeding `navExit` may already be up to `maxAge` old at post-time (`fresh()` only requires age ≤
  `maxAge`), so the worst-case fill-time mark age was `maxAge` (already elapsed) + `maxAge` (resting) = `2·maxAge`.
  It now reads `validTo > oldestRequiredLegTs() + maxAge`, capping the fill-time mark age at exactly `maxAge`.
  `oldestRequiredLegTs()` (additive `SzipNavOracle` view) = min of the two pushed legs (`LEG_ALPHA_USD`,
  `LEG_HYDX_USD`), plus the wired xALPHA rate oracle's `lastUpdate()` when seeded (`!= 0`). Underflow-safe by
  construction (ADDITION, never `maxAge − age`). Side effect (intended, fail-closed): an age-stale pushed leg now
  trips this fence before `fresh()`/`StaleNav` (strictly tighter); an unset leg (`anchor == 0`) also fails closed
  here. Rate-leg window note: the rate's native freshness is its own `maxStaleness` (tighter than `maxAge`), still
  enforced at post-time by `fresh()`; folding its ts into the min only LOWERS the anchor.
- **The fence's `+ maxAge` head-room is inert at the production default; the leg anchor is always active.** The
  `+ maxAge` ceiling binds before `BadValidTo` ONLY when `oldestRequiredLegTs() + maxAge < now + MAX_BID_TTL` — at
  the default (`SzipNavOracle.maxAge == 1 day == MAX_BID_TTL`) with freshly-pushed legs it coincides with the
  post-time ceiling. But because the anchor is the leg ts (not `now`), the moment any required leg ages the fence
  tightens automatically. To make `maxAge` clamp the resting TTL more aggressively, set the oracle `maxAge < 1 day`
  (an immutable ctor arg) or lower `MAX_BID_TTL`.
- **Bid-only — the module never burns, never holds Loot.** The buy and the burn are split by authority; do not
  look for a burn path here. The burn is `ExitGate.burnFor` (windowController), and it is NOT atomic with the buy
  (async CoW fill — a CRE-orchestrated 3-step).
- **Self-hashed uid + `setPreSignature` (Call), NOT a delegatecall to `CowswapOrderSigner`.** Chosen so §10.1's
  `Operation.Call`-only mandate holds, the uid stays in-contract (emittable/testable), and the Safe's storage is
  never handed to an external delegatecall. The uid is proven against a `cast` known-answer vector + the live
  settlement storing it.
- **Single resting bid.** `postBid` reverts `BidAlreadyLive` while a uid is live; a re-post requires `cancelBid`
  (presig→false, allowance→0) then a fresh `validTo`. Outstanding signed USDC ≤ `buybackCap` by construction.
- **0.8.24 pin.** Guards use `if (!cond) revert CustomError()` (the `require(cond, CustomError())` form is 0.8.26+).
