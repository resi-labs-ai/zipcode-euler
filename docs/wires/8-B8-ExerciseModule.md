# 8-B8 — ExerciseModule (wiring map)

> **X-Ray (security verdict):** rated **ADEQUATE** — pays the option strike to mint liquid HYDX; recipient
> hard-pinned to the vault, strike slippage-bounded by the option's own price with a max-payment backstop. Proven
> unit + live oHYDX fork (26 unit + 4 fork). Report:
> `contracts/src/supply/szipUSD/x-ray/ExerciseModule.md` (scope: `portfolio-map.md`). ELI20:
> `docs/supply/szipUSD/ExerciseModule.md`. This doc is the code-truth wiring map.

> Source of truth = `contracts/src/supply/szipUSD/ExerciseModule.sol`. Ticket
> `tickets/sodo/8-B8-exercise-ohydx.md` + report `reports/8-B8-report.md` are intent only — the kept
> `.sol` is final. Every claim below is read off the code; the doc records how the module is wired.

## Role
The **fifth engine Zodiac Module** (after the 8-B14 buy-and-burn, the 8-B5 farm utility loop, the 8-B6 LP
strategy, and the 8-B7 harvest/vote) — the on-chain seam of the **8-B8 paid-exercise leg** (§4.5.1). It owns
the **PAID exercise of the sell slice**: per harvest the CRE robot (8-B11) finances the ~30% USDC strike via
the 8-B5 borrow (the USDC is already in the engine Safe), then calls one `onlyOperator`
`exercise(amount, maxPayment, deadline)` here. The module approves the strike to oHYDX, calls
`oHYDX.exercise(...)` (burns the Safe's oHYDX, pulls the strike USDC, mints liquid HYDX **to the Safe**),
and resets the approval. 8-B9 then market-sells the HYDX to repay the borrow.

This is **DISTINCT from 8-B7's FREE `exerciseVe` permalock** — it is the *paid* `oHYDX.exercise` (a different
oHYDX function, with a USDC strike). The module has **NO EVC leg** (the borrow that funds the strike is 8-B5's
job), **NO oracle, NO LP, NO veNFT** — it is pure exercise mechanism. It is enabled ON the engine Safe and only
ever mutates it (`avatar == target == juniorTrancheEngine`).

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `ExerciseModule` (`is Module`, zodiac-core) | The module. Four set-once storage pins (`juniorTrancheEngine`/`operator`/`oHYDX`/`paymentToken` — **not immutable**, written in `setUp` because clones share mastercopy bytecode). One `onlyOperator` mutator `exercise(amount, maxPayment, deadline)` driving the Safe via inherited `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles. One `quoteStrike(amount)` view. Owner-only Timelock re-wiring setters. |
| `IOptionToken` (`src/interfaces/hydrex/IOptionToken.sol`) | Minimal local interface for **oHYDX** (`OptionTokenV4` @ Base `0xA113…cB78`, non-proxy). Calls used: `exercise(uint256,uint256,address,uint256)` (4-arg deadline overload, returns `paymentAmount`), `paymentToken()` (live-read → USDC), `getDiscountedPrice(uint256)` + `getMinPaymentAmount()` (the `quoteStrike` view). |
| `Module` / `Operation` (`@gnosis-guild/zodiac-core/core/…`) | Base. Provides `setUp`-under-`initializer`, `avatar`/`target`, `execAndReturnData`, `_transferOwnership`, and the inherited `onlyOwner` `setAvatar`/`setTarget`. |
| `IERC20` (OZ `token/ERC20/IERC20.sol`) | The `approve` selector encoded onto `paymentToken` (the strike allowance + the reset). |

## Wiring — internal (ctor/setUp + the one entrypoint)
- **No constructor logic** — the module is a zodiac-core clone target. All per-clone wiring is plain **set-once
  storage written in `setUp`** under the zodiac-core `initializer` (CLONE FACT, §18.6: `immutable` lives in the
  shared mastercopy runtime and cannot carry per-clone config). The mastercopy is init-locked in its constructor
  (see `MastercopyInitLock`, SEC-14).
- **`setUp(bytes initParams)`** decodes **4 addresses** `(owner, juniorTrancheEngine, operator, oHYDX)`. ORDER is
  load-bearing: (1) validate all four decoded addresses nonzero **and** `owner != operator` FIRST (so a zero
  `oHYDX` reverts `ZeroAddress`, not a confusing staticcall-to-zero); (2) set `avatar = target = juniorTrancheEngine`
  (enabled ON, only ever mutates, the engine Safe); (3) store `juniorTrancheEngine`/`operator`/`oHYDX`; (4) **read
  `paymentToken` LIVE off `IOptionToken(oHYDX).paymentToken()`** and assert it nonzero; (5)
  `_transferOwnership(owner)`. Errors: `ZeroAddress`, `OwnerIsOperator`.
- **`exercise(uint256 amount, uint256 maxPayment, uint256 deadline) onlyOperator returns (uint256 paymentAmount)`**
  — the sole mutator. Guard: `amount == 0 || maxPayment == 0` reverts `ZeroAmount`. Then **exactly 3 `exec`s**:
  1. `paymentToken.approve(oHYDX, maxPayment)` — the strike allowance from the Safe (`abi.encodeWithSelector(IERC20.approve.selector, oHYDX, maxPayment)`).
  2. `oHYDX.exercise(amount, maxPayment, juniorTrancheEngine, deadline)` — the **4-arg deadline overload**, typed via
     `abi.encodeCall(IOptionToken.exercise, …)`; **`recipient` hard-pinned to the set-once `juniorTrancheEngine`** (HYDX
     can only ever mint to the basket, never the operator/a third party). Burns the Safe's oHYDX, pulls
     `paymentAmount` (≤ `maxPayment`) USDC from the Safe, mints HYDX to the Safe, returns `paymentAmount`.
  3. `paymentToken.approve(oHYDX, 0)` — reset the residual allowance (no standing approval; security parity
     with 8-B5 `repay`).
  Then `paymentAmount = abi.decode(ret, (uint256))`; **KR5 honesty guard** `if (paymentAmount > maxPayment)
  revert PaymentExceedsMax()` (defense-in-depth — the USDC approval already bounds the real pull at
  `maxPayment`; this re-asserts the bound on the decoded return so the emitted/returned value 8-B11/8-B12
  accounting reads can never exceed the authorized strike even against a malformed decode). Emits
  `Exercised(amount, paymentAmount)`.
- **`_exec(to, data)` (private):** drives the Safe via `execAndReturnData(to, 0, data, Operation.Call)` and
  **HARD-REVERTS on `false`**, bubbling the inner revert data (`assembly { revert(add(ret,0x20), mload(ret)) }`),
  empty data → `ExecFailed`. This surfaces the original oHYDX error (a `maxPayment`-exceeded slippage revert or a
  past-deadline revert) — the Gnosis Safe's `execTransactionFromModuleReturnData` catches inner reverts and
  returns `(false, revertData)` rather than bubbling, so an unchecked exec would silently swallow a failed
  exercise and wrongly report success. **`value == 0` on every exec; `Operation.Call` only; no delegatecall, no
  generic call/exec passthrough** — the operator supplies ONLY scalars and the module builds ALL calldata to the
  set-once wired targets (§10.1, the module's whole security boundary).
- **`maxPayment` = the SLIPPAGE/spike guard.** oHYDX (immutable, non-proxy) computes the strike from its own
  TWAP and pulls EXACTLY that, reverting if it would exceed `maxPayment` — so a TWAP spike between the CRE's
  quote and tx execution safely ABORTS the loop instead of overpaying the basket (fork-proven: the charge ==
  `quoteStrike(amount)` read in the same block).
- **`quoteStrike(uint256 amount)` (view):** the USDC strike the contract will charge =
  `max(getDiscountedPrice(amount), getMinPaymentAmount())` (the flat $0.01 floor dominates for small `amount`).
  8-B5 sizes the borrow + 8-B11 sets the `maxPayment` cushion off this read.
- **Re-wiring setters (build phase, §17), all `onlyOwner` (Timelock):** `setJuniorTrancheEngine` (keeps
  `avatar`/`target` in sync), `setOperator`, `setOHYDX` (**re-reads `paymentToken` LIVE off the new option**,
  fail-closed, emits both `WiringSet("oHYDX",…)` and `WiringSet("paymentToken",…)`), and `setPaymentToken` (a
  direct override should the option's payment token need pinning). All revert `ZeroAddress` on a zero arg.
  `setOperator` additionally re-checks `operator != owner` (`OwnerIsOperator`, SEC-15) so a re-point cannot collapse
  the Timelock owner and the CRE operator into one key — preserving the init-time (`setUp`) role separation.
- **`setAvatar`/`setTarget`** are inherited zodiac-core `onlyOwner` — the CRE `operator` (hot key) CANNOT call
  them; only the Timelock owner can. Not hard-locked (that would require marking the vendored setters `virtual`;
  reference deps stay pristine) — a non-owner caller reverts (tested).

## Wiring — cross-component (who points at whom)
- **`oHYDX` → the live option token `0xA113…cB78`** (`BaseAddresses.OHYDX`, `OptionTokenV4`, immutable/non-proxy,
  on-chain-verified). The exercise target; burns the Safe's oHYDX and mints HYDX. Charges exactly
  `quoteStrike(amount)`.
- **`paymentToken` = LIVE-read off `oHYDX.paymentToken()` → USDC** (`0x8335…2913` on Base). Live-read in `setUp`
  (and re-read by `setOHYDX`) so the `approve` target can never drift from the option's actual payment token —
  fail-closed.
- **HYDX output (`BaseAddresses.HYDX 0x0000…6B30`) → 8-B9 sell input.** The HYDX `exercise` mints to the Safe is
  exactly what 8-B9 `SellModule.sellHydx` market-sells (`SwapRouter.exactInputSingle`) to USDC to repay the 8-B5
  borrow immediately (PROGRESS row 347, DISCHARGED by 8-B9).
- **Strike USDC funding = the 8-B5 borrow.** The module touches no EVC account; the borrow that finances the
  strike is 8-B5's job, and the USDC is already in the Safe when the operator calls `exercise`.
- **`operator` = the single CRE operator** (8-B11 strategy robot) — the sole caller of `exercise`. Internal
  engine plumbing: no INFLOW ticket, the frontend never wires to it.

## Item-10 deploy facts (PROGRESS row 346)
- **Wire the single CRE operator** as `ExerciseModule.operator` (the sole `exercise` caller); **wire `oHYDX`** to
  the live option token `0xA113…` (its `paymentToken` live-read = USDC).
- **Deploy the clone via `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe)** —
  the 8-B5/8-B14 pattern (`ZODIAC_MODULE_PROXY_FACTORY 0x0000…a236`); **never a two-tx deploy-then-init**. The
  mastercopy is locked AUTOMATICALLY by its constructor (`MastercopyInitLock`, SEC-14) the instant it is deployed —
  NO separate deploy-time lock step, and `setUp` on the mastercopy reverts `AlreadyInitialized`.
- **`owner = Timelock`, distinct from `operator`** (enforced by the `OwnerIsOperator` guard in `setUp`). The
  Timelock holds the re-wiring + `setAvatar`/`setTarget`; the operator holds only the hot exercise entrypoint.
- **The gates live in 8-B11 CRE policy, NOT contract constants:**
  - **Profitability gate** — skip exercise when HYDX/USD < the **$0.015 loop cutoff** (user-ratified canonical
    cutoff; $0.018 = amber/begin-taper; $0.01 = the mechanical dead floor, never reached). The price input is the
    CRE `reportType 7` HYDX/USD leg that already feeds `SzipNavOracle` (reuse it, not a new feed).
  - **Regime gate** — exercise ONLY in UP/FLAT; DOWN → route to 8-B7 `exerciseVe`.
  - **Commitment gate** — borrow+exercise COMMITS to a repay market-sell → enter only at a size whose 8-B9
    repay-sell fits the per-epoch soft-bleed cap.
  - **`maxPayment` cushion** — `maxPayment = quoteStrike(amount) × a modest cushion` (too tight → normal drift
    reverts; too loose → a genuine TWAP spike overpays the basket). Self-quote-exact was evaluated + REJECTED
    (it would delete the spike guard).
- **Cadence = the Hydrex weekly epoch (604800s)** — votes reset weekly, emissions accrue weekly, so the refinery
  loop runs ~weekly.

## Gotchas
- **When unprofitable, simply do NOT call 8-B8.** The oHYDX accrues in the Safe (8-B7 keeps claiming it; marked
  at intrinsic in NAV) until a profitable epoch — there is no on-chain threshold in the module (it holds none;
  the cutoff is CRE policy that tracks live pool depth + slippage).
- **oHYDX is immutable/non-proxy and charges EXACTLY `quoteStrike(amount)`** (its own TWAP); `maxPayment` only
  bounds/aborts, it does not set the price. The same-block fork proof: the real charge == `quoteStrike(amount)`.
- The KR5 `PaymentExceedsMax` guard is defense-in-depth on the *decoded return* — the real USDC pull is already
  bounded by the `approve(oHYDX, maxPayment)` allowance even if the return decode were malformed.
- The 3rd exec (reset-to-0) leaves no standing approval — hygiene parity with 8-B5 `repay`.
