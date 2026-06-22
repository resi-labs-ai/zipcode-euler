# 8-B9 SellModule — Algebra swap seam (sellHydx HYDX→USDC + buyXAlpha zipUSD→xALPHA + sellXAlpha xALPHA→zipUSD) (wiring map)

> **X-Ray (security verdict):** rated **ADEQUATE** — recipient/pair hard-pinned to the vault; the HYDX size cap
> is the distinctive control (the minimum-out bounds price, the cap bounds size). Proven unit + live Algebra
> router (34 unit + 4 fork). Report: `contracts/src/supply/szipUSD/x-ray/SellModule.md` (scope:
> `portfolio-map.md`). ELI20: `docs/supply/szipUSD/SellModule.md`. This doc is the code-truth wiring map.

> Source of truth = `contracts/src/supply/szipUSD/SellModule.sol` (the kept code is FINAL/AUTHORITATIVE — code
> wins). Ticket `tickets/sodo/8-B9-sell-module.md` + report `reports/8-B9-report.md` are intent only.
> Sibling engine modules: `ExerciseModule` (8-B8, the primary model), `FarmUtilityLoopModule` (8-B5),
> `LpStrategyModule` (8-B6), `HarvestVoteModule` (8-B7), `SzipBuyBurnModule` (8-B14), `RecycleModule` (8-B10).

## Role
The **sixth engine Zodiac Module** (`is Module`) of the auto-compounder harvest loop, enabled on the szipUSD engine
Safe (`avatar == target == juniorTrancheEngine`), CRE-operator-gated. It owns the **SWAP leg** (`claude-zipcode.md` §4.5.1,
8-B9): per harvest the CRE robot (8-B11) market-sells the exercised HYDX (handed off from 8-B8) → USDC **immediately**
so the proceeds can repay the 8-B5 strike-borrow (`debtOf(safe)→0`), and it also runs the **zipUSD→xALPHA on-our-POL**
swap the 8-B10/8-B13 recycle/compound Mode-B/C policy consumes. It is **pure swap mechanism** — Algebra
`SwapRouter.exactInputSingle` only: **NO EVC leg, NO oracle, NO LP, NO veNFT, NO oHYDX exercise, NO repay/borrow, NO
free-value accumulator** (those are 8-B5/8-B6/8-B7/8-B8/SzipNavOracle/8-B10). The repay that consumes the USDC is
8-B5's `FarmUtilityLoopModule.repay`; the free-value crediting is 8-B10's `creditFreeValue` — both CRE-sequenced **after**
this sell. The operator supplies **only scalars** (`amountIn`, `minOut`, `deadline`); the module builds all calldata.

It also exposes **`sellXAlpha` (xALPHA→zipUSD)** — the reverse of `buyXAlpha` on the same POL pair. No live-ops loop
uses it; it exists to (a) **unstrand the xALPHA leg in the global wind-down** — after `LpStrategyModule.removeLiquidity`
decomposes the LP into zipUSD + xALPHA, `sellXAlpha` routes the xALPHA back to zipUSD (which then exits to USDC via the
senior par queue — xALPHA has no direct USDC pool, it is the bridge stand-in), and (b) let the protocol **accept/recycle
xALPHA** for incentive/LM strategies. See `SzipBuyBurnModule` for the wind-down orchestration.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `SellModule` (`is Module`) | The swap driver. `setUp(bytes)`-under-`initializer` decodes **8 addresses + 1 uint256**; three `onlyOperator` entrypoints `sellHydx`/`buyXAlpha`/`sellXAlpha` sharing a private `_swap` (approve→`exactInputSingle`→reset-approve); private bubbling `_exec`; an `onlyOwner` `setMaxSellHydx`; 7 Timelock (`onlyOwner`) address-wiring setters. Set-once storage `juniorTrancheEngine`/`operator`/`swapRouter`/`hydx`/`usdc`/`zipUSD`/`xAlpha` + the `maxSellHydx` cap — **not `immutable`** (§18.6 clone fact: a `ModuleProxyFactory` clone shares mastercopy bytecode, so per-clone config must be `setUp` storage). |
| `ISwapRouter` (`src/interfaces/algebra/ISwapRouter.sol`) | The minimal Algebra **Integral** `SwapRouter` surface the module calls — only `exactInputSingle(ExactInputSingleParams)`. The struct carries `(tokenIn, tokenOut, deployer, recipient, deadline, amountIn, amountOutMinimum, limitSqrtPrice)` — **no `fee` field**, a `deployer` field, and `limitSqrtPrice` (NOT `sqrtPriceLimitX96`) ⇒ Algebra Integral, not Uniswap V3. On-chain-verified selector `0x1679c792` against the deployed router `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`. |
| `IERC20` (`@openzeppelin/contracts/token/ERC20/IERC20.sol`) | Supplies the `approve.selector` for the swap-allowance set + reset legs of `_swap`. |

## Wiring — internal
- **It is a `Module`.** `setUp(bytes initParams) public override initializer` decodes
  `(owner, juniorTrancheEngine, operator, swapRouter, hydx, usdc, zipUSD, xAlpha, maxSellHydx)` — **8 addresses + 1 uint256**.
  ORDER is load-bearing: validate **all eight addresses nonzero** (`ZeroAddress`) FIRST, then `owner != operator`
  (`OwnerIsOperator`), then `maxSellHydx > 0` (`ZeroAmount` — a zero cap would brick `sellHydx`), then set
  `avatar = target = juniorTrancheEngine`, store the 7 wiring slots + the cap (emitting `MaxSellHydxSet`), **then**
  `_transferOwnership(owner)`. **No live-read / staticcall in `setUp`** — every token is wired directly (unlike 8-B8,
  which live-read `paymentToken` off oHYDX). `initializer` makes it callable once (mastercopy init-locked in its
  constructor (see `MastercopyInitLock`, SEC-14); re-`setUp` reverts).
- **`sellHydx(uint256 amountIn, uint256 minOut, uint256 deadline) external onlyOperator returns (uint256 amountOut)`**
  — the **8-B5 strike-loop repay leg**. Guard `amountIn > maxSellHydx` reverts `ExceedsMaxSell` (the `>` guard, so
  `amountIn == maxSellHydx` is allowed), then `amountOut = _swap(hydx, usdc, amountIn, minOut, deadline)`. USDC lands
  in the engine Safe.
- **`buyXAlpha(uint256 amountIn, uint256 minOut, uint256 deadline) external onlyOperator returns (uint256 amountOut)`**
  — the **POL buy leg** (Mode-B/C, consumed by 8-B10/8-B13). Identical mechanism on the wired POL pair:
  `amountOut = _swap(zipUSD, xAlpha, amountIn, minOut, deadline)`. **Uncapped here** — no `maxSellHydx` check (different
  token; bounded upstream by 8-B10's `freeValueAccrued` gate). xALPHA lands in the engine Safe.
- **`sellXAlpha(uint256 amountIn, uint256 minOut, uint256 deadline) external onlyOperator returns (uint256 amountOut)`**
  — the **reverse POL leg** (wind-down LP→legs→USDC hop + xALPHA recycle): `amountOut = _swap(xAlpha, zipUSD, amountIn,
  minOut, deadline)`. zipUSD lands in the engine Safe. **Deliberately uncapped** — `maxSellHydx` exists only because the
  oHYDX harvest system becomes unprofitable past a clip (a HYDX-specific ceiling); xALPHA is our own POL asset sold back
  into our own pair, so a size cap would be arbitrary. `minOut`+`deadline` remain the price/staleness guards; throughput
  stays 8-B11/8-B12 CRE/off-chain policy.
- **The shared `_swap(tokenIn, tokenOut, amountIn, minOut, deadline)` private helper.** Guard `amountIn == 0 ||
  minOut == 0` reverts `ZeroAmount` (a zero slippage floor = no protection — fail fast). Then exactly **three**
  `_exec`s, in order:
  1. `_exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, router, amountIn))` — the swap allowance from the
     Safe (`router = swapRouter` cached to a local);
  2. `_exec(router, abi.encodeCall(ISwapRouter.exactInputSingle, (params)))` — **typed `encodeCall`, NOT
     `encodeWithSelector`**, so a struct-field-order regression fails to compile rather than silently mis-encoding.
     The params struct is **hard-pinned**: `deployer: address(0)`, `recipient: juniorTrancheEngine`, `limitSqrtPrice: 0`,
     `tokenIn`/`tokenOut` per entrypoint, `deadline`/`amountIn`/`amountOutMinimum: minOut` passed through;
  3. `_exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, router, uint256(0)))` — reset the residual
     allowance (no standing approval; hygiene parity with 8-B8/8-B5).
  **Only the 2nd `_exec` return is decoded** (`amountOut = abi.decode(ret, (uint256))`); the two `approve` returns are
  ignored. Then `emit Sold(tokenIn, tokenOut, amountIn, amountOut)` and return. A malformed (`< 32`-byte) 2nd return
  reverts the decode (never emits garbage).
- **Bubbling `_exec` (load-bearing).** `_exec(to, data)` is private and calls the inherited
  `execAndReturnData(to, 0, data, Operation.Call)` — a **value-0 Call through the engine Safe**. The Gnosis Safe's
  `execTransactionFromModuleReturnData` **catches** inner reverts and returns `(false, revertData)` rather than
  bubbling, so `_exec` hard-reverts on `!ok`: it `revert`s the inner `revertData` via assembly
  (`revert(add(ret, 0x20), mload(ret))`) when present, else `ExecFailed()`. This is what surfaces a router slippage
  revert (`amountOut < minOut`) or a past-deadline revert — an unchecked `exec` would silently swallow a failed swap
  and wrongly report success, leaving a dangling approval.
- **`minOut` is the SLIPPAGE GUARD, not a malware defense.** The Algebra router enforces `amountOut >= minOut` and
  reverts otherwise (the revert bubbles through `_exec`), so a price move between the CRE's quote and tx execution
  safely ABORTS instead of dumping at a bad price. `minOut` bounds **price**, never **size**. The module asserts no
  `amountOut <= X` ceiling — more output is strictly good, and the router floor already bounds the decoded value.
- **The per-call `maxSellHydx` SIZE cap (defense-in-depth, user-directed).** `uint256 public maxSellHydx` is set-once
  in `setUp` (default wired 300_000e18 at deploy ≈ ~3% slippage ≈ ~$10k weekly clip on the live pool). It is a SIZE
  backstop that `minOut` cannot provide: a compromised operator could otherwise `sellHydx(wholeBasket, minOut=1)` and
  crater HYDX (we are long it via veHYDX + the LP). `sellHydx` reverts `ExceedsMaxSell` above it; `buyXAlpha` is NOT
  capped. **It is set-once config, NOT a running accumulator** — the module stays stateless beyond wiring (sibling
  symmetry). `setMaxSellHydx(uint256 newMax) external onlyOwner` (the Timelock, NOT the hot operator) re-sizes it to
  track pool depth, reverts `ZeroAmount` on zero; both `setUp` and the setter `emit MaxSellHydxSet`.
- **Timelock-settable wiring (build phase, §17).** Each of the 7 address slots has an `onlyOwner` setter,
  `ZeroAddress`-guarded, emitting `WiringSet(bytes32 slot, address value)`: `setJuniorTrancheEngine` (**also re-points
  avatar+target in lock-step**), `setOperator`, `setSwapRouter`, `setHydx`, `setUsdc`, `setZipUSD`, `setXAlpha`. Slots
  are **re-pointable, not set-once-frozen** (§17 build-phase doctrine). `setOperator` additionally re-checks
  `operator != owner` (`OwnerIsOperator`, SEC-15) so a re-point cannot collapse the two roles into one key. The inherited `setAvatar`/`setTarget` are
  zodiac-core `onlyOwner` (Timelock only, never the operator) — deliberately not hard-locked (marking the vendored
  zodiac-core setters `virtual` would dirty the pristine reference dep).
- **`onlyOperator` gate.** `modifier onlyOperator { if (msg.sender != operator) revert NotOperator(); }` gates **both**
  swap entrypoints. `owner` (Timelock) != `operator` (CRE) is enforced at `setUp`.

## Wiring — cross-component (who points at whom)
- **operator = the CRE robot (8-B11).** The single `operator` slot is the sole caller of `sellHydx`/`buyXAlpha`/`sellXAlpha`. The
  CRE sizes `amountIn` + `minOut` off `pool.globalState()` off-chain (the §9.3 per-order slippage cap → a modest
  cushion) and sequences sell → 8-B5 `repay` → 8-B6 re-stake → 8-B10 `creditFreeValue`. The module is correctly
  agnostic to regime / cutoff / loop-size / per-epoch throughput (all 8-B11 CRE policy).
- **swapRouter = the live Algebra Integral `SwapRouter` `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`** (Base 8453,
  `BaseAddresses.ALGEBRA_SWAP_ROUTER`). The swap target + the `approve` spender. On-chain-verified:
  `router.factory() == 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E`.
- **hydx / usdc — the `sellHydx` pair.** `hydx 0x00000e7efa313F4E11Bfff432471eD9423AC6B30`,
  `usdc 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. The **HYDX/USDC pool `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`
  is a BASE-FACTORY pool ⇒ `deployer == address(0)`**: `pool.factory() == router.factory() == 0x36077D39…` and
  `factory.poolByPair(HYDX, USDC)` resolves the live pool, so the router derives the pool+direction from
  `(tokenIn, tokenOut, deployer=0)` — no pool address, no `zeroToOne` is passed. `pool.token0() == HYDX`,
  `pool.token1() == USDC`. **HYDX in** is handed off from 8-B8 `exercise`; **USDC out** is the input to the 8-B5 repay,
  then the residual feeds 8-B10 `creditFreeValue`.
- **zipUSD / xAlpha — the `buyXAlpha`/`sellXAlpha` POL pair (both directions).** `zipUSD` = our `ESynth` (deployed at
  runtime, no fixed constant); `xAlpha` = the 8x bridge stand-in (runtime). Both wired at deploy and mocked in unit
  tests — **no `BaseAddresses` constants** (runtime addresses). **The POL pool identity is load-bearing:** because
  `_swap` hard-pins `deployer: address(0)` for ALL legs, the wired POL pool **must itself be a base-factory (deployer-0)
  Algebra pool** or both POL legs revert. There is no live zipUSD/xALPHA POL pool on Base yet, so `buyXAlpha`/`sellXAlpha`
  are **unit-proven only** this window; their live-pool fork proof is deferred to 8-B10/8-B13 integration (the router
  calldata shape is fork-grounded by the shared sell-leg sig-verify).
- **recipient / output destination = the engine Safe, always.** `exactInputSingle.recipient` is hard-pinned to
  `juniorTrancheEngine` — the output token (USDC or xALPHA) can only ever land in the basket, never the operator or a third
  party. `tokenIn` is pulled FROM the same Safe (it holds the input + grants the transient allowance).
- **NOT wired to 8-B5/8-B8/8-B10.** The module never calls the borrow/repay, the exercise, or the free-value
  accumulator. It only moves tokens within the one engine Safe via the swap; the CRE chains the neighbors after.

## Item-10 deploy facts
> No deploy script exists for this module yet; item 10 (`PROGRESS.md` rows 350/352/353) is the next backlog item.
> These are the wiring obligations the kept code imposes — discharged by the item-10 script.
- **Clone, not `new` (row 350).** Deploy via zodiac-core `ModuleProxyFactory.deployModule(mastercopy, setUpCalldata,
  salt)` (CREATE2) so the clone `setUp`s **atomically in one factory tx (front-run-safe)** — never two-tx
  deploy-then-init (the proven 8-B5/8-B8/8-B14 pattern). `setUpCalldata = abi.encode(owner, juniorTrancheEngine, operator,
  swapRouter, hydx, usdc, zipUSD, xAlpha, maxSellHydx)`. Set-once storage (not `immutable`) is exactly what makes the
  shared-bytecode clone work.
- **Init-lock the mastercopy.** The mastercopy is locked AUTOMATICALLY by its constructor (`MastercopyInitLock`,
  SEC-14) the instant it is deployed — NO separate deploy-time lock step, and `setUp` on the mastercopy reverts
  `AlreadyInitialized`. (The un-setUp mastercopy is also already inert by storage — `sellHydx` reverts
  `NotOperator`, every getter returns 0.)
- **`enableModule` on the engine Safe.** The deployed clone must be enabled as a Zodiac module on the engine Safe so
  its `exec…FromModule` calls are authorized.
- **owner = Timelock, != operator (row 350).** Wire the single CRE operator as `SellModule.operator` (sole caller);
  `owner_` becomes the module owner via `_transferOwnership` and is the **Timelock**, distinct from the CRE operator
  (the `OwnerIsOperator` guard enforces it at `setUp`).
- **Wire the router + tokens (row 350).** `swapRouter` → the live Algebra router `0x6f4b…`; `hydx`/`usdc` → the live
  tokens; `zipUSD`/`xAlpha` → our `ESynth` + the bridge xALPHA. Assert `module.swapRouter() == ALGEBRA_SWAP_ROUTER`.
- **Wire `maxSellHydx = 300_000e18` (row 352).** The per-call HYDX size backstop ≈ ~3% slippage / the weekly clip on
  the live pool. **GOVERNED value, NOT a contract constant** — `owner` (the Timelock, not the hot operator) re-sizes it
  via `setMaxSellHydx` as pool depth changes.
- **The `buyXAlpha` POL pool wiring + deployer-shape gate (row 353).** When the zipUSD/xALPHA POL pool is created
  (8x bridge + POL LP), wire `zipUSD`/`xAlpha` to the live pair and assert it is the SINGLE address the Mode-B/C buy
  leg trades against, with `factory.poolByPair(zipUSD, xAlpha)` resolving it so `deployer == address(0)` holds.
  **Iteration plan:** iteration 1 wires `buyXAlpha` to a good-enough stand-in pool to demo functionality, then
  repoints to the exact POL. Because `_swap` hard-pins `deployer: address(0)` for both legs, the stand-in **must itself
  be a base-factory (deployer-0) Algebra pool** or `buyXAlpha` reverts even in the demo. The planned repoint is a pure
  re-wire **IF the real POL is also base-factory**, but a **code change to 8-B9 (add a `deployer` param/wiring) IF the
  POL is a custom-deployer pool** — so decide the POL deployment shape BEFORE the repoint, not after.
- **Per-epoch throughput is OFF-chain (8-B12 tripwire).** `maxSellHydx` caps any SINGLE `sellHydx` on-chain, but the
  per-**epoch** cumulative throughput across many `sellHydx`/`buyXAlpha` calls is NOT on-chain (stateless by design,
  §17). 8-B12 MUST tripwire/alert if cumulative volume exceeds the §9.3 soft-bleed cap — the operational backstop for a
  multi-call mis-sized or compromised-operator dump.

## Gotchas
- **Algebra Integral, NOT Uniswap V3 — the struct shape is the trap.** `ExactInputSingleParams` has a **`deployer`
  field** and **`limitSqrtPrice`** (not `sqrtPriceLimitX96`) and carries **NO `fee` field**. Selector for
  `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))` is **`0x1679c792`**
  (on-chain-verified; `algebraSwapCallback(int256,int256,bytes)` `0x2c8958f6` also present). The two non-Algebra
  candidates are ABSENT (`0xbc651188` Algebra-classic-no-deployer, `0x04e45aaf` UniV3-with-fee). The typed
  `abi.encodeCall` pins the field order at compile time.
- **`deployer == address(0)` is hard-coded for ALL legs** (sellHydx, buyXAlpha, sellXAlpha). Verified base-factory for
  HYDX/USDC; it must be re-verified for the not-yet-created POL pair (see item-10 row 353) — and it now covers BOTH POL
  directions. A custom-deployer POL pool would require a code change, not a re-wire.
- **`sellXAlpha` is intentionally uncapped.** Only `sellHydx` carries `maxSellHydx`, because the oHYDX system has a
  profitability ceiling; xALPHA (our own POL asset) has none, so no size cap. Throughput for `sellXAlpha` is the same
  8-B12 off-chain tripwire concern as the other legs.
- **On-chain bounds = `minOut` (price) + `maxSellHydx` (per-call size); throughput = off-chain.** `minOut` bounds the
  price (slippage abort), `maxSellHydx` bounds the per-call HYDX size; multi-call per-epoch throughput is the 8-B12
  off-chain tripwire, NOT a module accumulator. The compromised-operator economic risk is **accepted** under §17's
  CRE-permissioned-single-writer model (the operator is the trust anchor; loss would be a key-compromise, bounded by
  the 8-B12 tripwire and `maxSellHydx`, not by on-chain logic).
- **`minOut == 0` and `amountIn == 0` both revert `ZeroAmount`.** A zero slippage floor = no protection → fail fast
  (parity with 8-B8's `maxPayment > 0`). `deadline` is passed through un-validated (the router enforces it; the
  operator sets `block.timestamp + buffer`).
- **No standing approval ever survives.** The 3rd `_exec` resets `tokenIn.approve(router, 0)`; and on a mid-swap
  failure the atomic tx revert rolls back exec #1's approve too (`allowance(safe, router) == 0` holds after both a
  happy path and a reverted path).
- **`setJuniorTrancheEngine` moves three slots.** Re-pointing `juniorTrancheEngine` also re-points `avatar` and `target` in lock-step;
  the three must never diverge (the module only ever mutates its avatar, which must equal the engine Safe).
- **`require(cond, CustomError())` is 0.8.26+; this is the 0.8.24 pin** — guards use `if (!cond) revert CustomError()`.
