# 8-B14 — `SzipBuyBurnModule` — haircut buy-and-burn bid module (§7)

> **NEXT / build-only.** The §7 "haircut buy-and-burn" splits across two contracts by *authority*: the **bid side**
> (this ticket — a Zodiac Module on the engine Safe that posts the discounted resting CoW `BUY szipUSD` order and
> enforces the §7.4 bounds **on-chain**) and the **burn side** (the already-built `ExitGate.burnFor`, the
> `manager(2)` path, called by the CRE **windowController** after fills). This ticket builds the **bid module
> only** — no edit to the kept Gate. Internal engine plumbing → **build-only** (no INFLOW ticket; the frontend never
> wires to it, CRE drives it).
>
> **Spec edits made this window (baal-spec §7.2/§7.4), honor them:** (a) the bid prices off **`navExit = min(spot,
> twap)` × (1 − d)`** — the buyer-conservative §3 mark — **not** bare `twapNAV` (a buyer must not overpay off a
> stale-high twap when NAV is trending down); (b) the burn caller is named the **windowController** via
> `ExitGate.burnFor` (the module never burns); (c) "Roles-scoped engine Safe" is dropped — it is a **plain engine
> Module (§10.1)** signing PRESIGN via `Operation.Call`.

**Deliverable**
One contract + one interface + tests under the supply/engine tree:
- `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` — `contract SzipBuyBurnModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the engine Safe**
  (`avatar == target == engineSafe`). It makes the protocol the **discounted buyer of last resort** for szipUSD: on
  the operator's tick it posts a **single resting** CoW `BUY szipUSD` limit order, `sellToken = USDC`, priced **at or
  below `navExit × (1 − d)`** off `SzipNavOracle`, `sellAmount ≤ buybackCap`, `partiallyFillable`, `receiver =
  engineSafe` — signed on-chain via **PRESIGN** (`GPv2Settlement.setPreSignature`). Everything it buys lands in the
  engine Safe; the **burn** is the existing `ExitGate.burnFor` (out of this contract's scope — see "The burn side").
- `contracts/src/interfaces/cow/IGPv2Settlement.sol` — minimal CoW settlement interface.
- `contracts/test/SzipBuyBurnModule.t.sol` — unit (recording-mock Safe) + fork (live Base CoW/USDC) tests.

It is the **first engine Zodiac Module** (8-B5…B13 follow). Establish the `is Module` + `setUp(bytes)`-under-
`initializer` + `onlyOperator` + `exec(...,Operation.Call)` pattern the rest of the engine inherits (§10.1).

**Spec §**
`baal-spec.md` **§7** (the buy-and-burn module — what/mechanics/trace/bounds, **edited this window**), cross:
- `baal-spec.md` **§6** (CoW over szipUSD/USDC; `SigningScheme.PRESIGN` lets a Safe place CoW orders on-chain; never
  read the szipUSD market price for accounting, §6.3/§3.4).
- `baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, **one immutable CRE operator** =
  `onlyOperator`, mutate the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via
  `ModuleProxyFactory`, init in `setUp` under `initializer`) + **§14** (`d`, `buybackCap` = governed params).
- `baal-spec.md` **§3** (NAV oracle = the pricing primitive — `navExit()` / `twapNavPerShare()` / `fresh()`, 18-dp
  USD/share) and **§18.2** (`burnLoot` = pure supply reduction, NO asset payout — the retire path).
- `claude-zipcode.md` **§4.5.1** (engine module architecture; 8-B14 = "engine USDC posts discounted standing bids
  below NAV and burns") / **§17** locked: the protocol **never reads the szipUSD market (CoW) price for accounting**;
  pari-passu, no peg defense; priced off §3.

**Model from (VERIFIED against `reference/` and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol` (`pragma ^0.8.24`, compiles under 0.8.24).
  **Verified:** `abstract contract Module is FactoryFriendly, Ownable`; `setUp(bytes) public virtual` from
  `FactoryFriendly`; `initializer` is **zodiac-core's own** (`factory/Initializable.sol`, one-shot, reverts
  `AlreadyInitialized`) — **NOT** OZ's. `exec(to,value,data,Operation)` is `internal virtual` →
  `IAvatar(target).execTransactionFromModule(to,value,data,operation)`; `Operation { Call, DelegateCall }`. `Ownable`
  is **zodiac-core's own** (`factory/Ownable.sol`): `address public owner`; `onlyOwner` reverts
  `OwnableUnauthorizedAccount`; `transferOwnership(newOwner) public onlyOwner`; `_transferOwnership(newOwner)
  internal` (no guard — use this in `setUp`). **Remap `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/`
  is already in `remappings.txt`** (verified resolves). **zodiac-core imports ZERO OpenZeppelin** (own Ownable/
  Initializable) → no OZ-4/5 collision with the Euler OZ-5 tree (verified by grep + the WOOF-00 probe).
- **CRITICAL clone fact (§18.6).** A `ModuleProxyFactory` clone shares the **mastercopy's** runtime bytecode, so
  **`immutable` values are baked into the mastercopy at ITS construction and are identical for every clone** — they
  CANNOT carry per-clone `setUp` config. **Every per-clone wired address/param (`operator`, `engineSafe`, `navOracle`,
  `szipUSD`, `usdc`, `settlement`, `vaultRelayer`, `domainSeparator`, `dBps`, `buybackCap`) MUST be plain storage set
  in `setUp` — NOT `immutable`.** Make them set-once (write only in `setUp`, guarded by `initializer`); the governed
  `dBps`/`buybackCap` get `onlyOwner` setters. Init-lock the mastercopy at deploy (§18.6).
- **CoW PRESIGN on-chain surface** — **verified live on Base 8453 (2026-06-08, `cast`):**
  - `GPv2Settlement` = `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (~32 KB; **same address all chains**).
    `domainSeparator()(bytes32)` = `0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b` on Base.
    `vaultRelayer()(address)` = `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`. `setPreSignature(bytes orderUid,
    bool signed)` (selector `0xec6cb13f`) stores the presignature keyed by the `owner` packed in `orderUid` (must ==
    `msg.sender` = the Safe on the `exec` Call). `preSignature(bytes)(uint256)` (selector `0xd08d33d1`) reads back
    (0 = unsigned, nonzero = signed).
  - `GPv2VaultRelayer` = `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` (~9 KB) — the spender USDC is `approve`d to.
    **Read it live in `setUp`** (`settlement.vaultRelayer()`), store it; do not hard-trust the constant.
  - `CowswapOrderSigner` (Gnosis Guild) = `0x23dA9AdE38E4477b23770DeD512fD37b12381FAB` (~3.6 KB) — the SDK's
    delegatecall signer (`reference/zodiac-modifier-roles/packages/sdk/src/swaps/encodeSignOrder.ts`). **Reference-only**
    for the order hashing; this module does **NOT** delegatecall it (see "Signing"). Useful as a fork ground-truth for
    the uid test (below).
- **GPv2 order hashing (replicate, Call-only) — verified against the SDK + canonical `GPv2Order.sol`:**
  - `TYPE_HASH = keccak256("Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256
    buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,bytes32 kind,bool partiallyFillable,bytes32
    sellTokenBalance,bytes32 buyTokenBalance)")` — **verified** `cast keccak` =
    `0x1a59c8ffcce6fc2e6738119e0d2e050163ef0912ac7168f28acd39badd252b51` (the canonical GPv2 type hash).
  - `KIND_BUY = keccak256("buy")` (`0x6ed88e8…29ccc`); `BALANCE_ERC20 = keccak256("erc20")` (`0x5a28e93…060dc9`).
  - `structHash = keccak256(abi.encode(TYPE_HASH, sellToken, buyToken, receiver, sellAmount, buyAmount,
    uint256(validTo), appData, feeAmount, kind, partiallyFillable, sellTokenBalance, buyTokenBalance))` (EIP-712:
    each field a 32-byte word; `validTo` widened to `uint256`; `partiallyFillable` the 32-byte bool;
    `appData`/`kind`/balances are `bytes32`).
  - `orderDigest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash))`, `domainSeparator` read live
    from the settlement (cached in `setUp`).
  - `orderUid = abi.encodePacked(orderDigest /*32*/, owner /*20, = engineSafe*/, validTo /*uint32, 4*/)` → **56 bytes**.
- **`SzipNavOracle`** (`contracts/src/supply/SzipNavOracle.sol`, built+kept) — **verified:** `navExit() external
  view returns (uint256)` = `min(spot, twap)`, 18-dp, **does not revert on staleness**; `twapNavPerShare() public
  view returns (uint256)`, 18-dp; `fresh() public view returns (bool)` (both required pushed legs within `maxAge`).
  Price off **`navExit()`**, gate on **`fresh()`** (since `navExit` won't revert stale). NOTE the oracle ALSO has
  `setEngineSafe` (`:183`) — its denominator excludes the engine Safe's transient szipUSD; that wiring must point at
  the SAME Safe (deploy/item-10 concern, asserted in the identity check).
- **`ExitGate`** (`contracts/src/supply/szipUSD/ExitGate.sol`) — **verified** `burnFor(uint256 amount)` gated
  `if (msg.sender != windowController) revert NotWindowController()` (`:251-258`); does `baal.burnLoot([gate],[amt])`
  + `SzipUSD.burn(engineSafe, amount)` (burns from `engineSafe`, pure supply reduction). The module's `engineSafe`
  == `ExitGate.engineSafe` (`:129` `setEngineSafe`). **Out of this contract's scope; no edit.**
- **`SzipUSD`** — `buyToken`. 18-dp, plain ERC20, `gate`-only mint/burn. Module needs its **address** only.
- **USDC** = `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (**6-dp**, verified live) — the `sellToken`. The 6-vs-18-dp
  reconciliation is load-bearing in the price bound (below).

**`GPv2OrderInput` — the exact operator-supplied struct (define it in the contract).**
The operator passes this; the module fixes/validates every field, then hashes the SAME struct into the uid (so the
signed order == the validated order — no field is both operator-supplied and unvalidated):
```solidity
struct GPv2OrderInput {
    uint256 sellAmount;          // USDC (6-dp) the protocol will pay — validated ≤ buybackCap, > 0
    uint256 buyAmount;           // szipUSD (18-dp) to buy — validated > 0; sets the limit price with sellAmount
    uint32  validTo;             // unix expiry — validated > block.timestamp, ≤ block.timestamp + MAX_BID_TTL
}
```
All other GPv2 fields are **module-fixed constants**, NOT operator inputs (this is the §4-attack hardening — no
unvalidated field enters the hash): `sellToken = usdc`, `buyToken = szipUSD`, `receiver = engineSafe`, `kind =
KIND_BUY`, `partiallyFillable = true`, `appData = APP_DATA` (a single pinned `bytes32` constant — an unconstrained
appData could attach hooks/partner-fees the validation never saw), `feeAmount = 0`, `sellTokenBalance = buyTokenBalance
= BALANCE_ERC20`. The module builds the full canonical order from `(usdc, szipUSD, engineSafe, sellAmount, buyAmount,
validTo, APP_DATA, 0, KIND_BUY, true, BALANCE_ERC20, BALANCE_ERC20)` and hashes exactly that. `owner` in the uid is
hard-coded `engineSafe`.

**Starting state**
`forge build` green on `main` (kept tree: SzipNavOracle, ExitGate+SzipUSD, ZipDepositModule, WOOF-00…05, 8-B1
substrate). zodiac-core is interface-available + remapped but **not yet inherited by any built contract** — this is
the first. The CoW addresses are **not yet in `BaseAddresses.sol`** — add them. `contracts/src/interfaces/cow/` does
not exist — create it. No engine Safe is summoned in unit tests — use a **recording mock Safe** (implements
`execTransactionFromModule`, records each `(to, value, data, operation)`) for validation/authority/calldata-shape
assertions, and a **real Base fork** (`ForkConfig`) for the live `GPv2Settlement.setPreSignature`/`preSignature` +
USDC allowance + domainSeparator/vaultRelayer reads. (Model the fork setup on `SzipNavOracle.t.sol` /
`ExitGate.t.sol`.)

**Do NOT**
- **Do NOT read the szipUSD CoW/market price for any decision** (§3.4/§6.3/§17). Price the bid **only** off
  `SzipNavOracle.navExit()` (the §3 mark). The CoW clearing price is an output, never an input.
- **Do NOT post a sell side.** §7.2 is one-sided. The module's order is BUY-only by construction (`kind` is a fixed
  constant, never an operator input).
- **Do NOT ever bid `≥ NAV`.** The implied limit price MUST be `≤ navExit × (1 − d)` with `dBps` in `(0, 10_000)`
  (§7.4). A bid above the ceiling is a hard revert (`BidAboveDiscount`), not a clamp. Re-assert `0 < dBps < 10_000`
  at post time (defense in depth).
- **Do NOT expose ANY generic `exec`/`call`/`multicall` passthrough, and never let the operator supply `to`/`data`/
  `operation`.** The operator passes ONLY the 3 `GPv2OrderInput` fields. The module's only `exec` targets are the
  fixed `usdc.approve` and `settlement.setPreSignature` with module-built calldata. (A single arbitrary-call path =
  a compromised operator key drains the Safe — this is the module's whole security boundary, §10.1.)
- **Do NOT grant an infinite USDC approval.** Approve the VaultRelayer **exactly `sellAmount`** for the live bid;
  reset to `0` on cancel (a stale resting approval + a stale presignature is double exposure / over-`buybackCap`).
- **Do NOT overwrite a live bid.** If a bid is live (`currentUid != 0`), `postBid` **reverts `BidAlreadyLive`** — the
  operator must `cancelBid` first (which flips the old presignature false + approval 0); a re-post then carries a
  **new `validTo`** (hence a new uid). Never two live presignatures.
- **Do NOT `delegatecall`** (§10.1: `Operation.Call` only, `value == 0`). Sign via the module's own
  `setPreSignature(uid)` (Call), keeping the uid in-contract (emittable/testable).
- **Do NOT touch `mintShares`/Loot/`ragequit`/the Gate's exit paths**, and **Do NOT call `burnFor`** — the burn is
  the windowController's authority on the Gate (separate seam).
- **Do NOT make `d`/`buybackCap` operator-settable** — `onlyOwner` (the TimelockController). **Assert `owner !=
  operator` in `setUp`.** Leave the inherited `setAvatar`/`setTarget` as the zodiac-core `onlyOwner` setters: the CRE
  `operator` (hot key) cannot call them, only the Timelock can, and a redirect by governance is a deliberate
  timelocked act — not an attack path. **Do NOT hard-lock them** (an `override`-to-revert needs the vendored
  zodiac-core setters marked `virtual`, and **`reference/` deps MUST stay pristine — never edit them**). The
  operator-can't-redirect property is what's tested; the compromised-Timelock residual is accepted (the same Timelock
  governs the whole module).
- **Do NOT edit anything under `reference/`** (it is a pristine vendored dependency tree). If a build needs a
  reference symbol that isn't `virtual`/exported, adapt the module — never patch the dep.
- **Do NOT use `immutable` for any `setUp`-decoded value** (clone bytecode is shared — see the CRITICAL clone fact).

**Key requirements**
1. **`is Module` substrate (§10.1).** `setUp(bytes initParams) public initializer` decoding
   `(address owner, address engineSafe, address operator, address navOracle, address szipUSD, address usdc,
   address settlement, uint16 dBps, uint256 buybackCap)`. In `setUp`: require all addresses nonzero, `owner !=
   operator`, `0 < dBps < 10_000`; set `avatar = engineSafe; target = engineSafe`; store `operator/navOracle/szipUSD/
   usdc/settlement` (set-once storage, NOT immutable); read+store `vaultRelayer =
   IGPv2Settlement(settlement).vaultRelayer()` and `domainSeparator = settlement.domainSeparator()`; store `dBps`/
   `buybackCap`; `_transferOwnership(owner)`. `setDiscountBps(uint16)`/`setBuybackCap(uint256)` are `onlyOwner`
   (`setDiscountBps` re-checks `0 < dBps < 10_000`). Override `setAvatar`/`setTarget` to `revert Locked()`. The
   mastercopy is init-locked at deploy (§18.6).
2. **`onlyOperator` gate (§10.1 invariant 1).** `postBid`/`cancelBid` gated to the single set-once `operator`; a
   non-operator caller reverts `NotOperator()`.
3. **`postBid(GPv2OrderInput calldata order)` — the bid (§7.2).** In order:
   - `if (currentUid.length != 0) revert BidAlreadyLive();` (single-resting-bid).
   - `if (order.sellAmount == 0 || order.buyAmount == 0) revert ZeroAmount();`
   - `if (order.sellAmount > buybackCap) revert CapExceeded();` (`buybackCap == 0` ⇒ always reverts = kill-switch).
   - `if (order.validTo <= block.timestamp || order.validTo > block.timestamp + MAX_BID_TTL) revert BadValidTo();`
     (`MAX_BID_TTL` = a bounded constant, e.g. `1 days` — far-but-bounded resting exposure; pin the value, comment it).
   - `if (!INavOracle(navOracle).fresh()) revert StaleNav();` (§7.4 staleness — `navExit` won't revert on its own).
   - `if (dBps == 0 || dBps >= 10_000) revert BadDiscount();` (re-assert).
   - **Price bound (§7.2/§7.4), exact integer form (USD 18-dp basis), reconciling USDC-6dp ↔ szipUSD-18dp ↔ nav-18dp:**
     `navExit18 = INavOracle(navOracle).navExit();` (USD-18dp per 1e18 share). The order pays `sellAmount` USDC
     (6-dp) for `buyAmount` szipUSD (18-dp). Value paid, in 18-dp USD = `sellAmount * 1e12`. Value of shares at the
     discounted ceiling, in 18-dp USD = `buyAmount * navExit18 * (10_000 - dBps) / 10_000 / 1e18`. Require **paid ≤
     ceiling**, cross-multiplied to a single division (floor the RHS **against the buyer** so the ceiling never
     rounds UP into an above-NAV fill):
     `require(order.sellAmount * 1e12 * 10_000 * 1e18 <= order.buyAmount * navExit18 * (10_000 - dBps), BidAboveDiscount)`
     — i.e. move BOTH `/10_000` and `/1e18` to the LHS as multipliers so the comparison is exact (no truncation on
     the bound). **The build MUST pin this exact form and prove the boundary with unit tests at the largest
     `sellAmount` that passes and `+1` that reverts, including a `buyAmount*navExit18*(…)` value that is NOT divisible
     by `1e22` (the non-divisible case is where a rounding bug hides).** Guard overflow: `buyAmount` is operator-
     supplied and NOT cap-bounded — the products are ~1e46 at realistic sizes (fine in uint256); add a sanity upper
     bound on `buyAmount` (e.g. `≤ 1e30`) or document the uint256 headroom + test a large-but-realistic `buyAmount`.
   - **Build the canonical order** from the fixed constants + the 3 validated fields; `uid = _orderUid(order)`;
     `exec(usdc, 0, abi.encodeCall(IERC20.approve, (vaultRelayer, order.sellAmount)), Operation.Call)`;
     `exec(settlement, 0, abi.encodeWithSelector(setPreSignature.selector, uid, true), Operation.Call)`; store
     `currentUid = uid; currentSellAmount = order.sellAmount;` `emit BidPosted(uid, order.sellAmount, order.buyAmount,
     order.validTo, navExit18, dBps)`. (Two `exec`s in one tx → atomic: a revert of the 2nd rolls back the approve.)
4. **`cancelBid()` — retract the resting bid.** `onlyOperator || onlyOwner` (both may cancel — owner = emergency).
   If `currentUid.length != 0`: `exec(settlement, 0, setPreSignature(currentUid, false), Call)` + `exec(usdc, 0,
   approve(vaultRelayer, 0), Call)`; clear `currentUid`/`currentSellAmount`; `emit BidCancelled(uid)`. Idempotent
   (no-op, no revert) when no live bid.
5. **The burn side is the existing Gate seam (documented, NOT built here).** After fills the engine Safe holds the
   bought szipUSD; the CRE **windowController** calls `ExitGate.burnFor(amount)` with `amount =
   SzipUSD.balanceOf(engineSafe)` read **on-chain** (not from fill events), ordering **fill → burnFor → re-post**.
   The report states the cycle `{postBid → CoW fill → windowController:burnFor}` and that `burnFor`'s `engineSafe`
   burn-source == the `engineSafe` wired here. No ExitGate edit.
6. **Events + views for the CRE op surface + monitoring (8-B11/8-B12 back-pressure).** `BidPosted`, `BidCancelled`;
   `currentBid() view returns (bytes memory uid, uint256 sellAmount)`; `quoteMaxPrice() view returns (uint256
   maxUsdc6PerShare)` = the current 6-dp USDC ceiling per 1e18 share = `navExit() * (10_000 - dBps) / 10_000 / 1e12`
   (the off-chain bid builder sizes against this; the on-chain check re-validates — the test round-trips the view
   against `postBid` to catch a 1e12 scale mismatch).
7. **Address book.** Add to `contracts/script/BaseAddresses.sol`: `COW_SETTLEMENT`
   (`0x9008D19f58AAbD9eD0D60971565AA8510560ab41`), `COW_VAULT_RELAYER`
   (`0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`), `COW_ORDER_SIGNER`
   (`0x23dA9AdE38E4477b23770DeD512fD37b12381FAB`, reference-only). Comment "read `vaultRelayer()` live in `setUp`".
8. **Interface.** `contracts/src/interfaces/cow/IGPv2Settlement.sol`: `domainSeparator() view returns (bytes32)`,
   `vaultRelayer() view returns (address)`, `setPreSignature(bytes,bool)`, `preSignature(bytes) view returns
   (uint256)`. Verify selectors live (`cast sig` — `setPreSignature(bytes,bool)`=`0xec6cb13f`).

**Done when**
- `forge build` green (zodiac-core inherited for the first time; no OZ collision).
- `forge test --fork-url $BASE_RPC_URL --match-contract SzipBuyBurnModuleTest` green, covering:
  - **uid correctness (non-circular):** assert `module._orderUid(sampleOrder)` equals a **pinned known-answer 56-byte
    vector** (a fully-specified order + the live Base `domainSeparator`, the expected uid computed out-of-band via the
    CoW SDK / `cast` and committed with a provenance comment) — NOT just an inlined re-hash. Also assert
    `uid.length == 56`, `uid[32:52] == engineSafe`, `uid[52:56] == validTo` (big-endian), and the module's
    `TYPE_HASH` constant == `cast keccak` of the canonical string. After `postBid` on the fork: `settlement.
    preSignature(uid) != 0` (live Base settlement stored it under the packed owner = the Safe) and
    `USDC.allowance(engineSafe, vaultRelayer) == sellAmount`. (Optional strongest cross-check: stage the order through
    the live `CowswapOrderSigner` and compare its uid.)
  - **price bound:** boundary pass at the largest `sellAmount` satisfying `≤ navExit×(1−d)` and `+1` reverts
    `BidAboveDiscount`, **including a non-`1e22`-divisible RHS** (proves the floor rounds against the buyer); a bid at
    `≥ navExit` reverts; a deep-discount bid passes.
  - **navExit vs twap:** with `spot < twap` (push the oracle so min(spot,twap)=spot < twap), assert the bid prices off
    `spot` (= navExit), i.e. an order that would pass off `twap` but not off `navExit` reverts — proves buyer-
    conservative pricing.
  - **cap / single bid:** `sellAmount > buybackCap` reverts `CapExceeded`; `buybackCap == 0` ⇒ every `postBid`
    reverts (kill-switch); a second `postBid` while one is live reverts `BidAlreadyLive`; outstanding allowance is
    always ≤ `buybackCap`.
  - **partial-fill-then-repost (the double-fill guard):** simulate a partial fill (warp / direct), then
    `cancelBid` → assert `preSignature(oldUid)==0` AND `allowance==0`; then `postBid` with a NEW `validTo` → new uid,
    allowance == new `sellAmount` only (never additive, no stale residue).
  - **atomicity:** force the 2nd `exec` (setPreSignature) to revert (mock-Safe path) → assert the `approve` is rolled
    back (`allowance == 0`), `currentUid` unset.
  - **freshness:** push both legs, `vm.warp(now + maxAge + 1)` → `oracle.fresh()==false` → `postBid` reverts
    `StaleNav`; also the never-pushed case.
  - **authority / shape:** non-operator `postBid`/`cancelBid` revert `NotOperator`; non-owner `setDiscountBps`/
    `setBuybackCap` revert; `setDiscountBps(0)`/`setDiscountBps(10_000)` revert `BadDiscount`; the **operator (and any
    non-owner) cannot redirect the Safe** — `setAvatar`/`setTarget` revert `OwnableUnauthorizedAccount` (inherited
    `onlyOwner`); `setUp` callable once (`initializer`), `owner == operator` in `setUp` reverts; the mastercopy is
    inert.
  - **exec discipline (recording mock):** every `exec` the module issues is `Operation.Call` with `value == 0` and
    targets only `usdc`/`settlement` with the expected calldata (`approve(vaultRelayer, sellAmount)` /
    `setPreSignature(uid, true|false)`) — proves no delegatecall / no arbitrary call slipped in.
  - **zero-amount / validTo:** `sellAmount==0` or `buyAmount==0` reverts `ZeroAmount`; `validTo<=now` or `>now+
    MAX_BID_TTL` reverts `BadValidTo`.
  - **quoteMaxPrice round-trip:** the 6-dp ceiling, used as `sellAmount` per 1e18 `buyAmount`, exactly passes
    `postBid` (catches a view/gate scale mismatch).
  - **identity:** assert `module.engineSafe() == ExitGate.engineSafe()` (and the deploy wires the oracle's
    `setEngineSafe` to the same — note for item-10).
  - **no regression:** full suite green (prior count + these).
- Code committed under `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` +
  `contracts/src/interfaces/cow/IGPv2Settlement.sol` + `contracts/test/SzipBuyBurnModule.t.sol`, kept. Mapped to
  `audit/2.md` (an L-step posting a below-NAV buy-bid + fill + windowController `burnFor`; an N-step: over-NAV /
  over-cap / stale-nav bid reverts) and an `audit/3-results.md` authority row — **audit-sweep obligation, below.**

**Depends on**
- 8-B1 substrate (engine Safe summoned/wired at deploy; unit-tested against a recording mock Safe). · `SzipNavOracle`
  (built, the pricing primitive). · Exit Gate + szipUSD (built, the buyToken + the `burnFor` burn seam). · zodiac-core
  `Module` (interface-available; first inheritance here).
- **Downstream:** 8-B11 (CRE op surface drives `postBid`/`cancelBid` + the windowController `burnFor`), 8-B12
  (monitoring reads the events + alarms on non-zero engine-Safe szipUSD residual), item-10 deploy (CREATE2-clone via
  `ModuleProxyFactory`, `enableModule` on the engine Safe, `setUp` with governed `d`/`cap`, wire the same `engineSafe`
  the Gate's + the oracle's `setEngineSafe` pin; init-lock the mastercopy; `owner = TimelockController != operator`).

**Inbound cross-ticket obligations discharged by this ticket** (mark `DISCHARGED (by 8-B14)` at Conclude)
- **(from `SzipNavOracle`)** "8-B14 wired via `setEngineSafe`" → the module's `engineSafe` == the Safe the oracle's
  and the Gate's `setEngineSafe` pin == the order `receiver`/owner; the report + a test assert the identity.
- **(from Exit Gate)** "8-B14 calls `burnFor`" → **reframed (spec-clarified this window, baal-spec §7.2)**: the burn
  is the CRE **windowController** via the existing `burnFor` seam; the module is the bid side. The cycle `{postBid →
  fill → burnFor}` is documented and the `engineSafe` burn-source identity asserted. No ExitGate edit.

**Audit-sweep obligation (this item creates it)**
Author the buy-bid into `audit/2.md` Phase L (an L-step: operator posts a below-NAV `BUY szipUSD` bid → fill →
windowController `burnFor` → NAV-per-share ticks up; an N-step: over-NAV / over-cap / stale-nav / second-live bid
reverts) + the matching `audit/3-results.md` authority rows (operator-only `postBid`/`cancelBid`; owner-only
`d`/`cap`; `setAvatar`/`setTarget` locked). Touch `audit/*` only as a consequence of this build landing.
