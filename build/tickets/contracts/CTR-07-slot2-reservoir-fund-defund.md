# CTR-07 — Slot-2 reallocate fund/defund: make the junior yield facility revolving

> Contract-track change (EXPANSION). Wires the missing half of the reservoir's revolving cycle: an allocator path
> that moves idle USDC resting→reservoir on demand and re-absorbs it reservoir→resting after repay. Implements the
> session's locked "split slot 2" decision — the reservoir holds ~0 at rest (minimal standing borrowable surface;
> isolated senior-redemption liquidity), funded just-in-time for a harvest.
> Spec: `claude-zipcode.md` §4.5.1 (reservoir loop) / §4.7 / §17.

## Why (the verified gap)
`ReservoirLoopModule` cycles borrow/repay (`contracts/src/supply/szipUSD/ReservoirLoopModule.sol:216-273`), but
NOTHING funds the reservoir borrow vault from EE's resting cash or re-absorbs it after repay — `reallocate` is
called only for credit lines (`contracts/src/venue/EulerVenueAdapter.sol:316,404`). So the reservoir's lending
liquidity has no wired source. Decision (session): keep a no-borrow resting market + a separate reservoir vault, and add an allocator
fund/defund path (the per-line `fund`/`closeLine` pattern, generalized to the reservoir) — NOT a combined
resting=reservoir vault.

## Deliverable
Add to `EulerVenueAdapter` two NEW `onlyReservoirAllocator`-gated methods (adapter-LOCAL — NOT on the venue-agnostic
`IZipcodeVenue` interface, so no `@inheritdoc`; the venue interface stays line-only). Plus two Timelock-settable
wiring slots (`reservoirVault`, `reservoirAllocator`) + their `setX`/`WiringSet` setters + a `NotReservoirAllocator`
error + an `onlyReservoirAllocator` modifier:
1. `fundReservoir(uint256 amount)` — an absolute-target `reallocate` moving `amount` resting→reservoir vault
   (mirror `fund`'s two-item allocation, `EulerVenueAdapter.sol:300-316`), sized donation-immune via
   `_eeSupplyAssets` (`:287-297`). Pre-borrow, the CRE calls this so the reservoir has lendable USDC.
2. `defundReservoir(uint256 amount)` / re-absorb — the inverse `reallocate` moving reservoir→resting after the
   junior repays (mirror `closeLine`'s defund, `:399-405`). Restores resting liquidity.
3. The reservoir vault must be an enabled EE market with non-zero cap (it is — `acceptCap`'d at deploy,
   `DeployLocal.s.sol:140-141`), so it is reallocate-eligible without touching the supply queue.

## Spec §
`claude-zipcode.md` §4.5.1 (the strike-financing reservoir loop), §4.7, §17.

## Binds to (verified)
- `eulerEarn.reallocate(MarketAllocation[])` + `_eeSupplyAssets` donation-immune sizing
  (`EulerVenueAdapter.sol:287-316,399-405`).
- The reservoir vault address (`d.borrowVault`) + the borrow loop it serves: `ReservoirLoopModule.borrow`/`repay`
  (`contracts/src/supply/szipUSD/ReservoirLoopModule.sol:228-264`), pinned to `engineSafe` by
  `ReservoirBorrowGuard` (`contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol:91-92`).

## Starting state
- Reservoir vault `acceptCap`'d but unfunded by any wired path; `ReservoirLoopModule` borrows/repays assuming
  liquidity exists. Resting USDC sits in the separate no-borrow `baseUsdcMarket`.

## Do NOT
- Do NOT make idle USDC standing-borrowable (that's the rejected "combined" option) — fund JIT, defund on repay,
  reservoir ≈ 0 at rest.
- Do NOT collapse the allocator authority into the `ReservoirLoopModule` operator key — keep them DISTINCT
  (two-key: funding the reservoir and borrowing from it require different identities; draining idle USDC needs
  both). Document the two-key separation.
- Do NOT size the reallocate off `convertToAssets(balanceOf(EE))` (donation-skewable → `InconsistentReallocation`);
  use `_eeSupplyAssets` like `fund`/`closeLine`.
- Do NOT touch the line fund/close paths.
- **LOAD-BEARING DEPLOY INVARIANT (record, do not change):** the reservoir vault's hook config must stay
  **OP_BORROW-only** (`ReservoirMarketDeployer` installs `setHookConfig(guard, OP_BORROW)`). `fundReservoir`/
  `defundReservoir` work *because* the EE's `reallocate` deposit/withdraw legs into `bv` are un-hooked. If a future
  governor (the Timelock retains the borrow-vault governor, CTR-06a) ever widens the hooked-op mask to include
  `OP_DEPOSIT`/`OP_WITHDRAW`, `fundReservoir` silently bricks with `NotEngineSafe` — note this in the wire, do not
  defend against it in code (it is a governed footgun, like the other §17 Timelock-trusted invariants).

## Key requirements
1. **Round-trips to resting.** A fund→borrow→repay→defund cycle leaves the resting market's balance restored (a
   test asserts resting USDC before == after a full cycle).
2. **Donation-immune sizing** matches `fund`/`closeLine` (`_eeSupplyAssets`).
3. **Two-key separation** — the allocator that calls `fundReservoir`/`defundReservoir` is NOT the
   `ReservoirLoopModule` operator; a test asserts the operator alone cannot move resting→reservoir.
4. **Redemption isolation** — at rest the reservoir holds ≈0, so senior redemption liquidity stays in the
   no-borrow resting market untouched by the junior. A `defundReservoir` issued while the reservoir's cash is
   borrowed-out (no repay yet) MUST revert (the EVK withdraw has no cash) — proving JIT discipline, not a silent
   under-defund.

## Test plan (pinned — the cold-builder follows this, guesses no fixture)
The EE side does NOT exist in the reservoir suite today — it must be **ported + merged** (not "found"). Every step is
pinned below so the merge is mechanical.

- **Test home = `contracts/test/ReservoirLoopModule.t.sol`** (NOT the adapter test). That suite already stands up the
  full reservoir borrow leg on a live Base fork: a summoned engine Safe (`_summonAndEnable`), the reservoir USDC
  borrow vault + escrow via `_deployMarket` (real `ReservoirMarketDeployer`, returns `(escrowVault, bv, router)`,
  guard pinned to `engineSafe`, asset == USDC), a seeded LP mark (`_pushMark`), and a working
  `postCollateral`→`borrow`→`repay` cycle (`test_full_loop_revolves_twice`, `:693-735`). Reuse that fixture; the only
  NEW machinery is the EE side. `bv`'s asset is USDC and its hook is **OP_BORROW-only** (`ReservoirMarketDeployer`
  installs `setHookConfig(guard, OP_BORROW)`), so the EE's `reallocate` deposit/withdraw legs into `bv` are UN-hooked
  and succeed — this is the load-bearing invariant the fund path depends on (see Do-NOT below).
- **Imports to ADD** to the reservoir test (the mock + adapter need them — the file lacks them today): the OZ
  `IERC4626 as IOZERC4626` alias, `{IEulerEarn, MarketAllocation} from "euler-earn/interfaces/IEulerEarn.sol"`, and
  `{EulerVenueAdapter} from "../src/venue/EulerVenueAdapter.sol"` (note the path: `src/venue/`, NOT
  `src/supply/szipUSD/`). `forge-std`/`IEVault`/`IERC20`/`GenericFactory` are already imported via `ForkConfig`.
- **EE side = the faithful `MockEulerEarn`** copied verbatim from `test/EulerVenueAdapter.t.sol:36-315` into the
  reservoir test file (EulerEarn pins solc 0.8.26 and cannot be `new`-ed under 0.8.24 — both test files are
  `pragma 0.8.24`, no version conflict; this mock is the established substitute and is FAITHFUL: its `reallocate`
  physically `deposit`/`withdraw`/`redeem`s **real USDC against the real EVK vaults**, `:260-306`, single in-order
  pass — withdraw-leg-first matches the alloc order in pins #2/#3 — sizing off the tracked `config.balance`, with the
  `InconsistentReallocation` zero-sum invariant `:304`).
- **Base resting market** — port the adapter test's pattern verbatim: build a bare no-borrow EVK proxy
  (`factory.createProxy(address(0), false, abi.encodePacked(usdc, address(0), address(0)))` +
  `setHookConfig(address(0),0)` + `setGovernorAdmin(address(0))`, à la `EulerVenueAdapter.t.sol:413-416`) and a
  `_fundBaseMarket(uint256 usdcAmount)` helper (`deal(usdc, addr, amt)` → `deposit(amt, address(ee))` →
  `ee.seedConfig(baseUsdcMarket, mintedShares)`, à la `:469-474`). This seeds the EE-tracked base position so
  `fundReservoir`'s `base − amount` has cash to withdraw.
- **Enable the reservoir market on the mock at ZERO balance:** `ee.submitCap(IOZERC4626(bv), type(uint136).max)` then
  `ee.acceptCap(IOZERC4626(bv))` (the mock's `acceptCap` calls `_enableMarket` → `cfgEnabled[bv]=true`, balance stays
  0; mirrors `DeployLocal.s.sol:140-141`). Do NOT seed the reservoir vault with shares (replaces the old
  `_seedBorrowVault` step) — it gets its cash ONLY via `fundReservoir`, so it holds ≈0 at rest.
- **Wire a real `EulerVenueAdapter`** (10-arg ctor, order per `EulerVenueAdapter.sol:91-102` / instantiation example
  `EulerVenueAdapter.t.sol:426-437`): `eulerEarn_` = the mock, `baseUsdcMarket_` = the base resting vault. The
  line-side args (`controller`/`evc`/`eVaultFactory`/`oracleRegistry`/`gatingHook`/`irm`/`usdc`/`erebor`) are
  real-but-unused placeholders — the new methods touch only `eulerEarn`/`baseUsdcMarket`/`reservoirVault`; do NOT
  replicate the adapter test's CREATE-address/hook dance (CTR-07 opens no lines). The test contract is the adapter
  `owner` (`Ownable(msg.sender)`), so after construction call `adapter.setReservoirVault(bv)` and
  `adapter.setReservoirAllocator(allocatorKey)` (allocatorKey = a fresh `makeAddr`, ≠ the `operator` key).
- **Reading tracked balances** (`_eeSupplyAssets` is `internal` — not test-callable): use the mock's public
  `ee.expectedSupplyAssets(IOZERC4626(market))` (== `previewRedeem(config.balance)`, identical to `_eeSupplyAssets`)
  or `ee.config(IOZERC4626(market)).balance`.
- **Tests to add (5):**
  1. `test_ctr07_roundtrip_restores_resting`: record `ee.expectedSupplyAssets(base)`; `vm.prank(allocatorKey)`
     `fundReservoir(X)` → base −X, reservoir == X; run `postCollateral`→`borrow(< X)`→`repay` via the operator (push
     a fresh LP mark first, like `test_full_loop_revolves_twice`); `vm.prank(allocatorKey)` `defundReservoir(X)` →
     base restored to the recorded value, reservoir == 0.
  2. `test_ctr07_defund_reverts_when_lent_out`: `fundReservoir(X)`; `postCollateral`→`borrow(Y)` (NO repay);
     `defundReservoir(X)` → `vm.expectRevert(EvkErrors.E_InsufficientCash.selector)` (the reservoir EVK vault lacks
     cash to honor the withdraw leg — `Vault.sol` reverts `E_InsufficientCash` when `cash < assets`).
     Redemption-isolation / JIT proof. (`Errors as EvkErrors` is already imported by the suite.)
  3. `test_ctr07_operator_cannot_fund`: `vm.prank(operator)` (the loop hot key, NOT the allocator) → `fundReservoir`
     reverts `EulerVenueAdapter.NotReservoirAllocator`; same for `defundReservoir`.
  4. `test_ctr07_donation_noop_on_sizing`: a donor `deal`s USDC, `deposit`s into `bv` to MINT shares, then
     `IEVault(bv).transfer(address(ee), shares)` (a raw share transfer — inflates `balanceOf(ee)` but NOT the tracked
     `cfgBalance`); `fundReservoir`/`defundReservoir` still net (sized off the tracked balance, not `balanceOf`) — no
     `InconsistentReallocation`.
  5. `test_ctr07_reservoir_zero_at_rest`: after a full fund→borrow→repay→defund cycle,
     `ee.expectedSupplyAssets(IOZERC4626(bv)) == 0`.

## Done when (gate — `forge test`, fork)
- `forge build` green; `forge test --match-path test/ReservoirLoopModule.t.sol` green — all pre-existing tests still
  pass PLUS the 5 CTR-07 tests above (round-trip restores resting; defund-while-lent-out reverts; operator key cannot
  `fundReservoir`/`defundReservoir`; donation no-op on sizing; reservoir == 0 at rest).
- Cold-build with ZERO load-bearing guesses.

## Implementation pins (resolved from code — the cold-builder guesses NONE of these)
1. **New wiring slots.** `address public reservoirVault;` + `address public reservoirAllocator;` — both
   Timelock-settable (`onlyOwner` + `WiringSet`), mirroring `EulerVenueAdapter.sol:118-185`. `reservoirVault` =
   the `d.borrowVault` from `ReservoirMarketDeployer` (acceptCap'd at deploy, `DeployLocal.s.sol:140-141`).
2. **`fundReservoir(uint256 amount) external onlyReservoirAllocator`** — mirror `fund` (`:300-319`) exactly:
   `uint256 base = _eeSupplyAssets(baseUsdcMarket); uint256 res = _eeSupplyAssets(reservoirVault);` then
   `reallocate([{baseUsdcMarket, base - amount}, {reservoirVault, res + amount}])` (absolute targets, zero-sum).
3. **`defundReservoir(uint256 amount) external onlyReservoirAllocator`** — the inverse:
   `reallocate([{reservoirVault, res - amount}, {baseUsdcMarket, base + amount}])`. Re-absorbs to resting after
   the junior repays.
4. **Donation-immune sizing.** Both use `_eeSupplyAssets` (`:295-297`) — `previewRedeem(config[id].balance)`, the
   EE's tracked balance — NOT `convertToAssets(balanceOf(EE))` (donation-skewable → `InconsistentReallocation`).
5. **Two-key separation (load-bearing).** `onlyReservoirAllocator` is a DISTINCT key from the
   `ReservoirLoopModule.operator` that calls `borrow`/`repay` (`contracts/src/supply/szipUSD/ReservoirLoopModule.sol:156,228`).
   Funding the reservoir (allocator) and borrowing from it (operator) require different identities, so draining
   idle USDC needs both. **Enforcement: a `modifier onlyReservoirAllocator` on both methods.** The adapter holds no
   handle on the loop module's `operator`, so the distinctness is a DOCUMENTED deploy invariant (NatSpec: "set
   `reservoirAllocator` ≠ the `ReservoirLoopModule.operator`"), NOT an on-chain cross-contract assert — do NOT invent
   a loop-module reference just to compare them (that would be a fabricated coupling). The on-chain proof is the gate
   itself: the loop `operator` key, lacking the allocator role, reverts `NotReservoirAllocator` (test #3).
6. **No supply-queue touch.** The reservoir vault is `config[].enabled` with a non-zero cap, so it is
   reallocate-eligible without supply-queue membership (`EulerEarn` gates reallocate on cap/enabled, not queue
   position — same basis as the line markets, `EulerEarn.sol:392-393`). Do NOT add it to the supply queue (that
   would route fresh DEPOSITS into it — the opposite of JIT funding). **VERIFIED against the live deploy:**
   `DeployLocal.s.sol:140-141` `submitCap(d.borrowVault, max)`+`acceptCap(d.borrowVault)` enables the reservoir
   vault as an EE market, while `setSupplyQueue` is set to `[baseUsdcMarket]` ONLY (the line right above, `q[0]`) —
   so the reservoir vault is already an enabled, NON-supply-queue market exactly as pins #3/#6 require. Zero
   back-pressure: the contract surface (`reallocate` + the enabled reservoir market) all exists today.

## Depends on / unblocks
- **Depends on:** nothing hard (operates on the existing reservoir market); composes with CTR-06 (every silo wires
  this path).
- **Unblocks:** a truly revolving slot-2 facility in every silo; the same reallocate-funded-revolving pattern that
  CTR-08's structure-2 credit lines reuse.
