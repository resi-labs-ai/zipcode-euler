# SUPPLY-ADV-10 — `removeLiquidity` must reject an all-zero slippage floor (`ZeroMinAmount`), matching `addLiquidity`'s `ZeroMinShares`

> **STATUS: BUILT (2026-06-23) — SHIPPED to `main`.** Added `error ZeroMinAmount()` (`LpStrategyModule.sol:67-70`)
> + the guard `if (minAmount0 == 0 && minAmount1 == 0) revert ZeroMinAmount()` in `removeLiquidity` (after the
> `ZeroAmount` check) + `test_removeLiquidity_zero_minAmount_reverts`; updated the 5 `(0,0)` happy/coverage-gate
> test sites to non-zero floors (the `NotOperator`/`ZeroAmount`-first sites needed none). `removeLiquidity` NatSpec
> updated. Scoped suite **38/38 green**, `forge build` clean. Doc-sync in the same commit (X-Ray I-3/§4/§5/counts +
> wire `8-B6`), folding ADV-09's overlapping doc corrections. No fix divergence (at-least-one-non-zero, as planned).
>
> Originally FILED. On-chain change (one guard + one error + regression test) to `LpStrategyModule.sol`. The
> belt to KEEPER-02's suspenders: the *durable* protection that holds even when the off-chain floor-sizing
> (SUPPLY-ADV-09 / KEEPER-02) is buggy, unbuilt, or bypassed by a manual operator tx.
>
> Source: adversarial-review on `contracts/src/supply/szipUSD/LpStrategyModule.sol`
> (`adversarial-review/reports/src/supply/lpstrategymodule/synthesis.md`, mission 3 — the `ZeroMinAmount`
> candidate). Promoted to a filed LOW after the verified-ICHI-source follow-up showed the **withdraw** is the
> vault-*unprotected* side (see SUPPLY-ADV-09), so the caller's floor is the sole guard — yet the contract lets
> it be all-zero.

> BUILD item (LOW / defense-in-depth). Solvency is NOT at risk (the coverage gate values LP at TWAP, so an empty
> floor cannot breach the senior floor — see SUPPLY-ADV-09 "Why it's LOW"). Worth doing because: (1) it is the
> ONLY protection on the dissolution hop that does not depend on the off-chain keeper being correct — and that
> keeper does not exist yet, so the first wind-downs may be manual operator txs where a `(0,0)` floor is most
> likely; (2) it conforms the remove leg to a decision the author already made on the add leg (`ZeroMinShares`,
> `:221`) — and the verified ICHI source shows that decision applies *more* strongly to the withdraw; (3) the fix
> is one `if` + one error, shipped once, protecting every future wind-down regardless of who writes the keeper.

## The gap (verified in code)

`addLiquidity` makes a non-zero floor MANDATORY (`LpStrategyModule.sol:221`):

```solidity
if (minShares == 0) revert ZeroMinShares();   // :221
```

`removeLiquidity` has the symmetric exposure — a direct, router-less `IICHIVault.withdraw` (`:270`) whose
returned legs are floored by `amount0 < minAmount0 || amount1 < minAmount1` (`:272`) — but imposes **no**
corresponding non-zero requirement:

```solidity
function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1)
    external onlyOperator returns (uint256 amount0, uint256 amount1)
{
    if (shares == 0) revert ZeroAmount();          // :264  <- no ZeroMinAmount analog
    address gate = coverageGate;
    if (gate != address(0) && !ICoverageGate(gate).lpBurnKeepsCovered(shares)) revert Undercovered();   // :269
    bytes memory ret = _exec(ichiVault, abi.encodeCall(IICHIVault.withdraw, (shares, juniorTrancheEngine)));  // :270
    (amount0, amount1) = abi.decode(ret, (uint256, uint256));
    if (amount0 < minAmount0 || amount1 < minAmount1) revert Slippage();   // :272  vacuous when both are 0
}
```

With `minAmount0 == minAmount1 == 0` the `:272` compare is vacuously true, so a sandwiched/thin withdraw passes
unprotected. The verified ICHI vault (`statskiy-sovetnik/ICHI-vaults-build` `src/vault/ICHIVault.sol`, mirror of
Base `0xfF8B…73f7`) shows `withdraw` (`:233-277`) has **no** internal spot/TWAP/hysteresis guard — it decomposes
liquidity at the current pool tick — so `minAmount0/1` is the SOLE sandwich protection on this leg. The contract
already enforces exactly this floor-must-be-nonzero rule on the *deposit* side, where ICHI *does* self-protect
(hysteresis, `ICHIVault.sol:186-187`). The guard is missing on the side that needs it most.

## Why it's LOW, not higher (don't over-fix)

- **Solvency is already safe.** The coverage gate (`:269` → `DurationFreezeModule.lpBurnKeepsCovered`) binds the
  burned share count and values LP at the **TWAP** (`IchiAlgebraFairReserves.fairReserves`), not spot — so an
  empty `minAmount0/1` cannot drop coverage below the senior floor (X-1 holds regardless).
- **No theft.** The withdraw `to` is the pinned `juniorTrancheEngine` (`:270`); a sandwich skews/reduces the
  basket the Safe receives, it does not redirect value off-protocol. Bounded, recoverable.
- **It catches the empty floor, not a mis-sized one.** "At-least-one-non-zero" does not force BOTH legs floored,
  so a wrongly-sized single-leg floor still slips — the *value* of the floor remains the off-chain X-2 sizing
  job (SUPPLY-ADV-09 / KEEPER-02). This guard closes the `(0,0)` = no-protection footgun, nothing more. That is
  its honest scope.
- **Not against malice.** A compromised operator passes a fake non-zero floor; this guard does nothing there
  (and the coverage gate already bounds that case). Its value is honest-but-careless protection.

So: LOW defense-in-depth — the durable, keeper-independent floor under the off-chain floor.

## The fix (recommended)

Add the error next to `ZeroMinShares`:

```solidity
error ZeroMinAmount();
```

and the guard in `removeLiquidity`, immediately after the `ZeroAmount` check (`:264`):

```solidity
if (shares == 0) revert ZeroAmount();
if (minAmount0 == 0 && minAmount1 == 0) revert ZeroMinAmount();   // + sole sandwich guard on the router-less
                                                                  // + withdraw (ICHI withdraw self-protects with
                                                                  // + nothing); at-least-one-leg floored.
```

**At-least-one-non-zero, NOT both.** A single-sided withdraw legitimately returns ~0 on one leg, so requiring
both non-zero would break it; requiring at least one closes the all-zero footgun while leaving the per-leg sizing
to the operator (the same X-2 posture as the deposit leg). Update the `removeLiquidity` NatSpec (`:255-256`) to
note `minAmount0/1` must not both be zero — and to correct the framing (per SUPPLY-ADV-09) that the *withdraw* is
the vault-unprotected side.

## Expected test fallout (the builder MUST handle — gate it yourself)

Existing happy-path tests call `removeLiquidity(shares, 0, 0)` and currently pass; after this guard they will
revert `ZeroMinAmount`. At least `test_removeLiquidity_coverage_gate` and `test_removeLiquidity_returns_legs_to_
safe_and_emits` (`LpStrategyModule.t.sol`) use `(0,0)` — update those call sites to a nominal non-zero floor
(e.g. `(1, 1)` or a probe-derived value) so they still exercise the dissolve path. Run the scoped suite to find
every `(0,0)` site; do not assume the two named above are exhaustive.

## Regression test

Add to `contracts/test/supply/szipUSD/LpStrategyModule.t.sol` (mirror `test_zero_minShares_reverts`):

```solidity
function test_removeLiquidity_zero_minAmount_reverts() public {
    // both floors zero → ZeroMinAmount (the sole sandwich guard on the router-less withdraw)
    vm.prank(operator);
    vm.expectRevert(LpStrategyModule.ZeroMinAmount.selector);
    m.removeLiquidity(shares, 0, 0);
}
// and assert (shares, x, 0) and (shares, 0, x) PASS the guard (reach the coverage gate / dissolve path).
```

## Documentation propagation (same commit — X-Ray is code-truth)

Grep-verified targets carrying the affected claim:

- **`contracts/src/supply/szipUSD/x-ray/LpStrategyModule.md`** (authoritative):
  - §3 I-3 row (`:50`): change "slippage floors — `minShares` on add (non-zero), `minAmount0/1` on remove" to
    note BOTH legs now require a non-zero floor (`ZeroMinShares` / `ZeroMinAmount`).
  - §4 guards table — the `ZeroAmount / ZeroMinShares` row (`:63`): add `ZeroMinAmount` +
    `test_removeLiquidity_zero_minAmount_reverts`.
  - §5 (`:81-83`): fold in with the SUPPLY-ADV-09 correction (withdraw is the vault-unprotected side; the floor
    is now mandatory there too).
- **`docs/wires/8-B6-LpStrategyModule.md`**:
  - `:75-78` (the `removeLiquidity` entrypoint description): add the `ZeroMinAmount` guard alongside the existing
    `ZeroAmount` / `Slippage`.
  - `:158-159` (the "`minShares == 0` is rejected … deliberate strictness" note): extend to say the same
    strictness now applies to `removeLiquidity`'s `minAmount0/1` (at-least-one-non-zero), and correct the
    deposit/withdraw asymmetry per SUPPLY-ADV-09.

(The doc edits here overlap SUPPLY-ADV-09's; if both land together, make the X-Ray/wire edits once and reference
both ticket IDs.)

## Cross-references

- **SUPPLY-ADV-09** — the off-chain TWAP floor-sizing rule + the doc corrections. This guard is the on-chain
  backstop; ADV-09 is the control that makes the floor *value* meaningful.
- **KEEPER-02** — the wind-down `removeLiquidity` driver that will supply the TWAP-sized floor; this guard
  protects the window before it ships/while it is unaudited, and any manual operator wind-down forever.

## Acceptance criteria

- `removeLiquidity` reverts `ZeroMinAmount` when `minAmount0 == 0 && minAmount1 == 0`; a single non-zero leg
  passes the guard.
- `test_removeLiquidity_zero_minAmount_reverts` added; all `(0,0)` call sites updated to non-zero; scoped suite
  (`test/supply/szipUSD/LpStrategyModule.t.sol`) green; `forge build` clean.
- X-Ray (I-3 / guard table / §5) + wire doc (`8-B6` entrypoint + the strictness note) reflect the mandatory
  remove-side floor and the corrected deposit/withdraw asymmetry.
