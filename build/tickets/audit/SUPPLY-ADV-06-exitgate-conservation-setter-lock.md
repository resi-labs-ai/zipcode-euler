# SUPPLY-ADV-06 — `ExitGate`: lock the conservation-defining setters post-issuance + `burnFor` `NotWired` symmetry

> **STATUS: BUILT (2026-06-23)** on `main`. Shipped: `_assertPreIssuance()` (revert `AlreadyWired` once
> `shareToken != 0 && SzipUSD(shareToken).totalSupply() != 0`, reusing the declared-but-unused `AlreadyWired`
> error) gating `setShareToken` and `setBaal`; plus the explicit `shareToken == 0 → NotWired` guard added to
> `burnFor` for symmetry with `depositFor:159`. Regression: `test_setShareToken_locked_after_issuance`,
> `test_setBaal_locked_after_issuance`, `test_setBaal_repoint_allowed_pre_issuance`,
> `test_burnFor_reverts_when_shareToken_unwired`. GATE: `forge build` clean + scoped suite **24/24** green (19
> baseline + 4 ADV-06 + 1 ADV-07). Doc-sync: wire doc `ExitGate-szipUSD.md` (setter list + `burnFor` guard) +
> X-Ray `ExitGate.md` §4 guard rows / §5 build-phase note / counts (18→24). No divergence from the planned fix.
> Source: adversarial-review mission 4 (two MEDIUMs deflated to LOW + one LOW), folded — all three share the
> wiring-setter / I-1-conservation code path
> (`adversarial-review/reports/src/supply/exitgate/synthesis.md`).

> BUILD item (LOW). The two-token conservation `szipUSD.totalSupply() == loot.balanceOf(gate)` (I-1) holds under
> every *runtime* path, but two `onlyOwner` setters can break it the moment they are called against a live (already-
> issued) vault — not a future redirect, an immediate restatement of the invariant's terms. The global pre-prod
> immutable re-freeze closes all 8 setters at once; this is the cheaper in-contract belt-and-suspenders that makes
> the *two conservation-defining* pointers fail closed even before that freeze. Folds the `burnFor` `NotWired`
> symmetry nit (mission 4 LOW, currently non-reachable) since it is the same wiring-hygiene surface.

## The gap (verified in code)

`setBaal` (`ExitGate.sol:115-121`) re-derives `loot = IBaal(baal_).lootToken()` (`:118`). After deposits exist the
Gate holds `N` units of the OLD Loot and `szipUSD.totalSupply() == N`; re-pointing makes `loot.balanceOf(gate)` read
the NEW token (likely `0`) while `totalSupply` is unchanged at `N` — the old Loot is orphaned and I-1 is false.
`burnFor` would then call `burnLoot` on the new substrate (Gate holds no loot there / lacks the manager grant) → exits
brick while the old paired Loot is stranded.

`setShareToken` (`:94-98`) is the inverse: with `N` szipUSD minted on token A and `loot.balanceOf(gate) == N`, a
re-point to token B makes subsequent `depositFor`/`burnFor` mint/burn B while `loot` still tracks A's frozen supply
plus B's deltas — after one more deposit `loot = N+d`, matching neither `A.totalSupply()` (=N) nor `B.totalSupply()`
(=d). The identity no longer maps to a single token.

`burnFor` (`:200-207`) guards `windowController` / `juniorTrancheEngine != 0` / `amount != 0` but NOT `shareToken == 0`,
then dereferences `SzipUSD(shareToken).burn` (`:205`). `depositFor` has the explicit `shareToken == 0 → NotWired`
guard (`:159`); `burnFor` relies instead on an incidental EVM call-to-codeless-address revert. Non-reachable today
(`burnLoot` needs the Gate to already hold Loot → only after a `depositFor` that required `shareToken` set; and
`setShareToken` rejects re-setting to `0`), but the asymmetry is a robustness gap the X-Ray flags as untested.

## The fix

A `private view` helper, reusing the existing `AlreadyWired` error (`:59`, previously declared-but-unused):

```solidity
function _assertPreIssuance() private view {
    if (shareToken != address(0) && SzipUSD(shareToken).totalSupply() != 0) revert AlreadyWired();
}
```

Called at the top of `setShareToken` and `setBaal` (after their zero-address checks). `shareToken == 0` is safe to
re-point because `depositFor:159` forbids any mint while unwired, so no szipUSD can exist. The other five setters
(oracle, tokens, windowController, engine, cap) do not touch I-1 and stay re-pointable. Plus, in `burnFor`, add
`if (shareToken == address(0)) revert NotWired();` for symmetry.

## Severity rationale (LOW, deflated from the raw MEDIUM ×2)

- The trigger is `onlyOwner` (the Timelock) — a governance/ops mistake (re-pointing AFTER issuance, against the
  documented "wire once, lock pre-prod" procedure), not an operator/attacker path.
- **No drain:** existing basket assets stay in the old `juniorTrancheSafe`; this strands accounting, it does not move
  value. Per the boot rule a re-point that breaks conservation but does not DRAIN is at most LOW.
- It is build-phase mutable wiring closed by the documented pre-prod immutable re-freeze; this just makes the two
  sharpest setters fail closed earlier, in-contract.
- Raised above the generic re-point INFO because mission 4 named it the conservation hazard most worth working, the
  fix is a one-liner reusing an existing error, and the I-1 invariant test never re-points (so the suite misses it).

## Acceptance criteria

1. After a deposit (szipUSD issued), `setShareToken` and `setBaal` revert `AlreadyWired`; on a fresh pre-issuance
   Gate both still re-point (existing `test_setters_repoint_and_auth` + new `test_setBaal_repoint_allowed_pre_issuance`).
2. `burnFor` on a Gate with `windowController` + `juniorTrancheEngine` set but `shareToken` unset reverts the explicit
   `NotWired` (not a bare EVM revert).
3. GATE: `forge build` clean + `forge test --match-path test/supply/szipUSD/ExitGate.t.sol` green (baseline + new).

## Documentation-propagation step

- `contracts/src/supply/szipUSD/x-ray/ExitGate.md` (authoritative): §4 guard rows for `AlreadyWired` (pre-issuance
  lock) + the `burnFor` `NotWired`; §5 build-phase-wiring note; test counts.
- `docs/wires/ExitGate-szipUSD.md`: setter list (pre-issuance lock on `setShareToken`/`setBaal`) + `burnFor` guard.
- Grep-verify no other `docs/wires/` doc asserts ExitGate setter internals (the topology docs reference the deploy
  wiring, not the guards) — expect nothing else to propagate.
