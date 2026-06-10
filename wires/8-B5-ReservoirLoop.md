# 8-B5 — ReservoirLoop cluster (wiring map)

> Source of truth = the kept code: `contracts/src/supply/szipUSD/ReservoirLoopModule.sol`,
> `contracts/src/supply/SzipReservoirLpOracle.sol`, `contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol`,
> `contracts/script/ReservoirMarketDeployer.sol`. Ticket `tickets/sodo/8-B5-reservoir-loop.md` + report
> `reports/8-B5-report.md` + `claude-zipcode.md §4.5.1` are intent — **code wins where they differ**. This doc
> reads the code as the final form. (Test `contracts/test/ReservoirLoopModule.t.sol`.)

## Role
8-B5 is the **strike-financing borrow loop** of the auto-compounder engine (§4.5.1). oHYDX is an option — redeeming
it costs the ~30% strike in USDC (8-B8) — so each harvest needs USDC. The source is **the LP itself**: unstake a
gauge slice (8-B6), POST it as collateral, BORROW the strike, exercise the oHYDX (8-B8) / sell the HYDX (8-B9),
REPAY, and WITHDRAW the LP to re-stake. The LP self-collateralizes its own strike. The defining shape: the engine
Safe **borrows on its OWN EVC account** (borrower-of-record = the Safe, sub-account 0, NOT a fresh `LineAccount`),
so the borrow is account-identity-driven, not operator-on-behalf. The USDC borrow vault **IS the warehouse's
shared resting USDC** (idle depositor cash), which is exactly why the borrow must be pinned to the Safe at the
vault level (the guard) — no third-party ICHI-LP holder may lever depositor funds.

## Contracts involved (what each does)
| Contract | What it is |
|---|---|
| `ReservoirLoopModule` (`is Module`) | The **2nd engine Zodiac Module** (after 8-B14 buy-and-burn), enabled on the engine Safe (`avatar == target == engineSafe`), CRE-`onlyOperator`. Four loop entrypoints `postCollateral`/`borrow`/`repay`/`withdrawCollateral`, each a sequence of `exec(Call, value 0)` with every `receiver`/`owner`/`onBehalfOfAccount` hard-pinned to `engineSafe`. No generic call/exec passthrough, no delegatecall. Operator supplies ONLY scalars; the module builds all calldata to set-once-wired targets. |
| `SzipReservoirLpOracle` (`is ReceiverTemplate, BaseAdapter`) | CRE-fed **push-cache** LP-collateral oracle. Single fixed key (`lpToken`, quote USDC); the EVK read-adapter the reservoir router resolves the LP collateral through (`IPriceOracle`/`BaseAdapter` face) AND the CRE receiver the Forwarder pushes the per-LP-share USD mark to (`reportType LP_MARK = 7`). Stale/missing mark **fails the borrow closed**. |
| `ReservoirBorrowGuard` (`is IHookTarget`) | EVK hook target installed on the USDC borrow vault at `OP_BORROW` (security F8a). Pins the borrow to the engine Safe: the EVK-appended on-behalf account must `== engineSafe`, else revert `NotEngineSafe`. Account-identity gate (NOT operator-authorization). |
| `ReservoirMarketDeployer` (script) | One-time stand-up of the per-strategy borrow market: the LP escrow collateral vault, a dedicated `EulerRouter` wired `escrow → lpToken → lpOracle`, the borrow guard, and the USDC borrow vault (oracle = that router). Governor **RETAINED** at the Timelock on both router and borrow vault. Returns `(escrowVault, borrowVault, router)`. |

## Wiring — internal

### ReservoirLoopModule — ctor / setUp
- **Clone fact (§18.6).** A `ModuleProxyFactory` clone shares the mastercopy runtime bytecode, so `immutable`
  cannot carry per-clone config. EVERY wired address/param is plain **set-once storage written in `setUp` under
  the zodiac-core `initializer`**, NOT `immutable`. `setUp` decodes
  `(owner, engineSafe, operator, evc, borrowVault, escrowVault, lpToken, usdc, borrowCap)`, requires all
  addresses nonzero, requires `owner != operator` (`OwnerIsOperator`), sets `avatar = target = engineSafe`
  (so the module only ever mutates the Safe), and `_transferOwnership(owner_)`.
- **Gates.** `onlyOperator` (the CRE hot key) gates the four loop entrypoints. `onlyOwner` (the Timelock) gates
  `setBorrowCap` + all the §17 re-point setters. The inherited zodiac-core `setAvatar`/`setTarget` are
  `onlyOwner` — the operator **cannot** redirect them; only a deliberate timelocked governance act can.

### ReservoirLoopModule — the four onlyOperator entrypoints (the EVC-account-driving loop)
Every step runs through the private `_exec(to, data)` → `execAndReturnData(to, 0, data, Operation.Call)` and
**hard-reverts on `ok == false`** (see Gotchas — the Safe swallows inner reverts). The borrow/repay/withdraw run
the EVK call on behalf of the Safe via `IEVC.call(target, engineSafe, 0, …)` — the Safe is the EVC msg.sender and
owns the EVC account whose address == the Safe (sub-account 0), so the on-behalf is authorized with **no operator
bit**.

- `postCollateral(lpAmount)` — steps 1–2, exactly **3 `exec`s**: `lpToken.approve(escrowVault, lpAmount)` →
  `IEVC.enableCollateral(engineSafe, escrowVault)` (idempotent — re-enable is an EVC no-op) →
  `escrowVault.deposit(lpAmount, engineSafe)`.
- `borrow(usdcAmount)` — step 3. **Cap check first:** `IBorrowing(borrowVault).debtOf(engineSafe) + usdcAmount >
  borrowCap ⇒ revert CapExceeded` (the AGGREGATE-outstanding bound; `borrowCap == 0` ⇒ every borrow reverts =
  kill-switch). Then 2 `exec`s: `IEVC.enableController(engineSafe, borrowVault)` (idempotent) →
  `IEVC.call(borrowVault, engineSafe, 0, IBorrowing.borrow(usdcAmount, engineSafe))` (receiver = the Safe). The
  EVC end-of-call account-status check enforces health via the router → LP oracle: an over-LTV borrow reverts
  `E_AccountLiquidity`; a stale/missing mark reverts. **Health gates on `borrowLTV`, NOT `liqLTV`** (build
  correction C3 — a new borrow is checked against the lower borrow LTV; the higher liq LTV only governs
  liquidation, so a borrow that just touches `liqLTV` is rejected).
- `repay(usdcAmount)` — step 5, exactly **3 `exec`s**: `usdc.approve(borrowVault, usdcAmount)` →
  `IEVC.call(borrowVault, engineSafe, 0, IBorrowing.repay(usdcAmount, engineSafe))` →
  `usdc.approve(borrowVault, 0)` (reset, no standing approval — security F13). **`repay` does NOT cap**: EVK
  `repay` reverts `E_RepayTooMuch` for a literal amount > outstanding debt (only `type(uint256).max` means
  "all"), so the operator repays the EXACT strike it borrowed (build correction C2 — there is no silent clamp).
- `withdrawCollateral(lpAmount)` — step 6, exactly **1 `exec`** (after a guard):
  `IBorrowing(borrowVault).debtOf(engineSafe) != 0 ⇒ revert DebtOutstanding` (defense-in-depth — the EVC would
  block an unhealthy withdraw anyway, but fail-fast + testable), then
  `IEVC.call(escrowVault, engineSafe, 0, escrowVault.withdraw(lpAmount, engineSafe, engineSafe))`
  (owner = receiver = the Safe). The controller may stay enabled (next loop's enable is idempotent).
- **Views (8-B11/8-B12 back-pressure):** `outstandingDebt()` = `IBorrowing(borrowVault).debtOf(engineSafe)`,
  `postedCollateral()` = `IEVault(escrowVault).balanceOf(engineSafe)` — both LIVE reads off the vault, no cached
  field.
- **Governed param:** `setBorrowCap(uint256)` is `onlyOwner` (the Timelock), NOT operator-settable (security F1).

### ReservoirLoopModule — §17 Timelock-settable wiring
`setEngineSafe` / `setOperator` / `setEvc` / `setBorrowVault` / `setEscrowVault` / `setLpToken` / `setUsdc` are
all `onlyOwner`, each with a zero-address guard, each emitting `WiringSet(slot, value)`. `setEngineSafe` keeps
`avatar`/`target` in **lockstep** with `engineSafe` so the borrower-of-record + every receiver/owner invariant
holds. Build-phase flexibility (§17), lock pre-prod. The CRE operator hot key cannot call any of these.

### SzipReservoirLpOracle — ctor / push / read
- **Ctor** `(forwarder, quote_, validityWindow_, lpToken_)` → `ReceiverTemplate(forwarder)` (reverts on zero
  forwarder — the only writer). Sets `quote = USDC`, `lpToken` (the single 18-dp key), `validityWindow` (the
  generous engine-cadence read-staleness window), and derives `scale = ScaleUtils.calcScale(LP_DECIMALS=18,
  quoteDecimals, quoteDecimals)`.
- **Push** `_processReport(report)` (override; only the Forwarder reaches it via `ReceiverTemplate`): decodes the
  shared §4.4 envelope `(uint8 reportType, bytes payload)`, requires `reportType == LP_MARK (7)` (else
  `InvalidReportType`), decodes `(uint256 mark, uint32 ts)`, and `_writePrice(mark, ts)` →
  fail-closed write guards `mark != 0` (`PriceOracle_InvalidAnswer`), `mark <= uint208.max`
  (`PriceOracle_Overflow`), `ts <= block.timestamp` (`FutureTimestamp`); caches `Cache{uint208 price, uint48
  timestamp}`. There is **no controller-seed path** — the Forwarder push is the only writer (the difference from
  the lien `ZipcodeOracleRegistry`).
- **Read** `_getQuote(inAmount, base, quoteAsset)` (override): requires `quoteAsset == quote && base == lpToken`
  (else `PriceOracle_NotSupported`); `cache.timestamp == 0` (unset) reverts `PriceOracle_NotSupported`; if
  `block.timestamp - cache.timestamp > validityWindow` reverts `PriceOracle_TooStale` — **the stale path fails
  the borrow CLOSED** (router read reverts → EVC account-status check reverts), never opening an unsafe
  position. Returns `ScaleUtils.calcOutAmount(inAmount, price, scale, false)` — **rounds DOWN, against the
  borrower**.
- **§17 wiring:** `setQuote` (re-derives `scale`), `setLpToken`, `setValidityWindow` — all `onlyOwner` (the OZ-5
  `Ownable` owner = the Timelock). Re-pointing is the router governor's job, not an oracle-local owner.

### ReservoirBorrowGuard — the borrow pin
- **Ctor** `(eVaultFactory_, engineSafe_)` — sets `eVaultFactory` (the EVK GenericFactory), `engineSafe` (the
  sole legal borrower), and `owner = msg.sender` (the deployer, then `transferOwnership(timelock)`). It is **NOT
  OZ `Ownable`** — the inherited `Context._msgSender()` would collide with the hook's EVK trailing-data
  `_msgSender()` decoder, so `onlyOwner` checks the RAW `msg.sender` directly (the admin is never an EVK
  on-behalf call). §2371 of the spec records this manual-owner exception (shared with `CREGatingHook`).
- **`isHookTarget()`** returns the magic selector only when `eVaultFactory.isProxy(msg.sender)` (a recognized
  vault); else `0`.
- **`fallback()`** is the only gate, op-agnostic: `if (_msgSender() != engineSafe) revert NotEngineSafe()`.
  Installed only on `OP_BORROW`, so it only ever guards borrows; reverts with no return data; non-payable.
- **`_msgSender()`** trusts the EVK-appended trailing 20 bytes ONLY when `msg.sender` is a factory proxy
  (else a non-vault caller could spoof an authorized account) — replicates `BaseHookTarget._msgSender()`
  verbatim (evk-periphery is not remapped, so the logic is inlined).
- **§17 wiring:** `setEVaultFactory`, `setEngineSafe`, `transferOwnership` — all `onlyOwner` (raw `msg.sender`).

### ReservoirMarketDeployer — `deploy(Params)`
Modeled on WOOF-04 `openLine` steps 1–3 with **two deliberate differences**: (1) the governor is **RETAINED**
(not renounced to `address(0)` like WOOF-04 per-line routers — LTV/caps/oracle stay tunable under the §17
2-day veto as LP economics shift); (2) the deployer **creates the borrow vault** (oracle = the router),
resolving the router/borrow-vault ordering cycle (router built BEFORE the borrow vault). Sequence:
1. **Escrow collateral vault** — `factory.createProxy(address(0), false, abi.encodePacked(lpToken, address(0),
   address(0)))` (bare 1:1 holding box, no oracle / unit-of-account); `setHookConfig(0,0)`;
   `setGovernorAdmin(address(0))`.
2. **Dedicated `EulerRouter`** `new EulerRouter(evc, address(this))` (deployer = governor at birth):
   `govSetResolvedVault(escrowVault, true)` (unwrap escrow shares → lpToken, 1:1) +
   `govSetConfig(lpToken, usdc, lpOracle)` (price `(lpToken, USDC)` via the LP oracle).
3. **Borrow guard + borrow vault** — `createProxy(address(0), false, abi.encodePacked(usdc, router, usdc))`
   (oracle = the router, unit-of-account = USDC → 1:1); `setInterestRateModel(irm)`; `setHookConfig(new
   ReservoirBorrowGuard(factory, engineSafe), OP_BORROW)` (**never hook `OP_REPAY`**); `setLTV(escrowVault,
   borrowLTV, liqLTV, 0)` (1e4 scale, ramp 0 — accepts the escrow as collateral).
4. **Birth-time wire-check (W3)** `_assertWired` — `resolveOracle(1e18, escrowVault, usdc)` must resolve
   `rBase == lpToken && rOracle == lpOracle`, else `WireMismatch`.
5. **`transferGovernance(governor)`** — hands the router governance to the Timelock, RETAINED.

## Wiring — cross-component (who points at whom)
- **`borrowVault` = the warehouse USDC resting vault.** The deployer creates the borrow vault; in production the
  EulerEarn supply queue (the warehouse, 8-Bw) **allocates idle depositor USDC into it** so it IS the
  `USDC Resting Vault` — the un-utilized USDC the credit lines have not drawn (PROGRESS row 333). Depositor
  principal is protected by the ICHI-LP collateral, never by the counterparty; the borrow revolves (out only for
  the short loop window). The module's `borrowVault` slot points at this same vault.
- **`lpToken` = the SHARED ICHI vault address (the load-bearing identity invariant).** The single production POL
  ICHI vault share token MUST be the SAME address wired into ALL of: the 8-B5 escrow collateral-vault `asset()`
  (`ReservoirMarketDeployer.lpToken`), the module's `lpToken`, the `SzipReservoirLpOracle` `LP_MARK` key, the
  8-B6 `LpStrategyModule.ichiVault` (`setUp`), and the `SzipNavOracle` basket-LP leg (PROGRESS row 338). 8-B6
  unstakes that LP to the Safe (loop step 1) and 8-B5 `postCollateral` deposits the SAME token into the escrow —
  wire two different LP addresses and the harvest loop silently fractures (the unstaked LP cannot be posted).
- **Reservoir governor retained at the Timelock.** Router + borrow vault governor = the §17 `TimelockController`
  (`transferGovernance(governor)`), so LTV/caps/oracle stay tunable under the 2-day veto — distinct from the
  frozen per-line lien routers (§4.7).
- **CRE operator.** The module's `operator` is the single immutable CRE operator identity (§8.7) that runs the
  loop (8-B11 sequences `postCollateral`→`borrow`→exercise(8-B8)→sell(8-B9)→`repay`→`withdrawCollateral`). The
  oracle's writer is the Chainlink Forwarder (`CRE_KEYSTONE_FORWARDER`), pushing the LP mark each epoch.

## Item-10 deploy facts (PROGRESS rows 333 / 335 / 336 / 338)
- **Deploy the reservoir market** via `ReservoirMarketDeployer.deploy(Params)` (GenericFactory escrow + router +
  guard + borrow vault) — NOT `EdgeFactory` (which renounces governance + bakes LTV, making post-deploy
  `setLTV`/`setCaps` and oracle re-point impossible).
- **Set the module's `borrowVault`** to the deployer's borrow-vault address; keep its governor at the Timelock
  (LTV/caps tunable) and **retain the router governor** via `transferGovernance(timelock)` (RETAINED, not
  `address(0)`). The fork test proves the loop against a directly-seeded borrow vault; production points the EE
  supply queue at it (an EulerEarn curator/allocator config, NOT a `WarehouseAdminModule` op — row 333).
- **Wire LP-token identity** across 8-B5 / 8-B6 / oracle / NAV (row 338): deploy MUST assert
  `LpStrategyModule.ichiVault() == reservoir escrow vault asset() == lpOracle key`.
- **Wire the CRE operator** into the module (`operator`) and the **LP-oracle Forwarder** (`CRE_KEYSTONE_FORWARDER`
  passed to the `SzipReservoirLpOracle` ctor); the 8-B11 CRE workflow computes the per-LP-share mark off-chain
  (`(reserve_xALPHA × priceXAlpha + reserve_zipUSD × priceZipUSD) / ICHI_LP_totalSupply` — the same reserve×price
  math `SzipNavOracle` runs for the basket LP leg) and pushes it each epoch within `validityWindow` (CRE-03 /
  §8.6).
- **Audit sweep (row 335, OPEN):** author the loop into `audit/2.md` Phase L (an L-step post→borrow→repay→withdraw
  debt 0→strike→0; N-steps over-LTV / stale-mark / over-cap / non-operator / third-party-direct-borrow each
  revert) + the `audit/3-results.md` authority rows (operator-only entrypoints; owner-only `borrowCap`;
  `setAvatar`/`setTarget` locked; reservoir governor retained at the Timelock; the `OP_BORROW` guard pins the
  Safe).

## Gotchas
- **The Safe swallows inner reverts → `_exec` bubbles (build correction C1).** Gnosis Safe
  `execTransactionFromModule(ReturnData)` catches an inner revert and returns `(false, revertData)` rather than
  bubbling. An unchecked `exec` would silently swallow a failed EVC borrow/repay/withdraw and the step would
  wrongly report success. `_exec` uses `execAndReturnData` and, on `ok == false`, **assembly-reverts the inner
  return data** (surfacing `E_AccountLiquidity` / `PriceOracle_TooStale` / `E_RepayTooMuch` / …); falls back to
  `ExecFailed` if the Safe returns no revert data.
- **`LP_MARK = 7` is per-receiver-scoped — never collides with `NavOracle NAV_LEG = 7`.** Both are the same
  numeral `7` on **different receivers**; each `WriteReport` names exactly one receiver, so there is no
  collision (§8.0 / §8.6 ratification; distinct from the lien registry's `REVALUATION = 3`). `LP_MARK = 7` is
  pinned at `SzipReservoirLpOracle.sol:27`.
- **`borrowCap` is AGGREGATE outstanding, not per-call.** `borrow` checks `debtOf(engineSafe) + amount >
  borrowCap`; `borrowCap == 0` is the kill-switch (every borrow reverts). `onlyOwner` (Timelock), never operator.
- **`repay` has no cap and rejects over-repay.** EVK `repay` reverts `E_RepayTooMuch` for a literal amount >
  debt (only `type(uint256).max` = "all") — the operator must repay the exact borrowed strike.
- **Borrow gates on `borrowLTV`, not `liqLTV`.** A new borrow is health-checked against the lower borrow LTV; the
  self-collateralizing ~30% strike sits well inside it.
- **Manual owner on the guard.** `ReservoirBorrowGuard` is deliberately NOT OZ `Ownable` (the `Context._msgSender`
  vs the hook's EVK `_msgSender()` decoder collision); `onlyOwner` checks raw `msg.sender`.
