# tickets/LEDGER.md — component digest for final big-picture review

**Purpose.** One entry per net-new component, written as each ticket is authored, so the design can be
**validated as a whole at the end** without re-reading every ticket. This is the *review* artifact; the
*process* state (DONE/NEXT, session log, spec-gap triage) lives in `PROGRESS.md`. Each entry: **what it does ·
locked shape · holes the harness surfaced → resolution · cross-ticket obligations** (things this ticket
deliberately pushed to another ticket — verify at the end that each is actually picked up there).

> Maintained as part of the per-item **Conclude** step (`audit/adversarial-spec/README.md` §6): when an item is
> filed, add/extend its entry here.

---

## Authored

### WOOF-00 — Foundry scaffold  ·  §16 / README §7  ·  `tickets/woof/WOOF-00-scaffold.md`
- **What it does.** The buildable skeleton every later contract writes into: `foundry.toml`, `remappings.txt`,
  `.env.example`, and the `src/` tree (`venue/ supply/ loss/` + named top-level stubs) per README §7. No protocol logic.
- **Locked shape.** solc **0.8.24**, `evm_version=cancun`, `optimizer_runs=20000`; `allow_paths=["../reference"]`;
  an **exact 9-line `remappings.txt`, no comment lines**; all OZ/forge-std/permit2 dedup to the single
  `euler-vault-kit/lib` copy; SPDX **`GPL-2.0-or-later`** on every protocol file; `reference/` read-only (submodule
  init is a one-time prerequisite, not part of the build loop).
- **Holes → resolution.** (a) A single-file EVC import is not a sufficient build probe — it hides the OZ/EVC dedup
  that actually breaks; the self-check pins an `ESynth`+`BaseAdapter` cross-repo probe. (b) SPDX license was
  unpinned (cold-build had to guess) → **pinned `GPL-2.0-or-later`** (imports GPL evk code; GPL-compatible with OZ MIT).
- **Cross-ticket.** Each later ticket adds only the remap lines it needs (e.g. `ReceiverTemplate` alias is the
  controller/registry ticket's job, not here).
- **EXTENDED 2026-06-06 (superintendent holistic audit) — Euler-only → complete multi-ecosystem scaffold.** The
  item-8/8-Bw/bridge design added Baal, Zodiac (Roles v2 + zodiac-core), Gnosis Safe, Chainlink CCIP/Subtensor,
  ICHI, Hydrex/Algebra. Root problem surfaced: **Baal/Zodiac/Safe are npm/Hardhat-based and pin OZ 4.8.3/4.9.3,
  colliding with Euler's OZ 5.0.2** (4.x↔5.x breaking) — they cannot be source-compiled alongside Euler.
  **Resolution = Strategy A (interface + fork, user-locked):** never compile their OZ-4.x source — author minimal
  local interfaces (`src/interfaces/{safe,baal,zodiac,ichi,hydrex,algebra}`) + fork live **Base mainnet** for the
  real deployments. Tiers: **compiled** = Euler (OZ 5.0.2, unchanged) + OZ-free `zodiac-core` `Module`/`factory`
  (one new remap) + (the **bridge exception**) Chainlink CCIP base, whose OZ/solc compat is re-verified in the 8x
  window; **interface+fork** = Baal/Roles/Safe/ICHI/Hydrex. Adds a Base-mainnet fork RPC (`base`),
  `script/BaseAddresses.sol` (validated candidate addresses — re-pin on Basescan), `test/ForkConfig.sol`, and a
  **3-part cross-ecosystem probe** (Euler OZ-5 + local interfaces + OZ-free zodiac-core coexist with NO
  OZ-collision; a fork-read against a real Base address).
- **MATERIALIZED + BUILDS GREEN ON DISK 2026-06-06 (the keep-the-build doctrine flip).** The scaffold is now real
  under `contracts/`: `forge build` clean (52 files, solc 0.8.24), all 3 self-checks pass incl. a **live
  Base-mainnet fork read**. Building it for real (instead of doc-auditing it) exposed what the prose layer hid and
  all were fixed on disk + verified against the live chain: a CRE-selector contradiction; **10 of 25 guessed
  external interface signatures wrong** (ICHI `getICHIVault`/`createICHIVault`, IVoter `vote`, `createLock`,
  `exerciseVe`, NFPM `mint`/`positions`, …); and **2 "CONFIRMED" addresses that were the wrong contract** — ICHI
  "factory" `0x7d11…` was a Gnosis Safe (real `0x2b52c416…`); Baal summoner labels scrambled (real `BaalSummoner`
  `0x22e0…`, vs `reference/Baal/deployments/base/*.json`). The materialized scaffold is **committed, NOT
  discarded** — the old "reset `contracts/` to `.gitkeep`" rule is retired (it caused the unverifiable rotted
  "cold-build PASSED, discarded" claims). For anything verifiable, the **code is the source of truth, not the
  ticket**. (Doctrine in `nextsteps.md` + `audit/adversarial-spec/README.md` + `superintendent.md`.)

### WOOF-01 — `LienCollateralToken` + `LienTokenFactory`  ·  §4.2  ·  `tickets/woof/WOOF-01-lien-collateral-token.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone, `forge build` green (solc
  0.8.24) + **14/14 unit tests pass** (independently re-run); code kept at `contracts/src/{LienCollateralToken,
  LienTokenFactory}.sol` + `contracts/test/LienToken.t.sol`. The real build confirmed the ticket is a true
  zero-spec-guess keepsake (all OZ/Create2 citations accurate; the 0.8.24 `if/revert` gotcha honored; the `pure`
  decimals narrowing compiles) — **no contradiction or wrong address/signature surfaced** (unlike WOOF-00).
- **What it does.** The 1/1 collateral primitive every isolated lien market is built on. **Token:** a plain ERC20,
  fixed supply **exactly `1e18` @ 18 decimals** minted once to the controller at construction, constant
  name/symbol (`"Zipcode Lien Collateral"`/`"zLIEN"`), `burn` controller-only; a lien's **identity is the token
  address**. **Factory:** deploys tokens via **CREATE2** (`salt = keccak256(abi.encode(lienId))`) so the address
  **precomputes** before origination; `create(bytes32 lienId)` binds authority to the caller; `computeAddress(lienId,
  controller)` is the two-arg precompute view; `LIEN_DECIMALS()==18` is the canonical decimals pin.
- **Locked shape.** Plain OZ `ERC20` (**not** ESynth/EVCUtil — wrong shape); **net-new** CREATE2 factory (**not**
  EVK `GenericFactory`, which has no salt); `decimals()` pinned via a `pure` override; **no public `mint`** (supply
  is structurally fixed by the single constructor mint); `burn` from the controller's **own** balance; no admin/`Ownable`.
- **Holes → resolution.** (a) §4.2 read "the factory grants the controller mint authority," implying a factory-held
  controller immutable — but the controller constructor takes `lienFactory`, so the factory deploys first →
  **deploy-order circularity**. Resolved by making `create` **caller-bound** (`controller := msg.sender`), and the
  spec was rewritten. (b) `require(cond, CustomError())` **does not compile on 0.8.24** (it's 0.8.26+) → use
  `if (!cond) revert`. (c) Then **simplified two-arg `create(lienId, controller)`+gate → one-arg `create(lienId)`**:
  strictly simpler and **inherently squat-proof** (an attacker's `create` derives a *different* address, can never
  occupy `LIEN_i`), aligning with the pre-existing §9 trace. Cold-build: 14/14 tests incl. the squat-proof test.
- **Cross-ticket obligations (verify these land elsewhere).** (1) **Burn-custody sequencing** — at close the
  controller must reclaim the `1e18` from `EVAULT_i` *before* `burn` (else `ERC20InsufficientBalance`): **controller
  ticket §4.4c**. (2) The registry must validate a registered key's `decimals()` against `LIEN_DECIMALS` before
  caching: **registry ticket §4.1**. (3) Collateral registration via `setLTV` / market wiring: **venue ticket §4.7**.

### WOOF-03 — `CREGatingHook`  ·  §4.3  ·  `tickets/woof/WOOF-03-cre-gating-hook.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone, `forge build` green + **8/8
  unit tests pass** (independently re-run; 56/56 across all suites, no regression); code kept at
  `contracts/src/CREGatingHook.sol` + `contracts/test/CREGatingHook.t.sol`. Confirmed: `borrowDriver` immutable
  (not `controller`), operator-auth gate, `NotAuthorizedOperator()` = `0x3d9adf1c`, verbatim isProxy-guarded
  assembly `_msgSender()`, and the spoof-guard rejecting a non-proxy appended-account. Zero-spec-guess keepsake —
  every reference citation accurate (EVC `:286`, `Base.sol`, `Constants`, `GenericFactory.isProxy`, `IHookTarget`).
> **RE-AUTHORED 2026-06-05 (borrower-model, Step 2a), then RECONCILED 2026-06-05 (borrow-driver fix).** The old
> digest gated on `EVC.haveCommonOwner(caller, controller)` (owner check, borrowers = controller sub-accounts). The
> borrower-of-record rework (Step 1) replaced that with an **operator-authorization** gate; the borrow-driver
> reconciliation then **renamed the gated immutable `controller` → `borrowDriver`** and points it at the **adapter**
> (the `EVC.call` caller), not the controller contract. This digest is the reconciled one.
- **What it does.** The EVK `IHookTarget` hook that makes the **borrow-driver** (the `EulerVenueAdapter`) — as the
  **EVC operator** of each line's fresh per-line borrow account — the **sole** party able to `borrow`/`liquidate`
  on the lien markets; `repay` stays **permissionless**. Installed at `OP_BORROW | OP_LIQUIDATE`; the `OP_LIQUIDATE`
  gate is **purely defensive** (blocks external seizure of an interest-underwater line — there is **no on-chain
  economic liquidation**).
- **Locked shape.** Three constructor immutables (EVK `GenericFactory`, EVC, **`borrowDriver`**); ctor
  `constructor(address eVaultFactory, address evc, address borrowDriver)`. `isHookTarget()` returns the selector
  (`0x87439e04`) **only when `GenericFactory.isProxy(msg.sender)`**; **guarded `_msgSender()`** extraction (trust the
  appended 20-byte caller — the EVC on-behalf borrow account, `Base.sol:87,89,132` — only if `msg.sender` is a
  factory proxy); the gate is **`EVC.isAccountOperatorAuthorized(caller, borrowDriver)`**
  (`EthereumVaultConnector.sol:286`, internal `:1205-1221`) — an **operator-authorization** check, NOT an owner
  check or equality. The appended caller is the `account` arg, the immutable **`borrowDriver`** the `operator` arg —
  and `borrowDriver` is the address that makes the `EVC.call(borrowVault, borrowAccount, …)`, i.e. the **adapter**
  (== the controller **only if** M1 collapses them). **Replicates `BaseHookTarget` inline** (`:26-41`; evk-periphery
  is not remapped, so it can't be inherited). Named custom error **`NotAuthorizedOperator()`** (`0x3d9adf1c`) →
  surfaced by the EVK as `HookReverted`; returns no data.
- **Holes → resolution.** (a) **Gate change** — each line borrows on a fresh per-line account with its **own**
  prefix (§4.4), so any owner check (`haveCommonOwner`/`getAccountOwner`/equality) is **false for every line** →
  must use the EVC **operator-authorization** check, which fails closed for an unregistered prefix
  (`isAccountOperatorAuthorizedInternal :1213`) and otherwise checks `operatorLookup[prefix][operator]` (`:1220`),
  so `operator` must be the **exact `EVC.call` caller = the adapter**. (b) **Naming footgun (the reconciliation)** —
  the immutable was named `controller`, but the EVC authenticates the **adapter** (the `EVC.call` `msg.sender`) as
  the operator → renamed **`borrowDriver`** and wired to the adapter; wiring it to the controller contract (when
  distinct) would reject every borrow. (c) Unconditional caller extraction is **spoofable** → gate it on `isProxy`
  (proven by the non-proxy-spoof test: the guard falls back to `msg.sender`, not the appended bytes). (d) Listing
  only EVC+borrowDriver yields an `isHookTarget` that can't validate the vault → the **factory immutable is required**.
- **Security note.** The operator-auth gate is **at least as strong as, and strictly more isolated than**, the old
  owner check (§4.4: one operator grant per line over its own prefix — no shared sub-account space). Only an account
  whose per-line `LineAccount` granted the **borrow-driver (adapter)** the operator bit can borrow/liquidate.
- **Cross-ticket.** Installing the hook (`setHookConfig`) + the live N1/N1b/L4 end-to-end is the **deploy/wiring
  ticket** (audit/2.md S5/S6/S9); the deploy must wire the hook's **`borrowDriver`** immutable to the **adapter**
  address (circular with the hook-before-adapter deploy order → precompute/two-pass). The live operator grant on
  each line is **WOOF-04**'s `openLine`/`LineAccount` (grants the **adapter**). The contract + its unit test are
  provable in isolation with a mock `GenericFactory` + a mock EVC (`isAccountOperatorAuthorized`). Cold-build (both
  the re-author and the reconciliation): `forge build` clean, **6/6** tests green (reconciliation run).

### WOOF-02 — `ZipcodeOracleRegistry`  ·  §4.1  ·  `tickets/woof/WOOF-02-oracle-registry.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone (multiple inheritance
  `is ReceiverTemplate, BaseAdapter` + 2 new remaps), `forge build` green + **34/34 unit tests pass**
  (independently re-run, no WOOF-00/01 regression); code kept at `contracts/src/ZipcodeOracleRegistry.sol` +
  `contracts/test/ZipcodeOracleRegistry.t.sol`. Confirmed on-chain-shape: the `calcScale(18,quoteDec,quoteDec)`
  convention gives `getQuote(1e18,LIEN,USDC)==equityMark` exact; the strict-decimals staticcall rejects a 6-dp
  token AND a code-less EOA on both write paths. Zero-spec-guess keepsake — every `ReceiverTemplate`/`BaseAdapter`/
  `ScaleUtils`/`IPriceOracle` citation accurate; no `supportsInterface` collision; OZ-v5 pin holds.
- **What it does.** ONE multi-asset push-cache price adapter (`is ReceiverTemplate, BaseAdapter`) that prices
  every lien token at its **Proof-of-Value** mark, behind a stale-checked `BaseAdapter`/`IPriceOracle` read face
  the EVK router falls back to. **Two write paths into one `cache`:** a **controller-gated `seedPrice`** (single
  lien, `block.timestamp`, atomic with the controller's origination batch) and a **Forwarder-gated
  `_processReport`** (batch revaluation, off the controller's surface). Event-driven (no heartbeat), long
  line-term `validityWindow` checked only at read.
- **Locked shape.** `struct Cache {uint208 price; uint48 timestamp}`; one **immutable `Scale`** for all liens =
  `calcScale(18, quoteDecimals, feedDecimals=quoteDecimals)` → `getQuote(1e18, LIEN, USDC) == equityMark`
  (equityMark in USDC's 6 native decimals; `bid==ask==mid`). Fail-closed per-write guards: `price!=0`,
  `≤uint208.max`, **strict** `decimals()==18` (low-level staticcall — NOT silent-18 `_getDecimals`), `ts≤now`;
  **no on-chain value band** (§4.1 — integrity is upstream). Set-once `setController` (deploy-order: registry
  before controller). Forwarder made immutable by **renounce** (base setters are non-virtual — can't override).
- **Holes → resolution.** Five §4.1 under-specs, all confirmed faithful gap-closures by the critics (not
  invention): (a) controller seed + set-once controller (deploy-order circularity, mirrors §4.2 factory); (b)
  two-stage report decode (envelope `reportType==3` then payload + length check); (c) strict-decimals guard
  (the `_getDecimals` silent-18 footgun would no-op it); (d) the scale/equityMark-units convention; (e) a
  `ts>now` sanity guard (units, not a value band). **Plus** the cross-cutting fix: "override `setForwarderAddress`
  to revert" is **unimplementable** (base non-virtual) → corrected to renounce-based immutability at five spec
  sites + the audit harness; S11 gains a **hard pre-gate** (assert identity set + controller set before renounce,
  security F7). Cold-build: 24/24 tests, scale identity verified exact.
- **Cross-ticket obligations (verify these land elsewhere).** (1) **Discharged here:** WOOF-01's
  decimals()==LIEN_DECIMALS validation (strict guard, both paths). (2) **Owed to item 6 controller:** call
  `seedPrice` inside the atomic origination batch (`create→seed→setLTV→borrow`). (3) **Owed to item 10
  deploy/wiring:** `setController` at S6; S11 pre-gate (`getExpectedWorkflowId()!=0` && `controller()!=0` before
  renounce); `govSetFallbackOracle` at S10. (4) **Owed to CRE track:** gas-bounded sharding of revaluation
  reports (on-chain batch is atomic — one bad entry reverts the cohort).

### WOOF-04 — `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount`  ·  §4.7  ·  `tickets/woof/WOOF-04-venue-adapter.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone against the live WOOF-00
  scaffold; `forge build` green (solc 0.8.24) + **20/20 new tests pass on a live Base-mainnet fork** (76/76 total,
  no WOOF-00/01/02/03 regression — independently re-run by the superintendent). Code kept at
  `contracts/src/venue/{IZipcodeVenue,LineAccount,EulerVenueAdapter}.sol` + `contracts/test/EulerVenueAdapter.t.sol`.
  EVK/EVC/EulerRouter LIVE; `EulerEarn` MOCKED (0.8.26 pragma). **Live-fork-proven:** the two-line distinct-prefix
  BOTH-draw isolation (real `evc.batch` borrows, `debtOf` each correct + cross-independent), the operator-grant
  authorizes-the-adapter assertion (`isAccountOperatorAuthorized(borrowAccount, adapter)==true`), foreign-account
  hook rejection, AmountCap round-trip (read back via `EVault.caps()`), the `!=1e18` guard, router freeze, and
  close-reclaim. Every external interface signature + the AmountCap encode re-verified against `reference/` before
  keeping (**zero discrepancies** — `setAccountOperator:364`, code-free `:787`, self-call `:888-895`, op-auth
  `:903`, `call:553` 4-arg, `EulerRouter` `:47/:56/:69/:123`, `AmountCap:18-28`, `IEulerEarn`
  reallocate/submitCap/acceptCap/setSupplyQueue/supplyQueueLength/supplyQueue, `MarketAllocation{IERC4626 id;
  uint256 assets}`). **Zero spec-guesses;** 1 mild ticket cap-seed clarification folded (step 4 `capSeed =
  type(uint136).max`, mock-level). The hook<->adapter deploy cycle is the existing item-10/WOOF-03 precompute
  obligation (now empirically confirmed). `fund` + F3 onboarding are mock-level (live EE path = audit S9/L4).
  **DISCHARGES** the item-5 inbound obligation (lien-as-collateral `setLTV` on `COLLAT`, asserted live).
> **RE-AUTHORED 2026-06-05 (borrower-model, Step 2b) — supersedes the sub-account version.** The borrower account
> changed: `sub_i = controller XOR subId` controller sub-account (+ `subId` counter + blanket `setOperator(prefix,
> venue, ~uint256(1))`, 255-line cap, hook gated `haveCommonOwner`) → a **fresh per-line `LineAccount`** that grants
> the EVC operator bit over its own code-free borrow account; the hook (WOOF-03 re-authored) gates on
> `isAccountOperatorAuthorized`. Cold-build = **YES, 15/15**. Everything else carries forward unchanged.
- **What it does.** The venue-neutral seam (`IZipcodeVenue`: `openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/
  `closeLine`/`liquidate`, no Euler types) + the Euler config-one realization, a **per-line isolated-market factory**.
  Per credit line, `openLine` mints + aligns + freezes, in one atomic call: a **fresh per-line borrower account**
  (CREATE2 **`LineAccount`**, salt = `lienId`, whose ctor grants the operator bit), an **escrow collateral vault**
  (holds the lien), an **isolated USDC borrow vault** (the lending vault, EulerEarn-funded), and a **dedicated
  `EulerRouter`** wired `escrowVault→LIEN_i→registry` then `transferGovernance(0)`-frozen. The adapter holds the Euler
  roles (EulerEarn allocator+curator, per-line market governor) and is each line's **EVC operator** (granted by that
  line's `LineAccount`, NOT a blanket controller-prefix grant).
- **Locked shape.** **Per-line isolated markets** (EdgeFactory pattern — verified) with the per-line router **frozen at
  birth** (supersedes the shared-router "F4"); **oracle key stays `LIEN_i`** (WOOF-02 unchanged). **Borrower-of-record =
  a fresh per-line `LineAccount` prefix** (the `LineAccount` ctor does `EVC.setAccountOperator(borrowAccount, operator,
  true)` for `borrowAccount = address(lineAccount) ^ 1`, a code-free sub-account it owns — owner-self path
  `EthereumVaultConnector.sol:364-401`, code-free guard `:787`, prefix registered `:772-774`). **The granted operator =
  the §4.3 hook's `controller` immutable = the address that makes the `EVC.call` = the ADAPTER** (the controller drives
  the borrow through `IZipcodeVenue.draw`; spec-clarified in §4.3/§4.4/§4.7/§17). `draw` = `EVC.batch([enableController
  self-call, enableCollateral self-call, IBorrowing.borrow]` on-behalf of `borrowAccount`); `closeLine` redeems the lien
  via the operator-routed `EVC.call`. **No `subId` field, no `nextSubId` counter, no blanket grant.** Every mutating
  method `onlyController`; `draw` receiver pinned to immutable Erebor; `liquidate` = defensive `NotImplemented` stub
  (§4.4e); `collateralAmount == 1e18` (full-lien) guard.
- **Holes → resolution.** (a) **Operator identity** (the one re-author hole) — the EVC authenticates the operator
  against the `EVC.call` `msg.sender`, which is the **adapter** (not the controller); so the `LineAccount` grants the
  adapter and the hook's `controller` immutable is wired to the adapter (spec clarified; the §4.4 "controller borrows as
  operator" prose = the abstract borrow-driver). (b) `borrowAccount` must be code-free (sub 1), never the `LineAccount`'s
  own coded address (`:787`). (c) hook<->adapter immutables are circular → deploy resolves by precompute (test uses
  `vm.computeCreateAddress`; item 10 does the real two-pass). Carried forward unchanged from the sub-account version:
  `fund`'s two-item absolute `reallocate` from `baseUsdcMarket` (EulerEarn has **no** idle concept); `draw` receiver
  pinned to Erebor; adapter-as-curator scoped (only onboards its own vault) + production-hardening flag; AmountCap
  `(mantissa<<6)|exponent` round-up + reject-0; EVC self-call vs vault-call encoding; `closeLine` operator-routed redeem;
  `abi.encodeCall(IBorrowing.borrow,…)`; EulerEarn mocked (pragma 0.8.26). Cold-build: `forge build` clean, **15/15**
  incl. the live **two-line distinct-`LineAccount`-prefix both-draw**, the grant-authorizes-the-adapter assertion, the
  foreign-account hook rejection (a stand-in hook reverting `NotControllerOperator` → `HookReverted`; the **real
  WOOF-03 hook reverts `NotAuthorizedOperator()` = `0x3d9adf1c`** post-borrowDriver-reconcile — the integrated
  build observes that selector), revaluation-independence, close-reclaim.
- **Cross-ticket obligations (verify these land elsewhere).** (1) **Discharged here:** WOOF-01's lien-as-collateral
  registration (`setLTV` on the escrow vault); **the operator grant** (now issued per line by `LineAccount` in
  `openLine` — discharges what was the controller's `wireVenueOperator` job). (2) **Owed to item 6 controller:** seed
  `cache[LIEN_i]` via the `oracleKey` returned by `openLine`; lien↔escrow custody sequencing; **pass the FULL `1e18`
  lien as `collateralAmount`**; **NO operator-wiring / no EVC handle** (removed). (3) **Owed to item 10 deploy/wiring:**
  curator+allocator grant, `EE_POOL` timelock 0, the `baseUsdcMarket` funding source (also a §4.5 supply-side
  dependency); **the deploy two-pass that wires the hook's `controller` immutable = the adapter address** (precompute);
  the old `wireVenueOperator`-before-renounce obligation is **REMOVED**. (4) **Spec/audit:** the borrow-driver =
  adapter clarification (done this window) + the stale-ref sweep in `audit/2.md`/`audit/3-results.md`.

### WOOF-05 — `ZipcodeController`  ·  §4.4  ·  `tickets/woof/WOOF-05-controller.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone against the live WOOF-00..04
  scaffold; `forge build` green (solc 0.8.24) + **26/26 new tests pass on a live Base-mainnet fork** (102/102
  total, no WOOF-00/01/02/03/04 regression — independently re-run by the superintendent). Code kept at
  `contracts/src/ZipcodeController.sol` + `contracts/test/ZipcodeController.t.sol`. EVK/EVC/EulerRouter LIVE;
  `EulerEarn` MOCKED (0.8.26, recording mock that deposits real cash into the live line vault on `reallocate`).
  **The central subtraction holds on disk:** the controller imports ONLY `ReceiverTemplate` + `IZipcodeVenue` (+
  three inline local interfaces) — **no EVC import / immutable / call**, 5-arg ctor `(forwarder, venue,
  lienFactory, oracleRegistry, erebor)`. **Live-fork-proven:** the no-controller-operator-wiring origination
  borrow (`isAccountOperatorAuthorized(borrowAccount, adapter)==true` & `(…, controller)==false`); the L4 full
  transcript (exact `1e18` escrow, `getQuote==equityMark`, both LTVs, `debtOf==drawAmount`, `allowance==0`);
  batch-atomicity (over-LTV → exact `E_AccountLiquidity()` `0x34373fbc`, mid-batch `equityMark=0` rollback +
  re-origination, cap-only → exact `E_BorrowCapExceeded()` `0x6ef90ef1`, full no-orphan post-state); draw-a′ exact
  accrual + re-anchor rollback; close reclaim-before-burn (incl. the mocked-`closeLine` → `burn` reverts
  `ERC20InsufficientBalance` sequencing pin); dispatch/dup; status markers 5/6; dormant-gate + post-renounce
  setters; reentrancy-impossible. Every external signature re-verified vs the on-disk WOOF-01/02/03/04 source
  (zero discrepancies); error selectors re-verified via `cast`. **Zero spec-guesses; no `claude-zipcode.md`
  edit** (zero-spec-guess keepsake confirmed). **DISCHARGES** item-6's WOOF-01/02/04 inbound obligations
  (seed-before-draw atomic batch / reclaim-before-burn / operator-AT-ORIGIN-by-WOOF-04 / custody / full-`1e18`).
> **RE-AUTHORED 2026-06-05 (borrower-model, Step 2c) — supersedes the sub-account / `wireVenueOperator` version.**
> A pure **SUBTRACTION**: the borrower-of-record rework **removed** the controller's `wireVenueOperator(evc)` /
> blanket `setOperator(prefix, venue, ~uint256(1))` step + the EVC parameter/import + the
> `~uint256(1)`/sub-account/F-1/F-2 reasoning **entirely** — the per-line operator grant is now issued inside
> `VENUE.openLine` by the adapter's `LineAccount` (granting **the adapter**, the `EVC.call` borrow-driver,
> §4.4/§4.7), so the controller takes **no EVC handle** and **touches no EVC type at all**. Item-10's
> `wireVenueOperator`-before-renounce obligation is **dissolved**. Everything else carries forward unchanged
> (CRE receiver, `_processReport` dispatch, lien mint/burn, `create→openLine→seed→setLineLimits→fund→draw`
> ordering, the §4.4a seed-before-draw invariant, custody/full-`1e18`/erebor, the identity/renounce gate).
> Cold-build = **YES, 17/17** with a **live** EVK borrow that succeeds with NO controller operator-wiring.
- **What it does.** The portable-core orchestrator + CRE receiver. `is ReceiverTemplate`; inbound gated on an
  **immutable** Forwarder (sealed by renounce, not an override). `_processReport` envelope-decodes
  `(uint8 reportType, bytes payload)` and dispatches: **1 Origination** (create lien → `openLine` → seed the
  returned `oracleKey` → `setLineLimits` → `fund` → `draw` to Erebor — one atomic call), **2 Draw** (re-anchor
  seed → fund → draw on an open line), **4 Close** (`observeDebt==0` → `closeLine` reclaims → `burn` →
  `LienReleased`), **5/6** (M1 status markers — never `venue.liquidate`, §4.4e), **3 rejected** (→ registry
  direct), unknown → `UnsupportedReportType`. Holds **lien mint/burn authority** (the `create`/`burn` caller)
  and is the abstract **borrower of record** (the *mechanical* EVC borrow-on-behalf is the adapter's job behind
  the seam — the controller itself never touches EVC); drives **every** venue effect through `IZipcodeVenue` (no
  direct EVK/EulerEarn/EVC call). Per-lien state `liens[lienId] = {lien, lineRef, open}` + a `getLien` struct
  getter (no `borrowAccount`/`subId` stored — that is the adapter's internal artifact behind the seam).
- **Locked shape.** **Four immutables `(venue, lienFactory, oracleRegistry, erebor)` + the Forwarder/owner from
  `ReceiverTemplate`** — 5-arg ctor `(forwarder, venue, lienFactory, oracleRegistry, erebor)`, **NO EVC**. The
  controller holds **no EVC**, has **no `wireVenueOperator` / no `setOperator` / no EVC import** (the central
  subtraction). No override of `onReport`/`setForwarderAddress` (non-virtual); immutability via the S11 renounce.
  The only `onlyOwner` surface is the inherited identity setters (frozen by renounce). No `nonReentrant` (reentry
  is Forwarder-gated-impossible). Local minimal interfaces for the factory/lien-token/registry (avoids the
  OZ-vs-forge-std `IERC20` choice).
- **Holes → resolution (the re-author, all closed in the ticket).** (a) **Operator authorization — REMOVED from
  the controller.** Under the per-line model the grant is the adapter's `LineAccount` job at origination
  (WOOF-04); the controller's old blanket-`setOperator`-excluding-sub-0 entrypoint + the F-1/F-2 isolation
  caveats are **deleted** — the controller has no EVC role. (Isolation now rests on per-line distinct prefixes,
  WOOF-04, not on any controller backstop.) (b) **Dormant identity gate** (security F-3) — unchanged: the
  workflow-identity check is conditional; the controller has no self-defense against renounce-before-identity →
  the deploy S11 pre-gate (WOOF-10a) is the only defense; the unit test demonstrates the dormancy. (c) `erebor`
  5th ctor immutable — carried forward (passed to `venue.draw`). (d) **`getLien`** struct getter (the `public`
  mapping returns a tuple, not a struct) — carried forward. (e) `PrecomputeMismatch` is **defensive/unreachable**
  — carried forward. **No `claude-zipcode.md` edit needed** — §4.4 (`:380-383`) + §9 (`:915-920`) already state
  no-EVC-handle / no-controller-operator-step (Step-1 / WOOF-04 edits); spec-fidelity confirmed.
  Cold-build: `forge build` clean, **17/17** with a **live** EVK borrow — the re-author proof
  `test_origination_liveBorrow_noControllerOperatorWiring` (borrow succeeds with NO controller EVC step;
  `isAccountOperatorAuthorized(borrowAccount, adapter)==true` & `(…, controller)==false`); over-LTV →
  `E_AccountLiquidity` (trace-confirmed, NOT `E_InsufficientCash`), cap → `E_BorrowCapExceeded`; **zero
  load-bearing guesses**.
- **Cross-ticket obligations (verify these land elsewhere).** (1) **Discharged here:** WOOF-04 obl.
  (operator-AT-ORIGIN-by-WOOF-04 — controller has no operator step / seed-returned-key / custody / full-`1e18`),
  WOOF-02 obl. (atomic-batch seed-before-draw), WOOF-01 obl. (reclaim-before-burn). (2) **Owed to item 10
  (deploy/wiring):** deploy with the **5-arg** ctor (incl. `EREBOR`, **NO EVC**); **NO
  `controller.wireVenueOperator(EVC)` step — REMOVED** (each line's operator grant is the `LineAccount`'s job
  inside `openLine`; `draw` no longer depends on any deploy-time controller EVC wiring); `setController` at S6;
  identity-then-renounce with the `getExpectedWorkflowId()!=0` pre-gate (WOOF-10a); wire the hook's `borrowDriver`
  = the adapter (WOOF-03/04 obligation). (3) **Owed to the CRE track (§8):** encode reports as `abi.encode(uint8
  reportType, bytes payload)` per the §4.4 per-type table (1/2/4/5/6 → controller, 3 → registry direct); emit
  origination/draw only when the off-chain Proof + delinquency gates pass.

### WOOF-10a — `ZipcodeDeployAsserts` (deploy identity pre-gate)  ·  §9 (slice of item 10)  ·  `tickets/woof/WOOF-10a-deploy-identity-gate.md`
- **BUILT-VERIFIED 2026-06-06 (keep-the-build):** materialized from the ticket alone against the live WOOF-00..05
  keepsakes; `forge build` green (solc 0.8.24) + **5/5 new tests pass** (107/107 total, no regression;
  independently re-run + source read). Code kept at `contracts/src/ZipcodeDeployAsserts.sol` +
  `contracts/test/ZipcodeDeployIdentityGate.t.sol`. **No fork needed** (pure view over the real WOOF-02/05; a 6-dp
  `MockUSDC` satisfies the registry ctor). The combined fail-closed `getExpectedWorkflowId()==0 || controller()==0`
  → `IdentityNotWired` gate proven across all three classes against the REAL receivers: NEGATIVE (3 cases, exact
  selector+args), POSITIVE (gate passes → renounce → inherited setters + `setController` revert
  `OwnableUnauthorizedAccount`), NEGATIVE-CONTROL (dormancy selector-difference — dormant → `UnsupportedReportType(3)`,
  gate-active → `InvalidWorkflowId(WRONG_WID, WID)`). Zero spec-guesses; no `claude-zipcode.md` edit (zero-spec-guess
  keepsake confirmed). **DISCHARGES (gate portion, now build-verified-kept):** the item-10 WOOF-05 row (F-3) +
  WOOF-02 row (F7) S11 pre-gate.
- **What it does.** A deploy-time pre-gate proving the security **F7/F-3** renounce-before-identity defense — the
  highest real risk in the system (HIGH). A tiny `library ZipcodeDeployAsserts` with one `internal view`
  free function `requireIdentityWired(address controller, address registry)` that reverts `IdentityNotWired` unless
  **BOTH** `controller.getExpectedWorkflowId() != bytes32(0)` (F-3: identity active, not dormant) **AND**
  `registry.controller() != address(0)` (F7: origination seeding not bricked). Item 10's deploy script calls it
  ONCE at S11 immediately before the two `renounceOwnership()` calls. Build-only; no user surface.
- **Locked shape.** `library` + `internal view` (compiles INTO the deploy script — no extra deployed bytecode), ONE
  combined fail-closed assert, two local read interfaces (`IReceiverIdentity.getExpectedWorkflowId`,
  `IOracleRegistryController.controller`). NOT a method on the controller/registry (it spans two contracts + is a
  deploy-time concern; a method would be dead post-renounce). Realizes the §9/audit-S11 mandate verbatim — invents
  no mechanism. **The ONLY defense:** `ReceiverTemplate.onReport`'s identity check is conditional (`:88`) and
  `onReport`/`setForwarderAddress` are non-virtual → the receiver CANNOT self-defend; the deploy-time gate is the
  sole place to catch a renounce-before-wiring.
- **Holes → resolution.** **No spec gap** (spec-fidelity confirmed: §9 + audit/2.md S11 + §4.4 already specify the
  combined pre-gate + the dormancy caveat — a test-authoring + tiny-helper item, exactly as the superintendent
  predicted; confirm-don't-invent). The only judgment was test SHAPE: the dormancy NEGATIVE-CONTROL uses a
  `reportType 3` (controller-rejected) so the proof is a pure SELECTOR DIFFERENCE — dormant identity →
  `UnsupportedReportType(3)` (the wrong-id metadata sailed past the skipped gate), gate-active →
  `InvalidWorkflowId` (the gate fires first) — isolating "identity accepted the wrong id" from any venue effect (no
  origination needed). Cold-build: `forge build` clean + clean-rebuild **6/6** green against the REAL WOOF-02
  registry + WOOF-05 controller (venue/factory stubbed — origination is never exercised); observed selectors
  `IdentityNotWired` ×3, `OwnableUnauthorizedAccount` ×5, `UnsupportedReportType(3)`, `InvalidWorkflowId(0x9999,
  0x1234)`.
- **Cross-ticket obligations (verify these land elsewhere).** **Discharges (gate portion only):** the item-10
  WOOF-05 row (F-3) + WOOF-02 row (F7) S11 pre-gate — now TESTED. **Owed to the full item 10:** import
  `ZipcodeDeployAsserts.requireIdentityWired(ZIP_CONTROLLER, ZIP_ORACLE_REG)` at S11 before the sequenced
  `renounceOwnership()` calls (may add a redundant `requireIdentityWired(ZIP_ORACLE_REG, ZIP_ORACLE_REG)` for the
  registry's own id); the rows' OTHER clauses (5-arg ctor, `wireVenueOperator`-before-renounce, `setController`@S6,
  `govSetFallbackOracle`@S10) stay OPEN for item 10.

### WOOF-06 — `ZipDepositModule` (the zap)  ·  §4.5  ·  `tickets/woof/WOOF-06-deposit-module.md` (+ `tickets/inflow/INFLOW-06-deposit-module.md`)
> **BUILT-VERIFIED 2026-06-08 against the REAL Gate seam (two-token / Exit-Gate model — supersedes the 2026-06-06
> `loot`/`stakingVault` digest below).** Final shape: the zap's junior leg calls **`IZipExitGate.depositFor(zipUSD,
> zipAmount, msg.sender) → shares`** (the **Exit Gate**, not a "mint shaman"); the Gate values the deposit
> NAV-proportionally via `SzipNavOracle`, mints soulbound Loot to **itself** and the **transferable szipUSD share**
> to the user, returns `shares`. Module surface: `error ZeroShares` (was `ZeroLoot`); `setGate` (was
> `setStakingVault`); `event Zapped(user, usdcIn, zipMinted, shares)`. 4 ctor immutables `(zipUSD, usdc, eePool,
> warehouse)` + derived `scaleUp` + `deployer` + set-once `gate` are UNCHANGED; the warehouse-as-EE-receiver,
> per-zap-exact-allowance (D1), `ResidualBalance`/`ZeroShares`/`forceApprove`-reset hardening, Permit2 fallback,
> `nonReentrant`, dual `deposit`/`zap` path, decimals/`scaleUp` derivation all PRESERVED.
> - **Materialized + KEPT** at `contracts/src/supply/ZipDepositModule.sol` + `contracts/test/ZipDepositModule.t.sol`;
>   `forge build` green + **29/29** (`ZipDepositModuleTest` 26 mock-gate adversarial unit + `ZipDepositModuleRealGateTest`
>   3 Base-fork), **205/205 total no regression**. zipUSD = the REAL `ESynth` over a live EVC in every test.
> - **Real-seam proof (the keep-the-build mandate):** the headline zap is fork-proven against the **LIVE** `ExitGate`
>   + real `SzipNavOracle` + real Baal substrate (genesis-par, NAV-proportional $1.2→round-down, on-behalf,
>   `previewZap==zap`, two-token invariant `szipUSD.totalSupply==Loot.balanceOf(gate)`, `totalShares()==0`). The
>   `MockGate` is retained ONLY for adversarial gate behaviours the real Gate can't exhibit.
> - **Build-discovered.** (1) `depositFor(asset,amount,receiver)→shares` matched the pinned interface EXACTLY. (2) The
>   real `ExitGate` LACKED the `previewDeposit` quote view (the obligation this ticket created) → **added it to the
>   kept Gate as a thin forwarder to `SzipNavOracle` (8-B4) — NO new pricing math** (it reads the oracle's `valueOf` +
>   `navEntry`, divides round-down; the price + the empty-basket genesis-par are the oracle's; view-only no-poke; +2
>   Gate tests; obligation DISCHARGED). (3) The real Gate pulls the zipUSD into the **main Safe basket** (`safeTransferFrom(module, mainSafe,
>   …)`), not into the Gate — so the real-gate test asserts `zip.balanceOf(mainSafe)`; the module's full-pull/residual
>   invariant is identical either way. No `claude-zipcode.md` edit (pure plumbing; the pinned seam held).
> - **Cross-ticket obligations.** Owed to deploy/item-10 (UNCHANGED, OPEN): 4-arg ctor; assert `module.warehouse()`
>   == canonical Safe + Gate owner-renounced/Timelock'd + `eePool` canonical **before** `setCapacity` (F3); `setGate`
>   grants no allowance; `audit/2` Baal sweep carries these. **INFLOW-06 (frontend interface) still PENDING cold-build.**
>
> *(Historical 2026-06-06 digest below — `loot`/`stakingVault`/`depositFor(zipAmount,user)` nouns are SUPERSEDED.)*

> **RE-AUTHORED 2026-06-06 (Baal + two-Safe `CreditWarehouse` model) — supersedes the EE-share-custody /
> convert-on-stake version.** The old digest below it described the deleted model (module-as-EE-share-custodian +
> `szipUSD.stake(amount, shares, receiver)` + the F1 exact-shares + `max` EE-share allowance seam). All of that is
> GONE: the junior is now a Baal Loot share (8-S1/§17), senior EE shares live in the **`CreditWarehouse` Safe**
> (8-S2b), and the module is a stateless router. This digest is the re-authored one; cold-build **PASSED 32/32**.
- **What it does.** The supply-side mint+route entry — the **only** way USDC becomes the protocol's two supply
  positions, now a **stateless mint+deposit router (NO custody).** `zap(usdc)` (THE default action) does, in one
  call: pull USDC → `IESynth(zipUSD).mint(this, zipAmount)` (transient, value-1:1 `usdc*scaleUp`) →
  `EE_POOL.deposit(usdc, warehouse)` (the **`CreditWarehouse` Safe** is the EE-share `receiver`, NOT the module) →
  `forceApprove(stakingVault, zipAmount)` → `loot = ISzipUSD(stakingVault).depositFor(zipAmount, msg.sender)` (the
  Baal **mint shaman**, on-behalf Loot to the user) → enforce `ZeroLoot`/`ResidualBalance` + reset the allowance.
  Plain `deposit(usdc)` mints raw zipUSD to the user (secondary path). `emit Zapped(user, usdcIn, zipMinted, loot)`.
  Plain `contract` (no `ReceiverTemplate`/`Ownable`/EVC) — called by **users**, not the CRE.
- **Locked shape.** **4 ctor immutables `(zipUSD, usdc, eePool, warehouse)`** + ctor-derived `scaleUp = 10**(zipDec
  − usdcDec)` + immutable `deployer`. One **set-once `setStakingVault(szipUSD)`** (deployer-gated, `AlreadyWired`)
  that stores the szipUSD vault address — **grants NO allowance** (the deleted version's `max` EE-share allowance
  is gone; per-zap `forceApprove` of the transient zipUSD only). `nonReentrant` (OZ v5) on `deposit`/`zap`.
  `previewDeposit`/`previewZap` views (back-pressure). Hardened: **zero-residual in-contract** (`ResidualBalance`,
  `ZeroLoot`), `forceApprove` + reset, Permit2 RESOLVED (ERC20 `safeTransferFrom` fallback).
- **Holes → resolution.** **(decimals)** `ESynth` is fixed **18-dp** (ctor `(evc,name,symbol)` — the audit's `, 6
  decimals` arg was impossible); `EE_POOL` shares **6-dp** (`VIRTUAL_AMOUNT=1e6`, offset 0) → "1:1" is value-1:1,
  mint `usdc*scaleUp`. **(custody MOVED)** EE shares no longer held by the module — `EE_POOL.deposit(usdc,
  warehouse)` parks them in the `CreditWarehouse` Safe (8-S2b/8-Bw); the module holds nothing. **(junior deposit)**
  the Baal mint shaman `depositFor(zipAmount, receiver)` replaces the deleted 3-arg `stake` — mints on-behalf Loot,
  no EE-share pull. **(Permit2)** `EulerEarn._deposit` falls back to `SafeERC20.safeTransferFrom` when no Permit2
  pre-approval → plain `forceApprove(eePool)` suffices. Cold-build: `forge build` clean, **32/32** (real `ESynth` +
  live EVC + par/non-par EE mocks + `ISzipUSD`/`depositFor` mock + 6-dp USDC mock); 2 build-proven fixes folded (OZ
  `IERC20` import, `usdcIn` param). The `depositFor` seam + Permit2 live-pool check are MOCKED + pinned (the Baal
  interface scaffold isn't materialized yet; the underlying `mintLoot`/`isManager` shaman primitive exists in
  `reference/Baal`).
- **Cross-ticket obligations (verify these land elsewhere).** (1) **Owed to item 8 / `8-B2` (the Baal mint
  shaman):** the `ISzipUSD` seam is now `depositFor(uint256 zipAmount, address receiver) returns (uint256 loot)` +
  `previewDeposit(uint256 zipAmount) view returns (uint256 loot)` (on-behalf Loot mint; **no** EE-share pull, **no**
  3-arg `stake`). (2) **Owed to item 8 / `8-Bw` (the `CreditWarehouse` Safe):** must exist as a deployed Safe
  address for the 4th ctor immutable; admin = Zodiac **Roles Modifier v2** (out of module scope). (3) **Owed to item
  10 (deploy/wiring):** 4-arg ctor; deploy MUST assert `module.warehouse()==canonical Safe` + szipUSD
  renounced/Timelock'd + non-upgradeable + `eePool` canonical **before** `setCapacity` (F3 unbacked-zipUSD guard);
  `setStakingVault` grants no EE-share allowance; the `audit/2` Baal sweep carries these when 8-Bw is authored.
  **INFLOW-06** = the interface half (Vue/euler-lite supply+zap form), **also re-authored 2026-06-06**: zap=default
  Loot via `depositFor`, `Zapped(…loot)` consumed, writes via `sendTransactionAsync` (not `writeContract`),
  decimals contract USDC-6/zipUSD-18/Loot-18, back-pressure satisfied (no missing contract surface).

### WOOF-07 — `szipUSD` ~~freezable junior vault share~~ — **DELETED 2026-06-06 (WRONG VAULT)**
> **This ticket + INFLOW-08 + the report were DELETED.** It built szipUSD as an ERC-4626 convert-on-stake vault
> over **EulerEarn loan-book pool shares** — the wrong substrate. szipUSD is the **auto-compounder junior NAV
> vault** (**Baal Moloch-v3 + Zodiac**: Loot share, Safe-held multi-asset basket, ragequit in-kind exit, NAV
> tracked from multiple oracles, CRE-driven Hydrex farm, LOCK + FREEZE gates, first-loss = withhold-not-markdown).
> See the
> §4.5 SUPERSEDED guardrail + the 2026-06-06 PROGRESS session-log entry + the plan. The digest below is retained
> only as the record of the wrong pass.
- **What it does.** The junior first-loss(-residual) yield-bearing vault share — the headline supply product.
  An **ERC-4626 vault whose single asset is the `EulerEarn` pool share** (the senior backing held by the
  module). Suppliers enter via the zap (WOOF-06) or a direct stake; they exit on a per-staker `sUSD3` cooldown,
  gated by a subordination floor + a Duration-Bond freeze seam. M1 = the **vault SHELL**; loss/markdown/xALPHA/
  HYDX-boost are M2 and plug into the seams.
- **Locked shape.** `SZIPUSD is ERC4626, Ownable, ReentrancyGuard`; ctor `(zipUSD, eePool, module)` immutable +
  derived `scaleUp`; `_decimalsOffset()=12` → **decimals()==18** (presents the 18-dp face AND a `1e12`
  virtual-share inflation defense over the 6-dp asset); `totalAssets()` = own pool-share balance (perf-fee
  fee-shares accrue structurally → NAV, the M1 mechanical routing). **stake**: 3-arg exact-shares core
  (**module-only**, the F-CRIT gate) pulling **exactly** the passed `shares` (F1, no recompute) + 2-arg
  conservative `convertToShares(amount/scaleUp)` direct (public) + `previewStake`; both via private `_stake`.
  **unstake** (the inverse of stake; pays **zipUSD not USDC**): `availableWithdrawLimit`-gated → burn szipUSD →
  return pro-rata pool shares to the **module's** senior custody → mint `convertToAssets(poolSharesOut)×scaleUp`
  zipUSD; the USDC exit is the epoch queue (item 9). Replicated `sUSD3` cooldown (`UserCooldown`/startCooldown/
  cancel/window/getCooldownStatus); `availableWithdrawLimit` = `min(cooldownShares, totalSupply−floor,
  balance×(1−frozenBps))`; governed share-denominated floor; freeze seam (`lossCoordinator` **owner-replaceable**,
  `frozenBps`, `freeze`/`unfreeze` `onlyCoordinator`). Vanilla 4626 `deposit/mint/withdraw/redeem` → revert
  `UseStakeUnstake` (views stay live). Owner = TimelockController (§17 governed setters), **NOT renounced**.
- **Holes → resolution.** **(EXIT mechanism — the genuine gap)** §4.5 (USDC) vs audit-L12 (USDC) vs S7 (mints
  zipUSD) conflicted → resolved to **zipUSD-out, pool-shares-to-module** (faithful to S7 + §6.3 paced queue);
  §4.5/§17-L1334/audit-L12/N3/N4/S7 swept. **(F-CRIT drain, security)** the 3-arg stake decouples burned
  `amount` from pulled `shares` over the module's `max` allowance → public caller drains all senior backing →
  **3-arg is module-only**. **(`_consumeCooldown` underflow, junior-dev)** cooldownDuration==0 path → made the
  consume total (no-op when `c.shares==0`). **(decimals)** szipUSD 18-dp via offset-12, bound to a 6-dp pool by
  a ctor `InvalidDecimals` invariant. **(yield framing, spec-fidelity)** softened to "structural fee-share NAV
  accrual = M1 mechanical routing; §17 protocol-privatization is end-state" (no §17 decision changed).
  **(capacity, cold-build)** corrected the `ESynth.burn` premise (`minted` floors at 0, not "always 0") — grant
  `max` still required (stake-burns bank no credit; an exit-wave accumulates the full unstake total). Cold-build:
  `forge build` clean, **36/36** (real `ESynth` + live EVC + par/non-par EE mocks + module mock + 256-run
  rounding-direction-solvency fuzz); 2 narrow findings folded (added `InvalidDuration`/`InvalidDecimals`;
  corrected the capacity rationale).
- **Cross-ticket obligations.** **DISCHARGED** the WOOF-06 `ISzipUSD` seam (3-arg exact-shares + 2-arg
  conservative + previewStake; ctor takes module; **F4 via structural immutability, not renounce**). **CREATES**
  on **item 10 (S7/S8 deploy):** deploy szipUSD **after** the module `(ZIPUSD, EE_POOL, DEPOSIT_MODULE)`;
  `setCapacity(SZIPUSD, max)` (MUST be max); `module.setStakingVault(SZIPUSD)`; `EE_POOL.setFeeRecipient(SZIPUSD)`+
  `setFee(f)`; **owner = TimelockController (NOT renounced)** — the S7 reciprocal check asserts `module()==
  DEPOSIT_MODULE` + `owner()==TIMELOCK` (NOT `==0`); `lossCoordinator` stays `address(0)` in M1. On **M2
  (`DefaultCoordinator`, §4.6/§11):** `setLossCoordinator(coord)` then `freeze(bps)`/`unfreeze()` drive the
  Duration Bond; sizing/xALPHA premium/markdown are M2. **INFLOW-08** = the interface half (junior position /
  cooldown timer / unstake; back-pressure satisfied — no missing surface; corrections: model the stake side on
  `earn/[vault]/index.vue` + the unstake side on `earn/[vault]/[subAccount]/withdraw.vue`, the cooldown panel is
  NET-NEW, unstake cross-links to the zipUSD queue, reads via `useSpyMode.ts:53` not `multicall.ts`).

### Credit-union — the szipUSD CoW-book exit (C1–C4)  ·  §6.4  ·  `credit-union.md` (consolidated build spec)
- **What it does.** Replaces the forfeiting on-chain exit queue with the CoW book + treasury buy-and-burn. Four
  pieces: **C1 `OffRampModule`** (a CRE-operator Zodiac module on the rq Safe; drives `ZipRedemptionQueue` to turn
  basket zipUSD → USDC at par so the treasury can fund buybacks; pure driver, no redemption logic; bubbling `_exec`,
  reads `scaleUp()` live, destinations pinned to the rq Safe). **C2 NAV-freshness fence** — folded into
  `SzipBuyBurnModule.postBid` (`validTo ≤ now + maxAge`, error `ValidToBeyondNavFreshness`, `maxAge()` added to its
  local `INavOracle`). **C3** removed the `ExitGate.processWindow` forfeit + on-chain queue (+ all orphans).
  **C4** hard-gated `ZipRedemptionQueue.requestRedeem` to the rq Safe (Timelock-settable `redeemController`).
- **Locked shape.** Exit = a resting CoW sell order (the order IS the queue) filled by the treasury's 8-B14
  buy-and-burn (priced ≤ navExit×(1−d)) or an external buyer → `ExitGate.burnFor` (NAV-accretive, basket flat). No
  forfeit, no on-chain window, no separate engine Safe (the `engineSafe` label = the rq Safe = `Baal.avatar()`).
- **Holes surfaced → resolution.** (a) C2 controller-vs-fold → **COLLAPSED to the fence** (superintendent reversed
  the critic "keep it thin" call — the CRE already holds both roles + drives `postBid`/`burnFor`). (b) C4 gate must
  target the **rq Safe**, not the module (the module `exec`s through the Safe) — and is a griefing-vector fix, not
  theft prevention. (c) C1 must use the bubbling `_exec` (Safe swallows reverts otherwise) + read `scaleUp()` live.
  (d) C3's `test_invariant_sequence` was a hidden landmine (calls the deleted fns but isn't named `*processWindow*`).
  (e) `burnFor` is unbounded operator-trusted (documented). (f) stale spec language (§6.4/§17 "liquidity windows /
  intent queue / engine Safe") fixed in `claude-zipcode.md` first.
- **Cross-ticket obligations.** Item-10: wire the rq-Safe `OffRampModule` (enable + operator); set
  `ZipRedemptionQueue.redeemController = rqSafe`; the junior-acceptance `audit/2` sweep now traces the CoW exit (not
  `processWindow`). 8-B12: tripwire `ExitGate.Burned`/buyback throughput. **NOTE:** a parallel agent is building
  `RecycleModule.divert` (Stream-2) in the same tree — no file overlap with this rework; attribute results per-suite,
  not by the aggregate `forge test` count.
- **Status.** BUILT-VERIFIED + KEPT 2026-06-09 (C1 17/17 · C2 SzipBuyBurnModule 36/36 · C3 ExitGate 14/14 · C4
  ZipRedemptionQueue 44/44; full non-fork green). `reports/credit-union-report.md`.

---

## Pending (one-liner each; expanded when authored)

- **7 · `ZipDepositModule` — the zap (§4.5)** — **DONE** (WOOF-06 + INFLOW-06; see Authored above).
- **8 · `szipUSD` — the Baal NAV vault (§4.5/§6.4/§11)** *[+ interface]* — **REDESIGNING.** The 2026-06-05 WOOF-07
  + INFLOW-08 (ERC-4626 convert-on-stake over EulerEarn pool shares) were **DELETED — wrong vault.** szipUSD is now
  the **Baal/Moloch-v3 + Zodiac** auto-compounder NAV vault (Loot share, Safe basket, in-kind ragequit; two-token /
  NAV-oracle / provision money model — the 2026-06-06 withhold-not-markdown model was retired 2026-06-07).
  **Phase 8-S spec foundation DONE; Phase 8-B build tickets mostly BUILT-VERIFIED** (see PROGRESS item 8 +
  `reports/baal-spec.md`). The WOOF-07 digest below is retained ONLY as the record of the
  wrong pass.
  - **8-B1 · Baal substrate scaffold (§4.5 / `reports/baal-spec.md` 8-B1) — BUILT-VERIFIED 2026-06-07.** *What it does:* a
    summon script (`contracts/script/SummonSubstrate.s.sol`) that calls the LIVE `BaalAndVaultSummoner` (Base
    `0x2eF2…`) to produce Baal + main Safe (avatar/ragequit target = FREE equity) + non-ragequittable sidecar
    (COMMITTED equity / the freeze) + Loot/Shares clones (Loot soulbound/paused, **Shares = 0 forever**). *Locked
    shape:* **two-tier authority (user-ratified)** — admin = the **team multisig added as a Safe owner/signer** on
    both Safes (governs the module set, grants the Gate `manager`, all wiring via `Safe.execTransaction`); CRE
    operator = a Zodiac module the admin enables; **zero Shares ⇒ Baal governance inert by design** (no bootstrap
    shares). Team owner injected at summon via `executeAsBaal → execTransactionFromModule → addOwnerWithThreshold`;
    main-Safe addr **computed-from-live-factory + asserted == `baal.avatar()`** (fail-closed). *Holes surfaced →
    resolution:* (a) the baal-spec "post-deploy `setShamans`" seam was **un-reachable** (inert governance) → fixed
    in `claude-zipcode.md §4.5 item-0` + `reports/baal-spec.md 8-B1` (the authority model); (b) BaalSummoner's proxy factory
    = `0xC22834581EbC…` (slot 208), not `0xa6B7…` → new `BaseAddresses.BAAL_SAFE_PROXY_FACTORY`. *Cross-ticket
    obligations created:* Gate/all-manager-holders must NOT call `mintShares` (zero-Shares invariant); item-9
    sidecar-funding gated on team-owner; item-10 team-k-of-n / remove-Baal-as-owner / Roles-scoped-CRE-operator /
    unpredictable-saltNonce. *Proof:* 8/8 fork tests, 115/115 total — `forge test --match-contract
    SummonSubstrateTest`. **Not git-committed** (repo working-tree untracked; on `main`). Memory:
    [[szipusd-safe-authority-model]].
  - **SzipNavOracle · the szipUSD NAV-per-share oracle (§7 / `reports/baal-spec.md §3`) — BUILT-VERIFIED 2026-06-07.**
    *What it does:* `contract SzipNavOracle is ReceiverTemplate` — the szipUSD **issuance + exit pricing primitive**
    (NOT display-only). Composes junior-basket NAV **on-chain** across the main + sidecar Safes (incl. the staked
    ICHI LP read off the gauge), CRE-**pushes only** the off-chain leg marks (`alphaUSD`, `HYDX/USD`) via reportType 7,
    and maintains an on-chain windowed-TWAP accumulator (`W=4h`) on `navPerShare`. Serves `navEntry = max(spot,twap)`
    (issuance) / `navExit = min(spot,twap)` (exit), 18-dp. *Locked shape:* `is ReceiverTemplate` only (NOT
    BaseAdapter — consumers read its own views, not an EulerRouter); per-leg marks zipUSD/USDC=$1, xALPHA = on-chain
    `exchangeRate ×` pushed `alphaUSD` (two-layer), oHYDX = `HYDX×(100−discount)/100` (discount read on-chain), **ICHI
    LP marked-through at true reserve value**, veHYDX excluded; denominator = `szipUSD.totalSupply() − engine
    pending-burn`; genesis returns `navPerShare₀=$1`; **staleness pauses issuance (`navEntry`/`fresh`) but never exit**;
    per-push deviation circuit-break; **two write authorities** — immutable Forwarder (reportType 7) + set-once
    **unbounded** `DefaultCoordinator` provision writer (bound lives in the M2 coordinator); 4 set-once setters
    (shareToken/LpPosition/engineSafe/defaultCoordinator) frozen by renounce; uint256 `cumNav` ring (CARDINALITY 65)
    with an explicit bounded walk-back. *Holes surfaced → resolution:* the 3 spec gaps (§4.4 reportType 7 / §7
    authorities+denominator / §12 stale-model rewrite — all FIXED in `claude-zipcode.md`); `IOptionToken.discount()`
    was absent from the stub → added (on-chain==30). Security notes recorded as **documented invariants** (the
    `max`/`min` bracket defends the profitable direction of one-block spikes; `navExit` stale-mark asymmetry needs the
    Gate to `poke()`; `writeProvision` unbounded-by-design; genesis round-down is the Gate's job). *Cross-ticket
    obligations created:* Exit Gate issues off `navEntry`/exits off `navExit` + `poke()`s + wired via `setShareToken`;
    8-B14 wired via `setEngineSafe`; DefaultCoordinator (M2) enforces the provision bound; item-10 wires the 4 setters
    + asserts `shareToken!=0` before renounce; CRE track produces the gas-bounded reportType-7 push. *Proof:* 39/39
    tests + a live Base-fork sig-verification of the USDC/ICHI/gauge/oHYDX faces; 154/154 total, no regression —
    `forge test --match-contract SzipNavOracleTest [--fork-url $BASE_RPC_URL]`. Code: `contracts/src/supply/
    SzipNavOracle.sol` + `contracts/src/interfaces/bridge/IXAlphaRate.sol` + `contracts/test/SzipNavOracle.t.sol`.
    *Note:* authored AND built in one window (build-subagent dropped on a socket error mid-run, unresumable); the
    formal fresh-subagent zero-guess gate was **run separately + CLOSED 2026-06-08** (3 ticket-detail gaps folded in,
    keepsake restored, no bug); code is green+kept+fork-verified.
  - **Exit Gate + szipUSD · the junior share + the windowed exit valve (§6.4/§7 / `reports/baal-spec.md §4/§5/§7`) —
    BUILT-VERIFIED 2026-06-08.** *What it does:* `SzipUSD` = a plain transferable 18-dp ERC-20, `onlyGate` mint/burn
    (the user token; trades on CoW). `ExitGate` = the **sole Baal `Loot` custodian** (holds `manager`=2, granted
    post-deploy by `team→mainSafe.execTransaction→setShamans([gate],[2])`), **sole szipUSD minter/burner**, **sole
    `ragequit` caller** — so depositors never hold raw Loot. Flows: **`depositFor(asset,amount,receiver)`** —
    NAV-proportional issuance off `navOracle.navEntry()` (poke-first, round-down), pulls the asset straight into the
    **main Safe** (zero Gate custody), `mintLoot([gate],shares)` + `szip.mint(receiver,shares)` (paired, equal),
    TVL-capped, asset-whitelist {zipUSD,xALPHA} valued via the oracle's new `valueOf`; **`requestExit`** escrows szipUSD
    + queues a FIFO claim; **`processWindow(maxClaims)`** (onlyWindowController/keeper) does a **plain in-kind ragequit**
    of each queued claim — the exiter gets their **pro-rata slice of the (free, main-Safe) basket (zipUSD + xALPHA)
    sent straight to them**, and the matching Loot + escrowed szipUSD are burned. **No oracle/cap/numeraire/sweep on
    exit** — "you leave, you get your share" (worth `shares × NAV/share` by construction; the slice self-prices).
    **`burnFor`** = the §7/
    8-B14 pure-supply retire (burnLoot + burn engine-Safe szipUSD, no asset payout). *Locked shape:* two-token
    invariant `szipUSD.totalSupply()==loot.balanceOf(gate)` held on every path; **Shares stay 0 forever** (never
    `mintShares`); the **freeze is structural** (ragequit reaches only the main Safe; the sidecar/committed slice is
    excluded, so a leaver gets their share of free equity; no floor knob, no fundability gate). The leaver takes
    zipUSD→USDC via `ZipRedemptionQueue` (a separate downstream leg). *(The xALPHA→zipUSD auto-dump module was
    REMOVED 2026-06-09 — user-directed: the impatient exit relies on CoW, not an auto-dump.)* *Holes surfaced →
    resolution:* (a) the oracle had no per-asset valuation → **added
    public `valueOf` to the kept `SzipNavOracle`** (§7 spec edit + 42/42, for *issuance*); (b) §6.4 didn't name the
    window opener → **named `windowController`** + rewrote exit to **plain in-kind ragequit** (§6.4 edit; the
    zipUSD-numeraire I first built was user-overruled 2026-06-08 — see PROGRESS rework entry). *Obligations discharged:* 8-B1 F4.2 (manager-grant + zero-Shares) +
    `SzipNavOracle` NAV-pricing seam. *Obligations created:* WOOF-06 calls `gate.depositFor`; 8-B14 calls `burnFor`;
    item-9 keeps main-Safe zipUSD topped before windows; item-10 deploys Gate→szipUSD, grants manager(2), wires
    `setShareToken`/`setWindowController`/`setEngineSafe` (+ oracle), renounces. *Status:* **17/17 on a live Base fork**
    (real Baal substrate + real oracle + mock basket), 174/174 total no regression — `forge test --match-contract
    ExitGateTest --fork-url $BASE_RPC_URL`. Code: `contracts/src/supply/szipUSD/{ExitGate,SzipUSD}.sol` +
    `contracts/test/ExitGate.t.sol`; ticket `tickets/sodo/8-B-exit-gate-szipusd.md`; `reports/Exit-Gate-report.md`.
    *Caveat:* authored AND built in one window (no independent fresh-subagent zero-guess rebuild — non-blocking, same
    as `SzipNavOracle`). (The earlier "M1 zipUSD-sufficiency" caveat is void — pure in-kind ragequit has no numeraire
    to be short of; a leaver simply gets their pro-rata slice of whatever's free.)
- **8-B14 · `SzipBuyBurnModule` · the haircut buy-and-burn BID module (§7 / `reports/baal-spec.md §7`) — BUILT-VERIFIED
  2026-06-08.** *What it does:* the protocol's discounted **buyer-of-last-resort** for szipUSD. A Zodiac Module
  (`is Module`, zodiac-core) `enableModule`'d on the **engine Safe**, one immutable CRE `operator`, mutating the Safe
  only via `exec(...,Operation.Call)`. `postBid(GPv2OrderInput{sellAmount,buyAmount,validTo})` validates + signs a
  **single resting** CoW `BUY szipUSD` PRESIGN order: `sellToken=USDC`, `buyToken=szipUSD`, `receiver=engineSafe`,
  `kind=BUY`, `partiallyFillable`, pinned `appData`, `feeAmount=0` (all non-amount fields are **module-fixed
  constants** so no unvalidated field enters the uid); price bound `sellAmount` paid `≤ navExit×(1−d)` (exact
  no-truncation integer form, floored against the buyer), `sellAmount ≤ buybackCap`, `0<dBps<10000`, `fresh()` gated,
  bounded `validTo`; computes the GPv2 orderUid on-chain (canonical `TYPE_HASH`, live `domainSeparator`,
  56-byte pack) and `setPreSignature(uid,true)` + `approve(vaultRelayer, sellAmount)` (exact, never infinite).
  `cancelBid` (operator|owner) flips presignature false + approval 0; re-post = cancel + new `validTo` (kills the
  partial-fill double-fill). `buybackCap==0` = kill-switch. *Locked shape:* **bid side ONLY** — the burn is the
  existing `ExitGate.burnFor` (windowController/manager(2), pure `burnLoot` supply reduction), so buy and burn are
  split by *authority*; the cycle is `{postBid → CoW fill into engineSafe → windowController:burnFor}`. The
  **first engine Zodiac Module** — establishes the `is Module`/`setUp`-under-`initializer`/`onlyOperator`/Call-only
  pattern for 8-B5…B13. *Holes surfaced → resolution:* (a) **3 spec edits to `baal-spec §7.2/§7.4`** — price off
  `navExit`=min(spot,twap) (buyer-conservative, not bare twap; a downward-trending NAV would otherwise let it overpay
  off a stale-high twap), name the **windowController** burn caller, drop "Roles-scoped engine Safe" (§10.1 plain
  Module governs); (b) ticket fixes — defined `GPv2OrderInput` + pinned `appData`; exact price inequality; **set-once
  storage NOT immutable** (clone bytecode is shared); single-resting-bid `BidAlreadyLive`; no generic exec passthrough.
  (c) **Build-discovered governance miss, user-corrected:** the cold-build subagent edited `reference/zodiac-core` to
  add `virtual` (to hard-lock `setAvatar`/`setTarget`) — **reference deps are PRISTINE, never edit them.** Reverted;
  dropped the hard-lock; `setAvatar`/`setTarget` stay inherited `onlyOwner` (operator can't redirect — the real
  property, tested; a Timelock redirect is deliberate governance, residual accepted). *Obligations discharged:*
  the Exit-Gate "8-B14 calls burnFor" seam (reframed — windowController calls burnFor; module is bid-side, identity
  `module.engineSafe==ExitGate.engineSafe` asserted) + the `SzipNavOracle` "8-B14 wired via setEngineSafe" (module
  side asserted; the oracle's same-Safe wiring stays item-10 deploy). *Obligations created:* item-10 deploys the
  module (CREATE2 clone via `ModuleProxyFactory`, `enableModule` on the engine Safe, `setUp` with governed `d`/`cap`,
  `owner=Timelock≠operator`, init-lock the mastercopy, wire `module.engineSafe==ExitGate.engineSafe==
  SzipNavOracle.engineSafe==order.receiver`); 8-B11 CRE drives `postBid`/`cancelBid` + windowController `burnFor`
  (reads `balanceOf(engineSafe)` on-chain, orders fill→burn→repost); 8-B12 alarms on non-zero engine-Safe residual;
  **audit-sweep** (the below-NAV buy-bid L-step + over-NAV/over-cap/stale N-steps into `audit/2`/`audit/3` — OPEN).
  *Proof:* **33/33 Base-fork** (uid known-answer vector via out-of-band `cast` + live `GPv2Settlement.preSignature` +
  USDC allowance; price boundary incl. non-`1e22`-divisible RHS; navExit-vs-twap; cap/kill-switch/single-bid;
  partial-fill→cancel→repost; atomicity rollback; freshness via warp; authority/shape; exec-discipline Call/value==0
  via recording mock Safe), **238/238 total no-regression** — `forge test --fork-url $BASE_RPC_URL`. Code:
  `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` + `contracts/src/interfaces/cow/IGPv2Settlement.sol` +
  `contracts/test/SzipBuyBurnModule.t.sol`; CoW addrs in `BaseAddresses.sol`. Ticket
  `tickets/sodo/8-B14-buy-burn-module.md`; `reports/8-B14-report.md`. CoW on Base (verified live): `GPv2Settlement
  0x9008D19f58AAbD9eD0D60971565AA8510560ab41`, `VaultRelayer 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`,
  `CowswapOrderSigner 0x23dA9AdE38E4477b23770DeD512fD37b12381FAB` (reference-only).
- **8-B5 · `ReservoirLoopModule` + `SzipReservoirLpOracle` + `ReservoirBorrowGuard` + `ReservoirMarketDeployer` · the
  strike-financing reservoir loop (§4.5.1 8-B5 / `reports/baal-spec.md §10.8`) — BUILT-VERIFIED 2026-06-08.** *What it does:*
  the on-chain seam of the self-collateralizing harvest loop — the LP finances its own oHYDX strike. The **2nd engine
  Zodiac Module** (`is Module`, zodiac-core, `enableModule`'d on the szipUSD engine Safe, one immutable CRE
  `operator`, mutates the Safe only via `exec(...,Operation.Call)`) drives the **Safe's OWN EVC account** (NOT a
  per-line `LineAccount` — that's the senior side, §4.7) through four `onlyOperator` scalar-only entrypoints:
  `postCollateral(lpAmount)` (approve→enableCollateral→deposit the LP into the escrow), `borrow(usdcAmount)`
  (enableController→`EVC.call` borrow the ~30% strike from the reservoir USDC vault), `repay(usdcAmount)`
  (approve→`EVC.call` repay→reset approval), `withdrawCollateral(lpAmount)` (`EVC.call` withdraw the LP back to the
  Safe). Every `receiver`/`onBehalfOfAccount` is the **literal `engineSafe`**; no generic passthrough; Call-only,
  `value==0` — the security boundary (the 8-B14 boundary extended to the EVC leg). *Locked shape:* the USDC borrow
  vault IS the warehouse's **shared resting USDC** → a required **`ReservoirBorrowGuard`** (modeled verbatim on
  `CREGatingHook`, but gating account-identity `_msgSender()==engineSafe`, since the Safe borrows on its own account
  with no operator) pins `OP_BORROW` to the Safe so no ICHI-LP holder can lever depositor funds. **`borrowCap` bounds
  AGGREGATE outstanding debt** (`debtOf(safe)+amount`), not a single call; `borrowCap==0` = kill-switch. The
  **`SzipReservoirLpOracle`** is the CRE-fed push-cache LP collateral oracle (`is ReceiverTemplate, BaseAdapter`,
  modeled on `ZipcodeOracleRegistry`): single LP key, quote=USDC, `LP_MARK=7` reportType (≠ registry's
  `REVALUATION=3`), fail-closed staleness (a stale/missing mark reverts the router → the EVC account-status check →
  the borrow, never opening an unsafe position). The **`ReservoirMarketDeployer`** stands up the EVK market
  (GenericFactory escrow collateral vault + dedicated `EulerRouter` wired `escrow→lpToken→lpOracle` + the USDC borrow
  vault with the guard at `OP_BORROW` + `setLTV`), **governor RETAINED at the Timelock** (`transferGovernance(timelock)`
  — the deliberate §4.5.1 inversion of WOOF-04's `transferGovernance(0)` freeze; LTV/caps/oracle stay tunable).
  *User decision locked:* the LP collateral oracle = **CRE-fed push-cache** (not a fixed-haircut constant); CRE
  computes the per-LP-share mark off-chain (`(reserve_xALPHA·priceXAlpha + reserve_zipUSD·priceZipUSD)/lpTotalSupply`
  — the same reserve×price math `SzipNavOracle` runs for the basket LP leg) + pushes it. *Holes surfaced →
  resolution:* (a) **2 §4.5.1 spec clarifications** (the `OP_BORROW` borrow-pin + the LP_MARK reportType) + **1
  SPEC-GAP deferred** (LP_MARK registration in the §8 CRE report ABI — now DONE `claude-zipcode.md §8.0/§8.6`; pinned placeholder
  `7` + CRE-track obligation). (b) Critic hardening folded into the ticket: aggregate `borrowCap` (security F1), the
  required borrow guard (security F8a), the deployer-creates-the-borrow-vault fix (junior #10 — router must precede
  the borrow vault whose oracle is the router). (c) **4 build-exposed corrections folded back** (kept-build doctrine):
  **C1 (critical)** the Gnosis Safe **swallows inner reverts** in `execTransactionFromModule` (returns false, doesn't
  bubble) → a private `_exec` uses `execAndReturnData` and **bubbles the inner revert bytes** (else fail-closed
  reverts silently swallow + the module wrongly emits success); **C2** EVK `repay(amount,receiver)` does NOT cap a
  literal `amount>owed` (reverts `E_RepayTooMuch`; only `type(uint).max`=all) → repay the exact strike; **C3** a NEW
  borrow gates on **`borrowLTV`** not `liqLTV` → over-LTV magnitudes pinned to `borrowLTV`; **C4** `setLTV` validates
  the collateral price via `getQuote` at config time → a live LP mark must exist pre-deploy, and "governor retained"
  = the deployer is governor at birth then `transferGovernance(timelock)`. *Obligations discharged:* none inbound
  (8-B5 owes nothing in the obligations table). *Obligations created:* 8-Bw/item-10 (EE allocates idle USDC into the
  reservoir borrow vault = the resting vault; wire `module.borrowVault`); CRE §8 (register `LP_MARK`); item-10/8-B11
  (CRE operator + Forwarder wiring); **audit-sweep** (the loop L-step + over-LTV/stale/over-cap/third-party-borrow
  N-steps into `audit/2`/`audit/3` — OPEN, item-10/engine-integration pass). *Proof:* **33/33 Base-fork** (full loop
  revolves twice against a real summoned substrate Safe; idempotent enable; over-LTV + no-collateral `E_AccountLiquidity`;
  both fail-closed oracle paths `TooStale`+`NotSupported`; aggregate-cap boundary + kill-switch; third-party borrow
  blocked by the guard; governor-RETAINED inversion + re-pointable; negative wire-mismatch; exhaustive exec-discipline
  decoding the inner `IEVC.call` (target/onBehalf/innermost receiver==engineSafe); atomicity rollback via
  `setFailOnCallIndex`; LP-oracle scale round-trip incl. non-divisible floor; mastercopy-inert; escrow 1:1;
  `LP_MARK==7≠3`), **271/271 total no-regression** — `forge test --match-contract ReservoirLoopModuleTest`. Code:
  `contracts/src/supply/szipUSD/{ReservoirLoopModule,ReservoirBorrowGuard}.sol` +
  `contracts/src/supply/SzipReservoirLpOracle.sol` + `contracts/script/ReservoirMarketDeployer.sol` +
  `contracts/test/ReservoirLoopModule.t.sol` (no `reference/` or kept-contract edits; `BaseAddresses.sol` untouched).
  Ticket `tickets/sodo/8-B5-reservoir-loop.md`; `reports/8-B5-report.md`.
- **8-B6 · `LpStrategyModule` · the LP build/stake module (§4.5.1 8-B6 / `reports/baal-spec.md §10.8`) — BUILT-VERIFIED
  2026-06-08.** *What it does:* owns the LP's whole lifecycle — build the zipUSD/xALPHA ICHI LP, gauge-stake it to farm
  oHYDX, and unstake/re-stake slices for the 8-B5 loop. The **3rd engine Zodiac Module** (`is Module`, zodiac-core,
  `enableModule`'d on the szipUSD engine Safe, one immutable CRE `operator`, mutates the Safe only via
  `exec/execAndReturnData(...,Operation.Call)`) — the **simplest** engine module: NO EVC/borrow/oracle/hook, just three
  `onlyOperator` scalar-only entrypoints driving the wired ICHI vault + gauge. `addLiquidity(deposit0, deposit1,
  minShares)` (approve non-zero legs → `IICHIVault.deposit(d0,d1,engineSafe)` capturing the share-return via
  `execAndReturnData` → reset approvals → assert `shares>=minShares`); `stake(lpAmount)` (approve→`IGauge.deposit`→reset);
  `unstake(lpAmount)` (`IGauge.withdraw`). Deposit `to` + both view reads pinned to the **literal `engineSafe`**; no
  generic passthrough; Call-only, `value==0`; **no storage written in any mutating path** (the reentrancy-safety
  property). *Locked shape:* (1) **direct `IICHIVault.deposit` is the add path — VERIFIED on live Base** (fork test
  drives the module against the REAL single-sided ICHI vault `0x07e72…` on our factory `0x2b52c416…`; direct deposit
  lands shares → the **DepositGuard is NOT needed**, resolving the build flag). (2) **SINGLE-SIDED zipUSD (user-directed
  2026-06-08) — vault-enforced, module vault-agnostic.** The vault is a single-sided zipUSD YieldIQ vault; there is **no
  balanced add** (the xALPHA leg accrues from pool flow + the emission flywheel, never a deposit). Single-sidedness is
  the **wired vault's** `allowToken*` property, **NOT a module gate** — the module forwards `(deposit0, deposit1)`
  unchanged and the vault rejects the disallowed side fail-closed, so the ICHI vault config can be finalized later
  without re-authoring the module (the module did NOT change when the design was pinned single-sided). The gauge MUST be
  a Hydrex **`ALM_ICHI_UNIV3`-type** gauge. *(This reverses my initial "balanced for 8-B13 Mode-C" framing — see the
  PROGRESS spec-gap log "ICHI vault = single-sided zipUSD YieldIQ".)* (3) **non-zero `minShares` floor enforced**
  (`ZeroMinShares`) — the contract-side slippage guard replacing the DepositGuard's `minimumProceeds`; a `minShares==0`
  would no-op the only sandwich protection on a direct ICHI deposit (security #4). (4) `token0`/`token1` read LIVE off
  the wired vault in `setUp` (the `SzipBuyBurnModule` pattern), address-nonzero guards ordered BEFORE the live read.
  *Holes surfaced → resolution:* **1 SPEC GAP fixed** (the single-sided contradiction → §4.5.1 reworded). Critic
  hardening folded into the ticket pre-build: the `minShares==0` footgun → hard non-zero floor (security); the
  mock-ICHI-vault/mock-gauge behavioral spec (qa — the cycle assertions would be vacuous without faithful
  transferFrom/mint-to-`to`/LP-movement mocks); the `_exec`-must-return-bytes adaptation (the kept 8-B5 `_exec` is void —
  8-B6 needs the deposit share-return decoded from it); the exec-discipline test must run a **live** RecordingSafe + real
  mock vault (a non-live mock returns `""` → `abi.decode` reverts before any assertion); snapshot-guarded slippage probe;
  per-entrypoint atomicity fail-indices (deposit is index 1 single / 2 balanced — no `enableCollateral` interposer like
  8-B5); gauge sig-verify limited to VIEW selectors (can't staticcall the state-mutating `deposit`/`withdraw`).
  *Obligations discharged:* none inbound (8-B6 owes nothing in the obligations table — confirmed by spec-fidelity).
  *Obligations created:* item-10 (resolve+wire the gauge via `Voter.gauges(ourPool)` with the `!=0` whitelist gate —
  MUST be `ALM_ICHI_UNIV3` type; create the **single-sided zipUSD** POL ICHI YieldIQ vault; clone+enable+setUp+init-lock);
  8-B11/CRE (sole
  caller; sizes `minShares` off the same reserve×price math; sequences unstake→re-stake around the 8-B5 loop within the
  epoch); 8-B10 (the zipUSD leg must be backed); **audit-sweep** (the LP-lifecycle L-step + non-operator/zero-amount/
  slippage N-steps into `audit/2`/`audit/3` — OPEN, item-10/engine-integration pass). *Proof:* **29/29** (24 unit:
  setUp/authority/mastercopy-inert-6-fields/zero-address-ordering/owner≠operator/initializer-once/setAvatar-locked/
  zero-amount/zero-minShares/vault-agnostic-passthrough-non-1:1-price/slippage-floor/exec-discipline-per-index-incl-`to==engineSafe`/
  views-read-engineSafe/atomicity-per-fail-index-both-legs/`_exec`-bubbles-custom+ExecFailed/disallowed-side; **5 fork**:
  real-ICHI-vault single-sided deposit lands shares + no standing allowance, snapshot-guarded slippage, disallowed-side
  real revert, gauge/Voter view sig-verify, full add→stake→unstake→re-stake cycle ×2 against a real summoned Safe),
  **300/300 total no-regression** — `forge test [--fork-url $BASE_RPC_URL] --match-contract LpStrategyModule`. Code:
  `contracts/src/supply/szipUSD/LpStrategyModule.sol` + `contracts/test/LpStrategyModule.t.sol` (no `reference/` or
  kept-contract edits; `BaseAddresses.sol` untouched — live test vault/gauge are test-file constants). Ticket
  `tickets/sodo/8-B6-lp-strategy.md`; `reports/8-B6-report.md`.
- **8-B7 · `HarvestVoteModule` · the harvest/vote (emissions + governance) module (§4.5.1 8-B7 / `reports/baal-spec.md §10.8`) —
  BUILT-VERIFIED 2026-06-08.** *What it does:* the per-epoch emissions+governance leg of the auto-compounder — claims the
  gauge's oHYDX to the Safe, takes the **vote-floor `exerciseVe` slice** (free permalock → grows the Safe's
  account-aggregate veHYDX), re-**votes** our gauge (votes reset weekly), and claims the anti-dilution **rebase**. The
  **4th engine Zodiac Module** and the **simplest sibling of 8-B6**: `is Module`, zodiac-core, `enableModule`'d on the
  szipUSD engine Safe, one set-once CRE `operator`, mutates the Safe only via `_exec`/`execAndReturnData(...,Call,value
  0)` — **NO EVC/oracle/custody/approvals, and (the load-bearing simplification) NO `tokenId` state.** Five `onlyOperator`
  mutators — `claimReward()`(`gauge.getReward()`), `lockVe(amount)`(`oHYDX.exerciseVe(amount, engineSafe)`, decode+emit
  the fresh `nftId`), `vote(address[],uint256[])`, `resetVote()`(`Voter.reset()`), `claimRebase(uint256[])`
  (`RewardsDistributor.claim_many`) — plus 3 views (`pendingReward`/`voteFloor`/`rebaseClaimable`). The `exerciseVe`
  recipient + every read are hard-pinned to the **literal `engineSafe`** (the irreversibility firewall — permalocked
  veHYDX is non-redeemable; a redirect would exfiltrate basket value permanently). *Locked shape — the account-keyed
  model (5 spec corrections, all reverse-verified from the un-open-sourced host's bytecode on live Base 8453):* (1)
  **VoterV5 is account-keyed, NOT tokenId-keyed** — `vote(address[],uint256[])`/`reset()` carry NO tokenId and act on
  the caller account's whole veHYDX position (the tokenId variants are ABSENT on-chain). (2) **Each `exerciseVe` mints a
  FRESH account-owned veNFT** (the team voter holds 40), and the Voter aggregates **by account** — so the module needs no
  tokenId/merge/enumeration; voting + the floor are account-level. (3) **Floor = `ve.getVotes(account)`** (account
  aggregate), proven > `balanceOfNFT(#1)` live. (4) **Rebase on the RewardsDistributor** (`Minter._rewards_distributor()`
  = `0x6FCa2…`, `claim_many(uint256[])`), not the Minter; per-NFT, operator-curated array (harmless if imperfect —
  claims credit each NFT's own lock). (5) `getEpochDuration()`=604800 confirmed. *Scoped out (faithful, spec-sanctioned):*
  the veHYDX **voting bribes/fees** claim (the gauge swap fees auto-compound in the ICHI vault → captured in NAV; 8-B7
  claims only the oHYDX emission) — a deferred extension. *Holes surfaced → resolution:* spec-fidelity verdict FAITHFUL
  (no §17 reopen, no inbound obligations). Critic findings folded pre-build: `IVotingEscrow` needed `balanceOf`/`ownerOf`/
  `tokenOfOwnerByIndex` adds (fork test) + full `IRewardsDistributor` sigs; the kept `RecordingSafe` can't return data
  for the `lockVe` nftId decode → spec'd a `setReturnData` extension + target mocks (MockGauge/Voter/RewardsDistributor);
  exec-shape pinned via typed `encodeCall` + a `lockVe` recipient decode-assert; positive `vote`/`reset`/`claimRebase`
  fork assertions (not bare "does not revert"); the **over-lock** monitoring obligation (8-B11 must bound `lockVe` to the
  regime floor `s*`, 8-B12 tripwire — `exerciseVe` is irreversible). *Build-exposed (test-sequencing, module correctly
  agnostic):* the live `vote` reverts `InsufficientVotingPower()`/`EpochStale()` unless the test warps to the next epoch
  boundary + calls `Minter.update_period()` (the veNFT must predate the snapshot), and the Voter enforces a per-account
  ~1h vote-delay (`VoteDelayNotMet()`) between vote/reset actions — both folded into the fork test (an 8-B11 CRE concern).
  `exerciseVe` needs **NO approval** (CONFIRMED on-chain — burns oHYDX from the Safe directly). *Obligations discharged:*
  none inbound. *Obligations created:* item-10/8-B11 (wire operator + `gauge` via `Voter.gauges(ourPool)!=0` whitelist
  gate [same external-gov dep as 8-B6] + the live `rewardsDistributor`; sequence claim→`lockVe`-first→`vote`); 8-B11/8-B12
  over-lock guard + monitoring (incl. the missed-epoch / floor-drift failure modes — CRE/monitoring-layer); item-10
  audit-sweep (the harvest/vote L-step + N-steps into `audit/2`/`audit/3`); the deferred veHYDX-voting-bribe extension.
  *Proof:* **26/26** (21 unit: exec-shape-all-5-fully-pinned + `lockVe`-recipient-decode + nftId-decode/malformed-return-
  reverts/authority-per-mutator/mastercopy-inert/owner≠operator/initializer-once/setAvatar-locked/zero-addr-all-6/
  live-read-zero-reverts/guards-all-4/`_exec`-bubble-custom+ExecFailed/views-read-engineSafe; **5 fork**: sig-verify +
  real `exerciseVe` proving fresh-veNFT/account-aggregate (balance+1, getVotes↑, oHYDX−exactly-amount, `ownerOf(nftId)==
  Safe`, 2nd lock→balance 2) + real `vote`/`reset` vs live VoterV5 + real `claimRebase` + fork-non-operator), **326/326
  total no-regression** — `forge test [--fork-url $BASE_RPC_URL] --match-contract HarvestVoteModule`. **ZERO load-bearing
  guesses.** Code: `contracts/src/supply/szipUSD/HarvestVoteModule.sol` + `contracts/test/HarvestVoteModule.t.sol` +
  interface adds (`IVoter`/`IVotingEscrow`/new `IRewardsDistributor`) + `BaseAddresses` (`HYDREX_VE`/
  `HYDREX_REWARDS_DISTRIBUTOR`); spec corrections in `claude-zipcode.md §4.5.1` + `baal-spec §10.8`. Ticket
  `tickets/sodo/8-B7-harvest-vote.md`; `reports/8-B7-report.md`.
- **8-B8 · `ExerciseModule` · the paid oHYDX-exercise (strike-financing) module (§4.5.1 8-B8 / `reports/baal-spec.md §10.8`) —
  BUILT-VERIFIED 2026-06-08.** *What it does:* the **paid** exercise of the sell slice — pays the ~30% USDC strike
  (financed by the 8-B5 borrow; the USDC is already in the Safe) to `oHYDX.exercise(...)` and receives liquid **HYDX**
  to the Safe, which 8-B9 then market-sells to repay. The **5th engine Zodiac Module**; the *paid* counterpart to 8-B7's
  **free** `exerciseVe` permalock — a **different oHYDX function** (`exercise` vs `exerciseVe`) with a USDC strike. The
  sibling of **8-B5's approve→call→reset USDC dance MINUS the EVC leg** (it touches no EVC account; the borrow that funds
  the strike is 8-B5's job). *Locked shape:* `is Module`, zodiac-core, `enableModule`'d on the szipUSD engine Safe
  (`avatar==target==engineSafe`), one set-once CRE `operator`, mutates the Safe only via `_exec`/`execAndReturnData(...,
  Call, value 0)` — **NO EVC/oracle/LP/veNFT, stateless beyond set-once wiring.** ONE `onlyOperator` mutator
  `exercise(uint256 amount, uint256 maxPayment, uint256 deadline) → paymentAmount` = exactly 3 `exec`s:
  (1) `USDC.approve(oHYDX, maxPayment)`, (2) `oHYDX.exercise(amount, maxPayment, engineSafe, deadline)` (the **4-arg
  deadline overload** — burns the Safe's oHYDX, pulls `paymentAmount ≤ maxPayment` USDC, mints HYDX to the Safe, returns
  `paymentAmount`), (3) `USDC.approve(oHYDX, 0)` (reset — no standing approval). The exercise `recipient` is hard-pinned
  to the **literal `engineSafe`** (the HYDX can only mint to the basket); `paymentToken` is **live-read** off
  `oHYDX.paymentToken()` at setUp (USDC; fail-closed nonzero). Plus a `quoteStrike(amount)` view =
  `max(getDiscountedPrice(amount), getMinPaymentAmount())` (8-B5/8-B11 back-pressure to size the borrow + the
  `maxPayment` cushion). *Spec-fidelity verdict FAITHFUL:* the profitability cutoff ($0.015 loop cutoff / $0.018 amber-taper / $0.01 dead floor), regime gate (UP/FLAT-only), and
  commitment gate (borrow→exercise→sell→repay) are correctly **OFF-chain** (8-B11 CRE-layer per §4.5.1 — the module is
  pure mechanism, correctly agnostic to regime/spot/loop-size); the strike-funding-via-8-B5-borrow boundary respected
  (does NOT borrow); §17 untouched. *Holes surfaced → resolution:* no spec-mechanism gap; one cosmetic §4.5.1 8-B8
  "State" tidy (read as module storage → "no module state; tracked by 8-B5/8-B11"). *Critic-hardened pre-build (strict
  additions → cold-build-only, no re-fan):* the **KR5 `paymentAmount ≤ maxPayment` honesty guard** (`PaymentExceedsMax`
  — defense-in-depth re-asserting the bound oHYDX already enforces internally); the **`maxPayment` = SLIPPAGE/spike
  guard** framing (CORRECTED from an initial "compromised oHYDX" overstatement — oHYDX is immutable/non-proxy, verified
  empty EIP-1967 slot + no `owner()`, and **fork-proven to charge exactly `quoteStrike(amount)` in the same block**;
  `maxPayment` aborts the loop on a TWAP spike between quote and execution, the only real risk being overpay-on-spike)
  → an 8-B11 modest-cushion obligation; **module-self-quote-exact EVALUATED + REJECTED** (it would delete the spike
  guard — pay-whatever-the-strike-is unconditionally — and wouldn't simplify: the CRE computes the strike regardless to
  size the 8-B5 borrow, the binding constraint); state-moving allowance-reset + rollback tests
  (live mock, not just calldata shape); decode-all-4-exercise-args recipient-pin; quoteStrike(0)/tie boundary;
  per-recorded-call value-0 assertion; atomic front-run-safe deploy+setUp obligation. *Obligations discharged:* none
  inbound (confirmed by spec-fidelity — no row owed by 8-B8). *Obligations created:* item-10/8-B11 (wire operator +
  `oHYDX`; atomic CREATE2 deploy+setUp; soft-halt/regime/commitment gates + TIGHT `maxPayment` cushion); 8-B9 HYDX
  hand-off (the minted HYDX is 8-B9's market-sell input); item-10 audit-sweep (the borrow→exercise→sell→repay L-step +
  N-steps into `audit/2`/`audit/3`). *On-chain-verified (Base 8453):* `paymentToken()`=`0x3013ce29`→USDC;
  `getMinPaymentAmount()`=`0x2abb945c` NO-args→10000 ($0.01 floor); `getDiscountedPrice(uint256)`=`0x339ccade`;
  `exercise(uint256,uint256,address,uint256)`=`0xa1d50c3a` (+ the 3-arg `0xd6379b72` exists, unused); `discount()`=30.
  *Proof:* **25/25** (21 unit: exec-shape-fully-pinned [3 calls, value-0/Call each, decode-all-4-exercise-args +
  recipient==engineSafe + reset-args] + paymentAmount-decode/malformed-return-reverts/`PaymentExceedsMax` + state-moving
  rollback (no dangling approval) + happy-path allowance-reset + authority/mastercopy-inert/owner≠operator/initializer-
  once/setAvatar-locked/zero-addr-all-4/zero-paymentToken-live/guards/`_exec`-bubble-custom+ExecFailed/quoteStrike-max+
  floor-at-0+tie; **4 fork**: sig-verify [`paymentToken`==USDC, `discount`==30, `quoteStrike`==max] + real `oHYDX.exercise`
  [oHYDX −exactly amount, USDC −exactly paymentAmount, HYDX minted, allowance reset to 0, Exercised event] + maxPayment-
  too-low-reverts-state-unchanged + past-deadline-reverts), **351/351 total no-regression** — `forge test [--fork-url
  $BASE_RPC_URL] --match-contract ExerciseModule`. **ZERO load-bearing guesses.** Code:
  `contracts/src/supply/szipUSD/ExerciseModule.sol` + `contracts/test/ExerciseModule.t.sol` + `IOptionToken` adds
  (`paymentToken`/`getMinPaymentAmount`); spec tidy in `claude-zipcode.md §4.5.1`. Ticket
  `tickets/sodo/8-B8-exercise-ohydx.md`; `reports/8-B8-report.md`.
- **8-B9 · `SellModule` · the swap (market-sell + POL-buy) module (§4.5.1 8-B9 / `reports/baal-spec.md §10.8`) — BUILT-VERIFIED
  2026-06-08.** *What it does:* the **6th engine Zodiac Module** (sibling of 8-B8, NO EVC/oracle/repay) — the swap leg
  of the auto-compounder. Two `onlyOperator` mutators sharing a private `_swap(tokenIn, tokenOut, amountIn, minOut,
  deadline)` approve→`exactInputSingle`→reset-approve dance (the 8-B8 token-dance, router target instead of oHYDX):
  `sellHydx`(HYDX→USDC, the 8-B5 strike-loop repay leg — market-sell now because the borrow accrues + the pool is
  net-draining with no buy-side) + `buyXAlpha`(zipUSD→xALPHA, the 8-B10/8-B13 Mode-B/C POL buy leg). *Locked shape:*
  Algebra Integral `SwapRouter.exactInputSingle` (8-field struct, `deployer`+`limitSqrtPrice`, no `fee`); operator
  supplies only `(amountIn, minOut, deadline)`; `recipient=engineSafe`/`deployer=address(0)`/`limitSqrtPrice=0`/the
  token pair all hard-pinned; typed `abi.encodeCall` (field-order regression fails to compile); `minOut` = the on-chain
  slippage guard (PRICE bound); decode+emit `Sold(tokenIn,tokenOut,amountIn,amountOut)`; value-0/Call-only/
  `_exec`-bubble; set-once storage (no immutables, clone-safe), init-locked mastercopy. **Per-call `maxSellHydx` SIZE
  ceiling** (user-directed 2026-06-08; default 300k HYDX, set-once + `onlyOwner setMaxSellHydx`, `sellHydx` reverts
  `ExceedsMaxSell` above it) = the on-chain whole-basket-dump backstop; `buyXAlpha` uncapped (bounded by 8-B10).
  **STATELESS beyond set-once config — no on-chain per-epoch *accumulator*** (the spec-gap this window: §4.5.1 8-B9
  "State: per-epoch accumulator" → "no module state"; on-chain bounds = `minOut` price + `maxSellHydx` size, per-epoch
  *throughput* stays the 8-B11/8-B12 CRE layer; the accumulator REJECTED for sibling-consistency + §17 time-policy).
  *Holes surfaced → resolution:*
  (1) §4.5.1 "State" contradiction → spec-fixed to stateless (spec-fidelity + security critics confirmed); (2)
  `IAlgebraPool` lacked `token0()/token1()` the fork test asserts → added; (3) qa test-completeness folds (assert every
  struct field; both entrypoints' authority/guards; 7 getters; all 8 zero-address reverts; fork determinism). *Live-chain
  verified (zero ticket discrepancies):* router `0x6f4b…` selector `0x1679c792` + `algebraSwapCallback` ⇒ Algebra not
  UniV3; base-factory pool (`router.factory()==pool.factory()==0x36077D39…`, `poolByPair(HYDX,USDC)==0x51f0…`) ⇒
  `deployer=0`; token0=HYDX/token1=USDC; the real fork swap pins the struct field order. *Security:* a compromised-operator
  whole-basket dump (`minOut=1`) is a CRE-key-compromise loss bounded by the 8-B12 off-chain tripwire, NOT a module bug
  (accepted under §17 CRE-permissioned-single-writer). *Cross-ticket:* **discharged** 8-B8→8-B9 HYDX hand-off; *created*
  the item-10/8-B11 wiring (operator + router + tokens, atomic clone+setUp), the 8-B12 volume tripwire, the 8-B10/8-B13
  `buyXAlpha` live-pool deferral + POL pool-identity, the 8-B10 proceeds/free-value hand-off, the item-10 audit sweep.
  **31/31 (27 unit + 4 Base-fork; +7 cap tests), 382/382 total, ZERO load-bearing guesses.** Code `contracts/src/supply/szipUSD/
  SellModule.sol` + `contracts/test/SellModule.t.sol` + NEW `contracts/src/interfaces/algebra/ISwapRouter.sol` + edits
  (`IAlgebraPool` token0/token1, `BaseAddresses.ALGEBRA_SWAP_ROUTER`). `tickets/sodo/8-B9-sell-module.md`;
  `reports/8-B9-report.md`.
- **8-B10 · `RecycleModule` — the single recycle sink (§4.5.1 8-B10)** — REWORKED + BUILT-VERIFIED 2026-06-08, KEPT.
  > **REWORKED 2026-06-08 (user-directed single-sink redesign) — the digest below describes the SUPERSEDED
  > `RecyclePayoutModule`.** Final shape: `RecycleModule` with ONE action — `recycle(usdc)` = `_spendFreeValue` →
  > `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the
  > MAIN-Safe basket** (no `gate.depositFor`, no shares; 8-B6 then single-sides it into the gauge-staked LP) → NAV
  > accretes for every holder. **DELETED:** `payoutClean`/`payoutBoost`/public `spendFreeValue`/`setCompounder` +
  > `xAlpha`/`distributor`/`compounder` wiring + the entire `SzipRewardsDistributor`. **Kept:** `freeValueAccrued` +
  > `creditFreeValue` + `recycle` + internal `_spendFreeValue`. setUp decodes **5** addresses (owner/engineSafe/
  > operator/zipDepositModule/usdc). **19/19** (16 unit + 2 integrated + 1 Base-fork), superintendent-reverified;
  > `RecyclePayoutModule.*` + `SzipRewardsDistributor.*` DELETED. **8-B13 REMOVED** (absorbed here — single-sided LP
  > moots the balanced-add compounder). Spec/docs reconciled (§4.5.1/§2/§17; baal-spec/auto-compounder/treasury).
  > Inbound obligations stay discharged; the distributor/compounder/8-B13-seam outbound obligations are VOIDED.
  *(Historical pre-rework `RecyclePayoutModule` digest follows:)*
  *What it does:* the engine's free-value LEDGER + the two *distribute* sinks. `RecyclePayoutModule` (7th engine Zodiac
  Module, and the **only** one with real mutable state) owns the single `uint256 freeValueAccrued` (the §8-inv-3 free-value
  ledger). `creditFreeValue` (CRE-only `+=`, the 8-B9→8-B10 hand-off, single-arg net `max(0,realized−borrowRepaid)`),
  `spendFreeValue` (`onlyOperatorOrCompounder` decrement gate — the 8-B13 seam), `recycleModeB` (Mode B leg 1: debit then
  drive the REAL `ZipDepositModule.deposit` → senior backing + backed-1:1 zipUSD mint to the Safe), `payoutClean` (Mode A:
  debit + Safe→distributor USDC), `payoutBoost` (Mode B leg 3: Safe→distributor xALPHA, NO debit — value debited at
  recycle), `setCompounder` (owner set-once = 8-B13). `SzipRewardsDistributor` = a multi-asset Merkle cumulative-claim
  pull-claim YIELD distributor (clean-room from `reference/.../jane/RewardsDistributor.sol` `_claim` :159-191): per-asset
  root + per-asset `claimed`, `setRoot`(rootPoster=CRE), `claim`/`claimMultiple` (cumulative−claimed, effects-first +
  nonReentrant), `getClaimable` view; NO `maxClaimable`/mint machinery (held balance is the cap).
  *Locked shape:* sibling of `SellModule` (`is Module`/`setUp`-under-`initializer`/`onlyOperator`/`exec(Call,value 0)`/
  `_exec`-bubble) MINUS swap, PLUS the accumulator. **Free-value-only enforced TWO-LAYER:** (a) policy ceiling
  (`freeValueAccrued`, operator-TRUSTED, unbounded `creditFreeValue` = §17 trust not crypto) + (b) hard backing (real
  `safeTransferFrom`/`transfer` from the Safe — can't conjure value). Mode-B zipUSD backed 1:1 by construction (deposit
  precedes mint). **Effects-before-interaction** (decrement BEFORE the value-moving execs) — ORDERING-PROVEN by a mid-call
  readback, not just rollback. Payouts realized, never NAV (module never touches the oracle). Module = NO OZ
  `ReentrancyGuard` (clone-ctor-skip + effects-first + trusted wired targets); distributor = `nonReentrant` (real ctor +
  caller-supplied asset). Mode selection is CRE policy (entrypoint choice), not on-chain.
  *Holes surfaced → resolution:* (1) §4.5.1 "Loot holders" + "payout-mode flag/distribution checkpoints" → **2 spec-fixes**
  (szipUSD holders; stateless+distributor) — spec-fidelity critic found ZERO further gaps; (2) `creditFreeValue` single-arg
  vs `max(0,…)` formula → single-arg operator-trusted (the formula is the CRE's off-chain derivation), faithful; (3) the
  whole distributor is the YIELD payout path, spec-justified + DISTINCT from the M2 insurance-cohort premium (which has
  NO distributor — route-to-sidecar + NAV pro-rata, §4.6/§11); (4) junior/qa/security folds: pinned event sigs, zero-amount guard placement (`_spendFreeValue` + `payoutBoost`
  own guard), `onlyOperatorOrCompounder` (zero compounder never authorizes), OZ5 `Ownable` ctor, `getClaimable` takes no
  proof, the in-test Merkle sorted-pair rule, the fork-free real-`ZipDepositModule` rig (model `ZipDepositModule.t.sol`),
  the decrement-before-exec readback test, the reentrancy split, cross-asset/no-root/down-bump negatives, the trust-boundary
  NatSpec. *Security:* no exploitable bug under §17 single-CRE-operator; over-credit/forged-root are operator-trust-bounded
  (logged as 8-B11 fund-discipline + 8-B12 tripwire obligations). *Cross-ticket:* **discharged** the 8-B9→8-B10 free-value
  hand-off + the 8-B6 backed-zipUSD invariant (mechanism side); *created* the 8-B13 `spendFreeValue` seam, the item-10/8-B11
  wiring (atomic clone+setUp + distributor deploy + root posting), the item-10 audit sweep, the 8-B11/8-B12
  funding-precedes-claim + the NAV-XOR-accumulator + the CRE net-computation obligations. **45/45 (22 unit + 3
  integrated-no-fork against a REAL ZipDepositModule/ESynth + 2 Base-fork against a REAL summoned Safe + 18 distributor),
  427/427 total, ZERO load-bearing guesses.** Code `contracts/src/supply/szipUSD/{RecyclePayoutModule,SzipRewardsDistributor}.sol`
  + `contracts/test/{RecyclePayoutModule,SzipRewardsDistributor}.t.sol`. `tickets/sodo/8-B10-recycle.md`;
  `reports/8-B10-report.md`. NEXT engine contract = 8-B13 (Mode C compounder; deps 8-B6+8-B10 done).
- **S1 · `RecycleModule.divert` — loss-side Stream 2 (`solvency.md` §C.S1) — BUILT-VERIFIED + KEPT 2026-06-09.**
  *What it does:* a SECOND spend mode on the BUILT `RecycleModule` (8-B10) that **supplies engine free-value USDC
  straight into the credit warehouse** to fill the capital hole a default left behind — `divert(usdcAmount)` =
  bounds → `_spendFreeValue` → `eePool.deposit(usdcAmount, warehouse)` (**raw USDC, NO zipUSD minted, NO senior
  claim**) — bounded by the live `SzipNavOracle.provision()` hole. Distinct from `recycle` (which mints backed zipUSD
  into the basket for NAV accretion); both debit the same `freeValueAccrued` ledger and leave the other working on
  the remainder. *Locked shape:* 3 new set-once wiring slots (`navOracle`/`eePool`/`warehouse`, clone-safe non-
  `immutable`, setUp 5→8, 3 Timelock `WiringSet` setters); order load-bearing — **bounds-before-spend, then CEI**
  (ZeroAmount → NoHole → ExceedsHole [`usdcAmount*1e12 > provision()`, strict `>`, scales USDC 6-dp→USD 18-dp] →
  `_spendFreeValue` → approve/deposit/reset → guards → `Filled`). 2 local interfaces (`ISzipNavProvision`,
  `IEulerEarn`); errors `NoHole`/`ExceedsHole`/`NoSharesMinted`/`BackingShortfall`. **TWO value guards after the
  deposit:** hard-backing (Safe USDC fell by EXACTLY `usdcAmount` → `BackingShortfall`) + liveness (warehouse
  EE-share balance rose → `NoSharesMinted`). Divert NEVER writes `provision` (the CRE reduces the hole later via
  `DefaultCoordinator.Recovery`; `Filled.provisionAfter == the pre-spend hole`). No `nonReentrant` (clone-ctor-skip +
  effects-first, sibling of `recycle`). *Holes surfaced → resolution:* (1) **security MED F5** — the spec's required
  share-rose guard proves *liveness*, not *value moved*; a malicious EE could mint warehouse shares without pulling
  USDC → **promoted the USDC-fell hard-backing assert into the contract** (`BackingShortfall`), matching the module's
  own HARD-BACKING doctrine (preserve-intent hardening, flagged for superintendent); (2) **security MED F2** —
  huge-provision → drain free value = §13-accepted **grief** (USDC still lands in the bank; bounded by the trusted
  Coordinator+CRE pair + the deferred invariant-fuzz), not theft; (3) qa — the value-flow test MUST use a LIVE Safe +
  real `EEMock` (a non-live RecordingSafe would falsely trip the share-rose guard) + new 2-arg `deposit` mocks
  (stingy/free-mint/readback). NO spec gap (spec-fidelity FAITHFUL; **no `claude-zipcode.md` edit**). *Cross-ticket:*
  *created* the item-10/S2 wiring (`setNavOracle`/`setEePool`/`setWarehouse` + the one-bank deploy-asserts
  `warehouse == ZipDepositModule's warehouse` AND `eePool == ZipDepositModule.eePool()`), the loss-side audit sweep +
  the `divert ≤ min(freeValueAccrued, provision/1e12)` invariant-fuzz, the 8-B11 CRE divert-sizing + Recovery
  follow-up. **15 new tests** (13 `RecycleModuleDivertTest` LIVE-Safe unit/integrated + 1 Base-fork divert vs a real
  summoned Safe + 1 Stream-2 setter test), ZERO load-bearing guesses. Code
  `contracts/src/supply/szipUSD/RecycleModule.sol` (the `divert` mode) + `contracts/test/RecycleModule.t.sol`.
  `tickets/sodo/S1-recycle-divert.md`; `reports/S1-report.md`. The loss side is now fully built on-chain; NEXT = S2
  item-10 deploy/wiring.
- **8-Bw · `CreditWarehouse` + `WarehouseAdminModule` (§4.5/§8.5/§11, `baal-spec §11`) — BUILT-VERIFIED + KEPT
  2026-06-09.** The **SENIOR** custody: a plain **Gnosis Safe** holds the `EulerEarn` shares backing all zipUSD float
  (the "protocol's holding"); a deployed **Zodiac Roles-modifier-v2** (`enableModule`'d on the Safe) is the audited
  access-control engine; and the authored **`WarehouseAdminModule is ReceiverTemplate`** (the SOLE Roles role member,
  `assignRoles`'d — NOT an enabled Module) decodes the §8.5 envelope `(uint8 opType, bytes payload)` → one of 4 scoped
  ops → `Roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)`. **Locked shape:** the **scope IS the security
  boundary** (params pinned `EqualToAvatar`/`EqualTo`, Call-only `ExecutionOptions.None`) — the adapter holds no custody
  and enforces no scope; it injects receiver/spender/owner (belt-and-suspenders) and passes only REPAY's `to` through
  (scope-guarded). Op-set: SUPPLY=1 `deposit(amount, Safe)`, APPROVE=2 `approve(EE_POOL, amount)`, REDEEM=3
  `redeem(shares, Safe, Safe)`, REPAY=4 `transfer(repaySink, amount)`. **EulerEarn MOCKED** (solc 0.8.26, WOOF-04/05
  precedent); the **real Roles mastercopy `0x9646…D337` + ModuleProxyFactory + Safe factory/singleton + USDC** are
  live-fork. **Holes surfaced → resolution:** the 3 §4.5/§8.5 "open items" RESOLVED + folded to spec (redeem owner-3rd;
  redeemed USDC→Safe-then-REPAY; APPROVE scope-free + CRE exact-amount; `LOANBOOK`→pinned `repaySink`; opType bytes);
  `ISafe.setup` was ABSENT (added); `IRoles` lacked `scopeFunction`+`ConditionFlat` (extended); the 4 `ConditionFlat[]`
  trees pass `Integrity.enforce` as authored. **2 build-discovered on-chain corrections** (deployed mastercopy newer
  than the vendored ref): non-member → `NotAuthorized` (the `moduleOnly` gate fires before `NoMembership`), non-owner →
  `OwnableUnauthorizedAccount` (zodiac-core OZ-5 custom error, not an OZ-4 string); + the deployer is the **transient**
  Safe/Roles owner during wiring then hands off to GOD-EOA. **Cross-ticket:** *inbound* — the §4.5 open-items DISCHARGED
  (folded to spec); the 8-B5 "reservoir vault = warehouse resting vault" row ROUTED to item-10 (it is EE
  curator/allocator config, not an adapter op). *Created* — the item-10 audit sweep; the item-10/8-B11 seal +
  drain-defense (HIGH: `repaySink` SPOF must be immutable; `WithinAllowance`/Delay Modifier elevated to recommended;
  exact-amount APPROVE; don't-fund-before-sealed; distinct workflowId; non-commingling asserts); the item-9 REDEEM/REPAY
  seam; the CRE-04 envelope reconcile. **23/23 on a live Base fork, 424/424 total, ZERO load-bearing guesses.** Code
  `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` + `contracts/script/CreditWarehouseDeployer.sol` +
  `contracts/test/WarehouseAdminModule.t.sol` + `contracts/test/mocks/MockEulerEarn.sol` + NEW
  `src/interfaces/euler/IEulerEarn.sol` + EXTENDED `src/interfaces/zodiac/IRoles.sol`/`src/interfaces/safe/ISafe.sol`.
  `tickets/sodo/8-Bw-credit-warehouse.md`; `reports/8-Bw-report.md`. Run `forge test --fork-url $BASE_RPC_URL
  --match-contract WarehouseAdminModule` — green, run it yourself.
- **9 · `ZipRedemptionQueue` (§4.5/§6.1 / baal-spec §12) — BUILT-VERIFIED 2026-06-09.** *What it does:* the SENIOR
  exit — un-staked zipUSD → USDC at **par ($1)** via a **30-day epoch queue** with **pro-rata partial fills** +
  **carry-forward** when the warehouse can't free enough cash; the inverse of the WOOF-06 mint. NOT the junior Exit
  Gate (different instrument, par not NAV). *Locked shape:* `contract ZipRedemptionQueue is ReentrancyGuard` —
  **clean-room** (NOT inherited): the ERC-7540 `requestRedeem→settle→claim` lifecycle + EIP-7540 `setOperator` shape
  from `reference/erc7540-reference`, but escrowing **external** zipUSD (`ESynth`) and paying USDC at **par**
  (`÷scaleUp`, derived in-ctor, same as the deposit-module mint) — NOT solmate's `share==this`/NAV `convertToAssets`.
  Pro-rata via a **global cumulative-remaining factor `cumRemaining` (PREC=1e27) scoped by an `era` counter**
  (the Maple `:367-387` idea, clean-room): O(1) per op, iteration-free, auto-carry across epochs with no per-user
  action, **fair/censorship-resistant** (no `settleEpoch` caller can omit a requester). `_realize` ceil(pendingNow)
  /floor(filled); a 100%-drain **bumps `era` + resets `cumRemaining`** (`eraAt<era ⇒ fully filled`) — the zero-safe
  full-drain. **Funded externally** by the warehouse REDEEM→REPAY (the queue reads its **own** USDC balance, calls
  **no** EulerEarn — KR-1). Privileged op `settleEpoch` gated on an **immutable `controller`** (the CRE
  redemption-settle operator), **never renounced**, **no Owned/owner/sweep/pause** (non-sweepable — KR-2). zipUSD
  burned at settle via `ESynth.burn(address(this),·)` (own-balance, no allowance/capacity). *Holes surfaced →
  resolution (all in the ticket, pre-build):* **(div-by-zero, junior-dev)** the naive `cumRemaining*=R` hit 0 on a
  full fill → fixed with the **`era` construct**. **(CRITICAL value-destruction, security)** the era bump keyed on
  `filledShares==pending` but `filledShares` is always a `scaleUp` multiple while `pending` (zipUSD) can carry
  sub-`scaleUp` dust → era never bumps → `cumRemaining` decays to 1 → zipUSD burned with **no claimable USDC**,
  every invariant still green → fixed by **`require(shares % scaleUp == 0)`** in `requestRedeem` (par is whole-
  USDC-unit anyway; also kills the sub-`scaleUp` dust-trap). **(qa)** added the **ghost-accumulator solvency
  harness** `ghost_totalPaid <= ghost_totalDelivered` (the binding invariant), donation-tolerant `zipBalance >=
  totalPending`, redeem/withdraw zero guards, cross-era + over-funded + boundary tests, `block.timestamp`-anchored
  epoch clock. *Spec edit:* a whole-USDC-unit redemption-granularity clarification to `claude-zipcode.md §6.1`
  (faithful, not a mechanism change). *Cross-ticket:* **DISCHARGED** the warehouse REDEEM/REPAY seam (PROGRESS row
  317 — no EulerEarn coupling, settles own balance, non-sweepable, fork-proven against the real `WarehouseAdminModule`
  + real `ESynth` burn). **Disambiguated** PROGRESS row 272 ("Item 9 · sidecar rotation") = baal-spec-§8's *freeze/
  rotation module* (item-10/8-B11), NOT this senior queue — annotated. *Created (item-10):* wire `repaySink==queue`
  + `controller`=CRE-settle-operator (distinct identity); the REPAY Roles-scope re-target authority must be the
  timelock/multisig NOT the settle operator (security F6); the senior-queue `audit/2`/`audit/3` rows (deferred like
  8-Bw). *Proof:* **44/44** (37 unit + 5 invariant/fuzz @128k calls + 2 Base-fork), **468/468 total no regression** —
  `forge test [--fork-url $BASE_RPC_URL]` (independently re-run). **ZERO load-bearing guesses.** Code:
  `contracts/src/supply/ZipRedemptionQueue.sol` + `contracts/src/interfaces/euler/IZipUSD.sol` +
  `contracts/test/ZipRedemptionQueue.t.sol`. NOT git-committed (superintendent commit decision). Ticket
  `tickets/sodo/9-zip-redemption-queue.md`; `reports/9-report.md` — run it yourself.
- **10 · Deploy + wiring script (§9)** — vanilla Euler/OZ/CRE config; covers audit/2.md S1–S12 (deploys + installs
  the hook, wires + freezes each per-line `ROUTER_i` inside `openLine` [no shared router / no `govSetFallbackOracle`],
  renounces ESynth ownership, etc.).
- **8-Bx · `LienXAlphaEscrow` (§4.6/§11/§2)** — **BUILT-VERIFIED + KEPT 2026-06-09** (`contracts/src/loss/LienXAlphaEscrow.sol`,
  44/44 + 512/512 total, `forge test` green — run it yourself). **What it does:** per-lien xALPHA first-loss bond
  custody — a standalone, fully-immutable, **non-sweepable** vault (the loss-side sibling of item 9 `ZipRedemptionQueue`).
  **Locked shape:** `is ReentrancyGuard` only base; 4 immutables (`xAlpha`/`coordinator`/`capitalSink`/`sidecar`, all
  ctor-zero-checked); per-lien book keyed by **`bytes32 lienId`** (canonical type); four `onlyCoordinator nonReentrant`
  CEI state-changers — `lockXAlpha(lienId,originator,amount)` (pull-in, no clobber, M1-live) / `releaseXAlpha` (full →
  recorded originator, M1-live) / `slashXAlphaToCapital(amount)` (partial ≤ bond → `capitalSink`, off-chain alpha→TAO→USDC,
  mock-tested M2-live) / `slashXAlphaToCohort` (remainder → `sidecar`, in-kind premium, mock-tested M2-live). Models
  `InsuranceFund.bring:33`. **Security thesis (128k-call invariant-proven):** DESTINATION integrity — no recipient param,
  funds only ever reach {recorded originator, immutable capitalSink, immutable sidecar} ⇒ a compromised coordinator
  **cannot steal**; residual = grief (premature release / slash-healthy), the coordinator's §13 trust boundary, NOT
  closed on-chain (dumb-router mandate). **Holes surfaced → resolution:** (1) §4.6 cohort-distributor was stale
  RewardsDistributor/snapshot language contradicting §11/§6.4 "no per-position index, no SBT" → **spec fixed** to
  route-to-sidecar + NAV-pro-rata. (2) `lienId` was `uint256` → **`bytes32`** to match controller/CRE. (3) the as-drafted
  reentrancy probe couldn't fire (all entrypoints `onlyCoordinator`) → probe sets `coordinator==reentrant token`. **Cross-
  ticket obligations CREATED:** item-10 wiring (4 immutables + feeless-token assert + coordinator-approval + terminal-call
  operational invariant); `DefaultCoordinator` owns the slash split-policy + drives the calls; `SzipNavOracle` must value
  the sidecar xALPHA leg (so route-to-sidecar = the socialized pro-rata). `tickets/loss/8-Bx-lien-xalpha-escrow.md`,
  `reports/8-Bx-report.md`.
- **DC · `DefaultCoordinator` (§4.6/§11/§7/§8.4)** — **BUILT-VERIFIED + KEPT 2026-06-09** (`contracts/src/loss/DefaultCoordinator.sol`
  + `contracts/src/interfaces/loss/{ISzipNavOracle,ILienXAlphaEscrow}.sol` + test; 63/63 + 575/575 total, `forge test`
  green — run it yourself). **What it does:** the single loss-side orchestrator — NAV-provision writer (`SzipNavOracle`)
  + xALPHA bond router (it IS `LienXAlphaEscrow.coordinator`, so it owns the **full** bond lifecycle). **Locked shape:**
  `is ReceiverTemplate` (the same CRE base `SzipNavOracle` uses), renounce-frozen; immutables `navOracle`/`xAlpha`/
  `recoveryFloor` (`<1e18`, the governed day-one provision floor) + the set-once `setEscrow` (breaks the escrow↔coordinator
  **circular deploy** + `forceApprove(escrow, max)` so `lockXAlpha`'s pull from this coordinator succeeds). Per-lien
  `(LienStatus status, uint256 provision)` ledger + `totalProvision` pushed to `writeProvision`. **reportType-8 action
  dispatcher** in `_processReport`: LOCK/RELEASE (M1-live bond custody) + DEFAULT/RECOVERY/RESOLVE/WRITEOFF (M2, mock-tested).
  **The bound (its reason to exist):** the oracle's `writeProvision` is unbounded by design; the coordinator constrains it —
  DEFAULT sets `provision = atRisk×(1e18−recoveryFloor)/1e18` (round-down), RECOVERY reduces by `min(provision, proceeds)`
  (floored 0), RESOLVE→0, WRITEOFF settles the residual permanently (NO `writeProvision`); `totalProvision == Σ
  lienLoss.provision == oracle.provision()` invariant + an independent `ghost_cap` proven over 128k calls — **no
  arbitrary-NAV path, never above the un-impaired basket.** Status machine forbids re-recognition / post-resolution heal /
  release-of-defaulted / **LOCK-on-terminal** (the escrow would allow a re-lock at `bondAmount==0`; the coordinator's
  status guard is what blocks it). RESOLVE/WRITEOFF drive `slashXAlphaToCapital`(if>0)→`slashXAlphaToCohort` (reads
  `escrow.bondAmount` to skip cohort on a full-capital slash). **Security thesis (§13 boundary, NatSpec-documented):**
  bounds + routes; does NOT validate a default is real — `atRisk`/`recoveryProceeds`/`capitalSlashAmount`/`originator` are
  CRE-supplied, so the bound constrains the TRANSFORM not the magnitude; a compromised CRE can **grief** (down-mark NAV →
  exit-poor; slash healthy; reclaim via hostile originator) but **cannot steal** (escrow destinations immutable except the
  originator leg) or inflate NAV. **Holes surfaced → resolution:** the only spec gaps were the under-defined §8.4 report ABI
  + the coordinator's concrete shape → **spec surgery FIRST** (§4.6 build-grade bullet + §4.4 reportType-8 row + §8.4 action
  decode; spec-fidelity verdict FAITHFUL = detailing, no §17 reopen). Critic catches folded pre-build (no re-fan): the
  `MockNavOracle` shape + OZ-vs-forge-std `IERC20` trap (junior); the tautological-fuzz → **independent `ghost_cap`
  invariant handler** + floor boundaries + the full illegal-transition matrix + atomic-rollback-on-`ExceedsBond` (qa); the
  residual-trust NatSpec block + the **hard tested renounce gate** + the WRITEOFF-must-not-decrement Do-NOT (security).
  **Obligations DISCHARGED:** provision-bound (to `SzipNavOracle`) + slash-driver (to 8-Bx). **Obligations CREATED:** item-10
  circular-deploy + hard renounce-gate `require`s; xALPHA just-in-time funding (non-sweepable, feeless token); CRE §8.4
  off-chain arithmetic; the item-10/M2 audit sweep. `tickets/loss/DefaultCoordinator.md`, `reports/DefaultCoordinator-report.md`.
- **— · `DurationFreezeModule` (Duration-Bond trigger B, §11-B/§6.4/§8.2)** — **BUILT-VERIFIED + KEPT 2026-06-09**
  (`contracts/src/supply/szipUSD/DurationFreezeModule.sol` + the additive `SzipNavOracle` views + the two interfaces +
  `contracts/test/DurationFreezeModule.t.sol`; **40/40 module, 628 total no regression, independently re-run from
  `forge clean`**; the 42-test oracle suite + `grossBasketValue` pins unchanged). The **rotation/floor actuator** for the structural sidecar freeze —
  the orphan that baal-spec §8 parked as "item 9 / 8-B11" but never got a build slot (the `ExitGate.sol:40` `// (item 9
  rotation)` comment is the fingerprint). **What it does:** a Zodiac `Module` enabled on **BOTH** Safes (main + non-RQ
  sidecar) — `commit(asset,amount)` main→sidecar (operator-gated, **ungated by value**: raising the freeze is peg-safe)
  + `release(asset,amount)` sidecar→main (operator-gated, **autonomously floor-gated**). It moves only the **five
  whitelisted liquid legs** (zipUSD/usdc/xAlpha/hydx/oHydx read from the oracle at setUp; the LP is moved by 8-B6,
  not here), `value==0`/Call-only via `ISafe(src).execTransactionFromModule`, balance-delta-asserted, no recipient
  param (destinations are the literal set-once Safes). **Locked shape (the bounds-not-validates thesis, §13):** the
  load-bearing guard is the **release floor** — `release` reverts unless `committedValue() ≥ requiredFraction(U)×
  grossBasketValue`, where **`requiredFraction = U`** (freeze% = utilization%, DEAD-SIMPLE — superintendent 2026-06-09;
  the §11-B `max(U, escalation)` band over `U_lock`/`U_max`/`maxLockFraction` is **post-M1, not built**), and **U is
  read live + donation-immune** off the senior pool (`1 −
  maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))`). So the operator picks *which/how-much* to rotate; the
  contract bounds the *release value* on-chain → **even a compromised operator can't open the run hatch** while
  utilization is breached. Gates the Exit Gate **structurally** (by what's kept out of the main Safe — no ExitGate
  change). No markdown, no xALPHA bond/premium, no Exit-Gate/DefaultCoordinator coupling (trigger B is liquidity-only).
  **Holes surfaced → resolution:** (spec-fidelity FAITHFUL on all 5 flagged tensions — the autonomous floor is faithful
  §11-B/§6.4 detailing per the §4.6 precedent; freeze% = utilization (φ_A=U; the `max(U,esc)` escalation band was built
  then STRIPPED post-conclusion — post-M1); `commit` ungated + no separate redeemability cap [baal-spec §8.8's
  "redeemability cap" is **stale**, dies with that file]; dropping
  `maxDuration`/`releaseHysteresis` faithful under the continuous floor). **SECURITY CRITICAL caught + fixed FIRST:** the
  v1 `idle = balanceOf(eulerEarn)` U-read was **wrong** (EulerEarn `totalAssets()` excludes idle → idle≈0 → U≈1 → bricks
  release) **and donatable** (transfer USDC to the pool → lower U → lower floor → over-release run-hatch) → **redesigned
  to the `maxWithdraw` read + fixed spec §8.2/§11-B** (the §8.2 "idle"/"borrowed/totalAssets" framing was the spec's own
  error). **SECURITY HIGH:** non-basket-asset leak → the 5-leg whitelist. Folded (no re-fan): the additive oracle
  `committedValue()`/`freeValue()` (**grossBasketValue UNCHANGED** — 42-test pins hold; parity exact for plain legs,
  ≤2-wei for split LP; gross exactly rotation-invariant since the module never moves LP); the `FreezeHandler` 128k
  invariant; FoT mock + atomic-rollback; truncation pins; the `requiredFraction == utilization` identity vectors; donation-immunity
  test; the two-Safe `enableModule` fork plumbing. **Cold-build (fresh subagent, same window): ZERO load-bearing
  guesses, 40/40 module + 628 total green, independently re-run from `forge clean`** (the subagent hit forge
  incremental-cache phantoms that cleared on clean). The invariant is a per-successful-release ghost check (faithful to
  "after any successful release"). **Obligation DISCHARGED:** PROGRESS row 289 (sidecar-funding-after-team-owns —
  structural fail-closed + fork-proven enable-on-both + item-10 wiring). **Obligations CREATED:** item-10 (clone/setUp +
  enable-on-both-Safes + warehouse wiring + the **live-pool U donation-immunity verification**); CRE-05 drives the
  rotation; **no governed freeze params** (freeze% = utilization%, dead-simple); the audit/2+3 sweep. **Build-surfaced (not mine):** the branch
  `SzipNavOracle.sol` had already flipped its four set-once wiring setters to **Timelock-re-pointable** (test updated to
  match) — an authority-model change touching the item-10 renounce/freeze + DefaultCoordinator set-once assumptions;
  left intact, flagged for superintendent review. `tickets/sodo/DurationFreezeModule.md`, `reports/DurationFreezeModule-report.md`.
- **8x-02 · `SzAlphaRateOracle` — the Base xALPHA exchange-rate oracle + derived APR (§8.6/§8.8)** — the Base home
  for the one fact native only to Bittensor (the rate), and the §8.6 cross-chain-rate-seam resolution. **Locked
  shape (REDESIGNED ×2, user-directed 2026-06-09):** the arc — v1 pushed a **pre-computed APR** (over-built,
  adversarial deviation bands; the band spawned the "slash bricks the feed" knot it then solved); v2 derived
  **natively on 964** (right principle, wrong chain — the protocol + the NAV/Euler oracle are Base-side); **v3 (as
  shipped):** `exchangeRate` (`staked/supply`, `0x805`) is native only on 964 and the consumers are on Base, so the
  cross-chain pull **is** required and **is** a CRE job — but **CRE pulls the RATE (the primitive), not a
  pre-computed APR.** `SzAlphaRateOracle is ReceiverTemplate, IXAlphaRate` (Base): a CRE workflow
  (`cre/szalpha-rate/`) reads `SzAlpha.exchangeRate()` on 964 and pushes it RAW (`reportType RATE = 8`, payload
  `(uint256 rate, uint48 ts)`); the contract exposes **`exchangeRate()`** (the drop-in `SzipNavOracle`'s xALPHA leg
  + an Euler adapter read), `fresh()`/`lastUpdate()`, and a **DERIVED** `intrinsicAprBps()` view (`(rate_now/
  rate_prev−1)×year/Δ` over two rolling checkpoints the pushes maintain, floored-0/cap-clamped, advisory).
  **Truthful guards** (non-zero / not-future / **strictly-newer** — no replay/out-of-order); **NO deviation band**
  (a validator slash legitimately lowers the rate — a band would brick it or need a bypass); consumers
  **fail-closed on staleness** via `fresh()` (a rate that moves NAV must not serve stale). **Key design move:**
  *CRE transports the primitive; the chain derives NAV + APR* — nothing pre-computed is ever pushed or bridged.
  **Holes surfaced → resolution:** v1's deviation band was self-inflicted complexity (deleted); v2 mis-placed the
  derivation off the consuming chain (corrected). **Resolves the §8.6 cross-chain rate seam** — `SzipNavOracle`'s
  xALPHA rate read now has a defined Base producer. **Spec:** §8.8 rewritten (rate→Base oracle, APR derived); §8.0
  gains the `8` RATE / `SzAlphaRateOracle` row. **Cross-ticket obligations:** item-10 deploys `SzAlphaRateOracle` on
  **Base** (ctor `forwarder`/`maxStaleness`/`window`/`aprCap`, owner=Timelock) + runs the pull workflow + points
  `SzipNavOracle`'s xALPHA **rate** read at it (token stays the mirror for balances — the split is the seam fix);
  8-B12/8-B11 + the UI read `intrinsicAprBps()`/`fresh()`. 17/17 suite + 675/675 total non-fork.
  `tickets/bridge/8x-02-xalpha-apr-cre.md`, `reports/8x-02-report.md`.
- **— · `sdVAULT` yield-ENGINE (§4.5 / `auto-compounder.md`)** — **post-M1 module bolted onto the szipUSD vault,
  NOT a separate token.** Hydrex/oHYDX autocompounder + zipUSD/xALPHA POL; farms `oHYDX` → sells HYDX for net-new
  USDC → book AUM + xALPHA reward; the **free-value stream funds the duration boost + residual hole-plug**
  ("HYDX/USDC pays for duration and plugs holes"). DEFERRED (post-M1) — needs the §17 yield-routing flip + the
  Hydrex gauge whitelist. **Inputs real** (canonical xALPHA zero-work, CCIP lane live, Hydrex OTC).
- **— · xALPHA = "xALPHA" (one token, §2)** — the bridged subnet LST; does first-loss bond / Duration-Bond premium
  / szipUSD incentive / zipUSD-xALPHA POL leg / last-resort backstop (alpha→TAO→USDC) / treasury buyback target.
  The M2-sketch loss-side name sweep (`LienXAlphaEscrow`/`slashXAlpha*`) is a tracked follow-up.
