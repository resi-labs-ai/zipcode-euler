# 8-B8 — Exercise module (paid `oHYDX.exercise` → HYDX, within the strike loop)

> **NEXT / build-only.** The fifth harvest-loop engine module (after 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6
> LP-strategy, 8-B7 harvest-vote). It owns the **paid exercise leg** of the auto-sodomizer: per harvest, for the
> **sell** slice, it pays the ~30% USDC strike (financed by the 8-B5 borrow) to `oHYDX.exercise(...)` and receives
> liquid **HYDX** to the Safe, which 8-B9 then market-sells to repay. Internal engine plumbing → **build-only** (no
> INFLOW ticket; the frontend never wires to it; the 8-B11 CRE strategy robot drives the entrypoint). It is a
> **close sibling of `ReservoirLoopModule` (8-B5)** — same `is Module` + `setUp(bytes)`-under-`initializer` +
> `onlyOperator` + `exec(...,Operation.Call)` + `_exec`-that-bubbles + the **approve → call → reset-approval**
> dance, but with **NO EVC leg** (it touches no EVC account; the borrow that funds the strike is 8-B5's job). It is
> the *paid* counterpart to 8-B7's **free** `exerciseVe` — a **different oHYDX function** with a USDC strike.

**Deliverable**
Two files under the supply/engine tree, plus two minimal interface additions:
- `contracts/src/supply/szipUSD/ExerciseModule.sol` — `contract ExerciseModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine
  Safe** (`avatar == target == engineSafe`). **One operator-only mutator**, mutating the Safe **only** via the
  inherited `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles:
  - **`exercise(uint256 amount, uint256 maxPayment, uint256 deadline) returns (uint256 paymentAmount)`** — exactly
    **3 `exec`s**: (1) `paymentToken.approve(oHYDX, maxPayment)` (the USDC strike allowance, from the Safe), (2)
    `oHYDX.exercise(amount, maxPayment, engineSafe, deadline)` (the **4-arg deadline overload**) — burns `amount`
    oHYDX held by the Safe, pulls **`paymentAmount` USDC** (`paymentAmount ≤ maxPayment`) from the Safe, mints liquid
    **HYDX to `engineSafe`**, returns `paymentAmount`; (3) `paymentToken.approve(oHYDX, 0)` (reset the residual
    allowance — no standing approval, security parity with 8-B5 `repay`). Decode `paymentAmount` from the exec return
    and `emit Exercised(amount, paymentAmount)`.
  The operator supplies **only scalars** (`amount`, `maxPayment`, `deadline`); the module builds all calldata to the
  **set-once wired targets** (`oHYDX`, `paymentToken`), the exercise `recipient` is hard-pinned to `engineSafe`. No
  generic call passthrough, no delegatecall, `value == 0` on every `exec` — the module's whole security boundary
  (§10.1). **No EVC, no oracle, no LP, no veNFT — none of those are this module's job** (8-B5/8-B6/8-B7/SzipNavOracle).
- `contracts/test/ExerciseModule.t.sol` — unit (recording-mock Safe — exec-shape / approve-reset dance / authority /
  atomicity / guards / `paymentAmount` decode) + fork (live Base: a **real `oHYDX.exercise`** against a real summoned
  substrate Safe seeded with oHYDX + USDC, proving the burn / USDC-pull / HYDX-mint / `paymentAmount` return, plus a
  **signature-verification** of the oHYDX surface and a **`maxPayment`-too-low revert** bubble).
- **Interface additions (on-chain-verified Base 8453 this window — selectors confirmed against the deployed
  oHYDX `OptionTokenV4` bytecode `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78`):**
  - `contracts/src/interfaces/hydrex/IOptionToken.sol`: ADD
    `function paymentToken() external view returns (address);` (`0x3013ce29`, returns USDC
    `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` — read LIVE in `setUp`) and
    `function getMinPaymentAmount() external view returns (uint256);` (`0x2abb945c`, NO args — the flat $0.01 floor,
    staticcall returned `10000`; used by the `quoteStrike` view). (`exercise(uint256,uint256,address,uint256)`
    `0xa1d50c3a`, `getDiscountedPrice(uint256)` `0x339ccade`, `discount()` `0x6b6f4a9d` already present + verified;
    `exerciseVe` already present.)

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec, the **8-B8** block: external call
  `oHYDX.exercise(uint256 _amount, uint256 _maxPaymentAmount, address _recipient, uint256 _deadline)` (the **deadline
  overload** — slippage+deadline protection; the 3-arg form also exists) paying `max(30%·TWAP, $0.01)` → receive HYDX
  to the Safe; the strike is financed by the **8-B5 self-collateralizing borrow** (loop steps 1–3), not by this
  module. **The profitability cutoff ($0.015 — skip exercise below it; $0.018 amber-taper; $0.01 mechanical floor),
  the regime gate (UP/FLAT-only), and the commitment gate (borrow→exercise→sell→repay) are LOAD-BEARING but live at
  the 8-B11 CRE layer, NOT in this contract** — the module is pure mechanism (pay strike, get HYDX); §4.5.1 is
  explicit that "a malformed CRE call cannot violate" the invariants is achieved by the *module's* gating
  (operator-only, recipient-pinned, value-0), with the caps/regime/cutoff enforced upstream. **State: none beyond the
  set-once wiring** (the "pending-exercise
  accounting / in-flight strike-borrow" §4.5.1 names is 8-B5's `debtOf` + the 8-B11 robot's view, not module storage).
- `baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one CRE operator = `onlyOperator`, mutate
  the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via `ModuleProxyFactory`, init in
  `setUp` under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B8** (the exercise description: the *paid*
  exercise of the sell slice, distinct from 8-B7's free `exerciseVe`; strike = `max(30%·2h-TWAP, $0.01)` read from
  oHYDX, not a knob; `maxPayment` slippage bound set per call) + **§3.2** (oHYDX marked at intrinsic = HYDX × (1 −
  discount) pre-exercise; post-exercise the position is HYDX, marked directly).
- `pending-docs/auto-sodomizer.md` **§4 (step c) / §9** (the exercise step of the harvest loop; strike funding via the
  borrow) **/ §2.4** (the price tiers: $0.015 loop cutoff / $0.018 amber-taper / $0.01 dead floor — a CRE pre-check, not a contract gate).
- `pending-docs/hydrex.md` **§2.4** (the price tiers: $0.015 loop cutoff / $0.018 amber-taper / $0.01 dead-option floor)
  **/ §2.5/§2.6** (the verified address book + live params).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation; collateral mocked. (8-B8 reopens nothing.)

**Model from (VERIFIED against `reference/`, the kept builds, and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol`. **Proven by the kept `ReservoirLoopModule`
  (8-B5), `LpStrategyModule` (8-B6), `HarvestVoteModule` (8-B7), `SzipBuyBurnModule` (8-B14), all build + fork-test
  green under 0.8.24:** `abstract contract Module is FactoryFriendly, Ownable`; `setUp(bytes) public virtual`;
  `initializer` is zodiac-core's own (`factory/Initializable.sol`, one-shot); `exec(to,value,data,Operation) internal`
  (`core/Module.sol:43`) and `execAndReturnData(...) internal returns (bool,bytes)` (`:59`) → forward to
  `IAvatar(target).execTransactionFromModule(...)` / `...ReturnData(...)`; `Operation { Call, DelegateCall }`
  (`core/Operation.sol:4`); `Ownable` is zodiac-core's own (`factory/Ownable.sol`; `_transferOwnership` internal,
  use in `setUp`; `setAvatar`/`setTarget` `public onlyOwner`). Remap
  `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/`; zodiac-core imports **zero OpenZeppelin** → no
  OZ-4/5 collision.
- **PRIMARY MODEL = `contracts/src/supply/szipUSD/ReservoirLoopModule.sol` (8-B5, the closest sibling — same
  approve→call→reset-approval USDC dance, the `repay` method `:190-208`).** Copy the module header (`Module`,
  `Operation` imports, `ReservoirLoopModule.sol:4-5`), the `_exec`-that-bubbles helper (model
  `ReservoirLoopModule.sol:146-154` — `private`; on `!ok` bubble inner revert data via the assembly
  `revert(add(ret,0x20),mload(ret))` or `revert ExecFailed()` when empty) **but make it `returns (bytes memory)`**
  (model `LpStrategyModule.sol:116-125` / `HarvestVoteModule.sol:129-138` — the `exercise` entrypoint MUST decode the
  returned `paymentAmount`, exactly as 8-B7's `lockVe` decodes the `nftId`). Copy the `setUp` validate-then-read-live
  pattern (`ReservoirLoopModule.sol:82-119` for the decode/validate/store; `HarvestVoteModule.sol:101-107` for the
  **live-read** of a dependency address), the `onlyOperator` modifier + the `setAvatar`/`setTarget` "left as
  onlyOwner, not hard-locked" comment (`ReservoirLoopModule.sol:122-130`), and the approve/reset selectors
  (`ReservoirLoopModule.sol:193,205`: `abi.encodeWithSelector(IERC20.approve.selector, oHYDX, amount)` then
  `... , 0`). **8-B8 has NO `borrowCap`, NO EVC, NO `debtOf` check** (those are 8-B5) — it is *simpler* on the EVC
  axis and identical on the approve axis.
- **The strike is paid in USDC — VERIFIED on live Base.** `oHYDX.paymentToken()` (`0x3013ce29`) staticcalled
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` = **USDC** (6-dp). `oHYDX.exercise(amount, maxPayment, recipient,
  deadline)` (`0xa1d50c3a`, in the existing `IOptionToken`, returns `paymentAmount`) **pulls `paymentAmount` USDC from
  `msg.sender` (the Safe)** and mints the underlying HYDX to `recipient`. So the module must `approve` oHYDX for the
  USDC strike **from the Safe** (the `exec` is run AS the Safe) before the exercise, then reset to 0. **Read
  `paymentToken` LIVE in `setUp` off `oHYDX.paymentToken()`** (the 8-B7 live-read pattern) — this guarantees the
  approve target token == the option's actual payment token and is fail-closed (assert nonzero).
- **The strike math is read from oHYDX, not a knob — VERIFIED on live Base.** `getDiscountedPrice(1e18)` (`0x339ccade`,
  in `IOptionToken`) = `10556` (= 30%·TWAP in USDC 6-dp); `getMinPaymentAmount()` (`0x2abb945c`, NO args) = `10000`
  (= the flat $0.01 floor); `getTimeWeightedAveragePrice(1e18)` (`0xe8772bb2`) = `35185` (30% of which ≈ 10556,
  confirming `getDiscountedPrice` IS `discount()·TWAP`); `discount()` (`0x6b6f4a9d`) = `30`. The actual strike the
  contract charges = `max(getDiscountedPrice(amount), getMinPaymentAmount())`. The **`quoteStrike(uint256 amount)`
  view** mirrors this so 8-B5/8-B11 size the borrow + the `maxPayment` cushion. **Do NOT compute the strike inside the
  mutator** — pass `maxPayment` as the operator-supplied slippage bound (the contract enforces `paymentAmount ≤
  maxPayment` and reverts otherwise; that revert bubbles through `_exec`).
- **The exercise needs the deadline overload — VERIFIED.** Both `exercise(uint256,uint256,address,uint256)`
  (`0xa1d50c3a`) and the 3-arg `exercise(uint256,uint256,address)` (`0xd6379b72`) are PRESENT in the deployed
  bytecode; the spec + this ticket use the **4-arg deadline overload** (the existing `IOptionToken` already declares
  exactly it). The 3-arg form is NOT added to the interface (unused — keep the surface minimal).
- **CRITICAL clone fact (§18.6, proven on 8-B5/8-B6/8-B7/8-B14).** A `ModuleProxyFactory` clone shares the
  mastercopy's runtime bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp`
  config. **Every per-clone wired address (`engineSafe`, `operator`, `oHYDX`, `paymentToken`) MUST be plain set-once
  storage written in `setUp` under `initializer`, NOT `immutable`.** Init-lock the mastercopy at deploy (test asserts
  a second `setUp` reverts).
- **Error declarations:** `error NotOperator(); error ZeroAddress(); error OwnerIsOperator(); error ZeroAmount();
  error PaymentExceedsMax(); error ExecFailed();` (model the block on `ReservoirLoopModule.sol:58-69`; drop
  `CapExceeded`/`DebtOutstanding` — no borrow leg here; add `PaymentExceedsMax` for the KR5 honesty check).
  `ZeroAmount` covers both `amount == 0` and `maxPayment == 0`.
- **Addresses (`contracts/script/BaseAddresses.sol` — all already present, none new):** `OHYDX
  0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` (present), `USDC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
  (present), `HYDX 0x00000e7efa313F4E11Bfff432471eD9423AC6B30` (present — the fork test asserts the HYDX delta).
  The live gauge `0xAC396CabF5832A49483B78225D902C0999829993` is **not needed** here (8-B8 reads no gauge). **oHYDX
  source for the fork seed:** `deal(OHYDX, engineSafe, amount)` first (oHYDX is a standard ERC20 —
  `name()=="Option to buy HYDX w/ USDC"`, `isPaused()==false`, verified in 8-B7); **fallback** impersonate the
  concrete holder **team Safe A `0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF`** (holds `2334e18` oHYDX,
  on-chain-verified) via `vm.prank` + `transfer` (declare `OHYDX_WHALE`). **USDC source for the strike:**
  `deal(USDC, engineSafe, strike)` (standard).

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…05, `SzipNavOracle`, `ExitGate`+`SzipUSD`, `ZipDepositModule`,
8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule`+`SzipReservoirLpOracle`+`ReservoirBorrowGuard`+
`ReservoirMarketDeployer`, 8-B6 `LpStrategyModule`, 8-B7 `HarvestVoteModule`). zodiac-core `Module` proven by
8-B5/8-B6/8-B7/8-B14; `IOptionToken.sol` exists + is on-chain-verified (`exercise` 4-arg / `exerciseVe` /
`getDiscountedPrice` / `discount`). `contracts/src/supply/szipUSD/` exists. **No engine Safe is summoned in unit
tests** — use a **recording mock Safe** (the `RecordingSafe` in `contracts/test/ReservoirLoopModule.t.sol` /
`HarvestVoteModule.t.sol`: implements `execTransactionFromModule` + `execTransactionFromModuleReturnData`, records
each `(to, value, data, operation)`, `setLive`/`getCall`/`callCount`, `setFailOnCallIndex` for atomicity, plus the
8-B7 `setReturnData(bytes)` extension for the return decode) for validation/authority/exec-shape, and a **real Base
fork** with the **real summoned substrate Safe** (`SummonSubstrate._summon`, model
`ReservoirLoopModule.t.sol`/`HarvestVoteModule.t.sol _summonAndEnable`) as the engine Safe for the live `exercise`.

**Test-harness extensions to author (build them in the test file):**
- **`RecordingSafe` return-data (the `paymentAmount` decode).** Reuse the 8-B7 `RecordingSafe` **verbatim** — its
  non-live `_record` returns `(true, _returnData)` for **EVERY** call (confirmed: `HarvestVoteModule.t.sol`
  `RecordingSafe._record` returns the global `_returnData` on every non-live call). So: `setReturnData(abi.encode(
  uint256 expectedPayment))`, then `exercise(a, m, d)` — the module decodes the **2nd** exec's return as
  `paymentAmount` and **ignores** the 1st/3rd `approve` returns (the same blob comes back on all three; harmless
  because the module never reads the approve returns). **The global-`_returnData` mock is sufficient; do NOT build a
  per-index variant** (it adds surface for no gain — the module only decodes one exec). The `paymentAmount` decode
  MUST be exercised on the non-live path (assert `emit Exercised(a, expectedPayment)` + the function return). ALSO a
  **short/empty return-data** case (`setReturnData` to `< 32` bytes) → `exercise` **reverts** (the decode must not emit
  garbage), and a **`expectedPayment > maxPayment`** case → `exercise` reverts `PaymentExceedsMax` (KR5).
- **Target mock `MockOHYDX`** (the `_exec` target; the model files have no analog): a **settable** `paymentToken()`
  (incl. `address(0)` to prove the `setUp` `ZeroAddress` fail-closed), `getDiscountedPrice(amount)` /
  `getMinPaymentAmount()` (settable, to prove `quoteStrike` = max of the two), and an `exercise(...)` that **records**
  its `(amount, maxPayment, recipient, deadline)` args (to prove `recipient == engineSafe` and the deadline/maxPayment
  pass-through) and returns a settable `paymentAmount`. A `MockUSDC` (or reuse a standard mock ERC20) is the wired
  `paymentToken` for the approve-shape assertions.
- **A `live`-Safe atomicity case:** a target returning `(false, customErrorBytes)` through a `live` Safe so the
  `_exec` assembly-bubble is exercised, plus a `(false, "")` case asserting `ExecFailed`.

**Do NOT**
- **Do NOT** compute or enforce the strike, the profitability cutoff ($0.015), the regime (UP/FLAT/DOWN), the commitment gate,
  or the loop size in the contract — those are **8-B11 CRE policy** (§4.5.1; `hydrex.md §2.4/§9.2`). The module takes
  `maxPayment` as the per-call slippage bound and lets oHYDX enforce `paymentAmount ≤ maxPayment`. The contract is
  pure mechanism.
- **Do NOT** call `exercise` with `recipient != engineSafe`. The HYDX must mint to the Safe (the basket), never to the
  operator or a third party (the irreversibility/value-leak firewall — assert the recorded recipient `== engineSafe`).
- **Do NOT** add an EVC leg, a borrow/repay, a `borrowCap`, an LP/escrow leg, a veNFT, or the free `exerciseVe` — those
  are 8-B5/8-B6/8-B7. 8-B8 is the **single paid `exercise`** only. Do NOT touch the 8-B5 borrow accounting (the strike
  USDC is already in the Safe when `exercise` runs; the borrow that put it there is 8-B5's `borrow`, sequenced by the
  CRE robot).
- **Do NOT** leave a standing USDC approval — reset to 0 after the exercise (the residual = `maxPayment − paymentAmount`
  would otherwise stand; hygiene, parity with 8-B5 `repay`). **`maxPayment` is the SLIPPAGE GUARD, not a malware
  defense.** oHYDX is immutable + non-proxy (verified on Base — empty EIP-1967 slot, no `owner()`); it computes the
  strike from its own TWAP and pulls **exactly** that, reverting if it would exceed `maxPayment`. Fork-proven: the
  charge `== quoteStrike(amount)` read in the same block. So `maxPayment`'s job is to **abort the loop on a TWAP spike**
  between the CRE's quote and tx execution (instead of overpaying the basket). 8-B11 sets `maxPayment = quoteStrike ×
  a small cushion` — too tight → normal drift reverts; too loose → a genuine spike could be paid (a real economic
  overpay to the basket, NOT theft). This is why the cushion must be modest (logged as an 8-B11 obligation). **Do NOT
  switch to module-self-quote-exact** (read the strike on-chain + approve exactly): it would DELETE the spike guard —
  the module would pay whatever the current strike is, unconditionally. `maxPayment` is the protection; keep it
  operator-supplied. (And the CRE must compute the strike regardless, to size the 8-B5 borrow — the binding constraint.)
- **Do NOT** use `immutable` for any wired address (clone fact); **do NOT** add a generic `exec`/`call` passthrough,
  delegatecall, or non-zero `value`; **do NOT** hard-lock `setAvatar`/`setTarget` (keep them zodiac-core `onlyOwner`,
  matching the siblings — marking the vendored setters `virtual` would dirty the pristine reference dep).
- **Do NOT** add the 3-arg `exercise` overload, `getTimeWeightedAveragePrice`, or any other oHYDX method the module
  does not call to the interface (keep the surface minimal; only `paymentToken` + `getMinPaymentAmount` are new).

**Key requirements**
1. **`is Module` on the engine Safe, clone-safe.** Inherit zodiac-core `Module`; `setUp(bytes)` under `initializer`
   decodes the **4** addresses `(address owner, address engineSafe, address operator, address oHYDX)`. **ORDER is
   load-bearing (the sibling pattern):** validate `owner`/`engineSafe`/`operator`/`oHYDX` nonzero FIRST + `owner !=
   operator` (so a zero `oHYDX` reverts `ZeroAddress`, not a confusing staticcall-to-zero), set `avatar = target =
   engineSafe`, store the wiring, THEN read `paymentToken = IOptionToken(oHYDX).paymentToken()` live and assert
   **nonzero** (`ZeroAddress`), THEN `_transferOwnership(owner)`. **setUp args (4):** `(owner, engineSafe, operator,
   oHYDX)`. All wired addresses are **set-once storage, never `immutable`**. The mastercopy is init-locked at deploy
   (test asserts a second `setUp` reverts).
2. **`onlyOperator` on the mutator; recipient hard-pinned to `engineSafe`.** `exercise` reverts `NotOperator` for any
   non-operator caller. It passes `recipient = engineSafe`. Tests: a non-operator caller reverts; a non-owner
   `setAvatar`/`setTarget` reverts; `owner == operator` in `setUp` reverts `OwnerIsOperator`.
3. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** Every mutation routes through the private
   `_exec(to, data) returns (bytes)` using `execAndReturnData(to, 0, data, Operation.Call)`; on `!ok` it bubbles the
   inner revert data (or `ExecFailed` when empty). The three calls, in order:
   (1) `_exec(paymentToken, abi.encodeWithSelector(IERC20.approve.selector, oHYDX, maxPayment))`,
   (2) `_exec(oHYDX, abi.encodeCall(IOptionToken.exercise, (amount, maxPayment, engineSafe, deadline)))` — **typed
   `encodeCall`, NOT `encodeWithSelector`**, so an arg-order regression (a recipient/deadline slip) fails to compile,
   (3) `_exec(paymentToken, abi.encodeWithSelector(IERC20.approve.selector, oHYDX, 0))`.
   **Import `{IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"`** for the `approve` selector (the 8-B5
   `ReservoirLoopModule.sol:10` import). **Only the 2nd `_exec` return is decoded** (`paymentAmount =
   abi.decode(ret,(uint256))`); the two `approve` returns are ignored. Tests assert the
   entrypoint produces exactly `(paymentToken, 0, approve(oHYDX,maxPayment), Call)`, `(oHYDX, 0,
   exercise(amount,maxPayment,engineSafe,deadline), Call)`, `(paymentToken, 0, approve(oHYDX,0), Call)` on the
   recording Safe — and **decode the recorded exercise calldata's recipient arg and assert `== engineSafe`** (not
   merely a keccak match). Atomicity: a `live` Safe returning `(false, customErrorBytes)` (e.g. the oHYDX
   `maxPayment`-exceeded revert) makes `exercise` **revert bubbling that data**; `(false, "")` reverts `ExecFailed`.
4. **Guards.** `exercise`: `amount == 0` reverts `ZeroAmount`; `maxPayment == 0` reverts `ZeroAmount` (a zero strike
   allowance would always fail at oHYDX — fail fast + testable). `deadline` is passed through un-validated (oHYDX
   enforces it; the operator sets `block.timestamp + buffer`).
5. **`exercise` decodes + emits `paymentAmount`.** The 2nd `_exec` returns the encoded `paymentAmount`; decode
   `abi.decode(ret,(uint256))`, then **assert `paymentAmount <= maxPayment` (revert `PaymentExceedsMax`)** — a
   defense-in-depth honesty check: the USDC `approve(oHYDX, maxPayment)` already bounds the *actual* USDC the Safe can
   ever pay (an over-reporting / compromised oHYDX cannot pull more than the allowance), so this assert does NOT add a
   new fund-safety guarantee — it ensures the emitted `Exercised(amount, paymentAmount)` event can never report a
   payment larger than was authorized (a misleading event would corrupt the 8-B11/8-B12 accounting that reads it).
   `emit Exercised(amount, paymentAmount)`, `return paymentAmount`. A malformed (`< 32`-byte) return reverts (the
   decode must not emit garbage).
6. **View (8-B5/8-B11 back-pressure):** `quoteStrike(uint256 amount) view returns (uint256)` →
   `max(IOptionToken(oHYDX).getDiscountedPrice(amount), IOptionToken(oHYDX).getMinPaymentAmount())` (the USDC strike
   the contract will charge, so 8-B5 sizes the borrow + 8-B11 sets `maxPayment` with a cushion). Plus the public
   set-once getters (`engineSafe`/`operator`/`oHYDX`/`paymentToken`).
7. **Interface additions are minimal + verified** (Deliverable list): `IOptionToken.paymentToken()` +
   `getMinPaymentAmount()`, each carrying the on-chain-verified selector in a comment (the house `[EXT]` posture).

**Done when**
- `forge build` green; `forge test --match-contract ExerciseModuleTest` green (unit) and
  `forge test --fork-url $BASE_RPC_URL --match-contract ExerciseModuleTest` green (unit + fork); **no regression** on
  the full suite (`forge test --fork-url $BASE_RPC_URL`, currently 326/326 after 8-B7).
- **Unit (RecordingSafe + MockOHYDX + a real MockUSDC):** (a) **exec-shape, fully pinned** — `exercise(a, m, d)`
  produces exactly three recorded calls: `(paymentToken, 0, approve(oHYDX, m), Call)`, `(oHYDX, 0, exercise(a, m,
  engineSafe, d), Call)`, `(paymentToken, 0, approve(oHYDX, 0), Call)`. **For EACH recorded call assert `value == 0`
  AND `operation == uint8(Operation.Call)`** (not just `to`/`data`). **Decode ALL FOUR exercise args from `getCall(1)`
  and assert `(amount==a, maxPayment==m, recipient==engineSafe, deadline==d)`** (the recipient-pin + deadline/maxPayment
  pass-through firewall — calldata-decode, not a keccak match); **decode the `approve(oHYDX, 0)` reset call args** too
  (assert spender==oHYDX, amount==0). The mock returns a set `paymentAmount` → assert `emit Exercised(a, paymentAmount)`
  (via `vm.expectEmit`) and the function's **return value** equals it. (b) **malformed return** — the mock's exercise
  return set to `< 32` bytes → `exercise` **reverts**; and `paymentAmount > maxPayment` → `exercise` reverts
  `PaymentExceedsMax` (KR5). (c) authority — `exercise` reverts `NotOperator` for a non-operator (operator + rando);
  `setAvatar`/`setTarget` revert for a non-owner; `owner == operator` setUp reverts `OwnerIsOperator`; the **un-setUp
  mastercopy** is inert (`exercise` reverts `NotOperator`, every getter returns 0). (d) guards — `exercise(0, m, d)` →
  `ZeroAmount`; `exercise(a, 0, d)` → `ZeroAmount`. (e) atomicity — the production **bubble** path: a `live` target
  returning `(false, customErrorBytes)` makes `exercise` revert bubbling that data; `(false, "")` reverts `ExecFailed`.
  **(e2) state-moving rollback** — wire the module to a **live** RecordingSafe + a real `MockUSDC` + a `MockOHYDX`
  whose `exercise` REVERTS (the slippage-bound analog); call `exercise`; `vm.expectRevert`; **then assert
  `MockUSDC.allowance(safe, oHYDX) == 0`** (the approve in exec #1 is rolled back with the atomic tx — proves no
  dangling approval survives a mid-loop failure, the property the prose claims). **(e3) state-moving happy path** —
  a `live` RecordingSafe + `MockUSDC` (Safe pre-funded) + a `MockOHYDX` that pulls `paymentAmount` USDC and returns it:
  after `exercise`, assert `MockUSDC.allowance(safe, oHYDX) == 0` (the reset actually cleared the residual
  `maxPayment − paymentAmount` on a state-moving path, not just the calldata shape). (f) clone/init — a second `setUp`
  on the SAME instance reverts (the zodiac-core `initializer` lock); the deploy-time mastercopy `setUp` leaves it
  locked; a zero in **each** of the 4 addresses reverts `ZeroAddress` — **for the zero-`oHYDX` case assert the revert
  selector is `ExerciseModule.ZeroAddress` specifically** (proving the order-guard fires before a staticcall-to-zero);
  a `MockOHYDX` whose `paymentToken()` returns `0` reverts `ZeroAddress` at setUp. (g) view — `quoteStrike(amount)`
  returns `max(getDiscountedPrice, getMinPaymentAmount)` (set the mock so each side wins once — prove the `max`);
  **`quoteStrike(0)` returns `getMinPaymentAmount()`** (the floor dominates at zero — pins the `max` boundary) and a
  **tie** case (`getDiscountedPrice == getMinPaymentAmount`) returns that value.
- **Fork (live Base, real summoned Safe):** (a) **sig-verify** — staticcall `oHYDX.paymentToken()` (== USDC),
  `oHYDX.getDiscountedPrice(1e18)`, `oHYDX.getMinPaymentAmount()`, `oHYDX.discount()` (== 30) resolve on the live
  oHYDX `0xA113…`; **and assert the MODULE stored the live payment token: `module.paymentToken() == USDC`** (the
  `setUp` live-read resolved to the real USDC). (b) **real `exercise` proves the model** — `deal`/whale oHYDX to the Safe + `deal` USDC ≥ the strike
  to the Safe, enable the module, operator `exercise(amount, maxPayment, block.timestamp + 1h)` with `maxPayment` =
  `quoteStrike(amount)` × a small cushion: assert `oHYDX.balanceOf(Safe)` decreased by **exactly `amount`** (the
  burn), `USDC.balanceOf(Safe)` decreased by **exactly the returned `paymentAmount`** (`≤ maxPayment`), `HYDX.balanceOf(
  Safe)` **increased** (the underlying minted to the Safe), `USDC.allowance(Safe, oHYDX) == 0` (the reset — no standing
  approval), and `Exercised(amount, paymentAmount)` emitted with a nonzero `paymentAmount`. (c) **`maxPayment`-too-low
  reverts** — call `exercise(amount, 1, block.timestamp + 1h)` (a strike allowance far below the real strike) and
  assert it **reverts** (the oHYDX slippage guard bubbles through `_exec`); **then assert the Safe state is unchanged:
  `USDC.allowance(Safe, oHYDX) == 0` AND `oHYDX.balanceOf(Safe)` unchanged AND `HYDX.balanceOf(Safe)` unchanged** (the
  atomic revert rolled back exec #1's approve — no dangling approval, no partial burn/mint). (d) **past deadline
  reverts** (cheap) — `exercise(amount, maxPayment, block.timestamp - 1)` reverts.
- Mapped to the integration layer: the per-epoch exercise belongs in the **deferred engine-integration audit sweep**
  (`audit/2.md` Phase L + `audit/3-results.md` authority rows), authored once the engine is integration-testable
  alongside item-10 — logged as an obligation, NOT in this window (matches the 8-B5/8-B6/8-B7/Exit-Gate sweeps).

**Depends on**
- **8-B1** (the summoned engine Safe substrate — `SummonSubstrate._summon`, at
  `contracts/script/SummonSubstrate.s.sol`) and **8-B5/8-B7** (the `ReservoirLoopModule.sol` approve-dance primary
  model + the test harness). **The cold-builder MUST open these test files to reuse the harness:**
  `contracts/test/HarvestVoteModule.t.sol` (the `RecordingSafe` with `setLive`/`setFailOnCallIndex`/`getCall`/
  `callCount`/`setReturnData` — `_record` returns `(true, _returnData)` on every non-live call — and the
  `_summonAndEnable` fork pattern) and `contracts/test/ReservoirLoopModule.t.sol` (the live-Safe approve/exec
  patterns). The on-chain `IOptionToken` interface already exists (extend it minimally with `paymentToken` +
  `getMinPaymentAmount`).
- **Feeds:** 8-B9 (market-sells the resulting HYDX → USDC to repay the 8-B5 borrow), 8-B5 (the borrow that funds the
  strike; the loop wraps this exercise as step c), 8-B11 (the CRE robot that classifies regime, runs the soft-halt
  pre-check, sizes `maxPayment`, and sequences borrow→exercise→sell→repay — the commitment gate), item 2 NAV (oHYDX
  marked at intrinsic pre-exercise; post-exercise the HYDX is marked directly, §3.2).

---

**New cross-ticket obligations this ticket CREATES** (record in `PROGRESS.md` at Conclude):
- **Item 10 / engine-integration audit sweep (8-B8):** author the paid exercise into `audit/2.md` Phase L (an L-step
  borrow (8-B5) → `exercise` → sell (8-B9) → repay, with oHYDX/USDC/HYDX balances moving; N-steps: non-operator /
  zero-amount / zero-maxPayment / `maxPayment`-too-low / past-deadline each revert) + the matching
  `audit/3-results.md` authority rows (operator-only entrypoint; `setAvatar`/`setTarget` owner-locked; recipient
  pinned to the engine Safe; no standing approval; no custody beyond the transient HYDX). Author once the engine is
  integration-testable (with 8-B9…B13 + item-10), like the 8-B5/8-B6/8-B7/Exit-Gate sweeps.
- **Item 10 / 8-B11 — operator + oHYDX wiring (8-B8):** the single CRE operator is the module's `operator` (sole
  caller); wire `oHYDX` to the live option token `0xA113…` (its `paymentToken` read live = USDC). **Deploy the clone
  via the proven `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe — the salt +
  initializer calldata are bundled, so a griefer cannot init someone else's clone), and init-lock the mastercopy at
  deploy** (the 8-B5/8-B14 deploy pattern; never a two-tx deploy-then-init). The 8-B11 robot runs the
  profitability-cutoff pre-check (skip if HYDX < $0.015; $0.018 amber-taper), the regime gate (exercise ONLY in UP/FLAT; DOWN → route to 8-B7 `exerciseVe`), the
  **commitment gate** (borrow + exercise COMMITS to a repay market-sell → enter the loop only at a size whose 8-B9
  repay-sell fits the per-epoch soft-bleed cap), sizes `maxPayment` off `quoteStrike` + a **TIGHT slippage cushion**
  (≤ a few % — `maxPayment` is the single-tx USDC pull ceiling incl. a compromised oHYDX, so a fat cushion = a fat
  drain ceiling), and sets the per-call `deadline`. These are LOAD-BEARING but live OFF-chain (the module is correctly
  agnostic — it cannot see regime/spot/loop-size).
- **8-B9 — HYDX hand-off (8-B8 → 8-B9):** the HYDX minted to the Safe by `exercise` is the input the 8-B9 market-sell
  consumes to repay the 8-B5 borrow immediately (the pool is net-draining, no buy-side → market-sell, not resting).
  8-B9 must consume the Safe's HYDX balance the exercise produced, bounded by the §9.3 soft-bleed caps (which size the
  loop, set at 8-B8's `amount`).
