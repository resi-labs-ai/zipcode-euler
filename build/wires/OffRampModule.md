# OffRampModule — credit-union C1 zipUSD→USDC off-ramp (wiring map)

> Source of truth = `contracts/src/supply/szipUSD/OffRampModule.sol` (the kept code is FINAL). Ticket
> `tickets/sodo/credit-union.md` §C1 + report `reports/credit-union-report.md` are intent — code wins.
> Sibling engine modules: `RecycleModule` (8-B10), `SzipBuyBurnModule` (8-B14).

## Role
An engine **Zodiac Module** enabled on the **rq/main Safe** (`avatar == target == rqSafe == Baal.avatar()`). It is
the back-office leg of the szipUSD CoW-book exit (`claude-zipcode.md` §6.4): it turns the rq Safe's **basket zipUSD
into USDC** by driving the BUILT senior `ZipRedemptionQueue` (item 9) at par through its on-demand settle cycle
(the 30-day epoch time gate was removed 2026-06-12 — see `9-ZipRedemptionQueue.md`) — sourcing the USDC the
treasury's 8-B14 buy-and-burn bids exits with from un-lent EulerEarn cash. It is a **pure driver / C1 only**: par
and the `min(available, pending)` settle fill are the queue's job; this module adds **no redemption logic**.
Operator-gated and manual (the CRE sizes each `requestRedeem`/`claim`), never autonomic. It never touches the
warehouse Safe and never sells xALPHA or any other basket leg.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `OffRampModule` (`is Module`) | The driver. `setUp(bytes)`-under-`initializer` decodes 5 addresses; `onlyOperator` `requestRedeem(zipAmount)` / `claim(assets)`; private bubbling `_exec`; 4 Timelock (`onlyOwner`) wiring setters. Set-once storage `rqSafe`/`operator`/`zipUSD`/`queue`, **not `immutable`** (§18.6 clone fact — a `ModuleProxyFactory` clone shares mastercopy bytecode). |
| `IZipRedemptionQueue` (inline iface) | The minimal queue surface driven: `scaleUp() view`, `requestRedeem(shares, requester, owner)`, `withdraw(assets, receiver, requester)`. |
| `ZipRedemptionQueue` (`src/supply/ZipRedemptionQueue.sol`, item 9 BUILT) | The par-burn sink (pro-rata engine collapsed out 2026-06-13 — single requester). `requestRedeem` is `onlyRedeemController` (C4 gate); `settleEpoch()` `onlyController` (CRE) fills `min(available, pending)` + burns; `withdraw`/`redeem` claim at par; `scaleUp` = `10**(zipDec−usdcDec)` (mutable, re-derived on `setTokens`). |
| `WarehouseAdminModule` (8-Bw BUILT) | **NOT called by this module.** The CRE separately drives REDEEM/REPAY through it to fund the queue's USDC per settle. |

## Wiring — internal
- **It is a `Module`.** `setUp(bytes initParams) public override initializer` decodes
  `(owner, rqSafe, operator, zipUSD, queue)` (5 addresses). ORDER is load-bearing: validate **all five nonzero**
  (`ZeroAddress`) and `owner != operator` (`OwnerIsOperator`) FIRST, then set `avatar = target = rqSafe`, store the
  4 wiring slots, **then** `_transferOwnership(owner)`. No live-read / staticcall in `setUp`. `initializer` makes it
  callable once (mastercopy init-locked at deploy; re-`setUp` reverts).
- **`requestRedeem(uint256 zipAmount) external onlyOperator`** — the off-ramp entrypoint. Guards: `zipAmount != 0`
  (`ZeroAmount`) and `zipAmount % IZipRedemptionQueue(queue).scaleUp() == 0` (`NotWholeUnit`) — `scaleUp()` is read
  **LIVE** off the queue each call, never the hard-coded `1e12` (it is mutable, re-derived on `setTokens`). Then it
  drives the rq Safe through the bubbling `_exec` in three legs:
  1. `_exec(zipUSD, IERC20.approve(queue, zipAmount))`;
  2. `_exec(queue, IZipRedemptionQueue.requestRedeem(zipAmount, rqSafe, rqSafe))` — positional
     `(shares, requester, owner)`, so **`requester == owner == rqSafe`**;
  3. `_exec(zipUSD, IERC20.approve(queue, 0))` — allowance reset.
  Emits `Redeemed(zipAmount, rqSafe)`.
- **`claim(uint256 assets) external onlyOperator`** — the realize leg. Guard `assets != 0` (`ZeroAmount`); one
  `_exec(queue, IZipRedemptionQueue.withdraw(assets, rqSafe, rqSafe))` (positional `(assets, receiver, requester)`)
  → USDC lands back in the rq Safe (the basket). Emits `Claimed(assets, rqSafe)`.
- **How it reaches the queue (via the Safe).** `_exec(to, data)` is private and calls the inherited
  `execAndReturnData(to, 0, data, Operation.Call)` — a **value-0 Call through the rq Safe** (Gnosis Safe
  `execTransactionFromModuleReturnData`). Because the queue is called **by the Safe**, the queue sees
  `msg.sender == rqSafe`: this satisfies (a) C4's `onlyRedeemController` (wired to the rq Safe) and (b) the queue's
  `owner == msg.sender` check (since `owner == rqSafe`), and (c) the USDC claim/escrow accrues to the rq Safe.
- **Bubbling `_exec` (load-bearing).** The Safe's `execTransactionFromModuleReturnData` **catches** inner reverts
  and returns `(false, revertData)` rather than bubbling. So `_exec` hard-reverts on `ok == false`: it `revert`s the
  inner `revertData` via assembly when present, else `ExecFailed()`. A plain `exec` would let the Safe **silently
  swallow** a failed `requestRedeem`/`withdraw` and leave a dangling approval.
- **Timelock-settable wiring (build phase, §17).** Each slot has an `onlyOwner` setter, `ZeroAddress`-guarded,
  emitting `WiringSet(bytes32 slot, address value)`: `setRqSafe` (**also re-points avatar+target in lock-step**),
  `setOperator`, `setZipUSD`, `setQueue`. Slots are **re-pointable, not set-once-frozen** (§17 build-phase doctrine).
  The inherited `setAvatar`/`setTarget` are `onlyOwner` (Timelock only, never the operator) — deliberately not
  hard-locked (would dirty the vendored zodiac-core setters).

## Wiring — cross-component (who points at whom)
- **operator = the CRE.** The single `operator` slot gates `requestRedeem`/`claim`. The CRE supplies the policy each
  period (when, how much) against liquidity on hand; `owner` (Timelock) != `operator` (CRE) is enforced at `setUp`.
- **The redeemController-authorization seam (C4).** The module never holds queue authority directly — it `exec`s
  **through** the rq Safe, so the queue's `msg.sender` is the **rq Safe**, not the `OffRampModule` contract.
  Therefore `ZipRedemptionQueue.redeemController` MUST be wired to the **rq Safe address** (item 10 asserts it).
  Wiring it to the module address would make the whole C1 path revert `NotRedeemController`. Honest framing
  (report §3 / ticket C4): this gate authorizes the rq Safe — whose action surface is the union of all Zodiac
  modules enabled on it — and its value is closing the **epoch-dilution / senior-USDC-griefing** vector of an open
  `requestRedeem`, NOT theft prevention (par is fixed, `settleEpoch` is `onlyController`, the queue is non-sweepable).
- **zipUSD source = USDC sink = the rq Safe.** The basket zipUSD redeemed lives on the rq Safe; the claimed USDC
  lands back on the **same** rq Safe (the basket), where the 8-B14 buyback spends it. `requester` is never
  operator-supplied (always `rqSafe`) — destination integrity, no cross-Safe routing.
- **NOT wired to the warehouse.** The off-ramp never calls `WarehouseAdminModule` and never touches the warehouse
  Safe. The CRE separately drives REDEEM (`eePool.redeem(shares, safe, safe)`) → REPAY (`usdc.transfer(queue, …)`)
  to deliver USDC into the queue, which `settleEpoch()` (CRE, `onlyController`) then reserves at par. The off-ramp's
  USDC source (un-lent EulerEarn cash) is the **same** cash senior redemption draws — coupling noted, operator-managed.

## Item-10 deploy facts
> No deploy script exists yet (`OffRampModule` does not appear in `contracts/script/`); item 10 is the next backlog
> item. These are the wiring obligations the kept code imposes — to be discharged by the item-10 script.
- **Clone, not `new`.** Deploy via the zodiac-core `ModuleProxyFactory.deployModule(mastercopy, setUpCalldata, salt)`
  (CREATE2) — the clone `setUp`s **atomically** with the deploy. `setUpCalldata` = `abi.encode(owner, rqSafe,
  operator, zipUSD, queue)`. Set-once storage (not `immutable`) is exactly what makes the shared-bytecode clone work.
- **Init-lock the mastercopy.** After deploying the `OffRampModule` mastercopy, call `setUp` on it once (or otherwise
  consume its `initializer`) so the mastercopy is inert and cannot be hijacked.
- **`enableModule` on the rq Safe.** The deployed clone must be enabled as a Zodiac module on the rq Safe
  (`Baal.avatar()`) so its `exec…FromModule` calls are authorized.
- **owner = Timelock, != operator (CRE).** `owner_` decoded in `setUp` becomes the module owner via
  `_transferOwnership`; it is the Timelock, distinct from the CRE `operator` (the `OwnerIsOperator` guard enforces it).
- **Wire + assert `redeemController == rqSafe`.** Call `ZipRedemptionQueue.setRedeemController(rqSafe)` (Timelock,
  `onlyOwner`) and **assert** the queue's `redeemController` == the rq Safe (the avatar the module drives) — NOT the
  module address. The fork proof is `RedeemRequest.sender == rqSafe` after an operator `requestRedeem` through the
  real `exec` (a `vm.prank(module)` shortcut would hide a mis-wire).
- **Wiring slots match the queue.** Assert `OffRampModule.queue == ZipRedemptionQueue`, `OffRampModule.zipUSD` ==
  the queue's `zipUSD`, and (production) the live `scaleUp()` the module reads is the queue's.

## Gotchas
- **C2 (the NAV-freshness fence) is NOT here.** The credit-union rework (`reports/credit-union-report.md`) deleted
  the planned `ExitFulfillmentController` and **collapsed** the `validTo ≤ now + maxAge` NAV-freshness fence into
  `SzipBuyBurnModule.postBid` (new error `ValidToBeyondNavFreshness`, `maxAge()` added to that module's local
  `INavOracle`) — because the CRE already holds both `operator` + `windowController` and drives `postBid`/`burnFor`
  directly. **OffRampModule is C1 only** (the zipUSD→USDC off-ramp driver); it carries no NAV freshness, no price
  bound, and no burn logic.
- **`scaleUp()` is read LIVE, never hard-coded.** The queue's `scaleUp` is mutable storage (re-derived on
  `setTokens` = `10**(zipDec−usdcDec)`). An amount that is a whole multiple of `1e12` but not of the queue's live
  `scaleUp` correctly reverts `NotWholeUnit` — the guard staticcalls the queue every call.
- **The off-ramp is not NAV-neutral per step.** At `requestRedeem` alone the basket drops by `zipAmount` with no
  offsetting USDC; the USDC only arrives at `claim` (after the CRE's `settleEpoch`). NAV-neutrality holds across the
  **full cycle** (`requestRedeem` → `settleEpoch` → `claim`), ±round-down dust — not per leg.
- **The queue has no cancel.** Once `requestRedeem` escrows zipUSD into the queue there is no recall — the only path
  out is the epoch settle + `claim`. The operator must size each `requestRedeem` accordingly.
- **`setRqSafe` moves three slots.** Re-pointing `rqSafe` also re-points `avatar` and `target` in lock-step; the
  three must never diverge (the module only ever mutates its avatar, which must equal the rq Safe).
