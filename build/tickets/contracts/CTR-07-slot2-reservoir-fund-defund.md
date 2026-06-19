# CTR-07 — Slot-2 reallocate fund/defund: make the junior yield facility revolving

> Contract-track change (EXPANSION). Wires the missing half of the reservoir's revolving cycle: an allocator path
> that moves idle USDC resting→reservoir on demand and re-absorbs it reservoir→resting after repay. Implements the
> session's locked "split slot 2" decision — the reservoir holds ~0 at rest (minimal standing borrowable surface;
> isolated senior-redemption liquidity), funded just-in-time for a harvest.
> Spec: `claude-zipcode.md` §4.5.1 (reservoir loop) / §4.7 / §17.

## Why (the verified gap)
`ReservoirLoopModule` cycles borrow/repay (`contracts/src/supply/szipUSD/ReservoirLoopModule.sol:216-273`), but
NOTHING funds the reservoir borrow vault from EE's resting cash or re-absorbs it after repay — `reallocate` is
called only for credit lines (`EulerVenueAdapter.sol:316,404`). So the reservoir's lending liquidity has no wired
source. Decision (session): keep a no-borrow resting market + a separate reservoir vault, and add an allocator
fund/defund path (the per-line `fund`/`closeLine` pattern, generalized to the reservoir) — NOT a combined
resting=reservoir vault.

## Deliverable
Add to `EulerVenueAdapter` (or a small sibling allocator module) two `onlyController`/Timelock-gated methods:
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

## Key requirements
1. **Round-trips to resting.** A fund→borrow→repay→defund cycle leaves the resting market's balance restored (a
   test asserts resting USDC before == after a full cycle).
2. **Donation-immune sizing** matches `fund`/`closeLine` (`_eeSupplyAssets`).
3. **Two-key separation** — the allocator that calls `fundReservoir`/`defundReservoir` is NOT the
   `ReservoirLoopModule` operator; a test asserts the operator alone cannot move resting→reservoir.
4. **Redemption isolation** — at rest the reservoir holds ≈0, so senior redemption liquidity stays in the
   no-borrow resting market untouched by the junior.

## Done when (gate — `forge test`, fork)
- `forge build` green; `contracts/test/ReservoirLoopModule.t.sol` (or a new adapter test) green: fund→borrow→
  repay→defund restores resting; donation no-op on sizing; the operator key cannot `fundReservoir`; reservoir ≈ 0
  at rest.
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
   idle USDC needs both. Assert/ document the distinctness (e.g. revert if `reservoirAllocator == loop operator` is
   detectable, else document the deploy invariant).
6. **No supply-queue touch.** The reservoir vault is `config[].enabled` with a non-zero cap, so it is
   reallocate-eligible without supply-queue membership (`EulerEarn` gates reallocate on cap/enabled, not queue
   position — same basis as the line markets, `EulerEarn.sol:392-393`). Do NOT add it to the supply queue (that
   would route fresh DEPOSITS into it — the opposite of JIT funding).

## Depends on / unblocks
- **Depends on:** nothing hard (operates on the existing reservoir market); composes with CTR-06 (every silo wires
  this path).
- **Unblocks:** a truly revolving slot-2 facility in every silo; the same reallocate-funded-revolving pattern that
  CTR-08's structure-2 credit lines reuse.
