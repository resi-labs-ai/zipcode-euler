# SUPPLY-ADV-12 — `SzipUSD`: lock `setGate` post-issuance (the third conservation-defining pointer ADV-06 left open)

> **STATUS: BUILT (2026-06-23)** on `main`. Shipped: `error AlreadyIssued()` + `if (totalSupply() != 0) revert
> AlreadyIssued();` in `setGate` (after the zero-address check), failing the sole-minter re-point closed once any
> szipUSD is issued — symmetric with `ExitGate._assertPreIssuance` (ADV-06). Regression:
> `test_szipUSD_setGate_locked_after_issuance` (revert + gate unchanged after a mint) +
> `test_szipUSD_setGate_repoint_allowed_pre_issuance` (two free re-points at `totalSupply()==0`). GATE: `forge
> build` clean + scoped suite `test/supply/szipUSD/*.t.sol` **26/26** green (24 baseline + 2 ADV-12). Doc-sync:
> X-Ray `SzipUSD.md` (§1/§2/§3 I-4/§4/§5/§6 + header stamp) + wire `ExitGate-szipUSD.md` (`SzipUSD` row +
> internal-wiring narrative). No divergence from the planned fix (named the error `AlreadyIssued`, as the ticket
> suggested). Source: adversarial-review SzipUSD missions 1 & 2 (both legs INFO; promoted to LOW under the ADV-06
> precedent — `adversarial-review/reports/src/supply/szipusd/synthesis.md`).

> BUILD item (LOW). The two-token conservation `szipUSD.totalSupply() == loot.balanceOf(gate)` (I-1/I-2) is
> defined by THREE `onlyOwner` pointers. SUPPLY-ADV-06 (BUILT 2026-06-23) made the two on the Gate
> (`ExitGate.setShareToken`, `setBaal`) fail closed once `totalSupply() != 0`. The THIRD — `SzipUSD.gate`,
> re-pointed by `SzipUSD.setGate` — was out of ADV-06's (ExitGate-scoped) blast radius and remains mutable
> post-issuance. This ticket adds the symmetric in-contract belt-and-suspenders before the pre-prod immutable
> re-freeze, so the sole-minter pointer cannot be silently re-assigned over a live supply.

## The gap (verified in code)

`SzipUSD.setGate` (`contracts/src/supply/szipUSD/SzipUSD.sol:30-34`) is `onlyOwner` + `ZeroAddress`-guarded but
carries no post-issuance lock. `mint`/`burn` read `gate` live (`:38`, `:44`), so a re-point is immediately
authoritative.

After deposits exist, the ExitGate holds `N` units of Loot and `szipUSD.totalSupply() == N`. Re-point
`SzipUSD.setGate(newGate)` while `totalSupply() != 0`:
- the OLD gate immediately reverts `NotGate` (`:38`/`:44`) — it can no longer `burn`, so the `N` Loot it holds
  is stranded;
- the NEW gate becomes sole minter/burner but holds no Loot, so `szipUSD.totalSupply() == loot.balanceOf(gate)`
  (read against the new gate) is `N == 0` — false from the first block, and every subsequent `mint` widens it.

This is the exact mirror of the `setShareToken`/`setBaal` hazard ADV-06 documented and closed
(`SUPPLY-ADV-06-exitgate-conservation-setter-lock.md`): a conservation-defining re-point against a live vault
that breaks I-1/I-2 without draining value. The Gate side now fails closed
(`ExitGate.sol:224-225`, `_assertPreIssuance` → `AlreadyWired`); `SzipUSD.setGate` does not. The
`test_szipUSD_setGate_and_ctor_zero_guard` re-point test runs on a fresh (pre-issuance) token, so the suite
never exercises a re-point over a non-zero supply.

## The fix

Add a pre-issuance guard at the top of `setGate` (after the zero-address check), mirroring ADV-06:

```solidity
error AlreadyIssued();

function setGate(address gate_) external onlyOwner {
    if (gate_ == address(0)) revert ZeroAddress();
    if (totalSupply() != 0) revert AlreadyIssued();   // re-point the minter/burner only before any szipUSD is issued (I-1)
    gate = gate_;
    emit GateSet(gate_);
}
```

`totalSupply()` is the token's own inherited OZ accessor — no cross-contract call needed (unlike ADV-06, which
had to reach into `SzipUSD(shareToken)`). Build-phase re-pointing stays fully available while
`totalSupply() == 0`, which is the entire window the "survive a Gate redeploy" flexibility (ctor doc `:13`)
actually needs — a Gate redeploy after issuance would strand the paired Loot regardless and must go through the
documented migration, not a silent setter. The ctor zero-guard is unchanged; the new error name is a builder
choice (`AlreadyIssued` reads better on the token than ADV-06's `AlreadyWired`, which named the Gate's wiring).

## Severity rationale (LOW — matches the ADV-06 deflation)

- Trigger is `onlyOwner` (the Timelock): a governance/ops mistake (re-pointing AFTER issuance, against the
  documented "wire once, freeze pre-prod" procedure), not an operator/attacker path.
- **No drain:** basket assets stay in the `juniorTrancheSafe`; this strands accounting (old Loot orphaned, new
  gate unbacked), it does not move value. Per the house rule a conservation-breaking re-point that does not
  DRAIN is at most LOW.
- Build-phase mutable wiring otherwise closed by the documented pre-prod immutable re-freeze; this makes the
  token's sole conservation pointer fail closed earlier, in-contract — completing the set ADV-06 began.
- Raised above the generic re-point INFO because it is the *same* conservation hazard ADV-06 chose to harden,
  the fix is a one-liner against the token's own `totalSupply()`, and the I-4 re-point test never re-points over
  a live supply (the suite misses it).

## Acceptance criteria

1. After a deposit (szipUSD issued via the Gate), `SzipUSD.setGate(newGate)` reverts `AlreadyIssued`; on a
   fresh pre-issuance token `setGate` still re-points and the new gate can mint while the old reverts `NotGate`
   (extend `test_szipUSD_setGate_and_ctor_zero_guard` or add `test_szipUSD_setGate_locked_after_issuance` +
   `test_szipUSD_setGate_repoint_allowed_pre_issuance`).
2. ctor zero-guard and `setGate` `onlyOwner`/`ZeroAddress` behavior unchanged (existing assertions stay green).
3. GATE: `forge build` clean + `forge test --match-path 'test/supply/szipUSD/*.t.sol'` green (baseline + new).

## Documentation-propagation step

Gate all on the code landing (the X-Ray is code-truth); none landable before the code:
- `contracts/src/supply/szipUSD/x-ray/SzipUSD.md` (authoritative): §2 entry-points row for `setGate`
  (add the post-issuance lock), §4 guards table (new `AlreadyIssued` / pre-issuance row), §5 attack-surface
  bullet on `setGate` (now fails closed post-issuance), I-4 proven-by + test counts (§6).
- `docs/wires/ExitGate-szipUSD.md`: the `SzipUSD` row (`:30`), the `setGate` narrative (`:95`), and the
  szipUSD-owner note (`:125`) — update "build-phase re-pointable" to "build-phase re-pointable **only until
  first issuance** (`AlreadyIssued` thereafter); immutability still deferred to pre-prod."
- Grep-verify no other `docs/wires/` doc asserts `SzipUSD.setGate` internals — the deploy/topology docs
  (`DeployZipcode.md`, `CTR-06b/c`, `8-B14`, `WOOF-06`) reference the wiring, not the guard; expect nothing
  else to propagate (filter those false positives).
