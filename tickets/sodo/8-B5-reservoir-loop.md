# 8-B5 — Reservoir USDC vault + ICHI-LP collateral + CRE-borrow (the strike-financing loop)

> **NEXT / build-only.** The first of the engine harvest-loop modules (8-B5…B13). It is the **strike-financing
> process**: the LP self-collateralizes its own oHYDX strike. The CRE robot, per harvest, **unstakes** an LP slice
> (8-B6), **posts it as collateral**, **borrows** the ~30% strike USDC from the warehouse `USDC Resting Vault`,
> (8-B8 exercises → 8-B9 sells), **repays** the borrow, and **withdraws** the LP to re-stake (8-B6). This ticket
> builds the **on-chain seam** of that loop: a CRE-gated Zodiac module driving the szipUSD Safe's **own EVC
> account** + the LP-collateral price oracle + a borrow-gating hook + the reservoir EVK market wiring. Internal
> engine plumbing → **build-only** (no INFLOW ticket; the frontend never wires to it, CRE drives it).
>
> **User decision locked this window (the §4.5.1 flag):** the LP-collateral price feed is a **CRE-fed push-cache
> oracle** (option 1, user-ratified 2026-06-08), NOT a fixed-haircut constant. The CRE workflow computes the
> per-LP-share USD mark off-chain — `(reserve_xALPHA × priceXAlpha + reserve_zipUSD × priceZipUSD) /
> ICHI_LP_totalSupply` (the same LP-marked-through-at-reserve-value math `SzipNavOracle` already runs for the
> basket's staked-LP leg) — and pushes it; the on-chain adapter is the thin cache + staleness gate the **Oracle
> Router** (`EulerRouter`, the price-oracle router — NOT the swap/orderflow router) resolves. Both options were
> manipulation-safe (CRE-only + over-collateralized borrow); the cache shape was chosen for value tracking + reuse
> of the proven registry shape.
>
> **Critic-pass hardening folded in this window (4 findings → design changes):** (1) **aggregate `borrowCap`** —
> the cap bounds *total outstanding* reservoir debt, not a single call (security F1); (2) a **required
> `ReservoirBorrowGuard`** hook pins `OP_BORROW` to the engine Safe so no third party can lever the *shared*
> resting USDC via the escrow collateral (security F8a); (3) the **deployer CREATES the borrow vault**
> (oracle = router), resolving a router/borrow-vault ordering cycle (junior #10); (4) `repay`'s 2nd arg is
> **`receiver`** (verified `IEVault.sol:240`), value = `engineSafe`.
>
> **BUILD-EXPOSED CORRECTIONS (cold-build 2026-06-08, kept-build doctrine — these are load-bearing, honor them):**
> - **(C1 — CRITICAL) The Gnosis Safe SWALLOWS inner reverts.** `execTransactionFromModule(...)` catches an inner
>   revert and returns `false` (it does NOT bubble). A bare `exec(...)` therefore silently swallows a failed EVC
>   borrow/repay/oracle-read — `E_AccountLiquidity`/`PriceOracle_*`/`E_RepayTooMuch` would be emitted then ignored,
>   and the module would wrongly emit success. **The module MUST route every mutation through a private `_exec` that
>   uses `execAndReturnData(...)` and BUBBLES the inner revert data** (re-`revert` with the returned bytes; fall back
>   to a new `error ExecFailed()` when there is no revert data). This is what makes every fail-closed "Done when"
>   revert actually surface. (Without it, the safety tests pass for the wrong reason.)
> - **(C2) `repay` does NOT cap at outstanding debt.** EVK `repay(amount, receiver)` reverts `E_RepayTooMuch`
>   (`Borrowing.sol:86`) when a *literal* `amount > owed` (only `type(uint256).max` means "repay all"). The loop
>   repays the **exact** strike (the operator/8-B9 knows the figure). Over-repay reverts `E_RepayTooMuch` — the
>   residual-approval reset (§A.5) stays as defense-in-depth.
> - **(C3) EVK gates a NEW borrow against `borrowLTV`, not `liqLTV`.** The over-LTV magnitudes are pinned to
>   `borrowLTV` (see Done-when): on $100 collateral at `borrowLTV=0.7e4`, `borrow(69e6)` succeeds, a borrow taking
>   the total over $70 reverts `E_AccountLiquidity` (`liqLTV` is the *liquidation* threshold, not the borrow gate).
> - **(C4) `setLTV` validates the collateral price at config time, so a live LP mark MUST exist BEFORE deploy.**
>   `ReservoirMarketDeployer.deploy(...)` calls `setLTV`, which calls `getQuote` on the router → the LP oracle must
>   already hold a fresh CRE mark. And "governor RETAINED" = the deployer is the router governor **at birth** (to
>   configure), then `router.transferGovernance(governor)` hands it to the **Timelock** — it is NOT a skipped
>   transfer (the WOOF-04 inversion is `transferGovernance(timelock)` vs WOOF-04's `transferGovernance(0)`).
> - **(mechanical) `deploy(...)` packs its args into a `Params` struct** (10 loose args hit stack-too-deep without
>   `via_ir`). Test stand-ins: 18-dp `MockLpToken`, `ZeroIRM` (model `EulerVenueAdapter.t.sol`), a `DebtStub` for
>   unit exec-discipline, a `MisWiringDeployer` for the W3 negative. Test deploy values: `validityWindow = 1 days`,
>   `borrowCap = 1_000_000e6`, `borrowLTV/liqLTV = 0.7e4/0.8e4`, mark `1e6` ($1/share), slice `100e18`, strike `50e6`.

**Deliverable**
Four contracts + tests under the supply/engine tree:
- `contracts/src/supply/szipUSD/ReservoirLoopModule.sol` — `contract ReservoirLoopModule is Module` (zodiac-core
  base, `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD
  engine Safe** (`avatar == target == engineSafe`). It exposes the four loop entrypoints —
  `postCollateral` / `borrow` / `repay` / `withdrawCollateral` — each mutating the Safe **only** via the inherited
  `exec(to, value, data, Operation.Call)` to drive the **Safe's own EVC account** (borrower-of-record = the Safe,
  NOT a fresh `LineAccount`, §4.5.1). The operator supplies **only scalar amounts**; the module builds all calldata
  to the **set-once wired targets** (the LP token, the LP escrow vault, the reservoir USDC borrow vault, USDC, the
  EVC), with every `receiver`/`onBehalfOfAccount` hard-pinned to `engineSafe`. No generic call passthrough — the
  module's whole security boundary (§10.1).
- `contracts/src/supply/SzipReservoirLpOracle.sol` — `contract SzipReservoirLpOracle is ReceiverTemplate,
  BaseAdapter`. The CRE-fed push-cache LP price oracle (single LP key, quote = USDC), modeled directly on
  `ZipcodeOracleRegistry`. The CRE Forwarder pushes the per-LP-share mark via `_processReport` (reportType
  `LP_MARK`); `_getQuote` serves a stale-checked read to the reservoir's `EulerRouter`. The deploy prerequisite the
  router resolves the LP collateral through.
- `contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol` — `contract ReservoirBorrowGuard is IHookTarget`,
  modeled **verbatim** on `contracts/src/CREGatingHook.sol` (the `isProxy`-guarded `isHookTarget()` +
  `_msgSender()` calldata-extraction), with the gate swapped: `OP_BORROW` is allowed **only** when the EVK-appended
  on-behalf account `== engineSafe` (else revert `NotEngineSafe()`). Installed on the reservoir USDC borrow vault at
  `OP_BORROW`. (`CREGatingHook` itself does NOT fit: it gates `isAccountOperatorAuthorized(account, borrowDriver)`,
  which requires an EVC operator on the borrowing account — but the engine Safe borrows on its OWN account with NO
  operator, §4.5.1. So the guard is account-identity, not operator-authorization.)
- `contracts/script/ReservoirMarketDeployer.sol` — a deployer library/contract that stands up the **reservoir EVK
  market** one-time: the LP **escrow collateral vault**, a dedicated **`EulerRouter`** wired
  `escrow → lpToken → SzipReservoirLpOracle`, the **USDC borrow vault** (oracle = that router; the warehouse
  `USDC Resting Vault`), with the `ReservoirBorrowGuard` installed at `OP_BORROW` and `setLTV(escrow, …)` accepting
  the escrow as collateral. **Governor RETAINED** (the §17 `TimelockController`), NOT renounced — distinct from
  WOOF-04's frozen per-line routers (LTV/caps/oracle stay tunable). Returns `(escrowVault, borrowVault, router)` for
  the module's `setUp` + item-10 deploy.
- `contracts/test/ReservoirLoopModule.t.sol` — unit (recording-mock Safe — exec-shape/authority) + fork (live Base
  EVK/EVC, real summoned substrate Safe — the full unstake→post→borrow→repay→withdraw loop) + the LP-oracle + guard
  + deployer tests.

It is the **second engine Zodiac Module** (after 8-B14): it reuses the `is Module` + `setUp(bytes)`-under-
`initializer` + `onlyOperator` + `exec(...,Operation.Call)` pattern established by `SzipBuyBurnModule`, and adds the
**EVC-account-driving** dimension (the Safe borrows on its own account, modeled on WOOF-04's fork-proven EVK/EVC path).

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec: the shared architecture (every engine module is a
  `is Module` Zodiac module on the Safe, one immutable CRE operator = `onlyCRE`, **the Safe is itself an EVC account
  owner**, the module drives the Safe to `enableController`/`enableCollateral`/borrow), and the **8-B5** block (the
  self-collateralizing loop, the **`OP_BORROW`-guard-pins-the-Safe** hardening, the **aggregate `borrowCap`**, the
  `GenericFactory`-governor-retained wiring, the CRE-fed `LP_MARK` collateral oracle as a deploy prerequisite, the
  verified call signatures for loop steps 2–6, the lender-side invariant). *(The §4.5.1 oracle + borrow-pin notes
  were clarified this window — see the spec edits.)*
- `baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one immutable CRE operator =
  `onlyOperator`, mutate the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via
  `ModuleProxyFactory`, init in `setUp` under `initializer`, Call-only/no-delegatecall) + **§10.8 / 8-B5** (the
  strike-loop description) + **§14** (`borrowCap` = governed param).
- `claude-zipcode.md` **§4.1 / §7** — the push-cache adapter shape (`BaseAdapter`/`IPriceOracle`, event-driven mark,
  fail-closed staleness) the LP oracle reuses; **§4.3** — the EVK hook-target pattern (`CREGatingHook`) the borrow
  guard reuses; **§4.7** — the per-line-router/EVK pattern (the EVC-account borrow this loop adapts to the Safe's own
  account); **§17** locked: venue-agnostic (Euler = config one), no on-chain economic liquidation, the engine is
  CRE-permissioned.

**Model from (VERIFIED against `reference/`, the kept build, and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol`. **Verified by the kept `SzipBuyBurnModule`
  (8-B14, builds + fork-tests green under 0.8.24)** and re-confirmed by the reference-verifier this window:
  `abstract contract Module is FactoryFriendly, Ownable`; `setUp(bytes) public virtual`; `initializer` is
  **zodiac-core's own** (`factory/Initializable.sol`, one-shot); `exec(to,value,data,Operation) internal virtual`
  (`core/Module.sol:43`) → `IAvatar(target).execTransactionFromModule(...)`; `Operation { Call, DelegateCall }`
  (`core/Operation.sol`); `Ownable` is zodiac-core's own (`factory/Ownable.sol`: `address public owner`,
  `onlyOwner` reverts `OwnableUnauthorizedAccount`, `_transferOwnership` internal/no-guard — use in `setUp`;
  `setAvatar`/`setTarget` are `public onlyOwner` at `Module.sol:23/:31`). Remap
  `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/` (`contracts/remappings.txt:10`) resolves;
  zodiac-core imports **zero OpenZeppelin** → no OZ-4/5 collision with the Euler OZ-5 tree.
- **Import the exact lines from the kept models (do NOT re-derive aliases):**
  - module side — copy from `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol:4-5` (`Module`, `Operation`) +
    `contracts/src/venue/EulerVenueAdapter.sol:7-14` (`GenericFactory`, `{IEVault, IBorrowing}`, **`{IERC4626 as
    IEVKERC4626}` from `evk/EVault/IEVault.sol`** — use this EVK alias for `deposit`/`withdraw`, NOT the OZ
    `IERC4626`; `EulerRouter`, `{IEVC}`, `{IERC20}`). The EVC/EVK/EulerRouter remaps (`evc/`, `evk/`,
    `euler-price-oracle/`) are in `contracts/remappings.txt:1-3` (proven by WOOF-04). **8-B5 does NOT import
    euler-earn** (the loop borrows from a standalone EVK USDC vault, not the EE pool).
  - oracle side — copy from `contracts/src/ZipcodeOracleRegistry.sol:4-7` (`ReceiverTemplate`, `{BaseAdapter,
    Errors, IPriceOracle}`, `{ScaleUtils, Scale}`, forge-std `IERC20`). `_getDecimals` is a `BaseAdapter` internal
    (registry `:70`). `ReceiverTemplate` is OZ-5-`Ownable`-based (its own ctor reverts on a zero forwarder); the
    registry's `_processReport` override is the model. Remap `x402-cre-price-alerts/` (`remappings.txt:11`).
  - guard side — copy the whole structure from `contracts/src/CREGatingHook.sol` (`{IHookTarget} from
    "evk/interfaces/IHookTarget.sol"`, the `IGenericFactory.isProxy` guard, the `_msgSender()` assembly, the
    `fallback()` gate, `isHookTarget()`); swap the gate body to `if (_msgSender() != engineSafe) revert
    NotEngineSafe();`.
- **CRITICAL clone fact (§18.6, proven on 8-B14).** A `ModuleProxyFactory` clone shares the mastercopy's runtime
  bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp` config. **Every
  per-clone wired address/param of `ReservoirLoopModule` (`operator`, `engineSafe`, `evc`, `borrowVault`,
  `escrowVault`, `lpToken`, `usdc`, `borrowCap`) MUST be plain set-once storage written in `setUp` under
  `initializer`, NOT `immutable`.** Governed `borrowCap` gets an `onlyOwner` setter. Init-lock the mastercopy at
  deploy. *(The LP oracle, the guard, and the deployer are **singletons**, NOT clones — they MAY use `immutable`;
  only the `is Module` module is clone-deployed.)*
- **The EVC/EVK borrow path** — **verified against the kept, fork-tested `EulerVenueAdapter.sol` (WOOF-04, 20/20 on
  a live Base fork)** + the remapped headers (reference-verifier, this window). The signatures the module builds
  calldata for:
  - `IEVC.enableCollateral(address account, address vault)` (`EthereumVaultConnector.sol:221`) /
    `IEVC.enableController(address account, address vault)` (`:269`) — called with `account = engineSafe`.
  - `IEVC.call(address targetContract, address onBehalfOfAccount, uint256 value, bytes data)` — **FOUR args**
    (`:323`; WOOF-04 `closeLine:270`). Borrow/repay/withdraw run on behalf of `engineSafe` via this.
  - `IEVKERC4626.deposit(uint256 amount, address receiver)` (`IEVault.sol:144`; WOOF-04 `:158`) /
    `IEVKERC4626.withdraw(uint256 amount, address receiver, address owner)` (`:157`). **Use `withdraw` (assets-in,
    so `lpAmount` is LP-token units, symmetric with `deposit`), NOT `redeem`** — the bare escrow is 1:1 shares↔assets
    (`EulerVenueAdapter.t.sol:312`), so assets == shares; the test asserts the 1:1 to make the `postedCollateral()`
    (shares) == posted-asset identity explicit.
  - `IBorrowing.borrow(uint256 amount, address receiver)` (`IEVault.sol:234`; WOOF-04 `draw:245`) /
    **`IBorrowing.repay(uint256 amount, address receiver)` (`IEVault.sol:240` — VERIFIED this window; the 2nd arg is
    `receiver` = the account whose debt is reduced, value = `engineSafe`; do NOT confuse with `repayWithShares(uint256,
    address)` at `:250`)** / `IBorrowing.debtOf(address account)` (`:210`; WOOF-04 `observeDebt:258`).
  - Governance: `IEVault.setLTV(address collateral, uint16 borrowLTV, uint16 liqLTV, uint32 rampDuration)`
    (`:492`; WOOF-04 `:188`, 1e4 scale, ramp 0) / `setCaps(uint16,uint16)` (`:528`) / `setHookConfig(address,uint32)`
    (`:519`) / `setGovernorAdmin(address)` (`:481`) / `setInterestRateModel(address)` (`:511`).
  - **The Safe-as-EVC-account fact:** when the module `exec`s a call to the EVC, the **Safe** is the EVC
    `msg.sender` and **owns** the EVC account whose address == the Safe address (sub-account 0). So
    `enableCollateral(engineSafe,·)` / `enableController(engineSafe,·)` / `call(·, engineSafe, ·, ·)` are authorized.
    This is the §4.5.1 "the Safe is itself an EVC account owner" architecture — distinct from WOOF-04's fresh
    per-line `LineAccount` + adapter-as-operator (the SENIOR lien borrowers, §4.4).
- **The reservoir EVK market wiring** — **verified against WOOF-04 `openLine` (fork-proven):** escrow =
  `GenericFactory.createProxy(address(0), false, abi.encodePacked(lpToken, address(0), address(0)))`
  (`GenericFactory.sol:116`; WOOF-04 `:126`) then `setHookConfig(0,0)` + `setGovernorAdmin(0)` (bare box). Router =
  `new EulerRouter(evc, governor)` (`EulerRouter.sol:47`); `router.govSetResolvedVault(escrow, true)` (`:69`, unwrap
  escrow → lpToken 1:1); `router.govSetConfig(lpToken, usdc, lpOracle)` (`:56`). **Governor RETAINED** (do NOT call
  `router.transferGovernance(address(0))` — the §4.5.1 difference; pass `governor = TimelockController`). Borrow vault
  = `createProxy(address(0), false, abi.encodePacked(usdc, address(router), usdc))` (oracle = router, unitOfAccount =
  USDC → 1:1, WOOF-04 `:137`); `setInterestRateModel(irm)`; `setHookConfig(borrowGuard, OP_BORROW)` (the guard, see
  below); `setLTV(escrow, borrowLTV, liqLTV, 0)` so the ~30% strike borrow sits well inside `liqLTV`
  (self-collateralizing). `OP_BORROW = 1 << 6` (the EVK op bitmask, `EulerVenueAdapter.sol:26`).
- **`SzipReservoirLpOracle`** — model **directly on `contracts/src/ZipcodeOracleRegistry.sol`** (kept,
  fork-verified): `is ReceiverTemplate, BaseAdapter`; ctor `(address forwarder, address quote_ /*USDC*/, uint256
  validityWindow_, address lpToken_)`. Differences from the registry: **single fixed key** (`lpToken` set in ctor —
  NOT a per-key map; the registry's strict-`decimals()==18` guard becomes a strict `base == lpToken` guard in
  `_getQuote`), a **dedicated reportType `LP_MARK`** (see below — NOT `REVALUATION=3`), and **no controller-seed
  path** (drop `seedPrice`/`setController` — the only writer is the Forwarder push). Reuse the registry's
  `Cache{uint208 price; uint48 timestamp}`, the `_writePrice` fail-closed guards (price != 0, ≤ uint208.max, ts ≤
  now — `Errors.PriceOracle_InvalidAnswer`/`_Overflow` + a `FutureTimestamp`), `ScaleUtils.calcScale`/`calcOutAmount`,
  and the `_getQuote` staleness check (`block.timestamp - c.timestamp > validityWindow → Errors.PriceOracle_TooStale`;
  `c.timestamp == 0 || quoteAsset != quote || base != lpToken → Errors.PriceOracle_NotSupported`). **Scale:** the
  ICHI LP share is **18-dp**, quote = USDC **6-dp** — `scale = ScaleUtils.calcScale(18, _getDecimals(quote_),
  _getDecimals(quote_))` (the registry's exact pattern). Owner: renounce the inherited OZ-5 Ownable at deploy
  (`renounceOwnership()`) — no owner-gated method on this oracle; **re-pointing is the *router governor*'s job**
  (`router.govSetConfig` under the retained Timelock), NOT an oracle-local owner. *(This renounce is distinct from —
  and not in tension with — "Do NOT renounce the router/vault governor": the **oracle's** owner is renounced; the
  **router's** governor is retained.)*
- **`LP_MARK` reportType — pinned placeholder, CRE-ratified later.** `claude-zipcode.md §8` (the CRE report ABI) is
  TODO (`spec-clear-CRE.md`), so the engine-oracle reportType is not yet registered there. **Pin `uint8 constant
  LP_MARK = 7`** in the built oracle (distinct from the registry's `REVALUATION = 3`); the report flags it for the
  CRE window to ratify in §8. The envelope is the shared §4.4 shape: `abi.encode(uint8 reportType, abi.encode(uint256
  mark, uint32 ts))`.
- **Error declarations (declare them; the ticket throws them).** Module: `error NotOperator(); error ZeroAddress();
  error OwnerIsOperator(); error ZeroAmount(); error CapExceeded(); error DebtOutstanding();` (model the block on
  `SzipBuyBurnModule.sol:98-108`). Guard: `error NotEngineSafe();`. Oracle: reuse the registry's `Errors.PriceOracle_*`
  (from `euler-price-oracle/lib/Errors.sol`) + a local `error InvalidReportType(uint8); error FutureTimestamp();`
  (registry `:49/:55`). Deployer: `error WireMismatch();`.
- **`SzipNavOracle`** (`contracts/src/supply/SzipNavOracle.sol`, kept) — **reference only.** It already computes the
  basket's staked-LP leg at true reserve value (the same math the CRE LP mark uses). The LP oracle does **not** read
  it on-chain; the report notes the shared computation so CRE produces one consistent LP value for both NAV and the
  collateral mark.
- **Addresses (`contracts/script/BaseAddresses.sol`, kept + verified):** `EVC` `0x5301c7dD…`, `EVAULT_FACTORY`
  (`GenericFactory`) `0x7F321498…`, `USDC` `0x833589fC…` (6-dp), `CRE_KEYSTONE_FORWARDER` `0xF8344CFd…`,
  `ZODIAC_MODULE_PROXY_FACTORY` `0x00000…dda236`. The real LP token is an ICHI vault share (minted by 8-B6) — for
  8-B5 use an **18-dp stand-in ERC20 LP** (the §4.5.1 stand-in posture). No new address constants required.

**Starting state**
`forge build` green on `main` (kept tree: WOOF-00…05, SzipNavOracle, ExitGate+SzipUSD, ZipDepositModule, 8-B1
substrate, 8-B14 `SzipBuyBurnModule`) — confirmed by the reference-verifier (`forge build` exit 0 this window). The
EVK/EVC/EulerRouter remaps are proven by WOOF-04; zodiac-core `Module` by 8-B14; `ReceiverTemplate`+`BaseAdapter` by
the registry; `IHookTarget` by `CREGatingHook`. `contracts/src/supply/szipUSD/` exists. **No engine Safe is summoned
in unit tests** — use a **recording mock Safe** = the `RecordingSafe` in `contracts/test/SzipBuyBurnModule.t.sol`
(it implements `execTransactionFromModule`, records each `(to, value, data, operation)`, `setLive`/`getCall`/
`callCount`, and `setFailOnCallIndex` for atomicity tests) for validation/authority/exec-shape, and a **real Base
fork** with the **real summoned substrate Safe** (`SummonSubstrate._summon`, model `ExitGate.t.sol` /
`SummonSubstrate.t.sol`) as the engine Safe for the live EVC borrow loop. The CRE Forwarder push is `oracle.onReport("",
report)` under `vm.prank(forwarder)` (model `SzipBuyBurnModule.t.sol` NAV-push / `ExitGate.t.sol _pushBoth`).

**Do NOT**
- **Do NOT expose ANY generic `exec`/`call`/`multicall`/arbitrary-target passthrough, and never let the operator
  supply `to`/`data`/`operation`/`receiver`/`onBehalfOfAccount`/a vault/token/account address.** The operator passes
  **only scalar amounts** (`lpAmount` / `usdcAmount`). The module's only `exec` targets are the **set-once wired**
  `lpToken` / `escrowVault` / `borrowVault` / `usdc` / `evc` with **module-built calldata**, and every borrow/repay/
  withdraw `receiver`/`owner` and EVC `onBehalfOfAccount` is the **literal set-once `engineSafe`** (never a stored
  derivative, never a sub-account `addr ^ n`). This is the module's whole security boundary (§10.1; the 8-B14
  boundary extended to the EVC leg — security F5).
- **Do NOT `delegatecall`** (§10.1: `Operation.Call` only, `value == 0` on every `exec`).
- **Do NOT borrow to, or send the LP/USDC to, any address other than `engineSafe`** (never the operator, never
  Erebor — this is the engine, not a senior lien draw).
- **Do NOT use a fresh per-line `LineAccount` or grant the module/operator an EVC operator bit over the Safe.** The
  Safe borrows on **its own** EVC account; the module drives it via `exec` (Safe = EVC `msg.sender` = account owner).
- **Do NOT renounce the reservoir router/vault governance.** Keep `governor = TimelockController` (§4.5.1
  standing-tunable facility). This is the deliberate difference from WOOF-04's `transferGovernance(address(0))`.
- **Do NOT ship the reservoir borrow vault with an ungated `OP_BORROW`.** It IS the warehouse's shared resting USDC
  (depositors' idle cash) — without the `ReservoirBorrowGuard`, any ICHI-LP holder could post the escrow on their
  own account and lever the resting USDC (security F8a). The guard is REQUIRED, installed at deploy.
- **Do NOT make `borrowCap` operator-settable** (`onlyOwner`/Timelock). **`borrowCap` bounds AGGREGATE outstanding
  debt** (`debtOf(engineSafe) + usdcAmount`), not a single call (security F1). **Assert `owner != operator` in
  `setUp`.** Leave the inherited `setAvatar`/`setTarget` as zodiac-core `onlyOwner` (the operator/hot key cannot
  redirect; a Timelock redirect is a deliberate governed act — the accepted residual, as 8-B14). **Do NOT hard-lock
  them** (needs the vendored setters `virtual` — never edit `reference/`).
- **Do NOT read the LP's price from any spot AMM/pool on-chain, and do NOT bake a fixed mark into the oracle.** The
  LP mark is **CRE-pushed** (the locked decision); the oracle is a stale-checked cache; a stale/missing mark
  **fails the borrow closed** (the router `_getQuote` reverts).
- **Do NOT add an origination-seed/`setController` path to the LP oracle.** The only writer is the Forwarder push
  (`_processReport`). **Do NOT set `LP_MARK = 3`** (the registry's `REVALUATION`).
- **Do NOT edit anything under `reference/`** (pristine vendored tree). **Do NOT edit the kept `ExitGate` /
  `SzipNavOracle` / `ZipcodeOracleRegistry` / `CREGatingHook` / WOOF contracts** — 8-B5 is purely additive.
- **Do NOT use `immutable` for any `setUp`-decoded module value** (clone bytecode is shared). (The oracle, guard,
  and deployer are singletons — `immutable` is fine there.)

**Key requirements**

*A. `ReservoirLoopModule` (`is Module`).*
1. **`setUp(bytes initParams) public initializer`** decoding `(address owner, address engineSafe, address operator,
   address evc, address borrowVault, address escrowVault, address lpToken, address usdc, uint256 borrowCap)`.
   Require all addresses nonzero (`ZeroAddress`), `owner != operator` (`OwnerIsOperator`); set `avatar = engineSafe;
   target = engineSafe`; store `engineSafe/operator/evc/borrowVault/escrowVault/lpToken/usdc/borrowCap` (set-once,
   NOT immutable); `_transferOwnership(owner)`. `setBorrowCap(uint256) onlyOwner`. The mastercopy is init-locked at
   deploy.
2. **`onlyOperator` gate (§10.1 invariant 1).** `postCollateral`/`borrow`/`repay`/`withdrawCollateral` gated to the
   single set-once `operator`; a non-operator reverts `NotOperator()`.
3. **`postCollateral(uint256 lpAmount)` — loop steps 1–2** (the slice is already unstaked by 8-B6). Exactly **3**
   `exec`s, in order:
   - `if (lpAmount == 0) revert ZeroAmount();`
   - `exec(lpToken, 0, abi.encodeWithSelector(IERC20.approve.selector, escrowVault, lpAmount), Call)`
   - `exec(evc, 0, abi.encodeCall(IEVC.enableCollateral, (engineSafe, escrowVault)), Call)` (idempotent — re-enable
     is an EVC no-op)
   - `exec(escrowVault, 0, abi.encodeCall(IEVKERC4626.deposit, (lpAmount, engineSafe)), Call)`
   - `emit CollateralPosted(lpAmount);`
4. **`borrow(uint256 usdcAmount)` — loop step 3.** Exactly **2** `exec`s:
   - `if (usdcAmount == 0) revert ZeroAmount();`
   - `if (IBorrowing(borrowVault).debtOf(engineSafe) + usdcAmount > borrowCap) revert CapExceeded();`
     (**AGGREGATE** outstanding bound; `borrowCap == 0` ⇒ always reverts = kill-switch; the self-collateralizing
     size gate, §4.5.1 — security F1).
   - `exec(evc, 0, abi.encodeCall(IEVC.enableController, (engineSafe, borrowVault)), Call)` (idempotent).
   - `exec(evc, 0, abi.encodeCall(IEVC.call, (borrowVault, engineSafe, 0, abi.encodeCall(IBorrowing.borrow,
     (usdcAmount, engineSafe)))), Call)` — borrow on behalf of the Safe; receiver = the Safe. The EVC
     account-status check at the end of this `EVC.call` enforces health via the router → LP oracle. A borrow
     breaching `liqLTV` reverts `E_AccountLiquidity`; a stale/missing LP mark reverts in the router.
   - `emit Borrowed(usdcAmount);`
5. **`repay(uint256 usdcAmount)` — loop step 5.** Exactly **3** `exec`s:
   - `if (usdcAmount == 0) revert ZeroAmount();`
   - `exec(usdc, 0, abi.encodeWithSelector(IERC20.approve.selector, borrowVault, usdcAmount), Call)`
   - `exec(evc, 0, abi.encodeCall(IEVC.call, (borrowVault, engineSafe, 0, abi.encodeCall(IBorrowing.repay,
     (usdcAmount, engineSafe)))), Call)` (2nd arg `receiver` = `engineSafe`; the operator passes the **exact**
     owed strike — a literal `amount > owed` reverts `E_RepayTooMuch`, see C2).
   - `exec(usdc, 0, abi.encodeWithSelector(IERC20.approve.selector, borrowVault, 0), Call)` (reset the residual
     approval — repay may pull < `usdcAmount` at debt==0; leave no standing approval — security F13).
   - `emit Repaid(usdcAmount);`
6. **`withdrawCollateral(uint256 lpAmount)` — loop step 6.** Exactly **1** `exec` (after a `debtOf` view):
   - `if (lpAmount == 0) revert ZeroAmount();`
   - `if (IBorrowing(borrowVault).debtOf(engineSafe) != 0) revert DebtOutstanding();` (defense in depth — the EVC
     would block an unhealthy withdraw anyway; fail fast + make the invariant testable).
   - `exec(evc, 0, abi.encodeCall(IEVC.call, (escrowVault, engineSafe, 0, abi.encodeCall(IEVKERC4626.withdraw,
     (lpAmount, engineSafe, engineSafe)))), Call)` (release LP from escrow to the Safe; owner = receiver = Safe). The
     controller may stay enabled (next loop's `enableController` is idempotent); no `disableController` cleanup
     required.
   - `emit CollateralWithdrawn(lpAmount);`
7. **Views (8-B11/8-B12 back-pressure).** `outstandingDebt() view returns (uint256)` =
   `IBorrowing(borrowVault).debtOf(engineSafe)` (read live); `postedCollateral() view returns (uint256)` =
   `IEVKERC4626(escrowVault).balanceOf(engineSafe)`; the four events; `borrowCap` public getter. No persistent loop
   state beyond `borrowCap`.

*B. `SzipReservoirLpOracle` (`is ReceiverTemplate, BaseAdapter`).*
8. **The push-cache** (model on the registry — see "Model from"). ctor `(forwarder, quote_/*USDC*/, validityWindow_,
   lpToken_)`. `uint8 constant LP_MARK = 7`. `_processReport`: decode `(uint8 reportType, bytes payload)`; `if
   (reportType != LP_MARK) revert InvalidReportType(reportType)`; decode `(uint256 mark, uint32 ts)`;
   `_writePrice(mark, uint48(ts))` (fail-closed); `emit LpMarkUpdated(mark, ts)`. `_getQuote(inAmount, base,
   quoteAsset)`: `if (quoteAsset != quote || base != lpToken) revert NotSupported`; `if (cache.timestamp == 0) revert
   NotSupported`; staleness (`> validityWindow → TooStale`); `return ScaleUtils.calcOutAmount(inAmount, cache.price,
   scale, false)` (rounds DOWN — against the borrower). Renounce Ownable at deploy.
9. **`validityWindow`** is a generous engine-cadence window (CRE re-pushes each epoch; pin a deploy value — governed).
   A stale mark fails the borrow closed (safe direction), never opens an unsafe one.

*C. `ReservoirBorrowGuard` (`is IHookTarget`).*
10. Model **verbatim** on `CREGatingHook.sol`: immutable `eVaultFactory` + `engineSafe`; `isHookTarget()` returns the
    selector only when `eVaultFactory.isProxy(msg.sender)`; `_msgSender()` extracts the EVK-appended account (the
    `isProxy`-guarded assembly); `fallback()`: `if (_msgSender() != engineSafe) revert NotEngineSafe();`. Op-agnostic
    (installed only on `OP_BORROW`, so it only ever guards borrows). Non-payable.

*D. `ReservoirMarketDeployer` (script/library).*
11. **`deploy(GenericFactory factory, address evc, address governor, address lpToken, address usdc, address
    lpOracle, address irm, address engineSafe, uint16 borrowLTV, uint16 liqLTV)` returns `(address escrowVault,
    address borrowVault, address router)`** — the one-time wiring (model WOOF-04 `openLine` steps 1–3, **router THEN
    borrow vault**, governor RETAINED):
    - **PREREQUISITE (C4):** a fresh CRE LP mark MUST already be pushed to `lpOracle` — `setLTV` below validates the
      collateral price via `router.getQuote` at config time, so a missing mark reverts the deploy.
    - `escrow = factory.createProxy(address(0), false, abi.encodePacked(lpToken, address(0), address(0)))`;
      `setHookConfig(0,0)`; `setGovernorAdmin(0)`.
    - `router = new EulerRouter(evc, address(this))` — the **deployer is router governor AT BIRTH** (to configure);
      `router.govSetResolvedVault(escrow, true)`; `router.govSetConfig(lpToken, usdc, lpOracle)`.
    - `guard = new ReservoirBorrowGuard(factory, engineSafe)`.
    - `borrowVault = factory.createProxy(address(0), false, abi.encodePacked(usdc, address(router), usdc))`;
      `setInterestRateModel(irm)`; `setHookConfig(address(guard), OP_BORROW)`; `setLTV(escrow, borrowLTV, liqLTV, 0)`.
      (The borrow vault is created HERE — it is the reservoir's USDC vault; in production the EE supply queue
      allocates idle depositor USDC into it, see Obligations.) The borrow vault governor stays the deployer/
      caller (then handed to the Timelock) — NOT renounced — so LTV/caps stay tunable.
    - **`router.transferGovernance(governor)` — RETAIN at the Timelock (C4).** This is the WOOF-04 inversion:
      `transferGovernance(timelock)`, NOT `transferGovernance(address(0))`. The router is now governed by the
      Timelock (re-pointable under the 2-day veto), never frozen.
    - Birth-time wire-check (model WOOF-04 `_assertWired:179`): `router.resolveOracle(1e18, escrow, usdc)` resolves to
      `(·, lpToken, ·, lpOracle)` → else revert `WireMismatch`. (Expose a deliberately-mis-wiring harness subclass
      for the negative test — model `MisWiringAdapter`.)

**Done when**
- `forge build` green (the second zodiac-core module; the registry-shaped LP oracle; the `CREGatingHook`-shaped
  guard; no OZ collision — the module uses zodiac Ownable, the oracle OZ-5 Ownable, never mixed in one contract).
- `forge test --fork-url $BASE_RPC_URL --match-contract ReservoirLoopModuleTest` green, covering:
  - **the full loop on a live Base fork (the headline test):** real `GenericFactory`/`EVC`/`EulerRouter`; a real
    summoned substrate Safe as the engine Safe; the module `enableModule`'d on the Safe (team-owner drives it); the
    deployer stands up escrow+router+borrowVault+guard; the borrow vault seeded with USDC (`deal` + a supplier
    `deposit`); an 18-dp stand-in LP dealt to the Safe; the CRE Forwarder pushes a fresh LP mark. Then drive, as
    operator: `postCollateral(slice)` → `postedCollateral() == slice`, collateral enabled; `borrow(strike)` → Safe's
    USDC += strike, `outstandingDebt() == strike`, controller enabled; `repay(strike)` → `outstandingDebt() == 0`,
    `IERC20(usdc).allowance(engineSafe, borrowVault) == 0`; `withdrawCollateral(slice)` → LP back to the Safe,
    `postedCollateral() == 0`. **Run the loop twice** to prove it revolves.
  - **idempotent enable (revolve):** after the 2nd loop, `evc.getCollaterals(engineSafe)` length == 1 and
    `evc.getControllers(engineSafe)` length == 1 (no duplicate enable) — QA #8.
  - **live views mid-loop:** after `borrow`, `outstandingDebt() == strike == IBorrowing(borrowVault).debtOf(safe)`
    (the view reads the vault, not a cached field) — QA #22.
  - **the self-collateralizing gate (pinned magnitudes, right step, boundary — gated on `borrowLTV`, C3):** push
    mark so 1 LP = $1 (`getQuote(1e18,lp,usdc)==1e6`), `postCollateral(100e18)` ($100 collateral), `setLTV(escrow,
    0.7e4, 0.8e4, 0)`; a **healthy** `borrow(69e6)` succeeds (< $70 `borrowLTV` — proves `enableController` works +
    the boundary), then `borrow` taking the total over $70 reverts the EVK `E_AccountLiquidity.selector` (import EVK
    `Errors`); plus a **no-collateral-posted** `borrow(>0)` reverts `E_AccountLiquidity` (QA #1/#2/#11).
  - **fail-closed oracle (two distinct paths, named selectors):** **never-pushed** mark → `borrow` reverts
    `PriceOracle_NotSupported` (bubbled from the router); **stale** mark (push, `warp(validityWindow+1)`) → `borrow`
    reverts `PriceOracle_TooStale` (QA #3).
  - **aggregate cap / kill-switch (boundary):** with debt 0, `borrow(borrowCap)` exactly **succeeds**; a further
    `borrow(1)` reverts `CapExceeded`; `borrowCap == 0` ⇒ every `borrow` reverts; `setBorrowCap` is `onlyOwner`
    (QA #13, security F1).
  - **withdraw guards:** `withdrawCollateral` with `outstandingDebt() != 0` reverts `DebtOutstanding`; `lpAmount >
    postedCollateral()` (debt 0) reverts (insufficient escrow — pin whether EVK or guard) (QA #10).
  - **exact-repay clears + resets, over-repay reverts (C2):** borrow `strike`, `repay(strike)` → `outstandingDebt()
    == 0` and `allowance(engineSafe, borrowVault) == 0` afterward; a literal `repay(strike + delta)` reverts
    `E_RepayTooMuch` (EVK does NOT silently cap a literal amount) (QA #9 / security F13).
  - **the borrow guard (security F8a — third-party borrow blocked):** a third-party account that holds the stand-in
    LP, deposits it into the reservoir escrow on its OWN account, enables controller+collateral, and attempts to
    `borrow` directly via the EVC → reverts at the guard (`NotEngineSafe` / hook revert); the engine Safe's borrow
    (through the module) passes the same guard. Also: `guard.isHookTarget()` returns the selector only for a factory
    proxy.
  - **governor RETAINED (the §4.5.1 invariant — inverted from WOOF-04):** assert `EulerRouter(router).governor() ==
    governor` (NOT `address(0)`), and that the governor can still `govSetConfig` (re-pointable); contrast the kept
    WOOF-04 test asserting its router is frozen to 0 (QA #20).
  - **negative wire-mismatch:** a deployer wired to the WRONG lpOracle/lpToken trips `WireMismatch` (mis-wiring
    harness, model `MisWiringAdapter`) — proves the birth wire-check actually catches a cross-wire (QA #19).
  - **authority / shape:** non-operator entrypoints revert `NotOperator`; non-owner `setBorrowCap` reverts; the
    **operator (and any non-owner) cannot redirect the Safe** — `setAvatar`/`setTarget` revert
    `OwnableUnauthorizedAccount`; `setUp` callable once (`initializer`); `owner == operator` in `setUp` reverts
    `OwnerIsOperator`; at least one per-field `ZeroAddress` case (e.g. `evc == 0`); the **mastercopy is inert**
    (`mc.operator() == address(0)` && `mc.engineSafe() == address(0)`, every entrypoint reverts `NotOperator`)
    (QA #16/#17).
  - **exec discipline (recording mock — THE security-boundary test, exhaustive — QA #6/#7, security F5/F15):** per
    entrypoint, assert the **exact `callCount()`** (postCollateral 3 / borrow 2 / repay 3 / withdrawCollateral 1) AND
    that **every** recorded call is `Operation.Call` with `value == 0` targeting only the wired
    `lpToken`/`escrowVault`/`borrowVault`/`usdc`/`evc` with the expected module-built calldata; **decode the inner
    `IEVC.call` calldata** and assert `targetContract == borrowVault`/`escrowVault`, `onBehalfOfAccount ==
    engineSafe`, inner `value == 0`, and the innermost `borrow`/`repay`/`withdraw` `receiver`/`owner` == `engineSafe`
    (proves a `borrow(amt, operator)` regression cannot hide behind the outer `to == evc` shape).
  - **atomicity / rollback (recording mock `setFailOnCallIndex`, model 8-B14):** force the `deposit` exec in
    `postCollateral` to revert → assert the `approve` + `enableCollateral` rolled back (no standing LP allowance, no
    dangling collateral-enable); force the `EVC.call(repay)` exec to revert → assert the `approve` rolled back
    (QA #21).
  - **LP oracle unit tests:** a Forwarder push sets the mark; `getQuote(1e18, lpToken, usdc)` == the exact 6-dp
    value, and `getQuote(5e17, …)` == the exact half (scale on a fractional share); a **non-divisible** mark×inAmount
    floors against the borrower (model `test_price_bound_boundary_non_divisible`); a non-Forwarder push reverts; a
    wrong reportType reverts `InvalidReportType`; `base != lpToken` / `quoteAsset != usdc` revert `NotSupported`;
    `mark == 0` / `ts > now` revert (fail-closed); after `validityWindow` a read reverts `TooStale`; `LP_MARK != 3`
    (QA #4/#5/#18, security F10/F11).
  - **escrow 1:1 share accounting:** assert `IEVKERC4626(escrow).convertToAssets(1e18) == 1e18` (bare box) so
    `postedCollateral()` (shares) == posted LP-asset amount (QA #12).
  - **reentrancy / gas disposition (state, don't hand-wave):** the loop holds NO internal accumulator (debt + posted
    collateral are read live from the vaults), targets are wired/trusted (EVC, EVK vaults, USDC, the wired LP token),
    and `escrow` is `setHookConfig(0,0)` — so classic reentrancy is low-risk; the report states this reasoning. No
    user-supplied arrays → no gas-griefing surface (QA #14/#15).
  - **no regression:** the full suite green (prior count + these).
- Code committed under `contracts/src/supply/szipUSD/ReservoirLoopModule.sol` +
  `contracts/src/supply/SzipReservoirLpOracle.sol` + `contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol` +
  `contracts/script/ReservoirMarketDeployer.sol` + `contracts/test/ReservoirLoopModule.t.sol`, kept. Mapped to
  `audit/2.md` (an L-step: the harvest loop post→borrow→repay→withdraw; N-steps: over-LTV / stale-mark / over-cap /
  non-operator / third-party-borrow revert) + an `audit/3-results.md` authority row — **audit-sweep obligation, below.**

**Depends on**
- **8-B1 substrate** (the engine Safe + sidecar; unit-tested against a recording mock Safe, fork-tested against the
  real summoned Safe). · **zodiac-core `Module`** (8-B14). · **`ReceiverTemplate` + `BaseAdapter`** (the registry). ·
  **`IHookTarget`** (`CREGatingHook`). · the **EVK/EVC/EulerRouter** stack (WOOF-04).
- **Downstream:** 8-B6 (unstakes before `postCollateral`, re-stakes after `withdrawCollateral`); 8-B8 (spends the
  borrowed strike); 8-B9 (HYDX-sale proceeds fund `repay`); 8-B11 (the CRE op surface drives all four entrypoints +
  pushes the LP mark); 8-B12 (monitors `outstandingDebt`/`postedCollateral`); item-10 deploy (CREATE2-clone the
  module via `ModuleProxyFactory`, `enableModule` on the engine Safe, `setUp` with the wired market + governed
  `borrowCap`, `owner = TimelockController != operator`, init-lock the mastercopy; run `ReservoirMarketDeployer`;
  deploy + renounce the LP oracle; wire the CRE workflow as both the module operator AND the LP-oracle Forwarder
  source).

**Inbound cross-ticket obligations discharged by this ticket**
None owed by 8-B5 in `PROGRESS.md → Open cross-ticket obligations` (the table is owed by items 3/5/6/10/CRE/WOOF-00 —
confirmed by the spec-fidelity critic). 8-B5 is a downstream consumer + creates new obligations (below).

**New cross-ticket obligations this item creates** (log in `PROGRESS.md` at Conclude)
- **(owed by 8-Bw / item-10 deploy)** the EE supply queue MUST allocate idle depositor USDC into the reservoir
  **borrow vault** the deployer creates (so it IS the warehouse `USDC Resting Vault`), and the deploy MUST set the
  module's `borrowVault` to that address + keep its governor at the Timelock (LTV/caps tunable). The fork test proves
  the wiring against a directly-seeded borrow vault; production points EE at it.
- **(owed by the CRE track, `spec-clear-CRE.md` §8)** register the **`LP_MARK` reportType** (pinned `7` in the built
  oracle) in the §8 report ABI alongside the §4.4 lien types, and have the CRE strategy workflow (8-B11) compute the
  per-LP-share mark from the same reserve×price math `SzipNavOracle` uses and push it each epoch (within
  `validityWindow`). **This is the one SPEC-GAP the spec-fidelity critic surfaced** — it is CRE-§8 territory (still
  TODO), so 8-B5 pins a placeholder and routes it here rather than inventing the registry.
- **(owed by item-10 / 8-B11)** wire the **single CRE operator** as the module's `operator` (the only caller of the
  four entrypoints) AND ensure the LP-oracle Forwarder push is on the engine cadence; the engine Safe must be the EVC
  account whose borrow/collateral the module drives.

**Audit-sweep obligation (this item creates it)**
Author the harvest-loop borrow into `audit/2.md` Phase L (an L-step: operator `postCollateral` → `borrow` strike →
[exercise/sell off-harness] → `repay` → `withdrawCollateral`, debt round-trips 0→strike→0; N-steps: over-LTV /
stale-LP-mark / over-cap / non-operator / **third-party-direct-borrow (guard)** each revert) + the matching
`audit/3-results.md` authority rows (operator-only entrypoints; owner-only `borrowCap`; `setAvatar`/`setTarget`
locked; the reservoir governor retained at the Timelock; the `OP_BORROW` guard pins the Safe). Touch `audit/*` only
as a consequence of this build landing.
