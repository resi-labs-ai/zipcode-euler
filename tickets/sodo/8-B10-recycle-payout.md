> **SUPERSEDED 2026-06-08 (user-directed single-sink redesign) — this ticket describes the retired
> `RecyclePayoutModule`.** 8-B10 is now `RecycleModule` with ONE action: `recycle(usdc)` = `_spendFreeValue` →
> `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the
> MAIN-Safe basket** (no `gate.depositFor`, no shares); 8-B6 single-sides it into the gauge-staked LP → NAV
> accretion for every holder. **DELETED:** `payoutClean`/`payoutBoost`/public `spendFreeValue`/`setCompounder`/
> `xAlpha`/`distributor`/`compounder` + the entire `SzipRewardsDistributor`. **8-B13 removed** (absorbed here).
> Current truth = the code (`contracts/src/supply/szipUSD/RecycleModule.sol` + `test/RecycleModule.t.sol`, 19/19) +
> `claude-zipcode.md §4.5.1` + `reports/8-B10-report.md`. The body below is retained only as design rationale.

# 8-B10 — Recycle / payout module (the engine's free-value accumulator + Mode A/B routing) + the pull-claim distributor

> **NEXT / build-only.** The seventh harvest-loop engine module (after 8-B14 buy-and-burn, 8-B5 reservoir-loop, 8-B6
> LP-strategy, 8-B7 harvest-vote, 8-B8 exercise, 8-B9 sell). It owns the **free-value ledger** of the auto-sodomizer:
> the single `freeValueAccrued` accumulator (no other module writes it) plus the two *distribute* sinks — **Mode A
> (clean USDC pro-rata to szipUSD holders)** and **Mode B (boosted xALPHA recycle loop)**. The *reinvest* sink (Mode
> C) is 8-B13 (TODO); it spends this module's accumulator through the same gate. Internal engine plumbing → **build-only**
> (no INFLOW ticket; the 8-B11 CRE strategy robot drives the entrypoints; the holder-facing claim UI is folded into the
> 8-B12 dashboard / a later INFLOW pass, logged below). It is a **close sibling of `SellModule` (8-B9) and
> `ExerciseModule` (8-B8)** — same `is Module` + `setUp(bytes)`-under-`initializer` + `onlyOperator` + `exec(...,
> Operation.Call)` + the `_exec`-that-bubbles dance — but instead of a swap it drives the **`ZipDepositModule.deposit`
> backed-mint** (Mode B) and **Safe→distributor transfers** (the payout legs), and it adds the **one piece of real
> on-chain state in the engine**: the `freeValueAccrued` accumulator and its credit/spend gate (§8 inv. 3).

**Deliverable**
Two new contracts under the supply tree + their two test files:

- `contracts/src/supply/szipUSD/RecyclePayoutModule.sol` — `contract RecyclePayoutModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine
  Safe** (`avatar == target == engineSafe`). It mutates the Safe **only** via the inherited `execAndReturnData(to, 0,
  data, Operation.Call)` through a private `_exec`-that-bubbles (copied from `SellModule._exec`). **The owned state =
  one `uint256 freeValueAccrued`** (the engine's free-value ledger; §8 inv. 3) plus the set-once wiring. Surface:
  - **`creditFreeValue(uint256 netFreeValueUsdc)`** — `onlyOperator`. `freeValueAccrued += netFreeValueUsdc`;
    `emit FreeValueCredited(netFreeValueUsdc, freeValueAccrued)`. Called by the CRE robot after 8-B9 sweeps a fill and
    8-B5 repays the strike-borrow: the operand is the USDC realized **net of** the borrow repaid (principal + interest)
    for that loop, i.e. the CRE passes `max(0, realized − borrowRepaid)` (only the HYDX sold above the ~30% strike is
    free value). **Single arg, operator-trusted** — the module cannot reconstruct `realized`/`borrowRepaid` on-chain
    (historical), exactly as every sibling trusts the single immutable CRE operator to size scalars (§17). `0` reverts
    `ZeroAmount`. (The accumulator is a POLICY ceiling on spend; the HARD backing guarantee is the real USDC
    `safeTransferFrom` the deposit/transfer legs do from the Safe — see Key requirement 6.)
  - **`spendFreeValue(uint256 amount)`** — `onlyOperatorOrCompounder`. The **decrement primitive** 8-B13 (Mode C)
    calls: revert `InsufficientFreeValue` if `amount > freeValueAccrued`, else `freeValueAccrued -= amount`;
    `emit FreeValueSpent(amount, freeValueAccrued)`. It moves **no tokens** — it is the accounting gate; the caller
    (8-B13) does the deposit/mint/LP with that budget. Internally, the Mode-A/B legs below debit through the **same
    private `_spendFreeValue(amount)`** (check + decrement + event), so there is one debit path.
  - **`recycleModeB(uint256 usdcAmount) returns (uint256 zipMinted)`** — `onlyOperator` [Mode B leg 1]. `_spendFreeValue(
    usdcAmount)`; then drive the Safe through three `_exec`s: (1) `usdc.approve(zipDepositModule, usdcAmount)`, (2)
    `zipDepositModule.deposit(usdcAmount)` — mints `usdcAmount·scaleUp` **backed** zipUSD to the Safe (the deposit
    parks the USDC into the venue pool with the warehouse Safe as the EE-share receiver → senior backing AND lending
    capacity), decode the returned `zipMinted`, (3) `usdc.approve(zipDepositModule, 0)` (reset — no standing approval).
    `emit RecycledModeB(usdcAmount, zipMinted)`. **This is the only free-value debit of a Mode-B pass** — the downstream
    zipUSD→xALPHA swap is 8-B9 `buyXAlpha` and the boost distribution is `payoutBoost` (no second debit; the value was
    already debited here as USDC).
  - **`payoutClean(uint256 usdcAmount)`** — `onlyOperator` [Mode A]. `_spendFreeValue(usdcAmount)`; drive the Safe to
    `usdc.transfer(distributor, usdcAmount)` (one `_exec`); `emit PaidOut(usdc, usdcAmount)`. Funds the pull-claim
    distributor with USDC; the CRE separately posts the per-holder cumulative Merkle root on the distributor.
  - **`payoutBoost(uint256 xAlphaAmount)`** — `onlyOperator` [Mode B leg 3]. Drive the Safe to `xAlpha.transfer(
    distributor, xAlphaAmount)` (one `_exec`); `emit PaidOut(xAlpha, xAlphaAmount)`. **NO free-value debit** (the value
    was debited at `recycleModeB`; the xALPHA in the Safe is the swap output of already-debited free value). Funds the
    distributor with the boost xALPHA.
  - **`setCompounder(address compounder_)`** — `onlyOwner` (Timelock), **set-once** (revert `AlreadyWired` if nonzero,
    `ZeroAddress` if zero). Wires the 8-B13 module (built later) as the second authorized caller of `spendFreeValue`.
    Zero until wired ⇒ only the operator can spend. `emit CompounderWired(compounder_)`.
  - Public set-once getters: `engineSafe`/`operator`/`zipDepositModule`/`usdc`/`xAlpha`/`distributor`/`compounder`/
    `freeValueAccrued`.
  The operator supplies **only scalars**; the module builds all calldata to the **set-once wired targets**
  (`zipDepositModule`, `usdc`, `xAlpha`, `distributor`). **No generic call passthrough, no arbitrary token/target, no
  delegatecall, `value == 0` on every `exec`** (§10.1). **No swap** (8-B9 `buyXAlpha`), **no LP/gauge** (8-B6/8-B13),
  **no EVC/borrow** (8-B5), **no NAV write** (payouts are realized distributions, never NAV markups — §8 inv. 7 / `auto-
  sodomizer.md` §7; the module never touches `SzipNavOracle`).

- `contracts/src/supply/szipUSD/SzipRewardsDistributor.sol` — `contract SzipRewardsDistributor` (plain `Ownable` +
  `ReentrancyGuard`, NOT a Zodiac module). The **pull-claim distributor** the Mode A/B legs fund. A **multi-asset Merkle
  cumulative-claim** distributor, clean-room-modeled on `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol`
  (`_claim` leaf + cumulative semantics, `:159-191`; the leaf line is `:161`):
  - `mapping(address asset => bytes32) public merkleRoot;` and `mapping(address asset => mapping(address account =>
    uint256)) public claimed;` — per-asset root + per-asset per-holder cumulative-claimed.
  - `address public rootPoster;` (the CRE operator — set at deploy) and `owner` (the Timelock — `Ownable`).
  - **`setRoot(address asset, bytes32 newRoot)`** — `onlyRootPoster`. `emit RootUpdated(asset, oldRoot, newRoot)`.
  - **`claim(address asset, address account, uint256 cumulativeAmount, bytes32[] calldata proof)`** — `nonReentrant`,
    permissionless. Leaf `= keccak256(bytes.concat(keccak256(abi.encode(account, cumulativeAmount))))` (the OZ-standard
    double-hash leaf, verbatim from the reference `:181`); `MerkleProof.verify(proof, merkleRoot[asset], leaf)` else
    `InvalidProof`; `amount = cumulativeAmount − claimed[asset][account]`, revert `NothingToClaim` if `cumulativeAmount
    <= claimed[asset][account]`; set `claimed[asset][account] = cumulativeAmount` (effects before interaction);
    `IERC20(asset).safeTransfer(account, amount)`; `emit Claimed(asset, account, amount, cumulativeAmount)`.
  - **`claimMultiple(address asset, address[] accounts, uint256[] cumulativeAmounts, bytes32[][] proofs)`** — the batch
    convenience (model `:141`), `LengthMismatch` guard, loops `_claim`.
  - **`setRootPoster(address newPoster)`** — `onlyOwner` (rotation/recovery), `ZeroAddress` guard, `emit RootPosterSet`.
  - View `getClaimable(address asset, address account, uint256 cumulativeAmount, bytes32[] calldata proof) returns
    (uint256)` — verifies the proof, returns `cumulativeAmount > claimed ? cumulativeAmount − claimed : 0` (the
    frontend back-pressure read). Plus the public `claimed`/`merkleRoot` mappings.
  - **NO `maxClaimable`/`totalClaimed`/`epochEmissions`/`useMint` bookkeeping** (reference `:46-54`): the held
    `IERC20(asset).balanceOf(this)` IS the cap — a claim transfers the full `amount` via `safeTransfer`, which **reverts
    if the distributor is underfunded** (the funding-precedes-claim invariant the CRE maintains; a `mint` path is
    irrelevant — we distribute USDC/xALPHA the module funded, never a mintable token). A mis-posted root can mis-split
    among holders but cannot create value beyond the funded balance (single-trusted-operator model, §17).

- `contracts/test/RecyclePayoutModule.t.sol` — unit (recording-mock Safe — exec-shape / approve-reset dance /
  authority / atomicity / the accumulator credit-spend arithmetic + over-spend revert / event assertions, for every
  entrypoint) + fork (live Base: a **real `ZipDepositModule.deposit`** through a real summoned substrate Safe, proving
  Mode-B end-to-end mints backed zipUSD to the Safe and debits `freeValueAccrued`; plus a real Safe→distributor USDC
  `transfer` for `payoutClean`).
- `contracts/test/SzipRewardsDistributor.t.sol` — unit: build a small Merkle tree in-test (OZ-standard double-hash
  leaves), prove `claim` pays `cumulative − claimed`, a second claim against the same root reverts `NothingToClaim`, a
  root *bump* (new cumulative) pays only the delta, a wrong proof reverts `InvalidProof`, per-asset isolation (USDC vs
  xALPHA roots independent), `setRoot` authority (`onlyRootPoster`), `setRootPoster` authority (`onlyOwner`), an
  underfunded claim reverts (the `safeTransfer`), and `claimMultiple` length-mismatch + happy path.

**No interface/address additions.** `ZipDepositModule` is an in-repo contract (a local `IZipDepositModule` interface for
the `deposit(uint256) returns (uint256)` + `usdc()`/`scaleUp()` getters); `MerkleProof`/`Ownable`/`ReentrancyGuard`/
`IERC20`/`SafeERC20` all resolve through the active OZ remap (`@openzeppelin/contracts/...`, verified:
`utils/cryptography/MerkleProof.sol` exists under `reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/`).
`usdc`/`xAlpha` are runtime addresses wired at deploy (our `ESynth`-adjacent USDC + the bridge stand-in), mocked in
unit tests — **no new `BaseAddresses` constant** (parity with 8-B9, which added none for `zipUSD`/`xAlpha`).

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec, the **8-B10** block (just spec-fixed this window —
  see the two fixes below): owns the single `freeValueAccrued` accumulator (CRE the only writer); two mutators
  `creditFreeValue` (increment, `+= max(0, realized − borrowRepaid)`) and the decrement gate (revert if spend >
  accrued); **Mode A** = distribute net USDC pro-rata to **szipUSD holders** (corrected from "Loot holders") via a
  pull-claim `RewardsDistributor`-shape distributor; **Mode B** = `ZipDepositModule.deposit(usdc)` (backed-1:1 mint) →
  8-B9 `buyXAlpha` swap → distribute xALPHA "+30% boost"; the reinvest/compound sink is **Mode C = 8-B13**;
  free-value-only invariant ENFORCED ON-CHAIN (the gate); payouts are realized distributions, **not** NAV markups;
  **State = the accumulator + wiring only, mode selection is CRE policy (entrypoint choice), not an on-chain flag, and
  the distribution checkpoints live in the distributor** (corrected from "payout-mode flag; distribution checkpoints"
  this window).
- `baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one CRE operator = `onlyOperator`, mutate
  the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via `ModuleProxyFactory`, init in
  `setUp` under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B10** (the recycle/payout description: Mode A
  clean USDC / Mode B boosted xALPHA loop; the free-value-only invariant funded only by HYDX-extracted value; what it
  touches: 8-B9 buy leg, 8-B5 free-value source, 8-B13 Mode C, `ZipDepositModule`, item 2 NAV).
- `pending-docs/auto-sodomizer.md` **§6** (the three payout modes — Mode A "pro-rata to szipUSD shares", Mode B
  boosted xALPHA loop with the load-bearing free-value-only invariant §8 inv. 3, Mode C compound) **/ §8 inv. 1/2/3/7**
  (permissioned CRE writer; depositor principal never at risk in the dump; free-value-only; trailing-realized
  not-NAV) **/ §11.2** (the Treasury-owned A/B/C allocation policy — weight-agnostic mechanism, numbers deferred).
- `pending-docs/treasury.md` **§4.7** (Mode B boost economics — referenced; the boost is reflexive + time-limited).
- `claude-zipcode.md` **§3 / §4.6** (the `RewardsDistributor`-shape pull-claim distributor reference, the §3 reference
  table row "Pro-rata in-kind bonus distribution → `RewardsDistributor :: claim/claimMultiple`",
  `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol`, concept-only/clean-room).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation; collateral mocked; **the A/B/C mode split is Treasury policy, NOT a contract constant**.
  (8-B10 reopens nothing — the module is weight/mode-agnostic; the CRE picks the entrypoint.)

**Model from (VERIFIED against `reference/`, the kept builds, and the repo this window — not cited blind)**
- **`is Module` + the exec dance — PRIMARY MODEL = `contracts/src/supply/szipUSD/SellModule.sol` (8-B9, the closest
  sibling).** Copy verbatim: the header imports (`Module`, `Operation` from `@gnosis-guild/zodiac-core/core/`, `IERC20`
  from `@openzeppelin/contracts/token/ERC20/IERC20.sol` — `SellModule.sol:4-7`); the `setUp` validate-all-nonzero-FIRST-
  then-store order-guard (`SellModule.sol:87-126` — validate every decoded address nonzero + `owner != operator` BEFORE
  any use, set `avatar=target=engineSafe`, store wiring, `_transferOwnership` LAST); the `onlyOperator` modifier
  (`:138-141`); the `setAvatar`/`setTarget` "left as onlyOwner, not hard-locked" comment (`:143-146`); the private
  `_exec(to,data) returns (bytes)` that bubbles inner revert data via `assembly { revert(add(ret,0x20),mload(ret)) }` /
  `revert ExecFailed()` when empty (`:184-193`); the approve-selector pattern `abi.encodeWithSelector(IERC20.approve.
  selector, spender, amount)` then `..., 0` (`:210,229`); and `abi.decode(ret,(uint256))` to read a call's return
  (`:231`). **Structural differences vs 8-B9:** (a) the middle `_exec` targets `zipDepositModule` with
  `abi.encodeCall(IZipDepositModule.deposit, (usdcAmount))` (Mode B) or is a plain `IERC20.transfer` to the distributor
  (the payout legs) — NOT a swap; (b) the module carries **real state** (`freeValueAccrued`) and the credit/spend gate —
  the ONLY engine module that does (every other is stateless beyond wiring); (c) two authorized callers for
  `spendFreeValue` (operator + the set-once compounder) via an `onlyOperatorOrCompounder` modifier; (d) no `maxSellHydx`-
  style cap (the spend is bounded by `freeValueAccrued`, not a per-call size).
- **`ZipDepositModule.deposit` — VERIFIED in-repo (`contracts/src/supply/ZipDepositModule.sol:115-123`):**
  `deposit(uint256 usdcIn) external nonReentrant returns (uint256 zipMinted)` — `safeTransferFrom(msg.sender, this,
  usdcIn)` (so the **Safe must approve** the module first — that is exec #1 of `recycleModeB`), `zipMinted = usdcIn *
  scaleUp`, `IESynth(zipUSD).mint(msg.sender, zipMinted)` (mints backed zipUSD to **msg.sender = the engine Safe**),
  parks the USDC into `eePool` with the `warehouse` Safe as the share receiver. So `recycleModeB`'s exec #2 mints the
  backed zipUSD **to the engine Safe** and routes the USDC to senior backing in one call — exactly the §4.5.1 Mode-B leg.
  `scaleUp = 1e12` (18-dp zipUSD / 6-dp USDC). The local `IZipDepositModule` interface needs `deposit(uint256) returns
  (uint256)` (+ `usdc()`/`scaleUp()` getters only if an assertion uses them — optional).
- **The pull-claim distributor — MODEL = `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol` (clean-room
  CONCEPT only, MIT but treat as concept per the §3 "concept only" marking).** Copy the leaf + cumulative semantics
  (`_claim` `:159-191`, leaf at `:161`): `leaf = keccak256(bytes.concat(keccak256(abi.encode(user, totalAllocation))))`, `MerkleProof.
  verify(proof, root, leaf)`, `claimable = totalAllocation − claimed[user]`, `NothingToClaim` if `<=`, set
  `claimed[user] = totalAllocation`, transfer. **Adapt:** make it **per-asset** (`merkleRoot[asset]`, `claimed[asset]
  [user]`) so one distributor serves USDC + xALPHA; **drop** the `maxClaimable`/`totalClaimed`/`epochEmissions`/`useMint`/
  `START`/`EPOCH` machinery (the held balance is the cap; we never mint); **rename** `updateRoot`→`setRoot(asset,...)`,
  owner-posts→`rootPoster`-posts. `MerkleProof` import = `@openzeppelin/contracts/utils/cryptography/MerkleProof.sol`
  (verified present under the active remap). `Ownable`/`ReentrancyGuard`/`SafeERC20`/`IERC20` from `@openzeppelin/
  contracts/...` (the `ZipDepositModule.sol:4-7` import paths).
- **CRITICAL clone fact (§18.6, proven on 8-B5..B9/B14).** A `ModuleProxyFactory` clone shares the mastercopy's runtime
  bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp` config. **Every
  per-clone wired address (`engineSafe`, `operator`, `zipDepositModule`, `usdc`, `xAlpha`, `distributor`) MUST be plain
  set-once storage written in `setUp` under `initializer`, NOT `immutable`.** Init-lock the mastercopy at deploy (test
  asserts a second `setUp` reverts). **(The `SzipRewardsDistributor` is NOT a clone — it is a normally-constructed
  `Ownable`, so its wiring CAN be `immutable`/constructor args; only the module is clone-constrained.)**
- **Error declarations (module):** `error NotOperator(); error NotOperatorOrCompounder(); error ZeroAddress(); error
  OwnerIsOperator(); error ZeroAmount(); error InsufficientFreeValue(); error AlreadyWired(); error ExecFailed();`
  (model the block on `SellModule.sol:64-72`; **drop** `ExceedsMaxSell`; **add** `NotOperatorOrCompounder`,
  `InsufficientFreeValue`, `AlreadyWired`). **Distributor:** `error InvalidProof(); error NothingToClaim(); error
  LengthMismatch(); error ZeroAddress();`.

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…05, `SzipNavOracle`, `ExitGate`+`SzipUSD`, `ZipDepositModule`,
8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule`+`SzipReservoirLpOracle`+`ReservoirBorrowGuard`+
`ReservoirMarketDeployer`, 8-B6 `LpStrategyModule`, 8-B7 `HarvestVoteModule`, 8-B8 `ExerciseModule`, 8-B9 `SellModule`).
zodiac-core `Module` proven by the six built engine modules; `ZipDepositModule.sol` present + fork-proven.
`contracts/src/supply/szipUSD/` exists. `IERC20`/`SafeERC20`/`Ownable`/`ReentrancyGuard`/`MerkleProof` resolve via
`@openzeppelin/contracts/...`. **No engine Safe is summoned in unit tests** — use a **recording mock Safe** (the
`RecordingSafe` in `contracts/test/SellModule.t.sol` / `ExerciseModule.t.sol`: implements `execTransactionFromModule` +
`execTransactionFromModuleReturnData`, records each `(to, value, data, operation)`, `setLive`/`getCall`/`callCount`,
`setFailOnCallIndex` for atomicity, `setReturnData(bytes)` for the deposit-return decode — `_record` returns `(true,
_returnData)` on every non-live call) for validation/authority/exec-shape, and a **real Base fork** with the **real
summoned substrate Safe** (`SummonSubstrate._summon`, model `SellModule.t.sol`'s `_summonAndEnable`) as the engine Safe
for the live `recycleModeB`/`payoutClean`.

**Test-harness extensions to author (build them in the test file):**
- **`RecordingSafe` return-data (the `zipMinted` decode).** Reuse the 8-B9/8-B8 `RecordingSafe` **verbatim** — its
  non-live `_record` returns `(true, _returnData)` for **EVERY** call. So `setReturnData(abi.encode(uint256
  expectedZip))`, then `recycleModeB(usdcAmount)` — the module decodes the **2nd** exec's return (the `deposit` call) as
  `zipMinted` and ignores the 1st/3rd `approve` returns. Assert `emit RecycledModeB(usdcAmount, expectedZip)` + the
  function return. ALSO a **short/empty return-data** case (`setReturnData` < 32 bytes) → `recycleModeB` **reverts** (the
  decode must not emit garbage).
- **Target mocks** (the `_exec` targets; the model files have analogs to copy): a **`MockZipDepositModule`** whose
  `deposit(uint256) returns (uint256)` records the `usdcAmount` it received and returns a settable `zipMinted` (for the
  Mode-B exec-shape + decode); a **`MockERC20`** as the wired `usdc`/`xAlpha` (for the approve-shape + the
  state-moving `payoutClean`/`payoutBoost` transfer-to-distributor assertions); a plain address as the `distributor` for
  the recording-Safe exec-shape, and the real `SzipRewardsDistributor` for an integrated unit pass (fund → claim).
- **A `live`-Safe atomicity case:** a target returning `(false, customErrorBytes)` through a `live` Safe so the `_exec`
  assembly-bubble is exercised, plus a `(false, "")` case asserting `ExecFailed`. **Crucially**, assert that on a Mode-B
  `_exec` revert the `freeValueAccrued` **stays decremented-then-rolled-back** with the atomic tx — i.e. after a reverted
  `recycleModeB` the accumulator is **unchanged** (the decrement and the failed deposit are one atomic tx; a revert rolls
  back the `_spendFreeValue` too).

**Do NOT**
- **Do NOT** add a swap, an LP/gauge leg, an EVC `borrow`/`repay`, a veNFT, an oHYDX `exercise`, an oracle read/write,
  or a `maxSellHydx`-style per-call size cap — those are 8-B9/8-B6/8-B5/8-B7/8-B8/`SzipNavOracle`. 8-B10 is the
  **free-value ledger + the deposit-mint/transfer routing** only. The zipUSD→xALPHA swap is **8-B9 `buyXAlpha`**, called
  by the CRE robot **after** `recycleModeB` (the zipUSD is in the Safe; the swap mechanism + its `minOut` are 8-B9's).
- **Do NOT** put the **mode selection** (A/B/C) or the **allocation weights** in the contract. Mode = which entrypoint
  the CRE calls (`recycleModeB`/`payoutClean`/8-B13 `compound`); the A/B/C split is Treasury-owned CRE policy (§11.2,
  weight-agnostic — the numbers are open, deferred to `treasury.md`). **No `payoutMode` enum/flag, no weight storage,
  no taper schedule on-chain** (the §4.5.1 8-B10 "State" line was fixed this window to drop the "payout-mode flag").
- **Do NOT** mark up NAV or touch `SzipNavOracle`. Payouts are **realized distributions** (the value leaves the basket
  to the distributor; the holder gets a claim) — never a NAV markup (§8 inv. 7 / `auto-sodomizer.md` §7). The
  free-value USDC sits in the engine Safe (counted in NAV as "accrued undistributed proceeds", §3/8-B12) until a payout
  leg moves it out — value-neutral to the holder (NAV down, claim up). `recycleModeB` is itself value-neutral to NAV
  (the basket swaps USDC for equal-value backed zipUSD; the EE shares accrue to the warehouse/senior side).
- **Do NOT** trust the `freeValueAccrued` accumulator as the *backing* guarantee. It is the **policy ceiling** (don't
  spend more than was extracted as free value). The **hard** guarantee is that every spend leg moves **real** USDC/
  xALPHA out of the Safe (`ZipDepositModule.deposit` does `safeTransferFrom(Safe, ...)`; `payout*` does
  `transfer(distributor, ...)`) — if the Safe lacks the balance, the `_exec` reverts. So even an over-credited
  accumulator cannot mint unbacked zipUSD (the deposit pulls real USDC) — state this in the security section.
- **Do NOT** let any non-operator write the accumulator; **do NOT** let `spendFreeValue` be called by anyone but the
  operator or the set-once compounder; **do NOT** make `setCompounder` re-settable (set-once, owner-gated — an
  attacker-set compounder could drain the spend gate; though the spend itself moves no tokens, it would corrupt the
  free-value ledger).
- **Do NOT** use `immutable` for any wired address in the **module** (clone fact); **do NOT** add a generic
  `exec`/`call`/`transfer(arbitrary token/target)` passthrough, delegatecall, or non-zero `value`; **do NOT** hard-lock
  `setAvatar`/`setTarget` (keep them zodiac-core `onlyOwner`, matching the siblings).
- **Distributor — Do NOT** add `maxClaimable`/`totalClaimed`/`epochEmissions`/`useMint`/`mint`-on-claim/`START`/`EPOCH`
  (the held balance is the cap; we distribute funded USDC/xALPHA, never a mintable token). **Do NOT** make `claim`
  permissioned (anyone can claim FOR a holder — the proof + cumulative bind the payout to `account`, funds go to
  `account`; a third-party claim just pays the rightful holder). **Effects-before-interaction** in `_claim` (set
  `claimed` before `safeTransfer`) + `nonReentrant`.

**Key requirements**
1. **`is Module` on the engine Safe, clone-safe.** Inherit zodiac-core `Module`; `setUp(bytes)` under `initializer`
   decodes **7 addresses** `(address owner, address engineSafe, address operator, address zipDepositModule, address
   usdc, address xAlpha, address distributor)`. Validate **ALL six non-owner addresses + owner nonzero FIRST** +
   `owner != operator` (order-guard: a zero address reverts `ZeroAddress` deterministically before any use), set
   `avatar = target = engineSafe`, store the wiring, THEN `_transferOwnership(owner)`. `compounder` starts zero (wired
   later via `setCompounder`). No live-read/staticcall in `setUp`. All module wiring is **set-once storage, never
   `immutable`**. The mastercopy is init-locked at deploy (test asserts a second `setUp` reverts).
2. **Authority — `onlyOperator` on the action legs; `onlyOperatorOrCompounder` on `spendFreeValue`; `onlyOwner` on
   `setCompounder`.** `creditFreeValue`/`recycleModeB`/`payoutClean`/`payoutBoost` revert `NotOperator` for any
   non-operator. `spendFreeValue` reverts `NotOperatorOrCompounder` for anyone but the operator or the wired compounder
   (test BOTH callers succeed once wired, and a third party reverts). `setCompounder` reverts for a non-owner, reverts
   `AlreadyWired` on the second call, `ZeroAddress` on zero. A non-owner `setAvatar`/`setTarget` reverts; `owner ==
   operator` in `setUp` reverts `OwnerIsOperator`.
3. **The accumulator arithmetic + the gate.** `creditFreeValue(n)` (n>0) sets `freeValueAccrued += n`; `_spendFreeValue(
   a)` reverts `InsufficientFreeValue` if `a > freeValueAccrued`, else `freeValueAccrued -= a`. Tests: credit 100 →
   accrued 100; spend 60 → accrued 40; spend 41 → `InsufficientFreeValue` (accrued unchanged at 40); spend 40 → accrued
   0; `creditFreeValue(0)`/`spendFreeValue(0)` → `ZeroAmount`. **Boundary:** spend == accrued succeeds to exactly 0.
   Every credit/spend emits its event with the new running `freeValueAccrued`.
4. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** Every Safe mutation routes through the
   private `_exec(to, data) returns (bytes)` using `execAndReturnData(to, 0, data, Operation.Call)`; on `!ok` it bubbles
   the inner revert data (or `ExecFailed` when empty). **`recycleModeB(usdcAmount)`** does exactly three `_exec`s in
   order after `_spendFreeValue(usdcAmount)`: (1) `_exec(usdc, abi.encodeWithSelector(IERC20.approve.selector,
   zipDepositModule, usdcAmount))`, (2) `_exec(zipDepositModule, abi.encodeCall(IZipDepositModule.deposit,
   (usdcAmount)))` → decode `zipMinted = abi.decode(ret,(uint256))`, (3) `_exec(usdc, abi.encodeWithSelector(
   IERC20.approve.selector, zipDepositModule, uint256(0)))`. **`payoutClean(usdcAmount)`** (after `_spendFreeValue`):
   one `_exec(usdc, abi.encodeWithSelector(IERC20.transfer.selector, distributor, usdcAmount))`. **`payoutBoost(
   xAlphaAmount)`** (no spend): one `_exec(xAlpha, abi.encodeWithSelector(IERC20.transfer.selector, distributor,
   xAlphaAmount))`. **Use typed `abi.encodeCall(IZipDepositModule.deposit, (usdcAmount))`** for the deposit (a sig
   regression fails to compile). Tests assert the exact recorded `(to, value==0, data, operation==Call)` tuples on the
   recording Safe for each entrypoint, decode the `approve`/`transfer`/`deposit` args (spender/recipient ==
   zipDepositModule/distributor, amounts correct, reset == 0). Atomicity: a `live` Safe returning `(false,
   customErrorBytes)` makes the entrypoint **revert bubbling that data**; `(false, "")` reverts `ExecFailed`; and after a
   reverted `recycleModeB` **`freeValueAccrued` is unchanged** (the atomic rollback covers the decrement).
5. **`creditFreeValue` is single-arg + operator-trusted; the formula is documented not computed.** The contract does
   `freeValueAccrued += netFreeValueUsdc` (no on-chain subtraction — `realized`/`borrowRepaid` are historical, off-chain
   only). A doc comment cites the CRE's `max(0, realized − borrowRepaid)` derivation. This discharges the **8-B10
   proceeds + free-value hand-off** obligation (8-B9 → 8-B10): the USDC `sellHydx` lands in the Safe net of the 8-B5
   repay → the CRE passes that net to `creditFreeValue`; 8-B9 does NOT credit.
6. **Free-value-only enforced two-layer (the load-bearing invariant, §8 inv. 3).** (a) **Policy ceiling:** every spend
   path (`recycleModeB`, `payoutClean`, and 8-B13 via `spendFreeValue`) debits `freeValueAccrued` and reverts if it
   would go negative → the engine can never *route* more than the HYDX-extracted free value. (b) **Hard backing:** the
   actual USDC/xALPHA moved is pulled from the **Safe's real balance** by the `_exec` legs (`ZipDepositModule.deposit`
   does `safeTransferFrom(Safe, ...)`; `payout*` does `transfer`) → even an over-credited accumulator cannot conjure
   value (the transfer reverts if the Safe is short). **The Mode-B zipUSD is backed 1:1 by construction** (the deposit
   parks the USDC as senior backing *before* the mint, inside `ZipDepositModule.deposit`). Test: `recycleModeB` over a
   real fork Safe with real USDC mints exactly `usdcAmount·scaleUp` zipUSD to the Safe AND debits `freeValueAccrued` by
   `usdcAmount`; a `recycleModeB(usdcAmount)` with `usdcAmount > freeValueAccrued` reverts `InsufficientFreeValue`
   before any `_exec`.
7. **The distributor — cumulative Merkle claim, per-asset, balance-bounded.** `setRoot(asset, root)` `onlyRootPoster`;
   `claim(asset, account, cumulative, proof)` verifies the OZ-double-hash leaf against `merkleRoot[asset]`, pays
   `cumulative − claimed[asset][account]` (revert `NothingToClaim` if `<=`), sets `claimed` BEFORE the `safeTransfer`
   (effects-before-interaction), `nonReentrant`. `claimMultiple` batches with a `LengthMismatch` guard. `setRootPoster`
   `onlyOwner`. No `maxClaimable`/mint machinery (held balance is the cap). Public `claimed`/`merkleRoot` mappings + a
   `getClaimable` view for the frontend.

**Done when**
- `forge build` green; `forge test --match-path test/RecyclePayoutModule.t.sol` + `--match-path
  test/SzipRewardsDistributor.t.sol` green (unit); `forge test --fork-url $BASE_RPC_URL --match-path
  test/RecyclePayoutModule.t.sol` green (unit + fork); **no regression** on the full suite (`forge test --fork-url
  $BASE_RPC_URL`, currently 382/382 after 8-B9).
- **Module unit (RecordingSafe + MockZipDepositModule + MockERC20 + real `SzipRewardsDistributor`):**
  (a) **exec-shape, fully pinned** — `recycleModeB(u)`: exactly three recorded calls `(usdc, 0, approve(
  zipDepositModule, u), Call)`, `(zipDepositModule, 0, deposit(u), Call)`, `(usdc, 0, approve(zipDepositModule, 0),
  Call)`; decode each; the mock-returned `zipMinted` → assert `emit RecycledModeB(u, zipMinted)` + the function return.
  `payoutClean(u)`: one call `(usdc, 0, transfer(distributor, u), Call)` + `emit PaidOut(usdc, u)`. `payoutBoost(x)`:
  one call `(xAlpha, 0, transfer(distributor, x), Call)` + `emit PaidOut(xAlpha, x)`. **For EVERY recorded call assert
  `value == 0` AND `operation == uint8(Operation.Call)`.** (b) **accumulator arithmetic + the gate** — the full
  sequence in KR3 (credit/spend/boundary/over-spend revert leaves accrued unchanged/zero-amount reverts), with the
  running `freeValueAccrued` getter asserted after each + the events. `recycleModeB`/`payoutClean` each debit accrued
  by their amount; `payoutBoost` does NOT. A `recycleModeB(u)` / `payoutClean(u)` with `u > freeValueAccrued` reverts
  `InsufficientFreeValue` **before** any recorded `_exec` (assert `callCount == 0`). (c) **malformed deposit return** —
  `MockZipDepositModule`/`setReturnData` < 32 bytes → `recycleModeB` reverts. (d) authority — every action leg reverts
  `NotOperator` for a non-operator; `spendFreeValue` reverts `NotOperatorOrCompounder` for a third party, succeeds for
  the operator, and (after `setCompounder`) succeeds for the compounder; `setCompounder` reverts for a non-owner, twice
  reverts `AlreadyWired`, zero reverts `ZeroAddress`; `setAvatar`/`setTarget` revert for a non-owner; `owner ==
  operator` setUp reverts `OwnerIsOperator`; the **un-setUp mastercopy** is inert (`creditFreeValue` reverts
  `NotOperator`, every getter 0). (e) atomicity — a `live` target returning `(false, customErrorBytes)` makes the
  entrypoint revert bubbling that data; `(false, "")` reverts `ExecFailed`; **after a reverted `recycleModeB`,
  `freeValueAccrued` is unchanged** (atomic rollback of the decrement). (f) clone/init — a second `setUp` reverts; a
  zero in **each** of the 7 addresses reverts `ZeroAddress` — for ≥1 case assert the selector is
  `RecyclePayoutModule.ZeroAddress` specifically. (g) **getters** — each wired getter returns its address;
  `compounder()` is 0 pre-wire then the set value.
- **Module fork (live Base, real summoned Safe):** (a) **real Mode B end-to-end** — deploy a REAL `ZipDepositModule`
  (wired to a real/forked USDC + a deployed `ESynth` zipUSD with capacity granted to the module + a real `EulerEarn`
  pool + a warehouse Safe) — OR, if a full real EE wiring is too heavy on the fork, deploy the real `ZipDepositModule`
  against the **real Base USDC** + a **mock EE pool** + a real `ESynth` (the module-under-test's job is to *drive* the
  deposit, not to re-prove `ZipDepositModule` — that is WOOF-06's fork suite); seed the Safe with USDC, `creditFreeValue(
  seed)`, operator `recycleModeB(amount)`: assert the Safe's zipUSD balance increased by exactly `amount·scaleUp`, the
  Safe's USDC decreased by exactly `amount`, `freeValueAccrued` decreased by exactly `amount`, and `RecycledModeB`
  emitted. (b) **real `payoutClean`** — seed the Safe with USDC, `creditFreeValue`, deploy a real
  `SzipRewardsDistributor`, operator `payoutClean(amount)`: assert the distributor's USDC balance increased by exactly
  `amount`, the Safe's decreased by `amount`, `freeValueAccrued` debited, `PaidOut` emitted. (c) **integrated claim** —
  post a 2-leaf root on the distributor (built in-test), `claim` pays the allocation from the just-funded balance.
  **(Choose the lightest fork wiring that still proves the module drives a REAL `ZipDepositModule.deposit` and a REAL
  Safe→distributor transfer; mock only what is not under test.)**
- **Distributor unit (`SzipRewardsDistributor.t.sol`):** build a small Merkle tree in-test (compute leaves
  `keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))`, hash pairs sorted per OZ `MerkleProof`).
  (a) fund (mint MockERC20 to the distributor) + `setRoot(asset, root)` + `claim` pays `cumulative` to a first-time
  claimer; a second `claim` against the same root reverts `NothingToClaim`. (b) **root bump** — `setRoot` to a new tree
  with a higher cumulative for the holder → `claim` pays only the **delta**. (c) **wrong proof / wrong amount** reverts
  `InvalidProof`. (d) **per-asset isolation** — a USDC root and an xALPHA root coexist; claiming USDC does not touch
  xALPHA `claimed`. (e) **underfunded** — a valid claim whose `amount` exceeds the distributor's balance reverts (the
  `safeTransfer`); after funding, the same claim succeeds. (f) authority — `setRoot` reverts for a non-rootPoster;
  `setRootPoster` reverts for a non-owner + `ZeroAddress` on zero. (g) `claimMultiple` — length-mismatch reverts
  `LengthMismatch`; a 2-holder happy path pays both. (h) `getClaimable` returns the right value for a valid proof and 0
  after a full claim.
- **Mapped to the integration layer:** the per-epoch recycle/payout belongs in the **deferred engine-integration audit
  sweep** (`audit/2.md` Phase L + `audit/3-results.md` authority rows), authored once the engine is integration-testable
  alongside item-10 — logged as an obligation, NOT in this window (matches the 8-B5..B9/Exit-Gate sweeps).
- **The holder-facing claim UI + the off-chain Merkle-tree builder are DEFERRED** to the 8-B11 (CRE: compute per-holder
  cumulative allocations from szipUSD balances + post the root) / 8-B12 (dashboard) / a later INFLOW pass — logged as an
  obligation; the distributor exposes clean events (`RootUpdated`/`Claimed`) + the `getClaimable`/`claimed` views as the
  back-pressure (parity with how 8-B9 deferred `buyXAlpha`'s frontend).

**Critic-hardening folded (this window — all TICKET-GAP folds from the 5-critic fanout; NO spec change beyond the two
§4.5.1 fixes already made, NO §17 reopen. spec-fidelity returned zero spec/ticket gaps of substance.)**
- **Pinned event signatures (junior #5/#6):**
  Module — `event FreeValueCredited(uint256 amount, uint256 newAccrued); event FreeValueSpent(uint256 amount, uint256
  newAccrued); event RecycledModeB(uint256 usdcAmount, uint256 zipMinted); event PaidOut(address indexed asset, uint256
  amount); event CompounderWired(address indexed compounder);`. Distributor — `event RootUpdated(address indexed asset,
  bytes32 oldRoot, bytes32 newRoot); event Claimed(address indexed asset, address indexed account, uint256 amount,
  uint256 cumulativeAmount); event RootPosterSet(address indexed oldPoster, address indexed newPoster);`. The
  credit/spent second arg is the **post-mutation** running `freeValueAccrued`.
- **Zero-amount guard placement (junior #3/#4, qa):** the private `_spendFreeValue(amount)` does **both** checks —
  `amount == 0 → ZeroAmount` AND `amount > freeValueAccrued → InsufficientFreeValue` (over-spend check), then
  decrements + emits `FreeValueSpent`. Therefore `spendFreeValue(0)` / `recycleModeB(0)` / `payoutClean(0)` all revert
  `ZeroAmount` (each routes through `_spendFreeValue`). `payoutBoost` does NOT route through `_spendFreeValue` → give it
  its **own** explicit `if (xAlphaAmount == 0) revert ZeroAmount();`. `creditFreeValue(0)` reverts `ZeroAmount`.
- **The `onlyOperatorOrCompounder` modifier (junior #12):** `if (msg.sender != operator && (compounder == address(0)
  || msg.sender != compounder)) revert NotOperatorOrCompounder();` — i.e. a zero `compounder` can **never** authorize
  (so a pre-wire call from `address(0)` is impossible to authorize). Test the pre-wire third-party revert proves it.
- **Distributor constructor (junior #7/#8, ref-verifier — OZ5 `Ownable`):** `constructor(address owner_, address
  rootPoster_) Ownable(owner_)` — revert `ZeroAddress` if `rootPoster_ == 0` (OZ5 `Ownable` itself rejects `owner_ ==
  0` with `OwnableInvalidOwner`). The active OZ is **OZ5** (custom errors — the sibling asserts
  `OwnableUnauthorizedAccount`); `setRootPoster` reverts `OwnableUnauthorizedAccount` for a non-owner.
- **`getClaimable` takes NO proof (junior #17, qa #13 — match the reference `getClaimable(user, totalAllocation)`):**
  `getClaimable(address asset, address account, uint256 cumulativeAmount) returns (uint256)` = `cumulativeAmount >
  claimed[asset][account] ? cumulativeAmount − claimed[asset][account] : 0`. It is a pure netting view (the frontend
  already holds the cumulative + proof from the CRE's published tree) — it does **NOT** verify the proof and does
  **NOT** revert. (Drop the earlier "verifies the proof" phrasing in the Deliverable list — this supersedes it.)
- **Merkle-tree-in-test construction (junior #16, qa #8 — pin the rule so the builder can't guess wrong):** `leaf =
  keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))`; the internal node hashes a **sorted** pair with
  `abi.encodePacked`: `node = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a))` (OZ
  `MerkleProof` default sorted-pair). For a 2-leaf tree, `proof_for_leaf0 = [leaf1]`, `root = node(leaf0, leaf1)`.
  **Self-check in-test:** after building, `assertTrue(MerkleProof.verify(proof, root, leaf))` BEFORE relying on `claim`.
- **`MockERC20` must implement `transfer` (junior #22):** the sibling `RecordingSafe.MockERC20` has only
  `approve`/`transferFrom`/`balanceOf`; the `payoutClean`/`payoutBoost` legs + the distributor funding need `transfer` —
  extend the test mock (add a real `transfer` updating balances).
- **Fork / integrated-unit rig — model `contracts/test/ZipDepositModule.t.sol` (junior #10, qa #17 — the previously-
  vague "lightest wiring" is now PINNED):** that file deploys a **fork-free** real-deposit rig — `ESynth zip = new
  ESynth(address(evc), "Zipcode USD", "zipUSD")` (`evk/Synths/ESynth.sol`; 18-dp), a `ConfigurableERC20` 6-dp USDC
  mock, a **par `MockEulerEarn`** (its own 6-dp share token; `deposit(assets, receiver)` pulls the full assets), a
  `WAREHOUSE_SAFE` test address, `new ZipDepositModule(address(zip), address(usdc), address(ee), WAREHOUSE_SAFE)`, and
  **`zip.setCapacity(address(module), type(uint128).max)`** (the EVC + ESynth are plain contracts — **no fork needed for
  the deposit deps**). **MUST be real:** the `RecyclePayoutModule` under test drives a **real `ZipDepositModule.deposit`**
  over a **real `ESynth`** (capacity-granted) so the Mode-B mint is genuinely exercised. **MAY be mocked:** USDC
  (`ConfigurableERC20`) + the EE pool (`MockEulerEarn` par) — re-proving EE/USDC is WOOF-06's job. **Pin `scaleUp ==
  1e12`** (`ZipDepositModule.sol:118`) and assert the Safe's zipUSD delta is **exactly `amount * 1e12`**, USDC delta
  exactly `−amount`, `freeValueAccrued` delta exactly `−amount`, and the post-call `usdc.allowance(safe,
  zipDepositModule) == 0` (reset). So **two integrated passes:** (i) a **no-fork integrated UNIT** test with a LIVE
  `RecordingSafe` as the "engine Safe" driving the real `ZipDepositModule` rig (proves the full Mode-B value flow +
  the ordering test below without a fork); (ii) a **Base-fork** test with a **real summoned Gnosis Safe**
  (`SummonSubstrate._summon`, model `SellModule.t.sol`'s `_summonAndEnable`) as the engine Safe, the same rig enabled,
  proving the Zodiac exec path against real Safe bytecode + a real `SzipRewardsDistributor` claim end-to-end. **USDC
  is the mock here** (the rig's `ConfigurableERC20`), so no `deal`/whale problem.
- **Decrement-BEFORE-exec ordering — the riskiest path, must be OBSERVABLY pinned (qa #1/#2, security #6/#12):** a
  test where `recycleModeB`'s decrement landing before the value-moving deposit is *observable*, not just "a revert
  rolls back." Use a LIVE `RecordingSafe` whose deposit target is a **`MockZipDepositModule` that, inside `deposit()`,
  staticcalls back `module.freeValueAccrued()` and records it**; after `recycleModeB(u)` over `creditFreeValue(seed)`,
  assert the recorded mid-call value `== seed − u` (the spend was already applied at exec #2 time). This proves
  effects-before-interaction (a re-entrant spend can't double-spend the same budget) — the plain `setFailOnCallIndex`
  rollback test CANNOT distinguish decrement-before from decrement-after, so this read-back test is REQUIRED.
- **Reentrancy posture — principled split (security #6/#10, qa #10):** the **module** does NOT inherit OZ
  `ReentrancyGuard` (a `ModuleProxyFactory` clone never runs the guard's constructor, and the siblings deliberately
  avoid it) — its reentrancy safety is **effects-before-interaction** (`_spendFreeValue` decrements BEFORE the three
  `_exec`s) + the set-once **trusted** wired targets + `ZipDepositModule`'s own `nonReentrant`; the ordering test above
  is the proof. The **distributor** DOES inherit `ReentrancyGuard` (it has a real constructor + a caller-supplied
  `asset`): `claim`/`claimMultiple` are `nonReentrant`, `_claim` sets `claimed` BEFORE `safeTransfer`. Test: a
  malicious-asset whose `transfer` re-enters `claim` reverts (`ReentrancyGuardReentrantCall` or `NothingToClaim`), and
  the outer claim pays exactly once.
- **Distributor security negatives (security #8/#11):** (a) **cross-asset proof confusion** — a VALID USDC proof
  submitted as `claim(xAlpha, account, cumulative, usdcProof)` reverts `InvalidProof` (the per-asset root is the
  isolation boundary; the leaf does not bind the asset). (b) **no-root asset** — `claim(arbitraryAsset, …)` where
  `merkleRoot[arbitraryAsset] == bytes32(0)` reverts `InvalidProof` (assets are implicitly allowlisted by having a
  rootPoster-set root). (c) **stale/lower-cumulative root** — `setRoot` to a root with a LOWER cumulative for a holder
  who already claimed → their next `claim` reverts `NothingToClaim` (monotonic `claimed`; their funds are safe; a
  recoverable operator grief, NOT a loss). (d) **claimed unchanged after an underfunded revert** — fund `amount−1`,
  `claim` reverts at the `safeTransfer`, `claimed[asset][account]` is UNCHANGED (effects rolled back), then top-up `+1`
  and the same `claim` succeeds paying the full `amount`. (e) **root-bump pays only the delta** — `setRoot` cum=100 →
  claim 100; `setRoot` cum=150 → claim 50.
- **Trust-boundary notes — §17-ACCEPTED, document in the contract NatSpec + logged as obligations (security #3/#7/#9,
  NOT bugs under the single-immutable-CRE-operator model):** (1) `creditFreeValue` is **unbounded** — the policy
  ceiling (`freeValueAccrued`) is operator-trusted, NOT a cryptographic guarantee; an over-credit lets the operator
  route up to the Safe's real balance (which can include depositor principal) as a "payout" — the HARD backing layer
  (real `safeTransferFrom`/`transfer` from the Safe) only proves a balance EXISTS, not that it is free-value balance.
  (2) A mis-posted root mis-SPLITS among holders within the funded balance but cannot create value beyond it. (3) These
  are bounded by §17's single trusted CRE writer; the operational backstops are the 8-B11 fund-before-post-root
  discipline + the 8-B12 balance tripwire (logged below). State (1)/(2) plainly in the module/distributor NatSpec.
- **qa test-completeness folds (all strict additions):** assert the specific selector `RecyclePayoutModule.ZeroAddress`
  for **all 7** zero-address `setUp` cases (not just ≥1); add an abi-length-mismatch `setUp` payload revert; a
  multi-credit accumulation (`creditFreeValue(100)`→`(150)` running total + events); `spendFreeValue` makes **no**
  Safe calls (`callCount == 0` — pure accounting); the **`payoutBoost` ungated negative-control** (`creditFreeValue(0)`
  then `payoutBoost(40)` SUCCEEDS and leaves `freeValueAccrued == 0` — boost is genuinely un-gated by the accumulator);
  `value == 0` + `operation == Call` asserted on every recorded exec of every entrypoint via the shared `_assertCall`
  helper; `claimMultiple` three length-mismatch permutations + a 2-holder happy path; `getClaimable` returns 0 after a
  full claim.

**Depends on**
- **8-B1** (the summoned engine Safe substrate — `SummonSubstrate._summon`, at `contracts/script/SummonSubstrate.s.sol`),
  **8-B9** (`SellModule.sol` — the primary `is Module`/`_exec`/setUp-order-guard model + the `RecordingSafe`/`MockERC20`
  test harness), and **WOOF-06** (`ZipDepositModule.sol` — the real Mode-B backed-mint target; `contracts/src/supply/
  ZipDepositModule.sol`). **The cold-builder MUST open these to reuse the harness:** `contracts/test/SellModule.t.sol`
  (the `RecordingSafe` with `setLive`/`setFailOnCallIndex`/`getCall`/`callCount`/`setReturnData` and the
  `_summonAndEnable` fork pattern) + `ZipDepositModule.sol` (the `deposit(uint256) returns (uint256)` signature + the
  `safeTransferFrom(msg.sender,...)` pull that dictates the approve-first exec order).
- **Feeds:** 8-B9 (the `buyXAlpha` swap the CRE sequences after `recycleModeB`), 8-B5 (the free-value source the CRE
  nets and passes to `creditFreeValue`), **8-B13** (Mode C — calls `spendFreeValue` through the set-once `compounder`
  seam), 8-B11 (the CRE robot that picks the mode/entrypoint, sizes amounts, posts the distributor root, and sequences
  sell→repay→credit→recycle/payout), 8-B12 (monitoring: trailing-realized APR off the realized distributions), item 2
  NAV (the undistributed free value marked as accrued proceeds until a payout leg moves it out).

---

**Inbound cross-ticket obligations DISCHARGED by this ticket** (mark in `PROGRESS.md` at Conclude):
- **8-B10 · proceeds + free-value hand-off (8-B9 → 8-B10)** (owed by 8-B9): `creditFreeValue(uint256 netFreeValueUsdc)`
  is the owned accumulator's only increment, single-arg, operator-trusted, `+= max(0, realized − borrowRepaid)` computed
  off-chain. **DISCHARGED** — KR5; 8-B9 does NOT credit free value.
- **8-B10 · 8-B6 backed-zipUSD invariant** (owed by 8-B6): the zipUSD leg of any `LpStrategyModule.addLiquidity` MUST be
  **backed** (minted only via 8-B10's free-value path / the §4.5 zap), never unbacked. **DISCHARGED (mechanism side)** —
  8-B10's Mode-B/C path mints zipUSD **only** through `ZipDepositModule.deposit` (USDC parked as senior backing *before*
  the mint ⇒ backed 1:1 by construction; KR6); the module never calls `ESynth.mint` directly. The CRE funds the Safe
  before calling (the wiring/sequencing half stays an 8-B11/item-10 obligation).

**New cross-ticket obligations this ticket CREATES** (record in `PROGRESS.md` at Conclude):
- **Item 10 / 8-B11 — operator + compounder + token + distributor wiring (8-B10):** wire the single CRE operator as
  `operator`; wire `zipDepositModule` to the deployed WOOF-06 module, `usdc`/`xAlpha` to the live tokens, `distributor`
  to the deployed `SzipRewardsDistributor`; **deploy the module clone via `ModuleProxyFactory` CREATE2 + `setUp`
  ATOMICALLY in one factory tx (front-run-safe) + init-lock the mastercopy** (the 8-B5/8-B8/8-B9/8-B14 pattern). After
  8-B13 is built, `owner` (Timelock) calls `setCompounder(8-B13)` once. The `SzipRewardsDistributor` is deployed with
  `rootPoster = the CRE operator`, `owner = Timelock`. 8-B11 picks the A/B/C mode per epoch (the entrypoint), sizes the
  amounts within `freeValueAccrued`, and **computes the per-holder cumulative allocation from szipUSD balances + posts
  the Merkle root** via `setRoot(asset, root)` (the off-chain tree builder is a CRE/§8 deliverable).
- **8-B13 — Mode-C `spendFreeValue` seam (8-B10):** when 8-B13 is authored, its `compound` pass calls 8-B10
  `spendFreeValue(B)` (through the `onlyOperatorOrCompounder` gate; `owner` wires `setCompounder(8-B13)` at deploy)
  BEFORE it deposits/mints/LPs the budget `B` — so the Mode-C spend is gated by the same free-value accumulator
  (`auto-sodomizer.md` §11.3 / §8 inv. 3). 8-B13 uses the SAME `ZipDepositModule.deposit` backed-mint mechanism as
  Mode B.
- **Item 10 / engine-integration audit sweep (8-B10):** author the per-epoch recycle/payout into `audit/2.md` Phase L
  (an L-step: 8-B9 sell → 8-B5 repay → `creditFreeValue(net)` → `recycleModeB`/`payoutClean` → distributor `claim`, with
  USDC/zipUSD/`freeValueAccrued`/distributor balances moving; N-steps: non-operator / over-spend (`InsufficientFreeValue`)
  / zero-amount / non-rootPoster `setRoot` / wrong-proof `claim` each revert) + the matching `audit/3-results.md`
  authority rows (operator-only action legs; `spendFreeValue` operator-or-compounder; `setCompounder` owner-set-once;
  `setAvatar`/`setTarget` owner-locked; distributor `setRoot` rootPoster-only; no NAV write; payouts realized not
  marked). Author once the engine is integration-testable (with 8-B11..B13 + item-10), like the 8-B5..B9/Exit-Gate
  sweeps.
- **8-B11 / 8-B12 — distributor funding-precedes-claim + root correctness (8-B10):** the distributor has **no
  on-chain `maxClaimable`** — the held balance bounds total claims, but a mis-posted root can mis-split among holders
  within the funded balance. 8-B11 MUST fund (`payoutClean`/`payoutBoost`) the cumulative-delta **before** posting the
  matching root, and the off-chain tree MUST sum to ≤ the funded balance; 8-B12 MUST tripwire if
  `distributor.balanceOf(asset)` falls short of the outstanding-unclaimed implied by the posted root (the operational
  backstop; under the single-trusted-operator model a bad root cannot create value beyond the funded balance).
- **Item 10 / 8-B12 — NAV must count Safe balance XOR the accumulator (8-B10, security #13):** the free-value USDC
  sits in the engine Safe (counted in NAV as "accrued undistributed proceeds", §3/8-B12) until a payout leg moves it
  out. `SzipNavOracle` + 8-B12 MUST value the Safe's **real token balances** and **never separately add**
  `freeValueAccrued` — otherwise the same dollars count twice (once as Safe balance, once as the accounting ledger).
  8-B10 never writes NAV; this is the load-bearing assumption behind "value-neutral (NAV down, claim up)". Verify in
  the integration sweep.
- **8-B11 / CRE §8 — `creditFreeValue` net computation (8-B10):** the CRE computes `max(0, realized − borrowRepaid)`
  off-chain from the 8-B9 sell proceeds and the 8-B5 `debtOf`/repay receipts for that loop and passes the single net to
  `creditFreeValue`; the module trusts it (it cannot reconstruct historical realized/repaid on-chain). The §8 workflow
  owns this arithmetic.
