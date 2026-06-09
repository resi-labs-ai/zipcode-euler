# 8-B10 — Recycle module (`RecycleModule`) — the engine's free-value ledger + its single recycle sink

> **Reconciled 2026-06-08 to the as-built single-sink redesign.** This ticket originally specified a
> `RecyclePayoutModule` (free-value ledger + Mode A clean-USDC payout + Mode B boosted-xALPHA loop) plus a companion
> `SzipRewardsDistributor` (pull-claim Merkle distributor), with Mode C deferred to 8-B13. The user collapsed 8-B10 to
> a **single recycle sink**: no payout, no xALPHA leg, no distributor, no compounder seam; **8-B13 absorbed** (single-sided
> LP moots the balanced-add compounder). The pre-rework design rationale lives in `reports/8-B10-report.md` (retained
> builder section) + the `PROGRESS.md`/`LEDGER.md` historical digests. The body below is the **as-built recipe**.

> **Build-only.** A harvest-loop engine module (sibling of 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6 LP-strategy,
> 8-B7 harvest-vote, 8-B8 exercise, 8-B9 sell). It owns the **free-value ledger** of the auto-sodomizer — the single
> `freeValueAccrued` accumulator (no other module writes it) — and the ONE sink that spends it: `recycle(usdc)` parks the
> free-value USDC as senior warehouse backing + mints backed zipUSD 1:1 **into the MAIN-Safe basket** (no
> `gate.depositFor`, no share issuance). 8-B6 single-sides that zipUSD into the ICHI LP next (CRE-sequenced). Basket
> grows, share count flat → **NAV-per-share accretes for every holder** (the depositor's M1 return). Internal engine
> plumbing → build-only (no INFLOW ticket; the 8-B11 CRE robot drives the entrypoints).

**Deliverable**
One new contract + its test file:

- `contracts/src/supply/szipUSD/RecycleModule.sol` — `contract RecycleModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine Safe**
  (`avatar == target == engineSafe`). It mutates the Safe **only** via the inherited `execAndReturnData(to, 0, data,
  Operation.Call)` through a private `_exec`-that-bubbles (copied from `SellModule._exec`). **Owned state = one
  `uint256 freeValueAccrued`** (the engine's free-value ledger; §8 inv. 3) plus the set-once wiring. Surface:
  - **`creditFreeValue(uint256 amount)`** — `onlyOperator`. `amount == 0` reverts `ZeroAmount`; else
    `freeValueAccrued += amount`; `emit FreeValueCredited(amount, freeValueAccrued)`. Called by the CRE robot after 8-B9
    sweeps a fill and 8-B5 repays the strike-borrow: the operand is the USDC realized **net of** the borrow repaid for
    that loop, i.e. the CRE passes `max(0, realized − borrowRepaid)` (only the HYDX sold above the ~30% strike is free
    value). **Single arg, operator-trusted** — the module cannot reconstruct `realized`/`borrowRepaid` on-chain
    (historical), exactly as every sibling trusts the single immutable CRE operator to size scalars (§17). (The
    accumulator is a POLICY ceiling on spend; the HARD backing guarantee is the real USDC `safeTransferFrom` the deposit
    leg does from the Safe — see Key requirement 5.)
  - **`recycle(uint256 usdcAmount) returns (uint256 zipMinted)`** — `onlyOperator`. The single sink.
    `_spendFreeValue(usdcAmount)` (effects first — the policy gate), then drive the Safe through three `_exec`s: (1)
    `usdc.approve(zipDepositModule, usdcAmount)`, (2) `zipDepositModule.deposit(usdcAmount)` — mints `usdcAmount·scaleUp`
    **backed** zipUSD to the Safe (the deposit parks the USDC into the venue pool with the warehouse Safe as the EE-share
    receiver → senior backing), decode the returned `zipMinted`, (3) `usdc.approve(zipDepositModule, 0)` (reset — no
    standing approval). `emit Recycled(usdcAmount, zipMinted)`. The minted zipUSD stays in the MAIN-Safe basket — no
    `gate.depositFor`, no new shares — and 8-B6 single-sides it into the LP on the next CRE step.
  - **`_spendFreeValue(uint256 amount)`** — `private`, the single debit path. `amount == 0` reverts `ZeroAmount`;
    `amount > freeValueAccrued` reverts `InsufficientFreeValue`; else `freeValueAccrued -= amount`;
    `emit FreeValueSpent(amount, freeValueAccrued)`. Decrement lands BEFORE the value-moving `_exec`s (a re-entrant spend
    can't double-spend the same budget).
  - Public set-once getters (auto, from `public` storage): `engineSafe` / `operator` / `zipDepositModule` / `usdc` /
    `freeValueAccrued`.
  The operator supplies **only scalars**; the module builds all calldata to the **set-once wired targets**
  (`zipDepositModule`, `usdc`). **No generic call passthrough, no arbitrary token/target, no delegatecall, `value == 0`
  on every `exec`** (§10.1). **No swap** (8-B9 `buyXAlpha`), **no LP/gauge** (8-B6), **no EVC/borrow** (8-B5), **no NAV
  write** (recycle is a realized reinvestment, never a NAV markup — §8 inv. 7 / `auto-sodomizer.md` §7; the module never
  touches `SzipNavOracle`). **No payout, no xALPHA leg, no distributor, no compounder/8-B13 seam** (all removed in the
  single-sink redesign).

- `contracts/test/RecycleModule.t.sol` — unit (recording-mock Safe — exec-shape / approve-reset dance / authority /
  atomicity / the accumulator credit-spend arithmetic + over-spend revert / event assertions, for every entrypoint) +
  an integrated-no-fork pass (a LIVE `RecordingSafe` driving a **real `ZipDepositModule.deposit`** over a real
  capacity-granted `ESynth`, proving the Mode-B-style backed mint + the decrement-before-exec ordering) + a Base-fork
  pass (a **real summoned Gnosis Safe** as the engine Safe, the same rig enabled, proving the Zodiac exec path against
  real Safe bytecode). **19/19 (16 unit + 2 integrated + 1 Base-fork).**

**No interface/address additions.** `ZipDepositModule` is an in-repo contract (a local `IZipDepositModule` interface for
the `deposit(uint256) returns (uint256)` only); `IERC20` resolves through the active OZ remap
(`@openzeppelin/contracts/token/ERC20/IERC20.sol`). `usdc` is a runtime address wired at deploy (our `ESynth`-adjacent
USDC), mocked in unit tests — **no new `BaseAddresses` constant** (parity with 8-B9).

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec, the **8-B10** block: owns the single `freeValueAccrued`
  accumulator (CRE the only writer); `creditFreeValue` (increment, `+= max(0, realized − borrowRepaid)`); the single
  recycle sink = `ZipDepositModule.deposit(usdc)` backed-1:1 mint into the basket → 8-B6 single-sided LP → NAV
  accretion; free-value-only invariant ENFORCED ON-CHAIN (the gate); the recycle is a realized reinvestment, **not** a
  NAV markup; **State = the accumulator + wiring only** (no mode flag, no checkpoints — single sink, single entrypoint).
- `reports/baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one CRE operator = `onlyOperator`, mutate the
  Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via `ModuleProxyFactory`, init in `setUp`
  under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B10** (the recycle description: the free-value-only
  invariant funded only by HYDX-extracted value; what it touches: 8-B9 buy leg / 8-B5 free-value source / `ZipDepositModule`
  / item 2 NAV).
- `pending-docs/auto-sodomizer.md` **§6/§11** (the recycle sink → NAV accretion) **/ §8 inv. 1/2/3/7** (permissioned CRE
  writer; depositor principal never at risk in the dump; free-value-only; trailing-realized not-NAV).
- `pending-docs/treasury.md` **§4.7** (recycle economics — referenced).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation; collateral mocked. (8-B10 reopens nothing — the module is weight/mode-agnostic; the CRE picks
  the timing/size.)

**Model from (VERIFIED against `reference/`, the kept builds, and the repo)**
- **`is Module` + the exec dance — PRIMARY MODEL = `contracts/src/supply/szipUSD/SellModule.sol` (8-B9, closest
  sibling).** Copy verbatim: the header imports (`Module`, `Operation` from `@gnosis-guild/zodiac-core/core/`, `IERC20`
  from `@openzeppelin/contracts/token/ERC20/IERC20.sol`); the `setUp` validate-all-nonzero-FIRST-then-store order-guard
  (validate every decoded address nonzero + `owner != operator` BEFORE any use, set `avatar=target=engineSafe`, store
  wiring, `_transferOwnership` LAST); the `onlyOperator` modifier; the `setAvatar`/`setTarget` "left as onlyOwner, not
  hard-locked" comment; the private `_exec(to,data) returns (bytes)` that bubbles inner revert data via
  `assembly { revert(add(ret,0x20),mload(ret)) }` / `revert ExecFailed()` when empty; the approve-selector pattern
  `abi.encodeWithSelector(IERC20.approve.selector, spender, amount)` then `..., 0`; and `abi.decode(ret,(uint256))` to
  read the deposit's return. **Structural differences vs 8-B9:** (a) the middle `_exec` targets `zipDepositModule` with
  `abi.encodeCall(IZipDepositModule.deposit, (usdcAmount))` — NOT a swap; (b) the module carries **real state**
  (`freeValueAccrued`) and the credit/spend gate — the ONLY engine module that does; (c) no `maxSellHydx`-style cap (the
  spend is bounded by `freeValueAccrued`, not a per-call size).
- **`ZipDepositModule.deposit` — VERIFIED in-repo (`contracts/src/supply/ZipDepositModule.sol:115`):**
  `deposit(uint256 usdcIn) external nonReentrant returns (uint256 zipMinted)` — `safeTransferFrom(msg.sender, this,
  usdcIn)` (so the **Safe must approve** the module first — that is exec #1 of `recycle`), `zipMinted = usdcIn * scaleUp`,
  `IESynth(zipUSD).mint(msg.sender, zipMinted)` (mints backed zipUSD to **msg.sender = the engine Safe**), parks the USDC
  into `eePool` with the `warehouse` Safe as the share receiver. So `recycle`'s exec #2 mints the backed zipUSD **to the
  engine Safe** and routes the USDC to senior backing in one call. `scaleUp = 1e12` (18-dp zipUSD / 6-dp USDC). The local
  `IZipDepositModule` interface needs `deposit(uint256) returns (uint256)` only.
- **CRITICAL clone fact (§18.6, proven on 8-B5..B9/B14).** A `ModuleProxyFactory` clone shares the mastercopy's runtime
  bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp` config. **Every per-clone
  wired address (`engineSafe`, `operator`, `zipDepositModule`, `usdc`) MUST be plain set-once storage written in `setUp`
  under `initializer`, NOT `immutable`.** Init-lock the mastercopy at deploy (test asserts a second `setUp` reverts).
- **Error declarations:** `error NotOperator(); error ZeroAddress(); error OwnerIsOperator(); error ZeroAmount(); error
  InsufficientFreeValue(); error ExecFailed();` (model the block on `SellModule.sol`; drop `ExceedsMaxSell`; add
  `InsufficientFreeValue`).
- **Events:** `event FreeValueCredited(uint256 amount, uint256 newAccrued); event FreeValueSpent(uint256 amount,
  uint256 newAccrued); event Recycled(uint256 usdcAmount, uint256 zipMinted);`. The credit/spent second arg is the
  **post-mutation** running `freeValueAccrued`.

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…06, `SzipNavOracle`, `ExitGate`+`SzipUSD`, `ZipDepositModule`,
8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule`, 8-B6 `LpStrategyModule`, 8-B7 `HarvestVoteModule`,
8-B8 `ExerciseModule`, 8-B9 `SellModule`). zodiac-core `Module` proven by the six built engine modules;
`ZipDepositModule.sol` present + fork-proven. **No engine Safe is summoned in unit tests** — use a **recording mock
Safe** (the `RecordingSafe` in `contracts/test/SellModule.t.sol`: implements `execTransactionFromModule` +
`execTransactionFromModuleReturnData`, records each `(to, value, data, operation)`, `setLive`/`getCall`/`callCount`,
`setFailOnCallIndex` for atomicity, `setReturnData(bytes)` for the deposit-return decode), and a **real Base fork** with
the **real summoned substrate Safe** as the engine Safe for the live `recycle`.

**Do NOT**
- **Do NOT** add a swap, an LP/gauge leg, an EVC `borrow`/`repay`, a veNFT, an oHYDX `exercise`, an oracle read/write, or
  a `maxSellHydx`-style per-call size cap — those are 8-B9/8-B6/8-B5/8-B7/8-B8/`SzipNavOracle`. 8-B10 is the **free-value
  ledger + the deposit-mint** only. The zipUSD→LP single-sided add is **8-B6**, called by the CRE robot **after**
  `recycle`.
- **Do NOT** add a payout leg, an xALPHA transfer, a `SzipRewardsDistributor`, a Merkle root, a claim path, a public
  `spendFreeValue`, a `setCompounder`/`compounder` seam, or any 8-B13 Mode-C hook (all removed in the single-sink
  redesign — holder return is NAV accretion realized on exit at NAV, not a pull-claim).
- **Do NOT** mark up NAV or touch `SzipNavOracle`. `recycle` is value-neutral to NAV at the moment of the call (the
  basket swaps USDC for equal-value backed zipUSD; the EE shares accrue to the warehouse/senior side); the per-share
  accretion comes from the recycled value being net-new to the basket without minting shares (§8 inv. 7 /
  `auto-sodomizer.md` §7).
- **Do NOT** trust the `freeValueAccrued` accumulator as the *backing* guarantee. It is the **policy ceiling** (don't
  spend more than was extracted as free value). The **hard** guarantee is that `recycle`'s deposit leg moves **real**
  USDC out of the Safe (`ZipDepositModule.deposit` does `safeTransferFrom(Safe, ...)`) — if the Safe lacks the balance,
  the `_exec` reverts. So even an over-credited accumulator cannot mint unbacked zipUSD (the deposit pulls real USDC) —
  state this in the security NatSpec.
- **Do NOT** let any non-operator write or spend the accumulator (`creditFreeValue`/`recycle` are both `onlyOperator`).
- **Do NOT** use `immutable` for any wired address (clone fact); **do NOT** add a generic `exec`/`call`/`transfer(arbitrary
  token/target)` passthrough, delegatecall, or non-zero `value`; **do NOT** hard-lock `setAvatar`/`setTarget` (keep them
  zodiac-core `onlyOwner`, matching the siblings).

**Key requirements**
1. **`is Module` on the engine Safe, clone-safe.** Inherit zodiac-core `Module`; `setUp(bytes)` under `initializer`
   decodes **5 addresses** `(address owner, address engineSafe, address operator, address zipDepositModule, address
   usdc)`. Validate **ALL 5 nonzero FIRST** + `owner != operator` (order-guard: a zero address reverts `ZeroAddress`
   deterministically before any use), set `avatar = target = engineSafe`, store the wiring, THEN `_transferOwnership(owner)`.
   No live-read/staticcall in `setUp`. All wiring is **set-once storage, never `immutable`**. The mastercopy is
   init-locked at deploy (test asserts a second `setUp` reverts).
2. **Authority — `onlyOperator` on both action legs.** `creditFreeValue` and `recycle` revert `NotOperator` for any
   non-operator. A non-owner `setAvatar`/`setTarget` reverts; `owner == operator` in `setUp` reverts `OwnerIsOperator`.
3. **The accumulator arithmetic + the gate.** `creditFreeValue(n)` (n>0) sets `freeValueAccrued += n`;
   `_spendFreeValue(a)` reverts `InsufficientFreeValue` if `a > freeValueAccrued`, else `freeValueAccrued -= a`. Tests:
   credit 100 → accrued 100; recycle 60 → accrued 40; recycle 41 → `InsufficientFreeValue` (accrued unchanged at 40,
   `callCount == 0`); recycle 40 → accrued 0; `creditFreeValue(0)`/`recycle(0)` → `ZeroAmount`. **Boundary:** spend ==
   accrued succeeds to exactly 0. Every credit/spend emits its event with the new running `freeValueAccrued`.
4. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** Every Safe mutation routes through the
   private `_exec(to, data) returns (bytes)` using `execAndReturnData(to, 0, data, Operation.Call)`; on `!ok` it bubbles
   the inner revert data (or `ExecFailed` when empty). **`recycle(usdcAmount)`** does exactly three `_exec`s in order
   after `_spendFreeValue(usdcAmount)`: (1) `_exec(usdc, approve(zipDepositModule, usdcAmount))`, (2) `_exec(zipDepositModule,
   deposit(usdcAmount))` → decode `zipMinted = abi.decode(ret,(uint256))`, (3) `_exec(usdc, approve(zipDepositModule, 0))`.
   **Use typed `abi.encodeCall(IZipDepositModule.deposit, (usdcAmount))`** for the deposit (a sig regression fails to
   compile). Tests assert the exact recorded `(to, value==0, data, operation==Call)` tuples on the recording Safe, decode
   the `approve`/`deposit` args (spender == zipDepositModule, amounts correct, reset == 0). Atomicity: a `live` Safe
   returning `(false, customErrorBytes)` makes `recycle` **revert bubbling that data**; `(false, "")` reverts
   `ExecFailed`; and after a reverted `recycle` **`freeValueAccrued` is unchanged** (the atomic rollback covers the
   decrement). A short/empty deposit-return (`setReturnData` < 32 bytes) → `recycle` reverts (the decode must not emit
   garbage).
5. **Free-value-only enforced two-layer (the load-bearing invariant, §8 inv. 3).** (a) **Policy ceiling:** `recycle`
   debits `freeValueAccrued` and reverts if it would go negative → the engine can never *route* more than the
   HYDX-extracted free value. (b) **Hard backing:** the actual USDC moved is pulled from the **Safe's real balance** by
   the deposit `_exec` (`ZipDepositModule.deposit` does `safeTransferFrom(Safe, ...)`) → even an over-credited
   accumulator cannot conjure value (the deposit reverts if the Safe is short). **The zipUSD is backed 1:1 by
   construction** (the deposit parks the USDC as senior backing *before* the mint, inside `ZipDepositModule.deposit`).
   Test: `recycle` over a real fork Safe with real USDC mints exactly `usdcAmount·scaleUp` zipUSD to the Safe AND debits
   `freeValueAccrued` by `usdcAmount`; a `recycle(usdcAmount)` with `usdcAmount > freeValueAccrued` reverts
   `InsufficientFreeValue` before any `_exec`.
6. **`creditFreeValue` is single-arg + operator-trusted; the formula is documented not computed.** The contract does
   `freeValueAccrued += amount` (no on-chain subtraction — `realized`/`borrowRepaid` are historical, off-chain only). A
   doc comment cites the CRE's `max(0, realized − borrowRepaid)` derivation. This discharges the **proceeds + free-value
   hand-off** obligation (8-B9 → 8-B10): the USDC `sellHydx` lands in the Safe net of the 8-B5 repay → the CRE passes
   that net to `creditFreeValue`; 8-B9 does NOT credit.
7. **Decrement-BEFORE-exec ordering — OBSERVABLY pinned.** A test where `recycle`'s decrement landing before the
   value-moving deposit is *observable*, not just "a revert rolls back": a LIVE `RecordingSafe` whose deposit target is a
   `MockZipDepositModule` that, inside `deposit()`, staticcalls back `module.freeValueAccrued()` and records it; after
   `recycle(u)` over `creditFreeValue(seed)`, assert the recorded mid-call value `== seed − u` (the spend was already
   applied at exec #2 time). The plain rollback test CANNOT distinguish decrement-before from decrement-after, so this
   read-back test is REQUIRED. (Reentrancy posture: the module does NOT inherit OZ `ReentrancyGuard` — a clone never
   runs the guard's constructor, and the siblings avoid it; safety is effects-before-interaction + the set-once trusted
   wired targets + `ZipDepositModule`'s own `nonReentrant`.)

**Done when**
- `forge build` green; `forge test --match-path test/RecycleModule.t.sol` green (unit + integrated); `forge test
  --fork-url $BASE_RPC_URL --match-path test/RecycleModule.t.sol` green (adds the Base-fork pass); **no regression** on
  the full suite (`forge test --fork-url $BASE_RPC_URL`, **401/401**).
- **Module unit (RecordingSafe + MockZipDepositModule + MockERC20):**
  (a) **exec-shape, fully pinned** — `recycle(u)`: exactly three recorded calls `(usdc, 0, approve(zipDepositModule, u),
  Call)`, `(zipDepositModule, 0, deposit(u), Call)`, `(usdc, 0, approve(zipDepositModule, 0), Call)`; decode each; the
  mock-returned `zipMinted` → assert `emit Recycled(u, zipMinted)` + the function return. **For EVERY recorded call
  assert `value == 0` AND `operation == uint8(Operation.Call)`.** (b) **accumulator arithmetic + the gate** — the full
  sequence in KR3 (credit/recycle/boundary/over-spend revert leaves accrued unchanged/zero-amount reverts), with the
  running `freeValueAccrued` getter asserted after each + the events; a multi-credit accumulation (`creditFreeValue(100)`
  → `(150)` running total + events). A `recycle(u)` with `u > freeValueAccrued` reverts `InsufficientFreeValue` **before**
  any recorded `_exec` (assert `callCount == 0`). (c) **malformed deposit return** — `MockZipDepositModule`/`setReturnData`
  < 32 bytes → `recycle` reverts. (d) authority — `creditFreeValue`/`recycle` each revert `NotOperator` for a
  non-operator; `setAvatar`/`setTarget` revert for a non-owner; `owner == operator` setUp reverts `OwnerIsOperator`; the
  **un-setUp mastercopy** is inert (`creditFreeValue` reverts `NotOperator`, every getter 0). (e) atomicity — a `live`
  target returning `(false, customErrorBytes)` makes `recycle` revert bubbling that data; `(false, "")` reverts
  `ExecFailed`; **after a reverted `recycle`, `freeValueAccrued` is unchanged** (atomic rollback of the decrement). (f)
  clone/init — a second `setUp` reverts; a zero in **each** of the 5 addresses reverts `ZeroAddress` (assert the selector
  is `RecycleModule.ZeroAddress`); an abi-length-mismatch `setUp` payload reverts. (g) **getters** — each wired getter
  returns its address.
- **Module integrated/fork (real `ZipDepositModule`):** model `contracts/test/ZipDepositModule.t.sol`'s fork-free
  real-deposit rig — `ESynth zip = new ESynth(address(evc), "Zipcode USD", "zipUSD")` (18-dp), a `ConfigurableERC20` 6-dp
  USDC mock, a **par `MockEulerEarn`**, a `WAREHOUSE_SAFE` test address, `new ZipDepositModule(address(zip), address(usdc),
  address(ee), WAREHOUSE_SAFE)`, and **`zip.setCapacity(address(module), type(uint128).max)`** (no fork needed for the
  deposit deps). **MUST be real:** the `RecycleModule` under test drives a **real `ZipDepositModule.deposit`** over a
  **real `ESynth`** (capacity-granted) so the backed mint is genuinely exercised. **MAY be mocked:** USDC + the EE pool
  (re-proving EE/USDC is WOOF-06's job). **Pin `scaleUp == 1e12`** and assert the Safe's zipUSD delta is **exactly
  `amount * 1e12`**, USDC delta exactly `−amount`, `freeValueAccrued` delta exactly `−amount`, and the post-call
  `usdc.allowance(safe, zipDepositModule) == 0` (reset). **Two integrated passes:** (i) a **no-fork integrated UNIT**
  test with a LIVE `RecordingSafe` as the engine Safe driving the real `ZipDepositModule` rig (the full value flow + the
  KR7 ordering read-back); (ii) a **Base-fork** test with a **real summoned Gnosis Safe** (`SummonSubstrate._summon`,
  model `SellModule.t.sol`'s `_summonAndEnable`) as the engine Safe, the same rig enabled, proving the Zodiac exec path
  against real Safe bytecode. USDC is the rig's `ConfigurableERC20` mock, so no `deal`/whale problem.
- **Mapped to the integration layer:** the per-epoch recycle belongs in the **deferred engine-integration audit sweep**
  (`audit/2.md` Phase L + `audit/3-results.md` authority rows), authored once the engine is integration-testable
  alongside item-10 — logged as an obligation, NOT in this window (matches the 8-B5..B9/Exit-Gate sweeps).

**Depends on**
- **8-B1** (the summoned engine Safe substrate — `SummonSubstrate._summon`, `contracts/script/SummonSubstrate.s.sol`),
  **8-B9** (`SellModule.sol` — the primary `is Module`/`_exec`/setUp-order-guard model + the `RecordingSafe`/`MockERC20`
  test harness), and **WOOF-06** (`ZipDepositModule.sol` — the real backed-mint target). **The cold-builder MUST open
  these to reuse the harness:** `contracts/test/SellModule.t.sol` (the `RecordingSafe` with `setLive`/`setFailOnCallIndex`/
  `getCall`/`callCount`/`setReturnData` and the `_summonAndEnable` fork pattern) + `contracts/test/ZipDepositModule.t.sol`
  (the fork-free real-deposit rig) + `ZipDepositModule.sol` (the `deposit(uint256) returns (uint256)` signature + the
  `safeTransferFrom(msg.sender,...)` pull that dictates the approve-first exec order).
- **Feeds:** 8-B6 (the single-sided LP add the CRE sequences after `recycle`), 8-B5 (the free-value source the CRE nets
  and passes to `creditFreeValue`), 8-B9 (the sell the CRE nets into the credit), 8-B11 (the CRE robot that sizes amounts
  within `freeValueAccrued` and sequences sell→repay→credit→recycle→LP), 8-B12 (monitoring: trailing-realized APR off the
  realized recycle), item 2 NAV (the undistributed free value marked as accrued proceeds until `recycle` moves it into
  the basket as backed zipUSD).

---

**Inbound cross-ticket obligations DISCHARGED by this ticket** (marked in `PROGRESS.md`):
- **8-B10 · proceeds + free-value hand-off (8-B9 → 8-B10)** (owed by 8-B9): `creditFreeValue(uint256 amount)` is the
  owned accumulator's only increment, single-arg, operator-trusted, `+= max(0, realized − borrowRepaid)` computed
  off-chain. **DISCHARGED** — KR6; 8-B9 does NOT credit free value.
- **8-B10 · 8-B6 backed-zipUSD invariant** (owed by 8-B6): the zipUSD leg of any `LpStrategyModule.addLiquidity` MUST be
  **backed** (minted only via 8-B10's free-value path / the §4.5 zap), never unbacked. **DISCHARGED (mechanism side)** —
  8-B10's `recycle` mints zipUSD **only** through `ZipDepositModule.deposit` (USDC parked as senior backing *before* the
  mint ⇒ backed 1:1 by construction; KR5); the module never calls `ESynth.mint` directly. The CRE funds the Safe before
  calling (the wiring/sequencing half stays an 8-B11/item-10 obligation).

**New cross-ticket obligations this ticket CREATES** (recorded in `PROGRESS.md`):
- **Item 10 / 8-B11 — operator + token wiring (8-B10):** wire the single CRE operator as `operator`; wire
  `zipDepositModule` to the deployed WOOF-06 module, `usdc` to the live token; **deploy the module clone via
  `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe) + init-lock the mastercopy** (the
  8-B5/8-B8/8-B9/8-B14 pattern). 8-B11 sizes the recycle amount within `freeValueAccrued` and sequences
  sell→repay→`creditFreeValue(net)`→`recycle`→8-B6 single-sided add per epoch.
- **Item 10 / engine-integration audit sweep (8-B10):** author the per-epoch recycle into `audit/2.md` Phase L (an
  L-step: 8-B9 sell → 8-B5 repay → `creditFreeValue(net)` → `recycle` → 8-B6 single-sided LP, with
  USDC/zipUSD/`freeValueAccrued` moving; N-steps: non-operator / over-spend (`InsufficientFreeValue`) / zero-amount each
  revert) + the matching `audit/3-results.md` authority rows (operator-only action legs; `setAvatar`/`setTarget`
  owner-locked; no NAV write; recycle realized not marked). Author once the engine is integration-testable (with
  8-B11 + item-10), like the 8-B5..B9/Exit-Gate sweeps.
- **Item 10 / 8-B12 — NAV must count Safe balance XOR the accumulator (8-B10):** the free-value USDC sits in the engine
  Safe (counted in NAV as "accrued undistributed proceeds", §3/8-B12) until `recycle` moves it into the basket as backed
  zipUSD. `SzipNavOracle` + 8-B12 MUST value the Safe's **real token balances** and **never separately add**
  `freeValueAccrued` — otherwise the same dollars count twice. 8-B10 never writes NAV; verify in the integration sweep.
- **8-B11 / CRE §8 — `creditFreeValue` net computation (8-B10):** the CRE computes `max(0, realized − borrowRepaid)`
  off-chain from the 8-B9 sell proceeds and the 8-B5 `debtOf`/repay receipts for that loop and passes the single net to
  `creditFreeValue`; the module trusts it (it cannot reconstruct historical realized/repaid on-chain).
