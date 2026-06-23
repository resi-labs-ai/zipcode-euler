# SUPPLY-ADV-09 — Size `removeLiquidity`'s `minAmount0/1` floor off the TWAP fair-reserves, not spot

> **STATUS: DOC HALF SHIPPED (ce1376b, 2026-06-23); CODE HALF BLOCKED → KEEPER-02.** The doc corrections
> (deposit-is-protected / withdraw-is-not; the floor is TWAP-sized) landed in the SUPPLY-ADV-10 commit (X-Ray §5 +
> wire `8-B6`). The off-chain TWAP floor-sizing *code* has no driver to change — `removeLiquidity` has no keeper
> Job today — so it is realized when the wind-down driver is built (`build/tickets/cre/KEEPER-02`). Not
> independently shippable beyond the docs.
>
> Process + doc ticket (no `.sol` change required). Off-chain CRE sizing rule + X-Ray/wire doc-sync. The optional
> on-chain backstop (`ZeroMinAmount` guard) shipped as SUPPLY-ADV-10 — this ticket is the *materially correct*
> control; the guard is hygiene.
>
> Source: adversarial-review on `contracts/src/supply/szipUSD/LpStrategyModule.sol`
> (`adversarial-review/reports/src/supply/lpstrategymodule/synthesis.md`, mission 3 + verified-source follow-up).
> Promoted from the synthesis's INFO candidate after pulling the **verified ICHI vault source** (Base
> `0xfF8B29e9f536F9A43DA7868011b7B667fa8d73f7`; mirror `statskiy-sovetnik/ICHI-vaults-build`
> `src/vault/ICHIVault.sol`), which shows the deposit/withdraw protection is asymmetric in a way our docs got
> backwards.

> BUILD item (LOW / off-chain control). Solvency is **not** at risk (the coverage gate already values LP at the
> TWAP, so a sandwiched withdraw cannot breach the floor — see "Why it's LOW"). This closes a bounded value-leak
> on the wind-down LP→legs hop. Worth doing because the fix is nearly free — the manipulation-resistant value the
> floor should use is **already computed on-chain** (`IchiAlgebraFairReserves.fairReserves`), the same number the
> coverage gate trusts; only the off-chain sizing *input* changes (TWAP fair-value, not spot).

## The gap (verified against the real ICHI vault)

`removeLiquidity(shares, minAmount0, minAmount1)` (`LpStrategyModule.sol:259-273`) does a direct
`IICHIVault.withdraw(shares, juniorTrancheEngine)` (`:270`) and floors the result `amount0 < minAmount0 ||
amount1 < minAmount1 → Slippage` (`:272`). The `minAmount0/1` are operator-supplied scalars; the **CRE robot
sizes them off-chain** (wire doc `8-B6-LpStrategyModule.md:110`).

The verified ICHI vault shows the two sides of the LP lifecycle have **opposite** native protection:

- **`deposit` self-protects** (`ICHIVault.sol:169-217`): it fetches spot `price` *and* `twap`, and
  `if (delta > hysteresis) require(checkHysteresis(), "IV.deposit: try later")` (`:186-187`, 1% default
  `:109`) — it refuses to mint while spot is >1% off TWAP in the same block. The share math is also
  conservatively bracketed (`deposit0 * min(price, twap)` `:192` vs `pool0 * max(price, twap)` `:212`), biased
  against the depositor. A deposit sandwich is largely fenced *by the vault itself*.
- **`withdraw` self-protects with NOTHING** (`ICHIVault.sol:233-277`): no `_fetchSpot`, no `_fetchTwap`, no
  hysteresis. It calls `_burnLiquidity(...)` which decomposes each position's liquidity **at the current pool
  tick** (`:243-256`) plus pro-rata idle (`:258-272`). The token0/token1 *split* you receive is a pure function
  of the manipulable current tick.

**Consequence:** the only sandwich protection on the dissolution hop is the caller's `minAmount0/1`, and today
the CRE sizes that floor from the **spot** pool state — the exact quantity an attacker moves for one block.
Sizing the seatbelt off the number the attacker controls is the gap. (This also corrects two docs that have the
asymmetry backwards: wire `8-B6:33-35` and `:158-159` and X-Ray §5 call `minShares` "the only sandwich
protection on a direct ICHI deposit" — the deposit is the *protected* side; the **withdraw** is the unprotected
one.)

## Why it's LOW, not higher (don't over-fix)

- **Solvency is already safe.** The coverage gate (`removeLiquidity:269` → `DurationFreezeModule.
  lpBurnKeepsCovered(shares)`) binds the burned **share count**, and the freeze module values that LP at the
  **TWAP** (`IchiAlgebraFairReserves.fairReserves`), not spot. A manipulated withdraw therefore **cannot drop
  coverage below the liability floor** — the load-bearing invariant (X-1) holds regardless of `minAmount0/1`.
- **No theft, value stays in the basket.** The withdraw `to` is the pinned `juniorTrancheEngine` (`:270`); a
  sandwich skews/reduces the *basket* the Safe receives, it does not redirect value to an attacker address. The
  attacker's profit comes from the swap, not from the Safe.
- **One-shot, wind-down only.** `removeLiquidity` has no live-ops caller (`:248-253`); it is an operator-triggered
  teardown hop, not a recurring drip. The exposure is per-teardown, not standing.
- **Bounded by pool depth.** On the small zipUSD/xALPHA pool, extractable MEV is bounded by how far the Algebra
  pool's tick can be moved against the size being withdrawn.

So the realistic worst case is: the protocol eats bounded, recoverable slippage on a single wind-down withdraw.
LOW.

## The fix (recommended — off-chain CRE sizing rule)

Change the CRE's `minAmount0/1` sizing for `removeLiquidity` from spot-derived to **TWAP-fair-reserves-derived**,
reusing the on-chain value the coverage gate already trusts:

```
(fair0, fair1) = IchiAlgebraFairReserves.fairReserves(ichiVault, window)   // TWAP reconstruction, :38
supply         = IICHIVault.totalSupply()
expected_i     = fair_i * shares / supply                                  // honest pro-rata at TWAP
minAmount_i    = expected_i * (1 - tolerance)                             // tolerance ~1–2% for honest wiggle
```

- `window` = the same TWAP window the protocol already uses for the LP leg (`SzipNavOracle.lpTwapWindow`); reuse
  it so the floor and the coverage gate read the *same* fair price.
- `fairReserves` already returns base+limit positions reconstructed at the TWAP tick **plus idle balances**, which
  is exactly what an unmanipulated `withdraw` decomposes to pro-rata — so `fair_i * shares / supply` is the
  honest expected leg.
- A sandwich that skews the split now pushes one realized leg below its TWAP-derived floor → `Slippage` revert
  (`:272`). The seatbelt is bolted to a number the attacker cannot move in one block.

**No contract change.** This is a sizing-rule change in the off-chain keeper (the (K) transport in
`build/tickets/cre/CRE-OPS-ROUTING.md:37`).

**Realization caveat (verified 2026-06-23):** there is **no remove-side driver to change** — the keeper drives
`LpStrategyModule` only for the restake legs; `removeLiquidity` has no Job (`cre/keeper/cmd/keeper/main.go:166`
registers `identity, burn, strikeLoop, redemption` only). The TWAP-fair-reserves pattern this ticket prescribes
already exists for the *add* side (`cre/keeper/internal/quote/quote.go:159` ports
`IchiAlgebraFairReserves._meanTick`). So this rule is realized when the wind-down driver is built — see
**`build/tickets/cre/KEEPER-02-winddown-lp-dissolution.md`** (which applies the same `quote.go` TWAP source +
cushion to the withdraw side). This audit ticket owns the *rule + the doc corrections*; KEEPER-02 owns the
*code*.

Pairs with SUPPLY-ADV-10 (the optional `ZeroMinAmount` on-chain backstop) and with the private-submission half
of KEEPER-02 (route the wind-down `removeLiquidity` through a protected RPC) — defense in depth, but THIS ticket
is the control that actually makes the floor meaningful.

## Documentation propagation (X-Ray is code-truth; the doc edits are landable now — no code gate)

Grep-verified targets carrying the affected claim:

- **`contracts/src/supply/szipUSD/x-ray/LpStrategyModule.md`** (authoritative):
  - §5 "Slippage is the only sandwich protection on a direct ICHI **deposit** (I-3)" (`:81-83`): correct the
    asymmetry — per the verified ICHI source, the **deposit** is vault-protected (hysteresis + min/max
    bracketing) and the **withdraw** is the unprotected side; the `removeLiquidity` floor must be sized off
    `fairReserves` TWAP, not spot.
  - I-3 row (§3, `:50`): note the remove-side floor is the *sole* protection on the dissolution hop and is
    TWAP-sized (cross-reference the coverage gate's shared fair-value source).
- **`docs/wires/8-B6-LpStrategyModule.md`**:
  - `:33-35` ("slippage protection is the operator-supplied `minShares` post-check ... fail-closed inside the
    vault") and `:158-159` ("a direct ICHI deposit is sandwich-exposed"): re-frame — the *deposit* is the
    vault-protected side; the *withdraw* is the exposed one; the remove floor is TWAP-sized.
  - `:110` ("The CRE robot sizes `minShares` ..."): add that the CRE sizes `removeLiquidity`'s `minAmount0/1`
    off `IchiAlgebraFairReserves.fairReserves(ichiVault, lpTwapWindow)` pro-rata minus tolerance — the same
    fair value the coverage gate uses — NOT off spot.
- **`build/tickets/cre/CRE-OPS-ROUTING.md`** (`:37`): the (K)-keeper row for `LpStrategyModule` says "slippage
  floors computed off-chain" — append the sizing rule (TWAP fair-reserves pro-rata) so the off-chain
  contract-of-record names the source.

## Acceptance criteria

- The CRE keeper sizes `removeLiquidity`'s `minAmount0/1` from `IchiAlgebraFairReserves.fairReserves(ichiVault,
  lpTwapWindow)` pro-rata minus a configured tolerance (not from spot pool state). (Off-chain change; verify in
  the keeper's StrikeLoop/wind-down floor-sizing code + its config/runbook.)
- X-Ray §5 + I-3 corrected: the **withdraw** is the vault-unprotected side; the remove floor is TWAP-sized and
  shares the coverage gate's fair-value source. The "only protection on a direct ICHI deposit" framing is fixed.
- Wire doc `8-B6` (`:33-35`, `:110`, `:158-159`) and `CRE-OPS-ROUTING.md:37` reflect the TWAP sizing rule.
- No `.sol` change in this ticket (the `ZeroMinAmount` on-chain backstop is SUPPLY-ADV-10).
