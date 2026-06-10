# S1 — Stream 2 (`RecycleModule.divert`) — divert engine yield into the bank (the warehouse)

> **Build-only. An EXTENSION of the BUILT `RecycleModule` (8-B10), not a new contract.** The loss-side waterfall
> (`solvency.md`) has five streams; four are built (markdown ledger, xALPHA slash, buy-at-discount-burn, lien
> workout). **Stream 2 is the one genuine build gap:** a continuous yield diversion that **supplies engine
> free-value USDC straight into the credit warehouse** (`eePool.deposit(amount, warehouse)`, **no zipUSD minted**) so
> the warehouse's USDC backing rises toward ≥ zipUSD owed — filling the capital hole a default left behind. It is a
> SECOND spend of the same `freeValueAccrued` ledger `recycle` already governs; the two diverge only in the sink
> (recycle → backed-mint into the basket for NAV accretion; divert → raw USDC into the bank, bounded by the live
> hole). Internal engine plumbing driven by the CRE robot → build-only (no INFLOW ticket).

**Deliverable**
Extend the two existing files (KEEP everything they already do — `creditFreeValue` / `recycle` / the accumulator
gate / the exec dance are unchanged):

- `contracts/src/supply/szipUSD/RecycleModule.sol` — add the `divert` mode:
  - **Three new set-once wiring slots** (plain storage, **never `immutable`** — clone fact §18.6): `address public
    navOracle` (the `SzipNavOracle`; the `provision()` hole-size read), `address public eePool` (the `EulerEarn`
    senior pool the warehouse supplies), `address public warehouse` (the EE deposit **receiver** = the
    `CreditWarehouse` Safe). All three decoded + validated nonzero in `setUp` (the decode grows from **5 → 8
    addresses**), each with an `onlyOwner` (Timelock) re-point setter (`setNavOracle`/`setEePool`/`setWarehouse`)
    emitting `WiringSet` — matching the four existing build-phase setters (§17).
  - **`divert(uint256 usdcAmount) external onlyOperator returns (uint256 sent)`** — order is load-bearing
    (**bounds-before-spend, then CEI**): (a) `usdcAmount > 0` else `ZeroAmount`; (b) read `hole =
    navOracle.provision()`, `hole > 0` else `NoHole`; (c) **revert** `ExceedsHole` if `usdcAmount * 1e12 > hole`
    (the `1e12` scales USDC 6-dp → USD 18-dp; strict `>` so an EXACT fill is allowed but a divert can never
    over-fill the hole); (d) `_spendFreeValue(usdcAmount)` (the existing CEI debit — effects FIRST, reverts
    `InsufficientFreeValue` over-ledger); (e) drive the Safe via three `_exec`s — `usdc.approve(eePool, usdcAmount)`
    → `eePool.deposit(usdcAmount, warehouse)` → `usdc.approve(eePool, 0)` (reset); (f) **two value guards** — capture
    `beforeUsdc = IERC20(usdc).balanceOf(safe)` and `beforeShares = IERC20(eePool).balanceOf(warehouse)` before the
    deposit, then assert: (i) **hard backing** — the Safe's USDC fell by **exactly** `usdcAmount`
    (`beforeUsdc - balanceOf(safe) == usdcAmount`), else `BackingShortfall` (proves real value moved, not a trusted-pool
    no-op that mints shares without pulling USDC — security MED F5); and (ii) **liveness** — the warehouse EE-share
    balance **rose** (`> beforeShares`), else `NoSharesMinted`; (g) `sent = usdcAmount`; `emit Filled(usdcAmount,
    warehouse, hole)`.
  - **New errors:** `NoHole`, `ExceedsHole`, `NoSharesMinted`, `BackingShortfall` (reuse the existing `ZeroAmount` /
    `ZeroAddress` / `InsufficientFreeValue` / `NotOperator` / `ExecFailed`).
  - **New event:** `event Filled(uint256 usdcAmount, address indexed warehouse, uint256 provisionAfter)`. Because
    `divert` does NOT itself write provision (the CRE reduces it later via `DefaultCoordinator.Recovery`),
    `provisionAfter == hole` (the live hole at divert time, unchanged within the tx) — documented in NatSpec.
  - **Two new local interfaces** (house posture — do NOT import the GPL oracle/earn): `interface ISzipNavProvision
    { function provision() external view returns (uint256); }` and `interface IEulerEarn { function deposit(uint256
    assets, address receiver) external returns (uint256 shares); }`. The EE-share read uses the already-imported
    `IERC20(eePool).balanceOf(warehouse)` (the EE pool share token is itself an ERC20).

- `contracts/test/RecycleModule.t.sol` — extend the existing suite: (i) update every `setUp` encoding 5 → 8
  addresses (a small `_params` change + the integrated/fork rigs); (ii) add a `RecycleModuleDivertTest` contract
  with the divert unit + integrated + fork coverage (below). **All prior recycle tests stay green unchanged.**

**No new `BaseAddresses` constant / no new shared-interface file.** `eePool`/`warehouse`/`navOracle` are runtime
addresses wired at deploy (mocked in tests); the two interfaces are local to `RecycleModule.sol` (parity with the
local `IZipDepositModule`).

**Spec §**
- `solvency.md` **§C.S1** — the canonical build-spec for this item (Stream 2: `divert` on `RecycleModule`; supply
  USDC into EE crediting the warehouse, no zipUSD mint; bounded by `provision()`; the `1e12` boundary; the
  false-return guard; the Do-NOTs). `solvency.md` **§B** (the waterfall — Stream 2 row) + **§D** (RESOLVED: the
  hole = the warehouse's USDC backing; Stream-2 home = a `divert` mode on `RecycleModule`; provision source =
  `SzipNavOracle.provision()`).
- `claude-zipcode.md` **§2** (USDC over-collateralizes zipUSD in the warehouse), **§5** (yield routing — diverted
  yield goes to the bank instead of compounding the basket; depositor return is the xALPHA subsidy), **§11** (loss
  side / fill the hole), **§4.5.1** (engine modules — `RecycleModule`'s free-value ledger).
- `claude-zipcode.md` **§17** locked: venue-agnostic; CRE-permissioned single operator; no on-chain economic
  liquidation; build-phase wiring is Timelock-settable. (S1 reopens nothing.)

**Model from (VERIFIED against the repo + `reference/`)**
- **The attach point — `RecycleModule` (`contracts/src/supply/szipUSD/RecycleModule.sol`, BUILT, in-repo).** `divert`
  is a sibling of `recycle`: same `onlyOperator` gate, same `_spendFreeValue(amount)` CEI debit (effects first),
  same `_exec(to, data)` that bubbles inner revert data via `assembly { revert(add(ret,0x20),mload(ret)) }` /
  `ExecFailed` when empty, same approve-selector dance `abi.encodeWithSelector(IERC20.approve.selector, spender,
  amount)` then `..., 0`. **The whole difference vs `recycle`:** (a) the middle `_exec` targets `eePool` with
  `abi.encodeCall(IEulerEarn.deposit, (usdcAmount, warehouse))` — NOT `ZipDepositModule.deposit`, so **NO zipUSD is
  minted** (raw USDC supplied as senior backing → shares to the warehouse, no new senior claim); (b) a `provision()`
  bound is read BEFORE the spend; (c) a warehouse-EE-share-balance-rose guard replaces the deposit-return decode.
- **The EE-supply path — copy `ZipDepositModule.deposit` (`contracts/src/supply/ZipDepositModule.sol:120-121`),
  OMITTING the zipUSD mint at `:119`.** That contract does `usdc.forceApprove(eePool, usdcIn)` then
  `IEulerEarn(eePool).deposit(usdcIn, warehouse)` (shares → warehouse). `divert` reproduces exactly that supply leg
  (via the Safe's `_exec` approve/deposit/reset), minus the `IESynth(zipUSD).mint(...)` at `:119` — that omission IS
  Stream 2. `IEulerEarn.deposit(uint256 assets, address receiver) returns (uint256 shares)` is ERC-4626
  (`reference/euler-earn/src/EulerEarn.sol:560`; "pulls assets from caller, mints shares to receiver") — already
  fork-proven by WOOF-06. (Builder note: EE is ERC-4626 — its `maxDeposit` cap, if any, would revert the deposit
  `_exec` and bubble; no extra handling needed.)
- **The provision read — `SzipNavOracle.provision` (`contracts/src/supply/SzipNavOracle.sol:102`, BUILT).**
  `uint256 public provision` (18-dp USD), so the getter is `provision()`. The local `ISzipNavProvision` interface
  needs that one view. It is the hole size; `divert` reads it (the bound), never writes it (the
  `DefaultCoordinator` is the sole writer; the CRE reduces it later via a `Recovery`).
- **The false-return/FoT guard — model `DurationFreezeModule.commit`/`release`
  (`contracts/src/supply/szipUSD/DurationFreezeModule.sol:282-287`,`304-309`).** They capture `beforeBal =
  IERC20(asset).balanceOf(dest)`, exec the transfer, and revert `TransferShortfall` unless the delta matches. For an
  EE **deposit** the share amount is share-price-dependent (not == `usdcAmount`), so assert the warehouse share
  balance **strictly rose** (`> beforeShares`), not an exact delta → `NoSharesMinted`.
- **CRITICAL clone fact (§18.6, proven on 8-B5..B10/B14).** A `ModuleProxyFactory` clone shares the mastercopy's
  runtime bytecode → `immutable` cannot carry per-clone `setUp` config. `navOracle`/`eePool`/`warehouse` MUST be
  plain set-once storage written in `setUp` under `initializer`, NOT `immutable` (exactly like the existing four
  slots).

**Starting state**
`forge build` green on `snapshot/recycle-rework` (kept tree incl. WOOF-00…06, `SzipNavOracle`, `ExitGate`+`SzipUSD`,
`ZipDepositModule`, 8-B1 substrate, 8-B5..B10/B14 engine modules, 8-Bw warehouse, `DurationFreezeModule`,
`DefaultCoordinator`, `LienXAlphaEscrow`). `RecycleModule.sol` present + 19/19 green. The test harness already has
a `RecordingSafe` (records `(to,value,data,operation)`, `setLive`/`getCall`/`callCount`/`setFailOnCallIndex`/
`setReturnData`), a configurable-decimals `MockERC20`, a par `EEMock` (itself the share token: `deposit` pulls the
full assets, par-mints shares to the receiver), and the `ReadbackZipDepositModule` ordering probe — REUSE them.

**Do NOT**
- **Do NOT mint zipUSD.** `divert` supplies **raw USDC** into EE crediting the warehouse (more backing, NOT a new
  senior claim). The `eePool.deposit` middle leg replaces `ZipDepositModule.deposit`; there is NO `ESynth.mint`, no
  `ZipDepositModule` call, no `gate.depositFor`, no share issuance.
- **Do NOT route to `capitalSink`** (that is Stream 1's xALPHA→USDC conversion venue — a different stream). Stream 2's
  USDC is already USDC, so it goes straight to the bank (the warehouse).
- **Do NOT route to an operator-chosen receiver.** The **warehouse** is the wired set-once `receiver` of
  `eePool.deposit` (destination integrity); the operator supplies only the `usdcAmount` scalar.
- **Do NOT divert more than the live hole** (`usdcAmount * 1e12 <= provision()`, strict `>` reverts `ExceedsHole`);
  **do NOT** write `provision` (the module never touches the oracle's writer; the CRE reduces the hole later via
  `DefaultCoordinator.Recovery`).
- **Do NOT touch `recycle`'s path** — `divert` is a SECOND spend of `freeValueAccrued`, CEI-first; both debit the
  same accumulator and leave the other working on the remainder.
- **Do NOT sell xALPHA or pull basket assets** (only engine USDC); **Do NOT** add `nonReentrant` (the module avoids
  OZ `ReentrancyGuard` per the clone fact — safety is effects-before-interaction, matching `recycle`); **Do NOT**
  use `immutable` for the three new slots; **Do NOT** add a generic exec/arbitrary-target/delegatecall/non-zero
  `value`.

**Key requirements**
1. **setUp grows 5 → 8, order-guard preserved.** `setUp(bytes)` decodes `(owner, engineSafe, operator,
   zipDepositModule, usdc, navOracle, eePool, warehouse)`. Validate **ALL 8 nonzero FIRST** + `owner != operator`
   (a zero in ANY position reverts `ZeroAddress` deterministically before any use), set `avatar = target =
   engineSafe`, store all wiring, THEN `_transferOwnership(owner)`. No live-read in `setUp`. All set-once storage,
   never `immutable`; mastercopy init-locked (a second `setUp` reverts). The three new slots each get an `onlyOwner`
   nonzero-guarded `WiringSet`-emitting setter.
2. **`divert` order is load-bearing — bounds-before-spend, then CEI.** Exactly: ZeroAmount → NoHole → ExceedsHole →
   `_spendFreeValue` → three `_exec`s (approve / deposit(amount, warehouse) / approve-0) → share-rose guard → emit.
   The `provision()` read AND the `ExceedsHole` revert happen **before** `_spendFreeValue` (so an over-hole or
   no-hole divert never debits the ledger and records `callCount == 0`). The `_spendFreeValue` debit lands **before**
   any value-moving `_exec` (CEI / decrement-before-exec).
3. **The `1e12` boundary — pinned with ±1 vectors (qa, HIGH).** `usdcAmount * 1e12 > provision()` reverts
   `ExceedsHole`. Test at `provision = usdcAmount·1e12` (exact fill — ALLOWED), `usdcAmount·1e12 − 1` (reverts
   `ExceedsHole`), `usdcAmount·1e12 + 1` (ALLOWED). Document that a pathologically huge `usdcAmount` overflows the
   multiplication (Solidity 0.8 Panic-revert) before `_spendFreeValue` — acceptable (operator-only; still reverts).
4. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** `divert` does exactly three `_exec`s in
   order: `(usdc, approve(eePool, usdcAmount))`, `(eePool, deposit(usdcAmount, warehouse))`, `(usdc, approve(eePool,
   0))`. **Use typed `abi.encodeCall(IEulerEarn.deposit, (usdcAmount, warehouse))`** (a sig regression fails to
   compile). For EVERY recorded call assert `value == 0` AND `operation == uint8(Operation.Call)`. A `live` Safe whose
   deposit target returns `(false, customErrorBytes)` makes `divert` revert bubbling that data; `(false, "")` reverts
   `ExecFailed`; after a reverted `divert`, `freeValueAccrued` is unchanged (atomic rollback of the decrement).
5. **The two value guards (hard-backing + liveness).** `divert` captures `beforeUsdc = IERC20(usdc).balanceOf(safe)`
   and `beforeShares = IERC20(eePool).balanceOf(warehouse)` before the deposit `_exec`, then reverts: `BackingShortfall`
   unless the Safe's USDC fell by **exactly** `usdcAmount` (hard backing — proves real value moved, defends a pool that
   mints shares without pulling USDC; security MED F5), AND `NoSharesMinted` unless the warehouse share balance strictly
   rose after (liveness — defends a no-op / share-mint-skipping / FoT pool that the Safe's swallow-inner-reverts would
   otherwise hide). Tests: a free-mint EE mock that mints shares without pulling USDC → `BackingShortfall`; a stingy EE
   mock that pulls the USDC but mints no shares → `NoSharesMinted`.
6. **`divert` leaves `recycle` working on the remainder.** A test that credits the ledger, runs a `divert` (debits
   part), then runs a `recycle` (debits more) — both succeed, `freeValueAccrued` ends at `seed − diverted −
   recycled`, the divert's USDC landed in EE/warehouse and the recycle's zipUSD landed in the basket.
7. **Authority + CEI.** `divert` reverts `NotOperator` for any non-operator. A re-entrant `divert`/`recycle`
   mid-`_exec` fails `InsufficientFreeValue` (the decrement already landed) — proven by a readback EE mock that reads
   `module.freeValueAccrued()` inside `deposit()` and asserts it equals `seed − usdcAmount` mid-call (the
   decrement-before-exec is observable, not just rollback-implied).

**Done when**
- `forge build` green; `forge test --match-path test/RecycleModule.t.sol` green (unit + integrated); `forge test
  --fork-url $BASE_RPC_URL --match-path test/RecycleModule.t.sol` green (adds the Base-fork pass); **no regression**
  on the full suite.
- **Divert unit/integrated (LIVE `RecordingSafe` + `MockERC20` USDC + `EEMock` eePool + a `MockNavProvision`):**
  - **value flow + exec-shape, fully pinned (live Safe):** seed the ledger, mint USDC to the Safe, set provision
    large; `divert(u)` records exactly three calls `(usdc, 0, approve(eePool, u), Call)`, `(eePool, 0,
    deposit(u, warehouse), Call)`, `(usdc, 0, approve(eePool, 0), Call)`; the warehouse EE-share balance rose, the
    Safe USDC fell by `u`, `freeValueAccrued` fell by `u`, `usdc.allowance(safe, eePool) == 0`, `Filled(u,
    warehouse, hole)` emitted, return `sent == u`.
  - **bounds:** `provision == 0` → `NoHole` (callCount 0, ledger unchanged); the ±1 `ExceedsHole` vectors (KR3);
    `usdcAmount > freeValueAccrued` within the hole → `InsufficientFreeValue` (callCount 0); `divert(0)` →
    `ZeroAmount`; non-operator → `NotOperator`.
  - **guards/atomicity:** stingy EE mock (no share mint) → `NoSharesMinted`; a `live` Safe failing the deposit exec
    bubbles the inner data / `ExecFailed` on empty, and leaves `freeValueAccrued` unchanged; the readback CEI test
    (KR7); divert-then-recycle co-existence (KR6).
  - **wiring:** `setNavOracle`/`setEePool`/`setWarehouse` re-point onlyOwner (non-owner reverts; zero reverts
    `ZeroAddress`; `WiringSet` emitted); the 3 new getters wired; the mastercopy's 3 new getters are `address(0)`; a
    zero in EACH of the 8 setUp positions reverts `ZeroAddress`.
- **Divert fork (real summoned Gnosis Safe as the engine Safe, mock EE + mock provision):** reuse the existing
  `_summonAndEnable` rig; one `divert` over the real Safe bytecode supplies USDC into the mock EE crediting the
  warehouse and debits the ledger (proves the Zodiac exec path for the new leg).
- **Mapped to the integration layer:** the loss-phase divert belongs in the deferred loss-side audit sweep
  (`solvency.md` §C.S1 maps it to a new `audit/2.md` loss-phase step + an invariant-fuzz `divert` never sends more
  than `min(freeValueAccrued, provision/1e12)`), authored with item-10 — logged as an obligation, NOT this window.

**Depends on**
- **8-B10** (`RecycleModule.sol` — the attach point: the `freeValueAccrued` ledger, the `_spendFreeValue` CEI debit,
  the `_exec` dance, the `onlyOperator` gate, the setUp order-guard, the four build-phase setters — all reused).
- **`SzipNavOracle.provision`** (BUILT — the hole-size read), **EulerEarn** (`eePool` — the warehouse's senior
  pool, ERC-4626 `deposit(assets, receiver)`), the **`CreditWarehouse` Safe** (8-Bw, BUILT — the EE-share
  receiver). The cold-builder MUST open `contracts/test/RecycleModule.t.sol` (the `RecordingSafe`/`EEMock`/
  `ReadbackZipDepositModule` + `_summonAndEnable` rig), `ZipDepositModule.sol:115-123` (the EE-supply leg to copy
  minus the mint), and `DurationFreezeModule.sol:282-309` (the balance-rose guard idiom).

---

**Inbound cross-ticket obligations DISCHARGED by this ticket:** none owed specifically by S1 (the loss-side
provision-bound + slash-driver obligations were discharged by `DefaultCoordinator`; the divert reads the same
`provision()` ledger they bound).

**New cross-ticket obligations this ticket CREATES** (record in `PROGRESS.md`):
- **Item 10 / S2 wiring — `RecycleModule` new slots:** wire `setNavOracle(SzipNavOracle)` / `setEePool(EE_POOL)` /
  `setWarehouse(CreditWarehouse Safe)`; **deploy-time assert `RecycleModule.warehouse == ZipDepositModule`'s /
  `WarehouseAdminModule`'s warehouse Safe** (one bank — else diverted USDC supplies the wrong pool and never fills
  the hole; revert the deploy if mismatched), and `RecycleModule.eePool == ZipDepositModule.eePool()`. Stream 1's
  `capitalSink` USDC output must also be supplied to THIS warehouse (a CRE/off-chain step).
- **Item 10 / loss-side audit sweep (S1):** author the divert into a new `audit/2.md` loss-phase step (post →
  default → provision → `divert` → warehouse backing up; N-steps: `NoHole` / `ExceedsHole` (±1) / over-ledger /
  non-operator / `NoSharesMinted` each revert) + an invariant-fuzz (`divert` never sends more than
  `min(freeValueAccrued, provision/1e12)`) + the `audit/3-results.md` authority rows (operator-only;
  warehouse-pinned receiver; no NAV/provision write). Author once the loss side is integration-testable with item-10.
- **8-B11 / CRE §8 — divert sizing + the Recovery follow-up:** the CRE sizes the per-call `usdcAmount` within
  `min(freeValueAccrued, provision()/1e12)`, sequences it against the recycle spend, and writes a
  `DefaultCoordinator.Recovery` to reduce `provision` by the realized fill after a divert (the divert does not write
  provision itself).
