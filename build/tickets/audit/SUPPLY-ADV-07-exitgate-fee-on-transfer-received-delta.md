# SUPPLY-ADV-07 — `ExitGate.depositFor`: received-delta guard against a fee-on-transfer / rebasing leg

> **STATUS: BUILT (2026-06-23)** on `main`. Shipped: a basket-balance snapshot around the deposit
> `safeTransferFrom` in `depositFor` — `if (IERC20(asset).balanceOf(juniorTrancheSafe) - basketBefore != amount)
> revert TransferShortfall();` (new `TransferShortfall` error), adopting the in-house `DurationFreezeModule`
> (`:363/368`, `:387/392`) received-delta pattern. Regression: `test_depositFor_feeOnTransfer_reverts` (a fresh
> oracle+Gate whose zipUSD leg is a 1% fee-on-transfer mock → deposit reverts). GATE: `forge build` clean + scoped
> suite **24/24** green. Doc-sync: wire doc `ExitGate-szipUSD.md` `depositFor` step 6 + X-Ray `ExitGate.md` §4
> guard row / §5 attack-surface note / counts. No divergence from the planned fix. Source: adversarial-review
> mission 3 (LOW) — `adversarial-review/reports/src/supply/exitgate/synthesis.md`.

> BUILD item (LOW). `depositFor` prices `shares` off `valueOf(asset, amount)` (the FULL requested amount, `:163`)
> then forwards `amount` to the basket (`:170`). For a fee-on-transfer or down-rebasing leg the basket receives
> `< amount`, so the depositor (and the Gate's paired self-mint of Loot) gets szipUSD for value the basket never
> received — diluting stayers, the exact direction the round-down pricing exists to prevent. Latent under today's
> non-FoT whitelist {zipUSD, xALPHA}; reachable only if `setTokens` (Timelock) ever points a leg at a FoT token —
> the whitelist is currently the sole defense. Two-token conservation is NOT broken (the Loot/szipUSD legs stay
> paired); this is a value-dilution mispricing, not a desync.

## The gap (verified in code)

- `ExitGate.sol:163` — `value = navOracle.valueOf(asset, amount)` values the *requested* `amount`.
- `:166` — `shares = value * 1e18 / navE`, minted to the depositor (`:174`) with paired Loot to the Gate (`:173`).
- `:170` — `IERC20(asset).safeTransferFrom(msg.sender, juniorTrancheSafe, amount)` forwards `amount`, with **no check
  that the basket balance rose by `amount`**. `SzipNavOracle.valueOf` (`:603-604` → `_tokenValue:594-595`) values the
  requested amount, not the realized delta.

The sibling `DurationFreezeModule.sol` already guards exactly this: `beforeBal = balanceOf(dest)` … transfer …
`if (balanceOf(dest) - beforeBal != amount) revert TransferShortfall()` (`:363/368`, `:387/392`). `ExitGate.depositFor`
does not — the inconsistency is the finding.

## The fix

Snapshot the basket balance around the transfer and require the exact `amount` landed, with a new `TransferShortfall`
error:

```solidity
uint256 basketBefore = IERC20(asset).balanceOf(juniorTrancheSafe);
IERC20(asset).safeTransferFrom(msg.sender, juniorTrancheSafe, amount);
if (IERC20(asset).balanceOf(juniorTrancheSafe) - basketBefore != amount) revert TransferShortfall();
```

Requiring `received == amount` (rather than re-pricing off the received delta) matches the sibling precedent and
keeps `shares` priced off a `value` that is now guaranteed accurate. No change to the paired mint or the cap check.

## Severity rationale (LOW)

- Not reachable under the current whitelist (neither zipUSD nor xALPHA is fee-on-transfer/rebasing); requires a
  Timelock `setTokens` re-point to a FoT leg.
- The value is removing the silent dependency on "`setTokens` never points at a FoT token" and aligning `depositFor`
  with the in-house received-delta pattern its sibling already enforces.
- Conservation-preserving (legs stay paired) — a dilution mispricing, not a desync; hence LOW, not MEDIUM.

## Acceptance criteria

1. A deposit of a 1% fee-on-transfer leg reverts `TransferShortfall` (the basket would have received 99%).
2. A normal (non-FoT) deposit is unaffected — all existing issuance tests stay green.
3. GATE: `forge build` clean + `forge test --match-path test/supply/szipUSD/ExitGate.t.sol` green (baseline + new).

## Documentation-propagation step

- `contracts/src/supply/szipUSD/x-ray/ExitGate.md` (authoritative): §4 guard row for `TransferShortfall`; §5
  attack-surface note (FoT over-issue closed; whitelist no longer the sole defense).
- `docs/wires/ExitGate-szipUSD.md`: `depositFor` step 6 received-delta guard.
- Grep-verify no other truth-source asserts the deposit-transfer internals — expect nothing else to propagate.
