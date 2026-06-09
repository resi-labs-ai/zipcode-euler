# 8-B9 — Sell module (market-sell HYDX→USDC + the zipUSD→xALPHA POL buy leg, via Algebra `SwapRouter`)

> **NEXT / build-only.** The sixth harvest-loop engine module (after 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6
> LP-strategy, 8-B7 harvest-vote, 8-B8 exercise). It owns the **swap leg** of the auto-sodomizer: per harvest it
> **market-sells** the exercised HYDX (from 8-B8) → USDC immediately so the CRE can repay the 8-B5 strike-borrow
> (`debtOf(safe)→0`), and it also runs the **zipUSD→xALPHA on our POL** swap that the 8-B10/8-B13 recycle/compound
> Modes B/C consume. Internal engine plumbing → **build-only** (no INFLOW ticket; the frontend never wires to it; the
> 8-B11 CRE strategy robot drives the entrypoints). It is a **close sibling of `ExerciseModule` (8-B8)** — same
> `is Module` + `setUp(bytes)`-under-`initializer` + `onlyOperator` + `exec(...,Operation.Call)` + the
> `_exec`-that-bubbles + the **approve → call → reset-approval** dance — but it calls the **Algebra `SwapRouter`**
> instead of oHYDX, with **NO EVC leg, NO oracle, NO repay** (the repay that consumes the proceeds is 8-B5's
> `ReservoirLoopModule.repay`, sequenced by the CRE robot after this sell).

**Deliverable**
Two files under the supply/engine tree, plus one new minimal interface and one new address constant:
- `contracts/src/supply/szipUSD/SellModule.sol` — `contract SellModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine
  Safe** (`avatar == target == engineSafe`). **Two operator-only mutators**, each mutating the Safe **only** via the
  inherited `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles, and each routing
  through a shared private `_swap(tokenIn, tokenOut, amountIn, minOut, deadline) returns (uint256 amountOut)` helper
  (the **approve → exactInputSingle → reset-approve** dance):
  - **`sellHydx(uint256 amountIn, uint256 minOut, uint256 deadline) returns (uint256 amountOut)`** — the strike-loop
    repay leg. `_swap(HYDX, USDC, amountIn, minOut, deadline)`: (1) `HYDX.approve(swapRouter, amountIn)` (from the
    Safe), (2) `swapRouter.exactInputSingle(ExactInputSingleParams{tokenIn: HYDX, tokenOut: USDC, deployer:
    address(0), recipient: engineSafe, deadline, amountIn, amountOutMinimum: minOut, limitSqrtPrice: 0})` — pulls
    `amountIn` HYDX from the Safe, sends **`amountOut` USDC to `engineSafe`** (`amountOut ≥ minOut` or it reverts),
    returns `amountOut`, (3) `HYDX.approve(swapRouter, 0)` (reset; no standing approval). Decode `amountOut` from the
    exec return; `emit Sold(HYDX, USDC, amountIn, amountOut)`.
  - **`buyXAlpha(uint256 amountIn, uint256 minOut, uint256 deadline) returns (uint256 amountOut)`** — the Mode-B/C POL
    buy leg (consumed by 8-B10/8-B13). `_swap(zipUSD, xAlpha, amountIn, minOut, deadline)` — identical mechanism with
    the wired `zipUSD`/`xAlpha` pair; `emit Sold(zipUSD, xAlpha, amountIn, amountOut)`.
  The operator supplies **only scalars** (`amountIn`, `minOut`, `deadline`); the module builds all calldata to the
  **set-once wired targets** (`swapRouter`, the token pair), `deployer` is hard-pinned to `address(0)` (the HYDX/USDC
  and POL pools are **base-factory pools**, verified below), `recipient` is hard-pinned to `engineSafe`, and the
  `tokenIn`/`tokenOut` are hard-pinned per entrypoint. **No generic call passthrough, no arbitrary token pair, no
  delegatecall, `value == 0` on every `exec`** — the module's whole security boundary (§10.1). **No EVC, no oracle,
  no LP, no veNFT, no repay — none of those are this module's job** (8-B5/8-B6/8-B7/SzipNavOracle).
- `contracts/test/SellModule.t.sol` — unit (recording-mock Safe — exec-shape / approve-reset dance / authority /
  atomicity / guards / `amountOut` decode, for **both** entrypoints) + fork (live Base: a **real
  `SwapRouter.exactInputSingle`** HYDX→USDC against a real summoned substrate Safe seeded with HYDX, proving the HYDX
  pull / USDC-to-Safe / `amountOut` return / `minOut` enforcement, plus a **signature-verification** of the router
  surface and a **`minOut`-too-high revert** bubble). The **`buyXAlpha` leg is unit-only** (mock router) — there is
  **no live zipUSD/xALPHA POL pool on Base yet** (zipUSD is our just-deployed `ESynth`, xALPHA is the 8x bridge
  stand-in); the live-pool fork proof for `buyXAlpha` is **deferred to 8-B10/8-B13 integration** (logged as an
  obligation). The router selector/shape are shared with `sellHydx`, so the buy leg's calldata shape IS fork-grounded
  by the sell-leg sig-verify.
- **Interface addition (on-chain-verified Base 8453 this window — selector confirmed against the deployed Algebra
  `SwapRouter` bytecode `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`):**
  - **NEW** `contracts/src/interfaces/algebra/ISwapRouter.sol`: the minimal Algebra Integral router surface —
    ```solidity
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address deployer;          // Algebra Integral custom-pool deployer; address(0) for base-factory pools
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    ```
    `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))` = selector **`0x1679c792`**
    (FOUND as a PUSH4 in the deployed router bytecode; `algebraSwapCallback(int256,int256,bytes)` `0x2c8958f6` also
    FOUND, confirming it is **Algebra Integral, not Uniswap V3** — note **no `fee` field**, a `deployer` field, and
    `limitSqrtPrice` not `sqrtPriceLimitX96`, exactly as `INonfungiblePositionManager.MintParams` already documents
    the Algebra deltas). Add the on-chain-verified selector + the source address in a `[EXT]` doc comment (house
    posture). **Do NOT** add `exactInput`/`exactOutputSingle`/`unwrapWNativeToken`/`refundNativeToken` (unused — keep
    the surface minimal).
  - **EXTEND** `contracts/src/interfaces/algebra/IAlgebraPool.sol`: ADD `function token0() external view returns
    (address);` and `function token1() external view returns (address);` (the standard pair getters — the existing
    interface has only `swap`/`globalState`, but the fork sanity-quote + the token-order sig-verify call them).
    Verified on-chain this window: pool `0x51f0…` `token0() == HYDX`, `token1() == USDC`.
- **Address addition (`contracts/script/BaseAddresses.sol`):** `ALGEBRA_SWAP_ROUTER =
  0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e` (on-chain-verified this window: `router.factory()` ==
  `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E` == the HYDX/USDC pool's `factory()` == the factory whose
  `poolByPair(HYDX, USDC)` returns the live pool `0x51f0…` — proving the pool is a **base-factory pool** ⇒ the
  `deployer` arg is `address(0)`). `HYDX`/`USDC`/`HYDX_USDC_POOL` already present. **No `zipUSD`/`xAlpha` constants** —
  those are runtime addresses (our `ESynth` + the bridge stand-in), wired at deploy (item 10) and mocked in unit tests.

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec, the **8-B9** block: **market-sell, NOT patient range
  orders** (two forces require immediate execution — an open strike-borrow accruing interest, and a net-draining pool
  with no buy-side, so resting orders rarely fill → take the bid that exists); external call Algebra `SwapRouter`
  `exactInputSingle(...)` HYDX→USDC; CRE op seq = market-sell the exercised HYDX (sized within the per-epoch cap) →
  from the proceeds the CRE calls **8-B5** `Borrowing.repay` until `debtOf(safe)==0` → 8-B6 re-stakes → the residual
  USDC → 8-B10. **The per-epoch soft-bleed cap is a SIZE GATE on the loop, not a "sell slowly" rule, and it is
  8-B11/8-B12 CRE/monitoring policy — NOT a contract constant or on-chain accumulator** (the §4.5.1 8-B9 "State"
  line is reconciled to this in the spec-fix below; the module is pure swap mechanism, the loop size is bounded
  upstream by 8-B8's exercise size so the repay sell always fits the cap — exactly as 8-B8's strike/cutoff/regime are
  CRE-layer). The on-chain safety bound is the operator-supplied **`minOut`** slippage floor (the analog of 8-B8's
  `maxPayment`).
- `baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one CRE operator = `onlyOperator`, mutate
  the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via `ModuleProxyFactory`, init in
  `setUp` under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B9** (the swap description: market-sells
  HYDX→USDC for the 8-B5 repay leg **and** zipUSD→xALPHA on our POL for the Mode B/C buy leg, via the Hydrex
  `SwapRouter`, sized within the soft-bleed caps; addresses `SwapRouter 0x6f4b…`, HYDX/USDC pool `0x51f0…`).
- `pending-docs/auto-sodomizer.md` **§4 step (d) / §5 / §9** (the market-sell step; `SwapRouter.exactInputSingle`
  HYDX→USDC, immediate, sized within the §9.3 soft-bleed cap; loop sizing = size the loop so the repay sell fits the
  cap, NOT sell-slowly) **/ §6 / §11** (the zipUSD→xALPHA buy leg for Mode B/C).
- `pending-docs/hydrex.md` **§9.3** (the soft-bleed caps: per-order slippage ≤2–3%, per-epoch volume ≤1–2% of pool
  USDC, taper $0.033 → amber ~$0.018 → halt $0.015 — all governed CRE/monitoring policy) **/ §2.3** (the
  net-draining-with-no-buy-side pool → why market-sell) **/ §5** (the HYDX/USDC pool is the binding constraint, ~$429k,
  not ours to grow).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation; collateral mocked. (8-B9 reopens nothing.)

**Model from (VERIFIED against `reference/`, the kept builds, and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol`. **Proven by the kept `ExerciseModule` (8-B8),
  `ReservoirLoopModule` (8-B5), `LpStrategyModule` (8-B6), `HarvestVoteModule` (8-B7), `SzipBuyBurnModule` (8-B14), all
  build + fork-test green under 0.8.24:** `abstract contract Module is FactoryFriendly, Ownable`; `setUp(bytes) public
  virtual`; `initializer` is zodiac-core's own (`factory/Initializable.sol`, one-shot); `exec(to,value,data,Operation)
  internal` (`core/Module.sol:43`) and `execAndReturnData(...) internal returns (bool,bytes)` (`:59`) → forward to
  `IAvatar(target).execTransactionFromModule(...)` / `...ReturnData(...)`; `Operation { Call, DelegateCall }`
  (`core/Operation.sol:4`); `Ownable` is zodiac-core's own (`factory/Ownable.sol`; `_transferOwnership` internal, use
  in `setUp`; `setAvatar`/`setTarget` `public onlyOwner`). Remap
  `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/`; zodiac-core imports **zero OpenZeppelin** → no
  OZ-4/5 collision.
- **PRIMARY MODEL = `contracts/src/supply/szipUSD/ExerciseModule.sol` (8-B8, the closest sibling — the SAME
  approve→call→reset-approval token dance + the SAME `_exec`-that-bubbles-and-returns-bytes + the SAME decode of the
  call's return + the SAME 4-address `setUp` order-guard).** Copy verbatim: the module header (`Module`, `Operation`,
  `IERC20` imports — `ExerciseModule.sol:4-7`), the `setUp` validate-FIRST-then-store pattern
  (`ExerciseModule.sol:67-95` — validate all decoded addresses nonzero + `owner != operator` BEFORE any staticcall,
  set `avatar=target=engineSafe`, store wiring, `_transferOwnership` LAST), the `onlyOperator` modifier
  (`:98-101`), the `setAvatar`/`setTarget` "left as onlyOwner, not hard-locked" comment (`:103-106`), the private
  `_exec(to,data) returns (bytes)` that bubbles inner revert data via the assembly
  `revert(add(ret,0x20),mload(ret))` / `revert ExecFailed()` when empty (`:115-124`), the approve/reset selectors
  (`:144,146`: `abi.encodeWithSelector(IERC20.approve.selector, target, amount)` then `..., 0`), and the
  `abi.decode(ret, (uint256))` return decode (`:148`). **The ONLY structural differences:** (a) the middle `_exec`
  targets `swapRouter` with `abi.encodeCall(ISwapRouter.exactInputSingle, (params))` instead of `oHYDX.exercise`; (b)
  the approve target is the **input token** (`tokenIn`, which differs per entrypoint), so the dance is factored into a
  shared `_swap(tokenIn, tokenOut, amountIn, minOut, deadline)`; (c) there is **no live-read in `setUp`** (8-B8 read
  `paymentToken` off oHYDX; 8-B9's tokens are all wired directly) — so `setUp` decodes **7 addresses** with no
  staticcall; (d) no `quoteStrike`-style view (the CRE reads the pool's `globalState()` directly to size — see Do NOT).
- **`abi.encodeCall(ISwapRouter.exactInputSingle, (params))` — typed, NOT `encodeWithSelector`** (the 8-B8
  `abi.encodeCall(IOptionToken.exercise, ...)` pattern, `ExerciseModule.sol:145`), so a struct-field-order regression
  (a recipient/deployer/deadline slip) **fails to compile** rather than silently mis-encoding.
- **The Algebra `SwapRouter` surface — VERIFIED on live Base 8453 this window:**
  `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))` = **`0x1679c792`** (FOUND as
  a PUSH4 in the deployed bytecode of `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`); the two non-Algebra candidates
  are ABSENT (`0xbc651188` Algebra-classic-no-deployer, `0x04e45aaf` UniV3-with-fee). `algebraSwapCallback(int256,
  int256,bytes)` `0x2c8958f6` is PRESENT → Algebra Integral. The struct field **order** (`tokenIn, tokenOut,
  deployer, recipient, deadline, amountIn, amountOutMinimum, limitSqrtPrice`) is the canonical Algebra Integral
  periphery ordering — and the **fork test is the real proof**: a swap with a wrong field order would send USDC to the
  wrong recipient / revert, so the green real-swap fork test pins the order (do not trust the prose alone; the
  4-arg-decode recipient assertion + the balance deltas prove it).
- **`deployer == address(0)` — VERIFIED.** `router.factory()` == `pool.factory()` ==
  `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E`; `factory.poolByPair(HYDX, USDC)` == the live pool `0x51f0…` (the base
  factory knows the pool) ⇒ it is a base-factory pool, so the router's custom-pool `deployer` arg is `address(0)` (the
  HYDX/USDC pair has exactly one base pool; the same holds for our POL pair when it is created — base factory). Pass
  `deployer: address(0)` hard-coded.
- **Token ordering / direction.** Pool `0x51f0…` `token0() == HYDX`, `token1() == USDC` (verified). `exactInputSingle`
  does NOT take a direction or pool address — the router derives the pool + direction from `(tokenIn, tokenOut,
  deployer)`. So `sellHydx` passes `tokenIn = HYDX, tokenOut = USDC`; no `zeroToOne` to compute.
- **CRITICAL clone fact (§18.6, proven on 8-B5/8-B6/8-B7/8-B8/8-B14).** A `ModuleProxyFactory` clone shares the
  mastercopy's runtime bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp`
  config. **Every per-clone wired address (`engineSafe`, `operator`, `swapRouter`, `hydx`, `usdc`, `zipUSD`, `xAlpha`)
  MUST be plain set-once storage written in `setUp` under `initializer`, NOT `immutable`.** Init-lock the mastercopy
  at deploy (test asserts a second `setUp` reverts).
- **Error declarations:** `error NotOperator(); error ZeroAddress(); error OwnerIsOperator(); error ZeroAmount();
  error ExceedsMaxSell(); error ExecFailed();` (model the block on `ExerciseModule.sol:48-58`; **drop**
  `PaymentExceedsMax` — there is no payment ceiling here; the slippage protection is the router-enforced
  `amountOutMinimum`, which bubbles its own revert through `_exec`; **add** `ExceedsMaxSell` for the per-call HYDX size
  cap). `ZeroAmount` covers `amountIn == 0`, `minOut == 0`, and a zero `maxSellHydx` (setUp + setter).
- **Addresses (`contracts/script/BaseAddresses.sol`):** `HYDX 0x00000e7efa313F4E11Bfff432471eD9423AC6B30` (present),
  `USDC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (present), `HYDX_USDC_POOL 0x51f0…` (present, used in the fork test
  to read `globalState()` for the sanity-quote + to confirm liquidity), **`ALGEBRA_SWAP_ROUTER 0x6f4b…` (NEW, add
  it)**. **HYDX source for the fork seed:** `deal(HYDX, engineSafe, amountIn)` (HYDX is a standard ERC20, verified in
  8-B7/8-B8). **No USDC seed needed for `sellHydx`** (the swap MINTS USDC to the Safe). If `deal` on HYDX misbehaves
  (some tokens block `deal`), **fallback** impersonate a concrete HYDX holder via `vm.prank` + `transfer` (the 8-B8
  whale-fallback pattern).

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…05, `SzipNavOracle`, `ExitGate`+`SzipUSD`, `ZipDepositModule`,
8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule`+`SzipReservoirLpOracle`+`ReservoirBorrowGuard`+
`ReservoirMarketDeployer`, 8-B6 `LpStrategyModule`, 8-B7 `HarvestVoteModule`, 8-B8 `ExerciseModule`). zodiac-core
`Module` proven by the five built engine modules; `IAlgebraPool.sol` exists (`globalState()`/`token0`/`token1`
on-chain-verified). `contracts/src/supply/szipUSD/` exists. `IERC20` import path is
`@openzeppelin/contracts/token/ERC20/IERC20.sol` (the 8-B8 `ExerciseModule.sol:6` import). **No engine Safe is
summoned in unit tests** — use a **recording mock Safe** (the `RecordingSafe` in
`contracts/test/ExerciseModule.t.sol` / `HarvestVoteModule.t.sol`: implements `execTransactionFromModule` +
`execTransactionFromModuleReturnData`, records each `(to, value, data, operation)`, `setLive`/`getCall`/`callCount`,
`setFailOnCallIndex` for atomicity, `setReturnData(bytes)` for the return decode — `_record` returns `(true,
_returnData)` on every non-live call) for validation/authority/exec-shape, and a **real Base fork** with the **real
summoned substrate Safe** (`SummonSubstrate._summon`, model `ExerciseModule.t.sol _summonAndEnable`) as the engine
Safe for the live `sellHydx`.

**Test-harness extensions to author (build them in the test file):**
- **`RecordingSafe` return-data (the `amountOut` decode).** Reuse the 8-B8 `RecordingSafe` **verbatim** — its
  non-live `_record` returns `(true, _returnData)` for **EVERY** call. So `setReturnData(abi.encode(uint256
  expectedOut))`, then `sellHydx(a, m, d)` — the module decodes the **2nd** exec's return as `amountOut` and ignores
  the 1st/3rd `approve` returns (the same blob comes back on all three; harmless — the module never reads the approve
  returns). Assert `emit Sold(HYDX, USDC, a, expectedOut)` + the function return. ALSO a **short/empty return-data**
  case (`setReturnData` < 32 bytes) → `sellHydx` **reverts** (the decode must not emit garbage).
- **Target mock `MockSwapRouter`** (the `_exec` target; the model files have no analog): an `exactInputSingle(params)`
  that **records** the full `ExactInputSingleParams` struct it received (to assert `tokenIn`/`tokenOut`/`deployer ==
  0`/`recipient == engineSafe`/`deadline`/`amountIn`/`amountOutMinimum == minOut`/`limitSqrtPrice == 0`) and returns
  a settable `amountOut` — the recipient-pin + deployer-pin + slippage-passthrough firewall proven by **struct
  decode**, not a keccak match. A `MockERC20` (or reuse the standard test mock) is the wired `tokenIn` for the
  approve-shape + state-moving allowance-reset assertions.
- **A `live`-Safe atomicity case:** a target returning `(false, customErrorBytes)` through a `live` Safe so the
  `_exec` assembly-bubble is exercised (the router slippage-revert analog), plus a `(false, "")` case asserting
  `ExecFailed`.

**Do NOT**
- **Do NOT** store or reset a **per-epoch volume accumulator** in the contract (no running sum, no epoch
  boundary/reset). The per-**epoch** *throughput* limit across many calls stays at the **8-B11/8-B12 CRE/monitoring
  layer** (§4.5.1; that stateful time-policy is what §17 puts at CRE; an on-chain epoch accumulator was considered and
  REJECTED for sibling-consistency). **DO, however, enforce a governed per-CALL `maxSellHydx` SIZE ceiling** (set-once
  config + an `onlyOwner` setter — NOT an accumulator, so the module stays stateless beyond wiring): `sellHydx`
  reverts `ExceedsMaxSell` if `amountIn > maxSellHydx`. This is the defense-in-depth backstop (user-directed
  2026-06-08) against a compromised operator dumping the whole HYDX basket in one tx — `minOut` bounds only PRICE,
  never SIZE. Default 300k HYDX (≈ ~3% slippage ≈ ~$10k = the intended weekly clip), wired at deploy,
  owner(Timelock)-settable to track pool depth. *(This refines the §4.5.1 8-B9 "State" line — fixed this window to "no
  module state; on-chain bounds = `minOut` price floor + `maxSellHydx` size ceiling".)* The buy leg `buyXAlpha` is
  **not** size-capped here (different token; bounded upstream by 8-B10's `freeValueAccrued` gate).
- **Do NOT** compute the strike, the regime (UP/FLAT/DOWN), the profitability cutoff ($0.015), the loop size, or read
  the pool to size the order **inside the contract** — those are **8-B11 CRE policy** (§4.5.1; `hydrex.md §9.2/§9.3`).
  The CRE reads `pool.globalState()` directly and sizes `amountIn` + `minOut` off it; the module takes them as scalars.
  **Do NOT add a `quoteSpot`/`poolSpot` view** (it would require wiring the pool address for no on-chain consumer — the
  CRE reads the pool directly).
- **Do NOT** call `exactInputSingle` with `recipient != engineSafe`. The output token must land in the Safe (the
  basket), never the operator or a third party (assert the recorded `recipient == engineSafe` via struct decode).
- **Do NOT** add an EVC leg, a `borrow`/`repay`, a `borrowCap`, an LP/escrow leg, a veNFT, an oHYDX `exercise`, or a
  free-value accumulator — those are 8-B5/8-B6/8-B7/8-B8/8-B10. 8-B9 is the **single swap mechanism** only. The repay
  that consumes the USDC proceeds is **8-B5's `ReservoirLoopModule.repay`**, called by the CRE robot **after** this
  sell (the USDC is in the Safe; the borrow accounting is 8-B5's). The free-value crediting is **8-B10's
  `creditFreeValue`**, also CRE-sequenced after.
- **Do NOT** leave a standing token approval — reset `tokenIn.approve(swapRouter, 0)` after each swap (hygiene, parity
  with 8-B8 `exercise` / 8-B5 `repay`). **`minOut` is the SLIPPAGE GUARD, not a malware defense.** The Algebra router
  is canonical Hydrex infra; `minOut` aborts the swap on adverse price movement (a sandwich / a TWAP move between the
  CRE's quote and tx execution) instead of dumping at a bad price. 8-B11 sets `minOut = expectedOut × (1 − the §9.3
  per-order slippage cap)` — too tight → normal drift reverts; too loose → a real economic bad-fill (NOT theft —
  the proceeds still go to the Safe). The cushion must be modest (logged as an 8-B11 obligation).
- **Do NOT** use `immutable` for any wired address (clone fact); **do NOT** add a generic `swap`/`exec`/`call`
  passthrough, an arbitrary `(tokenIn, tokenOut)` argument, delegatecall, or non-zero `value`; **do NOT** hard-lock
  `setAvatar`/`setTarget` (keep them zodiac-core `onlyOwner`, matching the siblings — marking the vendored setters
  `virtual` would dirty the pristine reference dep).
- **Do NOT** add `exactInput`(path)/`exactOutputSingle`/`unwrapWNativeToken`/`refundNativeToken`/`algebraSwapCallback`
  or any other router method the module does not call to the interface (keep the surface minimal; only
  `exactInputSingle` + its `ExactInputSingleParams` struct are added).

**Key requirements**
1. **`is Module` on the engine Safe, clone-safe.** Inherit zodiac-core `Module`; `setUp(bytes)` under `initializer`
   decodes **8 addresses + 1 uint256** `(address owner, address engineSafe, address operator, address swapRouter,
   address hydx, address usdc, address zipUSD, address xAlpha, uint256 maxSellHydx)`. Validate **ALL eight addresses
   nonzero FIRST** + `maxSellHydx > 0` (`ZeroAmount` — a zero cap would brick `sellHydx`) +
   `owner != operator` (the order-guard: a zero address reverts `ZeroAddress` deterministically before any use), set
   `avatar = target = engineSafe`, store the wiring, THEN `_transferOwnership(owner)`. **No live-read / staticcall in
   `setUp`** (unlike 8-B8 — all tokens are wired directly). All wired addresses are **set-once storage, never
   `immutable`**. The mastercopy is init-locked at deploy (test asserts a second `setUp` reverts).
2. **`onlyOperator` on both mutators; recipient + tokens hard-pinned.** `sellHydx`/`buyXAlpha` revert `NotOperator`
   for any non-operator caller. Each passes its **wired** `tokenIn`/`tokenOut`, `deployer = address(0)`, `recipient =
   engineSafe`. Tests: a non-operator caller reverts (both entrypoints); a non-owner `setAvatar`/`setTarget` reverts;
   `owner == operator` in `setUp` reverts `OwnerIsOperator`.
3. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** Every mutation routes through the private
   `_exec(to, data) returns (bytes)` using `execAndReturnData(to, 0, data, Operation.Call)`; on `!ok` it bubbles the
   inner revert data (or `ExecFailed` when empty). The shared `_swap(tokenIn, tokenOut, amountIn, minOut, deadline)`
   does exactly three `_exec`s, in order:
   (1) `_exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, swapRouter, amountIn))`,
   (2) `_exec(swapRouter, abi.encodeCall(ISwapRouter.exactInputSingle, (ExactInputSingleParams({tokenIn: tokenIn,
       tokenOut: tokenOut, deployer: address(0), recipient: engineSafe, deadline: deadline, amountIn: amountIn,
       amountOutMinimum: minOut, limitSqrtPrice: 0}))))` — **typed `encodeCall`, NOT `encodeWithSelector`**, so a
       struct-field-order regression fails to compile,
   (3) `_exec(tokenIn, abi.encodeWithSelector(IERC20.approve.selector, swapRouter, uint256(0)))`.
   **Import `{IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"`** for the `approve` selector. **Only the
   2nd `_exec` return is decoded** (`amountOut = abi.decode(ret,(uint256))`); the two `approve` returns are ignored.
   Tests assert the entrypoint produces exactly `(tokenIn, 0, approve(swapRouter, amountIn), Call)`, `(swapRouter, 0,
   exactInputSingle(params), Call)`, `(tokenIn, 0, approve(swapRouter, 0), Call)` on the recording Safe — and **decode
   the recorded `ExactInputSingleParams` struct from `getCall(1)` and assert `(tokenIn, tokenOut, deployer == 0,
   recipient == engineSafe, deadline, amountIn, amountOutMinimum == minOut, limitSqrtPrice == 0)`** (the
   recipient/deployer-pin + slippage/deadline pass-through firewall — struct-decode, not a keccak match); **decode the
   `approve(swapRouter, 0)` reset call args** too (assert spender == swapRouter, amount == 0). Atomicity: a `live` Safe
   returning `(false, customErrorBytes)` (the router slippage revert) makes the entrypoint **revert bubbling that
   data**; `(false, "")` reverts `ExecFailed`.
4. **Guards.** `amountIn == 0` reverts `ZeroAmount`; `minOut == 0` reverts `ZeroAmount` (a zero slippage floor =
   no protection — fail fast, parity with 8-B8 `maxPayment == 0`; the meaningful floor is an 8-B11 obligation).
   `deadline` is passed through un-validated (the router enforces it; the operator sets `block.timestamp + buffer`).
5. **Both mutators decode + emit `amountOut`.** The 2nd `_exec` returns the encoded `amountOut`; decode
   `abi.decode(ret,(uint256))`, `emit Sold(tokenIn, tokenOut, amountIn, amountOut)`, `return amountOut`. A malformed
   (`< 32`-byte) return reverts (the decode must not emit garbage). **No `amountOut <= X` honesty guard** — the router
   enforces `amountOut >= minOut` internally (reverts otherwise), so the decoded value is already floor-bounded; there
   is no ceiling to assert (more output is strictly good).
6. **Both entrypoints share `_swap`; `buyXAlpha` is the same mechanism on the `(zipUSD, xAlpha)` pair.** `sellHydx`
   calls `_swap(hydx, usdc, ...)`; `buyXAlpha` calls `_swap(zipUSD, xAlpha, ...)`. Public set-once getters:
   `engineSafe`/`operator`/`swapRouter`/`hydx`/`usdc`/`zipUSD`/`xAlpha`.
7. **Interface addition is minimal + verified** (Deliverable list): `ISwapRouter.exactInputSingle` +
   `ExactInputSingleParams`, carrying the on-chain-verified selector `0x1679c792` + the source address in a `[EXT]`
   comment (the house posture). The new `ALGEBRA_SWAP_ROUTER` constant in `BaseAddresses.sol`.
8. **Per-call HYDX size cap + governed setter (defense-in-depth, user-directed 2026-06-08).** Storage `uint256 public
   maxSellHydx` (set-once in `setUp`, validated `> 0`); `sellHydx` reverts `ExceedsMaxSell` when `amountIn >
   maxSellHydx` (guard `>`, so `amountIn == maxSellHydx` is allowed). `setMaxSellHydx(uint256 newMax) external
   onlyOwner` (the Timelock, NOT the hot operator) updates it, reverts `ZeroAmount` on zero; both `setUp` and the
   setter `emit MaxSellHydxSet(newMax)`. The cap is on **`sellHydx` only** — `buyXAlpha` is uncapped here. Public
   getter `maxSellHydx()`.

**Done when**
- `forge build` green; `forge test --match-path test/SellModule.t.sol` green (unit) and
  `forge test --fork-url $BASE_RPC_URL --match-path test/SellModule.t.sol` green (unit + fork); **no regression** on the
  full suite (`forge test --fork-url $BASE_RPC_URL`, currently 351/351 after 8-B8).
- **Unit (RecordingSafe + MockSwapRouter + a real MockERC20 as `tokenIn`):** (a) **exec-shape, fully pinned** — for
  **both** `sellHydx(a, m, d)` and `buyXAlpha(a, m, d)`: exactly three recorded calls `(tokenIn, 0, approve(router,
  a), Call)`, `(router, 0, exactInputSingle(params), Call)`, `(tokenIn, 0, approve(router, 0), Call)`. **For EACH
  recorded call assert `value == 0` AND `operation == uint8(Operation.Call)`.** **Decode the full
  `ExactInputSingleParams` from `getCall(1)`** and assert every field (`tokenIn`/`tokenOut` are the wired pair,
  `deployer == 0`, `recipient == engineSafe`, `deadline == d`, `amountIn == a`, `amountOutMinimum == m`,
  `limitSqrtPrice == 0`); **decode the `approve(router, 0)` reset** (spender == router, amount == 0). The mock returns
  a set `amountOut` → assert `emit Sold(tokenIn, tokenOut, a, amountOut)` (via `vm.expectEmit`) and the function
  return equals it. (b) **malformed return** — the mock's `exactInputSingle` return set to `< 32` bytes → the
  entrypoint **reverts**. (c) authority — both entrypoints revert `NotOperator` for a non-operator (operator + rando);
  `setAvatar`/`setTarget` revert for a non-owner; `owner == operator` setUp reverts `OwnerIsOperator`; the **un-setUp
  mastercopy** is inert (`sellHydx` reverts `NotOperator`, every getter returns 0). (d) guards — `sellHydx(0, m, d)` →
  `ZeroAmount`; `sellHydx(a, 0, d)` → `ZeroAmount` (and the same for `buyXAlpha`). (e) atomicity — the production
  **bubble** path: a `live` target returning `(false, customErrorBytes)` makes the entrypoint revert bubbling that
  data; `(false, "")` reverts `ExecFailed`. **(e2) state-moving rollback** — wire a **live** RecordingSafe + a real
  `MockERC20` (`tokenIn`) + a `MockSwapRouter` whose `exactInputSingle` REVERTS; call `sellHydx`; `vm.expectRevert`;
  **then assert `MockERC20.allowance(safe, router) == 0`** (exec #1's approve is rolled back with the atomic tx — no
  dangling approval survives a mid-loop failure). **(e3) state-moving happy path** — a `live` RecordingSafe +
  `MockERC20` (Safe pre-funded) + a `MockSwapRouter` that pulls `amountIn` `tokenIn` and returns `amountOut`: after
  `sellHydx`, assert `MockERC20.allowance(safe, router) == 0` (the reset cleared the residual on a state-moving path,
  not just the calldata shape). (f) clone/init — a second `setUp` on the SAME instance reverts (the zodiac-core
  `initializer` lock); a zero in **each** of the 8 addresses reverts `ZeroAddress` — **for at least one case assert
  the revert selector is `SellModule.ZeroAddress` specifically** (the order-guard fires); a zero `maxSellHydx` reverts
  `ZeroAmount`. (g) **the per-call cap** — `sellHydx(maxSellHydx + 1, …)` reverts `ExceedsMaxSell`;
  `sellHydx(maxSellHydx, …)` (the exact boundary) does NOT revert at the guard; `buyXAlpha(maxSellHydx + 1, …)` does
  NOT revert `ExceedsMaxSell` (the cap is HYDX-only); `setMaxSellHydx(newMax)` by `owner` emits `MaxSellHydxSet` + a
  subsequently-larger `sellHydx` passes; a non-owner (operator + rando) `setMaxSellHydx` reverts
  `OwnableUnauthorizedAccount`; `setMaxSellHydx(0)` reverts `ZeroAmount`. The deploy default is **300_000e18**.
- **Fork (live Base, real summoned Safe — `sellHydx` only):** (a) **sig-verify** — staticcall the router/pool resolve:
  `pool.globalState()` decodes on `0x51f0…`, `pool.token0() == HYDX`, `pool.token1() == USDC`, and **assert the
  MODULE stored the live router: `module.swapRouter() == ALGEBRA_SWAP_ROUTER`**. (b) **real `exactInputSingle` proves
  the model** — `deal`/whale HYDX to the Safe, enable the module, read a sanity quote off `pool.globalState()` to set
  a conservative `minOut` (e.g. accept ≥ ~95% of the spot-implied USDC for the chosen `amountIn`), operator
  `sellHydx(amountIn, minOut, block.timestamp + 1h)`: assert `HYDX.balanceOf(Safe)` decreased by **exactly
  `amountIn`** (the pull), `USDC.balanceOf(Safe)` **increased by exactly the returned `amountOut`** (`≥ minOut`),
  `HYDX.allowance(Safe, router) == 0` (the reset — no standing approval), and `Sold(HYDX, USDC, amountIn, amountOut)`
  emitted with a nonzero `amountOut`. **Size `amountIn` small** (well within pool liquidity, e.g. a few hundred USDC
  of HYDX) so the real-pool slippage is small and `minOut` is satisfiable. (c) **`minOut`-too-high reverts** — call
  `sellHydx(amountIn, type(uint256).max, block.timestamp + 1h)` (an impossible slippage floor) and assert it
  **reverts** (the router slippage guard bubbles through `_exec`); **then assert the Safe state is unchanged:
  `HYDX.allowance(Safe, router) == 0` AND `HYDX.balanceOf(Safe)` unchanged AND `USDC.balanceOf(Safe)` unchanged** (the
  atomic revert rolled back exec #1's approve — no dangling approval, no partial swap). (d) **past deadline reverts**
  (cheap) — `sellHydx(amountIn, minOut, block.timestamp - 1)` reverts.
- **Critic-hardening folded (qa, this window — all strict test-completeness additions, no contract-semantics change):**
  (i) the struct-decode in (a) MUST explicitly assert `deployer == 0`, `limitSqrtPrice == 0`, and `deadline == d`
  (not just `recipient`/`amountOutMinimum`) — every one of the 8 fields pinned. (ii) `buyXAlpha` gets its OWN
  authority + guard tests (`NotOperator`, `ZeroAmount` on `amountIn==0`/`minOut==0`), not only the shared exec-shape
  assertion — both entrypoints fully covered. (iii) a `test_getters` asserting each of the 7 wired getters
  (`engineSafe`/`operator`/`swapRouter`/`hydx`/`usdc`/`zipUSD`/`xAlpha`) returns its wired address after `setUp`.
  (iv) enumerate the **8** zero-address `setUp` reverts (one per address) — for the `swapRouter==0` case assert the
  selector is `SellModule.ZeroAddress` specifically. (v) **Fork determinism:** do the `globalState()` quote and the
  `sellHydx` exec in the **same block with NO `vm.warp`/`vm.roll` between them** (avoid a stale-quote flake); size
  `amountIn` SMALL (well within pool depth) and set `minOut` with a generous integer-math cushion (e.g. `minOut =
  expectedOut * 80 / 100`) so the assertion is robust to normal fork price — the test proves the *mechanism*, not a
  tight price; mind the decimals (HYDX 18-dp in, USDC 6-dp out). `USDC.balanceOf(Safe)` delta `== amountOut` exactly
  holds (neither HYDX nor USDC is fee-on-transfer — verified standard ERC20s).
- Mapped to the integration layer: the per-epoch sell belongs in the **deferred engine-integration audit sweep**
  (`audit/2.md` Phase L + `audit/3-results.md` authority rows), authored once the engine is integration-testable
  alongside item-10 — logged as an obligation, NOT in this window (matches the 8-B5/8-B6/8-B7/8-B8/Exit-Gate sweeps).
- **`buyXAlpha` live-pool fork proof is DEFERRED** to 8-B10/8-B13 integration (no live zipUSD/xALPHA POL pool exists
  yet) — logged as an obligation; the buy leg is unit-proven this window + its router calldata shape is fork-grounded
  by the shared sell-leg sig-verify.

**Depends on**
- **8-B1** (the summoned engine Safe substrate — `SummonSubstrate._summon`, at
  `contracts/script/SummonSubstrate.s.sol`) and **8-B8** (the `ExerciseModule.sol` approve-dance + return-decode
  primary model + the test harness). **The cold-builder MUST open these test files to reuse the harness:**
  `contracts/test/ExerciseModule.t.sol` (the `RecordingSafe` with `setLive`/`setFailOnCallIndex`/`getCall`/
  `callCount`/`setReturnData` — `_record` returns `(true, _returnData)` on every non-live call — and the
  `_summonAndEnable` fork pattern) and the `MockOHYDX` target-mock shape (to model `MockSwapRouter`). The
  `IAlgebraPool` interface already exists (read `globalState()`/`token0`/`token1` in the fork sanity-quote); add the
  NEW `ISwapRouter` interface.
- **Feeds:** 8-B8 (consumes the exercised HYDX this module sells), 8-B5 (the borrow that this sell's proceeds repay
  via 8-B5's `repay`, CRE-sequenced after), 8-B10/8-B13 (the `buyXAlpha` Mode-B/C consumer + the `freeValueAccrued`
  crediting that follows the sell), 8-B11 (the CRE robot that sizes `amountIn`/`minOut` off `pool.globalState()`,
  enforces the soft-bleed caps, and sequences sell→repay→re-stake→credit), item 2 NAV (the post-sell USDC marked
  directly).

---

**Inbound cross-ticket obligations DISCHARGED by this ticket** (mark in `PROGRESS.md` at Conclude):
- **8-B9 · HYDX hand-off (8-B8 → 8-B9)** (owed by 8-B8): the HYDX `exercise` minted to the Safe is the input
  `sellHydx` market-sells (`SwapRouter.exactInputSingle`) to repay the 8-B5 borrow immediately (the pool is
  net-draining, no buy-side → market-sell, not resting). **DISCHARGED** — `sellHydx` consumes the Safe's HYDX balance
  (operator-sized `amountIn`), market-sells via `exactInputSingle` to USDC-in-the-Safe; the per-epoch cap that sizes
  `amountIn` is the 8-B11 CRE layer (per the §4.5.1 size-gate model).

**New cross-ticket obligations this ticket CREATES** (record in `PROGRESS.md` at Conclude):
- **Item 10 / engine-integration audit sweep (8-B9):** author the per-epoch sell into `audit/2.md` Phase L (an L-step
  exercise (8-B8) → `sellHydx` → repay (8-B5), with HYDX/USDC/debt balances moving; N-steps: non-operator /
  zero-amount / zero-minOut / `minOut`-too-high / past-deadline each revert) + the matching `audit/3-results.md`
  authority rows (operator-only entrypoints; `setAvatar`/`setTarget` owner-locked; recipient pinned to the engine
  Safe; no standing approval; no custody beyond the transient USDC/xALPHA). Author once the engine is
  integration-testable (with 8-B10…B13 + item-10), like the 8-B5/8-B6/8-B7/8-B8/Exit-Gate sweeps.
- **Item 10 / 8-B11 — operator + router + token wiring (8-B9):** the single CRE operator is the module's `operator`
  (sole caller); wire `swapRouter` to the live Algebra router `0x6f4b…`, `hydx`/`usdc` to the live tokens, and
  `zipUSD`/`xAlpha` to our `ESynth` + the bridge xALPHA at deploy. **Deploy the clone via the proven
  `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe) + init-lock the mastercopy**
  (the 8-B5/8-B8/8-B14 pattern; never two-tx deploy-then-init). The 8-B11 robot sizes `amountIn` + `minOut` off
  `pool.globalState()` (the §9.3 per-order slippage cap → a **modest** cushion: too loose = a fat bad-fill ceiling),
  enforces the per-epoch volume cap (the loop size gate), and sequences sell → 8-B5 `repay` → 8-B6 re-stake → 8-B10
  `creditFreeValue`. **Wire `maxSellHydx = 300_000e18` at deploy** (the per-call HYDX size backstop; owner=Timelock
  re-sizes via `setMaxSellHydx` to track ~3% slippage / the weekly clip as pool depth changes). These (regime / per-
  order minOut sizing / per-epoch throughput) are LOAD-BEARING but live OFF-chain (the module is correctly agnostic).
  **8-B12 monitoring obligation (security, this window):** the on-chain per-call `maxSellHydx` caps any SINGLE sell, but
  the per-**epoch** *throughput* across many calls is not on-chain — 8-B12 MUST tripwire/alert if cumulative
  `sellHydx`/`buyXAlpha` volume exceeds the §9.3 soft-bleed cap (the operational backstop for a multi-call mis-sized or
  compromised-operator dump; a single whole-basket dump is already bounded by `maxSellHydx`, accepted under the
  CRE-permissioned-single-writer model).
- **8-B10/8-B13 — `buyXAlpha` live-pool fork proof + POL pool identity:** when the zipUSD/xALPHA POL pool is created
  (8x bridge + the POL LP), wire `zipUSD`/`xAlpha` to the live pair and author the deferred `buyXAlpha` live-swap fork
  test; assert the POL pool is the SINGLE address the Mode-B/C buy leg trades against and `factory.poolByPair(zipUSD,
  xAlpha)` resolves it (so `deployer == address(0)` holds for the POL pair too — re-verify at that integration).
- **8-B10 — proceeds + free-value hand-off (8-B9 → 8-B10):** the USDC `sellHydx` lands in the Safe (net of the 8-B5
  repay the CRE runs next) is the input to 8-B10's `creditFreeValue(realizedUsdc)` (`freeValueAccrued += max(0,
  realized − borrowRepaid)`). 8-B9 does NOT credit free value (that is 8-B10's owned accumulator); the CRE sequences
  it after the sell + repay.
- **Post-M1 — exit-numeraire conversion (Exit Gate JC1, owed jointly by 8-B9/8-B13):** M1 windowed exits pay zipUSD
  only, skewing the free basket toward the volatile legs faster than the harvest replenishes zipUSD. Post-M1, 8-B9's
  swap path provides the general **volatile→zipUSD** numeraire conversion and 8-B13 rebalances the free basket toward
  exit liquidity. A liquidity-management obligation, not an M1 build requirement (the module's swap mechanism already
  supports it; the routing is CRE policy).
