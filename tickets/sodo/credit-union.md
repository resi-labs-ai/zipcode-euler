# credit-union.md — BUILD SPEC: the szipUSD exit (off-ramp + NAV-freshness fence + CoW book)

> **Status: build-spec — CRITIC-HARDENED + spec-triaged (steps 1-3 of `audit/adversarial-spec/README.md` DONE
> 2026-06-09).** 5 critics fanned out (junior-dev / spec-fidelity / ref-verifier / qa / security). Spec gaps fixed
> in `claude-zipcode.md` FIRST (the stale "liquidity-window / intent-queue / engine-Safe" language in §6.4 / §6-intro
> / §17 / §11 → the CoW-book model). Ticket gaps folded back below: C1 reads `scaleUp()` live + bubbling `_exec`;
> **C2 COLLAPSED (superintendent 2026-06-09) — no separate `ExitFulfillmentController`; the `validTo ≤ maxAge` fence
> folds into `SzipBuyBurnModule.postBid` and the CRE (already `operator` + `windowController`) drives `postBid`/
> `burnFor` directly**; C3 full orphan-deletion list + the `test_invariant_sequence` landmine; C4
> `redeemController == rq Safe` (not the module) + Timelock-settable + honest griefing-vector framing; `burnFor`
> documented as unbounded-operator-trusted. The dangling "§5.6/§5.8" citations (no such § in claude-zipcode.md —
> those decisions were locked in THIS doc's session) are removed.
> **BUILT + KEPT 2026-06-09:** C1 OffRampModule 17/17, C2 fence (SzipBuyBurnModule 36/36 incl. 3 new), C3 ExitGate
> 14/14, C4 ZipRedemptionQueue 44/44; full non-fork suite green except 2 pre-existing **Stream-2 `divert`** failures
> (a parallel workstream, untouched here). `reports/credit-union-report.md`.
> **C5 is the frontend interface ticket — DEFERRED to the dedicated post-deploy frontend sweep** (`superintendent-allaprima.md`
> → `tickets/frontend/`, memory `frontend-after-contracts`), NOT this contract-track window. Sibling spec = `solvency.md`
> (the loss side). No emojis; contract-cited; keep lean.

---

## A. Architecture (locked)

Two layers, one principle: **the front is a uniform CoW book; the back office is the treasury's zipUSD arb.**

**Front (UI) — one CoW order book, exiters rest the orders.** Every szipUSD holder exits the same way: sign a
CoW **sell order** at their own limit. That resting book *is* the queue — capital-light (the exiter's token
rests, not parked treasury USDC). Fills come from either side: the **treasury** (just-in-time, never standing)
or **external buyers** (adversarial). Patience vs price is the exiter's own call; a holdout simply sits unfilled
and keeps earning. Discovery throughout — the junior is NAV/market-priced, never administered (a junior is paid
the yield *for* bearing the risk; there is no par floor on szipUSD).

**Back office — two treasury conversions that fund the front:**
- **zipUSD ↔ USDC** (par, the 7540): the off-ramp. Sources the USDC the treasury bids with; defends the senior
  peg; banks the par/market spread for stayers. This spec.
- **xALPHA ↔ ALPHA** (the bridge): the volatile leg — feeds the **loss** waterfall (`solvency.md`), not exits.

**The treasury is the buyer-of-last-resort on the book, fed by its own back office** — `navExit`-priced and
**never above NAV** (paying >NAV robs stayers). On every fill it buys szipUSD → `ExitGate.burnFor` burns it →
supply shrinks, basket untouched → **NAV/share rises, stayers win** (the kicker is socialized, never extracted).

**Manual, not autonomic.** These are **operator tools**, not a liquidity engine. The contracts enforce safety
bounds (never pay beyond available cash, never force-liquidate a line, never bid above NAV); the CRE/operator
supplies the policy (when to process, how much to redeem, what price to post) judged each period against
liquidity on hand and upcoming maturities. Same shape as every engine module: operator-gated,
bounds-not-validates.

**The forfeit is retired.** Today's only exit executor, `ExitGate.processWindow` (`:250-278`), ragequits the
**full claim** against the free main-Safe basket and closes it (`c.filled = c.shares`, `:271`) — so an exiter at
utilization `U` forfeits `U` of their equity to stayers (test `test_processWindow_freeze_pays_free_equity_only`).
That path is replaced by the CoW-buy-and-burn rail.

---

## B. Safe topology (CORRECTED — verified against the substrate)

The substrate (`SummonSubstrate`, 8-B1) summons exactly **two Safes**. The credit warehouse is a third, separate
Safe. **There is no "engine Safe."** The engine Zodiac modules (8-B5…B14, the auto-compounder + the 8-B14
buy-burn) are *enabled on* the rq Safe; `engineSafe` is just the avatar **label** those modules use — it resolves
to the **rq Safe** in the built substrate, not a fourth wallet.

| Safe | Holds | What acts on it | Role |
| --- | --- | --- | --- |
| **rq Safe** = `Baal.avatar()` (a.k.a. `mainSafe` / the modules' `engineSafe`) | the **basket** (zipUSD + xALPHA + ICHI LP), NAV-counted; **transient pre-burn szipUSD** from a buyback fill (excluded from the NAV supply denominator, `_effectiveSupply:413-418`) | `ExitGate` (custody), `DurationFreezeModule`, the engine modules (`SzipBuyBurnModule`/`RecycleModule`/`SellModule`) | ragequit target; the basket, the buyback, and the redeemed USDC all live here |
| **non-rq Safe** = `sidecar` | committed (frozen) basket slice — NAV-counted | `DurationFreezeModule` | the structural freeze |
| **warehouse** | EulerEarn senior shares | `WarehouseAdminModule` (Zodiac Roles) | senior backing; sources redemption USDC |

NAV: `grossBasketValue()` counts rq + non-rq balances; `_effectiveSupply = totalSupply − (rq Safe's transient
szipUSD)`. Because the basket and the buyback share the rq Safe, **there is no cross-Safe USDC routing**.

---

## C. Build items

### C1. `OffRampModule` (NEW — build ticket → `tickets/sodo/`)

**Deliverable.** `contracts/src/supply/szipUSD/OffRampModule.sol` — `contract OffRampModule is Module`
(zodiac-core, `pragma 0.8.24`), a CRE-operator-gated Zodiac Module **enabled on the main/Baal Safe**
(`avatar == target == mainSafe`). It turns **basket zipUSD → USDC** by driving the built `ZipRedemptionQueue`,
so the treasury can fund exits from un-lent EulerEarn cash. Pure driver — **no new redemption logic.** Plus
`contracts/test/OffRampModule.t.sol` (recording-mock Safe + Base fork against the real queue/warehouse).

**Spec §.** `claude-zipcode.md` §6.1/§6.3/§8.2 (senior redemption + epoch settlement), §4.5.1 + §10.1 (engine
module pattern), §17 (build-phase Timelock-settable wiring). Cross: `solvency.md` is NOT touched.

**Model from (VERIFIED).**
- `is Module` / clone discipline / `setUp` under `initializer` / `onlyOperator` / `exec(...,Operation.Call)` —
  model exactly on `SzipBuyBurnModule.sol` and `RecycleModule.sol` (both `is Module`, set-once storage NOT
  immutable — §18.6 clone fact). All wired addresses are plain set-once storage, mastercopy init-locked.
- `ZipRedemptionQueue` (`contracts/src/supply/ZipRedemptionQueue.sol`, BUILT) — the redemption engine:
  - `requestRedeem(uint256 shares, address requester, address owner) external nonReentrant returns (uint256)`
    (`:238`). Pulls `IERC20(zipUSD).safeTransferFrom(owner, queue, shares)`; requires `owner == msg.sender` OR
    `isOperator[owner][msg.sender]`; `shares` must be a whole multiple of `scaleUp` (=1e12); the **`requester`**
    arg is the claim key that later withdraws.
  - `settleEpoch() external nonReentrant` (`:261`) — **`onlyController`** (`NotController`, `:262`); 30-day epoch;
    pro-rata partial fill at par; burns `zipUSD` (`:279/286`); CRE-driven.
  - `withdraw(uint256 assets, address receiver, address requester) external nonReentrant returns (uint256)`
    (`:297`) — claim USDC at par; caller = `requester` OR its 7540 operator.
  - **No cancel** once escrowed. Errors: `NotWholeUnit`, `NotAuthorized`, `NotController`, `EpochNotElapsed`,
    `InsufficientClaimable`. Events: `RedeemRequest`, `EpochSettled`, `Withdraw`.
- `WarehouseAdminModule` (`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`, BUILT) — sources the
  USDC the queue settles against, **already CRE-driven, not part of this module**: op `REDEEM=3`
  (`eePool.redeem(shares, safe, safe)`) then `REPAY=4` (`usdc.transfer(repaySink==queue, amount)`), both via
  `roles.execTransactionWithRole`. The OffRampModule does NOT call this — it is the warehouse-side half that the
  CRE already runs to fund the epoch.

**Starting state.** Basket zipUSD sits in `mainSafe`. The queue + warehouse path is built and funds USDC into the
queue per epoch. What is absent: anything that pushes the **main Safe's own** zipUSD into the queue.

**Do NOT.**
- Do NOT add redemption/par/epoch logic — drive `ZipRedemptionQueue` as-is (par + 30-day epoch + pro-rata are
  its job; this module is a thin driver).
- Do NOT call `WarehouseAdminModule` / touch the warehouse Safe (different avatar; the CRE drives REDEEM/REPAY).
- Do NOT redeem more than the main Safe's zipUSD balance; do NOT sell xALPHA or any other basket leg here.
- Do NOT add a recipient parameter for the redeemed USDC beyond the wired `requester` sink (destination
  integrity).
- Do NOT make it autonomic — `redeem`/`claim` are operator-gated calls, sized by the operator each period.

**Key requirements.**
1. `is Module, ReentrancyGuard`; `setUp(bytes)` under `initializer` decodes `(owner, rqSafe, operator,
   zipUSD, queue)`; `avatar = target = rqSafe`; `_transferOwnership(owner)`. All set-once storage.
   `owner != operator`; non-zero guards. (`rqSafe` = `Baal.avatar()` — the same Safe the buyback runs on.)
2. `requestRedeem(uint256 zipAmount) external onlyOperator` — drives the rq Safe via a **bubbling `_exec`** (the
   `RecycleModule._exec` pattern: `execTransactionFromModuleReturnData` then **revert on `success==false`,
   bubbling the inner revert data** — a plain `exec` would let the Safe SWALLOW a queue revert and silently no-op,
   leaving a dangling approval; see ref-verifier + qa). Three legs:
   (a) `IERC20(zipUSD).approve(queue, zipAmount)`;
   (b) `ZipRedemptionQueue.requestRedeem(zipAmount, rqSafe, rqSafe)` — positional args are
   `(shares, requester, owner)`, so `requester == owner == rqSafe` (the Safe is the `_exec` caller, so the queue's
   `owner == msg.sender` check holds AND the USDC claim accrues to the rq Safe);
   (c) `approve(queue, 0)` reset.
   Require `zipAmount > 0` (`ZeroAmount`) and `zipAmount % IZipRedemptionQueue(queue).scaleUp() == 0`
   (`NotWholeUnit`) — **read `scaleUp()` LIVE from the queue; do NOT hard-code `1e12`** (it is mutable storage
   re-derived on `setTokens`, `ZipRedemptionQueue.sol:72/:162`).
3. `claim(uint256 assets) external onlyOperator` — drives the rq Safe (same bubbling `_exec`) to call
   `ZipRedemptionQueue.withdraw(assets, rqSafe, rqSafe)` = `(assets, receiver, requester)`. USDC lands back in the
   rq Safe (the basket) where the buyback spends it — no cross-Safe routing. Require `assets > 0`.
4. Timelock (`onlyOwner`) wiring setters for each slot (§17); emit `WiringSet(slot, value)`.
5. Events: `Redeemed(zipAmount, requester)`, `Claimed(assets, receiver)`. Errors: `NotOperator`, `ZeroAddress`,
   `OwnerIsOperator`, `ZeroAmount`, `NotWholeUnit`.

**Done when.** Unit (RecordingSafe model = `RecycleModule.t.sol`): operator `requestRedeem` produces the exact
3-leg exec shape — call 0 `zipUSD.approve(queue,zipAmount)`, call 1 `queue.requestRedeem(zipAmount,rqSafe,rqSafe)`
(assert the calldata triple), call 2 `zipUSD.approve(queue,0)`; non-operator reverts `NotOperator`; `zipAmount==0`
reverts `ZeroAmount`; a whole-against-1e12-but-not-against-live-`scaleUp` amount reverts `NotWholeUnit` (deploy a
non-18/6 queue so `scaleUp != 1e12` — proves the live read); **a reverting inner `requestRedeem` BUBBLES** (live
RecordingSafe forced to fail call index 1 → the module reverts, not silently succeeds); the `setUp` discipline set
(wires 5 storage slots, rejects `owner==operator`, rejects zero in each, `initializer`-once, mastercopy inert).
Fork (Base): full cycle — `requestRedeem` → CRE-equiv `settleEpoch` after warehouse REDEEM/REPAY → `claim` lands
USDC at par; main-Safe zipUSD down exactly `zipAmount` immediately after `requestRedeem`; **NAV-neutrality across
the FULL cycle** (`grossBasketValue` after `claim` == before `requestRedeem`, ±round-down dust — NOT per-step: at
`requestRedeem` alone the basket drops by `zipAmount` with no offsetting USDC; the USDC only arrives at `claim`).
Mapped to a new `audit/2.md` Phase-S step.

**Depends on.** `ZipRedemptionQueue` (item 9, BUILT-VERIFIED), `WarehouseAdminModule` (8-Bw, BUILT).

---

### C2. NAV-freshness fence — `SzipBuyBurnModule.postBid` (CHANGE — COLLAPSED, no new contract)

> **DECISION — COLLAPSED (superintendent 2026-06-09): do NOT build a separate `ExitFulfillmentController`.** The
> earlier draft (a thin Ownable coordinator holding `operator` + `windowController`, posting the bid + burning the
> fill) was a redundant middle layer. Two facts kill the need for a contract: (1) **the CRE operator already holds
> both roles** — it IS `SzipBuyBurnModule.operator` and `ExitGate.windowController`, so it calls `postBid` and
> `burnFor` directly (CRE → module, no CRE → controller → module hop). (2) **The only piece with real on-chain value
> is the `validTo ≤ now + maxAge` bound** (so a resting bid can't fill against a NAV mark that has since gone stale)
> — that belongs *inside* `SzipBuyBurnModule.postBid` (read `navOracle.maxAge()`, cap `validTo`), a tiny addition to
> a built contract, not a new one. The UI tracks fills via the existing `BidPosted` / `ExitGate.Burned` events; the
> `liquiditySignal` view is dropped (the CRE/UI read `freezeModule.utilization()` + the rq-Safe USDC balance directly
> off-chain). Only build a separate controller later **if** `postBid`+`burnFor` must be atomic or the CRE's discretion
> must be fenced behind extra governance — neither is needed for M1. *(This reverses the critic-triage "keep it thin"
> recommendation; the superintendent owns the call.)*

**Deliverable.** A small addition to `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` (the BUILT 8-B14 module):
the NAV-freshness fence on the resting bid. No new contract, no new role to wire. Plus boundary tests.

**Spec §.** `claude-zipcode.md` §6.4 (the CoW-book exit), §7 (NAV freshness — `fresh()`/`maxAge`). `reports/baal-spec.md` §7.

**Model from (VERIFIED, BUILT).** `SzipBuyBurnModule.postBid(GPv2OrderInput{sellAmount, buyAmount, validTo})`
already enforces `validTo ∈ (now, now + MAX_BID_TTL=1day]` (`BadValidTo`), `fresh()` (`StaleNav`), and the price
bound (`BidAboveDiscount`). Its local `INavOracle` interface declares `navExit()`/`fresh()` only. `SzipNavOracle`
exposes `maxAge` (`uint256 public immutable`, auto-getter `maxAge()`) — the freshness window.

**Key requirements.**
1. Add `maxAge()` to the module's local `INavOracle` interface.
2. In `postBid`, after the existing `BadValidTo` check and before `fresh()`, add:
   `if (order.validTo > block.timestamp + INavOracle(navOracle).maxAge()) revert ValidToBeyondNavFreshness();`
   + the new error `ValidToBeyondNavFreshness`. This binds before `BadValidTo` whenever `maxAge < MAX_BID_TTL`, and
   is a no-op when `maxAge == MAX_BID_TTL` (the default real-oracle config), so existing bids are unaffected.

**Do NOT.** Do NOT change the price bound, the presign path, the cap, or the single-resting-bid rule. Do NOT add a
controller or a new role. Do NOT make the CRE's discretion contract-fenced (M1 = operator-trusted, §13).

**Done when.** `MockNavOracle` gains a settable `maxAge()` (default `1 days` == `MAX_BID_TTL`, so the fence is a
no-op at default and the prior 33 tests are unchanged); `validTo == now + maxAge` SUCCEEDS, `== now + maxAge + 1`
reverts `ValidToBeyondNavFreshness`, and with `maxAge < MAX_BID_TTL` the fence binds before `BadValidTo`. The CRE
orchestration (post → fill → `burnFor`) and the UI fill-tracking (`BidPosted`/`Burned`) need no contract change.

**Depends on.** `SzipBuyBurnModule` (8-B14, BUILT), `SzipNavOracle.maxAge()` (BUILT). No dependency on C1.

---

### C3. Retire the forfeit — `ExitGate.processWindow` (CHANGE — fold into the ExitGate ticket)

**Deliverable.** **Delete** the forfeit + the on-chain queue **and all symbols it orphans.** The CoW book *is* the
queue now (resolved this session; §6.4 spec edit landed). Remove:
- the functions `processWindow`, `requestExit`, `cancelExit` + the storage `claims` array + `queueHead`;
- the now-orphaned **`Claim` struct**, the **`claimCount()` view** (reads `claims.length`), the internal
  **`_basketTokens()`** (only caller was `processWindow`);
- the orphaned **errors** `NotClaimOwner`/`NoSuchClaim`/`AlreadyClosed` and **events** `ExitRequested`/`ExitFilled`/
  `ExitCancelled`/`WindowProcessed` (only thrown/emitted by the deleted functions).
**MUST SURVIVE (do NOT touch):** `depositFor`, `burnFor`, `previewDeposit`, **both `_one(...)` overloads** (still
used by `depositFor` AND `burnFor` — easy to over-delete), the `windowController` slot + `setWindowController`, the
`engineSafe` slot + `setEngineSafe`, and the **`NotWindowController` error** (still thrown by `burnFor`). The exit
path becomes: exiter rests a CoW sell order → `SzipBuyBurnModule` (treasury) or external fills → `burnFor`.

**Do NOT.** Do NOT keep `processWindow` in any form (it confiscates `U` of equity — the bug). Do NOT remove
`burnFor` (the retire leg), `depositFor` (issuance), `_one`, or `NotWindowController`.

**Done when.** All deleted-symbol tests in `ExitGate.t.sol` are removed: `test_requestExit_and_cancel`,
`test_processWindow_pays_pro_rata_in_kind`, `test_processWindow_multi_asset_in_kind`,
`test_processWindow_freeze_pays_free_equity_only` (the named forfeit test), `test_processWindow_onlyController_and_empty`,
**and the landmine `test_invariant_sequence`** (it calls `requestExit` + `processWindow` but is NOT named `*processWindow*`,
so a name-pattern delete MISSES it and breaks the build — delete it or rewrite it to drop the exit-queue calls). A grep
over `src test script` for `processWindow|requestExit|cancelExit|\bclaims\b|claimCount|queueHead|_basketTokens|ExitRequested|ExitFilled|ExitCancelled|WindowProcessed|NotClaimOwner|NoSuchClaim|AlreadyClosed`
returns ZERO hits outside the deleted lines (qa C3.2). `forge test` green, no regression to the remaining suite.

**Depends on.** The §6.4 spec edit (landed). The replacement rail (CoW buy-burn = `SzipBuyBurnModule` + the CRE
driving `postBid`/`burnFor`, with the C2 freshness fence) already exists — no controller.

---

### C4. Internalize the 7540 — `ZipRedemptionQueue` (CHANGE)

**Deliverable.** **Hard-gate `requestRedeem`** to the off-ramp path — "must exit through the vault" (resolved this
session). VERIFIED: `settleEpoch` is **already** `onlyController` (`:262`); `requestRedeem` is currently **open**
(any `owner`/operator). Add a **Timelock-settable** `redeemController` slot + `onlyRedeemController` on
`requestRedeem`, a `setRedeemController(address) onlyOwner` setter (`ZeroAddress` guard, `RedeemControllerSet`
event — re-pointable per §17 build-phase, **NOT set-once**), and a `NotRedeemController` error. The epoch/par/burn
core is UNCHANGED (item 9 stays BUILT-VERIFIED); only `requestRedeem`'s authority + the public surface change.

**CRITICAL — the authorized caller is the rq SAFE, not the C1 module.** C1's `OffRampModule` calls
`exec(queue, requestRedeem(...))`, so the `msg.sender` the queue sees is the **rq Safe** (the avatar the module
drives), NOT the `OffRampModule` contract. Therefore `redeemController` MUST be wired to the **rq Safe address**.
Wiring it to the module address would make the entire C1 fork path revert. (Honest framing: this gate authorizes
the **rq Safe**, whose action surface is the union of all Zodiac modules enabled on it — it does not
cryptographically single out C1. Its security value is **closing the epoch-dilution / senior-USDC-griefing vector**
of an OPEN `requestRedeem` — an external whale escrowing just before `settleEpoch` to shrink honest pro-rata fills
and drain the un-lent USDC senior redemption competes for, §F — NOT theft prevention: par is fixed, `settleEpoch`
is `onlyController`, the queue is non-sweepable, so an open queue enables no theft, only griefing.)

**Do NOT.** Do NOT alter `scaleUp`/par/epoch/pro-rata. Do NOT gate `withdraw`/`redeem`/`settleEpoch`/`setOperator` —
existing requesters' **claim** path stays open (only new escrow is gated).

**Done when.** A random EOA, the module address itself, and an old-style `owner==msg.sender` caller all revert
`NotRedeemController` (qa C4.1); the off-ramp path succeeds **proven via a FORK test through the real `exec`** —
wire `redeemController = rqSafe`, call `offRamp.requestRedeem(zipAmount)` as operator, assert the queue's
`RedeemRequest.sender == rqSafe` (this is the proof the real `exec`-driven `msg.sender` matched the gate; a
`vm.prank(module)` unit shortcut would pass against the WRONG sender and hide a mis-wire) + main-Safe zipUSD
actually decreased (qa C4.2); an existing requester's `withdraw`/`redeem` still settles and `settleEpoch` stays
`onlyController` (qa C4.3); `setRedeemController` is `onlyOwner` + `ZeroAddress`-guarded + re-pointable; `forge test`
green.

**Depends on.** C1 (the off-ramp drives the rq Safe, the sole authorized caller). Resolved this session = hard-gate.

---

### C5. Secondary-swap support (INTERFACE ticket → `tickets/inflow/`)

**Deliverable.** The Vue/Inflow wiring for the CoW book: place/cancel szipUSD (and zipUSD) sell orders, show
`navExit()` and the standing treasury bid next to the book, surface the **liquidity signal** (`DurationFreezeModule.utilization()`
+ the rq-Safe USDC balance, read directly), and confirm a fill **closed on-chain** (the `ExitGate.Burned` event). No
new contract — szipUSD/zipUSD are transferable ERC20s; CoW order placement is off-chain.

**Back-pressure (all ALREADY BUILT — C2 collapsed, so there is no controller surface to demand):**
- The **completion signal** is the existing `ExitGate.Burned(amount)` (the treasury fill's paired on-chain burn),
  paired with `SzipBuyBurnModule.BidPosted`/`BidCancelled` for the standing-bid state. CoW fills off-chain, so the UI
  confirms via these events, not the orderbook.
- The **liquidity signal** is two direct reads, not a contract view: `DurationFreezeModule.utilization()` + the
  rq-Safe (`ExitGate.mainSafe()`) USDC balance.
- Price marks: `SzipNavOracle.navExit()`/`fresh()`; the standing treasury max price `SzipBuyBurnModule.quoteMaxPrice()`.

**Model from (euler-lite files to mirror — verified to exist this window):** `composables/useSwapPageLogic.ts`
(quote/plan/execute harness), `composables/cowswap/useCowSwapExecutionCore.ts` (CoW execution; **EOA-sign via
wagmi `useSignTypedData` — no ERC-1271 path in the reference**, so a smart-account holder must presign on-chain via
`GPv2Settlement.setPreSignature` — call this out in the UX), `entities/cowswap/` (SDK type re-exports;
`cancelCowSwapOrder`/`fetchCowSwapOrderStatus`), `abis/erc20.ts`, `reference/euler-interfaces/addresses/` (8453).

**Done when.** The interface ticket lists those files, specifies EOA-order vs on-chain-presign for smart accounts,
defines the soft-vs-hard cancel mode, and wires the completion signal (`ExitGate.Burned`) + the standing-bid state
(`SzipBuyBurnModule.BidPosted`/`BidCancelled`/`quoteMaxPrice()`) + the liquidity-signal direct reads. All surfaces
ALREADY BUILT (no controller).

---

## D. Decisions

**RESOLVED (baked above):**
- **USDC routing** — DEAD. No separate engine Safe; basket + buyback + redeemed USDC all on the one rq Safe. No
  hop, no `sweepUsdc`.
- **Queue collapse** — RESOLVED. CoW book is the queue; `requestExit`/`cancelExit`/`claims` + the orphaned
  `Claim`/`claimCount`/`_basketTokens`/exit-events/exit-errors deleted (C3).
- **Hard-gate `requestRedeem`** — RESOLVED. The `redeemController` is the **rq Safe** (the module `exec`s through
  it, so the Safe is `msg.sender`); the gate closes the epoch-dilution / senior-USDC-griefing vector, not theft (C4).
- **Controller nature** — RESOLVED (superintendent 2026-06-09): **COLLAPSE it — no separate controller.** The CRE
  already holds `operator` + `windowController` and drives `postBid`/`burnFor` directly; the only on-chain value-add
  (the `validTo ≤ maxAge` fence) folds into `SzipBuyBurnModule.postBid`. (Reverses the critic-triage "keep it thin"
  call.) See the C2 section.

- **Pricing `d` / drift** — RESOLVED: **operator sets the bid price manually each period.** The actual bid
  (effective discount) is operator-supplied per `postBid`, off live data, with short `validTo` — exactly "tune it
  over time." `dBps` stays a **Timelock safety floor** ("never bid above `navExit×(1−d_floor)`") so a compromised
  operator key can't overpay; the operator prices at or below it. The NAV-drift risk is absorbed by the operator's
  live pricing + short `validTo` (C2's on-chain `validTo ≤ maxAge`), not a hard-coded constant. No fixed `d` to
  pick — only the floor `d_floor` (a §17 governed value) to set conservatively.

(No remaining cold-build blockers — the items above are baked.)

---

## E. Verified integration surface (quick reference)

| Contract | File | Key surface (BUILT) |
| --- | --- | --- |
| `ZipRedemptionQueue` | `src/supply/ZipRedemptionQueue.sol` | `requestRedeem(shares,requester,owner):238` (owner==sender/operator), `settleEpoch():261` onlyController, `withdraw():297`, `redeem():318`; `scaleUp=1e12`; no cancel |
| `WarehouseAdminModule` | `src/supply/CreditWarehouse/WarehouseAdminModule.sol` | ops REDEEM=3 `eePool.redeem(shares,safe,safe)`, REPAY=4 `usdc.transfer(repaySink,amount)`; CRE-driven via Roles |
| `SzipBuyBurnModule` | `src/supply/szipUSD/SzipBuyBurnModule.sol` | `postBid(GPv2OrderInput):241` onlyOperator, price bound `:257`, `cancelBid():283`, `quoteMaxPrice():340`; receiver/owner=engineSafe; `MAX_BID_TTL=1 day`; `dBps`,`buybackCap` governed |
| `ExitGate` | `src/supply/szipUSD/ExitGate.sol` | `depositFor():175`, `requestExit():222`, `processWindow():250` (forfeit, retire), `burnFor():283` windowController-only; `mainSafe=Baal.avatar()` |
| `SzipNavOracle` | `src/supply/SzipNavOracle.sol` | `navExit()=min(spot,twap):380` (no stale revert), `navEntry()=max:368` (StalePrice), `fresh():387`, `valueOf():437`, `grossBasketValue():273`, `poke():255`, `maxAge` (immutable, `:69`), `provision`, `_effectiveSupply():442` (engineSafe excluded) — *(working-tree lines; the file has uncommitted edits that shifted the committed `:235/:252/:348/:357/:364/:408/:413` refs ~20 down — symbols are unchanged, re-read the file)* |
| `DurationFreezeModule` | `src/supply/szipUSD/DurationFreezeModule.sol` | `utilization():233` donation-immune; `requiredFraction()=utilization`; `commit`/`release` operator-only |
| `IGPv2Settlement` | `src/interfaces/cow/IGPv2Settlement.sol` | `setPreSignature(uid,bool)` (owner==msg.sender), `vaultRelayer()`, `domainSeparator()` |

> Two notes on the table (current built state): the `engineSafe` wired in `SzipBuyBurnModule`/`SzipNavOracle`
> **= the rq Safe** (§B), not a separate Safe. The `ExitGate` `requestExit`/`processWindow` rows are the
> forfeit + on-chain queue that **C3 deletes**.

---

## F. Out of scope

The **loss waterfall** (markdown, xALPHA slash, yield diversion, lien workout) is `solvency.md`. This spec
assumes lines are *performing* — just illiquid. When a line goes *bad*, solvency.md takes over. The off-ramp's
USDC source (un-lent EulerEarn) is the **same** un-lent cash senior redemption draws — the two compete; that
coupling is noted but managed by the operator, not encoded here.
